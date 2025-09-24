# Spoke Cluster Bootstrap Configuration

This directory contains Kustomize-based configurations for bootstrapping spoke clusters in the ArgoCD Hub-Spoke architecture.

## Directory Structure

```
spoke-bootstrap/
├── base/                    # Base configurations shared by all environments
│   ├── kustomization.yaml  # Base kustomize configuration
│   ├── namespace.yaml      # argocd-managed namespace
│   ├── serviceaccount.yaml # ArgoCD manager service account
│   └── rbac.yaml          # RBAC permissions for ArgoCD
└── overlays/              # Environment-specific customizations
    ├── dev/               # Development environment
    ├── staging/           # Staging environment
    └── prod/              # Production environment
```

## How It Works

1. **Base Configuration**: Common resources that all spoke clusters need
   - `argocd-managed` namespace
   - `argocd-manager` service account with Azure Workload Identity annotation
   - ClusterRole and ClusterRoleBinding for ArgoCD permissions

2. **Environment Overlays**: Environment-specific customizations
   - Patches to inject the actual Hub Identity Client ID
   - Environment-specific labels and annotations
   - Production-specific security configurations

## Usage with ArgoCD ApplicationSet

The ArgoCD ApplicationSet in the hub cluster will automatically:

1. Detect spoke clusters labeled with `environment: spoke`
2. Deploy the appropriate overlay based on the cluster's environment label
3. Replace `${HUB_IDENTITY_CLIENT_ID}` with the actual hub identity client ID

## Example ApplicationSet Template

```yaml
spec:
  source:
    repoURL: https://github.com/srinman/aks-cicd
    path: argo/spoke-bootstrap/overlays/{{metadata.labels.environment}}
    targetRevision: main
```

## Manual Testing

You can test the configurations locally:

```bash
# Test dev overlay
kustomize build overlays/dev

# Test staging overlay  
kustomize build overlays/staging

# Test prod overlay
kustomize build overlays/prod
```

## Environment Variables

The overlays expect the following environment variable to be substituted:

- `${HUB_IDENTITY_CLIENT_ID}`: The client ID of the hub cluster's managed identity

ArgoCD will automatically substitute this when deploying to spoke clusters.