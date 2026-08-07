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
  Aefos.WebView.Control;

type
  TAefosAddonStoreForm = class(TForm)
    AefosWebView1: TAefosWebView;
  private
    FBusy: Boolean;
    procedure _WebViewReady;
    procedure _WebViewMessage(const AMessage: string);
    procedure _SendTheme;
    procedure _LoadCatalog;
    procedure _RunAction(const AAction, ASlug, ASource: string);
    procedure _CallPage(const AFunc, AJsonArg: string);
    procedure _PageLog(const AText: string);
  public
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

class procedure TAefosAddonStoreForm.Execute;
begin
  if Assigned(GStoreForm) then
  begin
    GStoreForm.BringToFront;
    Exit;
  end;
  GStoreForm := TAefosAddonStoreForm.Create(nil);
  try
    TThemeHelper.ApplyPremiumTheme(GStoreForm);
    GStoreForm.AefosWebView1.OnReady := GStoreForm._WebViewReady;
    GStoreForm.AefosWebView1.OnMessageReceived := GStoreForm._WebViewMessage;
    GStoreForm.AefosWebView1.Navigate('file:///' +
      StringReplace(_MaterialisePage, '\', '/', [rfReplaceAll]));
    GStoreForm.ShowModal;
  finally
    GStoreForm.Free;
    GStoreForm := nil;
  end;
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
  _SendTheme;
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
      // Not wired yet: saying so beats a button that does nothing, which the
      // user reads as the window being broken.
      _PageLog('Custom stores are configured in ~/.aefos/sources.json ' +
        '(the Options page is not wired yet).')
    else if (LAction = 'install') or (LAction = 'update') or
            (LAction = 'remove') then
      _RunAction(LAction, _StrOf(LObj, 'slug'), _StrOf(LObj, 'source'));
  finally
    LVal.Free;
  end;
end;

end.
