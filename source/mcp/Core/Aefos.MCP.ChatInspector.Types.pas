unit Aefos.MCP.ChatInspector.Types;

(*
  Chat-panel WebView2 inspection facade (ESP-002, Epic 2/3 Demand 1/5;
  ADR-215). RTL-only — zero `uses ToolsAPI` / `Vcl.` / `FMX.` so the unit
  stays inside the MCP.Core boundary (C-1, Tests.MCPPackageBoundary).

  The GetChatPanelHTML / EvalChatPanelScript tools must call
  TEdgeBrowser.ExecuteScript on the live chat panel, but that browser lives in
  the VCL/plugin layer. Following the IMCPWorkspaceFacade pattern, the tools
  depend only on this interface; the implementation that touches TEdgeBrowser
  (TChatInspectorFacade) is injected at composition time from the plugin BPL.

  Contract (BR-3 / BR-5):
    - Every method runs the WebView2 call on the VCL main thread and NEVER
      raises and NEVER hangs. A failure is reported as Result=False plus a
      structured, kebab-coded reason in AError, one of:
        no-panel          — no chat-panel WebView2 surface is open
        not-initialized   — the WebView2 runtime has not finished loading
        script-error      — the script raised / ExecuteScript returned non-S_OK
        timeout           — the async callback did not complete in time
    - GetRenderedHtml returns the decoded DOM string (the WebView2 JSON
      string result is unwrapped to its raw text — A-2).
    - EvalScript returns the WebView2 result verbatim as JSON text (A-2/BR-5);
      the tool embeds it under `result`.
*)

interface

uses
  Aefos.MCP.Types;

type
  // Injected at composition time; implemented in the plugin BPL against the
  // live TOutputPanelEdgeSurface / TEdgeBrowser (ADR-215).
  IMCPChatInspectorFacade = interface
    ['{7E2C9A14-3D5B-4F81-9C26-8A4E1B7D3F50}']
    // Reads document.documentElement.outerHTML from the chat panel and returns
    // it decoded. True + AHtml on success; False + AError (no-panel /
    // not-initialized / timeout) on failure. Never raises.
    function GetRenderedHtml(out AHtml: string; out AError: string): Boolean;
    // Evaluates AScript in the chat panel and returns its WebView2 JSON result
    // verbatim. True + AResultJson on success; False + AError (no-panel /
    // not-initialized / script-error / timeout) on failure. Never raises.
    function EvalScript(const AScript: string; out AResultJson: string;
      out AError: string): Boolean;
    // Destructive-action consent modal for EvalChatPanelScript (RN-C01),
    // shown on the IDE main thread by the implementation. Mirrors
    // IMCPWorkspaceFacade.RequestConsent; the calling handler marshals it.
    function RequestConsent(const AToolName, ASummary,
      ADetail: string): TMCPConsentDecision;
  end;

implementation

end.
