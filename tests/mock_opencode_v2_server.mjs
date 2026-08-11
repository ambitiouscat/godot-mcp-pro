#!/usr/bin/env node
// Loopback-only v2 transport fixture.  It drives the shipped GDScript client
// through actual HTTPClient/SSE sockets, including a dropped durable stream.
import http from "node:http"
import fs from "node:fs"
import path from "node:path"

const [readyFile, project] = process.argv.slice(2)
if (!readyFile || !project) {
  process.stderr.write("usage: mock_opencode_v2_server.mjs <ready-file> <canonical-project>\n")
  process.exit(2)
}
const readyPath = path.resolve(readyFile)
const logPath = readyPath + ".requests.log"
const password = "transport-fixture-password-0123456789"
const basic = "Basic " + Buffer.from(`opencode:${password}`).toString("base64")
let durableConnections = 0

function log(value) { fs.appendFileSync(logPath, value + "\n", { encoding: "utf8", mode: 0o600 }) }
function json(res, status, body) {
  const payload = Buffer.from(JSON.stringify(body), "utf8")
  res.writeHead(status, { "content-type": "application/json", "cache-control": "no-store", "content-length": payload.length, connection: "keep-alive" })
  res.end(payload)
}
function valid(req) {
  // Do not persist transient test credentials.  The runner separately checks
  // every observed request; this responder only refuses requests that lack
  // either security/binding header altogether.
  return String(req.headers.authorization || "").startsWith("Basic ") && String(req.headers["x-opencode-directory"] || "").length > 0
}
function sse(res, events) {
  const payload = Buffer.from(events.map((event) => `id: ${event.id}\ndata: ${JSON.stringify(event)}\n\n`).join(""), "utf8")
  res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache", "content-length": payload.length, connection: "keep-alive" })
  res.end(payload)
}
function durable(id, seq, text) {
  return { id, type: "session.next.text.ended", durable: { aggregateID: "ses_live", seq, version: 1 }, location: { directory: project }, data: { sessionID: "ses_live", text } }
}

const server = http.createServer((req, res) => {
  if (!valid(req)) return json(res, 401, { error: "unauthorized or unbound" })
  const url = new URL(req.url, "http://127.0.0.1")
  log(`${req.method} ${url.pathname}${url.search}`)
  if (req.method === "GET" && url.pathname === "/global/godot-health") return json(res, 200, { opencode_version: "1.17.18" })
  if (req.method === "GET" && url.pathname === "/path") return json(res, 200, { directory: project, worktree: "/" })
  if (req.method === "GET" && url.pathname === "/api/session") return json(res, 200, { data: [{ id: "ses_live", title: "Loopback transport" }] })
  if (req.method === "GET" && url.pathname === "/api/session/ses_live/history") return json(res, 200, { data: [durable("evt_history", 0, "history snapshot")], hasMore: false })
  if (req.method === "GET" && url.pathname === "/api/session/ses_live/event") {
    durableConnections += 1
    const after = url.searchParams.get("after")
    if (durableConnections === 1 && after === "0") return sse(res, [durable("evt_one", 1, "replayed once")])
    if (durableConnections === 2 && after === "1") return sse(res, [durable("evt_one", 1, "duplicate must drop"), durable("evt_two", 2, "replay after disconnect")])
    return sse(res, [])
  }
  if (req.method === "GET" && url.pathname === "/event") return sse(res, [])
  if (req.method === "GET" && url.pathname === "/api/session/ses_live/permission") return json(res, 200, { data: [{ id: "per_live", sessionID: "ses_live", action: "edit", resources: [], save: ["once"] }] })
  if (req.method === "GET" && url.pathname === "/api/session/ses_live/question") return json(res, 200, { data: [{ id: "que_live", sessionID: "ses_live", questions: [{ question: "Continue?", header: "Transport", options: [{ label: "Yes", description: "Continue" }], multiple: false, custom: false }] }] })
  // A compact JSON acknowledgement avoids platform-specific 204 keep-alive
  // handling while still exercising the same authenticated client operations.
  if (req.method === "POST" && ["/api/session/ses_live/permission/per_live/reply", "/api/session/ses_live/question/que_live/reply", "/api/session/ses_live/interrupt"].includes(url.pathname)) return json(res, 200, {})
  if (req.method === "POST" && url.pathname === "/api/session/ses_live/prompt") return json(res, 200, { data: { id: "adm_cancel", sessionID: "ses_live" } })
  return json(res, 404, { error: "unexpected route" })
})
server.listen(0, "127.0.0.1", () => {
  const address = server.address()
  fs.mkdirSync(path.dirname(readyPath), { recursive: true })
  fs.writeFileSync(readyPath, JSON.stringify({ hostname: "127.0.0.1", port: address.port, base_url: `http://127.0.0.1:${address.port}`, password }), { encoding: "utf8", mode: 0o600 })
})
function stop() { server.close(() => process.exit(0)); setTimeout(() => process.exit(0), 2000).unref() }
process.once("SIGTERM", stop)
process.once("SIGINT", stop)
