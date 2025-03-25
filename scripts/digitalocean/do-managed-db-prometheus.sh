#!/bin/bash
#shellcheck disable=all


# Set default value for PROMETHEUS_DIR if not provided
MW_PROMETHEUS_DIR=${MW_PROMETHEUS_DIR:-/etc/prometheus}

mkdir -p "$MW_PROMETHEUS_DIR"
echo "Prometheus directory is set to: $MW_PROMETHEUS_DIR"

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check dependencies
check_dependencies() {
    local dependencies=("jq")

    echo "Checking dependencies..."

    for dependency in "${dependencies[@]}"; do
        if ! command_exists "$dependency"; then
            echo "Error: $dependency is not installed. Please install it before running this script."
            exit 1
        fi
    done

    echo "All dependencies are installed."
}

# Function to check if a file exists and is readable
check_file_readable() {
    local file="$1"
    if [ ! -r "$file" ]; then
        echo "Error: $file not found or not readable."
        exit 1
    fi
}

# Function to check if a file exists and is writable
check_file_writable() {
    local file="$1"
    if [ ! -w "$file" ]; then
        echo "Error: $file not found or not writable."
        exit 1
    fi
}

# Function to check if a directory exists and is writable
check_dir_writable() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        echo "Creating directory: $dir"
        mkdir -p "$dir"
    fi
}

# Check dependencies
check_dependencies

# Prompt user for type of managed database
echo "Select the type of managed database you want to manage:"
echo "1) MySQL"
echo "2) PostgreSQL"
echo "3) Redis"
echo "4) Kafka"
read -rp "Enter your choice: " DB_TYPE

# Test if token was entered
if [ -z "$DB_TYPE" ]; then
    echo "Error: Database type cannot be empty."
    exit 1
fi

# Prompt user for DigitalOcean Token
echo -n "Enter your DigitalOcean Token: "
read -s DIGITALOCEAN_TOKEN

# Test if token was entered
if [ -z "$DIGITALOCEAN_TOKEN" ]; then
    echo "Error: DigitalOcean Token cannot be empty."
    exit 1
fi

# Filter databases based on selected engine type
case $DB_TYPE in
    1) ENGINE="mysql" ;;
    2) ENGINE="pg" ;;
    3) ENGINE="redis" ;;
    4) ENGINE="kafka" ;;
    *) echo "Error: Invalid choice. Please select a valid option."
       exit 1 ;;
esac

# Check and create certificates folder if it doesn't exist
check_cert_folder() {
    local cert_dir="$MW_PROMETHEUS_DIR/certificates"
    check_dir_writable "$cert_dir"
}

# Clear the file /tmp/dbuuid.txt
> /tmp/dbuuid.txt

# Run curl command to get database information
DATABASE_INFO=$(curl -s -X GET \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $DIGITALOCEAN_TOKEN" \
  "https://api.digitalocean.com/v2/databases")

# Check if curl command was successful
if [ -z "$DATABASE_INFO" ]; then
    echo "Error: No output received from curl command."
    exit 1
fi

# Check if the response contains an error message
ERROR_MSG=$(echo "$DATABASE_INFO" | jq -r '.message')
if [ "$ERROR_MSG" = "Unable to authenticate you" ]; then
    echo -e "\nError: $ERROR_MSG"
    exit 1
elif [ "$ERROR_MSG" = "You are not authorized to perform this operation" ]; then
    echo -e "\nError: $ERROR_MSG"
    exit 1
fi

# Extract database IDs and hostnames based on engine type
DB_IDS_HOSTNAMES=$(echo "$DATABASE_INFO" | jq -r --arg engine "$ENGINE" '.databases[] | select(.engine == $engine) | "\(.connection.host) (\(.id))"')

# Save the formatted data to a file
echo "$DB_IDS_HOSTNAMES" > /tmp/dbuuid.txt

echo "Database IDs and hostnames saved to /tmp/dbuuid.txt"


# Function to add databases to monitoring
add_to_monitoring() {
    echo "Option 1: Add databases to monitoring"

    # Check if /tmp/dbuuid.txt exists and is readable
    check_file_readable "/tmp/dbuuid.txt"

    # Clear the file /tmp/databases_to_monitor.txt
    > /tmp/databases_to_monitor.txt

    # Check if the $MW_PROMETHEUS_DIR/certificates folder exists and create if not
    check_cert_folder

    # Loop through hostnames in /tmp/dbuuid.txt
    while IFS= read -r line; do
        hostname=$(echo "$line" | awk '{print $1}')

        # Check if hostname is already added to prometheus.yml
        if ! grep -qF "$hostname" $MW_PROMETHEUS_DIR/prometheus.yml ; then    
	# If not added, append to /tmp/databases_to_monitor.txt
            echo "$line" >> /tmp/databases_to_monitor.txt
        fi
    done < /tmp/dbuuid.txt

    # Check if there are databases to add
    if [ -s /tmp/databases_to_monitor.txt ]; then
        echo "Select databases to add to monitoring by entering their corresponding numbers:"
        awk '{print NR")", $0}' /tmp/databases_to_monitor.txt
    else
        echo "All the databases are already added to monitoring."
        read -rp "Press Enter to return to the main menu..."

    	return 0
    fi

    # Prompt user to select databases
    read -rp "Enter the serial numbers of databases you want to add to monitoring separated by a single space (e.g., 1 3 4): " -a selected_numbers

    # Check if input is provided
    if [ ${#selected_numbers[@]} -eq 0 ]; then
        echo "No databases selected."
        read -rp "Press Enter to return to the main menu..."

    	return 0
    fi

    # Clear previous Prometheus YAML file
    > /tmp/prom.yml

    # Loop through selected numbers
    for number in "${selected_numbers[@]}"; do
        # Validate input
        if [[ $number =~ ^[0-9]+$ && $number -ge 1 && $number -le $(wc -l < /tmp/databases_to_monitor.txt) ]]; then
            # Get corresponding database information
            database_info=$(sed -n "${number}p" /tmp/databases_to_monitor.txt)
            hostname=$(echo "$database_info" | awk '{print $1}')
            uuid=$(echo "$database_info" | awk '{print $2}')

            # Run curl command to fetch crt content
            crt_content=$(curl -s -X GET \
                          -H "Content-Type: application/json" \
                          -H "Authorization: Bearer $DIGITALOCEAN_TOKEN" \
                          "https://api.digitalocean.com/v2/databases/${uuid}/ca" | jq -r '.ca.certificate')

            # Write crt content to corresponding crt file
            echo "$crt_content" | base64 -d > "$MW_PROMETHEUS_DIR/certificates/${hostname}.crt"
            echo "Created $MW_PROMETHEUS_DIR/certificates/${hostname}.crt"


# Run curl command to get hostname and port
curl_output=$(curl --silent -XGET --location "https://api.digitalocean.com/v2/databases/$uuid" --header "Content-Type: application/json" --header "Authorization: Bearer $DIGITALOCEAN_TOKEN")


# Parse hostname and port from curl output, filtering out replicas
host_port=$(echo "$curl_output" | jq -r '.database.metrics_endpoints[] | select(.host | startswith("replica") | not) | "\(.host) \(.port)"')


                    # Get credentials for accessing metrics
                    credentials_output=$(curl --silent -XGET --location "https://api.digitalocean.com/v2/databases/metrics/credentials" --header "Content-Type: application/json" --header "Authorization: Bearer $DIGITALOCEAN_TOKEN" | jq '.credentials')

                    # Check if curl command for credentials was successful
                    if [ $? -eq 0 ]; then
                        # Parse username and password from curl output
                        username=$(echo "$credentials_output" | jq -r '.basic_auth_username')
                        password=$(echo "$credentials_output" | jq -r '.basic_auth_password')
			host=$(echo "$host_port" | awk '{print $1}')
			port=$(echo "$host_port" | awk '{print $2}')
                    # Generate Prometheus YAML configuration for this database
                        cat <<EOF >> /tmp/prom.yml
  - job_name: '${hostname}_metrics'
    scheme: https
    tls_config:
      ca_file: $MW_PROMETHEUS_DIR/certificates/${hostname}.crt
    dns_sd_configs:
    - names:
      - $host
      type: 'A'
      port: $port
      refresh_interval: 15s
    metrics_path: '/metrics'
    basic_auth:
      username: $username
      password: $password
EOF
                        echo "Prometheus YAML configuration generated for database $hostname (ID: $uuid)"
                    else
                        echo "Failed to retrieve credentials for database $hostname (ID: $uuid)"
                    fi
                #done <<< "$curl_output"
            else
                echo "Failed to retrieve metrics information for database $hostname (ID: $uuid)"
            fi
     #       echo "Invalid selection: $number"
    done

    # Backup prometheus.yml file
    local backup_file="$MW_PROMETHEUS_DIR/prometheus.yml-$(date +'%d%b%Y-%H:%M')"
    if [ -f "$MW_PROMETHEUS_DIR/prometheus.yml" ]; then
    	cp "$MW_PROMETHEUS_DIR/prometheus.yml" "$backup_file"
        echo "Backup of Prometheus configuration created: $backup_file"
    fi

    # Append contents of prom.yml to prometheus.yml
    cat /tmp/prom.yml >> $MW_PROMETHEUS_DIR/prometheus.yml

    # Exit to main menu
    read -rp "Press Enter to return to the main menu..."

    return 0
}

# Function to remove databases from monitoring
remove_from_monitoring() {
    echo "Option 2: Remove databases from monitoring"

    # Check if /tmp/dbuuid.txt exists and is readable
    check_file_readable "/tmp/dbuuid.txt"

    # Clear the file /tmp/databases_to_remove.txt
    > /tmp/databases_to_remove.txt

    # Loop through hostnames in /tmp/dbuuid.txt
    while IFS= read -r line; do
        hostname=$(echo "$line" | awk '{print $1}')

        # Check if hostname is already present in prometheus.yml
	if grep -qF "$hostname" $MW_PROMETHEUS_DIR/prometheus.yml ; then	
            # If present, append to /tmp/databases_to_remove.txt
            echo "$line" >> /tmp/databases_to_remove.txt
        fi
    done < /tmp/dbuuid.txt

    # Check if there are databases to remove
    if [ -s /tmp/databases_to_remove.txt ]; then
        echo "Select databases to remove from monitoring by entering their corresponding numbers:"
        awk '{print NR")", $0}' /tmp/databases_to_remove.txt
    else
        echo "No databases to remove from monitoring."
        read -rp "Press Enter to return to the main menu..."

    	return 0
    fi

    # Prompt user to select databases
    read -rp "Enter the serial numbers of databases you want to remove from monitoring separated by a single space (e.g., 3 4): " -a selected_numbers

    # Check if input is provided
    if [ ${#selected_numbers[@]} -eq 0 ]; then
        echo "No databases selected."
        read -rp "Press Enter to return to the main menu..."

    	return 0
    fi

    # Backup prometheus.yml file
    local backup_file="$MW_PROMETHEUS_DIR/prometheus.yml-$(date +'%d%b%Y-%H:%M')"
    cp $MW_PROMETHEUS_DIR/prometheus.yml "$backup_file"
    echo "Backup of Prometheus configuration created: $backup_file"

    # Loop through selected numbers
    for number in "${selected_numbers[@]}"; do
        # Validate input
        if [[ $number =~ ^[0-9]+$ && $number -ge 1 && $number -le $(wc -l < /tmp/databases_to_remove.txt) ]]; then
            # Get corresponding database entry
            database_info=$(sed -n "${number}p" /tmp/databases_to_remove.txt)
            hostname=$(echo "$database_info" | awk '{print $1}')

            # Remove entries from prometheus.yml
            sed -i "/- job_name: '$hostname\_metrics'/,/password:/d" $MW_PROMETHEUS_DIR/prometheus.yml

	    echo "Removed monitoring configuration for database: $hostname"
        else
            echo "Invalid selection: $number"
        fi
    done

    # Exit to main menu
    read -rp "Press Enter to return to the main menu..."

    return 0
}

# Function to print all database clusters
print_all_clusters() {
    echo "Option 3: Print all database clusters"

    # Check if /tmp/dbuuid.txt exists and is readable
    check_file_readable "/tmp/dbuuid.txt"

    # Check if there are clusters to print
    if [ ! -s "/tmp/dbuuid.txt" ]; then
        echo "No database clusters found."
        read -rp "Press Enter to return to the main menu..."

    	return 0
    fi

    echo "Available database clusters:"
    # Print contents of /tmp/dbuuid.txt
    awk '{print NR")", $0}' /tmp/dbuuid.txt

    # Exit to main menu
    read -rp "Press Enter to return to the main menu..."

    return 0
}

# Main menu
while true; do
    echo "Main Menu:"
    echo "1) Add databases to monitoring"
    echo "2) Remove databases from monitoring"
    echo "3) Print all database clusters"
    echo "4) Exit"
    read -rp "Please select an option: " option
    case $option in
        1) add_to_monitoring ;;
        2) remove_from_monitoring ;;
        3) print_all_clusters ;;
        4) exit ;;
        *) echo "Invalid option. Please select a valid option." ;;
    esac
done

