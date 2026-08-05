unit Aefos.OTA.Terminal.UI.WelcomePane;

{
  V.1 welcome / "new tab" landing pane (ESP-058 / ADR-058-01).

  A TPanel-descended pane parented into a TTabSheet with Align := alClient,
  following the same parenting pattern TAefosTerminalTerminalView uses. It renders a
  greeting header plus one launch card per configured shell profile (BR3). The
  card view-models and the greeting come from the pure Aefos.OTA.Terminal.Core.WelcomeModel
  helpers; all colors come from Aefos.OTA.Terminal.Core.VisualTokens / TVisualSurfaces so the
  pane tracks the locked "Delphi IDE" theme (BR2/BR4).

  Activating a card raises OnLaunchProfile with the chosen profile index; the
  dock form replaces this pane with a live terminal for that profile through the
  existing _AddTerminalView path (BR1). The pane never spawns a shell itself.

  Paint/layout is VCL-structural -> coverage-exempt (BR7); validated live by the
  operator (BR9, visual-validation-protocol.md §V.1).
}

interface

uses
  System.Classes,
  Vcl.Controls,
  Vcl.ExtCtrls,
  Vcl.StdCtrls,
  Vcl.Themes,
  System.Generics.Collections,
  Aefos.OTA.Terminal.Core.Profiles;

type
  /// <summary>Raised when the operator activates a profile launch card.
  /// <c>AProfileIndex</c> indexes <c>TProfileManager.Profiles</c>.</summary>
  TWelcomeLaunchEvent = procedure(Sender: TObject; const AProfileIndex: Integer) of object;

  /// <summary>
  ///   In-tab landing pane: greeting + one launch card per configured profile.
  ///   Host-less tab content (the first non-terminal tab content in Aefos.OTA.Terminal).
  /// </summary>
  TWelcomePane = class(TPanel)
  private
    FOnLaunchProfile: TWelcomeLaunchEvent;
    FLogo: TImage;
    FHeader: TLabel;
    FSubtitle: TLabel;
    FCardHost: TPanel;
    // V.8 (ESP-065 / ADR-065-03): the launch cards are keyboard-focusable; the
    // focus ring shows only while navigating by keyboard. Set from the card's
    // own KeyDown/MouseDown overrides (TWelcomeCardPanel, same unit).
    FKeyboardNavigation: Boolean;
    procedure _CardClick(Sender: TObject);
    procedure _ClearCards;
    procedure _FocusSiblingCard(const ACurrent: TWinControl; const ADelta: Integer);
    function _ResolveStyle: TCustomStyleServices;
    // 2026-06-09: centered brand mark + centered greeting/cards (chat-style
    // empty-state). _Relayout recomputes positions on every Resize.
    procedure _LoadLogo;
    procedure _Relayout;
  protected
    procedure Resize; override;
  public
    constructor Create(AOwner: TComponent); override;
    /// <summary>Rebuilds the greeting + cards from the live profile list (BR3).</summary>
    procedure BuildFromProfiles(const AProfiles: TObjectList<TShellProfile>);
    property OnLaunchProfile: TWelcomeLaunchEvent read FOnLaunchProfile write FOnLaunchProfile;
  end;

implementation

uses
  Winapi.Windows,
  Winapi.Messages,
  Vcl.Graphics,
  Vcl.Imaging.pngimage,
  Aefos.OTA.Terminal.Core.VisualTokens,
  Aefos.OTA.Terminal.Core.Accessibility,
  Aefos.OTA.Terminal.UI.IDEThemes,
  Aefos.OTA.Terminal.UI.WelcomeAssets,
  Aefos.OTA.Terminal.Core.WelcomeModel;

type
  /// <summary>
  ///   Keyboard-focusable launch card (V.8 / ESP-065 / ADR-065-03). A plain
  ///   TPanel that takes Tab focus, paints the uniform Aefos.OTA.Terminal focus ring when
  ///   keyboard-focused, activates on Enter/Space, and moves focus to the
  ///   adjacent card on Up/Down. Mouse interaction clears keyboard mode so the
  ///   ring stays off for pointer-driven launches.
  /// </summary>
  TWelcomeCardPanel = class(TPanel)
  private
    FOwnerPane: TWelcomePane;
  protected
    procedure Paint; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure DoEnter; override;
    procedure DoExit; override;
    procedure WMGetDlgCode(var Message: TWMGetDlgCode); message WM_GETDLGCODE;
  end;

procedure TWelcomeCardPanel.Paint;
begin
  inherited;
  if Assigned(FOwnerPane) and
     TAccessibility.ShouldDrawFocusRing(Focused, FOwnerPane.FKeyboardNavigation) then
    DrawAefosTerminalFocusRing(Canvas, ClientRect);
end;

procedure TWelcomeCardPanel.KeyDown(var Key: Word; Shift: TShiftState);
begin
  if Assigned(FOwnerPane) then
    FOwnerPane.FKeyboardNavigation := True;
  case Key of
    VK_RETURN, VK_SPACE:
      begin
        if Assigned(FOwnerPane) then
          FOwnerPane._CardClick(Self);
        Key := 0;
      end;
    VK_DOWN:
      begin
        if Assigned(FOwnerPane) then
          FOwnerPane._FocusSiblingCard(Self, 1);
        Key := 0;
      end;
    VK_UP:
      begin
        if Assigned(FOwnerPane) then
          FOwnerPane._FocusSiblingCard(Self, -1);
        Key := 0;
      end;
  end;
  inherited;
end;

procedure TWelcomeCardPanel.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  if Assigned(FOwnerPane) then
    FOwnerPane.FKeyboardNavigation := False;
  inherited;
end;

procedure TWelcomeCardPanel.DoEnter;
begin
  inherited;
  Invalidate;
end;

procedure TWelcomeCardPanel.DoExit;
begin
  inherited;
  Invalidate;
end;

procedure TWelcomeCardPanel.WMGetDlgCode(var Message: TWMGetDlgCode);
begin
  inherited;
  // Receive arrow keys for inter-card traversal; Tab still navigates natively.
  Message.Result := Message.Result or DLGC_WANTARROWS;
end;

const
  CARD_LEFT    = 28;
  CARD_WIDTH   = 380;
  CARD_HEIGHT  = 58;
  CARD_GAP     = 12;
  CARD_TOP0    = 16;
  DOT_SIZE     = 14;
  SUMMARY_MAX  = 64;
  LOGO_DISP    = 104;   // on-screen logo size (px); source PNG is 128
  LOGO_TOP     = 24;

constructor TWelcomePane.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  BevelOuter := bvNone;
  Padding.SetBounds(0, 0, 0, 0);
  ParentBackground := False;

  // Centered brand mark at the top (mirrors the chat empty-state). Nil-safe:
  // _LoadLogo leaves the picture empty if the embedded PNG fails to decode, so
  // the pane still renders greeting + cards without it.
  FLogo := TImage.Create(Self);
  FLogo.Parent := Self;
  FLogo.Stretch := True;
  FLogo.Proportional := True;
  FLogo.Transparent := True;
  FLogo.Center := True;
  _LoadLogo;

  FHeader := TLabel.Create(Self);
  FHeader.Parent := Self;
  FHeader.AutoSize := False;
  FHeader.Alignment := taCenter;
  FHeader.Font.Name := 'Segoe UI';
  FHeader.Font.Size := 18;
  FHeader.Font.Style := [fsBold];
  FHeader.Transparent := True;

  FSubtitle := TLabel.Create(Self);
  FSubtitle.Parent := Self;
  FSubtitle.AutoSize := False;
  FSubtitle.Alignment := taCenter;
  FSubtitle.Font.Name := 'Segoe UI';
  FSubtitle.Font.Size := 10;
  FSubtitle.Transparent := True;
  FSubtitle.Caption := 'Pick a shell to start a new terminal in this tab.';

  FCardHost := TPanel.Create(Self);
  FCardHost.Parent := Self;
  FCardHost.Align := alClient;
  FCardHost.AlignWithMargins := True;
  FCardHost.Margins.SetBounds(0, 220, 0, 0);
  FCardHost.BevelOuter := bvNone;
  FCardHost.ParentBackground := False;
end;

function TWelcomePane._ResolveStyle: TCustomStyleServices;
begin
  // The IDE keeps the active VCL style in sync with its own theme, so the
  // global StyleServices is the locked "Delphi IDE" surface at paint time
  // (BR4). TVisualSurfaces tolerates nil with a clBtnFace fallback.
  Result := StyleServices;
end;

procedure TWelcomePane._ClearCards;
var
  LIndex: Integer;
begin
  for LIndex := FCardHost.ControlCount - 1 downto 0 do
    FCardHost.Controls[LIndex].Free;
end;

procedure TWelcomePane.BuildFromProfiles(const AProfiles: TObjectList<TShellProfile>);
var
  LStyle: TCustomStyleServices;
  LPaneColor, LCardColor, LTextColor, LDimColor: TColor;
  LCards: TArray<TWelcomeCard>;
  LIndex: Integer;
  LCard: TWelcomeCardPanel;
  LDot: TShape;
  LName, LSummary, LStart: TLabel;
  LTop: Integer;
  LSummaryText: string;
begin
  LStyle := _ResolveStyle;
  LPaneColor := TVisualSurfaces.ChromeBackground(LStyle);
  LCardColor := TVisualSurfaces.PanelSurface(LStyle);
  if TVisualTokens.IsLightColor(LPaneColor) then
  begin
    LTextColor := clBlack;
    LDimColor := TVisualTokens.Shade(clBlack, 40);
  end
  else
  begin
    LTextColor := clWhite;
    LDimColor := TVisualTokens.Shade(clWhite, -35);
  end;

  Color := LPaneColor;
  FCardHost.Color := LPaneColor;
  FHeader.Caption := 'Welcome to Aefos Terminal';
  FHeader.Font.Color := LTextColor;
  FSubtitle.Font.Color := LDimColor;

  _ClearCards;

  LCards := TWelcomeModel.BuildCards(AProfiles);
  LTop := CARD_TOP0;
  for LIndex := 0 to High(LCards) do
  begin
    LCard := TWelcomeCardPanel.Create(Self);
    LCard.FOwnerPane := Self;
    LCard.Parent := FCardHost;
    LCard.BevelOuter := bvNone;
    LCard.ParentBackground := False;
    LCard.Color := LCardColor;
    LCard.SetBounds(CARD_LEFT, LTop, CARD_WIDTH, CARD_HEIGHT);
    LCard.Tag := LCards[LIndex].ProfileIndex;
    LCard.Cursor := crHandPoint;
    // V.8: keyboard-focusable so Tab/arrows reach the card and the focus ring
    // can render (ESP-065 / ADR-065-03).
    LCard.TabStop := True;
    LCard.OnClick := _CardClick;

    LDot := TShape.Create(LCard);
    LDot.Parent := LCard;
    LDot.Shape := stCircle;
    LDot.Pen.Style := psClear;
    LDot.Brush.Color := LCards[LIndex].DotColor;
    LDot.SetBounds(16, (CARD_HEIGHT - DOT_SIZE) div 2, DOT_SIZE, DOT_SIZE);
    // TShape does not publish OnClick; the dot is decorative. The card panel
    // and its labels carry the activation handler.

    LName := TLabel.Create(LCard);
    LName.Parent := LCard;
    LName.SetBounds(44, 10, CARD_WIDTH - 120, 20);
    LName.Caption := LCards[LIndex].ProfileName;
    LName.Font.Name := 'Segoe UI';
    LName.Font.Size := 11;
    LName.Font.Style := [fsBold];
    LName.Font.Color := LTextColor;
    LName.Transparent := True;
    LName.Tag := LCards[LIndex].ProfileIndex;
    LName.OnClick := _CardClick;

    LSummaryText := LCards[LIndex].ShellSummary;
    if Length(LSummaryText) > SUMMARY_MAX then
      LSummaryText := Copy(LSummaryText, 1, SUMMARY_MAX - 1) + '…';

    LSummary := TLabel.Create(LCard);
    LSummary.Parent := LCard;
    LSummary.SetBounds(44, 32, CARD_WIDTH - 120, 18);
    LSummary.Caption := LSummaryText;
    LSummary.Font.Name := 'Segoe UI';
    LSummary.Font.Size := 9;
    LSummary.Font.Color := LDimColor;
    LSummary.Transparent := True;
    LSummary.Tag := LCards[LIndex].ProfileIndex;
    LSummary.OnClick := _CardClick;

    LStart := TLabel.Create(LCard);
    LStart.Parent := LCard;
    LStart.SetBounds(CARD_WIDTH - 70, (CARD_HEIGHT - 18) div 2, 60, 18);
    LStart.Caption := 'Start ▸';
    LStart.Font.Name := 'Segoe UI';
    LStart.Font.Size := 10;
    LStart.Font.Style := [fsBold];
    LStart.Font.Color := TVisualTokens.Accent;
    LStart.Transparent := True;
    LStart.Tag := LCards[LIndex].ProfileIndex;
    LStart.OnClick := _CardClick;

    Inc(LTop, CARD_HEIGHT + CARD_GAP);
  end;
  _Relayout;
end;

procedure TWelcomePane._CardClick(Sender: TObject);
begin
  if Assigned(FOnLaunchProfile) and (Sender is TControl) then
    FOnLaunchProfile(Self, TControl(Sender).Tag); // NOSONAR — Win32 target: Tag (NativeInt) == Integer; no truncation
end;

procedure TWelcomePane._FocusSiblingCard(const ACurrent: TWinControl;
  const ADelta: Integer);
var
  LCards: TArray<TWinControl>;
  LIndex, LCurrent, LNext: Integer;
begin
  // Collect the card panels in layout order and move focus to the neighbor in
  // ADelta direction (V.8 arrow traversal, ESP-065 / ADR-065-03).
  SetLength(LCards, 0);
  for LIndex := 0 to FCardHost.ControlCount - 1 do
    if FCardHost.Controls[LIndex] is TWelcomeCardPanel then
    begin
      SetLength(LCards, Length(LCards) + 1);
      LCards[High(LCards)] := TWinControl(FCardHost.Controls[LIndex]);
    end;

  LCurrent := -1;
  for LIndex := 0 to High(LCards) do
    if LCards[LIndex] = ACurrent then
    begin
      LCurrent := LIndex;
      Break;
    end;
  if LCurrent < 0 then
    Exit;

  LNext := LCurrent + ADelta;
  if (LNext >= 0) and (LNext <= High(LCards)) and LCards[LNext].CanFocus then
    LCards[LNext].SetFocus;
end;

procedure TWelcomePane._LoadLogo;
var
  LPng: TPngImage;
begin
  if not Assigned(FLogo) then
    Exit;
  if TryLoadWelcomeLogo(LPng) then
  try
    FLogo.Picture.Assign(LPng);
  finally
    LPng.Free;
  end;
end;

procedure TWelcomePane._Relayout;
var
  LW, LCardX, LIndex: Integer;
begin
  LW := ClientWidth;
  if LW <= 0 then
    Exit;
  if Assigned(FLogo) then
    FLogo.SetBounds((LW - LOGO_DISP) div 2, LOGO_TOP, LOGO_DISP, LOGO_DISP);
  if Assigned(FHeader) then
    FHeader.SetBounds(0, LOGO_TOP + LOGO_DISP + 10, LW, 34);
  if Assigned(FSubtitle) then
    FSubtitle.SetBounds(0, LOGO_TOP + LOGO_DISP + 48, LW, 20);
  // Center the launch-card column inside the host (recomputed every Resize).
  if Assigned(FCardHost) then
  begin
    LCardX := (FCardHost.ClientWidth - CARD_WIDTH) div 2;
    if LCardX < CARD_LEFT then
      LCardX := CARD_LEFT;
    for LIndex := 0 to FCardHost.ControlCount - 1 do
      if FCardHost.Controls[LIndex] is TWelcomeCardPanel then
        FCardHost.Controls[LIndex].Left := LCardX;
  end;
end;

procedure TWelcomePane.Resize;
begin
  inherited;
  _Relayout;
end;

end.




