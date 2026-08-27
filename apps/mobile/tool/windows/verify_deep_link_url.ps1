# Builds and runs the standalone deep link URL check.
#
# The runner's native code cannot be reached from `flutter test`, and the app
# window on the CI VM does not render into a screenshot, so this is how the
# URL rules get exercised for real instead of by inspection.
#
# Usage from apps/mobile:  powershell -File tool/windows/verify_deep_link_url.ps1
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$out = Join-Path $env:TEMP "deep_link_url_test"
New-Item -ItemType Directory -Force -Path $out | Out-Null

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw "No Visual Studio C++ toolchain found." }
$vcvars = Join-Path $vs "VC\Auxiliary\Build\vcvars64.bat"

$sources = @(
  (Join-Path $root "windows\runner\deep_link_url.cpp"),
  (Join-Path $root "tool\windows\deep_link_url_test.cpp")
)
$includeDir = Join-Path $root "windows\runner"
$exe = Join-Path $out "deep_link_url_test.exe"
$compile = "cl /nologo /EHsc /std:c++17 /DNOMINMAX /I`"$includeDir`" /Fo:$out\ /Fe:$exe " +
           ($sources -join " ") + " shlwapi.lib"
cmd /c "`"$vcvars`" >nul && $compile"
if ($LASTEXITCODE -ne 0) { throw "compile failed" }

& $exe
exit $LASTEXITCODE
