output "foundry_endpoint" {
  description = "The endpoint URL for Azure AI Foundry"
  value       = azurerm_cognitive_account.foundry.endpoint
}

output "acs_endpoint" {
  description = "The endpoint URL for Azure Communication Services"
  value       = "https://${azurerm_communication_service.acs.name}.communication.azure.com"
}

output "acs_sender_address" {
  description = "The Azure Managed DoNotReply sender address"
  value       = azurerm_email_communication_service_domain.managed.from_sender_domain
}