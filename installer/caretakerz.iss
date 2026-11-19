#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#define Win64 "{app}\Voyage\Binaries\Win64"
#define ModDir "{app}\Voyage\Binaries\Win64\ue4ss\Mods\CoopSync"

[Setup]
AppId={{ABB442BC-45A3-4EFF-8AAA-4763F9B18A9D}
AppName=Caretakers Multiplayer
AppVersion={#AppVersion}
AppPublisher=Bemno
AppContact=bemno@tutamail.com
AppPublisherURL=https://github.com/Bemno/Caretakers-Multiplayer
UninstallDisplayName=Caretakers Multiplayer, co-op mod for The Last Caretaker
DefaultDirName={code:GameDir}
AppendDefaultDirName=no
DirExistsWarning=no
UsePreviousAppDir=yes
DisableProgramGroupPage=yes
PrivilegesRequired=admin
OutputDir=..\dist
OutputBaseFilename=Caretakers-Multiplayer-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes

[Messages]
SelectDirLabel3=Select the folder where The Last Caretaker is installed (it contains Voyage.exe).

[InstallDelete]
; Modules that were renamed or removed must not linger from an older version.
Type: files; Name: "{#ModDir}\Scripts\*.lua"
Type: files; Name: "{#ModDir}\coopnet.exe"
Type: filesandordirs; Name: "{#ModDir}\coopnet"

[Files]
; UE4SS core is always replaced: the mod is only tested with this build.
Source: "ue4ss\dwmapi.dll"; DestDir: "{#Win64}"; Flags: ignoreversion uninsneveruninstall
Source: "ue4ss\ue4ss\UE4SS.dll"; DestDir: "{#Win64}\ue4ss"; Flags: ignoreversion uninsneveruninstall
Source: "ue4ss\ue4ss\*"; Excludes: "UE4SS.dll"; DestDir: "{#Win64}\ue4ss"; Flags: recursesubdirs onlyifdoesntexist uninsneveruninstall
Source: "..\mod\CoopSync\Scripts\*.lua"; DestDir: "{#ModDir}\Scripts"; Flags: ignoreversion
Source: "..\mod\CoopSync\coopnet\*"; DestDir: "{#ModDir}\coopnet"; Flags: ignoreversion recursesubdirs
Source: "enabled.txt"; DestDir: "{#ModDir}"; Flags: ignoreversion

[INI]
; coopnet checks GitHub for a newer release only when this file exists (not in the Nexus zip).
Filename: "{#ModDir}\update.ini"; Section: "update"; Key: "version"; String: "{#AppVersion}"; Flags: uninsdeletesection

[Run]
; The in-game updater runs this installer silently after the game has closed.
Filename: "steam://rungameid/1783560"; Flags: shellexec nowait runasoriginaluser; Check: RestartGame

[Code]
function RestartGame: Boolean;
begin
  Result := ExpandConstant('{param:RESTARTGAME|0}') = '1';
end;

// coopnet starts this installer and then exits; give it time to let go of its files.
function InitializeSetup: Boolean;
begin
  if RestartGame then Sleep(3000);
  Result := True;
end;

const
  GameExe = 'Voyage\Binaries\Win64\VoyageSteam-Win64-Shipping.exe';

function HasGame(Dir: String): Boolean;
begin
  Result := (Dir <> '') and FileExists(AddBackslash(Dir) + GameExe);
end;

// Steam's library list (steamapps\libraryfolders.vdf) names every library
// folder; the game is in whichever one has it. The uninstall key in the
// registry can point at an old place (seen: C:\Steam while the game was on H:).
function FromLibraries(SteamDir: String): String;
var
  Lines: TArrayOfString;
  I, P: Integer;
  Line, Lib: String;
begin
  Result := '';
  if not LoadStringsFromFile(AddBackslash(SteamDir) + 'steamapps\libraryfolders.vdf', Lines) then Exit;
  for I := 0 to GetArrayLength(Lines) - 1 do
  begin
    Line := Trim(Lines[I]);
    if Pos('"path"', Lowercase(Line)) = 1 then
    begin
      Lib := Trim(Copy(Line, 7, Length(Line)));
      P := Pos('"', Lib);
      if P > 0 then
      begin
        Lib := Copy(Lib, P + 1, Length(Lib));
        P := Pos('"', Lib);
        if P > 0 then Lib := Copy(Lib, 1, P - 1);
        StringChangeEx(Lib, '\\', '\', True);
        Lib := AddBackslash(Lib) + 'steamapps\common\Voyage';
        if HasGame(Lib) then
        begin
          Result := Lib;
          Exit;
        end;
      end;
    end;
  end;
end;

function GameDir(Param: String): String;
var
  Steam: String;
begin
  Result := '';
  if RegQueryStringValue(HKCU, 'Software\Valve\Steam', 'SteamPath', Steam) then
  begin
    StringChangeEx(Steam, '/', '\', True);
    Result := FromLibraries(Steam);
  end;
  if (Result = '') and RegQueryStringValue(HKLM, 'SOFTWARE\WOW6432Node\Valve\Steam', 'InstallPath', Steam) then
    Result := FromLibraries(Steam);
  if (Result = '') and RegQueryStringValue(HKLM, 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 1783560', 'InstallLocation', Steam) and HasGame(Steam) then
    Result := Steam;
  if Result = '' then
    Result := ExpandConstant('{commonpf32}\Steam\steamapps\common\Voyage');
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if (CurPageID = wpSelectDir) and not HasGame(WizardDirValue) then
  begin
    MsgBox('The Last Caretaker was not found in this folder. Pick the folder that contains Voyage.exe.', mbError, MB_OK);
    Result := False;
  end;
end;
