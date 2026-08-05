unit Aefos.Lazarus.IssueReport;

{ Aefos AI - Lazarus edition: the ProposeAefosIssue backend (editable dialog +
  browser hand-off).

  The LCL twin of the RAD Studio tool (source\mcp\OTA\Aefos.OTA.MCP.IssueReport.pas).
  Golden rule (design 2026-06-24, mirrored here): the agent NEVER writes to
  GitHub. It only PROPOSES a symptom; this unit shows an EDITABLE dialog (the
  agent's prose pre-filled) with a deterministic FACT block the plugin appends
  ITSELF (Aefos / IDE / OS versions) so it cannot be forged by the prose. On
  "Send" the pre-filled GitHub new-issue URL opens in the browser and the human
  reviews + clicks Submit. No backend, no token - the human gate on the editable
  dialog + the explicit browser Submit removes ~all spam risk.

  The MCP-side gate (the "Issue reporting" toggle) lives in the registrar
  (Aefos.Lazarus.McpTools): when the toggle is OFF the dialog never opens. This
  unit is the UI + URL slice only, and it is always driven on the IDE main thread
  by the registrar's per-call carrier (the dialog + OpenURL are UI work).

  FACT parity - honest degrade where the RAD path uses OTA the Lazarus edition
  lacks:
    * Aefos: the plugin version. The design-time BPL carries no FileVersion
      resource the way the RAD module does, so we report the same constant the
      About dialog shows (kept in sync by scripts\bump-version.ps1), NOT a forged
      "read from module".
    * IDE: Lazarus/LCL version (LCLVersion.lcl_version) + the FPC compiler version
      ({$I %FPCVERSION%}) - the Lazarus equivalent of the RAD "BDS <n>" line.
    * OS: the Windows version from the RTL globals (Win32MajorVersion /
      Win32MinorVersion / Win32BuildNumber) - the equivalent of TOSVersion, which
      FPC 3.2.2's SysUtils does not provide.

  Runtime-built LCL (no .lfm), no IDEIntf/ToolsAPI, so it links cleanly in the
  design package (same discipline as the sibling ConsentDialog). Mode
  delphiunicode to match the MCP core's `string` (= UnicodeString); the LCL
  caption/text boundary and the URL-encoder are UTF-8 AnsiString, crossed
  explicitly via LazUTF8. All literals are ASCII, so the file needs no BOM. }

{$mode delphiunicode}

interface

type
  { Shows the editable issue dialog and, on Send, opens the pre-filled GitHub
    new-issue URL in the browser. Returns True (sent) with AUrl set to the opened
    URL, or False on Cancel / empty title (mirror of the RAD _ShowIssueDialog +
    _OpenGitHubIssue pair). }
  TAefosLazIssueReport = class
  private
    { The deterministic FACT block (plugin-supplied, not forgeable by the prose):
      Aefos / IDE (LCL + FPC) / OS versions, plain markdown. }
    class function _BuildFact: string; static;
    { RFC-3986 percent-encoding of AValue's UTF-8 bytes for a query parameter
      (the URL-encode the RAD path gets from TNetEncoding.URL.Encode). }
    class function _PercentEncode(const AValue: string): string; static;
    { The editable modal (TEdit title + TMemo body pre-filled + read-only TMemo
      FACT + Send/Cancel). On Send: AEditedTitle = trimmed title, AEditedBody =
      prose + separator + FACT; returns True only when the title is non-empty. }
    class function _ShowDialog(const ATitle, AProblem, ASolution, AFact: string;
      out AEditedTitle, AEditedBody: string): Boolean; static;
  public
    class function Execute(const ATitle, AProblem, ASolution: string;
      out AUrl: string): Boolean; static;
  end;

implementation

uses
  SysUtils,       // Win32*Version RTL globals (win sysutils), Trim
  Forms,
  Controls,       // mrOk / mrCancel (LCL ModalResult constants), TForm.ShowModal
  StdCtrls,
  LCLIntf,        // OpenURL - open the pre-filled issue page in the browser
  LCLVersion,     // lcl_version - the Lazarus/LCL version for the FACT block
  LazUTF8,        // UTF16ToUTF8 / UTF8ToUTF16 - UnicodeString <-> LCL UTF-8 boundary
  httpprotocol;   // HTTPEncode - percent-encode a query parameter (fcl-web, RTL)

const
  cIssueRepoUrl = 'https://github.com/ModernDelphiWorks/Aefos/issues/new';
  // The plugin version shown in the FACT block. Matches the About dialog's
  // 'Version: 1.1.0' line (Aefos.Lazarus.AboutForm) and is kept in sync by
  // scripts\bump-version.ps1 so it never drifts behind a release.
  cPluginVersion = '1.1.0';

class function TAefosLazIssueReport._BuildFact: string;
begin
  // Plain markdown, appended to the body and shown read-only (mirror of the RAD
  // _BuildFact). Win32*Version are RTL dwords - widened to Int64 for IntToStr.
  Result :=
    '- Aefos: ' + cPluginVersion + sLineBreak +
    '- IDE: Lazarus/LCL ' + lcl_version + ', FPC ' + {$I %FPCVERSION%} + sLineBreak +
    '- OS: Windows ' + IntToStr(Int64(Win32MajorVersion)) + '.' +
      IntToStr(Int64(Win32MinorVersion)) + '.' +
      IntToStr(Int64(Win32BuildNumber));
end;

class function TAefosLazIssueReport._PercentEncode(const AValue: string): string;
begin
  // HTTPEncode (fcl-web httpprotocol) percent-encodes every byte that is not an
  // unreserved query char (space -> '+', others -> %XX). Feed it the UTF-8 bytes
  // of the value so non-ASCII prose encodes exactly as GitHub expects; the result
  // is pure ASCII, safely widened back to UnicodeString.
  Result := HTTPEncode(UTF16ToUTF8(AValue));
end;

class function TAefosLazIssueReport._ShowDialog(const ATitle, AProblem, ASolution,
  AFact: string; out AEditedTitle, AEditedBody: string): Boolean;
var
  LForm: TForm;
  LLblTitle, LLblBody, LLblFact: TLabel;
  LEdtTitle: TEdit;
  LMemoBody, LMemoFact: TMemo;
  LBtnSend, LBtnCancel: TButton;
begin
  AEditedTitle := '';
  AEditedBody := '';
  Result := False;
  LForm := TForm.CreateNew(nil);
  try
    LForm.Caption := 'Aefos AI - Report an issue';
    LForm.BorderStyle := bsDialog;
    LForm.Position := poScreenCenter;
    LForm.ClientWidth := 600;
    LForm.ClientHeight := 520;

    LLblTitle := TLabel.Create(LForm);
    LLblTitle.Parent := LForm;
    LLblTitle.SetBounds(16, 12, 560, 16);
    LLblTitle.Caption := 'Title';

    LEdtTitle := TEdit.Create(LForm);
    LEdtTitle.Parent := LForm;
    LEdtTitle.SetBounds(16, 32, 568, 24);
    LEdtTitle.Text := UTF16ToUTF8(ATitle);

    LLblBody := TLabel.Create(LForm);
    LLblBody.Parent := LForm;
    LLblBody.SetBounds(16, 68, 560, 16);
    LLblBody.Caption := 'Description (editable) - problem and possible solution';

    LMemoBody := TMemo.Create(LForm);
    LMemoBody.Parent := LForm;
    LMemoBody.SetBounds(16, 88, 568, 240);
    LMemoBody.ScrollBars := ssVertical;
    LMemoBody.WordWrap := True;
    LMemoBody.Lines.Add('## Problem');
    LMemoBody.Lines.Add(UTF16ToUTF8(AProblem));
    LMemoBody.Lines.Add('');
    LMemoBody.Lines.Add('## Possible solution');
    LMemoBody.Lines.Add(UTF16ToUTF8(ASolution));

    LLblFact := TLabel.Create(LForm);
    LLblFact.Parent := LForm;
    LLblFact.SetBounds(16, 340, 560, 16);
    LLblFact.Caption := 'Attached automatically by Aefos (not editable)';

    LMemoFact := TMemo.Create(LForm);
    LMemoFact.Parent := LForm;
    LMemoFact.SetBounds(16, 360, 568, 88);
    LMemoFact.ReadOnly := True;
    LMemoFact.Text := UTF16ToUTF8(AFact);

    LBtnSend := TButton.Create(LForm);
    LBtnSend.Parent := LForm;
    LBtnSend.SetBounds(396, 468, 90, 32);
    LBtnSend.Caption := 'Send';
    LBtnSend.Default := True;
    LBtnSend.ModalResult := mrOk;

    LBtnCancel := TButton.Create(LForm);
    LBtnCancel.Parent := LForm;
    LBtnCancel.SetBounds(494, 468, 90, 32);
    LBtnCancel.Caption := 'Cancel';
    LBtnCancel.Cancel := True;
    LBtnCancel.ModalResult := mrCancel;

    if LForm.ShowModal = mrOk then
    begin
      AEditedTitle := Trim(UTF8ToUTF16(LEdtTitle.Text));
      // Prose (user-editable) + a separator + the deterministic FACT block, so
      // the environment is clearly attached-by-Aefos and separate from the prose.
      AEditedBody := UTF8ToUTF16(LMemoBody.Lines.Text) + sLineBreak + sLineBreak +
        '---' + sLineBreak +
        '### Environment (attached by Aefos)' + sLineBreak +
        AFact;
      Result := AEditedTitle <> '';
    end;
  finally
    LForm.Free;
  end;
end;

class function TAefosLazIssueReport.Execute(const ATitle, AProblem, ASolution: string;
  out AUrl: string): Boolean;
var
  LFact, LEditedTitle, LEditedBody: string;
begin
  AUrl := '';
  Result := False;
  LFact := _BuildFact;
  if not _ShowDialog(ATitle, AProblem, ASolution, LFact,
       LEditedTitle, LEditedBody) then
    Exit;
  AUrl := cIssueRepoUrl +
    '?title=' + _PercentEncode(LEditedTitle) +
    '&body=' + _PercentEncode(LEditedBody);
  OpenURL(UTF16ToUTF8(AUrl));
  Result := True;
end;

end.
