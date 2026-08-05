unit Aefos.OTA.Terminal.Core.CommandHistory;

{
  Pure command-history spine for ESP-078 (ADR-078-01 / ADR-078-02 / BR2).

  TCommandLineTap reconstructs submitted command lines from raw input chunks fed
  off the host input funnel: printable runs accumulate, backspace edits the
  buffer, ESC/CSI control sequences are filtered (never stored), and a line
  terminator (#13/#10) emits exactly one completed command (whitespace-only
  flushes dropped). TCommandHistoryRing holds the completed commands in a bounded
  FIFO with consecutive-dedup and a newest-first read API.

  VCL-free and OTA-free so it is headless-testable (target >= 80% coverage). The
  live capture wiring (feed after the passthrough write) and the persistence are
  attached by other units (TerminalHost / CommandHistoryStore). See
  [[mobaxterm-ux-reference]].
}

interface

uses
  System.SysUtils, System.Generics.Collections;

const
  /// <summary>Default ring capacity (ESP-078 assumption; tunable, not user-set).</summary>
  COMMAND_HISTORY_DEFAULT_CAPACITY = 200;

type
  /// <summary>Fired once per reconstructed command on a line terminator.</summary>
  TCommandLineEvent = reference to procedure(const ACommand: string);

  /// <summary>
  ///   Reconstructs submitted command lines from raw terminal input chunks
  ///   (ADR-078-01 best-effort). Feed it the same bytes written to the shell
  ///   (BR3, side-effect); it emits a completed command via <see cref="OnCommand"/>
  ///   each time a line terminator is seen. Pure / VCL-free.
  /// </summary>
  TCommandLineTap = class
  private
    /// <summary>ESC-sequence scanner state, so CSI/SS3 bytes are never stored.</summary>
    type TEscState = (esNone, esGotEsc, esCsi, esSs3);
  private
    FBuffer: TStringBuilder;
    FEscState: TEscState;
    FOnCommand: TCommandLineEvent;
    function _ConsumeEscape(const AChar: Char): Boolean;
    procedure _FeedChar(const AChar: Char);
    procedure _Backspace;
    procedure _Flush;
  public
    constructor Create;
    destructor Destroy; override;
    /// <summary>Feeds one input chunk; may emit zero or more completed commands.</summary>
    procedure Feed(const AChunk: string);
    /// <summary>Callback invoked with each reconstructed command (BR4-clean).</summary>
    property OnCommand: TCommandLineEvent read FOnCommand write FOnCommand;
  end;

  /// <summary>
  ///   Bounded FIFO of submitted commands (BR4). Past capacity the oldest entry
  ///   is evicted; a command equal to the current newest is suppressed
  ///   (consecutive-dedup). <see cref="Items"/> is chronological (oldest-first),
  ///   <see cref="MostRecent"/> is newest-first, and <see cref="Snapshot"/> is the
  ///   chronological (newest-last) wire order used by the store (ADR-078-03).
  /// </summary>
  TCommandHistoryRing = class
  private
    FList: TList<string>;
    FCapacity: Integer;
    function _GetCount: Integer;
    function _GetItem(const AIndex: Integer): string;
  public
    /// <summary>Creates a ring of the given capacity (&lt; 1 falls back to the default).</summary>
    constructor Create(const ACapacity: Integer = COMMAND_HISTORY_DEFAULT_CAPACITY);
    destructor Destroy; override;
    /// <summary>Appends a command, applying consecutive-dedup then capacity eviction.</summary>
    procedure Add(const ACommand: string);
    /// <summary>Empties the ring.</summary>
    procedure Clear;
    /// <summary>Replaces the contents from a chronological (newest-last) list.</summary>
    procedure ReplaceAll(const ACommands: TArray<string>);
    /// <summary>Up to <c>ACount</c> commands, newest-first.</summary>
    function MostRecent(const ACount: Integer): TArray<string>;
    /// <summary>All commands in chronological (newest-last) order for persistence.</summary>
    function Snapshot: TArray<string>;
    /// <summary>Chronological access (index 0 = oldest).</summary>
    property Items[const AIndex: Integer]: string read _GetItem; default;
    /// <summary>Number of commands currently held.</summary>
    property Count: Integer read _GetCount;
    /// <summary>Fixed maximum number of retained commands.</summary>
    property Capacity: Integer read FCapacity;
  end;

implementation

const
  /// <summary>Lowest byte that ends a CSI sequence (final byte range 0x40..0x7E).</summary>
  CSI_FINAL_LOW  = #$40;
  CSI_FINAL_HIGH = #$7E;
  /// <summary>First printable code point; anything below is a control char.</summary>
  FIRST_PRINTABLE = #$20;
  CHAR_ESC = #27;
  CHAR_BACKSPACE = #8;
  CHAR_DELETE = #127;
  CHAR_CR = #13;
  CHAR_LF = #10;

{ TCommandLineTap }

constructor TCommandLineTap.Create;
begin
  inherited Create;
  FBuffer := TStringBuilder.Create;
  FEscState := esNone;
end;

destructor TCommandLineTap.Destroy;
begin
  FBuffer.Free;
  inherited Destroy;
end;

procedure TCommandLineTap.Feed(const AChunk: string);
var
  LIndex: Integer;
begin
  for LIndex := 1 to Length(AChunk) do
    _FeedChar(AChunk[LIndex]);
end;

function TCommandLineTap._ConsumeEscape(const AChar: Char): Boolean;
begin
  // True when AChar is absorbed by an in-flight ESC sequence (never stored).
  Result := True;
  case FEscState of
    esGotEsc:
      if AChar = '[' then
        FEscState := esCsi
      else if AChar = 'O' then
        FEscState := esSs3
      else
        FEscState := esNone; // two-char escape (ESC + one byte) consumed
    esCsi:
      if (AChar >= CSI_FINAL_LOW) and (AChar <= CSI_FINAL_HIGH) then
        FEscState := esNone; // final byte ends the CSI sequence
    esSs3:
      FEscState := esNone;   // single final byte ends the SS3 sequence
  else
    Result := False;
  end;
end;

procedure TCommandLineTap._FeedChar(const AChar: Char);
begin
  if _ConsumeEscape(AChar) then
    Exit;

  case AChar of
    CHAR_ESC:
      FEscState := esGotEsc;
    CHAR_BACKSPACE, CHAR_DELETE:
      _Backspace;
    CHAR_CR, CHAR_LF:
      _Flush;
  else
    // Printable runs accumulate; other control chars are dropped (BR4).
    if AChar >= FIRST_PRINTABLE then
      FBuffer.Append(AChar);
  end;
end;

procedure TCommandLineTap._Backspace;
begin
  if FBuffer.Length > 0 then
    FBuffer.Remove(FBuffer.Length - 1, 1);
end;

procedure TCommandLineTap._Flush;
var
  LCommand: string;
begin
  LCommand := FBuffer.ToString;
  FBuffer.Clear;
  if LCommand.Trim = '' then
    Exit; // whitespace-only flush dropped (BR4)
  if Assigned(FOnCommand) then
    FOnCommand(LCommand);
end;

{ TCommandHistoryRing }

constructor TCommandHistoryRing.Create(const ACapacity: Integer);
begin
  inherited Create;
  if ACapacity < 1 then
    FCapacity := COMMAND_HISTORY_DEFAULT_CAPACITY
  else
    FCapacity := ACapacity;
  FList := TList<string>.Create;
end;

destructor TCommandHistoryRing.Destroy;
begin
  FList.Free;
  inherited Destroy;
end;

procedure TCommandHistoryRing.Add(const ACommand: string);
begin
  // Consecutive-dedup: skip a command identical to the current newest (BR4).
  if (FList.Count > 0) and (FList.Last = ACommand) then
    Exit;
  FList.Add(ACommand);
  while FList.Count > FCapacity do
    FList.Delete(0); // evict oldest past capacity
end;

procedure TCommandHistoryRing.Clear;
begin
  FList.Clear;
end;

procedure TCommandHistoryRing.ReplaceAll(const ACommands: TArray<string>);
var
  LCommand: string;
begin
  FList.Clear;
  for LCommand in ACommands do
    Add(LCommand); // re-applies dedup + capacity
end;

function TCommandHistoryRing.MostRecent(const ACount: Integer): TArray<string>;
var
  LTake, LIndex: Integer;
begin
  LTake := ACount;
  if LTake > FList.Count then
    LTake := FList.Count;
  if LTake < 0 then
    LTake := 0;
  SetLength(Result, LTake);
  for LIndex := 0 to LTake - 1 do
    Result[LIndex] := FList[FList.Count - 1 - LIndex]; // newest-first
end;

function TCommandHistoryRing.Snapshot: TArray<string>;
begin
  Result := FList.ToArray; // chronological, newest-last (ADR-078-03 wire order)
end;

function TCommandHistoryRing._GetCount: Integer;
begin
  Result := FList.Count;
end;

function TCommandHistoryRing._GetItem(const AIndex: Integer): string;
begin
  Result := FList[AIndex];
end;

end.
