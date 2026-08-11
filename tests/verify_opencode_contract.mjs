#!/usr/bin/env node

import { createHash } from "node:crypto"
import { execFileSync } from "node:child_process"
import { existsSync, readFileSync, readdirSync } from "node:fs"
import path from "node:path"
import process from "node:process"

const PINNED_COMMIT = "f47684787ad07e5311bd9422c1a9eb70c9966274"
const EXPECTED_VERSION = "1.17.18"
const cwd = path.resolve(process.cwd())
const repoRoot = existsSync(path.join(cwd, "addons", "opencode_godot")) ? cwd : path.resolve(import.meta.dirname, "..")
const projectRoot = path.resolve(repoRoot, "..")
const defaultOpenCodeRoot = path.join(projectRoot, "opencode")
const defaultContractPath = path.join(repoRoot, "addons", "opencode_godot", "contract", "opencode-http-contract.json")

const args = parseArgs(process.argv.slice(2))
const openCodeRoot = path.resolve(args["opencode-root"] ?? process.env.OPENCODE_ROOT ?? defaultOpenCodeRoot)
const contractPath = path.resolve(args.contract ?? defaultContractPath)
const failures = []
const checks = []

function check(condition, message) {
  if (condition) checks.push(message)
  else failures.push(message)
}

function read(relativePath) {
  return readFileSync(path.join(openCodeRoot, relativePath), "utf8")
}

function git(args) {
  return execFileSync("git", ["-C", openCodeRoot, ...args], { encoding: "utf8" }).trim()
}

function sourceFingerprint(commit, files) {
  const hash = createHash("sha256")
  for (const file of files) {
    const bytes = execFileSync("git", ["-C", openCodeRoot, "show", `${commit}:${file}`])
    hash.update(file)
    hash.update(Buffer.from([0]))
    hash.update(bytes)
    hash.update(Buffer.from([0]))
  }
  return `sha256:${hash.digest("hex")}`
}

function normalizePath(value) {
  return value.replace(/\$\{encodeURIComponent\(input\.([A-Za-z0-9_]+)\)\}/g, "{$1}")
}

function generatedDescriptors(source) {
  const result = []
  const expression = /method:\s*"([A-Z]+)",\s*path:\s*`([^`]+)`[\s\S]*?successStatus:\s*(\d+)/g
  for (const match of source.matchAll(expression)) {
    result.push({ method: match[1], path: normalizePath(match[2]), status: Number(match[3]) })
  }
  return result
}

function fixture(name) {
  const file = path.join(repoRoot, "tests", "fixtures", "opencode-http-sse", name)
  return JSON.parse(readFileSync(file, "utf8"))
}

function parseArgs(values) {
  const result = {}
  for (let index = 0; index < values.length; index += 1) {
    const value = values[index]
    if (!value.startsWith("--")) continue
    const key = value.slice(2)
    result[key] = values[index + 1]?.startsWith("--") ? true : values[++index]
  }
  return result
}

let contract
try {
  contract = JSON.parse(readFileSync(contractPath, "utf8"))
} catch (error) {
  failures.push(`cannot read contract ${contractPath}: ${error.message}`)
  reportAndExit()
  process.exit(1)
}

check(contract.schema === "opencode-godot-http-contract", "contract schema is pinned")
check(contract.schema_version === 1, "contract schema version is supported")
check(contract.source?.version === EXPECTED_VERSION, "contract pins OpenCode 1.17.18")
check(contract.source?.git_commit === PINNED_COMMIT, "contract pins the expected OpenCode source commit")

let head = ""
try {
  head = git(["rev-parse", "HEAD"])
  check(head === PINNED_COMMIT, `OpenCode HEAD is ${PINNED_COMMIT}`)
} catch (error) {
  failures.push(`cannot read OpenCode git revision: ${error.message}`)
}

try {
  const actualFingerprint = sourceFingerprint(contract.source.git_commit, contract.source.source_files)
  check(actualFingerprint === contract.source.source_fingerprint, "pinned OpenAPI/SDK source fingerprint matches")
} catch (error) {
  failures.push(`cannot calculate pinned source fingerprint: ${error.message}`)
}

const generatedPath = contract.source.sdk.generated_client
let generated = ""
try {
  generated = read(generatedPath)
} catch (error) {
  failures.push(`cannot read generated SDK client ${generatedPath}: ${error.message}`)
}

const descriptors = generatedDescriptors(generated)
const descriptorSet = new Set(descriptors.map((entry) => `${entry.method} ${entry.path} ${entry.status}`))
check(descriptors.length > 0, "generated SDK descriptors are readable")
for (const endpoint of contract.endpoints ?? []) {
  const signature = `${endpoint.method} ${endpoint.path} ${endpoint.response.status}`
  check(descriptorSet.has(signature), `${endpoint.id} endpoint has not drifted (${signature})`)
}

const protocolSources = [
  ["packages/protocol/src/groups/session.ts", contract.endpoints?.filter((entry) => entry.id.startsWith("v2.session.") && !entry.id.includes("permission") && !entry.id.includes("question")) ?? []],
  ["packages/protocol/src/groups/permission.ts", contract.endpoints?.filter((entry) => entry.id.includes("permission")) ?? []],
  ["packages/protocol/src/groups/question.ts", contract.endpoints?.filter((entry) => entry.id.includes("question")) ?? []],
]
for (const [file, endpoints] of protocolSources) {
  let text = ""
  try {
    text = read(file)
  } catch (error) {
    failures.push(`cannot read protocol source ${file}: ${error.message}`)
    continue
  }
  for (const endpoint of endpoints) check(text.includes(`identifier: "${endpoint.id}"`), `${endpoint.id} OpenAPI identifier is present in ${file}`)
}

let authSource = ""
let directorySource = ""
try {
  authSource = read("packages/opencode/src/server/auth.ts")
  directorySource = read("packages/opencode/src/server/routes/instance/httpapi/middleware/workspace-routing.ts")
  check(authSource.includes('withDefault("opencode")'), "Basic auth defaults to username opencode")
  check(authSource.includes("credentials.username === config.username"), "Basic auth validates the username")
  check(directorySource.includes('request.headers["x-opencode-directory"]'), "directory binding reads x-opencode-directory")
} catch (error) {
  failures.push(`cannot read authentication/directory source: ${error.message}`)
}

const managedSources = [
  ["packages/opencode/src/server/routes/instance/httpapi/groups/global.ts", ["/global/godot-health", 'identifier: "global.godot.health"', 'schema: Schema.Literal("opencode-godot-listen")']],
  ["packages/opencode/src/server/routes/instance/httpapi/handlers/global.ts", ["godotHealth", "managedHealth"]],
  ["packages/opencode/src/cli/godot-managed.ts", ["opencode-godot-listen", "project_hash", "launch_nonce", "build_fingerprint"]],
]
for (const [file, markers] of managedSources) {
  let text = ""
  try {
    text = read(file)
  } catch (error) {
    failures.push(`cannot read managed-health source ${file}: ${error.message}`)
    continue
  }
  for (const marker of markers) check(text.includes(marker), `managed-health source retains ${marker}`)
}

const health = contract.managed_health
check(health?.path === "/global/godot-health", "managed health path is pinned")
check(health?.response?.schema === "opencode-godot-listen", "managed health schema is pinned")
check(health?.auth_required === true, "managed health requires Basic auth")
check(health?.standard_health_unchanged?.path === "/global/health", "standard health remains a separate route")

const directoryProbe = contract.directory_probe
check(directoryProbe?.path === "/path", "directory routing probe uses the exact instance path endpoint")
check(directoryProbe?.response_directory_field === "directory", "directory routing proof compares the instance directory field")
check(directoryProbe?.non_git_worktree_may_be_root === true, "contract records that non-Git project worktree is not routing proof")
try {
  const group = read("packages/opencode/src/server/routes/instance/httpapi/groups/instance.ts")
  const handler = read("packages/opencode/src/server/routes/instance/httpapi/handlers/instance.ts")
  check(group.includes('path: "/path"'), "instance path route remains pinned")
  check(handler.includes("directory: ctx.directory"), "instance path handler returns the routed directory")
} catch (error) {
  failures.push(`cannot read directory-probe source: ${error.message}`)
}

const examples = fixture("http-examples.json")
const endpointIds = new Set((contract.endpoints ?? []).map((entry) => entry.id).concat("global.godot.health", "instance.path"))
check(examples.headers.authorization.startsWith("Basic "), "HTTP fixture carries Basic auth")
check(examples.headers.authorization.includes("b3BlbmNvZGU6"), "HTTP fixture uses Basic username opencode")
check(examples.headers["x-opencode-directory"] === examples.directory, "HTTP fixture binds the canonical directory")
for (const request of examples.requests) check(endpointIds.has(request.endpoint), `HTTP fixture endpoint ${request.endpoint} is in the contract`)
const permissionFixture = examples.requests.find((request) => request.endpoint === "v2.session.permission.reply")
check(JSON.stringify(permissionFixture.body_variants.map((entry) => entry.reply)) === JSON.stringify(["once", "always", "reject"]), "permission fixture covers once/always/reject")
const questionFixture = examples.requests.find((request) => request.endpoint === "v2.session.question.reply")
check(JSON.stringify(questionFixture.body.answers) === JSON.stringify([["Editor"], ["Full"]]), "question fixture preserves ordered answer arrays")

const fragmented = fixture("sse-fragmented.json")
check(fragmented.chunks.length > 1, "fragmented SSE fixture spans transport chunks")
check(JSON.stringify(fragmented.expected_ids) === JSON.stringify(["evt_0001", "evt_0002"]), "fragmented SSE fixture preserves event IDs")
const replay = fixture("sse-replay-gap.json")
check(replay.reconnect.after === replay.initial_cursor, "replay fixture resumes with the exclusive after cursor")
check(replay.reconnect.duplicate_ids_dropped.includes("evt_0002"), "replay fixture covers duplicate suppression")
check(replay.reconnect.gap_detected.expected_seq + 1 === replay.reconnect.gap_detected.received_seq, "replay fixture covers a sequence gap")
check(replay.reconnect.recovery.request === "v2.session.history", "replay fixture requires history recovery")
const malformed = fixture("sse-malformed.json")
check(malformed.expected.malformed_event.includes("compatibility error"), "malformed SSE fixture requires a compatibility diagnostic")
check(malformed.expected.reconnect === true, "malformed SSE fixture requires bounded reconnect")
const replacement = fixture("daemon-replacement.json")
check(replacement.expected.must_not_attach_old_request_to_replacement === true, "daemon replacement fixture isolates generations")
check(replacement.old.launch_nonce !== replacement.replacement.launch_nonce, "daemon replacement fixture has distinct ownership nonces")

const expectedFixtureNames = ["daemon-replacement.json", "http-examples.json", "sse-fragmented.json", "sse-malformed.json", "sse-replay-gap.json"]
const actualFixtureNames = readdirSync(path.join(repoRoot, "tests", "fixtures", "opencode-http-sse")).filter((name) => name.endsWith(".json"))
for (const name of expectedFixtureNames) check(actualFixtureNames.includes(name), `fixture file ${name} is installed`)

reportAndExit()

function reportAndExit() {
  if (failures.length > 0) {
    console.error("OPENCODE_CONTRACT_FAILED")
    for (const failure of failures) console.error(`- ${failure}`)
    process.exitCode = 1
    return
  }
  console.log(`OPENCODE_CONTRACT_OK checks=${checks.length} commit=${PINNED_COMMIT} version=${EXPECTED_VERSION}`)
}
