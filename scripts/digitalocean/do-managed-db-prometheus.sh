#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e pipefail

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

    # Get credentials for accessing metrics
    credentials_output=$(curl --silent -XGET --location "https://api.digitalocean.com/v2/databases/metrics/credentials" --header "Content-Type: application/json" --header "Authorization: Bearer $DIGITALOCEAN_API_TOKEN" | jq '.credentials')

    # Check if curl command for credentials was successful
    if [ $? -eq 0 ]; then
        # Parse username and password from curl output
        DATABASE_USERNAME=$(echo "$credentials_output" | jq -r '.basic_auth_username')
        DATABASE_PASSWORD=$(echo "$credentials_output" | jq -r '.basic_auth_password')
    fi

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

# Fetch database UUID, Host, Username, and Password
get_database_details

# Run curl command to fetch crt content
crt_content=$(curl -s -X GET \
          -H "Content-Type: application/json" \
          -H "Authorization: Bearer $DIGITALOCEAN_API_TOKEN" \
          "https://api.digitalocean.com/v2/databases/${DATABASE_UUID}/ca" | jq -r '.ca.certificate')

# Write crt content to corresponding crt file
echo "$crt_content" | base64 -d > "$MW_PROMETHEUS_DIR/${DATABASE_HOST}.crt"
echo "Created $MW_PROMETHEUS_DIR/${DATABASE_HOST}.crt"

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


echo "Prometheus configuration generated for $DATABASE_NAME in $MW_PROMETHEUS_DIR/$PROMETHEUS_CONFIG_FILE"


