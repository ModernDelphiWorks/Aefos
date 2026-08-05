unit Aefos.OTA.Terminal.UI.AboutForm;

{
  Branded About dialog for the Terminal host BPL.

  Runtime-built modal form that shows the black-background Aefos lockup logo
  (RCDATA 'AEFOS_ABOUT_LOGO', embedded via Terminal.UI.Branding.res — already
  linked by Terminal.UI.Branding) on a matching black canvas, with the
  suite/support facts below it.

  The Chat host BPL has its own equivalent unit (it cannot reach this one across
  the BPL boundary), kept visually identical. The version is read from the
  shared single source TerminalPluginVersion (the BPL FILEVERSION); the
  remaining suite facts mirror docs/branding/SUITE-BRANDING.md. (The Chat BPL
  sources the same facts from Chat.Core.SupportInfo; there is no shared
  cross-BPL facts unit today — see the rebrand notes if this should be
  extracted.)

  Pure VCL — no ToolsAPI — so it links cleanly inside the design-time BPL.
}

interface

procedure ShowTerminalAboutDialog;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.UITypes,
  Vcl.Forms,
  Vcl.Controls,
  Vcl.StdCtrls,
  Vcl.ExtCtrls,
  Vcl.Graphics,
  Vcl.Imaging.pngimage,
  Aefos.OTA.Terminal.UI.Branding;

const
  ABOUT_LOGO_RES = 'AEFOS_ABOUT_LOGO';
  ABOUT_CAPTION  = 'About Aefos AI (Terminal)';
  SUITE_SUBTITLE = 'Chat ' + #$00B7 + ' Terminal ' + #$00B7 + ' MCP Server';
  // Brand accent (light blue #4FB0F5) as a VCL BGR TColor, and the soft-gray
  // body colour (#C8C8C8).
  CLR_ACCENT     = TColor($00F5B04F);
  CLR_BODY       = TColor($00C8C8C8);
  // Suite facts (mirror of SUITE-BRANDING.md / Chat.Core.SupportInfo).
  SUPPORT_IDE_FLOOR = 'RAD Studio Delphi 13';
  SUPPORT_CLI_REQUIREMENT =
    'AI CLI: Codex and Gemini are bundled; Claude Code and Copilot are ' +
    'user-supplied. The plugin owns no credentials.';
  SUPPORT_BRANDING_DOC = 'docs/branding/SUITE-BRANDING.md';

// Loads the embedded About lockup PNG, or nil when the resource is missing.
function _LoadLogoPng: TPngImage;
var
  LStream: TResourceStream;
begin
  Result := nil;
  if FindResource(HInstance, ABOUT_LOGO_RES, RT_RCDATA) = 0 then
    Exit;
  LStream := TResourceStream.Create(HInstance, ABOUT_LOGO_RES, RT_RCDATA);
  try
    Result := TPngImage.Create;
    try
      Result.LoadFromStream(LStream);
    except
      FreeAndNil(Result);
    end;
  finally
    LStream.Free;
  end;
end;

// The descriptive lines below the logo. The version comes from the shared
// TerminalPluginVersion; the lockup art carries the 'Aefos AI' wordmark.
function _BodyText: string;
var
  LVersion: string;
begin
  LVersion := TerminalPluginVersion;
  if LVersion = '' then
    LVersion := '(unknown)';
  Result :=
    'A harness for your own AI CLI inside RAD Studio ' + #$2014 +
      ' never a direct LLM client.' + sLineBreak + sLineBreak +
    'Version: ' + LVersion + sLineBreak +
    'Requires: ' + SUPPORT_IDE_FLOOR + sLineBreak +
    SUPPORT_CLI_REQUIREMENT + sLineBreak + sLineBreak +
    'See ' + SUPPORT_BRANDING_DOC;
end;

// Pixel height of AText wrapped to AWidth in AFont. The body used to be a fixed
// BODY_H box, but the text is taller than the guess on some configs, so the last
// line ("External AI CLI: ...") was clipped behind the OK button. Measuring the
// real wrapped height (DT_CALCRECT) sizes the body to its content so OK always
// sits below it.
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
    Winapi.Windows.DrawText(LBmp.Canvas.Handle, PChar(AText), -1, LRect,
      DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
    Result := LRect.Bottom - LRect.Top;
  finally
    LBmp.Free;
  end;
end;

procedure ShowTerminalAboutDialog;
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
  LPng:      TPngImage;
  LSubtitle: TLabel;
  LBody:     TLabel;
  LBtn:      TButton;
  LY:        Integer;
  LBodyStr:  string;
  LBodyH:    Integer;
begin
  LForm := TForm.CreateNew(nil);
  try
    LForm.BorderStyle  := bsDialog;
    LForm.BorderIcons  := [biSystemMenu];
    LForm.Caption      := ABOUT_CAPTION;
    LForm.Position     := poScreenCenter;
    LForm.Color        := clBlack;
    LForm.Font.Name    := 'Segoe UI';
    LForm.Font.Size    := 9;
    LForm.ClientWidth  := FORM_W;
    if Assigned(Application.MainForm) then
    begin
      LForm.PopupMode   := pmExplicit;
      LForm.PopupParent := Application.MainForm;
    end;

    LY := MARGIN;

    LPng := _LoadLogoPng;
    if Assigned(LPng) then
    begin
      LImg := TImage.Create(LForm);
      LImg.Parent      := LForm;
      LImg.Stretch     := True;
      LImg.Proportional := True;
      LImg.Center      := True;
      LImg.SetBounds((FORM_W - LOGO_BOX) div 2, LY, LOGO_BOX, LOGO_BOX);
      LImg.Picture.Assign(LPng);
      LPng.Free;
      LY := LY + LOGO_BOX + 6;
    end;

    LSubtitle := TLabel.Create(LForm);
    LSubtitle.Parent     := LForm;
    LSubtitle.Alignment  := taCenter;
    LSubtitle.AutoSize   := False;
    LSubtitle.Transparent := True;
    LSubtitle.Font.Size  := 10;
    LSubtitle.Font.Style := [fsBold];
    LSubtitle.Font.Color := CLR_ACCENT;
    LSubtitle.Caption    := SUITE_SUBTITLE;
    LSubtitle.SetBounds(MARGIN, LY, FORM_W - 2 * MARGIN, 22);
    LY := LY + 28;

    LBodyStr := _BodyText;
    // Size the body to its REAL wrapped height so the last line is never clipped
    // behind OK; BODY_H is now just a floor (short text won't collapse the dialog).
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
    LBtn.Parent       := LForm;
    LBtn.Caption      := 'OK';
    LBtn.ModalResult  := mrOk;
    LBtn.Default      := True;
    LBtn.Cancel       := True;
    LBtn.SetBounds((FORM_W - BTN_W) div 2, LY, BTN_W, BTN_H);
    LY := LY + BTN_H + MARGIN;

    LForm.ClientHeight := LY;
    LForm.ShowModal;
  finally
    LForm.Free;
  end;
end;

end.
