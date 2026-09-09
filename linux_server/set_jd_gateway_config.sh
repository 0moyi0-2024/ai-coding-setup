#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

# ============================================================
# set_jd_gateway_config.sh
# 在基础安装之上追加京东（JD LLM Gateway）的 Claude Code 和 Codex 配置
#
# 用法:
#   ./set_jd_gateway_config.sh                  隐藏输入 token，并追加到已有配置
#   ./set_jd_gateway_config.sh --token xxx      非交互式追加配置
#   JD_GATEWAY_TOKEN=xxx ./set_jd_gateway_config.sh
#
# 选项:
#   --token <token>       直接指定 JD 网关 token
#   --output-dir <dir>    指定配置根目录（默认自动识别 /agent 或 $HOME）
#   --standalone          生成独立文件（不写入 ~/.claude ~/.codex，而是输出到 output-dir 下的
#                         claude-settings.json 和 codex-config.toml，方便手动复制）
#   --merge               追加 JD 支持（默认；保留 Claude/Codex 主配置默认行为）
#   --claude-only         只生成 Claude Code 配置
#   --codex-only          只生成 Codex 配置
#   --no-probe            跳过模型探测，直接使用全部候选模型
#   --inline-token        Codex 配置使用 http_headers 内联 token（默认使用 env_key 环境变量引用，更安全）
#   --no-save-token       不把 token 追加到 /agent/env.sh 或用户 shell 配置
#   --dry-run             探测模型并显示写入计划，不实际写文件或打印 token
#   -h, --help            显示帮助
# ============================================================

SCRIPT_NAME=${0##*/}
readonly AGENT_DIR="${AI_SETUP_AGENT_DIR:-/agent}"
CLAUDE_BASE_URL='http://llm-gw.jd.local/anthropic'
CODEX_BASE_URL='http://llm-gw.jd.local/v1'

# JD 网关支持的候选模型（按端点拆分）
CLAUDE_MODEL_CANDIDATES=(
  'claude-opus-4-8[1m]'
  'claude-opus-4-7[1m]'
  'claude-sonnet-5[1m]'
)
CODEX_MODEL_CANDIDATES=(
  'GPT-5.6-Terra-joybuilder'
  'GPT-5.6-Sol-joybuilder'
)

# Codex 子代理模型
CODEX_SUBAGENT_MODEL='GPT-5.6-Sol-joybuilder'

TOKEN=''
OUTPUT_DIR="${HOME}"
STANDALONE=0
MERGE=1
OUTPUT_MODE_EXPLICIT=''
CLAUDE_ONLY=0
CODEX_ONLY=0
NO_PROBE=0
INLINE_TOKEN=0
NO_SAVE_TOKEN=0
DRY_RUN=0
CODEX_CATALOG_FILE=''
OUTPUT_DIR_SET=0
TEMP_DIR=''

log() { printf '[jd-setup] %s\n' "$*" >&2; }
warn() { printf '[jd-setup] WARNING: %s\n' "$*" >&2; }
die() { printf '[jd-setup] ERROR: %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]]; then
    rm -rf -- "${TEMP_DIR}"
  fi
}

usage() {
  cat <<USAGE
用法: ${SCRIPT_NAME} [选项]

在已有 Claude Code、Codex 和 CCR 安装旁追加京东（JD LLM Gateway）配置。
不带模式参数时默认追加 JD 支持，不修改已有主配置，并隐藏输入 token。

选项:
  --token <token>       直接指定 JD 网关 token（也可以通过 JD_GATEWAY_TOKEN 环境变量提供）
  --output-dir <dir>    指定配置根目录（默认自动识别 /agent 或 \$HOME）
  --standalone          生成独立文件到 output-dir 下（不覆盖 ~/.claude ~/.codex）
  --merge               追加 JD 配置（默认）：写入 .codex/jd.config.toml，并为 Claude
                        生成 claude-jd 启动器；Codex 主配置只注册 JD provider
  --claude-only         只生成 Claude Code 配置
  --codex-only          只生成 Codex 配置
  --no-probe            跳过模型探测，直接使用全部候选模型
  --inline-token        Codex 配置使用 http_headers 内联 token（默认 env_key 引用环境变量，更安全）
  --no-save-token       不把 token 追加到 /agent/env.sh 或用户 shell 配置
  --dry-run             探测模型并显示写入计划，不实际写文件或打印 token
  -h, --help            显示本帮助

环境变量:
  AI_SETUP_AGENT_DIR    安装根目录（默认 /agent；与主安装脚本一致）

生成的文件:
  默认/--merge: 追加 JD 环境变量和 claude-jd 启动器 + 写入 \${output_dir}/.codex/jd.config.toml
  --standalone: \${output_dir}/claude-settings.json + \${output_dir}/codex-config.toml

默认追加模式不会修改 Claude settings.json 或 Codex 的默认模型；之后使用:
  claude-jd
  codex --profile jd
USAGE
}

parse_args() {
  while (($#)); do
    case "$1" in
      --token)
        [[ -n "${2:-}" ]] || die "--token 需要一个参数"
        TOKEN="$2"
        shift 2
        ;;
      --output-dir)
        [[ -n "${2:-}" ]] || die "--output-dir 需要一个参数"
        OUTPUT_DIR="$2"
        OUTPUT_DIR_SET=1
        shift 2
        ;;
      --standalone)
        [[ -z "${OUTPUT_MODE_EXPLICIT}" || "${OUTPUT_MODE_EXPLICIT}" == standalone ]] ||
          die "--standalone 和 --merge 不能同时使用"
        STANDALONE=1
        MERGE=0
        OUTPUT_MODE_EXPLICIT=standalone
        shift
        ;;
      --merge)
        [[ -z "${OUTPUT_MODE_EXPLICIT}" || "${OUTPUT_MODE_EXPLICIT}" == merge ]] ||
          die "--standalone 和 --merge 不能同时使用"
        STANDALONE=0
        MERGE=1
        OUTPUT_MODE_EXPLICIT=merge
        shift
        ;;
      --claude-only)
        CLAUDE_ONLY=1
        shift
        ;;
      --codex-only)
        CODEX_ONLY=1
        shift
        ;;
      --no-probe)
        NO_PROBE=1
        shift
        ;;
      --inline-token)
        INLINE_TOKEN=1
        shift
        ;;
      --no-save-token)
        NO_SAVE_TOKEN=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        usage >&2
        die "未知选项: $1"
        ;;
    esac
  done
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少依赖命令: $1"
}

match_owner() {
  local path=$1
  local reference=$2
  ((EUID == 0)) || return 0
  [[ -e "${reference}" ]] || return 0
  chown --reference="${reference}" -- "${path}"
}

toml_string() {
  local value=$1
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\b'/\\b}
  value=${value//$'\f'/\\f}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '"%s"' "${value}"
}

read_managed_jd_token() {
  local file=$1 block
  [[ -r "${file}" ]] || return 1
  block=$(awk '
    $0 == "# BEGIN JD gateway token" { capture=1; next }
    $0 == "# END JD gateway token" { capture=0; exit }
    capture { print }
  ' "${file}")
  [[ -n "${block}" ]] || return 1
  /usr/bin/env -u JD_GATEWAY_TOKEN /usr/bin/bash --noprofile --norc -c \
    'eval "$1"; printf "%s" "${JD_GATEWAY_TOKEN:-}"' bash "${block}"
}

prompt_token() {
  if [[ -n "${TOKEN}" ]]; then
    return 0
  fi

  local current=${JD_GATEWAY_TOKEN:-}
  local saved_env target_codex_dir
  target_codex_dir=$(dirname "$(codex_config_path)")
  # An explicitly exported value updates the saved token. Only fall back to the
  # managed block when the current process does not provide one.
  if [[ -z "${current}" ]] && (( ! STANDALONE && ! OUTPUT_DIR_SET )); then
    if [[ "${target_codex_dir}" == "${AGENT_DIR}/config/codex" ]]; then
      saved_env=${AGENT_DIR}/env.sh
      if current=$(read_managed_jd_token "${saved_env}") && [[ -n "${current}" ]]; then
        :
      else
        current=''
      fi
    else
      for saved_env in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
        if current=$(read_managed_jd_token "${saved_env}") && [[ -n "${current}" ]]; then
          break
        fi
        current=''
      done
    fi
  fi
  local legacy_env
  legacy_env="$(dirname "$(codex_config_path)")/jd.env"
  if [[ -z "${current}" && -r "${legacy_env}" ]] && (( ! STANDALONE )); then
    # 兼容旧版安装；成功后会迁移到 /agent/env.sh 并删除这个文件。
    source "${legacy_env}"
    current=${JD_GATEWAY_TOKEN:-}
  fi

  if [[ ! -t 0 && -n "${current}" ]]; then
    TOKEN=${current}
    log "使用环境变量或已保存的 JD_GATEWAY_TOKEN"
    return 0
  fi

  local entered=''
  local prompt='请输入 JD 网关 token (输入内容隐藏)'
  [[ -z "${current}" ]] || prompt+='，直接回车保留现有值'
  read -r -s -p "${prompt}: " entered
  printf '\n'
  if [[ -n "${entered}" ]]; then
    TOKEN=${entered}
  elif [[ -n "${current}" ]]; then
    TOKEN=${current}
  else
    die 'token 不能为空'
  fi
}

claude_settings_path() {
  printf '%s/claude-settings.json' "${OUTPUT_DIR}"
}

codex_config_path() {
  if ((STANDALONE)); then
    printf '%s/codex-config.toml' "${OUTPUT_DIR}"
  elif ((MERGE)); then
    if ((OUTPUT_DIR_SET)); then
      printf '%s/.codex/jd.config.toml' "${OUTPUT_DIR}"
    elif [[ -n "${CODEX_HOME:-}" ]]; then
      printf '%s/jd.config.toml' "${CODEX_HOME%/}"
    elif [[ -f "${AGENT_DIR}/env.sh" && -d "${AGENT_DIR}/config/codex" ]]; then
      printf '%s/config/codex/jd.config.toml' "${AGENT_DIR}"
    else
      printf '%s/.codex/jd.config.toml' "${OUTPUT_DIR}"
    fi
  elif [[ -n "${CODEX_HOME:-}" ]]; then
    printf '%s/config.toml' "${CODEX_HOME%/}"
  else
    printf '%s/.codex/config.toml' "${OUTPUT_DIR}"
  fi
}

codex_main_config_path() {
  if [[ -n "${CODEX_HOME:-}" ]]; then
    printf '%s/config.toml' "${CODEX_HOME%/}"
  elif [[ -f "${AGENT_DIR}/env.sh" && -d "${AGENT_DIR}/config/codex" ]]; then
    printf '%s/config/codex/config.toml' "${AGENT_DIR}"
  else
    printf '%s/.codex/config.toml' "${OUTPUT_DIR}"
  fi
}

probe_claude_models() {
  local verified=()
  local model status payload
  log "探测 Claude 端点 ${CLAUDE_BASE_URL} ..."
  for model in "${CLAUDE_MODEL_CANDIDATES[@]}"; do
    payload=$(jq -cn --arg m "${model}" \
      '{model:$m,max_tokens:16,messages:[{role:"user",content:"Reply OK."}]}')
    status=$(curl --silent --show-error --max-time 30 --output /dev/null \
      --write-out '%{http_code}' \
      -H "Authorization: Bearer ${TOKEN}" \
      -H 'anthropic-version: 2023-06-01' \
      -H 'content-type: application/json' \
      --data-binary "${payload}" "${CLAUDE_BASE_URL%/}/v1/messages" 2>/dev/null || true)
    if [[ "${status}" =~ ^2 ]]; then
      verified+=("${model}")
      log "  ✓ ${model}"
    else
      warn "  ✗ ${model} (HTTP ${status:-请求失败})"
    fi
  done
  if (( ${#verified[@]} == 0 )); then
    warn 'Claude 端点探测全部失败；未修改配置。确认 token 和网络后重试，或明确使用 --no-probe。'
    return 1
  else
    printf '%s\n' "${verified[@]}"
  fi
}

probe_codex_models() {
  local verified=()
  local model status payload
  log "探测 Codex 端点 ${CODEX_BASE_URL} ..."
  for model in "${CODEX_MODEL_CANDIDATES[@]}"; do
    payload=$(jq -cn --arg m "${model}" \
      '{model:$m,input:"Reply OK.",max_output_tokens:16,stream:false}')
    status=$(curl --silent --show-error --max-time 30 --output /dev/null \
      --write-out '%{http_code}' \
      -H "Authorization: Bearer ${TOKEN}" \
      -H 'content-type: application/json' \
      --data-binary "${payload}" "${CODEX_BASE_URL%/}/responses" 2>/dev/null || true)
    if [[ "${status}" =~ ^2 ]]; then
      verified+=("${model}")
      log "  ✓ ${model}"
    else
      warn "  ✗ ${model} (HTTP ${status:-请求失败})"
    fi
  done
  if (( ${#verified[@]} == 0 )); then
    warn 'Codex 端点探测全部失败；未修改配置。确认 token 和网络后重试，或明确使用 --no-probe。'
    return 1
  else
    printf '%s\n' "${verified[@]}"
  fi
}

build_claude_settings() {
  local -a models=("$@")
  local opus='' sonnet='' model
  for model in "${models[@]}"; do
    case "${model}" in
      *opus*)   [[ -z "${opus}"   ]] && opus="${model}" ;;
      *sonnet*) [[ -z "${sonnet}" ]] && sonnet="${model}" ;;
    esac
  done
  # 某一模型族全部探测失败时，用首个已验证模型兜底，避免写入空的默认模型。
  [[ -n "${opus}" ]] || opus=${models[0]}
  [[ -n "${sonnet}" ]] || sonnet=${models[0]}
  # fallbackModel 只包含已验证且不同于主 Opus 模型的候选。
  local fallback
  fallback=$(printf '%s\n' "${models[@]}" |
    jq -R --arg primary "${opus}" 'select(. != $primary)' | jq -s '.[0:3]')
  jq -n \
    --arg base_url "${CLAUDE_BASE_URL}" \
    --arg token "${TOKEN}" \
    --arg opus_model "${opus}" \
    --arg sonnet_model "${sonnet}" \
    --argjson fallback "${fallback}" \
    '{
      "$schema": "https://json.schemastore.org/claude-code-settings.json",
      "env": {
        "ANTHROPIC_AUTH_TOKEN": $token,
        "ANTHROPIC_BASE_URL": $base_url,
        "ANTHROPIC_DEFAULT_OPUS_MODEL": $opus_model,
        "ANTHROPIC_DEFAULT_SONNET_MODEL": $sonnet_model,
        "ANTHROPIC_DEFAULT_HAIKU_MODEL": $sonnet_model,
        "CLAUDE_CODE_EXTRA_BODY": "{\"thinking\":{\"type\":\"adaptive\",\"display\":\"summarized\"}}",
        "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY": "1",
        "CLAUDE_CODE_EFFORT_LEVEL": "xhigh",
        "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "128000",
        "CLAUDE_CODE_RETRY_WATCHDOG": "1",
        "CLAUDE_CODE_ENABLE_FINE_GRAINED_TOOL_STREAMING": "1",
        "DISABLE_ERROR_REPORTING": "1",
        "BASH_DEFAULT_TIMEOUT_MS": "600000",
        "BASH_MAX_TIMEOUT_MS": "1800000"
      },
      "model": "opus",
      "fallbackModel": $fallback,
      "modelOverrides": {
        "claude-opus-4-8": "Claude-Opus-4.8-joybuilder",
        "claude-opus-4-7": "Claude-Opus-4.7-joybuilder",
        "claude-sonnet-5": "Claude-Sonnet-5-joybuilder"
      },
      "permissions": { "deny": [], "defaultMode": "bypassPermissions" },
      "outputStyle": "Concise",
      "language": "Chinese",
      "promptCacheTtl": "1h",
      "skipWebFetchPreflight": true
    }'
}

build_claude_runtime_settings() {
  # 启动器通过 --settings 传入非敏感 JSON；token 只从 /agent/env.sh 进入进程环境。
  build_claude_settings "$@" | jq -c 'del(.env.ANTHROPIC_AUTH_TOKEN) | {
    "$schema": .["$schema"],
    env,
    model,
    fallbackModel,
    modelOverrides,
    permissions: {defaultMode: .permissions.defaultMode}
  }'
}

select_codex_model() {
  local -a models=("$@")
  local current='' candidate profile_path
  if ((MERGE)); then
    profile_path=$(codex_config_path)
    if [[ -f "${profile_path}" ]]; then
      current=$(sed -nE 's/^model[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' \
        "${profile_path}" | head -n 1)
    fi
  fi
  if [[ -n "${current}" ]]; then
    for candidate in "${models[@]}"; do
      if [[ "${candidate}" == "${current}" ]]; then
        printf '%s\n' "${current}"
        return 0
      fi
    done
  fi
  printf '%s\n' "${models[0]}"
}

build_codex_config() {
  local -a models=("$@")
  local model model_toml base_url_toml subagent_model subagent_model_toml candidate
  model=$(select_codex_model "${models[@]}")
  subagent_model=${model}
  for candidate in "${models[@]}"; do
    if [[ "${candidate}" == "${CODEX_SUBAGENT_MODEL}" ]]; then
      subagent_model=${candidate}
      break
    fi
  done
  model_toml=$(toml_string "${model}")
  base_url_toml=$(toml_string "${CODEX_BASE_URL}")
  subagent_model_toml=$(toml_string "${subagent_model}")
  local toml_models=''
  local first=1 quoted_model
  for m in "${models[@]}"; do
    quoted_model=$(toml_string "${m}")
    if ((first)); then
      toml_models="[${quoted_model}"
      first=0
    else
      toml_models+=", ${quoted_model}"
    fi
  done
  toml_models+=']'
  local auth_line
  if ((INLINE_TOKEN)); then
    auth_line="http_headers = { Authorization = $(toml_string "Bearer ${TOKEN}") }"
  else
    auth_line='env_key = "JD_GATEWAY_TOKEN"'
  fi
  local catalog_line=''
  if [[ -n "${CODEX_CATALOG_FILE}" ]]; then
    catalog_line="model_catalog_json = $(toml_string "${CODEX_CATALOG_FILE}")"
  fi

  cat <<TOML_EOF
#:schema https://learn.chatgpt.com/docs/config-schema.json

model_provider = "jd"
model = ${model_toml}
${catalog_line}
model_reasoning_effort = "xhigh"
plan_mode_reasoning_effort = "max"
model_reasoning_summary = "detailed"
model_verbosity = "high"
web_search = "live"

approval_policy = "never"
sandbox_mode = "danger-full-access"

[model_providers.jd]
name = "JD LLM Gateway"
base_url = ${base_url_toml}
${auth_line}
wire_api = "responses"
models = ${toml_models}

[tui]
status_line = ["model-with-reasoning", "current-dir", "git-branch", "context-used"]
terminal_title = ["project", "git-branch"]

[history]
max_bytes = 104857600

[features]
apps = false
memories = true
prevent_idle_sleep = true
multi_agent_v2 = { enabled = true, expose_spawn_agent_model_overrides = true }

[agents]
max_concurrent_threads_per_session = 6
default_subagent_model = ${subagent_model_toml}
default_subagent_reasoning_effort = "max"

[tools.update_plan]
enabled = true

[tools.web_search]
context_size = "high"

[shell_environment_policy]
inherit = "core"
exclude = [
  "*TOKEN*",
  "*KEY*",
  "*SECRET*",
  "*PASSWORD*",
  "*COOKIE*",
]
TOML_EOF
}

build_jd_provider_registration() {
  local -a models=("$@")
  local models_toml='' quoted_model base_url_toml
  local first=1 model
  for model in "${models[@]}"; do
    quoted_model=$(toml_string "${model}")
    if ((first)); then
      models_toml="[${quoted_model}"
      first=0
    else
      models_toml+=", ${quoted_model}"
    fi
  done
  models_toml+=']'
  base_url_toml=$(toml_string "${CODEX_BASE_URL}")
  cat <<TOML_EOF
[model_providers.jd]
name = "JD LLM Gateway"
base_url = ${base_url_toml}
env_key = "JD_GATEWAY_TOKEN"
wire_api = "responses"
models = ${models_toml}
TOML_EOF
}

generate_codex_catalog() {
  local -a models=("$@")
  local codex_bin
  codex_bin=$(command -v codex || true)
  [[ -n "${codex_bin}" ]] || die '生成 JD 模型 catalog 需要 codex 命令'

  local dir
  if ((STANDALONE)); then
    dir="${OUTPUT_DIR}"
  else
    dir=$(dirname "$(codex_config_path)")
  fi
  CODEX_CATALOG_FILE="${dir}/catalogs/jd.json"
  if ((DRY_RUN)); then
    log "[dry-run] 将生成 JD 模型 catalog ${CODEX_CATALOG_FILE}"
    return 0
  fi
  mkdir -p "${dir}/catalogs"

  TEMP_DIR=$(mktemp -d "${dir}/.jd-catalog.XXXXXXXX")
  mkdir -p "${TEMP_DIR}/home"
  local base_catalog="${TEMP_DIR}/base.json"
  if ! CODEX_HOME="${TEMP_DIR}/home" "${codex_bin}" debug models --bundled >"${base_catalog}"; then
    die 'Codex 无法导出内置模型 metadata；原 JD catalog 未修改'
  fi
  jq -e '.models | type == "array" and length > 0' "${base_catalog}" >/dev/null 2>&1 ||
    die 'Codex 返回的内置模型 metadata 无效；原 JD catalog 未修改'

  local model_array catalog_tmp owner_reference
  model_array=$(printf '%s\n' "${models[@]}" | jq -R . | jq -s .)
  catalog_tmp="${TEMP_DIR}/jd.json"
  if ! jq --argjson models "${model_array}" '{models: [
        . as $base
        | $base.models[0] as $template
        | $models[]
        | $template * {
            slug: .,
            display_name: .,
            description: ("JD LLM Gateway model " + .),
            default_reasoning_level: "xhigh",
            supported_reasoning_levels: [
              {effort:"xhigh", description:"Extra high reasoning"},
              {effort:"max", description:"Maximum reasoning"}
            ],
            visibility: "list",
            supported_in_api: true,
            priority: 100,
            availability_nux: {message:"This model is served through JD LLM Gateway."},
            context_window: 256000,
            max_context_window: 256000,
            effective_context_window_percent: 95
          }
      ]}' "${base_catalog}" >"${catalog_tmp}"; then
    die '无法生成 JD 模型 catalog；原文件未修改'
  fi
  chmod 600 "${catalog_tmp}"
  owner_reference="${dir}/catalogs"
  [[ ! -e "${CODEX_CATALOG_FILE}" ]] || owner_reference=${CODEX_CATALOG_FILE}
  match_owner "${catalog_tmp}" "${owner_reference}"
  mv -f -- "${catalog_tmp}" "${CODEX_CATALOG_FILE}"
  rm -rf -- "${TEMP_DIR}"
  TEMP_DIR=''
  log "已生成 JD 模型 catalog ${CODEX_CATALOG_FILE}"
}

write_claude_jd_launcher() {
  local runtime_settings=$1
  local launcher claude_bin env_file content
  if ((OUTPUT_DIR_SET)); then
    launcher="${OUTPUT_DIR}/claude-jd"
    claude_bin=$(command -v claude || true)
    [[ -n "${claude_bin}" ]] || die '生成 claude-jd 启动器需要 claude 命令'
    env_file=''
  elif [[ -d "${AGENT_DIR}/bin" && -f "${AGENT_DIR}/env.sh" &&
          ( -z "${CLAUDE_CONFIG_DIR:-}" || "${CLAUDE_CONFIG_DIR%/}" == "${AGENT_DIR}/config/claude" ) ]]; then
    launcher="${AGENT_DIR}/bin/claude-jd"
    claude_bin="${AGENT_DIR}/bin/claude"
    env_file="${AGENT_DIR}/env.sh"
  else
    launcher="${HOME}/.local/bin/claude-jd"
    claude_bin=$(command -v claude || true)
    [[ -n "${claude_bin}" ]] || die '生成 claude-jd 启动器需要 claude 命令'
    env_file=''
  fi
  printf -v content \
    '#!/usr/bin/env bash\nset -Eeuo pipefail\n%s\n: "${JD_GATEWAY_TOKEN:?JD_GATEWAY_TOKEN 未配置，请重新运行 set_jd_gateway_config.sh}"\nexport ANTHROPIC_AUTH_TOKEN="${JD_GATEWAY_TOKEN}"\nexec %q --settings %q --permission-mode bypassPermissions "$@"' \
    "$(if [[ -n "${env_file}" ]]; then printf '[[ ! -r %q ]] || source %q' "${env_file}" "${env_file}"; else printf ':'; fi)" \
    "${claude_bin}" "${runtime_settings}"
  write_file "${launcher}" "${content}" 755
  if [[ "${launcher}" == "${AGENT_DIR}/bin/claude-jd" ]]; then
    log 'JD Claude 启动命令: claude-jd'
  else
    log "JD Claude 启动命令: ${launcher}"
  fi
}

upsert_jd_environment_block() {
  local target=$1
  local dir tmp kept final target_mode
  dir=$(dirname "${target}")
  tmp=$(mktemp "${dir}/.jd-source.XXXXXXXX")
  final="${tmp}.final"

  awk '
    $0 == "# BEGIN JD gateway token" { skip=1; next }
    $0 == "# END JD gateway token" { skip=0; next }
    !skip { print }
  ' "${target}" >"${tmp}" 2>/dev/null || : >"${tmp}"

  {
    cat "${tmp}"
    printf '\n# BEGIN JD gateway token\n'
    printf 'export JD_GATEWAY_TOKEN=%q\n' "${TOKEN}"
    printf '# END JD gateway token\n'
  } >"${final}"

  target_mode=$(stat -c '%a' "${target}" 2>/dev/null || printf '600')
  chmod "${target_mode}" "${final}"
  match_owner "${final}" "${target}"
  mv -f "${final}" "${target}"
  rm -f -- "${tmp}"
}

remove_jd_environment_block() {
  local target=$1
  [[ -f "${target}" ]] || return 0
  local dir tmp target_mode
  dir=$(dirname "${target}")
  tmp=$(mktemp "${dir}/.jd-remove.XXXXXXXX")
  awk '
    $0 == "# BEGIN JD gateway token" { skip=1; next }
    $0 == "# END JD gateway token" { skip=0; next }
    !skip { print }
  ' "${target}" >"${tmp}"
  target_mode=$(stat -c '%a' "${target}")
  chmod "${target_mode}" "${tmp}"
  match_owner "${tmp}" "${target}"
  mv -f -- "${tmp}" "${target}"
}

register_jd_codex_provider() {
  local main_config dir tmp final target_mode provider_block
  main_config=$(codex_main_config_path)
  provider_block=$(build_jd_provider_registration "$@")

  if ((DRY_RUN)); then
    log "[dry-run] 将在 ${main_config} 注册 JD provider；不改变默认 provider 或 model"
    return 0
  fi

  dir=$(dirname "${main_config}")
  mkdir -p "${dir}"
  tmp=$(mktemp "${dir}/.jd-provider.XXXXXXXX")
  final="${tmp}.final"
  if [[ -f "${main_config}" ]]; then
    awk '
      $0 == "# BEGIN JD gateway provider" { skip=1; next }
      $0 == "# END JD gateway provider" { skip=0; next }
      !skip { print }
    ' "${main_config}" >"${tmp}"
  else
    : >"${tmp}"
  fi

  # Respect an existing manually managed provider and avoid producing an
  # invalid duplicate TOML table. Managed blocks are refreshed on every run.
  if grep -Eq '^[[:space:]]*\[model_providers\.jd\][[:space:]]*$' "${tmp}"; then
    rm -f -- "${tmp}"
    log "${main_config} 已包含手动维护的 JD provider；保留现有定义"
    return 0
  fi

  {
    cat "${tmp}"
    printf '\n# BEGIN JD gateway provider\n%s\n# END JD gateway provider\n' "${provider_block}"
  } >"${final}"
  target_mode=$(stat -c '%a' "${main_config}" 2>/dev/null || printf '600')
  chmod "${target_mode}" "${final}"
  match_owner "${final}" "${main_config}"
  mv -f -- "${final}" "${main_config}"
  rm -f -- "${tmp}"
  log "已在 ${main_config} 注册 JD provider；默认 provider 和 model 保持不变"
}

save_jd_environment() {
  local codex_dir legacy_env rc_file current_shell_source startup_updated=0
  codex_dir=$(dirname "$(codex_config_path)")
  legacy_env="${codex_dir}/jd.env"

  if ((DRY_RUN)); then
    log "[dry-run] 将把 JD_GATEWAY_TOKEN 追加到 ${AGENT_DIR}/env.sh 或用户 shell 配置"
    return 0
  fi

  # 安装器环境直接把 token 放进 /agent/env.sh；变量名不会改变现有 Claude/CCR 路由。
  if (( ! OUTPUT_DIR_SET )) && [[ "${codex_dir}" == "${AGENT_DIR}/config/codex" && -f "${AGENT_DIR}/env.sh" ]]; then
    upsert_jd_environment_block "${AGENT_DIR}/env.sh"
    chmod 600 "${AGENT_DIR}/env.sh"
    current_shell_source=${AGENT_DIR}/env.sh
    remove_jd_environment_block "${codex_dir}/gateways.env"
    [[ ! -f "${legacy_env}" ]] || rm -f -- "${legacy_env}"
    log "已把 JD_GATEWAY_TOKEN 追加到 ${AGENT_DIR}/env.sh (mode 600)"
  elif (( ! OUTPUT_DIR_SET )); then
    for rc_file in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
      [[ -f "${rc_file}" ]] || continue
      upsert_jd_environment_block "${rc_file}"
      startup_updated=1
    done
    if (( ! startup_updated )); then
      upsert_jd_environment_block "${HOME}/.bashrc"
    fi
    current_shell_source=${HOME}/.bashrc
    [[ ! -f "${legacy_env}" ]] || rm -f -- "${legacy_env}"
    log '新 Bash/Zsh 会话会自动加载 JD token'
  else
    log '指定输出目录时不会修改环境文件；使用前请手动 export JD_GATEWAY_TOKEN'
    return 0
  fi

  log "当前已打开的 shell 需要执行一次: source ${current_shell_source}"
}

write_file() {
  local path=$1
  local content=$2
  local mode=${3:-600}
  local dir
  dir=$(dirname "${path}")
  if ((DRY_RUN)); then
    log "[dry-run] 将写入 ${path} (mode ${mode})"
    return 0
  fi
  mkdir -p "${dir}"
  local tmp
  tmp=$(mktemp "${dir}/.jd-setup-tmp.XXXXXXXX")
  printf '%s\n' "${content}" >"${tmp}"
  chmod "${mode}" "${tmp}"
  if [[ -e "${path}" ]]; then
    match_owner "${tmp}" "${path}"
  else
    match_owner "${tmp}" "${dir}"
  fi
  mv -f "${tmp}" "${path}"
  log "已生成 ${path} (mode ${mode})"
}

main() {
  parse_args "$@"
  (( CLAUDE_ONLY + CODEX_ONLY < 2 )) || die "--claude-only 和 --codex-only 不能同时使用"
  (( STANDALONE + MERGE == 1 )) || die "内部错误：无效的输出模式"
  require_command jq
  ((NO_PROBE)) || require_command curl
  ((CLAUDE_ONLY)) || require_command codex
  prompt_token

  local -a claude_models codex_models
  local probe_output
  if (( ! NO_PROBE )); then
    if (( ! CODEX_ONLY )); then
      probe_output=$(probe_claude_models) ||
        die '没有探测到可用的 JD Claude 模型；配置保持不变'
      mapfile -t claude_models <<<"${probe_output}"
    fi
    if (( ! CLAUDE_ONLY )); then
      probe_output=$(probe_codex_models) ||
        die '没有探测到可用的 JD Codex 模型；配置保持不变'
      mapfile -t codex_models <<<"${probe_output}"
    fi
  else
    log '跳过模型探测（--no-probe），使用全部候选模型'
    claude_models=("${CLAUDE_MODEL_CANDIDATES[@]}")
    codex_models=("${CODEX_MODEL_CANDIDATES[@]}")
  fi

  if (( ! CODEX_ONLY )); then
    local claude_content
    if ((MERGE)); then
      claude_content=$(build_claude_runtime_settings "${claude_models[@]}")
      write_claude_jd_launcher "${claude_content}"
    else
      local claude_path
      claude_path=$(claude_settings_path)
      claude_content=$(build_claude_settings "${claude_models[@]}")
      write_file "${claude_path}" "${claude_content}" 600
    fi
  fi

  if (( ! CLAUDE_ONLY )); then
    generate_codex_catalog "${codex_models[@]}"
    local codex_path
    codex_path=$(codex_config_path)
    local codex_content
    codex_content=$(build_codex_config "${codex_models[@]}")
    write_file "${codex_path}" "${codex_content}" 600

    if ((MERGE)); then
      if (( ! OUTPUT_DIR_SET )); then
        register_jd_codex_provider "${codex_models[@]}"
      fi
      log 'Codex 主配置仅注册 JD provider；默认 provider 和 model 未修改'
    elif (( ! STANDALONE )); then
      log 'JD 已写入 Codex 主配置；启动命令: codex'
    fi

    if (( ! INLINE_TOKEN && (NO_SAVE_TOKEN || STANDALONE || OUTPUT_DIR_SET) )); then
      cat <<HINT

[jd-setup] Codex 使用 env_key 模式，请确保运行 codex 前设置环境变量:
[jd-setup]   export JD_GATEWAY_TOKEN='你的token'
[jd-setup] 可将以上行加入 ~/.bashrc 或 ~/.zshrc 持久化。
HINT
    fi

    if ((MERGE)); then
      log '加载 JD 网关: codex --profile jd'
    fi
  fi

  if ((MERGE && !NO_SAVE_TOKEN)) && (( !INLINE_TOKEN || !CODEX_ONLY )); then
    save_jd_environment
  fi

  log '完成。'
}
trap cleanup EXIT
main "$@"
