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
    "script": "kubernetes-v2",
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
        "script": "kubernetes",
        "status": "ok",
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
# Home for local configs
MW_KUBE_AGENT_HOME=/usr/local/bin/mw-kube-agent
export MW_KUBE_AGENT_HOME

# Fetch install manifest 
sudo su << EOSUDO
mkdir -p $MW_KUBE_AGENT_HOME
cp -r ./mw-kube-agent/* $MW_KUBE_AGENT_HOME
ls -l $MW_KUBE_AGENT_HOME
EOSUDO

kubectl --kubeconfig "${MW_KUBECONFIG}" delete configmap mw-deployment-otel-config --namespace="$MW_NAMESPACE"
kubectl --kubeconfig "${MW_KUBECONFIG}" delete configmap mw-daemonset-otel-config --namespace="$MW_NAMESPACE"
kubectl --kubeconfig "${MW_KUBECONFIG}" delete job mw-kube-agent-update-configmap --namespace="$MW_NAMESPACE"


sudo chmod 777 "$MW_KUBE_AGENT_HOME"
for file in "$MW_KUBE_AGENT_HOME"/*.yaml; do
  sed -e "s|MW_KUBE_CLUSTER_NAME_VALUE|${MW_KUBE_CLUSTER_NAME}|g" \
      -e "s|NAMESPACE_VALUE|${MW_NAMESPACE}|g" \
      -e "s|MW_API_URL_FOR_CONFIG_CHECK_VALUE|${MW_API_URL_FOR_CONFIG_CHECK}|g" \
      -e "s|MW_CONFIG_CHECK_INTERVAL_VALUE|${MW_CONFIG_CHECK_INTERVAL}|g" \
    "$file" > "$file.modified.yaml"

  kubectl delete -f "$file.modified.yaml" --kubeconfig "${MW_KUBECONFIG}" --namespace="$MW_NAMESPACE"

  rm "$file.modified.yaml"
done

kubectl --kubeconfig "${MW_KUBECONFIG}" delete namespace "$MW_NAMESPACE"

elif [ "${MW_KUBE_AGENT_INSTALL_METHOD}" = "helm" ]; then
  echo "Removing Middleware K8s Agent v2 Helm chart ..."
  helm uninstall mw-kube-agent --namespace="$MW_NAMESPACE"

fi

echo "Middleware Kubernetes agent successfully uninstalled !"
