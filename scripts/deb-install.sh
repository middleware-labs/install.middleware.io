#!/bin/bash

# Function to check if a command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Check if required commands are available
required_commands=("sudo" "mkdir" "touch" "tee" "date" "curl" "uname" "source" "sed" "tr" "systemctl" "chmod" "dpkg" "apt-get" "exec")
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

LOG_FILE="/var/log/mw-agent/apt-installation-$(date +%s).log"
sudo mkdir -p /var/log/mw-agent
sudo touch "$LOG_FILE"
sudo chmod 666 "$LOG_FILE"

# Redirect both standard output (stdout) and standard error (stderr) to the log file in append mode
# using 'tee' to simultaneously write logs to the file and display them in the console.
exec > >(tee -a "$LOG_FILE") 2>&1

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
    "script": "linux-deb",
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
  --data "$payload" > /dev/null
}

function force_continue {
  read -r -p "Do you still want to continue? (y|N): " response
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

get_latest_mw_agent_version() {
  repo="middleware-labs/mw-agent"

  # Fetch the latest release version from GitHub API
  latest_version=$(curl --silent "https://api.github.com/repos/$repo/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

  # Check if the version was fetched successfully
  if [ -z "$latest_version" ] || [ "$latest_version" = "null" ]; then
    latest_version="1.6.6"
  fi

  echo "$latest_version"
}

trap on_exit EXIT

# recording agent installation attempt
send_logs "tried" "Agent Installation Attempted"

# Check if the system is running Linux
if [ "$(uname -s)" != "Linux" ]; then
  echo "This machine is not running Linux, The script is designed to run on a Linux machine."
  force_continue
fi

MW_LATEST_VERSION=$(get_latest_mw_agent_version)
export MW_LATEST_VERSION
# Check if MW_VERSION is provided
if [ "${MW_VERSION}" = "" ]; then 
  MW_VERSION=$MW_LATEST_VERSION
fi
export MW_VERSION
echo -e "\nInstalling Middleware Agent version ${MW_VERSION} on hostname $(hostname) at $(date)" | sudo tee -a "$LOG_FILE"

# Check if /etc/os-release file exists
if [ -f /etc/os-release ]; then
  source /etc/os-release
  case "$ID" in
    debian|ubuntu)
      echo "os-release ID is $ID"
      ;;
    *)
      case "$ID_LIKE" in
        debian|ubuntu)
          echo  "os-release ID_LIKE is $ID_LIKE"
          ;;
        *)
          echo "This is not a Debian based Linux distribution."
          force_continue
          ;;
      esac
  esac
else
  echo "/etc/os-release file not found. Unable to determine the distribution."
  force_continue
fi

if [ "${MW_DETECTED_ARCH}" = "" ]; then 
  MW_DETECTED_ARCH=$(dpkg --print-architecture)
  echo -e "cpu architecture detected: '$MW_DETECTED_ARCH'"
else 
  echo -e "cpu architecture provided: '$MW_DETECTED_ARCH'"
fi
export MW_DETECTED_ARCH

MW_APT_LIST_ARCH=""
if [[ $MW_DETECTED_ARCH == "arm64" || $MW_DETECTED_ARCH == "armhf" || $MW_DETECTED_ARCH == "armel" || $MW_DETECTED_ARCH == "armeb" ]]; then
  MW_APT_LIST_ARCH=arm64
elif [[ $MW_DETECTED_ARCH == "amd64" || $MW_DETECTED_ARCH == "i386" || $MW_DETECTED_ARCH == "i486" || $MW_DETECTED_ARCH == "i586" || $MW_DETECTED_ARCH == "i686" || $MW_DETECTED_ARCH == "x32" ]]; then
  MW_APT_LIST_ARCH=amd64
else
  echo ""
fi

if [ "${MW_AGENT_HOME}" = "" ]; then 
  MW_AGENT_HOME=/opt/mw-agent
fi
export MW_AGENT_HOME

if [ "${MW_KEYRING_LOCATION}" = "" ]; then 
  MW_KEYRING_LOCATION=/usr/share/keyrings
fi
export MW_KEYRING_LOCATION

if [ "${MW_APT_LIST}" = "" ]; then 
  MW_APT_LIST=mw-agent.list
fi
export MW_APT_LIST

MW_AGENT_BINARY=mw-agent
if [ "${MW_AGENT_BINARY}" = "" ]; then 
  MW_AGENT_BINARY=mw-agent
fi

export MW_AGENT_BINARY

if [ "${MW_AUTO_START}" = "" ]; then 
  MW_AUTO_START=true
fi
export MW_AUTO_START

if [ "${MW_API_KEY}" = "" ]; then 
  echo "MW_API_KEY environment variable is required and is not set."
  force_continue
fi
export MW_API_KEY

if [ "${MW_TARGET}" = "" ]; then 
  echo "MW_TARGET environment variable is required and is not set."
  force_continue
fi
export MW_TARGET

if [ -n "${MW_API_URL_FOR_SYNTHETIC_MONITORING}" ]; then
  export MW_API_URL_FOR_SYNTHETIC_MONITORING
fi

if [ -n "${MW_AGENT_FEATURES_SYNTHETIC_MONITORING}" ]; then
  export MW_AGENT_FEATURES_SYNTHETIC_MONITORING
fi


echo -e "\nThe host agent will monitor all '.log' files inside your /var/log directory recursively [/var/log/**/*.log]\n"

# Adding APT repo address & public key to system
sudo curl -q -fs https://apt.middleware.io/gpg-keys/mw-agent-apt-public.key | sudo gpg --dearmor -o "$MW_KEYRING_LOCATION"/middleware-keyring.gpg
sudo touch /etc/apt/sources.list.d/"$MW_APT_LIST"

echo -e "Adding Middleware Agent APT Repository ...\n"
echo "deb [arch=${MW_APT_LIST_ARCH} signed-by=${MW_KEYRING_LOCATION}/middleware-keyring.gpg] https://apt.middleware.io/public stable main" | sudo tee /etc/apt/sources.list.d/$MW_APT_LIST > /dev/null

# Updating apt list on system
sudo apt-get update -o Dir::Etc::sourcelist="sources.list.d/${MW_APT_LIST}" -o Dir::Etc::sourceparts="-" -o APT::Get::List-Cleanup="0" > /dev/null

# Installing Agent
echo -e "Installing Middleware Agent Service ...\n"
if ! sudo -E apt-get install -y "${MW_AGENT_BINARY}=$MW_VERSION"; then
  echo "Error: Failed to install Middleware Agent."
  exit 1
fi

sudo systemctl daemon-reload

# Adding mw-agent to PATH
if ! grep -q "/opt/mw-agent/bin" ~/.bashrc; then
  echo "export PATH=/opt/mw-agent/bin:$PATH" >> ~/.bashrc
  echo "/opt/mw-agent/bin added to PATH in ~/.bashrc"
else
  echo "/opt/mw-agent/bin is already in the PATH"
fi

#check for errors
if ! sudo systemctl enable mw-agent; then
  echo "Error: Failed to enable Middleware Agent service."
  exit 1
fi

if [ "${MW_AUTO_START}" = true ]; then
    sudo systemctl start mw-agent
    sudo systemctl restart mw-agent
fi

echo -e "Middleware Agent installation completed successfully.\n"