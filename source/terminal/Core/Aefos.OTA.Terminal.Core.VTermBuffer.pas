unit Aefos.OTA.Terminal.Core.VTermBuffer;

{$IFDEF FPC}{$mode delphi}{$H+}{$ENDIF}

(*
  Screen-model adapter for libvterm - ESP-024 / Slice S3.

  TVTermBuffer wraps a libvterm VTerm + VTermScreen and exposes the same
  surface the from-scratch TScreenBuffer offered, so Aefos.OTA.Terminal.Core.TerminalHost
  and Aefos.OTA.Terminal.UI.TerminalCanvas can consume libvterm without knowing the C
  binding. Shell output bytes go in through Feed/FeedBytes; the canvas
  reads the cell grid, cursor and dirty rows back out.

  The libvterm damage callback drives dirty-row tracking and OnChange; the
  movecursor callback drives the cursor position; the settermprop callback
  drives the window title and cursor visibility; sb_pushline/sb_popline
  drive scrollback. All callbacks fire synchronously inside Feed/Resize
  while FLock is held - they never re-enter the lock.
*)

interface

uses
  {$IFDEF FPC}SysUtils, Math, SyncObjs,{$ELSE}System.SysUtils, System.Math, System.SyncObjs,{$ENDIF}
  {$IFDEF FPC}Generics.Collections, Aefos.Compat.Json,{$ELSE}System.Generics.Collections, System.JSON,{$ENDIF}
  Aefos.OTA.Terminal.Core.CellColor, Aefos.OTA.Terminal.Core.LibVTerm, Aefos.OTA.Terminal.Core.Hyperlink, Aefos.OTA.Terminal.Core.Reflow,
  Aefos.OTA.Terminal.Core.SixelDecode;

const
  /// <summary>Versioned payload tag for screen-buffer persistence.</summary>
  VTERMBUFFER_STATE_VERSION = 1;
  /// <summary>Maximum number of lines retained in scrollback.</summary>
  DEFAULT_SCROLLBACK_CAP = 5000;
  /// <summary>Codepoint for a blank cell (U+0020 space). TTerminalCell.Ch is
  /// now a UCS4Char scalar, so blank cells carry the space codepoint rather
  /// than a Char/WideChar space literal.</summary>
  cBlankCodepoint = UCS4Char(32);

type
  /// <summary>Re-exports for back-compat: TCellAttr / TCellAttrs /
  /// TTerminalCell / TTerminalRow moved to Aefos.OTA.Terminal.Core.CellColor under ESP-034
  /// so the pure Aefos.OTA.Terminal.Core.Reflow unit can reach them without pulling in
  /// libvterm. Consumers of this unit continue to read TVTermBuffer.Cell as
  /// TTerminalCell with no source change required.</summary>
  TBellEvent = procedure(Sender: TObject) of object;
  TTitleEvent = procedure(Sender: TObject; const ATitle: string) of object;
  TBufferChangeEvent = procedure(Sender: TObject) of object;

  /// <summary>
  /// A 2D cell-grid terminal screen model backed by libvterm. It feeds raw
  /// terminal output into libvterm and exposes the resulting cell grid,
  /// cursor, scrollback and dirty-row state. Pure logic - no UI dependency.
  /// </summary>
  /// <summary>Internal state of the DEC private mode scanner.</summary>
  TBracketPasteScanState = (
    bpsIdle,
    bpsEsc,
    bpsCsiStart,
    bpsCsiParams
  );

  /// <summary>Re-export: TScrollbackRow is owned by Aefos.OTA.Terminal.Core.Reflow (the
  /// pure unit) so its `cells + continuation` shape can be tested without
  /// libvterm. ESP-034 / ADR-034-02.</summary>

  /// <summary>One decoded Sixel image anchored to a buffer-grid position.
  /// Pixels is row-major BGRA (Length = Width * Height * 4). Anchor row/col
  /// are captured from `vterm_state_get_cursorpos` when the DCS `initial`
  /// fragment arrives — they stay frozen for the remainder of the body.
  /// ESP-035 / ADR-035-03.</summary>
  TSixelPlacement = record
    Pixels: TArray<Byte>;
    Width: Integer;
    Height: Integer;
    AnchorRow: Integer;
    AnchorCol: Integer;
  end;

  /// <summary>Default total BGRA budget for stored Sixel placements (~32
  /// MB). Tests may shrink this via SetSixelCapForTest to exercise the
  /// FIFO eviction path. ESP-035 / ADR-035-03 / BR8.</summary>
const
  DEFAULT_SIXEL_IMAGE_CAP = 32000000;

type
  /// <summary>Kind tag for the OSC 8 stream splitter (ADR-033-02).</summary>
  TFeedSegmentKind = (sfkText, sfkOsc8);

  /// <summary>One sub-burst produced by `_SplitFeedAtOsc8`.</summary>
  TFeedSegment = record
    Kind:  TFeedSegmentKind;
    Start: Integer;
    Len:   Integer;
  end;

  /// <summary>Internal state of the SGR mouse-mode scanner. Shape mirrors
  /// TBracketPasteScanState; the scanners are kept separate because their
  /// parameter sets differ (2004 vs 1006/1015) and the bracketed-paste
  /// scanner runs on every byte path.</summary>
  TMouseSgrScanState = (
    msIdle,
    msEsc,
    msCsiStart,
    msCsiParams
  );

  TVTermBuffer = class
  private
    FLock: TCriticalSection;
    FVTerm: PVTerm;
    FScreen: PVTermScreen;
    FCallbacks: TVTermScreenCallbacks;
    FCols: Integer;
    FRows: Integer;
    FCursorX: Integer;
    FCursorY: Integer;
    FCursorVisible: Boolean;
    FDirty: TArray<Boolean>;
    FScrollback: TList<TScrollbackRow>;
    FScrollbackCap: Integer;
    FTitle: string;
    FTitleBuf: string;
    FBracketedPasteEnabled: Boolean;
    FBpScanState: TBracketPasteScanState;
    FBpScanNum: Integer;
    FBpScanMatched: Boolean;
    FMouseLevel: Integer;
    FMouseSgrEnabled: Boolean;
    FMsScanState: TMouseSgrScanState;
    FMsScanNum: Integer;
    FMsScanSgr: Boolean;
    FMsScanUrxvt: Boolean;
    FMsScanLevelOff: Boolean;
    FState: PVTermState;
    FFallbacks: TVTermStateFallbacks;
    FUrlPool: TList<string>;
    FLinkRows: TArray<TList<TLinkRange> >;
    FScrollbackLinks: TList<TArray<TLinkRange> >;
    FCurrentLinkIdx: Integer;
    FOscBuf: TBytes;
    FSplitInOsc8: Boolean;
    FSplitPrevEsc: Boolean;
    FDcsAccumulator: RawByteString;
    FDcsAnchorRow: Integer;
    FDcsAnchorCol: Integer;
    FDcsActive: Boolean;
    FSixelImages: TList<TSixelPlacement>;
    FSixelImageCap: Integer;
    FOnBell: TBellEvent;
    FOnTitleChange: TTitleEvent;
    FOnChange: TBufferChangeEvent;
    procedure _SetupCallbacks;
    procedure _SetupOscFallback;
    procedure _ScanBracketedPaste(const AData: TBytes);
    procedure _ScanMouseSgrMode(const AData: TBytes);
    function  _SplitFeedAtOsc8(const AData: TBytes): TArray<TFeedSegment>;
    procedure _WriteRawBytes(const AData: TBytes; const AStart, ALen: Integer);
    procedure _RecordTextBurstLinks(const ABefore, AAfter: TVTermPos);
    function  _LookupUrlIdx(const AUrl: string): Integer;
    procedure _AppendOscFragment(const ABytes: TBytes);
    procedure _ClearAllLinks;
    procedure _ClearVisibleLinks;
    function  _SnapshotScrollback: TArray<TScrollbackRow>;
    function  _SnapshotScrollbackLinks: TArray<TArray<TLinkRange> >;
    procedure _ApplyReflowedScrollback(const ARows: TArray<TScrollbackRow>;
      const ALinks: TArray<TArray<TLinkRange> >);
    procedure _CapScrollbackToLimit;
    procedure _EnsureLinkRows(const ANewRows: Integer);
    procedure _MarkAllDirty;
    procedure _MarkDirtyRange(const AFrom, ATo: Integer);
    function _GetScrollbackCount: Integer;
    function _BlankCell: TTerminalCell;
    function _CodepointToChar(const ACodepoint: LongWord): UCS4Char;
    function _CodepointToUtf16(const ACodepoint: UCS4Char): UnicodeString;
    function _ConvertColor(const AColor: TVTermColor): TCellColor;
    function _ConvertAttrs(const AAttrs: TVTermScreenCellAttrs): TCellAttrs;
    function _ConvertCell(const ACell: TVTermScreenCell): TTerminalCell;
    function _CellColorToVTerm(const AColor: TCellColor): TVTermColor;
    function _AttrsToVTerm(const AAttrs: TCellAttrs): TVTermScreenCellAttrs;
    function _CellToVTerm(const ACell: TTerminalCell): TVTermScreenCell;
    function _ReadCell(const AX, AY: Integer): TTerminalCell;
    procedure _PushScrollbackRow(const ARow: TTerminalRow;
      const AContinuation: Boolean);
    function _SgrColor(const AColor: TCellColor; const AIsBg: Boolean): string;
    function _SgrFor(const ACell: TTerminalCell): string;
    function _DeserializeCell(const AArray: TJSONArray): TTerminalCell;
    function _SerializeGrid: TJSONArray;
    function _BuildRestoreText(const AGrid: TJSONArray;
      const ACurX, ACurY: Integer): string;
    procedure _HandleDamage(const ARect: TVTermRect);
    procedure _HandleMoveCursor(const APos: TVTermPos);
    procedure _HandleSetTermProp(const AProp: TVTermProp; const AVal: PVTermValue);
    procedure _ApplyTitleFragment(const AVal: PVTermValue);
    procedure _HandleBell;
    procedure _HandlePushLine(const ACols: Integer; const ACells: PVTermScreenCell;
      const AContinuation: Boolean);
    function _HandlePopLine(const ACols: Integer; const ACells: PVTermScreenCell): Integer;
    procedure _HandleSbClear;
    procedure _HandleOscFallback(const ACmd: Integer;
      const AFragBytes: TBytes; const AInitial, AFinal: Boolean);
    procedure _HandleDcsFallback(const ACommand: AnsiString;
      const AFragBytes: TBytes; const AInitial, AFinal: Boolean);
    procedure _StoreSixelDecoded(const AData: RawByteString);
    procedure _ClearSixelImages;
  public
    constructor Create(const ACols: Integer = 80; const ARows: Integer = 25);
    destructor Destroy; override;

    /// <summary>Feeds raw terminal output (UTF-8 encoded internally). Thread-safe.</summary>
    procedure Feed(const AText: string);
    /// <summary>Feeds raw terminal output bytes straight into libvterm. Thread-safe.</summary>
    procedure FeedBytes(const AData: TBytes);
    /// <summary>Resizes the grid and the underlying libvterm screen.</summary>
    procedure Resize(const ACols, ARows: Integer);
    /// <summary>Hard-resets the libvterm screen and clears scrollback.</summary>
    procedure Reset;
    /// <summary>Returns a copy of the cell at the given visible coordinates.</summary>
    function Cell(const AX, AY: Integer): TTerminalCell;
    /// <summary>Returns a copy of a scrollback cell (0 = oldest line).</summary>
    function ScrollbackCell(const ALine, AX: Integer): TTerminalCell;
    /// <summary>Returns the visible text of a grid row (no attributes).</summary>
    function RowText(const AY: Integer): string;
    /// <summary>Indices of rows changed since the last ClearDirty.</summary>
    function GetDirtyRows: TArray<Integer>;
    /// <summary>Marks all dirty rows as clean.</summary>
    procedure ClearDirty;
    /// <summary>Serializes the visible grid and cursor to a versioned JSON string.</summary>
    function SaveStateJSON: string;
    /// <summary>Restores state from SaveStateJSON. Returns False on version mismatch.</summary>
    function LoadStateJSON(const AJSON: string): Boolean;
    /// <summary>URL attached to the cell at (ACol, ARow), or '' when none.
    /// Reads from the per-row sparse link range list seeded by OSC 8
    /// dispatches (ESP-033 / ADR-033-02). Out-of-bounds inputs return ''.</summary>
    function GetLinkAt(const ACol, ARow: Integer): string;
    /// <summary>URL attached to the scrollback cell at (ALine, ACol), or
    /// '' when none. Mirrors GetLinkAt for the scrollback list reflowed in
    /// lockstep with FScrollbackLinks. ESP-034 §Scope item 5.</summary>
    function ScrollbackLinkAt(const ALine, ACol: Integer): string;
    /// <summary>True when the scrollback row at ALine was evicted as the
    /// flow-continuation of the previous scrollback row (libvterm's
    /// VTermLineInfo.continuation:1, captured via sb_pushline4 — see
    /// ESP-034 / ADR-034-01). Returns False on out-of-bounds ALine.</summary>
    function ScrollbackContinuation(const ALine: Integer): Boolean;
    /// <summary>Snapshot of the link ranges attached to the scrollback row
    /// at ALine. Returns an empty array on out-of-bounds ALine. Mirrors
    /// FLinkRows for the visible grid; reflowed in lockstep with
    /// FScrollback by Resize. ESP-034 / ADR-034-02.</summary>
    function ScrollbackLinkRanges(const ALine: Integer): TArray<TLinkRange>;
    {$IFDEF DEBUG}
    /// <summary>Test seam: replaces FScrollback + FScrollbackLinks with the
    /// supplied arrays under FLock. Used by the reflow buffer-level tests
    /// (TestReflowGrowJoinsContinuedRows..TestReflowRespectsCap) to seed a
    /// controlled scrollback shape without driving libvterm. Not a public
    /// API for production callers — see ESP-034 §Technical impact.
    /// ESP-045: gated behind {$IFDEF DEBUG} so the release BPL does not
    /// expose test-only hooks. BR1 hard gate.</summary>
    procedure SeedScrollbackForTest(const ARows: TArray<TScrollbackRow>;
      const ALinks: TArray<TArray<TLinkRange> >);
    /// <summary>Test seam: replaces FScrollbackCap with ACap (clamped to at
    /// least 1) and immediately trims FScrollback + FScrollbackLinks to the
    /// new cap. Lets TestReflowRespectsCap exercise the cap path without
    /// allocating 5000+ rows. ESP-045: gated behind {$IFDEF DEBUG}.</summary>
    procedure SetScrollbackCapForTest(const ACap: Integer);
    {$ENDIF}
    /// <summary>Snapshot copy of the stored Sixel placements. The caller
    /// receives an independent array; mutations on the returned slice do
    /// not affect the buffer. Snapshot is taken under FLock so the canvas
    /// can paint on the UI thread while the I/O thread keeps decoding.
    /// ESP-035 / ADR-035-03.</summary>
    function GetSixelImages: TArray<TSixelPlacement>;
    {$IFDEF DEBUG}
    /// <summary>Test seam: replaces FSixelImageCap with ACap (clamped to
    /// at least 1) and immediately evicts oldest placements until the
    /// running total fits. Not a production path — the canvas does not
    /// call this. Used by TestSixelCapEvictsOldest to exercise BR8 without
    /// having to decode 32 MB of fake images. ESP-045: gated behind
    /// {$IFDEF DEBUG} so the release BPL does not expose test-only hooks,
    /// matching SeedScrollbackForTest / SetScrollbackCapForTest.</summary>
    procedure SetSixelCapForTest(const ACap: Integer);
    {$ENDIF}

    property Cols: Integer read FCols;
    property Rows: Integer read FRows;
    property CursorX: Integer read FCursorX;
    property CursorY: Integer read FCursorY;
    property CursorVisible: Boolean read FCursorVisible;
    property ScrollbackCount: Integer read _GetScrollbackCount;
    property Title: string read FTitle;
    /// <summary>
    /// True while the foreground program has DEC private mode `?2004`
    /// (bracketed paste) enabled. Mirrors `state->mode.bracketpaste` inside
    /// libvterm — tracked locally by a small CSI scanner in FeedBytes because
    /// the engine does not expose this flag through any public symbol or
    /// callback.
    /// </summary>
    property BracketedPasteEnabled: Boolean read FBracketedPasteEnabled;
    /// <summary>
    /// DEC private mouse-tracking level surfaced by libvterm's vtpMouse
    /// settermprop: 0 = off, 1 = `?1000` X10, 2 = `?1002` button-event,
    /// 3 = `?1003` any-event. Updated whenever the foreground program toggles
    /// `?1000`/`?1002`/`?1003`. Read on the GUI thread; writes happen inside
    /// FeedBytes under FLock so a single 32-bit read is atomic on Win32.
    /// </summary>
    property MouseLevel: Integer read FMouseLevel;
    /// <summary>
    /// True while the foreground program has DEC private mode `?1006` (SGR
    /// mouse encoding) enabled. Tracked locally by a small CSI scanner in
    /// FeedBytes because libvterm does not expose this flag through any
    /// public symbol or callback. `?1015` (URXVT) clears the flag — Aefos.OTA.Terminal
    /// does not emit URXVT-shaped events; see ESP-032 Out of scope.
    /// </summary>
    property MouseSgrEnabled: Boolean read FMouseSgrEnabled;
    property OnBell: TBellEvent read FOnBell write FOnBell;
    property OnTitleChange: TTitleEvent read FOnTitleChange write FOnTitleChange;
    property OnChange: TBufferChangeEvent read FOnChange write FOnChange;
  end;

implementation

{ libvterm callbacks ---------------------------------------------------------
  cdecl C callbacks. The 'user' pointer carries the owning TVTermBuffer; the
  private handler methods are reachable here because Delphi 'private' has
  unit-level visibility. }

function _CellAt(const ABase: PVTermScreenCell;
  const AIndex: Integer): PVTermScreenCell;
begin
  Result := PVTermScreenCell(PByte(ABase) + AIndex * SizeOf(TVTermScreenCell));
end;

function _CbDamage(ARect: TVTermRect; AUser: Pointer): Integer; cdecl;
begin
  TVTermBuffer(AUser)._HandleDamage(ARect);
  Result := 1;
end;

function _CbMoveRect(ADest: TVTermRect; ASrc: TVTermRect;
  AUser: Pointer): Integer; cdecl;
begin
  // Not handled here - libvterm falls back to damage, which repaints.
  Result := 0;
end;

function _CbMoveCursor(APos: TVTermPos; AOldPos: TVTermPos; AVisible: Integer;
  AUser: Pointer): Integer; cdecl;
begin
  TVTermBuffer(AUser)._HandleMoveCursor(APos);
  Result := 1;
end;

function _CbSetTermProp(AProp: TVTermProp; AVal: PVTermValue;
  AUser: Pointer): Integer; cdecl;
begin
  TVTermBuffer(AUser)._HandleSetTermProp(AProp, AVal);
  Result := 1;
end;

function _CbBell(AUser: Pointer): Integer; cdecl;
begin
  TVTermBuffer(AUser)._HandleBell;
  Result := 1;
end;

function _CbResize(ARows: Integer; ACols: Integer; AUser: Pointer): Integer; cdecl;
begin
  // The new size is read back through vterm_get_size after Resize.
  Result := 1;
end;

function _CbPushLine(ACols: Integer; ACells: PVTermScreenCell;
  AUser: Pointer): Integer; cdecl;
begin
  // Defensive v3 fallback. libvterm prefers sb_pushline4 when both are wired
  // (see _CbPushLine4); this entrypoint only fires if the linked-in libvterm
  // build ships without v4 dispatch. ESP-034 / ADR-034-01 / C6.
  TVTermBuffer(AUser)._HandlePushLine(ACols, ACells, False);
  Result := 1;
end;

function _CbPushLine4(ACols: Integer; ACells: PVTermScreenCell;
  AContinuation: Integer; AUser: Pointer): Integer; cdecl;
begin
  // Preferred v4 dispatch. Carries the flow-continuation bit of the row
  // being evicted to scrollback. ESP-034 / ADR-034-01.
  TVTermBuffer(AUser)._HandlePushLine(ACols, ACells, AContinuation <> 0);
  Result := 1;
end;

function _CbPopLine(ACols: Integer; ACells: PVTermScreenCell;
  AUser: Pointer): Integer; cdecl;
begin
  Result := TVTermBuffer(AUser)._HandlePopLine(ACols, ACells);
end;

function _CbSbClear(AUser: Pointer): Integer; cdecl;
begin
  TVTermBuffer(AUser)._HandleSbClear;
  Result := 1;
end;

function _CbDcsFallback(ACommand: PAnsiChar; ACommandLen: NativeUInt;
  AFrag: TVTermStringFragment; AUser: Pointer): Integer; cdecl;
// Module-level cdecl trampoline registered in TVTermStateFallbacks.dcs and
// installed in TVTermBuffer._SetupOscFallback alongside the OSC trampoline.
// Decodes the fragment len_flags into (length, initial, final) bits using
// the same encoding as _CbOscFallback and forwards into the buffer handler.
// The fallback fires synchronously inside vterm_input_write — FLock is
// already held by the calling FeedBytes path, so the handler must NOT
// re-acquire it (same constraint as _CbSetTermProp / _CbOscFallback).
var
  LLen: LongWord;
  LBytes: TBytes;
  LCommand: AnsiString;
  LInitial, LFinal: Boolean;
begin
  LLen := AFrag.len_flags and $3FFFFFFF;
  LInitial := (AFrag.len_flags and $40000000) <> 0;
  LFinal   := (AFrag.len_flags and $80000000) <> 0;
  SetLength(LBytes, LLen);
  if (LLen > 0) and (AFrag.str <> nil) then
    Move(AFrag.str^, LBytes[0], LLen);
  SetLength(LCommand, ACommandLen);
  if (ACommandLen > 0) and (ACommand <> nil) then
    Move(ACommand^, LCommand[1], ACommandLen);
  TVTermBuffer(AUser)._HandleDcsFallback(LCommand, LBytes, LInitial, LFinal);
  Result := 1;
end;

function _CbOscFallback(ACommand: Integer; AFrag: TVTermStringFragment;
  AUser: Pointer): Integer; cdecl;
// Module-level cdecl trampoline registered in TVTermStateFallbacks.osc and
// installed in TVTermBuffer._SetupOscFallback. libvterm fires this for every
// OSC command outside the built-in handled set (0/1/2/52). Decodes the
// VTermStringFragment len_flags into (length, initial, final) bits using the
// existing encoding from _ApplyTitleFragment and forwards the payload into
// TVTermBuffer._HandleOscFallback. The fallback runs synchronously inside
// vterm_input_write — FLock is already held by the calling FeedBytes path,
// so the handler must NOT re-acquire it (same constraint as _CbSetTermProp).
var
  LLen: LongWord;
  LBytes: TBytes;
  LInitial, LFinal: Boolean;
begin
  LLen := AFrag.len_flags and $3FFFFFFF;
  LInitial := (AFrag.len_flags and $40000000) <> 0;
  LFinal   := (AFrag.len_flags and $80000000) <> 0;
  SetLength(LBytes, LLen);
  if (LLen > 0) and (AFrag.str <> nil) then
    Move(AFrag.str^, LBytes[0], LLen);
  TVTermBuffer(AUser)._HandleOscFallback(ACommand, LBytes, LInitial, LFinal);
  Result := 1;
end;

{ TVTermBuffer }

constructor TVTermBuffer.Create(const ACols, ARows: Integer);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FScrollback := TList<TScrollbackRow>.Create;
  FScrollbackCap := DEFAULT_SCROLLBACK_CAP;
  FCols := Max(ACols, 1);
  FRows := Max(ARows, 1);
  FCursorVisible := True;
  FBracketedPasteEnabled := False;
  FBpScanState := bpsIdle;
  FBpScanNum := 0;
  FBpScanMatched := False;
  FMouseLevel := 0;
  FMouseSgrEnabled := False;
  FMsScanState := msIdle;
  FMsScanNum := 0;
  FMsScanSgr := False;
  FMsScanUrxvt := False;
  FUrlPool := TList<string>.Create;
  FUrlPool.Add('');  // slot 0 reserved = "no link"
  FScrollbackLinks := TList<TLinkRangeArray>.Create;
  FCurrentLinkIdx := 0;
  FOscBuf := nil;
  FSplitInOsc8 := False;
  FSplitPrevEsc := False;
  FDcsAccumulator := '';
  FDcsAnchorRow := 0;
  FDcsAnchorCol := 0;
  FDcsActive := False;
  FSixelImages := TList<TSixelPlacement>.Create;
  FSixelImageCap := DEFAULT_SIXEL_IMAGE_CAP;
  SetLength(FDirty, FRows);
  _MarkAllDirty;
  _EnsureLinkRows(FRows);
  FVTerm := vterm_new(FRows, FCols);
  FScreen := vterm_obtain_screen(FVTerm);
  FState := vterm_obtain_state(FVTerm);
  _SetupCallbacks;
  vterm_screen_set_callbacks(FScreen, @FCallbacks, Self);
  // Opt-in to sb_pushline4 dispatch. Without this call libvterm leaves the
  // v4 slot inert and falls back to v3 even though both are wired.
  // ESP-034 / ADR-034-01 — confirmed in screen.c line_pushed_to_scrollback.
  vterm_screen_callbacks_has_pushline4(FScreen);
  _SetupOscFallback;
  vterm_screen_reset(FScreen, 1);
  vterm_set_utf8(FVTerm, 1);
  vterm_screen_enable_altscreen(FScreen, 1);
  vterm_screen_set_damage_merge(FScreen, VTERM_DAMAGE_SCROLL);
end;

destructor TVTermBuffer.Destroy;
var
  LRow: Integer;
begin
  if FVTerm <> nil then
    vterm_free(FVTerm);
  for LRow := 0 to High(FLinkRows) do
    FLinkRows[LRow].Free;
  FLinkRows := nil;
  FScrollbackLinks.Free;
  FUrlPool.Free;
  FScrollback.Free;
  FSixelImages.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TVTermBuffer._SetupCallbacks;
begin
  FillChar(FCallbacks, SizeOf(FCallbacks), 0);
  FCallbacks.damage      := _CbDamage;
  FCallbacks.moverect    := _CbMoveRect;
  FCallbacks.movecursor  := _CbMoveCursor;
  FCallbacks.settermprop := _CbSetTermProp;
  FCallbacks.bell        := _CbBell;
  FCallbacks.resize      := _CbResize;
  FCallbacks.sb_pushline := _CbPushLine;
  FCallbacks.sb_popline  := _CbPopLine;
  FCallbacks.sb_clear    := _CbSbClear;
  // sb_pushline4 is the preferred dispatch when both are set — libvterm's
  // line_pushed_to_scrollback in screen.c. v3 stays wired as the defensive
  // fallback that records Continuation := False. ESP-034 / ADR-034-01.
  FCallbacks.sb_pushline4 := _CbPushLine4;
end;

procedure TVTermBuffer._SetupOscFallback;
// Binds libvterm's unrecognised_fallbacks table. ADR-033-01 added the OSC
// slot for clickable hyperlinks; ADR-035-01 adds the DCS slot so Sixel
// images dispatch into _HandleDcsFallback. The remaining slots stay nil
// and libvterm safely no-ops them.
begin
  FillChar(FFallbacks, SizeOf(FFallbacks), 0);
  FFallbacks.osc := _CbOscFallback;
  FFallbacks.dcs := _CbDcsFallback;
  vterm_screen_set_unrecognised_fallbacks(FScreen, @FFallbacks, Self);
end;

procedure TVTermBuffer._EnsureLinkRows(const ANewRows: Integer);
// Grows or shrinks FLinkRows to ANewRows rows. New rows get a fresh empty
// list; surplus rows are freed.
var
  LRow, LOld: Integer;
begin
  LOld := Length(FLinkRows);
  if ANewRows = LOld then Exit;
  if ANewRows < LOld then
  begin
    for LRow := ANewRows to LOld - 1 do
      FLinkRows[LRow].Free;
    SetLength(FLinkRows, ANewRows);
  end
  else
  begin
    SetLength(FLinkRows, ANewRows);
    for LRow := LOld to ANewRows - 1 do
      FLinkRows[LRow] := TList<TLinkRange>.Create;
  end;
end;

procedure TVTermBuffer._ClearVisibleLinks;
// Narrower counterpart of _ClearAllLinks introduced under ESP-034 /
// ADR-034-03: clears only the visible-grid link rows and FCurrentLinkIdx,
// then re-seeds the empty visible-grid list for the new FRows. Crucially
// leaves FScrollbackLinks + FUrlPool alone — the Resize path now reflows
// scrollback link snapshots in lockstep with the cells.
var
  LRow: Integer;
begin
  for LRow := 0 to High(FLinkRows) do
    FLinkRows[LRow].Free;
  FLinkRows := nil;
  _EnsureLinkRows(FRows);
  FCurrentLinkIdx := 0;
  FOscBuf := nil;
  FSplitInOsc8 := False;
  FSplitPrevEsc := False;
end;

function TVTermBuffer._SnapshotScrollback: TArray<TScrollbackRow>;
var
  LFor: Integer;
begin
  SetLength(Result, FScrollback.Count);
  for LFor := 0 to FScrollback.Count - 1 do
    Result[LFor] := FScrollback[LFor];
end;

function TVTermBuffer._SnapshotScrollbackLinks: TArray<TArray<TLinkRange> >;
var
  LFor: Integer;
begin
  SetLength(Result, FScrollbackLinks.Count);
  for LFor := 0 to FScrollbackLinks.Count - 1 do
    Result[LFor] := Copy(FScrollbackLinks[LFor]);
end;

procedure TVTermBuffer._ApplyReflowedScrollback(
  const ARows: TArray<TScrollbackRow>;
  const ALinks: TArray<TArray<TLinkRange> >);
var
  LFor: Integer;
begin
  FScrollback.Clear;
  FScrollbackLinks.Clear;
  for LFor := 0 to High(ARows) do
    FScrollback.Add(ARows[LFor]);
  for LFor := 0 to High(ALinks) do
    FScrollbackLinks.Add(Copy(ALinks[LFor]));
  // Keep the two lists parallel for downstream readers: ScrollbackLinkAt
  // and any future canvas hover path index them by the same line number.
  while FScrollbackLinks.Count < FScrollback.Count do
    FScrollbackLinks.Add(nil);
end;

procedure TVTermBuffer._CapScrollbackToLimit;
begin
  while FScrollback.Count > FScrollbackCap do
    FScrollback.Delete(0);
  while FScrollbackLinks.Count > FScrollbackCap do
    FScrollbackLinks.Delete(0);
  while FScrollbackLinks.Count < FScrollback.Count do
    FScrollbackLinks.Add(nil);
end;

procedure TVTermBuffer._ClearAllLinks;
// Wipes per-row link ranges and scrollback link history; keeps FUrlPool's
// reserved slot 0 ('') and rebuilds the empty row list for current FRows.
var
  LRow: Integer;
begin
  for LRow := 0 to High(FLinkRows) do
    FLinkRows[LRow].Free;
  FLinkRows := nil;
  _EnsureLinkRows(FRows);
  FScrollbackLinks.Clear;
  FUrlPool.Clear;
  FUrlPool.Add('');  // restore slot 0
  FCurrentLinkIdx := 0;
  FOscBuf := nil;
  FSplitInOsc8 := False;
  FSplitPrevEsc := False;
end;

function TVTermBuffer._LookupUrlIdx(const AUrl: string): Integer;
// Returns the FUrlPool slot for AUrl, creating one if absent. Slot 0 is
// reserved for the empty URL — only positive indices mark a real link
// (per ADR-033-02). Linear search is intentional: per-session unique URLs
// stay small (typical `gh issue list` ≤ 100).
var
  LIndex: Integer;
begin
  if AUrl = '' then Exit(0);
  for LIndex := 1 to FUrlPool.Count - 1 do
    if FUrlPool[LIndex] = AUrl then Exit(LIndex);
  Result := FUrlPool.Add(AUrl);
end;

procedure TVTermBuffer._AppendOscFragment(const ABytes: TBytes);
// Appends ABytes to FOscBuf; libvterm may deliver an OSC fragment in
// multiple chunks (initial=False ... final=True) so we accumulate before
// parsing.
var
  LOldLen: Integer;
begin
  if Length(ABytes) = 0 then Exit;
  LOldLen := Length(FOscBuf);
  SetLength(FOscBuf, LOldLen + Length(ABytes));
  Move(ABytes[0], FOscBuf[LOldLen], Length(ABytes));
end;

procedure TVTermBuffer._MarkAllDirty;
var
  LRow: Integer;
begin
  for LRow := 0 to High(FDirty) do
    FDirty[LRow] := True;
end;

procedure TVTermBuffer._MarkDirtyRange(const AFrom, ATo: Integer);
var
  LRow: Integer;
begin
  for LRow := Max(0, AFrom) to Min(High(FDirty), ATo) do
    FDirty[LRow] := True;
end;

function TVTermBuffer._GetScrollbackCount: Integer;
begin
  FLock.Enter;
  try
    Result := FScrollback.Count;
  finally
    FLock.Leave;
  end;
end;

function TVTermBuffer._BlankCell: TTerminalCell;
begin
  Result.Ch := cBlankCodepoint;
  Result.Fg := TCellColor.CreateDefault;
  Result.Bg := TCellColor.CreateDefault;
  Result.Attrs := [];
end;

function TVTermBuffer._CodepointToChar(const ACodepoint: LongWord): UCS4Char;
begin
  // UCS4Char result (was WideChar): the cell stores the full Unicode scalar, so
  // astral-plane codepoints (emoji, logo glyphs) survive intact and the painters
  // convert them to text at draw time — the old `> $FFFF -> '?'` fallback is gone.
  //
  // The rule for what may be stored lives on TTerminalCell, next to the field it
  // constrains, because this is not the only door into the grid (LoadStateJSON is
  // the other) and the two used to disagree. Pass-through was a real defect: the
  // gap behind a double-width glyph arrives here as $FFFFFFFF and reached the
  // painter as Integer(-1), which is the "Invalid UTF32 character value"
  // exception the Codex banner triggered.
  Result := TTerminalCell.ScalarFromVTerm(ACodepoint);
end;

function TVTermBuffer._CodepointToUtf16(
  const ACodepoint: UCS4Char): UnicodeString;
var
  LScalar: UCS4Char;
  LHigh, LLow: Word;
begin
  // Renders a full Unicode scalar (BMP or astral) as its UTF-16 form. Kept
  // dependency-free on purpose: this Core unit is compiled by the headless FPC
  // probes whose unit path has neither System.Character
  // nor LazUTF8, so the surrogate split is spelled out by hand. Callers on FPC
  // wrap the result in the RTL's UTF8Encode (same seam TerminalHost already uses)
  // to cross the Ansi/UTF-8 boundary; on Delphi the UnicodeString is appended as
  // is (byte-identical to the former string(WideChar) for the BMP).
  if (ACodepoint >= $10000) and (ACodepoint <= $10FFFF) then
  begin
    LScalar := ACodepoint - $10000;
    LHigh := Word($D800 + (LScalar shr 10));
    LLow  := Word($DC00 + (LScalar and $3FF));
    SetLength(Result, 2);
    Result[1] := WideChar(LHigh);
    Result[2] := WideChar(LLow);
  end
  else
  begin
    SetLength(Result, 1);
    Result[1] := WideChar(ACodepoint);
  end;
end;

function TVTermBuffer._ConvertColor(const AColor: TVTermColor): TCellColor;
begin
  if (AColor.colorType and VTERM_COLOR_DEFAULT_MASK) <> 0 then
    Result := TCellColor.CreateDefault
  else if (AColor.colorType and VTERM_COLOR_TYPE_MASK) = VTERM_COLOR_INDEXED then
    Result := TCellColor.CreateIndexed(AColor.idx)
  else
    Result := TCellColor.CreateRGB(AColor.red, AColor.green, AColor.blue);
end;

function TVTermBuffer._ConvertAttrs(
  const AAttrs: TVTermScreenCellAttrs): TCellAttrs;
begin
  Result := [];
  if (AAttrs and VTERM_CELL_BOLD_MASK) <> 0 then
    Include(Result, caBold);
  if (AAttrs and VTERM_CELL_UNDERLINE_MASK) <> 0 then
    Include(Result, caUnderline);
  if (AAttrs and VTERM_CELL_ITALIC_MASK) <> 0 then
    Include(Result, caItalic);
  if (AAttrs and VTERM_CELL_REVERSE_MASK) <> 0 then
    Include(Result, caInverse);
end;

function TVTermBuffer._ConvertCell(
  const ACell: TVTermScreenCell): TTerminalCell;
begin
  Result.Ch := _CodepointToChar(ACell.chars[0]);
  Result.Attrs := _ConvertAttrs(ACell.attrs);
  // Structural, so it is set HERE rather than inside _ConvertAttrs (which speaks
  // only libvterm's visual attribute mask and knows nothing about chars[0]).
  if TTerminalCell.IsWideGap(ACell.chars[0]) then
    Include(Result.Attrs, caWideGap);
  Result.Fg := _ConvertColor(ACell.fg);
  Result.Bg := _ConvertColor(ACell.bg);
end;

function TVTermBuffer._CellColorToVTerm(const AColor: TCellColor): TVTermColor;
begin
  FillChar(Result, SizeOf(Result), 0);
  case AColor.Kind of
    ckIndexed:
      begin
        Result.colorType := VTERM_COLOR_INDEXED;
        Result.idx := Byte(AColor.Value);
      end;
    ckRGB:
      begin
        Result.colorType := VTERM_COLOR_RGB;
        Result.red   := Byte((AColor.Value shr 16) and $FF);
        Result.green := Byte((AColor.Value shr 8) and $FF);
        Result.blue  := Byte(AColor.Value and $FF);
      end;
  else
    Result.colorType := VTERM_COLOR_DEFAULT_FG;
  end;
end;

function TVTermBuffer._AttrsToVTerm(
  const AAttrs: TCellAttrs): TVTermScreenCellAttrs;
begin
  Result := 0;
  if caBold in AAttrs then
    Result := Result or VTERM_CELL_BOLD_MASK;
  if caUnderline in AAttrs then
    Result := Result or VTERM_CELL_UNDERLINE_SINGLE;
  if caItalic in AAttrs then
    Result := Result or VTERM_CELL_ITALIC_MASK;
  if caInverse in AAttrs then
    Result := Result or VTERM_CELL_REVERSE_MASK;
end;

function TVTermBuffer._CellToVTerm(
  const ACell: TTerminalCell): TVTermScreenCell;
begin
  FillChar(Result, SizeOf(Result), 0);
  // ACell.Ch is already the full Unicode codepoint (UCS4Char) — feed it straight
  // to libvterm's chars[0] (LongWord), no Ord() narrowing.
  Result.chars[0] := LongWord(ACell.Ch);
  Result.width := AnsiChar(#1);
  Result.attrs := _AttrsToVTerm(ACell.Attrs);
  Result.fg := _CellColorToVTerm(ACell.Fg);
  Result.bg := _CellColorToVTerm(ACell.Bg);
end;

function TVTermBuffer._ReadCell(const AX, AY: Integer): TTerminalCell;
var
  LPos: TVTermPos;
  LVCell: TVTermScreenCell;
begin
  if (AX < 0) or (AX >= FCols) or (AY < 0) or (AY >= FRows) then
    Exit(_BlankCell);
  LPos.row := AY;
  LPos.col := AX;
  FillChar(LVCell, SizeOf(LVCell), 0);
  vterm_screen_get_cell(FScreen, LPos, @LVCell);
  Result := _ConvertCell(LVCell);
end;

procedure TVTermBuffer._PushScrollbackRow(const ARow: TTerminalRow;
  const AContinuation: Boolean);
var
  LEntry: TScrollbackRow;
begin
  LEntry.Cells := ARow;
  LEntry.Continuation := AContinuation;
  FScrollback.Add(LEntry);
  while FScrollback.Count > FScrollbackCap do
    FScrollback.Delete(0);
end;

{ callback handlers --------------------------------------------------------- }

procedure TVTermBuffer._HandleDamage(const ARect: TVTermRect);
begin
  _MarkDirtyRange(ARect.start_row, ARect.end_row - 1);
end;

procedure TVTermBuffer._HandleMoveCursor(const APos: TVTermPos);
begin
  FCursorX := APos.col;
  FCursorY := APos.row;
end;

procedure TVTermBuffer._HandleSetTermProp(const AProp: TVTermProp;
  const AVal: PVTermValue);
begin
  case AProp of
    vtpCursorVisible: FCursorVisible := AVal^.boolean <> 0;
    vtpTitle: _ApplyTitleFragment(AVal);
    vtpMouse: FMouseLevel := AVal^.number;
    vtpAltScreen:
      // Alt-screen transitions in either direction wipe stored Sixel
      // images (BR9): entering alt means the normal-screen pictures are
      // no longer visible, and the alt surface starts fresh; leaving
      // alt discards whatever the alt-screen program drew. This matches
      // MobaXterm's behaviour and the libvterm cell-clear pattern.
      _ClearSixelImages;
  end;
end;

procedure TVTermBuffer._ApplyTitleFragment(const AVal: PVTermValue);
var
  LLen: LongWord;
  LAnsi: AnsiString;
begin
  LLen := AVal^.stringFrag.len_flags and $3FFFFFFF;
  if LLen > 65535 then
    LLen := 65535;
  if (AVal^.stringFrag.len_flags and $40000000) <> 0 then
    FTitleBuf := '';
  if (AVal^.stringFrag.str <> nil) and (LLen > 0) then
  begin
    SetString(LAnsi, AVal^.stringFrag.str, Integer(LLen));
    FTitleBuf := FTitleBuf + UTF8ToString(LAnsi);
  end;
  if (AVal^.stringFrag.len_flags and $80000000) <> 0 then
  begin
    FTitle := FTitleBuf;
    if Assigned(FOnTitleChange) then
      FOnTitleChange(Self, FTitle);
  end;
end;

procedure TVTermBuffer._HandleBell;
begin
  if Assigned(FOnBell) then
    FOnBell(Self);
end;

procedure TVTermBuffer._HandlePushLine(const ACols: Integer;
  const ACells: PVTermScreenCell; const AContinuation: Boolean);
var
  LRow: TTerminalRow;
  LX: Integer;
  LLinks: TArray<TLinkRange>;
begin
  SetLength(LRow, ACols);
  for LX := 0 to ACols - 1 do
    LRow[LX] := _ConvertCell(_CellAt(ACells, LX)^);
  _PushScrollbackRow(LRow, AContinuation);
  // Push the parallel link-range snapshot for row 0 onto FScrollbackLinks,
  // mirroring how the visual row is evicted. Subsequent rows shift up by 1.
  if Length(FLinkRows) > 0 then
  begin
    LLinks := FLinkRows[0].ToArray;
    FScrollbackLinks.Add(LLinks);
    while FScrollbackLinks.Count > FScrollbackCap do
      FScrollbackLinks.Delete(0);
    FLinkRows[0].Free;  // the row's list now lives in FScrollbackLinks as TArray
    for LX := 0 to High(FLinkRows) - 1 do
      FLinkRows[LX] := FLinkRows[LX + 1];
    FLinkRows[High(FLinkRows)] := TList<TLinkRange>.Create;
  end;
end;

function TVTermBuffer._HandlePopLine(const ACols: Integer;
  const ACells: PVTermScreenCell): Integer;
var
  LRow: TTerminalRow;
  LX, LIndex: Integer;
  LLinks: TArray<TLinkRange>;
  LRestored: TList<TLinkRange>;
  LFor: Integer;
begin
  if FScrollback.Count = 0 then
    Exit(0);
  LIndex := FScrollback.Count - 1;
  // Continuation drops to False on restore: the row is rejoining the visible
  // grid where libvterm owns line info — Pascal does not need to round-trip
  // the bit. ESP-034 §Scope item 2.
  LRow := FScrollback[LIndex].Cells;
  for LX := 0 to ACols - 1 do
    if LX < Length(LRow) then
      _CellAt(ACells, LX)^ := _CellToVTerm(LRow[LX])
    else
      _CellAt(ACells, LX)^ := _CellToVTerm(_BlankCell);
  FScrollback.Delete(LIndex);
  // Restore the parallel link snapshot onto row 0; shift existing rows down.
  if (FScrollbackLinks.Count > 0) and (Length(FLinkRows) > 0) then
  begin
    LIndex := FScrollbackLinks.Count - 1;
    LLinks := FScrollbackLinks[LIndex];
    FScrollbackLinks.Delete(LIndex);
    FLinkRows[High(FLinkRows)].Free;
    for LX := High(FLinkRows) downto 1 do
      FLinkRows[LX] := FLinkRows[LX - 1];
    LRestored := TList<TLinkRange>.Create;
    for LFor := 0 to High(LLinks) do
      LRestored.Add(LLinks[LFor]);
    FLinkRows[0] := LRestored;
  end;
  Result := 1;
end;

procedure TVTermBuffer._HandleSbClear;
begin
  FScrollback.Clear;
  FScrollbackLinks.Clear;
end;

procedure TVTermBuffer._HandleOscFallback(const ACmd: Integer;
  const AFragBytes: TBytes; const AInitial, AFinal: Boolean);
// Aggregates OSC 8 fragments libvterm delivers; on the final chunk, parses
// the URL and updates FCurrentLinkIdx. The cursor query and link-range
// recording for the text written before this OSC happens in FeedBytes after
// each vterm_input_write returns — keeping the callback short and lock-safe
// (FLock is already held by the enclosing FeedBytes call).
//
// ACmd != 8 is intentionally discarded for v1; ESP-033 Out of scope lists
// OSC 6 / 7 / 4 / 10 / 11 as future cycles sharing this same hook.
var
  LParams, LUrl: string;
begin
  if ACmd <> 8 then Exit;
  if AInitial then
    FOscBuf := nil;
  _AppendOscFragment(AFragBytes);
  if not AFinal then Exit;
  if THyperlink.ParseOsc8Fragment(FOscBuf, LParams, LUrl) and (LUrl <> '') then
    FCurrentLinkIdx := _LookupUrlIdx(LUrl)
  else
    FCurrentLinkIdx := 0;
  FOscBuf := nil;
end;

procedure TVTermBuffer._HandleDcsFallback(const ACommand: AnsiString;
  const AFragBytes: TBytes; const AInitial, AFinal: Boolean);
// Accumulates DCS body fragments libvterm delivers and, on the final
// chunk for a Sixel command (ACommand[1] = 'q'), invokes the pure decoder
// and stores the resulting placement at the anchor captured on the
// `initial` fragment. Fires under FLock — the caller (vterm_input_write
// inside FeedBytes) already holds the lock. Raw accumulator capped at
// SIXEL_RAW_CAP per BR7; oversized streams are discarded silently.
var
  LPos: TVTermPos;
  LAppendLen: Integer;
  LOldLen: Integer;
begin
  if AInitial then
  begin
    FDcsAccumulator := '';
    if FState <> nil then
    begin
      LPos.row := 0;
      LPos.col := 0;
      vterm_state_get_cursorpos(FState, @LPos);
      FDcsAnchorRow := LPos.row;
      FDcsAnchorCol := LPos.col;
    end
    else
    begin
      FDcsAnchorRow := 0;
      FDcsAnchorCol := 0;
    end;
    FDcsActive := True;
  end;
  if not FDcsActive then Exit;
  LAppendLen := Length(AFragBytes);
  if LAppendLen > 0 then
  begin
    LOldLen := Length(FDcsAccumulator);
    if LOldLen + LAppendLen > SIXEL_RAW_CAP then
    begin
      // Stream exceeds the raw cap — discard silently and stop further
      // accumulation until the next `initial` fragment.
      FDcsAccumulator := '';
      FDcsActive := False;
    end
    else
    begin
      SetLength(FDcsAccumulator, LOldLen + LAppendLen);
      Move(AFragBytes[0], FDcsAccumulator[LOldLen + 1], LAppendLen);
    end;
  end;
  if AFinal then
  begin
    // libvterm accumulates every byte between ESC P and the body into
    // `command` — that includes the DCS parameters AND the terminator
    // byte. For `ESC P 0;0;0 q ...` the command arrives as "0;0;0q",
    // so the Sixel marker is the LAST byte, not the first.
    if FDcsActive and (Length(ACommand) >= 1) and
       (ACommand[Length(ACommand)] = 'q') and
       (Length(FDcsAccumulator) > 0) then
      _StoreSixelDecoded(FDcsAccumulator);
    FDcsAccumulator := '';
    FDcsActive := False;
  end;
end;

procedure TVTermBuffer._StoreSixelDecoded(const AData: RawByteString);
// Decodes AData and, if the result is a non-empty image, appends a
// placement to FSixelImages — evicting older placements (FIFO) until the
// running BGRA total plus the new image fits inside FSixelImageCap. A
// single placement larger than the cap is dropped without storage
// (BR8). The decoder never raises, so this method does not need a guard.
var
  LWidth, LHeight: Integer;
  LPixels: TArray<Byte>;
  LPlacement: TSixelPlacement;
  LNewBytes, LTotalBytes: Int64;
  LFor: Integer;
begin
  LPixels := TSixelDecoder.Decode(AData, LWidth, LHeight);
  if (LWidth <= 0) or (LHeight <= 0) then Exit;
  LNewBytes := Int64(LWidth) * Int64(LHeight) * 4;
  if LNewBytes > FSixelImageCap then Exit;
  LTotalBytes := 0;
  for LFor := 0 to FSixelImages.Count - 1 do
    Inc(LTotalBytes, Length(FSixelImages[LFor].Pixels));
  while (FSixelImages.Count > 0) and
        (LTotalBytes + LNewBytes > FSixelImageCap) do
  begin
    Dec(LTotalBytes, Length(FSixelImages[0].Pixels));
    FSixelImages.Delete(0);
  end;
  LPlacement.Pixels := LPixels;
  LPlacement.Width := LWidth;
  LPlacement.Height := LHeight;
  LPlacement.AnchorRow := FDcsAnchorRow;
  LPlacement.AnchorCol := FDcsAnchorCol;
  FSixelImages.Add(LPlacement);
end;

procedure TVTermBuffer._ClearSixelImages;
// Drops every stored placement and resets the DCS accumulator. Called
// from Reset (hard reset clears everything) and from _HandleSetTermProp
// on both vtpAltScreen=True and =False transitions (BR9). Runs under
// FLock — every caller already holds it.
begin
  FSixelImages.Clear;
  FDcsAccumulator := '';
  FDcsActive := False;
end;

procedure TVTermBuffer._RecordTextBurstLinks(const ABefore, AAfter: TVTermPos);
// Appends a TLinkRange to every row touched by the cursor advance from
// ABefore to AAfter, attributing it to FCurrentLinkIdx. No-op when the
// cursor did not advance forward (reverse moves and pure cursor-positioning
// sequences write no cells).
//
// Per ADR-033-02 the range is half-open [StartCol, EndCol): the first
// touched row starts at ABefore.col; intermediate rows span [0, FCols);
// the final row ends at AAfter.col.
var
  LRow, LStartCol, LEndCol: Integer;
  LRange: TLinkRange;
begin
  if FCurrentLinkIdx <= 0 then Exit;
  if Length(FLinkRows) = 0 then Exit;
  if (AAfter.row < ABefore.row) then Exit;  // reverse wrap — ignore (BR7 NIT)
  if (AAfter.row = ABefore.row) and (AAfter.col <= ABefore.col) then Exit;
  for LRow := ABefore.row to AAfter.row do
  begin
    if (LRow < 0) or (LRow >= Length(FLinkRows)) then Continue;
    if LRow = ABefore.row then
      LStartCol := ABefore.col
    else
      LStartCol := 0;
    if LRow = AAfter.row then
      LEndCol := AAfter.col
    else
      LEndCol := FCols;
    if LEndCol > LStartCol then
    begin
      LRange.StartCol := LStartCol;
      LRange.EndCol := LEndCol;
      LRange.UrlIdx := FCurrentLinkIdx;
      FLinkRows[LRow].Add(LRange);
    end;
  end;
end;

{ feed / resize / reset ----------------------------------------------------- }

procedure TVTermBuffer.Feed(const AText: string);
begin
  if AText <> '' then
    FeedBytes(TEncoding.UTF8.GetBytes(AText));
end;

procedure TVTermBuffer._WriteRawBytes(const AData: TBytes;
  const AStart, ALen: Integer);
// Helper that funnels every vterm_input_write call through one place; lets
// FeedBytes hand sub-bursts produced by _SplitFeedAtOsc8 to libvterm without
// allocating intermediate copies.
begin
  if ALen <= 0 then Exit;
  vterm_input_write(FVTerm, PAnsiChar(@AData[AStart]), ALen);
end;

function TVTermBuffer._SplitFeedAtOsc8(
  const AData: TBytes): TArray<TFeedSegment>;
// Splits AData into alternating text / OSC 8 segments at the 4-byte signature
// `ESC ] 8 ;` and the matching terminator (`ESC \` or `BEL`). State persists
// across FeedBytes calls via FSplitInOsc8 / FSplitPrevEsc so an OSC 8 split
// between two FeedBytes calls is tracked correctly. ADR-033-02.
//
// The splitter does not parse the OSC payload — libvterm does (we just
// observe via _HandleOscFallback). Its job is to give FeedBytes two facts:
//   1. byte ranges that contain only text-mode bytes (cursor advances)
//   2. byte ranges that contain only OSC 8 bytes (cursor stays put)
// so cursor positions can be sampled around each text sub-burst.
const
  CESC = $1B;
  CBEL = $07;
var
  LIndex, LSegStart: Integer;
  LInOsc8, LPrevEsc: Boolean;
  LSegments: TList<TFeedSegment>;
  LSeg: TFeedSegment;
  LIsSignature: Boolean;
begin
  LSegments := TList<TFeedSegment>.Create;
  try
    LInOsc8 := FSplitInOsc8;
    LPrevEsc := FSplitPrevEsc;
    LSegStart := 0;
    LIndex := 0;
    while LIndex < Length(AData) do
    begin
      if not LInOsc8 then
      begin
        // Look ahead for the 4-byte OSC 8 signature `ESC ] 8 ;`.
        LIsSignature :=
          (AData[LIndex] = CESC)
          and (LIndex + 3 < Length(AData))
          and (AData[LIndex + 1] = Ord(']'))
          and (AData[LIndex + 2] = Ord('8'))
          and (AData[LIndex + 3] = Ord(';'));
        if LIsSignature then
        begin
          if LIndex > LSegStart then
          begin
            LSeg.Kind := sfkText;
            LSeg.Start := LSegStart;
            LSeg.Len := LIndex - LSegStart;
            LSegments.Add(LSeg);
          end;
          LSegStart := LIndex;
          LInOsc8 := True;
          LPrevEsc := False;
          Inc(LIndex, 4);
          Continue;
        end;
        Inc(LIndex);
      end
      else
      begin
        if LPrevEsc and (AData[LIndex] = Ord('\')) then
        begin
          Inc(LIndex);  // include ESC and \ in OSC 8 segment
          LSeg.Kind := sfkOsc8;
          LSeg.Start := LSegStart;
          LSeg.Len := LIndex - LSegStart;
          LSegments.Add(LSeg);
          LSegStart := LIndex;
          LInOsc8 := False;
          LPrevEsc := False;
        end
        else if AData[LIndex] = CBEL then
        begin
          Inc(LIndex);
          LSeg.Kind := sfkOsc8;
          LSeg.Start := LSegStart;
          LSeg.Len := LIndex - LSegStart;
          LSegments.Add(LSeg);
          LSegStart := LIndex;
          LInOsc8 := False;
          LPrevEsc := False;
        end
        else
        begin
          LPrevEsc := AData[LIndex] = CESC;
          Inc(LIndex);
        end;
      end;
    end;
    // Emit the trailing segment (may be partial OSC 8 spanning into next call).
    if LIndex > LSegStart then
    begin
      if LInOsc8 then
        LSeg.Kind := sfkOsc8
      else
        LSeg.Kind := sfkText;
      LSeg.Start := LSegStart;
      LSeg.Len := LIndex - LSegStart;
      LSegments.Add(LSeg);
    end;
    FSplitInOsc8 := LInOsc8;
    FSplitPrevEsc := LPrevEsc;
    Result := LSegments.ToArray;
  finally
    LSegments.Free;
  end;
end;

procedure TVTermBuffer.FeedBytes(const AData: TBytes);
var
  LSegments: TArray<TFeedSegment>;
  LFor: Integer;
  LBefore, LAfter: TVTermPos;
begin
  FLock.Enter;
  try
    if Length(AData) > 0 then
    begin
      _ScanBracketedPaste(AData);
      _ScanMouseSgrMode(AData);
      LSegments := _SplitFeedAtOsc8(AData);
      for LFor := 0 to High(LSegments) do
      begin
        case LSegments[LFor].Kind of
          sfkText:
            begin
              // Sample cursor before and after each text-only sub-burst;
              // if a link is currently open, attribute the touched cells.
              vterm_state_get_cursorpos(FState, @LBefore);
              _WriteRawBytes(AData, LSegments[LFor].Start, LSegments[LFor].Len);
              vterm_state_get_cursorpos(FState, @LAfter);
              if FCurrentLinkIdx > 0 then
                _RecordTextBurstLinks(LBefore, LAfter);
            end;
          sfkOsc8:
            // OSC 8 sub-burst — libvterm fires _CbOscFallback synchronously
            // which updates FCurrentLinkIdx via _HandleOscFallback.
            _WriteRawBytes(AData, LSegments[LFor].Start, LSegments[LFor].Len);
        end;
      end;
    end;
    vterm_screen_flush_damage(FScreen);
  finally
    FLock.Leave;
  end;
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

procedure TVTermBuffer._ScanBracketedPaste(const AData: TBytes);
// Mirrors libvterm's `state->mode.bracketpaste` flag, which has no public
// getter and is not propagated through any screen/state callback. The scanner
// walks the byte stream watching for DEC private CSI sequences of the form
// `ESC [ ? <params> h|l` and toggles FBracketedPasteEnabled whenever the
// parameter list contains 2004. State persists across chunk boundaries so a
// CSI split between two FeedBytes calls is tracked correctly.
// Governing decision: ADR-028-01 (supersedes the mechanism portion of ADR-026-01).
const
  CESC = $1B;
var
  LIndex: Integer;
  LByte: Byte;
begin
  for LIndex := 0 to High(AData) do
  begin
    LByte := AData[LIndex];
    case FBpScanState of
      bpsIdle:
        if LByte = CESC then
          FBpScanState := bpsEsc;
      bpsEsc:
        if LByte = Ord('[') then
          FBpScanState := bpsCsiStart
        else if LByte <> CESC then
          FBpScanState := bpsIdle;
      bpsCsiStart:
        if LByte = Ord('?') then
        begin
          FBpScanState := bpsCsiParams;
          FBpScanNum := 0;
          FBpScanMatched := False;
        end
        else if LByte = CESC then
          FBpScanState := bpsEsc
        else
          FBpScanState := bpsIdle;
      bpsCsiParams:
        case LByte of
          Ord('0')..Ord('9'):
            FBpScanNum := FBpScanNum * 10 + (LByte - Ord('0'));
          Ord(';'):
            begin
              if FBpScanNum = 2004 then
                FBpScanMatched := True;
              FBpScanNum := 0;
            end;
          Ord('h'):
            begin
              if (FBpScanNum = 2004) or FBpScanMatched then
                FBracketedPasteEnabled := True;
              FBpScanState := bpsIdle;
            end;
          Ord('l'):
            begin
              if (FBpScanNum = 2004) or FBpScanMatched then
                FBracketedPasteEnabled := False;
              FBpScanState := bpsIdle;
            end;
          CESC:
            FBpScanState := bpsEsc;
        else
          FBpScanState := bpsIdle;
        end;
    end;
  end;
end;

procedure TVTermBuffer._ScanMouseSgrMode(const AData: TBytes);
// Tracks the foreground program's `?1006` (SGR) and `?1015` (URXVT) toggles
// via a Pascal-side scanner. libvterm exposes the mouse *level* through
// settermprop (vtpMouse) but does not surface the SGR/URXVT encoding flag
// anywhere - so we mirror the bracketed-paste pattern from ADR-028-01 and
// walk the byte stream watching for `ESC [ ? <params> h|l`. State persists
// across chunk boundaries so a CSI split between two FeedBytes calls is
// tracked correctly. URXVT is observed for parity (sets MouseSgrEnabled
// back to False) but not encoded - see ESP-032 Out of scope.
const
  CESC = $1B;
var
  LIndex: Integer;
  LByte: Byte;
begin
  for LIndex := 0 to High(AData) do
  begin
    LByte := AData[LIndex];
    case FMsScanState of
      msIdle:
        if LByte = CESC then
          FMsScanState := msEsc;
      msEsc:
        if LByte = Ord('[') then
          FMsScanState := msCsiStart
        else if LByte <> CESC then
          FMsScanState := msIdle;
      msCsiStart:
        if LByte = Ord('?') then
        begin
          FMsScanState := msCsiParams;
          FMsScanNum := 0;
          FMsScanSgr := False;
          FMsScanUrxvt := False;
          FMsScanLevelOff := False;
        end
        else if LByte = CESC then
          FMsScanState := msEsc
        else
          FMsScanState := msIdle;
      msCsiParams:
        case LByte of
          Ord('0')..Ord('9'):
            FMsScanNum := FMsScanNum * 10 + (LByte - Ord('0'));
          Ord(';'):
            begin
              if FMsScanNum = 1006 then FMsScanSgr := True;
              if FMsScanNum = 1015 then FMsScanUrxvt := True;
              if (FMsScanNum = 1000) or (FMsScanNum = 1002)
                or (FMsScanNum = 1003) then FMsScanLevelOff := True;
              FMsScanNum := 0;
            end;
          Ord('h'):
            begin
              if (FMsScanNum = 1006) or FMsScanSgr then
                FMouseSgrEnabled := True;
              if (FMsScanNum = 1015) or FMsScanUrxvt then
                FMouseSgrEnabled := False;
              FMsScanState := msIdle;
            end;
          Ord('l'):
            begin
              if (FMsScanNum = 1006) or FMsScanSgr then
                FMouseSgrEnabled := False;
              if (FMsScanNum = 1015) or FMsScanUrxvt then
                FMouseSgrEnabled := False;
              // ADR-056-02 (M-5): symmetric reset for `?1000l/?1002l/?1003l`.
              // libvterm normally clears the level via its vtpMouse settermprop
              // callback, but combined or fragmented disable lists from vim's
              // exit sequence have been observed to leave FMouseLevel > 0 — so
              // the Pascal scanner explicitly clears it on every `l` that
              // disables a tracking mode. Belt-and-suspenders per BR1.
              if (FMsScanNum = 1000) or (FMsScanNum = 1002)
                or (FMsScanNum = 1003) or FMsScanLevelOff then
                FMouseLevel := 0;
              FMsScanState := msIdle;
            end;
          CESC:
            FMsScanState := msEsc;
        else
          FMsScanState := msIdle;
        end;
    end;
  end;
end;

procedure TVTermBuffer.Resize(const ACols, ARows: Integer);
var
  LNewCols, LNewRows, LOldCols: Integer;
  LOldRows, LNewRowsArr: TArray<TScrollbackRow>;
  LOldLinks, LNewLinksArr: TArray<TArray<TLinkRange> >;
begin
  LNewCols := Max(ACols, 1);
  LNewRows := Max(ARows, 1);
  FLock.Enter;
  try
    if (LNewCols = FCols) and (LNewRows = FRows) then
      Exit;
    LOldCols := FCols;
    SetLength(FDirty, LNewRows);
    vterm_set_size(FVTerm, LNewRows, LNewCols);
    vterm_get_size(FVTerm, @FRows, @FCols);
    if Length(FDirty) <> FRows then
      SetLength(FDirty, FRows);
    _MarkAllDirty;
    // ESP-034 / ADR-034-03: narrow the link-clear to the visible grid so
    // FScrollbackLinks survives the reflow that follows. Pre-ESP-034 this
    // call was _ClearAllLinks, which wiped scrollback links too.
    _ClearVisibleLinks;
    if (LNewCols <> LOldCols) and (FScrollback.Count > 0) then
    begin
      LOldRows  := _SnapshotScrollback;
      LOldLinks := _SnapshotScrollbackLinks;
      LNewRowsArr := TScrollbackReflow.Reflow(
        LOldRows, LOldLinks, LNewCols, LNewLinksArr);
      _ApplyReflowedScrollback(LNewRowsArr, LNewLinksArr);
      _CapScrollbackToLimit;
    end;
  finally
    FLock.Leave;
  end;
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

procedure TVTermBuffer.Reset;
begin
  FLock.Enter;
  try
    FScrollback.Clear;
    vterm_screen_reset(FScreen, 1);
    FBracketedPasteEnabled := False;
    FBpScanState := bpsIdle;
    FBpScanNum := 0;
    FBpScanMatched := False;
    FMouseLevel := 0;
    FMouseSgrEnabled := False;
    FMsScanState := msIdle;
    FMsScanNum := 0;
    FMsScanSgr := False;
    FMsScanUrxvt := False;
    _ClearAllLinks;
    _ClearSixelImages;
    _MarkAllDirty;
  finally
    FLock.Leave;
  end;
end;

function TVTermBuffer.GetLinkAt(const ACol, ARow: Integer): string;
// Returns the URL attached to (ACol, ARow) — visible-grid coordinates. The
// per-row list is short (typical: 0..3 ranges) so a linear scan beats the
// overhead of binary search for the expected workload. Out-of-bounds inputs
// return '' silently — the canvas hover path probes coordinates derived
// from raw pixel math and must not crash on edge cells.
var
  LRange: TLinkRange;
  LList: TList<TLinkRange>;
  LFor: Integer;
begin
  Result := '';
  FLock.Enter;
  try
    if (ARow < 0) or (ACol < 0) then Exit;
    if ARow >= Length(FLinkRows) then Exit;
    LList := FLinkRows[ARow];
    if (LList = nil) or (LList.Count = 0) then Exit;
    for LFor := 0 to LList.Count - 1 do
    begin
      LRange := LList[LFor];
      if (ACol >= LRange.StartCol) and (ACol < LRange.EndCol) then
      begin
        if (LRange.UrlIdx > 0) and (LRange.UrlIdx < FUrlPool.Count) then
          Result := FUrlPool[LRange.UrlIdx];
        Exit;
      end;
    end;
  finally
    FLock.Leave;
  end;
end;

{ readers ------------------------------------------------------------------- }

function TVTermBuffer.Cell(const AX, AY: Integer): TTerminalCell;
begin
  FLock.Enter;
  try
    Result := _ReadCell(AX, AY);
  finally
    FLock.Leave;
  end;
end;

function TVTermBuffer.ScrollbackCell(const ALine, AX: Integer): TTerminalCell;
begin
  FLock.Enter;
  try
    if (ALine >= 0) and (ALine < FScrollback.Count) and
       (AX >= 0) and (AX < Length(FScrollback[ALine].Cells)) then
      Result := FScrollback[ALine].Cells[AX]
    else
      Result := _BlankCell;
  finally
    FLock.Leave;
  end;
end;

function TVTermBuffer.RowText(const AY: Integer): string;
var
  LX: Integer;
  LBuilder: TStringBuilder;
begin
  FLock.Enter;
  try
    if (AY < 0) or (AY >= FRows) then
      Exit('');
    LBuilder := TStringBuilder.Create;
    try
      for LX := 0 to FCols - 1 do
        // A column COVERED by the double-width glyph to its left contributes no
        // text of its own -- emitting the blank it stores would put a stray space
        // after every wide glyph in copied text.
        if caWideGap in _ReadCell(LX, AY).Attrs then
          Continue
        else
        // Ch is a UCS4Char codepoint now. On Delphi the builder is UnicodeString,
        // so append the UTF-16 form directly (byte-identical to the former path for
        // the BMP; astral scalars now round-trip as a surrogate pair). On FPC the
        // builder is Ansi, so UTF8-encode via the RTL - the same ANSI/UTF-8 seam
        // TerminalHost uses; the LIVE render never goes through here.
        {$IFDEF FPC}
        LBuilder.Append(UTF8Encode(_CodepointToUtf16(_ReadCell(LX, AY).Ch)));
        {$ELSE}
        LBuilder.Append(_CodepointToUtf16(_ReadCell(LX, AY).Ch));
        {$ENDIF}
      Result := LBuilder.ToString;
    finally
      LBuilder.Free;
    end;
  finally
    FLock.Leave;
  end;
end;

function TVTermBuffer.GetDirtyRows: TArray<Integer>;
var
  LRow: Integer;
  LList: TList<Integer>;
begin
  FLock.Enter;
  try
    LList := TList<Integer>.Create;
    try
      for LRow := 0 to High(FDirty) do
        if FDirty[LRow] then
          LList.Add(LRow);
      Result := LList.ToArray;
    finally
      LList.Free;
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TVTermBuffer.ClearDirty;
var
  LRow: Integer;
begin
  FLock.Enter;
  try
    for LRow := 0 to High(FDirty) do
      FDirty[LRow] := False;
  finally
    FLock.Leave;
  end;
end;

{ session persistence (ESP-024 OP1) ----------------------------------------- }

function TVTermBuffer._SgrColor(const AColor: TCellColor;
  const AIsBg: Boolean): string;
var
  LIntro: string;
begin
  if AIsBg then
    LIntro := '48'
  else
    LIntro := '38';
  case AColor.Kind of
    ckIndexed:
      Result := LIntro + ';5;' + UIntToStr(AColor.Value);
    ckRGB:
      Result := LIntro + ';2;' +
        UIntToStr((AColor.Value shr 16) and $FF) + ';' +
        UIntToStr((AColor.Value shr 8) and $FF) + ';' +
        UIntToStr(AColor.Value and $FF);
  else
    if AIsBg then
      Result := '49'
    else
      Result := '39';
  end;
end;

function TVTermBuffer._SgrFor(const ACell: TTerminalCell): string;
var
  LParts: string;
begin
  LParts := '0';
  if caBold in ACell.Attrs then
    LParts := LParts + ';1';
  if caItalic in ACell.Attrs then
    LParts := LParts + ';3';
  if caUnderline in ACell.Attrs then
    LParts := LParts + ';4';
  if caInverse in ACell.Attrs then
    LParts := LParts + ';7';
  LParts := LParts + ';' + _SgrColor(ACell.Fg, False);
  LParts := LParts + ';' + _SgrColor(ACell.Bg, True);
  Result := #27'[' + LParts + 'm';
end;

function TVTermBuffer._SerializeGrid: TJSONArray;
var
  LRow, LX: Integer;
  LRowArr, LCellArr: TJSONArray;
  LCell: TTerminalCell;
begin
  Result := TJSONArray.Create;
  for LRow := 0 to FRows - 1 do
  begin
    LRowArr := TJSONArray.Create;
    for LX := 0 to FCols - 1 do
    begin
      LCell := _ReadCell(LX, LRow);
      LCellArr := TJSONArray.Create;
      // The shim's TJSONArray exposes only Add(TJSONValue)/Add(string), not the
      // scalar Add(Integer)/Add(Int64) System.JSON adds; AddElement(TJSONNumber)
      // is the common surface and lands the identical number node (System.JSON's
      // scalar Add is itself just AddElement(TJSONNumber.Create(...))). Int64
      // carries the full Cardinal color value as a positive decimal - same wire.
      LCellArr.AddElement(TJSONNumber.Create(Int64(LongWord(LCell.Ch))));
      LCellArr.AddElement(TJSONNumber.Create(Int64(Ord(LCell.Fg.Kind))));
      LCellArr.AddElement(TJSONNumber.Create(Int64(LCell.Fg.Value)));
      LCellArr.AddElement(TJSONNumber.Create(Int64(Ord(LCell.Bg.Kind))));
      LCellArr.AddElement(TJSONNumber.Create(Int64(LCell.Bg.Value)));
      LCellArr.AddElement(TJSONNumber.Create(Int64(Byte(LCell.Attrs))));
      LRowArr.AddElement(LCellArr);
    end;
    Result.AddElement(LRowArr);
  end;
end;

function TVTermBuffer._DeserializeCell(
  const AArray: TJSONArray): TTerminalCell;
begin
  // Empty path = this element itself; the second arg is the on-miss default the
  // shim's GetValue<T> requires (System.JSON accepts the same two-arg form, used
  // throughout the swept core). The elements are always present here, so the
  // default is inert and the decoded values are identical on both compilers.
  // Same gate as the libvterm door. A saved grid is just bytes on disk: it can
  // predate this fix, or be hand-edited, and a restored session must not be able
  // to crash a paint that a live session no longer can.
  Result.Ch := TTerminalCell.ScalarFromVTerm(
    LongWord(AArray.Items[0].GetValue<Integer>('', 0)));
  Result.Fg.Kind := TColorKind(AArray.Items[1].GetValue<Integer>('', 0));
  Result.Fg.Value := Cardinal(AArray.Items[2].GetValue<Int64>('', 0));
  Result.Bg.Kind := TColorKind(AArray.Items[3].GetValue<Integer>('', 0));
  Result.Bg.Value := Cardinal(AArray.Items[4].GetValue<Int64>('', 0));
  Result.Attrs := TCellAttrs(Byte(AArray.Items[5].GetValue<Integer>('', 0)));
end;

function TVTermBuffer._BuildRestoreText(const AGrid: TJSONArray;
  const ACurX, ACurY: Integer): string;
var
  LRow, LX: Integer;
  LRowArr: TJSONArray;
  LCell: TTerminalCell;
  LBuilder: TStringBuilder;
begin
  LBuilder := TStringBuilder.Create;
  try
    LBuilder.Append(#27'[2J');
    for LRow := 0 to AGrid.Count - 1 do
    begin
      LRowArr := AGrid.Items[LRow] as TJSONArray;
      LBuilder.Append(#27'[').Append(LRow + 1).Append(';1H');
      for LX := 0 to LRowArr.Count - 1 do
      begin
        LCell := _DeserializeCell(LRowArr.Items[LX] as TJSONArray);
        // Skipping the covered column is what makes the restore CORRECT, not just
        // tidy: this stream is fed back INTO libvterm, which re-creates the gap
        // itself from the wide glyph. Emitting a space here would shift the rest
        // of the row one column right on every save/restore.
        if caWideGap in LCell.Attrs then
          Continue;
        // Ch is a UCS4Char codepoint: see RowText for the per-compiler encoding.
        // Byte-identical on Delphi for the BMP; astral scalars now round-trip.
        {$IFDEF FPC}
        LBuilder.Append(_SgrFor(LCell)).Append(UTF8Encode(_CodepointToUtf16(LCell.Ch)));
        {$ELSE}
        LBuilder.Append(_SgrFor(LCell)).Append(_CodepointToUtf16(LCell.Ch));
        {$ENDIF}
      end;
    end;
    LBuilder.Append(#27'[').Append(ACurY + 1).Append(';')
      .Append(ACurX + 1).Append('H');
    Result := LBuilder.ToString;
  finally
    LBuilder.Free;
  end;
end;

function TVTermBuffer.SaveStateJSON: string;
var
  LObj: TJSONObject;
begin
  FLock.Enter;
  try
    LObj := TJSONObject.Create;
    try
      // TJSONNumber.Create carries only Int64/Double overloads on the shim, so an
      // Integer argument is cast to Int64 to bind unambiguously (System.JSON's
      // Create(Int64) yields the identical decimal - same wire format).
      LObj.AddPair('version', TJSONNumber.Create(Int64(VTERMBUFFER_STATE_VERSION)));
      LObj.AddPair('cols', TJSONNumber.Create(Int64(FCols)));
      LObj.AddPair('rows', TJSONNumber.Create(Int64(FRows)));
      LObj.AddPair('cursorX', TJSONNumber.Create(Int64(FCursorX)));
      LObj.AddPair('cursorY', TJSONNumber.Create(Int64(FCursorY)));
      LObj.AddPair('grid', _SerializeGrid);
      Result := LObj.ToJSON;
    finally
      LObj.Free;
    end;
  finally
    FLock.Leave;
  end;
end;

function TVTermBuffer.LoadStateJSON(const AJSON: string): Boolean;
var
  LObj: TJSONObject;
  LGrid: TJSONArray;
  LText: string;
  LCurX, LCurY: Integer;
begin
  Result := False;
  if AJSON.Trim = '' then
    Exit;
  LObj := TJSONObject.ParseJSONValue(AJSON) as TJSONObject;
  if not Assigned(LObj) then
    Exit;
  try
    if LObj.GetValue<Integer>('version', 0) <> VTERMBUFFER_STATE_VERSION then
      Exit;
    LGrid := LObj.GetValue('grid') as TJSONArray;
    if not Assigned(LGrid) then
      Exit;
    LCurX := LObj.GetValue<Integer>('cursorX', 0);
    LCurY := LObj.GetValue<Integer>('cursorY', 0);
    LText := _BuildRestoreText(LGrid, LCurX, LCurY);
  finally
    LObj.Free;
  end;
  Reset;
  Feed(LText);
  Result := True;
end;

function TVTermBuffer.ScrollbackLinkAt(const ALine, ACol: Integer): string;
// Mirrors GetLinkAt for scrollback coordinates. Linear-scan over the per-
// line range list — typical OSC 8 burst leaves 0..3 ranges per row, well
// below the threshold where binary search wins. ESP-034 §Scope item 5.
var
  LRange: TLinkRange;
  LRanges: TArray<TLinkRange>;
  LFor: Integer;
begin
  Result := '';
  FLock.Enter;
  try
    if (ALine < 0) or (ACol < 0) then Exit;
    if ALine >= FScrollbackLinks.Count then Exit;
    LRanges := FScrollbackLinks[ALine];
    for LFor := 0 to High(LRanges) do
    begin
      LRange := LRanges[LFor];
      if (ACol >= LRange.StartCol) and (ACol < LRange.EndCol) then
      begin
        if (LRange.UrlIdx > 0) and (LRange.UrlIdx < FUrlPool.Count) then
          Result := FUrlPool[LRange.UrlIdx];
        Exit;
      end;
    end;
  finally
    FLock.Leave;
  end;
end;

function TVTermBuffer.ScrollbackContinuation(const ALine: Integer): Boolean;
begin
  Result := False;
  FLock.Enter;
  try
    if (ALine >= 0) and (ALine < FScrollback.Count) then
      Result := FScrollback[ALine].Continuation;
  finally
    FLock.Leave;
  end;
end;

function TVTermBuffer.ScrollbackLinkRanges(
  const ALine: Integer): TArray<TLinkRange>;
begin
  Result := nil;
  FLock.Enter;
  try
    if (ALine >= 0) and (ALine < FScrollbackLinks.Count) then
      Result := Copy(FScrollbackLinks[ALine]);
  finally
    FLock.Leave;
  end;
end;

{$IFDEF DEBUG}
procedure TVTermBuffer.SeedScrollbackForTest(
  const ARows: TArray<TScrollbackRow>;
  const ALinks: TArray<TArray<TLinkRange> >);
var
  LFor: Integer;
begin
  FLock.Enter;
  try
    FScrollback.Clear;
    FScrollbackLinks.Clear;
    for LFor := 0 to High(ARows) do
      FScrollback.Add(ARows[LFor]);
    for LFor := 0 to High(ALinks) do
      FScrollbackLinks.Add(Copy(ALinks[LFor]));
    // Pad FScrollbackLinks if the test seeded fewer link rows than scrollback
    // rows so the two arrays stay parallel — matches the production invariant
    // maintained by _HandlePushLine.
    while FScrollbackLinks.Count < FScrollback.Count do
      FScrollbackLinks.Add(nil);
  finally
    FLock.Leave;
  end;
end;

procedure TVTermBuffer.SetScrollbackCapForTest(const ACap: Integer);
begin
  FLock.Enter;
  try
    FScrollbackCap := Max(ACap, 1);
    while FScrollback.Count > FScrollbackCap do
      FScrollback.Delete(0);
    while FScrollbackLinks.Count > FScrollbackCap do
      FScrollbackLinks.Delete(0);
  finally
    FLock.Leave;
  end;
end;
{$ENDIF}

function TVTermBuffer.GetSixelImages: TArray<TSixelPlacement>;
var
  LFor: Integer;
begin
  FLock.Enter;
  try
    SetLength(Result, FSixelImages.Count);
    for LFor := 0 to FSixelImages.Count - 1 do
      Result[LFor] := FSixelImages[LFor];
  finally
    FLock.Leave;
  end;
end;

{$IFDEF DEBUG}
procedure TVTermBuffer.SetSixelCapForTest(const ACap: Integer);
var
  LTotalBytes: Int64;
  LFor: Integer;
begin
  FLock.Enter;
  try
    FSixelImageCap := Max(ACap, 1);
    LTotalBytes := 0;
    for LFor := 0 to FSixelImages.Count - 1 do
      Inc(LTotalBytes, Length(FSixelImages[LFor].Pixels));
    while (FSixelImages.Count > 0) and (LTotalBytes > FSixelImageCap) do
    begin
      Dec(LTotalBytes, Length(FSixelImages[0].Pixels));
      FSixelImages.Delete(0);
    end;
  finally
    FLock.Leave;
  end;
end;
{$ENDIF}

end.


