unit Aefos.OTA.Chat.UI.AddonStoreForm;

(*
  Aefos.OTA.Chat.UI.AddonStoreForm - the addon store window.

  A shell around ONE control. Everything the user sees is the page in the
  WebView (assets\addon-store.html, embedded as RCDATA); everything the buttons
  DO is aefos.exe, reached through Aefos.OTA.Chat.Core.AddonStore. This unit is
  only the wire between them, and keeping it that thin is the point: the store
  list, the install rules and the trust decisions all live in one place already,
  and a second copy in Pascal would be free to disagree with the first.

  THE ONE RULE HERE: aefos.exe is run on a WORKER THREAD, never on the IDE main
  thread. TProcessRunner.Run blocks until the child finishes, and a store on a
  slow VPN would otherwise freeze the whole IDE - not this window, the IDE. The
  reply comes back through TThread.Queue, because touching the WebView from the
  worker is the other half of the same mistake.
*)

interface

uses
  Winapi.Windows,
  Winapi.Messages,
  System.SysUtils,
  System.Classes,
  Vcl.Graphics,
  Vcl.Controls,
  Vcl.Forms,
  Aefos.WebView.Types,
  Aefos.WebView.Control;

type
  TAefosAddonStoreForm = class(TForm)
    AefosWebView1: TAefosWebView;
  private
    FBusy: Boolean;
    procedure _WebViewReady;
    procedure _WebViewFailed(const AHResult: HRESULT);
    procedure _WebViewMessage(const AMessage: string);
    procedure _SendTheme;
    procedure _LoadCatalog;
    procedure _RunAction(const AAction, ASlug, ASource: string);
    procedure _LoadSources;
    procedure _RunSourceEdit(const AAction, AName, AKind, ALocation: string);
    procedure _CallPage(const AFunc, AJsonArg: string);
    procedure _PageLog(const AText: string);
  public
    { Configures the WebView and wires its events HERE, before anything else can
      touch the control. The host bakes its config in on the first CreateWnd,
      and a handle can be allocated by something as innocent as walking the
      children to apply a theme - after which Configure is ignored, because the
      host already exists. That is the chat's documented order ("Configure
      BEFORE the handle exists", "wire events BEFORE Parent"); doing it in the
      constructor is the only way to be sure nothing got there first. }
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    { The window frees itself on close, because it is shown MODELESS - see
      Execute for why it cannot be modal. }
    procedure DoClose(var AAction: TCloseAction); override;

    { Opens the store. One window at a time on purpose: two of them would show
      two catalogues that disagree the moment either one installs something. }
    class procedure Execute; static;
  end;

implementation

uses
  System.IOUtils,
  System.JSON,
  Aefos.OTA.Chat.Core.AddonStore,
  Aefos.OTA.UI.ThemeHelper;

{$R *.dfm}
{$R 'Aefos.OTA.Chat.UI.AddonStore.res'}

const
  CHtmlResource = 'AEFOS_ADDON_STORE_HTML';

var
  // The live instance, so a second call raises the existing window instead of
  // opening a rival copy. Nil-ed in the finally of Execute, which is the only
  // place that creates it.
  GStoreForm: TAefosAddonStoreForm = nil;

// Joins the WebView control/host trace, in the same file and behind the same
// switch (AEFOS_WEBVIEW_TRACE), so an open reads top to bottom as one story:
// this window, then the control, then the host.
procedure _StoreLog(const S: string);
begin
  if GetEnvironmentVariable('AEFOS_WEBVIEW_TRACE') = '' then
    Exit;
  try
    TFile.AppendAllText(WebViewTraceFile, 'store: ' + S + sLineBreak,
      TEncoding.UTF8);
  except
    // tracing is best-effort; never let it break the pipeline
  end;
end;

// The page is embedded, but WebView2 navigates to a URL, so it has to exist as
// a file somewhere. Written fresh on every open: the copy on disk is a cache of
// the resource, never a thing a user is expected to edit, and rewriting it is
// cheaper than deciding whether a stale one is still good.
function _MaterialisePage: string;
var
  LStream: TResourceStream;
  LDir: string;
begin
  LDir := TPath.Combine(TPath.Combine(GetEnvironmentVariable('APPDATA'), 'Aefos'),
    'webview');
  ForceDirectories(LDir);
  Result := TPath.Combine(LDir, 'addon-store.html');
  LStream := TResourceStream.Create(HInstance, CHtmlResource, RT_RCDATA);
  try
    LStream.SaveToFile(Result);
  finally
    LStream.Free;
  end;
end;

// A JavaScript string literal, built here rather than by concatenation at the
// call site: the CLI's output travels through it, and that output contains
// Windows paths (backslashes) and quotes as a matter of course. TJSONString
// escapes both, and its result is already wrapped in the quotes JS wants.
function _JsString(const AValue: string): string;
var
  LStr: TJSONString;
begin
  LStr := TJSONString.Create(AValue);
  try
    Result := LStr.ToJSON;
  finally
    LStr.Free;
  end;
end;

function _StrOf(const AObj: TJSONObject; const AKey: string): string;
var
  LVal: TJSONValue;
begin
  Result := '';
  if AObj = nil then
    Exit;
  LVal := AObj.Values[AKey];
  if LVal is TJSONString then
    Result := TJSONString(LVal).Value;
end;

constructor TAefosAddonStoreForm.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  // First thing after the .dfm is streamed and before any caller can reach the
  // control. Its OWN folder, like every other pane here: Default leaves it
  // empty, which sends WebView2 to keep its user data beside bds.exe, and
  // sharing the chat's would couple this window to the chat's browser
  // arguments (see TWebViewConfig.ForPane).
  AefosWebView1.Configure(TWebViewConfig.ForPane('AddonStore'));
  AefosWebView1.OnReady := _WebViewReady;
  AefosWebView1.OnMessageReceived := _WebViewMessage;
  AefosWebView1.OnFailed := _WebViewFailed;
  _StoreLog('configured');
end;

destructor TAefosAddonStoreForm.Destroy;
begin
  // The single-instance check in Execute reads this, so it has to be cleared by
  // whoever actually dies - the window frees itself now, not the caller.
  if GStoreForm = Self then
    GStoreForm := nil;
  inherited;
end;

procedure TAefosAddonStoreForm.DoClose(var AAction: TCloseAction);
begin
  inherited DoClose(AAction);
  AAction := caFree;
end;

class procedure TAefosAddonStoreForm.Execute;
begin
  if Assigned(GStoreForm) then
  begin
    GStoreForm.BringToFront;
    Exit;
  end;
  _StoreLog('opening');
  GStoreForm := TAefosAddonStoreForm.Create(nil);
  TThemeHelper.ApplyPremiumTheme(GStoreForm);
  GStoreForm.AefosWebView1.Navigate('file:///' +
    StringReplace(_MaterialisePage, '\', '/', [rfReplaceAll]));
  // MODELESS, and that is not a preference. Shown with ShowModal, the WebView2
  // composition controller never completed: the environment was created and
  // CreateCoreWebView2CompositionController returned S_OK, but its completion
  // handler was never called, so the window sat on "Loading Aefos..." forever
  // with nothing failing (traced 2026-08-08). The modal loop disables the
  // application's other top-level windows, and the host's composition anchor is
  // one of them - a WS_POPUP created next to the control. Shown modeless, the
  // callback arrives. The store is a browsing window anyway; nothing about it
  // wants to block the IDE, and a single instance is still enforced above.
  GStoreForm.Show;
end;

procedure TAefosAddonStoreForm._CallPage(const AFunc, AJsonArg: string);
begin
  AefosWebView1.ExecuteScript(Format('window.aefosStore && window.aefosStore.%s(%s);',
    [AFunc, AJsonArg]));
end;

procedure TAefosAddonStoreForm._PageLog(const AText: string);
begin
  _CallPage('log', _JsString(AText));
end;

// The page paints itself from CSS variables, so the IDE's theme reaches it as
// four values rather than as a stylesheet. Dark/light is read from the colour
// ApplyPremiumTheme just resolved - the helper already asked the IDE (or fell
// back to luminance), and asking the same question twice is how two answers
// start to differ.
procedure TAefosAddonStoreForm._SendTheme;
var
  LRgb: Longint;
  LIsDark: Boolean;
begin
  LRgb := ColorToRGB(Color);
  LIsDark := ((0.299 * GetRValue(LRgb)) + (0.587 * GetGValue(LRgb)) +
              (0.114 * GetBValue(LRgb))) < 128;
  if LIsDark then
    _CallPage('theme',
      '{"bg":"#1e1e1e","fg":"#e7e7e7","muted":"#9a9a9a","line":"#333333",' +
      '"panel":"#252526"}')
  else
    _CallPage('theme',
      '{"bg":"#ffffff","fg":"#1f1f1f","muted":"#6a6a6a","line":"#dcdcdc",' +
      '"panel":"#f3f3f3"}');
end;

procedure TAefosAddonStoreForm._WebViewReady;
begin
  _StoreLog('OnReady');
  _SendTheme;
end;

// The page cannot report this - there is no page. So the window title carries
// it, because a WebView that never starts otherwise looks exactly like a store
// that is slow, and the first version of this window sat on "Loading Aefos..."
// with nothing anywhere saying why.
procedure TAefosAddonStoreForm._WebViewFailed(const AHResult: HRESULT);
begin
  _StoreLog(Format('OnFailed hr=%.8x', [Cardinal(AHResult)]));
  Caption := Format('Aefos Addons - WebView2 could not start (0x%.8x)',
    [Cardinal(AHResult)]);
end;

// Reading the catalogue is itself a shell-out that can block (an HTTP gallery,
// a share behind a VPN), so it goes to a worker exactly like an install does.
procedure TAefosAddonStoreForm._LoadCatalog;
begin
  if FBusy then
    Exit;
  FBusy := True;
  TThread.CreateAnonymousThread(
    procedure
    var
      LRes: TAddonStoreResult;
    begin
      LRes := TAefosAddonStore.CatalogJson;
      TThread.Queue(nil,
        procedure
        begin
          // The window may have gone while the child ran; the global is the
          // only honest way to ask, and it is nil-ed by the same Execute that
          // freed it.
          if not Assigned(GStoreForm) then
            Exit;
          FBusy := False;
          if LRes.Ok then
            _CallPage('data', LRes.Output)
          else
          begin
            // A failure here is not "no addons" - the page must not read as an
            // empty store when the manager could not even be asked.
            _PageLog(LRes.Output);
            _CallPage('data', '{"addons":[],"errors":[{"source":"aefos.exe",' +
              '"origin":"official","message":' + _JsString(Trim(LRes.Output)) + '}]}');
          end;
        end);
    end).Start;
end;

procedure TAefosAddonStoreForm._RunAction(const AAction, ASlug, ASource: string);
begin
  if FBusy then
    Exit;
  FBusy := True;
  TThread.CreateAnonymousThread(
    procedure
    var
      LRes: TAddonStoreResult;
    begin
      if SameText(AAction, 'install') then
        LRes := TAefosAddonStore.Install(ASlug, ASource)
      else if SameText(AAction, 'update') then
        LRes := TAefosAddonStore.Update(ASlug, ASource)
      else
        LRes := TAefosAddonStore.Remove(ASlug);
      TThread.Queue(nil,
        procedure
        begin
          if not Assigned(GStoreForm) then
            Exit;
          FBusy := False;
          _PageLog(LRes.Output);
          _CallPage('done', '');
          // Re-read rather than patch the row in place: the install may have
          // changed more than the row it was fired from (a shared dependency,
          // a version), and a list that disagrees with the ledger is worse
          // than a list that took a second to refresh.
          _LoadCatalog;
        end);
    end).Start;
end;

// The store list, same shape of trip as the catalogue: shelling out can block on
// nothing worse than a disk, but it is the same runner with the same rule.
procedure TAefosAddonStoreForm._LoadSources;
begin
  if FBusy then
    Exit;
  FBusy := True;
  TThread.CreateAnonymousThread(
    procedure
    var
      LRes: TAddonStoreResult;
    begin
      LRes := TAefosAddonStore.SourcesJson;
      TThread.Queue(nil,
        procedure
        begin
          if not Assigned(GStoreForm) then
            Exit;
          FBusy := False;
          if LRes.Ok then
            _CallPage('sources', LRes.Output)
          else
            // An empty panel would read as "you have no stores", which is never
            // true - the official one always exists. Say what actually happened.
            _CallPage('sourceError', _JsString(Trim(LRes.Output)));
        end);
    end).Start;
end;

// Add / remove / enable / disable. Every one of them ends the same way: ask the
// CLI again, because the panel draws the FILE rather than what it hoped the edit
// did. BOTH answers are re-read on this one worker instead of queueing two more:
// a store going on or off changes which addons exist at all, and FBusy would
// have let the first re-read start and made the second one return silently.
procedure TAefosAddonStoreForm._RunSourceEdit(const AAction, AName, AKind,
  ALocation: string);
begin
  if FBusy then
    Exit;
  FBusy := True;
  TThread.CreateAnonymousThread(
    procedure
    var
      LRes, LSources, LCatalog: TAddonStoreResult;
    begin
      if SameText(AAction, 'sourceAdd') then
        LRes := TAefosAddonStore.SourceAdd(AName, AKind, ALocation)
      else if SameText(AAction, 'sourceRemove') then
        LRes := TAefosAddonStore.SourceRemove(AName)
      else
        LRes := TAefosAddonStore.SourceEnable(AName,
          SameText(AAction, 'sourceEnable'));
      if LRes.Ok then
      begin
        LSources := TAefosAddonStore.SourcesJson;
        LCatalog := TAefosAddonStore.CatalogJson;
      end;
      TThread.Queue(nil,
        procedure
        begin
          if not Assigned(GStoreForm) then
            Exit;
          FBusy := False;
          // A refusal is the CLI's own sentence, shown on the form that caused
          // it. It is the whole point of routing edits through the one writer:
          // the rule and its wording live together.
          if not LRes.Ok then
          begin
            _CallPage('sourceError', _JsString(Trim(LRes.Output)));
            Exit;
          end;
          if LSources.Ok then
            _CallPage('sources', LSources.Output);
          if LCatalog.Ok then
            _CallPage('data', LCatalog.Output);
        end);
    end).Start;
end;

procedure TAefosAddonStoreForm._WebViewMessage(const AMessage: string);
var
  LVal: TJSONValue;
  LObj: TJSONObject;
  LAction: string;
begin
  LVal := TJSONObject.ParseJSONValue(AMessage);
  try
    if not (LVal is TJSONObject) then
      Exit;
    LObj := TJSONObject(LVal);
    LAction := _StrOf(LObj, 'action');
    if (LAction = 'ready') or (LAction = 'refresh') then
      _LoadCatalog
    else if LAction = 'openSources' then
      _LoadSources
    else if LAction = 'sourceAdd' then
      _RunSourceEdit(LAction, _StrOf(LObj, 'name'), _StrOf(LObj, 'kind'),
        _StrOf(LObj, 'location'))
    else if (LAction = 'sourceRemove') or (LAction = 'sourceEnable') or
            (LAction = 'sourceDisable') then
      _RunSourceEdit(LAction, _StrOf(LObj, 'name'), '', '')
    else if (LAction = 'install') or (LAction = 'update') or
            (LAction = 'remove') then
      _RunAction(LAction, _StrOf(LObj, 'slug'), _StrOf(LObj, 'source'));
  finally
    LVal.Free;
  end;
end;

end.
