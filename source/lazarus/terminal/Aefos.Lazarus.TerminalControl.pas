unit Aefos.Lazarus.TerminalControl;

{$IFDEF FPC}{$mode delphi}{$H+}{$ENDIF}

(*
  LCL terminal control (Aefos -> Lazarus, terminal UI slice).

  A TCustomControl that hosts a live terminal: it owns a TVTermBuffer (the screen
  model) + a TAefosTerminalController (the ConPTY child + reader thread), paints the
  grid through TTerminalPainter, and wires keyboard input and resize back to the
  pseudo-console. It is the LCL twin of the Delphi
  source\terminal\UI\Aefos.OTA.Terminal.UI.TerminalCanvas.pas, trimmed to the
  usable core: paint + keyboard + resize + text selection + scrollback (wheel and
  a docked vertical scrollbar). Mouse reporting, find bar, hyperlinks and Sixel
  are DEFERRED to later slices.

  INPUT SPLIT (mirrors a real terminal):
    * KeyDown handles the control / navigation keys (Enter, Backspace, Tab, Esc,
      Ctrl+letter, arrows, Home/End/PgUp/PgDn/Ins/Del, F1-F12) -> encodes the VT
      byte sequence and writes it to the PTY, swallowing the key.
    * UTF8KeyPress handles printable text -> writes the UTF-8 bytes to the PTY.
  All input goes to the controller as RAW BYTES (WriteBytes) so no AnsiString
  codepage round-trip can corrupt it.

  The reader thread feeds the buffer on the MAIN thread via TThread.Synchronize; the
  buffer fires OnChange from there, so _OnBufferChange just Invalidate's - the IDE's
  own message loop services the marshaled feeds (unlike the console probe, no manual
  CheckSynchronize is needed).
*)

interface

uses
  Classes, SysUtils, Types, Math, Controls, Graphics, ExtCtrls, StdCtrls, Buttons,
  Forms, Dialogs, LCLType, Clipbrd, LazUTF8, Generics.Collections,
  Aefos.OTA.Terminal.Core.CellColor,
  Aefos.OTA.Terminal.Core.VTermBuffer,
  Aefos.OTA.Terminal.Core.ActionRunner,
  Aefos.OTA.Terminal.Core.SlashCommands,
  Aefos.Lazarus.TerminalController,
  Aefos.Lazarus.TerminalPainter,
  Aefos.Lazarus.TerminalComposerPane,
  Aefos.Lazarus.TerminalComposerPicker,
  Aefos.Lazarus.TerminalMemoryDialog;

type
  /// <summary>Per-cell text of one grid line, one entry per column (each entry is
  /// a single UTF-8 codepoint or a space). Used by the find scan so the reported
  /// match column is inherently a GRID column, never a byte offset.</summary>
  TAefosLineCells = array of string;

  /// <summary>
  /// A live terminal surface: owns the screen model + the ConPTY-backed
  /// controller, paints the grid and forwards keystrokes / resizes to the shell.
  /// Also satisfies ITerminalInput so the Action Center can inject saved-action
  /// script lines into this terminal (the LCL twin of the Delphi TTerminalHost's
  /// ITerminalInput role). A TControl's IInterface is non-refcounted, so handing
  /// this control out as an ITerminalInput never affects its lifetime.
  /// </summary>
  TAefosLazTerminalControl = class(TCustomControl, ITerminalInput)
  private
    FBuffer: TVTermBuffer;
    FController: TAefosTerminalController;
    FCellWidth: Integer;
    FCellHeight: Integer;
    FBasePalette: TBasePalette;
    FDefaultFg: TColor;
    FDefaultBg: TColor;
    FCursorColor: TColor;
    FCursorOn: Boolean;
    FBlink: TTimer;
    FStarted: Boolean;
    // --- Top toolbar -------------------------------------------------------
    // A slim dark-chrome bar pinned to the TOP edge, carrying flat TSpeedButtons that
    // SURFACE the terminal features that already exist but were keyboard-only: the AI
    // composer (Ctrl+I), find (Ctrl+F) and the Action Center. It is alNone and stops
    // at the scrollbar's left edge (_LayoutChrome), leaving the scrollbar a clean
    // full-height right column. Its fixed height still steals vertical space, so
    // _ToolbarHeight both offsets the paint (TTerminalSnapshot.TopOffset) and shrinks
    // _VisibleRows -- the mirror of how _ComposerBarHeight handles the bottom bar --
    // so the shell resizes to the rows painted BELOW the toolbar and the prompt is
    // never hidden behind it.
    FToolbar: TPanel;
    FToolAiBtn: TSpeedButton;
    FToolFindBtn: TSpeedButton;
    FToolActionsBtn: TSpeedButton;
    // Vertical scrollbar docked to the right edge; scrollback viewport offset.
    // FScrollOffset = lines scrolled UP from the live bottom (0 = live/bottom,
    // max = Buffer.ScrollbackCount). Mirrors the Delphi TTerminalCanvas.
    FScrollBar: TScrollBar;
    FScrollOffset: Integer;
    // Mouse text selection in ABSOLUTE line coordinates: FSelAnchor/FSelEnd hold
    // X=col 0..Cols, Y=absolute line (scrollback-based, via _PixelToCell =
    // _TopLine + row). Mirrors the Delphi TTerminalCanvas selection fields, so a
    // selection stays pinned to its text while the viewport scrolls.
    FSelecting: Boolean;
    FHasSelection: Boolean;
    FSelAnchor: TPoint;
    FSelEnd: TPoint;
    // Find state (Ctrl+F search bar). FFindLine/FFindCol are the current match in
    // ABSOLUTE line / GRID column coordinates; FFindLen is the match width in grid
    // columns (0 = no highlight). Mirrors the Delphi TTerminalCanvas find fields.
    FFindLine: Integer;
    FFindCol: Integer;
    FFindLen: Integer;
    // The find-bar overlay: a code-created child panel anchored top-right of the
    // grid, hidden by default (mirrors the Delphi TFindBar behaviour, minus the
    // VCL chrome/focus-ring the task explicitly waives).
    FFindBar: TPanel;
    FFindEdit: TEdit;
    FFindPrevBtn: TSpeedButton;
    FFindNextBtn: TSpeedButton;
    FFindCaseChk: TSpeedButton;
    FFindCountLbl: TLabel;
    // --- AI composer bar (Ctrl+I) -----------------------------------------
    // A WebView2-backed footer bar docked to the bottom edge, PIXEL-IDENTICAL to
    // the Delphi terminal composer (it navigates the shared BuildComposerHtml): a
    // rounded dark textarea with paperclip / brain icons and an orange send. The
    // user types a request and it is INJECTED into the active pane's PTY -- so the
    // AI CLI (or shell) already running in the terminal receives it, exactly the
    // Delphi SendCommandToActivePane mechanic. Hidden until Ctrl+I. The bar is pinned
    // to the bottom (alNone, kept at the bottom by _LayoutChrome) and stops at the
    // scrollbar's left edge; when visible it steals vertical space -- _ComposerBarHeight
    // shrinks the grid so the shell resizes to the rows actually painted above it.
    FComposerBar: TPanel;
    FComposerPane: TAefosLazTerminalComposerPane;
    // Floating '/' command picker, overlaying the grid above the bar (a sibling
    // child of this control). The composer's JS owns the keyboard and posts the
    // nav intents; the picker just renders the filtered list + highlight.
    FPicker: TAefosLazTerminalComposerPicker;
    // The current '/' query mirrored from the webview, so a commit with no picker
    // match still injects the typed text verbatim (Delphi FComposerFilter twin).
    FComposerFilter: string;
    // Composer attachments (paperclip chips): id -> full file path. FAttachSeq
    // hands out the monotonic chip ids (Delphi twin).
    FAttachments: TDictionary<string, string>;
    FAttachSeq: Integer;
    procedure _InitTheme;
    procedure _ComputeMetrics;
    procedure _ApplyGeometry;
    /// <summary>Keeps the top toolbar and the bottom composer bar spanning only the
    /// grid column: their right edge stops at the scrollbar's LEFT edge
    /// (ClientWidth - FScrollBar.Width), so the alRight scrollbar owns a clean
    /// full-height column on the right instead of being sandwiched between a
    /// full-width alTop toolbar and a full-width alBottom bar. The composer is also
    /// re-pinned to the bottom here (it is alNone, so its Top must be maintained).</summary>
    procedure _LayoutChrome;
    function _DrawAreaWidth: Integer;
    function _VisibleCols: Integer;
    function _VisibleRows: Integer;
    /// <summary>Top absolute line of the viewport (ScrollbackCount - ScrollOffset,
    /// clamped >= 0). Delphi canvas _TopLine twin.</summary>
    function _TopLine: Integer;
    /// <summary>Total addressable lines (ScrollbackCount + Rows). Delphi
    /// canvas _TotalLines twin.</summary>
    function _TotalLines: Integer;
    /// <summary>Cell at absolute line / column: from scrollback below
    /// ScrollbackCount, else the live grid. Delphi canvas _CellOfLine twin.</summary>
    function _CellOfLine(const AAbsLine, AX: Integer): TTerminalCell;
    /// <summary>Sets the scrollbar Min/Max/PageSize/Position from ScrollbackCount,
    /// visible Rows and ScrollOffset; disables it when there is no history.
    /// Delphi canvas _SyncScrollBar twin.</summary>
    procedure _SyncScrollBar;
    procedure _ScrollBarChange(Sender: TObject);
    procedure _OnBufferChange(Sender: TObject);
    procedure _BlinkTick(Sender: TObject);
    procedure _EmitBytes(const AData: TBytes);
    procedure _EmitAscii(const AData: string);
    function _EncodeSpecialKey(const AKey: Word): string;
    /// <summary>Maps a client pixel to a grid cell. X is clamped 0..Cols (Cols is
    /// a valid past-the-end boundary for the half-open selection range, matching
    /// the Delphi canvas); Y is clamped to a visible buffer row 0..Rows-1.</summary>
    function _PixelToCell(const AX, AY: Integer): TPoint;
    /// <summary>True when cell (ACol, ALine) is inside the current selection, by
    /// the same ordered Y*100000+X half-open test the painter uses.</summary>
    function _IsSelected(const ACol, ALine: Integer): Boolean;
    /// <summary>Copies the selected visible-grid text to the clipboard (Delphi
    /// CopySelection twin).</summary>
    procedure CopySelection;
    /// <summary>UTF-8 text of one grid cell. A blank / control codepoint becomes a
    /// space so trailing blanks trim away (TrimRight in CopySelection).</summary>
    function _CellText(const ACell: TTerminalCell): string;
    /// <summary>Pastes the clipboard text to the shell, bracketed when the program
    /// enabled DEC ?2004 (Delphi SendCtrlV + TTerminalHost.PreparePastePayload twin).</summary>
    procedure PasteFromClipboard;
    function _PreparePastePayload(const AText: string;
      const ABracketed: Boolean): string;
    // --- Find bar (Ctrl+F) -------------------------------------------------
    /// <summary>Splits a UTF-8 needle into per-codepoint strings (lowercased when
    /// not case sensitive), so the search matches cell-by-cell and the reported
    /// column is a real grid column.</summary>
    function _SplitCells(const AText: string;
      const ACaseSensitive: Boolean): TAefosLineCells;
    /// <summary>Per-cell text of an absolute line (lowercased when not case
    /// sensitive), one entry per grid column. Delphi _LineText twin, but cell-wise
    /// so the column stays a grid column under UTF-8.</summary>
    function _LineCells(const AAbsLine: Integer;
      const ACaseSensitive: Boolean): TAefosLineCells;
    /// <summary>First grid column >= AStartCol where ANeedle matches ALine
    /// (both already case-folded), or -1. FFindCol/FFindLen come from this.</summary>
    function _MatchAt(const ALine, ANeedle: TAefosLineCells;
      const AStartCol: Integer): Integer;
    /// <summary>Searches _TotalLines starting after FFindLine, wrapping; on a hit
    /// sets FFindLine/FFindCol/FFindLen, scrolls the viewport to the match and
    /// repaints. Delphi TTerminalCanvas.FindText twin (cell-based).</summary>
    function FindText(const ASearch: string;
      const AForward, ACaseSensitive: Boolean): Boolean;
    /// <summary>Total matches across _TotalLines (Delphi CountFindMatches twin).</summary>
    function CountFindMatches(const ASearch: string;
      const ACaseSensitive: Boolean): Integer;
    /// <summary>1-based index of the current FFindLine/FFindCol match among all
    /// matches (Delphi FindCurrentMatchIndex twin), for the "N of M" counter.</summary>
    function FindCurrentMatchIndex(const ASearch: string;
      const ACaseSensitive: Boolean): Integer;
    procedure _CreateFindBar;
    procedure _AnchorFindBar;
    procedure _ToggleFindBar;
    /// <summary>Runs a find in AForward direction from the current position,
    /// tints the edit (red on miss) and refreshes the "N of M" counter.</summary>
    procedure _DoFind(const AForward: Boolean);
    procedure _UpdateFindCounter;
    procedure _FindEditChange(Sender: TObject);
    procedure _FindNextClick(Sender: TObject);
    procedure _FindPrevClick(Sender: TObject);
    procedure _FindCaseChange(Sender: TObject);
    procedure _FindEditKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    // --- AI composer bar (Ctrl+I) -----------------------------------------
    procedure _CreateComposerBar;
    /// <summary>Vertical space the composer bar consumes when visible (0 when
    /// hidden), so _VisibleRows / the paint region exclude it and the shell
    /// resizes to the grid actually above the bar.</summary>
    function _ComposerBarHeight: Integer;
    procedure _ToggleComposerBar;
    /// <summary>Hides the bar + picker and returns keyboard focus to the grid so
    /// typing goes back to the shell.</summary>
    procedure _CloseComposerBar;
    /// <summary>Writes ACommand + a submit CR to the active pane's PTY, so the CLI
    /// / shell running in the terminal receives and runs it (the Delphi
    /// SendCommandToActivePane mechanic). No-op when no shell is live.</summary>
    procedure SendCommandToActivePane(const ACommand: string);
    /// <summary>Injects AText into the pane and clears the composer input (the
    /// picker path, which did not go through the JS send that self-clears).</summary>
    procedure _InjectComposerText(const AText: string);
    /// <summary>'send:' from the webview: a plain line goes to the pane verbatim (+
    /// any attachment paths appended); a '/name' expands to the command body.</summary>
    procedure _ComposerPaneSend(Sender: TObject; const AText: string);
    /// <summary>'height:' from the webview: grow/shrink the bar for multi-line text
    /// (clamped) and re-flow the grid + picker to the new bar height.</summary>
    procedure _ComposerRequestHeight(Sender: TObject; const AHeight: Integer);
    /// <summary>The '/' picker keyboard intents relayed from the webview textarea:
    /// filter re-lists + shows the picker, nav moves the highlight, commit injects
    /// the selection (or the verbatim query), cancel hides it.</summary>
    procedure _ComposerPicker(Sender: TObject;
      AAction: TAefosComposerPickerAction; const AQuery: string);
    procedure _PickerPicked(Sender: TObject; const ACommand: TSlashCommand);
    /// <summary>Paperclip: LCL file picker -> add a chip. Chip X -> drop it. Brain:
    /// open the shared-memory editor. _PushComposerAttachments syncs chips to JS.</summary>
    procedure _ComposerAttachOpen(Sender: TObject);
    procedure _ComposerAttachRemove(Sender: TObject; const AId: string);
    procedure _ComposerMemoryOpen(Sender: TObject);
    procedure _PushComposerAttachments;
    // --- Top toolbar -------------------------------------------------------
    /// <summary>Builds the alTop toolbar panel + its flat glyph buttons (AI
    /// composer / Find / Action Center), each wired to the existing action.</summary>
    procedure _CreateToolbar;
    /// <summary>Vertical space the always-visible top toolbar consumes, fed to the
    /// paint TopOffset and subtracted from _VisibleRows (the top twin of
    /// _ComposerBarHeight). 0 before the toolbar exists.</summary>
    function _ToolbarHeight: Integer;
    /// <summary>Creates one flat dark toolbar button at ALeft with a drawn light
    /// glyph (AGlyph: 'A'=AI bubble, 'F'=magnifier, 'C'=action list), a hint and a
    /// click handler, parented to the toolbar.</summary>
    function _MakeToolButton(const ALeft: Integer; const AGlyph: Char;
      const AHint: string; const AOnClick: TNotifyEvent): TSpeedButton;
    procedure _DrawAiGlyph(const ACanvas: TCanvas; const ARect: TRect);
    procedure _DrawFindGlyph(const ACanvas: TCanvas; const ARect: TRect);
    procedure _DrawActionsGlyph(const ACanvas: TCanvas; const ARect: TRect);
    procedure _ToolAiClick(Sender: TObject);
    procedure _ToolFindClick(Sender: TObject);
    procedure _ToolActionsClick(Sender: TObject);
  protected
    procedure CreateWnd; override;
    procedure Paint; override;
    procedure Resize; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure UTF8KeyPress(var UTF8Key: TUTF8Char); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint): Boolean; override;
    procedure DoEnter; override;
    procedure DoExit; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    /// <summary>Spawns the shell (e.g. 'cmd.exe') behind the pseudo-console and
    /// starts streaming its output. Idempotent; guarded - a spawn failure shows a
    /// notice on the grid instead of raising into the IDE.</summary>
    procedure StartShell(const ACommand: string);
    /// <summary>True once StartShell has spawned a child.</summary>
    property Started: Boolean read FStarted;
    // --- ITerminalInput (Action Center runner target) ----------------------
    /// <summary>ITerminalInput: True when a live shell can receive input.
    /// Mirrors the Delphi TTerminalHost.IsActive gate (running controller).</summary>
    function IsActive: Boolean;
    /// <summary>ITerminalInput: writes AText verbatim to the shell. The runner
    /// already CR-terminates each script line, so this forwards the bytes as-is
    /// (the Delphi TTerminalHost.SendInput contract). AText is a UTF-8
    /// AnsiString; _EmitAscii sends each byte unchanged.</summary>
    procedure SendInput(const AText: string);
  end;

implementation

uses
  // The Action Center toolbar button opens the SAME saved-actions window the IDE
  // "Action Center" menu item does (Register.pas -> TAefosLazActionCenter.Show).
  // Implementation-only use: that unit's interface does not reach back here, so no
  // circular-interface dependency (its impl uses TerminalWindow, which interface-
  // uses this control, but the cycle is closed through implementation sections).
  Aefos.Lazarus.ActionCenterWindow;

{ TAefosLazTerminalControl }

constructor TAefosLazTerminalControl.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  TabStop := True;
  DoubleBuffered := True;
  FCellWidth := 8;
  FCellHeight := 14;
  FCursorOn := True;
  _InitTheme;
  Color := FDefaultBg;
  Font.Name := 'Consolas';
  Font.Size := 10;

  // Screen model + controller are owned here (plain classes, freed in Destroy
  // BEFORE the inherited component teardown so the reader thread is joined while
  // the buffer it feeds is still alive).
  FBuffer := TVTermBuffer.Create(80, 25);
  FBuffer.OnChange := _OnBufferChange;
  FController := TAefosTerminalController.Create(FBuffer);

  // Vertical scrollback scrollbar docked to the right edge (mirrors the Delphi
  // canvas). TabStop off so it never steals focus from the typeable grid; the
  // draw area (_DrawAreaWidth) already excludes its width so the grid never
  // paints under it.
  FScrollBar := TScrollBar.Create(Self);
  FScrollBar.Parent := Self;
  FScrollBar.Kind := sbVertical;
  FScrollBar.Align := alRight;
  FScrollBar.OnChange := _ScrollBarChange;
  FScrollBar.TabStop := False;

  FBlink := TTimer.Create(Self);
  FBlink.Interval := 530;
  FBlink.OnTimer := _BlinkTick;
  FBlink.Enabled := True;

  // Find bar (Ctrl+F) starts hidden; FFindLen = 0 means no highlight is painted.
  FFindLine := -1;
  FFindCol := 0;
  FFindLen := 0;
  _CreateFindBar;

  // AI composer bar (Ctrl+I) starts hidden. The attachment map is a plain object
  // owned here (freed in Destroy). The WebView pane + floating picker are child
  // controls created below and freed FIRST in Destroy (controlled WebView2
  // teardown before the controller/buffer go).
  FAttachments := TDictionary<string, string>.Create;
  _CreateComposerBar;

  // The top toolbar is always visible; created last so it sits above the other
  // child controls. It is alNone (see _CreateToolbar) and, like the alNone composer,
  // stops at the scrollbar's LEFT edge -- the alRight scrollbar owns a clean
  // full-height column on the right (kept in sync by _LayoutChrome).
  _CreateToolbar;
end;

destructor TAefosLazTerminalControl.Destroy;
begin
  if Assigned(FBlink) then
    FBlink.Enabled := False;
  // Free the composer WebView pane + picker FIRST (composer-freed-first ordering):
  // the pane's destructor drops the WebView2 sinks and the host's C1 liveness token
  // neutralises any late callback, so the WebView2 controller/child process is torn
  // down cleanly here -- never outliving the terminal -- before the reader thread
  // and buffer below go. Both are child controls of Self; freeing them explicitly
  // removes them from the owner list so the inherited destructor does not re-touch.
  FreeAndNil(FComposerPane);
  FreeAndNil(FPicker);
  FreeAndNil(FAttachments);
  if Assigned(FBuffer) then
    FBuffer.OnChange := nil;
  // Stop + join the reader thread while the buffer is still alive, then free both.
  FreeAndNil(FController);
  FreeAndNil(FBuffer);
  inherited Destroy;
end;

procedure TAefosLazTerminalControl._InitTheme;
var
  LIndex: Integer;
const
  // Embarcadero-themed base-16 ANSI palette, replicated from the Delphi
  // Aefos.OTA.Terminal.Core.VisualTokens.AnsiColor (that unit is VCL-only, so the
  // values are inlined here to keep the colours identical across editions).
  cAnsi: array[0..15] of array[0..2] of Byte = (
    ( 30,  30,  30), (190,  55,  54), ( 46, 160,  67), (197, 140,   0),
    (  1,  88, 175), (128,  50, 180), (  0, 152, 173), (190, 190, 190),
    ( 90,  90,  90), (240,  80,  80), ( 80, 200, 100), (243, 178,  50),
    ( 60, 140, 230), (200,  80, 240), ( 50, 210, 210), (240, 240, 240));
begin
  for LIndex := 0 to 15 do
    FBasePalette[LIndex] := RGBToColor(
      cAnsi[LIndex][0], cAnsi[LIndex][1], cAnsi[LIndex][2]);
  FDefaultBg := RGBToColor(24, 24, 24);
  FDefaultFg := RGBToColor(220, 220, 220);
  // Embarcadero brand orange #F37021 (VisualTokens.Accent), the cursor colour.
  FCursorColor := RGBToColor(243, 112, 33);
end;

procedure TAefosLazTerminalControl.CreateWnd;
begin
  inherited CreateWnd;
  // The window (and its Canvas font metrics) exist now: recompute the real cell
  // size and size the buffer/pseudo-console to what will actually be painted.
  _ComputeMetrics;
  _ApplyGeometry;
end;

procedure TAefosLazTerminalControl._ComputeMetrics;
begin
  FCellWidth := 8;
  FCellHeight := 14;
  if not HandleAllocated then Exit;
  Canvas.Font := Font;
  FCellWidth := Canvas.TextWidth('W');
  FCellHeight := Canvas.TextHeight('Wg');
  if FCellWidth < 1 then FCellWidth := 8;
  if FCellHeight < 1 then FCellHeight := 14;
end;

function TAefosLazTerminalControl._DrawAreaWidth: Integer;
var
  LBarWidth: Integer;
begin
  // Exclude the docked scrollbar so the grid never paints under it (mirrors the
  // Delphi canvas ClientWidth - FScrollBar.Width). The bar keeps its layout width
  // even when disabled/invisible, so the grid width stays stable.
  LBarWidth := 0;
  if Assigned(FScrollBar) then
    LBarWidth := FScrollBar.Width;
  Result := ClientWidth - LBarWidth;
  if Result < FCellWidth then
    Result := FCellWidth;
end;

function TAefosLazTerminalControl._VisibleCols: Integer;
begin
  Result := _DrawAreaWidth div FCellWidth;
  if Result < 1 then Result := 1;
end;

function TAefosLazTerminalControl._VisibleRows: Integer;
begin
  // Exclude the top toolbar's height AND the composer bar's height (when docked at
  // the bottom), so the grid (and the pseudo-console resize keyed off it) only
  // covers the rows painted BETWEEN the toolbar and the bar -- neither the toolbar
  // above nor the prompt hides any output.
  Result := (ClientHeight - _ToolbarHeight - _ComposerBarHeight) div FCellHeight;
  if Result < 1 then Result := 1;
end;

function TAefosLazTerminalControl._TopLine: Integer;
begin
  Result := FBuffer.ScrollbackCount - FScrollOffset;
  if Result < 0 then
    Result := 0;
end;

function TAefosLazTerminalControl._TotalLines: Integer;
begin
  Result := FBuffer.ScrollbackCount + FBuffer.Rows;
end;

function TAefosLazTerminalControl._CellOfLine(
  const AAbsLine, AX: Integer): TTerminalCell;
begin
  if AAbsLine < FBuffer.ScrollbackCount then
    Result := FBuffer.ScrollbackCell(AAbsLine, AX)
  else
    Result := FBuffer.Cell(AX, AAbsLine - FBuffer.ScrollbackCount);
end;

procedure TAefosLazTerminalControl._SyncScrollBar;
var
  LMax: Integer;
begin
  if not Assigned(FScrollBar) then Exit;
  if not HandleAllocated then Exit;
  LMax := FBuffer.ScrollbackCount;
  if LMax < 0 then LMax := 0;
  // With no history the bar is a dead rail: disable it so it neither draws a
  // draggable thumb nor accepts input (Delphi keeps it enabled but empty; a
  // disabled rail reads cleaner and the draw-area width stays unchanged).
  FScrollBar.Enabled := LMax > 0;
  // LCL TScrollBar tolerates PageSize/Max ordering better than VCL, but clear
  // PageSize before shrinking the range to stay safe on an empty scrollback.
  FScrollBar.PageSize := 0;
  FScrollBar.Min := 0;
  FScrollBar.Max := LMax;
  if LMax > 0 then
    FScrollBar.PageSize := 1;
  // Position counts DOWN from the top: bottom (live) = Max, fully scrolled up = 0.
  FScrollBar.Position := FScrollBar.Max - FScrollOffset;
end;

procedure TAefosLazTerminalControl._ScrollBarChange(Sender: TObject);
begin
  FScrollOffset := FScrollBar.Max - FScrollBar.Position;
  if FScrollOffset < 0 then
    FScrollOffset := 0;
  Invalidate;
end;

procedure TAefosLazTerminalControl._LayoutChrome;
var
  LBarWidth, LChromeWidth: Integer;
begin
  if not Assigned(FScrollBar) then Exit;
  // The alRight scrollbar spans the full client height (no alTop/alBottom sibling
  // squeezes it now that the bars are alNone). The toolbar + composer stop at the
  // scrollbar's LEFT edge, so the scrollbar reads as an intentional full-height
  // right column rather than a strip sandwiched between two dark bars.
  LBarWidth := FScrollBar.Width;
  LChromeWidth := ClientWidth - LBarWidth;
  if LChromeWidth < 0 then
    LChromeWidth := 0;
  if Assigned(FToolbar) then
    FToolbar.SetBounds(0, 0, LChromeWidth, FToolbar.Height);
  if Assigned(FComposerBar) then
    // Re-pin the (alNone) composer to the bottom: its Top follows the client height,
    // its width stops at the scrollbar. Height is owned by the toggle / auto-grow.
    FComposerBar.SetBounds(0, ClientHeight - FComposerBar.Height, LChromeWidth,
      FComposerBar.Height);
end;

procedure TAefosLazTerminalControl._ApplyGeometry;
var
  LCols, LRows: Integer;
begin
  if not HandleAllocated then Exit;
  if not Assigned(FBuffer) then Exit;
  // Re-flow the chrome bars around the full-height scrollbar column before the grid
  // resize (runs on every geometry change: this is the single hook every caller of
  // _ApplyGeometry -- Resize, CreateWnd, composer toggle / auto-grow / close -- goes
  // through).
  _LayoutChrome;
  LCols := _VisibleCols;
  LRows := _VisibleRows;
  // Guard against destructive resizes while the panel is being dragged/docked to a
  // tiny size (mirrors the Delphi canvas guard).
  if (LCols < 15) or (LRows < 3) then Exit;
  if (LCols <> FBuffer.Cols) or (LRows <> FBuffer.Rows) then
    // Controller.Resize resizes the buffer always and the PTY only when running.
    FController.Resize(LCols, LRows);
  _SyncScrollBar;
end;

procedure TAefosLazTerminalControl.Resize;
begin
  inherited Resize;
  if (FCellWidth > 0) and Assigned(FBuffer) then
    _ApplyGeometry;
  // Keep the find overlay pinned to the top-right of the grid as the pane resizes.
  if Assigned(FFindBar) and FFindBar.Visible then
    _AnchorFindBar;
  // Keep the floating '/' picker pinned just above the (full-width alBottom) bar.
  if Assigned(FComposerBar) and FComposerBar.Visible
    and Assigned(FPicker) and FPicker.IsShown then
    FPicker.ShowAbove(FComposerBar.BoundsRect);
  Invalidate;
end;

procedure TAefosLazTerminalControl._OnBufferChange(Sender: TObject);
begin
  // Fired synchronously from FeedBytes/Resize, both already on the main thread.
  if csDestroying in ComponentState then Exit;
  // Stick-to-bottom is implicit: at FScrollOffset = 0 the viewport already tracks
  // the live tail. When scrolled up, keep the user's offset - but clamp it to the
  // (possibly shrunk) ScrollbackCount so a cls/clear that empties history snaps
  // the view back to live instead of pointing past the ring (mirrors the Delphi
  // canvas, which resets FScrollOffset to 0 on those screen-clear paths).
  if FScrollOffset > FBuffer.ScrollbackCount then
    FScrollOffset := FBuffer.ScrollbackCount;
  _SyncScrollBar;
  Invalidate;
end;

procedure TAefosLazTerminalControl._BlinkTick(Sender: TObject);
begin
  FCursorOn := not FCursorOn;
  if Focused then
    Invalidate;
end;

procedure TAefosLazTerminalControl.Paint;
var
  LSnap: TTerminalSnapshot;
begin
  if not Assigned(FBuffer) then Exit;
  LSnap.CellWidth     := FCellWidth;
  LSnap.CellHeight    := FCellHeight;
  LSnap.DrawAreaWidth := _DrawAreaWidth;
  // Paint region excludes the docked composer bar (see _VisibleRows), so the grid
  // background clear stops at the bar top rather than painting under it.
  LSnap.ClientHeight  := ClientHeight - _ComposerBarHeight;
  // Push the whole grid (rows, cursor, padding strips) down below the top toolbar
  // so its first rows are not painted behind the alTop bar.
  LSnap.TopOffset     := _ToolbarHeight;
  LSnap.VisibleRows   := _VisibleRows;
  LSnap.VisibleCols   := _VisibleCols;
  LSnap.DefaultFg     := FDefaultFg;
  LSnap.DefaultBg     := FDefaultBg;
  LSnap.CursorColor   := FCursorColor;
  LSnap.BasePalette   := FBasePalette;
  LSnap.Buffer        := FBuffer;
  LSnap.ScrollOffset  := FScrollOffset;
  LSnap.CursorOn      := FCursorOn;
  LSnap.Focused       := Focused;
  LSnap.CursorShape   := csBlock;
  LSnap.FontName      := Font.Name;
  LSnap.FontSize      := Font.Size;
  LSnap.HasSelection  := FHasSelection;
  LSnap.SelAnchor     := FSelAnchor;
  LSnap.SelEnd        := FSelEnd;
  LSnap.FindLine      := FFindLine;
  LSnap.FindCol       := FFindCol;
  LSnap.FindLen       := FFindLen;
  TTerminalPainter.Paint(Canvas, LSnap);
  FBuffer.ClearDirty;
end;

procedure TAefosLazTerminalControl.MouseDown(Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  // A click must land the keyboard focus INSIDE the grid. When the panel floats,
  // window activation focuses the control for free; docked (an AnchorDocking page)
  // the click is absorbed by the host site and the control never gains focus, so
  // keystrokes never reach the shell. Grab it explicitly - this is what makes the
  // docked terminal typeable, mirroring the Delphi canvas' WMLButtonDown SetFocus.
  if CanFocus and not Focused then
    SetFocus;
  // Start a text selection on left-press (mirrors the Delphi canvas). This slice
  // has no mouse-reporting / hyperlink routing, so a left press always selects.
  if Button = mbLeft then
  begin
    FSelecting := True;
    FHasSelection := False;
    FSelAnchor := _PixelToCell(X, Y);
    FSelEnd := FSelAnchor;
    Invalidate;
  end;
end;

procedure TAefosLazTerminalControl.MouseMove(Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseMove(Shift, X, Y);
  if FSelecting then
  begin
    FSelEnd := _PixelToCell(X, Y);
    FHasSelection := (FSelEnd.X <> FSelAnchor.X) or (FSelEnd.Y <> FSelAnchor.Y);
    Invalidate;
  end;
end;

procedure TAefosLazTerminalControl.MouseUp(Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  FSelecting := False;
end;

function TAefosLazTerminalControl.DoMouseWheel(Shift: TShiftState;
  WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  // This slice has no mouse-reporting routing (a full-screen program can't grab
  // the wheel), so the wheel always scrolls the scrollback viewport. Wheel up
  // reveals history (offset toward ScrollbackCount); wheel down returns to live
  // (offset toward 0). Three lines per notch, matching the Delphi canvas.
  if not Assigned(FBuffer) then Exit(False);
  if WheelDelta > 0 then
    FScrollOffset := Min(FScrollOffset + 3, FBuffer.ScrollbackCount)
  else
    FScrollOffset := Max(FScrollOffset - 3, 0);
  _SyncScrollBar;
  Invalidate;
  Result := True;
end;

function TAefosLazTerminalControl._PixelToCell(const AX, AY: Integer): TPoint;
var
  LGridY: Integer;
begin
  Result.X := AX div FCellWidth;
  if Result.X < 0 then Result.X := 0;
  // Clamp to Cols (not Cols-1): Cols is the valid past-the-end boundary for the
  // half-open [start..end) selection key, so a drag to the right edge still
  // includes the last column (matches the Delphi canvas' _PixelToCell).
  if Result.X > FBuffer.Cols then Result.X := FBuffer.Cols;
  // Y is the ABSOLUTE line under the current viewport: _TopLine + view row. The
  // grid starts at _ToolbarHeight (the paint TopOffset), so subtract that from the
  // client Y before mapping to a row; clamp a click on/above the toolbar to row 0.
  LGridY := AY - _ToolbarHeight;
  if LGridY < 0 then LGridY := 0;
  Result.Y := _TopLine + (LGridY div FCellHeight);
  if Result.Y < 0 then Result.Y := 0;
end;

function TAefosLazTerminalControl._IsSelected(const ACol, ALine: Integer): Boolean;
var
  LStart, LEnd: TPoint;
  LKey, LStartKey, LEndKey: Int64;
begin
  Result := False;
  if not FHasSelection then Exit;
  if (FSelAnchor.Y < FSelEnd.Y) or
     ((FSelAnchor.Y = FSelEnd.Y) and (FSelAnchor.X <= FSelEnd.X)) then
  begin
    LStart := FSelAnchor;
    LEnd := FSelEnd;
  end
  else
  begin
    LStart := FSelEnd;
    LEnd := FSelAnchor;
  end;
  LKey := Int64(ALine) * 100000 + ACol;
  LStartKey := Int64(LStart.Y) * 100000 + LStart.X;
  LEndKey := Int64(LEnd.Y) * 100000 + LEnd.X;
  Result := (LKey >= LStartKey) and (LKey < LEndKey);
end;

function TAefosLazTerminalControl._CellText(const ACell: TTerminalCell): string;
begin
  // Control / null codepoints (unwritten cells) collapse to a space so a whole
  // trailing run trims off; printable scalars (BMP + astral) go through
  // UnicodeToUTF8 exactly as the painter draws them.
  if ACell.Ch < 32 then
    Result := ' '
  else
    Result := UnicodeToUTF8(ACell.Ch);
end;

procedure TAefosLazTerminalControl.CopySelection;
var
  LStartLine, LEndLine, LLine, LCol, LFrom: Integer;
  LLineText: string;
  LBuilder: TStringList;
begin
  if not FHasSelection then Exit;
  if not Assigned(FBuffer) then Exit;
  // Order the anchor/end lines top-to-bottom (same key ordering as _IsSelected).
  if FSelAnchor.Y * 100000 + FSelAnchor.X <= FSelEnd.Y * 100000 + FSelEnd.X then
  begin
    LStartLine := FSelAnchor.Y; LEndLine := FSelEnd.Y;
  end
  else
  begin
    LStartLine := FSelEnd.Y; LEndLine := FSelAnchor.Y;
  end;
  // TStringList joins with the platform line break and gives byte-safe UTF-8
  // assembly; a TStringBuilder is Ansi-only under FPC and Copy() on a UTF-8
  // string would be byte-indexed, so build each line column-by-column instead.
  LBuilder := TStringList.Create;
  try
    for LLine := LStartLine to LEndLine do
    begin
      // LLine is an ABSOLUTE line: skip anything outside scrollback + live grid.
      if (LLine < 0) or (LLine >= _TotalLines) then
      begin
        LBuilder.Add('');
        Continue;
      end;
      // First selected column on this line (Delphi CopySelection: LFrom defaults
      // to 0 and the copy always runs to the last column, then TrimRight).
      LFrom := 0;
      for LCol := 0 to FBuffer.Cols - 1 do
        if _IsSelected(LCol, LLine) then
        begin
          LFrom := LCol;
          Break;
        end;
      LLineText := '';
      // _CellOfLine resolves the absolute line to scrollback or the live grid, so
      // a copy taken while scrolled up grabs the right history (Delphi twin).
      for LCol := LFrom to FBuffer.Cols - 1 do
        LLineText := LLineText + _CellText(_CellOfLine(LLine, LCol));
      LBuilder.Add(TrimRight(LLineText));
    end;
    // TStringList.Text appends a trailing line break; Delphi's AppendLine loop
    // does the same, so the copied block ends with a newline either way.
    Clipboard.AsText := LBuilder.Text;
  finally
    LBuilder.Free;
  end;
end;

function TAefosLazTerminalControl._PreparePastePayload(const AText: string;
  const ABracketed: Boolean): string;
var
  LIndex, LLen: Integer;
  LChar: Char;
begin
  // Byte-faithful twin of the Delphi TTerminalHost.PreparePastePayload. AText is a
  // UTF-8 AnsiString (LCL clipboard); every byte of a multibyte glyph is >= $80 so
  // it never matches the CR/LF checks and passes through the else branch intact.
  Result := '';
  if AText = '' then Exit;
  if ABracketed then
  begin
    Result := #27'[200~' + AText + #27'[201~';
    Exit;
  end;
  LLen := Length(AText);
  LIndex := 1;
  while LIndex <= LLen do
  begin
    LChar := AText[LIndex];
    if LChar = #13 then
    begin
      Result := Result + #13;
      if (LIndex < LLen) and (AText[LIndex + 1] = #10) then
        Inc(LIndex);
    end
    else if LChar = #10 then
      Result := Result + #13
    else
      Result := Result + LChar;
    Inc(LIndex);
  end;
end;

procedure TAefosLazTerminalControl.PasteFromClipboard;
var
  LText, LPayload: string;
  LBracketed: Boolean;
begin
  if not (Assigned(FController) and FController.IsRunning) then Exit;
  // Clipboard.AsText is the empty string for a non-text / empty clipboard - a
  // silent no-op, matching the Delphi SendCtrlV contract.
  LText := Clipboard.AsText;
  if LText = '' then Exit;
  LBracketed := Assigned(FBuffer) and FBuffer.BracketedPasteEnabled;
  LPayload := _PreparePastePayload(LText, LBracketed);
  // LPayload is a UTF-8 AnsiString; _EmitAscii forwards each byte verbatim.
  _EmitAscii(LPayload);
end;

procedure TAefosLazTerminalControl.DoEnter;
begin
  inherited DoEnter;
  FCursorOn := True;
  Invalidate;
end;

procedure TAefosLazTerminalControl.DoExit;
begin
  inherited DoExit;
  Invalidate;
end;

procedure TAefosLazTerminalControl._EmitBytes(const AData: TBytes);
begin
  if (Length(AData) > 0) and Assigned(FController) and FController.IsRunning then
    FController.WriteBytes(AData);
end;

procedure TAefosLazTerminalControl._EmitAscii(const AData: string);
var
  LBytes: TBytes;
  LIndex: Integer;
begin
  if AData = '' then Exit;
  SetLength(LBytes, Length(AData));
  for LIndex := 1 to Length(AData) do
    LBytes[LIndex - 1] := Byte(AData[LIndex]);
  _EmitBytes(LBytes);
end;

function TAefosLazTerminalControl._EncodeSpecialKey(const AKey: Word): string;
begin
  case AKey of
    VK_UP:     Result := #27'[A';
    VK_DOWN:   Result := #27'[B';
    VK_RIGHT:  Result := #27'[C';
    VK_LEFT:   Result := #27'[D';
    VK_HOME:   Result := #27'[H';
    VK_END:    Result := #27'[F';
    VK_PRIOR:  Result := #27'[5~';
    VK_NEXT:   Result := #27'[6~';
    VK_INSERT: Result := #27'[2~';
    VK_DELETE: Result := #27'[3~';
    VK_F1:     Result := #27'OP';
    VK_F2:     Result := #27'OQ';
    VK_F3:     Result := #27'OR';
    VK_F4:     Result := #27'OS';
    VK_F5:     Result := #27'[15~';
    VK_F6:     Result := #27'[17~';
    VK_F7:     Result := #27'[18~';
    VK_F8:     Result := #27'[19~';
    VK_F9:     Result := #27'[20~';
    VK_F10:    Result := #27'[21~';
    VK_F11:    Result := #27'[23~';
    VK_F12:    Result := #27'[24~';
  else
    Result := '';
  end;
end;

procedure TAefosLazTerminalControl.KeyDown(var Key: Word; Shift: TShiftState);
var
  LSeq: string;
begin
  // Ctrl+F toggles the find bar. It MUST be handled before the generic
  // Ctrl+letter -> C0 path below, otherwise Ctrl+F would degrade into ACK (#6).
  if (Key = Ord('F')) and (ssCtrl in Shift) and not (ssAlt in Shift) then
  begin
    _ToggleFindBar;
    Key := 0;
    Exit;
  end;
  // Ctrl+I toggles the AI composer bar. Like Ctrl+F it MUST be handled before the
  // generic Ctrl+letter -> C0 path below (Ctrl+I would otherwise degrade into HT
  // / #9). The Tab KEY itself still reaches the shell via VK_TAB, so the shell
  // loses nothing.
  if (Key = Ord('I')) and (ssCtrl in Shift) and not (ssAlt in Shift) then
  begin
    _ToggleComposerBar;
    Key := 0;
    Exit;
  end;
  // F3 / Shift+F3 cycle matches while the find bar is open. When it is closed the
  // key falls through to the normal VT function-key encoding (unchanged).
  if (Key = VK_F3) and Assigned(FFindBar) and FFindBar.Visible then
  begin
    if ssShift in Shift then _DoFind(False) else _DoFind(True);
    Key := 0;
    Exit;
  end;
  // Clipboard shortcuts are handled BEFORE the generic Ctrl+letter -> C0 path so
  // Ctrl+C/Ctrl+V never degrade into ETX/SYN when they mean copy/paste. This is
  // the Delphi SendCtrlC/SendCtrlV contract.
  if (ssCtrl in Shift) and not (ssAlt in Shift) then
  begin
    // Ctrl+C copies WHEN there is a selection; with nothing selected it falls
    // through to the #3 interrupt below (unchanged behaviour).
    if (Key = Ord('C')) and FHasSelection then
    begin
      CopySelection;
      Key := 0;
      Exit;
    end;
    // Ctrl+Shift+C: explicit copy alias - never an interrupt (a no-op when there
    // is no selection).
    if (Key = Ord('C')) and (ssShift in Shift) then
    begin
      if FHasSelection then CopySelection;
      Key := 0;
      Exit;
    end;
    // Ctrl+V / Ctrl+Shift+V: paste (must not become the Ctrl+V -> SYN C0 byte).
    if Key = Ord('V') then
    begin
      PasteFromClipboard;
      Key := 0;
      Exit;
    end;
  end;
  // Shift+Insert: common terminal paste alias.
  if (Key = VK_INSERT) and (ssShift in Shift) and not (ssCtrl in Shift) then
  begin
    PasteFromClipboard;
    Key := 0;
    Exit;
  end;
  // Ctrl+letter -> the C0 control byte (Ctrl+C = ETX #3 interrupts the shell).
  if (Key >= Ord('A')) and (Key <= Ord('Z')) and (ssCtrl in Shift)
    and not (ssAlt in Shift) then
  begin
    _EmitAscii(Chr(Key - Ord('A') + 1));
    Key := 0;
    Exit;
  end;
  case Key of
    VK_RETURN:
      begin
        _EmitAscii(#13);       // CR submits the line to cmd/ConPTY
        Key := 0;
        Exit;
      end;
    VK_BACK:
      begin
        _EmitAscii(#127);      // DEL, matching the Delphi canvas (#8 -> #127)
        Key := 0;
        Exit;
      end;
    VK_TAB:
      begin
        _EmitAscii(#9);
        Key := 0;
        Exit;
      end;
    VK_ESCAPE:
      begin
        _EmitAscii(#27);
        Key := 0;
        Exit;
      end;
  end;
  LSeq := _EncodeSpecialKey(Key);
  if LSeq <> '' then
  begin
    _EmitAscii(LSeq);
    Key := 0;
    Exit;
  end;
  inherited KeyDown(Key, Shift);
end;

procedure TAefosLazTerminalControl.UTF8KeyPress(var UTF8Key: TUTF8Char);
var
  LBytes: TBytes;
  LIndex: Integer;
begin
  // Control chars are already handled in KeyDown; drop a lone one here so it is
  // not double-sent (Enter/Backspace suppressed their KeyPress via Key := 0, but
  // some widgetsets still deliver a control KeyPress).
  if (Length(UTF8Key) = 1) and (Ord(UTF8Key[1]) < 32) then
  begin
    UTF8Key := '';
    Exit;
  end;
  if Length(UTF8Key) > 0 then
  begin
    SetLength(LBytes, Length(UTF8Key));
    for LIndex := 1 to Length(UTF8Key) do
      LBytes[LIndex - 1] := Byte(UTF8Key[LIndex]);
    _EmitBytes(LBytes);
  end;
  UTF8Key := '';
end;

function TAefosLazTerminalControl._SplitCells(const AText: string;
  const ACaseSensitive: Boolean): TAefosLineCells;
var
  LText: string;
  LLen, LIndex: Integer;
begin
  // Case-fold the whole needle first (UTF8LowerCase is codepoint-correct), then
  // split into one entry per codepoint with UTF8Copy so each entry lines up with
  // exactly one grid cell during the match scan.
  LText := AText;
  if not ACaseSensitive then
    LText := UTF8LowerCase(LText);
  LLen := UTF8Length(LText);
  SetLength(Result, LLen);
  for LIndex := 1 to LLen do
    Result[LIndex - 1] := UTF8Copy(LText, LIndex, 1);
end;

function TAefosLazTerminalControl._LineCells(const AAbsLine: Integer;
  const ACaseSensitive: Boolean): TAefosLineCells;
var
  LX: Integer;
  LText: string;
begin
  // One entry per grid column. _CellText collapses control / unwritten cells to a
  // space (so trailing blanks are searchable spaces); case-fold per cell so the
  // comparison against the (already folded) needle is a plain string equality.
  SetLength(Result, FBuffer.Cols);
  for LX := 0 to FBuffer.Cols - 1 do
  begin
    LText := _CellText(_CellOfLine(AAbsLine, LX));
    if not ACaseSensitive then
      LText := UTF8LowerCase(LText);
    Result[LX] := LText;
  end;
end;

function TAefosLazTerminalControl._MatchAt(const ALine,
  ANeedle: TAefosLineCells; const AStartCol: Integer): Integer;
var
  LCol, LK, LMax: Integer;
  LMatch: Boolean;
begin
  Result := -1;
  if Length(ANeedle) = 0 then Exit;
  LMax := Length(ALine) - Length(ANeedle);
  LCol := AStartCol;
  if LCol < 0 then LCol := 0;
  while LCol <= LMax do
  begin
    LMatch := True;
    for LK := 0 to Length(ANeedle) - 1 do
      if ALine[LCol + LK] <> ANeedle[LK] then
      begin
        LMatch := False;
        Break;
      end;
    if LMatch then Exit(LCol);
    Inc(LCol);
  end;
end;

function TAefosLazTerminalControl.FindText(const ASearch: string;
  const AForward, ACaseSensitive: Boolean): Boolean;
var
  LLine, LStartLine, LTargetLine, LCol: Integer;
  LNeedle, LLineCells: TAefosLineCells;
begin
  // Cell-based twin of the Delphi TTerminalCanvas.FindText. The needle and each
  // line are broken into per-cell (per-codepoint) strings and matched cell-by-cell,
  // so FFindCol is inherently a GRID column (the painter highlights grid columns)
  // rather than a UTF-8 byte offset a Pos() would have produced.
  Result := False;
  if ASearch = '' then Exit;
  LNeedle := _SplitCells(ASearch, ACaseSensitive);
  if Length(LNeedle) = 0 then Exit;
  LStartLine := FFindLine;
  for LLine := 0 to _TotalLines - 1 do
  begin
    if AForward then
      LTargetLine := (LStartLine + 1 + LLine) mod _TotalLines
    else
      LTargetLine := ((LStartLine - 1 - LLine) mod _TotalLines +
        _TotalLines) mod _TotalLines;
    LLineCells := _LineCells(LTargetLine, ACaseSensitive);
    LCol := _MatchAt(LLineCells, LNeedle, 0);
    if LCol >= 0 then
    begin
      FFindLine := LTargetLine;
      FFindCol := LCol;
      FFindLen := Length(LNeedle);
      // Scroll the viewport so the matched absolute line is in view (Delphi twin).
      FScrollOffset := Max(0, FBuffer.ScrollbackCount - FFindLine);
      _SyncScrollBar;
      Invalidate;
      Exit(True);
    end;
  end;
end;

function TAefosLazTerminalControl.CountFindMatches(const ASearch: string;
  const ACaseSensitive: Boolean): Integer;
var
  LLine, LCol: Integer;
  LNeedle, LLineCells: TAefosLineCells;
begin
  Result := 0;
  if ASearch = '' then Exit;
  LNeedle := _SplitCells(ASearch, ACaseSensitive);
  if Length(LNeedle) = 0 then Exit;
  for LLine := 0 to _TotalLines - 1 do
  begin
    LLineCells := _LineCells(LLine, ACaseSensitive);
    LCol := 0;
    while True do
    begin
      LCol := _MatchAt(LLineCells, LNeedle, LCol);
      if LCol < 0 then Break;
      Inc(Result);
      // Advance past this (non-overlapping) match, matching the Delphi PosEx loop.
      Inc(LCol, Max(1, Length(LNeedle)));
    end;
  end;
end;

function TAefosLazTerminalControl.FindCurrentMatchIndex(const ASearch: string;
  const ACaseSensitive: Boolean): Integer;
var
  LLine, LCol, LIndex: Integer;
  LNeedle, LLineCells: TAefosLineCells;
begin
  Result := 0;
  if (ASearch = '') or (FFindLen = 0) or (FFindLine < 0) then Exit;
  LNeedle := _SplitCells(ASearch, ACaseSensitive);
  if Length(LNeedle) = 0 then Exit;
  LIndex := 0;
  for LLine := 0 to _TotalLines - 1 do
  begin
    LLineCells := _LineCells(LLine, ACaseSensitive);
    LCol := 0;
    while True do
    begin
      LCol := _MatchAt(LLineCells, LNeedle, LCol);
      if LCol < 0 then Break;
      Inc(LIndex);
      if (LLine = FFindLine) and (LCol = FFindCol) then
        Exit(LIndex);
      Inc(LCol, Max(1, Length(LNeedle)));
    end;
  end;
end;

procedure TAefosLazTerminalControl._CreateFindBar;
begin
  // A code-created child overlay (no DFM / .lpk unit). Hidden until Ctrl+F. The
  // controls are owned by Self so the inherited destructor frees them.
  // Dark chrome that reads as part of the terminal, not a light Windows strip.
  // A code-created child overlay (no DFM / .lpk unit). Hidden until Ctrl+F. The
  // controls are owned by Self so the inherited destructor frees them.
  FFindBar := TPanel.Create(Self);
  FFindBar.Parent := Self;
  FFindBar.BevelOuter := bvNone;
  FFindBar.BorderStyle := bsSingle;
  FFindBar.Color := RGBToColor(37, 37, 38);
  FFindBar.Width := 300;
  FFindBar.Height := 30;
  FFindBar.Visible := False;
  FFindBar.Anchors := [akTop, akRight];

  // Search box: dark field + light text so it belongs on the dark chrome.
  FFindEdit := TEdit.Create(Self);
  FFindEdit.Parent := FFindBar;
  FFindEdit.Left := 6;
  FFindEdit.Top := 4;
  FFindEdit.Width := 150;
  FFindEdit.Height := 22;
  FFindEdit.BorderStyle := bsNone;
  FFindEdit.Color := RGBToColor(30, 30, 30);
  FFindEdit.Font.Color := RGBToColor(230, 230, 230);
  FFindEdit.OnChange := _FindEditChange;
  FFindEdit.OnKeyDown := _FindEditKeyDown;

  // "N of M" counter -- wide enough that a two/three-digit total never clips.
  FFindCountLbl := TLabel.Create(Self);
  FFindCountLbl.Parent := FFindBar;
  FFindCountLbl.Left := 162;
  FFindCountLbl.Top := 8;
  FFindCountLbl.AutoSize := False;
  FFindCountLbl.Width := 58;
  FFindCountLbl.Height := 16;
  FFindCountLbl.Alignment := taCenter;
  FFindCountLbl.Layout := tlCenter;
  FFindCountLbl.Transparent := True;
  FFindCountLbl.Font.Color := RGBToColor(170, 170, 170);
  FFindCountLbl.Caption := '';

  // Flat dark nav buttons (TSpeedButton honours Color/Flat; a themed TButton
  // would stay light on Windows and break the dark look).
  FFindPrevBtn := TSpeedButton.Create(Self);
  FFindPrevBtn.Parent := FFindBar;
  FFindPrevBtn.Left := 222;
  FFindPrevBtn.Top := 4;
  FFindPrevBtn.Width := 22;
  FFindPrevBtn.Height := 22;
  FFindPrevBtn.Flat := True;
  FFindPrevBtn.Caption := '<';
  FFindPrevBtn.Color := RGBToColor(55, 55, 58);
  FFindPrevBtn.Font.Color := RGBToColor(230, 230, 230);
  FFindPrevBtn.OnClick := _FindPrevClick;

  FFindNextBtn := TSpeedButton.Create(Self);
  FFindNextBtn.Parent := FFindBar;
  FFindNextBtn.Left := 246;
  FFindNextBtn.Top := 4;
  FFindNextBtn.Width := 22;
  FFindNextBtn.Height := 22;
  FFindNextBtn.Flat := True;
  FFindNextBtn.Caption := '>';
  FFindNextBtn.Color := RGBToColor(55, 55, 58);
  FFindNextBtn.Font.Color := RGBToColor(230, 230, 230);
  FFindNextBtn.OnClick := _FindNextClick;

  // Case toggle as a flat "Aa" toggle button (not a TCheckBox: the Windows-themed
  // checkbox draws its caption with the OS text colour, ignoring Font.Color, so
  // "Aa" came out black/unreadable on the dark chrome). A grouped SpeedButton
  // honours the dark face + light caption and reads its state via .Down.
  FFindCaseChk := TSpeedButton.Create(Self);
  FFindCaseChk.Parent := FFindBar;
  FFindCaseChk.Left := 270;
  FFindCaseChk.Top := 4;
  FFindCaseChk.Width := 24;
  FFindCaseChk.Height := 22;
  FFindCaseChk.Flat := True;
  FFindCaseChk.GroupIndex := 1;
  FFindCaseChk.AllowAllUp := True;
  FFindCaseChk.Down := False;
  FFindCaseChk.Caption := 'Aa';
  FFindCaseChk.Color := RGBToColor(55, 55, 58);
  FFindCaseChk.Font.Color := RGBToColor(230, 230, 230);
  FFindCaseChk.OnClick := _FindCaseChange;
end;

procedure TAefosLazTerminalControl._AnchorFindBar;
var
  LBarArea: Integer;
begin
  if not Assigned(FFindBar) then Exit;
  // Top-right of the GRID (below the top toolbar), inset by 8px and clear of the
  // docked scrollbar -- so the find bar sits under the toolbar, never behind it.
  LBarArea := 0;
  if Assigned(FScrollBar) then
    LBarArea := FScrollBar.Width;
  FFindBar.Top := _ToolbarHeight + 4;
  FFindBar.Left := ClientWidth - LBarArea - FFindBar.Width - 8;
  if FFindBar.Left < 0 then
    FFindBar.Left := 0;
end;

procedure TAefosLazTerminalControl._ToggleFindBar;
begin
  if not Assigned(FFindBar) then Exit;
  FFindBar.Visible := not FFindBar.Visible;
  if FFindBar.Visible then
  begin
    _AnchorFindBar;
    FFindBar.BringToFront;
    if FFindEdit.CanFocus then
    begin
      FFindEdit.SetFocus;
      FFindEdit.SelectAll;
    end;
    // Re-run over any text already in the box (Delphi ShowFind re-anchors + the
    // edit keeps its text so a re-open resumes the previous search).
    if FFindEdit.Text <> '' then
    begin
      FFindLine := -1;
      _DoFind(True);
    end;
  end
  else
  begin
    // Hiding clears the highlight so no stale match lingers, and returns keyboard
    // focus to the grid so typing goes back to the shell.
    FFindLen := 0;
    Invalidate;
    if CanFocus then
      SetFocus;
  end;
end;

procedure TAefosLazTerminalControl._DoFind(const AForward: Boolean);
begin
  if not Assigned(FFindEdit) then Exit;
  if FFindEdit.Text = '' then
  begin
    FFindLen := 0;
    // Light (not clWindowText/black) so it stays readable on the dark field.
    FFindEdit.Font.Color := RGBToColor(230, 230, 230);
    Invalidate;
  end
  else if FindText(FFindEdit.Text, AForward, FFindCaseChk.Down) then
    FFindEdit.Font.Color := RGBToColor(230, 230, 230)
  else
    // A miss tints the box red (Delphi FindChanged / FindNext / FindPrev twin).
    FFindEdit.Font.Color := RGBToColor(255, 90, 90);
  _UpdateFindCounter;
end;

procedure TAefosLazTerminalControl._UpdateFindCounter;
var
  LTotal, LCurrent: Integer;
begin
  if not Assigned(FFindCountLbl) then Exit;
  if (FFindEdit.Text = '') then
  begin
    FFindCountLbl.Caption := '';
    Exit;
  end;
  LTotal := CountFindMatches(FFindEdit.Text, FFindCaseChk.Down);
  LCurrent := FindCurrentMatchIndex(FFindEdit.Text, FFindCaseChk.Down);
  if (LTotal <= 0) or (LCurrent <= 0) then
    FFindCountLbl.Caption := ''
  else
    // "N of M" match counter (Delphi TFindBarMath.FormatFindCounter is "N/M").
    FFindCountLbl.Caption := Format('%d of %d', [LCurrent, LTotal]);
end;

procedure TAefosLazTerminalControl._FindEditChange(Sender: TObject);
begin
  // Live incremental search: reset the anchor so each keystroke re-finds the first
  // match from the top rather than walking forward off the previous hit.
  FFindLine := -1;
  _DoFind(True);
end;

procedure TAefosLazTerminalControl._FindNextClick(Sender: TObject);
begin
  _DoFind(True);
end;

procedure TAefosLazTerminalControl._FindPrevClick(Sender: TObject);
begin
  _DoFind(False);
end;

procedure TAefosLazTerminalControl._FindCaseChange(Sender: TObject);
begin
  // Re-run from the top with the new case mode.
  FFindLine := -1;
  _DoFind(True);
end;

procedure TAefosLazTerminalControl._FindEditKeyDown(Sender: TObject;
  var Key: Word; Shift: TShiftState);
begin
  // Enter = next (Shift = prev), F3 / Shift+F3 = next / prev, Esc / Ctrl+F = close.
  // The find edit has keyboard focus here, so the control's own KeyDown never sees
  // these - handle them on the edit too.
  case Key of
    VK_RETURN:
      begin
        if ssShift in Shift then _DoFind(False) else _DoFind(True);
        Key := 0;
      end;
    VK_F3:
      begin
        if ssShift in Shift then _DoFind(False) else _DoFind(True);
        Key := 0;
      end;
    VK_ESCAPE:
      begin
        _ToggleFindBar;
        Key := 0;
      end;
    Ord('F'):
      if (ssCtrl in Shift) and not (ssAlt in Shift) then
      begin
        _ToggleFindBar;
        Key := 0;
      end;
  end;
end;

// --- AI composer bar (Ctrl+I) ----------------------------------------------

procedure TAefosLazTerminalControl._CreateComposerBar;
begin
  // A code-created child bar docked to the BOTTOM edge (no DFM / .lpk unit),
  // hidden until Ctrl+I. It hosts the WebView2 composer pane (alClient), which
  // navigates the SHARED BuildComposerHtml so the bar is PIXEL-IDENTICAL to the
  // Delphi composer. The controls are owned by Self; FComposerPane / FPicker are
  // freed FIRST in Destroy (controlled WebView2 teardown).
  FComposerBar := TPanel.Create(Self);
  FComposerBar.Parent := Self;
  // alNone (not alBottom): like the toolbar, it must stop at the scrollbar's LEFT
  // edge so the scrollbar owns the full-height right column. _LayoutChrome re-pins
  // its Top to the bottom and sets its width on every geometry change; akBottom keeps
  // the bottom edge pinned between recomputes (and while it auto-grows upward).
  FComposerBar.Align := alNone;
  FComposerBar.Anchors := [akLeft, akRight, akBottom];
  FComposerBar.BevelOuter := bvNone;
  FComposerBar.BorderStyle := bsNone;
  FComposerBar.Color := RGBToColor(30, 30, 30);
  FComposerBar.Height := 92;
  FComposerBar.Left := 0;
  FComposerBar.Width := ClientWidth - FScrollBar.Width;
  FComposerBar.Top := ClientHeight - FComposerBar.Height;
  FComposerBar.Visible := False;

  FComposerPane := TAefosLazTerminalComposerPane.Create(Self);
  FComposerPane.Parent := FComposerBar;
  FComposerPane.Align := alClient;
  FComposerPane.OnSend := _ComposerPaneSend;
  FComposerPane.OnRequestHeight := _ComposerRequestHeight;
  FComposerPane.OnPicker := _ComposerPicker;
  FComposerPane.OnAttachOpen := _ComposerAttachOpen;
  FComposerPane.OnAttachRemove := _ComposerAttachRemove;
  FComposerPane.OnMemoryOpen := _ComposerMemoryOpen;

  // The floating '/' picker is a SIBLING of the bar (child of this control), so it
  // can overlay the grid above the bar; it positions itself over FComposerBar's
  // BoundsRect (same coordinate space). Hidden by default.
  FPicker := TAefosLazTerminalComposerPicker.Create(Self);
  FPicker.Parent := Self;
  FPicker.OnPick := _PickerPicked;
end;

function TAefosLazTerminalControl._ComposerBarHeight: Integer;
begin
  if Assigned(FComposerBar) and FComposerBar.Visible then
    Result := FComposerBar.Height
  else
    Result := 0;
end;

procedure TAefosLazTerminalControl._ToggleComposerBar;
begin
  if not Assigned(FComposerBar) then Exit;
  FComposerBar.Visible := not FComposerBar.Visible;
  if FComposerBar.Visible then
  begin
    FComposerBar.Height := 92;  // input + action bar; the page re-reports exact px
    FComposerBar.BringToFront;
    // The bar now steals grid height: resize the shell to the rows above it.
    _ApplyGeometry;
    Invalidate;
    if Assigned(FComposerPane) then
      FComposerPane.Activate;   // navigate on first show + focus the textarea
  end
  else
    _CloseComposerBar;
end;

procedure TAefosLazTerminalControl._CloseComposerBar;
begin
  if not Assigned(FComposerBar) then Exit;
  if Assigned(FPicker) then
    FPicker.HidePicker;
  FComposerBar.Visible := False;
  // The bar released its grid height: resize the shell back to the full area.
  _ApplyGeometry;
  Invalidate;
  if CanFocus then
    SetFocus;
end;

procedure TAefosLazTerminalControl.SendCommandToActivePane(const ACommand: string);
begin
  // The Delphi SendCommandToActivePane mechanic: write the text + a submit line
  // break to the pane's running CLI / shell, so whatever runs in the terminal
  // receives it and runs it. A single CR is the ConPTY line submit (same byte the
  // Enter key emits). No-op when no shell is live.
  if not IsActive then
    Exit;
  _EmitAscii(ACommand + #13);
end;

procedure TAefosLazTerminalControl._InjectComposerText(const AText: string);
begin
  if Trim(AText) = '' then
    Exit;
  SendCommandToActivePane(AText);
  if Assigned(FComposerPane) then
    FComposerPane.ClearInput;
end;

procedure TAefosLazTerminalControl._ComposerPaneSend(Sender: TObject;
  const AText: string);
var
  LText, LSend: string;
  LCmds: TArray<TSlashCommand>;
  LIndex: Integer;
  LIsSlash: Boolean;
  LPair: TPair<string, string>;
begin
  LText := Trim(AText);
  if LText = '' then
    Exit;
  LSend := LText;
  LIsSlash := False;
  // '/name' -> inject the command's EXPANDED PROMPT (body), so the AI CLI running
  // in the pane acts on it without needing the slash registered in its own dir.
  if (Length(LText) > 1) and (LText[1] = '/') then
  begin
    LIsSlash := True;
    LCmds := ListSlashCommands('');
    for LIndex := 0 to High(LCmds) do
      if SameText(LCmds[LIndex].Trigger, LText) then
      begin
        LSend := SlashInjectionText(LCmds[LIndex], False);
        Break;
      end;
  end;
  // On a PLAIN send (not a self-contained '/command'), ride the attached file
  // paths along in the text so the CLI in the pane can read them (the PTY is
  // text-only). Then clear the chips both in Pascal state and in the webview.
  if (not LIsSlash) and Assigned(FAttachments) and (FAttachments.Count > 0) then
  begin
    LSend := LSend + sLineBreak + sLineBreak + 'Attached files:';
    for LPair in FAttachments do
      LSend := LSend + sLineBreak + LPair.Value;
    FAttachments.Clear;
    if Assigned(FComposerPane) then
      FComposerPane.SetAttachments([], []);
  end;
  SendCommandToActivePane(LSend);
end;

procedure TAefosLazTerminalControl._ComposerRequestHeight(Sender: TObject;
  const AHeight: Integer);
const
  MIN_H = 92;   // input row + action bar (icons below)
  MAX_H = 320;  // never eat more than this of the terminal
var
  LWanted: Integer;
begin
  if not (Assigned(FComposerBar) and FComposerBar.Visible) then
    Exit;
  LWanted := AHeight;
  if LWanted < MIN_H then LWanted := MIN_H;
  if LWanted > MAX_H then LWanted := MAX_H;
  if FComposerBar.Height <> LWanted then
  begin
    FComposerBar.Height := LWanted;
    // The bar changed height: re-flow the grid (shell resize) and re-anchor the
    // floating picker above the new bar top.
    _ApplyGeometry;
    Invalidate;
    if Assigned(FPicker) and FPicker.IsShown then
      FPicker.ShowAbove(FComposerBar.BoundsRect);
  end;
end;

procedure TAefosLazTerminalControl._ComposerPicker(Sender: TObject;
  AAction: TAefosComposerPickerAction; const AQuery: string);
var
  LAll, LMatch: TArray<TSlashCommand>;
  LIndex: Integer;
  LQ: string;
begin
  if not Assigned(FPicker) then
    Exit;
  case AAction of
    cpaFilter:
      begin
        FComposerFilter := '/' + AQuery;
        LQ := LowerCase(Trim(AQuery));
        LAll := ListSlashCommands('');
        SetLength(LMatch, 0);
        for LIndex := 0 to High(LAll) do
          if (LQ = '') or (Pos(LQ, LowerCase(LAll[LIndex].Name)) > 0) then
          begin
            SetLength(LMatch, Length(LMatch) + 1);
            LMatch[High(LMatch)] := LAll[LIndex];
          end;
        FPicker.SetItems(LMatch);
        // FComposerBar.BoundsRect is in this control's client coords -- the same
        // space the picker (a sibling child) lives in -- so it positions itself
        // directly above the bar with no coordinate conversion.
        FPicker.ShowAbove(FComposerBar.BoundsRect);
      end;
    cpaNavDown:
      FPicker.MoveSel(1);
    cpaNavUp:
      FPicker.MoveSel(-1);
    cpaCommit:
      begin
        FPicker.HidePicker;
        if FPicker.ItemCount > 0 then
          _PickerPicked(FPicker, Default(TSlashCommand))  // uses selection
        else
          _InjectComposerText(FComposerFilter);           // no match: verbatim
      end;
    cpaCancel:
      FPicker.HidePicker;
  end;
end;

procedure TAefosLazTerminalControl._PickerPicked(Sender: TObject;
  const ACommand: TSlashCommand);
var
  LCmd: TSlashCommand;
begin
  if not (Assigned(FPicker) and FPicker.Selected(LCmd)) then
    Exit;
  FPicker.HidePicker;
  // Inject the EXPANDED PROMPT (body): the CLI in the pane has no slash registered.
  _InjectComposerText(SlashInjectionText(LCmd, False));
end;

procedure TAefosLazTerminalControl._PushComposerAttachments;
var
  LIds, LNames: TArray<string>;
  LPair: TPair<string, string>;
  LCount: Integer;
begin
  if not (Assigned(FComposerPane) and Assigned(FAttachments)) then
    Exit;
  SetLength(LIds, FAttachments.Count);
  SetLength(LNames, FAttachments.Count);
  LCount := 0;
  for LPair in FAttachments do
  begin
    LIds[LCount] := LPair.Key;
    LNames[LCount] := ExtractFileName(LPair.Value);
    Inc(LCount);
  end;
  FComposerPane.SetAttachments(LIds, LNames);
end;

procedure TAefosLazTerminalControl._ComposerAttachOpen(Sender: TObject);
var
  LDlg: TOpenDialog;
  LId: string;
begin
  if not Assigned(FAttachments) then
    Exit;
  LDlg := TOpenDialog.Create(nil);
  try
    LDlg.Title := 'Attach a file';
    LDlg.Options := LDlg.Options + [ofFileMustExist, ofPathMustExist];
    LDlg.Filter :=
      'All files (*.*)|*.*' +
      '|Source (*.pas;*.pp;*.lpr;*.inc;*.lfm)|*.pas;*.pp;*.lpr;*.inc;*.lfm' +
      '|Images (*.png;*.jpg;*.jpeg;*.gif;*.bmp)|*.png;*.jpg;*.jpeg;*.gif;*.bmp';
    if LDlg.Execute then
    begin
      Inc(FAttachSeq);
      LId := IntToStr(FAttachSeq);
      FAttachments.AddOrSetValue(LId, LDlg.FileName);
      _PushComposerAttachments;
    end;
  finally
    LDlg.Free;
  end;
end;

procedure TAefosLazTerminalControl._ComposerAttachRemove(Sender: TObject;
  const AId: string);
begin
  if not Assigned(FAttachments) then
    Exit;
  FAttachments.Remove(AId);
  _PushComposerAttachments;
end;

procedure TAefosLazTerminalControl._ComposerMemoryOpen(Sender: TObject);
begin
  // Edit the SAME global memory file the chat edits (%APPDATA%\Aefos\memory.md,
  // via TAefosLazMemoryStore -- byte-compatible with the Delphi twin). One brain.
  TAefosLazTerminalMemoryDialog.Execute(Self);
end;

// --- Top toolbar -----------------------------------------------------------

function TAefosLazTerminalControl._ToolbarHeight: Integer;
begin
  // The toolbar is always visible once created, so its fixed height is the vertical
  // space the grid gives up at the top (fed to the paint TopOffset / _VisibleRows).
  if Assigned(FToolbar) then
    Result := FToolbar.Height
  else
    Result := 0;
end;

procedure TAefosLazTerminalControl._DrawAiGlyph(const ACanvas: TCanvas;
  const ARect: TRect);
begin
  // A rounded speech bubble with a little tail -- reads as the chat/AI composer.
  // Brush is bsClear (outline only); the caller set a light pen.
  ACanvas.RoundRect(ARect.Left, ARect.Top, ARect.Right, ARect.Bottom - 3, 5, 5);
  ACanvas.MoveTo(ARect.Left + 3, ARect.Bottom - 4);
  ACanvas.LineTo(ARect.Left + 2, ARect.Bottom);
  ACanvas.LineTo(ARect.Left + 6, ARect.Bottom - 4);
end;

procedure TAefosLazTerminalControl._DrawFindGlyph(const ACanvas: TCanvas;
  const ARect: TRect);
begin
  // A magnifier: a circle plus a diagonal handle to the lower-right.
  ACanvas.Ellipse(ARect.Left, ARect.Top, ARect.Left + 10, ARect.Top + 10);
  ACanvas.MoveTo(ARect.Left + 8, ARect.Top + 8);
  ACanvas.LineTo(ARect.Right, ARect.Bottom);
end;

procedure TAefosLazTerminalControl._DrawActionsGlyph(const ACanvas: TCanvas;
  const ARect: TRect);
var
  LRow, LY: Integer;
begin
  // Three bullet+line rows -- a list of saved actions (the Action Center catalog).
  for LRow := 0 to 2 do
  begin
    LY := ARect.Top + 1 + LRow * 5;
    ACanvas.Brush.Style := bsSolid;
    ACanvas.Brush.Color := ACanvas.Pen.Color;
    ACanvas.FillRect(Rect(ARect.Left, LY, ARect.Left + 3, LY + 3));
    ACanvas.Brush.Style := bsClear;
    ACanvas.MoveTo(ARect.Left + 5, LY + 1);
    ACanvas.LineTo(ARect.Right, LY + 1);
  end;
end;

function TAefosLazTerminalControl._MakeToolButton(const ALeft: Integer;
  const AGlyph: Char; const AHint: string;
  const AOnClick: TNotifyEvent): TSpeedButton;
var
  LBtn: TSpeedButton;
  LBmp: TBitmap;
begin
  // Flat dark button (TSpeedButton honours the dark face + light glyph; a themed
  // TButton would render light on Windows -- the find-bar lesson). Owned by Self so
  // the inherited destructor frees it; parented to the toolbar.
  LBtn := TSpeedButton.Create(Self);
  LBtn.Parent := FToolbar;
  LBtn.Flat := True;
  LBtn.Left := ALeft;
  LBtn.Top := 3;
  LBtn.Width := 26;
  LBtn.Height := 24;
  LBtn.ShowHint := True;
  LBtn.Hint := AHint;
  LBtn.OnClick := AOnClick;
  // Glyph: light strokes on a fuchsia-masked bitmap. TSpeedButton treats the
  // bottom-left pixel colour as transparent, so the fuchsia field drops out and the
  // dark toolbar face (and the hover highlight) shows through around the glyph.
  LBmp := TBitmap.Create;
  try
    LBmp.SetSize(18, 18);
    // Explicit fuchsia colour-key so the drop-out is deterministic across widgetsets
    // (not left to the bottom-left-pixel default).
    LBmp.Transparent := True;
    LBmp.TransparentColor := clFuchsia;
    LBmp.Canvas.Brush.Style := bsSolid;
    LBmp.Canvas.Brush.Color := clFuchsia;
    LBmp.Canvas.FillRect(Rect(0, 0, 18, 18));
    LBmp.Canvas.Pen.Color := RGBToColor(225, 225, 225);
    LBmp.Canvas.Pen.Width := 2;
    LBmp.Canvas.Brush.Style := bsClear;
    case AGlyph of
      'A': _DrawAiGlyph(LBmp.Canvas, Rect(2, 2, 16, 16));
      'F': _DrawFindGlyph(LBmp.Canvas, Rect(2, 2, 16, 16));
      'C': _DrawActionsGlyph(LBmp.Canvas, Rect(2, 2, 16, 16));
    end;
    LBtn.Glyph.Assign(LBmp);
  finally
    LBmp.Free;
  end;
  Result := LBtn;
end;

procedure TAefosLazTerminalControl._CreateToolbar;
begin
  // A code-created child bar docked to the TOP edge (no DFM / .lpk unit). Dark
  // chrome matching the terminal so it reads as part of the surface, not a light
  // Windows strip. Its buttons are SpeedButtons (graphic controls, no TabStop), so
  // clicking them never steals keyboard focus from the typeable grid / shell.
  FToolbar := TPanel.Create(Self);
  FToolbar.Parent := Self;
  // alNone (not alTop): the bar must stop at the scrollbar's LEFT edge, not span the
  // full width over the scrollbar column. Its exact width is set by _LayoutChrome on
  // every geometry change; the anchors keep it tracking the top row + right edge
  // between those recomputes. Height stays fixed (_ToolbarHeight feeds the paint).
  FToolbar.Align := alNone;
  FToolbar.Anchors := [akLeft, akTop, akRight];
  FToolbar.Left := 0;
  FToolbar.Top := 0;
  FToolbar.BevelOuter := bvNone;
  FToolbar.BorderStyle := bsNone;
  FToolbar.Color := RGBToColor(37, 37, 38);
  FToolbar.Height := 30;
  // Give it a sane initial width before the first layout pass (avoids a 1-frame
  // full-width flash on controls that paint before CreateWnd's _ApplyGeometry).
  FToolbar.Width := ClientWidth - FScrollBar.Width;

  // Left-to-right: AI composer (the key discoverability win -- it was Ctrl+I only),
  // Find, Action Center. Each opens the SAME action its shortcut / menu already does.
  FToolAiBtn := _MakeToolButton(6, 'A',
    'AI composer (Ctrl+I) - ask the AI or shell running in this terminal',
    _ToolAiClick);
  FToolFindBtn := _MakeToolButton(38, 'F',
    'Find in the terminal output (Ctrl+F)', _ToolFindClick);
  FToolActionsBtn := _MakeToolButton(70, 'C',
    'Action Center - run a saved terminal action', _ToolActionsClick);
end;

procedure TAefosLazTerminalControl._ToolAiClick(Sender: TObject);
begin
  // Exactly the Ctrl+I action: toggle the composer bar (open + focus / close).
  _ToggleComposerBar;
end;

procedure TAefosLazTerminalControl._ToolFindClick(Sender: TObject);
begin
  // Exactly the Ctrl+F action: toggle the find bar.
  _ToggleFindBar;
end;

procedure TAefosLazTerminalControl._ToolActionsClick(Sender: TObject);
begin
  // The SAME entry the IDE "Action Center" menu item uses. The window injects the
  // chosen action into THIS terminal via ITerminalInput (this control implements it).
  TAefosLazActionCenter.Show;
end;

procedure TAefosLazTerminalControl.StartShell(const ACommand: string);
begin
  if FStarted then Exit;
  FStarted := True;
  try
    FController.Start(ACommand);
  except
    on E: Exception do
      // Surface the reason on the grid instead of raising into the IDE (e.g.
      // ConPTY unavailable on pre-1809 Windows).
      if Assigned(FBuffer) then
        FBuffer.Feed('Aefos AI Terminal: could not start shell ('
          + E.Message + ')'#13#10);
  end;
  Invalidate;
end;

function TAefosLazTerminalControl.IsActive: Boolean;
begin
  // The Delphi TTerminalHost also checks the write handle + a still-alive
  // process; the LCL controller folds that into IsRunning (the reader thread
  // clears it when the child exits), so a single IsRunning gate is enough here.
  Result := Assigned(FController) and FController.IsRunning;
end;

procedure TAefosLazTerminalControl.SendInput(const AText: string);
begin
  // The runner appends #13 to each script line, so AText already carries its
  // line terminator; forward the UTF-8 bytes verbatim (Delphi SendInput twin).
  _EmitAscii(AText);
end;

end.
