# --- Action Group for Security Alerts ---
# Routes the tripwire alerts to the owner's email address defined in variables.

resource "azurerm_monitor_action_group" "security_operations" {
  name                = "ag-grc-secops"
  resource_group_name = azurerm_resource_group.sandbox.name
  short_name          = "GRCSecOps"

  email_receiver {
    name                    = "PrimaryOwner"
    email_address           = var.owner_email
    use_common_alert_schema = true
  }
}

# --- KQL Tripwire 1: Key Vault Secret Reads ---

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "kv_secret_reads" {
  name                = "alert-kv-secret-reads"
  resource_group_name = azurerm_resource_group.sandbox.name
  location            = var.location
  scopes              = [azurerm_log_analytics_workspace.grc.id]
  description         = "CRITICAL: A Key Vault secret was read by a non-pipeline identity."
  severity            = 1
  evaluation_frequency= "PT15M" # Evaluates every 15 minutes
  window_duration     = "PT15M" # Looks at the last 15 minutes of logs

  criteria {
    query                   = <<-KQL
      AzureDiagnostics
      | where ResourceProvider == "MICROSOFT.KEYVAULT"
      | where OperationName == "SecretGet"
      // Ignores the automated remediation identity. If your GitHub Actions uses a separate 
      // service principal, add its Object ID here as well.
      | where identity_claim_http_schemas_microsoft_com_identity_claims_objectidentifier_g != "${azurerm_user_assigned_identity.remediation.principal_id}"
      | project TimeGenerated, OperationName, KeyVault = Resource, SecretName = id_s, CallerIPAddress, CallerPrincipalId = identity_claim_http_schemas_microsoft_com_identity_claims_objectidentifier_g
    KQL
    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"
  }

  action {
    action_groups = [azurerm_monitor_action_group.security_operations.id]
  }
}

# --- KQL Tripwire 2: Admin Writes Outside Business Hours ---

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "out_of_hours_admin" {
  name                = "alert-out-of-hours-admin"
  resource_group_name = azurerm_resource_group.sandbox.name
  location            = var.location
  scopes              = [azurerm_log_analytics_workspace.grc.id]
  description         = "WARNING: Administrative changes detected outside standard business hours."
  severity            = 2
  evaluation_frequency= "PT1H" # Evaluates hourly
  window_duration     = "PT1H" 

  criteria {
    query                   = <<-KQL
      AzureActivity
      | where CategoryValue == "Administrative"
      | where OperationNameValue endswith "write" or OperationNameValue endswith "delete"
      | extend DayOfWeek = dayofweek(TimeGenerated)
      | extend HourOfDay = hourofday(TimeGenerated)
      // Flags weekends (0=Sun, 6=Sat) or times before 8am / after 6pm UTC
      | where DayOfWeek in (0, 6) or HourOfDay < 8 or HourOfDay >= 18
      | project TimeGenerated, OperationNameValue, Caller, ResourceGroup, ResourceId, ActivityStatusValue
    KQL
    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"
  }

  action {
    action_groups = [azurerm_monitor_action_group.security_operations.id]
  }
}

# --- KQL Tripwire 3: Manual RBAC Assignments ---

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "manual_rbac" {
  name                = "alert-manual-rbac"
  resource_group_name = azurerm_resource_group.sandbox.name
  location            = var.location
  scopes              = [azurerm_log_analytics_workspace.grc.id]
  description         = "CRITICAL: A role assignment was created manually, bypassing IaC."
  severity            = 1
  evaluation_frequency= "PT15M"
  window_duration     = "PT15M"

  criteria {
    query                   = <<-KQL
      AzureActivity
      | where OperationNameValue == "Microsoft.Authorization/roleAssignments/write"
      | where ActivityStatusValue == "Success"
      | where Caller != "${azurerm_user_assigned_identity.remediation.principal_id}" 
      | extend Scope = tostring(parse_json(Authorization).scope)
      | project TimeGenerated, Caller, OperationNameValue, Scope, ResourceGroup
    KQL
    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"
  }

  action {
    action_groups = [azurerm_monitor_action_group.security_operations.id]
  }
}

# --- KQL Tripwire 4: PIM Role Activations ---

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "pim_activations" {
  name                = "alert-pim-activations"
  resource_group_name = azurerm_resource_group.sandbox.name
  location            = var.location
  scopes              = [azurerm_log_analytics_workspace.grc.id]
  description         = "INFO: A Privileged Identity Management (PIM) role was successfully activated."
  severity            = 3
  evaluation_frequency= "PT1H"
  window_duration     = "PT1H"

  criteria {
    query                   = <<-KQL
      AuditLogs
      | where LoggedByService == "PIM" or Category == "RoleManagement"
      | where OperationName == "Add member to role completed (PIM activation)"
      | extend Initiator = tostring(InitiatedBy.user.userPrincipalName)
      | extend RoleActivated = tostring(TargetResources[0].displayName)
      | extend TargetUser = tostring(TargetResources[2].displayName)
      | project TimeGenerated, Initiator, TargetUser, RoleActivated, Result, ResultReason
    KQL
    time_aggregation_method = "Count"
    threshold               = 0
    operator                = "GreaterThan"
  }

  action {
    action_groups = [azurerm_monitor_action_group.security_operations.id]
  }
}