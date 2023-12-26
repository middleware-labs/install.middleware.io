#!/bin/bash

MW_AGENT_HOME="/etc/mw-agent"

# Function to install Middleware Agent
install_middleware_agent() {
    echo "Downloading Middleware Agent DEB file..."
    wget -O mw-agent_1.0.0-1_amd64.deb https://github.com/middleware-labs/mw-agent/releases/download/1.0.0/mw-agent_1.0.0-1_amd64.deb

    echo "Installing Middleware Agent..."
    sudo dpkg -i mw-agent_1.0.0-1_amd64.deb
}

# Function to configure and run Middleware Agent
configure_and_run_middleware_agent() {
    echo "Configuring Middleware Agent..."
    
    if [ -x "$(command -v systemctl)" ]; then
        # System has systemd
        echo "System has systemd. Configuring Middleware Agent using systemd..."
        sudo tee /etc/systemd/system/mwservice.service > /dev/null <<EOF
[Unit]
Description=Melt daemon!

[Service]
WorkingDirectory=/usr/bin
ExecStart=/usr/bin/mw-agent start --api-key $MW_API_KEY --target $MW_TARGET
Type=simple
TimeoutStopSec=10
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

        echo "Enabling and starting Middleware Agent service..."
        sudo systemctl daemon-reload
        sudo systemctl enable mwservice
        sudo systemctl start mwservice
    else
        mkdir -p $MW_AGENT_HOME/apt
        touch $MW_AGENT_HOME/apt/executable
        cat << EOEXECUTABLE > $MW_AGENT_HOME/apt/executable
#!/bin/sh
mw-agent start --api-key $MW_API_KEY --target $MW_TARGET
EOEXECUTABLE

        # System does not have systemd
        echo "System does not have systemd. Configuring Middleware Agent using older init system..."
        sudo tee /etc/init/mwservice.conf > /dev/null <<EOF
start on startup
stop on shutdown

# Automatically respawn the service if it dies
respawn
respawn limit 5 60

# Start the service by running the executable script
script
    exec bash $MW_AGENT_HOME/apt/executable
end script
EOF

        echo "Enabling and starting Middleware Agent service..."
        sudo start mwservice
    fi
}

# Function to uninstall Middleware Agent
uninstall_middleware_agent() {
    echo "Uninstalling Middleware Agent..."
    sudo dpkg -r mw-agent
}

# Main script
echo "=== Middleware Agent Installation Script ==="

# Install Middleware Agent
install_middleware_agent

# Configure and run Middleware Agent
configure_and_run_middleware_agent

echo "Middleware Agent is installed, configured, and running."

# Uncomment the next line if you want to uninstall the Middleware Agent
# uninstall_middleware_agent

echo "Script execution completed."
