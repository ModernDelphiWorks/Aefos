unit Aefos.Lazarus.McpHost;

{ Aefos AI - Lazarus edition: hosted MCP server lifecycle.

  Owns a single TMCPServer for the Lazarus IDE, the Lazarus twin of the Delphi
  chat/terminal hosts (source\chat\Aefos.OTA.Chat.Register.pas ~2945 /
  source\terminal\Core\Aefos.OTA.Terminal.MCP.Host.pas). It wires the three
  composition-root seams a hosted server needs:

    - transport  = a Windows named-pipe transport (TNamedPipeTransport),
    - marshal     = server->IDE-main-thread hop via TThread.Synchronize (blocking,
                    returns to the worker; LCL drains the Synchronize queue from
                    its main loop, exactly as the VCL does - the WRONG analog is
                    Application.QueueAsyncCall, which is fire-and-forget),
    - view provider = facade.CurrentIdeViewIntent, arming RULE #1 so the server
                    rejects a design/code tool sent in the wrong view.

  FPC 3.2.2 has no anonymous methods, so the three seams are BOUND METHODS of
  this host (of-object callbacks), not closures - the host therefore must outlive
  the server, which the process-wide singleton guarantees. The pipe name is
  MCP_PIPE_PREFIX + 'lazarus'.

  The unload-AV teardown ritual the RAD Studio BPLs need does NOT apply here: the
  Lazarus design package is STATICALLY linked into lazarus.exe and never unmaps,
  so there is no BPL-unmap window. Start/Stop are idempotent and never raise out
  (all failure is caught + logged with DebugLn, the Lazarus twin of the teardown
  log) so a toggle click or an autostart probe can never crash the IDE.

  Mode delphiunicode + de-dotted units, matching the MCP core; all literals are
  ASCII, so the file needs no BOM. }

{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

interface

uses
  Aefos.MCP.Types,
  Aefos.MCP.IntentGuard,
  Aefos.MCP.Server;

type
  { Process-wide MCP host for the Lazarus IDE. One owned server; Start/Stop are
    idempotent and swallow-and-log every fault. }
  TAefosLazMcpHost = class
  private
    FServer: IMCPServer;
    FFacade: IMCPWorkspaceFacade;
    FTools: TObject;     // TAefosLazMcpToolsRegistrar (owned; freed after Stop)
    FPipeName: string;
    { Why the last Start failed, in words a user can act on ('' once one
      succeeds). Start swallows every fault by design (a toggle click or an
      autostart probe must never crash the IDE), but swallowing it into a DebugLn
      nobody reads left the single most common failure -- a second IDE holding the
      pipe -- completely invisible: the user only ever saw "the MCP server is not
      reachable". This field is how the reason reaches the surfaces the user is
      actually looking at. }
    FLastStartError: string;
    // Bound composition-root seams (of-object; FPC has no closures).
    function _MakeTransport: IMCPTransport;
    procedure _Marshal(const AProc: TThreadProcedure);
    function _ViewIntent: TMCPToolIntent;
    procedure _TeardownServer;
  public
    constructor Create;
    destructor Destroy; override;
    // Idempotent. Builds the server on MCP_PIPE_PREFIX+'lazarus', arms the view
    // provider, registers the live read/editor tools, and opens the transport.
    // Never raises out (logs on failure and rolls back to the stopped state).
    procedure Start;
    // Idempotent. Shuts the transport down and frees the tool registrar AFTER the
    // server is stopped (so no in-flight worker calls a freed handler).
    procedure Stop;
    function Started: Boolean;
    function PipeName: string;
    // Why the last Start failed, ready to show ('' when it succeeded or was
    // never attempted). See FLastStartError.
    function LastStartError: string;
  end;

// Process-wide singleton (lazily created). The menu toggle and the autostart
// probe both drive THIS instance, so "server running?" is a single truth.
function AefosLazMcpHost: TAefosLazMcpHost;

// True once the singleton has been created (so shutdown can avoid resurrecting
// it just to free nothing).
function AefosLazMcpHostExists: Boolean;

implementation

uses
  SysUtils,
  Classes,
  LazLoggerBase,
  Aefos.MCP.Transport.NamedPipe,
  Aefos.MCP.AddonGateway,
  Aefos.Lazarus.IdeSilence,
  Aefos.Lazarus.WorkspaceFacade,
  Aefos.Lazarus.McpTools,
  Aefos.Lazarus.ChatAgent;

const
  cLogTag = '[AefosAI] ';
  { Win32 ERROR_PIPE_BUSY. Named inline rather than pulled from Windows: this unit
    deliberately depends on nothing but SysUtils/Classes/LazLoggerBase + the MCP
    core, and the value is frozen ABI. }
  cErrorPipeBusy = 231;

type
  { Lets the chat's Agent loop reach THIS host without the chat depending on the
    IDE. The dependency points this way on purpose: Aefos.Lazarus.ChatAgent is
    also compiled by the standalone runtime proof, which links no IDE units, so it
    may never `uses` this unit -- it publishes the seam, we implement it. See
    IAefosAgentMcpHostProvider. }
  TAefosLazAgentHostProvider = class(TInterfacedObject,
    IAefosAgentMcpHostProvider)
  public
    function EnsureStarted(out APipeName: string): Boolean;
    function LastError: string;
  end;

  { Wraps ONE marshalled tool call in the pipe-critical window (see
    Aefos.Lazarus.IdeSilence): while the IDE main thread is executing an agent
    tool, no IDE disk-diff modal may open on it, because the agent has no hand to
    click it with. FPC has no closures, so the window cannot be opened around a
    lambda - it takes an object whose METHOD is the of-object callback
    TThread.Synchronize accepts. One tiny instance per call, freed by the caller. }
  TAefosLazMarshalGuard = class
  private
    FProc: TThreadProcedure;
  public
    constructor Create(const AProc: TThreadProcedure);
    procedure Run;
  end;

{ TAefosLazMarshalGuard }

constructor TAefosLazMarshalGuard.Create(const AProc: TThreadProcedure);
begin
  inherited Create;
  FProc := AProc;
end;

procedure TAefosLazMarshalGuard.Run;
begin
  // Runs on the IDE main thread. The window MUST close even when the tool raises:
  // Synchronize re-raises in the worker AFTER this method unwinds, so the finally
  // is the only place that can hand the user's setting back.
  TAefosIdeSilence.BeginPipeCritical;
  try
    FProc();
  finally
    TAefosIdeSilence.EndPipeCritical;
  end;
end;

{ TAefosLazMcpHost }

constructor TAefosLazMcpHost.Create;
begin
  inherited Create;
  FPipeName := MCP_PIPE_PREFIX + 'lazarus';
end;

destructor TAefosLazMcpHost.Destroy;
begin
  Stop;
  inherited;
end;

function TAefosLazMcpHost._MakeTransport: IMCPTransport;
begin
  Result := TNamedPipeTransport.Create;
end;

procedure TAefosLazMcpHost._Marshal(const AProc: TThreadProcedure);
var
  LGuard: TAefosLazMarshalGuard;
begin
  // Blocking server->main hop: queues AProc and blocks the transport worker
  // until the IDE main loop runs it (LCL drains the Synchronize queue via
  // CheckSynchronize in Application.Idle/HandleMessage). Returns a value to the
  // worker before dispatch continues - which QueueAsyncCall could not do.
  //
  // The hop is ALSO the pipe-critical boundary: what the guard wraps is exactly
  // the stretch of main-thread time an agent tool owns, which is where a blocking
  // IDE modal (DoBuildProject -> DoCheckFilesOnDisk, ide\main.pp:7273) would
  // freeze the pipe with nobody there to click it.
  LGuard := TAefosLazMarshalGuard.Create(AProc);
  try
    TThread.Synchronize(nil, LGuard.Run);
  finally
    LGuard.Free;
  end;
end;

function TAefosLazMcpHost._ViewIntent: TMCPToolIntent;
begin
  // RULE #1 view probe. Runs on the IDE main thread (the server marshals it
  // through _Marshal). A nil facade or a probe hiccup degrades to tiNeutral
  // (guard off = allow) inside the server's own carrier - never a crash.
  Result := tiNeutral;
  if Assigned(FFacade) then
    Result := FFacade.CurrentIdeViewIntent;
end;

procedure TAefosLazMcpHost._TeardownServer;
begin
  // Order matters: stop the server (joins the transport workers) BEFORE freeing
  // the tool registrar, so no in-flight worker can call a freed handler.
  //
  // KNOWN LIMITATION (inherited, not introduced here): the FServer := nil then
  // FreeAndNil(FTools) path shares the Delphi terminal host's force-leak-window
  // limitation. If TNamedPipeTransport.Stop force-leaks a worker on its 1s join
  // timeout, that leaked worker's FOnFrame/handler could still touch a freed
  // TMCPServer/registrar. It is RARE (Stop runs on the main thread and pumps
  // CheckSynchronize, so parked workers unblock and exit first) and is inherited
  // from the shared Server/Transport, not created by this host. The proper fix -
  // Stop returning a force-leak signal so the host also leaks FServer/FTools
  // (matching the transport's own "leak > corrupt" stance) - is a shared-infra
  // hardening task tracked SEPARATELY; it must not change the shared
  // Server/Transport signatures and is deliberately NOT done in this fix.
  if Assigned(FServer) then
  begin
    try
      FServer.Stop;
    except
      on E: Exception do
        DebugLn(cLogTag + 'MCP host: server.Stop raised '
          + E.ClassName + ': ' + E.Message);
    end;
    FServer := nil;
  end;
  if Assigned(FTools) then
    FreeAndNil(FTools);
end;

procedure TAefosLazMcpHost.Start;
var
  LFactory: TMCPTransportFactory;
  LMarshal: TMCPMainThreadMarshal;
  LView: TMCPViewProvider;
  LTools: TAefosLazMcpToolsRegistrar;
begin
  if Assigned(FServer) then
    Exit; // already listening (idempotent)
  try
    if FFacade = nil then
      FFacade := NewAefosLazWorkspaceFacade;
    // Assign the of-object seams to typed locals first (a bare method name as an
    // argument can be misparsed as a CALL on FPC).
    LFactory := _MakeTransport;
    LMarshal := _Marshal;
    FServer := TMCPServer.Create(LFactory, LMarshal, '0.1.0');
    LView := _ViewIntent;
    FServer.SetViewProvider(LView);
    // Addon-MCP gateway (ESP: `aefos install <mcp>` -> every agent). One brain:
    // the SAME %USERPROFILE%\.aefos\addons\mcp-servers.json aggregate the Delphi
    // edition reads, so an addon installed once shows up in both IDEs. The server
    // kills the spawned children from its Stop/Destroy (called by _TeardownServer).
    FServer.SetToolGateway(TMCPAddonGateway.Create);
    LTools := TAefosLazMcpToolsRegistrar.Create(FFacade);
    FTools := LTools;
    LTools.RegisterAll(FServer);
    // SEAM / TODO (PyTools RUN side): the RAD Studio host ALSO registers one MCP
    // tool per %APPDATA%\Aefos\pytools\<name>\tool.json here (Delphi
    // Aefos.MCP.Tools.PyTools.RegisterPyTools -> interpreter resolve + subprocess
    // run + consent/audit). That runtime lives in source\mcp\Tools (Winapi +
    // System.JSON) and is NOT yet on the Lazarus package unit path, so the Lazarus
    // host does not expose the Python tools yet. The MANAGE side (create/edit/
    // delete the identical files) already ships as the "Python Tools" window
    // (Aefos.Lazarus.PyToolsWindow / Aefos.Lazarus.PyToolsStore); wiring a
    // FPC-clean PyTools registrar onto FServer (the twin of how this registrar
    // was hand-built on Aefos.Compat.Json) is a separate future slice.
    FServer.Start(FPipeName);
    FLastStartError := '';
    DebugLn(cLogTag + 'MCP host: server listening on ' + FPipeName);
  except
    { The pipe name is FIXED (MCP_PIPE_PREFIX + 'lazarus') and a named pipe is
      machine-global, so a SECOND Lazarus IDE cannot create it: the transport
      raises EOSError/ERROR_PIPE_BUSY and this host silently has no server. That
      is by far the most common way the MCP goes missing (proved live 2026-07-27:
      one leftover IDE was enough), and the generic wording sent the user hunting
      config that was never wrong. Name it exactly, and say what to do. }
    on E: EOSError do
    begin
      if E.ErrorCode = cErrorPipeBusy then
        FLastStartError :=
          'Another Lazarus IDE is already hosting the Aefos MCP server on "'
          + FPipeName + '". Only one IDE can host it at a time -- close the other '
          + 'IDE (including any leftover lazarus.exe still running) and start the '
          + 'server again.'
      else
        FLastStartError := 'The MCP server could not open "' + FPipeName
          + '" (OS error ' + IntToStr(E.ErrorCode) + ': ' + E.Message + ').';
      DebugLn(cLogTag + 'MCP host: START failed EOSError ' + IntToStr(E.ErrorCode)
        + ': ' + E.Message);
      _TeardownServer; // roll back to the clean stopped state
    end;
    on E: Exception do
    begin
      FLastStartError := 'The MCP server failed to start (' + E.ClassName + ': '
        + E.Message + ').';
      DebugLn(cLogTag + 'MCP host: START failed '
        + E.ClassName + ': ' + E.Message);
      _TeardownServer; // roll back to the clean stopped state
    end;
  end;
end;

function TAefosLazMcpHost.LastStartError: string;
begin
  Result := FLastStartError;
end;

procedure TAefosLazMcpHost.Stop;
begin
  try
    _TeardownServer;
    DebugLn(cLogTag + 'MCP host: stopped');
  except
    on E: Exception do
      DebugLn(cLogTag + 'MCP host: STOP raised '
        + E.ClassName + ': ' + E.Message);
  end;
end;

function TAefosLazMcpHost.Started: Boolean;
begin
  Result := Assigned(FServer) and FServer.Started;
end;

function TAefosLazMcpHost.PipeName: string;
begin
  Result := FPipeName;
end;

var
  GHost: TAefosLazMcpHost = nil;

function AefosLazMcpHost: TAefosLazMcpHost;
begin
  if GHost = nil then
    GHost := TAefosLazMcpHost.Create;
  Result := GHost;
end;

function AefosLazMcpHostExists: Boolean;
begin
  Result := GHost <> nil;
end;

{ TAefosLazAgentHostProvider }

function TAefosLazAgentHostProvider.EnsureStarted(
  out APipeName: string): Boolean;
begin
  APipeName := '';
  Result := False;
  try
    // Idempotent, and never raises out (Start swallows + logs). Starting the
    // server is NOT consent: every write still meets the tool registrar's
    // _EnsureWriteConsent, exactly as it does for any other pipe client.
    if not AefosLazMcpHost.Started then
      AefosLazMcpHost.Start;
    Result := AefosLazMcpHost.Started;
    if Result then
      APipeName := AefosLazMcpHost.PipeName;
  except
    // A provider must never raise into the agent loop.
    Result := False;
  end;
end;

function TAefosLazAgentHostProvider.LastError: string;
begin
  // Best-effort: never raise into the agent loop, and never resurrect the
  // singleton just to ask it why it failed.
  Result := '';
  try
    if AefosLazMcpHostExists then
      Result := AefosLazMcpHost.LastStartError;
  except
    Result := '';
  end;
end;

initialization
  // Composition root for the chat's Agent mode. Done here rather than in
  // Register so it cannot be forgotten: this unit is what owns the host, and unit
  // init order guarantees Aefos.Lazarus.ChatAgent (which we `uses`) is ready
  // first. Package-only, so the standalone proof simply has no provider and the
  // agent degrades with an honest notice.
  TAefosLazAgentGate.InstallMcpHostProvider(TAefosLazAgentHostProvider.Create);

finalization
  // Drop the provider BEFORE the host dies, so a late turn cannot resurrect the
  // singleton during shutdown.
  TAefosLazAgentGate.InstallMcpHostProvider(nil);
  // Static link: the package never unmaps, so this runs only at IDE shutdown.
  // Stop the server + free the singleton so no worker thread outlives the host.
  if GHost <> nil then
    FreeAndNil(GHost);

end.
