unit Aefos.OTA.Terminal.UI.WelcomeWebPane;

{
  WebView2-backed welcome/home pane (2026-06-09; ported to composition 2026-06-18).
  Drop-in for the VCL TWelcomePane: same public surface (OnLaunchProfile +
  BuildFromProfiles) so the DockForm swaps it in with no flow change. Hosts our
  composition TAefosWebView (blink-free, like the chat) that renders the chat-style
  HTML (WelcomeHtml.BuildWelcomeHtml) and bridges:

    Pascal -> JS : window.dsSetProfiles(json)
    JS -> Pascal : 'ready' | 'launch:<index>'

  Lifecycle mirrors the chat's EdgeController: Configure (UserDataFolder) BEFORE the
  handle; navigate via a file:/// temp URL; FReady set in OnReady, the page driven
  only after OnNavigationCompleted / the page's 'ready' post; handlers nilled in
  Destroy. The host extracts web messages, so OnMessageReceived gets the raw string.
}

interface

uses
  System.Classes,
  System.Generics.Collections,
  Vcl.Controls,
  Vcl.ExtCtrls,
  Aefos.WebView.Types,
  Aefos.WebView.Control,
  Aefos.OTA.Terminal.Core.Profiles,
  Aefos.OTA.Terminal.UI.WelcomePane;  // TWelcomeLaunchEvent

type
  TWelcomeWebPane = class(TPanel)
  private
    FBrowser: TAefosWebView;  // composition-hosted WebView2 (blink-free); name kept
    FOnLaunchProfile: TWelcomeLaunchEvent;
    FReady: Boolean;        // WebView2 created
    FNavigated: Boolean;    // navigation started
    FPageLive: Boolean;     // NavigationCompleted / page 'ready' seen
    FProfilesJson: string;
    procedure _OnReady;
    procedure _OnNav(const ASuccess: Boolean);
    procedure _OnHostMsg(const AMessage: string);
    procedure _EnsureNavigated;
    procedure _Flush;
    procedure _HandleHostMessage(const AMessage: string);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    // Builds the profile cards JSON from the live profile list and (once the
    // page is live) pushes it. Same signature as TWelcomePane.BuildFromProfiles.
    procedure BuildFromProfiles(const AProfiles: TObjectList<TShellProfile>);
    property OnLaunchProfile: TWelcomeLaunchEvent
      read FOnLaunchProfile write FOnLaunchProfile;
  end;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.IOUtils,
  System.JSON,
  Vcl.Graphics,
  Aefos.OTA.Terminal.Core.WelcomeModel,
  Aefos.OTA.Terminal.UI.WelcomeHtml;

function _ColorHex(const AColor: TColor): string;
var
  LRgb: LongInt;
begin
  LRgb := ColorToRGB(AColor);
  Result := Format('#%.2x%.2x%.2x',
    [GetRValue(LRgb), GetGValue(LRgb), GetBValue(LRgb)]);
end;

constructor TWelcomeWebPane.Create(AOwner: TComponent);
var
  LCfg: TWebViewConfig;
begin
  inherited Create(AOwner);
  BevelOuter := bvNone;
  ParentBackground := False;
  FProfilesJson := '[]';

  FBrowser := TAefosWebView.Create(Self);
  // Composition hosting (same as the chat): renders into a DComp visual the DWM
  // composites independent of activation -> never blanks when the IDE/terminal
  // loses the foreground. Configure BEFORE the handle exists.
  LCfg := TWebViewConfig.Default;
  // OWN user-data folder (NOT the chat's 'Aefos_WebView2'): WebView2 requires the
  // SAME AdditionalBrowserArguments for a shared folder, and the chat sets the
  // occlusion-disable arg while this pane doesn't -> sharing makes the second env
  // creation FAIL. Separate folders = fully independent, no args coupling.
  LCfg.UserDataFolder := TPath.Combine(TPath.GetTempPath, 'Aefos_WebView2_Terminal');
  FBrowser.Configure(LCfg);
  FBrowser.OnReady := _OnReady;
  FBrowser.OnNavigationCompleted := _OnNav;
  FBrowser.OnMessageReceived := _OnHostMsg;
  FBrowser.Parent := Self;
  FBrowser.Align := alClient;
end;

destructor TWelcomeWebPane.Destroy;
begin
  if Assigned(FBrowser) then
  begin
    FBrowser.OnReady := nil;
    FBrowser.OnNavigationCompleted := nil;
    FBrowser.OnMessageReceived := nil;
  end;
  inherited;
end;

procedure TWelcomeWebPane._EnsureNavigated;
var
  LFile: string;
begin
  if FNavigated or not Assigned(FBrowser) then
    Exit;
  FNavigated := True;
  FBrowser.HandleNeeded;  // force the handle so the composition host gets created
  // file:/// temp URL (NavigateToString hangs in some bds.exe contexts; data:
  // URIs are blocked since Chromium 123) — same approach as the chat.
  LFile := TPath.Combine(TPath.GetTempPath, 'aefos_terminal_welcome.html');
  TFile.WriteAllText(LFile, BuildWelcomeHtml, TEncoding.UTF8);
  FBrowser.Navigate('file:///' + StringReplace(LFile, '\', '/', [rfReplaceAll]));
end;

procedure TWelcomeWebPane._OnReady;
begin
  // The composition WebView2 is created; scripts can run. (On failure the host
  // fires OnFailed, which we don't wire — the pane just stays blank, and the
  // operator still has the sidebar / New-Tab paths.)
  FReady := True;
end;

procedure TWelcomeWebPane._OnNav(const ASuccess: Boolean);
begin
  if ASuccess then
  begin
    FPageLive := True;
    _Flush;
  end;
end;

procedure TWelcomeWebPane._Flush;
begin
  if not (Assigned(FBrowser) and FReady and FPageLive) then
    Exit;
  FBrowser.ExecuteScript('window.dsSetProfiles(' + FProfilesJson + ');');
end;

// JS -> Pascal. The page posts 'ready' once loaded, then 'launch:N' on clicks.
// The composition host extracts the string and hands it here on the main thread.
procedure TWelcomeWebPane._OnHostMsg(const AMessage: string);
begin
  _HandleHostMessage(AMessage);
end;

procedure TWelcomeWebPane._HandleHostMessage(const AMessage: string);
var
  LValue: Integer;
begin
  if AMessage = 'ready' then
  begin
    FPageLive := True;
    _Flush;
    Exit;
  end;
  if AMessage.StartsWith('launch:') then
  begin
    if Assigned(FOnLaunchProfile) and
       TryStrToInt(AMessage.Substring(7), LValue) then
      FOnLaunchProfile(Self, LValue);
    Exit;
  end;
end;

procedure TWelcomeWebPane.BuildFromProfiles(
  const AProfiles: TObjectList<TShellProfile>);
var
  LCards: TArray<TWelcomeCard>;
  LArr: TJSONArray;
  LObj: TJSONObject;
  LIndex: Integer;
begin
  // Reuse the same pure model the VCL pane uses, then serialise for the page.
  LCards := TWelcomeModel.BuildCards(AProfiles);
  LArr := TJSONArray.Create;
  try
    for LIndex := 0 to High(LCards) do
    begin
      LObj := TJSONObject.Create;
      LObj.AddPair('index', TJSONNumber.Create(LCards[LIndex].ProfileIndex));
      LObj.AddPair('name', LCards[LIndex].ProfileName);
      LObj.AddPair('summary', LCards[LIndex].ShellSummary);
      LObj.AddPair('dot', _ColorHex(LCards[LIndex].DotColor));
      LArr.AddElement(LObj);
    end;
    FProfilesJson := LArr.ToJSON;
  finally
    LArr.Free;
  end;
  _EnsureNavigated;
  _Flush;
end;

end.
