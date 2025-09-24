#!/bin/bash

# Integration script: terraform-deploy.sh
# This script uses Terraform to fetch spoke cluster info and then runs the deployment

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}"
}

print_success() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] ✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ✗ $1${NC}"
}

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$SCRIPT_DIR/../terraform"

print_status "Starting Terraform-integrated deployment"

# Check prerequisites
if ! command -v terraform &> /dev/null; then
    print_error "Terraform is not installed"
    exit 1
fi

if ! command -v az &> /dev/null; then
    print_error "Azure CLI is not installed"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    print_error "jq is not installed"
    print_status "Installing jq..."
    sudo apt-get update && sudo apt-get install -y jq
fi

# Navigate to Terraform directory
cd "$TERRAFORM_DIR"

# Check if terraform.tfvars exists
if [[ ! -f "terraform.tfvars" ]]; then
    print_error "terraform.tfvars not found"
    print_status "Please create terraform.tfvars from terraform.tfvars.example"
    print_status "Example:"
    echo "  cp terraform.tfvars.example terraform.tfvars"
    echo "  nano terraform.tfvars"
    exit 1
fi

# Initialize Terraform if needed
if [[ ! -d ".terraform" ]]; then
    print_status "Initializing Terraform..."
    terraform init
fi

# Validate configuration
print_status "Validating Terraform configuration..."
if ! terraform validate; then
    print_error "Terraform validation failed"
    exit 1
fi

# Apply Terraform (read-only operations)
print_status "Fetching spoke cluster information..."
if ! terraform apply -auto-approve; then
    print_error "Terraform apply failed"
    exit 1
fi

# Extract outputs
print_status "Extracting cluster information..."

# Method 1: Using terraform output with JSON parsing
ENV_VARS=$(terraform output -json environment_variables 2>/dev/null)
if [[ $? -eq 0 ]] && [[ -n "$ENV_VARS" ]]; then
    export SPOKE_RG=$(echo "$ENV_VARS" | jq -r '.SPOKE_RG')
    export SPOKE_CLUSTER_NAME=$(echo "$ENV_VARS" | jq -r '.SPOKE_CLUSTER_NAME')
    export SPOKE_FQDN=$(echo "$ENV_VARS" | jq -r '.SPOKE_FQDN')
    export HUB_IDENTITY_CLIENT_ID=$(echo "$ENV_VARS" | jq -r '.HUB_IDENTITY_CLIENT_ID')
else
    # Method 2: Extract individual outputs (fallback)
    print_warning "JSON output parsing failed, using individual outputs..."
    
    # Extract from terraform.tfvars as fallback
    if [[ -f "terraform.tfvars" ]]; then
        export SPOKE_RG=$(grep '^spoke_resource_group_name' terraform.tfvars | cut -d'"' -f2)
        export SPOKE_CLUSTER_NAME=$(grep '^spoke_cluster_name' terraform.tfvars | cut -d'"' -f2)
        
        # Try to get identity from terraform output
        export HUB_IDENTITY_CLIENT_ID=$(terraform output -raw hub_identity_client_id 2>/dev/null || echo "")
        export SPOKE_FQDN=$(terraform output -raw spoke_cluster_fqdn 2>/dev/null || echo "")
    else
        print_error "Could not extract cluster information"
        exit 1
    fi
fi

# Validate required variables
if [[ -z "$SPOKE_RG" ]] || [[ -z "$SPOKE_CLUSTER_NAME" ]]; then
    print_error "Required variables not set:"
    echo "  SPOKE_RG: '$SPOKE_RG'"
    echo "  SPOKE_CLUSTER_NAME: '$SPOKE_CLUSTER_NAME'"
    exit 1
fi

print_success "Cluster information extracted:"
echo "  Resource Group: $SPOKE_RG"
echo "  Cluster Name: $SPOKE_CLUSTER_NAME"
echo "  FQDN: ${SPOKE_FQDN:-'N/A'}"
echo "  Hub Identity: ${HUB_IDENTITY_CLIENT_ID:-'N/A'}"

# Generate kubectl config command
KUBECTL_CONFIG_CMD=$(terraform output -raw kubectl_config_command 2>/dev/null || echo "az aks get-credentials --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME --use-azuread --overwrite-existing")

print_status "Configuring kubectl for spoke cluster..."
eval "$KUBECTL_CONFIG_CMD"

if [[ $? -eq 0 ]]; then
    print_success "kubectl configured successfully"
else
    print_error "kubectl configuration failed"
    exit 1
fi

# Verify cluster connectivity
print_status "Verifying cluster connectivity..."
if kubectl cluster-info &>/dev/null; then
    print_success "Successfully connected to spoke cluster"
    kubectl cluster-info
else
    print_error "Failed to connect to spoke cluster"
    exit 1
fi

# Run the deployment script
print_status "Running deployment..."
cd "$SCRIPT_DIR"

if [[ -f "quick-deploy.sh" ]]; then
    # Export variables for the deployment script
    export SPOKE_RG
    export SPOKE_CLUSTER_NAME
    export SPOKE_FQDN
    export HUB_IDENTITY_CLIENT_ID
    
    print_status "Starting deployment script..."
    ./quick-deploy.sh
    
    if [[ $? -eq 0 ]]; then
        print_success "Deployment completed successfully!"
        print_status "You can verify the deployment by running:"
        echo "  ./verify-deployment.sh"
        print_status "To clean up resources later, run:"
        echo "  ./cleanup.sh"
    else
        print_error "Deployment failed"
        exit 1
    fi
else
    print_error "quick-deploy.sh not found in $SCRIPT_DIR"
    exit 1
fi

print_success "Terraform-integrated deployment completed!"