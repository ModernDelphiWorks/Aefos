unit Aefos.Provider.Ollama.Core;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  Pure Ollama chat-API core: request building + NDJSON stream parsing +
  /api/tags model-list parsing.

  Ollama is the sanctioned LOCAL-runtime exception to the "harness for the
  user's own AI CLI — never a direct LLM client" rule (maintainer decision
  2026-07-08): the endpoint is the user's own machine/network (default
  http://localhost:11434), no cloud vendor, no API key. The HTTP transport
  lives in the next layer (Aefos.Provider.Ollama); THIS unit is pure — no
  ToolsAPI, no Vcl.*, no I/O — so it compiles into the dcc32 console suite
  (Aefos.PureLogic.Tests) like the FlowGuide/IntentGuard cores.

  Stream protocol (POST /api/chat, "stream": true): the server answers with
  one JSON object PER LINE (NDJSON). Each line carries a message.content
  delta; the terminal line has "done": true plus the token counters
  (prompt_eval_count / eval_count). Errors arrive as an "error" member.
}

interface

uses
  {$IFDEF FPC}
  SysUtils;
  {$ELSE}
  System.SysUtils;
  {$ENDIF}

const
  COllamaDefaultBaseUrl = 'http://localhost:11434';

type
  TOllamaMessage = record
    Role: string;    // 'system' | 'user' | 'assistant' | 'tool'
    Content: string;
    // Agent-loop fields (both '' on plain chat messages, so pre-loop callers
    // are untouched): a tool RESULT names its tool; an assistant message may
    // echo the tool_calls array it answered with (history replay fidelity).
    ToolName: string;
    ToolCallsJson: string; // raw JSON array, verbatim
    // Vision: base64 image payloads attached to this message (Ollama's
    // /api/chat "images" member; vision models read them). Empty on plain
    // messages, so pre-vision callers are untouched.
    Images: TArray<string>;
    class function New(const ARole, AContent: string): TOllamaMessage; static;
    class function NewToolResult(const AToolName,
      AContent: string): TOllamaMessage; static;
    class function NewAssistantToolCalls(const AContent,
      AToolCallsJson: string): TOllamaMessage; static;
  end;

  // One parsed NDJSON stream line from /api/chat.
  TOllamaChunk = record
    Content: string;           // message.content delta ('' on the final line)
    Done: Boolean;             // True on the terminal line
    Error: string;             // non-empty => server-reported error
    PromptTokens: Integer;     // prompt_eval_count (terminal line only)
    CompletionTokens: Integer; // eval_count (terminal line only)
    ToolCallsJson: string;     // message.tool_calls (raw array) when present
  end;

  // One entry of a message.tool_calls array: the function the model wants
  // to run. Arguments arrive as a JSON OBJECT (Ollama, unlike OpenAI's
  // stringified form) and are kept verbatim for the executor.
  TOllamaToolCall = record
    Name: string;
    ArgumentsJson: string;
  end;

// Endpoint builders: tolerate a trailing slash on the configured base URL and
// fall back to the default when it is blank.
function OllamaChatEndpoint(const ABaseUrl: string): string;
function OllamaTagsEndpoint(const ABaseUrl: string): string;
function OllamaShowEndpoint(const ABaseUrl: string): string;

// POST /api/generate -- the FILL-IN-THE-MIDDLE endpoint, and the reason it is
// separate from /api/chat: inline completion is not a conversation. The model is
// handed the text BEFORE the caret and the text AFTER it and asked for the
// middle, which is a different request shape (prompt + suffix, no messages) and
// a different model capability. A model without FIM in its template answers
// `"<name> does not support insert"` rather than guessing -- measured against
// qwen2.5:0.5b, 2026-08-03.
function OllamaGenerateEndpoint(const ABaseUrl: string): string;

// Builds the /api/generate FIM body.
//   AKeepAliveSeconds is load-bearing for this feature, not a tuning knob: the
// server's default OLLAMA_KEEP_ALIVE is 5 minutes, and a cold load of a 14B
// model off a slow disk measured 99 SECONDS. So a user who stops typing for five
// minutes would pay a minute and a half for the next suggestion -- the feature
// would feel broken through no fault of the model. <= 0 omits the member and
// keeps the server default.
//   Stop sequences keep a single-line suggestion single-line at the SERVER,
// instead of generating tokens we would throw away.
function OllamaBuildGenerateRequest(const AModel, APrefix, ASuffix: string;
  const AMaxTokens: Integer = 0; const ATemperature: Double = -1.0;
  const AStopAtNewline: Boolean = True;
  const AKeepAliveSeconds: Integer = 0): string;

// Parses a non-streamed /api/generate reply. False when the payload is not a
// JSON object or carries an "error" member (e.g. the model has no FIM support),
// with the server's own message in AError -- surfacing THAT beats inventing
// "no suggestion", which would hide a misconfigured model forever.
function OllamaParseGenerateResponse(const AJson: string;
  out AResponse: string; out AError: string): Boolean;

// Body for POST /api/show (capability probe): {"model":"<id>"}.
function OllamaShowRequest(const AModel: string): string;

// Parses the /api/show "capabilities" array (e.g. ["completion","tools",
// "thinking","vision"]). Malformed/absent => empty. Used to gate agent mode:
// only a model advertising 'tools' can run the tool loop.
function OllamaParseCapabilities(const AJson: string): TArray<string>;
function OllamaCapabilitiesHaveTools(const ACapabilities: TArray<string>): Boolean;
function OllamaCapabilitiesHaveVision(const ACapabilities: TArray<string>): Boolean;

// Builds the /api/chat request body. Temperature < 0 and MaxTokens <= 0 omit
// the respective option (server defaults win); with both omitted no "options"
// object is emitted at all.
function OllamaBuildChatRequest(const AModel: string;
  const AMessages: TArray<TOllamaMessage>; const AStream: Boolean;
  const ATemperature: Double = -1.0; const AMaxTokens: Integer = 0): string; overload;

// Agent-loop overload: AToolsJson is the "tools" array (raw JSON, e.g. from
// OllamaToolsJson in the CLI) offered to the model; '' emits no tools member
// - byte-identical to the plain overload then. Tool-result and assistant-
// with-tool_calls messages are emitted with their extra members.
function OllamaBuildChatRequest(const AModel: string;
  const AMessages: TArray<TOllamaMessage>; const AStream: Boolean;
  const AToolsJson: string;
  const ATemperature: Double; const AMaxTokens: Integer): string; overload;

// Parses a message.tool_calls array (as delivered in TOllamaChunk.
// ToolCallsJson). Malformed input yields an empty array.
function OllamaParseToolCalls(
  const AToolCallsJson: string): TArray<TOllamaToolCall>;

// Serializes calls back to a tool_calls array
// ([{"function":{"name","arguments":{...}}}]) — used when a hop's calls were
// accumulated across MULTIPLE stream chunks and must be re-attached to the
// replayed assistant message. Round-trips with OllamaParseToolCalls.
function OllamaSerializeToolCalls(
  const ACalls: TArray<TOllamaToolCall>): string;

// Parses ONE NDJSON line. False when the line is not a JSON object (partial
// fragments, keep-alives, blank lines) — the caller just skips it.
function OllamaParseChunk(const ALine: string; out AChunk: TOllamaChunk): Boolean;

// Splits the accumulated HTTP buffer into complete lines, leaving a partial
// trailing fragment (no terminating LF yet) in ABuffer for the next round.
// CR is stripped; empty lines are dropped.
function OllamaSplitBufferLines(var ABuffer: string): TArray<string>;

// Parses the GET /api/tags response into a sorted model-name list. A malformed
// or model-less response yields an empty array (the caller decides fallbacks).
function OllamaParseTagsModels(const AJson: string): TArray<string>;

type
  // Streamed UTF-8 decoder for the HTTP byte chunks: an HTTP read can cut a
  // multibyte sequence anywhere, so each call decodes only the longest valid
  // prefix and carries the incomplete tail bytes into the next call. Pure —
  // the transport (Aefos.Provider.Ollama) owns one per request.
  TOllamaUtf8StreamDecoder = class
  private
    FCarry: TBytes;
  public
    function Decode(const ABytes: TBytes): string;
  end;

implementation

uses
  {$IFDEF FPC}
  Classes,
  Generics.Collections,
  Generics.Defaults,
  Aefos.Compat.Json;
  {$ELSE}
  System.Classes,
  System.Generics.Collections,
  System.Generics.Defaults,
  System.JSON;
  {$ENDIF}

type
  // Names the /api/tags sort order (case-insensitive) instead of the old inline
  // TComparer<string>.Construct closure - FPC 3.2.2 has no anonymous methods,
  // and a named comparer is byte-identical on Delphi (CompareText ordering).
  TOllamaNameComparer = class(TInterfacedObject, IComparer<string>)
  public
    // IComparer<T>.Compare is constref on FPC, const on Delphi - match each.
    {$IFDEF FPC}
    function Compare(constref ALeft, ARight: string): Integer;
    {$ELSE}
    function Compare(const ALeft, ARight: string): Integer;
    {$ENDIF}
  end;

{$IFDEF FPC}
function TOllamaNameComparer.Compare(constref ALeft, ARight: string): Integer;
{$ELSE}
function TOllamaNameComparer.Compare(const ALeft, ARight: string): Integer;
{$ENDIF}
begin
  Result := CompareText(ALeft, ARight);
end;

{ TOllamaUtf8StreamDecoder }

function TOllamaUtf8StreamDecoder.Decode(const ABytes: TBytes): string;
var
  LCombined: TBytes;
  LTotal: Integer;
  LDecodable: Integer;
  LKeep: Integer;
  LIndex: Integer;
  LByte: Byte;
  LContinuations: Integer;
  LNeeded: Integer;
begin
  Result := '';
  if Length(ABytes) = 0 then
    Exit;

  if Length(FCarry) > 0 then
  begin
    SetLength(LCombined, Length(FCarry) + Length(ABytes));
    Move(FCarry[0], LCombined[0], Length(FCarry));
    Move(ABytes[0], LCombined[Length(FCarry)], Length(ABytes));
  end
  else
    LCombined := ABytes;

  LTotal := Length(LCombined);
  LDecodable := LTotal;
  LKeep := 0;

  // Scan back over at most 4 bytes: continuation bytes (10xxxxxx) until a
  // lead byte; if the lead announces more continuations than present, the
  // sequence is incomplete — hold it back. An ASCII byte ends the scan.
  LIndex := LTotal - 1;
  LContinuations := 0;
  while (LIndex >= 0) and (LIndex >= LTotal - 4) do
  begin
    LByte := LCombined[LIndex];
    if LByte < $80 then
      Break;
    if LByte <= $BF then
    begin
      Inc(LContinuations);
      Dec(LIndex);
      Continue;
    end;
    // Lead byte: how many continuation bytes does it require?
    if LByte <= $DF then
      LNeeded := 1
    else if LByte <= $EF then
      LNeeded := 2
    else
      LNeeded := 3;
    if LContinuations < LNeeded then
    begin
      LKeep := LTotal - LIndex;
      LDecodable := LIndex;
    end;
    Break;
  end;

  if LKeep > 0 then
  begin
    SetLength(FCarry, LKeep);
    Move(LCombined[LDecodable], FCarry[0], LKeep);
  end
  else
    FCarry := nil;

  if LDecodable > 0 then
    Result := TEncoding.UTF8.GetString(LCombined, 0, LDecodable);
end;

{ TOllamaMessage }

class function TOllamaMessage.New(const ARole, AContent: string): TOllamaMessage;
begin
  Result := Default(TOllamaMessage);
  Result.Role := ARole;
  Result.Content := AContent;
end;

class function TOllamaMessage.NewToolResult(const AToolName,
  AContent: string): TOllamaMessage;
begin
  Result := Default(TOllamaMessage);
  Result.Role := 'tool';
  Result.Content := AContent;
  Result.ToolName := AToolName;
end;

class function TOllamaMessage.NewAssistantToolCalls(const AContent,
  AToolCallsJson: string): TOllamaMessage;
begin
  Result := Default(TOllamaMessage);
  Result.Role := 'assistant';
  Result.Content := AContent;
  Result.ToolCallsJson := AToolCallsJson;
end;

function _NormalizedBase(const ABaseUrl: string): string;
var
  LLower: string;
begin
  Result := Trim(ABaseUrl);
  if Result = '' then
    Result := COllamaDefaultBaseUrl;
  // Tolerate a scheme-less host ("localhost:11434"): the endpoint field's
  // placeholder shows the full URL, but a user who types only the host must
  // still resolve to a valid URL instead of an ENetURIException at request time.
  LLower := LowerCase(Result);
  if (Copy(LLower, 1, 7) <> 'http://') and (Copy(LLower, 1, 8) <> 'https://') then
    Result := 'http://' + Result;
  while (Result <> '') and (Result[Length(Result)] = '/') do
    SetLength(Result, Length(Result) - 1);
end;

function OllamaChatEndpoint(const ABaseUrl: string): string;
begin
  Result := _NormalizedBase(ABaseUrl) + '/api/chat';
end;

function OllamaTagsEndpoint(const ABaseUrl: string): string;
begin
  Result := _NormalizedBase(ABaseUrl) + '/api/tags';
end;

function OllamaShowEndpoint(const ABaseUrl: string): string;
begin
  Result := _NormalizedBase(ABaseUrl) + '/api/show';
end;

function OllamaGenerateEndpoint(const ABaseUrl: string): string;
begin
  Result := _NormalizedBase(ABaseUrl) + '/api/generate';
end;

function OllamaBuildGenerateRequest(const AModel, APrefix, ASuffix: string;
  const AMaxTokens: Integer; const ATemperature: Double;
  const AStopAtNewline: Boolean; const AKeepAliveSeconds: Integer): string;
var
  LRoot: TJSONObject;
  LOptions: TJSONObject;
  LStop: TJSONArray;
begin
  LRoot := TJSONObject.Create;
  try
    LRoot.AddPair('model', AModel);
    LRoot.AddPair('prompt', APrefix);
    // The suffix member IS the fill-in-the-middle switch. Emitted even when
    // empty (caret at end of file): dropping it would silently turn the request
    // into ordinary continuation, and the model would happily write past the
    // end of a routine that already has its `end;`.
    LRoot.AddPair('suffix', ASuffix);
    // Inline completion never streams: there is one short answer and the ghost
    // appears whole or not at all. A half-painted suggestion is worse than none.
    LRoot.AddPair('stream', TJSONBool.Create(False));
    if AKeepAliveSeconds > 0 then
      LRoot.AddPair('keep_alive', TJSONNumber.Create(AKeepAliveSeconds));
    LOptions := nil;
    try
      if AMaxTokens > 0 then
      begin
        if LOptions = nil then
          LOptions := TJSONObject.Create;
        LOptions.AddPair('num_predict', TJSONNumber.Create(AMaxTokens));
      end;
      if ATemperature >= 0 then
      begin
        if LOptions = nil then
          LOptions := TJSONObject.Create;
        LOptions.AddPair('temperature', TJSONNumber.Create(ATemperature));
      end;
      if AStopAtNewline then
      begin
        if LOptions = nil then
          LOptions := TJSONObject.Create;
        LStop := TJSONArray.Create;
        LStop.Add(#10);
        LOptions.AddPair('stop', LStop);
      end;
      if LOptions <> nil then
      begin
        LRoot.AddPair('options', LOptions);
        LOptions := nil; // ownership moved to LRoot
      end;
    finally
      LOptions.Free; // no-op once adopted above
    end;
    Result := LRoot.ToJSON;
  finally
    LRoot.Free;
  end;
end;

function OllamaParseGenerateResponse(const AJson: string;
  out AResponse: string; out AError: string): Boolean;
var
  LRoot: TJSONValue;
  LValue: TJSONValue;
begin
  AResponse := '';
  AError := '';
  Result := False;
  LRoot := TJSONObject.ParseJSONValue(AJson);
  try
    if not (LRoot is TJSONObject) then
    begin
      AError := 'malformed response';
      Exit;
    end;
    // The server reports a model without FIM support as a plain 200 carrying an
    // "error" member, NOT an HTTP failure -- so a transport-only check would
    // read it as success with an empty completion.
    LValue := TJSONObject(LRoot).GetValue('error');
    if LValue is TJSONString then
    begin
      AError := TJSONString(LValue).Value;
      Exit;
    end;
    LValue := TJSONObject(LRoot).GetValue('response');
    if not (LValue is TJSONString) then
    begin
      AError := 'response member missing';
      Exit;
    end;
    AResponse := TJSONString(LValue).Value;
    Result := True;
  finally
    LRoot.Free;
  end;
end;

function OllamaShowRequest(const AModel: string): string;
var
  LRoot: TJSONObject;
begin
  LRoot := TJSONObject.Create;
  try
    LRoot.AddPair('model', AModel);
    Result := LRoot.ToJSON;
  finally
    LRoot.Free;
  end;
end;

function OllamaParseCapabilities(const AJson: string): TArray<string>;
var
  LRoot: TJSONValue;
  LObj: TJSONObject;
  LArr: TJSONArray;
  LItem: TJSONValue;
  LCount: Integer;
begin
  Result := nil;
  LRoot := TJSONObject.ParseJSONValue(AJson);
  try
    if not (LRoot is TJSONObject) then
      Exit;
    // Call the generic accessor through a typed local, not a cast expression,
    // and parenthesise it under `not`: FPC 3.2.2 mis-parses both
    // `TJSONObject(x).TryGetValue<...>(` and `not x.TryGetValue<...>(` as a
    // comparison. Harmless on Delphi.
    LObj := TJSONObject(LRoot);
    LArr := nil;
    if not (LObj.TryGetValue<TJSONArray>('capabilities', LArr)) then
      Exit;
    if LArr = nil then
      Exit;
    LCount := 0;
    SetLength(Result, LArr.Count);
    for LItem in LArr do
      if LItem is TJSONString then
      begin
        Result[LCount] := (LItem as TJSONString).Value;
        Inc(LCount);
      end;
    SetLength(Result, LCount);
  finally
    LRoot.Free;
  end;
end;

function OllamaCapabilitiesHaveTools(
  const ACapabilities: TArray<string>): Boolean;
var
  LCap: string;
begin
  Result := False;
  for LCap in ACapabilities do
    if SameText(LCap, 'tools') then
      Exit(True);
end;

function OllamaCapabilitiesHaveVision(
  const ACapabilities: TArray<string>): Boolean;
var
  LCap: string;
begin
  Result := False;
  for LCap in ACapabilities do
    if SameText(LCap, 'vision') then
      Exit(True);
end;

function OllamaBuildChatRequest(const AModel: string;
  const AMessages: TArray<TOllamaMessage>; const AStream: Boolean;
  const ATemperature: Double; const AMaxTokens: Integer): string;
begin
  Result := OllamaBuildChatRequest(AModel, AMessages, AStream, '',
    ATemperature, AMaxTokens);
end;

function OllamaBuildChatRequest(const AModel: string;
  const AMessages: TArray<TOllamaMessage>; const AStream: Boolean;
  const AToolsJson: string;
  const ATemperature: Double; const AMaxTokens: Integer): string;
var
  LRoot: TJSONObject;
  LOptions: TJSONObject;
  LMessages: TJSONArray;
  LMsgObj: TJSONObject;
  LIndex, LImgIdx: Integer;
  LImages: TJSONArray;
  LTools, LCalls: TJSONValue;
begin
  LRoot := TJSONObject.Create;
  try
    LRoot.AddPair('model', AModel);
    LRoot.AddPair('stream', TJSONBool.Create(AStream));

    if AToolsJson <> '' then
    begin
      LTools := TJSONObject.ParseJSONValue(AToolsJson);
      if LTools is TJSONArray then
        LRoot.AddPair('tools', LTools)
      else
        LTools.Free; // malformed catalog: emit no tools rather than garbage
    end;

    LOptions := TJSONObject.Create;
    if ATemperature >= 0.0 then
      LOptions.AddPair('temperature', TJSONNumber.Create(ATemperature));
    if AMaxTokens > 0 then
      LOptions.AddPair('num_predict', TJSONNumber.Create(AMaxTokens));
    if LOptions.Count > 0 then
      LRoot.AddPair('options', LOptions)
    else
      LOptions.Free;

    LMessages := TJSONArray.Create;
    LRoot.AddPair('messages', LMessages);
    for LIndex := 0 to High(AMessages) do
    begin
      LMsgObj := TJSONObject.Create;
      LMessages.AddElement(LMsgObj);
      LMsgObj.AddPair('role', AMessages[LIndex].Role);
      LMsgObj.AddPair('content', AMessages[LIndex].Content);
      // Vision: attach the base64 payloads when carried (see TOllamaMessage).
      if Length(AMessages[LIndex].Images) > 0 then
      begin
        LImages := TJSONArray.Create;
        LMsgObj.AddPair('images', LImages);
        for LImgIdx := 0 to High(AMessages[LIndex].Images) do
          LImages.Add(AMessages[LIndex].Images[LImgIdx]);
      end;
      // Agent-loop members, emitted only when carried (see TOllamaMessage).
      if AMessages[LIndex].ToolName <> '' then
        LMsgObj.AddPair('tool_name', AMessages[LIndex].ToolName);
      if AMessages[LIndex].ToolCallsJson <> '' then
      begin
        LCalls := TJSONObject.ParseJSONValue(AMessages[LIndex].ToolCallsJson);
        if LCalls is TJSONArray then
          LMsgObj.AddPair('tool_calls', LCalls)
        else
          LCalls.Free;
      end;
    end;

    Result := LRoot.ToJSON;
  finally
    LRoot.Free;
  end;
end;

function OllamaSerializeToolCalls(
  const ACalls: TArray<TOllamaToolCall>): string;
var
  LArr: TJSONArray;
  LObj, LFn: TJSONObject;
  LArgs: TJSONValue;
  I: Integer;
begin
  LArr := TJSONArray.Create;
  try
    for I := 0 to High(ACalls) do
    begin
      LObj := TJSONObject.Create;
      LArr.AddElement(LObj);
      LFn := TJSONObject.Create;
      LObj.AddPair('function', LFn);
      LFn.AddPair('name', ACalls[I].Name);
      LArgs := TJSONObject.ParseJSONValue(ACalls[I].ArgumentsJson);
      if not (LArgs is TJSONObject) then
      begin
        LArgs.Free; // nil-safe; malformed/absent -> empty object
        LArgs := TJSONObject.Create;
      end;
      LFn.AddPair('arguments', LArgs);
    end;
    Result := LArr.ToJSON;
  finally
    LArr.Free;
  end;
end;

function OllamaParseToolCalls(
  const AToolCallsJson: string): TArray<TOllamaToolCall>;
var
  LRoot: TJSONValue;
  LArr: TJSONArray;
  LItem, LArgs: TJSONValue;
  LFn: TJSONObject;
  LCount: Integer;
begin
  Result := nil;
  LRoot := TJSONObject.ParseJSONValue(AToolCallsJson);
  try
    if not (LRoot is TJSONArray) then
      Exit;
    LArr := LRoot as TJSONArray;
    LCount := 0;
    SetLength(Result, LArr.Count);
    for LItem in LArr do
    begin
      if not (LItem is TJSONObject) then
        Continue;
      if not (TJSONObject(LItem).GetValue('function') is TJSONObject) then
        Continue;
      LFn := TJSONObject(TJSONObject(LItem).GetValue('function'));
      Result[LCount].Name := LFn.GetValue<string>('name', '');
      if Result[LCount].Name = '' then
        Continue;
      LArgs := LFn.GetValue('arguments');
      if LArgs <> nil then
        Result[LCount].ArgumentsJson := LArgs.ToJSON
      else
        Result[LCount].ArgumentsJson := '{}';
      Inc(LCount);
    end;
    SetLength(Result, LCount);
  finally
    LRoot.Free;
  end;
end;

function OllamaParseChunk(const ALine: string; out AChunk: TOllamaChunk): Boolean;
var
  LValue: TJSONValue;
  LRoot: TJSONObject;
  LMessage: TJSONObject;
  LError: TJSONValue;
begin
  AChunk.Content := '';
  AChunk.Done := False;
  AChunk.Error := '';
  AChunk.PromptTokens := 0;
  AChunk.CompletionTokens := 0;
  AChunk.ToolCallsJson := '';

  LValue := TJSONObject.ParseJSONValue(ALine);
  Result := LValue is TJSONObject;
  if not Result then
  begin
    LValue.Free;
    Exit;
  end;

  LRoot := LValue as TJSONObject;
  try
    LError := LRoot.GetValue('error');
    if Assigned(LError) then
    begin
      if LError is TJSONString then
        AChunk.Error := (LError as TJSONString).Value
      else
        AChunk.Error := LError.ToJSON;
      // An error line terminates the stream regardless of a "done" member.
      AChunk.Done := True;
      Exit;
    end;

    if LRoot.GetValue('message') is TJSONObject then
    begin
      LMessage := TJSONObject(LRoot.GetValue('message'));
      AChunk.Content := LMessage.GetValue<string>('content', '');
      // Agent loop: the model's tool requests ride the same stream. Kept as
      // the raw array; OllamaParseToolCalls splits it when the caller cares.
      if LMessage.GetValue('tool_calls') is TJSONArray then
        AChunk.ToolCallsJson := LMessage.GetValue('tool_calls').ToJSON;
    end;
    AChunk.Done := LRoot.GetValue<Boolean>('done', False);
    if AChunk.Done then
    begin
      AChunk.PromptTokens := LRoot.GetValue<Integer>('prompt_eval_count', 0);
      AChunk.CompletionTokens := LRoot.GetValue<Integer>('eval_count', 0);
    end;
  finally
    LRoot.Free;
  end;
end;

function OllamaSplitBufferLines(var ABuffer: string): TArray<string>;
var
  LLines: TList<string>;
  LStart: Integer;
  LIndex: Integer;
  LLine: string;
begin
  LLines := TList<string>.Create;
  try
    LStart := 1;
    for LIndex := 1 to Length(ABuffer) do
      if ABuffer[LIndex] = #10 then
      begin
        LLine := Copy(ABuffer, LStart, LIndex - LStart);
        LLine := StringReplace(LLine, #13, '', [rfReplaceAll]);
        if Trim(LLine) <> '' then
          LLines.Add(LLine);
        LStart := LIndex + 1;
      end;
    ABuffer := Copy(ABuffer, LStart, MaxInt);
    Result := LLines.ToArray;
  finally
    LLines.Free;
  end;
end;

function OllamaParseTagsModels(const AJson: string): TArray<string>;
var
  LValue: TJSONValue;
  LRoot: TJSONObject;
  LModels: TJSONArray;
  LItem: TJSONValue;
  LItemObj: TJSONObject;
  LName: string;
  LList: TList<string>;
begin
  SetLength(Result, 0);
  LValue := TJSONObject.ParseJSONValue(AJson);
  if not (LValue is TJSONObject) then
  begin
    LValue.Free;
    Exit;
  end;
  LRoot := LValue as TJSONObject;
  LList := TList<string>.Create;
  try
    if LRoot.GetValue('models') is TJSONArray then
    begin
      LModels := TJSONArray(LRoot.GetValue('models'));
      for LItem in LModels do
        if LItem is TJSONObject then
        begin
          // Typed local, not a cast expression (FPC generic-call parse limit).
          LItemObj := TJSONObject(LItem);
          LName := LItemObj.GetValue<string>('name', '');
          if LName <> '' then
            LList.Add(LName);
        end;
    end;
    LList.Sort(TOllamaNameComparer.Create);
    Result := LList.ToArray;
  finally
    LList.Free;
    LRoot.Free;
  end;
end;

end.
