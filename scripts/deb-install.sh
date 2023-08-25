#!/bin/bash

LOG_FILE="/var/log/mw-agent/apt-installation-$(date +%s).log"
sudo mkdir -p /var/log/mw-agent
sudo touch "$LOG_FILE"
exec &> >(sudo tee -a "$LOG_FILE")


MW_TRACKING_TARGET="https://app.middleware.io"

if [ -n "$MW_API_URL_FOR_CONFIG_CHECK" ]; then
    export MW_TRACKING_TARGET="$MW_API_URL_FOR_CONFIG_CHECK"
fi


function send_logs {
  status=$1
  message=$2
  host_id=$(eval hostname)

  payload=$(cat <<EOF
{
  "status": "$status",
  "metadata": {
    "script": "linux",
    "status": "ok",
    "message": "$message",
    "host_id": "$host_id",
    "script_logs": "$(sed 's/$/\\n/' "$LOG_FILE" | tr -d '\n' | sed 's/"/\\\"/g')"
  }
}
EOF
)

  curl -s --location --request POST $MW_TRACKING_TARGET/api/v1/agent/tracking/$MW_API_KEY \
  --header 'Content-Type: application/json' \
  --data-raw "$payload" > /dev/null
}

function force_continue {
  read -p "Do you still want to continue? (y|N): " response
  case "$response" in
    [yY])
      echo "Continuing with the script..."
      ;;
    [nN])
      echo "Exiting script..."
      exit 1
      ;;
    *)
      echo "Invalid input. Please enter 'yes' or 'no'."
      force_continue # Recursively call the function until valid input is received.
      ;;
  esac
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
send_logs "tried" "Agent Installation Attempted"

# Check if the system is running Linux
if [ "$(uname -s)" != "Linux" ]; then
  echo "This machine is not running Linux, The script is designed to run on a Linux machine"
  force_continue
fi

# Check if /etc/os-release file exists
if [ -f /etc/os-release ]; then
  source /etc/os-release
  case "$ID" in
    debian|ubuntu)
      echo -e "\nos-release ID is $ID"
      ;;
    *)
      case "$ID_LIKE" in
        debian|ubuntu)
          echo -e "\nos-release ID_LIKE is $ID_LIKE"
          ;;
        *)
          echo "This is not a Debian-based Linux distribution."
          force_continue
          ;;
      esac
  esac
else
  echo "/etc/os-release file not found. Unable to determine the distribution."
  force_continue
fi

MW_LATEST_VERSION=""
MW_AGENT_HOME=""
MW_APT_LIST=""
MW_APT_LIST_ARCH=""
MW_AGENT_BINARY=""
MW_DETECTED_ARCH=$(dpkg --print-architecture)

echo -e "\n'"$MW_DETECTED_ARCH"' architecture detected ..."

if [[ $MW_DETECTED_ARCH == "arm64" || $MW_DETECTED_ARCH == "armhf" || $MW_DETECTED_ARCH == "armel" || $MW_DETECTED_ARCH == "armeb" ]]; then
  MW_LATEST_VERSION=0.0.28arm64
  MW_AGENT_HOME=/usr/local/bin/mw-go-agent-arm
  MW_APT_LIST=mw-go-arm.list
  MW_AGENT_BINARY=mw-go-agent-host-arm
  MW_APT_LIST_ARCH=arm64
elif [[ $MW_DETECTED_ARCH == "amd64" || $MW_DETECTED_ARCH == "i386" || $MW_DETECTED_ARCH == "i486" || $MW_DETECTED_ARCH == "i586" || $MW_DETECTED_ARCH == "i686" || $MW_DETECTED_ARCH == "x32" ]]; then
  MW_LATEST_VERSION=0.0.28
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
            read -p "    Enter list of comma seperated paths that you want to monitor [ Ex. => /home/test, /etc/test2 ] : " MW_LOG_PATH_DIR
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

sudo su << EOSUDO


# Running Agent as a Daemon Service
touch /etc/systemd/system/mwservice.service

cat << EOF > /etc/systemd/system/mwservice.service
[Unit]
Description=Melt daemon!
[Service]

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


# Adding Cron to update + upgrade package every 5 minutes

# sudo mkdir -p $MW_AGENT_HOME/apt/cron
# sudo touch $MW_AGENT_HOME/apt/cron/mw-go.log

# sudo crontab -l > cron_bkp
# sudo echo "*/5 * * * * (wget -q -O $MW_AGENT_HOME/apt/pgp-key-$MW_VERSION.public https://install.middleware.io/public-keys/pgp-key-$MW_VERSION.public && sudo apt-get update -o Dir::Etc::sourcelist='sources.list.d/$MW_APT_LIST' -o Dir::Etc::sourceparts='-' -o APT::Get::List-Cleanup='0' && sudo apt-get install --only-upgrade telemetry-agent-host && sudo systemctl restart mwservice) >> $MW_AGENT_HOME/apt/cron/melt.log 2>&1 >> $MW_AGENT_HOME/apt/cron/melt.log" >> cron_bkp
# sudo crontab cron_bkp
# sudo rm cron_bkp

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
