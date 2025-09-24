# RBAC Module Variables

variable "organization_prefix" {
  description = "Prefix for naming resources and AD groups"
  type        = string
  default     = "myorg"
}

variable "hub_identity_principal_id" {
  description = "Principal ID of the hub cluster managed identity"
  type        = string
}

variable "hub_cluster_id" {
  description = "Resource ID of the hub cluster"
  type        = string
}

variable "hub_cluster_name" {
  description = "Name of the hub cluster"
  type        = string
}

variable "hub_cluster_endpoint" {
  description = "API endpoint of the hub cluster"
  type        = string
}

variable "spoke_cluster_ids" {
  description = "Map of spoke cluster names to their resource IDs"
  type        = map(string)
  default     = {}
}

variable "spoke_resource_group_ids" {
  description = "Map of spoke cluster names to their resource group IDs"
  type        = map(string)
  default     = {}
}

variable "spoke_environments" {
  description = "Map of spoke environment configurations"
  type        = map(object({
    name        = string
    description = optional(string, "")
  }))
  default = {}
}

variable "create_ad_groups" {
  description = "Whether to create Azure AD groups for RBAC"
  type        = bool
  default     = true
}

variable "grant_subscription_reader" {
  description = "Whether to grant subscription reader access to hub identity"
  type        = bool
  default     = false
}

variable "create_key_vault" {
  description = "Whether to create a Key Vault for storing cluster secrets"
  type        = bool
  default     = true
}

variable "key_vault_location" {
  description = "Location for the Key Vault"
  type        = string
  default     = "East US"
}

variable "key_vault_resource_group" {
  description = "Resource group name for the Key Vault"
  type        = string
}

variable "common_tags" {
  description = "Common tags to be applied to all resources"
  type        = map(string)
  default = {
    ManagedBy = "terraform"
    Project   = "aks-cicd"
  }
}