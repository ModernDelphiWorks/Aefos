unit Aefos.MCP.FlowGuide;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  Deterministic flow management at the MCP choke point, the sibling of
  Aefos.MCP.IntentGuard. Where the IntentGuard guards the VIEW (RULE #1 — a design/code
  command must run in the matching view), FlowGuide guards the SAVE STATE.

  It hosts the SaveAllFiles guard: saving at the wrong moment is destructive — the Delphi
  IDE (not the agent) then clears unresolved ✓/✗ review gutters (auto-accept) and/or strips
  a .dfm event wired to a handler that does not exist yet. The guard makes the SAVE refuse
  before it can do damage, with an actionable next-prompt, so the agent is never blamed for
  the IDE's behaviour. This is the "loop-engineering" guide half: the tool result IS the
  next prompt — the rejection carries the next valid step.

  Core stays OTA-free: the OTA host injects the save state through IMCPFlowState
  (SaveAllFilesGuardReason); this unit only decides and phrases. Strings are English-only
  and terse (they ship on every rejection).
}

interface

type
  // The facade-side seam an OTA-FREE host reads the save state through: the host
  // queries the injected facade for this interface (Supports) and reads it, so it
  // never touches ToolsAPI itself. Mirrors how the view read flows through
  // IMCPWorkspaceFacade.CurrentIdeViewIntent — but on a SEPARATE interface so the
  // Core-frozen IMCPWorkspaceFacade is never modified. The terminal host uses this;
  // the plugin host can too (symmetry with the view read).
  IMCPFlowState = interface
    ['{9B4D2E71-3A6C-4F58-8E0D-1C7B5A9E2D60}']
    // SaveAllFiles guard: '' when the save is safe, else an actionable refusal message.
    // Saving at the wrong moment is destructive — the Delphi IDE (not the agent) then
    // clears unresolved ✓/✗ gutters (auto-accept) and/or strips a .dfm event wired to a
    // handler that does not exist yet. The guard makes the SAVE refuse so the agent is
    // never blamed for the IDE's behaviour. Main-thread read (touches OTA review state).
    function SaveAllFilesGuardReason: string;
  end;

const
  // SaveAllFiles guard reason code (the save is refused before it can do damage).
  MCP_REASON_SAVE_BLOCKED = 'save-blocked';

const
  // PAS<->DFM desync guard reason code (the wholesale write is refused before it
  // can desync the form class from the .dfm object tree).
  MCP_REASON_PAS_DFM_DESYNC = 'pas-dfm-desync';

const
  // "Building a form in CODE" guard reason code: a wholesale/anchored .pas write
  // is refused because the source CREATES a STANDARD LCL/VCL control in code and
  // parents it — that control MUST be born through the Form Designer (AddComponent),
  // never hand-written. RULE #1 doctrine: "NEVER build a form off the Designer."
  MCP_REASON_CODE_BUILDS_UI = 'code-builds-ui';

type
  // Deterministic save/flow decisions as a sealed static namespace: phrase the
  // save-guard refusals + advisory next-prompts and run the pure PAS<->DFM desync
  // heuristics. Never instantiated (the class is the namespace). All pure string
  // logic — the OTA host feeds the live .dfm/.pas.
  TFlowGuide = class sealed
  public
    // SaveAllFiles guard, V1 phrasing: refused because unresolved ✓/✗ review gutters exist
    // (a save would auto-accept + clear them). Tells the agent to resolve the calha first —
    // never to "save anyway". English + terse.
    class function SavePendingReviewMessage: string; static;

    // Advisory next-prompt (the loop's GUIDE half): on a tool's SUCCESS the server appends
    // this terse hint to the result, conducting the agent to the natural next step of the
    // Delphi Design<->Code flow instead of betting it KNOWS the flow. Returns '' for tools
    // with no transition worth signposting (most tools). Unlike the guard refusals (enforcing
    // = law) this is ADVISORY: a strong agent may ignore it, a weak agent follows it. It NEVER
    // advises SaveAllFiles — the user saves; an agent save can clear pending review gutters and
    // strip dangling event wires. Single curated source, applied centrally in the server
    // (mirrors how RULE #1's suffix rides every tool description). English + terse.
    class function NextPromptFor(const AToolName: string): string; static;

    // --- SaveAllFiles guard V2: the "wired event without a handler" hazard ---------------
    // Pure heuristic (OTA-free string logic; the OTA host feeds the live .dfm + .pas). Saving
    // a form whose .dfm wires an event to a handler that is not in the code yet lets the Delphi
    // IDE STRIP the wiring — so the guard refuses. Headless-tested.

    // Handler names wired to events in a .dfm — lines like `OnClick = btnXClick`: the property
    // must be On<UpperLetter>… and its value a bare identifier (a method name, never a literal).
    class function ExtractWiredEvents(const ADfm: string): TArray<string>; static;

    // True when AHandler occurs as a WHOLE WORD in the .pas (its method decl/impl) — a cheap,
    // robust "the handler exists" proxy.
    class function HasHandlerMethod(const APas, AHandler: string): Boolean; static;

    // The save-guard V2 reason: '' when every wired event has a handler in APas, else an
    // actionable message naming the first dangling handler. Never advises SaveAllFiles.
    class function DanglingHandlerReason(const ADfm, APas: string): string; static;

    // --- PAS<->DFM desync guard: the "bulk write that builds a broken form" hazard -------
    // Pure heuristic (OTA-free string logic; the OTA host feeds the live .dfm + .pas).
    // The two WHOLESALE writers (SetDFMContent / SetEditorFullContent) can desync the
    // .pas class from the .dfm object tree — the IDE then errors ("declaration of X does
    // not exist") or strips the objects. Their descriptions already say "this is NOT how
    // you build a form"; these guards make the command ENFORCE it (RULE #1 philosophy:
    // descriptions tell, guards enforce). Headless-tested.

    // Component names of `object Name: TType` block openers in a text DFM, EXCLUDING the
    // first opener (the form root — object/inherited/inline alike). `inherited`/`inline`
    // child blocks are skipped: their fields belong to an ancestor form or a frame class,
    // which THIS unit's source cannot verify (the guard stays false-positive-free).
    class function ExtractDfmComponents(const ADfm: string): TArray<string>; static;

    // SetDFMContent guard: '' when every component in ANewDfm is mentioned (whole-word)
    // in APas, else an actionable refusal naming the undeclared ones and steering the
    // agent to AddComponent — the signature of building a form via a bulk DFM write.
    class function DfmUndeclaredComponentsReason(const ANewDfm, APas: string): string; static;

    // SetEditorFullContent guard (the mirror direction): '' when ANewPas keeps a
    // whole-word mention of every component on the live form's ADfm, else an actionable
    // refusal — a wholesale source rewrite must never drop Designer-managed fields.
    class function SourceDropsComponentsReason(const ADfm, ANewPas: string): string; static;

    // SetDFMContent guard #2 (its-own-guardian, RULE #1): a NEW control enters a form
    // ONLY through AddComponent (it sprouts LIVE in the Form Designer, where the user
    // watches it appear). '' when every component in ANewDfm already exists on the LIVE
    // form (ALiveDfm) — SetDFMContent may then only reposition/restyle them — else an
    // actionable refusal naming the ones a bulk .dfm would create OFF-Designer, steering
    // the agent to AddComponent. This closes the bypass of declaring the fields in the
    // .pas first (which makes the pas<->dfm desync guard pass) and then slamming the .dfm.
    class function DfmAddsUndesignedComponentsReason(const ANewDfm, ALiveDfm: string): string; static;

    // --- "Build a form in CODE" guard: the RULE #1 hard brake on the .pas side ----------
    // Pure heuristic (OTA-free string logic; the caller feeds the PROPOSED .pas source).
    // A NEW standard control enters a form ONLY through the Designer (AddComponent), where
    // it sprouts LIVE and the IDE declares its field — the agent NEVER hand-writes a
    // control in code. This guard makes the .pas write ENFORCE that (RULE #1: descriptions
    // tell, guards enforce), the mirror of the DFM-side DfmAddsUndesignedComponentsReason.
    //
    // HARD-BLOCK: '' when the source builds no standard control in code, else an actionable
    // refusal naming the offending control type(s) and steering to OpenFormDesigner ->
    // AddComponent -> SetComponentProperty -> AddEventHandler. It fires ONLY when a
    // BLOCKLISTED standard LCL/VCL control type (TEdit, TButton, TPanel, ...) is BOTH
    // created (`TType.Create(`) AND parented (`.Parent :=`) inside a FORM method (or global
    // scope). It DOES NOT fire for a type DECLARED locally in this same unit (a
    // custom-painted `TIconButton = class(TCustomControl)` cannot be built in the Designer)
    // NOR for a control created inside a locally-declared custom-control's OWN method
    // (composing a custom control's internals — e.g. the TEdit a TFieldBox owns — is
    // legitimate; only the Designer-managed FORM is guarded). Headless-tested.
    class function SourceBuildsStandardControlsInCodeReason(const ASource: string): string; static;
  end;

implementation

uses
  SysUtils;

// Newline-normalising line split (replaces the Delphi-only
// `S.Replace(...).Split([#10])` fluent-helper chain, which FPC 3.2.2's RTL does
// not provide). Behaviour matches TStringHelper.Split with no options,
// INCLUDING the edges — proven empirically on the real RTL (D13): Split('')
// yields an EMPTY array; a trailing newline yields a trailing empty line;
// adjacent separators keep their empty middle element.
function _SplitTextLines(const AText: string): TArray<string>;
var
  LNorm: string;
  LIndex, LStart, LCount: Integer;
begin
  SetLength(Result, 0);
  if AText = '' then
    Exit;
  LNorm := StringReplace(AText, #13#10, #10, [rfReplaceAll]);
  LNorm := StringReplace(LNorm, #13, #10, [rfReplaceAll]);
  LCount := 0;
  LStart := 1;
  for LIndex := 1 to Length(LNorm) do
    if LNorm[LIndex] = #10 then
    begin
      SetLength(Result, LCount + 1);
      Result[LCount] := Copy(LNorm, LStart, LIndex - LStart);
      Inc(LCount);
      LStart := LIndex + 1;
    end;
  SetLength(Result, LCount + 1);
  Result[LCount] := Copy(LNorm, LStart, Length(LNorm) - LStart + 1);
end;

class function TFlowGuide.SavePendingReviewMessage: string;
begin
  Result := MCP_REASON_SAVE_BLOCKED +
    ': there are unresolved review gutters (pending ✓/✗) — approve or reject them ' +
    'first. Saving now would auto-accept and clear the pending diffs.';
end;

class function TFlowGuide.NextPromptFor(const AToolName: string): string;
begin
  Result := '';
  if SameText(AToolName, 'AddComponent') then
    Result := 'next: add the next control (stays in Design) — ALWAYS pass its Parent: ' +
      'the container it nests in (a panel/group-box), or the form''s own name for a ' +
      'top-level control, so nothing lands invisibly behind another control. Use ' +
      'CaptureForm to SEE the layout and fix mistakes. Wire events with ' +
      'AddEventHandler; to write code, switch with OpenUnitInEditor (Code).'
  else if SameText(AToolName, 'AddEventHandler') then
    Result := 'next: fill the handler body with EditUnit — call OpenUnitInEditor first ' +
      'to switch to Code.'
  else if SameText(AToolName, 'CreateProjectVCL')
       or SameText(AToolName, 'CreateProjectFMX') then
    Result := 'next: AddComponent to start building the form (stays in Design). Every ' +
      'AddComponent REQUIRES a Parent — pass a container (panel/group-box) to nest ' +
      'inside it, or the form''s own name for a top-level control.'
  // --- Debugger navigation: the tools say WHAT each key does; these teach HOW to
  // WALK a debug session (which key when + the async poll contract), the step even
  // some developers miss. The cheat-sheet rides the run/continue result (where the
  // agent starts navigating); the step tools carry the async-poll reminder.
  else if SameText(AToolName, 'SetBreakpoint') then
    Result := 'next: set breakpoints at the lines you want to inspect, then ' +
      'RunProject (or ContinueRun if already running) and poll GetDebugState until ' +
      'it shows "stopped-at unit:line". To reach a SPECIFIC state fast instead of ' +
      'stepping by hand, pass a "condition" (stops only when the Delphi boolean is ' +
      'true, e.g. i = 5 or Total > 100 or edtNome.Text = '''') or "passCount" (skip ' +
      'N passes) — the app runs until that exact state is hit.'
  else if SameText(AToolName, 'RunProject')
       or SameText(AToolName, 'ContinueRun') then
    Result := 'next: poll GetDebugState — "running" = no breakpoint hit yet, ' +
      '"stopped-at unit:line" = it stopped. AT A STOP: InspectLocals and ' +
      'EvaluateExpression(<expr>) read the live state; GetCallStack shows the ' +
      'callers. NAVIGATE from there: StepOver (F8) = run the current line and stop ' +
      'on the next; StepInto (F7) = step INTO the call on this line; StepOut ' +
      '(Shift+F8) = run to the caller; ContinueRun (F9) = run to the next ' +
      'breakpoint. Each step is ASYNC — poll GetDebugState again for the new line.'
  else if SameText(AToolName, 'StepOver') or SameText(AToolName, 'StepInto')
       or SameText(AToolName, 'StepOut') or SameText(AToolName, 'RunToLine')
       or SameText(AToolName, 'PauseRun') then
    Result := 'next: the step is ASYNC (it returned dispatched, not the new line) — ' +
      'poll GetDebugState for the settled "stopped-at unit:line", then inspect ' +
      '(InspectLocals / EvaluateExpression) or step again (StepOver F8 / StepInto ' +
      'F7 / StepOut Shift+F8 / ContinueRun F9).'
  else if SameText(AToolName, 'GetDebugState') then
    Result := 'if stopped: inspect (InspectLocals, EvaluateExpression, GetCallStack) ' +
      'or move (StepOver F8, StepInto F7, StepOut Shift+F8, ContinueRun F9). Remove ' +
      'breakpoints with RemoveBreakpoint and end with StopProject when done.';
end;

// True when S is a valid Pascal identifier (first char letter/_, rest alnum/_).
function _IsIdent(const S: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  if S = '' then Exit;
  if not CharInSet(S[1], ['A'..'Z', 'a'..'z', '_']) then Exit;
  for I := 2 to Length(S) do
    if not CharInSet(S[I], ['A'..'Z', 'a'..'z', '0'..'9', '_']) then Exit;
  Result := True;
end;

class function TFlowGuide.ExtractWiredEvents(const ADfm: string): TArray<string>;
var
  LLines: TArray<string>;
  LLine, LName, LValue: string;
  LEq, LCount: Integer;
begin
  SetLength(Result, 0);
  LCount := 0;
  LLines := _SplitTextLines(ADfm);
  for LLine in LLines do
  begin
    LEq := Pos('=', LLine);
    if LEq < 1 then
      Continue;
    LName := Trim(Copy(LLine, 1, LEq - 1));
    // Event property: On<UpperLetter> + identifier (filters non-events like "Only...").
    if (Length(LName) < 3) or (LName[1] <> 'O') or (LName[2] <> 'n') then
      Continue;
    if not CharInSet(LName[3], ['A'..'Z']) then
      Continue;
    if not _IsIdent(LName) then
      Continue;
    // The wired handler is a BARE identifier (a method name); a literal value (quoted
    // string, number, set, etc.) is an ordinary property, not an event wire.
    LValue := Trim(Copy(LLine, LEq + 1, Length(LLine)));
    if not _IsIdent(LValue) then
      Continue;
    SetLength(Result, LCount + 1);
    Result[LCount] := LValue;
    Inc(LCount);
  end;
end;

class function TFlowGuide.HasHandlerMethod(const APas, AHandler: string): Boolean;
const
  CIdent = ['A'..'Z', 'a'..'z', '0'..'9', '_'];
var
  LPos, LHLen, LLen: Integer;
begin
  Result := False;
  if (APas = '') or (AHandler = '') then
    Exit;
  LHLen := Length(AHandler);
  LLen := Length(APas);
  LPos := Pos(AHandler, APas);
  while LPos > 0 do
  begin
    if ((LPos = 1) or not CharInSet(APas[LPos - 1], CIdent))
       and ((LPos + LHLen > LLen) or not CharInSet(APas[LPos + LHLen], CIdent)) then
      Exit(True);
    LPos := Pos(AHandler, APas, LPos + LHLen);
  end;
end;

class function TFlowGuide.DanglingHandlerReason(const ADfm, APas: string): string;
var
  LEvents: TArray<string>;
  LH: string;
begin
  Result := '';
  LEvents := TFlowGuide.ExtractWiredEvents(ADfm);
  for LH in LEvents do
    if not TFlowGuide.HasHandlerMethod(APas, LH) then
      Exit(MCP_REASON_SAVE_BLOCKED +
        ': the form wires event handler "' + LH + '" but it is not in the code yet — ' +
        'add the handler first; saving now lets the IDE strip the wiring.');
end;

// True when ALine (already trimmed) opens a DFM block; APayload = the `Name: Type`
// right-hand side; AIsObject distinguishes `object` from `inherited`/`inline`.
function _IsDfmBlockOpener(const ALine: string; out APayload: string;
  out AIsObject: Boolean): Boolean;

  function _StripPrefix(const APrefix: string): Boolean;
  begin
    Result := SameText(Copy(ALine, 1, Length(APrefix)), APrefix);
    if Result then
      APayload := Copy(ALine, Length(APrefix) + 1, MaxInt);
  end;

begin
  APayload := '';
  AIsObject := _StripPrefix('object ');
  Result := AIsObject or _StripPrefix('inherited ') or _StripPrefix('inline ');
end;

class function TFlowGuide.ExtractDfmComponents(const ADfm: string): TArray<string>;
var
  LLines: TArray<string>;
  LLine, LPayload, LName: string;
  LIsObject, LSeenRoot: Boolean;
  LColon, LCount: Integer;
begin
  SetLength(Result, 0);
  LCount := 0;
  LSeenRoot := False;
  LLines := _SplitTextLines(ADfm);
  for LLine in LLines do
  begin
    if not _IsDfmBlockOpener(Trim(LLine), LPayload, LIsObject) then
      Continue;
    // The first opener is the form root (object OR inherited/inline) — never a field.
    if not LSeenRoot then
    begin
      LSeenRoot := True;
      Continue;
    end;
    // Only `object`-opened children are fields THIS unit's class must declare;
    // inherited/inline children belong to an ancestor form / frame class.
    if not LIsObject then
      Continue;
    LColon := Pos(':', LPayload);
    if LColon <= 1 then
      Continue;
    LName := Trim(Copy(LPayload, 1, LColon - 1));
    if not _IsIdent(LName) then
      Continue;
    SetLength(Result, LCount + 1);
    Result[LCount] := LName;
    Inc(LCount);
  end;
end;

// Comma list of ADfm components with NO whole-word mention in APas ('' when none).
// TFlowGuide.HasHandlerMethod is a general whole-word identifier probe — same cheap, robust
// proxy the save-guard uses: a component the source never even NAMES is certain desync.
function _MissingDfmComponents(const ADfm, APas: string): string;
var
  LName: string;
begin
  Result := '';
  for LName in TFlowGuide.ExtractDfmComponents(ADfm) do
    if not TFlowGuide.HasHandlerMethod(APas, LName) then
      if Result = '' then
        Result := LName
      else
        Result := Result + ', ' + LName;
end;

class function TFlowGuide.DfmUndeclaredComponentsReason(const ANewDfm, APas: string): string;
var
  LMissing: string;
begin
  Result := '';
  LMissing := _MissingDfmComponents(ANewDfm, APas);
  if LMissing = '' then
    Exit;
  Result := MCP_REASON_PAS_DFM_DESYNC +
    ': the .dfm declares component(s) the form class does not — ' + LMissing +
    '. Writing it would desync .pas<->.dfm (the IDE errors "declaration not found" ' +
    'and strips the objects). Do NOT build a form by writing the whole .dfm: call ' +
    'AddComponent for EACH control (the IDE declares the field and it appears live ' +
    'in the Designer), then SetComponentProperty / AddEventHandler.';
end;

class function TFlowGuide.SourceDropsComponentsReason(const ADfm, ANewPas: string): string;
var
  LMissing: string;
begin
  Result := '';
  LMissing := _MissingDfmComponents(ADfm, ANewPas);
  if LMissing = '' then
    Exit;
  Result := MCP_REASON_PAS_DFM_DESYNC +
    ': the new source drops Designer-managed component field(s) still on the live ' +
    'form — ' + LMissing + '. Writing it would desync .pas<->.dfm (the IDE errors ' +
    '"declaration not found" and strips the objects). Keep every component field ' +
    'the Designer declared; to remove a control call RemoveComponent, and for ' +
    'incremental code changes use EditUnit.';
end;

// Comma list of ANewDfm components with NO whole-word mention in ALiveDfm ('' when
// none) — i.e. controls the incoming .dfm would ADD relative to the live form.
function _ComponentsNotOnLiveForm(const ANewDfm, ALiveDfm: string): string;
var
  LName: string;
begin
  Result := '';
  for LName in TFlowGuide.ExtractDfmComponents(ANewDfm) do
    if not TFlowGuide.HasHandlerMethod(ALiveDfm, LName) then
      if Result = '' then
        Result := LName
      else
        Result := Result + ', ' + LName;
end;

class function TFlowGuide.DfmAddsUndesignedComponentsReason(const ANewDfm,
  ALiveDfm: string): string;
var
  LAdded: string;
begin
  Result := '';
  LAdded := _ComponentsNotOnLiveForm(ANewDfm, ALiveDfm);
  if LAdded = '' then
    Exit;
  Result := MCP_REASON_PAS_DFM_DESYNC +
    ': this .dfm would create control(s) that are NOT on the live form — ' + LAdded +
    '. A NEW control may enter a form ONLY through AddComponent, which creates it ' +
    'LIVE in the Form Designer (the user watches it appear) and lets the IDE declare ' +
    'its field automatically — the agent never writes component code by hand. ' +
    'SetDFMContent may ONLY reposition / restyle controls that already exist. Call ' +
    'AddComponent for EACH new control, then SetComponentProperty / AddEventHandler.';
end;

// --- "Build a form in CODE" guard helpers ------------------------------------------------

// Standard LCL/VCL control types a form must NOT create in code — they belong in the
// Designer (AddComponent). LCL and VCL share these class names, so one blocklist covers
// both editions. Compared case-insensitively (SameText) as whole type tokens.
const
  CStandardControlBlocklist: array[0..30] of string = (
    'TEdit', 'TButton', 'TBitBtn', 'TSpeedButton', 'TLabel', 'TStaticText',
    'TMemo', 'TComboBox', 'TCheckBox', 'TRadioButton', 'TListBox', 'TCheckListBox',
    'TStringGrid', 'TDBGrid', 'TPanel', 'TGroupBox', 'TPageControl', 'TTabSheet',
    'TImage', 'TShape', 'TScrollBox', 'TTrackBar', 'TProgressBar', 'TRadioGroup',
    'TSpinEdit', 'TDateEdit', 'TColorButton', 'TToggleBox', 'TValueListEditor',
    'TTreeView', 'TListView');

// True when AType is one of the blocklisted standard control class names.
function _IsBlocklistedControl(const AType: string): Boolean;
var
  LIdx: Integer;
begin
  Result := False;
  for LIdx := Low(CStandardControlBlocklist) to High(CStandardControlBlocklist) do
    if SameText(AType, CStandardControlBlocklist[LIdx]) then
      Exit(True);
end;

// True when AName is one of AList's entries (case-insensitive whole-string match).
function _InStrList(const AList: TArray<string>; const AName: string): Boolean;
var
  LItem: string;
begin
  Result := False;
  for LItem in AList do
    if SameText(LItem, AName) then
      Exit(True);
end;

procedure _AppendUnique(var AList: TArray<string>; const AName: string);
begin
  if AName = '' then
    Exit;
  if _InStrList(AList, AName) then
    Exit;
  SetLength(AList, Length(AList) + 1);
  AList[High(AList)] := AName;
end;

// A form-like base class: a locally-declared descendant of one of these is a Designer
// FORM whose UI is guarded (its code must NOT build standard controls).
function _IsFormLikeAncestor(const AName: string): Boolean;
begin
  Result := SameText(AName, 'TForm') or SameText(AName, 'TCustomForm')
    or SameText(AName, 'TFrame') or SameText(AName, 'TCustomFrame')
    or SameText(AName, 'TDataModule') or SameText(AName, 'TCustomDataModule');
end;

// A control base class: a locally-declared descendant of one of these (i.e. a
// custom-painted control) is a legitimate composition scope — code INSIDE its own
// methods may create/parent controls (it cannot be built in the Designer).
function _IsControlAncestor(const AName: string): Boolean;
begin
  Result := SameText(AName, 'TControl') or SameText(AName, 'TWinControl')
    or SameText(AName, 'TCustomControl') or SameText(AName, 'TGraphicControl')
    or SameText(AName, 'TScrollingWinControl') or SameText(AName, 'TScrollBox');
end;

// Parses a `TIdent = class(TAncestor)` / `TIdent = class` declaration line. Returns
// True with AIdent/AAncestor when the (trimmed) line opens a class declaration. Guards
// against `class function` / `class procedure` (no `=` before `class`).
function _ParseClassDecl(const ALine: string; out AIdent, AAncestor: string): Boolean;
var
  LClassPos, LEqPos, LParen, LClose, LScan: Integer;
  LHead: string;
begin
  Result := False;
  AIdent := '';
  AAncestor := '';
  LClassPos := Pos('class', ALine);
  if LClassPos < 1 then
    Exit;
  // The token before `class` (skipping spaces) must be `=` (a type decl), never a
  // `class function` / `class procedure` modifier.
  LScan := LClassPos - 1;
  while (LScan >= 1) and (ALine[LScan] = ' ') do
    Dec(LScan);
  if (LScan < 1) or (ALine[LScan] <> '=') then
    Exit;
  LEqPos := LScan;
  LHead := Trim(Copy(ALine, 1, LEqPos - 1));
  // The head is `TIdent` or `type TIdent` (single-line decl) or `TIdent<T>`; take the
  // LAST identifier run so a leading `type ` keyword / generic tail does not defeat it.
  LScan := Length(LHead);
  while (LScan >= 1)
    and CharInSet(LHead[LScan], ['A'..'Z', 'a'..'z', '0'..'9', '_']) do
    Dec(LScan);
  LHead := Copy(LHead, LScan + 1, MaxInt);
  if not _IsIdent(LHead) then
    Exit;
  AIdent := LHead;
  Result := True;
  // Optional ancestor in parentheses after `class`.
  LParen := Pos('(', Copy(ALine, LClassPos, MaxInt));
  if LParen > 0 then
  begin
    LParen := LClassPos + LParen - 1;   // absolute
    LClose := LParen + 1;
    while (LClose <= Length(ALine)) and (ALine[LClose] <> ')')
      and (ALine[LClose] <> ',') do
      Inc(LClose);
    AAncestor := Trim(Copy(ALine, LParen + 1, LClose - LParen - 1));
  end;
end;

// The type token immediately before a `.Create(` whose dot is at AAt (walks back
// over identifier chars). '' when no identifier precedes the dot.
function _CreateTypeBefore(const ALine: string; const AAt: Integer): string;
var
  LEnd, LStart: Integer;
begin
  Result := '';
  if (AAt < 1) or (AAt > Length(ALine)) or (ALine[AAt] <> '.') then
    Exit;
  LEnd := AAt - 1;                       // last identifier char before the '.'
  LStart := LEnd;
  while (LStart >= 1)
    and CharInSet(ALine[LStart], ['A'..'Z', 'a'..'z', '0'..'9', '_']) do
    Dec(LStart);
  Result := Copy(ALine, LStart + 1, LEnd - LStart);
end;

// The assignment target left of `:=` on a line ('' when the line is not an assignment).
// Used as the receiver a creation binds to (e.g. `FEdit := TEdit.Create(Self)` -> FEdit).
function _AssignTargetOf(const ALine: string): string;
var
  LPos: Integer;
begin
  Result := '';
  LPos := Pos(':=', ALine);
  if LPos < 2 then
    Exit;
  Result := Trim(Copy(ALine, 1, LPos - 1));
end;

// True when the line assigns `<obj>.Parent := ...`; AObj = the last identifier segment
// before `.Parent` (e.g. `FEdit.Parent := Self` -> FEdit).
function _ParentAssignObject(const ALine: string; out AObj: string): Boolean;
var
  LPos, LAfter, LStart, LEnd: Integer;
begin
  Result := False;
  AObj := '';
  LPos := Pos('.Parent', ALine);
  if LPos < 1 then
    Exit;
  // Must be followed (past optional spaces) by `:=`, and `.Parent` must be a whole
  // word (next char not an identifier char, so `.ParentFont` is excluded).
  LAfter := LPos + Length('.Parent');
  if (LAfter <= Length(ALine))
    and CharInSet(ALine[LAfter], ['A'..'Z', 'a'..'z', '0'..'9', '_']) then
    Exit;
  while (LAfter <= Length(ALine)) and (ALine[LAfter] = ' ') do
    Inc(LAfter);
  if (LAfter + 1 > Length(ALine)) or (ALine[LAfter] <> ':')
    or (ALine[LAfter + 1] <> '=') then
    Exit;
  // A `.Parent :=` assignment IS present. Walk back over the simple identifier that
  // owns it (AObj); it may be empty when the owner is a complex expression, e.g.
  // `TPanel.Create(Self).Parent := X` — the caller then treats it as an inline build.
  LEnd := LPos - 1;
  LStart := LEnd;
  while (LStart >= 1)
    and CharInSet(ALine[LStart], ['A'..'Z', 'a'..'z', '0'..'9', '_']) do
    Dec(LStart);
  AObj := Copy(ALine, LStart + 1, LEnd - LStart);
  Result := True;
end;

// True when the (trimmed) line opens a method IMPLEMENTATION `<kw> TClass.Method` and
// returns the qualifying class in AClass. The `TClass.` qualifier appears only in the
// implementation (interface method decls are unqualified), so this reliably scopes code.
function _MethodImplClass(const ALine: string; out AClass: string): Boolean;
const
  CKeywords: array[0..3] of string = ('procedure', 'function', 'constructor', 'destructor');
var
  LKw, LRest, LClass: string;
  LKidx, LSpace, LDot: Integer;
begin
  Result := False;
  AClass := '';
  for LKidx := Low(CKeywords) to High(CKeywords) do
  begin
    LKw := CKeywords[LKidx];
    if not SameText(Copy(ALine, 1, Length(LKw) + 1), LKw + ' ') then
      Continue;
    LRest := Trim(Copy(ALine, Length(LKw) + 1, MaxInt));
    LDot := Pos('.', LRest);
    if LDot < 2 then
      Exit;                              // unqualified => an interface decl, not impl
    LClass := Copy(LRest, 1, LDot - 1);
    // A generic method impl `TFoo<T>.Bar` — trim any '<' tail; keep it simple.
    LSpace := Pos('<', LClass);
    if LSpace > 1 then
      LClass := Copy(LClass, 1, LSpace - 1);
    if not _IsIdent(LClass) then
      Exit;
    AClass := LClass;
    Exit(True);
  end;
end;

class function TFlowGuide.SourceBuildsStandardControlsInCodeReason(
  const ASource: string): string;
var
  LLines: TArray<string>;
  LLocalTypes, LControlScopes, LRecvNames, LRecvTypes, LViolations: TArray<string>;
  LIdent, LAncestor, LLine, LTrim, LType, LTarget, LObj, LClass, LList: string;
  LIdx, LCreatePos, LScan, LRi: Integer;
  LChanged, LScopeIsControl, LLineHasParent: Boolean;
begin
  Result := '';
  LLines := _SplitTextLines(ASource);

  // Pass 1: collect every locally-declared class + classify the composition scopes.
  // A local class is a "control scope" (its methods may build controls) when it
  // descends from a control base OR from another local control scope; a form-like
  // descendant is NEVER a control scope (its UI is Designer-guarded).
  for LLine in LLines do
    if _ParseClassDecl(Trim(LLine), LIdent, LAncestor) then
    begin
      _AppendUnique(LLocalTypes, LIdent);
      if (LAncestor <> '') and not _IsFormLikeAncestor(LAncestor)
        and (_IsControlAncestor(LAncestor) or _IsBlocklistedControl(LAncestor)) then
        _AppendUnique(LControlScopes, LIdent);
    end;
  // Fixpoint: propagate control-scope through local ancestry (a class deriving from a
  // local control scope is itself a control scope).
  repeat
    LChanged := False;
    for LLine in LLines do
      if _ParseClassDecl(Trim(LLine), LIdent, LAncestor) then
        if (LAncestor <> '') and not _IsFormLikeAncestor(LAncestor)
          and _InStrList(LControlScopes, LAncestor)
          and not _InStrList(LControlScopes, LIdent) then
        begin
          _AppendUnique(LControlScopes, LIdent);
          LChanged := True;
        end;
  until not LChanged;

  // Pass 2: walk the implementation, scoped by method. Inside a FORM (or global) scope
  // a blocklisted control that is created AND parented is a RULE #1 violation.
  LScopeIsControl := False;               // global scope until the first method opener
  SetLength(LRecvNames, 0);
  SetLength(LRecvTypes, 0);
  for LLine in LLines do
  begin
    LTrim := Trim(LLine);
    if _MethodImplClass(LTrim, LClass) then
    begin
      LScopeIsControl := _InStrList(LControlScopes, LClass);
      SetLength(LRecvNames, 0);           // receivers are per-method
      SetLength(LRecvTypes, 0);
      Continue;
    end;
    if LScopeIsControl then
      Continue;                           // composing a custom control's internals: OK

    LLineHasParent := _ParentAssignObject(LTrim, LObj);

    // Record creations of blocklisted, non-local types + detect inline parenting.
    LCreatePos := Pos('.Create(', LTrim);
    LScan := LCreatePos;
    while LScan > 0 do
    begin
      LType := _CreateTypeBefore(LTrim, LScan);
      if (LType <> '') and _IsBlocklistedControl(LType)
        and not _InStrList(LLocalTypes, LType) then
      begin
        LTarget := _AssignTargetOf(LTrim);
        if LTarget <> '' then
        begin
          SetLength(LRecvNames, Length(LRecvNames) + 1);
          SetLength(LRecvTypes, Length(LRecvTypes) + 1);
          LRecvNames[High(LRecvNames)] := LTarget;
          LRecvTypes[High(LRecvTypes)] := LType;
        end;
        // `TPanel.Create(Self).Parent := X` on ONE line: parent with no receiver var.
        if LLineHasParent and (LObj = '') then
          _AppendUnique(LViolations, LType);
      end;
      LScan := Pos('.Create(', LTrim, LScan + 1);
    end;

    // A `<recv>.Parent := ...` closes the loop on a recorded blocklisted creation.
    if LLineHasParent and (LObj <> '') then
      for LRi := 0 to High(LRecvNames) do
        if SameText(LRecvNames[LRi], LObj) then
          _AppendUnique(LViolations, LRecvTypes[LRi]);
  end;

  if Length(LViolations) = 0 then
    Exit;

  LList := '';
  for LIdx := 0 to High(LViolations) do
    if LList = '' then
      LList := LViolations[LIdx]
    else
      LList := LList + ', ' + LViolations[LIdx];
  Result := MCP_REASON_CODE_BUILDS_UI +
    ': this source BUILDS a form by creating standard control(s) in code and ' +
    'parenting them — ' + LList + '. That is NOT how you build a form: a NEW ' +
    'standard control enters a form ONLY through the Designer, where it sprouts ' +
    'LIVE and the IDE declares its field for you. Do it the Designer way: ' +
    'OpenFormDesigner, then AddComponent for EACH control (pass its parent), ' +
    'then SetComponentProperty for its state and AddEventHandler for its events. ' +
    '(Only genuinely custom-painted controls declared in this unit — e.g. ' +
    'TMyButton = class(TCustomControl) — may be created in code.)';
end;

end.
