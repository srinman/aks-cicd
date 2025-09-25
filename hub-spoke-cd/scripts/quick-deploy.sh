#!/bin/bash
set -e

# Hub-to-Spoke Quick Deployment Script
# This script demonstrates direct deployment from hub cluster to spoke cluster

# Configuration (set these environment variables)
SPOKE_CLUSTER_NAME=${SPOKE_CLUSTER_NAME:-""}
SPOKE_RG=${SPOKE_RG:-""}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}🚀 Hub-to-Spoke Quick Deployment${NC}"
echo "================================="

# Validate required parameters
if [ -z "$SPOKE_CLUSTER_NAME" ] || [ -z "$SPOKE_RG" ]; then
    echo -e "${RED}❌ Error: Required parameters not set${NC}"
    echo "Please set the following environment variables:"
    echo "  export SPOKE_CLUSTER_NAME='your-spoke-cluster-name'"
    echo "  export SPOKE_RG='your-spoke-resource-group'"
    echo ""
    echo "Example:"
    echo "  export SPOKE_CLUSTER_NAME='myorg-dev-aks'"
    echo "  export SPOKE_RG='myorg-dev-rg'"
    exit 1
fi

echo "Target Spoke Cluster: $SPOKE_CLUSTER_NAME"
echo "Resource Group: $SPOKE_RG"
echo ""

# Verify workload identity environment
echo -e "${YELLOW}Verifying workload identity environment...${NC}"
if [[ -z "${AZURE_CLIENT_ID:-}" ]]; then
    echo -e "${RED}❌ AZURE_CLIENT_ID not found. Workload identity may not be configured correctly.${NC}"
    echo "Please ensure workload identity is set up according to WORKLOAD-IDENTITY-SETUP.md"
    exit 1
fi

echo "Using Workload Identity - Client ID: $AZURE_CLIENT_ID"

# Verify spoke cluster exists
echo -e "${YELLOW}Verifying spoke cluster exists...${NC}"
SPOKE_EXISTS=$(az aks show --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME --query name -o tsv 2>/dev/null || echo "")

if [ -z "$SPOKE_EXISTS" ]; then
    echo -e "${RED}❌ Spoke cluster '$SPOKE_CLUSTER_NAME' not found in resource group '$SPOKE_RG'${NC}"
    echo "Available clusters in subscription:"
    az aks list --query "[].{Name:name, ResourceGroup:resourceGroup}" -o table
    exit 1
fi

echo -e "${GREEN}✅ Spoke cluster found${NC}"

# Get spoke cluster credentials
echo -e "${YELLOW}Getting spoke cluster credentials using Azure AD authentication...${NC}"

# Check if local admin is disabled (recommended security practice)
LOCAL_DISABLED=$(az aks show --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME --query "disableLocalAccounts" -o tsv 2>/dev/null || echo "false")
if [[ "$LOCAL_DISABLED" == "true" ]]; then
    echo -e "${GREEN}✓ Local admin accounts are disabled (secure configuration)${NC}"
else
    echo -e "${YELLOW}⚠ Local admin accounts are enabled (consider disabling for production)${NC}"
fi

# Get credentials using Azure AD authentication (uses kubelogin for K8s 1.24+)
az aks get-credentials --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME --overwrite-existing --use-azuread

# Configure kubeconfig for workload identity
echo -e "${BLUE}Converting kubeconfig to use workload identity authentication...${NC}"
kubelogin convert-kubeconfig -l workloadidentity
echo -e "${GREEN}✓ Using workload identity (AZURE_CLIENT_ID: $AZURE_CLIENT_ID)${NC}"

# Test connectivity
kubectl cluster-info --request-timeout=10s > /dev/null
echo -e "${GREEN}✅ Connected to spoke cluster${NC}"

# Create namespace
echo -e "${YELLOW}Creating demo namespace...${NC}"
kubectl apply -f - << EOF
apiVersion: v1
kind: Namespace
metadata:
  name: demo-app
  labels:
    managed-by: hub-cluster
    deployment-method: direct-kubectl
    deployment-time: "$(date -u +%Y%m%d-%H%M%S)"
EOF

echo -e "${GREEN}✅ Namespace created${NC}"

# Deploy nginx
echo -e "${YELLOW}Deploying nginx application...${NC}"
kubectl apply -f - << EOF
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
          value: "hub-cluster-script"
        - name: TARGET_CLUSTER
          value: "$SPOKE_CLUSTER_NAME"
        - name: DEPLOYED_BY
          value: "$HUB_IDENTITY_CLIENT_ID"
        - name: DEPLOYMENT_TIME
          value: "$(date -u)"
EOF

# Wait for deployment
echo "Waiting for deployment to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/nginx-demo -n demo-app
echo -e "${GREEN}✅ Nginx deployment ready${NC}"

# Create load balancer service
echo -e "${YELLOW}Creating load balancer service...${NC}"
kubectl apply -f - << EOF
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

echo -e "${GREEN}✅ Service created${NC}"

# Wait for external IP
echo -e "${YELLOW}Waiting for external IP assignment...${NC}"
for i in {1..30}; do
    EXTERNAL_IP=$(kubectl get service nginx-demo-service -n demo-app -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    if [ ! -z "$EXTERNAL_IP" ] && [ "$EXTERNAL_IP" != "null" ]; then
        break
    fi
    echo "Waiting for external IP... (attempt $i/30)"
    sleep 10
done

# Display results
echo ""
echo -e "${BLUE}📋 Deployment Summary${NC}"
echo "===================="
echo "Spoke Cluster: $SPOKE_CLUSTER_NAME"
echo "Namespace: demo-app"
echo "Deployment: nginx-demo (3 replicas)"
echo "Service: nginx-demo-service (LoadBalancer)"

if [ ! -z "$EXTERNAL_IP" ] && [ "$EXTERNAL_IP" != "null" ]; then
    echo -e "${GREEN}External IP: $EXTERNAL_IP${NC}"
    echo -e "${GREEN}🌐 Access your application at: http://$EXTERNAL_IP${NC}"
    
    # Test connectivity
    echo ""
    echo -e "${YELLOW}Testing application connectivity...${NC}"
    if curl -s --connect-timeout 10 "http://$EXTERNAL_IP" > /dev/null; then
        echo -e "${GREEN}✅ Application is accessible!${NC}"
    else
        echo -e "${YELLOW}⚠️  Application may still be starting up${NC}"
    fi
else
    echo -e "${YELLOW}⚠️  External IP not yet assigned (check service status)${NC}"
fi

echo ""
echo "All resources:"
kubectl get all -n demo-app

echo ""
echo -e "${GREEN}🎉 Hub-to-spoke deployment completed successfully!${NC}"
echo ""
echo "Cleanup command:"
echo "  kubectl delete namespace demo-app"