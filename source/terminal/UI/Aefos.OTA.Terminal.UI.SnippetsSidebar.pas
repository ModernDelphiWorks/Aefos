unit Aefos.OTA.Terminal.UI.SnippetsSidebar;

{
  Snippets contextual sidebar, extracted from the TAefosTerminalDockForm god-form as a
  focused helper of the DockForm split (audit / form decomposition). Sibling of the
  TActionsSidebar helper and shares its list-row model (TSnippetSidebarRow, homed in
  Aefos.OTA.Terminal.UI.ActionsSidebar).

  Owns the left-host's *snippets* panel (the DFM control pnlSnippetsSidebar, passed in)
  and everything inside it: the header + collapse chevron, the filter box, the owner-drawn
  run/copy list and its right-click menu, plus the row model (FSidebarRows). On Rebuild it
  loads the snippet model from the INJECTED TSnippetManager (which stays owned by the
  form) grouped by scope (Project / Team / Personal) and paints / filters / runs rows.
  The list may also contain mixed Action rows, which run through the OnRunAction callback
  exactly like the actions sidebar.

  It does NOT own the shared LEFT host, the actions sidebar, the inter-sidebar splitter,
  the quick-access snippets POPUP menu, or the TSnippetManager — all of those stay on the
  form. The form's _ArrangeLeftSidebars coordinator owns ALL left-host geometry, and the
  form's _ToggleSnippetsSidebar coordinator (reached through the OnToggle callback) drives
  the show/hide of BOTH sidebars. The chevron and the list's Esc key call OnToggle; running
  a snippet writes into the currently focused terminal view, fetched fresh each time through
  the GetFocusedView callback (FFocusedView is mutable form state). Running an action, the
  dark-theme query and the toggle are all injected callbacks, so the helper keeps no back-
  reference to the form.

  Teardown: the panel is a form-owned DFM control and every child control + the row menu is
  created with the OWNER FORM as Owner, so the form's destruction frees them exactly as it
  did before this extraction — the helper owns no VCL handles, and its destructor frees
  nothing. Zero change to the form's teardown sequence (the form still frees the helper
  instance itself in Destroy, beside the actions helper).
}

interface

uses
  Winapi.Windows,
  System.Classes,
  System.SysUtils,
  System.Types,
  System.Generics.Collections,
  Vcl.Graphics,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.StdCtrls,
  Vcl.Buttons,
  Vcl.ExtCtrls,
  Vcl.Menus,
  Aefos.OTA.Terminal.Core.Snippets,
  Aefos.OTA.Terminal.UI.ActionsSidebar,
  Aefos.OTA.Terminal.UI.TerminalView;

type
  /// <summary>
  ///   The terminal's contextual "Snippets" sidebar. Builds its children into the
  ///   form-owned DFM panel supplied in the constructor and exposes a small surface to
  ///   the form's geometry/toggle coordinators (Panel) plus the verbs the coordinator
  ///   and command palette need (Rebuild / ApplyTheme / UpdateScopes / RunSnippet /
  ///   FocusFilter / BuildVarContext).
  /// </summary>
  TSnippetsSidebar = class
  private
    FOwnerForm: TCustomForm;
    FPanel: TPanel;
    FSnippetManager: TSnippetManager;
    FGetFocusedView: TFunc<TAefosTerminalTerminalView>;
    FOnRunAction: TProc<string>;
    // OnToggle reaches the form's _ToggleSnippetsSidebar coordinator (it flips BOTH
    // sidebars + re-arranges), so the chevron and the list Esc key delegate to it
    // instead of owning a local toggle like the actions sidebar does.
    FOnToggle: TProc;
    FIsDark: TFunc<Boolean>;
    // Snippets children — ALL owned by FOwnerForm, so the form frees them. FPanel is the
    // DFM control pnlSnippetsSidebar (also form-owned); the helper only builds INTO it.
    FSnippetsHeader: TPanel;
    FSnippetsChevron: TSpeedButton;
    FSnippetFilter: TEdit;
    FSnippetsList: TListBox;
    FSnippetRowMenu: TPopupMenu;
    FSidebarRows: TArray<TSnippetSidebarRow>;
    FSnippetMenuRow: Integer;
    FSnippetsKeyboardNav: Boolean;
    procedure _OnChevronClick(Sender: TObject);
    procedure _SnippetFilterChange(Sender: TObject);
    procedure _SnippetsListDrawItem(Control: TWinControl; Index: Integer;
      Rect: TRect; State: TOwnerDrawState);
    procedure _SnippetsListMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure _SnippetsListKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure _SnippetsListDblClick(Sender: TObject);
    procedure _SnippetRunMenuClick(Sender: TObject);
    procedure _SnippetCopyMenuClick(Sender: TObject);
    function _SnippetRowAt(const AX, AY: Integer): Integer;
    function _ResolveSnippetText(const ASnippet: TSnippet): string;
    procedure _CopySnippetResolved(const ASnippet: TSnippet);
    function _ActiveProjectDproj: string;
    function _ActiveProjectRoot: string;
  public
    // Builds the snippets header/filter/list/chevron + row menu INTO APanel (the form-
    // owned DFM control pnlSnippetsSidebar), each child owned by AOwnerForm. The callbacks:
    // AGetFocusedView fetches the live focused terminal view (mutable form state),
    // AOnRunAction runs a saved action by id (mixed action rows), AOnToggle reaches the
    // form's both-sidebar toggle coordinator, AIsDark queries the IDE dark theme.
    // AOnArrange is accepted to parallel TActionsSidebar but the snippets panel FILLS
    // (alClient) so nothing here re-arranges — the form's toggle coordinator owns all
    // left-host geometry. ASnippetManager is the form-owned
    // snippet model, injected (the form keeps ownership + the public SnippetManager prop).
    constructor Create(const AOwnerForm: TCustomForm; const APanel: TPanel;
      const ASnippetManager: TSnippetManager;
      const AGetFocusedView: TFunc<TAefosTerminalTerminalView>;
      const AOnRunAction: TProc<string>; const AOnToggle: TProc;
      const AOnArrange: TProc; const AIsDark: TFunc<Boolean>);
    destructor Destroy; override;
    // The snippets panel (the DFM control it was given); the form's _ArrangeLeftSidebars
    // coordinator drives its Align/Visible (it FILLS — alClient — so there is no content-
    // fit height here, unlike the actions sidebar).
    function Panel: TPanel;
    // Re-tint the panel + controls for the active IDE theme.
    procedure ApplyTheme;
    // Rebuild the grouped snippet list from the manager + filter box.
    procedure Rebuild;
    // Re-derive Project/Team scope roots from the active OTA project, reload the manager,
    // and refresh the list when visible.
    procedure UpdateScopes;
    // Resolve {{...}} vars against current IDE state and write the snippet into the
    // focused terminal view (used by the list, the row menu and the command palette).
    procedure RunSnippet(const ASnippet: TSnippet);
    // Builds the live {{...}} variable context from current IDE state (OTA project,
    // focused profile, git, datetime). Caller owns the result. The form exposes this
    // through its public _BuildSnippetVarContext shim for the editor's live preview.
    function BuildVarContext: TDictionary<string, string>;
    // Give the filter box keyboard focus (the form's toggle does this on open).
    procedure FocusFilter;
  end;

implementation

uses
  Vcl.Clipbrd,
  ToolsAPI,
  Aefos.OTA.Terminal.Core.Accessibility,
  Aefos.OTA.Terminal.Core.GitInfo,
  Aefos.OTA.Terminal.Core.Mustache,
  Aefos.OTA.Terminal.Core.SnippetVars,
  Aefos.OTA.Terminal.UI.IDEThemes;

function _ScopeHeaderCaption(const AScope: TSnippetScope): string;
begin
  case AScope of
    ssProject: Result := 'PROJECT';
    ssTeam: Result := 'TEAM';
  else
    Result := 'PERSONAL';
  end;
end;

function _TagsToString(const ATags: TArray<string>): string;
var
  LTag: string;
begin
  Result := '';
  for LTag in ATags do
    if LTag <> '' then
      Result := Result + '[' + LTag + '] ';
  Result := TrimRight(Result);
end;

{ TSnippetsSidebar }

constructor TSnippetsSidebar.Create(const AOwnerForm: TCustomForm;
  const APanel: TPanel; const ASnippetManager: TSnippetManager;
  const AGetFocusedView: TFunc<TAefosTerminalTerminalView>;
  const AOnRunAction: TProc<string>; const AOnToggle: TProc;
  const AOnArrange: TProc; const AIsDark: TFunc<Boolean>);
var
  LRun: TMenuItem;
  LCopy: TMenuItem;
begin
  inherited Create;
  FOwnerForm := AOwnerForm;
  FPanel := APanel;
  FSnippetManager := ASnippetManager;
  FGetFocusedView := AGetFocusedView;
  FOnRunAction := AOnRunAction;
  FOnToggle := AOnToggle;
  FIsDark := AIsDark;
  FSnippetMenuRow := -1;
  if not Assigned(FPanel) then
    Exit;

  FPanel.BevelOuter := bvNone;
  FPanel.ParentBackground := False;
  FPanel.ParentColor := False;
  FPanel.DoubleBuffered := True;
  FPanel.Width := 184;
  FPanel.Visible := False;

  // Header strip: title + chevron collapse.
  FSnippetsHeader := TPanel.Create(FOwnerForm);
  FSnippetsHeader.Parent := FPanel;
  FSnippetsHeader.Align := alTop;
  FSnippetsHeader.Height := 24;
  FSnippetsHeader.BevelOuter := bvNone;
  FSnippetsHeader.ParentBackground := False;
  FSnippetsHeader.ParentColor := False;
  FSnippetsHeader.Alignment := taLeftJustify;
  FSnippetsHeader.Caption := '  Snippets';
  FSnippetsHeader.Font.Style := [fsBold];

  FSnippetsChevron := TSpeedButton.Create(FOwnerForm);
  FSnippetsChevron.Parent := FSnippetsHeader;
  FSnippetsChevron.Align := alRight;
  FSnippetsChevron.Width := 24;
  FSnippetsChevron.Flat := True;
  FSnippetsChevron.Caption := '<<';
  FSnippetsChevron.Hint := 'Collapse snippets sidebar';
  FSnippetsChevron.ShowHint := True;
  FSnippetsChevron.OnClick := _OnChevronClick;

  // Filter box.
  FSnippetFilter := TEdit.Create(FOwnerForm);
  FSnippetFilter.Parent := FPanel;
  FSnippetFilter.Align := alTop;
  FSnippetFilter.AlignWithMargins := True;
  FSnippetFilter.TextHint := 'Filter snippets...';
  FSnippetFilter.OnChange := _SnippetFilterChange;

  // Owner-drawn grouped list.
  FSnippetsList := TListBox.Create(FOwnerForm);
  FSnippetsList.Parent := FPanel;
  FSnippetsList.Align := alClient;
  FSnippetsList.BorderStyle := bsNone;
  FSnippetsList.Style := lbOwnerDrawFixed;
  FSnippetsList.ItemHeight := 22;
  FSnippetsList.DoubleBuffered := True;
  FSnippetsList.OnDrawItem := _SnippetsListDrawItem;
  FSnippetsList.OnMouseDown := _SnippetsListMouseDown;
  FSnippetsList.OnKeyDown := _SnippetsListKeyDown;
  FSnippetsList.OnDblClick := _SnippetsListDblClick;

  // Right-click run/copy menu (independent of the per-row glyph hit-zones).
  FSnippetRowMenu := TPopupMenu.Create(FOwnerForm);
  LRun := TMenuItem.Create(FSnippetRowMenu);
  LRun.Caption := 'Run on terminal';
  LRun.OnClick := _SnippetRunMenuClick;
  FSnippetRowMenu.Items.Add(LRun);
  LCopy := TMenuItem.Create(FSnippetRowMenu);
  LCopy.Caption := 'Copy resolved command';
  LCopy.OnClick := _SnippetCopyMenuClick;
  FSnippetRowMenu.Items.Add(LCopy);
  FSnippetsList.PopupMenu := FSnippetRowMenu;

  ApplyTheme;
end;

destructor TSnippetsSidebar.Destroy;
begin
  // Owns no VCL handles: FPanel is the form-owned DFM control, and every child control +
  // the row menu was created with the owner form as Owner, so the form's destruction
  // frees them (teardown unchanged). The injected callbacks + the form-owned snippet
  // manager are not owned here. Nothing to free — empty by design, SAFEST.
  inherited;
end;

function TSnippetsSidebar.Panel: TPanel;
begin
  Result := FPanel;
end;

procedure TSnippetsSidebar.FocusFilter;
begin
  if Assigned(FSnippetFilter) and FSnippetFilter.CanFocus then
    FSnippetFilter.SetFocus;
end;

procedure TSnippetsSidebar.ApplyTheme;
var
  LBg, LFg: TColor;
begin
  if not Assigned(FPanel) then
    Exit;
  if FIsDark then
  begin
    LBg := $1E1E1E;
    LFg := $D4D4D4;
  end
  else
  begin
    LBg := $F3F3F3;
    LFg := $333333;
  end;
  FPanel.Color := LBg;
  if Assigned(FSnippetsHeader) then
  begin
    FSnippetsHeader.Color := LBg;
    FSnippetsHeader.Font.Color := LFg;
  end;
  if Assigned(FSnippetFilter) then
  begin
    FSnippetFilter.Color := LBg;
    FSnippetFilter.Font.Color := LFg;
  end;
  if Assigned(FSnippetsList) then
  begin
    FSnippetsList.Color := LBg;
    FSnippetsList.Font.Color := LFg;
    FSnippetsList.Invalidate;
  end;
end;

procedure TSnippetsSidebar.Rebuild;
var
  LFilter: string;

  procedure _AppendScope(const AScope: TSnippetScope);
  var
    LSnip: TSnippet;
    LHeaderEmitted: Boolean;
    LMatches: Boolean;
    LIdx: Integer;
  begin
    LHeaderEmitted := False;
    for LSnip in FSnippetManager.SnippetsByScope(AScope) do
    begin
      LMatches := (LFilter = '')
        or (Pos(LFilter, LowerCase(LSnip.Title)) > 0)
        or (Pos(LFilter, LowerCase(_TagsToString(LSnip.Tags))) > 0);
      if not LMatches then
        Continue;

      if not LHeaderEmitted then
      begin
        LIdx := Length(FSidebarRows);
        SetLength(FSidebarRows, LIdx + 1);
        FSidebarRows[LIdx].IsHeader := True;
        FSidebarRows[LIdx].Scope := AScope;
        FSidebarRows[LIdx].Snippet := nil;
        FSnippetsList.Items.Add(_ScopeHeaderCaption(AScope));
        LHeaderEmitted := True;
      end;

      LIdx := Length(FSidebarRows);
      SetLength(FSidebarRows, LIdx + 1);
      FSidebarRows[LIdx].IsHeader := False;
      FSidebarRows[LIdx].Scope := AScope;
      FSidebarRows[LIdx].Snippet := LSnip;
      FSnippetsList.Items.Add(LSnip.Title);
    end;
  end;

begin
  if not Assigned(FSnippetsList) or not Assigned(FSnippetManager) then
    Exit;
  LFilter := LowerCase(Trim(FSnippetFilter.Text));
  FSnippetsList.Items.BeginUpdate;
  try
    FSnippetsList.Items.Clear;
    SetLength(FSidebarRows, 0);
    // Project first (most contextual when a project is open), then Team, Personal.
    _AppendScope(ssProject);
    _AppendScope(ssTeam);
    _AppendScope(ssPersonal);
  finally
    FSnippetsList.Items.EndUpdate;
  end;
  FSnippetsList.Invalidate;
end;

procedure TSnippetsSidebar._SnippetsListDrawItem(Control: TWinControl;
  Index: Integer; Rect: TRect; State: TOwnerDrawState);
const
  CRunZoneW = 22;
  CCopyZoneW = 22;
var
  LCanvas: TCanvas;
  LRow: TSnippetSidebarRow;
  LTextRect: TRect;
  LTagsStr: string;
  LNameW: Integer;
  LTagX: Integer;
  LMidY: Integer;
  LRunLeft: Integer;
  LCopyLeft: Integer;
  LHeaderBg, LDimFg, LFg, LSelBg: TColor;
begin
  if (Index < 0) or (Index > High(FSidebarRows)) then
    Exit;
  LCanvas := FSnippetsList.Canvas;
  LRow := FSidebarRows[Index];

  if FIsDark then
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
    if LRow.IsAction then
      LCanvas.TextRect(Rect, Rect.Left + 6, Rect.Top + 3, 'ACTIONS')
    else
      LCanvas.TextRect(Rect, Rect.Left + 6, Rect.Top + 3, _ScopeHeaderCaption(LRow.Scope));
    Exit;
  end;

  // Snippet row background.
  LCanvas.Brush.Style := bsSolid;
  if odSelected in State then
    LCanvas.Brush.Color := LSelBg
  else
    LCanvas.Brush.Color := FSnippetsList.Color;
  LCanvas.FillRect(Rect);

  // Title (clipped to the text zone) + dim tags.
  LRunLeft := Rect.Right - CCopyZoneW - CRunZoneW;
  LCopyLeft := Rect.Right - CCopyZoneW;
  LTextRect := Rect;
  LTextRect.Left := Rect.Left + 8;
  LTextRect.Right := LRunLeft - 4;

  LCanvas.Font.Style := [];
  LCanvas.Font.Color := LFg;
  LCanvas.Brush.Style := bsClear;

  if LRow.IsAction then
  begin
    // Action row: name + run glyph only (actions execute; no tags, no copy).
    LCanvas.TextRect(LTextRect, LTextRect.Left, Rect.Top + 3, LRow.ActionName);
    LCanvas.Brush.Style := bsSolid;
    LCanvas.Brush.Color := LFg;
    LCanvas.Pen.Color := LFg;
    LCanvas.Polygon([
      Point(LRunLeft + 7, LMidY - 5),
      Point(LRunLeft + 7, LMidY + 5),
      Point(LRunLeft + 15, LMidY)]);
  end
  else
  begin
    LCanvas.TextRect(LTextRect, LTextRect.Left, Rect.Top + 3, LRow.Snippet.Title);

    LTagsStr := _TagsToString(LRow.Snippet.Tags);
    if LTagsStr <> '' then
    begin
      LNameW := LCanvas.TextWidth(LRow.Snippet.Title);
      LTagX := LTextRect.Left + LNameW + 8;
      if LTagX < LTextRect.Right then
      begin
        LCanvas.Font.Color := LDimFg;
        LCanvas.TextRect(LTextRect, LTagX, Rect.Top + 3, LTagsStr);
      end;
    end;

    // Run glyph: filled play triangle.
    LCanvas.Brush.Style := bsSolid;
    LCanvas.Brush.Color := LFg;
    LCanvas.Pen.Color := LFg;
    LCanvas.Polygon([
      Point(LRunLeft + 7, LMidY - 5),
      Point(LRunLeft + 7, LMidY + 5),
      Point(LRunLeft + 15, LMidY)]);

    // Copy glyph: two overlapping rectangle outlines.
    LCanvas.Brush.Style := bsClear;
    LCanvas.Pen.Color := LFg;
    LCanvas.Rectangle(LCopyLeft + 8, LMidY - 1, LCopyLeft + 15, LMidY + 7);
    LCanvas.Rectangle(LCopyLeft + 10, LMidY - 5, LCopyLeft + 17, LMidY + 3);
  end;

  // V.8 keyboard-focus ring on the selected snippet row (ESP-065 / ADR-065-03).
  if TAccessibility.ShouldDrawFocusRing(
       (odSelected in State) and FSnippetsList.Focused, FSnippetsKeyboardNav) then
    DrawAefosTerminalFocusRing(LCanvas, Rect);
end;

function TSnippetsSidebar._SnippetRowAt(const AX, AY: Integer): Integer;
begin
  Result := FSnippetsList.ItemAtPos(Point(AX, AY), True);
end;

procedure TSnippetsSidebar._SnippetsListMouseDown(Sender: TObject;
  Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
const
  CRunZoneW = 22;
  CCopyZoneW = 22;
var
  LIndex: Integer;
  LWidth: Integer;
begin
  // Pointer interaction clears keyboard mode so the row focus ring stays off
  // for mouse-driven selection (V.8 / ADR-065-03).
  FSnippetsKeyboardNav := False;
  FSnippetsList.Invalidate;

  LIndex := _SnippetRowAt(X, Y);
  if (LIndex < 0) or (LIndex > High(FSidebarRows)) then
    Exit;

  if Button = mbRight then
  begin
    FSnippetMenuRow := LIndex;
    if not FSidebarRows[LIndex].IsHeader then
      FSnippetsList.ItemIndex := LIndex;
    Exit; // the row PopupMenu opens on mouse-up
  end;

  if Button <> mbLeft then
    Exit;
  if FSidebarRows[LIndex].IsHeader then
    Exit;

  LWidth := FSnippetsList.ClientWidth;
  if FSidebarRows[LIndex].IsAction then
  begin
    // Actions execute (no copy affordance): run zone fires, rest selects.
    if X >= LWidth - CCopyZoneW - CRunZoneW then
      FOnRunAction(FSidebarRows[LIndex].ActionId)
    else
      FSnippetsList.ItemIndex := LIndex;
    Exit;
  end;
  if X >= LWidth - CCopyZoneW then
    _CopySnippetResolved(FSidebarRows[LIndex].Snippet)
  else if X >= LWidth - CCopyZoneW - CRunZoneW then
    RunSnippet(FSidebarRows[LIndex].Snippet)
  else
    FSnippetsList.ItemIndex := LIndex;
end;

procedure TSnippetsSidebar._SnippetsListKeyDown(Sender: TObject;
  var Key: Word; Shift: TShiftState);
begin
  // Arrow/navigation keys mean the user is keyboard-driving the list → enable
  // the focus ring. Esc collapses the sidebar (consistent close affordance,
  // ADR-065-03). Up/Down traversal is native to the list box.
  FSnippetsKeyboardNav := True;
  if Key = VK_ESCAPE then
  begin
    if Assigned(FOnToggle) then
      FOnToggle();
    Key := 0;
    Exit;
  end;
  FSnippetsList.Invalidate;
end;

procedure TSnippetsSidebar._SnippetsListDblClick(Sender: TObject);
var
  LIndex: Integer;
begin
  LIndex := FSnippetsList.ItemIndex;
  if (LIndex >= 0) and (LIndex <= High(FSidebarRows))
    and not FSidebarRows[LIndex].IsHeader then
    if FSidebarRows[LIndex].IsAction then
      FOnRunAction(FSidebarRows[LIndex].ActionId)
    else
      RunSnippet(FSidebarRows[LIndex].Snippet);
end;

procedure TSnippetsSidebar._SnippetFilterChange(Sender: TObject);
begin
  Rebuild;
end;

procedure TSnippetsSidebar._SnippetRunMenuClick(Sender: TObject);
begin
  if (FSnippetMenuRow >= 0) and (FSnippetMenuRow <= High(FSidebarRows))
    and not FSidebarRows[FSnippetMenuRow].IsHeader then
    if FSidebarRows[FSnippetMenuRow].IsAction then
      FOnRunAction(FSidebarRows[FSnippetMenuRow].ActionId)
    else
      RunSnippet(FSidebarRows[FSnippetMenuRow].Snippet);
end;

procedure TSnippetsSidebar._SnippetCopyMenuClick(Sender: TObject);
begin
  if (FSnippetMenuRow >= 0) and (FSnippetMenuRow <= High(FSidebarRows))
    and not FSidebarRows[FSnippetMenuRow].IsHeader
    and not FSidebarRows[FSnippetMenuRow].IsAction then
    _CopySnippetResolved(FSidebarRows[FSnippetMenuRow].Snippet);
end;

procedure TSnippetsSidebar._OnChevronClick(Sender: TObject);
begin
  if Assigned(FOnToggle) then
    FOnToggle();
end;

function TSnippetsSidebar._ActiveProjectDproj: string;
var
  LModuleServices: IOTAModuleServices;
  LProject: IOTAProject;
begin
  Result := '';
  if not Assigned(BorlandIDEServices) then
    Exit;
  if Supports(BorlandIDEServices, IOTAModuleServices, LModuleServices)
    and Assigned(LModuleServices.MainProjectGroup) then
  begin
    LProject := LModuleServices.MainProjectGroup.ActiveProject;
    if Assigned(LProject) then
      Result := LProject.FileName;
  end;
end;

function TSnippetsSidebar._ActiveProjectRoot: string;
var
  LDproj: string;
begin
  LDproj := _ActiveProjectDproj;
  if LDproj <> '' then
    Result := ExcludeTrailingPathDelimiter(ExtractFilePath(LDproj))
  else
    Result := '';
end;

function TSnippetsSidebar.BuildVarContext: TDictionary<string, string>;
var
  LRoot: string;
  LDproj: string;
  LGit: TGitInfo;
  LProfile: string;
  LIso: string;
  LView: TAefosTerminalTerminalView;
begin
  LRoot := _ActiveProjectRoot;
  LDproj := _ActiveProjectDproj;
  LGit := TGitInfo.ReadFrom(LRoot);
  LProfile := '';
  LView := FGetFocusedView();
  if Assigned(LView) and Assigned(LView.Host) then
    LProfile := LView.Host.ActiveProfileName;
  LIso := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', Now);
  Result := TSnippetVars.Build(LGit, LDproj, LRoot, LProfile, LIso);
end;

function TSnippetsSidebar._ResolveSnippetText(const ASnippet: TSnippet): string;
var
  LContext: TDictionary<string, string>;
begin
  if not Assigned(ASnippet) then
    Exit('');
  LContext := BuildVarContext;
  try
    Result := TMustacheEngine.Substitute(ASnippet.Command, LContext);
  finally
    LContext.Free;
  end;
end;

procedure TSnippetsSidebar.RunSnippet(const ASnippet: TSnippet);
var
  LView: TAefosTerminalTerminalView;
begin
  LView := FGetFocusedView();
  if not Assigned(ASnippet) or not Assigned(LView) then
    Exit;
  LView.WriteText(_ResolveSnippetText(ASnippet) + sLineBreak);
  if Assigned(LView.TerminalCanvas) and LView.TerminalCanvas.CanFocus then
    LView.TerminalCanvas.SetFocus;
end;

procedure TSnippetsSidebar._CopySnippetResolved(const ASnippet: TSnippet);
begin
  if not Assigned(ASnippet) then
    Exit;
  Clipboard.AsText := _ResolveSnippetText(ASnippet);
end;

procedure TSnippetsSidebar.UpdateScopes;
var
  LRoot: string;
begin
  if not Assigned(FSnippetManager) then
    Exit;
  LRoot := _ActiveProjectRoot;
  // Both Project and Team tiers derive from the project root this demand
  // (ADR-060-04); empty root => both scopes inert, Personal only.
  FSnippetManager.ProjectPath := LRoot;
  FSnippetManager.TeamPath := LRoot;
  FSnippetManager.Reload;
  if Assigned(FPanel) and FPanel.Visible then
    Rebuild;
end;

end.
