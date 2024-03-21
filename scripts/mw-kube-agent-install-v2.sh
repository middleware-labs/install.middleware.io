#!/bin/sh
set -e errexit
LOG_FILE="/var/log/mw-kube-agent/mw-kube-agent-install-$(date +%s).log"
sudo mkdir -p /var/log/mw-kube-agent
sudo touch "$LOG_FILE"
exec &> >(sudo tee -a "$LOG_FILE")

function send_logs {
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

curl -s --location --request POST https://app.middleware.io/api/v1/agent/tracking/$MW_API_KEY \
  --header 'Content-Type: application/json' \
  --data-raw "$payload" > /dev/null
}

function on_exit {
  if [ $? -eq 0 ]; then
    send_logs "installed" "Script Completed"
  else
    send_logs "error" "Script Failed"
  fi
}

trap on_exit EXIT

# recording agent installation attempt
curl -s --location --request POST https://app.middleware.io/api/v1/agent/tracking/$MW_API_KEY \
--header 'Content-Type: application/json' \
--data-raw '{
    "status": "tried",
    "metadata": {
        "script": "kubernetes",
        "status": "ok",
        "message": "agent installed"
    }
}' > /dev/null

# Target Namespace - For Middleware Agent Workloads
MW_DEFAULT_NAMESPACE=mw-agent-ns
export MW_DEFAULT_NAMESPACE

if [ "${MW_NAMESPACE}" = "" ]; then 
  MW_NAMESPACE=$MW_DEFAULT_NAMESPACE
  export MW_NAMESPACE
fi

# Fetching cluster name
CURRENT_CONTEXT="$(kubectl config current-context)"
MW_KUBE_CLUSTER_NAME="$(kubectl config view -o jsonpath="{.contexts[?(@.name == '"$CURRENT_CONTEXT"')].context.cluster}")"
export MW_KUBE_CLUSTER_NAME

echo -e "\nSetting up Middleware Kubernetes agent ...\n\n\tcluster : $MW_KUBE_CLUSTER_NAME \n\tcontext : $CURRENT_CONTEXT\n"

# If no installtion method is specified, default to manifest
if [ "${MW_KUBE_AGENT_INSTALL_METHOD}" = "manifest" ] || [ "${MW_KUBE_AGENT_INSTALL_METHOD}" = "" ]; then
  echo -e "\nMiddleware Kubernetes agent is being installed using manifest files, please wait ..."
  # Home for local configs
  MW_KUBE_AGENT_HOME=/usr/local/bin/mw-kube-agent
  export MW_KUBE_AGENT_HOME
  
  # Fetch install manifest 
  sudo su << EOSUDO
  mkdir -p $MW_KUBE_AGENT_HOME
  cp -r ./mw-kube-agent/* $MW_KUBE_AGENT_HOME
  ls -l $MW_KUBE_AGENT_HOME
EOSUDO

  echo "correct..."

  kubectl --kubeconfig "${MW_KUBECONFIG}" create namespace ${MW_NAMESPACE}
  sudo wget -q -O otel-config-deployment.yaml https://install.middleware.io/scripts/otel-config-deployment.yaml
  sudo wget -q -O otel-config-daemonset.yaml https://install.middleware.io/scripts/otel-config-daemonset.yaml
  kubectl --kubeconfig "${MW_KUBECONFIG}" create configmap mw-deployment-otel-config --from-file=otel-config=otel-config-deployment.yaml --namespace=${MW_NAMESPACE}
  kubectl --kubeconfig "${MW_KUBECONFIG}" create configmap mw-daemonset-otel-config --from-file=otel-config=otel-config-daemonset.yaml --namespace=${MW_NAMESPACE}     
  for file in "$MW_KUBE_AGENT_HOME"/*.yaml; do
    echo "something $file"
    kubectl apply -f <( \
      cat "$file" | \
      sed -e "s|MW_KUBE_CLUSTER_NAME_VALUE|${MW_KUBE_CLUSTER_NAME}|g" \
          -e "s|MW_ROLLOUT_RESTART_RULE|${MW_ROLLOUT_RESTART_RULE}|g" \
          -e "s|MW_LOG_PATHS|${MW_LOG_PATHS}|g" \
          -e "s|MW_DOCKER_ENDPOINT_VALUE|${MW_DOCKER_ENDPOINT}|g" \
          -e "s|MW_API_KEY_VALUE|${MW_API_KEY}|g" \
          -e "s|TARGET_VALUE|${MW_TARGET}|g" \
          -e "s|NAMESPACE_VALUE|${MW_NAMESPACE}|g" \
          -e "s|MW_API_URL_FOR_CONFIG_CHECK_VALUE|${MW_API_URL_FOR_CONFIG_CHECK}|g" \
          -e "s|MW_CONFIG_CHECK_INTERVAL_VALUE|${MW_CONFIG_CHECK_INTERVAL}|g" \
    ) --kubeconfig "${MW_KUBECONFIG}"
  done

# If installtion method is specified as helm
elif [ "${MW_KUBE_AGENT_INSTALL_METHOD}" = "helm" ]; then
  echo -e "\nMiddleware helm chart is being installed, please wait ..."
  helm repo add middleware.io https://helm.middleware.io
  helm install --set mw.target=${MW_TARGET} --set mw.apiKey=${MW_API_KEY} --wait mw-kube-agent middleware.io/mw-kube-agent \
  -n ${MW_NAMESPACE} --create-namespace  
else 
  echo -e "MW_KUBE_AGENT_INSTALL_METHOD environment variable not set to \"helm\" or \"manifest\""
  exit 1
fi

echo "Middleware Kubernetes agent successfully installed !"

