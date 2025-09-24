# Hub Environment Variables

# Organization and Environment
variable "organization_prefix" {
  description = "Prefix for naming resources"
  type        = string
  default     = "myorg"
}

variable "location" {
  description = "Azure region for resources"
  type        = string
  default     = "East US"
}

variable "kubernetes_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.28.3"
}

# System Node Pool Configuration
variable "system_node_count" {
  description = "Number of system nodes"
  type        = number
  default     = 2
}

variable "system_node_min_count" {
  description = "Minimum system nodes"
  type        = number
  default     = 1
}

variable "system_node_max_count" {
  description = "Maximum system nodes"
  type        = number
  default     = 5
}

variable "system_node_vm_size" {
  description = "System node VM size"
  type        = string
  default     = "Standard_D2s_v3"
}

# ArgoCD Node Pool Configuration
variable "argocd_node_count" {
  description = "Number of ArgoCD nodes"
  type        = number
  default     = 2
}

variable "argocd_node_min_count" {
  description = "Minimum ArgoCD nodes"
  type        = number
  default     = 1
}

variable "argocd_node_max_count" {
  description = "Maximum ArgoCD nodes"
  type        = number
  default     = 4
}

variable "argocd_node_vm_size" {
  description = "ArgoCD node VM size"
  type        = string
  default     = "Standard_D4s_v3"
}

# Network Configuration
variable "dns_service_ip" {
  description = "DNS service IP"
  type        = string
  default     = "10.0.0.10"
}

variable "service_cidr" {
  description = "Service CIDR"
  type        = string
  default     = "10.0.0.0/16"
}

# Azure AD Configuration
variable "admin_group_object_ids" {
  description = "Azure AD admin groups"
  type        = list(string)
  default     = []
}

# Spoke Cluster Configuration (populated after spoke deployment)
variable "spoke_resource_group_ids" {
  description = "Spoke cluster resource group IDs"
  type        = list(string)
  default     = []
}

variable "spoke_cluster_ids" {
  description = "Map of spoke cluster IDs"
  type        = map(string)
  default     = {}
}

variable "spoke_environments" {
  description = "Spoke environment configurations"
  type        = map(object({
    name        = string
    description = optional(string, "")
  }))
  default = {
    dev = {
      name        = "development"
      description = "Development environment"
    }
    staging = {
      name        = "staging"
      description = "Staging environment"
    }
    prod = {
      name        = "production"
      description = "Production environment"
    }
  }
}

# RBAC Configuration
variable "create_ad_groups" {
  description = "Create Azure AD groups"
  type        = bool
  default     = true
}

variable "grant_subscription_reader" {
  description = "Grant subscription reader access"
  type        = bool
  default     = false
}

variable "create_key_vault" {
  description = "Create Key Vault for secrets"
  type        = bool
  default     = true
}

# Common Tags
variable "common_tags" {
  description = "Common resource tags"
  type        = map(string)
  default = {
    Environment = "hub"
    Project     = "aks-cicd"
    ManagedBy   = "terraform"
    Owner       = "platform-team"
  }
}