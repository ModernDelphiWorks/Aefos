unit Aefos.Agent.MCP.Core;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

(*
  Aefos Agent CLI - MCP client core (pure, RTL-only, headless-testable).

  Speaks the aefos MCP wire contract the PowerShell bridge documents: LF-
  delimited JSON-RPC 2.0 frames, protocolVersion '2025-06-18' (the server
  accepts exactly that one). Frame building/parsing and the MCP -> Ollama
  tool-catalog translation are pure functions; the client state machine takes
  an injected line transport, so the pure suite scripts entire conversations
  without a pipe. The Windows named-pipe transport lives in
  Aefos.Agent.MCP.Pipe.
*)

interface

uses
  {$IFDEF FPC}
  SysUtils,
  Aefos.Compat.Json;
  {$ELSE}
  System.SysUtils,
  System.JSON;
  {$ENDIF}

const
  CMcpProtocolVersion = '2025-06-18';
  CMcpClientName = 'aefos-agent';

type
  // One line out / one line in. Implemented by the named pipe (production)
  // and by scripted fakes (suite). ReadLine BLOCKS until a full line arrives
  // or the pipe closes (False). NOTE: the production pipe transport has no
  // read deadline yet - a tools/call that parks the IDE main thread (e.g. a
  // modal consent) hangs this read; the IDE-side Run timeout is the current
  // backstop. Overlapped-read deadline is a tracked follow-up (review F2).
  IAgentFrameTransport = interface
    ['{B4D7A2E1-6C3F-4A98-8D51-2F7E90C4B6A3}']
    function SendLine(const ALine: string): Boolean;
    function ReadLine(out ALine: string): Boolean;
  end;

  TMcpToolDef = record
    Name: string;
    Description: string;
    InputSchemaJson: string; // the tool's JSON-Schema object, verbatim
  end;

  // Static, sealed namespace for the pure MCP wire contract: frame builders,
  // frame parsers and the MCP -> Ollama catalog translation. Never instantiated;
  // the class IS the namespace, so the old 'Mcp' name prefix is gone. The
  // stateful client (TAgentMcpClient, below) drives these.
  TMcpWire = class sealed
  public
    // ---- frame builders (pure) ---------------------------------------------
    class function InitializeFrame(const AId: Integer): string; static;
    class function InitializedNotification: string; static;
    class function ToolsListFrame(const AId: Integer): string; static;
    class function ToolsCallFrame(const AId: Integer;
      const AName, AArgumentsJson: string): string; static;

    // ---- frame parsers (pure) ----------------------------------------------
    // True when ALine is the response to AExpectedId: AResultJson carries the
    // "result" object verbatim (or '' with AError set on a JSON-RPC error).
    class function ParseResponse(const ALine: string; const AExpectedId: Integer;
      out AResultJson: string; out AError: string): Boolean; static;
    // tools/list result -> defs. Malformed input yields an empty array.
    class function ParseToolsList(const AResultJson: string): TArray<TMcpToolDef>; static;
    // tools/call result -> concatenated text content + isError flag.
    class function ParseToolCallResult(const AResultJson: string; out AText: string;
      out AIsError: Boolean): Boolean; static;

    // True when ALine is a server-initiated NOTIFICATION (a JSON-RPC object with
    // a "method" and NO "id"). The aefos server broadcasts these (e.g.
    // notifications/resources/updated) to EVERY connected client, so one can land
    // on this client's pipe between a request and its response; the client must
    // SKIP them rather than mistake one for the response (review S3).
    class function IsNotificationFrame(const ALine: string): Boolean; static;

    // ---- catalog translation (pure) ----------------------------------------
    // MCP defs -> the Ollama /api/chat "tools" array (OpenAI-function shape):
    // [{"type":"function","function":{"name","description","parameters":schema}}]
    class function OllamaToolsJson(const ATools: TArray<TMcpToolDef>): string; static;
  end;

type
  // Minimal synchronous MCP client: initialize -> initialized -> list/call.
  // Sequential ids; one in-flight request at a time (the aefos server answers
  // in order on the same pipe instance, mirroring the bridge's readline flow).
  TAgentMcpClient = class
  private
    FTransport: IAgentFrameTransport;
    FNextId: Integer;
    FServerName: string;
    function _Request(const AFrame: string; const AId: Integer;
      out AResultJson: string; out AError: string): Boolean;
  public
    constructor Create(const ATransport: IAgentFrameTransport);
    // Handshake. False + AError when the server is unreachable/incompatible.
    function Initialize(out AError: string): Boolean;
    function ListTools(out ATools: TArray<TMcpToolDef>;
      out AError: string): Boolean;
    // Executes one tool. ATextOut is the tool's text content even when the
    // tool reports failure (AIsError True) - the model needs failure text too.
    function CallTool(const AName, AArgumentsJson: string; out ATextOut: string;
      out AIsError: Boolean; out AError: string): Boolean;
    property ServerName: string read FServerName;
  end;

implementation

class function TMcpWire.InitializeFrame(const AId: Integer): string;
var
  LRoot, LParams, LInfo: TJSONObject;
begin
  LRoot := TJSONObject.Create;
  try
    LRoot.AddPair('jsonrpc', '2.0');
    LRoot.AddPair('id', TJSONNumber.Create(AId));
    LRoot.AddPair('method', 'initialize');
    LParams := TJSONObject.Create;
    LRoot.AddPair('params', LParams);
    LParams.AddPair('protocolVersion', CMcpProtocolVersion);
    LParams.AddPair('capabilities', TJSONObject.Create);
    LInfo := TJSONObject.Create;
    LParams.AddPair('clientInfo', LInfo);
    LInfo.AddPair('name', CMcpClientName);
    LInfo.AddPair('version', '0.1.0');
    Result := LRoot.ToJSON;
  finally
    LRoot.Free;
  end;
end;

class function TMcpWire.InitializedNotification: string;
begin
  Result := '{"jsonrpc":"2.0","method":"notifications/initialized"}';
end;

class function TMcpWire.ToolsListFrame(const AId: Integer): string;
begin
  Result := Format(
    '{"jsonrpc":"2.0","id":%d,"method":"tools/list","params":{}}', [AId]);
end;

class function TMcpWire.ToolsCallFrame(const AId: Integer;
  const AName, AArgumentsJson: string): string;
var
  LRoot, LParams: TJSONObject;
  LArgs: TJSONValue;
begin
  LRoot := TJSONObject.Create;
  try
    LRoot.AddPair('jsonrpc', '2.0');
    LRoot.AddPair('id', TJSONNumber.Create(AId));
    LRoot.AddPair('method', 'tools/call');
    LParams := TJSONObject.Create;
    LRoot.AddPair('params', LParams);
    LParams.AddPair('name', AName);
    // The model hands us the arguments as a JSON OBJECT (Ollama tool_calls
    // carry objects, not strings); pass it through verbatim when parseable,
    // else send an empty object rather than a broken frame.
    LArgs := TJSONObject.ParseJSONValue(AArgumentsJson);
    if not (LArgs is TJSONObject) then
    begin
      LArgs.Free;
      LArgs := TJSONObject.Create;
    end;
    LParams.AddPair('arguments', LArgs);
    Result := LRoot.ToJSON;
  finally
    LRoot.Free;
  end;
end;

class function TMcpWire.ParseResponse(const ALine: string;
  const AExpectedId: Integer;
  out AResultJson: string; out AError: string): Boolean;
var
  LRoot: TJSONValue;
  LObj, LErr: TJSONObject;
  LId: Integer;
  LResult: TJSONValue;
  LMsg: string;
begin
  Result := False;
  AResultJson := '';
  AError := '';
  LRoot := TJSONObject.ParseJSONValue(ALine);
  try
    if not (LRoot is TJSONObject) then
    begin
      AError := 'Malformed MCP frame (not a JSON object).';
      Exit;
    end;
    LObj := TJSONObject(LRoot);
    // Parenthesise generic calls adjacent to not/and/or (FPC generic-call parse).
    if not (LObj.TryGetValue<Integer>('id', LId)) then
    begin
      AError := 'MCP frame without an id (notification?) where a response ' +
        'was expected.';
      Exit;
    end;
    if LId <> AExpectedId then
    begin
      AError := Format('MCP response id mismatch (got %d, expected %d).',
        [LId, AExpectedId]);
      Exit;
    end;
    LErr := nil;
    if (LObj.TryGetValue<TJSONObject>('error', LErr)) and (LErr <> nil) then
    begin
      if not (LErr.TryGetValue<string>('message', LMsg)) then
        LMsg := '';
      if LMsg = '' then
        LMsg := LErr.ToJSON;
      AError := LMsg;
      Result := True; // a well-formed error IS a response
      Exit;
    end;
    LResult := LObj.GetValue('result');
    if LResult = nil then
    begin
      AError := 'MCP response carries neither result nor error.';
      Exit;
    end;
    AResultJson := LResult.ToJSON;
    Result := True;
  finally
    LRoot.Free;
  end;
end;

class function TMcpWire.IsNotificationFrame(const ALine: string): Boolean;
var
  LRoot: TJSONValue;
  LObj: TJSONObject;
  LMethod: string;
begin
  Result := False;
  LRoot := TJSONObject.ParseJSONValue(ALine);
  try
    if not (LRoot is TJSONObject) then
      Exit;
    LObj := TJSONObject(LRoot);
    // A notification has a method and no id. (A response has an id and no
    // method; a request — which the server never sends us — has both.)
    Result := (LObj.GetValue('id') = nil) and
      (LObj.TryGetValue<string>('method', LMethod));
  finally
    LRoot.Free;
  end;
end;

class function TMcpWire.ParseToolsList(
  const AResultJson: string): TArray<TMcpToolDef>;
var
  LRoot: TJSONValue;
  LArr: TJSONArray;
  LItem: TJSONValue;
  LObj: TJSONObject;
  LSchema: TJSONValue;
  LCount: Integer;
begin
  Result := nil;
  LRoot := TJSONObject.ParseJSONValue(AResultJson);
  try
    if not (LRoot is TJSONObject) then
      Exit;
    LArr := nil;
    if not (TJSONObject(LRoot).TryGetValue<TJSONArray>('tools', LArr)) then
      Exit;
    if LArr = nil then
      Exit;
    LCount := 0;
    SetLength(Result, LArr.Count);
    for LItem in LArr do
    begin
      if not (LItem is TJSONObject) then
        Continue;
      LObj := TJSONObject(LItem);
      if not (LObj.TryGetValue<string>('name', Result[LCount].Name)) then
        Continue;
      if not (LObj.TryGetValue<string>('description',
        Result[LCount].Description)) then
        Result[LCount].Description := '';
      LSchema := LObj.GetValue('inputSchema');
      if LSchema <> nil then
        Result[LCount].InputSchemaJson := LSchema.ToJSON
      else
        Result[LCount].InputSchemaJson := '{"type":"object"}';
      Inc(LCount);
    end;
    SetLength(Result, LCount);
  finally
    LRoot.Free;
  end;
end;

class function TMcpWire.ParseToolCallResult(const AResultJson: string;
  out AText: string; out AIsError: Boolean): Boolean;
var
  LRoot: TJSONValue;
  LArr: TJSONArray;
  LItem: TJSONValue;
  LObj: TJSONObject;
  LType, LText: string;
begin
  Result := False;
  AText := '';
  AIsError := False;
  LRoot := TJSONObject.ParseJSONValue(AResultJson);
  try
    if not (LRoot is TJSONObject) then
      Exit;
    TJSONObject(LRoot).TryGetValue<Boolean>('isError', AIsError);
    LArr := nil;
    if (TJSONObject(LRoot).TryGetValue<TJSONArray>('content', LArr)) and
      (LArr <> nil) then
      for LItem in LArr do
      begin
        if not (LItem is TJSONObject) then
          Continue;
        LObj := TJSONObject(LItem);
        if (LObj.TryGetValue<string>('type', LType)) and (LType = 'text') and
          (LObj.TryGetValue<string>('text', LText)) then
        begin
          if AText <> '' then
            AText := AText + sLineBreak;
          AText := AText + LText;
        end;
      end;
    Result := True;
  finally
    LRoot.Free;
  end;
end;

class function TMcpWire.OllamaToolsJson(
  const ATools: TArray<TMcpToolDef>): string;
var
  LArr: TJSONArray;
  LTool, LFn: TJSONObject;
  LSchema: TJSONValue;
  LIndex: Integer;
begin
  LArr := TJSONArray.Create;
  try
    for LIndex := 0 to High(ATools) do
    begin
      LTool := TJSONObject.Create;
      LArr.AddElement(LTool);
      LTool.AddPair('type', 'function');
      LFn := TJSONObject.Create;
      LTool.AddPair('function', LFn);
      LFn.AddPair('name', ATools[LIndex].Name);
      LFn.AddPair('description', ATools[LIndex].Description);
      // parameters MUST be a JSON object: Ollama's Go API unmarshals it into a
      // struct, so a parseable-but-non-object schema (a boolean JSON-Schema, a
      // string, an array) would make the server 400 the ENTIRE /api/chat
      // request and kill every agent turn. Coerce anything non-object to an
      // empty object schema (review F1/inputSchema, 2026-07-09).
      LSchema := TJSONObject.ParseJSONValue(ATools[LIndex].InputSchemaJson);
      if not (LSchema is TJSONObject) then
      begin
        LSchema.Free; // nil-safe
        LSchema := TJSONObject.ParseJSONValue('{"type":"object"}');
      end;
      LFn.AddPair('parameters', LSchema);
    end;
    Result := LArr.ToJSON;
  finally
    LArr.Free;
  end;
end;

{ TAgentMcpClient }

constructor TAgentMcpClient.Create(const ATransport: IAgentFrameTransport);
begin
  inherited Create;
  FTransport := ATransport;
  FNextId := 0;
end;

function TAgentMcpClient._Request(const AFrame: string; const AId: Integer;
  out AResultJson: string; out AError: string): Boolean;
const
  CMaxNotificationsSkipped = 256; // guard against a notification flood
var
  LLine: string;
  LSkipped: Integer;
begin
  Result := False;
  AResultJson := '';
  if not FTransport.SendLine(AFrame) then
  begin
    AError := 'The aefos MCP connection is closed (send failed).';
    Exit;
  end;
  // Skip server-initiated notifications that may arrive between our request and
  // its response (review S3) — read until a real response frame or a bounded
  // flood limit.
  LSkipped := 0;
  repeat
    if not FTransport.ReadLine(LLine) then
    begin
      AError := 'The aefos MCP server did not answer (connection closed).';
      Exit;
    end;
    if not TMcpWire.IsNotificationFrame(LLine) then
      Break;
    Inc(LSkipped);
    if LSkipped > CMaxNotificationsSkipped then
    begin
      AError := 'The aefos MCP server sent only notifications, no response.';
      Exit;
    end;
  until False;
  // Result=True when a RESPONSE frame arrived (the transport is alive) - even
  // when that response is a JSON-RPC ERROR, in which case AError carries its
  // message. Result=False = transport/protocol-level failure (send/read died,
  // malformed frame, id desync). Callers decide: the handshake/catalog treat
  // any AError as failure; CallTool feeds an error RESPONSE back to the model
  // as tool feedback instead of killing the turn.
  Result := TMcpWire.ParseResponse(LLine, AId, AResultJson, AError);
  if (not Result) and (AError = '') then
    AError := 'Unreadable MCP response.';
end;

function TAgentMcpClient.Initialize(out AError: string): Boolean;
var
  LResult: string;
  LRoot: TJSONValue;
  LName: string;
begin
  Inc(FNextId);
  Result := _Request(TMcpWire.InitializeFrame(FNextId), FNextId, LResult, AError) and
    (AError = '');
  if not Result then
    Exit;
  // serverInfo.name is the "who answered" proof (the Options Test MCP uses
  // the same signal); absence is tolerated, a wrong protocol error is not.
  LRoot := TJSONObject.ParseJSONValue(LResult);
  try
    if (LRoot is TJSONObject) and
      (TJSONObject(LRoot).TryGetValue<string>('serverInfo.name', LName)) then
      FServerName := LName;
  finally
    LRoot.Free;
  end;
  // Fire-and-forget per spec: notifications get no response line.
  FTransport.SendLine(TMcpWire.InitializedNotification);
end;

function TAgentMcpClient.ListTools(out ATools: TArray<TMcpToolDef>;
  out AError: string): Boolean;
var
  LResult: string;
begin
  ATools := nil;
  Inc(FNextId);
  Result := _Request(TMcpWire.ToolsListFrame(FNextId), FNextId, LResult, AError) and
    (AError = '');
  if not Result then
    Exit;
  ATools := TMcpWire.ParseToolsList(LResult);
  if Length(ATools) = 0 then
  begin
    Result := False;
    AError := 'The aefos MCP server reported no tools.';
  end;
end;

function TAgentMcpClient.CallTool(const AName, AArgumentsJson: string;
  out ATextOut: string; out AIsError: Boolean; out AError: string): Boolean;
var
  LResult: string;
begin
  ATextOut := '';
  AIsError := False;
  Inc(FNextId);
  Result := _Request(TMcpWire.ToolsCallFrame(FNextId, AName, AArgumentsJson),
    FNextId, LResult, AError);
  if not Result then
    Exit; // transport/protocol dead: the turn cannot continue
  if AError <> '' then
  begin
    // The server ANSWERED with a JSON-RPC error (e.g. -32000 'no active
    // project', a RULE #1 wrong-view rejection): that is TOOL FEEDBACK, not a
    // dead pipe. Field report 2026-07-10: treating it as fatal killed the turn
    // at 'no active project' instead of letting the model create the project.
    ATextOut := AError;
    AIsError := True;
    AError := '';
    Exit(True);
  end;
  if not TMcpWire.ParseToolCallResult(LResult, ATextOut, AIsError) then
  begin
    Result := False;
    AError := 'Unreadable tools/call result for "' + AName + '".';
  end;
end;

end.
