#!/usr/bin/env bash
# Discovery-OVA builder for Ubuntu Server Minimal
# Version: 0.6.2 (2026-09-17)
# Target: Ubuntu Server 26.04 LTS amd64 on VMware vSphere/ESXi
#
# One script, staged internally.  It can install, validate, reconfigure credentials,
# and seal the guest before OVA export.

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

SELF="$(readlink -f "$0")"
VERSION="0.6.3"
DISCOVERY_OVA_ROOT="/opt/discovery-ova"
ETC_ROOT="/etc/discovery-ova"
STATE_ROOT="/var/lib/discovery-ova"
RUN_ROOT="/run/discovery-ova"
COMPOSE_DIR="$DISCOVERY_OVA_ROOT/compose"
CONFIG_DIR="$DISCOVERY_OVA_ROOT/config"
DATA_DIR="$DISCOVERY_OVA_ROOT/data"
PORTAL_DIR="$DISCOVERY_OVA_ROOT/portal"
APP_DIR="$DISCOVERY_OVA_ROOT/apps"
BACKUP_DIR="$DISCOVERY_OVA_ROOT/backups"
LOG_FILE="/var/log/discovery-ova-install.log"
CONF_FILE="$ETC_ROOT/discovery-ova.conf"
SECRETS_FILE="$ETC_ROOT/secrets.env"
BUILD_STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_STAMP_DIR="/var/backups/discovery-ova/$BUILD_STAMP"

# Pinned container versions. ntopng is resolved to an immutable digest at build time
# because its stable repository currently publishes a moving 'latest' tag.
LIBRENMS_IMAGE="librenms/librenms:26.8.2"
MARIADB_IMAGE="mariadb:11.8.9"
REDIS_IMAGE="redis:8.2.9-bookworm"
SMOKEPING_IMAGE="lscr.io/linuxserver/smokeping:2.9.0-r0-ls184"
LIBRESPEED_IMAGE="lscr.io/linuxserver/librespeed:v6.3.0-ls291"
GRAFANA_IMAGE="grafana/grafana:13.2.2"
PROMETHEUS_IMAGE="prom/prometheus:v3.14.0"
LOKI_IMAGE="grafana/loki:3.7.3"
ALLOY_IMAGE="grafana/alloy:v1.19.2"
NODE_EXPORTER_IMAGE="prom/node-exporter:v1.12.1"
CADVISOR_IMAGE="ghcr.io/google/cadvisor:v0.60.5"
GUACAMOLE_IMAGE="guacamole/guacamole:1.6.0"
GUACD_IMAGE="guacamole/guacd:1.6.0"
BLACKBOX_IMAGE="ghcr.io/prometheus/blackbox-exporter@sha256:9afaf166144b91c3d1d1f2a8ad143516365ec5d2b61579663c03641572e119d9"
TELEGRAF_IMAGE="telegraf:1.40.0"
REDFISH_IMAGE="ghcr.io/mrlhansen/idrac_exporter:v2.6.2"

export DEBIAN_FRONTEND=noninteractive

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }
warn() { printf '%s WARNING: %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE" >&2; }
die() { printf '%s ERROR: %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE" >&2; exit 1; }
stage() { printf '\n===== Discovery-OVA stage %s: %s =====\n' "$1" "$2" | tee -a "$LOG_FILE"; }

on_error() {
  local ec=$? line=${BASH_LINENO[0]:-?}
  warn "Installer failed at line $line with exit code $ec. Existing management configuration was not intentionally removed."
  warn "Review $LOG_FILE and $BACKUP_STAMP_DIR."
  exit "$ec"
}
trap on_error ERR

require_root() { [[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0 install"; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

backup_path() {
  local p="$1"
  [[ -e "$p" || -L "$p" ]] || return 0
  mkdir -p "$BACKUP_STAMP_DIR$(dirname "$p")"
  cp -a "$p" "$BACKUP_STAMP_DIR$p"
}

backup_glob() {
  local pattern="$1" f
  shopt -s nullglob
  for f in $pattern; do backup_path "$f"; done
  shopt -u nullglob
}

write_file() {
  local path="$1" mode="$2" owner="$3"
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  if [[ -e "$path" ]] && cmp -s "$tmp" "$path"; then
    rm -f "$tmp"
  else
    backup_path "$path"
    install -D -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$tmp" "$path"
    rm -f "$tmp"
  fi
}

random_secret() { openssl rand -base64 36 | tr -d '\n' | tr '/+' '_-'; }

prompt_secret() {
  local prompt="$1" varname="$2" minlen="${3:-12}" a b
  while true; do
    read -r -s -p "$prompt: " a; echo
    [[ ${#a} -ge $minlen ]] || { echo "Must be at least $minlen characters. Please try again."; continue; }
    read -r -s -p "Confirm: " b; echo
    [[ "$a" == "$b" ]] || { echo "Values did not match. Please try again."; continue; }
    printf -v "$varname" '%s' "$a"
    unset a b
    return 0
  done
}

prompt_hidden_nonempty() {
  local prompt="$1" varname="$2" value
  while true; do
    read -r -s -p "$prompt: " value; echo
    if [[ -n "$value" ]]; then
      printf -v "$varname" '%s' "$value"
      unset value
      return 0
    fi
    echo "A value is required. Please try again."
  done
}

prompt_yes_no() {
  local prompt="$1" default="${2:-N}" varname="$3" value suffix
  if [[ "$default" =~ ^[Yy]$ ]]; then suffix='[Y/n]'; else suffix='[y/N]'; fi
  while true; do
    read -r -p "$prompt $suffix: " value
    value="${value:-$default}"
    case "$value" in
      [Yy]|[Yy][Ee][Ss]) printf -v "$varname" '%s' 'y'; return 0 ;;
      [Nn]|[Nn][Oo]) printf -v "$varname" '%s' 'n'; return 0 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

prompt_value() {
  local prompt="$1" default="$2" varname="$3" validator="$4" errmsg="$5" value
  while true; do
    if [[ -n "$default" ]]; then
      read -r -p "$prompt [$default]: " value
      value="${value:-$default}"
    else
      read -r -p "$prompt: " value
    fi
    if "$validator" "$value"; then
      printf -v "$varname" '%s' "$value"
      return 0
    fi
    echo "$errmsg Please try again."
  done
}

valid_nonempty() { [[ -n "$1" ]]; }
valid_hostname() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,62}$ ]]; }
valid_interface() { [[ -n "$1" && -e "/sys/class/net/$1" ]]; }
valid_timezone() { timedatectl list-timezones | grep -Fxq "$1"; }
valid_no_space() { [[ -n "$1" && "$1" != *[[:space:]]* ]]; }
valid_simple_host() { [[ "$1" =~ ^[A-Za-z0-9._:-]+$ ]]; }
valid_email() { [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; }
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
valid_abs_path() { [[ "$1" == /* && "$1" != *$'\n'* ]]; }
valid_array_name() { [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]; }
valid_bmc_target() { [[ "$1" =~ ^[A-Za-z0-9._:-]+$ ]]; }
valid_pure_address() {
  local value="$1" port
  [[ "$value" =~ ^[A-Za-z0-9._-]+(:[0-9]{1,5})?$ ]] || return 1
  if [[ "$value" == *:* ]]; then
    port="${value##*:}"
    valid_port "$port" || return 1
  fi
  return 0
}

is_ipv4() { python3 - "$1" <<'PY' >/dev/null 2>&1
import ipaddress,sys
ipaddress.IPv4Address(sys.argv[1])
PY
}

get_mgmt_if() {
  ip -4 route show default 2>/dev/null | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}'
}

get_mgmt_ip() {
  local dev="${1:-$(get_mgmt_if)}"
  ip -4 -o addr show dev "$dev" scope global 2>/dev/null | awk 'NR==1 {split($4,a,"/");print a[1]}'
}

get_gateway() {
  local dev="${1:-$(get_mgmt_if)}"
  ip -4 route show default dev "$dev" 2>/dev/null | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="via") {print $(i+1); exit}}'
}

install_network_validation_library() {
  install -d -m 0755 /usr/local/libexec
  write_file /usr/local/libexec/discovery-ova-network-common 0755 root:root <<'EOF'
#!/usr/bin/env bash
# Shared Discovery-OVA network-path validation. Keep this file free of interactive behavior
# so the installer, boot guard, network controller and race-ready validator use the same rules.
discovery_global_ipv4() {
  local dev="$1"
  ip -4 -o addr show dev "$dev" scope global 2>/dev/null | awk 'NR==1{split($4,a,"/");print a[1]}'
}
discovery_default_gateway() {
  local dev="$1"
  ip -4 route show default dev "$dev" 2>/dev/null | awk 'NR==1{for(i=1;i<=NF;i++)if($i=="via"){print $(i+1);exit}}'
}
discovery_gateway_reachable() {
  local dev="$1" gw line
  gw="$(discovery_default_gateway "$dev")"
  [[ -n "$gw" ]] || return 1
  if ping -I "$dev" -c1 -W2 "$gw" >/dev/null 2>&1; then
    return 0
  fi
  line="$(ip neigh show to "$gw" dev "$dev" 2>/dev/null | head -n1 || true)"
  [[ -n "$line" ]] || return 1
  ! grep -Eq '(^|[[:space:]])(FAILED|INCOMPLETE)([[:space:]]|$)' <<<"$line"
}
discovery_external_route_ok() {
  local dev="$1" src route
  src="$(discovery_global_ipv4 "$dev")"
  [[ -n "$src" ]] || return 1
  route="$(ip -4 route get 1.1.1.1 from "$src" oif "$dev" 2>/dev/null || true)"
  [[ -n "$route" ]] && grep -Eq "(^|[[:space:]])dev[[:space:]]+$dev([[:space:]]|$)" <<<"$route"
}
discovery_outbound_ok() {
  local dev="$1"
  # Runtime path validation must not depend on DNS. First try ICMP to a literal
  # public IP, then fall back to TCP/443 to a literal IP for networks that block ping.
  ping -I "$dev" -c1 -W2 1.1.1.1 >/dev/null 2>&1 && return 0
  if command -v timeout >/dev/null 2>&1; then
    timeout 4 bash -c 'exec 3<>/dev/tcp/1.1.1.1/443' >/dev/null 2>&1 && return 0
  fi
  return 1
}
discovery_management_path_ok() {
  local dev="$1" ip gw
  [[ -e "/sys/class/net/$dev" ]] || return 1
  ip="$(discovery_global_ipv4 "$dev")"
  gw="$(discovery_default_gateway "$dev")"
  [[ -n "$ip" && -n "$gw" ]] || return 1
  discovery_external_route_ok "$dev" || return 1
  # Generate real traffic before checking the neighbor table. This lets gateways that
  # intentionally ignore ICMP still validate through a REACHABLE/STALE ARP entry.
  discovery_outbound_ok "$dev" || return 1
  discovery_gateway_reachable "$dev"
}
discovery_local_management_ok() {
  local dev="$1" ip gw
  [[ -e "/sys/class/net/$dev" ]] || return 1
  ip="$(discovery_global_ipv4 "$dev")"
  gw="$(discovery_default_gateway "$dev")"
  [[ -n "$ip" && -n "$gw" ]] || return 1
  discovery_external_route_ok "$dev" || return 1
  discovery_gateway_reachable "$dev"
}
discovery_capture_path_ok() {
  local dev="$1"
  [[ -e "/sys/class/net/$dev" ]] || return 1
  ! ip -4 -o addr show dev "$dev" scope global 2>/dev/null | grep -q . || return 1
  ! ip -4 route show default dev "$dev" 2>/dev/null | grep -q '^default ' || return 1
  ip -details link show "$dev" 2>/dev/null | grep -qw PROMISC
}
discovery_network_diagnostics() {
  local dev="$1" ip gw route neigh outbound=no gateway=no
  ip="$(discovery_global_ipv4 "$dev")"
  gw="$(discovery_default_gateway "$dev")"
  route=""
  [[ -n "$ip" ]] && route="$(ip -4 route get 1.1.1.1 from "$ip" oif "$dev" 2>&1 || true)"
  neigh=""
  [[ -n "$gw" ]] && neigh="$(ip neigh show to "$gw" dev "$dev" 2>/dev/null | head -n1 || true)"
  discovery_outbound_ok "$dev" && outbound=yes || true
  discovery_gateway_reachable "$dev" && gateway=yes || true
  cat <<DIAG
interface=$dev
ipv4=${ip:-none}
default_gateway=${gw:-none}
gateway_reachable=$gateway
external_route=${route:-none}
outbound_connectivity=$outbound
neighbor=${neigh:-none}
DIAG
}
EOF
}

list_candidate_nics() {
  local mgmt="$1"
  for p in /sys/class/net/*; do
    local n="${p##*/}"
    [[ "$n" == "lo" || "$n" == "$mgmt" ]] && continue
    [[ -e "$p/device" ]] || continue
    printf '%s\n' "$n"
  done
}

load_conf() {
  [[ -r "$CONF_FILE" ]] || die "Missing $CONF_FILE; run install first."
  # shellcheck disable=SC1090
  source "$CONF_FILE"
}

usage() {
  cat <<EOF
Discovery-OVA OVA builder $VERSION

Usage:
  sudo bash $0 install       Build or repair the appliance
  sudo bash $0 validate      Run race-ready validation
  sudo bash $0 rekey         Change operator credentials and refresh app admins
  sudo bash $0 smtp          Configure or disable boot-address email
  sudo bash $0 backup-remote Configure Farva/SSH remote backup settings
  sudo bash $0 remote        Configure vSphere, Redfish and Pure remote monitoring
  sudo bash $0 seal          Clean unique guest identity before OVA export
  sudo bash $0 discover      Read-only discovery report

Important: perform the first install from the VMware console, not only over SSH,
because Ubuntu Server networking is converted to NetworkManager.
EOF
}

preflight_os() {
  [[ -r /etc/os-release ]] || die "Cannot identify OS."
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "This build targets Ubuntu Server. Found: ${ID:-unknown}."
  case "${VERSION_ID:-}" in
    26.04|24.04) ;;
    *) die "Supported base releases are Ubuntu 26.04 LTS and 24.04 LTS; found ${VERSION_ID:-unknown}." ;;
  esac
  [[ "$(dpkg --print-architecture)" == "amd64" ]] || die "This OVA build currently targets amd64."
  local cpus mem_gb root_gb
  cpus="$(nproc)"
  mem_gb="$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 / 1024 ))"
  root_gb="$(df -BG --output=size / | tail -1 | tr -dc '0-9')"
  (( cpus >= 8 )) || warn "Only $cpus vCPU detected. Discovery-OVA v0.6 recommends 12 vCPU (8 minimum for a small lab)."
  (( mem_gb >= 16 )) || warn "Only ${mem_gb} GiB RAM detected. Discovery-OVA v0.6 recommends 24 GiB."
  (( root_gb >= 180 )) || warn "Root filesystem is only ${root_gb} GiB. The all-in-one build recommends a 300 GB thin VMDK/root filesystem."
}

discover() {
  echo "=== OS ==="
  cat /etc/os-release 2>/dev/null || true
  uname -a
  echo "=== Storage ==="
  lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS,MODEL
  df -hT
  echo "=== Interfaces ==="
  ip -br link
  ip -br -4 addr
  echo "=== NetworkManager ==="
  nmcli general status 2>/dev/null || true
  nmcli -f NAME,UUID,TYPE,DEVICE con show 2>/dev/null || true
  echo "=== Routes ==="
  ip -4 route
  echo "=== Docker ==="
  docker version 2>/dev/null || true
  docker compose version 2>/dev/null || true
  echo "=== Nginx ==="
  nginx -v 2>&1 || true
  echo "=== systemd failed ==="
  systemctl --failed --no-pager || true
  echo "=== Firewall ==="
  ufw status verbose 2>/dev/null || true
  echo "=== LLDP ==="
  systemctl is-active lldpd.service 2>/dev/null || true
  lldpctl 2>/dev/null || true
  echo "=== iperf3 ==="
  iperf3 --version 2>/dev/null | head -n1 || true
  systemctl status discovery-ova-iperf3-server.service --no-pager 2>/dev/null || true
  echo "=== Listening ports ==="
  ss -lntup || true
}

collect_settings() {
  local detected_mgmt detected_capture host_default tz_default existing=0
  if [[ -r "$CONF_FILE" ]]; then
    # Reuse the appliance identity/interface choices on repair runs.
    # shellcheck disable=SC1090
    source "$CONF_FILE"
    existing=1
  fi

  detected_mgmt="${MGMT_IF:-$(get_mgmt_if)}"
  [[ -n "$detected_mgmt" ]] || die "No IPv4 default route found. Attach the management NIC and obtain an address first."
  detected_capture="${CAPTURE_IF:-$(list_candidate_nics "$detected_mgmt" | head -n1 || true)}"
  [[ -n "$detected_capture" ]] || die "A second vNIC is required for passive capture. Add a second VMXNET3 NIC, then rerun."

  host_default="${HOSTNAME_SHORT:-$(hostname -s 2>/dev/null || echo discovery-ova)}"
  [[ "$host_default" == "localhost" || -z "$host_default" ]] && host_default="discovery-ova"
  tz_default="${TIMEZONE:-America/Los_Angeles}"

  echo "Detected management interface: $detected_mgmt ($(get_mgmt_ip "$detected_mgmt"))"
  echo "Detected capture candidate:    $detected_capture"
  echo
  prompt_value "Appliance hostname" "$host_default" HOSTNAME_SHORT valid_hostname "Hostname must start with a letter/digit and contain only letters, digits or hyphens (max 63 characters)."
  prompt_value "Management interface" "$detected_mgmt" MGMT_IF valid_interface "That network interface does not exist."
  while true; do
    prompt_value "Capture interface" "$detected_capture" CAPTURE_IF valid_interface "That network interface does not exist."
    [[ "$MGMT_IF" != "$CAPTURE_IF" ]] && break
    echo "Management and capture interfaces must be different. Please choose another capture interface."
  done
  prompt_value "Timezone" "$tz_default" TIMEZONE valid_timezone "Unknown timezone. Use an IANA timezone such as America/Los_Angeles or UTC."

  OPERATOR_USER="chili"
  if [[ -r "$SECRETS_FILE" ]]; then
    # Preserve database/application secrets on idempotent repair runs.
    # shellcheck disable=SC1090
    source "$SECRETS_FILE"
  fi
  if [[ -z "${OPERATOR_PASSWORD:-}" ]]; then
    prompt_secret "Password for Nginx/Grafana/LibreNMS/Guacamole operator '$OPERATOR_USER'" OPERATOR_PASSWORD 12
  elif (( existing )); then
    echo "Reusing the existing root-only operator credential for this repair run. Use '$SELF rekey' to rotate it."
  fi

  DB_PASSWORD="${DB_PASSWORD:-$(random_secret)}"
  REDIS_PASSWORD="${REDIS_PASSWORD:-$(random_secret)}"
  GRAFANA_SECRET_KEY="${GRAFANA_SECRET_KEY:-$(random_secret)}"
  LIBRESPEED_RESULTS_PASSWORD="${LIBRESPEED_RESULTS_PASSWORD:-$(random_secret)}"
  SNMP_COMMUNITY="${SNMP_COMMUNITY:-$(openssl rand -hex 16)}"
  GUAC_DB_PASSWORD="${GUAC_DB_PASSWORD:-$(random_secret)}"
  GUAC_DB_ROOT_PASSWORD="${GUAC_DB_ROOT_PASSWORD:-$(random_secret)}"

  install -d -m 0700 "$ETC_ROOT" "$STATE_ROOT" "$RUN_ROOT"
  write_file "$CONF_FILE" 0600 root:root <<EOF
HOSTNAME_SHORT='$HOSTNAME_SHORT'
MGMT_IF='$MGMT_IF'
CAPTURE_IF='$CAPTURE_IF'
TIMEZONE='$TIMEZONE'
OPERATOR_USER='$OPERATOR_USER'
DISCOVERY_OVA_ROOT='$DISCOVERY_OVA_ROOT'
COMPOSE_DIR='$COMPOSE_DIR'
DATA_DIR='$DATA_DIR'
BACKUP_DIR='$BACKUP_DIR'
EOF

  {
    printf 'OPERATOR_PASSWORD=%q\n' "$OPERATOR_PASSWORD"
    printf 'DB_PASSWORD=%q\n' "$DB_PASSWORD"
    printf 'REDIS_PASSWORD=%q\n' "$REDIS_PASSWORD"
    printf 'GRAFANA_SECRET_KEY=%q\n' "$GRAFANA_SECRET_KEY"
    printf 'LIBRESPEED_RESULTS_PASSWORD=%q\n' "$LIBRESPEED_RESULTS_PASSWORD"
    printf 'SNMP_COMMUNITY=%q\n' "$SNMP_COMMUNITY"
    printf 'GUAC_DB_PASSWORD=%q\n' "$GUAC_DB_PASSWORD"
    printf 'GUAC_DB_ROOT_PASSWORD=%q\n' "$GUAC_DB_ROOT_PASSWORD"
  } | write_file "$SECRETS_FILE" 0600 root:root

  export OPERATOR_PASSWORD
}

ensure_dirs_user() {
  getent group discovery-ova >/dev/null || groupadd --system discovery-ova
  id discovery-ova >/dev/null 2>&1 || useradd --system --gid discovery-ova --home-dir "$DISCOVERY_OVA_ROOT" --shell /usr/sbin/nologin discovery-ova
  DISCOVERY_OVA_UID="$(id -u discovery-ova)"
  DISCOVERY_OVA_GID="$(id -g discovery-ova)"
  export DISCOVERY_OVA_UID DISCOVERY_OVA_GID

  # The appliance root and static portal must be traversable by nginx (www-data).
  # Sensitive/config/data subdirectories remain 0750 or stricter.
  install -d -m 0755 -o root -g root "$DISCOVERY_OVA_ROOT"
  install -d -m 0750 -o root -g discovery-ova "$COMPOSE_DIR" "$CONFIG_DIR" "$APP_DIR"
  install -d -m 0755 -o root -g root "$PORTAL_DIR"
  install -d -m 0750 -o root -g discovery-ova "$DATA_DIR" "$BACKUP_DIR"
  local d
  for d in librenms smokeping/config smokeping/data librespeed scanner captures ntopng alloy node-exporter cadvisor; do
    install -d -m 0750 -o discovery-ova -g discovery-ova "$DATA_DIR/$d"
  done
  install -d -m 0750 -o root -g root "$DATA_DIR/db" "$DATA_DIR/redis" "$DATA_DIR/guacamole-db"
  install -d -m 0750 -o root -g discovery-ova "$CONFIG_DIR/guacamole" "$CONFIG_DIR/blackbox" "$CONFIG_DIR/telegraf" "$CONFIG_DIR/redfish"
  # Create bind-mount directories as root, then assign the numeric UIDs/GIDs used inside containers.
  # GNU install(1) on some Ubuntu builds resolves -o/-g as account names and rejects container-only numeric IDs.
  install -d -m 0750 "$DATA_DIR/grafana" "$DATA_DIR/prometheus" "$DATA_DIR/loki"
  chown 472:472 "$DATA_DIR/grafana"
  chown 65534:65534 "$DATA_DIR/prometheus"
  chown 10001:10001 "$DATA_DIR/loki"
  install -d -m 0755 -o root -g root "$STATE_ROOT/textfile_collector"
}
install_packages() {
  stage 1 "Baseline, packages, VMware tools, NetworkManager and Docker"
  preflight_os
  mkdir -p "$(dirname "$LOG_FILE")" "$BACKUP_STAMP_DIR"
  log "Saving discovery snapshot."
  discover > "$BACKUP_STAMP_DIR/discovery-before.txt" 2>&1 || true

  apt-get update
  apt-get install -y \
    ca-certificates curl gnupg jq openssl apache2-utils \
    network-manager netplan.io nginx rsyslog avahi-daemon \
    nmap tcpdump ethtool iproute2 iputils-ping dnsutils iperf3 lldpd \
    python3 python3-flask gunicorn sqlite3 \
    open-vm-tools ufw openssh-server tar gzip xz-utils rsync \
    util-linux systemd-timesyncd

  systemctl enable --now open-vm-tools.service 2>/dev/null || true
  systemctl enable --now ssh.service 2>/dev/null || true

  if ! command_exists docker; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    # shellcheck disable=SC1091
    source /etc/os-release
    cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  systemctl enable --now docker
  docker version >/dev/null
  docker compose version
}

configure_hostname_time() {
  hostnamectl set-hostname "$HOSTNAME_SHORT"
  timedatectl set-timezone "$TIMEZONE"
  systemctl enable --now systemd-timesyncd.service 2>/dev/null || true
  systemctl enable --now avahi-daemon.service
}

configure_networkmanager() {
  stage 2 "Safe management/capture networking"
  log "Backing up existing netplan and NetworkManager configuration."
  backup_glob '/etc/netplan/*.yaml'
  backup_glob '/etc/netplan/*.yml'
  backup_path /etc/NetworkManager/NetworkManager.conf

  install_network_validation_library
  # shellcheck disable=SC1091
  source /usr/local/libexec/discovery-ova-network-common

  local capture_ip capture_gw retry_ans
  capture_ip="$(get_mgmt_ip "$CAPTURE_IF")"
  capture_gw="$(get_gateway "$CAPTURE_IF")"
  if [[ -n "$capture_ip" || -n "$capture_gw" ]]; then
    warn "Capture interface $CAPTURE_IF currently participates in management networking."
    warn "  IPv4: ${capture_ip:-none}"
    warn "  Default gateway: ${capture_gw:-none}"
    warn "This is acceptable during installation. Discovery-OVA will remove Layer-3 configuration from $CAPTURE_IF and convert it to an addressless promiscuous capture interface."
  fi

  while ! discovery_management_path_ok "$MGMT_IF"; do
    warn "Management-path validation failed for $MGMT_IF."
    discovery_network_diagnostics "$MGMT_IF" | tee -a "$LOG_FILE"
    prompt_yes_no "Retry management validation after correcting the network issue?" Y retry_ans
    [[ "$retry_ans" == y ]] || die "A validated management path is required before networking can be changed. No management configuration was intentionally removed."
  done
  log "Management path validated on $MGMT_IF before NetworkManager conversion."

  # OVA templates should use DHCP on the management NIC. This avoids baking a site-specific address into the appliance.
  # Disable pre-existing Netplan YAML after backing it up so cloud-init/networkd definitions cannot merge with Discovery-OVA's profile.
  local f
  shopt -s nullglob
  for f in /etc/netplan/*.yaml /etc/netplan/*.yml; do
    [[ "$f" == /etc/netplan/90-discovery-ova.yaml ]] && continue
    mv -f "$f" "$f.discovery-ova-disabled"
  done
  shopt -u nullglob

  write_file /etc/netplan/90-discovery-ova.yaml 0600 root:root <<EOF
network:
  version: 2
  renderer: NetworkManager
  ethernets:
    $MGMT_IF:
      dhcp4: true
      dhcp6: false
    $CAPTURE_IF:
      dhcp4: false
      dhcp6: false
      optional: true
EOF
  systemctl enable NetworkManager.service
  if ! netplan generate || ! netplan apply; then
    warn "NetworkManager conversion failed; restoring the pre-build Netplan files."
    rm -f /etc/netplan/90-discovery-ova.yaml
    rm -f /etc/netplan/*.discovery-ova-disabled 2>/dev/null || true
    if [[ -d "$BACKUP_STAMP_DIR/etc/netplan" ]]; then cp -a "$BACKUP_STAMP_DIR/etc/netplan/." /etc/netplan/; fi
    netplan generate || true; netplan apply || true
    die "Network conversion failed and rollback was attempted. Continue from the VMware console."
  fi
  sleep 4

  local attempt post_ok=0
  for attempt in 1 2 3 4 5; do
    if discovery_management_path_ok "$MGMT_IF"; then
      post_ok=1
      break
    fi
    warn "Management path has not validated after NetworkManager conversion (attempt $attempt/5)."
    discovery_network_diagnostics "$MGMT_IF" | tee -a "$LOG_FILE"
    sleep 3
  done
  if (( post_ok == 0 )); then
    warn "Management validation failed after NetworkManager conversion; restoring the pre-build Netplan files."
    rm -f /etc/netplan/90-discovery-ova.yaml
    rm -f /etc/netplan/*.discovery-ova-disabled 2>/dev/null || true
    if [[ -d "$BACKUP_STAMP_DIR/etc/netplan" ]]; then cp -a "$BACKUP_STAMP_DIR/etc/netplan/." /etc/netplan/; fi
    netplan generate || true; netplan apply || true
    die "Management path did not validate after conversion; rollback was attempted. Use the VMware console before retrying."
  fi
  log "Management path validated on $MGMT_IF after NetworkManager conversion."

  nmcli con delete discovery-ova-capture >/dev/null 2>&1 || true
  nmcli con delete discovery-ova-wired >/dev/null 2>&1 || true
  nmcli con add type ethernet ifname "$CAPTURE_IF" con-name discovery-ova-capture ipv4.method disabled ipv6.method disabled connection.autoconnect yes
  nmcli con modify discovery-ova-capture connection.autoconnect-priority 50
  nmcli con add type ethernet ifname "$CAPTURE_IF" con-name discovery-ova-wired ipv4.method auto ipv6.method disabled connection.autoconnect no ipv4.route-metric 200
  nmcli con up discovery-ova-capture
  ip addr flush dev "$CAPTURE_IF" scope global || true
  while ip -4 route show default dev "$CAPTURE_IF" 2>/dev/null | grep -q '^default '; do
    ip -4 route del default dev "$CAPTURE_IF" 2>/dev/null || break
  done
  ip link set dev "$CAPTURE_IF" up promisc on

  local capture_ok=0
  for attempt in 1 2 3; do
    if discovery_capture_path_ok "$CAPTURE_IF"; then
      capture_ok=1
      break
    fi
    warn "Capture-interface safety state has not validated (attempt $attempt/3). Re-applying the addressless capture profile."
    nmcli con down discovery-ova-wired >/dev/null 2>&1 || true
    nmcli con up discovery-ova-capture >/dev/null 2>&1 || true
    ip addr flush dev "$CAPTURE_IF" scope global || true
    while ip -4 route show default dev "$CAPTURE_IF" 2>/dev/null | grep -q '^default '; do
      ip -4 route del default dev "$CAPTURE_IF" 2>/dev/null || break
    done
    ip link set dev "$CAPTURE_IF" up promisc on
    sleep 2
  done
  if (( capture_ok == 0 )); then
    warn "Capture interface $CAPTURE_IF could not be placed into the required addressless/promiscuous state."
    ip -4 addr show dev "$CAPTURE_IF" | tee -a "$LOG_FILE" || true
    ip -4 route show dev "$CAPTURE_IF" | tee -a "$LOG_FILE" || true
    ip -details link show "$CAPTURE_IF" | tee -a "$LOG_FILE" || true
    die "Capture interface safety validation failed. Management on $MGMT_IF remains intact; correct the capture NIC configuration and retry."
  fi
  log "Capture interface $CAPTURE_IF is addressless, has no default route, and is promiscuous."

  write_file /usr/local/sbin/discovery-ova-network 0750 root:discovery-ova <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/discovery-ova/discovery-ova.conf
source /usr/local/libexec/discovery-ova-network-common
log(){ logger -t discovery-ova-network -- "$*"; echo "$*"; }
mgmt_ok(){ discovery_management_path_ok "$MGMT_IF"; }
wired_ok(){ discovery_management_path_ok "$CAPTURE_IF"; }
case "${1:-status}" in
  capture)
    mgmt_ok || { log "Refusing capture mode: management path on $MGMT_IF is not healthy"; exit 1; }
    nmcli con down discovery-ova-wired >/dev/null 2>&1 || true
    nmcli con up discovery-ova-capture >/dev/null
    ip addr flush dev "$CAPTURE_IF" scope global || true
    while ip -4 route show default dev "$CAPTURE_IF" 2>/dev/null | grep -q '^default '; do
      ip -4 route del default dev "$CAPTURE_IF" 2>/dev/null || break
    done
    ip link set dev "$CAPTURE_IF" up promisc on
    if ! discovery_capture_path_ok "$CAPTURE_IF"; then
      log "capture mode failed safety validation on $CAPTURE_IF"
      exit 1
    fi
    systemctl restart discovery-ova-network-rollback.timer
    log "capture mode active on $CAPTURE_IF; two-minute rollback armed"
    ;;
  confirm)
    systemctl stop discovery-ova-network-rollback.timer >/dev/null 2>&1 || true
    log "capture mode confirmed; rollback cancelled"
    ;;
  wired)
    systemctl stop discovery-ova-network-rollback.timer >/dev/null 2>&1 || true
    ip link set dev "$CAPTURE_IF" promisc off || true
    nmcli con down discovery-ova-capture >/dev/null 2>&1 || true
    nmcli con up discovery-ova-wired >/dev/null
    sleep 3
    if wired_ok; then
      log "wired DHCP mode is usable on $CAPTURE_IF"
    else
      log "wired DHCP mode failed validation; restoring capture mode"
      nmcli con down discovery-ova-wired >/dev/null 2>&1 || true
      nmcli con up discovery-ova-capture >/dev/null
      ip addr flush dev "$CAPTURE_IF" scope global || true
      while ip -4 route show default dev "$CAPTURE_IF" 2>/dev/null | grep -q '^default '; do
        ip -4 route del default dev "$CAPTURE_IF" 2>/dev/null || break
      done
      ip link set dev "$CAPTURE_IF" up promisc on
      exit 1
    fi
    ;;
  rollback)
    if wired_ok; then
      log "rollback check: wired management on $CAPTURE_IF is usable; leaving wired mode active"
      exit 0
    fi
    if mgmt_ok; then
      nmcli con down discovery-ova-wired >/dev/null 2>&1 || true
      nmcli con up discovery-ova-capture >/dev/null
      ip addr flush dev "$CAPTURE_IF" scope global || true
      while ip -4 route show default dev "$CAPTURE_IF" 2>/dev/null | grep -q '^default '; do
        ip -4 route del default dev "$CAPTURE_IF" 2>/dev/null || break
      done
      ip link set dev "$CAPTURE_IF" up promisc on
      if ! discovery_capture_path_ok "$CAPTURE_IF"; then
        log "rollback restored $MGMT_IF but capture safety validation failed on $CAPTURE_IF"
        exit 1
      fi
      log "rollback restored management on $MGMT_IF plus passive capture on $CAPTURE_IF"
      exit 0
    fi
    log "rollback could not prove either management path; leaving current state unchanged"
    exit 1
    ;;
  status)
    echo "mgmt_if=$MGMT_IF"
    echo "capture_if=$CAPTURE_IF"
    echo "mgmt_ipv4=$(ip -4 -o addr show dev "$MGMT_IF" scope global | awk 'NR==1{print $4}')"
    echo "capture_ipv4=$(ip -4 -o addr show dev "$CAPTURE_IF" scope global | awk 'NR==1{print $4}')"
    echo "capture_profile=$(nmcli -t -f GENERAL.CONNECTION dev show "$CAPTURE_IF" 2>/dev/null | cut -d: -f2-)"
    echo "promisc=$(ip -details link show "$CAPTURE_IF" | grep -qw PROMISC && echo 1 || echo 0)"
    echo "rollback_pending=$(systemctl is-active --quiet discovery-ova-network-rollback.timer && echo 1 || echo 0)"
    ip -4 route
    ;;
  *) echo "usage: $0 {capture|confirm|wired|rollback|status}" >&2; exit 2;;
esac
EOF

  write_file /usr/local/sbin/discovery-ova-network-boot-guard 0750 root:root <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/discovery-ova/discovery-ova.conf
source /usr/local/libexec/discovery-ova-network-common
log(){ logger -t discovery-ova-network -- "$*"; }
if discovery_management_path_ok "$MGMT_IF"; then
  /usr/local/sbin/discovery-ova-network capture
  sleep 2
  if ! discovery_capture_path_ok "$CAPTURE_IF"; then
    log "boot guard: capture interface is not fully addressless/no-default/promiscuous"
    exit 1
  fi
  /usr/local/sbin/discovery-ova-network confirm
  log "boot guard: management is healthy on $MGMT_IF; $CAPTURE_IF is addressless capture"
  exit 0
fi
log "boot guard: primary management path is unhealthy; testing capture NIC as wired DHCP"
if /usr/local/sbin/discovery-ova-network wired; then
  log "boot guard: wired fallback is usable on $CAPTURE_IF"
  exit 0
fi
log "boot guard: no validated management path; manual console intervention required"
exit 1
EOF

  write_file /etc/systemd/system/discovery-ova-network-rollback.service 0644 root:root <<'EOF'
[Unit]
Description=Discovery-OVA network safety rollback
After=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/discovery-ova-network rollback
EOF

  write_file /etc/systemd/system/discovery-ova-network-rollback.timer 0644 root:root <<'EOF'
[Unit]
Description=Two-minute Discovery-OVA network rollback timer

[Timer]
OnActiveSec=2min
AccuracySec=1s
Unit=discovery-ova-network-rollback.service

[Install]
WantedBy=timers.target
EOF

  write_file /etc/systemd/system/discovery-ova-network-boot-guard.service 0644 root:root <<'EOF'
[Unit]
Description=Discovery-OVA boot network guard
Wants=network-online.target
After=NetworkManager.service network-online.target
Before=discovery-ova-boot-email.service discovery-ova-tls-refresh.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/discovery-ova-network-boot-guard
TimeoutStartSec=45

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable discovery-ova-network-boot-guard.service
  /usr/local/sbin/discovery-ova-network capture
  sleep 1
  /usr/local/sbin/discovery-ova-network confirm
  log "Network verification:"
  /usr/local/sbin/discovery-ova-network status | tee -a "$LOG_FILE"
}

configure_diagnostics_services() {
  log "Configuring integrated iperf3 and LLDP diagnostics."

  # LLDP is receive-only so the appliance can learn neighbors without transmitting
  # discovery frames from a passive/SPAN-connected capture interface.
  write_file /etc/default/lldpd 0644 root:root <<EOF
# Managed by Discovery-OVA. Listen only on the appliance vNICs and do not transmit.
DAEMON_ARGS="-r -I $MGMT_IF,$CAPTURE_IF"
EOF
  systemctl enable lldpd.service
  systemctl restart lldpd.service

  # Non-secret interface-only settings readable by the unprivileged iperf3 service.
  write_file /etc/default/discovery-ova-iperf3 0644 root:root <<EOF
MGMT_IF='$MGMT_IF'
CAPTURE_IF='$CAPTURE_IF'
EOF

  write_file /usr/local/sbin/discovery-ova-iperf3-server 0750 root:discovery-ova <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/default/discovery-ova-iperf3
bind_ip=""
for dev in "$MGMT_IF" "$CAPTURE_IF"; do
  ip="$(ip -4 -o addr show dev "$dev" scope global 2>/dev/null | awk 'NR==1{split($4,a,"/");print a[1]}')"
  [[ -n "$ip" ]] || continue
  if ip -4 route show default dev "$dev" 2>/dev/null | grep -q '^default '; then
    bind_ip="$ip"
    break
  fi
done
if [[ -z "$bind_ip" ]]; then
  for dev in "$MGMT_IF" "$CAPTURE_IF"; do
    bind_ip="$(ip -4 -o addr show dev "$dev" scope global 2>/dev/null | awk 'NR==1{split($4,a,"/");print a[1]}')"
    [[ -n "$bind_ip" ]] && break
  done
fi
[[ -n "$bind_ip" ]] || { echo "No usable Discovery-OVA IPv4 address is available for iperf3." >&2; exit 1; }
echo "Starting one-shot iperf3 server on $bind_ip:5201"
exec /usr/bin/iperf3 --server --one-off --bind "$bind_ip" --port 5201 --forceflush
EOF

  write_file /etc/systemd/system/discovery-ova-iperf3-server.service 0644 root:root <<'EOF'
[Unit]
Description=Discovery-OVA temporary one-shot iperf3 server
After=network-online.target discovery-ova-network-boot-guard.service
Wants=network-online.target

[Service]
Type=simple
User=discovery-ova
Group=discovery-ova
ExecStart=/usr/local/sbin/discovery-ova-iperf3-server
Restart=no
RuntimeMaxSec=15min
TimeoutStopSec=5s
KillSignal=SIGINT
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl stop discovery-ova-iperf3-server.service >/dev/null 2>&1 || true
  systemctl is-active --quiet lldpd.service || die "lldpd failed to start."
}

configure_firewall() {
  backup_path /etc/ufw/user.rules
  ufw --force reset >/dev/null
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow in on "$MGMT_IF" to any port 22 proto tcp comment 'Discovery-OVA SSH'
  ufw allow in on "$MGMT_IF" to any port 443 proto tcp comment 'Discovery-OVA portal'
  for p in 8443 8444 8445 8446 8447; do
    ufw allow in on "$MGMT_IF" to any port "$p" proto tcp comment "Discovery-OVA app $p"
  done
  # The second NIC normally has no address. These rules become useful only if the operator
  # explicitly switches it to the discovery-ova-wired DHCP management profile.
  ufw allow in on "$CAPTURE_IF" to any port 22 proto tcp comment 'Discovery-OVA wired-fallback SSH'
  ufw allow in on "$CAPTURE_IF" to any port 443 proto tcp comment 'Discovery-OVA wired-fallback portal'
  for p in 8443 8444 8445 8446 8447; do
    ufw allow in on "$CAPTURE_IF" to any port "$p" proto tcp comment "Discovery-OVA wired-fallback app $p"
  done
  ufw allow in on "$MGMT_IF" to any port 514 proto tcp comment 'Discovery-OVA syslog TCP'
  ufw allow in on "$MGMT_IF" to any port 514 proto udp comment 'Discovery-OVA syslog UDP'
  ufw allow in on "$MGMT_IF" to any port 5353 proto udp comment 'Discovery-OVA mDNS'
  # iperf3 only listens while the operator starts the one-shot test server.
  ufw allow in on "$MGMT_IF" to any port 5201 proto tcp comment 'Discovery-OVA temporary iperf3 TCP'
  ufw allow in on "$MGMT_IF" to any port 5201 proto udp comment 'Discovery-OVA temporary iperf3 UDP'
  ufw allow in on "$CAPTURE_IF" to any port 514 proto tcp comment 'Discovery-OVA wired-fallback syslog TCP'
  ufw allow in on "$CAPTURE_IF" to any port 514 proto udp comment 'Discovery-OVA wired-fallback syslog UDP'
  ufw allow in on "$CAPTURE_IF" to any port 5353 proto udp comment 'Discovery-OVA wired-fallback mDNS'
  ufw allow in on "$CAPTURE_IF" to any port 5201 proto tcp comment 'Discovery-OVA wired-fallback temporary iperf3 TCP'
  ufw allow in on "$CAPTURE_IF" to any port 5201 proto udp comment 'Discovery-OVA wired-fallback temporary iperf3 UDP'
  ufw --force enable
}
resolve_ntop_image() {
  local digest
  docker pull ntop/ntopng:latest >/dev/null
  digest="$(docker image inspect --format '{{index .RepoDigests 0}}' ntop/ntopng:latest 2>/dev/null || true)"
  [[ "$digest" == ntop/ntopng@sha256:* ]] || die "Could not resolve immutable ntopng digest."
  printf '%s' "$digest"
}

write_remote_base_configs() {
  install -d -m 0750 -o root -g discovery-ova \
    "$CONFIG_DIR/prometheus" "$CONFIG_DIR/blackbox" "$CONFIG_DIR/telegraf" "$CONFIG_DIR/redfish" "$CONFIG_DIR/guacamole"

  [[ -s "$CONFIG_DIR/prometheus/blackbox-targets.json" ]] || \
    write_file "$CONFIG_DIR/prometheus/blackbox-targets.json" 0640 root:discovery-ova <<'EOF'
[]
EOF

  write_file "$CONFIG_DIR/blackbox/blackbox.yml" 0644 root:root <<'EOF'
modules:
  icmp:
    prober: icmp
    timeout: 5s
    icmp:
      preferred_ip_protocol: ip4
  http_2xx:
    prober: http
    timeout: 10s
    http:
      preferred_ip_protocol: ip4
      method: GET
  https_insecure:
    prober: http
    timeout: 10s
    http:
      preferred_ip_protocol: ip4
      method: GET
      tls_config:
        insecure_skip_verify: true
  tcp_connect:
    prober: tcp
    timeout: 5s
    tcp:
      preferred_ip_protocol: ip4
  dns_udp:
    prober: dns
    timeout: 5s
    dns:
      preferred_ip_protocol: ip4
      transport_protocol: udp
      query_name: example.com
      query_type: A
EOF

  write_file "$CONFIG_DIR/telegraf/vsphere.conf" 0644 root:root <<'EOF'
[agent]
  interval = "60s"
  round_interval = true
  flush_interval = "15s"

[[inputs.vsphere]]
  vcenters = ["${VCENTER_URL}"]
  username = "${VCENTER_USERNAME}"
  password = "${VCENTER_PASSWORD}"
  insecure_skip_verify = ${VCENTER_INSECURE}
  collect_concurrency = 5
  discover_concurrency = 5

[[outputs.prometheus_client]]
  listen = ":9273"
  metric_version = 2
  path = "/metrics"
EOF

  if [[ ! -s "$ETC_ROOT/vsphere.env" ]]; then
    write_file "$ETC_ROOT/vsphere.env" 0600 root:root <<'EOF'
VCENTER_URL=https://127.0.0.1/sdk
VCENTER_USERNAME=disabled
VCENTER_PASSWORD=disabled
VCENTER_INSECURE=true
EOF
  fi
  [[ -s "$ETC_ROOT/vsphere.json" ]] || write_file "$ETC_ROOT/vsphere.json" 0600 root:root <<'EOF'
{"enabled":false}
EOF
  [[ -s "$ETC_ROOT/redfish.json" ]] || write_file "$ETC_ROOT/redfish.json" 0600 root:root <<'EOF'
{"enabled":false,"targets":[]}
EOF
  [[ -s "$ETC_ROOT/pure-monitoring.json" ]] || write_file "$ETC_ROOT/pure-monitoring.json" 0600 root:root <<'EOF'
{"enabled":false,"arrays":[]}
EOF

  if [[ ! -s "$CONFIG_DIR/redfish/idrac.yml" ]]; then
    write_file "$CONFIG_DIR/redfish/idrac.yml" 0600 root:root <<'EOF'
address: 0.0.0.0
port: 9348
timeout: 20
hosts:
  default:
    username: disabled
    password: disabled
    scheme: https
metrics:
  system: true
  sensors: true
  power: true
  storage: true
  memory: true
  network: true
  manager: true
EOF
  fi
  [[ -s "$CONFIG_DIR/prometheus/redfish-targets.json" ]] || write_file "$CONFIG_DIR/prometheus/redfish-targets.json" 0640 root:discovery-ova <<'EOF'
[]
EOF
}

write_prometheus_config() {
  local tmp enabled url name token insecure
  tmp="$(mktemp)"
  cat >"$tmp" <<'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s
scrape_configs:
  - job_name: node
    static_configs:
      - targets: ['node-exporter:9100']
  - job_name: cadvisor
    static_configs:
      - targets: ['cadvisor:8080']
  - job_name: prometheus
    static_configs:
      - targets: ['prometheus:9090']
  - job_name: blackbox-exporter
    static_configs:
      - targets: ['blackbox-exporter:9115']
  - job_name: blackbox
    metrics_path: /probe
    file_sd_configs:
      - files: ['/etc/prometheus/blackbox-targets.json']
        refresh_interval: 15s
    relabel_configs:
      - source_labels: [module]
        target_label: __param_module
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - source_labels: [name]
        target_label: target_name
      - target_label: __address__
        replacement: blackbox-exporter:9115
EOF

  enabled="$(jq -r '.enabled // false' "$ETC_ROOT/vsphere.json" 2>/dev/null || echo false)"
  if [[ "$enabled" == true ]]; then
    cat >>"$tmp" <<'EOF'
  - job_name: vsphere
    scrape_interval: 60s
    scrape_timeout: 55s
    static_configs:
      - targets: ['telegraf-vsphere:9273']
EOF
  fi

  enabled="$(jq -r '.enabled // false' "$ETC_ROOT/redfish.json" 2>/dev/null || echo false)"
  if [[ "$enabled" == true ]]; then
    cat >>"$tmp" <<'EOF'
  - job_name: redfish
    scrape_interval: 120s
    scrape_timeout: 110s
    file_sd_configs:
      - files: ['/etc/prometheus/redfish-targets.json']
        refresh_interval: 30s
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: redfish-exporter:9348
EOF
  fi

  enabled="$(jq -r '.enabled // false' "$ETC_ROOT/pure-monitoring.json" 2>/dev/null || echo false)"
  if [[ "$enabled" == true ]]; then
    while IFS=$'\t' read -r name url token insecure; do
      [[ -n "$url" && -n "$token" ]] || continue
      # Prometheus basic YAML scalar safety: setup rejects whitespace/newlines in name/address; tokens are JSON-decoded here.
      cat >>"$tmp" <<EOF
  - job_name: purefa_${name}_array
    scheme: https
    metrics_path: /metrics/array
    scrape_interval: 60s
    scrape_timeout: 55s
    authorization:
      credentials: '$token'
    tls_config:
      insecure_skip_verify: $insecure
    static_configs:
      - targets: ['$url']
        labels: {array: '$name'}
  - job_name: purefa_${name}_hosts
    scheme: https
    metrics_path: /metrics/hosts
    scrape_interval: 60s
    scrape_timeout: 55s
    authorization:
      credentials: '$token'
    tls_config:
      insecure_skip_verify: $insecure
    static_configs:
      - targets: ['$url']
        labels: {array: '$name'}
  - job_name: purefa_${name}_volumes
    scheme: https
    metrics_path: /metrics/volumes
    scrape_interval: 60s
    scrape_timeout: 55s
    authorization:
      credentials: '$token'
    tls_config:
      insecure_skip_verify: $insecure
    static_configs:
      - targets: ['$url']
        labels: {array: '$name'}
EOF
    done < <(jq -r '.arrays[]? | [.name,.address,.token,(.insecure|tostring)] | @tsv' "$ETC_ROOT/pure-monitoring.json" 2>/dev/null)
  fi

  backup_path "$CONFIG_DIR/prometheus/prometheus.yml"
  install -m 0640 -o root -g discovery-ova "$tmp" "$CONFIG_DIR/prometheus/prometheus.yml"
  rm -f "$tmp"
}

configure_remote_monitoring_interactive() {
  require_root
  load_conf
  install -d -m 0700 "$ETC_ROOT"
  local ans vc user pass insecure target targets_json rf_user rf_pass name address token pure_json safe_name

  echo "Remote infrastructure monitoring configuration"
  echo "Secrets are entered here with hidden input and stored in root-only files."

  prompt_yes_no "Configure VMware vSphere/vCenter monitoring?" N ans
  if [[ "$ans" == y ]]; then
    prompt_value "vCenter hostname or URL" "" vc valid_no_space "Enter a hostname or URL without spaces."
    if [[ "$vc" != http://* && "$vc" != https://* ]]; then vc="https://$vc"; fi
    [[ "$vc" == */sdk ]] || vc="${vc%/}/sdk"
    prompt_value "vCenter read-only username" "" user valid_nonempty "A vCenter username is required."
    prompt_hidden_nonempty "vCenter password" pass
    prompt_yes_no "Allow self-signed/unverified vCenter TLS certificate?" Y ans
    [[ "$ans" == y ]] && insecure=true || insecure=false
    {
      printf 'VCENTER_URL=%s\n' "$(jq -Rn --arg v "$vc" '$v')"
      printf 'VCENTER_USERNAME=%s\n' "$(jq -Rn --arg v "$user" '$v')"
      printf 'VCENTER_PASSWORD=%s\n' "$(jq -Rn --arg v "$pass" '$v')"
      printf 'VCENTER_INSECURE=%s\n' "$insecure"
    } | write_file "$ETC_ROOT/vsphere.env" 0600 root:root
    jq -n --arg url "$vc" '{enabled:true,url:$url}' | write_file "$ETC_ROOT/vsphere.json" 0600 root:root
    (cd "$COMPOSE_DIR" && docker compose --profile vsphere up -d telegraf-vsphere)
  else
    write_file "$ETC_ROOT/vsphere.json" 0600 root:root <<'EOF'
{"enabled":false}
EOF
    (cd "$COMPOSE_DIR" && docker compose stop telegraf-vsphere >/dev/null 2>&1 || true)
  fi

  prompt_yes_no "Configure Redfish server/BMC monitoring (iDRAC/iLO/XClarity/etc.)?" N ans
  if [[ "$ans" == y ]]; then
    prompt_value "Shared read-only BMC username" "" rf_user valid_nonempty "A BMC username is required."
    prompt_hidden_nonempty "Shared BMC password" rf_pass
    targets_json='[]'
    echo "Enter BMC IPs/hostnames one at a time; press Enter on an empty line when done."
    while true; do
      read -r -p "BMC target: " target
      if [[ -z "$target" ]]; then
        if [[ "$(jq 'length' <<<"$targets_json")" -gt 0 ]]; then break; fi
        echo "At least one BMC target is required. Enter a target before finishing."
        continue
      fi
      if ! valid_bmc_target "$target"; then
        echo "Invalid BMC target. Use a hostname or IP address without spaces. Please try again."
        continue
      fi
      targets_json="$(jq -c --arg t "$target" '. + [$t] | unique' <<<"$targets_json")"
    done
    {
      echo 'address: 0.0.0.0'
      echo 'port: 9348'
      echo 'timeout: 20'
      echo 'hosts:'
      printf "  default:\n    username: '%s'\n    password: '%s'\n    scheme: https\n" "$(printf '%s' "$rf_user" | sed "s/'/''/g")" "$(printf '%s' "$rf_pass" | sed "s/'/''/g")"
      cat <<'EOF'
metrics:
  system: true
  sensors: true
  power: true
  storage: true
  memory: true
  network: true
  manager: true
EOF
    } | write_file "$CONFIG_DIR/redfish/idrac.yml" 0600 root:root
    jq -n --argjson targets "$targets_json" '{enabled:true,targets:$targets}' | write_file "$ETC_ROOT/redfish.json" 0600 root:root
    jq -n --argjson ts "$targets_json" '[ $ts[] | {targets:[.],labels:{source:"redfish"}} ]' | write_file "$CONFIG_DIR/prometheus/redfish-targets.json" 0640 root:discovery-ova
    (cd "$COMPOSE_DIR" && docker compose --profile redfish up -d redfish-exporter)
  else
    write_file "$ETC_ROOT/redfish.json" 0600 root:root <<'EOF'
{"enabled":false,"targets":[]}
EOF
    write_file "$CONFIG_DIR/prometheus/redfish-targets.json" 0640 root:discovery-ova <<'EOF'
[]
EOF
    (cd "$COMPOSE_DIR" && docker compose stop redfish-exporter >/dev/null 2>&1 || true)
  fi

  prompt_yes_no "Configure Pure FlashArray native OpenMetrics monitoring?" N ans
  if [[ "$ans" == y ]]; then
    pure_json='[]'
    echo "This uses the FlashArray native OpenMetrics endpoint (Purity//FA 6.6.11+)."
    while true; do
      read -r -p "FlashArray short name (empty when finished): " name
      if [[ -z "$name" ]]; then
        if [[ "$(jq 'length' <<<"$pure_json")" -gt 0 ]]; then break; fi
        echo "At least one FlashArray is required when Pure monitoring is enabled. Enter an array name first."
        continue
      fi
      if ! valid_array_name "$name"; then
        echo "Array name may contain only letters, digits, _ and -. Please try again."
        continue
      fi
      safe_name="${name//-/_}"
      prompt_value "FlashArray management IP/hostname[:port]" "" address valid_pure_address "Prefer an IPv4 address to avoid DNS dependency; hostname is supported when intentionally configured."
      [[ "$address" == *:* ]] || address="${address}:443"
      while true; do
        read -r -s -p "Read-only FlashArray API token: " token; echo
        if [[ -n "$token" && "$token" != *$'\n'* && "$token" != *"'"* ]]; then break; fi
        echo "API token cannot be empty or contain a single quote/newline. Please try again."
      done
      prompt_yes_no "Allow self-signed/unverified FlashArray TLS certificate?" Y ans
      [[ "$ans" == y ]] && insecure=true || insecure=false
      pure_json="$(jq -c --arg n "$safe_name" --arg a "$address" --arg t "$token" --argjson i "$insecure" '. + [{name:$n,address:$a,token:$t,insecure:$i}]' <<<"$pure_json")"
    done
    jq -n --argjson arrays "$pure_json" '{enabled:true,arrays:$arrays}' | write_file "$ETC_ROOT/pure-monitoring.json" 0600 root:root
  else
    write_file "$ETC_ROOT/pure-monitoring.json" 0600 root:root <<'EOF'
{"enabled":false,"arrays":[]}
EOF
  fi

  write_prometheus_config
  if docker ps --format '{{.Names}}' | grep -Fxq discovery-ova-prometheus; then
    if docker exec discovery-ova-prometheus promtool check config /etc/prometheus/prometheus.yml >/dev/null 2>&1; then
      curl -fsS -X POST http://127.0.0.1:9090/-/reload >/dev/null || docker restart discovery-ova-prometheus >/dev/null
    else
      die "Prometheus rejected the generated remote-monitoring configuration."
    fi
  fi
  echo "Remote monitoring configuration updated."
}

write_observability_configs() {
  install -d -m 0750 "$CONFIG_DIR/prometheus" "$CONFIG_DIR/loki" "$CONFIG_DIR/alloy" "$CONFIG_DIR/grafana/provisioning/datasources" "$CONFIG_DIR/grafana/provisioning/dashboards" "$CONFIG_DIR/grafana/dashboards"

  write_remote_base_configs
  write_prometheus_config

  write_file "$CONFIG_DIR/loki/loki.yml" 0644 root:root <<'EOF'
auth_enabled: false
server:
  http_listen_port: 3100
common:
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory
schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h
storage_config:
  filesystem:
    directory: /loki/chunks
compactor:
  working_directory: /loki/compactor
  retention_enabled: true
  delete_request_store: filesystem
limits_config:
  retention_period: 168h
  allow_structured_metadata: true
analytics:
  reporting_enabled: false
EOF

  write_file "$CONFIG_DIR/alloy/config.alloy" 0644 root:root <<'EOF'
logging {
  level = "info"
}

loki.source.syslog "rsyslog" {
  listener {
    address                = "0.0.0.0:1514"
    protocol               = "tcp"
    syslog_format          = "rfc5424"
    use_incoming_timestamp = true
    label_structured_data  = true
    labels = {
      job = "syslog",
    }
  }
  relabel_rules = loki.relabel.syslog.rules
  forward_to    = [loki.write.local.receiver]
}

loki.relabel "syslog" {
  forward_to = [loki.write.local.receiver]

  rule {
    source_labels = ["__syslog_message_hostname"]
    target_label  = "host"
  }
  rule {
    source_labels = ["__syslog_message_app_name"]
    target_label  = "app"
  }
  rule {
    source_labels = ["__syslog_message_severity"]
    target_label  = "severity"
  }
  rule {
    source_labels = ["__syslog_message_facility"]
    target_label  = "facility"
  }
  rule {
    source_labels = ["__syslog_message_sd_discovery_ova_source_ip"]
    target_label  = "source_ip"
  }
}

loki.write "local" {
  endpoint {
    url = "http://loki:3100/loki/api/v1/push"
  }
}
EOF

  write_file "$CONFIG_DIR/grafana/provisioning/datasources/datasources.yml" 0644 root:root <<'EOF'
apiVersion: 1
datasources:
  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: false
  - name: Loki
    uid: loki
    type: loki
    access: proxy
    url: http://loki:3100
    editable: false
EOF

  write_file "$CONFIG_DIR/grafana/provisioning/dashboards/dashboards.yml" 0644 root:root <<'EOF'
apiVersion: 1
providers:
  - name: Discovery-OVA
    orgId: 1
    folder: Discovery-OVA
    type: file
    disableDeletion: true
    editable: true
    options:
      path: /var/lib/grafana/dashboards
EOF

  write_file "$CONFIG_DIR/grafana/dashboards/discovery-ova-overview.json" 0644 root:root <<'EOF'
{
  "annotations": {
    "list": []
  },
  "editable": true,
  "graphTooltip": 1,
  "panels": [
    {
      "type": "stat",
      "title": "Metrics Pipeline",
      "gridPos": {
        "h": 4,
        "w": 4,
        "x": 0,
        "y": 0
      },
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "targets": [
        {
          "expr": "min(up)",
          "refId": "A"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "thresholds"
          },
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "red",
                "value": null
              },
              {
                "color": "green",
                "value": 1
              }
            ]
          }
        },
        "overrides": []
      },
      "options": {
        "colorMode": "background",
        "graphMode": "area",
        "justifyMode": "auto",
        "textMode": "auto"
      }
    },
    {
      "type": "stat",
      "title": "CPU Usage %",
      "gridPos": {
        "h": 4,
        "w": 4,
        "x": 4,
        "y": 0
      },
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "targets": [
        {
          "expr": "100 - (avg(rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100)",
          "refId": "A"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "thresholds"
          },
          "unit": "percent",
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "green",
                "value": null
              },
              {
                "color": "yellow",
                "value": 70
              },
              {
                "color": "red",
                "value": 90
              }
            ]
          }
        },
        "overrides": []
      },
      "options": {
        "colorMode": "background",
        "graphMode": "area",
        "justifyMode": "auto",
        "textMode": "auto"
      }
    },
    {
      "type": "stat",
      "title": "Memory Usage %",
      "gridPos": {
        "h": 4,
        "w": 4,
        "x": 8,
        "y": 0
      },
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "targets": [
        {
          "expr": "100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)",
          "refId": "A"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "thresholds"
          },
          "unit": "percent",
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "green",
                "value": null
              },
              {
                "color": "yellow",
                "value": 70
              },
              {
                "color": "red",
                "value": 90
              }
            ]
          }
        },
        "overrides": []
      },
      "options": {
        "colorMode": "background",
        "graphMode": "area",
        "justifyMode": "auto",
        "textMode": "auto"
      }
    },
    {
      "type": "stat",
      "title": "Root Disk %",
      "gridPos": {
        "h": 4,
        "w": 4,
        "x": 12,
        "y": 0
      },
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "targets": [
        {
          "expr": "100 * (1 - node_filesystem_avail_bytes{mountpoint=\"/\",fstype!~\"tmpfs|overlay\"} / node_filesystem_size_bytes{mountpoint=\"/\",fstype!~\"tmpfs|overlay\"})",
          "refId": "A"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "thresholds"
          },
          "unit": "percent",
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "green",
                "value": null
              },
              {
                "color": "yellow",
                "value": 70
              },
              {
                "color": "red",
                "value": 90
              }
            ]
          }
        },
        "overrides": []
      },
      "options": {
        "colorMode": "background",
        "graphMode": "area",
        "justifyMode": "auto",
        "textMode": "auto"
      }
    },
    {
      "type": "stat",
      "title": "Uptime",
      "gridPos": {
        "h": 4,
        "w": 4,
        "x": 16,
        "y": 0
      },
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "targets": [
        {
          "expr": "time() - node_boot_time_seconds",
          "refId": "A"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "thresholds"
          },
          "unit": "s"
        },
        "overrides": []
      },
      "options": {
        "colorMode": "background",
        "graphMode": "area",
        "justifyMode": "auto",
        "textMode": "auto"
      }
    },
    {
      "type": "stat",
      "title": "CPU Temperature \u00b0F",
      "gridPos": {
        "h": 4,
        "w": 4,
        "x": 20,
        "y": 0
      },
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "targets": [
        {
          "expr": "discovery_ova_cpu_temperature_fahrenheit",
          "refId": "A"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "thresholds"
          },
          "unit": "fahrenheit",
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "green",
                "value": null
              },
              {
                "color": "yellow",
                "value": 150
              },
              {
                "color": "red",
                "value": 180
              }
            ]
          }
        },
        "overrides": []
      },
      "options": {
        "colorMode": "background",
        "graphMode": "area",
        "justifyMode": "auto",
        "textMode": "auto"
      }
    },
    {
      "type": "stat",
      "title": "Core Services",
      "gridPos": {
        "h": 4,
        "w": 4,
        "x": 0,
        "y": 4
      },
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "targets": [
        {
          "expr": "min(discovery_ova_service_up)",
          "refId": "A"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "thresholds"
          },
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "red",
                "value": null
              },
              {
                "color": "green",
                "value": 1
              }
            ]
          }
        },
        "overrides": []
      },
      "options": {
        "colorMode": "background",
        "graphMode": "area",
        "justifyMode": "auto",
        "textMode": "auto"
      }
    },
    {
      "type": "stat",
      "title": "Timers",
      "gridPos": {
        "h": 4,
        "w": 4,
        "x": 4,
        "y": 4
      },
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "targets": [
        {
          "expr": "min(discovery_ova_timer_up)",
          "refId": "A"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "thresholds"
          },
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "red",
                "value": null
              },
              {
                "color": "green",
                "value": 1
              }
            ]
          }
        },
        "overrides": []
      },
      "options": {
        "colorMode": "background",
        "graphMode": "area",
        "justifyMode": "auto",
        "textMode": "auto"
      }
    },
    {
      "type": "stat",
      "title": "Containers",
      "gridPos": {
        "h": 4,
        "w": 4,
        "x": 8,
        "y": 4
      },
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "targets": [
        {
          "expr": "count(container_last_seen{name!=\"\"})",
          "refId": "A"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "thresholds"
          }
        },
        "overrides": []
      },
      "options": {
        "colorMode": "background",
        "graphMode": "area",
        "justifyMode": "auto",
        "textMode": "auto"
      }
    },
    {
      "type": "stat",
      "title": "Management Path",
      "gridPos": {
        "h": 4,
        "w": 4,
        "x": 12,
        "y": 4
      },
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "targets": [
        {
          "expr": "discovery_ova_management_up",
          "refId": "A"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "thresholds"
          },
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "red",
                "value": null
              },
              {
                "color": "green",
                "value": 1
              }
            ]
          }
        },
        "overrides": []
      },
      "options": {
        "colorMode": "background",
        "graphMode": "area",
        "justifyMode": "auto",
        "textMode": "auto"
      }
    },
    {
      "type": "stat",
      "title": "Capture Mode",
      "gridPos": {
        "h": 4,
        "w": 4,
        "x": 16,
        "y": 4
      },
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "targets": [
        {
          "expr": "discovery_ova_capture_mode",
          "refId": "A"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "thresholds"
          },
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "red",
                "value": null
              },
              {
                "color": "green",
                "value": 1
              }
            ]
          }
        },
        "overrides": []
      },
      "options": {
        "colorMode": "background",
        "graphMode": "area",
        "justifyMode": "auto",
        "textMode": "auto"
      }
    },
    {
      "type": "stat",
      "title": "Ethernet Carrier",
      "gridPos": {
        "h": 4,
        "w": 4,
        "x": 20,
        "y": 4
      },
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "targets": [
        {
          "expr": "discovery_ova_capture_carrier",
          "refId": "A"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "thresholds"
          },
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "red",
                "value": null
              },
              {
                "color": "green",
                "value": 1
              }
            ]
          }
        },
        "overrides": []
      },
      "options": {
        "colorMode": "background",
        "graphMode": "area",
        "justifyMode": "auto",
        "textMode": "auto"
      }
    },
    {
      "type": "stat",
      "title": "Guacamole",
      "gridPos": {
        "h": 4,
        "w": 4,
        "x": 0,
        "y": 8
      },
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "targets": [
        {
          "expr": "discovery_ova_guacamole_up",
          "refId": "A"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "thresholds"
          },
          "unit": "none",
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "red",
                "value": null
              },
              {
                "color": "green",
                "value": 1
              }
            ]
          }
        },
        "overrides": []
      },
      "options": {
        "colorMode": "background",
        "graphMode": "area",
        "justifyMode": "auto",
        "textMode": "auto"
      }
    },
    {
      "type": "stat",
      "title": "Backup Age",
      "gridPos": {
        "h": 4,
        "w": 4,
        "x": 4,
        "y": 8
      },
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "targets": [
        {
          "expr": "time() - discovery_ova_last_backup_timestamp_seconds",
          "refId": "A"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "thresholds"
          },
          "unit": "s"
        },
        "overrides": []
      },
      "options": {
        "colorMode": "background",
        "graphMode": "area",
        "justifyMode": "auto",
        "textMode": "auto"
      }
    },
    {
      "type": "stat",
      "title": "Syslog Ingestion",
      "gridPos": {
        "h": 4,
        "w": 4,
        "x": 8,
        "y": 8
      },
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "targets": [
        {
          "expr": "discovery_ova_syslog_udp_listener * discovery_ova_syslog_tcp_listener",
          "refId": "A"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "thresholds"
          },
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "red",
                "value": null
              },
              {
                "color": "green",
                "value": 1
              }
            ]
          }
        },
        "overrides": []
      },
      "options": {
        "colorMode": "background",
        "graphMode": "area",
        "justifyMode": "auto",
        "textMode": "auto"
      }
    },
    {
      "type": "stat",
      "title": "Packet Capture",
      "gridPos": {
        "h": 4,
        "w": 4,
        "x": 12,
        "y": 8
      },
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "targets": [
        {
          "expr": "discovery_ova_packet_capture_active",
          "refId": "A"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "thresholds"
          }
        },
        "overrides": []
      },
      "options": {
        "colorMode": "background",
        "graphMode": "area",
        "justifyMode": "auto",
        "textMode": "auto"
      }
    },
    {
      "type": "stat",
      "title": "Promiscuous",
      "gridPos": {
        "h": 4,
        "w": 4,
        "x": 16,
        "y": 8
      },
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "targets": [
        {
          "expr": "discovery_ova_capture_promiscuous",
          "refId": "A"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "thresholds"
          },
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "red",
                "value": null
              },
              {
                "color": "green",
                "value": 1
              }
            ]
          }
        },
        "overrides": []
      },
      "options": {
        "colorMode": "background",
        "graphMode": "area",
        "justifyMode": "auto",
        "textMode": "auto"
      }
    },
    {
      "type": "stat",
      "title": "Rollback Pending",
      "gridPos": {
        "h": 4,
        "w": 4,
        "x": 20,
        "y": 8
      },
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "targets": [
        {
          "expr": "discovery_ova_rollback_pending",
          "refId": "A"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "thresholds"
          },
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "green",
                "value": null
              },
              {
                "color": "red",
                "value": 1
              }
            ]
          }
        },
        "overrides": []
      },
      "options": {
        "colorMode": "background",
        "graphMode": "area",
        "justifyMode": "auto",
        "textMode": "auto"
      }
    },
    {
      "type": "timeseries",
      "title": "Network Throughput",
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 0,
        "y": 12
      },
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "targets": [
        {
          "expr": "rate(node_network_receive_bytes_total{device!~=\"lo|veth.*|docker.*|br-.*\"}[5m]) * 8",
          "legendFormat": "RX {{device}}",
          "refId": "A"
        },
        {
          "expr": "rate(node_network_transmit_bytes_total{device!~=\"lo|veth.*|docker.*|br-.*\"}[5m]) * 8",
          "legendFormat": "TX {{device}}",
          "refId": "B"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "bps"
        },
        "overrides": []
      }
    },
    {
      "type": "timeseries",
      "title": "CPU and Memory",
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 12,
        "y": 12
      },
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "targets": [
        {
          "expr": "100 - (avg(rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100)",
          "legendFormat": "CPU %",
          "refId": "A"
        },
        {
          "expr": "100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)",
          "legendFormat": "Memory %",
          "refId": "B"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "min": 0,
          "max": 100
        },
        "overrides": []
      }
    },
    {
      "type": "timeseries",
      "title": "CPU Temperature",
      "gridPos": {
        "h": 8,
        "w": 8,
        "x": 0,
        "y": 20
      },
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "targets": [
        {
          "expr": "discovery_ova_cpu_temperature_fahrenheit",
          "legendFormat": "\u00b0F",
          "refId": "A"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "fahrenheit"
        },
        "overrides": []
      }
    },
    {
      "type": "timeseries",
      "title": "Container CPU",
      "gridPos": {
        "h": 8,
        "w": 8,
        "x": 8,
        "y": 20
      },
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "targets": [
        {
          "expr": "sum by (name) (rate(container_cpu_usage_seconds_total{name!=\"\"}[5m])) * 100",
          "legendFormat": "{{name}}",
          "refId": "A"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "percent"
        },
        "overrides": []
      }
    },
    {
      "type": "logs",
      "title": "Recent Syslog",
      "gridPos": {
        "h": 8,
        "w": 8,
        "x": 16,
        "y": 20
      },
      "datasource": {
        "type": "loki",
        "uid": "loki"
      },
      "targets": [
        {
          "expr": "{job=\"syslog\"}",
          "refId": "A"
        }
      ],
      "options": {
        "showTime": true,
        "wrapLogMessage": true,
        "enableLogDetails": true
      }
    }
  ],
  "refresh": "30s",
  "schemaVersion": 41,
  "tags": [
    "discovery-ova",
    "noc"
  ],
  "templating": {
    "list": []
  },
  "time": {
    "from": "now-6h",
    "to": "now"
  },
  "title": "Discovery-OVA Overview",
  "uid": "discovery-ova-overview",
  "version": 1
}
EOF


  write_file "$CONFIG_DIR/grafana/dashboards/discovery-ova-remote.json" 0644 root:root <<'EOF'
{
  "annotations":{"list":[]},
  "editable":true,
  "panels":[
    {"type":"stat","title":"Remote Probes Up","gridPos":{"h":5,"w":6,"x":0,"y":0},"datasource":{"type":"prometheus","uid":"prometheus"},"targets":[{"expr":"sum(probe_success)","refId":"A"}],"fieldConfig":{"defaults":{"color":{"mode":"thresholds"},"thresholds":{"mode":"absolute","steps":[{"color":"red","value":null},{"color":"green","value":1}]}},"overrides":[]}},
    {"type":"stat","title":"Remote Probes Total","gridPos":{"h":5,"w":6,"x":6,"y":0},"datasource":{"type":"prometheus","uid":"prometheus"},"targets":[{"expr":"count(probe_success)","refId":"A"}]},
    {"type":"stat","title":"vSphere Collector","gridPos":{"h":5,"w":6,"x":12,"y":0},"datasource":{"type":"prometheus","uid":"prometheus"},"targets":[{"expr":"max(up{job=\"vsphere\"})","refId":"A"}]},
    {"type":"stat","title":"Redfish Targets Up","gridPos":{"h":5,"w":6,"x":18,"y":0},"datasource":{"type":"prometheus","uid":"prometheus"},"targets":[{"expr":"sum(up{job=\"redfish\"})","refId":"A"}]},
    {"type":"timeseries","title":"Remote Probe Duration","gridPos":{"h":9,"w":12,"x":0,"y":5},"datasource":{"type":"prometheus","uid":"prometheus"},"targets":[{"expr":"probe_duration_seconds","legendFormat":"{{instance}}","refId":"A"}]},
    {"type":"timeseries","title":"Pure FlashArray Scrape Health","gridPos":{"h":9,"w":12,"x":12,"y":5},"datasource":{"type":"prometheus","uid":"prometheus"},"targets":[{"expr":"up{job=~\"purefa_.*\"}","legendFormat":"{{job}} {{instance}}","refId":"A"}]}
  ],
  "refresh":"30s",
  "schemaVersion":41,
  "tags":["discovery-ova","remote","infrastructure"],
  "time":{"from":"now-6h","to":"now"},
  "timezone":"America/Los_Angeles",
  "title":"Discovery-OVA Remote Infrastructure",
  "uid":"discovery-remote",
  "version":1
}
EOF
}

write_compose() {
  stage 3 "Core application and observability Docker stacks"
  # shellcheck disable=SC1090
  source "$SECRETS_FILE"
  local ntop_image
  ntop_image="$(resolve_ntop_image)"
  log "Pinned ntopng to $ntop_image"
  printf '%s\n' "$ntop_image" > "$ETC_ROOT/ntopng-image.lock"
  chmod 0600 "$ETC_ROOT/ntopng-image.lock"

  write_observability_configs

  write_file "$COMPOSE_DIR/.env" 0600 root:root <<EOF
TZ=$TIMEZONE
UTC_TZ=UTC
PUID=$DISCOVERY_OVA_UID
PGID=$DISCOVERY_OVA_GID
DB_PASSWORD=$DB_PASSWORD
GRAFANA_ADMIN_USER=$OPERATOR_USER
GRAFANA_ADMIN_PASSWORD=$GRAFANA_SECRET_KEY
GRAFANA_SECRET_KEY=$GRAFANA_SECRET_KEY
LIBRESPEED_RESULTS_PASSWORD=$LIBRESPEED_RESULTS_PASSWORD
SNMP_COMMUNITY=$SNMP_COMMUNITY
GUAC_DB_PASSWORD=$GUAC_DB_PASSWORD
GUAC_DB_ROOT_PASSWORD=$GUAC_DB_ROOT_PASSWORD
CAPTURE_IF=$CAPTURE_IF
NTOP_IMAGE=$ntop_image
EOF

  if [[ ! -s "$CONFIG_DIR/guacamole/initdb.sql" ]]; then
    log "Generating Apache Guacamole database schema from $GUACAMOLE_IMAGE."
    docker pull "$GUACAMOLE_IMAGE" >/dev/null
    docker run --rm "$GUACAMOLE_IMAGE" /opt/guacamole/bin/initdb.sh --mysql > "$CONFIG_DIR/guacamole/initdb.sql"
    chmod 0644 "$CONFIG_DIR/guacamole/initdb.sql"
  fi

  write_file "$COMPOSE_DIR/compose.yml" 0640 root:discovery-ova <<EOF
name: discovery-ova
services:
  db:
    image: $MARIADB_IMAGE
    container_name: discovery-ova-db
    command: ["mariadbd","--innodb-file-per-table=1","--lower-case-table-names=0","--character-set-server=utf8mb4","--collation-server=utf8mb4_unicode_ci"]
    environment:
      TZ: \${TZ}
      MARIADB_RANDOM_ROOT_PASSWORD: "yes"
      MARIADB_DATABASE: librenms
      MARIADB_USER: librenms
      MARIADB_PASSWORD: \${DB_PASSWORD}
    volumes:
      - $DATA_DIR/db:/var/lib/mysql
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 20s
      timeout: 5s
      retries: 10

  redis:
    image: $REDIS_IMAGE
    container_name: discovery-ova-redis
    environment:
      TZ: \${TZ}
    ports:
      - "127.0.0.1:6379:6379"
    volumes:
      - $DATA_DIR/redis:/data
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 20s
      timeout: 3s
      retries: 5

  librenms:
    image: $LIBRENMS_IMAGE
    container_name: discovery-ova-librenms
    hostname: librenms
    cap_add: ["NET_ADMIN", "NET_RAW"]
    depends_on:
      db: {condition: service_healthy}
      redis: {condition: service_healthy}
    environment:
      TZ: \${TZ}
      PUID: \${PUID}
      PGID: \${PGID}
      DB_HOST: db
      DB_NAME: librenms
      DB_USER: librenms
      DB_PASSWORD: \${DB_PASSWORD}
      DB_TIMEOUT: "60"
      REDIS_HOST: redis
      CACHE_DRIVER: redis
      SESSION_DRIVER: redis
      LIBRENMS_SNMP_COMMUNITY: \${SNMP_COMMUNITY}
    volumes:
      - $DATA_DIR/librenms:/data
    ports:
      - "127.0.0.1:8001:8000"
    restart: unless-stopped

  dispatcher:
    image: $LIBRENMS_IMAGE
    container_name: discovery-ova-librenms-dispatcher
    hostname: librenms-dispatcher
    cap_add: ["NET_ADMIN", "NET_RAW"]
    depends_on:
      db: {condition: service_healthy}
      redis: {condition: service_healthy}
    environment:
      TZ: \${TZ}
      PUID: \${PUID}
      PGID: \${PGID}
      DB_HOST: db
      DB_NAME: librenms
      DB_USER: librenms
      DB_PASSWORD: \${DB_PASSWORD}
      DB_TIMEOUT: "60"
      REDIS_HOST: redis
      CACHE_DRIVER: redis
      SESSION_DRIVER: redis
      DISPATCHER_NODE_ID: dispatcher1
      SIDECAR_DISPATCHER: "1"
    volumes:
      - $DATA_DIR/librenms:/data
    restart: unless-stopped

  smokeping:
    image: $SMOKEPING_IMAGE
    container_name: discovery-ova-smokeping
    environment:
      PUID: \${PUID}
      PGID: \${PGID}
      TZ: \${TZ}
    volumes:
      - $DATA_DIR/smokeping/config:/config
      - $DATA_DIR/smokeping/data:/data
    ports:
      - "127.0.0.1:8002:80"
    restart: unless-stopped

  librespeed:
    image: $LIBRESPEED_IMAGE
    container_name: discovery-ova-librespeed
    environment:
      PUID: \${PUID}
      PGID: \${PGID}
      TZ: \${TZ}
      PASSWORD: \${LIBRESPEED_RESULTS_PASSWORD}
      CUSTOM_RESULTS: "true"
      DB_TYPE: sqlite
    volumes:
      - $DATA_DIR/librespeed:/config
    ports:
      - "127.0.0.1:8003:80"
    restart: unless-stopped

  ntopng:
    image: \${NTOP_IMAGE}
    container_name: discovery-ova-ntopng
    environment:
      TZ: \${TZ}
    network_mode: host
    depends_on:
      redis: {condition: service_healthy}
    volumes:
      - $DATA_DIR/ntopng:/var/lib/ntopng
    command: ["--community", "-i", "\${CAPTURE_IF}", "-w", ":3000", "-d", "/var/lib/ntopng"]
    restart: unless-stopped


  guacamole-db:
    image: $MARIADB_IMAGE
    container_name: discovery-ova-guacamole-db
    environment:
      TZ: \${TZ}
      MARIADB_ROOT_PASSWORD: \${GUAC_DB_ROOT_PASSWORD}
      MARIADB_DATABASE: guacamole_db
      MARIADB_USER: guacamole_user
      MARIADB_PASSWORD: \${GUAC_DB_PASSWORD}
    volumes:
      - $DATA_DIR/guacamole-db:/var/lib/mysql
      - $CONFIG_DIR/guacamole/initdb.sql:/docker-entrypoint-initdb.d/001-initdb.sql:ro
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 20s
      timeout: 5s
      retries: 15

  guacd:
    image: $GUACD_IMAGE
    container_name: discovery-ova-guacd
    environment:
      TZ: \${TZ}
    restart: unless-stopped

  guacamole:
    image: $GUACAMOLE_IMAGE
    container_name: discovery-ova-guacamole
    depends_on:
      guacd: {condition: service_started}
      guacamole-db: {condition: service_healthy}
    environment:
      TZ: \${TZ}
      GUACD_HOSTNAME: guacd
      GUACD_PORT: "4822"
      MYSQL_ENABLED: "true"
      MYSQL_HOSTNAME: guacamole-db
      MYSQL_PORT: "3306"
      MYSQL_DATABASE: guacamole_db
      MYSQL_USERNAME: guacamole_user
      MYSQL_PASSWORD: \${GUAC_DB_PASSWORD}
      MYSQL_DRIVER: mariadb
      WEBAPP_CONTEXT: guacamole
    ports:
      - "127.0.0.1:8085:8080"
    restart: unless-stopped

  blackbox-exporter:
    image: $BLACKBOX_IMAGE
    container_name: discovery-ova-blackbox-exporter
    environment:
      TZ: \${UTC_TZ}
    cap_add: ["NET_RAW"]
    command:
      - --config.file=/config/blackbox.yml
      - --config.enable-auto-reload
    volumes:
      - $CONFIG_DIR/blackbox/blackbox.yml:/config/blackbox.yml:ro
    ports:
      - "127.0.0.1:9115:9115"
    restart: unless-stopped

  telegraf-vsphere:
    profiles: ["vsphere"]
    image: $TELEGRAF_IMAGE
    container_name: discovery-ova-telegraf-vsphere
    environment:
      TZ: \${UTC_TZ}
    env_file:
      - $ETC_ROOT/vsphere.env
    volumes:
      - $CONFIG_DIR/telegraf/vsphere.conf:/etc/telegraf/telegraf.conf:ro
    ports:
      - "127.0.0.1:9273:9273"
    restart: unless-stopped

  redfish-exporter:
    profiles: ["redfish"]
    image: $REDFISH_IMAGE
    container_name: discovery-ova-redfish-exporter
    user: "0:0"
    environment:
      TZ: \${UTC_TZ}
    command: ["-config", "/etc/prometheus/idrac.yml"]
    volumes:
      - $CONFIG_DIR/redfish/idrac.yml:/etc/prometheus/idrac.yml:ro
    ports:
      - "127.0.0.1:9348:9348"
    restart: unless-stopped


  prometheus:
    image: $PROMETHEUS_IMAGE
    container_name: discovery-ova-prometheus
    environment:
      TZ: \${UTC_TZ}
    group_add: ["\${PGID}"]
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --storage.tsdb.retention.time=15d
      - --web.enable-lifecycle
    volumes:
      - $CONFIG_DIR/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - $CONFIG_DIR/prometheus/blackbox-targets.json:/etc/prometheus/blackbox-targets.json:ro
      - $CONFIG_DIR/prometheus/redfish-targets.json:/etc/prometheus/redfish-targets.json:ro
      - $DATA_DIR/prometheus:/prometheus
    ports:
      - "127.0.0.1:9090:9090"
    restart: unless-stopped

  node-exporter:
    image: $NODE_EXPORTER_IMAGE
    container_name: discovery-ova-node-exporter
    environment:
      TZ: \${UTC_TZ}
    command:
      - --path.rootfs=/host
      - --collector.textfile.directory=/textfile
    pid: host
    volumes:
      - /:/host:ro,rslave
      - $STATE_ROOT/textfile_collector:/textfile:ro
    ports:
      - "127.0.0.1:9100:9100"
    restart: unless-stopped

  cadvisor:
    image: $CADVISOR_IMAGE
    container_name: discovery-ova-cadvisor
    environment:
      TZ: \${UTC_TZ}
    privileged: true
    devices:
      - /dev/kmsg:/dev/kmsg
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker:/var/lib/docker:ro
      - /dev/disk:/dev/disk:ro
    ports:
      - "127.0.0.1:8080:8080"
    restart: unless-stopped

  loki:
    image: $LOKI_IMAGE
    container_name: discovery-ova-loki
    environment:
      TZ: \${UTC_TZ}
    command: ["-config.file=/etc/loki/loki.yml"]
    volumes:
      - $CONFIG_DIR/loki/loki.yml:/etc/loki/loki.yml:ro
      - $DATA_DIR/loki:/loki
    ports:
      - "127.0.0.1:3100:3100"
    restart: unless-stopped

  alloy:
    image: $ALLOY_IMAGE
    container_name: discovery-ova-alloy
    environment:
      TZ: \${UTC_TZ}
    command: ["run", "--server.http.listen-addr=0.0.0.0:12345", "/etc/alloy/config.alloy"]
    volumes:
      - $CONFIG_DIR/alloy/config.alloy:/etc/alloy/config.alloy:ro
    ports:
      - "127.0.0.1:1514:1514"
      - "127.0.0.1:12345:12345"
    depends_on:
      - loki
    restart: unless-stopped

  grafana:
    image: $GRAFANA_IMAGE
    container_name: discovery-ova-grafana
    environment:
      TZ: \${TZ}
      GF_DATE_FORMATS_DEFAULT_TIMEZONE: \${TZ}
      GF_SECURITY_ADMIN_USER: \${GRAFANA_ADMIN_USER}
      GF_SECURITY_ADMIN_PASSWORD: \${GRAFANA_ADMIN_PASSWORD}
      GF_SECURITY_SECRET_KEY: \${GRAFANA_SECRET_KEY}
      GF_USERS_ALLOW_SIGN_UP: "false"
      GF_ANALYTICS_REPORTING_ENABLED: "false"
      GF_ANALYTICS_CHECK_FOR_UPDATES: "false"
    volumes:
      - $DATA_DIR/grafana:/var/lib/grafana
      - $CONFIG_DIR/grafana/provisioning:/etc/grafana/provisioning:ro
      - $CONFIG_DIR/grafana/dashboards:/var/lib/grafana/dashboards:ro
    ports:
      - "127.0.0.1:3001:3000"
    depends_on:
      - prometheus
      - loki
    restart: unless-stopped
EOF

  (cd "$COMPOSE_DIR" && docker compose config -q)
  log "Compose syntax validated. Pulling images."
  (cd "$COMPOSE_DIR" && docker compose pull)
  (cd "$COMPOSE_DIR" && docker compose up -d)

  log "Waiting for core HTTP endpoints."
  local url
  for url in http://127.0.0.1:8001 http://127.0.0.1:8002 http://127.0.0.1:8003 http://127.0.0.1:3000 http://127.0.0.1:3001 http://127.0.0.1:8085/guacamole/ http://127.0.0.1:9115/metrics; do
    for _ in {1..60}; do
      curl -fsS --max-time 2 "$url" >/dev/null 2>&1 && break
      sleep 3
    done
  done
  (cd "$COMPOSE_DIR" && docker compose ps) | tee -a "$LOG_FILE"
}
configure_syslog() {
  stage 4 "Centralized syslog through rsyslog, Alloy and Loki"
  backup_path /etc/rsyslog.conf
  backup_glob '/etc/rsyslog.d/*discovery-ova*'

  write_file /etc/rsyslog.d/20-discovery-ova-remote.conf 0644 root:root <<'EOF'
module(load="imudp")
module(load="imtcp")

# Preserve original hostname in the RFC5424 header and remote source IP in structured data.
template(name="DiscoveryOVARFC5424" type="string"
  string="<%pri%>1 %timereported:::date-rfc3339% %hostname% %app-name% %procid% %msgid% [discovery-ova source_ip=\"%fromhost-ip%\"] %msg%\n")

ruleset(name="discovery-ovaRemote") {
  action(
    type="omfwd"
    target="127.0.0.1"
    port="1514"
    protocol="tcp"
    TCP_Framing="octet-counted"
    template="DiscoveryOVARFC5424"
    action.resumeRetryCount="-1"
    queue.type="linkedList"
    queue.size="10000"
  )
}

input(type="imudp" port="514" ruleset="discovery-ovaRemote")
input(type="imtcp" port="514" ruleset="discovery-ovaRemote")
EOF
  rsyslogd -N1
  systemctl restart rsyslog
  ss -lun | grep -q ':514 ' || die "rsyslog UDP/514 did not start."
  ss -ltn | grep -q ':514 ' || die "rsyslog TCP/514 did not start."
  logger --udp --server 127.0.0.1 --port 514 -t discovery-ova-test "discovery-ova UDP syslog test $BUILD_STAMP"
  logger --tcp --server 127.0.0.1 --port 514 -t discovery-ova-test "discovery-ova TCP syslog test $BUILD_STAMP"
  log "rsyslog syntax valid and UDP/TCP 514 listeners are active."
}

make_tls_cert() {
  load_conf
  local ip cert key cfg
  ip="$(get_mgmt_ip "$MGMT_IF")"
  [[ -n "$ip" ]] || return 1
  cert="$ETC_ROOT/tls/discovery-ova.crt"
  key="$ETC_ROOT/tls/discovery-ova.key"
  cfg="$(mktemp)"
  install -d -m 0700 "$ETC_ROOT/tls"
  cat > "$cfg" <<EOF
[req]
distinguished_name=req_dn
x509_extensions=v3_req
prompt=no
[req_dn]
CN=$HOSTNAME_SHORT.local
[v3_req]
subjectAltName=@alt_names
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
[alt_names]
DNS.1=$HOSTNAME_SHORT.local
DNS.2=$HOSTNAME_SHORT
IP.1=$ip
EOF
  openssl req -x509 -nodes -newkey rsa:3072 -sha256 -days 825 \
    -keyout "$key.tmp" -out "$cert.tmp" -config "$cfg" >/dev/null 2>&1
  install -m 0600 "$key.tmp" "$key"
  install -m 0644 "$cert.tmp" "$cert"
  rm -f "$key.tmp" "$cert.tmp" "$cfg"
}

write_nginx_proxy_server() {
  local port="$1" upstream="$2" label="$3"
  cat <<EOF
server {
    listen $port ssl;
    listen [::]:$port ssl;
    server_name _;
    ssl_certificate $ETC_ROOT/tls/discovery-ova.crt;
    ssl_certificate_key $ETC_ROOT/tls/discovery-ova.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    auth_basic "Discovery-OVA $label";
    auth_basic_user_file /etc/nginx/.discovery-ova.htpasswd;
    location / {
        proxy_pass $upstream;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 300s;
    }
}
EOF
}

configure_portal_nginx() {
  stage 5 "HTTPS NOC portal and reverse proxies"
  load_conf
  make_tls_cert
  htpasswd -bcB /etc/nginx/.discovery-ova.htpasswd "$OPERATOR_USER" "$OPERATOR_PASSWORD" >/dev/null
  chmod 0640 /etc/nginx/.discovery-ova.htpasswd
  chown root:www-data /etc/nginx/.discovery-ova.htpasswd

  write_file "$PORTAL_DIR/index.html" 0644 root:root <<EOF
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Discovery-OVA NOC</title>
<style>
:root{color-scheme:dark;--bg:#08111b;--card:#101d2b;--line:#24384c;--text:#e9f2f9;--muted:#8fa8ba;--accent:#42c7e8;--tab:#0d1824}
*{box-sizing:border-box} body{margin:0;background:linear-gradient(145deg,#071019,#0b1724);font:15px system-ui,sans-serif;color:var(--text)}
main{max-width:1180px;margin:auto;padding:38px 24px 60px} h1{font-size:42px;margin:0}.sub{color:var(--muted);margin:8px 0 24px}
.tabs{display:flex;flex-wrap:wrap;gap:8px;margin:0 0 22px;padding-bottom:14px;border-bottom:1px solid var(--line)}
.tab{appearance:none;border:1px solid var(--line);background:var(--tab);color:var(--muted);border-radius:9px;padding:10px 15px;font-weight:650;cursor:pointer}
.tab:hover{border-color:var(--accent);color:var(--text)}.tab.active{background:#123042;border-color:var(--accent);color:var(--text)}
.tab-panel{display:none}.tab-panel.active{display:block}.tab-panel h2{margin:4px 0 14px;font-size:22px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:14px}
a.card{display:block;text-decoration:none;color:inherit;background:var(--card);border:1px solid var(--line);border-radius:14px;padding:20px;min-height:126px;transition:.15s}
a.card:hover{transform:translateY(-2px);border-color:var(--accent);box-shadow:0 8px 28px #0007}.card b{display:block;font-size:19px;margin-bottom:8px}.card span{color:var(--muted);line-height:1.45}.tag{display:inline-block;margin-top:12px;color:var(--accent);font-size:12px;letter-spacing:.08em;text-transform:uppercase}
footer{margin-top:34px;color:var(--muted);font-size:12px}
</style></head><body><main>
<h1>DISCOVERY-OVA</h1><div class="sub">Portable infrastructure discovery, remote monitoring, diagnostics and access appliance</div>
<nav class="tabs" aria-label="Tool categories">
<button class="tab active" data-tab="monitoring">Monitoring</button>
<button class="tab" data-tab="infrastructure">Infrastructure</button>
<button class="tab" data-tab="diagnostics">Diagnostics</button>
<button class="tab" data-tab="remote-access">Remote Access</button>
<button class="tab" data-tab="appliance">Appliance</button>
</nav>
<section class="tab-panel active" id="tab-monitoring"><h2>Monitoring</h2><div class="grid">
<a class="card app-port-link" href="#" data-port="8443" data-path="/" target="_blank" rel="noopener noreferrer"><b>LibreNMS</b><span>Network discovery, SNMP polling and alerting.</span><i class="tag">network monitor</i></a>
<a class="card app-port-link" href="#" data-port="8444" data-path="/smokeping/" target="_blank" rel="noopener noreferrer"><b>SmokePing</b><span>Remote latency and packet-loss history.</span><i class="tag">latency</i></a>
<a class="card app-port-link" href="#" data-port="8446" data-path="/" target="_blank" rel="noopener noreferrer"><b>ntopng</b><span>Passive traffic and flow analysis on the capture NIC.</span><i class="tag">traffic</i></a>
<a class="card app-port-link" href="#" data-port="8447" data-path="/" target="_blank" rel="noopener noreferrer"><b>Grafana</b><span>Metrics dashboards and centralized syslog views.</span><i class="tag">observability</i></a>
<a class="card" href="/remote/" target="_blank" rel="noopener noreferrer"><b>Remote Service Probes <small id="st-blackbox"></small></b><span>Manage ICMP, HTTP/HTTPS, TCP and DNS availability probes.</span><i class="tag">blackbox</i></a>
</div></section>
<section class="tab-panel" id="tab-infrastructure"><h2>Infrastructure</h2><div class="grid">
<a class="card app-port-link" href="#" data-port="8447" data-path="/d/discovery-remote/discovery-ova-remote-infrastructure" target="_blank" rel="noopener noreferrer"><b>Remote Infrastructure <small id="st-remote"></small></b><span>vSphere, Redfish server hardware and Pure FlashArray monitoring.</span><i class="tag">infrastructure</i></a>
</div></section>
<section class="tab-panel" id="tab-diagnostics"><h2>Diagnostics</h2><div class="grid">
<a class="card app-port-link" href="#" data-port="8445" data-path="/" target="_blank" rel="noopener noreferrer"><b>LibreSpeed</b><span>Browser-based throughput testing.</span><i class="tag">speed</i></a>
<a class="card" href="/scanner/" target="_blank" rel="noopener noreferrer"><b>Network Scanner</b><span>Nmap quick/deep scans with saved history and change tracking.</span><i class="tag">active scan</i></a>
<a class="card" href="/capture/" target="_blank" rel="noopener noreferrer"><b>Packet Capture</b><span>Bounded PCAP capture with validated BPF filters.</span><i class="tag">pcap</i></a>
<a class="card" href="/diagnostics/" target="_blank" rel="noopener noreferrer"><b>Network Diagnostics</b><span>iperf3 throughput tests and LLDP neighbor visibility.</span><i class="tag">diagnostics</i></a>
</div></section>
<section class="tab-panel" id="tab-remote-access"><h2>Remote Access</h2><div class="grid">
<a class="card" href="/guacamole/" target="_blank" rel="noopener noreferrer"><b>Guacamole <small id="st-guac"></small></b><span>Browser-based RDP, SSH and VNC access to remote systems.</span><i class="tag">remote access</i></a>
</div></section>
<section class="tab-panel" id="tab-appliance"><h2>Appliance</h2><div class="grid">
<a class="card" href="/network/" target="_blank" rel="noopener noreferrer"><b>Network Control</b><span>Management path, capture mode and rollback status.</span><i class="tag">control</i></a>
<a class="card" href="/status/" target="_blank" rel="noopener noreferrer"><b>Appliance Status</b><span>Interfaces, routes, services, containers and health.</span><i class="tag">status</i></a>
</div></section>
<footer>Discovery-OVA $VERSION · IP-first runtime; DNS/mDNS optional · Default timezone: $TIMEZONE</footer>
<script>
// Build port-isolated application links from the address actually used to open
// this portal. This avoids hard-coding .local or requiring external DNS.
document.querySelectorAll('.app-port-link').forEach(a=>{
 const u=new URL(window.location.href);
 u.port=a.dataset.port; u.pathname=a.dataset.path||'/'; u.search=''; u.hash='';
 a.href=u.toString();
});
document.querySelectorAll('.tab').forEach(btn=>btn.addEventListener('click',()=>{
 document.querySelectorAll('.tab').forEach(x=>x.classList.remove('active'));
 document.querySelectorAll('.tab-panel').forEach(x=>x.classList.remove('active'));
 btn.classList.add('active'); document.getElementById('tab-'+btn.dataset.tab).classList.add('active');
}));
fetch('/api/summary').then(r=>r.json()).then(s=>{
 const dot=(ok)=>ok?' · UP':' · DOWN';
 document.getElementById('st-guac').textContent=dot(s.guacamole_up);
 document.getElementById('st-blackbox').textContent=' · '+s.blackbox_targets+' targets';
 document.getElementById('st-remote').textContent=' · '+(s.vsphere?'vSphere ':'')+(s.redfish_targets?s.redfish_targets+' BMC ':'')+(s.pure_arrays?s.pure_arrays+' Pure':'');
}).catch(()=>{});
</script></main></body></html>
EOF

  backup_path /etc/nginx/sites-enabled/default
  rm -f /etc/nginx/sites-enabled/default
  cat > /etc/nginx/sites-available/discovery-ova <<EOF
map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;
    ssl_certificate $ETC_ROOT/tls/discovery-ova.crt;
    ssl_certificate_key $ETC_ROOT/tls/discovery-ova.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy no-referrer always;
    auth_basic "Discovery-OVA";
    auth_basic_user_file /etc/nginx/.discovery-ova.htpasswd;
    root $PORTAL_DIR;
    index index.html;
    # Serve the static portal normally. More-specific proxy locations below take precedence.
    location / { try_files \$uri \$uri/ /index.html; }
    location /scanner/ { proxy_pass http://127.0.0.1:8787; include proxy_params; proxy_read_timeout 920s; }
    location /network/ { proxy_pass http://127.0.0.1:8787; include proxy_params; }
    location /capture/ { proxy_pass http://127.0.0.1:8787; include proxy_params; proxy_read_timeout 650s; }
    location /captures/ { proxy_pass http://127.0.0.1:8787; include proxy_params; }
    location /diagnostics/ { proxy_pass http://127.0.0.1:8787; include proxy_params; proxy_read_timeout 90s; }
    location /remote/ { proxy_pass http://127.0.0.1:8787; include proxy_params; }
    location /api/ { proxy_pass http://127.0.0.1:8787; include proxy_params; }
    location /guacamole/ {
        proxy_pass http://127.0.0.1:8085;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_buffering off;
        proxy_read_timeout 3600s;
    }
    location /status/ { proxy_pass http://127.0.0.1:8787; include proxy_params; }
    location /health { proxy_pass http://127.0.0.1:8787; include proxy_params; }
}
$(write_nginx_proxy_server 8443 'http://127.0.0.1:8001' 'LibreNMS')
$(write_nginx_proxy_server 8444 'http://127.0.0.1:8002' 'SmokePing')
$(write_nginx_proxy_server 8445 'http://127.0.0.1:8003' 'LibreSpeed')
$(write_nginx_proxy_server 8446 'http://127.0.0.1:3000' 'ntopng')
$(write_nginx_proxy_server 8447 'http://127.0.0.1:3001' 'Grafana')
EOF
  ln -sfn /etc/nginx/sites-available/discovery-ova /etc/nginx/sites-enabled/discovery-ova
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
  [[ -r "$PORTAL_DIR/index.html" ]] || die "Portal index is not readable: $PORTAL_DIR/index.html"
  if ! runuser -u www-data -- test -r "$PORTAL_DIR/index.html"; then
    namei -l "$PORTAL_DIR/index.html" | tee -a "$LOG_FILE" || true
    die "Nginx user www-data cannot read the portal index. Check path permissions."
  fi
  namei -l "$PORTAL_DIR/index.html" | tee -a "$LOG_FILE" >/dev/null || true

  write_file /usr/local/sbin/discovery-ova-tls-refresh 0750 root:root <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/discovery-ova/discovery-ova.conf
active_if="$MGMT_IF"
ip="$(ip -4 -o addr show dev "$active_if" scope global 2>/dev/null | awk 'NR==1{split($4,a,"/");print a[1]}')"
if [[ -z "$ip" ]]; then
  active_if="$CAPTURE_IF"
  ip="$(ip -4 -o addr show dev "$active_if" scope global 2>/dev/null | awk 'NR==1{split($4,a,"/");print a[1]}')"
fi
[[ -n "$ip" ]] || exit 1
cert=/etc/discovery-ova/tls/discovery-ova.crt
if [[ -r "$cert" ]] && openssl x509 -in "$cert" -noout -text | grep -Fq "IP Address:$ip"; then exit 0; fi
cfg="$(mktemp)"
cat >"$cfg" <<CFG
[req]
distinguished_name=req_dn
x509_extensions=v3_req
prompt=no
[req_dn]
CN=$HOSTNAME_SHORT.local
[v3_req]
subjectAltName=@alt_names
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
[alt_names]
DNS.1=$HOSTNAME_SHORT.local
DNS.2=$HOSTNAME_SHORT
IP.1=$ip
CFG
openssl req -x509 -nodes -newkey rsa:3072 -sha256 -days 825 -keyout /etc/discovery-ova/tls/discovery-ova.key.new -out /etc/discovery-ova/tls/discovery-ova.crt.new -config "$cfg" >/dev/null 2>&1
install -m0600 /etc/discovery-ova/tls/discovery-ova.key.new /etc/discovery-ova/tls/discovery-ova.key
install -m0644 /etc/discovery-ova/tls/discovery-ova.crt.new /etc/discovery-ova/tls/discovery-ova.crt
rm -f /etc/discovery-ova/tls/*.new "$cfg"
nginx -t && systemctl reload nginx
EOF

  write_file /etc/systemd/system/discovery-ova-tls-refresh.service 0644 root:root <<'EOF'
[Unit]
Description=Refresh Discovery-OVA TLS certificate for current DHCP address
After=discovery-ova-network-boot-guard.service network-online.target
Requires=discovery-ova-network-boot-guard.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/discovery-ova-tls-refresh

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable discovery-ova-tls-refresh.service
  if ! curl -kfsS --max-time 8 -u "$OPERATOR_USER:$OPERATOR_PASSWORD" https://127.0.0.1/ >/dev/null; then
    log "Portal validation failed; collecting Nginx diagnostics."
    nginx -T >>"$LOG_FILE" 2>&1 || true
    ls -ld "$DISCOVERY_OVA_ROOT" "$PORTAL_DIR" "$PORTAL_DIR/index.html" | tee -a "$LOG_FILE" || true
    tail -n 80 /var/log/nginx/error.log | tee -a "$LOG_FILE" || true
    die "HTTPS portal validation failed. See $LOG_FILE and /var/log/nginx/error.log."
  fi
  log "HTTPS portal validated by loopback IP; no DNS/mDNS required."
}
write_control_app() {
  stage 6 "Scanner, network control, remote monitoring and packet-capture interfaces"
  write_file "$APP_DIR/discovery_ova_web.py" 0750 root:discovery-ova <<'PY'
#!/usr/bin/env python3
import datetime as dt
import html
import ipaddress
import json
import os
import re
import shlex
import signal
import sqlite3
import subprocess
import time
import xml.etree.ElementTree as ET
from pathlib import Path
from flask import Flask, Response, abort, redirect, render_template_string, request, send_file, url_for

APP = Flask(__name__)
CONF = {}
for line in Path('/etc/discovery-ova/discovery-ova.conf').read_text().splitlines():
    if '=' in line and not line.lstrip().startswith('#'):
        k, v = line.split('=', 1)
        CONF[k] = v.strip().strip("'").strip('"')
MGMT_IF = CONF['MGMT_IF']
CAPTURE_IF = CONF['CAPTURE_IF']
DATA = Path(CONF.get('DATA_DIR', '/opt/discovery-ova/data'))
SCAN_DB = DATA / 'scanner' / 'scanner.db'
CAP_DIR = DATA / 'captures'
RUN = Path('/run/discovery-ova')
PID_FILE = RUN / 'capture.pid'
META_FILE = RUN / 'capture.json'
PROM_CONFIG = Path('/opt/discovery-ova/config/prometheus')
BLACKBOX_TARGETS = PROM_CONFIG / 'blackbox-targets.json'
ETC = Path('/etc/discovery-ova')
CAP_DIR.mkdir(parents=True, exist_ok=True)
RUN.mkdir(parents=True, exist_ok=True)

BASE_STYLE = '''
<style>
:root{color-scheme:dark;--bg:#08111b;--card:#101d2b;--line:#24384c;--text:#e9f2f9;--muted:#91a9bb;--a:#42c7e8;--ok:#64d98b;--bad:#ff6b6b}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:14px system-ui,sans-serif}main{max-width:1100px;margin:auto;padding:28px 20px 60px}a{color:var(--a)}
h1{font-size:30px;margin:0 0 6px}.sub{color:var(--muted);margin-bottom:22px}.box{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px;margin:12px 0}
input,select,button{background:#0b1622;color:var(--text);border:1px solid #35516a;border-radius:7px;padding:9px 10px}button{cursor:pointer}button:hover{border-color:var(--a)}
table{width:100%;border-collapse:collapse}th,td{text-align:left;border-bottom:1px solid var(--line);padding:8px;vertical-align:top}th{color:var(--muted)}pre{white-space:pre-wrap;background:#071019;border:1px solid var(--line);padding:12px;border-radius:9px;overflow:auto}.ok{color:var(--ok)}.bad{color:var(--bad)}
.nav{display:flex;gap:12px;flex-wrap:wrap;margin:0 0 18px}.nav a{text-decoration:none}.row{display:flex;gap:9px;flex-wrap:wrap;align-items:center}.grow{flex:1;min-width:240px}.pill{display:inline-block;padding:3px 7px;border:1px solid var(--line);border-radius:999px;color:var(--muted)}
</style>'''

def page(title, body):
    return f'''<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>{html.escape(title)}</title>{BASE_STYLE}</head><body><main><h1>{html.escape(title)}</h1><div class="sub">Discovery-OVA network operations appliance</div><div class="nav"><a href="/">Portal</a><a href="/scanner/">Scanner</a><a href="/network/">Network</a><a href="/remote/">Remote</a><a href="/capture/">Capture</a><a href="/diagnostics/">Diagnostics</a><a href="/status/">Status</a></div>{body}</main></body></html>'''

def run(args, timeout=15, check=False):
    return subprocess.run(args, text=True, capture_output=True, timeout=timeout, check=check)

def db():
    con = sqlite3.connect(SCAN_DB)
    con.row_factory = sqlite3.Row
    con.execute('PRAGMA journal_mode=WAL')
    con.executescript('''
      CREATE TABLE IF NOT EXISTS scans(id INTEGER PRIMARY KEY, target TEXT NOT NULL, mode TEXT NOT NULL, started TEXT NOT NULL, finished TEXT, rc INTEGER, summary TEXT);
      CREATE TABLE IF NOT EXISTS hosts(id INTEGER PRIMARY KEY, scan_id INTEGER NOT NULL, address TEXT, mac TEXT, vendor TEXT, hostname TEXT, state TEXT, first_seen TEXT, last_seen TEXT);
      CREATE TABLE IF NOT EXISTS services(id INTEGER PRIMARY KEY, scan_id INTEGER NOT NULL, host TEXT, proto TEXT, port INTEGER, state TEXT, service TEXT, product TEXT, version TEXT);
      CREATE TABLE IF NOT EXISTS targets(target TEXT PRIMARY KEY, label TEXT, last_used TEXT);
      CREATE TABLE IF NOT EXISTS iperf_tests(
        id INTEGER PRIMARY KEY,
        target TEXT NOT NULL,
        protocol TEXT NOT NULL,
        reverse INTEGER NOT NULL DEFAULT 0,
        duration INTEGER NOT NULL,
        parallel INTEGER NOT NULL,
        bandwidth_mbps INTEGER,
        started TEXT NOT NULL,
        rc INTEGER,
        summary TEXT,
        result_json TEXT
      );
    ''')
    return con

def validate_target(value):
    value = value.strip()
    if len(value) > 253:
        raise ValueError('target too long')
    try:
        ipaddress.ip_network(value, strict=False)
        return value
    except ValueError:
        pass
    if not re.fullmatch(r'(?=.{1,253}$)([A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?', value):
        raise ValueError('target must be an IP, CIDR or DNS hostname')
    return value

def validate_host(value):
    value = value.strip()
    if not value or len(value) > 253 or '/' in value or any(c.isspace() for c in value):
        raise ValueError('host must be one IPv4 address or DNS hostname')
    try:
        ipaddress.IPv4Address(value)
        return value
    except ValueError:
        pass
    if not re.fullmatch(r'(?=.{1,253}$)([A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?', value):
        raise ValueError('host must be one IPv4 address or DNS hostname')
    return value

def active_management_ip():
    fallback = None
    for dev in (MGMT_IF, CAPTURE_IF):
        cp = run(['/usr/sbin/ip','-4','-o','addr','show','dev',dev,'scope','global'], timeout=5)
        fields = cp.stdout.split()
        if len(fields) < 4:
            continue
        address = fields[3].split('/')[0]
        if fallback is None:
            fallback = (dev, address)
        route = run(['/usr/sbin/ip','-4','route','show','default','dev',dev], timeout=5)
        if route.stdout.strip():
            return dev, address
    return fallback or ('', '')

def human_rate(bits):
    try:
        value = float(bits)
    except Exception:
        return 'n/a'
    units = [('Gbps',1_000_000_000),('Mbps',1_000_000),('Kbps',1_000),('bps',1)]
    for name, scale in units:
        if value >= scale or scale == 1:
            return f'{value/scale:.2f} {name}'
    return f'{value:.0f} bps'

def summarize_iperf(payload):
    try:
        end = payload.get('end', {})
        recv = end.get('sum_received') or {}
        sent = end.get('sum_sent') or {}
        aggregate = end.get('sum') or {}
        rate = recv.get('bits_per_second') or sent.get('bits_per_second') or aggregate.get('bits_per_second')
        parts = [human_rate(rate)]
        if sent.get('retransmits') is not None:
            parts.append(f'{sent.get("retransmits")} retransmits')
        udpstats = aggregate if aggregate.get('lost_percent') is not None else recv
        if udpstats.get('lost_percent') is not None:
            parts.append(f'{float(udpstats.get("lost_percent")):.2f}% loss')
        if udpstats.get('jitter_ms') is not None:
            parts.append(f'{float(udpstats.get("jitter_ms")):.3f} ms jitter')
        return ' · '.join(parts)
    except Exception:
        return 'completed'

def parse_nmap(xml_text, scan_id, target):
    root = ET.fromstring(xml_text)
    now = dt.datetime.now(dt.timezone.utc).isoformat()
    rows = []
    services = []
    con = db()
    for h in root.findall('host'):
        state = (h.find('status').attrib.get('state') if h.find('status') is not None else 'unknown')
        ipv4 = mac = vendor = ''
        for a in h.findall('address'):
            if a.attrib.get('addrtype') == 'ipv4': ipv4 = a.attrib.get('addr','')
            if a.attrib.get('addrtype') == 'mac':
                mac = a.attrib.get('addr',''); vendor = a.attrib.get('vendor','')
        hn = ''
        hnel = h.find('hostnames/hostname')
        if hnel is not None: hn = hnel.attrib.get('name','')
        identity = ipv4 or target
        old = con.execute('SELECT MIN(first_seen) AS first_seen FROM hosts WHERE address=?', (identity,)).fetchone()['first_seen']
        first_seen = old or now
        con.execute('INSERT INTO hosts(scan_id,address,mac,vendor,hostname,state,first_seen,last_seen) VALUES(?,?,?,?,?,?,?,?)',
                    (scan_id,identity,mac,vendor,hn,state,first_seen,now))
        rows.append((identity, mac, vendor, hn, state, first_seen, now))
        for p in h.findall('ports/port'):
            st = p.find('state')
            sv = p.find('service')
            statep = st.attrib.get('state','') if st is not None else ''
            proto = p.attrib.get('protocol','')
            port = int(p.attrib.get('portid','0'))
            name = sv.attrib.get('name','') if sv is not None else ''
            product = sv.attrib.get('product','') if sv is not None else ''
            version = sv.attrib.get('version','') if sv is not None else ''
            con.execute('INSERT INTO services(scan_id,host,proto,port,state,service,product,version) VALUES(?,?,?,?,?,?,?,?)',
                        (scan_id,identity,proto,port,statep,name,product,version))
            if statep == 'open': services.append((identity,proto,port,name,product,version))
    con.commit(); con.close()
    return rows, services

def changes_for(scan_id, target):
    con = db()
    prev = con.execute('SELECT id FROM scans WHERE target=? AND id<? AND rc=0 ORDER BY id DESC LIMIT 1',(target,scan_id)).fetchone()
    if not prev:
        con.close(); return [], []
    curset = {(r['host'],r['proto'],r['port'],r['service']) for r in con.execute('SELECT host,proto,port,service FROM services WHERE scan_id=? AND state="open"',(scan_id,))}
    oldset = {(r['host'],r['proto'],r['port'],r['service']) for r in con.execute('SELECT host,proto,port,service FROM services WHERE scan_id=? AND state="open"',(prev['id'],))}
    con.close()
    return sorted(curset-oldset), sorted(oldset-curset)

@APP.get('/health')
def health(): return {'status':'ok','capture_if':CAPTURE_IF,'mgmt_if':MGMT_IF}

@APP.route('/scanner/', methods=['GET','POST'])
def scanner():
    message = ''
    if request.method == 'POST':
        try:
            target = validate_target(request.form.get('target',''))
            mode = request.form.get('mode','quick')
            if mode not in ('quick','deep'): raise ValueError('invalid mode')
            con = db()
            started = dt.datetime.now(dt.timezone.utc).isoformat()
            sid = con.execute('INSERT INTO scans(target,mode,started) VALUES(?,?,?)',(target,mode,started)).lastrowid
            if request.form.get('save') == '1':
                con.execute('INSERT INTO targets(target,label,last_used) VALUES(?,?,?) ON CONFLICT(target) DO UPDATE SET last_used=excluded.last_used',(target,target,started))
            con.commit(); con.close()
            args = ['/usr/bin/nmap','-oX','-','-n','--reason']
            if mode == 'quick':
                args += ['-sS','-sV','--version-light','-T4','-F',target]
                timeout = 180
            else:
                args += ['-sS','-sV','-O','--traceroute','-T4','-p-',target]
                timeout = 900
            cp = run(args, timeout=timeout)
            summary = (cp.stderr or '')[-4000:]
            if cp.returncode == 0:
                parse_nmap(cp.stdout, sid, target)
            con = db(); con.execute('UPDATE scans SET finished=?,rc=?,summary=? WHERE id=?',(dt.datetime.now(dt.timezone.utc).isoformat(),cp.returncode,summary,sid)); con.commit(); con.close()
            return redirect(f'/scanner/?scan={sid}')
        except Exception as e:
            message = f'<div class="box bad">{html.escape(str(e))}</div>'
    con = db()
    saved = list(con.execute('SELECT target FROM targets ORDER BY last_used DESC LIMIT 30'))
    history = list(con.execute('SELECT id,target,mode,started,rc FROM scans ORDER BY id DESC LIMIT 30'))
    sid = request.args.get('scan','')
    detail = ''
    if sid.isdigit():
        scanrow = con.execute('SELECT * FROM scans WHERE id=?',(int(sid),)).fetchone()
        if scanrow:
            hosts = list(con.execute('SELECT * FROM hosts WHERE scan_id=?',(int(sid),)))
            svcs = list(con.execute('SELECT * FROM services WHERE scan_id=? AND state="open" ORDER BY host,port',(int(sid),)))
            added, removed = changes_for(int(sid), scanrow['target'])
            hrows = ''.join(f'<tr><td>{html.escape(r["address"] or "")}</td><td>{html.escape(r["hostname"] or "")}</td><td>{html.escape(r["mac"] or "")}</td><td>{html.escape(r["vendor"] or "")}</td><td>{html.escape(r["state"] or "")}</td><td>{html.escape(r["first_seen"] or "")}</td><td>{html.escape(r["last_seen"] or "")}</td></tr>' for r in hosts)
            srows = ''.join(f'<tr><td>{html.escape(r["host"] or "")}</td><td>{r["port"]}/{html.escape(r["proto"] or "")}</td><td>{html.escape(r["service"] or "")}</td><td>{html.escape((r["product"] or "")+" "+(r["version"] or ""))}</td></tr>' for r in svcs)
            ach = '<br>'.join(html.escape(str(x)) for x in added) or 'None'
            rch = '<br>'.join(html.escape(str(x)) for x in removed) or 'None'
            detail = f'<div class="box"><h3>Scan #{sid}: {html.escape(scanrow["target"])}</h3><div class="row"><div class="grow"><b>Added open services</b><br>{ach}</div><div class="grow"><b>Removed open services</b><br>{rch}</div></div><h3>Hosts</h3><table><tr><th>Address</th><th>Hostname</th><th>MAC</th><th>Vendor</th><th>State</th><th>First seen</th><th>Last seen</th></tr>{hrows}</table><h3>Open services</h3><table><tr><th>Host</th><th>Port</th><th>Service</th><th>Product</th></tr>{srows}</table></div>'
    con.close()
    opts = ''.join(f'<option value="{html.escape(r[0])}">{html.escape(r[0])}</option>' for r in saved)
    hist = ''.join(f'<tr><td><a href="/scanner/?scan={r["id"]}">#{r["id"]}</a></td><td>{html.escape(r["target"])}</td><td>{html.escape(r["mode"])}</td><td>{html.escape(r["started"])}</td><td>{r["rc"]}</td></tr>' for r in history)
    body = f'''{message}<div class="box"><form method="post"><div class="row"><input class="grow" name="target" list="targets" placeholder="IP, CIDR or hostname" required><datalist id="targets">{opts}</datalist><select name="mode"><option value="quick">Quick</option><option value="deep">Deep</option></select><label><input type="checkbox" name="save" value="1"> save target</label><button>Run scan</button></div></form></div>{detail}<div class="box"><h3>Recent scans</h3><table><tr><th>ID</th><th>Target</th><th>Mode</th><th>Started</th><th>RC</th></tr>{hist}</table></div>'''
    return page('Network Scanner', body)

@APP.route('/network/', methods=['GET','POST'])
def network():
    msg=''
    if request.method == 'POST':
        action=request.form.get('action','')
        if action not in ('capture','confirm','wired','rollback'): abort(400)
        cp=run(['/usr/local/sbin/discovery-ova-network',action], timeout=45)
        cls='ok' if cp.returncode==0 else 'bad'
        msg=f'<div class="box {cls}"><pre>{html.escape(cp.stdout+cp.stderr)}</pre></div>'
    status=run(['/usr/local/sbin/discovery-ova-network','status'],timeout=10)
    body=f'''{msg}<div class="box"><div class="row"><form method="post"><button name="action" value="capture">Enter capture</button></form><form method="post"><button name="action" value="confirm">Confirm capture</button></form><form method="post"><button name="action" value="wired">Test wired DHCP</button></form><form method="post"><button name="action" value="rollback">Rollback</button></form></div></div><div class="box"><pre>{html.escape(status.stdout+status.stderr)}</pre></div>'''
    return page('Network Control',body)


def capture_running():
    if not PID_FILE.exists(): return False, None
    try: pid=int(PID_FILE.read_text().strip())
    except Exception: return False,None
    try: os.kill(pid,0); return True,pid
    except OSError:
        PID_FILE.unlink(missing_ok=True); META_FILE.unlink(missing_ok=True); return False,None

def valid_bpf(expr):
    expr=expr.strip()
    if not expr: return []
    if len(expr)>300 or any(c in expr for c in '\n\r\x00'): raise ValueError('invalid BPF length/content')
    tokens=shlex.split(expr)
    cp=run(['/usr/bin/tcpdump','-ddd']+tokens,timeout=5)
    if cp.returncode != 0: raise ValueError('BPF did not compile: '+cp.stderr.strip())
    return tokens

@APP.route('/capture/',methods=['GET','POST'])
def capture():
    msg=''; running,pid=capture_running()
    if request.method=='POST':
        action=request.form.get('action','')
        try:
            if action=='start':
                if running: raise ValueError('a capture is already running')
                filt=valid_bpf(request.form.get('filter',''))
                duration=max(5,min(int(request.form.get('duration','60')),600))
                max_mb=max(1,min(int(request.form.get('max_mb','128')),512))
                stamp=dt.datetime.now().strftime('%Y%m%d-%H%M%S')
                out=CAP_DIR/f'discovery-ova-{stamp}.pcap'
                cmd=['/usr/bin/prlimit',f'--fsize={max_mb*1024*1024}','--','/usr/bin/timeout','--signal=INT',str(duration),'/usr/bin/tcpdump','-U','-i',CAPTURE_IF,'-s','0','-nn','-w',str(out)]+filt
                p=subprocess.Popen(cmd,stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)
                PID_FILE.write_text(str(p.pid)); META_FILE.write_text(json.dumps({'file':out.name,'started':time.time(),'duration':duration,'max_mb':max_mb,'filter':request.form.get('filter','')}))
                msg=f'<div class="box ok">Capture started: {html.escape(out.name)}</div>'
            elif action=='stop':
                if running and pid:
                    os.killpg(pid,signal.SIGINT)
                    time.sleep(1)
                PID_FILE.unlink(missing_ok=True); META_FILE.unlink(missing_ok=True)
                msg='<div class="box ok">Capture stopped.</div>'
            elif action=='delete':
                name=Path(request.form.get('name','')).name
                if not name.endswith('.pcap'): raise ValueError('invalid filename')
                (CAP_DIR/name).unlink(missing_ok=True)
                msg='<div class="box ok">Capture deleted.</div>'
            else: raise ValueError('invalid action')
        except Exception as e: msg=f'<div class="box bad">{html.escape(str(e))}</div>'
        running,pid=capture_running()
    meta=''
    if running and META_FILE.exists():
        try: meta=html.escape(META_FILE.read_text())
        except Exception: pass
    files=sorted(CAP_DIR.glob('*.pcap'),key=lambda p:p.stat().st_mtime,reverse=True)[:50]
    rows=''.join(f'<tr><td><a href="/captures/{html.escape(p.name)}">{html.escape(p.name)}</a></td><td>{p.stat().st_size/1024/1024:.1f} MB</td><td><form method="post"><input type="hidden" name="name" value="{html.escape(p.name)}"><button name="action" value="delete">Delete</button></form></td></tr>' for p in files)
    state=f'<span class="pill">running pid {pid}</span>' if running else '<span class="pill">idle</span>'
    body=f'''{msg}<div class="box">{state}<pre>{meta}</pre><form method="post"><div class="row"><input class="grow" name="filter" placeholder="BPF filter, e.g. host 10.0.0.10 and port 443"><input type="number" name="duration" value="60" min="5" max="600"><input type="number" name="max_mb" value="128" min="1" max="512"><button name="action" value="start">Start</button><button name="action" value="stop">Stop</button></div></form></div><div class="box"><table><tr><th>File</th><th>Size</th><th></th></tr>{rows}</table></div>'''
    return page('Packet Capture',body)

@APP.get('/captures/<name>')
def captures(name):
    safe=Path(name).name
    if safe!=name or not safe.endswith('.pcap'): abort(404)
    p=CAP_DIR/safe
    if not p.is_file(): abort(404)
    return send_file(p,as_attachment=True,download_name=safe)

@APP.route('/diagnostics/', methods=['GET','POST'])
def diagnostics():
    msg = ''
    latest = ''
    if request.method == 'POST':
        action = request.form.get('action','')
        try:
            if action == 'iperf_client':
                target = validate_host(request.form.get('target',''))
                protocol = request.form.get('protocol','tcp')
                if protocol not in ('tcp','udp'):
                    raise ValueError('invalid protocol')
                duration = max(1, min(int(request.form.get('duration','10')), 60))
                parallel = max(1, min(int(request.form.get('parallel','1')), 8))
                reverse = 1 if request.form.get('reverse') == '1' else 0
                bandwidth = None
                if protocol == 'udp':
                    bandwidth = max(1, min(int(request.form.get('bandwidth_mbps','100')), 100000))
                dev, bind_ip = active_management_ip()
                if not bind_ip:
                    raise ValueError('no usable management IPv4 address is present')
                args = ['/usr/bin/iperf3','-4','--client',target,'--json','--time',str(duration),'--parallel',str(parallel),'--bind',bind_ip]
                if reverse:
                    args.append('--reverse')
                if protocol == 'udp':
                    args += ['--udp','--bitrate',f'{bandwidth}M']
                started = dt.datetime.now(dt.timezone.utc).isoformat()
                cp = run(args, timeout=duration+20)
                try:
                    payload = json.loads(cp.stdout or '{}')
                except Exception:
                    payload = {'error': cp.stderr or cp.stdout or 'iperf3 returned no JSON'}
                summary = str(summarize_iperf(payload) if cp.returncode == 0 else (payload.get('error') or cp.stderr or 'iperf3 failed'))
                con = db()
                con.execute('INSERT INTO iperf_tests(target,protocol,reverse,duration,parallel,bandwidth_mbps,started,rc,summary,result_json) VALUES(?,?,?,?,?,?,?,?,?,?)',
                            (target,protocol,reverse,duration,parallel,bandwidth,started,cp.returncode,str(summary)[:2000],json.dumps(payload)))
                con.commit(); con.close()
                cls = 'ok' if cp.returncode == 0 else 'bad'
                latest = f'<div class="box {cls}"><h3>Latest iperf3 result</h3><p><b>{html.escape(summary)}</b> via {html.escape(dev)} ({html.escape(bind_ip)})</p><pre>{html.escape(json.dumps(payload,indent=2)[:30000])}</pre></div>'
            elif action == 'server_start':
                cp = run(['/usr/bin/systemctl','restart','discovery-ova-iperf3-server.service'],timeout=10)
                if cp.returncode != 0:
                    raise ValueError(cp.stderr or cp.stdout or 'could not start iperf3 server')
                msg = '<div class="box ok">One-shot iperf3 server started on the active management IPv4 address, TCP/UDP port 5201. It stops after one client or 15 minutes.</div>'
            elif action == 'server_stop':
                cp = run(['/usr/bin/systemctl','stop','discovery-ova-iperf3-server.service'],timeout=10)
                if cp.returncode != 0:
                    raise ValueError(cp.stderr or cp.stdout or 'could not stop iperf3 server')
                msg = '<div class="box ok">iperf3 server stopped.</div>'
            else:
                raise ValueError('invalid diagnostics action')
        except Exception as e:
            msg = f'<div class="box bad">{html.escape(str(e))}</div>'

    server_active = run(['/usr/bin/systemctl','is-active','discovery-ova-iperf3-server.service'],timeout=5)
    server_state = 'active — waiting for one client' if server_active.returncode == 0 else 'inactive'
    try:
        lldp = run(['/usr/sbin/lldpctl'],timeout=10)
        lldp_text = (lldp.stdout + lldp.stderr).strip() or 'No LLDP neighbors currently visible.'
    except Exception as e:
        lldp_text = str(e)

    con = db()
    recent = list(con.execute('SELECT id,target,protocol,reverse,duration,parallel,bandwidth_mbps,started,rc,summary FROM iperf_tests ORDER BY id DESC LIMIT 20'))
    con.close()
    rows = ''.join(
        f'<tr><td>#{r["id"]}</td><td>{html.escape(r["target"])}</td><td>{html.escape(r["protocol"].upper())}{" reverse" if r["reverse"] else ""}</td>'
        f'<td>{r["duration"]}s / P{r["parallel"]}</td><td>{html.escape(r["started"])}</td><td>{r["rc"]}</td><td>{html.escape(r["summary"] or "")}</td></tr>'
        for r in recent
    )
    body = f'''{msg}{latest}
<div class="box">
  <h3>iperf3 client</h3>
  <form method="post"><input type="hidden" name="action" value="iperf_client">
    <div class="row">
      <input class="grow" name="target" placeholder="iperf3 server IP or hostname" required>
      <select name="protocol"><option value="tcp">TCP</option><option value="udp">UDP</option></select>
      <label>seconds <input type="number" name="duration" value="10" min="1" max="60" style="width:80px"></label>
      <label>streams <input type="number" name="parallel" value="1" min="1" max="8" style="width:70px"></label>
      <label>UDP Mbps <input type="number" name="bandwidth_mbps" value="100" min="1" max="100000" style="width:100px"></label>
      <label><input type="checkbox" name="reverse" value="1"> reverse</label>
      <button>Run throughput test</button>
    </div>
  </form>
</div>
<div class="box">
  <h3>Temporary iperf3 server</h3>
  <p>State: <span class="pill">{html.escape(server_state)}</span>. The server binds only to the active Discovery-OVA management IPv4 address and is one-shot.</p>
  <div class="row">
    <form method="post"><button name="action" value="server_start">Start server</button></form>
    <form method="post"><button name="action" value="server_stop">Stop server</button></form>
  </div>
</div>
<div class="box">
  <h3>LLDP neighbors</h3>
  <pre>{html.escape(lldp_text)}</pre>
  <p class="sub">lldpd is receive-only on the management and capture vNICs. VMware/vSphere may not expose upstream physical-switch LLDP frames to a guest; when LLDP frames are delivered to either vNIC, they appear here.</p>
</div>
<div class="box"><h3>Recent iperf3 tests</h3><table><tr><th>ID</th><th>Target</th><th>Mode</th><th>Run</th><th>Started</th><th>RC</th><th>Summary</th></tr>{rows}</table></div>'''
    return page('Network Diagnostics', body)


def validate_probe_target(module, value):
    value=value.strip()
    if not value or len(value)>500 or any(c in value for c in '\r\n\x00'):
        raise ValueError('invalid probe target')
    if module in ('http_2xx','https_insecure'):
        from urllib.parse import urlparse
        u=urlparse(value)
        if u.scheme not in ('http','https') or not u.hostname:
            raise ValueError('HTTP probes require an http:// or https:// URL')
        return value
    if module=='tcp_connect':
        if not re.fullmatch(r'[A-Za-z0-9._:-]+:[0-9]{1,5}',value):
            raise ValueError('TCP target must be hostname:port or IPv4:port')
        port=int(value.rsplit(':',1)[1])
        if not (1 <= port <= 65535): raise ValueError('invalid TCP port')
        return value
    return validate_host(value)

def read_json(path, default):
    try: return json.loads(Path(path).read_text())
    except Exception: return default

def atomic_json(path, obj):
    path=Path(path); tmp=path.with_suffix(path.suffix+'.tmp')
    tmp.write_text(json.dumps(obj,indent=2)+'\n'); os.chmod(tmp,0o640); os.replace(tmp,path)

def container_running(name):
    cp=run(['/usr/bin/docker','inspect','-f','{{.State.Running}}',name],timeout=5)
    return cp.returncode==0 and cp.stdout.strip()=='true'

@APP.route('/remote/', methods=['GET','POST'])
def remote_monitoring():
    msg=''
    modules={'icmp':'ICMP','http_2xx':'HTTP/HTTPS 2xx','https_insecure':'HTTPS (allow self-signed)','tcp_connect':'TCP connect','dns_udp':'DNS server'}
    targets=read_json(BLACKBOX_TARGETS,[])
    if request.method=='POST':
        action=request.form.get('action','')
        try:
            if action=='add_probe':
                module=request.form.get('module','icmp')
                if module not in modules: raise ValueError('invalid probe module')
                target=validate_probe_target(module,request.form.get('target',''))
                name=request.form.get('name','').strip()[:80] or target
                entry={'targets':[target],'labels':{'module':module,'name':name}}
                targets=[x for x in targets if not (x.get('targets')==[target] and x.get('labels',{}).get('module')==module)]
                targets.append(entry); atomic_json(BLACKBOX_TARGETS,targets)
                msg='<div class="box ok">Probe saved. Prometheus file discovery will pick it up automatically.</div>'
            elif action=='delete_probe':
                idx=int(request.form.get('index','-1'))
                if not (0<=idx<len(targets)): raise ValueError('invalid probe index')
                targets.pop(idx); atomic_json(BLACKBOX_TARGETS,targets)
                msg='<div class="box ok">Probe removed.</div>'
            else: raise ValueError('invalid action')
        except Exception as e:
            msg=f'<div class="box bad">{html.escape(str(e))}</div>'
    rows=''
    for i,x in enumerate(targets):
        t=(x.get('targets') or [''])[0]; lab=x.get('labels') or {}; mod=lab.get('module','')
        rows += f'<tr><td>{html.escape(lab.get("name",t))}</td><td>{html.escape(t)}</td><td>{html.escape(modules.get(mod,mod))}</td><td><form method="post"><input type="hidden" name="index" value="{i}"><button name="action" value="delete_probe">Delete</button></form></td></tr>'
    vs=read_json(ETC/'vsphere.json',{'enabled':False}); rf=read_json(ETC/'redfish.json',{'enabled':False,'targets':[]}); pure=read_json(ETC/'pure-monitoring.json',{'enabled':False,'arrays':[]})
    opts=''.join(f'<option value="{html.escape(k)}">{html.escape(v)}</option>' for k,v in modules.items())
    body=f'''{msg}<div class="box"><h3>Remote service probes</h3><form method="post"><input type="hidden" name="action" value="add_probe"><div class="row"><input class="grow" name="name" placeholder="Friendly name"><input class="grow" name="target" placeholder="IP, URL, hostname:port" required><select name="module">{opts}</select><button>Add probe</button></div></form><table><tr><th>Name</th><th>Target</th><th>Probe</th><th></th></tr>{rows}</table></div>
<div class="box"><h3>Remote infrastructure collectors</h3><table>
<tr><td>VMware vSphere</td><td>{'configured' if vs.get('enabled') else 'disabled'}</td><td>{html.escape(str(vs.get('url','')))}</td></tr>
<tr><td>Redfish server hardware</td><td>{'configured' if rf.get('enabled') else 'disabled'}</td><td>{len(rf.get('targets',[]))} BMC target(s)</td></tr>
<tr><td>Pure FlashArray</td><td>{'configured' if pure.get('enabled') else 'disabled'}</td><td>{len(pure.get('arrays',[]))} array(s)</td></tr></table>
<p class="sub">Configure or rotate infrastructure credentials at the appliance console with <code>sudo discovery-ova-installer remote</code>. Secrets are intentionally not accepted by this web page.</p><p><a id="infra-grafana" href="#" target="_blank" rel="noopener noreferrer">Open the Remote Infrastructure Grafana dashboard</a></p>
<script>
(()=>{{const a=document.getElementById('infra-grafana');const u=new URL(window.location.href);u.port='8447';u.pathname='/d/discovery-remote/discovery-ova-remote-infrastructure';u.search='';u.hash='';a.href=u.toString();}})();
</script></div>'''
    return page('Remote Monitoring',body)

@APP.get('/api/summary')
def api_summary():
    targets=read_json(BLACKBOX_TARGETS,[]); vs=read_json(ETC/'vsphere.json',{}); rf=read_json(ETC/'redfish.json',{}); pure=read_json(ETC/'pure-monitoring.json',{})
    return {
      'guacamole_up':container_running('discovery-ova-guacamole'),
      'blackbox_up':container_running('discovery-ova-blackbox-exporter'),
      'blackbox_targets':len(targets),
      'vsphere':bool(vs.get('enabled')),
      'redfish_targets':len(rf.get('targets',[])) if rf.get('enabled') else 0,
      'pure_arrays':len(pure.get('arrays',[])) if pure.get('enabled') else 0
    }

@APP.get('/status/')
def status():
    sections=[]
    cmds=[
      ('Addresses',['/usr/sbin/ip','-br','-4','addr']),
      ('Routes',['/usr/sbin/ip','-4','route']),
      ('Links',['/usr/sbin/ip','-details','link','show']),
      ('NetworkManager',['/usr/bin/nmcli','-f','DEVICE,TYPE,STATE,CONNECTION','device']),
      ('Discovery-OVA network',['/usr/local/sbin/discovery-ova-network','status']),
      ('LLDP neighbors',['/usr/sbin/lldpctl']),
      ('iperf3 server',['/usr/bin/systemctl','status','discovery-ova-iperf3-server.service','--no-pager']),
      ('Systemd failed',['/usr/bin/systemctl','--failed','--no-pager']),
      ('Containers',['/usr/bin/docker','compose','-f','/opt/discovery-ova/compose/compose.yml','--env-file','/opt/discovery-ova/compose/.env','ps']),
    ]
    for title,args in cmds:
        try: cp=run(args,timeout=15); text=cp.stdout+cp.stderr
        except Exception as e: text=str(e)
        sections.append(f'<div class="box"><h3>{html.escape(title)}</h3><pre>{html.escape(text)}</pre></div>')
    return page('Appliance Status',''.join(sections))

if __name__=='__main__': APP.run('127.0.0.1',8787)
PY

  write_file /etc/systemd/system/discovery-ova-web.service 0644 root:root <<EOF
[Unit]
Description=Discovery-OVA local control and scanner web service
After=network-online.target NetworkManager.service docker.service
Wants=network-online.target

[Service]
Type=simple
User=root
Group=discovery-ova
WorkingDirectory=$APP_DIR
ExecStart=/usr/bin/gunicorn --workers 2 --threads 2 --timeout 930 --bind 127.0.0.1:8787 discovery_ova_web:APP
Restart=on-failure
RestartSec=3
UMask=0027
NoNewPrivileges=true
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_DAC_OVERRIDE CAP_KILL
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
ReadWritePaths=$DATA_DIR/scanner $DATA_DIR/captures $RUN_ROOT $CONFIG_DIR/prometheus

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now discovery-ova-web.service
  sleep 2
  curl -fsS http://127.0.0.1:8787/health | jq . | tee -a "$LOG_FILE"
}
configure_metrics() {
  stage 7 "Custom appliance metrics and Grafana support"
  write_file /usr/local/sbin/discovery-ova-field-metrics 0750 root:root <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/discovery-ova/discovery-ova.conf
source /usr/local/libexec/discovery-ova-network-common
OUT=/var/lib/discovery-ova/textfile_collector/discovery-ova.prom
TMP="${OUT}.tmp.$$"
esc(){ printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
active_mgmt_if="$MGMT_IF"
mgmt_ip="$(discovery_global_ipv4 "$active_mgmt_if")"
mgmt_gw="$(discovery_default_gateway "$active_mgmt_if")"
mgmt_up=0
if discovery_local_management_ok "$active_mgmt_if"; then
  mgmt_up=1
else
  active_mgmt_if="$CAPTURE_IF"
  mgmt_ip="$(discovery_global_ipv4 "$active_mgmt_if")"
  mgmt_gw="$(discovery_default_gateway "$active_mgmt_if")"
  discovery_local_management_ok "$active_mgmt_if" && mgmt_up=1 || true
fi
cap_profile="$(nmcli -t -f GENERAL.CONNECTION dev show "$CAPTURE_IF" 2>/dev/null | cut -d: -f2- || true)"
cap_mode=0; wired_mode=0
[[ "$cap_profile" == "discovery-ova-capture" ]] && cap_mode=1
[[ "$cap_profile" == "discovery-ova-wired" ]] && wired_mode=1
promisc=0; ip -details link show "$CAPTURE_IF" 2>/dev/null | grep -qw PROMISC && promisc=1
carrier="$(cat "/sys/class/net/$CAPTURE_IF/carrier" 2>/dev/null || echo 0)"
rollback=0; systemctl is-active --quiet discovery-ova-network-rollback.timer && rollback=1 || true
rs=0; systemctl is-active --quiet rsyslog && rs=1 || true
lldpd_up=0; systemctl is-active --quiet lldpd && lldpd_up=1 || true
iperf_server=0; systemctl is-active --quiet discovery-ova-iperf3-server.service && iperf_server=1 || true
udp=0; ss -lunH | grep -Eq '(^|[[:space:]])[^ ]*:514[[:space:]]' && udp=1 || true
tcp=0; ss -ltnH | grep -Eq '(^|[[:space:]])[^ ]*:514[[:space:]]' && tcp=1 || true
capture_active=0
[[ -r /run/discovery-ova/capture.pid ]] && kill -0 "$(cat /run/discovery-ova/capture.pid)" 2>/dev/null && capture_active=1 || true
guacamole_up=0; docker inspect -f '{{.State.Running}}' discovery-ova-guacamole 2>/dev/null | grep -qx true && guacamole_up=1 || true
blackbox_up=0; docker inspect -f '{{.State.Running}}' discovery-ova-blackbox-exporter 2>/dev/null | grep -qx true && blackbox_up=1 || true
blackbox_targets="$(jq 'length' /opt/discovery-ova/config/prometheus/blackbox-targets.json 2>/dev/null || echo 0)"
vsphere_configured=0; [[ "$(jq -r '.enabled // false' /etc/discovery-ova/vsphere.json 2>/dev/null || echo false)" == true ]] && vsphere_configured=1 || true
redfish_targets="$(jq 'if .enabled then (.targets|length) else 0 end' /etc/discovery-ova/redfish.json 2>/dev/null || echo 0)"
pure_arrays="$(jq 'if .enabled then (.arrays|length) else 0 end' /etc/discovery-ova/pure-monitoring.json 2>/dev/null || echo 0)"
backup_ts=0; backup_ok=0
if [[ -r /var/lib/discovery-ova/backup.status ]]; then
  backup_ts="$(awk -F= '$1=="timestamp"{print $2}' /var/lib/discovery-ova/backup.status | tail -1)"
  backup_ok="$(awk -F= '$1=="ok"{print $2}' /var/lib/discovery-ova/backup.status | tail -1)"
fi
[[ "$backup_ts" =~ ^[0-9]+$ ]] || backup_ts=0
[[ "$backup_ok" =~ ^[01]$ ]] || backup_ok=0
cat >"$TMP" <<METRICS
# HELP discovery_ova_management_up Management path validation without requiring gateway ICMP.
# TYPE discovery_ova_management_up gauge
discovery_ova_management_up{interface="$(esc "$active_mgmt_if")",ipv4="$(esc "$mgmt_ip")"} $mgmt_up
# HELP discovery_ova_capture_mode Capture interface is using the addressless capture profile.
# TYPE discovery_ova_capture_mode gauge
discovery_ova_capture_mode{interface="$(esc "$CAPTURE_IF")",profile="$(esc "$cap_profile")"} $cap_mode
discovery_ova_wired_management_mode{interface="$(esc "$CAPTURE_IF")"} $wired_mode
discovery_ova_capture_carrier{interface="$(esc "$CAPTURE_IF")"} $carrier
discovery_ova_capture_promiscuous{interface="$(esc "$CAPTURE_IF")"} $promisc
discovery_ova_rollback_pending $rollback
discovery_ova_rsyslog_up $rs
discovery_ova_lldpd_up $lldpd_up
discovery_ova_iperf3_server_active $iperf_server
discovery_ova_syslog_udp_listener $udp
discovery_ova_syslog_tcp_listener $tcp
discovery_ova_packet_capture_active $capture_active
discovery_ova_guacamole_up $guacamole_up
discovery_ova_blackbox_exporter_up $blackbox_up
discovery_ova_blackbox_target_count $blackbox_targets
discovery_ova_vsphere_configured $vsphere_configured
discovery_ova_redfish_target_count $redfish_targets
discovery_ova_pure_array_count $pure_arrays
discovery_ova_last_backup_success $backup_ok
discovery_ova_last_backup_timestamp_seconds $backup_ts
$(for svc in docker nginx rsyslog lldpd discovery-ova-web; do v=0; systemctl is-active --quiet "$svc.service" && v=1 || true; printf 'discovery_ova_service_up{service="%s"} %s\n' "$svc" "$v"; done)
$(for timer in discovery-ova-field-metrics discovery-ova-backup; do v=0; systemctl is-active --quiet "$timer.timer" && v=1 || true; printf 'discovery_ova_timer_up{timer="%s"} %s\n' "$timer" "$v"; done)
discovery_ova_collector_generation_timestamp_seconds $(date +%s)
METRICS
if [[ -r /sys/class/thermal/thermal_zone0/temp ]]; then
  awk '{printf "discovery_ova_cpu_temperature_fahrenheit %.3f\\n", ($1/1000*9/5)+32}' /sys/class/thermal/thermal_zone0/temp >>"$TMP"
fi
chmod 0644 "$TMP"
mv -f "$TMP" "$OUT"
EOF

  write_file /etc/systemd/system/discovery-ova-field-metrics.service 0644 root:root <<'EOF'
[Unit]
Description=Generate Discovery-OVA node-exporter textfile metrics
After=NetworkManager.service rsyslog.service docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/discovery-ova-field-metrics
EOF

  write_file /etc/systemd/system/discovery-ova-field-metrics.timer 0644 root:root <<'EOF'
[Unit]
Description=Refresh Discovery-OVA appliance metrics

[Timer]
OnBootSec=30s
OnUnitActiveSec=45s
AccuracySec=5s
Unit=discovery-ova-field-metrics.service

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now discovery-ova-field-metrics.timer
  systemctl start discovery-ova-field-metrics.service
  grep -q '^discovery_ova_management_up' "$STATE_ROOT/textfile_collector/discovery-ova.prom"
}

write_boot_email_service() {
  write_file /usr/local/sbin/discovery-ova-boot-email 0750 root:root <<'PY'
#!/usr/bin/env python3
import json, os, smtplib, socket, ssl, subprocess, sys
from datetime import datetime, timezone
from email.message import EmailMessage
from pathlib import Path
cfgp=Path('/etc/discovery-ova/ip-email.json')
if not cfgp.exists():
    print('boot email not configured'); sys.exit(0)
cfg=json.loads(cfgp.read_text())
if not cfg.get('enabled',False):
    print('boot email disabled'); sys.exit(0)
def out(args):
    return subprocess.run(args,text=True,capture_output=True,timeout=10).stdout.strip()
conf={}
for line in Path('/etc/discovery-ova/discovery-ova.conf').read_text().splitlines():
    if '=' in line:
        k,v=line.split('=',1); conf[k]=v.strip().strip("'").strip('"')
mg=conf['MGMT_IF']; cap=conf['CAPTURE_IF']
def addr(dev):
    p=out(['ip','-4','-o','addr','show','dev',dev,'scope','global']).split()
    return p[3].split('/')[0] if len(p)>3 else ''
def route(dev): return out(['ip','-4','route','show','default','dev',dev])
ip=addr(mg); gw=route(mg); active_mg=mg
if not ip or not gw:
    ip=addr(cap); gw=route(cap); active_mg=cap
profile=out(['nmcli','-t','-f','GENERAL.CONNECTION','dev','show',cap]).split(':',1)
profile=profile[1] if len(profile)>1 else ''
body=f'''Hostname: {socket.gethostname()}\nTimestamp: {datetime.now(timezone.utc).isoformat()}\nManagement interface: {active_mg}\nIPv4: {ip}\nDefault route: {gw}\nEthernet/capture profile: {profile}\n'''
msg=EmailMessage(); msg['Subject']=f'Discovery-OVA boot address: {socket.gethostname()} {ip}'; msg['From']=cfg.get('from',cfg['username']); msg['To']=cfg['to']; msg.set_content(body)
ctx=ssl.create_default_context(); port=int(cfg['port'])
if port==465:
    s=smtplib.SMTP_SSL(cfg['server'],port,timeout=20,context=ctx)
else:
    s=smtplib.SMTP(cfg['server'],port,timeout=20); s.ehlo(); s.starttls(context=ctx); s.ehlo()
try:
    s.login(cfg['username'],cfg['password']); s.send_message(msg)
finally: s.quit()
print(body)
PY

  write_file /etc/systemd/system/discovery-ova-boot-email.service 0644 root:root <<'EOF'
[Unit]
Description=Email Discovery-OVA final boot management address
After=network-online.target discovery-ova-network-boot-guard.service
Requires=discovery-ova-network-boot-guard.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/discovery-ova-boot-email
TimeoutStartSec=45
Restart=on-failure
RestartSec=20

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable discovery-ova-boot-email.service
}

configure_smtp_interactive() {
  require_root
  local ans to user server port pass from
  prompt_yes_no "Enable boot-address email?" N ans
  if [[ "$ans" != y ]]; then
    write_file /etc/discovery-ova/ip-email.json 0600 root:root <<'EOF'
{"enabled": false}
EOF
    log "Boot-address email disabled; run '$SELF smtp' after deployment to configure it."
    return 0
  fi
  prompt_value "Destination email" "" to valid_email "Enter a valid destination email address."
  prompt_value "SMTP username" "" user valid_nonempty "SMTP username is required."
  prompt_value "SMTP server" "smtp.gmail.com" server valid_no_space "SMTP server cannot be empty or contain spaces."
  prompt_value "SMTP port" "587" port valid_port "SMTP port must be a number from 1 to 65535."
  while true; do
    read -r -p "From address [$user]: " from
    from="${from:-$user}"
    if valid_email "$from"; then break; fi
    echo "Enter a valid From email address. Please try again."
  done
  prompt_hidden_nonempty "SMTP application password (not echoed)" pass
  python3 - "$to" "$user" "$server" "$port" "$from" "$pass" <<'PY'
import json,sys
p='/etc/discovery-ova/ip-email.json'
obj={'enabled':True,'to':sys.argv[1],'username':sys.argv[2],'server':sys.argv[3],'port':int(sys.argv[4]),'from':sys.argv[5],'password':sys.argv[6]}
with open(p,'w') as f: json.dump(obj,f,indent=2)
PY
  chmod 0600 /etc/discovery-ova/ip-email.json
  chown root:root /etc/discovery-ova/ip-email.json
  systemctl start discovery-ova-boot-email.service
  log "Boot-address email manual test completed."
}

write_backup_system() {
  stage 8 "Backup and recovery"
  install -d -m 0700 "$BACKUP_DIR/local"
  if [[ ! -f "$ETC_ROOT/backup_ed25519" ]]; then
    ssh-keygen -q -t ed25519 -N '' -C "discovery-ova-backup@$HOSTNAME_SHORT" -f "$ETC_ROOT/backup_ed25519"
    chmod 0600 "$ETC_ROOT/backup_ed25519"
  fi
  [[ -f "$ETC_ROOT/backup-remote.json" ]] || printf '%s\n' '{"enabled": false}' > "$ETC_ROOT/backup-remote.json"
  chmod 0600 "$ETC_ROOT/backup-remote.json"

  write_file /usr/local/sbin/discovery-ova-backup 0750 root:root <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/discovery-ova/discovery-ova.conf
LOCK=/run/discovery-ova-backup.lock
STATUS=/var/lib/discovery-ova/backup.status
LOCAL="$BACKUP_DIR/local"
mkdir -p "$LOCAL"
exec 9>"$LOCK"
flock -n 9 || { echo "backup already running"; exit 0; }
now="$(date +%s)"; stamp="$(date +%Y%m%d-%H%M%S)"
tmp="$LOCAL/.discovery-ova-$stamp.tar.gz.tmp"
out="$LOCAL/discovery-ova-$stamp.tar.gz"
sha="$out.sha256"
compose=(docker compose -f "$COMPOSE_DIR/compose.yml" --env-file "$COMPOSE_DIR/.env")
cleanup(){ "${compose[@]}" up -d >/dev/null 2>&1 || true; }
trap cleanup EXIT
# Quiesce stateful application writers; observability bulk stores are intentionally excluded.
"${compose[@]}" stop dispatcher librenms db guacamole guacamole-db >/dev/null || true
include=(
  /opt/discovery-ova/compose
  /opt/discovery-ova/config
  /opt/discovery-ova/apps
  /opt/discovery-ova/portal
  /opt/discovery-ova/data/librenms
  /opt/discovery-ova/data/db
  /opt/discovery-ova/data/guacamole-db
  /opt/discovery-ova/data/smokeping/config
  /opt/discovery-ova/data/librespeed
  /opt/discovery-ova/data/scanner
  /etc/discovery-ova
  /etc/nginx
  /etc/rsyslog.conf
  /etc/rsyslog.d
  /etc/default/lldpd
  /etc/default/discovery-ova-iperf3
  /etc/netplan
  /etc/systemd/system
  /usr/local/sbin/discovery-ova-installer
  /usr/local/sbin/discovery-ova-network
  /usr/local/sbin/discovery-ova-network-boot-guard
  /usr/local/libexec/discovery-ova-network-common
  /usr/local/sbin/discovery-ova-field-metrics
  /usr/local/sbin/discovery-ova-boot-email
  /usr/local/sbin/discovery-ova-tls-refresh
  /usr/local/sbin/discovery-ova-iperf3-server
  /usr/local/sbin/discovery-ova-backup
  /usr/local/sbin/discovery-ova-firstboot
)
# Only Discovery-OVA-owned NM profiles are recoverable; never archive unrelated management credentials.
[[ -e /etc/NetworkManager/system-connections/discovery-ova-capture.nmconnection ]] && include+=(/etc/NetworkManager/system-connections/discovery-ova-capture.nmconnection)
[[ -e /etc/NetworkManager/system-connections/discovery-ova-wired.nmconnection ]] && include+=(/etc/NetworkManager/system-connections/discovery-ova-wired.nmconnection)
tar --warning=no-file-changed -czf "$tmp" \
  --exclude='/etc/discovery-ova/backup_ed25519' \
  --exclude='/opt/discovery-ova/data/prometheus' \
  --exclude='/opt/discovery-ova/data/loki' \
  --exclude='/opt/discovery-ova/data/ntopng' \
  --exclude='/opt/discovery-ova/data/captures' \
  --exclude='/opt/discovery-ova/data/smokeping/data' \
  "${include[@]}"
mv -f "$tmp" "$out"
(cd "$LOCAL" && sha256sum "$(basename "$out")") > "$sha"
(cd "$LOCAL" && sha256sum -c "$(basename "$sha")" >/dev/null)
ln -sfn "$(basename "$out")" "$LOCAL/latest.tar.gz"
ln -sfn "$(basename "$sha")" "$LOCAL/latest.tar.gz.sha256"
"${compose[@]}" up -d >/dev/null
trap - EXIT
remote_ok=0
if [[ -r /etc/discovery-ova/backup-remote.json ]] && jq -e '.enabled==true' /etc/discovery-ova/backup-remote.json >/dev/null 2>&1; then
  host="$(jq -r .host /etc/discovery-ova/backup-remote.json)"
  user="$(jq -r .user /etc/discovery-ova/backup-remote.json)"
  path="$(jq -r .path /etc/discovery-ova/backup-remote.json)"
  key=/etc/discovery-ova/backup_ed25519
  opts=(-i "$key" -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)
  if ssh "${opts[@]}" "$user@$host" "mkdir -p -- '$path'" >/dev/null 2>&1; then
    scp "${opts[@]}" "$out" "$user@$host:$path/.discovery-ova-latest.tar.gz.tmp" >/dev/null
    scp "${opts[@]}" "$sha" "$user@$host:$path/.discovery-ova-latest.tar.gz.sha256.tmp" >/dev/null
    if ssh "${opts[@]}" "$user@$host" "cd '$path' && sed 's#$(basename "$out")#.discovery-ova-latest.tar.gz.tmp#' .discovery-ova-latest.tar.gz.sha256.tmp | sha256sum -c - >/dev/null && mv -f .discovery-ova-latest.tar.gz.tmp discovery-ova-latest.tar.gz && mv -f .discovery-ova-latest.tar.gz.sha256.tmp discovery-ova-latest.tar.gz.sha256"; then
      remote_ok=1
    fi
  fi
fi
cat > "$STATUS.tmp" <<STATUS
timestamp=$now
ok=1
remote_ok=$remote_ok
file=$out
STATUS
mv -f "$STATUS.tmp" "$STATUS"
# Keep seven dated local backups plus latest symlinks.
find "$LOCAL" -maxdepth 1 -type f -name 'discovery-ova-*.tar.gz' -printf '%T@ %p\n' | sort -nr | awk 'NR>7{print $2}' | xargs -r rm -f
find "$LOCAL" -maxdepth 1 -type f -name 'discovery-ova-*.tar.gz.sha256' -printf '%T@ %p\n' | sort -nr | awk 'NR>7{print $2}' | xargs -r rm -f
EOF

  write_file /etc/systemd/system/discovery-ova-backup.service 0644 root:root <<'EOF'
[Unit]
Description=Discovery-OVA configuration and state backup
After=docker.service network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/discovery-ova-backup
TimeoutStartSec=30min
EOF

  write_file /etc/systemd/system/discovery-ova-backup.timer 0644 root:root <<'EOF'
[Unit]
Description=Daily Discovery-OVA backup

[Timer]
OnCalendar=*-*-* 03:15:00
Persistent=true
RandomizedDelaySec=10min
Unit=discovery-ova-backup.service

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now discovery-ova-backup.timer
}

configure_remote_backup_interactive() {
  require_root
  local ans host user path
  prompt_yes_no "Enable remote backup synchronization to Farva/SSH?" N ans
  if [[ "$ans" != y ]]; then
    printf '%s\n' '{"enabled": false}' > /etc/discovery-ova/backup-remote.json
    chmod 0600 /etc/discovery-ova/backup-remote.json
    return 0
  fi
  prompt_value "Remote hostname or IP" "farva" host valid_simple_host "Enter a hostname or IP address without spaces."
  prompt_value "Remote SSH user" "" user valid_nonempty "Remote SSH user is required."
  prompt_value "Remote directory" "/srv/backups/discovery-ova" path valid_abs_path "Remote directory must be an absolute path beginning with /."
  jq -n --arg h "$host" --arg u "$user" --arg p "$path" '{enabled:true,host:$h,user:$u,path:$p}' > /etc/discovery-ova/backup-remote.json
  chmod 0600 /etc/discovery-ova/backup-remote.json
  echo
  echo "Install this public key in $user@$host:~/.ssh/authorized_keys:"
  cat /etc/discovery-ova/backup_ed25519.pub
  echo
  echo "Remote sync will defer safely until that key is authorized."
}

initialize_app_accounts() {
  stage 9 "Application account bootstrap"
  # Grafana v13 uses `grafana cli`; reset the real admin password after its SQLite DB exists.
  if ! docker exec discovery-ova-grafana grafana cli --homepath /usr/share/grafana admin reset-admin-password "$OPERATOR_PASSWORD" >/tmp/discovery-ova-grafana-rekey.out 2>&1; then
    warn "Grafana admin password reset failed: $(cat /tmp/discovery-ova-grafana-rekey.out)"
  fi
  rm -f /tmp/discovery-ova-grafana-rekey.out

  # LibreNMS supports CLI user creation after database migrations complete.
  for _ in {1..60}; do
    if docker exec discovery-ova-librenms /opt/librenms/lnms --version >/dev/null 2>&1; then break; fi
    sleep 3
  done
  if ! docker exec -u librenms discovery-ova-librenms /opt/librenms/lnms user:add "$OPERATOR_USER" --role=admin --password="$OPERATOR_PASSWORD" >/tmp/discovery-ova-lnms-user.out 2>&1; then
    grep -Eqi 'already|exists|duplicate' /tmp/discovery-ova-lnms-user.out || warn "LibreNMS user bootstrap: $(cat /tmp/discovery-ova-lnms-user.out)"
  fi
  rm -f /tmp/discovery-ova-lnms-user.out

  # Guacamole schema ships a guacadmin account. Rename that entity to the shared operator and replace its password before normal use.
  local guac_pw_b64 guac_sql
  guac_pw_b64="$(printf '%s' "$OPERATOR_PASSWORD" | base64 -w0)"
  guac_sql="SET @p=CONVERT(FROM_BASE64('${guac_pw_b64}') USING utf8mb4); SET @salt=UNHEX(SHA2(UUID(),256)); UPDATE guacamole_user u JOIN guacamole_entity e ON u.entity_id=e.entity_id SET u.password_salt=@salt,u.password_hash=UNHEX(SHA2(CONCAT(@p,HEX(@salt)),256)),u.password_date=CURRENT_TIMESTAMP WHERE e.type='USER' AND e.name IN ('guacadmin','${OPERATOR_USER}'); UPDATE guacamole_entity SET name='${OPERATOR_USER}' WHERE type='USER' AND name='guacadmin';"
  local guac_ready=0
  for _ in {1..90}; do
    if docker exec -e MYSQL_PWD="$GUAC_DB_ROOT_PASSWORD" discovery-ova-guacamole-db mariadb -N -uroot guacamole_db -e 'SELECT COUNT(*) FROM guacamole_user;' >/dev/null 2>&1; then
      guac_ready=1
      break
    fi
    sleep 2
  done
  (( guac_ready == 1 )) || die "Guacamole database schema did not become ready. Check discovery-ova-guacamole-db logs."
  docker exec -e MYSQL_PWD="$GUAC_DB_ROOT_PASSWORD" discovery-ova-guacamole-db mariadb -uroot guacamole_db -e "$guac_sql" >/dev/null \
    || die "Guacamole operator bootstrap failed. Check the Guacamole database logs."
  [[ "$(docker exec -e MYSQL_PWD="$GUAC_DB_ROOT_PASSWORD" discovery-ova-guacamole-db mariadb -N -uroot guacamole_db -e "SELECT COUNT(*) FROM guacamole_entity WHERE type='USER' AND name='${OPERATOR_USER}';" 2>/dev/null | tr -d '[:space:]')" == "1" ]] \
    || die "Guacamole operator account '$OPERATOR_USER' was not created correctly."

  warn "ntopng Community uses its own first-login credential. Its current upstream default is admin/admin and it forces a password change on first access. Nginx Basic Auth still protects the proxy."
}

install_firstboot_identity_service() {
  write_file /usr/local/sbin/discovery-ova-firstboot 0750 root:root <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
marker=/var/lib/discovery-ova/firstboot.pending
[[ -e "$marker" ]] || exit 0
# systemd normally establishes machine-id very early; make it persistent if still empty.
[[ -s /etc/machine-id ]] || systemd-machine-id-setup >/dev/null 2>&1 || true
ssh-keygen -A >/dev/null 2>&1 || true
rm -f "$marker"
logger -t discovery-ova-firstboot "regenerated clone-unique machine/SSH identity"
EOF

  write_file /etc/systemd/system/discovery-ova-firstboot.service 0644 root:root <<'EOF'
[Unit]
Description=Regenerate clone-unique Discovery-OVA guest identity
ConditionPathExists=/var/lib/discovery-ova/firstboot.pending
Before=ssh.service
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/discovery-ova-firstboot

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable discovery-ova-firstboot.service
}

rekey() {
  require_root
  load_conf
  [[ -r "$SECRETS_FILE" ]] || die "Missing $SECRETS_FILE"
  # shellcheck disable=SC1090
  source "$SECRETS_FILE"
  local new_password hash
  prompt_secret "New password for operator '$OPERATOR_USER'" new_password 12

  if docker ps --format '{{.Names}}' | grep -Fxq discovery-ova-grafana; then
    docker exec discovery-ova-grafana grafana cli --homepath /usr/share/grafana admin reset-admin-password "$new_password" >/dev/null \
      || warn "Grafana admin password could not be reset automatically."
  fi

  if docker ps --format '{{.Names}}' | grep -Fxq discovery-ova-librenms && docker ps --format '{{.Names}}' | grep -Fxq discovery-ova-db; then
    hash="$(docker exec discovery-ova-librenms php -r 'echo password_hash($argv[1], PASSWORD_BCRYPT);' "$new_password" 2>/dev/null || true)"
    if [[ "$hash" == \$2* ]]; then
      docker exec -e MYSQL_PWD="$DB_PASSWORD" discovery-ova-db mariadb -ulibrenms librenms \
        -e "UPDATE users SET password='${hash}' WHERE username='${OPERATOR_USER}';" >/dev/null \
        || warn "LibreNMS password could not be updated automatically."
    else
      warn "LibreNMS password hash generation failed."
    fi
  fi

  if docker ps --format '{{.Names}}' | grep -Fxq discovery-ova-guacamole-db; then
    local guac_pw_b64 guac_sql
    guac_pw_b64="$(printf '%s' "$new_password" | base64 -w0)"
    guac_sql="SET @p=CONVERT(FROM_BASE64('${guac_pw_b64}') USING utf8mb4); SET @salt=UNHEX(SHA2(UUID(),256)); UPDATE guacamole_user u JOIN guacamole_entity e ON u.entity_id=e.entity_id SET u.password_salt=@salt,u.password_hash=UNHEX(SHA2(CONCAT(@p,HEX(@salt)),256)),u.password_date=CURRENT_TIMESTAMP WHERE e.type='USER' AND e.name='${OPERATOR_USER}';"
    docker exec -e MYSQL_PWD="$GUAC_DB_ROOT_PASSWORD" discovery-ova-guacamole-db mariadb -uroot guacamole_db -e "$guac_sql" >/dev/null \
      || warn "Guacamole password could not be updated automatically."
  fi

  htpasswd -bcB /etc/nginx/.discovery-ova.htpasswd "$OPERATOR_USER" "$new_password" >/dev/null
  chmod 0640 /etc/nginx/.discovery-ova.htpasswd
  chown root:www-data /etc/nginx/.discovery-ova.htpasswd

  OPERATOR_PASSWORD="$new_password"
  {
    printf 'OPERATOR_PASSWORD=%q\n' "$OPERATOR_PASSWORD"
    printf 'DB_PASSWORD=%q\n' "$DB_PASSWORD"
    printf 'REDIS_PASSWORD=%q\n' "$REDIS_PASSWORD"
    printf 'GRAFANA_SECRET_KEY=%q\n' "$GRAFANA_SECRET_KEY"
    printf 'LIBRESPEED_RESULTS_PASSWORD=%q\n' "$LIBRESPEED_RESULTS_PASSWORD"
    printf 'SNMP_COMMUNITY=%q\n' "$SNMP_COMMUNITY"
    printf 'GUAC_DB_PASSWORD=%q\n' "$GUAC_DB_PASSWORD"
    printf 'GUAC_DB_ROOT_PASSWORD=%q\n' "$GUAC_DB_ROOT_PASSWORD"
  } | write_file "$SECRETS_FILE" 0600 root:root
  systemctl reload nginx
  log "Operator credential rotated for the Discovery-OVA front door, Grafana, LibreNMS and Guacamole where reachable. ntopng maintains its own credential."
}

validate() {
  require_root
  load_conf
  [[ -r "$SECRETS_FILE" ]] && source "$SECRETS_FILE"
  local failures=0 warnings=0
  local latest archive_list token start_ns end_ns remote_enabled remote_ok

  pass(){ printf 'PASS  %s\n' "$1"; }
  fail(){ printf 'FAIL  %s\n' "$1"; failures=$((failures+1)); }
  vwarn(){ printf 'WARN  %s\n' "$1"; warnings=$((warnings+1)); }
  check(){ local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }

  echo "=== Discovery-OVA race-ready validation ==="
  check "Nginx configuration syntax" nginx -t
  check "Portal authentication challenge" bash -c '[[ "$(curl -ksS -o /dev/null -w "%{http_code}" https://127.0.0.1/)" == 401 ]]'
  if [[ -n "${OPERATOR_PASSWORD:-}" ]]; then
    check "Authenticated HTTPS portal" curl -kfsS -u "$OPERATOR_USER:$OPERATOR_PASSWORD" https://127.0.0.1/
    check "Guacamole web application" curl -fsSL http://127.0.0.1:8085/guacamole/
    check "Blackbox Exporter metrics" curl -fsS http://127.0.0.1:9115/metrics
  else
    fail "Stored operator credential available for portal test"
  fi

  local c
  for c in discovery-ova-db discovery-ova-redis discovery-ova-librenms discovery-ova-librenms-dispatcher discovery-ova-smokeping discovery-ova-librespeed discovery-ova-ntopng discovery-ova-guacamole-db discovery-ova-guacd discovery-ova-guacamole discovery-ova-blackbox-exporter discovery-ova-prometheus discovery-ova-node-exporter discovery-ova-cadvisor discovery-ova-loki discovery-ova-alloy discovery-ova-grafana; do
    if [[ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || true)" == true ]]; then pass "Container running: $c"; else fail "Container running: $c"; fi
  done
  for c in NetworkManager docker nginx rsyslog lldpd discovery-ova-web; do
    check "systemd service active: $c" systemctl is-active --quiet "$c.service"
  done

  check "LibreNMS backend" curl -fsS --max-time 8 http://127.0.0.1:8001/
  check "SmokePing backend" curl -fsS --max-time 8 http://127.0.0.1:8002/
  check "LibreSpeed backend" curl -fsS --max-time 8 http://127.0.0.1:8003/
  check "ntopng backend" curl -fsS --max-time 8 http://127.0.0.1:3000/
  check "Grafana backend" curl -fsS --max-time 8 http://127.0.0.1:3001/api/health
  check "Scanner/control service" curl -fsS --max-time 8 http://127.0.0.1:8787/health
  check "iperf3 installed" command -v iperf3
  check "lldpctl installed" command -v lldpctl
  check "LLDP control socket" lldpctl
  check "iperf3 server unit installed" systemctl cat discovery-ova-iperf3-server.service
  check "iperf3 loopback self-test" bash -c 'set -e; /usr/bin/iperf3 -s -1 -B 127.0.0.1 -p 55201 >/tmp/discovery-ova-iperf3-selftest.log 2>&1 & p=$!; trap "kill $p >/dev/null 2>&1 || true; rm -f /tmp/discovery-ova-iperf3-selftest.log" EXIT; sleep 0.3; /usr/bin/iperf3 -c 127.0.0.1 -p 55201 -t 1 >/dev/null; wait $p'
  check "Prometheus ready" curl -fsS --max-time 8 http://127.0.0.1:9090/-/ready
  check "Loki ready" curl -fsS --max-time 8 http://127.0.0.1:3100/ready
  check "Alloy ready" curl -fsS --max-time 8 http://127.0.0.1:12345/-/ready

  prom_targets="$(curl -fsS http://127.0.0.1:9090/api/v1/targets 2>/dev/null || echo '{}')"
  if jq -e '[.data.activeTargets[]? | select((.labels.job=="node" or .labels.job=="cadvisor" or .labels.job=="prometheus" or .labels.job=="blackbox-exporter") and .health != "up")] | length == 0' <<<"$prom_targets" >/dev/null 2>&1; then
    pass "Core Prometheus targets healthy"
  else
    fail "Core Prometheus targets healthy"
  fi
  remote_bad="$(jq '[.data.activeTargets[]? | select((.labels.job=="blackbox" or .labels.job=="vsphere" or .labels.job=="redfish" or (.labels.job|startswith("purefa_"))) and .health != "up")] | length' <<<"$prom_targets" 2>/dev/null || echo 0)"
  if [[ "$remote_bad" =~ ^[0-9]+$ ]] && (( remote_bad > 0 )); then
    vwarn "$remote_bad remote monitored target(s) are currently unhealthy; this does not fail appliance validation"
  else
    pass "Remote monitoring targets have no current scrape failures"
  fi
  if [[ "$(jq -r '.enabled // false' "$ETC_ROOT/vsphere.json" 2>/dev/null || echo false)" == true ]]; then
    [[ "$(docker inspect -f '{{.State.Running}}' discovery-ova-telegraf-vsphere 2>/dev/null || true)" == true ]] && pass "vSphere collector container running" || fail "vSphere collector container running"
  fi
  if [[ "$(jq -r '.enabled // false' "$ETC_ROOT/redfish.json" 2>/dev/null || echo false)" == true ]]; then
    [[ "$(docker inspect -f '{{.State.Running}}' discovery-ova-redfish-exporter 2>/dev/null || true)" == true ]] && pass "Redfish exporter container running" || fail "Redfish exporter container running"
    curl -fsS --max-time 5 http://127.0.0.1:9348/health >/dev/null 2>&1 && pass "Redfish exporter health endpoint" || fail "Redfish exporter health endpoint"
  fi
  if curl -fsSG http://127.0.0.1:9090/api/v1/query --data-urlencode 'query=node_textfile_scrape_error' | jq -e '.data.result | length > 0 and all(.[]; .value[1] == "0")' >/dev/null 2>&1; then
    pass "node_textfile_scrape_error is zero"
  else
    fail "node_textfile_scrape_error is zero"
  fi

  check "rsyslog service" systemctl is-active --quiet rsyslog.service
  if ss -lunH | grep -Eq '(^|[[:space:]])[^ ]*:514[[:space:]]'; then pass "UDP syslog listener on 514"; else fail "UDP syslog listener on 514"; fi
  if ss -ltnH | grep -Eq '(^|[[:space:]])[^ ]*:514[[:space:]]'; then pass "TCP syslog listener on 514"; else fail "TCP syslog listener on 514"; fi

  # Diagnostic messages are non-destructive configuration-wise and verify end-to-end rsyslog -> Alloy -> Loki ingestion.
  token="discovery-ova-validate-$(date +%s)-$RANDOM"
  start_ns="$(( $(date +%s) - 30 ))000000000"
  logger --udp --server 127.0.0.1 --port 514 -t discovery-ova-validate "$token udp" || true
  logger --tcp --server 127.0.0.1 --port 514 -t discovery-ova-validate "$token tcp" || true
  sleep 3
  end_ns="$(date +%s)000000000"
  if curl -fsSG http://127.0.0.1:3100/loki/api/v1/query_range \
      --data-urlencode "query={job=\"syslog\"} |= \"$token\"" --data-urlencode "start=$start_ns" --data-urlencode "end=$end_ns" \
      | jq -e '[.data.result[].values[]?] | length >= 2' >/dev/null 2>&1; then
    pass "UDP and TCP syslog reached Loki"
  else
    fail "UDP and TCP syslog reached Loki"
  fi

  if [[ -r /usr/local/libexec/discovery-ova-network-common ]]; then
    # shellcheck disable=SC1091
    source /usr/local/libexec/discovery-ova-network-common
    if discovery_management_path_ok "$MGMT_IF"; then
      pass "Management path: IPv4, default route, gateway, external route and outbound connectivity"
    else
      fail "Management path: IPv4, default route, gateway, external route and outbound connectivity"
      discovery_network_diagnostics "$MGMT_IF" || true
    fi
  else
    fail "Shared management-path validation library present"
  fi
  if getent ahostsv4 example.com >/dev/null 2>&1; then
    pass "DNS resolution (optional convenience)"
  else
    vwarn "DNS resolution unavailable; Discovery-OVA core runtime remains operational by IP"
  fi

  if ! ip -4 -o addr show dev "$CAPTURE_IF" scope global | grep -q .; then pass "Capture interface has no global IPv4"; else fail "Capture interface has no global IPv4"; fi
  if ! ip -4 route show default dev "$CAPTURE_IF" 2>/dev/null | grep -q '^default '; then pass "Capture interface has no default route"; else fail "Capture interface has no default route"; fi
  if ip -details link show "$CAPTURE_IF" | grep -qw PROMISC; then pass "Capture interface promiscuous mode"; else fail "Capture interface promiscuous mode"; fi
  if nmcli -t -f GENERAL.CONNECTION dev show "$CAPTURE_IF" | grep -Fqx 'GENERAL.CONNECTION:discovery-ova-capture'; then pass "Capture NetworkManager profile active"; else fail "Capture NetworkManager profile active"; fi
  if ! systemctl is-active --quiet discovery-ova-network-rollback.timer; then pass "No capture rollback pending"; else fail "No capture rollback pending"; fi

  check "Boot network guard enabled" systemctl is-enabled --quiet discovery-ova-network-boot-guard.service
  if systemctl show -p After --value discovery-ova-boot-email.service 2>/dev/null | tr ' ' '\n' | grep -Fxq discovery-ova-network-boot-guard.service; then pass "Boot email ordered after network guard"; else fail "Boot email ordered after network guard"; fi
  check "Field metrics timer enabled" systemctl is-enabled --quiet discovery-ova-field-metrics.timer
  check "Backup timer enabled" systemctl is-enabled --quiet discovery-ova-backup.timer

  latest="$BACKUP_DIR/local/latest.tar.gz"
  if [[ -L "$latest" || -f "$latest" ]] && [[ -f "$BACKUP_DIR/local/latest.tar.gz.sha256" ]]; then
    if (cd "$BACKUP_DIR/local" && sha256sum -c latest.tar.gz.sha256 >/dev/null 2>&1); then pass "Latest backup SHA-256 checksum"; else fail "Latest backup SHA-256 checksum"; fi
    archive_list="$(tar -tzf "$latest" 2>/dev/null || true)"
    grep -Fq 'opt/discovery-ova/compose/compose.yml' <<<"$archive_list" && pass "Backup contains Compose configuration" || fail "Backup contains Compose configuration"
    grep -Fq 'etc/nginx/' <<<"$archive_list" && pass "Backup contains Nginx configuration" || fail "Backup contains Nginx configuration"
    grep -Fq 'etc/rsyslog.d/20-discovery-ova-remote.conf' <<<"$archive_list" && pass "Backup contains rsyslog configuration" || fail "Backup contains rsyslog configuration"
    grep -Fq 'etc/default/lldpd' <<<"$archive_list" && pass "Backup contains LLDP configuration" || fail "Backup contains LLDP configuration"
    grep -Fq 'etc/default/discovery-ova-iperf3' <<<"$archive_list" && pass "Backup contains iperf3 interface configuration" || fail "Backup contains iperf3 interface configuration"
    grep -Fq 'usr/local/sbin/discovery-ova-iperf3-server' <<<"$archive_list" && pass "Backup contains iperf3 server helper" || fail "Backup contains iperf3 server helper"
    grep -Fq 'etc/systemd/system/discovery-ova-network-boot-guard.service' <<<"$archive_list" && pass "Backup contains Discovery-OVA systemd units" || fail "Backup contains Discovery-OVA systemd units"
    grep -Fq 'usr/local/libexec/discovery-ova-network-common' <<<"$archive_list" && pass "Backup contains shared network validation library" || fail "Backup contains shared network validation library"
    grep -Fq 'etc/NetworkManager/system-connections/discovery-ova-capture.nmconnection' <<<"$archive_list" && pass "Backup contains capture NetworkManager profile" || fail "Backup contains capture NetworkManager profile"
    grep -Fq 'opt/discovery-ova/data/scanner/' <<<"$archive_list" && pass "Backup contains scanner state" || fail "Backup contains scanner state"
    grep -Fq 'opt/discovery-ova/data/guacamole-db/' <<<"$archive_list" && pass "Backup contains Guacamole database state" || fail "Backup contains Guacamole database state"
    if grep -Eq 'opt/discovery-ova/data/(prometheus|loki|ntopng|captures|smokeping/data)(/|$)' <<<"$archive_list"; then
      fail "Backup excludes rebuildable/bulk observability and capture data"
    else
      pass "Backup excludes rebuildable/bulk observability and capture data"
    fi
    if grep -Fq 'etc/discovery-ova/backup_ed25519' <<<"$archive_list"; then fail "Backup excludes private remote-backup key"; else pass "Backup excludes private remote-backup key"; fi
  else
    fail "Latest local backup exists"
  fi

  remote_enabled="$(jq -r '.enabled // false' /etc/discovery-ova/backup-remote.json 2>/dev/null || echo false)"
  remote_ok="$(awk -F= '$1=="remote_ok"{print $2}' /var/lib/discovery-ova/backup.status 2>/dev/null | tail -1)"
  if [[ "$remote_enabled" == true ]]; then
    if [[ "$remote_ok" == 1 ]]; then pass "Remote backup synchronization status"; else vwarn "Remote backup configured but last sync deferred/failed (local backup remains valid)"; fi
  else
    pass "Remote backup intentionally disabled"
  fi

  echo "=== Result: $failures failure(s), $warnings warning(s) ==="
  (( failures == 0 ))
}

seal_ova() {
  require_root
  load_conf
  echo "This prepares the current VM as a reusable OVA template. It preserves Discovery-OVA application data and credentials."
  echo "After deployment of a clone, run 'sudo discovery-ova-installer rekey' if the template credential must not be shared."
  local ans
  prompt_yes_no "Continue with OVA sealing?" N ans
  [[ "$ans" == y ]] || { echo "Cancelled."; return 0; }

  install_firstboot_identity_service
  touch "$STATE_ROOT/firstboot.pending"
  chmod 0600 "$STATE_ROOT/firstboot.pending"

  # Remove guest-unique host identity that should be generated on the clone.
  rm -f /etc/ssh/ssh_host_*key /etc/ssh/ssh_host_*key.pub
  truncate -s 0 /etc/machine-id
  rm -f /var/lib/dbus/machine-id 2>/dev/null || true
  rm -f /var/lib/NetworkManager/*.lease /var/lib/dhcp/*.leases 2>/dev/null || true
  rm -f /var/lib/systemd/random-seed 2>/dev/null || true
  command -v cloud-init >/dev/null 2>&1 && cloud-init clean --logs --seed 2>/dev/null || true
  journalctl --rotate >/dev/null 2>&1 || true
  journalctl --vacuum-time=1s >/dev/null 2>&1 || true
  rm -f /root/.bash_history
  find /home -maxdepth 2 -name .bash_history -type f -delete 2>/dev/null || true
  : > "$LOG_FILE"
  sync
  echo
  echo "OVA seal complete. Shut the VM down now (do not boot it again before exporting)."
  echo "In vSphere, export/clone the powered-off VM to OVF/OVA. The first clone boot regenerates SSH host keys and machine identity."
}

install_all() {
  require_root
  preflight_os
  install_packages
  collect_settings
  ensure_dirs_user
  configure_hostname_time
  install -D -m 0750 -o root -g root "$SELF" /usr/local/sbin/discovery-ova-installer
  configure_networkmanager
  configure_diagnostics_services
  configure_firewall
  write_compose
  configure_syslog
  configure_portal_nginx
  write_control_app
  configure_metrics
  write_boot_email_service
  write_backup_system
  install_firstboot_identity_service
  initialize_app_accounts

  if [[ "$(jq -r '.enabled // false' "$ETC_ROOT/vsphere.json" 2>/dev/null || echo false)" == false && "$(jq -r '.enabled // false' "$ETC_ROOT/redfish.json" 2>/dev/null || echo false)" == false && "$(jq -r '.enabled // false' "$ETC_ROOT/pure-monitoring.json" 2>/dev/null || echo false)" == false ]]; then
    local monitor_ans
    prompt_yes_no "Configure optional remote vSphere, Redfish and Pure monitoring now?" N monitor_ans
    if [[ "$monitor_ans" == y ]]; then configure_remote_monitoring_interactive; fi
  else
    log "Existing remote infrastructure monitoring configuration preserved. Use 'discovery-ova-installer remote' to change it."
    write_prometheus_config
    curl -fsS -X POST http://127.0.0.1:9090/-/reload >/dev/null 2>&1 || true
  fi

  # SMTP and Farva are deliberately interactive so no password/private deployment detail enters chat or shell history.
  if [[ ! -r /etc/discovery-ova/ip-email.json ]]; then
    configure_smtp_interactive
  else
    log "Existing boot-email configuration preserved. Use 'discovery-ova-installer smtp' to change it."
  fi
  if [[ "$(jq -r '.enabled // false' /etc/discovery-ova/backup-remote.json 2>/dev/null || echo false)" == false ]]; then
    configure_remote_backup_interactive
  fi

  stage 10 "Initial backup and race-ready validation"
  /usr/local/sbin/discovery-ova-backup
  /usr/local/sbin/discovery-ova-field-metrics
  if validate; then
    log "Discovery-OVA installation completed successfully."
  else
    die "Installation completed but race-ready validation found required failures. Review the output above."
  fi

  local ip
  ip="$(get_mgmt_ip "$MGMT_IF")"
  cat <<EOF

Discovery-OVA is ready.
  Portal:   https://$ip/
  Operator: $OPERATOR_USER
  Capture:  $CAPTURE_IF (addressless, promiscuous)
  Tools:    https://$ip/diagnostics/ (iperf3 + LLDP)
  Remote:   https://$ip/remote/
  Guac:     https://$ip/guacamole/

DNS/mDNS is optional. Core Discovery-OVA runtime, health checks and portal links do not require name resolution.

VMware requirement: connect $CAPTURE_IF's vNIC to the SPAN/mirror destination port group and configure the vSphere networking layer to deliver mirrored traffic to it. The guest installer cannot configure a vSphere Distributed Switch mirror session or port-group security policy.

Before exporting a reusable OVA:
  sudo discovery-ova-installer validate
  sudo discovery-ova-installer seal
  # then power off and export the VM without booting it again
EOF
}

main() {
  case "${1:-}" in
    install) install_all ;;
    validate) validate ;;
    rekey) rekey ;;
    smtp) require_root; load_conf; configure_smtp_interactive ;;
    backup-remote) require_root; load_conf; configure_remote_backup_interactive ;;
    remote) require_root; load_conf; configure_remote_monitoring_interactive ;;
    seal) seal_ova ;;
    discover) discover ;;
    -h|--help|help|'') usage ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
