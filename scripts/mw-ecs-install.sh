#!/bin/bash
set -euo pipefail

REPO="middleware-labs/mw-ecs-instrumentation"
BINARY_NAME="mw-ecs"
INSTALL_DIR="/opt/mw-agent/bin"
MW_CONFIG_FILE="/etc/mw-agent/mw-ecs.conf"

# ── Colors ────────────────────────────────────────────
RED='\033[31m'
GREEN='\033[32m'
CYAN='\033[36m'
YELLOW='\033[33m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

SEP="${DIM}──────────────────────────────────────────────────${RESET}"

info()  { echo -e "  ${CYAN}▸${RESET} $*"; }
ok()    { echo -e "  ${GREEN}✔${RESET} $*"; }
err()   { echo -e "  ${RED}✘${RESET} $*" >&2; }
fatal() { err "$@"; exit 1; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

run_sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif command_exists sudo; then
    sudo "$@"
  else
    fatal "Need root privileges but 'sudo' is not available."
  fi
}

# ── Banner ────────────────────────────────────────────
echo ""
echo -e "  ${BOLD}Middleware ECS CLI Installer${RESET}"
echo -e "  ${SEP}"
echo ""

# ── Preflight ─────────────────────────────────────────
for cmd in curl uname chmod; do
  command_exists "$cmd" || fatal "Required command '${BOLD}$cmd${RESET}' not found."
done

# ── Platform Detection ────────────────────────────────
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$OS" in
  linux)  OS="linux" ;;
  darwin) OS="darwin" ;;
  *)      fatal "Unsupported operating system: $OS" ;;
esac

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64)   ARCH="amd64" ;;
  aarch64|arm64)   ARCH="arm64" ;;
  *)               fatal "Unsupported architecture: $ARCH" ;;
esac

PKG_TYPE="binary"
if [ "$OS" = "linux" ]; then
  if command_exists dpkg && command_exists apt-get; then
    PKG_TYPE="deb"
  elif command_exists rpm; then
    PKG_TYPE="rpm"
  fi
fi

echo -e "  ${BOLD}Platform${RESET}"
echo -e "  ${SEP}"
echo -e "  OS:           ${CYAN}${OS}${RESET}"
echo -e "  Architecture: ${CYAN}${ARCH}${RESET}"
echo -e "  Install via:  ${CYAN}${PKG_TYPE}${RESET}"
echo ""

# ── Version ───────────────────────────────────────────
if [ -n "${MW_ECS_VERSION:-}" ]; then
  VERSION="$MW_ECS_VERSION"
else
  info "Fetching latest release ..."
  VERSION=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null \
    | grep '"tag_name":' \
    | sed -E 's/.*"([^"]+)".*/\1/') || true

  if [ -z "$VERSION" ] || [ "$VERSION" = "null" ]; then
    VERSION=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases" 2>/dev/null \
      | grep '"tag_name":' \
      | head -1 \
      | sed -E 's/.*"([^"]+)".*/\1/') || true
  fi

  if [ -z "$VERSION" ] || [ "$VERSION" = "null" ]; then
    fatal "Could not determine latest version. Set ${BOLD}MW_ECS_VERSION${RESET} and retry."
  fi
fi

VERSION_NUM="${VERSION#test-v}"
VERSION_NUM="${VERSION_NUM#v}"

echo -e "  ${BOLD}Version${RESET}"
echo -e "  ${SEP}"
echo -e "  Tag:     ${CYAN}${VERSION}${RESET}"
echo -e "  Number:  ${CYAN}${VERSION_NUM}${RESET}"
echo ""

# ── Download & Install ────────────────────────────────
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

echo -e "  ${BOLD}Installation${RESET}"
echo -e "  ${SEP}"

case "$PKG_TYPE" in
  deb)
    ASSET="${BINARY_NAME}-linux_${VERSION_NUM}_${ARCH}.deb"
    DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${VERSION}/${ASSET}"
    TMP_FILE="${TMP_DIR}/${ASSET}"

    info "Downloading ${BOLD}${ASSET}${RESET} ..."
    HTTP_CODE=$(curl -fSL -w "%{http_code}" -o "$TMP_FILE" "$DOWNLOAD_URL" 2>/dev/null) || true
    if [ ! -f "$TMP_FILE" ] || [ "${HTTP_CODE:-0}" -ge 400 ]; then
      fatal "Download failed (HTTP ${HTTP_CODE:-???})\n    URL: ${DOWNLOAD_URL}"
    fi
    ok "Downloaded"

    info "Installing .deb package ..."
    run_sudo dpkg -i "$TMP_FILE" > /dev/null 2>&1
    ok "Installed via ${BOLD}dpkg${RESET}"
    ;;

  rpm)
    RPM_ARCH="$ARCH"
    [ "$ARCH" = "amd64" ] && RPM_ARCH="x86_64"
    [ "$ARCH" = "arm64" ] && RPM_ARCH="aarch64"
    ASSET="${BINARY_NAME}-linux-${VERSION_NUM}.${RPM_ARCH}.rpm"
    DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${VERSION}/${ASSET}"
    TMP_FILE="${TMP_DIR}/${ASSET}"

    info "Downloading ${BOLD}${ASSET}${RESET} ..."
    HTTP_CODE=$(curl -fSL -w "%{http_code}" -o "$TMP_FILE" "$DOWNLOAD_URL" 2>/dev/null) || true
    if [ ! -f "$TMP_FILE" ] || [ "${HTTP_CODE:-0}" -ge 400 ]; then
      fatal "Download failed (HTTP ${HTTP_CODE:-???})\n    URL: ${DOWNLOAD_URL}"
    fi
    ok "Downloaded"

    info "Installing .rpm package ..."
    run_sudo rpm -U --force "$TMP_FILE" > /dev/null 2>&1
    ok "Installed via ${BOLD}rpm${RESET}"
    ;;

  binary)
    ASSET="${BINARY_NAME}-${OS}-${ARCH}"
    DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${VERSION}/${ASSET}"
    TMP_FILE="${TMP_DIR}/${BINARY_NAME}"

    info "Downloading ${BOLD}${ASSET}${RESET} ..."
    HTTP_CODE=$(curl -fSL -w "%{http_code}" -o "$TMP_FILE" "$DOWNLOAD_URL" 2>/dev/null) || true
    if [ ! -f "$TMP_FILE" ] || [ "${HTTP_CODE:-0}" -ge 400 ]; then
      fatal "Download failed (HTTP ${HTTP_CODE:-???})\n    URL: ${DOWNLOAD_URL}"
    fi
    ok "Downloaded"

    chmod +x "$TMP_FILE"
    run_sudo mkdir -p "$INSTALL_DIR"
    run_sudo mv "$TMP_FILE" "${INSTALL_DIR}/${BINARY_NAME}"
    ok "Installed to ${BOLD}${INSTALL_DIR}/${BINARY_NAME}${RESET}"
    ;;
esac

echo ""

# ── Configuration ─────────────────────────────────────
if [ -n "${MW_API_KEY:-}" ] || [ -n "${MW_TARGET:-}" ]; then
  echo -e "  ${BOLD}Configuration${RESET}"
  echo -e "  ${SEP}"

  run_sudo mkdir -p /etc/mw-agent
  {
    [ -n "${MW_API_KEY:-}" ]  && echo "MW_API_KEY=${MW_API_KEY}"
    [ -n "${MW_TARGET:-}" ]   && echo "MW_TARGET=${MW_TARGET}"
  } | run_sudo tee "$MW_CONFIG_FILE" > /dev/null
  run_sudo chmod 644 "$MW_CONFIG_FILE"

  ok "Saved to ${BOLD}${MW_CONFIG_FILE}${RESET}"
  [ -n "${MW_API_KEY:-}" ] && echo -e "    MW_API_KEY  = ${CYAN}${MW_API_KEY}${RESET}"
  [ -n "${MW_TARGET:-}" ]  && echo -e "    MW_TARGET   = ${CYAN}${MW_TARGET}${RESET}"
  echo ""
fi

# ── PATH ──────────────────────────────────────────────
echo -e "  ${BOLD}PATH${RESET}"
echo -e "  ${SEP}"

PATH_UPDATED=false
if [ -f "$HOME/.bashrc" ] && ! grep -q "$INSTALL_DIR" "$HOME/.bashrc" 2>/dev/null; then
  echo "export PATH=${INSTALL_DIR}:\$PATH" >> "$HOME/.bashrc"
  ok "Added to ${BOLD}.bashrc${RESET}"
  PATH_UPDATED=true
fi
if [ -f "$HOME/.zshrc" ] && ! grep -q "$INSTALL_DIR" "$HOME/.zshrc" 2>/dev/null; then
  echo "export PATH=${INSTALL_DIR}:\$PATH" >> "$HOME/.zshrc"
  ok "Added to ${BOLD}.zshrc${RESET}"
  PATH_UPDATED=true
fi
if [ "$OS" = "darwin" ] && [ -f "$HOME/.bash_profile" ] && ! grep -q "$INSTALL_DIR" "$HOME/.bash_profile" 2>/dev/null; then
  echo "export PATH=${INSTALL_DIR}:\$PATH" >> "$HOME/.bash_profile"
  ok "Added to ${BOLD}.bash_profile${RESET}"
  PATH_UPDATED=true
fi
if [ "$PATH_UPDATED" = false ]; then
  ok "${INSTALL_DIR} already in PATH"
fi
export PATH="${INSTALL_DIR}:$PATH"
echo ""

# ── Verify ────────────────────────────────────────────
echo -e "  ${BOLD}Verification${RESET}"
echo -e "  ${SEP}"

if command_exists "$BINARY_NAME"; then
  ok "${BOLD}${BINARY_NAME}${RESET} ${GREEN}v${VERSION_NUM}${RESET} is ready"
  echo ""
  echo -e "    ${DIM}\$ ${BINARY_NAME} --help${RESET}"
  "$BINARY_NAME" --help 2>&1 | head -3 | sed 's/^/    /'
else
  echo -e "  ${YELLOW}⚠${RESET}  ${INSTALL_DIR} may not be in PATH"
  echo -e "    Run: ${BOLD}export PATH=${INSTALL_DIR}:\$PATH${RESET}"
fi

echo ""
echo -e "  ${SEP}"
echo -e "  ${BOLD}Quick start:${RESET}"
echo -e "    ${DIM}\$${RESET} ${BINARY_NAME} discover --region us-east-1"
echo -e "    ${DIM}\$${RESET} ${BINARY_NAME} instrument --task-definition my-app:1 --mw-api-key <key> --mw-target <url>"
echo ""

