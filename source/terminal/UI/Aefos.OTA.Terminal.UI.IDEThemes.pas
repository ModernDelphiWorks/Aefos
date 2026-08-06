unit Aefos.OTA.Terminal.UI.IDEThemes;

interface

uses
  System.Types,
  Vcl.Forms,
  Vcl.Graphics;

// Applies the IDE's active theme to AForm and all its owned components.
// On dark themes, also patches TEdit/TMemo/TListView backgrounds that
// IOTAIDEThemingServices250.ApplyTheme misses on standalone (non-dockable) forms.
procedure ApplyAefosTerminalIDETheme(AForm: TCustomForm);

// Draws the uniform Aefos.OTA.Terminal keyboard-focus ring: a 2px TVisualTokens.Accent
// frame inset 1px inside ARect. Shared by every V.8 surface (ESP-065 / V.8 /
// ADR-065-03) so the affordance is identical across Command Palette, Snippets
// sidebar, Find overlay, Welcome cards, and the Snippet editor (BR5). The
// keyboard-vs-mouse DECISION lives in TAccessibility.ShouldDrawFocusRing; this
// helper only renders the agreed ring once that decision returns True.
procedure DrawAefosTerminalFocusRing(const ACanvas: TCanvas; const ARect: TRect);

implementation

uses
  Winapi.Windows,
  Winapi.UxTheme,
  System.SysUtils,
  System.Classes,
  Vcl.Themes,
  Vcl.Controls,
  Vcl.StdCtrls,
  Vcl.ExtCtrls,
  Vcl.ComCtrls,
  ToolsAPI,
  Aefos.OTA.Terminal.Core.VisualTokens;

procedure DrawAefosTerminalFocusRing(const ACanvas: TCanvas; const ARect: TRect);
var
  LRing: TRect;
begin
  if not Assigned(ACanvas) then
    Exit;
  LRing := ARect;
  InflateRect(LRing, -1, -1);
  ACanvas.Brush.Style := bsClear;
  ACanvas.Pen.Color := TVisualTokens.Accent;
  ACanvas.Pen.Width := 2;
  ACanvas.Pen.Style := psSolid;
  ACanvas.Rectangle(LRing);
  // Leave the canvas brush solid again so callers that keep painting after the
  // ring (owner-draw item handlers) are not surprised by a cleared brush.
  ACanvas.Brush.Style := bsSolid;
end;

(*
  Everything from here down to ApplyAefosTerminalIDETheme depends on the IDE
  theming service. 10 Seattle has no such service - that IDE had no themes at
  all - so on it this block does not exist and the procedure below is a no-op:
  the form keeps the stock VCL colours, which is what every other window in
  that IDE looks like anyway.

  Declared() asks the ToolsAPI in hand rather than encoding which release
  introduced theming. DrawAefosTerminalFocusRing above is deliberately OUTSIDE
  the guard: it paints with our own tokens and owes nothing to the IDE theme.
*)
{$IF Declared(IOTAIDEThemingServices250)}

function _IsDark(const AColor: TColor): Boolean;
var
  LRGB: TColor;
begin
  LRGB := ColorToRGB(AColor);
  Result := (GetRValue(LRGB) * 299 + GetGValue(LRGB) * 587 + GetBValue(LRGB) * 114) < 128000;
end;

// Primary: use ActiveTheme name. Fallback: check form background luminance.
// Name-based check is reliable; luminance catches renamed/custom dark themes.
function _IsIDEDark(const ATheming: IOTAIDEThemingServices250;
  AFormAfterApply: TCustomForm): Boolean;
var
  LName: string;
begin
  LName := LowerCase(ATheming.ActiveTheme);
  if (Pos('light', LName) > 0) or (Pos('mountain', LName) > 0) or
     (LName = 'windows') or (LName = 'campbell') then
  begin
    Result := False;
    Exit;
  end;
  // Theme name does not say "light" — assume dark unless the form's own
  // background colour (set by ApplyTheme) contradicts it.
  if (AFormAfterApply.Color <> clBtnFace) and (AFormAfterApply.Color > 0) then
    Result := _IsDark(AFormAfterApply.Color)
  else
    Result := True;
end;

procedure _RegisterThemeFormClass(const ATheming: IOTAIDEThemingServices250;
  AForm: TCustomForm);
begin
  // Tell the IDE theme engine about this form class so future instances and
  // theme-changed events are handled automatically.
  try
    ATheming.RegisterFormClass(TCustomFormClass(AForm.ClassType));
  except
    on E: Exception do
      OutputDebugString(PChar('[Aefos.OTA.Terminal] RegisterFormClass: ' + E.ClassName + ' - ' + E.Message));
  end;
end;

procedure _ApplyThemeRecursive(const ATheming: IOTAIDEThemingServices250;
  AForm: TCustomForm);
var
  LIndex: Integer;
  LComp: TComponent;
begin
  // Let the OTA engine paint its standard theme onto the form and every owned
  // component (handles TTreeView, TToolBar, TSpeedButton, etc.).
  try
    ATheming.ApplyTheme(AForm);
    for LIndex := 0 to Pred(AForm.ComponentCount) do
    begin
      LComp := AForm.Components[LIndex];
      if LComp is TPanel then
        TPanel(LComp).ParentBackground := True;
      ATheming.ApplyTheme(LComp);
    end;
  except
    on E: Exception do
      OutputDebugString(PChar('[Aefos.OTA.Terminal] ApplyIDETheme: ' + E.ClassName + ' - ' + E.Message));
  end;
end;

procedure _ResolveDarkPalette(const ATheming: IOTAIDEThemingServices250;
  out AFormBg, AInputBg, AFgColor: TColor);
var
  LStyle: TCustomStyleServices;
begin
  // Resolve colors: prefer the IDE's live StyleServices (adapts to any theme);
  // fall back to VS-Dark-style constants when the IDE does not use VCL styles.
  LStyle := ATheming.StyleServices;
  if Assigned(LStyle) then
  begin
    AFormBg  := LStyle.GetSystemColor(clBtnFace);
    AInputBg := LStyle.GetSystemColor(clWindow);
    AFgColor := LStyle.GetSystemColor(clWindowText);
    if _IsDark(AFormBg) then
      Exit;
  end;
  // StyleServices absent or returned a light palette despite a dark theme name:
  // the IDE uses its own non-VCL paint engine — fall back to hardcoded values.
  AFormBg  := TColor($252526);
  AInputBg := TColor($3C3C3C);
  AFgColor := TColor($D4D4D4);
end;

procedure _PatchComponentForDark(AComp: TComponent;
  AInputBg, AFormBg, AFgColor: TColor);
begin
  // Manually fix controls that ApplyTheme does not fully cover on standalone
  // TForms (non-dockable). TEdit/TMemo: SetWindowTheme('','') detaches the
  // UxTheme renderer so the Color property is respected.
  if AComp is TEdit then
  begin
    TEdit(AComp).Color      := AInputBg;
    TEdit(AComp).Font.Color := AFgColor;
    if IsWindow(TEdit(AComp).Handle) then
      SetWindowTheme(TEdit(AComp).Handle, '', '');
  end
  else if AComp is TMemo then
  begin
    TMemo(AComp).Color      := AInputBg;
    TMemo(AComp).Font.Color := AFgColor;
    if IsWindow(TMemo(AComp).Handle) then
      SetWindowTheme(TMemo(AComp).Handle, '', '');
  end
  else if AComp is TLabel then
    TLabel(AComp).Font.Color := AFgColor
  else if AComp is TCheckBox then
    TCheckBox(AComp).Font.Color := AFgColor
  else if AComp is TListView then
  begin
    TListView(AComp).Color      := AInputBg;
    TListView(AComp).Font.Color := AFgColor;
  end
  else if AComp is TPanel then
    TPanel(AComp).Color := AFormBg;
end;

procedure ApplyAefosTerminalIDETheme(AForm: TCustomForm);
var
  LTheming: IOTAIDEThemingServices250;
  LFormBg, LInputBg, LFgColor: TColor;
  LIndex: Integer;
begin
  if not Assigned(AForm) then
    Exit;
  if not (Assigned(BorlandIDEServices) and
          Supports(BorlandIDEServices, IOTAIDEThemingServices250, LTheming) and
          LTheming.IDEThemingEnabled) then
    Exit;

  _RegisterThemeFormClass(LTheming, AForm);
  _ApplyThemeRecursive(LTheming, AForm);

  if not _IsIDEDark(LTheming, AForm) then
    Exit;

  _ResolveDarkPalette(LTheming, LFormBg, LInputBg, LFgColor);

  AForm.Color := LFormBg;
  for LIndex := 0 to Pred(AForm.ComponentCount) do
    _PatchComponentForDark(AForm.Components[LIndex], LInputBg, LFormBg, LFgColor);
end;

{$ELSE}

// No IDE theming service on this compiler (see the note above), so the form
// keeps the stock VCL colours. An empty body rather than a guard at every call
// site, so callers stay identical across versions.
procedure ApplyAefosTerminalIDETheme(AForm: TCustomForm);
begin
end;

{$IFEND}

end.



