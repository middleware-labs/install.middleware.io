#!/bin/bash

LOG_FILE="/var/log/mw-agent/rpm-installation-$(date +%s).log"
sudo mkdir -p /var/log/mw-agent
sudo touch "$LOG_FILE"
exec &> >(sudo tee -a "$LOG_FILE")

function send_logs {
  status=$1
  message=$2
  host_id=$(eval hostname)

  payload=$(cat <<EOF
{
  "status": "$status",
  "metadata": {
    "script": "linux-rpm",
    "status": "ok",
    "message": "$message",
    "host_id": "$host_id",
    "script_logs": "$(sed 's/$/\\n/' "$LOG_FILE" | tr -d '\n' | sed 's/"/\\\"/g')"
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
        "script": "linux-rpm",
        "status": "ok",
        "message": "agent installed"
    }
}' > /dev/null

MW_AGENT_HOME=/usr/local/bin/mw-go-agent
MW_AGENT_BINARY=mw-go-agent-host
MW_DETECTED_ARCH=$(uname -m)

RPM_FILE=""

echo -e "\n'"$MW_DETECTED_ARCH"' architecture detected ..."

MW_LATEST_VERSION=0.0.25
export MW_LATEST_VERSION

if [ "${MW_VERSION}" = "" ]; then 
  MW_VERSION=$MW_LATEST_VERSION
  export MW_VERSION
fi

if [[ $MW_DETECTED_ARCH == "x86_64" ]]; then
  RPM_FILE="mw-go-agent-host-${MW_VERSION}-1.x86_64.rpm"
  MW_AGENT_BINARY="mw-go-agent-host"
elif [[ $MW_DETECTED_ARCH == "aarch64" ]]; then
  RPM_FILE="mw-go-agent-host-arm-${MW_VERSION}-1.aarch64.rpm"
  MW_AGENT_BINARY="mw-go-agent-host-arm"
else
  echo ""
fi

wget -q -O $MW_AGENT_BINARY.rpm install.middleware.io/rpms/$RPM_FILE
sudo rpm -i $MW_AGENT_BINARY.rpm
export PATH=$PATH:/usr/bin/$MW_AGENT_BINARY
source ~/.bashrc

export MW_AUTO_START=true

MW_LOG_PATHS=""

echo -e "\nThe host agent will monitor all '.log' files inside your /var/log directory recursively [/var/log/**/*.log]\n"



echo -e "Downloading data ingestion rules ...\n"
sudo mkdir -p /usr/bin/configyamls/all
sudo wget -q -O /usr/bin/configyamls/all/otel-config.yaml https://install.middleware.io/configyamls/all/otel-config.yaml
sudo mkdir -p /usr/bin/configyamls/metrics
sudo wget -q -O /usr/bin/configyamls/metrics/otel-config.yaml https://install.middleware.io/configyamls/metrics/otel-config.yaml
sudo mkdir -p /usr/bin/configyamls/traces
sudo wget -q -O /usr/bin/configyamls/traces/otel-config.yaml https://install.middleware.io/configyamls/traces/otel-config.yaml
sudo mkdir -p /usr/bin/configyamls/logs
sudo wget -q -O /usr/bin/configyamls/logs/otel-config.yaml https://install.middleware.io/configyamls/logs/otel-config.yaml
sudo mkdir -p /usr/bin/configyamls/nodocker
sudo wget -q -O /usr/bin/configyamls/nodocker/otel-config.yaml https://install.middleware.io/configyamls/nodocker/otel-config.yaml
sudo mkdir -p /etc/ssl/certs
sudo wget -q -O /etc/ssl/certs/MwCA.pem https://install.middleware.io/certs/MwCA.pem


MW_USER=$(whoami)
export MW_USER

sudo su << EOSUDO


# Running Agent as a Daemon Service
touch /etc/systemd/system/mwservice.service
mkdir -p $MW_AGENT_HOME/apt 
touch $MW_AGENT_HOME/apt/executable

cat << EOF > /etc/systemd/system/mwservice.service
[Unit]
Description=Melt daemon!
[Service]
User=$MW_USER
#Code to execute
#Can be the path to an executable or code itself
WorkingDirectory=$MW_AGENT_HOME/apt
ExecStart=$MW_AGENT_HOME/apt/executable
Type=simple
TimeoutStopSec=10
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF


cat << EOEXECUTABLE > $MW_AGENT_HOME/apt/executable
#!/bin/sh

# Check if MW_API_KEY is non-empty, then set the environment variable
if [ -n "$MW_API_KEY" ]; then
    export MW_API_KEY="$MW_API_KEY"
fi

# Check if MW_TARGET is non-empty, then set the environment variable
if [ -n "$MW_TARGET" ]; then
    export MW_TARGET="$MW_TARGET"
fi

# Check if MW_ENABLE_SYNTHETIC_MONITORING is non-empty, then set the environment variable
if [ -n "$MW_ENABLE_SYNTHETIC_MONITORING" ]; then
    export MW_ENABLE_SYNTHETIC_MONITORING="$MW_ENABLE_SYNTHETIC_MONITORING"
fi

# Check if MW_CONFIG_CHECK_INTERVAL is non-empty, then set the environment variable
if [ -n "$MW_CONFIG_CHECK_INTERVAL" ]; then
    export MW_CONFIG_CHECK_INTERVAL="$MW_CONFIG_CHECK_INTERVAL"
fi

# Check if MW_DOCKER_ENDPOINT is non-empty, then set the environment variable
if [ -n "$MW_DOCKER_ENDPOINT" ]; then
    export MW_DOCKER_ENDPOINT="$MW_DOCKER_ENDPOINT"
fi

# Check if MW_API_URL_FOR_CONFIG_CHECK is non-empty, then set the environment variable
if [ -n "$MW_API_URL_FOR_CONFIG_CHECK" ]; then
    export MW_API_URL_FOR_CONFIG_CHECK="$MW_API_URL_FOR_CONFIG_CHECK"
fi

# Check if MW_HOST_TAGS is non-empty, then set the environment variable
if [ -n "$MW_HOST_TAGS" ]; then
    export MW_HOST_TAGS="$MW_HOST_TAGS"
fi

# Start the MW_AGENT_BINARY with the configured environment variables
$MW_AGENT_BINARY start

EOEXECUTABLE




chmod 777 $MW_AGENT_HOME/apt/executable

EOSUDO

sudo systemctl daemon-reload
sudo systemctl enable mwservice

if [ "${MW_AUTO_START}" = true ]; then	
    sudo systemctl start mwservice
fi

echo -e "Installation done ! \n"