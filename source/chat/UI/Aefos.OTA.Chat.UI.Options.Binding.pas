unit Aefos.OTA.Chat.UI.Options.Binding;

{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  ToolsAPI-free binding seam between the IConfig service and the
  Tools->Options page frames (ESP-002, Epic 4/4, Demand 1/1, ADR-207/208).

  The option frames are TFrame descendants embedded by the IDE and therefore
  link ToolsAPI; this unit is deliberately pure (no ToolsAPI, no Vcl.*, no
  direct OTA) so the load/validate/save/discard logic and the no-active-project
  guard are unit-testable in the standalone runner EXE (AC-11). Each frame
  delegates its INTAAddInOptions lifecycle (FrameCreated/ValidateContents/
  DialogClosed) to a TOptionsConfigBinding instance.

  Behavioural rules:
    - RN-001: the config root is injected via a TFunc<string> (the same shape
      Register feeds TConfigService) so no OTA call lives here. The SHIPPED Options
      wiring injects the GLOBAL %APPDATA%\Aefos root (install-feedback #1), so
      executor/path/model are IDE-wide per user profile, NOT per-project. The class
      stays root-agnostic; RN-002 is the generic empty-root guard, but the shipped
      global root is never empty (so Options also saves on the Welcome page).
    - RN-002: empty root -> HasActiveProject = False; SaveToConfig is a
      no-op (never writes to an empty/wrong root, never raises).
    - RN-003: single source of truth — load/save go through IConfig only.
    - RN-004: persist via IConfig.Save only on accept; SaveToConfig re-reads the
      latest snapshot and overlays just the fields its scope owns, so two pages
      saved in one dialog session never clobber each other's fields.

  The two pure helpers (ExecutorPathValid, SuggestedModels) are lifted here
  from UI.ConfigDialog (ADR-211) so they are shared by the Chat frame and
  unit-tested without a live form.
}

interface

uses
  SysUtils,
  Aefos.Provider.Types,
  Aefos.OTA.Chat.Core.Dispatcher.Types,
  // For TConfigRootResolver: the compiler-shim alias for the injected config-root
  // resolver (TFunc<string> on Delphi, `of object` on FPC 3.2.2, which has no
  // anonymous methods). Single-sourced there rather than re-declared here.
  Aefos.OTA.Chat.Core.Config,
  Aefos.OTA.Chat.Core.Config.Types;

type
  // Reasoning-effort level offered by executors that expose one (Codex today).
  // reDefault = send nothing (the executor's own effort). The CLI wire token and
  // the user-facing pill label are derived by TReasoningEfforts.
  TReasoningEffort = (reDefault, reLow, reMedium, reHigh, reXHigh);

  // Which subset of TConfig an option page owns. SaveToConfig merges only the
  // owned fields back into the latest on-disk snapshot (RN-004).
  TOptionsScope = (osChat, osMcp);

  // Plain editable mirror of the option-page inputs. No behaviour — the frames
  // read from / write to this record and the binding maps it to TConfig.
  TOptionsEditState = record
    Executor: TExecutorKind;
    ExecutorPath: string;
    Model: string;
    InspectorEnabled: Boolean;
    // Chat-scope runtime settings (ADR-290).
    TimeoutSeconds: Integer;
    OutputFilter: TOutputFilterPolicy;
    // Local-model endpoint (ekOllama only). '' = the transport default
    // (http://localhost:11434).
    OllamaBaseUrl: string;
  end;

  TOptionsConfigBinding = class
  private
    FConfig: IConfig;
    FRootResolver: TConfigRootResolver;
    FScope: TOptionsScope;
    FState: TOptionsEditState;
    function _NormalisePath(const AValue: string): string;
  public
    constructor Create(const AConfig: IConfig;
      const ARootResolver: TConfigRootResolver; const AScope: TOptionsScope);
    // Refreshes IConfig from disk and copies the snapshot into State (RN-003).
    procedure LoadFromConfig;
    // Validates the owned fields. osChat checks the executor path (empty is
    // valid; a non-empty path must exist). osMcp has nothing to validate.
    function Validate(out AReason: string): Boolean;
    // Read-modify-write: reloads the latest snapshot, overlays the owned
    // fields, persists once. No-op when there is no active project (RN-002).
    procedure SaveToConfig;
    // True when the injected resolver yields a non-empty project root.
    function HasActiveProject: Boolean;
    property State: TOptionsEditState read FState write FState;
  end;

type
  // Path validation for the executor binary field.
  TExecutorPath = class sealed
  public
    // True when APath is empty (the executor resolves from PATH) or names an
    // existing file. APath must already be normalised by the caller (BR-4).
    class function ExecutorPathValid(const APath: string): Boolean; static;
  end;

  // User-editable, file-backed per-executor model list (models.json) — seeded
  // from SuggestedModels on first use, then extended via the Options "+" or the
  // fetch (avoids a BPL rebuild when a new model ships). Also owns the
  // per-executor SELECTED model (under a "__selected__" map) so switching
  // executor never carries one provider's model into another (e.g. a Claude
  // model into Gemini -> ModelNotFound 404).
  //
  // ⚠️ THIS IS NOW A THIN FACE. The store itself was extracted VERBATIM to the
  // shared, IDE-agnostic Aefos.Executor.Models (TExecutorModelStore) so the
  // Lazarus edition reads and writes the SAME %APPDATA%\Aefos\models.json — two
  // IDEs must never diverge over one global config file. Every member below
  // delegates 1:1 and adds nothing; Delphi behaviour is unchanged. Add new store
  // behaviour to TExecutorModelStore, never here.
  TExecutorModels = class sealed
  public
    // Curated, executor-scoped model suggestion list. UI affordance data only —
    // the model combobox stays editable, so an off-list or future model is still
    // accepted and saved verbatim (BR-3).
    class function SuggestedModels(const AKind: TExecutorKind): TArray<string>; static;
    class function ExecutorKindKey(const AKind: TExecutorKind): string; static;
    class function ModelsForKind(const AKind: TExecutorKind): TArray<string>; static;
    class procedure AddModelForKind(const AKind: TExecutorKind; const AModel: string); static;
    class procedure RemoveModelForKind(const AKind: TExecutorKind; const AModel: string); static;
    // '' when nothing is remembered yet.
    class function SelectedModelForKind(const AKind: TExecutorKind): string; static;
    class procedure SetSelectedModelForKind(const AKind: TExecutorKind;
      const AModel: string); static;
    // Per-executor reasoning-effort CLI token (under a "__effort__" map), the
    // same store/pattern as the selected model. '' = Default (send nothing).
    class function SelectedEffortForKind(const AKind: TExecutorKind): string; static;
    class procedure SetSelectedEffortForKind(const AKind: TExecutorKind;
      const AToken: string); static;
    // Pure (no I/O) predicate: True when AList is EXACTLY the retired 2025 Codex
    // seed (['gpt-5-codex','gpt-5']) — both slugs the ChatGPT backend rejects.
    // A list that matches was never customised, so ModelsForKind re-seeds it; any
    // other list is the user's and is left untouched.
    class function IsRetiredCodexSeed(const AKind: TExecutorKind;
      const AList: TArray<string>): Boolean; static;
  end;

  // Reasoning-effort value/label conversions (CLI wire token <-> enum <-> pill
  // label). Pure — the single source of truth for the effort vocabulary.
  TReasoningEfforts = class sealed
  public
    // '' | 'low' | 'medium' | 'high' | 'xhigh'.
    class function CliToken(const AEffort: TReasoningEffort): string; static;
    // 'Default' | 'Low' | 'Medium' | 'High' | 'XHigh'.
    class function DisplayLabel(const AEffort: TReasoningEffort): string; static;
    // Parses a CLI token (case-insensitive); anything unrecognised -> reDefault.
    class function FromCliToken(const AToken: string): TReasoningEffort; static;
  end;

  // Per-executor capability flags (enum-driven, no scattered ifs). The chat
  // header consults these to decide which controls to render.
  TExecutorCapabilities = class sealed
  public
    // True when the executor exposes a reasoning-effort control (Codex today).
    class function SupportsReasoningEffort(const AKind: TExecutorKind): Boolean; static;
  end;

  // Per-executor API key (apikeys.json) for providers that authenticate by key
  // (Gemini). The dispatch injects it as the provider's env var so no system env
  // or IDE restart is needed. Plaintext on disk (user-supplied convenience).
  TExecutorApiKeys = class sealed
  public
    class function ApiKeyForKind(const AKind: TExecutorKind): string; static;
    class procedure SetApiKeyForKind(const AKind: TExecutorKind; const AKey: string); static;
    // Env-var name the executor reads its key from ('' = the executor uses login).
    class function ApiKeyEnvVarFor(const AKind: TExecutorKind): string; static;
  end;

  // Official download-page URL per executor CLI — the pure lookup behind the
  // Options "Download..." button. NOTE: the installer now DOES bundle the
  // redistributable CLIs (codex; gemini via SEA — see installer\fetch-clis.ps1),
  // so this button is the fallback for the ones we cannot bundle (Claude,
  // Copilot) and a manual update path. Aefos still owns no credentials.
  TExecutorDownloads = class sealed
  public
    // The official download/release page for AKind's CLI. '' when the kind has
    // no CLI to download (there is none today — every TExecutorKind ships one —
    // but the empty-string contract is kept so a future kind without a
    // standalone CLI degrades to a disabled button instead of a dead link).
    class function DownloadUrlForKind(const AKind: TExecutorKind): string; static;
  end;

implementation

uses
  // Compat shims: pure type aliases onto System.IOUtils / System.JSON on Delphi
  // (byte-identical behaviour), real implementations on FPC 3.2.2 which ships
  // neither. This unit sits in Aefos.OTA.Chat.bpl, which already requires
  // Aefos.MCP.Core.bpl (where the shims are compiled), so no package-graph change.
  Aefos.Compat.IO,
  Aefos.Compat.Json,
  Aefos.Executor.Models;

class function TExecutorPath.ExecutorPathValid(const APath: string): Boolean;
begin
  Result := (APath = '') or TFile.Exists(APath);
end;

// --- TExecutorModels: a 1:1 face over the shared store ----------------------
// Every member forwards verbatim to TExecutorModelStore (Aefos.Executor.Models),
// which is the single implementation of models.json for BOTH IDEs. Nothing here
// may add behaviour - a rule added on one side only would be a divergence the
// user sees as "the two IDEs disagree about my models".

class function TExecutorModels.SuggestedModels(const AKind: TExecutorKind): TArray<string>;
begin
  Result := TExecutorModelStore.SuggestedModels(AKind);
end;

class function TExecutorModels.ExecutorKindKey(const AKind: TExecutorKind): string;
begin
  Result := TExecutorModelStore.ExecutorKindKey(AKind);
end;

class function TExecutorModels.ModelsForKind(const AKind: TExecutorKind): TArray<string>;
begin
  Result := TExecutorModelStore.ModelsForKind(AKind);
end;

class procedure TExecutorModels.AddModelForKind(const AKind: TExecutorKind; const AModel: string);
begin
  TExecutorModelStore.AddModelForKind(AKind, AModel);
end;

class procedure TExecutorModels.RemoveModelForKind(const AKind: TExecutorKind; const AModel: string);
begin
  TExecutorModelStore.RemoveModelForKind(AKind, AModel);
end;

class function TExecutorModels.SelectedModelForKind(const AKind: TExecutorKind): string;
begin
  Result := TExecutorModelStore.SelectedModelForKind(AKind);
end;

class procedure TExecutorModels.SetSelectedModelForKind(const AKind: TExecutorKind;
  const AModel: string);
begin
  TExecutorModelStore.SetSelectedModelForKind(AKind, AModel);
end;

class function TExecutorModels.IsRetiredCodexSeed(const AKind: TExecutorKind;
  const AList: TArray<string>): Boolean;
begin
  Result := TExecutorModelStore.IsRetiredCodexSeed(AKind, AList);
end;

class function TExecutorModels.SelectedEffortForKind(
  const AKind: TExecutorKind): string;
begin
  Result := TExecutorModelStore.SelectedEffortForKind(AKind);
end;

class procedure TExecutorModels.SetSelectedEffortForKind(
  const AKind: TExecutorKind; const AToken: string);
begin
  TExecutorModelStore.SetSelectedEffortForKind(AKind, AToken);
end;

class function TReasoningEfforts.CliToken(
  const AEffort: TReasoningEffort): string;
begin
  case AEffort of
    reLow: Result := 'low';
    reMedium: Result := 'medium';
    reHigh: Result := 'high';
    reXHigh: Result := 'xhigh';
  else
    Result := ''; // reDefault: send nothing
  end;
end;

class function TReasoningEfforts.DisplayLabel(
  const AEffort: TReasoningEffort): string;
begin
  case AEffort of
    reLow: Result := 'Low';
    reMedium: Result := 'Medium';
    reHigh: Result := 'High';
    reXHigh: Result := 'XHigh';
  else
    Result := 'Default';
  end;
end;

class function TReasoningEfforts.FromCliToken(
  const AToken: string): TReasoningEffort;
var
  LToken: string;
begin
  LToken := LowerCase(Trim(AToken));
  if LToken = 'low' then
    Result := reLow
  else if LToken = 'medium' then
    Result := reMedium
  else if LToken = 'high' then
    Result := reHigh
  else if LToken = 'xhigh' then
    Result := reXHigh
  else
    Result := reDefault;
end;

class function TExecutorCapabilities.SupportsReasoningEffort(
  const AKind: TExecutorKind): Boolean;
begin
  Result := AKind = ekCodex;
end;

class function TExecutorApiKeys.ApiKeyEnvVarFor(const AKind: TExecutorKind): string;
begin
  if AKind = ekGemini then
    Result := 'GEMINI_API_KEY'
  else
    Result := '';
end;

function _ApiKeysConfigPath: string;
begin
  Result := TPath.Combine(TPath.Combine(TPath.GetHomePath, 'Aefos'),
    'apikeys.json');
end;

function _ApiKeysRoot: TJSONObject;
var
  LVal: TJSONValue;
begin
  Result := nil;
  if TFile.Exists(_ApiKeysConfigPath) then
    try
      LVal := TJSONObject.ParseJSONValue(
        TAefosText.ReadAllUtf8(_ApiKeysConfigPath));
      if LVal is TJSONObject then
        Result := TJSONObject(LVal)
      else if LVal <> nil then
        LVal.Free;
    except
      Result := nil;
    end;
  if Result = nil then
    Result := TJSONObject.Create;
end;

class function TExecutorApiKeys.ApiKeyForKind(const AKind: TExecutorKind): string;
var
  LRoot: TJSONObject;
  LVal: TJSONValue;
begin
  Result := '';
  LRoot := _ApiKeysRoot;
  try
    LVal := LRoot.GetValue(TExecutorModels.ExecutorKindKey(AKind));
    if LVal is TJSONString then
      Result := TJSONString(LVal).Value;
  finally
    LRoot.Free;
  end;
end;

class procedure TExecutorApiKeys.SetApiKeyForKind(const AKind: TExecutorKind; const AKey: string);
var
  LRoot: TJSONObject;
begin
  LRoot := _ApiKeysRoot;
  try
    LRoot.RemovePair(TExecutorModels.ExecutorKindKey(AKind)).Free; // nil-safe
    if Trim(AKey) <> '' then
      LRoot.AddPair(TExecutorModels.ExecutorKindKey(AKind), AKey);
    TDirectory.CreateDirectory(TPath.GetDirectoryName(_ApiKeysConfigPath));
    TFile.WriteAllText(_ApiKeysConfigPath, LRoot.ToJSON, TEncoding.UTF8);
  finally
    LRoot.Free;
  end;
end;

class function TExecutorDownloads.DownloadUrlForKind(
  const AKind: TExecutorKind): string;
begin
  case AKind of
    ekClaude:
      Result := 'https://claude.com/claude-code';
    ekCodex:
      Result := 'https://github.com/openai/codex/releases';
    ekCopilot:
      Result := 'https://github.com/github/copilot-cli';
    ekGemini:
      Result := 'https://github.com/google-gemini/gemini-cli';
    ekOllama:
      Result := 'https://ollama.com/download';
  else
    Result := '';
  end;
end;

{ TOptionsConfigBinding }

constructor TOptionsConfigBinding.Create(const AConfig: IConfig;
  const ARootResolver: TConfigRootResolver; const AScope: TOptionsScope);
begin
  inherited Create;
  if not Assigned(AConfig) then
    raise EArgumentNilException.Create('TOptionsConfigBinding: AConfig');
  if not Assigned(ARootResolver) then
    raise EArgumentNilException.Create('TOptionsConfigBinding: ARootResolver');
  FConfig := AConfig;
  FRootResolver := ARootResolver;
  FScope := AScope;
  FState := Default(TOptionsEditState);
end;

function TOptionsConfigBinding.HasActiveProject: Boolean;
begin
  Result := Trim(FRootResolver()) <> '';
end;

function TOptionsConfigBinding._NormalisePath(const AValue: string): string;
begin
  Result := StringReplace(AValue, '/', '\', [rfReplaceAll]);
end;

procedure TOptionsConfigBinding.LoadFromConfig;
var
  LSnapshot: TConfig;
begin
  // Refresh from disk: the composition-root Load runs before any project is
  // active, so the in-memory snapshot can be stale by the time Options opens.
  FConfig.Load;
  LSnapshot := FConfig.Snapshot;
  FState.Executor := LSnapshot.Executor;
  FState.ExecutorPath := LSnapshot.ExecutorPath;
  FState.Model := LSnapshot.Model;
  FState.InspectorEnabled := LSnapshot.Inspector.Enabled;
  FState.TimeoutSeconds := LSnapshot.TimeoutSeconds;
  FState.OutputFilter := LSnapshot.OutputFilter;
  FState.OllamaBaseUrl := LSnapshot.OllamaBaseUrl;
end;

function TOptionsConfigBinding.Validate(out AReason: string): Boolean;
var
  LPath: string;
begin
  AReason := '';
  // RN-002: with no active project the inputs are disabled and nothing is
  // persisted, so there is nothing to reject.
  if not HasActiveProject then
    Exit(True);
  if FScope <> osChat then
    Exit(True);
  LPath := _NormalisePath(Trim(FState.ExecutorPath));
  if TExecutorPath.ExecutorPathValid(LPath) then
    Exit(True);
  AReason := 'Executor binary path does not exist: ' + LPath;
  Result := False;
end;

procedure TOptionsConfigBinding.SaveToConfig;
var
  LConfig: TConfig;
begin
  // RN-002: never write to an empty/wrong root.
  if not HasActiveProject then
    Exit;
  // RN-004: re-read the latest snapshot and overlay only the owned fields so a
  // sibling page saved in the same dialog session is not clobbered.
  FConfig.Load;
  LConfig := FConfig.Snapshot;
  case FScope of
    osChat:
      begin
        LConfig.Executor := FState.Executor;
        LConfig.ExecutorPath := _NormalisePath(Trim(FState.ExecutorPath));
        LConfig.Model := Trim(FState.Model);
        // A negative spin value is clamped to 0 (disabled) on the way to disk.
        if FState.TimeoutSeconds > 0 then
          LConfig.TimeoutSeconds := FState.TimeoutSeconds
        else
          LConfig.TimeoutSeconds := 0;
        LConfig.OutputFilter := FState.OutputFilter;
        LConfig.OllamaBaseUrl := Trim(FState.OllamaBaseUrl);
        // The former standalone "MCP Server" page was merged into the Chat page
        // (2026-06-09), so the Chat scope now also owns the Inspector toggle.
        LConfig.Inspector.Enabled := FState.InspectorEnabled;
      end;
    osMcp: // retained for compatibility; no page uses this scope after the merge
      LConfig.Inspector.Enabled := FState.InspectorEnabled;
  end;
  FConfig.Save(LConfig);
end;

end.
