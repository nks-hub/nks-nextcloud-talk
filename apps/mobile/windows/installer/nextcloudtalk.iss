#ifndef BundleDir
  #error BundleDir must point to the Flutter Windows release bundle.
#endif
#ifndef BundleManifest
  #error BundleManifest must point to the generated bundle manifest.
#endif
#ifndef RepoRoot
  #error RepoRoot must point to the repository root.
#endif
#ifndef OutputDir
  #error OutputDir must point to the installer output directory.
#endif
#ifndef AppVersion
  #error AppVersion must contain the pubspec version.
#endif
#ifndef NumericVersion
  #error NumericVersion must contain a four-part Windows version.
#endif
#ifndef SafeVersion
  #error SafeVersion must be safe for use in a file name.
#endif

#define AppGuid "E5ED1C79-5591-49F7-AD4C-607549A85F25"

[Setup]
AppId={{{#AppGuid}}
AppName=NKS Talk
AppVersion={#AppVersion}
AppVerName=NKS Talk {#AppVersion}
AppPublisher=NKS Hub
DefaultDirName={localappdata}\Programs\NKS Talk
DefaultGroupName=NKS Talk
DisableProgramGroupPage=yes
AllowNoIcons=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=commandline
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename=NKS-Talk-{#SafeVersion}-windows-x64-setup
SetupIconFile={#RepoRoot}\apps\mobile\windows\runner\resources\app_icon.ico
LicenseFile={#RepoRoot}\LICENSE
UninstallDisplayIcon={app}\nextcloudtalk.exe
UninstallDisplayName=NKS Talk
VersionInfoVersion={#NumericVersion}
VersionInfoCompany=NKS Hub
VersionInfoDescription=NKS Talk installer
VersionInfoProductName=NKS Talk
VersionInfoProductVersion={#NumericVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=force
CloseApplicationsFilter=nextcloudtalk.exe
RestartApplications=no
ChangesAssociations=no
ChangesEnvironment=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "czech"; MessagesFile: "compiler:Languages\Czech.isl"

[CustomMessages]
english.NewerVersionInstalled=A newer version of NKS Talk is already installed.
czech.NewerVersionInstalled=Je již nainstalována novější verze NKS Talk.

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#BundleManifest}"; DestDir: "{app}"; DestName: "bundle-manifest.json"; Flags: ignoreversion
Source: "{#RepoRoot}\LICENSE"; DestDir: "{app}\licenses"; DestName: "GPL-3.0-or-later.txt"; Flags: ignoreversion

[Icons]
Name: "{group}\NKS Talk"; Filename: "{app}\nextcloudtalk.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\NKS Talk"; Filename: "{app}\nextcloudtalk.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\nextcloudtalk.exe"; Description: "{cm:LaunchProgram,NKS Talk}"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent

[Registry]
Root: HKCU; Subkey: "Software\NKS Hub\NKS Talk"; ValueType: string; ValueName: "InstallLocation"; ValueData: "{app}"; Flags: uninsdeletevalue uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\NKS Hub\NKS Talk"; ValueType: string; ValueName: "InstallerVersion"; ValueData: "{#NumericVersion}"; Flags: uninsdeletevalue uninsdeletekeyifempty

[Code]
var
  DowngradeBlocked: Boolean;

function NextVersionPart(var Version: String): Integer;
var
  Separator: Integer;
  Part: String;
begin
  Separator := Pos('.', Version);
  if Separator = 0 then
  begin
    Part := Version;
    Version := '';
  end
  else
  begin
    Part := Copy(Version, 1, Separator - 1);
    Delete(Version, 1, Separator);
  end;
  Result := StrToIntDef(Part, 0);
end;

function CompareVersions(LeftVersion, RightVersion: String): Integer;
var
  Index: Integer;
  LeftPart: Integer;
  RightPart: Integer;
begin
  Result := 0;
  for Index := 1 to 4 do
  begin
    LeftPart := NextVersionPart(LeftVersion);
    RightPart := NextVersionPart(RightVersion);
    if LeftPart < RightPart then
    begin
      Result := -1;
      Exit;
    end;
    if LeftPart > RightPart then
    begin
      Result := 1;
      Exit;
    end;
  end;
end;

function InitializeSetup(): Boolean;
var
  InstalledVersion: String;
begin
  DowngradeBlocked := False;
  Result := True;
  if RegQueryStringValue(
    HKCU,
    'Software\NKS Hub\NKS Talk',
    'InstallerVersion',
    InstalledVersion
  ) and (CompareVersions('{#NumericVersion}', InstalledVersion) < 0) then
    DowngradeBlocked := True;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  NeedsRestart := False;
  Result := '';
  if DowngradeBlocked then
    Result := ExpandConstant('{cm:NewerVersionInstalled}');
end;
