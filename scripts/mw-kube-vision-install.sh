#!/bin/sh

LOG_FILE="/var/log/mw-kube-vision/mw-kube-vision-install-$(date +%s).log"
sudo mkdir -p /var/log/mw-kube-vision
sudo touch "$LOG_FILE"
exec &> >(sudo tee -a "$LOG_FILE")

function send_logs {
  status=$1
  message=$2

  payload=$(cat <<EOF
{
  "status": "$status",
  "metadata": {
    "script": "kubernetes-auto-instrument",
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
    send_logs "success" "install completed"
  else
    send_logs "error" "install failed"
  fi
}

trap on_exit EXIT

curl -s --location --request POST https://app.middleware.io/api/v1/agent/tracking/$MW_API_KEY \
--header 'Content-Type: application/json' \
--data-raw '{
    "status": "tried",
    "metadata": {
        "script": "kubernetes-auto-instrument",
        "status": "ok",
        "message": "mw-kube-vision installed"
    }
}' > /dev/null

# Target Namespace - For Middleware Agent Workloads
MW_DEFAULT_NAMESPACE=mw-kube-vision
export MW_DEFAULT_NAMESPACE

if [ "${MW_NAMESPACE}" = "" ]; then 
  MW_NAMESPACE=$MW_DEFAULT_NAMESPACE
  export MW_NAMESPACE
fi

kubectl get namespace | grep -q ${MW_NAMESPACE} || kubectl create ns ${MW_NAMESPACE}

CURRENT_CONTEXT="$(kubectl config current-context)"
MW_KUBE_CLUSTER_NAME="$(kubectl config view -o jsonpath="{.contexts[?(@.name == '"$CURRENT_CONTEXT"')].context.cluster}")"
export MW_KUBE_CLUSTER_NAME

echo -e "\nSetting up Middleware Kubernetes Vision ...\n\n\tcluster : $MW_KUBE_CLUSTER_NAME \n\tcontext : $CURRENT_CONTEXT\n"

#helm repo add middleware-vision https://helm.middleware.io
helm repo add middleware.io https://helm.middleware.io

if helm list --namespace ${MW_NAMESPACE} --short | grep -q "mw-kube-vision"; then 
  helm uninstall mw-kube-vision -n ${MW_NAMESPACE}; 
  kubectl delete configmap mw-kube-vision -n ${MW_NAMESPACE}
else 
  echo ""
fi

if kubectl get configmap mw-kube-vision --namespace ${MW_NAMESPACE} >/dev/null 2>&1; then
  echo "Good ! We already have mw-kube-vision configmap!"
else
  kubectl create configmap mw-kube-vision \
  -n ${MW_NAMESPACE} \
  --from-literal=MW_API_KEY=${MW_API_KEY} \
  --from-literal=MW_TARGET=${MW_TARGET} \
  --from-literal=MW_KUBE_CLUSTER_NAME=${MW_KUBE_CLUSTER_NAME} \
  --from-literal=MW_ROLLOUT_RESTART_RULE=${MW_ROLLOUT_RESTART_RULE}
fi

echo -e "\nMiddleware Kubernetes Vision helm chart is being installed, please wait ..."

helm install --wait \
-n ${MW_NAMESPACE} \
--create-namespace \
mw-kube-vision middleware.io/mw-kube-vision

# Adding SCC for Openshift based clusters
if kubectl api-resources | grep -q "routes"; then
    # Cluster is OpenShift-based, execute the command here
    echo "Current cluster is OpenShift-based"
    echo -e "\nAdding SCC for Openshift based clusters ...\n"

  if command -v oc &> /dev/null; then
      echo "oc is installed, running command..."
     
      cat <<EOF > custom-scc.yaml
apiVersion: security.openshift.io/v1
kind: SecurityContextConstraints
metadata:
  name: custom-scc
allowHostDirVolumePlugin: true
allowHostIPC: true
allowHostNetwork: true
allowHostPID: true
allowHostPorts: true
allowPrivilegedContainer: true
allowedCapabilities: ["*"]
fsGroup:
  type: RunAsAny
runAsUser:
  type: RunAsAny
seLinuxContext:
  type: RunAsAny
supplementalGroups:
  type: RunAsAny
EOF

      oc create -f custom-scc.yaml
      oc adm policy add-scc-to-user custom-scc -z vision-data-collection -n mw-vision
      oc adm policy add-scc-to-user custom-scc -z visioncart -n mw-vision
      oc adm policy add-scc-to-user custom-scc -z vision-scheduler -n mw-vision
      oc adm policy add-scc-to-user custom-scc -z vision-ui -n mw-vision
      oc adm policy add-scc-to-user custom-scc -z vision-autoscaler -n mw-vision
      oc adm policy add-scc-to-user custom-scc -z odigos-instrumentor -n mw-vision
      oc adm policy add-scc-to-user custom-scc -z default -n mw-vision
  fi

fi
