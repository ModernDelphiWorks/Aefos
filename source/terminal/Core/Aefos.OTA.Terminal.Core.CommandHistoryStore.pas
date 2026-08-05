unit Aefos.OTA.Terminal.Core.CommandHistoryStore;

{
  Versioned JSON persistence for the command-history ring (ESP-078 / ADR-078-03 /
  BR5). Mirrors Aefos.OTA.Terminal.Core.ActionStore: a `formatVersion`
  field, an atomic temp+rename write, and a missing / empty / corrupt /
  unknown-version file resolving to an empty ring without raising.

  Persists `command-history.json` under
  %APPDATA%\ModernDelphiWorks\Aefos.OTA.Terminal. The on-disk shape is a
  formatVersion=1 root carrying a "commands" array ordered oldest..newest — the
  chronological (newest-last) order produced by TCommandHistoryRing.Snapshot.
  VCL-free / OTA-free. See [[mobaxterm-ux-reference]].
}

interface

uses
  Aefos.OTA.Terminal.Core.CommandHistory;

const
  /// <summary>
  ///   Current command-history.json payload format. A file carrying a different
  ///   version is treated as corrupt and resolves to an empty ring.
  /// </summary>
  COMMAND_HISTORY_STORE_FORMAT_VERSION = 1;

type
  /// <summary>
  ///   Loads / saves a TCommandHistoryRing to versioned JSON. A missing,
  ///   unreadable, corrupt, or unknown-version file yields an empty ring without
  ///   raising (BR5); writes are atomic (temp file + rename).
  /// </summary>
  TCommandHistoryStore = class
  private
    FFilePath: string;
    class function _DefaultFilePath: string; static;
    class procedure _WriteAtomic(const AFilePath, AContent: string); static;
    class function _ReadCommands(const AFilePath: string;
      out ACommands: TArray<string>): Boolean; static;
  public
    /// <summary>Creates a store over command-history.json in the config dir.</summary>
    constructor Create; overload;
    /// <summary>Creates a store over an explicit file path (used by tests).</summary>
    constructor Create(const AFilePath: string); overload;

    /// <summary>
    ///   Per-terminal-type history file: a fixed <c>command-history\</c> folder
    ///   with one <c>&lt;type&gt;.json</c> per shell type (cmd / pwsh / wsl /
    ///   git-bash / claude), so each type keeps its OWN history. AShellKey is
    ///   sanitized to a safe filename; '' -> 'default'.
    /// </summary>
    class function PathForShell(const AShellKey: string): string; static;

    /// <summary>
    ///   Replaces <c>ARing</c> with the persisted commands. A missing, empty,
    ///   corrupt, or unknown-version file leaves the ring empty without raising.
    /// </summary>
    procedure Load(const ARing: TCommandHistoryRing);
    /// <summary>Serializes <c>ARing</c> to disk with an atomic write.</summary>
    procedure Save(const ARing: TCommandHistoryRing);

    /// <summary>Absolute path of the backing command-history.json file.</summary>
    property FilePath: string read FFilePath;
  end;

implementation

uses
  System.SysUtils, System.IOUtils, System.JSON;

{ TCommandHistoryStore }

class function TCommandHistoryStore._DefaultFilePath: string;
var
  LAppData: string;
  LDir: string;
begin
  LAppData := GetEnvironmentVariable('APPDATA');
  if LAppData = '' then
    LAppData := TPath.GetHomePath;
  LDir := TPath.Combine(TPath.Combine(LAppData, 'ModernDelphiWorks'),
    'Aefos.OTA.Terminal');
  Result := TPath.Combine(LDir, 'command-history.json');
end;

constructor TCommandHistoryStore.Create;
begin
  Create(_DefaultFilePath);
end;

class function TCommandHistoryStore.PathForShell(const AShellKey: string): string;
var
  LBaseDir, LKey: string;
  LIdx: Integer;
begin
  // Fixed 'command-history' folder under the config dir, one file per type.
  LBaseDir := TPath.GetDirectoryName(_DefaultFilePath);
  LKey := AShellKey;
  if LKey = '' then
    LKey := 'default';
  for LIdx := Low(LKey) to High(LKey) do  // sanitize -> safe filename
    if not CharInSet(LKey[LIdx], ['a'..'z', 'A'..'Z', '0'..'9', '-', '_']) then
      LKey[LIdx] := '_';
  Result := TPath.Combine(TPath.Combine(LBaseDir, 'command-history'),
    LKey + '.json');
end;

constructor TCommandHistoryStore.Create(const AFilePath: string);
begin
  inherited Create;
  FFilePath := AFilePath;
end;

class procedure TCommandHistoryStore._WriteAtomic(const AFilePath,
  AContent: string);
var
  LDir: string;
  LTempPath: string;
begin
  LDir := TPath.GetDirectoryName(AFilePath);
  if (LDir <> '') and not TDirectory.Exists(LDir) then
    TDirectory.CreateDirectory(LDir);

  LTempPath := AFilePath + '.tmp';
  TFile.WriteAllText(LTempPath, AContent, TEncoding.UTF8);

  if TFile.Exists(AFilePath) then
    TFile.Delete(AFilePath);
  TFile.Move(LTempPath, AFilePath);
end;

class function TCommandHistoryStore._ReadCommands(const AFilePath: string;
  out ACommands: TArray<string>): Boolean;
var
  LContent: string;
  LValue: TJSONValue;
  LRoot: TJSONObject;
  LArray: TJSONArray;
  LItem: TJSONValue;
  LList: TArray<string>;
begin
  ACommands := nil;
  Result := False;
  if not TFile.Exists(AFilePath) then
    Exit;

  LValue := nil;
  try
    LContent := TFile.ReadAllText(AFilePath);
    if LContent.Trim = '' then
      Exit;

    LValue := TJSONObject.ParseJSONValue(LContent);
    if not (LValue is TJSONObject) then
      Exit;

    LRoot := TJSONObject(LValue);
    if LRoot.GetValue<Integer>('formatVersion', 0)
       <> COMMAND_HISTORY_STORE_FORMAT_VERSION then
      Exit;

    LArray := LRoot.GetValue('commands') as TJSONArray;
    if not Assigned(LArray) then
      Exit;

    SetLength(LList, 0);
    for LItem in LArray do
      if LItem is TJSONString then
      begin
        SetLength(LList, Length(LList) + 1);
        LList[High(LList)] := TJSONString(LItem).Value;
      end;
    ACommands := LList;
    Result := True;
  finally
    LValue.Free;
  end;
end;

procedure TCommandHistoryStore.Load(const ARing: TCommandHistoryRing);
var
  LCommands: TArray<string>;
begin
  if not Assigned(ARing) then
    Exit;
  ARing.Clear;
  try
    if _ReadCommands(FFilePath, LCommands) then
      ARing.ReplaceAll(LCommands);
  except
    // Resilient persistence (BR5): any read/parse failure → empty ring, no raise.
    ARing.Clear;
  end;
end;

procedure TCommandHistoryStore.Save(const ARing: TCommandHistoryRing);
var
  LRoot: TJSONObject;
  LArray: TJSONArray;
  LCommand: string;
begin
  if not Assigned(ARing) then
    Exit;

  LRoot := TJSONObject.Create;
  try
    LRoot.AddPair('formatVersion',
      TJSONNumber.Create(COMMAND_HISTORY_STORE_FORMAT_VERSION));
    LArray := TJSONArray.Create;
    for LCommand in ARing.Snapshot do
      LArray.Add(LCommand);
    LRoot.AddPair('commands', LArray);
    _WriteAtomic(FFilePath, LRoot.ToJSON);
  finally
    LRoot.Free;
  end;
end;

end.
