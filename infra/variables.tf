variable "subscription_id" {
  type        = string
  description = "Azure subscription ID to deploy into"
}

variable "location" {
  type        = string
  description = "Azure region"
  default     = "eastus"
}

variable "project" {
  type        = string
  description = "Short project name used in resource names"
  default     = "devopsplat"
}

variable "node_vm_size" {
  type        = string
  description = "VM size for AKS nodes"
  default     = "Standard_D2nls_v6"
}

variable "node_count" {
  type        = number
  description = "Number of AKS nodes"
  default     = 2
}

variable "ado_issuer" {
  type        = string
  description = "OIDC issuer URL shown on the Azure DevOps service connection"
  default     = ""
}

variable "ado_subject" {
  type        = string
  description = "OIDC subject identifier shown on the Azure DevOps service connection"
  default     = ""
}