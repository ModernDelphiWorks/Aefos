program AefosDesktopMcp;

{
  Aefos Desktop — an MCP server for the developer's real desktop (feat/desktop-mcp).

  WHY THIS IS A SEPARATE PROCESS (the load-bearing architectural decision):
  the ToolsAPI offers nothing for desktop automation, and UI Automation is a
  COM ABI on UIAutomationCore.dll. Driving it from INSIDE the RAD Studio process
  could freeze or crash the customer's IDE. So this runs OUT of process, over
  stdio, reusing the very same TMCPServer core as the in-IDE server — swapping
  only the transport (stdio instead of a named pipe), so the JSON-RPC dialect,
  the tool-descriptor shape and the error codes are identical BY CONSTRUCTION
  rather than by imitation.

  PHASE 4 (read tools). Four READ-ONLY tools: desktop_ping, desktop_list_windows,
  desktop_window_tree, desktop_element_find. No mutation (click/type/close arrive
  in a later, separately guarded phase; screen_capture/ocr in phase 4b). Every
  read is passed through the pure privacy guard (Aefos.Desktop.Guard, finding M7):
  a sensitive/out-of-scope window's title is redacted before it leaves the process,
  with identity resolved by exe path (finding H4), never by the spoofable title.

  No ToolsAPI, no VCL, no designide — so ONE binary serves every IDE version
  (D11/D12/D13). The window enumeration uses the hand-written COM import
  Aefos.Win.UIAutomation, which closes the D11/D12 gap (those IDEs do not ship
  Winapi.UIAutomation).

  Usage (as an MCP server, spawned by the client):
      AefosDesktopMcp.exe
}

{$APPTYPE CONSOLE}

uses
  Winapi.ActiveX,
  System.SysUtils,
  System.Classes,
  Aefos.MCP.Types in '..\..\source\mcp\Core\Aefos.MCP.Types.pas',
  Aefos.MCP.IntentGuard in '..\..\source\mcp\Core\Aefos.MCP.IntentGuard.pas',
  Aefos.MCP.FlowGuide in '..\..\source\mcp\Core\Aefos.MCP.FlowGuide.pas',
  Aefos.MCP.InspectorBridge in '..\..\source\mcp\Core\Aefos.MCP.InspectorBridge.pas',
  Aefos.MCP.Server in '..\..\source\mcp\Core\Aefos.MCP.Server.pas',
  Aefos.MCP.Transport.Stdio in 'Aefos.MCP.Transport.Stdio.pas',
  Aefos.Win.UIAutomation in 'Aefos.Win.UIAutomation.pas',
  Aefos.Desktop.Guard in 'Aefos.Desktop.Guard.pas',
  Aefos.Desktop.ReadShape in 'Aefos.Desktop.ReadShape.pas',
  Aefos.Desktop.Capture in 'Aefos.Desktop.Capture.pas',
  Aefos.Desktop.Audit in 'Aefos.Desktop.Audit.pas',
  Aefos.Desktop.Actions in 'Aefos.Desktop.Actions.pas',
  Aefos.Desktop.Consent in 'Aefos.Desktop.Consent.pas',
  Aefos.Desktop.Tools in 'Aefos.Desktop.Tools.pas';

const
  SERVER_VERSION = '0.4.1';

var
  GTransport: TMCPStdioTransport;
  GTransportRef: IMCPTransport;
  GServer: TMCPServer;
  GComReady: Boolean;
begin
  GComReady := False;
  try
    // UI Automation is COM. Initialise the main thread once here (STA); each
    // tool handler still initialises its own thread per call (see Tools unit),
    // because a handler may run on a worker thread the server spun up.
    GComReady := Succeeded(CoInitializeEx(nil, COINIT_APARTMENTTHREADED));

    GTransport := TMCPStdioTransport.Create;
    GTransportRef := GTransport;   // interface ref keeps it alive

    // No IDE here, so there is no main thread to marshal to: the marshal is the
    // identity. (In the in-IDE server this hops to the OTA main thread.)
    GServer := TMCPServer.Create(
      function: IMCPTransport
      begin
        Result := GTransportRef;
      end,
      procedure(const AProc: TThreadProcedure)
      begin
        AProc();
      end,
      SERVER_VERSION);
    try
      TDesktopTools.RegisterTools(GServer);
      GServer.Start('');           // stdio ignores the pipe name
      GTransport.Run;              // blocks until the client closes stdin
      GServer.Stop;
    finally
      GServer.Free;
    end;
    ExitCode := 0;
  except
    on E: Exception do
    begin
      // stdout belongs to the protocol — a crash report goes to stderr.
      StdioLog('fatal: ' + E.ClassName + ': ' + E.Message);
      ExitCode := 1;
    end;
  end;
  if GComReady then
    CoUninitialize;
end.
