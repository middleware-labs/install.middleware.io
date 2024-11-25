#!/bin/bash
sudo systemctl stop mwservice
sudo systemctl disable mwservice

MW_DETECTED_ARCH=$(dpkg --print-architecture)
if [[ $MW_DETECTED_ARCH == "arm64" || $MW_DETECTED_ARCH == "arm32" ]]; then
    sudo apt-get remove mw-go-agent-host-arm -y
    sudo rm -rf /usr/local/bin/mw-go-agent-arm/apt
    sudo rm -rf /etc/systemd/system/mwservice.service
    sudo rm -rf /etc/apt/sources.list.d/mw-go-arm.list
    sudo rm -rf /var/lib/apt/lists/host-go.melt.so*
else 
    sdo apt-get remove mw-go-agent-host -y
    sudo rm -rf /usr/local/bin/mw-go-agent/apt
    sudo rm -rf /etc/systemd/system/mwservice.service
    sudo rm -rf /etc/apt/sources.list.d/mw-go.list
    sudo rm -rf /var/lib/apt/lists/host-go.melt.so*
fi

sudo apt-get remove mw-go-agent-host -y

sudo m -rf /usr/local/bin/mw-go-agent/apt
sudo rm -rf /etc/systemd/system/mwservice.service
sudo rm -rf /etc/apt/sources.list.d/mw-go.list
sudo rm -rf /var/lib/apt/lists/host-go.melt.so*
sudo apt-get clean
sudo apt autoremove
sudo crontab -r
sudo apt-get update
# sudo rm -rf /var/lib/apt/lists/apt.melt.so*
# sudo apt-get update