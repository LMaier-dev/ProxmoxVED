#!/usr/bin/env bash
# Copyright (c) 2021-2026 community-scripts ORG
# Author: LMaier-dev
# License: MIT
# https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE

# Grafana Alloy on Proxmox VE node:
#   - receives PVE OTLP metrics from pvestatd (cluster OTLP metric server)
#   - scrapes host hardware metrics (node_exporter built-in)
#   - ships systemd journal to Loki
# Run on every node. The cluster OTLP metric-server config is created once
# and replicates via /etc/pve/status.cfg.
#
# Re-running on a node with alloy installed prompts to Reinstall, Update, or
# Uninstall. Headless: set ALLOY_ACTION=install|update|uninstall.

header_info() {
  clear 2>/dev/null || true
  cat <<"EOF"
   ______            ___                  ___    ____
  / ____/________ _/ __/___ _____  ____ _/   |  / / /___  __  __
 / / __/ ___/ __ `/ /_/ __ `/ __ \/ __ `/ /| | / / / __ \/ / / /
/ /_/ / /  / /_/ / __/ /_/ / / / / /_/ / ___ |/ / / /_/ / /_/ /
\____/_/   \__,_/_/  \__,_/_/ /_/\__,_/_/  |_/_/_/\____/\__, /
   PVE Node Monitoring Agent                           /____/

EOF
}

RD=$(echo "\033[01;31m")
YW=$(echo "\033[33m")
GN=$(echo "\033[1;92m")
BL=$(echo "\033[36m")
CL=$(echo "\033[m")
BFR="\\r\\033[K"
HOLD="-"
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"

set -euo pipefail
shopt -s inherit_errexit nullglob

msg_info() { echo -ne " ${HOLD} ${YW}$1..."; }
msg_ok() { echo -e "${BFR} ${CM} ${GN}$1${CL}"; }
msg_error() { echo -e "${BFR} ${CROSS} ${RD}$1${CL}"; }

ALLOY_CONFIG="/etc/alloy/config.alloy"
GRAFANA_KEYRING="/etc/apt/keyrings/grafana.gpg"
GRAFANA_SOURCES="/etc/apt/sources.list.d/grafana.sources"
OTLP_SERVER_NAME="alloy-local"
OTLP_PORT=4318

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    msg_error "Run as root."
    exit 1
  fi
}

require_pve() {
  if ! command -v pveversion >/dev/null 2>&1; then
    msg_error "No PVE detected. This script must run on a Proxmox VE host."
    exit 1
  fi
}

require_pve_9() {
  local ver major
  ver=$(pveversion | awk -F'/' '{print $2}' | awk -F'-' '{print $1}')
  IFS='.' read -r major _ _ <<<"$ver"
  if [ "${major:-0}" -lt 9 ]; then
    msg_error "PVE ${ver} detected. PVE 9.0+ required for OpenTelemetry metric server."
    exit 1
  fi
  PVE_VER="$ver"
}

otlp_already_configured() {
  # Returns 0 if a metric server pointing at 127.0.0.1:4318 type opentelemetry already exists
  local out
  if ! out=$(pvesh get /cluster/metrics/server --output-format json 2>/dev/null); then
    return 1
  fi
  echo "$out" | grep -q '"type"[[:space:]]*:[[:space:]]*"opentelemetry"' || return 1
  echo "$out" | grep -q '"server"[[:space:]]*:[[:space:]]*"127\.0\.0\.1"' || return 1
  return 0
}

alloy_installed() {
  dpkg -s alloy >/dev/null 2>&1
}

otlp_server_named_exists() {
  pvesh get /cluster/metrics/server/${OTLP_SERVER_NAME} --output-format json >/dev/null 2>&1
}

prompt_inputs() {
  # Headless mode: any of these env vars triggers non-interactive setup.
  # ALLOY_PROMETHEUS_URL  full remote_write URL
  # ALLOY_LOKI_URL        full Loki push URL
  # ALLOY_CONFIGURE_OTLP  yes|no (default: yes if no existing OTLP server, else no)
  if [ -n "${ALLOY_PROMETHEUS_URL:-}" ] || [ -n "${ALLOY_LOKI_URL:-}" ]; then
    if [ -z "${ALLOY_PROMETHEUS_URL:-}" ] || [ -z "${ALLOY_LOKI_URL:-}" ]; then
      msg_error "Headless mode requires both ALLOY_PROMETHEUS_URL and ALLOY_LOKI_URL"
      exit 1
    fi
    PROMETHEUS_URL="$ALLOY_PROMETHEUS_URL"
    LOKI_URL="$ALLOY_LOKI_URL"
    local otlp_default="yes"
    otlp_already_configured && otlp_default="no"
    case "${ALLOY_CONFIGURE_OTLP:-$otlp_default}" in
      yes|YES|true|1) CONFIGURE_OTLP=1 ;;
      *) CONFIGURE_OTLP=0 ;;
    esac
    msg_ok "Headless mode: prometheus=${PROMETHEUS_URL} loki=${LOKI_URL} otlp=$([ $CONFIGURE_OTLP = 1 ] && echo yes || echo no)"
    return
  fi

  PROMETHEUS_URL=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
    --title "Prometheus remote_write URL" \
    --inputbox "Full URL of the Prometheus remote_write endpoint.\n\nExample: http://10.0.0.5:9090/api/v1/write\n\nPrometheus must be started with --web.enable-remote-write-receiver." \
    14 78 "http://prometheus.example.local:9090/api/v1/write" \
    3>&1 1>&2 2>&3) || { msg_info "Cancelled by user"; exit 0; }

  if [ -z "$PROMETHEUS_URL" ]; then
    msg_error "Prometheus URL is required."
    exit 1
  fi

  LOKI_URL=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
    --title "Loki push URL" \
    --inputbox "Full URL of the Loki push endpoint.\n\nExample: http://10.0.0.5:3100/loki/api/v1/push" \
    12 78 "http://loki.example.local:3100/loki/api/v1/push" \
    3>&1 1>&2 2>&3) || { msg_info "Cancelled by user"; exit 0; }

  if [ -z "$LOKI_URL" ]; then
    msg_error "Loki URL is required."
    exit 1
  fi

  local detected_msg="" defaultno_args=()
  if otlp_already_configured; then
    detected_msg="\n\nA cluster OTLP metric server pointing at 127.0.0.1 already exists — defaulting to no."
    defaultno_args=(--defaultno)
  fi

  if whiptail --backtitle "Proxmox VE Helper Scripts" \
      --title "Cluster OTLP metric server" \
      "${defaultno_args[@]}" \
      --yesno "Configure the cluster-wide OpenTelemetry metric server now?\n\nThis runs:\n  pvesh create /cluster/metrics/server/${OTLP_SERVER_NAME} \\\n    --type opentelemetry --server 127.0.0.1 \\\n    --port ${OTLP_PORT} --otel-protocol http\n\nIt only needs to be done once per cluster — the setting replicates via /etc/pve/status.cfg.${detected_msg}" \
      18 78; then
    CONFIGURE_OTLP=1
  else
    CONFIGURE_OTLP=0
  fi
}

install_alloy_repo() {
  msg_info "Adding Grafana APT repository"
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor --yes -o "$GRAFANA_KEYRING" 2>/dev/null
  chmod 0644 "$GRAFANA_KEYRING"
  cat >"$GRAFANA_SOURCES" <<EOF
Types: deb
URIs: https://apt.grafana.com
Suites: stable
Components: main
Signed-By: ${GRAFANA_KEYRING}
EOF
  msg_ok "Grafana APT repository added"

  msg_info "Updating package lists"
  apt-get update >/dev/null
  msg_ok "Package lists updated"
}

install_alloy_pkg() {
  if dpkg -s alloy >/dev/null 2>&1; then
    msg_info "Upgrading Grafana Alloy"
    apt-get install -y --only-upgrade alloy >/dev/null
    msg_ok "Grafana Alloy upgraded ($(dpkg-query -W -f='${Version}' alloy))"
  else
    msg_info "Installing Grafana Alloy"
    DEBIAN_FRONTEND=noninteractive apt-get install -y alloy >/dev/null
    msg_ok "Grafana Alloy installed ($(dpkg-query -W -f='${Version}' alloy))"
  fi
}

grant_alloy_groups() {
  msg_info "Granting alloy access to journal (adm, systemd-journal)"
  usermod -aG adm,systemd-journal alloy
  msg_ok "alloy added to adm and systemd-journal"
}

write_alloy_config() {
  msg_info "Writing ${ALLOY_CONFIG}"
  install -d -m 0755 /etc/alloy
  cat >"$ALLOY_CONFIG" <<EOF
logging {
  level = "info"
}

// ============================
// OTLP RECEIVER: PVE metrics
// Replaces prometheus-pve-exporter
// ============================
otelcol.receiver.otlp "proxmox" {
  http {
    endpoint = "0.0.0.0:${OTLP_PORT}"
  }
  output {
    metrics = [otelcol.exporter.prometheus.pve_metrics.input]
  }
}

otelcol.exporter.prometheus "pve_metrics" {
  forward_to = [prometheus.relabel.pve_labels.receiver]
}

prometheus.relabel "pve_labels" {
  forward_to = [prometheus.remote_write.default.receiver]

  rule {
    action       = "replace"
    replacement  = constants.hostname
    target_label = "instance"
  }
  rule {
    action       = "replace"
    replacement  = "proxmox-pve"
    target_label = "job"
  }
}

// ============================
// HOST METRICS: node_exporter
// ============================
prometheus.exporter.unix "default" {
  include_exporter_metrics = true
  enable_collectors = ["systemd", "processes", "interrupts", "tcpstat"]

  cpu {
    info  = true
    guest = true
  }

  systemd {
    enable_restarts = true
    start_time      = true
    unit_include    = "(pve|ceph|corosync|zfs|networking|ssh|alloy).*"
  }
}

prometheus.scrape "node" {
  targets         = prometheus.exporter.unix.default.targets
  forward_to      = [prometheus.relabel.add_labels.receiver]
  scrape_interval = "15s"
}

prometheus.relabel "add_labels" {
  forward_to = [prometheus.remote_write.default.receiver]

  rule {
    action       = "replace"
    replacement  = constants.hostname
    target_label = "instance"
  }
  rule {
    action       = "replace"
    replacement  = "proxmox-alloy"
    target_label = "job"
  }
}

// ============================
// REMOTE WRITE: Push to Prometheus
// ============================
prometheus.remote_write "default" {
  endpoint {
    url = "${PROMETHEUS_URL}"
  }
}

// ============================
// LOGS: Systemd Journal
// ============================
loki.relabel "journal" {
  forward_to = []

  rule {
    source_labels = ["__journal__systemd_unit"]
    target_label  = "unit"
  }
  rule {
    source_labels = ["__journal__hostname"]
    target_label  = "hostname"
  }
  rule {
    source_labels = ["__journal_priority_keyword"]
    target_label  = "level"
  }
}

loki.source.journal "default" {
  forward_to    = [loki.write.default.receiver]
  relabel_rules = loki.relabel.journal.rules
  labels        = {
    job       = "systemd-journal",
    instance  = constants.hostname,
    node_type = "proxmox",
  }
  max_age = "12h"
}

loki.write "default" {
  endpoint {
    url = "${LOKI_URL}"
  }
}
EOF
  chown root:alloy "$ALLOY_CONFIG"
  chmod 0640 "$ALLOY_CONFIG"
  msg_ok "Wrote ${ALLOY_CONFIG}"
}

start_alloy() {
  msg_info "Enabling and starting alloy.service"
  systemctl enable --now alloy >/dev/null 2>&1
  # Restart in case the service was already running before config was written
  systemctl restart alloy
  sleep 2
  if systemctl is-active --quiet alloy; then
    msg_ok "alloy.service is active"
  else
    msg_error "alloy.service failed to start"
    journalctl -u alloy --no-pager -n 30 || true
    exit 1
  fi
}

configure_otlp_server() {
  if [ "$CONFIGURE_OTLP" -ne 1 ]; then
    return
  fi
  if otlp_already_configured; then
    msg_ok "Cluster OTLP metric server already configured — skipping"
    return
  fi
  msg_info "Creating cluster OTLP metric server '${OTLP_SERVER_NAME}'"
  pvesh create /cluster/metrics/server/${OTLP_SERVER_NAME} \
    --type opentelemetry \
    --server 127.0.0.1 \
    --port ${OTLP_PORT} \
    --otel-protocol http >/dev/null
  msg_ok "Cluster OTLP metric server created"
}

show_summary() {
  echo
  echo -e "${BL}╔══════════════════════════════════════════════════════════════╗${CL}"
  echo -e "${BL}║${CL}              ${GN}Grafana Alloy Installation Complete${CL}             ${BL}║${CL}"
  echo -e "${BL}╠══════════════════════════════════════════════════════════════╣${CL}"
  echo -e "${BL}║${CL} ${YW}PVE version:${CL}     ${PVE_VER}"
  echo -e "${BL}║${CL} ${YW}Hostname:${CL}        $(hostname)"
  echo -e "${BL}║${CL} ${YW}Alloy version:${CL}   $(dpkg-query -W -f='${Version}' alloy)"
  echo -e "${BL}║${CL} ${YW}Config:${CL}          ${ALLOY_CONFIG}"
  echo -e "${BL}║${CL} ${YW}OTLP listener:${CL}   0.0.0.0:${OTLP_PORT}"
  echo -e "${BL}║${CL} ${YW}Alloy UI:${CL}        http://127.0.0.1:12345 (loopback only by default)"
  echo -e "${BL}║${CL} ${YW}Prometheus:${CL}      ${PROMETHEUS_URL}"
  echo -e "${BL}║${CL} ${YW}Loki:${CL}            ${LOKI_URL}"
  echo -e "${BL}╚══════════════════════════════════════════════════════════════╝${CL}"
  echo
  echo -e "${YW}Next steps:${CL}"
  echo "  - Run this script on every other node in the cluster (skip OTLP prompt)."
  echo "  - Verify metrics appear in Prometheus (e.g. query 'pve_up' and 'node_load1')."
  echo "  - Verify journal logs appear in Loki (e.g. query '{job=\"systemd-journal\"}')."
  echo "  - Import Grafana dashboard 23855 for the PVE OTLP overview."
  echo
}

prompt_uninstall_options() {
  # REMOVE_OTLP / REMOVE_REPO defaults: NO (both have cluster-wide / cross-tool blast radius).
  # Headless: read from env, fall back to defaults.
  if [ -n "${ALLOY_ACTION:-}" ] || [ -n "${ALLOY_PROMETHEUS_URL:-}" ] || [ -n "${ALLOY_LOKI_URL:-}" ]; then
    case "${ALLOY_REMOVE_OTLP:-no}" in yes|YES|true|1) REMOVE_OTLP=1 ;; *) REMOVE_OTLP=0 ;; esac
    case "${ALLOY_REMOVE_REPO:-no}" in yes|YES|true|1) REMOVE_REPO=1 ;; *) REMOVE_REPO=0 ;; esac
    return
  fi

  REMOVE_OTLP=0
  if otlp_server_named_exists; then
    if whiptail --backtitle "Proxmox VE Helper Scripts" \
        --title "Remove cluster OTLP metric server?" \
        --defaultno \
        --yesno "Also delete the cluster-wide OpenTelemetry metric server '${OTLP_SERVER_NAME}'?\n\nThis runs:\n  pvesh delete /cluster/metrics/server/${OTLP_SERVER_NAME}\n\nWARNING: This affects the ENTIRE cluster — every node will stop pushing pvestatd OTLP metrics. Only do this if you're uninstalling Alloy from all nodes." \
        16 78; then
      REMOVE_OTLP=1
    fi
  fi

  REMOVE_REPO=0
  if [ -f "$GRAFANA_SOURCES" ]; then
    if whiptail --backtitle "Proxmox VE Helper Scripts" \
        --title "Remove Grafana APT repository?" \
        --defaultno \
        --yesno "Also remove the Grafana APT repository (${GRAFANA_SOURCES} and ${GRAFANA_KEYRING})?\n\nSay no if you have other Grafana packages installed (loki, grafana, tempo, ...) that depend on it." \
        14 78; then
      REMOVE_REPO=1
    fi
  fi
}

stop_alloy() {
  if systemctl list-unit-files alloy.service >/dev/null 2>&1; then
    msg_info "Stopping and disabling alloy.service"
    systemctl disable --now alloy >/dev/null 2>&1 || true
    msg_ok "alloy.service stopped"
  fi
}

purge_alloy_pkg() {
  if dpkg -s alloy >/dev/null 2>&1; then
    msg_info "Purging alloy package"
    DEBIAN_FRONTEND=noninteractive apt-get purge -y alloy >/dev/null
    msg_ok "alloy purged"
  else
    msg_ok "alloy package not installed — skipping"
  fi
}

remove_alloy_config() {
  if [ -e /etc/alloy ]; then
    msg_info "Removing /etc/alloy"
    rm -rf /etc/alloy
    msg_ok "/etc/alloy removed"
  fi
}

remove_otlp_server() {
  if [ "$REMOVE_OTLP" -ne 1 ]; then
    return
  fi
  if ! otlp_server_named_exists; then
    msg_ok "Cluster OTLP server '${OTLP_SERVER_NAME}' does not exist — skipping"
    return
  fi
  msg_info "Deleting cluster OTLP metric server '${OTLP_SERVER_NAME}'"
  pvesh delete /cluster/metrics/server/${OTLP_SERVER_NAME} >/dev/null
  msg_ok "Cluster OTLP metric server deleted"
}

remove_grafana_repo() {
  if [ "$REMOVE_REPO" -ne 1 ]; then
    return
  fi
  msg_info "Removing Grafana APT repository"
  rm -f "$GRAFANA_SOURCES" "$GRAFANA_KEYRING"
  apt-get update >/dev/null
  msg_ok "Grafana APT repository removed"
}

show_uninstall_summary() {
  echo
  echo -e "${BL}╔══════════════════════════════════════════════════════════════╗${CL}"
  echo -e "${BL}║${CL}             ${GN}Grafana Alloy Uninstallation Complete${CL}            ${BL}║${CL}"
  echo -e "${BL}╠══════════════════════════════════════════════════════════════╣${CL}"
  echo -e "${BL}║${CL} ${YW}Hostname:${CL}        $(hostname)"
  echo -e "${BL}║${CL} ${YW}Package:${CL}         purged"
  echo -e "${BL}║${CL} ${YW}Config:${CL}          /etc/alloy removed"
  if [ "$REMOVE_OTLP" -eq 1 ]; then
    echo -e "${BL}║${CL} ${YW}OTLP server:${CL}     deleted (cluster-wide)"
  else
    echo -e "${BL}║${CL} ${YW}OTLP server:${CL}     kept (run pvesh delete /cluster/metrics/server/${OTLP_SERVER_NAME} to remove)"
  fi
  if [ "$REMOVE_REPO" -eq 1 ]; then
    echo -e "${BL}║${CL} ${YW}Grafana APT:${CL}     removed"
  else
    echo -e "${BL}║${CL} ${YW}Grafana APT:${CL}     kept"
  fi
  echo -e "${BL}╚══════════════════════════════════════════════════════════════╝${CL}"
  echo
}

run_install() {
  prompt_inputs
  install_alloy_repo
  install_alloy_pkg
  grant_alloy_groups
  write_alloy_config
  start_alloy
  configure_otlp_server
  show_summary
}

run_uninstall() {
  prompt_uninstall_options
  stop_alloy
  purge_alloy_pkg
  remove_alloy_config
  remove_otlp_server
  remove_grafana_repo
  show_uninstall_summary
}

prompt_action() {
  # Resolves ACTION in {install, update, uninstall} from env or interactive menu.
  if [ -n "${ALLOY_ACTION:-}" ]; then
    case "$ALLOY_ACTION" in
      install|update|uninstall) ACTION="$ALLOY_ACTION" ;;
      *) msg_error "Invalid ALLOY_ACTION='$ALLOY_ACTION' (expected install|update|uninstall)"; exit 1 ;;
    esac
    msg_ok "Headless action: ${ACTION}"
    return
  fi

  if alloy_installed; then
    # Existing install: offer menu.
    local choice
    choice=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
      --title "Grafana Alloy already installed on $(hostname)" \
      --menu "Alloy $(dpkg-query -W -f='${Version}' alloy) is installed.\n\nChoose an action:" \
      18 70 4 \
      "update"     "Re-run install (upgrade pkg, rewrite config)" \
      "uninstall"  "Stop alloy, purge pkg, remove /etc/alloy" \
      "cancel"     "Exit without changes" \
      3>&1 1>&2 2>&3) || { msg_info "Cancelled by user"; exit 0; }
    case "$choice" in
      update)    ACTION="update" ;;
      uninstall) ACTION="uninstall" ;;
      cancel|"") msg_info "Cancelled by user"; exit 0 ;;
    esac
  else
    if [ -z "${ALLOY_PROMETHEUS_URL:-}" ] && [ -z "${ALLOY_LOKI_URL:-}" ]; then
      if ! whiptail --backtitle "Proxmox VE Helper Scripts" \
          --title "Grafana Alloy on Proxmox VE" \
          --yesno "Install Grafana Alloy on $(hostname) (PVE ${PVE_VER}).\n\nThis will:\n  - add the Grafana APT repository\n  - install/upgrade the alloy package\n  - write /etc/alloy/config.alloy\n  - enable and start alloy.service\n  - optionally create the cluster OTLP metric server\n\nProceed?" \
          16 70; then
        msg_info "Cancelled by user"
        exit 0
      fi
    fi
    ACTION="install"
  fi
}

main() {
  header_info
  require_root
  require_pve
  require_pve_9

  prompt_action

  case "$ACTION" in
    install|update) run_install ;;
    uninstall)      run_uninstall ;;
  esac
}

main "$@"
