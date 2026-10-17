import os
import json
from datetime import datetime, timezone
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient
from azure.mgmt.resourcegraph import ResourceGraphClient
from azure.mgmt.resourcegraph.models import QueryRequest
from openai import AzureOpenAI

def upload_to_worm(container_client, filename, content):
    """Helper to lock artifacts in WORM storage."""
    print(f"Locking artifact into WORM storage as {filename}...")
    container_client.get_blob_client(filename).upload_blob(content, overwrite=False)

def generate_ai_content(ai_client, deployment, system_prompt, user_content):
    """Helper to standardize Azure AI Foundry calls."""
    response = ai_client.chat.completions.create(
        model=deployment,
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_content}
        ],
        temperature=0.1,
        max_completion_tokens=250  # Strictly throttled output limit
    )
    return response.choices[0].message.content

def main():
    cred = DefaultAzureCredential()
    subscription_id = os.environ["AZURE_SUBSCRIPTION_ID"]
    storage_account_name = os.environ["STORAGE_ACCOUNT_NAME"]
    target_json_blob = os.environ["TARGET_JSON_BLOB"] 
    
    foundry_deployment = "gpt-5.1"  
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    
    print("Locating Azure AI Foundry endpoint...")
    arg_client = ResourceGraphClient(credential=cred)
    narrative_query = """
    Resources
    | where tags['purpose'] == 'grc-narrative-plane' and type =~ 'microsoft.cognitiveservices/accounts'
    | project properties.endpoint
    """
    narrative_res = arg_client.resources(QueryRequest(subscriptions=[subscription_id], query=narrative_query))
    
    if not narrative_res.data:
        raise Exception("Could not discover Azure AI Foundry endpoint.")
    foundry_endpoint = narrative_res.data[0]['properties_endpoint']

    blob_service_url = f"https://{storage_account_name}.blob.core.windows.net"
    container_client = BlobServiceClient(account_url=blob_service_url, credential=cred).get_container_client("reports")
    
    token_provider = cred.get_token("https://cognitiveservices.azure.com/.default")
    ai_client = AzureOpenAI(
        azure_endpoint=foundry_endpoint,
        azure_ad_token_provider=lambda: token_provider.token,
        api_version="2024-02-15-preview"
    )

    print(f"\n--- Starting SDR OSCAL Generation ---")
    print(f"Retrieving raw inventory facts from {target_json_blob}...")
    inventory_evidence = container_client.get_blob_client(target_json_blob).download_blob().readall().decode("utf-8")
    
    with open("prompts/sdr.md", "r") as f:
        sdr_prompt = f.read()
    
    upload_to_worm(container_client, f"prompt-sdr-{timestamp}.md", sdr_prompt)
    
    # Throttle input payload down to 5 items to fit 1K TPM sandbox limit
    inventory_data = json.loads(inventory_evidence)
    minified_inventory = json.dumps(inventory_data[:5], separators=(',', ':'))
    
    print(f"Generating OSCAL SDR via {foundry_deployment}...")
    oscal_sdr = generate_ai_content(ai_client, foundry_deployment, sdr_prompt, f"INPUT: {minified_inventory}")
    
    oscal_filename = target_json_blob.replace(".json", "-oscal-sdr.json")
    upload_to_worm(container_client, oscal_filename, oscal_sdr)
    print("OSCAL SDR successfully locked in WORM.")

if __name__ == "__main__":
    main()