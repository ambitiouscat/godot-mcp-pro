<##
.SYNOPSIS
  Assemble the pinned OpenCode and Godot MCP payloads into addons/opencode_godot.

.DESCRIPTION
  This is release tooling only.  It consumes locally built artifacts and never
  downloads Node, Bun, npm, or any runtime.  A developer/source-tree assembly
  can use -AllowMissing; a full release uses -FullRelease and requires all six
  tuples, executable permission metadata, and signed artifacts.

  The destination is deliberately treated as untrusted input.  Every copied
  destination is resolved below <OutputAddonRoot>/bin before it is touched and
  the only recursive cleanup performed is for a uniquely named staging folder
  created by this invocation below the output root.

.PARAMETER OpenCodeRepo
  Local OpenCode source/build repository.

.PARAMETER OpenCodeArtifactRoot
  Optional directory containing a curated set of OpenCode target artifacts.
  Source/version/commit identity still comes from OpenCodeRepo.

.PARAMETER ServerRepo
  Local Godot MCP server repository containing dist/sidecars/manifest.json.

.PARAMETER Target
  Comma-separated canonical tuples or server aliases.  Defaults to all six.

.PARAMETER OutputAddonRoot
  The addons/opencode_godot directory to receive bin/ and payload-manifest.json.

.PARAMETER AllowMissing
  Emit a partial manifest for a source/developer tree. Missing/unverified
  entries remain explicit and cannot be used as a full release.

.PARAMETER FullRelease
  Require all six selected tuples, validated payload metadata, and signatures.
##>

[CmdletBinding()]
param(
  [string] $OpenCodeRepo,

  [string] $OpenCodeArtifactRoot = "",

  [string] $ServerRepo,

  [string] $Target = "all",

  [string] $OutputAddonRoot,

  [switch] $AllowMissing,

  [Alias("Release")]
  [switch] $FullRelease,

  [switch] $Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$CanonicalTargets = [ordered]@{
  "windows-x86_64"     = [ordered]@{ aliases = @("windows-x86_64", "windows-x64"); server = "windows-x64"; opencode = @("opencode-windows-x64", "opencode-windows-x64-baseline"); platform = "windows"; arch = "x86_64"; suffix = ".exe" }
  "windows-arm64"      = [ordered]@{ aliases = @("windows-arm64"); server = "windows-arm64"; opencode = @("opencode-windows-arm64", "opencode-windows-arm64-baseline"); platform = "windows"; arch = "arm64"; suffix = ".exe" }
  "macos-x86_64"       = [ordered]@{ aliases = @("macos-x86_64", "macos-x64", "darwin-x64"); server = "macos-x64"; opencode = @("opencode-darwin-x64", "opencode-macos-x64", "opencode-darwin-x64-baseline"); platform = "macos"; arch = "x86_64"; suffix = "" }
  "macos-arm64"        = [ordered]@{ aliases = @("macos-arm64", "darwin-arm64"); server = "macos-arm64"; opencode = @("opencode-darwin-arm64", "opencode-macos-arm64"); platform = "macos"; arch = "arm64"; suffix = "" }
  "linux-x86_64-glibc"  = [ordered]@{ aliases = @("linux-x86_64-glibc", "linux-glibc-x64", "linux-x64"); server = "linux-glibc-x64"; opencode = @("opencode-linux-x64-baseline", "opencode-linux-x64"); platform = "linux"; arch = "x86_64"; suffix = "" }
  "linux-arm64-glibc"   = [ordered]@{ aliases = @("linux-arm64-glibc", "linux-glibc-arm64", "linux-arm64"); server = "linux-glibc-arm64"; opencode = @("opencode-linux-arm64", "opencode-linux-arm64-baseline"); platform = "linux"; arch = "arm64"; suffix = "" }
}

function Show-Usage {
  @"
Usage:
  pwsh tools/package_opencode_godot_payloads.ps1 `
    -OpenCodeRepo <repo> [-OpenCodeArtifactRoot <artifact-dir>] `
    -ServerRepo <repo-or-aggregate-dir> -OutputAddonRoot <addons/opencode_godot> `
    [-Target all|tuple[,tuple...]] [-AllowMissing] [-FullRelease]

Canonical tuples:
  windows-x86_64, windows-arm64, macos-x86_64, macos-arm64,
  linux-x86_64-glibc, linux-arm64-glibc

-AllowMissing creates a partial/native developer manifest.  -FullRelease
requires every tuple, signed artifacts, and mode 0755 metadata.
"@
}

if ($Help) {
  Show-Usage
  exit 0
}
if ([String]::IsNullOrWhiteSpace($OpenCodeRepo) -or [String]::IsNullOrWhiteSpace($ServerRepo) -or [String]::IsNullOrWhiteSpace($OutputAddonRoot)) {
  Show-Usage
  throw "OpenCodeRepo, ServerRepo, and OutputAddonRoot are required"
}

function Resolve-ExistingDirectory([string] $Value, [string] $Name) {
  if (-not (Test-Path -LiteralPath $Value -PathType Container)) {
    throw "$Name does not exist or is not a directory: $Value"
  }
  return [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Value).Path)
}

function Resolve-OrCreateDirectory([string] $Value) {
  $full = [IO.Path]::GetFullPath($Value)
  if (-not (Test-Path -LiteralPath $full -PathType Container)) {
    New-Item -ItemType Directory -Path $full -Force | Out-Null
  }
  return [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $full).Path)
}

function Normalize-Directory([string] $Value) {
  return ([IO.Path]::GetFullPath($Value)).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function Test-PathUnder([string] $Root, [string] $Candidate) {
  $rootFull = Normalize-Directory $Root
  $candidateFull = [IO.Path]::GetFullPath($Candidate)
  if ($candidateFull.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) { return $true }
  return $candidateFull.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
    $candidateFull.StartsWith($rootFull + [IO.Path]::AltDirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-PathUnder([string] $Root, [string] $Candidate, [string] $Label) {
  if (-not (Test-PathUnder $Root $Candidate)) {
    throw "$Label escapes its allowed root: $Candidate"
  }
}

function Read-JsonFile([string] $Path, [string] $Label) {
  try {
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
  } catch {
    throw "Cannot read $Label JSON at $Path`: $($_.Exception.Message)"
  }
}

function Get-Sha256File([string] $Path) {
  $hash = [Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [IO.File]::ReadAllBytes($Path)
    return "sha256:" + ([BitConverter]::ToString($hash.ComputeHash($bytes)).Replace("-", "").ToLowerInvariant())
  } finally {
    $hash.Dispose()
  }
}

function Get-Sha256Text([string] $Text) {
  $hash = [Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    return "sha256:" + ([BitConverter]::ToString($hash.ComputeHash($bytes)).Replace("-", "").ToLowerInvariant())
  } finally {
    $hash.Dispose()
  }
}

function Invoke-Git([string] $Repo, [string[]] $Arguments) {
  $output = & git -C $Repo @Arguments 2>$null
  if ($LASTEXITCODE -ne 0) { return "" }
  return (($output -join "`n").Trim())
}

function Get-SourceFingerprint([string] $Repo, [string] $ContractPath) {
  if (Test-Path -LiteralPath $ContractPath -PathType Leaf) {
    try {
      $contract = Read-JsonFile $ContractPath "OpenCode contract"
      $value = [string] $contract.source.source_fingerprint
      if ($value -match '^sha256:[0-9a-fA-F]{64}$') { return $value.ToLowerInvariant() }
    } catch { }
  }

  $gitFilesText = Invoke-Git $Repo @("ls-files")
  $files = @($gitFilesText -split '\r?\n' | Where-Object {
    $_ -and ($_ -notmatch '(^|/)(dist|node_modules|build)/') -and
      ($_ -match '^(package\.json|bun\.lock|packages/(opencode|client|protocol|schema)/src/)')
  } | Sort-Object)
  if ($files.Count -eq 0) {
    $head = Invoke-Git $Repo @("rev-parse", "HEAD")
    if ($head -match '^[0-9a-fA-F]{40}$') { return Get-Sha256Text ("git:" + $head) }
    return "UNVERIFIED"
  }

  $sha = [Security.Cryptography.SHA256]::Create()
  $zero = [byte[]]::new(0)
  try {
    foreach ($relative in $files) {
      $file = Join-Path $Repo ($relative -replace '/', [IO.Path]::DirectorySeparatorChar)
      if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
      $nameBytes = [Text.Encoding]::UTF8.GetBytes(($relative -replace '\\', '/') + "`0")
      [void] $sha.TransformBlock($nameBytes, 0, $nameBytes.Length, $nameBytes, 0)
      $content = [IO.File]::ReadAllBytes($file)
      [void] $sha.TransformBlock($content, 0, $content.Length, $content, 0)
      $separator = [Text.Encoding]::UTF8.GetBytes("`0")
      [void] $sha.TransformBlock($separator, 0, $separator.Length, $separator, 0)
    }
    [void] $sha.TransformFinalBlock($zero, 0, 0)
    return "sha256:" + ([BitConverter]::ToString($sha.Hash).Replace("-", "").ToLowerInvariant())
  } finally {
    $sha.Dispose()
  }
}

function Get-TargetByName([string] $Name) {
  foreach ($canonical in $CanonicalTargets.Keys) {
    if ($canonical -eq $Name -or $CanonicalTargets[$canonical].aliases -contains $Name) { return $canonical }
  }
  throw "Unsupported target '$Name'. Supported: $($CanonicalTargets.Keys -join ', ')"
}

function Parse-Targets([string] $Value) {
  if ([String]::IsNullOrWhiteSpace($Value) -or $Value.Trim().ToLowerInvariant() -eq "all") {
    return @($CanonicalTargets.Keys)
  }
  $result = [Collections.Generic.List[string]]::new()
  foreach ($item in ($Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
    $canonical = Get-TargetByName $item
    if (-not $result.Contains($canonical)) { $result.Add($canonical) }
  }
  return @($result)
}

function Get-PropertyValue($Object, [string[]] $Names) {
  foreach ($name in $Names) {
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$name]) {
      $value = $Object.PSObject.Properties[$name].Value
      if ($null -ne $value -and -not [String]::IsNullOrWhiteSpace([string] $value)) { return $value }
    }
  }
  return $null
}

function Get-SignatureMetadata($Metadata, [bool] $Present) {
  $signature = Get-PropertyValue $Metadata @("signature", "signing")
  if ($null -eq $signature) {
    return [ordered]@{ status = if ($Present) { "unverified" } else { "missing" }; scheme = "none"; required_from_release_environment = $true }
  }
  if ($signature -is [string]) {
    if ($signature.Trim().Length -eq 0) { return [ordered]@{ status = "unverified"; scheme = "none"; required_from_release_environment = $true } }
    return [ordered]@{ status = "signed"; scheme = "external"; value = [string] $signature }
  }
  $result = [ordered]@{}
  foreach ($property in $signature.PSObject.Properties) { $result[$property.Name] = $property.Value }
  if (-not $result.Contains("status")) { $result.status = if ($Present) { "unverified" } else { "missing" } }
  if (-not $result.Contains("scheme")) { $result.scheme = "none" }
  return $result
}

function Find-JsonMetadata([string] $ArtifactPath, [string] $SearchRoot) {
  $candidates = @(
    ($ArtifactPath + ".json"),
    (Join-Path (Split-Path -Parent $ArtifactPath) "artifact.json"),
    (Join-Path (Split-Path -Parent $ArtifactPath) "build-manifest.json"),
    (Join-Path (Split-Path -Parent $ArtifactPath) "manifest.json"),
    (Join-Path (Split-Path -Parent $ArtifactPath) "package.json"),
    (Join-Path (Split-Path -Parent (Split-Path -Parent $ArtifactPath)) "package.json"),
    (Join-Path $SearchRoot "package.json"),
    (Join-Path $SearchRoot "manifest.json")
  )
  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      try { return Read-JsonFile $candidate "artifact metadata" } catch { }
    }
  }
  return $null
}

function Get-HostTuple {
  $platform = if ($env:OS -eq "Windows_NT") { "windows" } elseif ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::OSX)) { "macos" } elseif ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Linux)) { "linux" } else { "" }
  $architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
  if ($architecture -eq "x64") { $architecture = "x86_64" }
  if ($platform -eq "linux") { return "linux-$architecture-glibc" }
  if ($platform) { return "$platform-$architecture" }
  return ""
}

function Get-ExecutableVersion([string] $Path, [string] $Canonical) {
  # Never invoke a cross-target binary.  Release metadata is mandatory for
  # those targets; the native target can additionally prove the embedded
  # --version without going through a shell or inheriting editor environment.
  if ((Get-HostTuple) -ne $Canonical) { return "" }
  try {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Path
    $start.Arguments = "--version"
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    if ($null -eq $process) { return "" }
    if (-not $process.WaitForExit(5000)) {
      try { $process.Kill() } catch { }
      return ""
    }
    $output = ($process.StandardOutput.ReadToEnd() + "`n" + $process.StandardError.ReadToEnd()).Trim()
    $match = [Regex]::Match($output, '(?m)(?<![0-9])([0-9]+\.[0-9]+\.[0-9]+)(?![0-9])')
    if ($match.Success) { return $match.Groups[1].Value }
  } catch { }
  return ""
}

function Find-OpenCodeArtifact([string] $Repo, [string] $Canonical, $TargetInfo) {
  $distRoots = @(
    (Join-Path $Repo "packages/opencode/dist"),
    (Join-Path $Repo "dist"),
    (Join-Path $Repo "artifacts"),
    $Repo
  ) | Where-Object { Test-Path -LiteralPath $_ -PathType Container }
  $fileName = if ($TargetInfo.suffix -eq ".exe") { "opencode.exe" } else { "opencode" }
  foreach ($root in $distRoots) {
    foreach ($directoryName in $TargetInfo.opencode) {
      $artifactDirectories = @((Join-Path $root $directoryName))
      $artifactDirectories += @(Get-ChildItem -LiteralPath $root -Recurse -Directory -Filter $directoryName -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/]node_modules[\\/]' } |
        ForEach-Object { $_.FullName })
      foreach ($artifactDirectory in $artifactDirectories | Select-Object -Unique) {
        $candidate = Join-Path $artifactDirectory (Join-Path "bin" $fileName)
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
          $meta = Find-JsonMetadata $candidate $artifactDirectory
          return [pscustomobject]@{ path = [IO.Path]::GetFullPath($candidate); metadata = $meta; root = $artifactDirectory }
        }
      }
    }
    # Some release archives unpack directly into a target folder.  Keep this
    # search bounded to the build root and exclude dependency trees.
    $matches = Get-ChildItem -LiteralPath $root -Recurse -File -Filter $fileName -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -notmatch '[\\/]node_modules[\\/]' -and $_.FullName -match '(opencode|open-code)[-_]' }
    foreach ($match in $matches) {
      if ($match.FullName -match [Regex]::Escape($Canonical.Replace("_", "-"))) {
        $meta = Find-JsonMetadata $match.FullName $root
        return [pscustomobject]@{ path = $match.FullName; metadata = $meta; root = $root }
      }
    }
  }
  return $null
}

function Get-ServerArtifacts([string] $Repo) {
  $candidates = @(
    (Join-Path $Repo "manifest.json"),
    (Join-Path $Repo "dist/sidecars/manifest.json"),
    (Join-Path $Repo "server/dist/sidecars/manifest.json"),
    (Join-Path $Repo "dist/manifest.json")
  )
  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      $manifest = Read-JsonFile $candidate "Godot MCP sidecar manifest"
      if ([string] $manifest.version -ne "1.16.0" -or [string] $manifest.api_contract -ne "godot-mcp-pro/1.16.0") {
        throw "Godot MCP sidecar manifest is not pinned to 1.16.0: $candidate"
      }
      return [pscustomobject]@{ path = [IO.Path]::GetFullPath($candidate); value = $manifest }
    }
  }
  if ($AllowMissing) { return $null }
  throw "Godot MCP sidecar manifest not found below $Repo"
}

function Get-ServerArtifact($ServerManifest, $TargetInfo, [string] $ManifestRoot) {
  if ($null -eq $ServerManifest) { return $null }
  foreach ($artifact in @($ServerManifest.value.artifacts)) {
    if ([string] $artifact.tuple -ne [string] $TargetInfo.server) { continue }
    $relative = [string] $artifact.path
    if ([String]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)') {
      throw "Unsafe sidecar artifact path for $($TargetInfo.server): $relative"
    }
    $candidate = [IO.Path]::GetFullPath((Join-Path $ManifestRoot ($relative -replace '/', [IO.Path]::DirectorySeparatorChar)))
    Assert-PathUnder $ManifestRoot $candidate "Godot MCP artifact"
    $exists = Test-Path -LiteralPath $candidate -PathType Leaf
    return [pscustomobject]@{ path = $candidate; metadata = $artifact; present = $exists }
  }
  return $null
}

function Get-ArtifactRecord([string] $Kind, [string] $Canonical, $Artifact, [string] $SourceFingerprint, [string] $PinnedVersion, [string] $DestinationPath) {
  $present = $null -ne $Artifact -and (Test-Path -LiteralPath $Artifact.path -PathType Leaf)
  $metadata = if ($null -ne $Artifact) { $Artifact.metadata } else { $null }
  $actualHash = if ($present) { Get-Sha256File $Artifact.path } else { "" }
  $actualSize = if ($present) { [int64] ([IO.FileInfo]::new($Artifact.path)).Length } else { $null }
  $declaredHash = [string] (Get-PropertyValue $metadata @("sha256", "checksum", "digest"))
  if ($declaredHash -and $declaredHash -notmatch '^sha256:') { $declaredHash = "sha256:" + $declaredHash }
  if ($present -and $declaredHash -and $declaredHash.ToLowerInvariant() -ne $actualHash) {
    throw "$Kind artifact checksum metadata does not match $($Artifact.path)"
  }
  $hash = if ($present) { $actualHash } else { "" }
  $size = if ($present) { $actualSize } else { $null }
  $mode = [string] (Get-PropertyValue $metadata @("mode", "file_mode"))
  if ([String]::IsNullOrWhiteSpace($mode)) { $mode = if ($present) { "0755" } else { "" } }
  $signature = Get-SignatureMetadata $metadata $present
  $declaredVersion = [string] (Get-PropertyValue $metadata @("version", "artifact_version", "runtime_version"))
  $probedVersion = if ($present -and $Kind -eq "OpenCode") { Get-ExecutableVersion $Artifact.path $Canonical } else { "" }
  $versionVerified = if (-not $present) { $false } elseif ($probedVersion) { $probedVersion -eq $PinnedVersion -and (-not $declaredVersion -or $declaredVersion -eq $PinnedVersion) } elseif ($declaredVersion) { $declaredVersion -eq $PinnedVersion } else { $false }
  $declaredSourceFingerprint = [string] (Get-PropertyValue $metadata @("source_fingerprint", "sourceFingerprint", "opencode_source_fingerprint"))
  if ($declaredSourceFingerprint -match '^sha256:[0-9a-fA-F]{64}$') {
    $SourceFingerprint = $declaredSourceFingerprint.ToLowerInvariant()
  }
  $buildFingerprint = [string] (Get-PropertyValue $metadata @("build_fingerprint", "buildFingerprint", "opencode_build_fingerprint", "fingerprint"))
  if ([String]::IsNullOrWhiteSpace($buildFingerprint)) { $buildFingerprint = "UNVERIFIED" }
  $fingerprintsVerified = $SourceFingerprint -match '^sha256:[0-9a-fA-F]{64}$' -and $buildFingerprint -ne "UNVERIFIED" -and $buildFingerprint -ne "UNPACKAGED"
  $status = if (-not $present) { "missing" } elseif (-not $versionVerified -or -not $fingerprintsVerified) { "unverified" } elseif ($signature.status -in @("signed", "verified") -and $mode -eq "0755") { "ready" } else { "unverified" }
  $result = [ordered]@{
    path = $DestinationPath
    sha256 = $hash
    size_bytes = $size
    mode = $mode
    signature = $signature
    version = $PinnedVersion
    artifact_version = if ($declaredVersion) { $declaredVersion } elseif ($probedVersion) { $probedVersion } else { "" }
    version_verified = [bool] $versionVerified
    source_fingerprint = $SourceFingerprint
    build_fingerprint = $buildFingerprint
    status = $status
  }
  if (-not $present) { $result.reason = if ($null -eq $Artifact) { "not-found" } else { "artifact-file-missing" } }
  elseif (-not $versionVerified) { $result.reason = "version-unverified-or-mismatch" }
  return $result
}

function Remove-OwnStaging([string] $Path, [string] $AddonRoot) {
  if (-not (Test-Path -LiteralPath $Path)) { return }
  $leaf = Split-Path -Leaf $Path
  $resolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).Path)
  if ($leaf -notmatch '^\.payload-staging-[0-9a-f]{16}$' -or (Normalize-Directory (Split-Path -Parent $resolved)) -ne (Normalize-Directory $AddonRoot)) {
    throw "Refusing to remove an unverified staging path: $Path"
  }
  Remove-Item -LiteralPath $resolved -Recurse -Force
}

$openCodeRoot = Resolve-ExistingDirectory $OpenCodeRepo "OpenCode repository"
$openCodeArtifacts = if ([String]::IsNullOrWhiteSpace($OpenCodeArtifactRoot)) {
  $openCodeRoot
} else {
  Resolve-ExistingDirectory $OpenCodeArtifactRoot "OpenCode artifact root"
}
$serverRoot = Resolve-ExistingDirectory $ServerRepo "Godot MCP repository"
$addonRoot = Resolve-OrCreateDirectory $OutputAddonRoot
$binRoot = Resolve-OrCreateDirectory (Join-Path $addonRoot "bin")
Assert-PathUnder $addonRoot $binRoot "payload bin root"
$selectedTargets = @(Parse-Targets $Target)

$openCodePackagePath = Join-Path $openCodeRoot "packages/opencode/package.json"
if (-not (Test-Path -LiteralPath $openCodePackagePath -PathType Leaf)) { throw "OpenCode package.json not found: $openCodePackagePath" }
$openCodePackage = Read-JsonFile $openCodePackagePath "OpenCode package"
if ([string] $openCodePackage.version -ne "1.17.18") { throw "OpenCode package is not pinned to 1.17.18 (found $($openCodePackage.version))" }
$openCodeContractPath = Join-Path $addonRoot "contract/opencode-http-contract.json"
$openCodeSourceFingerprint = Get-SourceFingerprint $openCodeRoot $openCodeContractPath
$openCodeCommit = Invoke-Git $openCodeRoot @("rev-parse", "HEAD")
$serverManifest = Get-ServerArtifacts $serverRoot
$serverSourceFingerprint = if ($null -ne $serverManifest) { [string] $serverManifest.value.source_fingerprint } else { "UNVERIFIED" }
if ($serverSourceFingerprint -and $serverSourceFingerprint -notmatch '^sha256:[0-9a-fA-F]{64}$' -and $serverSourceFingerprint -ne "UNVERIFIED") {
  throw "Godot MCP source fingerprint is invalid: $serverSourceFingerprint"
}
$serverManifestRoot = if ($null -ne $serverManifest) { Split-Path -Parent $serverManifest.path } else { Join-Path $serverRoot "dist/sidecars" }

$nonce = ([Guid]::NewGuid().ToString("N")).Substring(0, 16)
$stagingRoot = Join-Path $addonRoot ".payload-staging-$nonce"
New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
$stagingBin = Join-Path $stagingRoot "bin"
New-Item -ItemType Directory -Path $stagingBin -Force | Out-Null
$records = [ordered]@{}
$allPayloadsReady = $true
$allPayloadsSigned = $true

try {
  foreach ($canonical in $CanonicalTargets.Keys) {
    $info = $CanonicalTargets[$canonical]
    $requested = $selectedTargets -contains $canonical
    $destinationDirectory = Join-Path $binRoot $canonical
    $stagingDirectory = Join-Path $stagingBin $canonical
    Assert-PathUnder $binRoot $destinationDirectory "payload target directory"
    Assert-PathUnder $stagingBin $stagingDirectory "payload staging directory"

    $opencodeArtifact = if ($requested) { Find-OpenCodeArtifact $openCodeArtifacts $canonical $info } else { $null }
    $mcpArtifact = if ($requested) { Get-ServerArtifact $serverManifest $info $serverManifestRoot } else { $null }
    if (-not $requested) {
      $opencodeArtifact = $null
      $mcpArtifact = $null
    }

    $opencodePath = "bin/$canonical/opencode$($info.suffix)"
    $mcpPath = "bin/$canonical/godot-mcp$($info.suffix)"
    $opencodeRecord = Get-ArtifactRecord "OpenCode" $canonical $opencodeArtifact $openCodeSourceFingerprint "1.17.18" $opencodePath
    $mcpRecord = Get-ArtifactRecord "Godot MCP" $canonical $mcpArtifact $serverSourceFingerprint "1.16.0" $mcpPath
    if (-not $requested) {
      $opencodeRecord.reason = "not-requested"
      $mcpRecord.reason = "not-requested"
    }
    $records[$canonical] = [ordered]@{ opencode = $opencodeRecord; mcp = $mcpRecord }

    foreach ($pair in @(@{ record = $opencodeRecord; artifact = $opencodeArtifact; filename = "opencode$($info.suffix)" }, @{ record = $mcpRecord; artifact = $mcpArtifact; filename = "godot-mcp$($info.suffix)" })) {
      if ($pair.record.status -eq "missing") { $allPayloadsReady = $false; $allPayloadsSigned = $false; continue }
      if ($pair.record.status -ne "ready") { $allPayloadsReady = $false }
      if ([string] $pair.record.signature.status -notin @("signed", "verified") -or [string] $pair.record.mode -ne "0755") { $allPayloadsSigned = $false }
      if ($null -ne $pair.artifact -and (Test-Path -LiteralPath $pair.artifact.path -PathType Leaf)) {
        $stagedPath = Join-Path $stagingDirectory $pair.filename
        Assert-PathUnder $stagingBin $stagedPath "payload staging file"
        New-Item -ItemType Directory -Path $stagingDirectory -Force | Out-Null
        Copy-Item -LiteralPath $pair.artifact.path -Destination $stagedPath -Force
      }
    }
  }

  $fullReady = $selectedTargets.Count -eq $CanonicalTargets.Count -and $allPayloadsReady -and $allPayloadsSigned
  if ($FullRelease -and -not $fullReady) {
    throw "Full release assembly requires all six tuples with signed artifacts and mode 0755 metadata"
  }
  if (-not $AllowMissing -and -not $fullReady) {
    throw "Assembly is incomplete or unverified; rerun with -AllowMissing for a developer/partial manifest or provide a full signed release"
  }

  # Copy only files staged by this invocation.  The destination was checked
  # under bin/ above; no broad cleanup or recursive replacement is performed.
  foreach ($canonical in $records.Keys) {
    $stagedDirectory = Join-Path $stagingBin $canonical
    if (-not (Test-Path -LiteralPath $stagedDirectory -PathType Container)) { continue }
    $destinationDirectory = Join-Path $binRoot $canonical
    Assert-PathUnder $binRoot $destinationDirectory "payload destination directory"
    New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    foreach ($file in Get-ChildItem -LiteralPath $stagedDirectory -File) {
      $destination = Join-Path $destinationDirectory $file.Name
      Assert-PathUnder $binRoot $destination "payload destination file"
      Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
    }
  }

  $packagedOpenCodeSources = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $packagedServerSources = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($record in $records.Values) {
    if ($record.opencode.status -ne "missing" -and [string] $record.opencode.source_fingerprint -match '^sha256:[0-9a-fA-F]{64}$') {
      [void] $packagedOpenCodeSources.Add(([string] $record.opencode.source_fingerprint).ToLowerInvariant())
    }
    if ($record.mcp.status -ne "missing" -and [string] $record.mcp.source_fingerprint -match '^sha256:[0-9a-fA-F]{64}$') {
      [void] $packagedServerSources.Add(([string] $record.mcp.source_fingerprint).ToLowerInvariant())
    }
  }
  if ($packagedOpenCodeSources.Count -gt 1 -or $packagedServerSources.Count -gt 1) {
    throw "Payloads for one release were built from different source fingerprints"
  }
  if ($packagedOpenCodeSources.Count -eq 1) { $openCodeSourceFingerprint = @($packagedOpenCodeSources)[0] }
  if ($packagedServerSources.Count -eq 1) { $serverSourceFingerprint = @($packagedServerSources)[0] }

  $manifest = [ordered]@{
    schema = "opencode-godot-payload-manifest"
    schema_version = 1
    godot_minimum = "4.3"
    release = [ordered]@{ mode = if ($fullReady) { "full" } else { "partial" }; complete = [bool] $fullReady; signature_required = $true }
    opencode = [ordered]@{
      version = "1.17.18"
      source_fingerprint = $openCodeSourceFingerprint
      git_commit = $openCodeCommit
    }
    godot_mcp = [ordered]@{
      version = "1.16.0"
      api_contract = "godot-mcp-pro/1.16.0"
      source_fingerprint = $serverSourceFingerprint
    }
    payloads = $records
  }

  $manifestPath = Join-Path $addonRoot "payload-manifest.json"
  $manifestTemp = Join-Path $addonRoot ".payload-manifest-$nonce.json"
  Assert-PathUnder $addonRoot $manifestTemp "manifest temporary file"
  $manifestJson = $manifest | ConvertTo-Json -Depth 30
  [IO.File]::WriteAllText($manifestTemp, $manifestJson, [Text.UTF8Encoding]::new($false))
  Move-Item -LiteralPath $manifestTemp -Destination $manifestPath -Force
  Write-Output ("OPENCODE_GODOT_PAYLOAD_ASSEMBLY_OK mode=" + $manifest.release.mode + " manifest=" + $manifestPath)
} finally {
  Remove-OwnStaging $stagingRoot $addonRoot
}
