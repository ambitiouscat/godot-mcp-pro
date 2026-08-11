param(
    [string]$Godot = 'E:\Code\godot\godot_work\bin\godot.windows.editor.x86_64.mono.console.exe',
    [string]$ProtocolFixture = ''
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixtureRoot = [IO.Path]::GetFullPath((Join-Path $tempRoot ("godot-mcp-pro-tests-" + [guid]::NewGuid().ToString('N'))))

if (-not $fixtureRoot.StartsWith((Join-Path $tempRoot 'godot-mcp-pro-tests-'), [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to use unexpected fixture path: $fixtureRoot"
}
if (-not (Test-Path -LiteralPath $Godot -PathType Leaf)) {
    throw "Godot executable not found: $Godot"
}

$priorExternalPid = [Environment]::GetEnvironmentVariable('GODOT_MCP_EXTERNAL_TEST_PID', 'Process')
$priorExternalStartedAt = [Environment]::GetEnvironmentVariable('GODOT_MCP_EXTERNAL_TEST_STARTED_AT_MS', 'Process')
$powershellStartedAtMs = ([DateTimeOffset](Get-Process -Id $PID).StartTime).ToUnixTimeMilliseconds()
[Environment]::SetEnvironmentVariable('GODOT_MCP_EXTERNAL_TEST_PID', [string]$PID, 'Process')
[Environment]::SetEnvironmentVariable('GODOT_MCP_EXTERNAL_TEST_STARTED_AT_MS', [string]$powershellStartedAtMs, 'Process')

try {
    New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixture\project.godot') -Destination $fixtureRoot
    $testDestination = Join-Path $fixtureRoot 'tests'
    New-Item -ItemType Directory -Path $testDestination -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixture\tests\bridge_protocol_runner.gd') -Destination $testDestination
    $localFixture = Join-Path $PSScriptRoot 'fixtures\bridge-protocol-v1.json'
    $selectedFixture = $localFixture
    if (-not [string]::IsNullOrWhiteSpace($ProtocolFixture)) {
        $selectedFixture = [IO.Path]::GetFullPath($ProtocolFixture)
        $localHash = (Get-FileHash -LiteralPath $localFixture -Algorithm SHA256).Hash
        $canonicalHash = (Get-FileHash -LiteralPath $selectedFixture -Algorithm SHA256).Hash
        if ($localHash -ne $canonicalHash) {
            throw 'Generated Godot protocol fixture differs from the canonical TypeScript fixture'
        }
    }
    $fixtureDestination = Join-Path $fixtureRoot 'tests\fixtures'
    New-Item -ItemType Directory -Path $fixtureDestination -Force | Out-Null
    Copy-Item -LiteralPath $selectedFixture -Destination (Join-Path $fixtureDestination 'bridge-protocol-v1.json')
    $addonDestination = Join-Path $fixtureRoot 'addons\godot_mcp'
    New-Item -ItemType Directory -Path $addonDestination -Force | Out-Null
    Copy-Item -Path (Join-Path $repositoryRoot 'addons\godot_mcp\*') -Destination $addonDestination -Recurse

    $scripts = @(
        'bridge_protocol_v1.gd',
        'bridge_process_identity.gd',
        'bridge_session_coordinator.gd',
        'runtime_service_controller.gd',
        'websocket_server.gd',
        'command_router.gd',
        'plugin.gd',
        'ui/status_panel.gd'
    )
    foreach ($script in $scripts) {
        & $Godot --headless --path $fixtureRoot --script ("res://addons/godot_mcp/" + $script) --check-only
        if ($LASTEXITCODE -ne 0) {
            throw "GDScript parse check failed for $script with exit code $LASTEXITCODE"
        }
    }

    & $Godot --headless --path $fixtureRoot --script res://tests/bridge_protocol_runner.gd
    if ($LASTEXITCODE -ne 0) {
        throw "Bridge protocol tests failed with exit code $LASTEXITCODE"
    }

    & $Godot --headless --editor --path $fixtureRoot --import
    if ($LASTEXITCODE -ne 0) {
        throw "Godot editor import failed with exit code $LASTEXITCODE"
    }
    if (Select-String -LiteralPath (Join-Path $fixtureRoot 'project.godot') -SimpleMatch '[autoload]' -Quiet) {
        throw 'Editor-only plugin startup unexpectedly added an autoload section'
    }
    Write-Output 'GODOT_BRIDGE_INTEGRATION_OK'
}
finally {
    [Environment]::SetEnvironmentVariable('GODOT_MCP_EXTERNAL_TEST_PID', $priorExternalPid, 'Process')
    [Environment]::SetEnvironmentVariable('GODOT_MCP_EXTERNAL_TEST_STARTED_AT_MS', $priorExternalStartedAt, 'Process')
    $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
    if ($resolvedFixture.StartsWith((Join-Path $tempRoot 'godot-mcp-pro-tests-'), [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedFixture)) {
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
    }
}
