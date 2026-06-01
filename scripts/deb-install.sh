#!/bin/bash

# ─── Logging helpers ──────────────────────────────────────────────────────────

log_info()    { echo "[INFO]  $*"; }
log_ok()      { echo "[OK]    $*"; }
log_warn()    { echo "[WARN]  $*"; }
log_error()   { echo "[ERROR] $*"; }

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
  log_error "The following required commands are missing: ${missing_commands[*]}"
  log_error "Please install them and run the script again."
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

run_cmd() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    local env_args=()
    while IFS='=' read -r name value; do
      env_args+=("${name}=${value}")
    done < <(env | grep '^MW_\|^OTEL_')
    sudo "${env_args[@]}" "$@"
  fi
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

get_latest_otel_injector_version() {
  repo="open-telemetry/opentelemetry-injector"

  latest_version=$(curl --silent "https://api.github.com/repos/$repo/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

  if [ -z "$latest_version" ] || [ "$latest_version" = "null" ]; then
    latest_version="v0.1.0"
  fi

  echo "$latest_version"
}

trap on_exit EXIT

# recording agent installation attempt
send_logs "tried" "Agent Installation Attempted"

# Check if the system is running Linux
if [ "$(uname -s)" != "Linux" ]; then
  log_warn "This machine is not running Linux. The script is designed to run on a Linux machine."
  force_continue
fi

MW_LATEST_VERSION=$(get_latest_mw_agent_version)
export MW_LATEST_VERSION
# Check if MW_VERSION is provided
if [ "${MW_VERSION}" = "" ]; then
  MW_VERSION=$MW_LATEST_VERSION
fi
export MW_VERSION

echo ""
log_info "Middleware Agent Install Script"
log_info "Date: $(date -u)"
log_info "Host: $(hostname) | Kernel: $(uname -r) | Arch: $(uname -m)"
log_info "Version: ${MW_VERSION}"
echo ""

# Check if /etc/os-release file exists
if [ -f /etc/os-release ]; then
  # shellcheck source=/dev/null
  source /etc/os-release
  case "$ID" in
    debian|ubuntu)
      log_ok "OS detected: $ID"
      ;;
    *)
      case "$ID_LIKE" in
        debian|ubuntu)
          log_ok "OS detected: $ID (ID_LIKE: $ID_LIKE)"
          ;;
        *)
          log_warn "This is not a Debian based Linux distribution."
          force_continue
          ;;
      esac
  esac
else
  log_warn "/etc/os-release file not found. Unable to determine the distribution."
  force_continue
fi

if [ "${MW_DETECTED_ARCH}" = "" ]; then
  MW_DETECTED_ARCH=$(dpkg --print-architecture)
  log_info "CPU architecture detected: ${MW_DETECTED_ARCH}"
else
  log_info "CPU architecture provided: ${MW_DETECTED_ARCH}"
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
  log_error "MW_API_KEY environment variable is required and is not set."
  force_continue
fi
export MW_API_KEY

if [ "${MW_TARGET}" = "" ]; then
  log_error "MW_TARGET environment variable is required and is not set."
  force_continue
fi
export MW_TARGET

if [ -n "${MW_API_URL_FOR_SYNTHETIC_MONITORING}" ]; then
  export MW_API_URL_FOR_SYNTHETIC_MONITORING
fi

if [ -n "${MW_AGENT_FEATURES_SYNTHETIC_MONITORING}" ]; then
  export MW_AGENT_FEATURES_SYNTHETIC_MONITORING
fi

# OTel Injector defaults
if [ "${MW_ENABLE_INJECTOR}" = "" ]; then
  MW_ENABLE_INJECTOR=true
fi
export MW_ENABLE_INJECTOR

if [ "${OTEL_INJECTOR_VERSION}" = "" ]; then
  OTEL_INJECTOR_VERSION=$(get_latest_otel_injector_version)
fi
export OTEL_INJECTOR_VERSION

# OBI Agent defaults
if [ "${MW_ENABLE_OBI}" = "" ]; then
  MW_ENABLE_OBI=true
fi
export MW_ENABLE_OBI


log_info "The host agent will monitor all '.log' files inside your /var/log directory recursively [/var/log/**/*.log]"

# Adding APT repo address & public key to system
log_info "Adding GPG key and APT repository..."
sudo curl -q -fs https://apt.middleware.io/gpg-keys/mw-agent-apt-public.key | sudo gpg --dearmor -o "$MW_KEYRING_LOCATION"/middleware-keyring.gpg
sudo touch /etc/apt/sources.list.d/"$MW_APT_LIST"
echo "deb [arch=${MW_APT_LIST_ARCH} signed-by=${MW_KEYRING_LOCATION}/middleware-keyring.gpg] https://apt.middleware.io/public stable main" | sudo tee /etc/apt/sources.list.d/"$MW_APT_LIST" > /dev/null
log_ok "APT repository configured."

log_info "Updating package lists..."
sudo apt-get update -o Dir::Etc::sourcelist="sources.list.d/${MW_APT_LIST}" -o Dir::Etc::sourceparts="-" -o APT::Get::List-Cleanup="0" > /dev/null
log_ok "Package lists updated."

log_info "Installing Middleware Agent (${MW_AGENT_BINARY}=${MW_VERSION})..."
if ! run_cmd apt-get install -y "${MW_AGENT_BINARY}=$MW_VERSION"; then
  log_error "Failed to install Middleware Agent."
  exit 1
fi

sudo systemctl daemon-reload

# Adding mw-agent to PATH
if ! grep -q "/opt/mw-agent/bin" ~/.bashrc; then
  echo "export PATH=/opt/mw-agent/bin:$PATH" >> ~/.bashrc
  log_ok "Added /opt/mw-agent/bin to PATH in ~/.bashrc"
else
  log_info "/opt/mw-agent/bin is already in PATH."
fi

# Also add mw-agent bin to zshrc if exists
if [ -f "$HOME/.zshrc" ]; then
    if ! grep -q "/opt/mw-agent/bin" "$HOME/.zshrc"; then
        echo "export PATH=/opt/mw-agent/bin:$PATH" >> "$HOME/.zshrc"
        log_ok "Added /opt/mw-agent/bin to PATH in ~/.zshrc"
    fi
fi

log_info "Enabling mw-agent service..."
if ! sudo systemctl enable mw-agent; then
  log_error "Failed to enable Middleware Agent service."
  exit 1
fi
log_ok "Service enabled to start on boot."

if [ "${MW_AUTO_START}" = true ]; then
    log_info "Starting mw-agent..."
    sudo systemctl start mw-agent
    sudo systemctl restart mw-agent
    log_ok "mw-agent is running."
fi

log_ok "Middleware Agent installation completed successfully."

echo ""
echo "================================================================="
echo "  Middleware Agent v${MW_VERSION} (${MW_DETECTED_ARCH}) installed successfully"
echo "================================================================="
echo ""
echo "  Binary:        ${MW_AGENT_HOME}/bin/${MW_AGENT_BINARY}"
echo "  Service:       mw-agent"
echo "  Log file:      ${LOG_FILE}"
echo ""
echo "  Useful commands:"
echo "    systemctl status mw-agent          # Check service status"
echo "    journalctl -u mw-agent -f          # Follow logs"
echo "    systemctl restart mw-agent         # Restart"
echo "    systemctl stop mw-agent            # Stop"
echo ""

# -------------------------------------------------------
# OTel Injector Installation
# -------------------------------------------------------
if [ "${MW_ENABLE_INJECTOR}" = true ]; then
  log_info "Installing OpenTelemetry Injector version ${OTEL_INJECTOR_VERSION}..."

  # Map detected arch to the arch string used in injector release filenames
  OTEL_INJECTOR_ARCH=""
  if [[ $MW_APT_LIST_ARCH == "arm64" ]]; then
    OTEL_INJECTOR_ARCH="arm64"
  elif [[ $MW_APT_LIST_ARCH == "amd64" ]]; then
    OTEL_INJECTOR_ARCH="amd64"
  else
    log_warn "Unsupported architecture '${MW_DETECTED_ARCH}' for OTel Injector. Skipping."
    exit 0
  fi

  # Strip leading 'v' from version for the filename (e.g. v0.1.0 -> 0.1.0)
  OTEL_INJECTOR_VERSION_STRIPPED="${OTEL_INJECTOR_VERSION#v}"

  OTEL_INJECTOR_DEB="opentelemetry-injector_${OTEL_INJECTOR_VERSION_STRIPPED}_${OTEL_INJECTOR_ARCH}.deb"
  OTEL_INJECTOR_URL="https://github.com/open-telemetry/opentelemetry-injector/releases/download/${OTEL_INJECTOR_VERSION}/${OTEL_INJECTOR_DEB}"
  OTEL_INJECTOR_TMP="/tmp/${OTEL_INJECTOR_DEB}"

  log_info "Downloading ${OTEL_INJECTOR_URL}..."
  if ! curl -fSL -o "$OTEL_INJECTOR_TMP" "$OTEL_INJECTOR_URL"; then
    log_error "Failed to download OpenTelemetry Injector package."
    log_error "URL: ${OTEL_INJECTOR_URL}"
    exit 1
  fi
  log_ok "Downloaded ${OTEL_INJECTOR_DEB}."

  log_info "Installing OpenTelemetry Injector package..."
  if ! sudo dpkg -i "$OTEL_INJECTOR_TMP"; then
    log_error "Failed to install OpenTelemetry Injector package."
    rm -f "$OTEL_INJECTOR_TMP"
    exit 1
  fi

  rm -f "$OTEL_INJECTOR_TMP"

  log_ok "OpenTelemetry Injector ${OTEL_INJECTOR_VERSION} installed successfully."

  echo ""
  echo "================================================================="
  echo "  OpenTelemetry Injector ${OTEL_INJECTOR_VERSION} (${MW_DETECTED_ARCH}) installed successfully"
  echo "================================================================="
  echo ""
  echo "  Package:       ${OTEL_INJECTOR_DEB}"
  echo "  Version:       ${OTEL_INJECTOR_VERSION}"
  echo ""
else
  log_info "OTel Injector installation skipped (MW_ENABLE_INJECTOR=${MW_ENABLE_INJECTOR})."
  echo ""
fi

# -------------------------------------------------------
# OBI Agent Installation
# -------------------------------------------------------
if [ "${MW_ENABLE_OBI}" = true ]; then
  log_info "Installing OBI Agent..."
  echo ""
  run_cmd bash -c "$(curl -fsSL https://install.middleware.io/scripts/install-obi.sh)"
else
  log_info "OBI Agent installation skipped (MW_ENABLE_OBI=${MW_ENABLE_OBI})."
fi
