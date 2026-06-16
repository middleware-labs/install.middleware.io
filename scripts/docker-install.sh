#!/bin/bash

# Checking if required commands exists -- Start
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

required_commands=("sudo" "mkdir" "touch" "tee" "date" "curl" "uname" "sed" "tr" "systemctl" "compgen")
missing_commands=()

for cmd in "${required_commands[@]}"; do
  if ! command_exists "$cmd"; then
    missing_commands+=("$cmd")
  fi
done

if [ ${#missing_commands[@]} -gt 0 ]; then
  echo "Error: The following required commands are missing: ${missing_commands[*]}"
  echo "Please install them and run the script again."
  exit 1
fi
# Checking if required commands exists -- End

LOG_FILE="/var/log/mw-agent/docker-installation-$(date +%s).log"
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
    "script": "docker",
    "status": "ok",
    "message": "$message",
    "host_id": "$host_id",
    "script_logs": "$(sed 's/$/\\n/' "$LOG_FILE" | tr -d '\n' | sed 's/"/\\\"/g')"
  }
}
EOF
)

  curl -s --location --request POST "$MW_TRACKING_TARGET"/api/v1/agent/tracking/"$MW_API_KEY" \
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
send_logs "tried" "Agent Installation Attempted"

MW_LOG_PATHS=""

if [ "${MW_AGENT_DOCKER_IMAGE}" = "" ]; then 
  MW_AGENT_DOCKER_IMAGE="ghcr.io/middleware-labs/mw-host-agent:master"
fi
export MW_AGENT_DOCKER_IMAGE


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
    read -r -p "$(echo -e '\nDo you want to monitor any more directories for logs ? \n[C-continue to quick install | A-advanced log path setup]\n[C|A] : ')" yn
    case $yn in
        [Aa]* )
          MW_LOG_PATH_DIR=""
          
          while true; do
            read -r -p "    Enter list of comma seperated paths that you want to monitor [ Ex. => /home/test, /etc/test2 ] : " MW_LOG_PATH_DIR
            export MW_LOG_PATH_DIR
            if [[ $MW_LOG_PATH_DIR =~ ^/|(/[\w-]+)+(,/|(/[\w-]+)+)*$ ]]
            then 
              break
            else
              echo "$MW_LOG_PATH_DIR"
              echo "Invalid file path, try again ..."
            fi
          done

          MW_LOG_PATH_COMPLETE=""
          MW_LOG_PATHS_BINDING=""

          MW_LOG_PATH_DIR_ARRAY=$(echo "$MW_LOG_PATH_DIR" | tr "," "\n")

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
          echo -e "\nNow, our agent will also monitor these paths : $MW_LOG_PATH_COMPLETE"
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

docker pull "${MW_AGENT_DOCKER_IMAGE}"

dockerrun="docker run -d \
  --name mw-agent-${MW_API_KEY:0:5} \
  --pid host \
  --restart always"

# Function to add environment variables to dockerrun
add_env_var() {
    local var_name="$1"
    local var_value="${!var_name}"  # Get the value of the variable using indirect reference
    if [ -n "$var_value" ]; then
        dockerrun="$dockerrun -e $var_name=$var_value"
    fi
}

# Capture all environment variables in the script's environment
# This ensures variables like MW_API_KEY are included
for env_var in $(compgen -e); do
    export env_var
done

# Loop through all environment variables in the script's environment
for env_var in $(compgen -e); do
    # Check if the environment variable starts with MW_ (modify as needed)
    if [[ "$env_var" == MW_* ]]; then
        add_env_var "$env_var"
    fi
done

if [[ $(uname) == "Darwin" ]]; then

  echo "Found a Darwin machine, adding port bindings individually ..."

  dockerrun="$dockerrun \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /var/log:/var/log \
  -v /var/lib/docker/containers:/var/lib/docker/containers \
  -v /tmp:/tmp \
  $MW_LOG_PATHS_BINDING \
  --privileged \
  -p 9319:9319 -p 9320:9320 -p 8006:8006  $MW_AGENT_DOCKER_IMAGE"

else

  dockerrun="$dockerrun \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /var/log:/var/log \
  -v /var/lib/docker/containers:/var/lib/docker/containers \
  -v /tmp:/tmp \
  $MW_LOG_PATHS_BINDING \
  --privileged \
  --network=host $MW_AGENT_DOCKER_IMAGE"

fi

export dockerrun
eval " $dockerrun"
