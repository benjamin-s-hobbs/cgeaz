import os
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient
from azure.communication.email import EmailClient
from azure.mgmt.resourcegraph import ResourceGraphClient
from azure.mgmt.resourcegraph.models import QueryRequest
from openai import AzureOpenAI

def main():
    cred = DefaultAzureCredential()
    subscription_id = os.environ["AZURE_SUBSCRIPTION_ID"]
    storage_account_name = os.environ["STORAGE_ACCOUNT_NAME"]
    target_json_blob = os.environ["TARGET_JSON_BLOB"]
    recipient_address = os.environ["RECIPIENT_EMAIL"] # Keep this as a GitHub Secret/Variable
    foundry_deployment = "gpt-5.1"  # Ensure this matches the deployment name in Azure AI Foundry
    
    # 1. Dynamically locate Narrative Plane resources via ARG
    print("Locating Azure AI Foundry and ACS endpoints...")
    arg_client = ResourceGraphClient(credential=cred)
    narrative_query = """
    Resources
    | where tags['purpose'] == 'grc-narrative-plane'
    | project type, name, properties.endpoint, properties.fromSenderDomain
    """
    narrative_res = arg_client.resources(QueryRequest(subscriptions=[subscription_id], query=narrative_query))
    
    foundry_endpoint = None
    acs_endpoint = None
    sender_address = None
    
    for item in narrative_res.data:
        if 'cognitiveservices' in item['type'].lower():
            foundry_endpoint = item['properties_endpoint']
        elif 'communicationservices' in item['type'].lower():
            acs_endpoint = f"https://{item['name']}.communication.azure.com"
        elif 'emailservices/domains' in item['type'].lower():
            sender_address = item['properties_fromSenderDomain']
            
    if not foundry_endpoint or not acs_endpoint or not sender_address:
        raise Exception("Could not discover all required narrative plane resources.")

    # 2. Read Immutable JSON from WORM Blob
    print(f"Retrieving verified facts from {target_json_blob}...")
    blob_service_url = f"https://{storage_account_name}.blob.core.windows.net"
    container_client = BlobServiceClient(account_url=blob_service_url, credential=cred).get_container_client("reports")
    json_evidence = container_client.get_blob_client(target_json_blob).download_blob().readall().decode("utf-8")
    
    # 3. Load Version-Controlled Prompt
    with open("prompts/sdr.md", "r") as f:
        system_prompt = f.read()
        
    # 4. Call Azure AI Foundry (Zero Keys)
    print(f"Generating narrative via {foundry_deployment}...")
    token_provider = cred.get_token("https://cognitiveservices.azure.com/.default")
    
    ai_client = AzureOpenAI(
        azure_endpoint=foundry_endpoint,
        azure_ad_token_provider=lambda: token_provider.token,
        api_version="2024-02-15-preview"
    )
    
    response = ai_client.chat.completions.create(
        model=foundry_deployment,
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": f"INPUT: {json_evidence}"}
        ],
        temperature=0.1
    )
    narrative_md = response.choices[0].message.content
    
    # 5. Upload Narrative to WORM Blob
    narrative_filename = target_json_blob.replace(".json", "-narrative.md")
    print(f"Locking narrative into WORM storage as {narrative_filename}...")
    container_client.get_blob_client(narrative_filename).upload_blob(narrative_md, overwrite=False)
    
    # 6. Dispatch via Azure Communication Services
    print("Dispatching executive digest to stakeholders...")
    email_client = EmailClient(acs_endpoint, cred)
    
    message = {
        "senderAddress": f"donotreply@{sender_address}",
        "recipients": {"to": [{"address": recipient_address}]},
        "content": {
            "subject": "Weekly System Security Plan & Inventory Digest",
            "plainText": narrative_md,
            "html": f"<html><body>{narrative_md}</body></html>"
        }
    }
    
    email_client.begin_send(message).result()
    print("Digest successfully delivered.")

if __name__ == "__main__":
    main()