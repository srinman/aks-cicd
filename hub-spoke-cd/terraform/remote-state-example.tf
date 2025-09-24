# Alternative Terraform configuration using remote state
# This approach fetches spoke cluster info from remote Terraform state

terraform {
  required_version = ">= 1.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

# Variables for remote state configuration
variable "spoke_state_resource_group" {
  description = "Resource group containing the storage account with spoke cluster state"
  type        = string
}

variable "spoke_state_storage_account" {
  description = "Storage account name containing spoke cluster Terraform state"
  type        = string
}

variable "spoke_state_container" {
  description = "Storage container name for spoke cluster state"
  type        = string
  default     = "tfstate"
}

variable "spoke_state_key" {
  description = "State file key/path for spoke cluster"
  type        = string
  # Example: "spoke-clusters/prod/terraform.tfstate"
}

# Remote state data source to fetch spoke cluster outputs
data "terraform_remote_state" "spoke" {
  backend = "azurerm"
  config = {
    resource_group_name  = var.spoke_state_resource_group
    storage_account_name = var.spoke_state_storage_account
    container_name       = var.spoke_state_container
    key                  = var.spoke_state_key
  }
}

# Outputs from remote state (assuming spoke cluster was created with Terraform)
output "spoke_cluster_from_remote_state" {
  description = "Spoke cluster information from remote Terraform state"
  value = {
    # These outputs depend on what your spoke cluster Terraform configuration exports
    cluster_name      = try(data.terraform_remote_state.spoke.outputs.cluster_name, null)
    resource_group    = try(data.terraform_remote_state.spoke.outputs.resource_group_name, null)
    cluster_fqdn      = try(data.terraform_remote_state.spoke.outputs.cluster_fqdn, null)
    cluster_endpoint  = try(data.terraform_remote_state.spoke.outputs.cluster_endpoint, null)
    resource_id       = try(data.terraform_remote_state.spoke.outputs.cluster_id, null)
  }
}

# Generate kubectl command using remote state data
output "kubectl_config_from_remote_state" {
  description = "kubectl configuration command using remote state data"
  value = format(
    "az aks get-credentials --resource-group %s --name %s --use-azuread --overwrite-existing",
    try(data.terraform_remote_state.spoke.outputs.resource_group_name, "UNKNOWN"),
    try(data.terraform_remote_state.spoke.outputs.cluster_name, "UNKNOWN")
  )
}