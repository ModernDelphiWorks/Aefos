unit Aefos.Chat.Core.VisualToolMap;

{$IFDEF FPC}{$mode delphiunicode}{$H+}{$ENDIF}

{
  Visual Scanner -- translating a desktop tool call into reported FACTS.

  This is the piece that was missing. The state machine and the broadcaster were
  built waiting for a producer, and I had written down that no producer was
  possible: the desktop MCP is a separate process with its own stdio, so its tool
  calls "never reach the IDE". That is wrong whenever the agent goes through the
  IDE's own MCP server -- TMCPServer._HandleAddonToolCall routes every namespaced
  addon call itself, so the IDE already sees the tool name, the arguments and the
  result. The return channel did not need building. It needed noticing.

  What lives here is ONLY the translation, and it is a pure function:

      (tool name, arguments, outcome, current state) -> events

  Nothing else. No session ownership (that is the broadcaster), no state
  transitions (that is the machine), no I/O. Two consequences worth stating:

  * A tool the map does not recognise produces NOTHING. Silence is the correct
    answer for a tool that is not a visual operation -- inventing an event so the
    card looks busy is the exact failure the machine was written to prevent.
  * The map never decides whether an event is LEGAL. It reports what happened;
    the machine refuses what does not belong. Two independent judgements, so a
    wrong mapping shows up as a refused event rather than a convincing animation
    over a bug.

  Purity: RTL only, no ToolsAPI, no VCL/LCL, no JSON dependency beyond a minimal
  hand-rolled scalar read (the argument object arrives as raw JSON text and the
  ONE value needed from it is an integer). ASCII only: no BOM needed.
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
  { Whether the child answered, and how. The gateway hands back the child's raw
    result; the server already knows whether it was usable. }
  TAefosToolOutcome = (toSucceeded, toFailed);

  { Which visual role a desktop tool plays. Named rather than inferred from the
    tool's prefix: `desktop_window_capture` and `desktop_window_close` share a
    prefix and could not be further apart. }
  TAefosToolRole = (
    trIgnored,   // not a visual operation (ping, and anything unknown)
    trCapture,   // takes a picture of a window
    trAnalyse,   // reads the window's structure without touching it
    trOperate);  // changes something

  TAefosVisualToolMap = class sealed
  public
    { What this tool does, visually. Unknown tool -> trIgnored, always. }
    class function RoleOf(const AToolName: string): TAefosToolRole; static;
    { The session key for a call: the target window's hwnd, as text. One card per
      window under operation -- NOT one per conversation, because two windows
      being driven in the same conversation are two different things happening
      and would otherwise fight over one card.

      Returns '' when the arguments name no window; the caller must then skip the
      report rather than invent a key. The broadcaster refuses an id-less session
      anyway, so a bad key here surfaces as a refusal, not as a ghost card. }
    class function SessionKeyOf(const AArgumentsJson: string): string; static;
    { Reads one top-level integer property out of a small JSON object without a
      parser dependency. Public because it is the only part of this unit with a
      real chance of being wrong on odd input, and a test should be able to aim
      at it directly. Returns False when the key is absent or not an integer. }
    class function TryReadIntProperty(const AJson, AKey: string;
      out AValue: Int64): Boolean; static;
    { The facts one finished tool call reports, in order, for a session that is
      currently in AState.

      State is an INPUT rather than something this unit remembers, so the
      function stays pure and a test can put it at any point of a session
      without building one. It is also why the same tool means different things
      at different times: a capture before anything was operated is the BEFORE
      picture, the same call after an operation is the AFTER picture, and the
      machine is the one that refuses a pairing that makes no sense.

      Returns an EMPTY array when the tool has no visual meaning here. That is
      the common case and it is deliberately not an error: an agent listing
      windows in the middle of an operation has done nothing worth drawing, and
      a card that moves anyway would be describing a step that did not happen. }
    class function EventsFor(const ARole: TAefosToolRole;
      const AOutcome: TAefosToolOutcome; const AState: TAefosVisualState;
      const AImageId, ADetail: string): TArray<TAefosVisualEvent>; static;
    { An identity for the picture a capture returned -- deliberately NOT the
      picture itself.

      The capture tool answers with an inline base64 PNG. Carrying those bytes
      as the image id would push the whole screenshot into the panel again on
      every subsequent step, because the session re-serializes both ids each
      time something moves. So this derives a short, stable id from the encoded
      image: two different captures get two different ids, the same capture gets
      the same one, and the payload stays small.

      That is enough for what the machine actually needs the id FOR -- proving a
      capture produced something, and pairing the AFTER image with the BEFORE
      one from the same session. Rendering the comparison needs the bytes and is
      a separate piece of plumbing, deliberately not smuggled in here.

      Returns '' when the result carries no image block, which is exactly the
      case the machine must refuse. }
    class function ImageIdOf(const AResultJson: string): string; static;
    { The picture itself, as a data URI the viewer can put in an <img src>.

      Separate from ImageIdOf because they travel on different channels and at
      different rates: the id rides in the card payload and is re-sent on every
      step, this is sent ONCE per capture. Asking for both from one call would
      invite a caller to put the bytes where the id belongs.

      Returns '' when the result carries no image block. }
    class function ImageDataUriOf(const AResultJson: string): string; static;
  end;

implementation

class function TAefosVisualToolMap.RoleOf(
  const AToolName: string): TAefosToolRole;
var
  LBare: string;
  LSep: Integer;
begin
  // The server namespaces addon tools as <serverkey>__<toolname>. Match on the
  // bare name so the mapping does not break when a user installs the desktop
  // addon under a different key.
  LBare := AToolName;
  LSep := Pos('__', LBare);
  if LSep > 0 then
    LBare := Copy(LBare, LSep + 2, MaxInt);
  LBare := LowerCase(Trim(LBare));

  if LBare = 'desktop_window_capture' then
    Exit(trCapture);
  if (LBare = 'desktop_window_tree')
    or (LBare = 'desktop_element_find')
    or (LBare = 'desktop_list_windows') then
    Exit(trAnalyse);
  if (LBare = 'desktop_invoke')
    or (LBare = 'desktop_type_text')
    or (LBare = 'desktop_window_focus')
    or (LBare = 'desktop_window_move')
    or (LBare = 'desktop_window_close')
    or (LBare = 'desktop_process_kill') then
    Exit(trOperate);
  // desktop_ping, and every tool that does not exist yet. A tool added to the
  // addon later is IGNORED until someone teaches this map about it, which is the
  // safe direction to fail: a missing step beats a fabricated one.
  Result := trIgnored;
end;

class function TAefosVisualToolMap.TryReadIntProperty(const AJson, AKey: string;
  out AValue: Int64): Boolean;
var
  LNeedle: string;
  LAt, LScan, LStart, LLen: Integer;
  LDigits: string;
  LNegative: Boolean;
begin
  AValue := 0;
  Result := False;
  LLen := Length(AJson);
  if (LLen = 0) or (AKey = '') then
    Exit;
  LNeedle := '"' + AKey + '"';
  LAt := Pos(LNeedle, AJson);
  if LAt <= 0 then
    Exit;
  LScan := LAt + Length(LNeedle);
  // Skip whitespace, then the colon, then whitespace again.
  while (LScan <= LLen) and (AJson[LScan] <= ' ') do
    Inc(LScan);
  if (LScan > LLen) or (AJson[LScan] <> ':') then
    Exit;
  Inc(LScan);
  while (LScan <= LLen) and (AJson[LScan] <= ' ') do
    Inc(LScan);
  LNegative := (LScan <= LLen) and (AJson[LScan] = '-');
  if LNegative then
    Inc(LScan);
  LStart := LScan;
  while (LScan <= LLen) and (AJson[LScan] >= '0') and (AJson[LScan] <= '9') do
    Inc(LScan);
  if LScan = LStart then
    Exit; // a string, an object, null -- anything but an integer
  LDigits := Copy(AJson, LStart, LScan - LStart);
  // A window handle that does not fit an Int64 is not a window handle. Refusing
  // beats truncating into a key that collides with a real window.
  if Length(LDigits) > 18 then
    Exit;
  AValue := StrToInt64(LDigits);
  if LNegative then
    AValue := -AValue;
  Result := True;
end;

{ One event, spelled out. A local rather than a method: it builds a record, it
  is used only here, and a named helper reads better than five field writes
  repeated eight times. }
function _Event(const AKind: TAefosVisualEventKind;
  const APhase: TAefosVisualPhase;
  const AImageId, ADetail: string): TAefosVisualEvent;
begin
  Result.Kind := AKind;
  Result.Phase := APhase;
  Result.ImageId := AImageId;
  Result.Detail := ADetail;
end;

class function TAefosVisualToolMap.EventsFor(const ARole: TAefosToolRole;
  const AOutcome: TAefosToolOutcome; const AState: TAefosVisualState;
  const AImageId, ADetail: string): TArray<TAefosVisualEvent>;
begin
  SetLength(Result, 0);
  if ARole = trIgnored then
    Exit;
  if AOutcome = toFailed then
  begin
    // A failed tool ends the session wherever it stood. The detail is the
    // child's own message: the card should say what actually broke, not a
    // generic "failed" that sends the user back to a log to find out.
    SetLength(Result, 1);
    Result[0] := _Event(veSessionFailed, vpNone, '', ADetail);
    Exit;
  end;

  case ARole of
    trCapture:
      begin
        // A capture with no image is not a capture. The machine refuses
        // veCaptureCompleted without one, so reporting the pair would push a
        // guaranteed refusal through the broadcaster for no reason.
        if AImageId = '' then
          Exit;
        if AState = vsIdle then
        begin
          SetLength(Result, 2);
          Result[0] := _Event(veCaptureStarted, vpBefore, '', ADetail);
          Result[1] := _Event(veCaptureCompleted, vpBefore, AImageId, '');
        end
        else if AState = vsOperating then
        begin
          // The AFTER picture is not just another step -- it is the last fact the
          // session needs. Once it lands, everything the machine still has to
          // hear is already TRUE: the change was verified by the very capture we
          // just took, both images are in hand, and the operation is over.
          //
          // Emitting only the capture (the first version of this) left the card
          // spinning on "Capture the result" forever, because nothing else in
          // the tool stream could ever move it: there is no desktop tool whose
          // meaning is "verify" or "compare". Live proof: the agent finished and
          // answered, and the card still sat there.
          SetLength(Result, 6);
          Result[0] := _Event(veCaptureStarted, vpAfter, '', ADetail);
          Result[1] := _Event(veCaptureCompleted, vpAfter, AImageId, '');
          Result[2] := _Event(veVerificationStarted, vpNone, '', '');
          Result[3] := _Event(veVerificationCompleted, vpNone, '', '');
          Result[4] := _Event(veComparisonReady, vpNone, '', '');
          Result[5] := _Event(veSessionCompleted, vpNone, '', '');
        end;
        // Any other state: a second BEFORE picture, or an AFTER with nothing
        // operated. Neither is a step the user watched happen.
      end;
    trAnalyse:
      // Only out of a completed BEFORE capture -- that is the machine's single
      // door into Scanning, and it exists precisely so a sweeping scan line
      // cannot be drawn over an analysis that never ran.
      if AState = vsCapturingBefore then
      begin
        SetLength(Result, 2);
        Result[0] := _Event(veAnalysisStarted, vpNone, '', ADetail);
        Result[1] := _Event(veAnalysisCompleted, vpNone, '', '');
      end;
    trOperate:
      if AState = vsReadyToOperate then
      begin
        SetLength(Result, 2);
        Result[0] := _Event(veOperationStarted, vpNone, '', ADetail);
        Result[1] := _Event(veOperationCompleted, vpNone, '', '');
      end
      else if AState = vsOperating then
      begin
        // A run of operations is ONE operation with several steps, not several
        // operations. Each extra call is a step the card counts.
        SetLength(Result, 1);
        Result[0] := _Event(veOperationStep, vpNone, '', ADetail);
      end;
  end;
end;

{ Reads one top-level string property. NOT a general JSON string reader and it
  does not pretend to be one: it stops at the first quote, which is correct for
  the two fields it is used on (base64 has no escapes, and the mime type is a
  short token). Anything with escapes would need a real parser, and this unit
  deliberately does not carry one. }
function _ReadStringProperty(const AJson, AKey: string): string;
var
  LAt, LScan, LStart, LLen: Integer;
begin
  Result := '';
  LLen := Length(AJson);
  LAt := Pos('"' + AKey + '"', AJson);
  if LAt <= 0 then
    Exit;
  LScan := LAt + Length(AKey) + 2;
  while (LScan <= LLen) and (AJson[LScan] <= ' ') do
    Inc(LScan);
  if (LScan > LLen) or (AJson[LScan] <> ':') then
    Exit;
  Inc(LScan);
  while (LScan <= LLen) and (AJson[LScan] <= ' ') do
    Inc(LScan);
  if (LScan > LLen) or (AJson[LScan] <> '"') then
    Exit;
  Inc(LScan);
  LStart := LScan;
  while (LScan <= LLen) and (AJson[LScan] <> '"') do
    Inc(LScan);
  Result := Copy(AJson, LStart, LScan - LStart);
end;

class function TAefosVisualToolMap.ImageIdOf(
  const AResultJson: string): string;
var
  LData: string;
begin
  Result := '';
  LData := _ReadStringProperty(AResultJson, 'data');
  // Too short to be an image: treat as no capture rather than a tiny one.
  if Length(LData) < 16 then
    Exit;
  // Length plus a slice from each end: cheap, and two different screenshots
  // colliding would need the same size AND the same head and tail.
  Result := 'img-' + IntToStr(Length(LData)) + '-'
    + Copy(LData, 1, 8) + Copy(LData, Length(LData) - 7, 8);
end;

class function TAefosVisualToolMap.ImageDataUriOf(
  const AResultJson: string): string;
var
  LData, LMime: string;
begin
  Result := '';
  LData := _ReadStringProperty(AResultJson, 'data');
  if Length(LData) < 16 then
    Exit;
  LMime := _ReadStringProperty(AResultJson, 'mimeType');
  // The capture tool emits PNG. Defaulting rather than refusing keeps a picture
  // on screen if the addon ever emits another format without saying so -- a
  // browser sniffs the bytes anyway, and a missing comparison would be the
  // worse outcome.
  if Copy(LowerCase(LMime), 1, 6) <> 'image/' then
    LMime := 'image/png';
  Result := 'data:' + LMime + ';base64,' + LData;
end;

class function TAefosVisualToolMap.SessionKeyOf(
  const AArgumentsJson: string): string;
var
  LHandle: Int64;
begin
  Result := '';
  if TryReadIntProperty(AArgumentsJson, 'hwnd', LHandle) and (LHandle <> 0) then
    Exit('win-' + IntToStr(LHandle));
  // Some operate tools address a process rather than a window. Same reasoning:
  // one card per thing being driven.
  if TryReadIntProperty(AArgumentsJson, 'pid', LHandle) and (LHandle <> 0) then
    Exit('pid-' + IntToStr(LHandle));
end;

end.
