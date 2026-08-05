unit Aefos.MCP.OTA.IDEService;

{
  IDE-level MCP operations, extracted from the TMCPWorkspaceFacade god-object as
  the first focused service of the SOLID decomposition (audit S6 / facade split).

  Owns the four host-neutral IDE actions — ShowIDEMessage, ListIDEActions,
  ExecuteIDEAction, RefreshProjectManager — plus their two private helpers. This
  domain is fully self-contained: it touches BorlandIDEServices / INTAServices /
  IOTAMessageServices directly and the pure FormUsesWritePolicy.ClassifyIDEAction
  gate; it holds NO facade state and uses NONE of the shared OTA helpers. The
  facade keeps the frozen IMCPWorkspaceFacade methods and simply delegates here.

  The bodies are moved VERBATIM from the facade (only the class qualifier changes),
  so behaviour is identical.
}

interface

type
  // The IDE-domain surface the facade delegates to. Refcounted, so the facade
  // holds it as an interface field and lifetime is automatic (no destructor).
  IMCPIDEService = interface
    ['{6B1F4C2A-9D70-4E55-8A13-2C7E1B6D9F40}']
    function ShowIDEMessage(const AText: string;
      const AUseOutput: Boolean): Boolean;
    function ListIDEActions(const AFilter: string): string;
    function ExecuteIDEAction(const AActionName: string;
      out AReason: string): Boolean;
    function RefreshProjectManager: Boolean;
  end;

// Factory — the facade calls this once in its constructor.
function NewMCPIDEService: IMCPIDEService;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.JSON,
  System.Actions,
  Vcl.ActnList,
  Vcl.Menus,
  Vcl.Forms,
  ToolsAPI,
  Aefos.MCP.OTA.FormUsesWritePolicy;

type
  TMCPIDEService = class(TInterfacedObject, IMCPIDEService)
  public
    function ShowIDEMessage(const AText: string;
      const AUseOutput: Boolean): Boolean;
    function ListIDEActions(const AFilter: string): string;
    function ExecuteIDEAction(const AActionName: string;
      out AReason: string): Boolean;
    function RefreshProjectManager: Boolean;
  end;

// Searches LNTA.ActionList for an action whose name matches AActionName
// (case-insensitive) and executes it. Returns True and clears AReason on success;
// returns False with a kebab AReason when the list is unavailable or the name is
// not found. Extracted from the ExecuteIDEAction TThread.Synchronize closure to
// bring Cognitive Complexity below 15 (ESP-090 verify-fix). The caller has
// already passed ClassifyIDEAction.
function _FindAndExecuteIDEAction(const LNTA: INTAServices;
  const AActionName: string; out AReason: string): Boolean;
var
  LList: TCustomActionList;
  LFor: Integer;
  LAction: TContainedAction;
begin
  Result  := False;
  AReason := 'action-not-found';
  LList   := LNTA.ActionList;
  if not Assigned(LList) then
  begin
    AReason := 'no-action-list';
    Exit;
  end;
  for LFor := 0 to LList.ActionCount - 1 do
  begin
    LAction := LList[LFor];
    if Assigned(LAction) and SameText(LAction.Name, Trim(AActionName)) then
    begin
      LAction.Execute;
      AReason := '';
      Exit(True);
    end;
  end;
end;

// Appends "Name|Caption" for every action in AAL to ALog. Unit-level (not a
// nested proc) so it can be referenced from the Synchronize closure below.
procedure _DumpActionList(const ALog: TStringList; const AAL: TCustomActionList);
var
  I: Integer;
  A: TContainedAction;
begin
  if not Assigned(AAL) then Exit;
  for I := 0 to AAL.ActionCount - 1 do
  begin
    A := AAL.Actions[I];
    if Assigned(A) then
      ALog.Add(A.Name + '|' + A.Caption);
  end;
end;

function TMCPIDEService.ShowIDEMessage(const AText: string;
  const AUseOutput: Boolean): Boolean;
var
  LResult: Boolean;
begin
  // R1: never raise a modal that blocks the IDE main thread and stalls the MCP
  // pipe. The IDE Messages window (IOTAMessageServices.AddTitleMessage) is the
  // non-blocking notice channel, so both the output-pane and notice variants
  // route there; AUseOutput is accepted for Core schema parity but the message
  // always lands in the Messages window (a non-blocking IDE notification).
  LResult := False;
  try
    TThread.Synchronize(nil, procedure
    var
      LMsg: IOTAMessageServices;
    begin
      if not Assigned(BorlandIDEServices) then Exit;
      if not Supports(BorlandIDEServices, IOTAMessageServices, LMsg) then Exit;
      LMsg.AddTitleMessage(AText);
      LResult := True;
    end);
  except
    LResult := False;
  end;
  Result := LResult;
end;

function TMCPIDEService.ListIDEActions(const AFilter: string): string;
var
  LNTA: INTAServices;
  LList: TCustomActionList;
  LRoot: TJSONObject;
  LArr: TJSONArray;
  LObj: TJSONObject;
  LFor: Integer;
  A: TContainedAction;
  LFilter, LName, LCaption, LCategory, LHint, LShortcut: string;
  LEnabled: Boolean;
begin
  // Read-only enumeration of the LIVE INTAServices.ActionList — the full IDE
  // action catalog. The point: any agent can DISCOVER the action name to pass to
  // ExecuteIDEAction (e.g. ViewToggleFormCommand = F12 to flip Form<->code so the
  // designer re-renders the components) instead of guessing or stumbling onto it.
  // Runs on the main thread (the Core handler marshals via MarshalToMainThread).
  // AFilter: case-insensitive substring matched against name/caption/category;
  // '' returns the whole catalog.
  LFilter := LowerCase(Trim(AFilter));
  LRoot := TJSONObject.Create;
  try
    LArr := TJSONArray.Create;
    if Supports(BorlandIDEServices, INTAServices, LNTA) then
    begin
      LList := LNTA.ActionList;
      if Assigned(LList) then
        for LFor := 0 to LList.ActionCount - 1 do
        begin
          A := LList.Actions[LFor];
          if not Assigned(A) then
            Continue;
          LName := A.Name;
          LCaption := A.Caption;
          LCategory := '';
          LHint := '';
          LShortcut := '';
          LEnabled := True;
          // Caption/Name live on TContainedAction; the richer fields are on
          // TCustomAction (TAction). Cast-guard keeps it safe for any item type.
          if A is TCustomAction then
          begin
            LCategory := TCustomAction(A).Category;
            LHint := TCustomAction(A).Hint;
            LShortcut := ShortCutToText(TCustomAction(A).ShortCut);
            LEnabled := TCustomAction(A).Enabled;
          end;
          if (LFilter <> '')
            and (Pos(LFilter, LowerCase(LName)) = 0)
            and (Pos(LFilter, LowerCase(LCaption)) = 0)
            and (Pos(LFilter, LowerCase(LCategory)) = 0) then
            Continue;
          LObj := TJSONObject.Create;
          LObj.AddPair('name', LName);
          LObj.AddPair('caption', LCaption);
          LObj.AddPair('category', LCategory);
          LObj.AddPair('shortcut', LShortcut);
          LObj.AddPair('hint', LHint);
          LObj.AddPair('enabled', TJSONBool.Create(LEnabled));
          LArr.AddElement(LObj);
        end;
    end;
    LRoot.AddPair('actions', LArr);
    LRoot.AddPair('count', TJSONNumber.Create(LArr.Count));
    Result := LRoot.ToJSON;
  finally
    LRoot.Free;
  end;
end;

// Invoke a named IDE action (ESP-090). The pure FormUsesWritePolicy
// .ClassifyIDEAction gates the name to the safe, non-destructive allow-list
// BEFORE any lookup (BR11 / ADR-090-07): an empty, destructive, or
// off-allow-list name is refused with a kebab reason and no side effect. A safe
// name is looked up in INTAServices.ActionList and Executed on the main thread;
// an allow-listed name absent from the live action list returns `action-not
// -found` (no change). There is no dedicated read accessor for an IDE action, so
// the effect is observed only via the chosen action's side-effect (CAVEAT,
// ADR-090-03).
function TMCPIDEService.ExecuteIDEAction(const AActionName: string;
  out AReason: string): Boolean;
var
  LResult: Boolean;
  LReason: string;
begin
  LResult := False;

  // ── Debug: ExecuteIDEAction("?") dumps every IDE action to a file and
  //    surfaces line-count + path via the error channel (handler discards
  //    AReason on success). Read the file to find e.g. the "View as Text" name.
  if Trim(AActionName) = '?' then
  begin
    try
      TThread.Synchronize(nil, procedure
      var
        LNTA: INTAServices;
        LFrm, LComp: Integer;
        LForm: TForm;
        LLog: TStringList;
        LLogPath: string;
      begin
        LLog := TStringList.Create;
        try
          LLogPath := TPath.Combine(TPath.GetTempPath, 'ds_ide_actions.txt');
          if Assigned(BorlandIDEServices)
            and Supports(BorlandIDEServices, INTAServices, LNTA) then
          begin
            LLog.Add('## INTAServices.ActionList');
            _DumpActionList(LLog, LNTA.ActionList);
          end;
          for LFrm := 0 to Screen.FormCount - 1 do
          begin
            try
              LForm := Screen.Forms[LFrm];
              if not Assigned(LForm) then Continue;
              for LComp := 0 to LForm.ComponentCount - 1 do
                if LForm.Components[LComp] is TCustomActionList then
                begin
                  LLog.Add('## ' + LForm.Name + ' (' + LForm.ClassName + ') / ' +
                    LForm.Components[LComp].Name);
                  _DumpActionList(LLog, TCustomActionList(LForm.Components[LComp]));
                end;
            except
              on E: Exception do
                LLog.Add('!! form[' + IntToStr(LFrm) + ']: ' + E.Message);
            end;
          end;
          LLog.SaveToFile(LLogPath);
          LReason := 'DUMP ' + IntToStr(LLog.Count) + ' lines -> ' + LLogPath;
        finally
          LLog.Free;
        end;
      end);
    except
      on E: Exception do
        LReason := 'DUMP-FAILED: ' + E.ClassName + ': ' + E.Message;
    end;
    AReason := LReason;
    Exit(False);
  end;

  if not TFormUsesWritePolicy.ClassifyIDEAction(AActionName, LReason) then
  begin
    AReason := LReason;
    Exit(False);
  end;
  LReason := 'action-not-found';
  try
    TThread.Synchronize(nil, procedure
    var
      LNTA: INTAServices;
    begin
      if not Assigned(BorlandIDEServices) then
      begin
        LReason := 'no-ide-services';
        Exit;
      end;
      if not Supports(BorlandIDEServices, INTAServices, LNTA) then
      begin
        LReason := 'no-nta-services';
        Exit;
      end;
      LResult := _FindAndExecuteIDEAction(LNTA, AActionName, LReason);
    end);
  except
    on E: Exception do
    begin
      LResult := False;
      LReason := E.Message;
    end;
  end;
  if LResult then AReason := '' else AReason := LReason;
  Result := LResult;
end;

function TMCPIDEService.RefreshProjectManager: Boolean;
begin
  Result := True;
end;

function NewMCPIDEService: IMCPIDEService;
begin
  Result := TMCPIDEService.Create;
end;

end.
