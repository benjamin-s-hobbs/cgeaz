variable "location" {
  type    = string
  default = "westus3"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "foundry_deployment_name" {
  type        = string
  description = "The name of the Azure OpenAI deployment"
  default     = "gpt-5.1"
}

variable "recipient_email" {
  type        = string
  description = "The ISSO/CISO distribution email address for the weekly digest"
  
}

variable "state_resource_group" {
  type        = string
  description = "The name of the resource group containing the Terraform state storage account"
  default     = "rg-grc-tfstate" # Safe to default since the bootstrap script hardcodes this RG name
}

variable "state_storage_account" {
  type        = string
  description = "The dynamically generated name of the Terraform state storage account"
  # No default here, because this name is dynamically generated based on your subscription ID
}

variable "pipeline_principal_id" {
  description = "The Object ID of the Service Principal running the pipeline"
  type        = string
}