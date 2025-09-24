# Step-by-Step Implementation Guide

This guide provides comprehensive instructions for implementing the ArgoCD Hub-Spoke AKS architecture with Azure RBAC for Kubernetes authorization.

## Prerequisites

### Required Tools
- [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli) (latest version)
- [Terraform](https://www.terraform.io/downloads.html) (>= 1.5)
- [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl/)
- [kubelogin](https://github.com/Azure/kubelogin) (Azure CLI plugin for AKS)

### Azure Permissions Required
- **Subscription Contributor** or higher on target subscription(s)
- **Application Administrator** or **Cloud Application Administrator** in Azure AD (for creating service principals and groups)
- **User Access Administrator** (for RBAC assignments)

### Initial Setup Commands
```bash
# Login to Azure
az login

# Set default subscription
az account set --subscription "your-subscription-id"

# Install kubelogin
az aks install-cli

# Verify tools
terraform version
kubectl version --client
kubelogin --version
```

## Phase 1: Infrastructure Setup

### Step 1: Prepare Terraform Backend

Create a storage account for Terraform state management:

```bash
# Set variables
RESOURCE_GROUP_NAME="tfstate-rg"
STORAGE_ACCOUNT_NAME="tfstate$(openssl rand -hex 3)"  # Must be globally unique
CONTAINER_NAME="tfstate"
LOCATION="East US"

# Create resource group
az group create --name $RESOURCE_GROUP_NAME --location "$LOCATION"

# Create storage account
az storage account create \
    --resource-group $RESOURCE_GROUP_NAME \
    --name $STORAGE_ACCOUNT_NAME \
    --sku Standard_LRS \
    --encryption-services blob

# Get storage account key
ACCOUNT_KEY=$(az storage account keys list --resource-group $RESOURCE_GROUP_NAME --account-name $STORAGE_ACCOUNT_NAME --query '[0].value' -o tsv)

# Create blob container
az storage container create \
    --name $CONTAINER_NAME \
    --account-name $STORAGE_ACCOUNT_NAME \
    --account-key $ACCOUNT_KEY

echo "Storage Account Name: $STORAGE_ACCOUNT_NAME"
echo "Update this in your terraform backend configuration"
```

### Step 2: Configure Hub Cluster Variables

```bash
cd argo/terraform/environments/hub
cp hub.tfvars.example hub.tfvars

# Edit hub.tfvars with your specific values
vim hub.tfvars
```

**Key configurations to update:**
- `organization_prefix`: Your organization identifier
- `location`: Your preferred Azure region
- `admin_group_object_ids`: Azure AD group IDs for initial admin access
- Backend configuration in `main.tf`

### Step 3: Deploy Hub Cluster

```bash
# Initialize Terraform
terraform init

# Review the deployment plan
terraform plan -var-file="hub.tfvars"

# Deploy the hub cluster
terraform apply -var-file="hub.tfvars"

# Save important outputs
terraform output -json > hub-outputs.json
```

**Expected deployment time**: 10-15 minutes

### Step 4: Configure kubectl for Hub Cluster

```bash
# Get cluster credentials
HUB_RG=$(terraform output -raw resource_group_name)
HUB_CLUSTER=$(terraform output -raw hub_cluster_name)

az aks get-credentials \
    --resource-group $HUB_RG \
    --name $HUB_CLUSTER \
    --admin

# Verify connectivity
kubectl get nodes
kubectl get namespaces
```

## Phase 2: ArgoCD Installation

### Step 5: Install ArgoCD and Supporting Infrastructure

```bash
# Navigate to ArgoCD bootstrap directory
cd ../../argocd/bootstrap

# Update domain configuration in argocd-bootstrap.yaml
# Replace "argocd.your-domain.com" with your actual domain

# Install ArgoCD and infrastructure
kubectl apply -f argocd-bootstrap.yaml
kubectl apply -f infrastructure-apps.yaml

# Wait for ArgoCD to be ready
kubectl wait --for=condition=available --timeout=600s deployment/argocd-server -n argocd

# Get ArgoCD admin password
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | base64 -d
```

### Step 6: Configure ArgoCD Access

```bash
# Port forward to ArgoCD server (if not using ingress)
kubectl port-forward svc/argocd-server -n argocd 8080:443 &

# Access ArgoCD UI
# URL: https://localhost:8080 (or your configured domain)
# Username: admin
# Password: (from previous step)
```

## Phase 3: Spoke Cluster Deployment

### Step 7: Deploy Spoke Clusters

```bash
cd ../../terraform/environments/spokes

# Copy and configure spoke variables
cp spokes.tfvars.example spokes.tfvars
vim spokes.tfvars

# Initialize Terraform
terraform init

# Deploy spoke clusters
terraform plan -var-file="spokes.tfvars"
terraform apply -var-file="spokes.tfvars"

# Save spoke outputs
terraform output -json > spoke-outputs.json
```

### Step 8: Update Hub Configuration with Spoke Information

```bash
cd ../hub

# Extract spoke cluster information from outputs
DEV_RG_ID=$(cd ../spokes && terraform output -raw dev_resource_group_id)
DEV_CLUSTER_ID=$(cd ../spokes && terraform output -raw dev_cluster_id)

# Update hub.tfvars with spoke information
cat >> hub.tfvars << EOF

# Spoke cluster configuration (populated after spoke deployment)
spoke_resource_group_ids = ["$DEV_RG_ID"]
spoke_cluster_ids = {
  dev = "$DEV_CLUSTER_ID"
}
EOF

# Re-run terraform to update RBAC
terraform apply -var-file="hub.tfvars"
```

## Phase 4: Cluster Discovery and Application Deployment

### Step 9: Configure Cluster Secrets in ArgoCD

The spoke clusters automatically create cluster secrets for ArgoCD. Verify they're available:

```bash
# Check cluster secrets
kubectl get secrets -n argocd -l argocd.argoproj.io/secret-type=cluster

# Verify clusters in ArgoCD CLI (optional)
argocd cluster list
```

### Step 10: Deploy Applications via ArgoCD

Create an example application for the dev cluster:

```bash
# Create application directory structure (in your Git repository)
mkdir -p clusters/dev/applications

# Example application manifest
cat > clusters/dev/applications/nginx-example.yaml << EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: nginx-example
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://charts.bitnami.com/bitnami
    chart: nginx
    targetRevision: 15.4.0
    helm:
      parameters:
        - name: replicaCount
          value: "2"
  destination:
    server: https://dev-cluster-endpoint  # Will be auto-discovered
    namespace: argocd-managed
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

# Commit and push to your Git repository
git add .
git commit -m "Add nginx example application"
git push origin main
```

## Phase 5: Verification and Testing

### Step 11: Verify Hub-to-Spoke Connectivity

```bash
# Test access to spoke cluster from hub
kubectl config use-context $HUB_CLUSTER

# Check if ArgoCD can access spoke clusters
kubectl logs -n argocd deployment/argocd-application-controller | grep -i "cluster.*connected"

# Verify spoke cluster access
DEV_RG=$(cd ../spokes && terraform output -raw dev_resource_group_name)
DEV_CLUSTER=$(cd ../spokes && terraform output -raw dev_cluster_name)

az aks get-credentials \
    --resource-group $DEV_RG \
    --name $DEV_CLUSTER \
    --admin

kubectl get nodes
kubectl get namespaces
kubectl get pods -n argocd-managed
```

### Step 12: Test Application Deployment

```bash
# In ArgoCD UI or CLI, create an application targeting the dev cluster
# Verify the application syncs successfully
# Check pods are running in the target cluster

kubectl get pods -n argocd-managed
kubectl get applications -n argocd
```

### Step 13: Validate RBAC Configuration

```bash
# Test Azure RBAC integration
# Try accessing clusters with different Azure AD identities
# Verify appropriate permissions are enforced

# Check Azure role assignments
az role assignment list --assignee $HUB_IDENTITY_PRINCIPAL_ID --all
```

## Phase 6: Production Readiness

### Step 14: Security Hardening

1. **Network Security**:
   ```bash
   # Configure network policies
   kubectl apply -f ../kubernetes/rbac/network-policies.yaml
   ```

2. **RBAC Fine-tuning**:
   ```bash
   # Review and adjust Kubernetes RBAC
   kubectl auth can-i --list --as=system:serviceaccount:argocd:argocd-application-controller
   ```

3. **Secret Management**:
   ```bash
   # Configure Azure Key Vault integration
   # Rotate service account tokens
   # Enable audit logging
   ```

### Step 15: Monitoring and Observability

```bash
# Verify Log Analytics integration
az monitor log-analytics query \
    --workspace $LOG_ANALYTICS_WORKSPACE_ID \
    --analytics-query "ContainerLog | where TimeGenerated > ago(1h) | limit 10"

# Check ArgoCD metrics
kubectl get servicemonitor -n argocd
```

### Step 16: Backup and Disaster Recovery

```bash
# Backup ArgoCD configuration
kubectl get applications,projects,repositories -n argocd -o yaml > argocd-backup.yaml

# Configure automated backups
# Document recovery procedures
```

## Common Operations

### Adding a New Spoke Cluster

1. Update spoke cluster configuration in Terraform
2. Run `terraform apply` in spokes environment
3. Update hub configuration with new spoke information
4. Run `terraform apply` in hub environment
5. Verify cluster appears in ArgoCD

### Updating Kubernetes Version

1. Update `kubernetes_version` in tfvars files
2. Apply changes using `terraform apply`
3. Monitor cluster upgrades in Azure portal

### Troubleshooting Connectivity Issues

1. Check Azure RBAC assignments
2. Verify kubelogin configuration
3. Check ArgoCD application controller logs
4. Validate network connectivity between clusters

## Security Considerations

### Network Security
- Use Azure Private Link for AKS API servers in production
- Implement network policies to restrict pod-to-pod communication
- Configure Azure Firewall or NSGs for egress control

### Identity and Access Management
- Regular review of Azure AD group memberships
- Implement just-in-time access for administrative operations
- Use Azure PIM (Privileged Identity Management) for elevated access

### Secret Management
- Store sensitive data in Azure Key Vault
- Use workload identity for pod-level authentication
- Rotate service account tokens regularly

### Compliance and Auditing
- Enable Azure Policy for Kubernetes
- Configure audit logging for all clusters
- Implement resource tagging standards
- Regular security assessments and penetration testing

## Cost Optimization

### Resource Rightsizing
- Monitor cluster utilization using Azure Monitor
- Implement horizontal pod autoscaling
- Use spot instances for non-critical workloads

### Multi-region Considerations
- Deploy spoke clusters across multiple regions for high availability
- Consider data residency requirements
- Implement cross-region backup strategies

This implementation provides a robust, scalable foundation for managing multiple AKS clusters with centralized GitOps deployment through ArgoCD.