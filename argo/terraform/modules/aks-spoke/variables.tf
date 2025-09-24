# Spoke Cluster Variables

variable "resource_group_name" {
  description = "Name of the resource group for the spoke cluster"
  type        = string
}

variable "location" {
  description = "Azure region for the spoke cluster"
  type        = string
  default     = "East US"
}

variable "cluster_name" {
  description = "Name of the spoke AKS cluster"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g., dev, staging, prod)"
  type        = string
}

variable "hub_cluster_name" {
  description = "Name of the hub cluster that manages this spoke cluster"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version for the spoke cluster"
  type        = string
  default     = "1.28.3"
}

variable "common_tags" {
  description = "Common tags to be applied to all resources"
  type        = map(string)
  default = {
    ManagedBy   = "terraform"
    Project     = "aks-cicd"
    ClusterType = "spoke"
  }
}

# Hub cluster identity information
variable "hub_identity_principal_id" {
  description = "Principal ID of the hub cluster managed identity"
  type        = string
}

variable "hub_identity_client_id" {
  description = "Client ID of the hub cluster managed identity"
  type        = string
}

# Node pool configuration
variable "system_node_count" {
  description = "Number of nodes in the system node pool"
  type        = number
  default     = 2
}

variable "system_node_min_count" {
  description = "Minimum number of nodes in system pool"
  type        = number
  default     = 1
}

variable "system_node_max_count" {
  description = "Maximum number of nodes in system pool"
  type        = number
  default     = 3
}

variable "system_node_vm_size" {
  description = "VM size for system nodes"
  type        = string
  default     = "Standard_D2s_v3"
}

variable "create_workload_pool" {
  description = "Whether to create a dedicated workload node pool"
  type        = bool
  default     = true
}

variable "workload_node_count" {
  description = "Number of nodes in the workload node pool"
  type        = number
  default     = 2
}

variable "workload_node_min_count" {
  description = "Minimum number of nodes in workload pool"
  type        = number
  default     = 0
}

variable "workload_node_max_count" {
  description = "Maximum number of nodes in workload pool"
  type        = number
  default     = 10
}

variable "workload_node_vm_size" {
  description = "VM size for workload nodes"
  type        = string
  default     = "Standard_D4s_v3"
}

variable "availability_zones" {
  description = "Availability zones for node pools"
  type        = list(string)
  default     = ["1", "2", "3"]
}

# Network configuration
variable "dns_service_ip" {
  description = "DNS service IP for the cluster"
  type        = string
  default     = "10.1.0.10"
}

variable "service_cidr" {
  description = "Service CIDR for the cluster"
  type        = string
  default     = "10.1.0.0/16"
}

# Azure AD integration
variable "admin_group_object_ids" {
  description = "List of Azure AD group object IDs that should have admin access to the cluster"
  type        = list(string)
  default     = []
}

# Monitoring
variable "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID for monitoring"
  type        = string
  default     = null
}