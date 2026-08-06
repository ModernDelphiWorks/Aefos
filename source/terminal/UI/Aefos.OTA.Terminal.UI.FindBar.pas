unit Aefos.OTA.Terminal.UI.FindBar;

{
  Find bar, extracted from the TAefosTerminalDockForm god-form as a focused helper of the
  DockForm split (audit / form decomposition). Sibling of the TActionsSidebar /
  TSnippetsSidebar helpers.

  Owns the floating find overlay's BEHAVIOUR: show/hide + focus, the live incremental
  search against the active terminal view, the N/M match counter, the top-right anchor +
  rounded silhouette, the IDE-theme tint, and the V.8 keyboard-focus ring (ESP-065 /
  ADR-065-03). Unlike the two sidebar helpers, the find bar's controls are DFM-PUBLISHED
  on the form (pnlFind / edtFind / btnFindNext / btnFindPrev / chkCaseSensitive /
  lblFindCount), so the helper RECEIVES them in the constructor (it does NOT create them)
  and the form keeps thin published forwarder handlers that the .dfm reader resolves by
  MethodAddress (btnShowFindClick / edtFindChange / btnFindNextClick / btnFindPrevClick /
  edtFindKeyDown). FormKeyDown (the global KeyPreview hub) stays on the form and routes
  the find shortcuts here through HandleShortcuts.

  Coupling: the search reads the currently focused terminal view fetched fresh each call
  through the GetFocusedView callback (FFocusedView is mutable form state); the overlay
  anchors against the terminal page-control's bounds (passed in as APgcTerminals, which
  shares the form client coordinate space with pnlFind); the focus ring is gated through
  TAccessibility.ShouldDrawFocusRing; the theme tint pulls the IDE chrome straight from
  BorlandIDEServices (no dark-theme callback is needed — _ApplyFindOverlayTheme never used
  _IsIDEDarkTheme).

  Teardown: pnlFind and every find control is a form-owned DFM control, so the form's
  destruction frees them. The helper owns no VCL handle of its own — its ONLY teardown
  responsibility is the pnlFind WindowProc subclass it installs in the constructor (the
  same WindowProc-swap the form's Create used). The destructor restores the original
  WindowProc; the form frees the helper BEFORE the inherited destructor frees pnlFind, so
  the restore lands in time. (The old form NEVER restored pnlFind.WindowProc in Destroy —
  only lstTerminals was restored — so this symmetric restore is a latent-bug fix carried
  by the extraction.)
}

interface

uses
  Winapi.Messages,
  System.Types,
  System.Classes,
  System.SysUtils,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.StdCtrls,
  Vcl.Buttons,
  Vcl.ExtCtrls,
  Aefos.OTA.Terminal.UI.TerminalView;

type
  /// <summary>
  ///   Logical match anchor used by the standalone find-bar (ESP-055 /
  ///   ADR-055-02). Anchors stay in (row, col, length) coordinates so a
  ///   window grow/shrink reflows the painted rect without invalidating
  ///   the anchor list.
  /// </summary>
  TMatchAnchor = record
    LogicalRow: Integer;
    LogicalCol: Integer;
    Length: Integer;
  end;

  /// <summary>Grid metrics consumed by <see cref="ComputeMatchRect"/>.</summary>
  TFindGridMetrics = record
    CellWidth: Integer;
    CellHeight: Integer;
    ScrollOffset: Integer;
  end;

  /// <summary>
  ///   The terminal's floating find bar. Receives the DFM-published find controls + the
  ///   page-control anchor frame and a GetFocusedView callback, installs the pnlFind
  ///   WindowProc subclass, and exposes the verbs the form's published forwarders and
  ///   FormKeyDown call (ShowFind / FindChanged / FindNext / FindPrev / KeyDown /
  ///   HandleShortcuts) plus AnchorOverlay (for Resize) and ApplyTheme.
  /// </summary>
  TFindBar = class
  private
    FPnlFind: TPanel;
    FEdtFind: TEdit;
    FChkCase: TCheckBox;
    FLblCount: TLabel;
    FPgcTerminals: TWinControl;
    FGetFocusedView: TFunc<TAefosTerminalTerminalView>;
    // V.8 (ESP-065 / ADR-065-03): keyboard-vs-mouse state for the find overlay
    // focus ring, gated through TAccessibility.ShouldDrawFocusRing.
    FFindKeyboardNav: Boolean;
    FOriginalFindWP: TWndMethod;
    procedure _UpdateFindCounter;
    // V.8: subclasses pnlFind so the find overlay paints the uniform focus ring
    // around edtFind when it holds keyboard focus (ESP-065 / ADR-065-03).
    procedure SubclassWP(var Message: TMessage);
  public
    // Receives the form-owned DFM find controls (does NOT create them) + APgcTerminals
    // (the terminal page-control whose BoundsRect frames the overlay) + AGetFocusedView
    // (the live focused terminal view, mutable form state). AOwnerForm / ABtnNext /
    // ABtnPrev are accepted to mirror the find-bar's conceptual ownership (the buttons are
    // DFM-wired to the form's forwarders, navigation runs through FindNext/FindPrev) but
    // are not retained. Installs the pnlFind WindowProc subclass exactly as the form's
    // Create did.
    constructor Create(const AOwnerForm: TCustomForm; const APnlFind: TPanel;
      const AEdtFind: TEdit; const ABtnNext, ABtnPrev: TSpeedButton;
      const AChkCase: TCheckBox; const ALblCount: TLabel;
      const APgcTerminals: TWinControl;
      const AGetFocusedView: TFunc<TAefosTerminalTerminalView>);
    destructor Destroy; override;
    // Toggle the overlay (Sender=nil => keyboard => show the focus ring); on show, anchor
    // + focus the find box, on hide return focus to the terminal view (old btnShowFindClick).
    procedure ShowFind(Sender: TObject);
    // Live incremental search as the find text changes (old edtFindChange).
    procedure FindChanged;
    // Find the next / previous match (old btnFindNextClick / btnFindPrevClick bodies).
    procedure FindNext;
    procedure FindPrev;
    // Find-box key handling: Enter = next (Shift = prev), Esc = close (old edtFindKeyDown).
    procedure KeyDown(var Key: Word; Shift: TShiftState);
    // Ctrl+F / F3 routed from the form's FormKeyDown hub (old _HandleFindShortcuts).
    procedure HandleShortcuts(var Key: Word; Shift: TShiftState);
    // Re-tint the overlay for the active IDE theme (old _ApplyFindOverlayTheme).
    procedure ApplyTheme;
    // Float/anchor the overlay at the terminal area's top-right with a rounded
    // silhouette (old _AnchorFindOverlay). Public so the form's Resize can re-pin it.
    procedure AnchorOverlay;
  end;

type
  /// <summary>
  ///   Pure geometry + formatting helpers for the find bar. Static-only
  ///   sealed class — headless-testable, no VCL state (BR5).
  /// </summary>
  TFindBarMath = class sealed
  public
    /// <summary>
    ///   Pure projection of a logical <see cref="TMatchAnchor"/> onto pixel
    ///   coordinates given current grid metrics. Reflowing the window changes
    ///   <c>CellWidth</c>/<c>CellHeight</c>/<c>ScrollOffset</c>; the anchor
    ///   stays constant (ADR-055-02).
    /// </summary>
    class function ComputeMatchRect(const AAnchor: TMatchAnchor;
      const AMetrics: TFindGridMetrics): TRect; static;

    /// <summary>
    ///   Formats the standalone find-bar counter caption. Returns <c>''</c> when
    ///   <c>ATotal &lt;= 0</c> or <c>ACurrent &lt;= 0</c>; otherwise
    ///   <c>'N/M'</c> (1-based, no padding) per ADR-055-03 / BR3.
    /// </summary>
    class function FormatFindCounter(ACurrent, ATotal: Integer): string; static;

    /// <summary>
    ///   Pure top-right anchor for the floating find overlay (ESP-061 / V.4 /
    ///   ADR-061 overlay chrome). Returns a rect inside <c>AClientRect</c>, inset
    ///   by <c>AMargin</c> from the top and right edges and sized to
    ///   <c>AOverlayW</c> x <c>AOverlayH</c>. When the client is too narrow or too
    ///   short the overlay is clamped so it never crosses the client edges. No VCL
    ///   state (BR5) — headless-testable.
    /// </summary>
    class function ComputeFindOverlayRect(const AClientRect: TRect;
      const AOverlayW, AOverlayH, AMargin: Integer): TRect; static;
  end;

implementation

uses
  Winapi.Windows,
  Vcl.Graphics,
  Vcl.Themes,
  ToolsAPI,
  Aefos.OTA.Terminal.Core.Accessibility,
  Aefos.OTA.Terminal.Core.VisualTokens,
  Aefos.OTA.Terminal.UI.IDEThemes;

class function TFindBarMath.ComputeMatchRect(const AAnchor: TMatchAnchor;
  const AMetrics: TFindGridMetrics): TRect;
begin
  Result.Left := AAnchor.LogicalCol * AMetrics.CellWidth;
  Result.Top := (AAnchor.LogicalRow - AMetrics.ScrollOffset) * AMetrics.CellHeight;
  Result.Right := Result.Left + AAnchor.Length * AMetrics.CellWidth;
  Result.Bottom := Result.Top + AMetrics.CellHeight;
end;

class function TFindBarMath.FormatFindCounter(ACurrent, ATotal: Integer): string;
begin
  if (ATotal <= 0) or (ACurrent <= 0) then
    Result := ''
  else
    Result := Format('%d/%d', [ACurrent, ATotal]);
end;

class function TFindBarMath.ComputeFindOverlayRect(const AClientRect: TRect;
  const AOverlayW, AOverlayH, AMargin: Integer): TRect;
var
  LClientW, LClientH, LWidth, LHeight: Integer;
begin
  LClientW := AClientRect.Right - AClientRect.Left;
  LClientH := AClientRect.Bottom - AClientRect.Top;

  // The overlay can never exceed the client minus both margins; clamp the
  // size first so the anchored rect always sits fully inside AClientRect.
  LWidth := AOverlayW;
  if LWidth > LClientW - 2 * AMargin then
    LWidth := LClientW - 2 * AMargin;
  if LWidth < 0 then
    LWidth := 0;

  LHeight := AOverlayH;
  if LHeight > LClientH - 2 * AMargin then
    LHeight := LClientH - 2 * AMargin;
  if LHeight < 0 then
    LHeight := 0;

  // Top-right anchor, inset by the margin on every clamped edge.
  Result.Right := AClientRect.Right - AMargin;
  Result.Left := Result.Right - LWidth;
  if Result.Left < AClientRect.Left + AMargin then
    Result.Left := AClientRect.Left + AMargin;
  // A client smaller than twice the margin cannot honor both insets; never let
  // the left clamp cross the right edge (no inverted/negative-width rect).
  if Result.Left > Result.Right then
    Result.Left := Result.Right;
  Result.Top := AClientRect.Top + AMargin;
  Result.Bottom := Result.Top + LHeight;
end;

{ TFindBar }

constructor TFindBar.Create(const AOwnerForm: TCustomForm; const APnlFind: TPanel;
  const AEdtFind: TEdit; const ABtnNext, ABtnPrev: TSpeedButton;
  const AChkCase: TCheckBox; const ALblCount: TLabel;
  const APgcTerminals: TWinControl;
  const AGetFocusedView: TFunc<TAefosTerminalTerminalView>);
begin
  inherited Create;
  FPnlFind := APnlFind;
  FEdtFind := AEdtFind;
  FChkCase := AChkCase;
  FLblCount := ALblCount;
  FPgcTerminals := APgcTerminals;
  FGetFocusedView := AGetFocusedView;

  // V.8 (ESP-065 / ADR-065-03): subclass the find overlay so it paints the
  // uniform keyboard-focus ring around edtFind. Same WindowProc-swap pattern
  // the form's Create used (and previously used for lstTerminals).
  if Assigned(FPnlFind) then
  begin
    FOriginalFindWP := FPnlFind.WindowProc;
    FPnlFind.WindowProc := SubclassWP;
  end;
end;

destructor TFindBar.Destroy;
begin
  // Restore the pnlFind WindowProc before the form's inherited destructor frees the
  // panel. The form frees this helper ahead of inherited, so the restore lands in time.
  // (The old form omitted this restore — extracting it here fixes that latent asymmetry.)
  if Assigned(FPnlFind) and Assigned(FOriginalFindWP) then
    FPnlFind.WindowProc := FOriginalFindWP;
  inherited;
end;

procedure TFindBar.ShowFind(Sender: TObject);
var
  LView: TAefosTerminalTerminalView;
begin
  // Ctrl+F routes here with Sender=nil (keyboard); the toolbar glyph passes its
  // own instance (mouse). Drive the focus-ring mode from that distinction (V.8).
  FFindKeyboardNav := not Assigned(Sender);
  FPnlFind.Visible := not FPnlFind.Visible;
  if FPnlFind.Visible then
  begin
    AnchorOverlay;
    FPnlFind.Invalidate;
    if not IsConsole and FEdtFind.CanFocus then
    begin
      FEdtFind.SetFocus;
      FEdtFind.SelectAll;
    end;
  end
  else
  begin
    LView := FGetFocusedView();
    if Assigned(LView) and not IsConsole and LView.CanFocus then
      LView.SetFocus;
  end;
end;

procedure TFindBar.FindChanged;
var
  LView: TAefosTerminalTerminalView;
begin
  LView := FGetFocusedView();
  if Assigned(LView) then
  begin
    if FEdtFind.Text = '' then
      FEdtFind.Font.Color := clWindowText
    else if LView.FindText(FEdtFind.Text, True, FChkCase.Checked) then
      FEdtFind.Font.Color := clWindowText
    else
      FEdtFind.Font.Color := clRed;
  end;
  _UpdateFindCounter;
end;

procedure TFindBar.FindNext;
var
  LView: TAefosTerminalTerminalView;
begin
  LView := FGetFocusedView();
  if Assigned(LView) then
  begin
    if FEdtFind.Text = '' then
      FEdtFind.Font.Color := clWindowText
    else if LView.FindText(FEdtFind.Text, True, FChkCase.Checked) then
      FEdtFind.Font.Color := clWindowText
    else
      FEdtFind.Font.Color := clRed;
  end;
  _UpdateFindCounter;
end;

procedure TFindBar.FindPrev;
var
  LView: TAefosTerminalTerminalView;
begin
  LView := FGetFocusedView();
  if Assigned(LView) then
  begin
    if FEdtFind.Text = '' then
      FEdtFind.Font.Color := clWindowText
    else if LView.FindText(FEdtFind.Text, False, FChkCase.Checked) then
      FEdtFind.Font.Color := clWindowText
    else
      FEdtFind.Font.Color := clRed;
  end;
  _UpdateFindCounter;
end;

procedure TFindBar._UpdateFindCounter;
var
  LTotal, LCurrent: Integer;
  LView: TAefosTerminalTerminalView;
begin
  // Guard the headless path: the label is DFM-bound, so a freshly-Create'd
  // form in a unit test exposes it; but defensive nil-check keeps a future
  // code-only construction path safe (BR3, ADR-055-03).
  if not Assigned(FLblCount) then
    Exit;
  LView := FGetFocusedView();
  if (FEdtFind.Text = '') or not Assigned(LView) then
  begin
    FLblCount.Caption := '';
    Exit;
  end;
  LTotal := LView.CountFindMatches(FEdtFind.Text, FChkCase.Checked);
  LCurrent := LView.FindCurrentMatchIndex(FEdtFind.Text, FChkCase.Checked);
  FLblCount.Caption := TFindBarMath.FormatFindCounter(LCurrent, LTotal);
end;

procedure TFindBar.AnchorOverlay;
var
  LRect: TRect;
  LRgn: HRGN;
begin
  if not Assigned(FPnlFind) or not Assigned(FPgcTerminals) then
    Exit;
  // Float the overlay at the top-right of the terminal area with an 8px margin
  // (A2). pgcTerminals shares the form client coordinate space with pnlFind,
  // so its BoundsRect is the anchor frame.
  LRect := TFindBarMath.ComputeFindOverlayRect(FPgcTerminals.BoundsRect, FPnlFind.Width,
    FPnlFind.Height, 8);
  FPnlFind.BoundsRect := LRect;
  FPnlFind.BringToFront;
  // Rounded-card silhouette. SetWindowRgn takes ownership of the region handle,
  // so it must not be freed here.
  if FPnlFind.HandleAllocated then
  begin
    LRgn := CreateRoundRectRgn(0, 0, FPnlFind.Width + 1, FPnlFind.Height + 1, 12, 12);
    SetWindowRgn(FPnlFind.Handle, LRgn, True);
  end;
end;

procedure TFindBar.ApplyTheme;
var
  {$IF Declared(IOTAIDEThemingServices)}
  LTheming: IOTAIDEThemingServices;
  {$IFEND}
  LStyle: TCustomStyleServices;
  LSurface, LText, LField: TColor;
begin
  if not Assigned(FPnlFind) then
    Exit;

  // Surface tracks the IDE chrome (BR2/BR5); the accent stays reserved for the
  // active-pane outline and focus cues, so the overlay does not compete with it.
  LStyle := nil;
  // No theming service on an IDE without themes (10 Seattle): LStyle stays nil and the designed colours are used.
  {$IF Declared(IOTAIDEThemingServices)}
  if Assigned(BorlandIDEServices) and
     Supports(BorlandIDEServices, IOTAIDEThemingServices, LTheming) and
     LTheming.IDEThemingEnabled then
    LStyle := LTheming.GetIDEStyleServices;
  {$IFEND}

  LSurface := TVisualSurfaces.ChromeBackground(LStyle);
  if Assigned(LStyle) then
  begin
    LText := LStyle.GetSystemColor(clWindowText);
    LField := LStyle.GetStyleColor(scEdit);
  end
  else
  begin
    LText := clWindowText;
    LField := clWindow;
  end;

  FPnlFind.ParentBackground := False;
  FPnlFind.ParentColor := False;
  FPnlFind.BevelOuter := bvNone;
  FPnlFind.Color := LSurface;

  if Assigned(FEdtFind) then
  begin
    FEdtFind.Color := LField;
    FEdtFind.Font.Color := LText;
  end;
  if Assigned(FChkCase) then
  begin
    FChkCase.ParentColor := False;
    FChkCase.Color := LSurface;
    FChkCase.Font.Color := LText;
  end;
  if Assigned(FLblCount) then
  begin
    FLblCount.Transparent := True;
    FLblCount.Font.Color := LText;
  end;
end;

procedure TFindBar.SubclassWP(var Message: TMessage);
var
  LCanvas: TControlCanvas;
begin
  if Assigned(FOriginalFindWP) then
    FOriginalFindWP(Message);
  // After the overlay paints, draw the uniform V.8 focus ring around the find
  // box when it holds keyboard focus (ESP-065 / ADR-065-03). The decision is
  // centralized in TAccessibility.ShouldDrawFocusRing; mouse-driven find shows
  // no ring.
  if (Message.Msg = WM_PAINT) and Assigned(FPnlFind) and Assigned(FEdtFind) and
     TAccessibility.ShouldDrawFocusRing(FEdtFind.Focused, FFindKeyboardNav) then
  begin
    LCanvas := TControlCanvas.Create;
    try
      LCanvas.Control := FPnlFind;
      DrawAefosTerminalFocusRing(LCanvas, FPnlFind.ClientRect);
    finally
      LCanvas.Free;
    end;
  end;
end;

procedure TFindBar.KeyDown(var Key: Word; Shift: TShiftState);
var
  LView: TAefosTerminalTerminalView;
begin
  // Typing/navigating in the find box is keyboard interaction → show the ring.
  FFindKeyboardNav := True;
  if Assigned(FPnlFind) then
    FPnlFind.Invalidate;
  case Key of
    VK_RETURN:
    begin
      if ssShift in Shift then
        FindPrev
      else
        FindNext;
      Key := 0;
    end;
    VK_ESCAPE:
    begin
      FPnlFind.Visible := False;
      LView := FGetFocusedView();
      if Assigned(LView) and LView.CanFocus then
        LView.SetFocus;
      Key := 0;
    end;
  end;
end;

procedure TFindBar.HandleShortcuts(var Key: Word; Shift: TShiftState);
begin
  if Key = Ord('F') then
  begin
    if not FPnlFind.Visible then
      ShowFind(nil)
    else
    begin
      FEdtFind.SetFocus;
      FEdtFind.SelectAll;
    end;
    Key := 0;
  end
  else if Key = VK_F3 then
  begin
    if ssShift in Shift then
      FindPrev
    else
      FindNext;
    Key := 0;
  end;
end;

end.
