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
    "script": "kubernetes",
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
    send_logs "installed" "Script Completed"
  else
    send_logs "error" "Script Failed"
  fi
}

trap on_exit EXIT

# recording agent installation attempt
curl -s --location --request POST https://app.middleware.io/api/v1/agent/tracking/"$MW_API_KEY" \
--header 'Content-Type: application/json' \
--data-raw '{
    "status": "tried",
    "metadata": {
        "script": "kubernetes-v2",
        "status": "ok",
        "message": "agent installed"
    }
}' > /dev/null

# Target Namespace - For Middleware Agent Workloads
MW_DEFAULT_NAMESPACE=mw-agent-ns
export MW_DEFAULT_NAMESPACE

MW_DEFAULT_API_URL_FOR_CONFIG_CHECK=http://app.middleware.io
export MW_DEFAULT_API_URL_FOR_CONFIG_CHECK

MW_DEFAULT_CONFIG_CHECK_INTERVAL="*/1 * * * *"
export MW_DEFAULT_CONFIG_CHECK_INTERVAL

MW_LATEST_VERSION="1.6.6"
export MW_LATEST_VERSION

if [ "${MW_VERSION}" = "" ]; then 
  MW_VERSION=$MW_LATEST_VERSION
  export MW_VERSION
fi

if [ "${MW_NAMESPACE}" = "" ]; then 
  MW_NAMESPACE=$MW_DEFAULT_NAMESPACE
  export MW_NAMESPACE
fi

if [ "${MW_API_URL_FOR_CONFIG_CHECK}" = "" ]; then 
  MW_API_URL_FOR_CONFIG_CHECK=$MW_DEFAULT_API_URL_FOR_CONFIG_CHECK
  export MW_NAMESPACE
fi

if [ "${MW_CONFIG_CHECK_INTERVAL}" = "" ]; then 
  MW_CONFIG_CHECK_INTERVAL=$MW_DEFAULT_CONFIG_CHECK_INTERVAL
  export MW_NAMESPACE
fi

# Fetching cluster name
CURRENT_CONTEXT="$(kubectl config current-context)"
MW_KUBE_CLUSTER_NAME="$(kubectl config view -o jsonpath="{.contexts[?(@.name == '$CURRENT_CONTEXT')].context.cluster}")"
export MW_KUBE_CLUSTER_NAME

printf "\nSetting up Middleware Kubernetes agent ...\n\n\tcluster : %s \n\tcontext : %s\n" "$MW_KUBE_CLUSTER_NAME" "$CURRENT_CONTEXT"


if [ "${MW_KUBE_AGENT_INSTALL_METHOD}" = "manifest" ] || [ "${MW_KUBE_AGENT_INSTALL_METHOD}" = "" ]; then

printf "\nMiddleware Kubernetes agent is being installed using manifest files, please wait ..."
# Home for local configs
MW_KUBE_AGENT_HOME=/usr/local/bin/mw-kube-agent
export MW_KUBE_AGENT_HOME

# Fetch install manifest 
sudo su << EOSUDO
sudo rm -rf $MW_KUBE_AGENT_HOME
mkdir -p $MW_KUBE_AGENT_HOME
wget -O $MW_KUBE_AGENT_HOME/clusterrole.yaml https://install.middleware.io/scripts/mw-kube-agent/clusterrole.yaml
wget -O $MW_KUBE_AGENT_HOME/clusterrolebinding.yaml https://install.middleware.io/scripts/mw-kube-agent/clusterrolebinding.yaml
wget -O $MW_KUBE_AGENT_HOME/cronjob.yaml https://install.middleware.io/scripts/mw-kube-agent/cronjob.yaml
wget -O $MW_KUBE_AGENT_HOME/daemonset.yaml https://install.middleware.io/scripts/mw-kube-agent/daemonset.yaml
wget -O $MW_KUBE_AGENT_HOME/deployment.yaml https://install.middleware.io/scripts/mw-kube-agent/deployment.yaml
wget -O $MW_KUBE_AGENT_HOME/role-update.yaml https://install.middleware.io/scripts/mw-kube-agent/role-update.yaml
wget -O $MW_KUBE_AGENT_HOME/role.yaml https://install.middleware.io/scripts/mw-kube-agent/role.yaml
wget -O $MW_KUBE_AGENT_HOME/rolebinding-update.yaml https://install.middleware.io/scripts/mw-kube-agent/rolebinding-update.yaml
wget -O $MW_KUBE_AGENT_HOME/rolebinding.yaml https://install.middleware.io/scripts/mw-kube-agent/rolebinding.yaml
wget -O $MW_KUBE_AGENT_HOME/service.yaml https://install.middleware.io/scripts/mw-kube-agent/service.yaml
wget -O $MW_KUBE_AGENT_HOME/serviceaccount-update.yaml https://install.middleware.io/scripts/mw-kube-agent/serviceaccount-update.yaml
wget -O $MW_KUBE_AGENT_HOME/serviceaccount.yaml https://install.middleware.io/scripts/mw-kube-agent/serviceaccount.yaml
ls -l $MW_KUBE_AGENT_HOME
EOSUDO

# Check if the namespace already exists
if kubectl --kubeconfig "$MW_KUBECONFIG" get namespace "$MW_NAMESPACE" > /dev/null 2>&1; then
    echo "Namespace '${MW_NAMESPACE}' already exists. Skipping creation."
else
    # If namespace doesn't exist, create it
    kubectl --kubeconfig "$MW_KUBECONFIG" create namespace "$MW_NAMESPACE"
    echo "Namespace '${MW_NAMESPACE}' created successfully."
fi

sudo wget -q -O otel-config-deployment.yaml https://install.middleware.io/scripts/otel-config-deployment.yaml
sudo wget -q -O otel-config-daemonset.yaml https://install.middleware.io/scripts/otel-config-daemonset.yaml
kubectl --kubeconfig "${MW_KUBECONFIG}" create configmap mw-deployment-otel-config --from-file=otel-config=otel-config-deployment.yaml --namespace="$MW_NAMESPACE"
kubectl --kubeconfig "${MW_KUBECONFIG}" create configmap mw-daemonset-otel-config --from-file=otel-config=otel-config-daemonset.yaml --namespace="$MW_NAMESPACE"     

for file in "$MW_KUBE_AGENT_HOME"/*.yaml; do
  sed -e "s|MW_KUBE_CLUSTER_NAME_VALUE|$MW_KUBE_CLUSTER_NAME|g" \
      -e "s|MW_ROLLOUT_RESTART_RULE|$MW_ROLLOUT_RESTART_RULE|g" \
      -e "s|MW_LOG_PATHS|$MW_LOG_PATHS|g" \
      -e "s|MW_DOCKER_ENDPOINT_VALUE|$MW_DOCKER_ENDPOINT|g" \
      -e "s|MW_API_KEY_VALUE|$MW_API_KEY|g" \
      -e "s|TARGET_VALUE|$MW_TARGET|g" \
      -e "s|NAMESPACE_VALUE|${MW_NAMESPACE}|g" \
      -e "s|MW_API_URL_FOR_CONFIG_CHECK_VALUE|$MW_API_URL_FOR_CONFIG_CHECK|g" \
      -e "s|MW_CONFIG_CHECK_INTERVAL_VALUE|$MW_CONFIG_CHECK_INTERVAL|g" \
      -e "s|MW_VERSION_VALUE|$MW_VERSION|g" \
    "$file" |kubectl apply -f - --kubeconfig "${MW_KUBECONFIG}"
done


elif [ "${MW_KUBE_AGENT_INSTALL_METHOD}" = "helm" ]; then
  helm repo add middleware-labs https://helm.middleware.io
  echo "Installing Middleware K8s Agent v2 via Helm chart ..."
  helm install --set mw.target="$MW_TARGET" --set mw.apiKey="$MW_API_KEY" --set clusterMetadata.name="$MW_KUBE_CLUSTER_NAME" --set mw.apiKey="$MW_API_KEY" --wait mw-kube-agent middleware-labs/mw-kube-agent-v2 \
  -n "$MW_NAMESPACE" --create-namespace 
fi

echo "Middleware Kubernetes agent successfully installed !"

