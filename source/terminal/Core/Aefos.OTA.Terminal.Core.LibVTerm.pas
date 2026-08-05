unit Aefos.OTA.Terminal.Core.LibVTerm;

{$IFDEF FPC}{$mode delphi}{$H+}{$ENDIF}

(*
  Delphi binding for libvterm - ESP-024 / Slice S2.

  The libvterm unity object is produced by running:
    Source\Terminal\ThirdParty\libvterm\build-objs.bat
  before building the package or test project. The L-link directive below
  uses a path relative to this unit file's directory (Source\Terminal\Core\).

  Unity build: all 9 libvterm translation units are compiled into a single
  libvterm_unity.obj to eliminate circular cross-references that Delphi's
  single-pass {$L} linker cannot resolve when objects are linked separately.

  CRT shim: the interface section below provides Delphi stubs for the
  external C-runtime symbols the libvterm object references. With Win32
  cdecl calling convention, bcc32c emits EXTDEF records as '_name'.
  Delphi satisfies these by declaring interface-section functions whose
  Delphi symbol (prefixed with '_' in OMF) matches exactly: '_malloc' etc.
*)

interface

(* libvterm binding differs by compiler:

   * Delphi (BPL) links the bcc32c OMF unity object STATICALLY via the L-directive
     below. A design BPL links its own OMF at load with no downstream rebuild, so
     static is fine; the hand-written CRT shims below satisfy libvterm's
     malloc/snprintf/... references.

   * FPC (Lazarus) binds libvterm as a RUNTIME DLL (external 'libvterm.dll', in the
     entry points below) -- NOT a static link. A static object link makes
     lazarus.exe non-rebuildable by the normal Package > Install/Uninstall path (the
     relative ..\ThirdParty path does not resolve from C:\lazarus\ide, and the object
     drags the mingw UCRT import libs into the IDE link). That is the exact lesson
     SQLite taught (source\lazarus\data\Aefos.Lazarus.SQLite.pas -> sqlite3.dll at
     runtime). The DLL bundles its own CRT, so the IDE link has ZERO C dependencies.
     It is produced by scripts\build-libvterm-fpc.ps1 and shipped beside lazarus.exe. *)
{$IFNDEF FPC}
  {$L '..\ThirdParty\libvterm\obj\libvterm_unity.obj'}
{$ENDIF}

{$IFDEF FPC}
const
  { The runtime libvterm DLL FPC imports every vterm_* entry point from. }
  cLibVTerm = 'libvterm.dll';
{$ENDIF}

const
  VTERM_MAX_CHARS_PER_CELL = 6;

  { VTermColor.colorType flags }
  VTERM_COLOR_RGB          = $00;
  VTERM_COLOR_INDEXED      = $01;
  VTERM_COLOR_TYPE_MASK    = $01;
  VTERM_COLOR_DEFAULT_FG   = $02;
  VTERM_COLOR_DEFAULT_BG   = $04;
  VTERM_COLOR_DEFAULT_MASK = $06;

  { VTermScreenCellAttrs bit masks }
  VTERM_CELL_BOLD_MASK      = $00000001;
  VTERM_CELL_UNDERLINE_MASK   = $00000006;
  VTERM_CELL_UNDERLINE_SINGLE = $00000002;
  VTERM_CELL_ITALIC_MASK    = $00000008;
  VTERM_CELL_BLINK_MASK     = $00000010;
  VTERM_CELL_REVERSE_MASK   = $00000020;
  VTERM_CELL_CONCEAL_MASK   = $00000040;
  VTERM_CELL_STRIKE_MASK    = $00000080;
  VTERM_CELL_FONT_MASK      = $00000F00;
  VTERM_CELL_DWL_MASK       = $00001000;
  VTERM_CELL_DHL_MASK       = $00006000;
  VTERM_CELL_SMALL_MASK     = $00008000;
  VTERM_CELL_BASELINE_MASK  = $00030000;

  { VTermDamageSize }
  VTERM_DAMAGE_CELL   = 0;
  VTERM_DAMAGE_ROW    = 1;
  VTERM_DAMAGE_SCREEN = 2;
  VTERM_DAMAGE_SCROLL = 3;

  { VTermModifier flags }
  VTERM_MOD_NONE  = $00;
  VTERM_MOD_SHIFT = $01;
  VTERM_MOD_ALT   = $02;
  VTERM_MOD_CTRL  = $04;

  { VTermKey constants (from vterm_keycodes.h) }
  VTERM_KEY_NONE      = 0;
  VTERM_KEY_ENTER     = 1;
  VTERM_KEY_TAB       = 2;
  VTERM_KEY_BACKSPACE = 3;
  VTERM_KEY_ESCAPE    = 4;
  VTERM_KEY_UP        = 5;
  VTERM_KEY_DOWN      = 6;
  VTERM_KEY_LEFT      = 7;
  VTERM_KEY_RIGHT     = 8;
  VTERM_KEY_INS       = 9;
  VTERM_KEY_DEL       = 10;
  VTERM_KEY_HOME      = 11;
  VTERM_KEY_END       = 12;
  VTERM_KEY_PAGEUP    = 13;
  VTERM_KEY_PAGEDOWN  = 14;
  VTERM_KEY_FUNCTION_0 = 256;
  VTERM_KEY_KP_0      = 512;
  VTERM_KEY_KP_ENTER  = 529;

type
  { Opaque libvterm handles — never dereferenced from Delphi }
  PVTerm       = Pointer;
  PVTermState  = Pointer;
  PVTermScreen = Pointer;

  TVTermDamageSize = Integer;
  TVTermModifier   = Integer;
  TVTermKey        = Integer;

  { TVTermPos — row/col screen coordinate (matches C VTermPos) }
  TVTermPos = record
    row: Integer;
    col: Integer;
  end;
  PVTermPos = ^TVTermPos;

  { TVTermRect — rectangular region (matches C VTermRect) }
  TVTermRect = record
    start_row: Integer;
    end_row:   Integer;
    start_col: Integer;
    end_col:   Integer;
  end;
  PVTermRect = ^TVTermRect;

  { TVTermColor — 4-byte packed union (RGB or palette index) }
  TVTermColor = packed record
    case Integer of
      0: (colorType: Byte; red: Byte; green: Byte; blue: Byte);
      1: (dummy: Byte; idx: Byte);
  end;
  PVTermColor = ^TVTermColor;

  { TVTermProp — terminal property identifiers (matches C VTermProp enum) }
  TVTermProp = (
    vtpNone          = 0,
    vtpCursorVisible = 1,
    vtpCursorBlink   = 2,
    vtpAltScreen     = 3,
    vtpTitle         = 4,
    vtpIconName      = 5,
    vtpReverse       = 6,
    vtpCursorShape   = 7,
    vtpMouse         = 8,
    vtpFocusReport   = 9
  );

  { TVTermStringFragment — VT string fragment (8 bytes: ptr + len/flags bitfield) }
  TVTermStringFragment = packed record
    str: PAnsiChar;
    len_flags: LongWord;
  end;
  PVTermStringFragment = ^TVTermStringFragment;

  { TVTermValue — union used in settermprop callbacks (8 bytes) }
  TVTermValue = record
    case Integer of
      0: (boolean:    Integer);
      1: (number:     Integer);
      2: (stringFrag: TVTermStringFragment);
      3: (color:      TVTermColor);
  end;
  PVTermValue = ^TVTermValue;

  { TVTermScreenCellAttrs — C packed bitfield stored as a 32-bit word }
  TVTermScreenCellAttrs = LongWord;

  { TVTermScreenCell — one rendered terminal cell (40 bytes on Win32) }
  TVTermScreenCell = packed record
    chars: array[0..VTERM_MAX_CHARS_PER_CELL - 1] of LongWord;
    width: AnsiChar;
    _pad:  array[0..2] of Byte;
    attrs: TVTermScreenCellAttrs;
    fg:    TVTermColor;
    bg:    TVTermColor;
  end;
  PVTermScreenCell = ^TVTermScreenCell;

  { TVTermLineInfo — per-row line metadata (matches C VTermLineInfo at
    vterm.h:298–304). The C type uses a 4-bit bitfield over a single LongWord;
    bcc32c emits the four flags as bits 0..3 of the first word. Bit 0
    `doublewidth`, bit 1 `doubleheight_top`, bit 2 `doubleheight_bottom`,
    bit 3 `continuation`. ESP-034 / ADR-034-01. }
  TVTermLineInfo = packed record
    Flags: LongWord;
  end;
  PVTermLineInfo = ^TVTermLineInfo;

  { Callback signatures for TVTermScreenCallbacks (all cdecl) }
  TVTermScreenDamageCallback   = function(rect: TVTermRect; user: Pointer): Integer; cdecl;
  TVTermMoveRectCallback       = function(dest: TVTermRect; src: TVTermRect; user: Pointer): Integer; cdecl;
  TVTermMoveCursorCallback     = function(pos: TVTermPos; oldpos: TVTermPos; visible: Integer; user: Pointer): Integer; cdecl;
  TVTermSetTermPropCallback    = function(prop: TVTermProp; val: PVTermValue; user: Pointer): Integer; cdecl;
  TVTermBellCallback           = function(user: Pointer): Integer; cdecl;
  TVTermScreenResizeCallback   = function(rows: Integer; cols: Integer; user: Pointer): Integer; cdecl;
  TVTermSbPushLineCallback     = function(cols: Integer; cells: PVTermScreenCell; user: Pointer): Integer; cdecl;
  TVTermSbPopLineCallback      = function(cols: Integer; cells: PVTermScreenCell; user: Pointer): Integer; cdecl;
  TVTermSbClearCallback        = function(user: Pointer): Integer; cdecl;
  { sb_pushline4 carries the flow-continuation bit alongside the cells (vterm.h:549).
    libvterm dispatches this in preference to sb_pushline when both are wired.
    ESP-034 / ADR-034-01. }
  TVTermSbPushLine4Callback    = function(cols: Integer; cells: PVTermScreenCell;
    continuation: Integer; user: Pointer): Integer; cdecl;

  { TVTermScreenCallbacks — passed by pointer to vterm_screen_set_callbacks (40 bytes) }
  TVTermScreenCallbacks = record
    damage:      TVTermScreenDamageCallback;
    moverect:    TVTermMoveRectCallback;
    movecursor:  TVTermMoveCursorCallback;
    settermprop: TVTermSetTermPropCallback;
    bell:        TVTermBellCallback;
    resize:      TVTermScreenResizeCallback;
    sb_pushline: TVTermSbPushLineCallback;
    sb_popline:  TVTermSbPopLineCallback;
    sb_clear:    TVTermSbClearCallback;
    sb_pushline4: TVTermSbPushLine4Callback;
  end;
  PVTermScreenCallbacks = ^TVTermScreenCallbacks;

  { Output callback type — called when libvterm encodes a keyboard/mouse response }
  TVTermOutputCallback = procedure(const s: PAnsiChar; len: NativeUInt; user: Pointer); cdecl;

  { OSC fallback callback — invoked by libvterm when on_osc encounters a command
    code outside the built-in handled set (0/1/2/52). Aefos.OTA.Terminal uses this to
    observe OSC 8 (clickable hyperlinks) per ESP-033 / ADR-033-01. The fragment
    is passed by value; its len_flags carries the length (bits 0..29), the
    `initial` bit (30) and the `final` bit (31), matching the existing
    TVTermStringFragment encoding used by settermprop. }
  TVTermOscFallback = function(ACommand: Integer; AFrag: TVTermStringFragment;
    AUser: Pointer): Integer; cdecl;

  { DCS fallback callback — invoked by libvterm when the state parser
    encounters a DCS sequence whose command byte is not handled internally.
    ACommand points to intermediate bytes + the final byte (e.g. 'q' for
    Sixel); ACommandLen is the byte count of that string. AFrag is dispatched
    once or more — its len_flags `initial` (bit 30) and `final` (bit 31)
    bits mark stream boundaries the same way OSC fragments do.
    ESP-035 / ADR-035-01. }
  TVTermDcsFallback = function(ACommand: PAnsiChar; ACommandLen: NativeUInt;
    AFrag: TVTermStringFragment; AUser: Pointer): Integer; cdecl;

  { TVTermStateFallbacks — table of "unrecognised" callbacks libvterm dispatches
    when its built-in handlers do not consume a control/CSI/OSC/DCS/APC/PM/SOS
    sequence. Layout mirrors the C struct in libvterm's vterm.h (7 function
    pointers). Aefos.OTA.Terminal fills the `osc` slot for ESP-033 and the `dcs` slot
    for ESP-035; the remaining five stay nil and libvterm safely no-ops them.

    On Win32: SizeOf(TVTermStateFallbacks) = 7 * SizeOf(Pointer) = 28 bytes —
    asserted by Aefos.OTA.Terminal.Core.TestLibVTerm.TestStateFallbacksLayout. The `dcs`
    slot sits at offset 3 * SizeOf(Pointer) = 12 — asserted by
    TestDcsFallbackLayout (ESP-035 / AC13). }
  TVTermStateFallbacks = packed record
    control: Pointer;
    csi:     Pointer;
    osc:     TVTermOscFallback;
    dcs:     TVTermDcsFallback;
    apc:     Pointer;
    pm:      Pointer;
    sos:     Pointer;
  end;
  PVTermStateFallbacks = ^TVTermStateFallbacks;

{ ---- libvterm lifecycle ---- }

function  vterm_new(rows: Integer; cols: Integer): PVTerm; cdecl; {$IFDEF FPC}external cLibVTerm name 'vterm_new';{$ELSE}external name '_vterm_new';{$ENDIF}
procedure vterm_free(vt: PVTerm); cdecl; {$IFDEF FPC}external cLibVTerm name 'vterm_free';{$ELSE}external name '_vterm_free';{$ENDIF}
procedure vterm_get_size(vt: PVTerm; rowsp: PInteger; colsp: PInteger); cdecl; {$IFDEF FPC}external cLibVTerm name 'vterm_get_size';{$ELSE}external name '_vterm_get_size';{$ENDIF}
procedure vterm_set_size(vt: PVTerm; rows: Integer; cols: Integer); cdecl; {$IFDEF FPC}external cLibVTerm name 'vterm_set_size';{$ELSE}external name '_vterm_set_size';{$ENDIF}
procedure vterm_set_utf8(vt: PVTerm; is_utf8: Integer); cdecl; {$IFDEF FPC}external cLibVTerm name 'vterm_set_utf8';{$ELSE}external name '_vterm_set_utf8';{$ENDIF}

{ ---- input ---- }

function  vterm_input_write(vt: PVTerm; bytes: PAnsiChar; len: NativeUInt): NativeUInt; cdecl; {$IFDEF FPC}external cLibVTerm name 'vterm_input_write';{$ELSE}external name '_vterm_input_write';{$ENDIF}

{ ---- output callback ---- }

procedure vterm_output_set_callback(vt: PVTerm; func: TVTermOutputCallback; user: Pointer); cdecl; {$IFDEF FPC}external cLibVTerm name 'vterm_output_set_callback';{$ELSE}external name '_vterm_output_set_callback';{$ENDIF}

{ ---- screen layer ---- }

function  vterm_obtain_screen(vt: PVTerm): PVTermScreen; cdecl; {$IFDEF FPC}external cLibVTerm name 'vterm_obtain_screen';{$ELSE}external name '_vterm_obtain_screen';{$ENDIF}
procedure vterm_screen_reset(screen: PVTermScreen; hard: Integer); cdecl; {$IFDEF FPC}external cLibVTerm name 'vterm_screen_reset';{$ELSE}external name '_vterm_screen_reset';{$ENDIF}
procedure vterm_screen_enable_altscreen(screen: PVTermScreen; altscreen: Integer); cdecl; {$IFDEF FPC}external cLibVTerm name 'vterm_screen_enable_altscreen';{$ELSE}external name '_vterm_screen_enable_altscreen';{$ENDIF}
function  vterm_screen_get_cell(screen: PVTermScreen; pos: TVTermPos; cell: PVTermScreenCell): Integer; cdecl; {$IFDEF FPC}external cLibVTerm name 'vterm_screen_get_cell';{$ELSE}external name '_vterm_screen_get_cell';{$ENDIF}
procedure vterm_screen_set_callbacks(screen: PVTermScreen; callbacks: PVTermScreenCallbacks; user: Pointer); cdecl; {$IFDEF FPC}external cLibVTerm name 'vterm_screen_set_callbacks';{$ELSE}external name '_vterm_screen_set_callbacks';{$ENDIF}
procedure vterm_screen_flush_damage(screen: PVTermScreen); cdecl; {$IFDEF FPC}external cLibVTerm name 'vterm_screen_flush_damage';{$ELSE}external name '_vterm_screen_flush_damage';{$ENDIF}
procedure vterm_screen_set_damage_merge(screen: PVTermScreen; size: TVTermDamageSize); cdecl; {$IFDEF FPC}external cLibVTerm name 'vterm_screen_set_damage_merge';{$ELSE}external name '_vterm_screen_set_damage_merge';{$ENDIF}
procedure vterm_screen_convert_color_to_rgb(screen: PVTermScreen; col: PVTermColor); cdecl; {$IFDEF FPC}external cLibVTerm name 'vterm_screen_convert_color_to_rgb';{$ELSE}external name '_vterm_screen_convert_color_to_rgb';{$ENDIF}
procedure vterm_screen_set_unrecognised_fallbacks(screen: PVTermScreen; fallbacks: PVTermStateFallbacks; user: Pointer); cdecl; {$IFDEF FPC}external cLibVTerm name 'vterm_screen_set_unrecognised_fallbacks';{$ELSE}external name '_vterm_screen_set_unrecognised_fallbacks';{$ENDIF}
{ Opt-in flag for v4 push-line dispatch. libvterm only dispatches sb_pushline4
  after this is called — vterm_screen_set_callbacks alone leaves it on v3.
  ESP-034 / ADR-034-01. }
procedure vterm_screen_callbacks_has_pushline4(screen: PVTermScreen); cdecl; {$IFDEF FPC}external cLibVTerm name 'vterm_screen_callbacks_has_pushline4';{$ELSE}external name '_vterm_screen_callbacks_has_pushline4';{$ENDIF}

{ ---- state layer ---- }

function  vterm_obtain_state(vt: PVTerm): PVTermState; cdecl; {$IFDEF FPC}external cLibVTerm name 'vterm_obtain_state';{$ELSE}external name '_vterm_obtain_state';{$ENDIF}
procedure vterm_state_get_cursorpos(state: PVTermState; cursorpos: PVTermPos); cdecl; {$IFDEF FPC}external cLibVTerm name 'vterm_state_get_cursorpos';{$ELSE}external name '_vterm_state_get_cursorpos';{$ENDIF}
{ vterm_state_get_lineinfo: returns a pointer into state->lineinfos[0][row]
  for the currently-visible grid. The returned pointer stays valid until the
  next vterm_set_size / vterm_state_reset. ESP-034 / ADR-034-01. }
function  vterm_state_get_lineinfo(state: PVTermState; row: Integer): PVTermLineInfo; cdecl; {$IFDEF FPC}external cLibVTerm name 'vterm_state_get_lineinfo';{$ELSE}external name '_vterm_state_get_lineinfo';{$ENDIF}

{ ---- keyboard input ---- }

procedure vterm_keyboard_unichar(vt: PVTerm; c: LongWord; mod_: TVTermModifier); cdecl; {$IFDEF FPC}external cLibVTerm name 'vterm_keyboard_unichar';{$ELSE}external name '_vterm_keyboard_unichar';{$ENDIF}
procedure vterm_keyboard_key(vt: PVTerm; key: TVTermKey; mod_: TVTermModifier); cdecl; {$IFDEF FPC}external cLibVTerm name 'vterm_keyboard_key';{$ELSE}external name '_vterm_keyboard_key';{$ENDIF}

{ ---- mouse input ----
  Declared for API completeness. ESP-032 / ADR-032-01 encodes mouse output in
  Pascal (see Aefos.OTA.Terminal.Core.MouseEncode) and uses libvterm only as an observer of
  the DEC mode level. These bindings remain unused so a future demand (e.g.
  pixel-resolution `?1016`) can flip the architecture without rebinding. }

procedure vterm_mouse_move(vt: PVTerm; row: Integer; col: Integer; mod_: TVTermModifier); cdecl; {$IFDEF FPC}external cLibVTerm name 'vterm_mouse_move';{$ELSE}external name '_vterm_mouse_move';{$ENDIF}
procedure vterm_mouse_button(vt: PVTerm; button: Integer; pressed: Integer; mod_: TVTermModifier); cdecl; {$IFDEF FPC}external cLibVTerm name 'vterm_mouse_button';{$ELSE}external name '_vterm_mouse_button';{$ENDIF}

{ ---- CRT shims (interface section) ----
  bcc32c emits EXTDEF records as '_name'. Delphi resolves these by looking
  for a PUBLIC symbol named '_name'. A cdecl function 'foo' declared in the
  Delphi interface section is exported as '_foo' in OMF, so we declare the
  shims with the underscore already in the Delphi name.
  FPC does NOT need these: libvterm.dll bundles its own mingw UCRT (the DLL is
  self-contained), so the whole shim block is Delphi-only. }

{$IFNDEF FPC}
function  _malloc(ASize: NativeUInt): Pointer; cdecl;
procedure _free(APtr: Pointer); cdecl;
function  _memcpy(ADest, ASrc: Pointer; ACount: NativeUInt): Pointer; cdecl;
function  _memmove(ADest, ASrc: Pointer; ACount: NativeUInt): Pointer; cdecl;
function  _memset(APtr: Pointer; AValue: Integer; ACount: NativeUInt): Pointer; cdecl;
function  _strncmp(AS1, AS2: PAnsiChar; ACount: NativeUInt): Integer; cdecl;
function  _strncpy(ADest, ASrc: PAnsiChar; ACount: NativeUInt): PAnsiChar; cdecl;
function  _abs(AValue: Integer): Integer; cdecl;
procedure _abort; cdecl;
procedure _exit(ACode: Integer); cdecl;
function  _snprintf(AStr: PAnsiChar; ASize: NativeUInt; AFmt: PAnsiChar): Integer; cdecl;
function  _vsnprintf(AStr: PAnsiChar; ASize: NativeUInt; AFmt: PAnsiChar; AArgs: Pointer): Integer; cdecl;
function  _fprintf(AStream: Pointer; AFmt: PAnsiChar): Integer; cdecl;
function  ___get_std_stream(AIndex: Integer): Pointer; cdecl;
{$ENDIF}

implementation

{$IFNDEF FPC}
{ CRT shim implementations (Delphi-only; FPC uses the mingw UCRT) ------------ }

function _malloc(ASize: NativeUInt): Pointer; cdecl;
begin
  GetMem(Result, ASize);
end;

procedure _free(APtr: Pointer); cdecl;
begin
  if APtr <> nil then
    FreeMem(APtr);
end;

function _memcpy(ADest, ASrc: Pointer; ACount: NativeUInt): Pointer; cdecl;
begin
  Move(ASrc^, ADest^, ACount);
  Result := ADest;
end;

function _memmove(ADest, ASrc: Pointer; ACount: NativeUInt): Pointer; cdecl;
begin
  Move(ASrc^, ADest^, ACount);
  Result := ADest;
end;

function _memset(APtr: Pointer; AValue: Integer; ACount: NativeUInt): Pointer; cdecl;
begin
  FillChar(APtr^, ACount, Byte(AValue));
  Result := APtr;
end;

function _strncmp(AS1, AS2: PAnsiChar; ACount: NativeUInt): Integer; cdecl;
var
  LIndex: NativeUInt;
begin
  LIndex := 0;
  while LIndex < ACount do
  begin
    if Byte(AS1[LIndex]) <> Byte(AS2[LIndex]) then
    begin
      Result := Integer(Byte(AS1[LIndex])) - Integer(Byte(AS2[LIndex]));
      Exit;
    end;
    if AS1[LIndex] = #0 then
      Break;
    Inc(LIndex);
  end;
  Result := 0;
end;

function _strncpy(ADest, ASrc: PAnsiChar; ACount: NativeUInt): PAnsiChar; cdecl;
var
  LIndex: NativeUInt;
begin
  LIndex := 0;
  while (LIndex < ACount) and (ASrc[LIndex] <> #0) do
  begin
    ADest[LIndex] := ASrc[LIndex];
    Inc(LIndex);
  end;
  while LIndex < ACount do
  begin
    ADest[LIndex] := #0;
    Inc(LIndex);
  end;
  Result := ADest;
end;

function _abs(AValue: Integer): Integer; cdecl;
begin
  if AValue < 0 then
    Result := -AValue
  else
    Result := AValue;
end;

{ abort and exit are called only in unreachable libvterm error paths }

procedure _abort; cdecl;
begin
  Halt(1);
end;

procedure _exit(ACode: Integer); cdecl;
begin
  Halt(ACode);
end;

{ snprintf/vsnprintf/fprintf: stub implementations that silence error output.
  libvterm calls these only for diagnostics; returning 0 / empty string is safe. }

function _snprintf(AStr: PAnsiChar; ASize: NativeUInt; AFmt: PAnsiChar): Integer; cdecl;
begin
  if ASize > 0 then
    AStr[0] := #0;
  Result := 0;
end;

function _vsnprintf(AStr: PAnsiChar; ASize: NativeUInt; AFmt: PAnsiChar; AArgs: Pointer): Integer; cdecl;
begin
  if ASize > 0 then
    AStr[0] := #0;
  Result := 0;
end;

function _fprintf(AStream: Pointer; AFmt: PAnsiChar): Integer; cdecl;
begin
  Result := 0;
end;

{ Clang internal helper referenced by fprintf — returns nil since fprintf is stubbed }
function ___get_std_stream(AIndex: Integer): Pointer; cdecl;
begin
  Result := nil;
end;
{$ENDIF}

end.


