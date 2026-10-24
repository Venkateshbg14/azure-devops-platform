terraform {
  backend "azurerm" {
    resource_group_name  = "rg-tfstate-eastus"
    storage_account_name = "sttfstate72852"
    container_name       = "tfstate"
    key                  = "platform.terraform.tfstate"
    use_azuread_auth     = true
  }
}