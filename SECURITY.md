# Security

This document describes the security boundary of Godot MCP Pro protocol v1.

## Trust model

The bridge is local-only, project-bound, and mutually authenticated. The agent
listens on one operating-system-selected port bound explicitly to
`127.0.0.1`. The editor never scans a fixed port range and neither side accepts
a wildcard, LAN, or public endpoint.

Processes running as the same operating-system user remain inside the trust
boundary. They may already read or edit the project and, subject to operating
system access controls, may read the protected session files. The bridge is not
a sandbox against a fully compromised user account.

## Discovery and protected session files

For each project, the editor derives this default rendezvous directory:

```text
<system-temp>/godot-mcp-pro/<sha256-of-canonical-project-path>/
```

The editor writes `bridge-session.json` plus a unique token file. On Unix-like
systems the directory is restricted to mode `0700` and files to mode `0600`.
`GODOT_MCP_SESSION_FILE` may select an absolute managed-session path. The
session contract contains the canonical project, discovery path, token-file
path, owner nonce, coordinator process identity, and protocol version. It is
protected launch material and must not be committed to a project.

The token file contains base64url-without-padding encoding of exactly 32 random
bytes. A new token and owner nonce are generated for every editor session. The
raw token is never placed in command-line arguments, project settings, logs, or
the discovery record.

The agent publishes `bridge-discovery.json` only after binding its listener. The
record is secret-free and contains:

- schema and protocol version;
- canonical project path and `ws://127.0.0.1:<selected-port>` endpoint;
- agent PID and durable process-start identity;
- observed parent PID/start identity, or a zero pair when unmanaged;
- owner nonce, creation time, and expiration time.

The discovery field names `owner_started_at_ms` and `parent_started_at_ms` are
retained for protocol-v1 compatibility. On Linux, every nonzero value in those
fields is an opaque JSON-safe integer in the inclusive range
`[2^52, 2^53-1]`, not a timestamp. It is generated as `2^52` plus the first 52
bits of a domain-separated SHA-256 whose UTF-8 input is the domain string
`godot-process-identity/linux/v1`, a NUL, the normalized (trimmed and
lowercased)
`/proc/sys/kernel/random/boot_id`, a NUL, and the raw decimal
`/proc/<pid>/stat` `start_ticks` value (with the digest prefix interpreted
big-endian). Linux identities must never be used as epoch time, ordering, or
duration. `created_at_ms` and `expires_at_ms` remain epoch milliseconds.

During upgrade, a nonzero Linux identity below `2^52` is a legacy value and is
not comparable with the v1 identity. It is `UNKNOWN` while the PID remains live
or its absence cannot be independently established; malformed values and
identity read failures have the same fail-closed result. The process and all
ownership evidence are preserved in those cases. A separate liveness result
that confirms the PID is absent may classify the overall record as `STALE`, and
a Linux `/proc/<pid>/stat` state `Z` (zombie) is definitively `STALE`; expiry
alone never overrides `UNKNOWN`. The 52-bit truncation keeps the identity
exactly representable as a JavaScript/JSON safe integer with a bounded collision
probability. It is not a standalone ownership proof.

Discovery records live for 30 seconds and are refreshed at least every 10
seconds. Publication uses a flushed temporary file and atomic rename. The
editor verifies schema, project, owner, lifetime, loopback endpoint, and both
process identities before connecting.

## Mutual authentication

Opening the WebSocket is not enough to run commands. Both peers remain in
`HANDSHAKING` until this five-second protocol completes:

1. Godot sends `bridge.handshake` with protocol version, canonical project,
   owner nonce, and a fresh client nonce.
2. The agent validates those fields and returns a fresh server nonce plus an
   HMAC-SHA256 server proof.
3. Godot verifies the proof and sends `bridge.authenticate` with its reciprocal
   client proof.
4. The agent verifies the proof and returns `{ "authenticated": true }`.

Proofs cover the NUL-delimited UTF-8 fields `godot-ai-bridge-v1`, role, project,
owner nonce, client nonce, and server nonce. The raw token is never sent over
the socket. Non-handshake commands are rejected until both peers enter
`READY`. Reconnects always use fresh nonce pairs and never replay incomplete
commands.

Protocol failures use JSON-RPC errors `-32000` through `-32004` for not-ready,
authentication, project, version, and timeout failures, followed by WebSocket
close code `1008` or `1002` as appropriate.

## Lifecycle and cleanup

A PID alone is never treated as ownership proof. PID, matching process-start
identity, and the fresh owner nonce jointly authorize adoption, termination, or
deletion; no one member is sufficient. Cleanup compares all three (and the
required parent tuple for managed children) so PID reuse cannot authorize
deletion or termination.
The editor also holds a per-project session lock, preventing a second live
editor from replacing the first editor's token or discovery contract.

Normal shutdown invalidates the transport first, then removes only the
session, discovery, token, runtime autoloads, and ownership journal belonging to
that session. Startup may remove an artifact only after proving that its owner
is dead, its PID was reused, its required parent identity is stale, or its
record expired. `UNKNOWN` identity status always takes precedence over expiry:
if either the owner or a required managed parent cannot be classified as a
match or confirmed stale, the process and record are preserved and startup
fails closed with a diagnostic.

If a client process outlives the editor, deletion or replacement of the
protected session contract invalidates the cached credential and stops further
discovery refresh. Restart the AI client to consume the new editor session.

## Runtime autoloads

Editor-only sessions do not modify project autoloads. Runtime-dependent tools
are disabled until explicitly enabled in the MCP Pro panel. Enabling one before
game launch installs only its screenshot, input, or inspector dependency.
Disabling the last dependent tool or disabling the plugin removes only entries
owned by the current session. Matching pre-existing autoloads are usable but
remain unowned and are preserved.

If a game was already running without a required service, the tool returns
`-32020` with a stop-and-relaunch diagnostic; changing Project Settings cannot
retroactively inject an autoload into that process.

## OpenCode managed-addon boundary

The unified `addons/opencode_godot` plugin launches only manifest-selected,
checksum-verified self-contained executables. Godot writes a private one-time
descriptor containing a fresh Basic-auth password and process-local OpenCode
configuration, launches the executable directly with `OS.execute_with_pipe`,
and retains stdin as the authoritative editor-owner lease. OpenCode consumes
and deletes the descriptor before binding an operating-system-selected
`127.0.0.1` port. Its public listen record contains no password; readiness
requires an authenticated `/global/godot-health` match and a separate
directory-bound `/path` probe. That probe compares the routed instance's exact
`directory`; it does not use `Project.Info.worktree`, because a valid non-Git
project reports `/` there.

The editor does not mutate its global environment, put credentials in command
arguments, or adopt a process based on a PID/port alone. Normal disable closes
the owner lease so OpenCode disposes project instances and its MCP child.
Forced cleanup is limited to nonce-, PID/start-, executable-, project-, and
parent-identity records that match; an `UNKNOWN` identity is preserved. A
partial development manifest may identify an unsigned/unverified but
SHA-256-verified native payload and emits a warning. A manifest marked as a
complete release requires signed/verified payload metadata for every declared
target.

HTTP/SSE provides chat state only. Godot editor mutations remain confined to
the MCP stdio -> mutually authenticated WebSocket -> single command-router
path. OpenCode or a configured model provider may use the network and receive
prompt/project context according to that provider's terms; the addon does not
download executable payloads at runtime.

## `execute_editor_script` is not sandboxed

The tool has guards against common accidental file writes, but those guards are
not a security sandbox. Disable `execute_editor_script` in the MCP Pro tool
panel if arbitrary editor-side GDScript is not required. The router persists
per-tool choices and rejects disabled methods with `-32603`.

## Troubleshooting

- **Waiting for discovery:** confirm the editor and agent use the same lexical
  canonical project path and that the AI client received `GODOT_PROJECT_PATH`.
- **Session ownership error:** another editor or agent still owns the project.
  Close it normally; do not delete files while its PID/start identity is live.
- **Authentication/project/version error:** upgrade the addon and server
  together, then restart both so they consume one protocol-v1 session.
- **Runtime service unavailable:** stop the running game, enable the required
  runtime tool in the panel, and launch the game again.
- **Unverified stale artifact:** inspect the reported file and process identity.
  The plugin intentionally refuses destructive cleanup when ownership cannot be
  proven.

## Reporting a vulnerability

Open a GitHub issue for public reports or contact the author directly for a
private disclosure. Include the addon and server versions, operating system,
and the smallest reproduction available. Never attach a live token or protected
session file.
