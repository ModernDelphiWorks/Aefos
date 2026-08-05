unit Aefos.MCP.Tools.Git;

(*
  Git/VCS MCP tools (ESP-002, Epic 1/3 Demand 1/5).

  Registers 4 read-only subprocess tools:
    GetGitStatus, GetGitCurrentBranch, GetGitLog, GetFileDiff.

  Layering (ADR-115 / ADR-201 §3):
    - Zero uses ToolsAPI. All Git contact flows through IMCPGitFacade.
    - Single public entry RegisterGitTools(AServer, AFacade).

  Error contract (ADR-201 BR-5): every tool returns either the
  success shape or { "error": "<kebab-code>" } — never both.
*)

interface

uses
  Aefos.MCP.Server,
  Aefos.MCP.GitFacade;

procedure RegisterGitTools(const AServer: IMCPServer;
  const AFacade: IMCPGitFacade);

implementation

uses
  System.SysUtils,
  System.JSON,
  Aefos.MCP.Types,
  Aefos.MCP.Tools.Common;

type
  TMCPGitToolsRegistrar = class(TMCPToolsRegistrarBase)
  private
    FFacade: IMCPGitFacade;
    function _ReadIntOptional(const AParams: TJSONObject;
      const AName: string; const ADefault: Integer): Integer;
    function _ReadStringRequired(const AParams: TJSONObject;
      const AName: string): string;
    function _SchemaEmpty: TJSONObject;
    function _SchemaCount: TJSONObject;
    function _SchemaFilePath: TJSONObject;
    function _SchemaStatusItems: TJSONObject;
    function _SchemaBranch: TJSONObject;
    function _SchemaCommits: TJSONObject;
    function _SchemaPatch: TJSONObject;
    function _ResultStatus(
      const AItems: TArray<TGitStatusItem>): TMCPToolResult;
    function _ResultBranch(const ABranch: string;
      const ADetached: Boolean): TMCPToolResult;
    function _ResultCommits(
      const ACommits: TArray<TGitLogEntry>): TMCPToolResult;
    function _ResultPatch(const APatch: string): TMCPToolResult;
    function _ResultError(const ACode: string): TMCPToolResult;
    function _HandleGetGitStatus(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleGetGitCurrentBranch(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleGetGitLog(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function _HandleGetFileDiff(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
  public
    constructor Create(const AFacade: IMCPGitFacade);
    procedure RegisterAll(const AServer: IMCPServer);
  end;

constructor TMCPGitToolsRegistrar.Create(const AFacade: IMCPGitFacade);
begin
  inherited Create;
  if not Assigned(AFacade) then
    raise EArgumentNilException.Create('TMCPGitToolsRegistrar: AFacade');
  FFacade := AFacade;
end;

function TMCPGitToolsRegistrar._ReadIntOptional(const AParams: TJSONObject;
  const AName: string; const ADefault: Integer): Integer;
var
  LValue: TJSONValue;
begin
  Result := ADefault;
  if not Assigned(AParams) then
    Exit;
  LValue := AParams.GetValue(AName);
  if not Assigned(LValue) then
    Exit;
  if LValue is TJSONNumber then
    Result := TJSONNumber(LValue).AsInt
  else
    raise EMCPInvalidParams.Create(AName + ' must be a number');
end;

function TMCPGitToolsRegistrar._ReadStringRequired(const AParams: TJSONObject;
  const AName: string): string;
var
  LValue: TJSONValue;
begin
  if not Assigned(AParams) then
    raise EMCPInvalidParams.Create(AName + ' required');
  LValue := AParams.GetValue(AName);
  if not (Assigned(LValue) and (LValue is TJSONString)) then
    raise EMCPInvalidParams.Create(AName + ' required (string)');
  Result := TJSONString(LValue).Value;
end;

function TMCPGitToolsRegistrar._SchemaEmpty: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  Result.AddPair('properties', TJSONObject.Create);
end;

function TMCPGitToolsRegistrar._SchemaCount: TJSONObject;
var
  LProps, LField: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LField := TJSONObject.Create;
  LField.AddPair('type', 'integer');
  LField.AddPair('minimum', TJSONNumber.Create(1));
  LField.AddPair('maximum', TJSONNumber.Create(200));
  LField.AddPair('default', TJSONNumber.Create(20));
  LProps.AddPair('count', LField);
  Result.AddPair('properties', LProps);
end;

function TMCPGitToolsRegistrar._SchemaFilePath: TJSONObject;
var
  LProps, LField: TJSONObject;
  LReq: TJSONArray;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LField := TJSONObject.Create; LField.AddPair('type', 'string');
  LProps.AddPair('filePath', LField);
  Result.AddPair('properties', LProps);
  LReq := TJSONArray.Create;
  LReq.Add('filePath');
  Result.AddPair('required', LReq);
end;

function TMCPGitToolsRegistrar._SchemaStatusItems: TJSONObject;
var
  LProps, LItems, LItem, LItemProps, LField: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LItems := TJSONObject.Create;
  LItems.AddPair('type', 'array');
  LItem := TJSONObject.Create;
  LItem.AddPair('type', 'object');
  LItemProps := TJSONObject.Create;
  LField := TJSONObject.Create; LField.AddPair('type', 'string');
  LItemProps.AddPair('file', LField);
  LField := TJSONObject.Create; LField.AddPair('type', 'string');
  LItemProps.AddPair('status', LField);
  LItem.AddPair('properties', LItemProps);
  LItems.AddPair('items', LItem);
  LProps.AddPair('items', LItems);
  Result.AddPair('properties', LProps);
end;

function TMCPGitToolsRegistrar._SchemaBranch: TJSONObject;
var
  LProps, LField: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LField := TJSONObject.Create; LField.AddPair('type', 'string');
  LProps.AddPair('branch', LField);
  LField := TJSONObject.Create; LField.AddPair('type', 'boolean');
  LProps.AddPair('detached', LField);
  Result.AddPair('properties', LProps);
end;

function TMCPGitToolsRegistrar._SchemaCommits: TJSONObject;
var
  LProps, LItems, LItem, LItemProps, LField: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LItems := TJSONObject.Create;
  LItems.AddPair('type', 'array');
  LItem := TJSONObject.Create;
  LItem.AddPair('type', 'object');
  LItemProps := TJSONObject.Create;
  LField := TJSONObject.Create; LField.AddPair('type', 'string');
  LItemProps.AddPair('hash', LField);
  LField := TJSONObject.Create; LField.AddPair('type', 'string');
  LItemProps.AddPair('author', LField);
  LField := TJSONObject.Create; LField.AddPair('type', 'string');
  LItemProps.AddPair('date', LField);
  LField := TJSONObject.Create; LField.AddPair('type', 'string');
  LItemProps.AddPair('message', LField);
  LItem.AddPair('properties', LItemProps);
  LItems.AddPair('items', LItem);
  LProps.AddPair('commits', LItems);
  Result.AddPair('properties', LProps);
end;

function TMCPGitToolsRegistrar._SchemaPatch: TJSONObject;
var
  LProps, LField: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LField := TJSONObject.Create; LField.AddPair('type', 'string');
  LProps.AddPair('patch', LField);
  Result.AddPair('properties', LProps);
end;

function TMCPGitToolsRegistrar._ResultStatus(
  const AItems: TArray<TGitStatusItem>): TMCPToolResult;
var
  LObj, LItem: TJSONObject;
  LArr: TJSONArray;
  LFor: Integer;
begin
  LObj := TJSONObject.Create;
  try
    LArr := TJSONArray.Create;
    for LFor := 0 to High(AItems) do
    begin
      LItem := TJSONObject.Create;
      LItem.AddPair('file', AItems[LFor].FileName);
      LItem.AddPair('status', AItems[LFor].Status);
      LArr.AddElement(LItem);
    end;
    LObj.AddPair('items', LArr);
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function TMCPGitToolsRegistrar._ResultBranch(const ABranch: string;
  const ADetached: Boolean): TMCPToolResult;
var
  LObj: TJSONObject;
begin
  LObj := TJSONObject.Create;
  try
    LObj.AddPair('branch', ABranch);
    if ADetached then
      LObj.AddPair('detached', TJSONBool.Create(True));
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function TMCPGitToolsRegistrar._ResultCommits(
  const ACommits: TArray<TGitLogEntry>): TMCPToolResult;
var
  LObj, LItem: TJSONObject;
  LArr: TJSONArray;
  LFor: Integer;
begin
  LObj := TJSONObject.Create;
  try
    LArr := TJSONArray.Create;
    for LFor := 0 to High(ACommits) do
    begin
      LItem := TJSONObject.Create;
      LItem.AddPair('hash', ACommits[LFor].Hash);
      LItem.AddPair('author', ACommits[LFor].Author);
      LItem.AddPair('date', ACommits[LFor].Date);
      LItem.AddPair('message', ACommits[LFor].Message);
      LArr.AddElement(LItem);
    end;
    LObj.AddPair('commits', LArr);
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function TMCPGitToolsRegistrar._ResultPatch(
  const APatch: string): TMCPToolResult;
var
  LObj: TJSONObject;
begin
  LObj := TJSONObject.Create;
  try
    LObj.AddPair('patch', APatch);
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function TMCPGitToolsRegistrar._ResultError(
  const ACode: string): TMCPToolResult;
var
  LObj: TJSONObject;
begin
  LObj := TJSONObject.Create;
  try
    LObj.AddPair('error', ACode);
    Result := TMCPToolResult.Text(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function TMCPGitToolsRegistrar._HandleGetGitStatus(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LItems: TArray<TGitStatusItem>;
  LError: string;
begin
  if AContext = nil then ;
  if FFacade.GetStatus(LItems, LError) then
    Result := _ResultStatus(LItems)
  else
    Result := _ResultError(LError);
end;

function TMCPGitToolsRegistrar._HandleGetGitCurrentBranch(
  const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LBranch: string;
  LDetached: Boolean;
  LError: string;
begin
  if AContext = nil then ;
  if FFacade.GetCurrentBranch(LBranch, LDetached, LError) then
    Result := _ResultBranch(LBranch, LDetached)
  else
    Result := _ResultError(LError);
end;

function TMCPGitToolsRegistrar._HandleGetGitLog(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LCount: Integer;
  LCommits: TArray<TGitLogEntry>;
  LError: string;
begin
  if AContext = nil then ;
  LCount := _ReadIntOptional(AParams, 'count', 20);
  if FFacade.GetLog(LCount, LCommits, LError) then
    Result := _ResultCommits(LCommits)
  else
    Result := _ResultError(LError);
end;

function TMCPGitToolsRegistrar._HandleGetFileDiff(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LFilePath: string;
  LPatch: string;
  LError: string;
begin
  if AContext = nil then ;
  LFilePath := _ReadStringRequired(AParams, 'filePath');
  if FFacade.GetFileDiff(LFilePath, LPatch, LError) then
    Result := _ResultPatch(LPatch)
  else
    Result := _ResultError(LError);
end;

procedure TMCPGitToolsRegistrar.RegisterAll(const AServer: IMCPServer);
var
  LSelf: TMCPGitToolsRegistrar;
  LLifetime: IInterface;
begin
  if not Assigned(AServer) then
    raise EArgumentNilException.Create(
      'TMCPGitToolsRegistrar.RegisterAll: AServer');
  LSelf := Self;
  LLifetime := Self;
  AServer.RegisterTool(_BuildDescriptor('GetGitStatus',
    'Get git status',
    'Returns the status of the repository files (porcelain v1).',
    _SchemaEmpty, _SchemaStatusItems,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      if LLifetime = nil then ;
      Result := LSelf._HandleGetGitStatus(AParams, AContext);
    end));
  AServer.RegisterTool(_BuildDescriptor('GetGitCurrentBranch',
    'Get current branch',
    'Returns the active branch (or hash when HEAD is detached).',
    _SchemaEmpty, _SchemaBranch,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      if LLifetime = nil then ;
      Result := LSelf._HandleGetGitCurrentBranch(AParams, AContext);
    end));
  AServer.RegisterTool(_BuildDescriptor('GetGitLog',
    'Get git log',
    'Returns the last N commits (default 20, clamped 1..200).',
    _SchemaCount, _SchemaCommits,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      if LLifetime = nil then ;
      Result := LSelf._HandleGetGitLog(AParams, AContext);
    end));
  AServer.RegisterTool(_BuildDescriptor('GetFileDiff',
    'Get file diff',
    'Returns the git diff patch of a repository file.',
    _SchemaFilePath, _SchemaPatch,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      if LLifetime = nil then ;
      Result := LSelf._HandleGetFileDiff(AParams, AContext);
    end));
end;

procedure RegisterGitTools(const AServer: IMCPServer;
  const AFacade: IMCPGitFacade);
var
  LRegistrar: TMCPGitToolsRegistrar;
  LIntf: IInterface;
begin
  LRegistrar := TMCPGitToolsRegistrar.Create(AFacade);
  LIntf := LRegistrar;
  if LIntf = nil then ;
  LRegistrar.RegisterAll(AServer);
end;

end.
