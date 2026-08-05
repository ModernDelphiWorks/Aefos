unit Aefos.OTA.Terminal.UI.CommandPaletteView;

{
  V.5 command-palette overlay (ESP-062 / ADR-062-03).

  A borderless modal popup, built entirely in code like the Action Center's
  TPlaceholderPromptDialog, themed through the proven
  ApplyAefosTerminalIDETheme (RegisterFormClass + SetWindowTheme + name-based dark
  detection) combo and colored from Aefos.OTA.Terminal.Core.VisualTokens (BR4). It renders a
  search edit over an owner-drawn, keyboard-navigable result list and reports
  the chosen command's dispatch back to the host (the DockForm runs it after the
  overlay closes, BR2). The command list and dispatch references are supplied by
  the IDE layer; the pure filtering/sorting lives in Aefos.OTA.Terminal.Core.CommandPalette.

  [[ide-theming-pattern]] [[mobaxterm-ux-reference]]
}

interface

uses
  System.Classes,
  System.Types,
  Vcl.Forms,
  Vcl.Graphics,
  Vcl.StdCtrls,
  Vcl.Controls,
  Aefos.OTA.Terminal.UI.ThemedForm,
  Aefos.OTA.Terminal.Core.CommandPalette;

type
  /// <summary>Live dispatch for a palette command — calls the existing handler
  /// (profile launch, action run, snippet insert, built-in). Attached in the
  /// IDE layer so the pure model stays VCL-free (A4 / BR2).</summary>
  TPaletteDispatch = reference to procedure;

  /// <summary>Pairs a pure <see cref="TPaletteCommand"/> with its live dispatch.
  /// The overlay displays the command data and returns the dispatch.</summary>
  TPaletteEntry = record
    Command: TPaletteCommand;
    Dispatch: TPaletteDispatch;
  end;

  /// <summary>
  ///   Borderless modal command palette. Use the class method
  ///   <see cref="Execute"/>: it shows the overlay, lets the user fuzzy-filter
  ///   and pick a command, and returns the chosen dispatch. The caller runs the
  ///   dispatch after the overlay has closed.
  /// </summary>
  TCommandPaletteView = class(TAefosTerminalThemedForm)
  private
    FSearch: TEdit;
    FList: TListBox;
    FEntries: TArray<TPaletteEntry>;
    FFiltered: TArray<TPaletteCommand>;
    FChosen: TPaletteDispatch;
    FReady: Boolean;
    FListBg: TColor;
    FListFg: TColor;
    FDimFg: TColor;
    FAccent: TColor;
    FSelFg: TColor;
    // V.8 (ESP-065 / ADR-065-03): the focus ring is drawn on the selected row
    // only while the user is navigating by keyboard. The palette opens via
    // Ctrl+P, so it starts in keyboard mode; a mouse-down on the list clears it.
    FKeyboardNavigation: Boolean;
    procedure _Build;
    function _Commands: TArray<TPaletteCommand>;
    procedure _Refilter;
    procedure _MoveSelection(const ADelta: Integer);
    procedure _ChooseCurrent;
    function _CategoryColor(const ACategory: TPaletteCategory): TColor;
    procedure _SearchChange(Sender: TObject);
    procedure _FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure _ListDblClick(Sender: TObject);
    procedure _ListDrawItem(AControl: TWinControl; AIndex: Integer;
      ARect: TRect; AState: TOwnerDrawState);
    procedure _ListMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure _FormDeactivate(Sender: TObject);
  protected
    procedure DoShow; override;
    /// <summary>Themes the palette and derives the owner-drawn list colors
    /// (ESP-077 / ADR-077-02). Overrides the base hook because the form is
    /// code-built and needs the post-construction list-color derivation; called
    /// explicitly after <c>_Build</c> so controls exist first (BR3).</summary>
    procedure _ApplyTheme; override;
  public
    constructor Create(AOwner: TComponent; const AEntries: TArray<TPaletteEntry>);
      reintroduce;
    /// <summary>
    ///   Shows the palette modal over <c>AOwner</c>. Returns <c>True</c> and the
    ///   chosen command's dispatch when the user runs a command (Enter /
    ///   double-click); returns <c>False</c> on Esc / focus loss / empty list.
    /// </summary>
    class function Execute(AOwner: TComponent;
      const AEntries: TArray<TPaletteEntry>;
      out ADispatch: TPaletteDispatch): Boolean;
  end;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  Aefos.OTA.Terminal.Core.VisualTokens,
  Aefos.OTA.Terminal.Core.Accessibility,
  Aefos.OTA.Terminal.UI.IDEThemes;

const
  PALETTE_WIDTH       = 560;
  PALETTE_SEARCH_H    = 28;
  PALETTE_ROW_H       = 42;
  PALETTE_MAX_ROWS    = 10;
  PALETTE_PAD         = 8;
  PALETTE_BADGE_W     = 78;

{ TCommandPaletteView }

constructor TCommandPaletteView.Create(AOwner: TComponent;
  const AEntries: TArray<TPaletteEntry>);
begin
  inherited CreateNew(AOwner);
  FEntries := AEntries;
  Caption := 'Command Palette';
  BorderStyle := bsNone;
  if Assigned(AOwner) and (AOwner is TCustomForm) then
    Position := poOwnerFormCenter
  else
    Position := poScreenCenter;
  KeyPreview := True;
  // Opened by the Ctrl+P shortcut, so the first interaction is keyboard (V.8).
  FKeyboardNavigation := True;
  OnKeyDown := _FormKeyDown;
  OnDeactivate := _FormDeactivate;
  _Build;
  // Code-built form: theme after controls exist via the base hook (ESP-077 /
  // ADR-077-02). CreateNew bypasses the base constructor, so call explicitly.
  _ApplyTheme;
  _Refilter;
end;

procedure TCommandPaletteView._Build;
var
  LVisibleRows: Integer;
begin
  LVisibleRows := Length(FEntries);
  if LVisibleRows > PALETTE_MAX_ROWS then
    LVisibleRows := PALETTE_MAX_ROWS;
  if LVisibleRows < 1 then
    LVisibleRows := 1;

  ClientWidth := PALETTE_WIDTH;
  ClientHeight := PALETTE_PAD * 3 + PALETTE_SEARCH_H + LVisibleRows * PALETTE_ROW_H;

  FSearch := TEdit.Create(Self);
  FSearch.Parent := Self;
  FSearch.SetBounds(PALETTE_PAD, PALETTE_PAD,
    PALETTE_WIDTH - 2 * PALETTE_PAD, PALETTE_SEARCH_H);
  FSearch.TextHint := 'Type to search profiles, actions, snippets, commands…';
  FSearch.OnChange := _SearchChange;

  FList := TListBox.Create(Self);
  FList.Parent := Self;
  FList.SetBounds(PALETTE_PAD, PALETTE_PAD * 2 + PALETTE_SEARCH_H,
    PALETTE_WIDTH - 2 * PALETTE_PAD, LVisibleRows * PALETTE_ROW_H);
  FList.Style := lbOwnerDrawFixed;
  FList.ItemHeight := PALETTE_ROW_H;
  FList.BorderStyle := bsNone;
  FList.OnDrawItem := _ListDrawItem;
  FList.OnDblClick := _ListDblClick;
  FList.OnMouseDown := _ListMouseDown;
end;

procedure TCommandPaletteView._ApplyTheme;
begin
  // Reuse the proven standalone-form theming combo via the base hook
  // (ADR-062-03 / ESP-077). The default body applies ApplyAefosTerminalIDETheme.
  inherited _ApplyTheme;

  FAccent := TVisualTokens.Accent;
  FSelFg := clWhite;
  // ApplyAefosTerminalIDETheme does not patch TListBox; derive list colors from the
  // form background it resolved so dark/light both read correctly (BR4).
  if TVisualTokens.IsLightColor(Color) then
  begin
    FListBg := clWindow;
    FListFg := clWindowText;
    FDimFg := TColor($707070);
  end
  else
  begin
    FListBg := TVisualTokens.Shade(Color, 6);
    FListFg := TColor($D4D4D4);
    FDimFg := TColor($9A9A9A);
  end;
  FList.Color := FListBg;
  FList.Font.Color := FListFg;
end;

function TCommandPaletteView._CategoryColor(
  const ACategory: TPaletteCategory): TColor;
begin
  // Category accents drawn from VisualTokens (BR4 — no new color system).
  case ACategory of
    pcProfile: Result := TVisualTokens.AnsiColor(12); // bright blue
    pcAction:  Result := TVisualTokens.Accent;        // Embarcadero orange
    pcSnippet: Result := TVisualTokens.AnsiColor(10); // bright green
    pcHistory: Result := TVisualTokens.AnsiColor(14); // bright cyan (ESP-078)
  else
    Result := FDimFg;                                 // built-in
  end;
end;

function TCommandPaletteView._Commands: TArray<TPaletteCommand>;
var
  LIndex: Integer;
begin
  SetLength(Result, Length(FEntries));
  for LIndex := 0 to High(FEntries) do
    Result[LIndex] := FEntries[LIndex].Command;
end;

procedure TCommandPaletteView._Refilter;
var
  LIndex: Integer;
begin
  FFiltered := TCommandPaletteFilter.Filter(_Commands, FSearch.Text);
  // lbOwnerDrawFixed draws by index but takes its row count from Items; the
  // string is unused (the row is painted from FFiltered).
  FList.Items.BeginUpdate;
  try
    FList.Items.Clear;
    for LIndex := 0 to High(FFiltered) do
      FList.Items.Add(FFiltered[LIndex].Title);
  finally
    FList.Items.EndUpdate;
  end;
  if Length(FFiltered) > 0 then
    FList.ItemIndex := 0
  else
    FList.ItemIndex := -1;
  FList.Invalidate;
end;

procedure TCommandPaletteView._SearchChange(Sender: TObject);
begin
  _Refilter;
end;

procedure TCommandPaletteView._MoveSelection(const ADelta: Integer);
var
  LNext: Integer;
begin
  if Length(FFiltered) = 0 then
    Exit;
  LNext := FList.ItemIndex + ADelta;
  if LNext < 0 then
    LNext := 0
  else if LNext > High(FFiltered) then
    LNext := High(FFiltered);
  FList.ItemIndex := LNext;
end;

procedure TCommandPaletteView._ChooseCurrent;
var
  LIndex: Integer;
  LId: string;
  LEntry: TPaletteEntry;
begin
  LIndex := FList.ItemIndex;
  if (LIndex < 0) or (LIndex > High(FFiltered)) then
    Exit;
  LId := FFiltered[LIndex].Id;
  for LEntry in FEntries do
    if LEntry.Command.Id = LId then
    begin
      FChosen := LEntry.Dispatch;
      Break;
    end;
  ModalResult := mrOk;
end;

procedure TCommandPaletteView._FormKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  // Any key inside the palette is keyboard navigation → enable the focus ring.
  FKeyboardNavigation := True;
  FList.Invalidate;
  case Key of
    VK_DOWN:   begin _MoveSelection(1);  Key := 0; end;
    VK_UP:     begin _MoveSelection(-1); Key := 0; end;
    VK_NEXT:   begin _MoveSelection(PALETTE_MAX_ROWS - 1); Key := 0; end;
    VK_PRIOR:  begin _MoveSelection(-(PALETTE_MAX_ROWS - 1)); Key := 0; end;
    VK_RETURN: begin _ChooseCurrent; Key := 0; end;
    VK_ESCAPE: begin ModalResult := mrCancel; Key := 0; end;
  end;
end;

procedure TCommandPaletteView._ListDblClick(Sender: TObject);
begin
  _ChooseCurrent;
end;

procedure TCommandPaletteView._ListMouseDown(Sender: TObject;
  Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  // Mouse interaction clears keyboard mode so the ring does not show on a
  // pointer-driven selection (ADR-065-03 / ShouldDrawFocusRing).
  FKeyboardNavigation := False;
  FList.Invalidate;
end;

procedure TCommandPaletteView._ListDrawItem(AControl: TWinControl;
  AIndex: Integer; ARect: TRect; AState: TOwnerDrawState);
var
  LCanvas: TCanvas;
  LCmd: TPaletteCommand;
  LSelected: Boolean;
  LTextLeft: Integer;
  LBadge: string;
begin
  if (AIndex < 0) or (AIndex > High(FFiltered)) then
    Exit;
  LCanvas := FList.Canvas;
  LCmd := FFiltered[AIndex];
  LSelected := odSelected in AState;

  if LSelected then
    LCanvas.Brush.Color := FAccent
  else
    LCanvas.Brush.Color := FListBg;
  LCanvas.FillRect(ARect);

  LTextLeft := ARect.Left + PALETTE_PAD;

  // Category badge (right-aligned), in its accent unless the row is selected.
  LBadge := TCommandPaletteFilter.CategoryLabel(LCmd.Category);
  LCanvas.Brush.Style := bsClear;
  LCanvas.Font.Style := [fsBold];
  if LSelected then
    LCanvas.Font.Color := FSelFg
  else
    LCanvas.Font.Color := _CategoryColor(LCmd.Category);
  LCanvas.TextOut(ARect.Right - PALETTE_BADGE_W, ARect.Top + 6, LBadge);

  // Title (top line).
  LCanvas.Font.Style := [];
  if LSelected then
    LCanvas.Font.Color := FSelFg
  else
    LCanvas.Font.Color := FListFg;
  LCanvas.TextOut(LTextLeft, ARect.Top + 4, LCmd.Title);

  // Subtitle (bottom line, dimmed).
  if LCmd.Subtitle <> '' then
  begin
    if LSelected then
      LCanvas.Font.Color := FSelFg
    else
      LCanvas.Font.Color := FDimFg;
    LCanvas.TextOut(LTextLeft, ARect.Top + 22, LCmd.Subtitle);
  end;
  LCanvas.Brush.Style := bsSolid;

  // V.8 keyboard-focus ring on the selected row (ESP-065 / ADR-065-03). The
  // selected row is the focused element; the ring shows only under keyboard nav.
  if TAccessibility.ShouldDrawFocusRing(LSelected, FKeyboardNavigation) then
    DrawAefosTerminalFocusRing(LCanvas, ARect);
end;

procedure TCommandPaletteView._FormDeactivate(Sender: TObject);
begin
  // Close on focus loss once fully shown (ADR-062-03).
  if FReady then
    ModalResult := mrCancel;
end;

procedure TCommandPaletteView.DoShow;
begin
  inherited;
  FReady := True;
  if FSearch.CanFocus then
    FSearch.SetFocus;
end;

class function TCommandPaletteView.Execute(AOwner: TComponent;
  const AEntries: TArray<TPaletteEntry>;
  out ADispatch: TPaletteDispatch): Boolean;
var
  LView: TCommandPaletteView;
begin
  ADispatch := nil;
  LView := TCommandPaletteView.Create(AOwner, AEntries);
  try
    Result := (LView.ShowModal = mrOk) and Assigned(LView.FChosen);
    if Result then
      ADispatch := LView.FChosen;
  finally
    LView.Free;
  end;
end;

end.



