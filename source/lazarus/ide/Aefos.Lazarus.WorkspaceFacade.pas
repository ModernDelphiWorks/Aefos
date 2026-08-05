unit Aefos.Lazarus.WorkspaceFacade;

{ Aefos AI - Lazarus edition: MCP workspace facade backend (Phase F seam).

  This is the Lazarus twin of the Delphi OTA facade
  (source\mcp\OTA\Aefos.MCP.OTA.WorkspaceFacade.pas). The OTA-free MCP core
  (source\mcp\Core) talks to the IDE ONLY through IMCPWorkspaceFacade
  (Aefos.MCP.Types); on RAD Studio the implementation is ToolsAPI, here it is
  Lazarus IDEIntf. The core, the transport and every tool policy are shared,
  compiler-portable code - only this backend changes.

  Scope of THIS phase (F): the CORE READ SLICE only, implemented honestly:
    - CurrentIdeViewIntent  -> RULE #1's Lazarus form (see below).
    - GetActiveUnit / GetEditorFullContent -> live source text via
      SourceEditorManagerIntf.ActiveEditor (srceditorintf.pas:377,325) and its
      SourceText property (srceditorintf.pas:193).
    - GetEditorActiveFile   -> active editor unit name + path
      (srceditorintf.pas:184 FileName).
    - ListIDEActions        -> IDE command catalog via IDECommandList
      (idecommands.pas:800; FindCommandByName :659; category list is TList).
  Every other IMCPWorkspaceFacade member raises ENotSupportedException naming
  the phase that will implement it (H = editor writes, I = project/CodeTools,
  J = designer) - never a silent stub that lies about doing nothing.

  RULE #1 on Lazarus (CLAUDE.md "each command is its own guardian"): Delphi is
  MODAL (a module shows EITHER the Form Designer OR the code editor), so the
  Delphi read is "which view is active". Lazarus is NOT modal - the source
  editor and the form designer are separate windows that can both be visible.
  So the doctrine's mechanism changes (00-master-plan.md, 02-designer.md):

    A DESIGN command requires a LIVE DESIGNER for the active unit whose form is
    currently SHOWN on screen (that is the module's active view) -- NOT that the
    IDE holds OS keyboard focus.

  Implemented rule (this file):
    - No active source editor                    -> tiNeutral (guard off).
    - Active editor, NO live designer            -> tiCode.
    - Active editor, designer NOT shown on screen -> tiCode.
    - Active editor, designer form IS shown       -> tiDesign.
  "Live designer" = LazarusIDE.GetDesignerForProjectEditor(editor, LoadForm:=
  False) <> nil (lazideintf.pas:447) - LoadForm False means "report only an
  already-loaded designer, never create one". "Shown" = LDesignForm.IsVisible
  (the Visible chain up to the top-level window), which is TRUE for a floating OR a
  docked (anchordocking) designer that is on screen and FALSE for a background dock
  tab -- and is INDEPENDENT of OS focus. An earlier version keyed on
  Screen.ActiveCustomForm (OS-foreground); that broke the agent flow completely,
  because the CLI drives the IDE while the user watches the chat, so lazarus.exe is
  never the foreground window and every mutation was rejected wrong-view-code even
  right after a successful OpenFormDesigner (reproduced 2026-07-20). Delphi's
  IOTAModule.CurrentEditor is focus-independent; this now matches it. A
  TDataModule/TFrame LookupRoot (not a TCustomForm) still defaults to tiCode.

  Mode: delphiunicode, matching Aefos.MCP.Types so the interface's `string`
  (= UnicodeString) signatures are satisfied verbatim. The LCL/IDEIntf boundary
  is UTF-8 AnsiString, so every value crossing in/out is converted explicitly
  through LazUTF8 (UTF8ToUTF16 / UTF16ToUTF8) - never left to the platform's
  ANSI codepage. All literals here are ASCII, so the file needs no BOM. }

{$mode delphiunicode}

interface

uses
  Classes,
  SysUtils,
  SrcEditorIntf,    // TSourceEditorInterface appears in the private helper signatures
  Aefos.MCP.Types,
  Aefos.MCP.IntentGuard;

type
  { Lazarus IDEIntf backend for the MCP workspace facade. Refcounted
    (TInterfacedObject) so the composition root holds it as an interface and
    lifetime is automatic, exactly like the OTA facade. Only the read slice is
    live; the rest raise ENotSupportedException (phase H+). }
  TAefosLazWorkspaceFacade = class(TInterfacedObject, IMCPWorkspaceFacade,
    IMCPFormCapture)
  private
    { TRANSIENT transfer slot for the just-finished StartBuild outcome. Lazarus's
      DoBuildProject is SYNCHRONOUS, so StartBuild records the result HERE and the
      registrar reads it back immediately via QueryBuildResult and stores it KEYED
      by build_id in the BuildManager (the source of truth for GetBuildStatus).
      This field is NOT the async state store - it is only ever written by one
      StartBuild and read by the very next QueryBuildResult on the same worker,
      with the registrar's single-active-build reservation keeping any concurrent
      build out of that window, so it never cross-talks between build_ids. Read/
      written only on the IDE main thread (both marshalled), so no lock is needed. }
    FLastBuildState: TMCPBuildState;
    { UTF-8 (LCL) -> UTF-16 (MCP core) boundary conversion. }
    class function _FromLcl(const AValue: AnsiString): UnicodeString; static;
    { UTF-16 (MCP core) -> UTF-8 (LCL) boundary conversion - the write twin of
      _FromLcl. LazUTF8.UTF16ToUTF8 returns a CP_ACP AnsiString carrying UTF-8
      bytes (the LCL convention), so the value passes to IDEIntf `string`
      parameters WITHOUT a lossy DefaultSystemCodePage reconversion. }
    class function _ToLcl(const AValue: UnicodeString): AnsiString; static;
    { Last path element of a UnicodeString path, without going through an ANSI
      SysUtils ExtractFileName (which would round-trip via the ANSI codepage). }
    class function _FileNameOf(const APath: UnicodeString): UnicodeString; static;
    { Live source text of the active editor; False when none is active. }
    function _ActiveEditorText(out AText: UnicodeString): Boolean;
    { The active source editor, or nil. }
    class function _ActiveEditor: TSourceEditorInterface; static;
    { The source editor showing AUnitPath (by full filename), or nil. }
    class function _ResolveEditor(const AUnitPath: UnicodeString): TSourceEditorInterface; static;
    { RULE #1 "end in Code" seam (the Lazarus twin of EnsureCodeView): make
      AEditor the active editor and bring its source window to the front, focused
      - so a code write LANDS AND ENDS in the editor, even if a Form Designer was
      up (sourceeditor.pp:9516 SetActiveEditor -> window + page; :10102
      ShowActiveWindowOnTop -> IDEWindowCreators.ShowForm + FocusEditor). }
    class procedure _EnsureCodeEditorFront(AEditor: TSourceEditorInterface); static;
    { One undoable whole-buffer replace of AEditor's live buffer with ANew.
      Wrapped in BeginUndoBlock/EndUndoBlock so the whole tool call is a SINGLE
      undo step (parity with the OTA single IOTAEditWriter). ReplaceLines routes
      through SynEdit's SetTextBetweenPoints - an undoable edit that also marks
      the buffer Modified, so the IDE prompts to save. False when read-only/no
      editor. Assumes the caller already flipped to Code. }
    class function _WriteWholeBuffer(AEditor: TSourceEditorInterface;
      const ANew: UnicodeString): Boolean; static;
    { Rewrite every CRLF / lone CR / lone LF in AText to AEol, so an anchor the
      agent sent with LF still matches a buffer stored CRLF, and the replacement
      lands with the buffer's own EOL. Pure UnicodeString - no AnsiString round-
      trip that would corrupt non-ASCII source (see EditSurgery). }
    class function _NormalizeEol(const AText, AEol: UnicodeString): UnicodeString; static;
    { True when the active project is VIRTUAL (never saved). IsVirtual stays true
      while the MAIN UNIT is virtual (project.pp:4247), even after ProjectInfoFile
      is set - so a plain DoSaveAll pops the native "Save project" dialog that
      blocks the in-process MCP pipe. A virtual save is routed through
      _SaveVirtualProjectReal (real save-as into the workspace home). }
    class function _ActiveProjectIsVirtual: Boolean; static;
    { Persist a VIRTUAL project to disk for real - no dialog, no test-dir copy.
      The IDE's SaveProject forces a "Save As" dialog for a never-saved project
      (SaveProjectInfo -> ShowSaveProjectAsDialog for the .lpi; each virtual unit
      -> ShowSaveFileAsDialog). Both instantiate IDESaveDialogClass and call
      Execute. We temporarily swap that class for TAefosSilentSaveDialog, which
      silently redirects every suggested filename into the project's workspace
      home, then DoSaveAll writes the .lpi + all units to disk under the chosen
      name and the project becomes NON-virtual (Save state clears). The class
      swap is scoped to THIS call (restored in a finally) so it only ever affects
      Aefos's own save - the dev's manual Save-As keeps the native dialog.
      Falls back to sfSaveToTestDir if a real home cannot be derived. }
    class function _SaveVirtualProjectReal: Boolean; static;
    { Derive the on-disk home (path-delimited absolute dir) and the sanitized
      Pascal-identifier project name for the active virtual project. Prefers the
      ProjectInfoFile set at CreateNewProject time; else builds one under
      %APPDATA%\Aefos\lazarus-workspace\<title>. False when neither is resolvable. }
    class function _ResolveVirtualHome(out AHomeDir, AMainName: AnsiString): Boolean; static;
    { Fold an arbitrary name down to a valid Pascal unit identifier (leading
      letter/underscore, then alnum/underscore); 'project' when nothing survives.
      Operates on the LCL UTF-8 AnsiString - non-ASCII bytes (never valid in an
      identifier) are dropped. }
    class function _SanitizeUnitName(const AName: AnsiString): AnsiString; static;
    { Pure safety gate for ExecuteIDEAction - the Lazarus twin of the OTA
      TFormUsesWritePolicy.ClassifyIDEAction (source\mcp\OTA\...FormUsesWrite
      Policy.pas:178). Refuses an empty name and any name carrying a hard-block
      token (exit/quit/terminate/kill/erase/uninstall -> 'destructive-action-
      refused') or a soft-block token (delete/remove/clean/revert/reset/drop ->
      'destructive-action-soft-blocked') BEFORE any lookup. This is defence in
      depth UNDER the consent gate the MCP handler already applies. }
    class function _ClassifyIDEAction(const AActionName: string;
      out AReason: string): Boolean; static;
    { Debug/discovery dump for ExecuteIDEAction('?'): writes every live IDE
      command (Name|LocalizedName, grouped by category) to a temp file and
      returns a 'DUMP <n> lines -> <path>' reason - the Lazarus twin of the OTA
      IDEService '?' branch (which dumps INTAServices.ActionList). }
    class function _DumpIDEActionCatalog: UnicodeString; static;
  public
    function ReadUnit(const AUnitPath: string; out ABody: string): Boolean;
    function GetActiveProject: TMCPActiveProjectInfo;
    function GetActiveUnit: string;
    function GetCursorPosition: TMCPCursorInfo;
    function GetSelection: TMCPSelectionInfo;
    function CurrentIdeViewIntent: TMCPToolIntent;
    function EditUnit(const AUnitPath, AOldText, ANewText: string; out AError: string): TMCPEditOutcome;
    function RequestConsent(const AToolName, ASummary, ADetail: string): TMCPConsentDecision;
    function DeleteUnit(const AUnitPath: string; out AError: string): TMCPFileActionOutcome;
    function OverwriteFile(const AFilePath, AContent: string; out AError: string): TMCPFileActionOutcome;
    function AddUnit(const AUnitPath, AContent: string; out AError: string): TMCPFileActionOutcome;
    function StartBuild(const AMode: string; out AError: string): Boolean;
    function QueryBuildResult: TMCPBuildState;
    function CancelBuild: Boolean;
    function GetCompilerMessages: TArray<TMCPCompilerMessage>;
    function GetProjectName: string;
    function GetProjectPath: string;
    function GetProjectFilePath: string;
    function GetProjectType: string;
    function GetProjectVersion: string;
    function GetProjectGUID: string;
    function GetProjectPlatforms: TArray<string>;
    function GetActiveProjectPlatform: string;
    function GetProjectConfigurations: TArray<string>;
    function GetActiveConfiguration: string;
    function GetProjectDescription: string;
    function GetProjectOutputDir: string;
    function SetProjectVersion(const AMajor, AMinor, ARelease, ABuild: Integer): Boolean;
    function SetActiveProjectPlatform(const APlatformName: string): Boolean;
    function SetActiveConfiguration(const AConfigName: string): Boolean;
    function SetProjectDescription(const ADescription: string): Boolean;
    function SetProjectOutputDir(const ADir: string): Boolean;
    function IsUnitOpen(const AUnitName: string): Boolean;
    function GetUnitUses(const AUnitName: string; out AInterfaceUses, AImplementationUses: TArray<string>): Boolean;
    function GetUnitFilePath(const AUnitName: string): string;
    function OpenUnitInEditor(const AUnitName: string): Boolean;
    function AddUnitToProject(const AFilePath: string): Boolean;
    function RemoveUnitFromProject(const AUnitName: string): Boolean;
    function CreateNewUnit(const AUnitName: string; AWithForm: Boolean; out AFilePath: string): Boolean;
    function CreateNewProject(const AName, AProjectType, ADirectory: string; out ADProjPath: string; out AReason: string): Boolean;
    function CloseAllProjects: Boolean;
    function AddToUses(const ATargetUnit, AUnitToAdd, ASection: string; out AChanged: Boolean): Boolean;
    function RemoveFromUses(const ATargetUnit, AUnitToRemove: string; out AChanged: Boolean): Boolean;
    function GetEditorActiveFile(out AName, APath: string): Boolean;
    function SetEditorCursorPosition(const ALine, ACol: Integer): Boolean;
    function InsertCodeAtCursor(const ACode: string): Boolean;
    function ReplaceEditorSelection(const ANewText: string): Boolean;
    function GetEditorFullContent(out AContent: string): Boolean;
    function SetEditorFullContent(const ASource: string): Boolean;
    function FindInEditor(const AText: string; const ACaseSensitive: Boolean; out AOccurrences: TArray<TMCPCursorInfo>): Boolean;
    function ReplaceInEditor(const AFind, AReplace: string; const AAll: Boolean; out ACount: Integer): Boolean;
    function FindInProject(const AText: string; const ACaseSensitive: Boolean; out AOccurrences: TArray<TMCPCursorInfo>): Boolean;
    function SaveActiveFile(out AChanged: Boolean): Boolean;
    function SaveAllFiles(out AChanged: Boolean): Boolean;
    function UndoEditor: Boolean;
    function GetOpenEditorFiles(out AFiles: TArray<TMCPRecordEditorFile>): Boolean;
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
    function SetMainForm(const AFormClass: string; out AChanged: Boolean; out AReason: string): Boolean;
    function ListProjectForms: TArray<TMCPRecordProjectForm>;
    function GetDFMContent(const AUnitName: string; out AContent: string; out AIsBinary: Boolean): Boolean;
    function SetDFMContent(const AUnitName, ADFMSource: string; out AReason: string): Boolean;
    function GetFormProperties(const AUnitName: string; out AProperties: TArray<TMCPRecordDFMProperty>): Boolean;
    function SetFormProperty(const AUnitName, APropName, APropValue: string; out AChanged: Boolean; out AReason: string): Boolean;
    function ListFormComponents(const AUnitName: string; out AComponents: TArray<TMCPRecordDFMComponent>): Boolean;
    function GetComponentProperties(const AUnitName, AComponentName: string; out AProperties: TArray<TMCPRecordDFMProperty>): Boolean;
    function SetComponentProperty(const AUnitName, AComponentName, APropName, APropValue: string; out AChanged: Boolean; out AReason: string): Boolean;
    function OpenFormDesigner(const AUnitName: string; out AChanged: Boolean; out AReason: string): Boolean;
    function OpenDFMTextEditor(const AUnitName: string; out AChanged: Boolean; out AReason: string): Boolean;
    function RemoveComponent(const AUnitName, AComponentName: string; out AChanged: Boolean; out AReason: string): Boolean;
    function AddComponent(const AUnitName, AComponentClass, AComponentName, AParent: string; const ALeft, ATop, AWidth, AHeight: Integer; out AChanged: Boolean; out AReason: string): Boolean;
    function AddEventHandler(const AUnitName, AComponentName, AEventName, AHandlerName, ABody: string; out AChanged: Boolean; out AReason: string): Boolean;
    function GetSymbolsInUnit(const AUnitName: string; out ASymbols: TArray<TMCPRecordUnitSymbol>): Boolean;
    function GetClassMembers(const AUnitName, AClassName: string; out AMembers: TArray<TMCPRecordClassMember>): Boolean;
    function FindSymbolUsages(const ASymbol: string; out AUsages: TArray<TMCPRecordSymbolUsage>): Boolean;
    function GetMethodBody(const AUnitName, AMethodName: string; out ABody: string): Boolean;
    function InsertMethod(const AUnitName, AClassName, ASignature, ABody: string; out AChanged: Boolean; out AReason: string): Boolean;
    function GetInheritanceChain(const AClassName: string; out AChain: TArray<string>): Boolean;
    function GetProjectGroupName: string;
    function ListProjectsInGroup: TArray<TMCPRecordGroupProject>;
    function SetActiveProject(const AProjectPath: string; out AChanged: Boolean; out AReason: string): Boolean;
    function AddProjectToGroup(const AProjectPath: string; out AChanged: Boolean; out AReason: string): Boolean;
    function RemoveProjectFromGroup(const AProjectPath: string; out AChanged: Boolean; out AReason: string): Boolean;
    function BuildAllInGroup( out AResults: TArray<TMCPRecordGroupBuildResult>; out AReason: string): Boolean;
    function ListProjectPackages: TArray<TMCPRecordProjectPackage>;
    function AddPackageToProject(const APackagePath: string; const ARuntime: Boolean; out AChanged: Boolean; out AReason: string): Boolean;
    function RemovePackageFromProject(const APackageName: string; out AChanged: Boolean; out AReason: string): Boolean;
    function GetLibraryPath: TArray<string>;
    function AddToLibraryPath(const APath: string; out AChanged: Boolean; out AReason: string): Boolean;
    function GetIDEVersion: TMCPRecordIDEVersion;
    function ShowIDEMessage(const AText: string; const AUseOutput: Boolean): Boolean;
    function GetIDETheme: string;
    function ExecuteIDEAction(const AActionName: string; out AReason: string): Boolean;
    function ListIDEActions(const AFilter: string): string;
    function GetProjectManagerTree: TArray<TMCPRecordProjectManagerNode>;
    function RefreshProjectManager: Boolean;
    function GetRecentFiles: TArray<string>;
    function RunExternalTool(const AArgv: TArray<string>; out ARun: TMCPRecordExternalToolRun; out AReason: string): Boolean;
    function ListProjectResources: TArray<TMCPRecordProjectResource>;
    function AddResourceFile(const AFilePath: string; out AChanged: Boolean; out AReason: string): Boolean;
    function ListProjectImages: TArray<string>;
    function RenameProject(const AOldName, ANewName: string; out AOutcome: TRenameOutcome): Boolean;
    function RenameUnit(const AUnitName, ANewUnitName: string; out AOutcome: TRenameOutcome): Boolean;
    function MoveUnitToFolder(const AUnitName, ATargetFolder: string; out AOutcome: TRenameOutcome): Boolean;
    function OpenFile(const APath: string): Boolean;
    // IMCPFormCapture (agent vision): render the LIVE designer form to a PNG.
    // Kept off the frozen IMCPWorkspaceFacade (the CaptureForm tool reaches it via
    // Supports(FFacade, IMCPFormCapture)); delegates to the Phase J designer engine.
    function CaptureActiveFormPng(const AUnitName: string;
      out ABase64, APngPath, AReason: string): Boolean;
  end;

// Factory - the composition root calls this once (mirrors the OTA facade's
// construction). Kept as the only loose routine (an FPC platform-style factory);
// it returns the interface so callers never see the concrete class.
function NewAefosLazWorkspaceFacade: IMCPWorkspaceFacade;

implementation

uses
  Forms,            // Screen (foreground form), TCustomForm, TIDesigner - the view-intent refinement
  Controls,         // mrOk (TModalResult) for the LazarusIDE save calls
  LazUTF8,
  LazIDEIntf,
  ProjectIntf,       // TLazProject.IsVirtual - virtual-project save taming
  IDEDialogs,        // IDESaveDialogClass / TIDESaveDialog - silent virtual save-as
  LazFileUtils,      // AppendPathDelim / FileExistsUTF8 / ForceDirectoriesUTF8 (CreateNewProject)
  IDECommands,
  CompOptsIntf,        // TCompileReason (crCompile/crBuild) for DoBuildProject
  IDEExternToolIntf,   // TMessageLine / TMessageLineUrgency - compiler-message harvest
  IDEMsgIntf,          // IDEMessagesWindow / TExtToolView - the live message view
  Aefos.Compat.Json,
  Aefos.Compat.IO,             // TFile - the on-disk .lfm read for the desync guard
  Aefos.MCP.FlowGuide,         // pure pas<->lfm desync guard (already FPC-swept)
  Aefos.Lazarus.EditSurgery,   // pure text surgery (Phase H write slice), semantics ported from ContentWritePolicy
  Aefos.Lazarus.LfmParser,     // Phase J - thin .lfm parser (design reads over the live form)
  Aefos.Lazarus.FormDesigner,  // Phase J - live-designer engine (design mutations + live-form reads)
  Aefos.Lazarus.GutterReview,  // change-review gutter (Model B) - mark applied edits for approve/reject
  Aefos.Lazarus.ConsoleProjectDescriptor; // dialog-free console descriptor (CreateProjectConsole)

type
  { Silent stand-in for the IDE's Save-As dialog, installed only while
    TAefosLazWorkspaceFacade._SaveVirtualProjectReal is running. Overriding
    DoExecute (the LCL seam TCommonDialog.Execute funnels through) and NOT
    calling inherited means the native chooser never shows: instead we keep the
    IDE's own suggested basename+extension and force the file into the Aefos
    workspace home, then report success. This turns the modal save of a virtual
    project into a headless one, so the in-process MCP pipe never blocks. }
  TAefosSilentSaveDialog = class(TIDESaveDialog)
  protected
    function DoExecute: Boolean; override;
  public
    class function NeedOverwritePrompt: Boolean; override;
  end;

var
  { Handshake between _SaveVirtualProjectReal and the silent dialog it installs.
    Written just before DoSaveAll and cleared in its finally; the Lazarus IDE is
    single-threaded (all facade calls run on the main thread), so no lock is
    needed. GSilentSaveHome is path-delimited; GSilentSaveMainName is a sanitized
    Pascal identifier used for the .lpi / .lpr basename. When GSilentSaveActive
    is False the dialog behaves natively (belt-and-suspenders for any stray
    Execute outside our scoped window). }
  GSilentSaveActive: Boolean = False;
  GSilentSaveHome: AnsiString = '';
  GSilentSaveMainName: AnsiString = '';

{ TAefosSilentSaveDialog }

function TAefosSilentSaveDialog.DoExecute: Boolean;
const
  cExtLpi: AnsiString = '.lpi';
  cExtLpr: AnsiString = '.lpr';
var
  LBase, LExt: AnsiString;
begin
  if not GSilentSaveActive then
    // Outside a tamed save: fall back to the real native dialog so we never
    // hijack a save the plugin did not initiate.
    Exit(inherited DoExecute);
  LBase := ExtractFileName(FileName);
  LExt := ExtractFileExt(LBase);
  if SameText(LExt, cExtLpi) or SameText(LExt, cExtLpr) then
    // Project info file / main program source: carry the chosen project name.
    FileName := GSilentSaveHome + GSilentSaveMainName + LExt
  else
    // Unit / form / anything else: keep the IDE's suggested basename.
    FileName := GSilentSaveHome + LBase;
  Result := True;
end;

class function TAefosSilentSaveDialog.NeedOverwritePrompt: Boolean;
begin
  // Never pop the overwrite confirmation (it would block the pipe). The target
  // is a fresh workspace home guarded against collisions at CreateNewProject.
  Result := False;
end;

{ TAefosLazWorkspaceFacade }

class function TAefosLazWorkspaceFacade._FromLcl(const AValue: AnsiString): UnicodeString;
begin
  // LCL/IDEIntf strings are UTF-8; the MCP core is UnicodeString. Explicit
  // conversion (never the platform ANSI codepage) keeps non-ASCII correct.
  Result := UTF8ToUTF16(AValue);
end;

// ASCII-only lowercase fold on a UnicodeString. Used for case-insensitive
// FindInEditor. Deliberately NOT SysUtils.LowerCase (AnsiString-typed, lossy
// codepage round-trip) nor a locale fold - editor find over Pascal identifiers
// is ASCII, and this keeps every byte intact. Non-ASCII compares case-sensitively.
function _AsciiLower(const AValue: UnicodeString): UnicodeString;
var
  LIdx: Integer;
  LCh: WideChar;
begin
  SetLength(Result, Length(AValue));
  for LIdx := 1 to Length(AValue) do
  begin
    LCh := AValue[LIdx];
    if (LCh >= 'A') and (LCh <= 'Z') then
      Result[LIdx] := WideChar(Ord(LCh) + 32)
    else
      Result[LIdx] := LCh;
  end;
end;

class function TAefosLazWorkspaceFacade._ToLcl(const AValue: UnicodeString): AnsiString;
begin
  // UTF16ToUTF8 returns a CP_ACP AnsiString holding UTF-8 bytes (LazUTF8), so
  // it flows into IDEIntf `string` params byte-for-byte (no codepage reconvert).
  Result := UTF16ToUTF8(AValue);
end;

class function TAefosLazWorkspaceFacade._FileNameOf(const APath: UnicodeString): UnicodeString;
var
  LIdx: Integer;
begin
  Result := APath;
  for LIdx := Length(APath) downto 1 do
    if (APath[LIdx] = '\') or (APath[LIdx] = '/') then
    begin
      Result := Copy(APath, LIdx + 1, Length(APath) - LIdx);
      Exit;
    end;
end;

function TAefosLazWorkspaceFacade._ActiveEditorText(out AText: UnicodeString): Boolean;
var
  LEditor: TSourceEditorInterface;
begin
  AText := '';
  Result := False;
  // The Lazarus IDE is single-threaded; no marshal-to-main is needed to touch
  // SourceEditorManagerIntf here (unlike the OTA facade's TThread.Synchronize).
  if SourceEditorManagerIntf = nil then
    Exit;
  LEditor := SourceEditorManagerIntf.ActiveEditor;
  if LEditor = nil then
    Exit;
  AText := _FromLcl(LEditor.SourceText);
  Result := True;
end;

class function TAefosLazWorkspaceFacade._ActiveEditor: TSourceEditorInterface;
begin
  Result := nil;
  if SourceEditorManagerIntf = nil then
    Exit;
  Result := SourceEditorManagerIntf.ActiveEditor;
end;

class function TAefosLazWorkspaceFacade._ResolveEditor(
  const AUnitPath: UnicodeString): TSourceEditorInterface;
const
  // Typed empty extension: a bare '' literal is UnicodeString under
  // {$mode delphiunicode}, which makes ChangeFileExt's overload ambiguous.
  LNoExt: AnsiString = '';
var
  // The query drives steps 1-2 in this unit's native string domain
  // (UnicodeString), crossing to the LCL's UTF-8 AnsiString filename domain via
  // _ToLcl. The basename scan (step 3) stays entirely in that AnsiString domain
  // - LCL FileName + ExtractFileName/ChangeFileExt/SameText are all AnsiString -
  // so there is no lossy UnicodeString<->AnsiString round-trip on the path.
  LQuery: UnicodeString;
  LQueryBase, LName: AnsiString;
  LEditor: TSourceEditorInterface;
  LI: Integer;
begin
  Result := nil;
  if SourceEditorManagerIntf = nil then
    Exit;
  LQuery := Trim(AUnitPath);
  // Blank path resolves to nil (the manager has no ''-named editor), matching
  // the OTA EditUnit contract that a blank path never anchor-edits the active.
  if LQuery = '' then
    Exit;
  // 1) First hit by full filename (srceditorintf.pas:320) - the common case
  // where the agent passes exactly the editor's stored name.
  Result := SourceEditorManagerIntf.SourceEditorIntfWithFilename(_ToLcl(LQuery));
  if Result <> nil then
    Exit;
  // 2) No-extension query ('unit1'): the agent routinely omits the extension.
  // Try the Pascal source extensions before falling back to a basename scan.
  if ExtractFileExt(LQuery) = '' then
  begin
    Result := SourceEditorManagerIntf.SourceEditorIntfWithFilename(_ToLcl(LQuery + '.pas'));
    if Result = nil then
      Result := SourceEditorManagerIntf.SourceEditorIntfWithFilename(_ToLcl(LQuery + '.pp'));
    if Result = nil then
      Result := SourceEditorManagerIntf.SourceEditorIntfWithFilename(_ToLcl(LQuery + '.lpr'));
    if Result <> nil then
      Exit;
  end;
  // 3) Basename match: once the project is saved the editor carries a FULL path
  // ('C:\...\unit1.pas') while the agent still names it 'unit1(.pas)'. Scan the
  // open editors and match the basename, comparing WITH and WITHOUT extension so
  // 'unit1' resolves 'unit1.pas'. First match wins.
  LQueryBase := ExtractFileName(_ToLcl(LQuery));
  for LI := 0 to SourceEditorManagerIntf.SourceEditorCount - 1 do
  begin
    LEditor := SourceEditorManagerIntf.SourceEditors[LI];
    if LEditor = nil then
      Continue;
    LName := ExtractFileName(LEditor.FileName);
    if SameText(LName, LQueryBase)
      or SameText(ChangeFileExt(LName, LNoExt), ChangeFileExt(LQueryBase, LNoExt)) then
    begin
      Result := LEditor;
      Exit;
    end;
  end;
end;

class procedure TAefosLazWorkspaceFacade._EnsureCodeEditorFront(
  AEditor: TSourceEditorInterface);
begin
  if (SourceEditorManagerIntf = nil) or (AEditor = nil) then
    Exit;
  // SetActiveEditor sets ActiveSourceWindow to the window holding AEditor and
  // flips its notebook to that page (sourceeditor.pp:9516); ShowActiveWindowOnTop
  // brings that source window on top and focuses the editor control
  // (sourceeditor.pp:10102) - the "watch it flip to Code" UX, RULE #1 doctrine 2.
  SourceEditorManagerIntf.ActiveEditor := AEditor;
  SourceEditorManagerIntf.ShowActiveWindowOnTop(True);
  // DOCKED FORM EDITOR flip (the CODE twin of the #290 design flip). When the
  // docked form editor is active the source editor has Code|Form|Anchors TABS, and
  // the two calls above select the editor + raise its window but do NOT bring the
  // CODE tab forward -- so a code write lands while the user is still looking at the
  // Form designer, and the code appears all at once at the end without the user
  // watching it (reported live 2026-07-20, the mirror of the design-tab bug).
  // IDETabMaster is non-nil ONLY when the docked form editor is active (nil for a
  // floating code editor, already handled above); ShowCode is the directed page
  // switch behind F12/ecToggleFormUnit -- always ends on the Code page.
  if IDETabMaster <> nil then
    IDETabMaster.ShowCode(AEditor);
end;

class function TAefosLazWorkspaceFacade._WriteWholeBuffer(
  AEditor: TSourceEditorInterface; const ANew: UnicodeString): Boolean;
var
  LLast: Integer;
begin
  Result := False;
  if AEditor = nil then
    Exit;
  if AEditor.ReadOnly then
    Exit;
  LLast := AEditor.LineCount;
  if LLast < 1 then
    LLast := 1;
  AEditor.BeginUndoBlock;
  try
    // ReplaceLines(1, last) -> SetTextBetweenPoints over the whole buffer: one
    // undoable edit that also sets Modified (sourceeditor.pp:5520). Grouped in
    // the undo block so the tool call reverts in a single Ctrl+Z.
    AEditor.ReplaceLines(1, LLast, _ToLcl(ANew));
  finally
    AEditor.EndUndoBlock;
  end;
  Result := True;
end;

class function TAefosLazWorkspaceFacade._NormalizeEol(
  const AText, AEol: UnicodeString): UnicodeString;
var
  LBuilder: TUnicodeStringBuilder;
  LI, LLen: Integer;
  LCh: WideChar;
begin
  LBuilder := TUnicodeStringBuilder.Create;
  try
    LLen := Length(AText);
    LI := 1;
    while LI <= LLen do
    begin
      LCh := AText[LI];
      if LCh = #13 then
      begin
        LBuilder.Append(AEol);
        // Swallow the LF half of a CRLF pair so it is not emitted twice.
        if (LI < LLen) and (AText[LI + 1] = #10) then
          Inc(LI);
      end
      else if LCh = #10 then
        LBuilder.Append(AEol)
      else
        LBuilder.Append(LCh);
      Inc(LI);
    end;
    Result := LBuilder.ToString;
  finally
    LBuilder.Free;
  end;
end;

function TAefosLazWorkspaceFacade.CurrentIdeViewIntent: TMCPToolIntent;
var
  LEditor: TSourceEditorInterface;
  LDesigner: TIDesigner;
  LDesignForm: TCustomForm;
begin
  // RULE #1 (Lazarus form): a DESIGN command needs a live designer for the active
  // unit whose form is currently SHOWN (the module's active view is Design). No
  // active editor -> neutral (guard off); a live designer that is on screen ->
  // Design; a designer that is not shown (source page frontmost), or no designer,
  // or a TDataModule/TFrame LookupRoot -> Code. See the implementation note below.
  //
  // The "shown, not focused" rule is deliberate and hard-won (2026-07-20): an
  // earlier version required the designer to be the OS-foreground window
  // (Screen.ActiveCustomForm), which BROKE the agent flow entirely -- the CLI drives
  // the IDE while the user watches the chat, so lazarus.exe never holds OS focus and
  // every mutation was rejected. Delphi's IOTAModule.CurrentEditor is focus-
  // independent; this now matches it. LoadForm MUST stay False: True materializes a
  // designer as a side effect - a mutating read, forbidden for a view probe.
  Result := tiNeutral;
  if SourceEditorManagerIntf = nil then
    Exit;
  LEditor := SourceEditorManagerIntf.ActiveEditor;
  if LEditor = nil then
    Exit;
  Result := tiCode;
  if LazarusIDE = nil then
    Exit;
  LDesigner := LazarusIDE.GetDesignerForProjectEditor(LEditor, False);
  if LDesigner = nil then
    Exit; // no live designer for the active unit -> Code
  if not (LDesigner.LookupRoot is TCustomForm) then
    Exit; // datamodule/frame: can't prove foreground -> Code (conservative)
  LDesignForm := TCustomForm(LDesigner.LookupRoot);
  // DOCKED FORM EDITOR: the active Code|Form|Anchors tab is the AUTHORITATIVE view.
  // IDETabMaster is non-nil ONLY when the docked form editor is active; its
  // TabDisplayStateEditor reports the shown tab EXACTLY (the docked master returns the
  // editor notebook's ActiveTabDisplayState -- tdsCode / tdsDesign / tdsOther). This
  // SUPERSEDES the IsVisible heuristic below, which is ambiguous in the docked editor:
  // the designed form stays IsVisible=True even when the Code tab is front, so
  // IsVisible alone wrongly reported tiDesign and BLOCKED every code command (EditUnit
  // -> wrong-view-design) right after a successful Code flip (reproduced 2026-07-20
  // driving the pipe: OpenUnitInEditor ok, then EditUnit rejected).
  if IDETabMaster <> nil then
  begin
    if IDETabMaster.TabDisplayStateEditor[LEditor] = tdsDesign then
      Result := tiDesign;
    Exit; // tdsCode / tdsOther / tdsNone -> Code
  end;
  // FLOATING designer (no tab master): a designer form actually SHOWN on screen is the
  // design view -- INDEPENDENT of OS focus (the #288 rule: the CLI drives the IDE while
  // the user watches the chat, so lazarus.exe never holds focus; "watch" = the designer
  // is VISIBLE, not focused). IsVisible walks the whole parent chain, so a designer that
  // is not on screen stays False -> Code -- mirror-safe. LoadForm stayed False above
  // (True would materialize a designer -- a mutating read, forbidden for a view probe).
  if LDesignForm.IsVisible then
    Result := tiDesign;
  // else: designer not on screen -> Code.
end;

function TAefosLazWorkspaceFacade.GetActiveUnit: string;
var
  LText: UnicodeString;
begin
  if _ActiveEditorText(LText) then
    Result := LText
  else
    Result := '';
end;

function TAefosLazWorkspaceFacade.GetEditorFullContent(out AContent: string): Boolean;
var
  LText: UnicodeString;
begin
  Result := _ActiveEditorText(LText);
  if Result then
    AContent := LText
  else
    AContent := '';
end;

function TAefosLazWorkspaceFacade.GetEditorActiveFile(out AName, APath: string): Boolean;
var
  LEditor: TSourceEditorInterface;
  LPath: UnicodeString;
begin
  AName := '';
  APath := '';
  Result := False;
  if SourceEditorManagerIntf = nil then
    Exit;
  LEditor := SourceEditorManagerIntf.ActiveEditor;
  if LEditor = nil then
    Exit;
  LPath := _FromLcl(LEditor.FileName);
  APath := LPath;
  AName := _FileNameOf(LPath);
  Result := True;
end;

function TAefosLazWorkspaceFacade.ListIDEActions(const AFilter: string): string;
var
  LFilter, LNameU, LCaptionU, LCategoryU: AnsiString;
  LRoot, LObj: TJSONObject;
  LArr: TJSONArray;
  LCatIdx, LCmdIdx: Integer;
  LCat: TIDECommandCategory;
  LCmd: TIDECommand;
begin
  // Read-only catalog of the LIVE IDE command list (idecommands.pas:800
  // IDECommandList). The Lazarus analog of INTAServices.ActionList: commands
  // carry name + localized name + category + enabled, but not the rich
  // Hint/ShortCut of a TCustomAction, so those keys ship empty (shape parity
  // with the OTA ListIDEActions JSON). Filtering is done in UTF-8 space so a
  // non-ASCII filter still folds correctly.
  LFilter := UTF8LowerCase(UTF16ToUTF8(Trim(AFilter)));
  LRoot := TJSONObject.Create;
  try
    LArr := TJSONArray.Create;
    if IDECommandList <> nil then
      for LCatIdx := 0 to IDECommandList.CategoryCount - 1 do
      begin
        LCat := IDECommandList.Categories[LCatIdx];
        if LCat = nil then
          Continue;
        LCategoryU := LCat.Name;
        for LCmdIdx := 0 to LCat.Count - 1 do
        begin
          LCmd := TIDECommand(LCat.Items[LCmdIdx]);
          if LCmd = nil then
            Continue;
          LNameU := LCmd.Name;
          LCaptionU := LCmd.LocalizedName;
          if (LFilter <> '')
            and (Pos(LFilter, UTF8LowerCase(LNameU)) = 0)
            and (Pos(LFilter, UTF8LowerCase(LCaptionU)) = 0)
            and (Pos(LFilter, UTF8LowerCase(LCategoryU)) = 0) then
            Continue;
          LObj := TJSONObject.Create;
          LObj.AddPair('name', _FromLcl(LNameU));
          LObj.AddPair('caption', _FromLcl(LCaptionU));
          LObj.AddPair('category', _FromLcl(LCategoryU));
          LObj.AddPair('shortcut', '');
          LObj.AddPair('hint', '');
          LObj.AddPair('enabled', TJSONBool.Create(LCmd.Enabled));
          LArr.AddElement(LObj);
        end;
      end;
    LRoot.AddPair('actions', LArr);
    LRoot.AddPair('count', TJSONNumber.Create(Int64(LArr.Count)));
    Result := LRoot.ToJSON;
  finally
    LRoot.Free;
  end;
end;

// ===========================================================================
// Phase H - editor READ completion. Selection, cursor position and the
// open-editor list (with per-file Modified state), matching the Delphi
// EditorReadService. The Lazarus IDE is single-threaded and these run on the
// main thread (the composition root marshals server->main, seam doc SS Marshal),
// so they touch SourceEditorManagerIntf directly.
// ===========================================================================

function TAefosLazWorkspaceFacade.GetCursorPosition: TMCPCursorInfo;
var
  LEditor: TSourceEditorInterface;
  LCaret: TPoint;
begin
  Result := Default(TMCPCursorInfo);
  LEditor := _ActiveEditor;
  if LEditor = nil then
    Exit;
  LCaret := LEditor.CursorTextXY;     // X = column, Y = line, both 1-based
  Result.UnitPath  := _FromLcl(LEditor.FileName);
  Result.Line      := LCaret.Y;
  Result.Column    := LCaret.X;
  Result.Available := True;
end;

function TAefosLazWorkspaceFacade.GetSelection: TMCPSelectionInfo;
var
  LEditor: TSourceEditorInterface;
  LBegin, LEnd: TPoint;
begin
  Result := Default(TMCPSelectionInfo);
  LEditor := _ActiveEditor;
  if LEditor = nil then
    Exit;
  if not LEditor.SelectionAvailable then
    Exit;
  LBegin := LEditor.BlockBegin;
  LEnd   := LEditor.BlockEnd;
  Result.UnitPath    := _FromLcl(LEditor.FileName);
  Result.Text        := _FromLcl(LEditor.Selection);
  Result.StartLine   := LBegin.Y;
  Result.StartColumn := LBegin.X;
  Result.EndLine     := LEnd.Y;
  Result.EndColumn   := LEnd.X;
  Result.Available   := True;
end;

function TAefosLazWorkspaceFacade.GetOpenEditorFiles(
  out AFiles: TArray<TMCPRecordEditorFile>): Boolean;
var
  LIdx: Integer;
  LEditor: TSourceEditorInterface;
  LPath: UnicodeString;
begin
  AFiles := nil;
  Result := False;
  if SourceEditorManagerIntf = nil then
    Exit;
  // UniqueSourceEditors excludes dual-view duplicates (one row per open file),
  // the closest analog of the OTA one-per-module list.
  SetLength(AFiles, SourceEditorManagerIntf.UniqueSourceEditorCount);
  for LIdx := 0 to SourceEditorManagerIntf.UniqueSourceEditorCount - 1 do
  begin
    LEditor := SourceEditorManagerIntf.UniqueSourceEditors[LIdx];
    LPath := _FromLcl(LEditor.FileName);
    AFiles[LIdx].Path     := LPath;
    AFiles[LIdx].Name     := _FileNameOf(LPath);
    AFiles[LIdx].Modified := LEditor.Modified;
  end;
  Result := True;
end;

// ===========================================================================
// Phase H - editor WRITE slice. Each CODE-intent write: resolves the target
// TSourceEditorInterface, flips-to-and-ends-in Code (_EnsureCodeEditorFront),
// wraps the mutation in one undo block (single Ctrl+Z reverts the tool call),
// and leaves the buffer Modified so the IDE prompts to save. Semantics match
// the Delphi EditorWriteService MINUS the inline-diff review approver and the
// pas<->dfm desync guard, which are chat/designer seams that land in later
// phases (documented per member). Marshalling is the composition root's job
// (single server->main hop), as with the reads.
// ===========================================================================

function TAefosLazWorkspaceFacade.EditUnit(const AUnitPath, AOldText,
  ANewText: string; out AError: string): TMCPEditOutcome;
var
  LEditor: TSourceEditorInterface;
  LBody, LNew, LFind, LRepl, LEol: UnicodeString;
  LCount: Integer;
begin
  AError := '';
  Result := eoUnitNotOpen;
  // A blank path never anchor-edits the active editor (OTA EditUnit contract).
  if Trim(AUnitPath) = '' then
    Exit;
  LEditor := _ResolveEditor(AUnitPath);
  if LEditor = nil then
    Exit; // eoUnitNotOpen
  _EnsureCodeEditorFront(LEditor);
  // Model B auto-save (opt-in): if the user enabled "Agent auto-save edits" and this unit
  // still has prior pending review changes, auto-approve them NOW - before we read the buffer
  // - so the new edit does not stack on an unresolved diff. No-op when auto-save is off (the
  // changes keep accruing) or nothing is pending. Mirrors the RAD facade guard that lets an
  // edit pass by auto-accepting the prior review (Aefos.MCP.OTA.WorkspaceFacade.pas:420-426).
  TAefosLazGutterReview.AutoAcceptUnitOnNewEdit(LEditor);
  LBody := _FromLcl(LEditor.SourceText);
  // Match EOL-agnostically: the live buffer is stored with the editor's EOL
  // (CRLF on Windows) but the agent routinely sends an anchor with LF only, so
  // a raw Pos would miss and report anchor-not-found. Rewrite the anchor AND the
  // replacement to the buffer's own EOL, so the match succeeds and the new text
  // lands with consistent line endings.
  if Pos(UnicodeString(#13#10), LBody) > 0 then
    LEol := #13#10
  else
    LEol := #10;
  LFind := _NormalizeEol(AOldText, LEol);
  LRepl := _NormalizeEol(ANewText, LEol);
  // Exactly-once anchor contract (ADR-061/062): count matches, then apply the
  // single replacement. Empty anchor / zero matches -> not found; 2+ -> ambiguous.
  if not TAefosEditSurgery.ReplaceInBuffer(LBody, LFind, '', True, LNew, LCount) then
  begin
    Result := eoAnchorNotFound; // empty anchor - nothing to match
    Exit;
  end;
  if LCount = 0 then
  begin
    Result := eoAnchorNotFound;
    Exit;
  end;
  if LCount > 1 then
  begin
    Result := eoAnchorAmbiguous;
    Exit;
  end;
  TAefosEditSurgery.ReplaceInBuffer(LBody, LFind, LRepl, False, LNew, LCount);
  if not _WriteWholeBuffer(LEditor, LNew) then
  begin
    Result := eoUnitNotOpen;
    Exit;
  end;
  // Model B change-review: the edit is APPLIED (above); now, when the shared
  // "AgentEditReviewMode" is not "Apply silently", light a gutter marker on the
  // changed line(s) so the developer can Approve (keep) or Reject (restore LBody,
  // the pre-edit whole buffer). NotifyApplied never raises out and is a no-op when
  // review is off, so the applied edit / eoApplied path is unchanged when silent.
  TAefosLazGutterReview.NotifyApplied(LEditor, AUnitPath, LBody, LNew);
  Result := eoApplied;
end;

// ---------------------------------------------------------------------------
// Not-yet-ported facade members. Each raises ENotSupportedException naming the
// phase that will implement it (H = editor writes, I = project/CodeTools,
// J = designer) - never a silent stub that returns a lie. They raise before
// returning, so FPC's "result not set" (5033) is expected here and suppressed
// for this block only.
// ---------------------------------------------------------------------------
{$push}
{$warn 5033 off}

function TAefosLazWorkspaceFacade.ReadUnit(const AUnitPath: string; out ABody: string): Boolean;
begin
  raise ENotSupportedException.Create('ReadUnit: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.GetActiveProject: TMCPActiveProjectInfo;
begin
  raise ENotSupportedException.Create('GetActiveProject: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.RequestConsent(const AToolName, ASummary, ADetail: string): TMCPConsentDecision;
begin
  raise ENotSupportedException.Create('RequestConsent: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.DeleteUnit(const AUnitPath: string; out AError: string): TMCPFileActionOutcome;
begin
  raise ENotSupportedException.Create('DeleteUnit: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.OverwriteFile(const AFilePath, AContent: string; out AError: string): TMCPFileActionOutcome;
begin
  raise ENotSupportedException.Create('OverwriteFile: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.AddUnit(const AUnitPath, AContent: string; out AError: string): TMCPFileActionOutcome;
begin
  raise ENotSupportedException.Create('AddUnit: Lazarus backend phase H+');
end;

// Build/compile-loop tools (the Lazarus twin of the OTA facade StartBuild /
// QueryBuildResult / CancelBuild / GetCompilerMessages). Lazarus's build API
// (LazarusIDE.DoBuildProject, lazideintf.pas:379) is SYNCHRONOUS - it returns
// the compile outcome directly - so the async build_id model (RunBuild ->
// GetBuildStatus) is honoured by recording the final state in StartBuild and
// replaying it from QueryBuildResult; the shape/contract is identical to the
// Delphi edition, only the mechanism (synchronous vs OTA async) differs.
function TAefosLazWorkspaceFacade.StartBuild(const AMode: string; out AError: string): Boolean;
var
  LReason: TCompileReason;
begin
  AError := '';
  Result := False;
  FLastBuildState := bsFailed;
  if LazarusIDE = nil then
  begin
    AError := 'no IDE';
    Exit;
  end;
  if LazarusIDE.ActiveProject = nil then
  begin
    AError := 'no active project';
    Exit;
  end;
  // Mode mapping mirrors the shared BuildRunPolicy.NormalizeBuildMode contract:
  // 'make' (default) -> incremental (crCompile); 'build' -> full (crBuild). The
  // RunBuild tool handler (_ReadBuildMode) has already rejected any value other
  // than 'make'/'build' with -32602, so a bare 'build' test is enough here.
  if AMode = 'build' then
    LReason := crBuild
  else
    LReason := crCompile;
  // DoBuildProject returns mrOk on success; anything else (mrAbort/mrCancel) is a
  // failed compile. It runs synchronously on the IDE main thread (the caller has
  // already marshalled us here), so the outcome is final on return.
  if LazarusIDE.DoBuildProject(LReason, []) = mrOk then
    FLastBuildState := bsSucceeded
  else
    FLastBuildState := bsFailed;
  // The build was launched (and, being synchronous, has already finished). True
  // means "a build_id may be minted"; the pass/fail lives in FLastBuildState.
  Result := True;
end;

function TAefosLazWorkspaceFacade.QueryBuildResult: TMCPBuildState;
begin
  // The synchronous build already resolved inside StartBuild, so this never
  // returns bsRunning - the first GetBuildStatus poll immediately sees the final
  // state (the async build_id job resolves in one hop).
  Result := FLastBuildState;
end;

function TAefosLazWorkspaceFacade.CancelBuild: Boolean;
begin
  // Honest degrade: Lazarus's DoBuildProject is synchronous, so by the time a
  // notifications/cancelled could flip the build_id token the compile has already
  // finished - there is nothing left to abort. Always a no-op (False).
  Result := False;
end;

function TAefosLazWorkspaceFacade.GetCompilerMessages: TArray<TMCPCompilerMessage>;
var
  LResult: TArray<TMCPCompilerMessage>;
  LCount, LLineIdx: Integer;
  LView: TExtToolView;
  LLines: TMessageLines;
  LLine: TMessageLine;
  LMsg: TMCPCompilerMessage;
  LSeverity: TMCPCompilerSeverity;
  LInclude: Boolean;
begin
  SetLength(LResult, 0);
  LCount := 0;
  // The IDE message view is nil until the first tool run populates it; an empty
  // array is the honest "no diagnostics" answer (never a crash).
  if IDEMessagesWindow = nil then
    Exit(LResult);
  if IDEMessagesWindow.ViewCount = 0 then
    Exit(LResult);
  // Read ONLY the most recent view. Each build (and each external-tool run)
  // appends a NEW TExtToolView and the history is kept, so iterating them all
  // would mix THIS build's diagnostics with stale ones from earlier builds.
  // GetCompilerErrors is called right after a RunBuild, so the last view is that
  // build's output.
  LView := IDEMessagesWindow.Views[IDEMessagesWindow.ViewCount - 1];
  if LView = nil then
    Exit(LResult);
  LLines := LView.Lines;
  if LLines = nil then
    Exit(LResult);
  // TMessageLines demands its critical section around any access (the compiler
  // runs on a worker; we read from the IDE main thread).
  LLines.EnterCriticalSection;
  try
    for LLineIdx := 0 to LLines.Count - 1 do
    begin
      LLine := LLines[LLineIdx];
      if LLine = nil then
        Continue;
      // Map the LCL urgency ladder onto the {error, warning, hint} contract;
      // progress/verbose/debug lines are noise and dropped.
      LInclude := True;
      case LLine.Urgency of
        mluError, mluFatal, mluPanic:
          LSeverity := csError;
        mluWarning, mluImportant:
          LSeverity := csWarning;
        mluHint, mluNote:
          LSeverity := csHint;
      else
        LInclude := False;
      end;
      if not LInclude then
        Continue;
      LMsg.Path := _FromLcl(LLine.Filename);
      LMsg.Line := LLine.Line;
      LMsg.Column := LLine.Column;
      LMsg.Severity := LSeverity;
      LMsg.Text := _FromLcl(LLine.Msg);
      if LCount = Length(LResult) then
      begin
        if LCount = 0 then
          SetLength(LResult, 16)
        else
          SetLength(LResult, LCount * 2);
      end;
      LResult[LCount] := LMsg;
      Inc(LCount);
    end;
  finally
    LLines.LeaveCriticalSection;
  end;
  SetLength(LResult, LCount);
  Result := LResult;
end;

function TAefosLazWorkspaceFacade.GetProjectName: string;
begin
  raise ENotSupportedException.Create('GetProjectName: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.GetProjectPath: string;
begin
  raise ENotSupportedException.Create('GetProjectPath: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.GetProjectFilePath: string;
begin
  raise ENotSupportedException.Create('GetProjectFilePath: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.GetProjectType: string;
begin
  raise ENotSupportedException.Create('GetProjectType: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.GetProjectVersion: string;
begin
  raise ENotSupportedException.Create('GetProjectVersion: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.GetProjectGUID: string;
begin
  raise ENotSupportedException.Create('GetProjectGUID: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.GetProjectPlatforms: TArray<string>;
begin
  raise ENotSupportedException.Create('GetProjectPlatforms: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.GetActiveProjectPlatform: string;
begin
  raise ENotSupportedException.Create('GetActiveProjectPlatform: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.GetProjectConfigurations: TArray<string>;
begin
  raise ENotSupportedException.Create('GetProjectConfigurations: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.GetActiveConfiguration: string;
begin
  raise ENotSupportedException.Create('GetActiveConfiguration: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.GetProjectDescription: string;
begin
  raise ENotSupportedException.Create('GetProjectDescription: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.GetProjectOutputDir: string;
begin
  raise ENotSupportedException.Create('GetProjectOutputDir: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.SetProjectVersion(const AMajor, AMinor, ARelease, ABuild: Integer): Boolean;
begin
  raise ENotSupportedException.Create('SetProjectVersion: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.SetActiveProjectPlatform(const APlatformName: string): Boolean;
begin
  raise ENotSupportedException.Create('SetActiveProjectPlatform: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.SetActiveConfiguration(const AConfigName: string): Boolean;
begin
  raise ENotSupportedException.Create('SetActiveConfiguration: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.SetProjectDescription(const ADescription: string): Boolean;
begin
  raise ENotSupportedException.Create('SetProjectDescription: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.SetProjectOutputDir(const ADir: string): Boolean;
begin
  raise ENotSupportedException.Create('SetProjectOutputDir: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.IsUnitOpen(const AUnitName: string): Boolean;
begin
  raise ENotSupportedException.Create('IsUnitOpen: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.GetUnitUses(const AUnitName: string; out AInterfaceUses, AImplementationUses: TArray<string>): Boolean;
begin
  raise ENotSupportedException.Create('GetUnitUses: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.GetUnitFilePath(const AUnitName: string): string;
begin
  raise ENotSupportedException.Create('GetUnitFilePath: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.OpenUnitInEditor(const AUnitName: string): Boolean;
var
  LEditor: TSourceEditorInterface;
  LOpened: TModalResult;
begin
  // View-switch (RULE #1 EXEMPT): the Lazarus twin of the Delphi OpenUnitInEditor -
  // materialize/focus the unit's SOURCE editor and flip the IDE to Code view, the
  // way an agent switches to Code before a code command. It opens a tab / brings a
  // window front; it never mutates code, so it is NOT consent-gated. Runs on the
  // IDE main thread (the registrar marshals through the context).
  Result := False;
  if (SourceEditorManagerIntf = nil) or (LazarusIDE = nil) then
    Exit;
  if Trim(AUnitName) = '' then
    Exit;
  // 1) Already open: _ResolveEditor handles exact path, the omitted-extension
  //    query ('unit1') and a basename scan over the open editors, so a bare name
  //    resolves the right tab.
  LEditor := _ResolveEditor(AUnitName);
  // 2) Not open yet: open it from disk. ofOnlyIfExists => never auto-create a file;
  //    a bare non-path name the IDE cannot locate fails cleanly (Result stays False
  //    and the tool reports unit-not-open). ofRegularFile keeps it a plain source
  //    open (not a project/package). After a successful open the file becomes the
  //    active editor; re-resolve, falling back to ActiveEditor.
  if LEditor = nil then
  begin
    LOpened := LazarusIDE.DoOpenEditorFile(_ToLcl(AUnitName), -1, -1,
      [ofOnlyIfExists, ofRegularFile]);
    if LOpened = mrOk then
    begin
      LEditor := _ResolveEditor(AUnitName);
      if LEditor = nil then
        LEditor := SourceEditorManagerIntf.ActiveEditor;
    end;
  end;
  if LEditor = nil then
    Exit;
  // End in Code: bring the source window on top and focus the editor control
  // (RULE #1 doctrine 2 - the user watches it flip to Code).
  _EnsureCodeEditorFront(LEditor);
  Result := True;
end;

function TAefosLazWorkspaceFacade.CaptureActiveFormPng(const AUnitName: string;
  out ABase64, APngPath, AReason: string): Boolean;
var
  LB64, LPath, LReason: AnsiString;
begin
  // Agent vision (IMCPFormCapture): render the LIVE designer form to a PNG so a
  // vision model SEES the layout it is building. Delegates to the Phase J designer
  // engine (LCL TCustomForm.GetFormImage -> TPortableNetworkGraphic -> base64 +
  // a temp PNG file), converting across the UTF-8 (LCL) <-> UTF-16 (MCP core)
  // boundary. AReason carries a machine-actionable code on failure ('' on success).
  LB64 := '';
  LPath := '';
  LReason := '';
  Result := TAefosLazFormDesigner.CaptureActiveFormPng(_ToLcl(AUnitName),
    LB64, LPath, LReason);
  ABase64 := _FromLcl(LB64);
  APngPath := _FromLcl(LPath);
  AReason := _FromLcl(LReason);
end;

function TAefosLazWorkspaceFacade.AddUnitToProject(const AFilePath: string): Boolean;
begin
  raise ENotSupportedException.Create('AddUnitToProject: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.RemoveUnitFromProject(const AUnitName: string): Boolean;
begin
  raise ENotSupportedException.Create('RemoveUnitFromProject: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.CreateNewUnit(const AUnitName: string; AWithForm: Boolean; out AFilePath: string): Boolean;
begin
  raise ENotSupportedException.Create('CreateNewUnit: Lazarus backend phase H+');
end;

// CreateNewProject is implemented (result always set) below, past the {$pop}.

function TAefosLazWorkspaceFacade.CloseAllProjects: Boolean;
begin
  raise ENotSupportedException.Create('CloseAllProjects: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.AddToUses(const ATargetUnit, AUnitToAdd, ASection: string; out AChanged: Boolean): Boolean;
begin
  raise ENotSupportedException.Create('AddToUses: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.RemoveFromUses(const ATargetUnit, AUnitToRemove: string; out AChanged: Boolean): Boolean;
begin
  raise ENotSupportedException.Create('RemoveFromUses: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.SetEditorCursorPosition(const ALine, ACol: Integer): Boolean;
begin
  raise ENotSupportedException.Create('SetEditorCursorPosition: Lazarus backend phase H+');
end;

{$pop}

// --- Project creation (dialog-free, per-type; result always set) -----------
// The Lazarus twin of the OTA facade CreateNewProject. AProjectType is a fixed
// ASCII kind token supplied by the CreateProject<Type> MCP tool (never read from
// an agent param - RULE #1: the type lives in the tool NAME, so an agent that
// asks for a "console" tool cannot end up with a GUI app). Each kind maps to a
// concrete Lazarus TProjectDescriptor which LazarusIDE.DoNewProject drives:
//   application   -> the registered 'Application' descriptor (GUI LCL app)
//   simpleprogram -> the registered 'Simple Program' descriptor
//   program       -> the registered 'Program' descriptor
//   library       -> the registered 'Library' descriptor
//   console       -> a PRIVATE dialog-free console descriptor (the registered one
//                    pops a modal options form that would block the MCP pipe).
// Passing a NON-NIL descriptor makes DoNewProject SKIP the "Create a new project"
// chooser modal (the menu path pops it via ChooseNewProject; here we bypass it) -
// so no dialog appears on the happy path.

function TAefosLazWorkspaceFacade.CreateNewProject(const AName, AProjectType,
  ADirectory: string; out ADProjPath: string; out AReason: string): Boolean;
const
  // LCL path domain is UTF-8 AnsiString; keep the segments AnsiString-typed so the
  // concatenations never trip an implicit UnicodeString<->AnsiString conversion
  // (4104/4105) under {$mode delphiunicode} (same discipline as _EnsureProjectHome).
  LEnvAppData: AnsiString = 'APPDATA';
  LVendorDir: AnsiString = 'Aefos';
  LWorkspaceDir: AnsiString = 'lazarus-workspace';
  LDefaultName: AnsiString = 'project';
  LProjectExt: AnsiString = '.lpi';
var
  LDesc: TProjectDescriptor;
  LConsole: TAefosConsoleProjectDescriptor;
  LOwnsDesc: Boolean;
  LProj: TLazProject;
  LName, LDir, LHomeFile: AnsiString;
begin
  ADProjPath := '';
  AReason := '';
  Result := False;
  if LazarusIDE = nil then
  begin
    AReason := 'no-ide';
    Exit;
  end;
  if ProjectDescriptors = nil then
  begin
    AReason := 'no-project-descriptors';
    Exit;
  end;

  // Resolve the requested name + optional sub-directory into a real home under
  // %APPDATA%\Aefos\lazarus-workspace (the shared ONE-BRAIN root), so the project
  // carries the caller's chosen name instead of the IDE placeholder 'project1'.
  LName := Trim(_ToLcl(AName));
  if Length(LName) = 0 then
    LName := LDefaultName;
  LDir := AppendPathDelim(GetEnvironmentVariableUTF8(LEnvAppData)) + LVendorDir;
  LDir := AppendPathDelim(LDir) + LWorkspaceDir;
  if Length(Trim(_ToLcl(ADirectory))) > 0 then
    LDir := AppendPathDelim(LDir) + Trim(_ToLcl(ADirectory));
  LDir := AppendPathDelim(LDir) + LName;
  LHomeFile := AppendPathDelim(LDir) + LName + LProjectExt;

  // Collision guard (parity with the OTA 'project-already-exists'): never clobber
  // an existing project on disk. Checked BEFORE DoNewProject so the current project
  // is left untouched on a collision.
  if FileExistsUTF8(LHomeFile) then
  begin
    ADProjPath := _FromLcl(LHomeFile);
    AReason := 'project-already-exists';
    Exit;
  end;

  LOwnsDesc := False;
  LConsole := nil;
  if AProjectType = 'application' then
    LDesc := ProjectDescriptors.FindByName(ProjDescNameApplication)
  else if AProjectType = 'simpleprogram' then
    LDesc := ProjectDescriptors.FindByName(ProjDescNameSimpleProgram)
  else if AProjectType = 'program' then
    LDesc := ProjectDescriptors.FindByName(ProjDescNameProgram)
  else if AProjectType = 'library' then
    LDesc := ProjectDescriptors.FindByName(ProjDescNameLibrary)
  else if AProjectType = 'console' then
  begin
    LConsole := TAefosConsoleProjectDescriptor.Create;
    LDesc := LConsole;
    LOwnsDesc := True;
  end
  else
  begin
    AReason := 'unknown-project-type';
    Exit;
  end;
  if LDesc = nil then
  begin
    AReason := 'descriptor-unavailable';
    Exit;
  end;

  try
    // DoNewProject creates a VIRTUAL (unsaved) project from the specific descriptor
    // and, given a non-nil descriptor, SKIPS the chooser modal (lazideintf.pas:372;
    // main.pp:6307 -> InitDescriptor is mrOk for all these descriptors, no dialog).
    if LazarusIDE.DoNewProject(LDesc) <> mrOk then
    begin
      AReason := 'do-new-project-failed';
      Exit;
    end;
  finally
    // The registered singletons are owned by ProjectDescriptors (never freed here -
    // the menu path reuses them too); the private console descriptor is NOT retained
    // by TProject (project.pp:2753 TProject.Create does not Reference it), so Release
    // its sole reference now.
    if LOwnsDesc and (LConsole <> nil) then
      LConsole.Release;
  end;

  // Give the freshly-created virtual project its home. Assigning ProjectInfoFile
  // clears IsVirtual WITHOUT writing to disk (files land on the next Save/Build via
  // DoSaveAll), so this stays dialog-free while honouring the caller's name. A later
  // _EnsureProjectHome then sees a non-virtual project and no-ops.
  LProj := LazarusIDE.ActiveProject;
  if LProj <> nil then
  begin
    ForceDirectoriesUTF8(LDir);
    LProj.ProjectInfoFile := LHomeFile;
    ADProjPath := _FromLcl(LProj.ProjectInfoFile);
  end;
  Result := True;
end;

// --- Phase H editor writes (implemented; result always set) ----------------

function TAefosLazWorkspaceFacade.InsertCodeAtCursor(const ACode: string): Boolean;
var
  LEditor: TSourceEditorInterface;
  LCaret: TPoint;
  LCurrent, LNew: UnicodeString;
begin
  Result := False;
  LEditor := _ActiveEditor;
  if LEditor = nil then
    Exit;
  _EnsureCodeEditorFront(LEditor);
  LCaret := LEditor.CursorTextXY;    // X = column, Y = line
  LCurrent := _FromLcl(LEditor.SourceText);
  if not TAefosEditSurgery.InsertTextAt(LCurrent, ACode, LCaret.Y, LCaret.X, LNew) then
    Exit; // caret unresolvable
  Result := _WriteWholeBuffer(LEditor, LNew);
end;

function TAefosLazWorkspaceFacade.ReplaceEditorSelection(const ANewText: string): Boolean;
var
  LEditor: TSourceEditorInterface;
begin
  Result := False;
  LEditor := _ActiveEditor;
  if LEditor = nil then
    Exit;
  if LEditor.ReadOnly then
    Exit;
  _EnsureCodeEditorFront(LEditor);
  LEditor.BeginUndoBlock;
  try
    // Selection setter -> SynEdit SelText := X (sourceeditor.pp:4820): replaces
    // the selected block, or inserts at the caret when nothing is selected.
    // Wrapped so it reverts in a single undo step.
    LEditor.Selection := _ToLcl(ANewText);
  finally
    LEditor.EndUndoBlock;
  end;
  Result := True;
end;

function TAefosLazWorkspaceFacade.SetEditorFullContent(const ASource: string): Boolean;
var
  LEditor: TSourceEditorInterface;
  LLfmPath: UnicodeString;
  LLfmText: UnicodeString;
  LReason: UnicodeString;
begin
  // Whole-buffer replace of the ACTIVE editor, gated by the same pas<->dfm
  // desync doctrine as the Delphi side: a wholesale source rewrite must never
  // drop Designer-managed component fields. The Delphi original prefers the
  // LIVE designer DFM and DEGRADES to the on-disk file; the live half is a
  // Phase J seam, so this backend ships the disk half now (sibling .lfm) -
  // the exact degrade path the OTA implementation already accepts. Fails open
  // when no .lfm exists (non-form unit), mirroring the Delphi guard.
  Result := False;
  LEditor := _ActiveEditor;
  if LEditor = nil then
    Exit;
  // RULE #1 hard brake (the owner's rigid decision): a wholesale .pas write must
  // NEVER build a form by creating standard LCL controls in code — they are born
  // in the Designer (AddComponent). Refuse before touching the buffer. Defense in
  // depth: the McpTools handler pre-checks and surfaces the actionable reason; this
  // facade guard protects any other caller of the seam. Custom-painted controls
  // declared in the unit are permitted (they cannot be built in the Designer).
  LReason := TFlowGuide.SourceBuildsStandardControlsInCodeReason(ASource);
  if LReason <> '' then
    Exit;
  LLfmPath := ChangeFileExt(_FromLcl(LEditor.FileName), '.lfm');
  if TFile.Exists(LLfmPath) then
  begin
    LLfmText := TFile.ReadAllText(LLfmPath, TEncoding.UTF8);
    LReason := TFlowGuide.SourceDropsComponentsReason(LLfmText, ASource);
    if LReason <> '' then
      Exit;   // refuse the desyncing rewrite; the caller surfaces the failure
  end;
  _EnsureCodeEditorFront(LEditor);
  Result := _WriteWholeBuffer(LEditor, ASource);
end;

function TAefosLazWorkspaceFacade.FindInEditor(const AText: string;
  const ACaseSensitive: Boolean; out AOccurrences: TArray<TMCPCursorInfo>): Boolean;
var
  LEditor: TSourceEditorInterface;
  LPath, LBuf, LHay, LNeedle: UnicodeString;
  LFrom, LAt, LLine, LCol, LScan: Integer;
  LList: array of TMCPCursorInfo;
  LNum: Integer;
begin
  // Read-only occurrence scan over the live buffer (no view change - RULE #1
  // exempts reads). Reports 1-based (line, column) of each hit, like the cursor
  // reads. Case-insensitive folds both sides (ASCII-safe UnicodeString compare).
  AOccurrences := nil;
  Result := False;
  LEditor := _ActiveEditor;
  if LEditor = nil then
    Exit;
  if AText = '' then
  begin
    Result := True; // empty needle: a valid no-op with zero occurrences
    Exit;
  end;
  LPath := _FromLcl(LEditor.FileName);
  LBuf  := _FromLcl(LEditor.SourceText);
  if ACaseSensitive then
  begin
    LHay := LBuf;
    LNeedle := AText;
  end
  else
  begin
    LHay := _AsciiLower(LBuf);
    LNeedle := _AsciiLower(AText);
  end;
  LNum := 0;
  SetLength(LList, 0);
  LFrom := 1;
  repeat
    LAt := Pos(LNeedle, LHay, LFrom);
    if LAt = 0 then
      Break;
    // Char index -> (line, col) by scanning the prefix (CRLF counts as one EOL).
    LLine := 1;
    LCol  := 1;
    for LScan := 1 to LAt - 1 do
      case LBuf[LScan] of
        #10:
          begin Inc(LLine); LCol := 1; end;
        #13:
          // A CR that is the first half of a CRLF is not counted here; the LF is
          // counted on the next iteration, so a CRLF advances exactly one line.
          if not ((LScan < LAt - 1) and (LBuf[LScan + 1] = #10)) then
          begin Inc(LLine); LCol := 1; end;
      else
        Inc(LCol);
      end;
    Inc(LNum);
    SetLength(LList, LNum);
    LList[LNum - 1] := Default(TMCPCursorInfo);
    LList[LNum - 1].UnitPath  := LPath;
    LList[LNum - 1].Line      := LLine;
    LList[LNum - 1].Column    := LCol;
    LList[LNum - 1].Available := True;
    LFrom := LAt + Length(LNeedle);
  until False;
  AOccurrences := LList;
  Result := True;
end;

function TAefosLazWorkspaceFacade.ReplaceInEditor(const AFind, AReplace: string;
  const AAll: Boolean; out ACount: Integer): Boolean;
var
  LEditor: TSourceEditorInterface;
  LBuf, LNew: UnicodeString;
begin
  ACount := 0;
  Result := False;
  LEditor := _ActiveEditor;
  if LEditor = nil then
    Exit;
  _EnsureCodeEditorFront(LEditor);
  LBuf := _FromLcl(LEditor.SourceText);
  if not TAefosEditSurgery.ReplaceInBuffer(LBuf, AFind, AReplace, AAll, LNew, ACount) then
    Exit; // empty find
  // Zero matches is a successful no-op (count 0, no rewrite) - the OTA contract.
  if ACount = 0 then
  begin
    Result := True;
    Exit;
  end;
  Result := _WriteWholeBuffer(LEditor, LNew);
end;

{$push}
{$warn 5033 off}

function TAefosLazWorkspaceFacade.FindInProject(const AText: string; const ACaseSensitive: Boolean; out AOccurrences: TArray<TMCPCursorInfo>): Boolean;
begin
  raise ENotSupportedException.Create('FindInProject: Lazarus backend phase H+');
end;

class function TAefosLazWorkspaceFacade._ActiveProjectIsVirtual: Boolean;
var
  LProj: TLazProject;
begin
  // VIRTUAL = never saved. IsVirtual (project.pp:4247) is true while the MAIN UNIT
  // is virtual OR the .lpi path is empty/relative - so setting ProjectInfoFile
  // alone can NEVER clear it (the main unit stays virtual). That is why a plain
  // DoSaveAll pops the native "Save project" dialog. When this returns true, the
  // caller routes the save through _SaveVirtualProjectReal (silent save-as into
  // the workspace home), NOT a bare DoSaveAll/DoSaveEditorFile.
  Result := False;
  if LazarusIDE = nil then
    Exit;
  LProj := LazarusIDE.ActiveProject;
  Result := (LProj <> nil) and LProj.IsVirtual;
end;

class function TAefosLazWorkspaceFacade._SanitizeUnitName(const AName: AnsiString): AnsiString;
const
  cDefaultName: AnsiString = 'project';
var
  LIdx: Integer;
  LCh: AnsiChar;
begin
  Result := '';
  for LIdx := 1 to Length(AName) do
  begin
    LCh := AName[LIdx];
    if ((LCh >= 'A') and (LCh <= 'Z')) or ((LCh >= 'a') and (LCh <= 'z'))
       or ((LCh >= '0') and (LCh <= '9')) or (LCh = '_') then
      Result := Result + LCh;
    // every other byte (space, punctuation, non-ASCII) is dropped - identifiers
    // are ASCII alnum/underscore only.
  end;
  // Must not start with a digit.
  if (Length(Result) > 0) and (Result[1] >= '0') and (Result[1] <= '9') then
    Result := '_' + Result;
  if Length(Result) = 0 then
    Result := cDefaultName;
end;

class function TAefosLazWorkspaceFacade._ResolveVirtualHome(out AHomeDir,
  AMainName: AnsiString): Boolean;
const
  cEnvAppData: AnsiString = 'APPDATA';
  cVendorDir: AnsiString = 'Aefos';
  cWorkspaceDir: AnsiString = 'lazarus-workspace';
var
  LProj: TLazProject;
  LInfo, LAppData: AnsiString;
begin
  Result := False;
  AHomeDir := '';
  AMainName := '';
  if LazarusIDE = nil then
    Exit;
  LProj := LazarusIDE.ActiveProject;
  if LProj = nil then
    Exit;
  // Preferred source of truth: the ProjectInfoFile set at CreateNewProject time
  // (an absolute <workspace>\<name>\<name>.lpi). Its directory is the home and
  // its basename the chosen name.
  LInfo := LProj.ProjectInfoFile;
  if (Length(LInfo) > 0) and FilenameIsAbsolute(LInfo) then
  begin
    AHomeDir := AppendPathDelim(ExtractFilePath(LInfo));
    AMainName := _SanitizeUnitName(ExtractFileNameOnly(LInfo));
    Result := Length(AHomeDir) > 0;
    Exit;
  end;
  // Fallback: build a home under %APPDATA%\Aefos\lazarus-workspace\<title>.
  LAppData := GetEnvironmentVariableUTF8(cEnvAppData);
  if Length(LAppData) = 0 then
    Exit;
  AMainName := _SanitizeUnitName(Trim(LProj.Title));
  AHomeDir := AppendPathDelim(LAppData) + cVendorDir;
  AHomeDir := AppendPathDelim(AHomeDir) + cWorkspaceDir;
  AHomeDir := AppendPathDelim(AHomeDir) + AMainName;
  AHomeDir := AppendPathDelim(AHomeDir);
  Result := True;
end;

class function TAefosLazWorkspaceFacade._SaveVirtualProjectReal: Boolean;
var
  LHome, LMainName: AnsiString;
  LSavedClass: TIDESaveDialogClass;
begin
  Result := False;
  if LazarusIDE = nil then
    Exit;
  if not _ResolveVirtualHome(LHome, LMainName) then
  begin
    // No real home resolvable: keep the never-block guarantee with the IDE's own
    // silent test-dir copy (default names, but no dialog).
    Result := LazarusIDE.DoSaveProject([sfSaveToTestDir]) = mrOk;
    Exit;
  end;
  ForceDirectoriesUTF8(LHome);
  LSavedClass := IDESaveDialogClass;
  GSilentSaveHome := LHome;
  GSilentSaveMainName := LMainName;
  GSilentSaveActive := True;
  try
    // Install the silent dialog, then DoSaveAll -> SaveProject: the virtual
    // project forces a Save-As for the .lpi and each virtual unit; every Execute
    // is redirected into LHome with no modal. mrOk => on disk and non-virtual.
    IDESaveDialogClass := TAefosSilentSaveDialog;
    Result := LazarusIDE.DoSaveAll([]) = mrOk;
  finally
    IDESaveDialogClass := LSavedClass;
    GSilentSaveActive := False;
    GSilentSaveHome := '';
    GSilentSaveMainName := '';
  end;
end;

function TAefosLazWorkspaceFacade.SaveActiveFile(out AChanged: Boolean): Boolean;
var
  LEditor: TSourceEditorInterface;
begin
  AChanged := False;
  Result := False;
  LEditor := _ActiveEditor;
  if LEditor = nil then
    Exit;
  AChanged := LEditor.Modified; // report whether there was anything to persist
  if LazarusIDE = nil then
    Exit;
  if _ActiveProjectIsVirtual then
    // Virtual project: the active unit has no on-disk path, so saving one file
    // still requires a project home. There is no "save this virtual unit alone" -
    // the IDE would pop the Save-As dialog. Materialize the whole project for real
    // into the workspace home (silent), which persists the active file too.
    Result := _SaveVirtualProjectReal
  else
    // DoSaveEditorFile(editor, []) writes the buffer to disk (lazideintf.pas:338).
    Result := LazarusIDE.DoSaveEditorFile(LEditor, []) = mrOk;
end;

function TAefosLazWorkspaceFacade.SaveAllFiles(out AChanged: Boolean): Boolean;
begin
  AChanged := False;
  Result := False;
  if LazarusIDE = nil then
    Exit;
  if _ActiveProjectIsVirtual then
    // Virtual project: a bare DoSaveAll pops the native "Save project" dialog
    // (blocking the MCP pipe). Materialize it for real into the workspace home
    // via the silent-dialog swap - the .lpi + every unit land on disk under the
    // chosen name and the project turns non-virtual (Save state clears).
    Result := _SaveVirtualProjectReal
  else
    // DoSaveAll saves every dirty editor + the project (lazideintf.pas:342).
    Result := LazarusIDE.DoSaveAll([]) = mrOk;
  AChanged := Result;
end;

function TAefosLazWorkspaceFacade.UndoEditor: Boolean;
const
  // ecUndo = 601 (components\synedit\syneditkeycmds.pp:256). Declared locally so
  // the design package needs no SynEdit package dependency for one command id.
  cEcUndo = 601;
var
  LEditor: TSourceEditorInterface;
begin
  Result := False;
  LEditor := _ActiveEditor;
  if LEditor = nil then
    Exit;
  _EnsureCodeEditorFront(LEditor);
  LEditor.DoEditorExecuteCommand(cEcUndo); // one editor undo step
  Result := True;
end;

function TAefosLazWorkspaceFacade.CloseFile(const AFilePath: string; const ASaveFirst: Boolean): Boolean;
begin
  raise ENotSupportedException.Create('CloseFile: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.GetSearchPath: TArray<string>;
begin
  raise ENotSupportedException.Create('GetSearchPath: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.SetSearchPath(const APaths: TArray<string>): Boolean;
begin
  raise ENotSupportedException.Create('SetSearchPath: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.AddToSearchPath(const APath: string): Boolean;
begin
  raise ENotSupportedException.Create('AddToSearchPath: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.GetConditionalDefines: TArray<string>;
begin
  raise ENotSupportedException.Create('GetConditionalDefines: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.SetConditionalDefines(const ADefines: TArray<string>): Boolean;
begin
  raise ENotSupportedException.Create('SetConditionalDefines: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.AddConditionalDefine(const ADefine: string): Boolean;
begin
  raise ENotSupportedException.Create('AddConditionalDefine: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.RemoveConditionalDefine(const ADefine: string): Boolean;
begin
  raise ENotSupportedException.Create('RemoveConditionalDefine: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.GetDCUOutputDir: string;
begin
  raise ENotSupportedException.Create('GetDCUOutputDir: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.SetDCUOutputDir(const ADir: string): Boolean;
begin
  raise ENotSupportedException.Create('SetDCUOutputDir: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.CleanProject: Boolean;
begin
  raise ENotSupportedException.Create('CleanProject: Lazarus backend phase H+');
end;

// Runtime tools (the Lazarus twin of the OTA facade RunProject /
// RunWithoutDebugger / StopProject). RunProject drives LazarusIDE.DoRunProject
// (the IDE's Run / F9, WITH the debugger) and confirms the launch by BOUNDED-
// POLLING ToolStatus for the debug session to actually come up (so a compile
// error, or an app that exits instantly, yields False - not a false positive,
// mirroring the Delphi RunService bounded-poll). BR-6 dedup: a second RunProject
// while already debugging returns True (honest "already running", no double-launch).
function TAefosLazWorkspaceFacade.RunProject: Boolean;
var
  LTries: Integer;
begin
  Result := False;
  if LazarusIDE = nil then
    Exit;
  if LazarusIDE.ActiveProject = nil then
    Exit;
  if LazarusIDE.ToolStatus = itDebugger then
    Exit(True); // already running under the debugger - honest True, no re-launch
  LazarusIDE.DoRunProject; // builds first, then launches under the debugger
  // DoRunProject only ARMS the debugger: TDebugManager.StartDebugging kicks off
  // via a timer, so the process comes up ASYNC (debugmanager.pas) - a single
  // immediate ToolStatus check races the launch and would false-positive. Poll
  // ~1.5s (30 x 50 ms), pumping the message loop so the timer fires, until the
  // IDE reports itDebugger (a real live-debug-session signal).
  LTries := 0;
  while (LTries < 30) and (LazarusIDE.ToolStatus <> itDebugger) do
  begin
    Application.ProcessMessages;
    Sleep(50);
    Inc(LTries);
  end;
  // Confirm: applied True only when a debugged process is actually live now (an
  // app that never launched, or exited before the poll ended, stays non-itDebugger).
  Result := LazarusIDE.ToolStatus = itDebugger;
end;

function TAefosLazWorkspaceFacade.RunWithoutDebugger: Boolean;
begin
  // Runs detached (Ctrl+Shift+F9) - no debugger to confirm against, so mrOk from
  // DoRunProjectWithoutDebug IS the launch signal (matches the Delphi contract
  // that a detached run cannot be StopProject-ed).
  Result := False;
  if LazarusIDE = nil then
    Exit;
  if LazarusIDE.ActiveProject = nil then
    Exit;
  Result := LazarusIDE.DoRunProjectWithoutDebug = mrOk;
end;

function TAefosLazWorkspaceFacade.StopProject: Boolean;
begin
  // Idempotent (parity with the Delphi StopProject/StopRunningApp): applied True
  // whether or not a debugged process was running. Only a debugger-attached run
  // (DoRunProject) can be stopped; a RunWithoutDebugger process is detached.
  Result := True;
  if LazarusIDE = nil then
    Exit;
  if LazarusIDE.ToolStatus = itDebugger then
    ExecuteIDECommand(nil, ecStopProgram);
end;

function TAefosLazWorkspaceFacade.SendKeystroke(const AKeys: string): Boolean;
begin
  raise ENotSupportedException.Create('SendKeystroke: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.GetDPRContent: string;
begin
  raise ENotSupportedException.Create('GetDPRContent: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.SetDPRContent(const ASource: string; out AReason: string): Boolean;
begin
  raise ENotSupportedException.Create('SetDPRContent: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.RenameDPR(const ANewName: string; out AReason: string): Boolean;
begin
  raise ENotSupportedException.Create('RenameDPR: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.GetDPRUsedForms: TArray<TMCPRecordDPRCreateForm>;
begin
  raise ENotSupportedException.Create('GetDPRUsedForms: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.GetMainForm: string;
begin
  raise ENotSupportedException.Create('GetMainForm: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.SetMainForm(const AFormClass: string; out AChanged: Boolean; out AReason: string): Boolean;
begin
  raise ENotSupportedException.Create('SetMainForm: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.ListProjectForms: TArray<TMCPRecordProjectForm>;
begin
  raise ENotSupportedException.Create('ListProjectForms: Lazarus backend phase H+');
end;

// ===========================================================================
// Phase J - LIVE FORM DESIGNER. The design members are now LIVE, delegating to
// the TAefosLazFormDesigner engine (Aefos.Lazarus.FormDesigner) on the Lazarus
// IDEIntf/designer seams. This backend is delphiunicode; the engine is mode
// delphi (UTF-8 `string`, the LCL convention), so every value crossing the
// boundary is converted through _ToLcl / _FromLcl - exactly as the editor-write
// slice already does. These run on the IDE main thread (the host marshals once).
//
// Design READS serialize the LIVE form to .lfm text (reflecting unsaved edits)
// and parse it with the thin TLFMParser (the .lfm text format is byte-identical
// to .dfm, so the shared parser applies verbatim). Reads never touch the view.
// Design MUTATIONS EnsureDesignView + end in Design inside the engine (RULE #1).
// ===========================================================================

function TAefosLazWorkspaceFacade.GetDFMContent(const AUnitName: string; out AContent: string; out AIsBinary: Boolean): Boolean;
var
  LLfm: AnsiString;
begin
  AContent  := '';
  AIsBinary := False; // a live-form serialization is always text
  Result := TAefosLazFormDesigner.GetLiveFormLfm(_ToLcl(AUnitName), LLfm);
  if Result then
    AContent := _FromLcl(LLfm);
end;

function TAefosLazWorkspaceFacade.SetDFMContent(const AUnitName, ADFMSource: string; out AReason: string): Boolean;
begin
  // A wholesale .lfm text REPLACEMENT (disk write + reload + the pas<->lfm and
  // designer-required guards) is a heavier, disk-oriented path than Phase J's
  // live-designer mutations. A NEW control must enter via AddComponent (it
  // sprouts live + the IDE declares the field); restyle/reposition go through
  // SetComponentProperty. Honest stub until the disk-DFM slice lands.
  raise ENotSupportedException.Create('SetDFMContent: Lazarus backend phase I+ (use AddComponent/SetComponentProperty)');
end;

function TAefosLazWorkspaceFacade.GetFormProperties(const AUnitName: string; out AProperties: TArray<TMCPRecordDFMProperty>): Boolean;
var
  LLfm: AnsiString;
  LLfmU: string;
  LPairs: TArray<TLFMPropertyPair>;
  LI: Integer;
begin
  AProperties := nil;
  Result := TAefosLazFormDesigner.GetLiveFormLfm(_ToLcl(AUnitName), LLfm);
  if not Result then
    Exit;
  LLfmU := _FromLcl(LLfm);
  LPairs := TLFMParser.ExtractTopLevelProperties(LLfmU);
  SetLength(AProperties, Length(LPairs));
  for LI := 0 to High(LPairs) do
  begin
    AProperties[LI].Name  := LPairs[LI].Name;
    AProperties[LI].Value := LPairs[LI].Value;
  end;
end;

function TAefosLazWorkspaceFacade.SetFormProperty(const AUnitName, APropName, APropValue: string; out AChanged: Boolean; out AReason: string): Boolean;
var
  LReason: AnsiString;
begin
  Result := TAefosLazFormDesigner.SetFormProperty(_ToLcl(AUnitName),
    _ToLcl(APropName), _ToLcl(APropValue), LReason);
  AChanged := Result;
  if Result then AReason := '' else AReason := _FromLcl(LReason);
end;

function TAefosLazWorkspaceFacade.ListFormComponents(const AUnitName: string; out AComponents: TArray<TMCPRecordDFMComponent>): Boolean;
var
  LLfm: AnsiString;
  LLfmU: string;
  LChildren: TArray<TLFMComponentRef>;
  LI: Integer;
begin
  AComponents := nil;
  Result := TAefosLazFormDesigner.GetLiveFormLfm(_ToLcl(AUnitName), LLfm);
  if not Result then
    Exit;
  LLfmU := _FromLcl(LLfm);
  // Every depth, not just the form's direct children -- see the note on
  // TDFMParser.EnumerateAllComponents. Same defect, same fix, both editions.
  LChildren := TLFMParser.EnumerateAllComponents(LLfmU);
  SetLength(AComponents, Length(LChildren));
  for LI := 0 to High(LChildren) do
  begin
    AComponents[LI].Name     := LChildren[LI].Name;
    AComponents[LI].TypeName := LChildren[LI].TypeName;
    AComponents[LI].Owner    := LChildren[LI].Owner;
  end;
end;

function TAefosLazWorkspaceFacade.GetComponentProperties(const AUnitName, AComponentName: string; out AProperties: TArray<TMCPRecordDFMProperty>): Boolean;
var
  LLfm: AnsiString;
  LLfmU: string;
  LPairs: TArray<TLFMPropertyPair>;
  LI: Integer;
begin
  AProperties := nil;
  Result := TAefosLazFormDesigner.GetLiveFormLfm(_ToLcl(AUnitName), LLfm);
  if not Result then
    Exit;
  LLfmU := _FromLcl(LLfm);
  LPairs := TLFMParser.ExtractComponentProperties(LLfmU, AComponentName);
  SetLength(AProperties, Length(LPairs));
  for LI := 0 to High(LPairs) do
  begin
    AProperties[LI].Name  := LPairs[LI].Name;
    AProperties[LI].Value := LPairs[LI].Value;
  end;
end;

function TAefosLazWorkspaceFacade.SetComponentProperty(const AUnitName, AComponentName, APropName, APropValue: string; out AChanged: Boolean; out AReason: string): Boolean;
var
  LReason: AnsiString;
begin
  Result := TAefosLazFormDesigner.SetComponentProperty(_ToLcl(AUnitName),
    _ToLcl(AComponentName), _ToLcl(APropName), _ToLcl(APropValue), LReason);
  AChanged := Result;
  if Result then AReason := '' else AReason := _FromLcl(LReason);
end;

function TAefosLazWorkspaceFacade.OpenFormDesigner(const AUnitName: string; out AChanged: Boolean; out AReason: string): Boolean;
var
  LReason: AnsiString;
begin
  Result := TAefosLazFormDesigner.ShowFormDesigner(_ToLcl(AUnitName), LReason);
  AChanged := Result;
  if Result then AReason := '' else AReason := _FromLcl(LReason);
end;

function TAefosLazWorkspaceFacade.OpenDFMTextEditor(const AUnitName: string; out AChanged: Boolean; out AReason: string): Boolean;
begin
  // Opening the .lfm AS TEXT is a project/editor-open concern (Phase I): Lazarus
  // does not expose a package seam to force a text view of a designed .lfm
  // without CodeTools file-open plumbing. Honest stub until then.
  raise ENotSupportedException.Create('OpenDFMTextEditor: Lazarus backend phase I+');
end;

function TAefosLazWorkspaceFacade.RemoveComponent(const AUnitName, AComponentName: string; out AChanged: Boolean; out AReason: string): Boolean;
var
  LReason: AnsiString;
begin
  Result := TAefosLazFormDesigner.RemoveComponent(_ToLcl(AUnitName),
    _ToLcl(AComponentName), LReason);
  AChanged := Result;
  if Result then AReason := '' else AReason := _FromLcl(LReason);
end;

function TAefosLazWorkspaceFacade.AddComponent(const AUnitName, AComponentClass, AComponentName, AParent: string; const ALeft, ATop, AWidth, AHeight: Integer; out AChanged: Boolean; out AReason: string): Boolean;
var
  LReason: AnsiString;
begin
  Result := TAefosLazFormDesigner.AddComponent(_ToLcl(AUnitName),
    _ToLcl(AComponentClass), _ToLcl(AComponentName), _ToLcl(AParent),
    ALeft, ATop, AWidth, AHeight, LReason);
  AChanged := Result;
  if Result then AReason := '' else AReason := _FromLcl(LReason);
end;

function TAefosLazWorkspaceFacade.AddEventHandler(const AUnitName, AComponentName, AEventName, AHandlerName, ABody: string; out AChanged: Boolean; out AReason: string): Boolean;
var
  LReason: AnsiString;
begin
  Result := TAefosLazFormDesigner.AddEventHandler(_ToLcl(AUnitName),
    _ToLcl(AComponentName), _ToLcl(AEventName), _ToLcl(AHandlerName),
    _ToLcl(ABody), LReason);
  AChanged := Result;
  if Result then AReason := '' else AReason := _FromLcl(LReason);
end;

function TAefosLazWorkspaceFacade.GetSymbolsInUnit(const AUnitName: string; out ASymbols: TArray<TMCPRecordUnitSymbol>): Boolean;
begin
  raise ENotSupportedException.Create('GetSymbolsInUnit: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.GetClassMembers(const AUnitName, AClassName: string; out AMembers: TArray<TMCPRecordClassMember>): Boolean;
begin
  raise ENotSupportedException.Create('GetClassMembers: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.FindSymbolUsages(const ASymbol: string; out AUsages: TArray<TMCPRecordSymbolUsage>): Boolean;
begin
  raise ENotSupportedException.Create('FindSymbolUsages: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.GetMethodBody(const AUnitName, AMethodName: string; out ABody: string): Boolean;
begin
  raise ENotSupportedException.Create('GetMethodBody: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.InsertMethod(const AUnitName, AClassName, ASignature, ABody: string; out AChanged: Boolean; out AReason: string): Boolean;
begin
  raise ENotSupportedException.Create('InsertMethod: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.GetInheritanceChain(const AClassName: string; out AChain: TArray<string>): Boolean;
begin
  raise ENotSupportedException.Create('GetInheritanceChain: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.GetProjectGroupName: string;
begin
  raise ENotSupportedException.Create('GetProjectGroupName: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.ListProjectsInGroup: TArray<TMCPRecordGroupProject>;
begin
  raise ENotSupportedException.Create('ListProjectsInGroup: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.SetActiveProject(const AProjectPath: string; out AChanged: Boolean; out AReason: string): Boolean;
begin
  raise ENotSupportedException.Create('SetActiveProject: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.AddProjectToGroup(const AProjectPath: string; out AChanged: Boolean; out AReason: string): Boolean;
begin
  raise ENotSupportedException.Create('AddProjectToGroup: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.RemoveProjectFromGroup(const AProjectPath: string; out AChanged: Boolean; out AReason: string): Boolean;
begin
  raise ENotSupportedException.Create('RemoveProjectFromGroup: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.BuildAllInGroup( out AResults: TArray<TMCPRecordGroupBuildResult>; out AReason: string): Boolean;
begin
  raise ENotSupportedException.Create('BuildAllInGroup: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.ListProjectPackages: TArray<TMCPRecordProjectPackage>;
begin
  raise ENotSupportedException.Create('ListProjectPackages: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.AddPackageToProject(const APackagePath: string; const ARuntime: Boolean; out AChanged: Boolean; out AReason: string): Boolean;
begin
  raise ENotSupportedException.Create('AddPackageToProject: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.RemovePackageFromProject(const APackageName: string; out AChanged: Boolean; out AReason: string): Boolean;
begin
  raise ENotSupportedException.Create('RemovePackageFromProject: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.GetLibraryPath: TArray<string>;
begin
  raise ENotSupportedException.Create('GetLibraryPath: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.AddToLibraryPath(const APath: string; out AChanged: Boolean; out AReason: string): Boolean;
begin
  raise ENotSupportedException.Create('AddToLibraryPath: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.GetIDEVersion: TMCPRecordIDEVersion;
begin
  raise ENotSupportedException.Create('GetIDEVersion: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.ShowIDEMessage(const AText: string; const AUseOutput: Boolean): Boolean;
begin
  raise ENotSupportedException.Create('ShowIDEMessage: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.GetIDETheme: string;
begin
  raise ENotSupportedException.Create('GetIDETheme: Lazarus backend phase H+');
end;

class function TAefosLazWorkspaceFacade._ClassifyIDEAction(const AActionName: string;
  out AReason: string): Boolean;
const
  // Mirror of the OTA CHardBlockTokens / CSoftBlockTokens (FormUsesWrite
  // Policy.pas:98/102) - kept in sync byte-for-byte with the Delphi edition.
  CHardBlockTokens: array[0..5] of string =
    ('exit', 'quit', 'terminate', 'kill', 'erase', 'uninstall');
  CSoftBlockTokens: array[0..5] of string =
    ('delete', 'remove', 'clean', 'revert', 'reset', 'drop');
var
  LName, LLower: string;
  LFor: Integer;
begin
  AReason := '';
  LName := Trim(AActionName);
  if LName = '' then
  begin
    AReason := 'empty-action';
    Exit(False);
  end;
  LLower := LowerCase(LName);
  for LFor := Low(CHardBlockTokens) to High(CHardBlockTokens) do
    if Pos(CHardBlockTokens[LFor], LLower) > 0 then
    begin
      AReason := 'destructive-action-refused';
      Exit(False);
    end;
  for LFor := Low(CSoftBlockTokens) to High(CSoftBlockTokens) do
    if Pos(CSoftBlockTokens[LFor], LLower) > 0 then
    begin
      AReason := 'destructive-action-soft-blocked';
      Exit(False);
    end;
  Result := True;
end;

class function TAefosLazWorkspaceFacade._DumpIDEActionCatalog: UnicodeString;
var
  LLog: TStringList;
  LPath: AnsiString;
  LCatIdx, LCmdIdx: Integer;
  LCat: TIDECommandCategory;
  LCmd: TIDECommand;
begin
  LLog := TStringList.Create;
  try
    try
      LPath := AppendPathDelim(SysUtils.GetTempDir(False)) + 'ds_ide_actions.txt';
      if IDECommandList <> nil then
        for LCatIdx := 0 to IDECommandList.CategoryCount - 1 do
        begin
          LCat := IDECommandList.Categories[LCatIdx];
          if LCat = nil then
            Continue;
          LLog.Add('## ' + LCat.Name);
          for LCmdIdx := 0 to LCat.Count - 1 do
          begin
            LCmd := TIDECommand(LCat.Items[LCmdIdx]);
            if LCmd = nil then
              Continue;
            LLog.Add(LCmd.Name + '|' + LCmd.LocalizedName);
          end;
        end;
      LLog.SaveToFile(LPath);
      Result := 'DUMP ' + IntToStr(LLog.Count) + ' lines -> ' + _FromLcl(LPath);
    except
      on E: Exception do
        Result := 'DUMP-FAILED: ' + _FromLcl(E.ClassName) + ': ' + _FromLcl(E.Message);
    end;
  finally
    LLog.Free;
  end;
end;

function TAefosLazWorkspaceFacade.ExecuteIDEAction(const AActionName: string; out AReason: string): Boolean;
var
  LName: string;
  LCmd: TIDECommand;
begin
  // Fires a named IDE command by name - the Lazarus twin of the OTA
  // IDEService.ExecuteIDEAction (source\mcp\OTA\...IDEService.pas:216). The
  // action name comes from ListIDEActions (same IDECommandList source, so a
  // discovered name always resolves here). CONSENT-GATED at the MCP handler
  // (mirror of the Delphi _Gate); this facade adds only the pure block-token
  // safety net. NOT view-guarded (RULE #1): it can even flip the view itself
  // (e.g. ecToggleFormUnit = F12), so it is deliberately exempt from the
  // design/code intent guard.
  Result := False;
  AReason := '';
  LName := Trim(AActionName);

  // Discovery escape hatch: '?' dumps the whole catalog to a temp file.
  if LName = '?' then
  begin
    AReason := _DumpIDEActionCatalog;
    Exit(False);
  end;

  if not _ClassifyIDEAction(LName, AReason) then
    Exit(False);

  if IDECommandList = nil then
  begin
    AReason := 'no-ide-command-list';
    Exit(False);
  end;

  // FindCommandByName resolves the SAME .Name that ListIDEActions exposes
  // (idecommands.pas:692). The name crosses to the UTF-8 (LCL) boundary.
  LCmd := IDECommandList.FindCommandByName(_ToLcl(LName));
  if LCmd = nil then
  begin
    AReason := 'action not found: ' + LName
      + ' (use ListIDEActions to discover the name)';
    Exit(False);
  end;

  if not LCmd.Enabled then
  begin
    AReason := 'action-disabled';
    Exit(False);
  end;

  // TIDECommand.Execute returns False when the command carries neither an
  // OnExecute nor an OnExecuteProc handler (idecommands.pas:1606) - the Lazarus
  // twin of "no action to invoke". Any handler exception is caught and surfaced
  // as the reason (mirror of the OTA except-guard).
  try
    if LCmd.Execute(nil) then
    begin
      AReason := '';
      Result := True;
    end
    else
      AReason := 'action-has-no-executor';
  except
    on E: Exception do
    begin
      Result := False;
      AReason := _FromLcl(E.Message);
    end;
  end;
end;

function TAefosLazWorkspaceFacade.GetProjectManagerTree: TArray<TMCPRecordProjectManagerNode>;
begin
  raise ENotSupportedException.Create('GetProjectManagerTree: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.RefreshProjectManager: Boolean;
begin
  raise ENotSupportedException.Create('RefreshProjectManager: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.GetRecentFiles: TArray<string>;
begin
  raise ENotSupportedException.Create('GetRecentFiles: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.RunExternalTool(const AArgv: TArray<string>; out ARun: TMCPRecordExternalToolRun; out AReason: string): Boolean;
begin
  raise ENotSupportedException.Create('RunExternalTool: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.ListProjectResources: TArray<TMCPRecordProjectResource>;
begin
  raise ENotSupportedException.Create('ListProjectResources: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.AddResourceFile(const AFilePath: string; out AChanged: Boolean; out AReason: string): Boolean;
begin
  raise ENotSupportedException.Create('AddResourceFile: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.ListProjectImages: TArray<string>;
begin
  raise ENotSupportedException.Create('ListProjectImages: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.RenameProject(const AOldName, ANewName: string; out AOutcome: TRenameOutcome): Boolean;
begin
  raise ENotSupportedException.Create('RenameProject: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.RenameUnit(const AUnitName, ANewUnitName: string; out AOutcome: TRenameOutcome): Boolean;
begin
  raise ENotSupportedException.Create('RenameUnit: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.MoveUnitToFolder(const AUnitName, ATargetFolder: string; out AOutcome: TRenameOutcome): Boolean;
begin
  raise ENotSupportedException.Create('MoveUnitToFolder: Lazarus backend phase H+');
end;

function TAefosLazWorkspaceFacade.OpenFile(const APath: string): Boolean;
begin
  raise ENotSupportedException.Create('OpenFile: Lazarus backend phase H+');
end;

{$pop}

function NewAefosLazWorkspaceFacade: IMCPWorkspaceFacade;
begin
  Result := TAefosLazWorkspaceFacade.Create;
end;

end.
