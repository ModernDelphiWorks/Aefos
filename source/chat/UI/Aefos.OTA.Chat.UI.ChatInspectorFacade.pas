unit Aefos.OTA.Chat.UI.ChatInspectorFacade;

(*
  Plugin-side IMCPChatInspectorFacade implementation (ESP-002, Epic 2/3
  Demand 1/5; ADR-215/ADR-216). VCL/plugin layer — touches TEdgeBrowser via
  IOutputPanelInspector and therefore lives in the Aefos.OTA BPL, never
  in MCP.Core (C-1). Injected into RegisterChatInspectorTools at the
  composition root, exactly as TOTAFacade implements IMCPWorkspaceFacade.

  Async->sync bridge (ADR-216):
    - GetRenderedHtml / EvalScript run on the MCP worker thread.
    - The WebView2 ExecuteScript call is STA-bound and asynchronous, so its
      initiation is marshalled to the VCL main thread (TThread.Queue) and the
      worker waits on a per-call TEvent with a bounded timeout. On signal the
      stored result is returned; on timeout a structured 'timeout' error is
      returned. The main thread is never blocked from the worker side, and the
      server never hangs (feedback_chat_sync_ux_async_thread).
    - Resolution failures degrade to structured errors (no-panel /
      not-initialized / script-error / timeout) — never an exception (BR-3).

  Live WebView2 coverage note: this unit drives TEdgeBrowser and cannot be
  exercised in the headless DUnit runner (no WebView2/STA host). It is verified
  by the BLOCKING IDE-smoke checkpoint (AC-09) and excluded from the per-file
  coverage gate (COMMAND.md), mirroring the NamedPipe / GitFacade transport
  precedent. The tool/facade contract is covered headlessly via a stub facade.
*)

interface

uses
  System.SysUtils,
  Aefos.OTA.Chat.UI.OutputPanel.Edge,
  Aefos.MCP.ChatInspector.Types,
  Aefos.MCP.Types;

type
  // Resolves the live chat-panel surface (GOutputPanel) at call time.
  TOutputPanelResolver = TFunc<IOutputPanelSurface>;
  // Shows the destructive-action consent modal on the IDE main thread.
  TConsentResolver = TFunc<string, string, string, TMCPConsentDecision>;

  TChatInspectorFacade = class(TInterfacedObject, IMCPChatInspectorFacade)
  private
    FSurfaceResolver: TOutputPanelResolver;
    FConsentResolver: TConsentResolver;
    function _RunEval(const AScript: string;
      out AResultJson, AError: string): Boolean;
  public
    constructor Create(const ASurfaceResolver: TOutputPanelResolver;
      const AConsentResolver: TConsentResolver);
    // IMCPChatInspectorFacade
    function GetRenderedHtml(out AHtml: string; out AError: string): Boolean;
    function EvalScript(const AScript: string; out AResultJson: string;
      out AError: string): Boolean;
    function RequestConsent(const AToolName, ASummary,
      ADetail: string): TMCPConsentDecision;
  end;

implementation

uses
  System.Classes,
  System.SyncObjs,
  System.JSON,
  Winapi.Windows;

const
  // Bounded wait for the WebView2 callback (ADR-216). Inspection scripts are
  // trivial DOM reads; 5 s is generous and turns a hung runtime into a
  // structured 'timeout' rather than a stuck tool call.
  CEvalTimeoutMs = 5000;

  CErrNoPanel        = 'no-panel';
  CErrNotInitialized = 'not-initialized';
  CErrScriptError    = 'script-error';
  CErrTimeout        = 'timeout';

  // document.documentElement.outerHTML — the rendered DOM (A-2).
  CRenderedHtmlScript = 'document.documentElement.outerHTML';

type
  // Per-call result holder + completion gate. Reference-counted so it outlives
  // the worker on a timeout (the queued main-thread closure still holds a ref
  // until the WebView2 callback fires). Field writes happen-before SetEvent;
  // the worker reads only after WaitFor returns signaled.
  IEvalCall = interface
    ['{5F1D3B82-9A47-4C0E-8B16-3D7E2A9F5C40}']
    function Event: TEvent;
    procedure Complete(const AHResult: HRESULT; const AJson: string);
    procedure Fail(const AReason: string);
    function Failed: Boolean;
    function Reason: string;
    function ResultHResult: HRESULT;
    function Json: string;
  end;

  TEvalCall = class(TInterfacedObject, IEvalCall)
  private
    FEvent: TEvent;
    FHResult: HRESULT;
    FJson: string;
    FFailed: Boolean;
    FReason: string;
  public
    constructor Create;
    destructor Destroy; override;
    function Event: TEvent;
    procedure Complete(const AHResult: HRESULT; const AJson: string);
    procedure Fail(const AReason: string);
    function Failed: Boolean;
    function Reason: string;
    function ResultHResult: HRESULT;
    function Json: string;
  end;

{ TEvalCall }

constructor TEvalCall.Create;
begin
  inherited Create;
  // Manual-reset, initially non-signaled: signaled exactly once by
  // Complete/Fail.
  FEvent := TEvent.Create(nil, True, False, '');
  FHResult := S_OK;
end;

destructor TEvalCall.Destroy;
begin
  FEvent.Free;
  inherited;
end;

function TEvalCall.Event: TEvent;
begin
  Result := FEvent;
end;

procedure TEvalCall.Complete(const AHResult: HRESULT; const AJson: string);
begin
  FHResult := AHResult;
  FJson := AJson;
  FEvent.SetEvent;
end;

procedure TEvalCall.Fail(const AReason: string);
begin
  FFailed := True;
  FReason := AReason;
  FEvent.SetEvent;
end;

function TEvalCall.Failed: Boolean;
begin
  Result := FFailed;
end;

function TEvalCall.Reason: string;
begin
  Result := FReason;
end;

function TEvalCall.ResultHResult: HRESULT;
begin
  Result := FHResult;
end;

function TEvalCall.Json: string;
begin
  Result := FJson;
end;

// Unwraps a WebView2 JSON string result to its raw text; non-string / invalid
// JSON is returned verbatim (A-2).
function _DecodeJsonString(const AJson: string): string;
var
  LValue: TJSONValue;
begin
  Result := AJson;
  LValue := TJSONObject.ParseJSONValue(AJson);
  if Assigned(LValue) then
  try
    if LValue is TJSONString then
      Result := TJSONString(LValue).Value;
  finally
    LValue.Free;
  end;
end;

{ TChatInspectorFacade }

constructor TChatInspectorFacade.Create(
  const ASurfaceResolver: TOutputPanelResolver;
  const AConsentResolver: TConsentResolver);
begin
  inherited Create;
  FSurfaceResolver := ASurfaceResolver;
  FConsentResolver := AConsentResolver;
end;

function TChatInspectorFacade._RunEval(const AScript: string;
  out AResultJson, AError: string): Boolean;
var
  LSurface: IOutputPanelSurface;
  LInspector: IOutputPanelInspector;
  LCall: IEvalCall;
  LInitiate: TThreadProcedure;
begin
  AResultJson := '';
  AError := '';
  LSurface := nil;
  if Assigned(FSurfaceResolver) then
    LSurface := FSurfaceResolver();
  // No output panel, or the live surface is not a WebView2 inspector surface
  // (e.g. a non-WebView2 chat panel) -> structured no-panel error (A-1/BR-3).
  if not (Assigned(LSurface)
    and Supports(LSurface, IOutputPanelInspector, LInspector)) then
  begin
    AError := CErrNoPanel;
    Exit(False);
  end;
  LCall := TEvalCall.Create;
  LInitiate :=
    procedure
    begin
      if not LInspector.IsBrowserReady then
      begin
        LCall.Fail(CErrNotInitialized);
        Exit;
      end;
      if not LInspector.BeginEvalScript(AScript,
        procedure(Sender: TObject; AHResultCb: HRESULT;
          const AJson: string)
        begin
          LCall.Complete(AHResultCb, AJson);
        end) then
        LCall.Fail(CErrNotInitialized);
    end;
  // Marshal the initiation to the VCL main thread; the worker waits on the
  // call's TEvent with a bounded timeout (ADR-216). On the (defensive) main
  // thread, run inline — the callback overload pumps to completion.
  if TThread.CurrentThread.ThreadID = MainThreadID then
    LInitiate()
  else
    TThread.Queue(nil, LInitiate);
  if LCall.Event.WaitFor(CEvalTimeoutMs) <> wrSignaled then
  begin
    AError := CErrTimeout;
    Exit(False);
  end;
  if LCall.Failed then
  begin
    AError := LCall.Reason;
    Exit(False);
  end;
  if LCall.ResultHResult <> S_OK then
  begin
    AError := CErrScriptError;
    Exit(False);
  end;
  AResultJson := LCall.Json;
  Result := True;
end;

function TChatInspectorFacade.GetRenderedHtml(out AHtml: string;
  out AError: string): Boolean;
var
  LJson: string;
begin
  AHtml := '';
  Result := _RunEval(CRenderedHtmlScript, LJson, AError);
  if Result then
    AHtml := _DecodeJsonString(LJson);  // decode to raw HTML (A-2)
end;

function TChatInspectorFacade.EvalScript(const AScript: string;
  out AResultJson: string; out AError: string): Boolean;
begin
  // Result returned verbatim as WebView2 JSON (A-2/BR-5).
  Result := _RunEval(AScript, AResultJson, AError);
end;

function TChatInspectorFacade.RequestConsent(const AToolName, ASummary,
  ADetail: string): TMCPConsentDecision;
begin
  // Invoked from the calling handler's main-thread marshal (RN-C01). A missing
  // resolver is fail-safe: treat as denied.
  if Assigned(FConsentResolver) then
    Result := FConsentResolver(AToolName, ASummary, ADetail)
  else
    Result := cdDenied;
end;

end.
