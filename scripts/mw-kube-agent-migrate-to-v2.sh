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
    "script": "kubernetes-migrate-to-v2",
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

send_logs "tried" "K8s Agent V1 to V2 migration attempted"

# Uninstalling K8s Agent v1
bash -c "$(curl -L https://install.middleware.io/scripts/mw-kube-agent-uninstall.sh)"

# Artifact cleanup
sudo rm -rf /usr/local/bin/mw-kube-agent

# Installing K8s Agent v2
MW_API_KEY=$MW_API_KEY MW_TARGET=$MW_TARGET bash -c "$(curl -L https://install.middleware.io/scripts/mw-kube-agent-install-v2.sh)"