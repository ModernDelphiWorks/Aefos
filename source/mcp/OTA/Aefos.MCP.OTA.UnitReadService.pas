unit Aefos.MCP.OTA.UnitReadService;

{
  Read-only unit queries, extracted from the TMCPWorkspaceFacade god-object as a
  focused service of the SOLID split (audit S6 / facade split).

  Owns the three pure unit reads — IsUnitOpen, GetUnitFilePath and ReadUnit. The
  only shared dependency is TFacadeShared.FindSourceForPath, now drawn from
  Aefos.MCP.OTA.FacadeShared (tier-4 unit-resolution cluster); the other two read
  IOTAModuleServices.FindModule directly. No mutation, no review-gate, no state.

  Bodies moved VERBATIM from the facade (only the class qualifier changes), so
  behaviour is identical. The facade keeps its frozen IMCPWorkspaceFacade methods
  and delegates each to a refcounted FUnitRead field. The uses-clause read
  (GetUnitUses) stays in the facade for now — its _FindUsesClause/_ParseUsesEntries
  helpers are shared with the AddToUses/RemoveFromUses writers (a later slice).
}

interface

type
  IMCPUnitReadService = interface
    ['{6E9C2A18-4D75-4B30-8F27-3A6C1E5B8D74}']
    function IsUnitOpen(const AUnitName: string): Boolean;
    function GetUnitFilePath(const AUnitName: string): string;
    function ReadUnit(const AUnitPath: string; out ABody: string): Boolean;
  end;

// Factory — the facade calls this once in its constructor.
function NewMCPUnitReadService: IMCPUnitReadService;

implementation

uses
  System.SysUtils,
  System.Classes,
  ToolsAPI,
  Aefos.MCP.OTA.FacadeShared;

type
  TMCPUnitReadService = class(TInterfacedObject, IMCPUnitReadService)
  public
    function IsUnitOpen(const AUnitName: string): Boolean;
    function GetUnitFilePath(const AUnitName: string): string;
    function ReadUnit(const AUnitPath: string; out ABody: string): Boolean;
  end;

function TMCPUnitReadService.IsUnitOpen(const AUnitName: string): Boolean;
var
  LResult: Boolean;
begin
  LResult := False;
  try
    TThread.Synchronize(nil, procedure
    var
      LMS: IOTAModuleServices;
      LModule: IOTAModule;
      LIdx: Integer;
      LEditor: IOTAEditor;
      LSource: IOTASourceEditor;
    begin
      if not Assigned(BorlandIDEServices) then Exit;
      if not Supports(BorlandIDEServices, IOTAModuleServices, LMS) then Exit;
      LModule := LMS.FindModule(AUnitName);
      if not Assigned(LModule) then Exit;
      for LIdx := 0 to LModule.GetModuleFileCount - 1 do
      begin
        LEditor := LModule.GetModuleFileEditor(LIdx);
        if Supports(LEditor, IOTASourceEditor, LSource) then
        begin
          LResult := True;
          Exit;
        end;
      end;
    end);
  except
    LResult := False;
  end;
  Result := LResult;
end;

function TMCPUnitReadService.GetUnitFilePath(
  const AUnitName: string): string;
var
  LResult: string;
begin
  LResult := '';
  try
    TThread.Synchronize(nil, procedure
    var
      LMS: IOTAModuleServices;
      LModule: IOTAModule;
    begin
      if not Assigned(BorlandIDEServices) then Exit;
      if not Supports(BorlandIDEServices, IOTAModuleServices, LMS) then Exit;
      LModule := LMS.FindModule(AUnitName);
      if Assigned(LModule) then
        LResult := LModule.FileName;
    end);
  except
    LResult := '';
  end;
  Result := LResult;
end;

function TMCPUnitReadService.ReadUnit(const AUnitPath: string;
  out ABody: string): Boolean;
var
  LBody: string;
  LOk: Boolean;
begin
  LBody := ''; LOk := False;
  try
    TThread.Synchronize(nil, procedure
    var
      LSource: IOTASourceEditor;
    begin
      LOk := TFacadeShared.FindSourceForPath(AUnitPath, LSource, LBody);
    end);
  except
    LOk := False; LBody := '';
  end;
  ABody := LBody;
  Result := LOk;
end;

function NewMCPUnitReadService: IMCPUnitReadService;
begin
  Result := TMCPUnitReadService.Create;
end;

end.
