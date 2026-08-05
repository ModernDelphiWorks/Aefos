unit Aefos.OTA.Terminal.UI.ActionsSidebar;

{
  Actions execution sidebar, extracted from the TAefosTerminalDockForm god-form as a
  focused helper of the DockForm split (audit / form decomposition).

  Owns the left-host's *actions* panel (pnlActionsSidebar) and everything inside it: the
  header + collapse chevron, the filter box, the owner-drawn run-only list and its
  right-click "Run on terminal" menu, plus the row model (FActionRows). On Rebuild it
  loads the saved-action catalog (TActionStore) and paints / filters / runs rows from it.

  It does NOT own the shared LEFT host, the snippets sidebar, or the inter-sidebar
  splitter — those stay on the form, and the form's _ArrangeLeftSidebars coordinator
  owns ALL left-host geometry (the Align/Top/Height/Visible of Panel plus the splitter).
  The helper drives only data + paint; whenever its row set changes (toggle / filter) it
  asks the coordinator to re-arrange through the OnArrange callback, which fits the panel
  to the helper's ContentFitHeight when both sidebars are open. Running an action, the
  dark-theme query and the re-arrange are all injected callbacks, so the helper keeps no
  back-reference to the form.

  Teardown: every control and the row menu is created with the OWNER FORM as Owner, so
  the form's destruction frees them exactly as it did before this extraction — the helper
  owns no VCL handles, and its destructor frees nothing. Zero change to the form's
  teardown sequence (the form still frees the helper instance itself in Destroy).
}

interface

uses
  Winapi.Windows,
  System.Classes,
  System.SysUtils,
  System.Types,
  Vcl.Graphics,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.StdCtrls,
  Vcl.Buttons,
  Vcl.ExtCtrls,
  Vcl.Menus,
  Aefos.OTA.Terminal.Core.Snippets;

type
  /// <summary>
  ///   One row in a left-sidebar list (ESP-060): either a scope-group header or an
  ///   entry. Shared by the snippets sidebar (kept in the form) and the actions sidebar
  ///   (this helper) — both keep their model parallel to the list items so owner-draw
  ///   and hit-testing map a list index straight to its row. Homed in this unit (the
  ///   single declaration both reference) because the actions helper cannot pull it from
  ///   the DockForm interface without a unit cycle: the form already uses this unit.
  /// </summary>
  TSnippetSidebarRow = record
    IsHeader: Boolean;
    Scope: TSnippetScope;
    Snippet: TSnippet;
    IsAction: Boolean;    // ESP-060+: an Actions-group row, run via the run-action callback
    ActionId: string;
    ActionName: string;
  end;

  /// <summary>
  ///   The terminal's run-only "Actions" sidebar. Builds its panel into the supplied
  ///   left host in the constructor and exposes a small surface to the form's geometry
  ///   coordinator (Panel / Wanted / ContentFitHeight) plus the three user verbs
  ///   (Toggle / Rebuild / ApplyTheme).
  /// </summary>
  TActionsSidebar = class
  private
    FOwnerForm: TCustomForm;
    FHost: TWinControl;
    FOnRunAction: TProc<string>;
    FOnArrange: TProc;
    FIsDark: TFunc<Boolean>;
    // Actions panel + its children — ALL owned by FOwnerForm, so the form frees them.
    pnlActionsSidebar: TPanel;
    FActionsHeader: TPanel;
    FActionsChevron: TSpeedButton;
    FActionsFilter: TEdit;
    FActionsList: TListBox;
    FActionRowMenu: TPopupMenu;
    FActionRows: TArray<TSnippetSidebarRow>;
    FActionMenuRow: Integer;
    FWanted: Boolean;
    procedure _OnChevronClick(Sender: TObject);
    procedure _ActionsFilterChange(Sender: TObject);
    procedure _ActionsListDrawItem(Control: TWinControl; Index: Integer;
      Rect: TRect; State: TOwnerDrawState);
    procedure _ActionsListMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure _ActionsListDblClick(Sender: TObject);
    procedure _ActionsListKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure _ActionRunMenuClick(Sender: TObject);
  public
    // Builds the actions panel + controls into AHost, each owned by AOwnerForm. The
    // callbacks: AOnRunAction runs a saved action by id, AOnArrange re-runs the form's
    // left-sidebar geometry coordinator, AIsDark queries the IDE dark theme. None is
    // stored as a form back-reference beyond these closures.
    constructor Create(const AOwnerForm: TCustomForm; const AHost: TWinControl;
      const AOnRunAction: TProc<string>; const AOnArrange: TProc;
      const AIsDark: TFunc<Boolean>);
    destructor Destroy; override;
    // The actions panel; the form's _ArrangeLeftSidebars coordinator drives its
    // Align/Top/Height/Visible.
    function Panel: TPanel;
    // Content height the coordinator fits the panel to when both sidebars are open
    // (header + filter + rows, min 90). The host-relative clamp stays in the coordinator.
    function ContentFitHeight: Integer;
    property Wanted: Boolean read FWanted write FWanted;
    // Flip wanted, re-arrange, and on open theme + rebuild + focus the filter.
    procedure Toggle;
    // Reload the action catalog into the list, then ask the coordinator to re-fit.
    procedure Rebuild;
    // Re-tint the panel + controls for the active IDE theme.
    procedure ApplyTheme;
  end;

implementation

uses
  Aefos.OTA.Terminal.Core.ActionStore,
  Aefos.OTA.Terminal.Core.Actions;

{ TActionsSidebar }

constructor TActionsSidebar.Create(const AOwnerForm: TCustomForm;
  const AHost: TWinControl; const AOnRunAction: TProc<string>;
  const AOnArrange: TProc; const AIsDark: TFunc<Boolean>);
var
  LRun: TMenuItem;
begin
  inherited Create;
  FOwnerForm := AOwnerForm;
  FHost := AHost;
  FOnRunAction := AOnRunAction;
  FOnArrange := AOnArrange;
  FIsDark := AIsDark;
  FActionMenuRow := -1;

  // Actions panel: sits on top of the shared left host (alTop), with the snippets
  // panel filling below it. Built entirely at runtime (no DFM entry). The coordinator
  // (_ArrangeLeftSidebars on the form) owns its final Align/Top/Height/Visible.
  pnlActionsSidebar := TPanel.Create(FOwnerForm);
  pnlActionsSidebar.Parent := FHost;
  pnlActionsSidebar.Align := alTop;
  pnlActionsSidebar.Height := 240;
  pnlActionsSidebar.BevelOuter := bvNone;
  pnlActionsSidebar.ParentBackground := False;
  pnlActionsSidebar.ParentColor := False;
  pnlActionsSidebar.DoubleBuffered := True;
  pnlActionsSidebar.Visible := False;

  // Header strip: title + chevron collapse.
  FActionsHeader := TPanel.Create(FOwnerForm);
  FActionsHeader.Parent := pnlActionsSidebar;
  FActionsHeader.Align := alTop;
  FActionsHeader.Height := 24;
  FActionsHeader.BevelOuter := bvNone;
  FActionsHeader.ParentBackground := False;
  FActionsHeader.ParentColor := False;
  FActionsHeader.Alignment := taLeftJustify;
  FActionsHeader.Caption := '  Actions';
  FActionsHeader.Font.Style := [fsBold];

  FActionsChevron := TSpeedButton.Create(FOwnerForm);
  FActionsChevron.Parent := FActionsHeader;
  FActionsChevron.Align := alRight;
  FActionsChevron.Width := 24;
  FActionsChevron.Flat := True;
  FActionsChevron.Caption := '<<';
  FActionsChevron.Hint := 'Collapse actions sidebar';
  FActionsChevron.ShowHint := True;
  FActionsChevron.OnClick := _OnChevronClick;

  // Filter box.
  FActionsFilter := TEdit.Create(FOwnerForm);
  FActionsFilter.Parent := pnlActionsSidebar;
  FActionsFilter.Align := alTop;
  FActionsFilter.AlignWithMargins := True;
  FActionsFilter.TextHint := 'Filter actions...';
  FActionsFilter.OnChange := _ActionsFilterChange;

  // Owner-drawn list (run-only rows).
  FActionsList := TListBox.Create(FOwnerForm);
  FActionsList.Parent := pnlActionsSidebar;
  FActionsList.Align := alClient;
  FActionsList.BorderStyle := bsNone;
  FActionsList.Style := lbOwnerDrawFixed;
  FActionsList.ItemHeight := 22;
  FActionsList.DoubleBuffered := True;
  FActionsList.OnDrawItem := _ActionsListDrawItem;
  FActionsList.OnMouseDown := _ActionsListMouseDown;
  FActionsList.OnKeyDown := _ActionsListKeyDown;
  FActionsList.OnDblClick := _ActionsListDblClick;

  // Right-click run menu (run-only - actions execute, no copy).
  FActionRowMenu := TPopupMenu.Create(FOwnerForm);
  LRun := TMenuItem.Create(FActionRowMenu);
  LRun.Caption := 'Run on terminal';
  LRun.OnClick := _ActionRunMenuClick;
  FActionRowMenu.Items.Add(LRun);
  FActionsList.PopupMenu := FActionRowMenu;

  ApplyTheme;
end;

destructor TActionsSidebar.Destroy;
begin
  // Owns no VCL handles: every control and the row menu was created with the owner
  // form as Owner, so the form's destruction frees them (teardown unchanged). The
  // injected callbacks are not owned. Nothing to free here — empty by design, SAFEST.
  inherited;
end;

function TActionsSidebar.Panel: TPanel;
begin
  Result := pnlActionsSidebar;
end;

function TActionsSidebar.ContentFitHeight: Integer;
begin
  // header 24 + filter ~32 + rows*itemHeight + pad. Min 90 so it never collapses.
  Result := 90;
  if Assigned(FActionsList) then
  begin
    Result := 24 + 34 + Length(FActionRows) * FActionsList.ItemHeight + 6;
    if Result < 90 then
      Result := 90;
  end;
end;

procedure TActionsSidebar.ApplyTheme;
var
  LBg, LFg: TColor;
begin
  if not Assigned(pnlActionsSidebar) then
    Exit;
  if FIsDark() then
  begin
    LBg := $1E1E1E;
    LFg := $D4D4D4;
  end
  else
  begin
    LBg := $F3F3F3;
    LFg := $333333;
  end;
  pnlActionsSidebar.Color := LBg;
  if Assigned(FActionsHeader) then
  begin
    FActionsHeader.Color := LBg;
    FActionsHeader.Font.Color := LFg;
  end;
  if Assigned(FActionsFilter) then
  begin
    FActionsFilter.Color := LBg;
    FActionsFilter.Font.Color := LFg;
  end;
  if Assigned(FActionsList) then
  begin
    FActionsList.Color := LBg;
    FActionsList.Font.Color := LFg;
    FActionsList.Invalidate;
  end;
end;

procedure TActionsSidebar.Rebuild;
var
  LFilter: string;
  LStore: TActionStore;
  LCatalog: TActionCatalog;
  LActions: TArray<TTerminalAction>;
  LAct: TTerminalAction;
  LHeaderEmitted: Boolean;
  LIdx: Integer;
begin
  if not Assigned(FActionsList) then
    Exit;
  LFilter := '';
  if Assigned(FActionsFilter) then
    LFilter := LowerCase(Trim(FActionsFilter.Text));
  FActionsList.Items.BeginUpdate;
  try
    FActionsList.Items.Clear;
    SetLength(FActionRows, 0);
    LStore := TActionStore.Create;
    try
      LCatalog := LStore.LoadCatalog;
      try
        LActions := LCatalog.AllActions;
        LHeaderEmitted := False;
        for LAct in LActions do
        begin
          if (LFilter <> '') and (Pos(LFilter, LowerCase(LAct.Name)) = 0) then
            Continue;
          if not LHeaderEmitted then
          begin
            LIdx := Length(FActionRows);
            SetLength(FActionRows, LIdx + 1);
            FActionRows[LIdx].IsHeader := True;
            FActionRows[LIdx].IsAction := True;
            FActionsList.Items.Add('ACTIONS');
            LHeaderEmitted := True;
          end;
          LIdx := Length(FActionRows);
          SetLength(FActionRows, LIdx + 1);
          FActionRows[LIdx].IsAction := True;
          FActionRows[LIdx].ActionId := LAct.Id;
          FActionRows[LIdx].ActionName := LAct.Name;
          FActionsList.Items.Add(LAct.Name);
        end;
      finally
        LCatalog.Free;
      end;
    finally
      LStore.Free;
    end;
  finally
    FActionsList.Items.EndUpdate;
  end;
  FActionsList.Invalidate;

  // The both-open content-fit (sizing the actions panel to its rows so there's no
  // empty gap above snippets) moved to the form's _ArrangeLeftSidebars coordinator,
  // which owns ALL left-host geometry incl. the inter-sidebar splitter. Re-arrange so
  // a filter change re-fits the panel to the new row count, exactly as before.
  if Assigned(FOnArrange) then
    FOnArrange();
end;

procedure TActionsSidebar._ActionsListDrawItem(Control: TWinControl;
  Index: Integer; Rect: TRect; State: TOwnerDrawState);
const
  CRunZoneW = 22;
var
  LCanvas: TCanvas;
  LRow: TSnippetSidebarRow;
  LTextRect: TRect;
  LMidY: Integer;
  LRunLeft: Integer;
  LHeaderBg, LDimFg, LFg, LSelBg: TColor;
begin
  if (Index < 0) or (Index > High(FActionRows)) then
    Exit;
  LCanvas := FActionsList.Canvas;
  LRow := FActionRows[Index];

  if FIsDark() then
  begin
    LFg := $D4D4D4;
    LHeaderBg := $2A2A2A;
    LDimFg := $9C9C9C;
    LSelBg := $3F3F46;
  end
  else
  begin
    LFg := $333333;
    LHeaderBg := $E4E4E4;
    LDimFg := $6E6E6E;
    LSelBg := $CDE6FF;
  end;

  LMidY := (Rect.Top + Rect.Bottom) div 2;

  if LRow.IsHeader then
  begin
    LCanvas.Brush.Style := bsSolid;
    LCanvas.Brush.Color := LHeaderBg;
    LCanvas.FillRect(Rect);
    LCanvas.Font.Style := [fsBold];
    LCanvas.Font.Color := LDimFg;
    LCanvas.Brush.Style := bsClear;
    LCanvas.TextRect(Rect, Rect.Left + 6, Rect.Top + 3, 'ACTIONS');
    Exit;
  end;

  LCanvas.Brush.Style := bsSolid;
  if odSelected in State then
    LCanvas.Brush.Color := LSelBg
  else
    LCanvas.Brush.Color := FActionsList.Color;
  LCanvas.FillRect(Rect);

  LRunLeft := Rect.Right - CRunZoneW;
  LTextRect := Rect;
  LTextRect.Left := Rect.Left + 8;
  LTextRect.Right := LRunLeft - 4;

  LCanvas.Font.Style := [];
  LCanvas.Font.Color := LFg;
  LCanvas.Brush.Style := bsClear;
  LCanvas.TextRect(LTextRect, LTextRect.Left, Rect.Top + 3, LRow.ActionName);

  // Run glyph: filled play triangle.
  LCanvas.Brush.Style := bsSolid;
  LCanvas.Brush.Color := LFg;
  LCanvas.Pen.Color := LFg;
  LCanvas.Polygon([
    Point(LRunLeft + 7, LMidY - 5),
    Point(LRunLeft + 7, LMidY + 5),
    Point(LRunLeft + 15, LMidY)]);
end;

procedure TActionsSidebar._ActionsListMouseDown(Sender: TObject;
  Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
const
  CRunZoneW = 22;
var
  LIndex: Integer;
  LWidth: Integer;
begin
  LIndex := FActionsList.ItemAtPos(Point(X, Y), True);
  if (LIndex < 0) or (LIndex > High(FActionRows)) then
    Exit;

  if Button = mbRight then
  begin
    FActionMenuRow := LIndex;
    if not FActionRows[LIndex].IsHeader then
      FActionsList.ItemIndex := LIndex;
    Exit; // the row PopupMenu opens on mouse-up
  end;

  if Button <> mbLeft then
    Exit;
  if FActionRows[LIndex].IsHeader then
    Exit;

  LWidth := FActionsList.ClientWidth;
  if X >= LWidth - CRunZoneW then
    FOnRunAction(FActionRows[LIndex].ActionId)
  else
    FActionsList.ItemIndex := LIndex;
end;

procedure TActionsSidebar._ActionsListDblClick(Sender: TObject);
var
  LIndex: Integer;
begin
  LIndex := FActionsList.ItemIndex;
  if (LIndex >= 0) and (LIndex <= High(FActionRows))
    and not FActionRows[LIndex].IsHeader then
    FOnRunAction(FActionRows[LIndex].ActionId);
end;

procedure TActionsSidebar._ActionsListKeyDown(Sender: TObject;
  var Key: Word; Shift: TShiftState);
begin
  if Key = VK_ESCAPE then
  begin
    Toggle;
    Key := 0;
  end;
end;

procedure TActionsSidebar._ActionsFilterChange(Sender: TObject);
begin
  Rebuild;
end;

procedure TActionsSidebar._ActionRunMenuClick(Sender: TObject);
begin
  if (FActionMenuRow >= 0) and (FActionMenuRow <= High(FActionRows))
    and not FActionRows[FActionMenuRow].IsHeader then
    FOnRunAction(FActionRows[FActionMenuRow].ActionId);
end;

procedure TActionsSidebar._OnChevronClick(Sender: TObject);
begin
  Toggle;
end;

procedure TActionsSidebar.Toggle;
begin
  FWanted := not FWanted;
  if Assigned(FOnArrange) then
    FOnArrange();
  if FWanted then
  begin
    ApplyTheme;
    Rebuild;
    if Assigned(FActionsFilter) and FActionsFilter.CanFocus then
      FActionsFilter.SetFocus;
  end;
end;

end.
