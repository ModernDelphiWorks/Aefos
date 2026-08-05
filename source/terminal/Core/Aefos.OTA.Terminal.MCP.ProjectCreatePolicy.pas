unit Aefos.OTA.Terminal.MCP.ProjectCreatePolicy;

{
  Pure project-create policy seam (ESP-096, S1 / ADR-096-03/04 / BR3/BR4).

  Pure RTL — no ToolsAPI, no VCL, no disk write. Carries every OTA-free
  decision the new consumer-defined CreateNewProject tool must make before any
  IOTAModuleServices.CreateModule call happens:

    - ValidateProjectName : a project name must be a single Pascal identifier
      (the .dpr/.dpk program/package name), so no dots, separators, spaces or
      `..` traversal can leak into a filename.
    - ClassifyProjectType : maps the requested type token (vcl / fmx / console /
      package / library, case-insensitive, alias-tolerant) onto a creator spec
      (kind, OTA creator-type, source extension, framework). An unknown token
      resolves to an unsupported spec — never an exception.
    - ConfineProjectRoot  : confines the resolved project directory to a
      disposable scratch root (in-root accept, out-of-root `path-escape`),
      separator-normalised. Pure string normalisation — TPath.GetFullPath does
      not touch the disk.
    - PlanCreate          : composes validate + classify + confine + the
      no-overwrite safe-default (`target-exists` when the injected AExists
      predicate reports the .dpr or .dproj already present), returning either an
      accepted plan (the confined .dpr + .dproj target paths) or a non-partial
      refusal reason.

  File existence is injected (TProjectExistsFunc) so the plan stays deterministic
  and disk-free for unit tests — exactly as UnitCreatePolicy injects TUnitExistsFunc.

  This unit also declares the consumer-owned IProjectCreatorService contract and
  the GProjectCreatorServiceFactory wiring hook. The OTA-backed implementation
  lives in the UI tier (Aefos.OTA.Terminal.MCP.ProjectCreator) and assigns
  the factory in its initialization (linked via the dpk). The frozen Core
  IMCPWorkspaceFacade interface is never extended (BR1) — the handler binds to
  this consumer-owned service instead.
}

interface

uses
  System.SysUtils;

type
  // The five requested project kinds plus an unsupported sentinel.
  TProjectKind = (
    pkUnsupported,
    pkVCLApplication,
    pkFMXApplication,
    pkConsoleApplication,
    pkPackage,
    pkLibrary);

  // Immutable description of how a kind maps onto an OTA project creator. The
  // pure seam fills it; the OTA service reads it to drive IOTAModuleServices.
  TProjectCreatorSpec = record
    Kind: TProjectKind;
    TypeName: string;     // canonical lowercase token (vcl/fmx/console/package/library)
    CreatorType: string;  // OTA sApplication/sConsole/sPackage/sLibrary token
    Personality: string;  // OTA personality token (Delphi.Personality)
    SourceExt: string;    // generated source extension: .dpr or .dpk
    Framework: string;    // 'VCL' / 'FMX' / '' (console/package/library)
    Supported: Boolean;   // a known, classifiable kind (pkUnsupported => False)
  end;

  // Why a create was refused. Each maps onto a non-partial kebab sentinel.
  TProjectCreateRejection = (
    pcrNone,            // accepted — the plan is valid
    pcrInvalidName,     // project name rejected (not a single identifier)
    pcrUnsupportedType, // type token does not classify to a known kind
    pcrPathEscape,      // resolved target escapes the scratch root
    pcrTargetExists);   // .dpr or .dproj already present (no silent overwrite)

  // Resolved create decision. When Accepted, ProjectFilePath + DProjPath are the
  // confined absolute targets the OTA service will create; otherwise Rejection /
  // Reason explain why (Reason is the kebab sentinel surfaced as AError).
  TProjectCreatePlan = record
    ProjectName: string;               // validated bare name (no extension)
    Spec: TProjectCreatorSpec;         // classified creator spec
    ProjectDir: string;                // confined absolute directory (accepted only)
    ProjectFilePath: string;           // confined absolute .dpr/.dpk target
    DProjPath: string;                 // confined absolute .dproj target
    Rejection: TProjectCreateRejection; // pcrNone => accepted
    Reason: string;                    // kebab reason on reject; '' when accepted
    function Accepted: Boolean;
  end;

  // Outcome the OTA service returns to the tool handler.
  TProjectCreateResult = record
    Created: Boolean;     // a .dproj exists on disk after the create
    DProjPath: string;    // the on-disk .dproj path (cross-check signal, AC3)
    ProjectType: string;  // canonical type token (cross-check signal, AC3)
    ErrorReason: string;  // kebab reason on failure; '' on success
  end;

  // Consumer-owned creation service. The OTA-backed implementation lives in the
  // UI tier; the registrar binds the CreateNewProject handler to it. The frozen
  // Core IMCPWorkspaceFacade interface is never extended (BR1 / ADR-096-03).
  IProjectCreatorService = interface
    ['{F2A7C3E1-4B59-4D2A-8E61-7C0A9D3B5F84}']
    // Runs on the IDE main thread (the handler marshals before calling). Must
    // not raise across the boundary — failures degrade to ErrorReason.
    function CreateProject(const APlan: TProjectCreatePlan): TProjectCreateResult;
  end;

  // Injected existence probe — the handler passes TFile.Exists; tests a stub.
  TProjectExistsFunc = reference to function(const APath: string): Boolean;

var
  // Production wiring hook: the UI ProjectCreator unit assigns this in its
  // initialization (linked into the BPL via the dpk `contains`). The headless
  // test host leaves it nil — the descriptor still registers; only an actual
  // handler invocation without a live OTA service is refused.
  GProjectCreatorServiceFactory: TFunc<IProjectCreatorService> = nil;

type
  // Pure, disk-free decisions the CreateNewProject tool makes before any OTA
  // CreateModule call. Static namespace — never instantiated (BR3).
  TProjectCreatePolicy = class sealed
  public
    // True when AName is a single valid Pascal identifier (a project/program
    // name): starts with a letter or underscore, then letters/digits/underscores;
    // no dot, separator, space or `..`. This keeps a name from leaking a path.
    class function IsValidProjectName(const AName: string): Boolean; static;

    // Maps a requested type token (case-insensitive, alias-tolerant) onto a
    // creator spec. An unknown token returns a pkUnsupported spec (Supported = False).
    class function ClassifyProjectType(const ATypeName: string): TProjectCreatorSpec; static;

    // Confines ARequestedDir to ARoot. Empty ARequestedDir resolves to the root
    // itself. Returns pcrNone + AResolvedDir on success, or pcrPathEscape.
    class function ConfineProjectRoot(const ARoot, ARequestedDir: string;
      out AResolvedDir: string): TProjectCreateRejection; static;

    // Pure decision: validate name, classify type, confine the directory to
    // ARoot, then apply the no-overwrite safe-default. No disk I/O — existence
    // comes from AExists. ADirectory may be empty (project goes directly under ARoot).
    class function PlanCreate(const AName, ARoot, ADirectory, ATypeName: string;
      const AExists: TProjectExistsFunc): TProjectCreatePlan; static;
  end;

implementation

uses
  System.IOUtils;

const
  // The OTA personality every kind here targets — all Delphi projects.
  DELPHI_PERSONALITY = 'Delphi.Personality';

function TProjectCreatePlan.Accepted: Boolean;
begin
  Result := Rejection = pcrNone;
end;

class function TProjectCreatePolicy.IsValidProjectName(const AName: string): Boolean;
var
  LIndex: Integer;
begin
  Result := False;
  if AName = '' then
    Exit;
  if not CharInSet(AName[1], ['A'..'Z', 'a'..'z', '_']) then
    Exit;
  for LIndex := 2 to Length(AName) do
    if not CharInSet(AName[LIndex], ['A'..'Z', 'a'..'z', '0'..'9', '_']) then
      Exit;
  Result := True;
end;

// Resolves a kind to its full spec. CreatorType uses the OTA sXxx tokens, kept
// as literals here so the pure seam stays free of any ToolsAPI import (BR3).
function _SpecFor(const AKind: TProjectKind): TProjectCreatorSpec;
begin
  Result := Default(TProjectCreatorSpec);
  Result.Kind := AKind;
  Result.Personality := DELPHI_PERSONALITY;
  Result.Supported := AKind <> pkUnsupported;
  case AKind of
    pkVCLApplication:
      begin
        Result.TypeName := 'vcl';
        Result.CreatorType := 'Application';
        Result.SourceExt := '.dpr';
        Result.Framework := 'VCL';
      end;
    pkFMXApplication:
      begin
        Result.TypeName := 'fmx';
        Result.CreatorType := 'Application';
        Result.SourceExt := '.dpr';
        Result.Framework := 'FMX';
      end;
    pkConsoleApplication:
      begin
        Result.TypeName := 'console';
        Result.CreatorType := 'Console';
        Result.SourceExt := '.dpr';
      end;
    pkPackage:
      begin
        Result.TypeName := 'package';
        Result.CreatorType := 'Package';
        Result.SourceExt := '.dpk';
      end;
    pkLibrary:
      begin
        Result.TypeName := 'library';
        Result.CreatorType := 'Library';
        Result.SourceExt := '.dpr';
      end;
  else
    Result.Personality := '';
  end;
end;

// Maps an alias token to a kind. Table-driven so the lookup stays flat (low CCN)
// and new aliases are a one-line addition.
function _KindFor(const AToken: string): TProjectKind;
type
  TAlias = record Token: string; Kind: TProjectKind; end;
const
  ALIASES: array[0..13] of TAlias = (
    (Token: 'vcl';             Kind: pkVCLApplication),
    (Token: 'vclapp';          Kind: pkVCLApplication),
    (Token: 'vclapplication';  Kind: pkVCLApplication),
    (Token: 'fmx';             Kind: pkFMXApplication),
    (Token: 'firemonkey';      Kind: pkFMXApplication),
    (Token: 'fmxapp';          Kind: pkFMXApplication),
    (Token: 'console';         Kind: pkConsoleApplication),
    (Token: 'consoleapp';      Kind: pkConsoleApplication),
    (Token: 'package';         Kind: pkPackage),
    (Token: 'pkg';             Kind: pkPackage),
    (Token: 'bpl';             Kind: pkPackage),
    (Token: 'library';         Kind: pkLibrary),
    (Token: 'lib';             Kind: pkLibrary),
    (Token: 'dll';             Kind: pkLibrary));
var
  LAlias: TAlias;
begin
  for LAlias in ALIASES do
    if SameText(AToken, LAlias.Token) then
      Exit(LAlias.Kind);
  Result := pkUnsupported;
end;

class function TProjectCreatePolicy.ClassifyProjectType(const ATypeName: string): TProjectCreatorSpec;
begin
  Result := _SpecFor(_KindFor(Trim(ATypeName).Replace(' ', '', [rfReplaceAll])));
end;

// Case-insensitive containment of a normalized absolute path under a normalized
// absolute root. The trailing delimiter prevents `app` matching `app-evil`.
function _IsWithinRoot(const AFull, ARootFull: string): Boolean;
var
  LRootSlash: string;
begin
  LRootSlash := IncludeTrailingPathDelimiter(ARootFull);
  Result := AFull.StartsWith(LRootSlash, True) or
            SameText(AFull, ExcludeTrailingPathDelimiter(LRootSlash));
end;

class function TProjectCreatePolicy.ConfineProjectRoot(const ARoot, ARequestedDir: string;
  out AResolvedDir: string): TProjectCreateRejection;
var
  LRootFull, LDirFull: string;
begin
  AResolvedDir := '';
  if Trim(ARoot) = '' then
    Exit(pcrPathEscape);
  try
    LRootFull := TPath.GetFullPath(ARoot);
    if Trim(ARequestedDir) = '' then
      LDirFull := LRootFull
    else if TPath.IsPathRooted(ARequestedDir) then
      LDirFull := TPath.GetFullPath(ARequestedDir)
    else
      LDirFull := TPath.GetFullPath(TPath.Combine(LRootFull, ARequestedDir));
  except
    Exit(pcrPathEscape);
  end;
  if not _IsWithinRoot(LDirFull, LRootFull) then
    Exit(pcrPathEscape);
  AResolvedDir := LDirFull;
  Result := pcrNone;
end;

// Fills Rejection/Reason on Result and returns False so the caller can Exit.
function _Refuse(var APlan: TProjectCreatePlan;
  const ARejection: TProjectCreateRejection; const AReason: string): Boolean;
begin
  APlan.Rejection := ARejection;
  APlan.Reason := AReason;
  Result := False;
end;

class function TProjectCreatePolicy.PlanCreate(const AName, ARoot, ADirectory, ATypeName: string;
  const AExists: TProjectExistsFunc): TProjectCreatePlan;
var
  LConfine: TProjectCreateRejection;
  LDir: string;
begin
  Result := Default(TProjectCreatePlan);

  if not IsValidProjectName(AName) then
  begin
    _Refuse(Result, pcrInvalidName, 'invalid-project-name');
    Exit;
  end;
  Result.ProjectName := AName;

  Result.Spec := ClassifyProjectType(ATypeName);
  if not Result.Spec.Supported then
  begin
    _Refuse(Result, pcrUnsupportedType, 'unsupported-type');
    Exit;
  end;

  LConfine := ConfineProjectRoot(ARoot, ADirectory, LDir);
  if LConfine <> pcrNone then
  begin
    _Refuse(Result, pcrPathEscape, 'path-escape');
    Exit;
  end;
  Result.ProjectDir := LDir;
  Result.ProjectFilePath := TPath.Combine(LDir, AName + Result.Spec.SourceExt);
  Result.DProjPath := TPath.Combine(LDir, AName + '.dproj');

  // No-overwrite safe-default: refuse if either the source project file or the
  // .dproj already exists. A create tool never clobbers (ADR-096-04 / BR4).
  if Assigned(AExists) and
     (AExists(Result.ProjectFilePath) or AExists(Result.DProjPath)) then
  begin
    _Refuse(Result, pcrTargetExists, 'target-exists');
    Exit;
  end;

  Result.Rejection := pcrNone;
  Result.Reason := '';
end;

end.
