#!/bin/bash
sudo systemctl stop mw-arm-service
sudo systemctl disable mw-arm-service

sudo apt-get remove mw-go-agent-host-arm -y

sudo rm -rf /usr/local/bin/mw-go-agent-arm/apt
sudo rm -rf /etc/systemd/system/mw-arm-service.service
sudo rm -rf /etc/apt/sources.list.d/mw-go-arm.list
sudo rm -rf /var/lib/apt/lists/host-go.melt.so*
sudo apt-get clean
sudo apt autoremove
sudo crontab -r
sudo apt-get update
# sudo rm -rf /var/lib/apt/lists/apt.melt.so*
# sudo apt-get update