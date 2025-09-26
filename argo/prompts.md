There is a ArgoCD admin or hub AKS cluster.   This manages deployment for all spoke AKS clusters.  Azure RBAC for Kubernetes authorization is enabled.  

when creating spoke AKS clusters, there is a need to create role bindings which will be using ArgoCD hub managed identity. 

For this newly created AKS cluster,  ArgoCD hub cluster should fetch kubeconfig and authenticate to that cluster.  What's the process?   Any role assignment can be provided at RG level where spoke clusters are created. 

Cluster creation is done with Terraform.   

Provide a good pattern along with step by step instruction.  Any other EntraID integration can be enabled for a seamless steps or process.