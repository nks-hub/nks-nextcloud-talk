<#
.SYNOPSIS
    Guards the installation search in install-windows.ps1.

.DESCRIPTION
    Runs the real script with -DetectOnly against throwaway directory trees, so
    the choice of destination is exercised without deleting, copying or
    repointing anything. -DetectOnly prints the same list the removal loop
    iterates, so a copy that is never printed is a copy that is never deleted.

    Written for the Pester that ships with Windows (3.4). The assertions are
    plain throws rather than `Should`, whose syntax changed in Pester 5, so the
    file runs unchanged on either.

.EXAMPLE
    Invoke-Pester -Path .\tools\install-windows.Tests.ps1
#>
Set-StrictMode -Version Latest

$script:InstallScript = Join-Path $PSScriptRoot 'install-windows.ps1'

function Assert-That {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

# A directory that looks like a Flutter Windows release: the executable plus
# the asset tree beside it. A backup copy is byte for byte the same thing,
# which is the whole difficulty.
function New-FakeInstall {
    param([string]$Directory)
    New-Item -ItemType Directory -Path (Join-Path $Directory 'data\flutter_assets') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $Directory 'nextcloudtalk.exe') -Value 'stand-in for a build'
    return $Directory
}

function New-Shortcut {
    param([string]$Path, [string]$Target)
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($Path)
    $shortcut.TargetPath = $Target
    $shortcut.Save()
    return $Path
}

function Invoke-Detect {
    param([string]$Source, [string]$Root, [string]$Shortcut)
    # 6>&1 because the script reports through Write-Host, which is the
    # information stream from PowerShell 5 onwards.
    return & $script:InstallScript -SourceDirectory $Source -SearchRoot $Root `
        -StartMenuShortcut $Shortcut -DetectOnly 6>&1 | Out-String
}

Describe 'install-windows.ps1 destination search' {
    $suite = Join-Path ([System.IO.Path]::GetTempPath()) ("install-windows-tests-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $suite -Force | Out-Null

    try {
        # `NKS Talk Backups` sorts before `Programs`, which is exactly how the
        # backup won on 9 September 2026.
        $source = New-FakeInstall (Join-Path $suite 'source')
        $roots = Join-Path $suite 'roots'
        $real = New-FakeInstall (Join-Path $roots 'Programs\NKS Talk')
        $decoy = New-FakeInstall (Join-Path $roots 'NKS Talk Backups\20260907-a7285846\installed-build-62')
        $missingShortcut = Join-Path $suite 'no-start-menu\NKS Talk.lnk'

        It 'installs into the program folder, not into the backup beside it' {
            $output = Invoke-Detect -Source $source -Root $roots -Shortcut $missingShortcut
            Assert-That $output.Contains("Destination: $real") `
                "Expected the program folder as the destination, got:`n$output"
        }

        It 'never offers a copy under a backup path for removal' {
            $output = Invoke-Detect -Source $source -Root $roots -Shortcut $missingShortcut
            Assert-That (-not $output.Contains($decoy)) `
                "The backup copy was listed and would have been deleted:`n$output"
        }

        It 'does find and offer a second copy that is not a backup' {
            # The negative control. Without it the two tests above would pass on
            # a search that finds nothing at all under the temporary root. Named
            # to sort after `Programs`, so the program folder stays the
            # destination and the sibling is what gets offered for removal.
            $sibling = New-FakeInstall (Join-Path $roots 'Zebra NKS Talk')
            try {
                $output = Invoke-Detect -Source $source -Root $roots -Shortcut $missingShortcut
                Assert-That $output.Contains("Removing an older copy: $sibling") `
                    "An ordinary second copy should have been reported:`n$output"
            } finally {
                Remove-Item -LiteralPath $sibling -Recurse -Force
            }
        }

        It 'keeps the location the Start Menu shortcut points at' {
            $preferred = New-FakeInstall (Join-Path $roots 'Zeta\NKS Talk')
            $shortcut = New-Shortcut -Path (Join-Path $suite 'start-menu\NKS Talk.lnk') `
                -Target (Join-Path $preferred 'nextcloudtalk.exe')
            try {
                $output = Invoke-Detect -Source $source -Root $roots -Shortcut $shortcut
                Assert-That $output.Contains("Destination: $preferred") `
                    "The shortcut target should have won over the first copy found:`n$output"
            } finally {
                Remove-Item -LiteralPath $preferred -Recurse -Force
            }
        }

        It 'ignores a shortcut already repointed into a backup tree' {
            # The state the machine was left in: the shortcut itself named the
            # backup, so trusting it blindly would reinstate the mistake.
            $shortcut = New-Shortcut -Path (Join-Path $suite 'broken-menu\NKS Talk.lnk') `
                -Target (Join-Path $decoy 'nextcloudtalk.exe')
            $output = Invoke-Detect -Source $source -Root $roots -Shortcut $shortcut
            Assert-That $output.Contains("Destination: $real") `
                "A shortcut into a backup must not choose the destination:`n$output"
        }
    } finally {
        Remove-Item -LiteralPath $suite -Recurse -Force -ErrorAction SilentlyContinue
    }
}
