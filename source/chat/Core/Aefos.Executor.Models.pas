unit Aefos.Executor.Models;

{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{ Per-executor model/effort store (models.json) - the SHARED, IDE-agnostic core.

  The file-backed half of what TExecutorModels used to own inside
  Aefos.OTA.Chat.UI.Options.Binding. That unit is Delphi/OTA-coupled (it lives in
  the chat UI folder and is compiled into the design-time BPL), so the Lazarus
  edition could not read the SAME %APPDATA%\Aefos\models.json the RAD Studio
  plugin writes. Two IDEs diverging over one global config file is exactly what
  the port forbids, so the store is EXTRACTED here rather than reimplemented.

  This follows the Aefos.Provider.Kinds precedent (fase G) to the letter:
    * the pure/portable logic moves out verbatim - same semantics, same file
      layout, same one-shot migrations, same curated seeds;
    * the original class (TExecutorModels) stays put as a THIN FACE delegating
      1:1, so every existing Delphi call site keeps working byte-identically and
      nothing about the shipped behaviour changes;
    * the mapping has a single source of truth from here on.

  Portability: delphiunicode mode under FPC (string = UnicodeString, matching
  Delphi), JSON through Aefos.Compat.Json and file I/O through Aefos.Compat.IO -
  both of which are plain type aliases on Delphi, so the Delphi code path is
  literally the code that shipped. No Vcl.*, no ToolsAPI, no LCL.

  FILE LAYOUT (%APPDATA%\Aefos\models.json), unchanged - a single JSON object of:
    * one member per executor kind ("claude", "codex", "copilot", "gemini",
      "ollama"), each an array of model-id strings: the EDITABLE list;
    * "__selected__" - an object mapping each kind to its picked model id;
    * "__effort__"   - an object mapping each kind to its reasoning-effort token.
  The per-kind SELECTED model is what keeps one provider's model from leaking
  into another (a Claude model dispatched at Gemini -> ModelNotFound 404).

  (No literal braces above: this is a brace comment, and a nested closing brace
  would end it early.) }

interface

uses
  Aefos.Provider.Types;

type
  // Sealed static namespace: the file-backed per-executor model + effort store.
  // Never instantiated. The ONLY reader/writer of models.json.
  TExecutorModelStore = class sealed
  private
    class var FRootOverride: string;
  public
    // ⚠️ TEST SEAM ONLY - production NEVER sets this, on either IDE.
    // '' (the default) resolves the SHIPPED shared root, %APPDATA%\Aefos, which
    // is the whole point of this unit: one file, both IDEs. A non-empty value
    // redirects models.json into that folder instead, so a test can exercise the
    // seeding/persistence without writing to the developer's (or the user's)
    // real config. Setting it anywhere in shipping code would re-create exactly
    // the divergence this extraction exists to prevent.
    class property RootOverride: string read FRootOverride write FRootOverride;
    // Curated, executor-scoped model suggestion list. UI affordance data only -
    // the model combobox stays editable, so an off-list or future model is still
    // accepted and saved verbatim (BR-3). Pure: no I/O.
    class function SuggestedModels(const AKind: TExecutorKind): TArray<string>; static;
    // The models.json member name for a kind. Pure: no I/O.
    class function ExecutorKindKey(const AKind: TExecutorKind): string; static;
    // The editable list for a kind, seeding + persisting the curated defaults on
    // first use (or when the retired-seed migration below fires).
    class function ModelsForKind(const AKind: TExecutorKind): TArray<string>; static;
    class procedure AddModelForKind(const AKind: TExecutorKind; const AModel: string); static;
    class procedure RemoveModelForKind(const AKind: TExecutorKind; const AModel: string); static;
    // '' when nothing is remembered yet.
    class function SelectedModelForKind(const AKind: TExecutorKind): string; static;
    class procedure SetSelectedModelForKind(const AKind: TExecutorKind;
      const AModel: string); static;
    // Per-executor reasoning-effort CLI token (under "__effort__"), the same
    // store/pattern as the selected model. '' = Default (send nothing).
    class function SelectedEffortForKind(const AKind: TExecutorKind): string; static;
    class procedure SetSelectedEffortForKind(const AKind: TExecutorKind;
      const AToken: string); static;
    // Pure (no I/O) predicate: True when AList is EXACTLY the retired 2025 Codex
    // seed (['gpt-5-codex','gpt-5']) - both slugs the ChatGPT backend rejects.
    // A list that matches was never customised, so ModelsForKind re-seeds it; any
    // other list is the user's and is left untouched.
    class function IsRetiredCodexSeed(const AKind: TExecutorKind;
      const AList: TArray<string>): Boolean; static;
  end;

implementation

uses
  SysUtils,
  Aefos.Compat.IO,
  Aefos.Compat.Json;

const
  SELECTED_KEY = '__selected__';
  EFFORT_KEY = '__effort__';

class function TExecutorModelStore.SuggestedModels(
  const AKind: TExecutorKind): TArray<string>;
begin
  // Sourced from each executor's published model identifiers (esp.md OQ-1).
  Result := [];
  case AKind of
    ekClaude:
      Result := ['claude-opus-4-7', 'claude-sonnet-4-6',
        'claude-haiku-4-5-20251001'];
    ekCodex:
      // The ChatGPT-account backend RETIRES old slugs ("The 'gpt-5' model is
      // not supported when using Codex with a ChatGPT account", field report
      // 2026-07-08): gpt-5/gpt-5-codex died 2026-03. Seed the current
      // generation; when these age out the user adds the new slug via "+"
      // (the CLI's own default shows in the bare `codex` banner). NOTE: the
      // seed only reaches FRESH machines - models.json persists per user.
      Result := ['gpt-5.5', 'gpt-5.4', 'gpt-5.4-mini'];
    ekCopilot:
      // Valid `--model` ids depend on the user's Copilot plan; gpt-5-mini is the
      // confirmed default. Others (gpt-5/claude-*) errored as "not available" -
      // the user adds the ones their plan exposes via the Options "+".
      Result := ['gpt-5-mini'];
    ekGemini:
      Result := ['gemini-2.5-pro', 'gemini-2.5-flash'];
    ekOllama:
      // Seeds only - the user's real list is whatever `ollama pull` fetched;
      // the "+" button adds any local tag.
      Result := ['qwen2.5-coder:7b', 'llama3.1:8b', 'gpt-oss:20b'];
  end;
end;

class function TExecutorModelStore.ExecutorKindKey(
  const AKind: TExecutorKind): string;
begin
  if AKind = ekCodex then
    Result := 'codex'
  else if AKind = ekCopilot then
    Result := 'copilot'
  else if AKind = ekGemini then
    Result := 'gemini'
  else if AKind = ekOllama then
    Result := 'ollama'
  else
    Result := 'claude';
end;

function _ModelsConfigPath: string;
begin
  // The default arm is the ORIGINAL expression, unchanged: TPath.GetHomePath is
  // %APPDATA% on Windows, so this is %APPDATA%\Aefos\models.json for both IDEs.
  if TExecutorModelStore.RootOverride <> '' then
    Result := TPath.Combine(TExecutorModelStore.RootOverride, 'models.json')
  else
    Result := TPath.Combine(TPath.Combine(TPath.GetHomePath, 'Aefos'),
      'models.json');
end;

function _ModelsRoot: TJSONObject;
var
  LVal: TJSONValue;
begin
  Result := nil;
  if TFile.Exists(_ModelsConfigPath) then
    try
      LVal := TJSONObject.ParseJSONValue(
        TAefosText.ReadAllUtf8(_ModelsConfigPath));
      if LVal is TJSONObject then
        Result := TJSONObject(LVal)
      else
        LVal.Free;
    except
      Result := nil;
    end;
  if Result = nil then
    Result := TJSONObject.Create;
end;

procedure _SaveModelsRoot(const ARoot: TJSONObject);
begin
  TDirectory.CreateDirectory(TPath.GetDirectoryName(_ModelsConfigPath));
  TFile.WriteAllText(_ModelsConfigPath, ARoot.ToJSON, TEncoding.UTF8);
end;

procedure _SetKindArr(const ARoot: TJSONObject; const AKey: string;
  const AList: TArray<string>);
var
  LArr: TJSONArray;
  LModel: string;
begin
  ARoot.RemovePair(AKey).Free; // nil-safe: Free on a nil instance is a no-op
  LArr := TJSONArray.Create;
  for LModel in AList do
    LArr.Add(LModel);
  ARoot.AddPair(AKey, LArr);
end;

class function TExecutorModelStore.ModelsForKind(
  const AKind: TExecutorKind): TArray<string>;
var
  LRoot: TJSONObject;
  LVal: TJSONValue;
  LArr: TJSONArray;
  LSelObj: TJSONObject;
  LFor: Integer;
begin
  Result := nil;
  LRoot := _ModelsRoot;
  try
    LVal := LRoot.GetValue(ExecutorKindKey(AKind));
    if LVal is TJSONArray then
    begin
      LArr := TJSONArray(LVal);
      for LFor := 0 to LArr.Count - 1 do
        if LArr.Items[LFor] is TJSONString then
          Result := Result + [TJSONString(LArr.Items[LFor]).Value];
      // One-shot migration: a codex list that is EXACTLY the retired 2025
      // seed (never customized by the user) is re-seeded - the ChatGPT
      // backend rejects those slugs outright ("The 'gpt-5' model is not
      // supported when using Codex with a ChatGPT account", field report
      // 2026-07-08). A customized list is the user's and is never touched.
      if IsRetiredCodexSeed(AKind, Result) then
        Result := nil // fall through to the fresh seed below
      else if Length(Result) > 0 then
        Exit;
    end;
    // Absent or empty -> seed from the curated defaults and persist so the file
    // becomes the editable source of truth from here on.
    Result := SuggestedModels(AKind);
    _SetKindArr(LRoot, ExecutorKindKey(AKind), Result);
    // The remembered selection must not keep pointing at a retired slug the
    // list no longer offers - recall would re-dispatch a dead model.
    if (AKind = ekCodex) and (Length(Result) > 0) then
    begin
      LVal := LRoot.GetValue(SELECTED_KEY);
      if LVal is TJSONObject then
      begin
        // Bound to a typed local rather than calling through a hard cast: FPC
        // 3.2.2 mis-parses some method calls made through `TJSONObject(x).`.
        LSelObj := TJSONObject(LVal);
        if LSelObj.GetValue(ExecutorKindKey(AKind)) <> nil then
        begin
          LSelObj.RemovePair(ExecutorKindKey(AKind)).Free;
          LSelObj.AddPair(ExecutorKindKey(AKind), Result[0]);
        end;
      end;
    end;
    _SaveModelsRoot(LRoot);
  finally
    LRoot.Free;
  end;
end;

class procedure TExecutorModelStore.AddModelForKind(const AKind: TExecutorKind;
  const AModel: string);
var
  LList: TArray<string>;
  LModel, LExisting: string;
  LRoot: TJSONObject;
begin
  LModel := Trim(AModel);
  if LModel = '' then
    Exit;
  LList := ModelsForKind(AKind); // ensures the kind is seeded first
  for LExisting in LList do
    if SameText(LExisting, LModel) then
      Exit; // already present
  LList := LList + [LModel];
  LRoot := _ModelsRoot;
  try
    _SetKindArr(LRoot, ExecutorKindKey(AKind), LList);
    _SaveModelsRoot(LRoot);
  finally
    LRoot.Free;
  end;
end;

class procedure TExecutorModelStore.RemoveModelForKind(
  const AKind: TExecutorKind; const AModel: string);
var
  LKept: TArray<string>;
  LModel, LExisting: string;
  LRoot: TJSONObject;
begin
  LModel := Trim(AModel);
  if LModel = '' then
    Exit;
  // Keep every entry except the one to drop (case-insensitive); persist only
  // when something actually changed.
  SetLength(LKept, 0);
  for LExisting in ModelsForKind(AKind) do
    if not SameText(LExisting, LModel) then
      LKept := LKept + [LExisting];
  LRoot := _ModelsRoot;
  try
    _SetKindArr(LRoot, ExecutorKindKey(AKind), LKept);
    _SaveModelsRoot(LRoot);
  finally
    LRoot.Free;
  end;
end;

class function TExecutorModelStore.SelectedModelForKind(
  const AKind: TExecutorKind): string;
var
  LRoot: TJSONObject;
  LSelVal, LModelVal: TJSONValue;
  LSelObj: TJSONObject;
begin
  Result := '';
  LRoot := _ModelsRoot;
  try
    LSelVal := LRoot.GetValue(SELECTED_KEY);
    if LSelVal is TJSONObject then
    begin
      LSelObj := TJSONObject(LSelVal);
      LModelVal := LSelObj.GetValue(ExecutorKindKey(AKind));
      if LModelVal is TJSONString then
        Result := TJSONString(LModelVal).Value;
    end;
  finally
    LRoot.Free;
  end;
end;

class procedure TExecutorModelStore.SetSelectedModelForKind(
  const AKind: TExecutorKind; const AModel: string);
var
  LRoot, LSel: TJSONObject;
  LSelVal: TJSONValue;
begin
  LRoot := _ModelsRoot;
  try
    LSelVal := LRoot.GetValue(SELECTED_KEY);
    if LSelVal is TJSONObject then
      LSel := TJSONObject(LSelVal)
    else
    begin
      if LSelVal <> nil then
        LRoot.RemovePair(SELECTED_KEY).Free;
      LSel := TJSONObject.Create;
      LRoot.AddPair(SELECTED_KEY, LSel);
    end;
    LSel.RemovePair(ExecutorKindKey(AKind)).Free;
    LSel.AddPair(ExecutorKindKey(AKind), Trim(AModel));
    _SaveModelsRoot(LRoot);
  finally
    LRoot.Free;
  end;
end;

class function TExecutorModelStore.IsRetiredCodexSeed(const AKind: TExecutorKind;
  const AList: TArray<string>): Boolean;
begin
  Result := (AKind = ekCodex) and (Length(AList) = 2) and
    SameText(AList[0], 'gpt-5-codex') and SameText(AList[1], 'gpt-5');
end;

class function TExecutorModelStore.SelectedEffortForKind(
  const AKind: TExecutorKind): string;
var
  LRoot: TJSONObject;
  LMapVal, LTokVal: TJSONValue;
  LMapObj: TJSONObject;
begin
  Result := '';
  LRoot := _ModelsRoot;
  try
    LMapVal := LRoot.GetValue(EFFORT_KEY);
    if LMapVal is TJSONObject then
    begin
      LMapObj := TJSONObject(LMapVal);
      LTokVal := LMapObj.GetValue(ExecutorKindKey(AKind));
      if LTokVal is TJSONString then
        Result := TJSONString(LTokVal).Value;
    end;
  finally
    LRoot.Free;
  end;
end;

class procedure TExecutorModelStore.SetSelectedEffortForKind(
  const AKind: TExecutorKind; const AToken: string);
var
  LRoot, LMap: TJSONObject;
  LMapVal: TJSONValue;
begin
  LRoot := _ModelsRoot;
  try
    LMapVal := LRoot.GetValue(EFFORT_KEY);
    if LMapVal is TJSONObject then
      LMap := TJSONObject(LMapVal)
    else
    begin
      if LMapVal <> nil then
        LRoot.RemovePair(EFFORT_KEY).Free;
      LMap := TJSONObject.Create;
      LRoot.AddPair(EFFORT_KEY, LMap);
    end;
    LMap.RemovePair(ExecutorKindKey(AKind)).Free;
    LMap.AddPair(ExecutorKindKey(AKind), Trim(AToken));
    _SaveModelsRoot(LRoot);
  finally
    LRoot.Free;
  end;
end;

end.
