unit Aefos.OTA.Chat.Core.PaletteState;

{
  Persistence service for the command palette (ESP-002, Epic 2/4,
  Demand 4/4).

  Reads and writes <root>\.aefos\palette-state.json. Mirrors the
  Demand 1/4 TConfigService shape:
    - TFunc<string> project-root resolver (C-3, OTA-free).
    - Atomic <path>.tmp + TFile.Move overwrite (BR-3 / ADR-049).
    - Hand-rolled UTF-8 (no BOM) two-space JSON serialiser (C-7, BR-8).
    - Silent defaults on missing root / missing file / malformed JSON
      / unknown enum strings (BR-2 / BR-6 / ADR-052), logged via
      OutputDebugString.
    - Defensive RECENTS_MAX clamp on Load (BR-5).

  Save raises EPaletteStateSaveFailed when the project root is empty
  or the underlying write fails — never raised by Load.
}

interface

uses
  System.SysUtils,
  Aefos.OTA.Chat.Core.CommandPalette.Types,
  Aefos.OTA.Chat.Core.PaletteState.Types;

type
  TPaletteStateService = class(TInterfacedObject, IPaletteState)
  private
    FRootResolver: TFunc<string>;
    function _ResolveStateDir: string;
    function _ResolveStatePath: string;
    function _ParseRecents(const AJson: string): TArray<TCommandEntry>;
    function _SerializeRecents(
      const ARecents: TArray<TCommandEntry>): string;
    procedure _WriteAtomic(const APath, AContent: string);
    function _KindToString(const AKind: TCommandKind): string;
    function _ActionIdToString(const AId: TActionId): string;
    function _TryStringToKind(const AInput: string;
      out AKind: TCommandKind): Boolean;
    function _TryStringToActionId(const AInput: string;
      out AId: TActionId): Boolean;
    function _BuildEntryFromJson(const AItem: TObject;
      out AEntry: TCommandEntry): Boolean;
  public
    constructor Create(const ARootResolver: TFunc<string>);
    function Load: TArray<TCommandEntry>;
    procedure Save(const ARecents: TArray<TCommandEntry>);
  end;

const
  RECENTS_MAX = 10;

implementation

uses
  Winapi.Windows,
  System.Classes,
  System.Generics.Collections,
  System.IOUtils,
  System.JSON,
  Aefos.OTA.Chat.Core.Dispatcher.Decode;

const
  STATE_DIR_REL = '.aefos';
  STATE_FILE_NAME = 'palette-state.json';
  KEY_RECENTS = 'recents';
  KEY_NAME = 'name';
  KEY_KIND = 'kind';
  KEY_DESCRIPTION = 'description';
  KEY_COMMAND_NAME = 'command_name';
  KEY_ACTION_ID = 'action_id';
  KIND_COMMAND = 'command';
  KIND_ACTION = 'action';
  ACTION_AGENT_SUGGEST = 'agent_suggest';
  ACTION_COMMAND_REPLICATE = 'command_replicate';
  ACTION_CONFIGURATION = 'configuration';

constructor TPaletteStateService.Create(const ARootResolver: TFunc<string>);
begin
  inherited Create;
  if not Assigned(ARootResolver) then
    raise EArgumentNilException.Create('TPaletteStateService: ARootResolver');
  FRootResolver := ARootResolver;
end;

function TPaletteStateService._ResolveStateDir: string;
var
  LRoot: string;
begin
  LRoot := FRootResolver();
  if LRoot = '' then
    Exit('');
  Result := TPath.Combine(LRoot, STATE_DIR_REL);
end;

function TPaletteStateService._ResolveStatePath: string;
var
  LDir: string;
begin
  LDir := _ResolveStateDir;
  if LDir = '' then
    Exit('');
  Result := TPath.Combine(LDir, STATE_FILE_NAME);
end;

function TPaletteStateService._KindToString(const AKind: TCommandKind): string;
begin
  case AKind of
    ckCommand:  Result := KIND_COMMAND;
    ckAction: Result := KIND_ACTION;
  else
    Result := KIND_COMMAND;
  end;
end;

function TPaletteStateService._ActionIdToString(const AId: TActionId): string;
begin
  case AId of
    aiAgentSuggest:   Result := ACTION_AGENT_SUGGEST;
    aiCommandReplicate: Result := ACTION_COMMAND_REPLICATE;
    aiConfiguration:  Result := ACTION_CONFIGURATION;
  else
    Result := ACTION_AGENT_SUGGEST;
  end;
end;

function TPaletteStateService._TryStringToKind(const AInput: string;
  out AKind: TCommandKind): Boolean;
begin
  Result := True;
  if SameText(AInput, KIND_COMMAND) then
    AKind := ckCommand
  else if SameText(AInput, KIND_ACTION) then
    AKind := ckAction
  else
    Result := False;
end;

function TPaletteStateService._TryStringToActionId(const AInput: string;
  out AId: TActionId): Boolean;
begin
  Result := True;
  if SameText(AInput, ACTION_AGENT_SUGGEST) then
    AId := aiAgentSuggest
  else if SameText(AInput, ACTION_COMMAND_REPLICATE) then
    AId := aiCommandReplicate
  else if SameText(AInput, ACTION_CONFIGURATION) then
    AId := aiConfiguration
  else
    Result := False;
end;

function TPaletteStateService._BuildEntryFromJson(const AItem: TObject;
  out AEntry: TCommandEntry): Boolean;
var
  LObject: TJSONObject;
  LKindStr: string;
  LActionStr: string;
  LField: TJSONValue;
begin
  Result := False;
  AEntry := Default(TCommandEntry);
  if not (AItem is TJSONObject) then
    Exit;
  LObject := TJSONObject(AItem);
  LField := LObject.GetValue(KEY_NAME);
  if not (LField is TJSONString) then
    Exit;
  AEntry.Name := TJSONString(LField).Value;
  LField := LObject.GetValue(KEY_DESCRIPTION);
  if LField is TJSONString then
    AEntry.Description := TJSONString(LField).Value;
  LField := LObject.GetValue(KEY_COMMAND_NAME);
  if LField is TJSONString then
    AEntry.CommandName := TJSONString(LField).Value;
  LField := LObject.GetValue(KEY_KIND);
  if not (LField is TJSONString) then
    Exit;
  LKindStr := TJSONString(LField).Value;
  if not _TryStringToKind(LKindStr, AEntry.Kind) then
  begin
    OutputDebugString(PChar(
      'Aefos.PaletteState: skipping entry with unknown kind "'
      + LKindStr + '"'));
    Exit;
  end;
  LField := LObject.GetValue(KEY_ACTION_ID);
  if LField is TJSONString then
    LActionStr := TJSONString(LField).Value
  else
    LActionStr := ACTION_AGENT_SUGGEST;
  if not _TryStringToActionId(LActionStr, AEntry.ActionId) then
  begin
    OutputDebugString(PChar(
      'Aefos.PaletteState: skipping entry with unknown action_id "'
      + LActionStr + '"'));
    Exit;
  end;
  Result := True;
end;

function TPaletteStateService._ParseRecents(
  const AJson: string): TArray<TCommandEntry>;
var
  LValue: TJSONValue;
  LRoot: TJSONObject;
  LArrayValue: TJSONValue;
  LArray: TJSONArray;
  LResult: TArray<TCommandEntry>;
  LCount: Integer;
  LIndex: Integer;
  LEntry: TCommandEntry;
begin
  SetLength(Result, 0);
  LValue := TJSONObject.ParseJSONValue(AJson);
  try
    if not (LValue is TJSONObject) then
    begin
      OutputDebugString(
        'Aefos.PaletteState: malformed JSON, returning empty list');
      Exit;
    end;
    LRoot := TJSONObject(LValue);
    LArrayValue := LRoot.GetValue(KEY_RECENTS);
    if not (LArrayValue is TJSONArray) then
      Exit;
    LArray := TJSONArray(LArrayValue);
    SetLength(LResult, LArray.Count);
    LCount := 0;
    for LIndex := 0 to LArray.Count - 1 do
    begin
      if _BuildEntryFromJson(LArray.Items[LIndex], LEntry) then
      begin
        LResult[LCount] := LEntry;
        Inc(LCount);
      end;
    end;
    SetLength(LResult, LCount);
    if Length(LResult) > RECENTS_MAX then
      SetLength(LResult, RECENTS_MAX);
    Result := LResult;
  finally
    LValue.Free;
  end;
end;

function TPaletteStateService.Load: TArray<TCommandEntry>;
var
  LPath: string;
  LBytes: TBytes;
  LJson: string;
begin
  SetLength(Result, 0);
  LPath := _ResolveStatePath;
  if LPath = '' then
    Exit;
  if not TFile.Exists(LPath) then
    Exit;
  try
    LBytes := TFile.ReadAllBytes(LPath);
    LJson := TEncoding.UTF8.GetString(LBytes);
    Result := _ParseRecents(LJson);
  except
    on E: Exception do
    begin
      OutputDebugString(PChar(
        'Aefos.PaletteState: read failed, returning empty list: '
        + E.Message));
      SetLength(Result, 0);
    end;
  end;
end;

function TPaletteStateService._SerializeRecents(
  const ARecents: TArray<TCommandEntry>): string;
var
  LBuilder: TStringBuilder;
  LIndex: Integer;
  LIsLast: Boolean;
begin
  LBuilder := TStringBuilder.Create;
  try
    LBuilder.Append('{').Append(sLineBreak);
    if Length(ARecents) = 0 then
    begin
      LBuilder.Append('  "').Append(KEY_RECENTS).Append('": []').Append(sLineBreak);
    end
    else
    begin
      LBuilder.Append('  "').Append(KEY_RECENTS).Append('": [').Append(sLineBreak);
      for LIndex := 0 to High(ARecents) do
      begin
        LIsLast := LIndex = High(ARecents);
        LBuilder.Append('    {').Append(sLineBreak);
        LBuilder.Append('      "').Append(KEY_NAME).Append('": "')
          .Append(TCliText.EscapeJsonString(ARecents[LIndex].Name)).Append('",').Append(sLineBreak);
        LBuilder.Append('      "').Append(KEY_KIND).Append('": "')
          .Append(_KindToString(ARecents[LIndex].Kind)).Append('",').Append(sLineBreak);
        LBuilder.Append('      "').Append(KEY_DESCRIPTION).Append('": "')
          .Append(TCliText.EscapeJsonString(ARecents[LIndex].Description)).Append('",').Append(sLineBreak);
        LBuilder.Append('      "').Append(KEY_COMMAND_NAME).Append('": "')
          .Append(TCliText.EscapeJsonString(ARecents[LIndex].CommandName)).Append('",').Append(sLineBreak);
        LBuilder.Append('      "').Append(KEY_ACTION_ID).Append('": "')
          .Append(_ActionIdToString(ARecents[LIndex].ActionId)).Append('"').Append(sLineBreak);
        if LIsLast then
          LBuilder.Append('    }').Append(sLineBreak)
        else
          LBuilder.Append('    },').Append(sLineBreak);
      end;
      LBuilder.Append('  ]').Append(sLineBreak);
    end;
    LBuilder.Append('}').Append(sLineBreak);
    Result := LBuilder.ToString;
  finally
    LBuilder.Free;
  end;
end;

procedure TPaletteStateService._WriteAtomic(const APath, AContent: string);
var
  LTempPath: string;
  LStream: TFileStream;
  LBytes: TBytes;
  LDir: string;
begin
  LDir := TPath.GetDirectoryName(APath);
  if (LDir <> '') and not TDirectory.Exists(LDir) then
    TDirectory.CreateDirectory(LDir);
  LTempPath := APath + '.tmp';
  LBytes := TEncoding.UTF8.GetBytes(AContent);
  LStream := TFileStream.Create(LTempPath, fmCreate);
  try
    if Length(LBytes) > 0 then
      LStream.WriteBuffer(LBytes[0], Length(LBytes));
  finally
    LStream.Free;
  end;
  try
    if TFile.Exists(APath) then
      TFile.Delete(APath);
    TFile.Move(LTempPath, APath);
  except
    on E: Exception do
    begin
      try
        if TFile.Exists(LTempPath) then
          TFile.Delete(LTempPath);
      except
        // best-effort cleanup
      end;
      raise EPaletteStateSaveFailed.CreateFmt(
        'Cannot persist palette state to "%s": %s', [APath, E.Message]);
    end;
  end;
end;

procedure TPaletteStateService.Save(const ARecents: TArray<TCommandEntry>);
var
  LPath: string;
  LSerialized: string;
begin
  LPath := _ResolveStatePath;
  if LPath = '' then
    raise EPaletteStateSaveFailed.Create(
      'Cannot save palette state: project root is unavailable');
  LSerialized := _SerializeRecents(ARecents);
  _WriteAtomic(LPath, LSerialized);
end;

end.
