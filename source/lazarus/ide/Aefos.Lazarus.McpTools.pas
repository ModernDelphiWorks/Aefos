unit Aefos.Lazarus.McpTools;

{ Aefos AI - Lazarus edition: MCP tool registrar (hosted-server slice).

  This is the Lazarus-only twin of the Delphi tool registrars
  (source\mcp\Core\Aefos.MCP.Tools.Editor.pas + a few reads from
  Aefos.MCP.Tools / Aefos.MCP.Tools.IDE). It exists because the shared Delphi
  registrars `uses System.JSON` FLATLY (a Delphi-RTL unit FPC lacks) - they are
  Delphi-only as written. Rather than port those shared units off System.JSON
  (a shared/core edit that would trip the Delphi build gate), path (ii) of
  06-seam-inventory.md builds a small, self-contained registrar HERE on
  Aefos.Compat.Json (FPC-clean, already on the package unit path) that exposes
  ONLY the facade members that are LIVE on Lazarus today (the read slice + the
  editor write slice + the Phase J live form designer + the view-switch/vision
  pair + the build/run slice - 33 tools). Tool NAMES + JSON schemas MIRROR the
  Delphi ones so a connecting AI
  CLI sees the exact same tools it already expects.

  Tools exposed (facade member -> tool):
    reads:
      GetEditorActiveFile   -> GetEditorActiveFile
      GetEditorFullContent  -> GetEditorFullContent
      GetOpenEditorFiles    -> GetOpenEditorFiles
      GetCursorPosition     -> GetCursorPosition
      GetSelection          -> GetSelection
      FindInEditor          -> FindInEditor
      ListIDEActions        -> ListIDEActions
    terminal (neutral action; RULE #1 EXEMPT like ListIDEActions):
      (dock.Show)           -> OpenTerminal            (opens the docked terminal panel)
    editor writes (tiCode where the name is mutating):
      EditUnit              -> EditUnit               (tiCode)
      InsertCodeAtCursor    -> InsertCodeAtCursor     (tiCode)
      ReplaceEditorSelection-> ReplaceEditorSelection (tiCode)
      SetEditorFullContent  -> SetEditorFullContent   (tiCode)
      ReplaceInEditor       -> ReplaceInEditor        (tiCode)
      UndoEditor            -> UndoEditor             (tiCode)
      SaveActiveFile        -> SaveActiveFile         (neutral)
      SaveAllFiles          -> SaveAllFiles           (neutral)
    live form designer (Phase J - design mutations are consent-gated + tiDesign):
      OpenFormDesigner      -> OpenFormDesigner       (neutral view-switch)
      AddComponent          -> AddComponent           (tiDesign)
      RemoveComponent       -> RemoveComponent        (tiDesign)
      SetComponentProperty  -> SetComponentProperty   (tiDesign)
      SetFormProperty       -> SetFormProperty        (tiDesign)
      AddEventHandler       -> AddEventHandler        (tiDesign)
      GetDFMContent         -> GetDFMContent          (neutral, live .lfm read)
      ListFormComponents    -> ListFormComponents     (neutral)
      GetComponentProperties-> GetComponentProperties (neutral)
      GetFormProperties     -> GetFormProperties      (neutral)
    view-switch to Code + agent vision (RULE #1 exempt; never gated):
      OpenUnitInEditor      -> OpenUnitInEditor        (neutral view-switch, ends in Code)
      CaptureActiveFormPng  -> CaptureForm             (neutral read, inline PNG)
    build/run (async build_id model; run/stop are consent-gated):
      StartBuild            -> RunBuild               (neutral, un-gated)
      QueryBuildResult      -> GetBuildStatus         (neutral, un-gated)
      GetCompilerMessages   -> GetCompilerErrors      (neutral, un-gated)
      RunProject            -> RunProject             (neutral, consent-gated)
      RunWithoutDebugger    -> RunWithoutDebugger     (neutral, consent-gated)
      StopProject           -> StopProject            (neutral, consent-gated)

  Members that raise ENotSupportedException on the Lazarus facade today
  (SetEditorCursorPosition, FindInProject, CloseFile, SendKeystroke, ReadUnit,
  and every project/designer member) are DELIBERATELY NOT exposed - a tool is
  registered only when its facade member is live.

  Threading: the named-pipe transport dispatches each client's frames on its own
  worker thread. Every facade call must run on the IDE main thread, so each
  handler marshals through AContext.MarshalToMainThread (the host wires that to
  TThread.Synchronize). FPC 3.2.2 has NO anonymous methods, so the marshalled
  body is a PER-CALL carrier object (TAefosLazMarshalCall) with a bound `Run`
  method - never a shared mutable field on the registrar (the transport is
  multi-client; a shared slot would let one client's read clobber another's -
  the exact bug caught in phase B).

  Lifetime: TMCPToolHandler on FPC is a method pointer, which does NOT keep its
  instance alive (no refcount). So the registrar is a plain owned object: the
  HOST creates it, holds it, and frees it AFTER the server is stopped (so a
  mid-dispatch worker never calls a freed handler). It is NOT a TInterfacedObject
  because there is no interface reference to keep it alive.

  RULE #1: the mutating tools declare tiCode; the SERVER enforces the view guard
  before the handler runs (via the host's SetViewProvider). The facade's own
  guards (e.g. SetEditorFullContent's pas<->lfm desync refusal) surface as a
  tool result with applied=false, never a crash.

  WRITE CONSENT (parity with the Delphi terminal host's _RequestGate): the 8
  editor-write tools (EditUnit, InsertCodeAtCursor, ReplaceEditorSelection,
  SetEditorFullContent, ReplaceInEditor, UndoEditor, SaveActiveFile,
  SaveAllFiles) AND the 5 Phase J design MUTATIONS (AddComponent,
  RemoveComponent, SetComponentProperty, SetFormProperty, AddEventHandler - they
  change the form) are gated behind a human Yes/No before the first mutation
  of the IDE session. Any local process can open the named pipe, so without this
  gate it could silently mutate the user's editor. The 3 RUN tools (RunProject,
  RunWithoutDebugger, StopProject) are gated on a SEPARATE grant: executing the
  user's binary is a distinct authorization from editing code. _EnsureWriteConsent
  shows a main-thread branded consent modal (the LCL twin of the Delphi terminal
  form: Allow once / Allow for this session / Deny) on the first action of each
  CLASS; "Allow for this session" grants that class for the whole session (one
  prompt per class, not per-call nagging), "Allow once" proceeds this call only,
  tracked by FEditsAllowedThisSession / FRunAllowedThisSession under FLock - a
  grant to editing does NOT authorize running, and vice versa (mirrors the Delphi
  per-tool consent registry). Auto-approve (shared TConfig.AgentConsentMode) is
  thresholded per class: edits at mode >= 1, runs ONLY at mode 2 (mode 1 =
  "auto-approve edits, ask before destructive" must still gate running a binary).
  A No raises EMCPUserDenied, which the server catches and returns as a well-formed
  isError frame. The read + build tools (RunBuild/GetBuildStatus/GetCompilerErrors)
  are NEVER gated. TEST-ONLY: AEFOS_LAZ_MCP_CONSENT_AUTOGRANT=1 (checked once at
  construction, default OFF) pre-grants BOTH session gates so the headless proof
  can exercise a write without a human click - never for normal use (mirrors how
  AEFOS_LAZ_MCP_AUTOSTART is test-only).

  Mode delphiunicode + de-dotted units, matching the MCP core; all literals are
  ASCII, so the file needs no BOM. }

{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

interface

uses
  SysUtils,
  SyncObjs,
  Aefos.Compat.Json,
  Aefos.MCP.Types,
  Aefos.Lazarus.DebugService, // IAefosLazDebugService (FDebug field type)
  Aefos.MCP.BuildManager,   // IMCPBuildManager / TMCPBuildManager - async build_id model
  Aefos.MCP.IntentGuard,
  Aefos.MCP.FlowGuide,      // TFlowGuide.SourceBuildsStandardControlsInCodeReason (RULE #1)
  Aefos.MCP.Server;

type
  { The registrar. A plain owned object (see the Lifetime note in the header):
    the host creates it, calls RegisterAll once, and frees it after the server
    stops. Its handler methods are the of-object handlers the tool descriptors
    carry (TMCPToolHandler on FPC = method pointer bound to this instance). }
  TAefosLazMcpToolsRegistrar = class
  private
    FFacade: IMCPWorkspaceFacade;
    // Session-scoped async build-job registry (ADR-068/070). Shared with the
    // Delphi edition byte-for-byte (Aefos.MCP.BuildManager is FPC-clean, pure
    // RTL): RunBuild mints a build_id here, GetBuildStatus polls it. Cancellation
    // is a no-op on Lazarus (synchronous build - see _HRunBuild), so this host
    // does NOT wire the server's IMCPCancellationSink.
    FBuildManager: IMCPBuildManager;
    // Debug service (the debug-loop foundation slice: GetDebugState + breakpoint
    // CRUD). The Lazarus twin of the Delphi IMCPDebugService, kept OFF the frozen
    // facade so the IdeDebugger dependency stays confined to its own unit. Created
    // once in the constructor, held for the registrar's life.
    FDebug: IAefosLazDebugService;
    // Consent gate (parity with the Delphi _RequestGate). The two grants are
    // read/written ONLY under FLock; the actual prompt runs on the IDE main
    // thread via the context marshal, so concurrent transport workers are safe.
    // TWO SEPARATE session grants (a Yes to editing must NOT silently authorize
    // running the user's binary, and vice versa - mirrors the Delphi per-tool
    // consent registry, Aefos.MCP.Consent.pas):
    //   FEditsAllowedThisSession - editor/design mutations (EditUnit, AddComponent...)
    //   FRunAllowedThisSession   - RUN tools (RunProject/RunWithoutDebugger/StopProject)
    FLock: TCriticalSection;
    FEditsAllowedThisSession: Boolean;
    FRunAllowedThisSession: Boolean;
    // Ensures the human consented before the FIRST edit / run of the session.
    // AIsRun selects WHICH gate (and threshold + prompt): False = an edit/design
    // mutation, True = a RUN tool. True = allowed (no prompt on the fast path once
    // granted); False = the user said No and the caller must raise EMCPUserDenied.
    function _EnsureWriteConsent(const AContext: IMCPToolContext;
      const AToolName: string; const AIsRun: Boolean = False): Boolean;
    // Global %APPDATA%\Aefos root for the SHARED config core (of-object seam) -
    // the same file the RAD plugin uses, so consent mode is ONE brain.
    function _ConfigRoot: string;
    // True when the shared TConfig.AgentConsentMode auto-approves THIS class of
    // tool: edits auto-approve at mode >= 1; RUN tools auto-approve ONLY at
    // mode = 2 (running the user's binary is NOT covered by "auto-approve edits").
    // Read off the transport worker; a bad read degrades to False (still prompt).
    function _ConsentModeAutoApproves(const AIsRun: Boolean): Boolean;
    // Handlers (TMCPToolHandler shape: function(params, context): result of object)
    function _HGetEditorActiveFile(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HGetEditorFullContent(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HGetOpenEditorFiles(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HGetCursorPosition(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HGetSelection(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HFindInEditor(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HListIDEActions(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    // Fires a named IDE command discovered via ListIDEActions. CONSENT-GATED (it can
    // trigger a mutating command) and RULE #1 EXEMPT (it may itself flip the view,
    // e.g. F12). Marshalled to the IDE main thread through the per-call carrier.
    function _HExecuteIDEAction(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    // Opens the docked Aefos AI terminal panel. Neutral / RULE #1 EXEMPT (like
    // ListIDEActions): it changes no editor/design view and is never consent-gated.
    // The dock Show is UI work, so it is marshalled to the IDE main thread.
    function _HOpenTerminal(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    // Change-review feedback loop (twins of the RAD GetReviewFeedback /
    // GetPendingReviews tools). Neutral / RULE #1 EXEMPT and never consent-gated:
    // they only READ the review gutter (GetReviewFeedback additionally CLEARS the
    // drained annotations). Both marshal to the IDE main thread - GReviewFeedback /
    // GChanges are mutated there by approve/reject.
    function _HGetReviewFeedback(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HGetPendingReviews(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HEditUnit(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HInsertCodeAtCursor(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HReplaceEditorSelection(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HSetEditorFullContent(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HReplaceInEditor(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HSaveActiveFile(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HSaveAllFiles(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HUndoEditor(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    // Phase J - live form designer (mutations are consent-gated + tiDesign).
    function _HAddComponent(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HRemoveComponent(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HSetComponentProperty(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HSetFormProperty(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HAddEventHandler(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HOpenFormDesigner(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HGetDFMContent(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HListFormComponents(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HGetComponentProperties(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HGetFormProperties(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    // View-switch to Code (OpenUnitInEditor) + agent-vision screenshot
    // (CaptureForm) - the Lazarus twins of the Delphi tools of the same name.
    // Both are RULE #1 EXEMPT: OpenUnitInEditor is a view-switch, CaptureForm is a
    // read; neither is consent-gated.
    function _HOpenUnitInEditor(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HCaptureForm(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    // Build/run group (the Lazarus twin of the Delphi RunBuild/GetBuildStatus/
    // GetCompilerErrors + RunProject/RunWithoutDebugger/StopProject tools).
    function _HRunBuild(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HGetBuildStatus(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HGetCompilerErrors(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HRunProject(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HRunWithoutDebugger(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HStopProject(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    // Debug-loop foundation (twins of the Delphi GetDebugState / SetBreakpoint /
    // RemoveBreakpoint / ListBreakpoints tools). GetDebugState + ListBreakpoints are
    // neutral / RULE #1 EXEMPT and never consent-gated (read-only); SetBreakpoint /
    // RemoveBreakpoint mutate debug state but are low-risk and, like the Delphi debug
    // tools, carry NO interactive consent gate in this slice. All marshal to the IDE
    // main thread (DebugBoss is main-thread only).
    function _HGetDebugState(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HSetBreakpoint(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HRemoveBreakpoint(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HListBreakpoints(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    // Step / run-control family (twins of the Delphi StepOver/StepInto/StepOut/
    // ContinueRun/RunToLine/PauseRun tools). Each is ASYNC: it guards the debugger
    // precondition (STOPPED for steps, a live SESSION for continue/pause/run-to-line),
    // dispatches through FDebug on the IDE main thread, then reports the freshly
    // re-read state with dispatched=true - the agent RE-POLLS GetDebugState to see the
    // new location (the descriptions carry that hint VERBATIM from the RAD edition).
    // No consent gate (parity with the Delphi debug family, which gates none).
    // _ReadDebugState marshals one state snapshot; _DispatchDebug marshals one
    // no-argument FDebug dispatch (continue/pause); the step + run-to-line handlers
    // add their own carrier for the parameterised call.
    function _ReadDebugState(const AContext: IMCPToolContext): TAefosLazDebugState;
    function _DispatchDebug(const AContext: IMCPToolContext;
      const AIsPause: Boolean): Boolean;
    function _StepFamily(const AContext: IMCPToolContext;
      const AKind: TAefosLazDebugStepKind): TMCPToolResult;
    function _HStepOver(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HStepInto(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HStepOut(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HContinueRun(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HRunToLine(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HPauseRun(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    // Debug inspection family (twins of the Delphi InspectLocals / EvaluateExpression
    // / GetCallStack tools). Each requires the debuggee STOPPED (dnStopped guard) and
    // reads the live frame: InspectLocals lists the native FpDebug locals as
    // "name = value"; EvaluateExpression evaluates an expression to {value}/{error};
    // GetCallStack renders the current thread's frames as "header  file:line". No
    // consent gate (read-only inspection, parity with the Delphi debug family). All
    // marshal to the IDE main thread (DebugBoss is main-thread only) and, because the
    // FpDebug data fills async, pump a bounded main-thread budget inside FDebug.
    function _HInspectLocals(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HEvaluateExpression(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HGetCallStack(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    // Per-type project creation. RULE #1: the kind is HARD-CODED by each tool's
    // handler (never read from AParams), so the tool NAME is the guarantee of the
    // type an agent gets. The five thin handlers all funnel into _CreateProjectKind,
    // which gates write-consent, marshals FFacade.CreateNewProject and shapes the
    // {path, applied} result - the Lazarus twin of the Delphi _BuildCreateProjectTyped
    // + _HandleCreateProjectKind pair.
    function _CreateProjectKind(const AToolName, AKind: string;
      const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HCreateProjectApplication(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HCreateProjectSimpleProgram(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HCreateProjectProgram(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HCreateProjectConsole(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HCreateProjectLibrary(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    // True when the shared "Issue reporting" toggle is ON (TConfig.IssueReporting
    // in the SAME config.json the RAD plugin's AI Flow page writes - ONE brain).
    // The gate for ProposeAefosIssue: OFF (default) means the dialog never opens,
    // so a hallucinating agent can never spam it (parity with the Delphi
    // TAIFlowOptions.IssueReportingEnabled). A bad read degrades to OFF.
    function _IssueReportingEnabled: Boolean;
    // Proposes an Aefos bug/suggestion: gated by _IssueReportingEnabled, then the
    // editable dialog + browser hand-off (TAefosLazIssueReport.Execute) run on the
    // IDE main thread via the per-call carrier. The agent NEVER files the issue
    // itself - the human edits and clicks Submit. Twin of the Delphi
    // ProposeAefosIssue tool (Aefos.OTA.MCP.IssueReport.pas). Neutral / RULE #1
    // EXEMPT: it shows a dialog, it changes no Design/Code view.
    function _HProposeAefosIssue(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
  public
    constructor Create(const AFacade: IMCPWorkspaceFacade);
    destructor Destroy; override;
    // Builds and registers every live read/editor tool on AServer.
    procedure RegisterAll(const AServer: IMCPServer);
  end;

implementation

uses
  Classes,                           // TStringList (feedback line counting)
  Aefos.Lazarus.ConsentDialog,       // branded 3-choice consent modal (LCL, main-thread only)
  Aefos.Lazarus.TerminalWindow,      // TAefosLazTerminalDock.Show (OpenTerminal tool)
  Aefos.Lazarus.GutterReview,        // TAefosLazGutterReview (GetReviewFeedback / GetPendingReviews)
  Aefos.Lazarus.IssueReport,         // TAefosLazIssueReport (ProposeAefosIssue dialog + browser)
  Aefos.Lazarus.IdeSilence,          // TAefosIdeSilence (one-shot debugger stop-dialog silence)
  Aefos.OTA.Chat.Core.Config,        // TConfigService / TConfigRootResolver
  Aefos.OTA.Chat.Core.Config.Types;  // TConfig / IConfig (AgentConsentMode)

const
  // TEST-ONLY session pre-grant. When AEFOS_LAZ_MCP_CONSENT_AUTOGRANT=1 the
  // registrar treats writes as already consented so the headless proof can call
  // a write tool without a human clicking the dialog. Defaults OFF (absent) -
  // NEVER set it in normal use (mirrors AEFOS_LAZ_MCP_AUTOSTART's test-only role).
  cConsentAutograntEnvVar = 'AEFOS_LAZ_MCP_CONSENT_AUTOGRANT';

type
  // Which facade member a marshalled call invokes. One enum-driven carrier
  // (instead of 15 carrier classes) keeps the per-call allocation cheap while
  // staying strictly per-call (no shared state - multi-client safe).
  TAefosLazCallKind = (
    ckGetEditorActiveFile, ckGetEditorFullContent, ckGetOpenEditorFiles,
    ckGetCursorPosition, ckGetSelection, ckFindInEditor, ckListIDEActions,
    // Fires a named IDE command discovered via ListIDEActions. FInStr1=ActionName;
    // FOk=applied, FOutStr1=reason. Consent-gated (see _HExecuteIDEAction).
    ckExecuteIDEAction,
    ckEditUnit, ckInsertCodeAtCursor, ckReplaceEditorSelection,
    ckSetEditorFullContent, ckReplaceInEditor, ckSaveActiveFile,
    ckSaveAllFiles, ckUndoEditor,
    // Phase J - live form designer.
    ckAddComponent, ckRemoveComponent, ckSetComponentProperty,
    ckSetFormProperty, ckAddEventHandler, ckOpenFormDesigner,
    ckGetDFMContent, ckListFormComponents, ckGetComponentProperties,
    ckGetFormProperties,
    // View-switch to Code + agent-vision capture (twins of the Delphi
    // OpenUnitInEditor / CaptureForm tools).
    ckOpenUnitInEditor, ckCaptureForm,
    // Build/run group.
    ckStartBuild, ckQueryBuildResult, ckGetCompilerMessages,
    ckRunProject, ckRunWithoutDebugger, ckStopProject,
    // Debug-loop foundation. Not facade members -- Run drives FDebug directly.
    // ckGetDebugState fills FDebugState; ckSetBreakpoint uses FInStr1=unit,
    // FInInt1=line, FInStr2=condition, FInInt2=passCount -> FOutBool=applied,
    // FOutReason; ckRemoveBreakpoint uses FInStr1=unit, FInInt1=line ->
    // FOutBool=applied; ckListBreakpoints fills FBreakpoints.
    ckGetDebugState, ckSetBreakpoint, ckRemoveBreakpoint, ckListBreakpoints,
    // Step family. Not facade members -- Run drives FDebug directly (DebugBoss is
    // main-thread only). ckDebugStep uses FInInt1=Ord(TAefosLazDebugStepKind);
    // ckDebugRunToLine uses FInStr1=unit, FInInt1=line. All -> FOutBool=dispatched.
    ckDebugStep, ckDebugContinue, ckDebugPause, ckDebugRunToLine,
    // Debug inspection. Not facade members -- Run drives FDebug directly (DebugBoss
    // is main-thread only). ckDebugInspectLocals / ckDebugGetCallStack fill
    // FDebugLines; ckDebugEvaluate uses FInStr1=expression -> FOutBool=ok,
    // FOutStr1=value/error.
    ckDebugInspectLocals, ckDebugEvaluate, ckDebugGetCallStack,
    // Project creation (per-type CreateProject<Type> tools). FInStr1=name,
    // FInStr2=kind, FInStr3=directory; FOutBool=applied, FOutStr1=project path,
    // FOutReason=machine-actionable code.
    ckCreateNewProject,
    // Terminal: open the docked terminal panel. Not a facade member -- Run calls
    // TAefosLazTerminalDock.Show directly. FOutBool=applied, FOutReason on failure.
    ckOpenTerminal,
    // Change-review feedback loop. Not facade members -- Run calls the gutter
    // review class methods directly. FOutStr1=text (feedback lines / pending
    // lines), FOutInt=count. GReviewFeedback / GChanges are mutated on the IDE
    // main thread by approve/reject, so both MUST run marshalled.
    ckGetReviewFeedback, ckGetPendingReviews,
    // Propose an Aefos issue. Not a facade member -- Run calls
    // TAefosLazIssueReport.Execute directly (the editable dialog + browser
    // hand-off are UI work, main-thread only). FInStr1=title, FInStr2=problem,
    // FInStr3=possibleSolution -> FOutBool=sent, FOutStr1=url (when sent).
    ckProposeAefosIssue);

  { Per-call carrier for a marshalled facade read/write. Created on the worker
    thread, its Run method executes on the IDE main thread via Synchronize, then
    the worker reads the output fields. A fresh instance per tool call - no field
    is ever shared between concurrent clients (FPC has no closures; this is the
    carrier-object form of the server's own TMarshalledViewRead). }
  TAefosLazMarshalCall = class
  private
    FFacade: IMCPWorkspaceFacade;
    FKind: TAefosLazCallKind;
    // inputs
    FInStr1: string;
    FInStr2: string;
    FInStr3: string;
    FInStr4: string;
    FInStr5: string;
    FInBool1: Boolean;
    FInInt1: Integer;
    FInInt2: Integer;
    FInInt3: Integer;
    FInInt4: Integer;
    // outputs
    FOk: Boolean;
    FOutStr1: string;
    FOutStr2: string;
    FOutBool: Boolean;
    FOutBool2: Boolean;
    FOutChanged: Boolean;
    FOutReason: string;
    FOutInt: Integer;
    FCursor: TMCPCursorInfo;
    FSelection: TMCPSelectionInfo;
    FEditOutcome: TMCPEditOutcome;
    FFiles: TArray<TMCPRecordEditorFile>;
    FOccurrences: TArray<TMCPCursorInfo>;
    FDfmProps: TArray<TMCPRecordDFMProperty>;
    FDfmComps: TArray<TMCPRecordDFMComponent>;
    // Build/run outputs.
    FBuildState: TMCPBuildState;
    FCompilerMsgs: TArray<TMCPCompilerMessage>;
    // Debug-loop foundation. FDebug is the debug service the ckDebug* kinds drive
    // (set by the handler before marshalling); FDebugState / FBreakpoints are their
    // outputs.
    FDebug: IAefosLazDebugService;
    FDebugState: TAefosLazDebugState;
    FBreakpoints: TArray<string>;
    // Inspection output: the "name = value" locals / "header  file:line" frame lines
    // (ckDebugInspectLocals / ckDebugGetCallStack). Kept distinct from FBreakpoints
    // so a single carrier's fields never alias across debug kinds.
    FDebugLines: TArray<string>;
  public
    constructor Create(const AFacade: IMCPWorkspaceFacade;
      const AKind: TAefosLazCallKind);
    // procedure of object -> matches TThreadProcedure; runs on the main thread.
    procedure Run;
  end;

  { Per-call carrier for the write-consent prompt. Created on the worker thread,
    its Run method shows the branded consent modal on the IDE main thread (via the
    context marshal), then the worker reads FDecision. A fresh instance per call -
    NEVER a shared field on the registrar - so concurrent clients cannot race on
    the outcome (the same discipline as TAefosLazMarshalCall). }
  TAefosLazConsentPrompt = class
  private
    FToolName: string;
    FIsRun: Boolean;
    // Three-way outcome from the branded modal (Allow once / Allow for this
    // session / Deny), the LCL twin of the Delphi terminal consent form. cdDenied
    // is the safe default until the user picks otherwise.
    FDecision: TMCPConsentDecision;
  public
    constructor Create(const AToolName: string; const AIsRun: Boolean);
    // procedure of object -> matches TThreadProcedure; runs on the main thread.
    procedure Run;
  end;

{ ---- param readers -------------------------------------------------------- }

// Optional string param: '' when absent or not a string. The server has already
// validated schema-`required` fields before the handler runs, so a required
// field is present here; these degrade safely for the optional ones.
function _OptStr(const AParams: TJSONObject; const AName: string): string;
var
  LValue: TJSONValue;
begin
  Result := '';
  if AParams = nil then
    Exit;
  LValue := AParams.GetValue(AName);
  if LValue = nil then
    Exit;
  Result := LValue.Value;
end;

function _OptBool(const AParams: TJSONObject; const AName: string): Boolean;
var
  LValue: TJSONValue;
begin
  Result := False;
  if AParams = nil then
    Exit;
  LValue := AParams.GetValue(AName);
  if LValue = nil then
    Exit;
  if LValue is TJSONBool then
    Result := TJSONBool(LValue).AsBoolean;
end;

// Optional integer param: 0 when absent / not a number.
function _OptInt(const AParams: TJSONObject; const AName: string): Integer;
var
  LValue: TJSONValue;
begin
  Result := 0;
  if AParams = nil then
    Exit;
  LValue := AParams.GetValue(AName);
  if LValue = nil then
    Exit;
  if LValue is TJSONNumber then
    Result := TJSONNumber(LValue).AsInt
  else
    Result := StrToIntDef(LValue.Value, 0);
end;

// Number of non-empty lines in AText (the RAD GetReviewFeedback count = one per
// annotation; TStringList.Text ends the last line with a break, so a naive line
// count would over-count by one - hence the non-empty filter). Unit-local helper,
// same discipline as the _Opt* readers above.
function _CountNonEmptyLines(const AText: string): Integer;
var
  LList: TStringList;
  LI: Integer;
begin
  Result := 0;
  if AText = '' then
    Exit;
  LList := TStringList.Create;
  try
    LList.Text := AText;
    for LI := 0 to LList.Count - 1 do
      if Trim(LList[LI]) <> '' then
        Inc(Result);
  finally
    LList.Free;
  end;
end;

{ ---- schema builders (mirror the Delphi tool schemas) --------------------- }

function _SchemaEmpty: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  Result.AddPair('properties', TJSONObject.Create);
end;

// Adds a typed property to the properties object.
procedure _AddProp(const AProps: TJSONObject; const AName, AType: string);
var
  LProp: TJSONObject;
begin
  LProp := TJSONObject.Create;
  LProp.AddPair('type', AType);
  AProps.AddPair(AName, LProp);
end;

// {type:object, properties:{...}, required:[...]}. ANames/ATypes are parallel
// arrays of (name, jsontype); ARequired lists the required names.
function _SchemaObject(const ANames, ATypes, ARequired: array of string): TJSONObject;
var
  LProps: TJSONObject;
  LReq: TJSONArray;
  LIdx: Integer;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  for LIdx := 0 to High(ANames) do
    _AddProp(LProps, ANames[LIdx], ATypes[LIdx]);
  Result.AddPair('properties', LProps);
  if Length(ARequired) > 0 then
  begin
    LReq := TJSONArray.Create;
    for LIdx := 0 to High(ARequired) do
      LReq.Add(ARequired[LIdx]);
    Result.AddPair('required', LReq);
  end;
end;

{ ---- TAefosLazMarshalCall -------------------------------------------------- }

constructor TAefosLazMarshalCall.Create(const AFacade: IMCPWorkspaceFacade;
  const AKind: TAefosLazCallKind);
begin
  inherited Create;
  FFacade := AFacade;
  FKind := AKind;
  FCursor := Default(TMCPCursorInfo);
  FSelection := Default(TMCPSelectionInfo);
  FEditOutcome := eoUnitNotOpen;
end;

procedure TAefosLazMarshalCall.Run;
var
  LCapture: IMCPFormCapture;
begin
  // Main thread (marshalled). Every kind dispatched here is a LIVE facade
  // member, so an exception is a genuine fault and is allowed to propagate: the
  // server's _HandleFrame turns it into a -32603 error frame (the honest result).
  case FKind of
    ckGetEditorActiveFile:
      FOk := FFacade.GetEditorActiveFile(FOutStr1, FOutStr2);
    ckGetEditorFullContent:
      FOk := FFacade.GetEditorFullContent(FOutStr1);
    ckGetOpenEditorFiles:
      FOk := FFacade.GetOpenEditorFiles(FFiles);
    ckGetCursorPosition:
      FCursor := FFacade.GetCursorPosition;
    ckGetSelection:
      FSelection := FFacade.GetSelection;
    ckFindInEditor:
      FOk := FFacade.FindInEditor(FInStr1, FInBool1, FOccurrences);
    ckListIDEActions:
      FOutStr1 := FFacade.ListIDEActions(FInStr1);
    ckExecuteIDEAction:
      FOk := FFacade.ExecuteIDEAction(FInStr1, FOutStr1);
    ckEditUnit:
      FEditOutcome := FFacade.EditUnit(FInStr1, FInStr2, FInStr3, FOutStr1);
    ckInsertCodeAtCursor:
      FOutBool := FFacade.InsertCodeAtCursor(FInStr1);
    ckReplaceEditorSelection:
      FOutBool := FFacade.ReplaceEditorSelection(FInStr1);
    ckSetEditorFullContent:
      FOutBool := FFacade.SetEditorFullContent(FInStr1);
    ckReplaceInEditor:
      FOk := FFacade.ReplaceInEditor(FInStr1, FInStr2, FInBool1, FOutInt);
    ckSaveActiveFile:
      FOutBool := FFacade.SaveActiveFile(FOk);
    ckSaveAllFiles:
      FOutBool := FFacade.SaveAllFiles(FOk);
    ckUndoEditor:
      FOutBool := FFacade.UndoEditor;
    // -- Phase J live form designer --------------------------------------
    ckAddComponent:
      FOutBool := FFacade.AddComponent(FInStr1, FInStr2, FInStr3, FInStr4,
        FInInt1, FInInt2, FInInt3, FInInt4, FOutChanged, FOutReason);
    ckRemoveComponent:
      FOutBool := FFacade.RemoveComponent(FInStr1, FInStr2,
        FOutChanged, FOutReason);
    ckSetComponentProperty:
      FOutBool := FFacade.SetComponentProperty(FInStr1, FInStr2, FInStr3,
        FInStr4, FOutChanged, FOutReason);
    ckSetFormProperty:
      FOutBool := FFacade.SetFormProperty(FInStr1, FInStr2, FInStr3,
        FOutChanged, FOutReason);
    ckAddEventHandler:
      FOutBool := FFacade.AddEventHandler(FInStr1, FInStr2, FInStr3, FInStr4,
        FInStr5, FOutChanged, FOutReason);
    ckOpenFormDesigner:
      FOutBool := FFacade.OpenFormDesigner(FInStr1, FOutChanged, FOutReason);
    ckGetDFMContent:
      FOk := FFacade.GetDFMContent(FInStr1, FOutStr1, FOutBool2);
    ckListFormComponents:
      FOk := FFacade.ListFormComponents(FInStr1, FDfmComps);
    ckGetComponentProperties:
      FOk := FFacade.GetComponentProperties(FInStr1, FInStr2, FDfmProps);
    ckGetFormProperties:
      FOk := FFacade.GetFormProperties(FInStr1, FDfmProps);
    // -- view-switch to Code + agent-vision capture ----------------------
    ckOpenUnitInEditor:
      FOutBool := FFacade.OpenUnitInEditor(FInStr1); // FInStr1 = unit name
    ckCaptureForm:
      begin
        // The capture seam is OFF the frozen IMCPWorkspaceFacade; reach it via
        // Supports (parity with the Delphi _HandleCaptureForm). FInStr1 = unit
        // name (empty = the form open in the Designer). Outputs: FOutStr1 = PNG
        // base64, FOutStr2 = temp PNG path, FOutReason = failure code, FOk = ok.
        if Supports(FFacade, IMCPFormCapture, LCapture) then
          FOk := LCapture.CaptureActiveFormPng(FInStr1, FOutStr1, FOutStr2,
            FOutReason)
        else
        begin
          FOk := False;
          FOutReason := 'capture-unavailable: this host cannot render forms to '
            + 'an image';
        end;
      end;
    // -- build/run group -------------------------------------------------
    ckStartBuild:
      FOutBool := FFacade.StartBuild(FInStr1, FOutStr1); // FInStr1=mode, FOutStr1=error
    ckQueryBuildResult:
      FBuildState := FFacade.QueryBuildResult;
    ckGetCompilerMessages:
      FCompilerMsgs := FFacade.GetCompilerMessages;
    ckRunProject:
      begin
        // AGENT-dispatched run: when it stops, the debugger's "Execution stopped"
        // / exit-code box would block the pipe with nobody to click it. Arm the
        // IDE's own one-shot SkipStopMessage for THIS stop only (see
        // Aefos.Lazarus.IdeSilence) - the developer's own F9 runs keep the
        // dialogs he configured, and no preference of his is read or written.
        TAefosIdeSilence.ArmDebuggerStopSilence;
        FOutBool := FFacade.RunProject;
      end;
    ckRunWithoutDebugger:
      FOutBool := FFacade.RunWithoutDebugger;
    ckStopProject:
      begin
        TAefosIdeSilence.ArmDebuggerStopSilence;
        FOutBool := FFacade.StopProject;
      end;
    // -- debug-loop foundation -------------------------------------------
    // Not facade members: drive the debug service directly on the main thread
    // (DebugBoss is main-thread only). FDebug is set by the handler.
    ckGetDebugState:
      FDebugState := FDebug.DebugReadState;
    ckSetBreakpoint:
      // FInStr1=unit, FInInt1=line, FInStr2=condition, FInInt2=passCount.
      FOutBool := FDebug.DebugSetBreakpoint(FInStr1, FInInt1, FInStr2, FInInt2,
        FOutReason);
    ckRemoveBreakpoint:
      // FInStr1=unit, FInInt1=line.
      FOutBool := FDebug.DebugRemoveBreakpoint(FInStr1, FInInt1);
    ckListBreakpoints:
      FBreakpoints := FDebug.DebugListBreakpoints;
    // -- step family (drive FDebug directly on the main thread) ----------
    ckDebugStep:
      // FInInt1 = Ord(TAefosLazDebugStepKind): 0=Over, 1=Into, 2=Out.
      FOutBool := FDebug.DebugStep(TAefosLazDebugStepKind(FInInt1));
    ckDebugContinue:
      FOutBool := FDebug.DebugContinue;
    ckDebugPause:
      FOutBool := FDebug.DebugPause;
    ckDebugRunToLine:
      // FInStr1 = unit, FInInt1 = line.
      FOutBool := FDebug.DebugRunToLine(FInStr1, FInInt1);
    // -- debug inspection (drive FDebug directly on the main thread) ------
    ckDebugInspectLocals:
      FDebugLines := FDebug.DebugInspectLocals;
    ckDebugEvaluate:
      // FInStr1 = expression -> FOutBool = ok, FOutStr1 = value/error.
      FOutBool := FDebug.DebugEvaluate(FInStr1, FOutStr1);
    ckDebugGetCallStack:
      FDebugLines := FDebug.DebugGetCallStack;
    // -- project creation ------------------------------------------------
    ckCreateNewProject:
      FOutBool := FFacade.CreateNewProject(FInStr1, FInStr2, FInStr3,
        FOutStr1, FOutReason);
    // -- terminal --------------------------------------------------------
    ckOpenTerminal:
      // Not a facade member: open the docked terminal panel directly. Show is
      // idempotent (create-on-demand) and internally guarded, degrading to a
      // floating window if the IDE docking seam is unavailable; a rare fault is
      // reported as applied=false + reason rather than crashing the transport.
      try
        TAefosLazTerminalDock.Show;
        FOutBool := True;
      except
        on E: Exception do
        begin
          FOutBool := False;
          FOutReason := 'open-terminal-failed: ' + E.Message;
        end;
      end;
    // -- change-review feedback loop -------------------------------------
    // Not facade members: read the gutter review directly on the main thread.
    // DrainReviewFeedback CLEARS the annotations; DescribePendingReviews is
    // read-only. The counts come from the same main-thread snapshot to stay
    // consistent with the text (parity with the RAD GetReviewFeedback /
    // GetPendingReviews handlers).
    ckGetReviewFeedback:
      begin
        FOutStr1 := TAefosLazGutterReview.DrainReviewFeedback;
        FOutInt := _CountNonEmptyLines(FOutStr1);
      end;
    ckGetPendingReviews:
      begin
        FOutStr1 := TAefosLazGutterReview.DescribePendingReviews;
        FOutInt := TAefosLazGutterReview.PendingCount;
      end;
    // -- propose an Aefos issue ------------------------------------------
    // Not a facade member: show the editable issue dialog and, on Send, open the
    // pre-filled GitHub new-issue URL in the browser (both are UI work, so this
    // runs marshalled on the IDE main thread). The MCP-side "Issue reporting"
    // gate has already been checked in _HProposeAefosIssue, so by the time Run
    // fires the dialog is authorized to appear.
    ckProposeAefosIssue:
      FOutBool := TAefosLazIssueReport.Execute(FInStr1, FInStr2, FInStr3,
        FOutStr1);
  end;
end;

{ ---- TAefosLazConsentPrompt ------------------------------------------------ }

constructor TAefosLazConsentPrompt.Create(const AToolName: string;
  const AIsRun: Boolean);
begin
  inherited Create;
  FToolName := AToolName;
  FIsRun := AIsRun;
  FDecision := cdDenied;
end;

procedure TAefosLazConsentPrompt.Run;
var
  LSummary, LDetail: string;
begin
  // IDE main thread (marshalled). Shows the branded 3-choice consent modal (the
  // LCL twin of the Delphi terminal form) instead of a plain Yes/No: Allow once /
  // Allow for this session / Deny. A DISTINCT prompt per class of action -
  // editing your code vs RUNNING your project - so a grant to one never silently
  // authorizes the other. Vendor-neutral, English-only per house style.
  if FIsRun then
  begin
    LSummary := 'An AI assistant connected to Aefos wants to RUN your project '
      + '(tool: ' + FToolName + ').';
    LDetail := 'Running executes your project binary. '
      + 'Allow once = run this time only; '
      + 'Allow for this session = don''t ask again until the IDE is restarted; '
      + 'Deny = refuse.';
  end
  else
  begin
    LSummary := 'An AI assistant connected to Aefos wants to EDIT your code '
      + '(tool: ' + FToolName + ').';
    LDetail := 'Editing changes your source or form. '
      + 'Allow once = apply this edit only; '
      + 'Allow for this session = don''t ask again until the IDE is restarted; '
      + 'Deny = refuse.';
  end;
  FDecision := TAefosLazConsentDialog.Execute(FToolName, LSummary, LDetail);
end;

{ ---- result helpers ------------------------------------------------------- }

// A {value, applied, changed} boolean result (mirrors the Delphi editor writes).
function _BoolResult(const AValue: Boolean): TMCPToolResult;
var
  LObj: TJSONObject;
begin
  LObj := TJSONObject.Create;
  try
    LObj.AddPair('value', TJSONBool.Create(AValue));
    LObj.AddPair('applied', TJSONBool.Create(AValue));
    LObj.AddPair('changed', TJSONBool.Create(AValue));
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

// A {value:false, applied:false, changed:false, reason} result for a code-write tool
// REFUSED by a pure guard (RULE #1 "code-builds-ui"). Keeps the _BoolResult shape so an
// agent that only reads `applied` still sees the failure, and adds a machine-actionable
// `reason` so the agent self-corrects to the Designer flow.
function _BlockedResult(const AReason: string): TMCPToolResult;
var
  LObj: TJSONObject;
begin
  LObj := TJSONObject.Create;
  try
    LObj.AddPair('value', TJSONBool.Create(False));
    LObj.AddPair('applied', TJSONBool.Create(False));
    LObj.AddPair('changed', TJSONBool.Create(False));
    LObj.AddPair('reason', AReason);
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

// A {applied, changed, reason} design-mutation result (mirrors the Delphi
// design tools). AReason carries a machine-actionable code on failure ('' ok).
function _DesignResult(const AApplied, AChanged: Boolean;
  const AReason: string): TMCPToolResult;
var
  LObj: TJSONObject;
begin
  LObj := TJSONObject.Create;
  try
    LObj.AddPair('applied', TJSONBool.Create(AApplied));
    LObj.AddPair('changed', TJSONBool.Create(AChanged));
    LObj.AddPair('reason', AReason);
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

// A {path, applied} result (mirrors the Delphi _PathResult for the CreateProject
// tools): applied is true when a non-empty path came back.
function _PathResult(const APath: string): TMCPToolResult;
var
  LObj: TJSONObject;
begin
  LObj := TJSONObject.Create;
  try
    LObj.AddPair('path', APath);
    LObj.AddPair('applied', TJSONBool.Create(APath <> ''));
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

{ ---- debug step/run precondition guard + state result --------------------- }

type
  // What a step/run tool requires of the debugger before it acts. Mirror of the
  // Delphi TDebugPrecondition (Aefos.MCP.OTA.DebugPolicy.pas:55): dnNone = no
  // requirement, dnSession = needs a live debug session, dnStopped = needs the
  // debuggee PAUSED. Prefixed dn* (not dp*) purely to avoid any unit-scope clash.
  TAefosLazDebugNeed = (dnNone, dnSession, dnStopped);

// Pure precondition guard, byte-for-byte the Delphi TDebugPolicy.DebugGuard
// (DebugPolicy.pas:148): True => the tool may proceed; False with AReason set to
// the SAME machine-actionable kebab code the RAD edition returns, so the agent
// self-corrects identically across editions:
//   'no-debug-session' - needs a running debuggee -> RunProject and resend
//   'process-running'  - needs it stopped -> PauseRun / wait for a breakpoint
function _DebugGuard(const AState: TAefosLazDebugState;
  const ANeed: TAefosLazDebugNeed; out AReason: string): Boolean;
begin
  AReason := '';
  case ANeed of
    dnNone:
      Result := True;
    dnSession:
      begin
        Result := AState.HasSession;
        if not Result then
          AReason := 'no-debug-session';
      end;
    dnStopped:
      begin
        if not AState.HasSession then
        begin
          AReason := 'no-debug-session';
          Exit(False);
        end;
        Result := AState.Stopped;
        if not Result then
          AReason := 'process-running';
      end;
  else
    Result := False;
    AReason := 'unknown-precondition';
  end;
end;

// A guard-failure result: {"error":"<kebab reason>"} - the kebab reason IS the
// payload the agent keys off (mirrors the Delphi _GuardErr, Tools.Debug.pas:75).
function _DebugErr(const AReason: string): TMCPToolResult;
var
  LObj: TJSONObject;
begin
  LObj := TJSONObject.Create;
  try
    LObj.AddPair('error', AReason);
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

// The debug-state result the step/continue/pause/run-to-line tools return after
// dispatching, with an optional extra key (e.g. dispatched=true). Same shape as
// _HGetDebugState so the agent polls one consistent structure (mirrors the Delphi
// _StateResult, Tools.Debug.pas:112). The source-context field is a RAD-only extra
// (FormatSourceContext is not ported to Lazarus); everything else is identical.
function _DebugStateResult(const AState: TAefosLazDebugState;
  const AExtraKey, AExtraVal: string): TMCPToolResult;
var
  LObj: TJSONObject;
begin
  LObj := TJSONObject.Create;
  try
    LObj.AddPair('state', TAefosLazDebugService.FormatDebugState(AState));
    LObj.AddPair('hasSession', TJSONBool.Create(AState.HasSession));
    LObj.AddPair('stopped', TJSONBool.Create(AState.Stopped));
    if AState.Stopped then
    begin
      LObj.AddPair('file', AState.StopFile);
      LObj.AddPair('line', TJSONNumber.Create(Int64(AState.StopLine)));
      LObj.AddPair('thread', TJSONNumber.Create(Int64(AState.ThreadId)));
    end;
    if AExtraKey <> '' then
      LObj.AddPair(AExtraKey, AExtraVal);
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

{ ---- TAefosLazMcpToolsRegistrar ------------------------------------------- }

constructor TAefosLazMcpToolsRegistrar.Create(const AFacade: IMCPWorkspaceFacade);
begin
  inherited Create;
  if not Assigned(AFacade) then
    raise EArgumentNilException.Create('TAefosLazMcpToolsRegistrar: AFacade');
  FFacade := AFacade;
  FBuildManager := TMCPBuildManager.Create;
  FDebug := TAefosLazDebugService.Create;
  FLock := TCriticalSection.Create;
  // Default OFF: both edits and runs require a human Yes on the first attempt.
  // The TEST-ONLY env var pre-grants BOTH session gates (headless proof) - checked
  // exactly once here.
  FEditsAllowedThisSession :=
    GetEnvironmentVariable(cConsentAutograntEnvVar) = '1';
  FRunAllowedThisSession := FEditsAllowedThisSession;
end;

destructor TAefosLazMcpToolsRegistrar.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

function TAefosLazMcpToolsRegistrar._ConfigRoot: string;
begin
  // %APPDATA%\Aefos - the shared global root; the core appends \.aefos\config.json.
  // Qualified so a future `uses Windows` cannot hijack the 3-arg overload.
  Result := SysUtils.GetEnvironmentVariable('APPDATA') + '\Aefos';
end;

function TAefosLazMcpToolsRegistrar._ConsentModeAutoApproves(
  const AIsRun: Boolean): Boolean;
var
  LResolver: TConfigRootResolver;
  LConfig: IConfig;
  LMode: Integer;
begin
  Result := False;
  try
    LResolver := Self._ConfigRoot;
    LConfig := TConfigService.Create(LResolver);
    LConfig.Load;
    LMode := LConfig.Snapshot.AgentConsentMode;
    // Threshold is PER TOOL CLASS (Config.Types AgentConsentMode: 0 = ask, 1 =
    // auto-approve edits / ask before destructive, 2 = auto-approve everything):
    //   - RUN tools execute the user's binary, which mode 1 must still gate, so
    //     they auto-approve ONLY at mode 2.
    //   - Edit/design mutations auto-approve at mode >= 1.
    if AIsRun then
      Result := LMode >= 2
    else
      Result := LMode >= 1;
  except
    Result := False;   // a bad config read must never block/raise the consent path
  end;
end;

function TAefosLazMcpToolsRegistrar._EnsureWriteConsent(
  const AContext: IMCPToolContext; const AToolName: string;
  const AIsRun: Boolean = False): Boolean;
var
  LPrompt: TAefosLazConsentPrompt;
  LDecision: TMCPConsentDecision;
begin
  // Fast path: a prior Yes (or the test autogrant) granted THIS class of action
  // for the whole session - return immediately, no prompt (one prompt per class,
  // not per-call nagging). Edits and runs are tracked SEPARATELY.
  FLock.Enter;
  try
    if (AIsRun and FRunAllowedThisSession)
      or ((not AIsRun) and FEditsAllowedThisSession) then
    begin
      Result := True;
      Exit;
    end;
  finally
    FLock.Leave;
  end;

  // Shared consent-mode gate (TConfig.AgentConsentMode in config.json - ONE brain
  // with the RAD plugin), thresholded per tool class: edits at mode >= 1, runs
  // only at mode 2. Remember it for the session so later same-class actions hit
  // the fast path above. This is the owner's "auto approve / authorize execution".
  if _ConsentModeAutoApproves(AIsRun) then
  begin
    FLock.Enter;
    try
      if AIsRun then
        FRunAllowedThisSession := True
      else
        FEditsAllowedThisSession := True;
    finally
      FLock.Leave;
    end;
    Result := True;
    Exit;
  end;

  // First action of this class this session: ask the human on the IDE main thread
  // with a class-specific prompt (edit vs run). The prompt is a PER-CALL carrier
  // (never a shared field), so concurrent workers are safe. A run is asked
  // SEPARATELY even when editing was already granted (and vice versa).
  LPrompt := TAefosLazConsentPrompt.Create(AToolName, AIsRun);
  try
    AContext.MarshalToMainThread(LPrompt.Run);
    LDecision := LPrompt.FDecision;
  finally
    LPrompt.Free;
  end;

  // Three-way outcome (parity with the Delphi terminal consent):
  //   cdAllowSession -> proceed AND persist the matching session grant (under the
  //                     lock) so the next same-class action skips the prompt;
  //   cdAllowOnce    -> proceed THIS call only, record NO session grant (the next
  //                     same-class action prompts again);
  //   cdDenied       -> refuse; the caller raises EMCPUserDenied.
  if LDecision = cdAllowSession then
  begin
    FLock.Enter;
    try
      if AIsRun then
        FRunAllowedThisSession := True
      else
        FEditsAllowedThisSession := True;
    finally
      FLock.Leave;
    end;
  end;
  Result := LDecision in [cdAllowOnce, cdAllowSession];
end;

function TAefosLazMcpToolsRegistrar._HGetEditorActiveFile(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCall: TAefosLazMarshalCall;
  LObj: TJSONObject;
begin
  LCall := TAefosLazMarshalCall.Create(FFacade, ckGetEditorActiveFile);
  try
    AContext.MarshalToMainThread(LCall.Run);
    LObj := TJSONObject.Create;
    try
      if LCall.FOk then
      begin
        LObj.AddPair('name', LCall.FOutStr1);
        LObj.AddPair('path', LCall.FOutStr2);
      end
      else
      begin
        LObj.AddPair('name', '');
        LObj.AddPair('path', '');
      end;
      Result := TMCPToolResult.Text(LObj.ToJSON);
    finally
      LObj.Free;
    end;
  finally
    LCall.Free;
  end;
end;

function TAefosLazMcpToolsRegistrar._HGetEditorFullContent(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCall: TAefosLazMarshalCall;
  LObj: TJSONObject;
begin
  LCall := TAefosLazMarshalCall.Create(FFacade, ckGetEditorFullContent);
  try
    AContext.MarshalToMainThread(LCall.Run);
    LObj := TJSONObject.Create;
    try
      LObj.AddPair('value', LCall.FOutStr1);
      Result := TMCPToolResult.Text(LObj.ToJSON);
    finally
      LObj.Free;
    end;
  finally
    LCall.Free;
  end;
end;

function TAefosLazMcpToolsRegistrar._HGetOpenEditorFiles(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCall: TAefosLazMarshalCall;
  LArr: TJSONArray;
  LItem: TJSONObject;
  LIdx: Integer;
begin
  LCall := TAefosLazMarshalCall.Create(FFacade, ckGetOpenEditorFiles);
  try
    AContext.MarshalToMainThread(LCall.Run);
    LArr := TJSONArray.Create;
    try
      for LIdx := 0 to High(LCall.FFiles) do
      begin
        LItem := TJSONObject.Create;
        LItem.AddPair('name', LCall.FFiles[LIdx].Name);
        LItem.AddPair('path', LCall.FFiles[LIdx].Path);
        LItem.AddPair('modified', TJSONBool.Create(LCall.FFiles[LIdx].Modified));
        LArr.AddElement(LItem);
      end;
      Result := TMCPToolResult.Text(LArr.ToJSON);
    finally
      LArr.Free;
    end;
  finally
    LCall.Free;
  end;
end;

function TAefosLazMcpToolsRegistrar._HGetCursorPosition(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCall: TAefosLazMarshalCall;
  LObj: TJSONObject;
begin
  LCall := TAefosLazMarshalCall.Create(FFacade, ckGetCursorPosition);
  try
    AContext.MarshalToMainThread(LCall.Run);
    if not LCall.FCursor.Available then
    begin
      Result := TMCPToolResult.Text('null');
      Exit;
    end;
    LObj := TJSONObject.Create;
    try
      LObj.AddPair('unit_path', LCall.FCursor.UnitPath);
      LObj.AddPair('line', TJSONNumber.Create(Int64(LCall.FCursor.Line)));
      LObj.AddPair('column', TJSONNumber.Create(Int64(LCall.FCursor.Column)));
      Result := TMCPToolResult.Text(LObj.ToJSON);
    finally
      LObj.Free;
    end;
  finally
    LCall.Free;
  end;
end;

function TAefosLazMcpToolsRegistrar._HGetSelection(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCall: TAefosLazMarshalCall;
  LObj: TJSONObject;
begin
  LCall := TAefosLazMarshalCall.Create(FFacade, ckGetSelection);
  try
    AContext.MarshalToMainThread(LCall.Run);
    if not LCall.FSelection.Available then
    begin
      Result := TMCPToolResult.Text('null');
      Exit;
    end;
    LObj := TJSONObject.Create;
    try
      LObj.AddPair('unit_path', LCall.FSelection.UnitPath);
      LObj.AddPair('selection_text', LCall.FSelection.Text);
      LObj.AddPair('start_line', TJSONNumber.Create(Int64(LCall.FSelection.StartLine)));
      LObj.AddPair('start_column', TJSONNumber.Create(Int64(LCall.FSelection.StartColumn)));
      LObj.AddPair('end_line', TJSONNumber.Create(Int64(LCall.FSelection.EndLine)));
      LObj.AddPair('end_column', TJSONNumber.Create(Int64(LCall.FSelection.EndColumn)));
      Result := TMCPToolResult.Text(LObj.ToJSON);
    finally
      LObj.Free;
    end;
  finally
    LCall.Free;
  end;
end;

function TAefosLazMcpToolsRegistrar._HFindInEditor(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCall: TAefosLazMarshalCall;
  LArr: TJSONArray;
  LItem: TJSONObject;
  LIdx: Integer;
begin
  LCall := TAefosLazMarshalCall.Create(FFacade, ckFindInEditor);
  try
    LCall.FInStr1 := _OptStr(AParams, 'Text');
    LCall.FInBool1 := _OptBool(AParams, 'CaseSensitive');
    AContext.MarshalToMainThread(LCall.Run);
    LArr := TJSONArray.Create;
    try
      for LIdx := 0 to High(LCall.FOccurrences) do
      begin
        LItem := TJSONObject.Create;
        LItem.AddPair('line', TJSONNumber.Create(Int64(LCall.FOccurrences[LIdx].Line)));
        LItem.AddPair('col', TJSONNumber.Create(Int64(LCall.FOccurrences[LIdx].Column)));
        LArr.AddElement(LItem);
      end;
      Result := TMCPToolResult.Text(LArr.ToJSON);
    finally
      LArr.Free;
    end;
  finally
    LCall.Free;
  end;
end;

function TAefosLazMcpToolsRegistrar._HListIDEActions(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCall: TAefosLazMarshalCall;
begin
  LCall := TAefosLazMarshalCall.Create(FFacade, ckListIDEActions);
  try
    LCall.FInStr1 := _OptStr(AParams, 'filter');
    AContext.MarshalToMainThread(LCall.Run);
    // The facade already returns a JSON string {actions:[...], count:n}; pass it
    // through verbatim (its shape is the parity contract).
    Result := TMCPToolResult.Text(LCall.FOutStr1);
  finally
    LCall.Free;
  end;
end;

function TAefosLazMcpToolsRegistrar._HExecuteIDEAction(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCall: TAefosLazMarshalCall;
begin
  // Fires a named IDE command (build/run/format/view-toggle/...) - the Lazarus
  // twin of the OTA ExecuteIDEAction handler (source\mcp\Core\...Tools.IDE.pas:617).
  // CONSENT-GATED (mirror of the Delphi _Gate): this can trigger a mutating command,
  // so it is NOT read-only-neutral - it passes the same write-consent gate as the
  // editor/designer mutations. RULE #1: deliberately NOT view-guarded (it may itself
  // flip the view, e.g. ecToggleFormUnit = F12); the block-token safety net in the
  // facade plus this consent gate are its guards.
  if not _EnsureWriteConsent(AContext, 'ExecuteIDEAction') then
    raise EMCPUserDenied.Create('User denied ExecuteIDEAction (Aefos MCP write consent)');
  LCall := TAefosLazMarshalCall.Create(FFacade, ckExecuteIDEAction);
  try
    LCall.FInStr1 := _OptStr(AParams, 'ActionName');
    AContext.MarshalToMainThread(LCall.Run);
    // Mirror of the OTA handler: applied -> {applied:true}; not applied WITH a reason
    // -> EMCPInvalidParams carrying a machine-actionable data.detail (also the channel
    // the '?' catalog-dump path surfaces its file path through).
    if (not LCall.FOk) and (LCall.FOutStr1 <> '') then
      raise EMCPInvalidParams.Create('ExecuteIDEAction: ' + LCall.FOutStr1
        + '; data.detail={"reason":"' + LCall.FOutStr1 + '"}');
    Result := _BoolResult(LCall.FOk);
  finally
    LCall.Free;
  end;
end;

function TAefosLazMcpToolsRegistrar._HOpenTerminal(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCall: TAefosLazMarshalCall;
  LObj: TJSONObject;
begin
  // Neutral / RULE #1 EXEMPT (like ListIDEActions): opens the docked Aefos AI
  // terminal panel so the agent can run shell commands in the IDE. Show is UI work
  // (creates/focuses/docks the panel), so it MUST run on the IDE main thread --
  // marshalled through the per-call carrier. NOT consent-gated: it opens a panel,
  // it does not run the user's project binary.
  LCall := TAefosLazMarshalCall.Create(FFacade, ckOpenTerminal);
  try
    AContext.MarshalToMainThread(LCall.Run);
    LObj := TJSONObject.Create;
    try
      LObj.AddPair('applied', TJSONBool.Create(LCall.FOutBool));
      LObj.AddPair('ok', TJSONBool.Create(LCall.FOutBool));
      LObj.AddPair('reason', LCall.FOutReason);
      Result := TMCPToolResult.Text(LObj.ToJSON);
    finally
      LObj.Free;
    end;
  finally
    LCall.Free;
  end;
end;

function TAefosLazMcpToolsRegistrar._HGetReviewFeedback(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCall: TAefosLazMarshalCall;
  LObj: TJSONObject;
begin
  // Returns AND CLEARS the user's review annotations (parity with the RAD
  // GetReviewFeedback). Drain runs on the IDE main thread -- approve/reject mutate
  // GReviewFeedback there, so marshalling avoids a cross-thread race. Output JSON
  // {feedback, count} is byte-shape identical to the RAD tool.
  LCall := TAefosLazMarshalCall.Create(FFacade, ckGetReviewFeedback);
  try
    AContext.MarshalToMainThread(LCall.Run);
    LObj := TJSONObject.Create;
    try
      LObj.AddPair('feedback', LCall.FOutStr1);
      LObj.AddPair('count', TJSONNumber.Create(LCall.FOutInt));
      Result := TMCPToolResult.Text(LObj.ToJSON);
    finally
      LObj.Free;
    end;
  finally
    LCall.Free;
  end;
end;

function TAefosLazMcpToolsRegistrar._HGetPendingReviews(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCall: TAefosLazMarshalCall;
  LObj: TJSONObject;
begin
  // Lists the still-PENDING edits in the review gutter (parity with the RAD
  // GetPendingReviews). Read-only -- does NOT clear. Runs on the IDE main thread
  // (GChanges is mutated there). Output JSON {pending, count}.
  LCall := TAefosLazMarshalCall.Create(FFacade, ckGetPendingReviews);
  try
    AContext.MarshalToMainThread(LCall.Run);
    LObj := TJSONObject.Create;
    try
      LObj.AddPair('pending', LCall.FOutStr1);
      LObj.AddPair('count', TJSONNumber.Create(LCall.FOutInt));
      Result := TMCPToolResult.Text(LObj.ToJSON);
    finally
      LObj.Free;
    end;
  finally
    LCall.Free;
  end;
end;

function TAefosLazMcpToolsRegistrar._IssueReportingEnabled: Boolean;
var
  LResolver: TConfigRootResolver;
  LConfig: IConfig;
begin
  // Read the shared TConfig.IssueReporting off the transport worker (same pattern
  // as _ConsentModeAutoApproves). %APPDATA%\Aefos\.aefos\config.json is the SAME
  // file the RAD plugin's AI Flow page persists the toggle into, so enabling it in
  // either edition enables it in both. A bad read keeps issue reporting OFF.
  Result := False;
  try
    LResolver := Self._ConfigRoot;
    LConfig := TConfigService.Create(LResolver);
    LConfig.Load;
    Result := LConfig.Snapshot.IssueReporting;
  except
    Result := False;
  end;
end;

function TAefosLazMcpToolsRegistrar._HProposeAefosIssue(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCall: TAefosLazMarshalCall;
  LObj: TJSONObject;
begin
  // Gated by the shared "Issue reporting" toggle (Tools > Options > Aefos > AI
  // Flow). When OFF (the default) the editable dialog NEVER opens and we return
  // {sent:false, message} - so a misbehaving / hallucinating agent can never spam
  // the dialog (parity with the Delphi TAIFlowOptions.IssueReportingEnabled gate).
  if not _IssueReportingEnabled then
  begin
    LObj := TJSONObject.Create;
    try
      LObj.AddPair('sent', TJSONBool.Create(False));
      LObj.AddPair('message',
        'Issue reporting is disabled. The user can enable it in ' +
        'Tools > Options > Aefos > AI Flow > Issue reporting.');
      Result := TMCPToolResult.Text(LObj.ToJSON);
    finally
      LObj.Free;
    end;
    Exit;
  end;
  // Enabled: show the editable dialog (agent prose pre-filled + a plugin-supplied
  // FACT block) and, on Send, open the pre-filled GitHub new-issue URL. The UI +
  // browser launch belong on the IDE main thread - marshalled via the per-call
  // carrier. FInStr1=title, FInStr2=problem, FInStr3=possibleSolution ->
  // FOutBool=sent, FOutStr1=url.
  LCall := TAefosLazMarshalCall.Create(FFacade, ckProposeAefosIssue);
  try
    LCall.FInStr1 := _OptStr(AParams, 'title');
    LCall.FInStr2 := _OptStr(AParams, 'problem');
    LCall.FInStr3 := _OptStr(AParams, 'possibleSolution');
    AContext.MarshalToMainThread(LCall.Run);
    LObj := TJSONObject.Create;
    try
      LObj.AddPair('sent', TJSONBool.Create(LCall.FOutBool));
      if LCall.FOutBool then
        LObj.AddPair('url', LCall.FOutStr1)
      else
        LObj.AddPair('message', 'User cancelled - no issue was opened.');
      Result := TMCPToolResult.Text(LObj.ToJSON);
    finally
      LObj.Free;
    end;
  finally
    LCall.Free;
  end;
end;

function TAefosLazMcpToolsRegistrar._HEditUnit(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCall: TAefosLazMarshalCall;
  LObj: TJSONObject;
  LOutcome, LNewText, LGuardReason: string;
begin
  // RULE #1 hard brake on the anchored path: an EditUnit whose inserted new_text
  // BUILDS a form (creates + parents a standard LCL control in code) is refused
  // with an actionable reason. The guard runs on the DELTA (new_text) so it fires
  // only when THIS edit introduces the UI-in-code, never on incremental edits to a
  // unit that already happens to contain such code elsewhere.
  LNewText := _OptStr(AParams, 'new_text');
  LGuardReason := TFlowGuide.SourceBuildsStandardControlsInCodeReason(LNewText);
  if LGuardReason <> '' then
  begin
    LObj := TJSONObject.Create;
    try
      LObj.AddPair('applied', TJSONBool.Create(False));
      LObj.AddPair('outcome', MCP_REASON_CODE_BUILDS_UI);
      LObj.AddPair('error', LGuardReason);
      Result := TMCPToolResult.Text(LObj.ToJSON);
    finally
      LObj.Free;
    end;
    Exit;
  end;
  if not _EnsureWriteConsent(AContext, 'EditUnit') then
    raise EMCPUserDenied.Create('User denied EditUnit (Aefos MCP write consent)');
  LCall := TAefosLazMarshalCall.Create(FFacade, ckEditUnit);
  try
    LCall.FInStr1 := _OptStr(AParams, 'unit_path');
    LCall.FInStr2 := _OptStr(AParams, 'old_text');
    LCall.FInStr3 := LNewText;
    AContext.MarshalToMainThread(LCall.Run);
    case LCall.FEditOutcome of
      eoApplied:         LOutcome := 'applied';
      eoUnitNotOpen:     LOutcome := 'unit-not-open';
      eoAnchorNotFound:  LOutcome := 'anchor-not-found';
      eoAnchorAmbiguous: LOutcome := 'anchor-ambiguous';
      eoUserRejected:    LOutcome := 'user-rejected';
    else
      LOutcome := 'unknown';
    end;
    LObj := TJSONObject.Create;
    try
      LObj.AddPair('applied', TJSONBool.Create(LCall.FEditOutcome = eoApplied));
      LObj.AddPair('outcome', LOutcome);
      LObj.AddPair('error', LCall.FOutStr1);
      Result := TMCPToolResult.Text(LObj.ToJSON);
    finally
      LObj.Free;
    end;
  finally
    LCall.Free;
  end;
end;

function TAefosLazMcpToolsRegistrar._HInsertCodeAtCursor(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCall: TAefosLazMarshalCall;
begin
  if not _EnsureWriteConsent(AContext, 'InsertCodeAtCursor') then
    raise EMCPUserDenied.Create('User denied InsertCodeAtCursor (Aefos MCP write consent)');
  LCall := TAefosLazMarshalCall.Create(FFacade, ckInsertCodeAtCursor);
  try
    LCall.FInStr1 := _OptStr(AParams, 'Code');
    AContext.MarshalToMainThread(LCall.Run);
    Result := _BoolResult(LCall.FOutBool);
  finally
    LCall.Free;
  end;
end;

function TAefosLazMcpToolsRegistrar._HReplaceEditorSelection(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCall: TAefosLazMarshalCall;
begin
  if not _EnsureWriteConsent(AContext, 'ReplaceEditorSelection') then
    raise EMCPUserDenied.Create('User denied ReplaceEditorSelection (Aefos MCP write consent)');
  LCall := TAefosLazMarshalCall.Create(FFacade, ckReplaceEditorSelection);
  try
    LCall.FInStr1 := _OptStr(AParams, 'NewText');
    AContext.MarshalToMainThread(LCall.Run);
    Result := _BoolResult(LCall.FOutBool);
  finally
    LCall.Free;
  end;
end;

function TAefosLazMcpToolsRegistrar._HSetEditorFullContent(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCall: TAefosLazMarshalCall;
  LSource, LGuardReason: string;
begin
  // RULE #1 hard brake, surfaced with its actionable reason (the owner's rigid
  // decision): a wholesale .pas write must NEVER build a form by creating standard
  // LCL controls in code — refuse BEFORE prompting for consent (no point asking to
  // apply a write that will be refused). The facade re-checks as defense in depth.
  LSource := _OptStr(AParams, 'Source');
  LGuardReason := TFlowGuide.SourceBuildsStandardControlsInCodeReason(LSource);
  if LGuardReason <> '' then
  begin
    Result := _BlockedResult(LGuardReason);
    Exit;
  end;
  if not _EnsureWriteConsent(AContext, 'SetEditorFullContent') then
    raise EMCPUserDenied.Create('User denied SetEditorFullContent (Aefos MCP write consent)');
  LCall := TAefosLazMarshalCall.Create(FFacade, ckSetEditorFullContent);
  try
    LCall.FInStr1 := LSource;
    AContext.MarshalToMainThread(LCall.Run);
    // A false result is the facade's OWN guard (pas<->lfm desync) refusing the
    // rewrite - surfaced as applied=false, not an error/crash.
    Result := _BoolResult(LCall.FOutBool);
  finally
    LCall.Free;
  end;
end;

function TAefosLazMcpToolsRegistrar._HReplaceInEditor(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCall: TAefosLazMarshalCall;
  LObj: TJSONObject;
begin
  if not _EnsureWriteConsent(AContext, 'ReplaceInEditor') then
    raise EMCPUserDenied.Create('User denied ReplaceInEditor (Aefos MCP write consent)');
  LCall := TAefosLazMarshalCall.Create(FFacade, ckReplaceInEditor);
  try
    LCall.FInStr1 := _OptStr(AParams, 'Find');
    LCall.FInStr2 := _OptStr(AParams, 'Replace');
    LCall.FInBool1 := _OptBool(AParams, 'All');
    AContext.MarshalToMainThread(LCall.Run);
    LObj := TJSONObject.Create;
    try
      LObj.AddPair('value', TJSONNumber.Create(Int64(LCall.FOutInt)));
      Result := TMCPToolResult.Text(LObj.ToJSON);
    finally
      LObj.Free;
    end;
  finally
    LCall.Free;
  end;
end;

function TAefosLazMcpToolsRegistrar._HSaveActiveFile(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCall: TAefosLazMarshalCall;
  LObj: TJSONObject;
begin
  if not _EnsureWriteConsent(AContext, 'SaveActiveFile') then
    raise EMCPUserDenied.Create('User denied SaveActiveFile (Aefos MCP write consent)');
  LCall := TAefosLazMarshalCall.Create(FFacade, ckSaveActiveFile);
  try
    AContext.MarshalToMainThread(LCall.Run);
    LObj := TJSONObject.Create;
    try
      LObj.AddPair('value', TJSONBool.Create(LCall.FOutBool));
      LObj.AddPair('applied', TJSONBool.Create(LCall.FOutBool));
      LObj.AddPair('changed', TJSONBool.Create(LCall.FOk));
      Result := TMCPToolResult.Text(LObj.ToJSON);
    finally
      LObj.Free;
    end;
  finally
    LCall.Free;
  end;
end;

function TAefosLazMcpToolsRegistrar._HSaveAllFiles(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCall: TAefosLazMarshalCall;
  LObj: TJSONObject;
begin
  if not _EnsureWriteConsent(AContext, 'SaveAllFiles') then
    raise EMCPUserDenied.Create('User denied SaveAllFiles (Aefos MCP write consent)');
  LCall := TAefosLazMarshalCall.Create(FFacade, ckSaveAllFiles);
  try
    AContext.MarshalToMainThread(LCall.Run);
    LObj := TJSONObject.Create;
    try
      LObj.AddPair('value', TJSONBool.Create(LCall.FOutBool));
      LObj.AddPair('applied', TJSONBool.Create(LCall.FOutBool));
      LObj.AddPair('changed', TJSONBool.Create(LCall.FOk));
      Result := TMCPToolResult.Text(LObj.ToJSON);
    finally
      LObj.Free;
    end;
  finally
    LCall.Free;
  end;
end;

function TAefosLazMcpToolsRegistrar._HUndoEditor(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCall: TAefosLazMarshalCall;
begin
  if not _EnsureWriteConsent(AContext, 'UndoEditor') then
    raise EMCPUserDenied.Create('User denied UndoEditor (Aefos MCP write consent)');
  LCall := TAefosLazMarshalCall.Create(FFacade, ckUndoEditor);
  try
    AContext.MarshalToMainThread(LCall.Run);
    Result := _BoolResult(LCall.FOutBool);
  finally
    LCall.Free;
  end;
end;

{ ---- Phase J live form designer handlers ---------------------------------- }

function TAefosLazMcpToolsRegistrar._HAddComponent(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCall: TAefosLazMarshalCall;
begin
  if not _EnsureWriteConsent(AContext, 'AddComponent') then
    raise EMCPUserDenied.Create('User denied AddComponent (Aefos MCP write consent)');
  LCall := TAefosLazMarshalCall.Create(FFacade, ckAddComponent);
  try
    LCall.FInStr1 := _OptStr(AParams, 'unit_name');
    LCall.FInStr2 := _OptStr(AParams, 'component_class');
    LCall.FInStr3 := _OptStr(AParams, 'component_name');
    LCall.FInStr4 := _OptStr(AParams, 'parent');
    LCall.FInInt1 := _OptInt(AParams, 'left');
    LCall.FInInt2 := _OptInt(AParams, 'top');
    LCall.FInInt3 := _OptInt(AParams, 'width');
    LCall.FInInt4 := _OptInt(AParams, 'height');
    AContext.MarshalToMainThread(LCall.Run);
    Result := _DesignResult(LCall.FOutBool, LCall.FOutChanged, LCall.FOutReason);
  finally
    LCall.Free;
  end;
end;

function TAefosLazMcpToolsRegistrar._HRemoveComponent(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCall: TAefosLazMarshalCall;
begin
  if not _EnsureWriteConsent(AContext, 'RemoveComponent') then
    raise EMCPUserDenied.Create('User denied RemoveComponent (Aefos MCP write consent)');
  LCall := TAefosLazMarshalCall.Create(FFacade, ckRemoveComponent);
  try
    LCall.FInStr1 := _OptStr(AParams, 'unit_name');
    LCall.FInStr2 := _OptStr(AParams, 'component_name');
    AContext.MarshalToMainThread(LCall.Run);
    Result := _DesignResult(LCall.FOutBool, LCall.FOutChanged, LCall.FOutReason);
  finally
    LCall.Free;
  end;
end;

function TAefosLazMcpToolsRegistrar._HSetComponentProperty(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCall: TAefosLazMarshalCall;
begin
  if not _EnsureWriteConsent(AContext, 'SetComponentProperty') then
    raise EMCPUserDenied.Create('User denied SetComponentProperty (Aefos MCP write consent)');
  LCall := TAefosLazMarshalCall.Create(FFacade, ckSetComponentProperty);
  try
    LCall.FInStr1 := _OptStr(AParams, 'unit_name');
    LCall.FInStr2 := _OptStr(AParams, 'component_name');
    LCall.FInStr3 := _OptStr(AParams, 'prop_name');
    LCall.FInStr4 := _OptStr(AParams, 'prop_value');
    AContext.MarshalToMainThread(LCall.Run);
    Result := _DesignResult(LCall.FOutBool, LCall.FOutChanged, LCall.FOutReason);
  finally
    LCall.Free;
  end;
end;

function TAefosLazMcpToolsRegistrar._HSetFormProperty(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCall: TAefosLazMarshalCall;
begin
  if not _EnsureWriteConsent(AContext, 'SetFormProperty') then
    raise EMCPUserDenied.Create('User denied SetFormProperty (Aefos MCP write consent)');
  LCall := TAefosLazMarshalCall.Create(FFacade, ckSetFormProperty);
  try
    LCall.FInStr1 := _OptStr(AParams, 'unit_name');
    LCall.FInStr2 := _OptStr(AParams, 'prop_name');
    LCall.FInStr3 := _OptStr(AParams, 'prop_value');
    AContext.MarshalToMainThread(LCall.Run);
    Result := _DesignResult(LCall.FOutBool, LCall.FOutChanged, LCall.FOutReason);
  finally
    LCall.Free;
  end;
end;

function TAefosLazMcpToolsRegistrar._HAddEventHandler(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCall: TAefosLazMarshalCall;
begin
  if not _EnsureWriteConsent(AContext, 'AddEventHandler') then
    raise EMCPUserDenied.Create('User denied AddEventHandler (Aefos MCP write consent)');
  LCall := TAefosLazMarshalCall.Create(FFacade, ckAddEventHandler);
  try
    LCall.FInStr1 := _OptStr(AParams, 'unit_name');
    LCall.FInStr2 := _OptStr(AParams, 'component_name');
    LCall.FInStr3 := _OptStr(AParams, 'event_name');
    LCall.FInStr4 := _OptStr(AParams, 'handler_name');
    LCall.FInStr5 := _OptStr(AParams, 'body');
    AContext.MarshalToMainThread(LCall.Run);
    Result := _DesignResult(LCall.FOutBool, LCall.FOutChanged, LCall.FOutReason);
  finally
    LCall.Free;
  end;
end;

function TAefosLazMcpToolsRegistrar._HOpenFormDesigner(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCall: TAefosLazMarshalCall;
begin
  // View-switch (RULE #1 exempt): NOT consent-gated - it moves the view, it does
  // not mutate code/form. Registered tiNeutral so the guard lets it through.
  LCall := TAefosLazMarshalCall.Create(FFacade, ckOpenFormDesigner);
  try
    LCall.FInStr1 := _OptStr(AParams, 'unit_name');
    AContext.MarshalToMainThread(LCall.Run);
    Result := _DesignResult(LCall.FOutBool, LCall.FOutChanged, LCall.FOutReason);
  finally
    LCall.Free;
  end;
end;

function TAefosLazMcpToolsRegistrar._HGetDFMContent(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCall: TAefosLazMarshalCall;
  LObj: TJSONObject;
begin
  // Design READ (neutral, never gated): serializes the LIVE form to .lfm text.
  LCall := TAefosLazMarshalCall.Create(FFacade, ckGetDFMContent);
  try
    LCall.FInStr1 := _OptStr(AParams, 'unit_name');
    AContext.MarshalToMainThread(LCall.Run);
    LObj := TJSONObject.Create;
    try
      LObj.AddPair('content', LCall.FOutStr1);
      LObj.AddPair('is_binary', TJSONBool.Create(LCall.FOutBool2));
      LObj.AddPair('found', TJSONBool.Create(LCall.FOk));
      Result := TMCPToolResult.Text(LObj.ToJSON);
    finally
      LObj.Free;
    end;
  finally
    LCall.Free;
  end;
end;

function TAefosLazMcpToolsRegistrar._HListFormComponents(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCall: TAefosLazMarshalCall;
  LArr: TJSONArray;
  LItem: TJSONObject;
  LIdx: Integer;
begin
  LCall := TAefosLazMarshalCall.Create(FFacade, ckListFormComponents);
  try
    LCall.FInStr1 := _OptStr(AParams, 'unit_name');
    AContext.MarshalToMainThread(LCall.Run);
    LArr := TJSONArray.Create;
    try
      for LIdx := 0 to High(LCall.FDfmComps) do
      begin
        LItem := TJSONObject.Create;
        LItem.AddPair('name', LCall.FDfmComps[LIdx].Name);
        LItem.AddPair('type', LCall.FDfmComps[LIdx].TypeName);
        LItem.AddPair('owner', LCall.FDfmComps[LIdx].Owner);
        LArr.AddElement(LItem);
      end;
      Result := TMCPToolResult.Text(LArr.ToJSON);
    finally
      LArr.Free;
    end;
  finally
    LCall.Free;
  end;
end;

function TAefosLazMcpToolsRegistrar._HGetComponentProperties(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCall: TAefosLazMarshalCall;
  LArr: TJSONArray;
  LItem: TJSONObject;
  LIdx: Integer;
begin
  LCall := TAefosLazMarshalCall.Create(FFacade, ckGetComponentProperties);
  try
    LCall.FInStr1 := _OptStr(AParams, 'unit_name');
    LCall.FInStr2 := _OptStr(AParams, 'component_name');
    AContext.MarshalToMainThread(LCall.Run);
    LArr := TJSONArray.Create;
    try
      for LIdx := 0 to High(LCall.FDfmProps) do
      begin
        LItem := TJSONObject.Create;
        LItem.AddPair('name', LCall.FDfmProps[LIdx].Name);
        LItem.AddPair('value', LCall.FDfmProps[LIdx].Value);
        LArr.AddElement(LItem);
      end;
      Result := TMCPToolResult.Text(LArr.ToJSON);
    finally
      LArr.Free;
    end;
  finally
    LCall.Free;
  end;
end;

function TAefosLazMcpToolsRegistrar._HGetFormProperties(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCall: TAefosLazMarshalCall;
  LArr: TJSONArray;
  LItem: TJSONObject;
  LIdx: Integer;
begin
  LCall := TAefosLazMarshalCall.Create(FFacade, ckGetFormProperties);
  try
    LCall.FInStr1 := _OptStr(AParams, 'unit_name');
    AContext.MarshalToMainThread(LCall.Run);
    LArr := TJSONArray.Create;
    try
      for LIdx := 0 to High(LCall.FDfmProps) do
      begin
        LItem := TJSONObject.Create;
        LItem.AddPair('name', LCall.FDfmProps[LIdx].Name);
        LItem.AddPair('value', LCall.FDfmProps[LIdx].Value);
        LArr.AddElement(LItem);
      end;
      Result := TMCPToolResult.Text(LArr.ToJSON);
    finally
      LArr.Free;
    end;
  finally
    LCall.Free;
  end;
end;

{ ---- view-switch to Code + agent-vision capture --------------------------- }

// Reads the optional unit-name param. The Lazarus design tools use 'unit_name';
// the Delphi edition's OpenUnitInEditor/CaptureForm schemas use 'UnitName'. Both
// are accepted so the SAME agent prompt drives either edition (empty = the active
// editor / the form open in the Designer, exactly like the Delphi tools).
function _OptUnitName(const AParams: TJSONObject): string;
begin
  Result := _OptStr(AParams, 'unit_name');
  if Result = '' then
    Result := _OptStr(AParams, 'UnitName');
end;

function TAefosLazMcpToolsRegistrar._HOpenUnitInEditor(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCall: TAefosLazMarshalCall;
begin
  // View-switch (RULE #1 EXEMPT): flips the IDE to Code by focusing the unit's
  // source editor. NOT consent-gated - it moves the view, it does not mutate.
  // Registered tiNeutral so the server guard lets it through. Result mirrors the
  // sibling OpenFormDesigner's {applied, changed, reason}: applied/changed are
  // true when an editor was brought to Code, false with a machine-actionable
  // reason when the unit is neither open nor openable from disk.
  LCall := TAefosLazMarshalCall.Create(FFacade, ckOpenUnitInEditor);
  try
    LCall.FInStr1 := _OptUnitName(AParams);
    AContext.MarshalToMainThread(LCall.Run);
    if LCall.FOutBool then
      Result := _DesignResult(True, True, '')
    else
      Result := _DesignResult(False, False,
        'unit-not-open: the unit is not open in the editor and could not be '
        + 'opened from disk (pass a path/name that exists in the project, or open '
        + 'it first)');
  finally
    LCall.Free;
  end;
end;

function TAefosLazMcpToolsRegistrar._HCaptureForm(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCall: TAefosLazMarshalCall;
  LContent: string;
begin
  // Agent-vision READ (RULE #1 EXEMPT, never gated): renders the LIVE designer
  // form to a PNG and returns it INLINE (TMCPToolResult.Image) so a vision model
  // literally SEES the layout and self-corrects. Mirrors the Delphi
  // _HandleCaptureForm - same accompanying text, same image content block, and a
  // failure surfaces as an invalid-params error (form-not-found / capture-
  // unavailable), not a crash.
  LCall := TAefosLazMarshalCall.Create(FFacade, ckCaptureForm);
  try
    LCall.FInStr1 := _OptUnitName(AParams);
    AContext.MarshalToMainThread(LCall.Run);
    if not LCall.FOk then
      raise EMCPInvalidParams.Create('CaptureForm: ' + LCall.FOutReason);
    LContent :=
      'Screenshot of the live form (PNG) attached. Look at it and fix anything '
      + 'wrong: a leftover placeholder Caption (e.g. a panel still showing its own '
      + 'name), a control hidden behind another, a missing/broken glyph, or a '
      + 'misaligned control.';
    if LCall.FOutStr2 <> '' then
      LContent := LContent + ' (saved to ' + LCall.FOutStr2 + ')';
    Result := TMCPToolResult.Image(LCall.FOutStr1, 'image/png', LContent);
  finally
    LCall.Free;
  end;
end;

{ ---- build/run group ------------------------------------------------------ }

// Reads RunBuild's optional `mode`, defaulting to 'make'. A non-string mode or
// any value other than 'make'/'build' is rejected with -32602 (mirrors the
// Delphi _ReadBuildMode).
function _ReadBuildMode(const AParams: TJSONObject): string;
var
  LValue: TJSONValue;
begin
  Result := 'make';
  if AParams = nil then
    Exit;
  LValue := AParams.GetValue('mode');
  if LValue = nil then
    Exit;
  if not (LValue is TJSONString) then
    raise EMCPInvalidParams.Create('RunBuild: mode must be a string');
  Result := TJSONString(LValue).Value;
  if (Result <> 'make') and (Result <> 'build') then
    raise EMCPInvalidParams.Create('RunBuild: mode must be "make" or "build"');
end;

// Maps a build state to the GetBuildStatus `status` token (parity with the
// Delphi _BuildStateToken).
function _BuildStateToken(const AState: TMCPBuildState): string;
begin
  case AState of
    bsSucceeded: Result := 'succeeded';
    bsFailed:    Result := 'failed';
    bsCancelled: Result := 'cancelled';
  else
    Result := 'running';
  end;
end;

// Maps a compiler severity to the GetCompilerErrors `severity` token.
function _SeverityToken(const ASeverity: TMCPCompilerSeverity): string;
begin
  case ASeverity of
    csWarning: Result := 'warning';
    csHint:    Result := 'hint';
  else
    Result := 'error';
  end;
end;

function TAefosLazMcpToolsRegistrar._HRunBuild(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCall: TAefosLazMarshalCall;
  LResultCall: TAefosLazMarshalCall;
  LMode, LBuildId: string;
  LObj: TJSONObject;
begin
  // NOT consent-gated: a compile never mutates source (mirrors the Delphi
  // RunBuild, which is un-gated).
  LMode := _ReadBuildMode(AParams);
  // Single-active-build model: RESERVE the slot + mint the id ATOMICALLY under
  // FLock, BEFORE StartBuild. Doing the HasActiveBuild check and the Register in
  // one locked section closes the check-then-act race where two concurrent
  // RunBuild workers both see "no active build" and clobber each other (the
  // transport is multi-client). The second concurrent RunBuild now sees the
  // reserved bsRunning job and is rejected here.
  FLock.Enter;
  try
    if FBuildManager.HasActiveBuild then
      raise EMCPBuildInProgress.Create('RunBuild: a build is already in progress');
    LBuildId := FBuildManager.NewBuildId;
    FBuildManager.Register(LBuildId); // bsRunning - HasActiveBuild is now true
  finally
    FLock.Leave;
  end;
  LCall := TAefosLazMarshalCall.Create(FFacade, ckStartBuild);
  try
    LCall.FInStr1 := LMode;
    AContext.MarshalToMainThread(LCall.Run);
    if not LCall.FOutBool then
    begin
      // Free the reserved slot (resolve to failed) so the next RunBuild is not
      // blocked, then surface the failure with no build_id.
      FBuildManager.SetState(LBuildId, bsFailed);
      raise EMCPError.Create(MCP_ERR_SERVER, 'RunBuild: ' + LCall.FOutStr1);
    end;
  finally
    LCall.Free;
  end;
  // Lazarus's build is SYNCHRONOUS, so capture the final outcome NOW and store it
  // KEYED by build_id in the manager - never leaning on the facade's single
  // FLastBuildState transfer field across polls (a later concurrent build would
  // overwrite it). GetBuildStatus then just reads the keyed, already-resolved
  // state. The reserved bsRunning job kept a second build blocked throughout, so
  // FLastBuildState cannot cross-talk between StartBuild and this read.
  LResultCall := TAefosLazMarshalCall.Create(FFacade, ckQueryBuildResult);
  try
    AContext.MarshalToMainThread(LResultCall.Run);
    FBuildManager.SetState(LBuildId, LResultCall.FBuildState);
  finally
    LResultCall.Free;
  end;
  LObj := TJSONObject.Create;
  try
    LObj.AddPair('build_id', LBuildId);
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function TAefosLazMcpToolsRegistrar._HGetBuildStatus(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LBuildId: string;
  LState: TMCPBuildState;
  LObj: TJSONObject;
begin
  LBuildId := _OptStr(AParams, 'build_id');
  // The state was resolved and stored KEYED by build_id in _HRunBuild (the
  // synchronous build finished before RunBuild returned the id), so this is a
  // pure lookup - each build_id carries its OWN outcome, no cross-talk between
  // concurrent builds. An unknown/expired id errors. No cancellation branch: a
  // synchronous build cannot be aborted mid-flight (CancelBuild is a no-op).
  if not FBuildManager.GetState(LBuildId, LState) then
    raise EMCPError.Create(MCP_ERR_SERVER,
      'GetBuildStatus: unknown build_id: ' + LBuildId);
  LObj := TJSONObject.Create;
  try
    LObj.AddPair('build_id', LBuildId);
    LObj.AddPair('status', _BuildStateToken(LState));
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function TAefosLazMcpToolsRegistrar._HGetCompilerErrors(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCall: TAefosLazMarshalCall;
  LArr: TJSONArray;
  LItem: TJSONObject;
  LIdx: Integer;
begin
  // Read: harvests the live IDE message view. Never gated.
  LCall := TAefosLazMarshalCall.Create(FFacade, ckGetCompilerMessages);
  try
    AContext.MarshalToMainThread(LCall.Run);
    LArr := TJSONArray.Create;
    try
      for LIdx := 0 to High(LCall.FCompilerMsgs) do
      begin
        LItem := TJSONObject.Create;
        LItem.AddPair('path', LCall.FCompilerMsgs[LIdx].Path);
        LItem.AddPair('line', TJSONNumber.Create(Int64(LCall.FCompilerMsgs[LIdx].Line)));
        LItem.AddPair('column', TJSONNumber.Create(Int64(LCall.FCompilerMsgs[LIdx].Column)));
        LItem.AddPair('severity', _SeverityToken(LCall.FCompilerMsgs[LIdx].Severity));
        LItem.AddPair('text', LCall.FCompilerMsgs[LIdx].Text);
        LArr.AddElement(LItem);
      end;
      Result := TMCPToolResult.Text(LArr.ToJSON);
    finally
      LArr.Free;
    end;
  finally
    LCall.Free;
  end;
end;

// Shared body for the three consent-gated runtime tools (RunProject /
// RunWithoutDebugger / StopProject): gate on the session write-consent, marshal
// the facade call, return {applied}. Mirrors the Delphi _RunLifecycle.
function TAefosLazMcpToolsRegistrar._HRunProject(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCall: TAefosLazMarshalCall;
  LObj: TJSONObject;
begin
  if not _EnsureWriteConsent(AContext, 'RunProject', True) then
    raise EMCPUserDenied.Create('User denied RunProject (Aefos MCP action consent)');
  LCall := TAefosLazMarshalCall.Create(FFacade, ckRunProject);
  try
    AContext.MarshalToMainThread(LCall.Run);
    LObj := TJSONObject.Create;
    try
      LObj.AddPair('applied', TJSONBool.Create(LCall.FOutBool));
      Result := TMCPToolResult.Text(LObj.ToJSON);
    finally
      LObj.Free;
    end;
  finally
    LCall.Free;
  end;
end;

function TAefosLazMcpToolsRegistrar._HRunWithoutDebugger(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCall: TAefosLazMarshalCall;
  LObj: TJSONObject;
begin
  if not _EnsureWriteConsent(AContext, 'RunWithoutDebugger', True) then
    raise EMCPUserDenied.Create('User denied RunWithoutDebugger (Aefos MCP action consent)');
  LCall := TAefosLazMarshalCall.Create(FFacade, ckRunWithoutDebugger);
  try
    AContext.MarshalToMainThread(LCall.Run);
    LObj := TJSONObject.Create;
    try
      LObj.AddPair('applied', TJSONBool.Create(LCall.FOutBool));
      Result := TMCPToolResult.Text(LObj.ToJSON);
    finally
      LObj.Free;
    end;
  finally
    LCall.Free;
  end;
end;

function TAefosLazMcpToolsRegistrar._HStopProject(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCall: TAefosLazMarshalCall;
  LObj: TJSONObject;
begin
  if not _EnsureWriteConsent(AContext, 'StopProject', True) then
    raise EMCPUserDenied.Create('User denied StopProject (Aefos MCP action consent)');
  LCall := TAefosLazMarshalCall.Create(FFacade, ckStopProject);
  try
    AContext.MarshalToMainThread(LCall.Run);
    LObj := TJSONObject.Create;
    try
      // Idempotent: applied True even when nothing was running.
      LObj.AddPair('applied', TJSONBool.Create(LCall.FOutBool));
      Result := TMCPToolResult.Text(LObj.ToJSON);
    finally
      LObj.Free;
    end;
  finally
    LCall.Free;
  end;
end;

{ ---- debug-loop foundation handlers --------------------------------------- }

// Neutral / RULE #1 EXEMPT, never consent-gated (read-only). Shapes the state the
// agent polls after a run/step: {state, hasSession, stopped[, file, line, thread]}.
// Mirrors the Delphi GetDebugState _StateResult (minus the source snippet, a later
// slice). state = the byte-identical FormatDebugState rendering.
function TAefosLazMcpToolsRegistrar._HGetDebugState(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCall: TAefosLazMarshalCall;
  LObj: TJSONObject;
begin
  LCall := TAefosLazMarshalCall.Create(FFacade, ckGetDebugState);
  try
    LCall.FDebug := FDebug;
    AContext.MarshalToMainThread(LCall.Run);
    LObj := TJSONObject.Create;
    try
      LObj.AddPair('state', TAefosLazDebugService.FormatDebugState(LCall.FDebugState));
      LObj.AddPair('hasSession', TJSONBool.Create(LCall.FDebugState.HasSession));
      LObj.AddPair('stopped', TJSONBool.Create(LCall.FDebugState.Stopped));
      if LCall.FDebugState.Stopped then
      begin
        LObj.AddPair('file', LCall.FDebugState.StopFile);
        LObj.AddPair('line', TJSONNumber.Create(Int64(LCall.FDebugState.StopLine)));
        LObj.AddPair('thread', TJSONNumber.Create(Int64(LCall.FDebugState.ThreadId)));
      end;
      Result := TMCPToolResult.Text(LObj.ToJSON);
    finally
      LObj.Free;
    end;
  finally
    LCall.Free;
  end;
end;

// Not consent-gated (low-risk debug-state mutation, like the Delphi debug tools).
// {applied:true} or {applied:false, reason}. Accepts optional condition + passCount.
function TAefosLazMcpToolsRegistrar._HSetBreakpoint(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCall: TAefosLazMarshalCall;
  LObj: TJSONObject;
begin
  LCall := TAefosLazMarshalCall.Create(FFacade, ckSetBreakpoint);
  try
    LCall.FDebug := FDebug;
    LCall.FInStr1 := _OptStr(AParams, 'unit');
    LCall.FInInt1 := _OptInt(AParams, 'line');
    LCall.FInStr2 := _OptStr(AParams, 'condition');
    LCall.FInInt2 := _OptInt(AParams, 'passCount');
    AContext.MarshalToMainThread(LCall.Run);
    LObj := TJSONObject.Create;
    try
      LObj.AddPair('applied', TJSONBool.Create(LCall.FOutBool));
      if not LCall.FOutBool then
        LObj.AddPair('reason', LCall.FOutReason);
      Result := TMCPToolResult.Text(LObj.ToJSON);
    finally
      LObj.Free;
    end;
  finally
    LCall.Free;
  end;
end;

// Not consent-gated. {applied:bool}.
function TAefosLazMcpToolsRegistrar._HRemoveBreakpoint(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCall: TAefosLazMarshalCall;
  LObj: TJSONObject;
begin
  LCall := TAefosLazMarshalCall.Create(FFacade, ckRemoveBreakpoint);
  try
    LCall.FDebug := FDebug;
    LCall.FInStr1 := _OptStr(AParams, 'unit');
    LCall.FInInt1 := _OptInt(AParams, 'line');
    AContext.MarshalToMainThread(LCall.Run);
    LObj := TJSONObject.Create;
    try
      LObj.AddPair('applied', TJSONBool.Create(LCall.FOutBool));
      Result := TMCPToolResult.Text(LObj.ToJSON);
    finally
      LObj.Free;
    end;
  finally
    LCall.Free;
  end;
end;

// Neutral / RULE #1 EXEMPT, never consent-gated. {breakpoints:[...]} where each
// line is the byte-identical FormatBreakpointLine rendering.
function TAefosLazMcpToolsRegistrar._HListBreakpoints(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCall: TAefosLazMarshalCall;
  LObj: TJSONObject;
  LArr: TJSONArray;
  LIdx: Integer;
begin
  LCall := TAefosLazMarshalCall.Create(FFacade, ckListBreakpoints);
  try
    LCall.FDebug := FDebug;
    AContext.MarshalToMainThread(LCall.Run);
    LObj := TJSONObject.Create;
    try
      LArr := TJSONArray.Create;
      for LIdx := 0 to High(LCall.FBreakpoints) do
        LArr.Add(LCall.FBreakpoints[LIdx]);
      LObj.AddPair('breakpoints', LArr);
      Result := TMCPToolResult.Text(LObj.ToJSON);
    finally
      LObj.Free;
    end;
  finally
    LCall.Free;
  end;
end;

{ ---- step / run-control family -------------------------------------------- }

// Marshals ONE debug-state snapshot to the IDE main thread (DebugBoss is main-
// thread only) and returns it - the guard reads it, and the post-dispatch report
// re-reads it. Same carrier the GetDebugState handler uses.
function TAefosLazMcpToolsRegistrar._ReadDebugState(
  const AContext: IMCPToolContext): TAefosLazDebugState;
var
  LCall: TAefosLazMarshalCall;
begin
  LCall := TAefosLazMarshalCall.Create(FFacade, ckGetDebugState);
  try
    LCall.FDebug := FDebug;
    AContext.MarshalToMainThread(LCall.Run);
    Result := LCall.FDebugState;
  finally
    LCall.Free;
  end;
end;

// Marshals one no-argument FDebug dispatch (continue / pause) on the IDE main
// thread and returns whether it was dispatched. AIsPause selects Pause; otherwise
// Continue (the two implementation-enum kinds are mapped here, keeping the
// interface-section method signature free of the implementation-only enum).
function TAefosLazMcpToolsRegistrar._DispatchDebug(
  const AContext: IMCPToolContext; const AIsPause: Boolean): Boolean;
var
  LCall: TAefosLazMarshalCall;
  LKind: TAefosLazCallKind;
begin
  if AIsPause then
    LKind := ckDebugPause
  else
    LKind := ckDebugContinue;
  LCall := TAefosLazMarshalCall.Create(FFacade, LKind);
  try
    LCall.FDebug := FDebug;
    AContext.MarshalToMainThread(LCall.Run);
    Result := LCall.FOutBool;
  finally
    LCall.Free;
  end;
end;

// Shared body of StepOver/StepInto/StepOut: guard STOPPED, dispatch the step,
// then report the re-read state with dispatched=true (mirrors the Delphi
// _StepTool, Tools.Debug.pas:155). The step is async - the new location shows up
// on the NEXT GetDebugState poll, not necessarily in this immediate re-read.
function TAefosLazMcpToolsRegistrar._StepFamily(const AContext: IMCPToolContext;
  const AKind: TAefosLazDebugStepKind): TMCPToolResult;
var
  LState: TAefosLazDebugState;
  LReason: string;
  LCall: TAefosLazMarshalCall;
begin
  LState := _ReadDebugState(AContext);
  if not _DebugGuard(LState, dnStopped, LReason) then
    Exit(_DebugErr(LReason));
  LCall := TAefosLazMarshalCall.Create(FFacade, ckDebugStep);
  try
    LCall.FDebug := FDebug;
    LCall.FInInt1 := Ord(AKind);
    AContext.MarshalToMainThread(LCall.Run);
  finally
    LCall.Free;
  end;
  Result := _DebugStateResult(_ReadDebugState(AContext), 'dispatched', 'true');
end;

function TAefosLazMcpToolsRegistrar._HStepOver(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
begin
  Result := _StepFamily(AContext, dskOver);
end;

function TAefosLazMcpToolsRegistrar._HStepInto(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
begin
  Result := _StepFamily(AContext, dskInto);
end;

function TAefosLazMcpToolsRegistrar._HStepOut(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
begin
  Result := _StepFamily(AContext, dskOut);
end;

// Guard a live SESSION, dispatch Continue, report the re-read state (mirrors the
// Delphi ContinueRun handler, Tools.Debug.pas:301).
function TAefosLazMcpToolsRegistrar._HContinueRun(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LState: TAefosLazDebugState;
  LReason: string;
begin
  LState := _ReadDebugState(AContext);
  if not _DebugGuard(LState, dnSession, LReason) then
    Exit(_DebugErr(LReason));
  _DispatchDebug(AContext, False); // Continue
  Result := _DebugStateResult(_ReadDebugState(AContext), 'dispatched', 'true');
end;

// Guard a live SESSION, plant a breakpoint at unit:line + Continue, report state
// (mirrors the Delphi RunToLine handler, Tools.Debug.pas:316). {"applied":false}
// when the breakpoint could not be planted (e.g. an unresolvable unit).
function TAefosLazMcpToolsRegistrar._HRunToLine(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LState: TAefosLazDebugState;
  LReason: string;
  LCall: TAefosLazMarshalCall;
  LOk: Boolean;
begin
  LState := _ReadDebugState(AContext);
  if not _DebugGuard(LState, dnSession, LReason) then
    Exit(_DebugErr(LReason));
  LCall := TAefosLazMarshalCall.Create(FFacade, ckDebugRunToLine);
  try
    LCall.FDebug := FDebug;
    LCall.FInStr1 := _OptStr(AParams, 'unit');
    LCall.FInInt1 := _OptInt(AParams, 'line');
    AContext.MarshalToMainThread(LCall.Run);
    LOk := LCall.FOutBool;
  finally
    LCall.Free;
  end;
  if not LOk then
    Exit(TMCPToolResult.Text('{"applied":false}'));
  Result := _DebugStateResult(_ReadDebugState(AContext), 'dispatched', 'true');
end;

// Guard a live SESSION, dispatch Pause, report state (mirrors the Delphi PauseRun
// handler, Tools.Debug.pas:337).
function TAefosLazMcpToolsRegistrar._HPauseRun(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LState: TAefosLazDebugState;
  LReason: string;
begin
  LState := _ReadDebugState(AContext);
  if not _DebugGuard(LState, dnSession, LReason) then
    Exit(_DebugErr(LReason));
  _DispatchDebug(AContext, True); // Pause
  Result := _DebugStateResult(_ReadDebugState(AContext), 'dispatched', 'true');
end;

{ ---- debug inspection family ---------------------------------------------- }

// Guard STOPPED, read the native FpDebug locals for the current frame, return them
// as {"locals":[ "name = value", ... ]} (byte-identical shape to the Delphi
// InspectLocals handler, Tools.Debug.pas:351).
function TAefosLazMcpToolsRegistrar._HInspectLocals(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LState: TAefosLazDebugState;
  LReason: string;
  LCall: TAefosLazMarshalCall;
  LObj: TJSONObject;
  LArr: TJSONArray;
  LIdx: Integer;
begin
  LState := _ReadDebugState(AContext);
  if not _DebugGuard(LState, dnStopped, LReason) then
    Exit(_DebugErr(LReason));
  LCall := TAefosLazMarshalCall.Create(FFacade, ckDebugInspectLocals);
  try
    LCall.FDebug := FDebug;
    AContext.MarshalToMainThread(LCall.Run);
    LObj := TJSONObject.Create;
    try
      LArr := TJSONArray.Create;
      for LIdx := 0 to High(LCall.FDebugLines) do
        LArr.Add(LCall.FDebugLines[LIdx]);
      LObj.AddPair('locals', LArr);
      Result := TMCPToolResult.Text(LObj.ToJSON);
    finally
      LObj.Free;
    end;
  finally
    LCall.Free;
  end;
end;

// Guard STOPPED, evaluate the expression in the current frame's scope, return
// {"value":...} on success or {"error":...} on failure (byte-identical shape to the
// Delphi EvaluateExpression handler, Tools.Debug.pas:375).
function TAefosLazMcpToolsRegistrar._HEvaluateExpression(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LState: TAefosLazDebugState;
  LReason: string;
  LCall: TAefosLazMarshalCall;
  LObj: TJSONObject;
begin
  LState := _ReadDebugState(AContext);
  if not _DebugGuard(LState, dnStopped, LReason) then
    Exit(_DebugErr(LReason));
  LCall := TAefosLazMarshalCall.Create(FFacade, ckDebugEvaluate);
  try
    LCall.FDebug := FDebug;
    LCall.FInStr1 := _OptStr(AParams, 'expression');
    AContext.MarshalToMainThread(LCall.Run);
    LObj := TJSONObject.Create;
    try
      if LCall.FOutBool then
        LObj.AddPair('value', LCall.FOutStr1)
      else
        LObj.AddPair('error', LCall.FOutStr1);
      Result := TMCPToolResult.Text(LObj.ToJSON);
    finally
      LObj.Free;
    end;
  finally
    LCall.Free;
  end;
end;

// Guard STOPPED, read the current thread's call stack, return it as
// {"frames":[ "header  file:line", ... ]} (byte-identical shape to the Delphi
// GetCallStack handler, Tools.Debug.pas:432).
function TAefosLazMcpToolsRegistrar._HGetCallStack(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LState: TAefosLazDebugState;
  LReason: string;
  LCall: TAefosLazMarshalCall;
  LObj: TJSONObject;
  LArr: TJSONArray;
  LIdx: Integer;
begin
  LState := _ReadDebugState(AContext);
  if not _DebugGuard(LState, dnStopped, LReason) then
    Exit(_DebugErr(LReason));
  LCall := TAefosLazMarshalCall.Create(FFacade, ckDebugGetCallStack);
  try
    LCall.FDebug := FDebug;
    AContext.MarshalToMainThread(LCall.Run);
    LObj := TJSONObject.Create;
    try
      LArr := TJSONArray.Create;
      for LIdx := 0 to High(LCall.FDebugLines) do
        LArr.Add(LCall.FDebugLines[LIdx]);
      LObj.AddPair('frames', LArr);
      Result := TMCPToolResult.Text(LObj.ToJSON);
    finally
      LObj.Free;
    end;
  finally
    LCall.Free;
  end;
end;

{ ---- per-type project creation handlers ----------------------------------- }

function TAefosLazMcpToolsRegistrar._CreateProjectKind(
  const AToolName, AKind: string; const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCall: TAefosLazMarshalCall;
begin
  // Creating a project mutates the workspace, so it is gated on the EDIT-class
  // session consent (not the RUN grant - nothing is executed). AKind is passed by
  // the caller (each tool hard-codes it); AParams supplies only Name + optional
  // Directory - never the type.
  if not _EnsureWriteConsent(AContext, AToolName) then
    raise EMCPUserDenied.Create('User denied ' + AToolName
      + ' (Aefos MCP write consent)');
  LCall := TAefosLazMarshalCall.Create(FFacade, ckCreateNewProject);
  try
    LCall.FInStr1 := _OptStr(AParams, 'Name');
    LCall.FInStr2 := AKind;                       // hard-coded per tool (RULE #1)
    LCall.FInStr3 := _OptStr(AParams, 'Directory');
    AContext.MarshalToMainThread(LCall.Run);
    // A name collision is a distinct, recoverable condition - surface it as a
    // structured error (parity with the Delphi 'project-already-exists') instead of
    // an opaque applied:false the agent cannot tell from a real failure.
    if (not LCall.FOutBool) and (LCall.FOutReason = 'project-already-exists') then
      raise EMCPInvalidParams.Create(AToolName + ': project "'
        + LCall.FInStr1 + '" already exists; data.detail={"reason":'
        + '"project-already-exists","existing":"' + LCall.FOutStr1 + '"}');
    Result := _PathResult(LCall.FOutStr1);
  finally
    LCall.Free;
  end;
end;

function TAefosLazMcpToolsRegistrar._HCreateProjectApplication(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
begin
  Result := _CreateProjectKind('CreateProjectApplication', 'application',
    AParams, AContext);
end;

function TAefosLazMcpToolsRegistrar._HCreateProjectSimpleProgram(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
begin
  Result := _CreateProjectKind('CreateProjectSimpleProgram', 'simpleprogram',
    AParams, AContext);
end;

function TAefosLazMcpToolsRegistrar._HCreateProjectProgram(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
begin
  Result := _CreateProjectKind('CreateProjectProgram', 'program',
    AParams, AContext);
end;

function TAefosLazMcpToolsRegistrar._HCreateProjectConsole(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
begin
  Result := _CreateProjectKind('CreateProjectConsole', 'console',
    AParams, AContext);
end;

function TAefosLazMcpToolsRegistrar._HCreateProjectLibrary(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
begin
  Result := _CreateProjectKind('CreateProjectLibrary', 'library',
    AParams, AContext);
end;

procedure TAefosLazMcpToolsRegistrar.RegisterAll(const AServer: IMCPServer);
var
  LHandler: TMCPToolHandler;
begin
  if not Assigned(AServer) then
    raise EArgumentNilException.Create('TAefosLazMcpToolsRegistrar.RegisterAll: AServer');

  // -- reads --------------------------------------------------------------
  LHandler := _HGetEditorActiveFile;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'GetEditorActiveFile', 'Get editor active file',
    'Returns the file currently active in the editor ({name, path}).',
    _SchemaEmpty, _SchemaEmpty, LHandler));

  LHandler := _HGetEditorFullContent;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'GetEditorFullContent', 'Get editor full content',
    'Returns the full content of the active editor buffer ({value}).',
    _SchemaEmpty, _SchemaEmpty, LHandler));

  LHandler := _HGetOpenEditorFiles;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'GetOpenEditorFiles', 'Get open editor files',
    'Lists all files open in the editor ([{name, path, modified}]).',
    _SchemaEmpty, _SchemaEmpty, LHandler));

  LHandler := _HGetCursorPosition;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'GetCursorPosition', 'Get cursor position',
    'Returns {unit_path, line, column} of the active source editor caret, or ' +
    'JSON null when no source editor has focus.',
    _SchemaEmpty, _SchemaEmpty, LHandler));

  LHandler := _HGetSelection;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'GetSelection', 'Get current selection',
    'Returns the selection envelope (unit_path, selection_text, start_line, ' +
    'start_column, end_line, end_column) or JSON null when no selection.',
    _SchemaEmpty, _SchemaEmpty, LHandler));

  LHandler := _HFindInEditor;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'FindInEditor', 'Find in editor',
    'Searches for text in the currently open file ([{line, col}]).',
    _SchemaObject(['Text', 'CaseSensitive'], ['string', 'boolean'],
      ['Text', 'CaseSensitive']),
    _SchemaEmpty, LHandler));

  LHandler := _HListIDEActions;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'ListIDEActions', 'List IDE actions',
    'Lists the live IDE command catalog (name, caption, category, enabled). ' +
    'Optional "filter" = case-insensitive substring on name/caption/category ' +
    '(empty = the entire catalog). Read-only.',
    _SchemaObject(['filter'], ['string'], []),
    _SchemaEmpty, LHandler));

  // Fires any IDE command by name (the twin of ListIDEActions' write side): build,
  // run, format, F12 view-toggle, etc. - not just what we surfaced as a dedicated
  // tool. CONSENT-GATED (it can mutate) and NOT view-guarded (it may itself flip the
  // view). Registered WITHOUT a view intent so RULE #1 never rejects it.
  LHandler := _HExecuteIDEAction;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'ExecuteIDEAction', 'Execute IDE action',
    'Fires a named IDE action by name (e.g. a build, run, format or F12 ' +
    'view-toggle command). Use ListIDEActions FIRST to discover the exact name, ' +
    'then pass it as "ActionName". Returns {applied, ok}. Destructive names ' +
    '(exit/quit/delete/clean/...) are refused; a name absent from the live ' +
    'catalog returns an actionable reason. Requires user consent.',
    _SchemaObject(['ActionName'], ['string'], ['ActionName']),
    _SchemaEmpty, LHandler));

  // -- terminal -----------------------------------------------------------
  // Neutral intent (opening a panel changes no Design/Code view) + never consent-
  // gated, exactly like ListIDEActions. Gives the agent a way to bring up the
  // terminal ("open a terminal and run X"): the panel docks and hosts a live shell.
  LHandler := _HOpenTerminal;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'OpenTerminal', 'Open terminal',
    'Opens the docked Aefos AI terminal panel; use it to run shell commands in ' +
    'the IDE. Returns {applied, ok, reason}. Idempotent: calling it again just ' +
    'focuses the already-open panel. Takes no parameters.',
    _SchemaEmpty, _SchemaEmpty, LHandler));

  // -- change-review feedback loop ----------------------------------------
  // Neutral / RULE #1 EXEMPT and never consent-gated (they only read the review
  // gutter). Descriptions are the RAD GetReviewFeedback / GetPendingReviews text
  // VERBATIM so the agent-facing contract is byte-identical across editions.
  LHandler := _HGetReviewFeedback;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'GetReviewFeedback', 'Get review feedback',
    'Returns and CLEARS the user''s review annotations on your edits. Each line is ' +
    '"[approved|rejected] <unit-path>:<line> - <note>", so you can tell which change ' +
    'each note refers to and whether it was kept or undone. Call after a batch of ' +
    'edits to learn the user''s feedback. Empty when there are no annotations.',
    _SchemaEmpty, _SchemaEmpty, LHandler));

  LHandler := _HGetPendingReviews;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'GetPendingReviews', 'Get pending reviews',
    'Lists the edits currently PENDING in the review gutter — changes already ' +
    'applied to the editor buffer but not yet approved or rejected by the user. Each ' +
    'line is "<unit-path>:<start>-<end>  pending". The review NEVER blocks you: edits ' +
    'apply immediately and are fully readable via ReadUnit/GetMethodBody/GetClassMembers, ' +
    'so use this to know which of your changes are still awaiting the user''s decision ' +
    'and revalidate with confidence. Does NOT clear anything. Empty when nothing is pending.',
    _SchemaEmpty, _SchemaEmpty, LHandler));

  // -- propose an Aefos issue ---------------------------------------------
  // Neutral / RULE #1 EXEMPT (it shows a dialog, it changes no Design/Code view)
  // and NOT write-consent gated: its own human gate is the editable dialog + the
  // "Issue reporting" toggle (checked in the handler). Name + schema + description
  // are the Delphi tool VERBATIM so a connecting AI sees the identical contract.
  LHandler := _HProposeAefosIssue;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'ProposeAefosIssue', 'Propose an Aefos issue',
    'PROPOSE an Aefos bug or suggestion to the user (you NEVER file it yourself). ' +
    'Call this ONLY when you hit friction that looks like a genuine Aefos defect AND ' +
    'is not your own fault (wrong view / bad params / a RULE #1 rejection -> fix and ' +
    'resend, do NOT report). Describe the problem and a possible solution; Aefos pops ' +
    'an EDITABLE window (your text pre-filled) with the IDE/Aefos/OS versions attached, ' +
    'and the user decides whether to open a pre-filled GitHub issue. Params: title ' +
    '(short), problem (what went wrong), possibleSolution (your suggested fix). ' +
    'Returns {sent, url}: sent=false means the user cancelled OR issue reporting ' +
    'is turned off in Tools > Options > Aefos > AI Flow (do not retry in that case).',
    _SchemaObject(['title', 'problem', 'possibleSolution'],
      ['string', 'string', 'string'], ['title', 'problem']),
    _SchemaEmpty, LHandler));

  // -- editor writes ------------------------------------------------------
  LHandler := _HEditUnit;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'EditUnit', 'Edit unit body',
    'Applies a single anchored replacement to an open unit''s editor buffer: ' +
    'old_text must occur exactly once and is replaced by new_text. The buffer ' +
    'is left dirty and undoable (single Ctrl+Z); the file is not saved. ' +
    'PREFERRED for code changes over SetEditorFullContent. This edits CODE — it ' +
    'is NOT how you build a form. To add a control use AddComponent — it sprouts ' +
    'LIVE in the Form Designer and the IDE DECLARES ITS FIELD FOR YOU; never ' +
    'hand-write a control (e.g. "MyEdit := TEdit.Create(Self); MyEdit.Parent := ' +
    'Self;") in FormCreate. To wire an event use AddEventHandler. GUARDED: an ' +
    'EditUnit whose new_text creates AND parents a standard LCL control ' +
    '(TEdit/TButton/TPanel/...) is REFUSED (outcome=code-builds-ui) — use the ' +
    'Designer. Only genuinely custom-painted controls declared in the unit ' +
    '(TMyCtrl = class(TCustomControl)) may be created in code.',
    _SchemaObject(['unit_path', 'old_text', 'new_text'],
      ['string', 'string', 'string'],
      ['unit_path', 'old_text', 'new_text']),
    _SchemaEmpty, LHandler, tiCode));

  LHandler := _HInsertCodeAtCursor;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'InsertCodeAtCursor', 'Insert code at cursor',
    'Inserts code at the current cursor position (one undo block). This inserts ' +
    'CODE — it is NOT how you build a form. NEVER paste control-construction code ' +
    '(TEdit/TButton/TPanel.Create + .Parent :=) to lay out a UI: a control enters ' +
    'a form ONLY through AddComponent, which sprouts it LIVE in the Designer and ' +
    'lets the IDE declare its field. Use this for genuine runtime logic only.',
    _SchemaObject(['Code'], ['string'], ['Code']),
    _SchemaEmpty, LHandler, tiCode));

  LHandler := _HReplaceEditorSelection;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'ReplaceEditorSelection', 'Replace editor selection',
    'Replaces the current selection in the editor (or inserts at the caret ' +
    'when nothing is selected). This edits CODE — it is NOT how you build a form. ' +
    'Do NOT introduce control-construction code (Txxx.Create + .Parent :=) to ' +
    'build UI: controls are born in the Designer via AddComponent (the IDE ' +
    'declares the field for you), never hand-written.',
    _SchemaObject(['NewText'], ['string'], ['NewText']),
    _SchemaEmpty, LHandler, tiCode));

  LHandler := _HSetEditorFullContent;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'SetEditorFullContent', 'Set editor full content',
    'ADVANCED / WHOLESALE ONLY - replaces the ENTIRE active editor buffer (a ' +
    '.pas) in one shot. This is NOT the normal way to write code, and it is NOT ' +
    'how you build a form. For incremental code changes use EditUnit (old_text ' +
    '-> new_text). To add a control use AddComponent — it sprouts LIVE in the ' +
    'Designer and the IDE DECLARES ITS FIELD FOR YOU. NEVER hand-write a control ' +
    'field or its construction (e.g. "MyBtn := TButton.Create(Self); MyBtn.Parent ' +
    ':= Self;") in a form class: that is the Designer''s job, and it desyncs ' +
    '.pas<->.lfm. To wire an event use AddEventHandler. Reserve this for a genuine ' +
    'full-file rewrite of RUNTIME LOGIC where an anchored EditUnit is impractical ' +
    '— never to introduce UI structure. GUARDED: the write is REFUSED ' +
    '(applied=false, reason=code-builds-ui) when the new source builds a form by ' +
    'creating + parenting standard LCL controls in code, and (pas-dfm-desync) when ' +
    'it drops Designer-managed fields still on the live form. Only genuinely ' +
    'custom-painted controls declared in the unit (TMyCtrl = class(TCustomControl)) ' +
    'may be created in code.',
    _SchemaObject(['Source'], ['string'], ['Source']),
    _SchemaEmpty, LHandler, tiCode));

  LHandler := _HReplaceInEditor;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'ReplaceInEditor', 'Replace in editor',
    'Replaces text occurrences in the active editor buffer (find/replace, no ' +
    'disk write). Returns {value: count}. Zero matches is a successful no-op. ' +
    'This is a mechanical CODE replace — it is NOT how you build a form. Do NOT ' +
    'use it to inject control-construction code (Txxx.Create + .Parent :=): ' +
    'controls are added in the Designer via AddComponent, which declares the ' +
    'field for you.',
    _SchemaObject(['Find', 'Replace', 'All'], ['string', 'string', 'boolean'],
      ['Find', 'Replace', 'All']),
    _SchemaEmpty, LHandler, tiCode));

  LHandler := _HUndoEditor;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'UndoEditor', 'Undo editor',
    'Undoes the last action in the active editor.',
    _SchemaEmpty, _SchemaEmpty, LHandler, tiCode));

  LHandler := _HSaveActiveFile;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'SaveActiveFile', 'Save active file',
    'Persists the active buffer to disk. The "changed" field is true if there ' +
    'was anything to save.',
    _SchemaEmpty, _SchemaEmpty, LHandler));

  LHandler := _HSaveAllFiles;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'SaveAllFiles', 'Save all files',
    'Persists all open buffers (and the project) to disk.',
    _SchemaEmpty, _SchemaEmpty, LHandler));

  // -- Phase J live form designer -----------------------------------------
  // View-switch first (how the agent flips to Design): tiNeutral, not gated.
  LHandler := _HOpenFormDesigner;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'OpenFormDesigner', 'Open form designer',
    'Brings the unit''s Form Designer to the front (materializing it if needed) ' +
    'and gives it focus - the way to flip the IDE into Design view before a ' +
    'design command. Returns {applied, changed, reason}.',
    _SchemaObject(['unit_name'], ['string'], []),
    _SchemaEmpty, LHandler));

  // Design MUTATIONS: tiDesign (server enforces RULE #1 - a wrong-view-code
  // rejection tells the agent to call OpenFormDesigner first) + write-consent.
  LHandler := _HAddComponent;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'AddComponent', 'Add component',
    'Adds a component to the LIVE form designer: it sprouts on the form AND the ' +
    'IDE declares the published field in the .pas (never write the field ' +
    'yourself). "parent" is a container name or the form name for a top-level ' +
    'control; left/top/width/height are the bounds. Returns {applied, changed, ' +
    'reason}.',
    _SchemaObject(
      ['unit_name', 'component_class', 'component_name', 'parent',
       'left', 'top', 'width', 'height'],
      ['string', 'string', 'string', 'string',
       'integer', 'integer', 'integer', 'integer'],
      ['component_class', 'parent']),
    _SchemaEmpty, LHandler, tiDesign));

  LHandler := _HRemoveComponent;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'RemoveComponent', 'Remove component',
    'Removes a component from the live form designer; the IDE drops its ' +
    'published field from the .pas. Returns {applied, changed, reason}.',
    _SchemaObject(['unit_name', 'component_name'], ['string', 'string'],
      ['component_name']),
    _SchemaEmpty, LHandler, tiDesign));

  LHandler := _HSetComponentProperty;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'SetComponentProperty', 'Set component property',
    'Sets a published property on a live component (nested paths ok, e.g. ' +
    'Font.Height, Color). Static design-time state (Caption/Text, Font, colors, ' +
    'size, Visible, Align) goes HERE - NOT in FormCreate. Returns {applied, ' +
    'changed, reason}.',
    _SchemaObject(['unit_name', 'component_name', 'prop_name', 'prop_value'],
      ['string', 'string', 'string', 'string'],
      ['component_name', 'prop_name', 'prop_value']),
    _SchemaEmpty, LHandler, tiDesign));

  LHandler := _HSetFormProperty;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'SetFormProperty', 'Set form property',
    'Sets a published property on the live form root (Caption, Color, ...). ' +
    'Returns {applied, changed, reason}.',
    _SchemaObject(['unit_name', 'prop_name', 'prop_value'],
      ['string', 'string', 'string'], ['prop_name', 'prop_value']),
    _SchemaEmpty, LHandler, tiDesign));

  LHandler := _HAddEventHandler;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'AddEventHandler', 'Add event handler',
    'Atomically wires a component event to a handler (the designer double-click): ' +
    'creates the handler in the published section AND wires the .lfm event in one ' +
    'step, then jumps to it. Optional "body" fills the handler. Leave ' +
    'component_name empty (or the form name) for the form''s own events ' +
    '(FormCreate...). Returns {applied, changed, reason}.',
    _SchemaObject(
      ['unit_name', 'component_name', 'event_name', 'handler_name', 'body'],
      ['string', 'string', 'string', 'string', 'string'],
      ['event_name']),
    _SchemaEmpty, LHandler, tiDesign));

  // Design READS: neutral, never gated - serialize/parse the LIVE form.
  LHandler := _HGetDFMContent;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'GetDFMContent', 'Get form (.lfm) content',
    'Serializes the LIVE form to .lfm text (reflects unsaved designer edits). ' +
    'Returns {content, is_binary, found}. Read-only.',
    _SchemaObject(['unit_name'], ['string'], []),
    _SchemaEmpty, LHandler));

  LHandler := _HListFormComponents;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'ListFormComponents', 'List form components',
    'Lists the immediate child components of the live form ([{name, type, ' +
    'owner}]). Read-only.',
    _SchemaObject(['unit_name'], ['string'], []),
    _SchemaEmpty, LHandler));

  LHandler := _HGetComponentProperties;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'GetComponentProperties', 'Get component properties',
    'Lists a live component''s serialized properties ([{name, value}]). Read-only.',
    _SchemaObject(['unit_name', 'component_name'], ['string', 'string'],
      ['component_name']),
    _SchemaEmpty, LHandler));

  LHandler := _HGetFormProperties;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'GetFormProperties', 'Get form properties',
    'Lists the live form root''s serialized properties ([{name, value}]). ' +
    'Read-only.',
    _SchemaObject(['unit_name'], ['string'], []),
    _SchemaEmpty, LHandler));

  // -- view-switch to Code + agent-vision capture -------------------------
  // OpenUnitInEditor is the CODE twin of OpenFormDesigner: a view-switch (RULE #1
  // EXEMPT), tiNeutral, not gated - it is HOW the agent flips the IDE to Code
  // before a code command. CaptureForm is a read (tiNeutral), not gated - it
  // returns an inline PNG screenshot of the live form so the agent SEES the
  // layout. Both are named exactly as the FlowGuide "next" hints cite them.
  LHandler := _HOpenUnitInEditor;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'OpenUnitInEditor', 'Open unit in editor',
    'Opens a unit in the IDE code editor and flips the IDE to Code view - the ' +
    'way to switch to Code before a code command (EditUnit, InsertCodeAtCursor, ' +
    'ReplaceInEditor). This is a VIEW-SWITCH: it does not modify anything. Pass ' +
    'the unit name (with or without .pas); it resolves an already-open tab or ' +
    'opens the file from disk. Returns {applied, changed, reason}.',
    _SchemaObject(['unit_name'], ['string'], []),
    _SchemaEmpty, LHandler));

  LHandler := _HCaptureForm;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'CaptureForm', 'Capture form (screenshot)',
    'Renders the LIVE form in the Designer to a PNG image and returns it so you ' +
    'can SEE what you are building and self-correct. Use it after adding or ' +
    'arranging controls (and again after tweaks) to verify the layout matches the ' +
    'intended design - catch a leftover placeholder Caption, a control hidden ' +
    'behind another, a missing glyph, or a misalignment, then fix it. This is a ' +
    'READ: it does not move the view or modify anything, and RunProject is NOT ' +
    'needed (it is the fast look-and-fix loop). unit_name may be empty to capture ' +
    'the form currently open in the Designer.',
    _SchemaObject(['unit_name'], ['string'], []),
    _SchemaEmpty, LHandler));

  // -- build/run group ----------------------------------------------------
  // Neutral intent (build/run never change the Design/Code view). RunBuild and
  // the two reads are un-gated; the three runtime tools are write-consent gated
  // (mirrors the Delphi: RunBuild un-gated in Tools.pas, run/stop gated in
  // Tools.Build.pas). Tool NAMES + schemas are wire-compatible with the Delphi
  // edition so the same agent prompt drives both.
  LHandler := _HRunBuild;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'RunBuild', 'Run build',
    'Builds the IDE''s active project and returns an opaque build_id. mode is ' +
    'optional: "make" (default, incremental) or "build" (full rebuild). Poll ' +
    'GetBuildStatus with the returned build_id for the result. A second RunBuild ' +
    'while one is still unresolved fails.',
    _SchemaObject(['mode'], ['string'], []),
    _SchemaEmpty, LHandler));

  LHandler := _HGetBuildStatus;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'GetBuildStatus', 'Get build status',
    'Polls the state of a build started by RunBuild. Returns {build_id, status} ' +
    'where status is "running", "succeeded", "failed" or "cancelled". An unknown ' +
    'build_id errors.',
    _SchemaObject(['build_id'], ['string'], ['build_id']),
    _SchemaEmpty, LHandler));

  LHandler := _HGetCompilerErrors;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'GetCompilerErrors', 'Get compiler errors',
    'Returns the compiler diagnostics as a JSON array; each element is {path, ' +
    'line, column, severity, text} with severity "error", "warning" or "hint", ' +
    'harvested from the IDE messages window after a RunBuild.',
    _SchemaEmpty, _SchemaEmpty, LHandler));

  LHandler := _HRunProject;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'RunProject', 'Run project',
    'Runs the active project under the IDE debugger (Run / F9). Build FIRST and ' +
    'check GetCompilerErrors is empty. applied:true means a debugged process is ' +
    'confirmed running; a compile error or an app that exits instantly yields ' +
    'applied:false. Close it afterwards with StopProject.',
    _SchemaEmpty, _SchemaEmpty, LHandler));

  LHandler := _HRunWithoutDebugger;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'RunWithoutDebugger', 'Run without debugger',
    'Runs the active project WITHOUT the debugger (Ctrl+Shift+F9). The process ' +
    'runs detached and cannot be stopped by StopProject - launch with RunProject ' +
    'if you need to stop it programmatically.',
    _SchemaEmpty, _SchemaEmpty, LHandler));

  LHandler := _HStopProject;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'StopProject', 'Stop project',
    'Stops the application currently running under the IDE debugger (Program ' +
    'Reset). Idempotent: applied:true even when nothing is running. Cannot stop a ' +
    'RunWithoutDebugger (detached) process.',
    _SchemaEmpty, _SchemaEmpty, LHandler));

  // -- debug-loop foundation ----------------------------------------------
  // Twins of the Delphi GetDebugState / SetBreakpoint / RemoveBreakpoint /
  // ListBreakpoints tools; descriptions are the Delphi text VERBATIM so the
  // agent-facing contract (incl. the GetDebugState polling hint) is byte-identical
  // across editions. GetDebugState + ListBreakpoints are neutral read-only tools;
  // SetBreakpoint / RemoveBreakpoint mutate debug state but carry no view intent and
  // no consent gate in this slice (parity with the Delphi debug tool family).
  LHandler := _HGetDebugState;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'GetDebugState', 'Get debug state',
    'Returns the live debugger state: whether a debugged process exists, ' +
    'whether it is STOPPED (at a breakpoint/exception), and the current ' +
    'file:line + thread. Poll this after RunProject / a step / ContinueRun ' +
    'to learn where execution is. Never changes anything.',
    _SchemaEmpty, _SchemaEmpty, LHandler));

  LHandler := _HSetBreakpoint;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'SetBreakpoint', 'Set breakpoint',
    'Creates a source breakpoint at unit:line (works before a run - a ' +
    'design-time breakpoint). Optional: "condition" (a Delphi boolean ' +
    'expression - the breakpoint only stops when it is true) and ' +
    '"passCount" (skip that many passes before stopping). Run the project, ' +
    'then poll GetDebugState to see it stop.',
    _SchemaObject(['unit', 'line', 'condition', 'passCount'],
      ['string', 'integer', 'string', 'integer'], ['unit', 'line']),
    _SchemaEmpty, LHandler));

  LHandler := _HRemoveBreakpoint;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'RemoveBreakpoint', 'Remove breakpoint',
    'Removes the source breakpoint at unit:line, if one exists.',
    _SchemaObject(['unit', 'line'], ['string', 'integer'], ['unit', 'line']),
    _SchemaEmpty, LHandler));

  LHandler := _HListBreakpoints;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'ListBreakpoints', 'List breakpoints',
    'Lists the current source breakpoints as "file:line[ disabled][ if expr]".',
    _SchemaEmpty, _SchemaEmpty, LHandler));

  // -- step / run-control family ------------------------------------------
  // Twins of the Delphi StepOver / StepInto / StepOut / ContinueRun / RunToLine /
  // PauseRun tools; descriptions are the RAD text VERBATIM so the agent-facing
  // contract (incl. the "poll GetDebugState" async hint) is byte-identical across
  // editions. Each is ASYNC: it returns dispatched=true, and the agent RE-POLLS
  // GetDebugState to learn where execution stopped. No consent gate (parity with
  // the Delphi debug family). StepOver/Into/Out require the debuggee STOPPED;
  // ContinueRun/RunToLine/PauseRun require a live session (the guard returns the
  // same 'no-debug-session'/'process-running' kebab reasons the RAD edition does).
  LHandler := _HStepOver;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'StepOver', 'Step over',
    'Steps over the current source line (F8). Requires the process STOPPED. ' +
    'Then poll GetDebugState for the new location.',
    _SchemaEmpty, _SchemaEmpty, LHandler));

  LHandler := _HStepInto;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'StepInto', 'Step into',
    'Traces into the call on the current line (F7). Requires STOPPED.',
    _SchemaEmpty, _SchemaEmpty, LHandler));

  LHandler := _HStepOut;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'StepOut', 'Step out',
    'Runs until the current routine returns (Shift+F8). Requires STOPPED.',
    _SchemaEmpty, _SchemaEmpty, LHandler));

  LHandler := _HContinueRun;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'ContinueRun', 'Continue',
    'Resumes a stopped process (F9). Falls back to RunProject when no ' +
    'session exists.',
    _SchemaEmpty, _SchemaEmpty, LHandler));

  LHandler := _HRunToLine;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'RunToLine', 'Run to line',
    'Sets a breakpoint at unit:line and continues the debugged process, so ' +
    'it runs until that line (or an earlier stop). Requires a debug session. ' +
    'Poll GetDebugState for the stop. NOTE: the breakpoint PERSISTS after ' +
    'the stop (the IDE has no one-shot breakpoints) - call RemoveBreakpoint ' +
    'at the same unit:line if it was temporary.',
    _SchemaObject(['unit', 'line'], ['string', 'integer'], ['unit', 'line']),
    _SchemaEmpty, LHandler));

  LHandler := _HPauseRun;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'PauseRun', 'Pause',
    'Pauses a running debugged process so it can be inspected.',
    _SchemaEmpty, _SchemaEmpty, LHandler));

  // -- debug inspection ---------------------------------------------------
  // Twins of the Delphi InspectLocals / EvaluateExpression / GetCallStack tools;
  // descriptions are the RAD text VERBATIM (bar the GetCallStack SetCurrentThread
  // note - that tool is not in this edition yet) so the agent-facing contract is
  // byte-identical across editions. Each requires the debuggee STOPPED (the guard
  // returns the same 'no-debug-session'/'process-running' kebab reasons the RAD
  // edition does). Read-only: no consent gate, no view intent. The FpDebug data
  // fills async, so each pumps a bounded main-thread budget inside FDebug.
  LHandler := _HInspectLocals;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'InspectLocals', 'Inspect locals',
    'Reads the enclosing routine''s parameters and local variables at the ' +
    'current stop (like the IDE Locals window) and returns "name = value" ' +
    'lines. Requires STOPPED. Unevaluable names come back as "name = ' +
    '<reason>" instead of being dropped.',
    _SchemaEmpty, _SchemaEmpty, LHandler));

  LHandler := _HEvaluateExpression;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'EvaluateExpression', 'Evaluate',
    'Evaluates an expression in the current stopped thread''s scope (like the ' +
    'IDE Evaluate/Watch window) and returns its value. Requires STOPPED. ' +
    'Use it to read variables, fields, and expressions at a breakpoint.',
    _SchemaObject(['expression'], ['string'], ['expression']),
    _SchemaEmpty, LHandler));

  LHandler := _HGetCallStack;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'GetCallStack', 'Get call stack',
    'Returns the current thread''s call stack as "header  file:line" frames, ' +
    'top frame first. A frame without source shows the header only. Requires ' +
    'STOPPED.',
    _SchemaEmpty, _SchemaEmpty, LHandler));

  // -- per-type project creation ------------------------------------------
  // One EXPLICIT tool per project type - the tool NAME fixes the kind, so an agent
  // never guesses a project-type string (RULE #1: a "console" tool cannot create a
  // GUI app). Inputs are only Name (required) + optional Directory - never a type
  // param. Neutral intent (creating a project is not a Design/Code view mutation);
  // gated on the edit-class write consent inside the handler. Mirrors the Delphi
  // CreateProjectVCL/FMX/Console/... surface, adapted to the Lazarus taxonomy.
  LHandler := _HCreateProjectApplication;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'CreateProjectApplication', 'Create new GUI (LCL) application',
    'Creates a new GUI application (LCL - the Lazarus visual widgetset, the ' +
    'equivalent of Delphi''s VCL) with a main form, under ' +
    '%APPDATA%\Aefos\lazarus-workspace\<Name>. Use for a desktop GUI. The project ' +
    'is created unsaved (virtual); it is written to disk on the first save/build. ' +
    'Inputs: Name (required), Directory (optional sub-folder).',
    _SchemaObject(['Name', 'Directory'], ['string', 'string'], ['Name']),
    _SchemaEmpty, LHandler));

  LHandler := _HCreateProjectSimpleProgram;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'CreateProjectSimpleProgram', 'Create new simple program',
    'Creates a new Simple Program (a bare "program ... begin end." .lpr, no units, ' +
    'no LCL) under %APPDATA%\Aefos\lazarus-workspace\<Name>. No form is created. ' +
    'Inputs: Name (required), Directory (optional sub-folder).',
    _SchemaObject(['Name', 'Directory'], ['string', 'string'], ['Name']),
    _SchemaEmpty, LHandler));

  LHandler := _HCreateProjectProgram;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'CreateProjectProgram', 'Create new program',
    'Creates a new Program (a non-visual "program" .lpr with a Classes uses clause) ' +
    'under %APPDATA%\Aefos\lazarus-workspace\<Name>. No form is created. Inputs: ' +
    'Name (required), Directory (optional sub-folder).',
    _SchemaObject(['Name', 'Directory'], ['string', 'string'], ['Name']),
    _SchemaEmpty, LHandler));

  LHandler := _HCreateProjectConsole;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'CreateProjectConsole', 'Create new console application',
    'Creates a new Console application (a TCustomApplication program: DoRun, option ' +
    'parsing, WriteHelp) under %APPDATA%\Aefos\lazarus-workspace\<Name>. No form is ' +
    'created. Inputs: Name (required), Directory (optional sub-folder).',
    _SchemaObject(['Name', 'Directory'], ['string', 'string'], ['Name']),
    _SchemaEmpty, LHandler));

  LHandler := _HCreateProjectLibrary;
  AServer.RegisterTool(TMCPToolDescriptor.Create(
    'CreateProjectLibrary', 'Create new library',
    'Creates a new Library (a "library" .lpr that builds a shared library/DLL) ' +
    'under %APPDATA%\Aefos\lazarus-workspace\<Name>. No form is created. Inputs: ' +
    'Name (required), Directory (optional sub-folder).',
    _SchemaObject(['Name', 'Directory'], ['string', 'string'], ['Name']),
    _SchemaEmpty, LHandler));
end;

end.
