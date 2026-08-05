unit Aefos.MCP.OTA.BuildService;

{
  Build / compile operations, extracted from the TMCPWorkspaceFacade god-object as
  a focused service of the SOLID split (audit S6 / facade split).

  Owns StartBuild, QueryBuildResult, CancelBuild, GetCompilerMessages and
  CleanProject, plus the build-only _ReadStructureViewErrors fallback. Crucially it
  also OWNS the build STATE (FBuildState / FBuildErrorLog) the facade used to hold:
  StartBuild captures the synchronous msbuild outcome into these fields and
  QueryBuildResult / GetCompilerMessages read them back. No other domain touches
  that state, so the service is self-contained — no IFacadeContext needed.

  Bodies moved VERBATIM from the facade (only the class qualifier changes), so
  behaviour is identical. The facade keeps its frozen IMCPWorkspaceFacade methods
  and delegates each to a refcounted FBuild field constructed once. Shared work
  comes from already-separate units: TryProject / TryModuleServices / TryBuffer
  / IsModuleModified (FacadeShared), NormalizeBuildMode (BuildRunPolicy) and
  TProcessRunner.Run (Aefos.Tools.Process).
}

interface

uses
  Aefos.MCP.Types;

type
  IMCPBuildService = interface
    ['{8C2A1E94-6D75-4B30-9F38-2A6C1E5B8D74}']
    function StartBuild(const AMode: string; out AError: string): Boolean;
    function QueryBuildResult: TMCPBuildState;
    function CancelBuild: Boolean;
    function GetCompilerMessages: TArray<TMCPCompilerMessage>;
    function CleanProject: Boolean;
  end;

// Factory — the facade calls this once in its constructor.
function NewMCPBuildService: IMCPBuildService;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.Generics.Collections,
  System.RegularExpressions,
  ToolsAPI,
  StructureViewAPI,
  Aefos.Tools.Process,
  Aefos.MCP.OTA.FacadeShared,
  Aefos.MCP.OTA.BuildRunPolicy;

type
  TMCPBuildService = class(TInterfacedObject, IMCPBuildService)
  private
    // Captured outcome of the last StartBuild (ESP-091, S2). The msbuild build is
    // synchronous, so StartBuild stores the real compiler result here and the
    // subsequent QueryBuildResult poll returns it (no faked success, R6).
    FBuildState: TMCPBuildState;
    // Deterministic path of the last build's diagnostics log written by StartBuild
    // (msbuild file logger). GetCompilerMessages re-reads + parses it on demand.
    FBuildErrorLog: string;
  public
    constructor Create;
    function StartBuild(const AMode: string; out AError: string): Boolean;
    function QueryBuildResult: TMCPBuildState;
    function CancelBuild: Boolean;
    function GetCompilerMessages: TArray<TMCPCompilerMessage>;
    function CleanProject: Boolean;
  end;

// OTA-native, BUILD-FREE error read: the IDE Structure view ('Structure' pane)
// carries an 'Errors' root node populated by Error Insight for the ACTIVE unit
// (ToolsAPI 37.0 — BorlandIDEServices supports IOTAStructureView; the node types
// live in StructureViewAPI, ErrorsNodeType). We walk the live structure context,
// find the 'Errors' root and read each child caption (e.g.
// "E2003 Undeclared identifier: 'cur' at line 70 (70:5)"), parsing the (line:col)
// tail. This is the instant, no-build complement to the msbuild-log read: it sees
// only the active file and Error-Insight-flavoured diagnostics (it will miss
// link/cross-unit errors like F2063 that a full build reports), so it is used as a
// FALLBACK when no build log exists. All on the main thread (BR7).
function _ReadStructureViewErrors: TArray<TMCPCompilerMessage>;
var
  LResult: TArray<TMCPCompilerMessage>;
begin
  LResult := [];
  try
    TThread.Synchronize(nil, procedure
    var
      LView: IOTAStructureView;
      LCtx: IOTAStructureContext;
      LRoot, LChild: IOTAStructureNode;
      LBuffer: IOTAEditBuffer;
      LPath, LCaption: string;
      LFor, LChildFor: Integer;
      LMsg: TMCPCompilerMessage;
      LMatch: TMatch;
      LList: TList<TMCPCompilerMessage>;
    begin
      if not Supports(BorlandIDEServices, IOTAStructureView, LView) then Exit;
      LCtx := LView.GetStructureContext;
      if not Assigned(LCtx) then Exit;
      LPath := '';
      if TFacadeShared.TryBuffer(LBuffer) then LPath := LBuffer.FileName;
      LList := TList<TMCPCompilerMessage>.Create;
      try
        for LFor := 0 to LCtx.RootNodeCount - 1 do
        begin
          LRoot := LCtx.GetRootStructureNode(LFor);
          if not Assigned(LRoot) then Continue;
          if not SameText(LRoot.Caption, 'Errors') then Continue;
          for LChildFor := 0 to LRoot.ChildCount - 1 do
          begin
            LChild := LRoot.Child[LChildFor];
            if not Assigned(LChild) then Continue;
            LCaption := LChild.Caption;
            if Trim(LCaption) = '' then Continue;
            LMsg := Default(TMCPCompilerMessage);
            LMsg.Path     := LPath;
            LMsg.Severity := csError;
            LMsg.Text     := LCaption;
            LMatch := TRegEx.Match(LCaption, '\((\d+):(\d+)\)');
            if LMatch.Success then
            begin
              LMsg.Line   := StrToIntDef(LMatch.Groups[1].Value, 0);
              LMsg.Column := StrToIntDef(LMatch.Groups[2].Value, 0);
            end;
            LList.Add(LMsg);
          end;
        end;
        LResult := LList.ToArray;
      finally
        LList.Free;
      end;
    end);
  except
    LResult := [];
  end;
  Result := LResult;
end;

constructor TMCPBuildService.Create;
begin
  inherited Create;
  // No build started yet — QueryBuildResult reports cancelled until StartBuild
  // captures a real compiler outcome (ESP-091, S2).
  FBuildState := bsCancelled;
end;

function TMCPBuildService.StartBuild(const AMode: string;
  out AError: string): Boolean;
const
  CBuildTimeoutMs = 300000; // 5 min hard cap (child is killed past this)
var
  LFullBuild: Boolean;
  LReason, LDProj, LConfig, LPlatform, LRoot, LLog, LComSpec, LArgs,
    LTarget, LDir: string;
  LProc: TToolProcessResult;
begin
  FBuildErrorLog := '';
  if not TBuildRunPolicy.NormalizeBuildMode(AMode, LFullBuild, LReason) then
  begin
    FBuildState := bsFailed;
    AError      := LReason;
    Exit(False);
  end;
  // Flush unsaved editor buffers, then resolve the .dproj path, active
  // config/platform and the IDE root — all on the main thread (OTA, BR7).
  // msbuild compiles DISK state, so without the save it would build the stale
  // on-disk source and miss the agent's just-made edits (the old in-IDE
  // IOTAProjectBuilder compiled the in-memory buffers). Sentinel-degrade on any
  // failure (BR3).
  LDProj := ''; LConfig := ''; LPlatform := ''; LRoot := '';
  try
    TThread.Synchronize(nil, procedure
    var
      LProject: IOTAProject;
      LServices: IOTAServices;
      LMS: IOTAModuleServices;
      LIdx: Integer;
      LModule: IOTAModule;
    begin
      if TFacadeShared.TryModuleServices(LMS) then
        for LIdx := 0 to LMS.ModuleCount - 1 do
        begin
          LModule := LMS.Modules[LIdx];
          if TFacadeShared.IsModuleModified(LModule) then
            LModule.Save(False, True);
        end;
      if TFacadeShared.TryProject(LProject) then
      begin
        LDProj    := LProject.FileName;
        LConfig   := LProject.CurrentConfiguration;
        LPlatform := LProject.CurrentPlatform;
      end;
      if Supports(BorlandIDEServices, IOTAServices, LServices) then
        LRoot := LServices.GetRootDirectory;
    end);
  except
    LDProj := '';
  end;
  if (LDProj = '') or not TFile.Exists(LDProj) then
  begin
    FBuildState := bsFailed;
    AError      := 'no-active-project';
    Exit(False);
  end;
  if LRoot = '' then
  begin
    FBuildState := bsFailed;
    AError      := 'no-ide-root';
    Exit(False);
  end;
  if LConfig = '' then LConfig := 'Debug';
  if LPlatform = '' then LPlatform := 'Win32';
  if LFullBuild then LTarget := 'Build' else LTarget := 'Make';
  LDir := TPath.GetDirectoryName(LDProj);
  LLog := TPath.Combine(LDir, '__aefos-build-errors.log');
  try TFile.Delete(LLog); except end;

  LComSpec := GetEnvironmentVariable('ComSpec');
  if LComSpec = '' then LComSpec := 'cmd.exe';
  // cmd /s /c "<rsvars> && msbuild ...": with /s, cmd strips only the outermost
  // pair of quotes and runs the rest verbatim, so the inner "quoted paths" survive.
  LArgs := Format('/s /c ""%s\bin\rsvars.bat" && msbuild "%s" /t:%s ' +
    '/p:Config=%s /p:Platform=%s /nologo /noconlog ' +
    '/flp:LogFile="%s";Verbosity=normal"',
    [LRoot, LDProj, LTarget, LConfig, LPlatform, LLog]);

  LProc := TProcessRunner.Run(LComSpec, LArgs, '', LDir, CBuildTimeoutMs);

  if LProc.Outcome = poSpawnError then
  begin
    FBuildState := bsFailed;
    AError      := 'build-spawn-error';
    Exit(False);
  end;
  // The log exists from here on (even on failure) for GetCompilerMessages.
  FBuildErrorLog := LLog;
  if LProc.Outcome = poTimedOut then
  begin
    FBuildState := bsFailed;
    AError      := 'build-timeout';
    Exit(False);
  end;
  if LProc.ExitCode = 0 then
    FBuildState := bsSucceeded
  else
    FBuildState := bsFailed;
  AError := '';
  Result := True;
end;

function TMCPBuildService.QueryBuildResult: TMCPBuildState;
begin
  // The OTA build is synchronous (StartBuild blocks until the compiler returns),
  // so the captured outcome is already final by the first poll.
  Result := FBuildState;
end;

function TMCPBuildService.CancelBuild: Boolean;
begin
  // The OTA BuildProject path is synchronous — StartBuild does not return until
  // the compiler has finished — so there is never an in-flight build to abort by
  // the time a cancel could be issued. Honest no-op (never a faked success).
  Result := False;
end;

// Parse the diagnostics log written by the last StartBuild (msbuild file logger).
// OTA still has no way to read back the Messages/Build pane — every
// IOTAMessageServices method is add-only and the compile notifiers report only
// pass/fail (verified against ToolsAPI 37.0) — so the build, not a read, is what
// captures the text. This read just parses the cached file and NEVER triggers a
// build (BR8). Each line is `Path(Line[,Col]): <sev> <Code>: <text> [project]`
// (DCC32/BRCC32 via msbuild); non-diagnostic build noise does not match and is
// dropped. '' / missing log (no build yet) -> honest []. Relative paths resolve
// against the .dproj directory; the DCC code (E2004/F2063/W1010) is kept in Text.
function TMCPBuildService.GetCompilerMessages: TArray<TMCPCompilerMessage>;
const
  CDiagPattern =
    '^(.+?)\((\d+)(?:,(\d+))?\)\s*:\s*' +
    '(error|fatal error|warning|hint|message)\s+([A-Za-z]?\d+)\s*:\s*' +
    '(.*?)\s*(?:\[[^\]]*\])?$';
var
  LLog, LText, LDir, LLine, LSev, LKey: string;
  LLines: TArray<string>;
  LRegex: TRegEx;
  LMatch: TMatch;
  LMsg: TMCPCompilerMessage;
  LList: TList<TMCPCompilerMessage>;
  LSeen: TStringList;
begin
  Result := [];
  LLog := FBuildErrorLog;
  // No build log yet (never built this session, or it was cleared) -> fall back to
  // the live, build-free Structure-view Error Insight read for the active unit.
  // After a build the log is authoritative (full project, incl. link/cross-unit
  // errors the structure pane does not show), so it takes precedence.
  if (LLog = '') or not TFile.Exists(LLog) then
    Exit(_ReadStructureViewErrors);
  try
    LText := TFile.ReadAllText(LLog);
  except
    Exit;
  end;
  LDir   := TPath.GetDirectoryName(LLog);
  LRegex := TRegEx.Create(CDiagPattern, [roIgnoreCase]);
  LList  := TList<TMCPCompilerMessage>.Create;
  LSeen  := TStringList.Create;
  try
    LLines := LText.Split([#13#10, #10], TStringSplitOptions.None);
    for LLine in LLines do
    begin
      LMatch := LRegex.Match(LLine.Trim);
      if not LMatch.Success then Continue;
      LMsg := Default(TMCPCompilerMessage);
      LMsg.Path := LMatch.Groups[1].Value;
      if not TPath.IsPathRooted(LMsg.Path) then
        LMsg.Path := TPath.Combine(LDir, LMsg.Path);
      LMsg.Line   := StrToIntDef(LMatch.Groups[2].Value, 0);
      LMsg.Column := StrToIntDef(LMatch.Groups[3].Value, 0); // '' -> 0
      LSev := LowerCase(LMatch.Groups[4].Value);
      if Pos('error', LSev) > 0 then
        LMsg.Severity := csError
      else if LSev = 'warning' then
        LMsg.Severity := csWarning
      else
        LMsg.Severity := csHint;
      // Keep the DCC code so the agent can reference it (e.g. "E2004: ...").
      LMsg.Text := Trim(LMatch.Groups[5].Value + ': ' + LMatch.Groups[6].Value);
      // Dedup: at normal verbosity msbuild prints each diagnostic inline AND again
      // in the final "Build FAILED" error summary, so every error is logged twice.
      LKey := Format('%s|%d|%d|%s', [LMsg.Path, LMsg.Line, LMsg.Column, LMsg.Text]);
      if LSeen.IndexOf(LKey) < 0 then
      begin
        LSeen.Add(LKey);
        LList.Add(LMsg);
      end;
    end;
    Result := LList.ToArray;
  finally
    LSeen.Free;
    LList.Free;
  end;
end;

// Clean the scratch project's build output via IOTAProjectBuilder (ESP-091, S2 /
// ADR-091-07 / R7). cmOTAClean removes the output files the build generated;
// the effect is read-verified by GetProjectOutputDir / GetDCUOutputDir plus a
// filesystem check that the .exe / .dcu artifacts are gone. Scratch-scoped: the
// active project is the campaign's scratch project; RADShell is never cleaned.
function TMCPBuildService.CleanProject: Boolean;
var
  LOk: Boolean;
begin
  LOk := False;
  try
    TThread.Synchronize(nil, procedure
    var
      LProject: IOTAProject;
      LBuilder: IOTAProjectBuilder;
    begin
      if not TFacadeShared.TryProject(LProject) then Exit;
      LBuilder := LProject.ProjectBuilder;
      if not Assigned(LBuilder) then Exit;
      LOk := LBuilder.BuildProject(cmOTAClean, False, True);
    end);
  except
    LOk := False;
  end;
  Result := LOk;
end;

function NewMCPBuildService: IMCPBuildService;
begin
  Result := TMCPBuildService.Create;
end;

end.
