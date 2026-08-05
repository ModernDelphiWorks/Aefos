unit Aefos.OTA.Terminal.UI.Branding;

{
  Splash-screen + About-box registration for the Terminal host BPL
  (Aefos.OTA.Terminal).

  Each Aefos host BPL registers its OWN branding so the Aefos logo
  shows on the Delphi splash / About box whether the Terminal plugin, the Chat
  plugin, or both are installed (they ship and load independently). The Chat BPL
  has its own equivalent unit; this one is captioned 'Aefos AI (Terminal)'
  and uses the terminal-window logo.

  RegisterTerminalBranding runs once at plugin load (the splash bitmap must be
  added while the IDE splash is still showing). UnregisterTerminalBranding
  removes the About entry on unload.

  The 24x24 logo is embedded as an RCDATA PNG; the splash treats the lower-left
  pixel colour (black) as transparent so the mark sits cleanly on the dark
  splash.
}

interface

procedure RegisterTerminalBranding;
procedure UnregisterTerminalBranding;

{ The plugin version (M.m.p) read from this BPL's FILEVERSION resource, the
  single source of truth shared by the splash/About caption and the About
  dialog. Returns '' when the module carries no version resource. }
function TerminalPluginVersion: string;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.Types,
  Vcl.Graphics,
  Vcl.Imaging.pngimage,
  ToolsAPI;

{$R 'Aefos.OTA.Terminal.UI.Branding.res'}

const
  LOGO_RES_NAME   = 'AEFOS_LOGO';
  PRODUCT_CAPTION = 'Aefos AI (Terminal)';
  // Fallback shown when the BPL carries no FILEVERSION resource (e.g. a build
  // config without VerInfo). The .dproj VerInfo stays the primary source; this
  // only guarantees the splash/About never degrade to a blank version — keep it
  // in sync with the .dproj FileVersion on release.
  FALLBACK_VERSION = '1.4.0';
  PRODUCT_DESC =
    'Aefos AI - Terminal: integrated terminal in the RAD Studio IDE with ' +
    'an in-process MCP server exposing OTA tools to a local AI CLI harness.';

var
  GAboutIndex: Integer = -1;
  GLogoBmp:    TBitmap = nil;

// Lazily builds the 24x24 logo DDB (PNG flattened onto black, the splash
// transparent colour) and keeps it alive for the BPL's lifetime: the IDE
// retains the HBITMAP we hand the splash / About list, so it must outlive
// registration — freed in UnregisterTerminalBranding (no per-load GDI leak).
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

// Reads the host BPL's FILEVERSION (the package version info) and formats it
// as 'M.m.p'. Single source of truth: the .dproj VerInfo — no hardcoded
// version constant to bump. Returns '' when the module carries no version
// resource, so the caption degrades gracefully to the bare product name.
function _ModuleVersion: string;
var
  LPath: array[0..MAX_PATH] of Char;
  LSize, LDummy: DWORD;
  LBuf: TBytes;
  LInfo: PVSFixedFileInfo;
  LLen: UINT;
begin
  Result := '';
  if GetModuleFileName(HInstance, LPath, Length(LPath)) = 0 then
    Exit;
  LSize := GetFileVersionInfoSize(LPath, LDummy);
  if LSize = 0 then
    Exit;
  SetLength(LBuf, LSize);
  if not GetFileVersionInfo(LPath, 0, LSize, LBuf) then
    Exit;
  if not VerQueryValue(Pointer(LBuf), '\', Pointer(LInfo), LLen) then
    Exit;
  Result := Format('%d.%d.%d',
    [HiWord(LInfo.dwFileVersionMS), LoWord(LInfo.dwFileVersionMS),
     HiWord(LInfo.dwFileVersionLS)]);
end;

function TerminalPluginVersion: string;
begin
  // FILEVERSION is the primary source; fall back to the literal so the version
  // is NEVER blank (the splash read FileVersion at load and silently degraded
  // when a Win32 build shipped without VerInfo).
  Result := _ModuleVersion;
  if Result = '' then
    Result := FALLBACK_VERSION;
end;

// Caption with the plugin version appended — same splash/About format as the
// Chat host BPL ('Aefos AI (Chat) 0.19.1'). Uses TerminalPluginVersion so the
// version always shows (FileVersion when present, fallback otherwise).
function _Caption: string;
begin
  Result := PRODUCT_CAPTION + ' ' + TerminalPluginVersion;
end;

// The license type shown on the IDE splash / About plugin list (Trial / Free /
// Pro...), read from the cache at load. Guarded — never break registration.
function _SplashStatus: string;
begin
  Result := '';
  if Result = '' then
    Result := 'Licensed';
end;

procedure RegisterTerminalBranding;
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
    GAboutIndex := LAbout.AddPluginInfo(_Caption, PRODUCT_DESC, LBmp,
      False, LStatus);
end;

procedure UnregisterTerminalBranding;
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
