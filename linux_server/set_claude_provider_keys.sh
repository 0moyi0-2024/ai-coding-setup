#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly SCRIPT_NAME=${0##*/}
readonly AGENT_DIR="${AI_SETUP_AGENT_DIR:-/agent}"
readonly AGENT_BIN_DIR="${AGENT_DIR}/bin"
readonly AGENT_CACHE_DIR="${AGENT_DIR}/cache"
readonly AGENT_CONFIG_DIR="${AGENT_DIR}/config"
readonly AGENT_HOME="${AGENT_DIR}/home"
readonly AGENT_ENV_FILE="${AGENT_DIR}/env.sh"
# When invoked through sudo, keep the generated user files and Bash startup
# configuration owned by the user who requested the installation.  A direct
# root invocation can opt into the same behavior with AI_SETUP_USER.
readonly SETUP_USER="${AI_SETUP_USER:-${SUDO_USER:-${USER:-$(id -un)}}}"
readonly SETUP_UID="$(id -u "${SETUP_USER}")"
readonly SETUP_GID="$(id -g "${SETUP_USER}")"
readonly SETUP_HOME="$(getent passwd "${SETUP_USER}" | cut -d: -f6)"
readonly BASH_RC_FILE="${AI_SETUP_BASHRC_FILE:-${SETUP_HOME}/.bashrc}"
readonly CCR_DIR="${AGENT_HOME}/.claude-code-router"
readonly CCR_SERVICE_FILE="${CCR_DIR}/service.json"
readonly CLAUDE_CONFIG_DIR="${AGENT_CONFIG_DIR}/claude"
readonly CLAUDE_SETTINGS_FILE="${CLAUDE_CONFIG_DIR}/settings.json"
readonly CODEX_DIR="${AGENT_CONFIG_DIR}/codex"
readonly CODEX_ENV_FILE="${CODEX_DIR}/gateways.env"
readonly CODEX_MODEL_CATALOG_DIR="${CODEX_DIR}/catalogs"
readonly NODE_INSTALL_DIR="${AGENT_DIR}/node"
readonly CCR_RUNTIME_FILE="${CCR_DIR}/runtime.env"
readonly CCR_SYSTEMD_UNIT="ai-coding-setup-ccr.service"
readonly CCR_AUTOSTART_HELPER="${AGENT_BIN_DIR}/ccr-autostart"
readonly CCR_PORT_SCAN_START="${AI_SETUP_CCR_PORT_SCAN_START:-3456}"
readonly VOLCANO_MODEL_CANDIDATES='["deepseek-v4-flash","deepseek-v4-pro","qwen3.7-plus","qwen3.7-max","doubao-seed-2.1-pro","MiniMax-M3","glm-5.2","hy3"]'
VOLCANO_MODELS='[]'
BAILIAN_MODELS='[]'
BLACKAI_GPT_MODELS='[]'
BLACKAI_CLAUDE_MODELS='[]'
TEMP_DIR=""
readonly -a GATEWAY_KEY_NAMES=(
  VOLCANO_AI_GATEWAY_API_KEY
  BAILIAN_API_KEY
  BLACKAICODING_GPT_API_KEY
  BLACKAICODING_CLAUDE_API_KEY
)

readonly CCR_HOST=127.0.0.1
CCR_GATEWAY_PORT="${AI_SETUP_CCR_GATEWAY_PORT:-${CCR_PORT_SCAN_START}}"
CCR_CORE_PORT=$((CCR_GATEWAY_PORT + 1))
CCR_MANAGEMENT_PORT=$((CCR_GATEWAY_PORT + 2))
CCR_GATEWAY_URL="http://${CCR_HOST}:${CCR_GATEWAY_PORT}"
INSTALL_TOOLS=1
CONFIGURE_GATEWAYS=1
DRY_RUN=0
EXIT_AFTER_HELP=0

usage() {
  printf '%s\n' \
    "Usage: ${SCRIPT_NAME} [options]" \
    "" \
    "Install or update Claude Code, Claude Code Router, and Codex, then" \
    "configure the supported API gateways without putting keys in TOML." \
    "" \
    "Options:" \
    "  --install-only     Only install/update the three CLI tools" \
    "  --configure-only   Only configure gateways and client profiles" \
    "  --dry-run          Show actions without installing or changing files" \
    "  -h, --help         Show this help"
}

log() {
  printf '[ai-setup] %s\n' "$*"
}

warn() {
  printf '[ai-setup] WARNING: %s\n' "$*" >&2
}

die() {
  printf '[ai-setup] ERROR: %s\n' "$*" >&2
  exit 1
}

run() {
  if ((DRY_RUN)); then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

require_command() {
  command_exists "$1" || die "Missing required command: $1"
}

write_secure_file() {
  local file=$1
  local content=$2
  local mode=${3:-600}
  if ((DRY_RUN)); then
    log "Would write ${file} with mode ${mode}"
    return 0
  fi
  local directory temporary_file
  directory=$(dirname "${file}")
  mkdir -p "${directory}"
  temporary_file=$(mktemp "${directory}/.$(basename "${file}").tmp.XXXXXXXX")
  if ! printf '%s\n' "${content}" >"${temporary_file}"; then
    rm -f -- "${temporary_file}"
    die "Could not write temporary file for ${file}."
  fi
  chmod "${mode}" "${temporary_file}"
  if ! mv -f -- "${temporary_file}" "${file}"; then
    rm -f -- "${temporary_file}"
    die "Could not replace ${file}."
  fi
}

write_executable_file() {
  local file=$1
  local content=$2
  write_secure_file "${file}" "${content}"
  run chmod 700 "${file}"
}

write_public_executable_file() {
  local file=$1
  local content=$2
  write_secure_file "${file}" "${content}" 644
  run chmod 755 "${file}"
}

ensure_setup_user_ownership() {
  ((DRY_RUN)) && return 0
  ((EUID == 0)) || return 0

  local path
  # These trees contain the CLI runtime, Codex/Claude state, CCR runtime files,
  # credentials, SQLite databases, and npm's user cache.  The setup user must
  # be able to execute and update the tools as well as write their state.
  for path in "${NODE_INSTALL_DIR}" "${AGENT_CONFIG_DIR}" "${AGENT_HOME}" "${AGENT_CACHE_DIR}"; do
    [[ -e "${path}" ]] && chown -R -- "${SETUP_UID}:${SETUP_GID}" "${path}"
  done
  for path in "${AGENT_ENV_FILE}" "${BASH_RC_FILE}"; do
    [[ -e "${path}" ]] && chown -- "${SETUP_UID}:${SETUP_GID}" "${path}"
  done
}

cleanup_temp_dir() {
  case "${TEMP_DIR}" in
    "${AGENT_DIR}"/.node-download.*|"${AGENT_DIR}"/.codex-catalog.*)
      rm -rf -- "${TEMP_DIR}"
      ;;
  esac
}

write_runtime_files() {
  local env_content claude_launcher codex_launcher ccr_launcher
  printf -v env_content \
    'ai_setup_prepend_path() {\n  local ai_setup_entry ai_setup_rest ai_setup_clean=\x27\x27\n  ai_setup_rest=${PATH:-}\n  while [[ -n "${ai_setup_rest}" ]]; do\n    case "${ai_setup_rest}" in\n      *:*) ai_setup_entry=${ai_setup_rest%%:*}; ai_setup_rest=${ai_setup_rest#*:} ;;\n      *) ai_setup_entry=${ai_setup_rest}; ai_setup_rest=\x27\x27 ;;\n    esac\n    [[ "${ai_setup_entry}" == %q || "${ai_setup_entry}" == %q || -z "${ai_setup_entry}" ]] && continue\n    [[ -n "${ai_setup_clean}" ]] && ai_setup_clean+=:\n    ai_setup_clean+=${ai_setup_entry}\n  done\n  PATH=%q:%q${ai_setup_clean:+:${ai_setup_clean}}\n  export PATH\n}\nai_setup_prepend_path\nunset -f ai_setup_prepend_path\nexport CLAUDE_CONFIG_DIR=%q\nexport CODEX_HOME=%q\nexport NPM_CONFIG_CACHE=%q\n[[ ! -f %q ]] || source %q' \
    "${AGENT_BIN_DIR}" "${NODE_INSTALL_DIR}/bin" \
    "${AGENT_BIN_DIR}" "${NODE_INSTALL_DIR}/bin" \
    "${CLAUDE_CONFIG_DIR}" "${CODEX_DIR}" "${AGENT_CACHE_DIR}/npm" \
    "${CODEX_ENV_FILE}" "${CODEX_ENV_FILE}"
  # The format string treats %% as a literal %, so restore the Bash longest-prefix
  # expansion after printf renders the template.
  env_content=${env_content//'${ai_setup_rest%:*}'/'${ai_setup_rest%%:*}'}
  # This file contains paths and exports, but no key values; all users need to
  # be able to source it when the shared installation is used.
  write_secure_file "${AGENT_ENV_FILE}" "${env_content}" 644

  printf -v claude_launcher \
    '#!/usr/bin/env bash\n[[ ! -r %q ]] || source %q\nexport CLAUDE_CONFIG_DIR=%q\nexec %q "$@"' \
    "${AGENT_ENV_FILE}" "${AGENT_ENV_FILE}" "${CLAUDE_CONFIG_DIR}" \
    "${NODE_INSTALL_DIR}/bin/claude"
  write_public_executable_file "${AGENT_BIN_DIR}/claude" "${claude_launcher}"

  printf -v codex_launcher \
    '#!/usr/bin/env bash\n[[ ! -r %q ]] || source %q\nexport CODEX_HOME=%q\n[[ ! -r %q ]] || source %q\nexec %q "$@"' \
    "${AGENT_ENV_FILE}" "${AGENT_ENV_FILE}" "${CODEX_DIR}" \
    "${CODEX_ENV_FILE}" "${CODEX_ENV_FILE}" \
    "${NODE_INSTALL_DIR}/bin/codex"
  write_public_executable_file "${AGENT_BIN_DIR}/codex" "${codex_launcher}"

  printf -v ccr_launcher \
    '#!/usr/bin/env bash\n[[ ! -r %q ]] || source %q\nexport HOME=%q CLAUDE_CONFIG_DIR=%q CODEX_HOME=%q\n[[ ! -r %q ]] || source %q\nexec %q "$@"' \
    "${AGENT_ENV_FILE}" "${AGENT_ENV_FILE}" "${AGENT_HOME}" \
    "${CLAUDE_CONFIG_DIR}" "${CODEX_DIR}" \
    "${CCR_RUNTIME_FILE}" "${CCR_RUNTIME_FILE}" "${NODE_INSTALL_DIR}/bin/ccr"
  write_public_executable_file "${AGENT_BIN_DIR}/ccr" "${ccr_launcher}"

  printf -v ccr_autostart_launcher \
    '#!/usr/bin/env bash\nset -Eeuo pipefail\n[[ -f %q ]] || { echo "Missing CCR runtime file: %q" >&2; exit 1; }\nsource %q\nccr_bin=%q\nservice_file=%q\nis_healthy() {\n  local pid\n  pid=$(sed -nE '\''s/.*"pid"[[:space:]]*:[[:space:]]*([0-9]+).*/\\1/p'\'' "${service_file}" 2>/dev/null | head -n 1)\n  [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null && curl --fail --silent --max-time 2 "http://${CCR_HOST}:${CCR_MANAGEMENT_PORT}" >/dev/null 2>&1\n}\nif ! is_healthy; then\n  "${ccr_bin}" start --host "${CCR_HOST}" --port "${CCR_MANAGEMENT_PORT}" --no-open --gateway\nfi\nuntil is_healthy; do sleep 1; done\nwhile is_healthy; do sleep 5; done\necho "CCR stopped or became unhealthy" >&2\nexit 1' \
    "${CCR_RUNTIME_FILE}" "${CCR_RUNTIME_FILE}" "${CCR_RUNTIME_FILE}" \
    "${AGENT_BIN_DIR}/ccr" "${CCR_SERVICE_FILE}"
  write_public_executable_file "${CCR_AUTOSTART_HELPER}" "${ccr_autostart_launcher}"
}

write_ccr_runtime_file() {
  local runtime_content
  runtime_content=$(printf '%s\n' \
    "CCR_HOST=${CCR_HOST}" \
    "CCR_GATEWAY_PORT=${CCR_GATEWAY_PORT}" \
    "CCR_CORE_PORT=${CCR_CORE_PORT}" \
    "CCR_MANAGEMENT_PORT=${CCR_MANAGEMENT_PORT}" \
    "CCR_GATEWAY_URL=${CCR_GATEWAY_URL}" \
    "case \":\${PATH:-}:\" in *:\"${AGENT_BIN_DIR}\":*) ;; *) PATH=${AGENT_BIN_DIR}:\${PATH:-} ;; esac" \
    "case \":\${PATH:-}:\" in *:\"${NODE_INSTALL_DIR}/bin\":*) ;; *) PATH=${NODE_INSTALL_DIR}/bin:\${PATH:-} ;; esac" \
    'export PATH CCR_HOST CCR_GATEWAY_PORT CCR_CORE_PORT CCR_MANAGEMENT_PORT CCR_GATEWAY_URL')
  write_secure_file "${CCR_RUNTIME_FILE}" "${runtime_content}"
  return 0
}

systemd_available() {
  command_exists systemctl || return 1
  [[ -d /run/systemd/system ]] ||
    [[ "$(ps -p 1 -o comm= 2>/dev/null)" == systemd ]]
}

configure_ccr_autostart() {
  local unit_file unit_user
  if ! systemd_available; then
    log 'systemd is unavailable; CCR auto-start is not installed (start ccr manually after boot).'
    return 0
  fi

  unit_user=${SETUP_USER}
  if ((EUID == 0)); then
    # The configuration phase may have started CCR as root.  Stop it before
    # handing the same runtime files to the configured non-root service user.
    systemctl stop "${CCR_SYSTEMD_UNIT}" >/dev/null 2>&1 || true
    stop_ccr_service
    ensure_setup_user_ownership
    unit_file="/etc/systemd/system/${CCR_SYSTEMD_UNIT}"
    write_secure_file "${unit_file}" "[Unit]
Description=AI Coding Setup Claude Code Router
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${unit_user}
Environment=HOME=${AGENT_HOME}
Environment=CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR}
Environment=CODEX_HOME=${CODEX_DIR}
Environment=PATH=${AGENT_BIN_DIR}:${NODE_INSTALL_DIR}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=${CCR_AUTOSTART_HELPER}
ExecStop=${AGENT_BIN_DIR}/ccr stop
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target" 644
    systemctl daemon-reload
    if ! systemctl enable --now "${CCR_SYSTEMD_UNIT}"; then
      log "WARNING: could not enable ${CCR_SYSTEMD_UNIT}; CCR configuration is complete, but auto-start needs manual repair."
      return 0
    fi
    log "Installed and enabled systemd unit ${unit_file}"
    return 0
  fi

  unit_file="${SETUP_HOME}/.config/systemd/user/${CCR_SYSTEMD_UNIT}"
  write_secure_file "${unit_file}" "[Unit]
Description=AI Coding Setup Claude Code Router
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HOME=${AGENT_HOME}
Environment=CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR}
Environment=CODEX_HOME=${CODEX_DIR}
Environment=PATH=${AGENT_BIN_DIR}:${NODE_INSTALL_DIR}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=${CCR_AUTOSTART_HELPER}
ExecStop=${AGENT_BIN_DIR}/ccr stop
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target" 644
  systemctl --user daemon-reload
  if ! systemctl --user enable --now "${CCR_SYSTEMD_UNIT}"; then
    log "WARNING: could not enable the user CCR unit; run systemctl --user enable --now ${CCR_SYSTEMD_UNIT} after login."
    return 0
  fi
  log "Installed and enabled user systemd unit ${unit_file}"
}

configure_bash_startup() {
  local begin_marker='# BEGIN ai-coding-setup environment'
  local end_marker='# END ai-coding-setup environment'
  local source_line rc_directory temporary_file current_mode input_file
  printf -v source_line '[[ ! -f %q ]] || source %q' \
    "${AGENT_ENV_FILE}" "${AGENT_ENV_FILE}"

  if ((DRY_RUN)); then
    log "Would configure ${BASH_RC_FILE} to load ${AGENT_ENV_FILE}"
    return 0
  fi

  [[ "${BASH_RC_FILE}" == /* ]] || die "AI_SETUP_BASHRC_FILE must be an absolute path."
  [[ ! -e "${BASH_RC_FILE}" || -f "${BASH_RC_FILE}" ]] ||
    die "${BASH_RC_FILE} exists but is not a regular file."

  rc_directory=$(dirname -- "${BASH_RC_FILE}")
  mkdir -p "${rc_directory}"
  temporary_file=$(mktemp "${rc_directory}/.$(basename "${BASH_RC_FILE}").tmp.XXXXXXXX")
  current_mode=600
  if [[ -f "${BASH_RC_FILE}" ]]; then
    current_mode=$(stat -c '%a' "${BASH_RC_FILE}")
    input_file=${BASH_RC_FILE}
  else
    input_file=/dev/null
  fi

  if ! awk -v marker_start="${begin_marker}" -v marker_end="${end_marker}" \
      -v source_line="${source_line}" '
        BEGIN { skipping = 0; replaced = 0 }
        $0 == marker_start {
          if (!replaced) {
            print marker_start
            print source_line
            print marker_end
            replaced = 1
          }
          skipping = 1
          next
        }
        skipping && $0 == marker_end { skipping = 0; next }
        !skipping { print }
        END {
          if (!replaced) {
            if (NR > 0) print ""
            print marker_start
            print source_line
            print marker_end
          }
        }
      ' "${input_file}" 2>/dev/null >"${temporary_file}"; then
    rm -f -- "${temporary_file}"
    die "Could not update ${BASH_RC_FILE}; check its managed environment block."
  fi
  chmod "${current_mode}" "${temporary_file}"
  mv -f -- "${temporary_file}" "${BASH_RC_FILE}"
  log "Configured ${BASH_RC_FILE} to load ${AGENT_ENV_FILE} in new Bash sessions"
}

initialize_install_layout() {
  [[ "${AGENT_DIR}" == /* && "${AGENT_DIR}" != / ]] ||
    die "AI_SETUP_AGENT_DIR must be an absolute path other than /."
  [[ ! -L "${AGENT_DIR}" ]] ||
    die "${AGENT_DIR} is a symbolic link; use a real container-local directory."
  if [[ -e "${AGENT_DIR}" && ! -d "${AGENT_DIR}" ]]; then
    die "${AGENT_DIR} already exists as a file; remove or rename it before installing."
  fi

  run mkdir -p "${AGENT_DIR}" "${AGENT_BIN_DIR}" "${AGENT_CACHE_DIR}/npm" \
    "${AGENT_CONFIG_DIR}" "${AGENT_HOME}" "${CLAUDE_CONFIG_DIR}" \
    "${CODEX_DIR}" "${CODEX_MODEL_CATALOG_DIR}"
  write_runtime_files
  configure_bash_startup
  # Keep the current shell consistent with the generated, idempotent env file.
  local ai_setup_entry ai_setup_rest ai_setup_clean=''
  ai_setup_rest=${PATH:-}
  while [[ -n "${ai_setup_rest}" ]]; do
    case "${ai_setup_rest}" in
      *:*) ai_setup_entry=${ai_setup_rest%%:*}; ai_setup_rest=${ai_setup_rest#*:} ;;
      *) ai_setup_entry=${ai_setup_rest}; ai_setup_rest='' ;;
    esac
    [[ "${ai_setup_entry}" == "${AGENT_BIN_DIR}" ||
       "${ai_setup_entry}" == "${NODE_INSTALL_DIR}/bin" ||
       -z "${ai_setup_entry}" ]] && continue
    case ":${ai_setup_clean}:" in
      *:"${ai_setup_entry}":*) continue ;;
    esac
    [[ -n "${ai_setup_clean}" ]] && ai_setup_clean+=:
    ai_setup_clean+=${ai_setup_entry}
  done
  PATH="${AGENT_BIN_DIR}:${NODE_INSTALL_DIR}/bin${ai_setup_clean:+:${ai_setup_clean}}"
  export PATH
  export NPM_CONFIG_PREFIX="${NODE_INSTALL_DIR}"
  export NPM_CONFIG_CACHE="${AGENT_CACHE_DIR}/npm"
  export CLAUDE_CONFIG_DIR CODEX_HOME="${CODEX_DIR}"
  log "Using the container-local installation directory ${AGENT_DIR}"
}

prompt_secret() {
  local label=$1
  local current_value=$2
  local result_var=$3
  local entered_value=''
  local suffix=''

  if [[ -n "${current_value}" ]]; then
    suffix=' [Enter keeps current value]'
  else
    suffix=' [Enter skips]'
  fi
  read -r -s -p "${label}${suffix}: " entered_value
  printf '\n'
  if [[ -z "${entered_value}" ]]; then
    printf -v "${result_var}" '%s' "${current_value}"
  else
    printf -v "${result_var}" '%s' "${entered_value}"
  fi
}

load_persisted_gateway_keys() {
  [[ -f "${CODEX_ENV_FILE}" ]] || return 0
  local name
  local -A current=()
  for name in "${GATEWAY_KEY_NAMES[@]}"; do
    current[${name}]=${!name:-}
  done
  # This file is generated by write_codex_environment with shell-escaped values.
  source "${CODEX_ENV_FILE}"
  for name in "${GATEWAY_KEY_NAMES[@]}"; do
    [[ -z "${current[${name}]}" ]] || printf -v "${name}" '%s' "${current[${name}]}"
  done
  export "${GATEWAY_KEY_NAMES[@]}"
  log "Loaded existing gateway keys from ${CODEX_ENV_FILE}"
}

# Node.js runtime and CLI installation.
node_platform() {
  [[ "$(uname -s)" == Linux ]] ||
    die "Automatic Node.js installation currently supports Linux only."
  case "$(uname -m)" in
    x86_64|amd64) printf '%s\n' linux-x64 ;;
    aarch64|arm64) printf '%s\n' linux-arm64 ;;
    armv7l) printf '%s\n' linux-armv7l ;;
    *) die "Unsupported Linux architecture: $(uname -m)" ;;
  esac
}

ensure_node_runtime_dependencies() {
  local node_binary=$1
  if ! "${node_binary}" --version >/dev/null 2>&1; then
    if command_exists ldd && ldd "${node_binary}" 2>/dev/null | grep -q 'libatomic\.so\.1.*not found'; then
      log "Missing libatomic.so.1; installing the system runtime dependency"
      if command_exists apt-get; then
        apt-get update
        apt-get install -y libatomic1
      elif command_exists dnf; then
        install_libatomic_with_dnf dnf
      elif command_exists yum; then
        yum install -y libatomic
      else
        die "Node.js requires libatomic.so.1. Install the libatomic runtime package manually."
      fi
    fi
  fi
  "${node_binary}" --version >/dev/null 2>&1 ||
    die "Node.js cannot start. Check shared-library dependencies with: ldd ${node_binary}"
}

install_libatomic_with_dnf() {
  local dnf_bin=$1
  local disabled_repos=${AI_SETUP_DNF_DISABLE_REPO:-'*update*'}

  # A stale mirror or proxy can serve a repomd.xml whose checksum does not
  # match its metadata. Retry after discarding cached metadata before using a
  # narrow repository fallback; this keeps normal repository selection intact.
  if "${dnf_bin}" install -y libatomic; then
    return 0
  fi
  log "dnf metadata download failed; clearing cached metadata and retrying"
  "${dnf_bin}" clean all >/dev/null 2>&1 || true
  if "${dnf_bin}" --refresh install -y libatomic; then
    return 0
  fi

  log "dnf update repository is unavailable; retrying with --disablerepo=${disabled_repos}"
  "${dnf_bin}" --refresh --disablerepo="${disabled_repos}" install -y libatomic
}

install_node_runtime() {
  [[ -x "${NODE_INSTALL_DIR}/bin/node" ]] && return 0
  require_command curl
  require_command sha256sum
  require_command tar

  local resolved_platform latest_archive archive_root checksum
  resolved_platform=$(node_platform)

  latest_archive=$(curl --fail --silent --show-error --location \
    https://nodejs.org/dist/latest/SHASUMS256.txt |
    awk -v platform="${resolved_platform}" \
      '$2 ~ "^node-v[0-9]+\\.[0-9]+\\.[0-9]+-" platform "\\.tar\\.xz$" {print $2; exit}')
  [[ -n "${latest_archive}" ]] || die "Could not resolve the latest Node.js archive for ${resolved_platform}."
  archive_root=${latest_archive%.tar.xz}
  TEMP_DIR=$(mktemp -d "${AGENT_DIR}/.node-download.XXXXXXXX")
  local archive_path="${TEMP_DIR}/${latest_archive}"
  log "Downloading ${latest_archive}"
  curl --fail --silent --show-error --location \
    "https://nodejs.org/dist/latest/${latest_archive}" --output "${archive_path}"
  checksum=$(curl --fail --silent --show-error --location \
    https://nodejs.org/dist/latest/SHASUMS256.txt |
    awk -v archive="${latest_archive}" '$2 == archive {print $1; exit}')
  [[ -n "${checksum}" ]] || die "Missing SHA256 checksum for ${latest_archive}."
  (cd "${TEMP_DIR}" && printf '%s  %s\n' "${checksum}" "${latest_archive}" | sha256sum -c -)
  tar -xJf "${archive_path}" -C "${TEMP_DIR}"
  [[ -d "${TEMP_DIR}/${archive_root}" ]] || die "Invalid Node.js archive: ${archive_root}"
  rm -rf -- "${NODE_INSTALL_DIR}"
  mv "${TEMP_DIR}/${archive_root}" "${NODE_INSTALL_DIR}"
  rm -rf -- "${TEMP_DIR}"
  TEMP_DIR=""
  local node_binary="${NODE_INSTALL_DIR}/bin/node"
  ensure_node_runtime_dependencies "${node_binary}"
  log "Using Node.js $(${node_binary} --version)"
}

require_supported_node_version() {
  local node_binary=$1
  local node_major
  node_major=$(${node_binary} -p 'Number(process.versions.node.split(".")[0])')
  ((node_major >= 22)) ||
    die "Node.js 22 or newer is required; found $(${node_binary} --version)."
}

service_pid() {
  [[ -f "${CCR_SERVICE_FILE}" ]] || return 0
  sed -nE 's/.*"pid"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' \
    "${CCR_SERVICE_FILE}" | head -n 1
}

install_cli_packages() {
  log "Installing latest Claude Code, Codex, and Claude Code Router"
  if ! env \
    PATH="${NODE_INSTALL_DIR}/bin:${PATH}" \
    NPM_CONFIG_PREFIX="${NODE_INSTALL_DIR}" \
    NPM_CONFIG_CACHE="${AGENT_CACHE_DIR}/npm" \
    "${NODE_INSTALL_DIR}/bin/npm" install -g \
      --allow-scripts=@anthropic-ai/claude-code,better-sqlite3 \
      @anthropic-ai/claude-code@latest \
      @openai/codex@latest \
      @musistudio/claude-code-router@latest; then
    log "ERROR: npm failed in ${NODE_INSTALL_DIR}"
    return 1
  fi

  local claude_package="${NODE_INSTALL_DIR}/lib/node_modules/@anthropic-ai/claude-code"
  [[ -f "${claude_package}/install.cjs" ]] ||
    die "Claude Code postinstall script is missing."
  log "Ensuring the Claude Code native binary is installed"
  (cd "${claude_package}" && "${NODE_INSTALL_DIR}/bin/node" install.cjs)
}

ccr_package_dir() {
  printf '%s\n' "$1/lib/node_modules/@musistudio/claude-code-router"
}

ensure_better_sqlite() {
  local ccr_package
  ccr_package=$(ccr_package_dir "${NODE_INSTALL_DIR}")

  if [[ -d "${ccr_package}/node_modules/better-sqlite3" ]] &&
     ! (cd "${ccr_package}" && "${NODE_INSTALL_DIR}/bin/node" -e \
       'const D=require("better-sqlite3"); const d=new D(":memory:"); d.close()'); then
    log "Rebuilding better-sqlite3"
    (cd "${ccr_package}" && env \
      PATH="${NODE_INSTALL_DIR}/bin:${PATH}" \
      NPM_CONFIG_PREFIX="${NODE_INSTALL_DIR}" \
      NPM_CONFIG_CACHE="${AGENT_CACHE_DIR}/npm" \
      "${NODE_INSTALL_DIR}/bin/npm" rebuild better-sqlite3 \
        --foreground-scripts \
        --allow-scripts=better-sqlite3)
  fi

  (cd "${ccr_package}" && "${NODE_INSTALL_DIR}/bin/node" -e \
    'const D=require("better-sqlite3"); const d=new D(":memory:"); d.close()') ||
    die "better-sqlite3 could not be loaded."
}

validate_tools_installation() {
  local executable ccr_package

  for executable in node npm claude codex ccr; do
    [[ -x "${NODE_INSTALL_DIR}/bin/${executable}" ]] ||
      die "Installation is missing ${NODE_INSTALL_DIR}/bin/${executable}"
  done

  ccr_package=$(ccr_package_dir "${NODE_INSTALL_DIR}")
  [[ -f "${ccr_package}/package.json" ]] ||
    die "Installation is missing ${ccr_package}/package.json"
  log "Installed $("${NODE_INSTALL_DIR}/bin/claude" --version)"
  log "Installed $("${NODE_INSTALL_DIR}/bin/codex" --version)"
  log "Installed Claude Code Router $("${NODE_INSTALL_DIR}/bin/node" -p \
    "require('${ccr_package}/package.json').version")"
}

install_latest_tools() {
  if ((DRY_RUN)); then
    log "Would install the tools directly in ${NODE_INSTALL_DIR}"
    run npm install -g \
      --allow-scripts=@anthropic-ai/claude-code,better-sqlite3 \
      @anthropic-ai/claude-code@latest \
      @openai/codex@latest \
      @musistudio/claude-code-router@latest
    return 0
  fi

  install_node_runtime
  ensure_node_runtime_dependencies "${NODE_INSTALL_DIR}/bin/node"
  require_supported_node_version "${NODE_INSTALL_DIR}/bin/node"
  local pid
  pid=$(service_pid)
  if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
    stop_ccr_service
  fi
  install_cli_packages
  ensure_better_sqlite
  validate_tools_installation
  write_runtime_files
  log 'CCR will be started after selecting unused gateway ports during configuration.'
}

# Token-scoped model discovery and Codex profile rendering.
parse_gateway_models() {
  jq -c '[.data[]?
    | if type == "object" then .id elif type == "string" then . else empty end
    | select(type == "string" and length > 0)] | unique'
}

discover_token_models() {
  local label=$1
  local base_url=$2
  local api_key=$3
  local result_var=$4
  local response discovered_models detail last_status

  if [[ -z "${api_key}" ]]; then
    printf -v "${result_var}" '%s' '[]'
    log "${label}: no token configured; no models will be listed"
    return 0
  fi

  curl --silent --show-error --max-time 20 \
    -H "Authorization: Bearer ${api_key}" "${base_url%/}/models" 2>/dev/null \
    >"${TMPDIR:-/tmp}/ai-setup-models-response.${$}" || true
  last_status=$?
  response=$(cat "${TMPDIR:-/tmp}/ai-setup-models-response.${$}" 2>/dev/null || true)
  rm -f -- "${TMPDIR:-/tmp}/ai-setup-models-response.${$}"
  detail=''
  if [ -n "${response}" ]; then
    detail=$(jq -r 'if type == "object" then
      (.message // .error.message // .error // .code // empty)
    else empty end' <<<"${response}" 2>/dev/null || true)
  fi

  discovered_models=$(jq -c '[.data[]? | if type == "object" then .id elif type == "string" then . else empty end | select(type == "string" and length > 0)] | unique' <<<"${response}" 2>/dev/null || true)
  if [[ -n "${discovered_models}" ]] && (( $(jq 'length' <<<"${discovered_models}") > 0 )); then
    printf -v "${result_var}" '%s' "${discovered_models}"
    log "${label}: token exposes $(jq 'length' <<<"${discovered_models}") model(s)"
    return 0
  fi

  printf -v "${result_var}" '%s' '[]'
  warn "${label}: skipped (could not discover any models for this token at ${base_url%/}/models)"
  if [ -n "${detail}" ]; then
    warn "${label}: upstream reported: ${detail}"
  elif [ "${last_status}" -ne 0 ]; then
    warn "${label}: upstream model-discovery request failed"
  fi
  log "${label}: other configured gateways will continue to be used"
}

probe_responses_models() {
  local label=$1
  local base_url=$2
  local api_key=$3
  local candidates=$4
  local result_var=$5
  local model payload status
  local verified_models='[]'

  if [[ -z "${api_key}" ]]; then
    printf -v "${result_var}" '%s' '[]'
    log "${label}: no token configured; no models will be listed"
    return 0
  fi

  while IFS= read -r model; do
    payload=$(jq -cn --arg model "${model}" \
      '{model:$model,input:"Reply with OK.",max_output_tokens:16,stream:false}')
    status=$(curl --silent --show-error --max-time 60 --output /dev/null \
      --write-out '%{http_code}' \
      -H "Authorization: Bearer ${api_key}" \
      -H 'content-type: application/json' \
      --data-binary "${payload}" "${base_url%/}/responses" 2>/dev/null || true)
    if [[ "${status}" =~ ^2[0-9][0-9]$ ]]; then
      verified_models=$(jq -c --arg model "${model}" \
        '. + [$model] | unique' <<<"${verified_models}")
      log "${label}: ${model} is available"
    else
      log "${label}: ${model} is unavailable for this token (HTTP ${status:-request-failed})"
    fi
  done < <(jq -r '.[]' <<<"${candidates}")

  if (( $(jq 'length' <<<"${verified_models}") == 0 )); then
    printf -v "${result_var}" '%s' '[]'
    warn "${label}: skipped (none of the configured candidate models are usable with this token)"
    log "${label}: other configured gateways will continue to be used"
    return 0
  fi
  printf -v "${result_var}" '%s' "${verified_models}"
  log "${label}: token can use $(jq 'length' <<<"${verified_models}") verified model(s)"
}

discover_configured_models() {
  if ((DRY_RUN)); then
    log 'Would discover the model list authorized by each configured token'
    return 0
  fi
  probe_responses_models 'Volcano AI Gateway' \
    'https://st8tp3ajl0df3n8b8l8qu.apigateway-cn-beijing.volceapi.com/v1' \
    "${VOLCANO_AI_GATEWAY_API_KEY:-}" "${VOLCANO_MODEL_CANDIDATES}" VOLCANO_MODELS
  discover_token_models 'Alibaba Bailian' \
    'https://dashscope.aliyuncs.com/compatible-mode/v1' \
    "${BAILIAN_API_KEY:-}" BAILIAN_MODELS
  discover_token_models 'BlackAI GPT' 'https://www.blackaicoding.com/v1' \
    "${BLACKAICODING_GPT_API_KEY:-}" BLACKAI_GPT_MODELS
  discover_token_models 'BlackAI Claude' 'https://www.blackaicoding.com/v1' \
    "${BLACKAICODING_CLAUDE_API_KEY:-}" BLACKAI_CLAUDE_MODELS
}

select_profile_model() {
  local models=$1
  shift
  local candidate
  for candidate in "$@"; do
    if jq -e --arg model "${candidate}" 'index($model) != null' <<<"${models}" >/dev/null; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  jq -r '.[0] // empty' <<<"${models}"
}

filter_codex_model_catalog() {
  local catalog=$1
  local models=$2
  jq --argjson allowed "${models}" \
    '.models = [.models[] | select(.slug as $slug | $allowed | index($slug) != null)]' \
    <<<"${catalog}"
}

augment_codex_model_catalog() {
  local catalog=$1
  local models=$2
  local profile=${3:-direct}
  jq \
    --argjson custom "${models}" \
    --arg profile "${profile}" \
    '($custom | unique) as $custom
     | .models as $existing
     | .models += [
         $custom[] as $slug
         | select($existing | map(.slug) | index($slug) | not)
         | {
             slug:$slug,
             display_name:$slug,
             description:("Custom gateway model " + $slug),
             default_reasoning_level:"high",
             supported_reasoning_levels:[{effort:"high",description:"High reasoning"}],
             shell_type:"shell_command",
             visibility:"list",
             supported_in_api:true,
             priority:100,
             additional_speed_tiers:[],
             service_tiers:[],
             availability_nux:{message:"This model is served through your configured gateway."},
             upgrade:null,
             base_instructions:"You are Codex, a coding agent.",
             default_reasoning_summary:"none",
             support_verbosity:false,
             truncation_policy:{mode:"tokens",limit:10000},
             supports_parallel_tool_calls:false,
             supports_image_detail_original:false,
             apply_patch_tool_type:"freeform",
             web_search_tool_type:"text_and_image",
             context_window:(if ($slug | startswith("claude-")) then 200000
                             elif ($slug | test("^(deepseek|qwen)")) then 1000000
                             else 128000 end),
             max_context_window:(if ($slug | startswith("claude-")) then 200000
                                 elif ($slug | test("^(deepseek|qwen)")) then 1000000
                                 else 128000 end),
             effective_context_window_percent:95,
             experimental_supported_tools:[],
             input_modalities:["text"],
             tool_mode:(if $profile == "volcano" then null else "code_mode_only" end),
             node_repl_disabled:false,
             node_repl_auto_review_required:false,
             multi_agent_version:"v2",
             use_responses_lite:($profile != "volcano"),
             supports_search_tool:($profile != "volcano")
           }
       ]' <<<"${catalog}"
}

codex_model_catalog_file() {
  printf '%s/%s.json\n' "${CODEX_MODEL_CATALOG_DIR}" "$1"
}

write_codex_model_catalog() {
  local profile=$1
  local models=$2
  local catalog_file
  catalog_file=$(codex_model_catalog_file "${profile}")
  if ((DRY_RUN)); then
    log "Would generate ${catalog_file} from Codex's built-in model metadata"
    return 0
  fi
  TEMP_DIR=$(mktemp -d "${AGENT_DIR}/.codex-catalog.XXXXXXXX")
  local base_catalog="${TEMP_DIR}/base-models.json"
  mkdir -p "${TEMP_DIR}/home"
  CODEX_HOME="${TEMP_DIR}/home" "${NODE_INSTALL_DIR}/bin/codex" debug models --bundled \
    >"${base_catalog}"
  local catalog
  catalog=$(filter_codex_model_catalog "$(<"${base_catalog}")" "${models}")
  catalog=$(augment_codex_model_catalog "${catalog}" "${models}" "${profile}")
  write_secure_file "${catalog_file}" "${catalog}"
  rm -rf -- "${TEMP_DIR}"
  TEMP_DIR=""
}

codex_profile() {
  local profile=$1 model provider name base_url env_key models note=''
  case "${profile}" in
    volcano)
      provider=volcano-ai-gateway; name='Volcano AI Gateway'
      base_url='https://st8tp3ajl0df3n8b8l8qu.apigateway-cn-beijing.volceapi.com/v1'
      env_key=VOLCANO_AI_GATEWAY_API_KEY
      models=${VOLCANO_MODELS}
      # Preferred priority is encoded by the order of the alternatives below;
      # keep this in sync with `codex_model_compatibility_mode`.
      model=$(select_profile_model "${models}" \
        'deepseek-v4-flash' 'deepseek-v4-pro' 'doubao-seed-2.1-pro' \
        'glm-5.2' 'qwen3.7-max' 'qwen3.7-plus')
      note='# Direct Volcano Responses access does not support Codex tool items or token-accurate context windows.'
      ;;
    bailian)
      provider=bailian; name='Alibaba Bailian'
      base_url='https://dashscope.aliyuncs.com/compatible-mode/v1'; env_key=BAILIAN_API_KEY
      models=${BAILIAN_MODELS}
      model=$(select_profile_model "${models}" qwen3.7-plus glm-5.2)
      note='# This profile requires the upstream gateway to support the Responses API.'
      ;;
    blackai-gpt)
      provider=blackaicoding-gpt; name='BlackAI Coding (GPT)'
      base_url='https://www.blackaicoding.com/v1'; env_key=BLACKAICODING_GPT_API_KEY
      models=${BLACKAI_GPT_MODELS}
      model=$(select_profile_model "${models}" gpt-5.6-sol gpt-5.6 gpt-5.5)
      ;;
    blackai-claude)
      provider=blackaicoding-claude; name='BlackAI Coding (Claude/Grok)'
      base_url='https://www.blackaicoding.com/v1'; env_key=BLACKAICODING_CLAUDE_API_KEY
      models=${BLACKAI_CLAUDE_MODELS}
      model=$(select_profile_model "${models}" claude-sonnet-4-6 claude-sonnet-5 claude-opus-4-6)
      note='# Some Claude/Grok models may reject Codex web_search tools with HTTP 422.'
      ;;
    *) die "Unknown Codex profile: ${profile}" ;;
  esac
  [[ -n "${model}" ]] || die "No token-authorized models are available for profile ${profile}."
  printf '%s\n' '# Managed by set_claude_provider_keys.sh.' "${note}" \
    "model = \"${model}\"" "model_provider = \"${provider}\"" \
    "model_catalog_json = \"$(codex_model_catalog_file "${profile}")\"" \
    'model_reasoning_effort = "high"' \
    'approval_policy = "never"' \
    'sandbox_mode = "danger-full-access"' 'web_search = "disabled"' \
    '' "[model_providers.${provider}]" \
    "name = \"${name}\"" "base_url = \"${base_url}\"" \
    "env_key = \"${env_key}\"" 'wire_api = "responses"' "models = ${models}" \
    '' '[features]' 'multi_agent = false' ''
}

profile_model_list() {
  case "$1" in
    volcano) printf '%s\n' "${VOLCANO_MODELS}" ;;
    bailian) printf '%s\n' "${BAILIAN_MODELS}" ;;
    blackai-gpt) printf '%s\n' "${BLACKAI_GPT_MODELS}" ;;
    blackai-claude) printf '%s\n' "${BLACKAI_CLAUDE_MODELS}" ;;
    *) die "Unknown Codex profile: $1" ;;
  esac
}

codex_provider_block() {
  local profile=$1 provider name base_url env_key models
  case "${profile}" in
    volcano)
      provider=volcano-ai-gateway; name='Volcano AI Gateway'
      base_url='https://st8tp3ajl0df3n8b8l8qu.apigateway-cn-beijing.volceapi.com/v1'
      env_key=VOLCANO_AI_GATEWAY_API_KEY
      ;;
    bailian)
      provider=bailian; name='Alibaba Bailian'
      base_url='https://dashscope.aliyuncs.com/compatible-mode/v1'
      env_key=BAILIAN_API_KEY
      ;;
    blackai-gpt)
      provider=blackaicoding-gpt; name='BlackAI Coding (GPT)'
      base_url='https://www.blackaicoding.com/v1'
      env_key=BLACKAICODING_GPT_API_KEY
      ;;
    blackai-claude)
      provider=blackaicoding-claude; name='BlackAI Coding (Claude/Grok)'
      base_url='https://www.blackaicoding.com/v1'
      env_key=BLACKAICODING_CLAUDE_API_KEY
      ;;
    *) die "Unknown Codex profile: ${profile}" ;;
  esac
  models=$(profile_model_list "${profile}")
  [[ "${models}" != '[]' ]] || return 0
  printf '%s\n' "[model_providers.${provider}]" \
    "name = \"${name}\"" "base_url = \"${base_url}\"" \
    "env_key = \"${env_key}\"" 'wire_api = "responses"' "models = ${models}" ''
}

write_codex_global_config() {
  # 全局配置同时注册已配置的 provider，使旧会话无需 profile 也能解析 provider。
  local global_config profile provider_block
  global_config='# Managed by set_claude_provider_keys.sh — global defaults.'
  global_config+=$'\n'"approval_policy = \"never\""
  global_config+=$'\n'"sandbox_mode = \"danger-full-access\""
  global_config+=$'\n\n# BEGIN ai-setup global Codex providers'
  for profile in volcano bailian blackai-gpt blackai-claude; do
    provider_block=$(codex_provider_block "${profile}")
    [[ -n "${provider_block}" ]] || continue
    global_config+=$'\n'"${provider_block}"
  done
  global_config+=$'\n# END ai-setup global Codex providers'
  write_secure_file "${CODEX_DIR}/config.toml" "${global_config}"
}

write_codex_profiles() {
  run mkdir -p "${CODEX_DIR}" "${CODEX_MODEL_CATALOG_DIR}"
  local legacy_catalog="${CODEX_DIR}/model-catalog.json"
  [[ ! -f "${legacy_catalog}" ]] || run unlink "${legacy_catalog}"
  write_codex_global_config
  local profile models profile_file catalog_file
  for profile in volcano bailian blackai-gpt blackai-claude; do
    models=$(profile_model_list "${profile}")
    profile_file="${CODEX_DIR}/${profile}.config.toml"
    catalog_file=$(codex_model_catalog_file "${profile}")
    if (( $(jq 'length' <<<"${models}") > 0 )); then
      write_codex_model_catalog "${profile}" "${models}"
      write_secure_file "${profile_file}" "$(codex_profile "${profile}")"
    else
      [[ ! -f "${profile_file}" ]] || run unlink "${profile_file}"
      [[ ! -f "${catalog_file}" ]] || run unlink "${catalog_file}"
    fi
  done
}

write_codex_environment() {
  local content=''
  local configured_count=0
  local name value
  for name in "${GATEWAY_KEY_NAMES[@]}"; do
    value=${!name:-}
    [[ -n "${value}" ]] || continue
    printf -v content '%s%s=%q\nexport %s\n' "${content}" "${name}" "${value}" "${name}"
    ((configured_count += 1))
  done
  write_secure_file "${CODEX_ENV_FILE}" "${content%$'\n'}"
  write_runtime_files
  if ((DRY_RUN)); then
    log "Would save ${configured_count} gateway key(s) to ${CODEX_ENV_FILE}"
  else
    log "Saved ${configured_count} gateway key(s) to ${CODEX_ENV_FILE}"
  fi
}

# CCR service lifecycle, RPC transport, and provider configuration rendering.
port_is_available() {
  "${NODE_INSTALL_DIR}/bin/node" - "${CCR_HOST}" "$1" <<'NODE'
const net = require('net');
const server = net.createServer();
server.once('error', () => process.exit(1));
server.listen(Number(process.argv[3]), process.argv[2], () => {
  server.close(() => process.exit(0));
});
NODE
}

select_ccr_ports() {
  local base
  for ((base=CCR_PORT_SCAN_START; base<=65000; base+=3)); do
    if port_is_available "${base}" &&
       port_is_available "$((base + 1))" &&
       port_is_available "$((base + 2))"; then
      CCR_GATEWAY_PORT=${base}
      CCR_CORE_PORT=$((base + 1))
      CCR_MANAGEMENT_PORT=$((base + 2))
      CCR_GATEWAY_URL="http://${CCR_HOST}:${CCR_GATEWAY_PORT}"
      log "Selected CCR ports: gateway=${CCR_GATEWAY_PORT}, core=${CCR_CORE_PORT}, management=${CCR_MANAGEMENT_PORT}"
      return 0
    fi
  done
  die 'Could not find three consecutive unused ports for CCR.'
}

wait_for_ccr_service() {
  local attempt service_url pid
  for ((attempt=1; attempt<=30; attempt+=1)); do
    if [[ -f "${CCR_SERVICE_FILE}" ]]; then
      service_url=$(jq -r '.url // empty' "${CCR_SERVICE_FILE}")
      pid=$(jq -r '.pid // 0' "${CCR_SERVICE_FILE}")
      if [[ -n "${service_url}" ]] && kill -0 "${pid}" 2>/dev/null &&
         curl --fail --silent --show-error --max-time 2 "${service_url%%\?*}" >/dev/null 2>&1; then
        return 0
      fi
    fi
    sleep 1
  done
  die 'CCR management service did not become ready.'
}

stop_ccr_service() {
  require_command ccr
  if ((DRY_RUN)); then
    run ccr stop
    return 0
  fi

  local pid attempt
  pid=$(service_pid)
  ccr stop >/dev/null 2>&1 || true
  [[ -n "${pid}" ]] || return 0

  for ((attempt=1; attempt<=20; attempt+=1)); do
    kill -0 "${pid}" 2>/dev/null || return 0
    sleep 1
  done
  die "CCR PID ${pid} is still running after 'ccr stop'."
}

start_ccr_service() {
  local gateway_mode=$1
  require_command ccr
  require_command curl
  require_command jq
  if [[ "${gateway_mode}" == gateway ]]; then
    run ccr start --host "${CCR_HOST}" --port "${CCR_MANAGEMENT_PORT}" --no-open --gateway >/dev/null
  else
    run ccr start --host "${CCR_HOST}" --port "${CCR_MANAGEMENT_PORT}" --no-open --no-gateway >/dev/null
  fi
  wait_for_ccr_service
}

load_ccr_connection() {
  local service_url
  service_url=$(jq -r '.url' "${CCR_SERVICE_FILE}")
  CCR_WEB_TOKEN=${service_url##*ccr_web_token=}
  CCR_MANAGEMENT_URL=${service_url%%\?*}
  CCR_MANAGEMENT_URL=${CCR_MANAGEMENT_URL%/}
}

ccr_rpc() {
  local request=$1
  printf '%s' "${request}" | curl --fail --silent --show-error \
    -H "x-ccr-web-auth: ${CCR_WEB_TOKEN}" \
    -H 'content-type: application/json' \
    --data-binary @- \
    "${CCR_MANAGEMENT_URL}/api/ccr/rpc"
}

prepare_ccr_management_service() {
  stop_ccr_service
  select_ccr_ports
  start_ccr_service no-gateway
  load_ccr_connection
}

require_ccr_rpc_success() {
  local response=$1
  local fallback_message=$2
  [[ "$(jq -r '.ok' <<<"${response}")" == true ]] ||
    die "$(jq -r --arg fallback "${fallback_message}" '.error.message // $fallback' <<<"${response}")"
}

fetch_ccr_config() {
  local response
  response=$(ccr_rpc '{"method":"getConfig","args":[]}')
  require_ccr_rpc_success "${response}" "Failed to read CCR configuration."
  printf '%s\n' "${response}"
}

resolve_ccr_local_key() {
  local config_response=$1
  local local_key
  local_key=$(jq -r '.value.APIKEY // ""' <<<"${config_response}")
  [[ -n "${local_key}" ]] || local_key=$(openssl rand -hex 32)
  printf '%s\n' "${local_key}"
}

build_ccr_config() {
  local config_response=$1
  local local_key=$2
  local volcano_key=$3
  local bailian_key=$4
  local gateway_host=$5
  local gateway_port=$6
  local core_port=$7
  local gateway_url=$8
  local volcano_models=$9
  local bailian_models=${10}
  local volcano_fast_model=${11}
  local volcano_pro_model=${12}
  local blackai_claude_key=${13:-}
  local blackai_claude_models=${14:-'[]'}

  jq \
    --arg local_key "${local_key}" \
    --arg volcano_key "${volcano_key}" \
    --arg bailian_key "${bailian_key}" \
    --arg gateway_host "${gateway_host}" \
    --argjson gateway_port "${gateway_port}" \
    --argjson core_port "${core_port}" \
    --arg gateway_url "${gateway_url}" \
    --argjson volcano_models "${volcano_models}" \
    --argjson bailian_models "${bailian_models}" \
    --arg volcano_fast_model "${volcano_fast_model}" \
    --arg volcano_pro_model "${volcano_pro_model}" \
    --arg blackai_claude_key "${blackai_claude_key}" \
    --argjson blackai_claude_models "${blackai_claude_models}" \
    --arg claude_settings_file "${CLAUDE_SETTINGS_FILE}" \
    --arg codex_home "${CODEX_DIR}" \
    '.value as $cfg
     | ([$cfg.Providers[]? | select(.id == "volcano-ai-gateway" or .name == "火山AI网关")][0].apiKey // "") as $old_volcano
     | ([$cfg.Providers[]? | select(.id == "bailian" or .name == "蓝区百炼")][0].apiKey // "") as $old_bailian
     | ([$cfg.Providers[]? | select(.id == "zhipu" or .name == "蓝区智谱")][0].apiKey // "") as $old_zhipu
     | ([$cfg.Providers[]? | select(.id == "xiyu" or .name == "蓝区稀宇")][0].apiKey // "") as $old_xiyu
     | ([$cfg.Providers[]? | select(.id == "blackai-claude" or .name == "BlackAI Claude")][0].apiKey // "") as $old_blackai_claude
     | (if $volcano_key != "" then $volcano_key else $old_volcano end) as $volcano
     | (if $bailian_key != "" then $bailian_key else $old_bailian end) as $bailian
     | (if $blackai_claude_key != "" then $blackai_claude_key else $old_blackai_claude end) as $blackai_claude
     | ($cfg // {})
     | .profile = (.profile // {})
     | .profile.profiles = (.profile.profiles // [])
     | .APIKEY = $local_key
     | .gateway = ((.gateway // {})
         + {
             enabled:true,
             host:$gateway_host,
             port:$gateway_port,
             coreHost:$gateway_host,
             corePort:$core_port
           })
     | .routerEndpoint = $gateway_url
     | .Providers = (
         [.Providers[]? | select(
           (.id != "volcano-ai-gateway" and .name != "火山AI网关") and
           (.id != "bailian" and .name != "蓝区百炼") and
           (.id != "zhipu" and .name != "蓝区智谱") and
           (.id != "xiyu" and .name != "蓝区稀宇")
           and (.id != "blackai-claude" and .name != "BlackAI Claude")
         )] +
         [{
           id:"volcano-ai-gateway", name:"火山AI网关",
           enabled:($volcano != "" and $volcano != "Your API Key" and ($volcano_models | length) > 0),
           baseUrl:"https://st8tp3ajl0df3n8b8l8qu.apigateway-cn-beijing.volceapi.com/v1",
           apiKey:$volcano, type:"openai_chat_completions",
           models:$volcano_models
         },{
           id:"bailian", name:"蓝区百炼",
           enabled:($bailian != "" and $bailian != "sk-xxxx" and ($bailian_models | length) > 0),
           baseUrl:"https://dashscope.aliyuncs.com/compatible-mode/v1",
           apiKey:$bailian, type:"openai_chat_completions",
           models:$bailian_models
         },{
           id:"blackai-claude", name:"BlackAI Claude",
           enabled:($blackai_claude != "" and ($blackai_claude_models | length) > 0),
           baseUrl:"https://www.blackaicoding.com/v1",
           apiKey:$blackai_claude, type:"openai_chat_completions",
           models:$blackai_claude_models
         },{
           id:"zhipu", name:"蓝区智谱", enabled:false,
           baseUrl:"https://open.bigmodel.cn/api/paas/v4",
           apiKey:$old_zhipu, type:"openai_chat_completions",
           models:["glm-5.1","glm-5.2"]
         },{
           id:"xiyu", name:"蓝区稀宇", enabled:false,
           baseUrl:"https://api.minimaxi.com/anthropic/v1",
           apiKey:$old_xiyu, type:"anthropic_messages", models:["MiniMax-M3"]
         }]
       )
     | .preferredProvider = (if $volcano_fast_model != "" then "火山AI网关"
                             elif ($bailian_models | length) > 0 then "蓝区百炼"
                             else (.preferredProvider // "") end)
     | if $volcano_fast_model != "" then
         .profile.claudeCode.model = ("火山AI网关/" + $volcano_fast_model)
         | .profile.claudeCode.settingsFile = $claude_settings_file
         | .profile.claudeCode.haikuModel = ("火山AI网关/" + $volcano_fast_model)
         | .profile.claudeCode.sonnetModel = ("火山AI网关/" + $volcano_fast_model)
         | .profile.claudeCode.opusModel = ("火山AI网关/" + $volcano_pro_model)
       else . end
     | .profile.profiles |= map(
         if .agent == "claude-code" and $volcano_fast_model != "" then
           .model = ("火山AI网关/" + $volcano_fast_model)
           | .settingsFile = $claude_settings_file
           | .haikuModel = ("火山AI网关/" + $volcano_fast_model)
           | .sonnetModel = ("火山AI网关/" + $volcano_fast_model)
           | .opusModel = ("火山AI网关/" + $volcano_pro_model)
         elif .agent == "codex" then
           .codexHome = $codex_home
         else . end
       )' <<<"${config_response}"
}

save_ccr_config() {
  local config=$1
  local save_request save_response
  save_request=$(jq '{method:"saveConfig",args:[.,{applyProfile:false}]}' <<<"${config}")
  save_response=$(ccr_rpc "${save_request}")
  require_ccr_rpc_success "${save_response}" "Failed to save CCR configuration."
}

restart_ccr_gateway() {
  stop_ccr_service
  start_ccr_service gateway
}

configure_ccr() {
  if ((DRY_RUN)); then
    log "Would configure CCR providers and Claude Code's local gateway"
    return 0
  fi

  local config_response local_key config volcano_fast_model volcano_pro_model
  prepare_ccr_management_service
  write_ccr_runtime_file
  config_response=$(fetch_ccr_config)
  local_key=$(resolve_ccr_local_key "${config_response}")
  volcano_fast_model=$(select_profile_model "${VOLCANO_MODELS}" \
    deepseek-v4-flash deepseek-v4-pro)
  volcano_pro_model=$(select_profile_model "${VOLCANO_MODELS}" \
    deepseek-v4-pro "${volcano_fast_model}")
  config=$(build_ccr_config \
    "${config_response}" \
    "${local_key}" \
    "${VOLCANO_AI_GATEWAY_API_KEY:-}" \
    "${BAILIAN_API_KEY:-}" \
    "${CCR_HOST}" \
    "${CCR_GATEWAY_PORT}" \
    "${CCR_CORE_PORT}" \
    "${CCR_GATEWAY_URL}" \
    "${VOLCANO_MODELS}" \
    "${BAILIAN_MODELS}" \
    "${volcano_fast_model}" \
    "${volcano_pro_model}" \
    "${BLACKAICODING_CLAUDE_API_KEY:-}" \
    "${BLACKAI_CLAUDE_MODELS}")
  save_ccr_config "${config}"

  restart_ccr_gateway
  configure_claude_settings "${local_key}" "${CCR_GATEWAY_URL}" \
    "${volcano_fast_model}" "${volcano_pro_model}"
  configure_ccr_autostart
}

build_claude_settings() {
  local settings=$1
  local local_key=$2
  local gateway_url=$3
  local volcano_fast_model=${4:-}
  local volcano_pro_model=${5:-}
  jq --arg key "${local_key}" --arg gateway_url "${gateway_url}" \
    --arg volcano_fast_model "${volcano_fast_model}" \
    --arg volcano_pro_model "${volcano_pro_model}" '
    .env = ((.env // {})
      | del(
          .ANTHROPIC_API_KEY,
          .ANTHROPIC_AUTH_TOKEN,
          .ANTHROPIC_FEDERATION_RULE_ID,
          .ANTHROPIC_IDENTITY_TOKEN_FILE,
          .ANTHROPIC_DEFAULT_HAIKU_MODEL,
          .ANTHROPIC_ORGANIZATION_ID,
          .ANTHROPIC_WORKSPACE_ID,
          .CCR_CLAUDE_CODE_MODEL,
          .CODEXL_CLAUDE_CODE_MODEL
        )
      + {
          ANTHROPIC_AUTH_TOKEN:$key,
          ANTHROPIC_BASE_URL:$gateway_url,
          ANTHROPIC_API_BASE_URL:$gateway_url,
          CLAUDE_AGENT_API_BASE_URL:$gateway_url,
          ANTHROPIC_MODEL:"claude-sonnet-4-6",
          ANTHROPIC_DEFAULT_SONNET_MODEL:"claude-sonnet-4-6",
          ANTHROPIC_DEFAULT_OPUS_MODEL:"claude-opus-4-6",
          CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY:"1"
        })
    | .model = "sonnet"
    | if $volcano_fast_model != "" then
        .modelOverrides = (((.modelOverrides // {})
          | del(.["claude-haiku-4-5-20251001"]))
          + {
              "claude-sonnet-4-6":("火山AI网关/" + $volcano_fast_model),
              "claude-opus-4-6":("火山AI网关/" + $volcano_pro_model),
              "claude-opus-4-7":("火山AI网关/" + $volcano_pro_model),
              "claude-fable-5":("火山AI网关/" + $volcano_fast_model)
            })
      else . end' <<<"${settings}"
}

configure_claude_settings() {
  local local_key=$1
  local gateway_url=$2
  local volcano_fast_model=${3:-}
  local volcano_pro_model=${4:-}
  local settings='{}'
  local next_settings
  [[ -f "${CLAUDE_SETTINGS_FILE}" ]] && settings=$(<"${CLAUDE_SETTINGS_FILE}")
  next_settings=$(build_claude_settings "${settings}" "${local_key}" "${gateway_url}" \
    "${volcano_fast_model}" "${volcano_pro_model}")
  write_secure_file "${CLAUDE_SETTINGS_FILE}" "${next_settings}"
}

configure_gateway_keys() {
  if ((DRY_RUN)); then
    log "Would prompt for Volcano, Bailian, BlackAI GPT, and BlackAI Claude keys"
    return 0
  fi

  printf '%s\n' \
    'Enter only the keys you want to add or replace.' \
    'Input is hidden; pressing Enter preserves an existing value or skips an unset key.'

  prompt_secret 'Volcano API key' "${VOLCANO_AI_GATEWAY_API_KEY:-}" VOLCANO_AI_GATEWAY_API_KEY
  prompt_secret 'Bailian API key' "${BAILIAN_API_KEY:-}" BAILIAN_API_KEY
  prompt_secret 'BlackAI GPT API key' "${BLACKAICODING_GPT_API_KEY:-}" BLACKAICODING_GPT_API_KEY
  prompt_secret 'BlackAI Claude/Grok API key' "${BLACKAICODING_CLAUDE_API_KEY:-}" BLACKAICODING_CLAUDE_API_KEY

  export "${GATEWAY_KEY_NAMES[@]}"
}

verify_setup() {
  if ((DRY_RUN)); then
    log "Would validate CLI versions, Codex profiles, Claude JSON, and CCR state"
    return 0
  fi

  claude --version
  codex --version
  local catalog catalog_file profile profile_models profile_stderr
  for profile in volcano bailian blackai-gpt blackai-claude; do
    profile_models=$(profile_model_list "${profile}")
    (( $(jq 'length' <<<"${profile_models}") > 0 )) || continue
    catalog_file=$(codex_model_catalog_file "${profile}")
    catalog=$(codex debug models \
      -c "model_catalog_json=\"${catalog_file}\"")
    jq -e --argjson allowed "${profile_models}" '
      [.models[] | select(.context_window > 0) | .slug] | sort
      == ($allowed | unique | sort)' <<<"${catalog}" >/dev/null ||
      die "Codex catalog for ${profile} does not match its token-authorized models."
    profile_stderr=$(codex --profile "${profile}" debug prompt-input \
      'configuration validation' 2>&1 >/dev/null) ||
      die "Codex could not load the ${profile} profile."
    [[ "${profile_stderr}" != *'Model metadata for '* ]] ||
      die "The ${profile} profile did not load its model metadata."
  done
  jq empty "${CLAUDE_SETTINGS_FILE}"

  load_ccr_connection
  local status
  status=$(ccr_rpc '{"method":"getGatewayStatus","args":[]}')
  [[ "$(jq -r '.ok' <<<"${status}")" == true ]] || die "CCR gateway status check failed."
  local state last_error gateway_url local_key models_response
  state=$(jq -r '.value.state // "unknown"' <<<"${status}")
  last_error=$(jq -r '.value.lastError // empty' <<<"${status}")
  [[ "${state}" != error ]] || die "CCR gateway is in error state: ${last_error:-unknown error}"

  gateway_url=$(jq -r '.env.ANTHROPIC_BASE_URL' "${CLAUDE_SETTINGS_FILE}")
  local_key=$(jq -r '.env.ANTHROPIC_AUTH_TOKEN' "${CLAUDE_SETTINGS_FILE}")
  models_response=$(curl --fail --silent --show-error --max-time 10 \
    -H "Authorization: Bearer ${local_key}" \
    "${gateway_url}/v1/models") ||
    die "CCR client authentication or model discovery failed at ${gateway_url}/v1/models"
  jq -e '.data | type == "array" and length > 0' <<<"${models_response}" >/dev/null ||
    die 'CCR model discovery returned no models.'
  log "CCR gateway state: ${state}; model discovery: ok"
}

# Command-line parsing and top-level phase orchestration.
parse_args() {
  while (($#)); do
    case "$1" in
      --install-only)
        INSTALL_TOOLS=1
        CONFIGURE_GATEWAYS=0
        ;;
      --configure-only)
        INSTALL_TOOLS=0
        CONFIGURE_GATEWAYS=1
        ;;
      --dry-run)
        DRY_RUN=1
        ;;
      -h|--help)
        usage
        EXIT_AFTER_HELP=1
        return 0
        ;;
      *)
        usage >&2
        die "Unknown option: $1"
        ;;
    esac
    shift
  done
}

require_configuration_dependencies() {
  if ((CONFIGURE_GATEWAYS && !DRY_RUN)); then
    require_command jq
    require_command curl
    require_command openssl
  fi
}

configure_gateways_phase() {
  load_persisted_gateway_keys
  configure_gateway_keys
  write_codex_environment
  discover_configured_models
  if (( ! DRY_RUN )) && [[ "${VOLCANO_MODELS}" == "[]" && \
        "${BAILIAN_MODELS}" == "[]" && \
        "${BLACKAI_GPT_MODELS}" == "[]" && \
        "${BLACKAI_CLAUDE_MODELS}" == "[]" ]]; then
    die 'No gateway returned a usable model list; refusing to overwrite the working client/CCR configuration.'
  fi
  write_codex_profiles
  configure_ccr
  verify_setup
}

print_completion_hints() {
  local profile models
  local -a profile_hints=()
  log "New Bash sessions load the environment automatically. Activate it in this current shell:"
  printf '  source %s\n' "${AGENT_ENV_FILE}"
  ((CONFIGURE_GATEWAYS)) || return 0
  for profile in volcano bailian blackai-gpt blackai-claude; do
    models=$(profile_model_list "${profile}")
    (( $(jq 'length' <<<"${models}") > 0 )) || continue
    profile_hints+=("${profile}")
  done
  ((${#profile_hints[@]} > 0)) || return 0
  log 'Then use:'
  for profile in "${profile_hints[@]}"; do
    log "  codex --profile ${profile}"
  done
}

main() {
  parse_args "$@"
  ((EXIT_AFTER_HELP == 0)) || return 0
  initialize_install_layout
  require_configuration_dependencies

  if ((INSTALL_TOOLS)); then
    install_latest_tools
  fi

  if ((CONFIGURE_GATEWAYS)); then
    configure_gateways_phase
  fi

  # Also repair ownership for --install-only and non-systemd installations.
  ensure_setup_user_ownership

  log 'Setup complete.'
  print_completion_hints
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  trap cleanup_temp_dir EXIT
  main "$@"
fi
