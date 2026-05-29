# promppctl.sh

`promppctl.sh` is a native Linux installer and lifecycle helper for [Deckhouse Prom++](https://github.com/deckhouse/prompp).

It installs Prom++ without Docker, creates a `systemd` service, can safely migrate an existing Prometheus TSDB copy, can perform release updates from GitHub Releases, and can roll back to the original `prometheus.service`.

## Features

- Native installation (no Docker).
- Automatic latest release detection from the official GitHub repository.
- Optional pinned release or custom release URL.
- `systemd` service generation.
- Safe Prometheus data migration:
  - old `/var/lib/prometheus` remains untouched;
  - data is copied into `/var/lib/prompp`;
  - WAL is converted with `prompptool walvanilla`.
- Clean install mode for machines without Prometheus.
- Automatic config creation:
  - uses existing `/etc/prometheus/prometheus.yml` if present;
  - otherwise tries to use an example config from the release archive;
  - otherwise creates a minimal working config.
- Release update command:
  - downloads the latest release;
  - extracts and validates binaries;
  - stops `prompp.service`;
  - backs up current binaries;
  - installs new binaries;
  - starts `prompp.service`.
- Rollback command:
  - stops Prom++;
  - removes Prom++ service/binaries;
  - starts original `prometheus.service` if it exists.
- Flexible environment overrides for paths, ports, retention, migration behavior and release selection.

## Default paths

| Item | Default |
|---|---|
| Prom++ binary | `/usr/local/bin/prompp` |
| Prom++ tool | `/usr/local/bin/prompptool` |
| Install dir | `/opt/prompp` |
| Config file | `/etc/prometheus/prometheus.yml` |
| Prom++ data dir | `/var/lib/prompp` |
| Old Prometheus data dir | `/var/lib/prometheus` |
| Systemd unit | `/etc/systemd/system/prompp.service` |
| Listen address | `127.0.0.1:9090` |
| Retention | `15d` |
| User/group | `prometheus:prometheus` |

## Requirements

The script expects a Linux host with `systemd`.

Required commands:

```bash
curl tar install find cp date grep sed awk tr chmod chown getent id
```

Optional but recommended:

```bash
rsync
```

If `rsync` is not installed, the script falls back to `cp -a` for TSDB migration.

## Installation

Download or copy the script:

```bash
chmod +x promppctl.sh
```

Install Prom++ using the latest release:

```bash
sudo ./promppctl.sh install
```

By default the installer:

1. detects the latest Prom++ release from GitHub;
2. downloads the matching `amd64` or `arm64` archive;
3. installs `prompp` and `prompptool`;
4. creates or reuses `/etc/prometheus/prometheus.yml`;
5. migrates existing Prometheus data if `/var/lib/prometheus` exists;
6. creates `prompp.service`;
7. starts Prom++ on `127.0.0.1:9090`.

Check service status:

```bash
./promppctl.sh status
```

Check readiness:

```bash
curl http://127.0.0.1:9090/-/ready
curl http://127.0.0.1:9090/api/v1/targets
```

## Clean install without Prometheus

Use this mode when there is no existing Prometheus installation or you do not want to migrate old data:

```bash
sudo MIGRATE_DATA=0 ./promppctl.sh install
```

For a safe side-by-side test on port `9091`:

```bash
sudo MIGRATE_DATA=0 LISTEN_ADDRESS="127.0.0.1:9091" ./promppctl.sh install
```

For a host where Grafana connects remotely:

```bash
sudo MIGRATE_DATA=0 LISTEN_ADDRESS="0.0.0.0:9090" ./promppctl.sh install
```

> Exposing Prom++ on `0.0.0.0` should be combined with firewall, VPN, reverse proxy, or other network access controls.

## Offline Installation

Without migration:

```bash
sudo OFFLINE_ARCHIVE="/root/prompp-binaries-amd64.tar.gz" \
  MIGRATE_DATA=0 \
  LISTEN_ADDRESS="127.0.0.1:9091" \
  ./promppctl.sh install
```

With migration:

```bash
sudo OFFLINE_ARCHIVE="/root/prompp-binaries-amd64.tar.gz" \
  ./promppctl.sh install
```

Offline update:

```bash
sudo OFFLINE_ARCHIVE="/root/prompp-binaries-amd64.tar.gz" \
  ./promppctl.sh release-update
```


## Migration from Prometheus

Default migration mode is enabled:

```bash
MIGRATE_DATA=1
```

During installation, if `/var/lib/prometheus` exists and contains data, the script performs a safe migration:

```text
/var/lib/prometheus        old Prometheus data, left untouched
/var/lib/prompp            copied data converted for Prom++
/var/lib/prometheus.backup.<date>  backup copy
```

Migration flow:

1. Stops `prometheus.service`, if running.
2. Disables `prometheus.service`, if present.
3. Creates a backup of `/var/lib/prometheus`.
4. Copies `/var/lib/prometheus/` to `/var/lib/prompp/`.
5. Runs:

```bash
prompptool walvanilla --working-dir /var/lib/prompp
```

6. Starts `prompp.service`.

### Important

Prometheus and Prom++ must not use the same `storage.tsdb.path` at the same time.

This script intentionally does **not** modify `/var/lib/prometheus`. It copies data into `/var/lib/prompp` and converts WAL only in the copied directory.

## Force migration again

If `/var/lib/prompp` already contains data, the script refuses to overwrite it.

To delete existing `/var/lib/prompp` content and re-copy from `/var/lib/prometheus`:

```bash
sudo FORCE_MIGRATE=1 ./promppctl.sh install
```

Use this carefully.

## Release detection

Show the release URL that would be downloaded:

```bash
./promppctl.sh latest-url
```

The script uses the GitHub API and selects the first matching archive for the detected architecture:

```bash
https://api.github.com/repos/deckhouse/prompp/releases/latest
```

The internal selection logic is equivalent to:

```bash
curl -fsSL "https://api.github.com/repos/deckhouse/prompp/releases/latest" \
  | grep 'browser_download_url' \
  | awk '{print $2}' \
  | tr -d '"' \
  | grep -Ei "${arch}" \
  | grep -Ei '\.tar\.gz$|\.tgz$' \
  | grep -Eiv 'sha256|checksum|checksums|sig|asc' \
  | head -n1
```

## Release update

Update Prom++ to the latest available release:

```bash
sudo ./promppctl.sh release-update
```

Aliases:

```bash
sudo ./promppctl.sh upgrade
sudo ./promppctl.sh update-release
```

Update flow:

1. Resolves the latest release asset.
2. Downloads and extracts it.
3. Stops `prompp.service`.
4. Backs up current binaries to:

```text
/opt/prompp/binary-backups/<date>/
```

5. Installs the new `prompp` and `prompptool`.
6. Reloads systemd.
7. Starts `prompp.service`.
8. Verifies that the service is active.

Pin a specific release:

```bash
sudo PROMPP_VERSION="v0.8.0-rc3" ./promppctl.sh release-update
```

Use a specific release URL:

```bash
sudo PROMPP_URL="https://github.com/deckhouse/prompp/releases/download/v0.8.0-rc3/prompp-binaries-amd64.tar.gz" ./promppctl.sh release-update
```

## Rollback to vanilla Prometheus

Remove Prom++ service and binaries, then start `prometheus.service` again:

```bash
sudo ./promppctl.sh uninstall
```

The uninstall command keeps:

```text
/etc/prometheus/prometheus.yml
/var/lib/prompp
/opt/prompp
```

It removes:

```text
/usr/local/bin/prompp
/usr/local/bin/prompptool
/etc/systemd/system/prompp.service
```

Since the script does not modify `/var/lib/prometheus`, rollback is fast and safe.

## Full purge

Remove Prom++ service, binaries, install directory and Prom++ data directory:

```bash
sudo ./promppctl.sh purge
```

This removes:

```text
/var/lib/prompp
/opt/prompp
```

It still does not delete `/var/lib/prometheus`.

## Commands

```bash
sudo ./promppctl.sh install
sudo ./promppctl.sh release-update
sudo ./promppctl.sh uninstall
sudo ./promppctl.sh purge
./promppctl.sh status
sudo ./promppctl.sh restart
./promppctl.sh logs
./promppctl.sh latest-url
```

### `install`

Install Prom++, create service, optionally migrate data.

```bash
sudo ./promppctl.sh install
```

### `release-update`

Download latest release and update binaries safely.

```bash
sudo ./promppctl.sh release-update
```

### `uninstall`

Remove Prom++ service and binaries, then start `prometheus.service` if available.

```bash
sudo ./promppctl.sh uninstall
```

### `purge`

Run uninstall and remove Prom++ data/install directories.

```bash
sudo ./promppctl.sh purge
```

### `status`

Show service status.

```bash
./promppctl.sh status
```

### `restart`

Restart Prom++.

```bash
sudo ./promppctl.sh restart
```

### `logs`

Follow logs.

```bash
./promppctl.sh logs
```

### `latest-url`

Print resolved latest release asset URL.

```bash
./promppctl.sh latest-url
```

## Environment variables

### Release variables

| Variable | Default | Description |
|---|---:|---|
| `GITHUB_REPO` | `deckhouse/prompp` | GitHub repository |
| `PROMPP_VERSION` | `latest` | Release tag or `latest` |
| `PROMPP_ARCH` | `auto` | `auto`, `amd64`, `arm64` |
| `PROMPP_URL` | empty | Direct asset URL; overrides GitHub API detection |

Examples:

```bash
sudo PROMPP_VERSION="v0.8.0-rc3" ./promppctl.sh install
```

```bash
sudo PROMPP_ARCH="amd64" ./promppctl.sh latest-url
```

```bash
sudo PROMPP_URL="https://github.com/deckhouse/prompp/releases/download/v0.8.0-rc3/prompp-binaries-amd64.tar.gz" ./promppctl.sh install
```

### Service and path variables

| Variable | Default | Description |
|---|---:|---|
| `PROMPP_USER` | `prometheus` | Linux user for service |
| `PROMPP_GROUP` | `prometheus` | Linux group for service |
| `INSTALL_DIR` | `/opt/prompp` | Install and backup directory |
| `BIN_PATH` | `/usr/local/bin/prompp` | Prom++ binary path |
| `TOOL_PATH` | `/usr/local/bin/prompptool` | Prom++ tool path |
| `CONFIG_DIR` | `/etc/prometheus` | Config directory |
| `CONFIG_FILE` | `/etc/prometheus/prometheus.yml` | Prometheus-compatible config |
| `DATA_DIR` | `/var/lib/prompp` | Prom++ data dir |
| `OLD_DATA_DIR` | `/var/lib/prometheus` | Existing Prometheus data dir |
| `BACKUP_ROOT` | `/var/lib` | Backup root for Prometheus data |
| `SERVICE_FILE` | `/etc/systemd/system/prompp.service` | Systemd unit path |
| `LISTEN_ADDRESS` | `127.0.0.1:9090` | Prom++ web listen address |
| `RETENTION_TIME` | `15d` | TSDB retention time |

Examples:

```bash
sudo LISTEN_ADDRESS="0.0.0.0:9090" ./promppctl.sh install
```

```bash
sudo DATA_DIR="/data/prompp" RETENTION_TIME="30d" ./promppctl.sh install
```

```bash
sudo CONFIG_FILE="/etc/prompp/prometheus.yml" ./promppctl.sh install
```

### Migration variables

| Variable | Default | Description |
|---|---:|---|
| `MIGRATE_DATA` | `1` | Migrate existing Prometheus data copy |
| `FORCE_MIGRATE` | `0` | Recreate `DATA_DIR` from `OLD_DATA_DIR` |
| `REPLACE_PROMETHEUS` | `1` | Stop/disable `prometheus.service` during install |

Examples:

Clean install without migration:

```bash
sudo MIGRATE_DATA=0 ./promppctl.sh install
```

Test Prom++ next to Prometheus:

```bash
sudo MIGRATE_DATA=0 REPLACE_PROMETHEUS=0 LISTEN_ADDRESS="127.0.0.1:9091" ./promppctl.sh install
```

Force re-copy and re-convert old Prometheus data:

```bash
sudo FORCE_MIGRATE=1 ./promppctl.sh install
```

Install without stopping vanilla Prometheus:

```bash
sudo REPLACE_PROMETHEUS=0 LISTEN_ADDRESS="127.0.0.1:9091" ./promppctl.sh install
```

## Generated systemd unit

The script creates:

```ini
[Unit]
Description=Deckhouse Prom++ Monitoring
Documentation=https://github.com/deckhouse/prompp
Wants=network-online.target
After=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecReload=/bin/kill -HUP $MAINPID

ExecStart=/usr/local/bin/prompp \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prompp \
  --web.listen-address=127.0.0.1:9090 \
  --storage.tsdb.retention.time=15d

Restart=always
RestartSec=5
TimeoutStopSec=20s

LimitNOFILE=65536
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=/var/lib/prompp

[Install]
WantedBy=multi-user.target
```

After editing the unit manually:

```bash
sudo systemctl daemon-reload
sudo systemctl restart prompp
```

## Typical workflows

### Replace existing Prometheus on the same port

```bash
sudo ./promppctl.sh install
curl http://127.0.0.1:9090/-/ready
```

### Run Prom++ side by side for testing

```bash
sudo MIGRATE_DATA=0 REPLACE_PROMETHEUS=0 LISTEN_ADDRESS="127.0.0.1:9091" ./promppctl.sh install
curl http://127.0.0.1:9091/-/ready
```

### Replace Prometheus and expose to remote Grafana

```bash
sudo LISTEN_ADDRESS="0.0.0.0:9090" ./promppctl.sh install
```

Make sure firewall rules allow only trusted hosts.

### Update to latest release

```bash
sudo ./promppctl.sh release-update
```

### Roll back

```bash
sudo ./promppctl.sh uninstall
sudo systemctl status prometheus
```

## Troubleshooting

### Check service logs

```bash
journalctl -u prompp -n 100 --no-pager
```

Follow logs:

```bash
./promppctl.sh logs
```

### Check listening port

```bash
ss -lntp | grep prompp
```

### Check readiness

```bash
curl http://127.0.0.1:9090/-/ready
```

### Check scrape targets

```bash
curl http://127.0.0.1:9090/api/v1/targets
```

### Config missing

If no config exists, the script will try to create one automatically.

To provide your own config:

```bash
sudo CONFIG_FILE="/etc/prompp/prometheus.yml" ./promppctl.sh install
```

### `prompptool not found`

Migration requires `prompptool`.

If the release archive does not include `prompptool`, the script will refuse to migrate WAL safely.

Use clean mode:

```bash
sudo MIGRATE_DATA=0 ./promppctl.sh install
```

Or install a release that includes `prompptool`.

### `DATA_DIR is not empty`

The script refuses to overwrite `/var/lib/prompp` by default.

Options:

```bash
sudo MIGRATE_DATA=0 ./promppctl.sh install
```

or:

```bash
sudo FORCE_MIGRATE=1 ./promppctl.sh install
```

### Prom++ failed after release update

Check status and logs:

```bash
systemctl status prompp
journalctl -u prompp -n 100 --no-pager
```

Previous binaries are backed up under:

```text
/opt/prompp/binary-backups/<date>/
```

Manual restore example:

```bash
sudo systemctl stop prompp
sudo cp /opt/prompp/binary-backups/<date>/prompp /usr/local/bin/prompp
sudo cp /opt/prompp/binary-backups/<date>/prompptool /usr/local/bin/prompptool
sudo systemctl start prompp
```

## Notes

- Prom++ is intended to be Prometheus-compatible for configs, API and PromQL workflows.
- The script keeps vanilla Prometheus data untouched to make rollback simple.
- Never run Prometheus and Prom++ against the same TSDB directory simultaneously.
- For production exposure, prefer `127.0.0.1` plus reverse proxy/VPN/firewall rules over raw public access.
