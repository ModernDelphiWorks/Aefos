unit Aefos.Lazarus.TerminalPainter;

{$IFDEF FPC}{$mode delphi}{$H+}{$ENDIF}

(*
  LCL port of the terminal grid painter (Aefos -> Lazarus, terminal UI slice).

  The Delphi twin is source\terminal\UI\Aefos.OTA.Terminal.UI.TerminalPainter.pas
  (TTerminalPainter.Paint drawing a TTerminalCell grid onto a Vcl.Graphics.TCanvas).
  This is a faithful-but-MINIMAL port onto an LCL TCanvas: it draws the padding
  strips, the visible rows (fg/bg per cell, bold/italic/underline, inverse) and the
  cursor. The LCL Canvas API is ~1:1 with the VCL one (TextOut / FillRect / Font /
  Brush), so the paint logic ports almost verbatim.

  DEFERRED to later slices (present in the Delphi painter, intentionally dropped
  here): find highlight, hover-hyperlink underline and Sixel image blitting. The
  scrollback viewport (ScrollOffset) and text selection ARE ported: each visible
  view row resolves to an absolute line _TopLine + row over TVTermBuffer's
  scrollback + live grid, so the user can wheel/scrollbar back through history and
  the cursor is hidden while scrolled up.

  The painter is stateless: all read-state arrives through TTerminalSnapshot, so the
  hosting control can build the snapshot from its own fields and the painter needs no
  live control instance (mirrors the Delphi ADR-067-01 extraction).
*)

interface

uses
  {$IFDEF FPC}Types, Graphics, LazUTF8,{$ELSE}System.Types, Vcl.Graphics,{$ENDIF}
  Aefos.OTA.Terminal.Core.CellColor,
  Aefos.OTA.Terminal.Core.VTermBuffer;

type
  /// <summary>Cursor shape variants. Mirrors the Delphi
  /// Aefos.OTA.Terminal.Core.VisualTokens.TCursorShape without pulling in that
  /// VCL-only unit; V.2 default is csBlock.</summary>
  TCursorShape = (csBlock, csUnderline, csBar);

  /// <summary>
  /// Trimmed read-set of the terminal paint captured as a value snapshot. Build
  /// from the hosting control's fields and pass to TTerminalPainter.Paint. The
  /// selection / find / hover / scrollback / sixel fields of the Delphi snapshot
  /// are dropped for this slice.
  /// </summary>
  TTerminalSnapshot = record
    // Grid metrics
    CellWidth: Integer;
    CellHeight: Integer;
    DrawAreaWidth: Integer;
    ClientHeight: Integer;
    VisibleRows: Integer;
    VisibleCols: Integer;
    // Y pixel where the grid starts, so a top toolbar docked on the hosting control
    // (alTop) does not paint the first rows behind itself: every row / cursor / pad
    // strip is offset down by TopOffset. 0 when no toolbar is present. The bottom
    // twin (composer bar) is instead handled by shrinking ClientHeight/VisibleRows.
    TopOffset: Integer;
    // Colors
    DefaultFg: TColor;
    DefaultBg: TColor;
    CursorColor: TColor;
    BasePalette: TBasePalette;
    // Buffer reference (not owned - control lifetime manages it)
    Buffer: TVTermBuffer;
    // Scrollback viewport: how many lines the view is scrolled UP from the live
    // bottom (0 = live/bottom, max = Buffer.ScrollbackCount). Mirrors the Delphi
    // snapshot's ScrollOffset.
    ScrollOffset: Integer;
    // Cursor blink / focus
    CursorOn: Boolean;
    Focused: Boolean;
    CursorShape: TCursorShape;
    // Font (frozen for the paint)
    FontName: string;
    FontSize: Integer;
    // Text selection in ABSOLUTE line coordinates: X = col, Y = absolute line
    // (0..Buffer.ScrollbackCount + Rows-1, scrollback lines first, then the live
    // grid). Mirrors the Delphi snapshot's HasSelection/SelAnchor/SelEnd, which
    // are captured through _PixelToCell as _TopLine + row so a selection stays
    // pinned to its text while the viewport scrolls.
    HasSelection: Boolean;
    SelAnchor: TPoint;
    SelEnd: TPoint;
    // Find highlight in GRID coordinates: when FindLen > 0, FindLen columns
    // starting at FindCol on the absolute line FindLine are drawn yellow-on-black.
    // Mirrors the Delphi snapshot's FindLine/FindCol/FindLen. Selection takes
    // precedence over find (find is the else-branch), matching the Delphi painter.
    FindLine: Integer;
    FindCol: Integer;
    FindLen: Integer;
  end;

  /// <summary>
  /// Stateless painter that reproduces the terminal surface against any LCL
  /// TCanvas. Receives all required state through TTerminalSnapshot.
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
    /// <summary>True when cell (ACol, AAbsLine) falls inside the current
    /// selection. Mirrors the Delphi painter's _IsSelectedInSnap: the anchor/end
    /// pair is put in reading order and the cell is tested by the ordered key
    /// Y*100000+X over the half-open range [start..end), so the anchor cell is
    /// included and the cell under the release point is not. AAbsLine is an
    /// absolute line (scrollback-based), matching the selection capture.</summary>
    class function _IsSelectedInSnap(const ACol, AAbsLine: Integer;
      const ASnapshot: TTerminalSnapshot): Boolean; static;
    /// <summary>Top absolute line of the viewport = ScrollbackCount - ScrollOffset,
    /// clamped >= 0 (Delphi painter _TopLine twin).</summary>
    class function _TopLine(const ASnapshot: TTerminalSnapshot): Integer; static;
    /// <summary>Total addressable lines = ScrollbackCount + Rows (Delphi
    /// painter _TotalLines twin).</summary>
    class function _TotalLines(const ASnapshot: TTerminalSnapshot): Integer; static;
    /// <summary>The cell at absolute line AAbsLine / column AX: from scrollback
    /// when AAbsLine < ScrollbackCount, otherwise from the live grid at
    /// AAbsLine - ScrollbackCount (Delphi painter _CellOfLine twin).</summary>
    class function _CellOfLine(const ABuffer: TVTermBuffer;
      const AAbsLine, AX: Integer): TTerminalCell; static;
    /// <summary>Paints one visible view row: resolves its absolute line and
    /// draws each column (or a background strip when the row is past the last
    /// addressable line). Delphi painter _PaintRow twin.</summary>
    class procedure _PaintRow(const ACanvas: TCanvas;
      const ASnapshot: TTerminalSnapshot; const AViewRow: Integer); static;
    class procedure _DrawCell(const ACanvas: TCanvas;
      const ASnapshot: TTerminalSnapshot;
      const AX, AViewRow, AAbsLine: Integer;
      const ACell: TTerminalCell); static;
    class procedure _DrawCursor(const ACanvas: TCanvas;
      const ASnapshot: TTerminalSnapshot); static;
  public
    /// <summary>Renders the terminal grid (padding strips + rows + cursor) onto
    /// ACanvas using the state captured in ASnapshot.</summary>
    class procedure Paint(const ACanvas: TCanvas;
      const ASnapshot: TTerminalSnapshot); static;
  end;

implementation

{ TTerminalPainter }

class function TTerminalPainter._TryDrawBlockElement(const ACanvas: TCanvas;
  const ARect: TRect; const ACodepoint: Cardinal;
  const AFg, ABg: TColor): Boolean;
var
  LCW, LCH, LMx, LMy, LN, LW, LH: Integer;
  LUL, LUR, LLL, LLR: TRect;
  LFgRgb, LBgRgb: LongInt;
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
    // In-range but unmapped (should not happen across 2580..259F) — let the font
    // draw it rather than paint nothing.
    Result := False;
  end;
end;

class function TTerminalPainter._IsSelectedInSnap(const ACol, AAbsLine: Integer;
  const ASnapshot: TTerminalSnapshot): Boolean;
var
  LStart, LEnd: TPoint;
  LKey, LStartKey, LEndKey: Int64;
begin
  Result := False;
  if not ASnapshot.HasSelection then Exit;
  // Order anchor/end in reading order (top-to-bottom, then left-to-right).
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

class function TTerminalPainter._TopLine(
  const ASnapshot: TTerminalSnapshot): Integer;
begin
  Result := ASnapshot.Buffer.ScrollbackCount - ASnapshot.ScrollOffset;
  if Result < 0 then
    Result := 0;
end;

class function TTerminalPainter._TotalLines(
  const ASnapshot: TTerminalSnapshot): Integer;
begin
  Result := ASnapshot.Buffer.ScrollbackCount + ASnapshot.Buffer.Rows;
end;

class function TTerminalPainter._CellOfLine(const ABuffer: TVTermBuffer;
  const AAbsLine, AX: Integer): TTerminalCell;
begin
  if AAbsLine < ABuffer.ScrollbackCount then
    Result := ABuffer.ScrollbackCell(AAbsLine, AX)
  else
    Result := ABuffer.Cell(AX, AAbsLine - ABuffer.ScrollbackCount);
end;

class procedure TTerminalPainter._DrawCell(const ACanvas: TCanvas;
  const ASnapshot: TTerminalSnapshot;
  const AX, AViewRow, AAbsLine: Integer;
  const ACell: TTerminalCell);
var
  LRect: TRect;
  LFg, LBg, LTmp: TColor;
  LStyle: TFontStyles;
begin
  LRect.Left   := AX * ASnapshot.CellWidth;
  LRect.Top    := ASnapshot.TopOffset + AViewRow * ASnapshot.CellHeight;
  LRect.Right  := LRect.Left + ASnapshot.CellWidth;
  LRect.Bottom := LRect.Top  + ASnapshot.CellHeight;

  LFg := ACell.Fg.Resolve(ASnapshot.BasePalette, ASnapshot.DefaultFg);
  LBg := ACell.Bg.Resolve(ASnapshot.BasePalette, ASnapshot.DefaultBg);
  if caInverse in ACell.Attrs then
  begin
    LTmp := LFg; LFg := LBg; LBg := LTmp;
  end;
  // Selection highlight rides ON TOP of the inverse-video swap and BEFORE the
  // block-element/text draw, so a selected block cell still reads as selected
  // (mirrors the Delphi painter). AAbsLine is the absolute scrollback line.
  if _IsSelectedInSnap(AX, AAbsLine, ASnapshot) then
  begin
    LBg := clHighlight;
    LFg := clHighlightText;
  end
  // Find highlight rides in the else-branch (selection wins over find), mirroring
  // the Delphi painter's order. FindCol/FindLen are GRID columns (the control
  // scans cell-by-cell so the column is inherently a grid col, never a byte
  // offset), so the half-open [FindCol, FindCol + FindLen) test is exact.
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
    // TTerminalCell.Ch is a UCS4Char full Unicode codepoint. LazUTF8's
    // UnicodeToUTF8(Cardinal) builds the UTF-8 AnsiString straight from the scalar
    // (BMP + astral) that LCL's TextOut wants - so box-drawing, arrows AND
    // astral-plane emoji / logo glyphs (> U+FFFF) all reach the canvas intact.
    ACanvas.TextOut(LRect.Left, LRect.Top, UnicodeToUTF8(ACell.Ch));
  ACanvas.Brush.Style := bsSolid;
end;

class procedure TTerminalPainter._PaintRow(const ACanvas: TCanvas;
  const ASnapshot: TTerminalSnapshot; const AViewRow: Integer);
var
  LAbsLine, LX: Integer;
begin
  LAbsLine := _TopLine(ASnapshot) + AViewRow;
  // A view row past the last addressable line (scrollback + live grid) paints as
  // a background strip - happens when ScrollbackCount + Rows < VisibleRows, e.g.
  // a fresh pane taller than the buffer.
  if LAbsLine >= _TotalLines(ASnapshot) then
  begin
    ACanvas.Brush.Color := ASnapshot.DefaultBg;
    ACanvas.FillRect(Rect(0,
      ASnapshot.TopOffset + AViewRow * ASnapshot.CellHeight,
      ASnapshot.DrawAreaWidth,
      ASnapshot.TopOffset + (AViewRow + 1) * ASnapshot.CellHeight));
    Exit;
  end;
  for LX := 0 to ASnapshot.Buffer.Cols - 1 do
    _DrawCell(ACanvas, ASnapshot, LX, AViewRow, LAbsLine,
      _CellOfLine(ASnapshot.Buffer, LAbsLine, LX));
end;

class procedure TTerminalPainter._DrawCursor(const ACanvas: TCanvas;
  const ASnapshot: TTerminalSnapshot);
var
  LRect: TRect;
begin
  // Hide the cursor while the view is scrolled up into history (Delphi twin).
  if ASnapshot.ScrollOffset <> 0 then Exit;
  if not ASnapshot.Buffer.CursorVisible then Exit;
  if not (ASnapshot.Focused and ASnapshot.CursorOn) then Exit;
  LRect.Left   := ASnapshot.Buffer.CursorX * ASnapshot.CellWidth;
  LRect.Top    := ASnapshot.TopOffset + ASnapshot.Buffer.CursorY * ASnapshot.CellHeight;
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

  // Right padding strip (client wider than the whole-cell grid). Starts at
  // TopOffset so it clears the grid area only, never the top toolbar band above it.
  LGridWidth := ASnapshot.Buffer.Cols * ASnapshot.CellWidth;
  if LGridWidth < ASnapshot.DrawAreaWidth then
    ACanvas.FillRect(Rect(LGridWidth, ASnapshot.TopOffset,
      ASnapshot.DrawAreaWidth, ASnapshot.ClientHeight));

  // Bottom padding strip (client taller than the whole-cell grid). The grid bottom
  // is TopOffset + the painted rows, so the strip fills the gap down to ClientHeight.
  LGridHeight := ASnapshot.TopOffset + ASnapshot.VisibleRows * ASnapshot.CellHeight;
  if LGridHeight < ASnapshot.ClientHeight then
    ACanvas.FillRect(Rect(0, LGridHeight,
      ASnapshot.DrawAreaWidth, ASnapshot.ClientHeight));

  // Visible rows resolved through the scrollback viewport: each view row maps to
  // an absolute line _TopLine + row (scrollback lines first, then the live grid).
  for LRow := 0 to ASnapshot.VisibleRows - 1 do
    _PaintRow(ACanvas, ASnapshot, LRow);

  _DrawCursor(ACanvas, ASnapshot);
end;

end.
