# Hub Environment Outputs

output "hub_cluster_id" {
  description = "Hub cluster resource ID"
  value       = module.hub_cluster.cluster_id
}

output "hub_cluster_name" {
  description = "Hub cluster name"
  value       = module.hub_cluster.cluster_name
}

output "hub_cluster_endpoint" {
  description = "Hub cluster API endpoint"
  value       = module.hub_cluster.cluster_endpoint
}

output "hub_identity_principal_id" {
  description = "Hub managed identity principal ID"
  value       = module.hub_cluster.hub_identity_principal_id
  sensitive   = true
}

output "hub_identity_client_id" {
  description = "Hub managed identity client ID"
  value       = module.hub_cluster.hub_identity_client_id
  sensitive   = true
}

output "resource_group_name" {
  description = "Hub resource group name"
  value       = module.hub_cluster.resource_group_name
}

output "kubeconfig" {
  description = "Hub cluster kubeconfig"
  value       = module.hub_cluster.kubeconfig
  sensitive   = true
}

# RBAC Outputs
output "cluster_admins_group_id" {
  description = "Cluster admins Azure AD group ID"
  value       = module.rbac_config.cluster_admins_group_id
}

output "hub_operators_group_id" {
  description = "Hub operators Azure AD group ID"
  value       = module.rbac_config.hub_operators_group_id
}

output "key_vault_id" {
  description = "Key Vault resource ID"
  value       = module.rbac_config.key_vault_id
}

output "custom_role_definition_id" {
  description = "Custom ArgoCD role definition ID"
  value       = module.rbac_config.custom_role_definition_id
}

# Instructions for next steps
output "next_steps" {
  description = "Next steps for setup"
  value = <<-EOT
    Hub cluster has been successfully deployed!
    
    Next steps:
    1. Configure kubectl: az aks get-credentials --resource-group ${module.hub_cluster.resource_group_name} --name ${module.hub_cluster.cluster_name}
    2. Install ArgoCD: kubectl apply -f ../../argocd/bootstrap/
    3. Deploy spoke clusters using the spoke environment configurations
    4. Update spoke_cluster_ids and spoke_resource_group_ids variables
    5. Re-run terraform apply to complete RBAC setup
    
    ArgoCD will be available at: https://argocd.your-domain.com (update domain in bootstrap config)
  EOT
}