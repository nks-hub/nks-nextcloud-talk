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

.PARAMETER SearchRoot
    Where to look for copies already on this machine. Defaults to Program Files
    and the per-user locations.

.PARAMETER StartMenuShortcut
    The shortcut whose target names the installation to keep. Defaults to the
    one this script writes in the current user's Start Menu.

.PARAMETER DetectOnly
    Report the copies found and the destination that would be used, then stop
    without deleting, copying or repointing anything.

.EXAMPLE
    .\install-windows.ps1 -SourceDirectory C:\build\Release

.EXAMPLE
    .\install-windows.ps1 -SourceDirectory C:\build\Release -DetectOnly
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceDirectory,

    [string]$Destination,

    [string[]]$SearchRoot,

    [string]$StartMenuShortcut,

    [switch]$DetectOnly,

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

# A backup of an installation is a byte-for-byte copy of it, executable
# included, so no test on the files can tell the two apart - only the path can.
# On 9 September 2026 a run without -Destination chose
# `%LOCALAPPDATA%\NKS Talk Backups\<stamp>\installed-build-62`, which sorts
# before `Programs\NKS Talk`, deleted the real program folder as an older copy
# and left the Start Menu shortcut pointing into the backup tree.
function Test-BackupPath {
    param([string]$Path)
    return $Path -match '(?i)[\\/][^\\/]*(backup|installed-build)[^\\/]*([\\/]|$)'
}

# What the removal below is allowed to delete. A lone executable is not an
# installation either: the whole directory is removed, so a wrong guess
# destroys whatever it was pointed at.
function Test-InstallationDirectory {
    param([string]$Directory)
    if (-not $Directory) { return $false }
    if (Test-BackupPath $Directory) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $Directory $exeName))) { return $false }
    return Test-Path -LiteralPath (Join-Path $Directory 'data\flutter_assets')
}

# Every copy already on this machine, so none is left behind to be opened by
# mistake. Program Files and the per-user locations are searched rather than
# the whole drive: a full scan takes minutes and finds build outputs too.
# The staged build itself often sits under one of those roots and is not an
# installed copy: the first run of this script picked its own source as the
# destination and then emptied it before copying. Excluded explicitly.
# Wrapped in @() because a pipeline that yields one item is not an array, and
# StrictMode refuses `.Count` on a bare object.
function Find-Installation {
    param([string[]]$Roots)
    $found = @()
    foreach ($root in $Roots) {
        $found += Get-ChildItem -LiteralPath $root -Recurse -Filter $exeName `
            -ErrorAction SilentlyContinue -Force |
            Select-Object -ExpandProperty FullName
    }
    return @($found |
        ForEach-Object { (Split-Path -Parent $_).TrimEnd([char]92) } |
        Where-Object { $_ -ne $sourceFull -and (Test-InstallationDirectory $_) } |
        Sort-Object -Unique)
}

if (-not $SearchRoot) {
    $SearchRoot = @(
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:LOCALAPPDATA,
        (Join-Path $env:SystemDrive 'nctalk')
    )
}
$SearchRoot = @($SearchRoot | Where-Object { $_ -and (Test-Path -LiteralPath $_) })

# The shortcut is the best evidence of where the app really lives, because it
# is the thing the person clicks. It is still put through the same test: a
# shortcut already repointed into a backup tree must not drag the install back
# in there.
$shell = New-Object -ComObject WScript.Shell
$startMenu = [Environment]::GetFolderPath('StartMenu')
if (-not $PSBoundParameters.ContainsKey('StartMenuShortcut')) {
    $StartMenuShortcut = if ($startMenu) { Join-Path $startMenu 'Programs\NKS Talk.lnk' } else { $null }
}
$shortcutInstallation = $null
if ($StartMenuShortcut -and (Test-Path -LiteralPath $StartMenuShortcut)) {
    $shortcutTarget = $shell.CreateShortcut($StartMenuShortcut).TargetPath
    if ($shortcutTarget) {
        $candidate = (Split-Path -Parent $shortcutTarget).TrimEnd([char]92)
        if ($candidate -ne $sourceFull -and (Test-InstallationDirectory $candidate)) {
            $shortcutInstallation = $candidate
        }
    }
}

# Wrapped again at the call site: a function that returns one item returns it
# bare, and StrictMode refuses `.Count` on a bare object.
$existing = @(Find-Installation -Roots $SearchRoot)
if ($shortcutInstallation -and $existing -notcontains $shortcutInstallation) {
    $existing = @($shortcutInstallation) + $existing
}

if (-not $Destination) {
    $Destination = if ($shortcutInstallation) {
        $shortcutInstallation
    } elseif ($existing.Count -gt 0) {
        $existing[0]
    } else {
        Join-Path $env:ProgramFiles 'NKS Talk'
    }
}
$Destination = $Destination.TrimEnd([char]92)
$destinationExe = Join-Path $Destination $exeName
$destinationResolved = Resolve-Path -LiteralPath $Destination -ErrorAction SilentlyContinue
if ($destinationResolved -and $destinationResolved.ProviderPath.TrimEnd([char]92) -eq $sourceFull) {
    throw "Refusing to install a build over its own source directory: $sourceFull"
}
Write-Host "Destination: $Destination"

foreach ($directory in $existing) {
    if ($directory -ne $Destination) {
        Write-Host "Removing an older copy: $directory"
    }
}

if ($DetectOnly) {
    Write-Host 'Detection only - nothing was changed.'
    return
}

# A running instance holds its own executable open, so it has to stop before
# the files can be replaced. Stopped by id, never by name: killing every
# process that shares a name is how unrelated work gets destroyed.
foreach ($process in @(Get-Process -Name 'nextcloudtalk' -ErrorAction SilentlyContinue)) {
    Write-Host "Stopping running instance, pid $($process.Id)"
    Stop-Process -Id $process.Id -Force
}
Start-Sleep -Seconds 2

foreach ($directory in $existing) {
    # Tested again immediately before the delete rather than trusted from the
    # search: this is the line that removed the real program folder.
    if ($directory -ne $Destination -and (Test-InstallationDirectory $directory)) {
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

# The Start Menu shortcut is not decoration: Windows refuses to show a toast
# from an unpackaged app unless a shortcut carries its AppUserModelID. The
# first version of this script wrote both shortcuts with WScript.Shell, which
# cannot set that property, and silently cost the app every notification —
# the app asked, Windows dropped it, and nothing anywhere said so.
function Set-AppUserModelId {
    param([string]$ShortcutPath, [string]$AppId)
    $code = @'
using System;
using System.Runtime.InteropServices;
public static class NksAumid {
  [ComImport, Guid("00021401-0000-0000-C000-000000000046")] private class CShellLink {}
  [ComImport, Guid("0000010b-0000-0000-C000-000000000046"),
   InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  private interface IPersistFile {
    void GetClassID(out Guid pClassID);
    [PreserveSig] int IsDirty();
    void Load([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, int dwMode);
    void Save([MarshalAs(UnmanagedType.LPWStr)] string pszFileName,
              [MarshalAs(UnmanagedType.Bool)] bool fRemember);
    void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string pszFileName);
    void GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string ppszFileName);
  }
  [StructLayout(LayoutKind.Sequential)]
  private struct PropertyKey { public Guid fmtid; public uint pid; }
  [StructLayout(LayoutKind.Sequential)]
  private struct PropVariant {
    public ushort vt; public ushort r1, r2, r3; public IntPtr p; public IntPtr p2;
  }
  [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"),
   InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  private interface IPropertyStore {
    void GetCount(out uint cProps);
    void GetAt(uint iProp, out PropertyKey pkey);
    void GetValue(ref PropertyKey key, out PropVariant pv);
    void SetValue(ref PropertyKey key, ref PropVariant pv);
    void Commit();
  }
  public static void Apply(string path, string appId) {
    object link = new CShellLink();
    ((IPersistFile)link).Load(path, 2);
    IPropertyStore store = (IPropertyStore)link;
    PropertyKey key = new PropertyKey();
    key.fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
    key.pid = 5;
    PropVariant pv = new PropVariant();
    pv.vt = 31;
    pv.p = Marshal.StringToCoTaskMemUni(appId);
    store.SetValue(ref key, ref pv);
    store.Commit();
    Marshal.FreeCoTaskMem(pv.p);
    ((IPersistFile)link).Save(path, true);
    Marshal.ReleaseComObject(link);
  }
}
'@
    Add-Type -TypeDefinition $code -Language CSharp -ErrorAction Stop
    [NksAumid]::Apply($ShortcutPath, $AppId)
}

# A service account has no Desktop and no Start Menu, and GetFolderPath then
# returns an empty string rather than failing - which turned into a Join-Path
# error AFTER the files were already copied, leaving a half-done install.
# Measured on a machine where the relay client runs as SYSTEM.
$desktop = [Environment]::GetFolderPath('Desktop')
$shortcuts = @(
    $(if ($desktop) { Join-Path $desktop 'NKS Talk.lnk' }),
    $StartMenuShortcut
) | Where-Object { $_ }
foreach ($shortcutPath in $shortcuts) {
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $destinationExe
    $shortcut.WorkingDirectory = $Destination
    $shortcut.Save()
}
if ($StartMenuShortcut) {
    Set-AppUserModelId -ShortcutPath $StartMenuShortcut -AppId 'com.nkshub.nextcloudtalk'
    Write-Host 'AppUserModelID set on the Start Menu shortcut'
} else {
    # Without a Start Menu shortcut Windows has nowhere to read the
    # AppUserModelID from, so this account cannot raise a toast at all.
    Write-Warning 'No Start Menu for this account - notifications will not appear.'
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

$remaining = @(Find-Installation -Roots $SearchRoot)
if ($remaining.Count -ne 1) {
    throw "Expected exactly one installed copy, found $($remaining.Count): $($remaining -join ', ')"
}

if (-not $SkipLaunch) {
    Start-Process -FilePath $destinationExe -WorkingDirectory $Destination
}

Write-Host "Installed $installedVersion at $Destination"
Write-Host "Protocol nctalk: registered for the current user"
