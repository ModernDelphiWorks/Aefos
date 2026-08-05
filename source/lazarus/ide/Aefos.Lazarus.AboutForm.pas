unit Aefos.Lazarus.AboutForm;

{ Branded About dialog for the Aefos AI - Lazarus edition.

  The LCL twin of the Delphi Chat host's About dialog
  (source\chat\UI\Aefos.OTA.Chat.UI.AboutForm.pas): a runtime-built modal on a
  black canvas showing the Aefos lockup logo, the suite subtitle, the support
  facts, and an OK button. Kept visually identical to the Delphi one so both
  IDEs present the same brand surface (the maintainer asked the Lazarus About to
  reuse the Delphi form's design).

  Logo delivery differs from Delphi. The Delphi edition embeds the PNG as an
  RCDATA resource in its BPL; the Lazarus edition recompiles lazarus.exe from
  shipped sources, so instead of an FPC resource we load the lockup PNG from
  %APPDATA%\Aefos\aefos-about-logo.png (the installer stages it there, next to
  mcp-bridge.ps1). If the file is missing the dialog still shows, just without
  the art (graceful, mirroring the Delphi nil-logo guard) - no crash.

  Pure LCL - no IDEIntf/ToolsAPI - so it links cleanly inside the design
  package. BOM-free: the two non-ASCII glyphs (em dash, middle dot) are spelled
  as their raw UTF-8 bytes, which the LCL renders directly. }

{$mode objfpc}{$H+}

interface

// Shows the branded About modal (centered on screen). Never raises.
procedure ShowLazAboutDialog;

implementation

uses
  SysUtils,
  Classes,
  Forms,
  Controls,
  StdCtrls,
  ExtCtrls,
  Graphics,
  LCLType,       // DT_CALCRECT / DT_WORDBREAK / DT_NOPREFIX for the body height calc
  LCLIntf,       // DrawText (measure wrapped text height, same seam as the Delphi calc)
  LazUTF8,       // GetEnvironmentVariableUTF8 / UTF16ToUTF8 - path + license text
  LazFileUtils,  // AppendPathDelim / FileExistsUTF8
  Aefos.License.Gate;  // real license status line (shared cross-compiler gate)

const
  cAboutCaption  = 'About Aefos AI';
  // ' ' + U+00B7 MIDDLE DOT + ' ' and U+2014 EM DASH, spelled as raw UTF-8 bytes
  // so the source stays BOM-free/ASCII (the LCL renders the bytes as the glyphs).
  cMidDot        = ' ' + #$C2#$B7 + ' ';
  cEmDash        = #$E2#$80#$94;
  cSuiteSubtitle = 'Chat' + cMidDot + 'Terminal' + cMidDot + 'MCP Server';

  // Brand accent (light blue #4FB0F5) and the soft-gray body colour (#C8C8C8),
  // as LCL TColor ($00BBGGRR on Windows, same byte order as the Delphi VCL).
  CLR_ACCENT     = TColor($00F5B04F);
  CLR_BODY       = TColor($00C8C8C8);

  // Runtime path of the lockup PNG the installer stages under %APPDATA%\Aefos.
  cLogoFileName  = 'aefos-about-logo.png';
  cVendorDir     = 'Aefos';

// Absolute path to the staged About logo (%APPDATA%\Aefos\aefos-about-logo.png).
function _LogoPath: string;
var
  LAppData: string;
begin
  Result := '';
  LAppData := GetEnvironmentVariableUTF8('APPDATA');
  if LAppData = '' then
    Exit;
  Result := AppendPathDelim(AppendPathDelim(LAppData) + cVendorDir) + cLogoFileName;
end;

// The descriptive lines below the logo. Facts adapted to the Lazarus edition;
// the AI-CLI/credentials line matches the Delphi copy verbatim.
function _BodyText: string;
begin
  Result :=
    'A harness for your own AI CLI inside the Lazarus IDE ' + cEmDash +
      ' never a direct LLM client.' + LineEnding + LineEnding +
    'Version: 1.1.0' + LineEnding +
    // Real license status from the shared gate (trial/active/expired/...),
    // instead of the old hardcoded "active". StatusText already includes the
    // "License: " prefix. Converted UnicodeString -> LCL UTF-8 at the boundary.
    UTF16ToUTF8(TLicenseGate.StatusText) + LineEnding +
    'Requires: Lazarus + FPC (Win32/Win64)' + LineEnding +
    'AI CLI: Codex and Gemini are bundled; Claude Code and Copilot are ' +
      'user-supplied. The plugin owns no credentials.' + LineEnding + LineEnding +
    'See docs/branding/SUITE-BRANDING.md';
end;

// Pixel height of AText wrapped to AWidth in AFont - sizes the body box to its
// real content so the last line is never clipped behind OK (DT_CALCRECT, the
// same technique as the Delphi dialog).
function _WrappedTextHeight(const AText: string; AWidth: Integer;
  AFont: TFont): Integer;
var
  LBmp: TBitmap;
  LRect: TRect;
begin
  LBmp := TBitmap.Create;
  try
    LBmp.Canvas.Font.Assign(AFont);
    LRect := Rect(0, 0, AWidth, 0);
    LCLIntf.DrawText(LBmp.Canvas.Handle, PChar(AText), -1, LRect,
      DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
    Result := LRect.Bottom - LRect.Top;
  finally
    LBmp.Free;
  end;
end;

procedure ShowLazAboutDialog;
const
  MARGIN   = 24;
  FORM_W   = 460;
  LOGO_BOX = 320;
  BODY_H   = 132;
  BTN_W    = 90;
  BTN_H    = 30;
var
  LForm:     TForm;
  LImg:      TImage;
  LSubtitle: TLabel;
  LBody:     TLabel;
  LBtn:      TButton;
  LY:        Integer;
  LBodyStr:  string;
  LBodyH:    Integer;
  LLogo:     string;
begin
  LForm := TForm.CreateNew(nil);
  try
    LForm.BorderStyle  := bsDialog;
    LForm.BorderIcons  := [biSystemMenu];
    LForm.Caption      := cAboutCaption;
    LForm.Position     := poScreenCenter;
    LForm.Color        := clBlack;
    LForm.Font.Name    := 'Segoe UI';
    LForm.Font.Size    := 9;
    LForm.ClientWidth  := FORM_W;

    LY := MARGIN;

    // Logo: loaded from the staged PNG. TPicture.LoadFromFile reads PNG by its
    // extension. Any failure (missing file / decode error) degrades to no art.
    LLogo := _LogoPath;
    if (LLogo <> '') and FileExistsUTF8(LLogo) then
    begin
      LImg := TImage.Create(LForm);
      LImg.Parent       := LForm;
      LImg.Stretch      := True;
      LImg.Proportional := True;
      LImg.Center       := True;
      LImg.SetBounds((FORM_W - LOGO_BOX) div 2, LY, LOGO_BOX, LOGO_BOX);
      try
        LImg.Picture.LoadFromFile(LLogo);
        LY := LY + LOGO_BOX + 6;
      except
        LImg.Free;   // decode failed - drop the image, keep the dialog
      end;
    end;

    LSubtitle := TLabel.Create(LForm);
    LSubtitle.Parent      := LForm;
    LSubtitle.Alignment   := taCenter;
    LSubtitle.AutoSize    := False;
    LSubtitle.Transparent := True;
    LSubtitle.Font.Size   := 10;
    LSubtitle.Font.Style  := [fsBold];
    LSubtitle.Font.Color  := CLR_ACCENT;
    LSubtitle.Caption     := cSuiteSubtitle;
    LSubtitle.SetBounds(MARGIN, LY, FORM_W - 2 * MARGIN, 22);
    LY := LY + 28;

    LBodyStr := _BodyText;
    // Size the body to its real wrapped height (floor of BODY_H so short text
    // won't collapse the dialog), so OK always sits below the last line.
    LBodyH := _WrappedTextHeight(LBodyStr, FORM_W - 2 * MARGIN, LForm.Font) + 4;
    if LBodyH < BODY_H then
      LBodyH := BODY_H;
    LBody := TLabel.Create(LForm);
    LBody.Parent      := LForm;
    LBody.Alignment   := taCenter;
    LBody.WordWrap    := True;
    LBody.AutoSize    := False;
    LBody.Transparent := True;
    LBody.Font.Color  := CLR_BODY;
    LBody.Caption     := LBodyStr;
    LBody.SetBounds(MARGIN, LY, FORM_W - 2 * MARGIN, LBodyH);
    LY := LY + LBodyH + 6;

    LBtn := TButton.Create(LForm);
    LBtn.Parent      := LForm;
    LBtn.Caption     := 'OK';
    LBtn.ModalResult := mrOk;
    LBtn.Default     := True;
    LBtn.Cancel      := True;
    LBtn.SetBounds((FORM_W - BTN_W) div 2, LY, BTN_W, BTN_H);
    LY := LY + BTN_H + MARGIN;

    LForm.ClientHeight := LY;
    LForm.ShowModal;
  finally
    LForm.Free;
  end;
end;

end.
