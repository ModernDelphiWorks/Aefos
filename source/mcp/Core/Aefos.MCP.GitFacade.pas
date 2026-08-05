unit Aefos.MCP.GitFacade;

(*
  Git facade interface + production implementation (ESP-002, Epic 1/3
  Demand 1/5 — Git/VCS group, ADR-201/ADR-202).

  Layering:
    - Zero uses ToolsAPI (ADR-115 / project_mcp_core_decoupled).
      Boundary enforced by Tests.MCPPackageBoundary.
    - Repo-root anchor injected via TFunc<string> lambda; mirrors
      CommandRegistry / ContextBuilder lazy-root pattern (ADR-082).

  Subprocess sandbox (ADR-202):
    - 5 s wall-clock timeout per invocation; timeout returns
      AError='timeout' and the child is terminated.
    - 8 MiB stdout cap; over-budget returns AError='output-too-large'.
    - stdin closed; stdout + stderr captured separately via redirected
      anonymous pipes; UTF-8 decoded.
    - cwd = resolved repo root.
    - PATH resolution is performed once at construction; subsequent
      calls return AError='git-not-found' without re-scanning.

  Read-only contract (BR-1): no mutating Git operations are exposed.
*)

interface

uses
  System.SysUtils;

type
  TGitStatusItem = record
    FileName: string;
    Status: string;
  end;

  TGitLogEntry = record
    Hash: string;
    Author: string;
    Date: string;
    Message: string;
  end;

  IMCPGitFacade = interface
    ['{B7F8E5C3-3C5A-4B91-8B2E-2F7C1A6E9D34}']
    function GetStatus(out AItems: TArray<TGitStatusItem>;
      out AError: string): Boolean;
    function GetCurrentBranch(out ABranch: string; out ADetached: Boolean;
      out AError: string): Boolean;
    function GetLog(const ACount: Integer;
      out ACommits: TArray<TGitLogEntry>; out AError: string): Boolean;
    function GetFileDiff(const AFilePath: string; out APatch: string;
      out AError: string): Boolean;
    // Committed content of a file at HEAD (`git show HEAD:./<rel>`). Backs the
    // buffer-vs-HEAD diff: the IDE side supplies the DIRTY editor buffer, this
    // supplies the committed side. AError='not-in-head' when the path is not
    // tracked at HEAD (new/untracked file).
    function GetFileAtHead(const AFilePath: string; out AContent: string;
      out AError: string): Boolean;
  end;

  TGitCaptureResult = record
    ExitCode: Integer;
    StdOut: string;
    StdErr: string;
    // The RAW stdout bytes, kept alongside the UTF-8 decode. `git show` streams
    // the COMMITTED BYTES of a file, and a legacy Delphi unit is very often
    // ANSI/cp1252 with no BOM — decoding those as UTF-8 mangles every accented
    // line and would make an untouched file look completely rewritten. Anything
    // that reads FILE CONTENT (as opposed to git's own porcelain, which is
    // UTF-8) must decode from here via DecodeSourceBytes.
    StdOutBytes: TBytes;
    TimedOut: Boolean;
    OutputTooLarge: Boolean;
  end;

  TGitFacade = class(TInterfacedObject, IMCPGitFacade)
  private
    FRepoRootResolver: TFunc<string>;
    FGitExePath: string;
    FGitExeResolved: Boolean;
    FTimeoutMs: Cardinal;
    FMaxOutputBytes: Integer;
    function _ResolveGitExe: string;
    function _ResolveRepoRoot: string;
    function _RunCapture(const AArgs: array of string;
      const ACwd: string): TGitCaptureResult;
    function _ParseStatusPorcelainZ(const ARaw: string): TArray<TGitStatusItem>;
    procedure _ParseStatusRecord(const ARaw: string; const ALen: Integer;
      var APos: Integer; var ARows: TArray<TGitStatusItem>);
    function _ParseLogOutput(const ARaw: string): TArray<TGitLogEntry>;
    function _ClampCount(const ACount: Integer): Integer;
    function _NormalizePath(const ARepoRoot, AFilePath: string;
      out AAbsolute: string; out AError: string): Boolean;
  public
    constructor Create(const ARepoRootResolver: TFunc<string>;
      const AGitExePath: string = '');
    function GetStatus(out AItems: TArray<TGitStatusItem>;
      out AError: string): Boolean;
    function GetCurrentBranch(out ABranch: string; out ADetached: Boolean;
      out AError: string): Boolean;
    function GetLog(const ACount: Integer;
      out ACommits: TArray<TGitLogEntry>; out AError: string): Boolean;
    function GetFileDiff(const AFilePath: string; out APatch: string;
      out AError: string): Boolean;
    function GetFileAtHead(const AFilePath: string; out AContent: string;
      out AError: string): Boolean;
  end;

// Decodes SOURCE-FILE bytes the way the IDE loads a unit: BOM sniff first
// (UTF-8 / UTF-16 LE / BE), then STRICT UTF-8 (a well-formed UTF-8 file without
// a BOM is still UTF-8), and only then the ANSI/cp1252 fallback — because the
// target market is legacy Delphi, where an accented `.pas` is routinely cp1252
// with no BOM. Blind-decoding those as UTF-8 turns 'Ação' into 'A��o' and makes
// an UNTOUCHED file diff as fully rewritten. Pure + headless-testable on
// purpose. The BOM itself is never returned.
function DecodeSourceBytes(const ABytes: TBytes): string;

implementation

uses
  Winapi.Windows,
  System.IOUtils;

const
  GIT_DEFAULT_TIMEOUT_MS = 5000;
  GIT_MAX_OUTPUT_BYTES   = 8 * 1024 * 1024;
  CP_WINDOWS_1252        = 1252;

// True when ABytes is valid UTF-8 (no invalid sequences). A file that decodes
// cleanly as UTF-8 IS UTF-8 even without a BOM, so it must not fall through to
// the ANSI codepage. Implemented by hand (no exception, no allocation) because
// TEncoding.UTF8 silently substitutes U+FFFD instead of reporting the error.
function _IsValidUtf8(const ABytes: TBytes; const AStart: Integer): Boolean;
var
  LFor, LLen, LTrail, LT: Integer;
  LB: Byte;
begin
  LFor := AStart;
  LLen := Length(ABytes);
  while LFor < LLen do
  begin
    LB := ABytes[LFor];
    if LB < $80 then
      LTrail := 0
    else if (LB and $E0) = $C0 then
    begin
      LTrail := 1;
      if LB < $C2 then Exit(False);   // overlong (C0/C1)
    end
    else if (LB and $F0) = $E0 then
      LTrail := 2
    else if (LB and $F8) = $F0 then
    begin
      LTrail := 3;
      if LB > $F4 then Exit(False);   // beyond U+10FFFF
    end
    else
      Exit(False);                    // stray continuation / 5-6 byte form
    for LT := 1 to LTrail do
    begin
      if LFor + LT >= LLen then Exit(False);
      if (ABytes[LFor + LT] and $C0) <> $80 then Exit(False);
    end;
    Inc(LFor, LTrail + 1);
  end;
  Result := True;
end;

function DecodeSourceBytes(const ABytes: TBytes): string;
var
  LLen: Integer;
  LAnsi: TEncoding;
begin
  LLen := Length(ABytes);
  if LLen = 0 then
    Exit('');
  // UTF-8 BOM.
  if (LLen >= 3) and (ABytes[0] = $EF) and (ABytes[1] = $BB)
    and (ABytes[2] = $BF) then
    Exit(TEncoding.UTF8.GetString(ABytes, 3, LLen - 3));
  // UTF-16 LE / BE BOM.
  if (LLen >= 2) and (ABytes[0] = $FF) and (ABytes[1] = $FE) then
    Exit(TEncoding.Unicode.GetString(ABytes, 2, LLen - 2));
  if (LLen >= 2) and (ABytes[0] = $FE) and (ABytes[1] = $FF) then
    Exit(TEncoding.BigEndianUnicode.GetString(ABytes, 2, LLen - 2));
  // No BOM: valid UTF-8 stays UTF-8; otherwise it is a legacy ANSI unit.
  if _IsValidUtf8(ABytes, 0) then
    Exit(TEncoding.UTF8.GetString(ABytes));
  LAnsi := TEncoding.GetEncoding(CP_WINDOWS_1252);
  try
    Result := LAnsi.GetString(ABytes);
  finally
    LAnsi.Free;
  end;
end;

{ TGitFacade }

constructor TGitFacade.Create(const ARepoRootResolver: TFunc<string>;
  const AGitExePath: string);
begin
  inherited Create;
  FRepoRootResolver := ARepoRootResolver;
  FGitExePath := AGitExePath;
  FGitExeResolved := False;
  FTimeoutMs := GIT_DEFAULT_TIMEOUT_MS;
  FMaxOutputBytes := GIT_MAX_OUTPUT_BYTES;
end;

function TGitFacade._ResolveGitExe: string;
var
  LBuf: array[0..MAX_PATH] of Char;
  LFilePart: PChar;
  LLen: DWORD;
begin
  // Cache the resolution so subsequent failed lookups do not re-scan PATH.
  // Empty string is a valid cached "not found" signal (ADR-202 §3).
  if FGitExeResolved then
    Exit(FGitExePath);
  FGitExeResolved := True;
  if FGitExePath <> '' then
  begin
    if not TFile.Exists(FGitExePath) then
      FGitExePath := '';
    Exit(FGitExePath);
  end;
  LFilePart := nil;
  LLen := Winapi.Windows.SearchPath(nil, 'git.exe', nil, MAX_PATH,
    LBuf, LFilePart);
  if (LLen > 0) and (LLen < MAX_PATH) then
    FGitExePath := string(LBuf)
  else
    FGitExePath := '';
  Result := FGitExePath;
end;

function TGitFacade._ResolveRepoRoot: string;
begin
  Result := '';
  if Assigned(FRepoRootResolver) then
    Result := FRepoRootResolver();
end;

// Quotes a single argv element for CreateProcess command-line composition.
function _QuoteArg(const AArg: string): string;
var
  LBuilder: TStringBuilder;
  LFor: Integer;
  LBackslashes: Integer;
  LCh: Char;
begin
  if (AArg <> '') and (Pos(' ', AArg) = 0) and (Pos('"', AArg) = 0)
    and (Pos(#9, AArg) = 0) then
    Exit(AArg);
  LBuilder := TStringBuilder.Create;
  try
    LBuilder.Append('"');
    LBackslashes := 0;
    for LFor := 1 to Length(AArg) do
    begin
      LCh := AArg[LFor];
      if LCh = '\' then
        Inc(LBackslashes)
      else
      begin
        if LCh = '"' then
        begin
          LBuilder.Append(StringOfChar('\', LBackslashes * 2 + 1));
          LBuilder.Append('"');
        end
        else
        begin
          LBuilder.Append(StringOfChar('\', LBackslashes));
          LBuilder.Append(LCh);
        end;
        LBackslashes := 0;
      end;
    end;
    LBuilder.Append(StringOfChar('\', LBackslashes * 2));
    LBuilder.Append('"');
    Result := LBuilder.ToString;
  finally
    LBuilder.Free;
  end;
end;

// Drains one chunk from a pipe handle. Returns True if at least one byte was
// read. AOverCap is set when AEnforceCap is True and appending would exceed
// AMaxBytes; in that case the chunk is NOT appended.
function _DrainOnce(const AHandle: THandle; var ABuf: TBytes;
  var ALen: Integer; const AMaxBytes: Integer; const AEnforceCap: Boolean;
  out AOverCap: Boolean): Boolean;
var
  LAvail: DWORD;
  LBytesRead: DWORD;
  LChunk: array[0..4095] of Byte;
  LNewLen: Integer;
begin
  Result := False;
  AOverCap := False;
  LAvail := 0;
  if not PeekNamedPipe(AHandle, nil, 0, nil, @LAvail, nil) then Exit;
  if LAvail = 0 then Exit;
  if not ReadFile(AHandle, LChunk[0], SizeOf(LChunk), LBytesRead, nil) then
    Exit;
  if LBytesRead = 0 then Exit;
  LNewLen := ALen + Integer(LBytesRead);
  if AEnforceCap and (LNewLen > AMaxBytes) then
  begin
    AOverCap := True;
    Exit;
  end;
  if LNewLen > Length(ABuf) then
    SetLength(ABuf, LNewLen * 2);
  Move(LChunk[0], ABuf[ALen], LBytesRead);
  ALen := LNewLen;
  Result := True;
end;

function _BuildCmdLine(const AExe: string;
  const AArgs: array of string): string;
var
  LFor: Integer;
begin
  Result := _QuoteArg(AExe);
  for LFor := 0 to High(AArgs) do
    Result := Result + ' ' + _QuoteArg(AArgs[LFor]);
end;

function _SpawnGitChild(const ACmdLine, ACwd: string;
  const AStdIn, AStdOut, AStdErr: THandle;
  out AProcInfo: TProcessInformation): Boolean;
var
  LStartup: TStartupInfo;
  LCwd: string;
begin
  FillChar(LStartup, SizeOf(LStartup), 0);
  LStartup.cb := SizeOf(LStartup);
  LStartup.dwFlags := STARTF_USESHOWWINDOW or STARTF_USESTDHANDLES;
  LStartup.wShowWindow := SW_HIDE;
  LStartup.hStdInput := AStdIn;
  LStartup.hStdOutput := AStdOut;
  LStartup.hStdError := AStdErr;
  FillChar(AProcInfo, SizeOf(AProcInfo), 0);
  LCwd := ACwd;
  Result := CreateProcess(nil, PChar(ACmdLine), nil, nil, True,
    CREATE_NO_WINDOW, nil, PChar(LCwd), LStartup, AProcInfo);
end;

function TGitFacade._RunCapture(const AArgs: array of string;
  const ACwd: string): TGitCaptureResult;
var
  LSecAttr: TSecurityAttributes;
  LStdOutRead, LStdOutWrite: THandle;
  LStdErrRead, LStdErrWrite: THandle;
  LStdInRead, LStdInWrite: THandle;
  LProcInfo: TProcessInformation;
  LExitCode: DWORD;
  LStdOutBuf, LStdErrBuf: TBytes;
  LStdOutLen, LStdErrLen: Integer;
  LStart: UInt64;
  LCmdLine: string;
  LOverCap: Boolean;
begin
  Result := Default(TGitCaptureResult);
  LCmdLine := _BuildCmdLine(_ResolveGitExe, AArgs);

  FillChar(LSecAttr, SizeOf(LSecAttr), 0);
  LSecAttr.nLength := SizeOf(LSecAttr);
  LSecAttr.bInheritHandle := True;

  if not CreatePipe(LStdOutRead, LStdOutWrite, @LSecAttr, 0) then
    RaiseLastOSError;
  try
    if not CreatePipe(LStdErrRead, LStdErrWrite, @LSecAttr, 0) then
      RaiseLastOSError;
    try
      if not CreatePipe(LStdInRead, LStdInWrite, @LSecAttr, 0) then
        RaiseLastOSError;
      try
        // The child must not inherit the read/write ends we keep.
        SetHandleInformation(LStdOutRead, HANDLE_FLAG_INHERIT, 0);
        SetHandleInformation(LStdErrRead, HANDLE_FLAG_INHERIT, 0);
        SetHandleInformation(LStdInWrite, HANDLE_FLAG_INHERIT, 0);

        if not _SpawnGitChild(LCmdLine, ACwd, LStdInRead, LStdOutWrite,
          LStdErrWrite, LProcInfo) then
          RaiseLastOSError;

        // Close child-side handles in the parent so reads unblock on exit.
        CloseHandle(LStdOutWrite); LStdOutWrite := 0;
        CloseHandle(LStdErrWrite); LStdErrWrite := 0;
        CloseHandle(LStdInRead);   LStdInRead := 0;
        // git reads no input here — close stdin write end immediately.
        CloseHandle(LStdInWrite);  LStdInWrite := 0;

        SetLength(LStdOutBuf, 16 * 1024);
        SetLength(LStdErrBuf, 4 * 1024);
        LStdOutLen := 0;
        LStdErrLen := 0;
        LStart := GetTickCount64;

        try
          while True do
          begin
            _DrainOnce(LStdOutRead, LStdOutBuf, LStdOutLen,
              FMaxOutputBytes, True, LOverCap);
            if LOverCap then
            begin
              Result.OutputTooLarge := True;
              TerminateProcess(LProcInfo.hProcess, 1);
              Break;
            end;
            _DrainOnce(LStdErrRead, LStdErrBuf, LStdErrLen, 0, False,
              LOverCap);
            if WaitForSingleObject(LProcInfo.hProcess, 25) = WAIT_OBJECT_0 then
              Break;
            if GetTickCount64 - LStart >= FTimeoutMs then
            begin
              Result.TimedOut := True;
              TerminateProcess(LProcInfo.hProcess, 1);
              WaitForSingleObject(LProcInfo.hProcess, 1000);
              Break;
            end;
          end;

          // Final drain after child exit.
          if not Result.TimedOut and not Result.OutputTooLarge then
          begin
            while _DrainOnce(LStdOutRead, LStdOutBuf, LStdOutLen,
              FMaxOutputBytes, True, LOverCap) do ;
            if LOverCap then Result.OutputTooLarge := True;
            while _DrainOnce(LStdErrRead, LStdErrBuf, LStdErrLen, 0, False,
              LOverCap) do ;
          end;

          if GetExitCodeProcess(LProcInfo.hProcess, LExitCode) then
            Result.ExitCode := Integer(LExitCode)
          else
            Result.ExitCode := -1;
        finally
          CloseHandle(LProcInfo.hProcess);
          CloseHandle(LProcInfo.hThread);
        end;

        SetLength(LStdOutBuf, LStdOutLen);
        SetLength(LStdErrBuf, LStdErrLen);
        // Keep the raw bytes for content reads (git show); the UTF-8 decode is
        // right for git's own porcelain (status/log/diff), which git emits UTF-8.
        Result.StdOutBytes := Copy(LStdOutBuf, 0, LStdOutLen);
        Result.StdOut := TEncoding.UTF8.GetString(LStdOutBuf);
        Result.StdErr := TEncoding.UTF8.GetString(LStdErrBuf);
      finally
        if LStdInRead <> 0 then CloseHandle(LStdInRead);
        if LStdInWrite <> 0 then CloseHandle(LStdInWrite);
      end;
    finally
      if LStdErrWrite <> 0 then CloseHandle(LStdErrWrite);
      CloseHandle(LStdErrRead);
    end;
  finally
    if LStdOutWrite <> 0 then CloseHandle(LStdOutWrite);
    CloseHandle(LStdOutRead);
  end;
end;

// Builds a TGitStatusItem from the raw two-char XY prefix and the path.
function _BuildStatusItem(const AXY, AFileName: string): TGitStatusItem;
var
  LCode: string;
begin
  Result.FileName := AFileName;
  LCode := Trim(AXY);
  // Untracked porcelain code is '??' — preserve it; otherwise keep the
  // first non-space code as the canonical status letter.
  if LCode = '??' then
    Result.Status := '??'
  else if LCode <> '' then
    Result.Status := LCode[1]
  else
    Result.Status := '';
end;

// Reads a single NUL-terminated path starting at APos and advances APos
// past the terminator.
function _ReadNulPath(const ARaw: string; const ALen: Integer;
  var APos: Integer): string;
var
  LStart: Integer;
begin
  LStart := APos;
  while (APos <= ALen) and (ARaw[APos] <> #0) do
    Inc(APos);
  Result := Copy(ARaw, LStart, APos - LStart);
  if APos <= ALen then
    Inc(APos);  // skip NUL
end;

procedure TGitFacade._ParseStatusRecord(const ARaw: string;
  const ALen: Integer; var APos: Integer;
  var ARows: TArray<TGitStatusItem>);
var
  LXY: string;
  LFileName: string;
  LIsRename: Boolean;
begin
  LXY := Copy(ARaw, APos, 2);
  Inc(APos, 2);
  if (APos <= ALen) and (ARaw[APos] = ' ') then
    Inc(APos);
  LFileName := _ReadNulPath(ARaw, ALen, APos);
  if (LXY <> '') or (LFileName <> '') then
    ARows := ARows + [_BuildStatusItem(LXY, LFileName)];
  // Rename / copy records carry a second NUL-terminated path (the old
  // name) — consume it without producing an extra row.
  LIsRename := (Length(LXY) >= 1) and ((LXY[1] = 'R') or (LXY[1] = 'C'));
  if LIsRename then
    _ReadNulPath(ARaw, ALen, APos);
end;

function TGitFacade._ParseStatusPorcelainZ(
  const ARaw: string): TArray<TGitStatusItem>;
var
  LList: TArray<TGitStatusItem>;
  LPos: Integer;
  LLen: Integer;
begin
  // porcelain v1 -z format per record:
  //   XY<space><path><NUL>             (regular entry)
  //   R <new><NUL><old><NUL>           (rename — old follows new)
  //   C <new><NUL><old><NUL>           (copy — old follows new)
  SetLength(LList, 0);
  LLen := Length(ARaw);
  LPos := 1;
  while (LPos <= LLen) and (LLen - LPos + 1 >= 3) do
    _ParseStatusRecord(ARaw, LLen, LPos, LList);
  Result := LList;
end;

function TGitFacade._ParseLogOutput(
  const ARaw: string): TArray<TGitLogEntry>;
var
  LLines: TArray<string>;
  LFor: Integer;
  LParts: TArray<string>;
  LEntry: TGitLogEntry;
  LNormalized: string;
begin
  SetLength(Result, 0);
  // Normalize line endings; --pretty=format does not emit a trailing newline.
  LNormalized := StringReplace(ARaw, #13#10, #10, [rfReplaceAll]);
  LLines := LNormalized.Split([#10]);
  for LFor := 0 to High(LLines) do
  begin
    if LLines[LFor] = '' then
      Continue;
    LParts := LLines[LFor].Split([#9]);
    if Length(LParts) < 4 then
      Continue;
    LEntry.Hash := LParts[0];
    LEntry.Author := LParts[1];
    LEntry.Date := LParts[2];
    LEntry.Message := LParts[3];
    Result := Result + [LEntry];
  end;
end;

function TGitFacade._ClampCount(const ACount: Integer): Integer;
begin
  if ACount > 200 then
    Result := 200
  else
    Result := ACount;
end;

function TGitFacade._NormalizePath(const ARepoRoot, AFilePath: string;
  out AAbsolute: string; out AError: string): Boolean;
var
  LAbs: string;
  LRoot: string;
begin
  AAbsolute := '';
  AError := '';
  Result := False;
  if AFilePath = '' then
  begin
    AError := 'invalid-path';
    Exit;
  end;
  if TPath.IsPathRooted(AFilePath) then
    LAbs := TPath.GetFullPath(AFilePath)
  else
    LAbs := TPath.GetFullPath(TPath.Combine(ARepoRoot, AFilePath));
  LRoot := IncludeTrailingPathDelimiter(TPath.GetFullPath(ARepoRoot));
  if not LAbs.ToLower.StartsWith(LRoot.ToLower) then
  begin
    AError := 'outside-repo';
    Exit;
  end;
  AAbsolute := LAbs;
  Result := True;
end;

function TGitFacade.GetStatus(out AItems: TArray<TGitStatusItem>;
  out AError: string): Boolean;
var
  LRoot: string;
  LRun: TGitCaptureResult;
begin
  SetLength(AItems, 0);
  AError := '';
  Result := False;
  if _ResolveGitExe = '' then
  begin
    AError := 'git-not-found';
    Exit;
  end;
  LRoot := _ResolveRepoRoot;
  if (LRoot = '') or not TDirectory.Exists(LRoot) then
  begin
    AError := 'not-a-repo';
    Exit;
  end;
  LRun := _RunCapture(['status', '--porcelain=v1', '-z'], LRoot);
  if LRun.TimedOut then begin AError := 'timeout'; Exit; end;
  if LRun.OutputTooLarge then begin AError := 'output-too-large'; Exit; end;
  if LRun.ExitCode <> 0 then
  begin
    if Pos('not a git repository', LowerCase(LRun.StdErr)) > 0 then
      AError := 'not-a-repo'
    else
      AError := 'git-error';
    Exit;
  end;
  AItems := _ParseStatusPorcelainZ(LRun.StdOut);
  Result := True;
end;

function TGitFacade.GetCurrentBranch(out ABranch: string;
  out ADetached: Boolean; out AError: string): Boolean;
var
  LRoot: string;
  LRun: TGitCaptureResult;
  LName: string;
begin
  ABranch := '';
  ADetached := False;
  AError := '';
  Result := False;
  if _ResolveGitExe = '' then
  begin
    AError := 'git-not-found';
    Exit;
  end;
  LRoot := _ResolveRepoRoot;
  if (LRoot = '') or not TDirectory.Exists(LRoot) then
  begin
    AError := 'not-a-repo';
    Exit;
  end;
  LRun := _RunCapture(['rev-parse', '--abbrev-ref', 'HEAD'], LRoot);
  if LRun.TimedOut then begin AError := 'timeout'; Exit; end;
  if LRun.ExitCode <> 0 then
  begin
    if Pos('not a git repository', LowerCase(LRun.StdErr)) > 0 then
      AError := 'not-a-repo'
    else
      AError := 'git-error';
    Exit;
  end;
  LName := Trim(LRun.StdOut);
  if SameText(LName, 'HEAD') then
  begin
    // Detached HEAD — substitute the commit hash.
    LRun := _RunCapture(['rev-parse', 'HEAD'], LRoot);
    if LRun.TimedOut then begin AError := 'timeout'; Exit; end;
    if LRun.ExitCode <> 0 then begin AError := 'git-error'; Exit; end;
    ABranch := Trim(LRun.StdOut);
    ADetached := True;
  end
  else
    ABranch := LName;
  Result := True;
end;

function TGitFacade.GetLog(const ACount: Integer;
  out ACommits: TArray<TGitLogEntry>; out AError: string): Boolean;
var
  LRoot: string;
  LRun: TGitCaptureResult;
  LClamped: Integer;
begin
  SetLength(ACommits, 0);
  AError := '';
  Result := False;
  if ACount <= 0 then
  begin
    AError := 'invalid-count';
    Exit;
  end;
  if _ResolveGitExe = '' then
  begin
    AError := 'git-not-found';
    Exit;
  end;
  LRoot := _ResolveRepoRoot;
  if (LRoot = '') or not TDirectory.Exists(LRoot) then
  begin
    AError := 'not-a-repo';
    Exit;
  end;
  LClamped := _ClampCount(ACount);
  LRun := _RunCapture(['log', '-n', IntToStr(LClamped),
    '--date=iso-strict',
    '--pretty=format:%H' + #9 + '%an' + #9 + '%ad' + #9 + '%s'], LRoot);
  if LRun.TimedOut then begin AError := 'timeout'; Exit; end;
  if LRun.OutputTooLarge then begin AError := 'output-too-large'; Exit; end;
  if LRun.ExitCode <> 0 then
  begin
    if Pos('not a git repository', LowerCase(LRun.StdErr)) > 0 then
      AError := 'not-a-repo'
    else
      AError := 'git-error';
    Exit;
  end;
  ACommits := _ParseLogOutput(LRun.StdOut);
  Result := True;
end;

function TGitFacade.GetFileDiff(const AFilePath: string; out APatch: string;
  out AError: string): Boolean;
var
  LRoot: string;
  LAbs: string;
  LRun: TGitCaptureResult;
begin
  APatch := '';
  AError := '';
  Result := False;
  if _ResolveGitExe = '' then
  begin
    AError := 'git-not-found';
    Exit;
  end;
  LRoot := _ResolveRepoRoot;
  if (LRoot = '') or not TDirectory.Exists(LRoot) then
  begin
    AError := 'not-a-repo';
    Exit;
  end;
  if not _NormalizePath(LRoot, AFilePath, LAbs, AError) then
    Exit;
  if not TFile.Exists(LAbs) then
  begin
    AError := 'file-not-found';
    Exit;
  end;
  LRun := _RunCapture(['diff', '--no-color', '--', LAbs], LRoot);
  if LRun.TimedOut then begin AError := 'timeout'; Exit; end;
  if LRun.OutputTooLarge then begin AError := 'output-too-large'; Exit; end;
  if LRun.ExitCode <> 0 then
  begin
    if Pos('not a git repository', LowerCase(LRun.StdErr)) > 0 then
      AError := 'not-a-repo'
    else
      AError := 'git-error';
    Exit;
  end;
  APatch := LRun.StdOut;
  Result := True;
end;

function TGitFacade.GetFileAtHead(const AFilePath: string;
  out AContent: string; out AError: string): Boolean;
var
  LRoot: string;
  LAbs: string;
  LRel: string;
  LRun: TGitCaptureResult;
  LStdErr: string;
begin
  AContent := '';
  AError := '';
  Result := False;
  if _ResolveGitExe = '' then
  begin
    AError := 'git-not-found';
    Exit;
  end;
  LRoot := _ResolveRepoRoot;
  if (LRoot = '') or not TDirectory.Exists(LRoot) then
  begin
    AError := 'not-a-repo';
    Exit;
  end;
  // The file need NOT exist on disk (it may have been deleted); it only has to
  // resolve INSIDE the repo root, which _NormalizePath enforces.
  if not _NormalizePath(LRoot, AFilePath, LAbs, AError) then
    Exit;
  // `<rev>:./<path>` is resolved relative to the CWD, so a project root that is
  // a SUBDIRECTORY of the git top-level still works (no rev-parse --show-toplevel
  // round-trip needed).
  LRel := LAbs.Substring(
    Length(IncludeTrailingPathDelimiter(TPath.GetFullPath(LRoot))));
  LRel := StringReplace(LRel, '\', '/', [rfReplaceAll]);
  LRun := _RunCapture(['show', 'HEAD:./' + LRel], LRoot);
  if LRun.TimedOut then begin AError := 'timeout'; Exit; end;
  if LRun.OutputTooLarge then begin AError := 'output-too-large'; Exit; end;
  if LRun.ExitCode <> 0 then
  begin
    LStdErr := LowerCase(LRun.StdErr);
    if Pos('not a git repository', LStdErr) > 0 then
      AError := 'not-a-repo'
    else if (Pos('does not exist', LStdErr) > 0)
      or (Pos('exists on disk, but not in', LStdErr) > 0)
      or (Pos('invalid object name', LStdErr) > 0) then
      AError := 'not-in-head'
    else
      AError := 'git-error';
    Exit;
  end;
  // Decode the COMMITTED BYTES the way the IDE loads a unit (BOM -> UTF-8 ->
  // cp1252), NOT blindly as UTF-8: a legacy ANSI `.pas` would otherwise diff as
  // fully rewritten against the correctly-decoded live buffer. The BOM is
  // stripped inside DecodeSourceBytes, so line 1 never shows a phantom change.
  AContent := DecodeSourceBytes(LRun.StdOutBytes);
  Result := True;
end;

end.
