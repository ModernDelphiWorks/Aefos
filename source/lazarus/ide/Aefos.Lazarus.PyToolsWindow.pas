unit Aefos.Lazarus.PyToolsWindow;

{ Aefos AI - Lazarus edition: "Python Tools" manager window.

  The LCL twin of the RAD Studio plugin's PyTools manager dialog
  (source\mcp\OTA\Aefos.OTA.MCP.PyToolsManager.pas). Same purpose, same fields,
  same on-disk store (Aefos.Lazarus.PyToolsStore -> %APPDATA%\Aefos\pytools) - so
  a tool created here is picked up verbatim by the Delphi MCP host running on the
  same Windows profile.

  It is a plain management dialog: a list of tools on the left, an editor on the
  right (Name / Timeout / Description / inputSchema / main.py) and New / Delete /
  Save / Close. Like the Delphi dialog it is built entirely in code (no .lfm) and
  never touches the IDE editor or designer - it only edits files, so RULE #1 and
  the IDE-unload teardown ritual do not apply (create-on-demand modal, freed on
  close; it holds no IDE-level reference past its own lifetime).

  There is NO premium/dark theming here (that helper is VCL/OTA only); the window
  uses the native LCL look, consistent with the other Lazarus port windows.

  Mode delphi: string = UTF-8 AnsiString, conversion-free with the LCL controls
  and the store. All literals are ASCII, so the file needs no BOM. }

{$mode delphi}
{$H+}

interface

type
  { Opens the modal PyTools manager. A sealed static namespace so no loose
    routine is exported (house style); the menu handler calls ShowManager. }
  TAefosLazPyTools = class
  public
    class procedure ShowManager; static;
  end;

implementation

uses
  SysUtils,
  Classes,
  Forms,
  Controls,
  StdCtrls,
  Dialogs,
  Aefos.Lazarus.PyToolsStore;

type
  { The manager form. Built in code (CreateNew, no resource), exactly like the
    Delphi TPyToolsForm. }
  TAefosLazPyToolsForm = class(TForm)
  private
    FList: TListBox;
    FBtnNew, FBtnDelete, FBtnSave, FBtnClose: TButton;
    FEdtName, FEdtDesc, FEdtTimeout: TEdit;
    FMemoSchema, FMemoCode: TMemo;
    FLblHint: TLabel;
    procedure _BuildUI;
    procedure _RefreshList;
    procedure _LoadSelected(ASender: TObject);
    procedure _ClearEditor(const ANewDefaults: Boolean);
    procedure _NewClick(ASender: TObject);
    procedure _SaveClick(ASender: TObject);
    procedure _DeleteClick(ASender: TObject);
  public
    constructor CreateManager;
  end;

{ TAefosLazPyToolsForm }

constructor TAefosLazPyToolsForm.CreateManager;
begin
  inherited CreateNew(nil);
  Caption := 'Aefos PyTools';
  BorderStyle := bsDialog;
  Position := poScreenCenter;
  ClientWidth := 760;
  ClientHeight := 560;
  _BuildUI;
  _RefreshList;
  _ClearEditor(True);
end;

procedure TAefosLazPyToolsForm._BuildUI;

  function _Lbl(const ACaption: string; ALeft, ATop, AWidth: Integer): TLabel;
  begin
    Result := TLabel.Create(Self);
    Result.Parent := Self;
    Result.SetBounds(ALeft, ATop, AWidth, 15);
    Result.Caption := ACaption;
  end;

begin
  _Lbl('Python tools (used by Chat and Terminal):', 12, 10, 400);

  // Left: list + New/Delete.
  FList := TListBox.Create(Self);
  FList.Parent := Self;
  FList.SetBounds(12, 32, 200, 430);
  FList.OnClick := _LoadSelected;

  FBtnNew := TButton.Create(Self);
  FBtnNew.Parent := Self;
  FBtnNew.SetBounds(12, 474, 94, 30);
  FBtnNew.Caption := 'New tool';
  FBtnNew.OnClick := _NewClick;

  FBtnDelete := TButton.Create(Self);
  FBtnDelete.Parent := Self;
  FBtnDelete.SetBounds(112, 474, 94, 30);
  FBtnDelete.Caption := 'Delete';
  FBtnDelete.OnClick := _DeleteClick;

  // Right: editor.
  _Lbl('Name (identifier)', 228, 32, 200);
  FEdtName := TEdit.Create(Self);
  FEdtName.Parent := Self;
  FEdtName.SetBounds(228, 50, 300, 23);

  _Lbl('Timeout (ms)', 540, 32, 120);
  FEdtTimeout := TEdit.Create(Self);
  FEdtTimeout.Parent := Self;
  FEdtTimeout.SetBounds(540, 50, 100, 23);

  _Lbl('Description', 228, 82, 300);
  FEdtDesc := TEdit.Create(Self);
  FEdtDesc.Parent := Self;
  FEdtDesc.SetBounds(228, 100, 512, 23);

  _Lbl('inputSchema (JSON)', 228, 132, 300);
  FMemoSchema := TMemo.Create(Self);
  FMemoSchema.Parent := Self;
  FMemoSchema.SetBounds(228, 150, 512, 120);
  FMemoSchema.ScrollBars := ssVertical;

  _Lbl('main.py', 228, 280, 300);
  FMemoCode := TMemo.Create(Self);
  FMemoCode.Parent := Self;
  FMemoCode.SetBounds(228, 298, 512, 164);
  FMemoCode.ScrollBars := ssVertical;
  FMemoCode.WordWrap := False;

  FBtnSave := TButton.Create(Self);
  FBtnSave.Parent := Self;
  FBtnSave.SetBounds(548, 474, 94, 30);
  FBtnSave.Caption := 'Save';
  FBtnSave.Default := True;
  FBtnSave.OnClick := _SaveClick;

  FBtnClose := TButton.Create(Self);
  FBtnClose.Parent := Self;
  FBtnClose.SetBounds(648, 474, 94, 30);
  FBtnClose.Caption := 'Close';
  FBtnClose.Cancel := True;
  FBtnClose.ModalResult := mrCancel;

  // Hint on its own full-width line below the buttons.
  FLblHint := _Lbl(
    'Saved to %APPDATA%\Aefos\pytools - reconnect the MCP session to load a new tool.',
    12, 514, 730);
end;

procedure TAefosLazPyToolsForm._RefreshList;
var
  LNames: TAefosPyToolNames;
  LIndex: Integer;
begin
  FList.Items.BeginUpdate;
  try
    FList.Items.Clear;
    LNames := TAefosLazPyToolsStore.ListTools(TAefosLazPyToolsStore.DefaultRoot);
    for LIndex := 0 to High(LNames) do
      FList.Items.Add(LNames[LIndex]);
  finally
    FList.Items.EndUpdate;
  end;
end;

procedure TAefosLazPyToolsForm._ClearEditor(const ANewDefaults: Boolean);
begin
  FEdtName.Text := '';
  FEdtDesc.Text := '';
  if ANewDefaults then
  begin
    FEdtTimeout.Text := IntToStr(TAefosLazPyToolsStore.DefaultTimeoutMs);
    FMemoSchema.Lines.Text := TAefosLazPyToolsStore.SchemaTemplate;
    FMemoCode.Lines.Text := TAefosLazPyToolsStore.MainPyTemplate;
  end
  else
  begin
    FEdtTimeout.Text := '';
    FMemoSchema.Lines.Text := '';
    FMemoCode.Lines.Text := '';
  end;
end;

procedure TAefosLazPyToolsForm._LoadSelected(ASender: TObject);
var
  LSpec: TAefosPyToolSpec;
begin
  if FList.ItemIndex < 0 then
    Exit;
  if not TAefosLazPyToolsStore.Load(TAefosLazPyToolsStore.DefaultRoot,
       FList.Items[FList.ItemIndex], LSpec) then
    Exit;
  FEdtName.Text := LSpec.Name;
  FEdtDesc.Text := LSpec.Description;
  FEdtTimeout.Text := IntToStr(LSpec.TimeoutMs);
  FMemoSchema.Lines.Text := LSpec.SchemaJson;
  FMemoCode.Lines.Text := LSpec.Code;
end;

procedure TAefosLazPyToolsForm._NewClick(ASender: TObject);
begin
  FList.ItemIndex := -1;
  _ClearEditor(True);
  FEdtName.SetFocus;
end;

procedure TAefosLazPyToolsForm._SaveClick(ASender: TObject);
var
  LSpec: TAefosPyToolSpec;
  LError: string;
begin
  LSpec.Name := Trim(FEdtName.Text);
  LSpec.Description := FEdtDesc.Text;
  LSpec.TimeoutMs := StrToIntDef(Trim(FEdtTimeout.Text),
    TAefosLazPyToolsStore.DefaultTimeoutMs);
  LSpec.SchemaJson := FMemoSchema.Lines.Text;
  LSpec.Code := FMemoCode.Lines.Text;

  if not TAefosLazPyToolsStore.Save(TAefosLazPyToolsStore.DefaultRoot, LSpec,
       LError) then
  begin
    ShowMessage(LError);
    Exit;
  end;
  _RefreshList;
  FList.ItemIndex := FList.Items.IndexOf(LSpec.Name);
  ShowMessage('Saved "' + LSpec.Name
    + '". Reconnect the MCP session to load it.');
end;

procedure TAefosLazPyToolsForm._DeleteClick(ASender: TObject);
var
  LName, LError: string;
begin
  if FList.ItemIndex < 0 then
  begin
    ShowMessage('Select a tool to delete.');
    Exit;
  end;
  LName := FList.Items[FList.ItemIndex];
  if MessageDlg('Aefos PyTools',
       'Delete the Python tool "' + LName + '"? This removes its folder.',
       mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
    Exit;
  if not TAefosLazPyToolsStore.Delete(TAefosLazPyToolsStore.DefaultRoot, LName,
       LError) then
  begin
    ShowMessage(LError);
    Exit;
  end;
  _RefreshList;
  _ClearEditor(False);
end;

{ TAefosLazPyTools }

class procedure TAefosLazPyTools.ShowManager;
var
  LForm: TAefosLazPyToolsForm;
begin
  LForm := TAefosLazPyToolsForm.CreateManager;
  try
    LForm.ShowModal;
  finally
    LForm.Free;
  end;
end;

end.
