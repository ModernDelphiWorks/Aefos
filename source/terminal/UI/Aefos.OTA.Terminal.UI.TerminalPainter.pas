unit Aefos.OTA.Terminal.UI.TerminalPainter;

/// <summary>
/// IDE-free terminal canvas painter (ESP-067 / ADR-067-01).
///
/// Provides <c>TTerminalSnapshot</c> (the full read-set of the terminal paint)
/// and <c>TTerminalPainter.Paint</c> (the extracted production paint logic).
/// The painter depends only on Vcl.Graphics, System types, and Core terminal
/// units — no ToolsAPI, no StyleServices, no TTerminalCanvas. It draws into
/// any TCanvas, including an offscreen TBitmap.Canvas.
/// </summary>

interface

uses
  System.Types, System.UITypes, System.Character,
  Vcl.Graphics,
  Aefos.OTA.Terminal.Core.CellColor,
  Aefos.OTA.Terminal.Core.VTermBuffer,
  Aefos.OTA.Terminal.Core.VisualTokens;

type
  /// <summary>
  /// Complete read-set of <c>TTerminalCanvas.Paint</c> captured as a value
  /// snapshot. Build from canvas instance fields and pass to
  /// <c>TTerminalPainter.Paint</c> to reproduce the exact pixel output against
  /// any <c>TCanvas</c> (ADR-067-01 / BR1).
  /// </summary>
  TTerminalSnapshot = record
    // Grid metrics
    CellWidth: Integer;
    CellHeight: Integer;
    DrawAreaWidth: Integer;
    ClientHeight: Integer;
    VisibleRows: Integer;
    VisibleCols: Integer;
    // Colors
    DefaultFg: TColor;
    DefaultBg: TColor;
    CursorColor: TColor;
    BasePalette: TBasePalette;
    // Buffer reference (not owned — canvas lifetime manages it)
    Buffer: TVTermBuffer;
    // Scroll
    ScrollOffset: Integer;
    // Selection
    HasSelection: Boolean;
    SelAnchor: TPoint;
    SelEnd: TPoint;
    // Find highlight
    FindLine: Integer;
    FindCol: Integer;
    FindLen: Integer;
    // Hover link
    HoverLinkUrl: string;
    HoverRow: Integer;
    HoverCol: Integer;
    // Cursor blink / focus
    CursorOn: Boolean;
    Focused: Boolean;
    CursorShape: TCursorShape;
    // Font (frozen for offscreen rendering)
    FontName: string;
    FontSize: Integer;
  end;

  /// <summary>
  /// Stateless painter that reproduces the owner-draw terminal surface against
  /// any <c>TCanvas</c>. Receives all required state through
  /// <c>TTerminalSnapshot</c> so no running IDE or <c>TTerminalCanvas</c>
  /// instance is needed (ADR-067-01 / BR2).
  /// </summary>
  TTerminalPainter = class
  private
    /// <summary>Geometric renderer for the Unicode block-element range
    /// (U+2580..U+259F: half/quadrant/eighth/shade/full blocks). Fills the
    /// appropriate sub-rectangle(s) of ARect with AFg so terminal block art
    /// (e.g. the Claude Code welcome robot) tiles seamlessly with no font gaps.
    /// Returns True when ACodepoint was in range and handled (caller then skips
    /// the TextOut glyph path); False leaves the cell to the font. Box-drawing
    /// (U+2500..U+257F) is deliberately left on the font path.</summary>
    class function _TryDrawBlockElement(const ACanvas: TCanvas;
      const ARect: TRect; const ACodepoint: Cardinal;
      const AFg, ABg: TColor): Boolean; static;
    class procedure _PaintRow(const ACanvas: TCanvas;
      const ASnapshot: TTerminalSnapshot; const AViewRow: Integer); static;
    { ASpan is how many COLUMNS this cell owns: 1 normally, 2 for a
      double-width glyph. The wide cell paints both its own column and the
      covered one -- background included -- because the covered column is never
      drawn on its own. Drawing it separately is what clipped the right half of
      every emoji: its FillRect ran after the glyph and erased the overflow. }
    class procedure _DrawCell(const ACanvas: TCanvas;
      const ASnapshot: TTerminalSnapshot;
      const AX, AViewRow, AAbsLine: Integer;
      const ACell: TTerminalCell; const ASpan: Integer); static;
    class procedure _DrawCursor(const ACanvas: TCanvas;
      const ASnapshot: TTerminalSnapshot); static;
  public
    /// <summary>
    /// Renders the terminal grid (padding strips + rows + cursor) onto
    /// <c>ACanvas</c> using the state captured in <c>ASnapshot</c>.
    /// Pixel output is identical to <c>TTerminalCanvas.Paint</c> before the
    /// extraction (ADR-067-01 / BR1). <c>_BlitSixelImages</c> and
    /// <c>FBuffer.ClearDirty</c> remain on the caller side.
    /// </summary>
    class procedure Paint(const ACanvas: TCanvas;
      const ASnapshot: TTerminalSnapshot); static;
  end;

implementation

// ---------------------------------------------------------------------------
// File-scope helpers (private to this unit)
// ---------------------------------------------------------------------------

function _TopLine(const ASnapshot: TTerminalSnapshot): Integer;
begin
  Result := ASnapshot.Buffer.ScrollbackCount - ASnapshot.ScrollOffset;
  if Result < 0 then
    Result := 0;
end;

function _TotalLines(const ASnapshot: TTerminalSnapshot): Integer;
begin
  Result := ASnapshot.Buffer.ScrollbackCount + ASnapshot.Buffer.Rows;
end;

function _CellOfLine(const ABuffer: TVTermBuffer;
  const AAbsLine, AX: Integer): TTerminalCell;
begin
  if AAbsLine < ABuffer.ScrollbackCount then
    Result := ABuffer.ScrollbackCell(AAbsLine, AX)
  else
    Result := ABuffer.Cell(AX, AAbsLine - ABuffer.ScrollbackCount);
end;

function _IsSelectedInSnap(const ACol, AAbsLine: Integer;
  const ASnapshot: TTerminalSnapshot): Boolean;
var
  LStart, LEnd: TPoint;
  LKey, LStartKey, LEndKey: Int64;
begin
  Result := False;
  if not ASnapshot.HasSelection then Exit;
  if (ASnapshot.SelAnchor.Y < ASnapshot.SelEnd.Y) or
     ((ASnapshot.SelAnchor.Y = ASnapshot.SelEnd.Y) and
      (ASnapshot.SelAnchor.X <= ASnapshot.SelEnd.X)) then
  begin
    LStart := ASnapshot.SelAnchor;
    LEnd   := ASnapshot.SelEnd;
  end
  else
  begin
    LStart := ASnapshot.SelEnd;
    LEnd   := ASnapshot.SelAnchor;
  end;
  LKey      := Int64(AAbsLine) * 100000 + ACol;
  LStartKey := Int64(LStart.Y) * 100000 + LStart.X;
  LEndKey   := Int64(LEnd.Y)   * 100000 + LEnd.X;
  Result := (LKey >= LStartKey) and (LKey < LEndKey);
end;

// ---------------------------------------------------------------------------
// TTerminalPainter
// ---------------------------------------------------------------------------

class function TTerminalPainter._TryDrawBlockElement(const ACanvas: TCanvas;
  const ARect: TRect; const ACodepoint: Cardinal;
  const AFg, ABg: TColor): Boolean;
var
  LCW, LCH, LMx, LMy, LN, LW, LH: Integer;
  LUL, LUR, LLL, LLR: TRect;
  LFgRgb, LBgRgb: Longint;
  LWeight: Integer;
  LR, LG, LB: Integer;

  procedure Solid(const ASub: TRect);
  begin
    ACanvas.FillRect(ASub);
  end;

begin
  // Only the block-element range is geometric here; box-drawing (U+2500..U+257F)
  // and everything else falls through to the font/TextOut path.
  if (ACodepoint < $2580) or (ACodepoint > $259F) then
    Exit(False);

  Result := True;
  LCW := ARect.Right - ARect.Left;
  LCH := ARect.Bottom - ARect.Top;
  LMx := LCW div 2;  // vertical mid-line (shared boundary for left/right & quadrants)
  LMy := LCH div 2;  // horizontal mid-line (shared boundary for top/bottom & quadrants)

  ACanvas.Brush.Style := bsSolid;

  // Shade blocks blend fg over bg; everything else is a solid fg fill.
  if (ACodepoint >= $2591) and (ACodepoint <= $2593) then
  begin
    LWeight := Integer(ACodepoint) - $2590; // 2591->1 (25%), 2592->2 (50%), 2593->3 (75%)
    LFgRgb := ColorToRGB(AFg);
    LBgRgb := ColorToRGB(ABg);
    LR := (( LFgRgb         and $FF) * LWeight + ( LBgRgb         and $FF) * (4 - LWeight)) div 4;
    LG := (((LFgRgb shr  8) and $FF) * LWeight + ((LBgRgb shr  8) and $FF) * (4 - LWeight)) div 4;
    LB := (((LFgRgb shr 16) and $FF) * LWeight + ((LBgRgb shr 16) and $FF) * (4 - LWeight)) div 4;
    ACanvas.Brush.Color := TColor((LB and $FF) shl 16 or (LG and $FF) shl 8 or (LR and $FF));
    Solid(ARect);
    Exit;
  end;

  ACanvas.Brush.Color := AFg;

  LUL := Rect(ARect.Left,       ARect.Top,       ARect.Left + LMx, ARect.Top + LMy);
  LUR := Rect(ARect.Left + LMx, ARect.Top,       ARect.Right,      ARect.Top + LMy);
  LLL := Rect(ARect.Left,       ARect.Top + LMy, ARect.Left + LMx, ARect.Bottom);
  LLR := Rect(ARect.Left + LMx, ARect.Top + LMy, ARect.Right,      ARect.Bottom);

  case ACodepoint of
    $2580: Solid(Rect(ARect.Left, ARect.Top, ARect.Right, ARect.Top + LMy)); // upper half
    $2584: Solid(Rect(ARect.Left, ARect.Top + LMy, ARect.Right, ARect.Bottom)); // lower half
    $2588: Solid(ARect); // full block
    $258C: Solid(Rect(ARect.Left, ARect.Top, ARect.Left + LMx, ARect.Bottom)); // left half
    $2590: Solid(Rect(ARect.Left + LMx, ARect.Top, ARect.Right, ARect.Bottom)); // right half
    $2594: Solid(Rect(ARect.Left, ARect.Top, ARect.Right, ARect.Top + (LCH + 4) div 8)); // upper 1/8
    $2595: Solid(Rect(ARect.Right - (LCW + 4) div 8, ARect.Top, ARect.Right, ARect.Bottom)); // right 1/8
    // Lower eighths (bottom N/8 up): 2581..2587 (2584 half & 2588 full handled above).
    $2581, $2582, $2583, $2585, $2586, $2587:
      begin
        LN := Integer(ACodepoint) - $2580;         // 1..7
        LH := (LCH * LN + 4) div 8;
        Solid(Rect(ARect.Left, ARect.Bottom - LH, ARect.Right, ARect.Bottom));
      end;
    // Left eighths (left N/8): 2589..258F (2588 full & 258C half handled above).
    $2589, $258A, $258B, $258D, $258E, $258F:
      begin
        LN := $2590 - Integer(ACodepoint);         // 1..7
        LW := (LCW * LN + 4) div 8;
        Solid(Rect(ARect.Left, ARect.Top, ARect.Left + LW, ARect.Bottom));
      end;
    // Quadrants.
    $2596: Solid(LLL);                                   // lower-left
    $2597: Solid(LLR);                                   // lower-right
    $2598: Solid(LUL);                                   // upper-left
    $2599: begin Solid(LUL); Solid(LLL); Solid(LLR); end; // UL+LL+LR
    $259A: begin Solid(LUL); Solid(LLR); end;            // UL+LR
    $259B: begin Solid(LUL); Solid(LUR); Solid(LLL); end; // UL+UR+LL
    $259C: begin Solid(LUL); Solid(LUR); Solid(LLR); end; // UL+UR+LR
    $259D: Solid(LUR);                                   // upper-right
    $259E: begin Solid(LUR); Solid(LLL); end;            // UR+LL
    $259F: begin Solid(LUR); Solid(LLL); Solid(LLR); end; // UR+LL+LR
  else
    // In-range but unmapped (should not happen across 2580..259F) - let the font
    // draw it rather than paint nothing.
    Result := False;
  end;
end;

class procedure TTerminalPainter._DrawCell(const ACanvas: TCanvas;
  const ASnapshot: TTerminalSnapshot;
  const AX, AViewRow, AAbsLine: Integer;
  const ACell: TTerminalCell; const ASpan: Integer);
var
  LRect: TRect;
  LFg, LBg, LTmp: TColor;
  LStyle: TFontStyles;
begin
  LRect.Left   := AX * ASnapshot.CellWidth;
  LRect.Top    := AViewRow * ASnapshot.CellHeight;
  LRect.Right  := LRect.Left + ASnapshot.CellWidth * ASpan;
  LRect.Bottom := LRect.Top  + ASnapshot.CellHeight;

  LFg := ACell.Fg.Resolve(ASnapshot.BasePalette, ASnapshot.DefaultFg);
  LBg := ACell.Bg.Resolve(ASnapshot.BasePalette, ASnapshot.DefaultBg);
  if caInverse in ACell.Attrs then
  begin
    LTmp := LFg; LFg := LBg; LBg := LTmp;
  end;
  if _IsSelectedInSnap(AX, AAbsLine, ASnapshot) then
  begin
    LBg := clHighlight;
    LFg := clHighlightText;
  end
  else if (ASnapshot.FindLen > 0) and (AAbsLine = ASnapshot.FindLine) and
          (AX >= ASnapshot.FindCol) and (AX < ASnapshot.FindCol + ASnapshot.FindLen) then
  begin
    LBg := clYellow;
    LFg := clBlack;
  end;

  ACanvas.Brush.Color := LBg;
  ACanvas.FillRect(LRect);

  // Block-element glyphs (U+2580..U+259F) are drawn geometrically so they fill
  // the whole cell rect and tile seamlessly - the font's block glyph is narrower
  // / shorter than the cell and would leave gaps in block art.
  if _TryDrawBlockElement(ACanvas, LRect, ACell.Ch, LFg, LBg) then
    Exit;

  LStyle := [];
  if caBold      in ACell.Attrs then Include(LStyle, fsBold);
  if caItalic    in ACell.Attrs then Include(LStyle, fsItalic);
  if caUnderline in ACell.Attrs then Include(LStyle, fsUnderline);
  ACanvas.Font.Style := LStyle;
  ACanvas.Font.Color := LFg;
  ACanvas.Brush.Style := bsClear;
  if ACell.Ch <> 32 then
    // GlyphText (not Char.ConvertFromUtf32) renders the UCS4Char as the UTF-16
    // text TextOut expects, so emoji / logo glyphs survive to the GDI call
    // instead of being narrowed away. It also cannot RAISE: ConvertFromUtf32
    // threw here on the gap behind a double-width glyph, and an exception inside
    // a paint puts an IDE-wide error dialog over the whole terminal.
    ACanvas.TextOut(LRect.Left, LRect.Top, ACell.GlyphText);
  ACanvas.Brush.Style := bsSolid;

  if (ASnapshot.HoverLinkUrl <> '') and (AAbsLine = ASnapshot.HoverRow)
    and (ASnapshot.Buffer.GetLinkAt(AX,
         AAbsLine - ASnapshot.Buffer.ScrollbackCount) = ASnapshot.HoverLinkUrl) then
  begin
    ACanvas.Pen.Color := LFg;
    ACanvas.MoveTo(LRect.Left,  LRect.Bottom - 1);
    ACanvas.LineTo(LRect.Right, LRect.Bottom - 1);
  end;
end;

class procedure TTerminalPainter._PaintRow(const ACanvas: TCanvas;
  const ASnapshot: TTerminalSnapshot; const AViewRow: Integer);
var
  LAbsLine, LX, LSpan: Integer;
begin
  LAbsLine := _TopLine(ASnapshot) + AViewRow;
  if LAbsLine >= _TotalLines(ASnapshot) then
  begin
    ACanvas.Brush.Color := ASnapshot.DefaultBg;
    ACanvas.FillRect(Rect(0, AViewRow * ASnapshot.CellHeight,
      ASnapshot.DrawAreaWidth, (AViewRow + 1) * ASnapshot.CellHeight));
    Exit;
  end;
  LX := 0;
  while LX <= ASnapshot.Buffer.Cols - 1 do
  begin
    // Look ahead ONE column: libvterm marks the column a double-width glyph
    // spills into, so a cell is wide exactly when its right neighbour is that
    // marker. Painting the pair as a unit (and skipping the covered column) is
    // what stops the neighbour's background from clipping the glyph in half.
    LSpan := 1;
    if (LX + 1 <= ASnapshot.Buffer.Cols - 1)
      and (caWideGap in _CellOfLine(ASnapshot.Buffer, LAbsLine, LX + 1).Attrs) then
      LSpan := 2;
    _DrawCell(ACanvas, ASnapshot, LX, AViewRow, LAbsLine,
      _CellOfLine(ASnapshot.Buffer, LAbsLine, LX), LSpan);
    Inc(LX, LSpan);
  end;
end;

class procedure TTerminalPainter._DrawCursor(const ACanvas: TCanvas;
  const ASnapshot: TTerminalSnapshot);
var
  LRect: TRect;
  LRow: Integer;
begin
  if (ASnapshot.ScrollOffset <> 0) or not ASnapshot.Buffer.CursorVisible then Exit;
  if not (ASnapshot.Focused and ASnapshot.CursorOn) then Exit;
  LRow         := ASnapshot.Buffer.CursorY;
  LRect.Left   := ASnapshot.Buffer.CursorX * ASnapshot.CellWidth;
  LRect.Top    := LRow * ASnapshot.CellHeight;
  LRect.Right  := LRect.Left + ASnapshot.CellWidth;
  LRect.Bottom := LRect.Top  + ASnapshot.CellHeight;
  ACanvas.Brush.Color := ASnapshot.CursorColor;
  case ASnapshot.CursorShape of
    csUnderline:
      ACanvas.FillRect(Rect(LRect.Left, LRect.Bottom - 2, LRect.Right, LRect.Bottom));
    csBar:
      ACanvas.FillRect(Rect(LRect.Left, LRect.Top, LRect.Left + 1, LRect.Bottom));
  else
    ACanvas.FillRect(LRect); // csBlock (default)
  end;
end;

class procedure TTerminalPainter.Paint(const ACanvas: TCanvas;
  const ASnapshot: TTerminalSnapshot);
var
  LRow: Integer;
  LGridWidth, LGridHeight: Integer;
begin
  ACanvas.Font.Name := ASnapshot.FontName;
  ACanvas.Font.Size := ASnapshot.FontSize;
  ACanvas.Brush.Color := ASnapshot.DefaultBg;

  LGridWidth := ASnapshot.Buffer.Cols * ASnapshot.CellWidth;
  if LGridWidth < ASnapshot.DrawAreaWidth then
    ACanvas.FillRect(Rect(LGridWidth, 0, ASnapshot.DrawAreaWidth, ASnapshot.ClientHeight));

  LGridHeight := ASnapshot.VisibleRows * ASnapshot.CellHeight;
  if LGridHeight < ASnapshot.ClientHeight then
    ACanvas.FillRect(Rect(0, LGridHeight, ASnapshot.DrawAreaWidth, ASnapshot.ClientHeight));

  for LRow := 0 to ASnapshot.VisibleRows - 1 do
    _PaintRow(ACanvas, ASnapshot, LRow);

  _DrawCursor(ACanvas, ASnapshot);
end;

end.
