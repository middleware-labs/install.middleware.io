#!/bin/bash
export PATH=$PATH:/opt/mw-agent/bin

# Function to extract version number
get_version() {
    local version_string="$1"
    echo "$version_string" | grep -oP '\d+\.\d+\.\d+'
}

# Function to compare versions
version_ge() {
    # Returns 0 if version $1 is greater than or equal to version $2, 1 otherwise
    dpkg --compare-versions "$1" "ge" "$2"
}

# Get Middleware Agent version
version_string=$(mw-agent version)
echo $version_string " detected"
version=$(get_version "$version_string")

# Define the threshold version
threshold_version="1.6.4"

# Compare version and run commands based on version
if version_ge "$version" "$threshold_version"; then
    # stopping and removing the service
    sudo systemctl stop mw-agent
    sudo systemctl disable mw-agent
    sudo rm -rf /etc/systemd/system/mw-agent.service
else
    # stopping and removing the service
    sudo systemctl stop mwservice
    sudo systemctl disable mwservice
    sudo rm -rf /etc/systemd/system/mwservice.service
fi

# deleting the MW agent binary
sudo apt-get purge mw-agent -y

# deleting MW agent artifacts
sudo rm -rf /usr/local/bin/mw-agent

# deleting entry from APT list
sudo rm -rf /etc/apt/sources.list.d/mw-agent.list

# -------------------------------------------------------
# OTel Injector Removal
# -------------------------------------------------------
if dpkg -l opentelemetry-injector &>/dev/null; then
    echo "Removing OpenTelemetry Injector ..."

    # Remove libotelinject.so from ld.so.preload if present
    if [ -f /etc/ld.so.preload ]; then
        sudo sed -i '\|/usr/lib/opentelemetry/libotelinject.so|d' /etc/ld.so.preload
        echo "Removed libotelinject.so from /etc/ld.so.preload"
    fi

    # Purge the package (removes config files too)
    sudo dpkg --purge opentelemetry-injector

    # Clean up any leftover dirs
    sudo rm -rf /usr/lib/opentelemetry
    sudo rm -rf /etc/opentelemetry

    echo "OpenTelemetry Injector removed successfully."
else
    echo "OpenTelemetry Injector not installed, skipping."
fi
