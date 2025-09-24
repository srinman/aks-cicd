# RBAC Module Outputs

output "cluster_admins_group_id" {
  description = "Object ID of the cluster admins Azure AD group"
  value       = var.create_ad_groups ? azuread_group.cluster_admins[0].object_id : null
}

output "hub_operators_group_id" {
  description = "Object ID of the hub operators Azure AD group"
  value       = var.create_ad_groups ? azuread_group.hub_operators[0].object_id : null
}

output "spoke_developers_group_ids" {
  description = "Map of spoke environment names to their developer group object IDs"
  value = var.create_ad_groups ? {
    for env, group in azuread_group.spoke_developers : env => group.object_id
  } : {}
}

output "custom_role_definition_id" {
  description = "Resource ID of the custom ArgoCD hub operator role definition"
  value       = azurerm_role_definition.argocd_hub_operator.role_definition_resource_id
}

output "key_vault_id" {
  description = "Resource ID of the Key Vault (if created)"
  value       = var.create_key_vault ? azurerm_key_vault.cluster_secrets[0].id : null
}

output "key_vault_uri" {
  description = "URI of the Key Vault (if created)"
  value       = var.create_key_vault ? azurerm_key_vault.cluster_secrets[0].vault_uri : null
}

output "role_assignments" {
  description = "Summary of role assignments created"
  value = {
    hub_spoke_access = {
      for rg_name, rg_id in var.spoke_resource_group_ids : rg_name => {
        resource_group_id = rg_id
        role             = "Azure Kubernetes Service Cluster User Role"
        principal_id     = var.hub_identity_principal_id
      }
    }
    custom_role_assigned = {
      scope        = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
      role_id      = azurerm_role_definition.argocd_hub_operator.role_definition_resource_id
      principal_id = var.hub_identity_principal_id
    }
  }
}

# Data source reference for use in other modules
data "azurerm_client_config" "current" {}