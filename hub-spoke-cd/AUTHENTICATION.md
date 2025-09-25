# AKS Authentication Methods Guide

This guide explains the different authentication methods for accessing AKS clusters using Azure AD integration, based on the [Microsoft kubelogin documentation](https://learn.microsoft.com/en-us/azure/aks/kubelogin-authentication).

## Overview

For AKS clusters with Azure AD integration and Kubernetes 1.24+, the `az aks get-credentials --use-azuread` command automatically uses the kubelogin format. This guide covers when and how to use different authentication methods.

## Authentication Methods

### 1. Azure CLI Authentication (Default)

**When to use:**
- Interactive development
- When you have an active `az login` session
- Local development scenarios

**How it works:**
- Uses the signed-in context from Azure CLI
- Tokens are managed by Azure CLI (not cached by kubelogin)
- Works only with AKS managed Azure AD

**Commands:**
```bash
# Login to Azure CLI
az login

# Get credentials (automatically uses Azure CLI auth)
az aks get-credentials --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME --use-azuread

# Test connection
kubectl get nodes
```

### 2. Managed Identity Authentication

**When to use:**
- Hub cluster workloads accessing spoke clusters
- Azure VM, VMSS, or Cloud Shell environments
- Automated scenarios without user interaction

**How it works:**
- Uses managed identity assigned to the compute resource
- No credential caching needed
- Supports both system-assigned and user-assigned identities

**Commands:**
```bash
# Get credentials first
az aks get-credentials --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME --use-azuread

# Convert to use default managed identity
kubelogin convert-kubeconfig -l msi

# Or use specific managed identity
kubelogin convert-kubeconfig -l msi --client-id $MANAGED_IDENTITY_CLIENT_ID

# Test connection
kubectl get nodes
```

### 3. Service Principal Authentication

**When to use:**
- CI/CD pipelines
- Automated deployments
- Non-interactive scenarios with service principals

**How it works:**
- Uses service principal credentials (client ID + secret or certificate)
- Credentials can be provided via environment variables or command line
- Works only with managed Azure AD

**Commands:**

**Option A: Environment Variables**
```bash
# Set environment variables
export AAD_SERVICE_PRINCIPAL_CLIENT_ID=<client-id>
export AAD_SERVICE_PRINCIPAL_CLIENT_SECRET=<client-secret>

# Get credentials and convert
az aks get-credentials --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME --use-azuread
kubelogin convert-kubeconfig -l spn

# Test connection
kubectl get nodes
```

**Option B: Command Line**
```bash
# Get credentials and convert with inline parameters
az aks get-credentials --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME --use-azuread
kubelogin convert-kubeconfig -l spn --client-id <client-id> --client-secret <client-secret>

# Test connection
kubectl get nodes
```

### 4. Workload Identity Authentication

**When to use:**
- Modern Kubernetes workloads with federated identities
- GitHub Actions with OIDC
- ArgoCD with workload identity
- Eliminates need for stored credentials

**How it works:**
- Uses federated identity tokens (JWT)
- Requires specific environment variables
- Modern replacement for service principals

**Commands:**
```bash
# Environment variables (usually set by the platform)
export AZURE_CLIENT_ID=<federated-identity-client-id>
export AZURE_TENANT_ID=<tenant-id>
export AZURE_FEDERATED_TOKEN_FILE=/path/to/token/file

# Get credentials and convert
az aks get-credentials --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME --use-azuread
kubelogin convert-kubeconfig -l workloadidentity

# Test connection
kubectl get nodes
```

### 5. Interactive Web Browser

**When to use:**
- When device code flow doesn't work (Conditional Access policies)
- Interactive scenarios requiring browser authentication
- MFA-enabled accounts

**Commands:**
```bash
# Get credentials and convert
az aks get-credentials --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME --use-azuread
kubelogin convert-kubeconfig -l interactive

# Test connection (will open browser)
kubectl get nodes
```

## Hub-to-Spoke Specific Scenarios

### Scenario 1: Hub Cluster Job Accessing Spoke Cluster

**Best Practice:** Use managed identity authentication

```yaml
# Kubernetes Job on hub cluster
apiVersion: batch/v1
kind: Job
metadata:
  name: deploy-to-spoke
spec:
  template:
    spec:
      containers:
      - name: deployer
        image: mcr.microsoft.com/azure-cli:latest
        env:
        - name: HUB_IDENTITY_CLIENT_ID
          value: "<hub-managed-identity-client-id>"
        command:
        - /bin/bash
        - -c
        - |
          # Login using managed identity
          az login --identity --username $HUB_IDENTITY_CLIENT_ID
          
          # Get spoke cluster credentials
          az aks get-credentials --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME --use-azuread
          
          # Convert to use managed identity (optional but recommended)
          kubelogin convert-kubeconfig -l msi --client-id $HUB_IDENTITY_CLIENT_ID
          
          # Deploy resources
          kubectl apply -f manifests/
```

### Scenario 2: CI/CD Pipeline Deployment

**Best Practice:** Use service principal or workload identity

```bash
# GitHub Actions example
- name: Deploy to Spoke Cluster
  env:
    AAD_SERVICE_PRINCIPAL_CLIENT_ID: ${{ secrets.AZURE_CLIENT_ID }}
    AAD_SERVICE_PRINCIPAL_CLIENT_SECRET: ${{ secrets.AZURE_CLIENT_SECRET }}
  run: |
    az aks get-credentials --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME --use-azuread
    kubelogin convert-kubeconfig -l spn
    kubectl apply -f deployment.yaml
```

### Scenario 3: Local Development Testing

**Best Practice:** Use Azure CLI authentication

```bash
# Developer workflow
az login
az aks get-credentials --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME --use-azuread
kubectl get pods
```

## Troubleshooting Authentication

### Common Issues and Solutions

**Issue: "exec plugin: invalid apiVersion"**
```bash
# Update kubelogin
az aks install-cli
# Or
curl -LO https://github.com/Azure/kubelogin/releases/latest/download/kubelogin-linux-amd64.zip
unzip kubelogin-linux-amd64.zip
sudo mv bin/linux_amd64/kubelogin /usr/local/bin/
```

**Issue: "failed to refresh token"**
```bash
# Clear kubelogin cache
kubelogin remove-tokens

# Re-authenticate
az login
az aks get-credentials --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME --use-azuread --overwrite-existing
```

**Issue: "managed identity not found"**
```bash
# Verify managed identity is assigned
az vm identity show --resource-group $RG --name $VM_NAME
# Or for VMSS
az vmss identity show --resource-group $RG --name $VMSS_NAME

# Check role assignments
az role assignment list --assignee $MANAGED_IDENTITY_OBJECT_ID
```

### Verification Commands

```bash
# Check current authentication method
kubectl config view --minify -o jsonpath='{.users[0].user.exec.args}'

# Test cluster connectivity
kubectl cluster-info

# Verify permissions
kubectl auth can-i "*" "*" --all-namespaces

# Check kubelogin version
kubelogin --version

# View current kubeconfig
kubectl config current-context
```

## Best Practices

1. **Use managed identity** for Azure-hosted workloads
2. **Use workload identity** for modern Kubernetes deployments
3. **Avoid storing service principal secrets** in kubeconfig files
4. **Enable audit logging** to track authentication events
5. **Use least privilege** role assignments
6. **Regularly rotate credentials** for service principals
7. **Cache tokens appropriately** based on your scenario

## References

- [Microsoft kubelogin documentation](https://learn.microsoft.com/en-us/azure/aks/kubelogin-authentication)
- [AKS managed Azure AD integration](https://learn.microsoft.com/en-us/azure/aks/managed-azure-ad)
- [Azure Workload Identity](https://learn.microsoft.com/en-us/azure/aks/workload-identity-overview)
- [kubelogin GitHub repository](https://github.com/Azure/kubelogin)