unit Aefos.OTA.Chat.Core.CLIBinaryResolver;

{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  CLI binary resolver helper (ESP-008 + ESP-002 ADR-036).

  Resolves the full path to the external CLI binary used by Core.CommandExecutor.
  Resolution order (ADR-036):
    1. Env var `AEFOS_CLI` — if set and the path exists, return verbatim.
    2. Else AConfigPath if non-empty and `TFile.Exists(AConfigPath)`.
    3. Else `ABinaryName` on PATH, directory by directory in PATH order, trying
       .exe, .cmd and .bat in each (never an extensionless file: CreateProcess
       cannot start one, error 193). Relative PATH entries are skipped.
    3b. Else %USERPROFILE%\.local\bin\<name>.exe (the native Claude Code
       installer's folder, which is not always on PATH).
    4. Else the installer-bundled binary in %APPDATA%\Aefos\bin\<name>.exe (the
       same folder AefosAgent.exe lives in). Makes a bundled CLI (codex, gemini,
       copilot) resolve out-of-the-box without the user adding it to PATH — but
       AFTER PATH, so a user's own install (possibly newer) still wins.
    5. Else empty string. Caller raises ECLINotFound at the surface.

  ABinaryName is a required parameter (ESP-004, ADR-074): the executor's
  default binary name comes from the active IExecutorProfile, never a literal.

  No process spawn here; caller does that via Core.CLIDispatcher. Windows-only.
}

interface

function ResolveCLIBinary(const AConfigPath, ABinaryName: string): string;

implementation

uses
{$IFDEF FPC}
  Windows,
{$ELSE}
  Winapi.Windows,
{$ENDIF}
  SysUtils,
  Aefos.Compat.IO;

const
  ENV_OVERRIDE_NAME = 'AEFOS_CLI';

function _ReadEnvOverride: string;
begin
  // Qualified: `uses Windows` exports a 3-arg GetEnvironmentVariable that
  // SHADOWS the 1-arg SysUtils one.
  Result := SysUtils.GetEnvironmentVariable(ENV_OVERRIDE_NAME);
end;

function _SearchWithExtension(const ABinaryName, AExtension: string): string;
var
  LBuffer: array[0..MAX_PATH] of Char;
  LFilePart: PChar;
  LExtArg: PChar;
  LLen: DWORD;
begin
  if AExtension = '' then
    LExtArg := nil
  else
    LExtArg := PChar(AExtension);
  // SearchPathW, not the unqualified SearchPath: FPC's Windows unit maps the
  // unqualified name to the ANSI entry point (LPSTR), which does not take this
  // unit's PChar (= PWideChar under delphiunicode). On Delphi the unqualified
  // name already IS the W one, so both builds call the identical API.
  LLen := SearchPathW(nil, PChar(ABinaryName), LExtArg,
    Length(LBuffer), LBuffer, LFilePart);
  if LLen > 0 then
    Result := LBuffer
  else
    Result := '';
end;

const
  // What CreateProcess can actually start, in the order cmd.exe tries them. A
  // file WITHOUT one of these is never runnable on Windows: npm drops an
  // extensionless `codex`/`gemini` beside the `.cmd`, and that one is a /bin/sh
  // script for Git Bash (CreateProcess refuses it with error 193,
  // ERROR_BAD_EXE_FORMAT).
  RUNNABLE_EXTENSIONS: array[0..2] of string = ('.exe', '.cmd', '.bat');

function _HasExtension(const APath: string): Boolean;
begin
  Result := ExtractFileExt(APath) <> '';
end;

function _RunnableSibling(const APathWithoutExtension: string): string;
var
  LFor: Integer;
begin
  for LFor := Low(RUNNABLE_EXTENSIONS) to High(RUNNABLE_EXTENSIONS) do
    if TFile.Exists(APathWithoutExtension + RUNNABLE_EXTENSIONS[LFor]) then
      Exit(APathWithoutExtension + RUNNABLE_EXTENSIONS[LFor]);
  Result := '';
end;

function _ExeFileName(const ABinaryName: string): string;
begin
  // Profiles name their binary either way: 'claude.exe' (Claude) or 'codex'
  // (Codex). A folder lookup must not turn the first into 'claude.exe.exe',
  // which is exactly how the ~/.local/bin rung missed claude.exe on its first
  // live test (2026-09-28).
  if _HasExtension(ABinaryName) then
    Result := ABinaryName
  else
    Result := ABinaryName + '.exe';
end;

function _NextPathEntry(const APathList: string; var APos: Integer): string;
var
  LEnd: Integer;
begin
  LEnd := APos;
  while (LEnd <= Length(APathList)) and (APathList[LEnd] <> ';') do
    Inc(LEnd);
  Result := Trim(Copy(APathList, APos, LEnd - APos));
  APos := LEnd + 1;
  // A PATH entry may be quoted when it holds a ';' of its own.
  if (Length(Result) >= 2) and (Result[1] = '"') and (Result[Length(Result)] = '"') then
    Result := Copy(Result, 2, Length(Result) - 2);
end;

function _SearchOnPath(const ABinaryName: string): string;
var
  LPathList: string;
  LPos: Integer;
  LDir: string;
begin
  Result := '';
  if ABinaryName = '' then
    Exit;
  // A name that already carries an extension ('claude.exe') resolves verbatim.
  if _HasExtension(ABinaryName) then
    Exit(_SearchWithExtension(ABinaryName, ''));
  // An extensionless name is looked up the way cmd.exe does it: PATH directory
  // by directory, IN ORDER, trying each runnable extension inside each one.
  // Asking SearchPath for '' first (the old ladder) went the other way round:
  // it matched the extensionless npm shell script (`...\npm\codex`) in a LATER
  // directory before ever looking for `codex.exe` in an earlier one, and the
  // launch died with error 193 (field report 2026-09-28). Walking the list also
  // picks the same binary the user's own terminal runs for `codex`.
  LPathList := SysUtils.GetEnvironmentVariable('PATH');
  LPos := 1;
  while LPos <= Length(LPathList) do
  begin
    LDir := _NextPathEntry(LPathList, LPos);
    // Relative entries ('.\modules\.bin') would resolve against whatever the
    // current directory happens to be. Skipped: a CLI is never looked up there.
    if (LDir = '') or not TPath.IsPathRooted(LDir) then
      Continue;
    Result := _RunnableSibling(TPath.Combine(LDir, ABinaryName));
    if Result <> '' then
      Exit;
  end;
  // What PATH did not hold, the system search path still may (application and
  // system directories), with the runnable extensions only.
  for LPos := Low(RUNNABLE_EXTENSIONS) to High(RUNNABLE_EXTENSIONS) do
  begin
    Result := _SearchWithExtension(ABinaryName, RUNNABLE_EXTENSIONS[LPos]);
    if Result <> '' then
      Exit;
  end;
end;

function _UserLocalBinPath(const ABinaryName: string): string;
var
  LHome: string;
  LPath: string;
begin
  // %USERPROFILE%\.local\bin is where the native Claude Code installer puts
  // claude.exe, and it does not always make it onto PATH (field report
  // 2026-09-28: the CLI was installed there, PATH did not list the folder, and
  // the chat said "No AI CLI was found").
  Result := '';
  if ABinaryName = '' then
    Exit;
  LHome := SysUtils.GetEnvironmentVariable('USERPROFILE');
  if LHome = '' then
    Exit;
  LPath := TPath.Combine(TPath.Combine(TPath.Combine(LHome, '.local'), 'bin'),
    _ExeFileName(ABinaryName));
  if TFile.Exists(LPath) then
    Result := LPath;
end;

function _BundledBinPath(const ABinaryName: string): string;
var
  LPath: string;
begin
  // The installer stages the bundled third-party CLIs (codex/gemini/copilot)
  // beside our own AefosAgent.exe in %APPDATA%\Aefos\bin, so they resolve
  // out-of-the-box without the user putting them on PATH. TPath.GetHomePath =
  // %AppData%\Roaming on Windows — the same base TChatGlobalSettings uses.
  Result := '';
  if ABinaryName = '' then
    Exit;
  LPath := TPath.Combine(
    TPath.Combine(TPath.Combine(TPath.GetHomePath, 'Aefos'), 'bin'),
    _ExeFileName(ABinaryName));
  if TFile.Exists(LPath) then
    Result := LPath;
end;

function ResolveCLIBinary(const AConfigPath, ABinaryName: string): string;
var
  LOverride: string;
begin
  LOverride := _ReadEnvOverride;
  if (LOverride <> '') and TFile.Exists(LOverride) then
    Exit(LOverride);
  if (AConfigPath <> '') and TFile.Exists(AConfigPath) then
  begin
    // A configured path to the extensionless npm shell script cannot be
    // started either (error 193): use the runnable file beside it, if any.
    if not _HasExtension(AConfigPath) then
    begin
      Result := _RunnableSibling(AConfigPath);
      if Result <> '' then
        Exit;
    end;
    Exit(AConfigPath);
  end;
  Result := _SearchOnPath(ABinaryName);
  // Rung 3b: the native installer's per-user folder, for when it is not on PATH.
  if Result = '' then
    Result := _UserLocalBinPath(ABinaryName);
  // Rung 4: the installer-bundled binary. AFTER PATH so a user's own install
  // still wins; before "" so a bundled CLI resolves with zero configuration.
  if Result = '' then
    Result := _BundledBinPath(ABinaryName);
end;

end.
