import os
from datetime import datetime, timezone
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient
from azure.core.exceptions import ResourceNotFoundError
from azure.communication.email import EmailClient
from azure.mgmt.resourcegraph import ResourceGraphClient
from azure.mgmt.resourcegraph.models import QueryRequest
from openai import AzureOpenAI

def upload_to_worm(container_client, filename, content):
    print(f"Locking artifact into WORM storage as {filename}...")
    container_client.get_blob_client(filename).upload_blob(content, overwrite=False)

def generate_ai_content(ai_client, deployment, system_prompt, user_content):
    response = ai_client.chat.completions.create(
        model=deployment,
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_content}
        ],
        temperature=0.1,
        max_completion_tokens=250 # Strictly throttled output limit
    )
    return response.choices[0].message.content

def main():
    cred = DefaultAzureCredential()
    subscription_id = os.environ["AZURE_SUBSCRIPTION_ID"]
    storage_account_name = os.environ["STORAGE_ACCOUNT_NAME"]
    recipient_address = os.environ["RECIPIENT_EMAIL"]
    
    sar_json_blob = os.environ.get("SAR_JSON_BLOB", "")
    poam_json_blob = os.environ.get("POAM_JSON_BLOB", "")
    framework_json_blob = os.environ.get("FRAMEWORK_JSON_BLOB", "")
    
    foundry_deployment = "gpt-5.1"  
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    
    print("Locating Azure AI Foundry and ACS endpoints...")
    arg_client = ResourceGraphClient(credential=cred)
    narrative_query = """
    Resources
    | where tags['purpose'] == 'grc-narrative-plane'
    | project type, name, properties.endpoint, properties.fromSenderDomain
    """
    narrative_res = arg_client.resources(QueryRequest(subscriptions=[subscription_id], query=narrative_query))
    
    foundry_endpoint, acs_endpoint, sender_address = None, None, None
    for item in narrative_res.data:
        if 'cognitiveservices' in item['type'].lower():
            foundry_endpoint = item['properties_endpoint']
        elif 'communicationservices' in item['type'].lower():
            acs_endpoint = f"https://{item['name']}.communication.azure.com"
        elif 'emailservices/domains' in item['type'].lower():
            sender_address = item['properties_fromSenderDomain']
            
    if not foundry_endpoint or not acs_endpoint or not sender_address:
        raise Exception("Could not discover all required narrative plane resources.")

    blob_service_url = f"https://{storage_account_name}.blob.core.windows.net"
    container_client = BlobServiceClient(account_url=blob_service_url, credential=cred).get_container_client("reports")
    
    token_provider = cred.get_token("https://cognitiveservices.azure.com/.default")
    ai_client = AzureOpenAI(
        azure_endpoint=foundry_endpoint,
        azure_ad_token_provider=lambda: token_provider.token,
        api_version="2024-02-15-preview"
    )

    print(f"\n--- Starting Executive Digest Generation ---")
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

    # Limit the prompt to 300 chars to respect the sandbox quota
    with open("prompts/digest.md", "r") as f:
        digest_prompt = f.read()[:300] 

    upload_to_worm(container_client, f"prompt-digest-{timestamp}.md", digest_prompt)
    
    # Squeeze the inputs tightly to keep the token footprint extremely small
    safe_sar = digest_inputs['SAR'][:150] if digest_inputs['SAR'] else "None"
    safe_poam = digest_inputs['POAM'][:150] if digest_inputs['POAM'] else "None"
    safe_framework = digest_inputs['FRAMEWORK'][:150] if digest_inputs['FRAMEWORK'] else "None"
    
    digest_user_content = f"INPUTS:\nSAR: {safe_sar}\nPOAM: {safe_poam}\nFRAMEWORK: {safe_framework}"
    
    print(f"Generating Executive Digest via {foundry_deployment}...")
    digest_md = generate_ai_content(ai_client, foundry_deployment, digest_prompt, digest_user_content)
    
    upload_to_worm(container_client, f"executive-digest-{timestamp}.md", digest_md)
    
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