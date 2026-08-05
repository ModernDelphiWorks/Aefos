unit Aefos.MCP.OTA.DprService;

{
  .dpr / main-form domain, extracted from the TMCPWorkspaceFacade god-object as a
  focused service of the SOLID split (audit S6 / facade split).

  Owns the project source-file reads + the honest OTA-limited mutation sentinels:
    - GetDPRContent      reads the live .dpr buffer
    - GetDPRUsedForms    parses every Application.CreateForm call (DPRParser)
    - GetMainForm        the first CreateForm class, else the first project form
    - SetDPRContent / RenameDPR / SetMainForm — sentinels: ToolsAPI exposes no safe
      open-project .dpr/identity/main-form rewrite, so these refuse with a kebab
      reason rather than desync the live IOTAProject (ADR-090-03 / BR10).

  GetMainForm's fallback needs the project form list, which lives in the already-
  extracted form-designer service, so IMCPFormDesignerService is INJECTED via the
  constructor (the facade hands it its own FFormDesigner). The other deps come from
  FacadeShared (FirstSourceEditor / ReadBytes / TryProject), the DPRParser seam
  (EnumerateCreateFormCalls), and the UnitCreatePolicy / StructuralWritePolicy seams
  (RenameDPR's name validation + root confinement). No FAudit.

  Bodies moved VERBATIM (only the class qualifier changes; the self-calls
  GetDPRUsedForms/GetMainForm -> GetDPRContent stay internal, and GetMainForm's
  ListProjectForms -> FFormDesigner.ListProjectForms). The facade delegates the six
  frozen methods to a refcounted FDpr field.
}

interface

uses
  Aefos.MCP.Types,
  Aefos.MCP.OTA.FormDesignerService;

type
  IMCPDprService = interface
    ['{7A2C1E94-6D83-4B50-9F38-3C6A1B5E8D40}']
    function GetDPRContent: string;
    function SetDPRContent(const ASource: string; out AReason: string): Boolean;
    function RenameDPR(const ANewName: string; out AReason: string): Boolean;
    function GetDPRUsedForms: TArray<TMCPRecordDPRCreateForm>;
    function GetMainForm: string;
    function SetMainForm(const AFormClass: string;
      out AChanged: Boolean; out AReason: string): Boolean;
  end;

// Factory — the facade calls this once in its constructor, injecting the
// form-designer service it owns (for GetMainForm's project-form fallback).
function NewMCPDprService(
  const AFormDesigner: IMCPFormDesignerService): IMCPDprService;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  ToolsAPI,
  Aefos.MCP.DPRParser,
  Aefos.MCP.OTA.FacadeShared,
  Aefos.MCP.OTA.UnitCreatePolicy,
  Aefos.MCP.OTA.StructuralWritePolicy;

type
  TMCPDprService = class(TInterfacedObject, IMCPDprService)
  private
    FFormDesigner: IMCPFormDesignerService;
  public
    constructor Create(const AFormDesigner: IMCPFormDesignerService);
    function GetDPRContent: string;
    function SetDPRContent(const ASource: string; out AReason: string): Boolean;
    function RenameDPR(const ANewName: string; out AReason: string): Boolean;
    function GetDPRUsedForms: TArray<TMCPRecordDPRCreateForm>;
    function GetMainForm: string;
    function SetMainForm(const AFormClass: string;
      out AChanged: Boolean; out AReason: string): Boolean;
  end;

constructor TMCPDprService.Create(
  const AFormDesigner: IMCPFormDesignerService);
begin
  inherited Create;
  FFormDesigner := AFormDesigner;
end;

function TMCPDprService.GetDPRContent: string;
var
  LContent: string;
begin
  // Was a stub (always ''). Now reads the active project's .dpr source from the
  // project module's source editor (live buffer) on the OTA main thread. '' only
  // when no project is open or it has no source editor.
  LContent := '';
  try
    TThread.Synchronize(nil, procedure
    var
      LMS: IOTAModuleServices;
      LProject: IOTAProject;
      LSource: IOTASourceEditor;
    begin
      try
        if not Supports(BorlandIDEServices, IOTAModuleServices, LMS) then
          Exit;
        LProject := LMS.GetActiveProject;
        if not Assigned(LProject) then
          Exit;
        LSource := TFacadeShared.FirstSourceEditor(LProject);
        if Assigned(LSource) then
          LContent := TFacadeShared.ReadBytes(LSource.CreateReader);
      except
        LContent := '';
      end;
    end);
  except
    LContent := '';
  end;
  Result := LContent;
end;

// Replace the open project's `.dpr` source (ESP-090). Honest OTA-limited
// sentinel: rewriting the live project's identity/source file desyncs the
// in-memory IOTAProject (the RenameDPR / RenameProject D5 class of risk,
// ADR-090-03), and ToolsAPI exposes no safe open-project `.dpr` source-buffer
// rewrite; disk-rewriting the open project's `.dpr` is explicitly forbidden
// (BR10). Dispositioned as an OTA gap (consumer-contract upstream ask, BR1),
// never disk-rewritten and never forced into Core — a documented CAVEAT.
function TMCPDprService.SetDPRContent(const ASource: string;
  out AReason: string): Boolean;
begin
  AReason := 'ota-no-open-project-dpr-rewrite';
  Result  := False;
end;

// Rename the active project's .dpr. Confines the proposed name to the project
// root (ADR-088-07) first — an out-of-root name is refused outright. The
// mutation itself is an honest OTA-limited sentinel: ToolsAPI has no
// rename-project primitive, and disk-renaming the *open* project's identity
// files desyncs the live IOTAProject and risks an unopenable project (R4), so
// it is dispositioned as an OTA gap (consumer-contract upstream ask), never
// forced into Core (BR1 / ADR-088-03) — the group-mutation class of CAVEAT.
function TMCPDprService.RenameDPR(const ANewName: string;
  out AReason: string): Boolean;
var
  LReason: string;
begin
  LReason := 'ota-no-open-project-rename';
  try
    TThread.Synchronize(nil, procedure
    var
      LProject: IOTAProject;
      LRoot, LBase, LFull, LConfReason: string;
    begin
      if not TFacadeShared.TryProject(LProject) then
      begin
        LReason := 'no-active-project';
        Exit;
      end;
      LRoot := TPath.GetDirectoryName(LProject.FileName);
      LBase := TPath.GetFileNameWithoutExtension(ANewName);
      if not TUnitCreatePolicy.IsValidUnitName(LBase) then
      begin
        LReason := 'invalid-name';
        Exit;
      end;
      if not TStructuralWritePolicy.ConfineStructuralTarget(LBase + '.dpr', LRoot, LFull, LConfReason) then
      begin
        LReason := LConfReason;
        Exit;
      end;
      LReason := 'ota-no-open-project-rename';
    end);
  except
    on E: Exception do
      LReason := E.Message;
  end;
  AReason := LReason;
  Result  := False;
end;

function TMCPDprService.GetDPRUsedForms: TArray<TMCPRecordDPRCreateForm>;
var
  LCalls: TArray<TDPRCreateFormCall>;
  LFor: Integer;
begin
  // Was a stub (always []). Now parses the live .dpr (GetDPRContent) for every
  // Application.CreateForm call via the shared DPRParser. [] only when no project
  // is open or the .dpr has no CreateForm calls.
  LCalls := EnumerateCreateFormCalls(GetDPRContent);
  SetLength(Result, Length(LCalls));
  for LFor := 0 to High(LCalls) do
  begin
    Result[LFor].FormVar := LCalls[LFor].FormVar;
    Result[LFor].FormClass := LCalls[LFor].FormClass;
    Result[LFor].UnitName := LCalls[LFor].UnitName;
  end;
end;

function TMCPDprService.GetMainForm: string;
var
  LCalls: TArray<TDPRCreateFormCall>;
  LForms: TArray<TMCPRecordProjectForm>;
begin
  // Was a stub (always ''). The main form is the FIRST Application.CreateForm
  // (position 0 — what the project shows on run). When the .dpr carries no
  // CreateForm line yet (e.g. a freshly generated project before the form is
  // wired, or one whose .dpr was hand-trimmed), fall back to the project's
  // first form module — the same source ListProjectForms trusts — so this
  // returns the form name instead of empty. NOTE the primary path returns the
  // form CLASS (e.g. TMainForm); the fallback returns the unit/form NAME (e.g.
  // MainForm). '' only when there is no project and no form at all.
  Result := '';
  LCalls := EnumerateCreateFormCalls(GetDPRContent);
  if Length(LCalls) > 0 then
    Exit(LCalls[0].FormClass);
  LForms := FFormDesigner.ListProjectForms;
  if Length(LForms) > 0 then
    Result := LForms[0].Name;
end;

// Select the project's main form (ESP-090). Honest OTA-limited sentinel: the
// main-form selection lives in the open project's `.dpr` (the Application
// .CreateForm order), and ToolsAPI exposes no open-project main-form setter;
// rewriting the live `.dpr` to reorder it desyncs the in-memory IOTAProject (the
// SetDPRContent / RenameProject class of risk, ADR-090-03). Dispositioned as an
// OTA gap (consumer-contract upstream ask, BR1), never disk-rewritten — a
// documented CAVEAT.
function TMCPDprService.SetMainForm(const AFormClass: string;
  out AChanged: Boolean; out AReason: string): Boolean;
begin
  AChanged := False;
  AReason  := 'ota-no-open-project-mainform';
  Result   := False;
end;

function NewMCPDprService(
  const AFormDesigner: IMCPFormDesignerService): IMCPDprService;
begin
  Result := TMCPDprService.Create(AFormDesigner);
end;

end.
