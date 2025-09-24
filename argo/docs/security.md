# Security Considerations for AKS Hub-Spoke Architecture

This document outlines security best practices and considerations for the ArgoCD Hub-Spoke AKS implementation.

## Architecture Security Overview

### Trust Model
- **Hub Cluster**: Trusted orchestration layer with elevated privileges
- **Spoke Clusters**: Workload isolation with minimal cross-cluster communication
- **Identity Boundary**: Azure RBAC + Kubernetes RBAC dual-layer authorization
- **Network Boundary**: Azure networking with optional private endpoints

## Identity and Access Management

### Azure Active Directory Integration

#### Service Principal vs Managed Identity
✅ **Recommended**: User-Assigned Managed Identity
- Automatic credential rotation
- No secret management overhead  
- Auditable through Azure AD logs
- Scoped to specific resources

❌ **Avoid**: Service Principal with client secrets
- Manual secret rotation required
- Secret sprawl risk
- Additional key management complexity

#### Azure RBAC Configuration

**Hub Cluster Identity Permissions**:
```
Custom Role: "ArgoCD-Hub-Operator"
Actions:
- Microsoft.ContainerService/managedClusters/read
- Microsoft.ContainerService/managedClusters/listClusterUserCredential/action
- Microsoft.Resources/resourceGroups/read
- Microsoft.ManagedIdentity/userAssignedIdentities/read
```

**Spoke Resource Group Permissions**:
```
- "Azure Kubernetes Service Cluster User Role"
- "Reader" (for resource discovery)
```

### Kubernetes RBAC Strategy

#### Principle of Least Privilege
- ArgoCD service accounts have minimal required permissions
- Namespace-scoped roles where possible
- Regular permission audits

#### Role Binding Patterns
```yaml
# Hub cluster - ArgoCD application controller
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: argocd-application-controller
rules:
- apiGroups: ["*"]
  resources: ["*"]  
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]

# Spoke cluster - Restricted management role
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole  
metadata:
  name: argocd-manager
rules:
- apiGroups: ["apps", ""]
  resources: ["deployments", "services", "configmaps"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: [""]
  resources: ["namespaces"]
  verbs: ["get", "list", "watch"]
  resourceNames: ["argocd-managed", "default"]
```

## Network Security

### Cluster Network Isolation

#### Virtual Network Configuration
- **Hub Cluster**: Dedicated subnet with monitoring/management traffic
- **Spoke Clusters**: Isolated subnets per environment/tenant
- **Network Policies**: Restrict cross-namespace communication

#### Private AKS Clusters (Production Recommendation)
```hcl
resource "azurerm_kubernetes_cluster" "spoke_cluster" {
  private_cluster_enabled = true
  private_dns_zone_id     = azurerm_private_dns_zone.aks.id
  
  api_server_access_profile {
    authorized_ip_ranges = [var.hub_cluster_subnet_cidr]
  }
}
```

#### Network Security Groups
```hcl
resource "azurerm_network_security_rule" "allow_hub_to_spoke" {
  name                       = "AllowHubManagement"
  priority                   = 100
  direction                  = "Inbound" 
  access                     = "Allow"
  protocol                   = "Tcp"
  source_port_range          = "*"
  destination_port_range     = "443"
  source_address_prefix      = var.hub_subnet_cidr
  destination_address_prefix = "*"
}
```

### Service Mesh Integration (Optional)
- Istio/Linkerd for enhanced network security
- mTLS for service-to-service communication
- Fine-grained traffic policies

## Secret Management

### Azure Key Vault Integration

#### Cluster Secret Management
```yaml
apiVersion: v1
kind: SecretProviderClass
metadata:
  name: cluster-secrets
spec:
  provider: azure
  parameters:
    usePodIdentity: "false"
    useVMManagedIdentity: "true"
    userAssignedIdentityID: "hub-cluster-identity-client-id"
    keyvaultName: "aks-hub-keyvault"
    objects: |
      array:
        - |
          objectName: spoke-cluster-config
          objectType: secret
          objectVersion: ""
```

#### Workload Identity Pattern
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: workload-identity-sa
  annotations:
    azure.workload.identity/client-id: "workload-client-id"
---
apiVersion: azure.workload.identity/v1beta1
kind: AzureIdentityBinding
metadata:
  name: workload-identity-binding
spec:
  azureIdentity: workload-identity
  selector: workload-identity-sa
```

### ArgoCD Secret Management
- Repository credentials stored in Azure Key Vault
- Cluster connection secrets auto-generated
- Application secrets via External Secrets Operator

## Audit and Compliance

### Azure Activity Logs
```bash
# Enable diagnostic settings for all AKS clusters
az monitor diagnostic-settings create \
  --resource "/subscriptions/{subscription-id}/resourceGroups/{rg}/providers/Microsoft.ContainerService/managedClusters/{cluster}" \
  --name "AKSAuditLogs" \
  --logs '[{"category":"kube-audit","enabled":true},{"category":"kube-apiserver","enabled":true}]' \
  --workspace "/subscriptions/{subscription-id}/resourceGroups/{rg}/providers/Microsoft.OperationalInsights/workspaces/{workspace}"
```

### Kubernetes Audit Policy
```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
- level: Metadata
  namespaces: ["argocd", "argocd-managed"]
  verbs: ["create", "update", "patch", "delete"]
- level: RequestResponse
  resources:
  - group: "rbac.authorization.k8s.io"
    resources: ["clusterroles", "clusterrolebindings", "roles", "rolebindings"]
```

### Compliance Standards
- **CIS Kubernetes Benchmark**: Regular assessments
- **Azure Security Benchmark**: Built-in policy compliance
- **SOC 2 Type II**: Audit trail requirements
- **GDPR/Data Residency**: Regional deployment constraints

## Runtime Security

### Pod Security Standards
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: argocd-managed
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

### Container Security Scanning
```yaml
# Azure Defender for Containers integration
apiVersion: v1
kind: ConfigMap
metadata:
  name: container-azm-ms-agentconfig
  namespace: kube-system
data:
  schema-version: v1
  config-version: ver1
  log-data-collection-settings: |-
    [log_collection_settings]
    [log_collection_settings.stdout]
      enabled = true
    [log_collection_settings.stderr]
      enabled = true
    [log_collection_settings.env_var]
      enabled = true
```

### Resource Quotas and Limits
```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: argocd-managed-quota
  namespace: argocd-managed
spec:
  hard:
    requests.cpu: "4"
    requests.memory: 8Gi
    limits.cpu: "8" 
    limits.memory: 16Gi
    persistentvolumeclaims: "10"
```

## Incident Response

### Security Event Detection
1. **Azure Sentinel Integration**: SIEM for threat detection
2. **Falco Deployment**: Runtime security monitoring
3. **Custom Alert Rules**: ArgoCD-specific security events

### Breach Response Procedures
1. **Immediate Actions**:
   - Isolate affected cluster
   - Rotate service account tokens
   - Review audit logs
   
2. **Investigation**:
   - Correlate Azure AD and Kubernetes logs
   - Analyze network traffic patterns
   - Review recent deployments

3. **Recovery**:
   - Restore from known good state
   - Update security policies
   - Implement additional controls

## Regular Security Maintenance

### Automated Security Tasks
```bash
#!/bin/bash
# Weekly security maintenance script

# Rotate ArgoCD admin password
kubectl patch secret argocd-secret -n argocd --type='json' -p='[{"op": "replace", "path": "/data/admin.password", "value": "'$(openssl rand -base64 32 | base64 -w 0)'"}]'

# Update cluster certificates
az aks rotate-certs --resource-group $RG --name $CLUSTER

# Scan for vulnerable images
trivy image --severity HIGH,CRITICAL $(kubectl get pods --all-namespaces -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}' | sort -u)
```

### Quarterly Security Reviews
- [ ] Review Azure RBAC assignments
- [ ] Audit Kubernetes RBAC policies  
- [ ] Update base container images
- [ ] Penetration testing
- [ ] Policy compliance assessment
- [ ] Disaster recovery testing

## Security Monitoring Dashboard

### Key Metrics to Monitor
```kusto
// Failed authentication attempts
AzureDiagnostics
| where Category == "kube-audit"
| where verb_s == "create" and requestURI_s contains "authentication"
| where responseStatus_code_d >= 400
| summarize count() by bin(TimeGenerated, 1h), user_username_s

// Suspicious privilege escalations
AzureDiagnostics  
| where Category == "kube-audit"
| where verb_s in ("create", "update")
| where requestURI_s contains "rolebinding" or requestURI_s contains "clusterrolebinding"
| project TimeGenerated, user_username_s, verb_s, requestURI_s

// ArgoCD application deployment failures
ContainerLog
| where ContainerName == "argocd-application-controller"
| where LogEntry contains "Failed to sync application"
| summarize count() by bin(TimeGenerated, 15m)
```

## Zero-Trust Implementation

### Verification at Every Layer
1. **Identity**: Azure AD authentication + MFA
2. **Device**: Conditional access policies
3. **Network**: Private endpoints + network policies
4. **Application**: Pod security contexts + admission controllers
5. **Data**: Encryption at rest + in transit

### Continuous Verification
- Real-time risk assessment
- Adaptive access controls
- Behavioral analytics
- Automated response actions

This security framework ensures defense-in-depth protection while maintaining operational efficiency for the hub-spoke AKS architecture.