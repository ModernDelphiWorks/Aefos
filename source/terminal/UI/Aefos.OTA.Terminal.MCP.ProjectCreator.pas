unit Aefos.OTA.Terminal.MCP.ProjectCreator;

{
  OTA-backed IProjectCreatorService for the Terminal (ESP-096, S2 / ADR-096-03).

  This is the consumer-owned, impure boundary of the new CreateNewProject MCP
  tool. The OTA-free decisions (validate / classify / confine / no-overwrite)
  live in the pure Aefos.OTA.Terminal.MCP.ProjectCreatePolicy seam; this
  unit performs only the impure work the policy could not: create the disposable
  scratch directory and drive IOTAModuleServices.CreateModule with an
  IOTAProjectCreator for the requested kind, then save so the .dproj lands on
  disk (the AC3 cross-check signal).

  The frozen Core IMCPWorkspaceFacade interface is never extended (BR1) — the
  tool handler binds to IProjectCreatorService, declared consumer-side. CreateProject
  runs on the IDE main thread (the handler marshals before calling) and never
  raises across the boundary: any OTA/IO failure degrades to a kebab ErrorReason.

  This unit uses ToolsAPI; it is never linked by the headless runner. Its
  initialization assigns GProjectCreatorServiceFactory so the BPL wiring is
  automatic when the package loads (the dpk `contains` this unit). The headless
  host leaves the factory nil and the descriptor still registers (BR8 parity).
}

interface

uses
  ToolsAPI,
  Aefos.OTA.Terminal.MCP.ProjectCreatePolicy,
  Aefos.OTA.Terminal.MCP.ProjectGroupManagerPolicy;

type
  // Supplies the generated .dpr/.dpk source text to the IDE creator pipeline.
  TTerminalProjectSourceFile = class(TInterfacedObject, IOTAFile)
  private
    FSource: string;
  public
    constructor Create(const ASource: string);
    function GetSource: string;
    function GetAge: TDateTime;
  end;

  // IOTAProjectCreator for one classified kind. Implements the full 160 chain so
  // the personality / framework / platform the modern IDE needs are supplied.
  TTerminalProjectCreator = class(TInterfacedObject, IOTACreator,
    IOTAProjectCreator, IOTAProjectCreator50, IOTAProjectCreator80,
    IOTAProjectCreator160)
  private
    FPlan: TProjectCreatePlan;
  public
    constructor Create(const APlan: TProjectCreatePlan);
    // IOTACreator
    function GetCreatorType: string;
    function GetExisting: Boolean;
    function GetFileSystem: string;
    function GetOwner: IOTAModule;
    function GetUnnamed: Boolean;
    // IOTAProjectCreator
    function GetFileName: string;
    function GetOptionFileName: string;
    function GetShowSource: Boolean;
    procedure NewDefaultModule;
    function NewOptionSource(const AProjectName: string): IOTAFile;
    procedure NewProjectResource(const AProject: IOTAProject);
    function NewProjectSource(const AProjectName: string): IOTAFile;
    // IOTAProjectCreator50
    procedure NewDefaultProjectModule(const AProject: IOTAProject);
    // IOTAProjectCreator80
    function GetProjectPersonality: string;
    // IOTAProjectCreator160
    function GetFrameworkType: string;
    function GetPlatforms: TArray<string>;
    function GetPreferredPlatform: string;
    procedure SetInitialOptions(const ANewProject: IOTAProject);
  end;

  // The consumer-owned creation service bound to the CreateNewProject handler.
  TOTAProjectCreatorService = class(TInterfacedObject, IProjectCreatorService)
  public
    function CreateProject(const APlan: TProjectCreatePlan): TProjectCreateResult;
  end;

  // OTA-backed service for the SaveProjectGroup / RenameProjectGroup / CloseAllProjects tools.
  TProjectGroupManagerService = class(TInterfacedObject, IProjectGroupManagerService)
  public
    function SaveGroupAs(const APath: string): TProjectGroupSaveResult;
    function RenameGroup(const ANewName: string): TProjectGroupSaveResult;
    function CloseAll: Boolean;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils;

const
  PLATFORM_WIN32 = 'Win32';

// Builds the minimal project skeleton source for the plan's kind. No forms or
// extra units are added (out of scope) — just a buildable default body.
function _GenerateSource(const APlan: TProjectCreatePlan): string;
const
  NL = sLineBreak;
var
  LName: string;
begin
  LName := APlan.ProjectName;
  case APlan.Spec.Kind of
    pkConsoleApplication:
      Result := 'program ' + LName + ';' + NL + NL +
                '{$APPTYPE CONSOLE}' + NL + NL +
                'uses' + NL +
                '  System.SysUtils;' + NL + NL +
                'begin' + NL +
                'end.' + NL;
    pkVCLApplication:
      Result := 'program ' + LName + ';' + NL + NL +
                'uses' + NL +
                '  Vcl.Forms;' + NL + NL +
                '{$R *.res}' + NL + NL +
                'begin' + NL +
                '  Application.Initialize;' + NL +
                '  Application.MainFormOnTaskbar := True;' + NL +
                '  Application.Run;' + NL +
                'end.' + NL;
    pkFMXApplication:
      Result := 'program ' + LName + ';' + NL + NL +
                'uses' + NL +
                '  FMX.Forms;' + NL + NL +
                '{$R *.res}' + NL + NL +
                'begin' + NL +
                '  Application.Initialize;' + NL +
                '  Application.Run;' + NL +
                'end.' + NL;
    pkPackage:
      Result := 'package ' + LName + ';' + NL + NL +
                '{$IMPLICITBUILD ON}' + NL + NL +
                'requires' + NL +
                '  rtl;' + NL + NL +
                'end.' + NL;
    pkLibrary:
      Result := 'library ' + LName + ';' + NL + NL +
                'uses' + NL +
                '  System.SysUtils;' + NL + NL +
                '{$R *.res}' + NL + NL +
                'begin' + NL +
                'end.' + NL;
  else
    Result := '';
  end;
end;

{ TTerminalProjectSourceFile }

constructor TTerminalProjectSourceFile.Create(const ASource: string);
begin
  inherited Create;
  FSource := ASource;
end;

function TTerminalProjectSourceFile.GetSource: string;
begin
  Result := FSource;
end;

function TTerminalProjectSourceFile.GetAge: TDateTime;
begin
  Result := -1; // new file
end;

{ TTerminalProjectCreator }

constructor TTerminalProjectCreator.Create(const APlan: TProjectCreatePlan);
begin
  inherited Create;
  FPlan := APlan;
end;

function TTerminalProjectCreator.GetCreatorType: string;
begin
  Result := FPlan.Spec.CreatorType;
end;

function TTerminalProjectCreator.GetExisting: Boolean;
begin
  Result := False;
end;

function TTerminalProjectCreator.GetFileSystem: string;
begin
  Result := '';
end;

function TTerminalProjectCreator.GetOwner: IOTAModule;
begin
  Result := nil; // standalone — the IDE creates a fresh project group
end;

function TTerminalProjectCreator.GetUnnamed: Boolean;
begin
  Result := False; // a fully-qualified GetFileName is supplied
end;

function TTerminalProjectCreator.GetFileName: string;
begin
  Result := FPlan.ProjectFilePath;
end;

function TTerminalProjectCreator.GetOptionFileName: string;
begin
  Result := '';
end;

function TTerminalProjectCreator.GetShowSource: Boolean;
begin
  Result := False;
end;

procedure TTerminalProjectCreator.NewDefaultModule;
begin
  // Deprecated path — NewDefaultProjectModule is used instead.
end;

function TTerminalProjectCreator.NewOptionSource(
  const AProjectName: string): IOTAFile;
begin
  Result := nil;
end;

procedure TTerminalProjectCreator.NewProjectResource(const AProject: IOTAProject);
begin
  // Default .res is generated by the IDE from the {$R *.res} directive.
end;

function TTerminalProjectCreator.NewProjectSource(
  const AProjectName: string): IOTAFile;
begin
  Result := TTerminalProjectSourceFile.Create(_GenerateSource(FPlan));
end;

procedure TTerminalProjectCreator.NewDefaultProjectModule(
  const AProject: IOTAProject);
begin
  // Bare skeleton only — no default form/unit is added (out of scope).
end;

function TTerminalProjectCreator.GetProjectPersonality: string;
begin
  Result := FPlan.Spec.Personality;
end;

function TTerminalProjectCreator.GetFrameworkType: string;
begin
  Result := FPlan.Spec.Framework;
end;

function TTerminalProjectCreator.GetPlatforms: TArray<string>;
begin
  Result := [PLATFORM_WIN32];
end;

function TTerminalProjectCreator.GetPreferredPlatform: string;
begin
  Result := PLATFORM_WIN32;
end;

procedure TTerminalProjectCreator.SetInitialOptions(
  const ANewProject: IOTAProject);
begin
  // Defaults are sufficient for the disposable scratch project.
end;

{ TOTAProjectCreatorService }

function TOTAProjectCreatorService.CreateProject(
  const APlan: TProjectCreatePlan): TProjectCreateResult;
var
  LServices: IOTAModuleServices;
  LModule: IOTAModule;
begin
  Result := Default(TProjectCreateResult);
  Result.DProjPath := APlan.DProjPath;
  Result.ProjectType := APlan.Spec.TypeName;
  try
    if not Assigned(BorlandIDEServices) or
       not Supports(BorlandIDEServices, IOTAModuleServices, LServices) then
    begin
      Result.ErrorReason := 'no-ota-services';
      Exit;
    end;
    TDirectory.CreateDirectory(APlan.ProjectDir);
    LModule := LServices.CreateModule(TTerminalProjectCreator.Create(APlan));
    if not Assigned(LModule) then
    begin
      Result.ErrorReason := 'ota-create-failed';
      Exit;
    end;
    LModule.Save(False, True); // ChangeName=False, ForceSave=True → write .dproj
    Result.Created := TFile.Exists(APlan.DProjPath);
    if not Result.Created then
      Result.ErrorReason := 'dproj-not-written';
  except
    on E: Exception do
    begin
      Result.Created := False;
      Result.ErrorReason := 'ota-exception';
    end;
  end;
end;

{ TProjectGroupManagerService }

function TProjectGroupManagerService.SaveGroupAs(
  const APath: string): TProjectGroupSaveResult;
var
  LDone: Boolean;
  LErrorReason: string;
begin
  Result       := Default(TProjectGroupSaveResult);
  LDone        := False;
  LErrorReason := 'no-project-group';
  if not Assigned(BorlandIDEServices) then
  begin
    Result.ErrorReason := 'no-ota-services';
    Exit;
  end;
  try
    TThread.Synchronize(nil, procedure
    var
      LMS:    IOTAModuleServices;
      LGroup: IOTAProjectGroup;
      LMod:   IOTAModule40;
    begin
      if not Supports(BorlandIDEServices, IOTAModuleServices, LMS) then
      begin
        LErrorReason := 'no-module-services';
        Exit;
      end;
      LGroup := LMS.MainProjectGroup;
      if not Assigned(LGroup) then
      begin
        LErrorReason := 'no-project-group';
        Exit;
      end;
      if not Supports(LGroup, IOTAModule40, LMod) then
      begin
        LErrorReason := 'no-module40-interface';
        Exit;
      end;
      // Pre-create a placeholder so Save(False, True) writes silently — without it
      // the IDE shows a Save As dialog for any group that has no file on disk yet.
      if not TFile.Exists(APath) then
        TFile.WriteAllText(APath,
          '<?xml version="1.0" encoding="utf-8"?>' + sLineBreak +
          '<Project xmlns="http://schemas.embarcadero.com/radstudio/cbuilder/2009">' + sLineBreak +
          '</Project>', TEncoding.UTF8);
      LMod.SetFileName(APath);
      if LMod.Save(False, True) then // ChangeName=False, ForceSave=True → write .groupproj
      begin
        LDone        := True;
        LErrorReason := '';
      end
      else
      begin
        TFile.Delete(APath); // clean up the placeholder if save failed
        LErrorReason := 'save-failed';
      end;
    end);
  except
    on E: Exception do
      LErrorReason := 'ota-exception';
  end;
  Result.Applied     := LDone;
  Result.Path        := APath;
  Result.ErrorReason := LErrorReason;
end;

function TProjectGroupManagerService.RenameGroup(
  const ANewName: string): TProjectGroupSaveResult;
var
  LDone:        Boolean;
  LErrorReason: string;
  LOldPath:     string;
  LNewPath:     string;
begin
  Result       := Default(TProjectGroupSaveResult);
  LDone        := False;
  LErrorReason := 'no-project-group';
  LOldPath     := '';
  LNewPath     := '';
  if not Assigned(BorlandIDEServices) then
  begin
    Result.ErrorReason := 'no-ota-services';
    Exit;
  end;
  try
    TThread.Synchronize(nil, procedure
    var
      LMS:    IOTAModuleServices;
      LGroup: IOTAProjectGroup;
      LMod:   IOTAModule40;
      LDir:   string;
    begin
      if not Supports(BorlandIDEServices, IOTAModuleServices, LMS) then
      begin
        LErrorReason := 'no-module-services';
        Exit;
      end;
      LGroup := LMS.MainProjectGroup;
      if not Assigned(LGroup) then
      begin
        LErrorReason := 'no-project-group';
        Exit;
      end;
      if not Supports(LGroup, IOTAModule40, LMod) then
      begin
        LErrorReason := 'no-module40-interface';
        Exit;
      end;
      LOldPath := LMod.GetFileName;
      if LOldPath = '' then
      begin
        LErrorReason := 'group-not-saved';
        Exit;
      end;
      LDir     := TPath.GetDirectoryName(LOldPath);
      LNewPath := TPath.Combine(LDir, ANewName + '.groupproj');
      if TFile.Exists(LNewPath) and not SameText(LOldPath, LNewPath) then
      begin
        LErrorReason := 'target-exists';
        Exit;
      end;
      // Pre-create a placeholder at the new path so Save(False, True) is silent.
      if not TFile.Exists(LNewPath) then
        TFile.WriteAllText(LNewPath,
          '<?xml version="1.0" encoding="utf-8"?>' + sLineBreak +
          '<Project xmlns="http://schemas.embarcadero.com/radstudio/cbuilder/2009">' + sLineBreak +
          '</Project>', TEncoding.UTF8);
      LMod.SetFileName(LNewPath);
      if LMod.Save(False, True) then // ChangeName=False, ForceSave=True
      begin
        LDone        := True;
        LErrorReason := '';
        if not SameText(LOldPath, LNewPath) and TFile.Exists(LOldPath) then
          TFile.Delete(LOldPath);
      end
      else
      begin
        LMod.SetFileName(LOldPath); // restore on failure
        TFile.Delete(LNewPath);     // clean up the placeholder
        LErrorReason := 'save-failed';
      end;
    end);
  except
    on E: Exception do
      LErrorReason := 'ota-exception';
  end;
  Result.Applied     := LDone;
  Result.Path        := LNewPath;
  Result.OldPath     := LOldPath;
  Result.ErrorReason := LErrorReason;
end;

function TProjectGroupManagerService.CloseAll: Boolean;
var
  LDone: Boolean;
begin
  LDone := False;
  if not Assigned(BorlandIDEServices) then
    Exit(False);
  try
    TThread.Synchronize(nil, procedure
    var
      LMS: IOTAModuleServices;
    begin
      if Supports(BorlandIDEServices, IOTAModuleServices, LMS) then
        LDone := LMS.CloseAll;
    end);
  except
    on E: Exception do
      LDone := False;
  end;
  Result := LDone;
end;

initialization
  GProjectCreatorServiceFactory :=
    function: IProjectCreatorService
    begin
      Result := TOTAProjectCreatorService.Create;
    end;
  GProjectGroupManagerServiceFactory :=
    function: IProjectGroupManagerService
    begin
      Result := TProjectGroupManagerService.Create;
    end;

finalization
  GProjectCreatorServiceFactory    := nil;
  GProjectGroupManagerServiceFactory := nil;

end.
