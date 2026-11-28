#define MyAppName "Just MakeOver Salon System"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "Just MakeOver Beauty Salon & Spa"
#define MyAppExeName "JustMakeOverSalonApp.exe"
#define ReleaseDir "..\JustMakeOverSalonApp\bin\Release"
#define PrereqsDir "Prereqs"

[Setup]
AppId={{8F642B61-2351-4A1E-98F1-5A9A92C8B740}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\Just MakeOver Salon System
DefaultGroupName={#MyAppName}
AllowNoIcons=yes
OutputDir=Output
OutputBaseFilename=JustMakeOverSalonSetup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64compatible
SetupIconFile=..\JustMakeOverSalonApp\logo.ico
UninstallDisplayIcon={app}\{#MyAppExeName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
; Core application binaries, WebView2 loader, Frontend assets, and Database\FullSetup.sql
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Excludes: "*.pdb,*.xml"; Flags: ignoreversion recursesubdirs createallsubdirs

; Optional offline prerequisites (place under Installer\Prereqs\ before compiling)
#if FileExists(PrereqsDir + "\SqlLocalDB.msi")
Source: "{#PrereqsDir}\SqlLocalDB.msi"; DestDir: "{tmp}"; Flags: deleteafterinstall
#endif
#if FileExists(PrereqsDir + "\MicrosoftEdgeWebview2Setup.exe")
Source: "{#PrereqsDir}\MicrosoftEdgeWebview2Setup.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall
#endif

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
; Install SQL Server Express LocalDB silently if neither SQLEXPRESS nor LocalDB is present
#if FileExists(PrereqsDir + "\SqlLocalDB.msi")
Filename: "msiexec.exe"; Parameters: "/i ""{tmp}\SqlLocalDB.msi"" /qn /norestart IACCEPTSQLLOCALDBLICENSETERMS=YES"; StatusMsg: "Installing SQL Server LocalDB engine..."; Check: NeedsLocalDbInstall; Flags: waituntilterminated
#endif

; Install WebView2 Runtime silently if missing
#if FileExists(PrereqsDir + "\MicrosoftEdgeWebview2Setup.exe")
Filename: "{tmp}\MicrosoftEdgeWebview2Setup.exe"; Parameters: "/silent /install"; StatusMsg: "Installing Microsoft Edge WebView2 Runtime..."; Check: NeedsWebView2Install; Flags: waituntilterminated
#endif

; Initialize database schema & starter seed silently during installation, or let first launch run it cleanly
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[Code]
function NeedsLocalDbInstall(): Boolean;
var
  Versions: TArrayOfString;
begin
  if RegGetSubkeyNames(HKLM, 'SOFTWARE\Microsoft\Microsoft SQL Server Local DB\Installed Versions', Versions) then
    Result := (GetArrayLength(Versions) = 0)
  else
    Result := True;
end;

function NeedsWebView2Install(): Boolean;
var
  Version: string;
begin
  Result := not RegQueryStringValue(HKLM, 'SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}', 'pv', Version)
        and not RegQueryStringValue(HKLM, 'SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}', 'pv', Version);
end;
