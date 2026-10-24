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