#!/bin/sh
set -e errexit
LOG_FILE="/var/log/mw-agent/mw-kube-agent-cronjob-install-$(date +%s).log"
sudo mkdir -p /var/log/mw-agent
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
    send_logs "installed" "cronjob installation Completed"
  else
    send_logs "error" "cronjob installation failed"
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
        "message": "cronjob installed"
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

echo -e "\nSetting up CronJob for upgrading Middleware Kubernetes agent ...\n\n\tcluster : $MW_KUBE_CLUSTER_NAME \n\tcontext : $CURRENT_CONTEXT\n"

# Home for local configs
MW_KUBE_AGENT_HOME=/usr/local/bin/mw-kube-agent
export MW_KUBE_AGENT_HOME
  
# Fetch install manifest 
sudo su << EOSUDO
mkdir -p $MW_KUBE_AGENT_HOME
touch $MW_KUBE_AGENT_HOME/cronjob.yaml
wget -q -O $MW_KUBE_AGENT_HOME/cronjob.yaml https://install.middleware.io/scripts/mw-kube-agent-cronjob.yaml
EOSUDO

sed -e 's|NAMESPACE_VALUE|'${MW_NAMESPACE}'|g' $MW_KUBE_AGENT_HOME/cronjob.yaml | sudo tee $MW_KUBE_AGENT_HOME/cronjob.yaml > /dev/null
if [ -z "${MW_KUBECONFIG}" ]; then
  kubectl create --kubeconfig=${MW_KUBECONFIG}  -f $MW_KUBE_AGENT_HOME/cronjob.yaml
else  
  kubectl create -f $MW_KUBE_AGENT_HOME/cronjob.yaml
fi

echo "Middleware Kubernetes agent CronJob successfully installed !"

