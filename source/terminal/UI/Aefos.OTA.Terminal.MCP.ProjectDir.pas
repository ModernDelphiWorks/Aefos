unit Aefos.OTA.Terminal.MCP.ProjectDir;

{
  OTA working-directory detection + MCP auto-wiring helpers (ESP-075, S2 /
  ADR-075-02..03).

  DetectProjectWorkDir resolves the active project's root via IOTAModuleServices
  so an AI CLI profile session opens in the project directory (BR3). Any OTA
  failure or no-open-project safe-degrades to the supplied fallback — it never
  raises and never blocks session open. The active-project filename source is an
  injectable seam (SetActiveProjectFileNameResolver) so the resolution logic is
  exercised headless without a live IDE.

  ResolveBridgePath / BuildClaudeMcpAddCommandLine are pure (OTA/VCL-free): the
  bridge path is resolved relative to the loaded BPL module (BR5 — never a
  hardcoded absolute path), and the auto-wiring command is built from that path.

  This unit uses ToolsAPI (UI layer); the Core/RTL units stay ToolsAPI-free.
}

interface

type
  /// <summary>Source of the active project's full file name; returns an empty
  /// string when no project is open. Injectable for headless tests.</summary>
  TActiveProjectFileNameFunc = reference to function: string;

const
  /// <summary>Bridge script path relative to the BPL module directory (BR5).</summary>
  MCP_BRIDGE_RELATIVE_PATH = 'Test\MCP\mcp-bridge.ps1';
  /// <summary>Default MCP session name — matches the proven manual loop and the
  /// Tools -> Options default.</summary>
  MCP_DEFAULT_SESSION = 'terminal';
  /// <summary>RAD Studio default Projects directory, relative to the user
  /// profile (ESP-082, ADR-082-02).</summary>
  DELPHI_PROJECTS_RELATIVE_PATH = 'Documents\Embarcadero\Studio\Projects';

type
  /// <summary>Resolves terminal-session working directories from the active
  /// project (via ToolsAPI, with an injectable headless seam) and the RAD Studio
  /// default Projects folder. Static namespace — never instantiated.</summary>
  TTerminalProjectDirResolver = class sealed
  strict private
    class var FActiveProjectFileName: TActiveProjectFileNameFunc;
  public
    /// <summary>Active project root directory, or <c>AFallback</c> when no
    /// project is open or any OTA lookup fails (BR3). Never raises.</summary>
    class function DetectProjectWorkDir(const AFallback: string): string; static;

    /// <summary>Working directory for a new terminal session, for every profile
    /// type (ESP-082, ADR-082-01/03). An explicit <c>AConfiguredStartDir</c>
    /// wins verbatim; otherwise resolves to the active project root, falling back
    /// to <c>AFallback</c> when no project is open. Pure — never raises.</summary>
    class function ResolveSessionWorkDir(const AConfiguredStartDir, AFallback: string): string; static;

    /// <summary>RAD Studio default Projects directory under <c>AUserProfile</c>
    /// (<c>&lt;AUserProfile&gt;\Documents\Embarcadero\Studio\Projects</c>). Pure —
    /// no filesystem access, never raises; an empty profile degrades to <c>''</c>
    /// (ESP-082, ADR-082-02).</summary>
    class function BuildDefaultProjectsDir(const AUserProfile: string): string; static;

    /// <summary>The Delphi default Projects directory for the current user, read
    /// from <c>%USERPROFILE%</c> (OTA-free wrapper over BuildDefaultProjectsDir).</summary>
    class function DefaultDelphiProjectsDir: string; static;

    /// <summary>Overrides the active-project filename source for headless tests.
    /// Pass <c>nil</c> to restore the default OTA-backed resolver.</summary>
    class procedure SetActiveProjectFileNameResolver(const AResolver: TActiveProjectFileNameFunc); static;
  end;

  /// <summary>Builds the MCP stdio↔pipe bridge script path (relative to the
  /// loaded BPL module, BR5) and the <c>claude mcp add</c> auto-wiring command
  /// line. Pure (OTA/VCL-free). Static namespace — never instantiated.</summary>
  TTerminalMcpBridgeCommand = class sealed
  public
    /// <summary>Bridge script path relative to a module directory. Pure —
    /// combines <c>AModuleDir</c> with <see cref="MCP_BRIDGE_RELATIVE_PATH"/>.</summary>
    class function BridgePathForModuleDir(const AModuleDir: string): string; static;

    /// <summary>Bridge script path relative to this BPL's loaded module (BR5).</summary>
    class function ResolveBridgePath: string; static;

    /// <summary>The fire-and-forget <c>claude mcp add</c> command line that wires
    /// the Claude CLI to the Aefos MCP server via the stdio↔pipe bridge.</summary>
    class function BuildClaudeMcpAddCommandLine(const ABridgePath, ASession: string): string; static;
  end;

implementation

uses
  System.SysUtils,
  System.IOUtils,
  ToolsAPI;

// Default source: the live IDE's active project. Returns '' when BorlandIDEServices
// is absent (headless) or no project is open.
function _OTAActiveProjectFileName: string;
var
  LModuleServices: IOTAModuleServices;
  LProject: IOTAProject;
begin
  Result := '';
  if not Assigned(BorlandIDEServices) then Exit;
  if not Supports(BorlandIDEServices, IOTAModuleServices, LModuleServices) then Exit;
  LProject := LModuleServices.GetActiveProject;
  if Assigned(LProject) then
    Result := LProject.FileName;
end;

{ TTerminalProjectDirResolver }

class function TTerminalProjectDirResolver.DetectProjectWorkDir(const AFallback: string): string;
var
  LFileName: string;
begin
  Result := AFallback;
  try
    if Assigned(FActiveProjectFileName) then
      LFileName := FActiveProjectFileName()
    else
      LFileName := _OTAActiveProjectFileName;
    if LFileName <> '' then
      Result := TPath.GetDirectoryName(LFileName);
  except
    Result := AFallback;
  end;
end;

class procedure TTerminalProjectDirResolver.SetActiveProjectFileNameResolver(
  const AResolver: TActiveProjectFileNameFunc);
begin
  FActiveProjectFileName := AResolver;
end;

class function TTerminalProjectDirResolver.ResolveSessionWorkDir(
  const AConfiguredStartDir, AFallback: string): string;
begin
  if AConfiguredStartDir <> '' then
    Result := AConfiguredStartDir
  else
    Result := DetectProjectWorkDir(AFallback);
end;

class function TTerminalProjectDirResolver.BuildDefaultProjectsDir(const AUserProfile: string): string;
begin
  if AUserProfile = '' then
    Exit('');
  Result := TPath.Combine(AUserProfile, DELPHI_PROJECTS_RELATIVE_PATH);
end;

class function TTerminalProjectDirResolver.DefaultDelphiProjectsDir: string;
begin
  Result := BuildDefaultProjectsDir(GetEnvironmentVariable('USERPROFILE'));
end;

{ TTerminalMcpBridgeCommand }

class function TTerminalMcpBridgeCommand.BridgePathForModuleDir(const AModuleDir: string): string;
begin
  Result := TPath.Combine(AModuleDir, MCP_BRIDGE_RELATIVE_PATH);
end;

class function TTerminalMcpBridgeCommand.ResolveBridgePath: string;
begin
  Result := BridgePathForModuleDir(TPath.GetDirectoryName(GetModuleName(HInstance)));
end;

class function TTerminalMcpBridgeCommand.BuildClaudeMcpAddCommandLine(
  const ABridgePath, ASession: string): string;
begin
  Result := Format('claude mcp add aefos-terminal pwsh -f "%s" -- -Session %s',
    [ABridgePath, ASession]);
end;

end.
