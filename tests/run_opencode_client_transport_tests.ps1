param(
    [string]$Godot = 'E:\Code\godot\godot_work\bin\godot.windows.editor.x86_64.mono.console.exe',
    [int]$TimeoutSeconds = 45
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixturePrefix = Join-Path $tempRoot 'opencode-godot-client-transport % '
$fixtureRoot = [IO.Path]::GetFullPath(($fixturePrefix + [guid]::NewGuid().ToString('N')))
$readyPath = Join-Path $fixtureRoot 'mock-opencode.ready.json'
$mock = $null
$stdoutTask = $null
$stderrTask = $null

function Stop-OwnedMock {
    if ($script:mock -ne $null -and -not $script:mock.HasExited) {
        try { $script:mock.Kill() } catch {}
        try { $script:mock.WaitForExit(5000) | Out-Null } catch {}
    }
}

function Get-TaskText($task) {
    if ($null -eq $task) { return '' }
    try { $task.Wait(5000) | Out-Null; if ($task.IsCompleted) { return [string]$task.Result } } catch {}
    return '<output capture timed out>'
}

if (-not (Test-Path -LiteralPath $Godot -PathType Leaf)) { throw "Godot executable not found: $Godot" }
$node = Get-Command node.exe -ErrorAction SilentlyContinue
if ($null -eq $node) { $node = Get-Command node -ErrorAction SilentlyContinue }
if ($null -eq $node) { throw 'Node.js is required only for the external loopback HTTP/SSE test fixture.' }

try {
    New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixture\project.godot') -Destination (Join-Path $fixtureRoot 'project.godot')
    (Get-Content -LiteralPath (Join-Path $fixtureRoot 'project.godot') -Raw).Replace('enabled=PackedStringArray("res://addons/godot_mcp/plugin.cfg")', 'enabled=PackedStringArray()') | Set-Content -LiteralPath (Join-Path $fixtureRoot 'project.godot') -NoNewline
    New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'addons') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'addons\opencode_godot') -Destination (Join-Path $fixtureRoot 'addons\opencode_godot') -Recurse
    New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'tests') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixture\tests\opencode_client_transport_runner.gd') -Destination (Join-Path $fixtureRoot 'tests\opencode_client_transport_runner.gd')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'mock_opencode_v2_server.mjs') -Destination (Join-Path $fixtureRoot 'tests\mock_opencode_v2_server.mjs')

    $mockInfo = [Diagnostics.ProcessStartInfo]::new()
    $mockInfo.FileName = $node.Source
    $mockInfo.WorkingDirectory = $fixtureRoot
    $mockInfo.UseShellExecute = $false
    $mockInfo.CreateNoWindow = $true
    $mockInfo.RedirectStandardOutput = $true
    $mockInfo.RedirectStandardError = $true
    $mockInfo.Arguments = ('"' + (Join-Path $fixtureRoot 'tests\mock_opencode_v2_server.mjs').Replace('"', '\"') + '" "' + $readyPath.Replace('"', '\"') + '" "' + $fixtureRoot.Replace('"', '\"') + '"')
    $mock = [Diagnostics.Process]::Start($mockInfo)
    $stdoutTask = $mock.StandardOutput.ReadToEndAsync()
    $stderrTask = $mock.StandardError.ReadToEndAsync()
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    while ($deadline.ElapsedMilliseconds -lt 10000 -and -not (Test-Path -LiteralPath $readyPath -PathType Leaf)) {
        if ($mock.HasExited) { throw "Loopback mock exited early.`n$(Get-TaskText $stdoutTask)`n$(Get-TaskText $stderrTask)" }
        Start-Sleep -Milliseconds 50
    }
    if (-not (Test-Path -LiteralPath $readyPath -PathType Leaf)) { throw 'Loopback mock did not publish its ready record.' }

    $restrictedPath = [IO.Path]::Combine($env:SystemRoot, 'System32') + ';' + [IO.Path]::Combine($env:SystemRoot, 'System32\WindowsPowerShell\v1.0')
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = [IO.Path]::GetFullPath($Godot)
    $info.WorkingDirectory = $fixtureRoot
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.EnvironmentVariables['PATH'] = $restrictedPath
    $info.EnvironmentVariables['OPENCODE_CLIENT_TRANSPORT_READY'] = $readyPath
    $info.Arguments = '--headless --path "' + $fixtureRoot.Replace('"', '\"') + '" --script res://tests/opencode_client_transport_runner.gd'
    $godotProcess = [Diagnostics.Process]::Start($info)
    $godotOut = $godotProcess.StandardOutput.ReadToEndAsync()
    $godotErr = $godotProcess.StandardError.ReadToEndAsync()
    if (-not $godotProcess.WaitForExit($TimeoutSeconds * 1000)) {
        try { $godotProcess.Kill() } catch {}
        throw "Godot client transport test exceeded $TimeoutSeconds seconds."
    }
    $log = (Get-TaskText $godotOut) + "`n" + (Get-TaskText $godotErr)
    Write-Output $log
    if ($godotProcess.ExitCode -ne 0 -or $log -notmatch 'OPENCODE_GODOT_CLIENT_TRANSPORT_OK') { throw "Godot client transport test failed.`n$log" }
    $requestLog = Get-Content -LiteralPath ($readyPath + '.requests.log') -Raw
    foreach ($expected in @('GET /api/session/ses_live/event?after=0', 'GET /api/session/ses_live/event?after=1', 'POST /api/session/ses_live/permission/per_live/reply', 'POST /api/session/ses_live/question/que_live/reply', 'POST /api/session/ses_live/interrupt')) {
        if ($requestLog -notmatch [regex]::Escape($expected)) { throw "Loopback transport fixture did not observe: $expected" }
    }
    Write-Output 'OPENCODE_GODOT_CLIENT_TRANSPORT_REQUEST_AUDIT_OK'
}
finally {
    Stop-OwnedMock
    if ($fixtureRoot -and (Test-Path -LiteralPath $fixtureRoot)) {
        $resolved = [IO.Path]::GetFullPath($fixtureRoot)
        if ($resolved.StartsWith($fixturePrefix, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
