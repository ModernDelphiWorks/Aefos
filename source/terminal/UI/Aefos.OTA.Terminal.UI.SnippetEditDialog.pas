unit Aefos.OTA.Terminal.UI.SnippetEditDialog;

(*
  V.6 snippet editor dialog - ESP-064 / ADR-064-01..03.

  Thin VCL shell over Aefos.OTA.Terminal.Core.SnippetEditModel: the form owns only rendering
  and event wiring (BR1/BR3). Title + Command + Scope + Tags are edited; the
  variable chips and the live preview are rebuilt from the pure helpers on every
  body change. Scope options Project/Team are enabled only when their tier path
  is active (BR4). The preview reuses TMustacheEngine.Substitute - the same resolver
  the sidebar run/copy path uses (ADR-064-03).
*)

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants, System.Classes,
  System.Generics.Collections, Vcl.Graphics,
  Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.StdCtrls, Vcl.ExtCtrls,
  Aefos.OTA.Terminal.UI.ThemedForm,
  Aefos.OTA.Terminal.Core.Snippets, Aefos.OTA.Terminal.Core.SnippetEditModel;

type
  TSnippetEditDialog = class(TAefosTerminalThemedForm)
    lblTitle: TLabel;
    edtTitle: TEdit;
    lblScope: TLabel;
    rbPersonal: TRadioButton;
    rbProject: TRadioButton;
    rbTeam: TRadioButton;
    lblTags: TLabel;
    edtTags: TEdit;
    lblCommand: TLabel;
    memCommand: TMemo;
    lblChips: TLabel;
    pnlChips: TFlowPanel;
    lblPreview: TLabel;
    memPreview: TMemo;
    pnlButtons: TPanel;
    btnOK: TButton;
    btnCancel: TButton;
    procedure memCommandChange(Sender: TObject);
    procedure btnOKClick(Sender: TObject);
  private
    // Live variable values supplied by the host (DockForm._BuildSnippetVarContext);
    // NOT owned here - the caller frees it (ADR-064-03). May be nil.
    FLiveContext: TDictionary<string, string>;
    // Chips currently rendered; a chip label's Tag indexes into this array so
    // the click handler can recover the raw variable name.
    FChips: TArray<TSnippetChip>;
    // V.8 (ESP-065 / ADR-065-03): pnlChips is keyboard-focusable; FSelectedChip
    // is the chip ringed under keyboard nav, FKeyboardNavigation gates the ring,
    // and FOriginalChipsWP holds the panel's pre-subclass WindowProc.
    FSelectedChip: Integer;
    FKeyboardNavigation: Boolean;
    FOriginalChipsWP: TWndMethod;
    procedure ChipsSubclassWP(var Message: TMessage);
    procedure _HandleChipsDlgCode(var Message: TMessage);
    procedure _HandleChipsFocus(var Message: TMessage);
    function  _HandleChipsKeyDown(var Message: TMessage): Boolean;
    procedure _HandleChipsPaint;
    procedure _MoveChipSelection(const ADelta: Integer);
    procedure _RebuildChips;
    procedure _RefreshPreview;
    procedure _ChipClick(Sender: TObject);
    procedure _ClearChips;
    function _ChipColor(const AKind: TSnippetVarKind): TColor;
    function _ChipHint(const AKind: TSnippetVarKind; const AName: string): string;
    function _SelectedScope: TSnippetScope;
    procedure _SetScope(const AScope: TSnippetScope);
  public
    constructor Create(AOwner: TComponent); override;
    /// <summary>
    ///   Edits a full snippet draft. In/out: ATitle, ACommand, AScope, ATags.
    ///   AProjectActive / ATeamActive gate the Project / Team scope options.
    ///   ALiveContext (optional, may be nil) supplies live variable values for
    ///   the preview; the caller retains ownership. Returns True on Save.
    /// </summary>
    class function Execute(var ATitle, ACommand: string;
      var AScope: TSnippetScope; var ATags: TArray<string>;
      const AProjectActive, ATeamActive: Boolean;
      const ALiveContext: TDictionary<string, string>): Boolean;
  end;

implementation

uses
  Aefos.OTA.Terminal.UI.IDEThemes, Aefos.OTA.Terminal.Core.Accessibility, Aefos.OTA.Terminal.Core.Mustache;

{$R *.dfm}

const
  CChipKnownColor    = TColor($005AA02E); // accent  (green)
  CChipDeferredColor = TColor($00808080); // muted   (gray)
  CChipUnknownColor  = TColor($00285AC8); // warning (orange)

{ TSnippetEditDialog }

constructor TSnippetEditDialog.Create(AOwner: TComponent);
begin
  // Theme is applied by the TAefosTerminalThemedForm base constructor
  // (ESP-077) after DFM streaming — same timing as the former _ApplyDialogTheme.
  inherited Create(AOwner);
  FLiveContext := nil;
  DoubleBuffered := True;
  // V.8: make the variable-chip strip keyboard-focusable and subclass it so it
  // paints the uniform focus ring around the selected chip and handles
  // Left/Right traversal + Enter-to-insert (ESP-065 / ADR-065-03).
  FSelectedChip := -1;
  FKeyboardNavigation := False;
  pnlChips.TabStop := True;
  FOriginalChipsWP := pnlChips.WindowProc;
  pnlChips.WindowProc := ChipsSubclassWP;
end;

function TSnippetEditDialog._ChipColor(const AKind: TSnippetVarKind): TColor;
begin
  case AKind of
    svkKnown:    Result := CChipKnownColor;
    svkDeferred: Result := CChipDeferredColor;
  else
    Result := CChipUnknownColor;
  end;
end;

function TSnippetEditDialog._ChipHint(const AKind: TSnippetVarKind;
  const AName: string): string;
var
  LKind: string;
begin
  case AKind of
    svkKnown:    LKind := 'known';
    svkDeferred: LKind := 'deferred (resolves verbatim)';
  else
    LKind := 'unknown';
  end;
  Result := Format('%s — %s. Click to insert {{%s}}.', [AName, LKind, AName]);
end;

procedure TSnippetEditDialog._ClearChips;
var
  LIndex: Integer;
begin
  for LIndex := pnlChips.ControlCount - 1 downto 0 do
    pnlChips.Controls[LIndex].Free;
end;

procedure TSnippetEditDialog._RebuildChips;
var
  LIndex: Integer;
  LChipLabel: TLabel;
begin
  _ClearChips;
  FChips := TSnippetEditModel.BuildChips(memCommand.Text);
  for LIndex := 0 to High(FChips) do
  begin
    LChipLabel := TLabel.Create(Self);
    LChipLabel.Parent := pnlChips;
    LChipLabel.AlignWithMargins := True;
    LChipLabel.Margins.SetBounds(3, 3, 3, 3);
    LChipLabel.Transparent := False;
    LChipLabel.AutoSize := True;
    LChipLabel.Color := _ChipColor(FChips[LIndex].Kind);
    LChipLabel.Font.Color := clWhite;
    LChipLabel.Caption := '  ' + FChips[LIndex].Name + '  ';
    LChipLabel.Cursor := crHandPoint;
    LChipLabel.ShowHint := True;
    LChipLabel.Hint := _ChipHint(FChips[LIndex].Kind, FChips[LIndex].Name);
    LChipLabel.Tag := LIndex;
    LChipLabel.OnClick := _ChipClick;
  end;
  // Keep the keyboard-selected chip in range after a rebuild (V.8).
  if FSelectedChip > High(FChips) then
    FSelectedChip := High(FChips);
  if Assigned(pnlChips) then
    pnlChips.Invalidate;
end;

procedure TSnippetEditDialog._MoveChipSelection(const ADelta: Integer);
begin
  if Length(FChips) = 0 then
  begin
    FSelectedChip := -1;
    Exit;
  end;
  if FSelectedChip < 0 then
    FSelectedChip := 0
  else
    FSelectedChip := FSelectedChip + ADelta;
  if FSelectedChip < 0 then
    FSelectedChip := 0
  else if FSelectedChip > High(FChips) then
    FSelectedChip := High(FChips);
end;

procedure TSnippetEditDialog._HandleChipsDlgCode(var Message: TMessage);
begin
  if Assigned(FOriginalChipsWP) then
    FOriginalChipsWP(Message);
  Message.Result := Message.Result or DLGC_WANTARROWS;
end;

procedure TSnippetEditDialog._HandleChipsFocus(var Message: TMessage);
begin
  if (Message.Msg = WM_SETFOCUS) and (FSelectedChip < 0)
    and (Length(FChips) > 0) then
    FSelectedChip := 0;
  if Assigned(FOriginalChipsWP) then
    FOriginalChipsWP(Message);
  pnlChips.Invalidate;
end;

function TSnippetEditDialog._HandleChipsKeyDown(var Message: TMessage): Boolean;
var
  LHandled: Boolean;
begin
  FKeyboardNavigation := True;
  LHandled := True;
  case Message.WParam of
    VK_LEFT:  _MoveChipSelection(-1);
    VK_RIGHT: _MoveChipSelection(1);
    VK_RETURN, VK_SPACE:
      if (FSelectedChip >= 0) and (FSelectedChip <= High(FChips)) then
        _ChipClick(pnlChips.Controls[FSelectedChip]);
  else
    LHandled := False;
  end;
  if LHandled then
  begin
    pnlChips.Invalidate;
    Message.Result := 0;
  end;
  Result := LHandled;
end;

procedure TSnippetEditDialog._HandleChipsPaint;
var
  LCanvas: TControlCanvas;
begin
  if (FSelectedChip < 0) or (FSelectedChip >= pnlChips.ControlCount) then
    Exit;
  if not TAccessibility.ShouldDrawFocusRing(pnlChips.Focused, FKeyboardNavigation) then
    Exit;
  LCanvas := TControlCanvas.Create;
  try
    LCanvas.Control := pnlChips;
    DrawAefosTerminalFocusRing(LCanvas, pnlChips.Controls[FSelectedChip].BoundsRect);
  finally
    LCanvas.Free;
  end;
end;

// V.8 (ESP-065 / ADR-065-03): thin dispatcher — each WM branch is a helper ≤ CCN 10.
procedure TSnippetEditDialog.ChipsSubclassWP(var Message: TMessage);
begin
  case Message.Msg of
    WM_GETDLGCODE:
      begin
        _HandleChipsDlgCode(Message);
        Exit;
      end;
    WM_LBUTTONDOWN:
      FKeyboardNavigation := False;
    WM_SETFOCUS, WM_KILLFOCUS:
      begin
        _HandleChipsFocus(Message);
        Exit;
      end;
    WM_KEYDOWN:
      if _HandleChipsKeyDown(Message) then
        Exit;
  end;
  if Assigned(FOriginalChipsWP) then
    FOriginalChipsWP(Message);
  if Message.Msg = WM_PAINT then
    _HandleChipsPaint;
end;

procedure TSnippetEditDialog._RefreshPreview;
var
  LCtx: TDictionary<string, string>;
begin
  LCtx := TSnippetEditModel.BuildPreviewContext(FLiveContext);
  try
    memPreview.Text := TMustacheEngine.Substitute(memCommand.Text, LCtx);
  finally
    LCtx.Free;
  end;
end;

procedure TSnippetEditDialog._ChipClick(Sender: TObject);
var
  LIndex: NativeInt; // matches TComponent.Tag (NativeInt) — avoids Win64 truncation (verify #104)
begin
  LIndex := TLabel(Sender).Tag;
  if (LIndex < 0) or (LIndex > High(FChips)) then
    Exit;
  memCommand.SelText := '{{' + FChips[LIndex].Name + '}}';
  memCommand.SetFocus;
end;

procedure TSnippetEditDialog.memCommandChange(Sender: TObject);
begin
  _RebuildChips;
  _RefreshPreview;
end;

function TSnippetEditDialog._SelectedScope: TSnippetScope;
begin
  if rbProject.Checked then
    Result := ssProject
  else if rbTeam.Checked then
    Result := ssTeam
  else
    Result := ssPersonal;
end;

procedure TSnippetEditDialog._SetScope(const AScope: TSnippetScope);
begin
  case AScope of
    ssProject: rbProject.Checked := True;
    ssTeam:    rbTeam.Checked := True;
  else
    rbPersonal.Checked := True;
  end;
end;

procedure TSnippetEditDialog.btnOKClick(Sender: TObject);
var
  LError: string;
begin
  LError := TSnippetEditModel.ValidateDraft(edtTitle.Text, memCommand.Text);
  if LError = '' then
    Exit;
  MessageDlg(LError, mtWarning, [mbOK], 0);
  ModalResult := mrNone; // keep the dialog open
  if Trim(edtTitle.Text) = '' then
    edtTitle.SetFocus
  else
    memCommand.SetFocus;
end;

class function TSnippetEditDialog.Execute(var ATitle, ACommand: string;
  var AScope: TSnippetScope; var ATags: TArray<string>;
  const AProjectActive, ATeamActive: Boolean;
  const ALiveContext: TDictionary<string, string>): Boolean;
var
  LDialog: TSnippetEditDialog;
begin
  Result := False;
  LDialog := TSnippetEditDialog.Create(nil);
  try
    LDialog.FLiveContext := ALiveContext;
    LDialog.edtTitle.Text := ATitle;
    LDialog.memCommand.Text := ACommand;
    LDialog.edtTags.Text := TSnippetEditModel.FormatTags(ATags);

    LDialog.rbProject.Enabled := AProjectActive;
    LDialog.rbTeam.Enabled := ATeamActive;
    LDialog._SetScope(AScope);

    LDialog._RebuildChips;
    LDialog._RefreshPreview;

    if LDialog.ShowModal = mrOk then
    begin
      ATitle := LDialog.edtTitle.Text;
      ACommand := LDialog.memCommand.Text;
      AScope := LDialog._SelectedScope;
      ATags := TSnippetEditModel.ParseTags(LDialog.edtTags.Text);
      Result := True;
    end;
  finally
    LDialog.Free;
  end;
end;

end.



