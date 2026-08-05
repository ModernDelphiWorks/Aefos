unit Aefos.OTA.UI.MCPToolInspector;

(*
  WebView2-backed MCP Tool Inspector window (ADR-117). DECOUPLED by design:
  depends ONLY on IMCPInspectorBridge (the engine) + a tools-list JSON, both
  INJECTED by the composition root via ShowMCPInspector. No TMCPServer, no
  ToolsAPI, no chat reference lives here - the single coupling (a live server as
  IMCPInspectorHost) is wired once at the composition root.

  WebView2 hosting is the shared Aefos composition host (Aefos.WebView.Control /
  TAefosWebView) - the SAME control the chat uses - NOT Vcl.Edge/TEdgeBrowser.
  That keeps this window off the 10.4+ RTL so it builds on legacy Delphi too.
  Recipe: Configure (UserDataFolder) before Parent; navigate via a file:/// temp
  URL since NavigateToString hangs in bds.exe; handlers nilled in Destroy.

  Pascal -> JS : window.insSetTools / insSetResult / insSetError
  JS -> Pascal : 'ready' | 'run:' + JSON({ tool, args })
*)

interface

uses
  System.Classes,
  Vcl.Forms,
  Aefos.WebView.Control,
  Aefos.WebView.Types,
  Aefos.MCP.InspectorBridge;

type
  TMCPInspectorForm = class(TForm)
  private
    FBrowser: TAefosWebView;
    FBridge: IMCPInspectorBridge;
    FToolsJson: string;
    FReady: Boolean;        // WebView2 host ready
    FNavigated: Boolean;    // navigation started
    FPageLive: Boolean;     // NavigationCompleted / page 'ready' seen
    procedure _OnReady;
    procedure _OnNav(const ASuccess: Boolean);
    procedure _OnHostMsg(const AMessage: string);
    procedure _OnFormClose(Sender: TObject; var Action: TCloseAction);
    procedure _EnsureNavigated;
    procedure _Flush;
    procedure _HandleHostMessage(const AMessage: string);
    procedure _PostError(const AText: string);
  public
    constructor CreateInspector(AOwner: TComponent;
      const ABridge: IMCPInspectorBridge; const AToolsJson: string); reintroduce;
    destructor Destroy; override;
  end;

// The single entry point the composition root calls (e.g. from /inspector).
// Hand it the live bridge + the tools-list JSON; this unit owns the window
// lifetime (singleton - reused if already open).
procedure ShowMCPInspector(const ABridge: IMCPInspectorBridge;
  const AToolsJson: string);

implementation

uses
  Winapi.Windows,
  Winapi.ActiveX,
  System.SysUtils,
  System.IOUtils,
  System.JSON,
  Vcl.Controls,
  Aefos.OTA.UI.MCPToolInspector.Assets;

var
  GInspector: TMCPInspectorForm = nil;

procedure ShowMCPInspector(const ABridge: IMCPInspectorBridge;
  const AToolsJson: string);
begin
  if not Assigned(GInspector) then
    GInspector := TMCPInspectorForm.CreateInspector(Application, ABridge, AToolsJson)
  else
  begin
    // Reused window: refresh the injected dependencies + re-push.
    GInspector.FBridge := ABridge;
    GInspector.FToolsJson := AToolsJson;
    GInspector._Flush;
  end;
  GInspector.Show;
  GInspector.BringToFront;
end;

{ TMCPInspectorForm }

constructor TMCPInspectorForm.CreateInspector(AOwner: TComponent;
  const ABridge: IMCPInspectorBridge; const AToolsJson: string);
var
  LCfg: TWebViewConfig;
begin
  inherited CreateNew(AOwner);
  FBridge := ABridge;
  FToolsJson := AToolsJson;
  Caption := 'MCP Tool Inspector';
  Width := 760;
  Height := 660;
  Position := poScreenCenter;
  OnClose := _OnFormClose;

  FBrowser := TAefosWebView.Create(Self);
  // Configure (UserDataFolder etc.) before Parent so the composition host is
  // created with these options - the same recipe the chat's EdgeController uses.
  LCfg := TWebViewConfig.Default;
  // Distinct user-data folder from the chat's: two SEPARATE WebView2 environments
  // sharing one folder makes the second composition controller fail with
  // ERROR_INVALID_STATE (0x8007139F) — proven via the host trace. A dedicated
  // folder gives the inspector its own browser process/state.
  LCfg.UserDataFolder := TPath.Combine(TPath.GetTempPath, 'Aefos_WebView2_Inspector');
  FBrowser.Configure(LCfg);
  FBrowser.OnReady := _OnReady;
  FBrowser.OnNavigationCompleted := _OnNav;
  FBrowser.OnMessageReceived := _OnHostMsg;
  FBrowser.Parent := Self;
  FBrowser.Align := alClient;
  _EnsureNavigated;
end;

destructor TMCPInspectorForm.Destroy;
begin
  if Assigned(FBrowser) then
  begin
    FBrowser.OnReady := nil;
    FBrowser.OnNavigationCompleted := nil;
    FBrowser.OnMessageReceived := nil;
  end;
  if GInspector = Self then
    GInspector := nil;
  FBridge := nil;
  inherited;
end;

procedure TMCPInspectorForm._OnFormClose(Sender: TObject; var Action: TCloseAction);
begin
  Action := caFree; // free on close; Destroy nils the singleton
end;

procedure TMCPInspectorForm._EnsureNavigated;
var
  LFile: string;
begin
  if FNavigated or not Assigned(FBrowser) then
    Exit;
  FNavigated := True;
  // The composition host queues a Navigate issued before it is ready
  // (FPendingUrl), so no HandleNeeded / ready-gate is needed here.
  LFile := TPath.Combine(TPath.GetTempPath, 'aefos_mcp_inspector.html');
  TFile.WriteAllText(LFile, BuildInspectorHtml, TEncoding.UTF8);
  FBrowser.Navigate('file:///' + StringReplace(LFile, '\', '/', [rfReplaceAll]));
end;

procedure TMCPInspectorForm._OnReady;
begin
  // Our composition host does not reliably fire OnReady for a standalone (undocked)
  // inspector window the way Vcl.Edge's OnCreateWebViewCompleted did. Nothing gates
  // on FReady anymore - the page's own 'ready' postMessage (FPageLive) is the
  // authoritative "loaded, insSetTools defined, send me the tools" signal.
  FReady := True;
end;

procedure TMCPInspectorForm._OnNav(const ASuccess: Boolean);
begin
  if ASuccess then
  begin
    FPageLive := True;
    _Flush;
  end;
end;

procedure TMCPInspectorForm._Flush;
begin
  // Gate on the page being live (nav complete OR the page's 'ready' message), not on
  // the host's OnReady: FPageLive implies the WebView2 host is up (it navigated) and
  // the page's JS has defined insSetTools.
  if not (Assigned(FBrowser) and FPageLive) then
    Exit;
  if FToolsJson = '' then
    FToolsJson := '[]';
  FBrowser.ExecuteScript('window.insSetTools(' + FToolsJson + ');');
end;

procedure TMCPInspectorForm._OnHostMsg(const AMessage: string);
begin
  // The composition host already hands us the message as a Delphi string (it did
  // the TryGetWebMessageAsString + free internally), so just route it.
  _HandleHostMessage(AMessage);
end;

procedure TMCPInspectorForm._PostError(const AText: string);
var
  LStr: TJSONString;
begin
  if not (Assigned(FBrowser) and FPageLive) then
    Exit;
  LStr := TJSONString.Create(AText);
  try
    FBrowser.ExecuteScript('window.insSetError(' + LStr.ToJSON + ');');
  finally
    LStr.Free;
  end;
end;

procedure TMCPInspectorForm._HandleHostMessage(const AMessage: string);
var
  LVal: TJSONValue;
  LObj: TJSONObject;
  LTool: string;
  LArgs: TJSONObject;
  LArgsTemp: TJSONObject;
  LResult: TJSONObject;
begin
  if AMessage = 'ready' then
  begin
    FPageLive := True;
    _Flush;
    Exit;
  end;

  if AMessage.StartsWith('run:') then
  begin
    if not Assigned(FBridge) then
    begin
      _PostError('No MCP server is wired to this inspector.');
      Exit;
    end;
    LVal := TJSONObject.ParseJSONValue(AMessage.Substring(4));
    try
      if not (LVal is TJSONObject) then
        Exit;
      LObj := TJSONObject(LVal);
      LTool := LObj.GetValue<string>('tool', '');
      if LTool = '' then
      begin
        _PostError('No tool selected.');
        Exit;
      end;
      // 'args' is owned by LObj; default to an empty object if absent.
      LArgsTemp := nil;
      if not LObj.TryGetValue<TJSONObject>('args', LArgs) then
      begin
        LArgsTemp := TJSONObject.Create;
        LArgs := LArgsTemp;
      end;
      try
        try
          LResult := FBridge.HandleInspectorRequest(LTool, LArgs);
          try
            if Assigned(FBrowser) and FPageLive then
              FBrowser.ExecuteScript('window.insSetResult(' + LResult.ToJSON + ');');
          finally
            LResult.Free;
          end;
        except
          on E: Exception do
            _PostError(E.ClassName + ': ' + E.Message);
        end;
      finally
        LArgsTemp.Free; // only frees the temp empty object (nil otherwise)
      end;
    finally
      LVal.Free;
    end;
    Exit;
  end;
end;

end.
