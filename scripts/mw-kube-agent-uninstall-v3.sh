#!/bin/sh
set -e errexit
LOG_FILE="/var/log/mw-kube-agent/mw-kube-agent-uninstall-$(date +%s).log"
sudo sh -c 'mkdir -p /var/log/mw-kube-agent && touch "$0" && exec > "$0" 2>&1' "$LOG_FILE"

send_logs() {
  status=$1
  message=$2

  payload=$(cat <<EOF
{
  "status": "$status",
  "metadata": {
    "script": "kubernetes-v3",
    "status": "ok",
    "message": "$message",
    "script_logs": "$(sed 's/$/\\n/' "$LOG_FILE" | tr -d '\n' | sed 's/"/\\\"/g' | sed 's/\t/\\t/g')"
  }
}
EOF
)

curl -s --location --request POST https://app.middleware.io/api/v1/agent/tracking/"$MW_API_KEY" \
  --header 'Content-Type: application/json' \
  --data-raw "$payload" > /dev/null
}

on_exit() {
  if [ $? -eq 0 ]; then
    send_logs "success" "uninstall completed"
  else
    send_logs "error" "uninstall failed"
  fi
}

trap on_exit EXIT

# recording agent installation attempt
curl -s --location --request POST https://app.middleware.io/api/v1/agent/tracking/"$MW_API_KEY" \
--header 'Content-Type: application/json' \
--data-raw '{
    "status": "tried",
    "metadata": {
        "script": "kubernetes-v3",
        "status": "ok
        "message": "agent uninstalled"
    }
}' > /dev/null

# Target Namespace - For Middleware Agent Workloads
MW_DEFAULT_NAMESPACE=mw-agent-ns
export MW_DEFAULT_NAMESPACE

if [ "$MW_NAMESPACE" = "" ]; then 
  MW_NAMESPACE=$MW_DEFAULT_NAMESPACE
  export MW_NAMESPACE
fi

# Fetching cluster name
CURRENT_CONTEXT="$(kubectl config current-context)"
MW_KUBE_CLUSTER_NAME="$(kubectl config view -o jsonpath="{.contexts[?(@.name == '$CURRENT_CONTEXT')].context.cluster}")"
export MW_KUBE_CLUSTER_NAME

printf "\nUninstalling Middleware Kubernetes agent ...\n\n\tcluster : %s \n\tcontext : %s\n" "$MW_KUBE_CLUSTER_NAME" "$CURRENT_CONTEXT"

if [ "${MW_KUBE_AGENT_INSTALL_METHOD}" = "manifest" ] || [ "${MW_KUBE_AGENT_INSTALL_METHOD}" = "" ]; then

printf "\nMiddleware Kubernetes agent is being uninstalled using manifest files, please wait ..."

# Function to delete a resource and check its status
delete_resource() {
    local resource_type=$1
    local resource_name=$2
    local namespace=$3

    if [ -n "$namespace" ]; then
        kubectl --kubeconfig "${MW_KUBECONFIG}" delete $resource_type $resource_name -n $namespace --ignore-not-found
    else
        kubectl --kubeconfig "${MW_KUBECONFIG}" delete $resource_type $resource_name --ignore-not-found
    fi
}

# Delete namespace-level resources
delete_resource configmap mw-deployment-otel-config $MW_DEFAULT_NAMESPACE
delete_resource configmap mw-daemonset-otel-config $MW_DEFAULT_NAMESPACE
delete_resource serviceaccount mw-service-account $MW_DEFAULT_NAMESPACE
delete_resource serviceaccount mw-service-account-update $MW_DEFAULT_NAMESPACE
delete_resource role mw-role $MW_DEFAULT_NAMESPACE
delete_resource role mw-role-update $MW_DEFAULT_NAMESPACE
delete_resource rolebinding mw-role-binding $MW_DEFAULT_NAMESPACE
delete_resource rolebinding mw-role-binding-update $MW_DEFAULT_NAMESPACE
delete_resource service mw-service $MW_DEFAULT_NAMESPACE
delete_resource deployment mw-kube-agent $MW_DEFAULT_NAMESPACE
delete_resource daemonset mw-kube-agent $MW_DEFAULT_NAMESPACE
delete_resource cronjob mw-kube-agent-update $MW_DEFAULT_NAMESPACE
delete_resource job mw-kube-agent-update-configmap $MW_DEFAULT_NAMESPACE
delete_resource deployment mw-kube-agent-config-updater $MW_DEFAULT_NAMESPACE

# Delete cluster-level resources
delete_resource clusterrole mw-cluster-role-mw-agent-ns
delete_resource clusterrolebinding mw-cluster-role-binding-mw-agent-ns

# kubectl --kubeconfig "${MW_KUBECONFIG}" delete namespace "$MW_NAMESPACE"

elif [ "${MW_KUBE_AGENT_INSTALL_METHOD}" = "helm" ]; then
  echo "Removing Middleware K8s Agent v3 Helm chart ..."
  helm uninstall mw-kube-agent --namespace="$MW_NAMESPACE"
fi

if [ "${MW_AUTO_INSTRUMENT:-false}" = "true" ]; then
    echo -e "\nUninstalling auto-instrumentation components..."
    bash -c "$(curl -L https://install.middleware.io/scripts/mw-kube-auto-instrumentation-uninstall.sh)"
else
    echo -e "If you have installed auto-instrumentation, please set MW_AUTO_INSTRUMENT=true and try again."
    delete_resource namespace "$MW_NAMESPACE"
fi

echo -e "\nMiddleware Kubernetes agent has been successfully uninstalled!"

send_logs "success" "uninstall completed"