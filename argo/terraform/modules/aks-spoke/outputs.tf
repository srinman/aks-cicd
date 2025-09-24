# Spoke Cluster Outputs

output "cluster_id" {
  description = "AKS cluster ID"
  value       = azurerm_kubernetes_cluster.spoke_cluster.id
}

output "cluster_name" {
  description = "AKS cluster name"
  value       = azurerm_kubernetes_cluster.spoke_cluster.name
}

output "resource_group_name" {
  description = "Resource group name"
  value       = azurerm_resource_group.spoke_rg.name
}

output "resource_group_id" {
  description = "Resource group ID"
  value       = azurerm_resource_group.spoke_rg.id
}

output "cluster_fqdn" {
  description = "FQDN of the AKS cluster"
  value       = azurerm_kubernetes_cluster.spoke_cluster.fqdn
}

output "cluster_endpoint" {
  description = "Endpoint for the AKS cluster API server"
  value       = azurerm_kubernetes_cluster.spoke_cluster.kube_config[0].host
}

output "spoke_identity_id" {
  description = "User assigned identity ID for the spoke cluster"
  value       = azurerm_user_assigned_identity.spoke_identity.id
}

output "spoke_identity_principal_id" {
  description = "Principal ID of the spoke cluster managed identity"
  value       = azurerm_user_assigned_identity.spoke_identity.principal_id
  sensitive   = true
}

output "spoke_identity_client_id" {
  description = "Client ID of the spoke cluster managed identity"
  value       = azurerm_user_assigned_identity.spoke_identity.client_id
  sensitive   = true
}

output "kubeconfig" {
  description = "Kubeconfig for the spoke cluster"
  value       = azurerm_kubernetes_cluster.spoke_cluster.kube_config_raw
  sensitive   = true
}

output "oidc_issuer_url" {
  description = "OIDC issuer URL for the cluster"
  value       = azurerm_kubernetes_cluster.spoke_cluster.oidc_issuer_url
}

output "cluster_ca_certificate" {
  description = "Base64 encoded cluster CA certificate"
  value       = azurerm_kubernetes_cluster.spoke_cluster.kube_config[0].cluster_ca_certificate
  sensitive   = true
}

output "argocd_service_account_name" {
  description = "Name of the service account created for ArgoCD management"
  value       = kubernetes_service_account.argocd_manager.metadata[0].name
}

output "argocd_namespace" {
  description = "Namespace where ArgoCD managed resources should be deployed"
  value       = kubernetes_namespace.argocd_managed.metadata[0].name
}