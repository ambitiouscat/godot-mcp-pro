#!/usr/bin/env node
/*
 * One-host slice of the copied-addon native -> MCP matrix.  This intentionally
 * has no shell wrapper: GitHub runners can invoke the same file on Windows,
 * macOS, and Linux while the provider retains the normal Node environment and
 * the Godot tree receives a deliberately non-Node PATH.
 */
import { createHash, randomUUID } from "node:crypto"
import { execFileSync, spawn, spawnSync } from "node:child_process"
import fs from "node:fs"
import os from "node:os"
import path from "node:path"
import process from "node:process"
import { fileURLToPath } from "node:url"

const HERE = path.dirname(fileURLToPath(import.meta.url))
const DEFAULT_ADDON = path.resolve(HERE, "../addons/opencode_godot")
// Keep the Windows user:// runtime comfortably below legacy MAX_PATH once a
// project hash and nonce-bound state files are appended.
const FIXTURE_PREFIX = "ocm-"
const TUPLES = new Map([
  ["windows-x64", "windows-x86_64"], ["windows-arm64", "windows-arm64"],
  ["macos-x64", "macos-x86_64"], ["macos-arm64", "macos-arm64"],
  ["linux-glibc-x64", "linux-x86_64-glibc"], ["linux-glibc-arm64", "linux-arm64-glibc"],
])

function usage() {
  console.log(`Usage: node tests/run_opencode_copied_addon_matrix_e2e.mjs --godot <editor> --tuple <tuple> [--addon-root <dir>] [--timeout-seconds <n>] [--report <file>]

Runs one native tuple from the copied-addon E2E matrix. Supported tuples:
  windows-x64, windows-arm64, macos-x64, macos-arm64,
  linux-glibc-x64, linux-glibc-arm64

The Node provider uses the caller PATH. Godot and every managed child receive
a restricted PATH that cannot resolve node, bun, or npm.

Validation-only commands:
  --self-test                 exercise parser, tuple and shutdown-noise gates
  --dry-run --tuple <tuple> --addon-root <dir>
                              validate the signed-in manifest metadata/files
`) }

function parseArgs(values) {
  const result = {}
  const valueOptions = new Set(["godot", "tuple", "addon-root", "timeout-seconds", "report"])
  for (let i = 0; i < values.length; i += 1) {
    const value = values[i]
    if (!value.startsWith("--")) throw new Error(`unexpected argument: ${value}`)
    const key = value.slice(2)
    if (["help", "self-test", "dry-run"].includes(key)) result[key] = true
    else {
      if (!valueOptions.has(key)) throw new Error(`unknown option: --${key}`)
      const next = values[++i]
      if (!next || next.startsWith("--")) throw new Error(`--${key} requires a value`)
      result[key] = next
    }
  }
  return result
}

function fail(message) { throw new Error(`OPENCODE_COPIED_ADDON_MATRIX_E2E_FAIL: ${message}`) }
function sleep(ms) { return new Promise((resolve) => setTimeout(resolve, ms)) }
function exists(file) { return fs.existsSync(file) && fs.statSync(file).isFile() }
function normalize(file) { const normalized = path.resolve(file).replace(/\\/g, "/"); return process.platform === "win32" ? normalized.toLowerCase() : normalized }
function sha256(file) { return `sha256:${createHash("sha256").update(fs.readFileSync(file)).digest("hex")}` }
function isPosix() { return process.platform !== "win32" }

function tuplePlatform(tuple) { return tuple.split("-")[0] }
function assertHostPlatform(tuple) {
  const expected = tuplePlatform(tuple)
  const actual = process.platform === "win32" ? "windows" : process.platform === "darwin" ? "macos" : process.platform
  if (expected !== actual) fail(`tuple ${tuple} cannot run on ${process.platform}`)
  const expectedArch = tuple.includes("x64") ? "x64" : "arm64"
  if (process.arch !== expectedArch) fail(`tuple ${tuple} cannot run with Node architecture ${process.arch}`)
}

function godotArchitectureMatches(tuple, value) {
  const accepted = tuple.includes("x64") ? new Set(["x86_64", "amd64", "x64"]) : new Set(["arm64", "aarch64"])
  return accepted.has(String(value || "").toLowerCase())
}

function payloadPaths(addon, tuple, manifest) {
  const payload = manifest.payloads?.[tuple]
  if (!payload?.opencode || !payload?.mcp) fail(`payload manifest has no complete ${tuple} entry`)
  return { payload, opencode: path.resolve(addon, payload.opencode.path), mcp: path.resolve(addon, payload.mcp.path) }
}

function verifyPayload(addon, tuple) {
  const manifestPath = path.join(addon, "payload-manifest.json")
  if (!exists(manifestPath)) fail(`missing payload manifest: ${manifestPath}`)
  let manifest
  try { manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8")) } catch (error) { fail(`invalid payload manifest: ${error.message}`) }
  if (manifest.schema !== "opencode-godot-payload-manifest" || manifest.schema_version !== 1) fail("unsupported payload manifest schema")
  const result = payloadPaths(addon, tuple, manifest)
  const expectedPayloadRoot = fs.realpathSync(path.join(addon, "bin", tuple))
  for (const [name, entry, file] of [["opencode", result.payload.opencode, result.opencode], ["mcp", result.payload.mcp, result.mcp]]) {
    const relative = path.relative(addon, file).replace(/\\/g, "/")
    if (!relative.startsWith("bin/") || relative.startsWith("../")) fail(`${tuple} ${name} path escapes the addon bin directory`)
    if (!exists(file)) fail(`${tuple} ${name} artifact is missing: ${file}`)
    if (fs.lstatSync(file).isSymbolicLink()) fail(`${tuple} ${name} artifact must not be a symlink`)
    const realFile = fs.realpathSync(file)
    if (!normalize(realFile).startsWith(`${normalize(expectedPayloadRoot)}/`)) fail(`${tuple} ${name} symlink escapes the addon tuple directory`)
    if (entry.mode !== "0755") fail(`${tuple} ${name} manifest mode must be 0755, found ${entry.mode}`)
    if (Number(entry.size_bytes) !== fs.statSync(file).size) fail(`${tuple} ${name} manifest size mismatch`)
    if (entry.sha256 !== sha256(file)) fail(`${tuple} ${name} manifest sha256 mismatch`)
    if (isPosix() && (fs.statSync(file).mode & 0o111) !== 0o111) fail(`${tuple} ${name} lacks POSIX execute bits`)
  }
  const pluginPath = path.join(addon, "runtime/opencode-plugins/godot-tools.js")
  const pluginManifestPath = path.join(addon, "runtime/opencode-plugins/godot-tools.manifest.json")
  for (const file of [pluginPath, pluginManifestPath]) {
    if (!exists(file)) fail(`missing packaged OpenCode plugin asset: ${file}`)
    if (fs.lstatSync(file).isSymbolicLink()) fail(`packaged OpenCode plugin asset must not be a symlink: ${file}`)
  }
  let pluginManifest
  try { pluginManifest = JSON.parse(fs.readFileSync(pluginManifestPath, "utf8")) } catch (error) { fail(`invalid native plugin manifest: ${error.message}`) }
  if (pluginManifest.plugin?.path !== "runtime/opencode-plugins/godot-tools.js" || pluginManifest.plugin?.sha256 !== sha256(pluginPath) || Number(pluginManifest.plugin?.size_bytes) !== fs.statSync(pluginPath).size) fail("native plugin manifest does not match packaged godot-tools.js")
  result.nativePlugin = pluginManifest.plugin
  return { manifest, ...result }
}

function snapshotSource(addon, payload) {
  const files = [path.join(addon, "payload-manifest.json"), path.join(addon, "runtime/opencode-plugins/godot-tools.js"), path.join(addon, "runtime/opencode-plugins/godot-tools.manifest.json"), payload.opencode, payload.mcp]
  return new Map(files.map((file) => [file, { size: fs.statSync(file).size, sha: sha256(file) }]))
}
function assertSourceUnchanged(before) {
  for (const [file, expected] of before) {
    if (!exists(file) || fs.statSync(file).size !== expected.size || sha256(file) !== expected.sha) fail(`source payload changed during test: ${file}`)
  }
}

function restrictedPath(fixture) {
  if (process.platform === "win32") return [path.join(process.env.SystemRoot || "C:\\Windows", "System32"), path.join(process.env.SystemRoot || "C:\\Windows", "System32", "WindowsPowerShell", "v1.0")].join(path.delimiter)
  if (process.platform === "darwin") {
    const bin = path.join(fixture, "system-bin"); fs.mkdirSync(bin, { recursive: true })
    for (const name of ["ps", "date"]) {
      const source = ["/bin", "/usr/bin"].map((base) => path.join(base, name)).find((candidate) => exists(candidate))
      if (!source) fail(`macOS restricted PATH needs ${name} for process identity verification`)
      fs.symlinkSync(source, path.join(bin, name))
    }
    return bin
  }
  const bin = path.join(fixture, "system-bin")
  fs.mkdirSync(bin, { recursive: true })
  const getconf = "/usr/bin/getconf"
  if (!exists(getconf)) fail("Linux restricted PATH needs /usr/bin/getconf for PID identity verification")
  fs.symlinkSync(getconf, path.join(bin, "getconf"))
  return bin
}

function commandResolves(name, value) {
  const suffixes = process.platform === "win32" ? (process.env.PATHEXT || ".COM;.EXE;.BAT;.CMD").split(";") : [""]
  for (const dir of value.split(path.delimiter).filter(Boolean)) for (const suffix of suffixes) {
    const candidate = path.join(dir, name + (path.extname(name) ? "" : suffix.toLowerCase()))
    if (fs.existsSync(candidate)) return candidate
  }
  return ""
}
function assertNoHostRuntimes(value) {
  for (const name of ["node", "bun", "npm"]) {
    const resolved = commandResolves(name, value)
    if (resolved) fail(`restricted PATH resolves ${name}: ${resolved}`)
  }
}

function makeManagedEnvironment(fixture, providerUrl, eventPath, continuePath, resultPath) {
  const PATH = restrictedPath(fixture)
  assertNoHostRuntimes(PATH)
  const home = path.join(fixture, "home")
  fs.mkdirSync(home, { recursive: true })
  const env = { ...process.env }
  for (const key of Object.keys(env)) if (/^(node_|npm_|bun_)/i.test(key) || ["NODE_OPTIONS", "NODE_PATH", "BUN_INSTALL"].includes(key)) delete env[key]
  Object.assign(env, { PATH, HOME: home, TMPDIR: path.join(fixture, "tmp"), TEMP: path.join(fixture, "tmp"), TMP: path.join(fixture, "tmp"), XDG_CONFIG_HOME: path.join(fixture, "xdg/config"), XDG_DATA_HOME: path.join(fixture, "xdg/data"), XDG_CACHE_HOME: path.join(fixture, "xdg/cache"), GODOT_PROJECT_PATH: fixture, GODOT_MCP_SESSION_FILE: path.join(fixture, ".bridge-session/bridge-session.json"), GODOT_MCP_E2E_PROVIDER_BASE_URL: providerUrl, GODOT_MODE_SWITCH_EVENT_PATH: eventPath, GODOT_MODE_SWITCH_CONTINUE_PATH: continuePath, GODOT_MODE_SWITCH_RESULT_PATH: resultPath })
  if (process.platform === "win32") Object.assign(env, { SystemRoot: process.env.SystemRoot || "C:\\Windows", WINDIR: process.env.WINDIR || "C:\\Windows", COMSPEC: process.env.COMSPEC || "C:\\Windows\\System32\\cmd.exe", PATHEXT: process.env.PATHEXT || ".COM;.EXE;.BAT;.CMD", USERPROFILE: home, APPDATA: path.join(fixture, "appdata/roaming"), LOCALAPPDATA: path.join(fixture, "appdata/local") })
  for (const directory of [env.TMPDIR, env.XDG_CONFIG_HOME, env.XDG_DATA_HOME, env.XDG_CACHE_HOME, env.APPDATA, env.LOCALAPPDATA].filter(Boolean)) fs.mkdirSync(directory, { recursive: true })
  return env
}

function copyFixture(fixture, addon) {
  fs.mkdirSync(path.join(fixture, "addons"), { recursive: true })
  fs.cpSync(addon, path.join(fixture, "addons/opencode_godot"), { recursive: true, preserveTimestamps: true })
  const project = fs.readFileSync(path.join(HERE, "fixture/project.godot"), "utf8")
    .replace('config/name="Godot MCP Bridge Test"', 'config/name="OpenCode"')
    .replace('enabled=PackedStringArray("res://addons/godot_mcp/plugin.cfg")', "enabled=PackedStringArray()")
  fs.writeFileSync(path.join(fixture, "project.godot"), project)
  fs.mkdirSync(path.join(fixture, "tests"), { recursive: true })
  for (const name of ["opencode_integration_mode_switch_e2e_runner.gd", "opencode_e2e_test_lifecycle.gd", "opencode_e2e_test_editor_plugin.gd"]) fs.copyFileSync(path.join(HERE, "fixture/tests", name), path.join(fixture, "tests", name))
  fs.copyFileSync(path.join(HERE, "mock_openai_tool_server.mjs"), path.join(fixture, "tests/mock_openai_tool_server.mjs"))
}

function readJsonWhenReady(file) { try { return exists(file) ? JSON.parse(fs.readFileSync(file, "utf8")) : null } catch { return null } }
function pidAlive(pid) { try { process.kill(pid, 0); return true } catch { return false } }

function processInfo(pid) {
  if (!Number.isInteger(pid) || pid <= 0 || !pidAlive(pid)) return null
  try {
    if (process.platform === "linux") return { pid, executable: fs.realpathSync(`/proc/${pid}/exe`), command: fs.readFileSync(`/proc/${pid}/cmdline`, "utf8").replaceAll("\0", " ") }
    if (process.platform === "darwin") {
      const executable = execFileSync("ps", ["-p", String(pid), "-o", "comm="], { encoding: "utf8" }).trim()
      const command = execFileSync("ps", ["-p", String(pid), "-o", "command="], { encoding: "utf8" }).trim()
      return executable ? { pid, executable, command } : null
    }
    const command = "Get-Process -Id " + pid + " -ErrorAction SilentlyContinue | Select-Object Id,ProcessName,Path | ConvertTo-Json -Compress"
    const text = execFileSync("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", command], { encoding: "utf8", windowsHide: true }).trim()
    if (!text) return null
    const item = JSON.parse(text)
    return { pid, executable: item.Path || "", command: item.Path || "", name: item.ProcessName || "" }
  } catch { return null }
}

function fixturePayloads(fixture) {
  if (process.platform === "win32") {
    const command = "Get-Process -Name opencode,godot-mcp -ErrorAction SilentlyContinue | Select-Object Id,ProcessName,Path | ConvertTo-Json -Compress"
    let values
    try { values = JSON.parse(execFileSync("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", command], { encoding: "utf8", windowsHide: true })) } catch { return [] }
    return (Array.isArray(values) ? values : [values]).filter((item) => /^(opencode|godot-mcp)$/i.test(item.ProcessName || "") && normalize(item.Path || "").includes(normalize(fixture))).map((item) => ({ pid: Number(item.Id), executable: item.Path || "", command: item.Path || "" }))
  }
  let text = ""
  try { text = execFileSync("ps", ["-axo", "pid=,command="], { encoding: "utf8" }) } catch { return [] }
  return text.split(/\r?\n/).map((line) => { const match = line.trim().match(/^(\d+)\s+(.*)$/); return match && { pid: Number(match[1]), command: match[2] } }).filter(Boolean).filter((item) => /(^|[\s/])(opencode|godot-mcp)(\s|$)/.test(item.command) && normalize(item.command).includes(normalize(fixture)))
}

function assertLiveSidecar(event, fixture, addonTuple) {
  if (!event.launch_nonce || !event.owner_nonce || !Number.isInteger(Number(event.sidecar_pid)) || Number(event.sidecar_started_at_ms) <= 0) fail("mcp_ready lacks a nonce-bound sidecar identity")
  const expected = path.join(fixture, "addons/opencode_godot/bin", addonTuple, process.platform === "win32" ? "godot-mcp.exe" : "godot-mcp")
  if (normalize(event.sidecar_executable || "") !== normalize(expected)) fail(`mcp_ready sidecar executable is not the copied tuple payload: ${event.sidecar_executable}`)
  const info = processInfo(Number(event.sidecar_pid))
  const commandStartsWithPayload = (info?.command || "").replace(/^"/, "").startsWith(expected)
  if (!info || (normalize(info.executable) !== normalize(expected) && !commandStartsWithPayload)) fail(`nonce-bound sidecar ${event.sidecar_pid} is not live from copied payload`)
  return { pid: Number(event.sidecar_pid), startedAt: Number(event.sidecar_started_at_ms), executable: expected }
}

function allowedGodot43Shutdown(exitCode, output) {
  const lines = output.replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "").split(/\r?\n/).map((line) => line.trim()).filter(Boolean)
  const errors = lines.filter((line) => line.startsWith("ERROR:"))
  const rid = /^ERROR: \d+ RID allocations of type '.+' were leaked at exit\.$/
  return exitCode === 1 && lines.filter((line) => line === "Godot Engine v4.3.stable.official.77dcf97d8 - https://godotengine.org").length === 1 && lines.some((line) => /^WARNING: \d+ RIDs? of type "Canvas" were leaked\.$/.test(line)) && lines.some((line) => /^WARNING: \d+ RIDs? of type "CanvasItem" were leaked\.$/.test(line)) && lines.some((line) => /^WARNING: ObjectDB instances leaked at exit/.test(line)) && errors.length > 0 && errors.every((line) => rid.test(line))
}

function startProvider(fixture) {
  const ready = path.join(fixture, "mock-openai.ready.json")
  const child = spawn(process.execPath, [path.join(fixture, "tests/mock_openai_tool_server.mjs"), ready, "--require-complex-schema", "--cycles", "2"], { cwd: fixture, stdio: ["ignore", "pipe", "pipe"] })
  let output = ""; child.stdout.on("data", (data) => { output += data }); child.stderr.on("data", (data) => { output += data })
  return { child, ready, output: () => output }
}
async function waitProvider(provider) {
  for (let i = 0; i < 200; i += 1) {
    const ready = readJsonWhenReady(provider.ready)
    if (ready?.hostname === "127.0.0.1" && Number(ready.port) > 0 && ready.base_url) return ready.base_url
    if (provider.child.exitCode !== null) fail(`provider exited before ready: ${provider.output()}`)
    await sleep(50)
  }
  fail("provider did not become ready")
}
async function stop(child) {
  if (!child || childFinished(child)) return
  try { child.kill("SIGTERM") } catch {}
  await Promise.race([waitForClose(child), sleep(5000)])
  if (!childFinished(child)) {
    try { child.kill("SIGKILL") } catch {}
    await Promise.race([waitForClose(child), sleep(5000)])
  }
  if (!childFinished(child)) fail(`child process ${child.pid || "unknown"} did not exit after bounded termination`)
}
function childFinished(child) { return child.exitCode !== null || child.signalCode !== null }
function waitForClose(child) { return childFinished(child) ? Promise.resolve(child.exitCode) : new Promise((resolve) => child.once("close", (code) => resolve(code))) }
function safeRemoveFixture(fixture) {
  const parent = path.resolve(os.tmpdir()); const target = path.resolve(fixture)
  if (path.dirname(target) !== parent || !path.basename(target).startsWith(FIXTURE_PREFIX)) fail(`refusing unsafe fixture cleanup: ${target}`)
  fs.rmSync(target, { recursive: true, force: true, maxRetries: 3 })
}
function writeReportAtomically(report, evidence) {
  const target = path.resolve(report)
  fs.mkdirSync(path.dirname(target), { recursive: true })
  const temporary = path.join(path.dirname(target), `.${path.basename(target)}.${randomUUID()}.tmp`)
  try {
    fs.writeFileSync(temporary, `${JSON.stringify(evidence, null, 2)}\n`, { encoding: "utf8", mode: 0o600 })
    fs.renameSync(temporary, target)
  } finally {
    if (fs.existsSync(temporary)) fs.rmSync(temporary, { force: true })
  }
}
async function terminateFixturePayloads(fixture) {
  for (const payload of fixturePayloads(fixture)) {
    try { if (process.platform === "win32") spawnSync("taskkill.exe", ["/pid", String(payload.pid), "/t", "/f"], { windowsHide: true }); else process.kill(payload.pid, "SIGTERM") } catch {}
  }
  for (let i = 0; i < 20 && fixturePayloads(fixture).length; i += 1) await sleep(100)
  if (process.platform !== "win32") for (const payload of fixturePayloads(fixture)) { try { process.kill(payload.pid, "SIGKILL") } catch {} }
  for (let i = 0; i < 20 && fixturePayloads(fixture).length; i += 1) await sleep(100)
  if (fixturePayloads(fixture).length) fail("refusing fixture cleanup while fixture-owned payloads remain live")
}

async function run(options) {
  const tuple = options.tuple
  if (!TUPLES.has(tuple)) fail(`unsupported tuple: ${tuple}`)
  assertHostPlatform(tuple)
  const addonTuple = TUPLES.get(tuple)
  const addon = path.resolve(options["addon-root"] || DEFAULT_ADDON)
  const payload = verifyPayload(addon, addonTuple)
  if (options["dry-run"]) { console.log(`OPENCODE_COPIED_ADDON_MATRIX_DRY_RUN_OK tuple=${tuple} addon=${addon}`); return }
  if (!options.godot || !exists(path.resolve(options.godot))) fail("--godot must name an existing Godot editor executable")
  const godot = path.resolve(options.godot)
  const version = execFileSync(godot, ["--version"], { encoding: "utf8" }).trim()
  const versionMatch = version.match(/^4\.(\d+)/)
  if (!versionMatch || Number(versionMatch[1]) < 3) fail(`Godot must be 4.3 or newer, found: ${version}`)
  const sourceBefore = snapshotSource(addon, payload)
  const fixture = path.join(os.tmpdir(), `${FIXTURE_PREFIX}${randomUUID()}`)
  let provider; let godotChild; let sidecar
  try {
    fs.mkdirSync(fixture, { recursive: false }); copyFixture(fixture, addon)
    verifyPayload(path.join(fixture, "addons/opencode_godot"), addonTuple)
    provider = startProvider(fixture)
    const providerUrl = await waitProvider(provider)
    const eventPath = path.join(fixture, "mode-switch-event.json"), continuePath = path.join(fixture, "continue-native-switch"), resultPath = path.join(fixture, "mode-switch-result.json")
    const managedEnv = makeManagedEnvironment(fixture, providerUrl, eventPath, continuePath, resultPath)
    godotChild = spawn(godot, ["--headless", "--editor", "--path", fixture, "--script", "res://tests/opencode_integration_mode_switch_e2e_runner.gd"], { cwd: fixture, env: managedEnv, stdio: ["ignore", "pipe", "pipe"] })
    let output = ""; godotChild.stdout.on("data", (data) => { output += data }); godotChild.stderr.on("data", (data) => { output += data })
    const timeout = Number(options["timeout-seconds"] || 240) * 1000; const started = Date.now(); let native; let mcp
    while (godotChild.exitCode === null && Date.now() - started < timeout) {
      const event = readJsonWhenReady(eventPath)
      if (event?.phase === "native_ready" && !native) {
        native = event
        if (fixturePayloads(fixture).some((item) => /godot-mcp/i.test(item.executable || item.command))) fail("native phase started a forbidden MCP sidecar")
        fs.writeFileSync(continuePath, "native phase observed")
      }
      if (event?.phase === "mcp_ready" && !mcp) { mcp = event; sidecar = assertLiveSidecar(event, fixture, addonTuple) }
      await sleep(75)
    }
    if (godotChild.exitCode === null) fail(`mode-switch E2E exceeded ${timeout / 1000} seconds`)
    const exitCode = await waitForClose(godotChild)
    if (!output.includes("OPENCODE_GODOT_INTEGRATION_MODE_SWITCH_E2E_OK")) fail(`Godot success marker missing:\n${output}`)
    if (/SCRIPT ERROR|TEST FAILURE|mode-switch runner failure/i.test(output)) fail(`Godot runner reported script/test failure:\n${output}`)
    if (exitCode !== 0 && !allowedGodot43Shutdown(exitCode, output)) fail(`Godot exited ${exitCode} outside the exact accepted Godot 4.3 shutdown RID-leak signature:\n${output}`)
    const result = readJsonWhenReady(resultPath)
    if (!result?.ok) fail(`runner result failed: ${(result?.failures || []).join("; ")}`)
    if (!native || !mcp || !sidecar || native.owner_nonce === mcp.owner_nonce || !mcp.launch_nonce || native.tool_call_completed !== true || result.tool_calls?.native !== true || result.tool_calls?.mcp !== true) fail("did not observe distinct native/MCP ownership generations with native and MCP tool calls plus a live sidecar")
    if (result.host?.path !== managedEnv.PATH) fail("runner host metadata did not retain the restricted PATH")
    if (!godotArchitectureMatches(tuple, result.host?.architecture)) fail(`runner architecture does not match ${tuple}: ${result.host?.architecture}`)
    const log = path.join(fixture, "mock-openai.ready.json.requests.log")
    if (!exists(log) || !fs.readFileSync(log, "utf8").includes("complex_schema=true")) fail("provider did not receive packaged complex tool schema")
    for (let i = 0; i < 50 && fixturePayloads(fixture).length; i += 1) await sleep(100)
    if (fixturePayloads(fixture).length) fail("fixture-owned payload process leaked after cleanup")
    if (pidAlive(sidecar.pid)) fail(`saved MCP sidecar PID ${sidecar.pid} remained live after cleanup`)
    assertSourceUnchanged(sourceBefore)
    if (options.report) {
      const entry = (name) => ({ version: payload.payload[name].version, sha256: payload.payload[name].sha256, size_bytes: payload.payload[name].size_bytes, mode: payload.payload[name].mode, source_fingerprint: payload.payload[name].source_fingerprint, build_fingerprint: payload.payload[name].build_fingerprint })
      const nativePlugin = path.join(addon, "runtime/opencode-plugins/godot-tools.js")
      writeReportAtomically(options.report, {
        schema: "opencode-godot-copied-addon-smoke",
        schema_version: 1,
        status: "passed",
        tuple,
        addon_tuple: addonTuple,
        host: { platform: tuplePlatform(tuple), architecture: tuple.includes("x64") ? "x64" : "arm64", godot_os: result.host?.os || "", godot_architecture: result.host?.architecture || "" },
        godot: { version },
        artifacts: { opencode: entry("opencode"), mcp: entry("mcp"), native_plugin: { sha256: sha256(nativePlugin), size_bytes: fs.statSync(nativePlugin).size, version: payload.nativePlugin.version, source_fingerprint: payload.nativePlugin.source_fingerprint, build_fingerprint: payload.nativePlugin.build_fingerprint } },
        checks: {
          manifest_integrity: true, permissions: true, runtime_path_isolated: true,
          native_tool_call: true, mcp_tool_call: true, native_no_mcp_child: true,
          mcp_sidecar_identity: true, complex_schema: true, cleanup: true, source_immutable: true,
        },
      })
    }
    console.log(`OPENCODE_GODOT_COPIED_ADDON_MATRIX_E2E_OK tuple=${tuple}${options.report ? ` report=${path.resolve(options.report)}` : ""}`)
  } finally {
    await stop(godotChild)
    await terminateFixturePayloads(fixture)
    await stop(provider?.child)
    assertSourceUnchanged(sourceBefore)
    if (fs.existsSync(fixture)) safeRemoveFixture(fixture)
  }
}

function selfTest() {
  if (!TUPLES.has("linux-glibc-arm64") || tuplePlatform("macos-arm64") !== "macos") throw new Error("tuple self-test failed")
  if (!godotArchitectureMatches("windows-x64", "x86_64") || !godotArchitectureMatches("linux-glibc-arm64", "aarch64") || godotArchitectureMatches("windows-x64", "") || godotArchitectureMatches("macos-arm64", "x86_64")) throw new Error("architecture gate self-test failed")
  if (!parseArgs(["--tuple", "windows-x64", "--report", "report.json"]).report) throw new Error("CLI report parser self-test failed")
  try { parseArgs(["--reprot", "report.json"]); throw new Error("unknown CLI option was accepted") } catch (error) { if (!String(error.message).includes("unknown option")) throw error }
  if (!allowedGodot43Shutdown(1, "Godot Engine v4.3.stable.official.77dcf97d8 - https://godotengine.org\nWARNING: 1 RID of type \"Canvas\" were leaked.\nWARNING: 1 RID of type \"CanvasItem\" were leaked.\nWARNING: ObjectDB instances leaked at exit\nERROR: 1 RID allocations of type 'Canvas' were leaked at exit.")) throw new Error("shutdown-noise self-test failed")
  if (allowedGodot43Shutdown(1, "ERROR: unexpected")) throw new Error("shutdown-noise rejection self-test failed")
  console.log("OPENCODE_COPIED_ADDON_MATRIX_SELF_TEST_OK")
}

try {
  const options = parseArgs(process.argv.slice(2))
  if (options.help) usage()
  else if (options["self-test"]) selfTest()
  else await run(options)
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error))
  process.exitCode = 1
}
