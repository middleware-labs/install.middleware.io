#!/bin/bash
set -e errexit
LOG_FILE="/var/log/mw-kube-agent/mw-kube-auto-instrumentation-install-$(date +%s).log"
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
    "script": "kubernetes auto-instrumentation uninstall",
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
    send_logs "uninstalled" "Script Completed"
  else
    send_logs "error" "Script Failed"
  fi
}

trap on_exit EXIT

if [ -z "$MW_API_KEY" ]; then
    echo "MW_API_KEY is required"
    exit 1
fi

if [ -z "$MW_CERT_MANAGER_VERSION" ]; then
   MW_CERT_MANAGER_VERSION="v1.14.5"
fi

if [ -z "$MW_OTEL_OPERATOR_VERSION" ]; then
   MW_OTEL_OPERATOR_VERSION="0.101.0"
fi

# Uninstall OpenTelemetry Kubernetes Operator
echo -e "\n-->Uninstalling OpenTelemetry operator ..."
kubectl delete -f https://install.middleware.io/manifests/autoinstrumentation/opentelemetry-operator-${MW_OTEL_OPERATOR_VERSION}.yaml 

# Uninstall cert-manager if it was installed
if [ -n "${MW_UNINSTALL_CERT_MANAGER}" ] && [ "${MW_UNINSTALL_CERT_MANAGER}" = "true" ]; then
    echo -e "\n-->Uninstalling cert-manager ..."
    MW_CERT_MANAGER_VERSION=$(kubectl get pods --namespace cert-manager -l app=cert-manager -o jsonpath="{.items[0].spec.containers[0].image}" | cut -d ":" -f 2)
    kubectl delete -f https://github.com/jetstack/cert-manager/releases/download/${MW_CERT_MANAGER_VERSION}/cert-manager.yaml
fi

echo -e "\n-->Uninstallation completed"