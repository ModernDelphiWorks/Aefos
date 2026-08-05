unit Aefos.Lazarus.ActionCenterWindow;

{ TAefosLazActionCenterWindow -- the LCL "Aefos AI - Action Center" window
  (Lazarus edition), the twin of the Delphi
  source\terminal\UI\Aefos.OTA.Terminal.UI.ActionCenterView.pas.

  A floating (non-modal) form hosting a searchable, category-grouped catalog of
  saved terminal actions with Run / New / Edit / Delete. Double-click or Run
  injects the selected action's script lines into the active terminal via the
  shared Core runner (Aefos.OTA.Terminal.Core.ActionRunner) against the terminal
  control's ITerminalInput. The catalog is loaded from / saved to the SAME
  actions.json the RAD Studio plugin uses (Aefos.OTA.Terminal.Core.ActionStore,
  %APPDATA%\ModernDelphiWorks\Aefos.OTA.Terminal\actions.json) -- one brain across
  the two editions.

  MVP scope (this slice): search, tree, Run/New/Edit/Delete, the New/Edit dialog
  (Name/Category/Description/Script/WorkingDir), first-run seeded samples,
  persistence, and the ConfirmBeforeRun gate. DEFERRED (flagged): Import/Export
  buttons, the placeholder-prompt dialog (run passes a nil resolver, so a
  placeholder-bearing action reports "needs a resolver"), and shortcut binding.

  Dark chrome to match the terminal: TSpeedButton (flat) for the toolbar buttons
  because a Windows-themed TButton/TCheckBox ignores Color/Font.Color and would
  render light on the dark panel (the find-bar lesson).

  Built entirely in code (no .lfm): a single reusable instance whose lifetime is
  the IDE's; freed at finalization (IDE-unload discipline). }

{$mode delphi}
{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ComCtrls,
  Aefos.OTA.Terminal.Core.Actions,
  Aefos.OTA.Terminal.Core.ActionStore,
  Aefos.OTA.Terminal.Core.ActionRunner;

type
  { The Action Center window. Owns its store, catalog and runner. }
  TAefosLazActionCenterWindow = class(TForm)
  private
    FStore: TActionStore;
    FCatalog: TActionCatalog;
    FRunner: TActionRunner;
    FSearch: TEdit;
    FTree: TTreeView;
    procedure _BuildUI;
    procedure _RefreshTree;
    function _MatchesFilter(const AAction: TTerminalAction): Boolean;
    function _SelectedAction: TTerminalAction;
    function _CloneAction(const ASource: TTerminalAction): TTerminalAction;
    { ConfirmBeforeRun gate (of-object twin of the Delphi _ConfirmRun). }
    function _ConfirmRun(const AAction: TTerminalAction): Boolean;
    procedure _Persist;
    procedure _SearchChange(ASender: TObject);
    procedure _RunClick(ASender: TObject);
    procedure _NewClick(ASender: TObject);
    procedure _EditClick(ASender: TObject);
    procedure _DeleteClick(ASender: TObject);
    procedure _TreeDblClick(ASender: TObject);
  public
    constructor CreateNew(AOwner: TComponent; Num: Integer = 0); override;
    destructor Destroy; override;
    { Reloads the catalog from actions.json and rebuilds the tree. Called on
      every Show so an edit made in the other edition (or the Delphi terminal)
      appears without restarting the IDE (one-brain freshness). }
    procedure RefreshFromStore;
  end;

  { Opens/shows the single Action Center window (create-on-demand). All entry
    points are class methods so no loose product routines are exported. }
  TAefosLazActionCenter = class
  public
    class procedure Show;
  end;

implementation

uses
  ExtCtrls, Buttons, Graphics, Dialogs, LCLType, LazUTF8,
  Aefos.Lazarus.TerminalWindow;

const
  { Native (light) system palette: the Action Center is a utility window and reads
    best in the IDE's own theme, NOT the immersive dark chrome of the chat/terminal
    surfaces (owner call). Using system colours also sidesteps the themed-control
    text-colour fights (checkbox / treeview) that dark-on-dark caused. }
  cColorBg      = clWindow;      // form / tree background
  cColorPanel   = clBtnFace;     // toolbar
  cColorField   = clWindow;      // edit fields
  cColorBtnFace = clBtnFace;     // button face
  cColorText    = clWindowText;  // text

type
  { Modal editor for one TTerminalAction, built in code (no .lfm). Shortcut and
    placeholder editing are deferred; the remaining fields mirror the Delphi
    TActionEditDialog. }
  TAefosLazActionEditDialog = class(TForm)
  private
    FName: TEdit;
    FCategory: TEdit;
    FDescription: TEdit;
    FWorkingDir: TEdit;
    FScript: TMemo;
    function _AddLabel(const ACaption: string; ATop: Integer): TLabel;
    function _AddEdit(ATop: Integer): TEdit;
    procedure _BuildFields;
    procedure _BuildButtons;
    procedure _LoadFrom(const AAction: TTerminalAction);
    procedure _StoreTo(const AAction: TTerminalAction);
  public
    constructor CreateNew(AOwner: TComponent; Num: Integer = 0); override;
    class function Execute(const AAction: TTerminalAction): Boolean;
  end;

var
  { The single Action Center window; created on first Show, freed at finalization. }
  GActionCenterWindow: TAefosLazActionCenterWindow = nil;

{ TAefosLazActionEditDialog }

constructor TAefosLazActionEditDialog.CreateNew(AOwner: TComponent; Num: Integer);
begin
  inherited CreateNew(AOwner, Num);
  Caption := 'Edit Action';
  BorderStyle := bsDialog;
  Position := poScreenCenter;
  ClientWidth := 420;
  ClientHeight := 330;
  Color := cColorBg;
  Font.Color := cColorText;
  _BuildFields;
  _BuildButtons;
end;

function TAefosLazActionEditDialog._AddLabel(const ACaption: string;
  ATop: Integer): TLabel;
begin
  Result := TLabel.Create(Self);
  Result.Parent := Self;
  Result.SetBounds(12, ATop + 3, 84, 17);
  Result.Caption := ACaption;
  Result.Font.Color := cColorText;
  Result.Transparent := True;
end;

function TAefosLazActionEditDialog._AddEdit(ATop: Integer): TEdit;
begin
  Result := TEdit.Create(Self);
  Result.Parent := Self;
  Result.SetBounds(104, ATop, 304, 24);
  Result.Color := cColorField;
  Result.Font.Color := cColorText;
end;

procedure TAefosLazActionEditDialog._BuildFields;
begin
  _AddLabel('Name', 12);
  FName := _AddEdit(12);
  _AddLabel('Category', 44);
  FCategory := _AddEdit(44);
  _AddLabel('Description', 76);
  FDescription := _AddEdit(76);
  _AddLabel('Working dir', 108);
  FWorkingDir := _AddEdit(108);
  _AddLabel('Script', 140);

  FScript := TMemo.Create(Self);
  FScript.Parent := Self;
  FScript.SetBounds(104, 140, 304, 130);
  FScript.ScrollBars := ssVertical;
  FScript.Color := cColorField;
  FScript.Font.Color := cColorText;
  FScript.WordWrap := False;
end;

procedure TAefosLazActionEditDialog._BuildButtons;
var
  LOk, LCancel: TButton;
begin
  LOk := TButton.Create(Self);
  LOk.Parent := Self;
  LOk.SetBounds(244, 288, 80, 28);
  LOk.Caption := 'OK';
  LOk.Default := True;
  LOk.ModalResult := mrOk;

  LCancel := TButton.Create(Self);
  LCancel.Parent := Self;
  LCancel.SetBounds(330, 288, 80, 28);
  LCancel.Caption := 'Cancel';
  LCancel.Cancel := True;
  LCancel.ModalResult := mrCancel;
end;

procedure TAefosLazActionEditDialog._LoadFrom(const AAction: TTerminalAction);
var
  LLine: string;
begin
  FName.Text := AAction.Name;
  FCategory.Text := AAction.Category;
  FDescription.Text := AAction.Description;
  FWorkingDir.Text := AAction.WorkingDir;
  FScript.Lines.Clear;
  for LLine in AAction.ScriptLines do
    FScript.Lines.Add(LLine);
end;

procedure TAefosLazActionEditDialog._StoreTo(const AAction: TTerminalAction);
begin
  AAction.Name := Trim(FName.Text);
  AAction.Category := Trim(FCategory.Text);
  AAction.Description := FDescription.Text;
  AAction.WorkingDir := Trim(FWorkingDir.Text);
  // TStrings.ToStringArray yields the AnsiString lines, one per script command.
  AAction.ScriptLines := FScript.Lines.ToStringArray;
end;

class function TAefosLazActionEditDialog.Execute(
  const AAction: TTerminalAction): Boolean;
var
  LDialog: TAefosLazActionEditDialog;
begin
  LDialog := TAefosLazActionEditDialog.CreateNew(nil);
  try
    LDialog._LoadFrom(AAction);
    Result := LDialog.ShowModal = mrOk;
    if Result then
      LDialog._StoreTo(AAction);
  finally
    LDialog.Free;
  end;
end;

{ TAefosLazActionCenterWindow }

constructor TAefosLazActionCenterWindow.CreateNew(AOwner: TComponent;
  Num: Integer);
begin
  inherited CreateNew(AOwner, Num);
  Caption := 'Aefos AI - Action Center';
  Width := 480;
  Height := 440;
  Position := poScreenCenter;
  Color := cColorBg;
  Constraints.MinWidth := 380;
  Constraints.MinHeight := 300;

  FStore := TActionStore.Create;
  FRunner := TActionRunner.Create;
  FCatalog := FStore.LoadCatalog;   // first run seeds + persists sample actions

  _BuildUI;
  _RefreshTree;
end;

destructor TAefosLazActionCenterWindow.Destroy;
begin
  FRunner.Free;
  FCatalog.Free;
  FStore.Free;
  if GActionCenterWindow = Self then
    GActionCenterWindow := nil;
  inherited Destroy;
end;

procedure TAefosLazActionCenterWindow._BuildUI;
var
  LToolbar: TPanel;
  LRight, LBtnW, LBtnGap: Integer;

  function _NavButton(const ACaption: string; ALeft: Integer;
    AOnClick: TNotifyEvent): TSpeedButton;
  begin
    Result := TSpeedButton.Create(Self);
    Result.Parent := LToolbar;
    Result.SetBounds(ALeft, 6, 62, 26);
    Result.Flat := True;
    Result.Caption := ACaption;
    Result.Color := cColorBtnFace;
    Result.Font.Color := cColorText;
    Result.Anchors := [akTop, akRight];
    Result.OnClick := AOnClick;
  end;

begin
  LToolbar := TPanel.Create(Self);
  LToolbar.Parent := Self;
  LToolbar.Align := alTop;
  LToolbar.Height := 40;
  LToolbar.BevelOuter := bvNone;
  LToolbar.Color := cColorPanel;
  // Force the toolbar to the client width NOW: an alTop panel has not stretched to
  // the parent width yet at build time, so an akRight child would compute its
  // offset against the panel's default width and get flung off-screen once the
  // form realises. Setting the width up front makes the akRight offsets correct
  // (and alTop keeps it at the client width on every later resize).
  LToolbar.Width := ClientWidth;

  FSearch := TEdit.Create(Self);
  FSearch.Parent := LToolbar;
  FSearch.SetBounds(8, 8, 180, 24);
  FSearch.Color := cColorField;
  FSearch.Font.Color := cColorText;
  FSearch.TextHint := 'Search actions...';
  FSearch.Anchors := [akLeft, akTop];
  FSearch.OnChange := _SearchChange;

  // Right-anchored nav buttons: Run / New / Edit / Delete (Import/Export
  // deferred). Left positions are computed from the real client width so they sit
  // just inside the right edge; the akRight anchor keeps them pinned on resize.
  LBtnW := 62;
  LBtnGap := 4;
  LRight := ClientWidth - 8;
  _NavButton('Delete', LRight - LBtnW, _DeleteClick);
  _NavButton('Edit', LRight - 2 * LBtnW - LBtnGap, _EditClick);
  _NavButton('New', LRight - 3 * LBtnW - 2 * LBtnGap, _NewClick);
  _NavButton('Run', LRight - 4 * LBtnW - 3 * LBtnGap, _RunClick);

  FTree := TTreeView.Create(Self);
  FTree.Parent := Self;
  FTree.Align := alClient;
  FTree.ReadOnly := True;
  FTree.BorderStyle := bsNone;
  FTree.OnDblClick := _TreeDblClick;
end;

procedure TAefosLazActionCenterWindow.RefreshFromStore;
begin
  FreeAndNil(FCatalog);
  FCatalog := FStore.LoadCatalog;
  _RefreshTree;
end;

function TAefosLazActionCenterWindow._MatchesFilter(
  const AAction: TTerminalAction): Boolean;
var
  LFilter: string;
begin
  LFilter := UTF8LowerCase(Trim(FSearch.Text));
  if LFilter = '' then
    Exit(True);
  Result := (Pos(LFilter, UTF8LowerCase(AAction.Name)) > 0)
         or (Pos(LFilter, UTF8LowerCase(AAction.EffectiveCategory)) > 0)
         or (Pos(LFilter, UTF8LowerCase(AAction.Description)) > 0);
end;

procedure TAefosLazActionCenterWindow._RefreshTree;
var
  LCategory: string;
  LAction: TTerminalAction;
  LCategoryNode: TTreeNode;
  LActionNode: TTreeNode;
begin
  FTree.Items.BeginUpdate;
  try
    FTree.Items.Clear;
    for LCategory in FCatalog.Categories do
    begin
      LCategoryNode := nil;
      for LAction in FCatalog.ActionsInCategory(LCategory) do
      begin
        if not _MatchesFilter(LAction) then
          Continue;
        if LCategoryNode = nil then
          LCategoryNode := FTree.Items.Add(nil, LCategory);
        LActionNode := FTree.Items.AddChild(LCategoryNode, LAction.Name);
        LActionNode.Data := LAction;   // raw pointer into the owning catalog
      end;
      if LCategoryNode <> nil then
        LCategoryNode.Expand(True);
    end;
  finally
    FTree.Items.EndUpdate;
  end;
end;

function TAefosLazActionCenterWindow._SelectedAction: TTerminalAction;
begin
  Result := nil;
  if (FTree.Selected <> nil) and (FTree.Selected.Data <> nil) then
    Result := TTerminalAction(FTree.Selected.Data);
end;

function TAefosLazActionCenterWindow._CloneAction(
  const ASource: TTerminalAction): TTerminalAction;
begin
  Result := TTerminalAction.Create;
  Result.Id := ASource.Id;
  Result.Name := ASource.Name;
  Result.Category := ASource.Category;
  Result.Description := ASource.Description;
  Result.ScriptLines := Copy(ASource.ScriptLines);
  Result.ProfileName := ASource.ProfileName;
  Result.WorkingDir := ASource.WorkingDir;
  Result.ConfirmBeforeRun := ASource.ConfirmBeforeRun;
  Result.Shortcut := ASource.Shortcut;
end;

function TAefosLazActionCenterWindow._ConfirmRun(
  const AAction: TTerminalAction): Boolean;
begin
  Result := MessageDlg('Aefos AI',
    Format('Run action "%s"?', [AAction.Name]),
    mtConfirmation, [mbYes, mbNo], 0) = mrYes;
end;

procedure TAefosLazActionCenterWindow._Persist;
begin
  FStore.SaveCatalog(FCatalog);
end;

procedure TAefosLazActionCenterWindow._SearchChange(ASender: TObject);
begin
  _RefreshTree;
end;

procedure TAefosLazActionCenterWindow._RunClick(ASender: TObject);
var
  LAction: TTerminalAction;
  LInput: ITerminalInput;
  LResult: TActionRunResult;
begin
  LAction := _SelectedAction;
  if LAction = nil then
    Exit;
  LInput := TAefosLazTerminalDock.ActiveTerminalInput;
  if (LInput = nil) or not LInput.IsActive then
  begin
    MessageDlg('Aefos AI',
      'No active terminal. Open View > Aefos AI (Terminal) > Open Terminal, '
      + 'then run the action.', mtWarning, [mbOK], 0);
    Exit;
  end;
  // Placeholder resolver deferred (nil): a ${...}-bearing action reports
  // aroCancelled with "needs a resolver"; the seeded samples have none.
  LResult := FRunner.RunAction(LAction, LInput, _ConfirmRun);
  if not LResult.IsSuccess and (LResult.Outcome <> aroCancelled) then
    MessageDlg('Aefos AI', LResult.Message, mtWarning, [mbOK], 0);
end;

procedure TAefosLazActionCenterWindow._NewClick(ASender: TObject);
var
  LAction: TTerminalAction;
begin
  LAction := TTerminalAction.Create;
  if not TAefosLazActionEditDialog.Execute(LAction) then
  begin
    LAction.Free;
    Exit;
  end;
  // FCatalog.Add takes ownership unconditionally (it frees LAction on rejection),
  // so LAction must not be freed again here.
  if FCatalog.Add(LAction) then
  begin
    _Persist;
    _RefreshTree;
  end
  else
    MessageDlg('Aefos AI',
      'The action could not be added. Check for an empty name/script or a '
      + 'duplicate name in the same category.', mtWarning, [mbOK], 0);
end;

procedure TAefosLazActionCenterWindow._EditClick(ASender: TObject);
var
  LSelected: TTerminalAction;
  LDraft: TTerminalAction;
begin
  LSelected := _SelectedAction;
  if LSelected = nil then
    Exit;
  LDraft := _CloneAction(LSelected);
  if not TAefosLazActionEditDialog.Execute(LDraft) then
  begin
    LDraft.Free;
    Exit;
  end;
  // FCatalog.Update takes ownership unconditionally (frees LDraft on rejection).
  if FCatalog.Update(LDraft) then
  begin
    _Persist;
    _RefreshTree;
  end
  else
    MessageDlg('Aefos AI',
      'The action could not be updated. Check for an empty name/script or a '
      + 'duplicate name in the same category.', mtWarning, [mbOK], 0);
end;

procedure TAefosLazActionCenterWindow._DeleteClick(ASender: TObject);
var
  LAction: TTerminalAction;
begin
  LAction := _SelectedAction;
  if LAction = nil then
    Exit;
  if MessageDlg('Aefos AI', Format('Delete action "%s"?', [LAction.Name]),
    mtConfirmation, [mbYes, mbNo], 0) = mrYes then
  begin
    FCatalog.Remove(LAction.Id);
    _Persist;
    _RefreshTree;
  end;
end;

procedure TAefosLazActionCenterWindow._TreeDblClick(ASender: TObject);
begin
  _RunClick(ASender);
end;

{ TAefosLazActionCenter }

class procedure TAefosLazActionCenter.Show;
begin
  if GActionCenterWindow = nil then
    GActionCenterWindow := TAefosLazActionCenterWindow.CreateNew(Application);
  // Re-read actions.json so an edit made elsewhere (the other edition / the
  // Delphi terminal) shows on every open (one-brain freshness).
  GActionCenterWindow.RefreshFromStore;
  GActionCenterWindow.Show;
  GActionCenterWindow.BringToFront;
end;

finalization
  // Statically linked package: runs at IDE shutdown. Close + free the single
  // window (guarded so shutdown never raises).
  if GActionCenterWindow <> nil then
  begin
    try
      GActionCenterWindow.Close;
    except
    end;
    FreeAndNil(GActionCenterWindow);
  end;

end.
