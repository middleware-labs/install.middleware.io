#!/bin/bash

# Java Application OpenTelemetry Instrumentation Script
# Detects running Java applications and instruments them with Middleware's extended OpenTelemetry Java agent
# Compatible with Amazon Linux

set -euo pipefail

# Source configuration file if it exists
if [[ -f "./java-instrumentation-config.env" ]]; then
    # shellcheck disable=SC1091
    source ./java-instrumentation-config.env
fi

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OTEL_AGENT_DIR="${SCRIPT_DIR}/otel-agents"
OTEL_AGENT_JAR="${OTEL_AGENT_DIR}/middleware-javaagent.jar"
LOG_FILE="${SCRIPT_DIR}/java-instrumentation.log"
BACKUP_DIR="${SCRIPT_DIR}/java-app-backups"

# OpenTelemetry Configuration (can be overridden by environment variables)
OTEL_SERVICE_NAME="${OTEL_SERVICE_NAME:-}"
OTEL_RESOURCE_ATTRIBUTES="${OTEL_RESOURCE_ATTRIBUTES:-}"
OTEL_EXPORTER_OTLP_ENDPOINT="${OTEL_EXPORTER_OTLP_ENDPOINT:-http://localhost:4317}"
OTEL_EXPORTER_OTLP_HEADERS="${OTEL_EXPORTER_OTLP_HEADERS:-}"
OTEL_EXPORTER_OTLP_PROTOCOL="${OTEL_EXPORTER_OTLP_PROTOCOL:-grpc}"
OTEL_LOGS_EXPORTER="${OTEL_LOGS_EXPORTER:-otlp}"
OTEL_METRICS_EXPORTER="${OTEL_METRICS_EXPORTER:-otlp}"
OTEL_TRACES_EXPORTER="${OTEL_TRACES_EXPORTER:-otlp}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}" | tee -a "${LOG_FILE}"
}

log_info() {
    log "INFO" "${BLUE}$*${NC}"
}

log_warn() {
    log "WARN" "${YELLOW}$*${NC}"
}

log_error() {
    log "ERROR" "${RED}$*${NC}"
}

log_success() {
    log "SUCCESS" "${GREEN}$*${NC}"
}

# Check if running as root or with sufficient privileges
check_privileges() {
    if [[ $EUID -ne 0 ]]; then
        log_warn "Script is not running as root. Some Java processes might not be accessible."
        log_warn "Consider running with sudo for full access to all Java processes."
    fi
}

# Create necessary directories
setup_directories() {
    log_info "Setting up directories..."
    mkdir -p "${OTEL_AGENT_DIR}"
    mkdir -p "${BACKUP_DIR}"
    touch "${LOG_FILE}"
}

# Download Middleware Java agent
download_otel_agent() {
    log_info "Checking for Middleware Java agent..."
    
    if [[ -f "${OTEL_AGENT_JAR}" ]]; then
        log_info "Middleware Java agent already exists at ${OTEL_AGENT_JAR}"
        return 0
    fi
    
    log_info "Downloading Middleware Java agent v1.8.1..."
    
    # Use Middleware's extended OpenTelemetry Java agent
    local middleware_url="https://github.com/middleware-labs/opentelemetry-java-instrumentation/releases/download/v1.8.1/middleware-javaagent.jar"
    
    log_info "Downloading from: ${middleware_url}"
    
    if command -v curl >/dev/null 2>&1; then
        curl -L -o "${OTEL_AGENT_JAR}" "${middleware_url}"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "${OTEL_AGENT_JAR}" "${middleware_url}"
    else
        log_error "Neither curl nor wget found. Cannot download Middleware Java agent."
        exit 1
    fi
    
    if [[ ! -f "${OTEL_AGENT_JAR}" ]]; then
        log_error "Failed to download Middleware Java agent"
        exit 1
    fi
    
    log_success "Middleware Java agent downloaded successfully"
}

# Find all running Java processes
find_java_processes() {
    # Send log messages to stderr to avoid contaminating the output
    echo "Detecting running Java applications..." >&2
    
    # shellcheck disable=SC2034
    # local java_pids=() # Unused variable removed
    
    # Use a very specific approach to avoid any contamination
    # First, get all processes that are exactly named 'java' or contain java binary
    local candidate_pids=()
    
    # Method 1: pgrep for exact java executable name
    while IFS= read -r pid; do
        if [[ "$pid" =~ ^[0-9]+$ ]]; then
            candidate_pids+=("$pid")
        fi
    done < <(pgrep -x java 2>/dev/null || true)
    
    # Method 2: Use ps with very specific pattern and field extraction
    while IFS= read -r line; do
        # Extract PID from ps output (1st field)
        local pid
        pid=$(echo "$line" | awk '{print $1}')
        if [[ "$pid" =~ ^[0-9]+$ ]]; then
            candidate_pids+=("$pid")
        fi
    done < <(ps -eo pid,comm,cmd | awk '$2 == "java" || $3 ~ /\/java[ ]/ || $3 ~ /^java[ ]/' 2>/dev/null || true)
    
    # Now validate each candidate PID very strictly
    local valid_pids=()
    for pid in "${candidate_pids[@]}"; do
        # Skip if not numeric or empty
        if [[ ! "$pid" =~ ^[0-9]+$ ]] || [[ -z "$pid" ]]; then
            continue
        fi
        
        # Check if process actually exists
        if ! kill -0 "$pid" 2>/dev/null; then
            continue
        fi
        
        # Check if it's a Java process by reading /proc/PID/comm
        local comm=""
        if [[ -r "/proc/$pid/comm" ]]; then
            comm=$(cat "/proc/$pid/comm" 2>/dev/null || echo "")
        fi
        
        # Skip if not java executable
        if [[ "$comm" != "java" ]]; then
            continue
        fi
        
        # Get command line safely
        local cmdline=""
        if [[ -r "/proc/$pid/cmdline" ]]; then
            cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || echo "")
        fi
        
        # Skip if we can't read cmdline
        if [[ -z "$cmdline" ]]; then
            echo "Cannot read command line for PID $pid (permission denied)" >&2
            continue
        fi
        
        # Skip our own script and related processes
        if [[ "$cmdline" == *"instrument-java-apps"* ]] || \
           [[ "$cmdline" == *"jps"* ]] || \
           [[ "$cmdline" == *"jstat"* ]] || \
           [[ "$cmdline" == *"jconsole"* ]] || \
           [[ "$cmdline" == *"jvisualvm"* ]]; then
            continue
        fi
        
        # Must contain java command
        if [[ "$cmdline" != *"java"* ]]; then
            continue
        fi
        
        # Check for duplicates
        local already_added=false
        for existing_pid in "${valid_pids[@]}"; do
            if [[ "$existing_pid" == "$pid" ]]; then
                already_added=true
                break
            fi
        done
        
        if [[ "$already_added" == false ]]; then
            valid_pids+=("$pid")
            
            # Check instrumentation status for display
            if [[ "$cmdline" == *"-javaagent:"*"opentelemetry"* ]]; then
                echo "Found Java process: PID=$pid [ALREADY INSTRUMENTED - OpenTelemetry] CMD=$cmdline" >&2
            elif [[ "$cmdline" == *"-javaagent:"*"middleware-javaagent"* ]]; then
                echo "Found Java process: PID=$pid [ALREADY INSTRUMENTED - Middleware] CMD=$cmdline" >&2
            else
                echo "Found Java process: PID=$pid [NOT INSTRUMENTED] CMD=$cmdline" >&2
            fi
        fi
    done
    
    if [[ ${#valid_pids[@]} -eq 0 ]]; then
        echo "No Java applications found running on this system" >&2
        exit 0
    fi
    
    # Only output the PIDs to stdout (space-separated)
    echo "${valid_pids[@]}"
}

# Get full command line for a process
get_process_cmdline() {
    local pid="$1"
    local temp_file="/tmp/get_cmdline_$$_$pid"
    
    # Check if process still exists and has readable cmdline
    if [[ ! -r "/proc/$pid/cmdline" ]]; then
        log_warn "Cannot read command line for PID ${pid} (not readable)"
        return 1
    fi
    
    # Use timeout to prevent hanging
    if timeout 3s bash -c "cat /proc/$pid/cmdline 2>/dev/null | tr '\0' ' '" > "$temp_file" 2>/dev/null; then
        local cmdline
        cmdline=$(cat "$temp_file" 2>/dev/null || echo "")
        rm -f "$temp_file" 2>/dev/null
        
        # Check if result is empty or whitespace only
        if [[ -z "$(echo "$cmdline" | tr -d ' \t\n')" ]]; then
            log_warn "Cannot read command line for PID ${pid} (empty result)"
            return 1
        fi
        
        echo "$cmdline"
        return 0
    else
        log_warn "Cannot read command line for PID ${pid} (timeout or error)"
        rm -f "$temp_file" 2>/dev/null
        return 1
    fi
}

# Get process working directory
get_process_cwd() {
    local pid="$1"
    
    if [[ -r "/proc/${pid}/cwd" ]]; then
        readlink "/proc/${pid}/cwd" 2>/dev/null || echo "/"
    else
        log_warn "Cannot read working directory for PID ${pid} (permission denied)"
        echo "/"
    fi
}

# Get process environment variables
get_process_env() {
    local pid="$1"
    
    if [[ -r "/proc/${pid}/environ" ]]; then
        tr '\0' '\n' < "/proc/${pid}/environ" 2>/dev/null || echo ""
    else
        log_warn "Cannot read environment for PID ${pid} (permission denied)"
        echo ""
    fi
}

# Check if process already has OpenTelemetry or Middleware Java agent
is_already_instrumented() {
    local cmdline="$1"
    
    # Check for OpenTelemetry agent (standard or Middleware's extended version)
    if [[ "$cmdline" == *"-javaagent:"*"opentelemetry"* ]] || \
       [[ "$cmdline" == *"-javaagent:"*"middleware-javaagent"* ]]; then
        return 0
    fi
    
    return 1
}

# Generate OpenTelemetry agent arguments
generate_otel_args() {
    local service_name="$1"
    local args="-javaagent:${OTEL_AGENT_JAR}"
    
    # Add service name if provided
    if [[ -n "$service_name" ]]; then
        args="${args} -Dotel.service.name=${service_name}"
    fi
    
    # Add resource attributes if provided
    if [[ -n "$OTEL_RESOURCE_ATTRIBUTES" ]]; then
        args="${args} -Dotel.resource.attributes=${OTEL_RESOURCE_ATTRIBUTES}"
    fi
    
    # Add exporter configuration
    args="${args} -Dotel.exporter.otlp.endpoint=${OTEL_EXPORTER_OTLP_ENDPOINT}"
    
    # Add headers if provided (critical for authentication)
    if [[ -n "$OTEL_EXPORTER_OTLP_HEADERS" ]]; then
        args="${args} -Dotel.exporter.otlp.headers=${OTEL_EXPORTER_OTLP_HEADERS}"
    fi
    
    args="${args} -Dotel.exporter.otlp.protocol=${OTEL_EXPORTER_OTLP_PROTOCOL}"
    args="${args} -Dotel.logs.exporter=${OTEL_LOGS_EXPORTER}"
    args="${args} -Dotel.metrics.exporter=${OTEL_METRICS_EXPORTER}"
    args="${args} -Dotel.traces.exporter=${OTEL_TRACES_EXPORTER}"
    
    echo "$args"
}

# Extract service name from command line
extract_service_name() {
    local cmdline="$1"
    
    # Try to extract from -jar argument
    if [[ "$cmdline" == *"-jar "* ]]; then
        local jar_file
        jar_file=$(echo "$cmdline" | sed -n 's/.*-jar \([^ ]*\).*/\1/p')
        if [[ -n "$jar_file" ]]; then
            basename "$jar_file" .jar
            return
        fi
    fi
    
    # Try to extract from main class
    if [[ "$cmdline" == *"java "* ]]; then
        local main_class
        main_class=$(echo "$cmdline" | sed -n 's/.*java.* \([a-zA-Z][a-zA-Z0-9._]*\).*/\1/p')
        if [[ -n "$main_class" ]]; then
            echo "${main_class##*.}"
            return
        fi
    fi
    
    echo "java-app"
}

# Check if process is managed by systemd
is_systemd_service() {
    local pid="$1"
    
    # Check if systemctl is available
    if ! command -v systemctl >/dev/null 2>&1; then
        return 1
    fi
    
    # Method 1: Check if process has systemd as parent (PPID = 1 and started by systemd)
    if [[ -r "/proc/$pid/stat" ]]; then
        local ppid
        ppid=$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null || echo "")
        if [[ "$ppid" == "1" ]]; then
            # Check if there's a corresponding systemd service
            local service_name
            service_name=$(get_systemd_service_name "$pid")
            if [[ -n "$service_name" ]]; then
                return 0
            fi
        fi
    fi
    
    # Method 2: Check cgroup for systemd service indicators
    if [[ -r "/proc/$pid/cgroup" ]]; then
        local cgroup_content
        cgroup_content=$(cat "/proc/$pid/cgroup" 2>/dev/null || echo "")
        if [[ "$cgroup_content" == *"/system.slice/"* ]] && [[ "$cgroup_content" == *".service"* ]]; then
            return 0
        fi
    fi
    
    return 1
}

# Get systemd service name for a PID
get_systemd_service_name() {
    local pid="$1"
    
    # Method 1: Use systemctl to find service by PID
    local service_name=""
    if command -v systemctl >/dev/null 2>&1; then
        service_name=$(systemctl --no-pager --no-legend status "$pid" 2>/dev/null | grep -o '[a-zA-Z0-9_.-]*\.service' | head -1 | sed 's/\.service$//')
        if [[ -n "$service_name" ]]; then
            echo "$service_name"
            return 0
        fi
    fi
    
    # Method 2: Parse cgroup for service name
    if [[ -r "/proc/$pid/cgroup" ]]; then
        local cgroup_content
        cgroup_content=$(cat "/proc/$pid/cgroup" 2>/dev/null || echo "")
        service_name=$(echo "$cgroup_content" | grep -o '/system\.slice/[^/]*\.service' | head -1 | sed 's|/system\.slice/||' | sed 's/\.service$//')
        if [[ -n "$service_name" ]]; then
            echo "$service_name"
            return 0
        fi
    fi
    
    return 1
}

# Get systemd service file path
get_systemd_service_file() {
    local service_name="$1"
    
    # Check common systemd service locations
    local service_file=""
    
    # User services
    if [[ -f "/etc/systemd/system/${service_name}.service" ]]; then
        echo "/etc/systemd/system/${service_name}.service"
        return 0
    fi
    
    # System services  
    if [[ -f "/lib/systemd/system/${service_name}.service" ]]; then
        echo "/lib/systemd/system/${service_name}.service"
        return 0
    fi
    
    # Additional system locations
    if [[ -f "/usr/lib/systemd/system/${service_name}.service" ]]; then
        echo "/usr/lib/systemd/system/${service_name}.service"
        return 0
    fi
    
    return 1
}

# Create instrumented systemd service override
create_systemd_override() {
    local service_name="$1"
    local otel_args="$2"
    
    local override_dir="/etc/systemd/system/${service_name}.service.d"
    local override_file="${override_dir}/middleware-instrumentation.conf"
    
    log_info "Creating systemd override for service: $service_name"
    
    # Create override directory
    mkdir -p "$override_dir" || {
        log_error "Failed to create override directory: $override_dir"
        return 1
    }
    
    # Get the original service's ExecStart command
    local original_exec_start=""
    if command -v systemctl >/dev/null 2>&1; then
        # Get the original ExecStart from systemd - parse the argv[] part
        local systemctl_output
        systemctl_output=$(systemctl show "$service_name" -p ExecStart --value 2>/dev/null)
        if [[ "$systemctl_output" == *"argv[]="* ]]; then
            # Extract the command from argv[]=command format
            original_exec_start=$(echo "$systemctl_output" | sed -n 's/.*argv\[\]=\([^;]*\).*/\1/p' | sed 's/^ *//; s/ *$//')
        fi
        
        if [[ -z "$original_exec_start" ]]; then
            log_warn "Could not determine original ExecStart from systemctl, trying service file"
            # Try to get from service file directly
            local service_file=""
            if [[ -f "/etc/systemd/system/${service_name}.service" ]]; then
                service_file="/etc/systemd/system/${service_name}.service"
            elif [[ -f "/lib/systemd/system/${service_name}.service" ]]; then
                service_file="/lib/systemd/system/${service_name}.service"
            elif [[ -f "/usr/lib/systemd/system/${service_name}.service" ]]; then
                service_file="/usr/lib/systemd/system/${service_name}.service"
            fi
            
            if [[ -n "$service_file" ]]; then
                original_exec_start=$(grep "^ExecStart=" "$service_file" 2>/dev/null | sed 's/^ExecStart=//')
            fi
        fi
    fi
    
    if [[ -z "$original_exec_start" ]]; then
        log_error "Could not determine original ExecStart command for service $service_name"
        return 1
    fi
    
    log_info "Original ExecStart: $original_exec_start"
    
    # Parse the original command to inject the Java agent
    local new_exec_start=""
    if [[ "$original_exec_start" == *"java "* ]]; then
        # Insert the Java agent right after 'java'
        new_exec_start="${original_exec_start//java /java $otel_args }"
    else
        log_error "Original ExecStart does not appear to be a Java command: $original_exec_start"
        return 1
    fi
    
    log_info "New ExecStart: $new_exec_start"
    
    # Parse OTEL args into environment variables
    local env_vars=""
    
    # Convert -D arguments to environment variables
    while read -r arg; do
        if [[ "$arg" == -D* ]]; then
            local key_value
            key_value="${arg#-D}"
            env_vars="${env_vars}Environment=\"$key_value\"\n"
        fi
    done <<< "$(echo "$otel_args" | tr ' ' '\n')"
    
    # Create override file
    cat > "$override_file" << EOF
# Middleware Java Agent Instrumentation Override
# Generated by Java Application Middleware Instrumentation Manager
# $(date)

[Service]
# Clear the original ExecStart and set the new instrumented one
ExecStart=
ExecStart=$new_exec_start

# OpenTelemetry Environment Variables (as backup)
$(echo -e "$env_vars")
EOF

    log_info "Created systemd override file: $override_file"
    log_info "Override will change ExecStart from:"
    log_info "  FROM: $original_exec_start"
    log_info "  TO:   $new_exec_start"
    return 0
}

# Remove systemd instrumentation override
remove_systemd_override() {
    local service_name="$1"
    
    local override_dir="/etc/systemd/system/${service_name}.service.d"
    local override_file="${override_dir}/middleware-instrumentation.conf"
    
    if [[ -f "$override_file" ]]; then
        log_info "Removing systemd override for service: $service_name"
        rm -f "$override_file" || {
            log_error "Failed to remove override file: $override_file"
            return 1
        }
        
        # Remove directory if empty
        if [[ -d "$override_dir" ]] && [[ -z "$(ls -A "$override_dir" 2>/dev/null)" ]]; then
            rmdir "$override_dir" 2>/dev/null || true
        fi
        
        log_info "Removed systemd override file: $override_file"
    else
        log_warn "No systemd override file found for service: $service_name"
    fi
    
    return 0
}

# Restart systemd service with instrumentation
restart_systemd_service() {
    local service_name="$1"
    local otel_args="$2"
    local action="$3" # "instrument", "uninstrument", or "re-instrument"
    
    log_info "Managing systemd service: $service_name (action: $action)"
    
    case "$action" in
        "instrument"|"re-instrument")
            # Create or update override
            if ! create_systemd_override "$service_name" "$otel_args"; then
                log_error "Failed to create systemd override for $service_name"
                return 1
            fi
            ;;
        "uninstrument")
            # Remove override
            if ! remove_systemd_override "$service_name"; then
                log_error "Failed to remove systemd override for $service_name"
                return 1
            fi
            ;;
        *)
            log_error "Unknown systemd action: $action"
            return 1
            ;;
    esac
    
    # Reload systemd configuration
    log_info "Reloading systemd daemon configuration..."
    if ! systemctl daemon-reload; then
        log_error "Failed to reload systemd daemon"
        return 1
    fi
    
    # Restart the service
    log_info "Restarting systemd service: $service_name"
    if ! systemctl restart "$service_name"; then
        log_error "Failed to restart systemd service: $service_name"
        
        # Show service status for debugging
        echo ""
        echo "Service status for debugging:"
        systemctl status "$service_name" --no-pager -l || true
        echo ""
        
        return 1
    fi
    
    # Wait a moment and check service status
    sleep 2
    if ! systemctl is-active "$service_name" >/dev/null 2>&1; then
        log_error "Service $service_name failed to start properly"
        echo ""
        echo "Service status:"
        systemctl status "$service_name" --no-pager -l || true
        echo ""
        return 1
    fi
    
    log_success "Successfully restarted systemd service: $service_name"
    return 0
}

# Get detailed process information for display
get_process_info() {
    local pid="$1"
    
    # Get command line
    local cmdline=""
    if cmdline=$(get_process_cmdline "$pid"); then
        :
    else
        cmdline="<unable to read>"
    fi
    
    # Check if it's a systemd service
    local systemd_service=""
    if is_systemd_service "$pid"; then
        systemd_service=$(get_systemd_service_name "$pid")
    fi
    
    # Determine instrumentation status and agent type
    local status="NOT_INSTRUMENTED"
    local agent_type=""
    local current_agent_path=""
    
    if [[ "$cmdline" == *"-javaagent:"* ]]; then
        # Extract the javaagent path
        current_agent_path=$(echo "$cmdline" | sed -n 's/.*-javaagent:\([^[:space:]]*\).*/\1/p')
        
        if [[ "$cmdline" == *"-javaagent:"*"middleware-javaagent"* ]]; then
            status="MIDDLEWARE_INSTRUMENTED"
            agent_type="Middleware"
        elif [[ "$cmdline" == *"-javaagent:"*"opentelemetry"* ]]; then
            status="OPENTELEMETRY_INSTRUMENTED"
            agent_type="OpenTelemetry"
        else
            status="OTHER_INSTRUMENTED"
            agent_type="Other"
        fi
    fi
    
    # Extract service name
    local service_name=""
    if [[ "$status" != "NOT_INSTRUMENTED" ]]; then
        # Try to extract from OTEL_SERVICE_NAME in environment or command line
        if [[ "$cmdline" == *"OTEL_SERVICE_NAME"* ]]; then
            service_name=$(echo "$cmdline" | sed -n 's/.*OTEL_SERVICE_NAME[=[:space:]]*\([^[:space:]]*\).*/\1/p')
        else
            service_name=$(extract_service_name "$cmdline")
        fi
    else
        service_name=$(extract_service_name "$cmdline")
    fi
    
    # Get working directory
    local cwd
    cwd=$(get_process_cwd "$pid")
    
    # Format output: PID|STATUS|AGENT_TYPE|SERVICE_NAME|AGENT_PATH|CWD|CMDLINE|SYSTEMD_SERVICE
    echo "${pid}|${status}|${agent_type}|${service_name}|${current_agent_path}|${cwd}|${cmdline}|${systemd_service}"
}

# Display comprehensive list of Java processes
display_java_processes() {
    log_info "Scanning for Java applications..."
    local java_pids=()
    mapfile -t java_pids < <(find_java_processes 2>> "${LOG_FILE}")
    
    if [[ ${#java_pids[@]} -eq 0 ]]; then
        log_warn "No Java applications found running on this system"
        return 1
    fi
    
    echo ""
    echo "==================================================================================="
    echo "                          JAVA APPLICATIONS DETECTED"
    echo "==================================================================================="
    echo ""
    
    # Store process info in array
    declare -A process_info_map
    local process_count=0
    
    for pid in "${java_pids[@]}"; do
        local info
        info=$(get_process_info "$pid")
        if [[ -n "$info" ]]; then
            process_count=$((process_count + 1))
            process_info_map["$process_count"]="$info"
        fi
    done
    
    # Display formatted table
    printf "%-4s %-8s %-20s %-15s %-20s %-15s %-30s\n" "ID" "PID" "STATUS" "AGENT" "SERVICE" "SYSTEMD" "COMMAND"
    echo "-----------------------------------------------------------------------------------------------------------"
    
    local middleware_count=0
    local opentel_count=0
    local other_agent_count=0
    local not_instrumented_count=0
    
    for i in $(seq 1 "$process_count"); do
        local info="${process_info_map[$i]}"
        IFS='|' read -r pid status agent_type service_name agent_path cwd cmdline systemd_service <<< "$info"
        
        # Count by status
        case "$status" in
            "MIDDLEWARE_INSTRUMENTED") middleware_count=$((middleware_count + 1)) ;;
            "OPENTELEMETRY_INSTRUMENTED") opentel_count=$((opentel_count + 1)) ;;
            "OTHER_INSTRUMENTED") other_agent_count=$((other_agent_count + 1)) ;;
            "NOT_INSTRUMENTED") not_instrumented_count=$((not_instrumented_count + 1)) ;;
        esac
        
        # Format status display
        local status_display=""
        case "$status" in
            "MIDDLEWARE_INSTRUMENTED") status_display="✅ Middleware" ;;
            "OPENTELEMETRY_INSTRUMENTED") status_display="🔧 OpenTelemetry" ;;
            "OTHER_INSTRUMENTED") status_display="⚙️  Other Agent" ;;
            "NOT_INSTRUMENTED") status_display="❌ Not Instrumented" ;;
        esac
        
        # Format systemd service display
        local systemd_display="Manual"
        if [[ -n "$systemd_service" ]]; then
            systemd_display="$systemd_service"
        fi
        
        # Truncate command for display
        local short_cmd
        short_cmd=$(echo "$cmdline" | cut -c1-30)
        if [[ ${#cmdline} -gt 30 ]]; then
            short_cmd="${short_cmd}..."
        fi
        
        printf "%-4s %-8s %-20s %-15s %-20s %-15s %-30s\n" "$i" "$pid" "$status_display" "$agent_type" "$service_name" "$systemd_display" "$short_cmd"
    done
    
    echo ""
    echo "==================================================================================="
    echo "SUMMARY:"
    echo "  ✅ Middleware Instrumented:     $middleware_count"
    echo "  🔧 OpenTelemetry Instrumented:  $opentel_count"  
    echo "  ⚙️  Other Agent Instrumented:    $other_agent_count"
    echo "  ❌ Not Instrumented:             $not_instrumented_count"
    echo "  📊 Total Java Applications:     $process_count"
    echo "==================================================================================="
    echo ""
    
    return 0
}

# Multi-selection menu for processes
select_processes() {
    local java_pids=()
    mapfile -t java_pids < <(find_java_processes 2>> "${LOG_FILE}")
    
    if [[ ${#java_pids[@]} -eq 0 ]]; then
        log_warn "No Java applications found"
        return 1
    fi
    
    # Build process info map
    declare -A process_info_map
    local process_count=0
    
    for pid in "${java_pids[@]}"; do
        local info
        info=$(get_process_info "$pid")
        if [[ -n "$info" ]]; then
            process_count=$((process_count + 1))
            process_info_map["$process_count"]="$info"
        fi
    done
    
    echo "Select applications to manage:"
    echo ""
    echo "Options:"
    echo "  - Enter numbers separated by spaces (e.g., 1 3 5)"
    echo "  - Use 'all' to select all applications"
    echo "  - Use 'uninstrumented' to select only uninstrumented apps"
    echo "  - Use 'instrumented' to select only instrumented apps"
    echo "  - Press Enter to cancel"
    echo ""
    
    local selected_processes=()
    while true; do
        echo -n "Your selection: "
        read -r selection
        
        if [[ -z "$selection" ]]; then
            echo "Selection cancelled."
            return 1
        fi
        
        selected_processes=()
        
        if [[ "$selection" == "all" ]]; then
            for i in $(seq 1 "$process_count"); do
                selected_processes+=("$i")
            done
            break
        elif [[ "$selection" == "uninstrumented" ]]; then
            for i in $(seq 1 "$process_count"); do
                local info="${process_info_map[$i]}"
                IFS='|' read -r pid status agent_type service_name agent_path cwd cmdline systemd_service <<< "$info"
                if [[ "$status" == "NOT_INSTRUMENTED" ]]; then
                    selected_processes+=("$i")
                fi
            done
            break
        elif [[ "$selection" == "instrumented" ]]; then
            for i in $(seq 1 "$process_count"); do
                local info="${process_info_map[$i]}"
                IFS='|' read -r pid status agent_type service_name agent_path cwd cmdline systemd_service <<< "$info"
                if [[ "$status" != "NOT_INSTRUMENTED" ]]; then
                    selected_processes+=("$i")
                fi
            done
            break
        else
            # Parse individual numbers
            local valid_selection=true
            for num in $selection; do
                if [[ "$num" =~ ^[0-9]+$ ]] && [[ "$num" -ge 1 ]] && [[ "$num" -le "$process_count" ]]; then
                    selected_processes+=("$num")
                else
                    echo "Error: '$num' is not a valid selection (1-$process_count)"
                    valid_selection=false
                    break
                fi
            done
            
            if [[ "$valid_selection" == true ]]; then
                break
            fi
        fi
    done
    
    if [[ ${#selected_processes[@]} -eq 0 ]]; then
        echo "No applications selected."
        return 1
    fi
    
    # Display selected applications
    echo ""
    echo "Selected applications:"
    echo "------------------------------------------------------------------------------------"
    printf "%-4s %-8s %-20s %-15s %-20s\n" "ID" "PID" "STATUS" "AGENT" "SERVICE"
    echo "------------------------------------------------------------------------------------"
    
    for i in "${selected_processes[@]}"; do
        local info="${process_info_map[$i]}"
        IFS='|' read -r pid status agent_type service_name agent_path cwd cmdline systemd_service <<< "$info"
        
        local status_display=""
        case "$status" in
            "MIDDLEWARE_INSTRUMENTED") status_display="✅ Middleware" ;;
            "OPENTELEMETRY_INSTRUMENTED") status_display="🔧 OpenTelemetry" ;;
            "OTHER_INSTRUMENTED") status_display="⚙️  Other Agent" ;;
            "NOT_INSTRUMENTED") status_display="❌ Not Instrumented" ;;
        esac
        
        printf "%-4s %-8s %-20s %-15s %-20s\n" "$i" "$pid" "$status_display" "$agent_type" "$service_name"
    done
    
    echo ""
    
    # Export selected processes for use in action menu
    export SELECTED_PROCESSES="${selected_processes[*]}"
    export -A PROCESS_INFO_MAP
    for i in $(seq 1 "$process_count"); do
        PROCESS_INFO_MAP["$i"]="${process_info_map[$i]}"
    done
    
    return 0
}

# Remove Java agent from process (uninstrumentation)
uninstrument_process() {
    local pid="$1"
    local cmdline="$2"
    local cwd="$3"
    local service_name="$4"
    
    log_info "Removing Java agent from PID=$pid"
    
    # Backup process information
    backup_process_info "$pid"
    
    # Parse command line and remove javaagent
    local java_cmd=""
    local main_part=""
    
    if [[ "$cmdline" == *"java "* ]]; then
        java_cmd=$(echo "$cmdline" | awk '{print $1}')
        main_part=$(echo "$cmdline" | cut -d' ' -f2-)
    else
        log_error "Unable to parse Java command from: $cmdline"
        return 1
    fi
    
    # Remove all -javaagent parameters
    local cleaned_main_part="$main_part"
    if [[ "$main_part" == *"-javaagent:"* ]]; then
        log_info "Removing Java agent(s) from command line..."
        cleaned_main_part=$(echo "$main_part" | sed -E 's/-javaagent:[^[:space:]]+[[:space:]]*//g')
        cleaned_main_part=$(echo "$cleaned_main_part" | sed -E 's/[[:space:]]+/ /g' | sed -E 's/^[[:space:]]+|[[:space:]]+$//')
    fi
    
    # Remove OTEL environment variables from command line if present
    cleaned_main_part=$(echo "$cleaned_main_part" | sed -E 's/-DOTEL_[^[:space:]]*[[:space:]]*//g')
    cleaned_main_part=$(echo "$cleaned_main_part" | sed -E 's/[[:space:]]+/ /g' | sed -E 's/^[[:space:]]+|[[:space:]]+$//')
    
    local new_cmdline="$java_cmd $cleaned_main_part"
    
    log_info "Original command: $cmdline"
    log_info "New command: $new_cmdline"
    log_info "Working directory: $cwd"
    
    # Stop the original process gracefully
    log_info "Stopping instrumented process PID=$pid gracefully..."
    if kill -TERM "$pid" 2>/dev/null; then
        local count=0
        while kill -0 "$pid" 2>/dev/null && [[ $count -lt 30 ]]; do
            sleep 1
            ((count++))
        done
        
        if kill -0 "$pid" 2>/dev/null; then
            log_warn "Process did not stop gracefully, force killing..."
            kill -KILL "$pid" 2>/dev/null || true
        fi
    else
        log_error "Failed to stop process PID=$pid"
        return 1
    fi
    
    # Start the uninstrumented process
    log_info "Starting uninstrumented process..."
    cd "$cwd"
    
    nohup "$new_cmdline" > "${LOG_FILE}.${pid}.uninstrumented.out" 2>&1 &
    local new_pid=$!
    
    log_success "Started uninstrumented process with PID=$new_pid"
    log_info "Process output redirected to: ${LOG_FILE}.${pid}.uninstrumented.out"
    
    return 0
}

# Action selection menu
select_action() {
    echo ""
    echo "==================================================================================="
    echo "                             ACTION SELECTION"
    echo "==================================================================================="
    echo ""
    echo "What would you like to do with the selected applications?"
    echo ""
    echo "  1) 🔧 INSTRUMENT      - Add Middleware Java agent to uninstrumented apps"
    echo "  2) 🔄 RE-INSTRUMENT   - Replace existing agent with Middleware Java agent"
    echo "  3) ❌ UNINSTRUMENT    - Remove Java agent (make apps uninstrumented)"
    echo "  4) 🔍 SHOW DETAILS    - Display detailed information about selected apps"
    echo "  5) ↩️  BACK TO LIST    - Go back to application selection"
    echo "  6) 🚪 EXIT           - Exit the script"
    echo ""
    
    while true; do
        echo -n "Enter your choice (1-6): "
        read -r action_choice
        
        case "$action_choice" in
            1) export SELECTED_ACTION="INSTRUMENT"; break ;;
            2) export SELECTED_ACTION="RE_INSTRUMENT"; break ;;
            3) export SELECTED_ACTION="UNINSTRUMENT"; break ;;
            4) export SELECTED_ACTION="SHOW_DETAILS"; break ;;
            5) export SELECTED_ACTION="BACK_TO_LIST"; break ;;
            6) log_info "Exiting..."; exit 0 ;;
            *) echo "Invalid choice. Please enter 1-6." ;;
        esac
    done
    
    return 0
}

# Show detailed information about selected processes
show_process_details() {
    local selected_processes=("$1")
    
    echo ""
    echo "==================================================================================="
    echo "                            DETAILED PROCESS INFORMATION"
    echo "==================================================================================="
    echo ""
    
    for i in "${selected_processes[@]}"; do
        local info="${PROCESS_INFO_MAP[$i]}"
        IFS='|' read -r pid status agent_type service_name agent_path cwd cmdline systemd_service <<< "$info"
        
        echo "Application ID: $i"
        echo "Process ID: $pid"
        echo "Status: $status"
        echo "Agent Type: $agent_type"
        echo "Service Name: $service_name"
        echo "Working Directory: $cwd"
        if [[ -n "$systemd_service" ]]; then
            echo "Systemd Service: $systemd_service"
        fi
        if [[ -n "$agent_path" ]]; then
            echo "Current Agent Path: $agent_path"
        fi
        echo "Full Command Line: $cmdline"
        echo ""
        echo "------------------------------------------------------------------------------------"
        echo ""
    done
    
    echo -n "Press Enter to continue..."
    read -r
}

# Batch process selected applications
batch_process_applications() {
    local selected_processes=("$1")
    local action="$2"
    
    echo ""
    echo "==================================================================================="
    echo "                              BATCH PROCESSING"
    echo "==================================================================================="
    echo ""
    
    local success_count=0
    local skip_count=0
    local error_count=0
    
    case "$action" in
        "SHOW_DETAILS")
            show_process_details "$1"
            return 0
            ;;
        "INSTRUMENT")
            echo "🔧 Starting instrumentation of selected applications..."
            ;;
        "RE_INSTRUMENT") 
            echo "🔄 Starting re-instrumentation of selected applications..."
            ;;
        "UNINSTRUMENT")
            echo "❌ Starting uninstrumentation of selected applications..."
            ;;
        *)
            log_error "Unknown action: $action"
            return 1
            ;;
    esac
    
    echo ""
    
    for i in "${selected_processes[@]}"; do
        local info="${PROCESS_INFO_MAP[$i]}"
        IFS='|' read -r pid status agent_type service_name agent_path cwd cmdline systemd_service <<< "$info"
        
        echo "Processing Application ID: $i (PID: $pid, Service: $service_name)"
        echo "Current Status: $status"
        
        # Show systemd service info if applicable
        if [[ -n "$systemd_service" ]]; then
            echo "Systemd Service: $systemd_service"
        fi
        
        # Determine if action is applicable
        local should_process=true
        local skip_reason=""
        
        case "$action" in
            "INSTRUMENT")
                if [[ "$status" != "NOT_INSTRUMENTED" ]]; then
                    should_process=false
                    skip_reason="Already instrumented (use re-instrument instead)"
                fi
                ;;
            "RE_INSTRUMENT")
                if [[ "$status" == "MIDDLEWARE_INSTRUMENTED" ]]; then
                    should_process=false
                    skip_reason="Already using Middleware Java agent"
                fi
                ;;
            "UNINSTRUMENT")
                if [[ "$status" == "NOT_INSTRUMENTED" ]]; then
                    should_process=false
                    skip_reason="Already uninstrumented"
                fi
                ;;
        esac
        
        if [[ "$should_process" == false ]]; then
            log_info "Skipping: $skip_reason"
            skip_count=$((skip_count + 1))
            echo ""
            continue
        fi
        
        # Confirm individual action unless in batch mode
        if [[ "${BATCH_CONFIRM:-false}" != "true" ]]; then
            local action_verb=""
            case "$action" in
                "INSTRUMENT") action_verb="instrument" ;;
                "RE_INSTRUMENT") action_verb="re-instrument" ;;
                "UNINSTRUMENT") action_verb="uninstrument" ;;
            esac
            
            local process_desc="PID $pid ($service_name)"
            if [[ -n "$systemd_service" ]]; then
                process_desc="systemd service '$systemd_service' (PID $pid)"
            fi
            
            echo -n "Do you want to $action_verb $process_desc? [y/N/a(ll)]: "
            read -r confirm
            
            if [[ "$confirm" =~ ^[Aa]$ ]]; then
                export BATCH_CONFIRM="true"
                log_info "Batch mode enabled for remaining applications"
            elif [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                log_info "Skipping $process_desc"
                skip_count=$((skip_count + 1))
                echo ""
                continue
            fi
        fi
        
        # Execute the action - use systemd management for systemd services
        local result=0
        if [[ -n "$systemd_service" ]]; then
            # Handle systemd service
            local otel_args
            otel_args=""
            if [[ "$action" != "UNINSTRUMENT" ]]; then
                otel_args=$(generate_otel_args "$service_name")
            fi
            
            case "$action" in
                "INSTRUMENT")
                    restart_systemd_service "$systemd_service" "$otel_args" "instrument"
                    result=$?
                    ;;
                "RE_INSTRUMENT")
                    restart_systemd_service "$systemd_service" "$otel_args" "re-instrument"
                    result=$?
                    ;;
                "UNINSTRUMENT")
                    restart_systemd_service "$systemd_service" "" "uninstrument"
                    result=$?
                    ;;
            esac
        else
            # Handle manual process
            case "$action" in
                "INSTRUMENT"|"RE_INSTRUMENT")
                    restart_with_instrumentation "$pid" "$cmdline" "$cwd" "$service_name"
                    result=$?
                    ;;
                "UNINSTRUMENT")
                    uninstrument_process "$pid" "$cmdline" "$cwd" "$service_name"
                    result=$?
                    ;;
            esac
        fi
        
        if [[ $result -eq 0 ]]; then
            success_count=$((success_count + 1))
            local process_desc="PID $pid"
            if [[ -n "$systemd_service" ]]; then
                process_desc="systemd service '$systemd_service'"
            fi
            log_success "Successfully processed $process_desc"
        else
            error_count=$((error_count + 1))
            local process_desc="PID $pid"
            if [[ -n "$systemd_service" ]]; then
                process_desc="systemd service '$systemd_service'"
            fi
            log_error "Failed to process $process_desc"
        fi
        
        echo ""
    done
    
    # Display final summary
    echo "==================================================================================="
    echo "                              BATCH PROCESSING COMPLETE"
    echo "==================================================================================="
    echo ""
    echo "Summary:"
    echo "  ✅ Successfully processed: $success_count applications"
    echo "  ⏭️  Skipped:               $skip_count applications"
    echo "  ❌ Errors:                $error_count applications"
    echo "  📊 Total selected:        ${#selected_processes[@]} applications"
    echo ""
    
    if [[ $error_count -gt 0 ]]; then
        echo "⚠️  Some applications failed to process. Check the log file for details: $LOG_FILE"
    else
        echo "🎉 All applicable applications were processed successfully!"
    fi
    echo ""
}

# Interactive main workflow
interactive_main() {
    while true; do
        # Display all Java processes
        if ! display_java_processes; then
            log_info "No Java applications found. Exiting."
            exit 0
        fi
        
        # Let user select processes
        if ! select_processes; then
            log_info "No processes selected. Exiting."
            exit 0
        fi
        
        # Let user select action
        select_action
        
        local selected_processes=()
        read -ra selected_processes <<< "$SELECTED_PROCESSES"
        local action="$SELECTED_ACTION"
        
        # Handle special actions
        if [[ "$action" == "BACK_TO_LIST" ]]; then
            continue  # Go back to the start of the loop
        fi
        
        # Process the selected applications
        batch_process_applications "${selected_processes[@]}" "$action"
        
        # Ask if user wants to continue
        echo -n "Would you like to manage more applications? [y/N]: "
        read -r continue_response
        if [[ ! "$continue_response" =~ ^[Yy]$ ]]; then
            break
        fi
        
        # Reset batch confirmation for next round
        unset BATCH_CONFIRM
        echo ""
    done
    
    log_success "Java application management completed!"
    log_info "Check the log file for details: $LOG_FILE"
}

# Backup process information
backup_process_info() {
    local pid="$1"
    local backup_file
    backup_file="${BACKUP_DIR}/process-${pid}-$(date +%Y%m%d-%H%M%S).info"
    
    {
        echo "PID: $pid"
        echo "TIMESTAMP: $(date)"
        echo "CMDLINE:"
        if get_process_cmdline "$pid"; then
            :  # Command line was successfully output
        else
            echo "Could not read command line"
        fi
        echo ""
        echo "CWD:"
        get_process_cwd "$pid"
        echo ""
        echo "ENVIRONMENT:"
        get_process_env "$pid"
    } > "$backup_file"
    
    log_info "Process information backed up to: $backup_file"
}

# Restart process with OpenTelemetry instrumentation
restart_with_instrumentation() {
    local pid="$1"
    local cmdline="$2"
    local cwd="$3"
    local service_name="$4"
    
    log_info "Instrumenting Java process PID=$pid"
    
    # Backup process information
    backup_process_info "$pid"
    
    # Generate OpenTelemetry arguments
    local otel_args
    otel_args=$(generate_otel_args "$service_name")
    
    # Parse the original command line and remove existing javaagents
    local java_cmd=""
    # local java_args=""
    local main_part=""
    
    # Split command line into java command and arguments
    if [[ "$cmdline" == *"java "* ]]; then
        java_cmd=$(echo "$cmdline" | awk '{print $1}')
        main_part=$(echo "$cmdline" | cut -d' ' -f2-)
    else
        log_error "Unable to parse Java command from: $cmdline"
        return 1
    fi
    
    # Remove existing -javaagent parameters from the command line
    local cleaned_main_part="$main_part"
    
    # Check if there are existing javaagents
    if [[ "$main_part" == *"-javaagent:"* ]]; then
        log_info "Removing existing javaagent(s) from command line..."
        
        # Remove all -javaagent:path parameters (handles multiple agents)
        # This regex removes -javaagent: followed by non-space characters
        cleaned_main_part=$(echo "$main_part" | sed -E 's/-javaagent:[^[:space:]]+[[:space:]]*//g')
        
        # Clean up any extra spaces
        cleaned_main_part=$(echo "$cleaned_main_part" | sed -E 's/[[:space:]]+/ /g' | sed -E 's/^[[:space:]]+|[[:space:]]+$//')
        
        log_info "Cleaned command line (without existing agents): $java_cmd $cleaned_main_part"
    fi
    
    # Insert Middleware agent before the main class/jar
    local new_cmdline="$java_cmd $otel_args $cleaned_main_part"
    
    log_info "Original command: $cmdline"
    log_info "New command: $new_cmdline"
    log_info "Working directory: $cwd"
    
    # Ask for confirmation
    local confirmation_msg="Restart this process with Middleware Java agent"
    if [[ "$main_part" == *"-javaagent:"* ]]; then
        confirmation_msg="$confirmation_msg (replacing existing agent)"
    fi
    confirmation_msg="$confirmation_msg? [y/N]: "
    
    echo -n "$confirmation_msg"
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        log_info "Skipping PID $pid"
        return 0
    fi
    
    # Stop the original process gracefully
    log_info "Stopping process PID=$pid gracefully..."
    if kill -TERM "$pid" 2>/dev/null; then
        # Wait for graceful shutdown
        local count=0
        while kill -0 "$pid" 2>/dev/null && [[ $count -lt 30 ]]; do
            sleep 1
            ((count++))
        done
        
        # Force kill if still running
        if kill -0 "$pid" 2>/dev/null; then
            log_warn "Process did not stop gracefully, force killing..."
            kill -KILL "$pid" 2>/dev/null || true
        fi
    else
        log_error "Failed to stop process PID=$pid"
        return 1
    fi
    
    # Start the new instrumented process
    log_info "Starting instrumented process..."
    cd "$cwd"
    
    # Start process in background and capture PID
    nohup "$new_cmdline" > "${LOG_FILE}.${pid}.out" 2>&1 &
    local new_pid=$!
    
    log_success "Started instrumented process with PID=$new_pid"
    log_info "Process output redirected to: ${LOG_FILE}.${pid}.out"
    
    return 0
}

# Main instrumentation function
instrument_java_processes() {
    log_info "Detecting running Java applications..."
    local java_pids=()
    mapfile -t java_pids < <(find_java_processes 2>> "${LOG_FILE}")
    
    log_info "Found ${#java_pids[@]} Java process(es) to potentially instrument"
    
    # Count instrumentation status
    local already_middleware=0
    local other_agents=0
    local not_instrumented=0
    
    for pid in "${java_pids[@]}"; do
        log_info "Checking instrumentation status for PID: $pid"
        
        # Add timeout for reading command line
        local cmdline=""
        local temp_file="/tmp/cmdline_$$_$pid"
        
        # Check if process still exists and has readable cmdline
        if [[ ! -r "/proc/$pid/cmdline" ]]; then
            log_warn "Process $pid cmdline not readable (process may have disappeared)"
            cmdline=""
        else
            # Try to read with timeout
            if timeout 3s bash -c "cat /proc/$pid/cmdline 2>/dev/null | tr '\0' ' '" > "$temp_file" 2>/dev/null; then
                cmdline=$(cat "$temp_file" 2>/dev/null || echo "")
                rm -f "$temp_file" 2>/dev/null
                
                # Check if result is empty or whitespace only
                if [[ -z "$(echo "$cmdline" | tr -d ' \t\n')" ]]; then
                    log_warn "Process $pid has empty or whitespace-only command line"
                    cmdline=""
                fi
            else
                log_warn "Timeout or error reading command line for PID $pid"
                cmdline=""
                rm -f "$temp_file" 2>/dev/null
            fi
        fi
        
        if [[ -n "$cmdline" ]]; then
            log_info "PID $pid has cmdline, checking instrumentation..."
            if [[ "$cmdline" == *"-javaagent:"*"middleware-javaagent"* ]]; then
                already_middleware=$((already_middleware + 1))
                log_info "PID $pid already has Middleware agent"
            elif is_already_instrumented "$cmdline"; then
                other_agents=$((other_agents + 1))
                log_info "PID $pid has other Java agent (OpenTelemetry or other)"
            else
                not_instrumented=$((not_instrumented + 1))
                log_info "PID $pid is not instrumented"
            fi
        else
            log_warn "Could not read command line for PID $pid - counting as not instrumented"
            not_instrumented=$((not_instrumented + 1))
        fi
        
        log_info "Completed checking PID $pid (so far: $already_middleware Middleware, $other_agents other agents, $not_instrumented not instrumented)"
    done
    
    log_info "Summary: $already_middleware already have Middleware agent, $other_agents have other agents, $not_instrumented not instrumented"
    
    for pid in "${java_pids[@]}"; do
        log_info "Processing PID: $pid"
        
        # Get process information
        local cmdline=""
        if cmdline=$(get_process_cmdline "$pid"); then
            # Successfully got command line
            :
        else
            log_warn "Could not read command line for PID $pid, skipping"
            continue
        fi
        
        local cwd
        cwd=$(get_process_cwd "$pid")
        
        # Check if already instrumented
        if [[ "$cmdline" == *"-javaagent:"*"middleware-javaagent"* ]]; then
            log_info "Process PID=$pid already has Middleware Java agent - skipping"
            continue
        elif is_already_instrumented "$cmdline"; then
            log_info "Process PID=$pid is already instrumented with another Java agent"
            
            # Determine current agent type
            local current_agent=""
            if [[ "$cmdline" == *"-javaagent:"*"opentelemetry"* ]]; then
                current_agent="OpenTelemetry agent"
            else
                current_agent="Unknown Java agent"
            fi
            
            log_info "Current agent: $current_agent"
            log_info "Target agent: Middleware Java agent"
            
            # Ask user if they want to override
            echo -n "Process PID=$pid is already instrumented with $current_agent. Override with Middleware agent? [y/N]: "
            read -r override_response
            if [[ ! "$override_response" =~ ^[Yy]$ ]]; then
                log_info "Skipping PID $pid - keeping existing instrumentation"
                continue
            fi
            
            log_info "User chose to override existing instrumentation for PID $pid"
        fi
        
        # Extract service name
        local service_name="${OTEL_SERVICE_NAME}"
        if [[ -z "$service_name" ]]; then
            service_name=$(extract_service_name "$cmdline")
        fi
        
        log_info "Detected service name: $service_name"
        
        # Restart with instrumentation
        if ! restart_with_instrumentation "$pid" "$cmdline" "$cwd" "$service_name"; then
            log_error "Failed to instrument process PID=$pid"
        fi
        
        echo ""
    done
}

# Print usage information
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Java Application Middleware Instrumentation Manager

Detects running Java applications and provides an interactive interface to:
- Instrument uninstrumented apps with Middleware Java agent
- Re-instrument apps with different agents  
- Uninstrument apps (remove Java agents)
- View detailed application information

MODES:
    Interactive Mode (default): Displays all Java apps with status and allows 
    multi-selection for batch operations

    Non-Interactive Mode: Legacy mode that processes all apps automatically

OPTIONS:
    -h, --help              Show this help message
    -s, --service-name      Set service name for all applications
    -e, --endpoint          Set OTLP endpoint (default: http://localhost:4317)
    -a, --attributes        Set resource attributes
    --dry-run              Show what would be done without making changes
    --list-only            Only list running Java processes
    --force-download       Force download of Middleware Java agent even if present
    --non-interactive      Use legacy non-interactive mode (auto-process all apps)

ENVIRONMENT VARIABLES:
    OTEL_SERVICE_NAME           Service name for all applications
    OTEL_RESOURCE_ATTRIBUTES    Resource attributes
    OTEL_EXPORTER_OTLP_ENDPOINT OTLP endpoint
    OTEL_EXPORTER_OTLP_PROTOCOL OTLP protocol (grpc or http/protobuf)
    OTEL_LOGS_EXPORTER          Logs exporter
    OTEL_METRICS_EXPORTER       Metrics exporter
    OTEL_TRACES_EXPORTER        Traces exporter

EXAMPLES:
    # Interactive mode (default) - select apps and actions
    sudo $0
    
    # Non-interactive mode - auto-instrument all uninstrumented apps
    sudo $0 --non-interactive
    
    # Dry run to see what would be done
    sudo $0 --dry-run
    
    # List running Java processes only
    $0 --list-only
    
    # Set service name for all applications
    sudo $0 -s my-microservice

INTERACTIVE MODE FEATURES:
    ✅ View all Java applications with current instrumentation status
    🔧 Select multiple applications for batch operations
    🔄 Instrument, re-instrument, or uninstrument applications
    📊 Detailed application information display
    ⚙️  Smart selection options (all, uninstrumented, instrumented)

EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                exit 0
                ;;
            -s|--service-name)
                OTEL_SERVICE_NAME="$2"
                shift 2
                ;;
            -e|--endpoint)
                OTEL_EXPORTER_OTLP_ENDPOINT="$2"
                shift 2
                ;;
            -a|--attributes)
                OTEL_RESOURCE_ATTRIBUTES="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --list-only)
                LIST_ONLY=true
                shift
                ;;
            --force-download)
                FORCE_DOWNLOAD=true
                shift
                ;;
            --non-interactive)
                NON_INTERACTIVE=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

# Main function
main() {
    echo "Java Application Middleware Instrumentation Manager"
    echo "==================================================="
    echo ""
    
    # Parse arguments
    parse_args "$@"
    
    # Check privileges
    check_privileges
    
    # Setup directories
    setup_directories
    
    # List only mode
    if [[ "${LIST_ONLY:-false}" == "true" ]]; then
        find_java_processes 2>> "${LOG_FILE}" > /dev/null
        exit 0
    fi
    
    # Download Middleware Java agent
    if [[ "${FORCE_DOWNLOAD:-false}" == "true" ]]; then
        rm -f "${OTEL_AGENT_JAR}"
    fi
    download_otel_agent
    
    # Dry run mode
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log_info "DRY RUN MODE - No changes will be made"
        echo ""
        # Show the enhanced interface even in dry run mode
        display_java_processes
        echo "This is a DRY RUN - no actual changes would be made."
        echo "Run without --dry-run to access the interactive interface."
        exit 0
    fi
    
    # Choose between interactive and non-interactive mode
    if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
        # Legacy non-interactive mode - process all applications automatically
        log_info "Running in non-interactive mode - processing all applications automatically"
        instrument_java_processes
        log_success "Java application instrumentation completed!"
        log_info "Check the log file for details: $LOG_FILE"
    else
        # New interactive mode (default)
        log_info "Running in interactive mode - you can select which applications to manage"
        interactive_main
    fi
}

# Execute main function with all arguments
main "$@"
