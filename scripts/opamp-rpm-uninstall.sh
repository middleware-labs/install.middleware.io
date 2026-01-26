#!/bin/bash

# stopping and removing the service

service_exists() {
    systemctl list-unit-files | grep -q "^$1.service"
}

if service_exists "mw-agent-opamp"; then
    echo "Stopping and removing mw-agent-opamp service..."
    sudo systemctl stop mw-agent-opamp
    sudo systemctl disable mw-agent-opamp
fi

if service_exists "mw-agent"; then
    echo "Stopping and removing mw-agent service..."
    sudo systemctl stop mw-agent
    sudo systemctl disable mw-agent
fi

if service_exists "mwservice"; then
    echo "Stopping and removing mw-agent service..."
    sudo systemctl stop mwservice
    sudo systemctl disable mwservice
fi

# Remove all possible service files
sudo rm -rf /etc/systemd/system/mw-agent-opamp.service
sudo rm -rf /etc/systemd/system/mw-agent.service
sudo rm -rf /etc/systemd/system/mwservice.service

sudo systemctl daemon-reload

# deleting the MW agent binary
sudo yum remove mw-agent -y

# deleting MW agent artifacts
sudo rm -rf /usr/local/bin/mw-agent

# deleting entry from YUM list
sudo rm -rf /etc/yum.repos.d/middleware.repo

echo -e "\nMiddleware Agent uninstallation completed successfully."

