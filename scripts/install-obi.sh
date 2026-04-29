#!/bin/bash
# OpenTelemetry eBPF Instrumentation (OBI) Agent - Install Script
# Installs and configures OBI as a systemd service on Linux systems.
#
# Run `sudo bash install-obi.sh --help` for usage, flags, and environment variables.

set -euo pipefail

# ─── Constants ────────────────────────────────────────────────────────────────

readonly SCRIPT_VERSION="1.2.0"
readonly GITHUB_REPO="open-telemetry/opentelemetry-ebpf-instrumentation"
readonly GITHUB_API="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
readonly DOWNLOAD_BASE="https://github.com/${GITHUB_REPO}/releases/download"
readonly SERVICE_UNIT_NAME="obi-agent"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_UNIT_NAME}.service"

# ─── LOG_FILE defined early so traps can reference it ─────────────────────────

LOG_FILE="/var/log/${SERVICE_UNIT_NAME}/install-$(date +%s).log"

# ─── Defaults ─────────────────────────────────────────────────────────────────

INSTALL_DIR="${OBI_INSTALL_DIR:-/usr/local/bin}"
CONFIG_DIR="${OBI_CONFIG_DIR:-/etc/obi-agent}"
OTEL_ENDPOINT="${OBI_OTEL_ENDPOINT:-http://localhost:9320}"
OTEL_PROTOCOL="${OBI_OTEL_PROTOCOL:-http/protobuf}"
AUTH_TOKEN="${OBI_AUTH_TOKEN:-}"
LOG_LEVEL="${OBI_LOG_LEVEL:-INFO}"
CONFIG_FILE_OVERRIDE="${OBI_CONFIG_FILE:-}"
INSTALL_ONLY="${OBI_INSTALL_ONLY:-false}"
AUTO_START="${OBI_AUTO_START:-true}"
CONTEXT_PROPAGATION="${OBI_CONTEXT_PROPAGATION:-all}"
DRY_RUN=false

# ─── Logging helpers ──────────────────────────────────────────────────────────

log_info()    { echo "[INFO]  $*"; }
log_ok()      { echo "[OK]    $*"; }
log_warn()    { echo "[WARN]  $*"; }
log_error()   { echo "[ERROR] $*"; }

# ─── Utility: check if a command exists ───────────────────────────────────────

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# ─── Cleanup on exit ─────────────────────────────────────────────────────────

TEMP_DIR=""
cleanup() {
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup EXIT

on_error() {
    local exit_code=$?
    log_error "Installation failed (exit code: ${exit_code})."
    if [ -f "$LOG_FILE" ]; then
        log_error "Check the log file for details: ${LOG_FILE}"
    fi
    rollback
    exit "$exit_code"
}
trap on_error ERR

# ─── Rollback partial install on failure ──────────────────────────────────────

ROLLBACK_BINARIES=false
ROLLBACK_SERVICE=false

rollback() {
    log_warn "Rolling back partial installation..."

    if [ "$ROLLBACK_SERVICE" = true ]; then
        systemctl stop "$SERVICE_UNIT_NAME" 2>/dev/null || true
        systemctl disable "$SERVICE_UNIT_NAME" 2>/dev/null || true
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload 2>/dev/null || true
        log_info "Removed systemd service."
    fi

    if [ "$ROLLBACK_BINARIES" = true ]; then
        rm -f "${INSTALL_DIR}/obi"
        rm -f "${INSTALL_DIR}/obi-java-agent.jar"
        rm -f "${INSTALL_DIR}/k8s-cache"
        rm -f /etc/profile.d/obi-agent.sh
        log_info "Removed installed binaries."
    fi
}

# ─── Prompt to continue on non-fatal warnings ────────────────────────────────

force_continue() {
    if ! tty -s; then
        log_warn "Non-interactive shell detected. Continuing automatically."
        return 0
    fi
    read -r -p "Do you still want to continue? (y/N): " response
    case "$response" in
        [yY]) echo "Continuing..." ;;
        *)    echo "Exiting."; exit 1 ;;
    esac
}

# ─── Help ─────────────────────────────────────────────────────────────────────

show_help() {
    cat <<'EOF'
OBI Agent Install Script

Installs the OpenTelemetry eBPF Instrumentation (OBI) agent as a
systemd service on Linux (amd64 / arm64).

USAGE:
    sudo bash install-obi.sh [OPTIONS]

OPTIONS:
    --help          Show this help message and exit
    --dry-run       Validate environment and print what would be done, without installing
    --uninstall     Remove OBI agent binaries, service, and config

ENVIRONMENT VARIABLES:
    OBI_VERSION              Pin a specific release (e.g. "0.3.0")
    OBI_OTEL_ENDPOINT        OTLP endpoint        (default: http://localhost:4318)
    OBI_OTEL_PROTOCOL        Export protocol       (default: http/protobuf)
    OBI_AUTH_TOKEN            Authorization header  (optional)
    OBI_LOG_LEVEL            DEBUG|INFO|WARN|ERROR (default: INFO)
    OBI_CONFIG_FILE          Path to custom config.yaml (optional)
    OBI_INSTALL_DIR          Binary directory      (default: /usr/local/bin)
    OBI_CONFIG_DIR           Config directory      (default: /etc/obi-agent)
    OBI_INSTALL_ONLY         "true" to skip enable/start
    OBI_AUTO_START           "true" to start after install (default: true)
    OBI_CONTEXT_PROPAGATION  all|traceparent|b3    (default: all)
    HTTPS_PROXY / HTTP_PROXY Proxy for downloads   (optional)

EXAMPLES:
    # Install latest version
    sudo bash install-obi.sh

    # Install specific version
    sudo OBI_VERSION=0.3.0 bash install-obi.sh

    # Install with custom endpoint, don't start
    sudo OBI_OTEL_ENDPOINT=http://collector:4318 OBI_INSTALL_ONLY=true bash install-obi.sh

    # Dry run
    sudo bash install-obi.sh --dry-run

    # Uninstall
    sudo bash install-obi.sh --uninstall
EOF
    exit 0
}

# ─── Uninstall ────────────────────────────────────────────────────────────────

uninstall() {
    log_info "Uninstalling OBI Agent..."

    if [ "$(id -u)" -ne 0 ]; then
        log_error "Uninstall must be run as root."
        exit 1
    fi

    # Stop and disable service
    if systemctl is-active --quiet "$SERVICE_UNIT_NAME" 2>/dev/null; then
        log_info "Stopping ${SERVICE_UNIT_NAME}..."
        systemctl stop "$SERVICE_UNIT_NAME"
    fi
    if systemctl is-enabled --quiet "$SERVICE_UNIT_NAME" 2>/dev/null; then
        log_info "Disabling ${SERVICE_UNIT_NAME}..."
        systemctl disable "$SERVICE_UNIT_NAME"
    fi
    if [ -f "$SERVICE_FILE" ]; then
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
        log_ok "Removed systemd service."
    fi

    # Remove binaries
    local removed=false
    for f in "${INSTALL_DIR}/obi" "${INSTALL_DIR}/obi-java-agent.jar" "${INSTALL_DIR}/k8s-cache"; do
        if [ -f "$f" ]; then
            rm -f "$f"
            log_ok "Removed: $f"
            removed=true
        fi
    done

    # Remove PATH profile
    if [ -f /etc/profile.d/obi-agent.sh ]; then
        rm -f /etc/profile.d/obi-agent.sh
        log_ok "Removed PATH profile."
    fi

    # Config: ask before deleting
    if [ -d "$CONFIG_DIR" ]; then
        if tty -s; then
            read -r -p "Remove configuration directory ${CONFIG_DIR}? (y/N): " response
            case "$response" in
                [yY])
                    rm -rf "$CONFIG_DIR"
                    log_ok "Removed configuration directory."
                    ;;
                *)
                    log_info "Configuration directory preserved."
                    ;;
            esac
        else
            log_info "Non-interactive mode. Configuration directory preserved at ${CONFIG_DIR}."
        fi
    fi

    # Log directory: leave it (logs are useful post-uninstall)
    log_ok "OBI Agent uninstalled."
    if [ "$removed" = false ]; then
        log_info "No binaries were found. OBI may not have been installed."
    fi
    exit 0
}

# ─── Validate inputs ─────────────────────────────────────────────────────────

validate_inputs() {
    # Validate OTEL endpoint format
    if ! [[ "$OTEL_ENDPOINT" =~ ^https?:// ]]; then
        log_error "OBI_OTEL_ENDPOINT must start with http:// or https://"
        log_error "Got: ${OTEL_ENDPOINT}"
        exit 1
    fi

    # Validate log level
    case "$LOG_LEVEL" in
        DEBUG|INFO|WARN|ERROR) ;;
        *)
            log_error "OBI_LOG_LEVEL must be one of: DEBUG, INFO, WARN, ERROR"
            log_error "Got: ${LOG_LEVEL}"
            exit 1
            ;;
    esac

    # Validate protocol
    case "$OTEL_PROTOCOL" in
        http/protobuf|http/json|grpc) ;;
        *)
            log_warn "OBI_OTEL_PROTOCOL '${OTEL_PROTOCOL}' is non-standard. Expected: http/protobuf, http/json, grpc"
            force_continue
            ;;
    esac

    # Validate context propagation
    case "$CONTEXT_PROPAGATION" in
        all|traceparent|b3) ;;
        *)
            log_warn "OBI_CONTEXT_PROPAGATION '${CONTEXT_PROPAGATION}' is non-standard. Expected: all, traceparent, b3"
            force_continue
            ;;
    esac

    log_ok "Input validation passed."
}

# ─── OS family detection ──────────────────────────────────────────────────────
# Sets OS_FAMILY to: RedHat, Debian, SUSE, or Unknown.
# Used only to decide whether a kernel 4.18 backport (RHEL-family) is acceptable.
# Parses /etc/os-release (present on every systemd-based distro, which this
# script already requires). Falls through to Unknown with a warning if absent.

OS_FAMILY="Unknown"
DISTRIBUTION=""

detect_os_family() {
    if [ ! -f /etc/os-release ]; then
        log_warn "/etc/os-release not found. Kernel compatibility checks may be less accurate."
        return
    fi

    local os_id os_id_like
    # shellcheck disable=SC1091
    os_id=$(. /etc/os-release && echo "${ID:-}" | tr '[:upper:]' '[:lower:]')
    # shellcheck disable=SC1091
    os_id_like=$(. /etc/os-release && echo "${ID_LIKE:-}" | tr '[:upper:]' '[:lower:]')
    DISTRIBUTION="${os_id:-unknown}"

    # ID first (standardized), then ID_LIKE for derivatives.
    local haystack=" ${os_id} ${os_id_like} "
    if [[ "$haystack" =~ (^|[\ ])(rhel|centos|fedora|rocky|almalinux|amzn|amazon|ol|oraclelinux|scientific|arista)([\ ]|$) ]]; then
        OS_FAMILY="RedHat"
    elif [[ "$haystack" =~ (^|[\ ])(debian|ubuntu|linuxmint|pop|elementary|kali|raspbian|neon)([\ ]|$) ]]; then
        OS_FAMILY="Debian"
    elif [[ "$haystack" =~ (^|[\ ])(sles|suse|opensuse|opensuse-leap|opensuse-tumbleweed)([\ ]|$) ]]; then
        OS_FAMILY="SUSE"
    fi

    if [ "$OS_FAMILY" != "Unknown" ]; then
        log_ok "OS detected: ${DISTRIBUTION} (family: ${OS_FAMILY})"
    else
        log_warn "Could not determine OS family (detected: ${DISTRIBUTION})."
        log_warn "Kernel compatibility checks may be less accurate."
    fi
}

# ─── Pre-flight checks ───────────────────────────────────────────────────────

preflight_checks() {
    log_info "Running pre-flight checks..."

    # Must be Linux
    if [ "$(uname -s)" != "Linux" ]; then
        log_error "This installer only supports Linux systems."
        exit 1
    fi

    # Must be root
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root (or with sudo)."
        exit 1
    fi

    # Check for required commands
    local required_cmds=("tar" "sha256sum" "chmod" "mkdir" "cp" "cat" "sed" "grep" "uname" "date" "mktemp" "tee" "id" "hostname" "cut")
    local missing_cmds=()

    for cmd in "${required_cmds[@]}"; do
        if ! command_exists "$cmd"; then
            missing_cmds+=("$cmd")
        fi
    done

    # Need at least one HTTP client
    if ! command_exists curl && ! command_exists wget; then
        missing_cmds+=("curl or wget")
    fi

    if [ ${#missing_cmds[@]} -ne 0 ]; then
        log_error "Missing required commands: ${missing_cmds[*]}"
        log_error "Please install them and re-run the script."
        exit 1
    fi

    # Check for systemd
    if ! command_exists systemctl; then
        log_error "systemctl not found. systemd is required to manage the OBI service."
        exit 1
    fi

    # Detect OS family (used for kernel compatibility decisions)
    detect_os_family

    # Check kernel version for eBPF/BTF support.
    # OBI requires kernel 5.8+ with BTF (general Linux) OR 4.18+ on RHEL-family
    # (which backports the needed eBPF features). Kernel 6.x+ is fully supported.
    local kernel_major kernel_minor kernel_full kernel_num
    kernel_major=$(uname -r | cut -d. -f1)
    kernel_minor=$(uname -r | cut -d. -f2)
    kernel_full=$(uname -r)
    kernel_num=$(( kernel_major * 1000 + kernel_minor ))

    if [ "$kernel_num" -ge 5008 ]; then
        # 5.8+ / 6.x — fully supported
        log_ok "Kernel ${kernel_full} is supported."
    elif [ "$kernel_num" -ge 4018 ] && [ "$OS_FAMILY" = "RedHat" ]; then
        # 4.18+ on RHEL-family — eBPF backports
        log_ok "RHEL-family kernel ${kernel_full} detected (eBPF backport support)."
    elif [ "$kernel_num" -ge 5000 ]; then
        # 5.0–5.7 — eBPF present but missing features OBI needs
        log_warn "Kernel ${kernel_full} may not have full eBPF/BTF support."
        log_warn "OBI requires kernel 5.8+ for full functionality."
        force_continue
    elif [ "$kernel_num" -ge 4018 ]; then
        # 4.18+ on non-RHEL — not officially supported
        log_warn "Kernel ${kernel_full} is only supported on RHEL/CentOS/Rocky/AlmaLinux/Amazon Linux."
        log_warn "On non-RHEL distributions, OBI requires kernel 5.8+ with BTF."
        force_continue
    else
        # < 4.18 — unsupported everywhere
        log_error "Kernel ${kernel_full} is not supported."
        log_error "OBI requires Linux kernel 5.8+ (with BTF), or 4.18+ on RHEL/CentOS 8."
        exit 1
    fi

    # Check for BTF support
    # BTF is required for OBI on general Linux (non-RHEL backport kernels).
    # It became enabled by default on most distros with kernel 5.14+.
    if [ -f /sys/kernel/btf/vmlinux ]; then
        log_ok "BTF support detected (/sys/kernel/btf/vmlinux)."
    else
        if [ "$OS_FAMILY" = "RedHat" ] && [ "$kernel_major" -eq 4 ]; then
            log_info "BTF not found, but RHEL-family 4.18 backport may not expose /sys/kernel/btf/vmlinux."
        else
            log_warn "BTF (/sys/kernel/btf/vmlinux) not found."
            log_warn "OBI requires BTF. Recompile your kernel with CONFIG_DEBUG_INFO_BTF=y if needed."
            force_continue
        fi
    fi

    # Proxy info
    if [ -n "${HTTPS_PROXY:-}" ] || [ -n "${HTTP_PROXY:-}" ]; then
        log_info "Proxy detected: HTTPS_PROXY=${HTTPS_PROXY:-} HTTP_PROXY=${HTTP_PROXY:-}"
    fi

    log_ok "Pre-flight checks passed."
}

# ─── Architecture detection ──────────────────────────────────────────────────

detect_arch() {
    local machine
    machine=$(uname -m)

    case "$machine" in
        x86_64|amd64)
            echo "amd64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        *)
            log_error "Unsupported architecture: ${machine}"
            log_error "OBI only provides binaries for amd64 and arm64."
            exit 1
            ;;
    esac
}

# ─── HTTP helper (supports both curl and wget, proxy-aware) ──────────────────

http_get() {
    local url="$1"
    local output="${2:-}"

    if command_exists curl; then
        if [ -n "$output" ]; then
            curl -fsSL --retry 3 --retry-delay 2 -o "$output" "$url"
        else
            curl -fsSL --retry 3 --retry-delay 2 "$url"
        fi
    elif command_exists wget; then
        if [ -n "$output" ]; then
            wget -q --tries=3 -O "$output" "$url"
        else
            wget -q --tries=3 -O - "$url"
        fi
    else
        log_error "Neither curl nor wget found."
        exit 1
    fi
}

# ─── Fetch latest version from GitHub ────────────────────────────────────────

get_latest_version() {
    log_info "Fetching latest OBI release version from GitHub..." >&2

    local api_response tag_name
    api_response=$(http_get "$GITHUB_API" 2>/dev/null) || true

    # Use jq if available for robust JSON parsing, fallback to grep+sed
    if command_exists jq; then
        tag_name=$(echo "$api_response" | jq -r '.tag_name // empty' 2>/dev/null | sed 's/^v//')
    else
        tag_name=$(echo "$api_response" | grep '"tag_name"' | sed -E 's/.*"tag_name":\s*"v?([^"]+)".*/\1/' | head -1)
    fi

    if [ -z "$tag_name" ] || [ "$tag_name" = "null" ]; then
        log_error "Failed to determine the latest OBI version from GitHub."
        log_error "This may be due to GitHub API rate limiting."
        log_error "Please set OBI_VERSION explicitly and re-run."
        exit 1
    fi

    echo "$tag_name"
}

# ─── Download and verify ─────────────────────────────────────────────────────

download_and_verify() {
    local version="$1"
    local arch="$2"

    local archive_name="obi-v${version}-linux-${arch}.tar.gz"
    local download_url="${DOWNLOAD_BASE}/v${version}/${archive_name}"
    local checksums_url="${DOWNLOAD_BASE}/v${version}/SHA256SUMS"

    TEMP_DIR=$(mktemp -d -t obi-install-XXXXXXXXXX)
    cd "$TEMP_DIR"

    log_info "Downloading OBI v${version} for ${arch}..."
    if ! http_get "$download_url" "$archive_name"; then
        log_error "Failed to download: ${download_url}"
        log_error "Please verify that version '${version}' exists for architecture '${arch}'."
        log_error "Available releases: https://github.com/${GITHUB_REPO}/releases"
        exit 1
    fi
    log_ok "Downloaded ${archive_name}."

    log_info "Downloading SHA256 checksums..."
    if http_get "$checksums_url" "SHA256SUMS" 2>/dev/null; then
        log_info "Verifying archive integrity..."
        if sha256sum -c SHA256SUMS --ignore-missing --status 2>/dev/null; then
            log_ok "SHA256 checksum verified."
        else
            log_error "SHA256 checksum verification FAILED. The download may be corrupted."
            exit 1
        fi
    else
        log_warn "SHA256SUMS not available for this release. Skipping checksum verification."
    fi

    log_info "Extracting archive..."
    tar -xzf "$archive_name"
    log_ok "Archive extracted."
}

# ─── Install binaries ────────────────────────────────────────────────────────

install_binaries() {
    log_info "Installing binaries to ${INSTALL_DIR}..."

    mkdir -p "$INSTALL_DIR"

    # Install the main obi binary
    if [ -f "obi" ]; then
        cp -f obi "${INSTALL_DIR}/obi"
        chmod 755 "${INSTALL_DIR}/obi"
        log_ok "Installed: ${INSTALL_DIR}/obi"
    else
        log_error "obi binary not found in archive. The release format may have changed."
        exit 1
    fi

    ROLLBACK_BINARIES=true

    # Install the Java agent jar if present
    if [ -f "obi-java-agent.jar" ]; then
        cp -f obi-java-agent.jar "${INSTALL_DIR}/obi-java-agent.jar"
        chmod 644 "${INSTALL_DIR}/obi-java-agent.jar"
        log_ok "Installed: ${INSTALL_DIR}/obi-java-agent.jar"
    fi

    # Install k8s-cache if present
    if [ -f "k8s-cache" ]; then
        cp -f k8s-cache "${INSTALL_DIR}/k8s-cache"
        chmod 755 "${INSTALL_DIR}/k8s-cache"
        log_ok "Installed: ${INSTALL_DIR}/k8s-cache"
    fi

    # Add to PATH via /etc/profile.d if not already present
    if [ ! -f /etc/profile.d/obi-agent.sh ]; then
        # Check if INSTALL_DIR is already in the default PATH
        if ! echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
            echo "export PATH=${INSTALL_DIR}:\$PATH" > /etc/profile.d/obi-agent.sh
            chmod 644 /etc/profile.d/obi-agent.sh
            log_ok "Added ${INSTALL_DIR} to system PATH via /etc/profile.d/obi-agent.sh"
        else
            log_info "${INSTALL_DIR} is already in PATH."
        fi
    else
        log_info "PATH profile already exists at /etc/profile.d/obi-agent.sh"
    fi

    # Quick verification
    if "${INSTALL_DIR}/obi" --version &>/dev/null; then
        local installed_version
        installed_version=$("${INSTALL_DIR}/obi" --version 2>&1 || true)
        log_ok "OBI binary verified: ${installed_version}"
    else
        log_warn "Could not verify OBI binary version (--version flag may not be supported in this release)."
    fi
}

# ─── Generate configuration ──────────────────────────────────────────────────

generate_config() {
    local config_file="${CONFIG_DIR}/config.yaml"

    mkdir -p "$CONFIG_DIR"

    # If a custom config file was provided, copy it
    if [ -n "$CONFIG_FILE_OVERRIDE" ]; then
        if [ ! -f "$CONFIG_FILE_OVERRIDE" ]; then
            log_error "Custom config file not found: ${CONFIG_FILE_OVERRIDE}"
            exit 1
        fi
        cp -f "$CONFIG_FILE_OVERRIDE" "$config_file"
        chmod 640 "$config_file"
        log_ok "Copied custom config to ${config_file}"
        return
    fi

    # Do not overwrite existing config. But warn if it is missing sections
    # that OBI v0.8+ requires, so the user knows why the service might fail.
    if [ -f "$config_file" ]; then
        log_info "Existing configuration found at ${config_file}. Preserving it."
        if ! grep -qE '^otel_metrics_export:|^prometheus_export:|^metrics:' "$config_file" 2>/dev/null; then
            log_warn "Existing config does not declare a metrics exporter."
            log_warn "OBI v0.8+ refuses to start without one. If the service fails with"
            log_warn "  \"at least one of 'network', 'application' or 'stats' features must be enabled\""
            log_warn "append an otel_metrics_export section, or remove ${config_file} and reinstall."
        fi
        return
    fi

    log_info "Generating configuration: ${config_file}"

    cat > "$config_file" <<YAML
# ============================================================================
# OBI Agent Configuration
# Generated by install-obi.sh v${SCRIPT_VERSION} on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Documentation: https://opentelemetry.io/docs/zero-code/obi/
# ============================================================================

# Log verbosity. Accepted values: DEBUG, INFO, WARN, ERROR
log_level: ${LOG_LEVEL}

# eBPF instrumentation settings
ebpf:
  # Controls how trace context is propagated across service boundaries.
  # Accepted values: all, traceparent, b3
  context_propagation: ${CONTEXT_PROPAGATION}

# OTLP trace export configuration
# OBI sends captured traces to this endpoint using the OpenTelemetry protocol.
otel_traces_export:
  # The URL of your OTLP-compatible collector or backend.
  endpoint: ${OTEL_ENDPOINT}
  # Export protocol. Accepted values: http/protobuf, http/json, grpc
  protocol: ${OTEL_PROTOCOL}
YAML

    # Add auth header if provided
    if [ -n "$AUTH_TOKEN" ]; then
        cat >> "$config_file" <<YAML
  # Custom headers sent with every export request.
  headers:
    Authorization: "${AUTH_TOKEN}"
YAML
    fi

    # OTLP metrics export — required since OBI v0.8.0, which refuses to start
    # unless at least one metrics feature (network/application/stats) is active.
    cat >> "$config_file" <<YAML

# OTLP metrics export configuration
# Required by OBI: at least one of traces+metrics features must be active.
otel_metrics_export:
  endpoint: ${OTEL_ENDPOINT}
  protocol: ${OTEL_PROTOCOL}
YAML

    if [ -n "$AUTH_TOKEN" ]; then
        cat >> "$config_file" <<YAML
  headers:
    Authorization: "${AUTH_TOKEN}"
YAML
    fi

    # Enable the default metrics feature set. Without this, OBI v0.8+ exits with:
    # "at least one of 'network', 'application' or 'stats' features must be enabled"
    # Top-level YAML key is `metrics` (maps to pkg/export/otel/perapp.MetricsConfig);
    # the error message hints at `meter_provider` but that isn't an actual schema path.
    cat >> "$config_file" <<'YAML'

# Metrics features to enable. Accepted values: network, application, stats,
# network_inter_zone, application_span, application_span_otel,
# application_span_sizes, application_service_graph, application_host, ebpf, all
metrics:
  features:
    - network
    - application
    - stats
YAML

    # Always append the discovery section as commented-out documentation
    cat >> "$config_file" <<'YAML'

# ============================================================================
# Service Discovery (optional)
# ============================================================================
# Use this section to tell OBI which application ports to instrument.
# Each entry targets a port and assigns a logical service name that will
# appear in your traces and metrics.
#
# discovery:
#   instrument:
#     # Instrument a single port:
#     - open_ports: 8080
#       name: "my-web-app"
#
#     # Instrument multiple services:
#     - open_ports: 3000
#       name: "frontend"
#     - open_ports: 5432
#       name: "postgres"
#
# If 'discovery' is omitted entirely, OBI will attempt to auto-discover
# and instrument all eligible processes on the host.
YAML

    chmod 640 "$config_file"
    log_ok "Configuration written to ${config_file}"
}

# ─── Create systemd service ──────────────────────────────────────────────────

create_systemd_service() {
    log_info "Creating systemd service: ${SERVICE_UNIT_NAME}"

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=OpenTelemetry eBPF Instrumentation (OBI) Agent
Documentation=https://opentelemetry.io/docs/zero-code/obi/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/obi --config=${CONFIG_DIR}/config.yaml
Environment="OTEL_EXPORTER_OTLP_ENDPOINT=${OTEL_ENDPOINT}"
Restart=on-failure
RestartSec=5
TimeoutStopSec=15
LimitNOFILE=65536
LimitMEMLOCK=infinity

# Hardening
# OBI requires root and access to /sys, /proc for eBPF. ProtectSystem=full
# still allows writes to /etc and /usr is read-only which is fine.
# ProtectHome=true prevents access to /home, /root, /run/user.
# If OBI needs to instrument processes in user home dirs, set ProtectHome=false.
ProtectSystem=full
ProtectHome=true
NoNewPrivileges=false
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "$SERVICE_FILE"

    ROLLBACK_SERVICE=true

    systemctl daemon-reload
    log_ok "systemd service created: ${SERVICE_FILE}"
}

# ─── Enable and start service ────────────────────────────────────────────────

start_service() {
    if [ "$INSTALL_ONLY" = "true" ]; then
        log_info "OBI_INSTALL_ONLY is set. Skipping service enable and start."
        log_info "To start the service manually:"
        log_info "  systemctl enable --now ${SERVICE_UNIT_NAME}"
        return
    fi

    log_info "Enabling ${SERVICE_UNIT_NAME} service..."
    if ! systemctl enable "$SERVICE_UNIT_NAME" 2>/dev/null; then
        log_error "Failed to enable ${SERVICE_UNIT_NAME} service."
        exit 1
    fi
    log_ok "Service enabled to start on boot."

    if [ "$AUTO_START" != "true" ]; then
        log_info "OBI_AUTO_START is not true. Service enabled but not started."
        log_info "To start: systemctl start ${SERVICE_UNIT_NAME}"
        return
    fi

    # Stop if already running (upgrade scenario)
    if systemctl is-active --quiet "$SERVICE_UNIT_NAME" 2>/dev/null; then
        log_info "Stopping existing ${SERVICE_UNIT_NAME} service for upgrade..."
        systemctl stop "$SERVICE_UNIT_NAME"
    fi

    log_info "Starting ${SERVICE_UNIT_NAME}..."
    systemctl start "$SERVICE_UNIT_NAME"

    # Brief check that it's running
    sleep 2
    if systemctl is-active --quiet "$SERVICE_UNIT_NAME"; then
        log_ok "${SERVICE_UNIT_NAME} is running."
    else
        log_warn "${SERVICE_UNIT_NAME} may not have started correctly."
        log_warn "Check status with: systemctl status ${SERVICE_UNIT_NAME}"
        log_warn "Check logs with:   journalctl -u ${SERVICE_UNIT_NAME} -f"
    fi
}

# ─── Print summary ───────────────────────────────────────────────────────────

print_summary() {
    local version="$1"
    local arch="$2"

    echo ""
    echo "================================================================="
    echo "  OBI Agent v${version} (${arch}) installed successfully"
    echo "================================================================="
    echo ""
    echo "  Binary:        ${INSTALL_DIR}/obi"
    echo "  Config:        ${CONFIG_DIR}/config.yaml"
    echo "  Service:       ${SERVICE_UNIT_NAME}"
    echo "  Log file:      ${LOG_FILE}"
    echo ""
    echo "  Useful commands:"
    echo "    systemctl status ${SERVICE_UNIT_NAME}       # Check service status"
    echo "    journalctl -u ${SERVICE_UNIT_NAME} -f       # Follow logs"
    echo "    systemctl restart ${SERVICE_UNIT_NAME}      # Restart"
    echo "    systemctl stop ${SERVICE_UNIT_NAME}         # Stop"
    echo ""
    echo "  To edit configuration:"
    echo "    vi ${CONFIG_DIR}/config.yaml"
    echo "    systemctl restart ${SERVICE_UNIT_NAME}"
    echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    # Parse flags
    for arg in "$@"; do
        case "$arg" in
            --help|-h)    show_help ;;
            --uninstall)  uninstall ;;
            --dry-run)    DRY_RUN=true ;;
            *)
                log_error "Unknown option: ${arg}"
                log_error "Run with --help for usage."
                exit 1
                ;;
        esac
    done

    # Set up logging
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1

    echo ""
    log_info "OBI Agent Install Script v${SCRIPT_VERSION}"
    log_info "Date: $(date -u)"
    log_info "Host: $(hostname) | Kernel: $(uname -r) | Arch: $(uname -m)"
    [ "$DRY_RUN" = true ] && log_info "=== DRY RUN ==="
    echo ""

    # Step 1: Pre-flight
    preflight_checks

    # Step 2: Validate inputs
    validate_inputs

    # Step 3: Detect architecture
    local arch
    arch=$(detect_arch)
    log_info "Detected architecture: ${arch}"

    # Step 4: Determine version.
    # Precedence: OBI_VERSION env var (pin to a specific release) > latest GitHub tag.
    # Pinning is recommended for production — upstream may ship schema changes
    # that break the config this script generates.
    local version
    if [ -n "${OBI_VERSION:-}" ]; then
        version="${OBI_VERSION#v}"
        log_info "Using specified version: ${version}"
    else
        version=$(get_latest_version)
        log_info "Latest version: ${version}"
        log_info "(pin a known-good release with OBI_VERSION=<x.y.z> to avoid upstream surprises)"
    fi

    # Dry run: everything above was read-only validation; stop before any side-effects.
    if [ "$DRY_RUN" = true ]; then
        echo ""
        log_info "The following actions WOULD be performed:"
        echo ""
        echo "  Version:       v${version}"
        echo "  Architecture:  ${arch}"
        echo "  Download:      ${DOWNLOAD_BASE}/v${version}/obi-v${version}-linux-${arch}.tar.gz"
        echo "  Install dir:   ${INSTALL_DIR}"
        echo "  Config dir:    ${CONFIG_DIR}"
        echo "  Service file:  ${SERVICE_FILE}"
        echo "  OTLP endpoint: ${OTEL_ENDPOINT}"
        echo "  Protocol:      ${OTEL_PROTOCOL}"
        echo "  Log level:     ${LOG_LEVEL}"
        echo "  Auto-start:    ${AUTO_START}"
        echo "  Install only:  ${INSTALL_ONLY}"
        echo ""
        log_info "No changes were made. Remove --dry-run to install."
        exit 0
    fi

    # Step 5: Download, verify, extract
    download_and_verify "$version" "$arch"

    # Step 6: Install binaries
    install_binaries

    # Step 7: Generate config
    generate_config

    # Step 8: Create systemd service
    create_systemd_service

    # Step 9: Enable and start
    start_service

    # Step 10: Summary
    print_summary "$version" "$arch"

    log_ok "Installation completed successfully."
}

main "$@"
