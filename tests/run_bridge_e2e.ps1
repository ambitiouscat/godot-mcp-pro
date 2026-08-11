param(
    [Parameter(Mandatory = $true)]
    [string]$ServerBuild,
    [string]$Godot = 'E:\Code\godot\godot_work\bin\godot.windows.editor.x86_64.mono.console.exe'
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$resolvedServerBuild = [IO.Path]::GetFullPath($ServerBuild)
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixtureRoot = [IO.Path]::GetFullPath((Join-Path $tempRoot ("godot-mcp-pro-e2e-" + [guid]::NewGuid().ToString('N'))))
$fixturePrefix = Join-Path $tempRoot 'godot-mcp-pro-e2e-'

if (-not $fixtureRoot.StartsWith($fixturePrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to use unexpected fixture path: $fixtureRoot"
}
if (-not (Test-Path -LiteralPath $Godot -PathType Leaf)) {
    throw "Godot executable not found: $Godot"
}
if (-not (Test-Path -LiteralPath (Join-Path $resolvedServerBuild 'godot-connection.js') -PathType Leaf)) {
    throw "Built GodotConnection module not found in: $resolvedServerBuild"
}

$priorSessionFile = [Environment]::GetEnvironmentVariable('GODOT_MCP_SESSION_FILE', 'Process')
$priorProjectPath = [Environment]::GetEnvironmentVariable('GODOT_PROJECT_PATH', 'Process')
$priorBridgeTrace = [Environment]::GetEnvironmentVariable('GODOT_MCP_TRACE_BRIDGE', 'Process')
$godotProcess = $null
try {
    New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixture\project.godot') -Destination $fixtureRoot
    $addonDestination = Join-Path $fixtureRoot 'addons\godot_mcp'
    New-Item -ItemType Directory -Path $addonDestination -Force | Out-Null
    Copy-Item -Path (Join-Path $repositoryRoot 'addons\godot_mcp\*') -Destination $addonDestination -Recurse

    $sessionPath = Join-Path $fixtureRoot '.bridge-session\bridge-session.json'
    $godotLogPath = Join-Path $fixtureRoot 'godot-e2e.log'
    [Environment]::SetEnvironmentVariable('GODOT_MCP_SESSION_FILE', $sessionPath, 'Process')
    [Environment]::SetEnvironmentVariable('GODOT_PROJECT_PATH', $fixtureRoot, 'Process')
    [Environment]::SetEnvironmentVariable('GODOT_MCP_TRACE_BRIDGE', '1', 'Process')

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Godot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    # The Godot console launcher can fill redirected anonymous pipes before the
    # editor plugin initializes. Let Godot own its streams and persist a log for
    # failure diagnostics instead of leaving unread ProcessStartInfo pipes.
    $startInfo.RedirectStandardOutput = $false
    $startInfo.RedirectStandardError = $false
    # Windows PowerShell may run on .NET Framework, where ProcessStartInfo has
    # no ArgumentList collection. The generated fixture path is quoted here.
    # --quit-after counts engine iterations, not seconds. Keep it well beyond
    # the adversarial reconnect matrix and terminate this exact fixture child
    # in finally so a slower machine cannot invalidate the session mid-test.
    $startInfo.Arguments = "--headless --editor --path `"$fixtureRoot`" --log-file `"$godotLogPath`" --quit-after 12000"
    $godotProcess = [Diagnostics.Process]::Start($startInfo)

    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while (-not (Test-Path -LiteralPath $sessionPath -PathType Leaf)) {
        if ($godotProcess.HasExited) {
            $godotLog = if (Test-Path -LiteralPath $godotLogPath) { Get-Content -LiteralPath $godotLogPath -Raw } else { '<no Godot log>' }
            throw "Godot exited before publishing the session contract.`n$godotLog"
        }
        if ([DateTime]::UtcNow -ge $deadline) {
            $godotLog = if (Test-Path -LiteralPath $godotLogPath) { Get-Content -LiteralPath $godotLogPath -Raw } else { '<no Godot log>' }
            throw "Timed out waiting for Godot session contract: $sessionPath`n$godotLog"
        }
        Start-Sleep -Milliseconds 100
    }

    & node (Join-Path $PSScriptRoot 'bridge_e2e_client.mjs') $resolvedServerBuild $fixtureRoot
    if ($LASTEXITCODE -ne 0) {
        $godotLog = if (Test-Path -LiteralPath $godotLogPath) { Get-Content -LiteralPath $godotLogPath -Raw } else { '<no Godot log>' }
        throw "Cross-language bridge client failed with exit code $LASTEXITCODE`n$godotLog"
    }
    Write-Output 'GODOT_NODE_BRIDGE_E2E_OK'
}
finally {
    [Environment]::SetEnvironmentVariable('GODOT_MCP_SESSION_FILE', $priorSessionFile, 'Process')
    [Environment]::SetEnvironmentVariable('GODOT_PROJECT_PATH', $priorProjectPath, 'Process')
    [Environment]::SetEnvironmentVariable('GODOT_MCP_TRACE_BRIDGE', $priorBridgeTrace, 'Process')
    if ($godotProcess -ne $null -and -not $godotProcess.HasExited) {
        $godotProcess.Kill()
        $godotProcess.WaitForExit()
    }
    $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
    if ($resolvedFixture.StartsWith($fixturePrefix, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedFixture)) {
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
    }
}
