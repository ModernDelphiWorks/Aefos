unit Aefos.MCP.OTA.WorkspaceFacade;

{
  OTA-backed IMCPWorkspaceFacade for the Terminal (ESP-070, S1+S2 /
  ADR-070-01..03).

  Backs the situational-awareness read set against the live OTA surface.
  Every OTA call marshals to the IDE main thread via TThread.Synchronize
  (BR7). Sentinel-degrades (''/[]/Available=False) on no-active-project,
  no-active-editor, or any OTA failure (BR3, BR11). No exception crosses
  the boundary.

  RequestConsent shows TMCPConsentDialog on the main thread (S2 / BR12).

  AddUnit is the first real OTA-backed mutation (ESP-073, S2 / BR20): a confined,
  no-silent-overwrite IOTAProject.AddFile write gated by the pure UnitCreatePolicy
  seam. Every other mutation stays an honest sentinel (BR20 / BR13 / ADR-073-01).

  This unit uses ToolsAPI and VCL; never linked by the headless runner (BR10).
}

interface

uses
  System.SysUtils,
  Aefos.MCP.Types,
  Aefos.MCP.IntentGuard,
  Aefos.MCP.FlowGuide, // IMCPFlowState (SaveAllFiles-guard seam)
  Aefos.MCP.AuditLog,
  Aefos.MCP.OTA.IDEService,
  Aefos.MCP.OTA.ProjectGroupService,
  Aefos.MCP.OTA.RunService,
  Aefos.MCP.OTA.PackagesService,
  Aefos.MCP.OTA.ResourcesService,
  Aefos.MCP.OTA.BuildConfigService,
  Aefos.MCP.OTA.ProjectWriteService,
  Aefos.MCP.OTA.ProjectReadService,
  Aefos.MCP.OTA.LibraryPathService,
  Aefos.MCP.OTA.EditorReadService,
  Aefos.MCP.OTA.UnitReadService,
  Aefos.MCP.OTA.BuildService,
  Aefos.MCP.OTA.ConsentService,
  Aefos.MCP.OTA.EditorWriteService,
  Aefos.MCP.OTA.CodeInsightWriteService,
  Aefos.MCP.OTA.FormDesignerService,
  Aefos.MCP.OTA.UsesWriteService,
  Aefos.MCP.OTA.StructuralWriteService,
  Aefos.MCP.OTA.ProjectLifecycleService,
  Aefos.MCP.OTA.CodeIntelReadService,
  Aefos.MCP.OTA.ExternalToolService,
  Aefos.MCP.OTA.DprService,
  Aefos.MCP.OTA.IDEReadService,
  Aefos.MCP.OTA.WorkspaceOpsService;

type
  TMCPWorkspaceFacade = class(TInterfacedObject, IMCPWorkspaceFacade, IMCPFlowState,
    IMCPFormCapture)
  private
    // Cross-cutting audit log: the facade still owns it (writes nav/edit lines
    // from several domains) and injects it into the consent service.
    FAudit: IMCPAuditLog;
    // Extracted domain services this thin facade delegates to (SOLID split of the
    // former god-object). Refcounted interfaces, so lifetime is automatic.
    FIDE: IMCPIDEService;
    FProjectGroup: IMCPProjectGroupService;
    FRun: IMCPRunService;
    FPackages: IMCPPackagesService;
    FResources: IMCPResourcesService;
    FBuildConfig: IMCPBuildConfigService;
    FProjectWrite: IMCPProjectWriteService;
    FProjectRead: IMCPProjectReadService;
    FLibraryPath: IMCPLibraryPathService;
    FEditorRead: IMCPEditorReadService;
    FUnitRead: IMCPUnitReadService;
    FBuild: IMCPBuildService;
    FConsent: IMCPConsentService;
    FEditorWrite: IMCPEditorWriteService;
    FCodeInsight: IMCPCodeInsightWriteService;
    FFormDesigner: IMCPFormDesignerService;
    FUsesWrite: IMCPUsesWriteService;
    FStructuralWrite: IMCPStructuralWriteService;
    FProjectLifecycle: IMCPProjectLifecycleService;
    FCodeIntel: IMCPCodeIntelReadService;
    FExternalTool: IMCPExternalToolService;
    FDpr: IMCPDprService;
    FIDERead: IMCPIDEReadService;
    FWorkspaceOps: IMCPWorkspaceOpsService;
  public
    constructor Create(const AConsentTimeoutMs: Cardinal;
      const AAuditPath: string); overload;
    function GetConsentPresenter: IMCPConsentPresenter;
    procedure SetConsentPresenter(const AValue: IMCPConsentPresenter);
    // Inject a consent UI; nil falls back to the global presenter, then to the
    // default VCL modal. The presenter owns its own rendering AND threading.
    // Forwards to the consent service (vestigial — no caller sets it today).
    property ConsentPresenter: IMCPConsentPresenter
      read GetConsentPresenter write SetConsentPresenter;
    // Situational reads — backed by OTA
    function GetActiveProject: TMCPActiveProjectInfo;
    function GetProjectName: string;
    function GetProjectPath: string;
    function GetProjectFilePath: string;
    function GetProjectType: string;
    function GetProjectPlatforms: TArray<string>;
    function GetActiveProjectPlatform: string;
    function GetProjectConfigurations: TArray<string>;
    function GetActiveConfiguration: string;
    function GetProjectOutputDir: string;
    function GetActiveUnit: string;
    function GetCursorPosition: TMCPCursorInfo;
    function GetSelection: TMCPSelectionInfo;
    function CurrentIdeViewIntent: TMCPToolIntent;
    function SaveAllFilesGuardReason: string; // IMCPFlowState
    function CaptureActiveFormPng(const AUnitName: string;
      out ABase64, APngPath, AReason: string): Boolean; // IMCPFormCapture
    function GetEditorActiveFile(out AName, APath: string): Boolean;
    function GetOpenEditorFiles(out AFiles: TArray<TMCPRecordEditorFile>): Boolean;
    function IsUnitOpen(const AUnitName: string): Boolean;
    function GetUnitFilePath(const AUnitName: string): string;
    function ReadUnit(const AUnitPath: string; out ABody: string): Boolean;
    function GetIDEVersion: TMCPRecordIDEVersion;
    function GetIDETheme: string;
    function GetRecentFiles: TArray<string>;
    function GetProjectManagerTree: TArray<TMCPRecordProjectManagerNode>;
    // Real consent modal (S2)
    function RequestConsent(const AToolName, ASummary,
      ADetail: string): TMCPConsentDecision;
    // Write sentinels — honest stubs; real mutations are D3+ (BR13)
    function EditUnit(const AUnitPath, AOldText, ANewText: string;
      out AError: string): TMCPEditOutcome;
    function DeleteUnit(const AUnitPath: string;
      out AError: string): TMCPFileActionOutcome;
    function OverwriteFile(const AFilePath, AContent: string;
      out AError: string): TMCPFileActionOutcome;
    function AddUnit(const AUnitPath, AContent: string;
      out AError: string): TMCPFileActionOutcome;
    function StartBuild(const AMode: string; out AError: string): Boolean;
    function QueryBuildResult: TMCPBuildState;
    function CancelBuild: Boolean;
    function GetCompilerMessages: TArray<TMCPCompilerMessage>;
    function GetProjectVersion: string;
    function GetProjectGUID: string;
    function GetProjectDescription: string;
    function SetProjectVersion(const AMajor, AMinor, ARelease,
      ABuild: Integer): Boolean;
    function SetActiveProjectPlatform(const APlatformName: string): Boolean;
    function SetActiveConfiguration(const AConfigName: string): Boolean;
    function SetProjectDescription(const ADescription: string): Boolean;
    function SetProjectOutputDir(const ADir: string): Boolean;
    function GetUnitUses(const AUnitName: string;
      out AInterfaceUses, AImplementationUses: TArray<string>): Boolean;
    function OpenUnitInEditor(const AUnitName: string): Boolean;
    function OpenFile(const APath: string): Boolean;
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
    function SetEditorCursorPosition(const ALine, ACol: Integer): Boolean;
    function InsertCodeAtCursor(const ACode: string): Boolean;
    function ReplaceEditorSelection(const ANewText: string): Boolean;
    function GetEditorFullContent(out AContent: string): Boolean;
    function SetEditorFullContent(const ASource: string): Boolean;
    function FindInEditor(const AText: string; const ACaseSensitive: Boolean;
      out AOccurrences: TArray<TMCPCursorInfo>): Boolean;
    function ReplaceInEditor(const AFind, AReplace: string; const AAll: Boolean;
      out ACount: Integer): Boolean;
    function FindInProject(const AText: string; const ACaseSensitive: Boolean;
      out AOccurrences: TArray<TMCPCursorInfo>): Boolean;
    function SaveActiveFile(out AChanged: Boolean): Boolean;
    function SaveAllFiles(out AChanged: Boolean): Boolean;
    function UndoEditor: Boolean;
    function CloseFile(const AFilePath: string; const ASaveFirst: Boolean): Boolean;
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
    function GetDPRContent: string;
    function SetDPRContent(const ASource: string; out AReason: string): Boolean;
    function RenameDPR(const ANewName: string; out AReason: string): Boolean;
    function GetDPRUsedForms: TArray<TMCPRecordDPRCreateForm>;
    function GetMainForm: string;
    function SetMainForm(const AFormClass: string;
      out AChanged: Boolean; out AReason: string): Boolean;
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
    function RemoveComponent(const AUnitName, AComponentName: string;
      out AChanged: Boolean; out AReason: string): Boolean;
    function AddComponent(const AUnitName, AComponentClass, AComponentName,
      AParent: string;
      const ALeft, ATop, AWidth, AHeight: Integer;
      out AChanged: Boolean; out AReason: string): Boolean;
    function AddEventHandler(const AUnitName, AComponentName, AEventName,
      AHandlerName, ABody: string;
      out AChanged: Boolean; out AReason: string): Boolean;
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
    function ListProjectPackages: TArray<TMCPRecordProjectPackage>;
    function AddPackageToProject(const APackagePath: string;
      const ARuntime: Boolean;
      out AChanged: Boolean; out AReason: string): Boolean;
    function RemovePackageFromProject(const APackageName: string;
      out AChanged: Boolean; out AReason: string): Boolean;
    function GetLibraryPath: TArray<string>;
    function AddToLibraryPath(const APath: string;
      out AChanged: Boolean; out AReason: string): Boolean;
    function ShowIDEMessage(const AText: string;
      const AUseOutput: Boolean): Boolean;
    function ExecuteIDEAction(const AActionName: string;
      out AReason: string): Boolean;
    function ListIDEActions(const AFilter: string): string;
    function RefreshProjectManager: Boolean;
    function RunExternalTool(const AArgv: TArray<string>;
      out ARun: TMCPRecordExternalToolRun; out AReason: string): Boolean;
    function ListProjectResources: TArray<TMCPRecordProjectResource>;
    function AddResourceFile(const AFilePath: string;
      out AChanged: Boolean; out AReason: string): Boolean;
    function ListProjectImages: TArray<string>;
    function RenameProject(const AOldName, ANewName: string;
      out AOutcome: TRenameOutcome): Boolean;
    function RenameUnit(const AUnitName, ANewUnitName: string;
      out AOutcome: TRenameOutcome): Boolean;
    function MoveUnitToFolder(const AUnitName, ATargetFolder: string;
      out AOutcome: TRenameOutcome): Boolean;
  end;

implementation

uses
  System.Classes,
  ToolsAPI,
  Aefos.MCP.OTA.FacadeShared,
  Aefos.MCP.OTA.ReviewGate;


{ ── TMCPWorkspaceFacade — construction ─────────────────────────── }

constructor TMCPWorkspaceFacade.Create(const AConsentTimeoutMs: Cardinal;
  const AAuditPath: string);
begin
  inherited Create;
  // Mirror TTerminalMCPHost._BuildServer so the facade's timeout-denied line
  // lands in the same JSONL file Core writes its consent lines to.
  if AAuditPath <> '' then
    FAudit := TMCPAuditLog.Create(AAuditPath)
  else
    FAudit := TMCPAuditLog.Create;
  // Domain services (SOLID split). Each owns one responsibility; the facade
  // delegates its frozen IMCPWorkspaceFacade methods to them.
  FIDE := NewMCPIDEService;
  FProjectGroup := NewMCPProjectGroupService;
  FRun := NewMCPRunService;
  FPackages := NewMCPPackagesService;
  FResources := NewMCPResourcesService;
  FBuildConfig := NewMCPBuildConfigService;
  FProjectWrite := NewMCPProjectWriteService;
  FProjectRead := NewMCPProjectReadService;
  FLibraryPath := NewMCPLibraryPathService;
  FEditorRead := NewMCPEditorReadService;
  FUnitRead := NewMCPUnitReadService;
  FBuild := NewMCPBuildService;
  // Consent owns its timeout + presenter; the shared audit log is injected.
  FConsent := NewMCPConsentService(AConsentTimeoutMs, FAudit);
  FEditorWrite := NewMCPEditorWriteService;
  FCodeInsight := NewMCPCodeInsightWriteService;
  FFormDesigner := NewMCPFormDesignerService;
  FUsesWrite := NewMCPUsesWriteService;
  FStructuralWrite := NewMCPStructuralWriteService;
  FProjectLifecycle := NewMCPProjectLifecycleService;
  FCodeIntel := NewMCPCodeIntelReadService;
  FExternalTool := NewMCPExternalToolService;
  // DPR reads the project form list via the form-designer service (GetMainForm).
  FDpr := NewMCPDprService(FFormDesigner);
  FIDERead := NewMCPIDEReadService;
  // The final slice — remaining editor + file + workspace ops. FAudit (still
  // owned here) and FEditorRead (an earlier extraction) are injected.
  FWorkspaceOps := NewMCPWorkspaceOpsService(FAudit, FEditorRead);
end;

{ ── OTA read helpers ───────────────────────────────────────────────────── }


{ ── D2 read helpers (ESP-085) ──────────────────────────────────────────
  Module/source resolution, project-option keys, uses-clause parse, and
  content search backing the editor/file/code-intelligence/DFM reads. OTA
  access is marshalled onto the IDE main thread by the callers (each read
  wraps the OTA portion in TThread.Synchronize, BR7); the pure parsers
  (Aefos.MCP.PasParser / .DFMParser, already linked) run off-thread. }

{ ── TMCPWorkspaceFacade — situational reads ───────────────────── }

function TMCPWorkspaceFacade.GetActiveProject: TMCPActiveProjectInfo;
begin
  Result := FProjectRead.GetActiveProject;
end;

function TMCPWorkspaceFacade.GetProjectName: string;
begin
  Result := FProjectRead.GetProjectName;
end;

function TMCPWorkspaceFacade.GetProjectPath: string;
begin
  Result := FProjectRead.GetProjectPath;
end;

function TMCPWorkspaceFacade.GetProjectFilePath: string;
begin
  Result := FProjectRead.GetProjectFilePath;
end;

function TMCPWorkspaceFacade.GetProjectType: string;
begin
  Result := FProjectRead.GetProjectType;
end;

function TMCPWorkspaceFacade.GetProjectPlatforms: TArray<string>;
begin
  Result := FProjectRead.GetProjectPlatforms;
end;

function TMCPWorkspaceFacade.GetActiveProjectPlatform: string;
begin
  Result := FProjectRead.GetActiveProjectPlatform;
end;

function TMCPWorkspaceFacade.GetProjectConfigurations: TArray<string>;
begin
  Result := FProjectRead.GetProjectConfigurations;
end;

function TMCPWorkspaceFacade.GetActiveConfiguration: string;
begin
  Result := FProjectRead.GetActiveConfiguration;
end;

function TMCPWorkspaceFacade.GetProjectOutputDir: string;
begin
  Result := FProjectRead.GetProjectOutputDir;
end;

function TMCPWorkspaceFacade.GetActiveUnit: string;
begin
  Result := FEditorRead.GetActiveUnit;
end;

function TMCPWorkspaceFacade.GetCursorPosition: TMCPCursorInfo;
begin
  Result := FEditorRead.GetCursorPosition;
end;

function TMCPWorkspaceFacade.GetSelection: TMCPSelectionInfo;
begin
  Result := FEditorRead.GetSelection;
end;

function TMCPWorkspaceFacade.CurrentIdeViewIntent: TMCPToolIntent;
begin
  Result := FEditorRead.CurrentIdeViewIntent;
end;

function TMCPWorkspaceFacade.SaveAllFilesGuardReason: string;
begin
  // V1 — pending review: a SaveAllFiles would auto-accept + clear unresolved ✓/✗
  // gutters. Refuse UNLESS the user enabled "Agent auto-save edits" (TReviewGate.ReviewAutoAccept),
  // in which case auto-accepting on save is exactly the opted-in behaviour — let it pass.
  Result := '';
  if TReviewGate.ReviewPendingGlobal and not TReviewGate.ReviewAutoAccept then
    Exit(TFlowGuide.SavePendingReviewMessage);
  // V2 — a .dfm event wired to a handler not in code yet: saving lets the IDE STRIP the
  // wire. Fires ALWAYS (a different hazard than the review gutters — the auto-save opt-in
  // is irrelevant here). Checks every open form's LIVE .dfm + .pas buffer.
  Result := FFormDesigner.SaveGuardDanglingReason;
end;

function TMCPWorkspaceFacade.GetEditorActiveFile(out AName,
  APath: string): Boolean;
begin
  Result := FEditorRead.GetEditorActiveFile(AName, APath);
end;

function TMCPWorkspaceFacade.GetOpenEditorFiles(
  out AFiles: TArray<TMCPRecordEditorFile>): Boolean;
begin
  Result := FEditorRead.GetOpenEditorFiles(AFiles);
end;

function TMCPWorkspaceFacade.IsUnitOpen(const AUnitName: string): Boolean;
begin
  Result := FUnitRead.IsUnitOpen(AUnitName);
end;

function TMCPWorkspaceFacade.GetUnitFilePath(
  const AUnitName: string): string;
begin
  Result := FUnitRead.GetUnitFilePath(AUnitName);
end;

function TMCPWorkspaceFacade.ReadUnit(const AUnitPath: string;
  out ABody: string): Boolean;
begin
  Result := FUnitRead.ReadUnit(AUnitPath, ABody);
end;

function TMCPWorkspaceFacade.GetIDEVersion: TMCPRecordIDEVersion;
begin
  Result := FIDERead.GetIDEVersion;
end;

function TMCPWorkspaceFacade.GetIDETheme: string;
begin
  Result := FIDERead.GetIDETheme;
end;

function TMCPWorkspaceFacade.GetRecentFiles: TArray<string>;
begin
  Result := FIDERead.GetRecentFiles;
end;

function TMCPWorkspaceFacade.GetProjectManagerTree: TArray<TMCPRecordProjectManagerNode>;
begin
  Result := FIDERead.GetProjectManagerTree;
end;

{ ── Consent modal (S2) + bounded wait (S1 / BR14) ──────────────────────── }

// IRREVERSIBLE / destructive structural tools: even under "Auto-approve edits"
// (AgentConsentMode = 1) these still prompt, because an undo/review cannot take
// them back. Mode 2 ("Auto-approve everything") bypasses even these. The list is
// deliberately inclusive — a name that is never consent-gated is simply never
// reached here, so erring toward "destructive" only ever keeps a prompt.
function TMCPWorkspaceFacade.GetConsentPresenter: IMCPConsentPresenter;
begin
  Result := FConsent.ConsentPresenter;
end;

procedure TMCPWorkspaceFacade.SetConsentPresenter(
  const AValue: IMCPConsentPresenter);
begin
  FConsent.ConsentPresenter := AValue;
end;

function TMCPWorkspaceFacade.RequestConsent(const AToolName,
  ASummary, ADetail: string): TMCPConsentDecision;
begin
  Result := FConsent.RequestConsent(AToolName, ASummary, ADetail);
end;

{ ── Structural writes — real OTA mutations (ESP-088, S2) ────────────────── }

// Apply a single anchored replacement (AOldText -> ANewText) to the live editor
// buffer of AUnitPath; the anchor must match exactly once (ADR-061/062). The
// pure occurrence count comes from ContentWritePolicy.ReplaceInBuffer; the
// single whole-buffer write goes through TFacadeShared.ReplaceWholeBuffer (left dirty /
// undoable). eoUnitNotOpen when the unit is not open in the editor.
function TMCPWorkspaceFacade.EditUnit(const AUnitPath, AOldText,
  ANewText: string; out AError: string): TMCPEditOutcome;
begin
  Result := FEditorWrite.EditUnit(AUnitPath, AOldText, ANewText, AError);
end;

function TMCPWorkspaceFacade.DeleteUnit(const AUnitPath: string;
  out AError: string): TMCPFileActionOutcome;
begin
  Result := FStructuralWrite.DeleteUnit(AUnitPath, AError);
end;

function TMCPWorkspaceFacade.OverwriteFile(const AFilePath,
  AContent: string; out AError: string): TMCPFileActionOutcome;
begin
  Result := FWorkspaceOps.OverwriteFile(AFilePath, AContent, AError);
end;

function TMCPWorkspaceFacade.AddUnit(const AUnitPath,
  AContent: string; out AError: string): TMCPFileActionOutcome;
begin
  Result := FProjectLifecycle.AddUnit(AUnitPath, AContent, AError);
end;

// Build the active (scratch) project via the command-line compiler so the build
// emits a READABLE diagnostics log — the headline fix for agent-blindness
// (ESP-093 follow-up / live-test 2026-06-19). OTA's IOTAProjectBuilder reports
// only pass/fail and IOTAMessageServices is add-only (no Messages-pane read, see
// GetCompilerMessages note), so a pure-OTA build can never surface error text.
// Instead StartBuild shells out to `rsvars && msbuild <dproj>` with an msbuild
// FILE logger (/flp) writing to a deterministic path next to the .dproj; the exit
// code is the honest pass/fail (no faked success) and GetCompilerMessages parses
// that file (a read never builds, BR8). The pure BuildRunPolicy seam still
// validates the mode (make -> /t:Make incremental, build/rebuild -> /t:Build
// full); an unknown mode is refused before any work. Project coordinates and the
// IDE root are read on the main thread (BR7); the compiler itself runs off it.
// Scratch-project-scoped (ADR-091-05); RADShell is never built.
function TMCPWorkspaceFacade.StartBuild(const AMode: string;
  out AError: string): Boolean;
begin
  Result := FBuild.StartBuild(AMode, AError);
end;

function TMCPWorkspaceFacade.QueryBuildResult: TMCPBuildState;
begin
  Result := FBuild.QueryBuildResult;
end;

function TMCPWorkspaceFacade.CancelBuild: Boolean;
begin
  Result := FBuild.CancelBuild;
end;

function TMCPWorkspaceFacade.GetCompilerMessages: TArray<TMCPCompilerMessage>;
begin
  Result := FBuild.GetCompilerMessages;
end;

// Composed major.minor.release.build read from the active project's .dproj
// VerInfo (ESP-092 / upstream ask #5). OTA exposes no VerInfo accessor, so the
// value is parsed from the .dproj XML via the pure DProjParser seam (ADR-092-01).
function TMCPWorkspaceFacade.GetProjectVersion: string;
begin
  Result := FProjectRead.GetProjectVersion;
end;

function TMCPWorkspaceFacade.GetProjectGUID: string;
begin
  Result := FProjectRead.GetProjectGUID;
end;

function TMCPWorkspaceFacade.GetProjectDescription: string;
begin
  Result := FProjectRead.GetProjectDescription;
end;

// Best-effort VersionInfo write (ESP-089, S2). The matching read accessor
// GetProjectVersion has no OTA implementation (Epic-1 finding, upstream ask #5),
// so the mutation is applied but NOT read-verifiable through the catalog —
// dispositioned as a documented CAVEAT (ADR-089-03 / R3), never forced to FAIL.
// Scratch-scoped & reversible (ADR-089-07): the scratch project's VerInfo only.
function TMCPWorkspaceFacade.SetProjectVersion(const AMajor, AMinor,
  ARelease, ABuild: Integer): Boolean;
begin
  Result := FProjectWrite.SetProjectVersion(AMajor, AMinor, ARelease, ABuild);
end;

function TMCPWorkspaceFacade.SetActiveProjectPlatform(
  const APlatformName: string): Boolean;
begin
  Result := FProjectWrite.SetActiveProjectPlatform(APlatformName);
end;

function TMCPWorkspaceFacade.SetActiveConfiguration(
  const AConfigName: string): Boolean;
begin
  Result := FProjectWrite.SetActiveConfiguration(AConfigName);
end;

function TMCPWorkspaceFacade.SetProjectDescription(
  const ADescription: string): Boolean;
begin
  Result := FProjectWrite.SetProjectDescription(ADescription);
end;

function TMCPWorkspaceFacade.SetProjectOutputDir(
  const ADir: string): Boolean;
begin
  Result := FProjectWrite.SetProjectOutputDir(ADir);
end;

function TMCPWorkspaceFacade.GetUnitUses(const AUnitName: string;
  out AInterfaceUses, AImplementationUses: TArray<string>): Boolean;
begin
  Result := FUsesWrite.GetUnitUses(AUnitName, AInterfaceUses, AImplementationUses);
end;

function TMCPWorkspaceFacade.OpenUnitInEditor(
  const AUnitName: string): Boolean;
begin
  Result := FWorkspaceOps.OpenUnitInEditor(AUnitName);
end;

function TMCPWorkspaceFacade.OpenFile(const APath: string): Boolean;
begin
  Result := FWorkspaceOps.OpenFile(APath);
end;

function TMCPWorkspaceFacade.AddUnitToProject(
  const AFilePath: string): Boolean;
begin
  Result := FStructuralWrite.AddUnitToProject(AFilePath);
end;

function TMCPWorkspaceFacade.RemoveUnitFromProject(
  const AUnitName: string): Boolean;
begin
  Result := FStructuralWrite.RemoveUnitFromProject(AUnitName);
end;

// Public interface method — unchanged contract; delegated to the project-
// lifecycle service (AddUnit / CreateNewUnit / CreateNewProject / CloseAllProjects).
function TMCPWorkspaceFacade.CreateNewUnit(const AUnitName: string;
  AWithForm: Boolean; out AFilePath: string): Boolean;
begin
  Result := FProjectLifecycle.CreateNewUnit(AUnitName, AWithForm, AFilePath);
end;

function TMCPWorkspaceFacade.CreateNewProject(const AName,
  AProjectType, ADirectory: string; out ADProjPath: string;
  out AReason: string): Boolean;
begin
  Result := FProjectLifecycle.CreateNewProject(
    AName, AProjectType, ADirectory, ADProjPath, AReason);
end;

function TMCPWorkspaceFacade.CloseAllProjects: Boolean;
begin
  Result := FProjectLifecycle.CloseAllProjects;
end;

// True when APath is a member module of the active (scratch) project. Backs the
// ADR-090-07 / BR10 scratch-module-scope guard for the source/uses writes: a
// target that does not resolve to an active-project module is refused (no
// change), so no RADShell module can be reached. Runs on the OTA main thread.
function TMCPWorkspaceFacade.AddToUses(const ATargetUnit, AUnitToAdd,
  ASection: string; out AChanged: Boolean): Boolean;
begin
  Result := FUsesWrite.AddToUses(ATargetUnit, AUnitToAdd, ASection, AChanged);
end;

function TMCPWorkspaceFacade.RemoveFromUses(const ATargetUnit,
  AUnitToRemove: string; out AChanged: Boolean): Boolean;
begin
  Result := FUsesWrite.RemoveFromUses(ATargetUnit, AUnitToRemove, AChanged);
end;

function TMCPWorkspaceFacade.SetEditorCursorPosition(const ALine,
  ACol: Integer): Boolean;
begin
  Result := FWorkspaceOps.SetEditorCursorPosition(ALine, ACol);
end;

// Insert ACode at the active editor caret (ESP-087, S2). The OTA-free splice is
// computed by ContentWritePolicy.InsertTextAt; the confined whole-buffer replace
// is the single undoable OTA write (R1). Active-editor only (ADR-087-07).
// NOTE (Phase 2): routing this through the inline diff was REVERTED — the localized
// pure-insertion diff triggered a FastMM use-after-free AV (rtl370 ~103B6), same
// class as crash #4. Applies directly (the shipped 0.18.0 behaviour) until that
// diff-paint path is fixed. See meta/tool-audit-livetest-calc-2026-06-20.md.
function TMCPWorkspaceFacade.InsertCodeAtCursor(
  const ACode: string): Boolean;
begin
  Result := FEditorWrite.InsertCodeAtCursor(ACode);
end;

// Replace the active editor selection with ANewText (ESP-087, S2). The range
// splice is computed by ContentWritePolicy.ReplaceTextRange (end column
// exclusive, OTA block convention); a missing/invalid selection is a no-op
// False. Active-editor only (ADR-087-07).
function TMCPWorkspaceFacade.ReplaceEditorSelection(
  const ANewText: string): Boolean;
begin
  Result := FWorkspaceOps.ReplaceEditorSelection(ANewText);
end;

function TMCPWorkspaceFacade.GetEditorFullContent(
  out AContent: string): Boolean;
begin
  Result := FWorkspaceOps.GetEditorFullContent(AContent);
end;

// Replace the whole active editor buffer with ASource (ESP-087, S2). One
// undoable OTA write (R1) on the active scratch unit only (ADR-087-07).

function TMCPWorkspaceFacade.SetEditorFullContent(
  const ASource: string): Boolean;
begin
  Result := FEditorWrite.SetEditorFullContent(ASource);
end;

function TMCPWorkspaceFacade.FindInEditor(const AText: string;
  const ACaseSensitive: Boolean;
  out AOccurrences: TArray<TMCPCursorInfo>): Boolean;
begin
  Result := FWorkspaceOps.FindInEditor(AText, ACaseSensitive, AOccurrences);
end;

// Find/replace over the active editor buffer (ESP-087, S2). The counted
// substitution is computed by ContentWritePolicy.ReplaceInBuffer (all-or-first);
// a zero-match call is a valid no-op (count 0, no write). The substituted text
// is committed by one undoable whole-buffer write (R1). Active-editor only
// (ADR-087-07).
function TMCPWorkspaceFacade.ReplaceInEditor(const AFind,
  AReplace: string; const AAll: Boolean; out ACount: Integer): Boolean;
begin
  Result := FEditorWrite.ReplaceInEditor(AFind, AReplace, AAll, ACount);
end;

function TMCPWorkspaceFacade.FindInProject(const AText: string;
  const ACaseSensitive: Boolean;
  out AOccurrences: TArray<TMCPCursorInfo>): Boolean;
begin
  Result := FWorkspaceOps.FindInProject(AText, ACaseSensitive, AOccurrences);
end;

function TMCPWorkspaceFacade.SaveActiveFile(
  out AChanged: Boolean): Boolean;
begin
  Result := FWorkspaceOps.SaveActiveFile(AChanged);
end;

function TMCPWorkspaceFacade.SaveAllFiles(
  out AChanged: Boolean): Boolean;
begin
  Result := FWorkspaceOps.SaveAllFiles(AChanged);
end;

function TMCPWorkspaceFacade.UndoEditor: Boolean;
begin
  Result := FWorkspaceOps.UndoEditor;
end;

function TMCPWorkspaceFacade.CloseFile(const AFilePath: string;
  const ASaveFirst: Boolean): Boolean;
begin
  Result := FWorkspaceOps.CloseFile(AFilePath, ASaveFirst);
end;

function TMCPWorkspaceFacade.GetSearchPath: TArray<string>;
begin
  Result := FBuildConfig.GetSearchPath;
end;

function TMCPWorkspaceFacade.SetSearchPath(
  const APaths: TArray<string>): Boolean;
begin
  Result := FBuildConfig.SetSearchPath(APaths);
end;

function TMCPWorkspaceFacade.AddToSearchPath(
  const APath: string): Boolean;
begin
  Result := FBuildConfig.AddToSearchPath(APath);
end;

function TMCPWorkspaceFacade.GetConditionalDefines: TArray<string>;
begin
  Result := FBuildConfig.GetConditionalDefines;
end;

function TMCPWorkspaceFacade.SetConditionalDefines(
  const ADefines: TArray<string>): Boolean;
begin
  Result := FBuildConfig.SetConditionalDefines(ADefines);
end;

function TMCPWorkspaceFacade.AddConditionalDefine(
  const ADefine: string): Boolean;
begin
  Result := FBuildConfig.AddConditionalDefine(ADefine);
end;

function TMCPWorkspaceFacade.RemoveConditionalDefine(
  const ADefine: string): Boolean;
begin
  Result := FBuildConfig.RemoveConditionalDefine(ADefine);
end;

function TMCPWorkspaceFacade.GetDCUOutputDir: string;
begin
  Result := FBuildConfig.GetDCUOutputDir;
end;

function TMCPWorkspaceFacade.SetDCUOutputDir(
  const ADir: string): Boolean;
begin
  Result := FBuildConfig.SetDCUOutputDir(ADir);
end;

// Clean the scratch project's build output via IOTAProjectBuilder (ESP-091, S2 /
// ADR-091-07 / R7). cmOTAClean removes the output files the build generated;
// the effect is read-verified by GetProjectOutputDir / GetDCUOutputDir plus a
// filesystem check that the .exe / .dcu artifacts are gone. Scratch-scoped: the
// active project is the campaign's scratch project; RADShell is never cleaned.
function TMCPWorkspaceFacade.CleanProject: Boolean;
begin
  Result := FBuild.CleanProject;
end;

function TMCPWorkspaceFacade.SendKeystroke(
  const AKeys: string): Boolean;
begin
  Result := FRun.SendKeystroke(AKeys);
end;

function TMCPWorkspaceFacade.RunProject: Boolean;
begin
  Result := FRun.RunProject;
end;

function TMCPWorkspaceFacade.RunWithoutDebugger: Boolean;
begin
  Result := FRun.RunWithoutDebugger;
end;

// Terminate any active debugged process via IOTADebuggerServices (ESP-091, S2 /
// ADR-091-07 / BR11 — the no-orphan guarantee). Idempotent: when no process is
// running it is a valid no-op (False, nothing to stop); when one or more debug
// sessions are active it terminates each and reports success. The observable
// "process stopped" side-effect is IOTADebuggerServices.ProcessCount dropping to
// zero. This is the campaign's standing guard that no launched process is left
// orphaned.
function TMCPWorkspaceFacade.StopProject: Boolean;
begin
  Result := FRun.StopProject;
end;

function TMCPWorkspaceFacade.GetDPRContent: string;
begin
  Result := FDpr.GetDPRContent;
end;

function TMCPWorkspaceFacade.SetDPRContent(const ASource: string;
  out AReason: string): Boolean;
begin
  Result := FDpr.SetDPRContent(ASource, AReason);
end;

function TMCPWorkspaceFacade.RenameDPR(const ANewName: string;
  out AReason: string): Boolean;
begin
  Result := FDpr.RenameDPR(ANewName, AReason);
end;

function TMCPWorkspaceFacade.GetDPRUsedForms: TArray<TMCPRecordDPRCreateForm>;
begin
  Result := FDpr.GetDPRUsedForms;
end;

function TMCPWorkspaceFacade.GetMainForm: string;
begin
  Result := FDpr.GetMainForm;
end;

function TMCPWorkspaceFacade.SetMainForm(const AFormClass: string;
  out AChanged: Boolean; out AReason: string): Boolean;
begin
  Result := FDpr.SetMainForm(AFormClass, AChanged, AReason);
end;

function TMCPWorkspaceFacade.ListProjectForms: TArray<TMCPRecordProjectForm>;
begin
  Result := FFormDesigner.ListProjectForms;
end;

function TMCPWorkspaceFacade.GetDFMContent(const AUnitName: string;
  out AContent: string; out AIsBinary: Boolean): Boolean;
begin
  Result := FFormDesigner.GetDFMContent(AUnitName, AContent, AIsBinary);
end;

function TMCPWorkspaceFacade.SetDFMContent(const AUnitName,
  ADFMSource: string; out AReason: string): Boolean;
begin
  Result := FFormDesigner.SetDFMContent(AUnitName, ADFMSource, AReason);
end;

function TMCPWorkspaceFacade.GetFormProperties(const AUnitName: string;
  out AProperties: TArray<TMCPRecordDFMProperty>): Boolean;
begin
  Result := FFormDesigner.GetFormProperties(AUnitName, AProperties);
end;

function TMCPWorkspaceFacade.SetFormProperty(const AUnitName,
  APropName, APropValue: string;
  out AChanged: Boolean; out AReason: string): Boolean;
begin
  Result := FFormDesigner.SetFormProperty(AUnitName, APropName, APropValue,
    AChanged, AReason);
end;

function TMCPWorkspaceFacade.ListFormComponents(const AUnitName: string;
  out AComponents: TArray<TMCPRecordDFMComponent>): Boolean;
begin
  Result := FFormDesigner.ListFormComponents(AUnitName, AComponents);
end;

function TMCPWorkspaceFacade.GetComponentProperties(
  const AUnitName, AComponentName: string;
  out AProperties: TArray<TMCPRecordDFMProperty>): Boolean;
begin
  Result := FFormDesigner.GetComponentProperties(AUnitName, AComponentName,
    AProperties);
end;

function TMCPWorkspaceFacade.SetComponentProperty(const AUnitName,
  AComponentName, APropName, APropValue: string;
  out AChanged: Boolean; out AReason: string): Boolean;
begin
  Result := FFormDesigner.SetComponentProperty(AUnitName, AComponentName,
    APropName, APropValue, AChanged, AReason);
end;

function TMCPWorkspaceFacade.OpenFormDesigner(const AUnitName: string;
  out AChanged: Boolean; out AReason: string): Boolean;
begin
  Result := FFormDesigner.OpenFormDesigner(AUnitName, AChanged, AReason);
end;

function TMCPWorkspaceFacade.OpenDFMTextEditor(const AUnitName: string;
  out AChanged: Boolean; out AReason: string): Boolean;
begin
  Result := FFormDesigner.OpenDFMTextEditor(AUnitName, AChanged, AReason);
end;

function TMCPWorkspaceFacade.RemoveComponent(const AUnitName,
  AComponentName: string;
  out AChanged: Boolean; out AReason: string): Boolean;
begin
  Result := FFormDesigner.RemoveComponent(AUnitName, AComponentName,
    AChanged, AReason);
end;

function TMCPWorkspaceFacade.AddComponent(const AUnitName, AComponentClass,
  AComponentName, AParent: string;
  const ALeft, ATop, AWidth, AHeight: Integer;
  out AChanged: Boolean; out AReason: string): Boolean;
begin
  Result := FFormDesigner.AddComponent(AUnitName, AComponentClass, AComponentName,
    AParent, ALeft, ATop, AWidth, AHeight, AChanged, AReason);
end;

function TMCPWorkspaceFacade.CaptureActiveFormPng(const AUnitName: string;
  out ABase64, APngPath, AReason: string): Boolean;
begin
  Result := FFormDesigner.CaptureActiveFormPng(AUnitName, ABase64, APngPath, AReason);
end;

function TMCPWorkspaceFacade.AddEventHandler(const AUnitName, AComponentName,
  AEventName, AHandlerName, ABody: string;
  out AChanged: Boolean; out AReason: string): Boolean;
begin
  Result := FFormDesigner.AddEventHandler(AUnitName, AComponentName, AEventName,
    AHandlerName, ABody, AChanged, AReason);
end;

function TMCPWorkspaceFacade.GetSymbolsInUnit(const AUnitName: string;
  out ASymbols: TArray<TMCPRecordUnitSymbol>): Boolean;
begin
  Result := FCodeIntel.GetSymbolsInUnit(AUnitName, ASymbols);
end;

function TMCPWorkspaceFacade.GetClassMembers(const AUnitName,
  AClassName: string; out AMembers: TArray<TMCPRecordClassMember>): Boolean;
begin
  Result := FCodeIntel.GetClassMembers(AUnitName, AClassName, AMembers);
end;

function TMCPWorkspaceFacade.FindSymbolUsages(const ASymbol: string;
  out AUsages: TArray<TMCPRecordSymbolUsage>): Boolean;
begin
  Result := FCodeIntel.FindSymbolUsages(ASymbol, AUsages);
end;

function TMCPWorkspaceFacade.GetMethodBody(const AUnitName,
  AMethodName: string; out ABody: string): Boolean;
begin
  Result := FCodeIntel.GetMethodBody(AUnitName, AMethodName, ABody);
end;

// Insert a method (signature + body) into AClassName on the active scratch unit
// (ESP-087, S2). All OTA-free structure decisions — class resolution, the decl
// and implementation insertion points, the qualified header — live in
// ContentWritePolicy.PlanMethodInsertion (R4, ESP-073 seam precedent); this
// caller marshals the resulting whole-buffer replace as one undoable OTA write
// (R1). Honest no-op (Changed=False + kebab AReason) when the class is absent or
// the signature is malformed. Active-editor only (ADR-087-07).
function TMCPWorkspaceFacade.InsertMethod(const AUnitName, AClassName,
  ASignature, ABody: string;
  out AChanged: Boolean; out AReason: string): Boolean;
begin
  Result := FCodeInsight.InsertMethod(AUnitName, AClassName, ASignature, ABody,
    AChanged, AReason);
end;

function TMCPWorkspaceFacade.GetInheritanceChain(
  const AClassName: string; out AChain: TArray<string>): Boolean;
begin
  Result := FCodeIntel.GetInheritanceChain(AClassName, AChain);
end;

function TMCPWorkspaceFacade.GetProjectGroupName: string;
begin
  Result := FProjectGroup.GetProjectGroupName;
end;

function TMCPWorkspaceFacade.ListProjectsInGroup: TArray<TMCPRecordGroupProject>;
begin
  Result := FProjectGroup.ListProjectsInGroup;
end;

function TMCPWorkspaceFacade.SetActiveProject(
  const AProjectPath: string;
  out AChanged: Boolean; out AReason: string): Boolean;
begin
  Result := FProjectGroup.SetActiveProject(AProjectPath, AChanged, AReason);
end;

function TMCPWorkspaceFacade.AddProjectToGroup(
  const AProjectPath: string;
  out AChanged: Boolean; out AReason: string): Boolean;
begin
  Result := FProjectGroup.AddProjectToGroup(AProjectPath, AChanged, AReason);
end;

function TMCPWorkspaceFacade.RemoveProjectFromGroup(
  const AProjectPath: string;
  out AChanged: Boolean; out AReason: string): Boolean;
begin
  Result := FProjectGroup.RemoveProjectFromGroup(AProjectPath, AChanged, AReason);
end;

function TMCPWorkspaceFacade.BuildAllInGroup(
  out AResults: TArray<TMCPRecordGroupBuildResult>;
  out AReason: string): Boolean;
begin
  Result := FProjectGroup.BuildAllInGroup(AResults, AReason);
end;

function TMCPWorkspaceFacade.ListProjectPackages: TArray<TMCPRecordProjectPackage>;
begin
  Result := FPackages.ListProjectPackages;
end;

function TMCPWorkspaceFacade.AddPackageToProject(
  const APackagePath: string; const ARuntime: Boolean;
  out AChanged: Boolean; out AReason: string): Boolean;
begin
  Result := FPackages.AddPackageToProject(APackagePath, ARuntime, AChanged, AReason);
end;

function TMCPWorkspaceFacade.RemovePackageFromProject(
  const APackageName: string;
  out AChanged: Boolean; out AReason: string): Boolean;
begin
  Result := FPackages.RemovePackageFromProject(APackageName, AChanged, AReason);
end;

function TMCPWorkspaceFacade.GetLibraryPath: TArray<string>;
begin
  Result := FLibraryPath.GetLibraryPath;
end;

function TMCPWorkspaceFacade.AddToLibraryPath(const APath: string;
  out AChanged: Boolean; out AReason: string): Boolean;
begin
  Result := FLibraryPath.AddToLibraryPath(APath, AChanged, AReason);
end;

function TMCPWorkspaceFacade.ShowIDEMessage(const AText: string;
  const AUseOutput: Boolean): Boolean;
begin
  Result := FIDE.ShowIDEMessage(AText, AUseOutput);
end;

function TMCPWorkspaceFacade.ListIDEActions(
  const AFilter: string): string;
begin
  Result := FIDE.ListIDEActions(AFilter);
end;

function TMCPWorkspaceFacade.ExecuteIDEAction(const AActionName: string;
  out AReason: string): Boolean;
begin
  Result := FIDE.ExecuteIDEAction(AActionName, AReason);
end;

function TMCPWorkspaceFacade.RefreshProjectManager: Boolean;
begin
  Result := FIDE.RefreshProjectManager;
end;

function TMCPWorkspaceFacade.RunExternalTool(
  const AArgv: TArray<string>;
  out ARun: TMCPRecordExternalToolRun; out AReason: string): Boolean;
begin
  Result := FExternalTool.RunExternalTool(AArgv, ARun, AReason);
end;

function TMCPWorkspaceFacade.ListProjectResources: TArray<TMCPRecordProjectResource>;
begin
  Result := FResources.ListProjectResources;
end;

function TMCPWorkspaceFacade.AddResourceFile(const AFilePath: string;
  out AChanged: Boolean; out AReason: string): Boolean;
begin
  Result := FResources.AddResourceFile(AFilePath, AChanged, AReason);
end;

function TMCPWorkspaceFacade.ListProjectImages: TArray<string>;
begin
  Result := FResources.ListProjectImages;
end;

function TMCPWorkspaceFacade.RenameProject(const AOldName,
  ANewName: string; out AOutcome: TRenameOutcome): Boolean;
begin
  Result := FWorkspaceOps.RenameProject(AOldName, ANewName, AOutcome);
end;

function TMCPWorkspaceFacade.RenameUnit(const AUnitName,
  ANewUnitName: string; out AOutcome: TRenameOutcome): Boolean;
begin
  Result := FStructuralWrite.RenameUnit(AUnitName, ANewUnitName, AOutcome);
end;

function TMCPWorkspaceFacade.MoveUnitToFolder(const AUnitName,
  ATargetFolder: string; out AOutcome: TRenameOutcome): Boolean;
begin
  Result := FStructuralWrite.MoveUnitToFolder(AUnitName, ATargetFolder, AOutcome);
end;

end.
