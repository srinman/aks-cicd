# Terraform Setup for Hub-to-Spoke Cluster Operations

This directory contains Terraform configurations to fetch spoke cluster endpoints and configure hub-to-spoke operations using managed identity authentication.

## Terraform Providers Used

### 1. AzureRM Provider (`hashicorp/azurerm`)
- **Purpose**: Primary provider for Azure resource management
- **Version**: `~> 3.0` (latest 3.x version)
- **Usage**: Fetches AKS cluster information, resource groups, and managed identities
- **Authentication**: Uses Azure CLI credentials or managed identity

### 2. Azure AD Provider (`hashicorp/azuread`) 
- **Purpose**: Azure Active Directory operations (optional, for advanced scenarios)
- **Version**: `~> 2.0` 
- **Usage**: Role assignments and identity management
- **Authentication**: Same as AzureRM provider

## Setup Steps

### Step 1: Prerequisites

Ensure you have the following installed and configured:

```bash
# Install Terraform (version >= 1.0)
# On Ubuntu/Debian:
sudo apt-get update && sudo apt-get install -y gnupg software-properties-common
wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor | sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install terraform

# Verify installation
terraform version

# Install Azure CLI (if not already installed)
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# Login to Azure
az login
```

### Step 2: Authentication Setup

Choose one of the following authentication methods:

#### Option A: Azure CLI Authentication (Recommended for development)
```bash
# Login with your Azure account
az login

# Set default subscription (if you have multiple)
az account set --subscription "your-subscription-id"

# Verify authentication
az account show
```

#### Option B: Managed Identity (For production workloads running on Azure)
```bash
# When running on Azure VM, AKS, or other Azure services
# Terraform will automatically use the assigned managed identity
# No additional authentication needed
```

#### Option C: Service Principal (For CI/CD pipelines)
```bash
# Set environment variables
export ARM_CLIENT_ID="your-service-principal-client-id"
export ARM_CLIENT_SECRET="your-service-principal-secret"
export ARM_SUBSCRIPTION_ID="your-subscription-id"
export ARM_TENANT_ID="your-tenant-id"
```

### Step 3: Configuration Files Setup

1. **Navigate to terraform directory:**
   ```bash
   cd /home/srinman/git/aks-cicd/hub-spoke-cd/terraform
   ```

2. **Create terraform.tfvars file:**
   ```bash
   # Copy the example file
   cp terraform.tfvars.example terraform.tfvars
   
   # Edit with your actual values
   nano terraform.tfvars
   ```

3. **Update terraform.tfvars with your cluster information:**
   ```hcl
   # Spoke cluster configuration
   spoke_resource_group_name = "rg-aks-spoke-prod-001"
   spoke_cluster_name        = "aks-spoke-prod-001"
   
   # Hub cluster configuration
   hub_resource_group_name = "rg-aks-hub-prod-001"
   hub_cluster_name        = "aks-hub-prod-001"
   ```

### Step 4: Initialize and Apply Terraform

```bash
# Initialize Terraform (downloads providers)
terraform init

# Validate configuration
terraform validate

# Plan the execution (dry run)
terraform plan

# Apply the configuration (read-only operations, no resources created)
terraform apply
```

### Step 5: Use Outputs

After applying, Terraform will output the spoke cluster information:

```bash
# View all outputs
terraform output

# View specific outputs
terraform output spoke_cluster_endpoint
terraform output kubectl_config_command
terraform output environment_variables

# Export environment variables for scripts
eval "$(terraform output -json environment_variables | jq -r 'to_entries[] | "export \(.key)=\(.value)"')"

# Or manually set variables
export SPOKE_RG=$(terraform output -raw spoke_cluster_endpoint | cut -d'/' -f5)
export SPOKE_CLUSTER_NAME=$(terraform output -raw spoke_cluster_name)
```

## Configuration Options

### Option 1: Direct Cluster Data Source (`spoke-cluster-data.tf`)

**Use when:**
- You know the spoke cluster name and resource group
- Spoke cluster already exists
- You need real-time cluster information

**Advantages:**
- Simple and direct
- Always gets current cluster state
- No dependency on remote state

**Configuration:**
- Uses `azurerm_kubernetes_cluster` data source
- Fetches cluster endpoint, CA certificate, and FQDN
- Gets hub cluster managed identity information

### Option 2: Remote State Data Source (`remote-state-example.tf`)

**Use when:**
- Spoke cluster was created with Terraform
- Terraform state is stored in Azure Storage
- You want to reference outputs from spoke cluster creation

**Advantages:**
- Leverages existing Terraform state
- Can access all outputs from spoke cluster deployment
- Maintains consistency with infrastructure-as-code approach

**Configuration:**
- Requires remote state backend configuration
- Uses `terraform_remote_state` data source
- Depends on spoke cluster Terraform outputs

## Key Outputs Explained

### 1. `spoke_cluster_endpoint`
- **Purpose**: API server URL for the spoke cluster
- **Usage**: Direct kubectl API calls or cluster configuration
- **Example**: `https://aks-spoke-dns-12345678.hcp.eastus.azmk8s.io:443`

### 2. `kubectl_config_command`
- **Purpose**: Ready-to-use command for kubectl configuration
- **Usage**: Configure kubectl to connect to spoke cluster with managed identity
- **Example**: `az aks get-credentials --resource-group rg-spoke --name aks-spoke --use-azuread`

### 3. `hub_identity_client_id`
- **Purpose**: Client ID of hub cluster's managed identity
- **Usage**: Authentication when hub workloads access spoke cluster
- **Security**: Used for Azure AD authentication flow

### 4. `environment_variables`
- **Purpose**: Pre-formatted environment variables for scripts
- **Usage**: Source into shell scripts or CI/CD pipelines
- **Content**: All necessary variables for hub-to-spoke operations

## Integration with Hub-Spoke Scripts

### Method 1: Export Variables from Terraform
```bash
# Navigate to terraform directory
cd terraform/

# Initialize and apply
terraform init && terraform apply

# Export variables
export SPOKE_RG=$(terraform output -raw environment_variables | jq -r '.SPOKE_RG')
export SPOKE_CLUSTER_NAME=$(terraform output -raw environment_variables | jq -r '.SPOKE_CLUSTER_NAME')
export HUB_IDENTITY_CLIENT_ID=$(terraform output -raw environment_variables | jq -r '.HUB_IDENTITY_CLIENT_ID')

# Run deployment script
cd ../scripts/
./quick-deploy.sh
```

### Method 2: Generate Script with Variables
```bash
# Create a deployment script with embedded variables
terraform output kubectl_config_command > ../scripts/configure-kubectl.sh
chmod +x ../scripts/configure-kubectl.sh

# Use the generated script
../scripts/configure-kubectl.sh
```

### Method 3: CI/CD Integration
```yaml
# Example for Azure DevOps or GitHub Actions
- name: Get Spoke Cluster Info
  run: |
    cd terraform/
    terraform init
    terraform apply -auto-approve
    
    # Export as pipeline variables
    echo "SPOKE_RG=$(terraform output -raw environment_variables | jq -r '.SPOKE_RG')" >> $GITHUB_ENV
    echo "SPOKE_CLUSTER_NAME=$(terraform output -raw environment_variables | jq -r '.SPOKE_CLUSTER_NAME')" >> $GITHUB_ENV
    echo "HUB_IDENTITY_CLIENT_ID=$(terraform output -raw environment_variables | jq -r '.HUB_IDENTITY_CLIENT_ID')" >> $GITHUB_ENV
```

## Troubleshooting

### Common Issues

1. **Authentication Errors**
   ```bash
   # Verify Azure login
   az account show
   
   # Check permissions on spoke cluster
   az aks show --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME --query "identity"
   ```

2. **Terraform Provider Errors**
   ```bash
   # Re-initialize providers
   rm -rf .terraform/
   terraform init
   ```

3. **Resource Not Found**
   ```bash
   # Verify resource group and cluster exist
   az group show --name $SPOKE_RG
   az aks show --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME
   ```

4. **Managed Identity Issues**
   ```bash
   # Check hub cluster identity
   az aks show --resource-group $HUB_RG --name $HUB_CLUSTER_NAME --query "identityProfile"
   
   # Verify role assignments
   az role assignment list --assignee $HUB_IDENTITY_CLIENT_ID --scope $SPOKE_CLUSTER_ID
   ```

## Security Considerations

1. **State File Security**
   - Store Terraform state in secure Azure Storage with encryption
   - Use managed identity for state backend authentication
   - Enable blob versioning and soft delete

2. **Output Sensitivity**
   - CA certificates are marked as sensitive
   - Use `terraform output -raw` carefully in scripts
   - Avoid logging sensitive values

3. **Least Privilege**
   - Grant only necessary permissions to service principals
   - Use resource-scoped role assignments
   - Regularly audit and rotate credentials

4. **Local Admin Account Security**
   - Always disable local admin accounts on production clusters
   - Use `create-secure-spoke-cluster.tf` for new cluster creation
   - Ensure Azure AD integration is properly configured
   - Test Azure AD authentication before disabling local accounts

### Creating Secure Spoke Clusters

To create a spoke cluster with local admin disabled from the start:

```bash
# Use the secure cluster configuration
cp create-secure-spoke.tfvars.example create-secure-spoke.tfvars
nano create-secure-spoke.tfvars  # Update with your values

# Apply the secure configuration
terraform init
terraform plan -var-file="create-secure-spoke.tfvars"
terraform apply -var-file="create-secure-spoke.tfvars"
```

This ensures:
- Local admin account is disabled (`local_account_disabled = true`)
- Azure AD integration is mandatory
- Hub cluster automatically gets admin access
- All authentication goes through Azure AD

## Advanced Usage

### Custom Data Sources
```hcl
# Example: Filter clusters by tags
data "azurerm_resources" "spoke_clusters" {
  type                = "Microsoft.ContainerService/managedClusters"
  resource_group_name = var.spoke_resource_group_name
  
  required_tags = {
    environment = "production"
    cluster-type = "spoke"
  }
}

# Use the first matching cluster
data "azurerm_kubernetes_cluster" "tagged_spoke" {
  name                = data.azurerm_resources.spoke_clusters.resources[0].name
  resource_group_name = var.spoke_resource_group_name
}
```

### Multiple Spoke Clusters
```hcl
# Variables for multiple spoke clusters
variable "spoke_clusters" {
  description = "Map of spoke clusters"
  type = map(object({
    name                = string
    resource_group_name = string
  }))
}

# Data sources for multiple spoke clusters
data "azurerm_kubernetes_cluster" "spokes" {
  for_each = var.spoke_clusters
  
  name                = each.value.name
  resource_group_name = each.value.resource_group_name
}

# Outputs for multiple clusters
output "all_spoke_endpoints" {
  value = {
    for k, v in data.azurerm_kubernetes_cluster.spokes : k => {
      endpoint = v.kube_config.0.host
      fqdn     = v.fqdn
    }
  }
}
```

This Terraform setup provides a robust, secure, and scalable way to fetch spoke cluster information for hub-to-spoke operations while maintaining proper authentication through managed identity.