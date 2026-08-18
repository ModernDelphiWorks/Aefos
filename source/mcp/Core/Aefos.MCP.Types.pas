unit Aefos.MCP.Types;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  Contracts for the in-process MCP server (ESP-002, Epic 3/5 Demand 1/5).

  Declarations only — JSON-RPC envelopes, tool descriptor, transport interface,
  OTA-façade interface, error family, and the protocol/budget constants. No
  IO; the only logic is trivial record factories (TMCPToolResult.Text/Image,
  TMCPToolDescriptor.Create) that fill their own fields — they replace the
  Default(T) + manual-fill spray the tool layer used to repeat 150+ times.

  Architectural baseline:
    - ADR-054: relay binary + Windows named pipe transport.
    - ADR-055: MCP protocol version pinned to '2025-06-18'.
    - ADR-057: OTA threading model — handlers marshal to main thread.
    - ADR-058: tool-result chunking budget = 64 KB.

  Lifetime contract:
    - Records carry TJSON* references that are owned by the dispatcher's
      parsed JSON root. Record owners must not free the references; the
      dispatcher frees the root once the response has been emitted.
    - TMCPToolDescriptor.InputSchema / OutputSchema are owned by the
      registry; registration transfers ownership to the server.
}

interface

uses
  SysUtils,
  Classes,
  Aefos.Compat.Json,
  Aefos.MCP.IntentGuard;

{$IFDEF FPC}
type
  // FPC 3.2.2's Classes has no TThreadProcedure (Delphi's anonymous-method
  // main-thread marshal type). The marshal is exercised only by the Delphi IDE
  // host; the FPC build gets a method-pointer stand-in so the contract compiles.
  TThreadProcedure = procedure of object;
{$ENDIF}

const
  MCP_PROTOCOL_VERSION   = '2025-06-18';
  MCP_TOOL_RESULT_BUDGET = 64 * 1024;
  MCP_SERVER_NAME        = 'aefos-mcp';
  MCP_PIPE_PREFIX        = '\\.\pipe\aefos-mcp-';

  // JSON-RPC error codes.
  MCP_ERR_PARSE            = -32700;
  MCP_ERR_INVALID_REQUEST  = -32600;
  MCP_ERR_METHOD_NOT_FOUND = -32601;
  MCP_ERR_INVALID_PARAMS   = -32602;
  MCP_ERR_INTERNAL         = -32603;
  MCP_ERR_SERVER           = -32000;

  // Write-tool server-error subcodes (ESP-002, Demand 2/5).
  MCP_ERR_STALE_READ = -32001;  // base_hash no longer matches live content
  MCP_ERR_NOT_READ   = -32002;  // edit attempted without a prior ReadUnit

  // Destructive-tool server-error subcode (ESP-002, Demand 3/5).
  MCP_ERR_USER_DENIED = -32003;  // user denied the action at the modal gate

  // Build-tool server-error subcode (ESP-002, Demand 4/5).
  MCP_ERR_BUILD_IN_PROGRESS = -32004;  // RunBuild issued while a build runs

  // Resource server-error subcode (ESP-002, Demand 5/5).
  MCP_ERR_RESOURCE_NOT_FOUND = -32005;  // resources/read|subscribe unknown URI

  // Intent-guard subcode (RULE #1): a design/code command was sent while the IDE
  // showed the wrong view; the command rejected without mutating. The agent
  // switches view (OpenFormDesigner / OpenUnitInEditor) and resends.
  MCP_ERR_WRONG_VIEW = -32006;

  // SaveAllFiles refused because firing it now would let the Delphi IDE do damage —
  // clear unresolved review gutters (auto-accept) or strip a .dfm event whose handler
  // is not in code yet. The agent resolves the named condition first (FlowGuide).
  MCP_ERR_SAVE_BLOCKED = -32008;

  // OTA-context resource URIs exposed via the resources capability (ADR-071).
  MCP_RES_ACTIVE_PROJECT = 'aefos://project/active';
  MCP_RES_ACTIVE_UNIT    = 'aefos://unit/active';
  MCP_RES_CURSOR         = 'aefos://cursor';

type
  // Forward declarations
  IMCPToolContext = interface;

  TMCPRequest = record
    Id: TJSONValue;        // shared reference; nil = notification / missing
    Method: string;
    Params: TJSONObject;   // shared reference; nil if absent
  end;

  TMCPToolResult = record
    Content: string;
    HasMore: Boolean;
    NextCursor: string;    // empty string serialises as JSON null
    ContentHash: string;   // empty unless the tool produces a content hash
    // Optional inline image (ADR: agent vision). When ImageBase64 <> '', the
    // server appends an MCP `image` content block so a vision-capable model
    // literally SEES the picture (e.g. a screenshot of the form it is building).
    ImageBase64: string;   // base64 of the raw image bytes (no data: prefix)
    ImageMimeType: string; // e.g. 'image/png'
    // Factory for the overwhelmingly common case: a text/JSON payload with no
    // paging. AContentHash is the SHA-256 a tool passes back so a follow-up
    // EditUnit can verify the buffer (empty otherwise). Starts from Default so
    // EVERY field is initialised on the returned value — this replaces the
    // Default(TMCPToolResult) + manual Content assignment spray at 90+ sites.
    class function Text(const AContent: string;
      const AContentHash: string = ''): TMCPToolResult; static;
    // Factory for an inline image result (agent vision): the picture rides in
    // ImageBase64/ImageMimeType and AContent is the accompanying text block.
    class function Image(const ABase64, AMimeType, AContent: string): TMCPToolResult; static;
  end;

  // Agent-vision capture seam. Kept SEPARATE from the frozen IMCPWorkspaceFacade
  // (mirrors IMCPFlowState): the facade also implements it, and the tool layer /
  // OTA-free hosts reach it via Supports(FFacade, IMCPFormCapture). Renders the
  // LIVE designer form to a PNG so a vision model can SEE what it is building.
  IMCPFormCapture = interface
    ['{C7E1A9F4-3B2D-4E6A-9C15-8D0F2B6A47E3}']
    // AUnitName empty => the form currently open in the Designer. On success
    // returns True with ABase64 set (PNG bytes, base64, no data: prefix) AND
    // APngPath set to a PNG file written to disk (so a human can open the
    // picture); on failure False + AReason (form-not-found / capture-unsupported
    // / capture-failed).
    function CaptureActiveFormPng(const AUnitName: string;
      out ABase64, APngPath, AReason: string): Boolean;
  end;

  // One replacement of a byte range in a source buffer.
  //
  // A RANGE, not an insertion. The first producer of these only ever inserts,
  // and shaping the record to that one producer would carve its shape into a
  // contract shared by everything — the coupling running backwards, from one
  // tool into the whole surface. `Length = 0` is an insertion, so the general
  // form costs one field and buys every other producer: a rename, a formatter,
  // a quick-fix, a refactor of our own.
  //
  // Offset and Length count **UTF-8 bytes**, not characters. That is what an
  // IOTAEditWriter position is, and what an engine that read the same bytes
  // computed against; converting to characters would create a second coordinate
  // system for the two ends to disagree in, and they would disagree exactly on
  // the files that have accents in them.
  //
  // It lives HERE and not beside the seam that applies it because
  // `Aefos.MCP.Core` requires rtl only — it links into headless hosts, and
  // widening that is a defect and not a fix (ESP C-2). The harness cannot see
  // this unit either (it builds first), so the seam takes the same data as
  // parallel arrays and the service converts once. That is the price of the
  // package boundary, paid in one place on purpose.
  TSourceEdit = record
    Offset: Integer;   // where the replaced range starts, in UTF-8 bytes
    Length: Integer;   // how many bytes it replaces; 0 inserts
    Text: string;      // what goes in its place; empty deletes
  end;

  TSourceEdits = TArray<TSourceEdit>;

  // Outcome of an EditUnit apply against the IDE editor buffer (ADR-061/062).
  TMCPEditOutcome = (
    eoApplied,         // anchored replacement applied; buffer left dirty
    eoUnitNotOpen,     // unit not open in the IDE editor
    eoAnchorNotFound,  // old_text matched zero times
    eoAnchorAmbiguous, // old_text matched two or more times
    eoUserRejected     // user rejected the change in the inline diff preview
  );

  // User decision returned by the destructive-action confirmation modal
  // (ADR-064). Drives the session-scoped per-tool consent gate.
  TMCPConsentDecision = (
    cdAllowOnce,     // proceed once; record no session grant
    cdAllowSession,  // proceed and grant the tool for the rest of the session
    cdDenied         // refuse the action (also the safe default on dismissal)
  );

  // Decoupled consent UI (ADR-064/216; Dependency Inversion). The workspace
  // facade delegates the destructive-action decision to a presenter; each
  // presenter OWNS its own rendering AND its own threading/wait model — VCL =
  // blocking ShowModal that pumps its own message loop; HTML = async WebView2
  // postMessage + a main-thread message-loop pump. Presentation-agnostic and
  // RTL-only, so it lives in MCP.Core next to TMCPConsentDecision.
  //   TryRequestDecision -> True  + ADecision set : the presenter handled it.
  //                      -> False                  : can't present now; the
  //                         caller falls back to the default VCL modal.
  // cdDenied is always the safe default.
  IMCPConsentPresenter = interface
    ['{7E3C9A14-2B8D-4F61-9C05-1A6E4D2F8B73}']
    function TryRequestDecision(const AToolName, ASummary, ADetail: string;
      out ADecision: TMCPConsentDecision): Boolean;
  end;

  // Inline diff approval seam (mirrors IMCPConsentPresenter). The Chat BPL
  // registers an approver that shows the agent's EditUnit (old_text -> new_text)
  // as a red/green diff in the editor and waits for the user. ddUnavailable =>
  // could not review inline; the caller applies the edit normally.
  TMCPDiffDecision = (ddUnavailable, ddApplied, ddRejected);

  IMCPDiffApprover = interface
    ['{C1F8A6D2-3E47-4B9A-8D52-7F1E0C9A4B36}']
    // AReason carries the user's optional rejection note (typed in the themed
    // reject dialog) back to the caller on ddRejected, so the facade can surface
    // it to the agent — the human tells the agent WHY the edit was refused.
    // Empty when applied/unavailable or when the user gave no note.
    function ReviewEdit(const AUnitPath, AOldText, ANewText: string;
      out AReason: string): TMCPDiffDecision;
  end;

  // Outcome of a destructive filesystem/project mutation (ADR-066).
  TMCPFileActionOutcome = (
    faApplied,         // the mutation succeeded
    faNotFound,        // the target unit/file does not exist
    faAlreadyExists,   // the target already exists (AddUnit)
    faNoActiveProject, // no active project in the IDE
    faAccessError      // a filesystem/OTA error occurred (see out AError)
  );

  // FPC 3.2.2 lacks anonymous methods; the tool handlers that assign this are
  // in the Delphi-only IDE/tool surface (phase C+), so the FPC build gets a
  // method-pointer form purely so the descriptor type compiles.
{$IFNDEF FPC}
  TMCPToolHandler = reference to function(const AParams: TJSONObject;
    const AContext: IMCPToolContext): TMCPToolResult;
{$ELSE}
  TMCPToolHandler = function(const AParams: TJSONObject;
    const AContext: IMCPToolContext): TMCPToolResult of object;
{$ENDIF}

  TMCPToolDescriptor = record
    Name: string;
    Title: string;
    Description: string;
    InputSchema: TJSONObject;  // owned by server after RegisterTool
    OutputSchema: TJSONObject; // owned by server after RegisterTool
    Handler: TMCPToolHandler;
    // RULE #1 intent, declared by the tool itself in its _Build (single source).
    // Drives both the description suffix (RegisterTool) and the runtime view
    // guard (_HandleToolsCall). Defaults to tiNeutral (ord 0) for unguarded tools;
    // a mutating tool that forgets to set it trips the DEBUG self-test.
    Intent: TMCPToolIntent;
    // Factory that fills every field in one call, replacing the
    // Default(TMCPToolDescriptor) + 6-8 field assignments repeated at each
    // _Build*Descriptor. AIntent defaults to tiNeutral (unguarded tool); a
    // mutating tool passes its tiCode/tiDesign explicitly — so the field can
    // never be silently forgotten (which the DEBUG self-test would otherwise trip).
    class function Create(const AName, ATitle, ADescription: string;
      const AInputSchema, AOutputSchema: TJSONObject;
      const AHandler: TMCPToolHandler;
      const AIntent: TMCPToolIntent = tiNeutral): TMCPToolDescriptor; static;
  end;

  IMCPToolContext = interface
    ['{7C8D4A19-2F31-4E5D-B710-3F9E1B6C2A85}']
    procedure MarshalToMainThread(const AProc: TThreadProcedure);
    function BudgetBytes: Integer;
  end;

{$IFNDEF FPC}
  TMCPFrameCallback = reference to procedure(const AFrame: string);
{$ELSE}
  TMCPFrameCallback = procedure(const AFrame: string) of object;
{$ENDIF}

  IMCPTransport = interface
    ['{9F2A6E04-8B12-4731-A923-5C0E8F4D1A82}']
    procedure Start(const APipeName: string);
    procedure Stop;
    procedure Send(const AFrame: string);
    procedure SetOnFrame(const ACallback: TMCPFrameCallback);
  end;

  // Addon-MCP gateway seam (ESP: `aefos install <mcp>` -> every agent sees the
  // tools). Injected into TMCPServer by the host composition root, mirroring the
  // FViewProvider/SetViewProvider DI pattern; nil = off (the default), so the
  // pure suites and a standalone terminal never spawn a child. The server calls
  // it INSIDE tools/list (to append the installed addons' tools, namespaced
  // <serverkey>__<toolname>) and tools/call (to route a namespaced call to the
  // owning addon child process). Every method degrades gracefully and NEVER
  // raises across the MCP boundary. The implementation lives in
  // Aefos.MCP.AddonGateway (Core, RTL + Winapi.Windows).
  IMCPToolGateway = interface
    ['{A6F1D3E8-4B92-4C07-9E15-2D8A7F0B4C63}']
    // A JSON array string of namespaced tool descriptors
    // ([{ "name","description","inputSchema" }, ...]) to splice into tools/list.
    // '' / '[]' when the gateway contributes nothing (no addons, or all failed).
    // Lazily spawns + discovers the addon children on first call.
    function ListToolsJson: string;
    // True when AToolName is a namespaced addon tool this gateway routes.
    function OwnsTool(const AToolName: string): Boolean;
    // Routes a namespaced tools/call to the owning child and returns the child's
    // raw JSON-RPC `result` object (verbatim MCP tools/call result -- content,
    // structuredContent, isError all preserved). '' when routing failed (the
    // server then emits a synthetic error result). AArgumentsJson is the caller's
    // `arguments` object JSON ('{}' when absent).
    function CallTool(const AToolName, AArgumentsJson: string): string;
    // Kill every child process and free every client. Idempotent; never raises.
    // Called by TMCPServer.Stop/Destroy so a child never outlives the host.
    procedure Shutdown;
  end;

  // Visual-report seam. The addon gateway already routes every desktop tool call
  // through this process, so the host can WATCH those calls without the child
  // knowing a UI exists -- the tool layer keeps reporting facts and nothing else.
  // Injected exactly like IMCPToolGateway; nil = off (the default), so the pure
  // suites and a standalone terminal never carry a UI dependency.
  //
  // Deliberately a callback rather than an interface: the only implementation is
  // one line (hand the call to the visual broadcaster), and a test wants to
  // capture what was reported, not implement an interface to do so. It must
  // NEVER raise -- the server calls it around a tool result that has already
  // been produced, and a drawing concern must not be able to fail a tool call.
  {$IFDEF FPC}
  TMCPVisualReport = procedure(const AToolName, AArgumentsJson,
    AResultJson: string; const AFailed: Boolean) of object;
  {$ELSE}
  TMCPVisualReport = reference to procedure(const AToolName, AArgumentsJson,
    AResultJson: string; const AFailed: Boolean);
  {$ENDIF}

  // Thin façade so the four read-only tools stay independent of OTA imports.
  // The real implementation lives next to Register.pas; tests inject a mock.
  TMCPActiveProjectInfo = record
    Name: string;
    Path: string;
    TargetPlatform: string;
    Available: Boolean;
  end;

  TMCPCursorInfo = record
    UnitPath: string;
    Line: Integer;
    Column: Integer;
    Available: Boolean;
  end;

  TMCPSelectionInfo = record
    UnitPath: string;
    Text: string;
    StartLine: Integer;
    StartColumn: Integer;
    EndLine: Integer;
    EndColumn: Integer;
    Available: Boolean;
  end;

  // Lifecycle state of an asynchronous build job (ADR-068/070).
  TMCPBuildState = (bsRunning, bsSucceeded, bsFailed, bsCancelled);

  // Severity of a single compiler diagnostic (ADR-070).
  TMCPCompilerSeverity = (csError, csWarning, csHint);

  // One compiler diagnostic harvested from the IDE message view (ADR-070).
  TMCPCompilerMessage = record
    Path: string;
    Line: Integer;
    Column: Integer;
    Severity: TMCPCompilerSeverity;
    Text: string;
  end;

  // Decoupling seam between the server's notifications/cancelled handler and
  // the build manager (ADR-069). The server core forwards a cancel request
  // here without ever depending on the build-manager unit.
  IMCPCancellationSink = interface
    ['{6F3D9A21-8C47-4E5B-9D10-2A7E4F0B3C58}']
    procedure RequestCancel(const ABuildId: string);
  end;

  TMCPRecordEditorFile = record
    Name: string;
    Path: string;
    Modified: Boolean;
  end;

  // Forms & DFM group (Epic 7/7 Demand 6/8, ADR-139). One entry per project
  // module that has a `.dfm` companion. `DfmPath` is the absolute path to the
  // .dfm; `ModulePath` is the absolute path to the `.pas`.
  TMCPRecordProjectForm = record
    Name: string;
    ModulePath: string;
    DfmPath: string;
  end;

  // Forms & DFM group — single property descriptor. The DFM parser produces
  // a flat list; ordering follows the source-text order in the DFM.
  TMCPRecordDFMProperty = record
    Name: string;
    Value: string;
  end;

  // Forms & DFM group — single component descriptor. `Owner` is the parent
  // component name (empty for immediate children of the form).
  TMCPRecordDFMComponent = record
    Name: string;
    TypeName: string;
    Owner: string;
  end;

  // DPR group (Epic 7/7 Demand 6/8, ADR-139). One entry per
  // `Application.CreateForm(TFormClass, FormVar)` call discovered in the DPR.
  TMCPRecordDPRCreateForm = record
    FormVar: string;
    FormClass: string;
    UnitName: string;
  end;

  // Code Insight group (Epic 7/7 Demand 7/8, ADR-142). One unit-level
  // declaration row used by GetSymbolsInUnit.
  TMCPRecordUnitSymbol = record
    Name: string;
    Kind: string;        // class | record | interface | function |
                         // procedure | var | const | type
    Line: Integer;       // 1-based
  end;

  // Code Insight group — one class-member row used by GetClassMembers.
  TMCPRecordClassMember = record
    Name: string;
    Kind: string;        // field | method | property | const | type
    Visibility: string;  // private | protected | public | published | automated
    Line: Integer;
  end;

  // Code Insight group — one symbol-usage row used by FindSymbolUsages.
  // ADR-143 token-boundary contract: every entry is a real identifier
  // occurrence; strings / comments / substrings are excluded.
  TMCPRecordSymbolUsage = record
    FilePath: string;
    Line: Integer;
    Column: Integer;
    Context: string;     // entire source line containing the match
  end;

  // Project Group (Epic 7/7 Demand 7/8, ADR-142). One row per `.dproj`
  // referenced from the active `.groupproj`.
  TMCPRecordGroupProject = record
    Name: string;
    Path: string;
    Active: Boolean;
  end;

  // Project Group — one per-project build outcome row returned by
  // BuildAllInGroup. ADR-144: BuildAllInGroup never short-circuits, so a
  // single failure produces one row with Success=False; the rest of the
  // group still builds.
  TMCPRecordGroupBuildResult = record
    Project: string;
    Success: Boolean;
    Errors: TArray<string>;
  end;

  // Packages group (Epic 7/7 Demand 8/8, ADR-145). One row per project
  // package reference, captured from `<DCC_UsePackage>` and the runtime
  // package list in the `.dproj`.
  TMCPRecordProjectPackage = record
    Name: string;
    Path: string;
    Runtime: Boolean;
    Designtime: Boolean;
  end;

  // IDE group (Epic 7/7 Demand 8/8, ADR-145). IDE product/version/build
  // triple as reported by `IOTAServices` (fields populated best-effort —
  // empty string sentinel when OTA does not expose the value).
  TMCPRecordIDEVersion = record
    Product: string;
    Version: string;
    Build: string;
  end;

  // IDE group — one Project Manager tree node. `Children` is the depth-
  // capped child slice (truncated at depth 8 per R-3 — beyond that a single
  // synthetic node {Kind='truncated'} is emitted).
  TMCPRecordProjectManagerNode = record
    Name: string;
    Kind: string;
    Children: TArray<TMCPRecordProjectManagerNode>;
  end;

  // IDE group — outcome of `RunExternalTool`. `ExitCode` is `Low(Integer)`
  // when the process is still running (BR-5 — surfaces as JSON null in the
  // tool result).
  TMCPRecordExternalToolRun = record
    Pid: Integer;
    ExitCode: Integer;
    ExitCodeKnown: Boolean;
    StartedAt: string;
  end;

  // Resources group (Epic 7/7 Demand 8/8, ADR-145). One row per project
  // resource module filtered to `.res` / `.rc` (Kind ∈ {"res","rc"}).
  TMCPRecordProjectResource = record
    Path: string;
    Kind: string;
  end;

  // Rename/Move cascade group (Epic 1/3 Demand 2/5, ADR-203/204). Outcome
  // of a multi-file atomic rename/move. `Changed` is False on an idempotent
  // no-op or a rolled-back apply failure; `TouchedFiles` lists the files the
  // committed plan wrote (empty when nothing changed); `Reason` is empty on
  // a clean apply, carries a kebab-coded reason on a pre-flight validation
  // failure, and carries `apply-failed` when the plan was rolled back
  // (ADR-204 §5 success-shaped envelope).
  TRenameOutcome = record
    Changed: Boolean;
    TouchedFiles: TArray<string>;
    Reason: string;
  end;

  IMCPWorkspaceFacade = interface
    ['{B2A4F0E7-1D38-4F9C-8E72-9A3B5D1C7E62}']
    function ReadUnit(const AUnitPath: string; out ABody: string): Boolean;
    function GetActiveProject: TMCPActiveProjectInfo;
    // Source text of the unit currently active in the IDE editor; empty
    // string when no unit is active (Demand 5/5, ADR-071). Backs the
    // aefos://unit/active resource provider.
    function GetActiveUnit: string;
    function GetCursorPosition: TMCPCursorInfo;
    function GetSelection: TMCPSelectionInfo;
    // RULE #1 (CLAUDE.md): the view the IDE is showing NOW via
    // IOTAModule.CurrentEditor — a form editor => tiDesign, a source editor =>
    // tiCode, else tiNeutral. The host injects this as the server's view
    // provider so the intent guard rejects a design/code command in the wrong
    // view. Main-thread read (the server invokes it through its marshal).
    function CurrentIdeViewIntent: TMCPToolIntent;
    function EditUnit(const AUnitPath, AOldText, ANewText: string;
      out AError: string): TMCPEditOutcome;
    // Destructive tools (Demand 3/5). RequestConsent shows the confirmation
    // modal on the IDE main thread (ADR-065); DeleteUnit/OverwriteFile/AddUnit
    // mutate the filesystem and the active project (ADR-066). All four are
    // marshalled to the main thread by the calling handler (ADR-057).
    function RequestConsent(const AToolName, ASummary,
      ADetail: string): TMCPConsentDecision;
    function DeleteUnit(const AUnitPath: string;
      out AError: string): TMCPFileActionOutcome;
    function OverwriteFile(const AFilePath, AContent: string;
      out AError: string): TMCPFileActionOutcome;
    function AddUnit(const AUnitPath, AContent: string;
      out AError: string): TMCPFileActionOutcome;
    // Build/compile-loop tools (Demand 4/5). StartBuild kicks off an
    // asynchronous build of the active project and returns immediately
    // (ADR-068); QueryBuildResult reports the captured outcome; CancelBuild
    // performs a best-effort OTA abort (ADR-069); GetCompilerMessages
    // harvests the live IDE message view (ADR-070). All four are marshalled
    // to the IDE main thread by the calling handler (ADR-057).
    function StartBuild(const AMode: string; out AError: string): Boolean;
    function QueryBuildResult: TMCPBuildState;
    function CancelBuild: Boolean;
    function GetCompilerMessages: TArray<TMCPCompilerMessage>;
    // Project group (Epic 7/7 Demand 2/8, ADR-125 — appended in place; GUID
    // unchanged per ADR-108). Reads return sentinels when there is no active
    // project; writes return False when there is no active project or the
    // OTA write surface refuses the value. Exceptions never cross the MCP
    // boundary (BR-3). Validation for SetActive* lives in the MCP-tool
    // handler (ADR-124), not the facade.
    function GetProjectName: string;
    function GetProjectPath: string;
    function GetProjectFilePath: string;
    function GetProjectType: string;
    function GetProjectVersion: string;
    function GetProjectGUID: string;
    function GetProjectPlatforms: TArray<string>;
    function GetActiveProjectPlatform: string;
    function GetProjectConfigurations: TArray<string>;
    function GetActiveConfiguration: string;
    function GetProjectDescription: string;
    function GetProjectOutputDir: string;
    function SetProjectVersion(const AMajor, AMinor, ARelease,
      ABuild: Integer): Boolean;
    function SetActiveProjectPlatform(const APlatformName: string): Boolean;
    function SetActiveConfiguration(const AConfigName: string): Boolean;
    function SetProjectDescription(const ADescription: string): Boolean;
    function SetProjectOutputDir(const ADir: string): Boolean;
    // Units group (Epic 7/7 Demand 3/8, ADR-131 — appended in place; GUID
    // unchanged per ADR-108). Reads return sentinels when the unit is not
    // known to the facade; writes return False on no-active-project or OTA
    // refusal. AddToUses / RemoveFromUses are idempotent — `AChanged` is
    // False when the operation is a no-op (ADR-128). Exceptions never cross
    // the MCP boundary (BR-3).
    function IsUnitOpen(const AUnitName: string): Boolean;
    function GetUnitUses(const AUnitName: string;
      out AInterfaceUses, AImplementationUses: TArray<string>): Boolean;
    function GetUnitFilePath(const AUnitName: string): string;
    function OpenUnitInEditor(const AUnitName: string): Boolean;
    function AddUnitToProject(const AFilePath: string): Boolean;
    function RemoveUnitFromProject(const AUnitName: string): Boolean;
    function CreateNewUnit(const AUnitName: string; AWithForm: Boolean;
      out AFilePath: string): Boolean;
    function CreateNewProject(const AName, AProjectType, ADirectory: string;
      out ADProjPath: string; out AReason: string): Boolean;
    function CloseAllProjects: Boolean;
    function AddToUses(const ATargetUnit, AUnitToAdd, ASection: string;
      out AChanged: Boolean): Boolean;
    function RemoveFromUses(const ATargetUnit, AUnitToRemove: string;
      out AChanged: Boolean): Boolean;
    // Editor group (Epic 7/7 Demand 4/8 — appended in place; GUID unchanged per ADR-108).
    function GetEditorActiveFile(out AName, APath: string): Boolean;
    function SetEditorCursorPosition(const ALine, ACol: Integer): Boolean;
    function InsertCodeAtCursor(const ACode: string): Boolean;
    function ReplaceEditorSelection(const ANewText: string): Boolean;
    function GetEditorFullContent(out AContent: string): Boolean;
    function SetEditorFullContent(const ASource: string): Boolean;
    function FindInEditor(const AText: string; const ACaseSensitive: Boolean;
      out AOccurrences: TArray<TMCPCursorInfo>): Boolean;
    function ReplaceInEditor(const AFind, AReplace: string; const AAll: Boolean;
      out ACount: Integer): Boolean;
    // Apply byte-range replacements to one unit in a single undoable write —
    // the shape a code action produces. See IMCPEditorWriteService.ApplyTextEdits.
    function ApplyTextEdits(const AUnitPath: string; const AEdits: TSourceEdits;
      out AError: string): TMCPEditOutcome;
    function FindInProject(const AText: string; const ACaseSensitive: Boolean;
      out AOccurrences: TArray<TMCPCursorInfo>): Boolean;
    function SaveActiveFile(out AChanged: Boolean): Boolean;
    function SaveAllFiles(out AChanged: Boolean): Boolean;
    function UndoEditor: Boolean;
    function GetOpenEditorFiles(out AFiles: TArray<TMCPRecordEditorFile>): Boolean;
    function CloseFile(const AFilePath: string; const ASaveFirst: Boolean): Boolean;
    // Build group (Epic 7/7 Demand 5/8 — appended in place; GUID unchanged per
    // ADR-108). Reads return sentinels (`[]` / `''`) when no active project is
    // open or the OTA option key is absent; writes return False on no-active-
    // project, option-key-not-found, or OTA refusal. Mutations are consent-
    // gated at the MCP-tool layer (BR-2). Runtime tools honor BR-6 dedup —
    // `RunProject` / `RunWithoutDebugger` return False when a process is
    // already running; `StopProject` is idempotent when none is running.
    // Exceptions never cross the MCP boundary (BR-3).
    function GetSearchPath: TArray<string>;
    function SetSearchPath(const APaths: TArray<string>): Boolean;
    function AddToSearchPath(const APath: string): Boolean;
    function GetConditionalDefines: TArray<string>;
    function SetConditionalDefines(const ADefines: TArray<string>): Boolean;
    function AddConditionalDefine(const ADefine: string): Boolean;
    function RemoveConditionalDefine(const ADefine: string): Boolean;
    function GetDCUOutputDir: string;
    function SetDCUOutputDir(const ADir: string): Boolean;
    function CleanProject: Boolean;
    function RunProject: Boolean;
    function RunWithoutDebugger: Boolean;
    function StopProject: Boolean;
    function SendKeystroke(const AKeys: string): Boolean;
    // DPR group (Epic 7/7 Demand 6/8 — appended in place; GUID unchanged per
    // ADR-108). Reads return sentinels (`[]`, `''`) when no active project
    // exists or the `.dpr` cannot be located. Writes return False on
    // no-active-project, parse failure, collision, or filesystem refusal.
    // RenameDPR is atomic per ADR-141 (filesystem rollback on `.dproj`
    // failure). Mutations are consent-gated at the MCP-tool layer (BR-2).
    // Exceptions never cross the MCP boundary (BR-3); error reasons are
    // surfaced via AReason for the caller to map onto data.reason.
    function GetDPRContent: string;
    function SetDPRContent(const ASource: string;
      out AReason: string): Boolean;
    function RenameDPR(const ANewName: string;
      out AReason: string): Boolean;
    function GetDPRUsedForms: TArray<TMCPRecordDPRCreateForm>;
    function GetMainForm: string;
    function SetMainForm(const AFormClass: string;
      out AChanged: Boolean; out AReason: string): Boolean;
    // Forms & DFM group (Epic 7/7 Demand 6/8 — appended in place; GUID
    // unchanged per ADR-108). Reads return sentinels (`[]`, `''`, `False`)
    // when the target form / component is unknown. Mutations rejected with
    // AReason ∈ {`no-active-project`, `form-not-found`, `component-not-found`,
    // `binary-dfm-not-supported`, `dfm-parse-error`, `unit-not-resolved`} per
    // ESP BR-6. `unit-not-resolved` = a non-blank UnitName naming no open form
    // (anti-hallucination): open that form or omit UnitName for the open one.
    function ListProjectForms: TArray<TMCPRecordProjectForm>;
    function GetDFMContent(const AUnitName: string;
      out AContent: string; out AIsBinary: Boolean): Boolean;
    function SetDFMContent(const AUnitName, ADFMSource: string;
      out AReason: string): Boolean;
    function GetFormProperties(const AUnitName: string;
      out AProperties: TArray<TMCPRecordDFMProperty>): Boolean;
    function SetFormProperty(const AUnitName, APropName, APropValue: string;
      out AChanged: Boolean; out AReason: string): Boolean;
    function ListFormComponents(const AUnitName: string;
      out AComponents: TArray<TMCPRecordDFMComponent>): Boolean;
    function GetComponentProperties(const AUnitName, AComponentName: string;
      out AProperties: TArray<TMCPRecordDFMProperty>): Boolean;
    function SetComponentProperty(const AUnitName, AComponentName,
      APropName, APropValue: string;
      out AChanged: Boolean; out AReason: string): Boolean;
    function OpenFormDesigner(const AUnitName: string;
      out AChanged: Boolean; out AReason: string): Boolean;
    function OpenDFMTextEditor(const AUnitName: string;
      out AChanged: Boolean; out AReason: string): Boolean;
    // Live designer mutation (first of its kind). Deletes a component through
    // the live IOTAFormEditor — not a .dfm text rewrite — so the change shows
    // in the Designer at once and the IDE drops the published field from the
    // .pas itself. Brings the Form Designer to front first (EnsureDesignView)
    // and leaves it there. Reasons: no-active-project, form-not-found,
    // component-not-found, unit-not-resolved. Exceptions never cross (BR-3).
    function RemoveComponent(const AUnitName, AComponentName: string;
      out AChanged: Boolean; out AReason: string): Boolean;
    // Live designer creation — the inverse of RemoveComponent. Creates a
    // component through the live IOTAFormEditor so the IDE declares the published
    // field in the .pas itself (the agent writes no .pas). Brings the Designer to
    // front (EnsureDesignView) and leaves it there. Reasons: no-active-project,
    // form-not-found, unknown-class, name-in-use, create-failed,
    // unit-not-resolved (a non-blank UnitName naming no open form — omit it to
    // build into the open form, never a phantom unit the agent invented),
    // parent-required (AParent empty), parent-not-found / parent-not-container.
    // AParent is REQUIRED: the container the control nests into (a panel/group-
    // box), or the form's own name for a top-level control — so nothing lands
    // invisibly behind another control.
    function AddComponent(const AUnitName, AComponentClass, AComponentName,
      AParent: string;
      const ALeft, ATop, AWidth, AHeight: Integer;
      out AChanged: Boolean; out AReason: string): Boolean;
    // Atomic event-handler wire — the designer's double-click. Through the live
    // IDesigner it creates AHandlerName in the .pas's published auto-managed
    // section (or links the existing method of that name) AND assigns it to
    // AComponentName.AEventName so the .dfm gets the `OnX = Handler` wire, in one
    // designer transaction. No disk write / no force-refresh, so the buffer-vs-
    // disk clobber cannot occur. This is the only correct way to wire an event to
    // a not-yet-compiled handler (a plain RTTI SetMethodProp cannot — no compiled
    // method address exists yet). AHandlerName '' => Comp+Event-minus-'On'.
    // Reasons: form-not-found, component-not-found, designer-unavailable,
    // event-not-found, create-failed, unit-not-resolved.
    function AddEventHandler(const AUnitName, AComponentName, AEventName,
      AHandlerName, ABody: string;
      out AChanged: Boolean; out AReason: string): Boolean;
    // Code Insight group (Epic 7/7 Demand 7/8 — appended in place; GUID
    // unchanged per ADR-108). All five reads degrade to sentinel `[]`/`''`
    // when the target unit or class/method is not found; InsertMethod is
    // the only mutation and respects BR-4 two-anchor atomicity per ESP.
    // Exceptions never cross the MCP boundary (BR-3).
    function GetSymbolsInUnit(const AUnitName: string;
      out ASymbols: TArray<TMCPRecordUnitSymbol>): Boolean;
    function GetClassMembers(const AUnitName, AClassName: string;
      out AMembers: TArray<TMCPRecordClassMember>): Boolean;
    function FindSymbolUsages(const ASymbol: string;
      out AUsages: TArray<TMCPRecordSymbolUsage>): Boolean;
    function GetMethodBody(const AUnitName, AMethodName: string;
      out ABody: string): Boolean;
    function InsertMethod(const AUnitName, AClassName, ASignature,
      ABody: string; out AChanged: Boolean; out AReason: string): Boolean;
    function GetInheritanceChain(const AClassName: string;
      out AChain: TArray<string>): Boolean;
    // Project Group (Epic 7/7 Demand 7/8 — appended in place; GUID unchanged
    // per ADR-108). Reads return sentinels (`[]`, `''`) when no active group
    // is open. Mutations return False with AReason ∈ {`no-active-group`,
    // `project-not-in-group`, `project-not-found`, `group-build-failed`} per
    // ESP BR-6. BuildAllInGroup NEVER short-circuits (ADR-144).
    function GetProjectGroupName: string;
    function ListProjectsInGroup: TArray<TMCPRecordGroupProject>;
    function SetActiveProject(const AProjectPath: string;
      out AChanged: Boolean; out AReason: string): Boolean;
    function AddProjectToGroup(const AProjectPath: string;
      out AChanged: Boolean; out AReason: string): Boolean;
    function RemoveProjectFromGroup(const AProjectPath: string;
      out AChanged: Boolean; out AReason: string): Boolean;
    function BuildAllInGroup(
      out AResults: TArray<TMCPRecordGroupBuildResult>;
      out AReason: string): Boolean;
    // Packages + IDE + Resources (Epic 7/7 Demand 8/8 — appended in place;
    // GUID unchanged per ADR-108). Reads return sentinels (`[]`, `''`)
    // when no active project / option is available; mutations return False
    // with AReason ∈ {`no-active-project`, `package-not-found`,
    // `package-not-in-project`, `library-path-locked`, `action-not-found`,
    // `external-tool-launch-failed`, `resource-not-found`,
    // `resource-extension-invalid`} per ESP BR-4. Exceptions never cross
    // the MCP boundary (BR-3).
    function ListProjectPackages: TArray<TMCPRecordProjectPackage>;
    function AddPackageToProject(const APackagePath: string;
      const ARuntime: Boolean;
      out AChanged: Boolean; out AReason: string): Boolean;
    function RemovePackageFromProject(const APackageName: string;
      out AChanged: Boolean; out AReason: string): Boolean;
    function GetLibraryPath: TArray<string>;
    function AddToLibraryPath(const APath: string;
      out AChanged: Boolean; out AReason: string): Boolean;
    function GetIDEVersion: TMCPRecordIDEVersion;
    function ShowIDEMessage(const AText: string;
      const AUseOutput: Boolean): Boolean;
    function GetIDETheme: string;
    function ExecuteIDEAction(const AActionName: string;
      out AReason: string): Boolean;
    // Read-only catalog of every live IDE action (INTAServices.ActionList) as a
    // JSON string {actions:[{name,caption,category,shortcut,hint,enabled}],count}.
    // AFilter is a case-insensitive substring over name/caption/category ('' = all).
    // Lets an agent discover the action name for ExecuteIDEAction.
    function ListIDEActions(const AFilter: string): string;
    function GetProjectManagerTree: TArray<TMCPRecordProjectManagerNode>;
    function RefreshProjectManager: Boolean;
    function GetRecentFiles: TArray<string>;
    function RunExternalTool(const AArgv: TArray<string>;
      out ARun: TMCPRecordExternalToolRun; out AReason: string): Boolean;
    function ListProjectResources: TArray<TMCPRecordProjectResource>;
    function AddResourceFile(const AFilePath: string;
      out AChanged: Boolean; out AReason: string): Boolean;
    function ListProjectImages: TArray<string>;
    // Rename/Move cascade group (Epic 1/3 Demand 2/5, ADR-203/204 — appended
    // in place; GUID unchanged per ADR-108). Each is a multi-file atomic
    // cascade (source rename/move + `.dproj`/`.dpr`/`.groupproj` surgery +
    // `.dfm` pair handling) wrapped in pre-flight → staged-plan →
    // apply-with-rollback (ADR-204). Returns False on a pre-flight validation
    // failure with AOutcome.Reason ∈ {`invalid-name`, `name-collision`,
    // `project-not-found`, `unit-not-in-project`, `file-not-found`,
    // `outside-root`} — nothing is touched (BR-2). Returns True on a clean
    // apply (Changed=True), an idempotent no-op (Changed=False, Reason=''),
    // or an apply failure that was fully rolled back (Changed=False,
    // Reason=`apply-failed` — success-shaped envelope per ADR-204 §5).
    // Exceptions never cross the MCP boundary (BR-3).
    function RenameProject(const AOldName, ANewName: string;
      out AOutcome: TRenameOutcome): Boolean;
    function RenameUnit(const AUnitName, ANewUnitName: string;
      out AOutcome: TRenameOutcome): Boolean;
    function MoveUnitToFolder(const AUnitName, ATargetFolder: string;
      out AOutcome: TRenameOutcome): Boolean;
    // Opens any file or project/group by absolute path in the IDE
    // (IOTAActionServices.OpenFile) — .dproj / .groupproj / .pas. Returns False
    // when the path is empty or the IDE refuses it. (ESP, 2026-06-10.)
    function OpenFile(const APath: string): Boolean;
  end;

  // ── Resources capability (ESP-002, Demand 5/5) ─────────────────────────

  // Returns the current text content of a resource. Provider closures wrap
  // a marshalled OTA-facade read; the registry never invokes them itself —
  // the server invokes the provider when handling resources/read (ADR-071).
{$IFNDEF FPC}
  TMCPResourceProvider = reference to function: string;
{$ELSE}
  TMCPResourceProvider = function: string of object;
{$ENDIF}

  // One MCP resource exposed by the server (ADR-071). The set is fixed at
  // composition time; the descriptor list never changes within a session.
  TMCPResourceDescriptor = record
    Uri: string;
    Name: string;
    MimeType: string;
    Provider: TMCPResourceProvider;
  end;

  // Session-scoped, thread-safe registry of resource descriptors. Created
  // and freed with the server (ADR-056).
  IMCPResourceRegistry = interface
    ['{1A7B3C9D-4E52-4F60-8A13-6D2E9F0C4B71}']
    procedure Register(const ADescriptor: TMCPResourceDescriptor);
    function List: TArray<TMCPResourceDescriptor>;
    function TryGet(const AUri: string;
      out ADescriptor: TMCPResourceDescriptor): Boolean;
  end;

  // Seam between the re-anchoring notifier and the server. The server
  // implements it and emits a subscription-filtered notifications/resources/
  // updated frame; an unsubscribed URI is a silent no-op (ADR-073).
  IMCPNotificationPublisher = interface
    ['{2E9F0C4B-715A-4D38-9C26-3F8A1B7D5E04}']
    procedure NotifyResourceUpdated(const AUri: string);
  end;

  // OTA events that trigger re-anchoring (ADR-072). Discrete events emit
  // immediately; raCursorMoved is debounced/coalesced by the notifier.
  TMCPReAnchorEvent = (
    raProjectSwitched,
    raFileSaved,
    raActiveEditorChanged,
    raCursorMoved
  );

  // Exception family — every subclass carries a JSON-RPC error code.
  EMCPError = class(Exception)
  private
    FCode: Integer;
  public
    constructor Create(const ACode: Integer; const AMessage: string);
    property Code: Integer read FCode;
  end;

  EMCPInvalidRequest = class(EMCPError)
  public
    constructor Create(const AMessage: string);
  end;

  EMCPMethodNotFound = class(EMCPError)
  public
    constructor Create(const AMethod: string);
  end;

  EMCPInvalidParams = class(EMCPError)
  public
    constructor Create(const AMessage: string);
  end;

  EMCPInternalError = class(EMCPError)
  public
    constructor Create(const AMessage: string);
  end;

  // base_hash does not match the unit's current content (-32001).
  EMCPStaleRead = class(EMCPError)
  public
    constructor Create(const AMessage: string);
  end;

  // EditUnit attempted on a unit never read in this session (-32002).
  EMCPNotRead = class(EMCPError)
  public
    constructor Create(const AMessage: string);
  end;

  // User denied a destructive action at the confirmation modal (-32003).
  EMCPUserDenied = class(EMCPError)
  public
    constructor Create(const AMessage: string);
  end;

  // RunBuild issued while a build job is still running (-32004).
  EMCPBuildInProgress = class(EMCPError)
  public
    constructor Create(const AMessage: string);
  end;

  // resources/read or resources/subscribe targeted an unknown URI (-32005).
  EMCPResourceNotFound = class(EMCPError)
  public
    constructor Create(const AUri: string);
  end;

  // Design/code command sent while the IDE shows the wrong view (-32006, RULE #1).
  EMCPWrongView = class(EMCPError)
  public
    constructor Create(const AMessage: string);
  end;

  // SaveAllFiles refused because firing it now would let the IDE do damage (-32008,
  // FlowGuide). The agent resolves the named condition (review/handler) first.
  EMCPSaveBlocked = class(EMCPError)
  public
    constructor Create(const AMessage: string);
  end;

type
  // UTF-8 byte-boundary utility as a sealed static namespace (never instantiated).
  TMCPUtf8Utils = class sealed
  public
    // R1: largest length in [0..AMaxLen] such that ABytes[AOffset .. AOffset+Result-1] does NOT end in
    // the middle of a UTF-8 multibyte sequence. A fixed-size byte cut (result budget / ReadUnit paging)
    // that split a trailing multibyte char made TEncoding.UTF8.GetString RAISE EEncodingError (the RTL
    // shared UTF8 instance uses MB_ERR_INVALID_CHARS), which the server maps to -32603 — even for a
    // mutation that already applied. Receding to a lead-byte boundary before GetString stops that.
    class function SafeLen(const ABytes: TBytes; AOffset, AMaxLen: Integer): Integer; static;
  end;

  // Command-interpreter recognizer for the RunExternalTool consent warning
  // (sealed static namespace, never instantiated).
  TMCPProcessGuard = class sealed
  public
    // R11: True when AExe (an argv[0]) is a known command interpreter (powershell, cmd, python, ...).
    // RunExternalTool's token block-list screens bare destructive verbs (del/format/...), but an
    // interpreter can run ANY command wrapped in -Command / /c, which no token list can catch. The
    // consent gate uses this to WARN the human (the per-call approval is the real control) — it does
    // NOT block: running interpreters is legitimate.
    class function IsInterpreterExe(const AExe: string): Boolean; static;
  end;

implementation

{ TMCPToolResult }

class function TMCPToolResult.Text(const AContent: string;
  const AContentHash: string): TMCPToolResult;
begin
  Result := Default(TMCPToolResult);
  Result.Content := AContent;
  Result.ContentHash := AContentHash;
end;

class function TMCPToolResult.Image(const ABase64, AMimeType,
  AContent: string): TMCPToolResult;
begin
  Result := Default(TMCPToolResult);
  Result.Content := AContent;
  Result.ImageBase64 := ABase64;
  Result.ImageMimeType := AMimeType;
end;

{ TMCPToolDescriptor }

class function TMCPToolDescriptor.Create(const AName, ATitle,
  ADescription: string; const AInputSchema, AOutputSchema: TJSONObject;
  const AHandler: TMCPToolHandler;
  const AIntent: TMCPToolIntent): TMCPToolDescriptor;
begin
  Result := Default(TMCPToolDescriptor);
  Result.Name := AName;
  Result.Title := ATitle;
  Result.Description := ADescription;
  Result.InputSchema := AInputSchema;
  Result.OutputSchema := AOutputSchema;
  Result.Handler := AHandler;
  Result.Intent := AIntent;
end;

class function TMCPUtf8Utils.SafeLen(const ABytes: TBytes;
  AOffset, AMaxLen: Integer): Integer;
var
  LAvail, LStart, LSeqLen: Integer;
  LByte: Byte;
begin
  Result := AMaxLen;
  if AOffset < 0 then
    AOffset := 0;
  LAvail := Length(ABytes) - AOffset;
  if Result > LAvail then
    Result := LAvail;
  if Result <= 0 then
  begin
    Result := 0;
    Exit;
  end;
  // Walk back over UTF-8 continuation bytes (10xxxxxx) to the lead byte of the last sequence.
  LStart := Result - 1;
  while (LStart > 0) and ((ABytes[AOffset + LStart] and $C0) = $80) do
    Dec(LStart);
  LByte := ABytes[AOffset + LStart];
  if (LByte and $80) = $00 then
    LSeqLen := 1                       // 0xxxxxxx  ASCII
  else if (LByte and $E0) = $C0 then
    LSeqLen := 2                       // 110xxxxx
  else if (LByte and $F0) = $E0 then
    LSeqLen := 3                       // 1110xxxx
  else if (LByte and $F8) = $F0 then
    LSeqLen := 4                       // 11110xxx
  else
    LSeqLen := 1;                      // invalid lead byte: treat as single, never loop
  // If that last sequence runs past the kept length, it is cut -> drop it entirely.
  if LStart + LSeqLen > Result then
    Result := LStart;
end;

class function TMCPProcessGuard.IsInterpreterExe(const AExe: string): Boolean;
const
  CInterpreters: array[0..12] of string = (
    'powershell', 'pwsh', 'cmd', 'command', 'wscript', 'cscript',
    'python', 'python3', 'node', 'ruby', 'perl', 'bash', 'sh');
var
  LName, LInterpreter: string;
begin
  Result := False;
  LName := LowerCase(ExtractFileName(Trim(AExe)));
  if (Length(LName) > 4) and (Copy(LName, Length(LName) - 3, 4) = '.exe') then
    LName := Copy(LName, 1, Length(LName) - 4);
  for LInterpreter in CInterpreters do
    if LName = LInterpreter then
      Exit(True);
end;

{ EMCPError }

constructor EMCPError.Create(const ACode: Integer; const AMessage: string);
begin
  inherited Create(AMessage);
  FCode := ACode;
end;

{ EMCPInvalidRequest }

constructor EMCPInvalidRequest.Create(const AMessage: string);
begin
  inherited Create(MCP_ERR_INVALID_REQUEST, AMessage);
end;

{ EMCPMethodNotFound }

constructor EMCPMethodNotFound.Create(const AMethod: string);
begin
  inherited Create(MCP_ERR_METHOD_NOT_FOUND, 'method not found: ' + AMethod);
end;

{ EMCPInvalidParams }

constructor EMCPInvalidParams.Create(const AMessage: string);
begin
  inherited Create(MCP_ERR_INVALID_PARAMS, AMessage);
end;

{ EMCPInternalError }

constructor EMCPInternalError.Create(const AMessage: string);
begin
  inherited Create(MCP_ERR_INTERNAL, AMessage);
end;

{ EMCPStaleRead }

constructor EMCPStaleRead.Create(const AMessage: string);
begin
  inherited Create(MCP_ERR_STALE_READ, AMessage);
end;

{ EMCPNotRead }

constructor EMCPNotRead.Create(const AMessage: string);
begin
  inherited Create(MCP_ERR_NOT_READ, AMessage);
end;

{ EMCPUserDenied }

constructor EMCPUserDenied.Create(const AMessage: string);
begin
  inherited Create(MCP_ERR_USER_DENIED, AMessage);
end;

{ EMCPBuildInProgress }

constructor EMCPBuildInProgress.Create(const AMessage: string);
begin
  inherited Create(MCP_ERR_BUILD_IN_PROGRESS, AMessage);
end;

{ EMCPResourceNotFound }

constructor EMCPResourceNotFound.Create(const AUri: string);
begin
  inherited Create(MCP_ERR_RESOURCE_NOT_FOUND, 'resource not found: ' + AUri);
end;

{ EMCPWrongView }

constructor EMCPWrongView.Create(const AMessage: string);
begin
  inherited Create(MCP_ERR_WRONG_VIEW, AMessage);
end;

{ EMCPSaveBlocked }

constructor EMCPSaveBlocked.Create(const AMessage: string);
begin
  inherited Create(MCP_ERR_SAVE_BLOCKED, AMessage);
end;

end.
