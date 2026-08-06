unit Aefos.OTA.UI.MCPConsentDialog;

{
  Terminal-owned destructive-action confirmation modal (ESP-070, S2 /
  ADR-070-03).

  THE VCL consent modal -- there used to be a second, identical one under
  source\chat\UI, and this comment used to open by admitting it ("Mirrors
  Aefos.OTA.Chat.UI.MCPConsentDialog"). A copy declared in a comment is still a
  copy: the two drifted, and a redesign landed on the one nobody sees. The chat
  now uses THIS unit and the duplicate is gone.

  Every caption comes from Aefos.MCP.ConsentView, shared with the chat's HTML
  card, the Lazarus twin and the desktop popup, so a surface can differ in
  LAYOUT without inventing different WORDS. Deny is the safe-default
  focused button; Escape and the close box both resolve to cdDenied (BR12).
  Themed via IOTAIDEThemingServices when available.

  This unit is VCL+OTA. It lives in the UI layer and is never linked by
  the headless test runner (BR10 / ADR-070-02).
}

interface

uses
  System.Classes,
  Vcl.Forms,
  Vcl.Controls,
  Vcl.StdCtrls,
  Vcl.ExtCtrls,
  Aefos.MCP.Types;

type
  TMCPConsentDialog = class(TForm)
    { Control for control, this is the chat card's #ds-perm-modal. Same badge,
      same title, same tool chip, same PREVIEW label, same footer hint, and the
      same BUTTON ORDER -- Deny, Allow for this session, Allow once, right
      aligned. The old form ran that order backwards, which by itself made two
      windows read as two products. }
    shpBadge:       TShape;
    lblBadge:       TLabel;
    lblHeading:     TLabel;
    lblSummary:     TLabel;
    lblTool:        TLabel;
    lblToolHint:    TLabel;
    lblWhat:        TLabel;
    lblDetailLabel: TLabel;
    lblFootHint:    TLabel;
    memoDetail:     TMemo;
    btnAllowOnce:   TButton;
    btnAllowSession: TButton;
    btnDeny:        TButton;
    procedure btnAllowOnceClick(Sender: TObject);
    procedure btnAllowSessionClick(Sender: TObject);
    procedure btnDenyClick(Sender: TObject);
  private
    FDecision: TMCPConsentDecision;
  protected
    procedure DoShow; override;
  public
    class function Execute(const AToolName, ASummary,
      ADetail: string): TMCPConsentDecision;
  end;

implementation

{$R *.dfm}

uses
  Winapi.Windows,
  System.SysUtils,
  ToolsAPI,
  Aefos.OTA.UI.ThemeHelper,
  Aefos.MCP.ConsentView,
  Aefos.MCP.OTA.MessageTextPolicy;

const
  CDetailPreviewChars = 2048;

class function TMCPConsentDialog.Execute(const AToolName, ASummary,
  ADetail: string): TMCPConsentDecision;
var
  LForm: TMCPConsentDialog;
  {$IF Declared(IOTAIDEThemingServices)}
  LTheming: IOTAIDEThemingServices;
  {$IFEND}
  LView: TAefosConsentView;
  LDrop: Integer;
begin
  LForm := TMCPConsentDialog.Create(nil);
  try
    LForm.FDecision := cdDenied;
    // Every caption on this form comes from the shared model. Nothing is spelled
    // out here, so this surface cannot drift from the others by someone editing
    // a string in one place.
    LView := TAefosConsentModel.ForTool(AToolName, ASummary);
    LForm.Caption := 'Aefos AI - permission required';
    LForm.lblHeading.Caption := LView.Heading;
    LForm.lblSummary.Caption := LView.Summary;
    LForm.lblTool.Caption := LView.ToolChip;
    LForm.lblToolHint.Caption := LView.ToolChipHint;
    LForm.lblDetailLabel.Caption := LView.DetailLabel;
    LForm.lblFootHint.Caption := LView.FootHint;
    LForm.btnAllowOnce.Caption := LView.AllowOnce;
    LForm.btnAllowSession.Caption := LView.AllowSession;
    LForm.btnDeny.Caption := LView.Deny;
    // Repair UTF-8-as-OEM/ANSI mojibake at the display boundary (#9, ESP-093).
    // EnsureDisplayText runs on the FULL string BEFORE the preview truncation so a
    // multi-byte UTF-8 sequence is never split by Copy mid-repair (idempotent /
    // no-op once the bridge delivers clean UTF-8).
    // The per-call text goes in "what", exactly as the card does -- the summary
    // line above it is the model's fixed explanation, not this action's.
    LForm.lblWhat.Caption := TMessageTextPolicy.EnsureDisplayText(ASummary);
    LForm.memoDetail.Text := Copy(TMessageTextPolicy.EnsureDisplayText(ADetail), 1, CDetailPreviewChars);
    // An empty read-only box looks broken rather than empty.
    // No detail, no PREVIEW box AND no PREVIEW label -- an empty read-only box
    // under a heading reads as broken rather than as "nothing to show".
    LForm.memoDetail.Visible := Trim(LForm.memoDetail.Text) <> '';
    LForm.lblDetailLabel.Visible := LForm.memoDetail.Visible;
    // ...and give the height back. Hiding the box left a tall empty gap above
    // the buttons, which reads as a form that lost something rather than one
    // that had nothing to show.
    if not LForm.memoDetail.Visible then
    begin
      LDrop := LForm.memoDetail.Top + LForm.memoDetail.Height
        - LForm.lblDetailLabel.Top;
      LForm.btnDeny.Top := LForm.btnDeny.Top - LDrop;
      LForm.btnAllowSession.Top := LForm.btnAllowSession.Top - LDrop;
      LForm.btnAllowOnce.Top := LForm.btnAllowOnce.Top - LDrop;
      LForm.lblFootHint.Top := LForm.lblFootHint.Top - LDrop;
      LForm.ClientHeight := LForm.ClientHeight - LDrop;
    end;
    LForm.ActiveControl := LForm.btnDeny;
    // Terminal-driven flow (C1): the IDE process is often in the background while
    // the user works in the external terminal. Keep the prompt above the IDE
    // windows so an alt-tab back lands on a visible, answerable modal.
    LForm.FormStyle := fsStayOnTop;
    // No theming service to ask on an older ToolsAPI (10 Seattle's IDE had no
    // themes): the dialog keeps stock VCL colours, which is what the rest of
    // that IDE looks like. The dark-form patching below still runs.
    {$IF Declared(IOTAIDEThemingServices)}
    if Assigned(BorlandIDEServices) and
       Supports(BorlandIDEServices, IOTAIDEThemingServices, LTheming) then
      LTheming.ApplyTheme(LForm);
    {$IFEND}
    // The IDE's own ApplyTheme leaves a bsDialog form light even on a dark
    // theme -- which is why this dialog stayed grey next to a dark chat card,
    // the single biggest thing making the two read as different products. The
    // deleted chat copy called BOTH; only this half survived the merge.
    TThemeHelper.ApplyPremiumTheme(LForm);
    LForm.ShowModal;
    Result := LForm.FDecision;
  finally
    LForm.Free;
  end;
end;

procedure TMCPConsentDialog.DoShow;
begin
  inherited DoShow;
  // Pull the modal to the foreground and flash the taskbar so a terminal user
  // (IDE in the background) notices the prompt and can answer it (C1).
  SetForegroundWindow(Handle);
  FlashWindow(Handle, True);
end;

procedure TMCPConsentDialog.btnAllowOnceClick(Sender: TObject);
begin
  FDecision := cdAllowOnce;
  ModalResult := mrOk;
end;

procedure TMCPConsentDialog.btnAllowSessionClick(Sender: TObject);
begin
  FDecision := cdAllowSession;
  ModalResult := mrOk;
end;

procedure TMCPConsentDialog.btnDenyClick(Sender: TObject);
begin
  FDecision := cdDenied;
  ModalResult := mrCancel;
end;

end.
