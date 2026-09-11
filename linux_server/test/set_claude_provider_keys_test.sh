#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly TEST_SCRIPT_PATH="${TEST_DIR}/set_claude_provider_keys_test.sh"
readonly SCRIPT_PATH="$(cd -- "${TEST_DIR}/.." && pwd -P)/set_claude_provider_keys.sh"
readonly MANUAL_PATH="$(cd -- "${TEST_DIR}/.." && pwd -P)/README.md"
readonly REAL_CODEX_BIN="$(command -v codex || true)"
readonly REAL_CODEX_PATH="${PATH}"
REAL_NODE_BIN="$(command -v node || true)"
if [[ -z "${REAL_NODE_BIN}" && -x /agent/node/bin/node ]]; then
  REAL_NODE_BIN=/agent/node/bin/node
fi
readonly REAL_NODE_BIN

INSTALLED_TEST_COUNT=0
INSTALLED_TEMP_DIR=''

installed_pass() {
  INSTALLED_TEST_COUNT=$((INSTALLED_TEST_COUNT + 1))
  printf 'ok %d - %s\n' "${INSTALLED_TEST_COUNT}" "$1"
}

installed_fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

installed_require_command() {
  command -v "$1" >/dev/null 2>&1 || installed_fail "missing required command: $1"
}

installed_assert_file_mode() {
  local expected=$1
  local file=$2
  [[ -f "${file}" ]] || installed_fail "missing file: ${file}"
  [[ "$(stat -c '%a' "${file}")" == "${expected}" ]] ||
    installed_fail "unexpected permissions for ${file}"
}

installed_profile_env_key() {
  case "$1" in
    volcano) printf '%s\n' VOLCANO_AI_GATEWAY_API_KEY ;;
    bailian) printf '%s\n' BAILIAN_API_KEY ;;
    blackai-gpt) printf '%s\n' BLACKAICODING_GPT_API_KEY ;;
    blackai-claude) printf '%s\n' BLACKAICODING_CLAUDE_API_KEY ;;
    *) installed_fail "unknown Codex profile: $1" ;;
  esac
}

run_installed_codex_test() {
  local installed_agent_dir="${AI_SETUP_AGENT_DIR:-/agent}"
  local installed_env_file="${installed_agent_dir}/env.sh"
  local installed_codex_dir="${installed_agent_dir}/config/codex"
  local installed_codex_bin="${installed_agent_dir}/bin/codex"
  local configured_profiles=0
  local profile profile_file catalog_file env_key expected_models
  local rendered_catalog actual_models profile_stderr catalog_stderr
  local -a profiles=(volcano bailian blackai-gpt blackai-claude)

  INSTALLED_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/codex-install-test.XXXXXXXX")
  trap 'rm -rf -- "${INSTALLED_TEMP_DIR}"' EXIT
  [[ -f "${installed_env_file}" ]] ||
    installed_fail "missing ${installed_env_file}; run the installer first"
  # The generated environment file contains shell-escaped values and is mode 600.
  source "${installed_env_file}"
  hash -r

  installed_require_command jq
  [[ -x "${installed_codex_bin}" ]] ||
    installed_fail "missing Codex launcher: ${installed_codex_bin}"
  [[ "$(command -v codex)" == "${installed_codex_bin}" ]] ||
    installed_fail "the active Codex command is not ${installed_codex_bin}"
  [[ "${CODEX_HOME:-}" == "${installed_codex_dir}" ]] ||
    installed_fail "CODEX_HOME is not ${installed_codex_dir}"
  codex --version | grep -Eq '^codex-cli [0-9]+' ||
    installed_fail "Codex version check failed"
  installed_pass "container-local Codex launcher and environment"

  for profile in "${profiles[@]}"; do
    profile_file="${installed_codex_dir}/${profile}.config.toml"
    catalog_file="${installed_codex_dir}/catalogs/${profile}.json"
    if [[ ! -e "${profile_file}" && ! -e "${catalog_file}" ]]; then
      continue
    fi

    installed_assert_file_mode 600 "${profile_file}"
    installed_assert_file_mode 600 "${catalog_file}"
    env_key=$(installed_profile_env_key "${profile}")
    [[ -n "${!env_key:-}" ]] ||
      installed_fail "${env_key} is unset for profile ${profile}"
    grep -Fq "env_key = \"${env_key}\"" "${profile_file}" ||
      installed_fail "profile ${profile} references the wrong token variable"
    grep -Fq "model_catalog_json = \"${catalog_file}\"" "${profile_file}" ||
      installed_fail "profile ${profile} references the wrong model catalog"

    expected_models=$(jq -c '[.models[].slug] | unique | sort' "${catalog_file}") ||
      installed_fail "invalid model catalog for profile ${profile}"
    [[ "${expected_models}" != '[]' ]] ||
      installed_fail "empty model catalog for profile ${profile}"
    catalog_stderr="${INSTALLED_TEMP_DIR}/${profile}.models.stderr"
    if ! rendered_catalog=$(codex debug models \
        -c "model_catalog_json=\"${catalog_file}\"" 2>"${catalog_stderr}"); then
      sed -n '1,20p' "${catalog_stderr}" >&2
      installed_fail "Codex could not load the model catalog for profile ${profile}"
    fi
    actual_models=$(jq -c '[.models[].slug] | unique | sort' <<<"${rendered_catalog}") ||
      installed_fail "Codex returned invalid model metadata for profile ${profile}"
    [[ "${actual_models}" == "${expected_models}" ]] ||
      installed_fail "profile ${profile} did not load only its own model catalog"
    jq -e 'all(.models[]; (.context_window | type) == "number" and .context_window > 0)' \
      <<<"${rendered_catalog}" >/dev/null ||
      installed_fail "profile ${profile} contains invalid context-window metadata"

    profile_stderr=$(codex --profile "${profile}" debug prompt-input \
      'configuration validation' 2>&1 >/dev/null) ||
      installed_fail "Codex could not render prompt metadata for profile ${profile}"
    [[ "${profile_stderr}" != *'Model metadata for '* ]] ||
      installed_fail "profile ${profile} did not resolve its model metadata"
    configured_profiles=$((configured_profiles + 1))
    installed_pass "Codex profile ${profile}"
  done

  ((configured_profiles > 0)) ||
    installed_fail "no Codex profiles are configured; configure a gateway token first"
  printf '1..%d\n' "${INSTALLED_TEST_COUNT}"
}

if (($#)); then
  if [[ "$1" == --installed-codex && $# -eq 1 ]]; then
    run_installed_codex_test
    exit 0
  fi
  printf 'Usage: %s [--installed-codex]\n' "${0##*/}" >&2
  exit 2
fi

TEST_ROOT=$(mktemp -d "${TEST_DIR}/.ai-setup-test.XXXXXXXX")
TEST_COUNT=0
readonly TEST_CODEX_BIN="${TEST_ROOT}/fake-codex"

cleanup() {
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup EXIT

export AI_SETUP_AGENT_DIR="${TEST_ROOT}/agent"
export AI_SETUP_BASHRC_FILE="${TEST_ROOT}/home/.bashrc"

source "${SCRIPT_PATH}"

VOLCANO_MODELS="${VOLCANO_MODEL_CANDIDATES}"
BAILIAN_MODELS='["glm-5.2","qwen3.7-plus"]'
BLACKAI_GPT_MODELS='["gpt-5.6-sol"]'
BLACKAI_CLAUDE_MODELS='["claude-sonnet-4-6"]'

pass() {
  TEST_COUNT=$((TEST_COUNT + 1))
  printf 'ok %d - %s\n' "${TEST_COUNT}" "$1"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local expected=$1
  local actual=$2
  local message=$3
  [[ "${actual}" == "${expected}" ]] ||
    fail "${message}: expected '${expected}', got '${actual}'"
}

assert_json() {
  local json=$1
  local expression=$2
  local message=$3
  jq -e "${expression}" <<<"${json}" >/dev/null || fail "${message}"
}

assert_file_mode() {
  local expected=$1
  local file=$2
  local message=$3
  [[ -f "${file}" ]] || fail "${message}: missing file"
  assert_eq "${expected}" "$(stat -c '%a' "${file}")" "${message}"
}

render_codex_test_wrapper() {
  local codex_bin=$1
  local runtime_path=$2
  printf '#!/usr/bin/env bash\nexport PATH=%q\nexec %q "$@"' \
    "${runtime_path}" "${codex_bin}"
}

make_fake_codex() {
  local base_models
  base_models=$(jq -cn \
    --argjson extras '["gpt-5.6-sol"]' \
    '$extras | map({slug:., context_window:128000})')
  printf '{"models":%s}\n' "${base_models}" >"${TEST_ROOT}/bundled-models.json"
  cat >"${TEST_CODEX_BIN}" <<'FAKE_CODEX'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == debug && "${2:-}" == models && "${3:-}" == --bundled ]]; then
  cat "${CODEX_TEST_BUNDLED_CATALOG}"
  exit 0
fi
if [[ "${1:-}" == debug && "${2:-}" == models ]]; then
  for argument in "$@"; do
    if [[ "${argument}" == model_catalog_json=* ]]; then
      file=${argument#model_catalog_json=}
      file=${file%\"}
      file=${file#\"}
      cat "${file}"
      exit 0
    fi
  done
fi
exit 0
FAKE_CODEX
  chmod 700 "${TEST_CODEX_BIN}"
  export CODEX_TEST_BUNDLED_CATALOG="${TEST_ROOT}/bundled-models.json"
}

test_node_platform() {
  local expected
  case "$(uname -m)" in
    x86_64|amd64) expected=linux-x64 ;;
    aarch64|arm64) expected=linux-arm64 ;;
    armv7l) expected=linux-armv7l ;;
    *) return 0 ;;
  esac
  assert_eq "${expected}" "$(node_platform)" "node platform resolution"
  pass "node platform resolution"
}

test_codex_wrapper_preserves_runtime_path() {
  local runtime_dir="${TEST_ROOT}/split-codex-runtime"
  local codex_dir="${runtime_dir}/codex-bin"
  local node_dir="${runtime_dir}/node-bin"
  local wrapper="${runtime_dir}/codex-wrapper"
  mkdir -p "${codex_dir}" "${node_dir}"
  cat >"${codex_dir}/codex" <<'FAKE_NODE_CODEX'
#!/usr/bin/env node
FAKE_NODE_CODEX
  cat >"${node_dir}/node" <<'FAKE_NODE_RUNTIME'
#!/usr/bin/env bash
printf '%s\n' 'codex-cli split-runtime-test'
FAKE_NODE_RUNTIME
  chmod 700 "${codex_dir}/codex" "${node_dir}/node"
  write_executable_file "${wrapper}" \
    "$(render_codex_test_wrapper "${codex_dir}/codex" "${node_dir}:/usr/bin:/bin")"
  assert_eq 'codex-cli split-runtime-test' "$(PATH=/usr/bin:/bin "${wrapper}" --version)" \
    "Codex wrapper preserves the separate Node runtime path"
  pass "Codex wrapper with separate Node runtime"
}

test_codex_profiles() {
  local volcano blackai claude global_config
  volcano=$(codex_profile volcano)
  blackai=$(codex_profile blackai-gpt)
  claude=$(codex_profile blackai-claude)
  grep -Fq 'model_provider = "volcano-ai-gateway"' <<<"${volcano}" ||
    fail "Volcano profile provider"
  grep -Fq 'deepseek-v4-pro' <<<"${volcano}" || fail "Volcano profile model catalog"
  grep -Fq 'model_provider = "blackaicoding-gpt"' <<<"${blackai}" ||
    fail "BlackAI profile provider"
  grep -Fq 'gpt-5.6-sol' <<<"${blackai}" || fail "BlackAI profile model catalog"
  grep -Fq 'claude-sonnet-4-6' <<<"${claude}" || fail "BlackAI Claude model catalog"
  ! grep -Fq 'claude-sonnet-4-6' <<<"${blackai}" || fail "GPT profile excludes Claude models"
  ! grep -Fq 'gpt-5.6-sol' <<<"${claude}" || fail "Claude profile excludes GPT models"
  grep -Fq "model_catalog_json = \"$(codex_model_catalog_file blackai-gpt)\"" <<<"${blackai}" ||
    fail "BlackAI profile model catalog path"
  grep -Fq 'multi_agent = false' <<<"${volcano}" ||
    fail "Volcano profile disables unsupported namespace tools"
  grep -Fq 'web_search = "disabled"' <<<"${volcano}" ||
    fail "Volcano profile disables unsupported web search tools"
  grep -Fq 'multi_agent = false' <<<"${blackai}" ||
    fail "BlackAI GPT profile disables unsupported namespace tools"
  grep -Fq 'web_search = "disabled"' <<<"${blackai}" ||
    fail "BlackAI GPT profile disables unsupported web search tools"
  grep -Fq 'multi_agent = false' <<<"${claude}" ||
    fail "BlackAI Claude profile disables unsupported namespace tools"
  # 验证全局配置，并模拟已经由附加脚本安装的 JD profile。基础安装器重跑时必须
  # 保留 provider 注册，否则之前的 JD 会话无法直接 codex resume。
  mkdir -p "${CODEX_MODEL_CATALOG_DIR}"
  cat >"${CODEX_DIR}/jd.config.toml" <<'TOML'
model_provider = "jd"
[model_providers.jd]
name = "JD LLM Gateway"
TOML
  printf '%s\n' '{"models":[{"slug":"GPT-5.6-Sol-joybuilder"}]}' \
    >"${CODEX_MODEL_CATALOG_DIR}/jd.json"
  write_codex_global_config
  global_config=$(<"${CODEX_DIR}/config.toml")
  grep -Fq 'approval_policy = "never"' <<<"${global_config}" ||
    fail "Global Codex config missing approval_policy"
  grep -Fq 'sandbox_mode = "danger-full-access"' <<<"${global_config}" ||
    fail "Global Codex config missing sandbox_mode"
  grep -Fq '[model_providers.volcano-ai-gateway]' <<<"${global_config}" ||
    fail "Global Codex config missing Volcano provider"
  grep -Fq 'env_key = "VOLCANO_AI_GATEWAY_API_KEY"' <<<"${global_config}" ||
    fail "Global Codex config missing Volcano token variable"
  grep -Fq '[model_providers.bailian]' <<<"${global_config}" ||
    fail "Global Codex config missing Bailian provider"
  grep -Fq '[model_providers.blackaicoding-gpt]' <<<"${global_config}" ||
    fail "Global Codex config missing BlackAI GPT provider"
  grep -Fq 'env_key = "BLACKAICODING_GPT_API_KEY"' <<<"${global_config}" ||
    fail "Global Codex config missing BlackAI GPT token variable"
  grep -Fq '[model_providers.blackaicoding-claude]' <<<"${global_config}" ||
    fail "Global Codex config missing BlackAI Claude provider"
  grep -Fq '# BEGIN JD gateway provider' <<<"${global_config}" ||
    fail "Global Codex config did not preserve the JD provider registration"
  grep -Fq '[model_providers.jd]' <<<"${global_config}" ||
    fail "Global Codex config missing JD provider required by resume"
  grep -Fq 'env_key = "JD_GATEWAY_TOKEN"' <<<"${global_config}" ||
    fail "Global Codex config JD provider references the wrong token variable"
  grep -Fq 'models = ["GPT-5.6-Sol-joybuilder"]' <<<"${global_config}" ||
    fail "Global Codex config did not preserve the JD catalog models"
  assert_file_mode 600 "${CODEX_DIR}/config.toml" "Global Codex config mode"
  pass "Codex profile rendering"
}

test_codex_model_catalog() {
  local catalog gpt_catalog profile_stderr rendered
  make_fake_codex
  mkdir -p "${NODE_INSTALL_DIR}/bin"
  cp "${TEST_CODEX_BIN}" "${NODE_INSTALL_DIR}/bin/codex"
  chmod 700 "${NODE_INSTALL_DIR}/bin/codex"

  write_codex_profiles
  catalog=$(<"$(codex_model_catalog_file volcano)")
  gpt_catalog=$(<"$(codex_model_catalog_file blackai-gpt)")
  assert_json "${catalog}" \
    "[.models[].slug] | sort == (${VOLCANO_MODELS} | sort)" \
    "Volcano catalog contains only its token models"
  assert_json "${gpt_catalog}" \
    '[.models[].slug] == ["gpt-5.6-sol"]' \
    "GPT catalog contains only its token models"
  assert_json "${catalog}" \
    '[.models[] | select(.slug == "gpt-5.6-sol")] | length == 0' \
    "Volcano catalog excludes GPT models"
  assert_json "${gpt_catalog}" \
    '[.models[] | select(.slug == "deepseek-v4-pro")] | length == 0' \
    "GPT catalog excludes Volcano models"
  assert_json "${catalog}" \
    '[.models[] | select(.slug == "deepseek-v4-flash" and .context_window == 1000000)] | length == 1' \
    "add custom model metadata"
  assert_json "${catalog}" \
    '[.models[] | select(.slug == "deepseek-v4-pro" and .apply_patch_tool_type == "freeform" and .web_search_tool_type == "text_and_image" and .support_verbosity == false and .default_verbosity == null)] | length == 1' \
    "custom models use valid apply_patch/web_search enum values and no verbosity fields"

  rendered=$(CODEX_HOME="${CODEX_DIR}" "${NODE_INSTALL_DIR}/bin/codex" \
    debug models \
    -c "model_catalog_json=\"$(codex_model_catalog_file volcano)\"")
  assert_json "${rendered}" \
    "[.models[].slug] | sort == (${VOLCANO_MODELS} | sort)" \
    "Codex loads only Volcano token models"
  assert_json "${rendered}" \
    '[.models[] | select(.slug == "deepseek-v4-pro" and .apply_patch_tool_type == "freeform" and .support_verbosity == false)] | length == 1' \
    "Codex loads compatibility metadata"
  assert_json "${rendered}" \
    '[.models[] | select(.slug == "deepseek-v4-pro" and .supports_search_tool == false and .use_responses_lite == false and .tool_mode == null)] | length == 1' \
    "Volcano direct profile keeps Responses-compatible model metadata"
  profile_stderr=$(CODEX_HOME="${CODEX_DIR}" "${NODE_INSTALL_DIR}/bin/codex" \
    --profile blackai-gpt debug prompt-input 'metadata check' 2>&1 >/dev/null) ||
    fail "Codex loads the blackai-gpt profile"
  [[ "${profile_stderr}" != *'Model metadata for `gpt-5.6-sol` not found'* ]] ||
    fail "blackai-gpt profile resolves model metadata"
  pass "Codex model catalog generation and loading"

  if [[ -n "${REAL_CODEX_BIN}" ]]; then
    rendered=$(CODEX_HOME="${CODEX_DIR}" "${REAL_CODEX_BIN}" \
      debug models \
      -c "model_catalog_json=\"$(codex_model_catalog_file volcano)\"") ||
      fail "real Codex loads the generated catalog"
    assert_json "${rendered}" \
      "[.models[].slug] | sort == (${VOLCANO_MODELS} | sort)" \
      "real Codex sees only Volcano token models"
    pass "real Codex catalog compatibility"
  fi
}

test_gateway_model_parser() {
  local models
  models=$(parse_gateway_models <<<'{"data":[{"id":"gpt-b"},{"id":"gpt-a"},{"id":"gpt-a"},"gpt-c",{"bad":true},null]}')
  assert_json "${models}" '. == ["gpt-a","gpt-b","gpt-c"]' \
    "parse token-scoped gateway models"
  pass "token-scoped gateway model parsing"
}

test_token_model_discovery() {
  local models
  curl() {
    printf '%s\n' '{"data":[{"id":"allowed-b"},{"id":"allowed-a"}]}'
  }
  discover_token_models 'test provider' 'https://example.invalid/v1' \
    'test-key' models >/dev/null
  unset -f curl
  assert_json "${models}" '. == ["allowed-a","allowed-b"]' \
    "write token-scoped discovery result"
  pass "token-scoped model discovery"
}

test_model_discovery_failures() {
  local models output
  models='not-empty'
  curl() { printf '%s\n' '{"data":[]}'; }
  output=$(mktemp "${TEST_ROOT}/discover-empty.XXXXXX")
  discover_token_models 'empty provider' 'https://example.invalid/v1' \
    'test-key' models >"${output}" 2>&1
  output=$(<"${output}")
  assert_eq '[]' "${models}" "empty model discovery is skipped"
  grep -Fq 'WARNING' <<<"${output}" || fail "empty discovery must warn"
  unset -f curl
  models='not-empty'

  curl() { printf '%s\n' '{not-json'; }
  output=$(mktemp "${TEST_ROOT}/discover-malformed.XXXXXX")
  discover_token_models 'malformed provider' 'https://example.invalid/v1' \
    'test-key' models >"${output}" 2>&1
  output=$(<"${output}")
  assert_eq '[]' "${models}" "malformed model discovery is skipped"
  grep -Fq 'WARNING' <<<"${output}" || fail "malformed discovery must warn"
  unset -f curl

  models='not-empty'
  discover_token_models 'unset provider' 'https://example.invalid/v1' '' models >/dev/null
  assert_eq '[]' "${models}" "unset token returns no models"
  pass "model discovery failure handling"
}

test_volcano_model_probe() {
  local models
  curl() {
    if [[ "$*" == *'deepseek-v4-flash'* ]]; then
      printf '200'
    else
      printf '403'
    fi
  }
  probe_responses_models 'test Volcano' 'https://example.invalid/v1' 'test-key' \
    '["deepseek-v4-flash","deepseek-v4-pro"]' models >/dev/null
  unset -f curl
  assert_json "${models}" '. == ["deepseek-v4-flash"]' \
    "retain only token-verified Volcano models"
  pass "Volcano token model verification"
}

test_volcano_probe_failure() {
  local models
  models='not-empty'
  curl() { printf '500'; }
  probe_responses_models 'failed Volcano' 'https://example.invalid/v1' 'test-key' \
    '["deepseek-v4-pro"]' models >/dev/null 2>&1
  assert_eq '[]' "${models}" "all failed Volcano probes are skipped"
  unset -f curl
  pass "Volcano probe failure handling"
}

test_claude_settings_builder() {
  local settings
  settings=$(build_claude_settings \
    '{"env":{"KEEP_ME":"yes","ANTHROPIC_API_KEY":"old","ANTHROPIC_DEFAULT_HAIKU_MODEL":"claude-fable-5"},"modelOverrides":{"claude-haiku-4-5-20251001":"old","keep-model":"keep"}}' \
    'local-test-key' \
    'http://127.0.0.1:4567' \
    'deepseek-v4-flash' \
    'deepseek-v4-pro')
  assert_json "${settings}" '.env.KEEP_ME == "yes"' "preserve unrelated Claude settings"
  assert_json "${settings}" '.env.ANTHROPIC_API_KEY == null' "remove obsolete Claude API key"
  assert_json "${settings}" '.env.ANTHROPIC_AUTH_TOKEN == "local-test-key"' "set local CCR key"
  assert_json "${settings}" '.env.ANTHROPIC_BASE_URL == "http://127.0.0.1:4567"' "set CCR URL"
  assert_json "${settings}" '.env.ANTHROPIC_DEFAULT_HAIKU_MODEL == null' "remove forced Haiku default"
  assert_json "${settings}" '.permissions.defaultMode == "bypassPermissions"' \
    "configure Claude continuous execution mode"
  assert_json "${settings}" '.modelOverrides["claude-fable-5"] == "火山AI网关/deepseek-v4-flash"' "set Fable model override"
  assert_json "${settings}" '.modelOverrides["claude-haiku-4-5-20251001"] == null' "remove obsolete Haiku override"
  assert_json "${settings}" '.modelOverrides["keep-model"] == "keep"' "preserve unrelated model override"
  assert_json "${settings}" '.modelOverrides["claude-opus-4-6"] == "火山AI网关/deepseek-v4-pro"' "set model override"
  pass "Claude settings rendering"
}

test_ccr_config_builder() {
  local response config
  response='{"ok":true,"value":{"APIKEY":"old-local","Providers":[{"id":"custom","name":"Custom","enabled":true},{"id":"volcano-ai-gateway","name":"火山AI网关","apiKey":"old-volcano"}],"profile":{"claudeCode":{},"profiles":[{"agent":"claude-code"},{"agent":"codex"}]}}}'
  config=$(build_ccr_config \
    "${response}" \
    'new-local' \
    'new-volcano' \
    'new-bailian' \
    '127.0.0.1' \
    '3456' \
    '3457' \
    'http://127.0.0.1:3456' \
    '["deepseek-v4-flash","deepseek-v4-pro"]' \
    '["qwen3.7-plus"]' \
    'deepseek-v4-flash' \
    'deepseek-v4-pro' \
    'new-blackai-claude' \
    '["claude-sonnet-4-6","claude-fable-5"]' \
    'new-blackai-gpt' \
    '["gpt-5.6-sol","gpt-5.6-terra"]' \
    'new-jd-token' \
    '["GPT-5.6-Sol-joybuilder","GPT-6-Astra-joybuilder"]')
  assert_json "${config}" '.APIKEY == "new-local"' "set CCR local key"
  assert_json "${config}" '.gateway.port == 3456 and .gateway.corePort == 3457' "set CCR ports"
  assert_json "${config}" '[.Providers[] | select(.id == "custom")] | length == 1' "preserve custom provider"
  assert_json "${config}" '[.Providers[] | select(.id == "volcano-ai-gateway" and .apiKey == "new-volcano")] | length == 1' "replace Volcano provider"
  assert_json "${config}" '[.Providers[] | select(.id == "volcano-ai-gateway")][0].models == ["deepseek-v4-flash","deepseek-v4-pro"]' "use discovered Volcano models"
  assert_json "${config}" '[.Providers[] | select(.id == "bailian")][0].models == ["qwen3.7-plus"]' "use discovered Bailian models"
  assert_json "${config}" '[.Providers[] | select(.id == "blackai-claude" and .apiKey == "new-blackai-claude")][0].models == ["claude-sonnet-4-6","claude-fable-5"]' "use discovered BlackAI Claude models"
  assert_json "${config}" '[.Providers[] | select(.id == "blackai-gpt" and .apiKey == "new-blackai-gpt" and .type == "openai_responses")][0].models == ["gpt-5.6-sol","gpt-5.6-terra"]' "use discovered BlackAI GPT models in the unified CCR catalog"
  assert_json "${config}" '[.Providers[] | select(.id == "jd" and .name == "京东网关" and .apiKey == "new-jd-token" and .type == "openai_chat_completions")][0].models == ["GPT-5.6-Sol-joybuilder","GPT-6-Astra-joybuilder"]' "restore JD in the unified CCR catalog"
  assert_json "${config}" '[.Providers[] | select(.id == "volcano-ai-gateway" or .id == "bailian" or .id == "blackai-gpt" or .id == "blackai-claude" or .id == "jd") | .id] == ["volcano-ai-gateway","bailian","blackai-gpt","blackai-claude","jd"]' "keep deterministic gateway priority"
  assert_json "${config}" '.preferredProvider == "火山AI网关" and .defaultOpenAIModel == "deepseek-v4-flash"' "prefer Volcano for unqualified/default requests"
  assert_json "${config}" '.profile.profiles[] | select(.agent == "codex") | .providerId == "claude-code-router" and .model == "火山AI网关/deepseek-v4-flash"' "set the default Codex route to Volcano through CCR"
  assert_json "${config}" '.profile.profiles[] | select(.agent == "claude-code") | .opusModel == "火山AI网关/deepseek-v4-pro"' "update Claude profile"
  pass "CCR configuration rendering"
}

test_ccr_config_from_empty_state() {
  local config
  config=$(build_ccr_config \
    '{"ok":true,"value":{}}' \
    'new-local' \
    '' \
    '' \
    '127.0.0.1' \
    '3456' \
    '3457' \
    'http://127.0.0.1:3456' \
    '[]' \
    '[]' \
    '' \
    '' \
    '' \
    '[]')
  assert_json "${config}" '.profile | type == "object"' \
    "initialize missing CCR profile"
  assert_json "${config}" '.profile.profiles == []' \
    "initialize missing CCR profile list"
  assert_json "${config}" '.APIKEY == "new-local" and .gateway.port == 3456' \
    "configure CCR from empty state"
  pass "empty CCR configuration rendering"
}

test_ccr_config_idempotence() {
  local response first second
  response='{"ok":true,"value":{"APIKEY":"old-local","Providers":[],"profile":{"profiles":[]}}}'
  first=$(build_ccr_config "${response}" 'local' 'volcano' 'bailian' \
    '127.0.0.1' '3456' '3457' 'http://127.0.0.1:3456' \
    '["deepseek-v4-pro"]' '[]' 'deepseek-v4-pro' 'deepseek-v4-pro' \
    'blackai-old' '["claude-fable-5"]')
  second=$(build_ccr_config \
    "$(jq -cn --argjson value "${first}" '{ok:true,value:$value}')" \
    '' '' '' '127.0.0.1' '3456' '3457' 'http://127.0.0.1:3456' \
    '["deepseek-v4-pro"]' '[]' 'deepseek-v4-pro' 'deepseek-v4-pro' \
    '' '["claude-fable-5"]')
  assert_json "${second}" '[.Providers[] | select(.id == "volcano-ai-gateway")] | length == 1' \
    "CCR rerun does not duplicate Volcano provider"
  assert_json "${second}" '[.Providers[] | select(.id == "blackai-claude")] | length == 1' \
    "CCR rerun does not duplicate BlackAI provider"
  assert_json "${second}" '[.Providers[] | select(.id == "blackai-claude")][0].apiKey == "blackai-old"' \
    "CCR rerun preserves BlackAI key"
  local with_existing_jd
  with_existing_jd=$(build_ccr_config \
    '{"ok":true,"value":{"Providers":[{"id":"jd","name":"京东网关","apiKey":"existing-jd","type":"openai_responses","models":["existing-jd-model"]}],"profile":{"profiles":[]}}}' \
    'local' '' '' '127.0.0.1' '3456' '3457' 'http://127.0.0.1:3456' \
    '[]' '[]' '' '' '' '[]' '' '[]')
  assert_json "${with_existing_jd}" '[.Providers[] | select(.id == "jd")][0]
    | .apiKey == "existing-jd" and .models == ["existing-jd-model"]' \
    "CCR rerun preserves JD when no persisted JD state is available"
  pass "CCR configuration idempotence"
}

test_stale_profile_cleanup() {
  local catalog_file profile_file
  make_fake_codex
  mkdir -p "${NODE_INSTALL_DIR}/bin"
  cp "${TEST_CODEX_BIN}" "${NODE_INSTALL_DIR}/bin/codex"
  write_codex_profiles
  profile_file="${CODEX_DIR}/blackai-claude.config.toml"
  catalog_file="$(codex_model_catalog_file blackai-claude)"
  [[ -f "${profile_file}" && -f "${catalog_file}" ]] || fail "initial profile files"
  assert_file_mode 600 "${profile_file}" "Codex profile mode"
  assert_file_mode 600 "${catalog_file}" "Codex catalog mode"
  BLACKAI_CLAUDE_MODELS='[]'
  write_codex_profiles
  [[ ! -e "${profile_file}" && ! -e "${catalog_file}" ]] || fail "stale profile files removed"
  BLACKAI_CLAUDE_MODELS='["claude-sonnet-4-6"]'
  pass "stale profile cleanup"
}

test_secure_file_permissions() {
  local secure executable
  DRY_RUN=0
  secure="${TEST_ROOT}/secure-file"
  executable="${TEST_ROOT}/launcher"
  write_secure_file "${secure}" 'secret value' 600
  write_executable_file "${executable}" 'echo ok'
  assert_file_mode 600 "${secure}" "secure file mode"
  assert_file_mode 700 "${executable}" "executable file mode"
  pass "secure file permissions"
}

test_gateway_key_round_trip() {
  local original_volcano original_claude output
  DRY_RUN=0
  unset VOLCANO_AI_GATEWAY_API_KEY BAILIAN_API_KEY \
    BLACKAICODING_GPT_API_KEY BLACKAICODING_CLAUDE_API_KEY
  original_volcano='key with spaces $ and "quotes"'
  original_claude="key-with-'quote'"
  VOLCANO_AI_GATEWAY_API_KEY="${original_volcano}"
  BLACKAICODING_CLAUDE_API_KEY="${original_claude}"
  export VOLCANO_AI_GATEWAY_API_KEY BLACKAICODING_CLAUDE_API_KEY
  output=$(write_codex_environment)
  [[ "${output}" != *"${original_volcano}"* && "${output}" != *"${original_claude}"* ]] ||
    fail "gateway keys leaked to output"
  unset VOLCANO_AI_GATEWAY_API_KEY BLACKAICODING_CLAUDE_API_KEY
  load_persisted_gateway_keys
  assert_eq "${original_volcano}" "${VOLCANO_AI_GATEWAY_API_KEY}" "round-trip Volcano key"
  assert_eq "${original_claude}" "${BLACKAICODING_CLAUDE_API_KEY}" "round-trip Claude key"
  assert_file_mode 600 "${CODEX_ENV_FILE}" "gateway environment mode"
  ! grep -Fq "${original_volcano}" "${AGENT_BIN_DIR}/codex" || fail "launcher contains gateway key"
  pass "gateway key persistence"
}

test_persisted_jd_gateway_recovery() {
  local loaded_token='persisted JD token'
  mkdir -p "${CODEX_MODEL_CATALOG_DIR}"
  cat >"${AGENT_ENV_FILE}" <<EOF
# BEGIN JD gateway token
export JD_GATEWAY_TOKEN=$(printf '%q' "${loaded_token}")
# END JD gateway token
EOF
  cat >"${CODEX_MODEL_CATALOG_DIR}/jd.json" <<'JSON'
{"models":[{"slug":"GPT-5.6-Sol-joybuilder"},{"slug":"GPT-6-Astra-joybuilder"}]}
JSON
  unset JD_GATEWAY_TOKEN
  JD_MODELS='[]'
  load_persisted_jd_gateway >/dev/null
  assert_eq "${loaded_token}" "${JD_GATEWAY_TOKEN}" "restore JD token from agent environment"
  assert_eq '["GPT-5.6-Sol-joybuilder","GPT-6-Astra-joybuilder"]' "${JD_MODELS}" \
    "restore JD models from the verified catalog"
  unset JD_GATEWAY_TOKEN
  JD_MODELS='[]'
  pass "persisted JD gateway recovery"
}

test_service_pid_reader() {
  mkdir -p "${CCR_DIR}"
  printf '%s\n' '{"pid":12345}' >"${CCR_SERVICE_FILE}"
  assert_eq 12345 "$(service_pid)" "service PID parsing"
  rm -f "${CCR_SERVICE_FILE}"
  assert_eq '' "$(service_pid)" "missing service PID"
  pass "service PID parsing"
}

test_rolling_port_selection() {
  port_is_available() {
    (( $1 >= 3462 ))
  }
  select_ccr_ports
  assert_eq 3462 "${CCR_GATEWAY_PORT}" "rolling gateway port"
  assert_eq 3463 "${CCR_CORE_PORT}" "rolling core port"
  assert_eq 3464 "${CCR_MANAGEMENT_PORT}" "rolling management port"
  pass "rolling CCR port selection"
}

test_agent_layout() {
  local loaded_jd_token
  mkdir -p "${AGENT_DIR}"
  printf '%s\n' keep >"${AGENT_DIR}/user-file"
  JD_GATEWAY_TOKEN='existing jd token'
  export JD_GATEWAY_TOKEN
  initialize_install_layout
  [[ -d "${AGENT_BIN_DIR}" && -d "${AGENT_CONFIG_DIR}" &&
     -d "${AGENT_HOME}" && -d "${AGENT_CACHE_DIR}/npm" &&
     -d "${CLAUDE_CONFIG_DIR}" && -d "${CODEX_DIR}" &&
     -d "${CODEX_MODEL_CATALOG_DIR}" ]] || fail "agent subdirectories"
  [[ -f "${AGENT_DIR}/user-file" ]] || fail "existing agent content preservation"
  [[ -f "${AGENT_ENV_FILE}" ]] || fail "agent environment file"
  grep -Fq 'export JD_GATEWAY_TOKEN=' "${AGENT_ENV_FILE}" ||
    fail "agent environment does not preserve the JD token"
  assert_file_mode 600 "${AGENT_ENV_FILE}" "agent environment with JD token"
  loaded_jd_token=$(env -u JD_GATEWAY_TOKEN bash --noprofile --norc -c \
    'source "$1"; printf "%s" "$JD_GATEWAY_TOKEN"' bash "${AGENT_ENV_FILE}")
  assert_eq 'existing jd token' "${loaded_jd_token}" "round-trip JD token"
  unset JD_GATEWAY_TOKEN
  write_runtime_files
  loaded_jd_token=$(env -u JD_GATEWAY_TOKEN bash --noprofile --norc -c \
    'source "$1"; printf "%s" "$JD_GATEWAY_TOKEN"' bash "${AGENT_ENV_FILE}")
  assert_eq 'existing jd token' "${loaded_jd_token}" "preserve JD token after installer rerun"
  [[ ! -e "${AGENT_DIR}/README.md" ]] || fail "installer must not generate README"
  [[ -x "${AGENT_BIN_DIR}/claude" && -x "${AGENT_BIN_DIR}/codex" &&
     -x "${AGENT_BIN_DIR}/ccr" ]] || fail "container-local launchers"
  pass "simple container-local agent layout"
}

test_codex_resume_uses_original_profile() {
  local jd_session_id='11111111-1111-4111-8111-111111111111'
  local volcano_session_id='22222222-2222-4222-8222-222222222222'
  local bailian_session_id='33333333-3333-4333-8333-333333333333'
  local ccr_session_id='44444444-4444-4444-8444-444444444444'
  local blackai_gpt_session_id='55555555-5555-4555-8555-555555555555'
  local blackai_claude_session_id='66666666-6666-4666-8666-666666666666'
  local session_dir="${CODEX_DIR}/sessions/2026/09/11"
  local output expected profile session_id provider model
  mkdir -p "${NODE_INSTALL_DIR}/bin" "${session_dir}"
  cat >"${NODE_INSTALL_DIR}/bin/codex" <<'FAKE_CODEX'
#!/usr/bin/env bash
printf '%s\n' "$@"
FAKE_CODEX
  chmod 700 "${NODE_INSTALL_DIR}/bin/codex"

  while IFS=$'\t' read -r profile session_id provider model; do
    printf 'model_provider = "%s"\nmodel = "%s"\n' \
      "${provider}" "${model}" >"${CODEX_DIR}/${profile}.config.toml"
    printf '%s\n' \
      "{\"type\":\"session_meta\",\"payload\":{\"model_provider\":\"${provider}\"}}" \
      >"${session_dir}/rollout-test-${session_id}.jsonl"
  done <<EOF
jd	${jd_session_id}	jd	GPT-5.6-Sol-joybuilder
volcano	${volcano_session_id}	volcano-ai-gateway	deepseek-v4-flash
bailian	${bailian_session_id}	bailian	qwen-max
blackai-gpt	${blackai_gpt_session_id}	blackaicoding-gpt	gpt-5.6-sol
blackai-claude	${blackai_claude_session_id}	blackaicoding-claude	claude-sonnet-4-6
EOF
  printf '%s\n' 'model_provider = "claude-code-router"' \
    >"${CODEX_DIR}/claude-code-router.config.toml"
  printf '%s\n' '{"models":[]}' >"${CODEX_DIR}/ccr-model-catalog.json"
  printf '%s\n' \
    '{"type":"session_meta","payload":{"model_provider":"claude-code-router"}}' \
    >"${session_dir}/rollout-test-${ccr_session_id}.jsonl"

  write_runtime_files
  while IFS=$'\t' read -r profile session_id provider; do
    output=$("${AGENT_BIN_DIR}/codex" resume "${session_id}")
    expected=$(printf '%s\n' --profile "${profile}" resume "${session_id}")
    assert_eq "${expected}" "${output}" \
      "bare resume automatically layers the original ${provider} profile"
  done <<EOF
jd	${jd_session_id}	jd
volcano	${volcano_session_id}	volcano-ai-gateway
bailian	${bailian_session_id}	bailian
blackai-gpt	${blackai_gpt_session_id}	blackaicoding-gpt
blackai-claude	${blackai_claude_session_id}	blackaicoding-claude
EOF

  output=$("${AGENT_BIN_DIR}/codex" resume "${volcano_session_id}" --profile jd)
  expected=$(printf '%s\n' \
    -c 'model_provider="claude-code-router"' \
    -m '京东网关/GPT-5.6-Sol-joybuilder' \
    resume "${volcano_session_id}")
  assert_eq "${expected}" "${output}" \
    "explicit JD profile switches the resumed session through CCR"

  output=$("${AGENT_BIN_DIR}/codex" --profile=volcano -m glm-5.3 resume "${jd_session_id}")
  expected=$(printf '%s\n' \
    -c 'model_provider="claude-code-router"' \
    -m '火山AI网关/glm-5.3' \
    resume "${jd_session_id}")
  assert_eq "${expected}" "${output}" \
    "explicit model and gateway switch are normalized through CCR"

  output=$("${AGENT_BIN_DIR}/codex" resume "${ccr_session_id}")
  expected=$(printf '%s\n' resume "${ccr_session_id}")
  assert_eq "${expected}" "${output}" \
    "CCR resume keeps the base launcher behavior"
  pass "Codex resume selects all original gateway profiles and honors explicit overrides"
}

test_setup_user_ownership() {
  ((EUID == 0)) || return 0
  id pc >/dev/null 2>&1 || return 0
  local owned_root="${TEST_ROOT}/owned-agent"
  local owned_bashrc="${TEST_ROOT}/owned-home/.bashrc"
  AI_SETUP_USER=pc AI_SETUP_AGENT_DIR="${owned_root}" \
    AI_SETUP_BASHRC_FILE="${owned_bashrc}" bash -c \
    'source "$1"; initialize_install_layout; ensure_setup_user_ownership' \
    bash "${SCRIPT_PATH}" >/dev/null
  assert_eq pc "$(stat -c '%U' "${owned_root}/config/codex")" \
    "setup user owns Codex configuration"
  assert_eq pc "$(stat -c '%U' "${owned_root}/env.sh")" \
    "setup user owns runtime environment"
  assert_eq pc "$(stat -c '%U' "${owned_bashrc}")" \
    "setup user owns Bash startup file"
  pass "root installation assigns mutable files to setup user"
}

test_runtime_environment_path_idempotence() {
  local polluted_path expected_path first_load repeated_load
  polluted_path="${AGENT_BIN_DIR}:/usr/bin:${NODE_INSTALL_DIR}/bin:${AGENT_BIN_DIR}:/bin:${NODE_INSTALL_DIR}/bin"
  expected_path="${AGENT_BIN_DIR}:${NODE_INSTALL_DIR}/bin:/usr/bin:/bin"

  first_load=$(PATH="${polluted_path}" bash -c \
    'source "$1"; printf "%s\n" "$PATH"' bash "${AGENT_ENV_FILE}")
  repeated_load=$(PATH="${polluted_path}" bash -c \
    'source "$1"; source "$1"; source "$1"; printf "%s\n" "$PATH"' \
    bash "${AGENT_ENV_FILE}")

  assert_eq "${expected_path}" "${first_load}" \
    "environment removes pre-existing managed PATH entries"
  assert_eq "${expected_path}" "${repeated_load}" \
    "repeated environment loading keeps PATH stable"
  pass "idempotent runtime PATH loading"
}
test_bash_startup_configuration() {
  local original_mode loaded_environment
  mkdir -p "$(dirname -- "${BASH_RC_FILE}")"
  printf '%s\n' '# existing user configuration' 'export USER_SETTING=keep' >"${BASH_RC_FILE}"
  chmod 640 "${BASH_RC_FILE}"
  original_mode=$(stat -c '%a' "${BASH_RC_FILE}")

  configure_bash_startup
  configure_bash_startup

  assert_eq 1 "$(grep -Fxc '# BEGIN ai-coding-setup environment' "${BASH_RC_FILE}")" \
    "single managed Bash startup block"
  assert_eq 1 "$(grep -Fxc "[[ ! -f ${AGENT_ENV_FILE} ]] || source ${AGENT_ENV_FILE}" "${BASH_RC_FILE}")" \
    "single environment source command"
  grep -Fq 'export USER_SETTING=keep' "${BASH_RC_FILE}" ||
    fail "Bash startup preserves existing configuration"
  assert_eq "${original_mode}" "$(stat -c '%a' "${BASH_RC_FILE}")" \
    "Bash startup file mode preservation"
  loaded_environment=$(bash --noprofile --rcfile "${BASH_RC_FILE}" -ic \
    'printf "%s|%s\n" "$CODEX_HOME" "${PATH%%:*}"' 2>/dev/null)
  assert_eq "${CODEX_DIR}|${AGENT_BIN_DIR}" "${loaded_environment}" \
    "new interactive Bash loads the managed environment"
  pass "idempotent Bash startup configuration"
}

test_operation_manual() {
  [[ -f "${MANUAL_PATH}" && -r "${MANUAL_PATH}" ]] || fail "readable operation manual"
  grep -Fq 'bash ./set_claude_provider_keys.sh' "${MANUAL_PATH}" ||
    fail "manual installer command"
  grep -Fq 'bash ./test/set_claude_provider_keys_test.sh' "${MANUAL_PATH}" ||
    fail "manual test command"
  grep -Fq 'bash ./test/set_claude_provider_keys_test.sh --installed-codex' "${MANUAL_PATH}" ||
    fail "manual installed Codex test command"
  grep -Fq '用于安装完成后检查当前容器中的真实 Codex 配置' "${MANUAL_PATH}" ||
    fail "manual source layout"
  ! grep -Fq '/mnt/sfs_turbo/tongpan' "${MANUAL_PATH}" ||
    fail "manual contains a machine-specific source path"
  ! grep -Eq '1\.\.[0-9]+' "${MANUAL_PATH}" ||
    fail "manual contains a fixed test count"
  grep -Fq '缺少时安装 Node.js，并安装或更新 Claude Code、Codex 和 CCR' "${MANUAL_PATH}" ||
    fail "manual Node.js installation behavior"
  grep -Fq 'source "/agent/env.sh"' "${MANUAL_PATH}" || fail "manual environment command"
  grep -Fq '直接按 Enter 会保留原值' "${MANUAL_PATH}" || fail "manual existing key behavior"
  grep -Fq -- '--configure-only' "${MANUAL_PATH}" || fail "manual configure-only usage"
  grep -Fq -- '--install-only' "${MANUAL_PATH}" || fail "manual install-only usage"
  grep -Fq -- '--dry-run' "${MANUAL_PATH}" || fail "manual dry-run usage"
  grep -Fq 'codex --profile volcano' "${MANUAL_PATH}" || fail "manual Volcano profile"
  grep -Fq 'codex --profile bailian' "${MANUAL_PATH}" || fail "manual Bailian profile"
  grep -Fq 'codex --profile blackai-gpt' "${MANUAL_PATH}" || fail "manual BlackAI GPT profile"
  grep -Fq 'codex --profile blackai-claude' "${MANUAL_PATH}" || fail "manual BlackAI Claude profile"
  grep -Fq '通过 `/model` 查看' "${MANUAL_PATH}" || fail "manual Claude model discovery"
  grep -Fq 'gateways.env' "${MANUAL_PATH}" || fail "manual key security warning"
  grep -Fq 'rm -rf -- "/agent"' "${MANUAL_PATH}" || fail "manual cleanup path"
  ! grep -Fq '安装后生成的操作手册' "${MANUAL_PATH}" || fail "manual claims generated copy"
  pass "operation manual instructions"
}

test_codex_install_smoke() {
  [[ -n "${REAL_CODEX_BIN}" ]] || return 0
  local codex_wrapper output
  DRY_RUN=0
  codex_wrapper=$(render_codex_test_wrapper "${REAL_CODEX_BIN}" "${REAL_CODEX_PATH}")
  write_executable_file "${NODE_INSTALL_DIR}/bin/codex" "${codex_wrapper}"
  VOLCANO_MODELS="${VOLCANO_MODEL_CANDIDATES}"
  BAILIAN_MODELS='["glm-5.2","qwen3.7-plus"]'
  BLACKAI_GPT_MODELS='["gpt-5.6-sol"]'
  BLACKAI_CLAUDE_MODELS='["claude-sonnet-4-6"]'
  VOLCANO_AI_GATEWAY_API_KEY=test-volcano
  BAILIAN_API_KEY=test-bailian
  BLACKAICODING_GPT_API_KEY=test-blackai-gpt
  BLACKAICODING_CLAUDE_API_KEY=test-blackai-claude
  export VOLCANO_AI_GATEWAY_API_KEY BAILIAN_API_KEY \
    BLACKAICODING_GPT_API_KEY BLACKAICODING_CLAUDE_API_KEY
  write_codex_environment >/dev/null
  write_codex_profiles
  output=$(AI_SETUP_AGENT_DIR="${AGENT_DIR}" bash "${TEST_SCRIPT_PATH}" \
    --installed-codex) ||
    fail "installed Codex smoke test"
  grep -Fq 'Codex profile volcano' <<<"${output}" ||
    fail "installed Codex smoke test did not validate profiles"
  pass "installed Codex smoke test"
}

test_agent_file_collision() {
  local collision="${TEST_ROOT}/agent-file"
  printf '%s\n' occupied >"${collision}"
  if AI_SETUP_AGENT_DIR="${collision}" bash -c '
      source "$1"
      initialize_install_layout
    ' bash "${SCRIPT_PATH}" >"${TEST_ROOT}/collision.log" 2>&1; then
    fail "agent file collision must fail"
  fi
  grep -Fq 'already exists as a file' "${TEST_ROOT}/collision.log" ||
    fail "agent file collision message"
  pass "agent file collision rejection"
}

test_agent_path_validation() {
  local link="${TEST_ROOT}/agent-link"
  ln -s "${TEST_ROOT}/missing-target" "${link}"
  if AI_SETUP_AGENT_DIR="${link}" bash -c \
      'source "$1" && initialize_install_layout' bash "${SCRIPT_PATH}" >/dev/null 2>&1; then
    fail "symbolic-link agent path must fail"
  fi
  if AI_SETUP_AGENT_DIR='relative-agent' bash -c \
      'source "$1" && initialize_install_layout' bash "${SCRIPT_PATH}" >/dev/null 2>&1; then
    fail "relative agent path must fail"
  fi
  pass "agent path validation"
}

test_argument_parsing() {
  INSTALL_TOOLS=1
  CONFIGURE_GATEWAYS=1
  DRY_RUN=0
  EXIT_AFTER_HELP=0
  parse_args --configure-only --dry-run
  assert_eq 0 "${INSTALL_TOOLS}" "configure-only install flag"
  assert_eq 1 "${CONFIGURE_GATEWAYS}" "configure-only configure flag"
  assert_eq 1 "${DRY_RUN}" "dry-run flag"
  EXIT_AFTER_HELP=0
  parse_args --help >/dev/null
  assert_eq 1 "${EXIT_AFTER_HELP}" "help exit flag"
  if bash "${SCRIPT_PATH}" --unknown-option >/dev/null 2>&1; then
    fail "unknown option must fail"
  fi
  pass "argument parsing"
}

test_dry_run_is_non_destructive() {
  local dry_dir="${TEST_ROOT}/dry-run-agent"
  AI_SETUP_AGENT_DIR="${dry_dir}" bash "${SCRIPT_PATH}" --configure-only --dry-run \
    >"${TEST_ROOT}/dry-run.log" 2>&1 || fail "dry-run command"
  [[ ! -e "${dry_dir}" ]] || fail "dry-run created files"
  grep -Fq '[ai-setup] Would save ' "${TEST_ROOT}/dry-run.log" ||
    fail "dry-run save preview"
  ! grep -Fq '[ai-setup] Saved ' "${TEST_ROOT}/dry-run.log" ||
    fail "dry-run claimed files were saved"
  pass "dry-run is non-destructive"
}

test_node_version_guard() {
  local old_node="${TEST_ROOT}/old-node"
  cat >"${old_node}" <<'OLD_NODE'
#!/usr/bin/env bash
if [[ "${1:-}" == -p ]]; then printf '21\n'; else printf 'v21.9.0\n'; fi
OLD_NODE
  chmod 700 "${old_node}"
  if (require_supported_node_version "${old_node}" >/dev/null 2>&1); then
    fail "old Node.js version must fail"
  fi
  pass "Node.js version guard"
}

test_dnf_metadata_recovery() {
  local fake_dnf="${TEST_ROOT}/fake-dnf"
  local dnf_log="${TEST_ROOT}/dnf-args"
  cat >"${fake_dnf}" <<'FAKE_DNF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${DNF_TEST_LOG}"
case "$*" in
  *'clean all'*) exit 0 ;;
  *"--disablerepo=${AI_SETUP_DNF_DISABLE_REPO}"*) exit 0 ;;
  *) exit 1 ;;
esac
FAKE_DNF
  chmod 700 "${fake_dnf}"
  export DNF_TEST_LOG="${dnf_log}" AI_SETUP_DNF_DISABLE_REPO='broken-update'
  install_libatomic_with_dnf "${fake_dnf}"
  grep -Fqx 'install -y libatomic' "${dnf_log}" || fail "dnf initial install attempt"
  grep -Fqx 'clean all' "${dnf_log}" || fail "dnf metadata cleanup"
  grep -Fqx -- '--refresh install -y libatomic' "${dnf_log}" ||
    fail "dnf refreshed install attempt"
  grep -Fqx -- '--refresh --disablerepo=broken-update install -y libatomic' "${dnf_log}" ||
    fail "dnf disabled-repository fallback"
  unset DNF_TEST_LOG AI_SETUP_DNF_DISABLE_REPO
  pass "dnf metadata recovery"
}

test_cli_install_command() {
  local npm_args claude_package codex_package resolved_platform architecture
  local claude_suffix='' claude_native codex_native claude_spec codex_spec
  local fake_npm="${NODE_INSTALL_DIR}/bin/npm"
  local fake_node="${NODE_INSTALL_DIR}/bin/node"
  local args_file="${TEST_ROOT}/npm-args"
  local npm_count_file="${TEST_ROOT}/npm-count"
  local postinstall_marker="${TEST_ROOT}/claude-postinstall"
  claude_package="${NODE_INSTALL_DIR}/lib/node_modules/@anthropic-ai/claude-code"
  codex_package="${NODE_INSTALL_DIR}/lib/node_modules/@openai/codex"
  mkdir -p "${NODE_INSTALL_DIR}/bin" "${claude_package}" "${codex_package}"
  [[ -n "${REAL_NODE_BIN}" ]] || fail "real Node.js is required for CLI installation tests"
  rm -f -- "${fake_node}"
  printf '#!/usr/bin/env bash\nexec %q "$@"\n' "${REAL_NODE_BIN}" >"${fake_node}"
  chmod 700 "${fake_node}"
  cat >"${claude_package}/install.cjs" <<'CLAUDE_POSTINSTALL'
require('fs').writeFileSync(process.env.CLAUDE_POSTINSTALL_MARKER, 'ran\n');
CLAUDE_POSTINSTALL
  cat >"${claude_package}/package.json" <<'CLAUDE_PACKAGE'
{
  "version": "2.1.263",
  "optionalDependencies": {
    "@anthropic-ai/claude-code-linux-x64": "2.1.263",
    "@anthropic-ai/claude-code-linux-arm64": "2.1.263",
    "@anthropic-ai/claude-code-linux-x64-musl": "2.1.263",
    "@anthropic-ai/claude-code-linux-arm64-musl": "2.1.263"
  }
}
CLAUDE_PACKAGE
  cat >"${codex_package}/package.json" <<'CODEX_PACKAGE'
{
  "version": "0.153.4",
  "optionalDependencies": {
    "@openai/codex-linux-x64": "npm:@openai/codex@0.153.4-linux-x64",
    "@openai/codex-linux-arm64": "npm:@openai/codex@0.153.4-linux-arm64"
  }
}
CODEX_PACKAGE
  cat >"${fake_npm}" <<'FAKE_NPM'
#!/usr/bin/env bash
set -Eeuo pipefail
count=$(($(cat "${NPM_TEST_COUNT}" 2>/dev/null || printf 0) + 1))
printf '%s\n' "${count}" >"${NPM_TEST_COUNT}"
printf '%s\n' "CALL ${count}" >>"${NPM_TEST_ARGS}"
printf '%s\n' "$@" >>"${NPM_TEST_ARGS}"
if [[ "${NPM_TEST_FAIL_PHASE:-}" == primary && "${*}" == *'@openai/codex@latest'* ]]; then
  exit 7
fi
if [[ "${*}" != *'@openai/codex@latest'* ]]; then
  [[ "${NPM_TEST_FAIL_PHASE:-}" != fallback ]] || exit 8
  for spec in "$@"; do
    case "${spec}" in
      @anthropic-ai/claude-code-linux-*@*)
        package_name=${spec%@*}
        package_version=${spec##*@}
        mkdir -p "${NPM_TEST_PREFIX}/lib/node_modules/${package_name}"
        printf '{"version":"%s"}\n' "${package_version}" \
          >"${NPM_TEST_PREFIX}/lib/node_modules/${package_name}/package.json"
        ;;
      @openai/codex-linux-*@npm:*)
        package_name=${spec%%@npm:*}
        package_version=${spec##*@}
        mkdir -p "${NPM_TEST_PREFIX}/lib/node_modules/${package_name}"
        printf '{"version":"%s"}\n' "${package_version}" \
          >"${NPM_TEST_PREFIX}/lib/node_modules/${package_name}/package.json"
        ;;
    esac
  done
fi
FAKE_NPM
  chmod 700 "${fake_npm}"
  export NPM_TEST_ARGS="${args_file}" NPM_TEST_COUNT="${npm_count_file}"
  export NPM_TEST_PREFIX="${NODE_INSTALL_DIR}" CLAUDE_POSTINSTALL_MARKER="${postinstall_marker}"
  export NPM_TEST_FAIL_PHASE=''
  install_cli_packages >/dev/null
  npm_args=$(<"${args_file}")
  grep -Fq -- '--include=optional' <<<"${npm_args}" ||
    fail "npm install includes platform optional dependencies"
  grep -Fq -- '--allow-scripts=@anthropic-ai/claude-code,better-sqlite3' <<<"${npm_args}" ||
    fail "npm install allows native package scripts"
  grep -Fq '@openai/codex@latest' <<<"${npm_args}" || fail "npm installs Codex"
  [[ -f "${postinstall_marker}" ]] || fail "Claude native postinstall runs"

  resolved_platform=$(node_platform)
  case "${resolved_platform}" in
    linux-x64) architecture=x64 ;;
    linux-arm64) architecture=arm64 ;;
    *) fail "unexpected native test platform: ${resolved_platform}" ;;
  esac
  [[ "$(node_libc_variant)" != musl ]] || claude_suffix=-musl
  claude_native="@anthropic-ai/claude-code-linux-${architecture}${claude_suffix}"
  codex_native="@openai/codex-linux-${architecture}"
  claude_spec=$(package_optional_dependency_spec \
    "${claude_package}/package.json" "${claude_native}")
  codex_spec=$(package_optional_dependency_spec \
    "${codex_package}/package.json" "${codex_native}")
  grep -Fq "${claude_native}@${claude_spec}" <<<"${npm_args}" ||
    fail "npm repairs the exact Claude native package"
  grep -Fq "${codex_native}@${codex_spec}" <<<"${npm_args}" ||
    fail "npm repairs the exact Codex native package"

  printf '%s\n' '{"version":"0.0.0-stale"}' \
    >"${NODE_INSTALL_DIR}/lib/node_modules/${claude_native}/package.json"
  printf '%s\n' '{"version":"0.0.0-stale"}' \
    >"${NODE_INSTALL_DIR}/lib/node_modules/${codex_native}/package.json"
  : >"${args_file}"
  : >"${npm_count_file}"
  NPM_TEST_FAIL_PHASE=fallback
  export NPM_TEST_FAIL_PHASE
  if install_cli_packages >/dev/null 2>&1; then
    fail "native package repair failure must propagate"
  fi

  NPM_TEST_FAIL_PHASE=primary
  export NPM_TEST_FAIL_PHASE
  if install_cli_packages >/dev/null 2>&1; then
    fail "primary npm failure must propagate"
  fi
  unset NPM_TEST_ARGS NPM_TEST_COUNT NPM_TEST_PREFIX \
    CLAUDE_POSTINSTALL_MARKER NPM_TEST_FAIL_PHASE
  pass "CLI install command, native package repair, and postinstall"
}

test_cli_version_validation() {
  local ccr_package output
  ccr_package=$(ccr_package_dir "${NODE_INSTALL_DIR}")
  mkdir -p "${NODE_INSTALL_DIR}/bin" "${ccr_package}"
  [[ -n "${REAL_NODE_BIN}" ]] || fail "real Node.js is required for CLI validation tests"
  rm -f -- "${NODE_INSTALL_DIR}/bin/node"
  printf '#!/usr/bin/env bash\nexec %q "$@"\n' "${REAL_NODE_BIN}" \
    >"${NODE_INSTALL_DIR}/bin/node"
  chmod 700 "${NODE_INSTALL_DIR}/bin/node"
  printf '%s\n' '{"version":"test-ccr"}' >"${ccr_package}/package.json"
  cat >"${NODE_INSTALL_DIR}/bin/claude" <<'FAKE_CLAUDE_VERSION'
#!/usr/bin/env bash
[[ "${CLI_VERSION_FAIL:-}" != claude ]] || exit 9
printf '%s\n' '2.1.263 (Claude Code)'
FAKE_CLAUDE_VERSION
  cat >"${NODE_INSTALL_DIR}/bin/codex" <<'FAKE_CODEX_VERSION'
#!/usr/bin/env bash
[[ "${CLI_VERSION_FAIL:-}" != codex ]] || exit 10
printf '%s\n' 'codex-cli 0.153.4'
FAKE_CODEX_VERSION
  cat >"${NODE_INSTALL_DIR}/bin/ccr" <<'FAKE_CCR_VERSION'
#!/usr/bin/env bash
exit 0
FAKE_CCR_VERSION
  [[ -x "${NODE_INSTALL_DIR}/bin/npm" ]] || fail "CLI validation fixture is missing npm"
  chmod 700 "${NODE_INSTALL_DIR}/bin/claude" \
    "${NODE_INSTALL_DIR}/bin/codex" "${NODE_INSTALL_DIR}/bin/ccr"

  output=$(validate_tools_installation 2>&1) || fail "valid CLI versions were rejected"
  grep -Fq 'Installed 2.1.263 (Claude Code)' <<<"${output}" ||
    fail "Claude version was not reported"
  grep -Fq 'Installed codex-cli 0.153.4' <<<"${output}" ||
    fail "Codex version was not reported"

  if output=$(CLI_VERSION_FAIL=claude validate_tools_installation 2>&1); then
    fail "broken Claude installation must stop validation"
  fi
  grep -Fq 'Claude Code installation is unusable' <<<"${output}" ||
    fail "broken Claude installation has no actionable error"
  if output=$(CLI_VERSION_FAIL=codex validate_tools_installation 2>&1); then
    fail "broken Codex installation must stop validation"
  fi
  grep -Fq 'Codex installation is unusable' <<<"${output}" ||
    fail "broken Codex installation has no actionable error"
  unset CLI_VERSION_FAIL
  pass "CLI startup validation blocks unusable native installations"
}

test_better_sqlite_rebuild() {
  local ccr_package marker npm_args
  ccr_package=$(ccr_package_dir "${NODE_INSTALL_DIR}")
  marker="${TEST_ROOT}/better-sqlite-rebuilt"
  npm_args="${TEST_ROOT}/better-sqlite-npm-args"
  mkdir -p "${ccr_package}/node_modules/better-sqlite3" "${NODE_INSTALL_DIR}/bin"
  cat >"${NODE_INSTALL_DIR}/bin/node" <<'FAKE_SQLITE_NODE'
#!/usr/bin/env bash
if [[ "${*}" == *'better-sqlite3'* && ! -f "${BETTER_SQLITE_MARKER}" ]]; then
  exit 1
fi
exit 0
FAKE_SQLITE_NODE
  cat >"${NODE_INSTALL_DIR}/bin/npm" <<'FAKE_SQLITE_NPM'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${BETTER_SQLITE_NPM_ARGS}"
touch "${BETTER_SQLITE_MARKER}"
FAKE_SQLITE_NPM
  chmod 700 "${NODE_INSTALL_DIR}/bin/node" "${NODE_INSTALL_DIR}/bin/npm"
  export BETTER_SQLITE_MARKER="${marker}" BETTER_SQLITE_NPM_ARGS="${npm_args}"
  ensure_better_sqlite
  grep -Fxq 'rebuild' "${npm_args}" || fail "better-sqlite3 rebuild command"
  [[ -f "${marker}" ]] || fail "better-sqlite3 rebuild marker"
  unset BETTER_SQLITE_MARKER BETTER_SQLITE_NPM_ARGS
  pass "better-sqlite3 recovery"
}

test_ccr_provider_catalog_validation() {
  local response runtime_config
  response='{"data":[{"id":"火山AI网关/deepseek-v4-pro"},{"id":"蓝区百炼/qwen-max"},"BlackAI GPT/gpt-5.6-sol",{"id":"BlackAI Claude/claude-sonnet-4-6"},{"id":"京东网关/GPT-5.6-Sol-joybuilder"}]}'
  runtime_config='{"value":{"Providers":[{"id":"volcano-ai-gateway","name":"火山AI网关","type":"openai_chat_completions","models":["deepseek-v4-pro"]},{"id":"bailian","name":"蓝区百炼","type":"openai_chat_completions","models":["qwen-max"]},{"id":"blackai-gpt","name":"BlackAI GPT","type":"openai_responses","models":["gpt-5.6-sol"]},{"id":"blackai-claude","name":"BlackAI Claude","type":"openai_chat_completions","models":["claude-sonnet-4-6"]},{"id":"jd","name":"京东网关","type":"openai_chat_completions","models":["GPT-5.6-Sol-joybuilder"]}]}}'
  ccr_models_include_provider_catalog "${response}" '火山AI网关' '["deepseek-v4-pro"]' ||
    fail "CCR runtime validation rejected Volcano models"
  ccr_models_include_provider_catalog "${response}" '蓝区百炼' '["qwen-max"]' ||
    fail "CCR runtime validation rejected Bailian models"
  ccr_models_include_provider_catalog "${response}" 'BlackAI GPT' '["gpt-5.6-sol"]' ||
    fail "CCR runtime validation rejected BlackAI GPT models"
  ccr_models_include_provider_catalog "${response}" 'BlackAI Claude' '["claude-sonnet-4-6"]' ||
    fail "CCR runtime validation rejected BlackAI Claude models"
  ccr_models_include_provider_catalog "${response}" '京东网关' '["GPT-5.6-Sol-joybuilder"]' ||
    fail "CCR runtime validation rejected JD models"
  ccr_config_includes_provider_catalog "${runtime_config}" 'volcano-ai-gateway'     '火山AI网关' 'openai_chat_completions' '["deepseek-v4-pro"]' ||
    fail "CCR provider validation rejected the canonical Volcano provider"
  ccr_config_includes_provider_catalog "${runtime_config}" 'jd'     '京东网关' 'openai_chat_completions' '["GPT-5.6-Sol-joybuilder"]' ||
    fail "CCR provider validation rejected the canonical JD provider"
  if ccr_config_includes_provider_catalog "${runtime_config}" 'jd'       'JD LLM Gateway' 'openai_chat_completions' '["GPT-5.6-Sol-joybuilder"]'; then
    fail "CCR provider validation accepted a display-name/catalog mismatch"
  fi
  if ccr_models_include_provider_catalog "${response}" '京东网关' \
      '["GPT-5.6-Sol-joybuilder","GPT-6-Astra-joybuilder"]'; then
    fail "CCR runtime validation accepted a missing JD model"
  fi
  pass "CCR runtime catalog validation covers all five gateways"
}

test_ccr_connection_helpers() {
  local generated
  mkdir -p "${CCR_DIR}"
  printf '%s\n' '{"url":"http://127.0.0.1:3461/?ccr_web_token=test-web-token","pid":123}' >"${CCR_SERVICE_FILE}"
  load_ccr_connection
  assert_eq 'http://127.0.0.1:3461' "${CCR_MANAGEMENT_URL}" "CCR management URL parsing"
  assert_eq 'test-web-token' "${CCR_WEB_TOKEN}" "CCR web token parsing"
  assert_eq 'old-key' "$(resolve_ccr_local_key '{"value":{"APIKEY":"old-key"}}')" \
    "preserve CCR local key"
  generated=$(resolve_ccr_local_key '{"value":{}}')
  [[ "${generated}" =~ ^[0-9a-f]{64}$ ]] || fail "generate CCR local key"
  pass "CCR connection helpers"
}

test_ccr_rpc_error() {
  if (require_ccr_rpc_success '{"ok":false,"error":{"message":"bad config"}}' \
      'fallback error' >/dev/null 2>&1); then
    fail "CCR RPC failure must fail"
  fi
  pass "CCR RPC error handling"
}

test_completion_hint() {
  local output
  CONFIGURE_GATEWAYS=0
  output=$(print_completion_hints)
  grep -Fq "source ${AGENT_ENV_FILE}" <<<"${output}" ||
    fail "completion environment hint"
  CONFIGURE_GATEWAYS=1
  VOLCANO_MODELS='[]'
  BAILIAN_MODELS='[]'
  BLACKAI_GPT_MODELS='["gpt-5.6-sol"]'
  BLACKAI_CLAUDE_MODELS='[]'
  output=$(print_completion_hints)
  grep -Fq 'codex --profile blackai-gpt' <<<"${output}" ||
    fail "completion configured profile hint"
  ! grep -Fq 'codex --profile volcano' <<<"${output}" ||
    fail "completion excludes unavailable profiles"
  pass "completion environment hint"
}

require_command jq
test_agent_layout
test_codex_resume_uses_original_profile
test_setup_user_ownership
test_runtime_environment_path_idempotence
test_bash_startup_configuration
test_operation_manual
test_node_platform
test_codex_wrapper_preserves_runtime_path
test_codex_profiles
test_codex_model_catalog
test_gateway_model_parser
test_token_model_discovery
test_model_discovery_failures
test_volcano_model_probe
test_volcano_probe_failure
test_claude_settings_builder
test_ccr_config_builder
test_ccr_config_from_empty_state
test_ccr_config_idempotence
test_stale_profile_cleanup
test_secure_file_permissions
test_gateway_key_round_trip
test_persisted_jd_gateway_recovery
test_service_pid_reader
test_rolling_port_selection
test_agent_file_collision
test_agent_path_validation
test_argument_parsing
test_dry_run_is_non_destructive
test_node_version_guard
test_dnf_metadata_recovery
test_cli_install_command
test_cli_version_validation
test_better_sqlite_rebuild
test_ccr_provider_catalog_validation
test_ccr_connection_helpers
test_ccr_rpc_error
test_completion_hint
test_codex_install_smoke

printf '1..%d\n' "${TEST_COUNT}"
