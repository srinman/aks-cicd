# Terraform configuration for creating a secure spoke cluster
# This configuration creates a spoke cluster with local admin disabled and Azure AD integration

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

# Variables for spoke cluster creation
variable "spoke_cluster_name" {
  description = "Name of the spoke AKS cluster to create"
  type        = string
}

variable "spoke_resource_group_name" {
  description = "Resource group name where spoke cluster will be created"
  type        = string
}

variable "spoke_location" {
  description = "Azure location for the spoke cluster"
  type        = string
  default     = "East US"
}

variable "node_count" {
  description = "Number of nodes in the default node pool"
  type        = number
  default     = 3
}

variable "node_vm_size" {
  description = "VM size for cluster nodes"
  type        = string
  default     = "Standard_D2s_v3"
}

variable "aad_admin_group_object_ids" {
  description = "List of Azure AD group object IDs that will have admin access to the cluster"
  type        = list(string)
}

variable "hub_cluster_resource_id" {
  description = "Resource ID of the hub cluster (for RBAC assignment)"
  type        = string
}

# Data source for hub cluster identity
data "azurerm_kubernetes_cluster" "hub" {
  name                = split("/", var.hub_cluster_resource_id)[8]
  resource_group_name = split("/", var.hub_cluster_resource_id)[4]
}

# Resource group for spoke cluster (if it doesn't exist)
resource "azurerm_resource_group" "spoke" {
  name     = var.spoke_resource_group_name
  location = var.spoke_location
  
  tags = {
    Environment = "production"
    ClusterType = "spoke"
    ManagedBy   = "terraform"
  }
}

# Spoke AKS cluster with security best practices
resource "azurerm_kubernetes_cluster" "spoke" {
  name                = var.spoke_cluster_name
  location            = azurerm_resource_group.spoke.location
  resource_group_name = azurerm_resource_group.spoke.name
  dns_prefix          = "${var.spoke_cluster_name}-dns"
  
  # Security Configuration
  local_account_disabled = true  # Disable local admin account
  
  # Azure AD Integration (mandatory when local accounts are disabled)
  azure_active_directory_role_based_access_control {
    managed                = true
    admin_group_object_ids = var.aad_admin_group_object_ids
  }
  
  # Default node pool
  default_node_pool {
    name                = "default"
    node_count          = var.node_count
    vm_size             = var.node_vm_size
    enable_auto_scaling = true
    min_count          = 1
    max_count          = 10
    
    # Security settings
    only_critical_addons_enabled = false
  }
  
  # System-assigned managed identity
  identity {
    type = "SystemAssigned"
  }
  
  # Network configuration
  network_profile {
    network_plugin = "azure"
    network_policy = "azure"
  }
  
  tags = {
    Environment = "production"
    ClusterType = "spoke"
    ManagedBy   = "terraform"
  }
}

# Role assignment: Hub cluster identity -> Spoke cluster admin
resource "azurerm_role_assignment" "hub_to_spoke" {
  scope                = azurerm_kubernetes_cluster.spoke.id
  role_definition_name = "Azure Kubernetes Service Cluster Admin Role"
  principal_id         = data.azurerm_kubernetes_cluster.hub.kubelet_identity[0].object_id
  
  depends_on = [azurerm_kubernetes_cluster.spoke]
}

# Outputs
output "spoke_cluster_name" {
  description = "Name of the created spoke cluster"
  value       = azurerm_kubernetes_cluster.spoke.name
}

output "spoke_resource_group_name" {
  description = "Resource group of the created spoke cluster"
  value       = azurerm_kubernetes_cluster.spoke.resource_group_name
}

output "spoke_cluster_id" {
  description = "Resource ID of the created spoke cluster"
  value       = azurerm_kubernetes_cluster.spoke.id
}

output "spoke_cluster_fqdn" {
  description = "FQDN of the created spoke cluster"
  value       = azurerm_kubernetes_cluster.spoke.fqdn
}

output "spoke_cluster_endpoint" {
  description = "API server endpoint of the created spoke cluster"
  value       = azurerm_kubernetes_cluster.spoke.kube_config.0.host
}

output "local_accounts_disabled" {
  description = "Confirmation that local admin accounts are disabled"
  value       = azurerm_kubernetes_cluster.spoke.local_account_disabled
}

output "azure_ad_enabled" {
  description = "Confirmation that Azure AD integration is enabled"
  value       = length(azurerm_kubernetes_cluster.spoke.azure_active_directory_role_based_access_control) > 0
}

output "kubectl_config_command" {
  description = "Command to configure kubectl for the new spoke cluster"
  value = format(
    "az aks get-credentials --resource-group %s --name %s --use-azuread --overwrite-existing",
    azurerm_kubernetes_cluster.spoke.resource_group_name,
    azurerm_kubernetes_cluster.spoke.name
  )
}

output "hub_role_assignment_id" {
  description = "ID of the role assignment granting hub cluster access to spoke cluster"
  value       = azurerm_role_assignment.hub_to_spoke.id
}

# Local values for convenience
locals {
  spoke_cluster_info = {
    name           = azurerm_kubernetes_cluster.spoke.name
    resource_group = azurerm_kubernetes_cluster.spoke.resource_group_name
    endpoint       = azurerm_kubernetes_cluster.spoke.kube_config.0.host
    fqdn          = azurerm_kubernetes_cluster.spoke.fqdn
    resource_id   = azurerm_kubernetes_cluster.spoke.id
    local_accounts_disabled = azurerm_kubernetes_cluster.spoke.local_account_disabled
  }
}