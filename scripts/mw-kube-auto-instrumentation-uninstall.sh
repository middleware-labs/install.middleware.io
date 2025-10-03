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
   MW_OTEL_OPERATOR_VERSION="0.94.2"
fi

CURRENT_CONTEXT="$(kubectl config current-context)"
MW_KUBE_CLUSTER_NAME="$(kubectl config view -o jsonpath="{.contexts[?(@.name == '$CURRENT_CONTEXT')].context.cluster}")"

printf "\nUninstalling Middleware AutoInstrumentation ...\n\n\tcluster : %s \n\tcontext : %s\n" "$MW_KUBE_CLUSTER_NAME" "$CURRENT_CONTEXT"

# Uninstall OpenTelemetry Kubernetes Operator
echo -e "\n-->Uninstalling OpenTelemetry operator ..."
kubectl delete -f https://install.middleware.io/manifests/opentelemetry-operator/opentelemetry-operator-manifests-${MW_OTEL_OPERATOR_VERSION}.yaml

# Uninstall cert-manager if it was installed
if [ -n "${MW_UNINSTALL_CERT_MANAGER}" ] && [ "${MW_UNINSTALL_CERT_MANAGER}" = "true" ]; then
    echo -e "\n-->Uninstalling cert-manager ..."
    MW_CERT_MANAGER_VERSION=$(kubectl get pods --namespace cert-manager -l app=cert-manager -o jsonpath="{.items[0].spec.containers[0].image}" | cut -d ":" -f 2)
    kubectl delete -f https://github.com/jetstack/cert-manager/releases/download/${MW_CERT_MANAGER_VERSION}/cert-manager.yaml
fi

# Delete webhook configuration first
kubectl delete mutatingwebhookconfiguration "mw-auto-injector.acme.com" --ignore-not-found

# Delete resources in reverse order
kubectl delete -n mw-agent-ns deployment mw-auto-injector --ignore-not-found
kubectl delete -n mw-agent-ns daemonset mw-lang-detector --ignore-not-found
kubectl delete -n mw-agent-ns service mw-auto-injector --ignore-not-found
kubectl delete clusterrolebinding mw-lang-detector --ignore-not-found
kubectl delete clusterrole mw-lang-detector --ignore-not-found
kubectl delete -n mw-agent-ns serviceaccount mw-lang-detector --ignore-not-found
kubectl delete -n mw-agent-ns certificate mw-auto-injector-tls --ignore-not-found
kubectl delete -n mw-agent-ns issuer mw-auto-injector-selfsigned --ignore-not-found
kubectl delete deployment -n mw-agent-ns mw-lang-aggregator --ignore-not-found
kubectl delete service -n mw-agent-ns mw-lang-aggregator --ignore-not-found
kubectl delete configmap -n mw-agent-ns mw-lang-aggregator-restart-signal --ignore-not-found
# Optionally delete namespace 
kubectl delete namespace mw-agent-ns --ignore-not-found

echo -e "\n-->Uninstallation completed"