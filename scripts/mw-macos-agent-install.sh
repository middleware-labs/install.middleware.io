#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to check if a command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Check if required commands are available
required_commands=("sudo" "mkdir" "curl" "uname" "date" "tee")
missing_commands=()

for cmd in "${required_commands[@]}"; do
  if ! command_exists "$cmd"; then
    missing_commands+=("$cmd")
  fi
done

if [ ${#missing_commands[@]} -gt 0 ]; then
  echo "${RED}Error: The following required commands are missing: ${missing_commands[*]}"
  echo "Please install them and run the script again.${NC}"
  exit 1
fi

LOG_FILE="/var/log/mw-agent/macos-installation-script-$(date +%s).log"
sudo mkdir -p /var/log/mw-agent
sudo touch "$LOG_FILE"

MW_TRACKING_TARGET="https://app.middleware.io"
if [ -n "$MW_API_URL_FOR_CONFIG_CHECK" ]; then
    export MW_TRACKING_TARGET="$MW_API_URL_FOR_CONFIG_CHECK"
fi

function send_logs {
  status=$1
  message=$2
  api_key=$3
  macos_version=$(sw_vers -productVersion)
  macos_product_name=$(sw_vers -productName)
  kernel_version=$(uname -r)
  hostname=$(hostname)
  host_id=$(eval hostname)
  platform=$(uname -m)

  payload=$(cat <<EOF
{
  "status": "$status",
  "metadata": {
    "script": "mw-macos-agent-install.sh",
    "status": "ok",
    "message": "$message",
    "macos_version": "$macos_version",
    "macos_product_name": "$macos_product_name",
    "kernel_version": "$kernel_version",
    "hostname": "$hostname",
    "host_id": "$host_id",
    "platform": "$platform",
    "script_logs": "$(sed 's/$/\\n/' "$LOG_FILE" | tr -d '\n' | sed 's/"/\\\"/g')"
  }
}
EOF
)

  url=https://app.middleware.io/api/v1/agent/tracking/"$api_key"
  curl -s --location --request POST "$url" \
  --header 'Content-Type: application/json' \
  --data "$payload" >> /dev/null
}

function on_exit {
  if [ $? -eq 0 ]; then
    send_logs "installed" "Script Completed" "$MW_API_KEY"
  else
    send_logs "error" "Script Failed" "$MW_API_KEY"
  fi
}

trap on_exit EXIT

# Check if MW_API_KEY and MW_TARGET environment variables are set
if [ -z "$MW_API_KEY" ] || [ -z "$MW_TARGET" ]; then
    echo "${RED}Error: MW_API_KEY or MW_TARGET environment variable is not set. ${NC}" | sudo tee -a "$LOG_FILE"
    exit 1
fi
# recording agent installation attempt
send_logs "tried" "Agent Installation Attempted" "$MW_API_KEY"

# Store the architecture in a variable
arch=$(uname -m)

# Determine the correct package to download based on the architecture
if [ "$arch" == "arm64" ]; then
    package="mw-macos-agent-setup-arm64.pkg"
else
    package="mw-macos-agent-setup-amd64.pkg"
fi

# Write the environment variables to /tmp/mw_agent_cfg.txt
input_file="/tmp/mw_agent_cfg.txt"
sudo -E echo "api-key: $MW_API_KEY" | sudo tee "$input_file" > /dev/null
sudo -E echo "target: $MW_TARGET" | sudo tee -a "$input_file" > /dev/null

# Get the installer from Middleware
echo -e "Downloading Middleware Agent for $arch platform..." | sudo tee -a "$LOG_FILE"
if ! sudo curl -L -q -# -o $package "https://github.com/middleware-labs/mw-agent/releases/latest/download/$package"; then
    echo "${RED}Failed to download Middleware macOS installer${NC}" | sudo tee -a "$LOG_FILE"
    exit 1
fi

echo -e "\nInstalling Middleware Agent to /opt/mw-agent. You might be asked to enter sudo password. ${NC}" | sudo tee -a "$LOG_FILE"
# Define the spinner function
spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    tput civis  # Hide cursor
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        for i in $(seq 0 $((${#spinstr} - 1))); do
            printf " [%c]  " "${spinstr:$i:1}"
            sleep $delay
            printf "\b\b\b\b\b\b"  # Move back to overwrite the spinner
        done
    done
    printf "    \b\b\b\b"  # Clear spinner
    tput cnorm  # Show cursor
}

# Run the installer command to install MiddlewareAgent.pkg
sudo installer -pkg ./mw-macos-agent-setup.pkg -target / > /dev/null 2>&1 &
spinner $!

# Check if the installer command was successful
if [ $? -eq 0 ]; then
    echo -e "\n${GREEN}Middleware Agent is successfully installed. Middleware Agent will continue to run in the background and send telemetry data to your Middleware account ${MW_TARGET}. ${NC}" | sudo tee -a "$LOG_FILE"
    echo -e "\n${GREEN}Configuration for Middleware Agent can be found at /opt/mw-agent/agent-config.yaml. ${NC}" | sudo tee -a "$LOG_FILE"
else
    echo -e "\n${RED}Error: Failed to install Middleware Agent. ${NC}" | sudo tee -a "$LOG_FILE"
    exit 1
fi

