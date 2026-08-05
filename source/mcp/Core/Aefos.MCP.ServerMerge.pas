unit Aefos.MCP.ServerMerge;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

// Pure union of two Claude-Code-style MCP config documents (FASE 0, Desktop MCP).
//
// The plugin points every CLI at ONE global config
// (%APPDATA%\Aefos\aefos-mcp.json, written by
// Aefos.MCP.Provision.TMCPProvision.EnsureGlobalConfig). Two independent sources contribute
// the servers that go into it:
//
//   1. The user's hand-written extras -- the chat "MCP Servers" modal, stored at
//      %APPDATA%\Aefos\mcp-servers.json.
//   2. The addon aggregate -- %USERPROFILE%\.aefos\addons\mcp-servers.json, which
//      the `aefos install <slug>` CLI rewrites every time an MCP/tool addon is
//      installed or removed. WITHOUT merging this in, no installed MCP addon
//      (Desktop, Janus-DB, ...) ever reaches the agent.
//
// Each argument is a JSON string shaped {"mcpServers":{<name>:{...}, ...}} (any
// other top-level key is ignored). MergeServers returns a fresh doc
// {"mcpServers":{<union>}} holding every server from both sides.
//
// Precedence on a name collision: the USER wins. A human who hand-writes a server
// under a name an addon also uses is deliberately pinning/patching that addon's
// connection, so the manual entry must override the addon-provided one -- never
// the reverse. (To flip this, swap the two _Absorb calls at the single
// implementation site below.)
//
// Degrades gracefully -- this is decision-grade code that must never break a chat
// dispatch: a nil/empty/invalid/non-object argument, or one lacking the
// mcpServers object, simply contributes nothing. It never raises. When neither
// side contributes a server the result is the canonical empty doc
// {"mcpServers":{}}.
//
// Pure RTL (SysUtils + the Aefos.Compat.Json shim) -- no ToolsAPI, no Vcl/FMX --
// so it lives in Aefos.MCP.Core and is exercised headless (Delphi)
// AND compiles under FPC 3.2.2, where it is the single-source merge the Lazarus
// edition's Aefos.Lazarus.McpAddonMerge reuses.

interface

type
  // Pure union of Claude-Code-style MCP config docs, as a sealed static namespace
  // (never instantiated). See the unit header for the shape + graceful-degradation
  // contract. Nothing here ever raises.
  TMCPServerMerge = class sealed
  public
    { Union of two MCP config docs. AUserJson wins on a name collision. See the unit
      header for the shape and the graceful-degradation contract. Never raises. }
    class function MergeServers(const AUserJson, AAddonJson: string): string; static;

    { Merges the addon aggregate's servers INTO an existing full config doc (the
      per-project .mcp.json), preserving every other top-level key of ADocJson.
      A server already present in the doc wins over the addon's (same user-wins
      rule as MergeServers). A malformed/empty/non-object ADocJson counts as the
      empty doc; a malformed/empty AAddonJson contributes nothing. The result is
      always an object carrying an mcpServers object. Never raises.

      This is the raw-terminal leg of the FASE 0 merge: the chat points its CLI at
      the global aefos-mcp.json (rebuilt with MergeServers on every dispatch),
      but a CLI run by hand in the project folder reads the project .mcp.json --
      live-test 2026-07-13 proved an installed addon never reached it. }
    class function MergeAddonServersIntoDoc(const ADocJson, AAddonJson: string): string; static;

    { The server-name keys under the mcpServers object of any MCP config doc, in
      document order. Used to pre-authorize each server's tools (e.g. Claude gates
      mcp__<name> behind --allowedTools). Pure; never raises; [] on anything that is
      not an object carrying an mcpServers object. }
    class function ServerKeysOf(const AJson: string): TArray<string>; static;
  end;

implementation

uses
  // De-dotted for FPC (System.SysUtils resolves via unit scope on Delphi); the
  // JSON types come from the shim so this pure unit is single-sourced across
  // Delphi (aliases onto System.JSON) and FPC 3.2.2 (fpjson wrappers).
  SysUtils,
  Aefos.Compat.Json;

// Returns the mcpServers object owned by APc (the parsed root), or nil when the
// root is not an object or has no mcpServers object. The returned object is still
// owned by APc — do NOT free it separately.
function _ServersObjectOf(const ARoot: TJSONValue): TJSONObject;
var
  LServersVal: TJSONValue;
begin
  Result := nil;
  if not (ARoot is TJSONObject) then
    Exit;
  LServersVal := TJSONObject(ARoot).GetValue('mcpServers');
  if LServersVal is TJSONObject then
    Result := TJSONObject(LServersVal);
end;

class function TMCPServerMerge.MergeServers(const AUserJson, AAddonJson: string): string;
var
  LResult, LServers: TJSONObject;

  // Copies every server from AJson's mcpServers into LServers. When AOverwrite is
  // True an existing key is replaced (the caller's value wins); when False an
  // existing key is left alone (the already-present value wins).
  procedure _Absorb(const AJson: string; const AOverwrite: Boolean);
  var
    LRoot: TJSONValue;
    LSource: TJSONObject;
    LPair: TJSONPair;
    LKey: string;
  begin
    if Trim(AJson) = '' then
      Exit;
    LRoot := TJSONObject.ParseJSONValue(AJson);  // nil on malformed input
    try
      LSource := _ServersObjectOf(LRoot);
      if LSource = nil then
        Exit;
      for LPair in LSource do
      begin
        LKey := LPair.JsonString.Value;
        if LServers.GetValue(LKey) <> nil then
        begin
          if not AOverwrite then
            Continue;
          LServers.RemovePair(LKey).Free;
        end;
        LServers.AddPair(LKey, LPair.JsonValue.Clone as TJSONValue);
      end;
    finally
      LRoot.Free;  // nil-safe
    end;
  end;

begin
  LResult := TJSONObject.Create;
  try
    LServers := TJSONObject.Create;
    LResult.AddPair('mcpServers', LServers);
    // Seed with the addon servers, then overlay the user's — the user OVERWRITES
    // on a name collision (AOverwrite=True), so the human's config wins.
    _Absorb(AAddonJson, False);
    _Absorb(AUserJson, True);
    Result := LResult.ToJSON;  // compact; TMCPProvision.EnsureGlobalConfig re-parses it
  finally
    LResult.Free;
  end;
end;

class function TMCPServerMerge.MergeAddonServersIntoDoc(const ADocJson, AAddonJson: string): string;
var
  LDocVal, LAddonVal, LServersVal: TJSONValue;
  LRoot, LServers, LSource: TJSONObject;
  LPair: TJSONPair;
begin
  // The doc root: the caller's parsed object, or a fresh empty one when the
  // file was absent/malformed/non-object (merge-never-clobber still holds --
  // an unreadable doc yields a valid one instead of propagating the damage).
  LRoot := nil;
  if Trim(ADocJson) <> '' then
  begin
    LDocVal := TJSONObject.ParseJSONValue(ADocJson);  // nil on malformed input
    if LDocVal is TJSONObject then
      LRoot := TJSONObject(LDocVal)
    else
      LDocVal.Free;
  end;
  if LRoot = nil then
    LRoot := TJSONObject.Create;
  try
    // mcpServers object (create it, or replace a non-object value).
    LServersVal := LRoot.GetValue('mcpServers');
    if LServersVal is TJSONObject then
      LServers := TJSONObject(LServersVal)
    else
    begin
      if LServersVal <> nil then
        LRoot.RemovePair('mcpServers').Free;
      LServers := TJSONObject.Create;
      LRoot.AddPair('mcpServers', LServers);
    end;
    // Absorb the addon servers WITHOUT overwriting: an entry already in the
    // doc is the user's (or a previous run's) and wins the collision.
    if Trim(AAddonJson) <> '' then
    begin
      LAddonVal := TJSONObject.ParseJSONValue(AAddonJson);  // nil on malformed
      try
        LSource := _ServersObjectOf(LAddonVal);
        if LSource <> nil then
          for LPair in LSource do
            if LServers.GetValue(LPair.JsonString.Value) = nil then
              LServers.AddPair(LPair.JsonString.Value,
                LPair.JsonValue.Clone as TJSONValue);
      finally
        LAddonVal.Free;  // nil-safe
      end;
    end;
    Result := LRoot.ToJSON;  // compact; the caller re-formats on write
  finally
    LRoot.Free;
  end;
end;

class function TMCPServerMerge.ServerKeysOf(const AJson: string): TArray<string>;
var
  LRoot: TJSONValue;
  LServers: TJSONObject;
  LPair: TJSONPair;
  LList: TArray<string>;
begin
  Result := nil;
  LList := nil;
  if Trim(AJson) = '' then
    Exit;
  LRoot := TJSONObject.ParseJSONValue(AJson);  // nil on malformed input
  try
    LServers := _ServersObjectOf(LRoot);
    if LServers <> nil then
      for LPair in LServers do
        LList := LList + [LPair.JsonString.Value];
  finally
    LRoot.Free;  // nil-safe
  end;
  Result := LList;
end;

end.
