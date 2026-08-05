unit Aefos.OTA.Terminal.UI.TerminalCanvas;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes,
  System.Character,
  System.Types, System.UITypes, Vcl.Controls, Vcl.Graphics, Vcl.StdCtrls,
  Vcl.Forms, Vcl.ExtCtrls, Vcl.ClipBrd, Aefos.OTA.Terminal.Core.VTermBuffer, Aefos.OTA.Terminal.Core.CellColor,
  Aefos.OTA.Terminal.Core.MouseEncode;

type
  /// <summary>Raised when the user produces input that must reach the PTY.</summary>
  TTerminalInputEvent = procedure(Sender: TObject; const AData: string) of object;
  /// <summary>Raised when the visible grid geometry changes.</summary>
  TTerminalResizeEvent = procedure(Sender: TObject; const ACols, ARows: Integer) of object;
  /// <summary>Raised when the user requests a clipboard paste (Ctrl+V).</summary>
  TTerminalPasteEvent = procedure(Sender: TObject; const AText: string) of object;
  /// <summary>Raised when the user Ctrl+Clicks a cell carrying an OSC 8 URL
  /// (ESP-033 / ADR-033-03). The handler decides whether to dispatch — the
  /// canvas only reports the gesture; policy lives in Aefos.OTA.Terminal.Core.Hyperlink.</summary>
  TTerminalHyperlinkClickEvent = procedure(Sender: TObject;
    const AUrl: string) of object;

  /// <summary>
  /// Owner-drawn terminal surface. Renders the cell grid of a TVTermBuffer
  /// onto its Canvas, repaints only dirty rows, draws a blinking block cursor,
  /// supports scrollback via a scrollbar, text selection and clipboard copy,
  /// and encodes keyboard input into VT sequences.
  /// </summary>
  TTerminalCanvas = class(TCustomControl)
  private
    FBuffer: TVTermBuffer;
    FScrollBar: TScrollBar;
    FBlinkTimer: TTimer;
    FCellWidth: Integer;
    FCellHeight: Integer;
    FScrollOffset: Integer;
    FCursorOn: Boolean;
    FBasePalette: TBasePalette;
    FDefaultFg: TColor;
    FDefaultBg: TColor;
    FCursorColor: TColor;
    FSelecting: Boolean;
    FHasSelection: Boolean;
    FSelAnchor: TPoint;
    FSelEnd: TPoint;
    FFindLine: Integer;
    FFindCol: Integer;
    FFindLen: Integer;
    FLastMouseRow: Integer;
    FLastMouseCol: Integer;
    FLastMouseButton: Integer;
    FHoverLinkUrl: string;
    FHoverRow: Integer;
    FHoverCol: Integer;
    FOnInput: TTerminalInputEvent;
    FOnResizeRequest: TTerminalResizeEvent;
    FOnFocusChanged: TNotifyEvent;
    FOnPaste: TTerminalPasteEvent;
    FOnHyperlinkClick: TTerminalHyperlinkClickEvent;
    FOnSnippetsRequest: TNotifyEvent;
    procedure _ComputeMetrics;
    function _DrawAreaWidth: Integer;
    function _TopLine: Integer;
    function _TotalLines: Integer;
    function _LineText(const AAbsLine: Integer): string;
    function _CellOfLine(const AAbsLine, AX: Integer): TTerminalCell;
    function _IsSelected(const ACol, AAbsLine: Integer): Boolean;
    function _PixelToCell(const AX, AY: Integer): TPoint;
    procedure _BlitSixelImages;
    procedure _SyncScrollBar;
    procedure _ScrollBarChange(Sender: TObject);
    procedure _BlinkTick(Sender: TObject);
    procedure _OnBufferChange(Sender: TObject);
    function _EncodeSpecialKey(const AKey: Word; const AShift: TShiftState): string;
    function _EncodeCursorKey(const AKey: Word): string;
    function _EncodeArrowKey(const AKey: Word): string;
    function _EncodeNavKey(const AKey: Word): string;
    function _EncodeFunctionKey(const AKey: Word): string;
    function _EncodeLowFunctionKey(const AKey: Word): string;
    function _EncodeHighFunctionKey(const AKey: Word): string;
    procedure _Emit(const AData: string);
    procedure _EmitBytes(const ABytes: TBytes);
    function _MouseButtonCode(const AButton: TMouseButton): Integer;
    procedure _EmitMouseButton(const AButton: TMouseButton;
      const AShift: TShiftState; const ARow, ACol: Integer; const APressed: Boolean);
    procedure _EmitMouseMotion(const AShift: TShiftState;
      const ARow, ACol: Integer);
    procedure _EmitMouseWheel(const AShift: TShiftState;
      const ARow, ACol: Integer; const AUp: Boolean);
    procedure _ApplyGeometry;
    procedure _UpdateHoverLink(const ARow, ACol: Integer);
    procedure WMGetDlgCode(var Msg: TWMGetDlgCode); message WM_GETDLGCODE;
    procedure CMMouseLeave(var Message: TMessage); message CM_MOUSELEAVE;
  protected
    procedure CreateParams(var Params: TCreateParams); override;
    procedure CreateWnd; override;
    procedure Paint; override;
    procedure Resize; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure KeyPress(var Key: Char); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure DoEnter; override;
    procedure DoExit; override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint): Boolean; override;
  public
    constructor Create(AOwner: TComponent; ABuffer: TVTermBuffer); reintroduce;
    destructor Destroy; override;

    /// <summary>Feeds raw output into the screen buffer and queues a repaint.</summary>
    procedure Feed(const AData: string);
    /// <summary>Applies theme colors and font, recomputing cell metrics.</summary>
    procedure ApplyTheme(const APalette: TBasePalette; const AFg, ABg,
      ACursor: TColor; const AFontName: string; const AFontSize: Integer);
    /// <summary>Copies the current text selection to the clipboard.</summary>
    procedure CopySelection;
    /// <summary>Routes Ctrl+C: copy if a selection exists, otherwise send ETX
    /// to interrupt the foreground process. Exposed so the dock form's
    /// IsShortCut can call it after intercepting the IDE's global Copy.</summary>
    procedure SendCtrlC;
    /// <summary>Reads `Clipboard.AsText` and dispatches it via OnPaste. Silent
    /// no-op when the clipboard text is empty. Exposed so the dock form's
    /// IsShortCut can call it after intercepting the IDE's global Paste.</summary>
    procedure SendCtrlV;
    /// <summary>Searches the grid and scrollback; highlights and scrolls to a match.</summary>
    function FindText(const ASearch: string; const AForward,
      ACaseSensitive: Boolean): Boolean;
    /// <summary>Total occurrences of <c>ASearch</c> across the visible grid
    /// and scrollback. Used by the standalone find-bar to populate the
    /// <c>N/M</c> counter (ESP-055 / BR3). Returns 0 for empty queries.</summary>
    function CountFindMatches(const ASearch: string;
      const ACaseSensitive: Boolean): Integer;
    /// <summary>1-based index of the currently highlighted match within the
    /// scrollback-ordered match list, or 0 when there is no current match.
    /// Pairs with <see cref="CountFindMatches"/> to drive the find counter.</summary>
    function FindCurrentMatchIndex(const ASearch: string;
      const ACaseSensitive: Boolean): Integer;
    /// <summary>Number of grid columns currently displayed.</summary>
    function VisibleCols: Integer;
    /// <summary>Number of grid rows currently displayed.</summary>
    function VisibleRows: Integer;

    property Buffer: TVTermBuffer read FBuffer;
    property OnInput: TTerminalInputEvent read FOnInput write FOnInput;
    property OnResizeRequest: TTerminalResizeEvent read FOnResizeRequest write FOnResizeRequest;
    property OnFocusChanged: TNotifyEvent read FOnFocusChanged write FOnFocusChanged;
    property OnPaste: TTerminalPasteEvent read FOnPaste write FOnPaste;
    /// <summary>Fired on Ctrl+Click on a cell that holds an OSC 8 URL. The
    /// host (TerminalView) decides whether to dispatch via
    /// Aefos.OTA.Terminal.Core.Hyperlink.THyperlink.Open — the canvas only reports.</summary>
    property OnHyperlinkClick: TTerminalHyperlinkClickEvent
      read FOnHyperlinkClick write FOnHyperlinkClick;
    property OnSnippetsRequest: TNotifyEvent read FOnSnippetsRequest write FOnSnippetsRequest;
  end;

implementation

uses
  System.Math, System.StrUtils,
  Aefos.OTA.Terminal.Core.Hyperlink,
  Aefos.OTA.Terminal.Core.VisualTokens,
  Aefos.OTA.Terminal.UI.TerminalPainter;

constructor TTerminalCanvas.Create(AOwner: TComponent; ABuffer: TVTermBuffer);
begin
  inherited Create(AOwner);
  FBuffer := ABuffer;
  FBuffer.OnChange := _OnBufferChange;
  ControlStyle := ControlStyle + [csOpaque];
  DoubleBuffered := True;
  TabStop := True;
  Width := 400;
  Height := 300;
  FDefaultFg := clSilver;
  FDefaultBg := clBlack;
  // Orange Embarcadero accent cursor (ADR-057-03); ApplyTheme later refines it
  // through the dark/light fallback resolver.
  FCursorColor := TVisualTokens.ResolveCursorColor(FDefaultBg);
  FCursorOn := True;
  FFindLen := 0;
  FFindLine := -1;
  FLastMouseRow := -1;
  FLastMouseCol := -1;
  FLastMouseButton := -1;
  FHoverLinkUrl := '';
  FHoverRow := -1;
  FHoverCol := -1;
  Font.Name := 'Consolas';
  Font.Size := 10;

  FScrollBar := TScrollBar.Create(Self);
  FScrollBar.Parent := Self;
  FScrollBar.Kind := sbVertical;
  FScrollBar.Align := alRight;
  FScrollBar.OnChange := _ScrollBarChange;
  FScrollBar.TabStop := False;

  FBlinkTimer := TTimer.Create(Self);
  FBlinkTimer.Interval := 530;
  FBlinkTimer.OnTimer := _BlinkTick;
  FBlinkTimer.Enabled := True;

  _ComputeMetrics;
end;

destructor TTerminalCanvas.Destroy;
begin
  if Assigned(FBuffer) then
    FBuffer.OnChange := nil;
  inherited Destroy;
end;

procedure TTerminalCanvas.CreateParams(var Params: TCreateParams);
begin
  inherited CreateParams(Params);
  Params.WindowClass.style := Params.WindowClass.style or CS_DBLCLKS;
  Params.Style := Params.Style or WS_CLIPCHILDREN;
end;

procedure TTerminalCanvas.WMGetDlgCode(var Msg: TWMGetDlgCode);
begin
  inherited;
  Msg.Result := DLGC_WANTARROWS or DLGC_WANTCHARS or DLGC_WANTTAB;
end;

procedure TTerminalCanvas.CreateWnd;
begin
  inherited CreateWnd;
  // The window now exists. The constructor and ApplyTheme run before the
  // handle and fall back to 8x14 cell defaults; recompute metrics from the
  // real font and resize the buffer/pseudoconsole so the grid size matches
  // what is actually painted (otherwise full-screen apps such as vim are
  // told a wrong row count and render into the wrong area).
  _ComputeMetrics;
  if Assigned(FBuffer) then
    _ApplyGeometry;
end;

procedure TTerminalCanvas._ComputeMetrics;
begin
  // Fall back to sane defaults until a window handle exists (e.g. headless).
  FCellWidth := 8;
  FCellHeight := 14;
  if not HandleAllocated then Exit;
  Canvas.Font := Font;
  FCellWidth := Canvas.TextWidth('W');
  FCellHeight := Canvas.TextHeight('Wg');
  if FCellWidth < 1 then FCellWidth := 8;
  if FCellHeight < 1 then FCellHeight := 14;
end;

function TTerminalCanvas._DrawAreaWidth: Integer;
begin
  Result := ClientWidth - FScrollBar.Width;
  if Result < FCellWidth then
    Result := FCellWidth;
end;

function TTerminalCanvas.VisibleCols: Integer;
begin
  Result := Max(1, _DrawAreaWidth div FCellWidth);
end;

function TTerminalCanvas.VisibleRows: Integer;
begin
  Result := Max(1, ClientHeight div FCellHeight);
end;

function TTerminalCanvas._TotalLines: Integer;
begin
  Result := FBuffer.ScrollbackCount + FBuffer.Rows;
end;

function TTerminalCanvas._TopLine: Integer;
begin
  Result := FBuffer.ScrollbackCount - FScrollOffset;
  if Result < 0 then
    Result := 0;
end;

function TTerminalCanvas._CellOfLine(const AAbsLine, AX: Integer): TTerminalCell;
begin
  if AAbsLine < FBuffer.ScrollbackCount then
    Result := FBuffer.ScrollbackCell(AAbsLine, AX)
  else
    Result := FBuffer.Cell(AX, AAbsLine - FBuffer.ScrollbackCount);
end;

function TTerminalCanvas._LineText(const AAbsLine: Integer): string;
var
  LX: Integer;
  LBuilder: TStringBuilder;
begin
  LBuilder := TStringBuilder.Create;
  try
    for LX := 0 to FBuffer.Cols - 1 do
      // Same skip the row-text builder makes: a column covered by a wide glyph
      // owns no text, so copying one must not yield a trailing space.
      if caWideGap in _CellOfLine(AAbsLine, LX).Attrs then
        Continue
      else
      // GlyphText yields the cell's UTF-16 text, so the selection/copy buffer
      // carries the real glyph (never the decimal codepoint an Append(Cardinal)
      // overload would have produced) -- and, like the painter, it cannot raise
      // on a cell that is not a Unicode scalar. Copying a line that contained a
      // double-width glyph used to throw here for the same reason painting did.
      LBuilder.Append(_CellOfLine(AAbsLine, LX).GlyphText);
    Result := LBuilder.ToString;
  finally
    LBuilder.Free;
  end;
end;

function TTerminalCanvas._IsSelected(const ACol, AAbsLine: Integer): Boolean;
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
  LKey := Int64(AAbsLine) * 100000 + ACol;
  LStartKey := Int64(LStart.Y) * 100000 + LStart.X;
  LEndKey := Int64(LEnd.Y) * 100000 + LEnd.X;
  Result := (LKey >= LStartKey) and (LKey < LEndKey);
end;

procedure TTerminalCanvas.Paint;
var
  LSnap: TTerminalSnapshot;
begin
  LSnap.CellWidth    := FCellWidth;
  LSnap.CellHeight   := FCellHeight;
  LSnap.DrawAreaWidth := _DrawAreaWidth;
  LSnap.ClientHeight := ClientHeight;
  LSnap.VisibleRows  := VisibleRows;
  LSnap.VisibleCols  := VisibleCols;
  LSnap.DefaultFg    := FDefaultFg;
  LSnap.DefaultBg    := FDefaultBg;
  LSnap.CursorColor  := FCursorColor;
  LSnap.BasePalette  := FBasePalette;
  LSnap.Buffer       := FBuffer;
  LSnap.ScrollOffset := FScrollOffset;
  LSnap.HasSelection := FHasSelection;
  LSnap.SelAnchor    := FSelAnchor;
  LSnap.SelEnd       := FSelEnd;
  LSnap.FindLine     := FFindLine;
  LSnap.FindCol      := FFindCol;
  LSnap.FindLen      := FFindLen;
  LSnap.HoverLinkUrl := FHoverLinkUrl;
  LSnap.HoverRow     := FHoverRow;
  LSnap.HoverCol     := FHoverCol;
  LSnap.CursorOn     := FCursorOn;
  LSnap.Focused      := Focused;
  LSnap.CursorShape  := TVisualTokens.DefaultCursorShape;
  LSnap.FontName     := Font.Name;
  LSnap.FontSize     := Font.Size;
  TTerminalPainter.Paint(Canvas, LSnap);
  _BlitSixelImages;
  FBuffer.ClearDirty;
end;

procedure TTerminalCanvas._BlitSixelImages;
// Paints each stored Sixel placement after the text rows have been drawn.
// Anchor coordinates are buffer-grid (row/col); convert to pixel space by
// scaling by FCellHeight/FCellWidth, then offset for scrollback so a
// scrolled-back viewport keeps images at their logical row. Placements
// fully above or below the visible region are skipped. ESP-035 / ADR-035-03.
var
  LPlacements: TArray<TSixelPlacement>;
  LFor: Integer;
  LPxX, LPxY: Integer;
  LBitmap: TBitmap;
  LRow: Integer;
  LSrc, LDest: PByte;
begin
  if FBuffer = nil then Exit;
  LPlacements := FBuffer.GetSixelImages;
  if Length(LPlacements) = 0 then Exit;
  for LFor := 0 to High(LPlacements) do
  begin
    if (LPlacements[LFor].Width <= 0) or (LPlacements[LFor].Height <= 0) then
      Continue;
    LPxX := LPlacements[LFor].AnchorCol * FCellWidth;
    LPxY := (LPlacements[LFor].AnchorRow + FBuffer.ScrollbackCount -
      _TopLine) * FCellHeight;
    if LPxY + LPlacements[LFor].Height < 0 then Continue;
    if LPxY > Height then Continue;
    LBitmap := TBitmap.Create;
    try
      LBitmap.PixelFormat := pf32bit;
      LBitmap.AlphaFormat := afPremultiplied;
      LBitmap.SetSize(LPlacements[LFor].Width, LPlacements[LFor].Height);
      for LRow := 0 to LPlacements[LFor].Height - 1 do
      begin
        LSrc := @LPlacements[LFor].Pixels[LRow * LPlacements[LFor].Width * 4];
        LDest := LBitmap.ScanLine[LRow];
        Move(LSrc^, LDest^, LPlacements[LFor].Width * 4);
      end;
      Canvas.Draw(LPxX, LPxY, LBitmap);
    finally
      LBitmap.Free;
    end;
  end;
end;

procedure TTerminalCanvas._ApplyGeometry;
var
  LCols, LRows: Integer;
begin
  // Querying the client rect forces handle creation; defer geometry until
  // the control is realized (the first real Resize re-applies it).
  if not HandleAllocated then Exit;
  LCols := VisibleCols;
  LRows := VisibleRows;
  
  // Safety guard: prevents destructive buffer/PTY resize when the panel is
  // temporarily shrunk (e.g. while dragging, docking or hiding tabs in the IDE).
  if (LCols < 15) or (LRows < 3) then Exit;

  if (LCols <> FBuffer.Cols) or (LRows <> FBuffer.Rows) then
  begin
    FBuffer.Resize(LCols, LRows);
    if Assigned(FOnResizeRequest) then
      FOnResizeRequest(Self, LCols, LRows);
  end;
  _SyncScrollBar;
end;

procedure TTerminalCanvas.Resize;
begin
  inherited Resize;
  if (FCellWidth > 0) and Assigned(FBuffer) then
    _ApplyGeometry;
  Invalidate;
end;

procedure TTerminalCanvas._SyncScrollBar;
var
  LMax: Integer;
begin
  // Touching the scrollbar position forces handle creation; skip when the
  // control is not yet realized (e.g. the headless test runner).
  if not HandleAllocated then Exit;
  LMax := Max(0, FBuffer.ScrollbackCount);
  // TScrollBar.SetParams raises EInvalidOperation when Max < PageSize. Clear
  // PageSize before shrinking the range so an empty scrollback (Max = 0 after
  // cls/clear or on a fresh pane) cannot violate that invariant on resize,
  // blink-tick or screen-clear syncs.
  FScrollBar.PageSize := 0;
  FScrollBar.Min := 0;
  FScrollBar.Max := LMax;
  if LMax > 0 then
    FScrollBar.PageSize := 1;
  FScrollBar.Position := FScrollBar.Max - FScrollOffset;
end;

procedure TTerminalCanvas._ScrollBarChange(Sender: TObject);
begin
  FScrollOffset := FScrollBar.Max - FScrollBar.Position;
  if FScrollOffset < 0 then
    FScrollOffset := 0;
  Invalidate;
end;

procedure TTerminalCanvas._BlinkTick(Sender: TObject);
begin
  FCursorOn := not FCursorOn;
  if Focused then
    Invalidate;
end;

procedure TTerminalCanvas._OnBufferChange(Sender: TObject);
begin
  // TVTermBuffer fires OnChange synchronously from FeedBytes/Resize, both of
  // which already run on the UI thread (the reader thread feeds the buffer
  // via TThread.Synchronize). Repaint directly. A TThread.ForceQueue closure
  // was used here to "marshal to the UI thread", but it captured Self and
  // could outlive the canvas: when the pane or the IDE closed before the
  // queue drained, the closure faulted on a dangling Self — the csDestroying
  // guard cannot help once the object has already been freed.
  if csDestroying in ComponentState then Exit;
  _SyncScrollBar;
  Invalidate;
end;

procedure TTerminalCanvas.Feed(const AData: string);
begin
  FBuffer.Feed(AData);
end;

procedure TTerminalCanvas.ApplyTheme(const APalette: TBasePalette;
  const AFg, ABg, ACursor: TColor; const AFontName: string;
  const AFontSize: Integer);
begin
  FBasePalette := APalette;
  FDefaultFg := AFg;
  FDefaultBg := ABg;
  FCursorColor := ACursor;
  Color := ABg;
  Font.Name := AFontName;
  Font.Size := AFontSize;
  _ComputeMetrics;
  if Assigned(FBuffer) then
    _ApplyGeometry;
  Invalidate;
end;

procedure TTerminalCanvas._Emit(const AData: string);
begin
  if (AData <> '') and Assigned(FOnInput) then
    FOnInput(Self, AData);
end;

procedure TTerminalCanvas._EmitBytes(const ABytes: TBytes);
var
  LIndex: Integer;
  LStr: string;
begin
  // Mouse CSI sequences are mostly 7-bit ASCII (always for SGR/?1006, and for
  // X10 inside the typical 80x25 cell range). High bytes only occur for X10
  // with col/row > ~95; modern apps default to SGR (see ESP-032 Out of scope).
  if Length(ABytes) = 0 then Exit;
  SetLength(LStr, Length(ABytes));
  for LIndex := 0 to High(ABytes) do
    LStr[LIndex + 1] := Char(ABytes[LIndex]);
  _Emit(LStr);
end;

function TTerminalCanvas._MouseButtonCode(const AButton: TMouseButton): Integer;
begin
  // VCL: TMouseButton = (mbLeft, mbRight, mbMiddle).
  // xterm Cb: 0 = left, 1 = middle, 2 = right.
  case AButton of
    mbLeft:   Result := 0;
    mbMiddle: Result := 1;
    mbRight:  Result := 2;
  else
    Result := 0;
  end;
end;

procedure TTerminalCanvas._EmitMouseButton(const AButton: TMouseButton;
  const AShift: TShiftState; const ARow, ACol: Integer; const APressed: Boolean);
var
  LCode, LMod: Integer;
begin
  if APressed then
  begin
    LCode := _MouseButtonCode(AButton);
    FLastMouseButton := LCode;
    FLastMouseRow := ARow;
    FLastMouseCol := ACol;
  end
  else
  begin
    // SGR carries the original press button on release. X10 ignores it
    // (the encoder substitutes the constant 3); keep the tracked code so SGR
    // emits the right Cb either way.
    if FLastMouseButton >= 0 then
      LCode := FLastMouseButton
    else
      LCode := _MouseButtonCode(AButton);
    FLastMouseButton := -1;
  end;
  LMod := TMouseEncoder.ShiftStateToVTermMod(AShift);
  _EmitBytes(TMouseEncoder.EncodeMouseEvent(LCode, ARow, ACol, LMod, APressed, False,
    FBuffer.MouseSgrEnabled));
end;

procedure TTerminalCanvas._EmitMouseMotion(const AShift: TShiftState;
  const ARow, ACol: Integer);
var
  LCode, LMod: Integer;
begin
  // libvterm mouse levels: 1 = X10/click only (never reports motion);
  // 2 = button-event (motion only while a button is held); 3 = any-event.
  case FBuffer.MouseLevel of
    1: Exit;
    2: if FLastMouseButton < 0 then Exit;
  end;
  if not TMouseEncoder.ShouldEmitMotion(FLastMouseRow, FLastMouseCol, ARow, ACol) then
    Exit;
  FLastMouseRow := ARow;
  FLastMouseCol := ACol;
  if FLastMouseButton >= 0 then
    LCode := FLastMouseButton
  else
    LCode := 3; // No button held: report code 3 (the xterm "no-button" idiom).
  LMod := TMouseEncoder.ShiftStateToVTermMod(AShift);
  _EmitBytes(TMouseEncoder.EncodeMouseEvent(LCode, ARow, ACol, LMod, True, True,
    FBuffer.MouseSgrEnabled));
end;

procedure TTerminalCanvas._EmitMouseWheel(const AShift: TShiftState;
  const ARow, ACol: Integer; const AUp: Boolean);
var
  LButton, LMod: Integer;
begin
  // Wheel events: xterm button 64 = up, 65 = down. Press-only — no release
  // event is sent (xterm convention).
  if AUp then
    LButton := 64
  else
    LButton := 65;
  LMod := TMouseEncoder.ShiftStateToVTermMod(AShift);
  _EmitBytes(TMouseEncoder.EncodeMouseEvent(LButton, ARow, ACol, LMod, True, False,
    FBuffer.MouseSgrEnabled));
end;

function TTerminalCanvas._EncodeSpecialKey(const AKey: Word;
  const AShift: TShiftState): string;
begin
  case AKey of
    VK_UP, VK_DOWN, VK_LEFT, VK_RIGHT,
    VK_HOME, VK_END, VK_PRIOR, VK_NEXT, VK_INSERT, VK_DELETE:
      Result := _EncodeCursorKey(AKey);
    VK_F1..VK_F12:
      Result := _EncodeFunctionKey(AKey);
  else
    Result := '';
  end;
end;

function TTerminalCanvas._EncodeCursorKey(const AKey: Word): string;
begin
  case AKey of
    VK_UP, VK_DOWN, VK_LEFT, VK_RIGHT: Result := _EncodeArrowKey(AKey);
  else
    Result := _EncodeNavKey(AKey);
  end;
end;

function TTerminalCanvas._EncodeArrowKey(const AKey: Word): string;
begin
  case AKey of
    VK_UP: Result := #27'[A';
    VK_DOWN: Result := #27'[B';
    VK_RIGHT: Result := #27'[C';
    VK_LEFT: Result := #27'[D';
  else
    Result := '';
  end;
end;

function TTerminalCanvas._EncodeNavKey(const AKey: Word): string;
begin
  case AKey of
    VK_HOME: Result := #27'[H';
    VK_END: Result := #27'[F';
    VK_PRIOR: Result := #27'[5~';
    VK_NEXT: Result := #27'[6~';
    VK_INSERT: Result := #27'[2~';
    VK_DELETE: Result := #27'[3~';
  else
    Result := '';
  end;
end;

function TTerminalCanvas._EncodeFunctionKey(const AKey: Word): string;
begin
  if AKey <= VK_F4 then
    Result := _EncodeLowFunctionKey(AKey)
  else
    Result := _EncodeHighFunctionKey(AKey);
end;

function TTerminalCanvas._EncodeLowFunctionKey(const AKey: Word): string;
begin
  case AKey of
    VK_F1: Result := #27'OP';
    VK_F2: Result := #27'OQ';
    VK_F3: Result := #27'OR';
    VK_F4: Result := #27'OS';
  else
    Result := '';
  end;
end;

function TTerminalCanvas._EncodeHighFunctionKey(const AKey: Word): string;
begin
  case AKey of
    VK_F5: Result := #27'[15~';
    VK_F6: Result := #27'[17~';
    VK_F7: Result := #27'[18~';
    VK_F8: Result := #27'[19~';
    VK_F9: Result := #27'[20~';
    VK_F10: Result := #27'[21~';
    VK_F11: Result := #27'[23~';
    VK_F12: Result := #27'[24~';
  else
    Result := '';
  end;
end;

procedure TTerminalCanvas.KeyDown(var Key: Word; Shift: TShiftState);
var
  LSeq: string;
begin
  if (Key = Ord('C')) and (ssCtrl in Shift) then
  begin
    // Ctrl+C: copy when a selection exists, otherwise send ETX (#3) to
    // interrupt the foreground process. The dock form's IsShortCut normally
    // routes Ctrl+C here before the IDE's global Copy can fire; this branch
    // is the fallback when the shortcut is not intercepted.
    SendCtrlC;
    Key := 0;
    Exit;
  end;
  if (Key = Ord('V')) and (ssCtrl in Shift) and not (ssShift in Shift) and
     not (ssAlt in Shift) then
  begin
    // Ctrl+V: read the system clipboard and dispatch the paste through
    // OnPaste. The dock form's IsShortCut routes Ctrl+V here before the
    // IDE's global Paste can fire; this branch is the fallback. Plain Ctrl+V
    // only — Ctrl+Shift+V and other modifiers fall through to _EncodeSpecialKey.
    SendCtrlV;
    FScrollOffset := 0;
    Key := 0;
    Exit;
  end;
  LSeq := _EncodeSpecialKey(Key, Shift);
  if LSeq <> '' then
  begin
    FScrollOffset := 0;
    _Emit(LSeq);
    Key := 0;
    Exit;
  end;
  inherited KeyDown(Key, Shift);
end;

procedure TTerminalCanvas.KeyPress(var Key: Char);
begin
  if Key = #8 then
    _Emit(#127)
  else
    _Emit(Key);
  FScrollOffset := 0;
  Key := #0;
end;

function TTerminalCanvas._PixelToCell(const AX, AY: Integer): TPoint;
begin
  Result.X := AX div FCellWidth;
  if Result.X < 0 then Result.X := 0;
  if Result.X > FBuffer.Cols then Result.X := FBuffer.Cols;
  Result.Y := _TopLine + (AY div FCellHeight);
end;

procedure TTerminalCanvas.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
// MouseDown precedence (ESP-033 / ADR-033-03 BR5, ESP-032 ADR-032-02):
//   1. Ctrl + left-click on a linked cell → fire OnHyperlinkClick, return.
//   2. Shift held → selection path (Shift forces selection over reporting).
//   3. TMouseEncoder.ShouldRouteToBuffer → mouse reporting (E3.D1).
//   4. Otherwise → start a text selection.
// The Ctrl branch is FIRST so a hyperlink open beats both selection and
// mouse reporting; order matters and must not be reordered by future edits.
var
  LCell: TPoint;
  LViewRow: Integer;
  LHoverViewRow: Integer;
  LUrl: string;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if CanFocus then
    SetFocus;
  LCell := _PixelToCell(X, Y);
  LHoverViewRow := Y div FCellHeight;
  if LHoverViewRow < 0 then LHoverViewRow := 0;
  LUrl := FBuffer.GetLinkAt(LCell.X, LHoverViewRow);
  // ADR-056-03 (H-2/H-7): THyperlink.ShouldDispatchOnLeftClick is the single
  // pure decision for "Ctrl+Click on a linked cell". Plain left-click falls
  // through to selection; Ctrl+Click on an unlinked cell falls through to
  // mouse reporting / selection. Test-covered headlessly.
  if THyperlink.ShouldDispatchOnLeftClick(
      Button = mbLeft, ssCtrl in Shift, LUrl) then
  begin
    if Assigned(FOnHyperlinkClick) then
      FOnHyperlinkClick(Self, LUrl);
    Exit;
  end;
  if TMouseEncoder.ShouldRouteToBuffer(FBuffer.MouseLevel, Shift) then
  begin
    // Reporting mode: forward press to the program. Use viewport-relative row
    // (the program addresses the visible grid, not absolute scrollback lines).
    LViewRow := Y div FCellHeight;
    if LViewRow < 0 then LViewRow := 0;
    _EmitMouseButton(Button, Shift, LViewRow, LCell.X, True);
    Exit;
  end;
  if Button = mbLeft then
  begin
    FSelecting := True;
    FHasSelection := False;
    FSelAnchor := LCell;
    FSelEnd := FSelAnchor;
    Invalidate;
  end;
end;

procedure TTerminalCanvas.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  LCell: TPoint;
  LViewRow: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  if TMouseEncoder.ShouldRouteToBuffer(FBuffer.MouseLevel, Shift) then
  begin
    LCell := _PixelToCell(X, Y);
    LViewRow := Y div FCellHeight;
    if LViewRow < 0 then LViewRow := 0;
    _EmitMouseMotion(Shift, LViewRow, LCell.X);
    _UpdateHoverLink(_TopLine + LViewRow, LCell.X);
    Exit;
  end;
  if FSelecting then
  begin
    FSelEnd := _PixelToCell(X, Y);
    FHasSelection := (FSelEnd.X <> FSelAnchor.X) or (FSelEnd.Y <> FSelAnchor.Y);
    Invalidate;
  end;
  LCell := _PixelToCell(X, Y);
  LViewRow := Y div FCellHeight;
  if LViewRow < 0 then LViewRow := 0;
  _UpdateHoverLink(_TopLine + LViewRow, LCell.X);
end;

procedure TTerminalCanvas.CMMouseLeave(var Message: TMessage);
begin
  // ADR-056-03 (H-1): clear hover state when the mouse leaves the canvas so
  // crHandPoint does not stay stuck and the underline overlay vanishes.
  inherited;
  if (FHoverLinkUrl = '') and (FHoverRow = -1) and (FHoverCol = -1) then Exit;
  FHoverLinkUrl := '';
  FHoverRow := -1;
  FHoverCol := -1;
  Cursor := crDefault;
  Invalidate;
end;

procedure TTerminalCanvas._UpdateHoverLink(const ARow, ACol: Integer);
// Recomputes the hovered URL from the buffer and swaps the cursor to a
// hand when non-empty. Hover state is purely visual — no PTY traffic.
// Per ESP-033 / BR3 the underline reflects the program's intent even when
// the URL fails the policy gate; only the click path is gated.
var
  LUrl: string;
  LScrollback, LBufRow: Integer;
begin
  LUrl := '';
  LScrollback := FBuffer.ScrollbackCount;
  LBufRow := ARow - LScrollback;
  if (LBufRow >= 0) and (LBufRow < FBuffer.Rows) then
    LUrl := FBuffer.GetLinkAt(ACol, LBufRow);
  if (LUrl = FHoverLinkUrl) and (ARow = FHoverRow) and (ACol = FHoverCol) then
    Exit;
  FHoverLinkUrl := LUrl;
  FHoverRow := ARow;
  FHoverCol := ACol;
  if LUrl <> '' then
    Cursor := crHandPoint
  else
    Cursor := crDefault;
  Invalidate;
end;

procedure TTerminalCanvas.MouseUp(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  LCell: TPoint;
  LViewRow: Integer;
begin
  inherited MouseUp(Button, Shift, X, Y);
  if TMouseEncoder.ShouldRouteToBuffer(FBuffer.MouseLevel, Shift) then
  begin
    LCell := _PixelToCell(X, Y);
    LViewRow := Y div FCellHeight;
    if LViewRow < 0 then LViewRow := 0;
    _EmitMouseButton(Button, Shift, LViewRow, LCell.X, False);
    Exit;
  end;
  FSelecting := False;
end;

function TTerminalCanvas.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
  MousePos: TPoint): Boolean;
var
  LClient: TPoint;
  LCell: TPoint;
  LViewRow: Integer;
begin
  if TMouseEncoder.ShouldRouteToBuffer(FBuffer.MouseLevel, Shift) then
  begin
    // MousePos is in screen coords (per VCL contract); convert before mapping.
    LClient := ScreenToClient(MousePos);
    LCell := _PixelToCell(LClient.X, LClient.Y);
    LViewRow := LClient.Y div FCellHeight;
    if LViewRow < 0 then LViewRow := 0;
    _EmitMouseWheel(Shift, LViewRow, LCell.X, WheelDelta > 0);
    Exit(True);
  end;
  if WheelDelta > 0 then
    FScrollOffset := Min(FScrollOffset + 3, FBuffer.ScrollbackCount)
  else
    FScrollOffset := Max(FScrollOffset - 3, 0);
  _SyncScrollBar;
  Invalidate;
  Result := True;
end;

procedure TTerminalCanvas.DoEnter;
begin
  inherited DoEnter;
  FCursorOn := True;
  Invalidate;
  if Assigned(FOnFocusChanged) then
    FOnFocusChanged(Self);
end;

procedure TTerminalCanvas.DoExit;
begin
  inherited DoExit;
  Invalidate;
  if Assigned(FOnFocusChanged) then
    FOnFocusChanged(Self);
end;

procedure TTerminalCanvas.SendCtrlC;
begin
  if FHasSelection then
    CopySelection
  else
    _Emit(#3);
end;

procedure TTerminalCanvas.SendCtrlV;
var
  LText: string;
begin
  if not Assigned(FOnPaste) then Exit;
  // Clipboard.AsText returns the empty string for non-text formats and for an
  // empty clipboard. Both cases are silent no-ops per ESP-026 AC4.
  LText := Clipboard.AsText;
  if LText = '' then Exit;
  FOnPaste(Self, LText);
end;

procedure TTerminalCanvas.CopySelection;
var
  LStart, LEnd, LLine, LCol, LFrom, LTo: Integer;
  LBuilder: TStringBuilder;
  LText: string;
begin
  if not FHasSelection then Exit;
  if FSelAnchor.Y * 100000 + FSelAnchor.X <= FSelEnd.Y * 100000 + FSelEnd.X then
  begin
    LStart := FSelAnchor.Y; LEnd := FSelEnd.Y;
  end
  else
  begin
    LStart := FSelEnd.Y; LEnd := FSelAnchor.Y;
  end;
  LBuilder := TStringBuilder.Create;
  try
    for LLine := LStart to LEnd do
    begin
      LText := _LineText(LLine);
      LFrom := 0;
      LTo := FBuffer.Cols - 1;
      for LCol := 0 to FBuffer.Cols - 1 do
        if _IsSelected(LCol, LLine) then
        begin
          LFrom := LCol;
          Break;
        end;
      LBuilder.AppendLine(TrimRight(Copy(LText, LFrom + 1, LTo - LFrom + 1)));
    end;
    Clipboard.AsText := LBuilder.ToString;
  finally
    LBuilder.Free;
  end;
end;

function TTerminalCanvas.FindText(const ASearch: string; const AForward,
  ACaseSensitive: Boolean): Boolean;
var
  LLine, LPos, LStartLine: Integer;
  LHaystack, LNeedle, LText: string;
begin
  Result := False;
  if ASearch = '' then Exit;
  if ACaseSensitive then
    LNeedle := ASearch
  else
    LNeedle := ASearch.ToLower;

  LStartLine := FFindLine;
  for LLine := 0 to _TotalLines - 1 do
  begin
    if AForward then
      LText := _LineText((LStartLine + 1 + LLine) mod _TotalLines)
    else
      LText := _LineText(((LStartLine - 1 - LLine) mod _TotalLines +
        _TotalLines) mod _TotalLines);
    if ACaseSensitive then
      LHaystack := LText
    else
      LHaystack := LText.ToLower;
    LPos := Pos(LNeedle, LHaystack);
    if LPos > 0 then
    begin
      if AForward then
        FFindLine := (LStartLine + 1 + LLine) mod _TotalLines
      else
        FFindLine := ((LStartLine - 1 - LLine) mod _TotalLines +
          _TotalLines) mod _TotalLines;
      FFindCol := LPos - 1;
      FFindLen := Length(ASearch);
      FScrollOffset := Max(0, FBuffer.ScrollbackCount - FFindLine);
      _SyncScrollBar;
      Invalidate;
      Exit(True);
    end;
  end;
end;

function TTerminalCanvas.CountFindMatches(const ASearch: string;
  const ACaseSensitive: Boolean): Integer;
var
  LLine, LStart: Integer;
  LHaystack, LNeedle, LText: string;
begin
  Result := 0;
  if ASearch = '' then Exit;
  if ACaseSensitive then
    LNeedle := ASearch
  else
    LNeedle := ASearch.ToLower;
  for LLine := 0 to _TotalLines - 1 do
  begin
    LText := _LineText(LLine);
    if ACaseSensitive then
      LHaystack := LText
    else
      LHaystack := LText.ToLower;
    LStart := 1;
    while True do
    begin
      LStart := PosEx(LNeedle, LHaystack, LStart);
      if LStart <= 0 then Break;
      Inc(Result);
      Inc(LStart, Max(1, Length(LNeedle)));
    end;
  end;
end;

function TTerminalCanvas.FindCurrentMatchIndex(const ASearch: string; // NOSONAR: linear scrollback scan; branch count is inherent to match-index counting (pre-existing E6.D2)
  const ACaseSensitive: Boolean): Integer;
var
  LLine, LStart: Integer;
  LHaystack, LNeedle, LText: string;
  LIndex: Integer;
begin
  Result := 0;
  if (ASearch = '') or (FFindLen = 0) or (FFindLine < 0) then Exit;
  if ACaseSensitive then
    LNeedle := ASearch
  else
    LNeedle := ASearch.ToLower;
  LIndex := 0;
  for LLine := 0 to _TotalLines - 1 do
  begin
    LText := _LineText(LLine);
    if ACaseSensitive then
      LHaystack := LText
    else
      LHaystack := LText.ToLower;
    LStart := 1;
    while True do
    begin
      LStart := PosEx(LNeedle, LHaystack, LStart);
      if LStart <= 0 then Break;
      Inc(LIndex);
      if (LLine = FFindLine) and (LStart - 1 = FFindCol) then
        Exit(LIndex);
      Inc(LStart, Max(1, Length(LNeedle)));
    end;
  end;
end;

end.


