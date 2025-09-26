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

