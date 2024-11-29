#!/bin/sh
set -e errexit
LOG_FILE="/var/log/mw-kube-agent/mw-kube-agent-install-$(date +%s).log"
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

get_latest_mw_agent_version() {
  repo="middleware-labs/mw-agent"

  # Fetch the latest release version from GitHub API
  latest_version=$(curl --silent "https://api.github.com/repos/$repo/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

  # Check if the version was fetched successfully
  if [ -z "$latest_version" ] || [ "$latest_version" = "null" ]; then
    latest_version="1.6.6"
  fi

  echo "$latest_version"
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

MW_LATEST_VERSION=$(get_latest_mw_agent_version)
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


# Home for local configs
MW_KUBE_AGENT_HOME=/usr/local/bin/mw-kube-agent
export MW_KUBE_AGENT_HOME

# Fetch install manifest 
sudo rm -rf $MW_KUBE_AGENT_HOME
sudo mkdir -p $MW_KUBE_AGENT_HOME
BASE_URL="https://install.middleware.io/scripts/mw-kube-agent"

# Download necessary files
for file in clusterrole.yaml clusterrolebinding.yaml cronjob.yaml daemonset.yaml deployment.yaml \
            role-update.yaml role.yaml rolebinding-update.yaml update-configmap-job.yaml rolebinding.yaml \
            service.yaml serviceaccount-update.yaml serviceaccount.yaml; do
    sudo wget -O "$MW_KUBE_AGENT_HOME/$file" "$BASE_URL/$file"
done

ls -l "$MW_KUBE_AGENT_HOME"

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



# Apply YAML files in specific order
ordered_files="
    serviceaccount.yaml
    serviceaccount-update.yaml
    role.yaml
    role-update.yaml
    rolebinding.yaml
    rolebinding-update.yaml
    serviceaccount.yaml
    clusterrole.yaml
    clusterrolebinding.yaml
    update-configmap-job.yaml
    service.yaml
    deployment.yaml
    daemonset.yaml
    cronjob.yaml
"

for file in $ordered_files; do
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
    "$MW_KUBE_AGENT_HOME/$file" |kubectl apply -f - --kubeconfig "${MW_KUBECONFIG}"

    # If the current file is the job, wait for it to complete
    if [ "$file" = "update-configmap-job.yaml" ]; then
      printf "\nFetching the lastest settings for your account ..."
      job_name=$(kubectl get job -o jsonpath='{.items[0].metadata.name}' --namespace "${MW_NAMESPACE}" --kubeconfig "${MW_KUBECONFIG}")
      kubectl wait --for=condition=complete --timeout=15s job/"$job_name" --namespace "${MW_NAMESPACE}" --kubeconfig "${MW_KUBECONFIG}"
    fi
done

echo "Middleware Kubernetes agent successfully installed !"
