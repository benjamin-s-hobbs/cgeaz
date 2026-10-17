
# Three baseline policies, plus seven capstone policies, bundled into one initiative.
# Assigned once at mg-grc-sandbox. Every subscription inherits it. (CSF: GV.PO, PR.DS, PR.PS)

# --- 1. Require the `env` tag on resource groups ---
# NIST 800-53 Rev 5: CM-8, PM-5 (Inventory hygiene; POA&M owner resolution)
resource "azurerm_policy_definition" "require_env_tag" {
  name                = "cge-require-env-tag-rg"
  display_name        = "Resource groups must carry an env tag"
  policy_type         = "Custom"
  mode                = "All"
  management_group_id = azurerm_management_group.sandbox.id

  parameters = jsonencode({
    effect = {
      type          = "String"
      allowedValues = ["Audit", "Deny", "Disabled"]
      defaultValue  = "Audit"
    }
  })

  policy_rule = jsonencode({
    if = {
      allOf = [
        { field = "type", equals = "Microsoft.Resources/subscriptions/resourceGroups" },
        { field = "tags['env']", exists = "false" }
      ]
    }
    then = { effect = "[parameters('effect')]" }
  })
}

# --- 2. Deny public blob access on storage accounts ---
# NIST 800-53 Rev 5: AC-3, AC-4
resource "azurerm_policy_definition" "deny_public_blob" {
  name                = "cge-deny-public-blob"
  display_name        = "Storage accounts must not allow public blob access"
  policy_type         = "Custom"
  mode                = "Indexed"
  management_group_id = azurerm_management_group.sandbox.id

  parameters = jsonencode({
    effect = {
      type          = "String"
      allowedValues = ["Audit", "Deny", "Disabled"]
      defaultValue  = "Deny"
    }
  })

  policy_rule = jsonencode({
    if = {
      allOf = [
        { field = "type", equals = "Microsoft.Storage/storageAccounts" },
        { field = "Microsoft.Storage/storageAccounts/allowBlobPublicAccess", equals = "true" }
      ]
    }
    then = { effect = "[parameters('effect')]" }
  })
}

# --- 3. DeployIfNotExists: Storage diagnostics to GRC workspace ---
# NIST 800-53 Rev 5: AU-2, AU-12
resource "azurerm_policy_definition" "storage_diagnostics" {
  name                = "cge-dine-storage-diagnostics"
  display_name        = "Storage accounts must route diagnostics to the GRC workspace"
  policy_type         = "Custom"
  mode                = "Indexed"
  management_group_id = azurerm_management_group.sandbox.id

  parameters = jsonencode({
    workspaceId = {
      type     = "String"
      metadata = { displayName = "Log Analytics workspace resource ID" }
    }
  })

  policy_rule = jsonencode({
    if = {
      field  = "type"
      equals = "Microsoft.Storage/storageAccounts"
    }
    then = {
      effect = "DeployIfNotExists"
      details = {
        type = "Microsoft.Insights/diagnosticSettings"
        roleDefinitionIds = [
          "/providers/Microsoft.Authorization/roleDefinitions/749f88d5-cbae-40b8-bcfc-e573ddc772fa"
        ]
        existenceCondition = {
          allOf = [
            { field = "Microsoft.Insights/diagnosticSettings/workspaceId", equals = "[parameters('workspaceId')]" }
          ]
        }
        deployment = {
          properties = {
            mode = "incremental"
            parameters = {
              resourceName = { value = "[field('name')]" }
              workspaceId  = { value = "[parameters('workspaceId')]" }
              location     = { value = "[field('location')]" }
            }
            template = {
              "$schema"      = "https://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#"
              contentVersion = "1.0.0.0"
              parameters = {
                resourceName = { type = "string" }
                workspaceId  = { type = "string" }
                location     = { type = "string" }
              }
              resources = [
                {
                  type       = "Microsoft.Storage/storageAccounts/providers/diagnosticSettings"
                  apiVersion = "2021-05-01-preview"
                  name       = "[concat(parameters('resourceName'), '/Microsoft.Insights/ds-to-grc-workspace')]"
                  properties = {
                    workspaceId = "[parameters('workspaceId')]"
                    metrics = [
                      { category = "Transaction", enabled = true }
                    ]
                  }
                }
              ]
            }
          }
        }
      }
    }
  })
}

# --- 4. Key Vault Purge Protection ---
# NIST 800-53 Rev 5: CP-9, SI-12
resource "azurerm_policy_definition" "kv_purge_protection" {
  name                = "cge-require-kv-purge-protection"
  display_name        = "Key vaults must have purge protection enabled"
  policy_type         = "Custom"
  mode                = "Indexed"
  management_group_id = azurerm_management_group.sandbox.id

  # BLAST RADIUS: A Deny effect blocks the creation of Key Vaults missing 'purge_protection_enabled = true'. 
  # It prevents malicious or accidental permanent deletion of cryptographic material.

  parameters = jsonencode({
    effect = {
      type          = "String"
      allowedValues = ["Audit", "Deny", "Disabled"]
      defaultValue  = "Audit"
    }
  })

  policy_rule = jsonencode({
    if = {
      allOf = [
        { field = "type", equals = "Microsoft.KeyVault/vaults" },
        { field = "Microsoft.KeyVault/vaults/enablePurgeProtection", notEquals = "true" }
      ]
    }
    then = { effect = "[parameters('effect')]" }
  })
}

# --- 5. App Service Minimum TLS Version ---
# NIST 800-53 Rev 5: SC-8
resource "azurerm_policy_definition" "app_service_tls" {
  name                = "cge-require-app-tls-1-2"
  display_name        = "App Services must require minimum TLS version 1.2"
  policy_type         = "Custom"
  mode                = "Indexed"
  management_group_id = azurerm_management_group.sandbox.id

  # BLAST RADIUS: A Deny effect blocks the creation of App Services configured for TLS 1.0 or 1.1. 
  # Modifying an existing app will fail unless its TLS version is simultaneously upgraded.

  parameters = jsonencode({
    effect = {
      type          = "String"
      allowedValues = ["Audit", "Deny", "Disabled"]
      defaultValue  = "Audit"
    }
  })

  policy_rule = jsonencode({
    if = {
      allOf = [
        { field = "type", equals = "Microsoft.Web/sites" },
        { field = "Microsoft.Web/sites/siteConfig.minTlsVersion", notEquals = "1.2" }
      ]
    }
    then = { effect = "[parameters('effect')]" }
  })
}

# --- 6. Storage Account Customer-Managed Keys (CMEK) ---
# NIST 800-53 Rev 5: SC-28, SC-12
resource "azurerm_policy_definition" "storage_cmek" {
  name                = "cge-require-storage-cmek"
  display_name        = "Storage accounts must use customer-managed keys for encryption"
  policy_type         = "Custom"
  mode                = "Indexed"
  management_group_id = azurerm_management_group.sandbox.id

  # BLAST RADIUS: A Deny effect blocks standard storage account creations relying on Microsoft-managed keys. 
  # Engineers must provision a Key Vault and cryptographic key prior to deploying storage.

  parameters = jsonencode({
    effect = {
      type          = "String"
      allowedValues = ["Audit", "Deny", "Disabled"]
      defaultValue  = "Audit"
    }
  })

  policy_rule = jsonencode({
    if = {
      allOf = [
        { field = "type", equals = "Microsoft.Storage/storageAccounts" },
        { field = "Microsoft.Storage/storageAccounts/encryption.keySource", notEquals = "Microsoft.Keyvault" }
      ]
    }
    then = { effect = "[parameters('effect')]" }
  })
}

# --- 7. Cosmos DB Private Endpoint Only ---
# NIST 800-53 Rev 5: SC-7
resource "azurerm_policy_definition" "cosmos_private_endpoint" {
  name                = "cge-require-cosmos-private-endpoint"
  display_name        = "Cosmos DB accounts must disable public network access"
  policy_type         = "Custom"
  mode                = "Indexed"
  management_group_id = azurerm_management_group.sandbox.id

  # BLAST RADIUS: A Deny effect blocks Cosmos DB creation unless 'public_network_access_enabled = false'. 
  # Forces data-plane traffic onto a Private Endpoint.


  parameters = jsonencode({
    effect = {
      type          = "String"
      allowedValues = ["Audit", "Deny", "Disabled"]
      defaultValue  = "Audit"
    }
  })

  policy_rule = jsonencode({
    if = {
      allOf = [
        { field = "type", equals = "Microsoft.DocumentDB/databaseAccounts" },
        { field = "Microsoft.DocumentDB/databaseAccounts/publicNetworkAccess", notEquals = "Disabled" }
      ]
    }
    then = { effect = "[parameters('effect')]" }
  })
}

# --- 8. Deny Public IPs on Network Interfaces ---
# NIST 800-53 Rev 5: SC-7
resource "azurerm_policy_definition" "deny_nic_public_ip" {
  name                = "cge-deny-nic-public-ip"
  display_name        = "Network Interfaces must not have public IP addresses"
  policy_type         = "Custom"
  mode                = "Indexed"
  management_group_id = azurerm_management_group.sandbox.id

  # BLAST RADIUS: A Deny effect blocks the creation of any VM or NIC attempting to attach a Public IP directly. 
  # Workloads must route through a NAT Gateway, Load Balancer, or Bastion.

  parameters = jsonencode({
    effect = {
      type          = "String"
      allowedValues = ["Audit", "Deny", "Disabled"]
      defaultValue  = "Audit"
    }
  })

  policy_rule = jsonencode({
    if = {
      allOf = [
        { field = "type", equals = "Microsoft.Network/networkInterfaces" },
        { field = "Microsoft.Network/networkInterfaces/ipConfigurations[*].publicIpAddress.id", exists = "true" }
      ]
    }
    then = { effect = "[parameters('effect')]" }
  })
}

# --- 9. Require Azure SQL Transparent Data Encryption ---
# NIST 800-53 Rev 5: SC-28
resource "azurerm_policy_definition" "sql_tde" {
  name                = "cge-require-sql-tde"
  display_name        = "Azure SQL databases must have Transparent Data Encryption enabled"
  policy_type         = "Custom"
  mode                = "Indexed"
  management_group_id = azurerm_management_group.sandbox.id

  # BLAST RADIUS: A Deny effect intercepts the explicit 'transparentDataEncryption' child resource, 
  # blocking any attempt to set 'transparent_data_encryption_enabled = false'.

  parameters = jsonencode({
    effect = {
      type          = "String"
      allowedValues = ["Audit", "Deny", "Disabled"]
      defaultValue  = "Audit"
    }
  })

  policy_rule = jsonencode({
    if = {
      allOf = [
        { field = "type", equals = "Microsoft.Sql/servers/databases/transparentDataEncryption" },
        { field = "Microsoft.Sql/servers/databases/transparentDataEncryption/state", equals = "Disabled" }
      ]
    }
    then = { effect = "[parameters('effect')]" }
  })
}

# --- 10. Require Subscription Scope Owner ---
# NIST 800-53 Rev 5: AC-6
resource "azurerm_policy_definition" "sub_scope_owner" {
  name                = "cge-require-sub-owner"
  display_name        = "Subscriptions must have at least one Owner assigned"
  policy_type         = "Custom"
  mode                = "All"
  management_group_id = azurerm_management_group.sandbox.id

  # BLAST RADIUS: Operates in AuditIfNotExists mode to evaluate an external Role Assignment resource. 
  # Will not block deployments, but flags subscriptions missing the Owner role GUID (8e3af657-a8ff-443c-a75c-2fe8c4bcb635).

  parameters = jsonencode({
    effect = {
      type          = "String"
      allowedValues = ["AuditIfNotExists", "Disabled"]
      defaultValue  = "AuditIfNotExists"
    }
  })

  policy_rule = jsonencode({
    if = {
      field  = "type"
      equals = "Microsoft.Resources/subscriptions"
    }
    then = {
      effect = "[parameters('effect')]"
      details = {
        type = "Microsoft.Authorization/roleAssignments"
        existenceCondition = {
          allOf = [
            {
              field    = "Microsoft.Authorization/roleAssignments/roleDefinitionId"
              contains = "8e3af657-a8ff-443c-a75c-2fe8c4bcb635"
            }
          ]
        }
      }
    }
  })
}

# --- The initiative: one assignment, whole-sandbox inheritance ---

resource "azurerm_management_group_policy_set_definition" "grc_baseline" {
  name                = "cge-grc-baseline"
  display_name        = "CGE-AZ GRC Baseline"
  policy_type         = "Custom"
  management_group_id = azurerm_management_group.sandbox.id

  parameters = jsonencode({
    tagEffect         = { type = "String", defaultValue = "Audit" }
    publicBlobEffect  = { type = "String", defaultValue = "Deny" }
    workspaceId       = { type = "String" }
    kvPurgeEffect     = { type = "String", defaultValue = "Audit" }
    appTlsEffect      = { type = "String", defaultValue = "Audit" }
    storageCmekEffect = { type = "String", defaultValue = "Audit" }
    cosmosPeEffect    = { type = "String", defaultValue = "Audit" }
    nicPublicIpEffect = { type = "String", defaultValue = "Audit" }
    sqlTdeEffect      = { type = "String", defaultValue = "Audit" }
    subOwnerEffect    = { type = "String", defaultValue = "AuditIfNotExists" }
  })

  # Existing references
  policy_definition_reference {
    policy_definition_id = azurerm_policy_definition.require_env_tag.id
    parameter_values     = jsonencode({ effect = { value = "[parameters('tagEffect')]" } })
  }

  policy_definition_reference {
    policy_definition_id = azurerm_policy_definition.deny_public_blob.id
    parameter_values     = jsonencode({ effect = { value = "[parameters('publicBlobEffect')]" } })
  }

  policy_definition_reference {
    policy_definition_id = azurerm_policy_definition.storage_diagnostics.id
    parameter_values     = jsonencode({ workspaceId = { value = "[parameters('workspaceId')]" } })
  }

  # Capstone references
  policy_definition_reference {
    policy_definition_id = azurerm_policy_definition.kv_purge_protection.id
    parameter_values     = jsonencode({ effect = { value = "[parameters('kvPurgeEffect')]" } })
  }

  policy_definition_reference {
    policy_definition_id = azurerm_policy_definition.app_service_tls.id
    parameter_values     = jsonencode({ effect = { value = "[parameters('appTlsEffect')]" } })
  }

  policy_definition_reference {
    policy_definition_id = azurerm_policy_definition.storage_cmek.id
    parameter_values     = jsonencode({ effect = { value = "[parameters('storageCmekEffect')]" } })
  }

  policy_definition_reference {
    policy_definition_id = azurerm_policy_definition.cosmos_private_endpoint.id
    parameter_values     = jsonencode({ effect = { value = "[parameters('cosmosPeEffect')]" } })
  }

  policy_definition_reference {
    policy_definition_id = azurerm_policy_definition.deny_nic_public_ip.id
    parameter_values     = jsonencode({ effect = { value = "[parameters('nicPublicIpEffect')]" } })
  }

  policy_definition_reference {
    policy_definition_id = azurerm_policy_definition.sql_tde.id
    parameter_values     = jsonencode({ effect = { value = "[parameters('sqlTdeEffect')]" } })
  }

  policy_definition_reference {
    policy_definition_id = azurerm_policy_definition.sub_scope_owner.id
    parameter_values     = jsonencode({ effect = { value = "[parameters('subOwnerEffect')]" } })
  }
}

resource "azurerm_management_group_policy_assignment" "grc_baseline" {
  name                 = "cge-grc-baseline"
  display_name         = "CGE-AZ GRC Baseline"
  policy_definition_id = azurerm_management_group_policy_set_definition.grc_baseline.id
  management_group_id  = azurerm_management_group.sandbox.id
  location             = var.location

  parameters = jsonencode({
    tagEffect         = { value = var.tag_policy_effect }
    publicBlobEffect  = { value = var.public_blob_policy_effect }
    workspaceId       = { value = azurerm_log_analytics_workspace.grc.id }
    kvPurgeEffect     = { value = "Audit" }
    appTlsEffect      = { value = "Audit" }
    storageCmekEffect = { value = "Audit" }
    cosmosPeEffect    = { value = "Audit" }
    nicPublicIpEffect = { value = "Audit" }
    sqlTdeEffect      = { value = "Audit" }
    subOwnerEffect    = { value = "AuditIfNotExists" }
  })

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.remediation.id]
  }
}