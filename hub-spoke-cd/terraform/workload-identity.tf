# Terraform Configuration for Azure Workload Identity Setup
# This configuration sets up workload identity for hub-to-spoke operations

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
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}

provider "azurerm" {
  features {}
}

provider "azuread" {}

# Variables
variable "hub_cluster_name" {
  description = "Name of the hub AKS cluster"
  type        = string
}

variable "hub_resource_group_name" {
  description = "Resource group name of the hub cluster"
  type        = string
}

variable "spoke_clusters" {
  description = "Map of spoke clusters to grant access to"
  type = map(object({
    name                = string
    resource_group_name = string
  }))
  default = {}
}

variable "service_account_namespace" {
  description = "Kubernetes namespace for the service account"
  type        = string
  default     = "hub-operations"
}

variable "service_account_name" {
  description = "Name of the Kubernetes service account"
  type        = string
  default     = "hub-to-spoke-sa"
}

variable "application_name" {
  description = "Name of the Azure AD application"
  type        = string
  default     = "hub-to-spoke-workload-identity"
}

# Data sources
data "azurerm_kubernetes_cluster" "hub" {
  name                = var.hub_cluster_name
  resource_group_name = var.hub_resource_group_name
}

data "azurerm_client_config" "current" {}

# Configure Kubernetes provider to use the hub cluster
provider "kubernetes" {
  host                   = data.azurerm_kubernetes_cluster.hub.kube_config.0.host
  client_certificate     = base64decode(data.azurerm_kubernetes_cluster.hub.kube_config.0.client_certificate)
  client_key             = base64decode(data.azurerm_kubernetes_cluster.hub.kube_config.0.client_key)
  cluster_ca_certificate = base64decode(data.azurerm_kubernetes_cluster.hub.kube_config.0.cluster_ca_certificate)
}

# Create Azure AD Application
resource "azuread_application" "workload_identity" {
  display_name = var.application_name
  
  tags = [
    "hub-to-spoke",
    "workload-identity",
    "terraform-managed"
  ]
}

# Create Service Principal
resource "azuread_service_principal" "workload_identity" {
  application_id = azuread_application.workload_identity.application_id
  
  tags = [
    "hub-to-spoke",
    "workload-identity",
    "terraform-managed"
  ]
}

# Create Kubernetes namespace
resource "kubernetes_namespace" "hub_operations" {
  metadata {
    name = var.service_account_namespace
    
    labels = {
      "azure.workload.identity/managed" = "true"
      "managed-by"                      = "terraform"
    }
  }
}

# Create Kubernetes Service Account
resource "kubernetes_service_account" "workload_identity" {
  metadata {
    name      = var.service_account_name
    namespace = kubernetes_namespace.hub_operations.metadata[0].name
    
    annotations = {
      "azure.workload.identity/client-id" = azuread_application.workload_identity.application_id
    }
    
    labels = {
      "azure.workload.identity/use" = "true"
      "managed-by"                  = "terraform"
    }
  }
  
  depends_on = [kubernetes_namespace.hub_operations]
}

# Create Federated Credential
resource "azuread_application_federated_identity_credential" "workload_identity" {
  application_object_id = azuread_application.workload_identity.object_id
  display_name          = "hub-to-spoke-federated-credential"
  description           = "Federated credential for hub-to-spoke operations"
  audiences             = ["api://AzureADTokenExchange"]
  issuer                = data.azurerm_kubernetes_cluster.hub.oidc_issuer_url
  subject               = "system:serviceaccount:${var.service_account_namespace}:${var.service_account_name}"
  
  depends_on = [kubernetes_service_account.workload_identity]
}

# Get spoke cluster data and assign RBAC permissions
data "azurerm_kubernetes_cluster" "spokes" {
  for_each = var.spoke_clusters
  
  name                = each.value.name
  resource_group_name = each.value.resource_group_name
}

# Assign RBAC permissions to spoke clusters
resource "azurerm_role_assignment" "spoke_access" {
  for_each = var.spoke_clusters
  
  scope                = data.azurerm_kubernetes_cluster.spokes[each.key].id
  role_definition_name = "Azure Kubernetes Service Cluster Admin Role"
  principal_id         = azuread_service_principal.workload_identity.object_id
  
  depends_on = [azuread_service_principal.workload_identity]
}

# Outputs
output "application_client_id" {
  description = "Client ID of the Azure AD application"
  value       = azuread_application.workload_identity.application_id
}

output "service_principal_object_id" {
  description = "Object ID of the service principal"
  value       = azuread_service_principal.workload_identity.object_id
}

output "oidc_issuer_url" {
  description = "OIDC issuer URL of the hub cluster"
  value       = data.azurerm_kubernetes_cluster.hub.oidc_issuer_url
}

output "service_account_namespace" {
  description = "Kubernetes namespace of the service account"
  value       = kubernetes_namespace.hub_operations.metadata[0].name
}

output "service_account_name" {
  description = "Name of the Kubernetes service account"
  value       = kubernetes_service_account.workload_identity.metadata[0].name
}

output "federated_credential_subject" {
  description = "Subject of the federated credential"
  value       = "system:serviceaccount:${var.service_account_namespace}:${var.service_account_name}"
}

output "environment_variables" {
  description = "Environment variables for workload identity"
  value = {
    AZURE_CLIENT_ID                = azuread_application.workload_identity.application_id
    AZURE_TENANT_ID               = data.azurerm_client_config.current.tenant_id
    AZURE_FEDERATED_TOKEN_FILE    = "/var/run/secrets/azure/tokens/azure-identity-token"
    AZURE_AUTHORITY_HOST          = "https://login.microsoftonline.com/"
    SERVICE_ACCOUNT_NAMESPACE     = var.service_account_namespace
    SERVICE_ACCOUNT_NAME          = var.service_account_name
  }
}

output "spoke_cluster_access" {
  description = "Spoke clusters that the workload identity can access"
  value = {
    for k, v in var.spoke_clusters : k => {
      cluster_name    = v.name
      resource_group  = v.resource_group_name
      cluster_id      = data.azurerm_kubernetes_cluster.spokes[k].id
      cluster_fqdn    = data.azurerm_kubernetes_cluster.spokes[k].fqdn
      role_assignment = "Azure Kubernetes Service Cluster Admin Role"
    }
  }
}

output "kubectl_commands" {
  description = "Useful kubectl commands for workload identity"
  value = {
    get_service_account = "kubectl get serviceaccount ${var.service_account_name} -n ${var.service_account_namespace} -o yaml"
    describe_service_account = "kubectl describe serviceaccount ${var.service_account_name} -n ${var.service_account_namespace}"
    test_workload_identity = "kubectl run workload-identity-test --image=mcr.microsoft.com/azure-cli:latest --serviceaccount=${var.service_account_name} -n ${var.service_account_namespace} --rm -it -- az account show"
  }
}

# Local values for convenience
locals {
  workload_identity_config = {
    application_id     = azuread_application.workload_identity.application_id
    tenant_id         = data.azurerm_client_config.current.tenant_id
    service_account   = "${var.service_account_namespace}/${var.service_account_name}"
    oidc_issuer       = data.azurerm_kubernetes_cluster.hub.oidc_issuer_url
    subject           = "system:serviceaccount:${var.service_account_namespace}:${var.service_account_name}"
  }
}