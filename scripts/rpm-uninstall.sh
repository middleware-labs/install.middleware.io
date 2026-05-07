#!/bin/bash

# stopping and removing the service
sudo systemctl stop mwservice
sudo systemctl disable mwservice
sudo rm -rf /etc/systemd/system/mwservice.service

# deleting the MW agent binary
sudo yum remove mw-agent -y

# deleting MW agent artifacts
sudo rm -rf /usr/local/bin/mw-agent

# deleting entry from YUM list
sudo rm -rf /etc/yum.repos.d/middleware.repo

# -------------------------------------------------------
# OTel Injector Removal
# -------------------------------------------------------
if rpm -q opentelemetry-injector &>/dev/null; then
    echo "Removing OpenTelemetry Injector ..."

    # Remove libotelinject.so from ld.so.preload if present
    if [ -f /etc/ld.so.preload ]; then
        sudo sed -i '\|/usr/lib/opentelemetry/libotelinject.so|d' /etc/ld.so.preload
        echo "Removed libotelinject.so from /etc/ld.so.preload"
    fi

    sudo rpm -e opentelemetry-injector

    # Clean up any leftover dirs
    sudo rm -rf /usr/lib/opentelemetry
    sudo rm -rf /etc/opentelemetry

    echo "OpenTelemetry Injector removed successfully."
else
    echo "OpenTelemetry Injector not installed, skipping."
fi

# -------------------------------------------------------
# OBI Agent Removal
# -------------------------------------------------------
if [ -f /etc/systemd/system/obi-agent.service ] || [ -f /usr/local/bin/obi ]; then
    echo "Removing OBI Agent ..."
    sudo bash -c "$(curl -fsSL https://install.middleware.io/scripts/install-obi.sh)" -- --uninstall
else
    echo "OBI Agent not installed, skipping."
fi
