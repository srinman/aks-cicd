# RBAC Module for AKS Hub-Spoke Architecture
# This module manages Azure RBAC and Kubernetes RBAC for the hub-spoke setup

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.0"
    }
  }
}

# Data sources
data "azurerm_client_config" "current" {}

# Create Azure AD groups for different levels of access
resource "azuread_group" "cluster_admins" {
  count            = var.create_ad_groups ? 1 : 0
  display_name     = "${var.organization_prefix}-aks-cluster-admins"
  description      = "AKS Cluster Administrators - Full access to all clusters"
  security_enabled = true
  owners           = [data.azurerm_client_config.current.object_id]
}

resource "azuread_group" "hub_operators" {
  count            = var.create_ad_groups ? 1 : 0
  display_name     = "${var.organization_prefix}-aks-hub-operators"
  description      = "AKS Hub Operators - Full access to hub cluster, read access to spokes"
  security_enabled = true
  owners           = [data.azurerm_client_config.current.object_id]
}

resource "azuread_group" "spoke_developers" {
  for_each         = var.create_ad_groups ? var.spoke_environments : {}
  display_name     = "${var.organization_prefix}-aks-${each.key}-developers"
  description      = "AKS ${each.key} Developers - Application access to ${each.key} spoke cluster"
  security_enabled = true
  owners           = [data.azurerm_client_config.current.object_id]
}

# Subscription-level role assignments for hub identity
resource "azurerm_role_assignment" "hub_subscription_reader" {
  count                = var.grant_subscription_reader ? 1 : 0
  scope                = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
  role_definition_name = "Reader"
  principal_id         = var.hub_identity_principal_id
}

# Custom role definition for ArgoCD hub operations
resource "azurerm_role_definition" "argocd_hub_operator" {
  name        = "${var.organization_prefix}-ArgoCD-Hub-Operator"
  scope       = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
  description = "Custom role for ArgoCD hub cluster operations across spoke clusters"

  permissions {
    actions = [
      # AKS cluster access
      "Microsoft.ContainerService/managedClusters/read",
      "Microsoft.ContainerService/managedClusters/listClusterUserCredential/action",
      "Microsoft.ContainerService/managedClusters/listClusterMonitoringUserCredential/action",
      
      # Resource group operations
      "Microsoft.Resources/resourceGroups/read",
      
      # Managed identity operations
      "Microsoft.ManagedIdentity/userAssignedIdentities/read",
      "Microsoft.ManagedIdentity/userAssignedIdentities/assign/action",
      
      # Key Vault operations (for secrets management)
      "Microsoft.KeyVault/vaults/read",
      "Microsoft.KeyVault/vaults/secrets/read",
      
      # Monitoring and logging
      "Microsoft.Insights/components/read",
      "Microsoft.OperationalInsights/workspaces/read",
      
      # Network operations (minimal)
      "Microsoft.Network/virtualNetworks/read",
      "Microsoft.Network/virtualNetworks/subnets/read"
    ]
    
    not_actions = []
    
    data_actions = [
      # Allow reading secrets from Key Vault
      "Microsoft.KeyVault/vaults/secrets/getSecret/action"
    ]
    
    not_data_actions = []
  }

  assignable_scopes = [
    "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
  ]
}

# Role assignments for spoke resource groups
resource "azurerm_role_assignment" "hub_spoke_access" {
  for_each             = var.spoke_resource_group_ids
  scope                = each.value
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = var.hub_identity_principal_id
}

resource "azurerm_role_assignment" "hub_spoke_reader" {
  for_each             = var.spoke_resource_group_ids
  scope                = each.value
  role_definition_name = "Reader"
  principal_id         = var.hub_identity_principal_id
}

# Assign the custom role to the hub identity
resource "azurerm_role_assignment" "hub_custom_role" {
  scope              = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
  role_definition_id = azurerm_role_definition.argocd_hub_operator.role_definition_resource_id
  principal_id       = var.hub_identity_principal_id
}

# Azure RBAC for Kubernetes - Cluster Admin access
resource "azurerm_role_assignment" "cluster_admin_hub" {
  count                = var.create_ad_groups ? 1 : 0
  scope                = var.hub_cluster_id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = azuread_group.cluster_admins[0].object_id
}

resource "azurerm_role_assignment" "cluster_admin_spokes" {
  for_each             = var.create_ad_groups ? var.spoke_cluster_ids : {}
  scope                = each.value
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = azuread_group.cluster_admins[0].object_id
}

# Azure RBAC for Kubernetes - Hub operators access
resource "azurerm_role_assignment" "hub_operator_access" {
  count                = var.create_ad_groups ? 1 : 0
  scope                = var.hub_cluster_id
  role_definition_name = "Azure Kubernetes Service RBAC Admin"
  principal_id         = azuread_group.hub_operators[0].object_id
}

# Azure RBAC for Kubernetes - Spoke developers access
resource "azurerm_role_assignment" "spoke_developer_access" {
  for_each             = var.create_ad_groups ? var.spoke_cluster_ids : {}
  scope                = each.value
  role_definition_name = "Azure Kubernetes Service RBAC Writer"
  principal_id         = azuread_group.spoke_developers[each.key].object_id
}

# Create Key Vault for storing cluster secrets (optional)
resource "azurerm_key_vault" "cluster_secrets" {
  count                      = var.create_key_vault ? 1 : 0
  name                       = "${var.organization_prefix}-aks-secrets-kv"
  location                   = var.key_vault_location
  resource_group_name        = var.key_vault_resource_group
  enabled_for_disk_encryption = true
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  soft_delete_retention_days = 7
  purge_protection_enabled   = false
  sku_name                   = "standard"

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = var.hub_identity_principal_id

    secret_permissions = [
      "Get",
      "List",
      "Set",
      "Delete",
      "Recover",
      "Backup",
      "Restore"
    ]
  }

  # Access policy for the current user (for initial setup)
  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id

    secret_permissions = [
      "Get",
      "List",
      "Set",
      "Delete",
      "Recover",
      "Backup",
      "Restore"
    ]
  }

  tags = var.common_tags
}

# Store hub cluster information in Key Vault
resource "azurerm_key_vault_secret" "hub_cluster_info" {
  count        = var.create_key_vault ? 1 : 0
  name         = "hub-cluster-config"
  value        = jsonencode({
    cluster_id   = var.hub_cluster_id
    cluster_name = var.hub_cluster_name
    endpoint     = var.hub_cluster_endpoint
  })
  key_vault_id = azurerm_key_vault.cluster_secrets[0].id

  depends_on = [azurerm_key_vault.cluster_secrets]
}