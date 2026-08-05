unit Aefos.Agent.Capability;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

(*
  Aefos Agent CLI - synchronous /api/show capability probe.

  Agent mode is gated on the selected model advertising 'tools' in its
  capabilities (Ollama /api/show). A tiny blocking POST is right here: it runs
  once before the turn, off the streaming path. AReached distinguishes "the
  endpoint answered" from "could not ask". The CLI's policy (in AefosAgent.dpr)
  is OPTIMISTIC: a definite "reached, no tools" degrades to chat with a notice,
  but an UNREACHABLE probe still offers tools (a transient blip must not
  silently strip tools from a capable model) - and the CLI notes that it did.
  Never a hard error.
*)

interface

uses
  {$IFDEF FPC}
  SysUtils,
  {$ELSE}
  System.SysUtils,
  {$ENDIF}
  Aefos.Compat.Http,
  Aefos.Provider.Ollama.Core;

type
  { Static, sealed namespace for the synchronous /api/show capability probe.
    Never instantiated; the class IS the namespace. }
  TAgentCapabilityProbe = class sealed
  public
    // True when the model advertises tool support. AError is informational only
    // (the caller degrades to chat regardless); AReached tells apart "endpoint
    // answered, no tools" from "could not ask".
    class function ModelSupportsTools(const ABaseUrl, AModel: string;
      out AReached: Boolean; out AError: string): Boolean; static;

    // True when the model advertises the 'vision' capability (image attachments
    // ride the message's images member). Same probe/temperament as the tools
    // gate; a failed probe reads as "no vision" - the caller notes and degrades.
    class function ModelSupportsVision(const ABaseUrl, AModel: string): Boolean; static;

    // Harness P0-3: the model's context window from /api/show model_info (the
    // arch-prefixed '<arch>.context_length' key). 0 when the probe fails or the
    // key is absent - the caller then leaves compaction OFF unless --ctx says
    // otherwise. NOTE: this is the model MAXIMUM; a server running a smaller
    // num_ctx truncates earlier - --ctx exists exactly to override that.
    class function ProbeContextWindow(const ABaseUrl, AModel: string): Integer; static;

    // Pure: extracts the context window from an /api/show response body. Exposed
    // for the headless suite.
    class function ParseContextWindow(const AShowBody: string): Integer; static;
  end;

implementation

uses
  {$IFDEF FPC}
  Aefos.Compat.Json;
  {$ELSE}
  System.JSON;
  {$ENDIF}

const
  CShowTimeoutMs = 5000;
  CContentTypeJson = 'application/json';

// Classic suffix test (FPC 3.2.2 has no TStringHelper): byte-identical to
// string.EndsWith for the ASCII keys this unit sees.
function _EndsWithStr(const AText, ASuffix: string): Boolean;
begin
  Result := (Length(ASuffix) <= Length(AText)) and
    (Copy(AText, Length(AText) - Length(ASuffix) + 1, Length(ASuffix)) = ASuffix);
end;

class function TAgentCapabilityProbe.ParseContextWindow(
  const AShowBody: string): Integer;
var
  LRoot: TJSONValue;
  LObj, LInfo: TJSONObject;
  LPair: TJSONPair;
  LVal: Integer;
begin
  Result := 0;
  LRoot := TJSONObject.ParseJSONValue(AShowBody);
  try
    if not (LRoot is TJSONObject) then
      Exit;
    LObj := TJSONObject(LRoot);
    LInfo := nil;
    if not (LObj.TryGetValue<TJSONObject>('model_info', LInfo)) then
      Exit;
    if LInfo = nil then
      Exit;
    for LPair in LInfo do
      if _EndsWithStr(LPair.JsonString.Value, '.context_length') then
      begin
        LVal := 0;
        // Empty path reads THIS value as T (the single TryGetValue<T> form);
        // parenthesised under `and`.
        if (LPair.JsonValue.TryGetValue<Integer>('', LVal)) and (LVal > 0) then
        begin
          Result := LVal;
          Exit;
        end;
      end;
  finally
    LRoot.Free;
  end;
end;

class function TAgentCapabilityProbe.ModelSupportsVision(
  const ABaseUrl, AModel: string): Boolean;
var
  LStatus: Integer;
  LBody, LError: string;
begin
  Result := False;
  if TAefosHttp.TryPostText(OllamaShowEndpoint(ABaseUrl),
    OllamaShowRequest(AModel), CContentTypeJson, CShowTimeoutMs,
    LStatus, LBody, LError) and (LStatus = 200) then
    Result := OllamaCapabilitiesHaveVision(OllamaParseCapabilities(LBody));
  // best-effort: an unreachable probe (Result stays False) reads as "no vision".
end;

class function TAgentCapabilityProbe.ProbeContextWindow(
  const ABaseUrl, AModel: string): Integer;
var
  LStatus: Integer;
  LBody, LError: string;
begin
  Result := 0;
  if TAefosHttp.TryPostText(OllamaShowEndpoint(ABaseUrl),
    OllamaShowRequest(AModel), CContentTypeJson, CShowTimeoutMs,
    LStatus, LBody, LError) and (LStatus = 200) then
    Result := TAgentCapabilityProbe.ParseContextWindow(LBody);
  // best-effort: any failure leaves 0 (= unknown window).
end;

class function TAgentCapabilityProbe.ModelSupportsTools(
  const ABaseUrl, AModel: string;
  out AReached: Boolean; out AError: string): Boolean;
var
  LStatus: Integer;
  LBody: string;
begin
  Result := False;
  AReached := False;
  AError := '';
  // Transport success = the endpoint answered (AReached); a non-2xx is still a
  // reply, so AReached is True and AError carries the status. A transport
  // failure leaves AReached False with TryPostText's error in AError.
  if TAefosHttp.TryPostText(OllamaShowEndpoint(ABaseUrl),
    OllamaShowRequest(AModel), CContentTypeJson, CShowTimeoutMs,
    LStatus, LBody, AError) then
  begin
    AReached := True;
    if LStatus = 200 then
      Result := OllamaCapabilitiesHaveTools(OllamaParseCapabilities(LBody))
    else
      AError := Format('HTTP %d from /api/show', [LStatus]);
  end;
end;

end.
