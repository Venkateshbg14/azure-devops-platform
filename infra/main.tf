resource "azurerm_resource_group" "main" {
  name     = "rg-${var.project}-${var.location}"
  location = var.location

  tags = {
    project    = var.project
    managed_by = "terraform"
  }
}