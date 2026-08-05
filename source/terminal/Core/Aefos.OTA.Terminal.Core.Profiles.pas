unit Aefos.OTA.Terminal.Core.Profiles;

interface

uses
  System.Classes, System.SysUtils, System.IniFiles, System.IOUtils, System.Generics.Collections;

type
  /// <summary>AI CLI family a shell profile is wired for. <c>aitNone</c> is the
  /// default — a plain shell with no MCP auto-wiring (BR2).</summary>
  TAIClientType = (aitNone, aitClaude, aitCodex, aitGemini);

  TShellProfile = class
  private
    FName: string;
    FExecutable: string;
    FArguments: string;
    FStartDir: string;
    FAIClientType: TAIClientType;
  public
    constructor Create(const AName, AExecutable, AArguments, AStartDir: string;
      const AClientType: TAIClientType = aitNone);
    property Name: string read FName write FName;
    property Executable: string read FExecutable write FExecutable;
    property Arguments: string read FArguments write FArguments;
    property StartDir: string read FStartDir write FStartDir;
    /// <summary>AI CLI family this profile launches; drives MCP auto-wiring at
    /// session open. Persisted in the INI key <c>AIClientType</c>; a missing or
    /// out-of-range key reads back as <c>aitNone</c>.</summary>
    property AIClientType: TAIClientType read FAIClientType write FAIClientType;
  end;

  TProfileManager = class
  private
    FProfiles: TObjectList<TShellProfile>;
    FActiveProfileIndex: Integer;
    FAutoSync: Boolean;
    function _GetConfigPath: string;
    procedure _DiscoverDefaults;
    // Adds auto-detectable shells (claude/wsl/git-bash) that are installed but not
    // yet in the loaded list, so existing users pick up newly-supported shells
    // without resetting their config. Saves when it changed anything.
    procedure _MergeDiscoveredProfiles;
  public
    constructor Create;
    destructor Destroy; override;

    procedure LoadFromIni;
    procedure SaveToIni;

    function FindProfileByName(const AName: string): TShellProfile;

    property Profiles: TObjectList<TShellProfile> read FProfiles;
    property ActiveProfileIndex: Integer read FActiveProfileIndex write FActiveProfileIndex;
    property AutoSync: Boolean read FAutoSync write FAutoSync;
  end;

implementation

uses
  Winapi.Windows, System.Win.Registry;

const
  AI_CLIENT_TYPE_KEY = 'AIClientType';
  CLAUDE_EXE_NAME     = 'claude';
  // Prompt style 0 (default): full powerline — calendar+date | clock+time | folder+cwd.
  POWERSHELL_POWERLINE_ARGS = '-NoExit -Command "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; function prompt { $esc = [char]27; $c1 = [char]0xF073; $c2 = [char]0xF017; $c3 = [char]0xF07C; $sep = [char]0xE0B0; $date = Get-Date -Format ''MM-dd''; $time = Get-Date -Format ''HH:mm''; $cwd = $pwd.ProviderPath; $b1 = $esc + ''[48;2;0;150;200m'' + $esc + ''[38;2;0;0;0m '' + $c1 + '' '' + $date + '' ''; $s1 = $esc + ''[38;2;0;150;200m'' + $esc + ''[48;2;0;180;100m'' + $sep; $b2 = $esc + ''[38;2;0;0;0m '' + $c2 + '' '' + $time + '' ''; $s2 = $esc + ''[38;2;0;180;100m'' + $esc + ''[48;2;200;200;20m'' + $sep; $b3 = $esc + ''[38;2;0;0;0m '' + $c3 + '' '' + $cwd + '' ''; $s3 = $esc + ''[38;2;200;200;20m'' + $esc + ''[49m'' + $sep + $esc + ''[0m''; Write-Host -NoNewline ($b1 + $s1 + $b2 + $s2 + $b3 + $s3 + '' ''); return '' '' }; Clear-Host"';

function TryFindExeOnPath(const AName: string; out APath: string): Boolean;
var
  LBuffer: array[0..MAX_PATH] of Char;
  LFilePart: PChar;
  LLen: DWORD;
begin
  APath := '';
  LFilePart := nil;
  LLen := SearchPath(nil, PChar(AName), '.exe', Length(LBuffer), LBuffer, LFilePart);
  Result := (LLen > 0) and (LLen < Cardinal(Length(LBuffer)));
  if Result then
    APath := LBuffer;
end;

// Clamps a persisted ordinal back into TAIClientType — an out-of-range value
// (forward-compat / corrupted INI) safe-defaults to aitNone.
function _IntToAIClientType(const AValue: Integer): TAIClientType;
begin
  if (AValue >= Ord(Low(TAIClientType))) and (AValue <= Ord(High(TAIClientType))) then
    Result := TAIClientType(AValue)
  else
    Result := aitNone;
end;

{ TShellProfile }

constructor TShellProfile.Create(const AName, AExecutable, AArguments, AStartDir: string;
  const AClientType: TAIClientType = aitNone);
begin
  FName := AName;
  FExecutable := AExecutable;
  FArguments := AArguments;
  FStartDir := AStartDir;
  FAIClientType := AClientType;
end;

{ TProfileManager }

constructor TProfileManager.Create;
begin
  inherited Create;
  FProfiles := TObjectList<TShellProfile>.Create(True);
  FActiveProfileIndex := -1;
  LoadFromIni;
  if FProfiles.Count = 0 then
  begin
    _DiscoverDefaults;
    SaveToIni;
  end
  else
    _MergeDiscoveredProfiles;  // existing config: pick up newly-installed shells
end;

destructor TProfileManager.Destroy;
begin
  FProfiles.Free;
  inherited;
end;

function TProfileManager._GetConfigPath: string;
var
  LAppData: string;
  LDir: string;
begin
  LAppData := GetEnvironmentVariable('APPDATA');
  LDir := TPath.Combine(TPath.Combine(LAppData, 'ModernDelphiWorks'), 'Aefos.OTA.Terminal');
  if not TDirectory.Exists(LDir) then
    TDirectory.CreateDirectory(LDir);
  Result := TPath.Combine(LDir, 'config.ini');
end;

// True when at least one REAL WSL distro is installed. wsl.exe ships on Win10/11
// even without WSL, so read the Lxss registry (fast, no process spawn) AND skip
// Docker Desktop's helper distros ('docker-desktop' / '-data') — they are not
// interactive shells (launching one crashed). We only need the yes/no: the profile
// launches the user's DEFAULT distro (a registry name can be stale and mismatch).
const
  LXSS_KEY = 'Software\Microsoft\Windows\CurrentVersion\Lxss';

function _HasRealWslDistro: Boolean;
var
  LReg: TRegistry;
  LKeys: TStringList;
  LIdx: Integer;
  LName: string;
begin
  Result := False;
  LReg := TRegistry.Create(KEY_READ);
  LKeys := TStringList.Create;
  try
    LReg.RootKey := HKEY_CURRENT_USER;
    if not LReg.OpenKeyReadOnly(LXSS_KEY) then
      Exit;
    LReg.GetKeyNames(LKeys);
    LReg.CloseKey;
    for LIdx := 0 to LKeys.Count - 1 do
      if LReg.OpenKeyReadOnly(LXSS_KEY + '\' + LKeys[LIdx]) then
      try
        LName := LReg.ReadString('DistributionName');
        if (LName <> '') and not LName.ToLower.StartsWith('docker-desktop') then
          Exit(True);
      finally
        LReg.CloseKey;
      end;
  finally
    LKeys.Free;
    LReg.Free;
  end;
end;

// Full path to wsl.exe that is reachable from THIS process. wsl.exe lives only in
// the 64-bit System32; a 32-bit process (the classic Win32 IDE) gets WOW64-
// redirected to SysWOW64 where it does NOT exist (CreateProcess -> "file not found",
// error 2). The 'Sysnative' virtual alias lets a 32-bit process reach the real
// System32. A 64-bit process uses System32 directly. '' when not found.
function _WslExePath: string;
var
  LWin: string;
begin
  LWin := GetEnvironmentVariable('WINDIR');
{$IFDEF WIN64}
  Result := TPath.Combine(LWin, 'System32\wsl.exe');
{$ELSE}
  Result := TPath.Combine(LWin, 'Sysnative\wsl.exe');  // 32-bit -> real System32
{$ENDIF}
  if not TFile.Exists(Result) then
    Result := '';
end;

// Locates Git for Windows' bash.exe: git.exe on PATH -> <gitroot>\bin\bash.exe
// (git.exe is at <root>\cmd\git.exe, sometimes <root>\bin\git.exe). False when Git
// is not installed (profile omitted).
function _TryFindGitBash(out APath: string): Boolean;
var
  LGit, LCand: string;
begin
  APath := '';
  Result := False;
  if not TryFindExeOnPath('git', LGit) then
    Exit;
  // up one level from \cmd (or \bin), then \bin\bash.exe
  LCand := TPath.Combine(
    TPath.GetDirectoryName(TPath.GetDirectoryName(LGit)), 'bin\bash.exe');
  if TFile.Exists(LCand) then
  begin
    APath := LCand;
    Exit(True);
  end;
  // fallback: bash.exe alongside git.exe
  LCand := TPath.Combine(TPath.GetDirectoryName(LGit), 'bash.exe');
  if TFile.Exists(LCand) then
  begin
    APath := LCand;
    Result := True;
  end;
end;

procedure TProfileManager._DiscoverDefaults;
var
  LComSpec: string;
  LPwshSpec: string;
  LGitBash: string;
  LWslExe: string;
begin
  LComSpec := GetEnvironmentVariable('COMSPEC');
  if LComSpec = '' then LComSpec := 'cmd.exe';
  FProfiles.Add(TShellProfile.Create('cmd', LComSpec, '', ''));

  LPwshSpec := 'powershell.exe';
  FProfiles.Add(TShellProfile.Create('pwsh', LPwshSpec, POWERSHELL_POWERLINE_ARGS, ''));

  // NO bundled AI-CLI profile (claude/codex/gemini/ollama/...). The user opens
  // their OWN CLI inside a normal shell and toggles the Aefos composer bar on the
  // active terminal (a toolbar button) — shipping one CLI invites endless "add
  // mine too" requests and couples us to that CLI's lifecycle bugs.

  // WSL — only when a REAL distro exists (Docker Desktop's helper distros excluded)
  // AND wsl.exe is reachable from this process (Sysnative on 32-bit). Launch with NO
  // '-d' -> the user's DEFAULT distro (robust: a registry DistributionName can be
  // stale/non-matching -> WSL_E_DISTRO_NOT_FOUND; the default is what they expect).
  LWslExe := _WslExePath;
  if (LWslExe <> '') and _HasRealWslDistro then
    FProfiles.Add(TShellProfile.Create('wsl', LWslExe, '', ''));

  // Git Bash — when Git for Windows is installed. A Unix-like shell (bash + the GNU
  // tools) that most Windows devs already have. Login + interactive.
  if _TryFindGitBash(LGitBash) then
    FProfiles.Add(TShellProfile.Create('git-bash', LGitBash, '-l -i', ''));

  FActiveProfileIndex := 0;
end;

procedure TProfileManager._MergeDiscoveredProfiles;
var
  LGitBash, LWslExe, LWantWsl: string;
  LWsl, LClaudeProfile: TShellProfile;
  LChanged: Boolean;
begin
  LChanged := False;
  // Remove a bundled 'claude' profile left by an older version (see
  // _DiscoverDefaults): no AI-CLI profile ships — the user runs their CLI inside
  // a shell.
  LClaudeProfile := FindProfileByName('claude');
  if Assigned(LClaudeProfile) then
  begin
    FProfiles.Remove(LClaudeProfile);
    LChanged := True;
  end;
  // Remove a 'pwsh chat' profile from an earlier iteration (superseded by the
  // toolbar toggle that turns the active terminal's composer bar on/off).
  LClaudeProfile := FindProfileByName('pwsh chat');
  if Assigned(LClaudeProfile) then
  begin
    FProfiles.Remove(LClaudeProfile);
    LChanged := True;
  end;
  // WSL — reconcile: add/fix when a REAL distro exists; REMOVE a stale/broken one
  // (e.g. the earlier '-e /bin/bash' profile, or a docker-desktop-only machine
  // that has no usable distro). Fixes the RaiseLastOSError launch crash.
  LWsl := FindProfileByName('wsl');
  LWslExe := _WslExePath;
  if (LWslExe <> '') and _HasRealWslDistro then
  begin
    LWantWsl := '';  // no '-d' -> the user's DEFAULT distro (stale registry names
                     // can mismatch -> WSL_E_DISTRO_NOT_FOUND)
    if LWsl = nil then
    begin
      FProfiles.Add(TShellProfile.Create('wsl', LWslExe, LWantWsl, ''));
      LChanged := True;
    end
    else if (LWsl.Arguments <> LWantWsl) or not SameText(LWsl.Executable, LWslExe) then
    begin
      LWsl.Executable := LWslExe;
      LWsl.Arguments := LWantWsl;
      LChanged := True;
    end;
  end
  else if LWsl <> nil then
  begin
    FProfiles.Remove(LWsl);   // no usable distro (e.g. only docker-desktop) -> drop
    LChanged := True;
  end;
  // Git Bash — when Git for Windows is installed.
  if (FindProfileByName('git-bash') = nil) and _TryFindGitBash(LGitBash) then
  begin
    FProfiles.Add(TShellProfile.Create('git-bash', LGitBash, '-l -i', ''));
    LChanged := True;
  end;
  if LChanged then
    SaveToIni;
end;

procedure TProfileManager.LoadFromIni;
var
  LIni: TMemIniFile;
  LSections: TStringList;
  LSection: string;
  LProfile: TShellProfile;
  LIndex: Integer;
  LName: string;
  LModified: Boolean;
  LArgs: string;
begin
  FProfiles.Clear;
  LIni := TMemIniFile.Create(_GetConfigPath);
  LSections := TStringList.Create;
  LModified := False;
  try
    LIni.ReadSections(LSections);
    for LIndex := 0 to LSections.Count - 1 do
    begin
      LSection := LSections[LIndex];
      if LSection.StartsWith('Profile_') then
      begin
        LName := LIni.ReadString(LSection, 'Name', '');
        if SameText(LName, 'PowerShell') then
        begin
          LName := 'pwsh';
          LModified := True;
        end
        else if SameText(LName, 'Command Prompt') then
        begin
          LName := 'cmd';
          LModified := True;
        end;

        LArgs := LIni.ReadString(LSection, 'Arguments', '');
        if SameText(LName, 'pwsh') and ((LArgs = '') or not LArgs.Contains('[Console]::OutputEncoding') or not LArgs.Contains('0xE0B0') or LArgs.Contains('0x25BA') or LArgs.Contains('0x25C6') or LArgs.Contains('Replace') or LArgs.Contains('Split-Path') or not LArgs.Contains('ProviderPath')) then
        begin
          LArgs := POWERSHELL_POWERLINE_ARGS;
          LModified := True;
        end;

        LProfile := TShellProfile.Create(
          LName,
          LIni.ReadString(LSection, 'Executable', ''),
          LArgs,
          LIni.ReadString(LSection, 'StartDir', ''),
          _IntToAIClientType(LIni.ReadInteger(LSection, AI_CLIENT_TYPE_KEY, Ord(aitNone)))
        );
        FProfiles.Add(LProfile);
      end;
    end;
    
    // Attempt to select the saved active profile
    if FProfiles.Count > 0 then
    begin
      LSection := LIni.ReadString('Settings', 'ActiveProfile', '');
      if SameText(LSection, 'PowerShell') then
      begin
        LSection := 'pwsh';
        LModified := True;
      end
      else if SameText(LSection, 'Command Prompt') then
      begin
        LSection := 'cmd';
        LModified := True;
      end;
      
      FActiveProfileIndex := 0;
      for LIndex := 0 to FProfiles.Count - 1 do
      begin
        if FProfiles[LIndex].Name = LSection then
        begin
          FActiveProfileIndex := LIndex;
          Break;
        end;
      end;
    end
    else
      FActiveProfileIndex := -1;
      
    FAutoSync := LIni.ReadBool('Settings', 'AutoSync', False);
  finally
    LSections.Free;
    LIni.Free;
  end;

  if LModified then
    SaveToIni;
end;

procedure TProfileManager.SaveToIni;
var
  LIni: TMemIniFile;
  LIndex: Integer;
  LSection: string;
begin
  LIni := TMemIniFile.Create(_GetConfigPath);
  try
    LIni.Clear;
    for LIndex := 0 to FProfiles.Count - 1 do
    begin
      LSection := 'Profile_' + IntToStr(LIndex);
      LIni.WriteString(LSection, 'Name', FProfiles[LIndex].Name);
      LIni.WriteString(LSection, 'Executable', FProfiles[LIndex].Executable);
      LIni.WriteString(LSection, 'Arguments', FProfiles[LIndex].Arguments);
      LIni.WriteString(LSection, 'StartDir', FProfiles[LIndex].StartDir);
      LIni.WriteInteger(LSection, AI_CLIENT_TYPE_KEY, Ord(FProfiles[LIndex].AIClientType));
    end;
    
    if (FActiveProfileIndex >= 0) and (FActiveProfileIndex < FProfiles.Count) then
      LIni.WriteString('Settings', 'ActiveProfile', FProfiles[FActiveProfileIndex].Name);
      
    LIni.WriteBool('Settings', 'AutoSync', FAutoSync);
      
    LIni.UpdateFile;
  finally
    LIni.Free;
  end;
end;

function TProfileManager.FindProfileByName(const AName: string): TShellProfile;
var
  LProfile: TShellProfile;
begin
  Result := nil;
  for LProfile in FProfiles do
  begin
    if LProfile.Name = AName then
      Exit(LProfile);
  end;
end;

end.


