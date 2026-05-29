#!/usr/bin/env bash
# Author: Yevgeniy Goncharov aka xck, http://sys-adm.in
# Prom++ installer script for Linux with safe migration of existing Prometheus data.

set -euo pipefail

# Sys env / paths / etc
# -------------------------------------------------------------------------------------------\
PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin
SCRIPT_PATH=$(cd `dirname "${BASH_SOURCE[0]}"` && pwd)

# Initial variables
# ---------------------------------------------------\

APP_NAME="prompp"

# Known working release asset format:
# https://github.com/deckhouse/prompp/releases/download/v0.8.0-rc3/prompp-binaries-amd64.tar.gz
PROMPP_VERSION="${PROMPP_VERSION:-v0.8.0-rc3}"
PROMPP_ARCH="${PROMPP_ARCH:-amd64}"
PROMPP_URL="${PROMPP_URL:-https://github.com/deckhouse/prompp/releases/download/${PROMPP_VERSION}/prompp-binaries-${PROMPP_ARCH}.tar.gz}"

# Use existing Prometheus user/group for smoother permissions.
PROMPP_USER="${PROMPP_USER:-prometheus}"
PROMPP_GROUP="${PROMPP_GROUP:-prometheus}"

INSTALL_DIR="${INSTALL_DIR:-/opt/prompp}"
BIN_PATH="${BIN_PATH:-/usr/local/bin/prompp}"
TOOL_PATH="${TOOL_PATH:-/usr/local/bin/prompptool}"

CONFIG_DIR="${CONFIG_DIR:-/etc/prometheus}"
CONFIG_FILE="${CONFIG_FILE:-${CONFIG_DIR}/prometheus.yml}"

# Safe migration model:
# - OLD_DATA_DIR remains untouched.
# - DATA_DIR receives a copy of OLD_DATA_DIR and gets WAL converted to Prom++ format.
DATA_DIR="${DATA_DIR:-/var/lib/prompp}"
OLD_DATA_DIR="${OLD_DATA_DIR:-/var/lib/prometheus}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/lib}"

SERVICE_FILE="${SERVICE_FILE:-/etc/systemd/system/prompp.service}"

# Safer default: bind locally. Override explicitly if Grafana is remote:
# sudo LISTEN_ADDRESS="0.0.0.0:9090" ./promppctl.sh install
LISTEN_ADDRESS="${LISTEN_ADDRESS:-127.0.0.1:9090}"

# Do not unexpectedly trim history too aggressively.
RETENTION_TIME="${RETENTION_TIME:-15d}"

# Whether install should migrate existing /var/lib/prometheus data into /var/lib/prompp.
# Set MIGRATE_DATA=0 for a clean empty Prom++ database.
MIGRATE_DATA="${MIGRATE_DATA:-1}"

# If DATA_DIR already has files, refuse to overwrite by default.
# Set FORCE_MIGRATE=1 to delete DATA_DIR content and re-copy from OLD_DATA_DIR.
FORCE_MIGRATE="${FORCE_MIGRATE:-0}"

# If enabled, installer stops/disables prometheus.service before starting prompp.
REPLACE_PROMETHEUS="${REPLACE_PROMETHEUS:-1}"

# Helper functions
# -------------------------------------------------------------------------------------------/

log() {
  echo -e "\033[32m[promppctl]\033[0m $*"
}

warn() {
  echo -e "\033[33m[promppctl] WARNING:\033[0m $*" >&2
}

die() {
  echo -e "\033[31m[promppctl] ERROR:\033[0m $*" >&2
  exit 1
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run as root: sudo $0 $*"
  fi
}

check_os() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    die "This installer supports Linux only"
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    die "systemd is required"
  fi
}

need_cmds() {
  local missing=0
  for cmd in curl tar install find cp date grep sed chmod chown getent id; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      echo "Missing command: ${cmd}" >&2
      missing=1
    fi
  done

  # rsync is preferred for TSDB copy, but script can fall back to cp -a.
  if ! command -v rsync >/dev/null 2>&1; then
    warn "rsync not found; falling back to cp -a for data migration"
  fi

  [[ "${missing}" -eq 0 ]] || die "Install missing dependencies and retry"
}

detect_arch() {
  local arch
  arch="$(uname -m)"

  case "${arch}" in
    x86_64|amd64)
      echo "amd64"
      ;;
    aarch64|arm64)
      echo "arm64"
      ;;
    *)
      die "Unsupported architecture: ${arch}"
      ;;
  esac
}

create_user() {
  if ! getent group "${PROMPP_GROUP}" >/dev/null 2>&1; then
    log "Creating group ${PROMPP_GROUP}"
    groupadd --system "${PROMPP_GROUP}"
  fi

  if ! id "${PROMPP_USER}" >/dev/null 2>&1; then
    log "Creating user ${PROMPP_USER}"
    useradd \
      --system \
      --no-create-home \
      --shell /usr/sbin/nologin \
      --gid "${PROMPP_GROUP}" \
      "${PROMPP_USER}"
  fi
}

create_dirs() {
  log "Creating directories"

  install -d -m 0755 "${INSTALL_DIR}"
  install -d -m 0755 "${CONFIG_DIR}"
  install -d -m 0755 "${DATA_DIR}"

  chown -R "${PROMPP_USER}:${PROMPP_GROUP}" "${DATA_DIR}"
  chown -R root:root "${INSTALL_DIR}" "${CONFIG_DIR}"
}

validate_config() {
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    die "Config file not found: ${CONFIG_FILE}. Put prometheus.yml there or override CONFIG_FILE=/path/to/prometheus.yml"
  fi
}

install_binary() {
  local tmp_dir found_prompp found_tool
  tmp_dir="$(mktemp -d)"

  log "Downloading Prom++"
  log "Version: ${PROMPP_VERSION}"
  log "Arch:    ${PROMPP_ARCH}"
  log "URL:     ${PROMPP_URL}"

  if ! curl -fL --retry 3 --retry-delay 2 "${PROMPP_URL}" -o "${tmp_dir}/prompp.tar.gz"; then
    rm -rf "${tmp_dir}"
    die "Failed to download archive. Check PROMPP_VERSION/PROMPP_ARCH/PROMPP_URL"
  fi

  log "Extracting archive"
  mkdir -p "${tmp_dir}/extract"
  tar -xzf "${tmp_dir}/prompp.tar.gz" -C "${tmp_dir}/extract"

  log "Archive binaries found:"
  find "${tmp_dir}/extract" -maxdepth 4 -type f -perm -111 -print || true

  found_prompp="$(find "${tmp_dir}/extract" -type f -name 'prompp' | head -n1 || true)"
  if [[ -z "${found_prompp}" ]]; then
    found_prompp="$(find "${tmp_dir}/extract" -type f -perm -111 -iname '*prompp*' ! -iname '*tool*' | head -n1 || true)"
  fi

  [[ -n "${found_prompp}" ]] || {
    rm -rf "${tmp_dir}"
    die "Could not find prompp binary in archive"
  }

  log "Installing prompp -> ${BIN_PATH}"
  install -m 0755 "${found_prompp}" "${BIN_PATH}"

  found_tool="$(find "${tmp_dir}/extract" -type f -name 'prompptool' | head -n1 || true)"
  if [[ -z "${found_tool}" ]]; then
    found_tool="$(find "${tmp_dir}/extract" -type f -perm -111 -iname '*prompptool*' | head -n1 || true)"
  fi

  if [[ -n "${found_tool}" ]]; then
    log "Installing prompptool -> ${TOOL_PATH}"
    install -m 0755 "${found_tool}" "${TOOL_PATH}"
  else
    warn "prompptool not found in archive. WAL migration will not be available."
    rm -f "${TOOL_PATH}"
  fi

  rm -rf "${tmp_dir}"

  log "Installed prompp version:"
  "${BIN_PATH}" --version || true

  if [[ -x "${TOOL_PATH}" ]]; then
    log "Installed prompptool:"
    "${TOOL_PATH}" --help >/dev/null 2>&1 || true
  fi
}

stop_old_prometheus() {
  if [[ "${REPLACE_PROMETHEUS}" != "1" ]]; then
    log "REPLACE_PROMETHEUS=0, not stopping prometheus.service"
    return
  fi

  if systemctl list-unit-files | grep -q '^prometheus\.service'; then
    if systemctl is-active --quiet prometheus; then
      log "Stopping prometheus.service"
      systemctl stop prometheus
    fi

    log "Disabling prometheus.service"
    systemctl disable prometheus >/dev/null 2>&1 || true
  else
    log "prometheus.service not found; nothing to stop"
  fi
}

copy_tsdb() {
  local backup_dir
  backup_dir="${BACKUP_ROOT}/prometheus.backup.$(date +%F-%H%M%S)"

  [[ -d "${OLD_DATA_DIR}" ]] || die "Old data dir not found: ${OLD_DATA_DIR}"

  if [[ -n "$(find "${DATA_DIR}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    if [[ "${FORCE_MIGRATE}" != "1" ]]; then
      die "DATA_DIR is not empty: ${DATA_DIR}. Use FORCE_MIGRATE=1 to overwrite it, or set MIGRATE_DATA=0"
    fi

    log "FORCE_MIGRATE=1, removing existing DATA_DIR content: ${DATA_DIR}"
    find "${DATA_DIR}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  fi

  log "Creating backup of old Prometheus data:"
  log "  ${OLD_DATA_DIR} -> ${backup_dir}"
  cp -a "${OLD_DATA_DIR}" "${backup_dir}"

  log "Copying Prometheus TSDB into Prom++ data dir:"
  log "  ${OLD_DATA_DIR}/ -> ${DATA_DIR}/"

  if command -v rsync >/dev/null 2>&1; then
    rsync -aHAX --delete "${OLD_DATA_DIR}/" "${DATA_DIR}/"
  else
    cp -a "${OLD_DATA_DIR}/." "${DATA_DIR}/"
  fi

  chown -R "${PROMPP_USER}:${PROMPP_GROUP}" "${DATA_DIR}"

  log "Backup completed:"
  log "  ${backup_dir}"
}

convert_wal_to_prompp() {
  if [[ ! -x "${TOOL_PATH}" ]]; then
    die "prompptool not found or not executable: ${TOOL_PATH}. Cannot safely convert WAL."
  fi

  log "Converting WAL: Prometheus -> Prom++"
  log "Command: ${TOOL_PATH} walvanilla --working-dir ${DATA_DIR}"

  "${TOOL_PATH}" walvanilla --working-dir "${DATA_DIR}"

  chown -R "${PROMPP_USER}:${PROMPP_GROUP}" "${DATA_DIR}"

  log "WAL conversion finished"
}

migrate_existing_data() {
  if [[ "${MIGRATE_DATA}" != "1" ]]; then
    log "MIGRATE_DATA=0, starting with empty/new DATA_DIR: ${DATA_DIR}"
    chown -R "${PROMPP_USER}:${PROMPP_GROUP}" "${DATA_DIR}"
    return
  fi

  if [[ ! -d "${OLD_DATA_DIR}" || -z "$(find "${OLD_DATA_DIR}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    log "Old Prometheus data dir is missing or empty; migration is not required"
    chown -R "${PROMPP_USER}:${PROMPP_GROUP}" "${DATA_DIR}"
    return
  fi

  log "--------------------------------------------------"
  log "Existing Prometheus data detected"
  log "Safe migration mode:"
  log "  old data remains untouched: ${OLD_DATA_DIR}"
  log "  copied/converter data goes to: ${DATA_DIR}"
  log "--------------------------------------------------"

  stop_old_prometheus
  copy_tsdb
  convert_wal_to_prompp

  log "Data migration completed"
}

create_service() {
  log "Creating systemd service: ${SERVICE_FILE}"

  cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Deckhouse Prom++ Monitoring
Documentation=https://github.com/deckhouse/prompp
Wants=network-online.target
After=network-online.target

[Service]
User=${PROMPP_USER}
Group=${PROMPP_GROUP}
Type=simple
ExecReload=/bin/kill -HUP \$MAINPID

ExecStart=${BIN_PATH} \\
  --config.file=${CONFIG_FILE} \\
  --storage.tsdb.path=${DATA_DIR} \\
  --web.listen-address=${LISTEN_ADDRESS} \\
  --storage.tsdb.retention.time=${RETENTION_TIME}

Restart=always
RestartSec=5
TimeoutStopSec=20s

LimitNOFILE=65536
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=${DATA_DIR}

[Install]
WantedBy=multi-user.target
EOF

  chmod 0644 "${SERVICE_FILE}"
  systemctl daemon-reload
}

start_prompp() {
  log "Enabling and starting prompp.service"
  systemctl enable --now prompp

  log "Service status:"
  systemctl --no-pager --full status prompp || true
}

install_prompp() {
  need_root "$@"
  check_os
  need_cmds

  PROMPP_ARCH="$(detect_arch)"
  PROMPP_URL="${PROMPP_URL:-https://github.com/deckhouse/prompp/releases/download/${PROMPP_VERSION}/prompp-binaries-${PROMPP_ARCH}.tar.gz}"

  create_user
  create_dirs
  validate_config
  install_binary
  migrate_existing_data
  create_service
  start_prompp

  echo
  log "Installation completed"
  echo "--------------------------------------------------"
  echo "Prom++ listen address: ${LISTEN_ADDRESS}"
  echo "Config file:           ${CONFIG_FILE}"
  echo "Prom++ data dir:       ${DATA_DIR}"
  echo "Old Prometheus dir:    ${OLD_DATA_DIR}"
  echo "Retention:             ${RETENTION_TIME}"
  echo
  echo "Check:"
  echo "  curl http://${LISTEN_ADDRESS}/-/ready"
  echo "  curl http://${LISTEN_ADDRESS}/api/v1/targets"
  echo
  echo "Rollback:"
  echo "  sudo $0 uninstall"
  echo "--------------------------------------------------"
}

uninstall_prompp() {
  need_root "$@"

  log "Stopping prompp.service"
  systemctl stop prompp 2>/dev/null || true
  systemctl disable prompp 2>/dev/null || true

  log "Removing prompp.service"
  rm -f "${SERVICE_FILE}"
  systemctl daemon-reload
  systemctl reset-failed prompp 2>/dev/null || true

  log "Removing binaries and install dir"
  rm -f "${BIN_PATH}" "${TOOL_PATH}"
  rm -rf "${INSTALL_DIR}"

  log "Prom++ config/data kept:"
  echo "  config: ${CONFIG_FILE}"
  echo "  data:   ${DATA_DIR}"
  echo

  if systemctl list-unit-files | grep -q '^prometheus\.service'; then
    log "Restoring vanilla prometheus.service"
    systemctl enable --now prometheus || warn "Could not start prometheus.service. Check manually: systemctl status prometheus"
  else
    warn "prometheus.service not found; rollback service start skipped"
  fi

  log "Uninstall completed"
}

purge_prompp() {
  need_root "$@"

  uninstall_prompp "$@"

  log "Purging Prom++ data dir: ${DATA_DIR}"
  rm -rf "${DATA_DIR}"

  log "Purge completed"
}

status_prompp() {
  systemctl --no-pager --full status prompp || true
}

restart_prompp() {
  need_root "$@"
  systemctl daemon-reload
  systemctl restart prompp
  status_prompp
}

logs_prompp() {
  journalctl -u prompp -f
}

usage() {
  cat <<EOF
Usage:
  sudo $0 install
  sudo $0 uninstall
  sudo $0 purge
  $0 status
  sudo $0 restart
  $0 logs

Commands:
  install     Install Prom++, optionally migrate Prometheus data copy, replace prometheus.service
  uninstall   Remove Prom++ service/binaries and start prometheus.service back
  purge       uninstall + remove Prom++ DATA_DIR
  status      Show prompp.service status
  restart     Restart prompp.service
  logs        Follow prompp.service logs

Environment overrides:
  PROMPP_VERSION=${PROMPP_VERSION}
  PROMPP_ARCH=${PROMPP_ARCH}
  PROMPP_URL=${PROMPP_URL}

  PROMPP_USER=${PROMPP_USER}
  PROMPP_GROUP=${PROMPP_GROUP}

  CONFIG_FILE=${CONFIG_FILE}
  OLD_DATA_DIR=${OLD_DATA_DIR}
  DATA_DIR=${DATA_DIR}
  LISTEN_ADDRESS=${LISTEN_ADDRESS}
  RETENTION_TIME=${RETENTION_TIME}

  MIGRATE_DATA=${MIGRATE_DATA}
  FORCE_MIGRATE=${FORCE_MIGRATE}
  REPLACE_PROMETHEUS=${REPLACE_PROMETHEUS}

Examples:
  sudo $0 install

  sudo LISTEN_ADDRESS="0.0.0.0:9090" $0 install

  sudo MIGRATE_DATA=0 LISTEN_ADDRESS="127.0.0.1:9091" $0 install

  sudo FORCE_MIGRATE=1 $0 install

  sudo $0 uninstall
EOF
}

# Main command dispatch
# -------------------------------------------------------------------------------------------/

case "${1:-}" in
  install)
    install_prompp "$@"
    ;;
  uninstall)
    uninstall_prompp "$@"
    ;;
  purge)
    purge_prompp "$@"
    ;;
  status)
    status_prompp
    ;;
  restart)
    restart_prompp "$@"
    ;;
  logs)
    logs_prompp
    ;;
  *)
    usage
    exit 1
    ;;
esac
