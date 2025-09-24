#!/bin/bash
set -e

# Hub-to-Spoke Verification Script
# This script verifies the deployment and tests the application

SPOKE_CLUSTER_NAME=${SPOKE_CLUSTER_NAME:-""}
SPOKE_RG=${SPOKE_RG:-""}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}🔍 Hub-to-Spoke Deployment Verification${NC}"
echo "======================================="

# Validate parameters
if [ -z "$SPOKE_CLUSTER_NAME" ] || [ -z "$SPOKE_RG" ]; then
    echo -e "${RED}❌ Error: Required parameters not set${NC}"
    echo "Please set: SPOKE_CLUSTER_NAME and SPOKE_RG"
    exit 1
fi

echo "Verifying deployment on: $SPOKE_CLUSTER_NAME"
echo ""

# Connect to spoke cluster
echo -e "${YELLOW}Connecting to spoke cluster...${NC}"
az aks get-credentials --resource-group $SPOKE_RG --name $SPOKE_CLUSTER_NAME --overwrite-existing > /dev/null

# Check if demo-app namespace exists
if ! kubectl get namespace demo-app > /dev/null 2>&1; then
    echo -e "${RED}❌ demo-app namespace not found${NC}"
    echo "Please run the deployment script first"
    exit 1
fi

echo -e "${GREEN}✅ Connected to spoke cluster${NC}"

# Check namespace
echo ""
echo -e "${BLUE}1. Namespace Status${NC}"
echo "==================="
kubectl get namespace demo-app -o wide

# Check deployment
echo ""
echo -e "${BLUE}2. Deployment Status${NC}"
echo "===================="
kubectl get deployment nginx-demo -n demo-app -o wide

READY_REPLICAS=$(kubectl get deployment nginx-demo -n demo-app -o jsonpath='{.status.readyReplicas}')
DESIRED_REPLICAS=$(kubectl get deployment nginx-demo -n demo-app -o jsonpath='{.spec.replicas}')

if [ "$READY_REPLICAS" = "$DESIRED_REPLICAS" ]; then
    echo -e "${GREEN}✅ Deployment is healthy ($READY_REPLICAS/$DESIRED_REPLICAS replicas ready)${NC}"
else
    echo -e "${YELLOW}⚠️  Deployment may still be starting ($READY_REPLICAS/$DESIRED_REPLICAS replicas ready)${NC}"
fi

# Check pods
echo ""
echo -e "${BLUE}3. Pod Status${NC}"
echo "============="
kubectl get pods -n demo-app -o wide

# Count running pods
RUNNING_PODS=$(kubectl get pods -n demo-app --field-selector=status.phase=Running --no-headers | wc -l)
echo "Running pods: $RUNNING_PODS"

# Check service
echo ""
echo -e "${BLUE}4. Service Status${NC}"
echo "================="
kubectl get service nginx-demo-service -n demo-app -o wide

# Get external IP and test
EXTERNAL_IP=$(kubectl get service nginx-demo-service -n demo-app -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)

echo ""
echo -e "${BLUE}5. External Access Test${NC}"
echo "======================="

if [ ! -z "$EXTERNAL_IP" ] && [ "$EXTERNAL_IP" != "null" ]; then
    echo -e "${GREEN}External IP: $EXTERNAL_IP${NC}"
    
    # Test HTTP connectivity
    echo "Testing HTTP connectivity..."
    if curl -s --connect-timeout 10 --max-time 10 "http://$EXTERNAL_IP" > /dev/null; then
        echo -e "${GREEN}✅ Application is accessible!${NC}"
        
        # Get response headers
        echo ""
        echo "Response headers:"
        curl -I "http://$EXTERNAL_IP" 2>/dev/null | head -5
        
        # Quick performance test
        echo ""
        echo "Response time test:"
        for i in {1..3}; do
            RESPONSE_TIME=$(curl -s -w "%{time_total}" "http://$EXTERNAL_IP" -o /dev/null)
            echo "  Request $i: ${RESPONSE_TIME}s"
        done
        
    else
        echo -e "${YELLOW}⚠️  Application is not yet accessible (may still be starting)${NC}"
        
        # Check service events
        echo ""
        echo "Service events:"
        kubectl describe service nginx-demo-service -n demo-app | tail -10
    fi
else
    echo -e "${YELLOW}⚠️  External IP not yet assigned${NC}"
    echo ""
    echo "Service details:"
    kubectl describe service nginx-demo-service -n demo-app | grep -A5 -B5 "LoadBalancer"
fi

# Check deployment labels to confirm source
echo ""
echo -e "${BLUE}6. Deployment Metadata${NC}"
echo "======================"
echo "Labels:"
kubectl get deployment nginx-demo -n demo-app -o jsonpath='{.metadata.labels}' | jq . 2>/dev/null || kubectl get deployment nginx-demo -n demo-app -o jsonpath='{.metadata.labels}'

echo ""
echo "Deployment environment variables:"
kubectl get deployment nginx-demo -n demo-app -o jsonpath='{.spec.template.spec.containers[0].env}' | jq . 2>/dev/null || kubectl get deployment nginx-demo -n demo-app -o jsonpath='{.spec.template.spec.containers[0].env}'

# Resource usage
echo ""
echo -e "${BLUE}7. Resource Usage${NC}"
echo "================="
echo "Pod resource requests/limits:"
kubectl describe deployment nginx-demo -n demo-app | grep -A2 -B2 "Limits\|Requests"

# Events
echo ""
echo -e "${BLUE}8. Recent Events${NC}"
echo "================"
kubectl get events -n demo-app --sort-by='.lastTimestamp' | tail -10

# Summary
echo ""
echo -e "${BLUE}📊 Verification Summary${NC}"
echo "======================"
echo "Namespace: ✅ demo-app exists"
echo "Deployment: $([ "$READY_REPLICAS" = "$DESIRED_REPLICAS" ] && echo "✅ Healthy" || echo "⚠️  Starting")"
echo "Pods: ✅ $RUNNING_PODS pods running"
echo "Service: $([ ! -z "$EXTERNAL_IP" ] && [ "$EXTERNAL_IP" != "null" ] && echo "✅ External IP assigned" || echo "⚠️  External IP pending")"
echo "Access: $([ ! -z "$EXTERNAL_IP" ] && [ "$EXTERNAL_IP" != "null" ] && curl -s --connect-timeout 5 "http://$EXTERNAL_IP" > /dev/null && echo "✅ Application accessible" || echo "⚠️  Not yet accessible")"

echo ""
echo -e "${GREEN}🎉 Verification completed!${NC}"

if [ ! -z "$EXTERNAL_IP" ] && [ "$EXTERNAL_IP" != "null" ]; then
    echo ""
    echo "🌐 Access your application at: http://$EXTERNAL_IP"
fi