unit Aefos.OTA.Chat.Core.Dispatcher.Decode;

{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  Pure decode / transform seam for the CLI dispatcher (ESP-004, Epic 3/3
  Demand 2/3 — ADR-261).

  This unit holds the deterministic, branch-rich, zero-process transforms that
  used to live inside Core.CLIDispatcher: the streaming UTF-8 carry decoder,
  the defensive ANSI CSI strip, the command-line build, the env-block build
  (incl. NO_COLOR enforcement), JSON escaping, the prompt summary, and the
  per-executor log-file-name derivation.

  Everything here is RTL-only and side-effect-free (modulo reading the current
  process environment for the env block). No `uses ToolsAPI`/`Vcl.`/`FMX.`, no
  process-spawn API (CreateProcess/ShellExecute/WinExec). The IProcessRunner
  seam (Dispatcher.Types) emits *raw* bytes so the real UTF-8 carry decode +
  ANSI strip run here, on the coverage-gated side — a fake runner exercises the
  genuine transform (BR-4 / ADR-261). The transforms were lifted verbatim
  (byte-for-byte behaviour preserved, C-2); the original instance methods on
  TCLIDispatcherReadThread / TCLIDispatcherRun became the TStreamDecoder /
  TAnsiStripper classes and the free functions below.

  Portability (Aefos -> Lazarus, external-CLI slice): the Lazarus chat dispatches
  external CLIs through the SAME transport, so BuildEnvBlock is no longer
  Delphi-only -- it is re-based on the W entry points and built on both. The ANSI
  CSI strip stays Delphi-only (regex; see the uses-clause note): the child env
  still carries NO_COLOR=1, which is what actually stops a well-behaved CLI
  colouring, and the strip is only the defensive second line.

  Constraints:
    - Windows only.
}

interface

uses
  SysUtils,
  Generics.Collections,
{$IFNDEF FPC}
  // The defensive ANSI CSI strip (TAnsiStripper / TCliText.StripAnsi) is
  // dispatcher-only and lives behind System.RegularExpressions on Delphi. FPC
  // 3.2.2 has no System.RegularExpressions (its regex engine is the RegExpr
  // unit, TRegExpr); rather than pull it in for a surface no Milestone-1 FPC
  // code exercises, the ANSI-strip surface is IFDEF'd out of the FPC build. It
  // returns with the FPC dispatcher (Phase D), re-based on RegExpr. Everything
  // Config needs here (TCliText.EscapeJsonString, command line, env block, log
  // naming, prompt summary) is regex-free and compiles on both.
  System.RegularExpressions,
{$ENDIF}
  Aefos.OTA.Chat.Core.Dispatcher.Types;

const
  // CSI escape sequence pattern (ESC [ ... final byte). Lifted verbatim from
  // the pre-refactor Core.CLIDispatcher.
  ANSI_CSI_PATTERN = #$1B + '\[[0-?]*[ -/]*[@-~]';
  PROMPT_SUMMARY_MAX_LEN = 200;

type
  // FPC 3.2.2's TStringBuilder is ALWAYS the Ansi one regardless of the string
  // mode, so appending UTF-16 text to it round-trips through the ANSI codepage
  // and mangles anything non-ASCII. TUnicodeStringBuilder is the UTF-16 twin;
  // on Delphi TStringBuilder already is that. Every builder in this unit handles
  // real user text (env values, a prompt summary), so all of them use this alias.
{$IFDEF FPC}
  TUnicodeTextBuilder = TUnicodeStringBuilder;
{$ELSE}
  TUnicodeTextBuilder = TStringBuilder;
{$ENDIF}
  // Streaming UTF-8 decoder that holds any incomplete trailing multi-byte
  // sequence as carry between calls, so a code point split across two raw
  // chunk boundaries decodes correctly (AC-02). One instance per stream; not
  // thread-safe (each stream is fed from a single read thread, as before).
  TStreamDecoder = class
  private
    FCarry: TBytes;
    function _ClassifyUtf8LeadByte(const AByte: Byte): Integer;
    function _FindUtf8CompleteBoundary(const ABytes: TBytes;
      const ALength: Integer): Integer;
    function _BuildCombinedBuffer(const ABuffer: array of Byte;
      const ACount: Integer): TBytes;
    function _DecodeWithCarry(const ABytes: TBytes;
      const ALength: Integer): string;
  public
    constructor Create;
    // Decodes the first ACount bytes of ABytes, prepending any carry from the
    // previous call. The incomplete trailing sequence (if any) is retained as
    // carry. Returns '' when every byte was carried.
    function Decode(const ABytes: array of Byte; const ACount: Integer): string;
    // Decodes the remaining carry at end-of-stream (best effort).
    function Flush: string;
  end;

{$IFNDEF FPC}
  // Defensive ANSI CSI strip with a regex compiled once per instance (matches
  // the pre-refactor per-run FAnsiRegex). One-shot StripAnsi below is the pure
  // headless-test convenience. Delphi-only: see the uses-clause note on the
  // FPC ANSI-strip exclusion.
  TAnsiStripper = class
  private
    FRegex: TRegEx;
  public
    constructor Create;
    function Strip(const AInput: string): string;
  end;
{$ENDIF}

type
  // CLI text transforms: ANSI strip, JSON-Lines escaping, prompt summary.
  TCliText = class sealed
  public
{$IFNDEF FPC}
    // One-shot ANSI CSI strip (AC-03). Equivalent to TAnsiStripper.Strip.
    // Delphi-only (dispatcher surface); excluded from the FPC build.
    class function StripAnsi(const AInput: string): string; static;
{$ENDIF}
    // JSON-escapes a string for the JSON-Lines session log.
    class function EscapeJsonString(const AInput: string): string; static;
    // Truncates a long prompt to a bounded summary for the spawn log line.
    class function BuildPromptSummary(const APrompt: string): string; static;
  end;

  // Child-process invocation assembly: the command line and the environment block.
  TCliCommandLine = class sealed
  public
    // Builds the child command line: "executor" "arg0" .. "argN" "prompt"
    // (executor -> Args -> Prompt). Byte-identical to the pre-refactor
    // _BuildCommandLine (AC-04).
    class function Build(const ARequest: TDispatchRequest): string; static;
    // Ensures NO_COLOR=1 is present among the env overrides: injected when absent,
    // left untouched when already supplied (case-insensitive). Caller overrides for
    // other keys are preserved (AC-05).
    class procedure EnsureNoColorOverride(
      var AOverrides: TArray<TPair<string, string>>); static;
    // Serializes the full child environment block (current process env merged
    // with the overrides; overrides win) as a #0-delimited, #0#0-terminated
    // string. Reads the live process env via the Win32 GetEnvironmentStringsW
    // API. Now built on BOTH compilers: the Lazarus edition dispatches external
    // CLIs through this same transport and needs the env block for NO_COLOR and
    // for the per-executor API key.
    class function BuildEnvBlock(
      const AOverrides: TArray<TPair<string, string>>): string; static;
  end;

  // Session log-file naming (ADR-085 / C-5).
  TCliLogNaming = class sealed
  public
    // Composes the session log file name from a date string and an executor token
    // (YYYY-MM-DD-<executor>.log). An empty token degrades to the date-only name.
    // Pure.
    class function Compose(const ADate, AExecutor: string): string; static;
  end;

implementation

// Windows is needed by BuildEnvBlock (GetEnvironmentStringsW), which is built on
// both compilers now that the Lazarus chat shares this transport.
uses
{$IFDEF FPC}
  Windows;
{$ELSE}
  Winapi.Windows;
{$ENDIF}

{ TStreamDecoder }

constructor TStreamDecoder.Create;
begin
  inherited Create;
  SetLength(FCarry, 0);
end;

function TStreamDecoder._ClassifyUtf8LeadByte(const AByte: Byte): Integer;
begin
  if (AByte and $E0) = $C0 then
    Result := 2
  else if (AByte and $F0) = $E0 then
    Result := 3
  else if (AByte and $F8) = $F0 then
    Result := 4
  else
    Result := 1;
end;

function TStreamDecoder._FindUtf8CompleteBoundary(const ABytes: TBytes;
  const ALength: Integer): Integer;
var
  LFor: Integer;
  LByte: Byte;
  LSeqLen: Integer;
begin
  Result := ALength;
  LFor := ALength - 1;
  while LFor >= 0 do
  begin
    LByte := ABytes[LFor];
    if (LByte and $80) = 0 then
      Break
    else if (LByte and $C0) = $80 then
      Dec(LFor)
    else
    begin
      LSeqLen := _ClassifyUtf8LeadByte(LByte);
      if (LFor + LSeqLen) > ALength then
        Result := LFor;
      Break;
    end;
  end;
end;

function TStreamDecoder._BuildCombinedBuffer(const ABuffer: array of Byte;
  const ACount: Integer): TBytes;
begin
  if Length(FCarry) > 0 then
  begin
    SetLength(Result, Length(FCarry) + ACount);
    Move(FCarry[0], Result[0], Length(FCarry));
    Move(ABuffer[0], Result[Length(FCarry)], ACount);
    SetLength(FCarry, 0);
  end
  else
  begin
    SetLength(Result, ACount);
    Move(ABuffer[0], Result[0], ACount);
  end;
end;

function TStreamDecoder._DecodeWithCarry(const ABytes: TBytes;
  const ALength: Integer): string;
var
  LCompleteEnd: Integer;
begin
  LCompleteEnd := _FindUtf8CompleteBoundary(ABytes, ALength);
  if LCompleteEnd > 0 then
    Result := TEncoding.UTF8.GetString(ABytes, 0, LCompleteEnd)
  else
    Result := '';
  if LCompleteEnd < ALength then
  begin
    SetLength(FCarry, ALength - LCompleteEnd);
    Move(ABytes[LCompleteEnd], FCarry[0], Length(FCarry));
  end
  else
    SetLength(FCarry, 0);
end;

function TStreamDecoder.Decode(const ABytes: array of Byte;
  const ACount: Integer): string;
var
  LCombined: TBytes;
begin
  LCombined := _BuildCombinedBuffer(ABytes, ACount);
  Result := _DecodeWithCarry(LCombined, Length(LCombined));
end;

function TStreamDecoder.Flush: string;
begin
  if Length(FCarry) > 0 then
  begin
    Result := TEncoding.UTF8.GetString(FCarry);
    SetLength(FCarry, 0);
  end
  else
    Result := '';
end;

{$IFNDEF FPC}
{ TAnsiStripper }

constructor TAnsiStripper.Create;
begin
  inherited Create;
  FRegex := TRegEx.Create(ANSI_CSI_PATTERN);
end;

function TAnsiStripper.Strip(const AInput: string): string;
begin
  Result := FRegex.Replace(AInput, '');
end;

class function TCliText.StripAnsi(const AInput: string): string;
var
  LStripper: TAnsiStripper;
begin
  LStripper := TAnsiStripper.Create;
  try
    Result := LStripper.Strip(AInput);
  finally
    LStripper.Free;
  end;
end;
{$ENDIF}

{ Command line }

// Quote one token for a Windows command line the way CommandLineToArgvW parses
// it back: wrap in quotes, escape embedded quotes as \" and double any run of
// backslashes that immediately precedes a quote (or the closing quote). Without
// this, an arg that itself contains a quote — e.g. Codex's
// `mcp_servers.aefos.args=["-File",...]` TOML override — would be split wrong.
function _QuoteArg(const A: string): string;
const
  // Explicitly a Char (WideChar in both string modes), NOT a 1-char string: the
  // repeat-count Append is Append(Char, Integer), and a string first argument
  // would bind AppendFormat(string, array of const) on FPC instead.
  CBackslash: Char = '\';
var
  LBuilder: TUnicodeTextBuilder;
  LI, LBs: Integer;
begin
  LBuilder := TUnicodeTextBuilder.Create;
  try
    LBuilder.Append(string('"'));
    LI := 1;
    while LI <= Length(A) do
    begin
      LBs := 0;
      while (LI <= Length(A)) and (A[LI] = '\') do
      begin
        Inc(LBs);
        Inc(LI);
      end;
      if LI > Length(A) then
        // trailing backslashes: they precede the closing quote -> double them
        LBuilder.Append(CBackslash, 2 * LBs)
      else if A[LI] = '"' then
      begin
        // backslashes before a quote -> double them, then escape the quote
        LBuilder.Append(CBackslash, 2 * LBs + 1);
        LBuilder.Append(string('"'));
        Inc(LI);
      end
      else
      begin
        LBuilder.Append(CBackslash, LBs); // backslashes not before a quote stay literal
        LBuilder.Append(string(A[LI])); // string() cast: see EscapeJsonString note
        Inc(LI);
      end;
    end;
    LBuilder.Append(string('"'));
    Result := LBuilder.ToString;
  finally
    LBuilder.Free;
  end;
end;

class function TCliCommandLine.Build(const ARequest: TDispatchRequest): string;
var
  LBuilder: TUnicodeTextBuilder;
  LFor: Integer;
begin
  LBuilder := TUnicodeTextBuilder.Create;
  try
    LBuilder.Append(_QuoteArg(ARequest.ExecutorPath));
    for LFor := 0 to High(ARequest.Args) do
      LBuilder.Append(string(' ')).Append(_QuoteArg(ARequest.Args[LFor]));
    LBuilder.Append(string(' ')).Append(_QuoteArg(ARequest.Prompt));
    Result := LBuilder.ToString;
  finally
    LBuilder.Free;
  end;
end;

{ Environment block }

class procedure TCliCommandLine.EnsureNoColorOverride(
  var AOverrides: TArray<TPair<string, string>>);
var
  LFor: Integer;
  LFound: Boolean;
begin
  LFound := False;
  for LFor := 0 to High(AOverrides) do
    if SameText(AOverrides[LFor].Key, 'NO_COLOR') then
    begin
      LFound := True;
      Break;
    end;
  if not LFound then
  begin
    SetLength(AOverrides, Length(AOverrides) + 1);
    AOverrides[High(AOverrides)] := TPair<string, string>.Create('NO_COLOR', '1');
  end;
end;

procedure _LoadCurrentEnvToMap(const AMap: TDictionary<string, string>);
var
  LEnv: PWideChar;
  LCurrent: PWideChar;
  LLine: string;
  LSplitAt: Integer;
begin
  // Explicitly the W entry point on both compilers: this unit is UTF-16
  // (delphiunicode under FPC), and FPC's unqualified GetEnvironmentStrings is
  // the ANSI overload, which would silently mangle a non-ASCII env value on its
  // way to a CREATE_UNICODE_ENVIRONMENT child.
  LEnv := GetEnvironmentStringsW;
  if not Assigned(LEnv) then
    Exit;
  try
    LCurrent := LEnv;
    while LCurrent^ <> #0 do
    begin
      LLine := LCurrent;
      // Hand-split rather than TStringHelper.Split: an env line's VALUE may
      // itself contain '=' (and the block's leading "=C:=C:\..." drive entries
      // start with one), so only the FIRST '=' separates, and a line starting
      // with '=' has an empty name and is skipped -- byte-identical to the
      // Split(['='], 2) + LParts[0] <> '' guard this replaces, without needing
      // the Delphi-only string helper.
      LSplitAt := Pos('=', LLine);
      if LSplitAt > 1 then
        AMap.AddOrSetValue(Copy(LLine, 1, LSplitAt - 1),
          Copy(LLine, LSplitAt + 1, MaxInt));
      Inc(LCurrent, Length(LLine) + 1);
    end;
  finally
    FreeEnvironmentStringsW(LEnv);
  end;
end;

function _SerializeEnvMap(const AMap: TDictionary<string, string>): string;
var
  LResult: TUnicodeTextBuilder;
  LPair: TPair<string, string>;
begin
  LResult := TUnicodeTextBuilder.Create;
  try
    for LPair in AMap do
    begin
      LResult.Append(LPair.Key);
      LResult.Append(string('='));
      LResult.Append(LPair.Value);
      LResult.Append(string(#0));
    end;
    LResult.Append(string(#0));
    Result := LResult.ToString;
  finally
    LResult.Free;
  end;
end;

class function TCliCommandLine.BuildEnvBlock(
  const AOverrides: TArray<TPair<string, string>>): string;
var
  LMap: TDictionary<string, string>;
  LFor: Integer;
begin
  LMap := TDictionary<string, string>.Create;
  try
    _LoadCurrentEnvToMap(LMap);
    for LFor := 0 to High(AOverrides) do
      LMap.AddOrSetValue(AOverrides[LFor].Key, AOverrides[LFor].Value);
    Result := _SerializeEnvMap(LMap);
  finally
    LMap.Free;
  end;
end;

{ JSON / prompt / log name }

class function TCliText.EscapeJsonString(const AInput: string): string;
var
  LBuilder: TUnicodeTextBuilder;
  LFor: Integer;
  LCh: Char;
begin
  LBuilder := TUnicodeTextBuilder.Create(Length(AInput) + 16);
  try
    for LFor := 1 to Length(AInput) do
    begin
      LCh := AInput[LFor];
      case LCh of
        '"':  LBuilder.Append('\"');
        '\':  LBuilder.Append('\\');
        #8:   LBuilder.Append('\b');
        #9:   LBuilder.Append('\t');
        #10:  LBuilder.Append('\n');
        #12:  LBuilder.Append('\f');
        #13:  LBuilder.Append('\r');
      else
        if Ord(LCh) < $20 then
          LBuilder.AppendFormat('\u%.4x', [Ord(LCh)])
        else
          // string() cast: a bare Char is ambiguous under FPC's TStringBuilder
          // (WideChar coerces to the numeric Append overloads too); a 1-char
          // string binds Append(string) on both compilers, byte-identical.
          LBuilder.Append(string(LCh));
      end;
    end;
    Result := LBuilder.ToString;
  finally
    LBuilder.Free;
  end;
end;

class function TCliText.BuildPromptSummary(const APrompt: string): string;
begin
  if Length(APrompt) <= PROMPT_SUMMARY_MAX_LEN then
    Result := APrompt
  else
    Result := Copy(APrompt, 1, PROMPT_SUMMARY_MAX_LEN) +
      Format('... (%d chars total)', [Length(APrompt)]);
end;

class function TCliLogNaming.Compose(const ADate, AExecutor: string): string;
begin
  if AExecutor = '' then
    Result := ADate + '.log'
  else
    Result := ADate + '-' + AExecutor + '.log';
end;

end.
