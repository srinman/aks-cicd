# ArgoCD Hub-Spoke AKS with Azure CLI

This document provides step-by-step instructions for implementing the ArgoCD Hub-Spoke AKS architecture using Azure CLI instead of Terraform for Azure resource management, while continuing to use ArgoCD for GitOps operations.

## Prerequisites

### Required Tools
- [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli) (latest version)
- [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl/)
- [kubelogin](https://github.com/Azure/kubelogin)
- [helm](https://helm.sh/docs/intro/install/) (for ArgoCD installation)

### Azure CLI Extensions
```bash
# Install required extensions
az extension add --name aks-preview
az extension update --name aks-preview

# Register required providers
az provider register --namespace Microsoft.ContainerService
az provider register --namespace Microsoft.OperationalInsights
az provider register --namespace Microsoft.ManagedIdentity
```

### Initial Setup
```bash
# Login to Azure
az login

# Set default subscription
az account set --subscription "your-subscription-id"

# Set environment variables
export ORGANIZATION_PREFIX="myorg"
export LOCATION="East US 2"
export SUBSCRIPTION_ID=$(az account show --query id -o tsv)
export TENANT_ID=$(az account show --query tenantId -o tsv)

echo "Organization: $ORGANIZATION_PREFIX"
echo "Location: $LOCATION"
echo "Subscription ID: $SUBSCRIPTION_ID"
echo "Tenant ID: $TENANT_ID"

# Note: Using East US 2 region for better VM availability and quota limits
# If you have existing resources in East US, you may need to recreate them
```

### Authentication Methods for AKS Clusters

This guide provides two authentication options for accessing AKS clusters:

#### Option 1: Admin Access (`--admin` flag)
- **Pros**: Simple, immediate access, bypasses RBAC
- **Cons**: Security risk, not recommended for production
- **Use case**: Development, testing, emergency access
- **Authentication**: Uses cluster admin certificates

#### Option 2: Azure RBAC Authentication (without `--admin`)
- **Pros**: Secure, auditable, follows principle of least privilege
- **Cons**: Requires proper RBAC setup, more complex initial configuration
- **Use case**: Production environments, team access
- **Authentication**: Uses Azure AD tokens via `kubelogin`

**Important Notes:**
- Many organizations disable admin access (`--disable-local-accounts`) for security
- ArgoCD managed identities will use Azure RBAC regardless of your choice
- This guide works with both methods - choose based on your security requirements

### Region Migration (Optional)
If you have existing resources in a different region that need to be cleaned up:

```bash
# List existing resource groups to identify resources to clean up
az group list --query "[?location!='eastus2'].{Name:name, Location:location}" --output table

# Clean up existing resources in wrong region (be careful with this!)
# az group delete --name "old-resource-group-name" --yes --no-wait
```

## Phase 1: Hub Cluster Setup

### Step 1: Create Hub Resource Group and Log Analytics

```bash
# Create hub resource group
HUB_RG="${ORGANIZATION_PREFIX}-hub-rg"
az group create --name $HUB_RG --location "$LOCATION"

# Create Log Analytics workspace for monitoring
WORKSPACE_NAME="${ORGANIZATION_PREFIX}-hub-logs"
az monitor log-analytics workspace create \
  --resource-group $HUB_RG \
  --workspace-name $WORKSPACE_NAME \
  --location "$LOCATION" \
  --sku PerGB2018

# Get workspace resource ID
WORKSPACE_ID=$(az monitor log-analytics workspace show \
  --resource-group $HUB_RG \
  --workspace-name $WORKSPACE_NAME \
  --query id -o tsv)

echo "Workspace ID: $WORKSPACE_ID"
```

### Step 2: Create Hub Cluster Managed Identity

```bash
# Create user-assigned managed identity for hub cluster
HUB_IDENTITY_NAME="${ORGANIZATION_PREFIX}-hub-identity"
az identity create \
  --resource-group $HUB_RG \
  --name $HUB_IDENTITY_NAME

# Get identity details
HUB_IDENTITY_ID=$(az identity show \
  --resource-group $HUB_RG \
  --name $HUB_IDENTITY_NAME \
  --query id -o tsv)

HUB_IDENTITY_CLIENT_ID=$(az identity show \
  --resource-group $HUB_RG \
  --name $HUB_IDENTITY_NAME \
  --query clientId -o tsv)

HUB_IDENTITY_PRINCIPAL_ID=$(az identity show \
  --resource-group $HUB_RG \
  --name $HUB_IDENTITY_NAME \
  --query principalId -o tsv)

echo "Hub Identity ID: $HUB_IDENTITY_ID"
echo "Hub Client ID: $HUB_IDENTITY_CLIENT_ID"
echo "Hub Principal ID: $HUB_IDENTITY_PRINCIPAL_ID"
```

### Step 3: Create Azure AD Groups (Optional)

```bash
# Create Azure AD groups for RBAC
CLUSTER_ADMINS_GROUP="${ORGANIZATION_PREFIX}-aks-cluster-admins"
HUB_OPERATORS_GROUP="${ORGANIZATION_PREFIX}-aks-hub-operators"

# Create cluster admins group
CLUSTER_ADMINS_ID=$(az ad group create \
  --display-name $CLUSTER_ADMINS_GROUP \
  --mail-nickname $CLUSTER_ADMINS_GROUP \
  --description "AKS Cluster Administrators - Full access to all clusters" \
  --query id -o tsv)

# Create hub operators group
HUB_OPERATORS_ID=$(az ad group create \
  --display-name $HUB_OPERATORS_GROUP \
  --mail-nickname $HUB_OPERATORS_GROUP \
  --description "AKS Hub Operators - Full access to hub cluster" \
  --query id -o tsv)

echo "Cluster Admins Group ID: $CLUSTER_ADMINS_ID"
echo "Hub Operators Group ID: $HUB_OPERATORS_ID"

# Add current user to cluster admins group
CURRENT_USER_ID=$(az ad signed-in-user show --query id -o tsv)
az ad group member add --group $CLUSTER_ADMINS_ID --member-id $CURRENT_USER_ID
```

### Step 4: Create Hub AKS Cluster

```bash
# Create hub AKS cluster
HUB_CLUSTER_NAME="${ORGANIZATION_PREFIX}-hub-aks"

az aks create \
  --resource-group $HUB_RG \
  --name $HUB_CLUSTER_NAME \
  --location "$LOCATION" \
  --kubernetes-version "1.31.11" \
  --node-count 2 \
  --node-vm-size Standard_D2ds_v4 \
  --enable-cluster-autoscaler \
  --min-count 1 \
  --max-count 5 \
  --service-cidr 10.0.0.0/16 \
  --dns-service-ip 10.0.0.10 \
  --docker-bridge-address 172.17.0.1/16 \
  --enable-aad \
  --enable-azure-rbac \
  --aad-admin-group-object-ids $CLUSTER_ADMINS_ID \
  --assign-identity $HUB_IDENTITY_ID \
  --enable-addons monitoring \
  --workspace-resource-id $WORKSPACE_ID \
  --tags Environment=hub Purpose=argocd-controller ManagedBy=azure-cli

echo "Hub cluster created: $HUB_CLUSTER_NAME"
```

### Step 5: Add ArgoCD Node Pool

```bash
# Add dedicated node pool for ArgoCD workloads
az aks nodepool add \
  --resource-group $HUB_RG \
  --cluster-name $HUB_CLUSTER_NAME \
  --name argocd \
  --node-count 2 \
  --node-vm-size Standard_D2ds_v4 \
  --enable-cluster-autoscaler \
  --min-count 1 \
  --max-count 4 \
  --node-taints workload-type=argocd:NoSchedule \
  --labels workload-type=argocd

echo "ArgoCD node pool added"
```

### Step 6: Configure kubectl for Hub Cluster

```bash
# Option 1: Get hub cluster credentials with admin access (if admin access is available)
# This uses cluster admin certificates for authentication
az aks get-credentials \
  --resource-group $HUB_RG \
  --name $HUB_CLUSTER_NAME \
  --admin

kubectl config rename-context "${HUB_CLUSTER_NAME}-admin" "hub-cluster"
kubectl config use-context hub-cluster

# Option 2: Get hub cluster credentials with Azure RBAC (if --admin is not available or disabled)
# This uses Azure AD authentication and requires proper RBAC assignments
# az aks get-credentials \
#   --resource-group $HUB_RG \
#   --name $HUB_CLUSTER_NAME

# kubectl config rename-context "$HUB_CLUSTER_NAME" "hub-cluster"
# kubectl config use-context hub-cluster

# If using Azure RBAC (Option 2), ensure you have proper role assignments:
# Get the hub cluster resource ID first
# HUB_CLUSTER_ID=$(az aks show \
#   --resource-group $HUB_RG \
#   --name $HUB_CLUSTER_NAME \
#   --query id -o tsv)

# Assign cluster admin role to current user
# az role assignment create \
#   --assignee $(az ad signed-in-user show --query id -o tsv) \
#   --role "Azure Kubernetes Service Cluster Admin Role" \
#   --scope $HUB_CLUSTER_ID

# Verify cluster access
kubectl cluster-info
kubectl get nodes
```

## Phase 2: Install ArgoCD on Hub Cluster

### Step 7: Install ArgoCD using Helm

```bash
# Add ArgoCD Helm repository
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# Create ArgoCD namespace
kubectl create namespace argocd

# Create values file for ArgoCD configuration
cat > argocd-values.yaml << 'EOF'
global:
  domain: argocd.local  # Update with your domain

configs:
  params:
    server.insecure: false
    application.instanceLabelKey: argocd.argoproj.io/instance
    server.repo.server.timeout.seconds: "300"
    
  rbac:
    policy.default: role:readonly
    policy.csv: |
      g, cluster-admins, role:admin
      g, hub-operators, role:admin
      
      p, role:developer, applications, *, */*, allow
      p, role:developer, logs, get, */*, allow
      p, role:developer, exec, create, */*, allow

# Application Controller Configuration
controller:
  replicas: 2
  resources:
    requests:
      cpu: 250m
      memory: 1Gi
    limits:
      cpu: 500m
      memory: 2Gi
  nodeSelector:
    workload-type: argocd
  tolerations:
    - key: workload-type
      operator: Equal
      value: argocd
      effect: NoSchedule
  metrics:
    enabled: true

# Server Configuration  
server:
  replicas: 2
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 200m
      memory: 512Mi
  nodeSelector:
    workload-type: argocd
  tolerations:
    - key: workload-type
      operator: Equal
      value: argocd
      effect: NoSchedule
  service:
    type: LoadBalancer
  metrics:
    enabled: true

# Repository Server Configuration
repoServer:
  replicas: 2
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 200m
      memory: 512Mi
  nodeSelector:
    workload-type: argocd
  tolerations:
    - key: workload-type
      operator: Equal
      value: argocd
      effect: NoSchedule
  metrics:
    enabled: true

# ApplicationSet Controller
applicationSet:
  enabled: true
  nodeSelector:
    workload-type: argocd
  tolerations:
    - key: workload-type
      operator: Equal
      value: argocd
      effect: NoSchedule

# Notifications Controller
notifications:
  enabled: true
  nodeSelector:
    workload-type: argocd
  tolerations:
    - key: workload-type
      operator: Equal
      value: argocd
      effect: NoSchedule
EOF

# Install ArgoCD
helm install argocd argo/argo-cd \
  --namespace argocd \
  --values argocd-values.yaml \
  --version 5.51.6

# Wait for ArgoCD to be ready
kubectl wait --for=condition=available --timeout=600s deployment/argocd-server -n argocd

echo "ArgoCD installed successfully"
```

### Step 8: Access ArgoCD

```bash
# Get ArgoCD admin password
ARGOCD_PASSWORD=$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | base64 -d)
echo "ArgoCD Admin Password: $ARGOCD_PASSWORD"

# Port forward to access ArgoCD (run in separate terminal)
kubectl port-forward svc/argocd-server -n argocd 8080:443 &

echo "ArgoCD UI available at: https://localhost:8080"
echo "Username: admin"
echo "Password: $ARGOCD_PASSWORD"

# Optional: Get LoadBalancer IP (if configured)
ARGOCD_IP=$(kubectl get svc argocd-server -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
if [ ! -z "$ARGOCD_IP" ]; then
  echo "ArgoCD LoadBalancer IP: $ARGOCD_IP"
fi
```

## Phase 3: Create Spoke Clusters

### Step 9: Create Development Spoke Cluster

```bash
# Create development resource group
DEV_RG="${ORGANIZATION_PREFIX}-dev-rg"
az group create --name $DEV_RG --location "$LOCATION"

# Create development cluster managed identity
DEV_IDENTITY_NAME="${ORGANIZATION_PREFIX}-dev-identity"
az identity create \
  --resource-group $DEV_RG \
  --name $DEV_IDENTITY_NAME

DEV_IDENTITY_ID=$(az identity show \
  --resource-group $DEV_RG \
  --name $DEV_IDENTITY_NAME \
  --query id -o tsv)

DEV_IDENTITY_CLIENT_ID=$(az identity show \
  --resource-group $DEV_RG \
  --name $DEV_IDENTITY_NAME \
  --query clientId -o tsv)

# Create development AKS cluster
DEV_CLUSTER_NAME="${ORGANIZATION_PREFIX}-dev-aks"

az aks create \
  --resource-group $DEV_RG \
  --name $DEV_CLUSTER_NAME \
  --location "$LOCATION" \
  --kubernetes-version "1.31.11" \
  --node-count 2 \
  --node-vm-size Standard_D2ds_v4 \
  --enable-cluster-autoscaler \
  --min-count 1 \
  --max-count 3 \
  --service-cidr 10.1.0.0/16 \
  --dns-service-ip 10.1.0.10 \
  --docker-bridge-address 172.18.0.1/16 \
  --enable-aad \
  --enable-azure-rbac \
  --aad-admin-group-object-ids $CLUSTER_ADMINS_ID \
  --assign-identity $DEV_IDENTITY_ID \
  --enable-addons monitoring \
  --workspace-resource-id $WORKSPACE_ID \
  --tags Environment=dev Purpose=workload-cluster ManagedBy=azure-cli

echo "Development cluster created: $DEV_CLUSTER_NAME"

# Get cluster resource ID for RBAC assignments
DEV_CLUSTER_ID=$(az aks show \
  --resource-group $DEV_RG \
  --name $DEV_CLUSTER_NAME \
  --query id -o tsv)

echo "Dev Cluster ID: $DEV_CLUSTER_ID"
```

### Step 10: Create Production Spoke Cluster (Optional)

```bash
# Create production resource group
PROD_RG="${ORGANIZATION_PREFIX}-prod-rg"
az group create --name $PROD_RG --location "$LOCATION"

# Create production cluster managed identity
PROD_IDENTITY_NAME="${ORGANIZATION_PREFIX}-prod-identity"
az identity create \
  --resource-group $PROD_RG \
  --name $PROD_IDENTITY_NAME

PROD_IDENTITY_ID=$(az identity show \
  --resource-group $PROD_RG \
  --name $PROD_IDENTITY_NAME \
  --query id -o tsv)

# Create production AKS cluster with higher availability
PROD_CLUSTER_NAME="${ORGANIZATION_PREFIX}-prod-aks"

az aks create \
  --resource-group $PROD_RG \
  --name $PROD_CLUSTER_NAME \
  --location "$LOCATION" \
  --kubernetes-version "1.31.11" \
  --node-count 3 \
  --node-vm-size Standard_D4ds_v4 \
  --enable-cluster-autoscaler \
  --min-count 2 \
  --max-count 10 \
  --zones 1 2 3 \
  --network-plugin azure \
  --network-policy azure \
  --service-cidr 10.2.0.0/16 \
  --dns-service-ip 10.2.0.10 \
  --docker-bridge-address 172.19.0.1/16 \
  --enable-aad \
  --enable-azure-rbac \
  --aad-admin-group-object-ids $CLUSTER_ADMINS_ID \
  --assign-identity $PROD_IDENTITY_ID \
  --enable-addons monitoring \
  --workspace-resource-id $WORKSPACE_ID \
  --tags Environment=prod Purpose=workload-cluster ManagedBy=azure-cli

echo "Production cluster created: $PROD_CLUSTER_NAME"

# Get cluster resource ID
PROD_CLUSTER_ID=$(az aks show \
  --resource-group $PROD_RG \
  --name $PROD_CLUSTER_NAME \
  --query id -o tsv)

echo "Prod Cluster ID: $PROD_CLUSTER_ID"
```

## Phase 4: Configure Hub-to-Spoke RBAC

### Step 11: Grant Hub Identity Access to Spoke Clusters

```bash
# Grant hub identity access to development cluster
az role assignment create \
  --assignee $HUB_IDENTITY_PRINCIPAL_ID \
  --role "Azure Kubernetes Service Cluster User Role" \
  --scope $DEV_CLUSTER_ID

az role assignment create \
  --assignee $HUB_IDENTITY_PRINCIPAL_ID \
  --role "Reader" \
  --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$DEV_RG"

echo "Hub identity granted access to dev cluster"

# Grant hub identity access to production cluster (if created)
if [ ! -z "$PROD_CLUSTER_ID" ]; then
  az role assignment create \
    --assignee $HUB_IDENTITY_PRINCIPAL_ID \
    --role "Azure Kubernetes Service Cluster User Role" \
    --scope $PROD_CLUSTER_ID

  az role assignment create \
    --assignee $HUB_IDENTITY_PRINCIPAL_ID \
    --role "Reader" \
    --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$PROD_RG"

  echo "Hub identity granted access to prod cluster"
fi
```

### Step 12: Create Custom Role for ArgoCD Hub Operations

```bash
# Create custom role definition for ArgoCD operations
cat > argocd-hub-role.json << EOF
{
  "Name": "${ORGANIZATION_PREFIX}-ArgoCD-Hub-Operator",
  "Description": "Custom role for ArgoCD hub cluster operations across spoke clusters",
  "Actions": [
    "Microsoft.ContainerService/managedClusters/read",
    "Microsoft.ContainerService/managedClusters/listClusterUserCredential/action",
    "Microsoft.ContainerService/managedClusters/listClusterMonitoringUserCredential/action",
    "Microsoft.Resources/subscriptions/resourceGroups/read",
    "Microsoft.ManagedIdentity/userAssignedIdentities/read",
    "Microsoft.Insights/components/read",
    "Microsoft.OperationalInsights/workspaces/read",
    "Microsoft.Network/virtualNetworks/read",
    "Microsoft.Network/virtualNetworks/subnets/read"
  ],
  "NotActions": [],
  "DataActions": [],
  "NotDataActions": [],
  "AssignableScopes": [
    "/subscriptions/$SUBSCRIPTION_ID"
  ]
}
EOF

# Create the custom role
az role definition create --role-definition argocd-hub-role.json

# Assign custom role to hub identity
az role assignment create \
  --assignee $HUB_IDENTITY_PRINCIPAL_ID \
  --role "${ORGANIZATION_PREFIX}-ArgoCD-Hub-Operator" \
  --scope "/subscriptions/$SUBSCRIPTION_ID"

echo "Custom ArgoCD role created and assigned"
```

## Phase 5: Configure Spoke Clusters for ArgoCD Management

### Step 13: Setup Development Cluster for ArgoCD

```bash
# Option 1: Get dev cluster credentials with admin access (if admin access is available)
# This uses cluster admin certificates for authentication
az aks get-credentials \
  --resource-group $DEV_RG \
  --name $DEV_CLUSTER_NAME \
  --admin

kubectl config rename-context "${DEV_CLUSTER_NAME}-admin" "dev-cluster"
kubectl config use-context dev-cluster

# Option 2: Get dev cluster credentials with Azure RBAC (if --admin is not available or disabled)
# This uses Azure AD authentication and requires proper RBAC assignments
# az aks get-credentials \
#   --resource-group $DEV_RG \
#   --name $DEV_CLUSTER_NAME

# kubectl config rename-context "$DEV_CLUSTER_NAME" "dev-cluster"
# kubectl config use-context dev-cluster

# If using Azure RBAC (Option 2), ensure you have proper role assignments:
 az role assignment create \
   --assignee $(az ad signed-in-user show --query id -o tsv) \
   --role "Azure Kubernetes Service Cluster Admin Role" \
   --scope $DEV_CLUSTER_ID

# Test cluster access
kubectl cluster-info
kubectl get nodes

# IMPORTANT: The following commands run on the SPOKE CLUSTER (development)
# We're creating resources that will allow the ArgoCD hub cluster to manage this spoke cluster

# Create namespace for ArgoCD managed resources
kubectl create namespace argocd-managed
kubectl label namespace argocd-managed app.kubernetes.io/managed-by=argocd

# Create service account for ArgoCD management (this allows hub cluster's ArgoCD to manage this spoke cluster)
cat > dev-argocd-rbac.yaml << EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-manager
  namespace: argocd-managed
  annotations:
    azure.workload.identity/client-id: "$HUB_IDENTITY_CLIENT_ID"
automountServiceAccountToken: true
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: argocd-manager
rules:
- apiGroups: [""]
  resources: ["configmaps", "secrets", "services", "serviceaccounts"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["apps"]
  resources: ["deployments", "daemonsets", "replicasets", "statefulsets"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["extensions", "networking.k8s.io"]
  resources: ["ingresses", "networkpolicies"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["policy"]
  resources: ["poddisruptionbudgets"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["autoscaling"]
  resources: ["horizontalpodautoscalers"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["batch"]
  resources: ["jobs", "cronjobs"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: [""]
  resources: ["namespaces"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["apiextensions.k8s.io"]
  resources: ["customresourcedefinitions"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argocd-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: argocd-manager
subjects:
- kind: ServiceAccount
  name: argocd-manager
  namespace: argocd-managed
- kind: User
  name: "$HUB_IDENTITY_CLIENT_ID"
  apiGroup: rbac.authorization.k8s.io
EOF

kubectl apply -f dev-argocd-rbac.yaml

echo "Development cluster configured for ArgoCD management"
```

### Step 14: Add Development Cluster to ArgoCD

```bash
# Switch back to hub cluster
kubectl config use-context hub-cluster

# Get development cluster endpoint and CA certificate
DEV_CLUSTER_ENDPOINT=$(az aks show \
  --resource-group $DEV_RG \
  --name $DEV_CLUSTER_NAME \
  --query fqdn -o tsv)

DEV_CLUSTER_CA=$(az aks show \
  --resource-group $DEV_RG \
  --name $DEV_CLUSTER_NAME \
  --query kubeConfig -o tsv | base64 -d | yq eval '.clusters[0].cluster.certificate-authority-data' -)

# Create cluster secret for ArgoCD
cat > dev-cluster-secret.yaml << EOF
apiVersion: v1
kind: Secret
metadata:
  name: dev-cluster-secret
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: "dev-cluster"
  server: "https://$DEV_CLUSTER_ENDPOINT"
  config: |
    {
      "execProviderConfig": {
        "command": "kubelogin",
        "args": [
          "get-token",
          "--login", "azurecli", 
          "--server-id", "6dae42f8-4368-4678-94ff-3960e28e3630"
        ],
        "apiVersion": "client.authentication.k8s.io/v1beta1"
      },
      "tlsClientConfig": {
        "insecure": false,
        "caData": "$DEV_CLUSTER_CA"
      }
    }
EOF

kubectl apply -f dev-cluster-secret.yaml

echo "Development cluster added to ArgoCD"
```

## Phase 6: Test Application Deployment

### Step 15: Deploy Test Application to Development Cluster

```bash
# Create a simple test application
cat > test-app.yaml << EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: nginx-test
  namespace: argocd
  labels:
    environment: dev
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
        - name: service.type
          value: "LoadBalancer"
  destination:
    server: "https://$DEV_CLUSTER_ENDPOINT"
    namespace: argocd-managed
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
EOF

kubectl apply -f test-app.yaml

echo "Test application deployed to development cluster"
```

### Step 16: Verify Application Deployment

```bash
# Wait for application sync
echo "Waiting for application to sync..."
sleep 30

# Check application status in ArgoCD
kubectl get applications -n argocd
kubectl get application nginx-test -n argocd -o yaml

# Check resources in development cluster
kubectl config use-context dev-cluster
kubectl get pods -n argocd-managed
kubectl get services -n argocd-managed

# Get service external IP (if LoadBalancer)
DEV_SERVICE_IP=$(kubectl get svc nginx-test -n argocd-managed -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
if [ ! -z "$DEV_SERVICE_IP" ]; then
  echo "Test application available at: http://$DEV_SERVICE_IP"
fi
```

## Phase 7: Monitoring and Validation

### Step 17: Validate RBAC Configuration

```bash
# Switch to hub cluster context
kubectl config use-context hub-cluster

# Check ArgoCD can list clusters
kubectl logs deployment/argocd-application-controller -n argocd | grep -i cluster

# Verify Azure role assignments
echo "Checking Azure role assignments for hub identity:"
az role assignment list --assignee $HUB_IDENTITY_PRINCIPAL_ID --all --output table

# Test hub identity permissions
echo "Testing hub identity cluster access:"
az aks get-credentials --resource-group $DEV_RG --name $DEV_CLUSTER_NAME --admin
kubectl auth can-i "*" "*" --as="$HUB_IDENTITY_CLIENT_ID"
```

### Step 18: Setup Monitoring and Logging

```bash
# Check Log Analytics data ingestion
echo "Checking Log Analytics workspace data:"
az monitor log-analytics query \
  --workspace $WORKSPACE_ID \
  --analytics-query "Heartbeat | where Computer contains 'aks' | top 10 by TimeGenerated desc"

# Verify container logs are being collected
az monitor log-analytics query \
  --workspace $WORKSPACE_ID \
  --analytics-query "ContainerLog | where Name contains 'argocd' | top 5 by TimeGenerated desc"

# Check cluster metrics
kubectl top nodes --context=hub-cluster
kubectl top nodes --context=dev-cluster
```

## Cleanup (Optional)

### Step 19: Clean Up Resources

```bash
# Delete test application
kubectl delete application nginx-test -n argocd

# Delete spoke clusters
az aks delete --resource-group $DEV_RG --name $DEV_CLUSTER_NAME --yes --no-wait
if [ ! -z "$PROD_RG" ]; then
  az aks delete --resource-group $PROD_RG --name $PROD_CLUSTER_NAME --yes --no-wait
fi

# Delete hub cluster
az aks delete --resource-group $HUB_RG --name $HUB_CLUSTER_NAME --yes --no-wait

# Delete resource groups (after clusters are deleted)
# az group delete --name $DEV_RG --yes --no-wait
# az group delete --name $PROD_RG --yes --no-wait  
# az group delete --name $HUB_RG --yes --no-wait

echo "Cleanup initiated"
```

## Automating Spoke Cluster Management from Hub

### Option 1: ArgoCD ApplicationSet for Spoke Cluster Onboarding

Create an ApplicationSet that automatically configures new spoke clusters:

```bash
# Switch to hub cluster context
kubectl config use-context hub-cluster

# Create ApplicationSet for spoke cluster management
cat > spoke-cluster-onboarding.yaml << 'EOF'
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: spoke-cluster-onboarding
  namespace: argocd
spec:
  generators:
  - clusters:
      selector:
        matchLabels:
          environment: spoke
  template:
    metadata:
      name: '{{name}}-onboarding'
      labels:
        environment: '{{metadata.labels.environment}}'
        cluster-type: spoke
    spec:
      project: default
      source:
        repoURL: https://github.com/srinman/aks-cicd
        path: argo/spoke-bootstrap/overlays/{{metadata.labels.cluster-environment}}
        targetRevision: main
      destination:
        server: '{{server}}'
        namespace: argocd-managed
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ServerSideApply=true
EOF

kubectl apply -f spoke-cluster-onboarding.yaml
```

### Complete Production-Ready Solution: ApplicationSet + Kustomize + Automation Scripts

Based on real-world implementation and troubleshooting, here's the complete working automation solution that addresses all the issues discovered:

#### Step 1: Create Spoke Bootstrap Directory Structure

```bash
# Create the complete spoke-bootstrap directory structure
mkdir -p argo/spoke-bootstrap/{base,overlays/{dev,staging,prod}}

# Create base configurations
cat > argo/spoke-bootstrap/base/namespace.yaml << 'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: argocd-managed
  labels:
    app.kubernetes.io/managed-by: argocd
EOF

cat > argo/spoke-bootstrap/base/serviceaccount.yaml << 'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-manager
  namespace: argocd-managed
  labels:
    app.kubernetes.io/name: spoke-bootstrap
automountServiceAccountToken: true
EOF

cat > argo/spoke-bootstrap/base/rbac.yaml << 'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: argocd-manager
  labels:
    app.kubernetes.io/name: spoke-bootstrap
rules:
- apiGroups: ["*"]
  resources: ["*"]
  verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argocd-manager
  labels:
    app.kubernetes.io/name: spoke-bootstrap
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: argocd-manager
subjects:
- kind: ServiceAccount
  name: argocd-manager
  namespace: argocd-managed
EOF

cat > argo/spoke-bootstrap/base/kustomization.yaml << 'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- namespace.yaml
- serviceaccount.yaml
- rbac.yaml

commonLabels:
  app.kubernetes.io/name: spoke-bootstrap
  cluster-type: spoke

images: []
EOF

# Create environment-specific overlays with hardcoded hub identity
for env in dev staging prod; do
  cat > argo/spoke-bootstrap/overlays/$env/hub-identity-configmap.yaml << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: hub-identity-config
  namespace: argocd-managed
  labels:
    environment: $env
data:
  clientId: "$HUB_IDENTITY_CLIENT_ID"
EOF

  cat > argo/spoke-bootstrap/overlays/$env/kustomization.yaml << EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- ../../base
- hub-identity-configmap.yaml

commonLabels:
  environment: $env

patchesStrategicMerge:
- |
  apiVersion: v1
  kind: ServiceAccount
  metadata:
    name: argocd-manager
    namespace: argocd-managed
    annotations:
      azure.workload.identity/client-id: "$HUB_IDENTITY_CLIENT_ID"

- |
  apiVersion: rbac.authorization.k8s.io/v1
  kind: ClusterRoleBinding
  metadata:
    name: argocd-manager
  subjects:
  - kind: ServiceAccount
    name: argocd-manager
    namespace: argocd-managed
  - kind: User
    name: "$HUB_IDENTITY_CLIENT_ID"
    apiGroup: rbac.authorization.k8s.io
EOF
done
```

#### Step 2: Create ApplicationSet Deployment Script

```bash
cat > argo/setup-applicationset.sh << 'EOF'
#!/bin/bash
set -e

# Get hub identity client ID from Azure
HUB_IDENTITY_CLIENT_ID=${HUB_IDENTITY_CLIENT_ID:-$(az identity show --resource-group myorg-hub-rg --name myorg-hub-identity --query clientId -o tsv 2>/dev/null)}

if [ -z "$HUB_IDENTITY_CLIENT_ID" ]; then
    echo "Error: Hub Identity Client ID not found. Set HUB_IDENTITY_CLIENT_ID environment variable or ensure hub identity exists."
    exit 1
fi

echo "Using Hub Identity Client ID: $HUB_IDENTITY_CLIENT_ID"

# Create ApplicationSet with proper label matching and path template
cat > spoke-cluster-applicationset.yaml << EOF
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: spoke-cluster-bootstrap
  namespace: argocd
  labels:
    app.kubernetes.io/name: spoke-cluster-bootstrap
spec:
  generators:
  - clusters:
      selector:
        matchLabels:
          environment: spoke
  template:
    metadata:
      name: '{{name}}-bootstrap'
      labels:
        cluster-type: spoke
        environment: spoke
        managed-by: applicationset
    spec:
      project: default
      source:
        repoURL: https://github.com/srinman/aks-cicd
        path: argo/spoke-bootstrap/overlays/{{metadata.labels.cluster-environment}}
        targetRevision: main
      destination:
        server: '{{server}}'
        namespace: argocd-managed
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ServerSideApply=true
          - RespectIgnoreDifferences=true
      ignoreDifferences:
      - group: "*"
        kind: "ServiceAccount"
        jsonPointers:
        - /secrets
EOF

kubectl apply -f spoke-cluster-applicationset.yaml
echo "✅ ApplicationSet 'spoke-cluster-bootstrap' created successfully"

# Cleanup temp file
rm -f spoke-cluster-applicationset.yaml
EOF

chmod +x argo/setup-applicationset.sh
```

#### Step 3: Create Robust Spoke Cluster Addition Script

```bash
cat > argo/add-spoke-cluster.sh << 'EOF'
#!/bin/bash
set -e

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    -n|--cluster-name)
      CLUSTER_NAME="$2"
      shift 2
      ;;
    -g|--resource-group)
      RESOURCE_GROUP="$2"
      shift 2
      ;;
    -e|--environment)
      ENVIRONMENT="$2"
      shift 2
      ;;
    -i|--hub-identity)
      HUB_IDENTITY_CLIENT_ID="$2"
      shift 2
      ;;
    *)
      echo "Usage: $0 -n <cluster-name> -g <resource-group> -e <environment> -i <hub-identity-client-id>"
      echo "Example: $0 -n myorg-dev-aks -g myorg-dev-rg -e dev -i $HUB_IDENTITY_CLIENT_ID"
      exit 1
      ;;
  esac
done

# Validate required parameters
if [ -z "$CLUSTER_NAME" ] || [ -z "$RESOURCE_GROUP" ] || [ -z "$ENVIRONMENT" ]; then
    echo "Error: Missing required parameters"
    echo "Usage: $0 -n <cluster-name> -g <resource-group> -e <environment> [-i <hub-identity-client-id>]"
    exit 1
fi

# Get hub identity from Azure if not provided
if [ -z "$HUB_IDENTITY_CLIENT_ID" ]; then
    HUB_IDENTITY_CLIENT_ID=$(az identity show --resource-group myorg-hub-rg --name myorg-hub-identity --query clientId -o tsv 2>/dev/null)
fi

if [ -z "$HUB_IDENTITY_CLIENT_ID" ]; then
    echo "Error: Hub Identity Client ID not provided via parameter or environment variable"
    echo "Set HUB_IDENTITY_CLIENT_ID environment variable or use -i parameter"
    echo ""
    echo "Usage: $0 -n <cluster-name> -g <resource-group> -e <environment> -i <hub-identity-client-id>"
    exit 1
fi

echo "Adding spoke cluster to ArgoCD:"
echo "  Cluster Name: $CLUSTER_NAME"
echo "  Resource Group: $RESOURCE_GROUP"  
echo "  Environment: $ENVIRONMENT"
echo "  Hub Identity: $HUB_IDENTITY_CLIENT_ID"
echo ""

# Warn if not on hub cluster context
CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "")
if [[ "$CURRENT_CONTEXT" != *"hub"* ]]; then
    echo "Warning: Current context '$CURRENT_CONTEXT' doesn't appear to be the hub cluster"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

echo "Getting cluster details from Azure..."

# Store original kubeconfig context to restore later
ORIGINAL_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "")

# Get admin kubeconfig for certificate-based authentication (required for ArgoCD)
az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" --admin --overwrite-existing

# Extract cluster configuration details
CLUSTER_SERVER=$(kubectl config view -o jsonpath="{.clusters[?(@.name=='$CLUSTER_NAME')].cluster.server}")
CLUSTER_CA=$(kubectl config view --raw -o jsonpath="{.clusters[?(@.name=='$CLUSTER_NAME')].cluster.certificate-authority-data}")

if [ -z "$CLUSTER_SERVER" ] || [ "$CLUSTER_SERVER" == "null" ]; then
    echo "Error: Could not get cluster server from admin credentials."
    exit 1
fi

if [ -z "$CLUSTER_CA" ] || [ "$CLUSTER_CA" == "null" ]; then
    echo "Error: Could not get cluster CA certificate from admin credentials."
    exit 1
fi

echo "Cluster Server: $CLUSTER_SERVER"

# Extract client certificate and key for ArgoCD authentication  
CLIENT_CERT=$(kubectl config view --raw -o jsonpath="{.users[?(@.name=='clusterAdmin_${RESOURCE_GROUP}_${CLUSTER_NAME}')].user.client-certificate-data}")
CLIENT_KEY=$(kubectl config view --raw -o jsonpath="{.users[?(@.name=='clusterAdmin_${RESOURCE_GROUP}_${CLUSTER_NAME}')].user.client-key-data}")

if [ -z "$CLIENT_CERT" ] || [ "$CLIENT_CERT" == "null" ]; then
    echo "Error: Could not get client certificate from admin credentials."
    exit 1
fi

if [ -z "$CLIENT_KEY" ] || [ "$CLIENT_KEY" == "null" ]; then
    echo "Error: Could not get client key from admin credentials."
    exit 1
fi

# Create ArgoCD cluster secret
SECRET_NAME="${CLUSTER_NAME}-secret"
echo "Creating ArgoCD cluster secret: $SECRET_NAME"

cat > "${SECRET_NAME}.yaml" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: $SECRET_NAME
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
    environment: spoke
    cluster-environment: $ENVIRONMENT
    cluster-name: $CLUSTER_NAME
  annotations:
    managed-by: spoke-cluster-automation
type: Opaque
stringData:
  name: "$CLUSTER_NAME"
  server: "$CLUSTER_SERVER"
  config: |
    {
      "tlsClientConfig": {
        "insecure": false,
        "caData": "$CLUSTER_CA",
        "certData": "$CLIENT_CERT",
        "keyData": "$CLIENT_KEY"
      }
    }
EOF

# Switch back to hub cluster to create the ArgoCD secret
kubectl config use-context hub-cluster >/dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "Error: Could not switch to hub-cluster context. Make sure hub cluster is configured."
    exit 1
fi

# Apply the cluster secret
kubectl apply -f "${SECRET_NAME}.yaml"

echo "✅ Cluster secret created successfully!"

# Verify the secret and labels
echo ""
echo "Verifying cluster secret labels..."
kubectl get secret "$SECRET_NAME" -n argocd --show-labels

# Restore original kubeconfig context if it existed
if [ -n "$ORIGINAL_CONTEXT" ]; then
    kubectl config use-context "$ORIGINAL_CONTEXT" >/dev/null 2>&1
fi

# Cleanup temporary files
rm -f "${SECRET_NAME}.yaml"

echo ""
echo "✅ Spoke cluster '$CLUSTER_NAME' added to ArgoCD successfully!"
echo ""
echo "The ApplicationSet will automatically detect this cluster and deploy bootstrap configuration."
echo "You can monitor the progress with:"
echo "  kubectl get applications -n argocd -l cluster-type=spoke"
echo "  kubectl get applicationset spoke-cluster-bootstrap -n argocd -o wide"
EOF

chmod +x argo/add-spoke-cluster.sh
```

#### Step 4: Complete Deployment and Verification

```bash
# 1. Commit all files to Git (CRITICAL - ArgoCD needs files in repository)
git add argo/spoke-bootstrap/ argo/setup-applicationset.sh argo/add-spoke-cluster.sh
git commit -m "Add production-ready spoke cluster automation

- Complete Kustomize-based bootstrap configuration with base and overlays
- ApplicationSet with corrected label selectors and path templates
- Robust cluster addition script with certificate-based authentication
- Proper error handling and context management
- Resolves all identified issues from initial implementation"
git push

# 2. Switch to hub cluster and deploy ApplicationSet
kubectl config use-context hub-cluster
./argo/setup-applicationset.sh

# 3. Add spoke cluster (replace values with your actual cluster details)
export HUB_IDENTITY_CLIENT_ID=$(az identity show --resource-group myorg-hub-rg --name myorg-hub-identity --query clientId -o tsv)
./argo/add-spoke-cluster.sh -n myorg-dev-aks -g myorg-dev-rg -e dev -i $HUB_IDENTITY_CLIENT_ID

# 4. Verify ApplicationSet created the Application
kubectl get applications -n argocd -l cluster-type=spoke
kubectl get applicationset spoke-cluster-bootstrap -n argocd

# 5. Wait for sync and verify resources in spoke cluster
sleep 30
kubectl get application myorg-dev-aks-bootstrap -n argocd  # Should show "Synced" and "Healthy"

# 6. Check deployed resources in spoke cluster
kubectl config use-context myorg-dev-aks-admin
kubectl get namespace argocd-managed
kubectl get serviceaccount,clusterrolebinding -n argocd-managed
kubectl describe serviceaccount argocd-manager -n argocd-managed  # Check for hub identity annotation
kubectl get configmap hub-identity-config -n argocd-managed -o yaml  # Verify hub client ID
```

### Verification Checklist

After running the complete solution, verify these items:

- ✅ **ApplicationSet Status**: `kubectl get applicationset spoke-cluster-bootstrap -n argocd` shows healthy status
- ✅ **Application Created**: ApplicationSet automatically created Application for spoke cluster
- ✅ **Application Synced**: Application status shows "Synced" and "Healthy"
- ✅ **Spoke Resources**: All resources deployed to spoke cluster (`namespace`, `serviceaccount`, `rbac`, `configmap`)
- ✅ **Hub Identity Integration**: ServiceAccount has correct workload identity annotation
- ✅ **ConfigMap Data**: Hub identity client ID correctly populated in spoke cluster

### Option 2: Kubernetes Job from Hub Cluster (Alternative Approach)

Create a Kubernetes Job that runs from the hub cluster to configure spoke clusters:

```bash
# Create spoke cluster automation job
cat > spoke-automation-job.yaml << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: spoke-setup-script
  namespace: argocd
data:
  setup-spoke.sh: |
    #!/bin/bash
    set -e
    
    SPOKE_CLUSTER_NAME=\${1}
    SPOKE_RG=\${2}
    HUB_IDENTITY_CLIENT_ID=\${3}
    
    echo "Setting up spoke cluster: \$SPOKE_CLUSTER_NAME in \$SPOKE_RG"
    
    # Get spoke cluster credentials using hub identity
    az aks get-credentials --resource-group \$SPOKE_RG --name \$SPOKE_CLUSTER_NAME
    
    # Create namespace and labels
    kubectl create namespace argocd-managed --dry-run=client -o yaml | kubectl apply -f -
    kubectl label namespace argocd-managed app.kubernetes.io/managed-by=argocd --overwrite
    
    # Apply RBAC configuration
    cat <<RBAC | kubectl apply -f -
    apiVersion: v1
    kind: ServiceAccount
    metadata:
      name: argocd-manager
      namespace: argocd-managed
      annotations:
        azure.workload.identity/client-id: "\$HUB_IDENTITY_CLIENT_ID"
    automountServiceAccountToken: true
    ---
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRole
    metadata:
      name: argocd-manager
    rules:
    - apiGroups: ["*"]
      resources: ["*"]
      verbs: ["*"]
    ---
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRoleBinding
    metadata:
      name: argocd-manager
    roleRef:
      apiGroup: rbac.authorization.k8s.io
      kind: ClusterRole
      name: argocd-manager
    subjects:
    - kind: ServiceAccount
      name: argocd-manager
      namespace: argocd-managed
    - kind: User
      name: "\$HUB_IDENTITY_CLIENT_ID"
      apiGroup: rbac.authorization.k8s.io
    RBAC
    
    echo "Spoke cluster \$SPOKE_CLUSTER_NAME configured successfully"
---
apiVersion: batch/v1
kind: Job
metadata:
  name: configure-spoke-cluster
  namespace: argocd
spec:
  template:
    metadata:
      labels:
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: argocd-server
      containers:
      - name: spoke-configurator
        image: mcr.microsoft.com/azure-cli:latest
        env:
        - name: SPOKE_CLUSTER_NAME
          value: "${DEV_CLUSTER_NAME}"
        - name: SPOKE_RG
          value: "${DEV_RG}"
        - name: HUB_IDENTITY_CLIENT_ID
          value: "${HUB_IDENTITY_CLIENT_ID}"
        command: ["/bin/bash"]
        args: ["/scripts/setup-spoke.sh", "\$(SPOKE_CLUSTER_NAME)", "\$(SPOKE_RG)", "\$(HUB_IDENTITY_CLIENT_ID)"]
        volumeMounts:
        - name: script-volume
          mountPath: /scripts
      volumes:
      - name: script-volume
        configMap:
          name: spoke-setup-script
          defaultMode: 0755
      restartPolicy: OnFailure
EOF

kubectl apply -f spoke-automation-job.yaml
```

### Option 3: ArgoCD Custom Resource Definitions (CRDs)

Create custom resources to declaratively manage spoke clusters:

```bash
# Create CRD for spoke cluster management
cat > spoke-cluster-crd.yaml << 'EOF'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: spokeclusters.argocd.io
spec:
  group: argocd.io
  versions:
  - name: v1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            properties:
              clusterName:
                type: string
              resourceGroup:
                type: string
              environment:
                type: string
              hubIdentityClientId:
                type: string
              server:
                type: string
            required:
            - clusterName
            - resourceGroup
            - environment
            - hubIdentityClientId
            - server
          status:
            type: object
            properties:
              phase:
                type: string
              message:
                type: string
  scope: Namespaced
  names:
    plural: spokeclusters
    singular: spokecluster
    kind: SpokeCluster
---
apiVersion: argocd.io/v1
kind: SpokeCluster
metadata:
  name: dev-cluster-config
  namespace: argocd
spec:
  clusterName: "${DEV_CLUSTER_NAME}"
  resourceGroup: "${DEV_RG}"
  environment: "dev"
  hubIdentityClientId: "${HUB_IDENTITY_CLIENT_ID}"
  server: "https://${DEV_CLUSTER_ENDPOINT}"
EOF

kubectl apply -f spoke-cluster-crd.yaml
```

### Option 4: Helm Chart for Spoke Cluster Bootstrap

Create a Helm chart that can be deployed to configure spoke clusters:

```bash
# Create Helm chart structure
mkdir -p spoke-bootstrap-chart/{templates,values}

# Create chart metadata
cat > spoke-bootstrap-chart/Chart.yaml << 'EOF'
apiVersion: v2
name: spoke-bootstrap
description: Bootstrap chart for ArgoCD spoke cluster configuration
version: 0.1.0
appVersion: "1.0"
EOF

# Create values file
cat > spoke-bootstrap-chart/values.yaml << 'EOF'
hubIdentity:
  clientId: ""
  
cluster:
  name: ""
  environment: "dev"
  
namespace:
  name: "argocd-managed"
  
serviceAccount:
  name: "argocd-manager"

rbac:
  create: true
EOF

# Create templates
cat > spoke-bootstrap-chart/templates/namespace.yaml << 'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: {{ .Values.namespace.name }}
  labels:
    app.kubernetes.io/managed-by: argocd
    environment: {{ .Values.cluster.environment }}
EOF

cat > spoke-bootstrap-chart/templates/serviceaccount.yaml << 'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ .Values.serviceAccount.name }}
  namespace: {{ .Values.namespace.name }}
  annotations:
    azure.workload.identity/client-id: "{{ .Values.hubIdentity.clientId }}"
automountServiceAccountToken: true
EOF

cat > spoke-bootstrap-chart/templates/rbac.yaml << 'EOF'
{{- if .Values.rbac.create }}
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: {{ .Values.serviceAccount.name }}
rules:
- apiGroups: ["*"]
  resources: ["*"]
  verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: {{ .Values.serviceAccount.name }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: {{ .Values.serviceAccount.name }}
subjects:
- kind: ServiceAccount
  name: {{ .Values.serviceAccount.name }}
  namespace: {{ .Values.namespace.name }}
- kind: User
  name: "{{ .Values.hubIdentity.clientId }}"
  apiGroup: rbac.authorization.k8s.io
{{- end }}
EOF

# Package the chart
helm package spoke-bootstrap-chart/

echo "Helm chart created: spoke-bootstrap-0.1.0.tgz"
```

### Option 5: GitOps Workflow for Spoke Cluster Automation

Create a GitOps workflow that automatically configures spoke clusters when they're added to a configuration repository:

```bash
# Create GitOps configuration structure
mkdir -p gitops-spoke-config/{clusters,templates,workflows}

# Create cluster configuration template
cat > gitops-spoke-config/templates/cluster-config.yaml << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: CLUSTER_NAME-secret
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: "CLUSTER_NAME"
  server: "CLUSTER_SERVER"
  config: |
    {
      "execProviderConfig": {
        "command": "kubelogin",
        "args": [
          "get-token",
          "--login", "azurecli", 
          "--server-id", "6dae42f8-4368-4678-94ff-3960e28e3630"
        ],
        "apiVersion": "client.authentication.k8s.io/v1beta1"
      },
      "tlsClientConfig": {
        "insecure": false,
        "caData": "CLUSTER_CA"
      }
    }
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: CLUSTER_NAME-bootstrap
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/spoke-bootstrap-chart
    chart: spoke-bootstrap
    targetRevision: 0.1.0
    helm:
      values: |
        hubIdentity:
          clientId: "HUB_IDENTITY_CLIENT_ID"
        cluster:
          name: "CLUSTER_NAME"
          environment: "CLUSTER_ENV"
  destination:
    server: "CLUSTER_SERVER"
    namespace: argocd-managed
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

# Create automation script
cat > gitops-spoke-config/workflows/add-spoke-cluster.sh << 'EOF'
#!/bin/bash
set -e

CLUSTER_NAME=$1
RESOURCE_GROUP=$2
ENVIRONMENT=$3
HUB_IDENTITY_CLIENT_ID=$4

if [ $# -ne 4 ]; then
    echo "Usage: $0 <cluster-name> <resource-group> <environment> <hub-identity-client-id>"
    exit 1
fi

echo "Adding spoke cluster: $CLUSTER_NAME"

# Get cluster details
CLUSTER_SERVER=$(az aks show --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME --query fqdn -o tsv)
CLUSTER_CA=$(az aks show --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME --query kubeConfig -o tsv | base64 -d | yq eval '.clusters[0].cluster.certificate-authority-data' -)

# Create cluster configuration from template
sed -e "s/CLUSTER_NAME/$CLUSTER_NAME/g" \
    -e "s|CLUSTER_SERVER|https://$CLUSTER_SERVER|g" \
    -e "s/CLUSTER_CA/$CLUSTER_CA/g" \
    -e "s/HUB_IDENTITY_CLIENT_ID/$HUB_IDENTITY_CLIENT_ID/g" \
    -e "s/CLUSTER_ENV/$ENVIRONMENT/g" \
    templates/cluster-config.yaml > clusters/$CLUSTER_NAME-config.yaml

echo "Configuration created: clusters/$CLUSTER_NAME-config.yaml"
echo "Commit this file to your GitOps repository to complete spoke cluster onboarding"
EOF

chmod +x gitops-spoke-config/workflows/add-spoke-cluster.sh

# Example usage:
# ./gitops-spoke-config/workflows/add-spoke-cluster.sh myorg-dev-aks myorg-dev-rg dev $HUB_IDENTITY_CLIENT_ID
```

### Option 6: Azure DevOps/GitHub Actions Pipeline

Create a CI/CD pipeline that automates spoke cluster setup:

```bash
# Create GitHub Actions workflow
mkdir -p .github/workflows

cat > .github/workflows/spoke-cluster-onboarding.yml << 'EOF'
name: Spoke Cluster Onboarding

on:
  workflow_dispatch:
    inputs:
      cluster_name:
        description: 'Spoke cluster name'
        required: true
      resource_group:
        description: 'Resource group name'
        required: true
      environment:
        description: 'Environment (dev/staging/prod)'
        required: true
        default: 'dev'

jobs:
  configure-spoke-cluster:
    runs-on: ubuntu-latest
    
    steps:
    - name: Checkout repository
      uses: actions/checkout@v3
      
    - name: Azure Login
      uses: azure/login@v1
      with:
        creds: ${{ secrets.AZURE_CREDENTIALS }}
        
    - name: Setup kubectl
      uses: azure/setup-kubectl@v3
      
    - name: Setup Helm
      uses: azure/setup-helm@v3
      
    - name: Configure spoke cluster
      env:
        CLUSTER_NAME: ${{ github.event.inputs.cluster_name }}
        RESOURCE_GROUP: ${{ github.event.inputs.resource_group }}
        ENVIRONMENT: ${{ github.event.inputs.environment }}
        HUB_IDENTITY_CLIENT_ID: ${{ secrets.HUB_IDENTITY_CLIENT_ID }}
      run: |
        # Get spoke cluster credentials
        az aks get-credentials --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME
        
        # Apply bootstrap configuration
        helm install spoke-bootstrap ./spoke-bootstrap-chart \
          --set hubIdentity.clientId=$HUB_IDENTITY_CLIENT_ID \
          --set cluster.name=$CLUSTER_NAME \
          --set cluster.environment=$ENVIRONMENT \
          --create-namespace \
          --namespace argocd-managed
        
        # Add cluster to ArgoCD (from hub cluster)
        az aks get-credentials --resource-group myorg-hub-rg --name myorg-hub-aks --admin
        
        CLUSTER_SERVER=$(az aks show --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME --query fqdn -o tsv)
        CLUSTER_CA=$(az aks show --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME --query kubeConfig -o tsv | base64 -d | yq eval '.clusters[0].cluster.certificate-authority-data' -)
        
        # Create cluster secret in ArgoCD
        kubectl create secret generic ${CLUSTER_NAME}-secret \
          --from-literal=name=$CLUSTER_NAME \
          --from-literal=server=https://$CLUSTER_SERVER \
          --from-literal=config='{"execProviderConfig":{"command":"kubelogin","args":["get-token","--login","azurecli","--server-id","6dae42f8-4368-4678-94ff-3960e28e3630"],"apiVersion":"client.authentication.k8s.io/v1beta1"},"tlsClientConfig":{"insecure":false,"caData":"'$CLUSTER_CA'"}}' \
          --namespace argocd
          
        kubectl label secret ${CLUSTER_NAME}-secret \
          argocd.argoproj.io/secret-type=cluster \
          environment=$ENVIRONMENT \
          --namespace argocd
EOF
```

## Recommendation: Hybrid Approach

For production use, I recommend combining multiple approaches:

1. **Helm Chart** for spoke cluster bootstrap configuration
2. **ArgoCD ApplicationSet** for automatic application deployment to configured clusters
3. **CI/CD Pipeline** for automated cluster onboarding workflow
4. **GitOps Repository** for declarative cluster configuration management

This provides both automation and auditability while maintaining the GitOps principles.

## Lessons Learned and Issue Resolution

### Issue 1: ApplicationSet Cluster Secret Authentication Failures

**Problem**: ArgoCD ApplicationSet was failing to connect to spoke clusters with certificate parsing errors:
```
Unable to apply K8s REST config defaults: unable to load root certificates: unable to parse bytes as PEM block
```

**Root Cause**: The cluster secret was using `kubelogin` authentication which requires interactive login, but ArgoCD needs certificate-based authentication for automation.

**Solution**: Modified the `add-spoke-cluster.sh` script to use admin credentials and extract client certificates:

```bash
# Get admin kubeconfig (not user config which requires kubelogin)
az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" --admin --file "$TEMP_KUBECONFIG" --overwrite-existing

# Extract client certificate and key from admin kubeconfig  
CLIENT_CERT=$(kubectl config view --raw -o jsonpath="{.users[?(@.name=='clusterAdmin_${RESOURCE_GROUP}_${CLUSTER_NAME}')].user.client-certificate-data}")
CLIENT_KEY=$(kubectl config view --raw -o jsonpath="{.users[?(@.name=='clusterAdmin_${RESOURCE_GROUP}_${CLUSTER_NAME}')].user.client-key-data}")

# Use certificate-based config instead of kubelogin
config: |
  {
    "tlsClientConfig": {
      "insecure": false,
      "caData": "$CLUSTER_CA",
      "certData": "$CLIENT_CERT",
      "keyData": "$CLIENT_KEY"
    }
  }
```

### Issue 2: ApplicationSet Path Template Mismatch

**Problem**: ApplicationSet was looking for path `argo/spoke-bootstrap/overlays/spoke` but the actual environment-specific paths were `argo/spoke-bootstrap/overlays/dev`, `argo/spoke-bootstrap/overlays/staging`, etc.

**Root Cause**: Label mismatch between ApplicationSet selector (`environment=spoke`) and path template (`{{metadata.labels.environment}}`).

**Solution**: 
1. Keep cluster selector as `environment=spoke` to identify spoke clusters
2. Use `cluster-environment` label for actual environment (dev/staging/prod)
3. Update ApplicationSet path template to use `{{metadata.labels.cluster-environment}}`

```yaml
# ApplicationSet configuration
spec:
  generators:
  - clusters:
      selector:
        matchLabels:
          environment: spoke  # Identifies spoke clusters
  template:
    spec:
      source:
        path: argo/spoke-bootstrap/overlays/{{metadata.labels.cluster-environment}}  # Uses actual environment
```

### Issue 3: Git Repository Sync Issues

**Problem**: ApplicationSet created Applications but they couldn't sync with error:
```
argo/spoke-bootstrap/overlays/dev: app path does not exist
```

**Root Cause**: The spoke-bootstrap directory structure was created locally but not committed to the Git repository that ArgoCD was monitoring.

**Solution**: Ensure all automation files are properly committed and pushed:

```bash
# Add all spoke-bootstrap files to git
git add argo/spoke-bootstrap/ argo/setup-applicationset.sh argo/add-spoke-cluster.sh

# Commit with descriptive message
git commit -m "Add spoke cluster bootstrap automation with ApplicationSet"

# Push to remote repository
git push

# Trigger ArgoCD refresh if needed
kubectl patch application myorg-dev-aks-bootstrap -n argocd --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

### Issue 4: Kustomize Configuration and Variable Substitution

**Problem**: Initial attempts to use ApplicationSet variable substitution in Kustomize images field failed.

**Root Cause**: ApplicationSet variable substitution doesn't work the same way as Kustomize templating.

**Solution**: Used hardcoded values in environment-specific overlays instead of trying to substitute variables:

```yaml
# Instead of trying to substitute variables in Kustomize
# Use hardcoded values in each environment overlay
# argo/spoke-bootstrap/overlays/dev/hub-identity-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: hub-identity-config
  namespace: argocd-managed
data:
  clientId: "604074ac-5cd5-4be3-94a7-3a95bfaa0d60"  # Hardcoded hub identity client ID
```

### Issue 5: Context Switching During Automation

**Problem**: The `add-spoke-cluster.sh` script was trying to create ArgoCD cluster secrets while in the spoke cluster context, causing "argocd namespace not found" errors.

**Root Cause**: The script was extracting spoke cluster credentials but remaining in spoke cluster context when trying to create hub cluster resources.

**Solution**: Explicit context switching in the automation script:

```bash
# Extract spoke cluster credentials
az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" --admin --overwrite-existing
# ... extract cluster details ...

# Switch back to hub cluster to create the ArgoCD secret
kubectl config use-context hub-cluster >/dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "Error: Could not switch to hub-cluster context. Make sure hub cluster is configured."
    exit 1
fi

# Now create ArgoCD cluster secret
kubectl apply -f "${SECRET_NAME}.yaml"
```

### Best Practices Discovered

1. **Use Admin Credentials for ArgoCD**: While Azure RBAC is preferred for human access, ArgoCD requires admin certificates for reliable automation.

2. **Separate Concerns in Labels**: Use different labels for cluster selection (`environment=spoke`) vs. configuration (`cluster-environment=dev`).

3. **Validate Git Synchronization**: Always ensure automation files are committed to Git before testing ApplicationSet deployments.

4. **Explicit Context Management**: Never assume kubectl context in automation scripts - always set it explicitly.

5. **Environment-Specific Hardcoding**: For stable values like managed identity client IDs, hardcode them in environment overlays rather than trying to template them.

6. **Tool Dependencies**: Ensure all required tools (`yq`, `jq`) are installed before running automation scripts.

### Verification Checklist

After implementing spoke cluster automation, verify:

- ✅ ApplicationSet is deployed and status shows "ApplicationSetUpToDate"
- ✅ Cluster secrets have correct labels (`environment=spoke`, `cluster-environment=dev`)
- ✅ Git repository contains all spoke-bootstrap files
- ✅ Applications are created by ApplicationSet with correct paths
- ✅ Applications sync successfully (status: "Synced" and "Healthy")
- ✅ Spoke cluster has required resources (namespace, serviceaccount, RBAC, configmap)
- ✅ Hub identity client ID is correctly injected in spoke cluster resources

## Troubleshooting

### Issue: Admin Access Disabled or Not Available

If you encounter errors like "admin access disabled" or "operation not allowed":

```bash
# Check if admin access is disabled
az aks show --resource-group $HUB_RG --name $HUB_CLUSTER_NAME --query disableLocalAccounts -o tsv

# If true, admin access is disabled - use Azure RBAC instead
# 1. Get cluster credentials without --admin flag
az aks get-credentials --resource-group $HUB_RG --name $HUB_CLUSTER_NAME

# 2. Assign yourself cluster admin role
HUB_CLUSTER_ID=$(az aks show --resource-group $HUB_RG --name $HUB_CLUSTER_NAME --query id -o tsv)
az role assignment create \
  --assignee $(az ad signed-in-user show --query id -o tsv) \
  --role "Azure Kubernetes Service Cluster Admin Role" \
  --scope $HUB_CLUSTER_ID

# 3. Test access
kubectl get nodes
```

### Issue: Authentication Errors with kubelogin

If you get authentication errors:

```bash
# Install or update kubelogin
az aks install-cli

# Convert kubeconfig to use Azure AD
kubelogin convert-kubeconfig -l azurecli

# Login to Azure if needed
az login --scope https://management.azure.com//.default

# Test cluster access
kubectl get nodes
```

### Issue: Insufficient Permissions

For "forbidden" errors:

```bash
# Check your current role assignments
az role assignment list --assignee $(az ad signed-in-user show --query id -o tsv) --all

# Add required roles
az role assignment create \
  --assignee $(az ad signed-in-user show --query id -o tsv) \
  --role "Azure Kubernetes Service Cluster User Role" \
  --scope $CLUSTER_ID

# For broader permissions (development only):
az role assignment create \
  --assignee $(az ad signed-in-user show --query id -o tsv) \
  --role "Azure Kubernetes Service Cluster Admin Role" \
  --scope $CLUSTER_ID
```

## Summary

This guide demonstrated how to:

1. **Create Hub AKS cluster** with managed identity and Azure RBAC
2. **Install ArgoCD** using Helm with proper configuration
3. **Create spoke clusters** with appropriate RBAC configuration
4. **Configure hub-to-spoke authentication** using Azure managed identities
5. **Deploy applications** via ArgoCD to spoke clusters
6. **Validate the setup** with monitoring and RBAC testing
7. **Handle both admin and non-admin authentication methods**

### Key Differences from Terraform Approach

- **Manual resource creation** using Azure CLI commands
- **Step-by-step validation** at each phase
- **More granular control** over resource configuration
- **Easier troubleshooting** with direct CLI feedback
- **No state management** complexity

### Production Considerations

For production environments, consider:
- Using Azure Private Link for AKS API servers
- Implementing network security groups and policies
- Setting up proper ingress controllers and certificates
- Configuring backup and disaster recovery procedures
- Implementing proper secret management with Azure Key Vault

## Summary of Real-World Implementation

This guide has been updated based on actual implementation experience and includes solutions to real problems encountered:

### Successfully Implemented Architecture

1. **Hub Cluster**: Central ArgoCD instance managing multiple spoke clusters
2. **Automated Onboarding**: ApplicationSet automatically detects and configures new spoke clusters
3. **Certificate-Based Authentication**: Resolved kubelogin issues by using admin certificates for ArgoCD
4. **Kustomize Configuration Management**: Environment-specific overlays with proper base inheritance
5. **GitOps Workflow**: All configurations committed to Git for proper ArgoCD synchronization

### Key Implementation Insights

- **Authentication Strategy**: Admin certificates work better for ArgoCD automation than Azure AD authentication
- **Label Strategy**: Separate cluster selection labels (`environment=spoke`) from configuration labels (`cluster-environment=dev`)
- **Path Templates**: Use correct ApplicationSet variable substitution for Kustomize overlay paths
- **Git Synchronization**: Ensure all automation files are committed before testing ApplicationSet deployments
- **Context Management**: Explicit kubectl context switching prevents automation errors

### Automation Benefits Achieved

- **Zero Manual Configuration**: New spoke clusters are automatically configured when added to ArgoCD
- **Consistent Security**: Every spoke cluster gets the same RBAC and workload identity configuration
- **Environment Isolation**: Separate overlays ensure environment-specific configurations
- **Audit Trail**: All changes tracked through Git commits and ArgoCD Application history
- **Scalability**: Adding new environments or clusters requires minimal manual intervention

### Production Readiness Features

- ✅ **Robust Error Handling**: Scripts validate inputs and provide clear error messages
- ✅ **Context Safety**: Automatic context switching and restoration
- ✅ **Cleanup**: Temporary files removed after successful operations
- ✅ **Verification**: Built-in checks confirm successful deployments
- ✅ **Documentation**: Complete usage examples and troubleshooting guides

The ArgoCD Hub-Spoke pattern provides centralized GitOps management while maintaining security boundaries between environments. This implementation demonstrates how to overcome real-world challenges and achieve production-ready automation.