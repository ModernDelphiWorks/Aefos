unit Aefos.OTA.Chat.Core.OutputPanel.RenderProtocol;

(*
  Render-protocol seam (ESP-002, ADR-241/244/245/246).

  Pure RTL-only string logic for the WebView2 output panel - no Vcl.Edge,
  no ToolsAPI. Logic lifted verbatim from TOutputPanelEdgeSurface so the
  render code exists once and is headless-unit-testable (AC-01..AC-06).

  Exports:
    TPanelTheme          - plain palette record (IsDark + #rrggbb fields).
    TPanelTheme.Dark     - built-in VS-dark palette.
    TPanelTheme.Light    - built-in light palette.
    TRenderProtocol.BuildShell         - parameterless overload; uses TPanelTheme.Dark.
    TRenderProtocol.BuildShell(ATheme) - substitutes THEME_VARS + PANEL_CSS /
                           HIGHLIGHT_CSS / MARKED_JS / HIGHLIGHT_JS.
    TRenderProtocol.JSEncode           - escapes a Delphi string to a JSON string literal.
    TRenderProtocol.UserScript         - window.dsUser && window.dsUser(enc);
    TRenderProtocol.AppendScript       - window.dsAppend && window.dsAppend(enc);
    TRenderProtocol.ClearScript        - window.dsClear && window.dsClear();
    TRenderProtocol.FooterScript       - window.dsFooter && window.dsFooter(enc, false|true);

  TRenderPendingQueue provides the pending-before-ready buffering (AC-04)
  at the seam level, with a caller-supplied TScriptRunner callback so it
  runs without a browser in the unit tests.
*)

interface

uses
  System.SysUtils,
  System.Classes;

type
  (* Plain palette record - RTL-only, no ToolsAPI/VCL (ADR-244/BR-2) *)
  TPanelTheme = record
    IsDark: Boolean;
    Bg: string;
    Fg: string;
    Secondary: string;
    Border: string;
    Accent: string;
    UserBg: string;
    UserFg: string;
    // Built-in palettes (ADR-244). Dark is the branded fallback.
    class function Dark: TPanelTheme; static;
    class function Light: TPanelTheme; static;
  end;

  // Render-protocol seam: the HTML shell + the window.ds*() script strings.
  // Pure RTL-only string logic (no Vcl.Edge/ToolsAPI).
  TRenderProtocol = class sealed
  strict private
    // The :root custom properties, built once and used by BOTH documents. A
    // second hand-kept copy is how the standalone card would end up a slightly
    // different shade of the same design.
    class function _ThemeVars(const ATheme: TPanelTheme): string; static;
  public
    class function BuildShell: string; overload; static;
    class function BuildShell(const ATheme: TPanelTheme): string; overload; static;
    { The permission card ALONE, as a document of its own.

      For the prompt that arrives with no chat panel open. It is the same card:
      same CSS, same markup, same script, spliced from the same constants the
      shell splices. What it deliberately leaves out is everything else --
      header, welcome, composer, marked, highlight.js. Pointing the borderless
      window at BuildShell instead was the shortcut that opened the WHOLE CHAT
      in a frameless window (reverted, PR #390); this exists so that shortcut is
      never tempting again.

      window.dsShowPermission and the "perm:*" messages behave exactly as they
      do in the panel, so the host talks to it with the code it already had. }
    class function BuildConsentDocument(const ATheme: TPanelTheme): string; static;
    // Escapes a Delphi string to a JSON string literal.
    class function JSEncode(const AInput: string): string; static;
    class function UserScript(const AText: string): string; static;
    class function AppendScript(const AText: string): string; static;
    class function ClearScript: string; static;
    class function FooterScript(const AText: string; const AIsError: Boolean): string; static;
    // Send-during-run queue indicator: shows "N queued" under the typing line
    // while messages wait for the in-flight turn to finish; 0 hides it.
    class function QueuedNoticeScript(const ACount: Integer): string; static;
    { The Visual Scanner card. APayloadJson is ALREADY JSON (built and tested by
      TAefosVisualSession.ToJson), so it is handed over as a JSON STRING and the
      viewer parses it -- rather than being spliced into the script raw.
      Splicing raw JSON into a script literal is how one unescaped quote in a
      failure message turns into a syntax error that kills every later call on
      the same page, not just this card. }
    class function ScannerScript(const APayloadJson: string): string; static;
    { Hands the viewer ONE screenshot, keyed by the id the card payload names.
      A separate call on purpose: the payload is re-sent on every step, so a
      picture carried inside it would be re-pushed with each one. This is sent
      once per capture and looked up from then on. }
    class function ScannerImageScript(const AImageId,
      ADataUri: string): string; static;
  end;

type
  TScriptRunner = reference to procedure(const AScript: string);

  TRenderPendingQueue = class
  private
    FPending: TStringList;
    FReady: Boolean;
    FRunner: TScriptRunner;
    procedure _Flush;
  public
    constructor Create(const ARunner: TScriptRunner);
    destructor Destroy; override;
    procedure SetReady;
    procedure Enqueue(const AScript: string);
    property Ready: Boolean read FReady;
  end;

implementation

uses
  Aefos.OTA.Chat.UI.OutputPanel.Assets;

class function TRenderProtocol.ScannerImageScript(const AImageId,
  ADataUri: string): string;
begin
  // Same guard as ScannerScript, and both arguments go through JSEncode: a data
  // URI is attacker-adjacent input as far as this page is concerned (it is built
  // from whatever the captured window rendered), and splicing it raw into a
  // script literal is how one stray character kills every later call on the page.
  Result := 'window.dsScannerImage && window.dsScannerImage('
    + JSEncode(AImageId) + ', ' + JSEncode(ADataUri) + ');';
end;

class function TRenderProtocol.ScannerScript(
  const APayloadJson: string): string;
begin
  // The guard is not decoration: the shell only defines dsScanner once the
  // document has loaded, and a script that runs before that would throw and
  // take the rest of the batch with it. Every other bridge call here is written
  // the same way.
  Result := 'window.dsScanner && window.dsScanner(' + JSEncode(APayloadJson) + ');';
end;

class function TPanelTheme.Dark: TPanelTheme;
begin
  Result.IsDark    := True;
  Result.Bg        := '#1e1e1e';
  Result.Fg        := '#d4d4d4';
  Result.Secondary := '#808080';
  Result.Border    := '#3c3c3c';
  Result.Accent    := '#9cdcfe';
  // Tribute to Claude: user bubble in the Anthropic standard "clay" orange.
  Result.UserBg    := '#d97757';
  Result.UserFg    := '#ffffff';
end;

class function TPanelTheme.Light: TPanelTheme;
begin
  Result.IsDark    := False;
  Result.Bg        := '#f5f5f5';
  Result.Fg        := '#121212';
  Result.Secondary := '#606060';
  Result.Border    := '#cccccc';
  Result.Accent    := '#0078d4';
  // Tribute to Claude: light shade of the "clay" orange (dark text for contrast).
  Result.UserBg    := '#f7e2d8';
  Result.UserFg    := '#121212';
end;

class function TRenderProtocol.BuildShell: string;
begin
  Result := BuildShell(TPanelTheme.Dark);
end;

class function TRenderProtocol._ThemeVars(const ATheme: TPanelTheme): string;
begin
  (* Build :root CSS custom properties block from the palette.
     Curly braces below are CSS, not Delphi comments - safe inside string literals. *)
  Result :=
    ':root { ' +
    '--ds-bg:'        + ATheme.Bg        + '; ' +
    '--ds-fg:'        + ATheme.Fg        + '; ' +
    '--ds-secondary:' + ATheme.Secondary + '; ' +
    '--ds-border:'    + ATheme.Border    + '; ' +
    '--ds-accent:'    + ATheme.Accent    + '; ' +
    '--ds-user-bg:'   + ATheme.UserBg    + '; ' +
    '--ds-user-fg:'   + ATheme.UserFg    + '; ' +
    // Brand/semantic accents - CONSTANTS (do not change dark<->light). To
    // switch the brand/color theme: edit HERE, a single place. The UI .pas use
    // var(--ds-*); the glows use rgba(var(--ds-*-rgb), <alpha>) with the triplets.
    // --ds-blue* = Aefos accent; --ds-primary* = Claude "clay" orange
    // (primary CTAs + user bubble); danger/success/warn = states.
    '--ds-blue:#2A98FF; --ds-blue-2:#1a7ae0; --ds-blue-rgb:42,152,255; ' +
    '--ds-primary:#d97757; --ds-primary-hi:#e0875f; --ds-primary-lo:#d2693f; ' +
    '--ds-primary-rgb:217,119,87; ' +
    '--ds-danger:#e0664a; --ds-danger-rgb:224,102,74; ' +
    '--ds-success:#25d366; --ds-success-rgb:37,211,102; ' +
    '--ds-warn:#e0a93a; --ds-warn-rgb:224,169,58; ' +
    '}';
end;

class function TRenderProtocol.BuildShell(const ATheme: TPanelTheme): string;
begin
  Result := HTML_SHELL;
  Result := StringReplace(Result, '{{THEME_VARS}}', _ThemeVars(ATheme), []);
  Result := StringReplace(Result, '{{PANEL_CSS}}', PANEL_CSS, []);
  Result := StringReplace(Result, '{{HIGHLIGHT_CSS}}', HIGHLIGHT_CSS, []);
  Result := StringReplace(Result, '{{MARKED_JS}}', MARKED_JS, []);
  Result := StringReplace(Result, '{{HIGHLIGHT_JS}}', HIGHLIGHT_JS, []);
end;

class function TRenderProtocol.BuildConsentDocument(
  const ATheme: TPanelTheme): string;
begin
  Result :=
    '<!DOCTYPE html>' + sLineBreak +
    '<html><head><meta charset="utf-8">' + sLineBreak +
    '<style>' + _ThemeVars(ATheme) + sLineBreak +
    '* { box-sizing: border-box; }' + sLineBreak +
    'html, body { margin: 0; padding: 0; height: 100%; ' +
    'font-family: "Segoe UI", system-ui, sans-serif; }' + sLineBreak +
    PERMISSION_KEYFRAMES +
    PERMISSION_CSS +
    (* The backdrop dims the CHAT behind it. Here it IS the window, so there is
       nothing behind to dim and a translucent black sheet would just be a grey
       rectangle around the card. The window is sized to the card instead, so
       the card's own border becomes the window edge. *)
    '#ds-perm-backdrop { background: transparent; backdrop-filter: none; ' +
    'padding: 0; display: block; }' + sLineBreak +
    (* Both of these were VIEWPORT-relative in the card (min(560px,94vw) and
       56vh), which is right inside a panel and a feedback loop out here: the
       window shrinks to fit the card, which shrinks because the viewport did,
       which shrinks the window... Fixed pixels break the loop. The body keeps a
       cap so a long PREVIEW scrolls instead of growing the window without end. *)
    '#ds-perm-modal { width: 560px; }' + sLineBreak +
    '#ds-perm-modal .ds-perm-body { max-height: 420px; }' + sLineBreak +
    'html, body { overflow: hidden; }' + sLineBreak +
    '</style></head><body>' + sLineBreak +
    PERMISSION_HTML +
    PERMISSION_JS +
    (* Tell the host how big the card turned out. NOT part of the shared script:
       only this container has a window to fit, and a message added to the card
       itself would also reach the chat panel -- where anything under "perm:"
       that is not an allow counts as a denial. Hence its own prefix, posted from
       a wrapper, leaving the card's own behaviour untouched. *)
    '<script>' + sLineBreak +
    '(function(){' + sLineBreak +
    '  var inner = window.dsShowPermission;' + sLineBreak +
    '  window.dsShowPermission = function(d){' + sLineBreak +
    '    if (inner) { inner(d); }' + sLineBreak +
    '    var card = document.getElementById("ds-perm-modal");' + sLineBreak +
    '    if (!card) { return; }' + sLineBreak +
    (* One frame later: the card is filled in by inner() and the browser has not
       laid it out yet, so measuring now would report the EMPTY card's height. *)
    '    requestAnimationFrame(function(){' + sLineBreak +
    '      var r = card.getBoundingClientRect();' + sLineBreak +
    '      try{ if(window.chrome && window.chrome.webview){' + sLineBreak +
    '        window.chrome.webview.postMessage("card:size:" +' + sLineBreak +
    '          Math.ceil(r.width) + "x" + Math.ceil(r.height)); } }catch(e){}' + sLineBreak +
    '    });' + sLineBreak +
    '  };' + sLineBreak +
    '})();' + sLineBreak +
    '</script>' + sLineBreak +
    '</body></html>';
end;

class function TRenderProtocol.JSEncode(const AInput: string): string;
var
  LBuilder: TStringBuilder;
  LFor: Integer;
  LCh: Char;
begin
  LBuilder := TStringBuilder.Create(Length(AInput) + 16);
  try
    LBuilder.Append('"');
    for LFor := 1 to Length(AInput) do
    begin
      LCh := AInput[LFor];
      case LCh of
        '"':  LBuilder.Append('\"');
        '\':  LBuilder.Append('\\');
        #8:   LBuilder.Append('\b');
        #9:   LBuilder.Append('\t');
        #10:  LBuilder.Append('\n');
        #12:  LBuilder.Append('\f');
        #13:  LBuilder.Append('\r');
      else
        if Ord(LCh) < $20 then
          LBuilder.AppendFormat('\u%.4x', [Ord(LCh)])
        else
          LBuilder.Append(LCh);
      end;
    end;
    LBuilder.Append('"');
    Result := LBuilder.ToString;
  finally
    LBuilder.Free;
  end;
end;

class function TRenderProtocol.AppendScript(const AText: string): string;
begin
  Result := 'window.dsAppend && window.dsAppend(' + JSEncode(AText) + ');';
end;

class function TRenderProtocol.ClearScript: string;
begin
  Result := 'window.dsClear && window.dsClear();';
end;

class function TRenderProtocol.FooterScript(const AText: string; const AIsError: Boolean): string;
begin
  if AIsError then
    Result := 'window.dsFooter && window.dsFooter(' + JSEncode(AText) + ', true);'
  else
    Result := 'window.dsFooter && window.dsFooter(' + JSEncode(AText) + ', false);';
end;

class function TRenderProtocol.UserScript(const AText: string): string;
begin
  Result := 'window.dsUser && window.dsUser(' + JSEncode(AText) + ');';
end;

class function TRenderProtocol.QueuedNoticeScript(const ACount: Integer): string;
begin
  Result := 'window.dsQueued && window.dsQueued(' + IntToStr(ACount) + ');';
end;

{ TRenderPendingQueue }

constructor TRenderPendingQueue.Create(const ARunner: TScriptRunner);
begin
  inherited Create;
  FPending := TStringList.Create;
  FReady := False;
  FRunner := ARunner;
end;

destructor TRenderPendingQueue.Destroy;
begin
  FPending.Free;
  inherited;
end;

procedure TRenderPendingQueue._Flush;
var
  LIndex: Integer;
begin
  for LIndex := 0 to FPending.Count - 1 do
    FRunner(FPending[LIndex]);
  FPending.Clear;
end;

procedure TRenderPendingQueue.SetReady;
begin
  FReady := True;
  _Flush;
end;

procedure TRenderPendingQueue.Enqueue(const AScript: string);
begin
  if FReady then
    FRunner(AScript)
  else
    FPending.Add(AScript);
end;

end.
