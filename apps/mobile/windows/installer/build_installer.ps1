[CmdletBinding()]
param(
    [string]$BundlePath,
    [string]$OutputPath,
    [string]$AppVersion,
    [string]$InnoCompilerPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RequiredPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$Description,
        [switch]$File
    )

    if (-not (Test-Path -LiteralPath $Path -PathType $(if ($File) { 'Leaf' } else { 'Container' }))) {
        throw "$Description was not found: $Path"
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Find-InnoCompiler {
    param([string]$ExplicitPath)

    if ($ExplicitPath) {
        return Resolve-RequiredPath -Path $ExplicitPath -Description 'Inno Setup compiler' -File
    }

    $command = Get-Command 'ISCC.exe' -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw 'Inno Setup 6 is required. Install the pinned build dependency before running this script.'
}

function Read-PubspecVersion {
    param([Parameter(Mandatory)][string]$PubspecPath)

    $match = [regex]::Match(
        [IO.File]::ReadAllText($PubspecPath),
        '(?m)^version:\s*(\d+)\.(\d+)\.(\d+)(?:\+(\d+))?\s*$'
    )
    if (-not $match.Success) {
        throw 'pubspec.yaml must contain a numeric major.minor.patch version and optional build number.'
    }
    return $match.Value.Substring($match.Value.IndexOf(':') + 1).Trim()
}

function Convert-ToWindowsVersion {
    param([Parameter(Mandatory)][string]$Version)

    $match = [regex]::Match($Version, '^(\d+)\.(\d+)\.(\d+)(?:\+(\d+))?$')
    if (-not $match.Success) {
        throw "Unsupported app version: $Version"
    }
    $parts = @(
        [int]$match.Groups[1].Value,
        [int]$match.Groups[2].Value,
        [int]$match.Groups[3].Value,
        $(if ($match.Groups[4].Success) { [int]$match.Groups[4].Value } else { 0 })
    )
    if ($parts.Where({ $_ -lt 0 -or $_ -gt 65535 }).Count -ne 0) {
        throw 'Every Windows version component must be between 0 and 65535.'
    }
    return $parts -join '.'
}

function Test-FlutterBundle {
    param([Parameter(Mandatory)][string]$Root)

    $requiredFiles = @(
        'nextcloudtalk.exe',
        'flutter_windows.dll',
        'data\app.so',
        'data\icudtl.dat',
        'data\flutter_assets\AssetManifest.bin'
    )
    foreach ($relativePath in $requiredFiles) {
        $candidate = Join-Path $Root $relativePath
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "The Flutter release bundle is incomplete: $relativePath is missing."
        }
    }

    $entries = Get-ChildItem -LiteralPath $Root -Recurse -Force
    $reparsePoint = $entries | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } | Select-Object -First 1
    if ($reparsePoint) {
        throw "The bundle must not contain reparse points: $($reparsePoint.FullName)"
    }
    $emptyFile = $entries | Where-Object { -not $_.PSIsContainer -and $_.Length -eq 0 } | Select-Object -First 1
    if ($emptyFile) {
        throw "The bundle contains an empty file: $($emptyFile.FullName)"
    }
}

$installerRoot = $PSScriptRoot
$mobileRoot = (Resolve-Path -LiteralPath (Join-Path $installerRoot '..\..')).Path
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $installerRoot '..\..\..\..')).Path
$pubspecPath = Join-Path $mobileRoot 'pubspec.yaml'
$sourcePath = Join-Path $installerRoot 'nextcloudtalk.iss'

if (-not $BundlePath) {
    $BundlePath = Join-Path $mobileRoot 'build\windows\x64\runner\Release'
}
if (-not $OutputPath) {
    $OutputPath = Join-Path $mobileRoot 'build\windows\installer'
}
if (-not $AppVersion) {
    $AppVersion = Read-PubspecVersion -PubspecPath $pubspecPath
}

$resolvedBundle = Resolve-RequiredPath -Path $BundlePath -Description 'Flutter Windows release bundle'
$resolvedSource = Resolve-RequiredPath -Path $sourcePath -Description 'Inno Setup source' -File
$resolvedLicense = Resolve-RequiredPath -Path (Join-Path $repoRoot 'LICENSE') -Description 'GPL license' -File
$compiler = Find-InnoCompiler -ExplicitPath $InnoCompilerPath
$numericVersion = Convert-ToWindowsVersion -Version $AppVersion
$safeVersion = $AppVersion -replace '[^0-9A-Za-z.-]', '-'

Test-FlutterBundle -Root $resolvedBundle

$null = New-Item -ItemType Directory -Path $OutputPath -Force
$resolvedOutput = (Resolve-Path -LiteralPath $OutputPath).Path
$workPath = Join-Path $resolvedOutput 'work'
$null = New-Item -ItemType Directory -Path $workPath -Force
$manifestPath = Join-Path $workPath "bundle-manifest-$safeVersion.json"

$bundleFiles = Get-ChildItem -LiteralPath $resolvedBundle -Recurse -File | ForEach-Object {
    [ordered]@{
        path = $_.FullName.Substring($resolvedBundle.Length + 1).Replace('\', '/')
        size = $_.Length
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
} | Sort-Object path

$manifest = [ordered]@{
    schemaVersion = 1
    packageVersion = $AppVersion
    windowsVersion = $numericVersion
    architecture = 'x64'
    files = @($bundleFiles)
}
[IO.File]::WriteAllText(
    $manifestPath,
    ($manifest | ConvertTo-Json -Depth 5),
    [Text.UTF8Encoding]::new($false)
)

$expectedInstaller = Join-Path $resolvedOutput "NKS-Talk-$safeVersion-windows-x64-setup.exe"
if (Test-Path -LiteralPath $expectedInstaller -PathType Leaf) {
    Remove-Item -LiteralPath $expectedInstaller -Force
}

$arguments = @(
    '/Qp',
    "/DBundleDir=$resolvedBundle",
    "/DBundleManifest=$manifestPath",
    "/DRepoRoot=$repoRoot",
    "/DOutputDir=$resolvedOutput",
    "/DAppVersion=$AppVersion",
    "/DNumericVersion=$numericVersion",
    "/DSafeVersion=$safeVersion",
    $resolvedSource
)
& $compiler @arguments
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup failed with exit code $LASTEXITCODE."
}

$resolvedInstaller = Resolve-RequiredPath -Path $expectedInstaller -Description 'Compiled Windows installer' -File
$signature = Get-AuthenticodeSignature -LiteralPath $resolvedInstaller
$result = [ordered]@{
    installer = $resolvedInstaller
    packageVersion = $AppVersion
    windowsVersion = $numericVersion
    bundleFileCount = @($bundleFiles).Count
    installerBytes = (Get-Item -LiteralPath $resolvedInstaller).Length
    installerSha256 = (Get-FileHash -LiteralPath $resolvedInstaller -Algorithm SHA256).Hash.ToLowerInvariant()
    signatureStatus = $signature.Status.ToString()
    license = $resolvedLicense
}
$result | ConvertTo-Json
