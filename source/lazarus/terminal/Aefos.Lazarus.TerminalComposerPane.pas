unit Aefos.Lazarus.TerminalComposerPane;

{$IFDEF FPC}{$mode delphi}{$H+}{$ENDIF}

{
  WebView2-backed AI composer bar for the Lazarus terminal footer (Aefos ->
  Lazarus, terminal AI slice). The LCL twin of the Delphi
  source\terminal\UI\Aefos.OTA.Terminal.UI.ComposerWebPane.pas: it hosts the
  composition TAefosLazWebView (the same own-SDK WebView2 host the Lazarus chat
  window uses) and navigates it to the SHARED composer document
  (Aefos.OTA.Terminal.UI.ComposerHtml.BuildComposerHtml) -- byte-identical markup
  to the Delphi composer, so the bar looks PIXEL-IDENTICAL across both editions
  (rounded dark textarea, paperclip/brain icons, orange round send).

  The bar is only the chat-style INPUT. The '/' picker is a separate floating LCL
  control (Aefos.Lazarus.TerminalComposerPicker) the host owns; this pane just
  relays the user's keyboard intent so focus can stay in the textarea.

  Bridge (identical to the Delphi ComposerWebPane, since the HTML is shared):
    Pascal -> JS : window.dsClear()
                   window.dsSetAttachments(list)    // list of id/name records
    JS -> Pascal : 'ready' | 'height:<px>' | 'send:<text>'
                 | 'filter:<query>' | 'navdown' | 'navup' | 'commit' | 'cancel'
                 | 'attach:open' | 'attach:remove:<id>' | 'memory:open'

  All literals are ASCII -- this file needs no BOM.
}

interface

uses
  Classes,
  SysUtils,
  Controls,
  Aefos.WebView.Types,
  Aefos.Lazarus.WebViewHost;

type
  TAefosComposerSendEvent = procedure(Sender: TObject; const AText: string) of object;
  TAefosComposerHeightEvent = procedure(Sender: TObject;
    const AHeight: Integer) of object;
  TAefosComposerAttachRemoveEvent = procedure(Sender: TObject;
    const AId: string) of object;

  { The '/' picker keyboard intents relayed from the webview textarea. cpaFilter
    carries the query (input text after the leading '/'); the rest carry ''. }
  TAefosComposerPickerAction = (cpaFilter, cpaNavDown, cpaNavUp, cpaCommit, cpaCancel);
  TAefosComposerPickerEvent = procedure(Sender: TObject;
    AAction: TAefosComposerPickerAction; const AQuery: string) of object;

  TAefosLazTerminalComposerPane = class(TCustomControl)
  private
    FBrowser: TAefosLazWebView;
    FOnSend: TAefosComposerSendEvent;
    FOnRequestHeight: TAefosComposerHeightEvent;
    FOnPicker: TAefosComposerPickerEvent;
    FOnAttachOpen: TNotifyEvent;
    FOnAttachRemove: TAefosComposerAttachRemoveEvent;
    FOnMemoryOpen: TNotifyEvent;
    FReady: Boolean;
    FNavigated: Boolean;
    FPageLive: Boolean;
    procedure _OnReady;
    procedure _OnNav(const ASuccess: Boolean);
    procedure _OnHostMsg(const AMessage: string);
    procedure _EnsureNavigated;
  protected
    procedure Paint; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    // Ensures the page is navigated + focuses the input (called when shown).
    procedure Activate;
    // Clears the textarea (after the host injects a picked command).
    procedure ClearInput;
    // Pushes the current attachment chips to the webview. AIds / ANames are
    // parallel arrays (same length); an empty pair hides the chip bar.
    procedure SetAttachments(const AIds, ANames: array of string);
    property OnSend: TAefosComposerSendEvent read FOnSend write FOnSend;
    property OnRequestHeight: TAefosComposerHeightEvent
      read FOnRequestHeight write FOnRequestHeight;
    property OnPicker: TAefosComposerPickerEvent read FOnPicker write FOnPicker;
    property OnAttachOpen: TNotifyEvent read FOnAttachOpen write FOnAttachOpen;
    property OnAttachRemove: TAefosComposerAttachRemoveEvent
      read FOnAttachRemove write FOnAttachRemove;
    property OnMemoryOpen: TNotifyEvent read FOnMemoryOpen write FOnMemoryOpen;
  end;

implementation

uses
  Graphics,
  Aefos.OTA.Terminal.UI.ComposerHtml;

// Escapes a string for embedding inside a JS double-quoted literal.
function _JsEscape(const AText: string): string;
var
  LIndex: Integer;
  LCh: Char;
begin
  Result := '';
  for LIndex := 1 to Length(AText) do
  begin
    LCh := AText[LIndex];
    case LCh of
      '\': Result := Result + '\\';
      '"': Result := Result + '\"';
      #13: Result := Result + '\r';
      #10: Result := Result + '\n';
    else
      Result := Result + LCh;
    end;
  end;
end;

{ TAefosLazTerminalComposerPane }

constructor TAefosLazTerminalComposerPane.Create(AOwner: TComponent);
var
  LCfg: TWebViewConfig;
begin
  inherited Create(AOwner);
  FBrowser := TAefosLazWebView.Create(Self);
  LCfg := TWebViewConfig.Default;
  // OWN user-data folder, distinct from the chat's (Aefos_WebView2_Lazarus_*) and
  // the Delphi terminal composer's: WebView2 fails a second environment creation on
  // a shared folder with differing args (the per-window-folder gotcha).
  LCfg.UserDataFolder := IncludeTrailingPathDelimiter(GetTempDir)
    + 'Aefos_WebView2_Lazarus_Terminal_Composer';
  FBrowser.Configure(LCfg);
  FBrowser.OnReady := _OnReady;
  FBrowser.OnNavigationCompleted := _OnNav;
  FBrowser.OnMessageReceived := _OnHostMsg;
  FBrowser.Parent := Self;
  FBrowser.Align := alClient;
end;

destructor TAefosLazTerminalComposerPane.Destroy;
begin
  // Drop the event sinks before the inherited destructor frees FBrowser (owned by
  // Self): the host's own C1 liveness token already neutralises a late WebView2
  // callback, this is defence in depth (mirrors the Delphi ComposerWebPane).
  if Assigned(FBrowser) then
  begin
    FBrowser.OnReady := nil;
    FBrowser.OnNavigationCompleted := nil;
    FBrowser.OnMessageReceived := nil;
  end;
  inherited Destroy;
end;

procedure TAefosLazTerminalComposerPane.Paint;
begin
  // Dark fill behind the alClient WebView so the ~1-frame gap before the WebView2
  // presents its first frame reads as the dark shell, never a white flash.
  Canvas.Brush.Color := TColor($001E1E1E);
  Canvas.FillRect(ClientRect);
end;

procedure TAefosLazTerminalComposerPane._EnsureNavigated;
begin
  if FNavigated or not Assigned(FBrowser) then
    Exit;
  FNavigated := True;
  FBrowser.HandleNeeded;
  // NavigateToString feeds the SHARED composer document inline: no temp file, no
  // WebView2 UserDataFolder cache to serve a stale copy (the Delphi pane needs a
  // GUID file URL to dodge that cache; the string path sidesteps it entirely).
  FBrowser.NavigateToString(BuildComposerHtml);
end;

procedure TAefosLazTerminalComposerPane._OnReady;
begin
  FReady := True;
end;

procedure TAefosLazTerminalComposerPane._OnNav(const ASuccess: Boolean);
begin
  if ASuccess then
    FPageLive := True;
end;

procedure TAefosLazTerminalComposerPane._OnHostMsg(const AMessage: string);

  function _Has(const APrefix: string): Boolean;
  begin
    Result := Copy(AMessage, 1, Length(APrefix)) = APrefix;
  end;

  function _After(const APrefix: string): string;
  begin
    Result := Copy(AMessage, Length(APrefix) + 1, MaxInt);
  end;

begin
  if AMessage = 'ready' then
  begin
    FPageLive := True;
    Exit;
  end;
  if _Has('send:') then
  begin
    if Assigned(FOnSend) then
      FOnSend(Self, _After('send:'));
    Exit;
  end;
  if _Has('height:') then
  begin
    if Assigned(FOnRequestHeight) then
      FOnRequestHeight(Self, StrToIntDef(_After('height:'), 0));
    Exit;
  end;
  if _Has('filter:') then
  begin
    if Assigned(FOnPicker) then
      FOnPicker(Self, cpaFilter, _After('filter:'));
    Exit;
  end;
  if AMessage = 'navdown' then
  begin
    if Assigned(FOnPicker) then FOnPicker(Self, cpaNavDown, '');
    Exit;
  end;
  if AMessage = 'navup' then
  begin
    if Assigned(FOnPicker) then FOnPicker(Self, cpaNavUp, '');
    Exit;
  end;
  if AMessage = 'commit' then
  begin
    if Assigned(FOnPicker) then FOnPicker(Self, cpaCommit, '');
    Exit;
  end;
  if AMessage = 'cancel' then
  begin
    if Assigned(FOnPicker) then FOnPicker(Self, cpaCancel, '');
    Exit;
  end;
  if AMessage = 'attach:open' then
  begin
    if Assigned(FOnAttachOpen) then FOnAttachOpen(Self);
    Exit;
  end;
  if _Has('attach:remove:') then
  begin
    if Assigned(FOnAttachRemove) then
      FOnAttachRemove(Self, _After('attach:remove:'));
    Exit;
  end;
  if AMessage = 'memory:open' then
  begin
    if Assigned(FOnMemoryOpen) then FOnMemoryOpen(Self);
    Exit;
  end;
end;

procedure TAefosLazTerminalComposerPane.Activate;
begin
  _EnsureNavigated;
  if Assigned(FBrowser) and FReady and FPageLive then
    FBrowser.ExecuteScript(
      'try{document.getElementById("inp").focus();}catch(e){}');
end;

procedure TAefosLazTerminalComposerPane.ClearInput;
begin
  if Assigned(FBrowser) and FReady and FPageLive then
    FBrowser.ExecuteScript('try{window.dsClear();}catch(e){}');
end;

procedure TAefosLazTerminalComposerPane.SetAttachments(
  const AIds, ANames: array of string);
var
  LJson: string;
  LIndex: Integer;
begin
  if not (Assigned(FBrowser) and FReady and FPageLive) then
    Exit;
  LJson := '[';
  for LIndex := 0 to High(AIds) do
  begin
    if LIndex > 0 then
      LJson := LJson + ',';
    LJson := LJson + '{"id":"' + _JsEscape(AIds[LIndex]) + '","name":"'
      + _JsEscape(ANames[LIndex]) + '"}';
  end;
  LJson := LJson + ']';
  FBrowser.ExecuteScript(
    'try{window.dsSetAttachments(' + LJson + ');}catch(e){}');
end;

end.
