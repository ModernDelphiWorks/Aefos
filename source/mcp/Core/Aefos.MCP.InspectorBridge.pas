unit Aefos.MCP.InspectorBridge;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

(*
  Host-side bridge for the MCP Tool Inspector (Epic 7/7 Demand 1/8, ADR-117).

  Responsibilities:
    - Build a synthetic JSON-RPC 2.0 `tools/call` request for the WebView2 page
      to display side-by-side with the response (AC-07).
    - Dispatch the request through the supplied IMCPInspectorHost (the
      composition root wires a live TMCPServer; the server implements
      IMCPInspectorHost directly so the live transport is untouched).
    - Capture the JSON-RPC response.
    - Read the audit-log delta (the JSONL lines TMCPAuditLog appended during
      the call), returned as a JSON array of objects (one per line).
    - Package everything into the payload the WebView2 page renders.

  Threading:
    - Single-threaded by contract - called by the form's WebMessageReceived
      handler on the IDE main thread. No internal worker threads.

  Layering:
    - RTL-only. Zero `uses ToolsAPI` (ADR-115). Unit-testable through a
      TStubInspectorHost that wraps a closure (per Tests.MCPInspectorBridge).
*)

interface

uses
  Aefos.Compat.Json;

type
  /// <summary>
  /// Host surface the bridge calls to dispatch a JSON-RPC frame through the
  /// in-process MCP server. TMCPServer implements it directly (see
  /// Aefos.MCP.Server). Kept narrow so the bridge stays RTL-only and
  /// the composition root supplies the live instance.
  /// </summary>
  IMCPInspectorHost = interface
    ['{B4A07F92-3D08-4C71-8C29-1F6E29A0B925}']
    function DispatchInspectorFrame(const AFrame: string): string;
  end;

  IMCPInspectorBridge = interface
    ['{E2A1F4B7-3D08-4C71-8C29-7D6F2A0B9145}']
    /// <summary>
    /// Builds a synthetic tools/call frame for <paramref name="AToolId"/>,
    /// dispatches it through the host, harvests the response + the audit-log
    /// lines appended during the call, and returns:
    ///
    ///   {
    ///     "request":     {jsonrpc, method, params, id},
    ///     "response":    {jsonrpc, id, result | error},
    ///     "audit_delta": [<jsonl line>, ...],
    ///     "diff":        null
    ///   }
    ///
    /// The "diff" field is always null at this layer - the form-side adapter
    /// (S-3) populates it for write tools after the bridge returns.
    /// </summary>
    function HandleInspectorRequest(const AToolId: string;
      const AArgs: TJSONObject): TJSONObject;
  end;

  TMCPInspectorBridge = class(TInterfacedObject, IMCPInspectorBridge)
  private
    FHost: IMCPInspectorHost;
    FAuditLogPath: string;
    FNextId: Int64;
    FLock: TObject; // TCriticalSection - opaque to keep uses lean
    function _NewRequestId: Int64;
    function _AuditLogSize: Int64;
    function _ReadAuditDelta(const ABeforeBytes: Int64;
      const AAfterBytes: Int64): TJSONArray;
    function _BuildRequestFrame(const AToolId: string;
      const AArgs: TJSONObject; out AFrameJson: string): TJSONObject;
    function _ParseResponseFrame(const AFrame: string): TJSONObject;
  public
    constructor Create(const AHost: IMCPInspectorHost;
      const AAuditLogPath: string);
    destructor Destroy; override;
    function HandleInspectorRequest(const AToolId: string;
      const AArgs: TJSONObject): TJSONObject;
  end;

implementation

uses
  // Winapi-scoped units stay dotted on Delphi: not every consumer .dproj config
  // carries the Winapi unit-scope prefix (System.* is safe, Winapi.* is not).
{$IFDEF FPC}
  Windows,
{$ELSE}
  Winapi.Windows,
{$ENDIF}
  SysUtils,
  Classes,
  Aefos.Compat.IO,
  SyncObjs;

// Split on any CR/LF, dropping empty segments (the classic-RTL replacement for
// the Delphi-only `S.Split([sLineBreak,#10,#13], ExcludeEmpty)` fluent helper,
// which FPC 3.2.2 does not provide).
function _SplitNonEmptyLines(const AText: string): TArray<string>;
var
  LIndex, LStart, LCount: Integer;

  procedure _Emit(const AFrom, ATo: Integer);
  begin
    if ATo >= AFrom then
    begin
      SetLength(Result, LCount + 1);
      Result[LCount] := Copy(AText, AFrom, ATo - AFrom + 1);
      Inc(LCount);
    end;
  end;

begin
  SetLength(Result, 0);
  LCount := 0;
  LStart := 1;
  for LIndex := 1 to Length(AText) do
    if (AText[LIndex] = #10) or (AText[LIndex] = #13) then
    begin
      _Emit(LStart, LIndex - 1);   // _Emit skips empty runs (ExcludeEmpty)
      LStart := LIndex + 1;
    end;
  _Emit(LStart, Length(AText));
end;

{ TMCPInspectorBridge }

constructor TMCPInspectorBridge.Create(const AHost: IMCPInspectorHost;
  const AAuditLogPath: string);
begin
  inherited Create;
  if not Assigned(AHost) then
    raise EArgumentNilException.Create('TMCPInspectorBridge: AHost');
  FHost := AHost;
  FAuditLogPath := AAuditLogPath;
  FNextId := 0;
  FLock := TCriticalSection.Create;
end;

destructor TMCPInspectorBridge.Destroy;
begin
  FLock.Free;
  inherited;
end;

function TMCPInspectorBridge._NewRequestId: Int64;
begin
  TCriticalSection(FLock).Enter;
  try
    Inc(FNextId);
    Result := FNextId;
  finally
    TCriticalSection(FLock).Leave;
  end;
end;

function TMCPInspectorBridge._AuditLogSize: Int64;
begin
  // Missing file is the normal first-call state - return 0 so the delta
  // computation harvests the entire post-call body.
  Result := 0;
  if FAuditLogPath = '' then
    Exit;
  if not TFile.Exists(FAuditLogPath) then
    Exit;
  try
    Result := TFile.GetSize(FAuditLogPath);
  except
    on E: Exception do
      // BR-9 (mirrors AuditLog write policy): observability noise is never
      // a tool abort. Treat read failures as zero size; the delta becomes
      // the full post-call file content if reachable.
{$IFDEF FPC}
      OutputDebugStringW(PWideChar(
        'Aefos.MCPInspectorBridge.AuditLogSize: ' + E.Message));
{$ELSE}
      OutputDebugString(PChar(
        'Aefos.MCPInspectorBridge.AuditLogSize: ' + E.Message));
{$ENDIF}
  end;
end;

function TMCPInspectorBridge._ReadAuditDelta(const ABeforeBytes: Int64;
  const AAfterBytes: Int64): TJSONArray;
var
  LStream: TFileStream;
  LBytes: TBytes;
  LLineCount: Integer;
  LIndex: Integer;
  LDelta: string;
  LLines: TArray<string>;
  LLine: string;
  LParsed: TJSONValue;
begin
  Result := TJSONArray.Create;
  if (FAuditLogPath = '') or (AAfterBytes <= ABeforeBytes) then
    Exit;
  if not TFile.Exists(FAuditLogPath) then
    Exit;
  try
    LStream := TFileStream.Create(FAuditLogPath,
      fmOpenRead or fmShareDenyNone);
    try
      LStream.Position := ABeforeBytes;
      SetLength(LBytes, AAfterBytes - ABeforeBytes);
      LStream.ReadBuffer(LBytes[0], Length(LBytes));
    finally
      LStream.Free;
    end;
    LDelta := TEncoding.UTF8.GetString(LBytes);
  except
    on E: Exception do
    begin
{$IFDEF FPC}
      OutputDebugStringW(PWideChar(
        'Aefos.MCPInspectorBridge.ReadAuditDelta: ' + E.Message));
{$ELSE}
      OutputDebugString(PChar(
        'Aefos.MCPInspectorBridge.ReadAuditDelta: ' + E.Message));
{$ENDIF}
      Exit;
    end;
  end;
  LLines := _SplitNonEmptyLines(LDelta);
  LLineCount := Length(LLines);
  for LIndex := 0 to LLineCount - 1 do
  begin
    LLine := Trim(LLines[LIndex]);
    if LLine = '' then
      Continue;
    LParsed := TJSONObject.ParseJSONValue(LLine);
    // ADR-067: the audit log is line-delimited JSON; a non-JSON line is a
    // corruption and is preserved as a string entry so the maintainer can
    // see it in the Inspector instead of silently losing it.
    if Assigned(LParsed) then
      Result.AddElement(LParsed)
    else
      Result.Add(LLine);
  end;
end;

function TMCPInspectorBridge._BuildRequestFrame(const AToolId: string;
  const AArgs: TJSONObject; out AFrameJson: string): TJSONObject;
var
  LParams: TJSONObject;
  LArgsClone: TJSONValue;
  LFrame: TJSONObject;
begin
  // The bridge owns its frame's lifetime up until it serialises to AFrameJson;
  // after that, the JSON string is what travels through IMCPInspectorHost.
  // Result is a *separate* object that is included in the payload as
  // "request" - it lives as long as the payload does (caller free'd).
  LFrame := TJSONObject.Create;
  try
    LFrame.AddPair('jsonrpc', '2.0');
    LFrame.AddPair('id', TJSONNumber.Create(_NewRequestId));
    LFrame.AddPair('method', 'tools/call');
    LParams := TJSONObject.Create;
    LParams.AddPair('name', AToolId);
    if Assigned(AArgs) then
      LArgsClone := TJSONObject.ParseJSONValue(AArgs.ToJSON)
    else
      LArgsClone := TJSONObject.Create;
    LParams.AddPair('arguments', LArgsClone);
    LFrame.AddPair('params', LParams);
    AFrameJson := LFrame.ToJSON;
    // Build a second copy for the payload's "request" field - we MUST NOT
    // hand the same TJSONObject to two owners (TJSONObject does single-owner
    // lifetime). ParseJSONValue clones via re-parse.
    Result := TJSONObject(TJSONObject.ParseJSONValue(AFrameJson));
  finally
    LFrame.Free;
  end;
end;

function TMCPInspectorBridge._ParseResponseFrame(const AFrame: string): TJSONObject;
var
  LValue: TJSONValue;
  LError: TJSONObject;
begin
  // A nil/empty frame degrades to a synthetic error envelope so the Inspector
  // page can render *something* in the response pane instead of crashing.
  if AFrame = '' then
  begin
    Result := TJSONObject.Create;
    Result.AddPair('jsonrpc', '2.0');
    Result.AddPair('id', TJSONNull.Create);
    LError := TJSONObject.Create;
    LError.AddPair('code', TJSONNumber.Create(-32603));
    LError.AddPair('message', 'inspector bridge: empty response from dispatch');
    Result.AddPair('error', LError);
    Exit;
  end;
  LValue := TJSONObject.ParseJSONValue(AFrame);
  if not (LValue is TJSONObject) then
  begin
    LValue.Free;
    Result := TJSONObject.Create;
    Result.AddPair('jsonrpc', '2.0');
    Result.AddPair('id', TJSONNull.Create);
    LError := TJSONObject.Create;
    LError.AddPair('code', TJSONNumber.Create(-32603));
    LError.AddPair('message', 'inspector bridge: response is not a JSON object');
    Result.AddPair('error', LError);
    Exit;
  end;
  Result := TJSONObject(LValue);
end;

function TMCPInspectorBridge.HandleInspectorRequest(const AToolId: string;
  const AArgs: TJSONObject): TJSONObject;
var
  LRequest: TJSONObject;
  LFrameJson: string;
  LResponseFrame: string;
  LResponse: TJSONObject;
  LBeforeBytes: Int64;
  LAfterBytes: Int64;
  LAuditDelta: TJSONArray;
  LError: TJSONObject;
begin
  if Trim(AToolId) = '' then
    raise EArgumentException.Create(
      'TMCPInspectorBridge.HandleInspectorRequest: tool id required');

  LRequest := _BuildRequestFrame(AToolId, AArgs, LFrameJson);
  Result := TJSONObject.Create;
  try
    Result.AddPair('request', LRequest);
    LBeforeBytes := _AuditLogSize;
    try
      LResponseFrame := FHost.DispatchInspectorFrame(LFrameJson);
    except
      on E: Exception do
      begin
        // BR-10: transport-level failure is rendered as a synthetic
        // internal-error response so the page never sees a Delphi crash.
        LError := TJSONObject.Create;
        LError.AddPair('code', TJSONNumber.Create(-32603));
        LError.AddPair('message', 'inspector bridge dispatch: ' +
          E.ClassName + ': ' + E.Message);
        LResponse := TJSONObject.Create;
        LResponse.AddPair('jsonrpc', '2.0');
        LResponse.AddPair('id', TJSONNull.Create);
        LResponse.AddPair('error', LError);
        Result.AddPair('response', LResponse);
        Result.AddPair('audit_delta', TJSONArray.Create);
        Result.AddPair('diff', TJSONNull.Create);
        Exit;
      end;
    end;
    LAfterBytes := _AuditLogSize;
    LResponse := _ParseResponseFrame(LResponseFrame);
    Result.AddPair('response', LResponse);
    LAuditDelta := _ReadAuditDelta(LBeforeBytes, LAfterBytes);
    Result.AddPair('audit_delta', LAuditDelta);
    Result.AddPair('diff', TJSONNull.Create);
  except
    Result.Free;
    raise;
  end;
end;

end.
