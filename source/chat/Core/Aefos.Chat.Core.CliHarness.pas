unit Aefos.Chat.Core.CliHarness;

{$IFDEF FPC}{$mode delphiunicode}{$H+}{$ENDIF}

{
  THE single, CLI-agnostic dispatch harness shared by BOTH editions.

  This unit is the ONE OWNER of the rule the owner mandated (2026-07-20): "o
  harness TEM que atender a TODOS os CLIs, regra UNICA e CENTRALIZADA, TANTO
  Delphi quanto Lazarus". Before this unit existed the orchestration was
  DUPLICATED -- TCommandExecutor (RAD Studio) and TAefosLazChatController
  (Lazarus) each carried their own copy of "assemble the final prompt" and
  "build the TDispatchRequest", and the copies had already DRIFTED (the Lazarus
  preamble had lost PACING, the Chat-mode text and the memory block). Both
  editions now DELEGATE here; neither keeps a private copy of the rule.

    TAefosCliHarness.AssembleFinalPrompt  -- the ONLY source of the final prompt
      (agent/chat preamble + "memory" standing instructions + rendered project
      context + command body + user selection). Ported VERBATIM from the RAD
      Studio TCommandExecutor._AssembleFinalPrompt, which is the canonical text.

    TAefosCliHarness.BuildDispatchRequest -- the ONLY source of the dispatch
      request assembly (model/agent/endpoint/effort context -> the driver's
      per-CLI flags via IExecutorProfile.BuildDispatchArgs, plus working dir,
      API-key env override, session tag, timeout and output filter).

    TAefosCliHarness.AgentPreamble / ChatModePreamble -- the SAME preamble text
      exposed for the in-process local-model loop (Aefos.Lazarus.ChatAgent and
      the AefosAgent CLI), so the THREE agentic paths (RAD Studio CLI, Lazarus
      CLI, Ollama loop) share ONE text with no possible drift.

  Everything genuinely per-edition (OTA project context vs none; the RAD Studio
  bridge/global-config MCP wiring vs the Lazarus in-process host; the model-
  fallback suppression vs _ResolveCurrentModel; the session STATE) is injected
  through IAefosCliHarnessInputs, which each edition implements over ITS OWN
  collaborators. The RULE stays here; only the plumbing differs.

  Purity: no ToolsAPI, no Vcl.*/LCL, no I/O and no JSON -- so it compiles in
  delphiunicode mode on FPC exactly as it does on Delphi, and is the SAME
  compiled unit reachable from the RAD Studio package AND the Lazarus package.
  The interface members are declared with an EXPLICIT UnicodeString so the
  delphi-mode Lazarus controller (string = UTF-8 AnsiString) can implement
  the seam unambiguously -- the boundary discipline the ChatAgent seam already
  uses. All literals are ASCII: this file needs no BOM.
}

interface

uses
  {$IFDEF FPC}
  SysUtils,
  Generics.Collections,
  {$ELSE}
  System.SysUtils,
  System.Generics.Collections,
  {$ENDIF}
  Aefos.Provider.Types,
  Aefos.OTA.Chat.Core.Dispatcher.Types,
  Aefos.OTA.Chat.Core.Config.Types;

type
  { The IDE-specific NOUNS the shared preamble TEMPLATE needs. The rule (use the
    Aefos MCP first, act-first pacing, never bulk-write a form file) is identical
    in both editions -- only these nouns differ, so they are the injected platform
    seam (owner's general law, 2026-07-20): one text, per-edition nouns. Built by
    RadStudioVocabulary / LazarusVocabulary below; an edition never hand-writes the
    preamble. }
  TAefosIdeVocabulary = record
    IdeName: string;      // 'RAD Studio (Delphi)' | 'Lazarus'
    ProjectKind: string;  // 'Delphi' | 'Lazarus' (the "this <X> project" adjective)
    FormFileNoun: string; // '.dfm (SetDFMContent)' | '.lfm' (Lazarus has no such tool)
    DesyncGuard: string;  // 'pas-dfm-desync' | 'pas-lfm-desync'
  end;

  { The per-dispatch MCP wiring an edition resolves and the harness copies onto
    TProviderDispatchContext. It mirrors the MCP fields of that record, plus
    AgentToolingActive (== ctx.AgentMode): the RAD Studio edition always fills
    the wiring and sets AgentToolingActive to the header toggle (the driver
    gates its own flags on it); the Lazarus edition sets it True only when its
    in-process MCP host actually started. }
  TAefosCliMcpWiring = record
    AgentToolingActive: Boolean;
    // The user's tool-permission choice, resolved by the edition (RAD reads the
    // AI Flow page; Lazarus its own settings) and copied onto the dispatch
    // context. It rides here rather than on TConfig so the shared config file
    // keeps ONE writer per key -- the Options page -- and this unit keeps no
    // dependency on the OTA package.
    AllowNativeTools: Boolean;
    McpConfigPath: string;
    McpBridgePath: string;
    McpSession: string;
    McpServerName: string;
    ExtraMcpNames: TArray<string>;
  end;

  { Everything the harness needs that is edition-specific. The RAD Studio
    edition implements it over its OTA collaborators (ProjectContextBuilder /
    CommandRegistry / TMCPProvision / TChatGlobalSettings); the Lazarus edition
    over the user text + Aefos.Lazarus.McpAddonMerge + the in-process host. Every
    string member is an EXPLICIT UnicodeString so a delphi-mode implementor
    binds the seam without an AnsiString mismatch. }
  IAefosCliHarnessInputs = interface
    ['{7C4A9E13-2B86-4D5F-9A0E-6F1C8B3D7A24}']
    // --- final-prompt assembly ---
    // The header Chat|Agent toggle, already resolved to its EFFECTIVE value
    // (the Lazarus edition returns True only when its tool host is reachable).
    function AgentMode: Boolean;
    // The IDE-specific nouns for the shared preamble template (RadStudioVocabulary
    // for the RAD Studio edition, LazarusVocabulary for Lazarus) -- so the ONE text
    // never lies about the IDE name or form-file extension it is running in.
    function Vocabulary: TAefosIdeVocabulary;
    // The global "memory" standing instructions ('' when none). Both editions
    // read the SAME %APPDATA%\Aefos\memory.md; the source is injected so a test
    // can point it elsewhere.
    function MemoryText: UnicodeString;
    // The rendered "## Project context" block ('' when the edition has no OTA
    // project context -- the honest floor for Lazarus).
    function RenderedContext: UnicodeString;
    // The command/prompt body (RAD Studio: registry body or built-in guide;
    // Lazarus: the expanded stored command or the raw user text).
    function CommandBody: UnicodeString;
    // The editor selection ('' when there is none).
    function Selection: UnicodeString;
    // --- dispatch-request assembly ---
    // The spawned CLI's working directory ('' inherits the IDE cwd).
    function WorkingDirectory: UnicodeString;
    // The model to send, already resolved ('' => the driver emits no --model:
    // RAD Studio returns '' under model-fallback suppression, Lazarus returns
    // the header selector's current model).
    function DispatchModel: UnicodeString;
    // Resolves + provisions the MCP wiring for this dispatch. SIDE-EFFECTING per
    // edition (writes the merged global config / the Gemini settings / starts
    // the host). AProfileKind lets the impl perform the Gemini file side effect.
    procedure ResolveMcpWiring(const AProfileKind: TExecutorKind;
      var AWiring: TAefosCliMcpWiring);
    // Conversation continuity, consulted per the profile's TSessionSupport. The
    // edition owns the STATE: EnsureSessionId generates + persists the id on the
    // first turn and returns it; SessionStarted reports new(False)/resume(True).
    // For an ssCaptured driver EnsureSessionId is called ONLY after the executor
    // stored a CLI-minted id, so it returns that id and never mints one.
    // The harness does NOT mark the session started -- each edition does that at
    // its own timing (RAD Studio at build time, Lazarus after a successful spawn).
    function EnsureSessionId: UnicodeString;
    function SessionStarted: Boolean;
    // The conversation id to STATE IN THE PROMPT, or '' when there genuinely is
    // not one yet. Separate from EnsureSessionId because the two answer
    // different questions: EnsureSessionId is asked while building the CLI args
    // and may MINT one; this is asked while writing the prompt and must never
    // invent an id the CLI has not agreed to. For a pinned driver the edition
    // returns the (idempotently minted) id, which is the same one the args will
    // carry moments later; for a captured driver it returns '' until a run has
    // actually minted one -- "not assigned yet" is the truthful first-turn
    // answer, and a placeholder would be a lie the model would repeat.
    function ConversationId: UnicodeString;
  end;

  { The shared harness. Sealed static namespace (house rule: no loose exported
    routines) -- never instantiated. }
  TAefosCliHarness = class sealed
  public
    // Canonical IDE vocabularies (the injected nouns for the ONE preamble text).
    class function RadStudioVocabulary: TAefosIdeVocabulary; static;
    class function LazarusVocabulary: TAefosIdeVocabulary; static;
    // The aefos-first AGENT preamble: ONE canonical text, the IDE-specific nouns
    // supplied by AVocab. Ends with the '---' separator so the local-model loop can
    // prepend it directly.
    class function AgentPreamble(const AVocab: TAefosIdeVocabulary): string; static;
    // The CHAT-mode preamble (tools declined, point at the Agent toggle).
    class function ChatModePreamble: string; static;
    // The "# This conversation" block: the conversation id (or an honest "not
    // assigned yet") plus the standing fact that this is a CONTINUING exchange.
    // Exposed so a test can assert the text without assembling a whole prompt.
    class function ConversationBlock(const AConversationId: string): string; static;
    // A bare lowercase UUID for --session-id (GUIDToString wraps it in braces).
    // Single source for both editions' session-id generation.
    class function NewSessionId: string; static;
    // THE final prompt: preamble + memory + context + body + selection.
    class function AssembleFinalPrompt(
      const AInputs: IAefosCliHarnessInputs): string; static;
    // THE dispatch request: context -> profile.BuildDispatchArgs + env/session/
    // timeout/filter. APrompt is the AssembleFinalPrompt result (the caller
    // assembles it first, so a retry can re-dispatch the identical prompt).
    class function BuildDispatchRequest(const AInputs: IAefosCliHarnessInputs;
      const AConfig: TConfig; const AProfile: IExecutorProfile;
      const AExecutorPath, APrompt: string): TDispatchRequest; static;
  end;

implementation

uses
  Aefos.Provider.Registry,
  // Pure per-executor capability/effort/apikey helpers (no ToolsAPI, no Vcl --
  // the RAD Studio executor and the Lazarus controller both already consume
  // these), and the shared per-executor model/effort store (models.json).
  Aefos.OTA.Chat.UI.Options.Binding,
  Aefos.Executor.Models;

{ TAefosCliHarness }

class function TAefosCliHarness.RadStudioVocabulary: TAefosIdeVocabulary;
begin
  Result.IdeName := 'RAD Studio (Delphi)';
  Result.ProjectKind := 'Delphi';
  Result.FormFileNoun := '.dfm (SetDFMContent)';
  Result.DesyncGuard := 'pas-dfm-desync';
end;

class function TAefosCliHarness.LazarusVocabulary: TAefosIdeVocabulary;
begin
  // Lazarus is NOT RAD Studio and its form file is .lfm; it has no SetDFMContent
  // tool (the .lfm is designer-only, SetEditorFullContent writes the .pas), so the
  // "never bulk-write" clause names the .lfm alone. Getting these nouns wrong tells
  // the Lazarus model to use a Delphi tool that does not exist -- the whole reason
  // the preamble is parameterized rather than a verbatim RAD Studio copy.
  Result.IdeName := 'Lazarus';
  Result.ProjectKind := 'Lazarus';
  Result.FormFileNoun := '.lfm';
  Result.DesyncGuard := 'pas-lfm-desync';
end;

class function TAefosCliHarness.AgentPreamble(
  const AVocab: TAefosIdeVocabulary): string;
begin
  // Agent mode: lead EVERY prompt with the aefos-first directive. Weaker models
  // don't reach for the MCP on their own (they default to shell / raw file edits
  // because they aren't trained to), so the contract must live in the prompt, not
  // in the model. Prepended BEFORE the user's standing instructions so it frames
  // everything. CLI-agnostic plain text; ASCII-only to dodge the .pas UTF-8/BOM
  // mojibake trap (the model still replies with proper accents). ONE text: the
  // IDE-specific nouns come from AVocab so it never lies about which IDE it runs in.
  Result :=
    '# IDE tools: ALWAYS use the Aefos IDE MCP first' + sLineBreak + sLineBreak +
    'You are running INSIDE the ' + AVocab.IdeName + ' IDE. The Aefos IDE MCP server ' +
    'is connected to the LIVE IDE and exposes tools to read and change THIS ' +
    'project: code (units, methods, uses), design (forms, components, ' +
    'properties, event handlers), project/group structure, build, run/debug, ' +
    'git and search. For ANYTHING that touches this ' + AVocab.ProjectKind + ' project''s code or ' +
    'design, you MUST use the Aefos IDE MCP tools FIRST. Before acting, confirm ' +
    'they are reachable (make a quick read, e.g. GetActiveProject / ' +
    'GetIDEVersion); if they are not reachable, say so plainly instead of guessing ' +
    'or working around it. Only fall back to generic means (shell, raw file ' +
    'edits, web) for a capability the Aefos tools do NOT provide. Do NOT use ' +
    'ad-hoc file/terminal tools when an Aefos tool exists for the job -- use ' +
    'the Aefos tools to open the form designer, set a property, insert a method, add an ' +
    'event handler, build, or run, rather than editing files or shelling out ' +
    'blindly.' + sLineBreak + sLineBreak +
    // PACING: the user watches the IDE, not the chat. Long silent planning reads
    // as a hang (proven live: a screenshot-driven build stalled for minutes before
    // the first tool call). Same act-first rule the live-test feedback demanded.
    'PACING: act, do not deliberate. Something must appear in the IDE within ' +
    'your first few steps -- the user is watching the Form Designer, not your ' +
    'reasoning. When the user gives a screenshot/mockup to build: do NOT plan ' +
    'the whole app first. Create the project, then AddComponent the visible ' +
    'controls one by one (containers first, top to bottom), then set the ' +
    'properties you can actually see, then wire events -- refining ' +
    'iteratively beats planning silently. NEVER bulk-write a whole ' + AVocab.FormFileNoun + ' ' +
    'or a whole .pas (SetEditorFullContent) to build a form: ' +
    'the ' + AVocab.DesyncGuard + ' guard refuses it and the Designer flow is faster.' +
    sLineBreak + sLineBreak + '---' + sLineBreak + sLineBreak;
end;

class function TAefosCliHarness.ChatModePreamble: string;
begin
  // Chat|Agent gate. In Chat mode the IDE tools are also disabled at the CLI
  // (--disallowedTools); this instruction makes the model decline IDE ACTIONS
  // gracefully and point the user at the Agent toggle, rather than a blunt
  // "I can't". CLI-agnostic (plain text, any CLI). ASCII-only on purpose to dodge
  // the .pas UTF-8/BOM mojibake trap; the model still replies with proper accents.
  Result :=
    '# Current mode: Chat (conversation + reading)' + sLineBreak + sLineBreak +
    'You are in Chat mode. You CAN READ files and images that the user ' +
    'attaches or asks you to look at (use Read/Glob/Grep normally) and answer ' +
    'about the code. What you do NOT do in Chat mode is EXECUTE ACTIONS in the IDE: ' +
    'editing/creating files, building, running, or using the tools that CHANGE the ' +
    'project. If the user asks for one of those ACTIONS, do NOT try and do NOT promise to do it: ' +
    'reply briefly and in a friendly way, in the user''s own language, that this ' +
    'requires Agent mode and ask them to click the "Agent" button at the top of the chat.' +
    sLineBreak + sLineBreak + '---' + sLineBreak + sLineBreak;
end;

class function TAefosCliHarness.NewSessionId: string;
var
  LGuid: TGUID;
  LText: string;
begin
  // The CLI wants a BARE lowercase UUID; GUIDToString wraps it in braces
  // ({8-4-4-4-12}). Uses CreateGUID/GUIDToString (both Delphi and FPC) rather
  // than TGUID.NewGuid so the routine is portable.
  CreateGUID(LGuid);
  LText := LowerCase(GUIDToString(LGuid));
  Result := Copy(LText, 2, Length(LText) - 2);
end;

class function TAefosCliHarness.ConversationBlock(
  const AConversationId: string): string;
begin
  // Session self-awareness. Without this the model is running blind inside its
  // own conversation: asked "what did I say earlier" or "do you have this
  // conversation's id" it can only guess, which is exactly what the owner hit
  // (2026-08-03). The id half was unanswerable BY CONSTRUCTION -- nothing in the
  // prompt ever carried it.
  //   Deliberately NOT stating a turn number: the model can count its own turns
  // now that the history actually reaches it, and a counter would be one more
  // piece of state to keep honest across resume.
  //   ASCII-only, like the preambles, to dodge the .pas UTF-8/BOM mojibake trap.
  Result := '# This conversation' + sLineBreak + sLineBreak;
  if AConversationId <> '' then
    Result := Result + 'Conversation id: ' + AConversationId + sLineBreak
  else
    // Honest, and specific about WHY -- a bare "unknown" would read as a defect.
    Result := Result +
      'Conversation id: not assigned yet (this is the first turn of this ' +
      'conversation; the CLI assigns the id when the turn starts).' + sLineBreak;
  Result := Result + sLineBreak +
    'This is a CONTINUING conversation, not a one-shot prompt: the earlier ' +
    'turns are in your context. If the user asks what was said before, read ' +
    'your own history and answer from it -- do NOT claim you have no access ' +
    'to it. If something genuinely is not in your context, say precisely that ' +
    'rather than that the conversation does not exist.' +
    sLineBreak + sLineBreak + '---' + sLineBreak + sLineBreak;
end;

class function TAefosCliHarness.AssembleFinalPrompt(
  const AInputs: IAefosCliHarnessInputs): string;
var
  LMemory: string;
begin
  // CLI-agnostic "memory": the user's global standing instructions are prepended
  // to EVERY prompt (works regardless of which CLI runs -- unlike CLAUDE.md, which
  // only Claude Code reads). The source file is injected via AInputs.MemoryText.
  if AInputs.AgentMode then
    Result := AgentPreamble(AInputs.Vocabulary)
  else
    Result := ChatModePreamble;
  // Straight after the mode preamble and BEFORE the user's standing
  // instructions: it frames what this exchange IS, which the rest depends on.
  Result := Result + ConversationBlock(AInputs.ConversationId);
  LMemory := AInputs.MemoryText;
  if LMemory <> '' then
    Result := Result +
      '# Standing instructions (always apply)' + sLineBreak + sLineBreak +
      LMemory +
      sLineBreak + sLineBreak + '---' + sLineBreak + sLineBreak;
  Result := Result +
    AInputs.RenderedContext +
    sLineBreak + sLineBreak + '---' + sLineBreak + sLineBreak +
    AInputs.CommandBody +
    sLineBreak + sLineBreak + '## User selection' + sLineBreak + sLineBreak +
    '```' + sLineBreak + AInputs.Selection + sLineBreak + '```';
end;

class function TAefosCliHarness.BuildDispatchRequest(
  const AInputs: IAefosCliHarnessInputs; const AConfig: TConfig;
  const AProfile: IExecutorProfile;
  const AExecutorPath, APrompt: string): TDispatchRequest;
var
  LCtx: TProviderDispatchContext;
  LWiring: TAefosCliMcpWiring;
  LKeyVar: string;
  LKey: string;
begin
  Result := Default(TDispatchRequest);
  Result.ExecutorPath := AExecutorPath;
  Result.Prompt := APrompt;
  // Run the CLI IN the edition's chosen working directory (RAD Studio: the
  // active project's folder; Lazarus: '' = inherit the IDE cwd).
  Result.WorkingDirectory := AInputs.WorkingDirectory;
  SetLength(Result.EnvOverrides, 0);
  // Inject the per-executor API key (e.g. Gemini's GEMINI_API_KEY) so the spawned
  // CLI authenticates without a system env var or IDE restart -- sourced from the
  // shared apikeys.json. Only providers that auth by key name an env var.
  LKeyVar := TExecutorApiKeys.ApiKeyEnvVarFor(AConfig.Executor);
  if LKeyVar <> '' then
  begin
    LKey := TExecutorApiKeys.ApiKeyForKind(AConfig.Executor);
    if LKey <> '' then
      Result.EnvOverrides := Result.EnvOverrides +
        [TPair<string, string>.Create(LKeyVar, LKey)];
  end;
  // --- provider dispatch context (was TCommandExecutor._BuildArgsFromConfig /
  // TAefosLazChatController._BuildDispatchContext) --------------------------
  // Profile-driven dispatch: each provider driver owns its per-CLI flag dialect
  // (subcommand, MCP, tool-auth, session). The harness only assembles the context
  // and delegates -- no executor-named branch here.
  LCtx := Default(TProviderDispatchContext);
  // The header model selector overrides the persisted Config.Model; under model-
  // fallback suppression the edition returns '' so the CLI runs on its own default.
  LCtx.Model := AInputs.DispatchModel;
  // Local-model endpoint (ekOllama): the base URL the Agent CLI streams to via
  // --endpoint. Empty for CLI executors, which ignore it.
  LCtx.Endpoint := AConfig.OllamaBaseUrl;
  // Reasoning effort (executors that expose one -- Codex today): the per-executor
  // persisted CLI token, round-tripped through the vocabulary so a hand-edited
  // models.json can never leak an arbitrary string into the -c TOML override
  // (unknown => Default => the driver emits no flag). Read from the SHARED store
  // (the same models.json both Options pages write), so both editions resolve it
  // byte-identically.
  if TExecutorCapabilities.SupportsReasoningEffort(AConfig.Executor) then
    LCtx.ReasoningEffort := TReasoningEfforts.CliToken(
      TReasoningEfforts.FromCliToken(
        TExecutorModelStore.SelectedEffortForKind(AConfig.Executor)));
  // MCP wiring: the ONE per-edition side-effecting step (merge the user's extra
  // servers + installed addons, provision the global config / Gemini settings,
  // and -- Lazarus -- start the in-process host). The driver gates its MCP/tool
  // flags on ctx.AgentMode (== AgentToolingActive).
  LWiring := Default(TAefosCliMcpWiring);
  AInputs.ResolveMcpWiring(AProfile.Kind, LWiring);
  LCtx.AgentMode := LWiring.AgentToolingActive;
  LCtx.AllowNativeTools := LWiring.AllowNativeTools;
  LCtx.McpConfigPath := LWiring.McpConfigPath;
  LCtx.McpBridgePath := LWiring.McpBridgePath;
  LCtx.McpSession := LWiring.McpSession;
  LCtx.McpServerName := LWiring.McpServerName;
  LCtx.ExtraMcpNames := LWiring.ExtraMcpNames;
  // Conversation continuity is the edition's STATE; the driver only formats its
  // own dialect of the flag. Keyed off the driver's TSessionSupport, so switching
  // CLIs never resumes a session another CLI started.
  case AProfile.SessionSupport of
    ssPinned:
      begin
        // WE own the id: minted on the first turn, the SAME one handed over on
        // every turn after (SessionStarted picks new-vs-resume for the drivers
        // that spell those differently).
        LCtx.SessionId := AInputs.EnsureSessionId;
        LCtx.SessionStarted := AInputs.SessionStarted;
      end;
    ssCaptured:
      // The CLI owns the id. Until a run has actually MINTED one there is
      // nothing to send -- and EnsureSessionId must NOT be called on that path,
      // because it would invent a uuid the CLI never heard of: fatal for the
      // agent CLI (`--resume <unknown>` Halts with exit 2) and an unknown-session
      // error for Codex. SessionStarted only goes True once the executor
      // captured a REAL id, so reading it here is safe by construction.
      if AInputs.SessionStarted then
      begin
        LCtx.SessionId := AInputs.EnsureSessionId;
        LCtx.SessionStarted := True;
      end;
    ssNone:
      ; // no continuity: the driver ignores the session fields entirely
  end;
  Result.Args := AProfile.BuildDispatchArgs(LCtx);
  // Tags the per-executor session log file (YYYY-MM-DD-<executor>.log).
  Result.Executor := TProviderRegistry.ExecutorKindToString(AConfig.Executor);
  // Persisted runtime settings: seconds -> ms; a non-positive value disables the
  // watchdog.
  if AConfig.TimeoutSeconds > 0 then
    Result.TimeoutMs := Cardinal(AConfig.TimeoutSeconds) * 1000
  else
    Result.TimeoutMs := 0;
  Result.OutputFilter := AConfig.OutputFilter;
end;

end.
