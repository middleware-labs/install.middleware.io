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
      force_continue
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
  latest_version=$(curl --silent "https://api.github.com/repos/$repo/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
  if [ -z "$latest_version" ] || [ "$latest_version" = "null" ]; then
    latest_version="1.6.6"
  fi
  echo "$latest_version"
}

get_latest_java_agent_version() {
  repo="middleware-labs/opentelemetry-java-instrumentation"
  latest_version=$(curl --silent "https://api.github.com/repos/$repo/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
  if [ -z "$latest_version" ] || [ "$latest_version" = "null" ]; then
    latest_version="1.8.1"
  else
    latest_version="${latest_version#v}"
  fi
  echo "$latest_version"
}

trap on_exit EXIT

send_logs "tried" "Agent Installation Attempted"

if [ "$(uname -s)" != "Linux" ]; then
  echo "This machine is not running Linux, The script is designed to run on a Linux machine."
  force_continue
fi

MW_LATEST_VERSION=$(get_latest_mw_agent_version)
export MW_LATEST_VERSION
if [ "${MW_VERSION}" = "" ]; then
  MW_VERSION=$MW_LATEST_VERSION
fi
export MW_VERSION
echo -e "\nInstalling Middleware Agent version ${MW_VERSION} on hostname $(hostname) at $(date)" | sudo tee -a "$LOG_FILE"

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

sudo curl -q -fs https://apt.middleware.io/gpg-keys/mw-agent-apt-public.key | sudo gpg --dearmor -o "$MW_KEYRING_LOCATION"/middleware-keyring.gpg
sudo touch /etc/apt/sources.list.d/"$MW_APT_LIST"

echo -e "Adding Middleware Agent APT Repository ...\n"
echo "deb [arch=${MW_APT_LIST_ARCH} signed-by=${MW_KEYRING_LOCATION}/middleware-keyring.gpg] https://apt.middleware.io/public stable main" | sudo tee /etc/apt/sources.list.d/$MW_APT_LIST > /dev/null

sudo apt-get update -o Dir::Etc::sourcelist="sources.list.d/${MW_APT_LIST}" -o Dir::Etc::sourceparts="-" -o APT::Get::List-Cleanup="0" > /dev/null

echo -e "Installing Middleware Agent Service ...\n"
if ! sudo -E apt-get install -y "${MW_AGENT_BINARY}=$MW_VERSION"; then
  echo "Error: Failed to install Middleware Agent."
  exit 1
fi

sudo systemctl daemon-reload

if ! grep -q "/opt/mw-agent/bin" ~/.bashrc; then
  echo "export PATH=/opt/mw-agent/bin:$PATH" >> ~/.bashrc
fi
# Also add mw-agent bin to zshrc if exists
if [ -f "$HOME/.zshrc" ]; then
    if ! grep -q "/opt/mw-agent/bin" "$HOME/.zshrc"; then
        echo "export PATH=/opt/mw-agent/bin:$PATH" >> "$HOME/.zshrc"
    fi
fi

if ! sudo systemctl enable mw-agent; then
  echo "Error: Failed to enable Middleware Agent service."
  exit 1
fi

if [ "${MW_AUTO_START}" = true ]; then
    sudo systemctl start mw-agent
    sudo systemctl restart mw-agent
fi

echo -e "Middleware Agent installation completed successfully.\n"

#########################################
# MW INJECTOR INSTALLATION STARTS HERE
#########################################

echo -e "\n========================================="
echo "MW Injector (Java Auto-Instrumentation)"
echo "========================================="

if [ "${MW_ENABLE_INJECTOR}" = "false" ]; then
  echo "MW_ENABLE_INJECTOR is set to false. Skipping Java auto-instrumentation."
  exit 0
fi

if [ "${MW_INJECTOR_VERSION}" = "" ]; then
  MW_INJECTOR_VERSION="0.0.1_alpha"
fi
export MW_INJECTOR_VERSION

MW_JAVA_AGENT_LATEST_VERSION=$(get_latest_java_agent_version)
if [ "${MW_JAVA_AGENT_VERSION}" = "" ]; then
  MW_JAVA_AGENT_VERSION=$MW_JAVA_AGENT_LATEST_VERSION
fi
export MW_JAVA_AGENT_VERSION

echo -e "\nInstalling MW Injector version ${MW_INJECTOR_VERSION}"
echo -e "Installing Middleware Java Agent version ${MW_JAVA_AGENT_VERSION}\n"

if [ "${MW_INJECTOR_HOME}" = "" ]; then
  MW_INJECTOR_HOME=/opt/middleware
fi
export MW_INJECTOR_HOME

MW_INJECTOR_BIN_DIR="${MW_INJECTOR_HOME}/bin"
MW_JAVA_AGENT_DIR="${MW_INJECTOR_HOME}/agents"

echo "Creating directory structure..."
sudo mkdir -p "$MW_INJECTOR_BIN_DIR"
sudo mkdir -p "$MW_JAVA_AGENT_DIR"
sudo mkdir -p /etc/middleware/systemd
sudo mkdir -p /etc/middleware/tomcat
sudo mkdir -p /etc/middleware/standalone
sudo mkdir -p /etc/middleware/state
sudo mkdir -p /etc/middleware/docker

echo "Downloading MW Injector binary..."
INJECTOR_BINARY_URL="https://github.com/middleware-labs/mw-injector/releases/download/${MW_INJECTOR_VERSION}/mw-injector"
INJECTOR_BINARY_PATH="${MW_INJECTOR_BIN_DIR}/mw-injector"

if ! sudo curl -L -f -o "$INJECTOR_BINARY_PATH" "$INJECTOR_BINARY_URL"; then
  echo "Error: Failed to download MW Injector binary"
  exit 1
fi

sudo chmod +x "$INJECTOR_BINARY_PATH"
echo "✅ MW Injector binary installed to $INJECTOR_BINARY_PATH"

echo "Downloading Middleware Java Agent..."
JAVA_AGENT_JAR="middleware-javaagent-${MW_JAVA_AGENT_VERSION}.jar"
JAVA_AGENT_URL="https://github.com/middleware-labs/opentelemetry-java-instrumentation/releases/download/v${MW_JAVA_AGENT_VERSION}/${JAVA_AGENT_JAR}"
JAVA_AGENT_PATH="${MW_JAVA_AGENT_DIR}/${JAVA_AGENT_JAR}"

if ! sudo curl -L -f -o "$JAVA_AGENT_PATH" "$JAVA_AGENT_URL"; then
  echo "Error: Failed to download Java Agent"
  exit 1
fi

sudo chmod 644 "$JAVA_AGENT_PATH"
sudo chown root:root "$JAVA_AGENT_PATH"
echo "✅ Java Agent installed to $JAVA_AGENT_PATH"

# -----------------------------------------------------------
# GLOBAL PATH CONFIGURATION (SYMLINK + SHELL CONFIGS)
# -----------------------------------------------------------
echo "Configuring Global Path..."

# 1. Create Symlink (Instant system-wide availability)
if [ -L "/usr/local/bin/mw-injector" ]; then
    sudo rm /usr/local/bin/mw-injector
fi
sudo ln -s "$INJECTOR_BINARY_PATH" /usr/local/bin/mw-injector
echo "✅ Created symlink /usr/local/bin/mw-injector"

# 2. Update Bash Config
if [ -f "$HOME/.bashrc" ]; then
    if ! grep -q "${MW_INJECTOR_BIN_DIR}" "$HOME/.bashrc"; then
        echo "export PATH=${MW_INJECTOR_BIN_DIR}:\$PATH" >> "$HOME/.bashrc"
        echo "✅ Updated ~/.bashrc"
    fi
fi

# 3. Update Zsh Config
if [ -f "$HOME/.zshrc" ]; then
    if ! grep -q "${MW_INJECTOR_BIN_DIR}" "$HOME/.zshrc"; then
        echo "export PATH=${MW_INJECTOR_BIN_DIR}:\$PATH" >> "$HOME/.zshrc"
        echo "✅ Updated ~/.zshrc"
    fi
fi
# -----------------------------------------------------------

ENV_FILE="/etc/mw-injector.conf"
echo "Creating configuration file at $ENV_FILE..."
sudo tee "$ENV_FILE" > /dev/null <<EOF
# Middleware Java Instrumentation Configuration
# Generated on $(date)

MW_API_KEY=${MW_API_KEY}
MW_TARGET=${MW_TARGET}
MW_JAVA_AGENT_PATH=${JAVA_AGENT_PATH}
EOF

sudo chmod 600 "$ENV_FILE"
echo "✅ Configuration file created"

# -----------------------------------------------------------
# AUTO-INSTRUMENT CONFIG
# -----------------------------------------------------------
echo -e "\nRunning auto-instrumentation global configuration..."

# We pass the env vars explicitly to ensure the command has context
sudo bash -c "
  export MW_API_KEY='$MW_API_KEY'
  export MW_TARGET='$MW_TARGET'
  export MW_JAVA_AGENT_PATH='$JAVA_AGENT_PATH'

  # Run config command
  '$INJECTOR_BINARY_PATH' auto-instrument-config
"

if [ $? -eq 0 ]; then
  echo "✅ Auto-instrumentation config applied."
else
  echo "⚠️  Failed to apply auto-instrumentation config."
fi
# -----------------------------------------------------------

echo -e "\n========================================="
echo "Java Process Discovery"
echo "========================================="

echo -e "\nScanning for Java processes on the host..."

if [ ! -x "$INJECTOR_BINARY_PATH" ]; then
  sudo chmod +x "$INJECTOR_BINARY_PATH"
fi

# Use the globally available command
if mw-injector list-all > /tmp/mw-java-processes.txt 2>&1; then
  TOMCAT_COUNT=$(grep -c "│ \[TOMCAT\] Instance" /tmp/mw-java-processes.txt 2>/dev/null || echo "0")
  SYSTEMD_COUNT=$(grep -c "│ \[SYSTEMD\] Service" /tmp/mw-java-processes.txt 2>/dev/null || echo "0")
  TOTAL_JAVA_COUNT=$((TOMCAT_COUNT + SYSTEMD_COUNT))

  if [ "$TOTAL_JAVA_COUNT" -gt 0 ]; then
    echo -e "\n📋 Found $TOTAL_JAVA_COUNT Java process(es):\n"
    cat /tmp/mw-java-processes.txt

    echo -e "\n"
    read -r -p "Would you like to auto-instrument these Java processes? (y/N): " response
    case "$response" in
      [yY]|[yY][eE][sS])
        echo -e "\nStarting auto-instrumentation for host Java processes..."
        sudo bash -c "
          export MW_API_KEY='$MW_API_KEY'
          export MW_TARGET='$MW_TARGET'
          export MW_JAVA_AGENT_PATH='$JAVA_AGENT_PATH'
          '$INJECTOR_BINARY_PATH' auto-instrument
        "
        ;;
      *)
        echo "⏭️  Skipping host Java process instrumentation"
        ;;
    esac
  else
    echo "No Java processes found on the host"
  fi
else
  echo "⚠️  Could not scan for Java processes"
fi

if command_exists docker; then
  echo -e "\n========================================="
  echo "Docker Container Discovery"
  echo "========================================="

  echo -e "\nScanning for Java Docker containers..."
  if sudo "$INJECTOR_BINARY_PATH" list-docker > /tmp/mw-java-containers.txt 2>&1; then
    JAVA_CONTAINER_COUNT=$(grep -c "│ \[DOCKER\] Container" /tmp/mw-java-containers.txt 2>/dev/null || echo "0")

    if [ "$JAVA_CONTAINER_COUNT" -gt 0 ]; then
      echo -e "\n🐳 Found $JAVA_CONTAINER_COUNT Java Docker container(s):\n"
      cat /tmp/mw-java-containers.txt

      echo -e "\n"
      read -r -p "Would you like to auto-instrument these Docker containers? (y/N): " response
      case "$response" in
        [yY]|[yY][eE][sS])
          echo -e "\nStarting auto-instrumentation for Docker containers..."
          sudo bash -c "
            export MW_API_KEY='$MW_API_KEY'
            export MW_TARGET='$MW_TARGET'
            export MW_JAVA_AGENT_PATH='$JAVA_AGENT_PATH'
            '$INJECTOR_BINARY_PATH' instrument-docker
          "
          ;;
        *)
          echo "⏭️  Skipping Docker container instrumentation"
          ;;
      esac
    else
      echo "No Java Docker containers found"
    fi
  else
    echo "⚠️  Could not scan for Docker containers"
  fi
else
  echo -e "\nDocker is not installed. Skipping Docker container instrumentation."
fi

rm -f /tmp/mw-java-processes.txt /tmp/mw-java-containers.txt

echo -e "\n========================================="
echo "Installation Summary"
echo "========================================="
echo "✅ Middleware Agent: installed and running"
echo "✅ MW Injector: installed to $INJECTOR_BINARY_PATH"
echo "✅ Symlink: /usr/local/bin/mw-injector created"
echo "✅ Shell Configs: ~/.bashrc and ~/.zshrc updated"
echo "✅ Java Agent: installed to $JAVA_AGENT_PATH"
echo "✅ Config: auto-instrument-config ran successfully"
echo ""
echo "You can manually instrument Java applications using 'mw-injector' command."
echo "========================================="
