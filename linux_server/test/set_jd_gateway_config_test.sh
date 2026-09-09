#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_PATH="$(cd -- "${TEST_DIR}/.." && pwd -P)/set_jd_gateway_config.sh"
TEST_ROOT=$(mktemp -d "${TEST_DIR}/.jd-setup-test.XXXXXXXX")
readonly TEST_TOKEN='jd token with spaces $ and a single quote: '\'''
TEST_COUNT=0

cleanup() {
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup EXIT

pass() {
  TEST_COUNT=$((TEST_COUNT + 1))
  printf 'ok %d - %s\n' "${TEST_COUNT}" "$1"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

assert_file_mode() {
  local expected=$1
  local path=$2
  [[ -f "${path}" ]] || fail "missing file: ${path}"
  [[ "$(stat -c '%a' "${path}")" == "${expected}" ]] ||
    fail "unexpected mode for ${path}"
}

make_fake_codex() {
  local bin_dir=$1
  mkdir -p "${bin_dir}"
  cat >"${bin_dir}/codex" <<'FAKE_CODEX'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == debug && "${2:-}" == models && "${3:-}" == --bundled ]]; then
  printf '%s\n' '{"models":[{"slug":"base","display_name":"Base","context_window":128000}]}'
  exit 0
fi
printf 'unexpected fake Codex arguments:' >&2
printf ' %q' "$@" >&2
printf '\n' >&2
exit 2
FAKE_CODEX
  chmod 700 "${bin_dir}/codex"
  cat >"${bin_dir}/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
printf '%s\n' "$@"
FAKE_CLAUDE
  chmod 700 "${bin_dir}/claude"
}

test_default_merge() {
  local install_root="${TEST_ROOT}/installed"
  local claude_dir="${install_root}/claude"
  local codex_dir="${install_root}/codex"
  local user_home="${install_root}/home"
  local fake_bin="${install_root}/bin"
  local output saved_token launcher_output runtime_settings
  local replacement_token='replacement JD token from environment'
  mkdir -p "${claude_dir}" "${codex_dir}" "${user_home}"
  make_fake_codex "${fake_bin}"

  cat >"${claude_dir}/settings.json" <<'JSON'
{
  "env": {
    "ANTHROPIC_AUTH_TOKEN": "old-local-key",
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:3456",
    "ANTHROPIC_API_BASE_URL": "http://127.0.0.1:3456",
    "CLAUDE_AGENT_API_BASE_URL": "http://127.0.0.1:3456",
    "ANTHROPIC_MODEL": "claude-sonnet-4-6",
    "USER_ENV": "keep"
  },
  "permissions": {"defaultMode": "plan", "deny": ["Read(./private/**)"]},
  "language": "English",
  "customField": {"keep": true}
}
JSON
  cp "${claude_dir}/settings.json" "${install_root}/original-claude-settings.json"
  cat >"${codex_dir}/config.toml" <<'TOML'
model = "existing-model"
[custom]
keep = true
TOML
  printf '%s\n' 'model = "GPT-5.6-Sol-joybuilder"' >"${codex_dir}/jd.config.toml"
  cp "${codex_dir}/config.toml" "${install_root}/original-config.toml"
  printf '%s\n' '# existing shell configuration' >"${user_home}/.bashrc"

  output=$(printf '%s\n' "${TEST_TOKEN}" | env -u JD_GATEWAY_TOKEN \
    PATH="${fake_bin}:/usr/bin:/bin" \
    HOME="${user_home}" \
    CLAUDE_CONFIG_DIR="${claude_dir}" \
    CODEX_HOME="${codex_dir}" \
    bash "${SCRIPT_PATH}" --no-probe 2>&1)

  [[ "${output}" != *"${TEST_TOKEN}"* ]] || fail 'token leaked to installer output'
  cmp "${install_root}/original-config.toml" \
    <(head -c "$(stat -c '%s' "${install_root}/original-config.toml")" "${codex_dir}/config.toml") \
    >/dev/null || fail 'existing Codex defaults changed while registering JD provider'
  assert_file_mode 600 "${codex_dir}/jd.config.toml"
  assert_file_mode 600 "${codex_dir}/catalogs/jd.json"
  [[ ! -e "${codex_dir}/jd.env" ]] || fail 'JD token was saved in a separate jd.env file'
  [[ ! -e "${claude_dir}/jd.settings.json" ]] || fail 'a separate Claude JD settings file was generated'
  [[ -x "${user_home}/.local/bin/claude-jd" ]] || fail 'Claude JD launcher was not generated'
  cmp "${install_root}/original-claude-settings.json" "${claude_dir}/settings.json" >/dev/null ||
    fail 'existing Claude settings.json changed'

  grep -Fq 'model_provider = "jd"' "${codex_dir}/jd.config.toml" ||
    fail 'JD profile provider is missing'
  grep -Fq 'model = "GPT-5.6-Sol-joybuilder"' "${codex_dir}/jd.config.toml" ||
    fail 'JD profile did not preserve the existing default model'
  grep -Fq 'env_key = "JD_GATEWAY_TOKEN"' "${codex_dir}/jd.config.toml" ||
    fail 'JD profile does not reference the token environment variable'
  grep -Fq 'wire_api = "responses"' "${codex_dir}/jd.config.toml" ||
    fail 'JD profile does not select the Responses API'
  grep -Fq 'approval_policy = "never"' "${codex_dir}/jd.config.toml" ||
    fail 'JD profile does not use the Volcano approval policy'
  grep -Fq 'sandbox_mode = "danger-full-access"' "${codex_dir}/jd.config.toml" ||
    fail 'JD profile does not use the Volcano sandbox mode'
  grep -Fq 'models = ["GPT-5.6-Terra-joybuilder", "GPT-5.6-Sol-joybuilder"]' \
    "${codex_dir}/jd.config.toml" || fail 'JD profile model list is missing'
  [[ "$(grep -Fxc '[model_providers.jd]' "${codex_dir}/config.toml")" -eq 1 ]] ||
    fail 'Codex main config does not contain exactly one JD provider registration'
  grep -Fq 'env_key = "JD_GATEWAY_TOKEN"' "${codex_dir}/config.toml" ||
    fail 'Codex main config JD provider does not use the shared environment token'
  ! grep -Fq "${TEST_TOKEN}" "${codex_dir}/config.toml" ||
    fail 'Codex main config contains the JD token'
  ! grep -Fq 'theme = ' "${codex_dir}/jd.config.toml" ||
    fail 'JD profile overrides the Codex theme instead of inheriting the Volcano background'
  ! grep -Fq "${TEST_TOKEN}" "${codex_dir}/jd.config.toml" ||
    fail 'JD profile contains the token inline'

  grep -Fq '# BEGIN JD gateway token' "${user_home}/.bashrc" ||
    fail 'shell startup does not load the JD token'
  grep -Fq 'export JD_GATEWAY_TOKEN=' "${user_home}/.bashrc" ||
    fail 'shell startup does not contain the JD token export'

  saved_token=$(env -u JD_GATEWAY_TOKEN /usr/bin/bash --noprofile --norc -c \
    'source "$1"; printf "%s" "$JD_GATEWAY_TOKEN"' bash "${user_home}/.bashrc")
  [[ "${saved_token}" == "${TEST_TOKEN}" ]] || fail 'saved token did not round-trip'
  launcher_output=$(env -u JD_GATEWAY_TOKEN /usr/bin/bash --noprofile --norc -c \
    'source "$1"; "$2" marker' bash "${user_home}/.bashrc" "${user_home}/.local/bin/claude-jd")
  runtime_settings=$(sed -n '2p' <<<"${launcher_output}")
  [[ "$(sed -n '1p' <<<"${launcher_output}")" == '--settings' &&
     "$(sed -n '3p' <<<"${launcher_output}")" == '--permission-mode' &&
     "$(sed -n '4p' <<<"${launcher_output}")" == 'bypassPermissions' &&
     "$(sed -n '5p' <<<"${launcher_output}")" == 'marker' ]] ||
    fail 'claude-jd did not pass the JD runtime settings and permission mode'
  jq -e '
    .env.ANTHROPIC_BASE_URL == "http://llm-gw.jd.local/anthropic"
    and .permissions.defaultMode == "bypassPermissions"
    and (.env | has("ANTHROPIC_AUTH_TOKEN") | not)
  ' <<<"${runtime_settings}" >/dev/null || fail 'claude-jd runtime settings are invalid'
  [[ "${launcher_output}" != *"${TEST_TOKEN}"* ]] || fail 'claude-jd arguments contain the token'

  # A non-interactive rerun can reuse the managed shell block.
  cp "${user_home}/.bashrc" "${install_root}/first-bashrc"
  cp "${codex_dir}/config.toml" "${install_root}/first-config.toml"
  env -u JD_GATEWAY_TOKEN \
    PATH="${fake_bin}:/usr/bin:/bin" \
    HOME="${user_home}" \
    CLAUDE_CONFIG_DIR="${claude_dir}" \
    CODEX_HOME="${codex_dir}" \
    bash "${SCRIPT_PATH}" --no-probe </dev/null >/dev/null 2>&1
  [[ "$(grep -Fxc '# BEGIN JD gateway token' "${user_home}/.bashrc")" -eq 1 ]] ||
    fail 'rerun duplicated the shell startup block'
  [[ "$(grep -Fxc '# BEGIN JD gateway provider' "${codex_dir}/config.toml")" -eq 1 ]] ||
    fail 'rerun duplicated the Codex JD provider registration'
  cmp "${install_root}/first-bashrc" "${user_home}/.bashrc" >/dev/null ||
    fail 'rerun changed shell startup bytes while reusing the same token'
  cmp "${install_root}/first-config.toml" "${codex_dir}/config.toml" >/dev/null ||
    fail 'rerun changed Codex main config bytes'
  [[ -z "$(find "${user_home}" -maxdepth 1 -name '.jd-source.*' -print -quit)" ]] ||
    fail 'shell startup update left temporary files behind'
  cmp "${install_root}/original-claude-settings.json" "${claude_dir}/settings.json" >/dev/null ||
    fail 'rerun changed the existing Claude settings.json'

  # A token explicitly supplied in the process environment must replace the
  # saved value instead of being shadowed by it.
  JD_GATEWAY_TOKEN="${replacement_token}" \
    PATH="${fake_bin}:/usr/bin:/bin" \
    HOME="${user_home}" \
    CLAUDE_CONFIG_DIR="${claude_dir}" \
    CODEX_HOME="${codex_dir}" \
    bash "${SCRIPT_PATH}" --no-probe </dev/null >/dev/null 2>&1
  saved_token=$(env -u JD_GATEWAY_TOKEN /usr/bin/bash --noprofile --norc -c \
    'source "$1"; printf "%s" "$JD_GATEWAY_TOKEN"' bash "${user_home}/.bashrc")
  [[ "${saved_token}" == "${replacement_token}" ]] ||
    fail 'explicit JD_GATEWAY_TOKEN did not replace the saved token'

  pass 'default append preserves existing defaults and registers JD for session resume'
}

test_manual_provider_cleanup() {
  local install_root="${TEST_ROOT}/manual-provider"
  local codex_dir="${install_root}/codex"
  local user_home="${install_root}/home"
  local fake_bin="${install_root}/bin"
  mkdir -p "${codex_dir}" "${user_home}"
  make_fake_codex "${fake_bin}"
  cat >"${codex_dir}/config.toml" <<'TOML'
model = "existing-model"

# BEGIN JD gateway provider
[model_providers.jd]
name = "obsolete managed provider"
# END JD gateway provider

[model_providers.jd]
name = "manually maintained provider"
base_url = "http://manual.jd.local/v1"
wire_api = "responses"
env_key = "JD_GATEWAY_TOKEN"
TOML

  JD_GATEWAY_TOKEN="${TEST_TOKEN}" \
    PATH="${fake_bin}:/usr/bin:/bin" \
    HOME="${user_home}" \
    CODEX_HOME="${codex_dir}" \
    bash "${SCRIPT_PATH}" --codex-only --no-probe >/dev/null 2>&1

  [[ "$(grep -Fxc '[model_providers.jd]' "${codex_dir}/config.toml")" -eq 1 ]] ||
    fail 'manual JD provider cleanup left duplicate TOML tables'
  ! grep -Fq '# BEGIN JD gateway provider' "${codex_dir}/config.toml" ||
    fail 'obsolete managed provider block was not removed'
  grep -Fq 'name = "manually maintained provider"' "${codex_dir}/config.toml" ||
    fail 'manual JD provider was not preserved'
  pass 'manual JD provider replaces obsolete managed registration cleanly'
}

test_dry_run() {
  local output_root="${TEST_ROOT}/dry-run"
  local fake_bin="${TEST_ROOT}/dry-bin"
  local output
  make_fake_codex "${fake_bin}"
  output=$(printf '%s\n' "${TEST_TOKEN}" | env -u JD_GATEWAY_TOKEN -u CLAUDE_CONFIG_DIR -u CODEX_HOME \
    PATH="${fake_bin}:/usr/bin:/bin" HOME="${TEST_ROOT}/dry-home" \
    bash "${SCRIPT_PATH}" --no-probe --dry-run --output-dir "${output_root}" 2>&1)
  [[ ! -e "${output_root}" ]] || fail 'dry-run created files or directories'
  [[ "${output}" != *"${TEST_TOKEN}"* ]] || fail 'dry-run printed the token'
  pass 'dry-run is non-destructive and redacts credentials'
}

test_agent_dir_discovery() {
  local agent_dir="${TEST_ROOT}/agent with spaces"
  local user_home="${TEST_ROOT}/export/home/test-user"
  local fake_bin="${TEST_ROOT}/agent-bin"
  local loaded_token launcher_output
  mkdir -p "${agent_dir}/bin" "${agent_dir}/config/claude" "${agent_dir}/config/codex" "${user_home}"
  printf '%s\n' 'export EXISTING_SETTING=keep' >"${agent_dir}/env.sh"
  cat >"${agent_dir}/config/codex/gateways.env" <<'LEGACY_ENV'
export EXISTING_GATEWAY_KEY=keep
# BEGIN JD gateway token
[[ -r "/old/jd.env" ]] && source "/old/jd.env"
# END JD gateway token
LEGACY_ENV
  printf '%s\n' '{"env":{"ANTHROPIC_BASE_URL":"http://127.0.0.1:3456"}}' \
    >"${agent_dir}/config/claude/settings.json"
  cat >"${agent_dir}/bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
printf '%s\n' "$@"
FAKE_CLAUDE
  chmod 755 "${agent_dir}/bin/claude"
  make_fake_codex "${fake_bin}"

  printf '%s\n' "${TEST_TOKEN}" | env -u JD_GATEWAY_TOKEN -u CLAUDE_CONFIG_DIR -u CODEX_HOME \
    PATH="${fake_bin}:/usr/bin:/bin" HOME="${user_home}" AI_SETUP_AGENT_DIR="${agent_dir}" \
    bash "${SCRIPT_PATH}" --no-probe >/dev/null 2>&1

  [[ -f "${agent_dir}/config/codex/jd.config.toml" ]] ||
    fail 'AI_SETUP_AGENT_DIR Codex profile was not discovered'
  [[ ! -e "${agent_dir}/config/claude/jd.settings.json" ]] ||
    fail 'AI_SETUP_AGENT_DIR generated a separate Claude settings file'
  [[ -x "${agent_dir}/bin/claude-jd" ]] ||
    fail 'AI_SETUP_AGENT_DIR Claude JD launcher was not generated'
  grep -Fq 'http://127.0.0.1:3456' "${agent_dir}/config/claude/settings.json" ||
    fail 'Claude JD setup replaced the existing CCR route'
  [[ ! -e "${agent_dir}/config/codex/jd.env" ]] ||
    fail 'AI_SETUP_AGENT_DIR generated a separate token file'
  ! grep -Fq '# BEGIN JD gateway token' "${agent_dir}/config/codex/gateways.env" ||
    fail 'legacy JD loader was not removed from gateways.env'
  grep -Fq 'export EXISTING_GATEWAY_KEY=keep' "${agent_dir}/config/codex/gateways.env" ||
    fail 'cleaning the legacy JD loader changed other gateway variables'
  grep -Fq '# BEGIN JD gateway token' "${agent_dir}/env.sh" ||
    fail 'AI_SETUP_AGENT_DIR environment was not updated'
  loaded_token=$(env -u JD_GATEWAY_TOKEN /usr/bin/bash --noprofile --norc -c \
    'source "$1"; printf "%s" "$JD_GATEWAY_TOKEN"' bash "${agent_dir}/env.sh")
  [[ "${loaded_token}" == "${TEST_TOKEN}" ]] ||
    fail 'shell-escaped agent path or token did not round-trip'
  launcher_output=$("${agent_dir}/bin/claude-jd" marker)
  [[ "$(sed -n '1p' <<<"${launcher_output}")" == '--settings' &&
     "$(sed -n '3p' <<<"${launcher_output}")" == '--permission-mode' &&
     "$(sed -n '4p' <<<"${launcher_output}")" == 'bypassPermissions' &&
     "$(sed -n '5p' <<<"${launcher_output}")" == 'marker' ]] ||
    fail 'claude-jd did not load the JD runtime configuration'
  jq -e '.env.ANTHROPIC_BASE_URL == "http://llm-gw.jd.local/anthropic"' \
    <<<"$(sed -n '2p' <<<"${launcher_output}")" >/dev/null ||
    fail 'claude-jd runtime configuration does not select JD'
  pass 'custom agent directory is discovered and shell paths are escaped'
}

test_probe_failure_is_non_destructive() {
  local output_root="${TEST_ROOT}/probe-failure"
  local fake_bin="${TEST_ROOT}/probe-bin"
  local output
  make_fake_codex "${fake_bin}"
  cat >"${fake_bin}/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
printf '401'
FAKE_CURL
  chmod 700 "${fake_bin}/curl"

  if output=$(printf '%s\n' "${TEST_TOKEN}" | env -u JD_GATEWAY_TOKEN -u CLAUDE_CONFIG_DIR -u CODEX_HOME \
      PATH="${fake_bin}:/usr/bin:/bin" HOME="${TEST_ROOT}/probe-home" \
      bash "${SCRIPT_PATH}" --output-dir "${output_root}" 2>&1); then
    fail 'all-failed model probe unexpectedly succeeded'
  fi
  [[ ! -e "${output_root}" ]] || fail 'failed model probe modified the output directory'
  [[ "${output}" != *"${TEST_TOKEN}"* ]] || fail 'failed model probe leaked the token'
  pass 'failed model probes stop before changing configuration'
}

test_partial_model_availability() {
  local output_root="${TEST_ROOT}/partial-models"
  local fake_bin="${TEST_ROOT}/partial-bin"
  local launcher_output runtime_settings
  make_fake_codex "${fake_bin}"
  cat >"${fake_bin}/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
for argument in "$@"; do
  case "${argument}" in
    *claude-sonnet-5*|*GPT-5.6-Terra-joybuilder*) printf '200'; exit 0 ;;
  esac
done
printf '404'
FAKE_CURL
  chmod 700 "${fake_bin}/curl"

  printf '%s\n' "${TEST_TOKEN}" | env -u JD_GATEWAY_TOKEN -u CLAUDE_CONFIG_DIR -u CODEX_HOME \
    PATH="${fake_bin}:/usr/bin:/bin" HOME="${TEST_ROOT}/partial-home" \
    bash "${SCRIPT_PATH}" --output-dir "${output_root}" >/dev/null 2>&1

  launcher_output=$(JD_GATEWAY_TOKEN="${TEST_TOKEN}" "${output_root}/claude-jd")
  runtime_settings=$(sed -n '2p' <<<"${launcher_output}")
  jq -e '
    .env.ANTHROPIC_DEFAULT_OPUS_MODEL == "claude-sonnet-5[1m]"
    and .env.ANTHROPIC_DEFAULT_SONNET_MODEL == "claude-sonnet-5[1m]"
    and .fallbackModel == []
    and (.env | has("ANTHROPIC_AUTH_TOKEN") | not)
  ' <<<"${runtime_settings}" >/dev/null ||
    fail 'Claude defaults include a model that failed probing'
  grep -Fq 'model = "GPT-5.6-Terra-joybuilder"' \
    "${output_root}/.codex/jd.config.toml" || fail 'Codex did not select the verified model'
  grep -Fq 'default_subagent_model = "GPT-5.6-Terra-joybuilder"' \
    "${output_root}/.codex/jd.config.toml" ||
    fail 'Codex subagent uses a model that failed probing'
  grep -Fq 'models = ["GPT-5.6-Terra-joybuilder"]' \
    "${output_root}/.codex/jd.config.toml" || fail 'Codex retained an unverified model'
  pass 'partial probe results only configure verified models'
}

test_catalog_failure_is_atomic() {
  local output_root="${TEST_ROOT}/catalog-failure"
  local fake_bin="${TEST_ROOT}/catalog-bin"
  local old_catalog='{"models":[{"slug":"existing"}]}'
  mkdir -p "${output_root}/.codex/catalogs" "${fake_bin}"
  printf '%s\n' "${old_catalog}" >"${output_root}/.codex/catalogs/jd.json"
  printf '%s\n' 'model = "existing"' >"${output_root}/.codex/jd.config.toml"
  cat >"${fake_bin}/codex" <<'BAD_CODEX'
#!/usr/bin/env bash
printf '%s\n' 'not-json'
BAD_CODEX
  chmod 700 "${fake_bin}/codex"

  if printf '%s\n' "${TEST_TOKEN}" | env -u JD_GATEWAY_TOKEN -u CLAUDE_CONFIG_DIR -u CODEX_HOME \
      PATH="${fake_bin}:/usr/bin:/bin" HOME="${TEST_ROOT}/catalog-home" \
      bash "${SCRIPT_PATH}" --codex-only --no-probe --output-dir "${output_root}" \
      >/dev/null 2>&1; then
    fail 'invalid bundled catalog unexpectedly succeeded'
  fi
  [[ "$(<"${output_root}/.codex/catalogs/jd.json")" == "${old_catalog}" ]] ||
    fail 'catalog generation failure replaced the existing catalog'
  grep -Fqx 'model = "existing"' "${output_root}/.codex/jd.config.toml" ||
    fail 'catalog generation failure replaced the existing profile'
  [[ -z "$(find "${output_root}/.codex" -maxdepth 1 -name '.jd-catalog.*' -print -quit)" ]] ||
    fail 'catalog generation failure left a temporary directory'
  pass 'catalog replacement is atomic on generation failure'
}

test_inline_token_toml_escaping() {
  local output_root="${TEST_ROOT}/inline-token"
  local fake_bin="${TEST_ROOT}/inline-bin"
  local inline_token=$'quote " slash \\ tab\t newline\nend'
  local parsed
  make_fake_codex "${fake_bin}"
  env -u JD_GATEWAY_TOKEN -u CLAUDE_CONFIG_DIR -u CODEX_HOME \
    PATH="${fake_bin}:/usr/bin:/bin" HOME="${TEST_ROOT}/inline-home" \
    bash "${SCRIPT_PATH}" --codex-only --no-probe --inline-token \
      --output-dir "${output_root}" --token "${inline_token}" >/dev/null 2>&1
  parsed=$(python3 - "${output_root}/.codex/jd.config.toml" <<'PY'
import pathlib
import sys
import tomllib
config = tomllib.loads(pathlib.Path(sys.argv[1]).read_text())
print(config["model_providers"]["jd"]["http_headers"]["Authorization"], end="")
PY
  )
  [[ "${parsed}" == "Bearer ${inline_token}" ]] || fail 'inline token TOML escaping failed'
  pass 'inline token is escaped as valid TOML'
}

test_mode_validation() {
  if bash "${SCRIPT_PATH}" --standalone --merge >/dev/null 2>&1; then
    fail '--standalone and --merge were accepted together'
  fi
  if bash "${SCRIPT_PATH}" --claude-only --codex-only >/dev/null 2>&1; then
    fail '--claude-only and --codex-only were accepted together'
  fi
  pass 'conflicting modes are rejected'
}

command -v jq >/dev/null 2>&1 || fail 'jq is required for the test'
test_default_merge
test_manual_provider_cleanup
test_dry_run
test_agent_dir_discovery
test_probe_failure_is_non_destructive
test_partial_model_availability
test_catalog_failure_is_atomic
test_inline_token_toml_escaping
test_mode_validation
printf '1..%d\n' "${TEST_COUNT}"
