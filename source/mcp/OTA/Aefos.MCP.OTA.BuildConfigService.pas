unit Aefos.MCP.OTA.BuildConfigService;

{
  Project build-configuration operations, extracted from the TMCPWorkspaceFacade
  god-object as a focused service of the SOLID split (audit S6 / facade split).

  Owns the search-path, conditional-defines and DCU-output-dir getters/setters
  (nine methods), plus the BuildConfig-specific option-key alternate constants.
  All shared work is drawn from already-separate units:
    - FacadeShared (tier-2 getters): TryProject, TryProjectOptions,
      ResolveOptionKey, ReadOptionString, ResolveOrDefaultKey, WriteOptionString
    - ConfigWritePolicy: ParseOptionList, ConfineConfigPath, NormalizeOptionList,
      AppendRawEntry, RemoveOptionEntry
    - DProjParser: ParseDcuOutputDir

  Bodies moved VERBATIM from the facade (only the class qualifier changes), so
  behaviour is identical. The facade keeps its frozen IMCPWorkspaceFacade methods
  and delegates each to a refcounted FBuildConfig field.
}

interface

type
  IMCPBuildConfigService = interface
    ['{7E4A1C92-8D63-4B05-9F27-3A6C1E8B4D70}']
    function GetSearchPath: TArray<string>;
    function SetSearchPath(const APaths: TArray<string>): Boolean;
    function AddToSearchPath(const APath: string): Boolean;
    function GetConditionalDefines: TArray<string>;
    function SetConditionalDefines(const ADefines: TArray<string>): Boolean;
    function AddConditionalDefine(const ADefine: string): Boolean;
    function RemoveConditionalDefine(const ADefine: string): Boolean;
    function GetDCUOutputDir: string;
    function SetDCUOutputDir(const ADir: string): Boolean;
  end;

// Factory — the facade calls this once in its constructor.
function NewMCPBuildConfigService: IMCPBuildConfigService;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.Variants,
  System.IOUtils,
  ToolsAPI,
  Aefos.MCP.OTA.FacadeShared,
  Aefos.MCP.OTA.ConfigWritePolicy,
  Aefos.MCP.OTA.DProjParser;

// Alternate project-option key names probed against IOTAProjectOptions
// (first exposed name wins). Read-only — extend, never replace.
const
  CSearchPathKeys: array[0..2] of string =
    ('SrcDir', 'UnitSearchPath', 'DCC_UnitSearchPath');
  CDefinesKeys: array[0..2] of string =
    ('Defines', 'DCC_Define', 'ConditionalDefines');
  CDCUOutputKeys: array[0..2] of string =
    ('DcuOutput', 'DCC_DcuOutput', 'DCC_UnitOutputDir');

type
  TMCPBuildConfigService = class(TInterfacedObject, IMCPBuildConfigService)
  public
    function GetSearchPath: TArray<string>;
    function SetSearchPath(const APaths: TArray<string>): Boolean;
    function AddToSearchPath(const APath: string): Boolean;
    function GetConditionalDefines: TArray<string>;
    function SetConditionalDefines(const ADefines: TArray<string>): Boolean;
    function AddConditionalDefine(const ADefine: string): Boolean;
    function RemoveConditionalDefine(const ADefine: string): Boolean;
    function GetDCUOutputDir: string;
    function SetDCUOutputDir(const ADir: string): Boolean;
  end;

function TMCPBuildConfigService.GetSearchPath: TArray<string>;
var
  LResult: TArray<string>;
begin
  LResult := [];
  try
    TThread.Synchronize(nil, procedure
    var
      LOptions: IOTAProjectOptions;
      LKey: string;
    begin
      if not TFacadeShared.TryProjectOptions(LOptions) then Exit;
      LKey := TFacadeShared.ResolveOptionKey(LOptions, CSearchPathKeys);
      if LKey = '' then Exit;
      LResult := TConfigWritePolicy.ParseOptionList(TFacadeShared.ReadOptionString(LOptions, LKey));
    end);
  except
    LResult := [];
  end;
  Result := LResult;
end;

// Replace the project search path with APaths (ESP-089). Path-bearing → every
// entry confined to the scratch-project root (ADR-089-07 / BR10): a single
// out-of-root entry refuses the whole op (non-partial, R6). The confined
// absolutes are deduped (NormalizeOptionList, R1) before the write;
// GetSearchPath is the live acceptance read.
function TMCPBuildConfigService.SetSearchPath(
  const APaths: TArray<string>): Boolean;
var
  LResult: Boolean;
  LSrcPaths: TArray<string>;
begin
  LResult   := False;
  LSrcPaths := APaths; // capture a local copy (anonymous methods capture locals)
  try
    TThread.Synchronize(nil, procedure
    var
      LProject: IOTAProject;
      LOptions: IOTAProjectOptions;
      LRoot, LFull, LReason, LNew: string;
      LConfined: TArray<string>;
      LFor: Integer;
    begin
      if not TFacadeShared.TryProject(LProject) then Exit;
      LRoot := TPath.GetDirectoryName(LProject.FileName);
      SetLength(LConfined, Length(LSrcPaths));
      for LFor := 0 to High(LSrcPaths) do
      begin
        if not TConfigWritePolicy.ConfineConfigPath(LSrcPaths[LFor], LRoot, LFull, LReason) then Exit;
        LConfined[LFor] := LFull;
      end;
      LOptions := LProject.ProjectOptions;
      if not Assigned(LOptions) then Exit;
      TConfigWritePolicy.NormalizeOptionList(LConfined, LNew);
      LResult := TFacadeShared.WriteOptionString(LOptions,
        TFacadeShared.ResolveOrDefaultKey(LOptions, CSearchPathKeys), LNew);
    end);
  except
    LResult := False;
  end;
  Result := LResult;
end;

// Append one entry to the project search path (ESP-089). Path-bearing → confined
// to the scratch root; the confined absolute is merged into the existing raw
// value WITHOUT dropping or duplicating any entry (AppendRawEntry, R1) — an
// already-present path is a valid no-op. GetSearchPath is the live acceptance
// read.
function TMCPBuildConfigService.AddToSearchPath(
  const APath: string): Boolean;
var
  LResult: Boolean;
begin
  LResult := False;
  try
    TThread.Synchronize(nil, procedure
    var
      LProject: IOTAProject;
      LOptions: IOTAProjectOptions;
      LRoot, LFull, LReason, LKey, LRaw, LNew: string;
      LChanged: Boolean;
    begin
      if not TFacadeShared.TryProject(LProject) then Exit;
      LRoot := TPath.GetDirectoryName(LProject.FileName);
      if not TConfigWritePolicy.ConfineConfigPath(APath, LRoot, LFull, LReason) then Exit;
      LOptions := LProject.ProjectOptions;
      if not Assigned(LOptions) then Exit;
      LKey := TFacadeShared.ResolveOrDefaultKey(LOptions, CSearchPathKeys);
      LRaw := TFacadeShared.ReadOptionString(LOptions, LKey);
      if not TConfigWritePolicy.AppendRawEntry(LRaw, LFull, LNew, LChanged) then Exit;
      if LChanged then
        LResult := TFacadeShared.WriteOptionString(LOptions, LKey, LNew)
      else
        LResult := True; // already present — valid no-op
    end);
  except
    LResult := False;
  end;
  Result := LResult;
end;

function TMCPBuildConfigService.GetConditionalDefines: TArray<string>;
var
  LResult: TArray<string>;
begin
  LResult := [];
  try
    TThread.Synchronize(nil, procedure
    var
      LOptions: IOTAProjectOptions;
      LKey: string;
    begin
      if not TFacadeShared.TryProjectOptions(LOptions) then Exit;
      LKey := TFacadeShared.ResolveOptionKey(LOptions, CDefinesKeys);
      if LKey = '' then Exit;
      LResult := TConfigWritePolicy.ParseOptionList(TFacadeShared.ReadOptionString(LOptions, LKey));
    end);
  except
    LResult := [];
  end;
  Result := LResult;
end;

// Replace the project conditional defines with ADefines (ESP-089). Defines are
// not paths (no confinement); the list is deduped case-insensitively, order
// preserved (NormalizeOptionList, R1), then written. GetConditionalDefines is
// the live acceptance read.
function TMCPBuildConfigService.SetConditionalDefines(
  const ADefines: TArray<string>): Boolean;
var
  LResult: Boolean;
  LSrcDefines: TArray<string>;
begin
  LResult     := False;
  LSrcDefines := ADefines; // capture a local copy (closures capture locals)
  try
    TThread.Synchronize(nil, procedure
    var
      LOptions: IOTAProjectOptions;
      LNew: string;
    begin
      if not TFacadeShared.TryProjectOptions(LOptions) then Exit;
      TConfigWritePolicy.NormalizeOptionList(LSrcDefines, LNew);
      LResult := TFacadeShared.WriteOptionString(LOptions,
        TFacadeShared.ResolveOrDefaultKey(LOptions, CDefinesKeys), LNew);
    end);
  except
    LResult := False;
  end;
  Result := LResult;
end;

// Append one conditional define (ESP-089). Read-modify-write that never drops or
// duplicates an existing define (AppendRawEntry, R1) — an already-present define
// is a valid no-op. GetConditionalDefines is the live acceptance read.
function TMCPBuildConfigService.AddConditionalDefine(
  const ADefine: string): Boolean;
var
  LResult: Boolean;
begin
  LResult := False;
  try
    TThread.Synchronize(nil, procedure
    var
      LOptions: IOTAProjectOptions;
      LKey, LRaw, LNew: string;
      LChanged: Boolean;
    begin
      if not TFacadeShared.TryProjectOptions(LOptions) then Exit;
      LKey := TFacadeShared.ResolveOrDefaultKey(LOptions, CDefinesKeys);
      LRaw := TFacadeShared.ReadOptionString(LOptions, LKey);
      if not TConfigWritePolicy.AppendRawEntry(LRaw, ADefine, LNew, LChanged) then Exit;
      if LChanged then
        LResult := TFacadeShared.WriteOptionString(LOptions, LKey, LNew)
      else
        LResult := True; // already present — valid no-op
    end);
  except
    LResult := False;
  end;
  Result := LResult;
end;

// Remove one conditional define (ESP-089). Idempotent — an absent define is a
// valid no-op (RemoveOptionEntry, R1). GetConditionalDefines is the live read.
function TMCPBuildConfigService.RemoveConditionalDefine(
  const ADefine: string): Boolean;
var
  LResult: Boolean;
begin
  LResult := False;
  try
    TThread.Synchronize(nil, procedure
    var
      LOptions: IOTAProjectOptions;
      LKey, LRaw, LNew: string;
      LChanged: Boolean;
    begin
      if not TFacadeShared.TryProjectOptions(LOptions) then Exit;
      LKey := TFacadeShared.ResolveOrDefaultKey(LOptions, CDefinesKeys);
      LRaw := TFacadeShared.ReadOptionString(LOptions, LKey);
      if not TConfigWritePolicy.RemoveOptionEntry(LRaw, ADefine, LNew, LChanged) then Exit;
      if LChanged then
        LResult := TFacadeShared.WriteOptionString(LOptions, LKey, LNew)
      else
        LResult := True; // absent — valid idempotent no-op
    end);
  except
    LResult := False;
  end;
  Result := LResult;
end;

// Read the DCU output directory via the resolved key first, then fall back to
// direct Values[key] access for projects where CDCUOutputKeys don't appear in
// GetOptionNames (platform-level storage pattern, ESP-089 / SetDCUOutputDir
// read-back fix). Mirrors GetProjectOutputDir's direct-access pattern.
function TMCPBuildConfigService.GetDCUOutputDir: string;
var
  LResult, LDProjPath, LConfig: string;
begin
  LResult := '';
  LDProjPath := '';
  LConfig := '';
  try
    TThread.Synchronize(nil, procedure
    var
      LProject: IOTAProject;
      LConfigs: IOTAProjectOptionsConfigurations;
      LOptions: IOTAProjectOptions;
      LKey, LDirect: string;
      LFor: Integer;
    begin
      // Capture the .dproj path + active config for the ESP-092 parse fallback.
      if TFacadeShared.TryProject(LProject) then
      begin
        LDProjPath := LProject.FileName;
        if Supports(LProject.ProjectOptions, IOTAProjectOptionsConfigurations, LConfigs) then
          LConfig := LConfigs.ActiveConfigurationName;
      end;
      if not TFacadeShared.TryProjectOptions(LOptions) then Exit;
      LKey := TFacadeShared.ResolveOptionKey(LOptions, CDCUOutputKeys);
      if LKey <> '' then
      begin
        LResult := TFacadeShared.ReadOptionString(LOptions, LKey);
        Exit;
      end;
      // Fallback: try direct Values[key] access bypassing GetOptionNames (covers
      // projects where the key is not in the enumerated names but IS readable).
      for LFor := Low(CDCUOutputKeys) to High(CDCUOutputKeys) do
      begin
        try
          LDirect := VarToStr(LOptions.Values[CDCUOutputKeys[LFor]]);
        except
          LDirect := '';
        end;
        if LDirect <> '' then
        begin
          LResult := LDirect;
          Exit;
        end;
      end;
    end);
  except
    LResult := '';
  end;
  // Final fallback (ESP-092): the option dictionary missed the key entirely —
  // parse <DCC_DcuOutput> straight from the .dproj XML, config-scoped. Projects
  // whose option key IS exposed are unaffected (returned above before this runs).
  if (LResult = '') and (LDProjPath <> '') and TFile.Exists(LDProjPath) then
  begin
    try
      LResult := TDProjParser.ParseDcuOutputDir(TFile.ReadAllText(LDProjPath), LConfig);
    except
      LResult := '';
    end;
  end;
  Result := LResult;
end;

// Set the DCU output directory (ESP-089). Path-bearing → confined to the
// scratch-project root (ADR-089-07 / BR10); an out-of-root target is refused
// with no write. Uses direct Values[key] write + immediate read-back
// verification so that projects whose GetOptionNames omits the DCU key still
// get a confirmed write (same pattern as GetProjectOutputDir / 'OutputDir').
// GetDCUOutputDir is the live acceptance read.
function TMCPBuildConfigService.SetDCUOutputDir(
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
      LRoot, LFull, LReason, LKey, LVerify: string;
    begin
      if not TFacadeShared.TryProject(LProject) then Exit;
      LRoot := TPath.GetDirectoryName(LProject.FileName);
      if not TConfigWritePolicy.ConfineConfigPath(ADir, LRoot, LFull, LReason) then Exit;
      LOptions := LProject.ProjectOptions;
      if not Assigned(LOptions) then Exit;
      // Resolve key or fall back to the canonical first alternate ('DcuOutput'),
      // then write and verify with an immediate direct read-back on the SAME key
      // so silent no-ops are caught before returning True (R1).
      LKey := TFacadeShared.ResolveOrDefaultKey(LOptions, CDCUOutputKeys);
      if not TFacadeShared.WriteOptionString(LOptions, LKey, LFull) then Exit;
      try
        LVerify := VarToStr(LOptions.Values[LKey]);
      except
        LVerify := '';
      end;
      LResult := SameText(LVerify, LFull);
    end);
  except
    LResult := False;
  end;
  Result := LResult;
end;

function NewMCPBuildConfigService: IMCPBuildConfigService;
begin
  Result := TMCPBuildConfigService.Create;
end;

end.
