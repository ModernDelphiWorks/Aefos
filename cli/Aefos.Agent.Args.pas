unit Aefos.Agent.Args;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  Aefos Agent CLI - command-line grammar (pure, RTL-only, headless-testable).

  The CLI is the agent shell for local models: the IDE dispatches it exactly
  like any other executor (claude/codex), so the grammar mirrors theirs -
  positional prompt + --flags. Parsing is a pure function over an argv array
  so the pure suite asserts it without spawning a process.
}

interface

uses
  {$IFDEF FPC}
  SysUtils;
  {$ELSE}
  System.SysUtils;
  {$ENDIF}

type
  // Mirrors the chat's AI Flow permission combo. Parsed here; enforcement
  // arrives with the tool loop (Phase C) - chat-only turns ignore it.
  TAgentPermissionMode = (pmAsk, pmAutoEdits, pmAutoAll);

  // Harness P0-1 catalog contract: auto picks compact when the catalog is
  // large (CCompactAutoThreshold), full ships every schema, compact forces
  // the GetToolSchema protocol regardless of size.
  TAgentCatalogMode = (cmAuto, cmFull, cmCompact);

  TAgentArgs = record
    Prompt: string;          // positional tokens joined with single spaces
    Model: string;           // --model <id> / -m <id>
    Endpoint: string;        // --endpoint <url>; '' = transport default
    SessionId: string;       // --resume <id>; '' = start a new session
    McpPipe: string;         // --mcp-pipe <name> (used from Phase B on)
    PermissionMode: TAgentPermissionMode; // --permission-mode <mode>
    PrintMode: Boolean;      // --print / -p (non-interactive; v1 default anyway)
    TurnTimeoutSec: Integer; // --turn-timeout <sec>; 0 = default (15 min)
    SessionsRoot: string;    // --sessions-root <dir>; '' = %APPDATA%\Aefos\sessions
    McpProbe: Boolean;       // --mcp-probe: handshake + tool count, then exit
    CatalogMode: TAgentCatalogMode; // --tool-catalog auto|full|compact
    NoOrientation: Boolean;  // --no-orientation: skip the environment snapshot
    CtxTokens: Integer;      // --ctx <tokens>; 0 = probe /api/show, <0 never set
    MaxIterations: Integer;  // --max-iterations <n>; 0 = loop default
    ShowHelp: Boolean;       // --help / -h
    ShowVersion: Boolean;    // --version / -v
    Error: string;           // non-empty => parse failed; message is user-facing

    // Parses the argv tail (ParamStr(1..N)) into this record. Never raises; a bad
    // input lands in Result.Error as a plain-English one-liner. The factory owns
    // the parse that only exists to build the record.
    class function Parse(const AArgv: TArray<string>): TAgentArgs; static;

    // Session ids reach the filesystem (sessions\<id>.json), so only a safe
    // charset is accepted: letters, digits, dash. Anything else is rejected
    // before it can traverse paths.
    class function IsValidSessionId(const AId: string): Boolean; static;
  end;

implementation

class function TAgentArgs.IsValidSessionId(const AId: string): Boolean;
var
  LIndex: Integer;
begin
  Result := AId <> '';
  for LIndex := 1 to Length(AId) do
    if not CharInSet(AId[LIndex], ['A'..'Z', 'a'..'z', '0'..'9', '-']) then
      Exit(False);
end;

class function TAgentArgs.Parse(const AArgv: TArray<string>): TAgentArgs;
var
  LIndex: Integer;
  LArg, LValue: string;
  LNeedsValue, LEndOfOpts: Boolean;
begin
  Result := Default(TAgentArgs);
  LEndOfOpts := False;
  LIndex := 0;
  while LIndex <= High(AArgv) do
  begin
    LArg := AArgv[LIndex];
    // After a literal `--`, everything is prompt text (review S6): the chat
    // passes the user message as one positional arg, and a message starting
    // with `-` (e.g. "-1 means EOF?") must not be parsed as a flag.
    if LEndOfOpts then
    begin
      if Result.Prompt <> '' then
        Result.Prompt := Result.Prompt + ' ';
      Result.Prompt := Result.Prompt + LArg;
      Inc(LIndex);
      Continue;
    end;
    if LArg = '--' then
    begin
      LEndOfOpts := True;
      Inc(LIndex);
      Continue;
    end;
    LNeedsValue := (LArg = '--model') or (LArg = '-m') or
      (LArg = '--endpoint') or (LArg = '--resume') or
      (LArg = '--mcp-pipe') or (LArg = '--permission-mode') or
      (LArg = '--turn-timeout') or (LArg = '--sessions-root') or
      (LArg = '--tool-catalog') or (LArg = '--ctx') or
      (LArg = '--max-iterations');
    if LNeedsValue then
    begin
      if LIndex >= High(AArgv) then
      begin
        Result.Error := 'Missing value after ' + LArg + '.';
        Exit;
      end;
      Inc(LIndex);
      LValue := AArgv[LIndex];
      if (LArg = '--model') or (LArg = '-m') then
        Result.Model := LValue
      else if LArg = '--endpoint' then
        Result.Endpoint := LValue
      else if LArg = '--resume' then
      begin
        if not TAgentArgs.IsValidSessionId(LValue) then
        begin
          Result.Error := 'Invalid session id "' + LValue +
            '" - letters, digits and dashes only.';
          Exit;
        end;
        Result.SessionId := LValue;
      end
      else if LArg = '--mcp-pipe' then
        Result.McpPipe := LValue
      else if LArg = '--turn-timeout' then
      begin
        Result.TurnTimeoutSec := StrToIntDef(LValue, -1);
        // Reject negative AND clamp absurd values (review L1): the dpr computes
        // Cardinal(sec)*1000, which would wrap for huge inputs into a near-zero
        // timeout. 24h is a generous ceiling.
        if Result.TurnTimeoutSec < 0 then
        begin
          Result.Error := 'Invalid --turn-timeout "' + LValue +
            '" - whole seconds expected.';
          Exit;
        end;
        if Result.TurnTimeoutSec > 86400 then
          Result.TurnTimeoutSec := 86400;
      end
      else if LArg = '--sessions-root' then
        Result.SessionsRoot := LValue
      else if LArg = '--tool-catalog' then
      begin
        if LValue = 'auto' then
          Result.CatalogMode := cmAuto
        else if LValue = 'full' then
          Result.CatalogMode := cmFull
        else if LValue = 'compact' then
          Result.CatalogMode := cmCompact
        else
        begin
          Result.Error := 'Unknown tool-catalog mode "' + LValue +
            '" - use auto, full or compact.';
          Exit;
        end;
      end
      else if LArg = '--ctx' then
      begin
        Result.CtxTokens := StrToIntDef(LValue, -1);
        if Result.CtxTokens < 0 then
        begin
          Result.Error := 'Invalid --ctx "' + LValue +
            '" - whole tokens expected.';
          Exit;
        end;
      end
      else if LArg = '--max-iterations' then
      begin
        Result.MaxIterations := StrToIntDef(LValue, -1);
        if (Result.MaxIterations < 0) or (Result.MaxIterations > 500) then
        begin
          Result.Error := 'Invalid --max-iterations "' + LValue +
            '" - 1..500 expected.';
          Exit;
        end;
      end
      else // --permission-mode
      begin
        if LValue = 'ask' then
          Result.PermissionMode := pmAsk
        else if LValue = 'auto-edits' then
          Result.PermissionMode := pmAutoEdits
        else if LValue = 'auto-all' then
          Result.PermissionMode := pmAutoAll
        else
        begin
          Result.Error := 'Unknown permission mode "' + LValue +
            '" - use ask, auto-edits or auto-all.';
          Exit;
        end;
      end;
    end
    else if LArg = '--mcp-probe' then
      Result.McpProbe := True
    else if LArg = '--no-orientation' then
      Result.NoOrientation := True
    else if (LArg = '--print') or (LArg = '-p') then
      Result.PrintMode := True
    else if (LArg = '--help') or (LArg = '-h') then
      Result.ShowHelp := True
    else if (LArg = '--version') or (LArg = '-v') then
      Result.ShowVersion := True
    else if (LArg <> '') and (LArg[1] = '-') then
    begin
      Result.Error := 'Unknown option ' + LArg + '. Try --help.';
      Exit;
    end
    else
    begin
      // Positional token: part of the prompt. Multiple tokens join with a
      // single space so unquoted prompts still read naturally.
      if Result.Prompt <> '' then
        Result.Prompt := Result.Prompt + ' ';
      Result.Prompt := Result.Prompt + LArg;
    end;
    Inc(LIndex);
  end;
end;

end.
