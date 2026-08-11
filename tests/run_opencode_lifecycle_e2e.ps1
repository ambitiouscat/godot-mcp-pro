param(
    [string]$Godot = 'E:\Code\godot\godot_work\bin\godot.windows.editor.x86_64.mono.console.exe',
    [int]$TimeoutSeconds = 210
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixturePrefix = Join-Path $tempRoot 'opencode-godot-lifecycle-e2e % '
$fixtureRoot = [IO.Path]::GetFullPath(($fixturePrefix + [guid]::NewGuid().ToString('N')))
$externalSentinelPath = [IO.Path]::GetFullPath((Join-Path $tempRoot ('opencode-godot-lifecycle-e2e-external-' + [guid]::NewGuid().ToString('N') + '.txt')))
$stdoutPath = Join-Path $fixtureRoot 'godot.stdout.log'
$stderrPath = Join-Path $fixtureRoot 'godot.stderr.log'
$stageLogPath = Join-Path $fixtureRoot 'e2e-stage.log'
$providerReadyPath = Join-Path $fixtureRoot 'mock-openai.ready.json'
$providerLogPath = Join-Path $fixtureRoot 'mock-openai.stdout.log'
$restrictedPath = [IO.Path]::Combine($env:SystemRoot, 'System32') + ';' + [IO.Path]::Combine($env:SystemRoot, 'System32\WindowsPowerShell\v1.0')
$godotProcess = $null
$stdoutTask = $null
$stderrTask = $null
$providerProcess = $null
$providerOutputTask = $null
$originalEnvironment = @{}
$wallClock = [Diagnostics.Stopwatch]::StartNew()

function Assert-TestPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $resolved = [IO.Path]::GetFullPath($Path)
    if (-not $resolved.StartsWith($fixturePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to use a path outside the isolated lifecycle fixture: $resolved"
    }
    return $resolved
}

function Read-Log {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return Get-Content -LiteralPath $Path -Raw
    }
    return '<no captured Godot output>'
}

function Redact-Log {
    param([AllowEmptyString()][string]$Text)
    if ($null -eq $Text) { return '' }
    $redacted = $Text
    $redacted = [regex]::Replace($redacted, '(?im)(Authorization:\s*Basic\s+)[^\s\r\n]+', '$1<redacted>')
    $redacted = [regex]::Replace($redacted, '(?im)(["'']?password["'']?\s*[:=]\s*["'']?)[^"''}\s,]+', '$1<redacted>')
    $redacted = $redacted.Replace('godot-e2e-test-key', '<redacted>')
    return $redacted
}

function Stop-MockProvider {
    if ($script:providerProcess -ne $null -and -not $script:providerProcess.HasExited) {
        try { $script:providerProcess.Kill() } catch {}
        try { $script:providerProcess.WaitForExit(5000) | Out-Null } catch {}
    }
    if ($script:providerProcess -ne $null -and -not $script:providerProcess.HasExited) {
        throw "Fixture-owned mock OpenAI responder PID $($script:providerProcess.Id) leaked after bounded shutdown."
    }
}

function Start-MockProvider {
    $node = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($null -eq $node) { $node = Get-Command node -ErrorAction SilentlyContinue }
    if ($null -eq $node) { throw 'Node.js is required only as the external local OpenAI-compatible test responder.' }
    $scriptPath = Assert-TestPath (Join-Path $fixtureRoot 'tests\mock_openai_tool_server.mjs')
    $readyPath = Assert-TestPath $providerReadyPath
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $node.Source
    $info.WorkingDirectory = $fixtureRoot
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.Arguments = ('"' + $scriptPath.Replace('"', '\"') + '" "' + $readyPath.Replace('"', '\"') + '"')
    $script:providerProcess = [Diagnostics.Process]::Start($info)
    $script:providerOutputTask = $script:providerProcess.StandardOutput.ReadToEndAsync()
    $script:providerErrTask = $script:providerProcess.StandardError.ReadToEndAsync()
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    while ($deadline.ElapsedMilliseconds -lt 10000) {
        if (Test-Path -LiteralPath $readyPath -PathType Leaf) {
            try {
                $record = Get-Content -LiteralPath $readyPath -Raw | ConvertFrom-Json
                if ($record.hostname -eq '127.0.0.1' -and [int]$record.port -gt 0 -and [int]$record.port -le 65535 -and $record.base_url -eq ('http://127.0.0.1:' + [int]$record.port + '/v1')) {
                    # Keep progress output out of the function return value:
                    # the return is used verbatim as the descriptor base URL.
                    Write-Host "[E2E][mock-provider] ready port=$($record.port)"
                    return [string]$record.base_url
                }
            } catch {}
        }
        if ($script:providerProcess.HasExited) {
            $providerOut = Redact-Log (Resolve-OutputTask $script:providerOutputTask)
            $providerErr = Redact-Log (Resolve-OutputTask $script:providerErrTask)
            throw "Mock OpenAI responder exited during startup.`n$providerOut`n$providerErr"
        }
        Start-Sleep -Milliseconds 50
    }
    $providerOut = Redact-Log (Resolve-OutputTask $script:providerOutputTask)
    $providerErr = Redact-Log (Resolve-OutputTask $script:providerErrTask)
    throw "Mock OpenAI responder did not publish a valid loopback ready record within 10 seconds.`n$providerOut`n$providerErr"
}

function Resolve-OutputTask {
    param($Task)
    if ($null -eq $Task) { return '' }
    try {
        $Task.Wait(5000) | Out-Null
        if ($Task.IsCompleted) { return [string]$Task.Result }
    } catch {}
    return '<output capture timed out>'
}

function Capture-GodotOutput {
    param([switch]$TimedOut)
    if ($godotProcess -ne $null -and -not $godotProcess.HasExited) {
        Stop-OwnedProcesses -FixturePath $fixtureRoot
        try { $godotProcess.WaitForExit(5000) | Out-Null } catch {}
    }
    $stdout = Redact-Log (Resolve-OutputTask $stdoutTask)
    $stderr = Redact-Log (Resolve-OutputTask $stderrTask)
    if (Test-Path -LiteralPath $fixtureRoot -PathType Container) {
        Set-Content -LiteralPath $stdoutPath -Value $stdout -NoNewline
        Set-Content -LiteralPath $stderrPath -Value $stderr -NoNewline
    }
    $combined = $stdout + "`n" + $stderr
    if ($TimedOut) {
        Write-Host "[E2E][wrapper][timeout] Godot exceeded the bounded timeout; owned processes were stopped before output capture."
    }
    Write-Host $stdout
    Write-Host $stderr
    if (Test-Path -LiteralPath $stageLogPath -PathType Leaf) {
        Write-Host '[E2E][wrapper][stage-log]'
        Write-Host (Get-Content -LiteralPath $stageLogPath -Raw)
    }
    return $combined
}

function Invoke-GodotCheckOnly {
    $checkInfo = [Diagnostics.ProcessStartInfo]::new()
    $checkInfo.FileName = [IO.Path]::GetFullPath($Godot)
    $checkInfo.WorkingDirectory = $fixtureRoot
    $checkInfo.UseShellExecute = $false
    $checkInfo.CreateNoWindow = $true
    $checkInfo.RedirectStandardOutput = $true
    $checkInfo.RedirectStandardError = $true
    $checkInfo.EnvironmentVariables['PATH'] = $restrictedPath
    $quotedFixture = '"' + $fixtureRoot.Replace('"', '\"') + '"'
    $checkInfo.Arguments = "--headless --path $quotedFixture --check-only --script res://tests/opencode_lifecycle_e2e_runner.gd"
    $check = [Diagnostics.Process]::Start($checkInfo)
    $checkOutTask = $check.StandardOutput.ReadToEndAsync()
    $checkErrTask = $check.StandardError.ReadToEndAsync()
    if (-not $check.WaitForExit(30000)) {
        try { $check.Kill() } catch {}
        try { $check.WaitForExit(5000) | Out-Null } catch {}
        $checkOut = Redact-Log (Resolve-OutputTask $checkOutTask)
        $checkErr = Redact-Log (Resolve-OutputTask $checkErrTask)
        throw "Godot --check-only exceeded its bounded 30 second timeout.`n$checkOut`n$checkErr"
    }
    $checkOut = Redact-Log (Resolve-OutputTask $checkOutTask)
    $checkErr = Redact-Log (Resolve-OutputTask $checkErrTask)
    $checkLog = $checkOut + "`n" + $checkErr
    Write-Output '[E2E][wrapper][check-only]'
    Write-Output $checkLog
    if ($checkLog -match '(?im)(SCRIPT ERROR|Failed to load script|Parse Error|Parse error)') {
        throw "Godot --check-only reported a script parse/load error.`n$checkLog"
    }
    if ($check.ExitCode -ne 0) {
        throw "Godot --check-only failed with exit code $($check.ExitCode).`n$checkLog"
    }
}

function Stop-OwnedProcesses {
    param([Parameter(Mandatory = $true)][string]$FixturePath)
    $needle = $FixturePath.Replace('\', '/').ToLowerInvariant()
    $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -in @('opencode.exe', 'godot-mcp.exe') -and
        $_.CommandLine -and
        $_.CommandLine.Replace('\', '/').ToLowerInvariant().Contains($needle)
    })
    foreach ($process in $processes) {
        try { Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue } catch {}
    }
    if ($godotProcess -ne $null -and -not $godotProcess.HasExited) {
        try { $godotProcess.Kill() } catch {}
        try { $godotProcess.WaitForExit(5000) | Out-Null } catch {}
    }
}

function Find-OwnedPayloadProcesses {
    param([Parameter(Mandatory = $true)][string]$FixturePath)
    $needle = $FixturePath.Replace('\', '/').ToLowerInvariant()
    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -in @('opencode.exe', 'godot-mcp.exe') -and
        $_.CommandLine -and
        $_.CommandLine.Replace('\', '/').ToLowerInvariant().Contains($needle)
    })
}

if (-not $IsWindows -and $env:OS -ne 'Windows_NT') {
    throw 'This test is intentionally restricted to Windows x86_64 packaged payloads.'
}
if (-not (Test-Path -LiteralPath $Godot -PathType Leaf)) {
    throw "Godot executable not found: $Godot"
}

$addonSource = Join-Path $repositoryRoot 'addons\opencode_godot'
$payloadSource = Join-Path $addonSource 'bin\windows-x86_64'
foreach ($payload in @('opencode.exe', 'godot-mcp.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $payloadSource $payload) -PathType Leaf)) {
        throw "Required packaged Windows x86_64 payload is missing: $payload"
    }
}
$sourceManifestHash = (Get-FileHash -LiteralPath (Join-Path $addonSource 'payload-manifest.json') -Algorithm SHA256).Hash
$sourceOpenCodeHash = (Get-FileHash -LiteralPath (Join-Path $payloadSource 'opencode.exe') -Algorithm SHA256).Hash
$sourceMcpHash = (Get-FileHash -LiteralPath (Join-Path $payloadSource 'godot-mcp.exe') -Algorithm SHA256).Hash

foreach ($name in @('GODOT_MCP_SESSION_FILE', 'GODOT_PROJECT_PATH', 'GODOT_MCP_E2E_EXTERNAL_SENTINEL', 'GODOT_MCP_E2E_STAGE_LOG', 'GODOT_MCP_E2E_EXPECTED_PATH', 'GODOT_MCP_E2E_PROVIDER_BASE_URL')) {
    $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

try {
    New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
    Set-Content -LiteralPath $externalSentinelPath -Value 'unrelated-test-state-must-survive' -NoNewline
    Write-Output "[E2E][wrapper] fixture=$fixtureRoot"

    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixture\project.godot') -Destination (Join-Path $fixtureRoot 'project.godot')
    $projectFile = Join-Path $fixtureRoot 'project.godot'
    (Get-Content -LiteralPath $projectFile -Raw).Replace('enabled=PackedStringArray("res://addons/godot_mcp/plugin.cfg")', 'enabled=PackedStringArray()') | Set-Content -LiteralPath $projectFile -NoNewline
    New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'addons') -Force | Out-Null
    Copy-Item -LiteralPath $addonSource -Destination (Join-Path $fixtureRoot 'addons\opencode_godot') -Recurse
    New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'tests') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixture\tests\opencode_lifecycle_e2e_runner.gd') -Destination (Join-Path $fixtureRoot 'tests\opencode_lifecycle_e2e_runner.gd')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixture\tests\opencode_e2e_test_lifecycle.gd') -Destination (Join-Path $fixtureRoot 'tests\opencode_e2e_test_lifecycle.gd')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixture\tests\opencode_e2e_test_editor_plugin.gd') -Destination (Join-Path $fixtureRoot 'tests\opencode_e2e_test_editor_plugin.gd')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'mock_openai_tool_server.mjs') -Destination (Join-Path $fixtureRoot 'tests\mock_openai_tool_server.mjs')

    $sessionPath = Join-Path $fixtureRoot '.bridge-session\bridge-session.json'
    [Environment]::SetEnvironmentVariable('GODOT_MCP_SESSION_FILE', $sessionPath, 'Process')
    [Environment]::SetEnvironmentVariable('GODOT_PROJECT_PATH', $fixtureRoot, 'Process')
    [Environment]::SetEnvironmentVariable('GODOT_MCP_E2E_EXTERNAL_SENTINEL', $externalSentinelPath, 'Process')
    [Environment]::SetEnvironmentVariable('GODOT_MCP_E2E_STAGE_LOG', $stageLogPath, 'Process')
    [Environment]::SetEnvironmentVariable('GODOT_MCP_E2E_EXPECTED_PATH', $restrictedPath, 'Process')
    $providerBaseUrl = Start-MockProvider
    [Environment]::SetEnvironmentVariable('GODOT_MCP_E2E_PROVIDER_BASE_URL', $providerBaseUrl, 'Process')

    Invoke-GodotCheckOnly
	$remainingMilliseconds = ($TimeoutSeconds * 1000) - [int]$wallClock.ElapsedMilliseconds
	if ($remainingMilliseconds -le 0) {
		throw "Godot lifecycle runner has no remaining wall-clock budget after --check-only."
	}

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = [IO.Path]::GetFullPath($Godot)
    $startInfo.WorkingDirectory = $fixtureRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables['PATH'] = $restrictedPath
    $quotedFixture = '"' + $fixtureRoot.Replace('"', '\"') + '"'
    $startInfo.Arguments = "--headless --editor --path $quotedFixture --script res://tests/opencode_lifecycle_e2e_runner.gd"
    $godotProcess = [Diagnostics.Process]::Start($startInfo)
    $stdoutTask = $godotProcess.StandardOutput.ReadToEndAsync()
    $stderrTask = $godotProcess.StandardError.ReadToEndAsync()
    if (-not $godotProcess.WaitForExit($remainingMilliseconds)) {
        $timeoutLog = Capture-GodotOutput -TimedOut
        throw "Godot lifecycle runner exceeded the bounded $TimeoutSeconds second timeout.`n$timeoutLog"
    }
    $combinedLog = Capture-GodotOutput
    if ($combinedLog -match '(?im)(SCRIPT ERROR|Failed to load script|Parse Error|Parse error)') {
        throw "Godot reported a script parse/load error even though the process exited.\n$combinedLog"
    }
    if ($godotProcess.ExitCode -ne 0) {
        throw "Godot lifecycle runner failed with exit code $($godotProcess.ExitCode).\n$combinedLog"
    }
    if ($combinedLog -notmatch 'OPENCODE_GODOT_LIFECYCLE_E2E_OK') {
        throw "Godot lifecycle runner did not publish its success marker.\n$combinedLog"
    }
    if ($combinedLog -notmatch 'OPENCODE_GODOT_TOOL_E2E_OK') {
        throw "Godot lifecycle runner did not publish the packaged tool success marker.\n$combinedLog"
    }

    $ownedAfterExit = @(Find-OwnedPayloadProcesses -FixturePath $fixtureRoot)
    if ($ownedAfterExit.Count -gt 0) {
        $descriptions = ($ownedAfterExit | ForEach-Object { "PID $($_.ProcessId): $($_.CommandLine)" }) -join [Environment]::NewLine
        throw "Owned OpenCode/MCP processes leaked after normal stop:\n$descriptions"
    }
    $manifestHashAfter = (Get-FileHash -LiteralPath (Join-Path $addonSource 'payload-manifest.json') -Algorithm SHA256).Hash
    $openCodeHashAfter = (Get-FileHash -LiteralPath (Join-Path $payloadSource 'opencode.exe') -Algorithm SHA256).Hash
    $mcpHashAfter = (Get-FileHash -LiteralPath (Join-Path $payloadSource 'godot-mcp.exe') -Algorithm SHA256).Hash
    if ($sourceManifestHash -ne $manifestHashAfter -or $sourceOpenCodeHash -ne $openCodeHashAfter -or $sourceMcpHash -ne $mcpHashAfter) {
        throw 'The lifecycle test mutated an external addon manifest or packaged payload.'
    }
    Write-Output 'OPENCODE_GODOT_LIFECYCLE_E2E_PROCESS_LEAK_CHECK_OK'
}
finally {
    [Environment]::SetEnvironmentVariable('GODOT_MCP_SESSION_FILE', $originalEnvironment['GODOT_MCP_SESSION_FILE'], 'Process')
    [Environment]::SetEnvironmentVariable('GODOT_PROJECT_PATH', $originalEnvironment['GODOT_PROJECT_PATH'], 'Process')
    [Environment]::SetEnvironmentVariable('GODOT_MCP_E2E_EXTERNAL_SENTINEL', $originalEnvironment['GODOT_MCP_E2E_EXTERNAL_SENTINEL'], 'Process')
    [Environment]::SetEnvironmentVariable('GODOT_MCP_E2E_STAGE_LOG', $originalEnvironment['GODOT_MCP_E2E_STAGE_LOG'], 'Process')
    [Environment]::SetEnvironmentVariable('GODOT_MCP_E2E_EXPECTED_PATH', $originalEnvironment['GODOT_MCP_E2E_EXPECTED_PATH'], 'Process')
    [Environment]::SetEnvironmentVariable('GODOT_MCP_E2E_PROVIDER_BASE_URL', $originalEnvironment['GODOT_MCP_E2E_PROVIDER_BASE_URL'], 'Process')
    Stop-MockProvider
    if ($fixtureRoot -and (Test-Path -LiteralPath $fixtureRoot)) {
        Stop-OwnedProcesses -FixturePath $fixtureRoot
        $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
        if ($resolvedFixture.StartsWith($fixturePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedFixture -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if ($externalSentinelPath -and (Test-Path -LiteralPath $externalSentinelPath)) {
        Remove-Item -LiteralPath $externalSentinelPath -Force -ErrorAction SilentlyContinue
    }
}
