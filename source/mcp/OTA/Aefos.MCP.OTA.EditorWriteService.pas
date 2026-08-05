unit Aefos.MCP.OTA.EditorWriteService;

{
  Editor buffer-write tools, extracted from the TMCPWorkspaceFacade god-object as a
  focused service of the SOLID split (audit S6 / facade split).

  Owns the four whole-buffer editor writes — EditUnit (anchored find/replace with the
  exactly-once contract), InsertCodeAtCursor, SetEditorFullContent and ReplaceInEditor
  — each of which routes through the change-review gate when an approver is registered
  and otherwise applies silently. No facade state (no FAudit), no public-method
  delegation: every dependency is drawn from an already-shared unit —
    - Aefos.Harness.View: WithLiveSource (the S2 seam — marshals, resolves the source
      editor, flips to Code per RULE #1, and exposes ReadBuffer/ReplaceWhole/RevealLine;
      the silent apply paths run inside it) + EnsureCodeView (the review pre-step flip)
    - FacadeShared: ActiveSourceEditor / ReadBytes (the review pre-step reads)
    - ReviewGate:   TReviewGate.GlobalDiffApprover / TReviewGate.ChangedSpan
    - ContentWritePolicy: ReplaceInBuffer / InsertTextAt (the pure text surgery)

  The inline-diff ddApplied/ddRejected/ddUnavailable handling and the anchored
  exactly-once semantics are identical to the original facade bodies; the silent
  fallbacks were migrated onto WithLiveSource (the hand-rolled Synchronize / resolve /
  EnsureCodeView / read / ReplaceWholeBuffer dance now lives once in the harness). The
  facade keeps its frozen IMCPWorkspaceFacade methods and delegates each to a
  refcounted FEditorWrite field.
}

interface

uses
  Aefos.MCP.Types;

type
  IMCPEditorWriteService = interface
    ['{7B3C1E94-5D86-4A20-9F47-2C6A1B5E8D40}']
    function EditUnit(const AUnitPath, AOldText, ANewText: string;
      out AError: string): TMCPEditOutcome;
    function InsertCodeAtCursor(const ACode: string): Boolean;
    function SetEditorFullContent(const ASource: string): Boolean;
    function ReplaceInEditor(const AFind, AReplace: string; const AAll: Boolean;
      out ACount: Integer): Boolean;
  end;

// Factory — the facade calls this once in its constructor.
function NewMCPEditorWriteService: IMCPEditorWriteService;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  ToolsAPI,
  Aefos.Harness.View,
  Aefos.MCP.FlowGuide,        // TFlowGuide.SourceDropsComponentsReason (pas<->dfm desync guard)
  Aefos.MCP.OTA.FacadeShared,
  Aefos.MCP.OTA.ReviewGate,
  Aefos.MCP.OTA.ContentWritePolicy;

type
  TMCPEditorWriteService = class(TInterfacedObject, IMCPEditorWriteService)
  public
    function EditUnit(const AUnitPath, AOldText, ANewText: string;
      out AError: string): TMCPEditOutcome;
    function InsertCodeAtCursor(const ACode: string): Boolean;
    function SetEditorFullContent(const ASource: string): Boolean;
    function ReplaceInEditor(const AFind, AReplace: string; const AAll: Boolean;
      out ACount: Integer): Boolean;
  end;

function TMCPEditorWriteService.EditUnit(const AUnitPath, AOldText,
  ANewText: string; out AError: string): TMCPEditOutcome;
var
  LOutcome: TMCPEditOutcome;
  LError, LDiffReason: string;
  LApprover: IMCPDiffApprover;
  LChanged: Boolean;
begin
  LOutcome := eoUnitNotOpen;
  LError   := '';
  LDiffReason := '';
  // Inline diff approval (ESP 2026-06-10): if an approver is registered, route
  // the change through the red/green editor diff. ddApplied => the approver
  // already applied it via the editor; ddRejected => leave the buffer untouched;
  // ddUnavailable => fall through to the silent anchored apply below.
  LApprover := TReviewGate.GlobalDiffApprover;
  if Assigned(LApprover) then
  begin
    case LApprover.ReviewEdit(AUnitPath, AOldText, ANewText, LDiffReason) of
      ddApplied:
        begin
          AError := '';
          Exit(eoApplied);
        end;
      ddRejected:
        begin
          // Surface the user's note to the agent so it learns WHY (not just that)
          // the edit was refused.
          if LDiffReason <> '' then
            AError := 'change rejected by the user in the inline diff: '
              + LDiffReason
          else
            AError := 'change rejected by the user in the inline diff';
          Exit(eoUserRejected);
        end;
    end;
  end;
  // EditUnit always targets a REAL unit path. The seam's blank-name contract
  // resolves the ACTIVE editor, but the old TFacadeShared.FindSourceForPath('') simply failed
  // to eoUnitNotOpen — preserve that exactly, so a blank path never anchor-edits
  // whatever editor happens to be active.
  if Trim(AUnitPath) = '' then
  begin
    AError := '';
    Exit(eoUnitNotOpen);
  end;
  // Silent anchored apply via the WithLiveSource seam (S2). The seam resolves the
  // unit's source editor BY PATH and flips to Code; this work enforces the
  // exactly-once anchor contract (ReplaceInBuffer all-mode count) and replaces the
  // buffer. LOutcome (captured) carries the precise result and is the function's
  // return — the seam's Boolean is ignored. An inner try/except preserves the old
  // behaviour of surfacing an exception's message in AError. (The seam adds a
  // bare-name `.pas` retry over the old FindModule(path); for a real path the
  // resolution is identical, so this only makes a bare unit name MORE resolvable.)
  THarnessView.WithLiveSource(AUnitPath, lsCodeMutation,
    procedure(const Ctx: ILiveSourceContext)
    var
      LBody, LNew: string;
      LCount: Integer;
    begin
      try
        LBody := Ctx.ReadBuffer;
        // Count occurrences (ReplaceInBuffer all-mode) to enforce the
        // exactly-once anchor contract before mutating.
        if not TContentWritePolicy.ReplaceInBuffer(LBody, AOldText, '', True, LNew, LCount) then
        begin
          LOutcome := eoAnchorNotFound; // empty anchor — nothing to match
          Exit;
        end;
        if LCount = 0 then
        begin
          LOutcome := eoAnchorNotFound;
          Exit;
        end;
        if LCount > 1 then
        begin
          LOutcome := eoAnchorAmbiguous;
          Exit;
        end;
        TContentWritePolicy.ReplaceInBuffer(LBody, AOldText, ANewText, False, LNew, LCount);
        if not Ctx.ReplaceWhole(LNew) then
        begin
          LOutcome := eoUnitNotOpen;
          Exit;
        end;
        LOutcome := eoApplied;
      except
        on E: Exception do
        begin
          LOutcome := eoUnitNotOpen;
          LError   := E.Message;
        end;
      end;
    end,
    LChanged, LDiffReason);
  AError := LError;
  Result := LOutcome;
end;

function TMCPEditorWriteService.InsertCodeAtCursor(
  const ACode: string): Boolean;
var
  LApprover: IMCPDiffApprover;
  LActivePath, LOldBlock, LNewBlock, LWholeOld, LNewWhole, LDiffReason: string;
  LChanged, LOk: Boolean;
  LRevealLine: Integer;
begin
  // Inline diff review (R6 — parity with EditUnit/SetEditorFullContent/ReplaceInEditor):
  // splice the code at the caret UP FRONT and route the resulting whole-buffer change
  // through the red/green diff, instead of applying silently. Without this, one
  // allow-for-session turned every later InsertCodeAtCursor into an invisible edit
  // while its siblings still showed a diff. TReviewGate.ChangedSpan reduces old->new to one
  // contiguous before/after block; ddUnavailable falls through to the direct apply.
  LDiffReason := '';
  LNewWhole := '';
  LWholeOld := '';
  LActivePath := '';
  LOldBlock := '';
  LNewBlock := '';
  LRevealLine := 0;
  LOk := False;
  TThread.Synchronize(nil, procedure
  var
    LES: IOTAEditorServices;
    LView: IOTAEditView;
    LEditor: IOTASourceEditor;
    LPos: TOTAEditPos;
    LCurrent: string;
  begin
    if not TFacadeShared.ActiveSourceEditor(LEditor) then Exit;
    if not Supports(BorlandIDEServices, IOTAEditorServices, LES) then Exit;
    LView := LES.TopView;
    if not Assigned(LView) then Exit;
    THarnessView.EnsureCodeView(LEditor); // intent->view: show Code before the diff paints
    LActivePath := LEditor.FileName;
    LPos := LView.CursorPos;
    LRevealLine := LPos.Line;
    LCurrent := TFacadeShared.ReadBytes(LEditor.CreateReader);
    if not TContentWritePolicy.InsertTextAt(LCurrent, ACode, LPos.Line, LPos.Col, LNewWhole) then
    begin
      LNewWhole := '';
      Exit;
    end;
    LWholeOld := LCurrent;
    TReviewGate.ChangedSpan(LCurrent, LNewWhole, LOldBlock, LNewBlock);
    LOk := True;
  end);
  if not LOk then Exit(False); // no active view / insert failed

  LApprover := TReviewGate.GlobalDiffApprover;
  if Assigned(LApprover) then
  begin
    if (LActivePath <> '') and (LOldBlock <> '') then
      case LApprover.ReviewEdit(LActivePath, LOldBlock, LNewBlock, LDiffReason) of
        ddApplied: Exit(True);
        ddRejected: Exit(True);
      end;
    // Fallback: pure insertion / no anchor — show the whole-buffer diff.
    if (LWholeOld <> '') and (LWholeOld <> LNewWhole) then
      case LApprover.ReviewEdit(LActivePath, LWholeOld, LNewWhole, LDiffReason) of
        ddApplied: Exit(True);
        ddRejected: Exit(True);
      end;
  end;

  // Direct (silent) apply — review off, no active view, or diff unavailable — via
  // the WithLiveSource seam (resolve the active editor, flip to Code, replace).
  Result := THarnessView.WithLiveSource('', lsCodeMutation,
    procedure(const Ctx: ILiveSourceContext)
    begin
      if Ctx.ReplaceWhole(LNewWhole) then
        Ctx.RevealLine(LRevealLine);
    end,
    LChanged, LDiffReason) and LChanged;
end;

// Live (or on-disk) form DFM text of the ACTIVE module, '' when the module owns
// no form. Live designer first (a component the agent just gained via AddComponent
// counts); the on-disk .dfm/.fmx sibling as fallback. Best-effort — any failure
// yields '' so the desync guard FAILS OPEN and never blocks a plain code write.
// Main thread only.
function _ActiveModuleFormDfm: string;
var
  LMS: IOTAModuleServices;
  LModule: IOTAModule;
  LPath: string;
begin
  Result := '';
  try
    if not Supports(BorlandIDEServices, IOTAModuleServices, LMS) then Exit;
    LModule := LMS.CurrentModule;
    if not Assigned(LModule) then Exit;
    if TFacadeShared.TryModuleLiveDfmText(LModule, Result) then Exit;
    LPath := ChangeFileExt(LModule.FileName, '.dfm');
    if not TFile.Exists(LPath) then
      LPath := ChangeFileExt(LModule.FileName, '.fmx');
    if TFile.Exists(LPath) then
      Result := TFile.ReadAllText(LPath);
  except
    Result := '';
  end;
end;

function TMCPEditorWriteService.SetEditorFullContent(
  const ASource: string): Boolean;
var
  LApprover: IMCPDiffApprover;
  LActivePath, LOldBlock, LNewBlock, LWholeOld, LDiffReason: string;
  LGuardDfm, LGuardReason: string;
  LChanged: Boolean;
begin
  LDiffReason := '';

  // PAS<->DFM DESYNC GUARD (its-own-guardian, the mirror of SetDFMContent's):
  // when the ACTIVE unit owns a form, a wholesale source replace must keep every
  // Designer-managed component field — dropping one desyncs .pas<->.dfm and the
  // IDE strips the .dfm objects ("declaration of X does not exist"). Refuses with
  // a structured reason BEFORE anything is shown or written; a formless unit or an
  // unreadable DFM skips the guard (fail open). RULE #1 philosophy: the tool's
  // description already says "this is NOT the normal way to write code" — the
  // guard now enforces the part that corrupts the module.
  LGuardDfm := '';
  TThread.Synchronize(nil, procedure
  begin
    LGuardDfm := _ActiveModuleFormDfm;
  end);
  if LGuardDfm <> '' then
  begin
    LGuardReason := TFlowGuide.SourceDropsComponentsReason(LGuardDfm, ASource);
    if LGuardReason <> '' then
      raise EMCPInvalidParams.Create('SetEditorFullContent: ' + LGuardReason);
  end;

  // Inline diff review (parity with EditUnit/ReplaceInEditor): a whole-buffer
  // replace is the path weaker agents reach for, so route it through the
  // red/green diff too instead of applying silently. TReviewGate.ChangedSpan reduces the
  // old->new content to one contiguous before/after block the inline diff can
  // show and apply. ddUnavailable (review off, no active view, or no change)
  // falls through to the direct replace below.
  LApprover := TReviewGate.GlobalDiffApprover;
  if Assigned(LApprover) then
  begin
    LActivePath := '';
    LOldBlock := '';
    LNewBlock := '';
    LWholeOld := '';
    TThread.Synchronize(nil, procedure
    var
      LEditor: IOTASourceEditor;
      LCurrent: string;
    begin
      if not TFacadeShared.ActiveSourceEditor(LEditor) then Exit;
      THarnessView.EnsureCodeView(LEditor); // intent->view: show Code before the diff paints
      LActivePath := LEditor.FileName;
      LCurrent := TFacadeShared.ReadBytes(LEditor.CreateReader);
      LWholeOld := LCurrent;
      TReviewGate.ChangedSpan(LCurrent, ASource, LOldBlock, LNewBlock);
    end);
    if (LActivePath <> '') and (LOldBlock <> '') then
      case LApprover.ReviewEdit(LActivePath, LOldBlock, LNewBlock, LDiffReason) of
        ddApplied:
          Exit(True);   // the diff wrote the change
        ddRejected:
          Exit(True);   // user rejected in the diff — nothing written, no-op
        // ddUnavailable -> try the whole-buffer fallback below
      end;
    // Fallback: the minimal TReviewGate.ChangedSpan block didn't anchor (or was a pure
    // insertion). Show the WHOLE-buffer diff (old -> new) — _FindLineRange always
    // locates the entire buffer, so a whole-buffer replace still gets a review
    // instead of applying silently. Only the changed lines stand out on screen.
    if (LActivePath <> '') and (LWholeOld <> '') and (LWholeOld <> ASource) then
      case LApprover.ReviewEdit(LActivePath, LWholeOld, ASource, LDiffReason) of
        ddApplied:
          Exit(True);
        ddRejected:
          Exit(True);
      end;
  end;

  // Direct (silent) replace — review off, no active view, or diff unavailable —
  // via the WithLiveSource seam (S2): resolve the active editor, flip to Code,
  // replace the whole buffer. Result True iff the write committed.
  Result := THarnessView.WithLiveSource('', lsCodeMutation,
    procedure(const Ctx: ILiveSourceContext)
    begin
      Ctx.ReplaceWhole(ASource);
    end,
    LChanged, LDiffReason) and LChanged;
end;

function TMCPEditorWriteService.ReplaceInEditor(const AFind,
  AReplace: string; const AAll: Boolean; out ACount: Integer): Boolean;
var
  LResult, LChanged: Boolean;
  LCount: Integer;
  LApprover: IMCPDiffApprover;
  LActivePath, LOldBlock, LNewBlock, LDiffReason: string;
  LMatchCount: Integer;
begin
  ACount := 0;
  LCount := 0;
  LDiffReason := '';

  // Inline diff review (parity with EditUnit): route ANY editor replace — single
  // OR global (All=true, scattered) — through the red/green diff instead of
  // applying silently. TReviewGate.ChangedSpan turns the whole-buffer change into one
  // contiguous before/after block (interspersed unchanged lines preserved), which
  // the inline diff can show and apply exactly. ddUnavailable (review off, unit not
  // shown, nothing changed) falls through to the direct replace below.
  LApprover := TReviewGate.GlobalDiffApprover;
  if Assigned(LApprover) and (AFind <> '') then
  begin
    LActivePath := '';
    LOldBlock := '';
    LMatchCount := 0;
    TThread.Synchronize(nil, procedure
    var
      LEditor: IOTASourceEditor;
      LCurrent, LNew: string;
    begin
      if not TFacadeShared.ActiveSourceEditor(LEditor) then Exit;
      THarnessView.EnsureCodeView(LEditor); // intent->view: show Code before the diff paints
      LActivePath := LEditor.FileName;
      LCurrent := TFacadeShared.ReadBytes(LEditor.CreateReader);
      if not TContentWritePolicy.ReplaceInBuffer(LCurrent, AFind, AReplace, AAll, LNew, LMatchCount) then
        Exit;
      if LMatchCount = 0 then Exit;
      TReviewGate.ChangedSpan(LCurrent, LNew, LOldBlock, LNewBlock);
    end);
    if (LActivePath <> '') and (LOldBlock <> '') then
      case LApprover.ReviewEdit(LActivePath, LOldBlock, LNewBlock, LDiffReason) of
        ddApplied:
          begin
            ACount := LMatchCount;
            Exit(True);
          end;
        ddRejected:
          begin
            ACount := 0;
            Exit(True); // user rejected in the diff — nothing written, no-op
          end;
        // ddUnavailable -> fall through to the direct replace below
      end;
  end;

  // Direct (silent) replace — bulk, review off, or diff unavailable — via the
  // WithLiveSource seam (S2). The work computes the replacement (pure
  // ContentWritePolicy.ReplaceInBuffer); a zero-match is a successful no-op
  // (count 0, no write, no Fail -> seam True), a positive match writes the whole
  // buffer, and a failed parse/write fails the transaction. Result mirrors the old
  // `Result := LResult` directly (NOT `and LChanged`): the no-op is a success even
  // though nothing was written.
  LResult := THarnessView.WithLiveSource('', lsCodeMutation,
    procedure(const Ctx: ILiveSourceContext)
    var
      LNew: string;
    begin
      if not TContentWritePolicy.ReplaceInBuffer(Ctx.ReadBuffer, AFind, AReplace, AAll, LNew, LCount) then
      begin
        LCount := 0;
        Ctx.Fail('replace-failed');
        Exit;
      end;
      // No match — a successful no-op: report count 0 without rewriting.
      if LCount = 0 then
        Exit;
      if not Ctx.ReplaceWhole(LNew) then
        Ctx.Fail('write-failed');
    end,
    LChanged, LDiffReason);
  ACount := LCount;
  Result := LResult;
end;

function NewMCPEditorWriteService: IMCPEditorWriteService;
begin
  Result := TMCPEditorWriteService.Create;
end;

end.
