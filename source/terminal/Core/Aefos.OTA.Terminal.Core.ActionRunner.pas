unit Aefos.OTA.Terminal.Core.ActionRunner;

{$IFDEF FPC}{$mode delphi}{$H+}{$ENDIF}

interface

uses
  {$IFDEF FPC}
  SysUtils, Generics.Collections,
  {$ELSE}
  System.SysUtils, System.Generics.Collections,
  {$ENDIF}
  Aefos.OTA.Terminal.Core.Actions, Aefos.OTA.Terminal.Core.ActionPlaceholders;

type
  /// <summary>
  /// Abstraction over the active terminal's input channel. Implemented by
  /// TTerminalHost in production and by a stub sink in tests, keeping the
  /// runner free of any VCL or PTY dependency.
  /// </summary>
  ITerminalInput = interface
    ['{6F2A1C84-3D9E-4B57-A0F1-7C8E2D5B9A40}']
    /// <summary>True when a live terminal session can receive input.</summary>
    function IsActive: Boolean;
    /// <summary>Writes AText verbatim into the terminal input stream.</summary>
    procedure SendInput(const AText: string);
  end;

  /// <summary>Outcome categories of an action run.</summary>
  TActionRunOutcome = (aroSuccess, aroNoActiveSession, aroCancelled,
    aroInvalidAction);

  /// <summary>
  /// Result of TActionRunner.RunAction — a non-fatal value, never an exception.
  /// </summary>
  TActionRunResult = record
    /// <summary>Categorized outcome of the run.</summary>
    Outcome: TActionRunOutcome;
    /// <summary>Human-readable description of the outcome.</summary>
    Message: string;
    /// <summary>Number of script lines sent to the terminal.</summary>
    LinesSent: Integer;
    /// <summary>True when the action ran and sent its script lines.</summary>
    function IsSuccess: Boolean;
  end;

  /// <summary>
  /// Confirmation gate invoked before a ConfirmBeforeRun action runs.
  /// Returning False cancels the run; nothing is sent.
  /// </summary>
  // FPC 3.2.2 has no anonymous methods, so the port gets an `of object`
  // method-pointer twin (the sweep-D convention shared by the chat dispatcher
  // callbacks). The Lazarus Action Center supplies an instance method.
  {$IFDEF FPC}
  TActionConfirmFunc = function(
    const AAction: TTerminalAction): Boolean of object;
  {$ELSE}
  TActionConfirmFunc = reference to function(
    const AAction: TTerminalAction): Boolean;
  {$ENDIF}

  /// <summary>
  /// Placeholder resolver invoked when an action's script lines reference one
  /// or more <c>${identifier}</c> tokens (ESP-030 / ADR-030-02). The resolver
  /// receives the action and the deduplicated list of placeholder names; on
  /// True it must allocate a fresh dictionary populated with one entry per
  /// name (empty string is a valid value) and return it via AValues. The
  /// runner takes ownership of the dictionary and frees it in a try/finally
  /// regardless of substitution outcome. Returning False cancels the run.
  /// </summary>
  {$IFDEF FPC}
  TActionPlaceholderResolver = function(
    const AAction: TTerminalAction;
    const ANames: TArray<string>;
    out AValues: TDictionary<string, string>): Boolean of object;
  {$ELSE}
  TActionPlaceholderResolver = reference to function(
    const AAction: TTerminalAction;
    const ANames: TArray<string>;
    out AValues: TDictionary<string, string>): Boolean;
  {$ENDIF}

  /// <summary>
  /// Runs a terminal action by injecting its script lines into the active
  /// terminal. Pure service logic — no VCL, no direct PTY access.
  /// </summary>
  TActionRunner = class
  private
    function _SendSubstitutedLines(const ALines: TArray<string>;
      const AInput: ITerminalInput): Integer;
  public
    /// <summary>
    /// Runs AAction against AInput, sending each non-empty script line in
    /// order and CR-terminated. Honors AAction.ConfirmBeforeRun via AConfirm.
    /// When the script lines contain <c>${identifier}</c> placeholders the
    /// runner delegates value collection to AResolve (ADR-030-02); when no
    /// placeholders are present the resolver is not invoked. Returns a
    /// non-fatal result; never raises.
    /// </summary>
    function RunAction(const AAction: TTerminalAction;
      const AInput: ITerminalInput;
      const AConfirm: TActionConfirmFunc;
      const AResolve: TActionPlaceholderResolver = nil): TActionRunResult;
  end;

implementation

const
  /// <summary>Carriage return appended to each script line sent.</summary>
  SCRIPT_LINE_TERMINATOR = #13;

{ TActionRunResult }

function TActionRunResult.IsSuccess: Boolean;
begin
  Result := Outcome = aroSuccess;
end;

{ TActionRunner }

function TActionRunner._SendSubstitutedLines(const ALines: TArray<string>;
  const AInput: ITerminalInput): Integer;
var
  LLine: string;
begin
  Result := 0;
  for LLine in ALines do
    if LLine.Trim <> '' then
    begin
      AInput.SendInput(LLine + SCRIPT_LINE_TERMINATOR);
      Inc(Result);
    end;
end;

function TActionRunner.RunAction(const AAction: TTerminalAction;
  const AInput: ITerminalInput;
  const AConfirm: TActionConfirmFunc;
  const AResolve: TActionPlaceholderResolver): TActionRunResult;
var
  LNames: TArray<string>;
  LValues: TDictionary<string, string>;
  LLines: TArray<string>;
begin
  Result.Outcome := aroSuccess;
  Result.Message := '';
  Result.LinesSent := 0;

  if not Assigned(AAction) or not AAction.IsValid then
  begin
    Result.Outcome := aroInvalidAction;
    Result.Message := 'The action is empty or invalid.';
    Exit;
  end;

  if not Assigned(AInput) or not AInput.IsActive then
  begin
    Result.Outcome := aroNoActiveSession;
    Result.Message := 'No active terminal session to run the action in.';
    Exit;
  end;

  if AAction.ConfirmBeforeRun then
    if not Assigned(AConfirm) or not AConfirm(AAction) then
    begin
      Result.Outcome := aroCancelled;
      Result.Message := 'The action run was cancelled.';
      Exit;
    end;

  LNames := TActionPlaceholders.Scan(AAction.ScriptLines);
  if Length(LNames) > 0 then
  begin
    if not Assigned(AResolve) then
    begin
      Result.Outcome := aroCancelled;
      Result.Message := 'The action has placeholders that need a resolver.';
      Exit;
    end;
    LValues := nil;
    try
      if not AResolve(AAction, LNames, LValues) then
      begin
        Result.Outcome := aroCancelled;
        Result.Message := 'The action run was cancelled.';
        Exit;
      end;
      LLines := TActionPlaceholders.Substitute(AAction.ScriptLines, LValues);
    finally
      LValues.Free;
    end;
  end
  else
    LLines := AAction.ScriptLines;

  Result.LinesSent := _SendSubstitutedLines(LLines, AInput);
  Result.Message := Format('%d line(s) sent to the terminal.',
    [Result.LinesSent]);
end;

end.


