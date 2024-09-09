#!/bin/bash

# Check if MW_API_KEY and MW_TARGET environment variables are set
if [ -z "$MW_API_KEY" ] || [ -z "$MW_TARGET" ]; then
    echo "Error: MW_API_KEY or MW_TARGET environment variable is not set."
    exit 1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if the MacBook is Intel-based
if [ "$(uname -m)" != "arm64" ]; then
    echo -e "${RED}Error: This installer is only supported on ARM-based MacBooks.${NC}"
    exit 1
fi

# Write the environment variables to /tmp/mw_agent_cfg.txt
input_file="/tmp/mw_agent_cfg.txt"
sudo -E echo "api-key: $MW_API_KEY" | sudo tee "$input_file" > /dev/null
sudo -E echo "target: $MW_TARGET" | sudo tee -a "$input_file" > /dev/null

# Get the installer from Middleware
echo -e "Downloading Middleware Agent..."
if ! sudo curl -L -q -# -o mw-macos-agent-setup.pkg "https://github.com/middleware-labs/mw-agent/releases/latest/download/mw-macos-agent-setup.pkg"; then
    echo "${RED}Failed to download Middleware macOS installer${NC}"
    exit 1
fi

echo -e "\nInstalling Middleware Agent to /opt/mw-agent. You might be asked to enter sudo password.${NC}"
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
    echo -e "\n${GREEN}Middleware Agent is successfully installed. MW Agent will continue to run in the background and send telemetry data to your Middleware account ${MW_TARGET}.${NC}"
    echo -e "\n${GREEN}Configuration for Middleware Agent can be found at /opt/mw-agent/agent-config.yaml.${NC}"
else
    echo -e "\n${RED}Error: Failed to install Middleware Agent${NC}"
    exit 1
fi

