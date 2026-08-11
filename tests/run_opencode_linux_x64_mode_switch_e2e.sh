#!/usr/bin/env bash
# Linux/WSL copied-addon native -> MCP handoff verification.  Run inside WSL,
# never Git Bash: Godot and every payload child get a deliberately restricted
# PATH, so a host Node/Bun/npm cannot satisfy the packaged payload.
set -euo pipefail

timeout_seconds="${TIMEOUT_SECONDS:-240}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
godot="${GODOT:-/mnt/e/Code/godot/godot_work/bin/godot.linuxbsd.editor.x86_64}"
addon_root_input="${ADDON_ROOT:-$repo_root/godot-mcp-pro/addons/opencode_godot}"
if [[ -d "$addon_root_input/addons/opencode_godot" ]]; then
  addon_source="$addon_root_input/addons/opencode_godot"
else
  addon_source="$addon_root_input"
fi
payload_dir="${PAYLOAD_DIR:-$addon_source/bin/linux-x86_64-glibc}"
opencode_source="${OPENCODE_BINARY:-$payload_dir/opencode}"
sidecar_source="${SIDECAR_BINARY:-$payload_dir/godot-mcp}"
manifest_source="${PAYLOAD_MANIFEST:-$addon_source/payload-manifest.json}"
fixture="$(mktemp -d /tmp/opencode-godot-linux-mode-switch-e2e.XXXXXX)"
provider_pid=""
godot_pid=""

die() { printf 'OPENCODE_GODOT_LINUX_MODE_SWITCH_E2E_FAIL: %s\n' "$*" >&2; exit 1; }
require_file() { [[ -f "$1" ]] || die "missing required file: $1"; }
sha() { sha256sum "$1" | awk '{print $1}'; }
canonical_path() { readlink -f -- "$1"; }

# Every managed payload child receives this exact project path.  This keeps
# leak cleanup and detection fixture-scoped even if unrelated payloads run on
# the same machine.
fixture_payload_processes() {
  local env_file pid env_text cmdline state
  for env_file in /proc/[0-9]*/environ; do
    pid="${env_file#/proc/}"; pid="${pid%/environ}"
    env_text="$(tr '\0' '\n' 2>/dev/null < "$env_file" || true)"
    grep -Fqx "GODOT_PROJECT_PATH=$fixture" <<<"$env_text" || continue
    cmdline="$(tr '\0' ' ' 2>/dev/null < "/proc/$pid/cmdline" || true)"
    state="$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)"
    if [[ "$cmdline" =~ (^|[[:space:]/])(opencode|godot-mcp)([[:space:]]|$) && "$state" != Z ]]; then
      printf 'PID=%s STATE=%s CMD=%s\n' "$pid" "$state" "$cmdline"
    fi
  done
}

fixture_sidecars() { fixture_payload_processes | grep -E '(^|[[:space:]/])godot-mcp([[:space:]]|$)' || true; }

cleanup() {
  local status=$?
  if [[ -n "$godot_pid" ]] && kill -0 "$godot_pid" 2>/dev/null; then kill "$godot_pid" 2>/dev/null || true; wait "$godot_pid" 2>/dev/null || true; fi
  if [[ -n "$provider_pid" ]] && kill -0 "$provider_pid" 2>/dev/null; then kill "$provider_pid" 2>/dev/null || true; wait "$provider_pid" 2>/dev/null || true; fi
  local env_file pid env_text
  for env_file in /proc/[0-9]*/environ; do
    pid="${env_file#/proc/}"; pid="${pid%/environ}"
    env_text="$(tr '\0' '\n' 2>/dev/null < "$env_file" || true)"
    if grep -Fqx "GODOT_PROJECT_PATH=$fixture" <<<"$env_text"; then kill "$pid" 2>/dev/null || true; fi
  done
  rm -rf -- "$fixture"
  exit "$status"
}
trap cleanup EXIT INT TERM

[[ "$(uname -s)" == Linux ]] || die 'run this wrapper inside Linux/WSL'
[[ "$(uname -m)" == x86_64 ]] || die "requires x86_64, found $(uname -m)"
require_file "$godot"
require_file "$addon_source/payload-manifest.json"
require_file "$manifest_source"
require_file "$addon_source/runtime/opencode-plugins/godot-tools.js"
require_file "$addon_source/runtime/opencode-plugins/godot-tools.manifest.json"
require_file "$opencode_source"
require_file "$sidecar_source"
require_file "$repo_root/godot-mcp-pro/tests/fixture/tests/opencode_integration_mode_switch_e2e_runner.gd"
[[ "$(file -Lb "$godot")" == *'ELF 64-bit'* ]] || die "Godot is not a Linux x86_64 ELF: $godot"
godot_version="$($godot --version)"
[[ "$godot_version" == '4.3.stable.official.77dcf97d8' ]] || die "requires official Godot 4.3.stable.official.77dcf97d8, found: $godot_version"

declare -A source_hash
for source in "$addon_source/payload-manifest.json" "$manifest_source" "$addon_source/runtime/opencode-plugins/godot-tools.js" "$addon_source/runtime/opencode-plugins/godot-tools.manifest.json" "$opencode_source" "$sidecar_source"; do
  source_hash["$source"]="$(sha "$source")"
done

mkdir -p "$fixture/addons" "$fixture/tests" "$fixture/home" "$fixture/tmp" "$fixture/xdg/config" "$fixture/xdg/data" "$fixture/xdg/cache" "$fixture/system-bin"
cp -a "$addon_source" "$fixture/addons/opencode_godot"
cp "$manifest_source" "$fixture/addons/opencode_godot/payload-manifest.json"
mkdir -p "$fixture/addons/opencode_godot/bin/linux-x86_64-glibc"
cp "$opencode_source" "$fixture/addons/opencode_godot/bin/linux-x86_64-glibc/opencode"
cp "$sidecar_source" "$fixture/addons/opencode_godot/bin/linux-x86_64-glibc/godot-mcp"
chmod 0755 "$fixture/addons/opencode_godot/bin/linux-x86_64-glibc/opencode" "$fixture/addons/opencode_godot/bin/linux-x86_64-glibc/godot-mcp"

# Overrides are copied into the fixture only.  Preserve pinned version/source
# metadata and refresh the two locally verifiable artifact fields, so a caller
# can provide alternate Linux payload files without mutating their source
# addon or requiring them to contain a matching release manifest.
node - "$fixture/addons/opencode_godot/payload-manifest.json" "$fixture/addons/opencode_godot/bin/linux-x86_64-glibc/opencode" "$fixture/addons/opencode_godot/bin/linux-x86_64-glibc/godot-mcp" <<'NODE'
const fs = require('fs');
const crypto = require('crypto');
const [manifestPath, opencodePath, sidecarPath] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
const payload = manifest.payloads?.['linux-x86_64-glibc'];
if (!payload?.opencode || !payload?.mcp) throw new Error('linux-x86_64-glibc manifest entry is absent');
for (const [entry, artifact] of [[payload.opencode, opencodePath], [payload.mcp, sidecarPath]]) {
  entry.sha256 = `sha256:${crypto.createHash('sha256').update(fs.readFileSync(artifact)).digest('hex')}`;
  entry.size_bytes = fs.statSync(artifact).size;
  entry.mode = '0755';
}
fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2));
NODE

cp "$repo_root/godot-mcp-pro/tests/fixture/project.godot" "$fixture/project.godot"
sed -i 's|enabled=PackedStringArray("res://addons/godot_mcp/plugin.cfg")|enabled=PackedStringArray()|' "$fixture/project.godot"
for runner_file in opencode_integration_mode_switch_e2e_runner.gd opencode_e2e_test_lifecycle.gd opencode_e2e_test_editor_plugin.gd; do
  cp "$repo_root/godot-mcp-pro/tests/fixture/tests/$runner_file" "$fixture/tests/"
done
cp "$repo_root/godot-mcp-pro/tests/mock_openai_tool_server.mjs" "$fixture/tests/"

ready_file="$fixture/mock-openai.ready.json"
event_file="$fixture/mode-switch-event.json"
continue_file="$fixture/continue-native-switch"
result_file="$fixture/mode-switch-result.json"
node "$fixture/tests/mock_openai_tool_server.mjs" "$ready_file" --require-complex-schema >"$fixture/provider.out" 2>"$fixture/provider.err" &
provider_pid=$!
for _ in $(seq 1 200); do
  [[ -s "$ready_file" ]] && break
  kill -0 "$provider_pid" 2>/dev/null || die "mock provider exited: $(cat "$fixture/provider.err")"
  sleep 0.05
done
[[ -s "$ready_file" ]] || die 'mock provider did not become ready'
provider_url="$(node -pe "JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8')).base_url" "$ready_file")"

ln -s "$(command -v getconf)" "$fixture/system-bin/getconf"
restricted_env=(env -i "HOME=$fixture/home" "TMPDIR=$fixture/tmp" "XDG_CONFIG_HOME=$fixture/xdg/config" "XDG_DATA_HOME=$fixture/xdg/data" "XDG_CACHE_HOME=$fixture/xdg/cache" "PATH=$fixture/system-bin" "GODOT_PROJECT_PATH=$fixture" "GODOT_MCP_SESSION_FILE=$fixture/.bridge-session/bridge-session.json" "GODOT_MCP_E2E_PROVIDER_BASE_URL=$provider_url" "GODOT_MODE_SWITCH_EVENT_PATH=$event_file" "GODOT_MODE_SWITCH_CONTINUE_PATH=$continue_file" "GODOT_MODE_SWITCH_RESULT_PATH=$result_file")
"${restricted_env[@]}" /usr/bin/bash -c '! command -v node && ! command -v bun && ! command -v npm' || die 'restricted Godot/OpenCode PATH resolved node, bun, or npm'

"${restricted_env[@]}" "$godot" --headless --path "$fixture" --check-only --script res://tests/opencode_integration_mode_switch_e2e_runner.gd >"$fixture/check.out" 2>"$fixture/check.err" || { cat "$fixture/check.out" "$fixture/check.err"; die 'Godot check-only failed'; }
if grep -Eqi 'SCRIPT ERROR|Parse Error|Failed to load script' "$fixture/check.out" "$fixture/check.err"; then cat "$fixture/check.out" "$fixture/check.err"; die 'Godot check-only reported a parse/load error'; fi

"${restricted_env[@]}" "$godot" --headless --editor --path "$fixture" --script res://tests/opencode_integration_mode_switch_e2e_runner.gd >"$fixture/godot.out" 2>"$fixture/godot.err" &
godot_pid=$!
native_observed=false
mcp_observed=false
for _ in $(seq 1 $((timeout_seconds * 10))); do
  if [[ -s "$event_file" ]]; then
    phase="$(node -p "(() => { try { return JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8')).phase || '' } catch { return '' } })()" "$event_file")"
    if [[ "$phase" == native_ready && "$native_observed" == false ]]; then
      native_observed=true
      [[ -z "$(fixture_sidecars)" ]] || die "native phase started a forbidden godot-mcp sidecar: $(fixture_sidecars)"
      printf 'native phase observed\n' >"$continue_file"
    elif [[ "$phase" == mcp_ready ]]; then
      mcp_observed=true
      break
    fi
  fi
  kill -0 "$godot_pid" 2>/dev/null || { cat "$fixture/godot.out" "$fixture/godot.err"; die 'Godot exited before both mode-switch phases were observed'; }
  sleep 0.1
done
[[ "$native_observed" == true ]] || die "Godot did not reach native READY within ${timeout_seconds}s"
[[ "$mcp_observed" == true ]] || die "Godot did not reach MCP READY within ${timeout_seconds}s"

mcp_pid="$(node -p "const e=JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8')); if(e.phase!=='mcp_ready'||!e.launch_nonce||!(+e.sidecar_pid>0)||!(+e.sidecar_started_at_ms>0)||!e.sidecar_executable||!e.ownership_path||!(+e.daemon_pid>0)) process.exit(1); e.sidecar_pid" "$event_file")" || die 'MCP event lacks nonce-bound sidecar identity'
mcp_started_at_ms="$(node -p "JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8')).sidecar_started_at_ms" "$event_file")"
mcp_executable="$(node -p "JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8')).sidecar_executable" "$event_file")"
mcp_ownership_path="$(node -p "JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8')).ownership_path" "$event_file")"
expected_sidecar="$fixture/addons/opencode_godot/bin/linux-x86_64-glibc/godot-mcp"
[[ "$(canonical_path "$mcp_executable")" == "$(canonical_path "$expected_sidecar")" ]] || die "event sidecar executable is not fixture payload: $mcp_executable"
for _ in $(seq 1 50); do kill -0 "$mcp_pid" 2>/dev/null && break; sleep 0.1; done
kill -0 "$mcp_pid" 2>/dev/null || die "nonce-bound MCP sidecar PID $mcp_pid was not live"
[[ "$(canonical_path "/proc/$mcp_pid/exe")" == "$(canonical_path "$expected_sidecar")" ]] || die "live MCP sidecar PID $mcp_pid executable is not fixture payload"
node - "$event_file" "$mcp_ownership_path" "$expected_sidecar" <<'NODE'
const fs = require('fs');
const [eventPath, ownershipPath, expectedSidecar] = process.argv.slice(2);
const event = JSON.parse(fs.readFileSync(eventPath, 'utf8'));
const ownership = JSON.parse(fs.readFileSync(ownershipPath, 'utf8'));
const samePath = (a, b) => require('path').resolve(a) === require('path').resolve(b);
if (ownership.schema !== 'opencode-godot-mcp-ownership' || ownership.schema_version !== 1 ||
    ownership.launch_nonce !== event.launch_nonce || ownership.canonical_project !== event.project ||
    ownership?.opencode_parent?.pid !== event.daemon_pid || ownership?.sidecar?.pid !== event.sidecar_pid ||
    ownership?.sidecar?.started_at_ms !== event.sidecar_started_at_ms || !samePath(ownership?.executable?.path || '', expectedSidecar)) {
  throw new Error('MCP ownership record is not exactly bound to the emitted launch nonce, parent, sidecar, and fixture executable');
}
NODE

set +e
wait "$godot_pid"
godot_exit=$?
set -e
godot_pid=""
cat "$fixture/godot.out" "$fixture/godot.err"
combined_log="$fixture/godot.plain.log"
sed -E $'s/\x1b\\[[0-?]*[ -/]*[@-~]//g' "$fixture/godot.out" "$fixture/godot.err" >"$combined_log"
if grep -Eqi 'SCRIPT ERROR|TEST FAILURE|mode-switch runner failure|Parse Error|Failed to load script' "$combined_log"; then die 'Godot reported a script or test failure'; fi
grep -q 'OPENCODE_GODOT_INTEGRATION_MODE_SWITCH_E2E_OK' "$combined_log" || die 'Godot mode-switch success marker missing'
if [[ "$godot_exit" -ne 0 ]]; then
  version_count="$(grep -Fxc 'Godot Engine v4.3.stable.official.77dcf97d8 - https://godotengine.org' "$combined_log" || true)"
  canvas_count="$(grep -Ec '^WARNING: [0-9]+ RIDs? of type "Canvas" were leaked\.$' "$combined_log" || true)"
  canvas_item_count="$(grep -Ec '^WARNING: [0-9]+ RIDs? of type "CanvasItem" were leaked\.$' "$combined_log" || true)"
  object_db_count="$(grep -Ec '^WARNING: ObjectDB instances leaked at exit' "$combined_log" || true)"
  error_count="$(grep -Ec '^ERROR:' "$combined_log" || true)"
  unexpected_errors="$(grep -E '^ERROR:' "$combined_log" | grep -Ev "^ERROR: [0-9]+ RID allocations of type '.+' were leaked at exit\\.$" || true)"
  if [[ "$godot_exit" != 1 || "$version_count" != 1 || "$canvas_count" -lt 1 || "$canvas_item_count" -lt 1 || "$object_db_count" -lt 1 || "$error_count" -lt 1 || -n "$unexpected_errors" ]]; then
    die "Godot failed with exit $godot_exit outside the exact accepted official Godot 4.3 shutdown-leak signature"
  fi
  printf 'OPENCODE_GODOT_LINUX_MODE_SWITCH_ACCEPTED_GODOT_4_3_SHUTDOWN_SIGNATURE\n'
elif grep -q '^ERROR:' "$combined_log"; then
  die 'Godot emitted ERROR output despite a zero exit'
fi

node - "$result_file" <<'NODE'
const result = JSON.parse(require('fs').readFileSync(process.argv[2], 'utf8'));
if (!result.ok) throw new Error(`runner failures: ${(result.failures || []).join('; ')}`);
NODE
grep -q 'complex_schema=true' "$ready_file.requests.log" || die 'provider did not observe the complex godot_set_input_action schema'
for removed in "$fixture/.bridge-session/bridge-session.json" "$mcp_ownership_path" "$mcp_ownership_path.bak" "$(node -p "JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8')).discovery_path" "$event_file")" "$(node -p "JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8')).token_path" "$event_file")"; do
  [[ ! -e "$removed" ]] || die "owned runtime file survived normal cleanup: $removed"
done
for _ in $(seq 1 50); do [[ -z "$(fixture_payload_processes)" ]] && break; sleep 0.1; done
leaked_payload_processes="$(fixture_payload_processes)"
[[ -z "$leaked_payload_processes" ]] || die "fixture-owned payload process leaked: $leaked_payload_processes"
kill -0 "$mcp_pid" 2>/dev/null && die "saved MCP sidecar PID $mcp_pid (started_at_ms=$mcp_started_at_ms) remained live after cleanup"
for source in "${!source_hash[@]}"; do [[ "${source_hash[$source]}" == "$(sha "$source")" ]] || die "source payload changed during test: $source"; done
printf 'OPENCODE_GODOT_LINUX_X64_MODE_SWITCH_E2E_OK\n'
