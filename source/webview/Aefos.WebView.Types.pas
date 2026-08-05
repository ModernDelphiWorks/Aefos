unit Aefos.WebView.Types;

{$IFDEF FPC}
// FPC-only: the lpk drives -Mdelphi, but TWebViewConfig carries a `class function`
// (an advanced record), and FPC's Delphi mode does not enable advanced records by
// default. Enable the modeswitch here so the record compiles unchanged. Guarded so
// Delphi never sees these directives -> the Delphi .dcu stays byte-identical.
{$mode delphi}
{$modeswitch advancedrecords}
{$ENDIF}

{
  Data contract for the composition WebView host — RTL-only, no WebView2/DComp deps,
  so callers (the chat, the POC) depend on this lightweight unit, not on the COM
  guts. Mirrors the small surface the chat already consumes from the Edge layer
  (navigate / execute-script / web-message / ready), keeping the host swappable.
}

interface

uses
  {$IFDEF FPC}
  // FPC 3.2.2 ships the classic short RTL unit names, not the Delphi dotted ones.
  Windows;
  {$ELSE}
  Winapi.Windows;
  {$ENDIF}

type
  // Event contract. On Delphi the host (TAefosWebView, VCL) wires these as
  // anonymous methods. On FPC 3.2.2 there are no `reference to` types (they land
  // only in 3.3.1+), so the Lazarus host (TAefosLazWebView, LCL) wires them as
  // ordinary `of object` method pointers -- the natural LCL published-event
  // idiom. The record below (TWebViewConfig) is shared verbatim across both.
  {$IFDEF FPC}
  TWebViewReadyEvent = procedure of object;
  TWebViewNavigationCompletedEvent = procedure(const ASuccess: Boolean) of object;
  TWebViewMessageEvent = procedure(const AMessage: string) of object;
  TWebViewFailedEvent = procedure(const AHResult: HRESULT) of object;
  // Result callback for ExecuteScript-with-result (the JSON the page returned).
  TWebViewScriptResult = procedure(const AErrorCode: HRESULT;
    const AResultJson: string) of object;
  {$ELSE}
  TWebViewReadyEvent = reference to procedure;
  TWebViewNavigationCompletedEvent = reference to procedure(const ASuccess: Boolean);
  TWebViewMessageEvent = reference to procedure(const AMessage: string);
  TWebViewFailedEvent = reference to procedure(const AHResult: HRESULT);
  // Result callback for ExecuteScript-with-result (the JSON the page returned).
  TWebViewScriptResult = reference to procedure(const AErrorCode: HRESULT;
    const AResultJson: string);
  {$ENDIF}

  // Creation config. UserDataFolder + AdditionalBrowserArguments mirror the Edge
  // controller; DefaultBackgroundColor is the pre-content paint (anti-flash).
  TWebViewConfig = record
    UserDataFolder: string;
    AdditionalBrowserArguments: string;
    DefaultBackgroundColorBGRA: Cardinal; // $AARRGGBB packed as the WV2 color
    class function Default: TWebViewConfig; static;
  end;

implementation

{ TWebViewConfig }

class function TWebViewConfig.Default: TWebViewConfig;
begin
  Result.UserDataFolder := '';
  Result.AdditionalBrowserArguments := '';
  Result.DefaultBackgroundColorBGRA := $FF1E1E1E; // opaque #1e1e1e dark shell bg
end;

end.
