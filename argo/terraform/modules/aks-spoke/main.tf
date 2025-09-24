# Spoke AKS Cluster Module
# This module creates spoke clusters that are managed by the ArgoCD hub cluster

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

# Resource Group for Spoke Cluster
resource "azurerm_resource_group" "spoke_rg" {
  name     = var.resource_group_name
  location = var.location

  tags = merge(var.common_tags, {
    Environment = var.environment
    Purpose     = "workload-cluster"
    ManagedBy   = var.hub_cluster_name
  })
}

# Spoke Cluster Managed Identity
resource "azurerm_user_assigned_identity" "spoke_identity" {
  name                = "${var.cluster_name}-spoke-identity"
  location            = azurerm_resource_group.spoke_rg.location
  resource_group_name = azurerm_resource_group.spoke_rg.name

  tags = var.common_tags
}

# Spoke AKS Cluster
resource "azurerm_kubernetes_cluster" "spoke_cluster" {
  name                = var.cluster_name
  location            = azurerm_resource_group.spoke_rg.location
  resource_group_name = azurerm_resource_group.spoke_rg.name
  dns_prefix          = "${var.cluster_name}-dns"
  kubernetes_version  = var.kubernetes_version

  # Enable Azure RBAC for Kubernetes Authorization
  azure_rbac_enabled                = true
  role_based_access_control_enabled = true
  local_account_disabled            = true

  # Identity configuration
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.spoke_identity.id]
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
    Environment = var.environment
    Purpose     = "workload-cluster"
    ManagedBy   = var.hub_cluster_name
  })

  lifecycle {
    ignore_changes = [
      default_node_pool[0].node_count
    ]
  }
}

# Workload node pool
resource "azurerm_kubernetes_cluster_node_pool" "workload_pool" {
  count                 = var.create_workload_pool ? 1 : 0
  name                  = "workload"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.spoke_cluster.id
  vm_size              = var.workload_node_vm_size
  node_count           = var.workload_node_count
  availability_zones   = var.availability_zones
  enable_auto_scaling  = true
  min_count           = var.workload_node_min_count
  max_count           = var.workload_node_max_count

  node_labels = {
    "workload-type" = "application"
  }

  upgrade_settings {
    max_surge = "10%"
  }

  tags = var.common_tags
}

# Role assignment for hub cluster identity to manage this spoke cluster
resource "azurerm_role_assignment" "hub_cluster_user" {
  scope                = azurerm_kubernetes_cluster.spoke_cluster.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = var.hub_identity_principal_id
}

# Role assignment for hub cluster identity to read spoke cluster configuration
resource "azurerm_role_assignment" "hub_reader" {
  scope                = azurerm_resource_group.spoke_rg.id
  role_definition_name = "Reader"
  principal_id         = var.hub_identity_principal_id
}

# Create namespace for ArgoCD managed applications
resource "kubernetes_namespace" "argocd_managed" {
  depends_on = [azurerm_kubernetes_cluster.spoke_cluster]

  metadata {
    name = "argocd-managed"
    labels = {
      "app.kubernetes.io/managed-by" = "argocd"
      "argocd.argoproj.io/managed"   = "true"
    }
  }
}

# Service Account for Hub Cluster ArgoCD to use in this spoke cluster
resource "kubernetes_service_account" "argocd_manager" {
  depends_on = [kubernetes_namespace.argocd_managed]

  metadata {
    name      = "argocd-manager"
    namespace = "argocd-managed"
    labels = {
      "app.kubernetes.io/name"      = "argocd-manager"
      "app.kubernetes.io/part-of"   = "argocd"
      "app.kubernetes.io/component" = "service-account"
    }
    annotations = {
      "azure.workload.identity/client-id" = var.hub_identity_client_id
    }
  }

  automount_service_account_token = true
}

# Cluster Role for ArgoCD to manage applications in this spoke cluster
resource "kubernetes_cluster_role" "argocd_manager" {
  depends_on = [azurerm_kubernetes_cluster.spoke_cluster]

  metadata {
    name = "argocd-manager"
  }

  rule {
    api_groups = [""]
    resources  = ["configmaps", "secrets", "services", "serviceaccounts"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "daemonsets", "replicasets", "statefulsets"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  rule {
    api_groups = ["extensions", "networking.k8s.io"]
    resources  = ["ingresses", "networkpolicies"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  rule {
    api_groups = ["policy"]
    resources  = ["poddisruptionbudgets"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  rule {
    api_groups = ["autoscaling"]
    resources  = ["horizontalpodautoscalers"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  rule {
    api_groups = ["batch"]
    resources  = ["jobs", "cronjobs"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  # Namespace management within allowed namespaces
  rule {
    api_groups     = [""]
    resources      = ["namespaces"]
    verbs          = ["get", "list", "watch"]
    resource_names = ["argocd-managed", "default", "kube-system"]
  }

  # Custom resources for application-specific CRDs
  rule {
    api_groups = ["apiextensions.k8s.io"]
    resources  = ["customresourcedefinitions"]
    verbs      = ["get", "list", "watch"]
  }
}

# Cluster Role Binding for ArgoCD manager
resource "kubernetes_cluster_role_binding" "argocd_manager" {
  depends_on = [kubernetes_cluster_role.argocd_manager, kubernetes_service_account.argocd_manager]

  metadata {
    name = "argocd-manager"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.argocd_manager.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.argocd_manager.metadata[0].name
    namespace = "argocd-managed"
  }

  # Also bind to the system service account that ArgoCD will use via Azure RBAC
  subject {
    kind      = "User"
    name      = var.hub_identity_client_id
    api_group = "rbac.authorization.k8s.io"
  }
}

# Create secret with cluster connection information for ArgoCD
resource "kubernetes_secret" "cluster_config" {
  depends_on = [kubernetes_namespace.argocd_managed]

  metadata {
    name      = "${var.cluster_name}-config"
    namespace = "argocd-managed"
    labels = {
      "argocd.argoproj.io/secret-type" = "cluster"
      "cluster-name"                   = var.cluster_name
      "environment"                    = var.environment
    }
  }

  data = {
    name   = var.cluster_name
    server = azurerm_kubernetes_cluster.spoke_cluster.kube_config[0].host
    config = jsonencode({
      execProviderConfig = {
        command = "kubelogin"
        args = [
          "get-token",
          "--login", "azurecli",
          "--server-id", "6dae42f8-4368-4678-94ff-3960e28e3630" # AKS AAD Server App ID
        ]
        apiVersion = "client.authentication.k8s.io/v1beta1"
      }
      tlsClientConfig = {
        insecure = false
        caData   = base64encode(base64decode(azurerm_kubernetes_cluster.spoke_cluster.kube_config[0].cluster_ca_certificate))
      }
    })
  }

  type = "Opaque"
}