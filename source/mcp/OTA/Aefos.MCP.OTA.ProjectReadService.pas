unit Aefos.MCP.OTA.ProjectReadService;

{
  Project-level read operations, extracted from the TMCPWorkspaceFacade god-object
  as a focused service of the SOLID split (audit S6 / facade split).

  Owns the project getters — active-project info, name, path, file path, type,
  platforms, active platform, configurations, active configuration, output dir,
  and the .dproj-parsed version / GUID / description. All shared work comes from
  already-separate units: TryProject + ReadActiveDProjXml from
  Aefos.MCP.OTA.FacadeShared and ParseProjectVersion / ParseProjectGuid /
  ParseProjectDescription from DProjParser. No facade-private helper or constant
  is needed.

  Bodies moved VERBATIM from the facade (only the class qualifier changes), so
  behaviour is identical. The facade keeps its frozen IMCPWorkspaceFacade methods
  and delegates each to a refcounted FProjectRead field.
}

interface

uses
  Aefos.MCP.Types;

type
  IMCPProjectReadService = interface
    ['{9D6C3E18-4A75-4B20-8F39-2C7E1B5A6D84}']
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
    function GetProjectVersion: string;
    function GetProjectGUID: string;
    function GetProjectDescription: string;
  end;

// Factory — the facade calls this once in its constructor.
function NewMCPProjectReadService: IMCPProjectReadService;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.Variants,
  System.IOUtils,
  ToolsAPI,
  Aefos.MCP.OTA.FacadeShared,
  Aefos.MCP.OTA.DProjParser;

type
  TMCPProjectReadService = class(TInterfacedObject, IMCPProjectReadService)
  public
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
    function GetProjectVersion: string;
    function GetProjectGUID: string;
    function GetProjectDescription: string;
  end;

function TMCPProjectReadService.GetActiveProject: TMCPActiveProjectInfo;
var
  LResult: TMCPActiveProjectInfo;
begin
  LResult := Default(TMCPActiveProjectInfo);
  try
    TThread.Synchronize(nil, procedure
    var
      LProject: IOTAProject;
    begin
      if not TFacadeShared.TryProject(LProject) then Exit;
      LResult.Name           := TPath.GetFileNameWithoutExtension(LProject.FileName);
      LResult.Path           := TPath.GetDirectoryName(LProject.FileName);
      LResult.TargetPlatform := LProject.CurrentPlatform;
      LResult.Available      := True;
    end);
  except
    LResult := Default(TMCPActiveProjectInfo);
  end;
  Result := LResult;
end;

function TMCPProjectReadService.GetProjectName: string;
var
  LResult: string;
begin
  LResult := '';
  try
    TThread.Synchronize(nil, procedure
    var
      LProject: IOTAProject;
    begin
      if TFacadeShared.TryProject(LProject) then
        LResult := TPath.GetFileNameWithoutExtension(LProject.FileName);
    end);
  except
    LResult := '';
  end;
  Result := LResult;
end;

function TMCPProjectReadService.GetProjectPath: string;
var
  LResult: string;
begin
  LResult := '';
  try
    TThread.Synchronize(nil, procedure
    var
      LProject: IOTAProject;
    begin
      if TFacadeShared.TryProject(LProject) then
        LResult := TPath.GetDirectoryName(LProject.FileName);
    end);
  except
    LResult := '';
  end;
  Result := LResult;
end;

function TMCPProjectReadService.GetProjectFilePath: string;
var
  LResult: string;
begin
  LResult := '';
  try
    TThread.Synchronize(nil, procedure
    var
      LProject: IOTAProject;
    begin
      if TFacadeShared.TryProject(LProject) then
        LResult := LProject.FileName;
    end);
  except
    LResult := '';
  end;
  Result := LResult;
end;

function TMCPProjectReadService.GetProjectType: string;
var
  LResult: string;
begin
  LResult := '';
  try
    TThread.Synchronize(nil, procedure
    var
      LProject: IOTAProject;
      LAppType: string;
    begin
      if not TFacadeShared.TryProject(LProject) then Exit;
      try
        LAppType := LProject.ApplicationType;
        if LAppType <> '' then
          LResult := LAppType
        else
          LResult := LProject.Personality;
      except
        LResult := LProject.Personality;
      end;
    end);
  except
    LResult := '';
  end;
  Result := LResult;
end;

function TMCPProjectReadService.GetProjectPlatforms: TArray<string>;
var
  LResult: TArray<string>;
begin
  LResult := [];
  try
    TThread.Synchronize(nil, procedure
    var
      LProject: IOTAProject;
    begin
      if TFacadeShared.TryProject(LProject) then
      begin
        try
          LResult := LProject.SupportedPlatforms;
        except
          LResult := [];
        end;
      end;
    end);
  except
    LResult := [];
  end;
  Result := LResult;
end;

function TMCPProjectReadService.GetActiveProjectPlatform: string;
var
  LResult: string;
begin
  LResult := '';
  try
    TThread.Synchronize(nil, procedure
    var
      LProject: IOTAProject;
    begin
      if TFacadeShared.TryProject(LProject) then
        LResult := LProject.CurrentPlatform;
    end);
  except
    LResult := '';
  end;
  Result := LResult;
end;

function TMCPProjectReadService.GetProjectConfigurations: TArray<string>;
var
  LResult: TArray<string>;
begin
  LResult := [];
  try
    TThread.Synchronize(nil, procedure
    var
      LProject: IOTAProject;
      LOptions: IOTAProjectOptions;
      LConfigs: IOTAProjectOptionsConfigurations;
      LIndex: Integer;
    begin
      if not TFacadeShared.TryProject(LProject) then Exit;
      LOptions := LProject.ProjectOptions;
      if not Assigned(LOptions) then Exit;
      if not Supports(LOptions, IOTAProjectOptionsConfigurations, LConfigs) then Exit;
      SetLength(LResult, LConfigs.ConfigurationCount);
      for LIndex := 0 to LConfigs.ConfigurationCount - 1 do
        LResult[LIndex] := LConfigs.Configurations[LIndex].Name;
    end);
  except
    LResult := [];
  end;
  Result := LResult;
end;

function TMCPProjectReadService.GetActiveConfiguration: string;
var
  LResult: string;
begin
  LResult := '';
  try
    TThread.Synchronize(nil, procedure
    var
      LProject: IOTAProject;
      LOptions: IOTAProjectOptions;
      LConfigs: IOTAProjectOptionsConfigurations;
    begin
      if not TFacadeShared.TryProject(LProject) then Exit;
      LOptions := LProject.ProjectOptions;
      if not Assigned(LOptions) then Exit;
      if Supports(LOptions, IOTAProjectOptionsConfigurations, LConfigs) then
      begin
        try
          LResult := LConfigs.ActiveConfigurationName;
        except
          LResult := '';
        end;
      end;
    end);
  except
    LResult := '';
  end;
  Result := LResult;
end;

function TMCPProjectReadService.GetProjectOutputDir: string;
var
  LResult: string;
begin
  LResult := '';
  try
    TThread.Synchronize(nil, procedure
    var
      LProject: IOTAProject;
      LOptions: IOTAProjectOptions;
    begin
      if not TFacadeShared.TryProject(LProject) then Exit;
      LOptions := LProject.ProjectOptions;
      if not Assigned(LOptions) then Exit;
      try
        LResult := VarToStr(LOptions.Values['OutputDir']);
      except
        LResult := '';
      end;
    end);
  except
    LResult := '';
  end;
  Result := LResult;
end;

function TMCPProjectReadService.GetProjectVersion: string;
begin
  Result := TDProjParser.ParseProjectVersion(TFacadeShared.ReadActiveDProjXml);
end;

// Real <ProjectGuid> read from the active project's .dproj (ESP-092 / upstream
// ask #4). IOTAProject has no GUID accessor; parsed from the .dproj XML.
function TMCPProjectReadService.GetProjectGUID: string;
begin
  Result := TDProjParser.ParseProjectGuid(TFacadeShared.ReadActiveDProjXml);
end;

// Project description read from the active project's .dproj (ESP-092 / upstream
// ask #5): a real FileDescription= in <VerInfo_Keys>, else <Description>. '' when
// the project sets neither (a documented no-viable-ota-path, BR5).
function TMCPProjectReadService.GetProjectDescription: string;
begin
  Result := TDProjParser.ParseProjectDescription(TFacadeShared.ReadActiveDProjXml);
end;

function NewMCPProjectReadService: IMCPProjectReadService;
begin
  Result := TMCPProjectReadService.Create;
end;

end.
