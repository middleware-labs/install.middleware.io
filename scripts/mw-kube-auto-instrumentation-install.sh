#!/bin/bash
set -e errexit
LOG_FILE="/var/log/mw-kube-agent/mw-kube-auto-instrumentation-install-$(date +%s).log"
sudo mkdir -p /var/log/mw-kube-agent
sudo touch "$LOG_FILE"
exec &> >(sudo tee -a "$LOG_FILE")

# Get the OS and architecture# detecting architecture
arch=$(uname -m)
os=$(uname -s)

if [ "$arch" == "x86_64" ]; then
    arch="amd64"
elif [ "$arch" == "aarch64" ]; then
    arch="arm64"
else 
    arch="amd64"
fi

if [ "$os" == "Linux" ]; then
    os="linux"
elif [ "$os" == "Darwin" ]; then
    os="darwin"
elif [[ "$os" == *"MINGW"* || "$os" == *"CYGWIN"* ]]; then
    os="windows"
else
    echo "Unsupported OS: $os"
    exit 1
fi

function send_logs {
  status=$1
  message=$2

  payload=$(cat <<EOF
{
  "status": "$status",
  "metadata": {
    "script": "kubernetes auto-instrumentation install",
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

if [ -z "$MW_API_KEY" ]; then
    echo "MW_API_KEY is required"
    exit 1
fi

if [ -z "$MW_KUBE_AGENT_HOME" ]; then
    MW_KUBE_AGENT_HOME=/tmp
fi

sudo mkdir -p $MW_KUBE_AGENT_HOME

if [ -z "$MW_CERT_MANAGER_VERSION" ]; then
   MW_CERT_MANAGER_VERSION="v1.14.5"
fi

if [ -z "$MW_CERT_MANAGER_NAMESPACE" ]; then
   MW_CERT_MANAGER_NAMESPACE="cert-manager"
fi

if [ -z "$MW_OTEL_OPERATOR_VERSION" ]; then
   MW_OTEL_OPERATOR_VERSION="0.107.0"
fi

check_pods_running_and_ready() {
    local namespace=$1
    end_time=$((SECONDS+120))

    while true; do
        # Get all pods in the namespace
        pods=$(kubectl get pods -n $namespace -o jsonpath='{.items[*].metadata.name}')

        all_running_and_ready=true

        # Loop through all pods and check their status and readiness
        for pod in $pods; do
            status=$(kubectl get pod $pod -n $namespace -o jsonpath='{.status.phase}')
            ready=$(kubectl get pod $pod -n $namespace -o jsonpath='{.status.containerStatuses[0].ready}')
            if [[ "$status" != "Running" ]] || [[ "$ready" != "true" ]]; then
                echo "Waiting for $pod to be running and ready..."
                all_running_and_ready=false
                break
            fi
        done

        if $all_running_and_ready; then
            echo "All pods in the $namespace namespace are running and ready"
            break
        fi

        # Check if the timeout has been reached
        if [[ $SECONDS -gt $end_time ]]; then
            echo "Not all pods in the $namespace namespace became running and ready within 2 minutes"
            exit 1
        fi

        # Wait before checking the status again
        sleep 5
    done
}

apply_manifest() {
    local webhook=$1
    local manifest=$2
    local end_time=$((SECONDS+60))

    while true; do
        if kubectl apply -f $manifest 2>/dev/null; then
            echo "Successfully applied $manifest"
            break
        else
            echo "$webhook webhook not yet available, retrying..."
        fi

        if [[ $SECONDS -gt $end_time ]]; then
            echo "Failed to apply $manifest within 1 minute"
            exit 1
        fi

        sleep 5
    done
}

# Set the namespace where cert-manager is installed
if [ -n "${MW_INSTALL_CERT_MANAGER}" ] && [ "${MW_INSTALL_CERT_MANAGER}" = "true" ]; then
    echo -e "-->Setting up cert-manager ..."
    kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/${MW_CERT_MANAGER_VERSION}/cert-manager.yaml

    echo -e "\n-->Checking if all pods in the $MW_CERT_MANAGER_NAMESPACE namespace are running..."
    check_pods_running_and_ready $MW_CERT_MANAGER_NAMESPACE

    echo -e "\n-->Checking if the cert-manager webhook server is ready. This may take a few minutes..."

    curl -fsSL -o cmctl https://github.com/cert-manager/cmctl/releases/latest/download/cmctl_${os}_$arch
    chmod +x cmctl
    sudo mv cmctl $MW_KUBE_AGENT_HOME/cmctl
    $MW_KUBE_AGENT_HOME/cmctl check api --wait=2m
fi

# Install OpenTelemetry Kubernetes Operator
echo -e "\n-->Setting up OpenTelemetry operator ..."
kubectl apply -f https://install.middleware.io/manifests/autoinstrumentation/opentelemetry-operator-${MW_OTEL_OPERATOR_VERSION}.yaml 

# Check if all operator pods in the opentelemetry-operator-system namespace are running
echo -e "\n-->Checking if all pods in the opentelemetry-operator-system namespace are running..."
check_pods_running_and_ready opentelemetry-operator-system

echo -e "\n-->Installing OpenTelemetry auto instrumentation manifest ..."
apply_manifest opentelemetry-operator-system ${MW_OTEL_OPERATOR_NAMESPACE} https://install.middleware.io/manifests/autoinstrumentation/mw-otel-auto-instrumentation.yaml
sudo rm -f $MW_KUBE_AGENT_HOME/cmctl

