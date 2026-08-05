unit Aefos.MCP.OTA.ProjectWriteService;

{
  Project-level write operations, extracted from the TMCPWorkspaceFacade
  god-object as a focused service of the SOLID split (audit S6 / facade split).

  Owns the five project setters — version, active platform, active configuration,
  description and executable output dir — plus their option-key alternate
  constants (version/description/output-dir), which no other domain uses (the
  matching Get* reads resolve via .dproj parsing, not these keys). Shared work
  comes from already-separate units: the tier-2 getters/writer from
  Aefos.MCP.OTA.FacadeShared and ConfineConfigPath from ConfigWritePolicy.

  Bodies moved VERBATIM from the facade (only the class qualifier changes), so
  behaviour is identical. The facade keeps its frozen IMCPWorkspaceFacade methods
  and delegates each to a refcounted FProjectWrite field.
}

interface

type
  IMCPProjectWriteService = interface
    ['{4B8D2F61-9C73-4A05-8E29-7F3C1A6D5B84}']
    function SetProjectVersion(const AMajor, AMinor,
      ARelease, ABuild: Integer): Boolean;
    function SetActiveProjectPlatform(const APlatformName: string): Boolean;
    function SetActiveConfiguration(const AConfigName: string): Boolean;
    function SetProjectDescription(const ADescription: string): Boolean;
    function SetProjectOutputDir(const ADir: string): Boolean;
  end;

// Factory — the facade calls this once in its constructor.
function NewMCPProjectWriteService: IMCPProjectWriteService;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  ToolsAPI,
  Aefos.MCP.OTA.FacadeShared,
  Aefos.MCP.OTA.ConfigWritePolicy;

// Alternate project-option key names probed against IOTAProjectOptions
// (first exposed name wins). Read-only — extend, never replace.
const
  // Executable output dir + description (single canonical name, Epic-1 reads).
  COutputDirKeys: array[0..0] of string = ('OutputDir');
  CDescriptionKeys: array[0..1] of string = ('Description', 'VerInfo_Description');
  // VersionInfo field keys (modern .dproj VerInfo_* first, legacy names after).
  CVerMajorKeys: array[0..1] of string = ('VerInfo_MajorVer', 'MajorVersion');
  CVerMinorKeys: array[0..1] of string = ('VerInfo_MinorVer', 'MinorVersion');
  CVerReleaseKeys: array[0..1] of string = ('VerInfo_Release', 'Release');
  CVerBuildKeys: array[0..1] of string = ('VerInfo_Build', 'Build');

type
  TMCPProjectWriteService = class(TInterfacedObject, IMCPProjectWriteService)
  public
    function SetProjectVersion(const AMajor, AMinor,
      ARelease, ABuild: Integer): Boolean;
    function SetActiveProjectPlatform(const APlatformName: string): Boolean;
    function SetActiveConfiguration(const AConfigName: string): Boolean;
    function SetProjectDescription(const ADescription: string): Boolean;
    function SetProjectOutputDir(const ADir: string): Boolean;
  end;

function TMCPProjectWriteService.SetProjectVersion(const AMajor, AMinor,
  ARelease, ABuild: Integer): Boolean;
var
  LResult: Boolean;
begin
  LResult := False;
  try
    TThread.Synchronize(nil, procedure
    var
      LOptions: IOTAProjectOptions;
      LWrote: Boolean;
    begin
      if not TFacadeShared.TryProjectOptions(LOptions) then Exit;
      LWrote := TFacadeShared.WriteOptionString(LOptions,
        TFacadeShared.ResolveOrDefaultKey(LOptions, CVerMajorKeys), IntToStr(AMajor));
      LWrote := TFacadeShared.WriteOptionString(LOptions,
        TFacadeShared.ResolveOrDefaultKey(LOptions, CVerMinorKeys), IntToStr(AMinor)) or LWrote;
      LWrote := TFacadeShared.WriteOptionString(LOptions,
        TFacadeShared.ResolveOrDefaultKey(LOptions, CVerReleaseKeys), IntToStr(ARelease)) or LWrote;
      LWrote := TFacadeShared.WriteOptionString(LOptions,
        TFacadeShared.ResolveOrDefaultKey(LOptions, CVerBuildKeys), IntToStr(ABuild)) or LWrote;
      LResult := LWrote;
    end);
  except
    LResult := False;
  end;
  Result := LResult;
end;

// Select the named target platform (IOTAProject.CurrentPlatform, ESP-089). The
// in-process re-read guards against a silent no-op (a write that returns without
// the platform changing is a FAIL, ADR-089-03); the live follow-up read
// GetActiveProjectPlatform is the acceptance evidence (ADR-089-06).
function TMCPProjectWriteService.SetActiveProjectPlatform(
  const APlatformName: string): Boolean;
var
  LResult: Boolean;
begin
  LResult := False;
  try
    TThread.Synchronize(nil, procedure
    var
      LProject: IOTAProject;
    begin
      if not TFacadeShared.TryProject(LProject) then Exit;
      if Trim(APlatformName) = '' then Exit;
      LProject.CurrentPlatform := APlatformName;
      LResult := SameText(LProject.CurrentPlatform, APlatformName);
    end);
  except
    LResult := False;
  end;
  Result := LResult;
end;

// Select the named build configuration (IOTAProject.CurrentConfiguration,
// ESP-089), guarded by an in-process re-read; GetActiveConfiguration is the live
// acceptance read.
function TMCPProjectWriteService.SetActiveConfiguration(
  const AConfigName: string): Boolean;
var
  LResult: Boolean;
begin
  LResult := False;
  try
    TThread.Synchronize(nil, procedure
    var
      LProject: IOTAProject;
    begin
      if not TFacadeShared.TryProject(LProject) then Exit;
      if Trim(AConfigName) = '' then Exit;
      LProject.CurrentConfiguration := AConfigName;
      LResult := SameText(LProject.CurrentConfiguration, AConfigName);
    end);
  except
    LResult := False;
  end;
  Result := LResult;
end;

// Best-effort project description write (ESP-089, S2). Like SetProjectVersion the
// matching read GetProjectDescription has no OTA accessor (upstream ask #6), so
// it is dispositioned as a documented CAVEAT (ADR-089-03). Scratch-scoped.
function TMCPProjectWriteService.SetProjectDescription(
  const ADescription: string): Boolean;
var
  LResult: Boolean;
begin
  LResult := False;
  try
    TThread.Synchronize(nil, procedure
    var
      LOptions: IOTAProjectOptions;
    begin
      if not TFacadeShared.TryProjectOptions(LOptions) then Exit;
      LResult := TFacadeShared.WriteOptionString(LOptions,
        TFacadeShared.ResolveOrDefaultKey(LOptions, CDescriptionKeys), ADescription);
    end);
  except
    LResult := False;
  end;
  Result := LResult;
end;

// Set the executable output directory (ESP-089). Path-bearing → confined to the
// scratch-project root (ConfineConfigPath, ADR-089-07 / BR10): an out-of-root
// target is refused with no write. GetProjectOutputDir is the live acceptance
// read.
function TMCPProjectWriteService.SetProjectOutputDir(
  const ADir: string): Boolean;
var
  LResult: Boolean;
begin
  LResult := False;
  try
    TThread.Synchronize(nil, procedure
    var
      LProject: IOTAProject;
      LOptions: IOTAProjectOptions;
      LRoot, LFull, LReason: string;
    begin
      if not TFacadeShared.TryProject(LProject) then Exit;
      LRoot := TPath.GetDirectoryName(LProject.FileName);
      if not TConfigWritePolicy.ConfineConfigPath(ADir, LRoot, LFull, LReason) then Exit;
      LOptions := LProject.ProjectOptions;
      if not Assigned(LOptions) then Exit;
      LResult := TFacadeShared.WriteOptionString(LOptions,
        TFacadeShared.ResolveOrDefaultKey(LOptions, COutputDirKeys), LFull);
    end);
  except
    LResult := False;
  end;
  Result := LResult;
end;

function NewMCPProjectWriteService: IMCPProjectWriteService;
begin
  Result := TMCPProjectWriteService.Create;
end;

end.
