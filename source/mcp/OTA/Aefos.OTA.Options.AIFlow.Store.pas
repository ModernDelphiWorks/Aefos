unit Aefos.OTA.Options.AIFlow.Store;

(*
  Shared-config accessor + registry-migration decision for the "AI Flow" agent
  knobs (consent mode, edit-review mode, auto-save, issue reporting).

  WHY THIS UNIT EXISTS (the one-brain rule, owner 2026-07-17): the four agent
  knobs must be the SAME setting whether the user is on the RAD Studio plugin or
  the Lazarus edition. The Lazarus edition already reads/writes them from the
  shared %APPDATA%\Aefos\.aefos\config.json (TConfig, keys agent_consent_mode /
  agent_edit_review_mode / agent_auto_save / issue_reporting). The RAD side used
  to keep them in the IDE registry. This unit lets the RAD page read/write the
  SAME config.json so both editions share one brain.

  WHY NOT reuse TConfigService directly: TConfig / TConfigService live in the
  Aefos.OTA.Chat package, which REQUIRES Aefos.MCP.Tools.OTA (where the AI Flow
  page lives). Referencing them from here would invert the package dependency
  (a build-breaking cycle). So this unit does a self-contained JSON read-modify-
  write against the exact SAME file, path, keys and UTF-8 (no BOM) encoding as
  TConfigService - byte-compatible with what the Lazarus edition writes. The
  writers are read-modify-write over the WHOLE object, so sibling keys the RAD
  side does not know about (model, executor, inspector, ...) are preserved.

  This unit is OTA-free / VCL-free (RTL + System.JSON only) so its JSON and
  migration-decision logic is unit-testable headless. ASCII-only
  literals on purpose (no UTF-8 BOM in this file).
*)

interface

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.JSON;

type
  // Raised when the shared config cannot be persisted (the atomic replace failed).
  // Local to this unit (the twin EConfigSaveFailed lives in the Aefos.OTA.Chat
  // package, which this unit must NOT reference - see the header's cycle note).
  EAefosFlowConfigSaveFailed = class(Exception);

  // Shared-config file (%APPDATA%\Aefos\.aefos\config.json) accessor for the four
  // AI Flow knobs. The *InJson / *FromJson primitives are pure string->value /
  // string->string transforms (no I/O) so they unit-test headless; the ReadInt /
  // WriteInt / ReadBool / WriteBool wrappers add the file read-modify-write.
  // Never instantiated - the class IS the namespace.
  TAefosFlowConfigStore = class sealed
  public const
    // Snake-case keys - MUST stay byte-identical to Aefos.OTA.Chat.Core.Config
    // (the Lazarus edition and TConfigService serialise the same names).
    KEY_AGENT_CONSENT_MODE = 'agent_consent_mode';
    KEY_AGENT_EDIT_REVIEW_MODE = 'agent_edit_review_mode';
    KEY_AGENT_AUTO_SAVE = 'agent_auto_save';
    KEY_ISSUE_REPORTING = 'issue_reporting';
    // Inline completion (ghost text). Same file, same one-brain rule: the
    // Lazarus edition will read these names byte-for-byte.
    KEY_INLINE_ENABLED = 'inline_completion_enabled';
    // Whether the AI CLI may use its OWN file/shell tools, or must route every
    // mutation through the Aefos MCP tools (which are consent-gated).
    KEY_AGENT_NATIVE_TOOLS = 'agent_native_tools';
    // Stored as TEXT ('Ctrl+Alt+Space'), not as a numeric TShortCut: the number
    // is a VCL encoding that means nothing to the Lazarus edition, and nothing
    // to a user who opens config.json.
    KEY_INLINE_SHORTCUT = 'inline_completion_shortcut';
  public const
    // Default FALSE: every mutation routes through the Aefos MCP tools, which
    // is where the consent modal lives. That was the intent behind the
    // hard-coded Claude allowlist and it is worth keeping -- it just should
    // never have been unchangeable, and never have applied to one vendor only.
    AGENT_NATIVE_TOOLS_DEFAULT = False;
    INLINE_DEFAULT_ENABLED = True;
    INLINE_DEFAULT_SHORTCUT = 'Ctrl+Alt+Space';
  private
    // %APPDATA%\Aefos\.aefos\config.json - resolved EXACTLY like the Delphi Chat
    // composition root (_ResolveGlobalConfigRoot: TPath.GetHomePath\Aefos) plus
    // TConfigService's '.aefos'\'config.json'.
    class function _ConfigPath: string; static;
    class function _LoadRaw: string; static;
    class procedure _StoreRaw(const AContent: string); static;
  public
    // Pure JSON primitives (no file I/O) - the unit-testable core.
    // Read* return ADefault when the JSON is absent/malformed or the key is
    // missing/wrong-typed (never raise). Set* return the WHOLE object re-
    // serialised with the one key updated/added, EVERY other key preserved
    // (read-modify-write); a malformed/empty input yields a fresh one-key object.
    class function ReadIntFromJson(const AJson, AName: string;
      const ADefault: Integer): Integer; static;
    class function ReadBoolFromJson(const AJson, AName: string;
      const ADefault: Boolean): Boolean; static;
    class function SetIntInJson(const AJson, AName: string;
      const AValue: Integer): string; static;
    class function SetBoolInJson(const AJson, AName: string;
      const AValue: Boolean): string; static;
    // Pure batch primitive: applies all FOUR agent knobs to AJson in ONE read-
    // modify-write over the whole object (no I/O), preserving every sibling key.
    // Backs UpdateFlowKnobs so the four-knob Options save is a single serialise.
    class function SetFlowKnobsInJson(const AJson: string;
      const AConsentMode, AEditReviewMode: Integer;
      const AAutoSave, AIssueReporting: Boolean): string; static;
    class function ReadStringFromJson(const AJson, AName,
      ADefault: string): string; static;
    class function SetStringInJson(const AJson, AName,
      AValue: string): string; static;
    // Pure batch primitive for the four inline-completion knobs, same contract
    // as SetFlowKnobsInJson: ONE read-modify-write, every sibling key preserved.
    // The delay is clamped here, not at the UI, so a hand-edited config.json
    // cannot arm a 5ms poll.
    class function SetInlineKnobsInJson(const AJson: string;
      const AEnabled: Boolean; const AShortcut: string): string; static;
    // File-backed wrappers over the primitives.
    class function ReadInt(const AName: string; const ADefault: Integer): Integer; static;
    class function ReadBool(const AName: string; const ADefault: Boolean): Boolean; static;
    class function ReadString(const AName, ADefault: string): string; static;
    class procedure WriteInt(const AName: string; const AValue: Integer); static;
    class procedure WriteBool(const AName: string; const AValue: Boolean); static;
    class procedure WriteString(const AName, AValue: string); static;
    // Batch write of the four inline-completion knobs in ONE load-modify-store.
    class procedure UpdateInlineKnobs(const AEnabled: Boolean;
      const AShortcut: string); static;
    // Batch write: persist all four agent knobs in ONE load-modify-store (one
    // disk write). All-or-nothing - a mid-apply failure can no longer leave some
    // knobs saved and others silently dropped (the old per-setter path could).
    class procedure UpdateFlowKnobs(const AConsentMode, AEditReviewMode: Integer;
      const AAutoSave, AIssueReporting: Boolean); static;
    // Atomic UTF-8 (no BOM) write of AContent to APath via a .tmp sibling +
    // MoveFileEx(REPLACE_EXISTING) - the destination is never momentarily absent
    // and a failed write cleans the .tmp and re-raises typed. Exposed (not just
    // _StoreRaw's fixed path) so the atomic-replace mechanism is provable headless
    // against a temp file without touching the real user config.
    class procedure WriteAllTextAtomic(const APath, AContent: string); static;
  end;

  // Pure decision for the one-time "import the legacy IDE-registry knob into the
  // shared config" migration. Kept separate + pure so the truth table is unit-
  // testable without any registry. The actual registry read + config write live
  // in Aefos.OTA.Options.AIFlow (the OTA side).
  TAefosFlowMigration = class sealed
  public
    // Migrate at all? True only until the migration marker is set (once per user
    // on the RAD side; the marker is registry-local Delphi bookkeeping).
    class function MigrationPending(const AMarkerSet: Boolean): Boolean; static;
    // Import THIS knob's legacy value? Only when the migration is still pending
    // AND the registry actually holds an explicit value for it. When the registry
    // has no value (a fresh user, or a Lazarus-first user whose Delphi registry
    // is empty), nothing is imported - the shared config value is left untouched.
    class function ShouldImportKnob(const AMarkerSet,
      ARegistryHasValue: Boolean): Boolean; static;
  end;

implementation

uses
  Winapi.Windows;

const
  CONFIG_DIR_REL = '.aefos';
  CONFIG_FILE_NAME = 'config.json';
  GLOBAL_ROOT_NAME = 'Aefos';
  // Win32 MoveFileEx flags. Declared locally (byte-identical to Winapi.Windows)
  // so the exact bit values are self-evident here and the call reads the same on
  // any RTL: REPLACE_EXISTING overwrites the destination atomically (it is never
  // momentarily absent); WRITE_THROUGH flushes to disk before returning.
  MOVEFILE_REPLACE_EXISTING = $00000001;
  MOVEFILE_WRITE_THROUGH = $00000008;

// Strips a leading UTF-8 BOM if present (TConfigService writes no BOM, but be
// tolerant of a hand-edited file so ParseJSONValue never chokes on it).
function _StripBom(const AText: string): string;
begin
  Result := AText;
  if (Length(Result) > 0) and (Result[1] = #$FEFF) then
    Delete(Result, 1, 1);
end;

{ TAefosFlowConfigStore }

class function TAefosFlowConfigStore._ConfigPath: string;
var
  LRoot: string;
  LDir: string;
begin
  LRoot := TPath.Combine(TPath.GetHomePath, GLOBAL_ROOT_NAME);
  LDir := TPath.Combine(LRoot, CONFIG_DIR_REL);
  Result := TPath.Combine(LDir, CONFIG_FILE_NAME);
end;

class function TAefosFlowConfigStore._LoadRaw: string;
var
  LPath: string;
begin
  Result := '';
  LPath := _ConfigPath;
  if not TFile.Exists(LPath) then
    Exit;
  try
    Result := _StripBom(TEncoding.UTF8.GetString(TFile.ReadAllBytes(LPath)));
  except
    Result := '';
  end;
end;

class procedure TAefosFlowConfigStore._StoreRaw(const AContent: string);
begin
  WriteAllTextAtomic(_ConfigPath, AContent);
end;

class procedure TAefosFlowConfigStore.WriteAllTextAtomic(const APath,
  AContent: string);
var
  LDir: string;
  LTempPath: string;
  LBytes: TBytes;
  LStream: TFileStream;
begin
  LDir := TPath.GetDirectoryName(APath);
  if (LDir <> '') and not TDirectory.Exists(LDir) then
    TDirectory.CreateDirectory(LDir);
  // UTF-8 WITHOUT BOM (GetBytes never prepends a preamble) - byte-compatible
  // with TConfigService._WriteAtomic.
  LBytes := TEncoding.UTF8.GetBytes(AContent);
  LTempPath := APath + '.tmp';
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
    // never observes an absent/empty config and re-saves it with a single key.
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
        // best-effort cleanup; never mask the original failure
      end;
      raise EAefosFlowConfigSaveFailed.CreateFmt(
        'Cannot persist config to "%s": %s', [APath, E.Message]);
    end;
  end;
end;

class function TAefosFlowConfigStore.ReadIntFromJson(const AJson, AName: string;
  const ADefault: Integer): Integer;
var
  LRoot: TJSONValue;
  LField: TJSONValue;
begin
  Result := ADefault;
  if Trim(AJson) = '' then
    Exit;
  LRoot := TJSONObject.ParseJSONValue(AJson);
  try
    if LRoot is TJSONObject then
    begin
      LField := TJSONObject(LRoot).GetValue(AName);
      if LField is TJSONNumber then
        Result := TJSONNumber(LField).AsInt;
    end;
  finally
    LRoot.Free;
  end;
end;

class function TAefosFlowConfigStore.ReadBoolFromJson(const AJson, AName: string;
  const ADefault: Boolean): Boolean;
var
  LRoot: TJSONValue;
  LField: TJSONValue;
begin
  Result := ADefault;
  if Trim(AJson) = '' then
    Exit;
  LRoot := TJSONObject.ParseJSONValue(AJson);
  try
    if LRoot is TJSONObject then
    begin
      LField := TJSONObject(LRoot).GetValue(AName);
      if LField is TJSONBool then
        Result := TJSONBool(LField).AsBoolean;
    end;
  finally
    LRoot.Free;
  end;
end;

// Read-modify-write of a single key over the WHOLE object; the passed value is
// created and OWNED by the object (freed with it). Every sibling key survives.
class function TAefosFlowConfigStore.SetIntInJson(const AJson, AName: string;
  const AValue: Integer): string;
var
  LRoot: TJSONValue;
  LObj: TJSONObject;
begin
  LRoot := TJSONObject.ParseJSONValue(AJson);
  try
    if LRoot is TJSONObject then
    begin
      LObj := TJSONObject(LRoot);
      LObj.RemovePair(AName).Free; // nil-safe when the key is absent
      LObj.AddPair(AName, TJSONNumber.Create(AValue));
      Result := LObj.Format(2);
    end
    else
    begin
      LObj := TJSONObject.Create;
      try
        LObj.AddPair(AName, TJSONNumber.Create(AValue));
        Result := LObj.Format(2);
      finally
        LObj.Free;
      end;
    end;
  finally
    LRoot.Free; // frees the object in the TJSONObject branch
  end;
end;

class function TAefosFlowConfigStore.SetBoolInJson(const AJson, AName: string;
  const AValue: Boolean): string;
var
  LRoot: TJSONValue;
  LObj: TJSONObject;
begin
  LRoot := TJSONObject.ParseJSONValue(AJson);
  try
    if LRoot is TJSONObject then
    begin
      LObj := TJSONObject(LRoot);
      LObj.RemovePair(AName).Free;
      LObj.AddPair(AName, TJSONBool.Create(AValue));
      Result := LObj.Format(2);
    end
    else
    begin
      LObj := TJSONObject.Create;
      try
        LObj.AddPair(AName, TJSONBool.Create(AValue));
        Result := LObj.Format(2);
      finally
        LObj.Free;
      end;
    end;
  finally
    LRoot.Free;
  end;
end;

class function TAefosFlowConfigStore.ReadStringFromJson(const AJson, AName,
  ADefault: string): string;
var
  LRoot: TJSONValue;
  LField: TJSONValue;
begin
  Result := ADefault;
  if Trim(AJson) = '' then
    Exit;
  LRoot := TJSONObject.ParseJSONValue(AJson);
  try
    if LRoot is TJSONObject then
    begin
      LField := TJSONObject(LRoot).GetValue(AName);
      // An EMPTY string is not a value: a config that says the shortcut is ''
      // would leave the feature with no way to be invoked at all, so it falls
      // back to the default exactly like a missing key.
      if (LField is TJSONString) and (Trim(TJSONString(LField).Value) <> '') then
        Result := TJSONString(LField).Value;
    end;
  finally
    LRoot.Free;
  end;
end;

class function TAefosFlowConfigStore.SetStringInJson(const AJson, AName,
  AValue: string): string;
var
  LRoot: TJSONValue;
  LObj: TJSONObject;
begin
  LRoot := TJSONObject.ParseJSONValue(AJson);
  try
    if LRoot is TJSONObject then
    begin
      LObj := TJSONObject(LRoot);
      LObj.RemovePair(AName).Free;
      LObj.AddPair(AName, TJSONString.Create(AValue));
      Result := LObj.Format(2);
    end
    else
    begin
      LObj := TJSONObject.Create;
      try
        LObj.AddPair(AName, TJSONString.Create(AValue));
        Result := LObj.Format(2);
      finally
        LObj.Free;
      end;
    end;
  finally
    LRoot.Free;
  end;
end;

class function TAefosFlowConfigStore.SetInlineKnobsInJson(const AJson: string;
  const AEnabled: Boolean; const AShortcut: string): string;
var
  LShortcut: string;
begin
  // A blank shortcut would leave the feature unreachable in manual mode, so it
  // is normalised to the default HERE rather than trusted from the caller.
  LShortcut := Trim(AShortcut);
  if LShortcut = '' then
    LShortcut := INLINE_DEFAULT_SHORTCUT;
  Result := SetBoolInJson(AJson, KEY_INLINE_ENABLED, AEnabled);
  Result := SetStringInJson(Result, KEY_INLINE_SHORTCUT, LShortcut);
end;

class function TAefosFlowConfigStore.ReadInt(const AName: string;
  const ADefault: Integer): Integer;
begin
  Result := ReadIntFromJson(_LoadRaw, AName, ADefault);
end;

class function TAefosFlowConfigStore.ReadString(const AName,
  ADefault: string): string;
begin
  Result := ReadStringFromJson(_LoadRaw, AName, ADefault);
end;

class function TAefosFlowConfigStore.ReadBool(const AName: string;
  const ADefault: Boolean): Boolean;
begin
  Result := ReadBoolFromJson(_LoadRaw, AName, ADefault);
end;

class procedure TAefosFlowConfigStore.WriteInt(const AName: string;
  const AValue: Integer);
begin
  _StoreRaw(SetIntInJson(_LoadRaw, AName, AValue));
end;

class procedure TAefosFlowConfigStore.WriteBool(const AName: string;
  const AValue: Boolean);
begin
  _StoreRaw(SetBoolInJson(_LoadRaw, AName, AValue));
end;

class function TAefosFlowConfigStore.SetFlowKnobsInJson(const AJson: string;
  const AConsentMode, AEditReviewMode: Integer;
  const AAutoSave, AIssueReporting: Boolean): string;
begin
  // Chain the four single-key read-modify-writes; each preserves every sibling
  // key, so the net result is the whole document with just these four updated.
  Result := SetIntInJson(AJson, KEY_AGENT_CONSENT_MODE, AConsentMode);
  Result := SetIntInJson(Result, KEY_AGENT_EDIT_REVIEW_MODE, AEditReviewMode);
  Result := SetBoolInJson(Result, KEY_AGENT_AUTO_SAVE, AAutoSave);
  Result := SetBoolInJson(Result, KEY_ISSUE_REPORTING, AIssueReporting);
end;

class procedure TAefosFlowConfigStore.UpdateFlowKnobs(const AConsentMode,
  AEditReviewMode: Integer; const AAutoSave, AIssueReporting: Boolean);
begin
  // ONE load, four in-memory updates, ONE atomic store: all-or-nothing.
  _StoreRaw(SetFlowKnobsInJson(_LoadRaw,
    AConsentMode, AEditReviewMode, AAutoSave, AIssueReporting));
end;

class procedure TAefosFlowConfigStore.WriteString(const AName, AValue: string);
begin
  _StoreRaw(SetStringInJson(_LoadRaw, AName, AValue));
end;

class procedure TAefosFlowConfigStore.UpdateInlineKnobs(const AEnabled: Boolean;
  const AShortcut: string);
begin
  _StoreRaw(SetInlineKnobsInJson(_LoadRaw, AEnabled, AShortcut));
end;

{ TAefosFlowMigration }

class function TAefosFlowMigration.MigrationPending(
  const AMarkerSet: Boolean): Boolean;
begin
  Result := not AMarkerSet;
end;

class function TAefosFlowMigration.ShouldImportKnob(const AMarkerSet,
  ARegistryHasValue: Boolean): Boolean;
begin
  Result := (not AMarkerSet) and ARegistryHasValue;
end;

end.
