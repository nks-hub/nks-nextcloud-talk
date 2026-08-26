# Windows installer

The installer packages an existing Flutter Windows release bundle as a per-user
Inno Setup installation. It installs NKS Talk under
`%LOCALAPPDATA%\Programs\NKS Talk`, creates a Start Menu shortcut, and leaves
application support data intact during upgrades and uninstall.

## Build

Build the Flutter bundle first, then run the packaging script from the repository
root:

```powershell
flutter build windows --release
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  .\apps\mobile\windows\installer\build_installer.ps1
```

The script reads the version from `apps\mobile\pubspec.yaml`, validates the
bundle, writes a SHA-256 manifest, locates Inno Setup 6, and creates the setup
executable in `apps\mobile\build\windows\installer`. Use `-BundlePath`,
`-OutputPath`, `-AppVersion`, or `-InnoCompilerPath` when a non-default build
layout is required.

## Smoke test

Run the smoke test only in a dedicated interactive Windows test account. It
installs and launches the application, captures runtime evidence, and uninstalls
it again. It refuses to replace an existing installation unless the explicit
reset switch is supplied.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  .\apps\mobile\windows\installer\smoke_installer.ps1 `
  -InstallerPath .\apps\mobile\build\windows\installer\NKS-Talk-0.1.0-1-windows-x64-setup.exe
```

To verify the complete version lifecycle, provide an older installer as well:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  .\apps\mobile\windows\installer\smoke_installer.ps1 `
  -InstallerPath .\current-setup.exe `
  -PreviousInstallerPath .\previous-setup.exe `
  -EvidencePath .\installer-evidence `
  -ResetExistingInstallation
```

That lifecycle performs a clean installation of the older version, upgrades it
while the application is running, verifies that a downgrade is rejected without
changing installed bytes, launches the current version, and uninstalls it. The
test checks installed hashes, the shortcut, process and window state, application
support-data preservation, and silent setup behavior. `-InstallerLifecycleOnly`
keeps the install, upgrade, downgrade, and uninstall checks but skips application
launch and screenshot capture.

`-ResetExistingInstallation` can stop NKS Talk and uninstall the per-user copy at
the fixed installation path. Do not use it on a workstation whose installation
or profile data is not dedicated to this test.
