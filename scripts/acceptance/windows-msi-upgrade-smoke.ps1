# Windows MSI real installed-version upgrade smoke.
# This validates the *installer* lifecycle, not the in-app MsiHandoff UI or
# Ed25519 feed authorization; both require a separate signed-feed E2E test.
# Uses immutable Fulcrum v0.13.1 -> v0.13.2 public release assets.
[CmdletBinding()]
param(
  [string]$OldVersion = "0.13.1",
  [string]$NewVersion = "0.13.2"
)
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($OldVersion -eq $NewVersion) {
  throw "Upgrade test requires two different versions"
}

$root = Join-Path $env:RUNNER_TEMP ("fulcrum-msi-upgrade-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$uninstallPaths = @(
  "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
  "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)
$msiexec = Join-Path $env:SystemRoot "System32\msiexec.exe"

function Get-FulcrumInstallation {
  @(
    foreach ($registryPath in $uninstallPaths) {
      Get-ItemProperty -Path $registryPath -ErrorAction SilentlyContinue |
        Where-Object { $_.PSObject.Properties["DisplayName"] -and
                       $_.DisplayName -eq "Fulcrum" }
    }
  )
}

function Require-InstalledVersion([string]$version) {
  $entries = @(Get-FulcrumInstallation)
  if ($entries.Count -ne 1) {
    throw "Expected one registered Fulcrum MSI, found $($entries.Count)"
  }
  if ([string]$entries[0].DisplayVersion -ne $version) {
    throw "Expected installed version $version; got $($entries[0].DisplayVersion)"
  }
  $exe = Join-Path $env:ProgramFiles "Fulcrum\RivetHost.exe"
  if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
    throw "Expected installed executable at $exe"
  }
  Write-Host "PASS: installed Fulcrum $version with one MSI registration and executable"
}

function Get-OfficialMsi([string]$version) {
  $base = "https://github.com/turinglambdaai/fulcrum/releases/download/v$version"
  $filename = "fulcrum-$version-windows-x64.msi"
  $destination = Join-Path $root $filename
  $shaFile = "$destination.sha256"
  Invoke-WebRequest -Uri "$base/$filename" -OutFile $destination -MaximumRedirection 5
  Invoke-WebRequest -Uri "$base/$filename.sha256" -OutFile $shaFile -MaximumRedirection 5
  $checksumText = (Get-Content -LiteralPath $shaFile -Raw).Trim()
  if ($checksumText -notmatch "(?i)^([0-9a-f]{64})\s+\*?\S+") {
    throw "Official checksum sidecar is missing SHA-256: $shaFile"
  }
  $expected = $Matches[1].ToLowerInvariant()
  $actual = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actual -ne $expected) {
    throw "Published MSI hash mismatch for $version"
  }
  Write-Host "PASS: official release $version MSI SHA-256 is correct"
  return $destination
}

function Invoke-Msi([string]$verb, [string]$msiOrGuid, [string]$label) {
  $log = Join-Path $root "$label.log"
  $argLine = "/$verb `"$msiOrGuid`" /qn /norestart /L*v `"$log`""
  Write-Host "Running Windows Installer: $label"
  $process = Start-Process -FilePath $msiexec -ArgumentList $argLine -Wait -PassThru
  if ($process.ExitCode -notin @(0, 3010)) {
    if (Test-Path $log) {
      Get-Content $log -Tail 45 | ForEach-Object { Write-Host $_ }
    }
    throw "msiexec $label failed with exit code $($process.ExitCode)"
  }
  if ($process.ExitCode -eq 3010) {
    throw "msiexec $label requested a reboot; cannot assert a complete in-session upgrade"
  }
}

$installed = $false
try {
  if (@(Get-FulcrumInstallation).Count -gt 0) {
    throw "Runner is not clean: a Fulcrum MSI is already installed"
  }

  $old = Get-OfficialMsi $OldVersion
  $new = Get-OfficialMsi $NewVersion

  Invoke-Msi "i" $old "install-old"
  $installed = $true
  Require-InstalledVersion $OldVersion

  Invoke-Msi "i" $new "upgrade-new"
  Require-InstalledVersion $NewVersion
  Write-Host "PASS: major upgrade $OldVersion -> $NewVersion removed the previous registration"
} finally {
  if ($installed) {
    $entries = @(Get-FulcrumInstallation)
    foreach ($entry in $entries) {
      if ($entry.PSChildName -notmatch "^\{[0-9A-Fa-f-]{36}\}$") {
        Write-Warning "Cannot safely extract MSI ProductCode from $($entry.PSChildName)"
        continue
      }
      try {
        Invoke-Msi "x" $entry.PSChildName "uninstall"
        Write-Host "Cleanup: removed test Fulcrum installation"
      } catch {
        Write-Warning "Cleanup failed: $_"
      }
    }
  }
  Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
