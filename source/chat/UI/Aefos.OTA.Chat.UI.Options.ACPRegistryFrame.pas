unit Aefos.OTA.Chat.UI.Options.ACPRegistryFrame;

interface

uses
  Winapi.Windows,
  Winapi.Messages,
  Winapi.ShellAPI,
  System.SysUtils,
  System.Classes,
  System.NetEncoding,
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
    LabelPortalLink: TLabel;
    EditSearch: TEdit;
    ButtonUpdateCatalog: TButton;
    ScrollBoxCards: TScrollBox;
    procedure EditSearchChange(Sender: TObject);
    procedure ButtonUpdateCatalogClick(Sender: TObject);
    procedure LabelPortalLinkClick(Sender: TObject);
  protected
    procedure SetParent(AParent: TWinControl); override;
    procedure Resize; override;
    procedure CMShowingChanged(var Message: TMessage); message CM_SHOWINGCHANGED;
  private
    FRegistry: IACPRegistry;
    procedure RefreshCards;
    procedure OnInstallClick(Sender: TObject);
    procedure OnUninstallClick(Sender: TObject);
    procedure OnRegistryChanged;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

implementation

const
  MAX_DISPLAYED_AGENTS = 50;

{$R *.dfm}

constructor TAefosACPRegistryOptionsFrame.Create(AOwner: TComponent);
begin
  inherited;
  FRegistry := DefaultACPRegistry;
  FRegistry.RegisterChangeListener(OnRegistryChanged);
  RefreshCards;
end;

procedure TAefosACPRegistryOptionsFrame.SetParent(AParent: TWinControl);
begin
  inherited SetParent(AParent);
  if AParent <> nil then
  begin
    RefreshCards;
    if ScrollBoxCards.HandleAllocated then
      ScrollBoxCards.VertScrollBar.Position := 0;
  end;
end;

procedure TAefosACPRegistryOptionsFrame.Resize;
var
  I, LCardWidth: Integer;
begin
  inherited;
  if ScrollBoxCards.HandleAllocated then
  begin
    LCardWidth := ScrollBoxCards.ClientWidth - 32;
    if LCardWidth > 200 then
    begin
      for I := 0 to ScrollBoxCards.ControlCount - 1 do
        ScrollBoxCards.Controls[I].Width := LCardWidth;
    end;
  end;
end;

destructor TAefosACPRegistryOptionsFrame.Destroy;
begin
  if Assigned(FRegistry) then
    FRegistry.UnregisterChangeListener(OnRegistryChanged);
  inherited;
end;

procedure TAefosACPRegistryOptionsFrame.OnRegistryChanged;
begin
  RefreshCards;
end;

procedure TAefosACPRegistryOptionsFrame.CMShowingChanged(var Message: TMessage);
begin
  inherited;
  if Showing and ScrollBoxCards.HandleAllocated then
    ScrollBoxCards.VertScrollBar.Position := 0;
end;

procedure TAefosACPRegistryOptionsFrame.EditSearchChange(Sender: TObject);
var
  LFilter: string;
begin
  LFilter := Trim(EditSearch.Text);
  if LFilter <> '' then
    LabelPortalLink.Caption := 'Search "' + LFilter + '" on Official ACP Registry (Web) ->'
  else
    LabelPortalLink.Caption := 'Browse all agents on the Official ACP Portal (Web) ->';
  RefreshCards;
end;

procedure TAefosACPRegistryOptionsFrame.LabelPortalLinkClick(Sender: TObject);
var
  LFilter, LUrl: string;
begin
  LFilter := Trim(EditSearch.Text);
  if LFilter <> '' then
    LUrl := 'https://github.com/agentclientprotocol/registry/search?q=' + TNetEncoding.URL.Encode(LFilter)
  else
    LUrl := 'https://agentclientprotocol.com';
  ShellExecute(0, 'open', PChar(LUrl), nil, nil, SW_SHOWNORMAL);
end;

procedure TAefosACPRegistryOptionsFrame.RefreshCards;
var
  LCatalog: TArray<TACPAgentManifest>;
  LAgent: TACPAgentManifest;
  LCard, LFooterCard: TPanel;
  LTitle, LDesc, LMeta, LFooterLabel: TLabel;
  LBtn: TButton;
  LFilter, LSearchTerm: string;
  LAgentIndex: Integer;
  LMatchedCount, LDisplayedCount: Integer;
  LTop, LCardWidth: Integer;
begin
  if ScrollBoxCards.HandleAllocated then
    SendMessage(ScrollBoxCards.Handle, WM_SETREDRAW, 0, 0);
  try
    if ScrollBoxCards.HandleAllocated then
      ScrollBoxCards.VertScrollBar.Position := 0;

    while ScrollBoxCards.ControlCount > 0 do
      ScrollBoxCards.Controls[0].Free;

    LFilter := Trim(EditSearch.Text);
    LSearchTerm := LowerCase(LFilter);
    LCatalog := FRegistry.GetCatalogAgents;
    LMatchedCount := 0;
    LDisplayedCount := 0;
    LTop := 12;

    if ScrollBoxCards.HandleAllocated and (ScrollBoxCards.ClientWidth > 300) then
      LCardWidth := ScrollBoxCards.ClientWidth - 32
    else if Width > 300 then
      LCardWidth := Width - 32
    else
      LCardWidth := 560;

    for LAgentIndex := 0 to High(LCatalog) do
    begin
      LAgent := LCatalog[LAgentIndex];
      if (LSearchTerm <> '') and
         (Pos(LSearchTerm, LowerCase(LAgent.Name)) = 0) and
         (Pos(LSearchTerm, LowerCase(LAgent.Description)) = 0) and
         (Pos(LSearchTerm, LowerCase(LAgent.Id)) = 0) and
         (Pos(LSearchTerm, LowerCase(LAgent.Authors)) = 0) and
         (Pos(LSearchTerm, LowerCase(LAgent.Distribution.PackageType)) = 0) then
        Continue;

      Inc(LMatchedCount);

      if LDisplayedCount >= MAX_DISPLAYED_AGENTS then
        Continue;

      Inc(LDisplayedCount);

      LCard := TPanel.Create(ScrollBoxCards);
      LCard.Parent := ScrollBoxCards;
      LCard.SetBounds(16, LTop, LCardWidth, 104);
      LCard.Anchors := [akLeft, akTop];
      LCard.ParentBackground := True;
      LCard.BevelKind := bkNone;
      LCard.BevelOuter := bvNone;
      LCard.BevelInner := bvNone;
      LCard.BorderStyle := bsSingle;

      LTitle := TLabel.Create(LCard);
      LTitle.Parent := LCard;
      LTitle.AutoSize := False;
      LTitle.ShowAccelChar := False;
      LTitle.EllipsisPosition := epEndEllipsis;
      LTitle.SetBounds(16, 12, LCardWidth - 140, 18);
      LTitle.Anchors := [akLeft, akTop, akRight];
      if LAgent.Distribution.PackageType <> '' then
        LTitle.Caption := LAgent.Name + '  v' + LAgent.Version + '  [' + LAgent.Distribution.PackageType + ']'
      else
        LTitle.Caption := LAgent.Name + '  v' + LAgent.Version;
      LTitle.Font.Style := [fsBold];
      LTitle.Font.Height := -13;

      LMeta := TLabel.Create(LCard);
      LMeta.Parent := LCard;
      LMeta.AutoSize := False;
      LMeta.ShowAccelChar := False;
      LMeta.EllipsisPosition := epEndEllipsis;
      LMeta.SetBounds(16, 33, LCardWidth - 140, 16);
      LMeta.Anchors := [akLeft, akTop, akRight];
      LMeta.Caption := 'Authors: ' + LAgent.Authors + '   |   License: ' + LAgent.License;
      LMeta.Font.Color := clGrayText;
      LMeta.Font.Height := -11;

      LDesc := TLabel.Create(LCard);
      LDesc.Parent := LCard;
      LDesc.AutoSize := False;
      LDesc.ShowAccelChar := False;
      LDesc.WordWrap := True;
      LDesc.EllipsisPosition := epEndEllipsis;
      LDesc.SetBounds(16, 52, LCardWidth - 140, 42);
      LDesc.Anchors := [akLeft, akTop, akRight];
      LDesc.Caption := LAgent.Description;
      LDesc.Hint := LAgent.Description;
      LDesc.ShowHint := True;

      LBtn := TButton.Create(LCard);
      LBtn.Parent := LCard;
      LBtn.SetBounds(LCardWidth - 116, 36, 100, 32);
      LBtn.Anchors := [akTop, akRight];
      LBtn.TabStop := False;
      LBtn.Tag := LAgentIndex;
      if LAgent.Installed then
      begin
        LBtn.Caption := 'Uninstall';
        LBtn.Enabled := True;
        LBtn.Hint := 'Uninstall this agent from Aefos';
        LBtn.ShowHint := True;
        LBtn.OnClick := OnUninstallClick;
      end
      else
      begin
        LBtn.Caption := 'Install';
        LBtn.Enabled := True;
        LBtn.Hint := 'Install this agent into Aefos';
        LBtn.ShowHint := True;
        LBtn.OnClick := OnInstallClick;
      end;

      Inc(LTop, 114);
    end;

    // Zero matches notice
    if LMatchedCount = 0 then
    begin
      LFooterCard := TPanel.Create(ScrollBoxCards);
      LFooterCard.Parent := ScrollBoxCards;
      LFooterCard.SetBounds(16, 20, LCardWidth, 74);
      LFooterCard.Anchors := [akLeft, akTop];
      LFooterCard.ParentBackground := True;
      LFooterCard.BevelKind := bkNone;
      LFooterCard.BevelOuter := bvNone;
      LFooterCard.BevelInner := bvNone;
      LFooterCard.BorderStyle := bsSingle;

      LFooterLabel := TLabel.Create(LFooterCard);
      LFooterLabel.Parent := LFooterCard;
      LFooterLabel.AutoSize := False;
      LFooterLabel.SetBounds(16, 18, LCardWidth - 32, 38);
      LFooterLabel.Anchors := [akLeft, akTop, akRight];
      LFooterLabel.Alignment := taCenter;
      if LFilter <> '' then
        LFooterLabel.Caption := 'No agents found matching "' + LFilter + '".' + sLineBreak +
          'Click the link above to search on the Official ACP Web Registry.'
      else
        LFooterLabel.Caption := 'No agents available in the local catalog.' + sLineBreak +
          'Click "Update Catalog" to fetch from the official repository.';
      LFooterLabel.Font.Color := clGrayText;
    end
    else if LMatchedCount > MAX_DISPLAYED_AGENTS then
    begin
      // 50 item limit notice
      LFooterCard := TPanel.Create(ScrollBoxCards);
      LFooterCard.Parent := ScrollBoxCards;
      LFooterCard.SetBounds(16, LTop + 4, LCardWidth, 44);
      LFooterCard.Anchors := [akLeft, akTop];
      LFooterCard.ParentBackground := True;
      LFooterCard.BevelKind := bkNone;
      LFooterCard.BevelOuter := bvNone;
      LFooterCard.BevelInner := bvNone;
      LFooterCard.BorderStyle := bsSingle;

      LFooterLabel := TLabel.Create(LFooterCard);
      LFooterLabel.Parent := LFooterCard;
      LFooterLabel.AutoSize := False;
      LFooterLabel.SetBounds(16, 13, LCardWidth - 32, 20);
      LFooterLabel.Anchors := [akLeft, akTop, akRight];
      LFooterLabel.Alignment := taCenter;
      LFooterLabel.Caption := 'Showing first ' + IntToStr(MAX_DISPLAYED_AGENTS) + ' of ' +
        IntToStr(LMatchedCount) + ' matching agents. Type in the search box to filter.';
      LFooterLabel.Font.Color := clGrayText;
      LFooterLabel.Font.Style := [fsItalic];
    end;

    // Subtitle summary
    if LFilter <> '' then
    begin
      if LMatchedCount > MAX_DISPLAYED_AGENTS then
        LabelSubtitle.Caption := 'Showing ' + IntToStr(MAX_DISPLAYED_AGENTS) + ' of ' +
          IntToStr(LMatchedCount) + ' agents matching "' + LFilter + '".'
      else
        LabelSubtitle.Caption := 'Found ' + IntToStr(LMatchedCount) +
          ' agent(s) matching "' + LFilter + '".';
    end
    else
    begin
      if LMatchedCount > MAX_DISPLAYED_AGENTS then
        LabelSubtitle.Caption := 'Showing first ' + IntToStr(MAX_DISPLAYED_AGENTS) + ' of ' +
          IntToStr(LMatchedCount) + ' agents compatible with the ACP standard.'
      else
        LabelSubtitle.Caption := 'Discover and install agents compatible with the ACP standard (' +
          IntToStr(LMatchedCount) + ' available).';
    end;

    if ScrollBoxCards.HandleAllocated then
      ScrollBoxCards.VertScrollBar.Position := 0;
  finally
    if ScrollBoxCards.HandleAllocated then
    begin
      SendMessage(ScrollBoxCards.Handle, WM_SETREDRAW, 1, 0);
      RedrawWindow(ScrollBoxCards.Handle, nil, 0,
        RDW_ERASE or RDW_FRAME or RDW_INVALIDATE or RDW_ALLCHILDREN);
    end;
  end;
end;

procedure TAefosACPRegistryOptionsFrame.ButtonUpdateCatalogClick(Sender: TObject);
var
  LError: string;
  LLoadingCard: TPanel;
  LLoadingLabel: TLabel;
  LCardWidth: Integer;
begin
  ButtonUpdateCatalog.Enabled := False;
  ButtonUpdateCatalog.Caption := 'Updating...';
  LabelSubtitle.Caption := 'Connecting to official ACP registry (https://cdn.agentclientprotocol.com)...';
  Screen.Cursor := crHourGlass;
  try
    if ScrollBoxCards.HandleAllocated then
      ScrollBoxCards.VertScrollBar.Position := 0;

    while ScrollBoxCards.ControlCount > 0 do
      ScrollBoxCards.Controls[0].Free;

    if ScrollBoxCards.HandleAllocated and (ScrollBoxCards.ClientWidth > 300) then
      LCardWidth := ScrollBoxCards.ClientWidth - 32
    else if Width > 300 then
      LCardWidth := Width - 32
    else
      LCardWidth := 560;

    LLoadingCard := TPanel.Create(ScrollBoxCards);
    LLoadingCard.Parent := ScrollBoxCards;
    LLoadingCard.SetBounds(16, 20, LCardWidth, 80);
    LLoadingCard.Anchors := [akLeft, akTop];
    LLoadingCard.ParentBackground := True;
    LLoadingCard.BevelKind := bkNone;
    LLoadingCard.BevelOuter := bvNone;
    LLoadingCard.BevelInner := bvNone;
    LLoadingCard.BorderStyle := bsSingle;

    LLoadingLabel := TLabel.Create(LLoadingCard);
    LLoadingLabel.Parent := LLoadingCard;
    LLoadingLabel.AutoSize := False;
    LLoadingLabel.WordWrap := True;
    LLoadingLabel.SetBounds(16, 18, LCardWidth - 32, 44);
    LLoadingLabel.Anchors := [akLeft, akTop, akRight];
    LLoadingLabel.Alignment := taCenter;
    LLoadingLabel.Caption := 'Connecting to official ACP registry and downloading latest catalog...' +
      sLineBreak + 'Please wait...';
    LLoadingLabel.Font.Style := [fsBold];
    LLoadingLabel.Font.Color := clHighlight;

    ScrollBoxCards.Update;
    Update;
    Application.ProcessMessages;

    if FRegistry.FetchRemoteCatalog(LError) then
    begin
      ShowMessage('ACP agent catalog synchronized with the official registry!');
    end
    else
      ShowMessage('Warning querying remote registry: ' + LError + sLineBreak + 'Displaying cached local catalog.');
  finally
    Screen.Cursor := crDefault;
    ButtonUpdateCatalog.Caption := 'Update Catalog';
    ButtonUpdateCatalog.Enabled := True;
    RefreshCards;
  end;
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
      RefreshCards;
      ShowMessage('Agent ' + LCatalog[LIndex].Name + ' installed successfully!' + sLineBreak +
        'Go to "Agents & Connections" to configure it or set it as Default Agent.');
    end;
  end;
end;

procedure TAefosACPRegistryOptionsFrame.OnUninstallClick(Sender: TObject);
var
  LIndex: Integer;
  LCatalog: TArray<TACPAgentManifest>;
  LName, LId: string;
begin
  if Sender is TButton then
  begin
    LIndex := TButton(Sender).Tag;
    LCatalog := FRegistry.GetCatalogAgents;
    if (LIndex >= 0) and (LIndex <= High(LCatalog)) then
    begin
      LName := LCatalog[LIndex].Name;
      LId := LCatalog[LIndex].Id;
      if MessageDlg('Are you sure you want to uninstall agent "' + LName + '"?',
        mtConfirmation, [mbYes, mbNo], 0) = mrYes then
      begin
        FRegistry.UninstallAgent(LId);
        RefreshCards;
      end;
    end;
  end;
end;

end.
