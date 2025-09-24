#!/bin/bash
set -e

# Hub-to-Spoke Cleanup Script
# This script removes all resources created by the deployment

SPOKE_CLUSTER_NAME=${SPOKE_CLUSTER_NAME:-""}
SPOKE_RG=${SPOKE_RG:-""}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}🧹 Hub-to-Spoke Cleanup Script${NC}"
echo "==============================="

# Validate parameters
if [ -z "$SPOKE_CLUSTER_NAME" ] || [ -z "$SPOKE_RG" ]; then
    echo -e "${RED}❌ Error: Required parameters not set${NC}"
    echo "Please set: SPOKE_CLUSTER_NAME and SPOKE_RG"
    echo ""
    echo "Example:"
    echo "  export SPOKE_CLUSTER_NAME='myorg-dev-aks'"
    echo "  export SPOKE_RG='myorg-dev-rg'"
    exit 1
fi

echo "Target Spoke Cluster: $SPOKE_CLUSTER_NAME"
echo "Resource Group: $SPOKE_RG"
echo ""

# Connect to spoke cluster
echo -e "${YELLOW}Connecting to spoke cluster...${NC}"
az aks get-credentials --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME --overwrite-existing > /dev/null

# Check if namespace exists
if ! kubectl get namespace demo-app > /dev/null 2>&1; then
    echo -e "${YELLOW}⚠️  demo-app namespace not found - nothing to clean up${NC}"
    exit 0
fi

echo -e "${GREEN}✅ Connected to spoke cluster${NC}"

# Show resources that will be deleted
echo ""
echo -e "${YELLOW}Resources to be deleted:${NC}"
echo "========================"
kubectl get all -n demo-app
echo ""
kubectl get namespace demo-app

# Get external IP before deletion (for information)
EXTERNAL_IP=$(kubectl get service nginx-demo-service -n demo-app -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
if [ ! -z "$EXTERNAL_IP" ] && [ "$EXTERNAL_IP" != "null" ]; then
    echo ""
    echo -e "${BLUE}ℹ️  External IP that will be released: $EXTERNAL_IP${NC}"
fi

# Confirm deletion
echo ""
read -p "$(echo -e ${YELLOW}Are you sure you want to delete these resources? [y/N]:${NC} )" -n 1 -r
echo

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cleanup cancelled"
    exit 0
fi

# Delete the namespace (this will delete all resources in it)
echo ""
echo -e "${YELLOW}Deleting demo-app namespace and all resources...${NC}"
kubectl delete namespace demo-app --timeout=300s

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Successfully deleted all resources${NC}"
else
    echo -e "${RED}❌ Cleanup failed${NC}"
    exit 1
fi

# Verify cleanup
echo ""
echo -e "${YELLOW}Verifying cleanup...${NC}"
if kubectl get namespace demo-app > /dev/null 2>&1; then
    echo -e "${YELLOW}⚠️  Namespace still exists (may be terminating)${NC}"
    kubectl get namespace demo-app
else
    echo -e "${GREEN}✅ Namespace successfully removed${NC}"
fi

echo ""
echo -e "${GREEN}🎉 Cleanup completed successfully!${NC}"
echo ""
echo "All resources deployed from the hub cluster have been removed from the spoke cluster."

if [ ! -z "$EXTERNAL_IP" ] && [ "$EXTERNAL_IP" != "null" ]; then
    echo "External IP $EXTERNAL_IP has been released and is no longer accessible."
fi