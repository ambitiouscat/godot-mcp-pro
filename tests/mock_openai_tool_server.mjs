#!/usr/bin/env node
// Deterministic local OpenAI-compatible SSE responder for the packaged addon
// E2E. It never contacts the network and deliberately performs exactly two
// provider turns: a Godot tool call, then a final assistant response.
import http from "node:http"
import fs from "node:fs"
import path from "node:path"

const readyFile = process.argv[2]
if (!readyFile) {
  process.stderr.write("usage: mock_openai_tool_server.mjs <ready-file>\n")
  process.exit(2)
}
const readyPath = path.resolve(readyFile)
const requestLogPath = readyPath + ".requests.log"
const requireComplexSchema = process.argv.includes("--require-complex-schema")
const cyclesIndex = process.argv.indexOf("--cycles")
const cycles = cyclesIndex < 0 ? 1 : Number(process.argv[cyclesIndex + 1])
if (!Number.isSafeInteger(cycles) || cycles < 1 || cyclesIndex >= process.argv.length - 1) {
  process.stderr.write("usage: mock_openai_tool_server.mjs <ready-file> [--require-complex-schema] [--cycles <positive-integer>]\n")
  process.exit(2)
}
const maxRequests = cycles * 2
const secret = "godot-e2e-test-key"
let requests = 0
let shuttingDown = false

function json(res, status, body) {
  res.writeHead(status, { "content-type": "application/json", "cache-control": "no-store" })
  res.end(JSON.stringify(body))
}

function sse(res, payloads) {
  res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache", connection: "keep-alive" })
  for (const payload of payloads) res.write(`data: ${JSON.stringify(payload)}\n\n`)
  res.end("data: [DONE]\n\n")
}

function chunk(id, created, delta, finish_reason = null) {
  return { id, object: "chat.completion.chunk", created, model: "tool-test", choices: [{ index: 0, delta, finish_reason }] }
}

function hasComplexGodotInputActionSchema(tools) {
  const entries = Array.isArray(tools) ? tools : (tools && typeof tools === "object" ? Object.values(tools) : [])
  const definition = entries.map((entry) => entry?.function ?? entry).find((entry) => entry?.name === "godot_set_input_action")
  const schema = definition?.parameters ?? definition?.input_schema ?? definition?.inputSchema
  const properties = schema?.properties
  const events = properties?.events
  const eventProperties = events?.items?.properties
  const eventType = eventProperties?.type
  const required = Array.isArray(schema?.required) ? schema.required : []
  return schema?.type === "object" && typeof properties?.action === "object" &&
    events?.type === "array" && events?.items?.type === "object" &&
    Array.isArray(eventType?.enum) && eventType.enum.includes("key") && eventType.enum.includes("joypad_motion") &&
    typeof properties?.deadzone === "object" && !required.includes("deadzone")
}

const server = http.createServer((req, res) => {
  if (req.method !== "POST" || req.url !== "/v1/chat/completions") return json(res, 404, { error: { message: "not found" } })
  if (req.headers.authorization !== `Bearer ${secret}`) return json(res, 401, { error: { message: "unauthorized" } })
  let raw = ""
  req.setEncoding("utf8")
  req.on("data", (chunk) => { raw += chunk })
  req.on("end", () => {
    let body
    try { body = JSON.parse(raw) } catch { return json(res, 400, { error: { message: "invalid JSON" } }) }
    if (body.model !== "tool-test" || body.stream !== true) return json(res, 400, { error: { message: "unexpected request" } })
    const complexSchema = hasComplexGodotInputActionSchema(body.tools)
    if (requireComplexSchema && !complexSchema) return json(res, 400, { error: { message: "missing godot_set_input_action complex schema" } })
    requests += 1
    if (requests > maxRequests) return json(res, 400, { error: { message: `more than ${cycles} provider tool cycles` } })
    const hasToolResult = Array.isArray(body.messages) && body.messages.some((item) => item && item.role === "tool")
    fs.appendFileSync(requestLogPath, `request=${requests} tool_result=${hasToolResult} complex_schema=${complexSchema}\n`, { encoding: "utf8", mode: 0o600 })
    const id = `chatcmpl-godot-e2e-${requests}`
    const created = Math.floor(Date.now() / 1000)
    if (!hasToolResult) {
      return sse(res, [
        chunk(id, created, { role: "assistant" }),
        chunk(id, created, { tool_calls: [{ index: 0, id: "call_godot_project_info", type: "function", function: { name: "godot_get_project_info", arguments: "" } }] }),
        chunk(id, created, { tool_calls: [{ index: 0, function: { arguments: "{}" } }] }),
        chunk(id, created, {}, "tool_calls"),
      ])
    }
    if (hasToolResult) {
      return sse(res, [
        chunk(id, created, { role: "assistant" }),
        chunk(id, created, { content: "Godot project info retrieved." }),
        chunk(id, created, {}, "stop"),
      ])
    }
  })
})

function shutdown(code = 0) {
  if (shuttingDown) return
  shuttingDown = true
  server.close(() => process.exit(code))
  setTimeout(() => process.exit(code), 2000).unref()
}
process.once("SIGTERM", () => shutdown())
process.once("SIGINT", () => shutdown())
server.listen(0, "127.0.0.1", () => {
  const address = server.address()
  const record = { hostname: "127.0.0.1", port: address.port, base_url: `http://127.0.0.1:${address.port}/v1`, pid: process.pid }
  fs.mkdirSync(path.dirname(readyPath), { recursive: true })
  fs.writeFileSync(readyPath, JSON.stringify(record), { encoding: "utf8", mode: 0o600 })
  process.stdout.write(`MOCK_OPENAI_TOOL_SERVER_READY port=${address.port}\n`)
})
