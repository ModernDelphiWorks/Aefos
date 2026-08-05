unit Aefos.OTA.Chat.UI.OutputPanel.Edge;

{
  Output-panel surface interfaces (ESP-002, ADR-241/243).

  The TOutputPanelEdgeSurface class has been retired: its render logic now
  lives in the ToolsAPI-free seam (RenderProtocol.pas) + controller
  (OutputPanel.EdgeController.pas), and TAefosChatPanel is the live
  implementation of both interfaces (ADR-243). The interface declarations
  remain here because they are referenced across the BPL.
}

interface

uses
  Winapi.Windows,
  System.SysUtils;

type
  TStdStream = (stStdout, stStderr);

  // Result callback for IOutputPanelInspector.BeginEvalScript. Declared here
  // (instead of borrowing Vcl.Edge.TExecuteScriptProc, which only exists on
  // Delphi 13) so the contract compiles on Delphi 12 too. Execution runs
  // through Aefos.WebView's own ExecuteScript callback; Sender is always nil in
  // composition mode (callers use the JSON result, not Sender).
  TInspectorEvalProc = reference to procedure(Sender: TObject;
    AResult: HRESULT; const AResultObjectAsJson: string);

  IOutputPanelSurface = interface
    ['{4B7C2E91-6F2A-49D0-A8C2-1D5E3F8B7A04}']
    procedure Show;
    procedure Clear;
    procedure AppendChunk(const AText: string; const AStream: TStdStream);
    procedure ReportComplete(const AExitCode: Integer);
    procedure ReportError(const AException: Exception);
  end;

  // Result-returning WebView2 inspection capability (ESP-002, ADR-243).
  // TAefosChatPanel implements this interface by delegating to the
  // embedded TOutputPanelEdgeController. Surfaces that are not WebView2-
  // backed simply do not implement it (the facade then reports no-panel).
  IOutputPanelInspector = interface
    ['{C3A7E519-8B42-4D6F-A015-9E2C7B4D8F61}']
    // True once the WebView2 runtime has loaded and navigation completed.
    function IsBrowserReady: Boolean;
    // True once NavigateToString completed (queue draining). Scripts execute
    // reliably only after this. Checked before BeginEvalScript in the facade
    // to avoid spurious timeouts while the HTML shell is still loading.
    function IsQueueReady: Boolean;
    // Initiates a result-returning ExecuteScript via TEdgeBrowser's callback
    // overload; AOnDone fires on the main thread with the WebView2 JSON
    // result. Returns False immediately when the browser is not ready so the
    // facade maps it to a structured 'not-initialized' error. The async->sync
    // bridge (bounded wait, timeout) lives in the facade (ADR-216).
    function BeginEvalScript(const AScript: string;
      const AOnDone: TInspectorEvalProc): Boolean;
  end;

implementation

end.
