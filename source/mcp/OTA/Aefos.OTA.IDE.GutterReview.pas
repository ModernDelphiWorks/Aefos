unit Aefos.OTA.IDE.GutterReview;

(*
  Editor change-review in the Delphi editor (ESP, 2026-06-10; N-change model + inline
  per-change controls 2026-06-21).

  Lives in the shared Aefos.MCP.Tools.OTA BPL so BOTH products (Chat AND a Terminal/
  Studio-only install) get the editor change-review — the MCP facade that drives the
  edits already lives here. Registered from each host wizard (Chat + Terminal) via
  RegisterGutterReview (idempotent); torn down once in this unit's finalization.

  MODEL B — "applied + review" (Cursor/VS Code style):
    - The agent's edit is APPLIED to the buffer immediately (old_text -> new_text),
      so the buffer is always coherent and the agent's chained edits anchor cleanly.
      ReviewEdit returns ddApplied at once — it NEVER blocks the agent; the edits
      accumulate and "sprout" as the agent works.
    - Each applied edit is tracked as a pending TReviewChange (its NEW block line
      range + the OLD text, kept so a reject can restore it). N changes accumulate;
      line accounting shifts the ranges of changes below each apply/reject.
    - APPROVE = keep (drop the marker, text stays). REJECT = restore the OLD text.

  RENDERING — INLINE (NOT the native gutter). A live investigation (2026-06-21)
  proved the modern INTACodeEditorServices custom gutter-column paint is a dead end
  on D13: the notifier registers, RequestGutterColumn returns a valid index,
  PaintGutter fires per line and GetGutterColumnRect returns a rect, yet drawing on
  the supplied Canvas at pgsEndPaint never reaches the screen (the surface is
  discarded). So we render with the PROVEN INTAEditViewNotifier on the editor body:
    - NEW (added) lines painted GREEN;
    - per-change [check]/[cross] buttons at the right edge of each change's first
      (marker) line; a click approves/rejects THAT change;
    - an "Approve All / Reject All" pill on the first pending change's line.
  Clicks are caught via Application.OnMessage hit-testing the painted rects (the
  same mechanism that already worked for the All pill) — no editor focus needed.
  The check/cross glyphs render fine on the editor-body canvas (its font has them);
  only the gutter canvas font lacked them.

  Boundary: ToolsAPI + Vcl.Graphics. Teardown removes the keyboard binding by index
  and restores Application.OnMessage in finalization (unload law).
*)

interface

uses
  Aefos.MCP.Server;

type
  // Editor change-review as a sealed static namespace (Wave 7c). The class IS the
  // namespace — never instantiated; the module-level state backing it stays as unit
  // globals for the IDE-UNLOAD teardown discipline (see the finalization law and
  // UnregisterGutterReview). Only the four host/MCP entry points are public; the
  // review-state queries and bulk resolvers have no external caller and are private
  // (consumed within this unit by the paint/hook/save free helpers).
  TGutterReview = class sealed
  private
    // One line per pending change: "<unit-path>:<start>-<end>  pending". Empty when none.
    class function DescribePendingReviews: string; static;
    // True while at least one change is pending review.
    class function ReviewPending: Boolean; static;
    // Number of pending changes (across all units).
    class function ReviewPendingCount: Integer; static;
    // Resolve ALL pending changes: approve keeps every applied edit; reject restores
    // every original. Safe no-ops when nothing is pending.
    class procedure ApproveAllChanges; static;
    class procedure RejectAllChanges; static;
    // Returns and CLEARS the accumulated annotations (one per line, tagged
    // approved/rejected) the user attached to changes. Empty when there are none.
    // Intended for an MCP tool so the agent can fetch the user's review feedback.
    class function DrainReviewFeedback: string; static;
    // Strips the pending "before" (red) blocks from the buffer so a save/compile never
    // persists the doubled old+new review text. Registered with the facade's pre-save flush
    // seam AND called from a module notifier, so every save path (agent ForceSave, manual
    // Ctrl+S, compile) lands the final (green) text. The changes stay pending as green-only.
    // Idempotent and a no-op when nothing is pending.
    class procedure FlushReviewBeforeSave; static;
  public
    // Idempotent — call from each host wizard (Chat + Terminal). Teardown runs once in
    // this unit's finalization; Unregister stays public for explicit shutdown.
    class procedure RegisterGutterReview; static;
    class procedure UnregisterGutterReview; static;
    // Registers the GetReviewFeedback MCP tool on AServer (call from the MCP host). The
    // tool returns + clears the user's review annotations so the agent can fetch them.
    class procedure RegisterReviewFeedbackTool(const AServer: IMCPServer); static;
    // Registers the GetPendingReviews MCP tool on AServer (call from the MCP host). The
    // tool lists the edits still PENDING in the review gutter (applied to the buffer but
    // not yet approved/rejected) WITHOUT clearing anything, so the agent always has a
    // truthful view of which of its changes are awaiting the user's decision and can
    // revalidate with confidence. The review never blocks the agent.
    class procedure RegisterPendingReviewsTool(const AServer: IMCPServer); static;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.UITypes,
  System.JSON,
  System.Generics.Collections,
  Winapi.Windows,
  Winapi.Messages,
  Vcl.Graphics,
  Vcl.Controls,
  Vcl.StdCtrls,
  Vcl.Menus,
  Vcl.Forms,
  ToolsAPI,
  Aefos.MCP.Types,
  Aefos.OTA.Options.AIFlow,
  Aefos.OTA.UI.ThemeHelper,
  Aefos.MCP.OTA.ReviewGate; // review seams hoisted out of the facade (SOLID split)

type
  // One accumulated, already-applied edit awaiting the user's approve/reject. The
  // buffer already holds the NEW text at [NewFrom..NewTo]; OldText restores it on a
  // reject. NewTo < NewFrom marks an empty new block (a pure deletion).
  // A click action on a painted control: approve, reject, or annotate (add a note).
  TReviewAction = (raApprove, raReject, raAnnotate);

  TReviewChange = class
  public
    Id: Integer;
    UnitPath: string;
    OldText: string;
    OldFrom, OldTo: Integer; // struck-out RED block (original text), kept in the buffer
    NewFrom, NewTo: Integer; // GREEN block (new text), sitting right below the old block
    HadRemoval: Boolean;
    Note: string; // user's annotation; delivered to the agent on approve OR reject
    function NewLineCount: Integer;
    function OldLineCount: Integer;
    function MarkerLine: Integer; // line carrying the gutter controls (top of the change)
  end;

  // A painted clickable control (per-change button or an All button). Rebuilt every
  // paint pass; hit-tested by the Application.OnMessage hook. ChangeId = 0 => All.
  TReviewTarget = record
    R: TRect;
    ChangeId: Integer;
    Action: TReviewAction;
  end;

  // Catches clicks on the painted controls via Application.OnMessage (no focus
  // needed; the floating overlay window never showed reliably in-IDE).
  TReviewInputHook = class
    procedure AppMessage(var Msg: TMsg; var Handled: Boolean);
  end;

  // One entry in the per-module save-notifier registry (R8): every unit with a pending
  // review keeps its OWN IOTAModuleNotifier so its own Ctrl+S / compile is caught. The
  // notifier is held as an interface (OTA-refcounted; never freed directly) alongside its
  // AddNotifier index, so teardown can RemoveNotifier(Idx) then drop the ref (unload law).
  TReviewModuleReg = class
  public
    UnitPath: string;
    Module: IOTAModule;
    Notifier: IInterface;
    Idx: Integer;
  end;

  // One entry in the per-VIEW paint-notifier registry (the view twin of the R8 module registry):
  // every unit with a pending review keeps its OWN INTAEditViewNotifier tagged with its UnitPath,
  // so switching the editor to another unit and back never detaches or mishandles a DIFFERENT
  // unit's review. The single global slot (old GReviewView) could go stale on a view teardown and
  // was then used as the buffer to mutate — corrupting the wrong unit. The notifier is held as an
  // interface (OTA-refcounted; never freed directly) alongside its AddNotifier index + the view it
  // watches, so teardown can RemoveNotifier(Idx) then drop the refs (unload law). View/Idx are
  // cleared to nil/-1 by the notifier's Destroyed so teardown never touches a torn-down view.
  TReviewViewReg = class
  public
    UnitPath: string;
    View: IOTAEditView;
    Notifier: IInterface;
    Idx: Integer;
  end;

var
  GChanges: TObjectList<TReviewChange> = nil;
  GNextId: Integer = 1;
  // Per-VIEW paint-notifier registry (the view twin of GModuleRegistry): one entry per unit with a
  // pending review, each holding that unit's OWN INTAEditViewNotifier + the view it is attached to.
  // Replaces the old single GReviewView/GNotifierIndex slot, whose staleness on a view switch was
  // the multi-unit corruption. EVERY AddNotifier into this registry is paired with a
  // RemoveNotifier(Idx) at teardown per the unload law (_RemoveAllViewNotifiers).
  GViewRegistry: TObjectList<TReviewViewReg> = nil;
  // Per-module save-notifier registry (R8): one entry per unit with a pending review, so a
  // manual Ctrl+S / compile on ANY reviewed unit is caught and its "before" (red) blocks are
  // stripped before the write. The old single slot only watched the LAST-edited unit, so a
  // save of an earlier unit persisted its doubled old+new text (silent source corruption).
  // The facade seam covers agent saves. EVERY AddNotifier into this registry is paired with a
  // RemoveNotifier(Idx) at teardown per the unload law (_RemoveAllModuleNotifiers).
  GModuleRegistry: TObjectList<TReviewModuleReg> = nil;
  GKbIndex: Integer = -1;
  GTargets: array of TReviewTarget;
  GTargetCount: Integer = 0;
  GInputHook: TReviewInputHook = nil;
  GOldAppOnMessage: TMessageEvent = nil;
  GMsgHookActive: Boolean = False;
  // Accumulated annotations delivered to the agent at resolution (approve/reject).
  // Each line: "approved|rejected <unit>@<line>: <note>". Drained by the agent via
  // an MCP tool (follow-up). Survives a single resolve so nothing is lost.
  GReviewFeedback: TStringList = nil;

const
  CLR_ADDED_BG = $00204020; // dark green (BGR)
  CLR_ADDED_FG = $0090E090;
  CLR_APPROVE  = $004CA64C; // approve = green (BGR)
  CLR_REJECT   = $004C4CE0; // reject = red (BGR)
  CLR_NOTE     = $00B0742C; // annotate = blue (BGR), no note yet
  CLR_NOTE_HI  = $00E0A85C; // annotate — has a note (brighter)
  CLR_REMOVED_BG = $00202060; // removed (OLD) lines band — dark red (BGR)
  CLR_REMOVED_FG = $007070E0; // removed (OLD) lines text — light red (BGR), struck-out

function TReviewChange.NewLineCount: Integer;
begin
  Result := NewTo - NewFrom + 1;
  if Result < 0 then
    Result := 0;
end;

function TReviewChange.OldLineCount: Integer;
begin
  Result := OldTo - OldFrom + 1;
  if Result < 0 then
    Result := 0;
end;

// The change's TOP line — where the gutter controls sit. The old (red) block is on top
// when present (the usual case); otherwise the new (green) block.
function TReviewChange.MarkerLine: Integer;
begin
  if OldLineCount > 0 then
    Result := OldFrom
  else
    Result := NewFrom;
end;

procedure _CleanupIfEmpty; forward;
// Strips the pending OLD (red) blocks of ONE unit from the buffer (on that unit's OWN live view)
// so a save never persists the doubled old+new review text, keeping the change pending as
// green-only. Defined after the line-accounting helpers. Called by the view notifier's BeforeSave.
procedure _StripOldBlocksForUnitKeepPending(const AUnitPath: string); forward;
// The unit's CURRENT live edit view (resolved fresh from the module — never a cached global slot),
// materialising one when the unit has no open view. Defined late; used by the per-view registry.
function _ViewForUnit(const AUnitPath: string): IOTAEditView; forward;
// The per-view registry entry watching AUnitPath, or nil. Declared early so the view notifier's
// Destroyed can clear its own entry.
function _FindViewReg(const AUnitPath: string): TReviewViewReg; forward;
// Save = accept ALL pending units (agent SaveAllFiles / facade ForceSave): strips every unit's
// red on its OWN view then drops all changes. Notifier/hook teardown is DEFERRED.
procedure _ResolveAllForSave; forward;
// Save = accept ONE unit (its module notifier's BeforeSave): strips that unit's red + drops
// that unit's changes, leaving OTHER units' reviews pending. Teardown is DEFERRED.
procedure _ResolveUnitForSave(const AUnitPath: string); forward;
// True while AUnitPath still has UNRESOLVED review blocks in GChanges (defined late; used by
// the module-notifier registry cleanup above its definition).
function ReviewHasPendingForUnit(const AUnitPath: string): Boolean; forward;

// ── OTA helpers ──────────────────────────────────────────────────────────

function _TopView: IOTAEditView;
var
  LEditorServices: IOTAEditorServices;
begin
  Result := nil;
  if Supports(BorlandIDEServices, IOTAEditorServices, LEditorServices) then
    Result := LEditorServices.TopView;
end;

// Brings AUnitPath's source editor to the front as the active Code view so the edit
// (and its markers) land on the unit the agent is editing. INTENT->VIEW. False when
// the unit has no open source editor.
function _ShowUnitSource(const AUnitPath: string): Boolean;
var
  LMS: IOTAModuleServices;
  LModule: IOTAModule;
  LSource: IOTASourceEditor;
  LIdx: Integer;
begin
  Result := False;
  if not Supports(BorlandIDEServices, IOTAModuleServices, LMS) then
    Exit;
  LModule := LMS.FindModule(AUnitPath);
  if not Assigned(LModule) then
    Exit;
  LSource := nil;
  for LIdx := 0 to LModule.GetModuleFileCount - 1 do
    if Supports(LModule.GetModuleFileEditor(LIdx), IOTASourceEditor, LSource) then
      Break;
  if not Assigned(LSource) then
    Exit;
  LSource.Show;
  Result := True;
end;

procedure _Repaint(const AView: IOTAEditView);
begin
  if Assigned(AView) then
    AView.Paint;
end;

// Forces a FULL editor repaint after a change resolves. AView.Paint alone clears
// only while our paint notifier is still attached (it drives the repaint cycle);
// resolving the LAST change detaches the notifier AND an Approve makes no buffer
// change, so the editor isn't dirty and the green/buttons linger as stale pixels.
// RedrawWindow with RDW_ALLCHILDREN reaches the editor control itself (a child of
// the edit-window form — InvalidateRect on the form alone never reaches it) and
// forces an immediate erase + repaint, so resolved changes vanish at once.
procedure _ForceFullRepaint(const AView: IOTAEditView);
var
  LWin: INTAEditWindow;
begin
  if AView = nil then
    Exit;
  AView.Paint;
  LWin := AView.GetEditWindow;
  if Assigned(LWin) and Assigned(LWin.Form) and LWin.Form.HandleAllocated then
    RedrawWindow(LWin.Form.Handle, nil, 0,
      RDW_INVALIDATE or RDW_ERASE or RDW_ALLCHILDREN or RDW_UPDATENOW);
end;

function _ViewUnitPath(const AView: IOTAEditView): string;
begin
  Result := '';
  if Assigned(AView) and Assigned(AView.Buffer) then
    Result := AView.Buffer.FileName;
end;

// Deletes whole lines [AFrom..ATo] (1-based, inclusive).
procedure _DeleteLineBlock(const AView: IOTAEditView; AFrom, ATo: Integer);
var
  LPos: IOTAEditPosition;
  LBlock: IOTAEditBlock;
begin
  if (AView = nil) or (AFrom < 1) or (ATo < AFrom) then
    Exit;
  LPos := AView.Buffer.EditPosition;
  LBlock := AView.Buffer.EditBlock;
  LBlock.Reset;
  LBlock.Style := btNonInclusive;
  LPos.GotoLine(AFrom);
  LPos.MoveBOL;
  LBlock.BeginBlock;
  LPos.GotoLine(ATo + 1);
  LPos.MoveBOL;
  LBlock.EndBlock;
  LBlock.Delete;
end;

// Inserts AText's lines AFTER line AAfterLine (1-based, always >= 1 here) and returns
// how many lines were inserted. Auto-indent is cleared per line.
function _InsertBlockAfter(const AView: IOTAEditView; AAfterLine: Integer;
  const AText: string): Integer;
var
  LPos: IOTAEditPosition;
  LLines: TStringList;
  LIndex, LCol: Integer;
begin
  Result := 0;
  if (AView = nil) or (AAfterLine < 1) then
    Exit;
  LPos := AView.Buffer.EditPosition;
  LLines := TStringList.Create;
  try
    LLines.Text := AText;
    if (LLines.Count > 0) and (LLines[LLines.Count - 1] = '') then
      LLines.Delete(LLines.Count - 1);
    Result := LLines.Count;
    if Result = 0 then
      Exit;
    AView.Block.Reset;
    LPos.GotoLine(AAfterLine);
    LPos.MoveEOL;
    for LIndex := 0 to LLines.Count - 1 do
    begin
      LPos.InsertText(sLineBreak);
      LPos.MoveEOL;
      LCol := LPos.Column;
      LPos.MoveBOL;
      if LCol > 1 then
        LPos.Delete(LCol - 1);
      LPos.InsertText(LLines[LIndex]);
    end;
  finally
    LLines.Free;
  end;
end;

// True if the first ALen bytes of ABytes are well-formed UTF-8.
function _IsValidUtf8(const ABytes: TBytes; ALen: Integer): Boolean;
var
  LIndex, LExtra: Integer;
  LByte: Byte;
begin
  LIndex := 0;
  while LIndex < ALen do
  begin
    LByte := ABytes[LIndex];
    if LByte < $80 then
      LExtra := 0
    else if (LByte and $E0) = $C0 then
      LExtra := 1
    else if (LByte and $F0) = $E0 then
      LExtra := 2
    else if (LByte and $F8) = $F0 then
      LExtra := 3
    else
      Exit(False);
    Inc(LIndex);
    while LExtra > 0 do
    begin
      if (LIndex >= ALen) or ((ABytes[LIndex] and $C0) <> $80) then
        Exit(False);
      Inc(LIndex);
      Dec(LExtra);
    end;
  end;
  Result := True;
end;

// Reads the full text of an edit buffer (UTF-8 when valid, ANSI otherwise).
function _BufferText(const ABuffer: IOTAEditBuffer): string;
var
  LReader: IOTAEditReader;
  LChunk, LAll: TBytes;
  LRead, LPos, LTotal: Integer;
begin
  Result := '';
  if ABuffer = nil then
    Exit;
  LReader := ABuffer.CreateReader;
  LPos := 0;
  LTotal := 0;
  SetLength(LChunk, 8192);
  repeat
    LRead := LReader.GetText(LPos, PAnsiChar(@LChunk[0]), Length(LChunk));
    if LRead > 0 then
    begin
      if LTotal + LRead > Length(LAll) then
        SetLength(LAll, (LTotal + LRead) * 2 + 8192);
      Move(LChunk[0], LAll[LTotal], LRead);
      Inc(LTotal, LRead);
      Inc(LPos, LRead);
    end;
  until LRead < Length(LChunk);
  if LTotal = 0 then
    Exit;
  if _IsValidUtf8(LAll, LTotal) then
    Result := TEncoding.UTF8.GetString(LAll, 0, LTotal)
  else
    Result := TEncoding.ANSI.GetString(LAll, 0, LTotal);
end;

// 1-based line range [AFrom..ATo] of the first occurrence of AOldText in ABufferText
// (LF-normalised so CRLF/LF differences are ignored).
function _FindLineRange(const ABufferText, AOldText: string;
  out AFrom, ATo: Integer): Boolean;
var
  LBuf, LOld: string;
  LOffset, LIndex, LLine: Integer;
begin
  AFrom := 0; ATo := 0;
  Result := False;
  LBuf := StringReplace(StringReplace(ABufferText, #13#10, #10, [rfReplaceAll]),
    #13, #10, [rfReplaceAll]);
  LOld := StringReplace(StringReplace(AOldText, #13#10, #10, [rfReplaceAll]),
    #13, #10, [rfReplaceAll]);
  LOld := LOld.Trim([#10, ' ', #9]);
  if LOld = '' then
    Exit;
  LOffset := Pos(LOld, LBuf);
  if LOffset = 0 then
    Exit;
  LLine := 1;
  for LIndex := 1 to LOffset - 1 do
    if LBuf[LIndex] = #10 then
      Inc(LLine);
  AFrom := LLine;
  for LIndex := 1 to Length(LOld) do
    if LOld[LIndex] = #10 then
      Inc(LLine);
  ATo := LLine;
  Result := True;
end;

{ ── Application.OnMessage hook (clicks on the painted controls) ───────────── }

procedure _InstallMsgHook;
begin
  if GMsgHookActive then
    Exit;
  if GInputHook = nil then
    GInputHook := TReviewInputHook.Create;
  GOldAppOnMessage := Application.OnMessage;
  Application.OnMessage := GInputHook.AppMessage;
  GMsgHookActive := True;
end;

procedure _RemoveMsgHook;
var
  LCurEvent: TMessageEvent;
  LCur, LOurs: TMethod;
begin
  if not GMsgHookActive then
    Exit;
  GMsgHookActive := False;
  // THE LAW: never leave an Application.OnMessage hook pointing into this BPL.
  if not Assigned(GInputHook) then
    Exit;
  LCurEvent := Application.OnMessage;
  LCur := TMethod(LCurEvent);
  LOurs.Code := @TReviewInputHook.AppMessage;
  LOurs.Data := Pointer(GInputHook);
  if (LCur.Code = LOurs.Code) and (LCur.Data = LOurs.Data) then
    Application.OnMessage := GOldAppOnMessage;
end;

{ ── Painted click-target registry (rebuilt each paint pass) ──────────────── }

procedure _ResetTargets;
begin
  GTargetCount := 0; // keep the array capacity; just forget last frame's rects
end;

procedure _AddTarget(const R: TRect; AChangeId: Integer; AAction: TReviewAction);
begin
  if GTargetCount >= Length(GTargets) then
    SetLength(GTargets, GTargetCount + 16);
  GTargets[GTargetCount].R := R;
  GTargets[GTargetCount].ChangeId := AChangeId;
  GTargets[GTargetCount].Action := AAction;
  Inc(GTargetCount);
end;

function _HitTarget(const APt: TPoint; out AId: Integer; out AAction: TReviewAction): Boolean;
var
  LIndex: Integer;
begin
  for LIndex := 0 to GTargetCount - 1 do
    if PtInRect(GTargets[LIndex].R, APt) then
    begin
      AId := GTargets[LIndex].ChangeId;
      AAction := GTargets[LIndex].Action;
      Exit(True);
    end;
  AId := 0; AAction := raApprove;
  Result := False;
end;

{ ── Paint notifier (green NEW blocks + inline per-change + All controls) ───── }

type
  TReviewViewNotifier = class(TInterfacedObject, IOTANotifier, INTAEditViewNotifier)
  private
    FUnitPath: string; // the unit this notifier paints/saves; BeforeSave strips ONLY this unit
  public
    constructor Create(const AUnitPath: string);
    procedure EditorIdle(const View: IOTAEditView);
    procedure BeginPaint(const View: IOTAEditView; var FullRepaint: Boolean);
    procedure PaintLine(const View: IOTAEditView; LineNumber: Integer;
      const LineText: PAnsiChar; const TextWidth: Word;
      const LineAttributes: TOTAAttributeArray; const Canvas: TCanvas;
      const TextRect: TRect; const LineRect: TRect; const CellSize: TSize);
    procedure EndPaint(const View: IOTAEditView);
    procedure AfterSave;
    procedure BeforeSave;
    procedure Modified;
    procedure Destroyed;
  end;

constructor TReviewViewNotifier.Create(const AUnitPath: string);
begin
  inherited Create;
  FUnitPath := AUnitPath;
end;

procedure TReviewViewNotifier.BeginPaint(const View: IOTAEditView;
  var FullRepaint: Boolean);
begin
  FullRepaint := True;
  _ResetTargets; // last frame's click rects are stale until re-painted this pass
end;

// Draws AGlyph centred in ARect on a filled button background ABg.
procedure _PaintButton(const ACanvas: TCanvas; const ARect: TRect; ABg, AFg: TColor;
  const AGlyph: string);
var
  LX, LY: Integer;
begin
  ACanvas.Brush.Color := ABg;
  ACanvas.Brush.Style := bsSolid;
  ACanvas.FillRect(ARect);
  ACanvas.Font.Style := [fsBold];
  ACanvas.Font.Color := AFg;
  ACanvas.Brush.Style := bsClear;
  LX := ARect.Left + ((ARect.Right - ARect.Left) - ACanvas.TextWidth(AGlyph)) div 2;
  LY := ARect.Top + ((ARect.Bottom - ARect.Top) - ACanvas.TextHeight(AGlyph)) div 2;
  ACanvas.TextOut(LX, LY, AGlyph);
end;

// Per-change check (approve) / cross (reject) in the GUTTER (x 0..TextRect.Left) on
// a change's marker line. PaintLine's canvas reaches the gutter (proven live:
// LineRect.Left = 0, and it paints over the line numbers), so this is the literal
// gutter the maintainer wanted. Squares sized to the line height, shrunk to fit the
// gutter width. Records each as a click target (same Application.OnMessage hit-test).
// Annotate button: a PENCIL drawn as shapes (font-independent, no glyph/tofu risk) —
// a diagonal body with a small tip. Brighter background when a note already exists.
procedure _PaintNoteButton(const ACanvas: TCanvas; const ARect: TRect; ABg: TColor);
begin
  ACanvas.Brush.Color := ABg;
  ACanvas.Brush.Style := bsSolid;
  ACanvas.FillRect(ARect);
  ACanvas.Pen.Color := clWhite;
  ACanvas.Pen.Width := 2;
  // pencil body (lower-left -> upper-right tip)
  ACanvas.MoveTo(ARect.Left + 5, ARect.Bottom - 5);
  ACanvas.LineTo(ARect.Right - 5, ARect.Top + 5);
  // tip "point"
  ACanvas.Pen.Width := 1;
  ACanvas.MoveTo(ARect.Right - 5, ARect.Top + 5);
  ACanvas.LineTo(ARect.Right - 9, ARect.Top + 5);
  ACanvas.MoveTo(ARect.Right - 5, ARect.Top + 5);
  ACanvas.LineTo(ARect.Right - 5, ARect.Top + 9);
end;

// Per-change check (approve) / cross (reject) / note (annotate) in the GUTTER on a
// change's marker line, via PaintLine's (visible) canvas. Squares sized to the line
// height, shrunk to fit the gutter width. Each is recorded as a click target.
procedure _PaintGutterButtons(const ACanvas: TCanvas; const ALineRect, ATextRect: TRect;
  AChange: TReviewChange);
var
  LSz: Integer;
  LRApprove, LRReject, LRNote: TRect;
begin
  LSz := ALineRect.Bottom - ALineRect.Top; // square = line height
  if ATextRect.Left < LSz * 3 + 6 then
    LSz := (ATextRect.Left - 6) div 3;      // shrink to fit 3 buttons in the gutter
  if LSz < 6 then
    Exit;
  LRApprove := Rect(1, ALineRect.Top, 1 + LSz, ALineRect.Bottom);
  LRReject := Rect(2 + LSz, ALineRect.Top, 2 + LSz * 2, ALineRect.Bottom);
  LRNote := Rect(3 + LSz * 2, ALineRect.Top, 3 + LSz * 3, ALineRect.Bottom);
  _PaintButton(ACanvas, LRApprove, CLR_APPROVE, clWhite, #$2713);
  _PaintButton(ACanvas, LRReject, CLR_REJECT, clWhite, #$2717);
  if AChange.Note <> '' then
    _PaintNoteButton(ACanvas, LRNote, CLR_NOTE_HI)
  else
    _PaintNoteButton(ACanvas, LRNote, CLR_NOTE);
  _AddTarget(LRApprove, AChange.Id, raApprove);
  _AddTarget(LRReject, AChange.Id, raReject);
  _AddTarget(LRNote, AChange.Id, raAnnotate);
end;

// "Approve All (N) / Reject All" pill at the right edge of the marker line (the text
// is too wide for the narrow gutter). On EVERY change's line so the user can resolve
// all from wherever they are. Records each as a click target.
procedure _PaintAllPill(const ACanvas: TCanvas; const ALineRect: TRect);
var
  LRAllA, LRAllR: TRect;
  LAllA, LAllR: string;
  LWa, LWr: Integer;
begin
  LAllA := ' ' + #$2713 + ' All (' + IntToStr(TGutterReview.ReviewPendingCount) + ') ';
  LAllR := ' ' + #$2717 + ' All ';
  ACanvas.Font.Style := [fsBold];
  LWa := ACanvas.TextWidth(LAllA);
  LWr := ACanvas.TextWidth(LAllR);
  LRAllR := Rect(ALineRect.Right - 4 - LWr, ALineRect.Top, ALineRect.Right - 4,
    ALineRect.Bottom);
  LRAllA := Rect(LRAllR.Left - LWa, ALineRect.Top, LRAllR.Left, ALineRect.Bottom);
  if LRAllA.Left > ALineRect.Left then
  begin
    _PaintButton(ACanvas, LRAllA, CLR_APPROVE, clWhite, LAllA);
    _PaintButton(ACanvas, LRAllR, CLR_REJECT, clWhite, LAllR);
    _AddTarget(LRAllA, 0, raApprove);
    _AddTarget(LRAllR, 0, raReject);
  end;
end;

procedure TReviewViewNotifier.PaintLine(const View: IOTAEditView;
  LineNumber: Integer; const LineText: PAnsiChar; const TextWidth: Word;
  const LineAttributes: TOTAAttributeArray; const Canvas: TCanvas;
  const TextRect: TRect; const LineRect: TRect; const CellSize: TSize);
var
  LText, LUnit: string;
  LChange, LMarker: TReviewChange;
  LInOld, LInNew: Boolean;
  LBand: TRect;
begin
  if (GChanges = nil) or (GChanges.Count = 0) then
    Exit;
  LUnit := _ViewUnitPath(View);

  LInOld := False;
  LInNew := False;
  LMarker := nil;
  for LChange in GChanges do
  begin
    if not SameText(LChange.UnitPath, LUnit) then
      Continue;
    if (LChange.OldLineCount > 0) and (LineNumber >= LChange.OldFrom) and (LineNumber <= LChange.OldTo) then
      LInOld := True;
    if (LChange.NewLineCount > 0) and (LineNumber >= LChange.NewFrom) and (LineNumber <= LChange.NewTo) then
      LInNew := True;
    if LineNumber = LChange.MarkerLine then
      LMarker := LChange;
  end;

  LText := string(UTF8String(LineText));

  // Stacked diff, bounded to the CODE area (from TextRect.Left) so each band fills the
  // line but STOPS at the gutter (like the IDE's active-line bar). LineRect.Left is 0
  // (covers the gutter); using it for the fill is what overpainted the gutter markers
  // before (the maintainer's catch). A line is in the OLD (red) block OR the NEW (green)
  // block, never both — the two ranges are disjoint and contiguous (new right after old).
  if LInOld then
  begin
    // The band starts ONE cell left of the code so the '-' has its own column, while the
    // code text stays at its natural TextRect.Left — no shift, so it stays ALIGNED with the
    // surrounding unchanged lines. The '-' sits in that column, NOT struck.
    LBand := LineRect;
    LBand.Left := TextRect.Left - CellSize.cx;
    Canvas.Brush.Color := CLR_REMOVED_BG;
    Canvas.Brush.Style := bsSolid;
    Canvas.FillRect(LBand);
    Canvas.Brush.Style := bsClear;
    Canvas.Font.Color := CLR_REMOVED_FG;
    Canvas.Font.Style := [fsStrikeOut];
    Canvas.TextOut(TextRect.Left, TextRect.Top, LText.TrimRight);
    Canvas.Font.Style := [];
    Canvas.TextOut(TextRect.Left - CellSize.cx, TextRect.Top, '-');
  end
  else if LInNew then
  begin
    LBand := LineRect;
    LBand.Left := TextRect.Left - CellSize.cx;
    Canvas.Brush.Color := CLR_ADDED_BG;
    Canvas.Brush.Style := bsSolid;
    Canvas.FillRect(LBand);
    Canvas.Brush.Style := bsClear;
    Canvas.Font.Color := CLR_ADDED_FG;
    Canvas.Font.Style := [];
    Canvas.TextOut(TextRect.Left, TextRect.Top, LText.TrimRight);
    Canvas.TextOut(TextRect.Left - CellSize.cx, TextRect.Top, '+');
  end;

  // Marker line (top of the change): per-change approve/reject/annotate in the GUTTER +
  // the All pill inline.
  if LMarker <> nil then
  begin
    _PaintGutterButtons(Canvas, LineRect, TextRect, LMarker);
    _PaintAllPill(Canvas, LineRect);
  end;
end;

procedure TReviewViewNotifier.EditorIdle(const View: IOTAEditView);
begin
end;

procedure TReviewViewNotifier.EndPaint(const View: IOTAEditView);
begin
end;

procedure TReviewViewNotifier.AfterSave;
begin
end;

procedure TReviewViewNotifier.BeforeSave;
begin
  // The stacked review keeps the OLD (red) text in the buffer. A save must NOT persist
  // that doubled old+new text — strip THIS notifier's own unit's pending OLD blocks first so the
  // file is written as the final (green) text. Changes stay pending as green-only. Per-unit: never
  // touches another unit's review. Guarded: a failure here must never abort the save nor AV the IDE.
  try
    _StripOldBlocksForUnitKeepPending(FUnitPath);
  except
    // best-effort: never let the save path raise
  end;
end;

procedure TReviewViewNotifier.Modified;
begin
end;

procedure TReviewViewNotifier.Destroyed;
var
  LReg: TReviewViewReg;
begin
  // The IDE is tearing down THIS view's notifier (e.g. the user closed/switched the view). Mark
  // our own registry entry's view dead (View=nil, Idx=-1) so teardown never calls RemoveNotifier on
  // an already-destroyed view (unload law: never touch a dead IDE ref). Only touch the entry if it
  // is still OURS — if a newer notifier already re-took this unit's slot on a fresh view, leave it
  // alone. We deliberately KEEP our Notifier ref: the entry stays the sole owner of this now-orphan
  // notifier object, so it is released cleanly later by _RemoveViewRegAt / _EnsureViewNotifier
  // re-add — never freed mid-callback. Pure field writes; no notifier is removed here.
  LReg := _FindViewReg(FUnitPath);
  if Assigned(LReg) and (LReg.Notifier = (Self as IInterface)) then
  begin
    LReg.View := nil;
    LReg.Idx := -1;
  end;
end;

// The per-view registry entry watching AUnitPath, or nil.
function _FindViewReg(const AUnitPath: string): TReviewViewReg;
var
  LReg: TReviewViewReg;
begin
  Result := nil;
  if GViewRegistry = nil then
    Exit;
  for LReg in GViewRegistry do
    if SameText(LReg.UnitPath, AUnitPath) then
      Exit(LReg);
end;

// Removes ONE registry entry's view notifier by index (guarded), then drops the entry (freeing it,
// which releases its View + Notifier interface refs). By index + drop the ref — never FreeAndNil
// (OTA-refcounted). A torn-down view is marked View=nil/Idx=-1 by Destroyed, so we skip the
// RemoveNotifier for it (never touch a dead view). Guarded so teardown never raises.
procedure _RemoveViewRegAt(AIndex: Integer);
var
  LReg: TReviewViewReg;
begin
  if (GViewRegistry = nil) or (AIndex < 0) or (AIndex >= GViewRegistry.Count) then
    Exit;
  LReg := GViewRegistry[AIndex];
  if Assigned(LReg.View) and (LReg.Idx >= 0) then
    try
      LReg.View.RemoveNotifier(LReg.Idx);
    except
      // teardown must never raise
    end;
  GViewRegistry.Delete(AIndex); // owns the object: frees LReg, releasing View + Notifier
end;

// Teardown: removes EVERY registered view notifier by index and empties the registry. The unload
// law — no AddNotifier may outlive finalization (a dangling notifier is the chronic AV).
procedure _RemoveAllViewNotifiers;
var
  I: Integer;
begin
  if GViewRegistry = nil then
    Exit;
  for I := GViewRegistry.Count - 1 downto 0 do
    _RemoveViewRegAt(I);
end;

// Drops the view notifiers of any unit that no longer has a pending review (tidies the registry as
// units resolve, so we never hold a notifier/view ref for a resolved unit). Like the module twin,
// MUST NOT run inside a view notifier's own callback — the save paths defer it via ForceQueue.
procedure _CleanupResolvedViewNotifiers;
var
  LIndex: Integer;
begin
  if GViewRegistry = nil then
    Exit;
  for LIndex := GViewRegistry.Count - 1 downto 0 do
    if not ReviewHasPendingForUnit(GViewRegistry[LIndex].UnitPath) then
      _RemoveViewRegAt(LIndex);
end;

// Attaches a paint notifier for AUnitPath on AView, keeping exactly ONE per unit. If a notifier
// already watches this unit on this same view, it is a no-op; if the unit's view changed (or the
// old one was torn down), the stale one is removed (by index, guarded) and a fresh one is attached.
// It NEVER removes another unit's notifier (the R8 discipline, mirrored for views). Paired with a
// RemoveNotifier at teardown (_RemoveAllViewNotifiers / _CleanupResolvedViewNotifiers).
procedure _EnsureViewNotifier(const AUnitPath: string; const AView: IOTAEditView);
var
  LReg: TReviewViewReg;
  LNot: TReviewViewNotifier;
begin
  if (GViewRegistry = nil) or (AView = nil) then
    Exit;
  LReg := _FindViewReg(AUnitPath);
  if Assigned(LReg) then
  begin
    if (LReg.View = AView) and (LReg.Idx >= 0) then
      Exit; // already watching this exact view
    // View changed (or was torn down): detach the old notifier by index (guarded) before re-adding.
    if Assigned(LReg.View) and (LReg.Idx >= 0) then
      try
        LReg.View.RemoveNotifier(LReg.Idx);
      except
        // best-effort — the old view may already be gone
      end;
    LReg.View := nil;
    LReg.Idx := -1;
    LReg.Notifier := nil;
  end
  else
  begin
    LReg := TReviewViewReg.Create;
    LReg.UnitPath := AUnitPath;
    GViewRegistry.Add(LReg);
  end;
  LNot := TReviewViewNotifier.Create(AUnitPath);
  LReg.Notifier := LNot; // hold as interface ref (refcounted)
  LReg.View := AView;
  LReg.Idx := -1;
  try
    LReg.Idx := AView.AddNotifier(LNot);
  except
    // AddNotifier failed: nothing was registered, so there is nothing to remove — drop the refs and
    // leave the entry inert. Never leave a half-registered entry behind.
    LReg.Notifier := nil;
    LReg.View := nil;
    LReg.Idx := -1;
    Exit;
  end;
  _InstallMsgHook;
end;

{ ── Module save notifier (manual Ctrl+S / compile) ───────────────────────── }

type
  // Strips the pending "before" blocks before a module write, so a manual save or a
  // compile (neither goes through the MCP save facade) never persists doubled text.
  // Modelled on the codebase's TMCPModuleSaveNotifier: CheckOverwrite returns Boolean and
  // BeforeSave is a name-resolved interface impl (TNotifierObject's is not virtual).
  TReviewModuleNotifier = class(TNotifierObject, IOTANotifier, IOTAModuleNotifier)
  private
    FUnitPath: string; // the unit this notifier watches; BeforeSave resolves ONLY this unit
  public
    constructor Create(const AUnitPath: string);
    procedure BeforeSave;
    function CheckOverwrite: Boolean;
    procedure ModuleRenamed(const NewName: string);
  end;

constructor TReviewModuleNotifier.Create(const AUnitPath: string);
begin
  inherited Create;
  FUnitPath := AUnitPath;
end;

procedure TReviewModuleNotifier.BeforeSave;
begin
  // Manual Ctrl+S / compile of THIS unit. Strip this unit's "before" (red) blocks and drop
  // this unit's changes only, leaving other reviewed units pending (each keeps its own
  // notifier). Guarded: a failure here must never abort the save nor AV the IDE.
  try
    if TGutterReview.ReviewPending then
      _ResolveUnitForSave(FUnitPath);
  except
    // best-effort: never let the save path raise
  end;
end;

function TReviewModuleNotifier.CheckOverwrite: Boolean;
begin
  Result := True;
end;

procedure TReviewModuleNotifier.ModuleRenamed(const NewName: string);
begin
end;

// The registry entry watching AUnitPath, or nil.
function _FindModuleReg(const AUnitPath: string): TReviewModuleReg;
var
  LReg: TReviewModuleReg;
begin
  Result := nil;
  if GModuleRegistry = nil then
    Exit;
  for LReg in GModuleRegistry do
    if SameText(LReg.UnitPath, AUnitPath) then
      Exit(LReg);
end;

// Removes ONE registry entry's module notifier by index, then drops the entry (freeing it,
// which releases its Module + Notifier interface refs). By index + drop the ref — never
// FreeAndNil (OTA-refcounted). Guarded so teardown never raises.
procedure _RemoveModuleRegAt(AIndex: Integer);
var
  LReg: TReviewModuleReg;
begin
  if (GModuleRegistry = nil) or (AIndex < 0) or (AIndex >= GModuleRegistry.Count) then
    Exit;
  LReg := GModuleRegistry[AIndex];
  if Assigned(LReg.Module) and (LReg.Idx >= 0) then
    try
      LReg.Module.RemoveNotifier(LReg.Idx);
    except
      // teardown must never raise
    end;
  GModuleRegistry.Delete(AIndex); // owns the object: frees LReg, releasing Module + Notifier
end;

// Teardown: removes EVERY registered module notifier by index and empties the registry. The
// unload law — no AddNotifier may outlive finalization (a dangling notifier is the chronic AV).
procedure _RemoveAllModuleNotifiers;
var
  I: Integer;
begin
  if GModuleRegistry = nil then
    Exit;
  for I := GModuleRegistry.Count - 1 downto 0 do
    _RemoveModuleRegAt(I);
end;

// Drops the module notifiers of any unit that no longer has a pending review (tidies the
// registry as units resolve, so we never hold a notifier/module ref for a resolved unit).
// MUST NOT run inside a module notifier's own BeforeSave — the save paths defer it via
// TThread.ForceQueue (never remove a notifier from within its own callback).
procedure _CleanupResolvedModuleNotifiers;
var
  LIndex: Integer;
begin
  if GModuleRegistry = nil then
    Exit;
  for LIndex := GModuleRegistry.Count - 1 downto 0 do
    if not ReviewHasPendingForUnit(GModuleRegistry[LIndex].UnitPath) then
      _RemoveModuleRegAt(LIndex);
end;

// Adds a module notifier for AUnitPath ONLY if it does not already have one; it NEVER removes
// another unit's notifier (the R8 fix — every reviewed unit keeps its own so its own save is
// caught). Paired with a RemoveNotifier at teardown (_RemoveAllModuleNotifiers / cleanup).
procedure _EnsureModuleNotifier(const AUnitPath: string);
var
  LMS: IOTAModuleServices;
  LMod: IOTAModule;
  LReg: TReviewModuleReg;
begin
  if GModuleRegistry = nil then
    Exit;
  if _FindModuleReg(AUnitPath) <> nil then
    Exit; // already watching this unit
  if not Supports(BorlandIDEServices, IOTAModuleServices, LMS) then
    Exit;
  LMod := LMS.FindModule(AUnitPath);
  if not Assigned(LMod) then
    Exit;
  LReg := TReviewModuleReg.Create;
  LReg.UnitPath := AUnitPath;
  LReg.Module := LMod;
  LReg.Idx := -1;
  LReg.Notifier := TReviewModuleNotifier.Create(AUnitPath);
  try
    LReg.Idx := LMod.AddNotifier(LReg.Notifier as IOTAModuleNotifier);
  except
    // AddNotifier failed: nothing was registered, so there is nothing to remove — just drop
    // the entry (releasing the notifier ref). Never leave a half-registered entry behind.
    LReg.Free;
    Exit;
  end;
  GModuleRegistry.Add(LReg);
end;

{ ── Pending-change model + line accounting ──────────────────────────────── }

class function TGutterReview.ReviewPending: Boolean;
begin
  Result := Assigned(GChanges) and (GChanges.Count > 0);
end;

class function TGutterReview.ReviewPendingCount: Integer;
begin
  if Assigned(GChanges) then
    Result := GChanges.Count
  else
    Result := 0;
end;

class function TGutterReview.DrainReviewFeedback: string;
begin
  if (GReviewFeedback = nil) or (GReviewFeedback.Count = 0) then
    Exit('');
  Result := GReviewFeedback.Text;
  GReviewFeedback.Clear;
end;

class procedure TGutterReview.RegisterReviewFeedbackTool(const AServer: IMCPServer);
var
  LDesc: TMCPToolDescriptor;
begin
  if not Assigned(AServer) then
    Exit;
  LDesc := Default(TMCPToolDescriptor);
  LDesc.Name := 'GetReviewFeedback';
  LDesc.Title := 'Get review feedback';
  LDesc.Description :=
    'Returns and CLEARS the user''s review annotations on your edits. Each line is ' +
    '"[approved|rejected] <unit-path>:<line> - <note>", so you can tell which change ' +
    'each note refers to and whether it was kept or undone. Call after a batch of ' +
    'edits to learn the user''s feedback. Empty when there are no annotations.';
  LDesc.InputSchema := TJSONObject.Create;
  LDesc.InputSchema.AddPair('type', 'object');
  LDesc.InputSchema.AddPair('properties', TJSONObject.Create);
  LDesc.OutputSchema := TJSONObject.Create;
  LDesc.OutputSchema.AddPair('type', 'object');
  LDesc.Handler :=
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    var
      LObj: TJSONObject;
      LText: string;
      LCount: Integer;
    begin
      Result := Default(TMCPToolResult);
      // Drain on the MAIN thread — _PushFeedback mutates the list there (approve/
      // reject), so marshalling avoids a cross-thread race on the TStringList.
      LText := '';
      if Assigned(AContext) then
        AContext.MarshalToMainThread(
          procedure
          begin
            LText := TGutterReview.DrainReviewFeedback;
          end)
      else
        LText := TGutterReview.DrainReviewFeedback;
      LCount := 0;
      if LText <> '' then
        LCount := Length(LText.Split([sLineBreak], TStringSplitOptions.ExcludeEmpty));
      LObj := TJSONObject.Create;
      try
        LObj.AddPair('feedback', LText);
        LObj.AddPair('count', TJSONNumber.Create(LCount));
        Result.Content := LObj.ToJSON;
      finally
        LObj.Free;
      end;
    end;
  AServer.RegisterTool(LDesc);
end;

// One line per still-pending change. Read-only (does NOT clear). Call on the main
// thread — GChanges is mutated there by paint/approve/reject.
class function TGutterReview.DescribePendingReviews: string;
var
  LChange: TReviewChange;
  LList: TStringList;
begin
  Result := '';
  if (GChanges = nil) or (GChanges.Count = 0) then
    Exit;
  LList := TStringList.Create;
  try
    for LChange in GChanges do
      if LChange.NewTo >= LChange.NewFrom then
        LList.Add(Format('%s:%d-%d  pending (applied to buffer, awaiting approve/reject)',
          [LChange.UnitPath, LChange.NewFrom, LChange.NewTo]))
      else
        LList.Add(Format('%s:%d  pending deletion (awaiting approve/reject)',
          [LChange.UnitPath, LChange.MarkerLine]));
    Result := LList.Text;
  finally
    LList.Free;
  end;
end;

class procedure TGutterReview.RegisterPendingReviewsTool(const AServer: IMCPServer);
var
  LDesc: TMCPToolDescriptor;
begin
  if not Assigned(AServer) then
    Exit;
  LDesc := Default(TMCPToolDescriptor);
  LDesc.Name := 'GetPendingReviews';
  LDesc.Title := 'Get pending reviews';
  LDesc.Description :=
    'Lists the edits currently PENDING in the review gutter — changes already ' +
    'applied to the editor buffer but not yet approved or rejected by the user. Each ' +
    'line is "<unit-path>:<start>-<end>  pending". The review NEVER blocks you: edits ' +
    'apply immediately and are fully readable via ReadUnit/GetMethodBody/GetClassMembers, ' +
    'so use this to know which of your changes are still awaiting the user''s decision ' +
    'and revalidate with confidence. Does NOT clear anything. Empty when nothing is pending.';
  LDesc.InputSchema := TJSONObject.Create;
  LDesc.InputSchema.AddPair('type', 'object');
  LDesc.InputSchema.AddPair('properties', TJSONObject.Create);
  LDesc.OutputSchema := TJSONObject.Create;
  LDesc.OutputSchema.AddPair('type', 'object');
  LDesc.Handler :=
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    var
      LObj: TJSONObject;
      LText: string;
      LCount: Integer;
    begin
      Result := Default(TMCPToolResult);
      // Read on the MAIN thread — GChanges is mutated there (paint/approve/reject),
      // so marshalling avoids a cross-thread race on the list.
      LText := '';
      LCount := 0;
      if Assigned(AContext) then
        AContext.MarshalToMainThread(
          procedure
          begin
            LText := TGutterReview.DescribePendingReviews;
            LCount := TGutterReview.ReviewPendingCount;
          end)
      else
      begin
        LText := TGutterReview.DescribePendingReviews;
        LCount := TGutterReview.ReviewPendingCount;
      end;
      LObj := TJSONObject.Create;
      try
        LObj.AddPair('pending', LText);
        LObj.AddPair('count', TJSONNumber.Create(LCount));
        Result.Content := LObj.ToJSON;
      finally
        LObj.Free;
      end;
    end;
  AServer.RegisterTool(LDesc);
end;

function _FindChangeById(AId: Integer): TReviewChange;
var
  LChange: TReviewChange;
begin
  Result := nil;
  if GChanges = nil then
    Exit;
  for LChange in GChanges do
    if LChange.Id = AId then
      Exit(LChange);
end;

// Shifts the NEW block of every OTHER pending change in AUnitPath below APivotLine.
procedure _AdjustBelow(const AUnitPath: string; APivotLine, ADelta: Integer;
  AExclude: TReviewChange);
var
  LChange: TReviewChange;
begin
  if ADelta = 0 then
    Exit;
  // A change sits entirely above OR below the pivot (changes never overlap), so its TOP
  // line (OldFrom) decides; shift BOTH the red (old) and green (new) blocks together.
  for LChange in GChanges do
    if (LChange <> AExclude) and SameText(LChange.UnitPath, AUnitPath) and (LChange.OldFrom > APivotLine) then
    begin
      Inc(LChange.OldFrom, ADelta);
      Inc(LChange.OldTo, ADelta);
      Inc(LChange.NewFrom, ADelta);
      Inc(LChange.NewTo, ADelta);
    end;
end;

// R4: the stored line coords are ABSOLUTE, and nothing re-anchors them when the USER edits
// the buffer above a still-pending span (INTAEditViewNotifier.Modified is a no-op; _AdjustBelow
// only runs on agent/gutter actions). A user insertion/deletion above a change therefore leaves
// its coords stale, and approve/reject would delete the WRONG lines. Before an interactive
// resolve, re-anchor by the red block's OldText: if that text now sits at a UNIQUE new position,
// shift all four coords to match; if it is ambiguous (>1 occurrence) or gone, leave the coords
// untouched — never worse than before, never a mis-shift. VCL/RTL string ops only, no OTA delta
// needed. Runs once per click (not per keystroke), so reading the whole buffer here is cheap.
procedure _ReanchorChange(const AView: IOTAEditView; AChange: TReviewChange);
var
  LNorm, LOld, LRest: string;
  LFirst, LLine, LIndex, LShift: Integer;
begin
  if (AView = nil) or (AChange = nil) or (AChange.OldLineCount <= 0) or (AChange.OldText = '') then
    Exit;
  LNorm := StringReplace(StringReplace(_BufferText(AView.Buffer), #13#10, #10,
    [rfReplaceAll]), #13, #10, [rfReplaceAll]);
  LOld := StringReplace(StringReplace(AChange.OldText, #13#10, #10, [rfReplaceAll]),
    #13, #10, [rfReplaceAll]).Trim([#10, ' ', #9]);
  if LOld = '' then
    Exit;
  LFirst := Pos(LOld, LNorm);
  if LFirst = 0 then
    Exit; // red text gone (user rewrote it) -> can't relocate safely, leave coords
  LRest := Copy(LNorm, LFirst + Length(LOld), MaxInt);
  if Pos(LOld, LRest) > 0 then
    Exit; // ambiguous (text occurs more than once) -> leave coords, don't guess
  // Unique occurrence: its 1-based start line is the block's true current position.
  LLine := 1;
  for LIndex := 1 to LFirst - 1 do
    if LNorm[LIndex] = #10 then
      Inc(LLine);
  LShift := LLine - AChange.OldFrom;
  if LShift <> 0 then
  begin
    Inc(AChange.OldFrom, LShift);
    Inc(AChange.OldTo, LShift);
    Inc(AChange.NewFrom, LShift);
    Inc(AChange.NewTo, LShift);
  end;
end;

// Applies old->new by inserting the NEW block right AFTER the OLD block — and KEEPS the
// old block in place (struck-out red) for the stacked before/after review. Returns the
// new range and the line delta (= lines added, since nothing was deleted). Approve later
// deletes the old block; reject deletes the new one. The non-blocking buffer therefore
// holds BOTH during review (guarded: BeforeSave/anchor — see _AccumulateEdit).
function _ApplyReviewEdit(const AView: IOTAEditView; AOldFrom, AOldTo: Integer;
  const ANewText: string; out ANewFrom, ANewTo, ADelta: Integer): Boolean;
var
  LNewCount: Integer;
begin
  Result := False;
  if (AView = nil) or (AOldFrom < 1) or (AOldTo < AOldFrom) then
    Exit;
  LNewCount := _InsertBlockAfter(AView, AOldTo, ANewText);
  ANewFrom := AOldTo + 1;
  if LNewCount > 0 then
    ANewTo := AOldTo + LNewCount
  else
    ANewTo := AOldTo; // empty new block (pure deletion): NewTo < NewFrom
  ADelta := LNewCount; // old kept, new added
  Result := True;
end;

// True if [AFrom..ATo] intersects any pending OLD (red) block of AUnit — i.e. the agent
// just anchored to text that is itself a not-yet-resolved "before" block. We refuse such
// edits (facade falls back to silent) rather than corrupt the diff by nesting a change
// inside stale struck-out text.
function _OverlapsPendingOld(const AUnit: string; AFrom, ATo: Integer): Boolean;
var
  LChange: TReviewChange;
begin
  Result := False;
  if GChanges = nil then
    Exit;
  for LChange in GChanges do
    if SameText(LChange.UnitPath, AUnit) and (LChange.OldLineCount > 0) and
       (AFrom <= LChange.OldTo) and (ATo >= LChange.OldFrom) then
      Exit(True);
end;

// Leading whitespace (spaces/tabs) of the 1-based line ALineNo of AText.
function _LineIndent(const AText: string; ALineNo: Integer): string;
var
  LLines: TArray<string>;
  LLine: string;
  LIndex: Integer;
begin
  Result := '';
  if ALineNo < 1 then
    Exit;
  LLines := AText.Replace(#13#10, #10).Replace(#13, #10).Split([#10]);
  if ALineNo > Length(LLines) then
    Exit;
  LLine := LLines[ALineNo - 1];
  LIndex := 1;
  while (LIndex <= Length(LLine)) and CharInSet(LLine[LIndex], [' ', #9]) do
    Inc(LIndex);
  Result := Copy(LLine, 1, LIndex - 1);
end;

// Non-blocking entry: apply the agent's edit and track it as pending. True when the
// edit was located and applied (agent told ddApplied); False falls back to silent.
function _AccumulateEdit(const AUnitPath, AOldText, ANewText: string): Boolean;
var
  LView: IOTAEditView;
  LFrom, LTo, LNewFrom, LNewTo, LDelta: Integer;
  LChange: TReviewChange;
  LBuf, LGreen, LIndent: string;
begin
  Result := False;
  if GChanges = nil then
    Exit;
  if not _ShowUnitSource(AUnitPath) then
    Exit;
  LView := _TopView;
  if LView = nil then
    Exit;
  LBuf := _BufferText(LView.Buffer);
  if not _FindLineRange(LBuf, AOldText, LFrom, LTo) then
    Exit;
  // Guard: don't anchor a new edit inside a pending "before" (red) block.
  if _OverlapsPendingOld(AUnitPath, LFrom, LTo) then
    Exit;
  // Preserve the located line's leading indentation on the GREEN block. An anchored
  // EditUnit passes the raw replacement SUBSTRING (no indent), so the inserted green line
  // would lose the located line's indent and misalign under the +/- markers. Guarded:
  // only restore it when the green's first line has NO leading whitespace (a substring)
  // while the located line does — whole-buffer callers already carry their own indent, so
  // their green (which starts with whitespace) is left untouched.
  LGreen := ANewText;
  if (LGreen <> '') and not CharInSet(LGreen[1], [' ', #9]) then
  begin
    LIndent := _LineIndent(LBuf, LFrom);
    if LIndent <> '' then
      LGreen := LIndent + LGreen;
  end;
  if not _ApplyReviewEdit(LView, LFrom, LTo, LGreen, LNewFrom, LNewTo, LDelta) then
    Exit;
  // We inserted LDelta lines AFTER the old block (which we kept); shift changes below.
  _AdjustBelow(AUnitPath, LTo, LDelta, nil);

  LChange := TReviewChange.Create;
  LChange.Id := GNextId;
  Inc(GNextId);
  LChange.UnitPath := AUnitPath;
  LChange.OldText := AOldText;
  LChange.OldFrom := LFrom;
  LChange.OldTo := LTo;
  LChange.NewFrom := LNewFrom;
  LChange.NewTo := LNewTo;
  LChange.HadRemoval := (LTo - LFrom + 1) > 0;
  GChanges.Add(LChange);

  _EnsureViewNotifier(AUnitPath, LView); // per-unit paint notifier (never disturbs another unit)
  _EnsureModuleNotifier(AUnitPath); // guard manual-save/compile writes
  _Repaint(LView);
  Result := True;
end;

// Reject ONE change: drop the NEW (green) block; the OLD (red) block stays and, once the
// change leaves GChanges, renders as plain code again (= original restored). Fixes the
// line accounting for changes below.
procedure _RejectOne(const AView: IOTAEditView; AChange: TReviewChange);
var
  LCount: Integer;
begin
  if (AView = nil) or (AChange = nil) then
    Exit;
  LCount := AChange.NewLineCount;
  if LCount > 0 then
    _DeleteLineBlock(AView, AChange.NewFrom, AChange.NewTo);
  _AdjustBelow(AChange.UnitPath, AChange.NewTo, -LCount, AChange);
end;

// Approve ONE change: drop the OLD (red) block; the NEW (green) block stays and renders
// as plain code (= the agent's edit kept). Fixes the line accounting for changes below.
procedure _ApproveOne(const AView: IOTAEditView; AChange: TReviewChange);
var
  LCount: Integer;
begin
  if (AView = nil) or (AChange = nil) then
    Exit;
  LCount := AChange.OldLineCount;
  if LCount > 0 then
    _DeleteLineBlock(AView, AChange.OldFrom, AChange.OldTo);
  _AdjustBelow(AChange.UnitPath, AChange.OldTo, -LCount, AChange);
end;

// Save guard: remove every pending OLD (red) block of the active unit from the buffer so a
// save/compile never persists doubled text. The NEW (green) blocks remain (= the final
// text), and the changes stay pending as green-only (their old range collapses to empty, so
// the gutter controls fall back to the new block via TReviewChange.MarkerLine). Deletes
// bottom-up (largest OldFrom first) so each deletion never shifts an as-yet-unprocessed
// block above it; _AdjustBelow then re-accounts the changes that sit below.
// Resolves AUnitPath's CURRENT live edit view so every strip/delete/adjust/reanchor acts on the
// buffer that is really on screen for THIS unit — the R8 orphaned-red fix AND the multi-unit
// corruption fix. It ALWAYS resolves fresh from the unit's module/source editor (materialising a
// view via Show when the editor has none open, the same idiom as _ShowUnitSource) and NEVER trusts
// a cached global slot: a view torn down by a plain editor switch would otherwise be re-used as the
// buffer to mutate, deleting the wrong lines (the pending green block / the unit header) of unit A
// on the way back from unit B. nil when the unit has no source editor at all.
function _ViewForUnit(const AUnitPath: string): IOTAEditView;
var
  LMS: IOTAModuleServices;
  LModule: IOTAModule;
  LSource: IOTASourceEditor;
  LIdx: Integer;
begin
  Result := nil;
  if not Supports(BorlandIDEServices, IOTAModuleServices, LMS) then
    Exit;
  LModule := LMS.FindModule(AUnitPath);
  if not Assigned(LModule) then
    Exit;
  LSource := nil;
  for LIdx := 0 to LModule.GetModuleFileCount - 1 do
    if Supports(LModule.GetModuleFileEditor(LIdx), IOTASourceEditor, LSource) then
      Break;
  if not Assigned(LSource) then
    Exit;
  if LSource.GetEditViewCount = 0 then
    LSource.Show; // materialise a view so a non-visible reviewed unit can still be stripped
  if LSource.GetEditViewCount > 0 then
    Result := LSource.GetEditView(0);
end;

// Strips the pending OLD (red) blocks of AUnitPath from AView's buffer so a save/compile never
// persists doubled text. The NEW (green) blocks remain (= the final text) and each change's old
// range collapses to empty (so its gutter controls fall back to the new block). Deletes bottom-up
// (largest OldFrom first) so a deletion never shifts an as-yet-unprocessed block above it;
// _AdjustBelow re-accounts the changes below. Does NOT drop or repaint — the caller decides
// whether to keep the change pending (green-only) or resolve it.
procedure _StripOldBlocksForUnit(const AUnitPath: string; const AView: IOTAEditView);
var
  LWithOld: array of TReviewChange;
  LChange: TReviewChange;
  LIndex, LInner, LOldLineCount: Integer;
begin
  if (GChanges = nil) or (GChanges.Count = 0) or (AView = nil) or (AUnitPath = '') then
    Exit;
  SetLength(LWithOld, 0);
  for LChange in GChanges do
    if SameText(LChange.UnitPath, AUnitPath) and (LChange.OldLineCount > 0) then
    begin
      SetLength(LWithOld, Length(LWithOld) + 1);
      LWithOld[High(LWithOld)] := LChange;
    end;
  if Length(LWithOld) = 0 then
    Exit;

  // descending by OldFrom (bottom-most block deleted first)
  for LIndex := 0 to High(LWithOld) do
    for LInner := LIndex + 1 to High(LWithOld) do
      if LWithOld[LInner].OldFrom > LWithOld[LIndex].OldFrom then
      begin
        LChange := LWithOld[LIndex]; LWithOld[LIndex] := LWithOld[LInner]; LWithOld[LInner] := LChange;
      end;

  for LIndex := 0 to High(LWithOld) do
  begin
    LChange := LWithOld[LIndex];
    LOldLineCount := LChange.OldLineCount;
    _DeleteLineBlock(AView, LChange.OldFrom, LChange.OldTo);
    // this change's own green block moves up by LOldLineCount; everyone below it shifts up too
    Dec(LChange.NewFrom, LOldLineCount);
    Dec(LChange.NewTo, LOldLineCount);
    _AdjustBelow(LChange.UnitPath, LChange.OldTo, -LOldLineCount, LChange);
    LChange.OldTo := LChange.OldFrom - 1; // collapse the old range to empty (no more red)
  end;
end;

// The VIEW notifier's save path: strips ONE unit's red blocks on that unit's OWN live view,
// keeping the changes pending as green-only. Per-unit — it never reads a global "active" view, so a
// save of unit A can never mutate unit B (and vice-versa). Thin wrapper over _StripOldBlocksForUnit.
procedure _StripOldBlocksForUnitKeepPending(const AUnitPath: string);
var
  LView: IOTAEditView;
begin
  if (GChanges = nil) or (GChanges.Count = 0) then
    Exit;
  LView := _ViewForUnit(AUnitPath);
  if LView = nil then
    Exit;
  _StripOldBlocksForUnit(AUnitPath, LView);
  _ForceFullRepaint(LView);
end;

// Public pre-save flush (interface). Marshals to the main thread (the buffer mutation must
// run there) and strips the pending "before" blocks. Safe to call from any save path.
class procedure TGutterReview.FlushReviewBeforeSave;
begin
  if not TGutterReview.ReviewPending then
    Exit;
  if TThread.CurrentThread.ThreadID = MainThreadID then
    _ResolveAllForSave
  else
    TThread.Synchronize(nil,
      procedure
      begin
        _ResolveAllForSave;
      end);
end;

// Queues a change's annotation for the agent, tagged with how it was resolved.
// Delivered regardless of approve/reject, only when a note was actually written.
procedure _PushFeedback(const ADisposition: string; AChange: TReviewChange);
begin
  if (AChange = nil) or (AChange.Note = '') then
    Exit;
  if GReviewFeedback = nil then
    GReviewFeedback := TStringList.Create;
  // Tagged with origin so the agent can identify EACH note: disposition + full unit
  // path + line + the note. e.g. "[rejected] C:\...\MainForm.pas:98 - prefer TList<T>"
  GReviewFeedback.Add('[' + ADisposition + '] ' + AChange.UnitPath + ':' +
    IntToStr(AChange.NewFrom) + ' - ' + AChange.Note);
end;

procedure _ApproveChange(const AView: IOTAEditView; AChange: TReviewChange);
begin
  if (GChanges = nil) or (AChange = nil) then
    Exit;
  _PushFeedback('approved', AChange); // deliver the note to the agent (if any)
  _ReanchorChange(AView, AChange); // R4: fix stale coords if the user edited above this span
  _ApproveOne(AView, AChange); // drop the red "before" block, keep the green new text
  GChanges.Remove(AChange);
  // Safe here (not inside a notifier callback — this runs from the OnMessage hook): drop the
  // module + view notifiers of any unit whose review is now fully resolved.
  _CleanupResolvedModuleNotifiers;
  _CleanupResolvedViewNotifiers;
  _CleanupIfEmpty;
end;

procedure _RejectChange(const AView: IOTAEditView; AChange: TReviewChange);
begin
  if (GChanges = nil) or (AChange = nil) then
    Exit;
  _PushFeedback('rejected', AChange); // deliver the note to the agent (if any)
  _ReanchorChange(AView, AChange); // R4: fix stale coords if the user edited above this span
  _RejectOne(AView, AChange);
  GChanges.Remove(AChange);
  // Safe here (not inside a notifier callback — this runs from the OnMessage hook): drop the
  // module + view notifiers of any unit whose review is now fully resolved.
  _CleanupResolvedModuleNotifiers;
  _CleanupResolvedViewNotifiers;
  _CleanupIfEmpty;
end;

procedure _CleanupIfEmpty;
begin
  if (GChanges <> nil) and (GChanges.Count = 0) then
  begin
    _RemoveAllViewNotifiers;   // pair EVERY view AddNotifier with a RemoveNotifier (unload law)
    _RemoveAllModuleNotifiers; // pair EVERY module AddNotifier with a RemoveNotifier (unload law)
    _RemoveMsgHook;
  end;
end;

class procedure TGutterReview.ApproveAllChanges;
var
  LIndex: Integer;
  LChange: TReviewChange;
  LView: IOTAEditView;
  LUnits: TStringList;
  LUnit: string;
begin
  if not TGutterReview.ReviewPending then
    Exit;
  // Resolve EACH change on its OWN unit's live view (not merely the top view), so approve-all
  // resolves changes across ALL reviewed units, never just the active one. Bottom-up; each
  // _ApproveOne deletes that change's red block and re-accounts the rest (per unit, via _AdjustBelow
  // which filters by unit), so the remaining changes stay correct whatever the list order.
  LUnits := TStringList.Create;
  try
    LUnits.Sorted := True;
    LUnits.Duplicates := dupIgnore;
    for LChange in GChanges do
      LUnits.Add(LChange.UnitPath);
    for LIndex := GChanges.Count - 1 downto 0 do
    begin
      LChange := GChanges[LIndex];
      _PushFeedback('approved', LChange); // deliver any notes to the agent
      LView := _ViewForUnit(LChange.UnitPath);
      if Assigned(LView) then
        _ApproveOne(LView, LChange);
      GChanges.Delete(LIndex);
    end;
    _CleanupIfEmpty;
    for LUnit in LUnits do
      _ForceFullRepaint(_ViewForUnit(LUnit));
  finally
    LUnits.Free;
  end;
end;

procedure _ResolveAllForSave;
var
  LIndex: Integer;
  LChange: TReviewChange;
  LUnits: TStringList;
  LUnit: string;
  LView: IOTAEditView;
begin
  if not TGutterReview.ReviewPending then
    Exit;
  // Save = accept ALL (the agent SaveAllFiles / facade ForceSave flush saves every file at
  // once). For EVERY distinct pending unit, strip its red blocks on its OWN edit view — so a
  // non-active unit is stripped too, not deleted-but-orphaned (R8 Defect 2, the old code
  // stripped only the active view yet deleted every change) — then deliver notes and drop all
  // changes. Teardown is DEFERRED: this can run inside a notifier's BeforeSave, and removing a
  // notifier during its own callback is unsafe.
  LUnits := TStringList.Create;
  try
    LUnits.Sorted := True;
    LUnits.Duplicates := dupIgnore;
    for LChange in GChanges do
      LUnits.Add(LChange.UnitPath);
    for LUnit in LUnits do
    begin
      LView := _ViewForUnit(LUnit);
      if Assigned(LView) then
        _StripOldBlocksForUnit(LUnit, LView);
    end;
    // Drop every change (bottom-up), delivering any notes as "approved".
    for LIndex := GChanges.Count - 1 downto 0 do
    begin
      LChange := GChanges[LIndex];
      _PushFeedback('approved', LChange);
      GChanges.Delete(LIndex);
    end;
    // Repaint each affected view now the markers are gone.
    for LUnit in LUnits do
    begin
      LView := _ViewForUnit(LUnit);
      if Assigned(LView) then
        _ForceFullRepaint(LView);
    end;
  finally
    LUnits.Free;
  end;
  // Defer notifier/hook teardown to the next main-loop turn (out of any save callback).
  TThread.ForceQueue(nil,
    procedure
    begin
      _CleanupResolvedModuleNotifiers;
      _CleanupResolvedViewNotifiers;
      _CleanupIfEmpty;
    end);
end;

// Save = accept ONE unit (called from that unit's module-notifier BeforeSave on a manual
// Ctrl+S / compile). Strips THIS unit's red blocks on its own view and drops THIS unit's
// changes, leaving other reviewed units pending (each keeps its own notifier). Teardown is
// DEFERRED — we may be inside this unit's own BeforeSave, and removing a notifier from within
// its own callback is exactly the unload AV; TThread.ForceQueue runs it on the next turn.
procedure _ResolveUnitForSave(const AUnitPath: string);
var
  LIndex: Integer;
  LChange: TReviewChange;
  LView: IOTAEditView;
begin
  if not TGutterReview.ReviewPending then
    Exit;
  LView := _ViewForUnit(AUnitPath);
  if Assigned(LView) then
    _StripOldBlocksForUnit(AUnitPath, LView); // strip only THIS unit's red (always — clean disk)
  // ACCEPT (drop the change) ONLY when the user opted into auto-save. With "Wait for my
  // approval" (auto-save OFF), a module save (manual Ctrl+S, compile, or an internal save from
  // e.g. CreateNewUnit) must NOT auto-approve the review: the red is stripped so the disk write
  // is clean, but the change stays pending as green-only so the user still decides. This is the
  // same strip-and-keep-pending the view notifier already does; it just was not honoured here.
  if TReviewGate.ReviewAutoAccept then
    for LIndex := GChanges.Count - 1 downto 0 do
    begin
      LChange := GChanges[LIndex];
      if SameText(LChange.UnitPath, AUnitPath) then
      begin
        _PushFeedback('approved', LChange);
        GChanges.Delete(LIndex);
      end;
    end;
  if Assigned(LView) then
    _ForceFullRepaint(LView); // repaint so stripped red / dropped markers refresh
  TThread.ForceQueue(nil,
    procedure
    begin
      _CleanupResolvedModuleNotifiers;
      _CleanupResolvedViewNotifiers;
      _CleanupIfEmpty;
    end);
end;

class procedure TGutterReview.RejectAllChanges;
var
  LIndex: Integer;
  LChange: TReviewChange;
  LView: IOTAEditView;
  LUnits: TStringList;
  LUnit: string;
begin
  if not TGutterReview.ReviewPending then
    Exit;
  // Resolve EACH change on its OWN unit's live view (not merely the top view), so reject-all
  // restores changes across ALL reviewed units. Bottom-up so each restore's line shift never
  // invalidates a change above it (within a unit; _AdjustBelow filters by unit).
  LUnits := TStringList.Create;
  try
    LUnits.Sorted := True;
    LUnits.Duplicates := dupIgnore;
    for LChange in GChanges do
      LUnits.Add(LChange.UnitPath);
    for LIndex := GChanges.Count - 1 downto 0 do
    begin
      LChange := GChanges[LIndex];
      _PushFeedback('rejected', LChange); // deliver any note to the agent
      LView := _ViewForUnit(LChange.UnitPath);
      if Assigned(LView) then
        _RejectOne(LView, LChange);
      GChanges.Delete(LIndex);
    end;
    _CleanupIfEmpty;
    for LUnit in LUnits do
      _ForceFullRepaint(_ViewForUnit(LUnit));
  finally
    LUnits.Free;
  end;
end;

// Themed note input. InputQuery is an unthemed white box on the dark IDE, so build a
// small form and run it through TThemeHelper.ApplyPremiumTheme (the same themer the consent/options
// dialogs use). ASCII-only caption (an em dash mojibake'd to "a*EUR"). True on OK.
function _PromptNote(var ANote: string): Boolean;
var
  LForm: TForm;
  LLabel: TLabel;
  LEdit: TEdit;
  LOK, LCancel: TButton;
begin
  Result := False;
  LForm := TForm.CreateNew(nil);
  try
    LForm.Caption := 'Aefos - note for the agent';
    LForm.BorderStyle := bsDialog;
    LForm.Position := poScreenCenter;
    LForm.ClientWidth := 500;
    LForm.ClientHeight := 132;
    LLabel := TLabel.Create(LForm);
    LLabel.Parent := LForm;
    LLabel.SetBounds(16, 14, LForm.ClientWidth - 32, 34);
    LLabel.AutoSize := False;
    LLabel.WordWrap := True;
    LLabel.Caption := 'Note about this change (sent to the agent on approve/reject):';
    LEdit := TEdit.Create(LForm);
    LEdit.Parent := LForm;
    LEdit.SetBounds(16, 52, LForm.ClientWidth - 32, 24);
    LEdit.Text := ANote;
    LOK := TButton.Create(LForm);
    LOK.Parent := LForm;
    LOK.Caption := 'OK';
    LOK.ModalResult := mrOk;
    LOK.Default := True;
    LOK.SetBounds(LForm.ClientWidth - 192, 92, 84, 28);
    LCancel := TButton.Create(LForm);
    LCancel.Parent := LForm;
    LCancel.Caption := 'Cancel';
    LCancel.ModalResult := mrCancel;
    LCancel.Cancel := True;
    LCancel.SetBounds(LForm.ClientWidth - 100, 92, 84, 28);
    try
      TThemeHelper.ApplyPremiumTheme(LForm);
    except
      // theming is best-effort
    end;
    if LForm.ShowModal = mrOk then
    begin
      ANote := Trim(LEdit.Text);
      Result := True;
    end;
  finally
    LForm.Free;
  end;
end;

// Opens the annotation input for AChangeId — DEFERRED off the OnMessage handler (a
// modal must not run nested inside message processing) via TThread.ForceQueue, so it
// pops on the next main-loop turn. The note is stored on the change and delivered to
// the agent when the change is later approved or rejected.
procedure _DeferNoteDialog(AChangeId: Integer);
begin
  TThread.ForceQueue(nil,
    procedure
    var
      LChange: TReviewChange;
      LNote: string;
    begin
      LChange := _FindChangeById(AChangeId);
      if LChange = nil then
        Exit;
      LNote := LChange.Note;
      if _PromptNote(LNote) then
      begin
        LChange.Note := LNote;
        _ForceFullRepaint(_ViewForUnit(LChange.UnitPath)); // reflect the annotated state on this unit
      end;
    end);
end;

{ TReviewInputHook — click-to-resolve on the painted controls }

procedure TReviewInputHook.AppMessage(var Msg: TMsg; var Handled: Boolean);
var
  LPt: TPoint;
  LId: Integer;
  LAction: TReviewAction;
  LChange: TReviewChange;
  LView: IOTAEditView;
begin
  if TGutterReview.ReviewPending and (Msg.message = WM_MOUSEMOVE) then
  begin
    LPt := Msg.pt;
    if Msg.hwnd <> 0 then
      ScreenToClient(Msg.hwnd, LPt);
    if _HitTarget(LPt, LId, LAction) then
      Winapi.Windows.SetCursor(Winapi.Windows.LoadCursor(0, IDC_HAND));
  end;

  if TGutterReview.ReviewPending and
     ((Msg.message = WM_LBUTTONDOWN) or (Msg.message = WM_LBUTTONUP)) then
  begin
    LPt := Msg.pt;
    if Msg.hwnd <> 0 then
      ScreenToClient(Msg.hwnd, LPt);
    if _HitTarget(LPt, LId, LAction) then
    begin
      Handled := True; // swallow down+up so the editor doesn't move the caret
      if Msg.message = WM_LBUTTONUP then
      begin
        if LId = 0 then
        begin
          if LAction = raApprove then
            TGutterReview.ApproveAllChanges
          else
            TGutterReview.RejectAllChanges;
        end
        else if LAction = raAnnotate then
          _DeferNoteDialog(LId)
        else
        begin
          LChange := _FindChangeById(LId);
          if LChange <> nil then
          begin
            // Resolve THIS change's own unit view (never a global slot), so the approve/reject
            // mutates the right unit's live buffer even when another unit is the active tab.
            LView := _ViewForUnit(LChange.UnitPath);
            if LAction = raApprove then
              _ApproveChange(LView, LChange)
            else
              _RejectChange(LView, LChange);
            _ForceFullRepaint(LView);
          end;
        end;
      end;
      Exit;
    end;
  end;
  if Assigned(GOldAppOnMessage) then
    GOldAppOnMessage(Msg, Handled);
end;

{ ── Keyboard binding (Ctrl+Alt+R toggles the AI Flow review mode) ─────────── }

type
  TReviewKeyboardBinding = class(TNotifierObject, IOTAKeyboardBinding)
  private
    procedure DoToggleReview(const Context: IOTAKeyContext; KeyCode: TShortcut;
      var BindingResult: TKeyBindingResult);
  public
    function GetBindingType: TBindingType;
    function GetDisplayName: string;
    function GetName: string;
    procedure BindKeyboard(const BindingServices: IOTAKeyBindingServices);
  end;

function TReviewKeyboardBinding.GetBindingType: TBindingType;
begin
  Result := btPartial;
end;

function TReviewKeyboardBinding.GetDisplayName: string;
begin
  Result := 'Aefos Change Review';
end;

function TReviewKeyboardBinding.GetName: string;
begin
  Result := 'Aefos.GutterReview';
end;

procedure TReviewKeyboardBinding.BindKeyboard(
  const BindingServices: IOTAKeyBindingServices);
begin
  BindingServices.AddKeyBinding([ShortCut(Ord('R'), [ssCtrl, ssAlt])],
    DoToggleReview, nil);
end;

procedure TReviewKeyboardBinding.DoToggleReview(const Context: IOTAKeyContext;
  KeyCode: TShortcut; var BindingResult: TKeyBindingResult);
var
  LMode: Integer;
begin
  LMode := (TAIFlowOptions.AgentEditReviewMode + 1) mod 3;
  TAIFlowOptions.SetAgentEditReviewMode(LMode);
  if LMode = 2 then
    MessageBeep(MB_ICONASTERISK)
  else
    MessageBeep(MB_OK);
  BindingResult := krHandled;
end;

{ ── Cross-BPL approval: agent EditUnit -> accumulate (non-blocking) ───────── }

type
  TReviewApprover = class(TInterfacedObject, IMCPDiffApprover)
  public
    function ReviewEdit(const AUnitPath, AOldText,
      ANewText: string; out AReason: string): TMCPDiffDecision;
  end;

function TReviewApprover.ReviewEdit(const AUnitPath, AOldText,
  ANewText: string; out AReason: string): TMCPDiffDecision;
begin
  AReason := '';
  if TAIFlowOptions.AgentEditReviewMode = 2 then
    Exit(ddUnavailable); // Silent: facade applies directly, no review markers
  if _AccumulateEdit(AUnitPath, AOldText, ANewText) then
    Result := ddApplied
  else
    Result := ddUnavailable;
end;

// Predicate behind the facade's review-pending guard (TReviewGate.SetReviewPendingQuery). True while
// AUnitPath still has UNRESOLVED review blocks tracked in GChanges — so a whole-buffer
// rewrite tool (AddEventHandler) refuses rather than corrupt the unit. Pending clears on
// approve/reject (gutter) or save (= accept), after which this reports False and the tool
// proceeds.
function ReviewHasPendingForUnit(const AUnitPath: string): Boolean;
var
  LChange: TReviewChange;
begin
  Result := False;
  if GChanges = nil then
    Exit;
  for LChange in GChanges do
    if SameText(LChange.UnitPath, AUnitPath) then
      Exit(True);
end;

class procedure TGutterReview.RegisterGutterReview;
var
  LKbServices: IOTAKeyboardServices;
begin
  if GChanges = nil then
    GChanges := TObjectList<TReviewChange>.Create(True);
  if GViewRegistry = nil then
    GViewRegistry := TObjectList<TReviewViewReg>.Create(True);
  if GModuleRegistry = nil then
    GModuleRegistry := TObjectList<TReviewModuleReg>.Create(True);
  if GKbIndex < 0 then
    if Supports(BorlandIDEServices, IOTAKeyboardServices, LKbServices) then
      GKbIndex := LKbServices.AddKeyboardBinding(TReviewKeyboardBinding.Create);
  TReviewGate.SetGlobalDiffApprover(TReviewApprover.Create);
  // Expose the pending-review predicate so whole-buffer tools (AddEventHandler) can refuse
  // with 'review-pending' instead of parsing/overwriting a buffer polluted with stacked diffs.
  TReviewGate.SetReviewPendingQuery(
    function(AUnitPath: string): Boolean
    begin
      Result := ReviewHasPendingForUnit(AUnitPath);
    end);
  // GLOBAL twin: the SaveAllFiles guard refuses a save that would auto-accept + clear
  // ANY unresolved ✓/✗ gutter the user has not yet approved/rejected.
  TReviewGate.SetReviewPendingGlobalQuery(
    function: Boolean
    begin
      Result := TGutterReview.ReviewPending;
    end);
  // Pre-save flush: strip "before" blocks before the facade's ForceSave (agent saves).
  TReviewGate.SetReviewSaveFlush(
    procedure
    begin
      TGutterReview.FlushReviewBeforeSave;
    end);
  // Auto-accept gate: reflect the "AI Flow -> Agent auto-save edits" setting so the facade's
  // review-pending guard can let a whole-buffer edit pass (auto-accepting the prior review)
  // instead of refusing when the user has opted into auto-save.
  TReviewGate.SetReviewAutoAccept(
    function: Boolean
    begin
      Result := TAIFlowOptions.AgentAutoSave;
    end);
end;

class procedure TGutterReview.UnregisterGutterReview;
var
  LKbServices: IOTAKeyboardServices;
begin
  TReviewGate.SetGlobalDiffApprover(nil);
  TReviewGate.SetReviewPendingQuery(nil); // drop the predicate seam so it never dangles into an unmapped BPL
  TReviewGate.SetReviewPendingGlobalQuery(nil); // drop the global predicate seam so it never dangles
  TReviewGate.SetReviewSaveFlush(nil); // drop the seam ref so it never dangles into an unmapped BPL
  TReviewGate.SetReviewAutoAccept(nil); // drop the auto-accept seam so it never dangles into an unmapped BPL
  if TGutterReview.ReviewPending then
    GChanges.Clear; // leave the applied text in place; drop the markers
  _RemoveAllViewNotifiers;   // remove EVERY per-view notifier by index while still mapped
  _RemoveAllModuleNotifiers; // remove EVERY per-module notifier by index while still mapped
  _RemoveMsgHook;
  // *** BEFORE CHANGING THIS: read Aefos.OTA.Chat.UnloadContract (the law). ***
  // Remove the binding by index while the code is still mapped.
  if (GKbIndex >= 0) and
     Supports(BorlandIDEServices, IOTAKeyboardServices, LKbServices) then
    try
      LKbServices.RemoveKeyboardBinding(GKbIndex);
    except
      on E: Exception do
        OutputDebugString(PChar(
          '[Aefos] GutterReview RemoveKeyboardBinding: ' + E.Message));
    end;
  GKbIndex := -1;
end;

initialization

finalization
  TGutterReview.UnregisterGutterReview;
  FreeAndNil(GChanges);
  FreeAndNil(GViewRegistry);   // emptied by UnregisterGutterReview's _RemoveAllViewNotifiers
  FreeAndNil(GModuleRegistry); // emptied by UnregisterGutterReview's _RemoveAllModuleNotifiers
  FreeAndNil(GInputHook);
  FreeAndNil(GReviewFeedback);

end.
