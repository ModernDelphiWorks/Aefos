unit Aefos.Chat.Core.VisualReporter;

{$IFDEF FPC}{$mode delphiunicode}{$H+}{$ENDIF}

{
  Visual Scanner -- the one line between the MCP server and the card.

  TMCPServer reports "this addon tool was called, here are its arguments and its
  result". TAefosVisualBroadcast owns the sessions and pushes to the panel.
  TAefosVisualToolMap knows what a desktop tool MEANS. This joins the three, and
  does nothing else:

      report -> role? key? image? -> events -> broadcaster -> panel

  It is a separate unit rather than a closure inside the chat's registration
  because every decision it makes is worth testing, and a lambda buried in a
  4000-line Register.pas is not reachable from a headless test. Everything here
  is pure except the broadcaster it holds, which is itself pure.

  What it deliberately does NOT do:

  * It does not create sessions. The broadcaster adopts on first sight and
    refuses an id-less one; inventing a key here to make a card appear would
    defeat that.
  * It does not decide legality. It reports; the machine refuses. A refusal is
    silent by design -- it means the agent did something that is not a step in
    a visual operation, which is most of what an agent does.
  * It does not carry the screenshot. The image id identifies a capture; the
    bytes are a separate piece of plumbing.

  ASCII only: no BOM needed.
}

interface

uses
  {$IFDEF FPC}
  SysUtils,
  {$ELSE}
  System.SysUtils,
  {$ENDIF}
  Aefos.Chat.Core.VisualSession,
  Aefos.Chat.Core.VisualBroadcast,
  Aefos.Chat.Core.VisualToolMap;

type
  { How a screenshot reaches the viewer -- a channel of its OWN, separate from
    the card payload. The payload is re-sent on every step, so a picture carried
    inside it would be re-pushed with each one; this fires once per capture and
    the card looks the id up from then on. }
  {$IFDEF FPC}
  TAefosVisualImagePush = procedure(const AImageId, ADataUri: string) of object;
  {$ELSE}
  TAefosVisualImagePush = reference to procedure(const AImageId,
    ADataUri: string);
  {$ENDIF}

  TAefosVisualReporter = class sealed
  private
    FBroadcast: TAefosVisualBroadcast;
    FOwnsBroadcast: Boolean;
    FImagePush: TAefosVisualImagePush;
  public
    { AOwnsBroadcast decides whether destroying this also destroys the
      broadcaster. The chat host owns one broadcaster for the whole panel and
      lends it; a test builds a throwaway pair and wants both gone. }
    constructor Create(const ABroadcast: TAefosVisualBroadcast;
      const AOwnsBroadcast: Boolean = False);
    destructor Destroy; override;

    { The MCP server's report, translated and delivered. Returns the number of
      events the machine ACCEPTED -- 0 is the normal answer for a tool that is
      not part of a visual operation, and a test can tell "nothing happened"
      from "something happened" without reaching into the panel. }
    function Report(const AToolName, AArgumentsJson, AResultJson: string;
      const AFailed: Boolean): Integer;

    { Where captured screenshots go. Optional: with none set the card still
      walks its steps and simply never draws the comparison, which is exactly
      what it did before the pictures were plumbed. }
    property ImagePush: TAefosVisualImagePush read FImagePush write FImagePush;
    property Broadcast: TAefosVisualBroadcast read FBroadcast;
  end;

implementation

constructor TAefosVisualReporter.Create(const ABroadcast: TAefosVisualBroadcast;
  const AOwnsBroadcast: Boolean);
begin
  inherited Create;
  FBroadcast := ABroadcast;
  FOwnsBroadcast := AOwnsBroadcast;
end;

destructor TAefosVisualReporter.Destroy;
begin
  if FOwnsBroadcast then
    FreeAndNil(FBroadcast);
  inherited Destroy;
end;

function TAefosVisualReporter.Report(const AToolName, AArgumentsJson,
  AResultJson: string; const AFailed: Boolean): Integer;
var
  LRole: TAefosToolRole;
  LOutcome: TAefosToolOutcome;
  LKey, LImageId, LReason: string;
  LEvents: TArray<TAefosVisualEvent>;
  LScan: Integer;
begin
  Result := 0;
  if FBroadcast = nil then
    Exit;
  LRole := TAefosVisualToolMap.RoleOf(AToolName);
  if LRole = trIgnored then
    Exit;
  LKey := TAefosVisualToolMap.SessionKeyOf(AArgumentsJson);
  if LKey = '' then
    Exit; // no window named: nothing to key a card by, so nothing is drawn
  if AFailed then
    LOutcome := toFailed
  else
    LOutcome := toSucceeded;
  LImageId := '';
  if LRole = trCapture then
  begin
    LImageId := TAefosVisualToolMap.ImageIdOf(AResultJson);
    // BEFORE the events, so the picture is already in the viewer's store when
    // the card that names it renders. The card repaints if it arrives late
    // anyway, but not needing that is better than relying on it.
    if (LImageId <> '') and Assigned(FImagePush) then
      try
        FImagePush(LImageId, TAefosVisualToolMap.ImageDataUriOf(AResultJson));
      except
        // A picture that fails to reach the panel must not fail the report: the
        // steps are the part the user is actually watching.
      end;
  end;

  // The map needs the session's CURRENT state, and the broadcaster is the only
  // thing that knows it. Asking for it here (rather than the map holding state)
  // is what keeps the translation a pure function of its inputs.
  LEvents := TAefosVisualToolMap.EventsFor(LRole, LOutcome,
    FBroadcast.StateOf(LKey), LImageId, AToolName);

  for LScan := 0 to High(LEvents) do
    if FBroadcast.Report(LKey, LEvents[LScan], LReason) then
      Inc(Result)
    else
      // The events for one call are a SEQUENCE (started, then completed), so a
      // refusal ends the run rather than reporting a completion for something
      // that never began.
      //
      // Defence in depth, and honestly labelled as such: mutation testing shows
      // removing this changes NO observable behaviour, because every completion
      // the machine knows is guarded by its own state and gets refused anyway.
      // Kept because it states the intent at the place the sequence is walked,
      // and because "the other layer happens to catch it" is a property of
      // today's machine, not a rule anyone promised to keep.
      Break;
end;

end.
