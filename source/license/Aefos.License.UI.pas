unit Aefos.License.UI;

{
  The Aefos license activation screen. A code-built VCL form
  (CreateNew, no .dfm) so the dedicated Aefos.License BPL stays a clean leaf:
  pure VCL, no ToolsAPI, no design resources.

  Shows: machine fingerprint (read-only), current status, a key field, and
  Activate / Deactivate / Close. On open it runs an online heartbeat (validate)
  and falls back to the cached state when offline.
}

interface

// Opens the activation/management dialog modally. Call on the main thread.
procedure ShowAefosLicenseDialog;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  Vcl.Forms,
  Vcl.Controls,
  Vcl.StdCtrls,
  Vcl.Graphics,
  Aefos.License.Client;

type
  TAefosLicenseForm = class(TForm)
  private
    FTitle: TLabel;
    FStatus: TLabel;
    FFinger: TLabel;
    FKeyLbl: TLabel;
    FKey: TEdit;
    FMsg: TLabel;
    FRegHint: TLabel;
    FBtnActivate: TButton;
    FBtnDeactivate: TButton;
    FBtnRegister: TButton;
    FBtnClose: TButton;
    procedure _Refresh(const AMsg: string = '');
    procedure _OnActivate(Sender: TObject);
    procedure _OnDeactivate(Sender: TObject);
    procedure _OnRegister(Sender: TObject);
  public
    constructor CreateNew(AOwner: TComponent; Dummy: Integer = 0); override;
  end;

// Opens the registration dialog; True when it registered + activated this machine.
function ShowAefosRegisterDialog: Boolean; forward;

constructor TAefosLicenseForm.CreateNew(AOwner: TComponent; Dummy: Integer);

  function Lbl(ATop, ALeft, AWidth: Integer; const ACaption: string;
    ABold: Boolean = False): TLabel;
  begin
    Result := TLabel.Create(Self);
    Result.Parent := Self;
    Result.SetBounds(ALeft, ATop, AWidth, 18);
    Result.Caption := ACaption;
    if ABold then Result.Font.Style := [fsBold];
  end;

var
  LInfo: TAefosLicenseInfo;
begin
  inherited CreateNew(AOwner, Dummy);
  BorderStyle := bsDialog;
  Position := poScreenCenter;
  Caption := 'Aefos AI ' + #$2014 + ' License';
  ClientWidth := 470;
  ClientHeight := 274;

  FTitle  := Lbl(16, 18, 430, 'Aefos AI ' + #$2014 + ' License activation', True);
  FStatus := Lbl(40, 18, 434, '');
  FFinger := Lbl(62, 18, 434, '');
  FFinger.Font.Color := clGrayText;

  FKeyLbl := Lbl(94, 18, 300, 'Already have a key? Paste it:');
  FKey := TEdit.Create(Self);
  FKey.Parent := Self;
  FKey.SetBounds(18, 114, 434, 24);
  FKey.TextHint := 'AEFOS-XXXXXXXXXXXXXXXXXXXXXXXX';

  FBtnActivate := TButton.Create(Self);
  FBtnActivate.Parent := Self;
  FBtnActivate.SetBounds(18, 146, 104, 28);
  FBtnActivate.Caption := 'Activate';
  FBtnActivate.Default := True;
  FBtnActivate.OnClick := _OnActivate;

  FBtnDeactivate := TButton.Create(Self);
  FBtnDeactivate.Parent := Self;
  FBtnDeactivate.SetBounds(128, 146, 160, 28);
  FBtnDeactivate.Caption := 'Deactivate (free seat)';
  FBtnDeactivate.OnClick := _OnDeactivate;

  FBtnClose := TButton.Create(Self);
  FBtnClose.Parent := Self;
  FBtnClose.SetBounds(382, 146, 70, 28);
  FBtnClose.Caption := 'Close';
  FBtnClose.ModalResult := mrClose;
  FBtnClose.Cancel := True;

  FRegHint := Lbl(186, 18, 434, 'New to Aefos AI? Get a free license instantly:');
  FRegHint.Font.Color := clGrayText;

  FBtnRegister := TButton.Create(Self);
  FBtnRegister.Parent := Self;
  FBtnRegister.SetBounds(18, 206, 300, 28);
  FBtnRegister.Caption := 'Register for a free license' + #$2026;
  FBtnRegister.OnClick := _OnRegister;

  FMsg := Lbl(242, 18, 434, '');
  FMsg.AutoSize := False;          // else it shrinks to the text and clips the wrap
  FMsg.WordWrap := True;
  FMsg.SetBounds(18, 242, 434, 28);

  FFinger.Caption := 'This machine: ' + Copy(LicenseFingerprint, 1, 16) + #$2026;
  // Online heartbeat refreshes status + cache; offline falls back to cached.
  LicenseValidate(LInfo);
  _Refresh;
end;

procedure TAefosLicenseForm._Refresh(const AMsg: string);
var
  LInfo: TAefosLicenseInfo;
begin
  LInfo := LicenseCurrent;
  case LInfo.State of
    lsActive:
      begin
        if LInfo.ExpiresAt = '' then
          FStatus.Caption := 'Status: ACTIVE on this machine.'
        else
          FStatus.Caption := 'Status: ACTIVE (until ' +
            Copy(LInfo.ExpiresAt, 1, 10) + ').';
        FStatus.Font.Color := clGreen;
      end;
    lsTrial:
      begin
        FStatus.Caption := Format('Status: TRIAL ' + #$2014 + ' %d day(s) left.',
          [LInfo.TrialDaysLeft]);
        FStatus.Font.Color := clNavy;
      end;
    lsExpired:
      begin
        FStatus.Caption := 'Status: EXPIRED ' + #$2014 + ' activate a key to continue.';
        FStatus.Font.Color := clMaroon;
      end;
  else
    begin
      FStatus.Caption := 'Status: NOT ACTIVATED ' + #$2014 + ' enter your license key.';
      FStatus.Font.Color := clMaroon;
    end;
  end;
  if LInfo.Key <> '' then
    FKey.Text := LInfo.Key;
  FBtnDeactivate.Enabled := LInfo.Key <> '';
  FMsg.Caption := AMsg;
end;

procedure TAefosLicenseForm._OnActivate(Sender: TObject);
var
  LInfo: TAefosLicenseInfo;
  LKey: string;
begin
  LKey := Trim(FKey.Text);
  if LKey = '' then
  begin
    _Refresh('Enter a license key first.');
    Exit;
  end;
  FBtnActivate.Enabled := False;
  try
    Screen.Cursor := crHourGlass;
    if LicenseActivate(LKey, LInfo) then
      _Refresh('Activated. Thank you!')
    else
      case LInfo.State of
        lsSeatLimit:
          _Refresh('All seats are in use. Deactivate another machine first, '
            + 'then activate here.');
        lsExpired:
          _Refresh('This key has expired.');
        lsInvalid:
          _Refresh('Invalid key. Check it and try again.');
      else
        if LInfo.Reason = 'offline' then
          _Refresh('Could not reach the license server. Check your connection.')
        else
          _Refresh('Activation failed: ' + LInfo.Reason);
      end;
  finally
    Screen.Cursor := crDefault;
    FBtnActivate.Enabled := True;
  end;
end;

procedure TAefosLicenseForm._OnDeactivate(Sender: TObject);
var
  LReason: string;
begin
  FBtnDeactivate.Enabled := False;
  try
    Screen.Cursor := crHourGlass;
    if LicenseDeactivate(LReason) then
    begin
      FKey.Text := '';
      _Refresh('This machine was deactivated ' + #$2014 + ' the seat is free to use elsewhere.');
    end
    else if LReason = 'offline' then
      _Refresh('Could not reach the license server to deactivate.')
    else if LReason = 'no-key' then
      _Refresh('No active key on this machine.')
    else
      _Refresh('Deactivation failed: ' + LReason);
  finally
    Screen.Cursor := crDefault;
  end;
end;

procedure TAefosLicenseForm._OnRegister(Sender: TObject);
begin
  if ShowAefosRegisterDialog then
    _Refresh('Registered and activated on this machine.')
  else
    _Refresh;
end;

{ ── Registration dialog (lead capture -> mint -> auto-activate) ───────────── }

type
  TAefosRegisterForm = class(TForm)
  private
    FEmail: TEdit;
    FName: TEdit;
    FCompany: TEdit;
    FConsent: TCheckBox;
    FMsg: TLabel;
    FBtnRegister: TButton;
    FBtnCancel: TButton;
    procedure _OnRegisterClick(Sender: TObject);
    procedure _OnConsentClick(Sender: TObject);
  public
    Registered: Boolean;
    constructor CreateNew(AOwner: TComponent; Dummy: Integer = 0); override;
  end;

constructor TAefosRegisterForm.CreateNew(AOwner: TComponent; Dummy: Integer);

  function Lbl(ATop: Integer; const ACaption: string;
    ABold: Boolean = False): TLabel;
  begin
    Result := TLabel.Create(Self);
    Result.Parent := Self;
    Result.SetBounds(18, ATop, 404, 18);
    Result.Caption := ACaption;
    if ABold then Result.Font.Style := [fsBold];
  end;

  function Edt(ATop: Integer): TEdit;
  begin
    Result := TEdit.Create(Self);
    Result.Parent := Self;
    Result.SetBounds(18, ATop, 404, 24);
  end;

begin
  inherited CreateNew(AOwner, Dummy);
  BorderStyle := bsDialog;
  Position := poScreenCenter;
  Caption := 'Aefos AI ' + #$2014 + ' Register';
  ClientWidth := 440;
  ClientHeight := 304;

  Lbl(16, 'Register for a free Aefos AI license', True);
  Lbl(40, 'We email your serial and activate this machine right away.')
    .Font.Color := clGrayText;

  Lbl(74, 'Email *');
  FEmail := Edt(94);
  Lbl(126, 'Name *');
  FName := Edt(146);
  Lbl(178, 'Company (optional)');
  FCompany := Edt(198);

  FConsent := TCheckBox.Create(Self);
  FConsent.Parent := Self;
  FConsent.SetBounds(18, 232, 404, 36);
  FConsent.WordWrap := True;
  FConsent.Caption := 'I agree to receive my license key and Aefos product ' +
    'updates by email, and to the storage of these details.';
  FConsent.OnClick := _OnConsentClick;

  FMsg := TLabel.Create(Self);
  FMsg.Parent := Self;
  FMsg.SetBounds(18, 272, 200, 28);
  FMsg.WordWrap := True;
  FMsg.Font.Color := clMaroon;

  FBtnRegister := TButton.Create(Self);
  FBtnRegister.Parent := Self;
  FBtnRegister.SetBounds(232, 270, 110, 28);
  FBtnRegister.Caption := 'Register';
  FBtnRegister.Default := True;
  FBtnRegister.OnClick := _OnRegisterClick;
  FBtnRegister.Enabled := False;  // enabled only once the consent box is ticked

  FBtnCancel := TButton.Create(Self);
  FBtnCancel.Parent := Self;
  FBtnCancel.SetBounds(352, 270, 70, 28);
  FBtnCancel.Caption := 'Cancel';
  FBtnCancel.ModalResult := mrCancel;
  FBtnCancel.Cancel := True;
end;

procedure TAefosRegisterForm._OnRegisterClick(Sender: TObject);
var
  LInfo: TAefosLicenseInfo;
  LEmail: string;
begin
  LEmail := Trim(FEmail.Text);
  if (LEmail = '') or (Pos('@', LEmail) = 0) then
  begin
    FMsg.Caption := 'Enter a valid email address.';
    Exit;
  end;
  if Trim(FName.Text) = '' then
  begin
    FMsg.Caption := 'Enter your name.';
    Exit;
  end;
  if not FConsent.Checked then
  begin
    FMsg.Caption := 'Please tick the consent box to continue.';
    Exit;
  end;
  FBtnRegister.Enabled := False;
  try
    Screen.Cursor := crHourGlass;
    if LicenseRegister(LEmail, Trim(FName.Text), Trim(FCompany.Text),
      True, LInfo) then
    begin
      Registered := True;
      ModalResult := mrOk;
    end
    else if LInfo.State = lsSeatLimit then
      FMsg.Caption := 'This email already has a license in use on another ' +
        'machine. Deactivate it there first.'
    else if LInfo.Reason = 'offline' then
      FMsg.Caption := 'Could not reach the license server. Check your connection.'
    else
      FMsg.Caption := 'Registration failed: ' + LInfo.Reason;
  finally
    Screen.Cursor := crDefault;
    FBtnRegister.Enabled := True;
  end;
end;

procedure TAefosRegisterForm._OnConsentClick(Sender: TObject);
begin
  // Gate Register on the LGPD consent: enabled only while the box is ticked.
  FBtnRegister.Enabled := FConsent.Checked;
end;

function ShowAefosRegisterDialog: Boolean;
var
  LForm: TAefosRegisterForm;
begin
  LForm := TAefosRegisterForm.CreateNew(nil);
  try
    LForm.ShowModal;
    Result := LForm.Registered;
  finally
    LForm.Free;
  end;
end;

procedure ShowAefosLicenseDialog;
var
  LForm: TAefosLicenseForm;
begin
  LForm := TAefosLicenseForm.CreateNew(nil);
  try
    LForm.ShowModal;
  finally
    LForm.Free;
  end;
end;

end.
