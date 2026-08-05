unit Aefos.MCP.OTA.ExternalToolService;

{
  External-tool spawn, extracted from the TMCPWorkspaceFacade god-object as a focused
  service of the SOLID split (audit S6 / facade split).

  Owns RunExternalTool — spawn a named external tool with an explicit argv via
  CreateProcess — plus its _QuoteArg (Win32 argv quoting) and _SpawnExternalTool
  (bounded CreateProcess + exit-code capture) helpers. The pure BuildRunPolicy seam
  (ClassifyExternalTool) refuses an empty / hard-destructive / soft-destructive argv
  BEFORE any execution; only a safe tool reaches CreateProcess. Project-independent —
  never runs RADShell, never persists host state.

  Both helpers are used ONLY by this slice. The only dependencies are Winapi.Windows
  (CreateProcess + the wait/exit-code calls) and the BuildRunPolicy seam. No OTA, no
  facade state (no FAudit), no public-method delegation. Bodies moved VERBATIM (only
  the class qualifier changes on RunExternalTool). The facade delegates the frozen
  method to a refcounted FExternalTool field.
}

interface

uses
  Aefos.MCP.Types;

type
  IMCPExternalToolService = interface
    ['{3F7C1E94-6D83-4B50-9A28-3C6A1B5E8D70}']
    function RunExternalTool(const AArgv: TArray<string>;
      out ARun: TMCPRecordExternalToolRun; out AReason: string): Boolean;
  end;

// Factory — the facade calls this once in its constructor.
function NewMCPExternalToolService: IMCPExternalToolService;

implementation

uses
  System.SysUtils,
  Winapi.Windows,
  Aefos.MCP.OTA.BuildRunPolicy;

type
  TMCPExternalToolService = class(TInterfacedObject, IMCPExternalToolService)
  public
    function RunExternalTool(const AArgv: TArray<string>;
      out ARun: TMCPRecordExternalToolRun; out AReason: string): Boolean;
  end;

// Quote one argv element for a Win32 command line: bare when it has no space or
// quote, else wrapped in double quotes with embedded quotes doubled.
function _QuoteArg(const AValue: string): string;
begin
  if (AValue <> '') and (Pos(' ', AValue) = 0) and (Pos('"', AValue) = 0) then
    Result := AValue
  else
    Result := '"' + StringReplace(AValue, '"', '""', [rfReplaceAll]) + '"';
end;

// Spawn an already-safe-classified external tool via CreateProcess (ESP-091, S2
// / ADR-091-07 / BR11). Bounded: waits up to CExternalToolWaitMs for a quick
// tool to exit and captures its exit code; a longer-lived process returns with
// ExitCodeKnown=False (ExitCode stays the Low(Integer) running sentinel, BR-5)
// while it continues independently. No window is shown (CREATE_NO_WINDOW). The
// caller has already refused any destructive/unknown argv.
function _SpawnExternalTool(const AArgv: TArray<string>;
  out ARun: TMCPRecordExternalToolRun; out AReason: string): Boolean;
const
  CExternalToolWaitMs = 5000;
var
  LCmdLine: string;
  LFor: Integer;
  LStartInfo: TStartupInfo;
  LProcInfo: TProcessInformation;
  LBuffer: array of Char;
  LExit: DWORD;
begin
  ARun := Default(TMCPRecordExternalToolRun);
  ARun.ExitCode      := Low(Integer); // running/unknown sentinel (BR-5)
  ARun.ExitCodeKnown := False;
  ARun.StartedAt     := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', Now);
  AReason            := '';

  LCmdLine := '';
  for LFor := 0 to High(AArgv) do
  begin
    if LFor > 0 then
      LCmdLine := LCmdLine + ' ';
    LCmdLine := LCmdLine + _QuoteArg(AArgv[LFor]);
  end;

  FillChar(LStartInfo, SizeOf(LStartInfo), 0);
  LStartInfo.cb := SizeOf(LStartInfo);
  FillChar(LProcInfo, SizeOf(LProcInfo), 0);
  // CreateProcess may modify the command-line buffer, so pass a writable copy.
  SetLength(LBuffer, Length(LCmdLine) + 1);
  if Length(LCmdLine) > 0 then
    Move(PChar(LCmdLine)^, LBuffer[0], Length(LCmdLine) * SizeOf(Char));
  LBuffer[Length(LCmdLine)] := #0;

  if not CreateProcess(nil, PChar(@LBuffer[0]), nil, nil, False,
       CREATE_NO_WINDOW, nil, nil, LStartInfo, LProcInfo) then
  begin
    AReason := 'spawn-failed';
    Exit(False);
  end;
  try
    ARun.Pid := Integer(LProcInfo.dwProcessId);
    if WaitForSingleObject(LProcInfo.hProcess, CExternalToolWaitMs) = WAIT_OBJECT_0 then
      if GetExitCodeProcess(LProcInfo.hProcess, LExit) then
      begin
        ARun.ExitCode      := Integer(LExit);
        ARun.ExitCodeKnown := True;
      end;
  finally
    CloseHandle(LProcInfo.hThread);
    CloseHandle(LProcInfo.hProcess);
  end;
  Result := True;
end;

function TMCPExternalToolService.RunExternalTool(
  const AArgv: TArray<string>;
  out ARun: TMCPRecordExternalToolRun; out AReason: string): Boolean;
var
  LExe, LReason: string;
  LRun: TMCPRecordExternalToolRun;
  LOk: Boolean;
begin
  LRun := Default(TMCPRecordExternalToolRun);
  LRun.ExitCode      := Low(Integer);
  LRun.ExitCodeKnown := False;
  // Stamp StartedAt on ALL paths. The happy path sets it in _SpawnExternalTool,
  // but the refusal path below returned LRun with StartedAt still '' — an
  // inconsistent record (a run that WAS requested but is reported with no start
  // time). Set it up front, matching the spawn-path format.
  LRun.StartedAt     := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', Now);
  if not TBuildRunPolicy.ClassifyExternalTool(AArgv, LExe, LReason) then
  begin
    ARun    := LRun;
    AReason := LReason;
    Exit(False); // unsafe / empty argv refused — no execution (R5)
  end;
  try
    LOk := _SpawnExternalTool(AArgv, LRun, LReason);
  except
    on E: Exception do
    begin
      LOk     := False;
      LReason := E.Message;
    end;
  end;
  ARun := LRun;
  if LOk then
    AReason := ''
  else
    AReason := LReason;
  Result := LOk;
end;

function NewMCPExternalToolService: IMCPExternalToolService;
begin
  Result := TMCPExternalToolService.Create;
end;

end.
