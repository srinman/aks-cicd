# Hub Cluster Outputs

output "cluster_id" {
  description = "AKS cluster ID"
  value       = azurerm_kubernetes_cluster.hub_cluster.id
}

output "cluster_name" {
  description = "AKS cluster name"
  value       = azurerm_kubernetes_cluster.hub_cluster.name
}

output "resource_group_name" {
  description = "Resource group name"
  value       = azurerm_resource_group.hub_rg.name
}

output "cluster_fqdn" {
  description = "FQDN of the AKS cluster"
  value       = azurerm_kubernetes_cluster.hub_cluster.fqdn
}

output "cluster_endpoint" {
  description = "Endpoint for the AKS cluster API server"
  value       = azurerm_kubernetes_cluster.hub_cluster.kube_config[0].host
}

output "hub_identity_id" {
  description = "User assigned identity ID for the hub cluster"
  value       = azurerm_user_assigned_identity.hub_identity.id
}

output "hub_identity_principal_id" {
  description = "Principal ID of the hub cluster managed identity"
  value       = azurerm_user_assigned_identity.hub_identity.principal_id
  sensitive   = true
}

output "hub_identity_client_id" {
  description = "Client ID of the hub cluster managed identity"
  value       = azurerm_user_assigned_identity.hub_identity.client_id
  sensitive   = true
}

output "kubeconfig" {
  description = "Kubeconfig for the hub cluster"
  value       = azurerm_kubernetes_cluster.hub_cluster.kube_config_raw
  sensitive   = true
}

output "oidc_issuer_url" {
  description = "OIDC issuer URL for the cluster"
  value       = azurerm_kubernetes_cluster.hub_cluster.oidc_issuer_url
}

output "cluster_ca_certificate" {
  description = "Base64 encoded cluster CA certificate"
  value       = azurerm_kubernetes_cluster.hub_cluster.kube_config[0].cluster_ca_certificate
  sensitive   = true
}