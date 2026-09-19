unit Aefos.OTA.Chat.UI.Options.ACPRegistryFrame;

interface

uses
  Winapi.Windows,
  Winapi.Messages,
  System.SysUtils,
  System.Classes,
  Vcl.Graphics,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.Dialogs,
  Vcl.StdCtrls,
  Vcl.ExtCtrls,
  Aefos.ACP.Types,
  Aefos.ACP.Registry;

type
  TAefosACPRegistryOptionsFrame = class(TFrame)
    PanelTop: TPanel;
    LabelTitle: TLabel;
    LabelSubtitle: TLabel;
    EditSearch: TEdit;
    ButtonUpdateCatalog: TButton;
    ScrollBoxCards: TScrollBox;
    procedure EditSearchChange(Sender: TObject);
    procedure ButtonUpdateCatalogClick(Sender: TObject);
  private
    FRegistry: IACPRegistry;
    procedure RefreshCards;
    procedure OnInstallClick(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
  end;

implementation

{$R *.dfm}

constructor TAefosACPRegistryOptionsFrame.Create(AOwner: TComponent);
begin
  inherited;
  FRegistry := DefaultACPRegistry;
  RefreshCards;
end;

procedure TAefosACPRegistryOptionsFrame.EditSearchChange(Sender: TObject);
begin
  RefreshCards;
end;

procedure TAefosACPRegistryOptionsFrame.RefreshCards;
var
  LCatalog: TArray<TACPAgentManifest>;
  LAgent: TACPAgentManifest;
  LCard: TPanel;
  LTitle: TLabel;
  LDesc: TLabel;
  LMeta: TLabel;
  LBtn: TButton;
  LFilter: string;
  LTop: Integer;
  LAgentIndex: Integer;
begin
  while ScrollBoxCards.ControlCount > 0 do
    ScrollBoxCards.Controls[0].Free;

  LFilter := Trim(EditSearch.Text);
  LCatalog := FRegistry.GetCatalogAgents;
  LTop := 8;

  for LAgentIndex := 0 to High(LCatalog) do
  begin
    LAgent := LCatalog[LAgentIndex];
    if (LFilter <> '') and
       (Pos(LowerCase(LFilter), LowerCase(LAgent.Name)) = 0) and
       (Pos(LowerCase(LFilter), LowerCase(LAgent.Description)) = 0) then
      Continue;

    LCard := TPanel.Create(ScrollBoxCards);
    LCard.Parent := ScrollBoxCards;
    LCard.SetBounds(16, LTop, ScrollBoxCards.ClientWidth - 32, 90);
    LCard.BevelKind := bkFlat;
    LCard.BevelOuter := bvNone;
    LCard.Color := clWindow;

    LTitle := TLabel.Create(LCard);
    LTitle.Parent := LCard;
    LTitle.SetBounds(16, 12, 350, 18);
    LTitle.Caption := LAgent.Name + '  v' + LAgent.Version;
    LTitle.Font.Style := [fsBold];
    LTitle.Font.Height := -13;

    LMeta := TLabel.Create(LCard);
    LMeta.Parent := LCard;
    LMeta.SetBounds(16, 32, 350, 14);
    LMeta.Caption := 'Autores: ' + LAgent.Authors + '  |  Licença: ' + LAgent.License;
    LMeta.Font.Color := clGrayText;
    LMeta.Font.Height := -11;

    LDesc := TLabel.Create(LCard);
    LDesc.Parent := LCard;
    LDesc.SetBounds(16, 52, LCard.Width - 140, 28);
    LDesc.Caption := LAgent.Description;
    LDesc.WordWrap := True;

    LBtn := TButton.Create(LCard);
    LBtn.Parent := LCard;
    LBtn.SetBounds(LCard.Width - 110, 26, 95, 32);
    LBtn.Tag := LAgentIndex;
    if LAgent.Installed then
    begin
      LBtn.Caption := 'Configurado';
      LBtn.Enabled := False;
    end
    else
    begin
      LBtn.Caption := 'Instalar';
      LBtn.OnClick := OnInstallClick;
    end;

    Inc(LTop, 98);
  end;
end;

procedure TAefosACPRegistryOptionsFrame.ButtonUpdateCatalogClick(Sender: TObject);
var
  LError: string;
begin
  if FRegistry.FetchRemoteCatalog(LError) then
  begin
    ShowMessage('Catálogo de agentes ACP sincronizado com o repositório oficial!');
    RefreshCards;
  end
  else
    ShowMessage('Aviso ao consultar repositório remoto: ' + LError + sLineBreak + 'Exibindo catálogo local em cache.');
end;

procedure TAefosACPRegistryOptionsFrame.OnInstallClick(Sender: TObject);
var
  LIndex: Integer;
  LCatalog: TArray<TACPAgentManifest>;
begin
  if Sender is TButton then
  begin
    LIndex := TButton(Sender).Tag;
    LCatalog := FRegistry.GetCatalogAgents;
    if (LIndex >= 0) and (LIndex <= High(LCatalog)) then
    begin
      FRegistry.InstallAgent(LCatalog[LIndex].Id, '');
      ShowMessage('Agente ' + LCatalog[LIndex].Name + ' instalado com sucesso! Configure-o na tela Agentes & Conexões.');
      RefreshCards;
    end;
  end;
end;

end.
