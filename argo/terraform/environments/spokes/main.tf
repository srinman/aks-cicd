# Spoke Clusters Deployment Configuration

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
    key                  = "spoke-clusters.tfstate"
  }
}

# Configure the Azure Provider
provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

# Data sources
data "azurerm_client_config" "current" {}

# Get hub cluster information from remote state
data "terraform_remote_state" "hub" {
  backend = "azurerm"
  config = {
    resource_group_name  = "tfstate-rg"
    storage_account_name = "tfstatestorage"
    container_name       = "tfstate"
    key                  = "hub-cluster.tfstate"
  }
}

# Create Log Analytics Workspace for spoke monitoring (shared)
resource "azurerm_resource_group" "spoke_monitoring" {
  name     = "${var.organization_prefix}-spoke-monitoring-rg"
  location = var.location
  tags     = var.common_tags
}

resource "azurerm_log_analytics_workspace" "spoke_logs" {
  name                = "${var.organization_prefix}-spoke-logs"
  location            = azurerm_resource_group.spoke_monitoring.location
  resource_group_name = azurerm_resource_group.spoke_monitoring.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.common_tags
}

# Development Spoke Cluster
module "dev_spoke" {
  source = "../../modules/aks-spoke"

  # Basic configuration
  resource_group_name = "${var.organization_prefix}-dev-rg"
  location           = var.location
  cluster_name       = "${var.organization_prefix}-dev-aks"
  environment        = "dev"
  hub_cluster_name   = data.terraform_remote_state.hub.outputs.hub_cluster_name
  kubernetes_version = var.kubernetes_version

  # Hub identity information
  hub_identity_principal_id = data.terraform_remote_state.hub.outputs.hub_identity_principal_id
  hub_identity_client_id    = data.terraform_remote_state.hub.outputs.hub_identity_client_id

  # Node configuration
  system_node_count     = var.dev_system_node_count
  system_node_min_count = var.dev_system_node_min_count
  system_node_max_count = var.dev_system_node_max_count
  system_node_vm_size   = var.dev_system_node_vm_size

  create_workload_pool      = var.dev_create_workload_pool
  workload_node_count       = var.dev_workload_node_count
  workload_node_min_count   = var.dev_workload_node_min_count
  workload_node_max_count   = var.dev_workload_node_max_count
  workload_node_vm_size     = var.dev_workload_node_vm_size

  # Network configuration
  dns_service_ip = var.dev_dns_service_ip
  service_cidr   = var.dev_service_cidr

  # Azure AD integration
  admin_group_object_ids = var.admin_group_object_ids

  # Monitoring
  log_analytics_workspace_id = azurerm_log_analytics_workspace.spoke_logs.id

  # Tags
  common_tags = merge(var.common_tags, {
    Environment = "dev"
    Purpose     = "development-workloads"
  })
}

# Staging Spoke Cluster
module "staging_spoke" {
  count  = var.deploy_staging ? 1 : 0
  source = "../../modules/aks-spoke"

  # Basic configuration
  resource_group_name = "${var.organization_prefix}-staging-rg"
  location           = var.location
  cluster_name       = "${var.organization_prefix}-staging-aks"
  environment        = "staging"
  hub_cluster_name   = data.terraform_remote_state.hub.outputs.hub_cluster_name
  kubernetes_version = var.kubernetes_version

  # Hub identity information
  hub_identity_principal_id = data.terraform_remote_state.hub.outputs.hub_identity_principal_id
  hub_identity_client_id    = data.terraform_remote_state.hub.outputs.hub_identity_client_id

  # Node configuration
  system_node_count     = var.staging_system_node_count
  system_node_min_count = var.staging_system_node_min_count
  system_node_max_count = var.staging_system_node_max_count
  system_node_vm_size   = var.staging_system_node_vm_size

  create_workload_pool      = var.staging_create_workload_pool
  workload_node_count       = var.staging_workload_node_count
  workload_node_min_count   = var.staging_workload_node_min_count
  workload_node_max_count   = var.staging_workload_node_max_count
  workload_node_vm_size     = var.staging_workload_node_vm_size

  # Network configuration
  dns_service_ip = var.staging_dns_service_ip
  service_cidr   = var.staging_service_cidr

  # Azure AD integration
  admin_group_object_ids = var.admin_group_object_ids

  # Monitoring
  log_analytics_workspace_id = azurerm_log_analytics_workspace.spoke_logs.id

  # Tags
  common_tags = merge(var.common_tags, {
    Environment = "staging"
    Purpose     = "staging-workloads"
  })
}

# Production Spoke Cluster
module "prod_spoke" {
  count  = var.deploy_prod ? 1 : 0
  source = "../../modules/aks-spoke"

  # Basic configuration
  resource_group_name = "${var.organization_prefix}-prod-rg"
  location           = var.location
  cluster_name       = "${var.organization_prefix}-prod-aks"
  environment        = "prod"
  hub_cluster_name   = data.terraform_remote_state.hub.outputs.hub_cluster_name
  kubernetes_version = var.kubernetes_version

  # Hub identity information
  hub_identity_principal_id = data.terraform_remote_state.hub.outputs.hub_identity_principal_id
  hub_identity_client_id    = data.terraform_remote_state.hub.outputs.hub_identity_client_id

  # Node configuration
  system_node_count     = var.prod_system_node_count
  system_node_min_count = var.prod_system_node_min_count
  system_node_max_count = var.prod_system_node_max_count
  system_node_vm_size   = var.prod_system_node_vm_size

  create_workload_pool      = var.prod_create_workload_pool
  workload_node_count       = var.prod_workload_node_count
  workload_node_min_count   = var.prod_workload_node_min_count
  workload_node_max_count   = var.prod_workload_node_max_count
  workload_node_vm_size     = var.prod_workload_node_vm_size

  # Network configuration
  dns_service_ip = var.prod_dns_service_ip
  service_cidr   = var.prod_service_cidr

  # Azure AD integration
  admin_group_object_ids = var.admin_group_object_ids

  # Monitoring
  log_analytics_workspace_id = azurerm_log_analytics_workspace.spoke_logs.id

  # Tags
  common_tags = merge(var.common_tags, {
    Environment = "prod"
    Purpose     = "production-workloads"
  })
}