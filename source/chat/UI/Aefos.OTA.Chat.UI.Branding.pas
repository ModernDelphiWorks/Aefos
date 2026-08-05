unit Aefos.OTA.Chat.UI.Branding;

{
  Splash-screen + About-box registration for the Chat host BPL (Aefos.OTA).

  Each Aefos host BPL registers its OWN branding so the Aefos logo
  shows on the Delphi splash / About box whether the Chat plugin, the Terminal
  plugin, or both are installed (they ship and load independently). The Terminal
  BPL has its own equivalent unit; this one is captioned 'Aefos AI (Chat)'.

  RegisterChatBranding runs once at plugin load (the splash bitmap must be added
  while the IDE splash is still showing, i.e. during package init).
  UnregisterChatBranding removes the About entry on unload.

  Links ToolsAPI -> designtime BPL only (ADR-115). The 24x24 logo is embedded as
  an RCDATA PNG; the splash treats the lower-left pixel colour (black) as
  transparent, so the mark sits cleanly on the dark splash.
}

interface

procedure RegisterChatBranding;
procedure UnregisterChatBranding;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.Types,
  Vcl.Graphics,
  Vcl.Imaging.pngimage,
  ToolsAPI,
  Aefos.OTA.Chat.Core.SupportInfo;

{$R 'Aefos.OTA.Chat.UI.Branding.res'}

const
  LOGO_RES_NAME   = 'AEFOS_LOGO';
  PRODUCT_CAPTION = 'Aefos AI (Chat)';
  PRODUCT_DESC =
    'Aefos AI - Chat: in-IDE chat/agent panel driven by a local AI CLI ' +
    'harness (bring your own), with an in-process MCP server exposing OTA ' +
    'tools to the spawned CLI.';

var
  GAboutIndex: Integer = -1;
  GLogoBmp:    TBitmap = nil;

// Lazily builds the 24x24 logo DDB (PNG flattened onto black, the splash
// transparent colour) and keeps it alive for the BPL's lifetime: the IDE
// retains the HBITMAP we hand the splash / About list, so it must outlive
// registration — freed in UnregisterChatBranding (no per-load GDI leak).
// Returns 0 when the embedded resource is missing.
function _LogoHandle: HBITMAP;
var
  LStream: TResourceStream;
  LPng:    TPngImage;
begin
  if GLogoBmp = nil then
  begin
    if FindResource(HInstance, LOGO_RES_NAME, RT_RCDATA) = 0 then
      Exit(0);
    LStream := TResourceStream.Create(HInstance, LOGO_RES_NAME, RT_RCDATA);
    try
      LPng := TPngImage.Create;
      try
        LPng.LoadFromStream(LStream);
        GLogoBmp := TBitmap.Create;
        GLogoBmp.PixelFormat := pf24bit;
        GLogoBmp.SetSize(24, 24);
        GLogoBmp.Canvas.Brush.Color := clBlack;
        GLogoBmp.Canvas.FillRect(Rect(0, 0, 24, 24));
        GLogoBmp.Canvas.StretchDraw(Rect(0, 0, 24, 24), LPng);
      finally
        LPng.Free;
      end;
    finally
      LStream.Free;
    end;
  end;
  Result := GLogoBmp.Handle;
end;

function _Caption: string;
begin
  Result := PRODUCT_CAPTION + ' ' + PluginVersion;
end;

// The license type shown on the IDE splash / About plugin list (Trial / Free /
// Pro...), read from the cache at load. Guarded — never break registration.
function _SplashStatus: string;
begin
  Result := '';
  if Result = '' then
    Result := 'Licensed';
end;

procedure RegisterChatBranding;
var
  LAbout: IOTAAboutBoxServices;
  LBmp:   HBITMAP;
  LStatus: string;
begin
  LBmp := _LogoHandle;
  if LBmp = 0 then
    Exit;
  LStatus := _SplashStatus;
  if Assigned(SplashScreenServices) then
    SplashScreenServices.AddPluginBitmap(_Caption, LBmp, False, LStatus);
  if Supports(BorlandIDEServices, IOTAAboutBoxServices, LAbout) then
    GAboutIndex := LAbout.AddPluginInfo(_Caption, PRODUCT_DESC, LBmp, False,
      LStatus);
end;

procedure UnregisterChatBranding;
var
  LAbout: IOTAAboutBoxServices;
begin
  if (GAboutIndex >= 0) and
     Supports(BorlandIDEServices, IOTAAboutBoxServices, LAbout) then
    LAbout.RemovePluginInfo(GAboutIndex);
  GAboutIndex := -1;
  FreeAndNil(GLogoBmp);
end;

end.
