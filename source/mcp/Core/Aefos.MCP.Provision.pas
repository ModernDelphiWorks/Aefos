unit Aefos.MCP.Provision;

{
  Self-provisioning of the MCP wiring so the plugin works WITHOUT the installer
  (a dev may just drop the BPLs into RAD Studio).

  Lives in the shared runtime Core (requires rtl only) so BOTH host BPLs — Chat
  and Terminal — provision from a SINGLE embedded source, with no duplication.
  A Chat-only or a Terminal-only install both get the bridge.

  Two artefacts the installer used to ship are produced here instead:
    1. mcp-bridge.ps1 — the stdio<->named-pipe bridge Claude Code runs. It is
       embedded as RCDATA 'AEFOS_MCP_BRIDGE' (single source: the repo-root
       mcp-bridge.ps1 is compiled into Aefos.MCP.Provision.res) and written to a
       STABLE per-user path: %APPDATA%\Aefos\mcp-bridge.ps1. A stable path
       survives the project/repo folder being renamed (the old installer baked
       an absolute repo path into .mcp.json, which broke on rename).
    2. <project>\.mcp.json — points the 'aefos' MCP server at that stable bridge
       with the given -Session (the Chat host uses 'plugin', the Terminal host
       'terminal'). Merged, never clobbered: other servers are kept, and the
       installed addons' servers (~/.aefos/addons/mcp-servers.json) are merged
       in so a raw CLI run in the project folder sees them too (FASE 0 leg).

  Pure RTL + file I/O + resource — no ToolsAPI, no Vcl (C-2: Core requires rtl
  ONLY). The caller supplies the active project directory and the session name.
}

interface

type
  // Self-provisioning of the MCP wiring as a sealed static namespace (never
  // instantiated). Pure RTL + file I/O + resource — no ToolsAPI, no Vcl.
  TMCPProvision = class sealed
  public
    { %APPDATA%\Aefos — the stable per-user Aefos data dir (same base as the logs). }
    class function AppDataDir: string; static;

    { %APPDATA%\Aefos\mcp-bridge.ps1 — the stable bridge location. }
    class function BridgePath: string; static;

    { Writes the embedded bridge to BridgePath when missing or out of date.
      Never raises into the caller (a locked/again file is logged, not fatal). }
    class procedure EnsureBridge; static;

    { %USERPROFILE%\.aefos — the per-user CONTENT root (commands/, skills/, addons/).
      Distinct from AppDataDir (%APPDATA%\Aefos = machine runtime). }
    class function UserDir: string; static;

    { %USERPROFILE%\.aefos\addons\mcp-servers.json — the aggregate mcpServers doc
      the `aefos install <slug>` CLI rewrites on every MCP/tool addon install or
      removal (same file as cli\Aefos.Addons.Paths.McpAggregatePath; recomputed
      here so the design-time BPLs never depend on the separate CLI project). }
    class function AddonAggregatePath: string; static;

    { The addon aggregate's content, or '' when absent/locked/unreadable. '' means
      "contributes no servers" to a merge, so a missing or half-written aggregate
      degrades gracefully and never breaks a provision nor a dispatch. }
    class function LoadAddonAggregate: string; static;

    { Ensures <AProjectDir>\.mcp.json declares the 'aefos' server pointing at the
      stable bridge with -Session ASession. Existing servers are preserved (merge),
      and the installed addons' servers (the aggregate above) are merged in — the
      raw-terminal CLI reads THIS file, not the global aefos-mcp.json, so without
      this leg an `aefos install desktop` never reaches a CLI run by hand in the
      project folder (live-test 2026-07-13). An entry already in the file wins a
      name collision; an uninstalled addon's entry is NOT removed here (the file
      is merge-never-clobber). Also ensures the bridge itself exists. Returns True
      on success. }
    class function EnsureProjectConfig(const AProjectDir, ASession: string): Boolean; static;

    { Writes the GLOBAL aefos MCP config at %APPDATA%\Aefos\aefos-mcp.json and
      returns its path. It always declares the built-in 'aefos' server (bridge ->
      named pipe, -Session ASession) and merges in any servers found under the
      mcpServers key of AExtraServersJson (the user's extra servers; '' or malformed
      = none; a duplicate 'aefos' there is ignored). This is the single MCP source
      every CLI is pointed at, so the chat no longer depends on a per-project
      .mcp.json. Also ensures the bridge itself exists. }
    class function EnsureGlobalConfig(const ASession, AExtraServersJson: string): string; static;

    { Merges the built-in 'aefos' server (bridge -> named pipe, ASession) into the
      Gemini global settings at %USERPROFILE%\.gemini\settings.json (or
      $GEMINI_HOME\settings.json), preserving every other key and MCP server — only
      the 'aefos' entry under mcpServers is (re)written. Gemini has no MCP flag; it
      reads this file. Also ensures the bridge + the ~/.gemini directory exist.
      Returns the file path. }
    class function EnsureGeminiConfig(const ASession: string): string; static;

    { The built-in MCP server KEY this edition writes into every config it
      generates ('aefos-delphi'). Exposed so the chat executor sets
      TProviderDispatchContext.McpServerName to the SAME name the config declares,
      keeping the driver's dynamic --allowedTools mcp__<name> in lock-step with the
      served host (single source of truth -- no drift). }
    class function BuiltInServerKey: string; static;
  end;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.JSON,
  Aefos.MCP.ServerMerge,
  Aefos.Compat.JsonFormat;

{$R 'Aefos.MCP.Provision.res'}

const
  BRIDGE_RES_NAME = 'AEFOS_MCP_BRIDGE';
  BRIDGE_FILE     = 'mcp-bridge.ps1';
  // The RAD Studio (Delphi) edition's built-in MCP server key. Renamed from the
  // legacy bare 'aefos' (owner decision 2026-07-18): a client with BOTH the Delphi
  // AND the Lazarus IDE open must see two DISTINCT, addressable hosts -- 'aefos-delphi'
  // here and 'aefos-lazarus' from the Lazarus edition -- so a tool (AddComponent,
  // EditUnit, ...) routes to the IDE the user meant. The config is regenerated on
  // every dispatch, so an updated plugin re-writes this name with no user action.
  SERVER_KEY      = 'aefos-delphi';
  // Windows PowerShell (5.1) is present on every Windows box; the bridge
  // declares #Requires -Version 5.1, so 'powershell' works without a separate
  // PowerShell 7 (pwsh) install — the safest default for a no-installer setup.
  PS_COMMAND      = 'powershell';

class function TMCPProvision.AppDataDir: string;
begin
  Result := TPath.Combine(GetEnvironmentVariable('APPDATA'), 'Aefos');
end;

class function TMCPProvision.BuiltInServerKey: string;
begin
  Result := SERVER_KEY;
end;

class function TMCPProvision.BridgePath: string;
begin
  Result := TPath.Combine(AppDataDir, BRIDGE_FILE);
end;

// The embedded bridge bytes, or an empty array when the resource is missing.
function _BridgeResourceBytes: TBytes;
var
  LStream: TResourceStream;
begin
  SetLength(Result, 0);
  if FindResource(HInstance, BRIDGE_RES_NAME, RT_RCDATA) = 0 then
    Exit;
  LStream := TResourceStream.Create(HInstance, BRIDGE_RES_NAME, RT_RCDATA);
  try
    SetLength(Result, LStream.Size);
    if LStream.Size > 0 then
      LStream.ReadBuffer(Result[0], LStream.Size);
  finally
    LStream.Free;
  end;
end;

function _SameBytes(const ALeft, ARight: TBytes): Boolean;
var
  LIndex: Integer;
begin
  Result := Length(ALeft) = Length(ARight);
  if not Result then
    Exit;
  for LIndex := 0 to High(ALeft) do
    if ALeft[LIndex] <> ARight[LIndex] then
      Exit(False);
end;

class procedure TMCPProvision.EnsureBridge;
var
  LDir, LPath: string;
  LBytes: TBytes;
begin
  try
    LBytes := _BridgeResourceBytes;
    if Length(LBytes) = 0 then
      Exit;
    LDir := AppDataDir;
    if not TDirectory.Exists(LDir) then
      TDirectory.CreateDirectory(LDir);
    LPath := BridgePath;
    // Write only when absent or stale so an open handle (Claude Code mid-run)
    // is not disturbed on every load.
    if (not TFile.Exists(LPath)) or
       (not _SameBytes(TFile.ReadAllBytes(LPath), LBytes)) then
      TFile.WriteAllBytes(LPath, LBytes);
  except
    on E: Exception do
      OutputDebugString(PChar('[Aefos] EnsureBridge: ' + E.Message));
  end;
end;

class function TMCPProvision.UserDir: string;
begin
  Result := TPath.Combine(GetEnvironmentVariable('USERPROFILE'), '.aefos');
end;

// The 'aefos' server object:
//   powershell -ExecutionPolicy Bypass -NonInteractive -File <bridge> -Session <s>.
// Bypass is REQUIRED: the default client-Windows policy is Restricted, which
// refuses `-File` scripts outright — the CLI then reports the MCP handshake as
// "connection closed" (field report 2026-07-08). Dev machines rarely see it
// because their policy is already RemoteSigned/Unrestricted.
function _BuildServerObject(const ASession: string): TJSONObject;
var
  LArgs: TJSONArray;
begin
  LArgs := TJSONArray.Create;
  LArgs.Add('-ExecutionPolicy');
  LArgs.Add('Bypass');
  LArgs.Add('-NonInteractive');
  LArgs.Add('-File');
  LArgs.Add(TMCPProvision.BridgePath);
  LArgs.Add('-Session');
  LArgs.Add(ASession);
  Result := TJSONObject.Create;
  Result.AddPair('command', PS_COMMAND);
  Result.AddPair('args', LArgs);
end;

class function TMCPProvision.AddonAggregatePath: string;
begin
  Result := TPath.Combine(TPath.Combine(UserDir, 'addons'),
    'mcp-servers.json');
end;

class function TMCPProvision.LoadAddonAggregate: string;
var
  LPath: string;
begin
  Result := '';
  LPath := AddonAggregatePath;
  if not TFile.Exists(LPath) then
    Exit;
  try
    Result := Trim(TFile.ReadAllText(LPath, TEncoding.UTF8));
  except
    // Locked/garbled aggregate => contributes nothing; never breaks a caller.
    Result := '';
  end;
end;

// Loads <AProjectDir>\.mcp.json as an object (new empty one when absent or
// malformed). Caller owns the result.
function _LoadOrNewRoot(const APath: string): TJSONObject;
var
  LRaw: string;
  LVal: TJSONValue;
begin
  Result := nil;
  if TFile.Exists(APath) then
  begin
    LRaw := TFile.ReadAllText(APath, TEncoding.UTF8);
    LVal := TJSONObject.ParseJSONValue(LRaw);
    if LVal is TJSONObject then
      Result := TJSONObject(LVal)
    else
      LVal.Free;
  end;
  if Result = nil then
    Result := TJSONObject.Create;
end;

class function TMCPProvision.EnsureProjectConfig(const AProjectDir, ASession: string): Boolean;
var
  LPath, LRaw: string;
  LVal: TJSONValue;
  LRoot, LServers: TJSONObject;
  LServersVal: TJSONValue;
begin
  Result := False;
  if Trim(AProjectDir) = '' then
    Exit;
  EnsureBridge;
  LPath := TPath.Combine(AProjectDir, '.mcp.json');
  // Merge the installed addons' servers into the doc FIRST (pure; exercised by
  // headlessly). Entries already in the file — the user's — win a collision,
  // and the 'aefos' pair is (re)written below, so ours always wins even when
  // an addon ships one under that name.
  LRaw := '';
  if TFile.Exists(LPath) then
    try
      LRaw := TFile.ReadAllText(LPath, TEncoding.UTF8);
    except
      LRaw := '';  // unreadable => provision a fresh doc
    end;
  LVal := TJSONObject.ParseJSONValue(
    TMCPServerMerge.MergeAddonServersIntoDoc(LRaw, LoadAddonAggregate));
  if LVal is TJSONObject then
    LRoot := TJSONObject(LVal)
  else
  begin
    // Unreachable (the merge always yields an object) — stay defensive.
    LVal.Free;
    LRoot := TJSONObject.Create;
  end;
  try
    // mcpServers object (create or replace a non-object value).
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
    // Replace only our own entry; other servers are left untouched.
    LServers.RemovePair(SERVER_KEY).Free;
    LServers.AddPair(SERVER_KEY, _BuildServerObject(ASession));
    // UTF-8 without BOM (some JSON readers choke on a BOM).
    TFile.WriteAllBytes(LPath, TEncoding.UTF8.GetBytes(LRoot.Format(2)));
    Result := True;
  finally
    LRoot.Free;
  end;
end;

class function TMCPProvision.EnsureGlobalConfig(const ASession, AExtraServersJson: string): string;
var
  LRoot, LServers: TJSONObject;
  LExtraVal, LExtraServersVal: TJSONValue;
  LPair: TJSONPair;
begin
  EnsureBridge;
  if not TDirectory.Exists(AppDataDir) then
    TDirectory.CreateDirectory(AppDataDir);
  Result := TPath.Combine(AppDataDir, 'aefos-mcp.json');
  LRoot := TJSONObject.Create;
  try
    LServers := TJSONObject.Create;
    LRoot.AddPair('mcpServers', LServers);
    // The built-in server is always present and wins over any same-named extra.
    LServers.AddPair(SERVER_KEY, _BuildServerObject(ASession));
    // Merge the user's extra servers (the "MCP Servers" modal) so every CLI sees
    // one combined config. A malformed/empty doc simply contributes nothing.
    if Trim(AExtraServersJson) <> '' then
    begin
      LExtraVal := TJSONObject.ParseJSONValue(AExtraServersJson);
      try
        if LExtraVal is TJSONObject then
        begin
          LExtraServersVal := TJSONObject(LExtraVal).GetValue('mcpServers');
          if LExtraServersVal is TJSONObject then
            for LPair in TJSONObject(LExtraServersVal) do
              if not SameText(LPair.JsonString.Value, SERVER_KEY) then
                LServers.AddPair(LPair.JsonString.Value,
                  LPair.JsonValue.Clone as TJSONValue);
        end;
      finally
        LExtraVal.Free;
      end;
    end;
    // UTF-8 without BOM (some JSON readers choke on a BOM).
    TFile.WriteAllBytes(Result, TEncoding.UTF8.GetBytes(LRoot.Format(2)));
  finally
    LRoot.Free;
  end;
end;

class function TMCPProvision.EnsureGeminiConfig(const ASession: string): string;
var
  LBase, LDir: string;
  LRoot, LServers: TJSONObject;
  LServersVal: TJSONValue;
begin
  EnsureBridge;
  LBase := GetEnvironmentVariable('GEMINI_HOME');
  if LBase = '' then
    LBase := TPath.Combine(GetEnvironmentVariable('USERPROFILE'), '.gemini');
  LDir := LBase;
  if not TDirectory.Exists(LDir) then
    TDirectory.CreateDirectory(LDir);
  Result := TPath.Combine(LDir, 'settings.json');
  LRoot := _LoadOrNewRoot(Result);  // preserves every existing setting
  try
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
    // Replace only our own entry; the user's other servers/settings are kept.
    LServers.RemovePair(SERVER_KEY).Free;
    LServers.AddPair(SERVER_KEY, _BuildServerObject(ASession));
    TFile.WriteAllBytes(Result, TEncoding.UTF8.GetBytes(LRoot.Format(2)));
  finally
    LRoot.Free;
  end;
end;

end.
