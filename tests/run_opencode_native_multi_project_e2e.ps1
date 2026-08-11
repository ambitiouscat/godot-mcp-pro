param(
    [string]$Godot = 'E:\Code\godot\godot_work\bin\godot.windows.editor.x86_64.mono.console.exe',
    [string]$AddonRoot = '',
    [int]$TimeoutSeconds = 210
)

# This wrapper deliberately does not reuse the MCP lifecycle wrapper: two
# Godot children run at once and exercise the packaged native file plugin. It
# leaves the MCP regression independent and verifies that no MCP sidecar was
# ever created for either project.
$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$addonSource = if ([String]::IsNullOrWhiteSpace($AddonRoot)) {
    Join-Path $repositoryRoot 'addons\opencode_godot'
} else {
    [IO.Path]::GetFullPath($AddonRoot)
}
$payloadSource = Join-Path $addonSource 'bin\windows-x86_64'
$nativeDir = Join-Path $addonSource 'runtime\opencode-plugins'
$nativeArtifact = Join-Path $nativeDir 'godot-tools.js'
$nativeManifest = Join-Path $nativeDir 'godot-tools.manifest.json'
$fixturePrefix = Join-Path ([IO.Path]::GetTempPath()) 'opencode-godot-native-multi % '
$root = [IO.Path]::GetFullPath(($fixturePrefix + [guid]::NewGuid().ToString('N')))
$restrictedPath = [IO.Path]::Combine($env:SystemRoot, 'System32') + ';' + [IO.Path]::Combine($env:SystemRoot, 'System32\WindowsPowerShell\v1.0')
$wallClock = [Diagnostics.Stopwatch]::StartNew()
$children = @()
$providers = @()

function Assert-FixturePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $resolved = [IO.Path]::GetFullPath($Path)
    if (-not $resolved.StartsWith($fixturePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to use a path outside the native E2E fixture: $resolved"
    }
    return $resolved
}

function Read-TaskText {
    param($Task)
    if ($null -eq $Task) { return '' }
    try { $Task.Wait(5000) | Out-Null; if ($Task.IsCompleted) { return [string]$Task.Result } } catch {}
    return '<output capture timed out>'
}

function Read-JsonWhenReady {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { return $null }
}

function Stop-OwnedFixtureProcesses {
    param([Parameter(Mandatory = $true)][string]$FixtureRoot)
    $needle = $FixtureRoot.Replace('\', '/').ToLowerInvariant()
    $owned = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -in @('opencode.exe', 'godot-mcp.exe') -and $_.CommandLine -and $_.CommandLine.Replace('\', '/').ToLowerInvariant().Contains($needle)
    })
    foreach ($process in $owned) { try { Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue } catch {} }
}

function Start-Provider {
    param([Parameter(Mandatory = $true)][string]$Fixture)
    $node = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($null -eq $node) { $node = Get-Command node -ErrorAction SilentlyContinue }
    if ($null -eq $node) { throw 'Node.js is required only for the external deterministic OpenAI-compatible responder.' }
    $readyPath = Assert-FixturePath (Join-Path $Fixture 'mock-openai.ready.json')
    $scriptPath = Assert-FixturePath (Join-Path $Fixture 'tests\mock_openai_tool_server.mjs')
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $node.Source
    $info.WorkingDirectory = $Fixture
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.Arguments = ('"' + $scriptPath.Replace('"', '\"') + '" "' + $readyPath.Replace('"', '\"') + '" --require-complex-schema')
    $process = [Diagnostics.Process]::Start($info)
    $record = [PSCustomObject]@{ Process = $process; Out = $process.StandardOutput.ReadToEndAsync(); Err = $process.StandardError.ReadToEndAsync(); Ready = $readyPath }
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    while ($deadline.ElapsedMilliseconds -lt 10000) {
        if (Test-Path -LiteralPath $readyPath -PathType Leaf) {
            try {
                $ready = Get-Content -LiteralPath $readyPath -Raw | ConvertFrom-Json
                if ($ready.hostname -eq '127.0.0.1' -and [int]$ready.port -gt 0 -and $ready.base_url -eq ('http://127.0.0.1:' + [int]$ready.port + '/v1')) {
                    $record | Add-Member -NotePropertyName BaseUrl -NotePropertyValue ([string]$ready.base_url)
                    return $record
                }
            } catch {}
        }
        if ($process.HasExited) { throw "Mock provider exited during startup.`n$(Read-TaskText $record.Out)`n$(Read-TaskText $record.Err)" }
        Start-Sleep -Milliseconds 50
    }
    throw "Mock provider did not publish a valid loopback ready record: $readyPath"
}

function Stop-Provider {
    param($Provider)
    if ($null -eq $Provider) { return }
    if (-not $Provider.Process.HasExited) { try { $Provider.Process.Kill() } catch {} }
    try { $Provider.Process.WaitForExit(5000) | Out-Null } catch {}
    if (-not $Provider.Process.HasExited) { throw "Fixture mock provider PID $($Provider.Process.Id) leaked." }
}

function New-ProjectFixture {
    param([Parameter(Mandatory = $true)][string]$Name)
    $fixture = Assert-FixturePath (Join-Path $root $Name)
    New-Item -ItemType Directory -Path $fixture -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixture\project.godot') -Destination (Join-Path $fixture 'project.godot')
    $project = Join-Path $fixture 'project.godot'
    $text = Get-Content -LiteralPath $project -Raw
    $text = $text.Replace('config/name="Godot MCP Bridge Test"', ('config/name="Native ' + $Name + '"'))
    $text = $text.Replace('enabled=PackedStringArray("res://addons/godot_mcp/plugin.cfg")', 'enabled=PackedStringArray()')
    Set-Content -LiteralPath $project -Value $text -NoNewline
    New-Item -ItemType Directory -Path (Join-Path $fixture 'addons') -Force | Out-Null
    Copy-Item -LiteralPath $addonSource -Destination (Join-Path $fixture 'addons\opencode_godot') -Recurse
    New-Item -ItemType Directory -Path (Join-Path $fixture 'tests') -Force | Out-Null
    foreach ($file in @('opencode_native_multi_project_e2e_runner.gd', 'opencode_native_e2e_test_lifecycle.gd', 'opencode_e2e_test_editor_plugin.gd')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot ('fixture\tests\' + $file)) -Destination (Join-Path $fixture ('tests\' + $file))
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'mock_openai_tool_server.mjs') -Destination (Join-Path $fixture 'tests\mock_openai_tool_server.mjs')
    return $fixture
}

function Start-GodotChild {
    param([Parameter(Mandatory = $true)][string]$Fixture, [Parameter(Mandatory = $true)]$Provider)
    $resultPath = Assert-FixturePath (Join-Path $Fixture 'native-result.json')
    $sessionPath = Assert-FixturePath (Join-Path $Fixture '.bridge-session\bridge-session.json')
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = [IO.Path]::GetFullPath($Godot)
    $info.WorkingDirectory = $Fixture
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.EnvironmentVariables['PATH'] = $restrictedPath
    $info.EnvironmentVariables['GODOT_MCP_SESSION_FILE'] = $sessionPath
    $info.EnvironmentVariables['GODOT_PROJECT_PATH'] = $Fixture
    $info.EnvironmentVariables['GODOT_MCP_E2E_PROVIDER_BASE_URL'] = $Provider.BaseUrl
    $info.EnvironmentVariables['GODOT_NATIVE_E2E_RESULT_PATH'] = $resultPath
    $info.Arguments = '--headless --editor --path "' + $Fixture.Replace('"', '\"') + '" --script res://tests/opencode_native_multi_project_e2e_runner.gd'
    $process = [Diagnostics.Process]::Start($info)
    return [PSCustomObject]@{ Fixture = $Fixture; Process = $process; Out = $process.StandardOutput.ReadToEndAsync(); Err = $process.StandardError.ReadToEndAsync(); Result = $resultPath }
}

function Assert-Result {
    param($Child, [Parameter(Mandatory = $true)][string]$ExpectedName)
    if (-not (Test-Path -LiteralPath $Child.Result -PathType Leaf)) { throw "Native runner did not produce result: $($Child.Result)" }
    $result = Get-Content -LiteralPath $Child.Result -Raw | ConvertFrom-Json
    if (-not $result.ok) { throw "Native runner reported failures for ${ExpectedName}: $($result.failures -join '; ')" }
    if ($result.project_name -ne ('Native ' + $ExpectedName)) { throw "Unexpected project result name: $($result.project_name)" }
    if ($result.integration_mode -ne 'native') { throw "Runner did not retain explicit native mode for $ExpectedName" }
    if ([string]::IsNullOrWhiteSpace($result.discovery_endpoint) -or $result.discovery_parent_pid -ne $result.editor_pid) { throw "Native discovery did not bind the correct Godot editor for $ExpectedName" }
    foreach ($property in @('session_removed', 'discovery_removed', 'mcp_ownership_absent')) {
        if (-not $result.cleanup.$property) { throw "Native cleanup did not attest $property for $ExpectedName" }
    }
    return $result
}

if (-not $IsWindows -and $env:OS -ne 'Windows_NT') { throw 'This test is intentionally restricted to Windows x86_64 packaged payloads.' }
if (-not (Test-Path -LiteralPath $Godot -PathType Leaf)) { throw "Godot executable not found: $Godot" }
foreach ($path in @((Join-Path $payloadSource 'opencode.exe'), $nativeArtifact, $nativeManifest)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Native E2E prerequisite is missing: $path" }
}
$manifest = Get-Content -LiteralPath $nativeManifest -Raw | ConvertFrom-Json
if ($manifest.schema -ne 'opencode-godot-native-plugin-manifest' -or $manifest.plugin.id -ne 'godot-tools' -or $manifest.plugin.path -ne 'runtime/opencode-plugins/godot-tools.js') {
    throw 'Native plugin manifest is not the expected packaged godot-tools file-plugin contract.'
}
if ((Get-FileHash -LiteralPath $nativeArtifact -Algorithm SHA256).Hash.ToLowerInvariant() -ne ([string]$manifest.plugin.sha256).Replace('sha256:', '').ToLowerInvariant()) {
    throw 'Native plugin artifact does not match its packaged manifest checksum.'
}
$sourceHashes = @{
    OpenCode = (Get-FileHash -LiteralPath (Join-Path $payloadSource 'opencode.exe') -Algorithm SHA256).Hash
    NativeArtifact = (Get-FileHash -LiteralPath $nativeArtifact -Algorithm SHA256).Hash
    NativeManifest = (Get-FileHash -LiteralPath $nativeManifest -Algorithm SHA256).Hash
}

try {
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    # Keep the concurrent black-box harness shell-encoding neutral; a separate
    # bundle test covers Unicode import paths. Spaces and a literal percent
    # still prove URI/path routing is not command-line tokenized.
    $fixtureA = New-ProjectFixture 'project A % '
    $fixtureB = New-ProjectFixture 'project B % '
    $providerA = Start-Provider $fixtureA
    $providerB = Start-Provider $fixtureB
    $providers += @($providerA, $providerB)
    $children += @(Start-GodotChild $fixtureA $providerA)
    $children += @(Start-GodotChild $fixtureB $providerB)
    $mcpSeen = @()
    while ($true) {
        $alive = @($children | Where-Object { -not $_.Process.HasExited })
        $mcpSeen += @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -eq 'godot-mcp.exe' -and $_.CommandLine -and $_.CommandLine.Replace('\', '/').ToLowerInvariant().Contains($root.Replace('\', '/').ToLowerInvariant())
        })
        if ($alive.Count -eq 0) { break }
        if ($wallClock.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw "Concurrent native E2E exceeded $TimeoutSeconds seconds." }
        Start-Sleep -Milliseconds 100
    }
    foreach ($child in $children) {
        $out = Read-TaskText $child.Out; $err = Read-TaskText $child.Err
        Write-Host "[native-e2e][$($child.Fixture)]`n$out`n$err"
        $combined = $out + "`n" + $err
        $hasMarker = $combined -match 'OPENCODE_GODOT_NATIVE_MULTI_PROJECT_E2E_OK'
        if (-not $hasMarker) { throw "Godot native runner omitted success marker: $($child.Fixture)" }
        $runnerFailure = $combined -match '(?im)(SCRIPT ERROR|TEST FAILURE|native runner failure)'
        if ($runnerFailure) { throw "Godot native runner reported a script/test failure: $($child.Fixture)" }
        if ($child.Process.ExitCode -ne 0) {
            # This exact custom Mono editor emits a non-test C# plugin error at
            # shutdown when its local .NET SDK is absent. Accept no broader
            # nonzero-exit class: the runner marker, result file, and absence
            # of all script/test failures remain mandatory.
            $knownMonoSdkNoise = $combined -match 'GodotSharpEditor' -and $combined -match "\.NET Sdk not found\. The required version is '9\.0\.13'\."
            # Godot's progress renderer can inject ANSI CSI sequences into the
            # captured 4.3 console output. Normalize first, then use an exact
            # line allowlist: every ERROR line must be a RID shutdown leak.
            $plainCombined = [regex]::Replace($combined, "`e\[[0-?]*[ -/]*[@-~]", '')
            $plainLines = @($plainCombined -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 })
            $has43Version = @($plainLines | Where-Object { $_ -eq 'Godot Engine v4.3.stable.official.77dcf97d8 - https://godotengine.org' }).Count -eq 1
            $has43Canvas = @($plainLines | Where-Object { $_ -match '^WARNING: \d+ RIDs? of type "Canvas" were leaked\.$' }).Count -ge 1
            $has43CanvasItem = @($plainLines | Where-Object { $_ -match '^WARNING: \d+ RIDs? of type "CanvasItem" were leaked\.$' }).Count -ge 1
            $has43ObjectDb = @($plainLines | Where-Object { $_ -match '^WARNING: ObjectDB instances leaked at exit' }).Count -ge 1
            $errorLines = @($plainLines | Where-Object { $_.StartsWith('ERROR:') })
            $unexpected43Errors = @($errorLines | Where-Object { $_ -notmatch "^ERROR: \d+ RID allocations of type '.+' were leaked at exit\.$" })
            $known43ShutdownLeakNoise = $child.Process.ExitCode -eq 1 -and
                $has43Version -and $has43Canvas -and $has43CanvasItem -and $has43ObjectDb -and
                $errorLines.Count -gt 0 -and $unexpected43Errors.Count -eq 0
            # Result validity is checked immediately after all child exit
            # classification by Assert-Result. Keeping that one authoritative
            # read avoids a race with the process/output drain here.
            if (-not $knownMonoSdkNoise -and -not $known43ShutdownLeakNoise) {
                throw "Godot native runner failed ($($child.Process.ExitCode)) for $($child.Fixture). known43 version=$has43Version canvas=$has43Canvas canvasItem=$has43CanvasItem objectDb=$has43ObjectDb errors=$($errorLines.Count) unexpectedErrors=$($unexpected43Errors.Count)"
            }
            if ($known43ShutdownLeakNoise) {
                Write-Warning "Accepting only the exact Godot 4.3 Canvas/CanvasItem/RID/ObjectDB shutdown-leak signature after successful native E2E: $($child.Fixture)"
            } else {
                Write-Warning "Accepting only the known GodotSharpEditor/.NET SDK 9.0.13 shutdown noise after successful native E2E: $($child.Fixture)"
            }
        }
    }
    if ($mcpSeen.Count -gt 0) { throw "Native mode started a forbidden godot-mcp sidecar: $($mcpSeen[0].CommandLine)" }
    $a = Assert-Result $children[0] 'project A % '
    $b = Assert-Result $children[1] 'project B % '
    foreach ($provider in $providers) {
        $requestLog = $provider.Ready + '.requests.log'
        if (-not (Test-Path -LiteralPath $requestLog -PathType Leaf) -or (Get-Content -LiteralPath $requestLog -Raw) -notmatch 'complex_schema=true') {
            throw "Native packaged file plugin did not expose godot_set_input_action's complex Zod schema to provider $($provider.Ready)."
        }
    }
    foreach ($field in @('canonical_project', 'session_path', 'discovery_path', 'owner_nonce', 'launch_nonce', 'daemon_pid', 'discovery_endpoint')) {
        if ([string]$a.$field -eq [string]$b.$field) { throw "Two native projects unexpectedly share $field." }
    }
    foreach ($pair in @($a, $b)) {
        $normalizedFixtureRoot = $root.Replace('\', '/').ToLowerInvariant()
        $canonicalProject = ([string]$pair.canonical_project).Replace('\', '/').ToLowerInvariant()
        $sessionPath = ([string]$pair.session_path).Replace('\', '/').ToLowerInvariant()
        if ($canonicalProject -ne $normalizedFixtureRoot -and -not $canonicalProject.StartsWith($normalizedFixtureRoot + '/')) { throw 'Native result canonical path escaped its fixture root.' }
        if ($sessionPath -ne $normalizedFixtureRoot -and -not $sessionPath.StartsWith($normalizedFixtureRoot + '/')) { throw 'Native session result did not remain fixture-scoped.' }
    }
    $leaked = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -in @('opencode.exe', 'godot-mcp.exe') -and $_.CommandLine -and $_.CommandLine.Replace('\', '/').ToLowerInvariant().Contains($root.Replace('\', '/').ToLowerInvariant())
    })
    if ($leaked.Count -gt 0) { throw "Native E2E leaked owned payload process: $($leaked[0].CommandLine)" }
    foreach ($name in $sourceHashes.Keys) {
        $path = if ($name -eq 'OpenCode') { Join-Path $payloadSource 'opencode.exe' } elseif ($name -eq 'NativeArtifact') { $nativeArtifact } else { $nativeManifest }
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $sourceHashes[$name]) { throw "Native E2E mutated source payload: $name" }
    }
    Write-Output 'OPENCODE_GODOT_NATIVE_MULTI_PROJECT_E2E_OK'
}
finally {
    foreach ($child in $children) { if ($child -and -not $child.Process.HasExited) { try { $child.Process.Kill() } catch {} } }
    Stop-OwnedFixtureProcesses -FixtureRoot $root
    foreach ($provider in $providers) { Stop-Provider $provider }
    if (Test-Path -LiteralPath $root) {
        $resolved = [IO.Path]::GetFullPath($root)
        if ($resolved.StartsWith($fixturePrefix, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
