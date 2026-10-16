import os
import json
import uuid
from datetime import datetime, timezone
from azure.identity import DefaultAzureCredential
from azure.mgmt.resourcegraph import ResourceGraphClient
from azure.mgmt.resourcegraph.models import QueryRequest
from azure.cosmos import CosmosClient
from azure.storage.blob import BlobServiceClient

def main():
    cred = DefaultAzureCredential()
    subscription_id = os.environ["AZURE_SUBSCRIPTION_ID"]
    arg_client = ResourceGraphClient(credential=cred)
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    
    # 1. Locate Evidence Resources
    print("Locating Evidence Plane resources via ARG...")
    evidence_query = """
    Resources
    | where tags['purpose'] == 'grc-evidence-plane'
    | where type =~ 'microsoft.documentdb/databaseaccounts' or type =~ 'microsoft.storage/storageaccounts'
    | project type, name, properties.documentEndpoint
    """
    evidence_req = QueryRequest(subscriptions=[subscription_id], query=evidence_query)
    evidence_res = arg_client.resources(evidence_req)
    
    cosmos_endpoint = None
    storage_account_name = None
    for item in evidence_res.data:
        if 'documentdb' in item['type'].lower():
            cosmos_endpoint = item['properties_documentEndpoint']
        elif 'storageaccounts' in item['type'].lower():
            storage_account_name = item['name']
            
    # 2. Query ARG and Upsert to Cosmos DB
    print(f"Querying ARG and updating Cosmos DB AssetInventory...")
    asset_query = "Resources | project id, name, type, location, tags"
    asset_res = arg_client.resources(QueryRequest(subscriptions=[subscription_id], query=asset_query))
    
    cosmos_client = CosmosClient(url=cosmos_endpoint, credential=cred)
    container = cosmos_client.get_database_client("grc-evidence").get_container_client("AssetInventory")
    
    docs_for_json = []
    for item in asset_res.data:
        resource_provider = item["type"].split('/')[0] if '/' in item["type"] else item["type"]
        doc = {
            "id": str(uuid.uuid5(uuid.NAMESPACE_URL, item["id"])),
            "resourceId": item["id"],
            "name": item["name"],
            "resourceProvider": resource_provider,
            "resourceType": item["type"],
            "location": item["location"],
            "owner": item["tags"].get("owner", "UNASSIGNED") if item["tags"] else "UNASSIGNED",
            "environment": item["tags"].get("env", "UNASSIGNED") if item["tags"] else "UNASSIGNED",
            "snapshotDate": timestamp
        }
        container.upsert_item(doc)
        docs_for_json.append(doc)
        
    # 3. Lock JSON in WORM Blob
    print(f"Uploading machine-readable JSON to {storage_account_name}...")
    blob_url = f"https://{storage_account_name}.blob.core.windows.net"
    blob_client = BlobServiceClient(account_url=blob_url, credential=cred).get_container_client("reports")
    
    json_filename = f"sdr-inventory-{timestamp}.json"
    blob_client.get_blob_client(json_filename).upload_blob(json.dumps(docs_for_json, indent=2), overwrite=False)
    
    # Pass the filename to the next step in GitHub Actions
    with open(os.environ['GITHUB_ENV'], 'a') as env_file:
        env_file.write(f"TARGET_JSON_BLOB={json_filename}\n")
        env_file.write(f"STORAGE_ACCOUNT_NAME={storage_account_name}\n")
    
    print(f"Phase 1 Complete. Facts locked in {json_filename}.")

if __name__ == "__main__":
    main()