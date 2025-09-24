# Hub Cluster Deployment Configuration

terraform {
  required_version = ">= 1.5"
  
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }

  # Configure remote state storage
  backend "azurerm" {
    # Update these values for your environment
    resource_group_name  = "tfstate-rg"
    storage_account_name = "tfstatestorage"
    container_name       = "tfstate"
    key                  = "hub-cluster.tfstate"
  }
}

# Configure the Azure Provider
provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
    key_vault {
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }
  }
}

# Configure Kubernetes provider
provider "kubernetes" {
  host                   = module.hub_cluster.cluster_endpoint
  cluster_ca_certificate = base64decode(module.hub_cluster.cluster_ca_certificate)
  
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "kubelogin"
    args = [
      "get-token",
      "--login", "azurecli",
      "--server-id", "6dae42f8-4368-4678-94ff-3960e28e3630" # AKS AAD Server App ID
    ]
  }
}

# Data sources
data "azurerm_client_config" "current" {}

# Create Log Analytics Workspace for monitoring
resource "azurerm_resource_group" "monitoring" {
  name     = "${var.organization_prefix}-monitoring-rg"
  location = var.location
  tags     = var.common_tags
}

resource "azurerm_log_analytics_workspace" "aks_logs" {
  name                = "${var.organization_prefix}-aks-logs"
  location            = azurerm_resource_group.monitoring.location
  resource_group_name = azurerm_resource_group.monitoring.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.common_tags
}

# Deploy Hub Cluster
module "hub_cluster" {
  source = "../../modules/aks-hub"

  # Basic configuration
  resource_group_name = "${var.organization_prefix}-hub-rg"
  location           = var.location
  cluster_name       = "${var.organization_prefix}-hub-aks"
  kubernetes_version = var.kubernetes_version

  # Node configuration
  system_node_count     = var.system_node_count
  system_node_min_count = var.system_node_min_count
  system_node_max_count = var.system_node_max_count
  system_node_vm_size   = var.system_node_vm_size

  argocd_node_count     = var.argocd_node_count
  argocd_node_min_count = var.argocd_node_min_count
  argocd_node_max_count = var.argocd_node_max_count
  argocd_node_vm_size   = var.argocd_node_vm_size

  # Network configuration
  dns_service_ip = var.dns_service_ip
  service_cidr   = var.service_cidr

  # Azure AD integration
  admin_group_object_ids = var.admin_group_object_ids

  # Spoke cluster configuration (will be populated after spoke deployment)
  spoke_resource_group_ids = var.spoke_resource_group_ids

  # Monitoring
  log_analytics_workspace_id = azurerm_log_analytics_workspace.aks_logs.id

  # Tags
  common_tags = var.common_tags
}

# Deploy RBAC Configuration
module "rbac_config" {
  source = "../../modules/rbac"

  # Organization configuration
  organization_prefix = var.organization_prefix

  # Hub cluster information
  hub_identity_principal_id = module.hub_cluster.hub_identity_principal_id
  hub_cluster_id           = module.hub_cluster.cluster_id
  hub_cluster_name         = module.hub_cluster.cluster_name
  hub_cluster_endpoint     = module.hub_cluster.cluster_endpoint

  # Spoke cluster configuration (populated after spoke deployment)
  spoke_cluster_ids        = var.spoke_cluster_ids
  spoke_resource_group_ids = var.spoke_resource_group_ids
  spoke_environments       = var.spoke_environments

  # RBAC options
  create_ad_groups           = var.create_ad_groups
  grant_subscription_reader  = var.grant_subscription_reader

  # Key Vault configuration
  create_key_vault           = var.create_key_vault
  key_vault_location        = var.location
  key_vault_resource_group  = azurerm_resource_group.monitoring.name

  # Tags
  common_tags = var.common_tags

  depends_on = [module.hub_cluster]
}