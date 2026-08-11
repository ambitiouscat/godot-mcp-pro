param(
    [string]$Godot = 'E:\Code\godot\godot_work\bin\godot.windows.editor.x86_64.mono.console.exe'
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixturePrefix = Join-Path $tempRoot 'opencode-godot-installation-'
$fixtureRoot = [IO.Path]::GetFullPath(($fixturePrefix + [guid]::NewGuid().ToString('N')))
$fixtureID = [IO.Path]::GetFileName($fixtureRoot)
$externalConfig = Join-Path $fixtureRoot '.opencode\config.json'
$projectConfig = Join-Path $fixtureRoot 'opencode.json'
$priorExternalConfig = [Environment]::GetEnvironmentVariable('OPENCODE_INSTALL_EXTERNAL_CONFIG', 'Process')
$priorProjectConfig = [Environment]::GetEnvironmentVariable('OPENCODE_INSTALL_PROJECT_CONFIG', 'Process')

function Assert-FixturePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $resolved = [IO.Path]::GetFullPath($Path)
    if (-not $resolved.StartsWith($fixturePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to use a path outside the isolated installation fixture: $resolved"
    }
    return $resolved
}

function Write-FixtureProject {
    param([Parameter(Mandatory = $true)][bool]$WithLegacy)
    $enabled = if ($WithLegacy) {
        'PackedStringArray("res://addons/godot_mcp/plugin.cfg")'
    } else {
        'PackedStringArray("res://addons/opencode_godot/plugin.cfg")'
    }
    $project = @"
; Isolated installation integration fixture.
config_version=5

[application]

config/name="OpenCode Godot Installation Fixture $fixtureID$(if ($WithLegacy) { ' Legacy' } else { '' })"

[editor_plugins]

enabled=$enabled

[rendering]

renderer/rendering_method="gl_compatibility"
renderer/rendering_method.mobile="gl_compatibility"
"@
    Set-Content -LiteralPath (Join-Path $fixtureRoot 'project.godot') -Value $project -NoNewline
}

function Invoke-GodotCase {
    param([Parameter(Mandatory = $true)][string]$Mode)
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $outputLines = @(& $Godot '--headless' '--editor' '--path' $fixtureRoot '--script' 'res://tests/opencode_installation_runner.gd' 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    $output = ($outputLines | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    Write-Output "[installation][$Mode]"
    Write-Output $output
    if ($output -match '(?im)(SCRIPT ERROR|Failed to load script|Parse Error|Parse error)') {
        throw "Godot reported a script parse/load error in the $Mode installation fixture."
    }
    if ($exitCode -ne 0) {
        throw "Godot installation fixture '$Mode' exited with code $exitCode."
    }
    if ($output -notmatch 'OPENCODE_GODOT_INSTALLATION_OK') {
        throw "Godot installation fixture '$Mode' did not publish its success marker."
    }
}

function Stop-FixturePayloads {
    $needle = $fixtureRoot.Replace('\', '/').ToLowerInvariant()
    $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -in @('opencode.exe', 'godot-mcp.exe') -and $_.CommandLine -and $_.CommandLine.Replace('\', '/').ToLowerInvariant().Contains($needle)
    })
    foreach ($process in $processes) {
        try { Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction SilentlyContinue } catch {}
    }
}

if (-not (Test-Path -LiteralPath $Godot -PathType Leaf)) {
    throw "Godot executable not found: $Godot"
}

try {
    New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'addons') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'tests') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'addons\opencode_godot') -Destination (Join-Path $fixtureRoot 'addons\opencode_godot') -Recurse
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixture\tests\opencode_installation_runner.gd') -Destination (Join-Path $fixtureRoot 'tests\opencode_installation_runner.gd')
    New-Item -ItemType Directory -Path (Split-Path -Parent $externalConfig) -Force | Out-Null
    Set-Content -LiteralPath $externalConfig -Value '{"unrelated":"must-survive"}' -NoNewline
    Set-Content -LiteralPath (Join-Path $fixtureRoot 'opencode.json') -Value '{"unrelated":"must-survive"}' -NoNewline
    [Environment]::SetEnvironmentVariable('OPENCODE_INSTALL_EXTERNAL_CONFIG', $externalConfig, 'Process')
    [Environment]::SetEnvironmentVariable('OPENCODE_INSTALL_PROJECT_CONFIG', $projectConfig, 'Process')

    # Normal single-directory installation and first-enable assertions.
    Write-FixtureProject -WithLegacy:$false
    Invoke-GodotCase -Mode 'single-directory'

    # Reuse the same copied addon to verify the legacy conflict path without
    # introducing a second production addon tree.
    New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'addons\godot_mcp') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixture\legacy_addon\plugin.cfg') -Destination (Join-Path $fixtureRoot 'addons\godot_mcp\plugin.cfg')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixture\legacy_addon\legacy_plugin.gd') -Destination (Join-Path $fixtureRoot 'addons\godot_mcp\legacy_plugin.gd')
    Write-FixtureProject -WithLegacy:$true
    Invoke-GodotCase -Mode 'legacy-conflict'
    Write-Output 'OPENCODE_GODOT_INSTALLATION_MATRIX_OK'
}
finally {
    [Environment]::SetEnvironmentVariable('OPENCODE_INSTALL_EXTERNAL_CONFIG', $priorExternalConfig, 'Process')
    [Environment]::SetEnvironmentVariable('OPENCODE_INSTALL_PROJECT_CONFIG', $priorProjectConfig, 'Process')
    Stop-FixturePayloads
    $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
    if ($resolvedFixture.StartsWith($fixturePrefix, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedFixture)) {
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force -ErrorAction SilentlyContinue
    }
}
