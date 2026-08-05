unit Aefos.Chat.Core.VisualBroadcast;

{$IFDEF FPC}{$mode delphiunicode}{$H+}{$ENDIF}

{
  Visual Scanner -- the thing between the tool layer and the panel.

  The tool layer reports FACTS ("a capture completed", "the operation failed").
  It does not know an animation exists, and it must not: the moment a tool has
  to remember to also drive a UI, the UI starts lying whenever someone adds a
  tool and forgets. So the facts come here, this owns the state machines, and
  the panel is told only when something actually changed.

  Why this exists rather than the panel holding sessions itself:

  * A session outlives any single call. It starts when the agent captures, and
    it is still alive several tool calls later when the comparison lands. Nothing
    in the tool path is around for that whole span.
  * A refused event must NOT reach the panel. The machine already rejects an
    event that does not belong (an "operation started" while still capturing),
    and pushing anyway would paint a convincing animation over a bug -- which is
    the exact failure the state machine was written to prevent.
  * The push has to happen once per real change. Ten events that move the
    machine produce ten updates of ONE card; an event that changes nothing
    produces no push at all.

  Purity: no ToolsAPI, no VCL/LCL, no I/O. The panel arrives as a callback, so a
  headless test drives the whole thing and asserts exactly what would have been
  sent. ASCII only: no BOM needed.
}

interface

uses
  {$IFDEF FPC}
  SysUtils,
  {$ELSE}
  System.SysUtils,
  {$ENDIF}
  Aefos.Chat.Core.VisualSession;

type
  { How a payload reaches the surface. A callback rather than an interface: the
    only implementation is one line (_Run('window.dsScanner && ...')), and a
    test wants to capture it, not implement an interface to do so. }
  {$IFDEF FPC}
  TAefosVisualPush = procedure(const APayloadJson: string) of object;
  {$ELSE}
  TAefosVisualPush = reference to procedure(const APayloadJson: string);
  {$ENDIF}

  { Owns the live sessions and decides when the panel hears about them. }
  TAefosVisualBroadcast = class sealed
  private
    FSessions: TArray<TAefosVisualSession>;
    FPush: TAefosVisualPush;
    function _Find(const ASessionId: string): TAefosVisualSession;
    function _Adopt(const ASessionId: string): TAefosVisualSession;
  public
    constructor Create(const APush: TAefosVisualPush);
    destructor Destroy; override;
    { Applies one reported fact to the named session, creating it on first
      sight, and pushes the new payload IF the machine moved.

      Returns False with a kebab-case reason when the event did not belong --
      and in that case nothing is pushed, because a UI that redraws on a refused
      event is a UI that hides the bug that produced it. }
    function Report(const ASessionId: string; const AEvent: TAefosVisualEvent;
      out AReason: string): Boolean;
    { Drops a finished session. Terminal sessions are NOT dropped automatically:
      the card stays on screen after the run ends -- that is the whole point of
      showing what happened -- so forgetting is the caller's decision, made when
      the conversation is cleared. }
    procedure Forget(const ASessionId: string);
    procedure ForgetAll;
    { Ends every session that is still live and returns how many that was.

      Called when the chat turn ends. Until this existed a card could outlive the
      conversation it belonged to: the agent read the control tree, decided the
      answer without operating the app, and replied -- leaving the card with four
      pending steps and a scan line sweeping over a screenshot of a program
      nobody was touching. The steps had no way to know the turn was over,
      because the only thing that moves them is a tool call, and no more were
      coming.

      Each closed session is FORGOTTEN as well as ended. That is deliberate: the
      card is keyed by the target window, so leaving a terminal session in the
      map would make the machine refuse the next turn's work on that same window
      -- the user asks for one more thing, and no card appears at all. The cost
      is that a closed card is not repainted after a WebView reload, which is the
      cheaper of the two losses. }
    function CloseLive: Integer;
    { How many sessions are being tracked. Exposed so a test can prove Forget
      actually forgets rather than merely appearing to. }
    function Count: Integer;
    { Where a session currently stands, or vsIdle when there is no such session
      yet. vsIdle is the right answer for "not started": it is exactly the state
      a session begins in, so a caller deciding what a tool MEANS gets the same
      answer whether the first call is about to create the session or already
      did. Exposed because the tool->event translation is a pure function of the
      state and has to be told it. }
    function StateOf(const ASessionId: string): TAefosVisualState;
    { The current payload for a session, or '' when there is no such session.
      Used to repaint after the panel reloads (a WebView2 navigation wipes the
      DOM; the sessions live out here and survive it). }
    function PayloadFor(const ASessionId: string): string;
  end;

implementation

constructor TAefosVisualBroadcast.Create(const APush: TAefosVisualPush);
begin
  inherited Create;
  FPush := APush;
end;

destructor TAefosVisualBroadcast.Destroy;
begin
  ForgetAll;
  inherited Destroy;
end;

function TAefosVisualBroadcast._Find(
  const ASessionId: string): TAefosVisualSession;
var
  LScan: Integer;
begin
  Result := nil;
  for LScan := 0 to High(FSessions) do
    if FSessions[LScan].SessionId = ASessionId then
      Exit(FSessions[LScan]);
end;

function TAefosVisualBroadcast._Adopt(
  const ASessionId: string): TAefosVisualSession;
begin
  Result := _Find(ASessionId);
  if Result <> nil then
    Exit;
  Result := TAefosVisualSession.Create(ASessionId);
  SetLength(FSessions, Length(FSessions) + 1);
  FSessions[High(FSessions)] := Result;
end;

function TAefosVisualBroadcast.Report(const ASessionId: string;
  const AEvent: TAefosVisualEvent; out AReason: string): Boolean;
var
  LSession: TAefosVisualSession;
begin
  AReason := '';
  if Trim(ASessionId) = '' then
  begin
    // A session with no id cannot be addressed, updated or forgotten -- and the
    // panel keys its card by exactly this. Refusing here beats minting an
    // anonymous card nobody can ever update again.
    AReason := 'visual-no-session-id';
    Exit(False);
  end;
  LSession := _Adopt(ASessionId);
  Result := LSession.Apply(AEvent, AReason);
  if not Result then
    Exit;
  // ONLY on a real move. The machine returning True is the single condition --
  // this unit never second-guesses it, and never pushes on its own schedule.
  if Assigned(FPush) then
    FPush(LSession.ToJson);
end;

procedure TAefosVisualBroadcast.Forget(const ASessionId: string);
var
  LScan: Integer;
  LLast: Integer;
begin
  LLast := High(FSessions);
  for LScan := 0 to LLast do
    if FSessions[LScan].SessionId = ASessionId then
    begin
      FSessions[LScan].Free;
      // Order does not matter to anyone here, so close the hole with the tail
      // instead of shifting the whole array.
      FSessions[LScan] := FSessions[LLast];
      SetLength(FSessions, LLast);
      Exit;
    end;
end;

function TAefosVisualBroadcast.CloseLive: Integer;
var
  LScan: Integer;
  LEvent: TAefosVisualEvent;
  LReason: string;
  LIds: TArray<string>;
begin
  Result := 0;
  LIds := nil;
  // Collect first, mutate after: Report goes through _Adopt and Forget rewrites
  // the array, so walking it while ending sessions would skip one.
  for LScan := 0 to High(FSessions) do
    if not FSessions[LScan].IsTerminal then
    begin
      SetLength(LIds, Length(LIds) + 1);
      LIds[High(LIds)] := FSessions[LScan].SessionId;
    end;
  LEvent := Default(TAefosVisualEvent);
  LEvent.Kind := veSessionAbandoned;
  for LScan := 0 to High(LIds) do
  begin
    // Through Report, not straight at the session, so the final payload reaches
    // the panel by the one path every other move uses. A card that ends without
    // being repainted still shows its old, live-looking self.
    if Report(LIds[LScan], LEvent, LReason) then
      Inc(Result);
    Forget(LIds[LScan]);
  end;
end;

procedure TAefosVisualBroadcast.ForgetAll;
var
  LScan: Integer;
begin
  for LScan := 0 to High(FSessions) do
    FSessions[LScan].Free;
  SetLength(FSessions, 0);
end;

function TAefosVisualBroadcast.Count: Integer;
begin
  Result := Length(FSessions);
end;

function TAefosVisualBroadcast.StateOf(
  const ASessionId: string): TAefosVisualState;
var
  LSession: TAefosVisualSession;
begin
  LSession := _Find(ASessionId);
  if LSession = nil then
    Result := vsIdle
  else
    Result := LSession.State;
end;

function TAefosVisualBroadcast.PayloadFor(const ASessionId: string): string;
var
  LSession: TAefosVisualSession;
begin
  LSession := _Find(ASessionId);
  if LSession = nil then
    Result := ''
  else
    Result := LSession.ToJson;
end;

end.
