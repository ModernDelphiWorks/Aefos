unit Aefos.OTA.Terminal.Core.MouseEncode;

(*
  Pure VCL-free mouse-event encoder - ESP-032 / E3.D1 S1.

  Owns the X10 and SGR (?1006) wire formats for xterm-style mouse reporting,
  plus pure helpers consumed by the canvas wiring (TerminalCanvas). libvterm
  is *not* used to encode mouse output (ADR-032-01: Pascal-only encoder; the
  bindings vterm_mouse_move / vterm_mouse_button stay observer-only).

  Modifier encoding mirrors the keyboard path: callers pass a VTERM_MOD_*
  bitmask via ShiftStateToVTermMod; this unit translates to the xterm
  Cb bits (Shift=4, Alt=8, Ctrl=16) internally.
*)

interface

uses
  System.SysUtils, System.Classes;

type
  /// <summary>Pure mouse-event encoder grouped as a stateless facade. Every
  /// member is a class-static function — no instance is ever created.</summary>
  TMouseEncoder = class sealed
  public
    /// <summary>
    /// Builds one xterm mouse CSI for the given event. ARow / ACol are 0-based
    /// (the encoder adds 1 to match the wire convention). AButton is 0/1/2 for
    /// left/middle/right; for X10 release the helper substitutes 3 regardless
    /// of the value passed. Wheel events pass 64 (up) or 65 (down) with
    /// APressed=True. AMod is a VTERM_MOD_* bitmask (see Aefos.OTA.Terminal.Core.LibVTerm).
    /// </summary>
    class function EncodeMouseEvent(const AButton, ARow, ACol, AMod: Integer;
      const APressed, AMotion, ASgr: Boolean): TBytes; static;

    /// <summary>Maps a VCL TShiftState to the VTERM_MOD_* bitmask.</summary>
    class function ShiftStateToVTermMod(const AShift: TShiftState): Integer; static;

    /// <summary>True when the new cell differs from the last emitted cell.</summary>
    class function ShouldEmitMotion(const ALastRow, ALastCol,
      ANewRow, ANewCol: Integer): Boolean; static;

    /// <summary>True when a mouse event must be forwarded to the PTY instead of
    /// running the canvas selection path. Routes only when the program has
    /// requested mouse reporting (level &gt; 0) and Shift is not held.</summary>
    class function ShouldRouteToBuffer(const AMouseLevel: Integer;
      const AShift: TShiftState): Boolean; static;
  end;

implementation

uses
  Aefos.OTA.Terminal.Core.LibVTerm;

const
  CESC      = $1B;
  CX10_BASE = 32;  // X10 byte offset (every encoded byte is rebased by +32).
  CMOTION   = 32;  // X10/SGR motion bit (`Cb` adds 32 when reporting motion).
  CCB_MAX   = 255; // X10 caps each byte at 0xFF (col/row > 222 are unreachable).
  CRELEASE_X10 = 3; // X10 uses fixed button code 3 for every release.

function _ModifierBits(const AMod: Integer): Integer;
begin
  Result := 0;
  if (AMod and VTERM_MOD_SHIFT) <> 0 then
    Result := Result or 4;
  if (AMod and VTERM_MOD_ALT) <> 0 then
    Result := Result or 8;
  if (AMod and VTERM_MOD_CTRL) <> 0 then
    Result := Result or 16;
end;

function _ClampX10(const AValue: Integer): Byte;
begin
  if AValue < 0 then
    Result := 0
  else if AValue > CCB_MAX then
    Result := CCB_MAX
  else
    Result := Byte(AValue);
end;

function _EncodeX10(const AButton, ARow, ACol, AMod: Integer;
  const APressed, AMotion: Boolean): TBytes;
var
  LButton, LCb, LCx, LCy: Integer;
begin
  if APressed then
    LButton := AButton
  else
    LButton := CRELEASE_X10;
  LCb := CX10_BASE + LButton + _ModifierBits(AMod);
  if AMotion then
    LCb := LCb + CMOTION;
  LCx := CX10_BASE + ACol + 1;
  LCy := CX10_BASE + ARow + 1;
  SetLength(Result, 6);
  Result[0] := CESC;
  Result[1] := Ord('[');
  Result[2] := Ord('M');
  Result[3] := _ClampX10(LCb);
  Result[4] := _ClampX10(LCx);
  Result[5] := _ClampX10(LCy);
end;

function _EncodeSgr(const AButton, ARow, ACol, AMod: Integer;
  const APressed, AMotion: Boolean): TBytes;
var
  LCb: Integer;
  LFinal: AnsiChar;
  LPayload: AnsiString;
  LLen: Integer;
begin
  LCb := AButton + _ModifierBits(AMod);
  if AMotion then
    LCb := LCb + CMOTION;
  if APressed then
    LFinal := 'M'
  else
    LFinal := 'm';
  LPayload := AnsiString(
    Format(#27'[<%d;%d;%d%s', [LCb, ACol + 1, ARow + 1, string(LFinal)]));
  LLen := Length(LPayload);
  SetLength(Result, LLen);
  if LLen > 0 then
    Move(LPayload[1], Result[0], LLen);
end;

class function TMouseEncoder.EncodeMouseEvent(const AButton, ARow, ACol, AMod: Integer;
  const APressed, AMotion, ASgr: Boolean): TBytes;
begin
  if ASgr then
    Result := _EncodeSgr(AButton, ARow, ACol, AMod, APressed, AMotion)
  else
    Result := _EncodeX10(AButton, ARow, ACol, AMod, APressed, AMotion);
end;

class function TMouseEncoder.ShiftStateToVTermMod(const AShift: TShiftState): Integer;
begin
  Result := VTERM_MOD_NONE;
  if ssShift in AShift then
    Result := Result or VTERM_MOD_SHIFT;
  if ssAlt in AShift then
    Result := Result or VTERM_MOD_ALT;
  if ssCtrl in AShift then
    Result := Result or VTERM_MOD_CTRL;
end;

class function TMouseEncoder.ShouldEmitMotion(const ALastRow, ALastCol,
  ANewRow, ANewCol: Integer): Boolean;
begin
  Result := (ANewRow <> ALastRow) or (ANewCol <> ALastCol);
end;

class function TMouseEncoder.ShouldRouteToBuffer(const AMouseLevel: Integer;
  const AShift: TShiftState): Boolean;
begin
  Result := (AMouseLevel > 0) and not (ssShift in AShift);
end;

end.


