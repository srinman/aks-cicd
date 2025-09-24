# Terraform configuration to fetch spoke cluster endpoint and credentials
# This example shows how to retrieve spoke cluster information for hub-to-spoke operations

terraform {
  required_version = ">= 1.0"
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

provider "azurerm" {
  features {}
}

provider "azuread" {}

# Variables for spoke cluster identification
variable "spoke_resource_group_name" {
  description = "Resource group name where the spoke cluster is deployed"
  type        = string
  # Example: "rg-aks-spoke-prod-001"
}

variable "spoke_cluster_name" {
  description = "Name of the spoke AKS cluster"
  type        = string
  # Example: "aks-spoke-prod-001"
}

variable "hub_cluster_name" {
  description = "Name of the hub AKS cluster (for managed identity reference)"
  type        = string
  # Example: "aks-hub-prod-001"
}

variable "hub_resource_group_name" {
  description = "Resource group name where the hub cluster is deployed"
  type        = string
  # Example: "rg-aks-hub-prod-001"
}

# Data source to fetch spoke cluster information
data "azurerm_kubernetes_cluster" "spoke" {
  name                = var.spoke_cluster_name
  resource_group_name = var.spoke_resource_group_name
}

# Data source to fetch hub cluster managed identity
data "azurerm_kubernetes_cluster" "hub" {
  name                = var.hub_cluster_name
  resource_group_name = var.hub_resource_group_name
}

# Output spoke cluster endpoint and configuration
output "spoke_cluster_endpoint" {
  description = "Spoke cluster API server endpoint"
  value       = data.azurerm_kubernetes_cluster.spoke.kube_config.0.host
  sensitive   = false
}

output "spoke_cluster_ca_certificate" {
  description = "Spoke cluster CA certificate (base64 encoded)"
  value       = data.azurerm_kubernetes_cluster.spoke.kube_config.0.cluster_ca_certificate
  sensitive   = true
}

output "spoke_cluster_fqdn" {
  description = "Spoke cluster FQDN"
  value       = data.azurerm_kubernetes_cluster.spoke.fqdn
}

output "spoke_cluster_id" {
  description = "Spoke cluster resource ID"
  value       = data.azurerm_kubernetes_cluster.spoke.id
}

output "hub_identity_client_id" {
  description = "Hub cluster managed identity client ID"
  value       = data.azurerm_kubernetes_cluster.hub.kubelet_identity[0].client_id
}

output "hub_identity_principal_id" {
  description = "Hub cluster managed identity principal ID"
  value       = data.azurerm_kubernetes_cluster.hub.kubelet_identity[0].object_id
}

# Generate kubectl configuration for spoke cluster
output "kubectl_config_command" {
  description = "Command to configure kubectl for spoke cluster using Azure AD"
  value = format(
    "az aks get-credentials --resource-group %s --name %s --use-azuread --overwrite-existing",
    var.spoke_resource_group_name,
    var.spoke_cluster_name
  )
}

# Generate environment variables for scripts
output "environment_variables" {
  description = "Environment variables for hub-to-spoke scripts"
  value = {
    SPOKE_RG           = var.spoke_resource_group_name
    SPOKE_CLUSTER_NAME = var.spoke_cluster_name
    SPOKE_FQDN        = data.azurerm_kubernetes_cluster.spoke.fqdn
    HUB_IDENTITY_CLIENT_ID = data.azurerm_kubernetes_cluster.hub.kubelet_identity[0].client_id
  }
}

# Local values for convenient access
locals {
  spoke_cluster_info = {
    endpoint           = data.azurerm_kubernetes_cluster.spoke.kube_config.0.host
    fqdn              = data.azurerm_kubernetes_cluster.spoke.fqdn
    resource_id       = data.azurerm_kubernetes_cluster.spoke.id
    ca_certificate    = data.azurerm_kubernetes_cluster.spoke.kube_config.0.cluster_ca_certificate
  }
  
  hub_identity = {
    client_id     = data.azurerm_kubernetes_cluster.hub.kubelet_identity[0].client_id
    principal_id  = data.azurerm_kubernetes_cluster.hub.kubelet_identity[0].object_id
  }
}