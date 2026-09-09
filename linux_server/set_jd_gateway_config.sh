#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# set_jd_gateway_config.sh
# 独立生成京东（JD LLM Gateway）网关的 Claude Code 和 Codex 配置文件
#
# 用法:
#   ./set_jd_gateway_config.sh                  交互式（隐藏输入 token）
#   ./set_jd_gateway_config.sh --token xxx      非交互式
#   JD_GATEWAY_TOKEN=xxx ./set_jd_gateway_config.sh
#
# 选项:
#   --token <token>       直接指定 JD 网关 token
#   --output-dir <dir>    输出目录（默认 $HOME，生成 ~/.claude/settings.json 和 ~/.codex/config.toml）
#   --standalone          生成独立文件（不写入 ~/.claude ~/.codex，而是输出到 output-dir 下的
#                         claude-settings.json 和 codex-config.toml，方便手动复制）
#   --merge               一键追加到已有配置：Codex 生成 jd.config.toml，Claude 合并 settings.json 并自动备份
#   --claude-only         只生成 Claude Code 配置
#   --codex-only          只生成 Codex 配置
#   --no-probe            跳过模型探测，直接使用全部候选模型
#   --inline-token        Codex 配置使用 http_headers 内联 token（默认使用 env_key 环境变量引用，更安全）
#   --dry-run             只打印将要写入的内容，不实际写文件
#   -h, --help            显示帮助
# ============================================================

SCRIPT_NAME=${0##*/}
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
MERGE=0
CLAUDE_ONLY=0
CODEX_ONLY=0
NO_PROBE=0
INLINE_TOKEN=0
DRY_RUN=0
CODEX_CATALOG_FILE=''
OUTPUT_DIR_SET=0

log() { printf '[jd-setup] %s\n' "$*" >&2; }
warn() { printf '[jd-setup] WARNING: %s\n' "$*" >&2; }
die() { printf '[jd-setup] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<USAGE
用法: ${SCRIPT_NAME} [选项]

独立生成京东（JD LLM Gateway）网关的 Claude Code 和 Codex 配置文件。

选项:
  --token <token>       直接指定 JD 网关 token（也可以通过 JD_GATEWAY_TOKEN 环境变量提供）
  --output-dir <dir>    输出目录（默认 \$HOME）
  --standalone          生成独立文件到 output-dir 下（不覆盖 ~/.claude ~/.codex）
  --merge               追加到已有配置：Codex 写入 .codex/jd.config.toml；Claude 合并到
                        .claude/settings.json，并自动创建 .bak.<时间戳> 备份
  --claude-only         只生成 Claude Code 配置
  --codex-only          只生成 Codex 配置
  --no-probe            跳过模型探测，直接使用全部候选模型
  --inline-token        Codex 配置使用 http_headers 内联 token（默认 env_key 引用环境变量，更安全）
  --dry-run             只打印将要写入的内容，不实际写文件
  -h, --help            显示本帮助

生成的文件:
  默认模式:     \${output_dir}/.claude/settings.json + \${output_dir}/.codex/config.toml
  --merge:      合并 \${output_dir}/.claude/settings.json + 写入 \${output_dir}/.codex/jd.config.toml
  --standalone: \${output_dir}/claude-settings.json + \${output_dir}/codex-config.toml

Codex 追加模式不会修改现有 config.toml；之后使用:
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
        STANDALONE=1
        shift
        ;;
      --merge)
        MERGE=1
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

prompt_token() {
  if [[ -n "${TOKEN}" ]]; then
    return 0
  fi
  if [[ -n "${JD_GATEWAY_TOKEN:-}" ]]; then
    TOKEN="${JD_GATEWAY_TOKEN}"
    log "使用环境变量 JD_GATEWAY_TOKEN 提供的 token"
    return 0
  fi
  local entered=''
  read -r -s -p '请输入 JD 网关 token (输入内容隐藏): ' entered
  printf '\n'
  [[ -n "${entered}" ]] || die 'token 不能为空'
  TOKEN="${entered}"
}

claude_settings_path() {
  if ((STANDALONE)); then
    printf '%s/claude-settings.json' "${OUTPUT_DIR}"
  elif [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
    printf '%s/settings.json' "${CLAUDE_CONFIG_DIR%/}"
  else
    printf '%s/.claude/settings.json' "${OUTPUT_DIR}"
  fi
}

codex_config_path() {
  if ((STANDALONE)); then
    printf '%s/codex-config.toml' "${OUTPUT_DIR}"
  elif [[ -n "${CODEX_HOME:-}" ]]; then
    if ((MERGE)); then
      # Codex 支持独立 profile 文件；不碰已有 config.toml。
      printf '%s/jd.config.toml' "${CODEX_HOME%/}"
    else
      printf '%s/config.toml' "${CODEX_HOME%/}"
    fi
  elif ((MERGE)); then
    printf '%s/.codex/jd.config.toml' "${OUTPUT_DIR}"
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
    warn 'Claude 端点探测全部失败，将使用全部候选模型生成配置（请确认网络可达后重新运行验证）'
    printf '%s\n' "${CLAUDE_MODEL_CANDIDATES[@]}"
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
    warn 'Codex 端点探测全部失败，将使用全部候选模型生成配置（请确认网络可达后重新运行验证）'
    printf '%s\n' "${CODEX_MODEL_CANDIDATES[@]}"
  else
    printf '%s\n' "${verified[@]}"
  fi
}

build_claude_settings() {
  local -a models=("$@")
  local opus='' sonnet='' haiku=''
  for model in "${models[@]}"; do
    case "${model}" in
      *opus*)   [[ -z "${opus}"   ]] && opus="${model}" ;;
      *sonnet*) [[ -z "${sonnet}" ]] && sonnet="${model}" ;;
    esac
  done
  # fallbackModel 只放 sonnet 之后的候选
  local fallback='[]'
  if [[ -n "${sonnet}" ]]; then
    fallback=$(printf '%s\n' "${models[@]}" | grep -v '^claude-opus-4-8' | jq -R . | jq -s .)
  fi
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
      "permissions": { "deny": [], "defaultMode": "acceptEdits" },
      "outputStyle": "Concise",
      "language": "Chinese",
      "promptCacheTtl": "1h",
      "skipWebFetchPreflight": true
    }'
}

build_codex_config() {
  local -a models=("$@")
  local model
  model="${models[0]}"
  local toml_models=''
  local first=1
  for m in "${models[@]}"; do
    if ((first)); then
      toml_models="[\"${m}\""
      first=0
    else
      toml_models+=", \"${m}\""
    fi
  done
  toml_models+=']'
  local auth_line
  if ((INLINE_TOKEN)); then
    auth_line="http_headers = { Authorization = \"Bearer ${TOKEN}\" }"
  else
    auth_line='env_key = "JD_GATEWAY_TOKEN"'
  fi
  local catalog_line=''
  if [[ -n "${CODEX_CATALOG_FILE}" ]]; then
    catalog_line="model_catalog_json = \"${CODEX_CATALOG_FILE}\""
  fi

  cat <<TOML_EOF
#:schema https://learn.chatgpt.com/docs/config-schema.json

model_provider = "jd"
model = "${model}"
${catalog_line}
model_reasoning_effort = "xhigh"
plan_mode_reasoning_effort = "max"
model_reasoning_summary = "detailed"
model_verbosity = "high"
web_search = "live"

approval_policy = "on-request"
sandbox_mode = "workspace-write"

[model_providers.jd]
name = "JD LLM Gateway"
base_url = "${CODEX_BASE_URL}"
${auth_line}

[tui]
theme = "github"
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
default_subagent_model = "${CODEX_SUBAGENT_MODEL}"
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

  local tmp
  tmp=$(mktemp -d "${dir}/.jd-catalog.XXXXXXXX")
  mkdir -p "${tmp}/home"
  local base_catalog
  base_catalog=$(mktemp "${tmp}/base.XXXXXXXX")
  CODEX_HOME="${tmp}/home" "${codex_bin}" debug models --bundled >"${base_catalog}"

  local model_array
  model_array=$(printf '%s\n' "${models[@]}" | jq -R . | jq -s .)
  jq     --argjson models "${model_array}"     '{models: [
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
      ]}' "${base_catalog}" >"${CODEX_CATALOG_FILE}"
  chmod 600 "${CODEX_CATALOG_FILE}"
  rm -rf -- "${tmp}"
  log "已生成 JD 模型 catalog ${CODEX_CATALOG_FILE}"
}

merge_claude_settings() {
  local path=$1
  local new_content=$2
  local dir backup
  dir=$(dirname "${path}")
  mkdir -p "${dir}"

  if [[ ! -f "${path}" ]]; then
    printf '%s\n' "${new_content}"
    return 0
  fi

  if ((DRY_RUN)); then
    log "[dry-run] 将合并到 ${path}（实际运行时会先备份）"
  else
    backup="${path}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -p "${path}" "${backup}"
    log "已备份 Claude 配置到 ${backup}"
  fi
  jq -S -s '.[0] * .[1]' "${path}" <(printf '%s\n' "${new_content}")
}

write_file() {
  local path=$1
  local content=$2
  local mode=${3:-600}
  local dir
  dir=$(dirname "${path}")
  if ((DRY_RUN)); then
    log "[dry-run] 将写入 ${path} (mode ${mode})"
    printf '%s\n' "${content}"
    return 0
  fi
  mkdir -p "${dir}"
  local tmp
  tmp=$(mktemp "${dir}/.jd-setup-tmp.XXXXXXXX")
  printf '%s\n' "${content}" >"${tmp}"
  chmod "${mode}" "${tmp}"
  mv -f "${tmp}" "${path}"
  log "已生成 ${path} (mode ${mode})"
}

main() {
  parse_args "$@"
  # 未显式指定 --output-dir 且本机存在安装器目录时，优先写入安装器管理的配置目录。
  if (( ! OUTPUT_DIR_SET )); then
    [[ -n "${CODEX_HOME:-}" || ! -d /agent/config/codex ]] || CODEX_HOME=/agent/config/codex
    [[ -n "${CLAUDE_CONFIG_DIR:-}" || ! -d /agent/config/claude ]] || CLAUDE_CONFIG_DIR=/agent/config/claude
  fi
  (( STANDALONE ^ MERGE )) || die "--standalone 和 --merge 只能选择一个；不使用它们时将覆盖主配置"
  require_command jq
  require_command curl
  prompt_token

  local -a claude_models codex_models
  if (( ! NO_PROBE )); then
    if (( ! CODEX_ONLY )); then
      mapfile -t claude_models < <(probe_claude_models)
    fi
    if (( ! CLAUDE_ONLY )); then
      mapfile -t codex_models < <(probe_codex_models)
    fi
  else
    log '跳过模型探测（--no-probe），使用全部候选模型'
    claude_models=("${CLAUDE_MODEL_CANDIDATES[@]}")
    codex_models=("${CODEX_MODEL_CANDIDATES[@]}")
  fi

  if (( ! CODEX_ONLY )); then
    local claude_path
    claude_path=$(claude_settings_path)
    local claude_content
    claude_content=$(build_claude_settings "${claude_models[@]}")

    if ((MERGE)); then
      local merged_content
      merged_content=$(merge_claude_settings "${claude_path}" "${claude_content}")
      write_file "${claude_path}" "${merged_content}" 600
    else
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
      log '现有 Codex config.toml 未修改；JD 网关请使用: codex --profile jd'
    elif (( ! STANDALONE )); then
      log 'JD 已写入 Codex 主配置；启动命令: codex'
    fi

    if (( ! INLINE_TOKEN )); then
      cat <<HINT

[jd-setup] Codex 使用 env_key 模式，请确保运行 codex 前设置环境变量:
[jd-setup]   export JD_GATEWAY_TOKEN='你的token'
[jd-setup] 可将以上行加入 ~/.bashrc 或 ~/.zshrc 持久化。
HINT
    fi
  fi

  log '完成。'
}
main "$@"
