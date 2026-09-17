#!/usr/bin/env bash
# Thorny OVA builder for Ubuntu Server Minimal
# Version: 0.2.0 (2026-09-17)
# Target: Ubuntu Server 26.04 LTS amd64 on VMware vSphere/ESXi
#
# One script, staged internally.  It can install, validate, reconfigure credentials,
# and seal the guest before OVA export.

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

SELF="$(readlink -f "$0")"
VERSION="0.2.0"
THORNY_ROOT="/opt/thorny"
ETC_ROOT="/etc/thorny"
STATE_ROOT="/var/lib/thorny"
RUN_ROOT="/run/thorny"
COMPOSE_DIR="$THORNY_ROOT/compose"
CONFIG_DIR="$THORNY_ROOT/config"
DATA_DIR="$THORNY_ROOT/data"
PORTAL_DIR="$THORNY_ROOT/portal"
APP_DIR="$THORNY_ROOT/apps"
BACKUP_DIR="$THORNY_ROOT/backups"
LOG_FILE="/var/log/thorny-install.log"
CONF_FILE="$ETC_ROOT/thorny.conf"
SECRETS_FILE="$ETC_ROOT/secrets.env"
BUILD_STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_STAMP_DIR="/var/backups/thorny/$BUILD_STAMP"

# Pinned container versions. ntopng is resolved to an immutable digest at build time
# because its stable repository currently publishes a moving 'latest' tag.
LIBRENMS_IMAGE="librenms/librenms:26.8.2"
MARIADB_IMAGE="mariadb:11.8.9"
REDIS_IMAGE="redis:8.2.9-bookworm"
SMOKEPING_IMAGE="lscr.io/linuxserver/smokeping:2.9.0-r0-ls184"
LIBRESPEED_IMAGE="lscr.io/linuxserver/librespeed:v6.3.0-ls291"
PORTAINER_IMAGE="portainer/portainer-ce:2.45.1-alpine"
GRAFANA_IMAGE="grafana/grafana:13.2.2"
PROMETHEUS_IMAGE="prom/prometheus:v3.14.0"
LOKI_IMAGE="grafana/loki:3.7.3"
ALLOY_IMAGE="grafana/alloy:v1.19.2"
NODE_EXPORTER_IMAGE="prom/node-exporter:v1.12.1"
CADVISOR_IMAGE="ghcr.io/google/cadvisor:v0.60.5"

export DEBIAN_FRONTEND=noninteractive

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }
warn() { printf '%s WARNING: %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE" >&2; }
die() { printf '%s ERROR: %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE" >&2; exit 1; }
stage() { printf '\n===== Thorny stage %s: %s =====\n' "$1" "$2" | tee -a "$LOG_FILE"; }

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
    [[ ${#a} -ge $minlen ]] || { echo "Must be at least $minlen characters."; continue; }
    read -r -s -p "Confirm: " b; echo
    [[ "$a" == "$b" ]] || { echo "Values did not match."; continue; }
    printf -v "$varname" '%s' "$a"
    unset b
    return 0
  done
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
Thorny OVA builder $VERSION

Usage:
  sudo bash $0 install       Build or repair the appliance
  sudo bash $0 validate      Run race-ready validation
  sudo bash $0 rekey         Change operator credentials and refresh app admins
  sudo bash $0 smtp          Configure or disable boot-address email
  sudo bash $0 backup-remote Configure Farva/SSH remote backup settings
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

  host_default="${HOSTNAME_SHORT:-$(hostname -s 2>/dev/null || echo thorny)}"
  [[ "$host_default" == "localhost" || -z "$host_default" ]] && host_default="thorny"
  tz_default="${TIMEZONE:-$(cat /etc/timezone 2>/dev/null || echo Etc/UTC)}"

  echo "Detected management interface: $detected_mgmt ($(get_mgmt_ip "$detected_mgmt"))"
  echo "Detected capture candidate:    $detected_capture"
  echo
  read -r -p "Appliance hostname [$host_default]: " reply
  HOSTNAME_SHORT="${reply:-$host_default}"
  [[ "$HOSTNAME_SHORT" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,62}$ ]] || die "Invalid hostname."
  read -r -p "Management interface [$detected_mgmt]: " reply
  MGMT_IF="${reply:-$detected_mgmt}"
  [[ -e "/sys/class/net/$MGMT_IF" ]] || die "No interface $MGMT_IF."
  read -r -p "Capture interface [$detected_capture]: " reply
  CAPTURE_IF="${reply:-$detected_capture}"
  [[ -e "/sys/class/net/$CAPTURE_IF" ]] || die "No interface $CAPTURE_IF."
  [[ "$MGMT_IF" != "$CAPTURE_IF" ]] || die "Management and capture interfaces must be different."
  read -r -p "Timezone [$tz_default]: " reply
  TIMEZONE="${reply:-$tz_default}"
  timedatectl list-timezones | grep -Fxq "$TIMEZONE" || die "Unknown timezone $TIMEZONE."

  OPERATOR_USER="ohagan"
  if [[ -r "$SECRETS_FILE" ]]; then
    # Preserve database/application secrets on idempotent repair runs.
    # shellcheck disable=SC1090
    source "$SECRETS_FILE"
  fi
  if [[ -z "${OPERATOR_PASSWORD:-}" ]]; then
    prompt_secret "Password for Nginx/Grafana/LibreNMS/Portainer operator '$OPERATOR_USER'" OPERATOR_PASSWORD 12
  elif (( existing )); then
    echo "Reusing the existing root-only operator credential for this repair run. Use '$SELF rekey' to rotate it."
  fi

  DB_PASSWORD="${DB_PASSWORD:-$(random_secret)}"
  REDIS_PASSWORD="${REDIS_PASSWORD:-$(random_secret)}"
  GRAFANA_SECRET_KEY="${GRAFANA_SECRET_KEY:-$(random_secret)}"
  LIBRESPEED_RESULTS_PASSWORD="${LIBRESPEED_RESULTS_PASSWORD:-$(random_secret)}"
  SNMP_COMMUNITY="${SNMP_COMMUNITY:-$(openssl rand -hex 16)}"

  install -d -m 0700 "$ETC_ROOT" "$STATE_ROOT" "$RUN_ROOT"
  write_file "$CONF_FILE" 0600 root:root <<EOF
HOSTNAME_SHORT='$HOSTNAME_SHORT'
MGMT_IF='$MGMT_IF'
CAPTURE_IF='$CAPTURE_IF'
TIMEZONE='$TIMEZONE'
OPERATOR_USER='$OPERATOR_USER'
THORNY_ROOT='$THORNY_ROOT'
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
  } | write_file "$SECRETS_FILE" 0600 root:root

  export OPERATOR_PASSWORD
}

ensure_dirs_user() {
  getent group thorny >/dev/null || groupadd --system thorny
  id thorny >/dev/null 2>&1 || useradd --system --gid thorny --home-dir "$THORNY_ROOT" --shell /usr/sbin/nologin thorny
  THORNY_UID="$(id -u thorny)"
  THORNY_GID="$(id -g thorny)"
  export THORNY_UID THORNY_GID

  install -d -m 0750 -o root -g thorny "$THORNY_ROOT" "$COMPOSE_DIR" "$CONFIG_DIR" "$PORTAL_DIR" "$APP_DIR"
  install -d -m 0750 -o root -g thorny "$DATA_DIR" "$BACKUP_DIR"
  local d
  for d in librenms smokeping/config smokeping/data librespeed portainer scanner captures ntopng alloy node-exporter cadvisor; do
    install -d -m 0750 -o thorny -g thorny "$DATA_DIR/$d"
  done
  install -d -m 0750 -o root -g root "$DATA_DIR/db" "$DATA_DIR/redis"
  install -d -m 0750 -o 472 -g 472 "$DATA_DIR/grafana"
  install -d -m 0750 -o 65534 -g 65534 "$DATA_DIR/prometheus"
  install -d -m 0750 -o 10001 -g 10001 "$DATA_DIR/loki"
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
    nmap tcpdump ethtool iw iproute2 iputils-ping dnsutils \
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

  local current_ip current_gw
  current_ip="$(get_mgmt_ip "$MGMT_IF")"
  current_gw="$(get_gateway "$MGMT_IF")"
  [[ -n "$current_ip" ]] || die "Management interface $MGMT_IF does not currently have a global IPv4 address."
  [[ -n "$current_gw" ]] || die "Management interface $MGMT_IF does not currently have a default gateway."
  ping -I "$MGMT_IF" -c 1 -W 2 "$current_gw" >/dev/null || die "Current management gateway $current_gw is not reachable through $MGMT_IF."

  # OVA templates should use DHCP on the management NIC. This avoids baking a site-specific address into the appliance.
  # Disable pre-existing Netplan YAML after backing it up so cloud-init/networkd definitions cannot merge with Thorny's profile.
  local f
  shopt -s nullglob
  for f in /etc/netplan/*.yaml /etc/netplan/*.yml; do
    [[ "$f" == /etc/netplan/90-thorny.yaml ]] && continue
    mv -f "$f" "$f.thorny-disabled"
  done
  shopt -u nullglob

  write_file /etc/netplan/90-thorny.yaml 0600 root:root <<EOF
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
    rm -f /etc/netplan/90-thorny.yaml
    rm -f /etc/netplan/*.thorny-disabled 2>/dev/null || true
    if [[ -d "$BACKUP_STAMP_DIR/etc/netplan" ]]; then cp -a "$BACKUP_STAMP_DIR/etc/netplan/." /etc/netplan/; fi
    netplan generate || true; netplan apply || true
    die "Network conversion failed and rollback was attempted. Continue from the VMware console."
  fi
  sleep 4

  local new_ip new_gw
  new_ip="$(get_mgmt_ip "$MGMT_IF")"
  new_gw="$(get_gateway "$MGMT_IF")"
  if [[ -z "$new_ip" || -z "$new_gw" ]] || ! ping -I "$MGMT_IF" -c 1 -W 2 "$new_gw" >/dev/null 2>&1; then
    warn "Management validation failed after NetworkManager conversion; restoring the pre-build Netplan files."
    rm -f /etc/netplan/90-thorny.yaml
    rm -f /etc/netplan/*.thorny-disabled 2>/dev/null || true
    if [[ -d "$BACKUP_STAMP_DIR/etc/netplan" ]]; then cp -a "$BACKUP_STAMP_DIR/etc/netplan/." /etc/netplan/; fi
    netplan generate || true; netplan apply || true
    die "Management path did not validate after conversion; rollback was attempted. Use the VMware console before retrying."
  fi

  nmcli con delete thorny-capture >/dev/null 2>&1 || true
  nmcli con delete thorny-wired >/dev/null 2>&1 || true
  nmcli con add type ethernet ifname "$CAPTURE_IF" con-name thorny-capture ipv4.method disabled ipv6.method disabled connection.autoconnect yes
  nmcli con modify thorny-capture connection.autoconnect-priority 50
  nmcli con add type ethernet ifname "$CAPTURE_IF" con-name thorny-wired ipv4.method auto ipv6.method disabled connection.autoconnect no ipv4.route-metric 200
  nmcli con up thorny-capture
  ip link set dev "$CAPTURE_IF" promisc on

  write_file /usr/local/sbin/thorny-network 0750 root:thorny <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/thorny/thorny.conf
log(){ logger -t thorny-network -- "$*"; echo "$*"; }
mgmt_ok(){
  local ip gw
  ip="$(ip -4 -o addr show dev "$MGMT_IF" scope global | awk 'NR==1{split($4,a,"/");print a[1]}')"
  gw="$(ip -4 route show default dev "$MGMT_IF" | awk 'NR==1{for(i=1;i<=NF;i++)if($i=="via"){print $(i+1);exit}}')"
  [[ -n "$ip" && -n "$gw" ]] && ping -I "$MGMT_IF" -c1 -W2 "$gw" >/dev/null 2>&1
}
wired_ok(){
  local ip gw
  ip="$(ip -4 -o addr show dev "$CAPTURE_IF" scope global | awk 'NR==1{split($4,a,"/");print a[1]}')"
  gw="$(ip -4 route show default dev "$CAPTURE_IF" | awk 'NR==1{for(i=1;i<=NF;i++)if($i=="via"){print $(i+1);exit}}')"
  [[ -n "$ip" && -n "$gw" ]] && ping -I "$CAPTURE_IF" -c1 -W2 "$gw" >/dev/null 2>&1
}
case "${1:-status}" in
  capture)
    mgmt_ok || { log "Refusing capture mode: management path on $MGMT_IF is not healthy"; exit 1; }
    nmcli con down thorny-wired >/dev/null 2>&1 || true
    nmcli con up thorny-capture >/dev/null
    ip addr flush dev "$CAPTURE_IF" scope global || true
    ip link set dev "$CAPTURE_IF" up promisc on
    systemctl restart thorny-network-rollback.timer
    log "capture mode active on $CAPTURE_IF; two-minute rollback armed"
    ;;
  confirm)
    systemctl stop thorny-network-rollback.timer >/dev/null 2>&1 || true
    log "capture mode confirmed; rollback cancelled"
    ;;
  wired)
    systemctl stop thorny-network-rollback.timer >/dev/null 2>&1 || true
    ip link set dev "$CAPTURE_IF" promisc off || true
    nmcli con down thorny-capture >/dev/null 2>&1 || true
    nmcli con up thorny-wired >/dev/null
    sleep 3
    if wired_ok; then
      log "wired DHCP mode is usable on $CAPTURE_IF"
    else
      log "wired DHCP mode failed validation; restoring capture mode"
      nmcli con down thorny-wired >/dev/null 2>&1 || true
      nmcli con up thorny-capture >/dev/null
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
      nmcli con down thorny-wired >/dev/null 2>&1 || true
      nmcli con up thorny-capture >/dev/null
      ip addr flush dev "$CAPTURE_IF" scope global || true
      ip link set dev "$CAPTURE_IF" up promisc on
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
    echo "rollback_pending=$(systemctl is-active --quiet thorny-network-rollback.timer && echo 1 || echo 0)"
    ip -4 route
    ;;
  *) echo "usage: $0 {capture|confirm|wired|rollback|status}" >&2; exit 2;;
esac
EOF

  write_file /usr/local/sbin/thorny-network-boot-guard 0750 root:root <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/thorny/thorny.conf
log(){ logger -t thorny-network -- "$*"; }
mgmt_ip="$(ip -4 -o addr show dev "$MGMT_IF" scope global 2>/dev/null | awk 'NR==1{split($4,a,"/");print a[1]}')"
mgmt_gw="$(ip -4 route show default dev "$MGMT_IF" 2>/dev/null | awk 'NR==1{for(i=1;i<=NF;i++)if($i=="via"){print $(i+1);exit}}')"
if [[ -n "$mgmt_ip" && -n "$mgmt_gw" ]] && ping -I "$MGMT_IF" -c1 -W2 "$mgmt_gw" >/dev/null 2>&1; then
  /usr/local/sbin/thorny-network capture
  sleep 2
  if ip -4 -o addr show dev "$CAPTURE_IF" scope global | grep -q .; then
    log "boot guard: capture interface unexpectedly has an IPv4 address"
    exit 1
  fi
  /usr/local/sbin/thorny-network confirm
  log "boot guard: management is healthy on $MGMT_IF; $CAPTURE_IF is addressless capture"
  exit 0
fi
log "boot guard: primary management path is unhealthy; testing capture NIC as wired DHCP"
if /usr/local/sbin/thorny-network wired; then
  log "boot guard: wired fallback is usable on $CAPTURE_IF"
  exit 0
fi
log "boot guard: no validated management path; manual console intervention required"
exit 1
EOF

  write_file /etc/systemd/system/thorny-network-rollback.service 0644 root:root <<'EOF'
[Unit]
Description=Thorny network safety rollback
After=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/thorny-network rollback
EOF

  write_file /etc/systemd/system/thorny-network-rollback.timer 0644 root:root <<'EOF'
[Unit]
Description=Two-minute Thorny network rollback timer

[Timer]
OnActiveSec=2min
AccuracySec=1s
Unit=thorny-network-rollback.service

[Install]
WantedBy=timers.target
EOF

  write_file /etc/systemd/system/thorny-network-boot-guard.service 0644 root:root <<'EOF'
[Unit]
Description=Thorny boot network guard
Wants=network-online.target
After=NetworkManager.service network-online.target
Before=thorny-boot-email.service thorny-tls-refresh.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/thorny-network-boot-guard
TimeoutStartSec=45

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable thorny-network-boot-guard.service
  /usr/local/sbin/thorny-network capture
  sleep 1
  /usr/local/sbin/thorny-network confirm
  log "Network verification:"
  /usr/local/sbin/thorny-network status | tee -a "$LOG_FILE"
}

configure_firewall() {
  backup_path /etc/ufw/user.rules
  ufw --force reset >/dev/null
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow in on "$MGMT_IF" to any port 22 proto tcp comment 'Thorny SSH'
  ufw allow in on "$MGMT_IF" to any port 443 proto tcp comment 'Thorny portal'
  for p in 8443 8444 8445 8446 8447 8448; do
    ufw allow in on "$MGMT_IF" to any port "$p" proto tcp comment "Thorny app $p"
  done
  # The second NIC normally has no address. These rules become useful only if the operator
  # explicitly switches it to the thorny-wired DHCP management profile.
  ufw allow in on "$CAPTURE_IF" to any port 22 proto tcp comment 'Thorny wired-fallback SSH'
  ufw allow in on "$CAPTURE_IF" to any port 443 proto tcp comment 'Thorny wired-fallback portal'
  for p in 8443 8444 8445 8446 8447 8448; do
    ufw allow in on "$CAPTURE_IF" to any port "$p" proto tcp comment "Thorny wired-fallback app $p"
  done
  ufw allow in on "$MGMT_IF" to any port 514 proto tcp comment 'Thorny syslog TCP'
  ufw allow in on "$MGMT_IF" to any port 514 proto udp comment 'Thorny syslog UDP'
  ufw allow in on "$MGMT_IF" to any port 5353 proto udp comment 'Thorny mDNS'
  ufw allow in on "$CAPTURE_IF" to any port 514 proto tcp comment 'Thorny wired-fallback syslog TCP'
  ufw allow in on "$CAPTURE_IF" to any port 514 proto udp comment 'Thorny wired-fallback syslog UDP'
  ufw allow in on "$CAPTURE_IF" to any port 5353 proto udp comment 'Thorny wired-fallback mDNS'
  ufw --force enable
}
resolve_ntop_image() {
  local digest
  docker pull ntop/ntopng:latest >/dev/null
  digest="$(docker image inspect --format '{{index .RepoDigests 0}}' ntop/ntopng:latest 2>/dev/null || true)"
  [[ "$digest" == ntop/ntopng@sha256:* ]] || die "Could not resolve immutable ntopng digest."
  printf '%s' "$digest"
}

write_observability_configs() {
  install -d -m 0750 "$CONFIG_DIR/prometheus" "$CONFIG_DIR/loki" "$CONFIG_DIR/alloy" "$CONFIG_DIR/grafana/provisioning/datasources" "$CONFIG_DIR/grafana/provisioning/dashboards" "$CONFIG_DIR/grafana/dashboards"

  write_file "$CONFIG_DIR/prometheus/prometheus.yml" 0644 root:root <<'EOF'
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
EOF

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
    source_labels = ["__syslog_message_sd_thorny_source_ip"]
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
  - name: Thorny
    orgId: 1
    folder: Thorny
    type: file
    disableDeletion: true
    editable: true
    options:
      path: /var/lib/grafana/dashboards
EOF

  write_file "$CONFIG_DIR/grafana/dashboards/thorny-overview.json" 0644 root:root <<'EOF'
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
          "expr": "thorny_cpu_temperature_fahrenheit",
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
          "expr": "min(thorny_service_up)",
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
          "expr": "min(thorny_timer_up)",
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
          "expr": "thorny_management_up",
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
          "expr": "thorny_capture_mode",
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
          "expr": "thorny_capture_carrier",
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
      "title": "Wi-Fi Signal",
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
          "expr": "thorny_wifi_signal_percent",
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
                "color": "red",
                "value": null
              },
              {
                "color": "yellow",
                "value": 40
              },
              {
                "color": "green",
                "value": 65
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
          "expr": "time() - thorny_last_backup_timestamp_seconds",
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
          "expr": "thorny_syslog_udp_listener * thorny_syslog_tcp_listener",
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
          "expr": "thorny_packet_capture_active",
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
          "expr": "thorny_capture_promiscuous",
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
          "expr": "thorny_rollback_pending",
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
          "expr": "thorny_cpu_temperature_fahrenheit",
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
    "thorny",
    "noc"
  ],
  "templating": {
    "list": []
  },
  "time": {
    "from": "now-6h",
    "to": "now"
  },
  "title": "Thorny Overview",
  "uid": "thorny-overview",
  "version": 1
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
PUID=$THORNY_UID
PGID=$THORNY_GID
DB_PASSWORD=$DB_PASSWORD
GRAFANA_ADMIN_USER=$OPERATOR_USER
GRAFANA_ADMIN_PASSWORD=$GRAFANA_SECRET_KEY
GRAFANA_SECRET_KEY=$GRAFANA_SECRET_KEY
LIBRESPEED_RESULTS_PASSWORD=$LIBRESPEED_RESULTS_PASSWORD
SNMP_COMMUNITY=$SNMP_COMMUNITY
CAPTURE_IF=$CAPTURE_IF
NTOP_IMAGE=$ntop_image
EOF

  write_file "$COMPOSE_DIR/compose.yml" 0640 root:thorny <<EOF
name: thorny
services:
  db:
    image: $MARIADB_IMAGE
    container_name: thorny-db
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
    container_name: thorny-redis
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
    container_name: thorny-librenms
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
    container_name: thorny-librenms-dispatcher
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
    container_name: thorny-smokeping
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
    container_name: thorny-librespeed
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
    container_name: thorny-ntopng
    network_mode: host
    depends_on:
      redis: {condition: service_healthy}
    volumes:
      - $DATA_DIR/ntopng:/var/lib/ntopng
    command: ["--community", "-i", "\${CAPTURE_IF}", "-w", ":3000", "-d", "/var/lib/ntopng"]
    restart: unless-stopped

  portainer:
    image: $PORTAINER_IMAGE
    container_name: thorny-portainer
    command: ["--http-enabled"]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - $DATA_DIR/portainer:/data
    ports:
      - "127.0.0.1:9000:9000"
    restart: unless-stopped

  prometheus:
    image: $PROMETHEUS_IMAGE
    container_name: thorny-prometheus
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --storage.tsdb.retention.time=15d
      - --web.enable-lifecycle
    volumes:
      - $CONFIG_DIR/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - $DATA_DIR/prometheus:/prometheus
    ports:
      - "127.0.0.1:9090:9090"
    restart: unless-stopped

  node-exporter:
    image: $NODE_EXPORTER_IMAGE
    container_name: thorny-node-exporter
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
    container_name: thorny-cadvisor
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
    container_name: thorny-loki
    command: ["-config.file=/etc/loki/loki.yml"]
    volumes:
      - $CONFIG_DIR/loki/loki.yml:/etc/loki/loki.yml:ro
      - $DATA_DIR/loki:/loki
    ports:
      - "127.0.0.1:3100:3100"
    restart: unless-stopped

  alloy:
    image: $ALLOY_IMAGE
    container_name: thorny-alloy
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
    container_name: thorny-grafana
    environment:
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
  for url in http://127.0.0.1:8001 http://127.0.0.1:8002 http://127.0.0.1:8003 http://127.0.0.1:3000 http://127.0.0.1:9000 http://127.0.0.1:3001; do
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
  backup_glob '/etc/rsyslog.d/*thorny*'

  write_file /etc/rsyslog.d/20-thorny-remote.conf 0644 root:root <<'EOF'
module(load="imudp")
module(load="imtcp")

# Preserve original hostname in the RFC5424 header and remote source IP in structured data.
template(name="ThornyRFC5424" type="string"
  string="<%pri%>1 %timereported:::date-rfc3339% %hostname% %app-name% %procid% %msgid% [thorny source_ip=\"%fromhost-ip%\"] %msg%\n")

ruleset(name="thornyRemote") {
  action(
    type="omfwd"
    target="127.0.0.1"
    port="1514"
    protocol="tcp"
    TCP_Framing="octet-counted"
    template="ThornyRFC5424"
    action.resumeRetryCount="-1"
    queue.type="linkedList"
    queue.size="10000"
  )
}

input(type="imudp" port="514" ruleset="thornyRemote")
input(type="imtcp" port="514" ruleset="thornyRemote")
EOF
  rsyslogd -N1
  systemctl restart rsyslog
  ss -lun | grep -q ':514 ' || die "rsyslog UDP/514 did not start."
  ss -ltn | grep -q ':514 ' || die "rsyslog TCP/514 did not start."
  logger --udp --server 127.0.0.1 --port 514 -t thorny-test "thorny UDP syslog test $BUILD_STAMP"
  logger --tcp --server 127.0.0.1 --port 514 -t thorny-test "thorny TCP syslog test $BUILD_STAMP"
  log "rsyslog syntax valid and UDP/TCP 514 listeners are active."
}

make_tls_cert() {
  load_conf
  local ip cert key cfg
  ip="$(get_mgmt_ip "$MGMT_IF")"
  [[ -n "$ip" ]] || return 1
  cert="$ETC_ROOT/tls/thorny.crt"
  key="$ETC_ROOT/tls/thorny.key"
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
    ssl_certificate $ETC_ROOT/tls/thorny.crt;
    ssl_certificate_key $ETC_ROOT/tls/thorny.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    auth_basic "Thorny $label";
    auth_basic_user_file /etc/nginx/.thorny.htpasswd;
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
  htpasswd -bcB /etc/nginx/.thorny.htpasswd "$OPERATOR_USER" "$OPERATOR_PASSWORD" >/dev/null
  chmod 0640 /etc/nginx/.thorny.htpasswd
  chown root:www-data /etc/nginx/.thorny.htpasswd

  write_file "$PORTAL_DIR/index.html" 0644 root:root <<EOF
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Thorny NOC</title>
<style>
:root{color-scheme:dark;--bg:#08111b;--card:#101d2b;--line:#24384c;--text:#e9f2f9;--muted:#8fa8ba;--accent:#42c7e8}
*{box-sizing:border-box} body{margin:0;background:linear-gradient(145deg,#071019,#0b1724);font:15px system-ui,sans-serif;color:var(--text)}
main{max-width:1180px;margin:auto;padding:38px 24px 60px} h1{font-size:42px;margin:0}.sub{color:var(--muted);margin:8px 0 30px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:14px}
a.card{display:block;text-decoration:none;color:inherit;background:var(--card);border:1px solid var(--line);border-radius:14px;padding:20px;min-height:126px;transition:.15s}
a.card:hover{transform:translateY(-2px);border-color:var(--accent);box-shadow:0 8px 28px #0007}.card b{display:block;font-size:19px;margin-bottom:8px}.card span{color:var(--muted);line-height:1.45}.tag{display:inline-block;margin-top:12px;color:var(--accent);font-size:12px;letter-spacing:.08em;text-transform:uppercase}
footer{margin-top:34px;color:var(--muted);font-size:12px}
</style></head><body><main>
<h1>THORNY</h1><div class="sub">Portable network operations, monitoring and packet-capture appliance</div>
<div class="grid">
<a class="card" href="https://$HOSTNAME_SHORT.local:8443/" target="_blank" rel="noopener noreferrer"><b>LibreNMS</b><span>Network discovery, SNMP polling and alerting.</span><i class="tag">monitor</i></a>
<a class="card" href="https://$HOSTNAME_SHORT.local:8444/smokeping/" target="_blank" rel="noopener noreferrer"><b>SmokePing</b><span>Latency and packet-loss history.</span><i class="tag">latency</i></a>
<a class="card" href="https://$HOSTNAME_SHORT.local:8445/" target="_blank" rel="noopener noreferrer"><b>LibreSpeed</b><span>Local browser-based throughput testing.</span><i class="tag">speed</i></a>
<a class="card" href="https://$HOSTNAME_SHORT.local:8446/" target="_blank" rel="noopener noreferrer"><b>ntopng</b><span>Passive traffic and flow analysis on the capture NIC.</span><i class="tag">traffic</i></a>
<a class="card" href="https://$HOSTNAME_SHORT.local:8447/" target="_blank" rel="noopener noreferrer"><b>Portainer</b><span>Container status and lifecycle visibility.</span><i class="tag">containers</i></a>
<a class="card" href="https://$HOSTNAME_SHORT.local:8448/" target="_blank" rel="noopener noreferrer"><b>Grafana</b><span>Thorny Overview metrics and centralized syslog.</span><i class="tag">observability</i></a>
<a class="card" href="/scanner/" target="_blank" rel="noopener noreferrer"><b>Network Scanner</b><span>Nmap quick/deep scans with saved history and change tracking.</span><i class="tag">active scan</i></a>
<a class="card" href="/network/" target="_blank" rel="noopener noreferrer"><b>Network Control</b><span>Management path, capture mode and rollback status.</span><i class="tag">control</i></a>
<a class="card" href="/wireless/" target="_blank" rel="noopener noreferrer"><b>Wireless Survey</b><span>NetworkManager Wi-Fi survey when a radio is present or passed through.</span><i class="tag">wifi</i></a>
<a class="card" href="/capture/" target="_blank" rel="noopener noreferrer"><b>Packet Capture</b><span>Bounded PCAP capture with validated BPF filters.</span><i class="tag">pcap</i></a>
<a class="card" href="/status/" target="_blank" rel="noopener noreferrer"><b>Appliance Status</b><span>Interfaces, routes, services, containers and health.</span><i class="tag">status</i></a>
</div><footer>Thorny $VERSION · $HOSTNAME_SHORT.local</footer></main></body></html>
EOF

  backup_path /etc/nginx/sites-enabled/default
  rm -f /etc/nginx/sites-enabled/default
  cat > /etc/nginx/sites-available/thorny <<EOF
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
    ssl_certificate $ETC_ROOT/tls/thorny.crt;
    ssl_certificate_key $ETC_ROOT/tls/thorny.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy no-referrer always;
    auth_basic "Thorny";
    auth_basic_user_file /etc/nginx/.thorny.htpasswd;
    root $PORTAL_DIR;
    index index.html;
    location = / { try_files /index.html =404; }
    location /scanner/ { proxy_pass http://127.0.0.1:8787; include proxy_params; proxy_read_timeout 920s; }
    location /network/ { proxy_pass http://127.0.0.1:8787; include proxy_params; }
    location /wireless/ { proxy_pass http://127.0.0.1:8787; include proxy_params; }
    location /capture/ { proxy_pass http://127.0.0.1:8787; include proxy_params; proxy_read_timeout 650s; }
    location /captures/ { proxy_pass http://127.0.0.1:8787; include proxy_params; }
    location /status/ { proxy_pass http://127.0.0.1:8787; include proxy_params; }
    location /health { proxy_pass http://127.0.0.1:8787; include proxy_params; }
}
$(write_nginx_proxy_server 8443 'http://127.0.0.1:8001' 'LibreNMS')
$(write_nginx_proxy_server 8444 'http://127.0.0.1:8002' 'SmokePing')
$(write_nginx_proxy_server 8445 'http://127.0.0.1:8003' 'LibreSpeed')
$(write_nginx_proxy_server 8446 'http://127.0.0.1:3000' 'ntopng')
$(write_nginx_proxy_server 8447 'http://127.0.0.1:9000' 'Portainer')
$(write_nginx_proxy_server 8448 'http://127.0.0.1:3001' 'Grafana')
EOF
  ln -sfn /etc/nginx/sites-available/thorny /etc/nginx/sites-enabled/thorny
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx

  write_file /usr/local/sbin/thorny-tls-refresh 0750 root:root <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/thorny/thorny.conf
active_if="$MGMT_IF"
ip="$(ip -4 -o addr show dev "$active_if" scope global 2>/dev/null | awk 'NR==1{split($4,a,"/");print a[1]}')"
if [[ -z "$ip" ]]; then
  active_if="$CAPTURE_IF"
  ip="$(ip -4 -o addr show dev "$active_if" scope global 2>/dev/null | awk 'NR==1{split($4,a,"/");print a[1]}')"
fi
[[ -n "$ip" ]] || exit 1
cert=/etc/thorny/tls/thorny.crt
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
openssl req -x509 -nodes -newkey rsa:3072 -sha256 -days 825 -keyout /etc/thorny/tls/thorny.key.new -out /etc/thorny/tls/thorny.crt.new -config "$cfg" >/dev/null 2>&1
install -m0600 /etc/thorny/tls/thorny.key.new /etc/thorny/tls/thorny.key
install -m0644 /etc/thorny/tls/thorny.crt.new /etc/thorny/tls/thorny.crt
rm -f /etc/thorny/tls/*.new "$cfg"
nginx -t && systemctl reload nginx
EOF

  write_file /etc/systemd/system/thorny-tls-refresh.service 0644 root:root <<'EOF'
[Unit]
Description=Refresh Thorny TLS certificate for current DHCP address
After=thorny-network-boot-guard.service network-online.target
Requires=thorny-network-boot-guard.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/thorny-tls-refresh

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable thorny-tls-refresh.service
  curl -kfsS -u "$OPERATOR_USER:$OPERATOR_PASSWORD" https://127.0.0.1/ >/dev/null
  log "HTTPS portal validated."
}
write_control_app() {
  stage 6 "Scanner, network control, wireless survey and packet-capture interfaces"
  write_file "$APP_DIR/thorny_web.py" 0750 root:thorny <<'PY'
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
for line in Path('/etc/thorny/thorny.conf').read_text().splitlines():
    if '=' in line and not line.lstrip().startswith('#'):
        k, v = line.split('=', 1)
        CONF[k] = v.strip().strip("'").strip('"')
MGMT_IF = CONF['MGMT_IF']
CAPTURE_IF = CONF['CAPTURE_IF']
DATA = Path(CONF.get('DATA_DIR', '/opt/thorny/data'))
SCAN_DB = DATA / 'scanner' / 'scanner.db'
CAP_DIR = DATA / 'captures'
RUN = Path('/run/thorny')
PID_FILE = RUN / 'capture.pid'
META_FILE = RUN / 'capture.json'
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
    return f'''<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>{html.escape(title)}</title>{BASE_STYLE}</head><body><main><h1>{html.escape(title)}</h1><div class="sub">Thorny network operations appliance</div><div class="nav"><a href="/">Portal</a><a href="/scanner/">Scanner</a><a href="/network/">Network</a><a href="/wireless/">Wireless</a><a href="/capture/">Capture</a><a href="/status/">Status</a></div>{body}</main></body></html>'''

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
        cp=run(['/usr/local/sbin/thorny-network',action], timeout=45)
        cls='ok' if cp.returncode==0 else 'bad'
        msg=f'<div class="box {cls}"><pre>{html.escape(cp.stdout+cp.stderr)}</pre></div>'
    status=run(['/usr/local/sbin/thorny-network','status'],timeout=10)
    body=f'''{msg}<div class="box"><div class="row"><form method="post"><button name="action" value="capture">Enter capture</button></form><form method="post"><button name="action" value="confirm">Confirm capture</button></form><form method="post"><button name="action" value="wired">Test wired DHCP</button></form><form method="post"><button name="action" value="rollback">Rollback</button></form></div></div><div class="box"><pre>{html.escape(status.stdout+status.stderr)}</pre></div>'''
    return page('Network Control',body)

@APP.get('/wireless/')
def wireless():
    devs=run(['/usr/bin/nmcli','-t','-f','DEVICE,TYPE,STATE','device'],timeout=10)
    wifi=[line.split(':',1)[0] for line in devs.stdout.splitlines() if ':wifi:' in line]
    if not wifi:
        body='<div class="box">No NetworkManager Wi-Fi device is present. In a VM this page becomes active only if a supported Wi-Fi adapter is passed through to the guest.</div>'
        return page('Wireless Survey',body)
    cp=run(['/usr/bin/nmcli','-t','--escape','yes','-f','IN-USE,SSID,BSSID,SIGNAL,CHAN,FREQ,SECURITY','dev','wifi','list','--rescan','yes'],timeout=30)
    rows=''
    for line in cp.stdout.splitlines():
        cols=line.split(':')
        cols += ['']*(7-len(cols))
        rows += '<tr>'+''.join(f'<td>{html.escape(c)}</td>' for c in cols[:7])+'</tr>'
    body=f'<div class="box"><table><tr><th>In use</th><th>SSID</th><th>BSSID</th><th>Signal</th><th>Channel</th><th>Freq</th><th>Security</th></tr>{rows}</table></div><div class="box">This is a NetworkManager survey. It does not claim monitor-mode support.</div>'
    return page('Wireless Survey',body)

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
                out=CAP_DIR/f'thorny-{stamp}.pcap'
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

@APP.get('/status/')
def status():
    sections=[]
    cmds=[
      ('Addresses',['/usr/sbin/ip','-br','-4','addr']),
      ('Routes',['/usr/sbin/ip','-4','route']),
      ('Links',['/usr/sbin/ip','-details','link','show']),
      ('NetworkManager',['/usr/bin/nmcli','-f','DEVICE,TYPE,STATE,CONNECTION','device']),
      ('Thorny network',['/usr/local/sbin/thorny-network','status']),
      ('Systemd failed',['/usr/bin/systemctl','--failed','--no-pager']),
      ('Containers',['/usr/bin/docker','compose','-f','/opt/thorny/compose/compose.yml','--env-file','/opt/thorny/compose/.env','ps']),
    ]
    for title,args in cmds:
        try: cp=run(args,timeout=15); text=cp.stdout+cp.stderr
        except Exception as e: text=str(e)
        sections.append(f'<div class="box"><h3>{html.escape(title)}</h3><pre>{html.escape(text)}</pre></div>')
    return page('Appliance Status',''.join(sections))

if __name__=='__main__': APP.run('127.0.0.1',8787)
PY

  write_file /etc/systemd/system/thorny-web.service 0644 root:root <<EOF
[Unit]
Description=Thorny local control and scanner web service
After=network-online.target NetworkManager.service docker.service
Wants=network-online.target

[Service]
Type=simple
User=root
Group=thorny
WorkingDirectory=$APP_DIR
ExecStart=/usr/bin/gunicorn --workers 2 --threads 2 --timeout 930 --bind 127.0.0.1:8787 thorny_web:APP
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
ReadWritePaths=$DATA_DIR/scanner $DATA_DIR/captures $RUN_ROOT

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now thorny-web.service
  sleep 2
  curl -fsS http://127.0.0.1:8787/health | jq . | tee -a "$LOG_FILE"
}
configure_metrics() {
  stage 7 "Custom appliance metrics and Grafana support"
  write_file /usr/local/sbin/thorny-field-metrics 0750 root:root <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/thorny/thorny.conf
OUT=/var/lib/thorny/textfile_collector/thorny.prom
TMP="${OUT}.tmp.$$"
esc(){ printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
active_mgmt_if="$MGMT_IF"
mgmt_ip="$(ip -4 -o addr show dev "$active_mgmt_if" scope global 2>/dev/null | awk 'NR==1{split($4,a,"/");print a[1]}')"
mgmt_gw="$(ip -4 route show default dev "$active_mgmt_if" 2>/dev/null | awk 'NR==1{for(i=1;i<=NF;i++)if($i=="via"){print $(i+1);exit}}')"
mgmt_up=0
if [[ -n "$mgmt_ip" && -n "$mgmt_gw" ]] && ping -I "$active_mgmt_if" -c1 -W1 "$mgmt_gw" >/dev/null 2>&1; then
  mgmt_up=1
else
  active_mgmt_if="$CAPTURE_IF"
  mgmt_ip="$(ip -4 -o addr show dev "$active_mgmt_if" scope global 2>/dev/null | awk 'NR==1{split($4,a,"/");print a[1]}')"
  mgmt_gw="$(ip -4 route show default dev "$active_mgmt_if" 2>/dev/null | awk 'NR==1{for(i=1;i<=NF;i++)if($i=="via"){print $(i+1);exit}}')"
  [[ -n "$mgmt_ip" && -n "$mgmt_gw" ]] && ping -I "$active_mgmt_if" -c1 -W1 "$mgmt_gw" >/dev/null 2>&1 && mgmt_up=1 || true
fi
cap_profile="$(nmcli -t -f GENERAL.CONNECTION dev show "$CAPTURE_IF" 2>/dev/null | cut -d: -f2- || true)"
cap_mode=0; wired_mode=0
[[ "$cap_profile" == "thorny-capture" ]] && cap_mode=1
[[ "$cap_profile" == "thorny-wired" ]] && wired_mode=1
promisc=0; ip -details link show "$CAPTURE_IF" 2>/dev/null | grep -qw PROMISC && promisc=1
carrier="$(cat "/sys/class/net/$CAPTURE_IF/carrier" 2>/dev/null || echo 0)"
rollback=0; systemctl is-active --quiet thorny-network-rollback.timer && rollback=1 || true
rs=0; systemctl is-active --quiet rsyslog && rs=1 || true
udp=0; ss -lunH | grep -Eq '(^|[[:space:]])[^ ]*:514[[:space:]]' && udp=1 || true
tcp=0; ss -ltnH | grep -Eq '(^|[[:space:]])[^ ]*:514[[:space:]]' && tcp=1 || true
capture_active=0
[[ -r /run/thorny/capture.pid ]] && kill -0 "$(cat /run/thorny/capture.pid)" 2>/dev/null && capture_active=1 || true
backup_ts=0; backup_ok=0
if [[ -r /var/lib/thorny/backup.status ]]; then
  backup_ts="$(awk -F= '$1=="timestamp"{print $2}' /var/lib/thorny/backup.status | tail -1)"
  backup_ok="$(awk -F= '$1=="ok"{print $2}' /var/lib/thorny/backup.status | tail -1)"
fi
[[ "$backup_ts" =~ ^[0-9]+$ ]] || backup_ts=0
[[ "$backup_ok" =~ ^[01]$ ]] || backup_ok=0
wifi_dev="$(nmcli -t -f DEVICE,TYPE dev 2>/dev/null | awk -F: '$2=="wifi"{print $1;exit}')"
wifi_ssid=""; wifi_signal=0; wifi_connected=0
if [[ -n "$wifi_dev" ]]; then
  wifi_ssid="$(nmcli -t -f ACTIVE,SSID,SIGNAL dev wifi 2>/dev/null | awk -F: '$1=="yes"{print $2;exit}')"
  wifi_signal="$(nmcli -t -f ACTIVE,SSID,SIGNAL dev wifi 2>/dev/null | awk -F: '$1=="yes"{print $3;exit}')"
  [[ -n "$wifi_ssid" ]] && wifi_connected=1
  [[ "$wifi_signal" =~ ^[0-9]+$ ]] || wifi_signal=0
fi
cat >"$TMP" <<METRICS
# HELP thorny_management_up Primary management gateway validation.
# TYPE thorny_management_up gauge
thorny_management_up{interface="$(esc "$active_mgmt_if")",ipv4="$(esc "$mgmt_ip")"} $mgmt_up
# HELP thorny_capture_mode Capture interface is using the addressless capture profile.
# TYPE thorny_capture_mode gauge
thorny_capture_mode{interface="$(esc "$CAPTURE_IF")",profile="$(esc "$cap_profile")"} $cap_mode
thorny_wired_management_mode{interface="$(esc "$CAPTURE_IF")"} $wired_mode
thorny_capture_carrier{interface="$(esc "$CAPTURE_IF")"} $carrier
thorny_capture_promiscuous{interface="$(esc "$CAPTURE_IF")"} $promisc
thorny_rollback_pending $rollback
thorny_rsyslog_up $rs
thorny_syslog_udp_listener $udp
thorny_syslog_tcp_listener $tcp
thorny_packet_capture_active $capture_active
thorny_last_backup_success $backup_ok
thorny_last_backup_timestamp_seconds $backup_ts
thorny_wifi_connected{interface="$(esc "$wifi_dev")",ssid="$(esc "$wifi_ssid")"} $wifi_connected
thorny_wifi_signal_percent{interface="$(esc "$wifi_dev")",ssid="$(esc "$wifi_ssid")"} $wifi_signal
$(for svc in docker nginx rsyslog thorny-web; do v=0; systemctl is-active --quiet "$svc.service" && v=1 || true; printf 'thorny_service_up{service="%s"} %s\n' "$svc" "$v"; done)
$(for timer in thorny-field-metrics thorny-backup; do v=0; systemctl is-active --quiet "$timer.timer" && v=1 || true; printf 'thorny_timer_up{timer="%s"} %s\n' "$timer" "$v"; done)
thorny_collector_generation_timestamp_seconds $(date +%s)
METRICS
if [[ -r /sys/class/thermal/thermal_zone0/temp ]]; then
  awk '{printf "thorny_cpu_temperature_fahrenheit %.3f\\n", ($1/1000*9/5)+32}' /sys/class/thermal/thermal_zone0/temp >>"$TMP"
fi
chmod 0644 "$TMP"
mv -f "$TMP" "$OUT"
EOF

  write_file /etc/systemd/system/thorny-field-metrics.service 0644 root:root <<'EOF'
[Unit]
Description=Generate Thorny node-exporter textfile metrics
After=NetworkManager.service rsyslog.service docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/thorny-field-metrics
EOF

  write_file /etc/systemd/system/thorny-field-metrics.timer 0644 root:root <<'EOF'
[Unit]
Description=Refresh Thorny appliance metrics

[Timer]
OnBootSec=30s
OnUnitActiveSec=45s
AccuracySec=5s
Unit=thorny-field-metrics.service

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now thorny-field-metrics.timer
  systemctl start thorny-field-metrics.service
  grep -q '^thorny_management_up' "$STATE_ROOT/textfile_collector/thorny.prom"
}

write_boot_email_service() {
  write_file /usr/local/sbin/thorny-boot-email 0750 root:root <<'PY'
#!/usr/bin/env python3
import json, os, smtplib, socket, ssl, subprocess, sys
from datetime import datetime, timezone
from email.message import EmailMessage
from pathlib import Path
cfgp=Path('/etc/thorny/ip-email.json')
if not cfgp.exists():
    print('boot email not configured'); sys.exit(0)
cfg=json.loads(cfgp.read_text())
if not cfg.get('enabled',False):
    print('boot email disabled'); sys.exit(0)
def out(args):
    return subprocess.run(args,text=True,capture_output=True,timeout=10).stdout.strip()
conf={}
for line in Path('/etc/thorny/thorny.conf').read_text().splitlines():
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
ssid=''
wifi=out(['nmcli','-t','-f','DEVICE,TYPE','dev'])
for line in wifi.splitlines():
    if line.endswith(':wifi'):
        ss=out(['nmcli','-t','-f','ACTIVE,SSID','dev','wifi'])
        for x in ss.splitlines():
            if x.startswith('yes:'): ssid=x[4:]; break
        break
profile=out(['nmcli','-t','-f','GENERAL.CONNECTION','dev','show',cap]).split(':',1)
profile=profile[1] if len(profile)>1 else ''
body=f'''Hostname: {socket.gethostname()}\nTimestamp: {datetime.now(timezone.utc).isoformat()}\nManagement interface: {active_mg}\nIPv4: {ip}\nDefault route: {gw}\nWi-Fi SSID: {ssid or '(none)'}\nEthernet/capture profile: {profile}\n'''
msg=EmailMessage(); msg['Subject']=f'Thorny boot address: {socket.gethostname()} {ip}'; msg['From']=cfg.get('from',cfg['username']); msg['To']=cfg['to']; msg.set_content(body)
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

  write_file /etc/systemd/system/thorny-boot-email.service 0644 root:root <<'EOF'
[Unit]
Description=Email Thorny final boot management address
After=network-online.target thorny-network-boot-guard.service
Requires=thorny-network-boot-guard.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/thorny-boot-email
TimeoutStartSec=45
Restart=on-failure
RestartSec=20

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable thorny-boot-email.service
}

configure_smtp_interactive() {
  require_root
  local ans to user server port pass from
  read -r -p "Enable boot-address email? [y/N]: " ans
  if [[ ! "$ans" =~ ^[Yy]$ ]]; then
    write_file /etc/thorny/ip-email.json 0600 root:root <<'EOF'
{"enabled": false}
EOF
    log "Boot-address email disabled; run '$SELF smtp' after deployment to configure it."
    return 0
  fi
  read -r -p "Destination email: " to
  read -r -p "SMTP username: " user
  read -r -p "SMTP server [smtp.gmail.com]: " server; server="${server:-smtp.gmail.com}"
  read -r -p "SMTP port [587]: " port; port="${port:-587}"
  read -r -p "From address [$user]: " from; from="${from:-$user}"
  read -r -s -p "SMTP application password (not echoed): " pass; echo
  [[ -n "$to" && -n "$user" && -n "$server" && "$port" =~ ^[0-9]+$ && -n "$pass" ]] || die "Incomplete SMTP settings."
  python3 - "$to" "$user" "$server" "$port" "$from" "$pass" <<'PY'
import json,sys
p='/etc/thorny/ip-email.json'
obj={'enabled':True,'to':sys.argv[1],'username':sys.argv[2],'server':sys.argv[3],'port':int(sys.argv[4]),'from':sys.argv[5],'password':sys.argv[6]}
with open(p,'w') as f: json.dump(obj,f,indent=2)
PY
  chmod 0600 /etc/thorny/ip-email.json
  chown root:root /etc/thorny/ip-email.json
  systemctl start thorny-boot-email.service
  log "Boot-address email manual test completed."
}
write_backup_system() {
  stage 8 "Backup and recovery"
  install -d -m 0700 "$BACKUP_DIR/local"
  if [[ ! -f "$ETC_ROOT/backup_ed25519" ]]; then
    ssh-keygen -q -t ed25519 -N '' -C "thorny-backup@$HOSTNAME_SHORT" -f "$ETC_ROOT/backup_ed25519"
    chmod 0600 "$ETC_ROOT/backup_ed25519"
  fi
  [[ -f "$ETC_ROOT/backup-remote.json" ]] || printf '%s\n' '{"enabled": false}' > "$ETC_ROOT/backup-remote.json"
  chmod 0600 "$ETC_ROOT/backup-remote.json"

  write_file /usr/local/sbin/thorny-backup 0750 root:root <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/thorny/thorny.conf
LOCK=/run/thorny-backup.lock
STATUS=/var/lib/thorny/backup.status
LOCAL="$BACKUP_DIR/local"
mkdir -p "$LOCAL"
exec 9>"$LOCK"
flock -n 9 || { echo "backup already running"; exit 0; }
now="$(date +%s)"; stamp="$(date +%Y%m%d-%H%M%S)"
tmp="$LOCAL/.thorny-$stamp.tar.gz.tmp"
out="$LOCAL/thorny-$stamp.tar.gz"
sha="$out.sha256"
compose=(docker compose -f "$COMPOSE_DIR/compose.yml" --env-file "$COMPOSE_DIR/.env")
cleanup(){ "${compose[@]}" up -d >/dev/null 2>&1 || true; }
trap cleanup EXIT
# Quiesce stateful application writers; observability bulk stores are intentionally excluded.
"${compose[@]}" stop dispatcher librenms portainer db >/dev/null || true
include=(
  /opt/thorny/compose
  /opt/thorny/config
  /opt/thorny/apps
  /opt/thorny/portal
  /opt/thorny/data/librenms
  /opt/thorny/data/db
  /opt/thorny/data/portainer
  /opt/thorny/data/smokeping/config
  /opt/thorny/data/librespeed
  /opt/thorny/data/scanner
  /etc/thorny
  /etc/nginx
  /etc/rsyslog.conf
  /etc/rsyslog.d
  /etc/netplan
  /etc/systemd/system
  /usr/local/sbin/thorny-installer
  /usr/local/sbin/thorny-network
  /usr/local/sbin/thorny-network-boot-guard
  /usr/local/sbin/thorny-field-metrics
  /usr/local/sbin/thorny-boot-email
  /usr/local/sbin/thorny-tls-refresh
  /usr/local/sbin/thorny-backup
  /usr/local/sbin/thorny-firstboot
)
# Only Thorny-owned NM profiles are recoverable; never archive unrelated Wi-Fi credentials.
[[ -e /etc/NetworkManager/system-connections/thorny-capture.nmconnection ]] && include+=(/etc/NetworkManager/system-connections/thorny-capture.nmconnection)
[[ -e /etc/NetworkManager/system-connections/thorny-wired.nmconnection ]] && include+=(/etc/NetworkManager/system-connections/thorny-wired.nmconnection)
tar --warning=no-file-changed -czf "$tmp" \
  --exclude='/etc/thorny/backup_ed25519' \
  --exclude='/opt/thorny/data/prometheus' \
  --exclude='/opt/thorny/data/loki' \
  --exclude='/opt/thorny/data/ntopng' \
  --exclude='/opt/thorny/data/captures' \
  --exclude='/opt/thorny/data/smokeping/data' \
  "${include[@]}"
mv -f "$tmp" "$out"
(cd "$LOCAL" && sha256sum "$(basename "$out")") > "$sha"
(cd "$LOCAL" && sha256sum -c "$(basename "$sha")" >/dev/null)
ln -sfn "$(basename "$out")" "$LOCAL/latest.tar.gz"
ln -sfn "$(basename "$sha")" "$LOCAL/latest.tar.gz.sha256"
"${compose[@]}" up -d >/dev/null
trap - EXIT
remote_ok=0
if [[ -r /etc/thorny/backup-remote.json ]] && jq -e '.enabled==true' /etc/thorny/backup-remote.json >/dev/null 2>&1; then
  host="$(jq -r .host /etc/thorny/backup-remote.json)"
  user="$(jq -r .user /etc/thorny/backup-remote.json)"
  path="$(jq -r .path /etc/thorny/backup-remote.json)"
  key=/etc/thorny/backup_ed25519
  opts=(-i "$key" -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)
  if ssh "${opts[@]}" "$user@$host" "mkdir -p -- '$path'" >/dev/null 2>&1; then
    scp "${opts[@]}" "$out" "$user@$host:$path/.thorny-latest.tar.gz.tmp" >/dev/null
    scp "${opts[@]}" "$sha" "$user@$host:$path/.thorny-latest.tar.gz.sha256.tmp" >/dev/null
    if ssh "${opts[@]}" "$user@$host" "cd '$path' && sed 's#$(basename "$out")#.thorny-latest.tar.gz.tmp#' .thorny-latest.tar.gz.sha256.tmp | sha256sum -c - >/dev/null && mv -f .thorny-latest.tar.gz.tmp thorny-latest.tar.gz && mv -f .thorny-latest.tar.gz.sha256.tmp thorny-latest.tar.gz.sha256"; then
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
find "$LOCAL" -maxdepth 1 -type f -name 'thorny-*.tar.gz' -printf '%T@ %p\n' | sort -nr | awk 'NR>7{print $2}' | xargs -r rm -f
find "$LOCAL" -maxdepth 1 -type f -name 'thorny-*.tar.gz.sha256' -printf '%T@ %p\n' | sort -nr | awk 'NR>7{print $2}' | xargs -r rm -f
EOF

  write_file /etc/systemd/system/thorny-backup.service 0644 root:root <<'EOF'
[Unit]
Description=Thorny configuration and state backup
After=docker.service network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/thorny-backup
TimeoutStartSec=30min
EOF

  write_file /etc/systemd/system/thorny-backup.timer 0644 root:root <<'EOF'
[Unit]
Description=Daily Thorny backup

[Timer]
OnCalendar=*-*-* 03:15:00
Persistent=true
RandomizedDelaySec=10min
Unit=thorny-backup.service

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now thorny-backup.timer
}

configure_remote_backup_interactive() {
  require_root
  local ans host user path
  read -r -p "Enable remote backup synchronization to Farva/SSH? [y/N]: " ans
  if [[ ! "$ans" =~ ^[Yy]$ ]]; then
    printf '%s\n' '{"enabled": false}' > /etc/thorny/backup-remote.json
    chmod 0600 /etc/thorny/backup-remote.json
    return 0
  fi
  read -r -p "Remote hostname or IP [farva]: " host; host="${host:-farva}"
  read -r -p "Remote SSH user: " user
  read -r -p "Remote directory [/srv/backups/thorny]: " path; path="${path:-/srv/backups/thorny}"
  [[ -n "$user" ]] || die "Remote user is required."
  jq -n --arg h "$host" --arg u "$user" --arg p "$path" '{enabled:true,host:$h,user:$u,path:$p}' > /etc/thorny/backup-remote.json
  chmod 0600 /etc/thorny/backup-remote.json
  echo
  echo "Install this public key in $user@$host:~/.ssh/authorized_keys:"
  cat /etc/thorny/backup_ed25519.pub
  echo
  echo "Remote sync will defer safely until that key is authorized."
}

initialize_app_accounts() {
  stage 9 "Application account bootstrap"
  # Portainer admin init is intentionally idempotent; HTTP 409 means it is already initialized.
  local payload code
  payload="$(jq -nc --arg u "$OPERATOR_USER" --arg p "$OPERATOR_PASSWORD" '{Username:$u,Password:$p}')"
  code="$(curl -sS -o /tmp/thorny-portainer-init.out -w '%{http_code}' -H 'Content-Type: application/json' -X POST -d "$payload" http://127.0.0.1:9000/api/users/admin/init || true)"
  case "$code" in 200|204|409) ;; *) warn "Portainer initialization returned HTTP $code: $(cat /tmp/thorny-portainer-init.out 2>/dev/null || true)";; esac
  rm -f /tmp/thorny-portainer-init.out

  # Grafana v13 uses `grafana cli`; reset the real admin password after its SQLite DB exists.
  if ! docker exec thorny-grafana grafana cli --homepath /usr/share/grafana admin reset-admin-password "$OPERATOR_PASSWORD" >/tmp/thorny-grafana-rekey.out 2>&1; then
    warn "Grafana admin password reset failed: $(cat /tmp/thorny-grafana-rekey.out)"
  fi
  rm -f /tmp/thorny-grafana-rekey.out

  # LibreNMS supports CLI user creation after database migrations complete.
  for _ in {1..60}; do
    if docker exec thorny-librenms /opt/librenms/lnms --version >/dev/null 2>&1; then break; fi
    sleep 3
  done
  if ! docker exec -u librenms thorny-librenms /opt/librenms/lnms user:add "$OPERATOR_USER" --role=admin --password="$OPERATOR_PASSWORD" >/tmp/thorny-lnms-user.out 2>&1; then
    grep -Eqi 'already|exists|duplicate' /tmp/thorny-lnms-user.out || warn "LibreNMS user bootstrap: $(cat /tmp/thorny-lnms-user.out)"
  fi
  rm -f /tmp/thorny-lnms-user.out

  warn "ntopng Community uses its own first-login credential. Its current upstream default is admin/admin and it forces a password change on first access. Nginx Basic Auth still protects the proxy."
}

install_firstboot_identity_service() {
  write_file /usr/local/sbin/thorny-firstboot 0750 root:root <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
marker=/var/lib/thorny/firstboot.pending
[[ -e "$marker" ]] || exit 0
# systemd normally establishes machine-id very early; make it persistent if still empty.
[[ -s /etc/machine-id ]] || systemd-machine-id-setup >/dev/null 2>&1 || true
ssh-keygen -A >/dev/null 2>&1 || true
rm -f "$marker"
logger -t thorny-firstboot "regenerated clone-unique machine/SSH identity"
EOF

  write_file /etc/systemd/system/thorny-firstboot.service 0644 root:root <<'EOF'
[Unit]
Description=Regenerate clone-unique Thorny guest identity
ConditionPathExists=/var/lib/thorny/firstboot.pending
Before=ssh.service
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/thorny-firstboot

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable thorny-firstboot.service
}

rekey() {
  require_root
  load_conf
  [[ -r "$SECRETS_FILE" ]] || die "Missing $SECRETS_FILE"
  # shellcheck disable=SC1090
  source "$SECRETS_FILE"
  local old_password="$OPERATOR_PASSWORD" new_password jwt user_id hash code
  prompt_secret "New password for operator '$OPERATOR_USER'" new_password 12

  # Change application passwords first while the old Portainer credential is still valid.
  if docker ps --format '{{.Names}}' | grep -Fxq thorny-portainer; then
    jwt="$(curl -fsS -H 'Content-Type: application/json' \
      -d "$(jq -nc --arg u "$OPERATOR_USER" --arg p "$old_password" '{Username:$u,Password:$p}')" \
      http://127.0.0.1:9000/api/auth | jq -r '.jwt // empty' || true)"
    if [[ -n "$jwt" ]]; then
      user_id="$(curl -fsS -H "Authorization: Bearer $jwt" http://127.0.0.1:9000/api/users/me | jq -r '.Id // .id // empty' || true)"
      if [[ -n "$user_id" ]]; then
        code="$(curl -sS -o /tmp/thorny-portainer-pass.out -w '%{http_code}' -X PUT \
          -H "Authorization: Bearer $jwt" -H 'Content-Type: application/json' \
          -d "$(jq -nc --arg o "$old_password" --arg n "$new_password" '{Password:$o,NewPassword:$n}')" \
          "http://127.0.0.1:9000/api/users/$user_id/passwd" || true)"
        [[ "$code" == 204 || "$code" == 200 ]] || warn "Portainer password change returned HTTP $code: $(cat /tmp/thorny-portainer-pass.out 2>/dev/null || true)"
      else
        warn "Could not determine Portainer operator user id; Portainer password was not changed."
      fi
    else
      warn "Could not authenticate to Portainer with the stored credential; Portainer password was not changed."
    fi
    rm -f /tmp/thorny-portainer-pass.out
  fi

  if docker ps --format '{{.Names}}' | grep -Fxq thorny-grafana; then
    docker exec thorny-grafana grafana cli --homepath /usr/share/grafana admin reset-admin-password "$new_password" >/dev/null \
      || warn "Grafana admin password could not be reset automatically."
  fi

  if docker ps --format '{{.Names}}' | grep -Fxq thorny-librenms && docker ps --format '{{.Names}}' | grep -Fxq thorny-db; then
    hash="$(docker exec thorny-librenms php -r 'echo password_hash($argv[1], PASSWORD_BCRYPT);' "$new_password" 2>/dev/null || true)"
    if [[ "$hash" == \$2* ]]; then
      docker exec -e MYSQL_PWD="$DB_PASSWORD" thorny-db mariadb -ulibrenms librenms \
        -e "UPDATE users SET password='${hash}' WHERE username='${OPERATOR_USER}';" >/dev/null \
        || warn "LibreNMS password could not be updated automatically."
    else
      warn "LibreNMS password hash generation failed."
    fi
  fi

  htpasswd -bcB /etc/nginx/.thorny.htpasswd "$OPERATOR_USER" "$new_password" >/dev/null
  chmod 0640 /etc/nginx/.thorny.htpasswd
  chown root:www-data /etc/nginx/.thorny.htpasswd

  OPERATOR_PASSWORD="$new_password"
  {
    printf 'OPERATOR_PASSWORD=%q\n' "$OPERATOR_PASSWORD"
    printf 'DB_PASSWORD=%q\n' "$DB_PASSWORD"
    printf 'REDIS_PASSWORD=%q\n' "$REDIS_PASSWORD"
    printf 'GRAFANA_SECRET_KEY=%q\n' "$GRAFANA_SECRET_KEY"
    printf 'LIBRESPEED_RESULTS_PASSWORD=%q\n' "$LIBRESPEED_RESULTS_PASSWORD"
    printf 'SNMP_COMMUNITY=%q\n' "$SNMP_COMMUNITY"
  } | write_file "$SECRETS_FILE" 0600 root:root
  systemctl reload nginx
  log "Operator credential rotated for the Thorny front door, Grafana, LibreNMS and Portainer where reachable. ntopng maintains its own credential."
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

  echo "=== Thorny race-ready validation ==="
  check "Nginx configuration syntax" nginx -t
  check "Portal authentication challenge" bash -c '[[ "$(curl -ksS -o /dev/null -w "%{http_code}" https://127.0.0.1/)" == 401 ]]'
  if [[ -n "${OPERATOR_PASSWORD:-}" ]]; then
    check "Authenticated HTTPS portal" curl -kfsS -u "$OPERATOR_USER:$OPERATOR_PASSWORD" https://127.0.0.1/
  else
    fail "Stored operator credential available for portal test"
  fi

  local c
  for c in thorny-db thorny-redis thorny-librenms thorny-librenms-dispatcher thorny-smokeping thorny-librespeed thorny-ntopng thorny-portainer thorny-prometheus thorny-node-exporter thorny-cadvisor thorny-loki thorny-alloy thorny-grafana; do
    if [[ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || true)" == true ]]; then pass "Container running: $c"; else fail "Container running: $c"; fi
  done
  for c in NetworkManager docker nginx rsyslog thorny-web; do
    check "systemd service active: $c" systemctl is-active --quiet "$c.service"
  done

  check "LibreNMS backend" curl -fsS --max-time 8 http://127.0.0.1:8001/
  check "SmokePing backend" curl -fsS --max-time 8 http://127.0.0.1:8002/
  check "LibreSpeed backend" curl -fsS --max-time 8 http://127.0.0.1:8003/
  check "ntopng backend" curl -fsS --max-time 8 http://127.0.0.1:3000/
  check "Portainer backend" curl -fsS --max-time 8 http://127.0.0.1:9000/api/status
  check "Grafana backend" curl -fsS --max-time 8 http://127.0.0.1:3001/api/health
  check "Scanner/control service" curl -fsS --max-time 8 http://127.0.0.1:8787/health
  check "Prometheus ready" curl -fsS --max-time 8 http://127.0.0.1:9090/-/ready
  check "Loki ready" curl -fsS --max-time 8 http://127.0.0.1:3100/ready
  check "Alloy ready" curl -fsS --max-time 8 http://127.0.0.1:12345/-/ready

  if curl -fsS http://127.0.0.1:9090/api/v1/targets | jq -e '[.data.activeTargets[] | select(.health != "up")] | length == 0' >/dev/null 2>&1; then
    pass "All Prometheus active targets healthy"
  else
    fail "All Prometheus active targets healthy"
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
  token="thorny-validate-$(date +%s)-$RANDOM"
  start_ns="$(( $(date +%s) - 30 ))000000000"
  logger --udp --server 127.0.0.1 --port 514 -t thorny-validate "$token udp" || true
  logger --tcp --server 127.0.0.1 --port 514 -t thorny-validate "$token tcp" || true
  sleep 3
  end_ns="$(date +%s)000000000"
  if curl -fsSG http://127.0.0.1:3100/loki/api/v1/query_range \
      --data-urlencode "query={job=\"syslog\"} |= \"$token\"" --data-urlencode "start=$start_ns" --data-urlencode "end=$end_ns" \
      | jq -e '[.data.result[].values[]?] | length >= 2' >/dev/null 2>&1; then
    pass "UDP and TCP syslog reached Loki"
  else
    fail "UDP and TCP syslog reached Loki"
  fi

  local mgip gw
  mgip="$(get_mgmt_ip "$MGMT_IF")"; gw="$(get_gateway "$MGMT_IF")"
  if [[ -n "$mgip" && -n "$gw" ]] && ping -I "$MGMT_IF" -c1 -W2 "$gw" >/dev/null 2>&1; then pass "Management IPv4/default gateway reachable"; else fail "Management IPv4/default gateway reachable"; fi
  if getent ahostsv4 example.com >/dev/null 2>&1; then pass "DNS resolution"; else fail "DNS resolution"; fi

  if ! ip -4 -o addr show dev "$CAPTURE_IF" scope global | grep -q .; then pass "Capture interface has no global IPv4"; else fail "Capture interface has no global IPv4"; fi
  if ip -details link show "$CAPTURE_IF" | grep -qw PROMISC; then pass "Capture interface promiscuous mode"; else fail "Capture interface promiscuous mode"; fi
  if nmcli -t -f GENERAL.CONNECTION dev show "$CAPTURE_IF" | grep -Fqx 'GENERAL.CONNECTION:thorny-capture'; then pass "Capture NetworkManager profile active"; else fail "Capture NetworkManager profile active"; fi
  if ! systemctl is-active --quiet thorny-network-rollback.timer; then pass "No capture rollback pending"; else fail "No capture rollback pending"; fi

  check "Boot network guard enabled" systemctl is-enabled --quiet thorny-network-boot-guard.service
  if systemctl show -p After --value thorny-boot-email.service 2>/dev/null | tr ' ' '\n' | grep -Fxq thorny-network-boot-guard.service; then pass "Boot email ordered after network guard"; else fail "Boot email ordered after network guard"; fi
  check "Field metrics timer enabled" systemctl is-enabled --quiet thorny-field-metrics.timer
  check "Backup timer enabled" systemctl is-enabled --quiet thorny-backup.timer

  latest="$BACKUP_DIR/local/latest.tar.gz"
  if [[ -L "$latest" || -f "$latest" ]] && [[ -f "$BACKUP_DIR/local/latest.tar.gz.sha256" ]]; then
    if (cd "$BACKUP_DIR/local" && sha256sum -c latest.tar.gz.sha256 >/dev/null 2>&1); then pass "Latest backup SHA-256 checksum"; else fail "Latest backup SHA-256 checksum"; fi
    archive_list="$(tar -tzf "$latest" 2>/dev/null || true)"
    grep -Fq 'opt/thorny/compose/compose.yml' <<<"$archive_list" && pass "Backup contains Compose configuration" || fail "Backup contains Compose configuration"
    grep -Fq 'etc/nginx/' <<<"$archive_list" && pass "Backup contains Nginx configuration" || fail "Backup contains Nginx configuration"
    grep -Fq 'etc/rsyslog.d/20-thorny-remote.conf' <<<"$archive_list" && pass "Backup contains rsyslog configuration" || fail "Backup contains rsyslog configuration"
    grep -Fq 'etc/systemd/system/thorny-network-boot-guard.service' <<<"$archive_list" && pass "Backup contains Thorny systemd units" || fail "Backup contains Thorny systemd units"
    grep -Fq 'etc/NetworkManager/system-connections/thorny-capture.nmconnection' <<<"$archive_list" && pass "Backup contains capture NetworkManager profile" || fail "Backup contains capture NetworkManager profile"
    grep -Fq 'opt/thorny/data/scanner/' <<<"$archive_list" && pass "Backup contains scanner state" || fail "Backup contains scanner state"
    if grep -Eq 'opt/thorny/data/(prometheus|loki|ntopng|captures|smokeping/data)(/|$)' <<<"$archive_list"; then
      fail "Backup excludes rebuildable/bulk observability and capture data"
    else
      pass "Backup excludes rebuildable/bulk observability and capture data"
    fi
    if grep -Fq 'etc/thorny/backup_ed25519' <<<"$archive_list"; then fail "Backup excludes private remote-backup key"; else pass "Backup excludes private remote-backup key"; fi
  else
    fail "Latest local backup exists"
  fi

  remote_enabled="$(jq -r '.enabled // false' /etc/thorny/backup-remote.json 2>/dev/null || echo false)"
  remote_ok="$(awk -F= '$1=="remote_ok"{print $2}' /var/lib/thorny/backup.status 2>/dev/null | tail -1)"
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
  echo "This prepares the current VM as a reusable OVA template. It preserves Thorny application data and credentials."
  echo "After deployment of a clone, run 'sudo thorny-installer rekey' if the template credential must not be shared."
  local ans
  read -r -p "Continue with OVA sealing? [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "Cancelled."; return 0; }

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
  install -D -m 0750 -o root -g root "$SELF" /usr/local/sbin/thorny-installer
  configure_networkmanager
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

  # SMTP and Farva are deliberately interactive so no password/private deployment detail enters chat or shell history.
  if [[ ! -r /etc/thorny/ip-email.json ]]; then
    configure_smtp_interactive
  else
    log "Existing boot-email configuration preserved. Use 'thorny-installer smtp' to change it."
  fi
  if [[ "$(jq -r '.enabled // false' /etc/thorny/backup-remote.json 2>/dev/null || echo false)" == false ]]; then
    configure_remote_backup_interactive
  fi

  stage 10 "Initial backup and race-ready validation"
  /usr/local/sbin/thorny-backup
  /usr/local/sbin/thorny-field-metrics
  if validate; then
    log "Thorny installation completed successfully."
  else
    die "Installation completed but race-ready validation found required failures. Review the output above."
  fi

  local ip
  ip="$(get_mgmt_ip "$MGMT_IF")"
  cat <<EOF

Thorny is ready.
  Portal:   https://$HOSTNAME_SHORT.local/  (or https://$ip/)
  Operator: $OPERATOR_USER
  Capture:  $CAPTURE_IF (addressless, promiscuous)

VMware requirement: connect $CAPTURE_IF's vNIC to the SPAN/mirror destination port group and configure the vSphere networking layer to deliver mirrored traffic to it. The guest installer cannot configure a vSphere Distributed Switch mirror session or port-group security policy.

Before exporting a reusable OVA:
  sudo thorny-installer validate
  sudo thorny-installer seal
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
    seal) seal_ova ;;
    discover) discover ;;
    -h|--help|help|'') usage ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
