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
