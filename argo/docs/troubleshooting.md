# Troubleshooting Guide

This guide covers common issues and solutions for the ArgoCD Hub-Spoke AKS architecture.

## Authentication Issues

### Problem: Hub cluster cannot authenticate to spoke clusters

**Symptoms:**
- ArgoCD shows clusters as "Unknown" status
- Application sync fails with authentication errors
- Logs show "unable to authenticate to cluster"

**Diagnosis:**
```bash
# Check hub identity assignments
az role assignment list --assignee $HUB_IDENTITY_PRINCIPAL_ID --all

# Verify kubelogin configuration
kubectl config view --raw | grep -A 10 -B 10 kubelogin

# Test manual authentication
az aks get-credentials --resource-group $SPOKE_RG --name $SPOKE_CLUSTER
kubectl get nodes
```

**Solutions:**

1. **Missing RBAC assignments:**
```bash
# Add missing role assignment
az role assignment create \
  --assignee $HUB_IDENTITY_PRINCIPAL_ID \
  --role "Azure Kubernetes Service Cluster User Role" \
  --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$SPOKE_RG"
```

2. **Kubelogin not configured:**
```bash
# Install kubelogin
az aks install-cli

# Convert kubeconfig to use kubelogin
kubelogin convert-kubeconfig -l azurecli
```

3. **Managed Identity not propagated:**
```bash
# Check identity status
az identity show --ids $HUB_IDENTITY_ID

# Wait for AAD propagation (can take 10-15 minutes)
# Retry authentication after waiting
```

### Problem: Azure RBAC authorization failures

**Symptoms:**
- "User does not have access to the resource" errors
- RBAC denials in audit logs
- ArgoCD cannot list/create resources

**Diagnosis:**
```bash
# Check effective permissions
kubectl auth can-i "*" "*" --as="$HUB_IDENTITY_CLIENT_ID"

# Review Azure RBAC assignments
az role assignment list --assignee $HUB_IDENTITY_PRINCIPAL_ID --include-inherited

# Check Kubernetes RBAC
kubectl describe clusterrolebinding argocd-application-controller
```

**Solutions:**

1. **Add required Azure RBAC:**
```bash
# For cluster-level access
az role assignment create \
  --assignee $HUB_IDENTITY_PRINCIPAL_ID \
  --role "Azure Kubernetes Service RBAC Admin" \
  --scope $SPOKE_CLUSTER_ID
```

2. **Fix Kubernetes RBAC:**
```bash
# Verify ClusterRoleBinding exists
kubectl get clusterrolebinding argocd-application-controller

# Recreate if missing
kubectl create clusterrolebinding argocd-application-controller \
  --clusterrole=cluster-admin \
  --serviceaccount=argocd:argocd-application-controller
```

## Network Connectivity Issues

### Problem: Hub cannot reach spoke cluster API servers

**Symptoms:**
- Network timeouts when connecting to spoke clusters
- "connection refused" errors
- Intermittent connectivity

**Diagnosis:**
```bash
# Test network connectivity from hub
kubectl run network-test --image=busybox --rm -it -- \
  nslookup $SPOKE_CLUSTER_FQDN

# Check private endpoint configuration
az network private-endpoint list --resource-group $SPOKE_RG

# Verify DNS resolution
dig $SPOKE_CLUSTER_FQDN
```

**Solutions:**

1. **Configure authorized IP ranges:**
```bash
# Get hub cluster outbound IPs
HUB_OUTBOUND_IPS=$(az aks show -g $HUB_RG -n $HUB_CLUSTER \
  --query networkProfile.loadBalancerProfile.effectiveOutboundIPs[].id -o tsv)

# Update spoke cluster authorized ranges
az aks update -g $SPOKE_RG -n $SPOKE_CLUSTER \
  --api-server-authorized-ip-ranges $HUB_OUTBOUND_IP_RANGE
```

2. **Fix private DNS configuration:**
```bash
# Link private DNS zone to hub cluster VNet
az network private-dns link vnet create \
  --resource-group $SPOKE_RG \
  --zone-name "privatelink.eastus.azmk8s.io" \
  --name hub-cluster-link \
  --virtual-network $HUB_VNET_ID \
  --registration-enabled false
```

## ArgoCD Specific Issues

### Problem: Applications stuck in "Progressing" state

**Symptoms:**
- Applications never reach "Healthy" status
- Sync operation appears successful but resources not created
- Resource hooks failing

**Diagnosis:**
```bash
# Check application status
kubectl get applications -n argocd
kubectl describe application $APP_NAME -n argocd

# Review ArgoCD logs
kubectl logs deployment/argocd-application-controller -n argocd

# Check target cluster resources
kubectl get all -n $TARGET_NAMESPACE --context=$SPOKE_CLUSTER_CONTEXT
```

**Solutions:**

1. **Resource creation permissions:**
```bash
# Verify service account permissions in target cluster
kubectl auth can-i create deployment --as=system:serviceaccount:argocd-managed:argocd-manager

# Add missing RBAC
kubectl create rolebinding argocd-manager-admin \
  --clusterrole=admin \
  --serviceaccount=argocd-managed:argocd-manager \
  -n $TARGET_NAMESPACE
```

2. **Resource quota issues:**
```bash
# Check resource quotas
kubectl describe resourcequota -n $TARGET_NAMESPACE

# Increase quotas if needed
kubectl patch resourcequota $QUOTA_NAME -n $TARGET_NAMESPACE \
  --type='json' -p='[{"op": "replace", "path": "/spec/hard/requests.memory", "value": "16Gi"}]'
```

### Problem: ArgoCD UI not accessible

**Symptoms:**
- Cannot access ArgoCD web interface
- Connection timeouts or SSL errors
- Ingress not working

**Diagnosis:**
```bash
# Check ArgoCD server status
kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server

# Verify ingress configuration
kubectl get ingress -n argocd
kubectl describe ingress argocd-server-ingress -n argocd

# Check service endpoints
kubectl get endpoints -n argocd
```

**Solutions:**

1. **Port forward for temporary access:**
```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Access via https://localhost:8080
```

2. **Fix ingress issues:**
```bash
# Check ingress controller
kubectl get pods -n ingress-nginx

# Verify SSL certificate
kubectl get certificate -n argocd
kubectl describe certificate argocd-server-tls -n argocd

# Check DNS resolution
nslookup argocd.your-domain.com
```

## Terraform Issues

### Problem: Terraform state conflicts

**Symptoms:**
- "Resource already exists" errors
- State drift detected
- Unable to modify resources

**Diagnosis:**
```bash
# Check Terraform state
terraform state list
terraform state show $RESOURCE_NAME

# Compare with actual Azure resources
az aks list --output table
```

**Solutions:**

1. **Import existing resources:**
```bash
# Import resource into state
terraform import module.hub_cluster.azurerm_kubernetes_cluster.hub_cluster \
  /subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG/providers/Microsoft.ContainerService/managedClusters/$CLUSTER_NAME
```

2. **Refresh and reconcile state:**
```bash
# Refresh state from Azure
terraform refresh -var-file="hub.tfvars"

# Plan and apply to fix drift
terraform plan -var-file="hub.tfvars"
terraform apply -var-file="hub.tfvars"
```

### Problem: Azure provider authentication failures

**Symptoms:**
- "authentication failed" during terraform operations
- "subscription not found" errors
- Permission denied errors

**Solutions:**

1. **Re-authenticate Azure CLI:**
```bash
az logout
az login
az account set --subscription $SUBSCRIPTION_ID
```

2. **Use service principal authentication:**
```bash
export ARM_CLIENT_ID="service-principal-client-id"
export ARM_CLIENT_SECRET="service-principal-secret"
export ARM_SUBSCRIPTION_ID="subscription-id"
export ARM_TENANT_ID="tenant-id"
```

## Performance Issues

### Problem: ArgoCD sync operations are slow

**Symptoms:**
- Long sync times for applications
- Timeout errors during sync
- High resource usage on ArgoCD components

**Diagnosis:**
```bash
# Check ArgoCD resource usage
kubectl top pods -n argocd

# Review sync performance metrics
kubectl logs deployment/argocd-application-controller -n argocd | grep "took"

# Check cluster resource availability
kubectl describe nodes | grep -A 5 "Allocated resources"
```

**Solutions:**

1. **Scale ArgoCD components:**
```bash
# Increase replicas
kubectl scale deployment/argocd-application-controller --replicas=3 -n argocd
kubectl scale deployment/argocd-repo-server --replicas=2 -n argocd

# Increase resource limits
kubectl patch deployment argocd-application-controller -n argocd --type='json' \
  -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/resources/limits/memory", "value": "2Gi"}]'
```

2. **Optimize repository scanning:**
```yaml
# Update ArgoCD configuration
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cmd-params-cm
  namespace: argocd
data:
  # Increase timeout
  controller.repo.server.timeout.seconds: "300"
  # Reduce sync frequency
  controller.self.heal.timeout.seconds: "30"
  # Enable concurrent processing
  controller.status.processors: "20"
  controller.operation.processors: "10"
```

## Monitoring and Alerting Issues

### Problem: Missing metrics or logs

**Symptoms:**
- No data in Azure Monitor dashboards
- ArgoCD metrics not available
- Missing audit logs

**Diagnosis:**
```bash
# Check Log Analytics configuration
az monitor log-analytics workspace show --resource-group $RG --workspace-name $WORKSPACE

# Verify data ingestion
az monitor log-analytics query \
  --workspace $WORKSPACE_ID \
  --analytics-query "Heartbeat | top 10 by TimeGenerated desc"

# Check ServiceMonitor configuration
kubectl get servicemonitor -n argocd
```

**Solutions:**

1. **Fix Log Analytics integration:**
```bash
# Enable Container Insights
az aks enable-addons --resource-group $RG --name $CLUSTER --addons monitoring \
  --workspace-resource-id $WORKSPACE_ID
```

2. **Configure ArgoCD metrics:**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: argocd-metrics
  namespace: argocd
  labels:
    app.kubernetes.io/component: metrics
spec:
  ports:
  - name: metrics
    port: 8082
    protocol: TCP
    targetPort: 8082
  selector:
    app.kubernetes.io/name: argocd-application-controller
```

## Recovery Procedures

### Complete Hub Cluster Recovery

1. **Restore from backup:**
```bash
# Restore ArgoCD configuration
kubectl apply -f argocd-backup.yaml

# Reimport cluster secrets
kubectl apply -f cluster-secrets/
```

2. **Recreate spoke cluster connections:**
```bash
# Re-run Terraform to recreate RBAC
cd terraform/environments/hub
terraform apply -var-file="hub.tfvars" -auto-approve

# Verify cluster connectivity
argocd cluster list
```

### Spoke Cluster Recovery

1. **Restore cluster access:**
```bash
# Re-create role bindings
kubectl apply -f kubernetes/rbac/spoke-cluster-rbac.yaml

# Verify ArgoCD can connect
kubectl get secrets -n argocd -l argocd.argoproj.io/secret-type=cluster
```

## Getting Help

### Log Collection for Support

```bash
#!/bin/bash
# Collect diagnostic information

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
DIAG_DIR="aks-diag-$TIMESTAMP"
mkdir -p $DIAG_DIR

# Cluster information
kubectl cluster-info > $DIAG_DIR/cluster-info.txt
kubectl get nodes -o wide > $DIAG_DIR/nodes.txt
kubectl get pods --all-namespaces > $DIAG_DIR/all-pods.txt

# ArgoCD specific
kubectl get applications,projects -n argocd -o yaml > $DIAG_DIR/argocd-resources.yaml
kubectl logs deployment/argocd-application-controller -n argocd > $DIAG_DIR/argocd-controller.log

# Azure information  
az aks show -g $HUB_RG -n $HUB_CLUSTER > $DIAG_DIR/aks-config.json
az role assignment list --assignee $HUB_IDENTITY_PRINCIPAL_ID > $DIAG_DIR/rbac-assignments.json

# Package for support
tar -czf aks-diagnostics-$TIMESTAMP.tar.gz $DIAG_DIR/
echo "Diagnostics collected in aks-diagnostics-$TIMESTAMP.tar.gz"
```

### Community Resources

- **ArgoCD Documentation**: https://argo-cd.readthedocs.io/
- **AKS Troubleshooting**: https://docs.microsoft.com/en-us/azure/aks/troubleshooting
- **Azure RBAC for Kubernetes**: https://docs.microsoft.com/en-us/azure/aks/azure-rbac
- **GitHub Issues**: Use the repository issue tracker for bugs and feature requests

### Professional Support

For production environments, consider:
- Azure Support Plans
- ArgoCD Enterprise Support (if applicable)
- Professional Services for architecture review