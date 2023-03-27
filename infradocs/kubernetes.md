## Supported Machines

All the k8s clusters running on v1.21 or above should support Middleware K8s agent.

## Current Technical Approach

We mainly run a Daemonset to run our Middleware agent containers inside your k8s cluster.

We add  components like ClusterRole, ClusterRoleBinding, ServiceAccount, Role, Rolebinding for setting up the permissions for our Daemonset pods.

We also create a k8s service, in case any components need to connect with the Middleware agent with a permanent URL. (Ex. Our language based APMs)

We add a Cronjob to rollout our Daemonset on daily basis, so that it can pull docker images with latest updates, if any.


## Roadmap

1. Currently, we have mainly used our Middleware agent with EKS. Based on the MW agent pre-requisites it should also work well on Azure Kubernetes Services, GKE and other popular platforms as well. But, we will be adding a tested list with version support details.

