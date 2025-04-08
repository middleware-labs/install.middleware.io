#!/bin/bash
LOG_FILE="/var/log/do-collector/docker-installation-$(date +%s).log"
sudo mkdir -p /var/log/do-collector
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
    "script": "do-collector-docker-install.sh",
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
send_logs "tried" "DO collector docker Installation Attempted"

MW_LOG_PATHS=""

if [ "${MW_DO_COLLECTOR_DOCKER_IMAGE}" = "" ]; then 
  MW_DO_COLLECTOR_DOCKER_IMAGE="ghcr.io/middleware-labs/do-collector:1.0.0"
fi
export MW_DO_COLLECTOR_DOCKER_IMAGE

if [ "${MW_DO_COLLECTOR_CONTAINER_NAME}" = "" ]; then 
  MW_DO_COLLECTOR_CONTAINER_NAME="do-collector"
fi
export MW_DO_COLLECTOR_CONTAINER_NAME


if [[ $(which docker) && $(docker --version) ]]; then
  echo -e ""
else
  echo -e "\nDocker is not installed on the system"
  echo -e "\nPlease install docker first, This link might be helpful : https://docs.docker.com/engine/install/\n"
  exit 1
fi

docker pull "$MW_DO_COLLECTOR_DOCKER_IMAGE"

dockerrun="docker run -d \
  --name $MW_DO_COLLECTOR_CONTAINER_NAME \
  --pid host \
  --restart always"

if [ -n "$MW_API_KEY" ]; then
    dockerrun="$dockerrun -e MW_API_KEY=$MW_API_KEY"
fi

# Check if MW_TARGET is non-empty, then set the environment variable
if [ -n "$MW_TARGET" ]; then
    dockerrun="$dockerrun -e MW_TARGET=$MW_TARGET"
fi

# If MW_LOG_LEVEL is not set, then set it to info
if [ -z "$MW_LOG_LEVEL" ]; then
    MW_LOG_LEVEL=info
fi
dockerrun="$dockerrun -e MW_LOG_LEVEL=$MW_LOG_LEVEL"

# If MW_SYSLOG_HOST is not set, then set it to [::]
if [ -z "$MW_SYSLOG_HOST" ]; then
    MW_SYSLOG_HOST="[::]"
fi
dockerrun="$dockerrun -e MW_SYSLOG_HOST=$MW_SYSLOG_HOST"

# If MW_SYSLOG_PORT is not set, then set it to info
if [ -z "$MW_SYSLOG_PORT" ]; then
    MW_SYSLOG_PORT="5514"
fi
dockerrun="$dockerrun -e MW_SYSLOG_PORT=$MW_SYSLOG_PORT"

# Check if MW_LOG_PATHS is non-empty, then set the environment variable
if [ -n "$MW_LOG_PATHS" ]; then
    dockerrun="$dockerrun -e MW_LOG_PATHS=$MW_LOG_PATHS"
fi

# If MW_PROMETHEUS_DIR is not set, then set it to /etc/prometheus
if [ -z "$MW_PROMETHEUS_DIR" ]; then
    MW_PROMETHEUS_DIR="/etc/prometheus"
fi

# Stop and remove existing container if it exists
docker stop "$MW_DO_COLLECTOR_CONTAINER_NAME" 2>/dev/null
docker rm "$MW_DO_COLLECTOR_CONTAINER_NAME" 2>/dev/null

echo "starting dockerrun"
# shellcheck disable=SC2089
dockerrun="$dockerrun \
-e MW_PROMETHEUS_DIR=$MW_PROMETHEUS_DIR \
-v /var/log:/var/log \
-v "${MW_PROMETHEUS_DIR}:${MW_PROMETHEUS_DIR}" \
--privileged \
--network=host $MW_DO_COLLECTOR_DOCKER_IMAGE"

echo $dockerrun
# shellcheck disable=SC2090
export dockerrun
eval " $dockerrun"

echo "checking status"
# Check if the container is running
container_status=$(docker inspect -f '{{.State.Status}}' $MW_DO_COLLECTOR_CONTAINER_NAME 2>/dev/null)
echo $container_status

if [[ "$container_status" == "running" ]]; then
    echo -e "\n\033[1m'${MW_DO_COLLECTOR_CONTAINER_NAME}' is running and collecting data.\033[0m\n"
    METADATA_URL="http://169.254.169.254/metadata/v1.json"
    PUBLIC_IP=$(curl -s --max-time 2 "$METADATA_URL" | jq -r '.interfaces.public[0].ipv4.ip_address')
    echo 'Use the following configuration to enable log forwarding using RSyslog for managed databases.'
    echo -e "\n\033[1m        Endpoint:           $PUBLIC_IP\033[0m"
    echo -e "\033[1m        Port:               $MW_SYSLOG_PORT\033[0m"
    echo -e "\033[1m        Enable TLS Support: Uncheck this option\033[0m"
    echo -e "\033[1m        Message Format:     Custom\033[0m"
    echo -e "\033[1m        Log Line Template:  <%pri%>1 %timereported:::date-rfc3339% %HOSTNAME% %app-name% %procid% - - %msg%\\\\n\033[0m\n"
elif [[ "$container_status" == "exited" || "$container_status" == "dead" ]]; then
    echo "'${MW_DO_COLLECTOR_CONTAINER_NAME}' failed to start with status $container_status. Please contact our support team at support@middleware.io." 
else
    echo "'${MW_DO_COLLECTOR_CONTAINER_NAME}' does not exist or is not accessible."
fi

