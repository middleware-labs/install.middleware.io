#!/bin/bash
set -euo pipefail

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
skip()  { echo -e "  ${DIM}–${RESET} $*"; }
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
echo -e "  ${BOLD}Middleware ECS CLI Uninstaller${RESET}"
echo -e "  ${SEP}"
echo ""

# ── Remove package (deb/rpm) ──────────────────────────
echo -e "  ${BOLD}Package${RESET}"
echo -e "  ${SEP}"

PKG_REMOVED=false

if command_exists dpkg && dpkg -s "$BINARY_NAME" > /dev/null 2>&1; then
  info "Removing .deb package ${BOLD}${BINARY_NAME}${RESET} ..."
  run_sudo dpkg --purge "$BINARY_NAME" > /dev/null 2>&1
  ok "Removed .deb package"
  PKG_REMOVED=true
elif command_exists rpm && rpm -q "$BINARY_NAME" > /dev/null 2>&1; then
  info "Removing .rpm package ${BOLD}${BINARY_NAME}${RESET} ..."
  run_sudo rpm -e "$BINARY_NAME" > /dev/null 2>&1
  ok "Removed .rpm package"
  PKG_REMOVED=true
else
  skip "No .deb or .rpm package found"
fi

echo ""

# ── Remove binary ────────────────────────────────────
echo -e "  ${BOLD}Binary${RESET}"
echo -e "  ${SEP}"

BINARY_REMOVED=false

if [ -f "${INSTALL_DIR}/${BINARY_NAME}" ]; then
  info "Removing ${BOLD}${INSTALL_DIR}/${BINARY_NAME}${RESET} ..."
  run_sudo rm -f "${INSTALL_DIR}/${BINARY_NAME}"
  ok "Removed binary"
  BINARY_REMOVED=true
else
  skip "No binary at ${INSTALL_DIR}/${BINARY_NAME}"
fi

# Also check for symlink in /usr/local/bin (created by deb postinst)
if [ -L "/usr/local/bin/${BINARY_NAME}" ]; then
  info "Removing symlink ${BOLD}/usr/local/bin/${BINARY_NAME}${RESET} ..."
  run_sudo rm -f "/usr/local/bin/${BINARY_NAME}"
  ok "Removed symlink"
elif [ -f "/usr/local/bin/${BINARY_NAME}" ]; then
  info "Removing ${BOLD}/usr/local/bin/${BINARY_NAME}${RESET} ..."
  run_sudo rm -f "/usr/local/bin/${BINARY_NAME}"
  ok "Removed binary"
else
  skip "No binary or symlink at /usr/local/bin/${BINARY_NAME}"
fi

echo ""

# ── Remove config file ───────────────────────────────
echo -e "  ${BOLD}Configuration${RESET}"
echo -e "  ${SEP}"

if [ -f "$MW_CONFIG_FILE" ]; then
  info "Removing ${BOLD}${MW_CONFIG_FILE}${RESET} ..."
  run_sudo rm -f "$MW_CONFIG_FILE"
  ok "Removed config file"
else
  skip "No config file at ${MW_CONFIG_FILE}"
fi

echo ""

# ── Clean PATH from shell rc files ───────────────────
echo -e "  ${BOLD}PATH cleanup${RESET}"
echo -e "  ${SEP}"

PATH_CLEANED=false

clean_path_from_rc() {
  local rc_file="$1"
  local rc_name="$2"
  if [ -f "$rc_file" ] && grep -q "$INSTALL_DIR" "$rc_file" 2>/dev/null; then
    sed -i "\|${INSTALL_DIR}|d" "$rc_file"
    ok "Removed PATH entry from ${BOLD}${rc_name}${RESET}"
    PATH_CLEANED=true
  fi
}

clean_path_from_rc "$HOME/.bashrc" ".bashrc"
clean_path_from_rc "$HOME/.zshrc" ".zshrc"
clean_path_from_rc "$HOME/.bash_profile" ".bash_profile"

if [ "$PATH_CLEANED" = false ]; then
  skip "No PATH entries to clean"
fi

echo ""

# ── Summary ───────────────────────────────────────────
echo -e "  ${SEP}"
if [ "$PKG_REMOVED" = true ] || [ "$BINARY_REMOVED" = true ]; then
  ok "${BOLD}${BINARY_NAME}${RESET} has been uninstalled"
else
  echo -e "  ${YELLOW}⚠${RESET}  ${BINARY_NAME} was not found on this system"
fi
echo ""

