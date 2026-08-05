unit Aefos.OTA.Terminal.Core.SixelDecode;
{$IFDEF FPC}{$mode delphi}{$H+}{$ENDIF}

(*
  Pure Sixel DCS-body decoder — ESP-035 / ADR-035-02.

  Decodes the body of a `DCS q ... ST` sequence into a row-major BGRA byte
  array, ready for the canvas to wrap in a TBitmap (pf32bit + afPremultiplied).
  No VCL, no libvterm, no globals, no exceptions — malformed tokens are
  silently skipped per BR3 / BR4. Honours the pixel cap from BR-style safety:
  decoding stops the first time a write would push the implied W*H past
  SIXEL_MAX_PIXELS and the partial result is returned.

  Sixel character encoding: `v = byte - 63`; '?' (63) is 0 (no pixels lit),
  '~' (126) is 63 (all six pixels lit). The bits map LSB->top-row.
*)

interface

uses
  {$IFDEF FPC}SysUtils, Math, Classes, Generics.Collections{$ELSE}System.SysUtils, System.Math, System.Classes, System.Generics.Collections{$ENDIF};

const
  /// <summary>Cap on the implied W*H pixel count of a single decoded image
  /// (~32 MB BGRA). Decoding stops the first time a write would push the
  /// implied area past this value; the partial result is returned with no
  /// exception. ESP-035 / ADR-035-02.</summary>
  SIXEL_MAX_PIXELS = 8000000;

  /// <summary>Cap on the raw DCS accumulator the buffer feeds into the
  /// decoder (16 MB). Beyond this the buffer discards the body silently —
  /// BR7. Mirrored here so callers reach it without a circular import.</summary>
  SIXEL_RAW_CAP = 16 * 1024 * 1024;

type
  /// <summary>One palette slot — RGBA in 0..255. Index 0 defaults to A=0
  /// (transparent); 1..255 default to opaque black per ADR-035-02.</summary>
  TSixelPaletteEntry = record
    R, G, B, A: Byte;
  end;

  /// <summary>Pure Sixel-decoder facade. The single entry point is the
  /// class-static Decode; no instance is ever created.</summary>
  TSixelDecoder = class sealed
  public
    /// <summary>Decodes the body of a `DCS q ... ST` Sixel sequence into a BGRA
    /// byte array, row-major, top-to-bottom (Windows pf32bit native order).
    /// Empty / nil input returns an empty array with AWidth = AHeight = 0.
    /// Malformed tokens are silently skipped (BR3, BR4). Decoded pixel count is
    /// capped at SIXEL_MAX_PIXELS; truncation returns a partial image without
    /// raising. Length(Result) = AWidth*AHeight*4 on success.</summary>
    class function Decode(const AData: RawByteString;
      out AWidth, AHeight: Integer): TArray<Byte>; static;
  end;

implementation

type
  TSixelPalette = array[0..255] of TSixelPaletteEntry;

  TSixelState = record
    Palette: TSixelPalette;
    Rows: TList<TBytes>;
    CurrentColor: Integer;
    X: Integer;
    SixelLineY: Integer;
    MaxX: Integer;
    MaxLineY: Integer;
    HasData: Boolean;
    Capped: Boolean;
  end;

procedure _InitPalette(out APalette: TSixelPalette);
var
  LFor: Integer;
begin
  FillChar(APalette, SizeOf(APalette), 0);
  for LFor := 1 to 255 do
    APalette[LFor].A := 255;
end;

function _ClampByte(const AValue: Integer): Byte;
begin
  if AValue < 0 then Exit(0);
  if AValue > 255 then Exit(255);
  Result := Byte(AValue);
end;

function _HlsHueShift(const AHue, AQ1, AQ2: Double): Double;
var
  LH: Double;
begin
  LH := AHue;
  while LH < 0 do LH := LH + 360;
  while LH >= 360 do LH := LH - 360;
  if LH < 60 then
    Result := AQ1 + (AQ2 - AQ1) * (LH / 60)
  else if LH < 180 then
    Result := AQ2
  else if LH < 240 then
    Result := AQ1 + (AQ2 - AQ1) * ((240 - LH) / 60)
  else
    Result := AQ1;
end;

procedure _HlsToRgb(const AH, AL, ASat: Integer; out AR, AG, AB: Byte);
// BR2: H in degrees (0..360), L and ASat as percentages (0..100). Standard
// HLS->RGB; ASat=0 collapses to the achromatic round(L * 2.55).
var
  LLn, LSn, LQ1, LQ2, LRd, LGd, LBd: Double;
begin
  if ASat = 0 then
  begin
    AR := _ClampByte(Round(AL * 2.55));
    AG := AR;
    AB := AR;
    Exit;
  end;
  LLn := AL / 100;
  LSn := ASat / 100;
  if AL < 50 then
    LQ2 := LLn * (1 + LSn)
  else
    LQ2 := LLn + LSn - LLn * LSn;
  LQ1 := 2 * LLn - LQ2;
  LRd := _HlsHueShift(AH + 120, LQ1, LQ2);
  LGd := _HlsHueShift(AH,       LQ1, LQ2);
  LBd := _HlsHueShift(AH - 120, LQ1, LQ2);
  AR := _ClampByte(Round(LRd * 255));
  AG := _ClampByte(Round(LGd * 255));
  AB := _ClampByte(Round(LBd * 255));
end;

procedure _SetPixel(var AState: TSixelState; const AX, AY: Integer);
// Writes one BGRA pixel at (AX, AY). Grows the per-row buffer geometrically
// (capacity doubles) so streaming `!N~` runs in linear time rather than the
// O(N^2) reallocation pattern a naïve `SetLength((X+1)*4)` would incur.
var
  LRow: TBytes;
  LEntry: TSixelPaletteEntry;
  LOffset, LNeeded, LCurrentCap: Integer;
begin
  while AState.Rows.Count <= AY do
    AState.Rows.Add(nil);
  LRow := AState.Rows[AY];
  LNeeded := (AX + 1) * 4;
  if Length(LRow) < LNeeded then
  begin
    LCurrentCap := Length(LRow);
    if LCurrentCap < 64 then LCurrentCap := 64;
    while LCurrentCap < LNeeded do LCurrentCap := LCurrentCap * 2;
    SetLength(LRow, LCurrentCap);
    AState.Rows[AY] := LRow;
  end;
  LEntry := AState.Palette[Byte(AState.CurrentColor)];
  LOffset := AX * 4;
  AState.Rows[AY][LOffset]     := LEntry.B;
  AState.Rows[AY][LOffset + 1] := LEntry.G;
  AState.Rows[AY][LOffset + 2] := LEntry.R;
  AState.Rows[AY][LOffset + 3] := LEntry.A;
  AState.HasData := True;
  if AState.SixelLineY > AState.MaxLineY then
    AState.MaxLineY := AState.SixelLineY;
end;

procedure _EmitColumn(var AState: TSixelState; const AValue: Byte);
// Paints one 6-pixel column at (AState.X, AState.SixelLineY..+5). Bit 0 is
// the top pixel; an unset bit leaves any previous pixel at that row
// untouched (Sixel additive semantics). Advances X by 1 even when AValue=0.
var
  LBit: Integer;
begin
  if AState.Capped then Exit;
  if NativeInt(AState.X + 1) *
     NativeInt(AState.SixelLineY + 6) > SIXEL_MAX_PIXELS then
  begin
    AState.Capped := True;
    Exit;
  end;
  if AValue <> 0 then
  begin
    for LBit := 0 to 5 do
      if (AValue and (1 shl LBit)) <> 0 then
        _SetPixel(AState, AState.X, AState.SixelLineY + LBit);
  end;
  Inc(AState.X);
  if AState.X > AState.MaxX then AState.MaxX := AState.X;
end;

function _ReadIntToken(const AData: RawByteString; var APos: Integer): Integer;
// Reads a non-negative decimal integer starting at APos; advances APos past
// the digits. Returns 0 when no digits present at APos.
var
  LStart: Integer;
  LCh: AnsiChar;
begin
  Result := 0;
  LStart := APos;
  while APos <= Length(AData) do
  begin
    LCh := AData[APos];
    if (LCh < '0') or (LCh > '9') then Break;
    Result := Result * 10 + (Ord(LCh) - Ord('0'));
    Inc(APos);
  end;
  if APos = LStart then
    Result := 0;
end;

procedure _ParsePaletteDef(var AState: TSixelState;
  const AData: RawByteString; var APos: Integer);
// On entry APos points one past the leading `#`. Reads `n` then, if `;`
// follows, parses the colour-system byte plus three channel params. `#n`
// alone selects palette entry n as the current colour; `#n;2;R;G;B` is RGB
// percentages 0..100; `#n;1;H;L;S` is HLS per BR2. Anything malformed is
// swallowed without raising.
var
  LN, LMode, LP1, LP2, LP3: Integer;
  LR, LG, LB: Byte;
begin
  LN := _ReadIntToken(AData, APos);
  if (APos > Length(AData)) or (AData[APos] <> ';') then
  begin
    if (LN >= 0) and (LN <= 255) then
      AState.CurrentColor := LN;
    Exit;
  end;
  Inc(APos);
  LMode := _ReadIntToken(AData, APos);
  if (APos > Length(AData)) or (AData[APos] <> ';') then Exit;
  Inc(APos);
  LP1 := _ReadIntToken(AData, APos);
  if (APos > Length(AData)) or (AData[APos] <> ';') then Exit;
  Inc(APos);
  LP2 := _ReadIntToken(AData, APos);
  if (APos > Length(AData)) or (AData[APos] <> ';') then Exit;
  Inc(APos);
  LP3 := _ReadIntToken(AData, APos);
  if (LN < 0) or (LN > 255) then Exit;
  case LMode of
    2:
      begin
        LR := _ClampByte(Round(LP1 * 2.55));
        LG := _ClampByte(Round(LP2 * 2.55));
        LB := _ClampByte(Round(LP3 * 2.55));
      end;
    1:
      _HlsToRgb(LP1, LP2, LP3, LR, LG, LB);
  else
    Exit;
  end;
  AState.Palette[LN].R := LR;
  AState.Palette[LN].G := LG;
  AState.Palette[LN].B := LB;
  AState.Palette[LN].A := 255;
  AState.CurrentColor := LN;
end;

procedure _ParseRepeat(var AState: TSixelState;
  const AData: RawByteString; var APos: Integer);
// On entry APos points one past the `!`. Reads the count and then the next
// byte; if that byte is a sixel character (63..126) emits the column AValue
// times. Repeat count 0 is a no-op (BR4). Non-sixel follow-byte makes the
// whole introducer a no-op — the byte is still consumed so the outer loop
// does not re-scan it as a top-level token.
var
  LCount, LFor: Integer;
  LCh: AnsiChar;
  LValue: Byte;
begin
  LCount := _ReadIntToken(AData, APos);
  if APos > Length(AData) then Exit;
  LCh := AData[APos];
  Inc(APos);
  if (Ord(LCh) < 63) or (Ord(LCh) > 126) then Exit;
  if LCount <= 0 then Exit;
  LValue := Byte(Ord(LCh) - 63);
  for LFor := 1 to LCount do
  begin
    if AState.Capped then Exit;
    _EmitColumn(AState, LValue);
  end;
end;

function _AssembleBgra(const AState: TSixelState;
  const AWidth, AHeight: Integer): TArray<Byte>;
// Flattens the variable-width row list into a contiguous W*H*4 BGRA array.
// Rows shorter than W (a column emitted in a later band but not this one)
// pad with zero — fully transparent — which matches the Sixel default
// (untouched cells stay transparent regardless of palette 0).
var
  LRow: TBytes;
  LRowIdx, LCopy: Integer;
begin
  if (AWidth <= 0) or (AHeight <= 0) then Exit(nil);
  SetLength(Result, AWidth * AHeight * 4);
  for LRowIdx := 0 to AHeight - 1 do
  begin
    if LRowIdx >= AState.Rows.Count then Break;
    LRow := AState.Rows[LRowIdx];
    if Length(LRow) = 0 then Continue;
    LCopy := Length(LRow);
    if LCopy > AWidth * 4 then LCopy := AWidth * 4;
    Move(LRow[0], Result[LRowIdx * AWidth * 4], LCopy);
  end;
end;

class function TSixelDecoder.Decode(const AData: RawByteString;
  out AWidth, AHeight: Integer): TArray<Byte>;
var
  LState: TSixelState;
  LPos: Integer;
  LCh: AnsiChar;
  LCode: Integer;
begin
  AWidth := 0;
  AHeight := 0;
  Result := nil;
  if Length(AData) = 0 then Exit;
  if Length(AData) > SIXEL_RAW_CAP then Exit;

  LState.Rows := TList<TBytes>.Create;
  try
    _InitPalette(LState.Palette);
    LState.CurrentColor := 0;
    LState.X := 0;
    LState.SixelLineY := 0;
    LState.MaxX := 0;
    LState.MaxLineY := 0;
    LState.HasData := False;
    LState.Capped := False;

    LPos := 1;
    while LPos <= Length(AData) do
    begin
      if LState.Capped then Break;
      LCh := AData[LPos];
      LCode := Ord(LCh);
      case LCh of
        '#':
          begin
            Inc(LPos);
            _ParsePaletteDef(LState, AData, LPos);
          end;
        '!':
          begin
            Inc(LPos);
            _ParseRepeat(LState, AData, LPos);
          end;
        '$':
          begin
            LState.X := 0;
            Inc(LPos);
          end;
        '-':
          begin
            Inc(LState.SixelLineY, 6);
            LState.X := 0;
            Inc(LPos);
          end;
      else
        if (LCode >= 63) and (LCode <= 126) then
        begin
          _EmitColumn(LState, Byte(LCode - 63));
          Inc(LPos);
        end
        else
          Inc(LPos);
      end;
    end;

    if not LState.HasData then Exit;
    AWidth := LState.MaxX;
    AHeight := LState.MaxLineY + 6;
    if (AWidth <= 0) or (AHeight <= 0) then
    begin
      AWidth := 0;
      AHeight := 0;
      Exit;
    end;
    if NativeInt(AWidth) * NativeInt(AHeight) > SIXEL_MAX_PIXELS then
      AHeight := SIXEL_MAX_PIXELS div Max(AWidth, 1);
    Result := _AssembleBgra(LState, AWidth, AHeight);
  finally
    LState.Rows.Free;
  end;
end;

end.


