unit Aefos.MCP.OTA.ProjectLifecycleService;

{
  Project / unit creation domain, extracted from the TMCPWorkspaceFacade
  god-object as a focused service of the SOLID split (audit S6 / facade split).

  Owns the OTA-backed "make something new" surface — AddUnit (the first confined,
  no-silent-overwrite IOTAProject.AddFile write gated by the pure UnitCreatePolicy
  seam), CreateNewUnit (optionally a paired VCL/FMX form), CreateNewProject (a full
  OTA CreateModule of a VCL/FMX/Console/Package/Library/DUnit/DUnitX project, with
  the inherited-design-package scrub) and CloseAllProjects. The framework-aware
  worker CreateNewUnitEx (private) and every source/.dfm/.fmx/.dpr generator, the
  project classifier/validator and the .dproj DCC_UsePackage strip move with the
  slice — they are used ONLY here. Every other dependency comes from FacadeShared
  (TryProject / FirstSourceEditor / ReadBytes / WriteUnitSource) and the pure
  UnitCreatePolicy. The service is stateless. Bodies moved VERBATIM (only the class
  qualifier changes on the methods); GetDPRContent's body became the free function
  _ReadActiveDprContent so CreateNewProject reads the live .dpr without a facade
  hop. The facade delegates the frozen IMCPWorkspaceFacade methods to a refcounted
  FProjectLifecycle field.
}

interface

uses
  Aefos.MCP.Types;

type
  IMCPProjectLifecycleService = interface
    ['{6F2B1D08-7C44-4A91-9E5D-1B3A82F6C7E2}']
    function AddUnit(const AUnitPath, AContent: string;
      out AError: string): TMCPFileActionOutcome;
    function CreateNewUnit(const AUnitName: string; AWithForm: Boolean;
      out AFilePath: string): Boolean;
    function CreateNewProject(const AName, AProjectType, ADirectory: string;
      out ADProjPath: string; out AReason: string): Boolean;
    function CloseAllProjects: Boolean;
  end;

// Factory — the facade calls this once in its constructor.
function NewMCPProjectLifecycleService: IMCPProjectLifecycleService;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  ToolsAPI,
  Aefos.MCP.OTA.FacadeShared,
  Aefos.MCP.OTA.UnitCreatePolicy;

// ── Project-lifecycle local types ─────────────────────────────────────────

type
  TNewProjectKind = (npkUnsupported, npkVCL, npkFMX, npkConsole, npkPackage,
    npkLibrary, npkDUnit, npkDUnitX);

  TProjectSourceFile = class(TInterfacedObject, IOTAFile)
  private
    FSource: string;
  public
    constructor Create(const ASource: string);
    function GetSource: string;
    function GetAge: TDateTime;
  end;

  TNewProjectCreator = class(TInterfacedObject, IOTACreator,
    IOTAProjectCreator, IOTAProjectCreator50, IOTAProjectCreator80,
    IOTAProjectCreator160)
  private
    FKind    : TNewProjectKind;
    FFileName: string;
    FSource  : string;
  public
    constructor Create(const AKind: TNewProjectKind;
      const AFileName, ASource: string);
    function  GetCreatorType: string;
    function  GetExisting: Boolean;
    function  GetFileSystem: string;
    function  GetOwner: IOTAModule;
    function  GetUnnamed: Boolean;
    function  GetFileName: string;
    function  GetOptionFileName: string;
    function  GetShowSource: Boolean;
    procedure NewDefaultModule;
    function  NewOptionSource(const AProjectName: string): IOTAFile;
    procedure NewProjectResource(const AProject: IOTAProject);
    function  NewProjectSource(const AProjectName: string): IOTAFile;
    procedure NewDefaultProjectModule(const AProject: IOTAProject);
    function  GetProjectPersonality: string;
    function  GetFrameworkType: string;
    function  GetPlatforms: TArray<string>;
    function  GetPreferredPlatform: string;
    procedure SetInitialOptions(const ANewProject: IOTAProject);
  end;

const
  PROJ_SCRATCH_SUBDIR  = 'Aefos';
  PROJ_OTA_PERSONALITY = 'Delphi.Personality';
  PROJ_PLATFORM_WIN32  = 'Win32';

{ TProjectSourceFile }

constructor TProjectSourceFile.Create(const ASource: string);
begin
  inherited Create;
  FSource := ASource;
end;

function TProjectSourceFile.GetSource: string;
begin
  Result := FSource;
end;

function TProjectSourceFile.GetAge: TDateTime;
begin
  Result := -1;
end;

{ TNewProjectCreator }

constructor TNewProjectCreator.Create(const AKind: TNewProjectKind;
  const AFileName, ASource: string);
begin
  inherited Create;
  FKind     := AKind;
  FFileName := AFileName;
  FSource   := ASource;
end;

function TNewProjectCreator.GetCreatorType: string;
begin
  case FKind of
    npkVCL, npkFMX: Result := 'Application';
    npkConsole:     Result := 'Console';
    npkPackage:     Result := 'Package';
    npkLibrary:     Result := 'Library';
  else
    Result := 'Application';
  end;
end;

function TNewProjectCreator.GetExisting: Boolean;
begin
  Result := False;
end;

function TNewProjectCreator.GetFileSystem: string;
begin
  Result := '';
end;

function TNewProjectCreator.GetOwner: IOTAModule;
begin
  Result := nil;
end;

function TNewProjectCreator.GetUnnamed: Boolean;
begin
  Result := False;
end;

function TNewProjectCreator.GetFileName: string;
begin
  Result := FFileName;
end;

function TNewProjectCreator.GetOptionFileName: string;
begin
  Result := '';
end;

function TNewProjectCreator.GetShowSource: Boolean;
begin
  Result := False;
end;

procedure TNewProjectCreator.NewDefaultModule;
begin
end;

function TNewProjectCreator.NewOptionSource(const AProjectName: string): IOTAFile;
begin
  Result := nil;
end;

procedure TNewProjectCreator.NewProjectResource(const AProject: IOTAProject);
begin
end;

function TNewProjectCreator.NewProjectSource(const AProjectName: string): IOTAFile;
begin
  Result := TProjectSourceFile.Create(FSource);
end;

procedure TNewProjectCreator.NewDefaultProjectModule(const AProject: IOTAProject);
begin
end;

function TNewProjectCreator.GetProjectPersonality: string;
begin
  Result := PROJ_OTA_PERSONALITY;
end;

function TNewProjectCreator.GetFrameworkType: string;
begin
  case FKind of
    npkVCL: Result := 'VCL';
    npkFMX: Result := 'FMX';
  else
    Result := '';
  end;
end;

function TNewProjectCreator.GetPlatforms: TArray<string>;
begin
  Result := [PROJ_PLATFORM_WIN32];
end;

function TNewProjectCreator.GetPreferredPlatform: string;
begin
  Result := PROJ_PLATFORM_WIN32;
end;

procedure TNewProjectCreator.SetInitialOptions(const ANewProject: IOTAProject);
begin
end;

// ── .dproj design-package scrub helpers ────────────────────────────────────

// Removes property AProp from ACfg and every descendant build configuration.
// Used to scrub the design-package list a freshly OTA-created project inherits
// from the IDE's currently-loaded design BPLs (C4). Pure ToolsAPI (no xmlrtl).
// Each node is guarded: a config that lacks the property or rejects Remove is
// simply skipped — never raises across the boundary (BR-3).
procedure _RemovePropRecursive(const ACfg: IOTABuildConfiguration;
  const AProp: string);
var
  LChild: Integer;
begin
  if not Assigned(ACfg) then Exit;
  try
    if ACfg.PropertyExists(AProp) then
      ACfg.Remove(AProp);
  except
  end;
  try
    for LChild := 0 to ACfg.ChildCount - 1 do
      _RemovePropRecursive(ACfg.Children[LChild], AProp);
  except
  end;
end;

// C4: a project made via OTA CreateModule bakes the IDE's currently-loaded
// design BPLs into DCC_UsePackage (e.g. a bare console lists Aefos.MCP.Core;
// Aefos.OTA.Chat;...). Harmless at design time but noisy/unprofessional in the
// generated .dproj. Remove it from the in-memory project options across the
// whole configuration tree so a later user-initiated project save stays clean
// (no Save here — the disk artifact is cleaned separately by the textual strip
// below, which avoids any risk of regenerating/clobbering the .dpr).
procedure _ClearInheritedUsePackages(const AModule: IOTAModule);
var
  LProject: IOTAProject;
  LOptions: IOTAProjectOptions;
  LConfigs: IOTAProjectOptionsConfigurations;
begin
  if not Assigned(AModule) then Exit;
  if not Supports(AModule, IOTAProject, LProject) then Exit;
  LOptions := LProject.ProjectOptions;
  if not Assigned(LOptions) then Exit;
  if not Supports(LOptions, IOTAProjectOptionsConfigurations, LConfigs) then Exit;
  // The base configuration is the root of the whole tree (Debug/Release and
  // their platform children all descend from it); recursing it covers every
  // node where the inherited literal could live.
  _RemovePropRecursive(LConfigs.BaseConfiguration, 'DCC_UsePackage');
end;

// Textually strips every <DCC_UsePackage>...</DCC_UsePackage> element from the
// .dproj on disk (C4), including the element's leading indentation and trailing
// line break so no blank line is left behind. Pure string surgery — same
// deliberate "no Xml.XMLDoc / no xmlrtl dependency" choice as _ScanUsePackages,
// and it never touches the .dpr. Returns True when the file was rewritten.
function _StripUsePackagesFromDproj(const ADProjPath: string): Boolean;
const
  COpen  = '<DCC_UsePackage>';
  CClose = '</DCC_UsePackage>';
var
  LText: string;
  LOpen, LClose, LLineStart, LLineEnd: Integer;
  LChanged: Boolean;
begin
  Result := False;
  if not TFile.Exists(ADProjPath) then Exit;
  try
    LText := TFile.ReadAllText(ADProjPath, TEncoding.UTF8);
  except
    Exit;
  end;
  LChanged := False;
  repeat
    LOpen := Pos(COpen, LText);
    if LOpen = 0 then Break;
    LClose := Pos(CClose, LText, LOpen);
    if LClose = 0 then Break;
    LClose := LClose + Length(CClose) - 1;  // index of the close tag's last char
    // Extend left over the leading spaces/tabs on the element's own line.
    LLineStart := LOpen;
    while (LLineStart > 1) and CharInSet(LText[LLineStart - 1], [' ', #9]) do
      Dec(LLineStart);
    // Extend right over the trailing CR/LF so the line is removed whole.
    LLineEnd := LClose;
    while (LLineEnd < Length(LText)) and
          CharInSet(LText[LLineEnd + 1], [#13, #10]) do
      Inc(LLineEnd);
    Delete(LText, LLineStart, LLineEnd - LLineStart + 1);
    LChanged := True;
  until False;
  if not LChanged then Exit;
  try
    TFile.WriteAllText(ADProjPath, LText, TEncoding.UTF8);
    Result := True;
  except
    Result := False;
  end;
end;

// ── Unit / form source generators ──────────────────────────────────────────

// Minimal source for a plain (form-less) new unit.
function _NewPlainUnitSource(const AUnitName: string): string;
begin
  Result :=
    'unit ' + AUnitName + ';' + sLineBreak + sLineBreak +
    'interface' + sLineBreak + sLineBreak +
    'implementation' + sLineBreak + sLineBreak +
    'end.' + sLineBreak;
end;

// Source for a new VCL-form unit. AFormBase is a dot-free identifier base for
// the form class (T<AFormBase>Form); AInstance is the global instance/var name
// (and the .dfm root object name) — passed in separately because it MUST differ
// from the unit identifier or the compiler rejects `var <id>: ...` with
// E2004 Identifier redeclared (a unit literally named 'MainForm' would otherwise
// declare `var MainForm`, colliding with the unit name). The `unit` clause keeps
// the dotted AUnitName.
function _NewFormUnitSource(const AUnitName, AFormBase, AInstance: string): string;
begin
  Result :=
    'unit ' + AUnitName + ';' + sLineBreak + sLineBreak +
    'interface' + sLineBreak + sLineBreak +
    'uses' + sLineBreak +
    '  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants,' + sLineBreak +
    '  System.Classes, Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs;' + sLineBreak + sLineBreak +
    'type' + sLineBreak +
    '  T' + AFormBase + 'Form = class(TForm)' + sLineBreak +
    '  private' + sLineBreak +
    '    { Private declarations }' + sLineBreak +
    '  public' + sLineBreak +
    '    { Public declarations }' + sLineBreak +
    '  end;' + sLineBreak + sLineBreak +
    'var' + sLineBreak +
    '  ' + AInstance + ': T' + AFormBase + 'Form;' + sLineBreak + sLineBreak +
    'implementation' + sLineBreak + sLineBreak +
    '{$R *.dfm}' + sLineBreak + sLineBreak +
    'end.' + sLineBreak;
end;

// Companion .dfm for a new form unit (paired with _NewFormUnitSource). The root
// object name is AInstance so it matches the global var the IDE wires into the
// .dpr's CreateForm call.
function _NewFormDfm(const AFormBase, AInstance: string): string;
begin
  Result :=
    'object ' + AInstance + ': T' + AFormBase + 'Form' + sLineBreak +
    '  Left = 0' + sLineBreak +
    '  Top = 0' + sLineBreak +
    '  Caption = ''' + AFormBase + '''' + sLineBreak +
    '  ClientHeight = 300' + sLineBreak +
    '  ClientWidth = 400' + sLineBreak +
    '  Font.Charset = DEFAULT_CHARSET' + sLineBreak +
    '  Font.Color = clWindowText' + sLineBreak +
    '  Font.Height = -12' + sLineBreak +
    '  Font.Name = ''Segoe UI''' + sLineBreak +
    '  Font.Style = []' + sLineBreak +
    '  PixelsPerInch = 96' + sLineBreak +
    '  TextHeight = 15' + sLineBreak +
    'end' + sLineBreak;
end;

// Source for a new FMX-form unit — the FireMonkey sibling of _NewFormUnitSource
// (same identifier contract: T<AFormBase>Form class, AInstance global var). The
// VCL generator above is deliberately left byte-for-byte unchanged; this is a
// parallel path selected only when the project's framework is FMX, so the
// well-trained VCL output never shifts.
function _NewFmxFormUnitSource(const AUnitName, AFormBase, AInstance: string): string;
begin
  Result :=
    'unit ' + AUnitName + ';' + sLineBreak + sLineBreak +
    'interface' + sLineBreak + sLineBreak +
    'uses' + sLineBreak +
    '  System.SysUtils, System.Types, System.UITypes, System.Classes,' + sLineBreak +
    '  System.Variants, FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics,' + sLineBreak +
    '  FMX.Dialogs, FMX.Controls.Presentation, FMX.StdCtrls;' + sLineBreak + sLineBreak +
    'type' + sLineBreak +
    '  T' + AFormBase + 'Form = class(TForm)' + sLineBreak +
    '  private' + sLineBreak +
    '    { Private declarations }' + sLineBreak +
    '  public' + sLineBreak +
    '    { Public declarations }' + sLineBreak +
    '  end;' + sLineBreak + sLineBreak +
    'var' + sLineBreak +
    '  ' + AInstance + ': T' + AFormBase + 'Form;' + sLineBreak + sLineBreak +
    'implementation' + sLineBreak + sLineBreak +
    '{$R *.fmx}' + sLineBreak + sLineBreak +
    'end.' + sLineBreak;
end;

// Companion .fmx for a new FMX form unit (paired with _NewFmxFormUnitSource).
// Mirrors _NewFormDfm but in FireMonkey form-stream format (FormFactor +
// DesignerMasterStyle instead of the VCL Font/PixelsPerInch block).
function _NewFmxFormFmx(const AFormBase, AInstance: string): string;
begin
  Result :=
    'object ' + AInstance + ': T' + AFormBase + 'Form' + sLineBreak +
    '  Left = 0' + sLineBreak +
    '  Top = 0' + sLineBreak +
    '  Caption = ''' + AFormBase + '''' + sLineBreak +
    '  ClientHeight = 480' + sLineBreak +
    '  ClientWidth = 640' + sLineBreak +
    '  FormFactor.Width = 320' + sLineBreak +
    '  FormFactor.Height = 480' + sLineBreak +
    '  FormFactor.Devices = [Desktop]' + sLineBreak +
    '  DesignerMasterStyle = 0' + sLineBreak +
    'end' + sLineBreak;
end;

// Sample DUnitX test fixture — mirrors the official DUnitX wizard's starter unit
// so a freshly created DUnitX project discovers a real, passing fixture via RTTI
// instead of running zero tests. AUnitName must equal the .pas file name (the
// `unit X;` clause), so the caller derives it from the created file path.
function _NewDUnitXTestUnitSource(const AUnitName: string): string;
const
  NL = sLineBreak;
begin
  Result :=
    'unit ' + AUnitName + ';' + NL + NL +
    'interface' + NL + NL +
    'uses' + NL +
    '  DUnitX.TestFramework;' + NL + NL +
    'type' + NL +
    '  [TestFixture]' + NL +
    '  TSampleTest = class' + NL +
    '  public' + NL +
    '    [Setup]' + NL +
    '    procedure Setup;' + NL +
    '    [TearDown]' + NL +
    '    procedure TearDown;' + NL +
    '    [Test]' + NL +
    '    procedure TestPasses;' + NL +
    '    [Test]' + NL +
    '    [TestCase(''Sum 1+2'', ''1,2,3'')]' + NL +
    '    [TestCase(''Sum 3+4'', ''3,4,7'')]' + NL +
    '    procedure TestSum(const A, B, Expected: Integer);' + NL +
    '  end;' + NL + NL +
    'implementation' + NL + NL +
    'procedure TSampleTest.Setup;' + NL +
    'begin' + NL +
    'end;' + NL + NL +
    'procedure TSampleTest.TearDown;' + NL +
    'begin' + NL +
    'end;' + NL + NL +
    'procedure TSampleTest.TestPasses;' + NL +
    'begin' + NL +
    '  Assert.AreEqual(4, 2 + 2);' + NL +
    'end;' + NL + NL +
    'procedure TSampleTest.TestSum(const A, B, Expected: Integer);' + NL +
    'begin' + NL +
    '  Assert.AreEqual(Expected, A + B);' + NL +
    'end;' + NL + NL +
    'initialization' + NL +
    '  TDUnitX.RegisterTestFixture(TSampleTest);' + NL + NL +
    'end.' + NL;
end;

// ── Project classifier / validator / .dpr source ───────────────────────────

function _ProjValidName(const AName: string): Boolean;
var
  LI: Integer;
begin
  Result := False;
  if AName = '' then Exit;
  if not CharInSet(AName[1], ['A'..'Z', 'a'..'z', '_']) then Exit;
  for LI := 2 to Length(AName) do
    if not CharInSet(AName[LI], ['A'..'Z', 'a'..'z', '0'..'9', '_']) then Exit;
  Result := True;
end;

function _ProjClassify(const ATypeName: string): TNewProjectKind;
type
  TKindAlias = record Token: string; Kind: TNewProjectKind; end;
const
  ALIASES: array[0..19] of TKindAlias = (
    (Token: 'vcl';            Kind: npkVCL),
    (Token: 'vclapp';         Kind: npkVCL),
    (Token: 'vclapplication'; Kind: npkVCL),
    (Token: 'fmx';            Kind: npkFMX),
    (Token: 'firemonkey';     Kind: npkFMX),
    (Token: 'fmxapp';         Kind: npkFMX),
    (Token: 'console';        Kind: npkConsole),
    (Token: 'consoleapp';     Kind: npkConsole),
    (Token: 'package';        Kind: npkPackage),
    (Token: 'pkg';            Kind: npkPackage),
    (Token: 'bpl';            Kind: npkPackage),
    (Token: 'library';        Kind: npkLibrary),
    (Token: 'lib';            Kind: npkLibrary),
    (Token: 'dll';            Kind: npkLibrary),
    (Token: 'dunit';          Kind: npkDUnit),
    (Token: 'dunit2';         Kind: npkDUnit),
    (Token: 'nunit';          Kind: npkDUnit),
    (Token: 'dunitx';         Kind: npkDUnitX),
    (Token: 'dunitx2';        Kind: npkDUnitX),
    (Token: 'testproject';    Kind: npkDUnitX));
var
  LToken: string;
  LI: Integer;
begin
  LToken := Trim(ATypeName).ToLower;
  for LI := 0 to High(ALIASES) do
    if SameText(LToken, ALIASES[LI].Token) then
      Exit(ALIASES[LI].Kind);
  Result := npkUnsupported;
end;

function _ProjSource(const AName: string; const AKind: TNewProjectKind): string;
const
  NL = sLineBreak;
begin
  case AKind of
    npkVCL:
      Result := 'program ' + AName + ';' + NL + NL +
                'uses' + NL + '  Vcl.Forms;' + NL + NL +
                '{$R *.res}' + NL + NL +
                'begin' + NL +
                '  Application.Initialize;' + NL +
                '  Application.MainFormOnTaskbar := True;' + NL +
                '  Application.Run;' + NL +
                'end.' + NL;
    npkFMX:
      Result := 'program ' + AName + ';' + NL + NL +
                'uses' + NL + '  FMX.Forms;' + NL + NL +
                '{$R *.res}' + NL + NL +
                'begin' + NL +
                '  Application.Initialize;' + NL +
                '  Application.Run;' + NL +
                'end.' + NL;
    npkConsole:
      Result := 'program ' + AName + ';' + NL + NL +
                '{$APPTYPE CONSOLE}' + NL + NL +
                'uses' + NL + '  System.SysUtils;' + NL + NL +
                'begin' + NL + 'end.' + NL;
    npkPackage:
      Result := 'package ' + AName + ';' + NL + NL +
                '{$IMPLICITBUILD ON}' + NL + NL +
                'requires' + NL + '  rtl;' + NL + NL +
                'end.' + NL;
    npkLibrary:
      Result := 'library ' + AName + ';' + NL + NL +
                'uses' + NL + '  System.SysUtils;' + NL + NL +
                '{$R *.res}' + NL + NL +
                'begin' + NL + 'end.' + NL;
    npkDUnit:
      Result := 'program ' + AName + ';' + NL + NL +
                '{$IFDEF CONSOLE_TESTRUNNER}' + NL +
                '{$APPTYPE CONSOLE}' + NL +
                '{$ENDIF}' + NL + NL +
                'uses' + NL + '  DUnitTestRunner;' + NL + NL +
                '{$R *.RES}' + NL + NL +
                'begin' + NL +
                '  DUnitTestRunner.RunRegisteredTests;' + NL +
                'end.' + NL;
    npkDUnitX:
      // Canonical DUnitX runner — mirrors the official DUnitX New Project wizard
      // (TestInsight gate, command-line check, RTTI fixture discovery, console +
      // NUnit-XML loggers, EXIT_ERRORS exit code, CI-safe pause). Paired with the
      // sample [TestFixture] unit created in CreateNewProject so the project runs
      // a real (passing) test out of the box instead of discovering nothing.
      Result := 'program ' + AName + ';' + NL + NL +
                '{$IFNDEF TESTINSIGHT}' + NL +
                '{$APPTYPE CONSOLE}' + NL +
                '{$ENDIF}' + NL +
                '{$STRONGLINKTYPES ON}' + NL + NL +
                'uses' + NL +
                '  System.SysUtils,' + NL +
                '  {$IFDEF TESTINSIGHT}' + NL +
                '  TestInsight.DUnitX,' + NL +
                '  {$ENDIF}' + NL +
                '  DUnitX.Loggers.Console,' + NL +
                '  DUnitX.Loggers.Xml.NUnit,' + NL +
                '  DUnitX.TestFramework;' + NL + NL +
                '{$R *.RES}' + NL + NL +
                'var' + NL +
                '  LRunner: ITestRunner;' + NL +
                '  LResults: IRunResults;' + NL +
                '  LLogger: ITestLogger;' + NL +
                '  LNUnitLogger: ITestLogger;' + NL +
                'begin' + NL +
                '{$IFDEF TESTINSIGHT}' + NL +
                '  TestInsight.DUnitX.RunRegisteredTests;' + NL +
                '{$ELSE}' + NL +
                '  try' + NL +
                '    TDUnitX.CheckCommandLine;' + NL +
                '    LRunner := TDUnitX.CreateRunner;' + NL +
                '    LRunner.UseRTTI := True;' + NL +
                '    LRunner.FailsOnNoAsserts := False;' + NL +
                '    if TDUnitX.Options.ConsoleMode <> TDunitXConsoleMode.Off then' + NL +
                '    begin' + NL +
                '      LLogger := TDUnitXConsoleLogger.Create(' + NL +
                '        TDUnitX.Options.ConsoleMode = TDunitXConsoleMode.Quiet);' + NL +
                '      LRunner.AddLogger(LLogger);' + NL +
                '    end;' + NL +
                '    LNUnitLogger := TDUnitXXMLNUnitFileLogger.Create(' + NL +
                '      TDUnitX.Options.XMLOutputFile);' + NL +
                '    LRunner.AddLogger(LNUnitLogger);' + NL +
                '    LResults := LRunner.Execute;' + NL +
                '    if not LResults.AllPassed then' + NL +
                '      System.ExitCode := EXIT_ERRORS;' + NL +
                '    {$IFNDEF CI}' + NL +
                '    if TDUnitX.Options.ExitBehavior = TDUnitXExitBehavior.Pause then' + NL +
                '    begin' + NL +
                '      System.Write(''Done.. press <Enter> key to quit.'');' + NL +
                '      System.Readln;' + NL +
                '    end;' + NL +
                '    {$ENDIF}' + NL +
                '  except' + NL +
                '    on E: Exception do' + NL +
                '      System.Writeln(E.ClassName, '': '', E.Message);' + NL +
                '  end;' + NL +
                '{$ENDIF}' + NL +
                'end.' + NL;
  else
    Result := '';
  end;
end;

// Reads the active project's .dpr source from the project module's source editor
// (live buffer) on the OTA main thread. '' only when no project is open or it has
// no source editor. Verbatim copy of the facade's GetDPRContent body, kept local
// so CreateNewProject reads the live .dpr without a facade round-trip.
function _ReadActiveDprContent: string;
var LContent: string;
begin
  LContent := '';
  try
    TThread.Synchronize(nil, procedure
    var LMS: IOTAModuleServices; LProject: IOTAProject; LSource: IOTASourceEditor;
    begin
      try
        if not Supports(BorlandIDEServices, IOTAModuleServices, LMS) then Exit;
        LProject := LMS.GetActiveProject;
        if not Assigned(LProject) then Exit;
        LSource := TFacadeShared.FirstSourceEditor(LProject);
        if Assigned(LSource) then LContent := TFacadeShared.ReadBytes(LSource.CreateReader);
      except LContent := ''; end;
    end);
  except LContent := ''; end;
  Result := LContent;
end;

type
  TMCPProjectLifecycleService = class(TInterfacedObject,
    IMCPProjectLifecycleService)
  private
    // Internal worker behind CreateNewUnit. AFmx selects the FMX form generators
    // (FMX.Forms / .fmx / {$R *.fmx}); AFmx=False keeps the VCL form output
    // byte-identical to before. The public CreateNewUnit always passes False (VCL
    // unchanged); CreateNewProject passes True only for an FMX project, so an FMX
    // project finally gets an FMX main form instead of a welded-on VCL one.
    function CreateNewUnitEx(const AUnitName: string; AWithForm, AFmx: Boolean;
      out AFilePath: string): Boolean;
  public
    function AddUnit(const AUnitPath, AContent: string;
      out AError: string): TMCPFileActionOutcome;
    function CreateNewUnit(const AUnitName: string; AWithForm: Boolean;
      out AFilePath: string): Boolean;
    function CreateNewProject(const AName, AProjectType, ADirectory: string;
      out ADProjPath: string; out AReason: string): Boolean;
    function CloseAllProjects: Boolean;
  end;

{ ── TMCPProjectLifecycleService ──────────────────────────────────────────── }

// ESP-073 (S2): the first real OTA-backed mutation. All OTA-free decision
// logic lives in the pure UnitCreatePolicy seam (BR23); this caller marshals to
// the IDE main thread (BR7) and performs the confined IOTAProject.AddFile
// write. Sentinel-degrades — faNoActiveProject / faAccessError / faAlreadyExists
// with no partial write (BR21) — on any policy rejection or OTA failure. Every
// other mutation method below stays an honest sentinel (BR20).
function TMCPProjectLifecycleService.AddUnit(const AUnitPath,
  AContent: string; out AError: string): TMCPFileActionOutcome;
var
  LOutcome: TMCPFileActionOutcome;
  LError: string;
begin
  LOutcome := faAccessError;
  LError   := '';
  try
    TThread.Synchronize(nil, procedure
    var
      LProject: IOTAProject;
      LRoot: string;
      LPlan: TUnitCreatePlan;
    begin
      if not TFacadeShared.TryProject(LProject) then
      begin
        LOutcome := faNoActiveProject;
        Exit;
      end;
      LRoot := TPath.GetDirectoryName(LProject.FileName);
      // AddUnit's Core tool schema exposes no overwrite arg (frozen, BR1/BR24),
      // so the create always refuses to clobber an existing file (safe default).
      LPlan := TUnitCreatePolicy.ResolveUnitCreate(AUnitPath, LRoot, False,
        function(const APath: string): Boolean
        begin
          Result := TFile.Exists(APath);
        end);
      if not LPlan.Accepted then
      begin
        LOutcome := LPlan.Outcome;
        LError   := LPlan.Reason;
        Exit;
      end;
      try
        TFile.WriteAllText(LPlan.FullPath, AContent, TEncoding.UTF8);
        try
          LProject.AddFile(LPlan.FullPath, True);
        except
          // No partial write (BR21/R1): if the project add fails, roll back the
          // file we just created, then surface the access error.
          if TFile.Exists(LPlan.FullPath) then
            TFile.Delete(LPlan.FullPath);
          raise;
        end;
        LOutcome := faApplied;
      except
        on E: Exception do
        begin
          LOutcome := faAccessError;
          LError   := E.Message;
        end;
      end;
    end);
  except
    on E: Exception do
    begin
      LOutcome := faAccessError;
      LError   := E.Message;
    end;
  end;
  AError := LError;
  Result := LOutcome;
end;

// Create a new unit (optionally a paired VCL form) in the active project,
// confined to the project root via the pure UnitCreatePolicy (no clobber), then
// add it as a member. Rolls back the written file(s) if the project add fails
// (no partial write, BR21). The with-form variant is a hand-authored .pas+.dfm
// pair (R6 — verified live; degrades to the form-less unit if the IDE rejects
// the pairing).
// Public interface method — unchanged contract. Always emits a VCL form so the
// well-trained VCL behaviour is byte-identical; the framework-aware path is
// reached only via CreateNewUnitEx (CreateNewProject).
function TMCPProjectLifecycleService.CreateNewUnit(const AUnitName: string;
  AWithForm: Boolean; out AFilePath: string): Boolean;
begin
  Result := CreateNewUnitEx(AUnitName, AWithForm, False {VCL}, AFilePath);
end;

function TMCPProjectLifecycleService.CreateNewUnitEx(const AUnitName: string;
  AWithForm, AFmx: Boolean; out AFilePath: string): Boolean;
var
  LResult: Boolean;
  LPath: string;
begin
  LResult := False;
  LPath   := '';
  try
    TThread.Synchronize(nil, procedure
    var
      LProject: IOTAProject;
      LRoot, LDfm, LFormBase, LInstance, LUnitIdent: string;
      LPlan: TUnitCreatePlan;
    begin
      if not TFacadeShared.TryProject(LProject) then Exit;
      LRoot := TPath.GetDirectoryName(LProject.FileName);
      LPlan := TUnitCreatePolicy.ResolveUnitCreate(AUnitName + '.pas', LRoot, False,
        function(const APath: string): Boolean
        begin
          Result := TFile.Exists(APath);
        end);
      if not LPlan.Accepted then Exit;
      LDfm := '';
      try
        if AWithForm then
        begin
          LUnitIdent := LPlan.UnitName.Replace('.', '_', [rfReplaceAll]);
          LFormBase  := LUnitIdent;
          // The generators always append 'Form' to derive the class
          // (T<base>Form). Strip a trailing 'Form' from the unit name first so a
          // unit literally named 'MainForm' yields TMainForm, not the doubled
          // TMainFormForm. Length guard keeps a unit named 'Form' intact.
          if LFormBase.EndsWith('Form', True) and (LFormBase.Length > 4) then
            LFormBase := LFormBase.Substring(0, LFormBase.Length - 4);
          // Global instance/var name. Normally <base>Form (e.g. unit 'Foo' ->
          // FooForm), but that collides with the unit identifier when the unit is
          // named '<base>Form' itself (unit 'MainForm' -> var 'MainForm' ->
          // E2004 Identifier redeclared). Prefix with 'frm' in that case so the
          // project compiles out-of-the-box (unit MainForm -> var frmMain).
          LInstance := LFormBase + 'Form';
          if SameText(LInstance, LUnitIdent) then
            LInstance := 'frm' + LFormBase;
          if AFmx then
          begin
            TFile.WriteAllText(LPlan.FullPath,
              _NewFmxFormUnitSource(LPlan.UnitName, LFormBase, LInstance), TEncoding.UTF8);
            LDfm := ChangeFileExt(LPlan.FullPath, '.fmx');
            TFile.WriteAllText(LDfm, _NewFmxFormFmx(LFormBase, LInstance), TEncoding.UTF8);
          end
          else
          begin
            TFile.WriteAllText(LPlan.FullPath,
              _NewFormUnitSource(LPlan.UnitName, LFormBase, LInstance), TEncoding.UTF8);
            LDfm := ChangeFileExt(LPlan.FullPath, '.dfm');
            TFile.WriteAllText(LDfm, _NewFormDfm(LFormBase, LInstance), TEncoding.UTF8);
          end;
        end
        else
          TFile.WriteAllText(LPlan.FullPath,
            _NewPlainUnitSource(LPlan.UnitName), TEncoding.UTF8);
        try
          LProject.AddFile(LPlan.FullPath, True);
        except
          if TFile.Exists(LPlan.FullPath) then TFile.Delete(LPlan.FullPath);
          if (LDfm <> '') and TFile.Exists(LDfm) then TFile.Delete(LDfm);
          raise;
        end;
        LProject.Save(False, True);
        LPath   := LPlan.FullPath;
        LResult := True;
      except
        LResult := False;
        LPath   := '';
      end;
    end);
  except
    LResult := False;
    LPath   := '';
  end;
  AFilePath := LPath;
  Result    := LResult;
end;

function TMCPProjectLifecycleService.CreateNewProject(const AName,
  AProjectType, ADirectory: string; out ADProjPath: string;
  out AReason: string): Boolean;
var
  LApplied: Boolean;
  LProjPath, LReason: string;
begin
  LApplied  := False;
  LProjPath := '';
  LReason   := '';
  try
    TThread.Synchronize(nil, procedure
    var
      LKind: TNewProjectKind;
      LScratchRoot, LDir, LSourceExt, LSourcePath, LSource: string;
      LServices: IOTAModuleServices;
      LModule: IOTAModule;
      LFormPath: string;
      LDpr: string;
      LRunAt: Integer;
      LOpenAct: IOTAActionServices;
      LTestPath: string;
    begin
      try
        if not _ProjValidName(AName) then
        begin
          Exit;
        end;
        LKind := _ProjClassify(AProjectType);
        if LKind = npkUnsupported then
        begin
          Exit;
        end;
        LScratchRoot := TPath.Combine(TPath.GetTempPath, PROJ_SCRATCH_SUBDIR);
        if Trim(ADirectory) = '' then
          LDir := TPath.Combine(LScratchRoot, AName)
        else if TPath.IsPathRooted(ADirectory) then
          LDir := ADirectory
        else
          LDir := TPath.Combine(LScratchRoot, ADirectory);
        if not LDir.StartsWith(LScratchRoot, True) then
          Exit;
        if LKind = npkPackage then
          LSourceExt := '.dpk'
        else
          LSourceExt := '.dpr';
        LSourcePath := TPath.Combine(LDir, AName + LSourceExt);
        LProjPath   := TPath.Combine(LDir, AName + '.dproj');
        if TFile.Exists(LSourcePath) or TFile.Exists(LProjPath) then
        begin
          // Keep LProjPath pointing at the file that actually exists so the
          // caller can report WHERE the colliding project lives; signal the
          // distinct 'project-already-exists' reason so the handler raises a
          // clear structured error instead of an opaque applied:false (a name
          // collision is indistinguishable from a real failure otherwise).
          if not TFile.Exists(LProjPath) then
            LProjPath := LSourcePath;
          LReason := 'project-already-exists';
          Exit;
        end;
        if not Supports(BorlandIDEServices, IOTAModuleServices, LServices) then
        begin
          Exit;
        end;
        LSource := _ProjSource(AName, LKind);
        TDirectory.CreateDirectory(LDir);
        LModule := LServices.CreateModule(
          TNewProjectCreator.Create(LKind, LSourcePath, LSource));
        if not Assigned(LModule) then
        begin
          LProjPath := '';
          Exit;
        end;
        LModule.Save(False, True);
        if not TFile.Exists(LProjPath) then
        begin
          LProjPath := '';
          Exit;
        end;
        if LKind in [npkVCL, npkFMX] then
        begin
          // AFmx := FMX kind, so an FMX project gets an FMX main form (FMX.Forms
          // + .fmx) instead of the old hardcoded VCL form welded onto an
          // FMX.Forms .dpr (which produced the create error + a VCL .dproj).
          CreateNewUnitEx('MainForm', True, LKind = npkFMX, LFormPath);
          if LFormPath <> '' then
          begin
            if Supports(BorlandIDEServices, IOTAActionServices, LOpenAct) then
              LOpenAct.OpenFile(LFormPath);
            // CreateNewUnit's LProject.AddFile wires the form into the .dpr
            // `uses`, but the IDE never inserts the matching
            // Application.CreateForm statement — so the project would start with
            // no main form and Application.Run would exit immediately. Inject it
            // through the live buffer (never a raw disk write: the .dpr is an
            // open module now and disk would be clobbered). CreateNewUnit always
            // creates unit 'MainForm' => class TMainForm + var frmMain, so the
            // names are fixed for both VCL and FMX.
            LDpr := _ReadActiveDprContent;
            if (LDpr <> '') and (Pos('Application.CreateForm', LDpr) = 0) then
            begin
              LRunAt := Pos('Application.Run;', LDpr);
              if LRunAt > 0 then
              begin
                LDpr := Copy(LDpr, 1, LRunAt - 1) +
                  'Application.CreateForm(TMainForm, frmMain);' + sLineBreak +
                  '  ' + Copy(LDpr, LRunAt, MaxInt);
                TFacadeShared.WriteUnitSource(LSourcePath, LDpr);
              end;
            end;
          end;
        end;
        if LKind = npkDUnitX then
        begin
          // Ship a sample [TestFixture] unit (like the official DUnitX wizard) so
          // the runner has something to discover via RTTI. CreateNewUnitEx writes a
          // plain unit AND wires it into the .dpr `uses` (so its initialization /
          // RTTI registration is linked); we then replace its body with the fixture
          // source on disk (it is not open in an editor yet) and open it. The unit
          // name must match the .pas file, so it is derived from the created path.
          if CreateNewUnitEx(AName + 'Tests', False, False, LTestPath)
             and (LTestPath <> '') then
          begin
            TFacadeShared.WriteUnitSource(LTestPath,
              _NewDUnitXTestUnitSource(
                TPath.GetFileNameWithoutExtension(LTestPath)));
            if Supports(BorlandIDEServices, IOTAActionServices, LOpenAct) then
              LOpenAct.OpenFile(LTestPath);
          end;
        end;
        // C4: scrub the inherited design-package list LAST — after the form/
        // DUnitX unit creation above (whose saves rewrite the noisy
        // DCC_UsePackage onto disk). Two prongs, both side-effect-free for the
        // .dpr: (1) Remove it from the in-memory project options so a later
        // user-initiated project save stays clean; (2) strip it textually from
        // the .dproj already on disk so the generated artifact is clean NOW.
        // Deliberately NO LModule.Save here — saving the project module could
        // regenerate the .dpr and clobber the Application.CreateForm injection
        // above when the .dpr is not buffer-backed.
        try
          _ClearInheritedUsePackages(LModule);
        except
        end;
        try
          _StripUsePackagesFromDproj(LProjPath);
        except
        end;
        LApplied := True;
      except
        on E: Exception do
        begin
          LProjPath := '';
          LApplied  := False;
        end;
      end;
    end);
  except
    LApplied  := False;
    LProjPath := '';
  end;
  ADProjPath := LProjPath;
  AReason    := LReason;
  Result     := LApplied;
end;

function TMCPProjectLifecycleService.CloseAllProjects: Boolean;
var
  LDone: Boolean;
begin
  LDone := False;
  try
    TThread.Synchronize(nil, procedure
    var
      LMS: IOTAModuleServices;
    begin
      try
        if Supports(BorlandIDEServices, IOTAModuleServices, LMS) then
          LDone := LMS.CloseAll;
      except
        LDone := False;
      end;
    end);
  except
    LDone := False;
  end;
  Result := LDone;
end;

function NewMCPProjectLifecycleService: IMCPProjectLifecycleService;
begin
  Result := TMCPProjectLifecycleService.Create;
end;

end.
