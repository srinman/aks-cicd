# Hub AKS Cluster Module
# This module creates the central ArgoCD hub cluster with necessary RBAC permissions

terraform {
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
}

# Data sources
data "azurerm_client_config" "current" {}

# Resource Group for Hub Cluster
resource "azurerm_resource_group" "hub_rg" {
  name     = var.resource_group_name
  location = var.location

  tags = merge(var.common_tags, {
    Environment = "hub"
    Purpose     = "argocd-controller"
  })
}

# Hub Cluster Managed Identity
resource "azurerm_user_assigned_identity" "hub_identity" {
  name                = "${var.cluster_name}-hub-identity"
  location            = azurerm_resource_group.hub_rg.location
  resource_group_name = azurerm_resource_group.hub_rg.name

  tags = var.common_tags
}

# Hub AKS Cluster
resource "azurerm_kubernetes_cluster" "hub_cluster" {
  name                = var.cluster_name
  location            = azurerm_resource_group.hub_rg.location
  resource_group_name = azurerm_resource_group.hub_rg.name
  dns_prefix          = "${var.cluster_name}-dns"
  kubernetes_version  = var.kubernetes_version

  # Enable Azure RBAC for Kubernetes Authorization
  azure_rbac_enabled                = true
  role_based_access_control_enabled = true
  local_account_disabled            = true

  # Identity configuration
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.hub_identity.id]
  }

  # Default node pool
  default_node_pool {
    name                = "system"
    node_count          = var.system_node_count
    vm_size             = var.system_node_vm_size
    type                = "VirtualMachineScaleSets"
    availability_zones  = var.availability_zones
    enable_auto_scaling = true
    min_count          = var.system_node_min_count
    max_count          = var.system_node_max_count

    # Node pool upgrade settings
    upgrade_settings {
      max_surge = "10%"
    }

    tags = var.common_tags
  }

  # Network configuration
  network_profile {
    network_plugin      = "azure"
    network_policy      = "azure"
    dns_service_ip      = var.dns_service_ip
    service_cidr        = var.service_cidr
    load_balancer_sku   = "standard"
  }

  # Azure Active Directory integration
  azure_active_directory_role_based_access_control {
    managed                = true
    azure_rbac_enabled     = true
    admin_group_object_ids = var.admin_group_object_ids
  }

  # Add-ons
  oms_agent {
    log_analytics_workspace_id = var.log_analytics_workspace_id
  }

  key_vault_secrets_provider {
    secret_rotation_enabled = true
  }

  tags = merge(var.common_tags, {
    Environment = "hub"
    Purpose     = "argocd-controller"
  })

  lifecycle {
    ignore_changes = [
      default_node_pool[0].node_count
    ]
  }
}

# Additional node pool for ArgoCD workloads
resource "azurerm_kubernetes_cluster_node_pool" "argocd_pool" {
  name                  = "argocd"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.hub_cluster.id
  vm_size              = var.argocd_node_vm_size
  node_count           = var.argocd_node_count
  availability_zones   = var.availability_zones
  enable_auto_scaling  = true
  min_count           = var.argocd_node_min_count
  max_count           = var.argocd_node_max_count

  node_taints = [
    "workload-type=argocd:NoSchedule"
  ]

  node_labels = {
    "workload-type" = "argocd"
  }

  upgrade_settings {
    max_surge = "10%"
  }

  tags = var.common_tags
}

# Role assignment for hub identity to manage spoke clusters across subscription
resource "azurerm_role_assignment" "hub_contributor" {
  count                = length(var.spoke_resource_group_ids)
  scope                = var.spoke_resource_group_ids[count.index]
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = azurerm_user_assigned_identity.hub_identity.principal_id
}

# Role assignment for hub identity to read spoke cluster configurations
resource "azurerm_role_assignment" "hub_reader" {
  count                = length(var.spoke_resource_group_ids)
  scope                = var.spoke_resource_group_ids[count.index]
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.hub_identity.principal_id
}

# Create ArgoCD namespace and basic RBAC
resource "kubernetes_namespace" "argocd" {
  depends_on = [azurerm_kubernetes_cluster.hub_cluster]

  metadata {
    name = "argocd"
    labels = {
      "app.kubernetes.io/name"      = "argocd"
      "app.kubernetes.io/component" = "namespace"
    }
  }
}

# Create cluster role for ArgoCD to manage applications across clusters
resource "kubernetes_cluster_role" "argocd_application_controller" {
  depends_on = [azurerm_kubernetes_cluster.hub_cluster]

  metadata {
    name = "argocd-application-controller"
  }

  rule {
    api_groups = ["*"]
    resources  = ["*"]
    verbs      = ["*"]
  }
}

resource "kubernetes_cluster_role_binding" "argocd_application_controller" {
  depends_on = [kubernetes_cluster_role.argocd_application_controller]

  metadata {
    name = "argocd-application-controller"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.argocd_application_controller.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = "argocd-application-controller"
    namespace = "argocd"
  }
}

# Service account for ArgoCD application controller
resource "kubernetes_service_account" "argocd_application_controller" {
  depends_on = [kubernetes_namespace.argocd]

  metadata {
    name      = "argocd-application-controller"
    namespace = "argocd"
    labels = {
      "app.kubernetes.io/name"      = "argocd-application-controller"
      "app.kubernetes.io/part-of"   = "argocd"
      "app.kubernetes.io/component" = "application-controller"
    }
  }

  automount_service_account_token = true
}