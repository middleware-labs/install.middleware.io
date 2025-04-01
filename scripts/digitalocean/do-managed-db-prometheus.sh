#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Ensure required environment variables are set
if [[ -z "$DATABASE_NAME" ]]; then
    echo "Error: DATABASE_NAME environment variable is not set."
    exit 1
fi

# Set default value for PROMETHEUS_DIR if not provided
MW_PROMETHEUS_DIR=${MW_PROMETHEUS_DIR:-/etc/prometheus}

# Function to check if a path is absolute
is_absolute_path() {
    case "$1" in
        /*) return 0 ;;  # Absolute path starts with '/'
        *) return 1 ;;  # Relative path
    esac
}

# Check if MW_PROMETHEUS_DIR is an absolute path
if ! is_absolute_path "$MW_PROMETHEUS_DIR"; then
    echo "Error: MW_PROMETHEUS_DIR must be an absolute path. Current value: $MW_PROMETHEUS_DIR"
    exit 1
fi

mkdir -p "$MW_PROMETHEUS_DIR"
echo "Prometheus directory is set to: $MW_PROMETHEUS_DIR"

# If MW_SYSLOG_HOST is not set, use the system's primary IP address
if [[ -z "$MW_SYSLOG_HOST" ]]; then
    MW_SYSLOG_HOST=$(hostname -I | awk '{print $1}')
fi

# If MW_SYSLOG_PORT is not set, then set it to 5514
if [[ -z "$MW_SYSLOG_PORT" ]]; then
    MW_SYSLOG_PORT="5514"
fi

# Prompt user for DigitalOcean Token
echo -n "Enter your DigitalOcean Token: "
read -s DIGITALOCEAN_API_TOKEN

DIGITALOCEAN_API_URL="https://api.digitalocean.com/v2/databases"
PROMETHEUS_CONFIG_FILE="$MW_PROMETHEUS_DIR/prometheus.yml"

# Function to fetch database details from DigitalOcean API
get_database_details() {
    echo -e "\nFetching database details for $DATABASE_NAME from DigitalOcean..."

    DATABASE_INFO=$(curl -s -X GET "$DIGITALOCEAN_API_URL" \
        -H "Authorization: Bearer $DIGITALOCEAN_API_TOKEN" \
        -H "Content-Type: application/json" | jq -r ".databases[] | select(.name == \"$DATABASE_NAME\")")

    DATABASE_UUID=$(echo "$DATABASE_INFO" | jq -r ".id")
    DATABASE_HOST=$(echo "$DATABASE_INFO" | jq -r ".connection.host")
    DATABASE_USERNAME=$(echo "$DATABASE_INFO" | jq -r ".connection.user")
    DATABASE_PASSWORD=$(echo "$DATABASE_INFO" | jq -r ".connection.password")

    if [[ -z "$DATABASE_UUID" || "$DATABASE_UUID" == "null" ]]; then
        echo "Error: Unable to fetch UUID for database: $DATABASE_NAME"
        exit 1
    fi

    if [[ -z "$DATABASE_USERNAME" || "$DATABASE_USERNAME" == "null" ]]; then
        echo "Error: Unable to fetch DATABASE_USERNAME for database: $DATABASE_NAME"
        exit 1
    fi

    if [[ -z "$DATABASE_PASSWORD" || "$DATABASE_PASSWORD" == "null" ]]; then
        echo "Error: Unable to fetch DATABASE_PASSWORD for database: $DATABASE_NAME"
        exit 1
    fi

    echo "Database UUID: $DATABASE_UUID"
    echo "Database Host: $DATABASE_HOST"
    echo "Database Username: $DATABASE_USERNAME"
}

# Function to append content if not already present
append_if_not_exists() {
    local file="$1"
    local content="$2"
    local marker="$3"

    if grep -q "$marker" "$file"; then
        echo "Configuration for $marker already exists in $file. Skipping..."
    else
        echo "Appending configuration for $marker to $file..."
        echo "$content" | sudo tee -a "$file" > /dev/null
    fi
}

# Function to configure DigitalOcean log sink
configure_digitalocean_log_sink() {
    echo "Configuring DigitalOcean log sink for database $DATABASE_UUID..."

    # Check if the log sink is already configured by fetching the current log sinks
    EXISTING_LOG_SINK=$(curl -s -X GET "${DIGITALOCEAN_API_URL}/${DATABASE_UUID}/logsink" \
        -H "Authorization: Bearer ${DIGITALOCEAN_API_TOKEN}" \
        -H "Content-Type: application/json")
    # Extract the log sink ID from the existing sinks if it exists
    LOG_SINK_ID=$(echo "$EXISTING_LOG_SINK" | jq -r '.sinks[]? | select(.sink_name == "middleware.io") | .sink_id')
    # Define the payload for the log sink configuration for PUT (update)
    LOG_SINK_PAYLOAD_PUT=$(jq -n \
        --arg server "$MW_SYSLOG_HOST" \
        --argjson port "$MW_SYSLOG_PORT" \
        '{
            "config": {
                "server": $server,
                "port": $port,
                "tls": false,
                "format": "rfc5424"
            }
        }')

    # Define the payload for the log sink configuration for POST (create)
    LOG_SINK_PAYLOAD_POST=$(jq -n \
        --arg server "$MW_SYSLOG_HOST" \
        --argjson port "$MW_SYSLOG_PORT" \
        '{
            "sink_name": "middleware.io",
            "sink_type": "rsyslog",
            "config": {
                "server": $server,
                "port": $port,
                "tls": false,
                "format": "rfc5424"
            }
        }')

    # If the log sink is already configured, update it using PUT API
    if [[ -n "$LOG_SINK_ID" && "$LOG_SINK_ID" != "null" ]]; then
        echo "Log sink already exists. Updating log sink..."
        RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$DIGITALOCEAN_API_URL/$DATABASE_UUID/logsink/$LOG_SINK_ID" \
            -H "Authorization: Bearer $DIGITALOCEAN_API_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$LOG_SINK_PAYLOAD_PUT")

        if [[ "$RESPONSE" == "200" || "$RESPONSE" == "201" || "$RESPONSE" == "204" ]]; then
            echo "Successfully updated DigitalOcean log sink."
        else
            echo "Error updating log sink. HTTP Status: $RESPONSE"
            exit 1
        fi
    else
        # If the log sink is not configured, create it using POST API
        echo "Log sink not found. Creating new log sink..."
	echo $LOG_SINK_PAYLOAD_POST
        RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$DIGITALOCEAN_API_URL/$DATABASE_UUID/logsink" \
            -H "Authorization: Bearer $DIGITALOCEAN_API_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$LOG_SINK_PAYLOAD_POST")

        if [[ "$RESPONSE" == "200" || "$RESPONSE" == "201" ]]; then
            echo "Successfully created DigitalOcean log sink."
        else
            echo "Error creating log sink. HTTP Status: $RESPONSE"
            exit 1
        fi
    fi
}

# Fetch database UUID, Host, Username, and Password
get_database_details

# Run curl command to fetch crt content
crt_content=$(curl -s -X GET \
	  -H "Content-Type: application/json" \
	  -H "Authorization: Bearer $DIGITALOCEAN_API_TOKEN" \
	  "https://api.digitalocean.com/v2/databases/${DATABASE_UUID}/ca" | jq -r '.ca.certificate')

# Write crt content to corresponding crt file
echo "$crt_content" | base64 -d > "$MW_PROMETHEUS_DIR/${hostname}.crt"
echo "Created $MW_PROMETHEUS_DIR/${hostname}.crt"

# Define Prometheus scrape job
PROMETHEUS_SCRAPE_JOB="
  - job_name: '${DATABASE_HOST}_metrics'
    scheme: https
    tls_config:
      ca_file: ${MW_PROMETHEUS_DIR}/${DATABASE_HOST}.crt
    dns_sd_configs:
    - names:
      - ${DATABASE_HOST}
      type: 'A'
      port: 9273
      refresh_interval: 15s
    metrics_path: '/metrics'
    basic_auth:
      username: ${DATABASE_USERNAME}
      password: ${DATABASE_PASSWORD}
"

# Ensure Prometheus job is added if not present
append_if_not_exists "$PROMETHEUS_CONFIG_FILE" "$PROMETHEUS_SCRAPE_JOB" "job_name: '${DATABASE_HOST}_metrics'"

# Configure DigitalOcean log sink
configure_digitalocean_log_sink

echo "Configuration completed."

