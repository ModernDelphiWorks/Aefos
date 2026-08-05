unit Aefos.Lazarus.GutterReview;

{ Aefos AI - Lazarus edition: change-review gutter (INLINE old/new diff slice).

  The Lazarus twin of the RAD Studio "Model B - applied + review" gutter
  (source\mcp\OTA\Aefos.OTA.IDE.GutterReview.pas). It closes the parity gap the
  owner flagged: the Delphi plugin marks an agent's edits for the developer to
  keep or undo, showing the REMOVED (old) text struck-out in red directly above
  the NEW (green) text - a true inline diff (git / VS Code style) - with per-change
  approve / reject / annotate controls in the gutter.

  MODEL B (Cursor / VS Code style), mirrored faithfully:
    - The agent's edit is ALREADY APPLIED to the buffer by the facade
      (Aefos.Lazarus.WorkspaceFacade.EditUnit -> _WriteWholeBuffer). Review NEVER
      blocks the agent; the diff blocks accrue and "sprout" as it works.
    - Right AFTER the write, EditUnit calls NotifyApplied with the OLD whole-buffer
      text and the NEW whole-buffer text. We locate the changed line range (equal
      prefix / suffix skip, the same algorithm as the RAD ChangedSpan), then INJECT
      the OLD lines of that range back into the live buffer as a struck-out RED block
      DIRECTLY ABOVE the NEW green block - exactly the RAD OldFrom/OldTo + NewFrom/NewTo
      stacked model. The developer SEES removed vs added together.
    - APPROVE one change = delete its OLD (red) block; the NEW (green) text stays.
      REJECT one change = delete its NEW (green) block; the OLD (red) text stays and,
      once the change leaves the list, renders as plain code (= original restored).
      Both use line-accounting (_AdjustBelow) so the OTHER pending changes shift
      correctly. ANNOTATE attaches a note delivered to the agent on resolution.
    - Approve All / Reject All (the IDE menu) resolve every pending change at once.

  BUFFER SAFETY - the injected red block would otherwise be persisted as doubled
  old+new text on a save / compile. We register the IDE save hook
  (LazarusIDE.AddHandlerOnSaveEditorFile, sefsBeforeWrite) and, before the disk
  write, STRIP the saved unit's pending red blocks (keeping the changes pending as
  green-only, with line re-accounting). This mirrors the RAD BeforeSave notifier.
  The changes stay pending; a later reject of a stripped (green-only) change
  re-injects the stored OldText, so undo is never lost.

  RENDERING seams (all native, no fragile app-wide message hook):
    - Line-background band: a dedicated TSynEditMarkup (TAefosReviewMarkup) paints the
      whole background of every OLD line RED with a struck-out font style and every NEW
      line GREEN, byte-identical to the RAD CLR_REMOVED_* / CLR_ADDED_* colours.
    - Inline gutter controls: a dedicated TSynGutterPartBase (TAefosReviewGutterPart)
      paints a '-' on old lines, a '+' on new lines, and on the change's TOP (marker)
      line three clickable buttons - CHECK (approve, green), CROSS (reject, red) and a
      PENCIL (annotate, blue). A click routes through the part's MouseDown (the reliable
      Lazarus gutter hit-test seam) and defers the resolve to the next message cycle via
      Application.QueueAsyncCall (approve/reject frees this very part, which must not
      happen inside its own MouseDown).
    - Inline All pill: a dedicated RIGHT-gutter part (TAefosReviewAllPart, TSynGutterPartBase in
      RightGutter.Parts) paints the "Approve All (N) / Reject All" pill on the RIGHT edge of every
      change's marker line - the port of the RAD _PaintAllPill. A right-gutter click lands beyond
      the text (the caret never moves) and routes through the part's MouseDown to ApproveAll /
      RejectAll, deferred via Application.QueueAsyncCall (same collapse-not-free discipline).

  NOTE on accrual: simultaneous red for MANY accrued changes on the SAME unit relies on the
  facade's exactly-once anchor contract (a collision is refused as ambiguous, never corrupted)
  rather than a ported _OverlapsPendingOld guard.

  GATE (Delphi contract, source of truth): TConfig.AgentEditReviewMode is SHARED (one
  brain, %APPDATA%\Aefos\.aefos\config.json). 2 = Apply silently (no review), 0/1 =
  show the review. A config read failure defaults to OFF so a hiccup never sprouts a
  diff nor breaks an edit.

  IDE-UNLOAD DISCIPLINE (CLAUDE.md law): no keyboard binding is added (the menu items
  are IDEIntf-owned for the process lifetime). The finalization cancels any queued
  resolve, REMOVES the save hook (the only IDE-held ref into this package), strips our
  markup / gutter parts / marks from every open editor (by live scan), and frees the
  owned singletons - leaving no dangling reference into this BPL.

  Mode: delphi (string = LCL / IDEIntf UTF-8 AnsiString) like the sibling glue units;
  the facade crosses the delphiunicode boundary by passing explicitly-typed
  UnicodeString whole-buffer values, converted here via LazUTF8. All literals are
  ASCII, so the file needs no BOM. }

{$mode delphi}
{$H+}

interface

uses
  SrcEditorIntf;

type
  { Change-review gutter as a sealed static namespace (never instantiated). The
    pending state and owned singletons live as unit globals for the unload
    discipline (see the finalization). Only the host / facade entry points are public. }
  TAefosLazGutterReview = class
  public
    { True when the review is active - AgentEditReviewMode <> 2 (Delphi contract).
      Read from the SHARED config each call; any failure reports False so a config
      hiccup never sprouts a diff nor aborts an edit. }
    class function ReviewActive: Boolean;
    { True when "Agent auto-save edits" is enabled in the SHARED config
      (TConfig.AgentAutoSave). The Lazarus mirror of the RAD auto-accept predicate
      (Aefos.OTA.IDE.GutterReview.pas:2037 -> TAIFlowOptions.AgentAutoSave). When TRUE the
      diff still SHOWS but is auto-approved on the next save / next edit over it; default
      FALSE (opt-in). Read from the SHARED config each call; any failure reports False so a
      config hiccup never auto-accepts behind the user's back. }
    class function AutoSaveEnabled: Boolean;
    { Model B seam: called by the facade RIGHT AFTER an edit is applied. AOldWhole is
      the pre-edit whole buffer; ANewWhole is the post-edit whole buffer (already in the
      editor). We locate the changed range, inject the OLD lines as a struck-red block
      above the NEW green block, and track the change. No-op when review is inactive,
      the editor is nil, the control is not a TSynEdit, or nothing changed. Never raises
      out - a review failure must not break the agent's applied edit. }
    class procedure NotifyApplied(const AEditor: TSourceEditorInterface;
      const AUnitPath, AOldWhole, ANewWhole: UnicodeString);
    { Auto-save seam: called by the facade BEFORE applying a NEW edit to a unit that still
      has pending (unresolved) changes. When "Agent auto-save edits" is ON, auto-approves
      (strips the red + drops) the unit's prior pending changes so they never stack up
      demanding a manual approve - the RAD facade's "let the edit pass, auto-accepting the
      prior review" intent (Aefos.MCP.OTA.WorkspaceFacade.pas:420-426). No-op when auto-save
      is OFF (the changes keep accruing as today), the editor is nil, or the unit has none
      pending. Never raises out. Main thread only (GChanges). }
    class procedure AutoAcceptUnitOnNewEdit(const AEditor: TSourceEditorInterface);
    { True while at least one change awaits approve / reject. }
    class function Pending: Boolean;
    { Number of pending changes (across all units). }
    class function PendingCount: Integer;
    { Approve ONE change by id: drop its OLD (red) block, keep the NEW (green) text.
      Re-accounts the other pending changes' line ranges. No-op for an unknown id. }
    class procedure ApproveChange(AId: Integer);
    { Reject ONE change by id: drop its NEW (green) block; the OLD (red) text remains
      and, once the change leaves the list, renders as the restored original. When the
      red was already stripped (a save), the stored OldText is re-injected. Re-accounts
      the other pending changes. No-op for an unknown id. }
    class procedure RejectChange(AId: Integer);
    { Attach / edit a note on a change (delivered to the agent on resolution). Prompts
      the developer; no-op on cancel or an unknown id. }
    class procedure AnnotateChange(AId: Integer);
    { Keep every applied edit; drop all reviews (strip the red blocks). Safe no-op. }
    class procedure ApproveAll;
    { Restore every unit's pre-edit text; drop all reviews. Safe no-op. }
    class procedure RejectAll;
    { Returns and CLEARS the accumulated user annotations, one per resolved change:
      "[approved|rejected] <unit>:<line> - <note>". Empty when there are none. For a
      future MCP GetReviewFeedback tool so the agent can fetch the user's feedback. }
    class function DrainReviewFeedback: string;
    { One line per still-PENDING change (read-only; does NOT clear). Each line is
      "<unit>:<from>-<to>  pending ..." or, for a pure deletion (NewTo < NewFrom),
      "<unit>:<line>  pending deletion ...". Mirrors the RAD plugin's
      DescribePendingReviews so the MCP GetPendingReviews tool reports the same shape.
      Call on the MAIN thread - GChanges is mutated there by paint/approve/reject. }
    class function DescribePendingReviews: string;
    { Teardown: cancel queued resolves, remove the save hook, strip our visuals from
      every open editor and clear pending state. Called from finalization (unload law)
      and safe to call repeatedly. }
    class procedure Shutdown;
  end;

implementation

uses
  Classes,
  SysUtils,
  StrUtils,             // PosEx (manual line counting)
  Types,                // TRect / TPoint / Rect / PtInRect
  Contnrs,              // TObjectList (pending changes)
  Controls,             // TCanvas colours, mrOk, TMouseButton
  Graphics,             // TColor, TFontStyle (fsStrikeOut), Canvas ops
  Dialogs,              // InputQuery (annotate prompt)
  Forms,                // Application.QueueAsyncCall (defer approve / reject / note)
  SynEdit,
  SynEditMarks,
  SynEditMarkup,        // TSynEditMarkup base + TLazSynDisplayRtlInfo
  SynEditMiscClasses,   // TSynEditBase, TSynSelectedColor, TLazSynDisplayTokenBound
  SynGutterBase,        // TSynGutterPartBase (the check / cross / note gutter part)
  SynEditMiscProcs,     // ToIdx (view-line -> 0-based index)
  LazSynEditText,       // ViewedTextBuffer.DisplayView.ViewToTextIndex
  LazUTF8,
  LazIDEIntf,           // LazarusIDE save hook (strip red before a disk write)
  ProjectIntf,          // TLazProjectFile (save-hook argument)
  Aefos.OTA.Chat.Core.Config,
  Aefos.OTA.Chat.Core.Config.Types;

const
  { Byte-identical to the RAD plugin's CLR_* (BGR TColor) so the two editions read
    the same. Added / new lines = green band; removed / old lines = red band with a
    struck-out font. Both fore + back are set so the bands read on a dark AND a light
    IDE theme (we never depend on the theme's own colours). }
  CLR_ADDED_BG   = TColor($00204020); // dark green (BGR) - the new-line band
  CLR_ADDED_FG   = TColor($0090E090); // light green (BGR) - the new-line text
  CLR_REMOVED_BG = TColor($00202060); // dark red (BGR) - the old-line band
  CLR_REMOVED_FG = TColor($007070E0); // light red (BGR) - the old-line text (struck)

  { Inline gutter buttons - same BGR greens / reds / blues the RAD _PaintGutterButtons
    uses (CLR_APPROVE / CLR_REJECT / CLR_NOTE / CLR_NOTE_HI, byte-identical). }
  CLR_APPROVE = TColor($004CA64C); // approve button = green (BGR)
  CLR_REJECT  = TColor($004C4CE0); // reject button = red (BGR)
  CLR_NOTE    = TColor($00B0742C); // annotate button = blue (BGR), no note yet
  CLR_NOTE_HI = TColor($00E0A85C); // annotate button = brighter blue when a note exists

type
  { A review marker subclass so a live-list scan can find OUR marks by type (never a
    stored raw pointer). Retained for defensive teardown; no marks are created in this
    slice (the red / green bands + gutter parts carry the review), so the scan simply
    finds none. }
  TAefosReviewMark = class(TSynEditMark)
  end;

  { One 1-based [FromLine..ToLine] band the review paints. Removed => red + struck
    (an OLD block); otherwise green (a NEW block). }
  TAefosReviewBand = record
    FromLine: Integer;
    ToLine: Integer;
    Removed: Boolean;
  end;

  { An inline gutter button set on a change's marker (top) line. }
  TAefosReviewButton = record
    Line: Integer;      // 1-based line carrying the check / cross / note buttons
    ChangeId: Integer;  // the change resolved by a click here
    HasNote: Boolean;   // brighten the pencil when a note already exists
  end;

  { The line-background HIGHLIGHT: a dedicated SynEdit markup (the "right" seam - NOT
    the editor's OnSpecialLine* events, which the source editor itself uses for the
    execution / breakpoint lines). It paints each tracked band's whole line background -
    green for a NEW block, red + struck for an OLD block. One instance per editor,
    re-found by class (never a stored raw pointer); owned by the markup manager, and
    removed + freed explicitly on refresh-to-empty / approve / reject / shutdown. }
  TAefosReviewMarkup = class(TSynEditMarkup)
  private
    FBands: array of TAefosReviewBand;
    FRowInBand: Boolean;   // set per row by PrepareMarkupForRow, read by the getters
    FRowRemoved: Boolean;  // the current row's band is an OLD (red / struck) block
    function _RowInBand(ARow: Integer; out ARemoved: Boolean): Boolean;
    function _RowAttribute: TSynSelectedColor;
  public
    constructor Create(ASynEdit: TSynEditBase);
    procedure ClearBands;
    procedure AddBand(AFrom, ATo: Integer; ARemoved: Boolean);
    function BandCount: Integer;
    procedure PrepareMarkupForRow(aRow: Integer); override;
    function GetMarkupAttributeAtRowCol(const aRow: Integer;
      const aStartCol: TLazSynDisplayTokenBound;
      const AnRtlInfo: TLazSynDisplayRtlInfo): TSynSelectedColor; override;
    procedure GetNextMarkupColAfterRowCol(const aRow: Integer;
      const aStartCol: TLazSynDisplayTokenBound;
      const AnRtlInfo: TLazSynDisplayRtlInfo;
      out ANextPhys, ANextLog: Integer); override;
    function GetMarkupAttributeAtWrapEnd(const aRow: Integer;
      const aWrapCol: TLazSynDisplayTokenBound): TSynSelectedColor; override;
    function RealEnabled: Boolean; override;
  end;

  { INLINE controls: a dedicated gutter part (TSynGutterPartBase, the native Lazarus
    click-target seam - modelled on TSynGutterChanges / TSynGutterMarks). It paints a
    '-' on OLD lines, a '+' on NEW lines, and on each change's marker (top) line three
    clickable buttons: CHECK (approve, green), CROSS (reject, red), PENCIL (annotate).
    Glyphs are drawn as SHAPES (polylines), not font characters, so there is no tofu
    risk on the editor font. A click routes through MouseDown (Lazarus routes a gutter
    click to Parts[PixelToPartIndex(X)].MouseDown), which defers the per-change resolve
    via Application.QueueAsyncCall (approve / reject frees this very part; freeing self
    mid-callback is the classic dangling-pointer AV). One per editor, re-found by class. }
  TAefosReviewGutterPart = class(TSynGutterPartBase)
  private
    FButtons: array of TAefosReviewButton;
    FOldLines: array of Integer;
    FNewLines: array of Integer;
    function _ButtonAt(ALine: Integer; out AButton: TAefosReviewButton): Boolean;
    function _IsOldLine(ALine: Integer): Boolean;
    function _IsNewLine(ALine: Integer): Boolean;
    // Three button squares (approve / reject / note) for a line whose top pixel is ATopY.
    // AValid is False when the part is too narrow to host readable buttons.
    procedure _ButtonRects(ATopY: Integer;
      out AApprove, AReject, ANote: TRect; out AValid: Boolean);
  protected
    function PreferedWidth: Integer; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure ClearAll;
    procedure AddButton(ALine, AChangeId: Integer; AHasNote: Boolean);
    procedure AddOldLine(ALine: Integer);
    procedure AddNewLine(ALine: Integer);
    procedure Paint(Canvas: TCanvas; AClip: TRect; FirstLine, LastLine: Integer); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
  end;

  { INLINE "Approve All (N) / Reject All" pill on the editor body's RIGHT edge - the port of
    the RAD _PaintAllPill (Aefos.OTA.IDE.GutterReview.pas:655), painted on EVERY change's
    marker (top) line so the user resolves everything from wherever they are.

    Implemented as a RIGHT-gutter part (TSynGutterPartBase in ASyn.RightGutter.Parts, the
    native Lazarus seam - NOT a message hook). This mirrors the RAD position (LineRect.Right,
    i.e. the far right of the viewport) and inherits the whole proven left-part discipline:
      * Paint reaches the far-right column; MouseDown is routed by TSynGutter.PixelToPartIndex
        with a CLIENT-relative X (verified in synedit.pp: FRightGutter.MouseDown gets the raw
        client X, and PixelToPartIndex subtracts the gutter Left) - so the same PtInRect vs
        Left-based rects the left part uses works unchanged.
      * A right-gutter click lands BEYOND the text area, so the caret never moves - the clean
        equivalent of the RAD hook swallowing the down/up to keep the caret still.
      * ApproveAll / RejectAll are DEFERRED via Application.QueueAsyncCall (they collapse - never
        free - this part, so TSynGutter.FMouseDownPart never dangles; see _CollapseVisuals).
    The right gutter carries no stock parts (CreateDefaultGutterParts is left-only), so this is
    its sole part; one per editor, re-found by class, freed only at teardown / editor-strip.
    Glyphs are drawn as SHAPES (reusing _DrawGlyphButton), the "All (N)" caption as ASCII text -
    no font-glyph tofu risk. }
  TAefosReviewAllPart = class(TSynGutterPartBase)
  private
    FMarkerLines: array of Integer; // 1-based lines that carry the All pill
    FPendingCount: Integer;         // N shown in the approve pill caption
    function _IsMarkerLine(ALine: Integer): Boolean;
    function _CaptionApprove: string;
    function _CaptionReject: string;
    function _MeasureWidth: Integer;
    // Approve / reject pill rects for a marker row whose top pixel is ATopY, right-aligned
    // within [Left..Left+Width] (reject rightmost, approve to its left - the RAD order).
    // AValid is False when the column is too narrow to host a readable pill.
    procedure _PillRects(ATopY: Integer; out AApprove, AReject: TRect; out AValid: Boolean);
  protected
    function PreferedWidthAtCurrentPPI: Integer; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure ClearAll;
    procedure AddMarkerLine(ALine: Integer);
    procedure SetPendingCount(ACount: Integer);
    procedure RecalcSize; // re-measure the column when the caption (N) changed
    procedure Paint(Canvas: TCanvas; AClip: TRect; FirstLine, LastLine: Integer); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
  end;

  { Carrier for the DEFERRED per-change resolve dispatched from the gutter part's
    MouseDown via Application.QueueAsyncCall (an of-object method is required). The
    change id rides in the PtrInt payload. Freeing the clicked part happens inside the
    resolve, safely AFTER the mouse handler returned. Singleton; teardown cancels any
    pending call then frees it (unload law). }
  TReviewDeferred = class
  public
    procedure DoApprove(AData: PtrInt);
    procedure DoReject(AData: PtrInt);
    procedure DoNote(AData: PtrInt);
    // All-at-once resolve dispatched from the inline All pill's MouseDown (AData ignored).
    procedure DoApproveAll(AData: PtrInt);
    procedure DoRejectAll(AData: PtrInt);
  end;

  { The IDE save hook (LazarusIDE.AddHandlerOnSaveEditorFile). Before a disk write it
    strips the saved unit's pending red blocks so the file never persists doubled
    old+new text; the changes stay pending as green-only. Singleton; removed at
    finalization (unload law - the only IDE-held ref into this package). }
  TReviewSaveHook = class
  public
    function OnSaveEditorFile(Sender: TObject; aFile: TLazProjectFile;
      SaveStep: TSaveEditorFileStep; TargetFilename: string): TModalResult;
  end;

  { One accumulated, already-applied edit awaiting approve / reject. Raw mark pointers
    are NOT stored (they dangle if the editor closes) - visuals are re-found by class
    on the live editor. }
  TReviewChange = class
  public
    Id: Integer;                 // stable identity (gutter hit-test -> this change)
    EditorName: string;          // the editor's stored FileName (re-resolves the editor)
    PreEditWhole: UnicodeString; // whole buffer BEFORE this edit (RejectAll restores it)
    OldText: string;             // the OLD lines (UTF-8, buffer EOL); '' for a pure add
    OldFrom, OldTo: Integer;     // struck RED block; OldTo < OldFrom => no red in buffer
    NewFrom, NewTo: Integer;     // GREEN block; NewTo < NewFrom => empty (a pure deletion)
    Note: string;                // user annotation, delivered to the agent on resolution
    function OldLineCount: Integer;
    function NewLineCount: Integer;
    function MarkerLine: Integer; // top of the change (OldFrom when red present, else NewFrom)
  end;

  { Config-root resolver as an object method so it binds to the shared core's
    TConfigRootResolver (a `function: string of object`), exactly as the AI Flow
    options page does. A class-static method would not be `of object`. }
  TReviewConfigRoot = class
  public
    function Resolve: UnicodeString;
  end;

var
  { Pending changes (OwnsObjects: clearing frees them). Lazily created. }
  GChanges: TObjectList = nil;
  { Monotonic change-id source (never reset within a session). }
  GNextId: Integer = 0;
  { Singleton config-root resolver object. }
  GRootObj: TReviewConfigRoot = nil;
  { Singleton carrier for the deferred approve / reject / note. }
  GDeferred: TReviewDeferred = nil;
  { Singleton IDE save hook + its installed flag. }
  GSaveHook: TReviewSaveHook = nil;
  GSaveHookInstalled: Boolean = False;
  { Accumulated annotations delivered to the agent on resolution. }
  GReviewFeedback: TStringList = nil;

function TReviewConfigRoot.Resolve: UnicodeString;
begin
  // %APPDATA%\Aefos - the SAME global root the RAD plugin and the AI Flow page use,
  // so the read is exactly %APPDATA%\Aefos\.aefos\config.json (one brain).
  Result := UTF8ToUTF16(SysUtils.GetEnvironmentVariable('APPDATA') + '\Aefos');
end;

{ ── TReviewChange ────────────────────────────────────────────────────────── }

function TReviewChange.OldLineCount: Integer;
begin
  Result := OldTo - OldFrom + 1;
  if Result < 0 then
    Result := 0;
end;

function TReviewChange.NewLineCount: Integer;
begin
  Result := NewTo - NewFrom + 1;
  if Result < 0 then
    Result := 0;
end;

function TReviewChange.MarkerLine: Integer;
begin
  if OldLineCount > 0 then
    Result := OldFrom
  else
    Result := NewFrom;
end;

{ ── TAefosReviewMarkup (the red / green line-background bands) ────────────── }

constructor TAefosReviewMarkup.Create(ASynEdit: TSynEditBase);
begin
  inherited Create(ASynEdit);
  MarkupInfo.Background := CLR_ADDED_BG;
  MarkupInfo.Foreground := CLR_ADDED_FG;
  MarkupInfo.Style := [];
  MarkupInfo.StyleMask := [];
end;

procedure TAefosReviewMarkup.ClearBands;
begin
  SetLength(FBands, 0);
end;

procedure TAefosReviewMarkup.AddBand(AFrom, ATo: Integer; ARemoved: Boolean);
var
  LIdx: Integer;
begin
  if ATo < AFrom then
    Exit; // an empty block (e.g. a pure deletion's green) contributes no band
  LIdx := Length(FBands);
  SetLength(FBands, LIdx + 1);
  FBands[LIdx].FromLine := AFrom;
  FBands[LIdx].ToLine := ATo;
  FBands[LIdx].Removed := ARemoved;
end;

function TAefosReviewMarkup.BandCount: Integer;
begin
  Result := Length(FBands);
end;

function TAefosReviewMarkup._RowInBand(ARow: Integer; out ARemoved: Boolean): Boolean;
var
  LIdx: Integer;
begin
  Result := False;
  ARemoved := False;
  for LIdx := 0 to High(FBands) do
    if (ARow >= FBands[LIdx].FromLine) and (ARow <= FBands[LIdx].ToLine) then
    begin
      ARemoved := FBands[LIdx].Removed;
      Exit(True);
    end;
end;

// Colours MarkupInfo for the current row (red + struck for an OLD block, green for a
// NEW block) and returns it. StyleMask forces the strike-out bit either on (red) or off
// (green) so the band never depends on the syntax highlighter's own style.
function TAefosReviewMarkup._RowAttribute: TSynSelectedColor;
begin
  if FRowRemoved then
  begin
    MarkupInfo.Background := CLR_REMOVED_BG;
    MarkupInfo.Foreground := CLR_REMOVED_FG;
    MarkupInfo.Style := [fsStrikeOut];
    MarkupInfo.StyleMask := [fsStrikeOut];
  end
  else
  begin
    MarkupInfo.Background := CLR_ADDED_BG;
    MarkupInfo.Foreground := CLR_ADDED_FG;
    MarkupInfo.Style := [];
    MarkupInfo.StyleMask := [fsStrikeOut];
  end;
  MarkupInfo.SetFrameBoundsPhys(1, MaxInt); // whole-line span (as the stock special-line markup)
  Result := MarkupInfo;
end;

procedure TAefosReviewMarkup.PrepareMarkupForRow(aRow: Integer);
begin
  // aRow is the real 1-based text line (lazsyntextarea passes CurTextIndex + 1).
  FRowInBand := _RowInBand(aRow, FRowRemoved);
end;

function TAefosReviewMarkup.GetMarkupAttributeAtRowCol(const aRow: Integer;
  const aStartCol: TLazSynDisplayTokenBound;
  const AnRtlInfo: TLazSynDisplayRtlInfo): TSynSelectedColor;
begin
  Result := nil;
  if FRowInBand then
    Result := _RowAttribute;
end;

procedure TAefosReviewMarkup.GetNextMarkupColAfterRowCol(const aRow: Integer;
  const aStartCol: TLazSynDisplayTokenBound;
  const AnRtlInfo: TLazSynDisplayRtlInfo;
  out ANextPhys, ANextLog: Integer);
begin
  ANextLog := -1;
  ANextPhys := -1; // valid for the whole line
end;

function TAefosReviewMarkup.GetMarkupAttributeAtWrapEnd(const aRow: Integer;
  const aWrapCol: TLazSynDisplayTokenBound): TSynSelectedColor;
begin
  Result := nil;
  if FRowInBand then
    Result := _RowAttribute;
end;

function TAefosReviewMarkup.RealEnabled: Boolean;
begin
  Result := Enabled and (not IsTempDisabled) and (Length(FBands) > 0);
end;

{ ── TReviewDeferred (deferred per-change resolve) ────────────────────────── }

procedure _EnsureDeferred; forward;
// Auto-approves (drops) a unit's pending changes. Defined after _PushFeedback (which it
// needs) but used earlier by the save hook, so forward-declared here.
procedure _DropChangesForUnit(const AEditorName: string); forward;

procedure TReviewDeferred.DoApprove(AData: PtrInt);
begin
  try
    TAefosLazGutterReview.ApproveChange(Integer(AData));
  except
    // best-effort: a deferred resolve must never crash the IDE message loop
  end;
end;

procedure TReviewDeferred.DoReject(AData: PtrInt);
begin
  try
    TAefosLazGutterReview.RejectChange(Integer(AData));
  except
    // best-effort
  end;
end;

procedure TReviewDeferred.DoNote(AData: PtrInt);
begin
  try
    TAefosLazGutterReview.AnnotateChange(Integer(AData));
  except
    // best-effort
  end;
end;

procedure TReviewDeferred.DoApproveAll(AData: PtrInt);
begin
  try
    TAefosLazGutterReview.ApproveAll;
  except
    // best-effort: a deferred resolve must never crash the IDE message loop
  end;
end;

procedure TReviewDeferred.DoRejectAll(AData: PtrInt);
begin
  try
    TAefosLazGutterReview.RejectAll;
  except
    // best-effort
  end;
end;

{ ── TAefosReviewGutterPart (inline -/+ markers + check / cross / note) ───── }

// Fills ARect with ABg, then strokes AGlyph ('v' = check, 'x' = cross, 'e' = pencil) in
// white as a polyline (font-independent, no tofu). Proportions echo the RAD glyphs.
procedure _DrawGlyphButton(const ACanvas: TCanvas; const ARect: TRect; ABg: TColor;
  AGlyph: Char);
var
  LW, LH: Integer;
begin
  ACanvas.Brush.Style := bsSolid;
  ACanvas.Brush.Color := ABg;
  ACanvas.FillRect(ARect);
  LW := ARect.Right - ARect.Left;
  LH := ARect.Bottom - ARect.Top;
  ACanvas.Pen.Color := clWhite;
  ACanvas.Pen.Width := 2;
  ACanvas.Pen.Style := psSolid;
  case AGlyph of
    'v':
      begin
        // checkmark: down to the low elbow, then up to the tip
        ACanvas.MoveTo(ARect.Left + LW * 3 div 10, ARect.Top + LH div 2);
        ACanvas.LineTo(ARect.Left + LW * 9 div 20, ARect.Top + LH * 7 div 10);
        ACanvas.LineTo(ARect.Left + LW * 3 div 4, ARect.Top + LH * 3 div 10);
      end;
    'x':
      begin
        // cross: two diagonals
        ACanvas.MoveTo(ARect.Left + LW div 4, ARect.Top + LH div 4);
        ACanvas.LineTo(ARect.Right - LW div 4, ARect.Bottom - LH div 4);
        ACanvas.MoveTo(ARect.Right - LW div 4, ARect.Top + LH div 4);
        ACanvas.LineTo(ARect.Left + LW div 4, ARect.Bottom - LH div 4);
      end;
    else
      begin
        // pencil: a diagonal body (lower-left -> upper-right) with a small tip notch
        ACanvas.MoveTo(ARect.Left + LW div 4, ARect.Bottom - LH div 4);
        ACanvas.LineTo(ARect.Right - LW div 4, ARect.Top + LH div 4);
        ACanvas.Pen.Width := 1;
        ACanvas.MoveTo(ARect.Right - LW div 4, ARect.Top + LH div 4);
        ACanvas.LineTo(ARect.Right - LW div 2, ARect.Top + LH div 4);
        ACanvas.MoveTo(ARect.Right - LW div 4, ARect.Top + LH div 4);
        ACanvas.LineTo(ARect.Right - LW div 4, ARect.Top + LH div 2);
      end;
  end;
  ACanvas.Pen.Width := 1;
end;

// Draws a 1-char diff sign (AChar = '-' old / '+' new) in AColor, centred in the part
// column on the line whose top pixel is ATopY.
procedure _DrawSign(const ACanvas: TCanvas; ALeft, AWidth, ATopY, ALineHeight: Integer;
  AColor: TColor; AChar: Char);
var
  LX, LY: Integer;
begin
  ACanvas.Brush.Style := bsClear;
  ACanvas.Font.Color := AColor;
  ACanvas.Font.Style := [fsBold];
  LX := ALeft + (AWidth - ACanvas.TextWidth(AChar)) div 2;
  LY := ATopY + (ALineHeight - ACanvas.TextHeight(AChar)) div 2;
  ACanvas.TextOut(LX, LY, AChar);
end;

constructor TAefosReviewGutterPart.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  MarkupInfo.Background := clNone; // transparent column: we paint markers, not a band
end;

function TAefosReviewGutterPart.PreferedWidth: Integer;
var
  LSz: Integer;
begin
  // Room for three square buttons at the line height (scaled), capped so the gutter
  // never eats the code area.
  if (SynEdit <> nil) and (SynEdit.LineHeight > 0) then
    LSz := SynEdit.LineHeight - 2
  else
    LSz := 14;
  if LSz < 12 then
    LSz := 12;
  if LSz > 18 then
    LSz := 18;
  Result := LSz * 3 + 6;
end;

procedure TAefosReviewGutterPart.ClearAll;
begin
  SetLength(FButtons, 0);
  SetLength(FOldLines, 0);
  SetLength(FNewLines, 0);
end;

procedure TAefosReviewGutterPart.AddButton(ALine, AChangeId: Integer; AHasNote: Boolean);
var
  LIdx: Integer;
begin
  if ALine < 1 then
    Exit;
  LIdx := Length(FButtons);
  SetLength(FButtons, LIdx + 1);
  FButtons[LIdx].Line := ALine;
  FButtons[LIdx].ChangeId := AChangeId;
  FButtons[LIdx].HasNote := AHasNote;
end;

procedure TAefosReviewGutterPart.AddOldLine(ALine: Integer);
var
  LIdx: Integer;
begin
  if ALine < 1 then
    Exit;
  LIdx := Length(FOldLines);
  SetLength(FOldLines, LIdx + 1);
  FOldLines[LIdx] := ALine;
end;

procedure TAefosReviewGutterPart.AddNewLine(ALine: Integer);
var
  LIdx: Integer;
begin
  if ALine < 1 then
    Exit;
  LIdx := Length(FNewLines);
  SetLength(FNewLines, LIdx + 1);
  FNewLines[LIdx] := ALine;
end;

function TAefosReviewGutterPart._ButtonAt(ALine: Integer;
  out AButton: TAefosReviewButton): Boolean;
var
  LIdx: Integer;
begin
  Result := False;
  AButton := Default(TAefosReviewButton);
  for LIdx := 0 to High(FButtons) do
    if FButtons[LIdx].Line = ALine then
    begin
      AButton := FButtons[LIdx];
      Exit(True);
    end;
end;

function TAefosReviewGutterPart._IsOldLine(ALine: Integer): Boolean;
var
  LIdx: Integer;
begin
  Result := False;
  for LIdx := 0 to High(FOldLines) do
    if FOldLines[LIdx] = ALine then
      Exit(True);
end;

function TAefosReviewGutterPart._IsNewLine(ALine: Integer): Boolean;
var
  LIdx: Integer;
begin
  Result := False;
  for LIdx := 0 to High(FNewLines) do
    if FNewLines[LIdx] = ALine then
      Exit(True);
end;

procedure TAefosReviewGutterPart._ButtonRects(ATopY: Integer;
  out AApprove, AReject, ANote: TRect; out AValid: Boolean);
var
  LSz, LThird, LPad, LY: Integer;
begin
  AApprove := Rect(0, 0, 0, 0);
  AReject := Rect(0, 0, 0, 0);
  ANote := Rect(0, 0, 0, 0);
  LSz := SynEdit.LineHeight - 2;
  LThird := (Width - 4) div 3;
  if LSz > LThird then
    LSz := LThird;
  AValid := LSz >= 6;
  if not AValid then
    Exit;
  LPad := (SynEdit.LineHeight - LSz) div 2; // vertical-centre the squares on the line
  LY := ATopY + LPad;
  AApprove := Rect(Left + 1, LY, Left + 1 + LSz, LY + LSz);
  AReject := Rect(Left + 2 + LSz, LY, Left + 2 + 2 * LSz, LY + LSz);
  ANote := Rect(Left + 3 + 2 * LSz, LY, Left + 3 + 3 * LSz, LY + LSz);
end;

procedure TAefosReviewGutterPart.Paint(Canvas: TCanvas; AClip: TRect;
  FirstLine, LastLine: Integer);
var
  LView, LCount, LLineHeight, LTopIdx, LTextIdx, LRcTop, LRcBottom, LLine: Integer;
  LApprove, LReject, LNote: TRect;
  LValid: Boolean;
  LButton: TAefosReviewButton;
begin
  if not Visible then
    Exit;
  PaintBackground(Canvas, AClip);
  if (Length(FButtons) = 0) and (Length(FOldLines) = 0) and (Length(FNewLines) = 0) then
    Exit;
  LLineHeight := SynEdit.LineHeight;
  if LLineHeight <= 0 then
    Exit;
  LCount := SynEdit.Lines.Count;
  LTopIdx := ToIdx(GutterArea.TextArea.TopLine);
  LRcBottom := AClip.Top;
  for LView := LTopIdx + FirstLine to LTopIdx + LastLine do
  begin
    LTextIdx := ViewedTextBuffer.DisplayView.ViewToTextIndex(LView);
    if (LTextIdx < 0) or (LTextIdx >= LCount) then
      Break;
    LRcTop := LRcBottom;
    Inc(LRcBottom, LLineHeight);
    LLine := LTextIdx + 1;
    if _ButtonAt(LLine, LButton) then
    begin
      _ButtonRects(LRcTop, LApprove, LReject, LNote, LValid);
      if not LValid then
        Continue;
      _DrawGlyphButton(Canvas, LApprove, CLR_APPROVE, 'v'); // approve = green check
      _DrawGlyphButton(Canvas, LReject, CLR_REJECT, 'x');   // reject = red cross
      if LButton.HasNote then
        _DrawGlyphButton(Canvas, LNote, CLR_NOTE_HI, 'e')
      else
        _DrawGlyphButton(Canvas, LNote, CLR_NOTE, 'e');     // annotate = blue pencil
    end
    else if _IsOldLine(LLine) then
      _DrawSign(Canvas, Left, Width, LRcTop, LLineHeight, CLR_REMOVED_FG, '-')
    else if _IsNewLine(LLine) then
      _DrawSign(Canvas, Left, Width, LRcTop, LLineHeight, CLR_ADDED_FG, '+');
  end;
end;

procedure TAefosReviewGutterPart.MouseDown(Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  LLineHeight, LTextTop, LScreenRow, LView, LTextIdx, LLineTopY: Integer;
  LApprove, LReject, LNote: TRect;
  LValid: Boolean;
  LButton: TAefosReviewButton;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if Button <> Controls.mbLeft then
    Exit;
  if Length(FButtons) = 0 then
    Exit;
  LLineHeight := SynEdit.LineHeight;
  if LLineHeight <= 0 then
    Exit;
  LTextTop := GutterArea.TextArea.TextBounds.Top;
  if Y < LTextTop then
    Exit;
  LScreenRow := (Y - LTextTop) div LLineHeight;
  LView := ToIdx(GutterArea.TextArea.TopLine) + LScreenRow;
  LTextIdx := ViewedTextBuffer.DisplayView.ViewToTextIndex(LView);
  if (LTextIdx < 0) or (LTextIdx >= SynEdit.Lines.Count) then
    Exit;
  if not _ButtonAt(LTextIdx + 1, LButton) then
    Exit;
  LLineTopY := LTextTop + LScreenRow * LLineHeight;
  _ButtonRects(LLineTopY, LApprove, LReject, LNote, LValid);
  if not LValid then
    Exit;
  // DEFER: approve / reject frees THIS part (drops the review visuals); freeing self
  // inside our own MouseDown is the classic dangling-pointer AV (TSynGutter re-touches
  // the part right after MouseDown returns), so hand off to the next message cycle.
  _EnsureDeferred;
  if PtInRect(LApprove, Point(X, Y)) then
    Application.QueueAsyncCall(GDeferred.DoApprove, LButton.ChangeId)
  else if PtInRect(LReject, Point(X, Y)) then
    Application.QueueAsyncCall(GDeferred.DoReject, LButton.ChangeId)
  else if PtInRect(LNote, Point(X, Y)) then
    Application.QueueAsyncCall(GDeferred.DoNote, LButton.ChangeId);
end;

{ ── TAefosReviewAllPart (inline Approve All / Reject All pill) ────────────── }

// One filled pill: ABg background, a white glyph SHAPE ('v' = check / 'x' = cross) in a
// square at the left, then ACaption ('All (N)' / 'All') in white bold. Font-independent glyph
// (no tofu), ASCII caption. Mirrors the RAD _PaintButton look for the All pill.
procedure _DrawAllPill(const ACanvas: TCanvas; const ARect: TRect; ABg: TColor;
  AGlyph: Char; const ACaption: string);
var
  LGlyphSz, LGlyphY, LTextX, LTextY: Integer;
  LGlyphRc: TRect;
begin
  ACanvas.Brush.Style := bsSolid;
  ACanvas.Brush.Color := ABg;
  ACanvas.FillRect(ARect);
  // Glyph square: line-height sized, inset + vertically centred inside the pill.
  LGlyphSz := (ARect.Bottom - ARect.Top) - 4;
  if LGlyphSz < 8 then
    LGlyphSz := 8;
  LGlyphY := ARect.Top + ((ARect.Bottom - ARect.Top) - LGlyphSz) div 2;
  LGlyphRc := Rect(ARect.Left + 3, LGlyphY, ARect.Left + 3 + LGlyphSz, LGlyphY + LGlyphSz);
  // The glyph shape strokes white on its own fill; keep the pill background under it.
  _DrawGlyphButton(ACanvas, LGlyphRc, ABg, AGlyph);
  // Caption after the glyph, white bold, vertically centred.
  ACanvas.Brush.Style := bsClear;
  ACanvas.Font.Color := clWhite;
  ACanvas.Font.Style := [fsBold];
  LTextX := LGlyphRc.Right + 3;
  LTextY := ARect.Top + ((ARect.Bottom - ARect.Top) - ACanvas.TextHeight(ACaption)) div 2;
  ACanvas.TextOut(LTextX, LTextY, ACaption);
end;

constructor TAefosReviewAllPart.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  MarkupInfo.Background := clNone; // the column blends with the editor body (filled in Paint)
  FPendingCount := 0;
end;

function TAefosReviewAllPart._IsMarkerLine(ALine: Integer): Boolean;
var
  LIdx: Integer;
begin
  Result := False;
  for LIdx := 0 to High(FMarkerLines) do
    if FMarkerLines[LIdx] = ALine then
      Exit(True);
end;

function TAefosReviewAllPart._CaptionApprove: string;
begin
  Result := 'All (' + IntToStr(FPendingCount) + ')';
end;

function TAefosReviewAllPart._CaptionReject: string;
begin
  Result := 'All';
end;

// Measures the two pills at the editor's actual (current-PPI) bold font, so the reserved
// right column is exactly wide enough. Each pill = [pad][glyph square][gap][caption][pad];
// a small gap separates the two, plus a right margin off the viewport edge.
function TAefosReviewAllPart._MeasureWidth: Integer;
var
  LBmp: TBitmap;
  LGlyphSz, LWa, LWr: Integer;
begin
  Result := 0;
  if SynEdit = nil then
    Exit;
  LGlyphSz := SynEdit.LineHeight - 4;
  if LGlyphSz < 8 then
    LGlyphSz := 8;
  LBmp := TBitmap.Create;
  try
    LBmp.Canvas.Font.Assign(TCustomSynEdit(SynEdit).Font);
    LBmp.Canvas.Font.Style := [fsBold];
    LWa := LBmp.Canvas.TextWidth(_CaptionApprove);
    LWr := LBmp.Canvas.TextWidth(_CaptionReject);
  finally
    LBmp.Free;
  end;
  // per pill: 3 (left pad) + glyph + 3 (gap) + text + 5 (right pad); + 4 between pills + 4 margin
  Result := (3 + LGlyphSz + 3 + LWa + 5) + (3 + LGlyphSz + 3 + LWr + 5) + 4 + 4;
end;

function TAefosReviewAllPart.PreferedWidthAtCurrentPPI: Integer;
begin
  if (SynEdit = nil) or (Length(FMarkerLines) = 0) then
    Exit(0);
  Result := _MeasureWidth;
end;

procedure TAefosReviewAllPart.ClearAll;
begin
  SetLength(FMarkerLines, 0);
end;

procedure TAefosReviewAllPart.AddMarkerLine(ALine: Integer);
var
  LIdx: Integer;
begin
  if ALine < 1 then
    Exit;
  LIdx := Length(FMarkerLines);
  SetLength(FMarkerLines, LIdx + 1);
  FMarkerLines[LIdx] := ALine;
end;

procedure TAefosReviewAllPart.SetPendingCount(ACount: Integer);
begin
  FPendingCount := ACount;
end;

procedure TAefosReviewAllPart.RecalcSize;
begin
  DoAutoSize; // re-measures via PreferedWidthAtCurrentPPI (N may have changed the caption width)
end;

procedure TAefosReviewAllPart._PillRects(ATopY: Integer;
  out AApprove, AReject: TRect; out AValid: Boolean);
var
  LBmp: TBitmap;
  LGlyphSz, LPillH, LY, LWa, LWr, LWaPill, LWrPill, LRejRight, LRejLeft, LAppRight: Integer;
begin
  AApprove := Rect(0, 0, 0, 0);
  AReject := Rect(0, 0, 0, 0);
  AValid := False;
  if SynEdit = nil then
    Exit;
  LGlyphSz := SynEdit.LineHeight - 4;
  if LGlyphSz < 8 then
    LGlyphSz := 8;
  LPillH := SynEdit.LineHeight - 2;
  if LPillH < 10 then
    LPillH := 10;
  LY := ATopY + (SynEdit.LineHeight - LPillH) div 2; // vertical-centre the pills on the line
  LBmp := TBitmap.Create;
  try
    LBmp.Canvas.Font.Assign(TCustomSynEdit(SynEdit).Font);
    LBmp.Canvas.Font.Style := [fsBold];
    LWa := LBmp.Canvas.TextWidth(_CaptionApprove);
    LWr := LBmp.Canvas.TextWidth(_CaptionReject);
  finally
    LBmp.Free;
  end;
  LWaPill := 3 + LGlyphSz + 3 + LWa + 5;
  LWrPill := 3 + LGlyphSz + 3 + LWr + 5;
  LRejRight := Left + Width - 4;    // reject pill hugs the right edge (RAD LineRect.Right - 4)
  LRejLeft := LRejRight - LWrPill;
  LAppRight := LRejLeft - 4;        // approve pill sits just left of reject
  if (LAppRight - LWaPill) < Left then
    Exit;                           // column too narrow: paint nothing (RAD LRAllA.Left guard)
  AReject := Rect(LRejLeft, LY, LRejRight, LY + LPillH);
  AApprove := Rect(LAppRight - LWaPill, LY, LAppRight, LY + LPillH);
  AValid := True;
end;

procedure TAefosReviewAllPart.Paint(Canvas: TCanvas; AClip: TRect;
  FirstLine, LastLine: Integer);
var
  LView, LCount, LLineHeight, LTopIdx, LTextIdx, LRcTop, LRcBottom, LLine: Integer;
  LApprove, LReject: TRect;
  LValid: Boolean;
begin
  if not Visible then
    Exit;
  // Blend the reserved column with the editor body (not the default grey gutter) so the pill
  // reads as floating over the code, mirroring the RAD in-body paint.
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := TCustomSynEdit(SynEdit).Color;
  Canvas.FillRect(AClip);
  if Length(FMarkerLines) = 0 then
    Exit;
  LLineHeight := SynEdit.LineHeight;
  if LLineHeight <= 0 then
    Exit;
  // Paint the caption in the EDITOR font so its width matches _PillRects' measurement.
  Canvas.Font.Assign(TCustomSynEdit(SynEdit).Font);
  LCount := SynEdit.Lines.Count;
  LTopIdx := ToIdx(GutterArea.TextArea.TopLine);
  LRcBottom := AClip.Top;
  for LView := LTopIdx + FirstLine to LTopIdx + LastLine do
  begin
    LTextIdx := ViewedTextBuffer.DisplayView.ViewToTextIndex(LView);
    if (LTextIdx < 0) or (LTextIdx >= LCount) then
      Break;
    LRcTop := LRcBottom;
    Inc(LRcBottom, LLineHeight);
    LLine := LTextIdx + 1;
    if not _IsMarkerLine(LLine) then
      Continue;
    _PillRects(LRcTop, LApprove, LReject, LValid);
    if not LValid then
      Continue;
    _DrawAllPill(Canvas, LApprove, CLR_APPROVE, 'v', _CaptionApprove);
    _DrawAllPill(Canvas, LReject, CLR_REJECT, 'x', _CaptionReject);
  end;
end;

procedure TAefosReviewAllPart.MouseDown(Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  LLineHeight, LTextTop, LScreenRow, LView, LTextIdx, LLineTopY: Integer;
  LApprove, LReject: TRect;
  LValid: Boolean;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if Button <> Controls.mbLeft then
    Exit;
  if Length(FMarkerLines) = 0 then
    Exit;
  LLineHeight := SynEdit.LineHeight;
  if LLineHeight <= 0 then
    Exit;
  LTextTop := GutterArea.TextArea.TextBounds.Top;
  if Y < LTextTop then
    Exit;
  LScreenRow := (Y - LTextTop) div LLineHeight;
  LView := ToIdx(GutterArea.TextArea.TopLine) + LScreenRow;
  LTextIdx := ViewedTextBuffer.DisplayView.ViewToTextIndex(LView);
  if (LTextIdx < 0) or (LTextIdx >= SynEdit.Lines.Count) then
    Exit;
  if not _IsMarkerLine(LTextIdx + 1) then
    Exit;
  LLineTopY := LTextTop + LScreenRow * LLineHeight;
  _PillRects(LLineTopY, LApprove, LReject, LValid);
  if not LValid then
    Exit;
  // DEFER: ApproveAll / RejectAll collapse THIS part's visuals; resolving inside our own
  // MouseDown risks the TSynGutter re-touch, so hand off to the next message cycle. AData
  // is unused (all-at-once), passed 0.
  _EnsureDeferred;
  if PtInRect(LApprove, Point(X, Y)) then
    Application.QueueAsyncCall(GDeferred.DoApproveAll, 0)
  else if PtInRect(LReject, Point(X, Y)) then
    Application.QueueAsyncCall(GDeferred.DoRejectAll, 0);
end;

{ ── helpers ─────────────────────────────────────────────────────────────── }

procedure _EnsureDeferred;
begin
  if GDeferred = nil then
    GDeferred := TReviewDeferred.Create;
end;

// The TSynEdit backing AEditor, or nil when the control is not a TSynEdit.
function _SynOf(const AEditor: TSourceEditorInterface): TCustomSynEdit;
begin
  Result := nil;
  if (AEditor <> nil) and (AEditor.EditorControl is TSynEdit) then
    Result := TSynEdit(AEditor.EditorControl);
end;

// The live source editor whose stored FileName is AFileName, or nil (closed).
function _EditorByName(const AFileName: string): TSourceEditorInterface;
begin
  Result := nil;
  if (SourceEditorManagerIntf = nil) or (AFileName = '') then
    Exit;
  Result := SourceEditorManagerIntf.SourceEditorIntfWithFilename(AFileName);
end;

// The buffer's own line ending (CRLF when present, else LF) for AWholeUtf8.
function _EolOf(const AWholeUtf8: string): string;
begin
  if Pos(#13#10, AWholeUtf8) > 0 then
    Result := #13#10
  else
    Result := #10;
end;

// Line count of AText (lines joined by AEol, no trailing EOL): occurrences of AEol + 1.
// 0 for an empty string. Manual scan (no string helper - not used elsewhere under FPC).
function _CountLines(const AText, AEol: string): Integer;
var
  LPos, LFound: Integer;
begin
  if AText = '' then
    Exit(0);
  Result := 1;
  LPos := 1;
  repeat
    LFound := PosEx(AEol, AText, LPos);
    if LFound = 0 then
      Break;
    Inc(Result);
    LPos := LFound + Length(AEol);
  until False;
end;

// 1-based changed ranges between AOld and ANew (UTF-8), via the same equal prefix /
// suffix skip as the RAD ChangedSpan. AOldTo < AOldFrom => nothing removed (a pure
// add); ANewTo < ANewFrom => nothing added (a pure deletion). Line counting is
// codepage-agnostic (we only need line NUMBERS here).
procedure _ChangedRanges(const AOldUtf8, ANewUtf8: string;
  out AOldFrom, AOldTo, ANewFrom, ANewTo: Integer);
var
  LOld, LNew: TStringList;
  LTop, LBotOld, LBotNew: Integer;
begin
  AOldFrom := 1; AOldTo := 0; ANewFrom := 1; ANewTo := 0;
  LOld := TStringList.Create;
  LNew := TStringList.Create;
  try
    LOld.Text := AOldUtf8;
    LNew.Text := ANewUtf8;
    LTop := 0; // skip equal leading lines
    while (LTop <= LOld.Count - 1) and (LTop <= LNew.Count - 1) and
          (LOld[LTop] = LNew[LTop]) do
      Inc(LTop);
    LBotOld := LOld.Count - 1; // skip equal trailing lines
    LBotNew := LNew.Count - 1;
    while (LBotOld >= LTop) and (LBotNew >= LTop) and
          (LOld[LBotOld] = LNew[LBotNew]) do
    begin
      Dec(LBotOld);
      Dec(LBotNew);
    end;
    AOldFrom := LTop + 1;    AOldTo := LBotOld + 1; // < From when nothing removed
    ANewFrom := LTop + 1;    ANewTo := LBotNew + 1; // < From when nothing added
  finally
    LOld.Free;
    LNew.Free;
  end;
end;

// The joined text (buffer EOL) of 1-based lines [AFrom..ATo] of AWholeUtf8, and their
// count. Uses the same TStringList.Text split as _ChangedRanges so line indices align.
procedure _ExtractLines(const AWholeUtf8: string; AFrom, ATo: Integer;
  const AEol: string; out AJoined: string; out ACount: Integer);
var
  LSL: TStringList;
  LIdx: Integer;
begin
  AJoined := '';
  ACount := 0;
  if ATo < AFrom then
    Exit;
  LSL := TStringList.Create;
  try
    LSL.Text := AWholeUtf8;
    for LIdx := AFrom to ATo do
      if (LIdx >= 1) and (LIdx <= LSL.Count) then
      begin
        if ACount > 0 then
          AJoined := AJoined + AEol;
        AJoined := AJoined + LSL[LIdx - 1];
        Inc(ACount);
      end;
  finally
    LSL.Free;
  end;
end;

// Length of the 1-based line ALineNo of AEditor, reading AEditor.Lines (0-based) with the
// index CLAMPED into [0..LineCount-1] so a stale / off-by-one line number can never raise
// EListError "List index out of bounds" from TSynEditStringList. 0 for an empty buffer.
function _LineLen(const AEditor: TSourceEditorInterface; ALineNo: Integer): Integer;
var
  LCount, LIdx: Integer;
begin
  Result := 0;
  if AEditor = nil then
    Exit;
  LCount := AEditor.LineCount;
  if LCount <= 0 then
    Exit;
  LIdx := ALineNo - 1; // 1-based line number -> 0-based Lines index
  if LIdx < 0 then
    LIdx := 0;
  if LIdx > LCount - 1 then
    LIdx := LCount - 1;
  Result := Length(AEditor.Lines[LIdx]);
end;

// Deletes whole lines [AFrom..ATo] (1-based, inclusive) via the source-editor API so the
// CodeBuffer stays in sync. Handles the last-line edge (no trailing line to absorb). Every
// Lines[] read goes through _LineLine (clamped) and every Point line is kept within
// [1..LineCount] so a stale range can never trip TSynEditStringList's index check.
procedure _DeleteLines(const AEditor: TSourceEditorInterface; AFrom, ATo: Integer);
var
  LCount, LEnd: Integer;
begin
  if (AEditor = nil) or AEditor.ReadOnly then
    Exit;
  LCount := AEditor.LineCount;
  if LCount <= 0 then
    Exit;
  if AFrom < 1 then
    AFrom := 1;
  if AFrom > LCount then
    Exit; // nothing to delete: the whole range is past the buffer end
  if ATo > LCount then
    ATo := LCount;
  if ATo < AFrom then
    Exit;
  if ATo >= LCount then
  begin
    // Deleting through the last line: swallow the preceding EOL so no blank line remains.
    if AFrom > 1 then
      AEditor.ReplaceText(Point(_LineLen(AEditor, AFrom - 1) + 1, AFrom - 1),
        Point(_LineLen(AEditor, ATo) + 1, ATo), '')
    else
      AEditor.ReplaceText(Point(1, 1),
        Point(_LineLen(AEditor, ATo) + 1, ATo), '');
  end
  else
  begin
    LEnd := ATo + 1;
    if LEnd > LCount then
      LEnd := LCount; // never point a block-end past the last line
    AEditor.ReplaceText(Point(1, AFrom), Point(1, LEnd), '');
  end;
end;

// Inserts AJoined (already EOL-joined lines) as whole lines directly BEFORE line
// ABeforeLine (1-based). Appends after the last line when ABeforeLine is past the end.
procedure _InsertLinesBefore(const AEditor: TSourceEditorInterface;
  ABeforeLine: Integer; const AJoined, AEol: string);
var
  LCount: Integer;
begin
  if (AEditor = nil) or AEditor.ReadOnly or (AJoined = '') then
    Exit;
  LCount := AEditor.LineCount;
  if ABeforeLine < 1 then
    ABeforeLine := 1;
  if ABeforeLine <= LCount then
    // Insert at column 1; the trailing EOL pushes the original line down.
    AEditor.ReplaceText(Point(1, ABeforeLine), Point(1, ABeforeLine), AJoined + AEol)
  else
    // Append: a leading EOL starts a fresh line after the current last line (_LineLen
    // clamps the index so a phantom last line can never raise EListError).
    AEditor.ReplaceText(Point(_LineLen(AEditor, LCount) + 1, LCount),
      Point(_LineLen(AEditor, LCount) + 1, LCount), AEol + AJoined);
end;

// Lines kept above a just-revealed change so its top isn't glued to the editor border.
const
  REVIEW_REVEAL_TOP_MARGIN = 2;

// Scrolls AEditor so the TOP of a just-applied change (ATopLine, the change's first
// affected line) shows with a small top margin, and parks the caret on ACaretLine (the
// first line of the kept GREEN text). Without this the whole-buffer facade write plus the
// struck-red block injected ABOVE the green leaves the view anchored on the NEW block, so
// the injected red block scrolls off the top and the developer only sees the green half of
// the diff. The RAD contract never hits this: its OTA insert (_InsertBlockAfter ->
// GotoLine) keeps the anchored old block in view; this mirrors that "removed block stays
// visible" behavior. Runs on the IDE main thread (NotifyApplied already does, like every
// other editor mutation here). Order matters: the caret is set FIRST (so a later
// EnsureCursorPosVisible has nothing to scroll), then TopLine is pinned explicitly
// (SetTopLine records sfExplicitTopLine, so the reveal survives the next repaint).
procedure _RevealChangeTop(const AEditor: TSourceEditorInterface;
  ATopLine, ACaretLine: Integer);
var
  LSyn: TCustomSynEdit;
  LCount, LTop, LCaret: Integer;
begin
  LSyn := _SynOf(AEditor);
  if LSyn = nil then
    Exit;
  LCount := AEditor.LineCount;
  if LCount <= 0 then
    Exit;
  LCaret := ACaretLine;
  if LCaret < 1 then
    LCaret := 1;
  if LCaret > LCount then
    LCaret := LCount;
  LTop := ATopLine - REVIEW_REVEAL_TOP_MARGIN;
  if LTop < 1 then
    LTop := 1;
  if LTop > LCount then
    LTop := LCount;
  LSyn.CaretXY := Point(1, LCaret);
  LSyn.TopLine := LTop;
end;

// The green / red markup registered on ASyn, creating + registering one on first use.
// Re-found by class (never a stored pointer). nil on a non-SynEdit.
function _EnsureMarkup(const ASyn: TCustomSynEdit): TAefosReviewMarkup;
var
  LFound: TSynEditMarkup;
begin
  Result := nil;
  if ASyn = nil then
    Exit;
  LFound := ASyn.MarkupByClass[TAefosReviewMarkup];
  if LFound = nil then
  begin
    Result := TAefosReviewMarkup.Create(ASyn);
    ASyn.MarkupManager.AddMarkUp(Result); // manager wires Lines / Caret / repaint; owns it
  end
  else
    Result := TAefosReviewMarkup(LFound);
end;

// The inline gutter part on ASyn, creating + registering one as the RIGHTMOST gutter
// part (beside the code) on first use. Re-found by class. nil on a non-SynEdit /
// gutterless editor.
function _EnsureGutterPart(const ASyn: TCustomSynEdit): TAefosReviewGutterPart;
var
  LFound: TSynGutterPartBase;
begin
  Result := nil;
  if (ASyn = nil) or (ASyn.Gutter = nil) then
    Exit;
  LFound := ASyn.Gutter.Parts.ByClass[TAefosReviewGutterPart, 0];
  if LFound = nil then
    Result := TAefosReviewGutterPart.Create(ASyn.Gutter.Parts)
  else
    Result := TAefosReviewGutterPart(LFound);
end;

// The inline All-pill part on ASyn's RIGHT gutter, creating + registering one on first use.
// The right gutter carries no stock parts, so ours is its only part. Made visible + blended
// with the editor colour so the reserved strip reads as the code body. Re-found by class.
function _EnsureAllPart(const ASyn: TCustomSynEdit): TAefosReviewAllPart;
var
  LFound: TSynGutterPartBase;
begin
  Result := nil;
  if (ASyn = nil) or (ASyn.RightGutter = nil) then
    Exit;
  ASyn.RightGutter.Visible := True;
  ASyn.RightGutter.Color := ASyn.Color; // blend the strip with the editor background
  LFound := ASyn.RightGutter.Parts.ByClass[TAefosReviewAllPart, 0];
  if LFound = nil then
    Result := TAefosReviewAllPart.Create(ASyn.RightGutter.Parts)
  else
    Result := TAefosReviewAllPart(LFound);
end;

// Removes + frees our markup from ASyn (if present). Guarded; re-found by class.
procedure _RemoveMarkup(const ASyn: TCustomSynEdit);
var
  LFound: TSynEditMarkup;
begin
  if ASyn = nil then
    Exit;
  try
    LFound := ASyn.MarkupByClass[TAefosReviewMarkup];
    if LFound <> nil then
    begin
      ASyn.MarkupManager.RemoveMarkUp(LFound); // detach (does not free)
      LFound.Free;
      ASyn.Invalidate;
    end;
  except
    // best-effort: markup cleanup must never raise
  end;
end;

// Removes + frees our inline gutter part from ASyn (if present). Guarded; re-found by class.
procedure _RemoveGutterPart(const ASyn: TCustomSynEdit);
var
  LFound: TSynGutterPartBase;
begin
  if (ASyn = nil) or (ASyn.Gutter = nil) then
    Exit;
  try
    LFound := ASyn.Gutter.Parts.ByClass[TAefosReviewGutterPart, 0];
    if LFound <> nil then
    begin
      LFound.Free; // destructor removes it from the parts list; the gutter re-autosizes
      ASyn.Invalidate;
    end;
  except
    // best-effort: gutter-part cleanup must never raise
  end;
end;

// Removes + frees our inline All-pill part from ASyn's right gutter (if present). Guarded;
// re-found by class. Freeing collapses the right gutter back to zero width.
procedure _RemoveAllPart(const ASyn: TCustomSynEdit);
var
  LFound: TSynGutterPartBase;
begin
  if (ASyn = nil) or (ASyn.RightGutter = nil) then
    Exit;
  try
    LFound := ASyn.RightGutter.Parts.ByClass[TAefosReviewAllPart, 0];
    if LFound <> nil then
    begin
      LFound.Free; // destructor removes it from the parts list; the right gutter re-autosizes to 0
      ASyn.Invalidate;
    end;
  except
    // best-effort: gutter-part cleanup must never raise
  end;
end;

// Collapses our review visuals on ASyn WITHOUT freeing them: the markup bands are cleared
// (RealEnabled then reports False, so it paints nothing) and the gutter part is emptied +
// hidden (Visible := False re-autosizes the gutter to drop its column). Used on the RESOLVE
// path (approve / reject / all) instead of _RemoveGutterPart.
//
// WHY NOT FREE ON RESOLVE (the "List index (5)" bug): TSynGutter caches FMouseDownPart - the
// index of the gutter part that got the last MouseDown - and its MouseMove / MouseUp read
// Parts[FMouseDownPart] UNGUARDED (syngutter.pp). Our part is appended after the 5 stock
// parts, so it sits at index 5. Resolving a change from a gutter click freed that part inside
// the deferred callback; the very next MouseMove then hit Parts[5] on a now-5-element list and
// raised EListError "List index (5) out of bounds" - which, firing on a later mouse message,
// escaped the deferred call's try/except straight to Application.HandleException. Keeping the
// part alive (index stays valid; its MouseMove/MouseUp early-exit on empty buttons) removes the
// dangling index entirely. The part is freed only at teardown / editor-strip, where no further
// gutter mouse event follows.
procedure _CollapseVisuals(const ASyn: TCustomSynEdit);
var
  LMarkup: TSynEditMarkup;
  LPart: TSynGutterPartBase;
begin
  if ASyn = nil then
    Exit;
  try
    LMarkup := ASyn.MarkupByClass[TAefosReviewMarkup];
    if LMarkup <> nil then
      TAefosReviewMarkup(LMarkup).ClearBands;
    if ASyn.Gutter <> nil then
    begin
      LPart := ASyn.Gutter.Parts.ByClass[TAefosReviewGutterPart, 0];
      if LPart <> nil then
      begin
        TAefosReviewGutterPart(LPart).ClearAll;
        LPart.Visible := False; // re-autosizes the gutter to drop the empty column
      end;
    end;
    // Same FMouseDownPart dangle protection for the RIGHT gutter: collapse, never free.
    if ASyn.RightGutter <> nil then
    begin
      LPart := ASyn.RightGutter.Parts.ByClass[TAefosReviewAllPart, 0];
      if LPart <> nil then
      begin
        TAefosReviewAllPart(LPart).ClearAll;
        LPart.Visible := False; // re-autosizes the right gutter back to zero width
      end;
    end;
    ASyn.Invalidate;
  except
    // best-effort: collapsing visuals must never raise into the IDE
  end;
end;

// Removes every TAefosReviewMark from AEditor (defensive; none are created here) AND our
// markup + gutter part. Collect-then-free so a mark's destructor never shifts the scan.
procedure _StripVisualsIn(const AEditor: TSourceEditorInterface);
var
  LSyn: TCustomSynEdit;
  LList: TList;
  LI: Integer;
begin
  LSyn := _SynOf(AEditor);
  if LSyn = nil then
    Exit;
  _RemoveMarkup(LSyn);
  _RemoveGutterPart(LSyn);
  _RemoveAllPart(LSyn);
  LList := TList.Create;
  try
    try
      for LI := 0 to LSyn.Marks.Count - 1 do
        if LSyn.Marks[LI] is TAefosReviewMark then
          LList.Add(LSyn.Marks[LI]);
      for LI := 0 to LList.Count - 1 do
        TAefosReviewMark(LList[LI]).Free; // destructor removes it from LSyn.Marks
    except
      // best-effort: never let cleanup raise
    end;
  finally
    LList.Free;
  end;
end;

// Unload law: strip our visuals (markup / gutter parts / All pill / marks) from EVERY OPEN
// editor - the LIVE editor list, NOT just those still in GChanges. Our gutter parts use
// collapse-not-free on resolve (to dodge the FMouseDownPart "List index" dangle), so a
// resolved-then-closed editor still holds a HIDDEN (collapsed) part. If teardown walked only
// GChanges, that orphan part would be freed/painted by the SynEdit AFTER this BPL unmaps ->
// the "unhandled EAccessViolation on IDE close". _StripVisualsIn removes only OUR classes
// (by class), so an editor we never touched is a safe no-op.
procedure _StripAllVisuals;
var
  LI: Integer;
begin
  if SourceEditorManagerIntf = nil then
    Exit;
  for LI := 0 to SourceEditorManagerIntf.UniqueSourceEditorCount - 1 do
    _StripVisualsIn(SourceEditorManagerIntf.UniqueSourceEditors[LI]);
end;

// One undoable whole-buffer replace (the RejectAll-restore twin of the facade's
// _WriteWholeBuffer). No-op on a read-only / absent editor.
procedure _WriteWhole(const AEditor: TSourceEditorInterface; const ANew: UnicodeString);
var
  LLast: Integer;
begin
  if (AEditor = nil) or AEditor.ReadOnly then
    Exit;
  LLast := AEditor.LineCount;
  if LLast < 1 then
    LLast := 1;
  AEditor.BeginUndoBlock;
  try
    AEditor.ReplaceLines(1, LLast, UTF16ToUTF8(ANew));
  finally
    AEditor.EndUndoBlock;
  end;
end;

{ ── model / line accounting ─────────────────────────────────────────────── }

function _FindChangeById(AId: Integer): TReviewChange;
var
  LI: Integer;
begin
  Result := nil;
  if GChanges = nil then
    Exit;
  for LI := 0 to GChanges.Count - 1 do
    if TReviewChange(GChanges[LI]).Id = AId then
      Exit(TReviewChange(GChanges[LI]));
end;

// Shifts BOTH blocks of every OTHER pending change in AEditorName whose top (OldFrom)
// is below APivotLine, by ADelta lines. Changes never overlap, so the top line decides.
procedure _AdjustBelow(const AEditorName: string; APivotLine, ADelta: Integer;
  AExclude: TReviewChange);
var
  LI: Integer;
  LChange: TReviewChange;
begin
  if (ADelta = 0) or (GChanges = nil) then
    Exit;
  for LI := 0 to GChanges.Count - 1 do
  begin
    LChange := TReviewChange(GChanges[LI]);
    if (LChange <> AExclude) and SameText(LChange.EditorName, AEditorName) and
       (LChange.OldFrom > APivotLine) then
    begin
      Inc(LChange.OldFrom, ADelta);
      Inc(LChange.OldTo, ADelta);
      Inc(LChange.NewFrom, ADelta);
      Inc(LChange.NewTo, ADelta);
    end;
  end;
end;

// True when AEditorName still has ANY pending change.
function _EditorHasChanges(const AEditorName: string): Boolean;
var
  LI: Integer;
begin
  Result := False;
  if GChanges = nil then
    Exit;
  for LI := 0 to GChanges.Count - 1 do
    if SameText(TReviewChange(GChanges[LI]).EditorName, AEditorName) then
      Exit(True);
end;

// Rebuilds the markup bands + gutter markers/buttons for AEditorName's editor from the
// current model, then repaints. Removes the visuals entirely when the editor has no
// pending change left (so the diff vanishes after the last resolve).
procedure _RefreshUnit(const AEditorName: string);
var
  LEditor: TSourceEditorInterface;
  LSyn: TCustomSynEdit;
  LMarkup: TAefosReviewMarkup;
  LPart: TAefosReviewGutterPart;
  LAllPart: TAefosReviewAllPart;
  LI, LLine: Integer;
  LChange: TReviewChange;
begin
  LEditor := _EditorByName(AEditorName);
  LSyn := _SynOf(LEditor);
  if LSyn = nil then
    Exit;
  if not _EditorHasChanges(AEditorName) then
  begin
    // Collapse (do NOT free) so TSynGutter.FMouseDownPart never dangles into a freed part -
    // see _CollapseVisuals for the "List index (5)" story. Freeing happens only at teardown.
    _CollapseVisuals(LSyn);
    Exit;
  end;
  LMarkup := _EnsureMarkup(LSyn);
  if LMarkup <> nil then
    LMarkup.ClearBands;
  LPart := _EnsureGutterPart(LSyn);
  if LPart <> nil then
  begin
    LPart.ClearAll;
    LPart.Visible := True; // a prior resolve may have hidden it; changes are pending again
  end;
  LAllPart := _EnsureAllPart(LSyn);
  if LAllPart <> nil then
  begin
    LAllPart.ClearAll;
    // N = TOTAL pending across all units (the pill resolves everything, like the RAD
    // ReviewPendingCount) - not just this unit's count.
    LAllPart.SetPendingCount(TAefosLazGutterReview.PendingCount);
    LAllPart.Visible := True;
  end;
  for LI := 0 to GChanges.Count - 1 do
  begin
    LChange := TReviewChange(GChanges[LI]);
    if not SameText(LChange.EditorName, AEditorName) then
      Continue;
    if LChange.OldLineCount > 0 then
    begin
      if LMarkup <> nil then
        LMarkup.AddBand(LChange.OldFrom, LChange.OldTo, True);
      if LPart <> nil then
        for LLine := LChange.OldFrom to LChange.OldTo do
          LPart.AddOldLine(LLine);
    end;
    if LChange.NewLineCount > 0 then
    begin
      if LMarkup <> nil then
        LMarkup.AddBand(LChange.NewFrom, LChange.NewTo, False);
      if LPart <> nil then
        for LLine := LChange.NewFrom to LChange.NewTo do
          LPart.AddNewLine(LLine);
    end;
    if LPart <> nil then
      LPart.AddButton(LChange.MarkerLine, LChange.Id, LChange.Note <> '');
    if LAllPart <> nil then
      LAllPart.AddMarkerLine(LChange.MarkerLine); // pill on EVERY marker line (RAD parity)
  end;
  if LAllPart <> nil then
    LAllPart.RecalcSize; // re-measure the right column now the caption (N) + markers are set
  LSyn.Invalidate;
end;

// Strips AEditorName's pending RED blocks from the live buffer (keeping the changes
// pending as green-only, with line re-accounting), then refreshes. Deletes bottom-up so
// a deletion never shifts an as-yet-unprocessed block above it. The save hook + Approve
// use this; the stored OldText still lets a later reject re-inject the original.
procedure _StripRedsForUnit(const AEditorName: string);
var
  LEditor: TSourceEditorInterface;
  LWithRed: array of TReviewChange;
  LI, LInner, LOldCnt: Integer;
  LChange: TReviewChange;
begin
  if GChanges = nil then
    Exit;
  LEditor := _EditorByName(AEditorName);
  if LEditor = nil then
    Exit;
  SetLength(LWithRed, 0);
  for LI := 0 to GChanges.Count - 1 do
  begin
    LChange := TReviewChange(GChanges[LI]);
    if SameText(LChange.EditorName, AEditorName) and (LChange.OldLineCount > 0) then
    begin
      SetLength(LWithRed, Length(LWithRed) + 1);
      LWithRed[High(LWithRed)] := LChange;
    end;
  end;
  if Length(LWithRed) = 0 then
    Exit;
  // descending by OldFrom (bottom-most block deleted first)
  for LI := 0 to High(LWithRed) do
    for LInner := LI + 1 to High(LWithRed) do
      if LWithRed[LInner].OldFrom > LWithRed[LI].OldFrom then
      begin
        LChange := LWithRed[LI];
        LWithRed[LI] := LWithRed[LInner];
        LWithRed[LInner] := LChange;
      end;
  for LI := 0 to High(LWithRed) do
  begin
    LChange := LWithRed[LI];
    LOldCnt := LChange.OldLineCount;
    _DeleteLines(LEditor, LChange.OldFrom, LChange.OldTo);
    // this change's own green moves up by LOldCnt; everyone below it shifts up too
    Dec(LChange.NewFrom, LOldCnt);
    Dec(LChange.NewTo, LOldCnt);
    _AdjustBelow(AEditorName, LChange.OldTo, -LOldCnt, LChange);
    LChange.OldTo := LChange.OldFrom - 1; // collapse the red (OldText kept for reject)
  end;
  _RefreshUnit(AEditorName);
end;

{ ── save hook ───────────────────────────────────────────────────────────── }

procedure _EnsureSaveHook;
begin
  if GSaveHookInstalled or (LazarusIDE = nil) then
    Exit;
  if GSaveHook = nil then
    GSaveHook := TReviewSaveHook.Create;
  LazarusIDE.AddHandlerOnSaveEditorFile(GSaveHook.OnSaveEditorFile, False);
  GSaveHookInstalled := True;
end;

procedure _RemoveSaveHook;
begin
  if not GSaveHookInstalled then
    Exit;
  GSaveHookInstalled := False;
  if (LazarusIDE <> nil) and (GSaveHook <> nil) then
    LazarusIDE.RemoveHandlerOnSaveEditorFile(GSaveHook.OnSaveEditorFile);
end;

function TReviewSaveHook.OnSaveEditorFile(Sender: TObject; aFile: TLazProjectFile;
  SaveStep: TSaveEditorFileStep; TargetFilename: string): TModalResult;
var
  LName: string;
begin
  Result := mrOk; // never abort a save
  try
    if SaveStep <> sefsBeforeWrite then
      Exit;
    if (GChanges = nil) or (GChanges.Count = 0) then
      Exit;
    LName := TargetFilename;
    if (LName = '') and (aFile <> nil) then
      LName := aFile.Filename;
    // Strip THIS unit's red so the disk write is clean.
    _StripRedsForUnit(LName);
    // AUTO-SAVE opt-in (Delphi parity, Aefos.OTA.IDE.GutterReview.pas:1714): when the user
    // enabled "Agent auto-save edits", a save also AUTO-APPROVES (drops) this unit's pending
    // changes - the diff showed, now it passes on save. With auto-save OFF the changes stay
    // pending green-only (unchanged behaviour) so the user still decides. The save hook is NOT
    // removed here (removing an IDE handler from within its own callback is the unload AV the
    // RAD side dodges via ForceQueue); it stays installed and early-exits when nothing pends.
    if TAefosLazGutterReview.AutoSaveEnabled then
      _DropChangesForUnit(LName);
  except
    // best-effort: a save-hook fault must never abort the save nor crash the IDE
  end;
end;

// Drops the save hook once no change remains anywhere.
procedure _CleanupIfEmpty;
begin
  if (GChanges = nil) or (GChanges.Count = 0) then
    _RemoveSaveHook;
end;

{ ── feedback ────────────────────────────────────────────────────────────── }

procedure _PushFeedback(const ADisposition: string; AChange: TReviewChange);
begin
  if (AChange = nil) or (AChange.Note = '') then
    Exit;
  if GReviewFeedback = nil then
    GReviewFeedback := TStringList.Create;
  GReviewFeedback.Add('[' + ADisposition + '] ' + AChange.EditorName + ':' +
    IntToStr(AChange.NewFrom) + ' - ' + AChange.Note);
end;

// Auto-approves (drops) every pending change for AEditorName: pushes its feedback and
// removes it from the model, then refreshes the unit so the now-empty visuals collapse.
// The caller has ALREADY stripped the unit's red blocks (_StripRedsForUnit), so the green
// (accepted) text stays in the buffer. Mirrors the RAD _ResolveUnitForSave accept branch
// (Aefos.OTA.IDE.GutterReview.pas:1714). Main-thread only (GChanges is mutated here).
procedure _DropChangesForUnit(const AEditorName: string);
var
  LIdx: Integer;
  LChange: TReviewChange;
begin
  if GChanges = nil then
    Exit;
  for LIdx := GChanges.Count - 1 downto 0 do
  begin
    LChange := TReviewChange(GChanges[LIdx]);
    if SameText(LChange.EditorName, AEditorName) then
    begin
      _PushFeedback('approved', LChange);
      GChanges.Delete(LIdx);
    end;
  end;
  _RefreshUnit(AEditorName);
end;

{ ── TAefosLazGutterReview ───────────────────────────────────────────────── }

class function TAefosLazGutterReview.ReviewActive: Boolean;
var
  LConfig: IConfig;
  LSnap: TConfig;
  LResolver: TConfigRootResolver;
begin
  Result := False;
  try
    if GRootObj = nil then
      GRootObj := TReviewConfigRoot.Create;
    LResolver := GRootObj.Resolve; // method pointer (of object), not a call
    LConfig := TConfigService.Create(LResolver);
    LConfig.Load;
    LSnap := LConfig.Snapshot;
    // Delphi contract: 2 = Apply silently (no review); 0/1 = show the review.
    Result := LSnap.AgentEditReviewMode <> 2;
  except
    Result := False; // a config read must never sprout a diff nor break an edit
  end;
end;

class function TAefosLazGutterReview.AutoSaveEnabled: Boolean;
var
  LConfig: IConfig;
  LSnap: TConfig;
  LResolver: TConfigRootResolver;
begin
  Result := False;
  try
    if GRootObj = nil then
      GRootObj := TReviewConfigRoot.Create;
    LResolver := GRootObj.Resolve; // method pointer (of object), not a call
    LConfig := TConfigService.Create(LResolver);
    LConfig.Load;
    LSnap := LConfig.Snapshot;
    // Delphi contract: "Agent auto-save edits" (TConfig.AgentAutoSave, default FALSE).
    Result := LSnap.AgentAutoSave;
  except
    Result := False; // opt-in: a config read must never auto-accept behind the user's back
  end;
end;

class procedure TAefosLazGutterReview.AutoAcceptUnitOnNewEdit(
  const AEditor: TSourceEditorInterface);
var
  LName: string;
begin
  try
    if AEditor = nil then
      Exit;
    if not AutoSaveEnabled then
      Exit; // opt-out: keep accruing pending changes exactly as before
    LName := AEditor.FileName;
    if not _EditorHasChanges(LName) then
      Exit; // nothing pending on this unit - the imminent edit lights a fresh diff on its own
    // Auto-save is ON and this unit has prior pending changes: strip their red (clean the
    // buffer) and drop them (auto-approved) so the imminent edit does not stack on an
    // unresolved diff. The green (accepted) prior text stays; the new edit then computes its
    // diff against the clean buffer. Mirrors the RAD facade's auto-accept-then-proceed.
    _StripRedsForUnit(LName);
    _DropChangesForUnit(LName);
  except
    // best-effort: an auto-accept hiccup must never break the agent's applied edit
  end;
end;

class procedure TAefosLazGutterReview.NotifyApplied(
  const AEditor: TSourceEditorInterface;
  const AUnitPath, AOldWhole, ANewWhole: UnicodeString);
var
  LSyn: TCustomSynEdit;
  LOldU8, LNewU8, LEol, LOldText: string;
  LOldFrom, LOldTo, LNewFrom, LNewTo, LOldCnt, LNewCnt: Integer;
  LChange: TReviewChange;
begin
  try
    if not ReviewActive then
      Exit;
    if AOldWhole = ANewWhole then
      Exit; // nothing changed
    LSyn := _SynOf(AEditor);
    if LSyn = nil then
      Exit;
    if GChanges = nil then
      GChanges := TObjectList.Create(True);
    LOldU8 := UTF16ToUTF8(AOldWhole);
    LNewU8 := UTF16ToUTF8(ANewWhole);
    _ChangedRanges(LOldU8, LNewU8, LOldFrom, LOldTo, LNewFrom, LNewTo);
    LEol := _EolOf(LNewU8);
    _ExtractLines(LOldU8, LOldFrom, LOldTo, LEol, LOldText, LOldCnt);
    // Inject the OLD lines as a struck-red block directly above the NEW green block. The
    // buffer already holds ANewWhole, so we insert before the new block's first line.
    if LOldCnt > 0 then
      _InsertLinesBefore(AEditor, LNewFrom, LOldText, LEol);
    LChange := TReviewChange.Create;
    Inc(GNextId);
    LChange.Id := GNextId;
    LChange.EditorName := AEditor.FileName;
    LChange.PreEditWhole := AOldWhole;
    LChange.OldText := LOldText;
    LNewCnt := LNewTo - LNewFrom + 1;
    if LNewCnt < 0 then
      LNewCnt := 0;
    // Line-accounting for the OTHER pending changes on this unit. The facade rewrote the
    // WHOLE buffer (its replace shifted lines below by newCount-oldCount) and we then inject
    // oldCount red lines above the green block (a further +oldCount) - the two sum to exactly
    // newCount. So every prior change below the edited region (its top OldFrom is past the old
    // block's last line LOldTo, in the pre-edit coordinate space they still hold) shifts by the
    // NEW green line count. Above / unaffected changes are left untouched. Done before this
    // change is added, so exclude is nil.
    _AdjustBelow(LChange.EditorName, LOldTo, LNewCnt, nil);
    if LOldCnt > 0 then
    begin
      // Struck-red OLD block sits directly above the GREEN block (both now shifted down by the
      // injected LOldCnt in the live buffer).
      LChange.OldFrom := LNewFrom;
      LChange.OldTo := LNewFrom + LOldCnt - 1;
      LChange.NewFrom := LNewFrom + LOldCnt;
      LChange.NewTo := LNewTo + LOldCnt;
    end
    else
    begin
      // Pure addition: no red, the green block stays where the facade wrote it.
      LChange.OldFrom := LNewFrom;
      LChange.OldTo := LNewFrom - 1;
      LChange.NewFrom := LNewFrom;
      LChange.NewTo := LNewTo;
    end;
    GChanges.Add(LChange);
    _EnsureSaveHook;
    _RefreshUnit(LChange.EditorName);
    // Reveal the TOP of the change. The facade rewrote the WHOLE buffer and we injected the
    // struck-red OLD block ABOVE the green, which leaves the view anchored on the NEW block -
    // scrolling the red block off the top so only the green (+) half shows. Bring OldFrom (the
    // first affected line, = the top of the red block when there is a removal, else the top of
    // the pure add) into view with a small margin and park the caret on the green, so the dev
    // sees the removed (-) and added (+) blocks together - the RAD contract's behavior.
    _RevealChangeTop(AEditor, LChange.OldFrom, LChange.NewFrom);
  except
    // best-effort: a review failure must never break the agent's applied edit
  end;
end;

class function TAefosLazGutterReview.Pending: Boolean;
begin
  Result := (GChanges <> nil) and (GChanges.Count > 0);
end;

class function TAefosLazGutterReview.PendingCount: Integer;
begin
  if GChanges <> nil then
    Result := GChanges.Count
  else
    Result := 0;
end;

class procedure TAefosLazGutterReview.ApproveChange(AId: Integer);
var
  LChange: TReviewChange;
  LEditor: TSourceEditorInterface;
  LName: string;
  LOldCnt: Integer;
begin
  LChange := _FindChangeById(AId);
  if LChange = nil then
    Exit;
  LName := LChange.EditorName;
  LEditor := _EditorByName(LName);
  _PushFeedback('approved', LChange);
  // Drop the OLD (red) block if present; the NEW (green) text stays = the edit kept.
  if (LEditor <> nil) and (LChange.OldLineCount > 0) then
  begin
    LOldCnt := LChange.OldLineCount;
    _DeleteLines(LEditor, LChange.OldFrom, LChange.OldTo);
    _AdjustBelow(LName, LChange.OldTo, -LOldCnt, LChange);
  end;
  GChanges.Remove(LChange); // OwnsObjects frees it
  _RefreshUnit(LName);
  _CleanupIfEmpty;
end;

class procedure TAefosLazGutterReview.RejectChange(AId: Integer);
var
  LChange: TReviewChange;
  LEditor: TSourceEditorInterface;
  LName, LEol: string;
  LNewCnt, LOldCnt: Integer;
begin
  LChange := _FindChangeById(AId);
  if LChange = nil then
    Exit;
  LName := LChange.EditorName;
  LEditor := _EditorByName(LName);
  _PushFeedback('rejected', LChange);
  if LEditor <> nil then
  begin
    LNewCnt := LChange.NewLineCount;
    if LChange.OldLineCount > 0 then
    begin
      // Red still in the buffer above the green: delete the green; the red becomes the
      // restored original once the change leaves the list.
      if LNewCnt > 0 then
      begin
        _DeleteLines(LEditor, LChange.NewFrom, LChange.NewTo);
        _AdjustBelow(LName, LChange.NewTo, -LNewCnt, LChange);
      end;
    end
    else if LChange.OldText <> '' then
    begin
      // Green-only (the red was stripped on a save): re-inject the stored original in
      // place of the green block. LOldCnt = the OldText's line count.
      LEol := _EolOf(LChange.OldText);
      LOldCnt := _CountLines(LChange.OldText, LEol);
      if LNewCnt > 0 then
        _DeleteLines(LEditor, LChange.NewFrom, LChange.NewTo);
      _InsertLinesBefore(LEditor, LChange.NewFrom, LChange.OldText, LEol);
      _AdjustBelow(LName, LChange.NewTo, LOldCnt - LNewCnt, LChange);
    end
    else
    begin
      // Pure addition with nothing before it: delete the added green lines.
      if LNewCnt > 0 then
      begin
        _DeleteLines(LEditor, LChange.NewFrom, LChange.NewTo);
        _AdjustBelow(LName, LChange.NewTo, -LNewCnt, LChange);
      end;
    end;
  end;
  GChanges.Remove(LChange);
  _RefreshUnit(LName);
  _CleanupIfEmpty;
end;

class procedure TAefosLazGutterReview.AnnotateChange(AId: Integer);
var
  LChange: TReviewChange;
  LNote: string;
begin
  LChange := _FindChangeById(AId);
  if LChange = nil then
    Exit;
  LNote := LChange.Note;
  if InputQuery('Aefos - note for the agent',
    'Note about this change (sent to the agent on approve/reject):', LNote) then
  begin
    LChange.Note := Trim(LNote);
    _RefreshUnit(LChange.EditorName); // brighten the pencil to reflect the note
  end;
end;

class procedure TAefosLazGutterReview.ApproveAll;
var
  LNames: TStringList;
  LI: Integer;
  LChange: TReviewChange;
  LName: string;
begin
  if not Pending then
    Exit;
  LNames := TStringList.Create;
  try
    LNames.Sorted := True;
    LNames.Duplicates := dupIgnore;
    for LI := 0 to GChanges.Count - 1 do
      LNames.Add(TReviewChange(GChanges[LI]).EditorName);
    // Strip every unit's red (keeps the green = accepted text).
    for LName in LNames do
      _StripRedsForUnit(LName);
    // Deliver notes and drop every change.
    for LI := GChanges.Count - 1 downto 0 do
    begin
      LChange := TReviewChange(GChanges[LI]);
      _PushFeedback('approved', LChange);
      GChanges.Delete(LI);
    end;
    for LName in LNames do
      _RefreshUnit(LName);
  finally
    LNames.Free;
  end;
  _CleanupIfEmpty;
end;

class procedure TAefosLazGutterReview.RejectAll;
var
  LI: Integer;
  LChange: TReviewChange;
  LDone: TStringList;
begin
  if not Pending then
    Exit;
  // Restore the EARLIEST pre-edit snapshot per unit (GChanges is in accrual order, so the
  // first entry for a unit IS its earliest, captured before any red injection) - reverts
  // every accrued edit in that unit in one correct write, wiping red + green together.
  LDone := TStringList.Create;
  try
    LDone.Sorted := True;
    LDone.Duplicates := dupIgnore;
    for LI := 0 to GChanges.Count - 1 do
    begin
      LChange := TReviewChange(GChanges[LI]);
      _PushFeedback('rejected', LChange);
      if LDone.IndexOf(LChange.EditorName) >= 0 then
        Continue;
      LDone.Add(LChange.EditorName);
      _WriteWhole(_EditorByName(LChange.EditorName), LChange.PreEditWhole);
    end;
    // Drop the changes FIRST so _RefreshUnit sees an empty unit and collapses (not frees) the
    // visuals - keeping the gutter part alive avoids the FMouseDownPart dangle if RejectAll was
    // reached with a stale gutter mouse-down on one of these parts (see _CollapseVisuals).
    GChanges.Clear;
    for LI := 0 to LDone.Count - 1 do
      _RefreshUnit(LDone[LI]);
  finally
    LDone.Free;
  end;
  _CleanupIfEmpty;
end;

class function TAefosLazGutterReview.DrainReviewFeedback: string;
begin
  if (GReviewFeedback = nil) or (GReviewFeedback.Count = 0) then
    Exit('');
  Result := GReviewFeedback.Text;
  GReviewFeedback.Clear;
end;

// One line per still-pending change. Read-only (does NOT clear). Call on the main
// thread - GChanges is mutated there by paint/approve/reject. Mirrors the RAD
// plugin's TGutterReview.DescribePendingReviews byte-for-byte (unit uses EditorName,
// the Lazarus twin of the RAD UnitPath). GChanges is a plain TObjectList, so the
// scan indexes and casts (no generic enumerator), exactly as the rest of this unit.
class function TAefosLazGutterReview.DescribePendingReviews: string;
var
  LChange: TReviewChange;
  LList: TStringList;
  LI: Integer;
begin
  Result := '';
  if (GChanges = nil) or (GChanges.Count = 0) then
    Exit;
  LList := TStringList.Create;
  try
    for LI := 0 to GChanges.Count - 1 do
    begin
      LChange := TReviewChange(GChanges[LI]);
      if LChange.NewTo >= LChange.NewFrom then
        LList.Add(Format('%s:%d-%d  pending (applied to buffer, awaiting approve/reject)',
          [LChange.EditorName, LChange.NewFrom, LChange.NewTo]))
      else
        LList.Add(Format('%s:%d  pending deletion (awaiting approve/reject)',
          [LChange.EditorName, LChange.MarkerLine]));
    end;
    Result := LList.Text;
  finally
    LList.Free;
  end;
end;

class procedure TAefosLazGutterReview.Shutdown;
begin
  // Unload law: ALWAYS strip, while the editors still exist. Our gutter parts survive an empty
  // GChanges (collapse-not-free), so gating this on GChanges.Count > 0 left collapsed ORPHAN
  // parts behind after "approve/reject All" - the SynEdit then freed them on IDE close, after
  // this BPL had unmapped, raising the EAccessViolation the maintainer hit on close.
  _StripAllVisuals;
  if GChanges <> nil then
    GChanges.Clear;
  _RemoveSaveHook;
end;

initialization

finalization
  // Unload law: cancel any queued resolve FIRST so the async loop never calls a freed
  // carrier after this BPL unmaps; then remove the save hook (the only IDE-held ref),
  // strip our visuals, and free what we own.
  if (GDeferred <> nil) and (Application <> nil) then
    Application.RemoveAsyncCalls(GDeferred);
  TAefosLazGutterReview.Shutdown;
  FreeAndNil(GChanges);
  FreeAndNil(GRootObj);
  FreeAndNil(GDeferred);
  FreeAndNil(GSaveHook);
  FreeAndNil(GReviewFeedback);

end.
