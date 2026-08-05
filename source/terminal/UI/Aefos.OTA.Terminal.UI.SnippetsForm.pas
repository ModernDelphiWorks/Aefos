unit Aefos.OTA.Terminal.UI.SnippetsForm;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants, System.Classes,
  System.Generics.Collections, Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs,
  Vcl.ComCtrls, Vcl.Buttons, Vcl.ExtCtrls, Aefos.OTA.Terminal.Core.Snippets,
  Aefos.OTA.Terminal.UI.ThemedForm;

type
  TAefosTerminalSnippetsForm = class(TAefosTerminalThemedForm)
    pnlToolbar: TPanel;
    btnAdd: TSpeedButton;
    btnEdit: TSpeedButton;
    btnDelete: TSpeedButton;
    lstSnippets: TListView;
    procedure btnAddClick(Sender: TObject);
    procedure btnEditClick(Sender: TObject);
    procedure btnDeleteClick(Sender: TObject);
    procedure lstSnippetsDblClick(Sender: TObject);
  private
    FDockForm: TCustomForm;
    procedure _RefreshSnippets;
  public
    constructor Create(AOwner: TComponent; ADockForm: TCustomForm); reintroduce;
  end;

implementation

uses
  Aefos.OTA.Terminal.UI.DockForm, Aefos.OTA.Terminal.UI.SnippetEditDialog, Aefos.OTA.Terminal.Core.SnippetEditModel;

{$R *.dfm}

function _ScopeName(const AScope: TSnippetScope): string;
begin
  case AScope of
    ssProject: Result := 'Project';
    ssTeam:    Result := 'Team';
  else
    Result := 'Personal';
  end;
end;

{ TAefosTerminalSnippetsForm }

constructor TAefosTerminalSnippetsForm.Create(AOwner: TComponent; ADockForm: TCustomForm);
begin
  // Theme is applied by the TAefosTerminalThemedForm base constructor
  // (ESP-077) after DFM streaming — same timing as the former manual call.
  inherited Create(AOwner);
  FDockForm := ADockForm;

  // Bind icons dynamically from DockForm resources
  if Assigned(FDockForm) and (FDockForm is TAefosTerminalDockForm) then
  begin
    TAefosTerminalDockForm(FDockForm)._CreateButtonGlyph(btnAdd, 'plus');
    TAefosTerminalDockForm(FDockForm)._CreateButtonGlyph(btnEdit, 'pencil');
    TAefosTerminalDockForm(FDockForm)._CreateButtonGlyph(btnDelete, 'trash');
  end;

  _RefreshSnippets;

  DoubleBuffered := True;
end;

procedure TAefosTerminalSnippetsForm._RefreshSnippets;
var
  LItem: TListItem;
  LDock: TAefosTerminalDockForm;
  LSnippet: TSnippet;
begin
  if not (Assigned(FDockForm) and (FDockForm is TAefosTerminalDockForm)) then
    Exit;

  LDock := TAefosTerminalDockForm(FDockForm);
  lstSnippets.Items.BeginUpdate;
  try
    lstSnippets.Items.Clear;
    for LSnippet in LDock.SnippetManager.Snippets do
    begin
      LItem := lstSnippets.Items.Add;
      LItem.Caption := LSnippet.Title;
      LItem.SubItems.Add(LSnippet.Command);
      LItem.SubItems.Add(_ScopeName(LSnippet.Scope));
      LItem.SubItems.Add(TSnippetEditModel.FormatTags(LSnippet.Tags));
      LItem.Data := LSnippet;
    end;
  finally
    lstSnippets.Items.EndUpdate;
  end;
end;

procedure TAefosTerminalSnippetsForm.btnAddClick(Sender: TObject);
var
  LTitle, LCommand: string;
  LScope: TSnippetScope;
  LTags: TArray<string>;
  LDock: TAefosTerminalDockForm;
  LContext: TDictionary<string, string>;
begin
  if not (Assigned(FDockForm) and (FDockForm is TAefosTerminalDockForm)) then
    Exit;

  try
    LDock := TAefosTerminalDockForm(FDockForm);
    LTitle := '';
    LCommand := '';
    LScope := ssPersonal;
    LTags := [];
    LContext := LDock._BuildSnippetVarContext;
    try
      if TSnippetEditDialog.Execute(LTitle, LCommand, LScope, LTags,
        LDock.SnippetManager.ProjectPath <> '',
        LDock.SnippetManager.TeamPath <> '', LContext) then
      begin
        LDock.SnippetManager.Snippets.Add(
          TSnippet.Create(LTitle, LCommand, LScope, LTags));
        LDock.SnippetManager.SaveToJson;
        _RefreshSnippets;
      end;
    finally
      LContext.Free;
    end;
  except
    on E: Exception do
      MessageDlg('Error adding snippet: ' + E.Message, mtError, [mbOK], 0);
  end;
end;

procedure TAefosTerminalSnippetsForm.btnEditClick(Sender: TObject);
var
  LSnippet: TSnippet;
  LTitle, LCommand: string;
  LScope: TSnippetScope;
  LTags: TArray<string>;
  LDock: TAefosTerminalDockForm;
  LContext: TDictionary<string, string>;
begin
  if not (Assigned(FDockForm) and (FDockForm is TAefosTerminalDockForm)) then
    Exit;

  try
    LDock := TAefosTerminalDockForm(FDockForm);
    if Assigned(lstSnippets.Selected) then
    begin
      LSnippet := TSnippet(lstSnippets.Selected.Data);
      if Assigned(LSnippet) then
      begin
        LTitle := LSnippet.Title;
        LCommand := LSnippet.Command;
        LScope := LSnippet.Scope;
        LTags := LSnippet.Tags;
        LContext := LDock._BuildSnippetVarContext;
        try
          if TSnippetEditDialog.Execute(LTitle, LCommand, LScope, LTags,
            LDock.SnippetManager.ProjectPath <> '',
            LDock.SnippetManager.TeamPath <> '', LContext) then
          begin
            LSnippet.Title := LTitle;
            LSnippet.Command := LCommand;
            LSnippet.Scope := LScope;
            LSnippet.Tags := LTags;
            LDock.SnippetManager.SaveToJson;
            _RefreshSnippets;
          end;
        finally
          LContext.Free;
        end;
      end;
    end;
  except
    on E: Exception do
      MessageDlg('Error editing snippet: ' + E.Message, mtError, [mbOK], 0);
  end;
end;

procedure TAefosTerminalSnippetsForm.btnDeleteClick(Sender: TObject);
var
  LDock: TAefosTerminalDockForm;
begin
  if not (Assigned(FDockForm) and (FDockForm is TAefosTerminalDockForm)) then
    Exit;

  try
    LDock := TAefosTerminalDockForm(FDockForm);
    if Assigned(lstSnippets.Selected) then
    begin
      if MessageDlg('Do you want to delete this snippet?', mtConfirmation, [mbYes, mbNo], 0) = mrYes then
      begin
        LDock.SnippetManager.Snippets.Delete(lstSnippets.Selected.Index);
        LDock.SnippetManager.SaveToJson;
        _RefreshSnippets;
      end;
    end;
  except
    on E: Exception do
      MessageDlg('Error deleting snippet: ' + E.Message, mtError, [mbOK], 0);
  end;
end;

procedure TAefosTerminalSnippetsForm.lstSnippetsDblClick(Sender: TObject);
begin
  btnEditClick(Sender);
end;

end.



