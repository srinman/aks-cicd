#!/bin/bash
set -e

# Script to add spoke clusters to ArgoCD with proper labels for ApplicationSet automation
# This script adds a spoke cluster to ArgoCD and labels it for automatic bootstrap

CLUSTER_NAME=""
RESOURCE_GROUP=""
ENVIRONMENT=""
HUB_IDENTITY_CLIENT_ID=""

usage() {
    echo "Usage: $0 -n <cluster-name> -g <resource-group> -e <environment> [-i <hub-identity-client-id>]"
    echo ""
    echo "Options:"
    echo "  -n, --cluster-name         Name of the spoke cluster"
    echo "  -g, --resource-group       Resource group of the spoke cluster"
    echo "  -e, --environment          Environment (dev/staging/prod)"
    echo "  -i, --hub-identity         Hub identity client ID (optional, uses env var if not provided)"
    echo "  -h, --help                 Show this help message"
    echo ""
    echo "Example:"
    echo "  $0 -n myorg-dev-aks -g myorg-dev-rg -e dev"
    echo ""
    echo "Environment variables:"
    echo "  HUB_IDENTITY_CLIENT_ID     Hub cluster managed identity client ID"
}

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
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Validate required parameters
if [ -z "$CLUSTER_NAME" ] || [ -z "$RESOURCE_GROUP" ] || [ -z "$ENVIRONMENT" ]; then
    echo "Error: Missing required parameters"
    usage
    exit 1
fi

# Validate environment
if [[ ! "$ENVIRONMENT" =~ ^(dev|staging|prod)$ ]]; then
    echo "Error: Environment must be one of: dev, staging, prod"
    exit 1
fi

# Get hub identity client ID from environment if not provided
if [ -z "$HUB_IDENTITY_CLIENT_ID" ]; then
    if [ -z "${HUB_IDENTITY_CLIENT_ID:-}" ]; then
        echo "Error: Hub Identity Client ID not provided via parameter or environment variable"
        echo "Set HUB_IDENTITY_CLIENT_ID environment variable or use -i parameter"
        exit 1
    fi
    HUB_IDENTITY_CLIENT_ID="$HUB_IDENTITY_CLIENT_ID"
fi

echo "Adding spoke cluster to ArgoCD:"
echo "  Cluster Name: $CLUSTER_NAME"
echo "  Resource Group: $RESOURCE_GROUP"
echo "  Environment: $ENVIRONMENT"
echo "  Hub Identity: $HUB_IDENTITY_CLIENT_ID"
echo ""

# Check if we're in the hub cluster context
CURRENT_CONTEXT=$(kubectl config current-context)
if [[ "$CURRENT_CONTEXT" != *"hub"* ]]; then
    echo "Warning: Current context '$CURRENT_CONTEXT' doesn't appear to be the hub cluster"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Get cluster details from Azure
echo "Getting cluster details from Azure..."

# Get admin credentials for ArgoCD to use
# Store current kubeconfig context to restore later
ORIGINAL_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "")

# Get admin kubeconfig (not user config which requires kubelogin)
az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" --admin --overwrite-existing

# Extract server and CA certificate from the admin context
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

# Create cluster secret for ArgoCD
SECRET_NAME="${CLUSTER_NAME}-secret"
echo "Creating ArgoCD cluster secret: $SECRET_NAME"

# Extract client certificate and key from admin kubeconfig  
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

# Clean up temporary file
rm -f "${SECRET_NAME}.yaml"