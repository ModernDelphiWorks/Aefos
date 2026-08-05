unit Aefos.Provider.Codex;

{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{ Codex driver. Extension-less binary name (ADR-077). MCP is wired per-invocation
  via `-c mcp_servers.*` TOML overrides in the dispatcher, not a config file, so
  BuildMcpConfigJson is unsupported here. Custom prompts are flat `<name>.md`
  files (frontmatter stripped) under the global $CODEX_HOME\prompts root. }

interface

uses
  Aefos.Provider.Types;

type
  TCodexExecutorProfile = class(TInterfacedObject, IExecutorProfile)
  private
    FMcpSupport: TMcpSupport;
  public
    constructor Create(const AMcpSupport: TMcpSupport = msUnknown);
    function Kind: TExecutorKind;
    function BinaryName: string;
    function ReplicationTargetRel: string;
    function McpSupport: TMcpSupport;
    function BuildMcpConfigJson(const ARelayExePath,
      APipeName: string): string;
    function BuildModelArgs(const AModel: string): TArray<string>;
    function CliNotFoundHint: string;
    function CommandReplicaRelPath(const ACommandName: string): string;
    function RequiresCommandConversion: Boolean;
    function ConvertCommand(const ACanonicalContent: string): string;
    function ReferenceReplicaRelPath(const ACommandName,
      AReferenceName: string): string;
    function ResolveReplicationRoot(const AProjectRoot: string): string;
    function BuildDispatchArgs(
      const ACtx: TProviderDispatchContext): TArray<string>;
    function SessionSupport: TSessionSupport;
    function TryCaptureSessionId(const AOutput: UnicodeString;
      out ASessionId: UnicodeString): Boolean;
  end;

// Model discovery (the STANDARD "Test" contract, 2026-07-08): the Test button
// refreshes the model list whenever the provider exposes a REAL source. Codex
// has no list-models subcommand, but the CLI maintains
// $CODEX_HOME\models_cache.json — the model catalog VALID FOR THE LOGGED
// ACCOUNT (the CLI itself fetches/refreshes it for its /model picker), so
// reading it needs no process spawn and reflects the user's actual plan.
// The cache is NOT a stable API: any parse failure yields [] and the caller
// keeps its seeded list.
// Parses the raw cache JSON: models[] entries with visibility 'list' (or no
// visibility field), ordered by ascending priority. Pure — unit-testable.
function ParseCodexModelsCache(const AJson: string): TArray<string>;
// Reads $CODEX_HOME\models_cache.json (else %USERPROFILE%\.codex\...).
// [] when absent, unreadable or malformed.
function LoadCodexCachedModels: TArray<string>;

// Normalises a typed/labelled model to its canonical Codex slug so the CLI never
// receives a mixed-case id it would reject ("GPT-5.5" -> "gpt-5.5"). Strips any
// trailing " (annotation)" first (shared sanitiser), then maps a case-insensitive
// match against the known catalog to its canonical lowercase form; an unrecognised
// (off-list / future) slug passes through verbatim (BR-3). Pure — unit-testable.
function NormalizeCodexModel(const AModel: string): string;

implementation

uses
{$IFDEF FPC}
  // FPC 3.2.2 has neither System.IOUtils nor System.JSON; the shims present the
  // same API shape (see Aefos.Provider.Claude for why this stays IFDEF'd).
  SysUtils,
  Classes,
  Aefos.Compat.IO,
  Aefos.Compat.Json,
{$ELSE}
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.JSON,
{$ENDIF}
  Aefos.Provider.Base;

const
  // Canonical Codex model slugs (lowercase), proven live 2026-07-14 against a
  // ChatGPT-account backend: gpt-5.5 (the CLI default), gpt-5.4 and gpt-5.4-mini
  // all answer; the -codex / -codex-mini variants ARE valid slugs (API-key accounts)
  // but the ChatGPT backend rejects them, so they stay in the normalisation
  // catalog (case-fold a typed label) without being SEEDED. Off-list slugs pass
  // through NormalizeCodexModel untouched.
  CCodexCanonicalSlugs: array[0..4] of string = (
    'gpt-5.5', 'gpt-5.5-codex', 'gpt-5.5-codex-mini', 'gpt-5.4', 'gpt-5.4-mini');

function NormalizeCodexModel(const AModel: string): string;
var
  LSlug: string;
  LIndex: Integer;
begin
  LSlug := Aefos.Provider.Base.SanitizeModelForCli(AModel);
  for LIndex := Low(CCodexCanonicalSlugs) to High(CCodexCanonicalSlugs) do
    if SameText(LSlug, CCodexCanonicalSlugs[LIndex]) then
      Exit(CCodexCanonicalSlugs[LIndex]);
  Result := LSlug;
end;

function ParseCodexModelsCache(const AJson: string): TArray<string>;
var
  LRoot: TJSONValue;
  LModels: TJSONValue;
  LItem: TJSONValue;
  LSlugVal, LVisVal, LPrioVal: TJSONValue;
  LSlug, LVis: string;
  LPrio: Double;
  LPrios: TArray<Double>;
  LIndex, LInsert: Integer;
begin
  SetLength(Result, 0);
  SetLength(LPrios, 0);
  LRoot := TJSONObject.ParseJSONValue(AJson);
  try
    if not (LRoot is TJSONObject) then
      Exit;
    LModels := (LRoot as TJSONObject).GetValue('models');
    if not (LModels is TJSONArray) then
      Exit;
    for LItem in TJSONArray(LModels) do
    begin
      if not (LItem is TJSONObject) then
        Continue;
      LSlugVal := (LItem as TJSONObject).GetValue('slug');
      if not (LSlugVal is TJSONString) then
        Continue;
      LSlug := Trim(TJSONString(LSlugVal).Value);
      if LSlug = '' then
        Continue;
      // visibility 'hide' entries are internal (e.g. codex-auto-review) —
      // only 'list' (or an absent field, for older cache layouts) is offered.
      LVisVal := (LItem as TJSONObject).GetValue('visibility');
      LVis := 'list';
      if LVisVal is TJSONString then
        LVis := (LVisVal as TJSONString).Value;
      if not SameText(LVis, 'list') then
        Continue;
      LPrio := MaxInt;
      LPrioVal := (LItem as TJSONObject).GetValue('priority');
      if LPrioVal is TJSONNumber then
        LPrio := (LPrioVal as TJSONNumber).AsDouble;
      // Insertion sort by ascending priority (the catalog ranks its
      // recommended model first); the arrays are tiny.
      LInsert := Length(Result);
      for LIndex := 0 to High(Result) do
        if LPrio < LPrios[LIndex] then
        begin
          LInsert := LIndex;
          Break;
        end;
      SetLength(Result, Length(Result) + 1);
      SetLength(LPrios, Length(LPrios) + 1);
      for LIndex := High(Result) downto LInsert + 1 do
      begin
        Result[LIndex] := Result[LIndex - 1];
        LPrios[LIndex] := LPrios[LIndex - 1];
      end;
      Result[LInsert] := LSlug;
      LPrios[LInsert] := LPrio;
    end;
  finally
    LRoot.Free;
  end;
end;

function LoadCodexCachedModels: TArray<string>;
var
  LBase, LPath: string;
begin
  SetLength(Result, 0);
  LBase := GetEnvironmentVariable('CODEX_HOME');
  if LBase = '' then
    LBase := TPath.Combine(GetEnvironmentVariable('USERPROFILE'), '.codex');
  LPath := TPath.Combine(LBase, 'models_cache.json');
  if not TFile.Exists(LPath) then
    Exit;
  try
    Result := ParseCodexModelsCache(TFile.ReadAllText(LPath, TEncoding.UTF8));
  except
    SetLength(Result, 0); // unreadable/locked file = no discovery, seeds stay
  end;
end;

constructor TCodexExecutorProfile.Create(const AMcpSupport: TMcpSupport);
begin
  inherited Create;
  FMcpSupport := AMcpSupport;
end;

function TCodexExecutorProfile.Kind: TExecutorKind;
begin
  Result := ekCodex;
end;

function TCodexExecutorProfile.BinaryName: string;
begin
  // Extension-less (ADR-077): the resolver ladder finds codex.exe/.cmd/.bat.
  Result := 'codex';
end;

function TCodexExecutorProfile.ReplicationTargetRel: string;
begin
  Result := '.codex\prompts';
end;

function TCodexExecutorProfile.McpSupport: TMcpSupport;
begin
  // Injected at construction by the live probe (ADR-078); never mutated.
  Result := FMcpSupport;
end;

function TCodexExecutorProfile.BuildMcpConfigJson(const ARelayExePath,
  APipeName: string): string;
begin
  // Codex MCP is injected via `-c mcp_servers.*` TOML overrides in the
  // dispatcher, not a config file. BR-7: never reached on a supported path.
  raise EExecutorProfileError.Create(
    'Codex executor does not support MCP configuration');
end;

function TCodexExecutorProfile.BuildModelArgs(
  const AModel: string): TArray<string>;
begin
  // Normalise a typed label ("GPT-5.5") to its canonical slug so the ChatGPT
  // backend never rejects a mixed-case id (Base then strips annotations + trims).
  Result := Aefos.Provider.Base.BuildModelArgs(NormalizeCodexModel(AModel));
end;

function TCodexExecutorProfile.CliNotFoundHint: string;
begin
  // Vendor-neutral (no CLI name in user-facing text — Aefos references no vendor).
  Result := 'Open Tools > Options > Aefos > AI Chat to set the Executor path, or put your AI CLI on PATH.';
end;

function TCodexExecutorProfile.CommandReplicaRelPath(
  const ACommandName: string): string;
begin
  // ADR-080: a Codex custom prompt is a flat `<name>.md` file — no
  // per-command subdirectory. The file stem is the `/name` invocation token.
  Result := ACommandName + '.md';
end;

function TCodexExecutorProfile.RequiresCommandConversion: Boolean;
begin
  // The canonical COMMAND.md carries YAML frontmatter Codex cannot consume.
  Result := True;
end;

function TCodexExecutorProfile.ConvertCommand(
  const ACanonicalContent: string): string;
begin
  Result := Aefos.Provider.Base.StripFrontmatter(ACanonicalContent);
end;

function TCodexExecutorProfile.ReferenceReplicaRelPath(const ACommandName,
  AReferenceName: string): string;
begin
  Result := Aefos.Provider.Base.ReferenceReplicaRelPath(ACommandName,
    AReferenceName);
end;

function TCodexExecutorProfile.ResolveReplicationRoot(
  const AProjectRoot: string): string;
begin
  // ADR-237/238: global root — Codex discovers prompts from a single
  // system-wide directory; the project root is irrelevant for Codex.
  Result := Aefos.Provider.Base.ResolveCodexPromptsRoot;
end;

function TCodexExecutorProfile.BuildDispatchArgs(
  const ACtx: TProviderDispatchContext): TArray<string>;
var
  LBridge: string;
  LServer: string;
  LResuming: Boolean;
begin
  // Non-interactive ONLY via `exec`; --skip-git-repo-check to run outside a repo.
  // The subcommand must come first.
  //   NOTE on the array-constructor spelling used throughout this method: FPC
  // 3.2.2's generics parser chokes on `TArray<string>.Create(` when it follows a
  // `+` (it reads the `<` as a comparison), so every one of these is written as
  // a dynamic-array constructor `[...]` instead -- the same values, and a form
  // both compilers parse everywhere.
  //   Conversation continuity (ssCaptured). Codex will NOT let us pin the id --
  // it mints its own and prints it as `session id: <uuid>` in the run header --
  // so turn 1 is a plain `exec` and every later turn is `exec resume <id>`, with
  // the id scraped by TryCaptureSessionId below. The id is STABLE: a resumed run
  // reprints the same one (proven live 2026-08-03), so it is captured once and
  // reused for the whole conversation.
  LResuming := ACtx.SessionStarted and (ACtx.SessionId <> '');
  if LResuming then
    Result := ['exec', 'resume', ACtx.SessionId, '--skip-git-repo-check']
  else
    Result := ['exec', '--skip-git-repo-check'];
  Result := Result + BuildModelArgs(ACtx.Model);
  // Reasoning effort (Codex-only capability): a `-c model_reasoning_effort="<x>"`
  // TOML override. '' = Default (the CLI's own effort → no flag). Proven live
  // 2026-07-14: the session header then prints "reasoning effort: <x>". The token
  // is a fixed lowercase word (low|medium|high|xhigh) so it needs no escaping.
  if ACtx.ReasoningEffort <> '' then
    Result := Result + ['-c', 'model_reasoning_effort="'
      + ACtx.ReasoningEffort + '"'];
  // Agent: inject the aefos MCP via per-invocation -c TOML overrides (no config
  // file). Backslashes are doubled for TOML; BuildCommandLine then escapes the
  // embedded quotes for CreateProcess. The prompt follows positionally.
  if ACtx.AgentMode then
  begin
    // Sandbox lift for MCP (field bug 2026-07-15, proven headless). `codex exec`
    // HARD-FORCES `approval: never` — `-c approval_policy=...` (on-request/untrusted)
    // is silently ignored — and clamps `workspace-write` back down to `read-only`.
    // Under read-only + never, Codex classifies an MCP tool invocation as an action
    // it cannot contain in the sandbox, so it AUTO-DENIES it and the tool returns
    // "user cancelled MCP tool call" (never touched by the user). The only sandbox
    // that `exec` lets through and that permits the MCP call to run is
    // `danger-full-access`. This is the FINE lever: it moves ONLY the sandbox (the
    // approval machinery is untouched — still `never`, so no interactive prompts),
    // unlike `--dangerously-bypass-approvals-and-sandbox` which also bypasses hook
    // trust. Security stays with the Aefos MCP guards (RULE #1 / consent), which is
    // where it belongs for a harness — the CLI sandbox never was the boundary. Scoped
    // to AgentMode only: plain chat (no MCP wired) keeps the safe read-only default.
    //   The lift has TWO spellings because the subcommands disagree: `exec`
    // takes --sandbox, but `exec resume` does NOT expose it at all (checked
    // against its own --help: only the far blunter
    // --dangerously-bypass-approvals-and-sandbox is there, and that one also
    // bypasses hook trust, which we deliberately keep). The equivalent -c TOML
    // override IS accepted on resume and is HONOURED -- proven by the run
    // header echoing `sandbox: workspace-write` instead of the default
    // `read-only` when probed with that value. So resume gets the -c form and
    // Agent mode keeps working past turn 1 instead of silently losing its MCP.
    if LResuming then
      Result := Result + ['-c', 'sandbox_mode="danger-full-access"']
    else
      Result := Result + ['--sandbox', 'danger-full-access'];
    LBridge := StringReplace(ACtx.McpBridgePath, '\', '\\', [rfReplaceAll]);
    // The server KEY the CLI namespaces the tools under (mcp_servers.<name>): the
    // executor's chosen name, or 'aefos' by default (the RAD Studio path). The
    // Lazarus edition passes 'aefos-lazarus' so a client with BOTH IDEs open can
    // route a tool to the right host (hyphen is a valid TOML bare-key char).
    LServer := Aefos.Provider.Base.ResolveMcpServerName(ACtx.McpServerName);
    // -ExecutionPolicy Bypass: the default client-Windows policy (Restricted)
    // refuses `-File` scripts, so without it the bridge dies at spawn and the
    // CLI reports "handshaking with MCP server failed: connection closed"
    // (field report 2026-07-08).
    Result := Result + [
      '-c', 'mcp_servers.' + LServer + '.command="powershell"',
      '-c', 'mcp_servers.' + LServer + '.args=["-ExecutionPolicy","Bypass",' +
            '"-NonInteractive","-File","' + LBridge +
            '","-Session","' + ACtx.McpSession + '"]'];
  end;
end;

function TCodexExecutorProfile.SessionSupport: TSessionSupport;
begin
  Result := ssCaptured;
end;

function TCodexExecutorProfile.TryCaptureSessionId(const AOutput: UnicodeString;
  out ASessionId: UnicodeString): Boolean;
begin
  // The run header line is `session id: 019fc959-ba88-7ce2-9bf7-00f399db3093`.
  // Scraped from the PLAIN output on purpose -- switching the dispatch to
  // --json would hand us the id in a `thread.started` event but would also turn
  // every rendered answer into JSONL, a far bigger blast radius for the same
  // string. The chat's output filter only strips ANSI escapes (CLIDispatcher),
  // so the header survives to the accumulated text either way.
  Result := TCliSessionScraper.TryIdAfterMarker(AOutput, 'session id: ',
    ASessionId);
end;

end.
