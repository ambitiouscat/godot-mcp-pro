#!/usr/bin/env bash
# Linux/WSL copied-addon native verification. Run this inside WSL, never from
# Git Bash: the Godot process and its bundled child are intentionally given an
# empty PATH so a host Node/Bun/npm installation cannot satisfy the payload.
set -euo pipefail

timeout_seconds="${TIMEOUT_SECONDS:-210}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
godot="${GODOT:-/mnt/e/Code/godot/godot_work/bin/godot.linuxbsd.editor.x86_64}"
addon_source="$repo_root/godot-mcp-pro/addons/opencode_godot"
opencode_source="${OPENCODE_BINARY:-$repo_root/opencode/packages/opencode/dist/opencode-linux-x64-baseline/bin/opencode}"
opencode_package="${OPENCODE_PACKAGE:-$(dirname "$(dirname "$opencode_source")")/package.json}"
sidecar_source="${SIDECAR_BINARY:-$repo_root/server/dist/wsl-linux-glibc-x64/linux-glibc-x64/godot-mcp-pro}"
sidecar_manifest="${SIDECAR_MANIFEST:-$repo_root/server/dist/wsl-linux-glibc-x64/manifest.json}"
fixture="$(mktemp -d /tmp/opencode-godot-linux-native-e2e.XXXXXX)"
provider_pid=""
godot_pid=""

die() { printf 'OPENCODE_GODOT_LINUX_NATIVE_COPIED_ADDON_E2E_FAIL: %s\n' "$*" >&2; exit 1; }
require_file() { [[ -f "$1" ]] || die "missing required file: $1"; }
sha() { sha256sum "$1" | awk '{print $1}'; }
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

cleanup() {
  local status=$?
  if [[ -n "$godot_pid" ]] && kill -0 "$godot_pid" 2>/dev/null; then kill "$godot_pid" 2>/dev/null || true; wait "$godot_pid" 2>/dev/null || true; fi
  if [[ -n "$provider_pid" ]] && kill -0 "$provider_pid" 2>/dev/null; then kill "$provider_pid" 2>/dev/null || true; wait "$provider_pid" 2>/dev/null || true; fi
  # Fixture ownership is passed through GODOT_PROJECT_PATH to every managed
  # child. Kill only processes carrying that exact environment value.
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

[[ "$(uname -s)" == "Linux" ]] || die 'run this wrapper inside Linux/WSL'
[[ "$(uname -m)" == "x86_64" ]] || die "requires x86_64, found $(uname -m)"
require_file "$godot"
require_file "$opencode_source"
require_file "$opencode_package"
require_file "$sidecar_source"
require_file "$sidecar_manifest"
require_file "$addon_source/payload-manifest.json"
require_file "$addon_source/runtime/opencode-plugins/godot-tools.js"
require_file "$addon_source/runtime/opencode-plugins/godot-tools.manifest.json"
[[ "$(file -Lb "$godot")" == *'ELF 64-bit'* ]] || die "Godot is not a Linux x86_64 ELF: $godot"
[[ "$($godot --version)" == 4.* ]] || die 'Godot did not report a 4.x version'

declare -A source_hash
for source in "$addon_source/payload-manifest.json" "$addon_source/runtime/opencode-plugins/godot-tools.js" "$addon_source/runtime/opencode-plugins/godot-tools.manifest.json" "$opencode_source" "$opencode_package" "$sidecar_source" "$sidecar_manifest"; do
  source_hash["$source"]="$(sha "$source")"
done

cp -a "$addon_source" "$fixture/addons"
mv "$fixture/addons" "$fixture/addons-opencode_godot"
mkdir -p "$fixture/addons" "$fixture/tests" "$fixture/home" "$fixture/xdg/config" "$fixture/xdg/data" "$fixture/xdg/cache" "$fixture/system-bin"
mv "$fixture/addons-opencode_godot" "$fixture/addons/opencode_godot"
cp "$repo_root/godot-mcp-pro/tests/fixture/project.godot" "$fixture/project.godot"
sed -i 's|enabled=PackedStringArray("res://addons/godot_mcp/plugin.cfg")|enabled=PackedStringArray()|' "$fixture/project.godot"
cp "$repo_root/godot-mcp-pro/tests/fixture/tests/opencode_linux_native_e2e_runner.gd" "$fixture/tests/"
cp "$repo_root/godot-mcp-pro/tests/fixture/tests/opencode_native_e2e_test_lifecycle.gd" "$fixture/tests/"
cp "$repo_root/godot-mcp-pro/tests/fixture/tests/opencode_e2e_test_editor_plugin.gd" "$fixture/tests/"
cp "$repo_root/godot-mcp-pro/tests/mock_openai_tool_server.mjs" "$fixture/tests/"
mkdir -p "$fixture/addons/opencode_godot/bin/linux-x86_64-glibc"
cp "$opencode_source" "$fixture/addons/opencode_godot/bin/linux-x86_64-glibc/opencode"
cp "$sidecar_source" "$fixture/addons/opencode_godot/bin/linux-x86_64-glibc/godot-mcp"
chmod 0755 "$fixture/addons/opencode_godot/bin/linux-x86_64-glibc/opencode" "$fixture/addons/opencode_godot/bin/linux-x86_64-glibc/godot-mcp"

# Update only the copied manifest with native artifact identity.  The source
# manifest remains untouched and intentionally retains its release payloads.
node - "$fixture/addons/opencode_godot/payload-manifest.json" "$opencode_package" "$sidecar_manifest" "$fixture/addons/opencode_godot/bin/linux-x86_64-glibc/opencode" "$fixture/addons/opencode_godot/bin/linux-x86_64-glibc/godot-mcp" <<'NODE'
const fs = require('fs');
const crypto = require('crypto');
const [manifestPath, openPackagePath, sidecarManifestPath, opencodePath, sidecarPath] = process.argv.slice(2);
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
const op = JSON.parse(fs.readFileSync(openPackagePath, 'utf8'));
const sidecars = JSON.parse(fs.readFileSync(sidecarManifestPath, 'utf8'));
const sidecar = sidecars.artifacts.find((value) => value.tuple === 'linux-glibc-x64');
if (!sidecar) throw new Error('linux-glibc-x64 sidecar metadata is absent');
const entry = (path, version, source_fingerprint, build_fingerprint, signature) => ({
  path, sha256: `sha256:${crypto.createHash('sha256').update(fs.readFileSync(path === 'bin/linux-x86_64-glibc/opencode' ? opencodePath : sidecarPath)).digest('hex')}`,
  size_bytes: fs.statSync(path === 'bin/linux-x86_64-glibc/opencode' ? opencodePath : sidecarPath).size,
  mode: '0755', signature, version, artifact_version: version, version_verified: true,
  source_fingerprint, build_fingerprint, status: signature.status,
});
manifest.payloads['linux-x86_64-glibc'] = {
  opencode: entry('bin/linux-x86_64-glibc/opencode', op.version, op.opencode_source_fingerprint, op.opencode_build_fingerprint, {status: 'unverified', scheme: 'none', required_from_release_environment: true}),
  mcp: entry('bin/linux-x86_64-glibc/godot-mcp', sidecar.version, sidecar.source_fingerprint, sidecar.build_fingerprint, sidecar.signature),
};
fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2));
NODE

ready_file="$fixture/mock-openai.ready.json"
result_file="$fixture/native-result.json"
ready_phase_file="$fixture/native-ready.json"
node "$fixture/tests/mock_openai_tool_server.mjs" "$ready_file" --require-complex-schema >"$fixture/provider.out" 2>"$fixture/provider.err" &
provider_pid=$!
for _ in $(seq 1 200); do [[ -s "$ready_file" ]] && break; kill -0 "$provider_pid" 2>/dev/null || die "mock provider exited: $(cat "$fixture/provider.err")"; sleep 0.05; done
[[ -s "$ready_file" ]] || die 'mock provider did not become ready'
provider_url="$(node -pe "JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8')).base_url" "$ready_file")"

ln -s /usr/bin/getconf "$fixture/system-bin/getconf"
# getconf is the sole production helper required by the Linux PID-start-time
# verifier.  Do not add a general system directory here: node, bun, and npm
# must remain unresolvable to Godot, OpenCode, and any of their children.
restricted_env=(env -i "HOME=$fixture/home" "TMPDIR=$fixture/tmp" "XDG_CONFIG_HOME=$fixture/xdg/config" "XDG_DATA_HOME=$fixture/xdg/data" "XDG_CACHE_HOME=$fixture/xdg/cache" "PATH=$fixture/system-bin" "GODOT_MCP_SESSION_FILE=$fixture/.bridge-session/bridge-session.json" "GODOT_PROJECT_PATH=$fixture" "GODOT_MCP_E2E_PROVIDER_BASE_URL=$provider_url" "GODOT_LINUX_NATIVE_E2E_RESULT_PATH=$result_file" "GODOT_LINUX_NATIVE_E2E_READY_PATH=$ready_phase_file")
mkdir -p "$fixture/tmp"
"${restricted_env[@]}" "$godot" --headless --path "$fixture" --check-only --script res://tests/opencode_linux_native_e2e_runner.gd >"$fixture/check.out" 2>"$fixture/check.err" || { cat "$fixture/check.out" "$fixture/check.err"; die 'Godot check-only failed'; }
if grep -Eqi 'SCRIPT ERROR|Parse Error|Failed to load script' "$fixture/check.out" "$fixture/check.err"; then cat "$fixture/check.out" "$fixture/check.err"; die 'Godot check-only reported a parse/load error'; fi

"${restricted_env[@]}" "$godot" --headless --editor --path "$fixture" --script res://tests/opencode_linux_native_e2e_runner.gd >"$fixture/godot.out" 2>"$fixture/godot.err" &
godot_pid=$!
for _ in $(seq 1 $((timeout_seconds * 10))); do
  [[ -s "$ready_phase_file" ]] && break
  kill -0 "$godot_pid" 2>/dev/null || { cat "$fixture/godot.out" "$fixture/godot.err"; die 'Godot exited before native bridge READY'; }
  sleep 0.1
done
[[ -s "$ready_phase_file" ]] || die "Godot did not reach native READY within ${timeout_seconds}s"
if grep -Rzl -- "GODOT_PROJECT_PATH=$fixture" /proc/[0-9]*/environ 2>/dev/null | while read -r env_file; do tr '\0' ' ' < "$env_file" 2>/dev/null | grep -q 'godot-mcp' && exit 1 || true; done; then :; else die 'native phase started a forbidden godot-mcp child'; fi
set +e
wait "$godot_pid"
godot_exit=$?
set -e
godot_pid=""
cat "$fixture/godot.out" "$fixture/godot.err"
if grep -Eqi 'SCRIPT ERROR|TEST FAILURE|Failed to load script|Parse Error' "$fixture/godot.out" "$fixture/godot.err"; then
  die 'Godot reported a script or test failure'
fi
grep -q 'OPENCODE_GODOT_LINUX_NATIVE_COPIED_ADDON_E2E_OK' "$fixture/godot.out" || die 'success marker missing'
node - "$result_file" <<'NODE'
const result = JSON.parse(require('fs').readFileSync(process.argv[2], 'utf8'));
if (!result.ok) throw new Error(`runner failures: ${(result.failures || []).join('; ')}`);
for (const key of ['session_removed', 'discovery_removed', 'mcp_ownership_absent']) if (!result.cleanup?.[key]) throw new Error(`cleanup attestation missing: ${key}`);
if (result.integration_mode !== 'native') throw new Error(`unexpected mode: ${result.integration_mode}`);
NODE
grep -q 'complex_schema=true' "$ready_file.requests.log" || die 'provider did not observe godot_set_input_action complex schema'
for _ in $(seq 1 50); do
  if [[ -z "$(fixture_payload_processes)" ]]; then break; fi
  sleep 0.1
done
leaked_payload_processes="$(fixture_payload_processes)"
[[ -z "$leaked_payload_processes" ]] || die "fixture-owned payload process leaked: $leaked_payload_processes"
for source in "${!source_hash[@]}"; do [[ "${source_hash[$source]}" == "$(sha "$source")" ]] || die "source payload changed during test: $source"; done
if [[ "$godot_exit" -ne 0 ]]; then
  # All functional success, cleanup, provider-schema, and source-integrity
  # gates passed. Accept only the exact Godot 4.3 shutdown signature; NUL
  # warnings, arbitrary nonzero exits, and unknown ERROR lines remain errors.
  plain_log="$fixture/godot.plain.log"
  sed -E $'s/\x1b\\[[0-?]*[ -/]*[@-~]//g' "$fixture/godot.out" "$fixture/godot.err" >"$plain_log"
  version_count="$(grep -Fxc 'Godot Engine v4.3.stable.official.77dcf97d8 - https://godotengine.org' "$plain_log" || true)"
  canvas_count="$(grep -Ec '^WARNING: [0-9]+ RIDs? of type "Canvas" were leaked\.$' "$plain_log" || true)"
  canvas_item_count="$(grep -Ec '^WARNING: [0-9]+ RIDs? of type "CanvasItem" were leaked\.$' "$plain_log" || true)"
  object_db_count="$(grep -Ec '^WARNING: ObjectDB instances leaked at exit' "$plain_log" || true)"
  error_count="$(grep -Ec '^ERROR:' "$plain_log" || true)"
  unexpected_errors="$(grep -E '^ERROR:' "$plain_log" | grep -Ev "^ERROR: [0-9]+ RID allocations of type '.+' were leaked at exit\\.$" || true)"
  if [[ "$version_count" != 1 || "$canvas_count" -lt 1 || "$canvas_item_count" -lt 1 || "$object_db_count" -lt 1 || "$error_count" -lt 1 || -n "$unexpected_errors" ]]; then
    die "Godot failed with exit $godot_exit outside the exact accepted 4.3 shutdown-leak signature"
  fi
  printf 'OPENCODE_GODOT_LINUX_NATIVE_ACCEPTED_GODOT_4_3_SHUTDOWN_SIGNATURE\n'
fi
node - "$fixture/addons/opencode_godot/payload-manifest.json" <<'NODE'
const manifest = JSON.parse(require('fs').readFileSync(process.argv[2], 'utf8'));
const e = manifest.payloads['linux-x86_64-glibc'];
console.log(`OPENCODE_GODOT_LINUX_NATIVE_TUPLE tuple=linux-x86_64-glibc opencode=${e.opencode.version} opencode_sha256=${e.opencode.sha256} opencode_build=${e.opencode.build_fingerprint} mcp=${e.mcp.version} mcp_sha256=${e.mcp.sha256} mcp_build=${e.mcp.build_fingerprint}`);
NODE
printf 'OPENCODE_GODOT_LINUX_NATIVE_COPIED_ADDON_E2E_OK\n'
