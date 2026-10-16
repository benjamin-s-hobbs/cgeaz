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
  default     = "gpt-4o-mini"
}

variable "recipient_email" {
  type        = string
  description = "The ISSO/CISO distribution email address for the weekly digest"
}