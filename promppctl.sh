#!/usr/bin/env bash
set -euo pipefail

APP_NAME="prompp"
PROMPPCTL_VERSION="2026-05-29.3"

GITHUB_REPO="${GITHUB_REPO:-deckhouse/prompp}"

# Release selection:
# - PROMPP_URL wins if explicitly provided.
# - PROMPP_VERSION can pin a version/tag.
# - Otherwise install/release-update auto-detects latest release asset from GitHub API.
PROMPP_VERSION="${PROMPP_VERSION:-latest}"
PROMPP_ARCH="${PROMPP_ARCH:-auto}"
PROMPP_URL="${PROMPP_URL:-}"
# If 1, "latest" is resolved from /releases and includes RC/prerelease builds.
# If 0, "latest" uses GitHub /releases/latest, which usually excludes prereleases.
PROMPP_INCLUDE_PRERELEASES="${PROMPP_INCLUDE_PRERELEASES:-1}"

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

log() {
  echo -e "\033[32m[promppctl]\033[0m $*" >&2
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

  for cmd in curl tar install find cp date grep sed awk tr chmod chown getent id systemctl; do
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

normalize_arch() {
  if [[ "${PROMPP_ARCH}" == "auto" || -z "${PROMPP_ARCH}" ]]; then
    detect_arch
  else
    case "${PROMPP_ARCH}" in
      x86_64)
        echo "amd64"
        ;;
      aarch64|arm64)
        echo "arm64"
        ;;
      amd64)
        echo "amd64"
        ;;
      *)
        echo "${PROMPP_ARCH}"
        ;;
    esac
  fi
}

github_api_url_for_release() {
  if [[ "${PROMPP_VERSION}" == "latest" || -z "${PROMPP_VERSION}" ]]; then
    if [[ "${PROMPP_INCLUDE_PRERELEASES}" == "1" ]]; then
      echo "https://api.github.com/repos/${GITHUB_REPO}/releases"
    else
      echo "https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
    fi
  else
    echo "https://api.github.com/repos/${GITHUB_REPO}/releases/tags/${PROMPP_VERSION}"
  fi
}

resolve_release_url() {
  local arch api_url asset_url tag

  if [[ -n "${PROMPP_URL}" ]]; then
    echo "${PROMPP_URL}"
    return
  fi

  arch="$(normalize_arch)"
  api_url="$(github_api_url_for_release)"

  log "Resolving Prom++ release asset from GitHub API"
  log "Repo:    ${GITHUB_REPO}"
  log "Release: ${PROMPP_VERSION}"
  log "Arch:    ${arch}"
  log "Include prereleases: ${PROMPP_INCLUDE_PRERELEASES}"
  log "API:     ${api_url}"

  asset_url="$(
    curl -fsSL "${api_url}" \
      | grep 'browser_download_url' \
      | awk '{print $2}' \
      | tr -d '"' \
      | grep -Ei "${arch}" \
      | grep -Ei '\.tar\.gz$|\.tgz$' \
      | grep -Eiv 'sha256|checksum|checksums|sig|asc' \
      | head -n1 || true
  )"

  if [[ -z "${asset_url}" ]]; then
    die "Could not find release asset for arch=${arch}. Try PROMPP_URL=... or check: ${api_url}"
  fi

  tag="$(
    echo "${asset_url}" \
      | sed -nE 's#^.*/releases/download/([^/]+)/.*$#\1#p'
  )"

  log "Resolved release:"
  log "Tag: ${tag:-unknown}"
  log "URL: ${asset_url}"

  # IMPORTANT: stdout must contain URL only.
  echo "${asset_url}"
}

current_prompp_version() {
  if [[ -x "${BIN_PATH}" ]]; then
    "${BIN_PATH}" --version 2>/dev/null | head -n1 || true
  fi
}

unit_exists() {
  local unit="$1"
  local load_state=""

  # Reliable unit detection.
  # Do not use "systemctl list-unit-files | grep -q" here:
  # with "set -o pipefail", grep -q can close the pipe early after a match,
  # systemctl may receive SIGPIPE, and the whole pipeline can become false.
  load_state="$(systemctl show "${unit}" --property=LoadState --value 2>/dev/null || true)"

  [[ "${load_state}" == "loaded" ]]
}

unit_is_active() {
  local unit="$1"
  systemctl is-active --quiet "${unit}" 2>/dev/null
}

unit_debug_state() {
  local unit="$1"
  local load_state unit_file_state active_state

  load_state="$(systemctl show "${unit}" --property=LoadState --value 2>/dev/null || true)"
  unit_file_state="$(systemctl show "${unit}" --property=UnitFileState --value 2>/dev/null || true)"
  active_state="$(systemctl show "${unit}" --property=ActiveState --value 2>/dev/null || true)"

  echo "load=${load_state:-unknown} unit_file=${unit_file_state:-unknown} active=${active_state:-unknown}"
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

ensure_config_from_release_or_default() {
  local tmp_dir="$1"
  local found_config=""

  if [[ -f "${CONFIG_FILE}" ]]; then
    log "Config already exists: ${CONFIG_FILE}"
    return
  fi

  log "Config file not found, trying to create it: ${CONFIG_FILE}"

  found_config="$(
    find "${tmp_dir}/extract" -type f \( \
      -iname 'prometheus.yml' -o \
      -iname 'prometheus.yaml' -o \
      -iname '*prometheus*.yml' -o \
      -iname '*prometheus*.yaml' -o \
      -iname '*example*.yml' -o \
      -iname '*example*.yaml' \
    \) | head -n1 || true
  )"

  if [[ -n "${found_config}" ]]; then
    log "Using config from release archive:"
    log "  ${found_config} -> ${CONFIG_FILE}"
    install -m 0644 "${found_config}" "${CONFIG_FILE}"
  else
    warn "No example config found in archive; creating minimal clean config"

    cat > "${CONFIG_FILE}" <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: "prompp"
    static_configs:
      - targets:
          - "${LISTEN_ADDRESS}"
EOF

    chmod 0644 "${CONFIG_FILE}"
  fi

  chown root:root "${CONFIG_FILE}"
}

download_and_extract_release() {
  local url="$1"
  local tmp_dir="$2"

  log "Downloading Prom++ release"
  log "URL: ${url}"

  curl -fL --retry 3 --retry-delay 2 "${url}" -o "${tmp_dir}/prompp.tar.gz"

  log "Extracting archive"
  mkdir -p "${tmp_dir}/extract"
  tar -xzf "${tmp_dir}/prompp.tar.gz" -C "${tmp_dir}/extract"

  log "Archive binaries found:"
  find "${tmp_dir}/extract" -maxdepth 4 -type f -perm -111 -print || true
}

find_binary_in_extract() {
  local tmp_dir="$1"
  local name="$2"
  local found=""

  found="$(find "${tmp_dir}/extract" -type f -name "${name}" | head -n1 || true)"

  if [[ -z "${found}" ]]; then
    found="$(find "${tmp_dir}/extract" -type f -perm -111 -iname "*${name}*" | head -n1 || true)"
  fi

  echo "${found}"
}

install_binaries_from_tmp() {
  local tmp_dir="$1"
  local found_prompp found_tool

  found_prompp="$(find_binary_in_extract "${tmp_dir}" "prompp")"

  [[ -n "${found_prompp}" ]] || die "Could not find prompp binary in archive"

  log "Installing prompp -> ${BIN_PATH}"
  install -m 0755 "${found_prompp}" "${BIN_PATH}"

  found_tool="$(find_binary_in_extract "${tmp_dir}" "prompptool")"

  if [[ -n "${found_tool}" ]]; then
    log "Installing prompptool -> ${TOOL_PATH}"
    install -m 0755 "${found_tool}" "${TOOL_PATH}"
  else
    warn "prompptool not found in archive. WAL migration will not be available."
    rm -f "${TOOL_PATH}"
  fi

  log "Installed prompp version:"
  "${BIN_PATH}" --version || true
}

install_binary() {
  local tmp_dir url
  tmp_dir="$(mktemp -d)"

  url="$(resolve_release_url)"

  if ! download_and_extract_release "${url}" "${tmp_dir}"; then
    rm -rf "${tmp_dir}"
    die "Failed to download/extract release"
  fi

  if ! install_binaries_from_tmp "${tmp_dir}"; then
    rm -rf "${tmp_dir}"
    die "Failed to install binaries"
  fi

  ensure_config_from_release_or_default "${tmp_dir}"

  rm -rf "${tmp_dir}"
}

backup_current_binaries() {
  local backup_dir
  backup_dir="${INSTALL_DIR}/binary-backups/$(date +%F-%H%M%S)"

  install -d -m 0755 "${backup_dir}"

  if [[ -x "${BIN_PATH}" ]]; then
    cp -a "${BIN_PATH}" "${backup_dir}/prompp"
  fi

  if [[ -x "${TOOL_PATH}" ]]; then
    cp -a "${TOOL_PATH}" "${backup_dir}/prompptool"
  fi

  log "Current binaries backup:"
  log "  ${backup_dir}"
}

release_update() {
  need_root "$@"
  check_os
  need_cmds

  local tmp_dir url old_version new_version

  old_version="$(current_prompp_version || true)"
  [[ -n "${old_version}" ]] && log "Current version: ${old_version}"

  url="$(resolve_release_url)"
  tmp_dir="$(mktemp -d)"

  if ! download_and_extract_release "${url}" "${tmp_dir}"; then
    rm -rf "${tmp_dir}"
    die "Failed to download/extract release"
  fi

  # Stop only after successful download/extract.
  if systemctl is-active --quiet prompp.service; then
    log "Stopping prompp.service"
    systemctl stop prompp.service
  fi

  backup_current_binaries

  if ! install_binaries_from_tmp "${tmp_dir}"; then
    rm -rf "${tmp_dir}"
    die "Failed to install updated binaries. Backup is in ${INSTALL_DIR}/binary-backups/"
  fi

  rm -rf "${tmp_dir}"

  systemctl daemon-reload

  log "Starting prompp.service"
  systemctl start prompp.service

  sleep 1

  if ! systemctl is-active --quiet prompp.service; then
    warn "prompp.service is not active after update"
    systemctl --no-pager --full status prompp.service || true
    die "Update installed binaries, but service failed to start. Check logs: journalctl -u prompp -n 100"
  fi

  new_version="$(current_prompp_version || true)"
  [[ -n "${new_version}" ]] && log "New version: ${new_version}"

  log "Release update completed successfully"
  systemctl --no-pager --full status prompp.service || true
}

stop_old_prometheus() {
  if [[ "${REPLACE_PROMETHEUS}" != "1" ]]; then
    log "REPLACE_PROMETHEUS=0, not stopping prometheus.service"
    return
  fi

  log "Checking prometheus.service state: $(unit_debug_state "prometheus.service")"

  if unit_exists "prometheus.service"; then
    if unit_is_active "prometheus.service"; then
      log "Stopping prometheus.service"
      systemctl stop prometheus.service
    else
      log "prometheus.service exists but is not active"
    fi

    log "Disabling prometheus.service"
    systemctl disable prometheus.service >/dev/null 2>&1 || true
  else
    warn "prometheus.service not found by systemctl show; nothing to stop"
  fi
}

copy_tsdb() {
  local backup_dir
  backup_dir="${BACKUP_ROOT}/prometheus.backup.$(date +%F-%H%M%S)"

  [[ -d "${OLD_DATA_DIR}" ]] || die "Old data dir not found: ${OLD_DATA_DIR}"

  if [[ -n "$(find "${DATA_DIR}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    if [[ "${FORCE_MIGRATE}" != "1" ]]; then
      warn "Systemctl status prompp.service: Not installed."
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
  systemctl enable --now prompp.service

  log "Service status:"
  systemctl --no-pager --full status prompp.service || true
}

install_prompp() {
  need_root "$@"
  check_os
  need_cmds

  PROMPP_ARCH="$(normalize_arch)"

  create_user
  create_dirs
  install_binary
  validate_config
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
  echo "Release update:"
  echo "  sudo $0 release-update"
  echo
  echo "Rollback:"
  echo "  sudo $0 uninstall"
  echo "--------------------------------------------------"
}

uninstall_prompp() {
  need_root "$@"

  log "Stopping prompp.service"
  systemctl stop prompp.service 2>/dev/null || true
  systemctl disable prompp.service 2>/dev/null || true

  log "Removing prompp.service"
  rm -f "${SERVICE_FILE}"
  systemctl daemon-reload
  systemctl reset-failed prompp.service 2>/dev/null || true

  log "Removing binaries"
  rm -f "${BIN_PATH}" "${TOOL_PATH}"

  log "Prom++ install/config/data kept:"
  echo "  install dir: ${INSTALL_DIR}"
  echo "  config:      ${CONFIG_FILE}"
  echo "  data:        ${DATA_DIR}"
  echo

  log "Checking prometheus.service state: $(unit_debug_state "prometheus.service")"

  if unit_exists "prometheus.service"; then
    log "Restoring vanilla prometheus.service"
    systemctl enable --now prometheus.service || warn "Could not start prometheus.service. Check manually: systemctl status prometheus"
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

  log "Purging Prom++ install dir: ${INSTALL_DIR}"
  rm -rf "${INSTALL_DIR}"

  log "Purge completed"
}

status_prompp() {
  systemctl --no-pager --full status prompp.service || true
}

restart_prompp() {
  need_root "$@"
  systemctl daemon-reload
  systemctl restart prompp.service
  status_prompp
}

logs_prompp() {
  journalctl -u prompp.service -f
}

show_latest_url() {
  need_cmds
  resolve_release_url
}

usage() {
  cat <<EOF
Usage:
  # promppctl version: ${PROMPPCTL_VERSION}

  sudo $0 install
  sudo $0 release-update
  sudo $0 uninstall
  sudo $0 purge
  $0 status
  sudo $0 restart
  $0 logs
  $0 latest-url

Commands:
  install         Install Prom++, auto-detect latest release, create config if missing, optionally migrate Prometheus data copy
  release-update Download latest release, stop prompp, backup old binaries, replace binaries, start prompp
  uninstall       Remove Prom++ service/binaries and start prometheus.service back
  purge           uninstall + remove Prom++ DATA_DIR and install dir
  status          Show prompp.service status
  restart         Restart prompp.service
  logs            Follow prompp.service logs
  latest-url      Print resolved GitHub release asset URL

Release environment overrides:
  GITHUB_REPO=${GITHUB_REPO}
  PROMPP_VERSION=${PROMPP_VERSION}
  PROMPP_ARCH=${PROMPP_ARCH}
  PROMPP_URL=${PROMPP_URL:-}

Common environment overrides:
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

  sudo MIGRATE_DATA=0 REPLACE_PROMETHEUS=0 LISTEN_ADDRESS="127.0.0.1:9091" $0 install

  sudo FORCE_MIGRATE=1 $0 install

  sudo $0 release-update

  sudo PROMPP_VERSION="v0.8.0-rc3" $0 release-update

  sudo PROMPP_URL="https://github.com/deckhouse/prompp/releases/download/v0.8.0-rc3/prompp-binaries-amd64.tar.gz" $0 release-update

  sudo $0 uninstall
EOF
}

case "${1:-}" in
  install)
    install_prompp "$@"
    ;;
  release-update|update-release|upgrade)
    release_update "$@"
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
  latest-url)
    show_latest_url
    ;;
  *)
    usage
    exit 1
    ;;
esac
