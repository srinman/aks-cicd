# Azure Workload Identity Setup for Hub-to-Spoke Operations

This guide covers setting up Azure Workload Identity for hub cluster workloads to access spoke clusters. Workload Identity is the modern, secure way to authenticate Kubernetes workloads to Azure services without storing credentials.

## Overview

Azure Workload Identity uses OpenID Connect (OIDC) federation between Azure AD and the Kubernetes cluster's OIDC issuer. This eliminates the need for stored secrets and provides short-lived, automatically rotated tokens.

### Benefits
- ✅ No stored credentials or secrets
- ✅ Automatic token rotation
- ✅ Kubernetes-native service account mapping
- ✅ Audit trail with specific identity attribution
- ✅ Principle of least privilege
- ✅ Works seamlessly with ArgoCD and other GitOps tools

## Prerequisites

1. **AKS cluster with OIDC issuer enabled**
2. **Azure CLI version 2.40.0 or higher**
3. **kubectl access to the hub cluster**
4. **Permissions to create Azure AD applications and federated credentials**

## Step 1: Enable Workload Identity on Hub Cluster

### Option 1: Enable on Existing Cluster

```bash
# Set variables
HUB_RG="myorg-hub-rg"
HUB_CLUSTER_NAME="aks-hub-prod-001"

# Enable workload identity and OIDC issuer
az aks update \
    --resource-group $HUB_RG \
    --name $HUB_CLUSTER_NAME \
    --enable-workload-identity \
    --enable-oidc-issuer

# Get the OIDC issuer URL (we'll need this later)
export AKS_OIDC_ISSUER="$(az aks show --resource-group $HUB_RG --name $HUB_CLUSTER_NAME --query "oidcIssuerProfile.issuerUrl" -o tsv)"
echo "OIDC Issuer URL: $AKS_OIDC_ISSUER"
```

### Option 2: Create New Cluster with Workload Identity

```bash
# Create cluster with workload identity enabled
az aks create \
    --resource-group $HUB_RG \
    --name $HUB_CLUSTER_NAME \
    --location eastus \
    --node-count 3 \
    --enable-workload-identity \
    --enable-oidc-issuer \
    --enable-managed-identity \
    --generate-ssh-keys

# Get the OIDC issuer URL
export AKS_OIDC_ISSUER="$(az aks show --resource-group $HUB_RG --name $HUB_CLUSTER_NAME --query "oidcIssuerProfile.issuerUrl" -o tsv)"
echo "OIDC Issuer URL: $AKS_OIDC_ISSUER"
```

## Step 2: Create Azure AD Application and Service Principal

```bash
# Create Azure AD application for workload identity
export APPLICATION_NAME="hub-to-spoke-workload-identity"

az ad app create --display-name $APPLICATION_NAME

# Get the application ID
export APPLICATION_CLIENT_ID=$(az ad app list --display-name $APPLICATION_NAME --query '[0].appId' -o tsv)
echo "Application Client ID: $APPLICATION_CLIENT_ID"

# Create service principal
az ad sp create --id $APPLICATION_CLIENT_ID

# Get the service principal object ID
export SERVICE_PRINCIPAL_ID=$(az ad sp show --id $APPLICATION_CLIENT_ID --query id -o tsv)
echo "Service Principal Object ID: $SERVICE_PRINCIPAL_ID"
```

## Step 3: Create Kubernetes Service Account

```bash
# Get AKS credentials
az aks get-credentials --resource-group $HUB_RG --name $HUB_CLUSTER_NAME --overwrite-existing

# Create namespace for hub-to-spoke operations
kubectl create namespace hub-operations --dry-run=client -o yaml | kubectl apply -f -

# Create service account with workload identity annotation
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: hub-to-spoke-sa
  namespace: hub-operations
  annotations:
    azure.workload.identity/client-id: $APPLICATION_CLIENT_ID
  labels:
    azure.workload.identity/use: "true"
EOF

echo "✅ Service account created with client ID: $APPLICATION_CLIENT_ID"
```

## Step 4: Create Federated Credential

```bash
# Set the service account details
export SERVICE_ACCOUNT_NAMESPACE="hub-operations"
export SERVICE_ACCOUNT_NAME="hub-to-spoke-sa"

# Create federated credential for the service account
az ad app federated-credential create \
    --id $APPLICATION_CLIENT_ID \
    --parameters '{
        "name": "hub-to-spoke-federated-credential",
        "issuer": "'$AKS_OIDC_ISSUER'",
        "subject": "system:serviceaccount:'$SERVICE_ACCOUNT_NAMESPACE':'$SERVICE_ACCOUNT_NAME'",
        "description": "Federated credential for hub-to-spoke operations",
        "audiences": ["api://AzureADTokenExchange"]
    }'

echo "✅ Federated credential created"
echo "  Issuer: $AKS_OIDC_ISSUER"
echo "  Subject: system:serviceaccount:$SERVICE_ACCOUNT_NAMESPACE:$SERVICE_ACCOUNT_NAME"
```

## Step 5: Assign RBAC Permissions on Spoke Clusters

Now assign the workload identity permissions to access spoke clusters:

```bash
# Set spoke cluster variables
export SPOKE_RG="myorg-spoke-rg"
export SPOKE_CLUSTER_NAME="aks-spoke-prod-001"

# Get spoke cluster resource ID
export SPOKE_CLUSTER_ID=$(az aks show --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME --query id -o tsv)

# Assign Azure Kubernetes Service Cluster Admin Role to the service principal
az role assignment create \
    --assignee $SERVICE_PRINCIPAL_ID \
    --role "Azure Kubernetes Service Cluster Admin Role" \
    --scope $SPOKE_CLUSTER_ID

echo "✅ RBAC permissions assigned to spoke cluster"
echo "  Service Principal: $SERVICE_PRINCIPAL_ID"
echo "  Role: Azure Kubernetes Service Cluster Admin Role"
echo "  Scope: $SPOKE_CLUSTER_ID"

# Verify the role assignment
az role assignment list --assignee $SERVICE_PRINCIPAL_ID --scope $SPOKE_CLUSTER_ID -o table
```

## Step 6: Test Workload Identity Setup

Create a test pod to verify the workload identity configuration:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: workload-identity-test
  namespace: hub-operations
  labels:
    azure.workload.identity/use: "true"
spec:
  serviceAccountName: hub-to-spoke-sa
  containers:
  - name: test-container
    image: mcr.microsoft.com/azure-cli:latest
    command: ["/bin/bash"]
    args:
    - -c
    - |
      echo "🧪 Testing Workload Identity Setup"
      echo "=================================="
      
      # Check environment variables
      echo "Environment variables:"
      env | grep AZURE_ | sort
      echo ""
      
      # Check if Azure CLI can authenticate
      echo "Testing Azure CLI authentication..."
      if az account show; then
        echo "✅ Successfully authenticated with workload identity"
      else
        echo "❌ Failed to authenticate with workload identity"
        exit 1
      fi
      
      # Test access to spoke cluster
      echo ""
      echo "Testing spoke cluster access..."
      az aks get-credentials --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME --use-azuread --file /tmp/kubeconfig
      
      if KUBECONFIG=/tmp/kubeconfig kubectl cluster-info; then
        echo "✅ Successfully accessed spoke cluster"
      else
        echo "❌ Failed to access spoke cluster"
        exit 1
      fi
      
      echo ""
      echo "🎉 Workload identity test completed successfully!"
      
      # Keep container running for inspection
      sleep 300
  restartPolicy: Never
EOF

# Monitor the test
echo "Monitoring workload identity test..."
kubectl logs -f workload-identity-test -n hub-operations
```

## Step 7: Configure for Multiple Spoke Clusters

To access multiple spoke clusters, assign the same service principal to each:

```bash
# Function to assign permissions to a spoke cluster
assign_spoke_permissions() {
    local spoke_rg=$1
    local spoke_cluster=$2
    
    echo "Assigning permissions to $spoke_cluster in $spoke_rg..."
    
    local spoke_cluster_id=$(az aks show --resource-group $spoke_rg --name $spoke_cluster --query id -o tsv)
    
    az role assignment create \
        --assignee $SERVICE_PRINCIPAL_ID \
        --role "Azure Kubernetes Service Cluster Admin Role" \
        --scope $spoke_cluster_id
    
    echo "✅ Permissions assigned to $spoke_cluster"
}

# Example: Assign to multiple spoke clusters
assign_spoke_permissions "myorg-dev-rg" "aks-spoke-dev-001"
assign_spoke_permissions "myorg-staging-rg" "aks-spoke-staging-001"
assign_spoke_permissions "myorg-prod-rg" "aks-spoke-prod-001"

# Verify all assignments
echo ""
echo "All role assignments for workload identity:"
az role assignment list --assignee $SERVICE_PRINCIPAL_ID -o table
```

## Step 8: Environment Variables Reference

When using workload identity, the following environment variables are automatically provided:

```bash
# These are automatically set by the workload identity webhook
AZURE_CLIENT_ID="$APPLICATION_CLIENT_ID"
AZURE_TENANT_ID="$(az account show --query tenantId -o tsv)"
AZURE_FEDERATED_TOKEN_FILE="/var/run/secrets/azure/tokens/azure-identity-token"
AZURE_AUTHORITY_HOST="https://login.microsoftonline.com/"
```

## Step 9: Validation Commands

```bash
# Verify workload identity is enabled on cluster
az aks show --resource-group $HUB_RG --name $HUB_CLUSTER_NAME --query "securityProfile.workloadIdentity" -o table

# Check OIDC issuer
az aks show --resource-group $HUB_RG --name $HUB_CLUSTER_NAME --query "oidcIssuerProfile" -o table

# List federated credentials
az ad app federated-credential list --id $APPLICATION_CLIENT_ID -o table

# Verify service account annotation
kubectl get serviceaccount hub-to-spoke-sa -n hub-operations -o yaml

# Check role assignments
az role assignment list --assignee $SERVICE_PRINCIPAL_ID -o table
```

## Troubleshooting

### Common Issues

1. **"AADSTS70021: No matching federated identity record found"**
   - Verify the federated credential subject matches exactly: `system:serviceaccount:namespace:serviceaccount-name`
   - Check that the OIDC issuer URL is correct

2. **"Failed to get token from IMDS"**
   - Ensure workload identity is enabled on the cluster
   - Verify the pod has the `azure.workload.identity/use: "true"` label
   - Check that the service account has the client ID annotation

3. **"Insufficient privileges to complete the operation"**
   - Verify RBAC role assignments are correct
   - Check that the service principal has the required permissions on spoke clusters

### Validation Script

```bash
#!/bin/bash
# workload-identity-validation.sh

echo "🔍 Workload Identity Validation"
echo "==============================="

# Check if workload identity is enabled
echo "1. Checking workload identity status..."
WI_ENABLED=$(az aks show --resource-group $HUB_RG --name $HUB_CLUSTER_NAME --query "securityProfile.workloadIdentity.enabled" -o tsv)
if [ "$WI_ENABLED" = "true" ]; then
    echo "✅ Workload Identity is enabled"
else
    echo "❌ Workload Identity is not enabled"
fi

# Check OIDC issuer
echo ""
echo "2. OIDC Issuer configuration:"
OIDC_ISSUER=$(az aks show --resource-group $HUB_RG --name $HUB_CLUSTER_NAME --query "oidcIssuerProfile.issuerUrl" -o tsv)
echo "   Issuer URL: $OIDC_ISSUER"

# Check federated credentials
echo ""
echo "3. Federated credentials:"
az ad app federated-credential list --id $APPLICATION_CLIENT_ID -o table

# Check service account
echo ""
echo "4. Service account configuration:"
kubectl get serviceaccount hub-to-spoke-sa -n hub-operations -o yaml | grep -A5 -B5 azure.workload.identity

# Check role assignments
echo ""
echo "5. RBAC role assignments:"
az role assignment list --assignee $SERVICE_PRINCIPAL_ID -o table

echo ""
echo "✅ Validation completed"
```

## Security Best Practices

1. **Use specific service accounts** for different workloads
2. **Apply least privilege** - only assign necessary RBAC roles
3. **Use namespaces** to isolate workloads
4. **Monitor token usage** through Azure AD audit logs
5. **Regularly audit** role assignments and federated credentials
6. **Use resource-scoped roles** instead of subscription-level permissions
7. **Implement proper RBAC** within Kubernetes clusters as well

## Integration with GitOps

Workload Identity works seamlessly with GitOps tools like ArgoCD:

```yaml
# ArgoCD Application with workload identity
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: spoke-cluster-app
  namespace: argocd
spec:
  source:
    repoURL: https://github.com/myorg/k8s-manifests
    path: spoke-cluster/
    targetRevision: main
  destination:
    server: https://aks-spoke-api-server-url:443
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

The ArgoCD pods will automatically use the workload identity when configured with the proper service account and annotations.

## Next Steps

After setting up workload identity:

1. Update deployment scripts to use workload identity authentication
2. Configure ArgoCD or other GitOps tools to use the service account
3. Test cross-cluster deployments with the new authentication method
4. Set up monitoring and alerting for authentication failures
5. Document the setup for your team

This workload identity setup provides a secure, scalable foundation for hub-to-spoke operations without managing secrets or credentials.