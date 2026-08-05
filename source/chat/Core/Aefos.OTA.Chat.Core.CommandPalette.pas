unit Aefos.OTA.Chat.Core.CommandPalette;

{
  Command palette logic (ESP-002, Epic 2/4, Demands 2/4 + 3/4).

  Pure logic: merged lookup over an action catalog (live plugin actions)
  and a command registry, plus in-memory LIFO recents capped at 10. No OTA,
  no VCL, no Win32, no file I/O.

  - ADR-041: case-insensitive substring match against Name + Description.
  - ADR-042: in-memory recents only (Demand 4/4 owns persistence).
  - ADR-043: FRegistry.List called on every Search (no caching).
  - ADR-045: TCommandKind = (ckCommand, ckAction); palette is kind-agnostic.
  - ADR-046: IActionCatalog supplies the live actions; both collaborators
    are required at construction (nil raises EArgumentNilException).
  - ADR-047: search results return actions first (alphabetical) then commands
    (alphabetical) for deterministic ordering across kinds.
  - ADR-049/050/053 (Demand 4/4): IPaletteState seeds recents from disk on
    construction and persists them on AddRecent. Nil AState disables
    persistence (test-only path); save failures are swallowed so the
    in-memory list remains intact.
}

interface

uses
  Aefos.OTA.Chat.Core.CommandRegistry.Types,
  Aefos.OTA.Chat.Core.CommandPalette.Types,
  Aefos.OTA.Chat.Core.PaletteState.Types;

type
  TCommandPalette = class(TInterfacedObject, ICommandPalette)
  private
    FRegistry: ICommandRegistry;
    FActions: IActionCatalog;
    FState: IPaletteState;
    FRecents: TArray<TCommandEntry>;
    function _BuildCommandEntry(const ACommand: TCommandMetadata): TCommandEntry;
    function _Matches(const AQueryLower, AField: string): Boolean;
    function _CommandIsMatch(const ACommand: TCommandMetadata;
      const AQueryLower: string): Boolean;
    function _ActionIsMatch(const AEntry: TCommandEntry;
      const AQueryLower: string): Boolean;
    function _FilterAndSortActions(
      const AQueryLower: string): TArray<TCommandEntry>;
    function _FilterAndSortCommands(
      const AQueryLower: string): TArray<TCommandEntry>;
    procedure _SortByName(var AEntries: TArray<TCommandEntry>);
    procedure _RemoveExisting(const AName: string);
    procedure _PrependEntry(const AEntry: TCommandEntry);
    procedure _CapRecents;
    procedure _PersistRecents;
    function _ValidRecents(
      const ACatalog: TArray<TCommandEntry>): TArray<TCommandEntry>;
    function _ComposeInline(const AValidRecents,
      ACatalog: TArray<TCommandEntry>): TArray<TCommandEntry>;
  public
    constructor Create(const ARegistry: ICommandRegistry;
      const AActions: IActionCatalog;
      const AState: IPaletteState);
    function Search(const AQuery: string): TArray<TCommandEntry>;
    procedure AddRecent(const AEntry: TCommandEntry);
    function GetRecents: TArray<TCommandEntry>;
    function ListForInline(const AQuery: string): TArray<TCommandEntry>;
  end;

const
  RECENTS_MAX = 10;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.Generics.Collections,
  System.Generics.Defaults;

{ TCommandPalette }

constructor TCommandPalette.Create(const ARegistry: ICommandRegistry;
  const AActions: IActionCatalog;
  const AState: IPaletteState);
begin
  inherited Create;
  if not Assigned(ARegistry) then
    raise EArgumentNilException.Create('TCommandPalette.Create: ARegistry');
  if not Assigned(AActions) then
    raise EArgumentNilException.Create('TCommandPalette.Create: AActions');
  FRegistry := ARegistry;
  FActions := AActions;
  FState := AState;
  if Assigned(FState) then
  begin
    FRecents := FState.Load;
    _CapRecents;
  end
  else
    SetLength(FRecents, 0);
end;

function TCommandPalette._BuildCommandEntry(
  const ACommand: TCommandMetadata): TCommandEntry;
begin
  Result := Default(TCommandEntry);
  Result.Name := ACommand.Name;
  Result.Description := ACommand.Description;
  Result.CommandName := ACommand.Name;
  Result.Kind := ckCommand;
end;

function TCommandPalette._Matches(const AQueryLower, AField: string): Boolean;
begin
  Result := Pos(AQueryLower, LowerCase(AField)) > 0;
end;

function TCommandPalette._CommandIsMatch(const ACommand: TCommandMetadata;
  const AQueryLower: string): Boolean;
begin
  Result := _Matches(AQueryLower, ACommand.Name)
    or _Matches(AQueryLower, ACommand.Description);
end;

function TCommandPalette._ActionIsMatch(const AEntry: TCommandEntry;
  const AQueryLower: string): Boolean;
begin
  Result := _Matches(AQueryLower, AEntry.Name)
    or _Matches(AQueryLower, AEntry.Description);
end;

function _CompareCommandEntryByName(
  const ALeft, ARight: TCommandEntry): Integer;
begin
  Result := CompareText(ALeft.Name, ARight.Name);
end;

procedure TCommandPalette._SortByName(var AEntries: TArray<TCommandEntry>);
begin
  TArray.Sort<TCommandEntry>(AEntries,
    TComparer<TCommandEntry>.Construct(_CompareCommandEntryByName));
end;

function TCommandPalette._FilterAndSortActions(
  const AQueryLower: string): TArray<TCommandEntry>;
var
  LActions: TArray<TCommandEntry>;
  LResult: TArray<TCommandEntry>;
  LIndex: Integer;
  LCount: Integer;
begin
  LActions := FActions.List;
  SetLength(LResult, Length(LActions));
  LCount := 0;
  for LIndex := 0 to High(LActions) do
  begin
    if (AQueryLower = '') or _ActionIsMatch(LActions[LIndex], AQueryLower) then
    begin
      LResult[LCount] := LActions[LIndex];
      Inc(LCount);
    end;
  end;
  SetLength(LResult, LCount);
  _SortByName(LResult);
  Result := LResult;
end;

function TCommandPalette._FilterAndSortCommands(
  const AQueryLower: string): TArray<TCommandEntry>;
var
  LCommands: TArray<TCommandMetadata>;
  LResult: TArray<TCommandEntry>;
  LIndex: Integer;
  LCount: Integer;
begin
  LCommands := FRegistry.List;
  SetLength(LResult, Length(LCommands));
  LCount := 0;
  for LIndex := 0 to High(LCommands) do
  begin
    if (AQueryLower = '') or _CommandIsMatch(LCommands[LIndex], AQueryLower) then
    begin
      LResult[LCount] := _BuildCommandEntry(LCommands[LIndex]);
      Inc(LCount);
    end;
  end;
  SetLength(LResult, LCount);
  _SortByName(LResult);
  Result := LResult;
end;

function TCommandPalette.Search(
  const AQuery: string): TArray<TCommandEntry>;
var
  LActions: TArray<TCommandEntry>;
  LCommands: TArray<TCommandEntry>;
  LResult: TArray<TCommandEntry>;
  LQueryLower: string;
  LIndex: Integer;
begin
  LQueryLower := LowerCase(AQuery);
  LActions := _FilterAndSortActions(LQueryLower);
  LCommands := _FilterAndSortCommands(LQueryLower);
  SetLength(LResult, Length(LActions) + Length(LCommands));
  for LIndex := 0 to High(LActions) do
    LResult[LIndex] := LActions[LIndex];
  for LIndex := 0 to High(LCommands) do
    LResult[Length(LActions) + LIndex] := LCommands[LIndex];
  Result := LResult;
end;

procedure TCommandPalette._RemoveExisting(const AName: string);
var
  LIndex: Integer;
  LWrite: Integer;
begin
  LWrite := 0;
  for LIndex := 0 to High(FRecents) do
  begin
    if not SameText(FRecents[LIndex].Name, AName) then
    begin
      FRecents[LWrite] := FRecents[LIndex];
      Inc(LWrite);
    end;
  end;
  SetLength(FRecents, LWrite);
end;

procedure TCommandPalette._PrependEntry(const AEntry: TCommandEntry);
var
  LIndex: Integer;
  LLength: Integer;
begin
  LLength := Length(FRecents);
  SetLength(FRecents, LLength + 1);
  for LIndex := LLength downto 1 do
    FRecents[LIndex] := FRecents[LIndex - 1];
  FRecents[0] := AEntry;
end;

procedure TCommandPalette._CapRecents;
begin
  if Length(FRecents) > RECENTS_MAX then
    SetLength(FRecents, RECENTS_MAX);
end;

procedure TCommandPalette._PersistRecents;
begin
  if not Assigned(FState) then
    Exit;
  try
    FState.Save(FRecents);
  except
    on E: EPaletteStateSaveFailed do
      OutputDebugString(PChar(
        'Aefos.PaletteState: save failed: ' + E.Message));
  end;
end;

procedure TCommandPalette.AddRecent(const AEntry: TCommandEntry);
begin
  _RemoveExisting(AEntry.Name);
  _PrependEntry(AEntry);
  _CapRecents;
  _PersistRecents;
end;

function TCommandPalette.GetRecents: TArray<TCommandEntry>;
var
  LIndex: Integer;
begin
  SetLength(Result, Length(FRecents));
  for LIndex := 0 to High(FRecents) do
    Result[LIndex] := FRecents[LIndex];
end;

function TCommandPalette._ValidRecents(
  const ACatalog: TArray<TCommandEntry>): TArray<TCommandEntry>;
var
  LResult: TArray<TCommandEntry>;
  LCount: Integer;
  LRecIndex: Integer;
  LCatIndex: Integer;
begin
  SetLength(LResult, Length(FRecents));
  LCount := 0;
  for LRecIndex := 0 to High(FRecents) do
    for LCatIndex := 0 to High(ACatalog) do
      if SameText(FRecents[LRecIndex].Name, ACatalog[LCatIndex].Name) then
      begin
        LResult[LCount] := FRecents[LRecIndex];
        Inc(LCount);
        Break;
      end;
  SetLength(LResult, LCount);
  Result := LResult;
end;

function TCommandPalette._ComposeInline(const AValidRecents,
  ACatalog: TArray<TCommandEntry>): TArray<TCommandEntry>;
var
  LResult: TArray<TCommandEntry>;
  LCount: Integer;
  LCatIndex: Integer;
  LRecIndex: Integer;
  LInRecents: Boolean;
begin
  SetLength(LResult, Length(AValidRecents) + Length(ACatalog));
  LCount := 0;
  for LRecIndex := 0 to High(AValidRecents) do
  begin
    LResult[LCount] := AValidRecents[LRecIndex];
    Inc(LCount);
  end;
  for LCatIndex := 0 to High(ACatalog) do
  begin
    LInRecents := False;
    for LRecIndex := 0 to High(AValidRecents) do
      if SameText(ACatalog[LCatIndex].Name, AValidRecents[LRecIndex].Name) then
      begin
        LInRecents := True;
        Break;
      end;
    if not LInRecents then
    begin
      LResult[LCount] := ACatalog[LCatIndex];
      Inc(LCount);
    end;
  end;
  SetLength(LResult, LCount);
  Result := LResult;
end;

function TCommandPalette.ListForInline(
  const AQuery: string): TArray<TCommandEntry>;
var
  LCatalog: TArray<TCommandEntry>;
  LValidRecents: TArray<TCommandEntry>;
begin
  if AQuery <> '' then
  begin
    Result := Search(AQuery);
    Exit;
  end;
  LCatalog := Search('');
  LValidRecents := _ValidRecents(LCatalog);
  Result := _ComposeInline(LValidRecents, LCatalog);
end;

end.
