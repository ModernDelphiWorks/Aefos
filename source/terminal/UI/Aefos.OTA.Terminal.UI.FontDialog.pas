unit Aefos.OTA.Terminal.UI.FontDialog;

interface

uses
  System.Classes,
  Vcl.Controls, Vcl.Forms, Vcl.StdCtrls, Vcl.ExtCtrls,
  Aefos.OTA.Terminal.UI.ThemedForm;

type
  TAefosTerminalFontDialog = class(TAefosTerminalThemedForm)
    lblFontTitle: TLabel;
    lblSizeTitle: TLabel;
    lstFonts: TListBox;
    lstSizes: TListBox;
    gbxPreview: TGroupBox;
    lblPreview: TLabel;
    pnlButtons: TPanel;
    btnOK: TButton;
    btnCancel: TButton;
    procedure lstFontsClick(Sender: TObject);
    procedure lstSizesClick(Sender: TObject);
  private
    procedure _InitFonts;
    procedure _UpdatePreview;
    function _GetSelectedFontName: string;
    function _GetSelectedFontSize: Integer;
    procedure _SetSelectedFontName(const AName: string);
    procedure _SetSelectedFontSize(const ASize: Integer);
  public
    constructor Create(AOwner: TComponent); override;
    class function Execute(var AFontName: string; var AFontSize: Integer): Boolean;
  end;

implementation

uses
  System.SysUtils, System.StrUtils;

{$R *.dfm}

{ TAefosTerminalFontDialog }

constructor TAefosTerminalFontDialog.Create(AOwner: TComponent);
begin
  // Theme is applied by the TAefosTerminalThemedForm base constructor
  // (ESP-077) after DFM streaming — same timing as the former manual call.
  inherited Create(AOwner);

  DoubleBuffered := True;
  _InitFonts;
end;

procedure TAefosTerminalFontDialog._InitFonts;
var
  LFontName: string;
  LList: TStringList;
begin
  lstFonts.Items.BeginUpdate;
  LList := TStringList.Create;
  try
    LList.Sorted := True;
    LList.Duplicates := dupIgnore;

    // Scan and add monospaced and Nerd Fonts only
    for LFontName in Screen.Fonts do
    begin
      // Filter for Nerd Fonts and standard monospaced coding fonts
      if ContainsText(LFontName, 'Mono') or
         ContainsText(LFontName, 'NF') or
         ContainsText(LFontName, 'NFM') or
         ContainsText(LFontName, 'Nerd') or
         ContainsText(LFontName, 'Console') or
         ContainsText(LFontName, 'Code') or
         ContainsText(LFontName, 'Courier') or
         ContainsText(LFontName, 'Consolas') or
         ContainsText(LFontName, 'Terminal') or
         ContainsText(LFontName, 'Cove') or
         ContainsText(LFontName, 'Caskaydia') or
         ContainsText(LFontName, 'Cascadia') or
         ContainsText(LFontName, 'Fixed') then
      begin
        LList.Add(LFontName);
      end;
    end;

    if LList.Count = 0 then
    begin
      LList.Add('Consolas');
      LList.Add('Courier New');
    end;

    lstFonts.Items.Assign(LList);
  finally
    LList.Free;
    lstFonts.Items.EndUpdate;
  end;
end;

procedure TAefosTerminalFontDialog._UpdatePreview;
var
  LFontName: string;
  LSize: Integer;
begin
  LFontName := _GetSelectedFontName;
  LSize := _GetSelectedFontSize;

  if LFontName <> '' then
    lblPreview.Font.Name := LFontName;

  if LSize > 0 then
    lblPreview.Font.Size := LSize;
end;

function TAefosTerminalFontDialog._GetSelectedFontName: string;
begin
  Result := '';
  if lstFonts.ItemIndex >= 0 then
    Result := lstFonts.Items[lstFonts.ItemIndex];
end;

function TAefosTerminalFontDialog._GetSelectedFontSize: Integer;
begin
  Result := 10;
  if lstSizes.ItemIndex >= 0 then
    Result := StrToIntDef(lstSizes.Items[lstSizes.ItemIndex], 10);
end;

procedure TAefosTerminalFontDialog._SetSelectedFontName(const AName: string);
var
  LIndex: Integer;
begin
  LIndex := lstFonts.Items.IndexOf(AName);
  if LIndex >= 0 then
  begin
    lstFonts.ItemIndex := LIndex;
    lstFonts.TopIndex := LIndex;
  end
  else
  begin
    // Partial matching if exact name is not found
    for LIndex := 0 to lstFonts.Items.Count - 1 do
    begin
      if ContainsText(lstFonts.Items[LIndex], AName) or ContainsText(AName, lstFonts.Items[LIndex]) then
      begin
        lstFonts.ItemIndex := LIndex;
        lstFonts.TopIndex := LIndex;
        Exit;
      end;
    end;
  end;
end;

procedure TAefosTerminalFontDialog._SetSelectedFontSize(const ASize: Integer);
var
  LIndex: Integer;
  LSizeStr: string;
begin
  LSizeStr := IntToStr(ASize);
  LIndex := lstSizes.Items.IndexOf(LSizeStr);
  if LIndex >= 0 then
  begin
    lstSizes.ItemIndex := LIndex;
    lstSizes.TopIndex := LIndex;
  end
  else
  begin
    // Add custom size if not present in the default list
    lstSizes.Items.Add(LSizeStr);
    LIndex := lstSizes.Items.IndexOf(LSizeStr);
    lstSizes.ItemIndex := LIndex;
    lstSizes.TopIndex := LIndex;
  end;
end;

procedure TAefosTerminalFontDialog.lstFontsClick(Sender: TObject);
begin
  _UpdatePreview;
end;

procedure TAefosTerminalFontDialog.lstSizesClick(Sender: TObject);
begin
  _UpdatePreview;
end;

class function TAefosTerminalFontDialog.Execute(var AFontName: string; var AFontSize: Integer): Boolean;
var
  LDialog: TAefosTerminalFontDialog;
begin
  Result := False;
  LDialog := TAefosTerminalFontDialog.Create(nil);
  try
    LDialog._SetSelectedFontName(AFontName);
    LDialog._SetSelectedFontSize(AFontSize);
    LDialog._UpdatePreview;

    if LDialog.ShowModal = mrOk then
    begin
      AFontName := LDialog._GetSelectedFontName;
      AFontSize := LDialog._GetSelectedFontSize;
      Result := True;
    end;
  finally
    LDialog.Free;
  end;
end;

end.


