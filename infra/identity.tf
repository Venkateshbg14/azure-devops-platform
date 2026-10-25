data "azurerm_client_config" "current" {}

resource "azurerm_user_assigned_identity" "pipeline" {
  name                = "id-${var.project}-pipeline"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  tags = azurerm_resource_group.main.tags
}

resource "azurerm_role_assignment" "pipeline_acr_push" {
  scope                            = azurerm_container_registry.main.id
  role_definition_name             = "AcrPush"
  principal_id                     = azurerm_user_assigned_identity.pipeline.principal_id
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "pipeline_aks_user" {
  scope                            = azurerm_kubernetes_cluster.main.id
  role_definition_name             = "Azure Kubernetes Service Cluster User Role"
  principal_id                     = azurerm_user_assigned_identity.pipeline.principal_id
  skip_service_principal_aad_check = true
}

resource "azurerm_federated_identity_credential" "pipeline" {
  count = var.ado_subject == "" ? 0 : 1

  name      = "ado-service-connection"
  parent_id = azurerm_user_assigned_identity.pipeline.id
  audience  = ["api://AzureADTokenExchange"]
  issuer    = var.ado_issuer
  subject   = var.ado_subject
}