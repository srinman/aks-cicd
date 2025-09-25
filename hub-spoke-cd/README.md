# Hub-to-Spoke Direct Deployment using Managed Identity

This document demonstrates how to use the hub cluster's managed identity to directly deploy resources to a spoke cluster without ArgoCD. This showcases the underlying permissions and authentication mechanisms that enable the hub-spoke architecture.

## Prerequisites

- **Hub cluster with workload identity enabled** (recommended) or managed identity configured
- **Azure AD application with federated credentials** for workload identity (see setup guide)
- **Service account** in hub cluster configured for workload identity
- **RBAC permissions**: Workload identity service principal should have "Azure Kubernetes Service Cluster Admin Role" on spoke cluster(s)
- Spoke cluster created (via Terraform or Azure CLI) with local admin disabled
- kubectl configured with hub cluster context
- Azure CLI installed and authenticated
- **Terraform** (optional, for automated cluster discovery and workload identity setup)

> **🏆 Recommended Setup**: This guide now uses **Azure Workload Identity** as the primary authentication method. For setup instructions, see [WORKLOAD-IDENTITY-SETUP.md](WORKLOAD-IDENTITY-SETUP.md). Terraform automation is available in the `terraform/` directory.

## Overview

The hub cluster's managed identity enables direct cross-cluster operations by leveraging Azure RBAC permissions. This approach demonstrates:

1. **Service-to-Service Authentication**: Using managed identity instead of user credentials
2. **Cross-Cluster Operations**: Hub cluster workloads managing spoke cluster resources
3. **Automated Deployments**: Scripted deployment without manual intervention
4. **Azure RBAC Integration**: Leveraging Azure's native role-based access control

## Security Configuration

### Disabling Local Admin Account on Spoke Clusters

For enhanced security, it's recommended to disable the local admin account on spoke clusters and rely exclusively on Azure AD authentication. This ensures all access is audited and follows Azure RBAC policies.

#### Option 1: Disable Local Admin on Existing Cluster

```bash
# Disable local admin account on existing spoke cluster
az aks update \
    --resource-group $SPOKE_RG \
    --name $SPOKE_CLUSTER_NAME \
    --disable-local-accounts

# Verify the change
az aks show --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME \
    --query "disableLocalAccounts" -o tsv
```

#### Option 2: Create New Spoke Cluster Without Local Admin

```bash
# Create spoke cluster with local admin disabled from the start
az aks create \
    --resource-group $SPOKE_RG \
    --name $SPOKE_CLUSTER_NAME \
    --location eastus \
    --node-count 3 \
    --node-vm-size Standard_D2s_v3 \
    --enable-managed-identity \
    --disable-local-accounts \
    --enable-aad \
    --aad-admin-group-object-ids "your-admin-group-id" \
    --generate-ssh-keys
```

#### Option 3: Terraform Configuration for Spoke Cluster

```hcl
resource "azurerm_kubernetes_cluster" "spoke" {
  name                = "aks-spoke-prod-001"
  location            = azurerm_resource_group.spoke.location
  resource_group_name = azurerm_resource_group.spoke.name
  dns_prefix          = "aks-spoke-prod"
  
  # Disable local admin account for enhanced security
  local_account_disabled = true
  
  # Enable Azure AD integration
  azure_active_directory_role_based_access_control {
    managed = true
    admin_group_object_ids = [var.aad_admin_group_id]
  }
  
  default_node_pool {
    name       = "default"
    node_count = 3
    vm_size    = "Standard_D2s_v3"
  }
  
  identity {
    type = "SystemAssigned"
  }
}
```

#### Verification

After disabling local accounts, verify that only Azure AD authentication works:

```bash
# This should work (Azure AD auth)
az aks get-credentials --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME --use-azuread

# This should fail (local admin auth)
az aks get-credentials --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME --admin
```

#### Important Notes

- **Breaking Change**: Once disabled, local admin access cannot be restored without re-enabling
- **Emergency Access**: Ensure you have proper Azure AD admin group configured before disabling
- **CI/CD Impact**: All automation must use `--use-azuread` flag or managed identity authentication
- **Existing kubeconfig**: Users need to re-run `az aks get-credentials` with `--use-azuread` flag

#### Authentication for Hub-to-Spoke Operations

All hub-to-spoke operations use **Azure Workload Identity** for secure, credential-free authentication.

**Workload Identity Authentication:**
```bash
# Connect to spoke cluster using workload identity
az aks get-credentials --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME --use-azuread
kubelogin convert-kubeconfig -l workloadidentity
```

Environment variables are automatically injected by the workload identity webhook:
- `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_FEDERATED_TOKEN_FILE`, `AZURE_AUTHORITY_HOST`

> 📖 **Setup Required**: Complete the one-time setup in [WORKLOAD-IDENTITY-SETUP.md](WORKLOAD-IDENTITY-SETUP.md)

## Deployment

All deployments use **Azure Workload Identity** for secure authentication.

### Step 1: Set up workload identity (one-time setup)

**Option A: Automated setup using Terraform**
```bash
cd terraform/
cp workload-identity.tfvars.example workload-identity.tfvars
nano workload-identity.tfvars  # Update with your cluster details

# Apply workload identity configuration
terraform init
terraform plan -var-file="workload-identity.tfvars"
terraform apply -var-file="workload-identity.tfvars"
```

**Option B: Manual setup using the step-by-step guide**
```bash
# Follow detailed instructions in WORKLOAD-IDENTITY-SETUP.md
```

### Step 2: Deploy using workload identity

**Recommended: Kubernetes Job deployment**
```bash
# Use the workload identity-enabled Kubernetes Job
kubectl apply -f workload-identity-job-example.yaml

# Monitor the deployment
kubectl logs -f job/hub-to-spoke-workload-identity-deployment -n hub-operations
```

**Alternative: Manual deployment**

Follow the step-by-step instructions below for manual deployment with workload identity.

## Step 1: Discover and Connect to New Spoke Cluster

### 1.1 List Available Spoke Clusters

If you have multiple spoke clusters or want to discover recently created ones:

```bash
# List all AKS clusters in subscription with spoke naming pattern
echo "Discovering spoke clusters..."
az aks list --query "[?contains(name, 'spoke') || contains(name, 'dev') || contains(name, 'staging') || contains(name, 'prod')].{Name:name, ResourceGroup:resourceGroup, Location:location, Status:provisioningState}" -o table

# Alternative: List clusters by resource group pattern
az aks list --query "[?contains(resourceGroup, 'spoke') || contains(resourceGroup, 'dev') || contains(resourceGroup, 'staging') || contains(resourceGroup, 'prod')].{Name:name, ResourceGroup:resourceGroup, Location:location, Status:provisioningState}" -o table
```

### 1.2 Get Spoke Cluster Details

For a specific spoke cluster (replace with your actual cluster details):

```bash
# Set spoke cluster information
SPOKE_CLUSTER_NAME="myorg-dev-aks"
SPOKE_RG="myorg-dev-rg"

# Get cluster details
echo "Getting spoke cluster details..."
SPOKE_CLUSTER_FQDN=$(az aks show --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME --query fqdn -o tsv)
SPOKE_CLUSTER_ID=$(az aks show --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME --query id -o tsv)

echo "Spoke Cluster: $SPOKE_CLUSTER_NAME"
echo "Resource Group: $SPOKE_RG"
echo "FQDN: $SPOKE_CLUSTER_FQDN"
echo "Cluster ID: $SPOKE_CLUSTER_ID"
echo "Server Endpoint: https://$SPOKE_CLUSTER_FQDN"
```

### 1.3 Verify Hub Identity Permissions on Spoke Cluster

```bash
# Get hub cluster managed identity details
HUB_RG="myorg-hub-rg"
HUB_IDENTITY_NAME="myorg-hub-identity"
HUB_CLUSTER_NAME="myorg-hub-aks"

HUB_IDENTITY_PRINCIPAL_ID=$(az identity show --resource-group $HUB_RG --name $HUB_IDENTITY_NAME --query principalId -o tsv)
HUB_IDENTITY_CLIENT_ID=$(az identity show --resource-group $HUB_RG --name $HUB_IDENTITY_NAME --query clientId -o tsv)

echo "Hub Identity Principal ID: $HUB_IDENTITY_PRINCIPAL_ID"
echo "Hub Identity Client ID: $HUB_IDENTITY_CLIENT_ID"

# Create federated credentials for workload identity authentication
echo "Creating federated credentials for workload identity..."
AKS_OIDC_ISSUER=$(az aks show --resource-group $HUB_RG --name $HUB_CLUSTER_NAME --query "oidcIssuerProfile.issuerUrl" -o tsv)

az identity federated-credential create \
    --name "hub-to-spoke-federated-credential" \
    --identity-name $HUB_IDENTITY_NAME \
    --resource-group $HUB_RG \
    --issuer $AKS_OIDC_ISSUER \
    --subject system:serviceaccount:hub-operations:hub-to-spoke-sa \
    --audience api://AzureADTokenExchange

echo "✅ Federated credentials created for workload identity"

# Verify hub identity has required permissions on spoke cluster
echo ""
echo "Verifying hub identity permissions on spoke cluster..."
az role assignment list --assignee $HUB_IDENTITY_PRINCIPAL_ID --scope $SPOKE_CLUSTER_ID --query "[].{Role:roleDefinitionName, Scope:scope}" -o table

# Check if the required role is assigned
REQUIRED_ROLE="Azure Kubernetes Service Cluster Admin Role"
ROLE_EXISTS=$(az role assignment list --assignee $HUB_IDENTITY_PRINCIPAL_ID --scope $SPOKE_CLUSTER_ID --query "[?roleDefinitionName=='$REQUIRED_ROLE'].roleDefinitionName" -o tsv)

if [ -z "$ROLE_EXISTS" ]; then
    echo "❌ Required role '$REQUIRED_ROLE' not found!"
    echo "Assigning required role to hub identity..."
    
    az role assignment create \
        --assignee $HUB_IDENTITY_PRINCIPAL_ID \
        --role "$REQUIRED_ROLE" \
        --scope $SPOKE_CLUSTER_ID
    
    echo "✅ Role assigned successfully"
else
    echo "✅ Hub identity has required permissions on spoke cluster"
fi
```

## Step 2: Create Hub Cluster Job for Cross-Cluster Deployment

### 2.1 Create Deployment Manifests

Create the resources that will be deployed to the spoke cluster:

```bash
# Create directory for deployment manifests
mkdir -p hub-spoke-deployment/manifests

# Create namespace manifest
cat > hub-spoke-deployment/manifests/demo-namespace.yaml << 'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: demo-app
  labels:
    managed-by: hub-cluster
    deployment-method: direct-kubectl
    environment: spoke-demo
EOF

# Create nginx deployment manifest
cat > hub-spoke-deployment/manifests/nginx-deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-demo
  namespace: demo-app
  labels:
    app: nginx-demo
    managed-by: hub-cluster
spec:
  replicas: 3
  selector:
    matchLabels:
      app: nginx-demo
  template:
    metadata:
      labels:
        app: nginx-demo
    spec:
      containers:
      - name: nginx
        image: nginx:1.25
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 200m
            memory: 256Mi
        env:
        - name: DEPLOYMENT_SOURCE
          value: "hub-cluster-managed-identity"
        - name: TARGET_CLUSTER
          value: "spoke-cluster"
        readinessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 10
        livenessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 10
          periodSeconds: 30
EOF

# Create load balancer service manifest
cat > hub-spoke-deployment/manifests/nginx-service.yaml << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: nginx-demo-service
  namespace: demo-app
  labels:
    app: nginx-demo
    managed-by: hub-cluster
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path: /
spec:
  type: LoadBalancer
  ports:
  - port: 80
    targetPort: 80
    protocol: TCP
    name: http
  selector:
    app: nginx-demo
EOF

echo "✅ Deployment manifests created in hub-spoke-deployment/manifests/"
```

### 2.2 Create Cross-Cluster Deployment Script

```bash
cat > hub-spoke-deployment/deploy-to-spoke.sh << 'EOF'
#!/bin/bash
set -e

# Configuration
SPOKE_CLUSTER_NAME=${SPOKE_CLUSTER_NAME:-"myorg-dev-aks"}
SPOKE_RG=${SPOKE_RG:-"myorg-dev-rg"}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}🚀 Hub-to-Spoke Deployment Script${NC}"
echo "================================="
echo "Target Spoke Cluster: $SPOKE_CLUSTER_NAME"
echo "Resource Group: $SPOKE_RG"
echo ""

# Function to check command success
check_success() {
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ $1${NC}"
    else
        echo -e "${RED}❌ $1 failed${NC}"
        exit 1
    fi
}

# Step 1: Authenticate to spoke cluster using workload identity
echo -e "${YELLOW}Step 1: Authenticating to spoke cluster using workload identity${NC}"

# Get spoke cluster credentials and configure for workload identity
echo "Getting spoke cluster credentials..."
az aks get-credentials --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME --overwrite-existing --use-azuread

echo "Configuring kubeconfig for workload identity authentication..."
kubelogin convert-kubeconfig -l workloadidentity
check_success "Retrieved spoke cluster credentials"

# Test cluster connectivity
kubectl cluster-info --request-timeout=10s > /dev/null 2>&1
check_success "Verified connectivity to spoke cluster"

SPOKE_CONTEXT=$(kubectl config current-context)
echo "Current context: $SPOKE_CONTEXT"
echo ""

# Step 2: Deploy namespace
echo -e "${YELLOW}Step 2: Creating namespace on spoke cluster${NC}"
kubectl apply -f manifests/demo-namespace.yaml
check_success "Created namespace 'demo-app'"

# Wait for namespace to be ready
kubectl wait --for=condition=Ready --timeout=30s namespace/demo-app 2>/dev/null || true
echo ""

# Step 3: Deploy nginx application
echo -e "${YELLOW}Step 3: Deploying nginx application${NC}"
kubectl apply -f manifests/nginx-deployment.yaml
check_success "Created nginx deployment"

# Wait for deployment to be ready
echo "Waiting for deployment to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/nginx-demo -n demo-app
check_success "Nginx deployment is ready"

# Check pod status
echo "Pod status:"
kubectl get pods -n demo-app -o wide
echo ""

# Step 4: Deploy load balancer service
echo -e "${YELLOW}Step 4: Creating load balancer service${NC}"
kubectl apply -f manifests/nginx-service.yaml
check_success "Created load balancer service"

# Wait for service to get external IP
echo "Waiting for external IP assignment..."
for i in {1..30}; do
    EXTERNAL_IP=$(kubectl get service nginx-demo-service -n demo-app -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    if [ ! -z "$EXTERNAL_IP" ] && [ "$EXTERNAL_IP" != "null" ]; then
        break
    fi
    echo "Waiting for external IP... (attempt $i/30)"
    sleep 10
done

if [ ! -z "$EXTERNAL_IP" ] && [ "$EXTERNAL_IP" != "null" ]; then
    echo -e "${GREEN}✅ External IP assigned: $EXTERNAL_IP${NC}"
else
    echo -e "${YELLOW}⚠️  External IP not yet assigned (may take a few more minutes)${NC}"
fi

# Step 5: Display deployment summary
echo ""
echo -e "${BLUE}📋 Deployment Summary${NC}"
echo "===================="
echo "Namespace: demo-app"
echo "Deployment: nginx-demo (3 replicas)"
echo "Service: nginx-demo-service (LoadBalancer)"
if [ ! -z "$EXTERNAL_IP" ] && [ "$EXTERNAL_IP" != "null" ]; then
    echo "External URL: http://$EXTERNAL_IP"
fi
echo ""
echo "Resources created on spoke cluster '$SPOKE_CLUSTER_NAME':"
kubectl get all -n demo-app

echo ""
echo -e "${GREEN}🎉 Deployment completed successfully!${NC}"

# Step 6: Verification commands
echo ""
echo -e "${BLUE}🔍 Verification Commands${NC}"
echo "======================="
echo "Check pod logs:"
echo "  kubectl logs -n demo-app deployment/nginx-demo"
echo ""
echo "Check service status:"
echo "  kubectl get service nginx-demo-service -n demo-app"
echo ""
echo "Get external IP:"
echo "  kubectl get service nginx-demo-service -n demo-app -o jsonpath='{.status.loadBalancer.ingress[0].ip}'"
echo ""
echo "Test application:"
if [ ! -z "$EXTERNAL_IP" ] && [ "$EXTERNAL_IP" != "null" ]; then
    echo "  curl http://$EXTERNAL_IP"
else
    echo "  # Wait for external IP, then: curl http://<external-ip>"
fi

EOF

chmod +x hub-spoke-deployment/deploy-to-spoke.sh
```

### 2.3 Create Cleanup Script

```bash
cat > hub-spoke-deployment/cleanup-spoke.sh << 'EOF'
#!/bin/bash
set -e

# Configuration
SPOKE_CLUSTER_NAME=${SPOKE_CLUSTER_NAME:-"myorg-dev-aks"}
SPOKE_RG=${SPOKE_RG:-"myorg-dev-rg"}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}🧹 Hub-to-Spoke Cleanup Script${NC}"
echo "==============================="
echo "Target Spoke Cluster: $SPOKE_CLUSTER_NAME"
echo ""

# Get spoke cluster credentials using managed identity
echo -e "${YELLOW}Connecting to spoke cluster...${NC}"
az aks get-credentials --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME --overwrite-existing --use-azuread

# Check if namespace exists
if kubectl get namespace demo-app > /dev/null 2>&1; then
    echo -e "${YELLOW}Cleaning up resources in demo-app namespace...${NC}"
    
    # Show resources before cleanup
    echo "Resources to be deleted:"
    kubectl get all -n demo-app
    echo ""
    
    # Confirm deletion
    read -p "Are you sure you want to delete these resources? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # Delete the namespace (this will delete all resources in it)
        kubectl delete namespace demo-app --timeout=300s
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✅ Successfully cleaned up all resources${NC}"
        else
            echo -e "${RED}❌ Cleanup failed${NC}"
            exit 1
        fi
    else
        echo "Cleanup cancelled"
        exit 0
    fi
else
    echo -e "${YELLOW}No demo-app namespace found - nothing to clean up${NC}"
fi

echo -e "${GREEN}🎉 Cleanup completed!${NC}"
EOF

chmod +x hub-spoke-deployment/cleanup-spoke.sh
```

## Step 3: Execute Cross-Cluster Deployment from Hub

### 3.1 Run Deployment from Hub Cluster

Execute the deployment from a pod running on the hub cluster using the managed identity:

```bash
# Ensure you're on the hub cluster context
kubectl config use-context hub-cluster

# Create a deployment job on the hub cluster that will deploy to spoke cluster
cat > hub-deployment-job.yaml << EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: hub-to-spoke-deployment
  namespace: hub-operations  # Use the workload identity namespace
  labels:
    job-type: cross-cluster-deployment
spec:
  ttlSecondsAfterFinished: 3600  # Keep job for 1 hour after completion
  template:
    metadata:
      labels:
        azure.workload.identity/use: "true"
        job-type: cross-cluster-deployment
    spec:
      serviceAccountName: hub-to-spoke-sa  # Use workload identity service account
      restartPolicy: OnFailure
      containers:
      - name: deployment-container
        image: mcr.microsoft.com/azure-cli:latest
        env:
        - name: SPOKE_CLUSTER_NAME
          value: "$SPOKE_CLUSTER_NAME"
        - name: SPOKE_RG
          value: "$SPOKE_RG"
        # Workload identity environment variables are automatically injected:
        # - AZURE_CLIENT_ID
        # - AZURE_TENANT_ID  
        # - AZURE_FEDERATED_TOKEN_FILE
        # - AZURE_AUTHORITY_HOST
        command: ["/bin/bash"]
        args:
          - -c
          - |
            set -e
            echo "🚀 Starting hub-to-spoke deployment using managed identity"
            echo "Hub Identity Client ID: \$HUB_IDENTITY_CLIENT_ID"
            echo "Target: \$SPOKE_CLUSTER_NAME in \$SPOKE_RG"
            
            # Install required packages (Alpine Linux packages)
            echo "Installing required packages..."
            apk add --no-cache curl tar gzip
            
            # Install kubectl
            echo "Installing kubectl..."
            curl -LO "https://dl.k8s.io/release/\$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
            chmod +x kubectl
            mv kubectl /usr/local/bin/
            echo "✅ kubectl installed successfully"
            
            # Install kubelogin - direct binary download (more reliable)
            echo "Installing kubelogin..."
            KUBELOGIN_VERSION=\$(curl -s https://api.github.com/repos/Azure/kubelogin/releases/latest | grep '"tag_name"' | cut -d'"' -f4)
            curl -L "https://github.com/Azure/kubelogin/releases/download/\${KUBELOGIN_VERSION}/kubelogin-linux-amd64.zip" -o kubelogin.zip
            
            # Check if unzip is available, if not install it
            if ! command -v unzip &> /dev/null; then
                echo "Installing unzip..."
                apk add --no-cache unzip
            fi
            
            unzip kubelogin.zip
            mv bin/linux_amd64/kubelogin /usr/local/bin/
            chmod +x /usr/local/bin/kubelogin
            rm -f kubelogin.zip
            echo "✅ kubelogin installed successfully"
            
            # Verify workload identity environment variables
            echo "Using workload identity authentication"
            echo "AZURE_CLIENT_ID: \$AZURE_CLIENT_ID"
            echo "AZURE_TENANT_ID: \$AZURE_TENANT_ID"
            echo "AZURE_FEDERATED_TOKEN_FILE: \$AZURE_FEDERATED_TOKEN_FILE"
            
            # Authenticate using workload identity token
            echo "Authenticating with Azure using workload identity..."
            if [ -f "\$AZURE_FEDERATED_TOKEN_FILE" ]; then
                az login --service-principal \\
                    --username "\$AZURE_CLIENT_ID" \\
                    --tenant "\$AZURE_TENANT_ID" \\
                    --federated-token "\$(cat \$AZURE_FEDERATED_TOKEN_FILE)"
                echo "✅ Successfully authenticated using workload identity"
            else
                echo "❌ Federated token file not found: \$AZURE_FEDERATED_TOKEN_FILE"
                exit 1
            fi
            
            # Verify authentication
            az account show
            
            # Get spoke cluster credentials using workload identity
            az aks get-credentials --resource-group \$SPOKE_RG --name \$SPOKE_CLUSTER_NAME --use-azuread
            
            # Configure kubeconfig for workload identity
            kubelogin convert-kubeconfig -l workloadidentity
            
            # Create deployment manifests
            mkdir -p /tmp/manifests
            
            # Create namespace
            cat > /tmp/manifests/namespace.yaml << 'MANIFEST_EOF'
            apiVersion: v1
            kind: Namespace
            metadata:
              name: demo-app
              labels:
                managed-by: hub-cluster-job
                deployment-timestamp: "$(date -u +%Y%m%d-%H%M%S)"
            MANIFEST_EOF
            
            # Create deployment
            cat > /tmp/manifests/deployment.yaml << 'MANIFEST_EOF'
            apiVersion: apps/v1
            kind: Deployment
            metadata:
              name: nginx-demo
              namespace: demo-app
              labels:
                app: nginx-demo
                deployed-by: hub-cluster-managed-identity
            spec:
              replicas: 3
              selector:
                matchLabels:
                  app: nginx-demo
              template:
                metadata:
                  labels:
                    app: nginx-demo
                spec:
                  containers:
                  - name: nginx
                    image: nginx:1.25
                    ports:
                    - containerPort: 80
                    env:
                    - name: DEPLOYMENT_SOURCE
                      value: "hub-cluster-job"
                    - name: DEPLOYMENT_TIME
                      value: "$(date -u)"
                    resources:
                      requests:
                        cpu: 100m
                        memory: 128Mi
                      limits:
                        cpu: 200m
                        memory: 256Mi
            MANIFEST_EOF
            
            # Create service
            cat > /tmp/manifests/service.yaml << 'MANIFEST_EOF'
            apiVersion: v1
            kind: Service
            metadata:
              name: nginx-demo-service
              namespace: demo-app
              labels:
                app: nginx-demo
            spec:
              type: LoadBalancer
              ports:
              - port: 80
                targetPort: 80
                name: http
              selector:
                app: nginx-demo
            MANIFEST_EOF
            
            # Apply manifests
            echo "📦 Creating namespace..."
            kubectl apply -f /tmp/manifests/namespace.yaml
            
            echo "🚀 Deploying nginx application..."
            kubectl apply -f /tmp/manifests/deployment.yaml
            
            echo "🌐 Creating load balancer service..."
            kubectl apply -f /tmp/manifests/service.yaml
            
            # Wait for deployment
            echo "⏳ Waiting for deployment to be ready..."
            kubectl wait --for=condition=available --timeout=300s deployment/nginx-demo -n demo-app
            
            echo "📋 Deployment status:"
            kubectl get all -n demo-app
            
            echo "✅ Hub-to-spoke deployment completed successfully!"
            echo "🔗 Resources deployed to spoke cluster: \$SPOKE_CLUSTER_NAME"
EOF

# Create the hub-operations namespace if it doesn't exist
echo "Creating hub-operations namespace..."
kubectl create namespace hub-operations --dry-run=client -o yaml | kubectl apply -f -

# Create the service account for workload identity
echo "Creating service account for workload identity..."
cat > hub-to-spoke-sa.yaml << EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: hub-to-spoke-sa
  namespace: hub-operations
  annotations:
    azure.workload.identity/client-id: "$HUB_IDENTITY_CLIENT_ID"
  labels:
    azure.workload.identity/use: "true"
EOF

kubectl apply -f hub-to-spoke-sa.yaml

# Apply the job
kubectl apply -f hub-deployment-job.yaml

echo "✅ Hub-to-spoke deployment job created"
echo ""
echo "Monitor the job with:"
echo "  kubectl get job hub-to-spoke-deployment"
echo "  kubectl logs job/hub-to-spoke-deployment -f"
```

### 3.2 Monitor Deployment Progress

```bash
# Watch job status
echo "Monitoring deployment job..."
kubectl get job hub-to-spoke-deployment -w &
WATCH_PID=$!

# Follow job logs
echo ""
echo "Following deployment logs..."
kubectl logs job/hub-to-spoke-deployment -f --tail=50

# Stop watching job status
kill $WATCH_PID 2>/dev/null || true

# Check final job status
echo ""
echo "Final job status:"
kubectl get job hub-to-spoke-deployment
kubectl describe job hub-to-spoke-deployment
```

### 3.3 Verify Spoke Cluster Resources

```bash
# Switch to spoke cluster to verify resources using managed identity
az aks get-credentials --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME --use-azuread

echo "Verifying resources on spoke cluster..."
kubectl get namespace demo-app
kubectl get all -n demo-app

# Check external IP assignment
echo ""
echo "Checking service external IP..."
for i in {1..20}; do
    EXTERNAL_IP=$(kubectl get service nginx-demo-service -n demo-app -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    if [ ! -z "$EXTERNAL_IP" ] && [ "$EXTERNAL_IP" != "null" ]; then
        echo "✅ External IP assigned: $EXTERNAL_IP"
        echo "🌐 Access your application at: http://$EXTERNAL_IP"
        break
    fi
    echo "⏳ Waiting for external IP assignment... (attempt $i/20)"
    sleep 15
done

if [ -z "$EXTERNAL_IP" ] || [ "$EXTERNAL_IP" == "null" ]; then
    echo "⚠️  External IP not yet assigned. Check service status:"
    kubectl describe service nginx-demo-service -n demo-app
fi
```

## Step 4: Alternative Methods

### 4.1 Direct Script Execution (Without Kubernetes Job)

For simpler scenarios, you can run the deployment script directly:

```bash
# Set environment variables
export SPOKE_CLUSTER_NAME="myorg-dev-aks"
export SPOKE_RG="myorg-dev-rg"
export HUB_IDENTITY_CLIENT_ID=$(az identity show --resource-group myorg-hub-rg --name myorg-hub-identity --query clientId -o tsv)

# Run deployment script
cd hub-spoke-deployment
./deploy-to-spoke.sh
```

### 4.2 Using Azure Container Instances (ACI)

Deploy using Azure Container Instances for cross-cluster operations:

```bash
# Create container group with managed identity
cat > aci-deployment.yaml << EOF
apiVersion: 2019-12-01
location: East US 2
name: hub-spoke-deployer
properties:
  containers:
  - name: kubectl-deployer
    properties:
      image: mcr.microsoft.com/azure-cli:latest
      command:
      - /bin/bash
      - -c
      - |
        # Your deployment script here
        echo "Deploying from ACI using managed identity"
        # ... (same deployment logic as above)
      resources:
        requests:
          cpu: 1
          memoryInGb: 1.5
      environmentVariables:
      - name: SPOKE_CLUSTER_NAME
        value: $SPOKE_CLUSTER_NAME
      - name: SPOKE_RG
        value: $SPOKE_RG
  identity:
    type: UserAssigned
    userAssignedIdentities:
      /subscriptions/$SUBSCRIPTION_ID/resourceGroups/$HUB_RG/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$HUB_IDENTITY_NAME: {}
  osType: Linux
  restartPolicy: OnFailure
EOF

# Deploy container group
az container create --resource-group $HUB_RG --file aci-deployment.yaml
```

## Step 5: Verification and Testing

### 5.1 Comprehensive Verification Script

```bash
cat > verify-deployment.sh << 'EOF'
#!/bin/bash

SPOKE_CLUSTER_NAME=${SPOKE_CLUSTER_NAME:-"myorg-dev-aks"}
SPOKE_RG=${SPOKE_RG:-"myorg-dev-rg"}

echo "🔍 Verifying hub-to-spoke deployment"
echo "===================================="

# Connect to spoke cluster using managed identity
az aks get-credentials --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME --use-azuread

# Check namespace
echo "1. Namespace status:"
kubectl get namespace demo-app -o wide

# Check deployment
echo ""
echo "2. Deployment status:"
kubectl get deployment nginx-demo -n demo-app -o wide

# Check pods
echo ""
echo "3. Pod status:"
kubectl get pods -n demo-app -o wide

# Check service
echo ""
echo "4. Service status:"
kubectl get service nginx-demo-service -n demo-app -o wide

# Get external IP and test
EXTERNAL_IP=$(kubectl get service nginx-demo-service -n demo-app -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

if [ ! -z "$EXTERNAL_IP" ] && [ "$EXTERNAL_IP" != "null" ]; then
    echo ""
    echo "5. Application accessibility test:"
    echo "External IP: $EXTERNAL_IP"
    
    # Test HTTP connectivity
    if curl -s --connect-timeout 10 "http://$EXTERNAL_IP" > /dev/null; then
        echo "✅ Application is accessible at http://$EXTERNAL_IP"
    else
        echo "❌ Application is not yet accessible (may still be starting)"
    fi
else
    echo ""
    echo "⚠️ External IP not yet assigned"
fi

# Check resource labels to confirm hub deployment
echo ""
echo "6. Confirming deployment source:"
kubectl get deployment nginx-demo -n demo-app -o jsonpath='{.metadata.labels}' | jq .
EOF

chmod +x verify-deployment.sh
./verify-deployment.sh
```

### 5.2 Test Application Functionality

```bash
# Get external IP
EXTERNAL_IP=$(kubectl get service nginx-demo-service -n demo-app -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

if [ ! -z "$EXTERNAL_IP" ] && [ "$EXTERNAL_IP" != "null" ]; then
    echo "Testing nginx application at $EXTERNAL_IP"
    
    # Test basic connectivity
    curl -v "http://$EXTERNAL_IP"
    
    # Test with headers to verify nginx
    echo ""
    echo "Server headers:"
    curl -I "http://$EXTERNAL_IP"
    
    # Load test (optional)
    echo ""
    echo "Quick load test:"
    for i in {1..5}; do
        echo "Request $i:"
        curl -s -w "HTTP Status: %{http_code}, Time: %{time_total}s\n" "http://$EXTERNAL_IP" -o /dev/null
        sleep 1
    done
else
    echo "External IP not available yet. Check service status:"
    kubectl describe service nginx-demo-service -n demo-app
fi
```

## Step 6: Cleanup

### 6.1 Clean Up Spoke Cluster Resources

```bash
# Run cleanup script
cd hub-spoke-deployment
./cleanup-spoke.sh

# Or manual cleanup
# kubectl delete namespace demo-app --timeout=300s
```

### 6.2 Clean Up Hub Cluster Job

```bash
# Switch to hub cluster
kubectl config use-context hub-cluster

# Delete the deployment job
kubectl delete job hub-to-spoke-deployment

# Clean up job manifest
rm -f hub-deployment-job.yaml
```

## Summary

This document demonstrated how to:

1. **Discover and connect** to Terraform-created spoke clusters
2. **Verify hub identity permissions** on spoke clusters  
3. **Deploy resources directly** from hub to spoke using managed identity
4. **Create cross-cluster deployment jobs** on the hub cluster
5. **Verify and test** deployed applications
6. **Clean up resources** after testing

### Key Concepts Demonstrated

- **Managed Identity Cross-Cluster Access**: Hub cluster identity can manage spoke cluster resources
- **Azure RBAC Integration**: Permissions managed through Azure role assignments
- **Kubernetes Job-Based Deployment**: Automated deployment using Kubernetes jobs
- **Service-to-Service Authentication**: No user credentials required for automation
- **Cross-Cluster Resource Management**: Direct kubectl operations across cluster boundaries

### Security Implications

- Hub cluster managed identity has admin-level access to spoke clusters
- This enables ArgoCD and other hub services to manage spoke workloads
- Permissions are scoped to specific clusters through Azure RBAC
- All operations are audited through Azure Activity Log

This approach forms the foundation for GitOps workflows where ArgoCD uses similar mechanisms to deploy applications across the hub-spoke architecture.

## Troubleshooting

### Common Issues with Azure AD Authentication

#### Issue 1: "error: You must be logged in to the server (Unauthorized)"

**Cause**: Local admin account is disabled and Azure AD authentication is not properly configured.

**Solution**:
```bash
# Re-authenticate with Azure AD
az login

# Ensure you're using the correct subscription
az account show
az account set --subscription "your-subscription-id"

# Get credentials with Azure AD authentication
az aks get-credentials --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME --use-azuread --overwrite-existing

# Test connection
kubectl cluster-info
```

#### Issue 2: "The client does not have authorization to perform action"

**Cause**: Hub cluster managed identity lacks proper RBAC permissions on spoke cluster.

**Solution**:
```bash
# Check current role assignments on spoke cluster
az role assignment list --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$SPOKE_RG/providers/Microsoft.ContainerService/managedClusters/$SPOKE_CLUSTER_NAME"

# Get hub cluster managed identity
HUB_IDENTITY=$(az aks show --resource-group $HUB_RG --name $HUB_CLUSTER_NAME --query "kubeletIdentity.objectId" -o tsv)

# Assign required role
az role assignment create \
    --assignee $HUB_IDENTITY \
    --role "Azure Kubernetes Service Cluster Admin Role" \
    --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$SPOKE_RG/providers/Microsoft.ContainerService/managedClusters/$SPOKE_CLUSTER_NAME"
```

#### Issue 3: "Local admin account is disabled"

**Cause**: Attempting to use `--admin` flag when local accounts are disabled.

**Solution**:
```bash
# Remove --admin flag and use --use-azuread instead
az aks get-credentials --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME --use-azuread

# If you need to re-enable local accounts (not recommended for production)
az aks update --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME --enable-local-accounts
```

#### Issue 4: "Token refresh failed"

**Cause**: Azure AD token has expired or is invalid.

**Solution**:
```bash
# Clear kubectl context and re-authenticate
kubectl config delete-context $SPOKE_CLUSTER_NAME
kubectl config delete-cluster $SPOKE_CLUSTER_NAME
kubectl config delete-user $SPOKE_CLUSTER_NAME

# Re-authenticate
az aks get-credentials --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME --use-azuread --overwrite-existing

# Or refresh Azure CLI login
az login --use-device-code
```

#### Issue 5: Terraform Authentication Errors

**Cause**: Terraform cannot authenticate to Azure or access resources.

**Solution**:
```bash
# Verify Azure CLI authentication
az account show

# If using service principal, check environment variables
echo $ARM_CLIENT_ID
echo $ARM_SUBSCRIPTION_ID
echo $ARM_TENANT_ID

# Re-initialize Terraform
cd terraform/
rm -rf .terraform/
terraform init
terraform plan
```

### Verification Commands

#### Check Cluster Security Configuration

```bash
# Verify local accounts are disabled
az aks show --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME \
    --query "disableLocalAccounts" -o tsv

# Check Azure AD configuration
az aks show --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME \
    --query "aadProfile" -o table

# List role assignments on spoke cluster
az role assignment list \
    --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$SPOKE_RG/providers/Microsoft.ContainerService/managedClusters/$SPOKE_CLUSTER_NAME" \
    --output table
```

#### Validate Hub Identity Permissions

```bash
# Get hub cluster identity
HUB_IDENTITY=$(az aks show --resource-group $HUB_RG --name $HUB_CLUSTER_NAME --query "kubeletIdentity.objectId" -o tsv)

# Check what roles the hub identity has on spoke cluster
az role assignment list --assignee $HUB_IDENTITY --output table

# Verify identity can access spoke cluster
az aks get-credentials --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME --use-azuread
kubectl auth can-i "*" "*" --all-namespaces
```

### Security Best Practices

1. **Always disable local admin accounts** on production spoke clusters
2. **Use Azure AD groups** for administrative access instead of individual users
3. **Implement least privilege** - grant only the minimum required permissions
4. **Regular audit** role assignments and access patterns
5. **Enable audit logging** on all clusters for compliance and security monitoring
6. **Use managed identity** for all service-to-service authentication
7. **Rotate credentials** regularly and remove unused service principals

### Emergency Access Procedures

If you lose access to a spoke cluster with disabled local accounts:

1. **Through Azure Portal**: Use the "Run command" feature to execute kubectl commands
2. **Through Azure CLI**: Use `az aks command invoke` to run commands without kubeconfig
3. **Re-enable local accounts** temporarily if absolutely necessary:

```bash
# Emergency re-enable (use with caution)
az aks update --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME --enable-local-accounts

# Get admin credentials
az aks get-credentials --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME --admin --overwrite-existing

# Fix the issue, then disable local accounts again
az aks update --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME --disable-local-accounts
```