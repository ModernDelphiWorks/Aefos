unit Aefos.OTA.MCP.PyToolsManager;

{
  "Aefos PyTools" — a small manager dialog for the Python tools the agent can use.

  PyTools are a drop-a-folder extension point: each tool is a folder under
  %APPDATA%\Aefos\pytools\<name> with a `tool.json` (manifest) and a `main.py`
  (JSON stdin -> JSON stdout). Both hosts register them on their MCP server, so a
  tool serves BOTH Chat and Terminal — which is exactly why this manager lives in
  the shared MCP.Tools.OTA BPL (like the AI Flow page) and is opened from a menu
  item in each host, NOT a chat-only command.

  This dialog just creates/edits/deletes those files; it never touches the IDE.
  Newly added tools load on the next MCP session (registration happens at server
  start), so the dialog says so. VCL + themed via ApplyPremiumTheme; no .dfm
  (built in code, like the issue dialog). Not Pro-gated — it only edits files.
}

interface

// Shows the modal PyTools manager. Safe to call from either host's menu.
procedure ShowPyToolsManager;

// Refcounted registration of the SINGLE top-level "Aefos PyTools" item under the
// IDE View menu (sibling to "Aefos AI (Chat)" / "(Terminal)"). Both hosts call
// these on load/teardown; the item is created once and freed by the last host.
// Pro-only: hidden for Free.
procedure RegisterPyToolsMenu;
procedure UnregisterPyToolsMenu;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.StrUtils,   // StartsText - the stale-menu match is by prefix now
  System.Classes,
  System.IOUtils,
  Aefos.Compat.IO,
  System.JSON,
  Vcl.Forms,
  Vcl.Controls,
  Vcl.StdCtrls,
  Vcl.Dialogs,
  Vcl.Menus,
  ToolsAPI,
  Aefos.MCP.Provision,
  Aefos.OTA.UI.ThemeHelper,
  Aefos.Compat.JsonFormat;

const
  CEntryDefault = 'main.py';
  CTimeoutDefault = 10000;
  CMainPyTemplate =
    '"""Aefos Python tool. Contract: JSON in on stdin, JSON out on stdout."""' + sLineBreak +
    'import sys, json' + sLineBreak + sLineBreak +
    'try:' + sLineBreak +
    '    sys.stdin.reconfigure(encoding="utf-8")' + sLineBreak +
    '    sys.stdout.reconfigure(encoding="utf-8")' + sLineBreak +
    'except Exception:' + sLineBreak +
    '    pass' + sLineBreak + sLineBreak +
    'payload = json.load(sys.stdin)' + sLineBreak +
    'text = payload.get("text", "")' + sLineBreak +
    'json.dump({"result": text.upper()}, sys.stdout, ensure_ascii=False)' + sLineBreak;
  CSchemaTemplate =
    '{' + sLineBreak +
    '  "type": "object",' + sLineBreak +
    '  "properties": {' + sLineBreak +
    '    "text": { "type": "string", "description": "text to transform" }' + sLineBreak +
    '  },' + sLineBreak +
    '  "required": ["text"]' + sLineBreak +
    '}';

type
  TPyToolsForm = class(TForm)
  private
    FList: TListBox;
    FBtnNew, FBtnDelete, FBtnSave, FBtnClose: TButton;
    FEdtName, FEdtDesc, FEdtTimeout: TEdit;
    FMemoSchema, FMemoCode: TMemo;
    FLblHint: TLabel;
    function _Root: string;
    procedure _BuildUI;
    procedure _RefreshList;
    procedure _LoadSelected(Sender: TObject);
    procedure _ClearEditor(const ANewDefaults: Boolean);
    procedure _NewClick(Sender: TObject);
    procedure _SaveClick(Sender: TObject);
    procedure _DeleteClick(Sender: TObject);
  public
    constructor CreateManager;
  end;

function _IsValidToolName(const AName: string): Boolean;
var
  LCh: Char;
begin
  Result := AName <> '';
  for LCh in AName do
    if not (CharInSet(LCh, ['A'..'Z', 'a'..'z', '0'..'9', '_'])) then
      Exit(False);
end;

function _Str(const AObj: TJSONObject; const AName, ADefault: string): string;
var
  LVal: TJSONValue;
begin
  Result := ADefault;
  if AObj = nil then Exit;
  LVal := AObj.GetValue(AName);
  if LVal is TJSONString then
    Result := TJSONString(LVal).Value;
end;

{ TPyToolsForm }

constructor TPyToolsForm.CreateManager;
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
  TThemeHelper.ApplyPremiumTheme(Self);
end;

function TPyToolsForm._Root: string;
begin
  Result := TPath.Combine(TMCPProvision.AppDataDir, 'pytools');
end;

procedure TPyToolsForm._BuildUI;

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

  // Hint on its OWN full-width line below the buttons (no longer cramped between).
  FLblHint := _Lbl(
    'Saved to %APPDATA%\Aefos\pytools - reconnect the MCP session to load a new tool.',
    12, 514, 730);
end;

procedure TPyToolsForm._RefreshList;
var
  LDir, LRoot: string;
begin
  FList.Items.BeginUpdate;
  try
    FList.Items.Clear;
    LRoot := _Root;
    if TDirectory.Exists(LRoot) then
      for LDir in TDirectory.GetDirectories(LRoot) do
        if TFile.Exists(TPath.Combine(LDir, 'tool.json')) then
          FList.Items.Add(TPath.GetFileName(LDir));
  finally
    FList.Items.EndUpdate;
  end;
end;

procedure TPyToolsForm._ClearEditor(const ANewDefaults: Boolean);
begin
  FEdtName.Text := '';
  FEdtDesc.Text := '';
  if ANewDefaults then
  begin
    FEdtTimeout.Text := IntToStr(CTimeoutDefault);
    FMemoSchema.Text := CSchemaTemplate;
    FMemoCode.Text := CMainPyTemplate;
  end
  else
  begin
    FEdtTimeout.Text := '';
    FMemoSchema.Text := '';
    FMemoCode.Text := '';
  end;
end;

procedure TPyToolsForm._LoadSelected(Sender: TObject);
var
  LFolder, LDir, LManifest, LEntry, LCodePath: string;
  LJson: TJSONObject;
  LTimeout: TJSONValue;
  LSchema: TJSONValue;
begin
  if FList.ItemIndex < 0 then Exit;
  LFolder := FList.Items[FList.ItemIndex];
  LDir := TPath.Combine(_Root, LFolder);
  LManifest := TPath.Combine(LDir, 'tool.json');
  if not TFile.Exists(LManifest) then Exit;
  LJson := nil;
  try
    try
      LJson := TJSONObject.ParseJSONValue(
        TAefosText.ReadAllUtf8(LManifest)) as TJSONObject;
    except
      LJson := nil;
    end;
    if LJson = nil then Exit;
    FEdtName.Text := _Str(LJson, 'name', LFolder);
    FEdtDesc.Text := _Str(LJson, 'description', '');
    LTimeout := LJson.GetValue('timeoutMs');
    if LTimeout is TJSONNumber then
      FEdtTimeout.Text := IntToStr(TJSONNumber(LTimeout).AsInt)
    else
      FEdtTimeout.Text := IntToStr(CTimeoutDefault);
    LEntry := _Str(LJson, 'entry', CEntryDefault);
    LSchema := LJson.GetValue('inputSchema');
    if LSchema <> nil then
      FMemoSchema.Text := LSchema.Format(2)
    else
      FMemoSchema.Text := '';
    LCodePath := TPath.Combine(LDir, LEntry);
    if TFile.Exists(LCodePath) then
      FMemoCode.Text := TAefosText.ReadAllUtf8(LCodePath)
    else
      FMemoCode.Text := '';
  finally
    LJson.Free;
  end;
end;

procedure TPyToolsForm._NewClick(Sender: TObject);
begin
  FList.ItemIndex := -1;
  _ClearEditor(True);
  FEdtName.SetFocus;
end;

procedure TPyToolsForm._SaveClick(Sender: TObject);
var
  LName, LDir, LSchemaText: string;
  LSchema: TJSONValue;
  LManifest: TJSONObject;
  LTimeout: Integer;
begin
  LName := Trim(FEdtName.Text);
  if not _IsValidToolName(LName) then
  begin
    ShowMessage('Name must be a non-empty identifier (letters, digits, underscore).');
    Exit;
  end;
  // inputSchema must be valid JSON (it becomes the tool's schema).
  LSchemaText := Trim(FMemoSchema.Text);
  if LSchemaText = '' then
    LSchemaText := '{"type":"object"}';
  LSchema := TJSONObject.ParseJSONValue(LSchemaText);
  if LSchema = nil then
  begin
    ShowMessage('inputSchema is not valid JSON.');
    Exit;
  end;
  LTimeout := StrToIntDef(Trim(FEdtTimeout.Text), CTimeoutDefault);
  if LTimeout <= 0 then
    LTimeout := CTimeoutDefault;

  LDir := TPath.Combine(_Root, LName);
  try
    if not TDirectory.Exists(LDir) then
      TDirectory.CreateDirectory(LDir);
    LManifest := TJSONObject.Create;
    try
      LManifest.AddPair('name', LName);
      LManifest.AddPair('description', FEdtDesc.Text);
      LManifest.AddPair('inputSchema', LSchema); // owned by LManifest now
      LSchema := nil;
      LManifest.AddPair('entry', CEntryDefault);
      LManifest.AddPair('python', '');
      LManifest.AddPair('timeoutMs', TJSONNumber.Create(LTimeout));
      TFile.WriteAllText(TPath.Combine(LDir, 'tool.json'),
        LManifest.Format(2), TEncoding.UTF8);
    finally
      LManifest.Free;
    end;
    TFile.WriteAllText(TPath.Combine(LDir, CEntryDefault),
      FMemoCode.Text, TEncoding.UTF8);
  except
    on E: Exception do
    begin
      LSchema.Free;
      ShowMessage('Could not save the tool: ' + E.Message);
      Exit;
    end;
  end;
  _RefreshList;
  FList.ItemIndex := FList.Items.IndexOf(LName);
  ShowMessage('Saved "' + LName + '". Reconnect the MCP session to load it.');
end;

procedure TPyToolsForm._DeleteClick(Sender: TObject);
var
  LName, LDir: string;
begin
  if FList.ItemIndex < 0 then
  begin
    ShowMessage('Select a tool to delete.');
    Exit;
  end;
  LName := FList.Items[FList.ItemIndex];
  if MessageDlg('Delete the Python tool "' + LName + '"? This removes its folder.',
       mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
    Exit;
  LDir := TPath.Combine(_Root, LName);
  try
    if TDirectory.Exists(LDir) then
      TDirectory.Delete(LDir, True);
  except
    on E: Exception do
    begin
      ShowMessage('Could not delete: ' + E.Message);
      Exit;
    end;
  end;
  _RefreshList;
  _ClearEditor(False);
end;

procedure ShowPyToolsManager;
var
  LForm: TPyToolsForm;
begin
  LForm := TPyToolsForm.CreateManager;
  try
    LForm.ShowModal;
  finally
    LForm.Free;
  end;
end;

// ── Shared top-level "Aefos PyTools" menu item (refcounted) ──────────────────

type
  TPyToolsMenuClicker = class
    procedure Click(Sender: TObject);
  end;

const
  // The item's IDENTITY (what _RemoveStaleMenu matches on). The DISPLAYED text
  // can carry a '(Pro)' tag on top of this, so the match is by PREFIX -- tagging
  // the caption must not make a leftover item from a previous load invisible to
  // the cleanup.
  CMenuCaption = 'Aefos PyTools';
  CMenuProTag  = '   (Pro)';

var
  GMenuRefCount: Integer = 0;
  GMenuItem: TMenuItem = nil;
  GMenuClicker: TPyToolsMenuClicker = nil;

procedure TPyToolsMenuClicker.Click(Sender: TObject);
begin
  try
    ShowPyToolsManager;
  except
    on E: Exception do
      ShowMessage('Aefos PyTools: ' + E.Message);
  end;
end;

// The IDE 'View' menu (falling back to the menu-bar root), same host the two
// 'Aefos AI (...)' menus use.
function _ViewMenuHost: TMenuItem;
var
  LServices: INTAServices;
  LMain: TMainMenu;
begin
  Result := nil;
  if not Supports(BorlandIDEServices, INTAServices, LServices) then
    Exit;
  LMain := LServices.MainMenu;
  if not Assigned(LMain) then
    Exit;
  Result := LMain.Items.Find('View');
  if not Assigned(Result) then
    Result := LMain.Items;
end;

procedure _RemoveStaleMenu(const AParent: TMenuItem);
var
  LIndex: Integer;
begin
  if AParent = nil then
    Exit;
  for LIndex := AParent.Count - 1 downto 0 do
    try
      if StartsText(CMenuCaption, AParent.Items[LIndex].Caption) then
        AParent.Items[LIndex].Free;
    except
    end;
end;

procedure RegisterPyToolsMenu;
var
  LHost: TMenuItem;
begin
  Inc(GMenuRefCount); // for teardown symmetry; still freed by the last Unregister
  // Pro, but HiddenByTier -- not a bare `not Allows`. That was the bug: the item
  // disappeared for a Free tier in EVERY build, while every other Pro surface
  // (Terminal MCP, AI Flow silent reload, chat commands) honours GATE_HARD_MODE
  // and stays visible during the soft beta. A menu item that is simply not there
  // is also the one failure a user cannot ask about: nothing on screen to point
  // at. So during beta it shows, tagged '(Pro)'; at GA it goes away.
  try
    LHost := _ViewMenuHost;
    if LHost = nil then
      Exit;
    if not Assigned(GMenuItem) then
    begin
      // First host: create the single shared item.
      _RemoveStaleMenu(LHost); // drop any leftover from a previous load
      GMenuClicker := TPyToolsMenuClicker.Create;
      GMenuItem := TMenuItem.Create(LHost);
      GMenuItem.Caption := CMenuCaption;
      GMenuItem.OnClick := GMenuClicker.Click;
      LHost.Add(GMenuItem);
    end
    else
    begin
      // Second host already created its own "Aefos AI (...)" menu just before this
      // call, which got appended AFTER our item — re-append ours so "Aefos PyTools"
      // stays LAST (below both Aefos AI menus).
      if Assigned(GMenuItem.Parent) then
        GMenuItem.Parent.Remove(GMenuItem);
      LHost.Add(GMenuItem);
    end;
  except
    on E: Exception do
      OutputDebugString(PChar('[Aefos] RegisterPyToolsMenu: ' + E.Message));
  end;
end;

procedure UnregisterPyToolsMenu;
begin
  if GMenuRefCount <= 0 then
    Exit;
  Dec(GMenuRefCount);
  if GMenuRefCount <> 0 then
    Exit; // another host still needs the item
  // Free OUR own item before the BPL unmaps (unload-AV rule: free your own menu
  // items; never leave an OnClick pointing into unloaded code).
  try
    if Assigned(GMenuItem) then
    begin
      if Assigned(GMenuItem.Parent) then
        GMenuItem.Parent.Remove(GMenuItem);
      FreeAndNil(GMenuItem);
    end;
  except
    on E: Exception do
      OutputDebugString(PChar('[Aefos] UnregisterPyToolsMenu: ' + E.Message));
  end;
  FreeAndNil(GMenuClicker);
end;

end.
