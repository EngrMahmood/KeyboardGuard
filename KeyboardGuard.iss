#define MyAppName "KeyboardGuard"
#define MyAppVersion "1.0"
#define MyAppExeName "KeyboardGuard.exe"

[Setup]
AppId={{7B3F1E7E-1B0A-4C7A-9E36-3B0F4C6E9A11}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2
SolidCompression=yes
OutputDir=Output
OutputBaseFilename=KeyboardGuard-Setup
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional icons:"

[Files]
Source: "KeyboardGuard.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "install-interception.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName} now"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}\Lib"
Type: files; Name: "{app}\nssm.exe"
Type: files; Name: "{app}\install-interception.exe"

[Code]
var
  DriverWasInstalled: Boolean;

function NeedRestart(): Boolean;
begin
  { Interception is a kernel driver - Windows only loads it after a reboot,
    so the finish page shows the standard restart prompt. }
  Result := DriverWasInstalled;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
begin
  if CurStep = ssInstall then
  begin
    { Stop the background service and close any running copy of the app
      first, otherwise Windows can't overwrite the locked exe file. }
    Exec(ExpandConstant('{sys}\sc.exe'), 'stop KeyboardGuard', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    Sleep(1000);
    Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM KeyboardGuard.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    Sleep(500);
  end;
  if CurStep = ssPostInstall then
  begin
    Exec(ExpandConstant('{app}\install-interception.exe'), '/install', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    DriverWasInstalled := True;
    { If a service was already registered from a previous install, restart
      it now so it picks up the newly-installed exe. }
    Exec(ExpandConstant('{sys}\sc.exe'), 'start KeyboardGuard', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  ResultCode: Integer;
begin
  if CurUninstallStep = usUninstall then
  begin
    { Stop/remove the background service and scheduled task if they were set up. }
    if FileExists(ExpandConstant('{app}\nssm.exe')) then
    begin
      Exec(ExpandConstant('{app}\nssm.exe'), 'stop KeyboardGuard', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
      Exec(ExpandConstant('{app}\nssm.exe'), 'remove KeyboardGuard confirm', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    end;
    Exec(ExpandConstant('{cmd}'), '/c schtasks /delete /tn "KeyboardGuard" /f', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    { Also remove the Interception driver installed during setup. }
    if FileExists(ExpandConstant('{app}\install-interception.exe')) then
      Exec(ExpandConstant('{app}\install-interception.exe'), '/uninstall', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  end;
end;
