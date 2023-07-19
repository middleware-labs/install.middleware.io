#!/bin/bash

LOG_FILE="/var/log/mw-agent/docker-installation-$(date +%s).log"
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
    "script": "docker",
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
        "script": "docker",
        "status": "ok",
        "message": "agent installed"
    }
}' > /dev/null

MW_LOG_PATHS=""
MW_AGENT_DOCKER_IMAGE=""

MW_DETECTED_ARCH=$(dpkg --print-architecture)
if [[ $MW_DETECTED_ARCH == "arm64" || $MW_DETECTED_ARCH == "arm32" ]]; then
  MW_AGENT_DOCKER_IMAGE="ghcr.io/middleware-labs/mw-host-agent:master"
else 
  MW_AGENT_DOCKER_IMAGE="ghcr.io/middleware-labs/mw-host-agent:master"
fi


if [[ $(which docker) && $(docker --version) ]]; then
  echo -e ""
else
  echo -e "\nSeems like docker is not already installed on the system"
  echo -e "\nPlease install docker first, This link might be helpful : https://docs.docker.com/engine/install/\n"
  exit 1
fi

echo -e "\nThe host agent will monitor all '.log' files inside your /var/log directory recursively [/var/log/**/*.log]"

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

docker pull $MW_AGENT_DOCKER_IMAGE

if [[ $(uname) == "Darwin" ]]; then

  echo "Found a Darwin machine, adding port bindings individually ..."

  HOSTNAME=eval "hostname"

  dockerrun="docker run -d \
  --hostname $HOSTNAME \
  --name mw-agent-${MW_API_KEY:0:5} \
  --pid host \
  --restart always \
  -e MW_API_KEY=$MW_API_KEY \
  -e MW_LOG_PATHS=$MW_LOG_PATHS \
  -e MW_API_URL_FOR_RESTART=$MW_API_URL_FOR_RESTART \
  -e MW_API_URL_FOR_YAML=$MW_API_URL_FOR_YAML \
  -e TARGET=$TARGET \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /var/log:/var/log \
  -v /var/lib/docker/containers:/var/lib/docker/containers \
  -v /tmp:/tmp \
  $MW_LOG_PATHS_BINDING \
  --privileged \
  -p 9319:9319 -p 9320:9320 -p 8006:8006  $MW_AGENT_DOCKER_IMAGE api-server start"

else

  dockerrun="docker run -d \
  --name mw-agent-${MW_API_KEY:0:5} \
  --pid host \
  --restart always \
  -e MW_API_KEY=$MW_API_KEY \
  -e MW_LOG_PATHS=$MW_LOG_PATHS \
  -e MW_API_URL_FOR_RESTART=$MW_API_URL_FOR_RESTART \
  -e MW_API_URL_FOR_YAML=$MW_API_URL_FOR_YAML \
  -e MW_TARGET=$MW_TARGET \
  -e MW_HOST_TAGS=$MW_HOST_TAGS \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /var/log:/var/log \
  -v /var/lib/docker/containers:/var/lib/docker/containers \
  -v /tmp:/tmp \
  $MW_LOG_PATHS_BINDING \
  --privileged \
  --network=host $MW_AGENT_DOCKER_IMAGE api-server start"

fi

export dockerrun
eval " $dockerrun"
