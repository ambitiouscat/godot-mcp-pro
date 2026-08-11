# OpenCode/Godot payload assembly

`addons/opencode_godot` carries the OpenCode daemon and the Godot MCP stdio
sidecar as local, self-contained executables. The editor never downloads a
runtime and does not require Node.js, Bun, npm, or a shell launcher.

## Assemble a developer/source tree

Run the PowerShell release tool from this repository (or pass absolute paths):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  tools/package_opencode_godot_payloads.ps1 `
  -OpenCodeRepo ..\opencode `
  -ServerRepo ..\server `
  -OutputAddonRoot addons\opencode_godot `
  -AllowMissing
```

The tool only reads local build output. It maps the six canonical tuples:

* `windows-x86_64`, `windows-arm64`
* `macos-x86_64`, `macos-arm64`
* `linux-x86_64-glibc`, `linux-arm64-glibc`

## Build and verify the MCP sidecars

The server repository builds the self-contained Bun payloads. Build artifacts
are unsigned by design: signing/notarization is an external release operation,
and no local command may claim that it happened.

```powershell
Push-Location ..\server
npm ci
npm run build:sidecars
npm run verify:sidecars
node tests/run_sidecar_smoke.mjs dist/sidecars/manifest.json
Pop-Location
```

`build:sidecars` compiles all six declared tuples. The smoke command is strict:
it runs only the artifact matching the current OS/architecture and fails if the
tuple is absent. Its payload process receives a PATH without Node, Bun, or npm;
the Node process that orchestrates the test is not part of the shipped payload.
Cross-compiled files are integrity-checked locally, but are not marked as
native-executed. The Git repository that contains the `server/` package runs
`.github/workflows/payload-native-matrix.yml` from its repository root. The
workflow runs the same test on each matching Windows, macOS, Linux, x86_64,
and arm64 runner. A
release must retain all six successful native-runner jobs.

Each runner emits a partial, single-tuple manifest. Merge those independently
produced manifests only after their native jobs pass:

```powershell
Push-Location ..\server
node scripts/merge-sidecar-manifests.mjs dist/sidecars-merged `
  <windows-x64-manifest> <windows-arm64-manifest> `
  <macos-x64-manifest> <macos-arm64-manifest> `
  <linux-x64-manifest> <linux-arm64-manifest>
node scripts/verify-sidecar-manifest.mjs dist/sidecars-merged/manifest.json
Pop-Location
```

The merger rechecks source/compiler identity, canonical tuple and path,
checksum, byte size, and signature metadata. It never upgrades cross-built or
unsigned evidence into a native-executed or signed claim.

After the release environment attaches real signature metadata, verify that
source manifest with the separate signing gate before assembly:

```powershell
Push-Location ..\server
npm run verify:sidecars:release -- dist/sidecars/manifest.json
Pop-Location
```

An incomplete source tree produces a `partial` manifest with explicit
`missing` or `unverified` entries. A development artifact whose embedded or
declared OpenCode version is not `1.17.18` is never marked ready.

## Validate a manifest

```powershell
node tests/verify_payload_manifest.mjs `
  --manifest addons/opencode_godot/payload-manifest.json `
  --addon-root addons/opencode_godot `
  --allow-missing
```

Use canonical absolute paths when the repositories are reached through
directory symlinks; different process runtimes can otherwise resolve a
relative parent directory against different physical locations.

Without `--allow-missing`, the validator requires every selected payload file,
relative `bin/<tuple>/` paths, unique paths, matching SHA-256 and byte size,
pinned versions, source/build fingerprints, and `0755` mode metadata. A full
release is emitted with `-FullRelease`; it additionally requires all six
tuples and signed/verified signature metadata:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  tools/package_opencode_godot_payloads.ps1 `
  -OpenCodeRepo ..\opencode `
  -ServerRepo ..\server `
  -OutputAddonRoot addons\opencode_godot `
  -FullRelease
```

Signatures and notarization are supplied by the release environment. The
assembler does not invent a signature claim. Existing payload files are only
overwritten at their exact validated `bin/<tuple>/<filename>` destinations;
it never recursively deletes an unverified path.
