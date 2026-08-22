#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_NAME=${0##*/}
readonly UNIT_NAME=dsh-web.service
readonly UNIT_FILE=/etc/systemd/system/${UNIT_NAME}
readonly PORT_FILE=/var/lib/dsh-web/port
default_dsh_bin=$(command -v dsh || true)
default_node_bin=$(command -v node || true)
default_node_dir=''
if [[ -n "${default_node_bin}" ]]; then
  default_node_dir=$(dirname -- "${default_node_bin}")
fi
readonly DSH_BIN=${DSH_BIN:-${default_dsh_bin:-/usr/local/bin/dsh}}
readonly DSH_HOME_DIR=${DSH_HOME:-${HOME:-/root}/.dsh}
readonly DSH_HOST=${DSH_HOST:-127.0.0.1}
readonly DSH_WORKDIR=${DSH_WORKDIR:-$(pwd -P)}
readonly NODE_BIN_DIR=${NODE_BIN_DIR:-${default_node_dir:-/usr/local/bin}}

usage() {
  printf '%s\n' \
    "Usage: ${SCRIPT_NAME} [install|start|stop|restart|status|uninstall]" \
    "" \
    "Install and manage the persistent dsh Web service." \
    "The service port is selected dynamically when it is installed or repaired." \
    "Environment overrides: DSH_BIN, DSH_HOME, DSH_HOST, DSH_WORKDIR, NODE_BIN_DIR"
}

die() {
  printf '[dsh-service] ERROR: %s\n' "$*" >&2
  exit 1
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die 'run this script as root (for example: sudo bash ./start_dsh_service.sh)'
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

validate() {
  [[ -x "${DSH_BIN}" ]] || die "dsh executable not found: ${DSH_BIN}"
  [[ -d "${DSH_HOME_DIR}" ]] || die "dsh home directory not found: ${DSH_HOME_DIR}"
  [[ -d "${DSH_WORKDIR}" ]] || die "working directory not found: ${DSH_WORKDIR}"
  [[ "${DSH_HOST}" == 127.0.0.1 || "${DSH_HOST}" == localhost ]] ||
    die 'DSH_HOST must be 127.0.0.1 or localhost; dsh does not allow public binding'
  [[ -x "${NODE_BIN_DIR}/node" ]] || die "Node.js executable not found: ${NODE_BIN_DIR}/node"
}

read_service_port() {
  local port=''
  if [[ -f "${PORT_FILE}" ]]; then
    port=$(sed -n '1p' "${PORT_FILE}")
  elif [[ -f "${UNIT_FILE}" ]]; then
    port=$(sed -nE 's/.*--port[[:space:]]+([0-9]+).*/\1/p' "${UNIT_FILE}" | sed -n '1p')
  fi
  [[ "${port}" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) || return 1
  printf '%s\n' "${port}"
}

service_url() {
  local port
  port=$(read_service_port) || return 1
  printf 'http://%s:%s\n' "${DSH_HOST}" "${port}"
}

service_healthy() {
  local url
  systemctl is-active --quiet "${UNIT_NAME}" || return 1
  url=$(service_url) || return 1
  curl --fail --silent --show-error --max-time 3 "${url}/" >/dev/null 2>&1
}

choose_dynamic_port() {
  "${NODE_BIN_DIR}/node" - <<'NODE'
const net = require('node:net');
const server = net.createServer();
server.once('error', (error) => {
  console.error(error.message);
  process.exit(1);
});
server.listen(0, '127.0.0.1', () => {
  const address = server.address();
  process.stdout.write(`${address.port}\n`);
  server.close(() => process.exit(0));
});
NODE
}

write_unit() {
  install -d -m 0755 "$(dirname -- "${UNIT_FILE}")"
  cat >"${UNIT_FILE}" <<EOF
[Unit]
Description=DeepSeek Harness Web UI (dsh)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${DSH_WORKDIR}
Environment=HOME=/root
Environment=DSH_HOME=${DSH_HOME_DIR}
Environment=PATH=${NODE_BIN_DIR}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=${DSH_BIN} web --host ${DSH_HOST} --port ${1} --no-open
Restart=on-failure
RestartSec=2s
KillMode=control-group
TimeoutStopSec=15s

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "${UNIT_FILE}"
}

install_service() {
  require_root
  require_command systemctl
  require_command curl
  validate
  local port=${1:-}
  [[ "${port}" =~ ^[0-9]+$ ]] || port=$(choose_dynamic_port)
  [[ "${port}" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) || die "invalid dynamically selected port: ${port}"
  install -d -m 0755 "$(dirname -- "${PORT_FILE}")"
  printf '%s\n' "${port}" >"${PORT_FILE}"
  chmod 0644 "${PORT_FILE}"
  systemctl stop "${UNIT_NAME}" 2>/dev/null || true
  write_unit "${port}"
  systemctl daemon-reload
  systemctl enable "${UNIT_NAME}" >/dev/null
  systemctl start "${UNIT_NAME}"
  printf '[dsh-service] enabled and started: http://%s:%s\n' "${DSH_HOST}" "${port}"
}

ensure_service() {
  require_root
  require_command systemctl
  if service_healthy; then
    printf '[dsh-service] already healthy; no action taken: %s\n' "$(service_url)"
    return 0
  fi
  printf '[dsh-service] service is missing or unhealthy; installing/restarting it\n'
  install_service
}

case "${1:-install}" in
  install|start)
    ensure_service
    ;;
  stop)
    require_root
    require_command systemctl
    systemctl stop "${UNIT_NAME}"
    ;;
  restart)
    require_root
    require_command systemctl
    install_service
    ;;
  status)
    require_command systemctl
    systemctl status "${UNIT_NAME}" --no-pager -l
    ;;
  uninstall)
    require_root
    require_command systemctl
    systemctl disable --now "${UNIT_NAME}" 2>/dev/null || true
    rm -f -- "${UNIT_FILE}"
    rm -f -- "${PORT_FILE}"
    systemctl daemon-reload
    printf '[dsh-service] removed %s\n' "${UNIT_FILE}"
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
