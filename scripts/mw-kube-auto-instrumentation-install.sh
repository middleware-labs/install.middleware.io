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

curl -s --location --request POST https://app.middleware.io/api/v1/agent/tracking/"$MW_API_KEY" \
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

if [ -z "$MW_TARGET" ]; then
    echo "MW_TARGET is required"
    exit 1
fi

if [ -z "$MW_KUBE_AGENT_HOME" ]; then
    MW_KUBE_AGENT_HOME=/tmp/mw-auto
fi

sudo mkdir -p "$MW_KUBE_AGENT_HOME"

if [ -z "$MW_CERT_MANAGER_VERSION" ]; then
   MW_CERT_MANAGER_VERSION="v1.14.5"
fi

if [ -z "$MW_CERT_MANAGER_NAMESPACE" ]; then
   MW_CERT_MANAGER_NAMESPACE="cert-manager"
fi

if [ -z "$MW_OTEL_OPERATOR_VERSION" ]; then
   MW_OTEL_OPERATOR_VERSION="0.94.2"
fi

MW_AUTOINSTRUMENTATION_NAMESPACE="mw-agent-ns"

# Fetching cluster name
CURRENT_CONTEXT="$(kubectl config current-context)"
MW_KUBE_CLUSTER_NAME="$(kubectl config view -o jsonpath="{.contexts[?(@.name == '$CURRENT_CONTEXT')].context.cluster}")"
export MW_KUBE_CLUSTER_NAME

MW_DOMAIN=${MW_DOMAIN:-"cluster.local"}

if kubectl --kubeconfig "$MW_KUBECONFIG" get namespace "$MW_AUTOINSTRUMENTATION_NAMESPACE" > /dev/null 2>&1; then
    echo "Namespace '${MW_AUTOINSTRUMENTATION_NAMESPACE}' already exists. Skipping creation."
else
    # If namespace doesn't exist, create it
    kubectl --kubeconfig "$MW_KUBECONFIG" create namespace "$MW_AUTOINSTRUMENTATION_NAMESPACE"
    echo "Namespace '${MW_AUTOINSTRUMENTATION_NAMESPACE}' created successfully."
fi

DEFAULT_EXCLUDED="mw-autoinstrumentation,kube-system,local-path-storage,istio-system,linkerd,kube-node-lease,mw-agent-ns"

# Initialize variables for namespace selection
FINAL_OPERATOR=""
NAMESPACE_LIST=""

# Determine operator and namespaces
# shellcheck disable=SC2236
if [ ! -z "$MW_INCLUDED_NAMESPACES" ]; then
    # If included namespaces are provided, they take priority
    FINAL_OPERATOR="In"
    NAMESPACE_LIST="$MW_INCLUDED_NAMESPACES"
else
    # Use excluded namespaces (combine with defaults if provided)
    FINAL_OPERATOR="NotIn"
    # shellcheck disable=SC2236
    if [ ! -z "$MW_EXCLUDED_NAMESPACES" ]; then
        # Combine user provided excludes with defaults and remove duplicates
        NAMESPACE_LIST="$MW_EXCLUDED_NAMESPACES,$DEFAULT_EXCLUDED"
        NAMESPACE_LIST=$(echo "$NAMESPACE_LIST" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')
    else
        NAMESPACE_LIST="$DEFAULT_EXCLUDED"
    fi
fi

NAMESPACE_LIST=$(echo "$NAMESPACE_LIST" | sed 's/,/", "/g' | sed 's/^/["/' | sed 's/$/"]/')

printf "\nSetting up Middleware AutoInstrumentation...\n\n\tcluster : %s \n\tcontext : %s\n" "$MW_KUBE_CLUSTER_NAME" "$CURRENT_CONTEXT"

check_pods_running_and_ready() {
    local namespace=$1
    end_time=$((SECONDS+120))

    while true; do
        # Get all pods in the namespace
        pods=$(kubectl get pods -n "$namespace" -o jsonpath='{.items[*].metadata.name}')

        all_running_and_ready=true

        # Loop through all pods and check their status and readiness
        for pod in $pods; do
            status=$(kubectl get pod "$pod" -n "$namespace" -o jsonpath='{.status.phase}')

            echo "Pod: $pod, Status: $status"
            # For Completed jobs, just check if status is Completed
            if [[ "$status" == "Succeeded" ]]; then
                echo "Job $pod Succeeded successfully"
                continue
            fi

            ready=$(kubectl get pod "$pod" -n "$namespace" -o jsonpath='{.status.containerStatuses[0].ready}')
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

        if curl -s "$manifest" | sed "s|MW_API_KEY_VALUE|$MW_API_KEY|g" | kubectl apply -f - 2>/dev/null; then
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
    kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/"${MW_CERT_MANAGER_VERSION}"/cert-manager.yaml

    echo -e "\n-->Checking if all pods in the $MW_CERT_MANAGER_NAMESPACE namespace are running..."
    check_pods_running_and_ready "$MW_CERT_MANAGER_NAMESPACE"

    echo -e "\n-->Checking if the cert-manager webhook server is ready. This may take a few minutes..."

    curl -fsSL -o cmctl https://github.com/cert-manager/cmctl/releases/latest/download/cmctl_${os}_$arch
    chmod +x cmctl
    sudo mv cmctl "$MW_KUBE_AGENT_HOME"/cmctl
    "$MW_KUBE_AGENT_HOME"/cmctl check api --wait=2m
fi


# Install OpenTelemetry Kubernetes Operator
echo -e "\n-->Setting up OpenTelemetry operator ..."

kubectl apply -f https://install.middleware.io/manifests/opentelemetry-operator/opentelemetry-operator-manifests-"${MW_OTEL_OPERATOR_VERSION}".yaml 

# Check if all operator pods in the mw-agent-ns namespace are running
echo -e "\n-->Checking if all pods in the mw-agent-ns namespace are running..."
check_pods_running_and_ready $MW_AUTOINSTRUMENTATION_NAMESPACE

echo -e "\n-->Installing OpenTelemetry auto instrumentation manifest ..."
apply_manifest opentelemetry-operator https://install.middleware.io/manifests/autoinstrumentation/mw-otel-auto-instrumentation.yaml

BASE_URL="https://install.middleware.io/manifests/mw-autoinstrumentation"

for file in mw-lang-detector-serviceaccount.yaml mw-lang-detector-rbac.yaml webhook-service.yaml \
            mw-lang-detector-daemonset.yaml mw-lang-aggregator.yaml webhook-deployment.yaml certmanager.yaml webhook-config.yaml; do
    if sudo wget -q -O "$MW_KUBE_AGENT_HOME/$file" "$BASE_URL/$file"; then
        :
    else
        echo "✗ Failed to download $file"
        exit 1
    fi
done

ls -l "$MW_KUBE_AGENT_HOME"

# Apply files in order
ordered_files="
    mw-lang-detector-serviceaccount.yaml
    mw-lang-detector-rbac.yaml
    webhook-service.yaml
    mw-lang-aggregator.yaml
    mw-lang-detector-daemonset.yaml
    webhook-deployment.yaml
    certmanager.yaml
    webhook-config.yaml
"
MW_CURRENT_TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

for file in $ordered_files; do
    echo "Applying $file..."
    
    sed -e "s|MW_KUBE_CLUSTER_NAME_VALUE|$MW_KUBE_CLUSTER_NAME|g" \
    -e "s|DOMAIN_NAME|$MW_DOMAIN|g" \
    -e "s|MW_API_KEY_VALUE|$MW_API_KEY|g" \
    -e "s|MW_TARGET_VALUE|$MW_TARGET|g" \
    -e "s|NAMESPACE_LIST_VALUE|${NAMESPACE_LIST}|g" \
    -e "s|MW_CURRENT_TIMESTAMP|${MW_CURRENT_TIMESTAMP}|g" \
    -e "s|MW_OPERATOR|${FINAL_OPERATOR}|g" \
"$MW_KUBE_AGENT_HOME/$file" |kubectl apply -f - --kubeconfig "${MW_KUBECONFIG}"
    
done

echo "Installation complete!"

sudo rm -rf "$MW_KUBE_AGENT_HOME"

