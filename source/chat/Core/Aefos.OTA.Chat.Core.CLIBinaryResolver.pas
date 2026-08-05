unit Aefos.OTA.Chat.Core.CLIBinaryResolver;

{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  CLI binary resolver helper (ESP-008 + ESP-002 ADR-036).

  Resolves the full path to the external CLI binary used by Core.CommandExecutor.
  Resolution order (ADR-036):
    1. Env var `AEFOS_CLI` — if set and the path exists, return verbatim.
    2. Else AConfigPath if non-empty and `TFile.Exists(AConfigPath)`.
    3. Else `SearchPath` for `ABinaryName` on PATH.
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

function _SearchOnPath(const ABinaryName: string): string;
const
  // Verbatim first: a name carrying an extension ('claude.exe') resolves on
  // this rung byte-identically. The .cmd/.bat rungs find npm-distributed
  // shims (ADR-077). First hit wins.
  EXTENSION_LADDER: array[0..3] of string = ('', '.exe', '.cmd', '.bat');
var
  LFor: Integer;
begin
  Result := '';
  if ABinaryName = '' then
    Exit;
  for LFor := Low(EXTENSION_LADDER) to High(EXTENSION_LADDER) do
  begin
    Result := _SearchWithExtension(ABinaryName, EXTENSION_LADDER[LFor]);
    if Result <> '' then
      Exit;
  end;
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
    ABinaryName + '.exe');
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
    Exit(AConfigPath);
  Result := _SearchOnPath(ABinaryName);
  // Rung 4: the installer-bundled binary. AFTER PATH so a user's own install
  // still wins; before "" so a bundled CLI resolves with zero configuration.
  if Result = '' then
    Result := _BundledBinPath(ABinaryName);
end;

end.
