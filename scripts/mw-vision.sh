#!/bin/sh
curl -s --location --request POST https://app.middleware.io/api/v1/agent/tracking/$MW_API_KEY \
--header 'Content-Type: application/json' \
--data-raw '{
    "status": "tried",
    "metadata": {
        "script": "kubernetes-auto-instrument",
        "status": "ok",
        "message": "agent installed"
    }
}' > /dev/null

# Home for local configs
MW_KUBE_AGENT_HOME_GO=/usr/local/bin/mw-agent-kube-go
export MW_KUBE_AGENT_HOME_GO

# Helm chart version
MW_DEFAULT_HELM_VERSION=0.2.62
if [ "${MW_HELM_VERSION}" = "" ]; then 
  MW_HELM_VERSION=$MW_DEFAULT_HELM_VERSION
  export MW_HELM_VERSION
fi

# Target Namespace - For Middleware Agent Workloads
MW_DEFAULT_NAMESPACE=mw-vision
export MW_DEFAULT_NAMESPACE

if [ "${MW_NAMESPACE}" = "" ]; then 
  MW_NAMESPACE=$MW_DEFAULT_NAMESPACE
  export MW_NAMESPACE
fi

# Default rollout time rule
# MW_DEFAULT_ROLLOUT_RESTART_RULE=0 8 * * *
# export MW_DEFAULT_ROLLOUT_RESTART_RULE

# if [ "${MW_ROLLOUT_RESTART_RULE}" = "" ]; then 
#   MW_ROLLOUT_RESTART_RULE=$MW_DEFAULT_ROLLOUT_RESTART_RULE
#   export MW_ROLLOUT_RESTART_RULE
# fi

# Fetching cluster name

kubectl get namespace | grep -q ${MW_NAMESPACE} || kubectl create ns ${MW_NAMESPACE}

CURRENT_CONTEXT="$(kubectl config current-context)"
MW_KUBE_CLUSTER_NAME="$(kubectl config view -o jsonpath="{.contexts[?(@.name == '"$CURRENT_CONTEXT"')].context.cluster}")"
export MW_KUBE_CLUSTER_NAME

echo -e "\nSetting up Middleware Agent ...\n\n\tcluster : $MW_KUBE_CLUSTER_NAME \n\tcontext : $CURRENT_CONTEXT\n"

helm repo add middleware-vision https://helm.middleware.io
helm repo add middleware-labs https://helm.middleware.io

if helm list --namespace ${MW_NAMESPACE} --short | grep -q "mw-vision-suite"; then 
  helm uninstall mw-vision-suite -n ${MW_NAMESPACE}; 
  kubectl delete configmap mw-configmap -n ${MW_NAMESPACE}
else 
  echo ""
fi

if kubectl get configmap mw-configmap --namespace ${MW_NAMESPACE} >/dev/null 2>&1; then
  echo "Good ! We already have mw-configmap !"
else
  kubectl create configmap mw-configmap \
  -n ${MW_NAMESPACE} \
  --from-literal=MW_API_KEY=${MW_API_KEY} \
  --from-literal=TARGET=${TARGET} \
  --from-literal=MW_KUBE_CLUSTER_NAME=${MW_KUBE_CLUSTER_NAME} \
  --from-literal=MW_ROLLOUT_RESTART_RULE=${MW_ROLLOUT_RESTART_RULE}
fi

helm install \
-n ${MW_NAMESPACE} \
--create-namespace \
mw-vision-suite middleware-labs/middleware-vision --version ${MW_HELM_VERSION}
