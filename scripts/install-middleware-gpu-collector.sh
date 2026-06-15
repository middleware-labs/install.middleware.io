#!/bin/bash
# Middleware GPU OpenTelemetry Collector - Install Script
# Installs and configures the otelcol-middleware-gpu binary as a systemd service.
#
# Downloads a prebuilt release tarball from GitHub releases, installs the binary,
# writes a config and systemd unit, and starts the service.
#
# Run `sudo bash install-middleware-gpu.sh --help` for usage, flags, and env vars.

set -euo pipefail

# ─── Constants ────────────────────────────────────────────────────────────────

readonly SCRIPT_VERSION="1.0.0"
readonly GITHUB_REPO="${MW_GPU_GITHUB_REPO:-middleware-labs/opentelemetry-operations-collector}"
readonly GITHUB_API="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
readonly DOWNLOAD_BASE="https://github.com/${GITHUB_REPO}/releases/download"
readonly BINARY_NAME="otelcol-middleware-gpu"
readonly SERVICE_UNIT_NAME="otelcol-middleware-gpu"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_UNIT_NAME}.service"

# ─── LOG_FILE defined early so traps can reference it ─────────────────────────

LOG_FILE="/var/log/${SERVICE_UNIT_NAME}/install-$(date +%s).log"

# ─── Defaults ─────────────────────────────────────────────────────────────────

INSTALL_DIR="${MW_GPU_INSTALL_DIR:-/usr/bin}"
CONFIG_DIR="${MW_GPU_CONFIG_DIR:-/etc/${SERVICE_UNIT_NAME}}"
MW_TARGET="${MW_TARGET:-}"
MW_API_KEY="${MW_API_KEY:-}"
CONFIG_FILE_OVERRIDE="${MW_GPU_CONFIG_FILE:-}"
SERVICE_USER="${MW_GPU_SERVICE_USER:-root}"
INSTALL_ONLY="${MW_GPU_INSTALL_ONLY:-false}"
AUTO_START="${MW_GPU_AUTO_START:-true}"
DRY_RUN=false

# ─── Logging helpers ──────────────────────────────────────────────────────────

log_info()    { echo "[INFO]  $*"; }
log_ok()      { echo "[OK]    $*"; }
log_warn()    { echo "[WARN]  $*"; }
log_error()   { echo "[ERROR] $*"; }

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
        rm -f "${INSTALL_DIR}/${BINARY_NAME}"
        log_info "Removed installed binary."
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
Middleware GPU Collector Install Script

Installs the otelcol-middleware-gpu collector as a systemd service on Linux
(amd64 / arm64). The collector scrapes NVIDIA GPU telemetry (DCGM + NVML) and
exports it to the Middleware platform over OTLP.

USAGE:
    sudo MW_TARGET=... MW_API_KEY=... bash install-middleware-gpu.sh [OPTIONS]

OPTIONS:
    --help          Show this help message and exit
    --dry-run       Validate environment and print what would be done, without installing
    --uninstall     Remove the collector binary, service, and config

REQUIRED ENVIRONMENT VARIABLES:
    MW_TARGET                Middleware OTLP endpoint (e.g. https://<uid>.middleware.io:443)
    MW_API_KEY               Middleware API key (sent as the Authorization header)

OPTIONAL ENVIRONMENT VARIABLES:
    MW_GPU_VERSION           Pin a specific release (e.g. "0.1.2"); default: latest
    MW_GPU_CONFIG_FILE       Path to a custom config.yaml (overrides the bundled config)
    MW_GPU_INSTALL_DIR       Binary directory (default: /usr/bin)
    MW_GPU_CONFIG_DIR        Config directory (default: /etc/otelcol-middleware-gpu)
    MW_GPU_SERVICE_USER      User to run the service as (default: root)
    MW_GPU_INSTALL_ONLY      "true" to skip enable/start
    MW_GPU_AUTO_START        "true" to start after install (default: true)
    MW_GPU_GITHUB_REPO       Override the GitHub repo (owner/name)
    HTTPS_PROXY / HTTP_PROXY Proxy for downloads (optional)

EXAMPLES:
    # Install latest version
    sudo MW_TARGET=https://abc.middleware.io:443 MW_API_KEY=xxx \
        bash install-middleware-gpu.sh

    # Install a specific version, don't start
    sudo MW_TARGET=... MW_API_KEY=... MW_GPU_VERSION=0.1.2 MW_GPU_INSTALL_ONLY=true \
        bash install-middleware-gpu.sh

    # Dry run
    sudo bash install-middleware-gpu.sh --dry-run

    # Uninstall
    sudo bash install-middleware-gpu.sh --uninstall
EOF
    exit 0
}

# ─── Uninstall ────────────────────────────────────────────────────────────────

uninstall() {
    log_info "Uninstalling Middleware GPU Collector..."

    if [ "$(id -u)" -ne 0 ]; then
        log_error "Uninstall must be run as root."
        exit 1
    fi

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

    if [ -f "${INSTALL_DIR}/${BINARY_NAME}" ]; then
        rm -f "${INSTALL_DIR}/${BINARY_NAME}"
        log_ok "Removed: ${INSTALL_DIR}/${BINARY_NAME}"
    else
        log_info "No binary found at ${INSTALL_DIR}/${BINARY_NAME}. Collector may not have been installed."
    fi

    # Config: ask before deleting
    if [ -d "$CONFIG_DIR" ]; then
        if tty -s; then
            read -r -p "Remove configuration directory ${CONFIG_DIR}? (y/N): " response
            case "$response" in
                [yY]) rm -rf "$CONFIG_DIR"; log_ok "Removed configuration directory." ;;
                *)    log_info "Configuration directory preserved." ;;
            esac
        else
            log_info "Non-interactive mode. Configuration directory preserved at ${CONFIG_DIR}."
        fi
    fi

    log_ok "Middleware GPU Collector uninstalled."
    exit 0
}

# ─── Validate inputs ─────────────────────────────────────────────────────────

validate_inputs() {
    if [ -z "$MW_TARGET" ]; then
        log_error "MW_TARGET is required (your Middleware OTLP endpoint)."
        log_error "Example: MW_TARGET=https://<uid>.middleware.io:443"
        exit 1
    fi
    if ! [[ "$MW_TARGET" =~ ^https?:// ]]; then
        log_error "MW_TARGET must start with http:// or https://"
        log_error "Got: ${MW_TARGET}"
        exit 1
    fi
    if [ -z "$MW_API_KEY" ] && [ -z "$CONFIG_FILE_OVERRIDE" ]; then
        log_warn "MW_API_KEY is empty. The collector will export without an Authorization header."
        force_continue
    fi
    log_ok "Input validation passed."
}

# ─── Pre-flight checks ───────────────────────────────────────────────────────

preflight_checks() {
    log_info "Running pre-flight checks..."

    if [ "$(uname -s)" != "Linux" ]; then
        log_error "This installer only supports Linux systems."
        exit 1
    fi

    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root (or with sudo)."
        exit 1
    fi

    local required_cmds=("tar" "sha256sum" "chmod" "mkdir" "cp" "cat" "uname" "date" "mktemp" "tee" "id" "hostname" "cut")
    local missing_cmds=()
    for cmd in "${required_cmds[@]}"; do
        command_exists "$cmd" || missing_cmds+=("$cmd")
    done
    if ! command_exists curl && ! command_exists wget; then
        missing_cmds+=("curl or wget")
    fi
    if [ ${#missing_cmds[@]} -ne 0 ]; then
        log_error "Missing required commands: ${missing_cmds[*]}"
        exit 1
    fi

    if ! command_exists systemctl; then
        log_error "systemctl not found. systemd is required to manage the service."
        exit 1
    fi

    # NVIDIA driver / GPU library checks. The dcgm/nvml receivers dlopen the
    # NVIDIA libraries at runtime; without them those receivers log scrape
    # errors (the collector still starts).
    if command_exists nvidia-smi; then
        log_ok "nvidia-smi found (NVIDIA driver present)."
    else
        log_warn "nvidia-smi not found. The NVIDIA driver may not be installed."
        log_warn "The dcgm/nvml receivers need the NVIDIA driver to collect GPU metrics."
        force_continue
    fi
    # libnvidia-ml is what the nvml receiver loads.
    if ! ldconfig -p 2>/dev/null | grep -q 'libnvidia-ml\.so'; then
        log_warn "libnvidia-ml.so not found in the linker cache."
        log_warn "The nvml receiver may fail to collect metrics without it."
    fi
    # DCGM is a separate package (datacenter-gpu-manager).
    if ! ldconfig -p 2>/dev/null | grep -q 'libdcgm\.so'; then
        log_warn "libdcgm.so not found. The dcgm receiver requires NVIDIA DCGM."
        log_warn "Install it from NVIDIA's datacenter-gpu-manager package if you need DCGM metrics."
    fi

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
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *)
            log_error "Unsupported architecture: ${machine}"
            log_error "Only amd64 and arm64 binaries are published."
            exit 1
            ;;
    esac
}

# ─── HTTP helper (curl or wget, proxy-aware) ─────────────────────────────────

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
    log_info "Fetching latest release version from GitHub..." >&2
    local api_response tag_name
    api_response=$(http_get "$GITHUB_API" 2>/dev/null) || true
    if command_exists jq; then
        tag_name=$(echo "$api_response" | jq -r '.tag_name // empty' 2>/dev/null | sed 's/^v//')
    else
        tag_name=$(echo "$api_response" | grep '"tag_name"' | sed -E 's/.*"tag_name":\s*"v?([^"]+)".*/\1/' | head -1)
    fi
    if [ -z "$tag_name" ] || [ "$tag_name" = "null" ]; then
        log_error "Failed to determine the latest version from GitHub (possible API rate limiting)."
        log_error "Set MW_GPU_VERSION explicitly and re-run."
        exit 1
    fi
    echo "$tag_name"
}

# ─── Download and verify ─────────────────────────────────────────────────────

download_and_verify() {
    local version="$1"
    local arch="$2"

    # Expected release artifact naming. Must match release.sh:
    #   otelcol-middleware-gpu_<version>_linux_<arch>.tar.gz
    local archive_name="${BINARY_NAME}_${version}_linux_${arch}.tar.gz"
    local download_url="${DOWNLOAD_BASE}/v${version}/${archive_name}"
    local checksums_url="${DOWNLOAD_BASE}/v${version}/SHA256SUMS"

    TEMP_DIR=$(mktemp -d -t mw-gpu-install-XXXXXXXXXX)
    cd "$TEMP_DIR"

    log_info "Downloading ${BINARY_NAME} v${version} for ${arch}..."
    if ! http_get "$download_url" "$archive_name"; then
        log_error "Failed to download: ${download_url}"
        log_error "Verify version '${version}' exists for arch '${arch}'."
        log_error "Releases: https://github.com/${GITHUB_REPO}/releases"
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

# ─── Install binary ──────────────────────────────────────────────────────────

install_binary() {
    log_info "Installing binary to ${INSTALL_DIR}..."
    mkdir -p "$INSTALL_DIR"

    # The binary may be at the archive root or in a subdirectory.
    local src
    if [ -f "$BINARY_NAME" ]; then
        src="$BINARY_NAME"
    else
        src=$(find . -type f -name "$BINARY_NAME" | head -1)
    fi
    if [ -z "$src" ] || [ ! -f "$src" ]; then
        log_error "${BINARY_NAME} not found in archive. The release format may have changed."
        exit 1
    fi

    cp -f "$src" "${INSTALL_DIR}/${BINARY_NAME}"
    chmod 755 "${INSTALL_DIR}/${BINARY_NAME}"
    ROLLBACK_BINARIES=true
    log_ok "Installed: ${INSTALL_DIR}/${BINARY_NAME}"

    if "${INSTALL_DIR}/${BINARY_NAME}" --version &>/dev/null; then
        log_ok "Binary verified: $("${INSTALL_DIR}/${BINARY_NAME}" --version 2>&1 | head -1 || true)"
    else
        log_warn "Could not verify binary --version (flag may not be supported in this release)."
    fi
}

# ─── Install configuration ───────────────────────────────────────────────────
# The config is bundled in this script (kept in sync with config.example.yaml).
# It reads MW_TARGET / MW_API_KEY from the environment at run time, supplied via
# the systemd env file. An explicit MW_GPU_CONFIG_FILE override takes precedence,
# and an existing config is preserved on upgrade.
#
# NOTE: the heredoc delimiter is quoted ('MWGPUCONFIG') so ${env:...} and the
# OTTL expressions are written verbatim with no shell expansion. Keep this in
# sync with config.example.yaml.

install_config() {
    local config_file="${CONFIG_DIR}/config.yaml"
    mkdir -p "$CONFIG_DIR"

    # Explicit override wins.
    if [ -n "$CONFIG_FILE_OVERRIDE" ]; then
        if [ ! -f "$CONFIG_FILE_OVERRIDE" ]; then
            log_error "Custom config file not found: ${CONFIG_FILE_OVERRIDE}"
            exit 1
        fi
        cp -f "$CONFIG_FILE_OVERRIDE" "$config_file"
        chmod 640 "$config_file"
        log_ok "Installed custom config to ${config_file}"
        return
    fi

    # Don't clobber an existing config (upgrade scenario).
    if [ -f "$config_file" ]; then
        log_info "Existing configuration found at ${config_file}. Preserving it."
        return
    fi

    log_info "Writing bundled configuration: ${config_file}"
    cat > "$config_file" <<'MWGPUCONFIG'
# Configuration for the Middleware GPU OpenTelemetry Collector.
#
# Scrapes NVIDIA GPU telemetry (DCGM + NVML) and exports it to the
# Middleware platform over OTLP. MW_TARGET / MW_API_KEY are read from the
# environment (supplied by the systemd env file).

receivers:
  # NVIDIA Data Center GPU Manager metrics (requires the gpu build tag).
  dcgm:
    collection_interval: 30s
  # NVIDIA Management Library metrics (requires the gpu build tag).
  nvml:
    collection_interval: 30s
  # Receive OTLP from other agents/applications on this host (optional).
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  # Guard against unbounded memory use.
  memory_limiter:
    check_interval: 1s
    limit_percentage: 80
    spike_limit_percentage: 25
  # Tag metrics with host / cloud resource attributes.
  # host.id and host.name must be explicitly requested for the system detector
  # to emit them.
  resourcedetection:
    detectors: [env, system]
    timeout: 5s
    override: false
    system:
      resource_attributes:
        host.id:
          enabled: true
        host.name:
          enabled: true
  # Copy the detected host.name into host.id so both carry the hostname.
  # Must run AFTER resourcedetection (host.name is set there).
  transform/host_id_from_name:
    metric_statements:
      - context: resource
        statements:
          - set(attributes["host.id"], attributes["host.name"]) where attributes["host.name"] != nil
  # Promote the per-GPU nvml datapoint attributes (gpu_number, uuid, model)
  # up to resource attributes so each GPU is identified at the resource level.
  transform/gpu_to_resource:
    metric_statements:
      - context: datapoint
        statements:
          - set(resource.attributes["gpu.number"], attributes["gpu_number"]) where attributes["gpu_number"] != nil
          - set(resource.attributes["gpu.uuid"], attributes["uuid"]) where attributes["uuid"] != nil
          - set(resource.attributes["gpu.model"], attributes["model"]) where attributes["model"] != nil
          - delete_key(attributes, "gpu_number")
          - delete_key(attributes, "uuid")
          - delete_key(attributes, "model")

  # --- Derived GPU power (watts) + cumulative->delta conversion ---------------
  # 1. Clone the cumulative energy counter into a new series we will turn into
  #    watts, leaving the original energy counter intact for kWh / energy tiles.
  metricstransform:
    transforms:
      - include: gpu.dcgm.energy_consumption
        action: insert
        new_name: gpu.dcgm.power_usage
      # Clone the cumulative PCIe byte counter into a series we'll turn into a
      # bytes/sec rate, leaving the original counter for total-bytes tiles.
      - include: gpu.dcgm.pcie.io
        action: insert
        new_name: gpu.dcgm.pcie.io.rate
      # Same for the cumulative NVLink byte counter.
      - include: gpu.dcgm.nvlink.io
        action: insert
        new_name: gpu.dcgm.nvlink.io.rate

  # 2. Convert cumulative monotonic sums to delta temporality. This covers all
  #    dcgm cumulative counters (Middleware prefers delta) plus the power clone,
  #    which deltatorate needs as a delta to work from.
  cumulativetodelta:
    include:
      match_type: strict
      metrics:
        - gpu.dcgm.energy_consumption
        - gpu.dcgm.power_usage
        - gpu.dcgm.nvlink.io
        - gpu.dcgm.nvlink.io.rate
        - gpu.dcgm.pcie.io
        - gpu.dcgm.pcie.io.rate
        - gpu.dcgm.ecc_errors
        - gpu.dcgm.xid_errors
        - gpu.dcgm.clock.throttle_duration.time

  # 3. Convert the clones from delta to a per-second rate. The interval is
  #    divided out, so each value is correct at any scrape rate. deltatorate
  #    emits the results as gauges.
  #      power_usage:    ΔJ / Δs     = W
  #      pcie.io.rate:   Δbytes / Δs = bytes/sec (per network.io.direction)
  #      nvlink.io.rate: Δbytes / Δs = bytes/sec (per network.io.direction)
  deltatorate:
    metrics:
      - gpu.dcgm.power_usage
      - gpu.dcgm.pcie.io.rate
      - gpu.dcgm.nvlink.io.rate

  # 4. Relabel the derived metric's unit from J to W (deltatorate does not do
  #    this), and round the watt value to 2 decimal places. This OTTL version
  #    has no Round(), so emulate round-half-up with Int(x*100 + 0.5)/100
  #    (power is always >= 0, so adding 0.5 before truncation rounds correctly).
  transform/power_unit:
    metric_statements:
      - context: metric
        statements:
          # deltatorate auto-appends "/s" to units (J -> J/s, By -> By/s).
          # Override the power unit to the friendlier W; pcie.io.rate already
          # reads By/s from deltatorate, so it needs no relabel.
          - set(unit, "W") where name == "gpu.dcgm.power_usage"
      - context: datapoint
        statements:
          - set(value_double, Int(value_double * 100.0 + 0.5) / 100.0)
              where metric.name == "gpu.dcgm.power_usage"
          - set(value_double, Int(value_double * 100.0 + 0.5) / 100.0)
              where metric.name == "gpu.dcgm.pcie.io.rate"
          - set(value_double, Int(value_double * 100.0 + 0.5) / 100.0)
              where metric.name == "gpu.dcgm.nvlink.io.rate"

  # Batch before export for efficiency.
  batch:
    send_batch_size: 1024
    timeout: 5s

exporters:
  # Primary export to Middleware over OTLP/HTTP.
  otlphttp:
    endpoint: ${env:MW_TARGET}
    headers:
      authorization: ${env:MW_API_KEY}
  # Uncomment for local troubleshooting of the GPU metric stream.
  # debug:
  #   verbosity: detailed

service:
  pipelines:
    metrics:
      receivers: [dcgm, nvml, otlp]
      # Order is execution order: promote GPU attrs, detect host, clone energy,
      # cumulative->delta, delta->rate (watts), relabel unit, then batch.
      processors:
        - memory_limiter
        - transform/gpu_to_resource
        - resourcedetection
        - transform/host_id_from_name
        - metricstransform
        - cumulativetodelta
        - deltatorate
        - transform/power_unit
        - batch
      exporters: [otlphttp]
  telemetry:
    logs:
      level: info
MWGPUCONFIG

    chmod 640 "$config_file"
    log_ok "Configuration written to ${config_file}"
}

# ─── Write systemd environment file ──────────────────────────────────────────

write_env_file() {
    local env_file="${CONFIG_DIR}/${SERVICE_UNIT_NAME}.conf"
    log_info "Writing environment file: ${env_file}"
    cat > "$env_file" <<EOF
# Systemd environment file for the ${SERVICE_UNIT_NAME} service.

# Command-line options for the collector.
OTELCOL_OPTIONS="--config=${CONFIG_DIR}/config.yaml"

# Middleware OTLP endpoint and API key, referenced by config.yaml via \${env:...}.
MW_TARGET=${MW_TARGET}
MW_API_KEY=${MW_API_KEY}
EOF
    chmod 640 "$env_file"
    log_ok "Environment file written."
}

# ─── Create systemd service ──────────────────────────────────────────────────

create_systemd_service() {
    log_info "Creating systemd service: ${SERVICE_UNIT_NAME}"

    # If a non-root service user was requested, create it.
    if [ "$SERVICE_USER" != "root" ]; then
        if ! getent passwd "$SERVICE_USER" >/dev/null; then
            useradd --system --user-group --no-create-home --shell /sbin/nologin "$SERVICE_USER"
            log_ok "Created service user: ${SERVICE_USER}"
        fi
    fi

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Minimal OpenTelemetry Collector for NVIDIA GPU telemetry, exporting to Middleware via OTLP
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
EnvironmentFile=${CONFIG_DIR}/${SERVICE_UNIT_NAME}.conf
ExecStart=${INSTALL_DIR}/${BINARY_NAME} \$OTELCOL_OPTIONS
KillMode=mixed
Restart=on-failure
RestartSec=5
TimeoutStopSec=15
LimitNOFILE=65536

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
        log_info "MW_GPU_INSTALL_ONLY is set. Skipping enable and start."
        log_info "To start manually: systemctl enable --now ${SERVICE_UNIT_NAME}"
        return
    fi

    log_info "Enabling ${SERVICE_UNIT_NAME} service..."
    systemctl enable "$SERVICE_UNIT_NAME" 2>/dev/null
    log_ok "Service enabled to start on boot."

    if [ "$AUTO_START" != "true" ]; then
        log_info "MW_GPU_AUTO_START is not true. Service enabled but not started."
        log_info "To start: systemctl start ${SERVICE_UNIT_NAME}"
        return
    fi

    if systemctl is-active --quiet "$SERVICE_UNIT_NAME" 2>/dev/null; then
        log_info "Stopping existing ${SERVICE_UNIT_NAME} for upgrade..."
        systemctl stop "$SERVICE_UNIT_NAME"
    fi

    log_info "Starting ${SERVICE_UNIT_NAME}..."
    systemctl start "$SERVICE_UNIT_NAME"

    sleep 2
    if systemctl is-active --quiet "$SERVICE_UNIT_NAME"; then
        log_ok "${SERVICE_UNIT_NAME} is running."
    else
        log_warn "${SERVICE_UNIT_NAME} may not have started correctly."
        log_warn "Check status: systemctl status ${SERVICE_UNIT_NAME}"
        log_warn "Check logs:   journalctl -u ${SERVICE_UNIT_NAME} -f"
    fi
}

# ─── Print summary ───────────────────────────────────────────────────────────

print_summary() {
    local version="$1"
    local arch="$2"
    echo ""
    echo "================================================================="
    echo "  Middleware GPU Collector v${version} (${arch}) installed"
    echo "================================================================="
    echo ""
    echo "  Binary:        ${INSTALL_DIR}/${BINARY_NAME}"
    echo "  Config:        ${CONFIG_DIR}/config.yaml"
    echo "  Env file:      ${CONFIG_DIR}/${SERVICE_UNIT_NAME}.conf"
    echo "  Service:       ${SERVICE_UNIT_NAME} (runs as ${SERVICE_USER})"
    echo "  Log file:      ${LOG_FILE}"
    echo ""
    echo "  Useful commands:"
    echo "    systemctl status ${SERVICE_UNIT_NAME}"
    echo "    journalctl -u ${SERVICE_UNIT_NAME} -f"
    echo "    systemctl restart ${SERVICE_UNIT_NAME}"
    echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
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

    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1

    echo ""
    log_info "Middleware GPU Collector Install Script v${SCRIPT_VERSION}"
    log_info "Date: $(date -u)"
    log_info "Host: $(hostname) | Kernel: $(uname -r) | Arch: $(uname -m)"
    [ "$DRY_RUN" = true ] && log_info "=== DRY RUN ==="
    echo ""

    preflight_checks
    validate_inputs

    local arch
    arch=$(detect_arch)
    log_info "Detected architecture: ${arch}"

    local version
    if [ -n "${MW_GPU_VERSION:-}" ]; then
        version="${MW_GPU_VERSION#v}"
        log_info "Using specified version: ${version}"
    else
        version=$(get_latest_version)
        log_info "Latest version: ${version}"
    fi

    if [ "$DRY_RUN" = true ]; then
        echo ""
        log_info "The following actions WOULD be performed:"
        echo ""
        echo "  Version:       v${version}"
        echo "  Architecture:  ${arch}"
        echo "  Download:      ${DOWNLOAD_BASE}/v${version}/${BINARY_NAME}_${version}_linux_${arch}.tar.gz"
        echo "  Install dir:   ${INSTALL_DIR}"
        echo "  Config dir:    ${CONFIG_DIR}"
        echo "  Service file:  ${SERVICE_FILE}"
        echo "  Service user:  ${SERVICE_USER}"
        echo "  MW_TARGET:     ${MW_TARGET:-<unset>}"
        echo "  Auto-start:    ${AUTO_START}"
        echo "  Install only:  ${INSTALL_ONLY}"
        echo ""
        log_info "No changes were made. Remove --dry-run to install."
        exit 0
    fi

    download_and_verify "$version" "$arch"
    install_binary
    install_config
    write_env_file
    create_systemd_service
    start_service
    print_summary "$version" "$arch"

    log_ok "Installation completed successfully."
}

main "$@"
