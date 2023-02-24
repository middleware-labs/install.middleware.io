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

MW_LATEST_VERSION=""
MW_AGENT_HOME=""
MW_APT_LIST=""
MW_APT_LIST_ARCH=""
MW_AGENT_BINARY=""
MW_DETECTED_ARCH=$(dpkg --print-architecture)

echo -e "\n'"$MW_DETECTED_ARCH"' architecture detected ..."

if [[ $MW_DETECTED_ARCH == "arm64" || $MW_DETECTED_ARCH == "armhf" || $MW_DETECTED_ARCH == "armel" || $MW_DETECTED_ARCH == "armeb" ]]; then
  MW_LATEST_VERSION=0.0.15arm64
  MW_AGENT_HOME=/usr/local/bin/mw-go-agent-arm
  MW_APT_LIST=mw-go-arm.list
  MW_AGENT_BINARY=mw-go-agent-host-arm
  MW_APT_LIST_ARCH=arm64
elif [[ $MW_DETECTED_ARCH == "amd64" || $MW_DETECTED_ARCH == "i386" || $MW_DETECTED_ARCH == "i486" || $MW_DETECTED_ARCH == "i586" || $MW_DETECTED_ARCH == "i686" || $MW_DETECTED_ARCH == "x32" ]]; then
  MW_LATEST_VERSION=0.0.15
  MW_AGENT_HOME=/usr/local/bin/mw-go-agent
  MW_APT_LIST=mw-go.list
  MW_AGENT_BINARY=mw-go-agent-host
  MW_APT_LIST_ARCH=all
else
  echo ""
fi

export MW_LATEST_VERSION
export MW_AUTO_START=true

if [ "${MW_VERSION}" = "" ]; then 
  MW_VERSION=$MW_LATEST_VERSION
  export MW_VERSION
fi

MW_LOG_PATHS=""

echo -e "\nThe host agent will monitor all '.log' files inside your /var/log directory recursively [/var/log/**/*.log]\n"

# conditional log path capabilities
if [[ $MW_ADVANCE_LOG_PATH_SETUP == "true" ]]; then
while true; do
    read -p "`echo -e '\nDo you want to monitor any more directories for logs ? \n[C-continue to quick install | A-advanced log path setup]\n[C|A] : '`" yn
    case $yn in
        [Aa]* )
          MW_LOG_PATH_DIR=""
          
          while true; do
            read -p "    Enter list of comma seperated paths that you want to monitor [ Ex. => /home/test, /etc/test2 | S - skip and continue ] : " MW_LOG_PATH_DIR
            export MW_LOG_PATH_DIR
            if [[ $MW_LOG_PATH_DIR =~ ^/|(/[\w-]+)+(,/|(/[\w-]+)+)*$ ]]
            then 
              break
            else
              echo $MW_LOG_PATH_DIR
              echo "Invalid file path, try again ..."
            fi
          done

          MW_LOG_PATH_COMPLETE=""
          MW_LOG_PATHS_BINDING=""

          MW_LOG_PATH_DIR_ARRAY=($(echo $MW_LOG_PATH_DIR | tr "," "\n"))

          for i in "${MW_LOG_PATH_DIR_ARRAY[@]}"
          do
            MW_LOG_PATHS_BINDING=$MW_LOG_PATHS_BINDING" -v $i:$i"
            if [ "${MW_LOG_PATH_COMPLETE}" = "" ]; then
              MW_LOG_PATH_COMPLETE="$MW_LOG_PATH_COMPLETE$i/**/*.*"
            else
              MW_LOG_PATH_COMPLETE="$MW_LOG_PATH_COMPLETE,$i/**/*.*"
            fi
          done

          export MW_LOG_PATH_COMPLETE

          MW_LOG_PATHS=$MW_LOG_PATH_COMPLETE
          export MW_LOG_PATHS
          echo -e "\n------------------------------------------------"
          echo -e "\nNow, our agent will also monitor these paths : "$MW_LOG_PATH_COMPLETE
          echo -e "\n------------------------------------------------\n"
          sleep 4
          break;;
        [Cc]* ) 
          echo -e "\n----------------------------------------------------------\n\nOkay, Continuing installation ....\n\n----------------------------------------------------------\n"
          break;;
        * ) 
          echo -e "\nPlease answer with c or a."
          continue;;
    esac
done
fi

# Adding APT repo address & public key to system
sudo mkdir -p $MW_AGENT_HOME/apt
sudo touch $MW_AGENT_HOME/apt/pgp-key-$MW_VERSION.public
sudo wget -q -O $MW_AGENT_HOME/apt/pgp-key-$MW_VERSION.public https://install.middleware.io/public-keys/pgp-key-$MW_VERSION.public
sudo touch /etc/apt/sources.list.d/$MW_APT_LIST

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
sudo apt-get install ca-certificates > /dev/null
sudo update-ca-certificates > /dev/null

echo -e "Adding Middleware Agent APT Repository ...\n"
sed -e 's|$MW_LOG_PATHS|'$MW_LOG_PATHS'|g' /usr/bin/configyamls/all/otel-config.yaml | sudo tee /usr/bin/configyamls/all/otel-config.yaml > /dev/null

echo "deb [arch=$MW_APT_LIST_ARCH signed-by=$MW_AGENT_HOME/apt/pgp-key-$MW_VERSION.public] https://install.middleware.io/repos/$MW_VERSION/apt-repo stable main" | sudo tee /etc/apt/sources.list.d/$MW_APT_LIST > /dev/null

# Updating apt list on system
sudo apt-get update -o Dir::Etc::sourcelist="sources.list.d/$MW_APT_LIST" -o Dir::Etc::sourceparts="-" -o APT::Get::List-Cleanup="0" > /dev/null

# Installing Agent
echo -e "Installing Middleware Agent Binary ...\n"
sudo apt-get install $MW_AGENT_BINARY > /dev/null

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


# Adding Cron to update + upgrade package every 5 minutes

sudo mkdir -p $MW_AGENT_HOME/apt/cron
sudo touch $MW_AGENT_HOME/apt/cron/mw-go.log

sudo crontab -l > cron_bkp
sudo echo "*/5 * * * * (wget -q -O $MW_AGENT_HOME/apt/pgp-key-$MW_VERSION.public https://install.middleware.io/public-keys/pgp-key-$MW_VERSION.public && sudo apt-get update -o Dir::Etc::sourcelist='sources.list.d/$MW_APT_LIST' -o Dir::Etc::sourceparts='-' -o APT::Get::List-Cleanup='0' && sudo apt-get install --only-upgrade telemetry-agent-host && sudo systemctl restart mwservice) >> $MW_AGENT_HOME/apt/cron/melt.log 2>&1 >> $MW_AGENT_HOME/apt/cron/melt.log" >> cron_bkp
sudo crontab cron_bkp
sudo rm cron_bkp

echo -e "Installation done ! \n"

# sudo su << EOSUDO

# echo '

#   MW Go Agent Installed Successfully !
#   ----------------------------------------------------

#   /usr/local/bin 
#     └───mw-go-agent
#             └───apt: Contains all the required components to run APT package on the system
#                 └───executable: Contains the script to run agent
#                 └───pgp-key-$MW_VERSION.public: Contains copy of public key
#                 └───cron:
#                     └───mw-go.log: Contains copy of public key

#   /etc 
#     ├─── apt
#     |      └───sources.list.d
#     |                └─── $MW_APT_LIST: Contains the APT repo entry
#     └─── systemd
#            └───system
#                 └─── mwservice.service: Service Entry for MW Agent
# '
# EOSUDO
