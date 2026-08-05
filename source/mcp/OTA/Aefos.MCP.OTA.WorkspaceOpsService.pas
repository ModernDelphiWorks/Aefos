unit Aefos.MCP.OTA.WorkspaceOpsService;

{
  The remaining editor + file + workspace operations, extracted from the
  TMCPWorkspaceFacade god-object as the FINAL focused service of the SOLID split
  (audit S6 / facade split).

  Owns the leftover real-body methods: the confined file overwrite, the editor
  navigation/save/undo/close ops, the in-editor and in-project text searches, and
  RenameProject. With this slice moved, the facade becomes a pure delegation
  shell.

  FAudit (IMCPAuditLog) and the editor-read service (IMCPEditorReadService) are
  INJECTED — the facade still owns FAudit (writes nav/edit lines from several
  domains) and the editor-read service (an earlier extraction), and hands both to
  this service's constructor. OpenUnitInEditor + SetEditorCursorPosition keep
  their FAudit.Append nav annotations; GetEditorFullContent + FindInEditor read
  the active buffer through FEditorRead.GetActiveUnit.

  Bodies moved VERBATIM from the facade (only the class qualifier changes on the
  methods, plus GetActiveUnit -> FEditorRead.GetActiveUnit in the two reads that
  self-called it). The facade delegates the thirteen frozen methods to a
  refcounted FWorkspaceOps field.
}

interface

uses
  Aefos.MCP.Types,
  Aefos.MCP.AuditLog,
  Aefos.MCP.OTA.EditorReadService;

type
  IMCPWorkspaceOpsService = interface
    ['{7B4C1E94-2D86-4A50-9F38-3C6A1B5E8D72}']
    function OverwriteFile(const AFilePath, AContent: string;
      out AError: string): TMCPFileActionOutcome;
    function OpenUnitInEditor(const AUnitName: string): Boolean;
    function OpenFile(const APath: string): Boolean;
    function SetEditorCursorPosition(const ALine, ACol: Integer): Boolean;
    function ReplaceEditorSelection(const ANewText: string): Boolean;
    function GetEditorFullContent(out AContent: string): Boolean;
    function FindInEditor(const AText: string; const ACaseSensitive: Boolean;
      out AOccurrences: TArray<TMCPCursorInfo>): Boolean;
    function FindInProject(const AText: string; const ACaseSensitive: Boolean;
      out AOccurrences: TArray<TMCPCursorInfo>): Boolean;
    function SaveActiveFile(out AChanged: Boolean): Boolean;
    function SaveAllFiles(out AChanged: Boolean): Boolean;
    function UndoEditor: Boolean;
    function CloseFile(const AFilePath: string; const ASaveFirst: Boolean): Boolean;
    function RenameProject(const AOldName, ANewName: string;
      out AOutcome: TRenameOutcome): Boolean;
  end;

// Factory — the facade calls this once in its constructor, injecting the shared
// audit log it still owns and the editor-read service (an earlier extraction).
function NewMCPWorkspaceOpsService(const AAudit: IMCPAuditLog;
  const AEditorRead: IMCPEditorReadService): IMCPWorkspaceOpsService;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.Generics.Collections,
  ToolsAPI,
  Aefos.MCP.OTA.FacadeShared,
  Aefos.MCP.OTA.ReviewGate,
  Aefos.MCP.OTA.ContentWritePolicy,
  Aefos.MCP.OTA.UnitCreatePolicy,
  Aefos.MCP.OTA.StructuralWritePolicy,
  Aefos.Harness.View;

type
  TMCPWorkspaceOpsService = class(TInterfacedObject, IMCPWorkspaceOpsService)
  private
    // Cross-cutting audit log INJECTED by the facade (the facade still owns it and
    // writes nav/edit lines from other domains).
    FAudit: IMCPAuditLog;
    // Editor-read service INJECTED by the facade (an earlier extraction). The two
    // editor-content reads here self-called the facade's GetActiveUnit, which is
    // itself a delegation to this service.
    FEditorRead: IMCPEditorReadService;
  public
    constructor Create(const AAudit: IMCPAuditLog;
      const AEditorRead: IMCPEditorReadService);
    function OverwriteFile(const AFilePath, AContent: string;
      out AError: string): TMCPFileActionOutcome;
    function OpenUnitInEditor(const AUnitName: string): Boolean;
    function OpenFile(const APath: string): Boolean;
    function SetEditorCursorPosition(const ALine, ACol: Integer): Boolean;
    function ReplaceEditorSelection(const ANewText: string): Boolean;
    function GetEditorFullContent(out AContent: string): Boolean;
    function FindInEditor(const AText: string; const ACaseSensitive: Boolean;
      out AOccurrences: TArray<TMCPCursorInfo>): Boolean;
    function FindInProject(const AText: string; const ACaseSensitive: Boolean;
      out AOccurrences: TArray<TMCPCursorInfo>): Boolean;
    function SaveActiveFile(out AChanged: Boolean): Boolean;
    function SaveAllFiles(out AChanged: Boolean): Boolean;
    function UndoEditor: Boolean;
    function CloseFile(const AFilePath: string; const ASaveFirst: Boolean): Boolean;
    function RenameProject(const AOldName, ANewName: string;
      out AOutcome: TRenameOutcome): Boolean;
  end;

constructor TMCPWorkspaceOpsService.Create(const AAudit: IMCPAuditLog;
  const AEditorRead: IMCPEditorReadService);
begin
  inherited Create;
  FAudit := AAudit;
  FEditorRead := AEditorRead;
end;

// Write AContent to AFilePath, confined to the active scratch unit's directory
// (ESP-087, S2 / ADR-087-07). The OTA-free confinement predicate lives in
// ContentWritePolicy.ConfineWritePath; any path resolving outside the root is
// refused with a non-partial sentinel (faAccessError, no bytes written). The
// root is the directory of the active source editor — the scratch unit's folder.
function TMCPWorkspaceOpsService.OverwriteFile(const AFilePath,
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
      LEditor: IOTASourceEditor;
      LRoot: string;
      LPlan: TConfinedWrite;
    begin
      if not TFacadeShared.ActiveSourceEditor(LEditor) then
      begin
        LOutcome := faNoActiveProject;
        LError   := 'no-active-editor';
        Exit;
      end;
      LRoot := TPath.GetDirectoryName(LEditor.FileName);
      LPlan := TContentWritePolicy.ConfineWritePath(AFilePath, LRoot);
      if not LPlan.Accepted then
      begin
        // ADR-087-07 non-partial sentinel: no bytes written outside the root.
        LOutcome := faAccessError;
        LError   := LPlan.Reason;
        Exit;
      end;
      TFile.WriteAllText(LPlan.FullPath, AContent, TEncoding.UTF8);
      // Silent in-place reload: if the file is open, the tab live-updates and
      // the IDE never asks "file has been changed, reload?".
      TFacadeShared.RefreshModuleFromDisk(LPlan.FullPath);
      LOutcome := faApplied;
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

function TMCPWorkspaceOpsService.OpenUnitInEditor(
  const AUnitName: string): Boolean;
var
  LResult: Boolean;
begin
  LResult := False;
  try
    TThread.Synchronize(nil, procedure
    var
      LPath: string;
      LActions: IOTAActionServices;
      LModule: IOTAModule;
      LSource: IOTASourceEditor;
    begin
      // If the module is already open, Show its source editor — the OTA
      // equivalent of F12: flips the active view to Code even when the form
      // designer is in front. Mirrors OpenFormDesigner (IOTAFormEditor.Show).
      if TFacadeShared.ResolveUnitModule(AUnitName, LModule) then
      begin
        LSource := TFacadeShared.FirstSourceEditor(LModule);
        if Assigned(LSource) then
        begin
          LSource.Show;
          LResult := True;
          Exit;
        end;
      end;
      // Fallback: open from disk when not already loaded.
      LPath := TFacadeShared.FindUnitPath(AUnitName);
      if LPath = '' then Exit;
      if not Assigned(BorlandIDEServices) then Exit;
      if not Supports(BorlandIDEServices, IOTAActionServices, LActions) then Exit;
      LResult := LActions.OpenFile(LPath);
    end);
  except
    LResult := False;
  end;
  Result := LResult;
  // Consumer-side audit annotation (ESP-095, #10). Core classifies this tool as
  // nav/view and bypasses its consent/audit gate, so it never reaches
  // QueryAuditLog even though it applies a real OTA effect. Record it here with
  // an additive 'nav'/'applied' value (frozen schema, mirroring the
  // timeout-denied line) so the navigation is observable. Only a navigation that
  // actually applied is logged.
  if LResult then
    FAudit.Append('OpenUnitInEditor', AUnitName, 'nav', 'applied');
end;

// Opens any file/project/group by absolute path (IOTAActionServices.OpenFile —
// the same call OpenUnitInEditor falls back to). Used by CreateProjectFromTemplate
// to open the freshly materialised .dproj/.groupproj.
function TMCPWorkspaceOpsService.OpenFile(const APath: string): Boolean;
var
  LResult: Boolean;
begin
  Result := False;
  if Trim(APath) = '' then
    Exit;
  LResult := False;
  try
    TThread.Synchronize(nil,
      procedure
      var
        LActions: IOTAActionServices;
      begin
        if not Assigned(BorlandIDEServices) then Exit;
        if not Supports(BorlandIDEServices, IOTAActionServices, LActions) then Exit;
        LResult := LActions.OpenFile(APath);
      end);
  except
    LResult := False;
  end;
  Result := LResult;
end;

function TMCPWorkspaceOpsService.SetEditorCursorPosition(const ALine,
  ACol: Integer): Boolean;
var
  LResult: Boolean;
begin
  LResult := False;
  try
    TThread.Synchronize(nil, procedure
    var
      LES: IOTAEditorServices;
      LView: IOTAEditView;
      LPos: TOTAEditPos;
    begin
      if not Assigned(BorlandIDEServices) then Exit;
      if not Supports(BorlandIDEServices, IOTAEditorServices, LES) then Exit;
      LView := LES.TopView;
      if not Assigned(LView) then Exit;
      LPos.Line := ALine;
      LPos.Col  := ACol;
      LView.CursorPos := LPos;
      LView.Paint;
      LResult := True;
    end);
  except
    LResult := False;
  end;
  Result := LResult;
  // Consumer-side audit annotation (ESP-095, #10) — same rationale as
  // OpenUnitInEditor: a Core-classified nav tool with a real OTA effect that
  // bypasses the audit gate. Additive 'nav'/'applied' value, frozen schema.
  if LResult then
    FAudit.Append('SetEditorCursorPosition',
      Format('%d:%d', [ALine, ACol]), 'nav', 'applied');
end;

// Replace the active editor selection with ANewText (ESP-087, S2). The range
// splice is computed by ContentWritePolicy.ReplaceTextRange (end column
// exclusive, OTA block convention); a missing/invalid selection is a no-op
// False. Active-editor only (ADR-087-07).
function TMCPWorkspaceOpsService.ReplaceEditorSelection(
  const ANewText: string): Boolean;
var
  LPath, LCurrent, LNewWhole, LReason: string;
  LOk, LChanged: Boolean;
begin
  // R6: route the selection replace through the ✓/✗ review gate (parity with
  // EditUnit/AddToUses), instead of applying silently after one allow-for-session.
  // Read the live selection + buffer and compute the spliced whole-buffer UP FRONT
  // (outside the harness), so TReviewGate.ReviewBufferChange can show the diff before anything
  // is written; ddUnavailable falls through to the direct harness apply.
  LReason := '';
  LPath := '';
  LCurrent := '';
  LNewWhole := '';
  LOk := False;
  TThread.Synchronize(nil, procedure
  var
    LES: IOTAEditorServices;
    LView: IOTAEditView;
    LEditor: IOTASourceEditor;
    LBlock: IOTAEditBlock;
  begin
    if not TFacadeShared.ActiveSourceEditor(LEditor) then Exit;
    if not Supports(BorlandIDEServices, IOTAEditorServices, LES) then Exit;
    LView := LES.TopView;
    if not Assigned(LView) then Exit;
    LBlock := LView.Block;
    if not Assigned(LBlock) or not LBlock.IsValid then Exit;
    THarnessView.EnsureCodeView(LEditor); // intent->view: show Code before the diff paints
    LPath := LEditor.FileName;
    LCurrent := TFacadeShared.ReadBytes(LEditor.CreateReader);
    if not TContentWritePolicy.ReplaceTextRange(LCurrent, ANewText,
      LBlock.StartingRow, LBlock.StartingColumn,
      LBlock.EndingRow, LBlock.EndingColumn, LNewWhole) then
    begin
      LNewWhole := '';
      Exit;
    end;
    LOk := True;
  end);
  if not LOk then Exit(False); // no active view / no selection / splice failed

  case TReviewGate.ReviewBufferChange(LPath, LCurrent, LNewWhole, LReason) of
    ddApplied: Exit(True);   // the diff wrote the change
    ddRejected: Exit(True);  // user rejected in the diff — nothing written, no-op
    // ddUnavailable -> direct apply below (review off / no change)
  end;

  Result := THarnessView.WithLiveSource('', lsCodeMutation,
    procedure(const Ctx: ILiveSourceContext)
    begin
      Ctx.ReplaceWhole(LNewWhole);
    end,
    LChanged, LReason) and LChanged;
end;

function TMCPWorkspaceOpsService.GetEditorFullContent(
  out AContent: string): Boolean;
begin
  // GetActiveUnit reads the active editor buffer on the main thread (BR7).
  AContent := FEditorRead.GetActiveUnit;
  Result   := AContent <> '';
end;

function TMCPWorkspaceOpsService.FindInEditor(const AText: string;
  const ACaseSensitive: Boolean;
  out AOccurrences: TArray<TMCPCursorInfo>): Boolean;
var
  LBody, LSearchLine, LSearchNeedle: string;
  LLines: TArray<string>;
  LForLine, LAt, LStart: Integer;
  LList: TList<TMCPCursorInfo>;
  LPos: TMCPCursorInfo;
begin
  AOccurrences := [];
  Result := False;
  if AText = '' then Exit;
  LBody := FEditorRead.GetActiveUnit;
  if LBody = '' then Exit;
  LList := TList<TMCPCursorInfo>.Create;
  try
    LLines := LBody.Split([#13#10, #13, #10]);
    for LForLine := 0 to High(LLines) do
    begin
      LSearchLine := LLines[LForLine];
      LSearchNeedle := AText;
      if not ACaseSensitive then
      begin
        LSearchLine := LSearchLine.ToLower;
        LSearchNeedle := LSearchNeedle.ToLower;
      end;
      LStart := 1;
      repeat
        LAt := Pos(LSearchNeedle, LSearchLine, LStart);
        if LAt = 0 then Break;
        LPos := Default(TMCPCursorInfo);
        LPos.Line      := LForLine + 1;
        LPos.Column    := LAt;
        LPos.Available := True;
        LList.Add(LPos);
        LStart := LAt + Length(LSearchNeedle);
      until False;
    end;
    AOccurrences := LList.ToArray;
    Result := True;
  finally
    LList.Free;
  end;
end;

// Reads a file from disk and appends one TMCPCursorInfo per text match.
procedure _SearchFileContent(const APath, AText: string;
  const ACaseSensitive: Boolean; const AList: TList<TMCPCursorInfo>);
var
  LBody, LSearchLine, LSearchNeedle: string;
  LLines: TArray<string>;
  LForLine, LAt, LStart: Integer;
  LPos: TMCPCursorInfo;
begin
  if (AText = '') or not TFile.Exists(APath) then Exit;
  try
    LBody := TFile.ReadAllText(APath);
  except
    LBody := '';
  end;
  if LBody = '' then Exit;
  LLines := LBody.Split([#13#10, #13, #10]);
  for LForLine := 0 to High(LLines) do
  begin
    LSearchLine := LLines[LForLine];
    LSearchNeedle := AText;
    if not ACaseSensitive then
    begin
      LSearchLine := LSearchLine.ToLower;
      LSearchNeedle := LSearchNeedle.ToLower;
    end;
    LStart := 1;
    repeat
      LAt := Pos(LSearchNeedle, LSearchLine, LStart);
      if LAt = 0 then Break;
      LPos := Default(TMCPCursorInfo);
      LPos.UnitPath  := APath;
      LPos.Line      := LForLine + 1;
      LPos.Column    := LAt;
      LPos.Available := True;
      AList.Add(LPos);
      LStart := LAt + Length(LSearchNeedle);
    until False;
  end;
end;

function TMCPWorkspaceOpsService.FindInProject(const AText: string;
  const ACaseSensitive: Boolean;
  out AOccurrences: TArray<TMCPCursorInfo>): Boolean;
var
  LPaths: TArray<string>;
  LFor: Integer;
  LList: TList<TMCPCursorInfo>;
begin
  AOccurrences := [];
  Result := False;
  if AText = '' then Exit;
  LPaths := nil;
  try
    TThread.Synchronize(nil, procedure
    begin
      LPaths := TFacadeShared.EnumProjectUnitPaths;
    end);
  except
    LPaths := nil;
  end;
  if Length(LPaths) = 0 then Exit;
  LList := TList<TMCPCursorInfo>.Create;
  try
    for LFor := 0 to High(LPaths) do
      _SearchFileContent(LPaths[LFor], AText, ACaseSensitive, LList);
    AOccurrences := LList.ToArray;
    Result := True;
  finally
    LList.Free;
  end;
end;

function TMCPWorkspaceOpsService.SaveActiveFile(
  out AChanged: Boolean): Boolean;
var
  LResult, LChanged: Boolean;
begin
  LResult  := False;
  LChanged := False;
  try
    TThread.Synchronize(nil, procedure
    var
      LBuffer: IOTAEditBuffer;
      LModule: IOTAModule;
    begin
      if not TFacadeShared.TryBuffer(LBuffer) then Exit;
      // Strip any pending review "before" blocks first so the write is the final text.
      TReviewGate.RunReviewSaveFlush;
      if not TFacadeShared.ResolveUnitModule(LBuffer.FileName, LModule) then Exit;
      LChanged := TFacadeShared.IsModuleModified(LModule);
      if LChanged then
        LResult := LModule.Save(False, True)
      else
        LResult := True;
    end);
  except
    LResult  := False;
    LChanged := False;
  end;
  AChanged := LChanged;
  Result   := LResult;
end;

function TMCPWorkspaceOpsService.SaveAllFiles(
  out AChanged: Boolean): Boolean;
var
  LResult, LChanged: Boolean;
begin
  LResult  := False;
  LChanged := False;
  try
    TThread.Synchronize(nil, procedure
    var
      LMS: IOTAModuleServices;
      LIdx: Integer;
      LModule: IOTAModule;
    begin
      if not TFacadeShared.TryModuleServices(LMS) then Exit;
      // Strip any pending review "before" blocks first so writes are the final text.
      TReviewGate.RunReviewSaveFlush;
      LResult := True;
      for LIdx := 0 to LMS.ModuleCount - 1 do
      begin
        LModule := LMS.Modules[LIdx];
        if TFacadeShared.IsModuleModified(LModule) then
        begin
          if LModule.Save(False, True) then
            LChanged := True
          else
            LResult := False;
        end;
      end;
    end);
  except
    LResult  := False;
    LChanged := False;
  end;
  AChanged := LChanged;
  Result   := LResult;
end;

function TMCPWorkspaceOpsService.UndoEditor: Boolean;
var
  LResult: Boolean;
begin
  LResult := False;
  try
    TThread.Synchronize(nil, procedure
    var
      LBuffer: IOTAEditBuffer;
    begin
      if not TFacadeShared.TryBuffer(LBuffer) then Exit;
      LBuffer.Undo;
      LResult := True;
    end);
  except
    LResult := False;
  end;
  Result := LResult;
end;

function TMCPWorkspaceOpsService.CloseFile(const AFilePath: string;
  const ASaveFirst: Boolean): Boolean;
var
  LResult: Boolean;
begin
  LResult := False;
  try
    TThread.Synchronize(nil, procedure
    var
      LModule: IOTAModule;
    begin
      if not TFacadeShared.ResolveUnitModule(AFilePath, LModule) then Exit;
      if ASaveFirst and TFacadeShared.IsModuleModified(LModule) then
        if not LModule.Save(False, True) then Exit;
      LResult := LModule.Close;
    end);
  except
    LResult := False;
  end;
  Result := LResult;
end;

// Rename the active project (.dpr/.dpk + .dproj) using IOTAProject100.Rename —
// the same operation as F2 in the Project Manager. Both .dproj and .dpr are
// renamed on disk and the in-memory IOTAProject is updated by the IDE.
function TMCPWorkspaceOpsService.RenameProject(const AOldName,
  ANewName: string; out AOutcome: TRenameOutcome): Boolean;
var
  LDone:    Boolean;
  LReason:  string;
  LOldPath: string;
  LNewPath: string;
begin
  AOutcome.Changed      := False;
  AOutcome.TouchedFiles := [];
  LDone    := False;
  LReason  := 'no-active-project';
  LOldPath := '';
  LNewPath := '';
  try
    TThread.Synchronize(nil, procedure
    var
      LProject: IOTAProject;
      LP100:    IOTAProject100;
      LRoot, LBase, LFull, LConfReason: string;
    begin
      if not TFacadeShared.TryProject(LProject) then
      begin
        LReason := 'no-active-project';
        Exit;
      end;
      LOldPath := LProject.FileName;
      LRoot    := TPath.GetDirectoryName(LOldPath);
      LBase    := TPath.GetFileNameWithoutExtension(ANewName);
      if not TUnitCreatePolicy.IsValidUnitName(LBase) then
      begin
        LReason := 'invalid-name';
        Exit;
      end;
      if not TStructuralWritePolicy.ConfineStructuralTarget(LBase + '.dproj', LRoot, LFull, LConfReason) then
      begin
        LReason := LConfReason;
        Exit;
      end;
      LNewPath := LFull;
      if TFile.Exists(LNewPath) then
      begin
        LReason := 'target-exists';
        Exit;
      end;
      if not Supports(LProject, IOTAProject100, LP100) then
      begin
        LReason := 'ota-no-rename-interface';
        Exit;
      end;
      if LP100.Rename(LOldPath, LNewPath) then
      begin
        LDone   := True;
        LReason := '';
      end
      else
        LReason := 'rename-failed';
    end);
  except
    on E: Exception do
      LReason := E.Message;
  end;
  AOutcome.Reason := LReason;
  if LDone then
  begin
    AOutcome.Changed      := True;
    AOutcome.TouchedFiles := [LOldPath, LNewPath];
  end;
  Result := LDone;
end;

function NewMCPWorkspaceOpsService(const AAudit: IMCPAuditLog;
  const AEditorRead: IMCPEditorReadService): IMCPWorkspaceOpsService;
begin
  Result := TMCPWorkspaceOpsService.Create(AAudit, AEditorRead);
end;

end.
