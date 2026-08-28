; ==============================================================================
; 「学生时代模组编辑器」Windows 安装包脚本 (Inno Setup 6)
; ==============================================================================

#ifndef AppVersion
  #define AppVersion "1.4.0"
#endif

#ifndef AppName
  #define AppName "学生时代模组编辑器"
#endif

#ifndef AppPublisher
  #define AppPublisher "PakyiGame"
#endif

#ifndef AppId
  #define AppId "{{B42E5CA7-9A1D-4A47-BE59-55694FA391C0}}"
#endif

#ifndef SourceDir
  #define SourceDir "..\..\dist\学生时代模组编辑器-v" + AppVersion
#endif

#ifndef BackendDist
  #define BackendDist "..\..\build\release\backend_dist"
#endif

#ifndef OfficialPackDir
  #define OfficialPackDir "..\..\build\release\installer_official_pack"
#endif

#ifndef OutputDir
  #define OutputDir "..\..\dist"
#endif

[Setup]
AppId={#AppId}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} v{#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\StudentAgeEditor
DisableProgramGroupPage=yes
PrivilegesRequiredOverridesAllowed=dialog
OutputDir={#OutputDir}
OutputBaseFilename={#AppName}-setup-v{#AppVersion}
SetupIconFile=..\..\frontend\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppName}.exe
UninstallDisplayName={#AppName} v{#AppVersion}
ChangesEnvironment=yes
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "chinesesimplified"; MessagesFile: "Languages\ChineseSimplified.isl"

[Types]
Name: "full"; Description: "完整安装（推荐）"
Name: "custom"; Description: "自定义安装"; Flags: iscustom

[Components]
Name: "core"; Description: "核心运行时与文档（必选）"; Types: full custom; Flags: fixed
Name: "gui"; Description: "图形用户界面 (GUI) - 桌面主程序"; Types: full custom
Name: "tui"; Description: "终端用户界面 (TUI) - 终端字符交互界面"; Types: full custom
Name: "cli"; Description: "命令行接口 (CLI) - 自动化与脚本工具"; Types: full custom
Name: "officialpack"; Description: "官方资源扩展包（适用于未安装游戏的创作者）"; Types: full custom

[Files]
; 核心组件 (core)
Source: "{#BackendDist}\backend.exe"; DestDir: "{app}"; Flags: ignoreversion; Components: core
; 共享运行时库（PyInstaller onedir 的 _internal，backend.exe 与 editor_cmd.exe 共用）
Source: "{#BackendDist}\_internal\*"; DestDir: "{app}\_internal"; Flags: ignoreversion recursesubdirs createallsubdirs; Components: core
Source: "{#SourceDir}\使用说明.txt"; DestDir: "{app}"; Flags: ignoreversion isreadme; Components: core; DestName: "使用说明.txt"

; GUI 组件 (Flutter 前端)
Source: "{#SourceDir}\{#AppName}.exe"; DestDir: "{app}"; Flags: ignoreversion; Components: gui
Source: "{#SourceDir}\*.dll"; DestDir: "{app}"; Flags: ignoreversion; Components: gui
Source: "{#SourceDir}\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs; Components: gui

; TUI 与 CLI 共享终端可执行文件 (editor_cmd.exe)
Source: "{#BackendDist}\editor_cmd.exe"; DestDir: "{app}"; Flags: ignoreversion; Components: tui cli

; 官方资源扩展包
Source: "{#OfficialPackDir}\*"; DestDir: "{app}\_cache\resource_packs\official-bundled"; Flags: ignoreversion recursesubdirs createallsubdirs; Components: officialpack

[Tasks]
Name: "startmenu"; Description: "创建开始菜单快捷方式"; GroupDescription: "快捷方式:"; Flags: checkedonce
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "快捷方式:"; Components: gui; Flags: checkedonce
Name: "path_gui"; Description: "添加 editor-gui 命令到系统/用户 PATH 环境变量"; GroupDescription: "命令行环境 (PATH):"; Components: gui; Flags: unchecked
Name: "path_tui"; Description: "添加 editor-tui 命令到系统/用户 PATH 环境变量"; GroupDescription: "命令行环境 (PATH):"; Components: tui; Flags: unchecked
Name: "path_cli"; Description: "添加 editor-cli 命令到系统/用户 PATH 环境变量"; GroupDescription: "命令行环境 (PATH):"; Components: cli; Flags: checkedonce

[Icons]
; 开始菜单快捷方式
Name: "{autoprograms}\{#AppName}\{#AppName}"; Filename: "{app}\{#AppName}.exe"; IconFilename: "{app}\{#AppName}.exe"; Tasks: startmenu; Components: gui
Name: "{autoprograms}\{#AppName}\{#AppName} (TUI 终端界面)"; Filename: "{app}\editor_cmd.exe"; Parameters: "tui"; IconFilename: "{app}\editor_cmd.exe"; Tasks: startmenu; Components: tui
Name: "{autoprograms}\{#AppName}\{#AppName} (CLI 命令行)"; Filename: "{app}\editor_cmd.exe"; Parameters: "cli"; IconFilename: "{app}\editor_cmd.exe"; Tasks: startmenu; Components: cli
Name: "{autoprograms}\{#AppName}\使用说明"; Filename: "{app}\使用说明.txt"; Tasks: startmenu; Components: core

; 桌面快捷方式
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppName}.exe"; Tasks: desktopicon; Components: gui

[Run]
Filename: "{app}\{#AppName}.exe"; Description: "启动 {#AppName}"; Flags: nowait postinstall skipifsilent; Components: gui

[UninstallDelete]
Type: files; Name: "{app}\bin\*.cmd"
Type: dirifempty; Name: "{app}\bin"
Type: filesandordirs; Name: "{app}\_cache"
Type: filesandordirs; Name: "{app}\logs"
Type: files; Name: "{app}\editor_env.json"
Type: files; Name: "{app}\.editor_ai.json"
Type: filesandordirs; Name: "{app}\_internal"

[Code]
var
  ModDirPage: TInputDirWizardPage;

const
  WM_SETTINGCHANGE = $001A;
  SMTO_ABORTIFHUNG = $0002;

function SendMessageTimeout(hWnd: HWND; Msg: UINT; wParam: LongInt; lParam: String; fuFlags: UINT; uTimeout: UINT; var lpdwResult: DWORD): LongInt;
  external 'SendMessageTimeoutW@user32.dll stdcall';

procedure BroadcastEnvChange();
var
  Res: DWORD;
begin
  SendMessageTimeout(HWND_BROADCAST, WM_SETTINGCHANGE, 0, 'Environment', SMTO_ABORTIFHUNG, 5000, Res);
end;

function GetPathRegistryRoot(): Integer;
begin
  if IsAdminInstallMode() then
    Result := HKLM
  else
    Result := HKCU;
end;

function GetPathRegistrySubKey(): String;
begin
  if IsAdminInstallMode() then
    Result := 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
  else
    Result := 'Environment';
end;

function FindSteamWorkshopDir(): String;
var
  InstallLoc: String;
  SteamPath: String;
  VdfPath: String;
  Lines: TArrayOfString;
  I: Integer;
  Line: String;
  LibPath: String;
  P1, P2: Integer;
  TestWorkshop: String;
begin
  Result := '';
  // 1. 尝试从 Steam 卸载注册表读游戏安装路径 (AppID 1991040)
  if RegQueryStringValue(HKLM, 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 1991040', 'InstallLocation', InstallLoc) or
     RegQueryStringValue(HKCU, 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 1991040', 'InstallLocation', InstallLoc) or
     RegQueryStringValue(HKLM64, 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 1991040', 'InstallLocation', InstallLoc) or
     RegQueryStringValue(HKLM32, 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 1991040', 'InstallLocation', InstallLoc) then
  begin
    if (InstallLoc <> '') and DirExists(InstallLoc) then
    begin
      // InstallLocation 通常为 <库>\steamapps\common\StudentAge
      TestWorkshop := ExtractFilePath(ExtractFilePath(InstallLoc)) + 'workshop\content\1991040';
      if DirExists(TestWorkshop) or DirExists(ExtractFilePath(TestWorkshop)) then
      begin
        Result := TestWorkshop;
        Exit;
      end;
    end;
  end;

  // 2. 尝试从 SteamPath 读取 libraryfolders.vdf
  SteamPath := '';
  if not RegQueryStringValue(HKCU, 'Software\Valve\Steam', 'SteamPath', SteamPath) then
  begin
    if not RegQueryStringValue(HKLM, 'SOFTWARE\Valve\Steam', 'InstallPath', SteamPath) then
    begin
      if not RegQueryStringValue(HKLM64, 'SOFTWARE\Valve\Steam', 'InstallPath', SteamPath) then
      begin
        SteamPath := ExpandConstant('{commonpf32}\Steam');
      end;
    end;
  end;

  if (SteamPath <> '') and DirExists(SteamPath) then
  begin
    VdfPath := SteamPath + '\steamapps\libraryfolders.vdf';
    if not FileExists(VdfPath) then
      VdfPath := SteamPath + '\config\libraryfolders.vdf';

    if FileExists(VdfPath) and LoadStringsFromFile(VdfPath, Lines) then
    begin
      for I := 0 to GetArrayLength(Lines) - 1 do
      begin
        Line := Trim(Lines[I]);
        if Pos('"path"', Line) > 0 then
        begin
          P1 := Pos('"', Line);
          if P1 > 0 then
          begin
            Line := Copy(Line, P1 + 1, Length(Line));
            P1 := Pos('"', Line);
            if P1 > 0 then
            begin
              Line := Copy(Line, P1 + 1, Length(Line));
              P1 := Pos('"', Line);
              if P1 > 0 then
              begin
                Line := Copy(Line, P1 + 1, Length(Line));
                P2 := Pos('"', Line);
                if P2 > 0 then
                begin
                  LibPath := Copy(Line, 1, P2 - 1);
                  StringChangeEx(LibPath, '\\', '\', True);
                  if DirExists(LibPath) then
                  begin
                    TestWorkshop := LibPath + '\steamapps\workshop\content\1991040';
                    if DirExists(TestWorkshop) or DirExists(LibPath + '\steamapps\common\StudentAge') then
                    begin
                      Result := TestWorkshop;
                      Exit;
                    end;
                  end;
                end;
              end;
            end;
          end;
        end;
      end;
    end;

    TestWorkshop := SteamPath + '\steamapps\workshop\content\1991040';
    Result := TestWorkshop;
    Exit;
  end;
end;

function GetDefaultWorkspaceModsDir(): String;
var
  UserProfile: String;
begin
  UserProfile := GetEnv('USERPROFILE');
  if UserProfile = '' then
    UserProfile := ExpandConstant('{userdocs}\..');
  Result := UserProfile + '\AppData\LocalLow\PakyiGame\StudentAge\Mods';
end;

function EscapeJsonString(const S: String): String;
var
  I: Integer;
  C: Char;
  Res: String;
begin
  Res := '';
  for I := 1 to Length(S) do
  begin
    C := S[I];
    if C = '\' then
      Res := Res + '\\'
    else if C = '"' then
      Res := Res + '\"'
    else
      Res := Res + C;
  end;
  Result := Res;
end;

procedure WriteEditorEnvJson(const AppPath, WorkspaceRoot, WorkshopRoot: String);
var
  EnvFile: String;
  JsonContent: String;
begin
  EnvFile := AppPath + '\editor_env.json';
  if not FileExists(EnvFile) then
  begin
    JsonContent := '{' + #13#10 +
      '  "workspace_root": "' + EscapeJsonString(WorkspaceRoot) + '",' + #13#10 +
      '  "workshop_root": "' + EscapeJsonString(WorkshopRoot) + '"' + #13#10 +
      '}';
    SaveStringToFile(EnvFile, JsonContent, False);
  end;
end;

procedure EnsurePacksJson(const AppPath: String);
var
  PacksDir: String;
  PacksFile: String;
  JsonContent: String;
begin
  PacksDir := AppPath + '\_cache\resource_packs';
  PacksFile := PacksDir + '\packs.json';
  if not FileExists(PacksFile) then
  begin
    ForceDirectories(PacksDir);
    JsonContent := '{"active":"official-bundled","packs":[]}';
    SaveStringToFile(PacksFile, JsonContent, False);
  end;
end;

procedure CreateCommandWrappers(const BinDir: String);
var
  GuiCmd, TuiCmd, CliCmd: String;
begin
  ForceDirectories(BinDir);
  GuiCmd := '@echo off' + #13#10 + 'start "" "%~dp0..\{#AppName}.exe" %*' + #13#10;
  TuiCmd := '@echo off' + #13#10 + '"%~dp0..\editor_cmd.exe" tui %*' + #13#10;
  CliCmd := '@echo off' + #13#10 + '"%~dp0..\editor_cmd.exe" cli %*' + #13#10;

  SaveStringToFile(BinDir + '\editor-gui.cmd', GuiCmd, False);
  SaveStringToFile(BinDir + '\editor-tui.cmd', TuiCmd, False);
  SaveStringToFile(BinDir + '\editor-cli.cmd', CliCmd, False);
end;

procedure AddPath(const Dir: String);
var
  RootKey: Integer;
  SubKey: String;
  OldPath: String;
  NewPath: String;
  Paths: String;
begin
  RootKey := GetPathRegistryRoot();
  SubKey := GetPathRegistrySubKey();
  if not RegQueryStringValue(RootKey, SubKey, 'Path', OldPath) then
    OldPath := '';

  RegWriteStringValue(RootKey, SubKey, 'StudentAgeEditor_BackupPath', OldPath);

  Paths := ';' + OldPath + ';';
  if Pos(';' + Dir + ';', Paths) = 0 then
  begin
    if (OldPath <> '') and (OldPath[Length(OldPath)] <> ';') then
      NewPath := OldPath + ';' + Dir
    else
      NewPath := OldPath + Dir;

    if RegWriteStringValue(RootKey, SubKey, 'Path', NewPath) then
    begin
      BroadcastEnvChange();
    end;
  end;
end;

procedure RemovePath(const Dir: String);
var
  RootKey: Integer;
  SubKey: String;
  CurPath: String;
  P: Integer;
  NewPath: String;
begin
  RootKey := GetPathRegistryRoot();
  SubKey := GetPathRegistrySubKey();

  if RegQueryStringValue(RootKey, SubKey, 'Path', CurPath) then
  begin
    P := Pos(';' + Dir + ';', ';' + CurPath + ';');
    if P > 0 then
    begin
      NewPath := CurPath;
      StringChangeEx(NewPath, ';' + Dir, '', True);
      StringChangeEx(NewPath, Dir + ';', '', True);
      StringChangeEx(NewPath, Dir, '', True);
      RegWriteStringValue(RootKey, SubKey, 'Path', NewPath);
      BroadcastEnvChange();
    end;
  end;
  RegDeleteValue(RootKey, SubKey, 'StudentAgeEditor_BackupPath');
end;

procedure InitializeWizard();
var
  DefWorkshop: String;
  DefWorkspace: String;
begin
  DefWorkspace := GetDefaultWorkspaceModsDir();
  DefWorkshop := FindSteamWorkshopDir();

  ModDirPage := CreateInputDirPage(
    wpSelectComponents,
    '配置模组工作目录',
    '请确认本地模组工作区与 Steam 创意工坊目录',
    '安装程序已自动探测游戏相关路径。如路径有变，可在此手动修改：' + #13#10 +
    '（两处目录若不存在，安装程序会自动创建对应文件夹）',
    False,
    '');

  ModDirPage.Add('本地模组工作区（用户自制与编辑 Mods 存放位置）:');
  ModDirPage.Add('Steam 创意工坊目录（已订阅模组下载位置）:');

  ModDirPage.Values[0] := DefWorkspace;
  ModDirPage.Values[1] := DefWorkshop;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if CurPageID = wpSelectComponents then
  begin
    if not (WizardIsComponentSelected('gui') or WizardIsComponentSelected('tui') or WizardIsComponentSelected('cli')) then
    begin
      MsgBox('请至少选择一种界面组件（图形界面 GUI、终端界面 TUI 或 命令行接口 CLI）。', mbError, MB_OK);
      Result := False;
      Exit;
    end;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  AppDir: String;
  WorkspaceDir: String;
  WorkshopDir: String;
  BinDir: String;
  NeedPath: Boolean;
begin
  if CurStep = ssPostInstall then
  begin
    AppDir := ExpandConstant('{app}');
    if Assigned(ModDirPage) then
    begin
      WorkspaceDir := ModDirPage.Values[0];
      WorkshopDir := ModDirPage.Values[1];
    end
    else
    begin
      WorkspaceDir := GetDefaultWorkspaceModsDir();
      WorkshopDir := FindSteamWorkshopDir();
    end;

    if WorkspaceDir <> '' then
      ForceDirectories(WorkspaceDir);
    if WorkshopDir <> '' then
      ForceDirectories(WorkshopDir);

    // 1. 写入 editor_env.json（升级不覆盖）
    WriteEditorEnvJson(AppDir, WorkspaceDir, WorkshopDir);

    // 2. 若安装了 officialpack，写入 packs.json
    if WizardIsComponentSelected('officialpack') then
    begin
      EnsurePacksJson(AppDir);
    end;

    // 3. 处理 PATH 命令
    NeedPath := WizardIsTaskSelected('path_gui') or
                WizardIsTaskSelected('path_tui') or
                WizardIsTaskSelected('path_cli');
    if NeedPath then
    begin
      BinDir := AppDir + '\bin';
      CreateCommandWrappers(BinDir);
      AddPath(BinDir);
    end;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  AppDir: String;
  BinDir: String;
begin
  if CurUninstallStep = usUninstall then
  begin
    AppDir := ExpandConstant('{app}');
    BinDir := AppDir + '\bin';
    RemovePath(BinDir);
    DeleteFile(BinDir + '\editor-gui.cmd');
    DeleteFile(BinDir + '\editor-tui.cmd');
    DeleteFile(BinDir + '\editor-cli.cmd');
    RemoveDir(BinDir);
  end;
end;
