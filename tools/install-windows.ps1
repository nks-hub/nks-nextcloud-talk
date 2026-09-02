<#
.SYNOPSIS
    Installs a built NKS Talk Windows release over any copy already present.

.DESCRIPTION
    Written after a deployment mistake worth not repeating: the build was
    unzipped into a new directory while an older copy stayed at its original
    location with its own shortcuts. The tester opened the old one, and its
    diagnostics screen honestly reported a build number from a week earlier.
    Two copies of the same app on one machine is the failure; a script that
    always installs over the existing location is the fix.

    It also registers the `nctalk:` protocol, which is what actually makes a
    conversation link open the app. That registration only ever existed in an
    installer this project does not have, so every hand-unzipped deployment
    silently lacked deep links.

    Everything is per-user (HKCU, no elevation) unless -Destination points
    somewhere that needs it.

.PARAMETER SourceDirectory
    The `build\windows\x64\runner\Release` directory of the build to install.

.PARAMETER Destination
    Where the app should live. Defaults to the copy already installed, so
    repeat runs stay in place; falls back to Program Files on a first install.

.EXAMPLE
    .\install-windows.ps1 -SourceDirectory C:\build\Release
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceDirectory,

    [string]$Destination,

    [switch]$SkipLaunch
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$exeName = 'nextcloudtalk.exe'
$sourceExe = Join-Path $SourceDirectory $exeName
if (-not (Test-Path -LiteralPath $sourceExe)) {
    throw "No $exeName in $SourceDirectory - point -SourceDirectory at the Release folder of a Windows build."
}
$sourceVersion = (Get-Item -LiteralPath $sourceExe).VersionInfo.FileVersion
$sourceFull = (Resolve-Path -LiteralPath $SourceDirectory).ProviderPath.TrimEnd([char]92)
Write-Host "Installing $exeName $sourceVersion"

# Every copy already on this machine, so none is left behind to be opened by
# mistake. Program Files and the per-user locations are searched rather than
# the whole drive: a full scan takes minutes and finds build outputs too.
$searchRoots = @(
    $env:ProgramFiles,
    ${env:ProgramFiles(x86)},
    $env:LOCALAPPDATA,
    (Join-Path $env:SystemDrive 'nctalk')
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

$existing = @()
foreach ($root in $searchRoots) {
    $existing += Get-ChildItem -LiteralPath $root -Recurse -Filter $exeName `
        -ErrorAction SilentlyContinue -Force |
        Select-Object -ExpandProperty FullName
}
# The staged build itself often sits under one of those roots, and it is not
# an installed copy: the first run of this script picked its own source as the
# destination and then emptied it before copying. Excluded explicitly.
# Wrapped in @() because a pipeline that yields one item is not an array, and
# StrictMode refuses `.Count` on a bare object.
$existing = @($existing |
    Where-Object { (Split-Path -Parent $_).TrimEnd([char]92) -ne $sourceFull } |
    Sort-Object -Unique)

if (-not $Destination) {
    $Destination = if ($existing.Count -gt 0) {
        Split-Path -Parent $existing[0]
    } else {
        Join-Path $env:ProgramFiles 'NKS Talk'
    }
}
$destinationExe = Join-Path $Destination $exeName
$destinationResolved = Resolve-Path -LiteralPath $Destination -ErrorAction SilentlyContinue
if ($destinationResolved -and $destinationResolved.ProviderPath.TrimEnd([char]92) -eq $sourceFull) {
    throw "Refusing to install a build over its own source directory: $sourceFull"
}
Write-Host "Destination: $Destination"

foreach ($path in $existing) {
    if ((Split-Path -Parent $path) -ne $Destination) {
        Write-Host "Removing an older copy: $path"
    }
}

# A running instance holds its own executable open, so it has to stop before
# the files can be replaced. Stopped by id, never by name: killing every
# process that shares a name is how unrelated work gets destroyed.
foreach ($process in @(Get-Process -Name 'nextcloudtalk' -ErrorAction SilentlyContinue)) {
    Write-Host "Stopping running instance, pid $($process.Id)"
    Stop-Process -Id $process.Id -Force
}
Start-Sleep -Seconds 2

foreach ($path in $existing) {
    $directory = Split-Path -Parent $path
    if ($directory -ne $Destination) {
        Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if (Test-Path -LiteralPath $Destination) {
    Get-ChildItem -LiteralPath $Destination -Recurse -Force |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
} else {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
}
Copy-Item -Path (Join-Path $SourceDirectory '*') -Destination $Destination -Recurse -Force

$installedVersion = (Get-Item -LiteralPath $destinationExe).VersionInfo.FileVersion
if ($installedVersion -ne $sourceVersion) {
    throw "Installed $installedVersion but the source was $sourceVersion."
}

$shell = New-Object -ComObject WScript.Shell
$shortcuts = @(
    (Join-Path ([Environment]::GetFolderPath('Desktop')) 'NKS Talk.lnk'),
    (Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs\NKS Talk.lnk')
)
foreach ($shortcutPath in $shortcuts) {
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $destinationExe
    $shortcut.WorkingDirectory = $Destination
    $shortcut.Save()
}

# What turns a conversation link into an opened room. The runner already
# parses `nctalk://call/<token>` and hands a second launch to the instance
# that is already running; without this key nothing ever calls it.
$protocolRoot = 'HKCU:\Software\Classes\nctalk'
New-Item -Path $protocolRoot -Force | Out-Null
Set-ItemProperty -Path $protocolRoot -Name '(default)' -Value 'URL:NKS Talk Protocol'
Set-ItemProperty -Path $protocolRoot -Name 'URL Protocol' -Value ''
New-Item -Path "$protocolRoot\DefaultIcon" -Force | Out-Null
Set-ItemProperty -Path "$protocolRoot\DefaultIcon" -Name '(default)' -Value "`"$destinationExe`",0"
New-Item -Path "$protocolRoot\shell\open\command" -Force | Out-Null
Set-ItemProperty -Path "$protocolRoot\shell\open\command" -Name '(default)' -Value "`"$destinationExe`" `"%1`""

$remaining = @()
foreach ($root in $searchRoots) {
    $remaining += Get-ChildItem -LiteralPath $root -Recurse -Filter $exeName `
        -ErrorAction SilentlyContinue -Force |
        Select-Object -ExpandProperty FullName
}
$remaining = @($remaining |
    Where-Object { (Split-Path -Parent $_).TrimEnd([char]92) -ne $sourceFull } |
    Sort-Object -Unique)
if ($remaining.Count -ne 1) {
    throw "Expected exactly one installed copy, found $($remaining.Count): $($remaining -join ', ')"
}

if (-not $SkipLaunch) {
    Start-Process -FilePath $destinationExe -WorkingDirectory $Destination
}

Write-Host "Installed $installedVersion at $Destination"
Write-Host "Protocol nctalk: registered for the current user"
