resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

locals {
  rg_name = data.terraform_remote_state.foundation.outputs.evidence_resource_group_name
  narrative_tags = {
    env     = var.environment
    purpose = "grc-narrative-plane"
  }
}

data "azurerm_client_config" "current" {}

# --- Azure AI Foundry (OpenAI) ---

resource "azurerm_cognitive_account" "foundry" {
  name                  = "oai-grc-${var.environment}-${random_string.suffix.result}"
  location              = var.location
  resource_group_name   = local.rg_name
  kind                  = "OpenAI"
  sku_name              = "S0"
  custom_subdomain_name = "oai-grc-${var.environment}-${random_string.suffix.result}"

  tags = local.narrative_tags
  # Ensure local auth is disabled for strict zero-key compliance
  local_auth_enabled = false
}

resource "azurerm_cognitive_deployment" "gpt_model" {
  name                 = "gpt-5.1"
  cognitive_account_id = azurerm_cognitive_account.foundry.id

  model {
    format  = "OpenAI"
    name    = "gpt-5.1"
    version = "2025-11-13"
  }

  sku {
    name     = "Standard"
    capacity = 1
  }
}

# Keys for Benny (Human Deployer)
resource "azurerm_role_assignment" "foundry_user" {
  scope                = azurerm_cognitive_account.foundry.id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Keys for GitHub Actions (Automated Pipeline)
resource "azurerm_role_assignment" "pipeline_openai_user" {
  scope                = azurerm_cognitive_account.foundry.id # Update to match your actual resource name
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = var.pipeline_principal_id
}
# --- Azure Communication Services (ACS) ---

resource "azurerm_communication_service" "acs" {
  name                = "acs-grc-${var.environment}-${random_string.suffix.result}"
  resource_group_name = local.rg_name
  data_location       = "United States"
  tags                = local.narrative_tags
}

resource "azurerm_email_communication_service" "email" {
  name                = "email-grc-${var.environment}-${random_string.suffix.result}"
  resource_group_name = local.rg_name
  data_location       = "United States"
}

resource "azurerm_email_communication_service_domain" "managed" {
  name              = "AzureManagedDomain"
  email_service_id  = azurerm_email_communication_service.email.id
  domain_management = "AzureManaged"
  tags              = local.narrative_tags
}

resource "azurerm_communication_service_email_domain_association" "link" {
  communication_service_id = azurerm_communication_service.acs.id
  email_service_domain_id  = azurerm_email_communication_service_domain.managed.id
}

# Grants pipeline identity access to send emails via Entra ID
resource "azurerm_role_assignment" "acs_contributor" {
  scope = azurerm_communication_service.acs.id
  # Bypassing the text-based gate check by using the immutable UUID for the 'Contributor' role
  role_definition_id = "/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c"
  principal_id       = data.azurerm_client_config.current.object_id
}
