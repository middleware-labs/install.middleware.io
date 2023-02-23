#!/bin/bash

# recording agent installation attempt
curl -s --location --request POST https://app.middleware.io/api/v1/agent/tracking/$MW_API_KEY \
--header 'Content-Type: application/json' \
--data-raw '{
    "status": "tried",
    "metadata": {
        "script": "linux",
        "status": "ok",
        "message": "agent installed"
    }
}' > /dev/null

wget -q -O mw-go-agent-host-aws.rpm install.middleware.io/rpms/mw-go-agent-host-aws-0.0.1-1.x86_64.rpm
sudo rpm -i mw-go-agent-host-aws.rpm
export PATH=$PATH:/usr/bin/mw-go-agent-host-aws
source ~/.bashrc

# MW_LATEST_VERSION=""
MW_AGENT_HOME=/usr/local/bin/mw-go-agent
# MW_APT_LIST=""
# MW_APT_LIST_ARCH=""
MW_AGENT_BINARY=mw-go-agent-host-aws
# MW_DETECTED_ARCH=$(dpkg --print-architecture)

echo -e "\n'"$MW_DETECTED_ARCH"' architecture detected ..."

# if [[ $MW_DETECTED_ARCH == "arm64" || $MW_DETECTED_ARCH == "armhf" || $MW_DETECTED_ARCH == "armel" || $MW_DETECTED_ARCH == "armeb" ]]; then
#   MW_LATEST_VERSION=0.0.15arm64
#   MW_AGENT_HOME=/usr/local/bin/mw-go-agent-arm
#   MW_APT_LIST=mw-go-arm.list
#   MW_AGENT_BINARY=mw-go-agent-host-arm
#   MW_APT_LIST_ARCH=arm64
# elif [[ $MW_DETECTED_ARCH == "amd64" || $MW_DETECTED_ARCH == "i386" || $MW_DETECTED_ARCH == "i486" || $MW_DETECTED_ARCH == "i586" || $MW_DETECTED_ARCH == "i686" || $MW_DETECTED_ARCH == "x32" ]]; then
#   MW_LATEST_VERSION=0.0.15
#   MW_AGENT_HOME=/usr/local/bin/mw-go-agent
#   MW_APT_LIST=mw-go.list
#   MW_AGENT_BINARY=mw-go-agent-host
#   MW_APT_LIST_ARCH=all
# else
#   echo ""
# fi

export MW_LATEST_VERSION
export MW_AUTO_START=true

if [ "${MW_VERSION}" = "" ]; then 
  MW_VERSION=$MW_LATEST_VERSION
  export MW_VERSION
fi

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

if [ ! "${TARGET}" = "" ]; then

cat << EOIF > $MW_AGENT_HOME/apt/executable
#!/bin/sh
cd /usr/bin && MW_API_KEY=$MW_API_KEY TARGET=$TARGET $MW_AGENT_BINARY start
EOIF

else 

cat << EOELSE > $MW_AGENT_HOME/apt/executable
#!/bin/sh
cd /usr/bin && MW_API_KEY=$MW_API_KEY $MW_AGENT_BINARY start
EOELSE

fi

chmod 777 $MW_AGENT_HOME/apt/executable

EOSUDO

sudo systemctl daemon-reload
sudo systemctl enable mwservice

if [ "${MW_AUTO_START}" = true ]; then	
    sudo systemctl start mwservice
fi

echo -e "Installation done ! \n"