param(
    [string]$Godot = 'E:\Code\godot\godot_work\bin\godot.windows.editor.x86_64.mono.console.exe',
    [string]$AddonRoot = '',
    [int]$TimeoutSeconds = 240
)

# Packaged native -> MCP integration-mode handoff. This is intentionally a
# separate wrapper from the MCP and native lifecycle regressions so it can hold
# at a native phase barrier and prove the forbidden sidecar is absent.
$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$addonSource = if ([String]::IsNullOrWhiteSpace($AddonRoot)) {
    Join-Path $repositoryRoot 'addons\opencode_godot'
} else {
    [IO.Path]::GetFullPath($AddonRoot)
}
$payloadSource = Join-Path $addonSource 'bin\windows-x86_64'
$fixturePrefix = Join-Path ([IO.Path]::GetTempPath()) 'opencode-godot-mode-switch % '
$fixtureRoot = [IO.Path]::GetFullPath(($fixturePrefix + '项目 % ' + [guid]::NewGuid().ToString('N')))
$restrictedPath = [IO.Path]::Combine($env:SystemRoot, 'System32') + ';' + [IO.Path]::Combine($env:SystemRoot, 'System32\WindowsPowerShell\v1.0')
$process = $null
$provider = $null

function Read-TaskText { param($Task) if ($null -eq $Task) { return '' }; try { $Task.Wait(5000) | Out-Null; if ($Task.IsCompleted) { return [string]$Task.Result } } catch {}; return '<capture timed out>' }
function Find-FixturePayloads {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Name)
    $needle = $Root.Replace('\', '/').ToLowerInvariant()
    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -eq $Name -and $_.CommandLine -and $_.CommandLine.Replace('\', '/').ToLowerInvariant().Contains($needle)
    })
}
function Normalize-PathForComparison {
    param([Parameter(Mandatory = $true)][string]$Path)
    # The event is untrusted test input until the exact payload path check
    # below succeeds. Preserve an invalid value as a guaranteed non-match so
    # the assertion reports the ownership defect instead of the wrapper
    # throwing from path canonicalization first.
    try { return [IO.Path]::GetFullPath($Path).Replace('\', '/').ToLowerInvariant() }
    catch { return "<invalid-path>:$Path" }
}
function Assert-LiveMcpSidecarFromEvent {
    param([Parameter(Mandatory = $true)]$Event, [Parameter(Mandatory = $true)][string]$Fixture)
    $sidecarPid = [int]$Event.sidecar_pid; $startedAt = [int64]$Event.sidecar_started_at_ms; $reportedPath = [string]$Event.sidecar_executable
    if ($sidecarPid -le 0 -or $startedAt -le 0 -or [string]::IsNullOrWhiteSpace($reportedPath)) { throw 'MCP ready event lacks a durable sidecar PID/start/executable identity.' }
    $expectedPath = Normalize-PathForComparison (Join-Path $Fixture 'addons\opencode_godot\bin\windows-x86_64\godot-mcp.exe')
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    while ($deadline.ElapsedMilliseconds -lt 5000) {
        $process = Get-CimInstance Win32_Process -Filter "ProcessId=$sidecarPid" -ErrorAction SilentlyContinue
        if ($process) {
            $actualPath = [string]$process.ExecutablePath
            if ([string]::IsNullOrWhiteSpace($actualPath)) { throw "MCP sidecar PID $sidecarPid has no readable ExecutablePath." }
            if ((Normalize-PathForComparison $actualPath) -ne $expectedPath) { throw "MCP sidecar PID $sidecarPid executable mismatches fixture payload: $actualPath" }
            return [PSCustomObject]@{ Pid = $sidecarPid; StartedAtMs = $startedAt; ExecutablePath = $actualPath }
        }
        Start-Sleep -Milliseconds 50
    }
    throw "Nonce-bound MCP sidecar PID $sidecarPid was not live during the bounded mcp_ready observation."
}
function Assert-SidecarExited {
    param([Parameter(Mandatory = $true)]$Identity)
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    while ($deadline.ElapsedMilliseconds -lt 5000) {
        if (-not (Get-CimInstance Win32_Process -Filter "ProcessId=$($Identity.Pid)" -ErrorAction SilentlyContinue)) { return }
        Start-Sleep -Milliseconds 50
    }
    throw "Saved MCP sidecar PID $($Identity.Pid) (started_at_ms=$($Identity.StartedAtMs)) remained live after normal cleanup."
}
function Stop-FixturePayloads {
    param([Parameter(Mandatory = $true)][string]$Root)
    foreach ($name in @('opencode.exe', 'godot-mcp.exe')) {
        foreach ($item in Find-FixturePayloads $Root $name) { try { Stop-Process -Id ([int]$item.ProcessId) -Force -ErrorAction SilentlyContinue } catch {} }
    }
}
function Read-JsonWhenReady {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { return $null }
}
function Test-AllowedGodotShutdownNoise {
    param([Parameter(Mandatory = $true)][int]$ExitCode, [Parameter(Mandatory = $true)][string]$Output)
    # Keep this aligned with the native multi-project wrapper. ANSI-free,
    # line-oriented classification means unknown ERROR output cannot be hidden
    # behind normal Godot editor shutdown noise.
    $plain = [regex]::Replace($Output, "`e\[[0-?]*[ -/]*[@-~]", '')
    $lines = @($plain -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 })
    $errors = @($lines | Where-Object { $_.StartsWith('ERROR:') })
    $ridPattern = "^ERROR: \d+ RID allocations of type '.+' were leaked at exit\.$"
    $sdkPattern = "^ERROR: \.NET Sdk not found\. The required version is '9\.0\.13'\.$"
    $has43Version = @($lines | Where-Object { $_ -eq 'Godot Engine v4.3.stable.official.77dcf97d8 - https://godotengine.org' }).Count -eq 1
    $has43Canvas = @($lines | Where-Object { $_ -match '^WARNING: \d+ RIDs? of type "Canvas" were leaked\.$' }).Count -ge 1
    $has43CanvasItem = @($lines | Where-Object { $_ -match '^WARNING: \d+ RIDs? of type "CanvasItem" were leaked\.$' }).Count -ge 1
    $has43ObjectDb = @($lines | Where-Object { $_ -match '^WARNING: ObjectDB instances leaked at exit' }).Count -ge 1
    $unexpected43 = @($errors | Where-Object { $_ -notmatch $ridPattern })
    $is43 = $ExitCode -eq 1 -and $has43Version -and $has43Canvas -and $has43CanvasItem -and $has43ObjectDb -and $errors.Count -gt 0 -and $unexpected43.Count -eq 0
    $hasSdk = @($lines | Where-Object { $_ -match $sdkPattern }).Count -eq 1
    $hasGodotSharp = $plain -match 'GodotSharpEditor'
    $unexpected47 = @($errors | Where-Object { $_ -notmatch $ridPattern -and $_ -notmatch $sdkPattern })
    $is47 = $ExitCode -eq 1 -and $hasGodotSharp -and $hasSdk -and $unexpected47.Count -eq 0
    return [PSCustomObject]@{
        Known = $is43 -or $is47; Kind = if ($is43) { 'Godot 4.3 Canvas/CanvasItem/RID/ObjectDB shutdown leak' } elseif ($is47) { 'GodotSharpEditor/.NET SDK 9.0.13 shutdown noise' } else { '' }
        ErrorCount = $errors.Count; Unexpected43 = $unexpected43.Count; Unexpected47 = $unexpected47.Count
    }
}
function Start-Provider {
    param([Parameter(Mandatory = $true)][string]$Fixture)
    $node = Get-Command node.exe -ErrorAction SilentlyContinue; if ($null -eq $node) { $node = Get-Command node -ErrorAction SilentlyContinue }
    if ($null -eq $node) { throw 'Node.js is required only as the external deterministic provider.' }
    $ready = Join-Path $Fixture 'mock-openai.ready.json'
    $script = Join-Path $Fixture 'tests\mock_openai_tool_server.mjs'
    $info = [Diagnostics.ProcessStartInfo]::new(); $info.FileName = $node.Source; $info.WorkingDirectory = $Fixture
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.Arguments = ('"' + $script.Replace('"', '\"') + '" "' + $ready.Replace('"', '\"') + '" --require-complex-schema')
    $child = [Diagnostics.Process]::Start($info)
    $record = [PSCustomObject]@{ Process = $child; Out = $child.StandardOutput.ReadToEndAsync(); Err = $child.StandardError.ReadToEndAsync(); Ready = $ready }
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    while ($deadline.ElapsedMilliseconds -lt 10000) {
        $json = Read-JsonWhenReady $ready
        if ($json -and $json.hostname -eq '127.0.0.1' -and [int]$json.port -gt 0) { $record | Add-Member BaseUrl ([string]$json.base_url); return $record }
        if ($child.HasExited) { throw "Mock provider exited: $(Read-TaskText $record.Out) $(Read-TaskText $record.Err)" }
        Start-Sleep -Milliseconds 50
    }
    throw 'Mock provider did not become ready.'
}

if (-not $IsWindows -and $env:OS -ne 'Windows_NT') { throw 'Windows x86_64 packaged payload test only.' }
if (-not (Test-Path -LiteralPath $Godot -PathType Leaf)) { throw "Godot executable not found: $Godot" }
foreach ($path in @((Join-Path $payloadSource 'opencode.exe'), (Join-Path $payloadSource 'godot-mcp.exe'), (Join-Path $addonSource 'runtime\opencode-plugins\godot-tools.js'), (Join-Path $addonSource 'runtime\opencode-plugins\godot-tools.manifest.json'))) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Mode-switch prerequisite missing: $path" }
}

try {
    New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixture\project.godot') -Destination (Join-Path $fixtureRoot 'project.godot')
    $projectPath = Join-Path $fixtureRoot 'project.godot'
    $projectText = (Get-Content -LiteralPath $projectPath -Raw).Replace('config/name="Godot MCP Bridge Test"', 'config/name="Godot Integration Mode Switch Test"').Replace('enabled=PackedStringArray("res://addons/godot_mcp/plugin.cfg")', 'enabled=PackedStringArray()')
    Set-Content -LiteralPath $projectPath -Value $projectText -NoNewline
    New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'addons') -Force | Out-Null
    Copy-Item -LiteralPath $addonSource -Destination (Join-Path $fixtureRoot 'addons\opencode_godot') -Recurse
    New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'tests') -Force | Out-Null
    foreach ($file in @('opencode_integration_mode_switch_e2e_runner.gd', 'opencode_e2e_test_lifecycle.gd', 'opencode_e2e_test_editor_plugin.gd')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot ('fixture\tests\' + $file)) -Destination (Join-Path $fixtureRoot ('tests\' + $file))
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'mock_openai_tool_server.mjs') -Destination (Join-Path $fixtureRoot 'tests\mock_openai_tool_server.mjs')
    $provider = Start-Provider $fixtureRoot
    $eventPath = Join-Path $fixtureRoot 'mode-switch-event.json'; $continuePath = Join-Path $fixtureRoot 'continue-native-switch'; $resultPath = Join-Path $fixtureRoot 'mode-switch-result.json'
    $info = [Diagnostics.ProcessStartInfo]::new(); $info.FileName = [IO.Path]::GetFullPath($Godot); $info.WorkingDirectory = $fixtureRoot
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.EnvironmentVariables['PATH'] = $restrictedPath
    $info.EnvironmentVariables['GODOT_PROJECT_PATH'] = $fixtureRoot
    $info.EnvironmentVariables['GODOT_MCP_SESSION_FILE'] = Join-Path $fixtureRoot '.bridge-session\bridge-session.json'
    $info.EnvironmentVariables['GODOT_MCP_E2E_PROVIDER_BASE_URL'] = $provider.BaseUrl
    $info.EnvironmentVariables['GODOT_MODE_SWITCH_EVENT_PATH'] = $eventPath
    $info.EnvironmentVariables['GODOT_MODE_SWITCH_CONTINUE_PATH'] = $continuePath
    $info.EnvironmentVariables['GODOT_MODE_SWITCH_RESULT_PATH'] = $resultPath
    $info.Arguments = '--headless --editor --path "' + $fixtureRoot.Replace('"', '\"') + '" --script res://tests/opencode_integration_mode_switch_e2e_runner.gd'
    $process = [Diagnostics.Process]::Start($info); $out = $process.StandardOutput.ReadToEndAsync(); $err = $process.StandardError.ReadToEndAsync()
    $nativeObserved = $false; $mcpObserved = $false; $mcpIdentity = $null; $deadline = [Diagnostics.Stopwatch]::StartNew()
    while (-not $process.HasExited) {
        $event = Read-JsonWhenReady $eventPath
        if ($event -and $event.phase -eq 'native_ready' -and -not $nativeObserved) {
            $nativeObserved = $true
            if ((Find-FixturePayloads $fixtureRoot 'godot-mcp.exe').Count -ne 0) { throw 'Native phase started a forbidden godot-mcp.exe sidecar.' }
            Set-Content -LiteralPath $continuePath -Value 'native phase observed' -NoNewline
        }
        if ($event -and $event.phase -eq 'mcp_ready') {
            $mcpObserved = $true
            if ($null -eq $mcpIdentity) { $mcpIdentity = Assert-LiveMcpSidecarFromEvent -Event $event -Fixture $fixtureRoot }
        }
        if ($deadline.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw "Integration-mode switch E2E exceeded $TimeoutSeconds seconds." }
        Start-Sleep -Milliseconds 75
    }
    $stdout = Read-TaskText $out; $stderr = Read-TaskText $err; Write-Host "[mode-switch]`n$stdout`n$stderr"
    $combined = $stdout + "`n" + $stderr
    if ($combined -notmatch 'OPENCODE_GODOT_INTEGRATION_MODE_SWITCH_E2E_OK') { throw 'Godot mode-switch success marker missing.' }
    if ($combined -match '(?im)(SCRIPT ERROR|TEST FAILURE|mode-switch runner failure)') { throw 'Godot mode-switch runner reported a script/test failure.' }
    if ($process.ExitCode -ne 0) {
        $shutdownNoise = Test-AllowedGodotShutdownNoise -ExitCode $process.ExitCode -Output $combined
        if (-not $shutdownNoise.Known) { throw "Godot mode-switch runner failed with exit $($process.ExitCode). errors=$($shutdownNoise.ErrorCount) unexpected43=$($shutdownNoise.Unexpected43) unexpected47=$($shutdownNoise.Unexpected47)" }
        Write-Warning "Accepting only the known $($shutdownNoise.Kind) after successful mode-switch E2E."
    }
    $result = Read-JsonWhenReady $resultPath
    if (-not $result -or -not $result.ok) { throw "Mode-switch runner reported failure: $($result.failures -join '; ')" }
    if (-not $nativeObserved -or -not $mcpObserved -or $null -eq $mcpIdentity) { throw 'Wrapper did not observe both native and MCP phases with a live nonce-bound sidecar.' }
    $requests = Join-Path $fixtureRoot 'mock-openai.ready.json.requests.log'
    if (-not (Test-Path -LiteralPath $requests) -or (Get-Content -LiteralPath $requests -Raw) -notmatch 'complex_schema=true') { throw 'Packaged daemon did not expose the required complex Zod tool schema to the provider.' }
    if ((Find-FixturePayloads $fixtureRoot 'opencode.exe').Count -ne 0 -or (Find-FixturePayloads $fixtureRoot 'godot-mcp.exe').Count -ne 0) { throw 'Payload process leaked after normal mode-switch exit.' }
    Assert-SidecarExited -Identity $mcpIdentity
    Write-Output 'OPENCODE_GODOT_INTEGRATION_MODE_SWITCH_E2E_OK'
}
finally {
    if ($process -and -not $process.HasExited) { try { $process.Kill() } catch {} }
    Stop-FixturePayloads $fixtureRoot
    if ($provider) { if (-not $provider.Process.HasExited) { try { $provider.Process.Kill() } catch {} }; try { $provider.Process.WaitForExit(5000) | Out-Null } catch {} }
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
