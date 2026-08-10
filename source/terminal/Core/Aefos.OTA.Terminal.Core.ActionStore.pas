unit Aefos.OTA.Terminal.Core.ActionStore;

// delphiunicode under FPC (not the sibling terminal-core `mode delphi`): this
// unit drives the System.JSON shim (Aefos.Compat.Json), whose generic
// GetValue<T> accessors are only memory-safe when the caller's `string` is
// UnicodeString (the shim writes a UnicodeString through the typed pointer). So
// the store keeps Delphi's native UnicodeString `string`; it reads/writes the
// TTerminalAction AnsiString fields (the domain unit is `mode delphi`) across an
// implicit, UTF-8-correct conversion (LazUTF8 seeds DefaultSystemCodePage=UTF-8).
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

interface

uses
  {$IFDEF FPC}
  SysUtils, Aefos.Compat.Json, Aefos.OTA.Terminal.Core.Actions;
  {$ELSE}
  System.SysUtils, System.JSON, Aefos.OTA.Terminal.Core.Actions;
  {$ENDIF}

const
  /// <summary>
  /// Current actions.json payload format. A file carrying a different version
  /// is treated as corrupt and resolves to an empty catalog.
  /// </summary>
  ACTION_STORE_FORMAT_VERSION = 1;

type
  /// <summary>
  /// Versioned JSON persistence for a TActionCatalog. Writes actions.json
  /// atomically (temp file + rename); a corrupt, unreadable, or
  /// unknown-version file resolves to an empty catalog without raising.
  /// </summary>
  TActionStore = class
  private
    FFilePath: string;
    // Promoted to class static so the ESP-031 import/export class methods can
    // reuse them without instantiating a TActionStore. Existing instance call
    // sites (Self._SerializeAction, Self._DeserializeAction, etc.) still
    // resolve through the class identifier.
    class function _SerializeAction(const AAction: TTerminalAction): TJSONObject; static;
    class function _DeserializeAction(const AJSON: TJSONObject): TTerminalAction; static;
    class procedure _LoadActions(const ARoot: TJSONObject;
      const ACatalog: TActionCatalog); static;
    class procedure _WriteAtomic(const AFilePath, AContent: string); static;
    class function _BuildRoot(const ACatalog: TActionCatalog): TJSONObject; static;
    class function _ParseRoot(const AFilePath: string; out ARoot: TJSONObject;
      out AOwner: TJSONValue; out AError: string): Boolean; static;
    class function _HasNameCategoryConflict(const ACatalog: TActionCatalog;
      const AAction: TTerminalAction): Boolean; static;
    class function _DefaultFilePath: string; static;
    /// <summary>First-run seed: a few sample actions (mirrors the snippet
    /// manager's _SeedDefaults) so the Action Center and the sidebar Actions
    /// group start with runnable content. Populates ACatalog and persists it.</summary>
    procedure _SeedDefaults(const ACatalog: TActionCatalog);
  public
    /// <summary>Creates a store over actions.json in the Aefos.OTA.Terminal config dir.</summary>
    constructor Create; overload;
    /// <summary>Creates a store over an explicit file path (used by tests).</summary>
    constructor Create(const AFilePath: string); overload;

    /// <summary>
    /// Loads the catalog from disk. A missing, empty, corrupt, or
    /// unknown-version file yields an empty catalog. The caller owns the
    /// returned catalog.
    /// </summary>
    function LoadCatalog: TActionCatalog;
    /// <summary>Serializes ACatalog to disk with an atomic write.</summary>
    procedure SaveCatalog(const ACatalog: TActionCatalog);

    /// <summary>
    /// Writes ACatalog to AFilePath using the same wire format as
    /// actions.json (formatVersion = 1, actions[]). Standalone from any
    /// TActionStore instance — used by the Action Center Export... button
    /// (ESP-031, ADR-031-01). The file is written atomically (temp file +
    /// rename).
    /// </summary>
    class procedure ExportCatalogToFile(const AFilePath: string;
      const ACatalog: TActionCatalog); static;

    /// <summary>
    /// Merges actions read from AFilePath into ACatalog using the skip-on-
    /// collision + drop-and-keep-on-shortcut-conflict policy (ESP-031,
    /// ADR-031-02). Each imported action is regenerated a fresh Id. Returns
    /// True on a well-formed formatVersion=1 payload; on any read / parse /
    /// version failure returns False with all report counters zero and
    /// AReport.LastError set. The catalog is mutated only after the file
    /// fully parses, so a corrupt payload never leaves a partial merge.
    /// </summary>
    class function ImportCatalogFromFile(const AFilePath: string;
      const ACatalog: TActionCatalog;
      out AReport: TActionImportReport): Boolean; static;

    /// <summary>Absolute path of the backing actions.json file.</summary>
    property FilePath: string read FFilePath;
  end;

implementation

uses
  {$IFDEF FPC}
  Aefos.Compat.IO, Generics.Collections,
  LCLProc, LCLType;
  {$ELSE}
  System.IOUtils, Aefos.Compat.IO, System.Generics.Collections,
  Vcl.Menus;
  {$ENDIF}

{ TActionStore }

class function TActionStore._DefaultFilePath: string;
var
  LAppData: string;
  LDir: string;
begin
  LAppData := GetEnvironmentVariable('APPDATA');
  if LAppData = '' then
    LAppData := TPath.GetHomePath;
  LDir := TPath.Combine(TPath.Combine(LAppData, 'ModernDelphiWorks'), 'Aefos.OTA.Terminal');
  Result := TPath.Combine(LDir, 'actions.json');
end;

constructor TActionStore.Create;
begin
  Create(_DefaultFilePath);
end;

constructor TActionStore.Create(const AFilePath: string);
begin
  inherited Create;
  FFilePath := AFilePath;
end;

class function TActionStore._SerializeAction(
  const AAction: TTerminalAction): TJSONObject;
var
  LLines: TJSONArray;
  LLine: string;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', AAction.Id);
  Result.AddPair('name', AAction.Name);
  Result.AddPair('category', AAction.Category);
  Result.AddPair('description', AAction.Description);
  Result.AddPair('profileName', AAction.ProfileName);
  Result.AddPair('workingDir', AAction.WorkingDir);
  Result.AddPair('confirmBeforeRun', TJSONBool.Create(AAction.ConfirmBeforeRun));
  // Shortcut persisted as a human-readable string token (e.g. "Ctrl+Shift+F5").
  // ADR-029-01: the domain unit owns its own TShortCut alias; pipe the Word
  // value through Vcl.Menus.TShortCut's distinct `type Word` via the
  // implementation-scope TShortCut name (which resolves to Vcl.Menus.TShortCut
  // since Vcl.Menus is the latest-listed uses entry).
  // The LCL twin (ShortCutToTextRaw, non-localized) writes the SAME English
  // token Vcl.Menus.ShortCutToText does (e.g. "Ctrl+Shift+F5"), so actions.json
  // stays byte-compatible across the two editions. Shortcut 0 -> '' on both.
  Result.AddPair('shortcut',
    {$IFDEF FPC}
    ShortCutToTextRaw(AAction.Shortcut));
    {$ELSE}
    Vcl.Menus.ShortCutToText(TShortCut(AAction.Shortcut)));
    {$ENDIF}

  LLines := TJSONArray.Create;
  for LLine in AAction.ScriptLines do
    LLines.Add(LLine);
  Result.AddPair('scriptLines', LLines);
end;

class function TActionStore._DeserializeAction(
  const AJSON: TJSONObject): TTerminalAction;
var
  LLinesValue: TJSONArray;
  LLines: TList<string>;
  LValue: TJSONValue;
  LShortcutValue: TJSONValue;
  LShortcutText: string;
  // In implementation scope `TShortCut` resolves to Vcl.Menus.TShortCut
  // since Vcl.Menus is the last unit added via the implementation uses.
  LShortcutFromText: TShortCut;
  {$IFDEF FPC}
  // The domain TTerminalAction (mode delphi) carries AnsiString script lines,
  // while this delphiunicode store builds a UnicodeString list; bridge the two
  // dynamic-array element types with an explicit per-element convert (FPC will
  // not implicitly assign TArray<UnicodeString> to TArray<AnsiString>).
  LScriptArr: TArray<AnsiString>;
  LScriptIdx: Integer;
  {$ENDIF}
begin
  Result := TTerminalAction.Create;
  // Free the half-built action if any GetValue cast raises (e.g. a hand-edited
  // actions.json whose 'scriptLines' is not a JSON array -> EInvalidCast below).
  try
  Result.Id := AJSON.GetValue<string>('id', '');
  Result.Name := AJSON.GetValue<string>('name', '');
  Result.Category := AJSON.GetValue<string>('category', '');
  Result.Description := AJSON.GetValue<string>('description', '');
  Result.ProfileName := AJSON.GetValue<string>('profileName', '');
  Result.WorkingDir := AJSON.GetValue<string>('workingDir', '');
  Result.ConfirmBeforeRun := AJSON.GetValue<Boolean>('confirmBeforeRun', False);

  // Read the shortcut as a string first (canonical, written by SaveCatalog);
  // fall back to integer for legacy/forward-shaped payloads. Missing field or
  // an unparseable value resolves to 0 (no binding). The dual-shape branch is
  // type-driven so a JSON integer doesn't raise during GetValue<string>.
  LShortcutValue := AJSON.GetValue('shortcut');
  Result.Shortcut := 0;
  if LShortcutValue is TJSONString then
  begin
    LShortcutText := TJSONString(LShortcutValue).Value;
    if LShortcutText <> '' then
    begin
      {$IFDEF FPC}
      LShortcutFromText := TextToShortCutRaw(LShortcutText);
      {$ELSE}
      LShortcutFromText := Vcl.Menus.TextToShortCut(LShortcutText);
      {$ENDIF}
      // Word(...) erases the distinct `type Word` so the value lands back in
      // the domain alias (a plain Word) without an additional type-cast step.
      Result.Shortcut := Word(LShortcutFromText);
    end;
  end
  else if LShortcutValue is TJSONNumber then
    Result.Shortcut := Word(TJSONNumber(LShortcutValue).AsInt);

  LLines := TList<string>.Create;
  try
    LLinesValue := AJSON.GetValue('scriptLines') as TJSONArray;
    if Assigned(LLinesValue) then
      for LValue in LLinesValue do
        LLines.Add(LValue.Value);
    {$IFDEF FPC}
    SetLength(LScriptArr, LLines.Count);
    for LScriptIdx := 0 to LLines.Count - 1 do
      LScriptArr[LScriptIdx] := LLines[LScriptIdx];
    Result.ScriptLines := LScriptArr;
    {$ELSE}
    Result.ScriptLines := LLines.ToArray;
    {$ENDIF}
  finally
    LLines.Free;
  end;
  except
    Result.Free;
    raise;
  end;
end;

class procedure TActionStore._LoadActions(const ARoot: TJSONObject;
  const ACatalog: TActionCatalog);
var
  LActions: TJSONArray;
  LValue: TJSONValue;
begin
  LActions := ARoot.GetValue('actions') as TJSONArray;
  if not Assigned(LActions) then
    Exit;
  for LValue in LActions do
    if LValue is TJSONObject then
      ACatalog.Add(_DeserializeAction(TJSONObject(LValue)));
end;

procedure TActionStore._SeedDefaults(const ACatalog: TActionCatalog);

  procedure _AddSample(const AName, ACategory, ADescription, ACommand: string;
    const AConfirm: Boolean);
  var
    LAction: TTerminalAction;
  begin
    LAction := TTerminalAction.Create;
    LAction.Name := AName;
    LAction.Category := ACategory;
    LAction.Description := ADescription;
    LAction.ScriptLines := [ACommand];
    LAction.ConfirmBeforeRun := AConfirm;
    ACatalog.Add(LAction); // takes ownership; assigns a blank id, frees if invalid
  end;

begin
  _AddSample('Git Pull', 'Git', 'Fetch and merge the current branch', 'git pull', False);
  _AddSample('Git Push', 'Git', 'Push commits to the remote', 'git push', True);
  _AddSample('Build (Debug)', 'Build', 'MSBuild the Debug configuration',
    'msbuild /t:Build /p:Configuration=Debug', False);
  _AddSample('List Tasks', 'System', 'Show running processes', 'tasklist', False);
  SaveCatalog(ACatalog);
end;

function TActionStore.LoadCatalog: TActionCatalog;
var
  LContent: string;
  LValue: TJSONValue;
  LRoot: TJSONObject;
begin
  Result := TActionCatalog.Create;
  if not TFile.Exists(FFilePath) then
  begin
    // First run (no actions.json yet): seed sample actions + persist, mirroring
    // TSnippetManager._SeedDefaults so Actions populate just like Snippets do.
    _SeedDefaults(Result);
    Exit;
  end;

  LValue := nil;
  try
    try
      // The compat shim has no encoding-less overload; UTF-8 matches the
      // BOM'd file SaveCatalog writes (the shim strips a leading BOM on read).
      {$IFDEF FPC}
      LContent := TAefosText.ReadAllUtf8(FFilePath);
      {$ELSE}
      LContent := TFile.ReadAllText(FFilePath);
      {$ENDIF}
      // FPC 3.2.2 has no UnicodeString type helper, so the .Trim method form is
      // an "illegal qualifier" there; SysUtils.Trim is the portable equivalent.
      {$IFDEF FPC}
      if Trim(LContent) = '' then
      {$ELSE}
      if LContent.Trim = '' then
      {$ENDIF}
        Exit;

      LValue := TJSONObject.ParseJSONValue(LContent);
      if not (LValue is TJSONObject) then
        Exit;

      LRoot := TJSONObject(LValue);
      if LRoot.GetValue<Integer>('formatVersion', 0) = ACTION_STORE_FORMAT_VERSION then
        _LoadActions(LRoot, Result);
    except
      on LError: Exception do
      begin
        FreeAndNil(Result);
        Result := TActionCatalog.Create;
      end;
    end;
  finally
    // Free regardless of an early Exit (e.g. parsed value is not an object).
    LValue.Free;
  end;
end;

class procedure TActionStore._WriteAtomic(const AFilePath, AContent: string);
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

class function TActionStore._BuildRoot(
  const ACatalog: TActionCatalog): TJSONObject;
var
  LActions: TJSONArray;
  LAction: TTerminalAction;
begin
  Result := TJSONObject.Create;
  try
    Result.AddPair('formatVersion',
      TJSONNumber.Create(ACTION_STORE_FORMAT_VERSION));
    LActions := TJSONArray.Create;
    for LAction in ACatalog.AllActions do
      LActions.AddElement(_SerializeAction(LAction));
    Result.AddPair('actions', LActions);
  except
    Result.Free;
    raise;
  end;
end;

class function TActionStore._ParseRoot(const AFilePath: string;
  out ARoot: TJSONObject; out AOwner: TJSONValue;
  out AError: string): Boolean;
var
  LContent: string;
  LValue: TJSONValue;
begin
  ARoot := nil;
  AOwner := nil;
  AError := '';
  Result := False;

  if not TFile.Exists(AFilePath) then
  begin
    AError := 'File not found: ' + AFilePath;
    Exit;
  end;

  try
    {$IFDEF FPC}
    LContent := TAefosText.ReadAllUtf8(AFilePath);
    {$ELSE}
    LContent := TFile.ReadAllText(AFilePath);
    {$ENDIF}
  except
    on E: Exception do
    begin
      AError := 'Read failed: ' + E.Message;
      Exit;
    end;
  end;

  // No UnicodeString type helper on FPC 3.2.2 (see LoadCatalog above).
  {$IFDEF FPC}
  if Trim(LContent) = '' then
  {$ELSE}
  if LContent.Trim = '' then
  {$ENDIF}
  begin
    AError := 'File is empty.';
    Exit;
  end;

  try
    LValue := TJSONObject.ParseJSONValue(LContent);
  except
    on E: Exception do
    begin
      AError := 'JSON parse failed: ' + E.Message;
      Exit;
    end;
  end;

  if not (LValue is TJSONObject) then
  begin
    AError := 'Root JSON is not an object.';
    LValue.Free;
    Exit;
  end;

  if TJSONObject(LValue).GetValue<Integer>('formatVersion', 0)
     <> ACTION_STORE_FORMAT_VERSION then
  begin
    AError := Format('Unsupported formatVersion (expected %d).',
      [ACTION_STORE_FORMAT_VERSION]);
    LValue.Free;
    Exit;
  end;

  AOwner := LValue;
  ARoot := TJSONObject(LValue);
  Result := True;
end;

class function TActionStore._HasNameCategoryConflict(
  const ACatalog: TActionCatalog;
  const AAction: TTerminalAction): Boolean;
var
  LExisting: TTerminalAction;
begin
  for LExisting in ACatalog.AllActions do
    if SameText(LExisting.Name.Trim, AAction.Name.Trim) and
       SameText(LExisting.EffectiveCategory, AAction.EffectiveCategory) then
      Exit(True);
  Result := False;
end;

procedure TActionStore.SaveCatalog(const ACatalog: TActionCatalog);
var
  LRoot: TJSONObject;
begin
  if not Assigned(ACatalog) then
    Exit;

  LRoot := _BuildRoot(ACatalog);
  try
    _WriteAtomic(FFilePath, LRoot.ToJSON);
  finally
    LRoot.Free;
  end;
end;

class procedure TActionStore.ExportCatalogToFile(const AFilePath: string;
  const ACatalog: TActionCatalog);
var
  LRoot: TJSONObject;
begin
  if not Assigned(ACatalog) then
    Exit;
  LRoot := _BuildRoot(ACatalog);
  try
    _WriteAtomic(AFilePath, LRoot.ToJSON);
  finally
    LRoot.Free;
  end;
end;

class function TActionStore.ImportCatalogFromFile(const AFilePath: string;
  const ACatalog: TActionCatalog;
  out AReport: TActionImportReport): Boolean;
var
  LOwner: TJSONValue;
  LRoot: TJSONObject;
  LActionsArr: TJSONArray;
  LEntry: TJSONValue;
  LParsed: TObjectList<TTerminalAction>;
  LAction: TTerminalAction;
  LIndex: Integer;
  LError: string;
begin
  AReport := Default(TActionImportReport);
  Result := False;

  if not Assigned(ACatalog) then
  begin
    AReport.LastError := 'Target catalog is not assigned.';
    Exit;
  end;

  if not _ParseRoot(AFilePath, LRoot, LOwner, LError) then
  begin
    AReport.LastError := LError;
    Exit;
  end;

  try
    LActionsArr := LRoot.GetValue('actions') as TJSONArray;
    if not Assigned(LActionsArr) then
    begin
      AReport.LastError := 'Missing "actions" array.';
      Exit;
    end;

    // Parse fully before mutating the target catalog (R4). OwnsObjects=False
    // so we control ownership through the success/failure branches below.
    LParsed := TObjectList<TTerminalAction>.Create(False);
    try
      try
        for LEntry in LActionsArr do
          if LEntry is TJSONObject then
            LParsed.Add(_DeserializeAction(TJSONObject(LEntry)));
      except
        on E: Exception do
        begin
          for LIndex := 0 to LParsed.Count - 1 do
            LParsed[LIndex].Free;
          AReport.LastError := 'Action parse failed: ' + E.Message;
          Exit;
        end;
      end;

      for LIndex := 0 to LParsed.Count - 1 do
      begin
        LAction := LParsed[LIndex];
        // Force a fresh id on every imported action so cross-machine merges
        // never collide on stable ids (ADR-031-02 identity rule).
        LAction.Id := '';

        if _HasNameCategoryConflict(ACatalog, LAction) then
        begin
          LAction.Free;
          Inc(AReport.Skipped);
          Continue;
        end;

        if TActionCatalog.IsReservedShortcut(LAction.Shortcut) or
           ACatalog.HasShortcut(LAction.Shortcut) then
        begin
          LAction.Shortcut := 0;
          Inc(AReport.ShortcutsDropped);
        end;

        // Defensive: Add frees LAction on validation failure. A True result
        // transfers ownership to ACatalog; on False the action has already
        // been freed by Add — count as Skipped without re-freeing.
        if ACatalog.Add(LAction) then
          Inc(AReport.Added)
        else
          Inc(AReport.Skipped);
      end;
      Result := True;
    finally
      LParsed.Free;
    end;
  finally
    LOwner.Free;
  end;
end;

end.


