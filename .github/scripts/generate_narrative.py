import os
import json
import time
from datetime import datetime, timezone
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient
from azure.communication.email import EmailClient
from azure.mgmt.resourcegraph import ResourceGraphClient
from azure.mgmt.resourcegraph.models import QueryRequest
from azure.core.exceptions import ResourceNotFoundError
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
        temperature=0.1, # Low temperature for highly deterministic GRC outputs
        max_completion_tokens=500 # Prevent unbounded token reservation
    )
    return response.choices[0].message.content

def main():
    cred = DefaultAzureCredential()
    subscription_id = os.environ["AZURE_SUBSCRIPTION_ID"]
    storage_account_name = os.environ["STORAGE_ACCOUNT_NAME"]
    
    # Inventory JSON from the collector phase
    target_json_blob = os.environ["TARGET_JSON_BLOB"] 
    
    # Future inputs for the digest (gracefully fallback if not yet passed by workflow)
    sar_json_blob = os.environ.get("SAR_JSON_BLOB", "")
    poam_json_blob = os.environ.get("POAM_JSON_BLOB", "")
    framework_json_blob = os.environ.get("FRAMEWORK_JSON_BLOB", "")
    
    recipient_address = os.environ["RECIPIENT_EMAIL"]
    foundry_deployment = "gpt-5.1"  
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    
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

    # 2. Setup Blob & AI Clients
    blob_service_url = f"https://{storage_account_name}.blob.core.windows.net"
    container_client = BlobServiceClient(account_url=blob_service_url, credential=cred).get_container_client("reports")
    
    token_provider = cred.get_token("https://cognitiveservices.azure.com/.default")
    ai_client = AzureOpenAI(
        azure_endpoint=foundry_endpoint,
        azure_ad_token_provider=lambda: token_provider.token,
        api_version="2024-02-15-preview"
    )

    # --- PART 1: THE SDR (OSCAL GENERATION) ---
    print(f"\n--- Starting SDR OSCAL Generation ---")
    print(f"Retrieving raw inventory facts from {target_json_blob}...")
    inventory_evidence = container_client.get_blob_client(target_json_blob).download_blob().readall().decode("utf-8")
    
    with open("prompts/sdr.md", "r") as f:
        sdr_prompt = f.read()
    
    # Archive the SDR prompt
    upload_to_worm(container_client, f"prompt-sdr-{timestamp}.md", sdr_prompt)

    # Minify the JSON and cap it to 50 items to fit sandbox TPM quotas
    inventory_data = json.loads(inventory_evidence)
    minified_inventory = json.dumps(inventory_data[:5], separators=(',', ':'))
    
    print(f"Generating OSCAL SDR via {foundry_deployment}...")
    oscal_sdr = generate_ai_content(ai_client, foundry_deployment, sdr_prompt, f"INPUT: {minified_inventory}")
    
    oscal_filename = target_json_blob.replace(".json", "-oscal-sdr.json")
    upload_to_worm(container_client, oscal_filename, oscal_sdr)

    print("\n[Rate Limit Cooldown] Sleeping for 60 seconds to let Azure AI token bucket refill...")
    time.sleep(90)

    
    
    # --- PART 2: THE EXECUTIVE DIGEST (PROSE GENERATION) ---
    print(f"\n--- Starting Executive Digest Generation ---")
    
    # Fetch additional reports if they were passed into the pipeline
    digest_inputs = {}
    for name, blob_name in [("SAR", sar_json_blob), ("POAM", poam_json_blob), ("FRAMEWORK", framework_json_blob)]:
        if blob_name:
            print(f"Retrieving {name} facts from {blob_name}...")
            try:
                digest_inputs[name] = container_client.get_blob_client(blob_name).download_blob().readall().decode("utf-8")
            except ResourceNotFoundError:
                print(f"  -> WARNING: {blob_name} not found. Skipping.")
                digest_inputs[name] = "NO DATA PROVIDED FOR THIS RUN"
        else:
            digest_inputs[name] = "NO DATA PROVIDED FOR THIS RUN"

    with open("prompts/digest.md", "r") as f:
        digest_prompt = f.read()[:400] # Trim the system prompt to save tokens

    # Archive the Digest prompt
    upload_to_worm(container_client, f"prompt-digest-{timestamp}.md", digest_prompt)
    
    print(f"Generating Executive Digest via {foundry_deployment}...")
    digest_user_content = f"INPUTS:\nSAR: {digest_inputs['SAR']}\nPOAM: {digest_inputs['POAM']}\nFRAMEWORK: {digest_inputs['FRAMEWORK']}"
    digest_md = generate_ai_content(ai_client, foundry_deployment, digest_prompt, digest_user_content)
    
    digest_filename = f"executive-digest-{timestamp}.md"
    upload_to_worm(container_client, digest_filename, digest_md)
    
    
    
    # --- PART 3: DISPATCH ---
    print("\n--- Dispatching Executive Digest to Stakeholders ---")
    email_client = EmailClient(acs_endpoint, cred)
    message = {
        "senderAddress": f"donotreply@{sender_address}",
        "recipients": {"to": [{"address": recipient_address}]},
        "content": {
            "subject": "Weekly System Security Plan & Compliance Digest",
            "plainText": digest_md,
            "html": f"<html><body>{digest_md}</body></html>"
        }
    }
    email_client.begin_send(message).result()
    print("Digest successfully delivered.")

if __name__ == "__main__":
    main()