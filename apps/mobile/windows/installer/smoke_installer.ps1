[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$InstallerPath,
    [string]$PreviousInstallerPath,
    [string]$EvidencePath,
    [switch]$ResetExistingInstallation,
    [switch]$InstallerLifecycleOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ('NativeWindowVisibility' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class NativeWindowVisibility
{
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsWindowVisible(IntPtr windowHandle);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool ShowWindowAsync(IntPtr windowHandle, int command);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetForegroundWindow(IntPtr windowHandle);
}
'@
}

function Resolve-RequiredFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Description)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description was not found: $Path"
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Invoke-HiddenProcess {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$ArgumentList
    )

    $process = Start-Process `
        -FilePath $Path `
        -ArgumentList $ArgumentList `
        -PassThru `
        -WindowStyle Hidden
    $visibleWindowObserved = $false
    while (-not $process.WaitForExit(50)) {
        $process.Refresh()
        $windowHandle = $process.MainWindowHandle
        if ($null -ne $windowHandle -and
            $windowHandle -ne [IntPtr]::Zero -and
            [NativeWindowVisibility]::IsWindowVisible($windowHandle)) {
            $visibleWindowObserved = $true
        }
    }
    $process.Refresh()
    return [ordered]@{
        exitCode = $process.ExitCode
        visibleWindowObserved = $visibleWindowObserved
    }
}

function Invoke-SetupProcess {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$LogPath
    )

    return Invoke-HiddenProcess -Path $Path -ArgumentList @(
        '/VERYSILENT',
        '/SUPPRESSMSGBOXES',
        '/NORESTART',
        '/NOCANCEL',
        '/CURRENTUSER',
        "/LOG=$LogPath"
    )
}

function Invoke-SetupExecutable {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$LogPath
    )

    $result = Invoke-SetupProcess -Path $Path -LogPath $LogPath
    if ($result.visibleWindowObserved) {
        throw 'Installer exposed a visible top-level window during silent setup.'
    }
    if ($result.exitCode -ne 0) {
        throw "Installer failed with exit code $($result.exitCode)."
    }
}

function Invoke-Uninstaller {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$LogPath
    )

    $result = Invoke-HiddenProcess -Path $Path -ArgumentList @(
        '/VERYSILENT',
        '/SUPPRESSMSGBOXES',
        '/NORESTART',
        "/LOG=$LogPath"
    )
    if ($result.visibleWindowObserved) {
        throw 'Uninstaller exposed a visible top-level window during silent removal.'
    }
    if ($result.exitCode -ne 0) {
        throw "Uninstaller failed with exit code $($result.exitCode)."
    }
}

function Wait-PathAbsent {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Description,
        [int]$TimeoutSeconds = 10,
        [switch]$RemoveEmptyDirectory
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ((Test-Path -LiteralPath $Path) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    if ((Test-Path -LiteralPath $Path -PathType Container) -and $RemoveEmptyDirectory) {
        $remainingEntries = @(Get-ChildItem -LiteralPath $Path -Force)
        if ($remainingEntries.Count -eq 0) {
            Remove-Item -LiteralPath $Path
        }
    }
    if (Test-Path -LiteralPath $Path) {
        throw "$Description was not removed within $TimeoutSeconds seconds."
    }
}

function Test-InstalledBundle {
    param([Parameter(Mandatory)][string]$InstallRoot)

    $manifestPath = Join-Path $InstallRoot 'bundle-manifest.json'
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    foreach ($entry in $manifest.files) {
        $relativePath = ([string]$entry.path).Replace('/', '\')
        $installedPath = Join-Path $InstallRoot $relativePath
        if (-not (Test-Path -LiteralPath $installedPath -PathType Leaf)) {
            throw "Installed bundle file is missing: $relativePath"
        }
        $file = Get-Item -LiteralPath $installedPath
        if ($file.Length -ne [long]$entry.size) {
            throw "Installed bundle file has an unexpected size: $relativePath"
        }
        $hash = (Get-FileHash -LiteralPath $installedPath -Algorithm SHA256).Hash
        if ($hash -ne [string]$entry.sha256) {
            throw "Installed bundle file has an unexpected hash: $relativePath"
        }
    }
    return $manifest
}

function Get-InstalledBundleSnapshot {
    param([Parameter(Mandatory)][string]$InstallRoot)

    $manifest = Test-InstalledBundle -InstallRoot $InstallRoot
    $manifestPath = Join-Path $InstallRoot 'bundle-manifest.json'
    $files = foreach ($entry in $manifest.files) {
        $relativePath = ([string]$entry.path).Replace('/', '\')
        $installedPath = Join-Path $InstallRoot $relativePath
        [ordered]@{
            path = [string]$entry.path
            size = (Get-Item -LiteralPath $installedPath).Length
            sha256 = (Get-FileHash -LiteralPath $installedPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    return [ordered]@{
        manifestSha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        packageVersion = [string]$manifest.packageVersion
        windowsVersion = [string]$manifest.windowsVersion
        files = @($files)
    }
}

function Get-DirectorySnapshot {
    param([Parameter(Mandatory)][string]$Root)

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return ''
    }
    $entries = Get-ChildItem -LiteralPath $Root -Recurse -File | Sort-Object FullName | ForEach-Object {
        $relativePath = $_.FullName.Substring($Root.Length).TrimStart('\')
        $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        "$relativePath|$($_.Length)|$hash"
    }
    return [string]::Join("`n", [string[]]@($entries))
}

function Test-StartMenuShortcut {
    param(
        [Parameter(Mandatory)][string]$ShortcutPath,
        [Parameter(Mandatory)][string]$ExpectedTarget
    )

    if (-not (Test-Path -LiteralPath $ShortcutPath -PathType Leaf)) {
        throw 'The Start menu shortcut was not created.'
    }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    if (-not [string]::Equals($shortcut.TargetPath, $ExpectedTarget, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The Start menu shortcut points to an unexpected executable.'
    }
}

function Start-AndVerifyApplication {
    param(
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][string]$ScreenshotPath
    )

    $process = Start-Process -FilePath $ExecutablePath -WorkingDirectory (Split-Path -Parent $ExecutablePath) -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 500
        $process.Refresh()
        if ($process.HasExited) {
            throw "NKS Talk exited during startup with code $($process.ExitCode)."
        }
    } until (($process.Responding -and $process.MainWindowHandle -ne 0) -or [DateTime]::UtcNow -ge $deadline)

    if (-not $process.Responding -or $process.MainWindowHandle -eq 0) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        throw 'NKS Talk did not expose a responsive top-level window within 30 seconds.'
    }

    try {
        Add-Type -AssemblyName UIAutomationClient
        Add-Type -AssemblyName System.Drawing
        $window = [Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
        $null = [NativeWindowVisibility]::ShowWindowAsync($process.MainWindowHandle, 9)
        $null = [NativeWindowVisibility]::SetForegroundWindow($process.MainWindowHandle)
        $shell = New-Object -ComObject WScript.Shell
        try {
            $null = $shell.AppActivate($process.Id)
        }
        finally {
            $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        }
        try {
            $window.SetFocus()
        }
        catch [InvalidOperationException] {
        }
        Start-Sleep -Milliseconds 500
        $bounds = $window.Current.BoundingRectangle
        $width = [int]$bounds.Width
        $height = [int]$bounds.Height
        if ($width -le 0 -or $height -le 0) {
            throw 'NKS Talk exposed an invalid top-level window rectangle.'
        }

        $bitmap = [Drawing.Bitmap]::new($width, $height)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.CopyFromScreen(
                [int]$bounds.X,
                [int]$bounds.Y,
                0,
                0,
                [Drawing.Size]::new($width, $height)
            )
            $bitmap.Save($ScreenshotPath, [Drawing.Imaging.ImageFormat]::Png)
        }
        finally {
            $graphics.Dispose()
            $bitmap.Dispose()
        }
        if (-not (Test-Path -LiteralPath $ScreenshotPath -PathType Leaf) -or
            (Get-Item -LiteralPath $ScreenshotPath).Length -eq 0) {
            throw 'NKS Talk runtime screenshot was not created.'
        }

        return [ordered]@{
            process = $process
            evidence = [ordered]@{
                responding = $process.Responding
                windowName = $window.Current.Name
                controlType = $window.Current.ControlType.ProgrammaticName
                width = $width
                height = $height
                screenshot = $ScreenshotPath
                screenshotSha256 = (Get-FileHash -LiteralPath $ScreenshotPath -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
    }
    catch {
        Stop-TestApplication -Process $process
        throw
    }
}

function Stop-TestApplication {
    param([Parameter(Mandatory)][Diagnostics.Process]$Process)

    if ($Process.HasExited) {
        return
    }
    $null = $Process.CloseMainWindow()
    if (-not $Process.WaitForExit(5000)) {
        Stop-Process -Id $Process.Id -Force
        $Process.WaitForExit()
    }
}

$currentInstaller = Resolve-RequiredFile -Path $InstallerPath -Description 'Current installer'
$previousInstaller = if ($PreviousInstallerPath) {
    Resolve-RequiredFile -Path $PreviousInstallerPath -Description 'Previous installer'
} else {
    $null
}

if (-not $EvidencePath) {
    $EvidencePath = Join-Path $env:TEMP ("nks-talk-windows-installer-" + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
}
$null = New-Item -ItemType Directory -Path $EvidencePath -Force
$resolvedEvidence = (Resolve-Path -LiteralPath $EvidencePath).Path

$installRoot = Join-Path $env:LOCALAPPDATA 'Programs\NKS Talk'
$executablePath = Join-Path $installRoot 'nextcloudtalk.exe'
$uninstallerPath = Join-Path $installRoot 'unins000.exe'
$shortcutPath = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\NKS Talk\NKS Talk.lnk'
$registryPath = 'HKCU:\Software\NKS Hub\NKS Talk'
$supportRoot = Join-Path $env:APPDATA 'com.nkshub\NKS Talk'
$sentinelPath = Join-Path $supportRoot 'installer-smoke-sentinel.txt'
$sentinelContent = 'preserve-on-upgrade-and-uninstall'
$supportSnapshotBefore = if ($InstallerLifecycleOnly) {
    Get-DirectorySnapshot -Root $supportRoot
} else {
    $null
}

if ($ResetExistingInstallation) {
    $existingProcessIds = @(
        Get-Process -Name nextcloudtalk -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty Id
    )
    foreach ($existingProcessId in $existingProcessIds) {
        $existingProcess = Get-Process -Id $existingProcessId -ErrorAction SilentlyContinue
        if ($existingProcess) {
            Stop-TestApplication -Process $existingProcess
        }
    }
}
if ($ResetExistingInstallation -and
    (Test-Path -LiteralPath $installRoot -PathType Container) -and
    @(Get-ChildItem -LiteralPath $installRoot -Force).Count -eq 0) {
    Remove-Item -LiteralPath $installRoot
}
if ($ResetExistingInstallation -and
    (Test-Path -LiteralPath $installRoot -PathType Container) -and
    -not (Test-Path -LiteralPath $uninstallerPath -PathType Leaf)) {
    Invoke-SetupExecutable `
        -Path $currentInstaller `
        -LogPath (Join-Path $resolvedEvidence 'partial-install-repair.log')
    if (-not (Test-Path -LiteralPath $uninstallerPath -PathType Leaf)) {
        throw 'The current installer did not repair the partial test installation.'
    }
}
if (Test-Path -LiteralPath $uninstallerPath -PathType Leaf) {
    if (-not $ResetExistingInstallation) {
        throw 'NKS Talk is already installed. Pass -ResetExistingInstallation only on a dedicated test machine.'
    }
    Invoke-Uninstaller -Path $uninstallerPath -LogPath (Join-Path $resolvedEvidence 'initial-uninstall.log')
    Wait-PathAbsent `
        -Path $installRoot `
        -Description 'The previous application installation directory' `
        -TimeoutSeconds 20 `
        -RemoveEmptyDirectory
}
if (Test-Path -LiteralPath $installRoot) {
    throw 'The installation directory is not clean after uninstall. No directory was deleted by the test harness.'
}

$firstInstaller = if ($previousInstaller) { $previousInstaller } else { $currentInstaller }
Invoke-SetupExecutable -Path $firstInstaller -LogPath (Join-Path $resolvedEvidence 'clean-install.log')
$firstManifest = Test-InstalledBundle -InstallRoot $installRoot
Test-StartMenuShortcut -ShortcutPath $shortcutPath -ExpectedTarget $executablePath

$null = New-Item -ItemType Directory -Path $supportRoot -Force
if (Test-Path -LiteralPath $sentinelPath -PathType Leaf) {
    $existingSentinel = [IO.File]::ReadAllText($sentinelPath)
    if (-not $ResetExistingInstallation -or $existingSentinel -ne $sentinelContent) {
        throw 'The test sentinel already exists; refusing to overwrite it.'
    }
    Remove-Item -LiteralPath $sentinelPath -Force
}
[IO.File]::WriteAllText($sentinelPath, $sentinelContent, [Text.UTF8Encoding]::new($false))

$upgradeEvidence = $null
$downgradeEvidence = $null
if ($previousInstaller) {
    $runningPrevious = if ($InstallerLifecycleOnly) {
        $null
    } else {
        Start-AndVerifyApplication `
            -ExecutablePath $executablePath `
            -ScreenshotPath (Join-Path $resolvedEvidence 'previous-runtime.png')
    }
    Invoke-SetupExecutable -Path $currentInstaller -LogPath (Join-Path $resolvedEvidence 'upgrade.log')
    $runningProcessClosed = $null
    if ($runningPrevious) {
        $runningPrevious.process.Refresh()
        if (-not $runningPrevious.process.HasExited) {
            Stop-TestApplication -Process $runningPrevious.process
            throw 'The upgrade did not close the running previous version.'
        }
        $runningProcessClosed = $true
    }
    $currentManifest = Test-InstalledBundle -InstallRoot $installRoot
    if ($currentManifest.windowsVersion -eq $firstManifest.windowsVersion) {
        throw 'The upgrade test requires installers with different versions.'
    }
    if (-not (Test-Path -LiteralPath $sentinelPath -PathType Leaf)) {
        throw 'The upgrade removed application support data.'
    }
    $upgradeEvidence = [ordered]@{
        from = $firstManifest.packageVersion
        to = $currentManifest.packageVersion
        runningProcessClosed = $runningProcessClosed
        userDataPreserved = $true
    }

    $beforeDowngrade = Get-InstalledBundleSnapshot -InstallRoot $installRoot
    $downgradeResult = Invoke-SetupProcess `
        -Path $previousInstaller `
        -LogPath (Join-Path $resolvedEvidence 'downgrade-block.log')
    if ($downgradeResult.visibleWindowObserved) {
        throw 'Blocked downgrade exposed a visible top-level window.'
    }
    if ($downgradeResult.exitCode -ne 7) {
        throw "Blocked downgrade returned exit code $($downgradeResult.exitCode) instead of documented code 7."
    }
    $afterDowngrade = Get-InstalledBundleSnapshot -InstallRoot $installRoot
    $beforeDowngradeJson = $beforeDowngrade | ConvertTo-Json -Depth 5 -Compress
    $afterDowngradeJson = $afterDowngrade | ConvertTo-Json -Depth 5 -Compress
    if (-not [string]::Equals($beforeDowngradeJson, $afterDowngradeJson, [StringComparison]::Ordinal)) {
        throw 'The blocked downgrade changed the installed manifest, version, or bundle files.'
    }
    if (-not (Test-Path -LiteralPath $sentinelPath -PathType Leaf)) {
        throw 'The blocked downgrade removed application support data.'
    }
    $downgradeEvidence = [ordered]@{
        attempted = $firstManifest.packageVersion
        retained = $afterDowngrade.packageVersion
        exitCode = $downgradeResult.exitCode
        visibleWindowObserved = $downgradeResult.visibleWindowObserved
        installedFilesUnchanged = $true
        userDataPreserved = $true
    }
}

$runtimeEvidence = if ($InstallerLifecycleOnly) {
    [ordered]@{ executed = $false }
} else {
    $runtime = Start-AndVerifyApplication `
        -ExecutablePath $executablePath `
        -ScreenshotPath (Join-Path $resolvedEvidence 'current-runtime.png')
    Stop-TestApplication -Process $runtime.process
    $runtime.evidence
}
Invoke-Uninstaller -Path $uninstallerPath -LogPath (Join-Path $resolvedEvidence 'final-uninstall.log')

Wait-PathAbsent `
    -Path $installRoot `
    -Description 'The application installation directory' `
    -RemoveEmptyDirectory
Wait-PathAbsent -Path $shortcutPath -Description 'The Start menu shortcut'
Wait-PathAbsent -Path $registryPath -Description 'The installer registry key'
if (-not (Test-Path -LiteralPath $sentinelPath -PathType Leaf)) {
    throw 'The uninstaller removed user data without explicit in-app account cleanup.'
}
Remove-Item -LiteralPath $sentinelPath -Force
if ($InstallerLifecycleOnly) {
    $supportSnapshotAfter = Get-DirectorySnapshot -Root $supportRoot
    if (-not [string]::Equals($supportSnapshotBefore, $supportSnapshotAfter, [StringComparison]::Ordinal)) {
        throw 'The installer-only lifecycle changed existing application support data.'
    }
}

$result = [ordered]@{
    installerSha256 = (Get-FileHash -LiteralPath $currentInstaller -Algorithm SHA256).Hash.ToLowerInvariant()
    cleanInstallVersion = $firstManifest.packageVersion
    bundleFileCount = @($firstManifest.files).Count
    shortcutVerified = $true
    upgrade = $upgradeEvidence
    downgrade = $downgradeEvidence
    runtime = $runtimeEvidence
    uninstall = [ordered]@{
        installFilesRemoved = $true
        shortcutRemoved = $true
        userDataPreserved = $true
    }
}
$resultPath = Join-Path $resolvedEvidence 'result.json'
[IO.File]::WriteAllText($resultPath, ($result | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
$result | ConvertTo-Json -Depth 5
