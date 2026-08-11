# OpenCode for Godot

This directory is a self-contained Godot 4.3+ editor addon. A packaged release
contains the native OpenCode daemon, the Godot MCP compatibility sidecar, the
authenticated engine bridge, and a native right-side `OpenCode` dock. The
editor runtime does not require Node.js, Bun, npm, a shell launcher, WebView,
or a browser.

## Install

1. Copy the complete `opencode_godot` directory to
   `<project>/addons/opencode_godot`.
2. If `Godot MCP Pro` (`godot_mcp`) is enabled, disable it first. The unified
   addon already contains its bridge and command router, and refuses to start a
   duplicate.
3. In Godot, open **Project > Project Settings > Plugins** and enable
   **OpenCode for Godot**.
4. Open the `OpenCode` dock on the editor's right side. Use **Chat** for
   sessions and **Status** for daemon, bridge, tool, and recovery diagnostics.

Copy the whole directory. Copying only the scripts omits the platform payloads
and produces an explicit payload error.

## Supported payloads

The release manifest declares these initial targets:

- Windows x86_64 and arm64
- macOS x86_64 and arm64
- glibc-baseline Linux x86_64 and arm64

Each target has an immutable OpenCode `1.17.18` executable and Godot MCP Pro
`1.16.0` executable with source/build fingerprints, byte size, SHA-256, mode,
and signature metadata. The addon never downloads an executable at editor
runtime. A source checkout may carry a `partial` manifest for native testing;
missing targets and unsigned/unverified payloads are reported honestly. A
distributable `full` manifest is accepted only after all six target pairs are
present and release-signed.

Godot 4.3 remains supported. Its platform pipe implementations cannot report
read readiness, so the addon uses bounded background drain workers for both
stdout and stderr; the main thread only consumes a bounded, redacted diagnostic
buffer. On Linux and macOS, Godot 4.3 and 4.4 additionally have an upstream
`execute_with_pipe` stderr descriptor-ownership defect. The addon preserves
the affected stderr handles for the remainder of the editor process and bounds
their count so native/MCP switching remains safe; after the diagnostic limit is
reached, restart the editor. Godot 4.5+ does not need the Unix stderr path.

## Integration modes and tool profiles

The Status tab exposes two mutually exclusive Godot-tool providers:

| Mode | Processes | Use |
| --- | --- | --- |
| `native` | Godot editor + OpenCode daemon | The bundled `godot-tools` server plugin runs inside OpenCode and talks directly to the authenticated project bridge. No MCP child is started. |
| `mcp` | Godot editor + OpenCode daemon + MCP stdio child | Compatibility and rollback path. OpenCode owns the packaged sidecar over stdio; the sidecar uses the same authenticated bridge and command router. |

A fresh project selects `native` only when the compatibility manifest attests
catalog parity, loading by the packaged OpenCode daemon, the complete supported
platform smoke matrix, and simultaneous-project isolation. If any gate is
absent, the safe default remains `mcp`; `native` is still available as an
explicit development opt-in when its artifact passes integrity validation.

Changing the selector cancels local requests, stops the old provider and
daemon, verifies discovery/listener cleanup, rotates the bridge token and owner
nonce, then starts the replacement. A failed cleanup is reported and no second
owner is launched. The selection is stored only in project-scoped addon state
under `user://opencode_godot/integration-mode/<project-hash>/mode.json`.

The native `opencode-default` profile is the frozen, ordered 35-tool v1
allowlist. It avoids duplicating OpenCode's generic file/search/edit tools. The
explicit `full` profile exposes all 178 catalog tools for compatibility and
specialized workflows. Native permission keys are stable and namespaced as
`godot_<canonical-tool-id>` (for example `godot_get_project_info`); each call
uses catalog-derived resource patterns and operation metadata before bridge
dispatch.

External MCP clients can still use the packaged/server executable directly.
Its default entry point is MCP stdio with the `full` profile. The optional
streamable HTTP entry point binds only `127.0.0.1`, requires a distinct
high-entropy `Authorization: Bearer` credential on every request, and never
reuses the protected bridge token. HTTP MCP is a compatibility endpoint, not
an editor-command shortcut.

## What the status means

| Status | Meaning | What to do |
| --- | --- | --- |
| Daemon `starting` | Godot launched the bundled OpenCode process and is waiting for its one-time listen record. | Wait; inspect the Status tab if it changes to `error`. |
| Daemon `probing` | Basic-auth health and the canonical project route are being verified. | Do not use an unrelated server on the reported port; it will never be adopted. |
| Daemon `ready` | OpenCode chat HTTP/SSE is authenticated for this project. | Create or select a session and send a prompt. |
| Bridge `READY` / Godot tools `ready` | The selected native plugin or MCP child completed the project-scoped reciprocal HMAC handshake. | Godot editor tools are available. |
| Chat ready, tools waiting | OpenCode is usable, but the selected provider, discovery, authentication, or route is not ready. | Check native/MCP and bridge diagnostics separately; restarting chat alone may not fix it. |
| `backoff` | An owned daemon failed and a bounded restart is pending. | Wait for the displayed retry or disable/re-enable after the retry limit. |
| `orphaned` | A daemon or MCP child identity could not be verified during shutdown. Credentials are cleared, but nonce-bound evidence is intentionally retained. | Close the prior editor/process normally and retry; do not delete evidence or kill the recorded PID unless its full start identity is verified. |
| `error` | Integrity, ownership, authentication, compatibility, or platform validation failed closed. | Follow the exact diagnostic; never delete a live ownership file merely to bypass it. |

Chat readiness never implies Godot tool readiness. Editor commands have one
engine route in both modes: selected OpenCode provider -> authenticated
loopback WebSocket -> the unified addon's command router. HTTP/SSE callbacks do
not execute editor commands.

Ownership and cleanup require the PID, matching process-start identity, and
fresh owner nonce together. Linux keeps the protocol-v1 compatibility names
`*_started_at_ms`, but stores opaque safe integers in `[2^52, 2^53-1]` rather
than epoch/order/duration values; discovery `created_at_ms` and `expires_at_ms`
remain epoch milliseconds. Legacy lower-range, malformed, or unreadable Linux
identities are `UNKNOWN` while liveness is unproven and preserve evidence; a
separately confirmed absent PID or zombie is `STALE`. See the repository
`SECURITY.md` for the exact derivation and fail-closed cleanup rules.

## State, configuration, and privacy

Writable addon state is project-scoped under:

```text
user://opencode_godot/runtime/<sha256-of-canonical-project-path>/
```

The bridge session/token uses the protected temporary location documented in
the repository `SECURITY.md`. Nothing is generated under `res://`, and the
addon does not overwrite a user's OpenCode configuration or external MCP
client configuration. It supplies one process-local OpenCode configuration for
the bundled sidecar by a private, one-time launch descriptor; the descriptor
is consumed and deleted before the daemon listens. The daemon binds an
operating-system-selected `127.0.0.1` port and requires a fresh high-entropy
Basic-auth password.

The addon performs no runtime payload download. OpenCode and the model provider
you select may still access the network, and prompts, selected project context,
or tool results may be sent to that provider under its own privacy terms.
Godot tools can edit scenes, scripts, settings, and runtime state. Review
permission and question prompts in the dock; `execute_editor_script` is not a
sandbox.

## Disable, upgrade, and rollback

- **Disable:** turn off **OpenCode for Godot** in Project Settings. The addon
  stops HTTP/SSE first, closes the daemon owner lease, waits a bounded interval,
  tears down its authenticated bridge, removes only session-owned runtime
  autoloads/state, and removes the dock. Unverified processes are preserved and
  reported instead of killed.
- **Upgrade:** disable the plugin, replace the entire directory with one
  coherent release, then enable it. Do not mix an OpenCode executable, MCP
  sidecar, manifest, or scripts from different releases.
- **Mode rollback:** choose **MCP compatibility** in the Status tab and press
  **Restart**. The addon performs the same verified teardown and credential
  rotation used for a native-mode switch.
- **Release rollback:** disable the plugin and restore the previous complete
  directory. The next enable generates fresh credentials. Project
  scenes/scripts and unrelated OpenCode/MCP configuration remain untouched.
- **Return to the legacy addon:** disable `opencode_godot` before enabling
  `godot_mcp`. Never enable both at once.

## Troubleshooting

- **Unsupported host:** use a release containing the exact OS/architecture
  tuple. Musl Linux is not in the initial manifest.
- **Checksum/version/build mismatch:** replace the whole addon from a trusted
  release. Do not edit the manifest to match a changed binary.
- **Legacy conflict:** disable the `godot_mcp` plugin, then disable/re-enable
  `opencode_godot`.
- **Ownership is live or unknown:** close the prior Godot editor normally. The
  addon intentionally refuses to adopt or terminate a process it cannot prove.
- **Native unavailable:** inspect the native bundle integrity and compatibility
  gate diagnostics. Use MCP rollback while replacing the complete addon from a
  coherent release.
- **Daemon ready but tools unavailable:** inspect the selected native/MCP
  provider, discovery, and bridge authentication messages separately. Confirm
  the project is open and packaged artifacts match their manifests.
- **Runtime service requires restart:** stop the running game, enable/retry the
  runtime-dependent tool so its owned autoload is configured, then launch the
  game again.
- **Repeated stream reconnect:** the client reloads authoritative session
  history before resuming. Persistent authentication, directory, or contract
  errors require a coherent addon upgrade.
- **Linux/macOS 4.3/4.4 restart limit:** restart the editor when the Status tab
  says the legacy pipe-handle quarantine is full. The addon fails closed
  instead of releasing an affected handle or launching a child with invalid
  stdin.

For the build/release matrix and manifest validator, see
`docs/payload-release.md` in the repository.
