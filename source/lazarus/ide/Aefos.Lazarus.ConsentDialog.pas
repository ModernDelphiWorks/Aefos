unit Aefos.Lazarus.ConsentDialog;

{ Terminal-owned destructive-action confirmation modal - Lazarus edition.

  The LCL twin of the Delphi terminal host's consent dialog
  (source\mcp\OTA\Aefos.OTA.UI.MCPConsentDialog.pas). A terminal user drives the
  external AI CLI with the IDE in the background, so a write/run request pops
  this modal: a summary of what the tool wants, a detail box, and the SAME three
  choices the Delphi form offers - "Allow once", "Allow for this session",
  "Deny". Deny is the focused safe default; Escape and the close box both resolve
  to cdDenied. The dialog stays on top and pulls itself to the foreground (with a
  taskbar flash) so an alt-tab back lands on an answerable modal - mirroring the
  Delphi form's DoShow.

  The Chat edition needs no such form: its approvals render inline in the chat
  WebView. This is the TERMINAL path only.

  Runtime-built LCL (no .lfm), no IDEIntf/ToolsAPI, so it links cleanly in the
  design package. Mode delphiunicode to match the MCP core's TMCPConsentDecision
  and `string` (= UnicodeString); the LCL caption/text boundary is UTF-8
  AnsiString, crossed explicitly via LazUTF8 (the discipline of the facade). All
  literals are ASCII, so the file needs no BOM. }

{$mode delphiunicode}

interface

uses
  Aefos.MCP.Types;   // TMCPConsentDecision (cdAllowOnce / cdAllowSession / cdDenied)

type
  { Shows the branded 3-choice consent modal and returns the decision. cdDenied
    is the safe default on any dismissal (Escape / close box / never shown). }
  TAefosLazConsentDialog = class
  public
    class function Execute(const AToolName, ASummary,
      ADetail: string): TMCPConsentDecision; static;
  end;

implementation

uses
  Windows,       // SetForegroundWindow / FlashWindow - surface the modal for a terminal user
  Classes,
  Forms,
  Controls,
  StdCtrls,
  Graphics,
  LazUTF8;       // UTF16ToUTF8 - MCP-core UnicodeString -> LCL UTF-8 AnsiString

const
  CDetailPreviewChars = 2048;   // cap the detail box (parity with the Delphi form)

type
  { Runtime-built consent form. The click handlers and DoShow must be methods, so
    the form is a real class; Execute builds its controls. }
  TAefosConsentModalForm = class(TForm)
  private
    FDecision: TMCPConsentDecision;
    procedure OnAllowOnceClick(Sender: TObject);
    procedure OnAllowSessionClick(Sender: TObject);
    procedure OnDenyClick(Sender: TObject);
  protected
    procedure DoShow; override;
  end;

procedure TAefosConsentModalForm.OnAllowOnceClick(Sender: TObject);
begin
  FDecision := cdAllowOnce;
  ModalResult := mrOk;
end;

procedure TAefosConsentModalForm.OnAllowSessionClick(Sender: TObject);
begin
  FDecision := cdAllowSession;
  ModalResult := mrOk;
end;

procedure TAefosConsentModalForm.OnDenyClick(Sender: TObject);
begin
  FDecision := cdDenied;
  ModalResult := mrCancel;
end;

procedure TAefosConsentModalForm.DoShow;
begin
  inherited DoShow;
  // Pull the modal to the foreground and flash the taskbar so a terminal user
  // (IDE in the background) notices the prompt and can answer it.
  SetForegroundWindow(Handle);
  FlashWindow(Handle, True);
end;

class function TAefosLazConsentDialog.Execute(const AToolName, ASummary,
  ADetail: string): TMCPConsentDecision;
const
  MARGIN   = 16;
  FORM_W   = 470;
  SUMM_H   = 44;
  MEMO_H   = 150;
  BTN_H    = 30;
  BTN_W1   = 110;   // Allow once
  BTN_W2   = 160;   // Allow for this session
  BTN_W3   = 90;    // Deny
  GAP      = 8;
var
  LForm:     TAefosConsentModalForm;
  LSummary:  TLabel;
  LMemo:     TMemo;
  LOnce:     TButton;
  LSession:  TButton;
  LDeny:     TButton;
  LY:        Integer;
  LBtnX:     Integer;
  LDetail:   string;
begin
  Result := cdDenied;
  LForm := TAefosConsentModalForm.CreateNew(nil);
  try
    LForm.FDecision   := cdDenied;
    LForm.BorderStyle := bsDialog;
    LForm.BorderIcons := [biSystemMenu];
    LForm.Caption     := UTF16ToUTF8('Aefos Terminal - confirm ' + AToolName);
    LForm.Position    := poScreenCenter;
    LForm.Font.Name   := 'Segoe UI';
    LForm.Font.Size   := 9;
    LForm.ClientWidth := FORM_W;
    // Terminal-driven flow: the IDE is usually behind the external terminal, so
    // keep the prompt above the IDE windows.
    LForm.FormStyle   := fsStayOnTop;

    LY := MARGIN;

    LSummary := TLabel.Create(LForm);
    LSummary.Parent   := LForm;
    LSummary.WordWrap := True;
    LSummary.AutoSize := False;
    LSummary.Caption  := UTF16ToUTF8(ASummary);
    LSummary.SetBounds(MARGIN, LY, FORM_W - 2 * MARGIN, SUMM_H);
    LY := LY + SUMM_H + GAP;

    LDetail := Copy(ADetail, 1, CDetailPreviewChars);
    LMemo := TMemo.Create(LForm);
    LMemo.Parent     := LForm;
    LMemo.ReadOnly   := True;
    LMemo.ScrollBars := ssAutoVertical;
    LMemo.WordWrap   := True;
    LMemo.TabStop    := False;
    LMemo.Text       := UTF16ToUTF8(LDetail);
    LMemo.SetBounds(MARGIN, LY, FORM_W - 2 * MARGIN, MEMO_H);
    LY := LY + MEMO_H + GAP + 4;

    // Button row, left-to-right: Allow once | Allow for this session | Deny,
    // right-aligned as a group (same order as the Delphi form).
    LBtnX := FORM_W - MARGIN - (BTN_W1 + BTN_W2 + BTN_W3 + 2 * GAP);

    LOnce := TButton.Create(LForm);
    LOnce.Parent  := LForm;
    LOnce.Caption := 'Allow once';
    LOnce.OnClick := LForm.OnAllowOnceClick;
    LOnce.SetBounds(LBtnX, LY, BTN_W1, BTN_H);

    LSession := TButton.Create(LForm);
    LSession.Parent  := LForm;
    LSession.Caption := 'Allow for this session';
    LSession.OnClick := LForm.OnAllowSessionClick;
    LSession.SetBounds(LBtnX + BTN_W1 + GAP, LY, BTN_W2, BTN_H);

    LDeny := TButton.Create(LForm);
    LDeny.Parent  := LForm;
    LDeny.Caption := 'Deny';
    LDeny.OnClick := LForm.OnDenyClick;
    LDeny.Cancel  := True;   // Escape / close box -> Deny (safe default)
    LDeny.SetBounds(LBtnX + BTN_W1 + BTN_W2 + 2 * GAP, LY, BTN_W3, BTN_H);
    LY := LY + BTN_H + MARGIN;

    LForm.ClientHeight  := LY;
    LForm.ActiveControl := LDeny;   // focus the safe default
    LForm.ShowModal;
    Result := LForm.FDecision;
  finally
    LForm.Free;
  end;
end;

end.
