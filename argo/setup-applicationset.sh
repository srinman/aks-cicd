#!/bin/bash
set -e

# Setup script for ArgoCD ApplicationSet with spoke cluster bootstrap
# This script configures the ApplicationSet to use your hub identity client ID

echo "Setting up ArgoCD ApplicationSet for spoke cluster automation..."

# Check if we're in the hub cluster context
CURRENT_CONTEXT=$(kubectl config current-context)
if [[ "$CURRENT_CONTEXT" != *"hub"* ]]; then
    echo "Warning: Current context '$CURRENT_CONTEXT' doesn't appear to be the hub cluster"
    echo "Make sure you're connected to the hub cluster before running this script"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Get the hub identity client ID from environment or prompt
if [ -z "$HUB_IDENTITY_CLIENT_ID" ]; then
    echo "Hub Identity Client ID not found in environment variable."
    read -p "Enter your Hub Identity Client ID: " HUB_IDENTITY_CLIENT_ID
    if [ -z "$HUB_IDENTITY_CLIENT_ID" ]; then
        echo "Error: Hub Identity Client ID is required"
        exit 1
    fi
fi

echo "Using Hub Identity Client ID: $HUB_IDENTITY_CLIENT_ID"

# Create the ApplicationSet with proper configuration
cat > spoke-cluster-applicationset.yaml << EOF
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: spoke-cluster-bootstrap
  namespace: argocd
  labels:
    app.kubernetes.io/name: spoke-cluster-bootstrap
    app.kubernetes.io/managed-by: argocd
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
        environment: '{{metadata.labels.environment}}'
        cluster-type: spoke
        managed-by: applicationset
    spec:
      project: default
      source:
        repoURL: https://github.com/srinman/aks-cicd
        path: argo/spoke-bootstrap/overlays/{{metadata.labels.environment}}
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
        retry:
          limit: 5
          backoff:
            duration: 5s
            factor: 2
            maxDuration: 3m
EOF

echo "ApplicationSet configuration created: spoke-cluster-applicationset.yaml"

# Apply the ApplicationSet
kubectl apply -f spoke-cluster-applicationset.yaml

echo "✅ ApplicationSet 'spoke-cluster-bootstrap' created successfully!"
echo ""
echo "Next steps:"
echo "1. Add spoke clusters to ArgoCD with proper labels:"
echo "   kubectl label secret <cluster-secret> environment=spoke -n argocd"
echo "2. Label the cluster secret with the environment (dev/staging/prod):"
echo "   kubectl label secret <cluster-secret> environment=dev -n argocd"
echo ""
echo "The ApplicationSet will automatically deploy bootstrap configurations to labeled spoke clusters."

# Verify the ApplicationSet
echo ""
echo "Verifying ApplicationSet status..."
kubectl get applicationset spoke-cluster-bootstrap -n argocd -o wide

echo ""
echo "To view ApplicationSet logs:"
echo "kubectl logs -n argocd deployment/argocd-applicationset-controller"