# Hub-to-Spoke Direct Deployment Examples

This directory contains examples and scripts for deploying resources directly from the hub cluster to spoke clusters using the hub cluster's managed identity.

## Quick Start

### 1. Set Environment Variables

```bash
# Set your spoke cluster details
export SPOKE_CLUSTER_NAME="myorg-dev-aks"
export SPOKE_RG="myorg-dev-rg"

# Optional: Set hub cluster details (defaults provided)
export HUB_RG="myorg-hub-rg"
export HUB_IDENTITY_NAME="myorg-hub-identity"
```

### 2. Run Quick Deployment

```bash
# Navigate to the scripts directory
cd /home/srinman/git/aks-cicd/hub-spoke-cd/scripts

# Execute the deployment
./quick-deploy.sh
```

### 3. Verify Deployment

```bash
# Verify the deployment worked
./verify-deployment.sh
```

### 4. Clean Up (Optional)

```bash
# Remove all deployed resources
./cleanup.sh
```

## What Gets Deployed

The quick deployment script creates:

- **Namespace**: `demo-app` on the spoke cluster
- **Deployment**: `nginx-demo` with 3 replicas
- **Service**: `nginx-demo-service` with LoadBalancer type
- **External IP**: Accessible nginx web server

## Expected Output

After successful deployment, you should see:

- ✅ Namespace `demo-app` created
- ✅ 3 nginx pods running
- ✅ LoadBalancer service with external IP
- ✅ Accessible web application

## Troubleshooting

### Permission Issues

If you get permission errors:

```bash
# Check hub identity permissions
HUB_IDENTITY_PRINCIPAL_ID=$(az identity show --resource-group $HUB_RG --name $HUB_IDENTITY_NAME --query principalId -o tsv)
SPOKE_CLUSTER_ID=$(az aks show --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME --query id -o tsv)

# Verify role assignment
az role assignment list --assignee $HUB_IDENTITY_PRINCIPAL_ID --scope $SPOKE_CLUSTER_ID
```

### Connectivity Issues

If kubectl can't connect:

```bash
# Verify cluster exists and is running
az aks show --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME --query provisioningState

# Get credentials again using managed identity
az aks get-credentials --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME --overwrite-existing --use-azuread
```

### External IP Not Assigned

If the LoadBalancer doesn't get an external IP:

```bash
# Check service status
kubectl describe service nginx-demo-service -n demo-app

# Check Azure Load Balancer events
kubectl get events -n demo-app --field-selector involvedObject.name=nginx-demo-service
```

## Advanced Usage

For more advanced scenarios, see the main [README.md](../README.md) which includes:

- Kubernetes Job-based deployment
- Azure Container Instances deployment
- CI/CD pipeline integration
- Custom resource definitions
- GitOps workflows

## Security Notes

- The hub cluster's managed identity has admin-level access to spoke clusters
- This enables cross-cluster resource management without user credentials
- All operations are audited through Azure Activity Log
- Permissions are scoped through Azure RBAC role assignments