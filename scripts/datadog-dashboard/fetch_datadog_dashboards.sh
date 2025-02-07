#!/bin/bash

# Check if curl and jq are installed
if ! command -v curl &>/dev/null || ! command -v jq &>/dev/null; then
    echo "Error: Required commands (curl, jq) are not installed."
    exit 1
fi

# Environment variables
DD_API_KEY="${DD_API_KEY:?Error: DD_API_KEY is not set}"
DD_APP_KEY="${DD_APP_KEY:?Error: DD_APP_KEY is not set}"
DD_BASE_URL="${DD_BASE_URL:-https://api.us5.datadoghq.com}"

# Create directory
mkdir -p datadog_dashboards

# Fetch the list of dashboards
echo "Fetching dashboard list..."
DASHBOARD_LIST=$(curl --silent --show-error --fail --location "$DD_BASE_URL/api/v1/dashboard" \
    --header 'Accept: application/json' \
    --header "DD-API-KEY: $DD_API_KEY" \
    --header "DD-APPLICATION-KEY: $DD_APP_KEY" | jq -r '.dashboards[] | "\(.id),\(.title)"')

# Process each dashboard
echo "$DASHBOARD_LIST" | while IFS=, read -r id title; do
    filename=$(echo "$title" | tr -dc '[:alnum:]._-' | tr ' ' '_')
    echo -n "Downloading $id - $title..."
    
    if curl --silent --show-error --fail --location "$DD_BASE_URL/api/v1/dashboard/$id" \
        --header 'Accept: application/json' \
        --header "DD-API-KEY: $DD_API_KEY" \
        --header "DD-APPLICATION-KEY: $DD_APP_KEY" \
        --output "datadog_dashboards/${filename}.json"; then
        echo " ✅ Done"
    else
        echo " ❌ Failed"
    fi
done
