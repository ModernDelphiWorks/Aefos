unit Aefos.Lazarus.ConsoleProjectDescriptor;

{ Aefos AI - Lazarus edition: dialog-free console-application project descriptor.

  The MCP CreateProjectConsole tool must create a console application WITHOUT
  showing any modal dialog, because the tool runs on the IDE main thread while an
  in-process named-pipe worker waits on the result - a modal would pump the main
  thread and BLOCK the pipe (the class of hang killed in #276/#277).

  The IDE's own registered console descriptor CANNOT be reused for this: its
  InitProject pops a modal "New console application" options form
  (C:\lazarus\ide\projectdescriptortypes.pas:392 -
  TCustomApplicationOptionsForm.ShowModal), which is exactly the blocking dialog
  we must avoid. So this descriptor reproduces the SAME default console app the
  IDE would generate when the user accepts that form's defaults (application
  class name 'TMyApplication', empty title, and every code-generation option ON -
  the form seeds all of them checked, frmcustomapplicationoptions.pas:110) but
  emits the source directly, with no dialog.

  It is NOT registered with RegisterProjectDescriptor (that would add an Aefos
  entry to the user's File > New... dialog). It is instantiated per CreateProject
  Console call, handed to LazarusIDE.DoNewProject, and released by the caller
  (TProject.Create does not retain the descriptor - C:\lazarus\ide\project.pp
  :2753 - so the caller Releases its single reference after DoNewProject).

  Mode objfpc/H+ (the native LCL/IDEIntf string domain is UTF-8 AnsiString), so
  the emitted Pascal source and the IDEIntf calls need no UnicodeString<->Ansi
  friction. All literals are ASCII, so the file needs no BOM. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils,
  System.UITypes, // TModalResult / mrOk (canonical FPC 3.2+ name; plain UITypes is deprecated)
  ProjectIntf,   // TProjectDescriptor / TLazProject / TLazProjectFile / project flags
  LazIDEIntf;    // LazarusIDE (CreateStartFiles opens the main file in the editor)

type
  { Dialog-free console-application descriptor - see the unit header. Mirrors
    TProjectConsoleApplicationDescriptor's flags and generated source, minus the
    interactive options form. }
  TAefosConsoleProjectDescriptor = class(TProjectDescriptor)
  public
    constructor Create; override;
    function GetLocalizedName: string; override;
    function InitProject(AProject: TLazProject): TModalResult; override;
    function CreateStartFiles(AProject: TLazProject): TModalResult; override;
  end;

implementation

constructor TAefosConsoleProjectDescriptor.Create;
begin
  inherited Create;
  // Same identity + flags as the IDE's console descriptor
  // (projectdescriptortypes.pas:362): a console app has no form-creation, title
  // or scaled main-unit statements and uses the default compiler options.
  Name := ProjDescNameConsoleApplication;
  Flags := Flags - [pfMainUnitHasCreateFormStatements,
                    pfMainUnitHasTitleStatement,
                    pfMainUnitHasScaledStatement]
                 + [pfUseDefaultCompilerOptions];
end;

function TAefosConsoleProjectDescriptor.GetLocalizedName: string;
begin
  Result := ProjDescNameConsoleApplication;
end;

function TAefosConsoleProjectDescriptor.InitProject(
  AProject: TLazProject): TModalResult;
var
  LSource: TStringList;
  LMainFile: TLazProjectFile;
begin
  Result := inherited InitProject(AProject);
  if Result <> mrOk then
    Exit;

  LMainFile := AProject.CreateProjectFile('project1.lpr');
  LMainFile.IsPartOfProject := True;
  AProject.AddFile(LMainFile, False);
  AProject.MainFileID := 0;

  AProject.LazCompilerOptions.UnitOutputDirectory :=
    'lib' + PathDelim + '$(TargetCPU)-$(TargetOS)';
  AProject.LazCompilerOptions.TargetFilename := 'project1';
  AProject.LazCompilerOptions.Win32GraphicApp := False;

  // Byte-for-byte the default output of the IDE's console descriptor with the
  // options form left at its defaults: class name 'TMyApplication', empty title,
  // all code-generation options enabled (constructor / destructor / help / stop-
  // on-error / check-options). This keeps the CreateProjectConsole result identical
  // to what a user would get accepting the New-console-application defaults.
  LSource := TStringList.Create;
  try
    LSource.Add('program Project1;');
    LSource.Add('');
    LSource.Add('{$mode objfpc}{$H+}');
    LSource.Add('');
    LSource.Add('uses');
    LSource.Add('  {$IFDEF UNIX}');
    LSource.Add('  cthreads,');
    LSource.Add('  {$ENDIF}');
    LSource.Add('  Classes, SysUtils, CustApp');
    LSource.Add('  { you can add units after this };');
    LSource.Add('');
    LSource.Add('type');
    LSource.Add('');
    LSource.Add('  { TMyApplication }');
    LSource.Add('');
    LSource.Add('  TMyApplication = class(TCustomApplication)');
    LSource.Add('  protected');
    LSource.Add('    procedure DoRun; override;');
    LSource.Add('  public');
    LSource.Add('    constructor Create(TheOwner: TComponent); override;');
    LSource.Add('    destructor Destroy; override;');
    LSource.Add('    procedure WriteHelp; virtual;');
    LSource.Add('  end;');
    LSource.Add('');
    LSource.Add('{ TMyApplication }');
    LSource.Add('');
    LSource.Add('procedure TMyApplication.DoRun;');
    LSource.Add('var');
    LSource.Add('  ErrorMsg: String;');
    LSource.Add('begin');
    LSource.Add('  // quick check parameters');
    LSource.Add('  ErrorMsg:=CheckOptions(''h'',''help'');');
    LSource.Add('  if ErrorMsg<>'''' then begin');
    LSource.Add('    ShowException(Exception.Create(ErrorMsg));');
    LSource.Add('    Terminate;');
    LSource.Add('    Exit;');
    LSource.Add('  end;');
    LSource.Add('');
    LSource.Add('  // parse parameters');
    LSource.Add('  if HasOption(''h'',''help'') then begin');
    LSource.Add('    WriteHelp;');
    LSource.Add('    Terminate;');
    LSource.Add('    Exit;');
    LSource.Add('  end;');
    LSource.Add('');
    LSource.Add('  { add your program here }');
    LSource.Add('');
    LSource.Add('  // stop program loop');
    LSource.Add('  Terminate;');
    LSource.Add('end;');
    LSource.Add('');
    LSource.Add('constructor TMyApplication.Create(TheOwner: TComponent);');
    LSource.Add('begin');
    LSource.Add('  inherited Create(TheOwner);');
    LSource.Add('  StopOnException:=True;');
    LSource.Add('end;');
    LSource.Add('');
    LSource.Add('destructor TMyApplication.Destroy;');
    LSource.Add('begin');
    LSource.Add('  inherited Destroy;');
    LSource.Add('end;');
    LSource.Add('');
    LSource.Add('procedure TMyApplication.WriteHelp;');
    LSource.Add('begin');
    LSource.Add('  { add your help code here }');
    LSource.Add('  writeln(''Usage: '',ExeName,'' -h'');');
    LSource.Add('end;');
    LSource.Add('');
    LSource.Add('var');
    LSource.Add('  Application: TMyApplication;');
    LSource.Add('begin');
    LSource.Add('  Application:=TMyApplication.Create(nil);');
    LSource.Add('  Application.Run;');
    LSource.Add('  Application.Free;');
    LSource.Add('end.');
    LSource.Add('');
    AProject.MainFile.SetSourceText(LSource.Text, True);
  finally
    LSource.Free;
  end;
end;

function TAefosConsoleProjectDescriptor.CreateStartFiles(
  AProject: TLazProject): TModalResult;
begin
  // Open the generated main file in the editor - exactly as the IDE console
  // descriptor does (projectdescriptortypes.pas:523). ofProjectLoading keeps it a
  // project-open (no re-add prompt), ofRegularFile a plain source open.
  Result := LazarusIDE.DoOpenEditorFile(AProject.MainFile.Filename, -1, -1,
    [ofProjectLoading, ofRegularFile]);
end;

end.
