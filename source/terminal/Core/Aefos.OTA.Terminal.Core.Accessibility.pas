unit Aefos.OTA.Terminal.Core.Accessibility;

{
  WCAG 2.x accessibility primitives for Aefos.OTA.Terminal chrome (ESP-065 / ADR-065-01).

  Pure, headless-testable unit. Holds the relative-luminance / contrast-ratio /
  AA-threshold math, a palette audit over the shipped TVisualTokens colors, and
  the keyboard-focus-ring decision. VCL imports are limited to Vcl.Graphics
  (TColor) per BR1 — no StyleServices, no ToolsAPI. Live IDE state (focus,
  keyboard-vs-mouse navigation) is read in the form layer and passed in.

  This is a DISTINCT formula from TVisualTokens.IsLightColor (ADR-065-01):
  IsLightColor uses perceived luminance (299/587/114) for cursor legibility and
  is left untouched; WCAG contrast requires linearized-sRGB relative luminance.
  See [[mobaxterm-ux-reference]].
}

interface

uses
  Vcl.Graphics;

type
  /// <summary>
  ///   One audited palette token: its color, the background it was measured
  ///   against, the resulting WCAG contrast ratio, which AA threshold applies
  ///   (<c>LargeOrUi</c>), whether it passes, and whether it is a documented
  ///   intentional exemption (dim base index that cannot reach AA without
  ///   breaking the base/bright hue hierarchy — ADR-065-01 / BR4).
  /// </summary>
  TContrastFinding = record
    TokenId: Integer;
    TokenName: string;
    Color: TColor;
    Background: TColor;
    Ratio: Double;
    LargeOrUi: Boolean;
    Passes: Boolean;
    Exempt: Boolean;
  end;

  /// <summary>
  ///   Pure WCAG 2.x accessibility resolver. Every member is headless-testable
  ///   (BR2). No VCL painting and no <c>StyleServices</c> dependency.
  /// </summary>
  TAccessibility = class
  public
    /// <summary>WCAG 2.x linearized-sRGB relative luminance (0.0..1.0).</summary>
    class function RelativeLuminance(const AColor: TColor): Double; static;

    /// <summary>WCAG contrast ratio between two colors: <c>(L1+0.05)/(L2+0.05)</c>,
    /// range 1.0..21.0. Order-independent.</summary>
    class function ContrastRatio(const AForeground, ABackground: TColor): Double; static;

    /// <summary>WCAG AA threshold test: <c>>= 4.5</c> for normal text,
    /// <c>>= 3.0</c> for large text / UI components.</summary>
    class function MeetsWcagAA(const ARatio: Double; const ALargeOrUi: Boolean): Boolean; static;

    /// <summary>
    ///   Audits the shipped TVisualTokens palette (ANSI base-16, the three
    ///   status colors, the accent, and the profile-dot colors) against a given
    ///   background. ANSI and status entries use the normal-text bar; accent and
    ///   profile dots use the large/UI bar. Dim base ANSI indices that cannot
    ///   reach AA without collapsing into their bright sibling are flagged
    ///   <c>Exempt</c> (BR4 / R1).
    /// </summary>
    class function AuditPalette(const ABackground: TColor): TArray<TContrastFinding>; static;

    /// <summary>
    ///   Focus-affordance decision (ADR-065-03): a focus ring is drawn only when
    ///   the surface has focus AND that focus arrived via keyboard navigation —
    ///   never on mouse-only interaction.
    /// </summary>
    class function ShouldDrawFocusRing(const AHasFocus, AKeyboardNavigation: Boolean): Boolean; static;
  end;

const
  /// <summary>WCAG AA contrast minimum for normal text.</summary>
  WCAG_AA_NORMAL = 4.5;
  /// <summary>WCAG AA contrast minimum for large text / UI components.</summary>
  WCAG_AA_LARGE = 3.0;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.Math,
  Aefos.OTA.Terminal.Core.VisualTokens;

{ TAccessibility }

class function TAccessibility.RelativeLuminance(const AColor: TColor): Double;
var
  LRgb: DWORD;

  function _Channel(const AValue: Byte): Double;
  var
    LChannel: Double;
  begin
    LChannel := AValue / 255.0;
    if LChannel <= 0.03928 then
      Result := LChannel / 12.92
    else
      Result := Power((LChannel + 0.055) / 1.055, 2.4);
  end;

begin
  LRgb := DWORD(ColorToRGB(AColor));
  Result := 0.2126 * _Channel(GetRValue(LRgb))
          + 0.7152 * _Channel(GetGValue(LRgb))
          + 0.0722 * _Channel(GetBValue(LRgb));
end;

class function TAccessibility.ContrastRatio(const AForeground, ABackground: TColor): Double;
var
  LFg, LBg, LHi, LLo: Double;
begin
  LFg := RelativeLuminance(AForeground);
  LBg := RelativeLuminance(ABackground);
  if LFg >= LBg then
  begin
    LHi := LFg;
    LLo := LBg;
  end
  else
  begin
    LHi := LBg;
    LLo := LFg;
  end;
  Result := (LHi + 0.05) / (LLo + 0.05);
end;

class function TAccessibility.MeetsWcagAA(const ARatio: Double; const ALargeOrUi: Boolean): Boolean;
begin
  if ALargeOrUi then
    Result := ARatio >= WCAG_AA_LARGE
  else
    Result := ARatio >= WCAG_AA_NORMAL;
end;

class function TAccessibility.AuditPalette(const ABackground: TColor): TArray<TContrastFinding>;
const
  // Dim base ANSI indices intentionally below AA on the dark surface (BR4 / R1):
  //   0 = near-black (the terminal background family itself);
  //   1 = dark red, 4 = dark blue, 5 = dark magenta — lifting to AA collapses
  //       them into their bright siblings (9/12/13), which ARE the AA-legible path;
  //   8 = bright-black / dim gray — the deliberately faint "dim" color.
  CExemptAnsi: array[0..4] of Integer = (0, 1, 4, 5, 8);
var
  LFindings: TArray<TContrastFinding>;
  LCount: Integer;
  LIndex: Integer;

  function _IsExemptAnsi(const AIndex: Integer): Boolean;
  var
    LFor: Integer;
  begin
    Result := False;
    for LFor := Low(CExemptAnsi) to High(CExemptAnsi) do
      if CExemptAnsi[LFor] = AIndex then
        Exit(True);
  end;

  procedure _Add(const AId: Integer; const AName: string; const AColor: TColor;
    const ALargeOrUi, AExempt: Boolean);
  var
    LFinding: TContrastFinding;
  begin
    LFinding.TokenId := AId;
    LFinding.TokenName := AName;
    LFinding.Color := AColor;
    LFinding.Background := ABackground;
    LFinding.Ratio := ContrastRatio(AColor, ABackground);
    LFinding.LargeOrUi := ALargeOrUi;
    LFinding.Passes := MeetsWcagAA(LFinding.Ratio, ALargeOrUi);
    LFinding.Exempt := AExempt;
    LFindings[LCount] := LFinding;
    Inc(LCount);
  end;

begin
  // 16 ANSI + 3 status + 1 accent + 5 profile dots = 25 audited tokens.
  SetLength(LFindings, 25);
  LCount := 0;

  for LIndex := 0 to 15 do
    _Add(LIndex, Format('ANSI%d', [LIndex]), TVisualTokens.AnsiColor(LIndex),
      False, _IsExemptAnsi(LIndex));

  _Add(16, 'StatusOk', TVisualTokens.StatusOk, False, False);
  _Add(17, 'StatusWarn', TVisualTokens.StatusWarn, False, False);
  _Add(18, 'StatusError', TVisualTokens.StatusError, False, False);

  _Add(19, 'Accent', TVisualTokens.Accent, True, False);

  _Add(20, 'ProfileDot:pwsh', TVisualTokens.ProfileDotColor('pwsh'), True, False);
  _Add(21, 'ProfileDot:cmd', TVisualTokens.ProfileDotColor('cmd'), True, False);
  _Add(22, 'ProfileDot:bash', TVisualTokens.ProfileDotColor('bash'), True, False);
  _Add(23, 'ProfileDot:python', TVisualTokens.ProfileDotColor('python'), True, False);
  _Add(24, 'ProfileDot:node', TVisualTokens.ProfileDotColor('node'), True, False);

  Result := LFindings;
end;

class function TAccessibility.ShouldDrawFocusRing(const AHasFocus, AKeyboardNavigation: Boolean): Boolean;
begin
  Result := AHasFocus and AKeyboardNavigation;
end;

end.


