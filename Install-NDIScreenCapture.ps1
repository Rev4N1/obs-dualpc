<#
.SYNOPSIS
  Installs only NDI Screen Capture (and optionally Screen Capture HX) from the newest NDI Tools
  installer. Everything it needs is downloaded automatically. It extracts just the Screen Capture
  files to Program Files, allows them through Windows Firewall and creates Start Menu and Desktop
  shortcuts. Nothing else from NDI Tools is installed. Elevates itself when needed.

.PARAMETER Installer
  Path or URL of an NDI Tools installer. Default: the newest *NDI*Tools*.exe next to this script,
  otherwise the download link currently published on ndi.video.

.NOTES
  Nothing is pinned to a version: the NDI Tools link is resolved from ndi.video on every run, and
  innoextract comes from the project's latest GitHub release, verified against its SHA256
  when GitHub publishes one.

.EXAMPLE
  .\Install-NDIScreenCapture.ps1                    # newest NDI Tools, downloaded automatically
  .\Install-NDIScreenCapture.ps1 -IncludeHX         # also install Screen Capture HX
  .\Install-NDIScreenCapture.ps1 "D:\NDI Tools.exe"
  .\Install-NDIScreenCapture.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Installer,
    [string]$InstallDir = (Join-Path $env:ProgramFiles 'NDI Screen Capture'),
    [string]$NdiToolsPage = 'https://ndi.video/tools/download/',
    [switch]$IncludeHX,       # also install Screen Capture HX
    [switch]$AllowPublic,     # also allow on Public networks (default: Private and Domain only)
    [switch]$NoDesktopShortcut,
    [switch]$KeepInstaller,   # keep the downloaded NDI Tools installer afterwards
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

# Relaunch elevated, passing the same arguments
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$PSCommandPath`"")
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [switch]) { if ($kv.Value) { $argList += "-$($kv.Key)" } }
        else {
            $value = Resolve-Path $kv.Value -ErrorAction SilentlyContinue
            if (-not $value) { $value = $kv.Value }
            $argList += "-$($kv.Key)", "`"$value`""
        }
    }
    $shell = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
    Start-Process $shell -Verb RunAs -ArgumentList $argList
    return
}

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13 }
catch { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }
$ProgressPreference = 'SilentlyContinue'   # much faster downloads on PowerShell 5.1

$startMenuDir = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\NDI Screen Capture'
$desktopDir   = [Environment]::GetFolderPath('CommonDesktopDirectory')
$rulePrefix   = 'NDI Screen Capture'

# innoextract is the only tool needed to pull single components out of the Inno Setup installer.
# Its newest release is resolved from the GitHub API.
$innoApi = 'https://api.github.com/repos/dscharrer/innoextract/releases/latest'

# NDI Tools is published as "NDI <major> Tools.exe"; the newest major that exists is used.
$ndiToolsBase = 'https://downloads.ndi.tv/Tools/NDI%20{0}%20Tools.exe'

function Invoke-Download([string]$Url, [string]$Path) {
    Write-Host "Downloading $Url"
    Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing -Headers @{ 'User-Agent' = 'ndi-screen-capture-installer' }
    $item = Get-Item $Path
    Write-Host ("  {0:N1} MB" -f ($item.Length / 1MB))
}

function Get-InnoExtract([string]$WorkDir) {
    $cmd = Get-Command innoextract -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    Write-Host 'Resolving the newest innoextract release...'
    $release = Invoke-RestMethod -Uri $innoApi -Headers @{ 'User-Agent' = 'ndi-screen-capture-installer' }
    $asset = $release.assets | Where-Object { $_.name -match '-windows\.zip$' } | Select-Object -First 1
    if (-not $asset) { throw 'No Windows build found in the latest innoextract release.' }

    $zip = Join-Path $WorkDir $asset.name
    Invoke-Download $asset.browser_download_url $zip

    if ($asset.digest -match '^sha256:([0-9a-fA-F]{64})$') {
        if ((Get-FileHash $zip -Algorithm SHA256).Hash -ne $Matches[1]) { throw 'innoextract download failed the SHA256 check.' }
    }
    else {
        Write-Warning "No published hash for $($asset.name); skipping verification."
    }

    Expand-Archive -Path $zip -DestinationPath (Join-Path $WorkDir 'innoextract')
    return Join-Path $WorkDir 'innoextract\innoextract.exe'
}

function Get-LatestNdiToolsUrl {
    # Preferred: ask the download page which installer it points at right now.
    foreach ($page in @($NdiToolsPage, 'https://ndi.video/tools/')) {
        try { $html = (Invoke-WebRequest -Uri $page -UseBasicParsing -TimeoutSec 30).Content } catch { continue }
        $links = [regex]::Matches($html, 'https://downloads\.ndi\.tv/Tools/[^"''<>\s]+\.exe') |
            ForEach-Object { $_.Value } | Select-Object -Unique
        foreach ($link in $links) {
            try {
                if ((Invoke-WebRequest -Uri $link -Method Head -UseBasicParsing -TimeoutSec 30).StatusCode -eq 200) { return $link }
            }
            catch { }
        }
    }

    # Fallback: probe the download server for the highest major that exists.
    $latest = $null
    for ($major = 5; $major -le 20; $major++) {
        try {
            Invoke-WebRequest -Uri ($ndiToolsBase -f $major) -Method Head -UseBasicParsing -TimeoutSec 20 | Out-Null
            $latest = $ndiToolsBase -f $major
        }
        catch { if ($latest) { break } }
    }
    if (-not $latest) { throw 'Could not resolve an NDI Tools download link. Pass the installer path or URL as the first argument.' }
    return $latest
}

function Get-NdiToolsInstaller([string]$WorkDir) {
    if ($Installer -and $Installer -match '^https?://') {
        $target = Join-Path $WorkDir 'NDI Tools.exe'
        Invoke-Download $Installer $target
        return $target
    }
    if ($Installer) { return (Resolve-Path $Installer).Path }

    $local = Get-ChildItem -Path $PSScriptRoot -Filter '*NDI*Tools*.exe' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($local) { return $local.FullName }

    Write-Host 'No local NDI Tools installer found, fetching the latest one...'
    $url = Get-LatestNdiToolsUrl
    $target = Join-Path $WorkDir ([IO.Path]::GetFileName([Uri]::UnescapeDataString($url)))
    Invoke-Download $url $target

    $signature = Get-AuthenticodeSignature $target
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'NDI|Vizrt') {
        throw "The downloaded NDI Tools installer failed its signature check ($($signature.Status))."
    }
    return $target
}

function Remove-ScreenCaptureFirewallRules {
    # Our own rules, plus any rules Windows created for Screen Capture (often Block rules from a dismissed prompt)
    Get-NetFirewallRule -DisplayName "$rulePrefix*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    Get-NetFirewallApplicationFilter | Where-Object { $_.Program -match 'ScanConverter(2|HX)' } |
        Get-NetFirewallRule -ErrorAction SilentlyContinue | Remove-NetFirewallRule
}

function Stop-ScreenCapture {
    Get-Process -Name 'Application.Network.ScanConverter*' -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "Stopping $($_.Name)..."
        $_ | Stop-Process -Force
        $_.WaitForExit(5000) | Out-Null
    }
}

if ($Uninstall) {
    Stop-ScreenCapture
    Remove-ScreenCaptureFirewallRules
    Remove-Item -Recurse -Force $startMenuDir -ErrorAction SilentlyContinue
    foreach ($name in 'NDI Screen Capture', 'NDI Screen Capture HX') { Remove-Item (Join-Path $desktopDir "$name.lnk") -ErrorAction SilentlyContinue }
    Remove-Item -Recurse -Force $InstallDir -ErrorAction SilentlyContinue
    Write-Host 'NDI Screen Capture uninstalled.' -ForegroundColor Green
    return
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("ndi-extract-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    # 1. Get the NDI Tools installer and innoextract
    $ndi = Get-NdiToolsInstaller $tmp
    $version = (Get-Item $ndi).VersionInfo.ProductVersion
    Write-Host ("Installer: {0}{1}" -f $ndi, $(if ($version) { " (v$version)" }))

    $inno = Get-InnoExtract $tmp

    # 2. Extract only the Screen Capture component
    Stop-ScreenCapture
    $files = Join-Path $tmp 'files'
    & $inno --silent --progress=0 --output-dir $files --include 'Screen Capture' $ndi
    if ($LASTEXITCODE -ne 0) { throw "innoextract failed (exit code $LASTEXITCODE). The installer may use an Inno Setup version innoextract does not support yet." }

    $exes = @(Get-ChildItem -Path $files -Recurse -File -Filter 'Application.Network.ScanConverter*.exe' -ErrorAction SilentlyContinue)
    if (-not $exes) {
        # Component names change between NDI releases; fall back to a full extraction.
        Write-Host 'Screen Capture component not found by name, extracting everything...'
        $files = Join-Path $tmp 'all'
        & $inno --silent --progress=0 --output-dir $files $ndi
        if ($LASTEXITCODE -ne 0) { throw "innoextract failed (exit code $LASTEXITCODE)." }
        $exes = @(Get-ChildItem -Path $files -Recurse -File -Filter 'Application.Network.ScanConverter*.exe')
    }
    if (-not $exes) { throw 'Screen Capture was not found in the installer.' }

    $apps = @()
    foreach ($group in $exes | Group-Object { if ($_.Name -match 'HX') { 'HX' } else { 'Plain' } }) {
        if ($group.Name -eq 'HX' -and -not $IncludeHX) { continue }
        # prefer the 64-bit build when both exist
        $exe = $group.Group | Sort-Object { if ($_.Name -match 'x64') { 0 } else { 1 } } | Select-Object -First 1
        $apps += @{ Exe = $exe.Name; Name = if ($group.Name -eq 'HX') { 'NDI Screen Capture HX' } else { 'NDI Screen Capture' }; Source = $exe.FullName }
    }

    # 3. Copy into Program Files
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    foreach ($app in $apps) {
        Copy-Item $app.Source -Destination $InstallDir -Force
        $item = Get-Item (Join-Path $InstallDir $app.Exe)
        Write-Host ("Installed {0} ({1:N1} MB, v{2})" -f $app.Name, ($item.Length / 1MB), $item.VersionInfo.ProductVersion)
    }

    if ($KeepInstaller) {
        $keep = Join-Path $InstallDir ([IO.Path]::GetFileName($ndi))
        if ($ndi -ne $keep) { Copy-Item $ndi $keep -Force; Write-Host "Kept installer at $keep" }
    }
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

# 4. Firewall: inbound allow for each exe (NDI uses TCP/UDP 5960+ and mDNS on UDP 5353)
Remove-ScreenCaptureFirewallRules
$profiles = if ($AllowPublic) { 'Any' } else { 'Private, Domain' }
foreach ($app in $apps) {
    New-NetFirewallRule -DisplayName $app.Name -Description 'Allows NDI receivers on the network to find and receive this source.' `
        -Direction Inbound -Action Allow -Program (Join-Path $InstallDir $app.Exe) -Profile $profiles -ErrorAction Stop | Out-Null
    Write-Host "Firewall: allowed $($app.Name) ($profiles)"
}

# 5. Shortcuts
$wsh = New-Object -ComObject WScript.Shell
function New-Shortcut([string]$Path, [string]$Target, [string]$Description) {
    $lnk = $wsh.CreateShortcut($Path)
    $lnk.TargetPath = $Target
    $lnk.WorkingDirectory = Split-Path $Target
    $lnk.IconLocation = "$Target,0"
    $lnk.Description = $Description
    $lnk.Save()
}
New-Item -ItemType Directory -Force -Path $startMenuDir | Out-Null
foreach ($app in $apps) {
    $exe = Join-Path $InstallDir $app.Exe
    New-Shortcut (Join-Path $startMenuDir "$($app.Name).lnk") $exe $app.Name
    if (-not $NoDesktopShortcut) { New-Shortcut (Join-Path $desktopDir "$($app.Name).lnk") $exe $app.Name }
}
Write-Host ('Shortcuts: Start Menu' + $(if (-not $NoDesktopShortcut) { ' and Desktop' }))

if (-not $AllowPublic -and (Get-NetConnectionProfile | Where-Object NetworkCategory -eq 'Public')) {
    Write-Warning 'A network is set to Public, where the firewall rule does not apply. Switch it to Private or rerun with -AllowPublic.'
}
Write-Host "`nInstalled to $InstallDir" -ForegroundColor Green
