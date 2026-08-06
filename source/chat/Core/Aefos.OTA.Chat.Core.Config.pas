unit Aefos.OTA.Chat.Core.Config;

{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  Configuration service (ESP-002, Epic 2/4, Demand 1/4).

  Root-agnostic: the config directory comes from an injected TFunc<string>
  (C-5). IMPORTANT — despite older "project-scoped" wording, the SHIPPED
  composition (Register._InitConfig and the Options binding) injects the GLOBAL
  per-user root %APPDATA%\Aefos, so the file is %APPDATA%\Aefos\.aefos\config.json:
  an IDE-wide setting per Windows profile, NOT stored in the project. Done on
  purpose so Tools -> Options -> Aefos is editable on the Welcome page with no
  project open (install-feedback #1). Genuinely per-project state (command
  registry, project context) uses a DIFFERENT resolver (_ResolveActiveProjectRoot).

  Reads and writes <root>\.aefos\config.json with top-level
  keys: executor_path, model, executor, inspector. UTF-8 without BOM,
  two-space indent, deterministic key order. Legacy key replicator_target
  is tolerated on load and silently ignored (BR-3, ADR-239).

  Behavioural rules:
    - BR-3: missing file/field/malformed JSON -> defaults; never raises
      during Load. Malformed payloads are logged via OutputDebugString.
    - BR-7: Save is atomic via <path>.tmp + TFile.Move (overwrite).
    - C-5: OTA-free — the config root comes from a TFunc<string> lambda (wired
      to the GLOBAL %APPDATA%\Aefos root in production; see the note above).

  Hand-rolled serialiser (three keys only) avoids RTL formatting drift
  per R-01.
}

interface

uses
  SysUtils,
  Aefos.Compat.Json,
  Aefos.OTA.Chat.Core.Config.Types;

type
  // The injected config-root resolver. On Delphi it is the anonymous-method
  // TFunc<string> (alias, so every existing Delphi caller is byte-identical).
  // FPC 3.2.2 has no anonymous methods, so the port gets a method-pointer twin
  // (`of object`) - the Lazarus composition root passes an instance method.
{$IFDEF FPC}
  TConfigRootResolver = function: string of object;
{$ELSE}
  TConfigRootResolver = TFunc<string>;
{$ENDIF}

  TConfigService = class(TInterfacedObject, IConfig)
  private
    FRootResolver: TConfigRootResolver;
    FSnapshot: TConfig;
    function _ResolveConfigPath: string;
    function _ResolveConfigDir: string;
    procedure _ApplyDefaults;
    procedure _ParseAndApply(const AJson: string);
    procedure _ApplyExecutorKey(const AValue: string);
    procedure _ApplyRuntimeKeys(const AObject: TJSONObject);
    function _Serialize(const AConfig: TConfig): string;
    // Carries every top-level key that _Serialize does NOT write from the file
    // as it is on disk into the text about to replace it.
    //
    // Without this, saving the chat's config SILENTLY DESTROYS every setting
    // this unit has never heard of. _Serialize builds the document from scratch
    // out of TConfig's fields, so anything else in the file simply ceases to
    // exist the next time the user changes a model or an executor.
    //   That is not hypothetical: config.json is the SHARED "one brain" file and
    // the Tools > Options page writes into it too. The inline-completion
    // settings were written correctly, then wiped by the next chat save, and the
    // owner reported the Options page as "not saving" (2026-08-04). It was
    // saving; this was erasing.
    //   Pure (no I/O) and PUBLIC so the merge is provable headless without
    // touching a real config file -- same reason the AI Flow store exposes its
    // atomic writer.
    procedure _WriteAtomic(const APath, AContent: string);
    // OutputDebugString wrapper: FPC's unqualified OutputDebugString is the ANSI
    // overload (PAnsiChar); in delphiunicode `string` is UTF-16, so the port
    // calls OutputDebugStringW. One helper keeps every diagnostic site portable.
    procedure _DebugOut(const AMessage: string);
  public
    constructor Create(const ARootResolver: TConfigRootResolver);
    procedure Load;
    procedure Save(const AConfig: TConfig);
    function Snapshot: TConfig;
    class function _MergeUnknownKeys(const ASerialized,
      AOnDisk: string): string; static;
  end;

implementation

uses
{$IFDEF FPC}
  Windows,
{$ELSE}
  Winapi.Windows,
{$ENDIF}
  Aefos.Compat.IO,
  Classes,
  Aefos.Provider.Types,
  Aefos.Provider.Kinds,
  Aefos.OTA.Chat.Core.Dispatcher.Types,
  Aefos.OTA.Chat.Core.Dispatcher.Decode,
  Aefos.Compat.JsonFormat;

const
  CONFIG_DIR_REL = '.aefos';
  CONFIG_FILE_NAME = 'config.json';
  KEY_EXECUTOR_PATH = 'executor_path';
  KEY_MODEL = 'model';
  KEY_EXECUTOR = 'executor';
  KEY_INSPECTOR = 'inspector';
  KEY_INSPECTOR_ENABLED = 'enabled';
  KEY_TIMEOUT_SECONDS = 'timeout_seconds';
  KEY_OUTPUT_FILTER = 'output_filter';
  KEY_OLLAMA_BASE_URL = 'ollama_base_url';
  // Win32 MoveFileEx flags. Declared locally so both compilers agree (FPC's
  // Windows unit ships REPLACE_EXISTING but NOT WRITE_THROUGH). REPLACE_EXISTING
  // swaps the destination atomically - it is never momentarily absent, unlike the
  // old delete-then-move; WRITE_THROUGH flushes to disk before returning.
  MOVEFILE_REPLACE_EXISTING = $00000001;
  MOVEFILE_WRITE_THROUGH = $00000008;
  // ADR-216 family (shared IDE-wide; see TConfig). Snake-case keys, one file.
  KEY_AGENT_CONSENT_MODE = 'agent_consent_mode';
  KEY_AGENT_EDIT_REVIEW_MODE = 'agent_edit_review_mode';
  KEY_AGENT_AUTO_SAVE = 'agent_auto_save';
  KEY_ISSUE_REPORTING = 'issue_reporting';
  KEY_MCP_AUTOSTART = 'mcp_autostart';

// Canonical JSON boolean literal (the hand-rolled serialiser has no Boolean
// overload; the inspector block predates this and inlines its own if/else).
function _BoolJson(const AValue: Boolean): string;
begin
  if AValue then
    Result := 'true'
  else
    Result := 'false';
end;

constructor TConfigService.Create(const ARootResolver: TConfigRootResolver);
begin
  inherited Create;
  if not Assigned(ARootResolver) then
    raise EArgumentNilException.Create('TConfigService: ARootResolver');
  FRootResolver := ARootResolver;
  _ApplyDefaults;
end;

procedure TConfigService._DebugOut(const AMessage: string);
begin
{$IFDEF FPC}
  OutputDebugStringW(PWideChar(AMessage));
{$ELSE}
  OutputDebugString(PChar(AMessage));
{$ENDIF}
end;

function TConfigService._ResolveConfigDir: string;
var
  LRoot: string;
begin
  LRoot := FRootResolver();
  if LRoot = '' then
    Exit('');
  Result := TPath.Combine(LRoot, CONFIG_DIR_REL);
end;

function TConfigService._ResolveConfigPath: string;
var
  LDir: string;
begin
  LDir := _ResolveConfigDir;
  if LDir = '' then
    Exit('');
  Result := TPath.Combine(LDir, CONFIG_FILE_NAME);
end;

procedure TConfigService._ApplyDefaults;
begin
  FSnapshot := DefaultConfig;
end;

procedure TConfigService._ParseAndApply(const AJson: string);
var
  LValue: TJSONValue;
  LObject: TJSONObject;
  LField: TJSONValue;
begin
  LValue := nil;
  try
    LValue := TJSONObject.ParseJSONValue(AJson);
    if not (LValue is TJSONObject) then
    begin
      _DebugOut('Aefos.Config: malformed JSON, using defaults');
      _ApplyDefaults;
      Exit;
    end;
    LObject := TJSONObject(LValue);
    _ApplyDefaults;
    LField := LObject.GetValue(KEY_EXECUTOR_PATH);
    if LField is TJSONString then
      FSnapshot.ExecutorPath := TJSONString(LField).Value;
    LField := LObject.GetValue(KEY_MODEL);
    if LField is TJSONString then
      FSnapshot.Model := TJSONString(LField).Value;
    LField := LObject.GetValue(KEY_EXECUTOR);
    if LField is TJSONString then
      _ApplyExecutorKey(TJSONString(LField).Value);
    // ADR-119: Inspector enabled flag. Missing object → default Enabled=False
    // (BR-3 — never raise on a missing/malformed sub-tree).
    LField := LObject.GetValue(KEY_INSPECTOR);
    if LField is TJSONObject then
    begin
      LField := TJSONObject(LField).GetValue(KEY_INSPECTOR_ENABLED);
      if LField is TJSONBool then
        FSnapshot.Inspector.Enabled := TJSONBool(LField).AsBoolean;
    end;
    _ApplyRuntimeKeys(LObject);
  finally
    LValue.Free;
  end;
end;

procedure TConfigService._ApplyRuntimeKeys(const AObject: TJSONObject);
var
  LField: TJSONValue;
begin
  // BR-4: absent or wrong-typed fields keep the defaults applied above; never
  // raise. A negative timeout is clamped to 0 (disabled).
  LField := AObject.GetValue(KEY_TIMEOUT_SECONDS);
  if LField is TJSONNumber then
  begin
    FSnapshot.TimeoutSeconds := TJSONNumber(LField).AsInt;
    if FSnapshot.TimeoutSeconds < 0 then
      FSnapshot.TimeoutSeconds := 0;
  end;
  LField := AObject.GetValue(KEY_OUTPUT_FILTER);
  if LField is TJSONString then
    FSnapshot.OutputFilter := ParseOutputFilter(TJSONString(LField).Value);
  LField := AObject.GetValue(KEY_OLLAMA_BASE_URL);
  if LField is TJSONString then
    FSnapshot.OllamaBaseUrl := TJSONString(LField).Value;
  // ADR-216 family: absent/wrong-typed keeps the default; mode ints normalise to
  // the documented default (never raise, BR-3/BR-4).
  LField := AObject.GetValue(KEY_AGENT_CONSENT_MODE);
  if LField is TJSONNumber then
  begin
    FSnapshot.AgentConsentMode := TJSONNumber(LField).AsInt;
    if (FSnapshot.AgentConsentMode < 0) or (FSnapshot.AgentConsentMode > 2) then
      FSnapshot.AgentConsentMode := 0;
  end;
  LField := AObject.GetValue(KEY_AGENT_EDIT_REVIEW_MODE);
  if LField is TJSONNumber then
  begin
    FSnapshot.AgentEditReviewMode := TJSONNumber(LField).AsInt;
    if (FSnapshot.AgentEditReviewMode < 0) or (FSnapshot.AgentEditReviewMode > 2) then
      FSnapshot.AgentEditReviewMode := 1;
  end;
  LField := AObject.GetValue(KEY_AGENT_AUTO_SAVE);
  if LField is TJSONBool then
    FSnapshot.AgentAutoSave := TJSONBool(LField).AsBoolean;
  LField := AObject.GetValue(KEY_ISSUE_REPORTING);
  if LField is TJSONBool then
    FSnapshot.IssueReporting := TJSONBool(LField).AsBoolean;
  LField := AObject.GetValue(KEY_MCP_AUTOSTART);
  if LField is TJSONBool then
    FSnapshot.McpAutostart := TJSONBool(LField).AsBoolean;
end;

procedure TConfigService._ApplyExecutorKey(const AValue: string);
begin
  FSnapshot.Executor := TExecutorKinds.ParseExecutorKind(AValue);
  // BR-3: an unrecognised token still resolves to ekClaude — log it so a
  // typo in config.json is diagnosable without the file ever raising. The
  // round-trip check covers EVERY known token (the old two-token check
  // false-flagged copilot/gemini).
  if not SameText(Trim(AValue),
       TExecutorKinds.ExecutorKindToString(TExecutorKinds.ParseExecutorKind(AValue))) then
    _DebugOut(
      'Aefos.Config: unknown executor "' + AValue + '", using the default executor');
end;

procedure TConfigService.Load;
var
  LPath: string;
  LBytes: TBytes;
  LJson: string;
begin
  _ApplyDefaults;
  LPath := _ResolveConfigPath;
  if LPath = '' then
    Exit;
  if not TFile.Exists(LPath) then
    Exit;
  try
    LBytes := TFile.ReadAllBytes(LPath);
    LJson := TEncoding.UTF8.GetString(LBytes);
    _ParseAndApply(LJson);
  except
    on E: Exception do
    begin
      _DebugOut('Aefos.Config: read failed, using defaults: ' + E.Message);
      _ApplyDefaults;
    end;
  end;
end;

class function TConfigService._MergeUnknownKeys(const ASerialized,
  AOnDisk: string): string;
var
  LNew: TJSONValue;
  LOld: TJSONValue;
  LPair: TJSONPair;
  LChanged: Boolean;
begin
  Result := ASerialized;
  if Trim(AOnDisk) = '' then
    Exit;
  LOld := TJSONObject.ParseJSONValue(AOnDisk);
  try
    if not (LOld is TJSONObject) then
      Exit; // a file we cannot read is a file we must not pretend to merge
    LNew := TJSONObject.ParseJSONValue(ASerialized);
    try
      if not (LNew is TJSONObject) then
        Exit;
      LChanged := False;
      for LPair in TJSONObject(LOld) do
        if TJSONObject(LNew).GetValue(LPair.JsonString.Value) = nil then
        begin
          // Cloned, not moved: LOld owns its pairs and frees them below.
          // The cast is not cosmetic -- Clone is declared to return the common
          // ancestor, which AddPair does not accept.
          TJSONObject(LNew).AddPair(LPair.JsonString.Value,
            TJSONValue(LPair.JsonValue.Clone));
          LChanged := True;
        end;
      if LChanged then
        Result := TJSONObject(LNew).Format(2);
    finally
      LNew.Free;
    end;
  finally
    LOld.Free;
  end;
end;

function TConfigService._Serialize(const AConfig: TConfig): string;
var
  LBuilder: TStringBuilder;
begin
  LBuilder := TStringBuilder.Create;
  try
    LBuilder.Append('{').Append(sLineBreak);
    LBuilder.Append('  "').Append(KEY_EXECUTOR_PATH).Append('": "')
      .Append(TCliText.EscapeJsonString(AConfig.ExecutorPath)).Append('",').Append(sLineBreak);
    LBuilder.Append('  "').Append(KEY_MODEL).Append('": "')
      .Append(TCliText.EscapeJsonString(AConfig.Model)).Append('",').Append(sLineBreak);
    LBuilder.Append('  "').Append(KEY_TIMEOUT_SECONDS).Append('": ')
      .Append(AConfig.TimeoutSeconds).Append(',').Append(sLineBreak);
    LBuilder.Append('  "').Append(KEY_OUTPUT_FILTER).Append('": "')
      .Append(OutputFilterToString(AConfig.OutputFilter)).Append('",')
      .Append(sLineBreak);
    LBuilder.Append('  "').Append(KEY_OLLAMA_BASE_URL).Append('": "')
      .Append(TCliText.EscapeJsonString(AConfig.OllamaBaseUrl)).Append('",')
      .Append(sLineBreak);
    LBuilder.Append('  "').Append(KEY_EXECUTOR).Append('": "')
      .Append(TExecutorKinds.ExecutorKindToString(AConfig.Executor)).Append('",').Append(sLineBreak);
    // ADR-216 family (shared IDE-wide). Ints unquoted; Booleans via _BoolJson.
    LBuilder.Append('  "').Append(KEY_AGENT_CONSENT_MODE).Append('": ')
      .Append(AConfig.AgentConsentMode).Append(',').Append(sLineBreak);
    LBuilder.Append('  "').Append(KEY_AGENT_EDIT_REVIEW_MODE).Append('": ')
      .Append(AConfig.AgentEditReviewMode).Append(',').Append(sLineBreak);
    LBuilder.Append('  "').Append(KEY_AGENT_AUTO_SAVE).Append('": ')
      .Append(_BoolJson(AConfig.AgentAutoSave)).Append(',').Append(sLineBreak);
    LBuilder.Append('  "').Append(KEY_ISSUE_REPORTING).Append('": ')
      .Append(_BoolJson(AConfig.IssueReporting)).Append(',').Append(sLineBreak);
    LBuilder.Append('  "').Append(KEY_MCP_AUTOSTART).Append('": ')
      .Append(_BoolJson(AConfig.McpAutostart)).Append(',').Append(sLineBreak);
    // ADR-119: Inspector flag serialised as a nested object so future
    // dev-only toggles can land under the same key without a schema bump.
    LBuilder.Append('  "').Append(KEY_INSPECTOR).Append('": { "')
      .Append(KEY_INSPECTOR_ENABLED).Append('": ');
    if AConfig.Inspector.Enabled then
      LBuilder.Append('true')
    else
      LBuilder.Append('false');
    LBuilder.Append(' }').Append(sLineBreak);
    LBuilder.Append('}').Append(sLineBreak);
    Result := LBuilder.ToString;
  finally
    LBuilder.Free;
  end;
end;

procedure TConfigService._WriteAtomic(const APath, AContent: string);
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
    // Atomic replace (fixes the delete-then-move TOCTOU): MoveFileEx with
    // REPLACE_EXISTING swaps the destination in one step, so a concurrent reader
    // never sees the config momentarily absent and re-saves it with one key.
    if not MoveFileExW(PWideChar(LTempPath), PWideChar(APath),
         MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
      RaiseLastOSError;
  except
    on E: Exception do
    begin
      try
        if TFile.Exists(LTempPath) then
          TFile.Delete(LTempPath);
      except
        // best-effort cleanup
      end;
      raise EConfigSaveFailed.CreateFmt(
        'Cannot persist config to "%s": %s', [APath, E.Message]);
    end;
  end;
end;

procedure TConfigService.Save(const AConfig: TConfig);
var
  LPath: string;
  LSerialized: string;
begin
  LPath := _ResolveConfigPath;
  if LPath = '' then
    raise EConfigSaveFailed.Create(
      'Cannot save config: project root is unavailable');
  LSerialized := _Serialize(AConfig);
  // Read-modify-write, not write. The file is shared with the Tools > Options
  // page (and with the Lazarus edition), so anything in it that this unit does
  // not model has to survive being saved over. Read FRESH from disk rather than
  // from the snapshot: the point is to pick up what someone ELSE wrote since we
  // loaded.
  if TFile.Exists(LPath) then
    try
      LSerialized := _MergeUnknownKeys(LSerialized,
        TEncoding.UTF8.GetString(TFile.ReadAllBytes(LPath)));
    except
      on E: Exception do
        // A file we could not read is one we cannot merge. Saving the known keys
        // is still better than not saving at all, but SAY that something was
        // potentially lost.
        _DebugOut('Aefos.Config: could not merge existing keys, they may be ' +
          'lost: ' + E.Message);
    end;
  _WriteAtomic(LPath, LSerialized);
  FSnapshot := AConfig;
end;

function TConfigService.Snapshot: TConfig;
begin
  Result := FSnapshot;
end;

end.
