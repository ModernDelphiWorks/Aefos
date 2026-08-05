unit Aefos.Lazarus.McpAddonMerge;

{ Aefos AI - Lazarus edition: builds the ONE global MCP config the external CLI
  agent is pointed at, so an installed MCP addon (Desktop, Janus-DB, ...) reaches
  the Lazarus agent EXACTLY as it does the RAD Studio one.

  This is the Lazarus twin of the Delphi executor's FASE 0 merge
  (source\chat\Core\Aefos.OTA.Chat.Core.CommandExecutor.pas ~625-645):

    Delphi                                   Lazarus (here)
    ------                                   --------------
    TMCPServerMerge.MergeServers(            TMCPServerMerge.MergeServers(     <- SAME pure unit
      TChatGlobalSettings.LoadMcpConfig,       _LoadUserServers,              <- SAME file
      TMCPProvision.LoadAddonAggregate)        _LoadAddonAggregate)           <- SAME file
    TMCPProvision.EnsureGlobalConfig(        BuildMergedConfig writes         <- SAME file, no BOM
      'plugin', merged)                        aefos-mcp.json itself
    TMCPServerMerge.ServerKeysOf(merged)     TMCPServerMerge.ServerKeysOf(merged)

  Why a NEW unit rather than FPC-guarding TMCPProvision: that unit reaches for an
  embedded RCDATA resource (a linked $R resource) to ship the bridge -- Delphi-only
  -- so only the MINIMUM (the aggregate loader + the
  global-config writer) is re-expressed here over the Compat shims. The collision
  RULE is NOT reimplemented: it is reused from the FPC-guarded pure
  Aefos.MCP.ServerMerge, so user-wins-over-addon is single-sourced with Delphi.

  ONE BRAIN (owner rule 2026-07-17): every path is the SAME one the Delphi edition
  reads/writes under %APPDATA%\Aefos and %USERPROFILE%\.aefos -- what one edition
  writes, the other sees:
    - user extras  = %APPDATA%\Aefos\mcp-servers.json   (the chat "MCP Servers" modal)
    - addon aggr.  = %USERPROFILE%\.aefos\addons\mcp-servers.json  (`aefos install`)
    - global cfg   = %APPDATA%\Aefos\aefos-mcp.json      (generated; every CLI points here)
    - bridge       = %APPDATA%\Aefos\mcp-bridge.ps1       (stdio<->named-pipe shim)
  The aefos-mcp.json is a DERIVED file rebuilt on every dispatch, so the two
  editions never fight over it (whoever dispatches last owns it, pointed at THAT
  edition's live host pipe). Formatting is fpjson-spaced on FPC vs System.JSON on
  Delphi -- irrelevant for a regenerated file; the persistent user files above are
  only READ here, never rewritten, so they stay byte-identical across editions.

  The built-in 'aefos-lazarus' server (DISTINCT from the Delphi edition's
  'aefos-delphi', owner decision 2026-07-18, so both IDEs stay addressable when
  open together) points the bridge at the Lazarus MCP host pipe via -Session <s>,
  where <s> is derived from the host's pipe name (MCP_PIPE_PREFIX + 'lazarus' ->
  session 'lazarus'), the byte-for-byte shape of the Delphi server, only the
  session and the server KEY differ. The bridge itself is
  provisioned to the shared path by the Lazarus installer (the Delphi edition
  additionally self-heals it at BPL load from an embedded resource -- a slice not
  ported here; see the report).

  Pure Compat shims (Aefos.Compat.IO + Aefos.Compat.Json) + the pure
  Aefos.MCP.ServerMerge -- no LCL, no ToolsAPI -- so it is exercised headless by
  a headless probe. All literals ASCII, so the file needs no BOM. }

{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

interface

type
  { The wiring a dispatch needs, mirroring the fields the Delphi executor fills on
    TProviderDispatchContext. The ChatController copies these across in agent mode
    (see BuildMergedConfig). }
  TAefosLazMcpWiring = record
    ConfigPath: string;           // -> ACtx.McpConfigPath (aefos-mcp.json path)
    BridgePath: string;           // -> ACtx.McpBridgePath (Codex -c override)
    Session: string;              // -> ACtx.McpSession    (named-pipe session)
    ServerName: string;           // -> ACtx.McpServerName (the built-in host's key:
                                  // 'aefos-lazarus', distinct from the Delphi
                                  // edition's 'aefos', so a client with both IDEs
                                  // open addresses the right host)
    ServerNames: TArray<string>;  // -> ACtx.ExtraMcpNames (extras, pre-authorized)
  end;

  { Builds + writes the global MCP config for the Lazarus chat agent, as a sealed
    static namespace (never instantiated). Never raises out: any load fault
    degrades to "contributes nothing", exactly like the Delphi loaders. }
  TAefosLazMcpAddonMerge = class sealed
  public
    { %APPDATA%\Aefos -- the shared per-user data dir (= TMCPProvision.AppDataDir /
      TChatGlobalSettings' Aefos root on the Delphi side). }
    class function AppDataDir: string; static;
    { %USERPROFILE%\.aefos -- the shared content root (= TMCPProvision.UserDir). }
    class function UserDir: string; static;
    { %APPDATA%\Aefos\mcp-bridge.ps1 -- the shared bridge (= TMCPProvision.BridgePath). }
    class function BridgePath: string; static;
    { %APPDATA%\Aefos\mcp-servers.json -- the user's extra servers
      (= TChatGlobalSettings.McpConfigPath). }
    class function UserServersPath: string; static;
    { %USERPROFILE%\.aefos\addons\mcp-servers.json -- the installed-addon aggregate
      (= TMCPProvision.AddonAggregatePath). }
    class function AddonAggregatePath: string; static;
    { %APPDATA%\Aefos\aefos-mcp.json -- the generated global config every CLI is
      pointed at (= TMCPProvision.EnsureGlobalConfig's output path). }
    class function GlobalConfigPath: string; static;

    { The Lazarus edition's built-in MCP server KEY ('aefos-lazarus'), DISTINCT
      from the Delphi 'aefos-delphi', so both IDEs stay addressable when open
      together. Exposed so the controller can stamp
      TProviderDispatchContext.McpServerName with it (single source of truth) even
      on the degraded plain-chat path, keeping the driver's dynamic MCP flags in
      this edition's namespace. }
    class function BuiltInServerKey: string; static;

    { THE ENTRY POINT. Merges the user's extra servers with the installed-addon
      aggregate (user wins a name collision), injects the built-in 'aefos' server
      pointing the bridge at APipeName's session, writes the global config
      (UTF-8, no BOM, byte-shape identical to the Delphi executor's), and returns
      the wiring. APipeName is the Lazarus MCP host's pipe (e.g.
      \\.\pipe\aefos-mcp-lazarus); the session is derived from it. Never raises. }
    class function BuildMergedConfig(const APipeName: string): TAefosLazMcpWiring; static;

    { Gemini CLI has NO MCP flag: the driver only emits
      --allowed-mcp-server-names aefos (Aefos.Provider.Gemini), which resolves ONLY
      if ~/.gemini/settings.json already declares an 'aefos' MCP server. This writes
      it there, pointed at the Lazarus host's bridge/session -- the exact twin of
      TMCPProvision.EnsureGeminiConfig (Aefos.MCP.Provision:411-444, Delphi-only,
      not portable because it self-heals the bridge from a linked resource). It
      MERGES: every existing setting and every other mcpServers entry is preserved;
      only our own 'aefos' key is (re)written. GEMINI_HOME overrides the home, else
      %USERPROFILE%\.gemini. Returns the settings.json path, or '' if it could not
      be written (the caller then keeps the honest "no tools" notice). Never raises. }
    class function EnsureGeminiConfig(const ASession: string): string; static;
  end;

implementation

uses
  SysUtils,
  Aefos.Compat.IO,
  Aefos.Compat.Json,
  Aefos.MCP.Types,      // MCP_PIPE_PREFIX
  Aefos.MCP.ServerMerge;

const
  // The DELPHI edition's built-in host key (only referenced here to EXCLUDE it
  // from an extras collision; the Lazarus config never writes it).
  SERVER_KEY   = 'aefos';
  // The Lazarus edition's built-in host key -- DISTINCT from the Delphi 'aefos'
  // so a client (Claude/Codex/Gemini) with BOTH IDEs open sees two addressable
  // MCP hosts and routes a tool (AddComponent, EditUnit, ...) to the IDE the user
  // meant (owner rule 2026-07-18). A hyphen is a valid key in JSON, in a Codex
  // TOML bare key, and in a Claude mcp__<name> / Gemini --allowed-mcp-server-names
  // token. The pipe SESSION stays 'lazarus' (the host's transport name); only the
  // client-facing SERVER KEY differs.
  LAZ_SERVER_KEY = 'aefos-lazarus';
  // Windows PowerShell (5.1) is on every box; -ExecutionPolicy Bypass is REQUIRED
  // (the default client policy is Restricted and refuses -File). Byte-identical to
  // TMCPProvision._BuildServerObject.
  PS_COMMAND   = 'powershell';
  BRIDGE_FILE  = 'mcp-bridge.ps1';
  USER_SERVERS = 'mcp-servers.json';
  GLOBAL_CFG   = 'aefos-mcp.json';
  AGGREGATE    = 'mcp-servers.json';
  ROOT_DIR     = 'Aefos';
  USER_ROOT    = '.aefos';
  ADDONS_DIR   = 'addons';
  FALLBACK_SESSION = 'lazarus';
  GEMINI_DIR   = '.gemini';
  GEMINI_FILE  = 'settings.json';
  MCP_SERVERS_KEY = 'mcpServers';

class function TAefosLazMcpAddonMerge.AppDataDir: string;
begin
  Result := TPath.Combine(TPath.GetHomePath, ROOT_DIR);
end;

class function TAefosLazMcpAddonMerge.UserDir: string;
begin
  Result := TPath.Combine(SysUtils.GetEnvironmentVariable('USERPROFILE'), USER_ROOT);
end;

class function TAefosLazMcpAddonMerge.BridgePath: string;
begin
  Result := TPath.Combine(AppDataDir, BRIDGE_FILE);
end;

class function TAefosLazMcpAddonMerge.UserServersPath: string;
begin
  Result := TPath.Combine(AppDataDir, USER_SERVERS);
end;

class function TAefosLazMcpAddonMerge.AddonAggregatePath: string;
begin
  Result := TPath.Combine(TPath.Combine(UserDir, ADDONS_DIR), AGGREGATE);
end;

class function TAefosLazMcpAddonMerge.GlobalConfigPath: string;
begin
  Result := TPath.Combine(AppDataDir, GLOBAL_CFG);
end;

class function TAefosLazMcpAddonMerge.BuiltInServerKey: string;
begin
  Result := LAZ_SERVER_KEY;
end;

// ASCII case-insensitive equality. SysUtils.SameText/CompareText are AnsiString-
// typed in the FPC RTL, so under {$mode delphiunicode} they narrow a UnicodeString
// argument (WorkspaceFacade documents the same trap); LazUTF8's folds would drag
// in an LCL dependency this headless unit must not carry. Server names are ASCII,
// so a plain A..Z fold is exact and enough.
function _AsciiSameText(const ALeft, ARight: string): Boolean;
var
  LIndex: Integer;
  LChL, LChR: WideChar;
begin
  Result := Length(ALeft) = Length(ARight);
  if not Result then
    Exit;
  for LIndex := 1 to Length(ALeft) do
  begin
    LChL := ALeft[LIndex];
    LChR := ARight[LIndex];
    if (LChL >= 'A') and (LChL <= 'Z') then
      LChL := WideChar(Ord(LChL) + 32);
    if (LChR >= 'A') and (LChR <= 'Z') then
      LChR := WideChar(Ord(LChR) + 32);
    if LChL <> LChR then
      Exit(False);
  end;
end;

// The named-pipe session encoded in APipeName (\\.\pipe\aefos-mcp-<session>).
// Falls back to 'lazarus' for an empty/unexpected name so the config is always
// pointed at the host this edition serves.
function _SessionFromPipe(const APipeName: string): string;
begin
  if (APipeName <> '') and (Pos(MCP_PIPE_PREFIX, APipeName) = 1) then
    Result := Copy(APipeName, Length(MCP_PIPE_PREFIX) + 1, MaxInt)
  else
    Result := FALLBACK_SESSION;
  if Trim(Result) = '' then
    Result := FALLBACK_SESSION;
end;

// Reads AFilePath as UTF-8, or '' when absent/locked/unreadable. '' means
// "contributes nothing" to a merge (TMCPServerMerge treats it as empty), so a
// missing or half-written file degrades gracefully -- never breaks a dispatch.
function _LoadTextOrEmpty(const AFilePath: string): string;
begin
  Result := '';
  if not TFile.Exists(AFilePath) then
    Exit;
  try
    Result := Trim(TFile.ReadAllText(AFilePath, TEncoding.UTF8));
  except
    Result := '';
  end;
end;

// The 'aefos' server object, byte-shape identical to
// TMCPProvision._BuildServerObject:
//   powershell -ExecutionPolicy Bypass -NonInteractive -File <bridge> -Session <s>
function _BuildAefosServer(const ABridgePath, ASession: string): TJSONObject;
var
  LArgs: TJSONArray;
begin
  LArgs := TJSONArray.Create;
  LArgs.Add('-ExecutionPolicy');
  LArgs.Add('Bypass');
  LArgs.Add('-NonInteractive');
  LArgs.Add('-File');
  LArgs.Add(ABridgePath);
  LArgs.Add('-Session');
  LArgs.Add(ASession);
  Result := TJSONObject.Create;
  Result.AddPair('command', PS_COMMAND);
  Result.AddPair('args', LArgs);
end;

// Loads APath as a JSON object, PRESERVING every existing key, or a fresh empty
// object when the file is absent/unreadable/not an object. Twin of
// TMCPProvision._LoadOrNewRoot -- the caller owns and frees the result.
function _LoadOrNewRoot(const APath: string): TJSONObject;
var
  LRaw: string;
  LVal: TJSONValue;
begin
  Result := nil;
  LRaw := _LoadTextOrEmpty(APath);
  if LRaw <> '' then
  begin
    LVal := TJSONObject.ParseJSONValue(LRaw);  // nil on malformed
    if LVal is TJSONObject then
      Result := TJSONObject(LVal)
    else
      LVal.Free;  // nil-safe; a non-object (or nil) is discarded
  end;
  if Result = nil then
    Result := TJSONObject.Create;
end;

class function TAefosLazMcpAddonMerge.EnsureGeminiConfig(
  const ASession: string): string;
var
  LBase, LDir, LPath: string;
  LRoot, LServers: TJSONObject;
  LServersVal: TJSONValue;
begin
  Result := '';
  try
    LBase := SysUtils.GetEnvironmentVariable('GEMINI_HOME');
    if LBase = '' then
      LBase := TPath.Combine(SysUtils.GetEnvironmentVariable('USERPROFILE'),
        GEMINI_DIR);
    LDir := LBase;
    if not TDirectory.Exists(LDir) then
      TDirectory.CreateDirectory(LDir);
    LPath := TPath.Combine(LDir, GEMINI_FILE);
    LRoot := _LoadOrNewRoot(LPath);  // preserves every existing setting
    try
      LServersVal := LRoot.GetValue(MCP_SERVERS_KEY);
      if LServersVal is TJSONObject then
        LServers := TJSONObject(LServersVal)
      else
      begin
        // Drop a non-object mcpServers (or add a fresh one) without disturbing the
        // rest of the file.
        if LServersVal <> nil then
          LRoot.RemovePair(MCP_SERVERS_KEY).Free;
        LServers := TJSONObject.Create;
        LRoot.AddPair(MCP_SERVERS_KEY, LServers);
      end;
      // Replace ONLY our own entry (the DISTINCT Lazarus key). RemovePair returns
      // nil (safe .Free) when absent. Crucially we touch ONLY 'aefos-lazarus', so a
      // Delphi edition's 'aefos' server in this SHARED settings.json is preserved --
      // both hosts coexist and stay addressable when both IDEs are open.
      LServers.RemovePair(LAZ_SERVER_KEY).Free;
      LServers.AddPair(LAZ_SERVER_KEY, _BuildAefosServer(BridgePath, ASession));
      // UTF-8 WITHOUT BOM -- byte-identical to TMCPProvision.EnsureGeminiConfig.
      TFile.WriteAllBytes(LPath, TEncoding.UTF8.GetBytes(LRoot.Format(2)));
      Result := LPath;
    finally
      LRoot.Free;
    end;
  except
    // A settings-file fault must never break a dispatch: the caller degrades to
    // the honest "no tools" notice for Gemini.
    Result := '';
  end;
end;

class function TAefosLazMcpAddonMerge.BuildMergedConfig(
  const APipeName: string): TAefosLazMcpWiring;
var
  LMerged: string;
  LRoot, LServers: TJSONObject;
  LMergedVal, LServersVal: TJSONValue;
  LPair: TJSONPair;
  LDir: string;
begin
  Result := Default(TAefosLazMcpWiring);
  Result.Session := _SessionFromPipe(APipeName);
  Result.BridgePath := BridgePath;
  Result.ConfigPath := GlobalConfigPath;
  Result.ServerName := LAZ_SERVER_KEY;
  // The SAME pure merge the Delphi executor runs: user extras UNION addon
  // aggregate, the human's hand-written server winning a name collision.
  LMerged := TMCPServerMerge.MergeServers(
    _LoadTextOrEmpty(UserServersPath), _LoadTextOrEmpty(AddonAggregatePath));
  // ExtraMcpNames = the extras' keys. The built-in host ('aefos-lazarus') is
  // authorized by the driver on its own (dynamic --allowedTools mcp__<ServerName>),
  // so it is deliberately NOT in this list -- exactly ServerKeysOf(LMergedMcp) on
  // the Delphi side.
  Result.ServerNames := TMCPServerMerge.ServerKeysOf(LMerged);
  // Write the global config: the built-in 'aefos-lazarus' (always present, wins any
  // same-named extra) + every extra server.
  LRoot := TJSONObject.Create;
  try
    LServers := TJSONObject.Create;
    LRoot.AddPair('mcpServers', LServers);
    // The Lazarus built-in host under its DISTINCT key (LAZ_SERVER_KEY), so it
    // never collides with a Delphi host's 'aefos' in a shared reader (Claude).
    LServers.AddPair(LAZ_SERVER_KEY,
      _BuildAefosServer(Result.BridgePath, Result.Session));
    if Trim(LMerged) <> '' then
    begin
      LMergedVal := TJSONObject.ParseJSONValue(LMerged);  // nil on malformed
      try
        if LMergedVal is TJSONObject then
        begin
          LServersVal := TJSONObject(LMergedVal).GetValue('mcpServers');
          if LServersVal is TJSONObject then
            for LPair in TJSONObject(LServersVal) do
              // Drop a user extra that would shadow our built-in host key.
              if not _AsciiSameText(LPair.JsonString.Value, LAZ_SERVER_KEY) then
                LServers.AddPair(LPair.JsonString.Value, LPair.JsonValue.Clone);
        end;
      finally
        LMergedVal.Free;  // nil-safe
      end;
    end;
    LDir := AppDataDir;
    if not TDirectory.Exists(LDir) then
      TDirectory.CreateDirectory(LDir);
    // UTF-8 WITHOUT BOM (GetBytes emits no preamble) -- byte-identical to
    // TMCPProvision.EnsureGlobalConfig, and some JSON readers choke on a BOM.
    TFile.WriteAllBytes(Result.ConfigPath,
      TEncoding.UTF8.GetBytes(LRoot.Format(2)));
  finally
    LRoot.Free;
  end;
end;

end.
