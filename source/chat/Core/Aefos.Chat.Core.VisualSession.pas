unit Aefos.Chat.Core.VisualSession;

{$IFDEF FPC}{$mode delphiunicode}{$H+}{$ENDIF}

{
  Aefos Visual Scanner -- STAGE 1: the visual session model + its state machine.

  Full spec: meta\visual-scanner\00-spec.md.

  What this unit is for
  ---------------------
  The chat already does the hard part: the agent changes REAL components through
  the IDE (OTA/MCP), which is safer than clicking pixels. What it never did was
  SHOW that happening. The Visual Scanner is the layer that shows it -- capture,
  analysis, operation, verification, before/after.

  The single rule that decides whether this feature is honest
  -----------------------------------------------------------
  THE ANIMATION FOLLOWS REAL EVENTS, NEVER A TIMER. A scanner line sweeping while
  nothing is being analysed is a lie told with pixels, and it is the easiest thing
  in the world to build by accident (start animation, sleep 2s, stop). So the
  state lives HERE, in a pure machine that only moves when the tool layer reports
  something that actually happened, and REFUSES every transition that does not
  belong -- it never silently corrects itself into a plausible state. A UI built
  on top of this cannot claim "locating controls" unless an analysis really ran,
  because there is no path into Scanning except AnalysisStarted.

  Purity: no ToolsAPI, no Vcl.*/LCL, no I/O, no JSON. Same discipline as
  Aefos.Chat.Core.CliHarness, so both editions can share one machine and a
  headless test can drive it. All literals are ASCII: this file needs no BOM.

  Not in this unit (later stages): the card, the overlay, the before/after
  viewer, the pixel diff. Stage 1 is the foundation those hang off.
}

interface

uses
  {$IFDEF FPC}
  SysUtils;
  {$ELSE}
  System.SysUtils;
  {$ENDIF}

type
  { The states from the spec, in order. CapturingBefore/CapturingAfter cover the
    whole capture phase (started AND completed): a capture that has landed but
    has no analysis yet is still "capturing" as far as the user is concerned, and
    inventing an extra state for it would let the UI show a stage the spec never
    named. }
  TAefosVisualState = (
    vsIdle,
    vsCapturingBefore,
    vsScanning,
    vsReadyToOperate,
    vsWaitingPermission,
    vsOperating,
    vsCapturingAfter,
    vsVerifying,
    vsShowingComparison,
    vsCompleted,
    vsCancelled,
    vsTimedOut,
    vsFailed,
    { The chat turn ended while this session was still mid-flight.
      Distinct from Cancelled on purpose. Cancelled means somebody said no -- a
      denied permission is the case that produces it. This means nobody said
      anything: the agent simply stopped calling desktop tools and answered, most
      often because it read the control tree and did the work in its head instead
      of operating the app. The card must say which of those happened; one label
      for both would blame the user for the agent's shortcut. }
    vsAbandoned);

  { The events the tool layer publishes. It does not know the animation exists --
    it reports facts, and the machine decides what that means.

    Two events here are NOT in the spec's list and are added deliberately:
      vePermissionGranted / vePermissionDenied -- the spec has permission_required
        but nothing that RESOLVES it, so a session could enter WaitingPermission
        and never legally leave. A dead end in a state machine is not a design.
      veSessionCompleted -- the spec has a Completed state but no event reaching
        it. Same reason.
    Flagged rather than smuggled in: the spec is the owner's, the gap is mine to
    report. }
  TAefosVisualEventKind = (
    veSessionStarted,
    veCaptureStarted,
    veCaptureCompleted,
    veAnalysisStarted,
    veAnalysisCompleted,
    vePermissionRequired,
    vePermissionGranted,
    vePermissionDenied,
    veOperationStarted,
    veOperationStep,
    veOperationCompleted,
    veVerificationStarted,
    veVerificationCompleted,
    veComparisonReady,
    veSessionCompleted,
    veSessionFailed,
    veSessionCancelled,
    veSessionTimedOut,
    { Published by the chat host, not by a tool: the turn is over, so nothing can
      move this session again. Without it a card that stopped mid-way stayed LIVE
      for ever -- steps pending, scan line sweeping -- while the conversation
      below it had already printed its answer. }
    veSessionAbandoned);

  { Which side of the operation a capture belongs to. vpNone is for events that
    carry no capture at all -- it is never a valid phase for a capture event, and
    the machine says so instead of guessing "before". }
  TAefosVisualPhase = (vpNone, vpBefore, vpAfter);

  { The steps a viewer draws, in the order they happen. This is the SPINE of the
    scanner overlay: the UI walks these, never a timer.

    Not the same list as TAefosVisualState. A state is where the session IS; a
    step is a thing the user watched happen, and some states are not steps at all
    (Idle, WaitingPermission, the four terminal ones). Conflating them is how an
    overlay ends up claiming "analysing" while a session sits waiting for a
    permission answer. }
  TAefosVisualStep = (
    vstCaptureBefore,
    vstScan,
    vstOperate,
    vstCaptureAfter,
    vstVerify,
    vstCompare);

  { What a viewer may say about one step.

    vssSkipped exists because a session that failed halfway must not draw its
    remaining steps as "pending", which reads as "still coming". They are never
    coming. Saying so is the difference between a progress display and a lie
    that happens to be still. }
  TAefosVisualStepStatus = (
    vssPending,
    vssActive,
    vssDone,
    vssFailed,
    vssSkipped);

  TAefosVisualEvent = record
    Kind: TAefosVisualEventKind;
    Phase: TAefosVisualPhase;
    ImageId: string;   // set by veCaptureCompleted; '' otherwise
    Detail: string;    // free text for step/failure reporting
  end;

  { The machine. One instance per visual session. Sealed: the rule has one
    implementation, exactly like the CLI harness. }
  TAefosVisualSession = class sealed
  private
    FSessionId: string;
    FState: TAefosVisualState;
    FBeforeImageId: string;
    FAfterImageId: string;
    FLastDetail: string;
    FStepCount: Integer;
    { The furthest the session ever got, which the current state cannot tell you
      once it is terminal: after a failure, State is Failed and every step looks
      equally un-run. The UI needs to know that the capture and the scan DID
      happen and only the verification never started -- otherwise a failed
      session redraws as if nothing had occurred, and the user loses the record
      of what the agent actually did before it broke. }
    FReached: TAefosVisualState;
    procedure _Reach(const AState: TAefosVisualState);
    function _AcceptTerminal(const AEvent: TAefosVisualEvent;
      out AReason: string): Boolean;
    function _AcceptCapture(const AEvent: TAefosVisualEvent;
      out AReason: string): Boolean;
  public
    constructor Create(const ASessionId: string);
    // Applies one reported fact. True => the machine moved (or legitimately
    // stayed, e.g. an operation step). False => the event does NOT belong in
    // this state and NOTHING changed; AReason says why, in kebab-case, so a
    // caller can log or surface it without parsing prose.
    //   Refusing rather than absorbing is the point: a UI that receives
    // "operation started" while still capturing has a bug somewhere, and
    // silently entering Operating would hide it behind a convincing animation.
    function Apply(const AEvent: TAefosVisualEvent;
      out AReason: string): Boolean;
    // True once the session can never move again (Completed/Cancelled/TimedOut/
    // Failed). Terminal states accept no further events at all.
    function IsTerminal: Boolean;
    // True while the scanner overlay is entitled to animate: an analysis or a
    // verification is genuinely running. The UI asks THIS instead of keeping its
    // own timer, which is what keeps the animation honest.
    function IsAnalysing: Boolean;
    // The before/after pair is only offerable when BOTH captures of THIS session
    // landed -- an acceptance criterion from the spec, enforced here rather than
    // trusted to the viewer.
    function HasComparisonPair: Boolean;
    // Short, TRUE status label for the current state. English (Aefos is English
    // everywhere user-facing) and single-sourced so two surfaces can never
    // describe the same state differently.
    class function StatusText(const AState: TAefosVisualState): string; static;
    { What a viewer may draw for one step, RIGHT NOW.

      This is where the spec's first rule stops being a promise and becomes
      code: "the animation follows a REAL EVENT, never a timer." A viewer that
      asks this cannot draw a step the session never reached, cannot leave a
      step spinning after the session died, and cannot show the comparison
      before both captures landed -- because the answer is computed from what
      was reported, and there is no other source. }
    function StepStatus(const AStep: TAefosVisualStep): TAefosVisualStepStatus;
    { The label for a step. Single-sourced for the same reason as StatusText:
      two surfaces must never name the same step differently. }
    class function StepText(const AStep: TAefosVisualStep): string; static;
    { The furthest state this session ever reached. Exposed because a terminal
      state erases the journey and the UI still has to render it. }
    property Reached: TAefosVisualState read FReached;
    { The whole session as the ONE payload the panel's JS consumes.

      The contract between Pascal and the WebView lives here, in the tested
      unit, rather than being assembled at the call site out of string
      concatenation nobody can prove. The JS reads exactly these keys; changing
      one is a change to a tested shape, not a silent break discovered in a
      screenshot.

      Kebab-case tokens (`capture-before`, `showing-comparison`) match the house
      convention for machine-readable values -- the guard verdicts and the
      inline-completion rejection reasons already read this way, so a log line
      from either surface looks the same.

      Deliberately NOT a generic serialiser: every value here is a fixed token
      or an id we minted, so the only field that can carry arbitrary text is
      Detail, and that one is escaped. }
    function ToJson: string;
    class function StateToken(const AState: TAefosVisualState): string; static;
    class function StepToken(const AStep: TAefosVisualStep): string; static;
    class function StatusToken(
      const AStatus: TAefosVisualStepStatus): string; static;
    property SessionId: string read FSessionId;
    property State: TAefosVisualState read FState;
    property BeforeImageId: string read FBeforeImageId;
    property AfterImageId: string read FAfterImageId;
    property LastDetail: string read FLastDetail;
    property StepCount: Integer read FStepCount;
  end;

// Builds an event without a capture. Kept as a function pair (not a constructor
// on the record) so FPC and Delphi agree on the syntax.
function VisualEvent(const AKind: TAefosVisualEventKind;
  const ADetail: string = ''): TAefosVisualEvent;
// Builds a capture event carrying its phase and (on completion) its image id.
function VisualCaptureEvent(const AKind: TAefosVisualEventKind;
  const APhase: TAefosVisualPhase;
  const AImageId: string = ''): TAefosVisualEvent;

implementation

function VisualEvent(const AKind: TAefosVisualEventKind;
  const ADetail: string): TAefosVisualEvent;
begin
  Result := Default(TAefosVisualEvent);
  Result.Kind := AKind;
  Result.Phase := vpNone;
  Result.Detail := ADetail;
end;

function VisualCaptureEvent(const AKind: TAefosVisualEventKind;
  const APhase: TAefosVisualPhase;
  const AImageId: string): TAefosVisualEvent;
begin
  Result := Default(TAefosVisualEvent);
  Result.Kind := AKind;
  Result.Phase := APhase;
  Result.ImageId := AImageId;
end;

{ TAefosVisualSession }

constructor TAefosVisualSession.Create(const ASessionId: string);
begin
  inherited Create;
  FSessionId := ASessionId;
  FState := vsIdle;
  FReached := vsIdle;
  FStepCount := 0;
end;

function TAefosVisualSession.IsTerminal: Boolean;
begin
  Result := FState in [vsCompleted, vsCancelled, vsTimedOut, vsFailed, vsAbandoned];
end;

function TAefosVisualSession.IsAnalysing: Boolean;
begin
  // Scanning and Verifying are the only two states where work the user was told
  // about is actually running. Operating is deliberately NOT here: while the
  // agent operates, the spec asks for a discrete "agent operating" indicator,
  // not the sweeping scanner.
  Result := FState in [vsScanning, vsVerifying];
end;

function TAefosVisualSession.HasComparisonPair: Boolean;
begin
  Result := (FBeforeImageId <> '') and (FAfterImageId <> '');
end;

function TAefosVisualSession._AcceptTerminal(const AEvent: TAefosVisualEvent;
  out AReason: string): Boolean;
begin
  // Cancel / fail / timeout may arrive in ANY live state -- that is the whole
  // point of them. They are checked before the per-state table so no state has
  // to remember to allow them.
  AReason := '';
  Result := True;
  case AEvent.Kind of
    veSessionCancelled: FState := vsCancelled;
    veSessionTimedOut: FState := vsTimedOut;
    veSessionAbandoned: FState := vsAbandoned;
    veSessionFailed:
      begin
        FState := vsFailed;
        FLastDetail := AEvent.Detail;
      end;
  else
    Result := False;
  end;
end;

function TAefosVisualSession._AcceptCapture(const AEvent: TAefosVisualEvent;
  out AReason: string): Boolean;
begin
  AReason := '';
  Result := False;
  // A capture event with no phase is a caller bug, not a "before" by default.
  if AEvent.Phase = vpNone then
  begin
    AReason := 'visual-capture-without-phase';
    Exit;
  end;
  if AEvent.Kind = veCaptureStarted then
  begin
    if (AEvent.Phase = vpBefore) and (FState = vsIdle) then
    begin
      FState := vsCapturingBefore;
      _Reach(vsCapturingBefore);
      Exit(True);
    end;
    // The AFTER capture only exists once something was operated: capturing
    // "after" with nothing done would produce a before/after pair that shows a
    // change the agent never made.
    if (AEvent.Phase = vpAfter) and (FState = vsOperating) then
    begin
      FState := vsCapturingAfter;
      _Reach(vsCapturingAfter);
      Exit(True);
    end;
    AReason := 'visual-capture-start-out-of-order';
    Exit;
  end;
  // veCaptureCompleted: stays in the capture state; the image id is what moves.
  if AEvent.ImageId = '' then
  begin
    AReason := 'visual-capture-without-image';
    Exit;
  end;
  if (AEvent.Phase = vpBefore) and (FState = vsCapturingBefore) then
  begin
    FBeforeImageId := AEvent.ImageId;
    Exit(True);
  end;
  if (AEvent.Phase = vpAfter) and (FState = vsCapturingAfter) then
  begin
    // Same-session pairing (spec acceptance criterion): the AFTER image can only
    // land in the same object that already holds the BEFORE image, so a viewer
    // can never be handed halves of two different sessions.
    if FBeforeImageId = '' then
    begin
      AReason := 'visual-after-without-before';
      Exit;
    end;
    FAfterImageId := AEvent.ImageId;
    Exit(True);
  end;
  AReason := 'visual-capture-phase-mismatch';
end;

function TAefosVisualSession.Apply(const AEvent: TAefosVisualEvent;
  out AReason: string): Boolean;
begin
  AReason := '';
  Result := False;
  // A finished session is finished. Accepting a late event would resurrect an
  // animation over a card the user already considers done.
  if IsTerminal then
  begin
    AReason := 'visual-session-already-terminal';
    Exit;
  end;
  if AEvent.Kind in [veSessionCancelled, veSessionTimedOut, veSessionFailed,
    veSessionAbandoned] then
    Exit(_AcceptTerminal(AEvent, AReason));
  if AEvent.Kind in [veCaptureStarted, veCaptureCompleted] then
    Exit(_AcceptCapture(AEvent, AReason));

  case AEvent.Kind of
    veSessionStarted:
      if FState = vsIdle then
        Exit(True)   // no move: Idle IS the started-but-idle state
      else
        AReason := 'visual-session-already-started';
    veAnalysisStarted:
      // The ONLY door into Scanning. This is what makes the sweeping line
      // impossible to show without a real analysis behind it.
      if (FState = vsCapturingBefore) and (FBeforeImageId <> '') then
      begin
        FState := vsScanning;
      _Reach(vsScanning);
        Exit(True);
      end
      else if FState = vsCapturingBefore then
        AReason := 'visual-analysis-without-capture'
      else
        AReason := 'visual-analysis-out-of-order';
    veAnalysisCompleted:
      if FState = vsScanning then
      begin
        FState := vsReadyToOperate;
      _Reach(vsReadyToOperate);
        Exit(True);
      end
      else
        AReason := 'visual-analysis-not-running';
    vePermissionRequired:
      if FState = vsReadyToOperate then
      begin
        FState := vsWaitingPermission;
      _Reach(vsWaitingPermission);
        Exit(True);
      end
      else
        AReason := 'visual-permission-out-of-order';
    vePermissionGranted:
      if FState = vsWaitingPermission then
      begin
        FState := vsReadyToOperate;
      _Reach(vsReadyToOperate);
        Exit(True);
      end
      else
        AReason := 'visual-permission-not-pending';
    vePermissionDenied:
      // A refused permission ends the session as CANCELLED, not FAILED: nothing
      // broke, a human said no.
      if FState = vsWaitingPermission then
      begin
        FState := vsCancelled;
        Exit(True);
      end
      else
        AReason := 'visual-permission-not-pending';
    veOperationStarted:
      if FState = vsReadyToOperate then
      begin
        FState := vsOperating;
      _Reach(vsOperating);
        Exit(True);
      end
      else
        AReason := 'visual-operation-out-of-order';
    veOperationStep:
      if FState = vsOperating then
      begin
        Inc(FStepCount);
        FLastDetail := AEvent.Detail;
        Exit(True);
      end
      else
        AReason := 'visual-step-outside-operation';
    veOperationCompleted:
      // Stays in Operating on purpose: the session is not done until the AFTER
      // capture is taken, and moving away here would leave no legal path to it.
      if FState = vsOperating then
        Exit(True)
      else
        AReason := 'visual-operation-not-running';
    veVerificationStarted:
      if (FState = vsCapturingAfter) and (FAfterImageId <> '') then
      begin
        FState := vsVerifying;
      _Reach(vsVerifying);
        Exit(True);
      end
      else if FState = vsCapturingAfter then
        AReason := 'visual-verification-without-capture'
      else
        AReason := 'visual-verification-out-of-order';
    veVerificationCompleted:
      if FState = vsVerifying then
        Exit(True)
      else
        AReason := 'visual-verification-not-running';
    veComparisonReady:
      if FState = vsVerifying then
      begin
        if not HasComparisonPair then
        begin
          AReason := 'visual-comparison-incomplete-pair';
          Exit;
        end;
        FState := vsShowingComparison;
      _Reach(vsShowingComparison);
        Exit(True);
      end
      else
        AReason := 'visual-comparison-out-of-order';
    veSessionCompleted:
      // Two honest ways to finish: after showing the comparison (operation mode)
      // or straight from the analysis (observation mode, where nothing is
      // operated and there is no after image to compare).
      if FState in [vsShowingComparison, vsScanning, vsReadyToOperate] then
      begin
        FState := vsCompleted;
      _Reach(vsCompleted);
        Exit(True);
      end
      else
        AReason := 'visual-complete-out-of-order';
  else
    AReason := 'visual-unknown-event';
  end;
end;

procedure TAefosVisualSession._Reach(const AState: TAefosVisualState);
begin
  // Monotonic by the enum's own order, which is the spec's order. Never moved
  // by a terminal state: Failed is not "further" than Verifying, it is the end
  // of the road, and treating it as progress would erase the step that broke.
  if AState > FReached then
    FReached := AState;
end;

function TAefosVisualSession.StepStatus(
  const AStep: TAefosVisualStep): TAefosVisualStepStatus;
var
  LNeeded: TAefosVisualState;
  LActive: Boolean;
begin
  // The state a session must have REACHED for this step to count as run, and
  // the state it is IN while the step is happening. For most steps they are the
  // same one; the pair is kept explicit so the mapping is readable rather than
  // clever.
  case AStep of
    vstCaptureBefore: LNeeded := vsCapturingBefore;
    vstScan:          LNeeded := vsScanning;
    vstOperate:       LNeeded := vsOperating;
    vstCaptureAfter:  LNeeded := vsCapturingAfter;
    vstVerify:        LNeeded := vsVerifying;
  else
    LNeeded := vsShowingComparison;
  end;

  LActive := (FState = LNeeded);
  // The comparison is the one step with a harder gate than "we got there": both
  // captures of THIS session must exist. Enforced here as well as in
  // HasComparisonPair, because this is the answer a viewer actually renders.
  if (AStep = vstCompare) and not HasComparisonPair then
  begin
    if IsTerminal or (FReached >= vsShowingComparison) then
      Exit(vssSkipped);
    Exit(vssPending);
  end;
  if LActive then
    Exit(vssActive);
  if FReached > LNeeded then
    Exit(vssDone);
  if FReached = LNeeded then
    // Reached it, no longer in it, and never went further: this is the step the
    // session stopped on. Failed says so; cancelled or timed out did not fail
    // the step, they ended the session while it was there.
    if FState = vsFailed then
      Exit(vssFailed)
    else if IsTerminal then
      Exit(vssSkipped)
    else
      Exit(vssDone);
  // Never reached. Pending only while the session can still get there.
  if IsTerminal then
    Exit(vssSkipped);
  Result := vssPending;
end;

class function TAefosVisualSession.StateToken(
  const AState: TAefosVisualState): string;
begin
  case AState of
    vsIdle:              Result := 'idle';
    vsCapturingBefore:   Result := 'capturing-before';
    vsScanning:          Result := 'scanning';
    vsReadyToOperate:    Result := 'ready-to-operate';
    vsWaitingPermission: Result := 'waiting-permission';
    vsOperating:         Result := 'operating';
    vsCapturingAfter:    Result := 'capturing-after';
    vsVerifying:         Result := 'verifying';
    vsShowingComparison: Result := 'showing-comparison';
    vsCompleted:         Result := 'completed';
    vsCancelled:         Result := 'cancelled';
    vsAbandoned:         Result := 'abandoned';
    vsTimedOut:          Result := 'timed-out';
  else
    Result := 'failed';
  end;
end;

class function TAefosVisualSession.StepToken(
  const AStep: TAefosVisualStep): string;
begin
  case AStep of
    vstCaptureBefore: Result := 'capture-before';
    vstScan:          Result := 'scan';
    vstOperate:       Result := 'operate';
    vstCaptureAfter:  Result := 'capture-after';
    vstVerify:        Result := 'verify';
  else
    Result := 'compare';
  end;
end;

class function TAefosVisualSession.StatusToken(
  const AStatus: TAefosVisualStepStatus): string;
begin
  case AStatus of
    vssPending: Result := 'pending';
    vssActive:  Result := 'active';
    vssDone:    Result := 'done';
    vssFailed:  Result := 'failed';
  else
    Result := 'skipped';
  end;
end;

function TAefosVisualSession.ToJson: string;
var
  LStep: TAefosVisualStep;
  LSteps: string;

  // Minimal, local, and enough: the only arbitrary text in this payload is
  // Detail. Backslash FIRST -- escaping it after the quote would re-escape the
  // backslashes the quote step just added.
  function _Esc(const AText: string): string;
  begin
    Result := StringReplace(AText, '', '\', [rfReplaceAll]);
    Result := StringReplace(Result, '"', '\"', [rfReplaceAll]);
    Result := StringReplace(Result, #13, ' ', [rfReplaceAll]);
    Result := StringReplace(Result, #10, ' ', [rfReplaceAll]);
    Result := StringReplace(Result, #9, ' ', [rfReplaceAll]);
  end;

begin
  LSteps := '';
  for LStep := Low(TAefosVisualStep) to High(TAefosVisualStep) do
  begin
    if LSteps <> '' then
      LSteps := LSteps + ',';
    LSteps := LSteps + '{"k":"' + StepToken(LStep) + '","t":"' +
      _Esc(StepText(LStep)) + '","s":"' + StatusToken(StepStatus(LStep)) + '"}';
  end;
  // `analysing` is emitted so the viewer never has to decide for itself whether
  // something is genuinely running -- the one question an animation must not
  // answer on its own.
  Result :=
    '{"id":"' + _Esc(FSessionId) + '"' +
    ',"state":"' + StateToken(FState) + '"' +
    ',"status":"' + _Esc(StatusText(FState)) + '"' +
    ',"analysing":' + LowerCase(BoolToStr(IsAnalysing, True)) +
    ',"terminal":' + LowerCase(BoolToStr(IsTerminal, True)) +
    ',"pair":' + LowerCase(BoolToStr(HasComparisonPair, True)) +
    ',"before":"' + _Esc(FBeforeImageId) + '"' +
    ',"after":"' + _Esc(FAfterImageId) + '"' +
    ',"detail":"' + _Esc(FLastDetail) + '"' +
    ',"steps":[' + LSteps + ']}';
end;

class function TAefosVisualSession.StepText(
  const AStep: TAefosVisualStep): string;
begin
  case AStep of
    vstCaptureBefore: Result := 'Capture the screen';
    vstScan:          Result := 'Find the controls';
    vstOperate:       Result := 'Operate the app';
    vstCaptureAfter:  Result := 'Capture the result';
    vstVerify:        Result := 'Verify the change';
  else
    Result := 'Compare before and after';
  end;
end;

class function TAefosVisualSession.StatusText(
  const AState: TAefosVisualState): string;
begin
  case AState of
    vsIdle: Result := 'Ready';
    vsCapturingBefore: Result := 'Capturing the interface';
    vsScanning: Result := 'Analysing the captured interface';
    vsReadyToOperate: Result := 'Analysis complete';
    vsWaitingPermission: Result := 'Waiting for your authorization';
    vsOperating: Result := 'Agent operating';
    vsCapturingAfter: Result := 'Capturing the result';
    vsVerifying: Result := 'Verifying the result';
    vsShowingComparison: Result := 'Comparing before and after';
    vsCompleted: Result := 'Done';
    vsCancelled: Result := 'Cancelled';
    vsAbandoned: Result := 'Stopped when the turn ended';
    vsTimedOut: Result := 'Timed out';
    vsFailed: Result := 'Failed';
  else
    Result := '';
  end;
end;

end.
