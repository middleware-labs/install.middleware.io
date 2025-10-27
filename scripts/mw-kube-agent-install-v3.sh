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
    latest_version="1.15.1"
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
        "script": "kubernetes-v3",
        "status": "ok",
        "message": "agent installed"
    }
}' > /dev/null

# Target Namespace - For Middleware Agent Workloads
MW_DEFAULT_NAMESPACE=mw-agent-ns
export MW_DEFAULT_NAMESPACE

MW_DEFAULT_API_URL_FOR_CONFIG_CHECK=http://app.middleware.io
export MW_DEFAULT_API_URL_FOR_CONFIG_CHECK

MW_DEFAULT_CONFIG_CHECK_INTERVAL="60s"
export MW_DEFAULT_CONFIG_CHECK_INTERVAL

MW_LATEST_VERSION=$(get_latest_mw_agent_version)
export MW_LATEST_VERSION

MW_DEFAULT_ENABLE_DATADOG_RECEIVER=false
export MW_DEFAULT_ENABLE_DATADOG_RECEIVER

# Allow override if explicitly defined
if [ -z "${MW_AGENT_SELF_PROFILING}" ]; then
  MW_AGENT_SELF_PROFILING=false
fi
export MW_AGENT_SELF_PROFILING

if [ -z "${MW_PROFILING_SERVER_URL}" ]; then
  MW_PROFILING_SERVER_URL=https://profiling.middleware.io
fi
export MW_PROFILING_SERVER_URL

if [ -z "${MW_SYNTHETIC_MONITORING_API_URL}" ]; then
  MW_SYNTHETIC_MONITORING_API_URL=wss://app.middleware.io:443/plsrws/v2
fi
export MW_SYNTHETIC_MONITORING_API_URL

if [ -z "${MW_SYNTHETIC_MONITORING_UNSUBSCRIBE_ENDPOINT}" ]; then
  MW_SYNTHETIC_MONITORING_UNSUBSCRIBE_ENDPOINT=https://app.middleware.io/api/v1/synthetics/unsubscribe
fi
export MW_SYNTHETIC_MONITORING_UNSUBSCRIBE_ENDPOINT

if [ -z "${MW_AGENT_FEATURES_OPSAI_AUTOFIX}" ]; then
  MW_AGENT_FEATURES_OPSAI_AUTOFIX=false
fi
export MW_AGENT_FEATURES_OPSAI_AUTOFIX

if [ -z "${MW_OPSAI_API_URL}" ]; then
  MW_OPSAI_API_URL=wss://app.middleware.io/plsrws/v2
fi
export MW_OPSAI_API_URL

if [ -z "${MW_OPSAI_UNSUBSCRIBE_ENDPOINT}" ]; then
  MW_OPSAI_UNSUBSCRIBE_ENDPOINT=https://app.middleware.io/api/v1/synthetics/unsubscribe
fi
export MW_OPSAI_UNSUBSCRIBE_ENDPOINT

ACCOUNT_UID=$(echo "$MW_TARGET" | sed -E 's|^https://([^\.]+).*|\1|')
export ACCOUNT_UID

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

if [ "${MW_ENABLE_DATADOG_RECEIVER}" = "" ]; then 
  MW_ENABLE_DATADOG_RECEIVER=$MW_DEFAULT_ENABLE_DATADOG_RECEIVER
  export MW_ENABLE_DATADOG_RECEIVER
fi

# Fetching cluster name
CURRENT_CONTEXT="$(kubectl config current-context)"
MW_KUBE_CLUSTER_NAME="$(kubectl config view -o jsonpath="{.contexts[?(@.name == '$CURRENT_CONTEXT')].context.cluster}")"
export MW_KUBE_CLUSTER_NAME

printf "\nSetting up Middleware Kubernetes agent ...\n\n\tcluster : %s \n\tcontext : %s\n" "$MW_KUBE_CLUSTER_NAME" "$CURRENT_CONTEXT"

# Home for local configs
MW_KUBE_AGENT_HOME=/tmp/mw-kube-agent
export MW_KUBE_AGENT_HOME

# Fetch install manifest 
sudo rm -rf $MW_KUBE_AGENT_HOME
sudo mkdir -p $MW_KUBE_AGENT_HOME
BASE_URL="https://install.middleware.io/manifests/mw-kube-agent"

# Download necessary files
for file in clusterrole.yaml clusterrolebinding.yaml configupdater.yaml daemonset.yaml deployment.yaml \
            role-update.yaml role.yaml rolebinding-update.yaml rolebinding.yaml \
            service.yaml serviceaccount-update.yaml serviceaccount.yaml \
            synthetics.yaml \
            opsai.yaml clusterrole-opsai.yaml clusterrolebinding-opsai.yaml serviceaccount-opsai.yaml; do
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

# Delete cronjob updater
kubectl delete cronjob mw-kube-agent-update -n "${MW_NAMESPACE}" --kubeconfig "${MW_KUBECONFIG}" --ignore-not-found

# Apply YAML files in specific order

ordered_files="
  serviceaccount.yaml
  serviceaccount-update.yaml
  role.yaml
  role-update.yaml
  rolebinding.yaml
  rolebinding-update.yaml
  clusterrole.yaml
  clusterrolebinding.yaml
  configupdater.yaml
  service.yaml
  deployment.yaml
  daemonset.yaml
"

# Append extra files if MW_AGENT_FEATURES_OPSAI_AUTOFIX is true
if [ "${MW_AGENT_FEATURES_OPSAI_AUTOFIX:-false}" = "true" ]; then
  ordered_files="$ordered_files
  opsai.yaml
  serviceaccount-opsai.yaml
  clusterrole-opsai.yaml
  clusterrolebinding-opsai.yaml"
fi

if [ "${MW_AGENT_FEATURES_SYNTHETIC_MONITORING:-false}" = "true" ]; then 
  ordered_files="$ordered_files
  synthetics.yaml"
fi


for file in $ordered_files; do
  sed -e "s|MW_KUBE_CLUSTER_NAME_VALUE|$MW_KUBE_CLUSTER_NAME|g" \
      -e "s|MW_ROLLOUT_RESTART_RULE|$MW_ROLLOUT_RESTART_RULE|g" \
      -e "s|MW_LOG_PATHS|$MW_LOG_PATHS|g" \
      -e "s|MW_DOCKER_ENDPOINT_VALUE|$MW_DOCKER_ENDPOINT|g" \
      -e "s|MW_API_KEY_VALUE|$MW_API_KEY|g" \
      -e "s|TARGET_VALUE|$MW_TARGET|g" \
      -e "s|ACCOUNT_UID_VALUE|$ACCOUNT_UID|g" \
      -e "s|NAMESPACE_VALUE|${MW_NAMESPACE}|g" \
      -e "s|MW_API_URL_FOR_CONFIG_CHECK_VALUE|$MW_API_URL_FOR_CONFIG_CHECK|g" \
      -e "s|MW_CONFIG_CHECK_INTERVAL_VALUE|$MW_CONFIG_CHECK_INTERVAL|g" \
      -e "s|MW_VERSION_VALUE|$MW_VERSION|g" \
      -e "s|MW_ENABLE_DATADOG_RECEIVER_VALUE|$MW_ENABLE_DATADOG_RECEIVER|g" \
      -e "s|MW_AGENT_FEATURES_SYNTHETIC_MONITORING_VALUE|$MW_AGENT_FEATURES_SYNTHETIC_MONITORING|g" \
      -e "s|MW_AGENT_SELF_PROFILING_VALUE|$MW_AGENT_SELF_PROFILING|g" \
      -e "s|MW_PROFILING_SERVER_URL_VALUE|$MW_PROFILING_SERVER_URL|g" \
      -e "s|MW_SYNTHETIC_MONITORING_API_URL_VALUE|$MW_SYNTHETIC_MONITORING_API_URL|g" \
      -e "s|MW_SYNTHETIC_MONITORING_UNSUBSCRIBE_ENDPOINT_VALUE|$MW_SYNTHETIC_MONITORING_UNSUBSCRIBE_ENDPOINT|g" \
      -e "s|MW_OPSAI_API_URL_VALUE|$MW_OPSAI_API_URL|g" \
      -e "s|MW_OPSAI_UNSUBSCRIBE_ENDPOINT_VALUE|$MW_OPSAI_UNSUBSCRIBE_ENDPOINT|g" \
      -e "s|MW_AGENT_FEATURES_OPSAI_AUTOFIX_VALUE|$MW_AGENT_FEATURES_OPSAI_AUTOFIX|g" \
    "$MW_KUBE_AGENT_HOME/$file" |kubectl apply -f - --kubeconfig "${MW_KUBECONFIG}"
done

echo "Middleware Kubernetes agent successfully installed !"

# Check if MW_AUTO_INSTRUMENT is defined, default to "false" if not
if [ "${MW_AUTO_INSTRUMENT:-false}" = "true" ]; then
    printf "\nAuto-instrumentation is enabled. Installing auto-instrumentation components...\n"
    bash -c "$(curl -L https://install.middleware.io/scripts/mw-kube-auto-instrumentation-install.sh)"
else
  printf "\nAuto-instrumentation is not enabled. Set MW_AUTO_INSTRUMENT=true to enable it.\n"
fi
