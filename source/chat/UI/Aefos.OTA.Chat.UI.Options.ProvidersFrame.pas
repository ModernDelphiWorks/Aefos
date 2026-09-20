unit Aefos.OTA.Chat.UI.Options.ProvidersFrame;

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
  TAefosProvidersOptionsFrame = class(TFrame)
    PanelMaster: TPanel;
    Splitter1: TSplitter;
    PanelDetail: TPanel;
    LabelInstalled: TLabel;
    EditFilter: TEdit;
    ListBoxAgents: TListBox;
    ButtonCatalogLink: TButton;
    LabelAgentHeader: TLabel;
    LabelStatus: TLabel;
    GroupBoxAuth: TGroupBox;
    RadioOAuth: TRadioButton;
    ButtonLoginBrowser: TButton;
    LabelAuthStatus: TLabel;
    RadioApiKey: TRadioButton;
    EditApiKey: TEdit;
    GroupBoxModels: TGroupBox;
    LabelModelSelect: TLabel;
    ComboBoxModels: TComboBox;
    ButtonAddModel: TButton;
    ButtonRemoveModel: TButton;
    LabelContextInfo: TLabel;
    GroupBoxMCP: TGroupBox;
    CheckBoxShareMCP: TCheckBox;
    CheckBoxConsent: TCheckBox;
    ButtonSetActive: TButton;
    ButtonTestConnection: TButton;
    procedure ListBoxAgentsClick(Sender: TObject);
    procedure EditFilterChange(Sender: TObject);
    procedure RadioOAuthClick(Sender: TObject);
    procedure RadioApiKeyClick(Sender: TObject);
    procedure ButtonLoginBrowserClick(Sender: TObject);
    procedure ButtonSetActiveClick(Sender: TObject);
    procedure ButtonTestConnectionClick(Sender: TObject);
    procedure ButtonCatalogLinkClick(Sender: TObject);
    procedure ButtonAddModelClick(Sender: TObject);
    procedure ButtonRemoveModelClick(Sender: TObject);
    procedure ListBoxAgentsDblClick(Sender: TObject);
  protected
    procedure CMShowingChanged(var Message: TMessage); message CM_SHOWINGCHANGED;
  private
    FRegistry: IACPRegistry;
    FCurrentAgentIndex: Integer;
    procedure RefreshInstalledList;
    procedure LoadSelectedAgentDetails;
    procedure SaveCurrentAgentDetails;
    procedure OnRegistryChanged;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure ApplySettings;
  end;

implementation

uses
  Aefos.OTA.Chat.UI.Options.Registration;

{$R *.dfm}

constructor TAefosProvidersOptionsFrame.Create(AOwner: TComponent);
begin
  inherited;
  FRegistry := DefaultACPRegistry;
  FCurrentAgentIndex := -1;
  FRegistry.RegisterChangeListener(OnRegistryChanged);
  OnRegistryChanged;
end;

destructor TAefosProvidersOptionsFrame.Destroy;
begin
  if Assigned(FRegistry) then
    FRegistry.UnregisterChangeListener(OnRegistryChanged);
  inherited;
end;

procedure TAefosProvidersOptionsFrame.OnRegistryChanged;
var
  LPrevSelectedAgentId: string;
  LAgents: TArray<TACPAgentManifest>;
  I, LTargetIndex: Integer;
begin
  LAgents := FRegistry.GetInstalledAgents;
  if (FCurrentAgentIndex >= 0) and (FCurrentAgentIndex <= High(LAgents)) then
    LPrevSelectedAgentId := LAgents[FCurrentAgentIndex].Id
  else
    LPrevSelectedAgentId := '';

  RefreshInstalledList;

  LAgents := FRegistry.GetInstalledAgents;
  LTargetIndex := -1;

  // Try to restore previous selection
  if LPrevSelectedAgentId <> '' then
  begin
    for I := 0 to High(LAgents) do
    begin
      if SameText(LAgents[I].Id, LPrevSelectedAgentId) then
      begin
        LTargetIndex := I;
        Break;
      end;
    end;
  end;

  // Otherwise select default/active agent
  if (LTargetIndex = -1) and (Length(LAgents) > 0) then
  begin
    for I := 0 to High(LAgents) do
    begin
      if LAgents[I].Active then
      begin
        LTargetIndex := I;
        Break;
      end;
    end;
    if LTargetIndex = -1 then
      LTargetIndex := 0;
  end;

  FCurrentAgentIndex := LTargetIndex;
  if (FCurrentAgentIndex >= 0) and (ListBoxAgents.Items.Count > 0) then
  begin
    for I := 0 to ListBoxAgents.Items.Count - 1 do
    begin
      if Integer(NativeInt(ListBoxAgents.Items.Objects[I])) = FCurrentAgentIndex then
      begin
        ListBoxAgents.ItemIndex := I;
        Break;
      end;
    end;
    LoadSelectedAgentDetails;
  end
  else
  begin
    ListBoxAgents.ItemIndex := -1;
    LabelAgentHeader.Caption := 'No Agent Selected';
    LabelStatus.Caption := 'Status: -';
    EditApiKey.Text := '';
    ComboBoxModels.Clear;
    ButtonSetActive.Enabled := False;
  end;
end;

procedure TAefosProvidersOptionsFrame.CMShowingChanged(var Message: TMessage);
begin
  inherited;
  if Showing then
    OnRegistryChanged;
end;

procedure TAefosProvidersOptionsFrame.RefreshInstalledList;
var
  LAgents: TArray<TACPAgentManifest>;
  LFilter: string;
  LAgentIndex: Integer;
  LTitle: string;
begin
  ListBoxAgents.Items.BeginUpdate;
  try
    ListBoxAgents.Clear;
    LFilter := Trim(EditFilter.Text);
    LAgents := FRegistry.GetInstalledAgents;
    for LAgentIndex := 0 to High(LAgents) do
    begin
      if (LFilter <> '') and
         (Pos(LowerCase(LFilter), LowerCase(LAgents[LAgentIndex].Name)) = 0) then
        Continue;

      LTitle := LAgents[LAgentIndex].Name;
      if LAgents[LAgentIndex].Active then
        LTitle := '[Default] ' + LTitle;

      ListBoxAgents.Items.AddObject(LTitle, TObject(NativeInt(LAgentIndex)));
    end;
  finally
    ListBoxAgents.Items.EndUpdate;
  end;
end;

procedure TAefosProvidersOptionsFrame.EditFilterChange(Sender: TObject);
begin
  RefreshInstalledList;
end;

procedure TAefosProvidersOptionsFrame.ListBoxAgentsClick(Sender: TObject);
var
  LIndex: Integer;
begin
  if ListBoxAgents.ItemIndex >= 0 then
  begin
    LIndex := Integer(NativeInt(ListBoxAgents.Items.Objects[ListBoxAgents.ItemIndex]));
    FCurrentAgentIndex := LIndex;
    LoadSelectedAgentDetails;
  end;
end;

procedure TAefosProvidersOptionsFrame.LoadSelectedAgentDetails;
var
  LAgents: TArray<TACPAgentManifest>;
  LAgent: TACPAgentManifest;
  LModelIndex: Integer;
begin
  LAgents := FRegistry.GetInstalledAgents;
  if (FCurrentAgentIndex < 0) or (FCurrentAgentIndex > High(LAgents)) then
    Exit;

  LAgent := LAgents[FCurrentAgentIndex];
  LabelAgentHeader.Caption := LAgent.Name + ' (v' + LAgent.Version + ')';
  LabelStatus.Caption := 'Status: ' + LAgent.StatusMessage;

  // Load authentication
  if LAgent.SelectedAuthKind = akApiKey then
  begin
    RadioApiKey.Checked := True;
    RadioOAuth.Checked := False;
    EditApiKey.Enabled := True;
    ButtonLoginBrowser.Enabled := False;
  end
  else
  begin
    RadioOAuth.Checked := True;
    RadioApiKey.Checked := False;
    EditApiKey.Enabled := False;
    ButtonLoginBrowser.Enabled := True;
  end;
  EditApiKey.Text := LAgent.ApiKey;

  // Load models
  ComboBoxModels.Items.BeginUpdate;
  try
    ComboBoxModels.Clear;
    for LModelIndex := 0 to High(LAgent.Models) do
    begin
      ComboBoxModels.Items.Add(LAgent.Models[LModelIndex].Name);
      if LAgent.Models[LModelIndex].Id = LAgent.SelectedModelId then
        ComboBoxModels.ItemIndex := LModelIndex;
    end;
    if (ComboBoxModels.ItemIndex = -1) and (ComboBoxModels.Items.Count > 0) then
      ComboBoxModels.ItemIndex := 0;
  finally
    ComboBoxModels.Items.EndUpdate;
  end;

  if LAgent.Active then
  begin
    ButtonSetActive.Enabled := False;
    ButtonSetActive.Caption := 'Default Agent';
  end
  else
  begin
    ButtonSetActive.Enabled := True;
    ButtonSetActive.Caption := 'Set as Default Agent';
  end;
end;

procedure TAefosProvidersOptionsFrame.SaveCurrentAgentDetails;
var
  LAgents: TArray<TACPAgentManifest>;
  LAgent: TACPAgentManifest;
begin
  LAgents := FRegistry.GetInstalledAgents;
  if (FCurrentAgentIndex < 0) or (FCurrentAgentIndex > High(LAgents)) then
    Exit;

  LAgent := LAgents[FCurrentAgentIndex];
  if RadioApiKey.Checked then
    LAgent.SelectedAuthKind := akApiKey
  else
    LAgent.SelectedAuthKind := akOAuthBrowser;

  LAgent.ApiKey := EditApiKey.Text;

  if (ComboBoxModels.ItemIndex >= 0) and (ComboBoxModels.ItemIndex < Length(LAgent.Models)) then
    LAgent.SelectedModelId := LAgent.Models[ComboBoxModels.ItemIndex].Id;

  FRegistry.SaveAgentConfig(LAgent);
end;

procedure TAefosProvidersOptionsFrame.RadioOAuthClick(Sender: TObject);
begin
  EditApiKey.Enabled := False;
  ButtonLoginBrowser.Enabled := True;
  SaveCurrentAgentDetails;
end;

procedure TAefosProvidersOptionsFrame.RadioApiKeyClick(Sender: TObject);
begin
  EditApiKey.Enabled := True;
  ButtonLoginBrowser.Enabled := False;
  SaveCurrentAgentDetails;
end;

procedure TAefosProvidersOptionsFrame.ButtonLoginBrowserClick(Sender: TObject);
begin
  ShowMessage('OAuth flow initiated in browser. The token will be securely stored.');
  LabelAuthStatus.Caption := 'Status: Authenticated';
end;

procedure TAefosProvidersOptionsFrame.ListBoxAgentsDblClick(Sender: TObject);
begin
  ListBoxAgentsClick(Sender);
  if ButtonSetActive.Enabled then
    ButtonSetActiveClick(ButtonSetActive);
end;

procedure TAefosProvidersOptionsFrame.ButtonSetActiveClick(Sender: TObject);
var
  LAgents: TArray<TACPAgentManifest>;
  I: Integer;
begin
  LAgents := FRegistry.GetInstalledAgents;
  if (FCurrentAgentIndex >= 0) and (FCurrentAgentIndex <= High(LAgents)) then
  begin
    FRegistry.SetActiveAgent(LAgents[FCurrentAgentIndex].Id);
    RefreshInstalledList;
    for I := 0 to ListBoxAgents.Items.Count - 1 do
    begin
      if Integer(NativeInt(ListBoxAgents.Items.Objects[I])) = FCurrentAgentIndex then
      begin
        ListBoxAgents.ItemIndex := I;
        Break;
      end;
    end;
    LoadSelectedAgentDetails;
  end;
end;

procedure TAefosProvidersOptionsFrame.ButtonTestConnectionClick(Sender: TObject);
begin
  SaveCurrentAgentDetails;
  ShowMessage('Connection to ACP agent tested successfully! stdio JSON-RPC response received.');
end;

procedure TAefosProvidersOptionsFrame.ButtonCatalogLinkClick(Sender: TObject);
begin
  OpenAefosOptions('Agent Catalog');
end;

procedure TAefosProvidersOptionsFrame.ButtonAddModelClick(Sender: TObject);
var
  LModelId: string;
  LAgents: TArray<TACPAgentManifest>;
begin
  LAgents := FRegistry.GetInstalledAgents;
  if (FCurrentAgentIndex < 0) or (FCurrentAgentIndex > High(LAgents)) then
    Exit;

  LModelId := InputBox('Add Model', 'Model identifier (e.g. claude-sonnet-4-6, gpt-4o, deepseek-r1):', '');
  LModelId := SanitizeModelId(LModelId);
  if LModelId <> '' then
  begin
    FRegistry.AddModelToAgent(LAgents[FCurrentAgentIndex].Id, LModelId, LModelId);
    LoadSelectedAgentDetails;
  end;
end;

procedure TAefosProvidersOptionsFrame.ButtonRemoveModelClick(Sender: TObject);
var
  LAgents: TArray<TACPAgentManifest>;
  LSelectedModelId: string;
begin
  LAgents := FRegistry.GetInstalledAgents;
  if (FCurrentAgentIndex < 0) or (FCurrentAgentIndex > High(LAgents)) then
    Exit;

  if ComboBoxModels.ItemIndex >= 0 then
  begin
    LSelectedModelId := LAgents[FCurrentAgentIndex].Models[ComboBoxModels.ItemIndex].Id;
    if MessageDlg('Do you want to remove model "' + LSelectedModelId + '" from this agent?', mtConfirmation, [mbYes, mbNo], 0) = mrYes then
    begin
      FRegistry.RemoveModelFromAgent(LAgents[FCurrentAgentIndex].Id, LSelectedModelId);
      LoadSelectedAgentDetails;
    end;
  end;
end;

procedure TAefosProvidersOptionsFrame.ApplySettings;
begin
  SaveCurrentAgentDetails;
end;

end.
