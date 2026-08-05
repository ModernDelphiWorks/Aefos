unit Aefos.MCP.OTA.EditorReadService;

{
  Read-only editor-state queries, extracted from the TMCPWorkspaceFacade
  god-object as a focused service of the SOLID split (audit S6 / facade split).

  Owns the six pure editor reads — active unit text, cursor position, selection,
  the RULE #1 view intent, the active editor file, and the open-editor file list.
  All shared work comes from already-separate units: TryBuffer / ReadBytes /
  FirstSourceEditor from Aefos.MCP.OTA.FacadeShared (tier-3 editor cluster) and
  CurrentLiveView from the harness. No mutation, no review-gate, no facade state.

  Bodies moved VERBATIM from the facade (only the class qualifier changes), so
  behaviour is identical. The facade keeps its frozen IMCPWorkspaceFacade methods
  and delegates each to a refcounted FEditorRead field.
}

interface

uses
  Aefos.MCP.Types,
  Aefos.MCP.IntentGuard;

type
  IMCPEditorReadService = interface
    ['{3A7C1E94-6D85-4B20-9F38-2C6A1B5E8D74}']
    function GetActiveUnit: string;
    function GetCursorPosition: TMCPCursorInfo;
    function GetSelection: TMCPSelectionInfo;
    function CurrentIdeViewIntent: TMCPToolIntent;
    function GetEditorActiveFile(out AName, APath: string): Boolean;
    function GetOpenEditorFiles(out AFiles: TArray<TMCPRecordEditorFile>): Boolean;
  end;

// Factory — the facade calls this once in its constructor.
function NewMCPEditorReadService: IMCPEditorReadService;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.Generics.Collections,
  ToolsAPI,
  Aefos.Harness.View,
  Aefos.MCP.OTA.FacadeShared;

type
  TMCPEditorReadService = class(TInterfacedObject, IMCPEditorReadService)
  public
    function GetActiveUnit: string;
    function GetCursorPosition: TMCPCursorInfo;
    function GetSelection: TMCPSelectionInfo;
    function CurrentIdeViewIntent: TMCPToolIntent;
    function GetEditorActiveFile(out AName, APath: string): Boolean;
    function GetOpenEditorFiles(out AFiles: TArray<TMCPRecordEditorFile>): Boolean;
  end;

function TMCPEditorReadService.GetActiveUnit: string;
var
  LResult: string;
begin
  LResult := '';
  try
    TThread.Synchronize(nil, procedure
    var
      LBuffer: IOTAEditBuffer;
      LReader: IOTAEditReader;
    begin
      if not TFacadeShared.TryBuffer(LBuffer) then Exit;
      LReader := LBuffer.CreateReader;
      LResult := TFacadeShared.ReadBytes(LReader);
    end);
  except
    LResult := '';
  end;
  Result := LResult;
end;

function TMCPEditorReadService.GetCursorPosition: TMCPCursorInfo;
var
  LResult: TMCPCursorInfo;
begin
  LResult := Default(TMCPCursorInfo);
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
      LPos := LView.CursorPos;
      LResult.UnitPath  := LView.Buffer.FileName;
      LResult.Line      := LPos.Line;
      LResult.Column    := LPos.Col;
      LResult.Available := True;
    end);
  except
    LResult := Default(TMCPCursorInfo);
  end;
  Result := LResult;
end;

function TMCPEditorReadService.GetSelection: TMCPSelectionInfo;
var
  LResult: TMCPSelectionInfo;
begin
  LResult := Default(TMCPSelectionInfo);
  try
    TThread.Synchronize(nil, procedure
    var
      LES: IOTAEditorServices;
      LView: IOTAEditView;
      LBlock: IOTAEditBlock;
    begin
      if not Assigned(BorlandIDEServices) then Exit;
      if not Supports(BorlandIDEServices, IOTAEditorServices, LES) then Exit;
      LView := LES.TopView;
      if not Assigned(LView) then Exit;
      LBlock := LView.Block;
      if not Assigned(LBlock) or not LBlock.IsValid then Exit;
      LResult.UnitPath    := LView.Buffer.FileName;
      LResult.Text        := LBlock.Text;
      LResult.StartLine   := LBlock.StartingRow;
      LResult.StartColumn := LBlock.StartingColumn;
      LResult.EndLine     := LBlock.EndingRow;
      LResult.EndColumn   := LBlock.EndingColumn;
      LResult.Available   := True;
    end);
  except
    LResult := Default(TMCPSelectionInfo);
  end;
  Result := LResult;
end;

function TMCPEditorReadService.CurrentIdeViewIntent: TMCPToolIntent;
begin
  // Thin MCP adapter (RULE #1): the actual Design/Code read lives in the HARNESS
  // (CurrentLiveView), the SAME seam as EnsureDesignView/EnsureCodeView — not
  // duplicated here. This only maps the harness view-state to the MCP intent
  // enum, keeping the harness MCP-agnostic. Main-thread read (server marshals).
  case THarnessView.CurrentLiveView of
    lvDesign: Result := tiDesign;
    lvCode:   Result := tiCode;
  else
    Result := tiNeutral;
  end;
end;

function TMCPEditorReadService.GetEditorActiveFile(out AName,
  APath: string): Boolean;
var
  LName, LPath: string;
  LOk: Boolean;
begin
  LName := ''; LPath := ''; LOk := False;
  try
    TThread.Synchronize(nil, procedure
    var
      LBuffer: IOTAEditBuffer;
    begin
      if TFacadeShared.TryBuffer(LBuffer) then
      begin
        LPath := LBuffer.FileName;
        LName := TPath.GetFileName(LPath);
        LOk   := True;
      end;
    end);
  except
    LOk := False;
  end;
  AName := LName;
  APath := LPath;
  Result := LOk;
end;

function TMCPEditorReadService.GetOpenEditorFiles(
  out AFiles: TArray<TMCPRecordEditorFile>): Boolean;
var
  LFiles: TArray<TMCPRecordEditorFile>;
  LOk: Boolean;
begin
  LFiles := [];
  LOk := False;
  try
    TThread.Synchronize(nil, procedure
    var
      LMS: IOTAModuleServices;
      LList: TList<TMCPRecordEditorFile>;
      LModule: IOTAModule;
      LIdx: Integer;
      LFile: TMCPRecordEditorFile;
    begin
      if not Assigned(BorlandIDEServices) then Exit;
      if not Supports(BorlandIDEServices, IOTAModuleServices, LMS) then Exit;
      LList := TList<TMCPRecordEditorFile>.Create;
      try
        for LIdx := 0 to LMS.ModuleCount - 1 do
        begin
          LModule := LMS.Modules[LIdx];
          if not Assigned(TFacadeShared.FirstSourceEditor(LModule)) then Continue;
          LFile      := Default(TMCPRecordEditorFile);
          LFile.Path := LModule.FileName;
          LFile.Name := TPath.GetFileName(LFile.Path);
          LList.Add(LFile);
        end;
        LFiles := LList.ToArray;
        LOk := True;
      finally
        LList.Free;
      end;
    end);
  except
    LOk := False;
  end;
  AFiles := LFiles;
  Result := LOk;
end;

function NewMCPEditorReadService: IMCPEditorReadService;
begin
  Result := TMCPEditorReadService.Create;
end;

end.
