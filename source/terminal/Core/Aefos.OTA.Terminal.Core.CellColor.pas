unit Aefos.OTA.Terminal.Core.CellColor;

{$IFDEF FPC}{$mode delphi}{$H+}{$ENDIF}

interface

{$IFNDEF FPC}
uses
  System.UITypes;   // TColor
{$ENDIF}

{$IFDEF FPC}
type
  { TColor here is only a packed 0x00BBGGRR RGB integer (this unit does colour
    math, no GUI). System.UITypes does not exist on FPC and the LCL's Graphics
    TColor would drag in the whole LCL; a plain 32-bit alias is the right weight
    for a core unit and layout-compatible with both. }
  TColor = LongInt;
{$ENDIF}

type
  /// <summary>
  /// Discriminates how a terminal cell color is stored and later resolved.
  /// </summary>
  TColorKind = (ckDefault, ckIndexed, ckRGB);

  /// <summary>The 16 base ANSI colors supplied by the active theme.</summary>
  TBasePalette = array[0..15] of TColor;

  /// <summary>
  /// Represents a terminal cell color. A default color resolves from the active
  /// theme; an indexed color resolves through the xterm 256-color palette;
  /// an RGB color is a fixed 24-bit value unaffected by theme changes.
  /// </summary>
  TCellColor = record
    Kind: TColorKind;
    /// <summary>Indexed: 0..255. RGB: packed $00RRGGBB.</summary>
    Value: Cardinal;
    class function CreateDefault: TCellColor; static;
    class function CreateIndexed(const AIndex: Integer): TCellColor; static;
    class function CreateRGB(const AR, AG, AB: Byte): TCellColor; static;
    class operator Equal(const A, B: TCellColor): Boolean;
    class operator NotEqual(const A, B: TCellColor): Boolean;
    /// <summary>
    /// Resolves a single xterm 256-palette index (0..255) to a TColor.
    /// 0..15 come from the base palette, 16..231 from the 6x6x6 cube,
    /// 232..255 from the 24-step grayscale ramp.
    /// </summary>
    class function PaletteColor(const AIndex: Integer;
      const ABasePalette: TBasePalette): TColor; static;
    /// <summary>
    /// Resolves this cell color to a concrete TColor using the supplied base
    /// palette and the default color for a cell with kind ckDefault.
    /// </summary>
    function Resolve(const ABasePalette: TBasePalette;
      const ADefault: TColor): TColor;
  end;

  /// <summary>Per-cell visual attributes (color is stored separately).
  /// Moved from Aefos.OTA.Terminal.Core.VTermBuffer to Aefos.OTA.Terminal.Core.CellColor so the pure
  /// Aefos.OTA.Terminal.Core.Reflow unit can reference TTerminalCell without pulling in
  /// libvterm. ESP-034 / ADR-034-02.</summary>
  { caWideGap is structural, not visual: the column is COVERED by the
    double-width glyph to its left and owns no character. It rides in the attrs
    set rather than becoming a new field so the serialized cell keeps its exact
    JSON shape -- a grid saved before this existed simply lacks the bit and
    restores to the old rendering instead of failing to load. }
  TCellAttr = (caBold, caDim, caItalic, caUnderline, caInverse, caWideGap);
  TCellAttrs = set of TCellAttr;

  /// <summary>A single terminal grid cell. Moved from Aefos.OTA.Terminal.Core.VTermBuffer
  /// to Aefos.OTA.Terminal.Core.CellColor for the same purity reasons as TCellAttrs.</summary>
  TTerminalCell = record
    // UCS4Char (NOT Char / WideChar): a plain 4-byte scalar value type (= LongWord)
    // holding the FULL Unicode codepoint. FPC {$mode delphi} `Char` = AnsiChar (1
    // byte) truncated codepoints > 255 to their low byte; a WideChar is a single
    // UTF-16 code unit and still cannot hold astral-plane scalars (> U+FFFF), so
    // emoji / logo glyphs (e.g. U+1F680) collapsed to a '?' placeholder. UCS4Char
    // is 4 bytes on both compilers, carries any scalar (BMP + astral), and stays a
    // value type — no per-cell heap allocation for a grid repainted thousands of
    // times. Painters convert this codepoint to text at the draw boundary.
    Ch: UCS4Char;
    Fg: TCellColor;
    Bg: TCellColor;
    Attrs: TCellAttrs;
    /// <summary>Turns one raw libvterm `chars[0]` into a value this record is
    /// allowed to hold. NOT every 32-bit word libvterm hands back is a Unicode
    /// scalar: the column BEHIND a double-width glyph carries the sentinel
    /// `(uint32_t)-1` (ThirdParty/libvterm/src/screen.c:191), and a scalar can
    /// never sit in the surrogate range nor above U+10FFFF. Storing those raw
    /// pushed the problem onto every consumer, and they disagreed about it --
    /// the text path silently truncated the sentinel to U+FFFF while the painter
    /// raised "Invalid UTF32 character value" from inside a WM_PAINT, which
    /// surfaces as an IDE-wide exception dialog. So the rule lives HERE, at the
    /// one boundary where the value enters the model, and the record's invariant
    /// becomes: Ch is always a paintable scalar.</summary>
    class function ScalarFromVTerm(const ARawChar: LongWord): UCS4Char; static;
    /// <summary>True when this raw libvterm `chars[0]` is the marker for the
    /// column behind a double-width glyph. ScalarFromVTerm blanks it, which is
    /// right for the VALUE -- but the PAINTER still has to know, or it paints
    /// this cell's background over the right half of the glyph next door. That
    /// is the clipped-emoji artifact.</summary>
    class function IsWideGap(const ARawChar: LongWord): Boolean; static;
    /// <summary>The cell's text for a draw call, as UTF-16 (a surrogate pair for
    /// astral scalars). Spelled out by hand rather than via
    /// Char.ConvertFromUtf32 because this unit is compiled by the headless FPC
    /// probes, whose unit path has neither System.Character nor LazUTF8 -- and
    /// because a painter must not be able to raise: anything that is not a
    /// scalar returns '' instead of an exception.</summary>
    function GlyphText: UnicodeString;
  end;

  /// <summary>A whole terminal row's worth of cells.</summary>
  TTerminalRow = TArray<TTerminalCell>;

implementation

function _PackColor(const AR, AG, AB: Byte): TColor;
begin
  Result := TColor(AR or (AG shl 8) or (AB shl 16));
end;

function _CubeComponent(const ALevel: Integer): Byte;
begin
  if ALevel <= 0 then
    Result := 0
  else
    Result := Byte(55 + 40 * ALevel);
end;

function _CubeColor(const AIndex: Integer): TColor;
var
  LBase: Integer;
begin
  LBase := AIndex - 16;
  Result := _PackColor(
    _CubeComponent(LBase div 36),
    _CubeComponent((LBase div 6) mod 6),
    _CubeComponent(LBase mod 6));
end;

function _GrayscaleColor(const AIndex: Integer): TColor;
var
  LLevel: Byte;
begin
  LLevel := Byte(8 + (AIndex - 232) * 10);
  Result := _PackColor(LLevel, LLevel, LLevel);
end;

{ TCellColor }

class function TCellColor.CreateDefault: TCellColor;
begin
  Result.Kind := ckDefault;
  Result.Value := 0;
end;

class function TCellColor.CreateIndexed(const AIndex: Integer): TCellColor;
begin
  Result.Kind := ckIndexed;
  if AIndex < 0 then
    Result.Value := 0
  else if AIndex > 255 then
    Result.Value := 255
  else
    Result.Value := Cardinal(AIndex);
end;

class function TCellColor.CreateRGB(const AR, AG, AB: Byte): TCellColor;
begin
  Result.Kind := ckRGB;
  Result.Value := Cardinal(AR shl 16) or Cardinal(AG shl 8) or Cardinal(AB);
end;

class operator TCellColor.Equal(const A, B: TCellColor): Boolean;
begin
  Result := (A.Kind = B.Kind) and (A.Value = B.Value);
end;

class operator TCellColor.NotEqual(const A, B: TCellColor): Boolean;
begin
  Result := not (A = B);
end;

{ Resolution }

class function TCellColor.PaletteColor(const AIndex: Integer;
  const ABasePalette: TBasePalette): TColor;
begin
  if AIndex < 0 then
    Result := ABasePalette[0]
  else if AIndex <= 15 then
    Result := ABasePalette[AIndex]
  else if AIndex <= 231 then
    Result := _CubeColor(AIndex)
  else if AIndex <= 255 then
    Result := _GrayscaleColor(AIndex)
  else
    Result := ABasePalette[15];
end;

function TCellColor.Resolve(const ABasePalette: TBasePalette;
  const ADefault: TColor): TColor;
begin
  case Kind of
    ckIndexed:
      Result := PaletteColor(Integer(Value), ABasePalette);
    ckRGB:
      Result := _PackColor(
        Byte((Value shr 16) and $FF),
        Byte((Value shr 8) and $FF),
        Byte(Value and $FF));
  else
    Result := ADefault;
  end;
end;

{ TTerminalCell }

class function TTerminalCell.ScalarFromVTerm(
  const ARawChar: LongWord): UCS4Char;
begin
  // Everything that is not a scalar becomes a blank. For the double-width gap
  // that is also what it MEANS: the column is covered by the glyph to its left
  // and owns no character of its own, so a space with the cell's own background
  // is the honest rendering. libvterm reports an empty cell as 0 and that has
  // always mapped to a space here.
  if (ARawChar = 0)
    or (ARawChar > $10FFFF)
    or ((ARawChar >= $D800) and (ARawChar <= $DFFF)) then
    Result := UCS4Char(32)
  else
    Result := UCS4Char(ARawChar);
end;

class function TTerminalCell.IsWideGap(const ARawChar: LongWord): Boolean;
begin
  // screen.c:191 -- libvterm writes (uint32_t)-1 into every column a wide glyph
  // spills into. It is the ONLY meaning that value has.
  Result := ARawChar = $FFFFFFFF;
end;

function TTerminalCell.GlyphText: UnicodeString;
var
  LScalar: LongWord;
  LHigh: Word;
  LLow: Word;
begin
  Result := '';
  LScalar := LongWord(Ch);
  // Defensive, not redundant: ScalarFromVTerm holds the invariant for cells that
  // came from libvterm, but a cell can also arrive from a restored JSON grid or
  // from the Lazarus edition. A paint handler is the worst possible place to
  // discover a bad value, so this refuses to hand GDI something it cannot draw.
  if (LScalar > $10FFFF) or ((LScalar >= $D800) and (LScalar <= $DFFF)) then
    Exit;
  if LScalar <= $FFFF then
  begin
    SetLength(Result, 1);
    Result[1] := WideChar(LScalar);
  end
  else
  begin
    LScalar := LScalar - $10000;
    LHigh := Word($D800 + (LScalar shr 10));
    LLow := Word($DC00 + (LScalar and $3FF));
    SetLength(Result, 2);
    Result[1] := WideChar(LHigh);
    Result[2] := WideChar(LLow);
  end;
end;

end.


