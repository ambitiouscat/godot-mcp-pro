#!/usr/bin/env node

/**
 * Validate the immutable payload contract consumed by the Godot addon.
 *
 * The validator is intentionally independent of Node/Bun at editor runtime;
 * this file is release/test tooling.  --allow-missing is for a source tree
 * whose six tuple directories have not all been assembled yet.  It does not
 * relax tuple/path traversal/version/schema checks.
 */

import { createHash } from "node:crypto"
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs"
import path from "node:path"
import process from "node:process"

const EXPECTED = {
  "windows-x86_64": { opencode: "opencode.exe", mcp: "godot-mcp.exe" },
  "windows-arm64": { opencode: "opencode.exe", mcp: "godot-mcp.exe" },
  "macos-x86_64": { opencode: "opencode", mcp: "godot-mcp" },
  "macos-arm64": { opencode: "opencode", mcp: "godot-mcp" },
  "linux-x86_64-glibc": { opencode: "opencode", mcp: "godot-mcp" },
  "linux-arm64-glibc": { opencode: "opencode", mcp: "godot-mcp" },
}
const EXPECTED_OPEN_CODE_VERSION = "1.17.18"
const EXPECTED_MCP_VERSION = "1.16.0"
const SHA256 = /^sha256:[0-9a-f]{64}$/i
const SOURCE_FINGERPRINT = /^(?:sha256:[0-9a-f]{64}|git:[0-9a-f]{40})$/i
// OpenCode release builds expose the exact OPENCODE_BUILD_FINGERPRINT value
// (a bare 64-hex digest), while local/source tooling may use a prefixed or
// compiler-qualified value. Keep the accepted grammar explicit and bounded.
const FINGERPRINT = /^(?:sha256:[0-9a-f]{64}|[0-9a-f]{64}|git:[0-9a-f]{40}|[A-Za-z0-9_.:-]{3,256})$/i

function usage() {
  console.log(`Usage: node tests/verify_payload_manifest.mjs [manifest] [options]

Options:
  --manifest <path>       Manifest path (also accepted as the first argument)
  --addon-root <path>     Addon root containing bin/ (defaults beside manifest)
  --allow-missing         Accept explicit missing/unverified source-tree entries
  --allow-partial         Alias for --allow-missing
  --allow-unverified      Accept present unsigned/version-unverified entries
  --help                  Show this help

The default/full mode requires all six tuples, relative bin paths, matching
SHA-256/size, pinned versions, release fingerprints, executable mode metadata,
and signed signature metadata when release.complete/mode=full is declared.`)
}

function parseArgs(argv) {
  const options = { allowMissing: false, allowUnverified: false }
  const positional = []
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index]
    if (value === "--help" || value === "-h") options.help = true
    else if (value === "--allow-missing" || value === "--allow-partial") options.allowMissing = true
    else if (value === "--allow-unverified") options.allowUnverified = true
    else if (value === "--manifest" || value === "--addon-root") {
      const next = argv[++index]
      if (!next || next.startsWith("--")) throw new Error(`${value} requires a path`)
      const key = value === "--manifest" ? "manifest_path" : "addon_root"
      options[key] = next
    } else if (value.startsWith("--")) throw new Error(`Unknown option: ${value}`)
    else positional.push(value)
  }
  if (!options.manifest_path && positional.length > 0) options.manifest_path = positional[0]
  return options
}

function resolveDefaultManifest() {
  const cwd = path.resolve(process.cwd())
  const candidates = [
    path.join(cwd, "addons", "opencode_godot", "payload-manifest.json"),
    path.join(cwd, "payload-manifest.json"),
    path.resolve(import.meta.dirname, "..", "addons", "opencode_godot", "payload-manifest.json"),
  ]
  return candidates.find((candidate) => existsSync(candidate)) ?? candidates[0]
}

function fail(message) {
  failures.push(message)
}

function check(condition, message) {
  if (condition) checks.push(message)
  else fail(message)
}

function asObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

function isMissingEntry(entry) {
  if (!asObject(entry)) return true
  if (entry.status === "missing") return true
  return !entry.path || !entry.sha256 || entry.sha256 === "" || entry.size_bytes === null || entry.size_bytes === undefined
}

function pathIsSafeRelative(value) {
  if (typeof value !== "string" || value.length === 0) return false
  if (value.includes("\\")) return false
  if (path.posix.isAbsolute(value) || /^[A-Za-z]:[\\/]/.test(value)) return false
  const segments = value.split("/")
  if (segments.includes("..") || segments.includes(".")) return false
  return segments[0] === "bin" && segments.length >= 3
}

function isInside(root, candidate) {
  const relative = path.relative(path.resolve(root), path.resolve(candidate))
  return relative === "" || (relative !== ".." && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative))
}

function digestFile(file) {
  return `sha256:${createHash("sha256").update(readFileSync(file)).digest("hex")}`
}

function validMode(mode) {
  return typeof mode === "string" && /^[0-7]{4}$/.test(mode) && mode === "0755"
}

function validSignature(signature) {
  if (!asObject(signature)) return false
  if (!["signed", "verified", "unsigned", "unverified", "missing"].includes(signature.status)) return false
  return typeof signature.scheme === "string" && signature.scheme.length > 0
}

function validMinimum(value) {
  if (typeof value !== "string") return false
  const match = /^(\d+)\.(\d+)(?:\.(\d+))?$/.exec(value)
  if (!match) return false
  return Number(match[1]) > 4 || (Number(match[1]) === 4 && Number(match[2]) >= 3)
}

const args = parseArgs(process.argv.slice(2))
if (args.help) {
  usage()
  process.exit(0)
}

const failures = []
const checks = []
const manifestPath = path.resolve(args.manifest_path ?? resolveDefaultManifest())
const addonRoot = path.resolve(args.addon_root ?? path.dirname(manifestPath))
let manifest
try {
  manifest = JSON.parse(readFileSync(manifestPath, "utf8"))
} catch (error) {
  console.error(`PAYLOAD_MANIFEST_FAILED\n- cannot read manifest ${manifestPath}: ${error.message}`)
  process.exit(1)
}

const fullRelease = manifest.release?.mode === "full" || manifest.release?.complete === true
const allowMissing = args.allowMissing && !fullRelease
const allowUnverified = (args.allowUnverified || args.allowMissing) && !fullRelease

check(manifest.schema === "opencode-godot-payload-manifest", "manifest schema is pinned")
check(manifest.schema_version === 1, "manifest schema version is supported")
check(validMinimum(manifest.godot_minimum), "Godot minimum is 4.3 or newer")
check(asObject(manifest.opencode), "OpenCode release metadata is present")
check(asObject(manifest.godot_mcp), "Godot MCP release metadata is present")
check(manifest.opencode?.version === EXPECTED_OPEN_CODE_VERSION, "OpenCode version is pinned to 1.17.18")
check(manifest.godot_mcp?.version === EXPECTED_MCP_VERSION, "Godot MCP version is pinned to 1.16.0")
check(manifest.godot_mcp?.api_contract === "godot-mcp-pro/1.16.0" || (allowMissing && !manifest.godot_mcp?.api_contract), "Godot MCP API contract is pinned")

for (const [label, release] of [["OpenCode", manifest.opencode], ["Godot MCP", manifest.godot_mcp]]) {
  const sourceFingerprint = release?.source_fingerprint
  const sourceOk = SOURCE_FINGERPRINT.test(sourceFingerprint ?? "")
  const missingSource = sourceFingerprint === undefined || sourceFingerprint === null || sourceFingerprint === "" || sourceFingerprint === "UNVERIFIED" || sourceFingerprint === "UNPACKAGED"
  check(sourceOk || (allowMissing && missingSource), `${label} source fingerprint is release-qualified`)
}

const payloads = manifest.payloads
check(asObject(payloads), "payload map is present")
const seenTuples = new Set()
const seenPaths = new Set()
if (asObject(payloads)) {
  for (const tuple of Object.keys(EXPECTED)) {
    check(Object.prototype.hasOwnProperty.call(payloads, tuple), `canonical tuple ${tuple} is declared`)
    if (!Object.prototype.hasOwnProperty.call(payloads, tuple)) continue
    seenTuples.add(tuple)
    const item = payloads[tuple]
    check(asObject(item), `${tuple} payload entry is an object`)
    if (!asObject(item)) continue
    for (const kind of ["opencode", "mcp"]) {
      const label = `${tuple}/${kind}`
      const entry = item[kind]
      check(asObject(entry), `${label} metadata is present`)
      if (!asObject(entry)) continue
      const missing = isMissingEntry(entry)
      if (missing) {
        check(allowMissing, `${label} missing payload is allowed only with --allow-missing`)
        if (!allowMissing) continue
        if (entry.status && !["missing", "unverified"].includes(entry.status)) fail(`${label} missing entry has invalid status ${entry.status}`)
        continue
      }

      const relativePath = entry.path
      const expectedPath = `bin/${tuple}/${EXPECTED[tuple][kind]}`
      check(pathIsSafeRelative(relativePath), `${label} path is relative and traversal-free`)
      check(relativePath === expectedPath, `${label} path is canonical (${expectedPath})`)
      if (!pathIsSafeRelative(relativePath)) continue
      const absolutePath = path.resolve(addonRoot, relativePath)
      check(isInside(path.join(addonRoot, "bin"), absolutePath), `${label} path remains under addon/bin`)
      check(!seenPaths.has(relativePath), `${label} path is unique`)
      seenPaths.add(relativePath)

      check(SHA256.test(entry.sha256 ?? ""), `${label} SHA-256 metadata is valid`)
      check(Number.isSafeInteger(entry.size_bytes) && entry.size_bytes > 0, `${label} size metadata is valid`)
      check(validMode(entry.mode), `${label} executable mode metadata is 0755`)
      check(entry.version === (kind === "opencode" ? EXPECTED_OPEN_CODE_VERSION : EXPECTED_MCP_VERSION), `${label} payload version is pinned`)
      check(SOURCE_FINGERPRINT.test(entry.source_fingerprint ?? ""), `${label} source fingerprint is valid`)
      const missingBuild = entry.build_fingerprint === undefined || entry.build_fingerprint === null || entry.build_fingerprint === "" || entry.build_fingerprint === "UNVERIFIED" || entry.build_fingerprint === "UNPACKAGED"
      check((!missingBuild && FINGERPRINT.test(entry.build_fingerprint ?? "")) || (allowMissing && missingBuild), `${label} build fingerprint is valid`)
      check(validSignature(entry.signature), `${label} signature metadata has a recognized structure`)
      const signatureStatus = typeof entry.signature === "object" ? entry.signature.status : "signed"
      if (fullRelease) {
        check(["signed", "verified"].includes(signatureStatus), `${label} is signed for a full release`)
        check(entry.signature.scheme !== "none", `${label} full-release signature scheme is not none`)
      } else if (!allowUnverified) {
        check(["signed", "verified"].includes(signatureStatus), `${label} is signed (or pass --allow-unverified for a developer manifest)`)
      }
      if (existsSync(absolutePath)) {
        let stats
        try {
          stats = statSync(absolutePath)
        } catch (error) {
          fail(`${label} payload cannot be stat'ed: ${error.message}`)
          continue
        }
        check(stats.isFile(), `${label} payload is a regular file`)
        check(stats.size === entry.size_bytes, `${label} size matches the payload`)
        check(digestFile(absolutePath).toLowerCase() === String(entry.sha256).toLowerCase(), `${label} SHA-256 matches the payload`)
      } else {
        check(allowMissing, `${label} payload file exists (or pass --allow-missing)`)
      }
    }
  }
  for (const tuple of Object.keys(payloads)) {
    check(Object.prototype.hasOwnProperty.call(EXPECTED, tuple), `no unexpected payload tuple ${tuple}`)
  }
}

check(seenTuples.size === Object.keys(EXPECTED).length, "manifest covers exactly six canonical tuples")
if (fullRelease) {
  check(manifest.release?.complete === true, "full release is marked complete")
  check(manifest.release?.signature_required === true, "full release records signature requirement")
}

if (failures.length > 0) {
  console.error("PAYLOAD_MANIFEST_FAILED")
  for (const failure of failures) console.error(`- ${failure}`)
  process.exit(1)
}
console.log(`PAYLOAD_MANIFEST_OK checks=${checks.length} mode=${fullRelease ? "full" : "partial-or-development"}`)
