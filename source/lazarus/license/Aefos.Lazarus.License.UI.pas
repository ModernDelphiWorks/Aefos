unit Aefos.Lazarus.License.UI;

{ Aefos license activation screen - Lazarus edition (LCL twin).

  The LCL twin of the Delphi Chat host's license screen
  (source\license\Aefos.License.UI.pas). Runtime-built LCL (CreateNew, no .lfm),
  no IDEIntf/ToolsAPI, so it links cleanly inside the design package.

  Same surface as the VCL form so both editions present the SAME license flow:
  machine fingerprint (read-only), current status, a key field, and Activate /
  Deactivate / Register / Close. On open it runs an online heartbeat (validate)
  and falls back to the cached state when offline. The Register sub-dialog
  captures the lead (email/name/company/consent), mints a free license and
  activates this machine - identical to the Delphi form.

  Mode delphiunicode to match the license core (Aefos.License.Client's `string`
  is UnicodeString); the LCL caption/text boundary is UTF-8 AnsiString, crossed
  explicitly via LazUTF8 (UTF16ToUTF8 out, UTF8ToUTF16 in) - the discipline of
  the facade. All literals are ASCII (the em dash / ellipsis are spelled as
  #$2014/#$2026 UnicodeString escapes, converted at the boundary), so the file
  needs no BOM. }

{$mode delphiunicode}{$H+}

interface

// Opens the activation/management dialog modally. Call on the main thread.
procedure ShowAefosLazLicenseDialog;

implementation

uses
  SysUtils,
  Classes,
  Forms,
  Controls,
  StdCtrls,
  Graphics,
  LazUTF8,          // UTF16ToUTF8 / UTF8ToUTF16 - core UnicodeString <-> LCL UTF-8
  Aefos.License.Client;

type
  TAefosLazLicenseForm = class(TForm)
  private
    FStatus: TLabel;
    FFinger: TLabel;
    FKey: TEdit;
    FMsg: TLabel;
    FBtnDeactivate: TButton;
    procedure _Refresh(const AMsg: string = '');
    procedure _OnActivate(Sender: TObject);
    procedure _OnDeactivate(Sender: TObject);
    procedure _OnRegister(Sender: TObject);
  public
    constructor CreateNew(AOwner: TComponent; Num: Integer = 0); override;
  end;

  TAefosLazRegisterForm = class(TForm)
  private
    FEmail: TEdit;
    FName: TEdit;
    FCompany: TEdit;
    FConsent: TCheckBox;
    FMsg: TLabel;
    FBtnRegister: TButton;
    procedure _OnRegisterClick(Sender: TObject);
    procedure _OnConsentClick(Sender: TObject);
  public
    Registered: Boolean;
    constructor CreateNew(AOwner: TComponent; Num: Integer = 0); override;
  end;

// Opens the registration dialog; True when it registered + activated this machine.
function ShowAefosLazRegisterDialog: Boolean; forward;

{ TAefosLazLicenseForm }

constructor TAefosLazLicenseForm.CreateNew(AOwner: TComponent; Num: Integer);

  function Lbl(ATop, ALeft, AWidth: Integer; const ACaption: string;
    ABold: Boolean = False): TLabel;
  begin
    Result := TLabel.Create(Self);
    Result.Parent := Self;
    Result.Transparent := True;
    Result.AutoSize := False;
    Result.SetBounds(ALeft, ATop, AWidth, 18);
    Result.Caption := UTF16ToUTF8(ACaption);
    if ABold then
      Result.Font.Style := [fsBold];
  end;

var
  LInfo: TAefosLicenseInfo;
  LBtnActivate, LBtnRegister, LBtnClose: TButton;
  LRegHint: TLabel;
begin
  inherited CreateNew(AOwner, Num);
  BorderStyle := bsDialog;
  Position := poScreenCenter;
  Caption := UTF16ToUTF8('Aefos AI ' + #$2014 + ' License');
  Font.Name := 'Segoe UI';
  Font.Size := 9;
  ClientWidth := 470;
  ClientHeight := 274;

  Lbl(16, 18, 434, 'Aefos AI ' + #$2014 + ' License activation', True);
  FStatus := Lbl(40, 18, 434, '');
  FFinger := Lbl(62, 18, 434, '');
  FFinger.Font.Color := clGrayText;

  Lbl(94, 18, 300, 'Already have a key? Paste it:');
  FKey := TEdit.Create(Self);
  FKey.Parent := Self;
  FKey.SetBounds(18, 114, 434, 24);
  FKey.TextHint := 'AEFOS-XXXXXXXXXXXXXXXXXXXXXXXX';

  LBtnActivate := TButton.Create(Self);
  LBtnActivate.Parent := Self;
  LBtnActivate.SetBounds(18, 146, 104, 28);
  LBtnActivate.Caption := 'Activate';
  LBtnActivate.Default := True;
  LBtnActivate.OnClick := _OnActivate;

  FBtnDeactivate := TButton.Create(Self);
  FBtnDeactivate.Parent := Self;
  FBtnDeactivate.SetBounds(128, 146, 160, 28);
  FBtnDeactivate.Caption := 'Deactivate (free seat)';
  FBtnDeactivate.OnClick := _OnDeactivate;

  LBtnClose := TButton.Create(Self);
  LBtnClose.Parent := Self;
  LBtnClose.SetBounds(382, 146, 70, 28);
  LBtnClose.Caption := 'Close';
  LBtnClose.ModalResult := mrClose;
  LBtnClose.Cancel := True;

  LRegHint := Lbl(186, 18, 434, 'New to Aefos AI? Get a free license instantly:');
  LRegHint.Font.Color := clGrayText;

  LBtnRegister := TButton.Create(Self);
  LBtnRegister.Parent := Self;
  LBtnRegister.SetBounds(18, 206, 300, 28);
  LBtnRegister.Caption := UTF16ToUTF8('Register for a free license' + #$2026);
  LBtnRegister.OnClick := _OnRegister;

  FMsg := Lbl(242, 18, 434, '');
  FMsg.WordWrap := True;
  FMsg.SetBounds(18, 242, 434, 28);

  FFinger.Caption := UTF16ToUTF8('This machine: ' +
    Copy(LicenseFingerprint, 1, 16) + #$2026);
  // Online heartbeat refreshes status + cache; offline falls back to cached.
  LicenseValidate(LInfo);
  _Refresh;
end;

procedure TAefosLazLicenseForm._Refresh(const AMsg: string);
var
  LInfo: TAefosLicenseInfo;
begin
  LInfo := LicenseCurrent;
  case LInfo.State of
    lsActive:
      begin
        if LInfo.ExpiresAt = '' then
          FStatus.Caption := UTF16ToUTF8('Status: ACTIVE on this machine.')
        else
          FStatus.Caption := UTF16ToUTF8('Status: ACTIVE (until ' +
            Copy(LInfo.ExpiresAt, 1, 10) + ').');
        FStatus.Font.Color := clGreen;
      end;
    lsTrial:
      begin
        FStatus.Caption := UTF16ToUTF8(Format('Status: TRIAL ' + #$2014 +
          ' %d day(s) left.', [LInfo.TrialDaysLeft]));
        FStatus.Font.Color := clNavy;
      end;
    lsExpired:
      begin
        FStatus.Caption := UTF16ToUTF8('Status: EXPIRED ' + #$2014 +
          ' activate a key to continue.');
        FStatus.Font.Color := clMaroon;
      end;
  else
    begin
      FStatus.Caption := UTF16ToUTF8('Status: NOT ACTIVATED ' + #$2014 +
        ' enter your license key.');
      FStatus.Font.Color := clMaroon;
    end;
  end;
  if LInfo.Key <> '' then
    FKey.Text := UTF16ToUTF8(LInfo.Key);
  FBtnDeactivate.Enabled := LInfo.Key <> '';
  FMsg.Caption := UTF16ToUTF8(AMsg);
end;

procedure TAefosLazLicenseForm._OnActivate(Sender: TObject);
var
  LInfo: TAefosLicenseInfo;
  LKey: string;
begin
  LKey := Trim(UTF8ToUTF16(FKey.Text));
  if LKey = '' then
  begin
    _Refresh('Enter a license key first.');
    Exit;
  end;
  Screen.Cursor := crHourGlass;
  try
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
  end;
end;

procedure TAefosLazLicenseForm._OnDeactivate(Sender: TObject);
var
  LReason: string;
begin
  Screen.Cursor := crHourGlass;
  try
    if LicenseDeactivate(LReason) then
    begin
      FKey.Text := '';
      _Refresh('This machine was deactivated ' + #$2014 +
        ' the seat is free to use elsewhere.');
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

procedure TAefosLazLicenseForm._OnRegister(Sender: TObject);
begin
  if ShowAefosLazRegisterDialog then
    _Refresh('Registered and activated on this machine.')
  else
    _Refresh;
end;

{ TAefosLazRegisterForm }

constructor TAefosLazRegisterForm.CreateNew(AOwner: TComponent; Num: Integer);

  function Lbl(ATop: Integer; const ACaption: string;
    ABold: Boolean = False): TLabel;
  begin
    Result := TLabel.Create(Self);
    Result.Parent := Self;
    Result.Transparent := True;
    Result.AutoSize := False;
    Result.SetBounds(18, ATop, 404, 18);
    Result.Caption := UTF16ToUTF8(ACaption);
    if ABold then
      Result.Font.Style := [fsBold];
  end;

  function Edt(ATop: Integer): TEdit;
  begin
    Result := TEdit.Create(Self);
    Result.Parent := Self;
    Result.SetBounds(18, ATop, 404, 24);
  end;

var
  LHint: TLabel;
  LBtnCancel: TButton;
begin
  inherited CreateNew(AOwner, Num);
  Registered := False;
  BorderStyle := bsDialog;
  Position := poScreenCenter;
  Caption := UTF16ToUTF8('Aefos AI ' + #$2014 + ' Register');
  Font.Name := 'Segoe UI';
  Font.Size := 9;
  ClientWidth := 440;
  ClientHeight := 304;

  Lbl(16, 'Register for a free Aefos AI license', True);
  LHint := Lbl(40, 'We email your serial and activate this machine right away.');
  LHint.Font.Color := clGrayText;

  Lbl(74, 'Email *');
  FEmail := Edt(94);
  Lbl(126, 'Name *');
  FName := Edt(146);
  Lbl(178, 'Company (optional)');
  FCompany := Edt(198);

  FConsent := TCheckBox.Create(Self);
  FConsent.Parent := Self;
  FConsent.SetBounds(18, 232, 404, 36);
  FConsent.Caption := UTF16ToUTF8('I agree to receive my license key and Aefos ' +
    'product updates by email, and to the storage of these details.');
  FConsent.OnClick := _OnConsentClick;

  FMsg := TLabel.Create(Self);
  FMsg.Parent := Self;
  FMsg.Transparent := True;
  FMsg.AutoSize := False;
  FMsg.WordWrap := True;
  FMsg.SetBounds(18, 272, 200, 28);
  FMsg.Font.Color := clMaroon;

  FBtnRegister := TButton.Create(Self);
  FBtnRegister.Parent := Self;
  FBtnRegister.SetBounds(232, 270, 110, 28);
  FBtnRegister.Caption := 'Register';
  FBtnRegister.Default := True;
  FBtnRegister.OnClick := _OnRegisterClick;
  FBtnRegister.Enabled := False;  // enabled only once the consent box is ticked

  LBtnCancel := TButton.Create(Self);
  LBtnCancel.Parent := Self;
  LBtnCancel.SetBounds(352, 270, 70, 28);
  LBtnCancel.Caption := 'Cancel';
  LBtnCancel.ModalResult := mrCancel;
  LBtnCancel.Cancel := True;
end;

procedure TAefosLazRegisterForm._OnRegisterClick(Sender: TObject);
var
  LInfo: TAefosLicenseInfo;
  LEmail: string;
begin
  LEmail := Trim(UTF8ToUTF16(FEmail.Text));
  if (LEmail = '') or (Pos('@', LEmail) = 0) then
  begin
    FMsg.Caption := UTF16ToUTF8('Enter a valid email address.');
    Exit;
  end;
  if Trim(UTF8ToUTF16(FName.Text)) = '' then
  begin
    FMsg.Caption := UTF16ToUTF8('Enter your name.');
    Exit;
  end;
  if not FConsent.Checked then
  begin
    FMsg.Caption := UTF16ToUTF8('Please tick the consent box to continue.');
    Exit;
  end;
  Screen.Cursor := crHourGlass;
  try
    if LicenseRegister(LEmail, Trim(UTF8ToUTF16(FName.Text)),
      Trim(UTF8ToUTF16(FCompany.Text)), True, LInfo) then
    begin
      Registered := True;
      ModalResult := mrOk;
    end
    else if LInfo.State = lsSeatLimit then
      FMsg.Caption := UTF16ToUTF8('This email already has a license in use on ' +
        'another machine. Deactivate it there first.')
    else if LInfo.Reason = 'offline' then
      FMsg.Caption := UTF16ToUTF8('Could not reach the license server. Check ' +
        'your connection.')
    else
      FMsg.Caption := UTF16ToUTF8('Registration failed: ' + LInfo.Reason);
  finally
    Screen.Cursor := crDefault;
  end;
end;

procedure TAefosLazRegisterForm._OnConsentClick(Sender: TObject);
begin
  // Gate Register on the consent: enabled only while the box is ticked.
  FBtnRegister.Enabled := FConsent.Checked;
end;

function ShowAefosLazRegisterDialog: Boolean;
var
  LForm: TAefosLazRegisterForm;
begin
  LForm := TAefosLazRegisterForm.CreateNew(nil);
  try
    LForm.ShowModal;
    Result := LForm.Registered;
  finally
    LForm.Free;
  end;
end;

procedure ShowAefosLazLicenseDialog;
var
  LForm: TAefosLazLicenseForm;
begin
  LForm := TAefosLazLicenseForm.CreateNew(nil);
  try
    LForm.ShowModal;
  finally
    LForm.Free;
  end;
end;

end.
