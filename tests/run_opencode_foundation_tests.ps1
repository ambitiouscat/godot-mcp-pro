param(
    [string]$Godot = 'E:\Code\godot\godot_work\bin\godot.windows.editor.x86_64.mono.console.exe'
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("opencode-godot-foundation-" + [guid]::NewGuid().ToString('N'))

function Invoke-GodotChecked {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $outputLines = @(& $Godot @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    $output = ($outputLines | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    if (-not [string]::IsNullOrWhiteSpace($output)) {
        Write-Output $output
    }
    if ($exitCode -ne 0) {
        throw "Godot exited with code $exitCode for: $($Arguments -join ' ')"
    }
    if ($output -match '(?im)(SCRIPT ERROR|Failed to load script|Parse Error|Parse error)') {
        throw "Godot reported a script parse/load error for: $($Arguments -join ' ')"
    }
}

try {
    New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixture\project.godot') -Destination $fixtureRoot
    $projectFile = Join-Path $fixtureRoot 'project.godot'
    (Get-Content -Raw $projectFile).Replace('res://addons/godot_mcp/plugin.cfg', 'res://addons/opencode_godot/plugin.cfg') | Set-Content -NoNewline $projectFile
    New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'addons') | Out-Null
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'addons\opencode_godot') -Destination (Join-Path $fixtureRoot 'addons\opencode_godot') -Recurse
    New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'tests') | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixture\tests\opencode_foundation_runner.gd') -Destination (Join-Path $fixtureRoot 'tests\opencode_foundation_runner.gd')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixture\tests\opencode_client_runner.gd') -Destination (Join-Path $fixtureRoot 'tests\opencode_client_runner.gd')
    foreach ($script in @(
        'plugin.gd',
        'process/opencode_daemon_lifecycle.gd',
        'client/sse_parser.gd',
        'client/http_sse_stream.gd',
        'client/opencode_api_client.gd',
        'ui/opencode_dock.gd',
        'engine_bridge/bridge_session_coordinator.gd'
    )) {
        Invoke-GodotChecked -Arguments @(
            '--headless', '--path', $fixtureRoot,
            '--script', ("res://addons/opencode_godot/" + $script),
            '--check-only'
        )
    }
    Invoke-GodotChecked -Arguments @(
        '--headless', '--path', $fixtureRoot,
        '--script', 'res://tests/opencode_foundation_runner.gd'
    )
    Invoke-GodotChecked -Arguments @(
        '--headless', '--path', $fixtureRoot,
        '--script', 'res://tests/opencode_client_runner.gd'
    )
} finally {
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}
