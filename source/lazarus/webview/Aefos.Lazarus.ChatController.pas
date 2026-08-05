unit Aefos.Lazarus.ChatController;

{ TAefosLazChatController -- the LCL render-protocol controller (Lazarus edition).

  The Lazarus twin of the Delphi TOutputPanelEdgeController
  (source/chat/UI/Aefos.OTA.Chat.UI.OutputPanel.EdgeController.pas). It MIRRORS
  that unit's render protocol -- it does not reuse it, because the Delphi one is
  Vcl.*-coupled. It owns:

    * Pascal -> JS: the window.ds*() calls the chat shell exposes
      (dsUser/dsClear/dsAppend/dsFooter for a turn; dsSetMode/dsSetCommands/
      dsReplay/dsResetThread to boot/reset the shell). Every argument is
      JSON-escaped exactly like the Delphi seam (TRenderProtocol.JSEncode).
    * JS -> Pascal: the shell posts 'send:<text>' | 'stop:' | 'busycheck:' |
      'composer:focus' | 'action:<x>' | 'shell-error:<x>' | 'hdr:models' |
      'hdr:model:<id>' via window.chrome.webview.postMessage; HandleHostMessage
      parses them.

  Header model selector: the shell posts 'hdr:models' on load (and on window
  focus) and expects a window.dsModels call back, carrying an object of models /
  current / executor / effort / effortSupported; picking one posts
  'hdr:model:<id>'. The Delphi twins are ChatPanel.HandleHostMessage + Register's
  OnGetModels/OnSetModel. The model LIST and the per-executor PICK both live in
  the SHARED store (Aefos.Executor.Models -> %APPDATA%\Aefos\models.json), the
  same file the RAD Studio Options page writes -- the two IDEs must agree about
  the user's models. (No literal braces in this comment: nested-comment handling
  differs between the package build and a plain project build, and a stray
  closing brace ends the header early in one of them.)

  The chat loop. On a user send-message it resolves the configured executor from
  the SHARED global config (%APPDATA%\Aefos\.aefos\config.json) and takes ONE of
  two paths -- the same two the RAD Studio plugin has:

    * ekOllama (the local model): drives the FPC-ready Ollama transport
      (Aefos.Provider.Ollama) DIRECTLY -- NOT via TOllamaDispatcher, whose
      ICommandExecutor contract is welded to the OTA surface (project-context
      builder, command registry, IOutputPanelSurface).
    * any external CLI (Claude/Codex/Gemini/Copilot): dispatches to the USER'S OWN
      CLI through the SHARED transport -- Aefos.Provider.Registry resolves the
      driver, the driver owns its flag dialect (BuildDispatchArgs), the CLI binary
      comes off the shared resolver ladder, and Aefos.OTA.Chat.Core.CLIDispatcher
      spawns it and streams stdout back. Not a Lazarus fork of any of those: the
      RAD Studio chat runs the very same units, so a flag fix lands on both IDEs
      at once. THAT is the Aefos thesis -- a harness for the user's own AI CLI,
      never a direct LLM client.

  Either way a streamed chunk becomes a dsAppend and the terminal event a
  dsFooter, so the render protocol above does not care which path ran.

  Dispatch is DELEGATED to the SHARED Aefos.Chat.Core.CliHarness (the ONE owner
  of the final-prompt + request-build rule, used by BOTH IDEs) through a
  TAefosLazHarnessInputs adapter: it assembles the aefos-first/Chat preamble +
  the global "memory" + the user's text, and builds the TDispatchRequest via the
  driver. Agent mode (adapter.ResolveMcpWiring): when the header's Chat|Agent
  toggle is on and the in-process MCP host is reachable, an external CLI is handed
  the aefos MCP server + the user's installed addon servers (via
  Aefos.Lazarus.McpAddonMerge), exactly like the RAD Studio edition -- Gemini,
  which has no MCP flag, is also provisioned into ~/.gemini/settings.json. When no
  host is available (standalone proof) the dispatch degrades honestly to
  AgentMode=False (plain conversation). Not sent (this IDE-free controller has no
  OTA project-context builder): the rendered project context and a working
  directory, so those inputs stay ''.

  Threading: both transports stream on a private worker and marshal every event
  to the MAIN thread, so _OnChunk / _OnCliChunk already run on the IDE main
  thread -- safe to call ExecuteScript from them directly. Both are cancelled at
  teardown so no worker (and no spawned child process) outlives the window.

  Mode: delphi (LCL glue, string = UTF-8 AnsiString). The shared cores compile in
  delphiunicode (string = UTF-16): TConfig fields, the Ollama request builder and
  TOllamaChunk are UnicodeString. Every value crossing that boundary is converted
  explicitly through LazUTF8 (UTF8ToUTF16 / UTF16ToUTF8), never the platform ANSI
  codepage -- the WorkspaceFacade/Options twin rule. All literals are ASCII, so
  this file needs no BOM. }

{$mode delphi}
{$H+}

interface

uses
  Classes,
  SysUtils,
  Generics.Collections,   // TPair (TDispatchRequest.EnvOverrides items); TList
  LazUTF8,
  Aefos.Lazarus.WebViewHost,
  // The user-command store (list/load/save the .aefos\commands\<name>\COMMAND.md
  // catalogue) -- referenced by a private method signature, so it must be visible
  // in the interface. Shared byte-compatibly with the RAD Studio plugin (one brain).
  Aefos.Lazarus.CommandRegistry,
  Aefos.Lazarus.SessionStore,
  Aefos.Lazarus.SessionStore.SQLite,   // the default SQLite-backed store (shared aefos.db)
  Aefos.Lazarus.ChatAgent,
  Aefos.Provider.Ollama.Core,
  Aefos.Provider.Ollama,
  Aefos.Provider.Types,
  Aefos.OTA.Chat.Core.Dispatcher.Types,
  Aefos.OTA.Chat.Core.CLIDispatcher,
  Aefos.OTA.Chat.Core.Config.Types;

type
  // Fired (main thread) for every script sent Pascal -> JS. A diagnostic /
  // test-capture seam so the render protocol can be asserted without a DOM.
  TAefosChatScriptEvent = procedure(const AScript: string) of object;
  // Fired (main thread) when a user send-message is accepted for dispatch.
  TAefosChatSendEvent = procedure(const AText: string) of object;
  // Fired (main thread) when the header gear (hdr:settings) is clicked. The chat
  // controller is deliberately IDE-free (the proof harness hosts it), so opening
  // the IDE Options page is delegated to whoever composed the controller -- the
  // chat window wires this to LazarusIDE.DoOpenIDEOptions(TAefosOptionsFrame), the
  // Lazarus twin of the Delphi panel's OnOpenSettings. nil in the test harness.
  TAefosChatOpenSettingsEvent = procedure of object;
  // Fired (main thread) to resolve the ACTIVE project's root folder, for the
  // user-command "This project" scope (.aefos\commands under it). The controller
  // is IDE-free (the proof harness hosts it), so the chat window wires this to
  // LazarusIDE.ActiveProject's directory; nil/'' in the harness means project
  // scope is unavailable and a project-scoped save is rejected with an inline
  // notice (exactly like the Delphi registry's ECommandFolderUnavailable path).
  TAefosChatResolveRootEvent = function: UnicodeString of object;

  TAefosLazChatController = class
  private
    FWeb: TAefosLazWebView;
    FTransport: IOllamaTransport;
    FTestTransport: IOllamaTransport;  // injected by tests; nil in production
    // Liveness token (mirrors the phase-M host): killed at the TOP of Destroy so
    // a chunk marshalled back after this controller is freed becomes a no-op
    // instead of a use-after-free. The Ollama transport stores a bare `of object`
    // sink and does NOT refcount it, so the token is the only safe guard.
    FLive: IAefosLiveToken;
    // The current turn's chunk sink. FSinkHold keeps it alive across Destroy's
    // drain; FSinkObj is a raw view for reading Ended (valid while FSinkHold holds).
    FSinkHold: IInterface;
    FSinkObj: TObject;
    // The header model-list fetch (ekOllama only). A SEPARATE transport from
    // FTransport: a models fetch and a chat stream can be in flight at once and
    // must never alias each other's state. Same sink discipline as the chunk
    // sink above -- FetchModels is async and is NOT cancellable, so the sink +
    // liveness token are the ONLY thing standing between a late /api/tags reply
    // and a use-after-free.
    FModelsTransport: IOllamaTransport;
    FModelsSinkHold: IInterface;
    FModelsSinkObj: TObject;
    // --- External-CLI dispatch state -------------------------------------
    // The shared transport + the in-flight run. FCliDispatcher is created per
    // turn (it is stateless; the run carries the state). FCliRun is what Stop
    // cancels and what teardown terminates -- a spawned child MUST NOT outlive
    // the chat window.
    FCliDispatcher: ICLIDispatcher;
    FTestCliDispatcher: ICLIDispatcher;  // injected by tests; nil in production
    FCliRun: IDispatcherRunHandle;
    FCliSinkHold: IInterface;
    FCliSinkObj: TObject;
    // Conversation continuity: the controller owns the session STATE, the driver
    // only formats its own dialect of the flag. Mirrors TCommandExecutor's
    // FSessionId/FSessionStarted.
    FSessionId: UnicodeString;
    FSessionStarted: Boolean;
    // The driver of the run IN FLIGHT, held only so the terminal callback can ask
    // it to capture a CLI-minted session id. Kept as a field rather than
    // re-resolved from config in _OnCliComplete because the config could have
    // changed under a long turn (Options switches the executor without a
    // restart) -- the id belongs to the driver that actually ran.
    FCliProfile: IExecutorProfile;
    FBusy: Boolean;
    FBooted: Boolean;
    // Send-during-run queue: a message the user sends WHILE a turn is in flight is
    // not dropped -- it is echoed at once and queued here (FIFO), then auto-
    // dispatched as its own turn when the current one settles (Ollama Done/Error,
    // agent done, or CLI complete). Mirrors the Delphi panel's FQueuedMessages
    // (TAefosChatPanel), down to the window.dsQueued counter cue. Survives Stop by
    // design: cancel drives the terminal event, which then drains the queue.
    FQueuedMessages: TStringList;
    // Set at the TOP of Destroy, BEFORE the cancel/drain loops. Those loops pump
    // CheckSynchronize, which can deliver a transport's terminal event while the
    // liveness token is still alive (it is killed only AFTER the drains), firing a
    // settle callback. That callback would otherwise drain the queue and start a
    // BRAND-NEW turn on a controller being torn down. This flag makes the drain a
    // no-op during teardown, so dispatch is never re-entered on a dying controller
    // -- the single riskiest lifetime point of this feature.
    FTearingDown: Boolean;
    // Chat | Agent. Agent = the local-model tool loop may call the IDE tools;
    // Chat = conversation only. Defaults to Agent, mirroring the Delphi panel
    // (TAefosChatPanel.FAgentMode := True). Only the LOCAL-model path can honour
    // it here -- see _DispatchOllama.
    FAgentMode: Boolean;
    // The in-flight agent turn (nil when idle). Refcounted and owned jointly with
    // its worker, so dropping it mid-turn is safe -- see Aefos.Lazarus.ChatAgent.
    FAgentSession: IAefosAgentSession;
    FConfigRoot: UnicodeString;        // config root; defaults to %APPDATA%\Aefos
    // --- Session history (JSON store) ------------------------------------
    // The current conversation, recorded turn by turn so hdr:sessions can list it
    // and a resume can replay it (the Lazarus twin of the Delphi panel's
    // SessionStore + FSessionTitle/FSessionCount, JSON not SQLite). Held as the
    // store's UnicodeString message shape so save/replay never re-convert; the
    // controller only converts the user's UTF-8 text in at record time. The store
    // itself is created on demand against the CURRENT FConfigRoot (a test changes
    // ConfigRoot after construction), so it is never cached.
    FConversation: TList<TAefosSessionMessage>;
    FStoreSessionId: UnicodeString;    // '' until the first user turn of a session
    FSessionTitle: UnicodeString;      // first user message (the list/ctx title)
    FSessionCount: Integer;            // user-message count (the list subtitle)
    FSessionCreated: TDateTime;        // session start (persisted 'created')
    // The assistant text accumulated across the CURRENT turn's chunks; committed
    // to FConversation (and the store) when the turn settles.
    FCurrentAssistant: UnicodeString;
    FOnScript: TAefosChatScriptEvent;
    FOnSend: TAefosChatSendEvent;
    FOnOpenSettings: TAefosChatOpenSettingsEvent;
    // --- User commands (/command editor + registry) ----------------------
    // The active project's root (for the "This project" scope), resolved through
    // this seam so the controller stays IDE-free. FCommandProjectRoot /
    // FCommandGlobalRoot are TEST overrides ('' => the seam / %USERPROFILE%), so a
    // proof never writes into the user's real catalogue.
    FOnResolveProjectRoot: TAefosChatResolveRootEvent;
    FCommandProjectRoot: UnicodeString;
    FCommandGlobalRoot: UnicodeString;
    // Config seam (mirrors the Options page composition).
    function _ResolveConfigRoot: UnicodeString;
    function _LoadConfig: TConfig;
    // Pascal -> JS render protocol.
    procedure _Run(const AScript: string);
    procedure _JsUser(const AText: string);
    procedure _JsClear;
    procedure _JsAppend(const AText: string);
    procedure _JsFooter(const AText: string; const AIsError: Boolean);
    procedure _JsSetMode(const AMode: string);
    // Send-during-run queue counter (window.dsQueued); 0 hides the line.
    procedure _JsQueued(const ACount: Integer);
    // Prefill the composer (window.dsPrefillInput): replace its value + focus.
    procedure _JsPrefill(const AText: string);
    class function _JsEncode(const AInput: string): string; static;
    class function _BuildShell: string; static;
    // Boot the shell once its navigation completes (view mode).
    procedure _OnNav(const ASuccess: Boolean);
    // --- Command surface (header icons + chips + picker + MCP modal) -----
    // Empty-state chip (action:<name>): prefill the composer with the mapped
    // slash command. Mirrors the Delphi panel's action->PrefillInput map.
    procedure _HandleActionChip(const AAction: string);
    // Slash commands the controller handles ITSELF (not sent to the model): the
    // built-ins that map to a UI action here. True when AText was one and was
    // handled (so _DoSend must not dispatch it). Mirrors ChatPanel._DispatchCommand
    // routing the UI-modal built-ins to their bespoke handlers.
    function _TryHandleSlashCommand(const AText: string): Boolean;
    // Feed the slash-command picker (window.dsSetCommands) from the shared
    // Core.BuiltInCommands table -- the SAME single source the Delphi picker reads
    // (_SendPickerCommands). Lazarus has no user-command registry yet, so this is
    // the built-ins alone.
    procedure _HandlePicker;
    // hdr:settings -> delegate to the composed OnOpenSettings (opens IDE Options).
    procedure _HandleOpenSettings;
    // Push the current trial reminder into the header ('' hides it). Answers
    // 'hdr:trial', which the shell posts on load and on every window focus, so
    // the countdown stays honest without a timer on our side.
    procedure _PushTrialBadge;
    // Badge click ('hdr:license'): open the activation screen, then re-push --
    // activating must make the reminder disappear without a restart.
    procedure _HandleLicense;
    // --- User commands (/command) ----------------------------------------
    // A fresh registry bound to this controller's catalogue-root seams. Created
    // per call (never cached), like the Delphi registry which re-reads disk.
    function _NewCommandRegistry: TAefosLazCommandRegistry;
    // Catalogue-root resolvers handed to the registry (`of object`, UTF-8): the
    // active project's root and the per-user global root (%USERPROFILE%). A test
    // override short-circuits each so a proof never touches the real catalogue.
    function _ResolveCommandProjectRoot: string;
    function _ResolveCommandGlobalRoot: string;
    // /command | /prompt: open the HTML command editor on a blank "new" form.
    // Mirrors ChatPanel._OpenCommandEditorNew.
    procedure _OpenCommandEditorNew;
    // command:list -> window.dsSetCommandList: the editable commands (name +
    // description) for the modal's "Edit existing" dropdown. Mirrors _SendCommandList.
    procedure _SendCommandList;
    // command:load:<name> -> window.dsShowCommandEditor prefilled for editing.
    // Mirrors ChatPanel._LoadCommandIntoEditor (isNew=false, canDelete=false).
    procedure _LoadCommandIntoEditor(const AName: string);
    // command:save:<json> -> persist through the registry (the sole writer).
    // Mirrors ChatPanel._SaveCommandFromJson.
    procedure _SaveCommandFromJson(const AJson: string);
    // command:delete:<name> -> mirror the Delphi: the registry exposes no delete
    // (canDelete stays false, so the button is hidden), so this only reports it.
    procedure _NotifyCommandDeleteUnsupported(const AName: string);
    // Expand a stored /name to its prompt body for dispatch, '' when AText is not a
    // bare stored command (args, a built-in, or unknown => sent as raw text).
    // Mirrors TCommandExecutor._PrepareContext's FRegistry.LoadBody step.
    function _ExpandStoredCommand(const AText: string): string;
    // --- Session history --------------------------------------------------
    // The on-demand JSON store, bound to the CURRENT config root every call.
    function _Store: IAefosLazSessionStore;
    // Record the user's turn into the live conversation (title/id/count/created)
    // and push the context line. Resets the per-turn assistant accumulator.
    procedure _RecordUserTurn(const AText: string);
    // Settle the turn: append the accumulated assistant text (if any) and persist.
    procedure _CommitTurn;
    // Persist the live conversation to the store (no-op without an id/turn).
    procedure _SaveSession;
    // Push the context line (window.dsSetSessionInfo) from the tracked title/count.
    procedure _PushSessionInfo;
    // Clear the live conversation + reset the ctx line + shell feed (the empty
    // state). Used by new-session and by deleting the live session.
    procedure _ResetConversation;
    // hdr:newsession: persist the current session, then reset to a fresh one.
    procedure _HandleNewSession;
    // hdr:sessions: persist the current session, list the store, show the panel.
    procedure _HandleOpenSessions;
    // session:resume:<id>: replay a stored session + adopt it as the live one.
    procedure _HandleResumeSession(const AId: string);
    // session:delete:<id>: drop it from the store (reset first if it is live).
    procedure _HandleDeleteSession(const AId: string);
    // --- MCP servers modal ------------------------------------------------
    // The user-editable global MCP config file (%APPDATA%\Aefos\mcp-servers.json),
    // the SAME file the RAD Studio chat's modal reads/writes.
    function _McpConfigPath: UnicodeString;
    // mcp:open: load the config + show the modal (window.dsShowMcp).
    procedure _HandleOpenMcp;
    // mcp:save:<json>: persist the edited config.
    procedure _HandleSaveMcp(const AJson: string);
    // Composer action bar (attach + memory). Localized, self-contained handlers
    // for the paperclip and brain buttons -- mirror the Delphi ChatPanel twins.
    procedure _HandleAttachOpen;
    // paste:image:<base64 PNG> from the shared shell's clipboard-paste handler:
    // decode -> temp .png -> an image attachment chip. Twin of ChatPanel's
    // _SavePastedImage (the RAD Studio edition).
    procedure _HandlePasteImage(const ABase64: string);
    procedure _HandleMemoryOpen;
    procedure _HandleMemorySave(const AText: string);
    // Dispatch.
    procedure _HandleSend(const AText: string);
    // The real send worker. AFromQueue = the drain's re-entry (skip the echo,
    // bypass the busy gate). _HandleSend is the fresh-send front door.
    procedure _DoSend(const AText: string; const AFromQueue: Boolean);
    // Send-during-run queue drain: dispatch the next queued message as its own
    // turn. Called from every terminal/settle event (Ollama Done/Error, agent
    // done, CLI complete). No-op during teardown (FTearingDown).
    procedure _DrainQueuedMessage;
    procedure _DispatchOllama(const AText: string; const AConfig: TConfig);
    // External-CLI dispatch: resolve driver + binary, delegate the request build
    // to the SHARED harness (TAefosCliHarness), spawn, stream.
    procedure _DispatchExternalCli(const AText: string; const AConfig: TConfig);
    // True when the Win32 keyboard focus already sits inside the WebView2 host
    // (the browser parks its Chrome child windows under our Handle). Guards the
    // 'composer:focus' MoveFocus against re-entering itself - see the caller.
    function _FocusInWebView: Boolean;
    procedure _RenderAssistantLine(const AText: string; const AIsError: Boolean);
    // Agent mode (local model only): hands the turn to the in-process tool loop.
    procedure _HandleSetMode(const AAgent: Boolean);
    procedure _DispatchOllamaAgent(const AText: string; const AModel: UnicodeString;
      const AConfig: TConfig);
    procedure _CancelAgentTurn;
    // True when the in-process MCP host can be (idempotently) started -- the
    // precondition for handing an EXTERNAL CLI the aefos tool surface via the
    // bridge. False in the standalone proof harness (no host provider), where the
    // external-CLI turn honestly degrades to a plain conversation.
    function _AgentHostReady: Boolean;
    // Agent-loop sinks. UnicodeString (not this unit's UTF-8 `string`) because
    // the signatures are fixed by TAefosAgentTextEvent/TAefosAgentDoneEvent,
    // declared in the delphiunicode Aefos.Lazarus.ChatAgent -- the same boundary
    // discipline as _OnModels. All three fire on the MAIN thread.
    procedure _OnAgentDelta(const AText: UnicodeString);
    procedure _OnAgentNotice(const AText: UnicodeString);
    procedure _OnAgentDone(const AError: UnicodeString);
    // Stop / teardown: cancels whichever transport is in flight (plain stream,
    // external-CLI child, AND an agent turn -- see the body).
    procedure _CancelInFlight;
    // Header model selector.
    procedure _HandleGetModels;
    procedure _HandleSetModel(const AModel: string);
    procedure _HandleSetEffort(const AEffort: string);
    // The model that IS current for AKind: the per-executor pick from the shared
    // store, falling back to the configured Model when nothing is remembered.
    // Mirrors Register's OnGetModels resolution order.
    function _ResolveCurrentModel(const AKind: TExecutorKind;
      const AConfig: TConfig): UnicodeString;
    procedure _PushModelsJson(const AKind: TExecutorKind;
      const AModels: TArray<UnicodeString>; const ACurrent: UnicodeString);
    // Ollama transport chunk sink (of object; MAIN thread via TThread.Synchronize).
    procedure _OnChunk(const AChunk: TOllamaChunk);
    // Ollama transport models sink (of object; MAIN thread). The signature is
    // fixed by TOllamaModelsEvent, declared in a delphiunicode unit -- hence the
    // explicit UnicodeString, not this unit's UTF-8 `string`.
    procedure _OnModels(const AModels: TArray<UnicodeString>;
      const AError: UnicodeString);
    // External-CLI transport sinks (of object; MAIN thread -- the dispatcher
    // marshals every callback via TThread.Queue). The signatures are fixed by
    // Dispatcher.Types, declared in a delphiunicode unit -- hence the explicit
    // UnicodeString, not this unit's UTF-8 `string`.
    procedure _OnCliChunk(const AChunk: UnicodeString);
    procedure _OnCliError(const AMessage: UnicodeString);
    procedure _OnCliComplete(const AExitCode: Integer;
      const ADurationMs: Cardinal);
  public
    constructor Create(const AWeb: TAefosLazWebView);
    destructor Destroy; override;
    // Wire the host events this controller owns (OnReady/OnNav/OnMessageReceived)
    // and queue the real shell for navigation. OnFailed stays with the caller so
    // the window can surface a runtime-missing caption.
    procedure AttachAndLoad;
    // JS -> Pascal entry (the host's OnMessageReceived is routed here).
    procedure HandleHostMessage(const AMessage: string);
    property Busy: Boolean read FBusy;
    // Config root override (tests point it at a temp dir so the user's real
    // %APPDATA%\Aefos\.aefos\config.json is never touched).
    property ConfigRoot: UnicodeString read FConfigRoot write FConfigRoot;
    // Transport override (tests inject a scripted fake; nil => the real HTTP one).
    property TestTransport: IOllamaTransport
      read FTestTransport write FTestTransport;
    // External-CLI transport override. nil (production) => the real
    // TCLIDispatcher over the real Win32 process runner. A test injects a
    // TCLIDispatcher composed with a fake IProcessRunner, so the whole
    // config -> driver -> args -> spawn -> decode -> render chain runs for real
    // with only the OS spawn faked.
    property TestCliDispatcher: ICLIDispatcher
      read FTestCliDispatcher write FTestCliDispatcher;
    property OnScript: TAefosChatScriptEvent read FOnScript write FOnScript;
    property OnSend: TAefosChatSendEvent read FOnSend write FOnSend;
    // Wired by the chat window to open the IDE Options page (hdr:settings). nil in
    // the test harness -- the gear then no-ops instead of touching an IDE.
    property OnOpenSettings: TAefosChatOpenSettingsEvent
      read FOnOpenSettings write FOnOpenSettings;
    // Wired by the chat window to resolve the active project's folder for the
    // user-command "This project" scope. nil in the test harness (project scope
    // then unavailable -> a project-scoped save is rejected with an inline notice).
    property OnResolveProjectRoot: TAefosChatResolveRootEvent
      read FOnResolveProjectRoot write FOnResolveProjectRoot;
    // Test overrides for the command catalogue roots (a proof points them at a
    // temp dir so it never writes into the user's project or %USERPROFILE%). '' =>
    // use OnResolveProjectRoot / %USERPROFILE% respectively.
    property CommandProjectRoot: UnicodeString
      read FCommandProjectRoot write FCommandProjectRoot;
    property CommandGlobalRoot: UnicodeString
      read FCommandGlobalRoot write FCommandGlobalRoot;
  end;

implementation

uses
  // Windows is needed for the focus-chain walk (GetFocus/GetParent). It also
  // exports a 3-arg GetEnvironmentVariable that would shadow the 1-arg SysUtils
  // one, so that call site below is qualified explicitly.
  Windows,
  Aefos.Compat.IO,
  Aefos.Compat.Json,
  Aefos.Compat.NetEncoding,   // base64 decode for the clipboard-image paste chip
  // Dialogs (LCL) is the composer attach picker's TOpenDialog. It runs on the
  // main thread (a shell button click is already main-thread), so no worker.
  Dialogs,
  Aefos.OTA.Chat.Core.Config,
  Aefos.OTA.Chat.Core.BuiltInCommands,
  Aefos.OTA.Chat.UI.OutputPanel.Assets,
  Aefos.OTA.Chat.UI.Options.Binding,
  Aefos.OTA.Chat.Core.CLIBinaryResolver,
  // The global chat "memory" store, shared byte-compatibly with the RAD Studio
  // plugin (%APPDATA%\Aefos\memory.md) -- backs the composer brain button.
  Aefos.Lazarus.MemoryStore,
  // Agent-mode MCP wiring for an EXTERNAL CLI: merges the user's installed addon
  // MCP servers (e.g. aefos-desktop) with the in-process aefos server and returns
  // the config/bridge/session the driver needs. Mirrors the RAD Studio edition's
  // TCommandExecutor._BuildContext agent branch (single entry point from #264).
  Aefos.Lazarus.McpAddonMerge,
  Aefos.Executor.Models,
  Aefos.Provider.Registry,
  // THE shared, CLI-agnostic dispatch harness (the ONE owner of the final-prompt
  // + dispatch-request rule). This controller now DELEGATES both to it -- the
  // mirrored _BuildDispatchContext/_BuildDispatchRequest and the #285 preamble
  // injection are gone (owner mandate 2026-07-20: one harness, both IDEs).
  Aefos.Chat.Core.CliHarness,
  // The shared cross-compiler license gate, for the persistent trial reminder in
  // the chat header. It is {$mode delphiunicode}, so everything it returns is
  // UTF-16 and crosses into this UTF-8 unit through UTF16ToUTF8 (LazUTF8, already
  // in the interface uses) -- the same boundary Aefos.Lazarus.Register.pas:316
  // uses for StatusText.
  Aefos.Provider.Kinds;

const
  // JS -> Pascal message prefixes the shell posts (OutputPanel.Assets.pas).
  CMsgSend         = 'send:';
  CMsgStop         = 'stop:';
  CMsgBusyCheck    = 'busycheck:';
  CMsgComposerFocus = 'composer:focus';
  CMsgShellError   = 'shell-error:';
  CMsgAction       = 'action:';
  CMsgHdrModels    = 'hdr:models';
  CMsgHdrModel     = 'hdr:model:';
  CMsgHdrEffort    = 'hdr:effort:';
  // Command-surface messages (header icons + picker + MCP modal). Same wire the
  // shared shell (OutputPanel.Assets.pas) posts and the Delphi panel handles.
  CMsgHdrNewSession = 'hdr:newsession';
  CMsgHdrSettings   = 'hdr:settings';
  CMsgHdrSessions   = 'hdr:sessions';
  // Persistent trial reminder in the header. The shared shell already asks for
  // it -- HTML_SHELL posts 'hdr:trial' on load AND on every window focus
  // (OutputPanel.Assets.pas:4456,4461) and exposes window.dsSetTrial (:4440,
  // '' = hide) -- and clicking the badge posts 'hdr:license' (:4439). Only the
  // Pascal answer was missing on this side, so the badge the RAD Studio chat
  // shows ('Trial - N days left - Upgrade') simply never appeared in Lazarus.
  CMsgHdrTrial      = 'hdr:trial';
  CMsgHdrLicense    = 'hdr:license';
  CMsgSessionResume = 'session:resume:';
  CMsgSessionDelete = 'session:delete:';
  CMsgMcpOpen       = 'mcp:open';
  CMsgMcpSave       = 'mcp:save:';
  CMsgCmdPicker     = 'cmd:picker';
  // User-command editor modal bridge (the shared shell's ds-cmd-* JS). Same wire
  // the Delphi ChatPanel.HandleHostMessage answers: list/load feed the modal;
  // save/delete go through the registry (the one writer).
  CMsgCommandList   = 'command:list';
  CMsgCommandLoad   = 'command:load:';
  CMsgCommandSave   = 'command:save:';
  CMsgCommandDelete = 'command:delete:';

  // The user-editable global MCP config file name (under %APPDATA%\Aefos). The
  // exact file the RAD Studio chat's MCP modal reads/writes
  // (TChatGlobalSettings.McpConfigPath) -- NOT the provisioned/merged dispatch
  // config (aefos-mcp.json); this is the hand-editable server list.
  CMcpConfigFile    = 'mcp-servers.json';
  // Chat | Agent pills. Distinct from the model consts above despite the shared
  // stem: 'hdr:mode:' diverges from 'hdr:model:'/'hdr:models' at the 9th
  // character, so the prefix tests cannot collide -- but keep this test BEFORE
  // them if that ever changes.
  CMsgHdrMode      = 'hdr:mode:';

  // --- Composer action bar (attach + memory) -------------------------------
  // Posted by the shell's paperclip (ds-attach-open -> "attach:open") and brain
  // (ds-mem-open -> "memory:open"; save -> "memory:save:<text>") buttons. The
  // markup + JS already live in HTML_SHELL (OutputPanel.Assets.pas); these are
  // the message names the Lazarus controller must answer -- mirroring the Delphi
  // ChatPanel.HandleHostMessage branches for the same posts.
  CMsgAttachOpen   = 'attach:open';
  CMsgPasteImage   = 'paste:image:';
  CMsgMemoryOpen   = 'memory:open';
  CMsgMemorySave   = 'memory:save:';

  // Vendor-neutral, English-only (no CLI is ever named -- maintainer UI rule).
  // Shown when the configured executor's CLI cannot be found on any rung of the
  // shared resolver ladder (AEFOS_CLI -> configured path -> PATH -> the bundled
  // bin). Mirrors TCommandExecutor.Execute's ECLINotFound text, retargeted at
  // this IDE's Options page.
  CCliNotFoundNotice =
    'No AI CLI was found. Open Aefos AI > Options and set the Executor (its '
    + 'path), or put your AI CLI on PATH.';

  CNoModelNotice =
    'No local model is selected. Open Aefos AI > Options, pick "Local models '
    + '(Ollama)" and enter a model name that "ollama list" shows (for example '
    + 'qwen2.5:0.5b).';

  // Agent mode needs the IDE's MCP server for its tools. Said plainly rather
  // than degrading silently: an Agent turn that cannot reach the IDE is not
  // Agent mode, and pretending otherwise is the one thing this must never do.
  CAgentNoHostNotice =
    'Agent mode needs the Aefos AI MCP server, which could not be started. Use '
    + 'the Aefos AI menu to start it, or switch to Chat mode for a '
    + 'conversation-only turn.';

  // Agent mode with an EXTERNAL CLI executor. The in-process tool loop only
  // drives the local model; giving an external CLI IDE tools needs the MCP
  // bridge, which is a separate slice. Rather than let the Agent pill silently
  // lie, say so and run the turn as a normal conversation. Vendor-neutral: the
  // configured CLI is never named.
  CAgentExternalNotice =
    'Agent mode (IDE tools) is available for local models today. Your configured '
    + 'AI CLI will answer this as a normal chat turn. To use tools now, pick '
    + '"Local models (Ollama)" in Aefos AI > Options, or switch to Chat mode.';

type
  // Concrete liveness token. Aefos.Lazarus.WebViewHost publishes the
  // IAefosLiveToken interface but keeps its own concrete class private, so this
  // unit carries its own trivial implementation.
  // Implements BOTH liveness views on one object so a chat has exactly ONE
  // liveness truth: IAefosLiveToken for the WebView host, IAefosAgentLiveToken
  // for the agent loop (Aefos.Lazarus.ChatAgent redeclares it structurally to
  // stay out of the LCL host's mode). A single IsAlive satisfies both.
  TAefosChatLiveToken = class(TInterfacedObject, IAefosLiveToken,
    IAefosAgentLiveToken)
  private
    FAlive: Boolean;
  public
    constructor Create;
    function IsAlive: Boolean;
    procedure Kill;
  end;

  // The chunk sink handed to the Ollama transport instead of a bare
  // Self._OnChunk. The transport stores an `of object` pointer and never
  // refcounts it, so a chunk marshalled back after the controller is freed would
  // be a UAF. The sink outlives the controller via a self-interface hold (FSelf,
  // released only on the terminal chunk) and consults FLive before ever touching
  // the owner -- a late chunk is a safe no-op. FEnded is a completion signal the
  // controller's teardown drain observes independently of the (by then killed)
  // liveness gate.
  TAefosOllamaSink = class(TInterfacedObject)
  private
    FLive: IAefosLiveToken;
    FOwner: TAefosLazChatController;
    FSelf: IInterface;
    FEnded: Boolean;
  public
    constructor Create(AOwner: TAefosLazChatController; const ALive: IAefosLiveToken);
    procedure Deliver(const AChunk: TOllamaChunk);
    // Release the self-hold WITHOUT delivering, for the one path where the sink
    // is created but the transport call throws SYNCHRONOUSLY (so no terminal
    // Deliver ever runs to drop FSelf) - otherwise the sink leaks. Idempotent.
    procedure Abandon;
    property Ended: Boolean read FEnded;
  end;

  // The models sink handed to IOllamaTransport.FetchModels. IDENTICAL discipline
  // to TAefosOllamaSink above, and for the same reason: the transport stores a
  // bare `of object` and never refcounts it, so a /api/tags reply that lands
  // after this controller is freed would be a use-after-free (the C1 class PR
  // #245/#246 paid for). It self-holds via FSelf, consults FLive before ever
  // touching the owner, and releases FSelf as its LAST instruction.
  //   Worse than the chat case, in fact: Cancel() only aborts an in-flight
  // ChatStream, so a models fetch CANNOT be cancelled and always runs to its
  // /api/tags timeout. The token is therefore the whole guarantee -- there is no
  // drain that could help. FetchModels fires exactly once, so every delivery is
  // terminal.
  TAefosModelsSink = class(TInterfacedObject)
  private
    FLive: IAefosLiveToken;
    FOwner: TAefosLazChatController;
    FSelf: IInterface;
    FEnded: Boolean;
  public
    constructor Create(AOwner: TAefosLazChatController;
      const ALive: IAefosLiveToken);
    procedure Deliver(const AModels: TArray<UnicodeString>;
      const AError: UnicodeString);
    property Ended: Boolean read FEnded;
  end;

  // The sink handed to ICLIDispatcher.Dispatch instead of three bare
  // Self._OnCli* method pointers. SAME discipline as TAefosOllamaSink above, and
  // for the same reason (the C1 class PR #245/#246 paid for): the dispatcher's
  // carriers store these `of object` pointers and do NOT refcount them, so a
  // chunk marshalled back after this controller is freed would be a
  // use-after-free. It self-holds via FSelf, consults FLive before ever touching
  // the owner, and releases FSelf as its LAST instruction.
  //   The dispatcher guarantees exactly ONE Complete per run (idempotent via
  // FCompletedFlag) and fires it AFTER any Error, so Complete is the terminal
  // event and the only one that releases the hold. A cancel drives that same
  // completion path, so a stopped run settles the sink too.
  TAefosCliSink = class(TInterfacedObject)
  private
    FLive: IAefosLiveToken;
    FOwner: TAefosLazChatController;
    FSelf: IInterface;
    FEnded: Boolean;
  public
    constructor Create(AOwner: TAefosLazChatController;
      const ALive: IAefosLiveToken);
    procedure DeliverChunk(const AChunk: UnicodeString);
    procedure DeliverError(const AMessage: UnicodeString);
    procedure DeliverComplete(const AExitCode: Integer;
      const ADurationMs: Cardinal);
    // Release the self-hold WITHOUT delivering - see TAefosOllamaSink.Abandon.
    procedure Abandon;
    property Ended: Boolean read FEnded;
  end;

constructor TAefosChatLiveToken.Create;
begin
  inherited Create;
  FAlive := True;
end;

function TAefosChatLiveToken.IsAlive: Boolean;
begin
  Result := FAlive;
end;

procedure TAefosChatLiveToken.Kill;
begin
  FAlive := False;
end;

constructor TAefosOllamaSink.Create(AOwner: TAefosLazChatController;
  const ALive: IAefosLiveToken);
begin
  inherited Create;
  FOwner := AOwner;
  FLive := ALive;
  FSelf := Self;   // survive independent of the owner until the terminal chunk
end;

procedure TAefosOllamaSink.Deliver(const AChunk: TOllamaChunk);
var
  LTerminal: Boolean;
begin
  // Runs on the IDE main thread (the transport marshals every event via
  // TThread.Synchronize). Gate on the token: after the owner is torn down the
  // token is dead and we must never touch FOwner.
  LTerminal := AChunk.Done or (AChunk.Error <> '');
  try
    if (FLive <> nil) and FLive.IsAlive and (FOwner <> nil) then
      FOwner._OnChunk(AChunk);
  except
    // Never raise across the transport's marshalled call.
  end;
  if LTerminal then
  begin
    FEnded := True;
    FSelf := nil;   // MUST be the last statement -- may free Self here.
  end;
end;

procedure TAefosOllamaSink.Abandon;
begin
  if FEnded then
    Exit;
  FEnded := True;
  FSelf := nil;   // MUST be the last statement -- may free Self here.
end;

constructor TAefosModelsSink.Create(AOwner: TAefosLazChatController;
  const ALive: IAefosLiveToken);
begin
  inherited Create;
  FOwner := AOwner;
  FLive := ALive;
  FSelf := Self;   // survive independent of the owner until the reply lands
end;

procedure TAefosModelsSink.Deliver(const AModels: TArray<UnicodeString>;
  const AError: UnicodeString);
begin
  // Runs on the IDE main thread (the transport marshals via TThread.Synchronize).
  // Gate on the token: after the owner is torn down we must never touch FOwner.
  try
    if (FLive <> nil) and FLive.IsAlive and (FOwner <> nil) then
      FOwner._OnModels(AModels, AError);
  except
    // Never raise across the transport's marshalled call.
  end;
  // FetchModels delivers exactly once -- every call is the terminal one.
  FEnded := True;
  FSelf := nil;   // MUST be the last statement -- may free Self here.
end;

{ TAefosCliSink }

constructor TAefosCliSink.Create(AOwner: TAefosLazChatController;
  const ALive: IAefosLiveToken);
begin
  inherited Create;
  FOwner := AOwner;
  FLive := ALive;
  FSelf := Self;   // survive independent of the owner until the run completes
end;

procedure TAefosCliSink.DeliverChunk(const AChunk: UnicodeString);
begin
  // Runs on the IDE main thread (the dispatcher marshals via TThread.Queue).
  try
    if (FLive <> nil) and FLive.IsAlive and (FOwner <> nil) then
      FOwner._OnCliChunk(AChunk);
  except
    // Never raise across the dispatcher's marshalled call.
  end;
end;

procedure TAefosCliSink.DeliverError(const AMessage: UnicodeString);
begin
  // NOT terminal: the dispatcher fires Error then Complete in the same queued
  // delivery, so the hold is released by DeliverComplete alone.
  try
    if (FLive <> nil) and FLive.IsAlive and (FOwner <> nil) then
      FOwner._OnCliError(AMessage);
  except
    // Never raise across the dispatcher's marshalled call.
  end;
end;

procedure TAefosCliSink.DeliverComplete(const AExitCode: Integer;
  const ADurationMs: Cardinal);
begin
  try
    if (FLive <> nil) and FLive.IsAlive and (FOwner <> nil) then
      FOwner._OnCliComplete(AExitCode, ADurationMs);
  except
    // Never raise across the dispatcher's marshalled call.
  end;
  FEnded := True;
  FSelf := nil;   // MUST be the last statement -- may free Self here.
end;

procedure TAefosCliSink.Abandon;
begin
  if FEnded then
    Exit;
  FEnded := True;
  FSelf := nil;   // MUST be the last statement -- may free Self here.
end;

{ TAefosLazChatController }

constructor TAefosLazChatController.Create(const AWeb: TAefosLazWebView);
var
  LAppData: string;
begin
  inherited Create;
  FWeb := AWeb;
  FLive := TAefosChatLiveToken.Create;
  FQueuedMessages := TStringList.Create;
  FConversation := TList<TAefosSessionMessage>.Create;
  // Agent is the DEFAULT mode, mirroring the Delphi panel -- the pills in the
  // shell must boot showing what is actually in force (see _OnNav).
  FAgentMode := True;
  // Default to the GLOBAL, IDE-wide, per-Windows-profile root %APPDATA%\Aefos --
  // the SAME file the RAD Studio plugin and the Options page use.
  // Qualified: the Windows unit (pulled in for the focus-chain walk) exports a
  // 3-arg GetEnvironmentVariable that would otherwise win this call.
  LAppData := SysUtils.GetEnvironmentVariable('APPDATA');
  FConfigRoot := UTF8ToUTF16(LAppData + '\Aefos');
end;

destructor TAefosLazChatController.Destroy;
var
  LSpins: Integer;
begin
  // Suppress the send-during-run drain for the WHOLE teardown: the cancel/drain
  // loops below pump CheckSynchronize, which can fire a settle callback while the
  // liveness token is still alive, and that callback must NOT start a new turn on
  // a controller being freed. Set BEFORE the first Cancel.
  FTearingDown := True;
  // Cancel any in-flight stream and drain it BEFORE freeing, so no worker
  // callback lands on a dead controller. Cancel is cooperative (the worker
  // notices on its next socket read), so we pump the synchronize queue -- the
  // transport marshals its terminal chunk via TThread.Synchronize and the
  // Ollama drain loop does NOT service it. Bounded by a spin counter (no
  // Date/Now), ~3s worst case; a genuinely stuck model exits on the budget and
  // the liveness token below makes any later chunk a safe no-op.
  if Assigned(FTransport) then
  begin
    try
      FTransport.Cancel;
    except
      // teardown must never raise.
    end;
    LSpins := 0;
    while (FSinkObj <> nil) and (not TAefosOllamaSink(FSinkObj).Ended)
      and (LSpins < 150) do
    begin
      CheckSynchronize(20);
      Inc(LSpins);
    end;
    FTransport := nil;
  end;
  // Same discipline for an in-flight external-CLI run, with one extra duty: this
  // cancel TERMINATES A CHILD PROCESS (IDispatcherRunHandle.Cancel ->
  // TerminateProcess). Closing the chat window MUST NOT leave the user's CLI
  // running headless, so this is not optional bookkeeping. Cancel also forces
  // the run's completion immediately (it does not wait on the child closing its
  // pipes), so the drain below normally settles on the first spin; the same
  // bounded budget covers a pathological case, after which the dead token makes
  // any later delivery a safe no-op.
  if Assigned(FCliRun) then
  begin
    try
      FCliRun.Cancel;
    except
      // teardown must never raise.
    end;
    LSpins := 0;
    while (FCliSinkObj <> nil) and (not TAefosCliSink(FCliSinkObj).Ended)
      and (LSpins < 150) do
    begin
      CheckSynchronize(20);
      Inc(LSpins);
    end;
    FCliRun := nil;
  end;
  // And the same for an in-flight AGENT turn, with one difference that matters:
  // its worker can be parked in a BLOCKING MCP pipe read (no read deadline yet --
  // see Aefos.Agent.MCP.Core), so we must never WaitFor it; that would hang the
  // IDE on window close. Cancel is cooperative, and the drain below is bounded
  // exactly like the drains above. Whatever is still running when the budget
  // expires is harmless: the session is refcounted and jointly owned with its
  // worker, and the token killed below turns every later callback into a no-op --
  // so dropping our ref here can never dangle.
  if Assigned(FAgentSession) then
  begin
    _CancelAgentTurn;
    LSpins := 0;
    while (not FAgentSession.Ended) and (LSpins < 150) do
    begin
      CheckSynchronize(20);
      Inc(LSpins);
    end;
    FAgentSession := nil;
  end;
  // Token dead: from here, a late marshalled chunk no-ops instead of touching us.
  if Assigned(FLive) then
    FLive.Kill;
  FSinkObj := nil;
  FSinkHold := nil;   // drop our hold; the sink self-holds until its terminal chunk
  FCliSinkObj := nil;
  FCliSinkHold := nil; // ditto; the sink self-holds until its Complete
  FCliDispatcher := nil;
  FTestCliDispatcher := nil;
  // The models fetch is deliberately NOT drained: FetchModels has no Cancel, so
  // a drain could only sit on the /api/tags timeout and freeze the IDE while the
  // user closes the chat window. It does not need one -- the token above is dead,
  // so TAefosModelsSink.Deliver no-ops, and the sink self-holds until the reply
  // lands and then frees itself. Dropping these refs here is bookkeeping only:
  // the transport's own worker holds it alive to the end of the run.
  FModelsTransport := nil;
  FModelsSinkObj := nil;
  FModelsSinkHold := nil;
  FTestTransport := nil;
  // The queue + the conversation hold only plain values -- nothing IDE-held -- so
  // they are safe to free last, after every worker has been cancelled/drained.
  FreeAndNil(FQueuedMessages);
  FreeAndNil(FConversation);
  inherited Destroy;
end;

procedure TAefosLazChatController.AttachAndLoad;
begin
  FWeb.OnMessageReceived := HandleHostMessage;
  FWeb.OnNavigationCompleted := _OnNav;
  // The shell is queued now; the host flushes it once the controller is live.
  FWeb.NavigateToString(_BuildShell);
end;

procedure TAefosLazChatController._OnNav(const ASuccess: Boolean);
begin
  // Boot the shell once, after its first successful navigation: establish the
  // Chat mode (dsSetMode) and a clean, empty command picker (dsSetCommands) --
  // enough for the shell to be interactive. The empty-state chips show until the
  // first turn.
  if not ASuccess then
    Exit;
  if FBooted then
    Exit;
  FBooted := True;
  // Boot the pills to the mode actually in force (Agent by default), not a
  // hardcoded 'chat' -- the header must never claim a mode the dispatch ignores.
  if FAgentMode then
    _JsSetMode('agent')
  else
    _JsSetMode('chat');
  _Run('window.dsSetCommands && window.dsSetCommands([]);');
end;

function TAefosLazChatController._ResolveConfigRoot: UnicodeString;
begin
  // Returned as UnicodeString to match the core's delphiunicode resolver seam
  // (function: string of object). Bound to a typed local by the caller so it
  // binds as a method pointer, never a call (the FPC delphi-mode idiom).
  Result := FConfigRoot;
end;

function TAefosLazChatController._LoadConfig: TConfig;
var
  LResolver: TConfigRootResolver;
  LConfig: IConfig;
begin
  LResolver := Self._ResolveConfigRoot;
  LConfig := TConfigService.Create(LResolver);
  LConfig.Load;
  Result := LConfig.Snapshot;
end;

// --- Pascal -> JS ----------------------------------------------------------

procedure TAefosLazChatController._Run(const AScript: string);
begin
  if Assigned(FOnScript) then
    FOnScript(AScript);
  if Assigned(FWeb) then
    FWeb.ExecuteScript(AScript);
end;

procedure TAefosLazChatController._JsUser(const AText: string);
begin
  _Run('window.dsUser && window.dsUser(' + _JsEncode(AText) + ');');
end;

procedure TAefosLazChatController._JsClear;
begin
  // Turn start: shows "working...", the typing line, and flips the composer to a
  // Stop button (dsClear itself calls dsSetBusy(true) in the shell).
  _Run('window.dsClear && window.dsClear();');
end;

procedure TAefosLazChatController._JsAppend(const AText: string);
begin
  _Run('window.dsAppend && window.dsAppend(' + _JsEncode(AText) + ');');
end;

procedure TAefosLazChatController._JsFooter(const AText: string;
  const AIsError: Boolean);
begin
  // Turn settled: hides the typing line, sets the footer, restores Send
  // (dsFooter itself calls dsSetBusy(false) in the shell).
  if AIsError then
    _Run('window.dsFooter && window.dsFooter(' + _JsEncode(AText) + ', true);')
  else
    _Run('window.dsFooter && window.dsFooter(' + _JsEncode(AText) + ', false);');
end;

procedure TAefosLazChatController._JsSetMode(const AMode: string);
begin
  _Run('window.dsSetMode && window.dsSetMode(' + _JsEncode(AMode) + ');');
end;

procedure TAefosLazChatController._JsQueued(const ACount: Integer);
begin
  // Send-during-run queue counter (mirrors TRenderProtocol.QueuedNoticeScript ->
  // window.dsQueued). 0 hides the line. The shared shell (HTML_SHELL) already
  // defines window.dsQueued + the #ds-queued element, so this cue is the SAME the
  // Delphi panel shows -- no shell change, and vendor-neutral by construction.
  _Run('window.dsQueued && window.dsQueued(' + IntToStr(ACount) + ');');
end;

procedure TAefosLazChatController._JsPrefill(const AText: string);
begin
  // window.dsPrefillInput REPLACES the composer value, focuses it, and puts the
  // caret at the end so the user keeps typing the target -- the exact affordance
  // the Delphi panel's PrefillInput drives for the empty-state chips.
  _Run('window.dsPrefillInput && window.dsPrefillInput(' + _JsEncode(AText) + ');');
end;

class function TAefosLazChatController._JsEncode(const AInput: string): string;
var
  LFor: Integer;
  LByte: Byte;
begin
  // Mirrors TRenderProtocol.JSEncode. AInput is UTF-8 (LCL AnsiString): iterate
  // bytes -- control bytes (< $20) are \u-escaped, quote/backslash/whitespace
  // get their short escapes, and every byte >= $20 (including UTF-8 lead and
  // continuation bytes, all >= $80) passes through verbatim, so the multibyte
  // sequence survives intact into the JS string literal.
  Result := '"';
  for LFor := 1 to Length(AInput) do
  begin
    LByte := Ord(AInput[LFor]);
    case LByte of
      Ord('"'):  Result := Result + '\"';
      Ord('\'):  Result := Result + '\\';
      8:   Result := Result + '\b';
      9:   Result := Result + '\t';
      10:  Result := Result + '\n';
      12:  Result := Result + '\f';
      13:  Result := Result + '\r';
    else
      if LByte < $20 then
        Result := Result + '\u' + LowerCase(IntToHex(LByte, 4))
      else
        Result := Result + AInput[LFor];
    end;
  end;
  Result := Result + '"';
end;

class function TAefosLazChatController._BuildShell: string;
var
  LThemeVars: string;
begin
  // Mirrors TRenderProtocol.BuildShell(TPanelTheme.Dark): substitute the theme
  // custom-properties block + the four generated/owned asset placeholders into
  // HTML_SHELL. The chat is always dark (vendor-neutral); the palette matches
  // the Delphi Dark theme byte-for-byte. Curly braces below are CSS, not Pascal
  // comments -- safe inside the string literals.
  LThemeVars :=
    ':root { ' +
    '--ds-bg:#1e1e1e; ' +
    '--ds-fg:#d4d4d4; ' +
    '--ds-secondary:#808080; ' +
    '--ds-border:#3c3c3c; ' +
    '--ds-accent:#9cdcfe; ' +
    '--ds-user-bg:#d97757; ' +
    '--ds-user-fg:#ffffff; ' +
    '--ds-blue:#2A98FF; --ds-blue-2:#1a7ae0; --ds-blue-rgb:42,152,255; ' +
    '--ds-primary:#d97757; --ds-primary-hi:#e0875f; --ds-primary-lo:#d2693f; ' +
    '--ds-primary-rgb:217,119,87; ' +
    '--ds-danger:#e0664a; --ds-danger-rgb:224,102,74; ' +
    '--ds-success:#25d366; --ds-success-rgb:37,211,102; ' +
    '--ds-warn:#e0a93a; --ds-warn-rgb:224,169,58; ' +
    '}';
  Result := HTML_SHELL;
  Result := StringReplace(Result, '{{THEME_VARS}}', LThemeVars, []);
  Result := StringReplace(Result, '{{PANEL_CSS}}', PANEL_CSS, []);
  Result := StringReplace(Result, '{{HIGHLIGHT_CSS}}', HIGHLIGHT_CSS, []);
  Result := StringReplace(Result, '{{MARKED_JS}}', MARKED_JS, []);
  Result := StringReplace(Result, '{{HIGHLIGHT_JS}}', HIGHLIGHT_JS, []);
end;

// --- JS -> Pascal ----------------------------------------------------------

procedure TAefosLazChatController.HandleHostMessage(const AMessage: string);
begin
  // Every branch is guarded so a callback into the shell can never crash the IDE.
  try
    if AMessage = '' then
      Exit;
    if Copy(AMessage, 1, Length(CMsgSend)) = CMsgSend then
      _HandleSend(Copy(AMessage, Length(CMsgSend) + 1, MaxInt))
    else if AMessage = CMsgStop then
      // Composer Stop: whichever shape is in flight -- plain stream, external-CLI
      // child, or an agent turn. Each drives its normal terminal event, so the
      // turn settles and the composer returns to Send. _CancelInFlight covers all
      // three.
      _CancelInFlight
    else if AMessage = CMsgBusyCheck then
    begin
      // A stale-busy probe: if no run is actually in flight, restore the composer
      // so a lost completion can self-heal (mirrors the Delphi busycheck path).
      if not FBusy then
        _Run('window.dsSetBusy && window.dsSetBusy(false);');
    end
    else if AMessage = CMsgComposerFocus then
    begin
      // ⚠️ ONLY when we do not already hold the Win32 focus. MoveFocus re-focuses
      // the document, which re-fires the composer's DOM 'focus' event, which posts
      // this message again: calling it unconditionally is an infinite ping-pong
      // that pegs the WebView2 browser process, flickers the caret and makes
      // typing a fight (field report 2026-07-17, measured at 81% of a core).
      // The Delphi twin guards the same way (ChatPanel._FocusInChat, "ONLY when
      // we don't already hold it ... so there is no focus loop") - the shell's own
      // comment even promises "Pascal guards against a focus loop". This one did
      // not; the guard is the contract, not an optimisation.
      if Assigned(FWeb) and (not _FocusInWebView) then
        FWeb.FocusWebView;
    end
    else if Copy(AMessage, 1, Length(CMsgHdrMode)) = CMsgHdrMode then
      // Chat | Agent pills. The shell posts this on every toggle; it is the only
      // channel that carries the user's intent for the NEXT turn.
      _HandleSetMode(Copy(AMessage, Length(CMsgHdrMode) + 1, MaxInt) = 'agent')
    else if AMessage = CMsgHdrModels then
      // Header model selector asking for its list (posted on load and on every
      // window focus, so this must stay cheap and idempotent).
      _HandleGetModels
    else if Copy(AMessage, 1, Length(CMsgHdrModel)) = CMsgHdrModel then
      _HandleSetModel(Copy(AMessage, Length(CMsgHdrModel) + 1, MaxInt))
    else if Copy(AMessage, 1, Length(CMsgHdrEffort)) = CMsgHdrEffort then
      // The effort pill, shown only for executors that expose one. Reachable now
      // that effortSupported answers the real capability (_PushModelsJson).
      _HandleSetEffort(Copy(AMessage, Length(CMsgHdrEffort) + 1, MaxInt))
    // --- Composer action bar (attach + memory) -----------------------------
    // Additive block; no collision with the branches above (all exact/prefix
    // matches on distinct stems). Mirrors ChatPanel's attach:open / memory:open /
    // memory:save branches.
    else if AMessage = CMsgAttachOpen then
      // Paperclip: open a native file picker; the chosen path becomes an
      // attachment chip in the shell and rides into the outgoing message on send.
      _HandleAttachOpen
    else if Copy(AMessage, 1, Length(CMsgPasteImage)) = CMsgPasteImage then
      // Clipboard image pasted into the composer: the shared shell posts the PNG
      // as base64; save it to a temp file and add an image chip (mirror of the
      // RAD Studio ChatPanel's paste:image branch).
      _HandlePasteImage(Copy(AMessage, Length(CMsgPasteImage) + 1, MaxInt))
    else if AMessage = CMsgMemoryOpen then
      // Brain: load the global memory and open the modal prefilled.
      _HandleMemoryOpen
    else if Copy(AMessage, 1, Length(CMsgMemorySave)) = CMsgMemorySave then
      // Memory modal Save: persist the edited text (the shell already hid it).
      _HandleMemorySave(Copy(AMessage, Length(CMsgMemorySave) + 1, MaxInt))
    else if Copy(AMessage, 1, Length(CMsgShellError)) = CMsgShellError then
      // Shell JS reported a broken runtime; nothing to recover in this slice.
      Exit
    else if AMessage = CMsgHdrNewSession then
      // Header "new session" icon: persist the current conversation, then reset to
      // a fresh one. Mirrors ChatPanel's hdr:newsession (_ResetSessionInfo +
      // OnNewSession).
      _HandleNewSession
    else if AMessage = CMsgHdrSettings then
      // Header gear: open the IDE Options page via the composed callback. Mirrors
      // ChatPanel's hdr:settings (OnOpenSettings).
      _HandleOpenSettings
    else if AMessage = CMsgHdrTrial then
      // Shell asking for the trial reminder (load + every window focus).
      _PushTrialBadge
    else if AMessage = CMsgHdrLicense then
      // Click on the badge / upgrade CTA: activation screen, then re-push.
      _HandleLicense
    else if AMessage = CMsgHdrSessions then
      // Header history icon: open the sessions panel. Mirrors _OpenSessionsPanel.
      _HandleOpenSessions
    else if Copy(AMessage, 1, Length(CMsgSessionResume)) = CMsgSessionResume then
      // Row click in the sessions panel: replay + adopt that session.
      _HandleResumeSession(Copy(AMessage, Length(CMsgSessionResume) + 1, MaxInt))
    else if Copy(AMessage, 1, Length(CMsgSessionDelete)) = CMsgSessionDelete then
      // Trash icon in the sessions panel: drop that session from the store.
      _HandleDeleteSession(Copy(AMessage, Length(CMsgSessionDelete) + 1, MaxInt))
    else if AMessage = CMsgMcpOpen then
      // MCP button / the /mcp built-in: load the global config + show the modal.
      _HandleOpenMcp
    else if Copy(AMessage, 1, Length(CMsgMcpSave)) = CMsgMcpSave then
      // MCP modal Save: persist the edited config JSON.
      _HandleSaveMcp(Copy(AMessage, Length(CMsgMcpSave) + 1, MaxInt))
    else if AMessage = CMsgCmdPicker then
      // Slash-picker asking for its list (posted on load + focus). Feed the
      // built-ins + the stored user commands. Mirrors ChatPanel._SendPickerCommands.
      _HandlePicker
    else if AMessage = CMsgCommandList then
      // Command editor "Edit existing": feed the editable-commands dropdown.
      _SendCommandList
    else if Copy(AMessage, 1, Length(CMsgCommandLoad)) = CMsgCommandLoad then
      // Editable-command row click: load it into the editor for editing.
      _LoadCommandIntoEditor(Copy(AMessage, Length(CMsgCommandLoad) + 1, MaxInt))
    else if Copy(AMessage, 1, Length(CMsgCommandSave)) = CMsgCommandSave then
      // Command editor Save: persist the {name,description,prompt,scope} JSON.
      _SaveCommandFromJson(Copy(AMessage, Length(CMsgCommandSave) + 1, MaxInt))
    else if Copy(AMessage, 1, Length(CMsgCommandDelete)) = CMsgCommandDelete then
      // Delete (hidden button; defensive): mirror the Delphi "not supported" note.
      _NotifyCommandDeleteUnsupported(
        Copy(AMessage, Length(CMsgCommandDelete) + 1, MaxInt))
    else if Copy(AMessage, 1, Length(CMsgAction)) = CMsgAction then
      // Empty-state chips (action:explain/...): prefill the composer with the
      // mapped slash command. Mirrors ChatPanel's action->PrefillInput map.
      _HandleActionChip(Copy(AMessage, Length(CMsgAction) + 1, MaxInt));
  except
    on E: Exception do
      // Never let an exception cross back into the WebView2 callback stack.
      _Run('/* aefos: host-message handler swallowed ' + E.ClassName + ' */');
  end;
end;

// --- Composer action bar (attach + memory) ---------------------------------

procedure TAefosLazChatController._HandleAttachOpen;
var
  LDlg: TOpenDialog;
begin
  // Paperclip -> attach:open. Mirror of TAefosChatPanel._OpenAttachDialog: open a
  // native file picker; the chosen path becomes a file-icon attachment chip in the
  // shell, and rides into the outgoing message on send (the SHARED shell's
  // dsSubmit appends "[Attached files - read them]:" + the paths -- all shell-side,
  // no threading of the path through _DoSend needed). Here we only pick the file
  // and hand its path to window.dsAddAttachment; the shell owns the chip + its X.
  //   Runs on the IDE main thread (a shell button click already is), so the modal
  // TOpenDialog needs no worker.
  if FWeb = nil then
    Exit;
  LDlg := TOpenDialog.Create(nil);
  try
    LDlg.Title := 'Attach a file';
    LDlg.Options := LDlg.Options + [ofFileMustExist, ofPathMustExist];
    // Lazarus-flavoured mirror of the Delphi filter (its .dpr/.dpk/.dfm become the
    // FPC/LCL .lpr/.lfm here). "All files" first so nothing is ever unreachable.
    LDlg.Filter :=
      'All files (*.*)|*.*' +
      '|Source (*.pas;*.pp;*.lpr;*.lfm;*.inc)|*.pas;*.pp;*.lpr;*.lfm;*.inc' +
      '|Images (*.png;*.jpg;*.jpeg;*.gif;*.bmp)|*.png;*.jpg;*.jpeg;*.gif;*.bmp';
    if LDlg.Execute then
      // A file-icon chip (no thumbnail): kind 'file', empty thumb. LCL FileName is
      // already UTF-8, which _JsEncode carries through byte-safe.
      _Run('window.dsAddAttachment && window.dsAddAttachment('
        + _JsEncode(LDlg.FileName) + ', "file", "");');
  finally
    LDlg.Free;
  end;
end;

procedure TAefosLazChatController._HandlePasteImage(const ABase64: string);
var
  LBytes: TBytes;
  LGuidStr, LPath: string;
  LGuid: TGUID;
begin
  // Twin of TAefosChatPanel._SavePastedImage: the shared shell's paste handler
  // posts a clipboard image as base64 PNG; decode it to a temp file and hand its
  // path to window.dsAddAttachment as an IMAGE chip (kind 'image', data-URL thumb
  // reusing the base64 we received). The temp path rides into the outgoing message
  // on send (shell-side), so the CLI's Read tool sees the image. A malformed
  // payload must never break the chat, so the whole body is guarded. Path stays in
  // the same `string` domain McpAddonMerge uses for TPath/TFile - no codepage churn.
  if FWeb = nil then
    Exit;
  try
    LBytes := TNetEncoding.Base64.DecodeStringToBytes(ABase64);
    if Length(LBytes) = 0 then
      Exit;
    CreateGUID(LGuid);
    // GUIDToString yields "{XXXX-...}"; drop the braces with Copy (UnicodeString-
    // clean, no StringReplace codepage round-trip) for a unique ASCII file stem.
    LGuidStr := GUIDToString(LGuid);
    LPath := TPath.Combine(TPath.GetTempPath,
      'ds_paste_' + Copy(LGuidStr, 2, Length(LGuidStr) - 2) + '.png');
    TFile.WriteAllBytes(LPath, LBytes);
    _Run('window.dsAddAttachment && window.dsAddAttachment('
      + _JsEncode(LPath) + ', "image", '
      + _JsEncode('data:image/png;base64,' + ABase64) + ');');
  except
    // Malformed clipboard payload / IO failure: swallow, keep the chat alive.
  end;
end;

procedure TAefosLazChatController._HandleMemoryOpen;
var
  LText: string;
begin
  // Brain -> memory:open. Mirror of ChatPanel's memory:open branch (OnMemoryLoad
  // -> TChatGlobalSettings.LoadMemory): load the GLOBAL memory text and open the
  // modal prefilled (window.dsShowMemory). The store is SHARED with the RAD Studio
  // plugin (%APPDATA%\Aefos\memory.md, resolved from FConfigRoot) -- one memory,
  // both IDEs.
  LText := TAefosLazMemoryStore.Load(UTF16ToUTF8(FConfigRoot));
  _Run('window.dsShowMemory && window.dsShowMemory(' + _JsEncode(LText) + ');');
end;

procedure TAefosLazChatController._HandleMemorySave(const AText: string);
begin
  // memory:save:<text> -> persist the edited memory. Mirror of ChatPanel's
  // memory:save branch (OnMemorySave -> TChatGlobalSettings.SaveMemory). The shell
  // hid the modal already, so there is nothing to render back.
  try
    TAefosLazMemoryStore.Save(UTF16ToUTF8(FConfigRoot), AText);
  except
    // A failed write (disk full / locked file) must never crash the IDE.
  end;
end;

procedure TAefosLazChatController._HandleSend(const AText: string);
begin
  // Public JS->Pascal entry (the shell's 'send:' post). A user send is a fresh,
  // not-drained send -- see _DoSend for the queue gate.
  _DoSend(AText, False);
end;

procedure TAefosLazChatController._DoSend(const AText: string;
  const AFromQueue: Boolean);
var
  LConfig: TConfig;
  LDispatchText: string;
begin
  if Trim(AText) = '' then
    Exit;
  // Slash commands the controller handles ITSELF (e.g. /mcp, /new, /reset) never
  // become a chat turn: intercept BEFORE the echo/queue so no user bubble shows
  // and the model is not asked to answer a command. Mirrors ChatPanel routing the
  // UI-modal built-ins to their bespoke handlers instead of dispatching them.
  if _TryHandleSlashCommand(AText) then
    Exit;
  // Send-during-run queue (mirrors TAefosChatPanel._DispatchCommand's gate). A
  // message the user sends WHILE a turn is in flight is NOT dropped: echo its
  // bubble at once, append it to the FIFO, and update the window.dsQueued cue. It
  // auto-dispatches as its own turn when the current one settles (see
  // _DrainQueuedMessage). AFromQueue is the drain's own re-entry: the bubble was
  // already echoed when the text was queued, so it must bypass this gate (else it
  // would re-queue itself) and skip the duplicate echo below.
  if (not AFromQueue) and FBusy then
  begin
    _JsUser(AText);
    FQueuedMessages.Add(AText);
    _JsQueued(FQueuedMessages.Count);
    Exit;
  end;

  // Render the user bubble immediately (design-time truth of the conversation) --
  // UNLESS this is a drained message, which was echoed when it was queued.
  if not AFromQueue then
    _JsUser(AText);
  if Assigned(FOnSend) then
    FOnSend(AText);

  // Record the user's turn for session history (title/id/count + ctx line). Only
  // ever reached on an ACTUAL dispatch -- a message queued while busy returned
  // above and is recorded when the drain re-enters here (AFromQueue).
  _RecordUserTurn(AText);

  LConfig := _LoadConfig;
  // Stored-command expansion: a bare /name of a saved command dispatches that
  // command's PROMPT BODY, while the user bubble + session history keep the raw
  // /name (recorded above). Mirrors TCommandExecutor._PrepareContext feeding
  // FRegistry.LoadBody into the final prompt while the panel echoes the raw text.
  // '' means AText was not a bare stored command -> dispatch it verbatim.
  LDispatchText := _ExpandStoredCommand(AText);
  if LDispatchText = '' then
    LDispatchText := AText;
  if LConfig.Executor = ekOllama then
    _DispatchOllama(LDispatchText, LConfig)
  else
  begin
    // Agent mode for an external CLI: when the in-process MCP host is reachable we
    // hand the CLI the aefos tool surface (see _DispatchExternalCli's harness
    // wiring) -- no notice, it is genuinely agentic. Only when the host is
    // unavailable (standalone proof) do we say so once, up front, so the Agent
    // pill never silently lies, then dispatch as a normal conversation. The
    // aefos-first preamble itself is now assembled by the SHARED harness inside
    // _DispatchExternalCli (TAefosCliHarness.AssembleFinalPrompt), so it is no
    // longer prepended here -- one preamble text for both IDEs.
    if FAgentMode and (not _AgentHostReady) then
      _JsAppend(CAgentExternalNotice);
    _DispatchExternalCli(LDispatchText, LConfig);
  end;
end;

procedure TAefosLazChatController._DrainQueuedMessage;
var
  LText: string;
begin
  // The single place all three dispatch shapes converge to hand the turn to the
  // next queued send: called from the Ollama Done/Error chunk, the agent-turn
  // done, and the external-CLI complete. Mirrors TAefosChatPanel._DrainQueuedMessage.
  //
  // Teardown guard FIRST: Destroy pumps CheckSynchronize while the liveness token
  // is still alive, so a terminal event can land mid-teardown and reach here -- it
  // must NOT start a new turn on a controller that is being freed.
  if FTearingDown then
    Exit;
  if (FQueuedMessages = nil) or (FQueuedMessages.Count = 0) then
    Exit;
  // Never drain into a live turn. Every settle callback clears FBusy BEFORE
  // calling here, so a normal drain sees FBusy False; this guards a stray call.
  if FBusy then
    Exit;
  LText := FQueuedMessages[0];
  FQueuedMessages.Delete(0);
  _JsQueued(FQueuedMessages.Count);
  // Dispatch as its own turn: AFromQueue skips the (already-shown) echo and
  // bypasses the busy gate.
  _DoSend(LText, True);
  // If that drained send never actually started a run (a synchronous no-model /
  // CLI-not-found / build throw settles immediately with FBusy still False), no
  // async terminal will ever come to drain the REST of the queue -- so keep going
  // here. Bounded by the queue length; not a retry loop.
  if (FQueuedMessages.Count > 0) and (not FBusy) then
    _DrainQueuedMessage;
end;

procedure TAefosLazChatController._CancelInFlight;
begin
  // All three cancels are idempotent no-ops when their transport is idle, so this
  // is safe to call unconditionally (Stop with nothing running, teardown, ...).
  // The three dispatch shapes are mutually exclusive per turn, but Stop must not
  // assume WHICH one is live, so it hits all of them.
  if Assigned(FTransport) then
    FTransport.Cancel;
  if Assigned(FCliRun) then
    FCliRun.Cancel;
  _CancelAgentTurn;   // an in-flight agent turn -- no-op when none is running
end;

procedure TAefosLazChatController._RenderAssistantLine(const AText: string;
  const AIsError: Boolean);
begin
  // Open a fresh assistant block, drop one line, settle the turn.
  _JsClear;
  _JsAppend(AText);
  _JsFooter('', AIsError);
end;

// --- External-CLI dispatch -------------------------------------------------

{ TAefosLazHarnessInputs -- the Lazarus adapter onto IAefosCliHarnessInputs (the
  twin of TCommandExecutorHarnessInputs on the RAD Studio side). It FEEDS the
  shared harness: the final-prompt text and the request assembly now live ONCE in
  Aefos.Chat.Core.CliHarness; this only surfaces the per-turn command body, the
  shared memory, the header model, this edition's in-process MCP host wiring and
  the session state. It holds a plain back-pointer to the controller (which
  outlives it). This unit is delphi-mode (string = UTF-8 AnsiString), so every
  seam member is declared UnicodeString and converts through LazUTF8 -- the same
  boundary discipline the CLI/agent sinks use. }
type
  TAefosLazHarnessInputs = class(TInterfacedObject, IAefosCliHarnessInputs)
  private
    FController: TAefosLazChatController;
    FConfig: TConfig;
    FCommandBody: UnicodeString;
    FAgentEffective: Boolean;
  public
    constructor Create(const AController: TAefosLazChatController;
      const AConfig: TConfig; const ACommandBody: UnicodeString;
      const AAgentEffective: Boolean);
    function AgentMode: Boolean;
    function Vocabulary: TAefosIdeVocabulary;
    function MemoryText: UnicodeString;
    function RenderedContext: UnicodeString;
    function CommandBody: UnicodeString;
    function Selection: UnicodeString;
    function WorkingDirectory: UnicodeString;
    function DispatchModel: UnicodeString;
    procedure ResolveMcpWiring(const AProfileKind: TExecutorKind;
      var AWiring: TAefosCliMcpWiring);
    function EnsureSessionId: UnicodeString;
    function SessionStarted: Boolean;
    function ConversationId: UnicodeString;
  end;

constructor TAefosLazHarnessInputs.Create(
  const AController: TAefosLazChatController; const AConfig: TConfig;
  const ACommandBody: UnicodeString; const AAgentEffective: Boolean);
begin
  inherited Create;
  FController := AController;
  FConfig := AConfig;
  FCommandBody := ACommandBody;
  FAgentEffective := AAgentEffective;
end;

function TAefosLazHarnessInputs.AgentMode: Boolean;
begin
  // The EFFECTIVE agent mode: True only when the header toggle is on AND the
  // in-process MCP host is reachable, so the aefos-first preamble is promised
  // only when the tools are genuinely on the table (else the shared harness uses
  // the Chat-mode preamble). Matches ResolveMcpWiring's AgentToolingActive.
  Result := FAgentEffective;
end;

function TAefosLazHarnessInputs.Vocabulary: TAefosIdeVocabulary;
begin
  // The LAZARUS nouns, so the one shared preamble names Lazarus/.lfm (never RAD
  // Studio/.dfm/SetDFMContent, which do not exist here).
  Result := TAefosCliHarness.LazarusVocabulary;
end;

function TAefosLazHarnessInputs.MemoryText: UnicodeString;
begin
  // The GLOBAL "memory" text, SHARED with the RAD Studio plugin
  // (%APPDATA%\Aefos\memory.md, resolved from the controller's config root).
  Result := UTF8ToUTF16(
    TAefosLazMemoryStore.Load(UTF16ToUTF8(FController.FConfigRoot)));
end;

function TAefosLazHarnessInputs.RenderedContext: UnicodeString;
begin
  // No OTA project context in this IDE-free controller -- the honest floor.
  Result := '';
end;

function TAefosLazHarnessInputs.CommandBody: UnicodeString;
begin
  Result := FCommandBody;
end;

function TAefosLazHarnessInputs.Selection: UnicodeString;
begin
  Result := '';
end;

function TAefosLazHarnessInputs.WorkingDirectory: UnicodeString;
begin
  // '' = inherit the IDE's own cwd (this IDE-free controller has no project
  // folder resolver).
  Result := '';
end;

function TAefosLazHarnessInputs.DispatchModel: UnicodeString;
begin
  // Resolve the model exactly as the header selector reports it, so what the
  // header SHOWS is what this turn RUNS (see _ResolveCurrentModel).
  Result := FController._ResolveCurrentModel(FConfig.Executor, FConfig);
end;

procedure TAefosLazHarnessInputs.ResolveMcpWiring(
  const AProfileKind: TExecutorKind; var AWiring: TAefosCliMcpWiring);
var
  LPipeName: UnicodeString;
  LWiring: TAefosLazMcpWiring;
begin
  // The Lazarus MCP wiring (was TAefosLazChatController._BuildDispatchContext).
  // We start the in-process MCP host (idempotent -- a convenience, NOT a consent
  // grant; every mutating tool still meets the host's first-write dialog), derive
  // the bridge session from its pipe, and merge the user's installed addon MCP
  // servers via Aefos.Lazarus.McpAddonMerge. Every driver gates its MCP flags on
  // AgentToolingActive, so when the host is unavailable (standalone proof) we
  // degrade honestly: it stays False and no driver emits a server it cannot reach.
  AWiring.AgentToolingActive := False;
  // PARITY GAP, stated rather than faked: the Lazarus edition has no reader for
  // arbitrary shared-config keys yet, so it stays on the default -- which is
  // exactly what it does today, so nothing regresses. When its Options grow the
  // toggle, it reads the SAME agent_native_tools key the RAD page writes.
  AWiring.AllowNativeTools := False;
  AWiring.McpConfigPath := '';
  AWiring.McpBridgePath := '';
  AWiring.McpSession := '';
  // This edition's DISTINCT built-in server key ('aefos-lazarus'), stamped
  // unconditionally so even the degraded plain-chat --disallowedTools names THIS
  // edition's namespace rather than the driver's bare 'aefos' default (owner
  // decision 2026-07-18).
  AWiring.McpServerName := TAefosLazMcpAddonMerge.BuiltInServerKey;
  AWiring.ExtraMcpNames := nil;
  if FController.FAgentMode and TAefosLazAgentGate.EnsureMcpHost(LPipeName) then
  begin
    LWiring := TAefosLazMcpAddonMerge.BuildMergedConfig(LPipeName);
    AWiring.AgentToolingActive := True;
    AWiring.McpConfigPath := LWiring.ConfigPath;
    AWiring.McpBridgePath := LWiring.BridgePath;
    AWiring.McpSession := LWiring.Session;
    AWiring.McpServerName := LWiring.ServerName;
    AWiring.ExtraMcpNames := LWiring.ServerNames;
    // Gemini has NO MCP flag: its driver only emits --allowed-mcp-server-names
    // aefos, which resolves ONLY if ~/.gemini/settings.json already declares the
    // server. Provision it there (agent mode only), pointed at THIS host's session.
    if AProfileKind = ekGemini then
      TAefosLazMcpAddonMerge.EnsureGeminiConfig(AWiring.McpSession);
  end;
end;

function TAefosLazHarnessInputs.EnsureSessionId: UnicodeString;
begin
  if FController.FSessionId = '' then
    FController.FSessionId := TAefosCliHarness.NewSessionId;
  Result := FController.FSessionId;
end;

function TAefosLazHarnessInputs.SessionStarted: Boolean;
begin
  Result := FController.FSessionStarted;
end;

function TAefosLazHarnessInputs.ConversationId: UnicodeString;
begin
  // Mirrors TCommandExecutorHarnessInputs.ConversationId -- the RAD Studio side
  // is the contract. Pinned: mint (idempotent), so turn 1 states the id it will
  // actually run under. Captured: only what a run really minted; '' on turn 1 is
  // the honest answer, never an invented uuid.
  if TProviderRegistry.ResolveExecutorProfile(
       FConfig.Executor).SessionSupport = ssPinned then
    Result := EnsureSessionId
  else
    Result := FController.FSessionId;
end;

procedure TAefosLazChatController._DispatchExternalCli(const AText: string;
  const AConfig: TConfig);
var
  LProfile: IExecutorProfile;
  LExecutorPath: UnicodeString;
  LRequest: TDispatchRequest;
  LInputs: IAefosCliHarnessInputs;
  LFinalPrompt: UnicodeString;
  LAgentEffective: Boolean;
  LSink: TAefosCliSink;
  LOnChunk: TDispatcherChunkCallback;
  LOnComplete: TDispatcherCompleteCallback;
  LOnError: TDispatcherErrorCallback;
begin
  // Driver for the configured executor. Resolved FRESH from the config on every
  // turn (never cached), so an executor change in Options applies to the next
  // send without an IDE restart.
  LProfile := TProviderRegistry.ResolveExecutorProfile(AConfig.Executor);
  FCliProfile := LProfile;
  // The shared resolver ladder: AEFOS_CLI -> the configured path -> PATH -> the
  // installer-bundled bin. Same order, same unit, as the RAD Studio chat.
  LExecutorPath := ResolveCLIBinary(AConfig.ExecutorPath, LProfile.BinaryName);
  if LExecutorPath = '' then
  begin
    _RenderAssistantLine(CCliNotFoundNotice, True);
    Exit;
  end;

  // Turn starts: dsClear shows "working..." and flips the composer to Stop.
  // Guarded so a synchronous throw (arg build, executor-not-found, spawn
  // failure) can never strand FBusy=True -- the "stuck on working..." bug class.
  FBusy := True;
  try
    _JsClear;
    // DELEGATE to the shared harness (the ONE owner of the rule): it assembles
    // the aefos-first/Chat preamble + the global "memory" + the user's text into
    // the final prompt, then builds the TDispatchRequest (driver args, api-key
    // env, session, timeout, filter). The command body is the user's text (or the
    // expanded stored command); this edition has no OTA project context, so it
    // stays ''. Agent tooling is effective only when the MCP host is reachable.
    LAgentEffective := FAgentMode and _AgentHostReady;
    LInputs := TAefosLazHarnessInputs.Create(Self, AConfig, UTF8ToUTF16(AText),
      LAgentEffective);
    LFinalPrompt := TAefosCliHarness.AssembleFinalPrompt(LInputs);
    LRequest := TAefosCliHarness.BuildDispatchRequest(LInputs, AConfig, LProfile,
      LExecutorPath, LFinalPrompt);

    if Assigned(FTestCliDispatcher) then
      FCliDispatcher := FTestCliDispatcher
    else
      FCliDispatcher := TCLIDispatcher.Create;

    // The sink -- not bare Self._OnCli* pointers -- is what survives a mid-run
    // teardown (see TAefosCliSink). We keep a hold + a raw view for the teardown
    // drain; the sink self-holds until its terminal Complete.
    LSink := TAefosCliSink.Create(Self, FLive);
    FCliSinkHold := LSink;
    FCliSinkObj := LSink;
    // Bound to typed locals so each binds as a method POINTER, not a call (the
    // FPC delphi-mode idiom).
    LOnChunk := LSink.DeliverChunk;
    LOnComplete := LSink.DeliverComplete;
    LOnError := LSink.DeliverError;
    FCliRun := FCliDispatcher.Dispatch(LRequest, LOnChunk, LOnComplete,
      LOnError);
    // The session only counts as started once the dispatch actually went out, so
    // a failed spawn does not leave the next turn trying to --resume a session
    // that never existed. Only for a PINNED id (the one we minted); a CAPTURED
    // id is born in the run's own output and is picked up in _OnCliComplete.
    if LProfile.SessionSupport = ssPinned then
      FSessionStarted := True;
  except
    on E: Exception do
    begin
      FBusy := False;
      // Dispatch threw synchronously (executor not found / spawn failed): no
      // Deliver* ever ran, so drop the sink's OWN self-hold too, else it leaks
      // one object per failed Send. Do this before dropping our refs.
      if FCliSinkObj <> nil then
        TAefosCliSink(FCliSinkObj).Abandon;
      FCliSinkHold := nil;
      FCliSinkObj := nil;
      FCliRun := nil;
      _JsFooter(UTF16ToUTF8(UnicodeString(E.Message)), True);
    end;
  end;
end;

procedure TAefosLazChatController._OnCliChunk(const AChunk: UnicodeString);
begin
  // Runs on the IDE main thread (the dispatcher marshals via TThread.Queue), so
  // ExecuteScript is safe here. Every stdout chunk lands in the assistant bubble
  // exactly as the Ollama path's content chunks do -- same render protocol.
  if AChunk <> '' then
  begin
    FCurrentAssistant := FCurrentAssistant + AChunk;
    _JsAppend(UTF16ToUTF8(AChunk));
  end;
end;

procedure TAefosLazChatController._OnCliError(const AMessage: UnicodeString);
begin
  // The CLI's captured stderr on a non-zero exit. Rendered INTO the turn (not as
  // a footer) because Complete follows immediately and owns the settle -- the
  // user sees the CLI's own reason above it.
  if AMessage <> '' then
  begin
    FCurrentAssistant := FCurrentAssistant + AMessage;
    _JsAppend(UTF16ToUTF8(AMessage));
  end;
end;

procedure TAefosLazChatController._OnCliComplete(const AExitCode: Integer;
  const ADurationMs: Cardinal);
var
  // UnicodeString, NOT string: this unit compiles in delphi mode, where `string`
  // is a UTF-8 AnsiString, and a `var`/`out` argument has to match EXACTLY
  // (FPC 3069). The seam declares UnicodeString for precisely this reason -- the
  // same boundary discipline IAefosCliHarnessInputs already uses.
  LRawId: UnicodeString;
begin
  // The single terminal event of a run (the dispatcher guarantees it fires once,
  // including on cancel and on timeout), so this is where the turn settles.
  FBusy := False;
  FCliRun := nil;
  // Conversation continuity for the CLIs that mint their OWN id (Codex, the
  // local agent CLI): scrape it out of this run's output now, so the next turn
  // resumes instead of starting over. FCurrentAssistant is the right buffer --
  // _OnCliChunk (stdout) AND _OnCliError (stderr) both append to it, and the
  // agent CLI prints its `session: <id>` on stderr. Read once per conversation.
  //   Mirrors TCommandExecutor's completion capture; the RAD Studio edition is
  // the contract, this is the port.
  if (FSessionId = '') and (FCliProfile <> nil) and
     (FCliProfile.SessionSupport = ssCaptured) and
     FCliProfile.TryCaptureSessionId(FCurrentAssistant, LRawId) then
  begin
    FSessionId := LRawId;
    FSessionStarted := True;
  end;
  // A non-zero exit already had its stderr appended by _OnCliError; the footer
  // just marks the turn failed. Exit 0 settles with no token line, matching the
  // Ollama path's Done.
  if AExitCode = 0 then
    _JsFooter('', False)
  else
    _JsFooter(Format('The AI CLI exited with code %d.', [AExitCode]), True);
  // Turn settled -- record the assistant reply, then hand off to the next
  // send-during-run message, if any.
  _CommitTurn;
  _DrainQueuedMessage;
end;

function TAefosLazChatController._FocusInWebView: Boolean;
var
  LFocused: HWND;
  LHost: HWND;
begin
  // Walk the Win32 focus chain up to the host control: WebView2 in windowed mode
  // parents its Chrome_WidgetWin_* children under the HWND we passed to
  // CreateCoreWebView2Controller (TAefosLazWebView.Handle), so one walk covers
  // every input surface the page owns. Mirrors ChatPanel._FocusInChat, minus the
  // composition anchor (we are windowed - there is no hidden anchor window).
  Result := False;
  if not Assigned(FWeb) or (not FWeb.HandleAllocated) then
    Exit;
  LHost := FWeb.Handle;
  if LHost = 0 then
    Exit;
  // GetFocus is per calling thread; this only ever runs on the main thread, the
  // same queue the host and its Chrome children were created on.
  LFocused := GetFocus;
  while LFocused <> 0 do
  begin
    if LFocused = LHost then
      Exit(True);
    LFocused := GetParent(LFocused);
  end;
end;

procedure TAefosLazChatController._DispatchOllama(const AText: string;
  const AConfig: TConfig);
var
  LModel: UnicodeString;
  LBaseUrl: UnicodeString;
  LBody: UnicodeString;
  LSink: TAefosOllamaSink;
begin
  // Resolve the model the SAME way the header selector reports it (per-executor
  // pick first, configured Model as the fallback). Reading AConfig.Model alone
  // would make a pick in the header a no-op -- the header would show one model
  // and the dispatch would send another.
  LModel := _ResolveCurrentModel(AConfig.Executor, AConfig);
  LBaseUrl := AConfig.OllamaBaseUrl;
  if Trim(LModel) = '' then
  begin
    _RenderAssistantLine(CNoModelNotice, True);
    Exit;
  end;

  // Agent mode owns the whole turn: it runs the tool loop against the IDE's own
  // MCP server instead of a single plain completion. Branch AFTER the model
  // resolution above so both modes dispatch exactly the model the header shows.
  if FAgentMode then
  begin
    _DispatchOllamaAgent(AText, LModel, AConfig);
    Exit;
  end;

  // Turn starts: dsClear shows "working..." and flips the composer to Stop.
  // Guarded so a synchronous throw (request build, transport spawn) can never
  // strand FBusy=True -- the 0.30.0 "stuck on working..." bug class.
  FBusy := True;
  try
    _JsClear;

    // Build the /api/chat body (stream=true). Cross to UTF-16 for the
    // delphiunicode request builder; the single user turn is the prompt.
    LBody := OllamaBuildChatRequest(LModel,
      [TOllamaMessage.New('user', UTF8ToUTF16(AText))], True);

    if Assigned(FTestTransport) then
      FTransport := FTestTransport
    else
      FTransport := NewOllamaTransport;

    // The sink -- not a bare Self._OnChunk -- is what survives a mid-stream
    // teardown (see TAefosOllamaSink). We keep a hold + a raw view for the
    // teardown drain; the sink self-holds until its terminal chunk.
    LSink := TAefosOllamaSink.Create(Self, FLive);
    FSinkHold := LSink;
    FSinkObj := LSink;
    FTransport.ChatStream(LBaseUrl, LBody, LSink.Deliver);
  except
    on E: Exception do
    begin
      FBusy := False;
      // Same as the CLI path: a synchronous ChatStream throw means no terminal
      // Deliver ran, so release the sink's own self-hold or it leaks.
      if FSinkObj <> nil then
        TAefosOllamaSink(FSinkObj).Abandon;
      FSinkHold := nil;
      FSinkObj := nil;
      _JsFooter(UTF16ToUTF8(UnicodeString(E.Message)), True);
    end;
  end;
end;

// --- Agent mode (local model) ----------------------------------------------

procedure TAefosLazChatController._HandleSetMode(const AAgent: Boolean);
begin
  // Intent for the NEXT turn only: an in-flight turn keeps the mode it started
  // with (flipping mid-stream would swap the dispatch shape under a running
  // loop). Mirrors the Delphi OnSetAgentMode, which likewise only sets a flag.
  FAgentMode := AAgent;
end;

procedure TAefosLazChatController._CancelAgentTurn;
begin
  // Safe at any time: the session is refcounted and its Cancel is idempotent and
  // no-ops after the turn ended.
  if Assigned(FAgentSession) then
    try
      FAgentSession.Cancel;
    except
      // Cancel also runs from teardown -- it must never raise.
    end;
end;

function TAefosLazChatController._AgentHostReady: Boolean;
var
  LPipeName: UnicodeString;
begin
  // EnsureMcpHost is idempotent and self-guarded (it returns False rather than
  // raise). A True here means an external CLI agent turn can reach the aefos tool
  // surface through the bridge; a False means we should say so and fall back.
  Result := TAefosLazAgentGate.EnsureMcpHost(LPipeName);
end;

procedure TAefosLazChatController._DispatchOllamaAgent(const AText: string;
  const AModel: UnicodeString; const AConfig: TConfig);
var
  LPipeName: UnicodeString;
begin
  // The tool surface is our OWN in-process MCP server. Start it if the user has
  // not toggled it on -- that is a convenience, NOT a grant: every mutating tool
  // still meets the server's first-write consent dialog. If it will not start we
  // say so instead of silently answering as a plain chat: Agent mode that cannot
  // touch the IDE must never look like Agent mode that can.
  if not TAefosLazAgentGate.EnsureMcpHost(LPipeName) then
  begin
    _RenderAssistantLine(CAgentNoHostNotice, True);
    Exit;
  end;

  FBusy := True;
  try
    _JsClear;
    // The session is refcounted and jointly owned with its worker, so holding it
    // here is safe and dropping it mid-turn is safe too (see Aefos.Lazarus.
    // ChatAgent's lifetime note). FLive is the SAME token the chunk sinks use.
    FAgentSession := TAefosLazAgentGate.StartTurn(
      TAefosAgentTurn.New(AConfig.OllamaBaseUrl, AModel, UTF8ToUTF16(AText),
        LPipeName),
      FLive as IAefosAgentLiveToken,
      _OnAgentDelta, _OnAgentNotice, _OnAgentDone);
  except
    on E: Exception do
    begin
      // A synchronous throw (thread spawn) must never strand the composer on
      // "working..." -- the 0.30.0 stuck-busy bug class.
      FBusy := False;
      FAgentSession := nil;
      _JsFooter(UTF16ToUTF8(UnicodeString(E.Message)), True);
    end;
  end;
end;

procedure TAefosLazChatController._OnAgentDelta(const AText: UnicodeString);
begin
  // MAIN thread (the session marshals via Synchronize), so _Run is safe here.
  FCurrentAssistant := FCurrentAssistant + AText;
  _JsAppend(UTF16ToUTF8(AText));
end;

procedure TAefosLazChatController._OnAgentNotice(const AText: UnicodeString);
begin
  // Status lines ("Running IDE tool: X", degradation notices) share the
  // assistant block: this slice has no separate notice lane in the shell, and a
  // silent loop reads as a hang. Kept on its own line so it never glues onto the
  // model's prose.
  _JsAppend(sLineBreak + '_' + UTF16ToUTF8(AText) + '_' + sLineBreak);
end;

procedure TAefosLazChatController._OnAgentDone(const AError: UnicodeString);
begin
  // MAIN thread. Exactly one of these per turn (the session guarantees it), so
  // the composer always comes back.
  FBusy := False;
  FAgentSession := nil;
  if AError <> '' then
    _JsFooter(UTF16ToUTF8(AError), True)
  else
    _JsFooter('', False);
  // Turn settled -- record the assistant reply, then hand off to the next
  // send-during-run message, if any.
  _CommitTurn;
  _DrainQueuedMessage;
end;

// --- Header model selector -------------------------------------------------

function TAefosLazChatController._ResolveCurrentModel(const AKind: TExecutorKind;
  const AConfig: TConfig): UnicodeString;
begin
  // Prefer the model remembered for THIS executor (so switching executor never
  // carries one provider's model into another), and fall back to the single
  // configured Model when nothing is remembered yet. That fallback is what makes
  // a fresh install show the model the user set in Options instead of the shell's
  // "model" placeholder.
  //
  // This resolution feeds BOTH the header payload and the dispatch, on purpose:
  // what the header SHOWS is then exactly what the next turn RUNS. Note that is a
  // deliberate divergence from Delphi, not a copy of it — Register's OnGetModels
  // uses this order for DISPLAY only, while Delphi's dispatch
  // (TCommandExecutor._BuildArgsFromConfig) resolves through a session-scoped
  // FModel that never reads this store, so a pick made in an earlier session is
  // displayed but not dispatched until the user touches the header again. Here a
  // pick persists and is honoured across sessions (and across both IDEs — the
  // store is the shared models.json). Options keeps config.Model and the stored
  // pick in sync on every save, so the two only differ after a header-only pick.
  Result := TExecutorModelStore.SelectedModelForKind(AKind);
  if Trim(Result) = '' then
    Result := AConfig.Model;
end;

procedure TAefosLazChatController._PushModelsJson(const AKind: TExecutorKind;
  const AModels: TArray<UnicodeString>; const ACurrent: UnicodeString);
var
  LArr: string;
  LJson: string;
  LEffort: string;
  LEffortSupported: Boolean;
  LFor: Integer;
begin
  // Same payload shape the Delphi Register.OnGetModels builds and the shell's
  // window.dsModels consumes: {models,current,executor,effort,effortSupported}.
  // Unlike the Delphi builder (which concatenates ids raw, because its lists are
  // curated or user-typed) every value here goes through _JsEncode: this list can
  // come from the LIVE /api/tags reply, and one stray quote in a model tag would
  // otherwise break the ExecuteScript payload -- i.e. reproduce the very blank
  // dropdown this change fixes.
  LArr := '';
  for LFor := 0 to High(AModels) do
  begin
    if LArr <> '' then
      LArr := LArr + ',';
    LArr := LArr + _JsEncode(UTF16ToUTF8(AModels[LFor]));
  end;
  // effortSupported now answers the REAL capability. It was hard-FALSE while the
  // external-CLI dispatch did not exist -- an effort pill would have set a value
  // nothing could ever send. Now that a turn goes out through BuildDispatchArgs,
  // the picked effort genuinely reaches the CLI (_BuildDispatchContext), so the
  // pill is honest. The capability itself is NOT re-derived here: it is read from
  // the shared TExecutorCapabilities, the same rule the RAD Studio header
  // consults, so the two IDEs cannot disagree about which executor has an effort
  // control. Both values come from the shared store, so a pick made in either
  // IDE shows in the other.
  LEffortSupported := TExecutorCapabilities.SupportsReasoningEffort(AKind);
  LEffort := '';
  if LEffortSupported then
    LEffort := UTF16ToUTF8(TReasoningEfforts.CliToken(
      TReasoningEfforts.FromCliToken(
        TExecutorModelStore.SelectedEffortForKind(AKind))));
  LJson := '{"models":[' + LArr + '],"current":'
    + _JsEncode(UTF16ToUTF8(ACurrent)) + ',"executor":'
    + _JsEncode(UTF16ToUTF8(TExecutorKinds.ExecutorKindDisplayName(AKind)))
    + ',"effort":' + _JsEncode(LEffort) + ',"effortSupported":'
    + LowerCase(BoolToStr(LEffortSupported, True)) + '}';
  _Run('window.dsModels && window.dsModels(' + LJson + ');');
end;

procedure TAefosLazChatController._HandleGetModels;
var
  LConfig: TConfig;
  LSink: TAefosModelsSink;
begin
  LConfig := _LoadConfig;
  // Every executor except the local runtime answers straight from the shared
  // store -- the same models.json the RAD Studio Options page maintains.
  if LConfig.Executor <> ekOllama then
  begin
    _PushModelsJson(LConfig.Executor,
      TExecutorModelStore.ModelsForKind(LConfig.Executor),
      _ResolveCurrentModel(LConfig.Executor, LConfig));
    Exit;
  end;

  // ekOllama: the authoritative LIST is whatever `ollama pull` actually fetched,
  // so it can only come from the endpoint (GET /api/tags) and is therefore async.
  // The CURRENT pick is NOT: it lives in the shared store, on disk, and is known
  // right now. Push it FIRST, so a change made elsewhere (an Options save, a pick
  // in the RAD Studio chat) shows the moment the shell asks -- instead of the
  // header staying stale for a whole network round-trip to display something we
  // already had in hand. The async reply pushes again with the live list; the
  // payload is idempotent, so that second push only completes the dropdown.
  _PushModelsJson(ekOllama, TExecutorModelStore.ModelsForKind(ekOllama),
    _ResolveCurrentModel(ekOllama, LConfig));

  // Deliberately AFTER the push above. This guard exists so a focus flap does not
  // pile up one worker per toggle -- but it used to return having pushed NOTHING,
  // so a request that arrived while an earlier fetch was still running was
  // silently DROPPED and the header kept its stale value until the next focus.
  // Closing Options while a fetch was in flight hit exactly that.
  if (FModelsSinkObj <> nil) and (not TAefosModelsSink(FModelsSinkObj).Ended) then
    Exit;
  try
    if Assigned(FTestTransport) then
      FModelsTransport := FTestTransport
    else
      FModelsTransport := NewOllamaTransport;
    LSink := TAefosModelsSink.Create(Self, FLive);
    FModelsSinkHold := LSink;
    FModelsSinkObj := LSink;
    FModelsTransport.FetchModels(LConfig.OllamaBaseUrl, LSink.Deliver);
  except
    on E: Exception do
    begin
      // A synchronous throw (transport spawn) leaves no sink to release the
      // handles. The selector itself needs no rescue push here any more: the
      // store's seeds and the current pick already went out above, before the
      // fetch was ever attempted.
      FModelsSinkHold := nil;
      FModelsSinkObj := nil;
    end;
  end;
end;

procedure TAefosLazChatController._OnModels(const AModels: TArray<UnicodeString>;
  const AError: UnicodeString);
var
  LConfig: TConfig;
  LList: TArray<UnicodeString>;
begin
  // Runs on the IDE main thread (see TAefosModelsSink), so _Run is safe here.
  // Re-read the config rather than caching it at fetch time: the user may have
  // changed executor in Options while /api/tags was in flight.
  LConfig := _LoadConfig;
  LList := AModels;
  // A dead endpoint (AError) or a machine with nothing pulled yet would leave the
  // dropdown empty -- exactly the reported bug. Degrade to the shared store's
  // curated seeds so the header always offers something to pick.
  if (AError <> '') or (Length(LList) = 0) then
    LList := TExecutorModelStore.ModelsForKind(ekOllama);
  _PushModelsJson(ekOllama, LList, _ResolveCurrentModel(ekOllama, LConfig));
end;

procedure TAefosLazChatController._HandleSetModel(const AModel: string);
var
  LConfig: TConfig;
begin
  if Trim(AModel) = '' then
    Exit;
  LConfig := _LoadConfig;
  // Remember the pick PER EXECUTOR in the shared store, mirroring the Delphi
  // OnSetModel. _ResolveCurrentModel reads it back, so the pick survives a
  // reopen AND is what the next dispatch actually sends -- and because the store
  // is the shared one, a model picked here shows up in the RAD Studio chat too.
  TExecutorModelStore.SetSelectedModelForKind(LConfig.Executor,
    UTF8ToUTF16(Trim(AModel)));
end;

procedure TAefosLazChatController._HandleSetEffort(const AEffort: string);
var
  LConfig: TConfig;
begin
  LConfig := _LoadConfig;
  // Only executors that HAVE an effort control may persist one -- a pill posting
  // for an executor without one would otherwise write a value nothing reads.
  if not TExecutorCapabilities.SupportsReasoningEffort(LConfig.Executor) then
    Exit;
  // Round-trip through the vocabulary so only a known token is ever stored
  // (unknown => Default => ''), which is what _BuildDispatchContext reads back.
  // Persisted PER EXECUTOR in the shared store, so a pick here shows up in the
  // RAD Studio chat too.
  TExecutorModelStore.SetSelectedEffortForKind(LConfig.Executor,
    TReasoningEfforts.CliToken(
      TReasoningEfforts.FromCliToken(UTF8ToUTF16(Trim(AEffort)))));
end;

// --- Command surface (chips / picker / settings) ---------------------------

procedure TAefosLazChatController._HandleActionChip(const AAction: string);
begin
  // Map the empty-state chip to its slash command, exactly as the Delphi panel
  // does (action -> PrefillInput). A trailing space leaves the caret ready for the
  // target. Unknown actions are ignored (defensive; the shell only sends these
  // six -- explain/refactor/test/docs/find/optimize).
  if SameText(AAction, 'explain') then
    _JsPrefill('/explain ')
  else if SameText(AAction, 'refactor') then
    _JsPrefill('/refactor ')
  else if SameText(AAction, 'test') then
    _JsPrefill('/test ')
  else if SameText(AAction, 'docs') then
    _JsPrefill('/docs ')
  else if SameText(AAction, 'find') then
    _JsPrefill('/find ')
  else if SameText(AAction, 'optimize') then
    _JsPrefill('/optimize ');
end;

function TAefosLazChatController._TryHandleSlashCommand(const AText: string): Boolean;
var
  LCmd: string;
begin
  // Only the built-ins that map to a UI action HERE are intercepted; everything
  // else (the agentic /explain.. etc.) falls through and is dispatched to the
  // model as normal text -- the Lazarus slice has no command-guide injection yet.
  Result := True;
  LCmd := LowerCase(Trim(AText));
  if LCmd = '/mcp' then
    _HandleOpenMcp
  else if (LCmd = '/command') or (LCmd = '/prompt') then
    // /command (alias /prompt): open the HTML command editor to author a custom
    // slash-command. Mirrors ChatPanel._DispatchCommand's /command|/prompt branch.
    _OpenCommandEditorNew
  else if (LCmd = '/new') or (LCmd = '/reset') then
    _HandleNewSession
  else
    Result := False;
end;

procedure TAefosLazChatController._HandlePicker;
var
  LB: TBuiltInCommand;
  LJson: string;
  LFirst: Boolean;
  LReg: TAefosLazCommandRegistry;
  LList: TArray<TAefosLazCommandMeta>;
  LI: Integer;
begin
  // Build the picker payload the SAME way _PushModelsJson builds its list: JSON
  // assembled through _JsEncode (mirrors TRenderProtocol.JSEncode), so a name or
  // description with a quote can never break the ExecuteScript payload. Source is
  // the shared Core.BuiltInCommands table (badged "builtin") PLUS the stored user
  // commands from the registry (badged "command") -- exactly the two sources the
  // Delphi picker feeds (_SendPickerCommands: BuiltInCommands + FRegistry.List).
  LJson := '[';
  LFirst := True;
  for LB in BuiltInCommands do
  begin
    if not LFirst then
      LJson := LJson + ',';
    LFirst := False;
    LJson := LJson + '{"name":' + _JsEncode(LB.Name) + ',"desc":'
      + _JsEncode(LB.Description) + ',"badge":"builtin"}';
  end;
  LReg := _NewCommandRegistry;
  try
    LList := LReg.List;
  finally
    LReg.Free;
  end;
  for LI := 0 to High(LList) do
  begin
    if not LFirst then
      LJson := LJson + ',';
    LFirst := False;
    LJson := LJson + '{"name":' + _JsEncode(LList[LI].Name) + ',"desc":'
      + _JsEncode(LList[LI].Description) + ',"badge":"command"}';
  end;
  LJson := LJson + ']';
  _Run('window.dsSetCommands && window.dsSetCommands(' + LJson + ');');
end;

procedure TAefosLazChatController._HandleOpenSettings;
begin
  // IDE-free by design: the chat window wires this to the IDE Options deep-link
  // (LazarusIDE.DoOpenIDEOptions). nil in the proof harness -- the gear no-ops.
  if Assigned(FOnOpenSettings) then
    FOnOpenSettings;
end;

procedure TAefosLazChatController._PushTrialBadge;
var
  LText: string;
begin
  // NEVER let a license read break the chat. The gate touches an on-disk record
  // and a clock; if any of that raises, the correct outcome is "no badge", not a
  // dead header -- the RAD Studio side guards the same call the same way
  // (Aefos.Lazarus.Register.pas:316 wraps StatusText in try/except for the menu
  // caption). TrialBadge already returns '' when the user is NOT on trial, and
  // the shell hides the element on '', so the non-trial path needs no branch here.
  LText := '';
  _Run('window.dsSetTrial && window.dsSetTrial(' + _JsEncode(LText) + ');');
end;

procedure TAefosLazChatController._HandleLicense;
begin
  // Nothing to activate any more: the product is free software with no tiers.
  // The entry point survives only because the shell may still post the message;
  // it now just re-pushes the (empty) badge.
  _PushTrialBadge;
end;

// --- User commands (/command) ----------------------------------------------

function TAefosLazChatController._ResolveCommandGlobalRoot: string;
begin
  // The per-user global catalogue root -- %USERPROFILE%\.aefos\commands, the SAME
  // root the Delphi registry's global default resolves (GetEnvironmentVariable
  // 'USERPROFILE'). A test override wins so a proof never writes into the real one.
  // Qualified SysUtils.GetEnvironmentVariable: the Windows unit's 3-arg one would
  // otherwise shadow it (the same trap the constructor guards for APPDATA).
  if FCommandGlobalRoot <> '' then
    Result := UTF16ToUTF8(FCommandGlobalRoot)
  else
    Result := SysUtils.GetEnvironmentVariable('USERPROFILE');
end;

function TAefosLazChatController._ResolveCommandProjectRoot: string;
begin
  // The active project's root (its .aefos\commands is the "This project" scope).
  // Resolved through the composed seam so the controller stays IDE-free; '' when
  // no project is open (a project-scoped save then fails with an inline notice,
  // exactly like the Delphi registry's ECommandFolderUnavailable).
  if FCommandProjectRoot <> '' then
    Result := UTF16ToUTF8(FCommandProjectRoot)
  else if Assigned(FOnResolveProjectRoot) then
    Result := UTF16ToUTF8(FOnResolveProjectRoot())
  else
    Result := '';
end;

function TAefosLazChatController._NewCommandRegistry: TAefosLazCommandRegistry;
begin
  // Bound to this controller's catalogue-root seams (of object method pointers).
  // Created per call and freed by the caller -- the Delphi registry likewise holds
  // no cache and re-reads disk on each call.
  Result := TAefosLazCommandRegistry.Create(_ResolveCommandProjectRoot,
    _ResolveCommandGlobalRoot);
end;

procedure TAefosLazChatController._OpenCommandEditorNew;
begin
  // Open the shared shell's command editor on a blank "new" form. Mirrors
  // ChatPanel._OpenCommandEditorNew (LObj.AddPair('isNew', True)) INCLUDING its
  _Run('window.dsShowCommandEditor && window.dsShowCommandEditor({"isNew":true});');
end;

procedure TAefosLazChatController._SendCommandList;
var
  LReg: TAefosLazCommandRegistry;
  LList: TArray<TAefosLazCommandMeta>;
  LJson: string;
  LFirst: Boolean;
  LI: Integer;
begin
  // command:list -> window.dsSetCommandList: the editable commands (name +
  // description) for the modal's "Edit existing" dropdown. Mirrors _SendCommandList.
  LReg := _NewCommandRegistry;
  try
    LList := LReg.List;
  finally
    LReg.Free;
  end;
  LJson := '[';
  LFirst := True;
  for LI := 0 to High(LList) do
  begin
    if not LFirst then
      LJson := LJson + ',';
    LFirst := False;
    LJson := LJson + '{"name":' + _JsEncode(LList[LI].Name)
      + ',"description":' + _JsEncode(LList[LI].Description) + '}';
  end;
  LJson := LJson + ']';
  _Run('window.dsSetCommandList && window.dsSetCommandList(' + LJson + ');');
end;

procedure TAefosLazChatController._LoadCommandIntoEditor(const AName: string);
var
  LReg: TAefosLazCommandRegistry;
  LCmd: TAefosLazCanonicalCommand;
  LLoaded: Boolean;
  LScope: string;
  LJson: string;
begin
  // command:load:<name> -> re-open the editor prefilled for editing. Mirrors
  // ChatPanel._LoadCommandIntoEditor: isNew=false, canDelete=false (the registry
  // exposes no delete), scope reflecting the catalogue the command lives in.
  LReg := _NewCommandRegistry;
  try
    LLoaded := LReg.LoadCommand(AName, LCmd);
  finally
    LReg.Free;
  end;
  if not LLoaded then
  begin
    _RenderAssistantLine(Format('Could not load command "%s".', [AName]), True);
    Exit;
  end;
  if LCmd.Scope = lcsGlobal then
    LScope := 'global'
  else
    LScope := 'project';
  LJson := '{"isNew":false,"canDelete":false'
    + ',"name":' + _JsEncode(LCmd.Name)
    + ',"description":' + _JsEncode(LCmd.Description)
    + ',"prompt":' + _JsEncode(LCmd.Instructions)
    + ',"scope":' + _JsEncode(LScope) + '}';
  _Run('window.dsShowCommandEditor && window.dsShowCommandEditor(' + LJson + ');');
end;

procedure TAefosLazChatController._SaveCommandFromJson(const AJson: string);
var
  LVal: TJSONValue;
  LObj: TJSONObject;
  LName, LDesc, LPrompt, LScopeStr, LError: string;
  LScope: TAefosLazCommandScope;
  LReg: TAefosLazCommandRegistry;
  LValid: Boolean;

  function J(const AKey: UnicodeString): string;
  var
    LV: TJSONValue;
  begin
    // Compat.Json is delphiunicode (UTF-16); convert each value back to this
    // unit's UTF-8 string at the boundary, like every other core seam here.
    Result := '';
    LV := LObj.GetValue(AKey);
    if LV <> nil then
      Result := UTF16ToUTF8(LV.Value);
  end;

begin
  // command:save:<json> -> the SOLE registry writer (mirrors _SaveCommandFromJson).
  // The shell already validated the name shape; the registry validates again and
  // reports any failure, which we surface inline (the Delphi panel's stderr line).
  LValid := False;
  LName := '';
  LDesc := '';
  LPrompt := '';
  LScopeStr := '';
  LVal := TJSONObject.ParseJSONValue(UTF8ToUTF16(AJson));
  try
    if LVal is TJSONObject then
    begin
      LObj := TJSONObject(LVal);
      LName := J('name');
      LDesc := J('description');
      LPrompt := J('prompt');
      LScopeStr := J('scope');
      LValid := True;
    end;
  finally
    LVal.Free; // nil-safe
  end;
  if not LValid then
  begin
    _RenderAssistantLine('Could not save the command: invalid payload.', True);
    Exit;
  end;
  // Scope defaults to project; only an explicit "global" retargets the write
  // (mirrors _SaveCommandFromJson's csProject default).
  if SameText(LScopeStr, 'global') then
    LScope := lcsGlobal
  else
    LScope := lcsProject;
  LReg := _NewCommandRegistry;
  try
    if LReg.SaveCommand(LName, LDesc, LPrompt, LScope, LError) then
      _RenderAssistantLine(Format('Command /%s saved.', [LName]), False)
    else
      _RenderAssistantLine('Could not save the command: ' + LError, True);
  finally
    LReg.Free;
  end;
  // Refresh the "/" picker so a freshly saved command is immediately discoverable
  // (mirrors _RefreshCommandListIfOpen re-feeding the list after a save).
  _HandlePicker;
end;

procedure TAefosLazChatController._NotifyCommandDeleteUnsupported(
  const AName: string);
begin
  // Mirrors ChatPanel._DeleteCommand: the registry exposes no delete contract
  // (canDelete stays false, so the button is hidden), so this is only reached
  // defensively -- say so plainly rather than become a second writer.
  _RenderAssistantLine(Format('Deleting "/%s" is not supported yet; delete its ' +
    '.aefos\commands\%s folder to remove it.', [AName, AName]), True);
end;

function TAefosLazChatController._ExpandStoredCommand(
  const AText: string): string;
var
  LName, LBody: string;
  LReg: TAefosLazCommandRegistry;
  LBuiltin: TBuiltInCommand;
  LUserText: string;
begin
  // A bare /name of a saved command expands to its prompt body for dispatch.
  // Returns '' for anything else -> the caller dispatches the raw text.
  Result := '';
  LName := Trim(AText);
  if (LName = '') or (LName[1] <> '/') then
    Exit;
  Delete(LName, 1, 1);
  LName := Trim(LName);
  // Exact single-token name only: trailing args make it free text (mirror Delphi,
  // where "/foo bar" fails LoadBody('foo bar') and falls through to raw text).
  if (LName = '') or (Pos(' ', LName) > 0) then
    Exit;
  if not TAefosLazCommandRegistry.IsValidCommandName(LName) then
    Exit;
  // A built-in name is never a stored expansion: built-ins fall through as raw
  // text (Lazarus injects no built-in guide yet) and a built-in shadows a
  // same-named stored command, exactly as Delphi checks built-ins before LoadBody.
  if FindBuiltInCommand(LName, LBuiltin, LUserText) then
    Exit;
  LReg := _NewCommandRegistry;
  try
    LReg.LoadBody(LName, LBody); // LBody stays '' when the command does not exist
  finally
    LReg.Free;
  end;
  Result := LBody;
end;

// --- Session history -------------------------------------------------------

function TAefosLazChatController._Store: IAefosLazSessionStore;
begin
  // Bound to the CURRENT config root (a test sets ConfigRoot AFTER Create). Cheap
  // per call: the store is a thin value object that BORROWS the process-wide shared
  // SQLite connection (TAefosLazSQLiteDb.Shared) -- no reopen per call. SQLite-backed:
  // the SHARED %APPDATA%\Aefos\aefos.db, one brain with the Delphi edition (both
  // directions); it migrates the legacy JSON sessions once.
  Result := TAefosLazSqliteSessionStore.Create(FConfigRoot);
end;

procedure TAefosLazChatController._RecordUserTurn(const AText: string);
begin
  // Start a session on the first user turn: the id keys the on-disk file, the
  // title is the first message (ctx line + list title), mirroring the Delphi
  // FSessionTitle/FSessionCount.
  if FStoreSessionId = '' then
  begin
    FStoreSessionId := NewSessionId;
    FSessionCreated := Now;
  end;
  if Trim(FSessionTitle) = '' then
    FSessionTitle := UTF8ToUTF16(Trim(AText));
  FConversation.Add(TAefosSessionMessage.New('user', UTF8ToUTF16(AText)));
  Inc(FSessionCount);
  // A fresh assistant accumulator for this turn.
  FCurrentAssistant := '';
  _PushSessionInfo;
end;

procedure TAefosLazChatController._CommitTurn;
begin
  // Append the assistant reply (if the turn produced any text) and persist. A
  // turn that only errored with no streamed text still saves the user message.
  if FCurrentAssistant <> '' then
  begin
    FConversation.Add(TAefosSessionMessage.New('assistant', FCurrentAssistant));
    FCurrentAssistant := '';
  end;
  _SaveSession;
end;

procedure TAefosLazChatController._SaveSession;
var
  LEntry: TAefosSessionEntry;
begin
  // Nothing to persist until a session has started (an id + at least the user
  // turn). Guards the settle callbacks that can fire with no live session.
  if (FStoreSessionId = '') or (FConversation.Count = 0) then
    Exit;
  LEntry := Default(TAefosSessionEntry);
  LEntry.Id := FStoreSessionId;
  if Trim(FSessionTitle) = '' then
    LEntry.Title := '(untitled)'
  else
    LEntry.Title := FSessionTitle;
  if FSessionCreated = 0 then
    FSessionCreated := Now;
  LEntry.Created := FSessionCreated;
  LEntry.Updated := Now;
  LEntry.Count := FSessionCount;
  LEntry.Messages := FConversation.ToArray;
  try
    _Store.Save(LEntry);
  except
    // Persistence is best-effort; a store error must never break the chat turn.
  end;
end;

procedure TAefosLazChatController._PushSessionInfo;
begin
  // window.dsSetSessionInfo(title, count, timeText). timeText is empty (the ctx
  // line shows title + count), matching the Delphi _PushSessionInfo.
  _Run('window.dsSetSessionInfo && window.dsSetSessionInfo('
    + _JsEncode(UTF16ToUTF8(FSessionTitle)) + ', ' + IntToStr(FSessionCount)
    + ', "");');
end;

procedure TAefosLazChatController._ResetConversation;
begin
  FConversation.Clear;
  FStoreSessionId := '';
  FSessionTitle := '';
  FSessionCount := 0;
  FSessionCreated := 0;
  FCurrentAssistant := '';
  // Clear the shell feed + restore the empty state (the shell owns dsResetThread).
  _Run('window.dsResetThread && window.dsResetThread();');
  _PushSessionInfo;
end;

procedure TAefosLazChatController._HandleNewSession;
begin
  // Persist the current conversation BEFORE clearing so it stays in history
  // (mirrors ChatPanel's hdr:newsession: _SaveCurrentSession then reset).
  _SaveSession;
  // Adopting a fresh session orphans any queued sends.
  FQueuedMessages.Clear;
  _JsQueued(0);
  _ResetConversation;
end;

procedure TAefosLazChatController._HandleOpenSessions;
var
  LEntries: TArray<TAefosSessionEntry>;
  LJson: UnicodeString;
begin
  // Persist the live conversation first so the CURRENT row reflects the latest
  // title/count even before a reply completed (mirrors _OpenSessionsPanel).
  _SaveSession;
  LEntries := _Store.List;
  LJson := TAefosSessionJson.BuildSessionsListJson(LEntries, FStoreSessionId);
  _Run('window.dsShowSessions && window.dsShowSessions('
    + UTF16ToUTF8(LJson) + ');');
end;

procedure TAefosLazChatController._HandleResumeSession(const AId: string);
var
  LEntry: TAefosSessionEntry;
  LId: UnicodeString;
  LMsgs: UnicodeString;
  LFor: Integer;
begin
  LId := UTF8ToUTF16(Trim(AId));
  if not _Store.TryLoad(LId, LEntry) then
    Exit;
  // Adopting another conversation orphans the current send-during-run queue.
  FQueuedMessages.Clear;
  _JsQueued(0);
  // Re-seed the live conversation so a later _SaveSession round-trips it rather
  // than overwriting it empty (the Delphi resume-then-save corruption guard).
  FConversation.Clear;
  for LFor := 0 to High(LEntry.Messages) do
    FConversation.Add(LEntry.Messages[LFor]);
  FStoreSessionId := LEntry.Id;
  FSessionTitle := LEntry.Title;
  FSessionCount := LEntry.Count;
  FSessionCreated := LEntry.Created;
  FCurrentAssistant := '';
  // Put the stored conversation back on screen. Empty/[] clears the feed so the
  // switch is visible; otherwise dsReplay rebuilds it.
  LMsgs := TAefosSessionJson.BuildMessagesJson(LEntry.Messages);
  if (Trim(LMsgs) = '') or (Trim(LMsgs) = '[]') then
    _Run('window.dsResetThread && window.dsResetThread();')
  else
    _Run('window.dsReplay && window.dsReplay(' + UTF16ToUTF8(LMsgs) + ');');
  _PushSessionInfo;
end;

procedure TAefosLazChatController._HandleDeleteSession(const AId: string);
var
  LId: UnicodeString;
begin
  LId := UTF8ToUTF16(Trim(AId));
  if LId = '' then
    Exit;
  // Deleting the LIVE session clears the conversation first so nothing lingers.
  if LId = FStoreSessionId then
    _ResetConversation;
  _Store.Delete(LId);
  // Re-list so the deleted row disappears (the panel stays open).
  _HandleOpenSessions;
end;

// --- MCP servers modal -----------------------------------------------------

function TAefosLazChatController._McpConfigPath: UnicodeString;
begin
  // TPath.Combine (Compat.IO) is UnicodeString end to end (no ANSI round-trip on
  // a non-ASCII %APPDATA% path). Same file the RAD Studio chat's modal uses.
  Result := TPath.Combine(FConfigRoot, CMcpConfigFile);
end;

procedure TAefosLazChatController._HandleOpenMcp;
var
  LPath: UnicodeString;
  LRaw: UnicodeString;
  LCfg: UnicodeString;
  LVal: TJSONValue;
begin
  // Load the user-editable global MCP config; a missing/garbled file degrades to
  // {} so the modal always opens (mirrors ShowMcpServers' _ObjectOrEmpty). NOTE:
  // dispatch DOES merge the installed-addon aggregate (Aefos.Lazarus.McpAddonMerge,
  // used by _BuildDispatchContext); this modal simply does not yet LIST those
  // read-only ADDON rows the way the Delphi one does, so it passes {} for the
  // aggregate and shows the user's editable servers alone -- a modal-display slice,
  // not a dispatch gap.
  LCfg := '{}';
  LPath := _McpConfigPath;
  if TFile.Exists(LPath) then
  begin
    try
      LRaw := Trim(TFile.ReadAllText(LPath, TEncoding.UTF8));
    except
      LRaw := '';
    end;
    if LRaw <> '' then
    begin
      LVal := TJSONObject.ParseJSONValue(LRaw);
      try
        if LVal is TJSONObject then
          LCfg := LRaw;
      finally
        LVal.Free;   // nil-safe (malformed input parses to nil)
      end;
    end;
  end;
  _Run('window.dsShowMcp && window.dsShowMcp(' + UTF16ToUTF8(LCfg) + ',{});');
end;

procedure TAefosLazChatController._HandleSaveMcp(const AJson: string);
begin
  // Persist the edited config (the modal already built valid {mcpServers:...}
  // JSON). Best-effort: a write failure must never break the chat.
  try
    if (FConfigRoot <> '') and not TDirectory.Exists(FConfigRoot) then
      TDirectory.CreateDirectory(FConfigRoot);
    TFile.WriteAllText(_McpConfigPath, UTF8ToUTF16(AJson), TEncoding.UTF8);
  except
    // best-effort
  end;
end;

procedure TAefosLazChatController._OnChunk(const AChunk: TOllamaChunk);
begin
  // Runs on the IDE main thread (the transport marshals every event via
  // TThread.Synchronize on FPC), so ExecuteScript is safe here.
  if AChunk.Error <> '' then
  begin
    FBusy := False;
    _JsFooter(UTF16ToUTF8(AChunk.Error), True);
    // Turn settled (errored) -- persist whatever streamed, then an errored turn is
    // still a settled turn, so drain the next send-during-run message exactly as a
    // clean Done does.
    _CommitTurn;
    _DrainQueuedMessage;
    Exit;
  end;
  if AChunk.Content <> '' then
  begin
    FCurrentAssistant := FCurrentAssistant + AChunk.Content;
    _JsAppend(UTF16ToUTF8(AChunk.Content));
  end;
  if AChunk.Done then
  begin
    FBusy := False;
    // A settled footer with no token line -- the reply already rendered.
    _JsFooter('', False);
    // Turn settled -- record the assistant reply, then hand off to the next
    // send-during-run message, if any.
    _CommitTurn;
    _DrainQueuedMessage;
  end;
end;

end.
