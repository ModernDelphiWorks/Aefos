unit Aefos.OTA.Terminal.UI.ComposerWebPane;

{
  WebView2-backed AI composer bar for the Terminal footer. Mirrors the proven
  TWelcomeWebPane lifecycle (composition TAefosWebView, own UserDataFolder,
  file:/// navigation, handlers nilled in Destroy) - no new dependency, since the
  terminal already ships Aefos.WebView.

  The bar is only the chat-style INPUT. The '/' picker is a separate floating VCL
  window (owned by the DockForm); this pane just relays the user's keyboard intent
  to the host so focus can stay in the textarea.

  Bridge:
    Pascal -> JS : window.dsClear()
                   window.dsSetAttachments(list)    // list of id/name records
    JS -> Pascal : 'ready' | 'height:<px>' | 'send:<text>'
                 | 'filter:<query>' | 'navdown' | 'navup' | 'commit' | 'cancel'
                 | 'attach:open' | 'attach:remove:<id>' | 'memory:open'

  On 'send:<text>' it fires OnSend with the raw line; the picker intents fire
  OnPicker; OnRequestHeight grows the footer for multi-line input. The paperclip
  fires OnAttachOpen, a chip's X fires OnAttachRemove(id), the brain fires
  OnMemoryOpen; SetAttachments pushes the current chip list back to the webview.
}

interface

uses
  System.Classes,
  System.Generics.Collections,
  Vcl.Controls,
  Vcl.ExtCtrls,
  Aefos.WebView.Types,
  Aefos.WebView.Control;

type
  TComposerSendEvent = procedure(Sender: TObject; const AText: string) of object;
  TComposerHeightEvent = procedure(Sender: TObject; const AHeight: Integer) of object;
  TComposerAttachRemoveEvent = procedure(Sender: TObject; const AId: string) of object;

  { The '/' picker keyboard intents relayed from the webview textarea. cpaFilter
    carries the query (input text after the leading '/'); the rest carry ''. }
  TComposerPickerAction = (cpaFilter, cpaNavDown, cpaNavUp, cpaCommit, cpaCancel);
  TComposerPickerEvent = procedure(Sender: TObject;
    AAction: TComposerPickerAction; const AQuery: string) of object;

  TComposerWebPane = class(TPanel)
  private
    FBrowser: TAefosWebView;
    FOnSend: TComposerSendEvent;
    FOnRequestHeight: TComposerHeightEvent;
    FOnPicker: TComposerPickerEvent;
    FOnAttachOpen: TNotifyEvent;
    FOnAttachRemove: TComposerAttachRemoveEvent;
    FOnMemoryOpen: TNotifyEvent;
    FReady: Boolean;
    FNavigated: Boolean;
    FPageLive: Boolean;
    procedure _OnReady;
    procedure _OnNav(const ASuccess: Boolean);
    procedure _OnHostMsg(const AMessage: string);
    procedure _EnsureNavigated;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    // Ensures the page is navigated + focuses the input (called when shown).
    procedure Activate;
    // Clears the textarea (after the host injects a picked command).
    procedure ClearInput;
    // Pushes the current attachment chips to the webview. AItems pairs are
    // (id, display name); an empty array hides the chip bar.
    procedure SetAttachments(const AItems: TArray<TPair<string, string>>);
    property OnSend: TComposerSendEvent read FOnSend write FOnSend;
    // Fired when multi-line text needs a taller bar (clamped by the host).
    property OnRequestHeight: TComposerHeightEvent
      read FOnRequestHeight write FOnRequestHeight;
    // Fired for every '/' picker keyboard intent (filter / nav / commit / cancel).
    property OnPicker: TComposerPickerEvent read FOnPicker write FOnPicker;
    // Fired when the paperclip is clicked (host opens a file picker).
    property OnAttachOpen: TNotifyEvent read FOnAttachOpen write FOnAttachOpen;
    // Fired when a chip's X is clicked; AId identifies the attachment to drop.
    property OnAttachRemove: TComposerAttachRemoveEvent
      read FOnAttachRemove write FOnAttachRemove;
    // Fired when the brain is clicked (host opens the global-memory editor).
    property OnMemoryOpen: TNotifyEvent read FOnMemoryOpen write FOnMemoryOpen;
  end;

implementation

uses
  System.SysUtils,
  System.IOUtils,
  System.JSON,
  Aefos.OTA.Terminal.UI.ComposerHtml;

constructor TComposerWebPane.Create(AOwner: TComponent);
var
  LCfg: TWebViewConfig;
begin
  inherited Create(AOwner);
  BevelOuter := bvNone;
  ParentBackground := False;

  FBrowser := TAefosWebView.Create(Self);
  LCfg := TWebViewConfig.Default;
  // OWN user-data folder (distinct from the chat's and the terminal welcome's):
  // WebView2 fails a second env creation on a shared folder with differing args.
  LCfg.UserDataFolder := TPath.Combine(TPath.GetTempPath,
    'Aefos_WebView2_Terminal_Composer');
  FBrowser.Configure(LCfg);
  FBrowser.OnReady := _OnReady;
  FBrowser.OnNavigationCompleted := _OnNav;
  FBrowser.OnMessageReceived := _OnHostMsg;
  FBrowser.Parent := Self;
  FBrowser.Align := alClient;
end;

destructor TComposerWebPane.Destroy;
begin
  if Assigned(FBrowser) then
  begin
    FBrowser.OnReady := nil;
    FBrowser.OnNavigationCompleted := nil;
    FBrowser.OnMessageReceived := nil;
  end;
  inherited;
end;

procedure TComposerWebPane._EnsureNavigated;
var
  LFile: string;
begin
  if FNavigated or not Assigned(FBrowser) then
    Exit;
  FNavigated := True;
  FBrowser.HandleNeeded;
  // UNIQUE filename per run: WebView2's persistent UserDataFolder would otherwise
  // serve a stale cached copy of a fixed URL across IDE sessions (why an updated
  // composer HTML kept rendering the old markup). A fresh GUID URL is never cached.
  LFile := TPath.Combine(TPath.GetTempPath,
    'aefos_composer_' + TPath.GetGUIDFileName(False) + '.html');
  TFile.WriteAllText(LFile, BuildComposerHtml, TEncoding.UTF8);
  FBrowser.Navigate('file:///' + StringReplace(LFile, '\', '/', [rfReplaceAll]));
end;

procedure TComposerWebPane._OnReady;
begin
  FReady := True;
end;

procedure TComposerWebPane._OnNav(const ASuccess: Boolean);
begin
  if ASuccess then
    FPageLive := True;
end;

procedure TComposerWebPane._OnHostMsg(const AMessage: string);
begin
  if AMessage = 'ready' then
  begin
    FPageLive := True;
    Exit;
  end;
  if AMessage.StartsWith('send:') then
  begin
    if Assigned(FOnSend) then
      FOnSend(Self, AMessage.Substring(5));
    Exit;
  end;
  if AMessage.StartsWith('height:') then
  begin
    if Assigned(FOnRequestHeight) then
      FOnRequestHeight(Self, StrToIntDef(AMessage.Substring(7), 0));
    Exit;
  end;
  if AMessage.StartsWith('filter:') then
  begin
    if Assigned(FOnPicker) then
      FOnPicker(Self, cpaFilter, AMessage.Substring(7));
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
  if AMessage.StartsWith('attach:remove:') then
  begin
    if Assigned(FOnAttachRemove) then
      FOnAttachRemove(Self, AMessage.Substring(Length('attach:remove:')));
    Exit;
  end;
  if AMessage = 'memory:open' then
  begin
    if Assigned(FOnMemoryOpen) then FOnMemoryOpen(Self);
    Exit;
  end;
end;

procedure TComposerWebPane.Activate;
begin
  _EnsureNavigated;
  if Assigned(FBrowser) and FReady and FPageLive then
    FBrowser.ExecuteScript(
      'try{document.getElementById("inp").focus();}catch(e){}');
end;

procedure TComposerWebPane.ClearInput;
begin
  if Assigned(FBrowser) and FReady and FPageLive then
    FBrowser.ExecuteScript('try{window.dsClear();}catch(e){}');
end;

procedure TComposerWebPane.SetAttachments(
  const AItems: TArray<TPair<string, string>>);
var
  LArr: TJSONArray;
  LObj: TJSONObject;
  LPair: TPair<string, string>;
  LJson: string;
begin
  if not (Assigned(FBrowser) and FReady and FPageLive) then
    Exit;
  LArr := TJSONArray.Create;
  try
    for LPair in AItems do
    begin
      LObj := TJSONObject.Create;
      LObj.AddPair('id', LPair.Key);
      LObj.AddPair('name', LPair.Value);
      LArr.AddElement(LObj);
    end;
    // ToJSON escapes for JS; the array literal is safe to inline in the call.
    LJson := LArr.ToJSON;
  finally
    LArr.Free;
  end;
  FBrowser.ExecuteScript(
    'try{window.dsSetAttachments(' + LJson + ');}catch(e){}');
end;

end.
