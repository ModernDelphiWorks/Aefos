unit Aefos.OTA.UI.ThemeHelper;

{
  Central theming helper (ADR-099, ADR-100, ADR-101).

  ApplyPremiumTheme queries the active IDE StyleServices (via IOTAIDEThemingServices250)
  and copies its exact system colors onto every child control recursively, so that
  all modal dialogs (TConfigDialogForm, TMCPConsentDialog, etc.) inherit the native
  Delphi IDE color palette — including the slate-blue/gray dark theme — without
  any hardcoded magic numbers.

  Fallback: when StyleServices are unavailable (unit tests, design time) the
  function falls back to a static premium dark/light palette derived from the
  form's current background luminance.
}

interface

uses
  Vcl.Forms;

type
  // Central theming helper as a sealed static namespace (ADR-099, ADR-100,
  // ADR-101). The class is the namespace — never instantiated. Shared cross-BPL
  // by the chat dialogs AND the MCP-side dialogs (consent/options/issue/pytools).
  TThemeHelper = class sealed
  public
    // Automatically themes a form and all its child controls recursively
    // to perfectly match the active Delphi IDE color theme.
    class procedure ApplyPremiumTheme(AForm: TCustomForm); static;
  end;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.UITypes,
  Vcl.Controls,
  Vcl.Graphics,
  Vcl.Themes,
  Vcl.StdCtrls,
  Vcl.ExtCtrls,
  ToolsAPI;

// ---------------------------------------------------------------------------
// Internal: apply theme colors recursively to one control and its children
// ---------------------------------------------------------------------------
procedure _ThemeControlRecursive(AControl: TControl;
  ABgColor, ATextColor, ASecondaryColor: TColor);
var
  LIndex: Integer;
  LWinControl: TWinControl;
begin
  if not Assigned(AControl) then
    Exit;

  // 1. Theme the control itself based on its class
  if AControl is TLabel then
  begin
    // Preserve explicit error/highlight color assignments (e.g. clRed, $003F3FFF)
    if (TLabel(AControl).Font.Color <> clRed) and
       (TLabel(AControl).Font.Color <> $003F3FFF) then
      TLabel(AControl).Font.Color := ATextColor;
  end
  else if AControl is TLabeledEdit then
  begin
    TLabeledEdit(AControl).StyleElements := [seFont];
    TLabeledEdit(AControl).Color := ABgColor;
    TLabeledEdit(AControl).Font.Color := ATextColor;
    TLabeledEdit(AControl).EditLabel.Font.Color := ASecondaryColor;
  end
  else if AControl is TEdit then
  begin
    TEdit(AControl).StyleElements := [seFont];
    TEdit(AControl).Color := ABgColor;
    TEdit(AControl).Font.Color := ATextColor;
  end
  else if AControl is TMemo then
  begin
    TMemo(AControl).StyleElements := [seFont];
    TMemo(AControl).Color := ABgColor;
    TMemo(AControl).Font.Color := ATextColor;
  end
  else if AControl is TComboBox then
  begin
    TComboBox(AControl).StyleElements := [seFont];
    TComboBox(AControl).Color := ABgColor;
    TComboBox(AControl).Font.Color := ATextColor;
  end
  else if AControl is TListBox then
  begin
    TListBox(AControl).StyleElements := [seFont];
    TListBox(AControl).Color := ABgColor;
    TListBox(AControl).Font.Color := ATextColor;
  end
  else if AControl is TPanel then
  begin
    // TPanel participates in the IDE StyleServices recursion naturally;
    // no explicit Color override needed here.
    TPanel(AControl).StyleElements := [seFont];
  end;

  // 2. Recurse into children if it is a WinControl
  if AControl is TWinControl then
  begin
    LWinControl := TWinControl(AControl);
    for LIndex := 0 to LWinControl.ControlCount - 1 do
      _ThemeControlRecursive(LWinControl.Controls[LIndex],
        ABgColor, ATextColor, ASecondaryColor);
  end;
end;

// ---------------------------------------------------------------------------
// Public: query IDE StyleServices and theme the form + all children
// ---------------------------------------------------------------------------
class procedure TThemeHelper.ApplyPremiumTheme(AForm: TCustomForm);
var
  LIsDark: Boolean;
  LBgColor, LTextColor, LSecondaryColor: TColor;
  {$IF Declared(IOTAIDEThemingServices250)}
  LTheming: IOTAIDEThemingServices250;
  {$IFEND}
  LStyle: TCustomStyleServices;
  LThemeName: string;
  LIndex: Integer;
begin
  if not Assigned(AForm) then
    Exit;

  LStyle := nil;
  LIsDark := False;
  LThemeName := '';
  LBgColor := 0;
  LTextColor := 0;
  LSecondaryColor := 0;

  // ── Step 1: try to get the native IDE StyleServices ─────────────────────
  //
  // IDE theming is not universal: IOTAIDEThemingServices250 does not exist in
  // 10 Seattle's ToolsAPI, because that IDE had no themes to expose. Declared()
  // asks the ToolsAPI in hand instead of encoding which release introduced it.
  //
  // Nothing is lost where it is absent - Step 2 below already derives dark/light
  // from the form's own luminance, which is exactly the path taken today when
  // the service exists but theming is switched off.
  {$IF Declared(IOTAIDEThemingServices250)}
  if Assigned(BorlandIDEServices) and
     Supports(BorlandIDEServices, IOTAIDEThemingServices250, LTheming) then
  begin
    try
      LThemeName := LTheming.GetActiveThemeName;
      LIsDark := LThemeName.ToLower.Contains('dark');
      if LTheming.GetIDEThemingEnabled then
        LStyle := LTheming.GetIDEStyleServices;
    except
      LStyle := nil;
    end;
  end;
  {$IFEND}

  // ── Step 2: derive luminance fallback when StyleServices unavailable ─────
  if (not Assigned(LStyle)) and (AForm.Color <> clNone) then
  begin
    LIsDark := ((0.299 * GetRValue(ColorToRGB(AForm.Color))) +
                (0.587 * GetGValue(ColorToRGB(AForm.Color))) +
                (0.114 * GetBValue(ColorToRGB(AForm.Color)))) < 128;
  end;

  // ── Step 3: resolve colors from StyleServices (native IDE palette) ───────
  if Assigned(LStyle) then
  begin
    try
      AForm.Color         := LStyle.GetSystemColor(clBtnFace);
      LBgColor            := LStyle.GetStyleColor(scEdit);
      LTextColor          := LStyle.GetSystemColor(clWindowText);
      LSecondaryColor     := LStyle.GetSystemColor(clGrayText);
    except
      // StyleServices call failed — fallback below
      LStyle := nil;
    end;
  end;

  // ── Step 4: static premium palette fallback ──────────────────────────────
  if not Assigned(LStyle) then
  begin
    if LIsDark then
    begin
      AForm.Color     := $00252526; // VS Dark-style charcoal
      LBgColor        := $00333337; // Slightly lighter for inputs
      LTextColor      := $00F1F1F1; // Near-white, high contrast
      LSecondaryColor := $00A5A0A0; // Muted secondary text
    end
    else
    begin
      AForm.Color     := $00F5F5F5; // Clean near-white background
      LBgColor        := $00FFFFFF; // White inputs
      LTextColor      := $00121212; // Near-black text
      LSecondaryColor := $00606060; // Muted secondary text
    end;
  end;

  // ── Step 5: propagate to all child controls recursively ──────────────────
  for LIndex := 0 to AForm.ControlCount - 1 do
    _ThemeControlRecursive(AForm.Controls[LIndex],
      LBgColor, LTextColor, LSecondaryColor);
end;

end.
