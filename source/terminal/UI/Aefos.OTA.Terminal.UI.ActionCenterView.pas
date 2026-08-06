unit Aefos.OTA.Terminal.UI.ActionCenterView;

interface

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.StdCtrls,
  Vcl.ComCtrls,
  Vcl.ExtCtrls,
  Vcl.Buttons,
  DockForm,
  Aefos.OTA.Terminal.Core.Actions,
  Aefos.OTA.Terminal.Core.ActionStore,
  Aefos.OTA.Terminal.Core.ActionRunner;

type
  /// <summary>
  /// Dockable panel hosting the Terminal Action Center: a category-grouped,
  /// searchable catalog of terminal actions with Run / New / Edit / Delete.
  /// </summary>
  TActionCenterView = class(TDockableForm)
    FToolbar: TPanel;
    FSearch: TEdit;
    FBtnRun: TSpeedButton;
    FBtnNew: TSpeedButton;
    FBtnEdit: TSpeedButton;
    FBtnDelete: TSpeedButton;
    FBtnImport: TSpeedButton;
    FBtnExport: TSpeedButton;
    FTree: TTreeView;
    procedure FSearchChange(Sender: TObject);
    procedure FBtnRunClick(Sender: TObject);
    procedure FBtnNewClick(Sender: TObject);
    procedure FBtnEditClick(Sender: TObject);
    procedure FBtnDeleteClick(Sender: TObject);
    procedure FBtnImportClick(Sender: TObject);
    procedure FBtnExportClick(Sender: TObject);
    procedure FTreeDblClick(Sender: TObject);
  private
    FStore: TActionStore;
    FCatalog: TActionCatalog;
    FRunner: TActionRunner;
    FOnCatalogChanged: TNotifyEvent;
    procedure _RefreshTree;
    function _MatchesFilter(const AAction: TTerminalAction): Boolean;
    function _SelectedAction: TTerminalAction;
    function _CloneAction(const ASource: TTerminalAction): TTerminalAction;
    function _ConfirmRun(const AAction: TTerminalAction): Boolean;
    function _ResolvePlaceholders(const AAction: TTerminalAction;
      const ANames: TArray<string>;
      out AValues: TDictionary<string, string>): Boolean;
    procedure _Persist;
    procedure _NotifyCatalogChanged;
    function _IsIDEDarkTheme: Boolean;
    procedure _CreateButtonGlyph(AButton: TSpeedButton; const AIconType: string);
    procedure _ApplyTheme;
  protected
    procedure DoShow; override;
    procedure SetParent(AParent: TWinControl); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure UpdateGlyphs;
    /// <summary>The live catalog backing this view; owned by the view.</summary>
    property Catalog: TActionCatalog read FCatalog;
    /// <summary>
    /// Fired after the catalog has been persisted (Add / Update / Delete via
    /// the panel). The wizard subscribes to this event during construction
    /// so IDE-wide keyboard bindings are refreshed in lock-step with user
    /// edits (ADR-029-02). A second fire with Sender = nil is emitted during
    /// teardown so subscribers can drop their reference to the catalog before
    /// it is freed.
    /// </summary>
    property OnCatalogChanged: TNotifyEvent
      read FOnCatalogChanged write FOnCatalogChanged;
  end;

var
  AefosActionCenterView: TActionCenterView;
  /// <summary>
  /// Hook attached to every newly constructed TActionCenterView's
  /// OnCatalogChanged. The wizard sets this once at startup so keyboard
  /// rebinding tracks the catalog regardless of which path (menu vs
  /// Ctrl+Shift+A) created the view (ADR-029-02).
  /// </summary>
  AefosTerminalActionCenterChangedHook: TNotifyEvent;

/// <summary>Shows the Action Center panel, creating it on first use.</summary>
procedure ShowAefosActionCenterView;
/// <summary>Toggles the Action Center panel's visibility.</summary>
procedure ToggleActionCenterView;

/// <summary>
/// Returns the display string used in the Action Edit dialog for a Shortcut
/// value: "(none)" when 0; otherwise the canonical Vcl.Menus token
/// ("Ctrl+Shift+F5"). Extracted to a unit-level helper so headless tests
/// can cover the mapping without instantiating the dialog (AC7,
/// ADR-029-01).
/// </summary>
function ShortCutToDisplay(const AShortCut: TShortCut): string;

implementation

uses
  ToolsAPI,
  Vcl.Dialogs,
  Vcl.Graphics,
  Vcl.Menus,
  Aefos.OTA.Terminal.UI.DockForm,
  Aefos.OTA.Terminal.UI.KeyBinding,
  Aefos.OTA.Terminal.UI.ThemedForm,
  Aefos.OTA.Terminal.UI.IDEThemes;

{$R *.dfm}

procedure _RegisterActionCenterViewClass;
begin
  // No-op to prevent Access Violations on IDE close/BPL unload
end;

procedure _UnregisterActionCenterViewClass;
begin
  // No-op
end;

type
  /// <summary>
  /// Small modal that records the next keyboard shortcut the user presses
  /// and returns it as a TShortCut. Pure modifier presses are ignored;
  /// ESC cancels. The form sets KeyPreview so the first non-modifier
  /// key-down closes the modal.
  /// </summary>
  TShortcutCaptureDialog = class(TAefosTerminalThemedForm)
  private
    FResult: TShortCut;
    procedure _KeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
  public
    constructor Create(AOwner: TComponent); reintroduce;
    destructor Destroy; override;
    class function Execute(out AShortCut: TShortCut): Boolean;
  end;

  /// <summary>
  /// Modal editor for a single TTerminalAction. Built entirely in code so the
  /// Action Center needs no separate .dfm unit.
  /// </summary>
  TActionEditDialog = class(TAefosTerminalThemedForm)
  private
    FName: TEdit;
    FCategory: TEdit;
    FDescription: TEdit;
    FProfile: TEdit;
    FWorkingDir: TEdit;
    FScript: TMemo;
    FShortcutEdit: TEdit;
    FShortcutValue: TShortCut;
    FConfirm: TCheckBox;
    function _AddLabel(const ACaption: string; ATop: Integer): TLabel;
    function _AddEdit(ATop: Integer): TEdit;
    procedure _BuildFields;
    procedure _BuildShortcutRow(ATop: Integer);
    procedure _BuildButtons;
    procedure _LoadFrom(const AAction: TTerminalAction);
    procedure _StoreTo(const AAction: TTerminalAction);
    procedure _CaptureClick(Sender: TObject);
    procedure _ClearClick(Sender: TObject);
    procedure _RefreshShortcutDisplay;
  public
    constructor Create(AOwner: TComponent); reintroduce;
    destructor Destroy; override;
    /// <summary>
    /// Edits AAction in a modal dialog. Returns True when the user confirms;
    /// AAction is mutated only on confirmation.
    /// </summary>
    class function Execute(const AAction: TTerminalAction): Boolean;
  end;

  /// <summary>
  /// Modal prompt that collects one value per unique placeholder discovered
  /// in an action's script. Built entirely in code (no .dfm); one row per
  /// name with a TLabel + TEdit. Up to 6 rows fit without scrolling; rows
  /// beyond that wrap into a scrollable region. The Execute class function
  /// allocates the result dictionary only when the user confirms (OK),
  /// transferring ownership to the runner per ADR-030-02.
  /// </summary>
  TPlaceholderPromptDialog = class(TAefosTerminalThemedForm)
  private
    FEdits: TArray<TEdit>;
    FNames: TArray<string>;
    procedure _Build(const ANames: TArray<string>);
  public
    constructor Create(AOwner: TComponent; const ANames: TArray<string>); reintroduce;
    destructor Destroy; override;
    /// <summary>
    /// Opens the dialog. On OK, allocates a fresh dictionary mapping each
    /// name to the value typed in the matching edit and returns True; the
    /// caller (runner) owns the dictionary. On Cancel returns False without
    /// allocating.
    /// </summary>
    class function Execute(const ANames: TArray<string>;
      out AValues: TDictionary<string, string>): Boolean;
  end;

function ShortCutToDisplay(const AShortCut: TShortCut): string;
begin
  if AShortCut = 0 then
    Exit('(none)');
  // TShortCut in implementation scope resolves to Vcl.Menus.TShortCut (last
  // uses entry). The cast widens the domain Word alias into that distinct
  // `type Word` so ShortCutToText accepts it.
  Result := Vcl.Menus.ShortCutToText(TShortCut(AShortCut));
  if Result = '' then
    Result := Format('Unknown (%d)', [AShortCut]);
end;

procedure ShowAefosActionCenterView;
begin
  if not Assigned(AefosActionCenterView) then
  begin
    _RegisterActionCenterViewClass;
    AefosActionCenterView := TActionCenterView.Create(nil);
  end;
  if not AefosActionCenterView.Visible then
    AefosActionCenterView.Show
  else
    AefosActionCenterView.BringToFront;
end;

procedure ToggleActionCenterView;
begin
  if Assigned(AefosActionCenterView) and
     AefosActionCenterView.Visible and not IsConsole then
    AefosActionCenterView.Hide
  else
    ShowAefosActionCenterView;
end;

{ TActionEditDialog }

constructor TActionEditDialog.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  FShortcutValue := 0;
  Caption := 'Edit Action';
  BorderStyle := bsDialog;
  Position := poScreenCenter;
  ClientWidth := 420;
  ClientHeight := 392;
  _BuildFields;
  _BuildButtons;
  // Code-built dialog: theme after controls exist via the base hook (ESP-077 /
  // ADR-077-02). CreateNew bypasses the base constructor, so call explicitly.
  _ApplyTheme;
end;

destructor TActionEditDialog.Destroy;
begin
  inherited;
end;

function TActionEditDialog._AddLabel(const ACaption: string;
  ATop: Integer): TLabel;
begin
  Result := TLabel.Create(Self);
  Result.Parent := Self;
  Result.SetBounds(12, ATop + 3, 80, 17);
  Result.Caption := ACaption;
end;

function TActionEditDialog._AddEdit(ATop: Integer): TEdit;
begin
  Result := TEdit.Create(Self);
  Result.Parent := Self;
  Result.SetBounds(100, ATop, 308, 23);
end;

procedure TActionEditDialog._BuildFields;
var
  LConfirmLabel: TLabel;
begin
  _AddLabel('Name', 12);
  FName := _AddEdit(12);
  _AddLabel('Category', 42);
  FCategory := _AddEdit(42);
  _AddLabel('Description', 72);
  FDescription := _AddEdit(72);
  _AddLabel('Profile', 102);
  FProfile := _AddEdit(102);
  _AddLabel('Working dir', 132);
  FWorkingDir := _AddEdit(132);
  _AddLabel('Script', 162);

  FScript := TMemo.Create(Self);
  FScript.Parent := Self;
  FScript.SetBounds(100, 162, 308, 110);
  FScript.ScrollBars := ssVertical;

  _BuildShortcutRow(282);

  FConfirm := TCheckBox.Create(Self);
  FConfirm.Parent := Self;
  FConfirm.SetBounds(100, 318, 16, 19);
  FConfirm.Caption := '';

  LConfirmLabel := TLabel.Create(Self);
  LConfirmLabel.Parent := Self;
  LConfirmLabel.SetBounds(120, 319, 260, 17);
  LConfirmLabel.Caption := 'Confirm before running';
  LConfirmLabel.FocusControl := FConfirm;
end;

procedure TActionEditDialog._BuildShortcutRow(ATop: Integer);
var
  LBtnCapture, LBtnClear: TButton;
begin
  _AddLabel('Shortcut', ATop);
  FShortcutEdit := TEdit.Create(Self);
  FShortcutEdit.Parent := Self;
  FShortcutEdit.SetBounds(100, ATop, 160, 23);
  FShortcutEdit.ReadOnly := True;
  FShortcutEdit.Text := ShortCutToDisplay(FShortcutValue);

  LBtnCapture := TButton.Create(Self);
  LBtnCapture.Parent := Self;
  LBtnCapture.SetBounds(266, ATop - 2, 70, 25);
  LBtnCapture.Caption := 'Capture...';
  LBtnCapture.OnClick := _CaptureClick;

  LBtnClear := TButton.Create(Self);
  LBtnClear.Parent := Self;
  LBtnClear.SetBounds(340, ATop - 2, 68, 25);
  LBtnClear.Caption := 'Clear';
  LBtnClear.OnClick := _ClearClick;
end;

procedure TActionEditDialog._BuildButtons;
var
  LOk, LCancel: TButton;
begin
  LOk := TButton.Create(Self);
  LOk.Parent := Self;
  LOk.SetBounds(244, 350, 80, 27);
  LOk.Caption := 'OK';
  LOk.Default := True;
  LOk.ModalResult := mrOk;

  LCancel := TButton.Create(Self);
  LCancel.Parent := Self;
  LCancel.SetBounds(330, 350, 80, 27);
  LCancel.Caption := 'Cancel';
  LCancel.Cancel := True;
  LCancel.ModalResult := mrCancel;
end;

procedure TActionEditDialog._RefreshShortcutDisplay;
begin
  if Assigned(FShortcutEdit) then
    FShortcutEdit.Text := ShortCutToDisplay(FShortcutValue);
end;

procedure TActionEditDialog._CaptureClick(Sender: TObject);
var
  LCaptured: TShortCut;
begin
  if TShortcutCaptureDialog.Execute(LCaptured) then
  begin
    FShortcutValue := LCaptured;
    _RefreshShortcutDisplay;
  end;
end;

procedure TActionEditDialog._ClearClick(Sender: TObject);
begin
  FShortcutValue := 0;
  _RefreshShortcutDisplay;
end;

procedure TActionEditDialog._LoadFrom(const AAction: TTerminalAction);
var
  LLine: string;
begin
  FName.Text := AAction.Name;
  FCategory.Text := AAction.Category;
  FDescription.Text := AAction.Description;
  FProfile.Text := AAction.ProfileName;
  FWorkingDir.Text := AAction.WorkingDir;
  FConfirm.Checked := AAction.ConfirmBeforeRun;
  FShortcutValue := AAction.Shortcut;
  _RefreshShortcutDisplay;
  for LLine in AAction.ScriptLines do
    FScript.Lines.Add(LLine);
end;

procedure TActionEditDialog._StoreTo(const AAction: TTerminalAction);
begin
  AAction.Name := Trim(FName.Text);
  AAction.Category := Trim(FCategory.Text);
  AAction.Description := FDescription.Text;
  AAction.ProfileName := Trim(FProfile.Text);
  AAction.WorkingDir := Trim(FWorkingDir.Text);
  AAction.ConfirmBeforeRun := FConfirm.Checked;
  AAction.Shortcut := FShortcutValue;
  AAction.ScriptLines := FScript.Lines.ToStringArray;
end;

{ TShortcutCaptureDialog }

constructor TShortcutCaptureDialog.Create(AOwner: TComponent);
var
  LPrompt: TLabel;
  LHint: TLabel;
begin
  inherited CreateNew(AOwner);
  FResult := 0;
  Caption := 'Capture Shortcut';
  BorderStyle := bsDialog;
  Position := poScreenCenter;
  ClientWidth := 280;
  ClientHeight := 120;
  KeyPreview := True;
  OnKeyDown := _KeyDown;

  LPrompt := TLabel.Create(Self);
  LPrompt.Parent := Self;
  LPrompt.SetBounds(16, 24, 248, 17);
  LPrompt.Alignment := taCenter;
  LPrompt.AutoSize := False;
  LPrompt.Caption := 'Press the keys to bind...';

  LHint := TLabel.Create(Self);
  LHint.Parent := Self;
  LHint.SetBounds(16, 64, 248, 17);
  LHint.Alignment := taCenter;
  LHint.AutoSize := False;
  LHint.Caption := 'ESC to cancel';

  // Code-built dialog: theme after controls exist via the base hook (ESP-077 /
  // ADR-077-02). CreateNew bypasses the base constructor, so call explicitly.
  _ApplyTheme;
end;

destructor TShortcutCaptureDialog.Destroy;
begin
  inherited;
end;

procedure TShortcutCaptureDialog._KeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  // ESC cancels.
  if Key = VK_ESCAPE then
  begin
    FResult := 0;
    ModalResult := mrCancel;
    Key := 0;
    Exit;
  end;
  // Pure modifier presses (Shift / Ctrl / Alt) by themselves are not valid
  // shortcuts — wait for an accompanying key.
  if (Key = VK_SHIFT) or (Key = VK_CONTROL) or (Key = VK_MENU) or
     (Key = VK_LWIN) or (Key = VK_RWIN) then
    Exit;
  // Word(...) lands the distinct Vcl.Menus.TShortCut value into the domain
  // alias (a plain Word) — see ADR-029-01 / TShortCut comment.
  FResult := Word(Vcl.Menus.ShortCut(Key, Shift));
  ModalResult := mrOk;
  Key := 0;
end;

class function TShortcutCaptureDialog.Execute(out AShortCut: TShortCut): Boolean;
var
  LDialog: TShortcutCaptureDialog;
begin
  AShortCut := 0;
  LDialog := TShortcutCaptureDialog.Create(nil);
  try
    Result := LDialog.ShowModal = mrOk;
    if Result then
      AShortCut := LDialog.FResult;
  finally
    LDialog.Free;
  end;
end;

class function TActionEditDialog.Execute(
  const AAction: TTerminalAction): Boolean;
var
  LDialog: TActionEditDialog;
begin
  LDialog := TActionEditDialog.Create(nil);
  try
    LDialog._LoadFrom(AAction);
    Result := LDialog.ShowModal = mrOk;
    if Result then
      LDialog._StoreTo(AAction);
  finally
    LDialog.Free;
  end;
end;

{ TPlaceholderPromptDialog }

const
  PLACEHOLDER_ROW_HEIGHT = 28;
  PLACEHOLDER_VISIBLE_ROWS = 6;
  PLACEHOLDER_LABEL_WIDTH = 120;
  PLACEHOLDER_EDIT_WIDTH = 220;
  PLACEHOLDER_FORM_WIDTH = 360;
  PLACEHOLDER_TOP_PADDING = 12;
  PLACEHOLDER_BUTTON_HEIGHT = 27;
  PLACEHOLDER_BOTTOM_PADDING = 48;

constructor TPlaceholderPromptDialog.Create(AOwner: TComponent; const ANames: TArray<string>);
begin
  inherited CreateNew(AOwner);
  FNames := ANames;
  Caption := 'Action Parameters';
  BorderStyle := bsDialog;
  Position := poScreenCenter;
  KeyPreview := True;
  _Build(ANames);
  // Code-built dialog: theme after controls exist via the base hook (ESP-077 /
  // ADR-077-02). CreateNew bypasses the base constructor, so call explicitly.
  _ApplyTheme;
end;

destructor TPlaceholderPromptDialog.Destroy;
begin
  inherited;
end;

procedure TPlaceholderPromptDialog._Build(const ANames: TArray<string>);
var
  LIndex: Integer;
  LVisible: Integer;
  LScroll: TScrollBox;
  LParent: TWinControl;
  LLabel: TLabel;
  LTop: Integer;
  LOk, LCancel: TButton;
  LRowsHeight: Integer;
begin
  LVisible := Length(ANames);
  if LVisible > PLACEHOLDER_VISIBLE_ROWS then
    LVisible := PLACEHOLDER_VISIBLE_ROWS;
  if LVisible < 1 then
    LVisible := 1;

  LRowsHeight := LVisible * PLACEHOLDER_ROW_HEIGHT;
  ClientWidth := PLACEHOLDER_FORM_WIDTH;
  ClientHeight := PLACEHOLDER_TOP_PADDING + LRowsHeight
    + PLACEHOLDER_BOTTOM_PADDING;

  if Length(ANames) > PLACEHOLDER_VISIBLE_ROWS then
  begin
    LScroll := TScrollBox.Create(Self);
    LScroll.Parent := Self;
    LScroll.SetBounds(8, PLACEHOLDER_TOP_PADDING,
      PLACEHOLDER_FORM_WIDTH - 16, LRowsHeight);
    LScroll.BorderStyle := bsNone;
    LScroll.VertScrollBar.Tracking := True;
    LParent := LScroll;
  end
  else
    LParent := Self;

  SetLength(FEdits, Length(ANames));
  for LIndex := 0 to High(ANames) do
  begin
    if LParent = Self then
      LTop := PLACEHOLDER_TOP_PADDING + LIndex * PLACEHOLDER_ROW_HEIGHT
    else
      LTop := LIndex * PLACEHOLDER_ROW_HEIGHT + 4;

    LLabel := TLabel.Create(Self);
    LLabel.Parent := LParent;
    LLabel.SetBounds(8, LTop + 4, PLACEHOLDER_LABEL_WIDTH, 17);
    LLabel.Caption := ANames[LIndex] + ':';
    LLabel.AutoSize := False;

    FEdits[LIndex] := TEdit.Create(Self);
    FEdits[LIndex].Parent := LParent;
    FEdits[LIndex].SetBounds(PLACEHOLDER_LABEL_WIDTH + 8, LTop,
      PLACEHOLDER_EDIT_WIDTH, 23);
    FEdits[LIndex].Text := '';
  end;

  LOk := TButton.Create(Self);
  LOk.Parent := Self;
  LOk.SetBounds(PLACEHOLDER_FORM_WIDTH - 176,
    ClientHeight - PLACEHOLDER_BUTTON_HEIGHT - 12, 80,
    PLACEHOLDER_BUTTON_HEIGHT);
  LOk.Caption := 'OK';
  LOk.Default := True;
  LOk.ModalResult := mrOk;

  LCancel := TButton.Create(Self);
  LCancel.Parent := Self;
  LCancel.SetBounds(PLACEHOLDER_FORM_WIDTH - 90,
    ClientHeight - PLACEHOLDER_BUTTON_HEIGHT - 12, 80,
    PLACEHOLDER_BUTTON_HEIGHT);
  LCancel.Caption := 'Cancel';
  LCancel.Cancel := True;
  LCancel.ModalResult := mrCancel;
end;

class function TPlaceholderPromptDialog.Execute(const ANames: TArray<string>;
  out AValues: TDictionary<string, string>): Boolean;
var
  LDialog: TPlaceholderPromptDialog;
  LIndex: Integer;
begin
  AValues := nil;
  LDialog := TPlaceholderPromptDialog.Create(nil, ANames);
  try
    Result := LDialog.ShowModal = mrOk;
    if Result then
    begin
      AValues := TDictionary<string, string>.Create;
      for LIndex := 0 to High(ANames) do
        AValues.AddOrSetValue(ANames[LIndex], LDialog.FEdits[LIndex].Text);
    end;
  finally
    LDialog.Free;
  end;
end;

{ TActionCenterView }

constructor TActionCenterView.Create(AOwner: TComponent);
begin
  try
    // Standard Create — loads layout from the .dfm file
    inherited Create(AOwner);
    // ESP-055 / ADR-055-01 — guard the floating-resize contract at the
    // code path too so any future DFM regression (or designer
    // round-trip) cannot silently revert to bsDialog. #89.
    BorderStyle := bsSizeable;
    Constraints.MinWidth := 420;
    Constraints.MinHeight := 320;
    FStore := TActionStore.Create;
    FRunner := TActionRunner.Create;
    FCatalog := FStore.LoadCatalog;
    // Attach the global subscriber (the wizard, set once at startup) so that
    // every freshly constructed view feeds its own catalog to keyboard
    // registration. Fire once so the wizard re-registers against this view's
    // catalog instance instead of the boot one (ADR-029-02).
    FOnCatalogChanged := AefosTerminalActionCenterChangedHook;
    // Publish the placeholder resolver so the shortcut handler (which lives in
    // Aefos.OTA.Terminal.UI.KeyBinding) can drive the same prompt dialog without taking a
    // direct dependency on the view (ADR-030-02).
    Aefos.OTA.Terminal.UI.KeyBinding.TAefosTerminalKeyBindingRegistry.ActionPlaceholderResolver := _ResolvePlaceholders;
    
    // Apply theme and custom visual tuning
    _ApplyTheme;

    // Bind icons dynamically from DockForm resources if available at this point
    UpdateGlyphs;

    DoubleBuffered := True;
    FTree.DoubleBuffered := True;

    _RefreshTree;
    _NotifyCatalogChanged;
  except
    on E: Exception do
      OutputDebugString(PChar('Aefos.OTA.Terminal ActionCenterView Create: ' + E.Message));
  end;
end;

destructor TActionCenterView.Destroy;
begin
  // Drop the resolver bridge before any other teardown so a late-firing
  // shortcut cannot reach a half-destroyed view (ADR-030-02). RunAction
  // treats a nil resolver on a placeholder-bearing action as aroCancelled.
  Aefos.OTA.Terminal.UI.KeyBinding.TAefosTerminalKeyBindingRegistry.ActionPlaceholderResolver := nil;
  // Signal teardown with Sender = nil so the wizard can drop its reference to
  // FCatalog before we free it. Without this, GLiveCatalog inside
  // Aefos.OTA.Terminal.UI.KeyBinding would dangle until the wizard's own destructor fires.
  if Assigned(FOnCatalogChanged) then
    try
      FOnCatalogChanged(nil);
    except
      on E: Exception do
        OutputDebugString(PChar('Aefos.OTA.Terminal ActionCenterView teardown notify: '
          + E.ClassName + ' - ' + E.Message));
    end;
  FRunner.Free;
  FCatalog.Free;
  FStore.Free;
  // Release the module-scope singleton so the wizard's _OpenOrRecreatePanel
  // helper sees Assigned=False after a close-via-X teardown and recreates a
  // fresh view on the next menu re-open (#88, ADR-054-01).
  if AefosActionCenterView = Self then
    AefosActionCenterView := nil;
  inherited;
end;

procedure TActionCenterView.DoShow;
begin
  try
    inherited;
    _ApplyTheme;
    UpdateGlyphs;
  except
    on E: Exception do
      OutputDebugString(PChar('Aefos.OTA.Terminal ActionCenterView DoShow: ' + E.Message));
  end;
end;

procedure TActionCenterView.SetParent(AParent: TWinControl);
var
  {$IF Declared(IOTAIDEThemingServices)}
  LThemeServices: IOTAIDEThemingServices;
  {$IFEND}
  LParentForm: TCustomForm;
begin
  inherited SetParent(AParent);
  if Assigned(AParent) then
  begin
    _ApplyTheme;
    
    // If our parent is a floating dock host, apply the IDE theme to it as well!
    if SameText(AParent.ClassName, 'TFloatDockForm') or
       SameText(AParent.ClassName, 'TFloatWindow') then
    begin
      // Nothing to mirror on an IDE with no themes (10 Seattle): the float host
      // keeps its own colours.
      {$IF Declared(IOTAIDEThemingServices)}
      if Supports(BorlandIDEServices, IOTAIDEThemingServices, LThemeServices) and
         LThemeServices.IDEThemingEnabled then
      begin
        LParentForm := GetParentForm(AParent);
        if Assigned(LParentForm) then
          LThemeServices.ApplyTheme(LParentForm);
      end;
      {$IFEND}
    end;
  end;
end;

procedure TActionCenterView._ApplyTheme;
begin
  ApplyAefosTerminalIDETheme(Self);
end;

procedure TActionCenterView.UpdateGlyphs;
begin
  try
    _CreateButtonGlyph(FBtnRun, 'play');
    _CreateButtonGlyph(FBtnNew, 'plus');
    _CreateButtonGlyph(FBtnEdit, 'pencil');
    _CreateButtonGlyph(FBtnDelete, 'trash');
    _CreateButtonGlyph(FBtnImport, 'import');
    _CreateButtonGlyph(FBtnExport, 'export');
  except
    on E: Exception do
      OutputDebugString(PChar('Aefos.OTA.Terminal ActionCenterView UpdateGlyphs: ' + E.Message));
  end;
end;

function TActionCenterView._IsIDEDarkTheme: Boolean;
// The var section itself is inside the guard: these are the ONLY locals, and a
// `var` with nothing under it is a syntax error, not an empty block.
{$IF Declared(IOTAIDEThemingServices)}
var
  LThemeServices: IOTAIDEThemingServices;
  LThemeName: string;
{$IFEND}
begin
  Result := True; // Default to dark theme
  // An IDE with no theming service (10 Seattle) has no theme name to inspect,
  // so the default above stands - the same answer this gives today when theming
  // is switched off.
  {$IF Declared(IOTAIDEThemingServices)}
  if Supports(BorlandIDEServices, IOTAIDEThemingServices, LThemeServices) and
     LThemeServices.IDEThemingEnabled then
  begin
    LThemeName := LowerCase(LThemeServices.ActiveTheme);
    if (Pos('light', LThemeName) > 0) or
       (Pos('mountain', LThemeName) > 0) or
       (LThemeName = 'windows') or
       (LThemeName = 'campbell') then
      Result := False;
  end;
  {$IFEND}
end;

procedure TActionCenterView._CreateButtonGlyph(AButton: TSpeedButton; const AIconType: string);
var
  LBitmap: TBitmap;
  LPenColor: TColor;
begin
  try
    LBitmap := TBitmap.Create;
    try
      LBitmap.Width := 16;
      LBitmap.Height := 16;
      LBitmap.PixelFormat := pf32bit;
      
      // Clear with transparent Fuchsia
      LBitmap.Canvas.Brush.Color := clFuchsia;
      LBitmap.Canvas.FillRect(Rect(0, 0, LBitmap.Width, LBitmap.Height));
      
      if _IsIDEDarkTheme then
        LPenColor := $D4D4D4 // Modern light grey (VS Code dark theme text)
      else
        LPenColor := $333333; // Modern dark grey (VS Code light theme text)
        
      LBitmap.Canvas.Pen.Color := LPenColor;
      LBitmap.Canvas.Pen.Width := 1;
      LBitmap.Canvas.Brush.Style := bsClear;
      
      if AIconType = 'play' then
      begin
        // Play triangle wireframe
        LBitmap.Canvas.Polygon([Point(5, 3), Point(13, 8), Point(5, 13)]);
      end
      else if AIconType = 'plus' then
      begin
        // Thin wireframe Plus (+)
        LBitmap.Canvas.MoveTo(8, 2);
        LBitmap.Canvas.LineTo(8, 14);
        LBitmap.Canvas.MoveTo(2, 8);
        LBitmap.Canvas.LineTo(14, 8);
      end
      else if AIconType = 'pencil' then
      begin
        // Pencil / Edit icon
        LBitmap.Canvas.MoveTo(12, 2);
        LBitmap.Canvas.LineTo(14, 4);
        LBitmap.Canvas.LineTo(6, 12);
        LBitmap.Canvas.LineTo(3, 13);
        LBitmap.Canvas.LineTo(4, 10);
        LBitmap.Canvas.LineTo(12, 2);
        LBitmap.Canvas.MoveTo(4, 10);
        LBitmap.Canvas.LineTo(6, 10);
        LBitmap.Canvas.LineTo(6, 12);
      end
      else if AIconType = 'trash' then
      begin
        // Thin wireframe Trash Can
        // Lid
        LBitmap.Canvas.MoveTo(2, 4);
        LBitmap.Canvas.LineTo(14, 4);
        // Handle
        LBitmap.Canvas.MoveTo(6, 4);
        LBitmap.Canvas.LineTo(6, 2);
        LBitmap.Canvas.LineTo(10, 2);
        LBitmap.Canvas.LineTo(10, 4);
        // Body
        LBitmap.Canvas.MoveTo(4, 5);
        LBitmap.Canvas.LineTo(5, 14);
        LBitmap.Canvas.LineTo(11, 14);
        LBitmap.Canvas.LineTo(12, 5);
        // Inner vertical bars
        LBitmap.Canvas.MoveTo(7, 6);
        LBitmap.Canvas.LineTo(7, 12);
        LBitmap.Canvas.MoveTo(9, 6);
        LBitmap.Canvas.LineTo(9, 12);
      end
      else if AIconType = 'import' then
      begin
        // Thin wireframe Import (downward arrow into a tray)
        // Arrow shaft
        LBitmap.Canvas.MoveTo(8, 2);
        LBitmap.Canvas.LineTo(8, 10); // draws (8,2)..(8,9)
        // Arrow head
        LBitmap.Canvas.MoveTo(5, 6);
        LBitmap.Canvas.LineTo(9, 10); // draws (5,6)..(8,9)
        LBitmap.Canvas.MoveTo(11, 6);
        LBitmap.Canvas.LineTo(7, 10); // draws (11,6)..(8,9)
        // Tray bottom bracket
        LBitmap.Canvas.MoveTo(3, 9);
        LBitmap.Canvas.LineTo(3, 13); // draws Y=9..12 at X=3
        LBitmap.Canvas.MoveTo(3, 13);
        LBitmap.Canvas.LineTo(14, 13); // draws X=3..13 at Y=13
        LBitmap.Canvas.MoveTo(13, 13);
        LBitmap.Canvas.LineTo(13, 8); // draws Y=13..9 at X=13
      end
      else if AIconType = 'export' then
      begin
        // Thin wireframe Export (upward arrow out of a tray)
        // Arrow shaft
        LBitmap.Canvas.MoveTo(8, 10);
        LBitmap.Canvas.LineTo(8, 2); // draws (8,10)..(8,3)
        // Arrow head
        LBitmap.Canvas.MoveTo(5, 6);
        LBitmap.Canvas.LineTo(9, 2); // draws (5,6)..(8,3)
        LBitmap.Canvas.MoveTo(11, 6);
        LBitmap.Canvas.LineTo(7, 2); // draws (11,6)..(8,3)
        // Tray bottom bracket
        LBitmap.Canvas.MoveTo(3, 9);
        LBitmap.Canvas.LineTo(3, 13); // draws Y=9..12 at X=3
        LBitmap.Canvas.MoveTo(3, 13);
        LBitmap.Canvas.LineTo(14, 13); // draws X=3..13 at Y=13
        LBitmap.Canvas.MoveTo(13, 13);
        LBitmap.Canvas.LineTo(13, 8); // draws Y=13..9 at X=13
      end;
      
      LBitmap.TransparentColor := clFuchsia;
      LBitmap.Transparent := True;
      
      AButton.Glyph.Assign(LBitmap);
      AButton.Caption := ''; // Keep caption empty so only the vector glyph is drawn!
    finally
      LBitmap.Free;
    end;
  except
    on E: Exception do
      OutputDebugString(PChar('Aefos.OTA.Terminal _CreateButtonGlyph: ' + E.Message));
  end;
end;

procedure TActionCenterView._NotifyCatalogChanged;
begin
  if Assigned(FOnCatalogChanged) then
    FOnCatalogChanged(Self);
end;

function TActionCenterView._MatchesFilter(
  const AAction: TTerminalAction): Boolean;
var
  LFilter: string;
begin
  LFilter := LowerCase(Trim(FSearch.Text));
  if LFilter = '' then
    Exit(True);
  Result := AAction.Name.ToLower.Contains(LFilter) or
            AAction.EffectiveCategory.ToLower.Contains(LFilter) or
            AAction.Description.ToLower.Contains(LFilter);
end;

procedure TActionCenterView._RefreshTree;
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
        if not Assigned(LCategoryNode) then
          LCategoryNode := FTree.Items.Add(nil, LCategory);
        LActionNode := FTree.Items.AddChild(LCategoryNode, LAction.Name);
        LActionNode.Data := LAction;
      end;
      if Assigned(LCategoryNode) then
        LCategoryNode.Expand(True);
    end;
  finally
    FTree.Items.EndUpdate;
  end;
end;

function TActionCenterView._SelectedAction: TTerminalAction;
begin
  Result := nil;
  if Assigned(FTree.Selected) and Assigned(FTree.Selected.Data) then
    Result := TTerminalAction(FTree.Selected.Data);
end;

function TActionCenterView._CloneAction(
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
end;

function TActionCenterView._ConfirmRun(const AAction: TTerminalAction): Boolean;
begin
  Result := MessageDlg(Format('Run action "%s"?', [AAction.Name]),
    mtConfirmation, [mbYes, mbNo], 0) = mrYes;
end;

function TActionCenterView._ResolvePlaceholders(
  const AAction: TTerminalAction; const ANames: TArray<string>;
  out AValues: TDictionary<string, string>): Boolean;
begin
  Result := TPlaceholderPromptDialog.Execute(ANames, AValues);
end;

procedure TActionCenterView._Persist;
begin
  FStore.SaveCatalog(FCatalog);
  _NotifyCatalogChanged;
end;

procedure TActionCenterView.FSearchChange(Sender: TObject);
begin
  _RefreshTree;
end;

procedure TActionCenterView.FBtnRunClick(Sender: TObject);
var
  LAction: TTerminalAction;
  LResult: TActionRunResult;
begin
  LAction := _SelectedAction;
  if not Assigned(LAction) then
    Exit;
  LResult := FRunner.RunAction(LAction, AefosOTATerminalActiveTerminalInput,
    _ConfirmRun, _ResolvePlaceholders);
  if not LResult.IsSuccess and (LResult.Outcome <> aroCancelled) then
    MessageDlg(LResult.Message, mtWarning, [mbOK], 0);
end;

procedure TActionCenterView.FBtnNewClick(Sender: TObject);
var
  LAction: TTerminalAction;
begin
  LAction := TTerminalAction.Create;
  if not TActionEditDialog.Execute(LAction) then
  begin
    LAction.Free;
    Exit;
  end;
  // FCatalog.Add takes ownership unconditionally — it frees LAction on
  // rejection, so the catalog must not be freed again here.
  if FCatalog.Add(LAction) then
  begin
    _Persist;
    _RefreshTree;
  end;
end;

procedure TActionCenterView.FBtnEditClick(Sender: TObject);
var
  LSelected: TTerminalAction;
  LDraft: TTerminalAction;
begin
  LSelected := _SelectedAction;
  if not Assigned(LSelected) then
    Exit;
  LDraft := _CloneAction(LSelected);
  if not TActionEditDialog.Execute(LDraft) then
  begin
    LDraft.Free;
    Exit;
  end;
  // FCatalog.Update takes ownership unconditionally — it frees LDraft on
  // rejection, so the draft must not be freed again here.
  if FCatalog.Update(LDraft) then
  begin
    _Persist;
    _RefreshTree;
  end;
end;

procedure TActionCenterView.FBtnDeleteClick(Sender: TObject);
var
  LAction: TTerminalAction;
begin
  LAction := _SelectedAction;
  if not Assigned(LAction) then
    Exit;
  if MessageDlg(Format('Delete action "%s"?', [LAction.Name]),
    mtConfirmation, [mbYes, mbNo], 0) = mrYes then
  begin
    FCatalog.Remove(LAction.Id);
    _Persist;
    _RefreshTree;
  end;
end;

const
  ACTION_JSON_FILTER = 'JSON files (*.json)|*.json|All files (*.*)|*.*';

procedure TActionCenterView.FBtnImportClick(Sender: TObject);
var
  LDialog: TOpenDialog;
  LReport: TActionImportReport;
begin
  LDialog := TOpenDialog.Create(nil);
  try
    LDialog.Filter := ACTION_JSON_FILTER;
    LDialog.DefaultExt := 'json';
    LDialog.Options := LDialog.Options + [ofFileMustExist];
    if not LDialog.Execute then
      Exit;

    if TActionStore.ImportCatalogFromFile(LDialog.FileName, FCatalog,
      LReport) then
    begin
      // AC8 ordering: persist → refresh → notify. _Persist writes
      // actions.json (and fires an intermediate notify); _RefreshTree
      // rebuilds the tree from the merged catalog; the final
      // _NotifyCatalogChanged satisfies the AC's explicit terminal step
      // so subscribers (the wizard, ESP-029) always see a fully
      // persisted-and-refreshed state.
      _Persist;
      _RefreshTree;
      _NotifyCatalogChanged;
      MessageDlg(Format(
        'Imported %d, skipped %d, shortcuts dropped %d.',
        [LReport.Added, LReport.Skipped, LReport.ShortcutsDropped]),
        mtInformation, [mbOK], 0);
    end
    else
      MessageDlg('Import failed: ' + LReport.LastError,
        mtError, [mbOK], 0);
  finally
    LDialog.Free;
  end;
end;

procedure TActionCenterView.FBtnExportClick(Sender: TObject);
var
  LDialog: TSaveDialog;
begin
  LDialog := TSaveDialog.Create(nil);
  try
    LDialog.Filter := ACTION_JSON_FILTER;
    LDialog.DefaultExt := 'json';
    LDialog.FileName := 'actions.json';
    LDialog.Options := LDialog.Options + [ofOverwritePrompt];
    if not LDialog.Execute then
      Exit;
    // AC9: export must not mutate the catalog or fire OnCatalogChanged.
    TActionStore.ExportCatalogToFile(LDialog.FileName, FCatalog);
    MessageDlg(Format('Exported %d action(s).', [FCatalog.Count]),
      mtInformation, [mbOK], 0);
  finally
    LDialog.Free;
  end;
end;

procedure TActionCenterView.FTreeDblClick(Sender: TObject);
begin
  FBtnRunClick(Sender);
end;

initialization

finalization
  _UnregisterActionCenterViewClass;
  FreeAndNil(AefosActionCenterView);

end.




