unit Aefos.OTA.Chat.UI.OutputPanel.EdgeController;

{
  WebView2 output controller (ESP-002, ADR-241).

  Owns a TEdgeBrowser, the FPending/FReady lifecycle, navigation to the
  HTML shell assembled by the render-protocol seam, and BeginEvalScript
  for the IOutputPanelInspector delegation. Uses RenderProtocol.pas for
  all string generation so the logic lives in one testable copy.

  No ToolsAPI dependency: this unit uses only Vcl.* and the seam. The
  docked panel (which does use ToolsAPI) hosts this controller; the
  controller itself is safe to reference from anywhere that can use Vcl.
}

interface

uses
  System.SysUtils,
  System.IOUtils,
  System.Generics.Collections,
  System.JSON,
  Winapi.Windows,
  Winapi.ActiveX,
  Vcl.Controls,
  Aefos.OTA.Chat.UI.OutputPanel.Edge, // TInspectorEvalProc (IOutputPanelInspector contract)
  Aefos.WebView.Types,
  Aefos.WebView.Control,
  Aefos.OTA.Chat.Core.OutputPanel.RenderProtocol;

type
  TWebViewFailedCallback = reference to procedure(const AHResult: HRESULT);
  // Fired (main thread) when the page calls window.chrome.webview.postMessage(s);
  // carries the raw string s (e.g. 'action:explain' from an empty-state chip).
  THostMessageCallback = reference to procedure(const AMessage: string);

  // One recorded turn, kept so the WebView2 DOM can be rebuilt (dsReplay) after a
  // re-dock recreates the browser handle and the conversation DOM is lost.
  TChatMsgRole = (cmrUser, cmrAssistant);
  TChatMsg = record
    Role: TChatMsgRole;
    Text: string;
  end;

  TOutputPanelEdgeController = class
  private
    FBrowser: TAefosWebView; // composition-hosted WebView2 (blink-free); name kept
    FQueue: TRenderPendingQueue;
    FReady: Boolean;
    FWebViewFailed: Boolean;
    FWebViewFailedHResult: HRESULT;
    FNavigated: Boolean;
    FRenavPending: Boolean;   // debounces RenavigateAfterRecreate across the
                              // _ApplyTheme/RecreateWnd re-entrancy; cleared on nav done
    FShellReloadTried: Boolean; // ReloadShellOnce is a single-shot recovery
    FOnWebViewFailed: TWebViewFailedCallback;
    FOnHostMessage: THostMessageCallback;
    FHistory: TList<TChatMsg>;
    FAsstIdx: Integer;
    FFirstNavDone: Boolean;
    // Turn state the replayed bubbles alone don't carry. A replay lands on a
    // fresh page (busy=false, default footer): without restoring this it lied
    // whenever it ran mid-turn (no Stop button) or dropped the last footer.
    FInTurn: Boolean;          // a Clear (turn start) with no Footer yet
    FLastFooterText: string;   // last EnqueueFooter text ('' = never set)
    FLastFooterErr: Boolean;
    // Tracks the WebView2's REAL keyboard focus via the controller's
    // GotFocus/LostFocus COM events (surfaced as the browser's OnEnter/OnExit).
    // GetFocus() can't be trusted for this: the focused window may belong to
    // the browser process, so the IDE thread's view of it is unreliable.
    FBrowserFocused: Boolean;
    procedure _OnBrowserEnter(Sender: TObject);
    procedure _OnBrowserExit(Sender: TObject);
    procedure _OnHostMsg(const AMessage: string);
    procedure _OnReady;
    procedure _OnFailed(const AHResult: HRESULT);
    procedure _OnNav(const ASuccess: Boolean);
    // The one navigation path: write AHtml to a per-process, per-kind temp file
    // and load it over file:///. Both documents go through here so the temp-file
    // handling (and its history of clobbering bugs) has a single owner.
    procedure _NavigateDocument(const AHtml, AKind: string);
    procedure _RunScript(const AScript: string);
    procedure _RecordUser(const AText: string);
    procedure _RecordClear;
    procedure _RecordAppend(const AText: string);
    // Rebuild FHistory from a stored session's [{"role","text"},..] array so
    // GetHistoryJson mirrors a resumed conversation (else the next save wrote
    // '[]' over it — the resume-then-save corruption).
    procedure _AdoptHistory(const AMessagesJson: string);
    function _BuildReplayScript: string;
    procedure _ReplayHistory;
    function _GetBrowser: TWinControl;
  public
    constructor Create(const AParent: TWinControl);
    destructor Destroy; override;
    // Initiates NavigateToString(BuildShell). Idempotent: subsequent calls
    // are no-ops once navigation has been started.
    procedure Navigate; overload;
    procedure Navigate(const ATheme: TPanelTheme); overload;
    // Loads the permission card ALONE instead of the chat shell, for the
    // borderless consent window. Same idempotence, same file:/// mechanism --
    // only the document differs, and it differs by leaving everything out.
    procedure NavigateConsent(const ATheme: TPanelTheme);
    // Call when the host dock form's HWND was RECREATED (re-dock / desktop-layout
    // restore), which tears down the child WebView2 -> blank. Re-navigates so the
    // shell reloads and _ReplayHistory rebuilds the conversation. Self-guarded:
    // no-op if navigation never started (the first nav is handled by Navigate).
    procedure RenavigateAfterRecreate(const ATheme: TPanelTheme);
    // Recovery for a shell page whose embedded JS runtime came up broken (the
    // page posted 'shell-error:*', e.g. a truncated shell file left window.marked
    // undefined and every assistant bubble rendered empty). Rewrites the shell
    // file and re-navigates; _OnNav then replays the recorded conversation.
    // Single attempt per controller so a persistently broken shell cannot loop
    // navigate -> error -> navigate.
    procedure ReloadShellOnce(const ATheme: TPanelTheme);
    procedure EnqueueAppend(const AText: string);
    { The Visual Scanner card. NOT recorded into FHistory like a bubble: the card
      is one live element the payload keeps re-rendering, so replaying it on a
      reload would stack a copy per step instead of restoring one card. The
      broadcaster still holds the session and can repaint it after a reload. }
    procedure EnqueueScanner(const APayloadJson: string);
    { One screenshot for the card's store. Not recorded, for the same reason the
      card is not: it is state the broadcaster owns, not a transcript line. }
    procedure EnqueueScannerImage(const AImageId, ADataUri: string);
    procedure EnqueueClear;
    procedure EnqueueFooter(const AText: string; const AIsError: Boolean);
    procedure EnqueueUser(const AText: string);
    // Send-during-run queue counter ("N queued" under the typing line; 0 hides).
    // Transient UI — intentionally NOT recorded for replay: the ChatPanel
    // re-posts the live count on every queue/drain event.
    procedure EnqueueQueuedNotice(const ACount: Integer);
    // /new | /reset: drop the recorded conversation, reset the assistant-block
    // cursor and first-nav flag, and (when the page is live) tell the WebView2
    // DOM to clear the thread and re-show the empty-state (window.dsResetThread).
    procedure ResetConversation;
    // Opens the memory modal in the page, prefilled with AText. JSON-encodes the
    // text so any quote/newline/backslash is safely escaped into the JS call.
    procedure ShowMemory(const AText: string);
    // Opens the destructive-action permission modal, prefilled with the tool
    // name, a human summary and a content/detail preview (each JSON-escaped). The
    // page resolves by posting 'perm:once' / 'perm:session' / 'perm:deny' back.
    // Returns False (no-op) when the browser is not ready, so the caller can fall
    // back to the VCL modal. HidePermission closes it (used on timeout).
    function ShowPermission(const AToolName, ASummary, ADetail: string): Boolean;
    procedure HidePermission;
    // Feeds the HTML context line (#ds-ctx): session title, message count and a
    // human time string. JSON-encodes the two strings so quotes/newlines are
    // safely escaped (same pattern as ShowMemory). No-op until the page is live.
    procedure SetSessionInfo(const ATitle: string; const ACount: Integer;
      const ATime: string);
    // Sessions/history (ESP follow-up). GetHistoryJson serializes the recorded
    // conversation to the SAME [{"role":..,"text":..},..] array dsReplay/_Build-
    // ReplayScript use (just the array, no window.dsReplay wrapper) so it can be
    // persisted via SessionStore. ReplayMessages re-hydrates the page DOM from a
    // stored array (window.dsReplay). ShowSessions opens the sessions panel with
    // an array the ChatPanel assembled. All JSON is already valid → not re-escaped.
    function GetHistoryJson: string;
    procedure ReplayMessages(const AMessagesJson: string);
    procedure ShowSessions(const AJson: string);
    // Command (command) editor modal. ShowCommandEditor opens the HTML modal
    // prefilled from AJson — an object {name,description,prompt,isNew} the
    // ChatPanel assembled (empty/{} = a blank "new" form). SetCommandList feeds
    // the "edit existing" dropdown an array the ChatPanel assembled. Both are
    // already valid JSON (built via System.JSON) → dropped in without re-escaping.
    procedure ShowCommandEditor(const AJson: string);
    procedure SetCommandList(const AJson: string);
    // MCP Servers modal. AJson is the user's mcp-config object
    // ({"mcpServers":{...}}) the ChatPanel loaded from disk; AAddonsJson is the
    // installed addons' aggregate (~/.aefos/addons/mcp-servers.json), rendered
    // read-only with an ADDON badge — managed by `aefos install/remove`, never
    // saved back from the modal. Either doc degrades to {} when empty or
    // malformed. No-op until the page is live.
    procedure ShowMcpServers(const AJson, AAddonsJson: string);
    // Appends text (an attached file path / pasted-image temp path) to the
    // composer input and focuses it. JSON-escaped so a Windows path's
    // backslashes survive intact into the JS call.
    procedure AppendInputText(const AText: string);
    // REPLACES the composer input with AText and focuses it (caret at the end) —
    // the welcome-shortcut / toolbar slash-command prefill. JSON-escaped.
    procedure PrefillComposer(const AText: string);
    // Adds an attachment chip (paperclip file / pasted image). APath = the file
    // path (the prompt references it on send); AKind = 'image'|'file'; AThumb =
    // a data: URL for images ('' = none → file-icon card). All JSON-escaped.
    procedure AddAttachment(const APath, AKind, AThumb: string);
    // Feeds the header model selector. AJson = {"models":[...],"current":"..."}.
    procedure SetModelsJson(const AJson: string);
    // Feeds the persistent Trial badge in the header. '' hides it. The text is
    // controlled (no quotes), so a quote-strip keeps the single-quoted JS literal
    // safe. No-op until the page is live.
    procedure SetTrialBadge(const AText: string);
    // Inserts AText at the input textarea caret (host-injected paste — the IDE
    // swallows Ctrl+V, so the ChatPanel reads the clipboard and calls this).
    procedure InsertTextAtCursor(const AText: string);
    // Runs document.execCommand(ACommand) against the page's focused editable
    // ('copy' | 'cut' | 'selectAll' | 'undo'). Used by the ChatPanel's
    // root-form shortcut hook to perform the editing keys it reserves from the
    // IDE while the composer owns the focus.
    procedure ExecEditingCommand(const ACommand: string);
    // True while the WebView2 owns the keyboard focus (GotFocus..LostFocus).
    property BrowserFocused: Boolean read FBrowserFocused;
    // Sets the header Chat|Agent toggle visually without posting back (Pascal
    // already knows the mode). Used by /new-project to force Agent.
    procedure SetAgentToggle(const AAgent: Boolean);
    // Replaces the slash-picker command list (static built-ins + registered
    // commands). AJson is a [{name,desc,badge}] array fed by ChatPanel.
    procedure SetPickerCommands(const AJson: string);
    // New Project wizard (native, /new-project): ShowNewProject opens the modal
    // fed with the template list; NewProjBrowse fills the folder field after a
    // native folder pick; NewProjResult reports the create outcome back.
    procedure ShowNewProject(const ATemplatesJson: string);
    procedure NewProjBrowse(const APath: string);
    procedure NewProjResult(const AJson: string);
    // The WebView host control handle, for host-level focus checks (0 if absent).
    function BrowserHandle: HWND;
    // The composition WebView's hidden focus-host (anchor) window — MoveFocus puts
    // the Win32 focus there, so focus/keystroke checks must recognise it too.
    function BrowserAnchorHandle: HWND;
    // Gives the WebView2 the Win32 keyboard focus the CORRECT way (MoveFocus),
    // keeping the composer's content focus — unlike a raw Win32 SetFocus.
    procedure FocusComposer;
    function IsBrowserReady: Boolean;
    // Initiates a result-returning eval via the composition WebView callback.
    // Returns False when the browser is not ready (maps to not-initialized).
    function BeginEvalScript(const AScript: string;
      const AOnDone: TInspectorEvalProc): Boolean;
    property Browser: TWinControl read _GetBrowser;
    property WebViewFailed: Boolean read FWebViewFailed;
    property WebViewFailedHResult: HRESULT read FWebViewFailedHResult;
    // Fires on the main thread when OnCreateWebViewCompleted returns a non-zero
    // HRESULT. Set before the first Navigate call. Used for status-bar diagnostics.
    property OnWebViewFailed: TWebViewFailedCallback
      read FOnWebViewFailed write FOnWebViewFailed;
    // JS->Pascal bridge: assign to receive window.chrome.webview.postMessage(s).
    property OnHostMessage: THostMessageCallback
      read FOnHostMessage write FOnHostMessage;
    // True once NavigateToString completed successfully (FQueue.SetReady called).
    // Scripts can execute reliably only after this point.
    function IsQueueReady: Boolean;
  end;

implementation

uses
  System.UITypes,
  Vcl.Dialogs;

var
  // One-time guard: the "WebView2 missing" notice shows once per IDE session
  // (re-docking recreates the controller and can re-fire CreateWebView failure).
  GWebViewNoticeShown: Boolean = False;

constructor TOutputPanelEdgeController.Create(const AParent: TWinControl);
var
  LCfg: TWebViewConfig;
begin
  inherited Create;
  FQueue := TRenderPendingQueue.Create(_RunScript);
  FHistory := TList<TChatMsg>.Create;
  FAsstIdx := -1;
  FBrowser := TAefosWebView.Create(AParent);
  // Composition-hosted WebView2: renders into a DirectComposition visual the DWM
  // composites independently of window activation/occlusion -> it does NOT blank
  // when the IDE loses the foreground / the dock re-layouts (the windowed
  // TEdgeBrowser's docked-blank bug). Configure BEFORE the handle exists; the host
  // bakes these in on creation. UserDataFolder: a writable temp subfolder. The
  // occlusion-disable arg is moot for composition but kept for parity.
  LCfg := TWebViewConfig.Default; // bg already opaque #1e1e1e (anti-flash)
  LCfg.UserDataFolder := TPath.Combine(TPath.GetTempPath, 'Aefos_WebView2');
  LCfg.AdditionalBrowserArguments := '--disable-features=CalculateNativeWinOcclusion';
  FBrowser.Configure(LCfg);
  // Wire events BEFORE Parent (setting Parent can create the handle, which kicks
  // off the host's async WebView2 creation that fires these back).
  FBrowser.OnReady := _OnReady;
  FBrowser.OnNavigationCompleted := _OnNav;
  FBrowser.OnMessageReceived := _OnHostMsg;
  FBrowser.OnFailed := _OnFailed;
  FBrowser.OnEnter := _OnBrowserEnter;
  FBrowser.OnExit := _OnBrowserExit;
  FBrowser.Parent := AParent;
  FBrowser.Align := alClient;
  FBrowser.Visible := False;
end;

destructor TOutputPanelEdgeController.Destroy;
begin
  if Assigned(FBrowser) then
  begin
    FBrowser.OnReady := nil;
    FBrowser.OnNavigationCompleted := nil;
    FBrowser.OnMessageReceived := nil;
    FBrowser.OnFailed := nil;
    FBrowser.OnEnter := nil;
    FBrowser.OnExit := nil;
  end;
  FQueue.Free;
  FHistory.Free;
  inherited;
end;

procedure TOutputPanelEdgeController._RunScript(const AScript: string);
begin
  if Assigned(FBrowser) and FReady then
    FBrowser.ExecuteScript(AScript);
end;

procedure TOutputPanelEdgeController._OnBrowserEnter(Sender: TObject);
begin
  FBrowserFocused := True;
end;

procedure TOutputPanelEdgeController._OnBrowserExit(Sender: TObject);
begin
  FBrowserFocused := False;
end;

procedure TOutputPanelEdgeController.ExecEditingCommand(const ACommand: string);
begin
  _RunScript('document.execCommand(''' + ACommand + ''');');
end;

procedure TOutputPanelEdgeController.SetAgentToggle(const AAgent: Boolean);
begin
  if AAgent then
    _RunScript('window.dsSetMode && window.dsSetMode("agent");')
  else
    _RunScript('window.dsSetMode && window.dsSetMode("chat");');
end;

procedure TOutputPanelEdgeController.SetPickerCommands(const AJson: string);
begin
  _RunScript('window.dsSetCommands && window.dsSetCommands(' + AJson + ');');
end;

procedure TOutputPanelEdgeController.SetTrialBadge(const AText: string);
begin
  _RunScript('window.dsSetTrial && window.dsSetTrial(''' +
    StringReplace(AText, '''', '', [rfReplaceAll]) + ''');');
end;

// --- conversation history (for re-dock replay) -----------------------------

procedure TOutputPanelEdgeController._RecordUser(const AText: string);
var
  LMsg: TChatMsg;
begin
  LMsg.Role := cmrUser;
  LMsg.Text := AText;
  FHistory.Add(LMsg);
  FAsstIdx := -1;
end;

procedure TOutputPanelEdgeController._RecordClear;
begin
  // A new response starts; the next appended chunk opens a fresh assistant
  // message (mirrors dsClear in the page).
  FAsstIdx := -1;
  FInTurn := True;
end;

procedure TOutputPanelEdgeController._RecordAppend(const AText: string);
var
  LMsg: TChatMsg;
begin
  if FAsstIdx < 0 then
  begin
    LMsg.Role := cmrAssistant;
    LMsg.Text := '';
    FHistory.Add(LMsg);
    FAsstIdx := FHistory.Count - 1;
  end;
  LMsg := FHistory[FAsstIdx];
  LMsg.Text := LMsg.Text + AText;
  FHistory[FAsstIdx] := LMsg;
end;

function TOutputPanelEdgeController.GetHistoryJson: string;
var
  LArr: TJSONArray;
  LObj: TJSONObject;
  LMsg: TChatMsg;
begin
  if FHistory.Count = 0 then
    Exit('[]');
  LArr := TJSONArray.Create;
  try
    for LMsg in FHistory do
    begin
      LObj := TJSONObject.Create;
      if LMsg.Role = cmrUser then
        LObj.AddPair('role', 'user')
      else
        LObj.AddPair('role', 'assistant');
      LObj.AddPair('text', LMsg.Text);
      LArr.AddElement(LObj);
    end;
    Result := LArr.ToJSON;
  finally
    LArr.Free;
  end;
end;

function TOutputPanelEdgeController._BuildReplayScript: string;
begin
  // Reuses GetHistoryJson so the serialization lives in one place; the only
  // difference is the window.dsReplay(...) wrapper for the in-process replay.
  Result := 'window.dsReplay(' + GetHistoryJson + ');';
end;

procedure TOutputPanelEdgeController._ReplayHistory;
var
  LScript: string;
begin
  if (FHistory.Count > 0) and FReady and Assigned(FBrowser) then
  begin
    LScript := _BuildReplayScript;
    // Re-apply the turn state on top of the rebuilt bubbles: mid-turn the page
    // must show working... + the Stop button (ClearScript), settled it must show
    // the last footer — dsReplay itself touches neither.
    if FInTurn then
      LScript := LScript + TRenderProtocol.ClearScript
    else if FLastFooterText <> '' then
      LScript := LScript + TRenderProtocol.FooterScript(FLastFooterText, FLastFooterErr);
    FBrowser.ExecuteScript(LScript);
  end;
end;

function TOutputPanelEdgeController._GetBrowser: TWinControl;
begin
  // Exposed as TWinControl so the ChatPanel (which only toggles .Visible) needs no
  // dependency on the webview unit; an upcast from TAefosWebView is implicit.
  Result := FBrowser;
end;

// JS -> Pascal: the empty-state chips (and the HTML input/command picker) call
// window.chrome.webview.postMessage('action:xxx'). The composition host extracts
// the string and hands it here on the main thread.
procedure TOutputPanelEdgeController._OnHostMsg(const AMessage: string);
begin
  if Assigned(FOnHostMessage) then
    FOnHostMessage(AMessage);
end;

procedure TOutputPanelEdgeController._OnReady;
begin
  // The composition WebView2 is created; scripts can run now. The dark pre-content
  // background (#1e1e1e, anti-flash) is applied via the host config, not here, so
  // there is no ControllerInterface poke. Do NOT drain the queue here — the HTML
  // shell is not loaded yet; FQueue.SetReady fires in _OnNav after the shell
  // navigation completes. Scripts enqueued before Navigate wait in FPending.
  FReady := True;
end;

procedure TOutputPanelEdgeController._OnFailed(const AHResult: HRESULT);
begin
  FWebViewFailed := True;
  FWebViewFailedHResult := AHResult;
  // Notify any listener (e.g. status bar) so failures are visible in Release.
  if Assigned(FOnWebViewFailed) then
    FOnWebViewFailed(AHResult);
  // One-time, user-facing notice (Release + Debug). A failed WebView2 create is
  // almost always the Evergreen Runtime being absent (HRESULT 0x8007007E = DLL not
  // found). The panel falls back to plain-text TRichEdit; this tells the user how
  // to restore rich rendering. Guarded so a re-dock never repeats it. ASCII-only
  // on purpose: this .pas has no UTF-8 BOM (accents would mojibake).
  if not GWebViewNoticeShown then
  begin
    GWebViewNoticeShown := True;
    Vcl.Dialogs.MessageDlg(
      'Aefos: the chat rich rendering uses the WebView2 Runtime '
      + '(Microsoft Edge), which cannot be started on this system '
      + '(usually because the runtime is not installed).'
      + sLineBreak + sLineBreak
      + 'The chat keeps working in plain-text mode.'
      + sLineBreak + sLineBreak
      + 'To enable markdown and code highlighting, install the WebView2 Runtime '
      + '(free) from https://aka.ms/webview2 and restart RAD Studio.'
      {$IFDEF DEBUG}
      + sLineBreak + sLineBreak + '[debug] HRESULT: 0x' + IntToHex(AHResult, 8)
      {$ENDIF},
      mtWarning, [mbOK], 0);
  end;
end;

procedure TOutputPanelEdgeController._OnNav(const ASuccess: Boolean);
begin
  // The composition host survives HWND recreates (it rebinds via Reparent), so the
  // conversation DOM is NOT lost on re-dock and this normally fires once. The
  // _ReplayHistory branch is kept defensively (e.g. an explicit re-navigate).
  if not ASuccess then
  begin
    // A reload superseding an in-flight navigation completes the OLD one with
    // success=False (OperationCanceled). That is NOT a broken WebView2 — the
    // reload's own completion settles the state; flagging it here would exile
    // the panel to the plain-text fallback for the rest of the session.
    if FRenavPending then
      Exit;
    FWebViewFailed := True;
    {$IFDEF DEBUG}
    Vcl.Dialogs.ShowMessage('Aefos WebView2 navigation FAILED (shell load). '
      + 'Check BuildShell output / the file:/// temp path / user-data folder lock.');
    {$ENDIF}
    Exit;
  end;
  FRenavPending := False;     // a re-nav (if any) completed
  if FFirstNavDone then
    _ReplayHistory            // rebuild the conversation into a fresh DOM
  else
  begin
    FFirstNavDone := True;
    FQueue.SetReady;          // first load: drain the live conversation queued so far
  end;
end;

procedure TOutputPanelEdgeController.Navigate;
begin
  Navigate(TPanelTheme.Dark);
end;

procedure TOutputPanelEdgeController.NavigateConsent(const ATheme: TPanelTheme);
begin
  _NavigateDocument(TRenderProtocol.BuildConsentDocument(ATheme), 'consent');
end;

procedure TOutputPanelEdgeController.Navigate(const ATheme: TPanelTheme);
begin
  _NavigateDocument(TRenderProtocol.BuildShell(ATheme), 'shell');
end;

procedure TOutputPanelEdgeController._NavigateDocument(const AHtml,
  AKind: string);
var
  LHtmlFile: string;
  LTmpFile: string;
begin
  if FNavigated then
    Exit;
  FNavigated := True;
  if Assigned(FBrowser) then
  begin
    FBrowser.HandleNeeded; // force the handle so the composition host gets created
    // Write shell to a temp file and navigate via file:/// URL.
    // data: URIs are blocked by WebView2 since Chromium 123 (security policy).
    // file:/// works reliably in both standalone EXE and BPL/bds.exe.
    // The name is PER-PROCESS and the write goes through a rename: a fixed
    // shared 'aefos_shell.html' let two IDE instances clobber each other's
    // write, and a page loaded from the truncated file rendered but had NO
    // window.marked — every assistant response came up blank (2026-07-06).
    // AKind keeps the two documents in separate files. Sharing one name would
    // let a consent window and the panel overwrite each other's page mid-load,
    // which is the same class of bug the per-process id already fixed.
    LHtmlFile := TPath.Combine(TPath.GetTempPath,
      Format('aefos_%s_%d.html', [AKind, GetCurrentProcessId]));
    LTmpFile := LHtmlFile + '.writing';
    TFile.WriteAllText(LTmpFile, AHtml, TEncoding.UTF8);
    if TFile.Exists(LHtmlFile) then
      TFile.Delete(LHtmlFile);
    TFile.Move(LTmpFile, LHtmlFile);
    FBrowser.Navigate('file:///' + StringReplace(LHtmlFile, '\', '/', [rfReplaceAll]));
  end;
end;

procedure TOutputPanelEdgeController.ReloadShellOnce(const ATheme: TPanelTheme);
begin
  if FShellReloadTried then
    Exit;
  FShellReloadTried := True;
  // The reload may supersede a navigation still in flight; FRenavPending keeps
  // that superseded nav's success=False completion from tripping FWebViewFailed.
  FRenavPending := True;
  // Re-arm Navigate (its FNavigated guard is what makes it once-only) and load
  // a freshly written shell. When the new page's navigation completes, _OnNav
  // takes the FFirstNavDone branch and _ReplayHistory rebuilds the conversation
  // — including any responses the broken page swallowed (they are recorded in
  // FHistory by EnqueueAppend regardless of what the page did with them).
  FNavigated := False;
  Navigate(ATheme);
end;

procedure TOutputPanelEdgeController.RenavigateAfterRecreate(const ATheme: TPanelTheme);
begin
  // NO-OP with composition hosting. The windowed TEdgeBrowser lost its child
  // WebView2 on an HWND recreate (re-dock / desktop-layout) and needed a reload +
  // replay. The composition TAefosWebView keeps the SAME host across a recreate:
  // the controller's hidden anchor window survives and the DComp target is rebound
  // in the control's CreateWnd -> Reparent, so the DOM/conversation persists and
  // there is nothing to re-navigate. Kept (with the same signature) so the
  // ChatPanel's recreate hook needs no change. ATheme is intentionally unused.
end;

function TOutputPanelEdgeController.IsQueueReady: Boolean;
begin
  Result := FQueue.Ready;
end;

procedure TOutputPanelEdgeController.EnqueueAppend(const AText: string);
begin
  _RecordAppend(AText);
  FQueue.Enqueue(TRenderProtocol.AppendScript(AText));
end;

procedure TOutputPanelEdgeController.EnqueueScanner(
  const APayloadJson: string);
begin
  FQueue.Enqueue(TRenderProtocol.ScannerScript(APayloadJson));
end;

procedure TOutputPanelEdgeController.EnqueueScannerImage(const AImageId,
  ADataUri: string);
begin
  FQueue.Enqueue(TRenderProtocol.ScannerImageScript(AImageId, ADataUri));
end;

procedure TOutputPanelEdgeController.EnqueueClear;
begin
  _RecordClear;
  FQueue.Enqueue(TRenderProtocol.ClearScript);
end;

procedure TOutputPanelEdgeController.EnqueueFooter(const AText: string;
  const AIsError: Boolean);
begin
  // Footer = turn settled. Recorded (unlike the bubbles it is not in FHistory)
  // so a replay can restore the idle state instead of losing it — a lost
  // completion footer froze the page on "working..." and every send died in
  // the composer's _dsBusy gate (proven live 2026-07-07).
  FInTurn := False;
  FLastFooterText := AText;
  FLastFooterErr := AIsError;
  FQueue.Enqueue(TRenderProtocol.FooterScript(AText, AIsError));
end;

procedure TOutputPanelEdgeController.EnqueueUser(const AText: string);
begin
  _RecordUser(AText);
  FQueue.Enqueue(TRenderProtocol.UserScript(AText));
end;

procedure TOutputPanelEdgeController.EnqueueQueuedNotice(const ACount: Integer);
begin
  FQueue.Enqueue(TRenderProtocol.QueuedNoticeScript(ACount));
end;

procedure TOutputPanelEdgeController.ResetConversation;
begin
  // Clear the recorded conversation + the assistant-block cursor. Do NOT touch
  // FFirstNavDone: the page stays loaded (we only clear its DOM), so a later
  // re-dock must keep replaying — otherwise messages sent after a reset would be
  // lost on the next dock.
  FHistory.Clear;
  FAsstIdx := -1;
  FInTurn := False;
  FLastFooterText := '';
  if Assigned(FBrowser) and FReady then
    FBrowser.ExecuteScript('window.dsResetThread();');
end;

procedure TOutputPanelEdgeController.ShowMemory(const AText: string);
var
  LJson: TJSONString;
begin
  if not (Assigned(FBrowser) and FReady) then
    Exit;
  // TJSONString.ToString returns the text already wrapped in double quotes with
  // all JS-unsafe characters escaped, so it drops straight into the call. Own
  // the object so it isn't leaked (we are sensitive to FastMM teardown reports).
  LJson := TJSONString.Create(AText);
  try
    FBrowser.ExecuteScript('window.dsShowMemory(' + LJson.ToString + ');');
  finally
    LJson.Free;
  end;
end;

function TOutputPanelEdgeController.ShowPermission(const AToolName, ASummary,
  ADetail: string): Boolean;
var
  LObj: TJSONObject;
begin
  if not (Assigned(FBrowser) and FReady) then
    Exit(False);
  // {tool, summary, detail} built via TJSONObject so every field is escaped;
  // own + free it (FastMM teardown sensitivity, same pattern as ShowMemory).
  LObj := TJSONObject.Create;
  try
    LObj.AddPair('tool', AToolName);
    LObj.AddPair('summary', ASummary);
    LObj.AddPair('detail', ADetail);
    FBrowser.ExecuteScript('window.dsShowPermission(' + LObj.ToString + ');');
  finally
    LObj.Free;
  end;
  Result := True;
end;

procedure TOutputPanelEdgeController.HidePermission;
begin
  if Assigned(FBrowser) and FReady then
    FBrowser.ExecuteScript('window.dsHidePermission();');
end;

procedure TOutputPanelEdgeController.SetSessionInfo(const ATitle: string;
  const ACount: Integer; const ATime: string);
var
  LTitle, LTime: TJSONString;
begin
  if not (Assigned(FBrowser) and FReady) then
    Exit;
  // Own each TJSONString so it isn't leaked (we are sensitive to FastMM teardown
  // reports). ToString returns the value already quoted + JS-escaped, dropping
  // straight into the call; ACount is a plain integer.
  LTitle := TJSONString.Create(ATitle);
  try
    LTime := TJSONString.Create(ATime);
    try
      FBrowser.ExecuteScript('window.dsSetSessionInfo(' + LTitle.ToString +
        ', ' + IntToStr(ACount) + ', ' + LTime.ToString + ');');
    finally
      LTime.Free;
    end;
  finally
    LTitle.Free;
  end;
end;

procedure TOutputPanelEdgeController._AdoptHistory(const AMessagesJson: string);
var
  LVal: TJSONValue;
  LItem: TJSONValue;
  LObj: TJSONObject;
  LMsg: TChatMsg;
begin
  FHistory.Clear;
  FAsstIdx := -1;
  if (Trim(AMessagesJson) = '') or (Trim(AMessagesJson) = '[]') then
    Exit;
  LVal := TJSONObject.ParseJSONValue(AMessagesJson);
  if LVal = nil then
    Exit;
  try
    if not (LVal is TJSONArray) then
      Exit;
    for LItem in TJSONArray(LVal) do
    begin
      if not (LItem is TJSONObject) then
        Continue;
      LObj := TJSONObject(LItem);
      if SameText(LObj.GetValue<string>('role', ''), 'user') then
        LMsg.Role := cmrUser
      else
        LMsg.Role := cmrAssistant;
      LMsg.Text := LObj.GetValue<string>('text', '');
      FHistory.Add(LMsg);
    end;
  finally
    LVal.Free;
  end;
end;

procedure TOutputPanelEdgeController.ReplayMessages(const AMessagesJson: string);
begin
  // AMessagesJson is the stored [{"role":..,"text":..},..] array — already valid
  // JSON, so it drops straight into the dsReplay call without re-escaping.
  // Re-seed the internal record FIRST so GetHistoryJson mirrors this session
  // (without it, the next _SaveCurrentSession overwrote the stored messages with
  // '[]' — corrupting the very session just resumed).
  _AdoptHistory(AMessagesJson);
  if not (Assigned(FBrowser) and FReady) then
    Exit;
  if (Trim(AMessagesJson) = '') or (Trim(AMessagesJson) = '[]') then
  begin
    // Nothing recorded to replay (e.g. a legacy/blank session): clear the feed
    // so switching sessions is VISIBLE instead of leaving the old one on screen.
    FBrowser.ExecuteScript('if(window.dsResetThread) window.dsResetThread();');
    Exit;
  end;
  FBrowser.ExecuteScript('window.dsReplay(' + AMessagesJson + ');');
end;

procedure TOutputPanelEdgeController.ShowMcpServers(const AJson, AAddonsJson: string);

  // The docs come from disk (user config / addon aggregate); a malformed one
  // interpolated into ExecuteScript would silently break the whole modal
  // script, so anything that does not parse to a JSON object degrades to {}.
  function _ObjectOrEmpty(const ADoc: string): string;
  var
    LVal: TJSONValue;
  begin
    Result := '{}';
    if Trim(ADoc) = '' then
      Exit;
    LVal := TJSONObject.ParseJSONValue(ADoc);
    try
      if LVal is TJSONObject then
        Result := ADoc;
    finally
      LVal.Free;  // nil-safe
    end;
  end;

begin
  if not (Assigned(FBrowser) and FReady) then
    Exit;
  FBrowser.ExecuteScript('window.dsShowMcp(' + _ObjectOrEmpty(AJson) + ',' +
    _ObjectOrEmpty(AAddonsJson) + ');');
end;

procedure TOutputPanelEdgeController.ShowNewProject(const ATemplatesJson: string);
begin
  // ATemplatesJson is a [{id,name,category,description,vars}] array — drops
  // straight into dsShowNewProject. No-op until the page is live.
  if not (Assigned(FBrowser) and FReady) then
    Exit;
  if ATemplatesJson = '' then
    FBrowser.ExecuteScript('window.dsShowNewProject([]);')
  else
    FBrowser.ExecuteScript('window.dsShowNewProject(' + ATemplatesJson + ');');
end;

procedure TOutputPanelEdgeController.NewProjBrowse(const APath: string);
var
  LJson: TJSONString;
begin
  if not (Assigned(FBrowser) and FReady) then
    Exit;
  LJson := TJSONString.Create(APath); // escapes backslashes in the Windows path
  try
    FBrowser.ExecuteScript('window.dsNewProjBrowse(' + LJson.ToString + ');');
  finally
    LJson.Free;
  end;
end;

procedure TOutputPanelEdgeController.NewProjResult(const AJson: string);
begin
  if not (Assigned(FBrowser) and FReady) then
    Exit;
  if AJson <> '' then
    FBrowser.ExecuteScript('window.dsNewProjResult(' + AJson + ');');
end;

procedure TOutputPanelEdgeController.AppendInputText(const AText: string);
var
  LJson: TJSONString;
begin
  if not (Assigned(FBrowser) and FReady) then
    Exit;
  // TJSONString quotes + escapes (so C:\a\b.pas -> "C:\\a\\b.pas") — drops
  // straight into the call. Own + free it (FastMM teardown sensitivity).
  LJson := TJSONString.Create(AText);
  try
    FBrowser.ExecuteScript('window.dsAppendInput(' + LJson.ToString + ');');
  finally
    LJson.Free;
  end;
end;

procedure TOutputPanelEdgeController.PrefillComposer(const AText: string);
var
  LJson: TJSONString;
begin
  if not (Assigned(FBrowser) and FReady) then
    Exit;
  LJson := TJSONString.Create(AText);
  try
    FBrowser.ExecuteScript('window.dsPrefillInput(' + LJson.ToString + ');');
  finally
    LJson.Free;
  end;
end;

procedure TOutputPanelEdgeController.SetModelsJson(const AJson: string);
begin
  // AJson is the {models,current} object the ChatPanel assembled — already valid
  // JSON, drops straight into dsModels. No-op until the page is live.
  if not (Assigned(FBrowser) and FReady) then
    Exit;
  if AJson = '' then
    Exit;
  FBrowser.ExecuteScript('window.dsModels(' + AJson + ');');
end;

procedure TOutputPanelEdgeController.InsertTextAtCursor(const AText: string);
var
  LJson: TJSONString;
begin
  if not (Assigned(FBrowser) and FReady) then
    Exit;
  LJson := TJSONString.Create(AText);
  try
    FBrowser.ExecuteScript('window.dsInsertAtCursor(' + LJson.ToString + ');');
  finally
    LJson.Free;
  end;
end;

function TOutputPanelEdgeController.BrowserHandle: HWND;
begin
  if Assigned(FBrowser) and FBrowser.HandleAllocated then
    Result := FBrowser.Handle
  else
    Result := 0;
end;

function TOutputPanelEdgeController.BrowserAnchorHandle: HWND;
begin
  if Assigned(FBrowser) then
    Result := FBrowser.AnchorHandle
  else
    Result := 0;
end;

procedure TOutputPanelEdgeController.FocusComposer;
begin
  // Composition mode has no child WebView2 HWND, so give the control the Win32
  // keyboard focus AND then MoveFocus(PROGRAMMATIC) so the WebView content (the
  // composer caret) takes focus. A raw Winapi SetFocus alone would not reach the
  // content; FocusWebView is the correct content-focus path.
  if not (Assigned(FBrowser) and FBrowser.HandleAllocated and FBrowser.CanFocus) then
    Exit;
  // Idempotent: if the WebView already owns the focus (the control or its hidden
  // focus anchor), do NOT re-focus. Re-MoveFocus would make the page re-post
  // 'composer:focus' -> FocusComposer -> ... a tight loop (trembling caret).
  if FBrowser.OwnsFocus then
    Exit;
  FBrowser.SetFocus;
  FBrowser.FocusWebView;
end;

procedure TOutputPanelEdgeController.AddAttachment(const APath, AKind, AThumb: string);
var
  LPath, LKind, LThumb: TJSONString;
begin
  if not (Assigned(FBrowser) and FReady) then
    Exit;
  // Each arg quoted + escaped (path backslashes -> \\, the thumb data URL is safe
  // too). Own + free each (FastMM teardown sensitivity).
  LPath := TJSONString.Create(APath);
  try
    LKind := TJSONString.Create(AKind);
    try
      LThumb := TJSONString.Create(AThumb);
      try
        FBrowser.ExecuteScript('window.dsAddAttachment(' + LPath.ToString + ', ' +
          LKind.ToString + ', ' + LThumb.ToString + ');');
      finally
        LThumb.Free;
      end;
    finally
      LKind.Free;
    end;
  finally
    LPath.Free;
  end;
end;

procedure TOutputPanelEdgeController.ShowSessions(const AJson: string);
begin
  // AJson is the sessions array assembled (and escaped) by the ChatPanel via
  // TJSONArray; it drops straight into the dsShowSessions call. No-op until live.
  if not (Assigned(FBrowser) and FReady) then
    Exit;
  if AJson = '' then
    Exit;
  FBrowser.ExecuteScript('window.dsShowSessions(' + AJson + ');');
end;

procedure TOutputPanelEdgeController.ShowCommandEditor(const AJson: string);
begin
  // AJson is the {name,description,prompt,isNew} object the ChatPanel built via
  // TJSONObject — already valid JSON, so it drops straight into the call. '' or
  // '{}' opens a blank "new" form. No-op until the page is live.
  if not (Assigned(FBrowser) and FReady) then
    Exit;
  if AJson = '' then
    FBrowser.ExecuteScript('window.dsShowCommandEditor({});')
  else
    FBrowser.ExecuteScript('window.dsShowCommandEditor(' + AJson + ');');
end;

procedure TOutputPanelEdgeController.SetCommandList(const AJson: string);
begin
  // AJson is the editable-commands array the ChatPanel built via TJSONArray —
  // already valid JSON, dropped straight into the dropdown. No-op until live.
  if not (Assigned(FBrowser) and FReady) then
    Exit;
  if AJson = '' then
    Exit;
  FBrowser.ExecuteScript('window.dsSetCommandList(' + AJson + ');');
end;

function TOutputPanelEdgeController.IsBrowserReady: Boolean;
begin
  Result := Assigned(FBrowser) and FReady;
end;

function TOutputPanelEdgeController.BeginEvalScript(const AScript: string;
  const AOnDone: TInspectorEvalProc): Boolean;
var
  LOnDone: TInspectorEvalProc;
  LCb: TWebViewScriptResult;
begin
  Result := Assigned(FBrowser) and FReady;
  if not Result then
    Exit;
  // Adapt the host's result callback (err, json) to the IOutputPanelInspector
  // contract TInspectorEvalProc (Sender, err, json). There is no TEdgeBrowser
  // Sender in composition mode, so pass nil — callers use the JSON result, not it.
  // Assign to a typed local first so the overloaded ExecuteScript resolves.
  LOnDone := AOnDone;
  LCb := procedure(const AErrorCode: HRESULT; const AResultJson: string)
    begin
      if Assigned(LOnDone) then
        LOnDone(nil, AErrorCode, AResultJson);
    end;
  FBrowser.ExecuteScript(AScript, LCb);
end;

end.
