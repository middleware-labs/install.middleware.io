#!/usr/bin/env bash
# otel-system-wide-java-extended.sh
# Install OpenTelemetry Java agent for host JVMs, provide docker-run wrapper,
# and patch Kubernetes controllers to inject agent into Java containers.
#
# Must be run as root when performing system changes.
# shellcheck disable=SC2317
set -euo pipefail

# Defaults (override by exporting before running)
OTEL_DIR="${OTEL_DIR:-/usr/lib/opentelemetry}"
AGENT_NAME="${AGENT_NAME:-opentelemetry-javaagent.jar}"
AGENT_PATH="$OTEL_DIR/$AGENT_NAME"
# AGENT_URL="${AGENT_URL:-https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/latest/download/opentelemetry-javaagent.jar}"
AGENT_URL="${AGENT_URL:-https://github.com/middleware-labs/opentelemetry-java-instrumentation/releases/download/v1.8.1/middleware-javaagent.jar}"
# OpenTelemetry Configuration (can be overridden by environment variables)
OTEL_EXPORTER_OTLP_ENDPOINT="${OTEL_EXPORTER_OTLP_ENDPOINT:-https://sandbox.middleware.io:443}"
OTEL_EXPORTER_OTLP_HEADERS="${OTEL_EXPORTER_OTLP_HEADERS:-authorization=5xrocjh0p5ir233mvi34dvl5bepnyqri3rqb}"
OTEL_SERVICE_NAME="${OTEL_SERVICE_NAME:-}"
OTEL_RESOURCE_ATTRIBUTES="${OTEL_RESOURCE_ATTRIBUTES:-}"
OTEL_TRACES_EXPORTER="${OTEL_TRACES_EXPORTER:-otlp}"
OTEL_METRICS_EXPORTER="${OTEL_METRICS_EXPORTER:-otlp}"
OTEL_LOGS_EXPORTER="${OTEL_LOGS_EXPORTER:-otlp}"

FORCE="${FORCE:-0}"
DRY_RUN="${DRY_RUN:-0}"    # if 1, don't apply changes (for Kubernetes patches)
K8S_NAMESPACE="${K8S_NAMESPACE:-all}" # or single namespace
DOCKER_WRAPPER_PATH="${DOCKER_WRAPPER_PATH:-/usr/local/bin/docker-run-otel}"
AUTO_UPDATE_SERVICES="${AUTO_UPDATE_SERVICES:-1}"  # if 1, automatically update existing Java services

# helper
err() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "INFO: $*"; }
warn() { echo "WARN: $*"; }

# Function to detect Java services
detect_java_services() {
  local services=()
  for service in $(systemctl list-units --type=service --state=active --no-pager --no-legend | awk '{print $1}' | grep -E '\.(service)$'); do
    # Check if service runs Java
    local exec_start
    exec_start=$(systemctl show "$service" --property=ExecStart --no-pager 2>/dev/null | cut -d'=' -f2- | tr -d '"')
    if echo "$exec_start" | grep -q "java"; then
      services+=("$service")
    fi
  done
  echo "${services[@]}"
}

# Function to detect Java Docker containers
detect_java_containers() {
  local containers=()
  for container in $(docker ps --format "{{.Names}}" 2>/dev/null); do
    # Check if container runs Java
    local command
    command=$(docker inspect "$container" --format '{{.Config.Cmd}}' 2>/dev/null)
    if echo "$command" | grep -q "java"; then
      containers+=("$container")
    fi
  done
  echo "${containers[@]}"
}

# Function to get container configuration for restart
get_container_config() {
  local container="$1"
  local image
  image=$(docker inspect "$container" --format '{{.Config.Image}}' 2>/dev/null)
  
  # Get ports in a safer way
  local ports=""
  docker port "$container" 2>/dev/null | while read -r line; do
    if [ -n "$line" ]; then
      local host_port
      local container_port
      host_port=$(echo "$line" | awk -F: '{print $2}')
      container_port=$(echo "$line" | awk -F: '{print $1}')
      ports="$ports -p $host_port:$container_port"
    fi
  done
  
  local env_vars
  local volumes
  local working_dir
  local command
  env_vars=$(docker inspect "$container" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep -v "^$" | sed 's/^/-e /' | tr '\n' ' ')
  volumes=$(docker inspect "$container" --format '{{range .Mounts}}{{print .Source ":" .Destination "\n"}}{{end}}' 2>/dev/null | grep -v "^$" | sed 's/^/-v /' | tr '\n' ' ')
  working_dir=$(docker inspect "$container" --format '{{.Config.WorkingDir}}' 2>/dev/null)
  command=$(docker inspect "$container" --format '{{.Config.Cmd}}' 2>/dev/null | tr -d '[]')
  
  echo "IMAGE=$image"
  echo "PORTS=\"$ports\""
  echo "ENV_VARS=\"$env_vars\""
  echo "VOLUMES=\"$volumes\""
  echo "WORKING_DIR=$working_dir"
  echo "COMMAND=\"$command\""
}

# Function to update Docker containers with OTEL wrapper
update_docker_containers() {
  if [ "$AUTO_UPDATE_SERVICES" != "1" ]; then
    info "AUTO_UPDATE_SERVICES is disabled, skipping Docker container updates"
    return 0
  fi
  
  info "Detecting Java Docker containers..."
  local java_containers
  mapfile -t java_containers < <(detect_java_containers)
  
  if [ ${#java_containers[@]} -eq 0 ]; then
    info "No running Java containers detected"
    return 0
  fi
  
  info "Found Java containers: ${java_containers[*]}"
  
  for container in "${java_containers[@]}"; do
    info "Processing container: $container"
    update_docker_container "$container"
  done
}

# Function to update a specific Docker container
update_docker_container() {
  local container="$1"
  
  # Check if container already has complete OTEL configuration
  local has_endpoint
  local has_service_name
  local has_java_tool_options
  has_endpoint=$(docker exec "$container" env 2>/dev/null | grep -q "OTEL_EXPORTER_OTLP_ENDPOINT" && echo "yes" || echo "no")
  has_service_name=$(docker exec "$container" env 2>/dev/null | grep -q "OTEL_SERVICE_NAME" && echo "yes" || echo "no")
  has_java_tool_options=$(docker exec "$container" env 2>/dev/null | grep -q "JAVA_TOOL_OPTIONS" && echo "yes" || echo "no")
  
  if [ "$has_endpoint" = "yes" ] && [ "$has_service_name" = "yes" ] && [ "$has_java_tool_options" = "yes" ]; then
    info "Container $container already has complete OTEL configuration"
    return 0
  elif [ "$has_endpoint" = "yes" ] && [ "$has_java_tool_options" = "no" ]; then
    info "Container $container missing JAVA_TOOL_OPTIONS, updating configuration"
  elif [ "$has_endpoint" = "yes" ] && [ "$has_service_name" = "no" ]; then
    info "Container $container has partial OTEL configuration, updating service name"
  else
    info "Container $container needs OTEL configuration"
  fi
  
  info "Updating container: $container"
  
  # Get basic container info
  local image
  image=$(docker inspect "$container" --format '{{.Config.Image}}' 2>/dev/null)
  
  # Get port mapping in a simpler way
  local ports=""
  local port_line
  port_line=$(docker port "$container" 2>/dev/null | head -1)
  if [ -n "$port_line" ]; then
    # Parse format like "9090/tcp -> 0.0.0.0:8082"
    local host_port
    local container_port
    host_port=$(echo "$port_line" | awk -F: '{print $2}')
    container_port=$(echo "$port_line" | awk '{print $1}' | awk -F/ '{print $1}')
    ports="-p $host_port:$container_port"
  fi
  
  # Create new container name
  local new_name="${container}-otel"
  
  # Use container name as service name (remove any suffixes like -otel)
  local service_name="${container%-otel}"
  
  # Stop the old container
  info "Stopping container: $container"
  docker stop "$container" >/dev/null 2>&1
  
  # Build docker-run-otel command with basic configuration
  local docker_cmd="docker-run-otel"
  
  # Add ports if available
  if [ -n "$ports" ]; then
    docker_cmd="$docker_cmd $ports"
  fi
  
  # Add service name environment variable
  docker_cmd="$docker_cmd -e OTEL_SERVICE_NAME=$service_name"
  
  # Add image and name
  docker_cmd="$docker_cmd --name $new_name $image"
  
  info "Starting container with OTEL instrumentation: $new_name"
  info "Service name will be: $service_name"
  info "Command: $docker_cmd"
  
  # Execute the command in background to ensure detached mode
  eval "$docker_cmd" &
  
  # Wait a moment for container to start
  sleep 3
  
  # Check if container is running
  if docker ps --format "{{.Names}}" | grep -q "^${new_name}$"; then
    info "✓ Successfully restarted container with OTEL instrumentation: $new_name"
    info "✓ Service name set to: $service_name"
    # Remove old container
    docker rm "$container" >/dev/null 2>&1
  else
    warn "Failed to restart container with OTEL instrumentation"
    # Restart original container
    docker start "$container" >/dev/null 2>&1
  fi
}

# Function to update existing Java services
update_java_services() {
  if [ "$AUTO_UPDATE_SERVICES" != "1" ]; then
    info "AUTO_UPDATE_SERVICES is disabled, skipping service updates"
    return 0
  fi
  
  info "Detecting existing Java services..."
  local java_services
  mapfile -t java_services < <(detect_java_services)
  
  if [ ${#java_services[@]} -eq 0 ]; then
    info "No running Java services detected"
    return 0
  fi
  
  info "Found Java services: ${java_services[*]}"
  
  for service in "${java_services[@]}"; do
    info "Updating service: $service"
    update_service_config "$service"
  done
}

# Function to update a specific service configuration
update_service_config() {
  local service="$1"
  local service_file="/etc/systemd/system/${service}"
  
  if [ ! -f "$service_file" ]; then
    warn "Service file not found: $service_file"
    return 1
  fi
  
  # Check if service already has OTEL configuration
  if grep -q "OTEL_EXPORTER_OTLP_ENDPOINT" "$service_file"; then
    info "Service $service already has OTEL configuration"
    return 0
  fi
  
  # Create backup
  cp "$service_file" "${service_file}.backup.$(date +%Y%m%d_%H%M%S)"
  info "Created backup: ${service_file}.backup.$(date +%Y%m%d_%H%M%S)"
  
  # Add OTEL environment variables to service file in the [Service] section
  local temp_file
  temp_file=$(mktemp)
  
  # Process the service file line by line
  local in_service_section=false
  local env_added=false
  
  while IFS= read -r line; do
    # Check if we're entering the [Service] section
    if [[ "$line" == "[Service]" ]]; then
      in_service_section=true
      echo "$line" >> "$temp_file"
      continue
    fi
    
    # Check if we're leaving the [Service] section
    if [[ "$line" == "["*"]" ]] && [[ "$line" != "[Service]" ]]; then
      # If we're leaving the [Service] section and haven't added env vars yet, add them now
      if [ "$in_service_section" = true ] && [ "$env_added" = false ]; then
        {
          echo ""
          echo "# OpenTelemetry instrumentation (auto-added)"
          echo "Environment=JAVA_TOOL_OPTIONS=-javaagent:${AGENT_PATH}"
          echo "Environment=OTEL_EXPORTER_OTLP_ENDPOINT=${OTEL_EXPORTER_OTLP_ENDPOINT}"
          echo "Environment=OTEL_EXPORTER_OTLP_HEADERS=${OTEL_EXPORTER_OTLP_HEADERS}"
          echo "Environment=OTEL_TRACES_EXPORTER=${OTEL_TRACES_EXPORTER}"
          echo "Environment=OTEL_METRICS_EXPORTER=${OTEL_METRICS_EXPORTER}"
          echo "Environment=OTEL_LOGS_EXPORTER=${OTEL_LOGS_EXPORTER}"
        } >> "$temp_file"
        if [ -n "${OTEL_SERVICE_NAME:-}" ]; then
          echo "Environment=OTEL_SERVICE_NAME=${OTEL_SERVICE_NAME}" >> "$temp_file"
        fi
        if [ -n "${OTEL_RESOURCE_ATTRIBUTES:-}" ]; then
          echo "Environment=OTEL_RESOURCE_ATTRIBUTES=${OTEL_RESOURCE_ATTRIBUTES}" >> "$temp_file"
        fi
        env_added=true
      fi
      in_service_section=false
    fi
    
    # If we're in the [Service] section and this is the last line before [Install], add env vars
    if [ "$in_service_section" = true ] && [ "$env_added" = false ]; then
      # Check if this is the last line of the [Service] section (empty line or next section)
      if [[ -z "$line" ]] || [[ "$line" == "["*"]" ]]; then
        {
          echo ""
          echo "# OpenTelemetry instrumentation (auto-added)"
          echo "Environment=JAVA_TOOL_OPTIONS=-javaagent:${AGENT_PATH}"
          echo "Environment=OTEL_EXPORTER_OTLP_ENDPOINT=${OTEL_EXPORTER_OTLP_ENDPOINT}"
          echo "Environment=OTEL_EXPORTER_OTLP_HEADERS=${OTEL_EXPORTER_OTLP_HEADERS}"
          echo "Environment=OTEL_TRACES_EXPORTER=${OTEL_TRACES_EXPORTER}"
          echo "Environment=OTEL_METRICS_EXPORTER=${OTEL_METRICS_EXPORTER}"
          echo "Environment=OTEL_LOGS_EXPORTER=${OTEL_LOGS_EXPORTER}"
        } >> "$temp_file"
        if [ -n "${OTEL_SERVICE_NAME:-}" ]; then
          echo "Environment=OTEL_SERVICE_NAME=${OTEL_SERVICE_NAME}" >> "$temp_file"
        fi
        if [ -n "${OTEL_RESOURCE_ATTRIBUTES:-}" ]; then
          echo "Environment=OTEL_RESOURCE_ATTRIBUTES=${OTEL_RESOURCE_ATTRIBUTES}" >> "$temp_file"
        fi
        env_added=true
      fi
    fi
    
    echo "$line" >> "$temp_file"
  done < "$service_file"
  
  # If we're still in the [Service] section at the end of the file, add env vars
  if [ "$in_service_section" = true ] && [ "$env_added" = false ]; then
    {
      echo ""
      echo "# OpenTelemetry instrumentation (auto-added)"
      echo "Environment=JAVA_TOOL_OPTIONS=-javaagent:${AGENT_PATH}"
      echo "Environment=OTEL_EXPORTER_OTLP_ENDPOINT=${OTEL_EXPORTER_OTLP_ENDPOINT}"
      echo "Environment=OTEL_EXPORTER_OTLP_HEADERS=${OTEL_EXPORTER_OTLP_HEADERS}"
      echo "Environment=OTEL_TRACES_EXPORTER=${OTEL_TRACES_EXPORTER}"
      echo "Environment=OTEL_METRICS_EXPORTER=${OTEL_METRICS_EXPORTER}"
      echo "Environment=OTEL_LOGS_EXPORTER=${OTEL_LOGS_EXPORTER}"
    } >> "$temp_file"
    if [ -n "${OTEL_SERVICE_NAME:-}" ]; then
      echo "Environment=OTEL_SERVICE_NAME=${OTEL_SERVICE_NAME}" >> "$temp_file"
    fi
    if [ -n "${OTEL_RESOURCE_ATTRIBUTES:-}" ]; then
      echo "Environment=OTEL_RESOURCE_ATTRIBUTES=${OTEL_RESOURCE_ATTRIBUTES}" >> "$temp_file"
    fi
  fi
  
  # Replace the original file with the new one
  mv "$temp_file" "$service_file"
  
  info "Updated service configuration: $service"
  
  # Reload systemd and restart service
  systemctl daemon-reload
  if systemctl is-active --quiet "$service"; then
    info "Restarting service: $service"
    systemctl restart "$service"
  fi
}

# Function to instrument a specific service
instrument_service() {
  local service_name="$1"
  
  if [ -z "$service_name" ]; then
    err "Service name is required"
    return 1
  fi
  
  info "Adding OTEL instrumentation to service: $service_name"
  
  # Check if service exists and is running
  if ! systemctl is-active --quiet "$service_name" 2>/dev/null; then
    err "Service $service_name is not running or does not exist"
    return 1
  fi
  
  # Check if service is already instrumented
  local env_output
  env_output=$(systemctl show "$service_name" --property=Environment --no-pager 2>/dev/null)
  if echo "$env_output" | grep -q "OTEL_EXPORTER_OTLP_ENDPOINT"; then
    info "Service $service_name is already instrumented"
    return 0
  fi
  
  # Create backup of service file
  local service_file="/etc/systemd/system/$service_name"
  if [ -f "$service_file" ]; then
    cp "$service_file" "${service_file}.backup.$(date +%Y%m%d_%H%M%S)"
    info "Created backup: ${service_file}.backup.$(date +%Y%m%d_%H%M%S)"
  fi
  
  # Add OTEL environment variables to service file
  if [ -f "$service_file" ]; then
    # Create a temporary file to build the new service file
    local temp_file
  temp_file=$(mktemp)
    
    # Process the service file line by line
    local in_service_section=false
    local env_added=false
    
    while IFS= read -r line; do
      # Check if we're entering the [Service] section
      if [[ "$line" == "[Service]" ]]; then
        in_service_section=true
        echo "$line" >> "$temp_file"
        continue
      fi
      
      # Check if we're leaving the [Service] section
      if [[ "$line" == "["*"]" ]] && [[ "$line" != "[Service]" ]]; then
        # If we're leaving the [Service] section and haven't added env vars yet, add them now
        if [ "$in_service_section" = true ] && [ "$env_added" = false ]; then
          {
            echo "Environment=JAVA_TOOL_OPTIONS=-javaagent:${AGENT_PATH}"
            echo "Environment=OTEL_EXPORTER_OTLP_ENDPOINT=${OTEL_EXPORTER_OTLP_ENDPOINT}"
            echo "Environment=OTEL_EXPORTER_OTLP_HEADERS=${OTEL_EXPORTER_OTLP_HEADERS}"
            echo "Environment=OTEL_TRACES_EXPORTER=${OTEL_TRACES_EXPORTER}"
            echo "Environment=OTEL_METRICS_EXPORTER=${OTEL_METRICS_EXPORTER}"
            echo "Environment=OTEL_LOGS_EXPORTER=${OTEL_LOGS_EXPORTER}"
          } >> "$temp_file"
          if [ -n "${OTEL_SERVICE_NAME:-}" ]; then
            echo "Environment=OTEL_SERVICE_NAME=${OTEL_SERVICE_NAME}" >> "$temp_file"
          fi
          if [ -n "${OTEL_RESOURCE_ATTRIBUTES:-}" ]; then
            echo "Environment=OTEL_RESOURCE_ATTRIBUTES=${OTEL_RESOURCE_ATTRIBUTES}" >> "$temp_file"
          fi
          env_added=true
        fi
        in_service_section=false
      fi
      
      # If we're in the [Service] section and this is the last line before [Install], add env vars
      if [ "$in_service_section" = true ] && [ "$env_added" = false ]; then
        # Check if this is the last line of the [Service] section (empty line or next section)
        if [[ -z "$line" ]] || [[ "$line" == "["*"]" ]]; then
          {
            echo "Environment=JAVA_TOOL_OPTIONS=-javaagent:${AGENT_PATH}"
            echo "Environment=OTEL_EXPORTER_OTLP_ENDPOINT=${OTEL_EXPORTER_OTLP_ENDPOINT}"
            echo "Environment=OTEL_EXPORTER_OTLP_HEADERS=${OTEL_EXPORTER_OTLP_HEADERS}"
            echo "Environment=OTEL_TRACES_EXPORTER=${OTEL_TRACES_EXPORTER}"
            echo "Environment=OTEL_METRICS_EXPORTER=${OTEL_METRICS_EXPORTER}"
            echo "Environment=OTEL_LOGS_EXPORTER=${OTEL_LOGS_EXPORTER}"
          } >> "$temp_file"
          if [ -n "${OTEL_SERVICE_NAME:-}" ]; then
            echo "Environment=OTEL_SERVICE_NAME=${OTEL_SERVICE_NAME}" >> "$temp_file"
          fi
          if [ -n "${OTEL_RESOURCE_ATTRIBUTES:-}" ]; then
            echo "Environment=OTEL_RESOURCE_ATTRIBUTES=${OTEL_RESOURCE_ATTRIBUTES}" >> "$temp_file"
          fi
          env_added=true
        fi
      fi
      
      echo "$line" >> "$temp_file"
    done < "$service_file"
    
    # If we're still in the [Service] section at the end of the file, add env vars
    if [ "$in_service_section" = true ] && [ "$env_added" = false ]; then
      {
        echo "Environment=JAVA_TOOL_OPTIONS=-javaagent:${AGENT_PATH}"
        echo "Environment=OTEL_EXPORTER_OTLP_ENDPOINT=${OTEL_EXPORTER_OTLP_ENDPOINT}"
        echo "Environment=OTEL_EXPORTER_OTLP_HEADERS=${OTEL_EXPORTER_OTLP_HEADERS}"
        echo "Environment=OTEL_TRACES_EXPORTER=${OTEL_TRACES_EXPORTER}"
        echo "Environment=OTEL_METRICS_EXPORTER=${OTEL_METRICS_EXPORTER}"
        echo "Environment=OTEL_LOGS_EXPORTER=${OTEL_LOGS_EXPORTER}"
      } >> "$temp_file"
      if [ -n "${OTEL_SERVICE_NAME:-}" ]; then
        echo "Environment=OTEL_SERVICE_NAME=${OTEL_SERVICE_NAME}" >> "$temp_file"
      fi
      if [ -n "${OTEL_RESOURCE_ATTRIBUTES:-}" ]; then
        echo "Environment=OTEL_RESOURCE_ATTRIBUTES=${OTEL_RESOURCE_ATTRIBUTES}" >> "$temp_file"
      fi
    fi
    
    # Replace the original file with the new one
    mv "$temp_file" "$service_file"
    info "Added OTEL environment variables to $service_file"
  fi
  
  # Reload systemd and restart service
  systemctl daemon-reload
  systemctl restart "$service_name"
  
  if systemctl is-active --quiet "$service_name"; then
    info "✓ Successfully added OTEL instrumentation to $service_name"
  else
    err "Failed to restart service $service_name after adding instrumentation"
    return 1
  fi
}

# Function to instrument a specific container
instrument_container() {
  local container_name="$1"
  
  if [ -z "$container_name" ]; then
    err "Container name is required"
    return 1
  fi
  
  info "Adding OTEL instrumentation to container: $container_name"
  
  # Check if container exists and is running
  if ! docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
    err "Container $container_name is not running or does not exist"
    return 1
  fi
  
  # Check if container is already instrumented
  local has_endpoint
  has_endpoint=$(docker exec "$container_name" env 2>/dev/null | grep -q "OTEL_EXPORTER_OTLP_ENDPOINT" && echo "yes" || echo "no")
  if [ "$has_endpoint" = "yes" ]; then
    info "Container $container_name is already instrumented"
    return 0
  fi
  
  # Get container configuration with better error handling
  info "Getting container image..."
  local image
  if ! image=$(timeout 15 docker inspect "$container_name" --format '{{.Config.Image}}' 2>&1); then
    err "Failed to get image for container $container_name (timeout or error)"
    return 1
  fi
  if [ -z "$image" ]; then
    err "Failed to get image for container $container_name (empty result)"
    return 1
  fi
  info "Container image: $image"
  
  # Get port mapping with better error handling
  info "Getting port mapping for container: $container_name"
  local ports=""
  local port_output
  if port_output=$(timeout 15 docker port "$container_name" 2>&1); then
    info "Port output: $port_output"
    if [ -n "$port_output" ]; then
      # Parse all port mappings, not just the first one
      while IFS= read -r port_line; do
        if [ -n "$port_line" ]; then
          local host_port
          local container_port
          # Parse format like "9090/tcp -> 0.0.0.0:8082"
          if [[ "$port_line" == *"->"* ]]; then
            host_port=$(echo "$port_line" | awk -F: '{print $2}')
            container_port=$(echo "$port_line" | awk '{print $1}' | awk -F/ '{print $1}')
            if [ -n "$host_port" ] && [ -n "$container_port" ]; then
              ports="$ports -p $host_port:$container_port"
              info "Found port mapping: $host_port:$container_port"
            fi
          fi
        fi
      done <<< "$port_output"
    fi
  else
    warn "Failed to get port mapping for container $container_name (timeout or error)"
  fi
  info "Final ports: $ports"
  
  # Get environment variables (excluding OTEL ones) with better error handling
  info "Getting environment variables for container: $container_name"
  local env_vars=""
  local env_output
  if env_output=$(timeout 15 docker inspect "$container_name" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>&1); then
    info "Environment output length: ${#env_output}"
    if [ -n "$env_output" ]; then
      env_vars=$(echo "$env_output" | grep -v "^$" | grep -v "OTEL_" | grep -v "JAVA_TOOL_OPTIONS" | while read -r env_var; do
        if [ -n "$env_var" ]; then
          echo "-e $env_var"
        fi
      done | tr '\n' ' ')
    fi
  else
    warn "Failed to get environment variables for container $container_name (timeout or error)"
  fi
  info "Final env_vars: $env_vars"
  
  # Get volumes (excluding OTEL agent volume) with better error handling
  info "Getting volume information for container: $container_name"
  local volumes=""
  local volume_output
  if volume_output=$(timeout 15 docker inspect "$container_name" --format '{{range .Mounts}}{{print .Source ":" .Destination "\n"}}{{end}}' 2>&1); then
    info "Volume output length: ${#volume_output}"
    info "Volume output: $volume_output"
    if [ -n "$volume_output" ]; then
      # Process volumes line by line to avoid hanging
      while IFS= read -r volume_line; do
        if [ -n "$volume_line" ] && [[ "$volume_line" != *":/otel"* ]]; then
          volumes="$volumes -v $volume_line"
          info "Added volume: $volume_line"
        fi
      done <<< "$volume_output"
    fi
  else
    warn "Failed to get volume information for container $container_name (timeout or error)"
  fi
  info "Final volumes: $volumes"
  
  # Get working directory
  info "Getting working directory for container: $container_name"
  local working_dir
  if ! working_dir=$(timeout 15 docker inspect "$container_name" --format '{{.Config.WorkingDir}}' 2>&1); then
    warn "Failed to get working directory for container $container_name (timeout or error)"
    working_dir=""
  fi
  info "Working directory: $working_dir"
  
  # Get command
  info "Getting command for container: $container_name"
  local command
  if ! command=$(timeout 15 docker inspect "$container_name" --format '{{.Config.Cmd}}' 2>&1 | tr -d '[]' | tr ',' ' '); then
    warn "Failed to get command for container $container_name (timeout or error)"
    command=""
  fi
  info "Command: $command"
  
  # Create new container name with -otel suffix
  local new_name="${container_name}-otel"
  
  # Check if target container already exists and remove it
  if docker ps -a --format "{{.Names}}" | grep -q "^${new_name}$"; then
    info "Removing existing container: $new_name"
    if ! docker rm "$new_name" >/dev/null 2>&1; then
      warn "Failed to remove existing container $new_name, continuing anyway"
    fi
  fi
  
  # Stop the old container
  info "Stopping container: $container_name"
  if ! docker stop "$container_name" >/dev/null 2>&1; then
    err "Failed to stop container $container_name"
    return 1
  fi
  
  # Build docker-run-otel command with OTEL instrumentation
  # Ensure detached mode is always used
  local docker_cmd="docker-run-otel -d"
  
  # Add ports if available
  if [ -n "$ports" ]; then
    docker_cmd="$docker_cmd $ports"
  fi
  
  # Add environment variables (excluding OTEL ones, they'll be added by docker-run-otel)
  if [ -n "$env_vars" ]; then
    docker_cmd="$docker_cmd $env_vars"
  fi
  
  # Add volumes if available
  if [ -n "$volumes" ]; then
    docker_cmd="$docker_cmd $volumes"
  fi
  
  # Add working directory if available
  if [ -n "$working_dir" ] && [ "$working_dir" != "/" ]; then
    docker_cmd="$docker_cmd -w $working_dir"
  fi
  
  # Add service name environment variable
  docker_cmd="$docker_cmd -e OTEL_SERVICE_NAME=$container_name"
  
  # Add JVM options to fix cgroup-related issues with OpenTelemetry agent
  docker_cmd="$docker_cmd -e OTEL_JAVAAGENT_ENABLE_RUNTIME_METRICS=false"
  docker_cmd="$docker_cmd -e OTEL_JAVAAGENT_ENABLE_EXPERIMENTAL_RUNTIME_METRICS=false"
  
  # Add additional JVM options to prevent cgroup-related failures
  docker_cmd="$docker_cmd -e JAVA_TOOL_OPTIONS=\"-javaagent:/otel/opentelemetry-javaagent.jar -Dotel.javaagent.enable.runtime.metrics=false -Dotel.javaagent.enable.experimental.runtime.metrics=false -XX:+DisableAttachMechanism\""
  
  # Add name and image
  docker_cmd="$docker_cmd --name $new_name $image"
  
  # Add command if available
  if [ -n "$command" ]; then
    docker_cmd="$docker_cmd $command"
  fi
  
  info "Starting container with OTEL instrumentation: $new_name"
  info "Service name will be: $container_name"
  info "Container will start in detached mode"
  info "Command: $docker_cmd"
  
  # Execute the command and capture output with timeout
  local run_output
  info "Executing docker command with timeout..."
  if ! run_output=$(timeout 30 bash -c "eval '$docker_cmd'" 2>&1); then
    local exit_code=$?
    if [ $exit_code -eq 124 ]; then
      err "Docker command timed out after 30 seconds"
    else
      # Check if the container was actually created despite the error
      if docker ps -a --format "{{.Names}}" | grep -q "^${new_name}$"; then
        info "Container was created despite error, checking status..."
        # Container exists, check if it's running
        if docker ps --format "{{.Names}}" | grep -q "^${new_name}$"; then
          info "Container is running, continuing with verification..."
        else
          err "Container was created but is not running (exit code: $exit_code): $run_output"
          # Try to restart original container
          info "Attempting to restart original container: $container_name"
          if docker start "$container_name" >/dev/null 2>&1; then
            info "✓ Restarted original container: $container_name"
          else
            err "Failed to restart original container: $container_name"
          fi
          return 1
        fi
      else
        err "Failed to start new container (exit code: $exit_code): $run_output"
        # Try to restart original container
        info "Attempting to restart original container: $container_name"
        if docker start "$container_name" >/dev/null 2>&1; then
          info "✓ Restarted original container: $container_name"
        else
          err "Failed to restart original container: $container_name"
        fi
        return 1
      fi
    fi
  else
    info "Docker command executed successfully: $run_output"
  fi
  
  # Wait a moment for container to start
  sleep 5
  
  # Check if container is running
  if docker ps --format "{{.Names}}" | grep -q "^${new_name}$"; then
    info "✓ Successfully restarted container with OTEL instrumentation: $new_name"
    info "✓ Service name set to: $container_name"
    # Check container logs for any issues
    info "Checking container logs for any issues..."
    local log_output
    log_output=$(docker logs "$new_name" 2>&1 | tail -10)
    if echo "$log_output" | grep -q "OpenTelemetry Javaagent failed to start"; then
      warn "OpenTelemetry agent had initialization issues, but container is running"
      info "This is often due to cgroup configuration issues but does not affect application functionality"
    fi
    if echo "$log_output" | grep -q "Started.*Application"; then
      info "✓ Application started successfully"
    fi
    # Remove old container
    if docker rm "$container_name" >/dev/null 2>&1; then
      info "✓ Removed old container: $container_name"
    else
      warn "Failed to remove old container: $container_name"
    fi
  else
    err "Failed to restart container with OTEL instrumentation"
    # Check what happened to the container
    if docker ps -a --format "{{.Names}}" | grep -q "^${new_name}$"; then
      info "Container exists but not running. Checking logs..."
      docker logs "$new_name" 2>&1 | tail -20
    fi
    # Try to restart original container
    info "Attempting to restart original container: $container_name"
    if docker start "$container_name" >/dev/null 2>&1; then
      info "✓ Restarted original container: $container_name"
    else
      err "Failed to restart original container: $container_name"
    fi
    return 1
  fi
}

# Function to list all instrumented Java apps
list_instrumented_apps() {
  info "Listing all instrumented Java applications..."
  
  local instrumented_count=0
  
  # Check systemd services
  info "=== Systemd Services ==="
  local java_services
  mapfile -t java_services < <(detect_java_services)
  
  for service in "${java_services[@]}"; do
    local env_output
    env_output=$(systemctl show "$service" --property=Environment --no-pager 2>/dev/null)
    if echo "$env_output" | grep -q "OTEL_EXPORTER_OTLP_ENDPOINT"; then
      info "✓ Service: $service (instrumented)"
      instrumented_count=$((instrumented_count + 1))
    else
      info "✗ Service: $service (not instrumented)"
    fi
  done
  
  # Check Docker containers
  info "=== Docker Containers ==="
  local java_containers
  mapfile -t java_containers < <(detect_java_containers)
  
  for container in "${java_containers[@]}"; do
    local has_endpoint
    has_endpoint=$(docker exec "$container" env 2>/dev/null | grep -q "OTEL_EXPORTER_OTLP_ENDPOINT" && echo "yes" || echo "no")
    if [ "$has_endpoint" = "yes" ]; then
      info "✓ Container: $container (instrumented)"
      instrumented_count=$((instrumented_count + 1))
    else
      info "✗ Container: $container (not instrumented)"
    fi
  done
  
  info "Total instrumented Java applications: $instrumented_count"
}

# Function to remove OTEL instrumentation from a specific service
uninstrument_service() {
  local service_name="$1"
  
  if [ -z "$service_name" ]; then
    err "Service name is required"
    return 1
  fi
  
  info "Removing OTEL instrumentation from service: $service_name"
  
  # Check if service exists and is running
  if ! systemctl is-active --quiet "$service_name" 2>/dev/null; then
    err "Service $service_name is not running or does not exist"
    return 1
  fi
  
  # Create backup of service file
  local service_file="/etc/systemd/system/$service_name"
  if [ -f "$service_file" ]; then
    cp "$service_file" "${service_file}.backup.$(date +%Y%m%d_%H%M%S)"
    info "Created backup: ${service_file}.backup.$(date +%Y%m%d_%H%M%S)"
  fi
  
  # Remove OTEL environment variables from service file
  if [ -f "$service_file" ]; then
    sed -i '/Environment=JAVA_TOOL_OPTIONS.*opentelemetry/d' "$service_file"
    sed -i '/Environment=OTEL_/d' "$service_file"
    info "Removed OTEL environment variables from $service_file"
  fi
  
  # Reload systemd and restart service
  systemctl daemon-reload
  systemctl restart "$service_name"
  
  if systemctl is-active --quiet "$service_name"; then
    info "✓ Successfully removed OTEL instrumentation from $service_name"
  else
    err "Failed to restart service $service_name after removing instrumentation"
    return 1
  fi
}

# Function to remove OTEL instrumentation from a specific container
uninstrument_container() {
  local container_name="$1"
  
  if [ -z "$container_name" ]; then
    err "Container name is required"
    return 1
  fi
  
  info "Removing OTEL instrumentation from container: $container_name"
  
  # Check if container exists and is running
  if ! docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
    err "Container $container_name is not running or does not exist"
    return 1
  fi
  
  # Get container configuration with better error handling
  local image
  if ! image=$(timeout 15 docker inspect "$container_name" --format '{{.Config.Image}}' 2>/dev/null); then
    err "Failed to get image for container $container_name (timeout or error)"
    return 1
  fi
  if [ -z "$image" ]; then
    err "Failed to get image for container $container_name (empty result)"
    return 1
  fi
  
  info "Container image: $image"
  
  # Get port mapping with better error handling
  info "Getting port mapping for container: $container_name"
  local ports=""
  local port_output
  if port_output=$(timeout 15 docker port "$container_name" 2>&1); then
    info "Port output: $port_output"
    if [ -n "$port_output" ]; then
      # Parse all port mappings, not just the first one
      while IFS= read -r port_line; do
        if [ -n "$port_line" ]; then
          local host_port
          local container_port
          # Parse format like "9090/tcp -> 0.0.0.0:8082"
          if [[ "$port_line" == *"->"* ]]; then
            host_port=$(echo "$port_line" | awk -F: '{print $2}')
            container_port=$(echo "$port_line" | awk '{print $1}' | awk -F/ '{print $1}')
            if [ -n "$host_port" ] && [ -n "$container_port" ]; then
              ports="$ports -p $host_port:$container_port"
              info "Found port mapping: $host_port:$container_port"
            fi
          fi
        fi
      done <<< "$port_output"
    fi
  else
    warn "Failed to get port mapping for container $container_name (timeout or error)"
  fi
  info "Final ports: $ports"
  
  # Get environment variables (excluding OTEL ones) with better error handling
  info "Getting environment variables for container: $container_name"
  local env_vars=""
  local env_output
  if env_output=$(timeout 15 docker inspect "$container_name" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>&1); then
    info "Environment output length: ${#env_output}"
    if [ -n "$env_output" ]; then
      env_vars=$(echo "$env_output" | grep -v "^$" | grep -v "OTEL_" | grep -v "JAVA_TOOL_OPTIONS" | while read -r env_var; do
        if [ -n "$env_var" ]; then
          echo "-e $env_var"
        fi
      done | tr '\n' ' ')
    fi
  else
    warn "Failed to get environment variables for container $container_name (timeout or error)"
  fi
  info "Final env_vars: $env_vars"
  
  # Get volumes (excluding OTEL agent volume) with better error handling
  info "Getting volume information for container: $container_name"
  local volumes=""
  local volume_output
  if volume_output=$(timeout 15 docker inspect "$container_name" --format '{{range .Mounts}}{{print .Source ":" .Destination "\n"}}{{end}}' 2>&1); then
    info "Volume output length: ${#volume_output}"
    info "Volume output: $volume_output"
    if [ -n "$volume_output" ]; then
      # Process volumes line by line to avoid hanging
      while IFS= read -r volume_line; do
        if [ -n "$volume_line" ] && [[ "$volume_line" != *":/otel"* ]]; then
          volumes="$volumes -v $volume_line"
          info "Added volume: $volume_line"
        fi
      done <<< "$volume_output"
    fi
  else
    warn "Failed to get volume information for container $container_name (timeout or error)"
  fi
  info "Final volumes: $volumes"
  
  # Get working directory
  info "Getting working directory for container: $container_name"
  local working_dir
  if ! working_dir=$(timeout 15 docker inspect "$container_name" --format '{{.Config.WorkingDir}}' 2>&1); then
    warn "Failed to get working directory for container $container_name (timeout or error)"
    working_dir=""
  fi
  info "Working directory: $working_dir"
  
  # Get command
  info "Getting command for container: $container_name"
  local command
  if ! command=$(timeout 15 docker inspect "$container_name" --format '{{.Config.Cmd}}' 2>&1 | tr -d '[]' | tr ',' ' '); then
    warn "Failed to get command for container $container_name (timeout or error)"
    command=""
  fi
  info "Command: $command"
  
  # Create new container name (remove -otel suffix if present)
  local new_name="${container_name%-otel}"
  
  info "Container configuration:"
  info "  Image: $image"
  info "  Ports: $ports"
  info "  Working directory: $working_dir"
  info "  Command: $command"
  
  # Check if target container already exists and remove it
  if docker ps -a --format "{{.Names}}" | grep -q "^${new_name}$"; then
    info "Removing existing container: $new_name"
    if ! docker rm "$new_name" >/dev/null 2>&1; then
      warn "Failed to remove existing container $new_name, continuing anyway"
    fi
  fi
  
  # Stop the old container
  info "Stopping container: $container_name"
  if ! docker stop "$container_name" >/dev/null 2>&1; then
    err "Failed to stop container $container_name"
    return 1
  fi
  
  # Build docker run command without OTEL instrumentation
  local docker_cmd="docker run -d"
  
  # Add ports if available
  if [ -n "$ports" ]; then
    docker_cmd="$docker_cmd $ports"
  fi
  
  # Add environment variables (excluding OTEL ones)
  if [ -n "$env_vars" ]; then
    docker_cmd="$docker_cmd $env_vars"
  fi
  
  # Add volumes if available
  if [ -n "$volumes" ]; then
    docker_cmd="$docker_cmd $volumes"
  fi
  
  # Add working directory if available
  if [ -n "$working_dir" ] && [ "$working_dir" != "/" ]; then
    docker_cmd="$docker_cmd -w $working_dir"
  fi
  
  # Add name and image
  docker_cmd="$docker_cmd --name $new_name $image"
  
  # Add command if available
  if [ -n "$command" ]; then
    docker_cmd="$docker_cmd $command"
  fi
  
  info "Starting container without OTEL instrumentation: $new_name"
  info "Command: $docker_cmd"
  
  # Execute the command and capture output
  local run_output
  if ! run_output=$(eval "$docker_cmd" 2>&1); then
    err "Failed to start new container: $run_output"
    # Try to restart original container
    info "Attempting to restart original container: $container_name"
    if docker start "$container_name" >/dev/null 2>&1; then
      info "✓ Restarted original container: $container_name"
    else
      err "Failed to restart original container: $container_name"
    fi
    return 1
  fi
  
  # Wait a moment for container to start
  sleep 3
  
  # Check if container is running
  if docker ps --format "{{.Names}}" | grep -q "^${new_name}$"; then
    info "✓ Successfully restarted container without OTEL instrumentation: $new_name"
    # Remove old container
    if docker rm "$container_name" >/dev/null 2>&1; then
      info "✓ Removed old container: $container_name"
    else
      warn "Failed to remove old container: $container_name"
    fi
  else
    err "Failed to restart container without OTEL instrumentation"
    # Try to restart original container
    info "Attempting to restart original container: $container_name"
    if docker start "$container_name" >/dev/null 2>&1; then
      info "✓ Restarted original container: $container_name"
    else
      err "Failed to restart original container: $container_name"
    fi
    return 1
  fi
}

# Function to remove OTEL instrumentation from all Java apps
uninstrument_all() {
  info "Removing OTEL instrumentation from all Java applications..."
  
  local total_removed=0
  
  # Remove from systemd services
  info "=== Removing from Systemd Services ==="
  local java_services
  mapfile -t java_services < <(detect_java_services)
  
  for service in "${java_services[@]}"; do
    local env_output
    env_output=$(systemctl show "$service" --property=Environment --no-pager 2>/dev/null)
    if echo "$env_output" | grep -q "OTEL_EXPORTER_OTLP_ENDPOINT"; then
      info "Removing instrumentation from service: $service"
      if uninstrument_service "$service"; then
        total_removed=$((total_removed + 1))
      fi
    else
      info "Service $service is not instrumented, skipping"
    fi
  done
  
  # Remove from Docker containers
  info "=== Removing from Docker Containers ==="
  local java_containers
  mapfile -t java_containers < <(detect_java_containers)
  
  for container in "${java_containers[@]}"; do
    local has_endpoint
    has_endpoint=$(docker exec "$container" env 2>/dev/null | grep -q "OTEL_EXPORTER_OTLP_ENDPOINT" && echo "yes" || echo "no")
    if [ "$has_endpoint" = "yes" ]; then
      info "Removing instrumentation from container: $container"
      if uninstrument_container "$container"; then
        total_removed=$((total_removed + 1))
      fi
    else
      info "Container $container is not instrumented, skipping"
    fi
  done
  
  # Remove systemd drop-in
  local systemd_dropin="/usr/lib/systemd/system.conf.d/00-otelinject-instrumentation.conf"
  if [ -f "$systemd_dropin" ]; then
    info "Removing systemd drop-in: $systemd_dropin"
    rm -f "$systemd_dropin"
    systemctl daemon-reload
  fi
  
  # Remove profile snippet
  local profile_snippet="/etc/profile.d/otelinject-instrumentation.sh"
  if [ -f "$profile_snippet" ]; then
    info "Removing profile snippet: $profile_snippet"
    rm -f "$profile_snippet"
  fi
  
  # Remove Docker wrapper
  if [ -f "$DOCKER_WRAPPER_PATH" ]; then
    info "Removing Docker wrapper: $DOCKER_WRAPPER_PATH"
    rm -f "$DOCKER_WRAPPER_PATH"
  fi
  
  info "✓ Successfully removed OTEL instrumentation from $total_removed applications"
  info "✓ Removed systemd drop-in, profile snippet, and Docker wrapper"
}

# Function to validate instrumentation
validate_instrumentation() {
  info "Validating OpenTelemetry instrumentation..."
  
  local java_services
  mapfile -t java_services < <(detect_java_services)
  local success_count=0
  
  for service in "${java_services[@]}"; do
    info "Checking service: $service"
    
    # Check if service has OTEL environment variables
    local env_output
    env_output=$(systemctl show "$service" --property=Environment --no-pager 2>/dev/null)
    if echo "$env_output" | grep -q "OTEL_EXPORTER_OTLP_ENDPOINT"; then
      info "✓ Service $service has OTEL configuration"
      success_count=$((success_count + 1))
    else
      warn "✗ Service $service missing OTEL configuration"
    fi
  done
  
  if [ $success_count -eq ${#java_services[@]} ] && [ ${#java_services[@]} -gt 0 ]; then
    info "✓ All Java services are properly instrumented"
    return 0
  else
    warn "Some services may not be properly instrumented"
    return 1
  fi
}

if [ "$EUID" -ne 0 ]; then
  err "Please run as root (sudo)."
fi

# Check dependencies
command -v curl >/dev/null 2>&1 || err "curl required. Install and re-run."
command -v jq >/dev/null 2>&1 || err "jq required. Install and re-run."

install_agent() {
  info "Creating $OTEL_DIR ..."
  mkdir -p "$OTEL_DIR"
  chmod 0755 "$OTEL_DIR"

  if [ -f "$AGENT_PATH" ] && [ "$FORCE" != "1" ]; then
    info "Agent already exists at $AGENT_PATH (use FORCE=1 to re-download)."
  else
    info "Downloading OpenTelemetry Java agent from: $AGENT_URL"
    curl -fL --progress-bar -o "$AGENT_PATH" "$AGENT_URL" || err "Failed to download java agent"
    chmod 0644 "$AGENT_PATH"
    info "Downloaded agent to $AGENT_PATH"
  fi
}

install_systemd_dropin() {
  SYSTEMD_DIR="/usr/lib/systemd/system.conf.d"
  SYSTEMD_DROPIN="$SYSTEMD_DIR/00-otelinject-instrumentation.conf"
  mkdir -p "$SYSTEMD_DIR"
  
  # Build environment variables string
  ENV_VARS="JAVA_TOOL_OPTIONS=-javaagent:${AGENT_PATH}"
  ENV_VARS="${ENV_VARS} OTEL_EXPORTER_OTLP_ENDPOINT=${OTEL_EXPORTER_OTLP_ENDPOINT}"
  ENV_VARS="${ENV_VARS} OTEL_EXPORTER_OTLP_HEADERS=${OTEL_EXPORTER_OTLP_HEADERS}"
  ENV_VARS="${ENV_VARS} OTEL_TRACES_EXPORTER=${OTEL_TRACES_EXPORTER}"
  ENV_VARS="${ENV_VARS} OTEL_METRICS_EXPORTER=${OTEL_METRICS_EXPORTER}"
  ENV_VARS="${ENV_VARS} OTEL_LOGS_EXPORTER=${OTEL_LOGS_EXPORTER}"
  
  if [ -n "${OTEL_SERVICE_NAME:-}" ]; then
    ENV_VARS="${ENV_VARS} OTEL_SERVICE_NAME=${OTEL_SERVICE_NAME}"
  fi
  
  if [ -n "${OTEL_RESOURCE_ATTRIBUTES:-}" ]; then
    ENV_VARS="${ENV_VARS} OTEL_RESOURCE_ATTRIBUTES=${OTEL_RESOURCE_ATTRIBUTES}"
  fi
  
  cat > "$SYSTEMD_DROPIN" <<EOF
# OpenTelemetry system-wide defaults (auto-generated)
DefaultEnvironment="${ENV_VARS}"
EOF
  info "Wrote systemd drop-in: $SYSTEMD_DROPIN"
  info "Environment variables: $ENV_VARS"
  systemctl daemon-reload
}

install_profile_snippet() {
  PROFILE_SNIPPET="/etc/profile.d/otel-javaagent.sh"
  cat > "$PROFILE_SNIPPET" <<'EOF'
# OpenTelemetry Java agent
AGENT="/usr/lib/opentelemetry/opentelemetry-javaagent.jar"

prepend_agent() {
  if [ -z "${JAVA_TOOL_OPTIONS:-}" ]; then
    export JAVA_TOOL_OPTIONS="-javaagent:${AGENT}"
  else
    case ":$JAVA_TOOL_OPTIONS:" in
      *":-javaagent:${AGENT}:"*)
        ;;
      *)
        export JAVA_TOOL_OPTIONS="-javaagent:${AGENT} $JAVA_TOOL_OPTIONS"
        ;;
    esac
  fi
}

prepend_agent
EOF
  chmod 0644 "$PROFILE_SNIPPET"
  info "Wrote profile snippet: $PROFILE_SNIPPET"
}

install_docker_wrapper() {
  cat > "$DOCKER_WRAPPER_PATH" <<'BASH'
#!/usr/bin/env bash
# docker-run-otel: wrapper around docker run to mount OTEL agent and set env vars.
# Usage: docker-run-otel [docker run args... ] image [cmd...]
OTEL_HOST_DIR="/usr/lib/opentelemetry"
OTEL_CONTAINER_PATH="/otel"
AGENT_NAME="opentelemetry-javaagent.jar"
AGENT_FULL_PATH="${OTEL_HOST_DIR}/${AGENT_NAME}"

if [ ! -f "${AGENT_FULL_PATH}" ]; then
  echo "Agent not found at ${AGENT_FULL_PATH}. Place agent there or run installer." >&2
  exit 1
fi

# We will add:
#  - a read-only mount of the agent dir to /otel in the container
#  - JAVA_TOOL_OPTIONS to include the javaagent path
# If caller already passes -e JAVA_TOOL_OPTIONS or -v containing AGENT path, we do not override.
args=()
skip_envset=0
skip_mount=0

# quick parse for env or volume that mention JAVA_TOOL_OPTIONS or -v /otel (not bulletproof)
for i in "$@"; do
  case "$i" in
    *JAVA_TOOL_OPTIONS*)
      skip_envset=1
      ;;
    *":/otel"*)
      skip_mount=1
      ;;
  esac
done

if [ "$skip_mount" -eq 0 ]; then
  args+=( -v "${OTEL_HOST_DIR}:${OTEL_CONTAINER_PATH}:ro" )
fi

if [ "$skip_envset" -eq 0 ]; then
  # Add JVM options to fix cgroup-related issues and ensure proper agent initialization
  java_tool_options="-javaagent:${OTEL_CONTAINER_PATH}/${AGENT_NAME}"
  java_tool_options="${java_tool_options} -Dotel.javaagent.enable.runtime.metrics=false"
  java_tool_options="${java_tool_options} -Dotel.javaagent.enable.experimental.runtime.metrics=false"
  java_tool_options="${java_tool_options} -XX:+DisableAttachMechanism"
  java_tool_options="${java_tool_options} ${JAVA_TOOL_OPTIONS:-}"
  args+=( -e "JAVA_TOOL_OPTIONS=${java_tool_options}" )
fi

# Add detached mode if not already specified
if ! echo "$@" | grep -q "\-d\|--detach"; then
  args+=( -d )
fi

# Add OpenTelemetry environment variables
args+=( -e "OTEL_EXPORTER_OTLP_ENDPOINT=${OTEL_EXPORTER_OTLP_ENDPOINT:-https://sandbox.middleware.io:443}" )
args+=( -e "OTEL_EXPORTER_OTLP_HEADERS=${OTEL_EXPORTER_OTLP_HEADERS:-authorization=5xrocjh0p5ir233mvi34dvl5bepnyqri3rqb}" )
args+=( -e "OTEL_TRACES_EXPORTER=${OTEL_TRACES_EXPORTER:-otlp}" )
args+=( -e "OTEL_METRICS_EXPORTER=${OTEL_METRICS_EXPORTER:-otlp}" )
args+=( -e "OTEL_LOGS_EXPORTER=${OTEL_LOGS_EXPORTER:-otlp}" )

# Add JVM options to fix cgroup-related issues with OpenTelemetry agent
args+=( -e "OTEL_JAVAAGENT_ENABLE_RUNTIME_METRICS=false" )
args+=( -e "OTEL_JAVAAGENT_ENABLE_EXPERIMENTAL_RUNTIME_METRICS=false" )

# Set service name from container name if not already set
if [ -z "${OTEL_SERVICE_NAME:-}" ]; then
  # Extract container name from --name argument or use a default
  container_name=""
  for i in "${@}"; do
    if [ "$i" = "--name" ]; then
      container_name="next"
    elif [ "$container_name" = "next" ]; then
      container_name="$i"
      break
    fi
  done
  
  if [ -n "$container_name" ]; then
    # Remove -otel suffix if present
    service_name=$(echo "$container_name" | sed 's/-otel$//')
    args+=( -e "OTEL_SERVICE_NAME=$service_name" )
  fi
else
  args+=( -e "OTEL_SERVICE_NAME=${OTEL_SERVICE_NAME}" )
fi

# Exec docker run with provided args prefixed
docker run "${args[@]}" "$@"
BASH
  chmod +x "$DOCKER_WRAPPER_PATH"
  info "Installed docker wrapper: $DOCKER_WRAPPER_PATH"
  info "Use it like: sudo $DOCKER_WRAPPER_PATH <docker run args> image"
}

# Kubernetes patcher:
# - requires kubectl configured and jq
patch_k8s_controllers() {
  if ! command -v kubectl >/dev/null 2>&1; then
    err "kubectl required for Kubernetes patching. Install/configure kubectl to continue."
  fi

  if [ "$K8S_NAMESPACE" = "all" ]; then
    ns_list=$(kubectl get ns -o jsonpath='{.items[*].metadata.name}')
  else
    ns_list="$K8S_NAMESPACE"
  fi

  for ns in $ns_list; do
    info "Scanning namespace: $ns"
    for kind in deployments statefulsets daemonsets; do
      info "Checking ${kind} in ${ns}..."
      names=$(kubectl -n "$ns" get "$kind" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || echo "")
      for name in $names; do
        info "Inspecting $kind/$name ..."
        obj=$(kubectl -n "$ns" get "$kind" "$name" -o json)
        # decide whether any container looks like Java (image or command/args)
        is_java=$(echo "$obj" | jq -r '
          .spec.template.spec.containers
          | map(
              ( .image // "" ) as $img
              | ( ($img|test("java|openjdk|jdk|jre";"i")) 
                  or ( (.command // []) | join(" ") | test("java";"i") )
                  or ( (.args // []) | join(" ") | test("java";"i") )
                )
            )
          | any(. == true)
        ')
        if [ "$is_java" != "true" ]; then
          info "Skipping $kind/$name (no Java-like container detected)."
          continue
        fi

        info "Preparing patch for $kind/$name ..."

        # Build patch JSON using jq:
        # - add volume otel-agent (emptyDir) if missing
        # - add initContainer otel-download if missing (uses curlimages/curl)
        # - for each container that is Java-like, add volumeMount and set/prepend JAVA_TOOL_OPTIONS
        patch=$(echo "$obj" | jq --arg AGENT_URL "$AGENT_URL" '
          def ensure_volumes:
            .spec.template.spec.volumes
            |= (
                if . == null then
                  [{"name":"otel-agent","emptyDir":{}}]
                else
                  (if any(.[]; .name=="otel-agent") then . else . + [{"name":"otel-agent","emptyDir":{}}] end)
                end
            );

          def ensure_init:
            .spec.template.spec.initContainers
            |= (
                if . == null then
                  [
                    {
                      "name":"otel-download",
                      "image":"curlimages/curl:latest",
                      "command":["sh","-c"],
                      "args":["set -e; mkdir -p /otel; curl -fsSL -o /otel/opentelemetry-javaagent.jar \($AGENT_URL)"],
                      "volumeMounts":[{"name":"otel-agent","mountPath":"/otel"}]
                    }
                  ]
                else
                  (if any(.[]; .name=="otel-download") then . else . + [
                    {
                      "name":"otel-download",
                      "image":"curlimages/curl:latest",
                      "command":["sh","-c"],
                      "args":["set -e; mkdir -p /otel; curl -fsSL -o /otel/opentelemetry-javaagent.jar \($AGENT_URL)"],
                      "volumeMounts":[{"name":"otel-agent","mountPath":"/otel"}]
                    }
                  ] end)
                end
            );

          def patch_containers:
            .spec.template.spec.containers
            |= ( map(
                  if ( (.image // "" ) | test("java|openjdk|jdk|jre";"i")
                       or ( (.command // []) | join(" ") | test("java";"i") )
                       or ( (.args // []) | join(" ") | test("java";"i") )
                     )
                  then
                    . 
                    | .volumeMounts = ( (.volumeMounts // []) + [ {"name":"otel-agent","mountPath":"/otel"} ] )
                    | .env = (
                        ( .env // [] )
                        | ( if any(.[]; .name=="JAVA_TOOL_OPTIONS") 
                            then ( map( if .name=="JAVA_TOOL_OPTIONS" then .value = ("-javaagent:/otel/opentelemetry-javaagent.jar " + ( .value // "" )) | . else . end ) )
                            else ( . + [ {"name":"JAVA_TOOL_OPTIONS","value":"-javaagent:/otel/opentelemetry-javaagent.jar"} ] )
                          end
                        )
                      )
                  else .
                  end
              )
            );

          .
          | ensure_volumes
          | ensure_init
          | patch_containers
        ' )

        # Apply patch (dry-run option available)
        if [ "$DRY_RUN" = "1" ]; then
          echo "DRY-RUN patch for $kind/$name in $ns:"
          echo "$patch" | jq .
        else
          info "Applying patched $kind/$name..."
          echo "$patch" | kubectl -n "$ns" apply -f -
          info "Patched $kind/$name applied."
        fi

      done
    done
  done
}

usage() {
  cat <<EOF
Usage: sudo $0 [commands]

Commands:
  install-agent       Download/install the Java agent to $AGENT_PATH
  install-host        (install-agent + systemd drop-in + profile snippet + update services + update docker + validate)
  docker-wrapper      Install docker-run-otel wrapper at $DOCKER_WRAPPER_PATH
  patch-k8s           Patch Kubernetes controllers in namespace $K8S_NAMESPACE (requires kubectl + jq). Honor DRY_RUN=1 to preview.
  update-services     Update existing Java services with OTEL configuration
  update-docker       Update existing Java Docker containers with OTEL wrapper
  validate            Validate that all Java services and containers are properly instrumented
  all                 Do install-host + docker-wrapper (does not run patch-k8s by default)
  instrument-service <name>    Add OTEL instrumentation to specific service
  instrument-container <name>  Add OTEL instrumentation to specific container (always starts in detached mode)
  uninstrument-all    Remove OTEL instrumentation from all Java apps
  uninstrument-service <name>  Remove OTEL instrumentation from specific service
  uninstrument-container <name>  Remove OTEL instrumentation from specific container
  list-instrumented   List all currently instrumented Java apps

Environment Variables:
  OTEL_EXPORTER_OTLP_ENDPOINT    OpenTelemetry endpoint (default: https://sandbox.middleware.io:443)
  OTEL_EXPORTER_OTLP_HEADERS     Authentication headers (default: authorization=5xrocjh0p5ir233mvi34dvl5bepnyqri3rqb)
  OTEL_SERVICE_NAME              Service name (optional, auto-detected from container name)
  OTEL_RESOURCE_ATTRIBUTES       Resource attributes (optional)
  AUTO_UPDATE_SERVICES           Auto-update existing services (default: 1)

Examples:
  sudo $0 install-agent
  sudo OTEL_DIR=/opt/otel FORCE=1 $0 install-agent
  sudo $0 install-host
  sudo OTEL_EXPORTER_OTLP_ENDPOINT=https://your-endpoint:4317 $0 install-host
  sudo $0 update-services        # Update existing services only
  sudo $0 update-docker          # Update existing Docker containers only
  sudo $0 validate               # Check instrumentation status
  sudo $0 instrument-container my-container  # Instrument specific container (detached mode)
  sudo docker-run-otel --name my-app -p 8080:9090 my-java-image  # Service name will be "my-app"
  sudo OTEL_SERVICE_NAME=custom-name docker-run-otel --name my-app my-java-image  # Override service name
  sudo DRY_RUN=1 K8S_NAMESPACE=default $0 patch-k8s   # preview for default ns
  sudo K8S_NAMESPACE=all $0 patch-k8s                 # patch all namespaces (careful)
EOF
}

main() {
  case "${1:-}" in
    install-agent) install_agent ;;
    install-host)
      install_agent
      install_systemd_dropin
      install_profile_snippet
      update_java_services
      update_docker_containers
      validate_instrumentation
      ;;
    docker-wrapper) install_agent; install_docker_wrapper ;;
    patch-k8s) patch_k8s_controllers ;;
    update-services) update_java_services ;;
    update-docker) update_docker_containers ;;
    validate) validate_instrumentation ;;
    all)
      install_agent
      install_systemd_dropin
      install_profile_snippet
      install_docker_wrapper
      update_java_services
      update_docker_containers
      validate_instrumentation
      ;;
    list-instrumented) list_instrumented_apps ;;
    instrument-service) 
      if [ -z "$2" ]; then
        err "Service name is required for instrument-service"
        # shellcheck disable=SC2317
        usage
        # shellcheck disable=SC2317
        exit 1
      fi
      instrument_service "$2" ;;
    instrument-container)
      if [ -z "$2" ]; then
        err "Container name is required for instrument-container"
        # shellcheck disable=SC2317
        usage
        # shellcheck disable=SC2317
        exit 1
      fi
      instrument_container "$2" ;;
    uninstrument-all) uninstrument_all ;;
    uninstrument-service) 
      if [ -z "$2" ]; then
        err "Service name is required for uninstrument-service"
        # shellcheck disable=SC2317
        usage
        # shellcheck disable=SC2317
        exit 1
      fi
      uninstrument_service "$2" ;;
    uninstrument-container)
      if [ -z "$2" ]; then
        err "Container name is required for uninstrument-container"
        # shellcheck disable=SC2317
        usage
        # shellcheck disable=SC2317
        exit 1
      fi
      uninstrument_container "$2" ;;
    ""|help|-h|--help) usage ;;
    *)
      echo "Unknown command: $1" >&2
      usage
      exit 2
      ;;
  esac
}

main "$@"
