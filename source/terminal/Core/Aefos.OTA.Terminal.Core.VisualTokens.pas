unit Aefos.OTA.Terminal.Core.VisualTokens;

{
  Centralized visual-token source for Aefos.OTA.Terminal chrome (ESP-057 / ADR-057-01).

  Split in two parts:

  - TVisualTokens: the PURE resolver. No VCL painting, no StyleServices,
    no live-IDE dependency. Returns TColor values for the accent, the
    shell-profile dot colors, the status colors and the dark/light cursor
    fallback. This is the headless-testable portion (target >= 80% coverage).

  - TVisualSurfaces: StyleServices-bound helpers used only by paint code at
    paint time. They read the IDE's live style so the chrome tracks the
    locked "Delphi IDE" theme (BR2/BR5). Because they need a live style they
    are exercised only through owner-draw paint code and fall under the VCL
    coverage exemption.

  Every later visual demand (V.1-V.8) consumes this unit instead of
  re-deriving colors. See [[mobaxterm-ux-reference]].
}

interface

uses
  Vcl.Graphics,
  Vcl.Themes;

type
  /// <summary>
  ///   Terminal cursor shape variants (ESP-059 / ADR-059-03).
  ///   V.2 default = <c>csBlock</c>; per-user shape selection deferred to V.7.
  /// </summary>
  TCursorShape = (csBlock, csUnderline, csBar);

  /// <summary>
  ///   Pure resolver for Aefos.OTA.Terminal chrome accents. No VCL painting and no
  ///   <c>StyleServices</c> dependency, so every member is headless-testable.
  /// </summary>
  TVisualTokens = class
  public
    /// <summary>The Embarcadero brand orange accent (RGB 243,112,33 / #F37021).
    /// Used for the active tab accent and the terminal cursor.</summary>
    class function Accent: TColor; static;

    /// <summary>Status color: success / running OK (green).</summary>
    class function StatusOk: TColor; static;
    /// <summary>Status color: warning (amber).</summary>
    class function StatusWarn: TColor; static;
    /// <summary>Status color: error / failure (red).</summary>
    class function StatusError: TColor; static;

    /// <summary>
    ///   Maps a shell-profile name to its dot color (A1 default palette):
    ///   PowerShell = blue, cmd = gray, bash = green, Python = yellow,
    ///   Node = light green. Any unknown / custom profile resolves to
    ///   <see cref="Accent"/>. Matching is case-insensitive and tolerant of
    ///   common aliases (pwsh, powershell, command prompt, ...).
    /// </summary>
    class function ProfileDotColor(const AProfileName: string): TColor; static;

    /// <summary>
    ///   Dark/light-aware cursor color (BR6). Returns <see cref="Accent"/> on
    ///   a dark background; on a light background returns a darker, more
    ///   saturated orange so the block cursor stays legible.
    /// </summary>
    class function ResolveCursorColor(const ABackground: TColor): TColor; static;

    /// <summary>True when <c>AColor</c> reads as a light color
    /// (perceived luminance &gt; 128).</summary>
    class function IsLightColor(const AColor: TColor): Boolean; static;

    /// <summary>
    ///   Lightens (<c>APercent &gt; 0</c>) or darkens (<c>APercent &lt; 0</c>)
    ///   a color by the given percentage toward white / black. Clamped to
    ///   [-100, 100] and to valid channel ranges.
    /// </summary>
    class function Shade(const AColor: TColor; const APercent: Integer): TColor; static;

    /// <summary>Hover variant of a base surface: a subtle lift on dark
    /// surfaces, a subtle dim on light surfaces.</summary>
    class function SurfaceHover(const ABase: TColor): TColor; static;
    /// <summary>Active/pressed variant of a base surface (stronger than
    /// <see cref="SurfaceHover"/>).</summary>
    class function SurfaceActive(const ABase: TColor): TColor; static;

    /// <summary>
    ///   Embarcadero-themed ANSI base-16 palette entry (ESP-059 / ADR-059-02).
    ///   Index 0–7 are standard colors; 8–15 are bright variants. Out-of-range
    ///   (&lt; 0 or &gt; 15) returns <c>clBlack</c>.
    /// </summary>
    class function AnsiColor(const AIndex: Integer): TColor; static;

    /// <summary>
    ///   Default cursor shape for V.2 (ESP-059 / ADR-059-03). Returns
    ///   <c>csBlock</c>; per-user shape selection is deferred to V.7.
    /// </summary>
    class function DefaultCursorShape: TCursorShape; static;
  end;

  /// <summary>
  ///   <c>StyleServices</c>-bound surface helpers. Paint-time only: callers
  ///   pass the IDE's live style so the chrome tracks the locked "Delphi IDE"
  ///   theme. Coverage-exempt (needs a live style; not headless-testable).
  /// </summary>
  TVisualSurfaces = class
  public
    /// <summary>Chrome background level (toolbar / sidebar surface). Falls
    /// back to <c>clBtnFace</c> when <c>AStyle</c> is nil.</summary>
    class function ChromeBackground(const AStyle: TCustomStyleServices): TColor; static;
    /// <summary>Raised panel level. Falls back to <c>clBtnFace</c> when
    /// <c>AStyle</c> is nil.</summary>
    class function PanelSurface(const AStyle: TCustomStyleServices): TColor; static; // NOSONAR — reserved V.1+ surface API (ADR-057-01 chrome panel level); not yet consumed.
    /// <summary>Hover surface derived from the live chrome background.</summary>
    class function HoverSurface(const AStyle: TCustomStyleServices): TColor; static; // NOSONAR — reserved V.1+ surface API (ADR-057-01 chrome hover level); not yet consumed.
    /// <summary>Active surface derived from the live chrome background.</summary>
    class function ActiveSurface(const AStyle: TCustomStyleServices): TColor; static; // NOSONAR — reserved V.1+ surface API (ADR-057-01 chrome active level); not yet consumed.
  end;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.Math;

{ TVisualTokens }

class function TVisualTokens.Accent: TColor;
begin
  // Embarcadero brand orange #F37021 (RGB 243,112,33). ADR-057-01 / A3.
  Result := TColor(RGB(243, 112, 33));
end;

class function TVisualTokens.StatusOk: TColor;
begin
  // Already WCAG-AA on the dark terminal surface (4.94:1) — left untouched (ESP-065/S2).
  Result := TColor(RGB(46, 160, 67));
end;

class function TVisualTokens.StatusWarn: TColor;
begin
  Result := TColor(RGB(219, 154, 4));
end;

class function TVisualTokens.StatusError: TColor;
begin
  // WCAG-AA tuned on the dark terminal surface (ESP-065/S2): (218,54,51) 3.62
  // -> (249,62,58) 4.59. Hue-preserving lightness lift (BR4); stays red.
  Result := TColor(RGB(249, 62, 58));
end;

class function TVisualTokens.ProfileDotColor(const AProfileName: string): TColor;
var
  LName: string;
begin
  LName := LowerCase(Trim(AProfileName));

  if (LName = 'pwsh') or (LName = 'powershell') or LName.StartsWith('powershell') then
    Result := TColor(RGB(1, 120, 215))      // PowerShell blue
  else if (LName = 'cmd') or (LName = 'command prompt') or LName.StartsWith('cmd') then
    Result := TColor(RGB(118, 118, 118))    // Command Prompt gray
  else if (LName = 'bash') or LName.Contains('bash') or LName.Contains('git') then
    Result := TColor(RGB(46, 164, 79))      // bash green
  else if (LName = 'python') or LName.StartsWith('py') then
    Result := TColor(RGB(255, 212, 59))     // Python yellow
  else if (LName = 'node') or LName.Contains('node') then
    Result := TColor(RGB(141, 196, 86))     // Node light green
  else
    Result := Accent;                       // custom / unknown -> accent orange
end;

class function TVisualTokens.IsLightColor(const AColor: TColor): Boolean;
var
  LRGB: Integer;
begin
  LRGB := ColorToRGB(AColor);
  Result := (GetRValue(LRGB) * 299 + GetGValue(LRGB) * 587 +
             GetBValue(LRGB) * 114) > 128000;
end;

class function TVisualTokens.ResolveCursorColor(const ABackground: TColor): TColor;
begin
  if IsLightColor(ABackground) then
    // On a light background the plain accent washes out; darken it so the
    // solid block cursor keeps contrast (BR6).
    Result := Shade(Accent, -28)
  else
    Result := Accent;
end;

class function TVisualTokens.Shade(const AColor: TColor; const APercent: Integer): TColor;
var
  LRGB: Integer;
  LPercent: Integer;
  LRed, LGreen, LBlue: Integer;

  function _Adjust(const AChannel: Integer): Integer;
  begin
    if LPercent >= 0 then
      Result := AChannel + (255 - AChannel) * LPercent div 100
    else
      Result := AChannel + AChannel * LPercent div 100;
    Result := EnsureRange(Result, 0, 255);
  end;

begin
  LPercent := EnsureRange(APercent, -100, 100);
  LRGB := ColorToRGB(AColor);
  LRed := _Adjust(GetRValue(LRGB));
  LGreen := _Adjust(GetGValue(LRGB));
  LBlue := _Adjust(GetBValue(LRGB));
  Result := TColor(RGB(LRed, LGreen, LBlue));
end;

class function TVisualTokens.SurfaceHover(const ABase: TColor): TColor;
begin
  if IsLightColor(ABase) then
    Result := Shade(ABase, -10)
  else
    Result := Shade(ABase, 12);
end;

class function TVisualTokens.SurfaceActive(const ABase: TColor): TColor;
begin
  if IsLightColor(ABase) then
    Result := Shade(ABase, -20)
  else
    Result := Shade(ABase, 24);
end;

class function TVisualTokens.AnsiColor(const AIndex: Integer): TColor;
begin
  // Embarcadero-themed base-16 ANSI palette (ESP-059 / ADR-059-02).
  // Indices 0-7: standard; 8-15: bright variants. Tuned for legibility on
  // dark IDE backgrounds while keeping hue identity (red stays red, etc.).
  case AIndex of
     0: Result := TColor(RGB( 30,  30,  30));  // Black (near-black)
     1: Result := TColor(RGB(190,  55,  54));  // Dark Red (AA-exempt: bright-9 is the AA path)
     2: Result := TColor(RGB( 46, 160,  67));  // Dark Green (AA 4.94:1)
     3: Result := TColor(RGB(197, 140,   0));  // Dark Yellow / Olive
     4: Result := TColor(RGB(  1,  88, 175));  // Dark Blue (AA-exempt: bright-12 is the AA path)
     5: Result := TColor(RGB(128,  50, 180));  // Dark Magenta (AA-exempt: bright-13 is the AA path)
     6: Result := TColor(RGB(  0, 152, 173));  // Dark Cyan (AA 4.84:1)
     7: Result := TColor(RGB(190, 190, 190));  // Light Gray
     8: Result := TColor(RGB( 90,  90,  90));  // Bright Black / Dark Gray
     9: Result := TColor(RGB(240,  80,  80));  // Bright Red
    10: Result := TColor(RGB( 80, 200, 100));  // Bright Green
    11: Result := TColor(RGB(243, 178,  50));  // Bright Yellow (near Embarcadero accent)
    12: Result := TColor(RGB( 60, 140, 230));  // Bright Blue
    13: Result := TColor(RGB(200,  80, 240));  // Bright Magenta
    14: Result := TColor(RGB( 50, 210, 210));  // Bright Cyan
    15: Result := TColor(RGB(240, 240, 240));  // Bright White
  else
    Result := clBlack;
  end;
end;

class function TVisualTokens.DefaultCursorShape: TCursorShape;
begin
  Result := csBlock;
end;

{ TVisualSurfaces }

class function TVisualSurfaces.ChromeBackground(const AStyle: TCustomStyleServices): TColor;
begin
  if Assigned(AStyle) then
    Result := AStyle.GetSystemColor(clBtnFace)
  else
    Result := clBtnFace;
end;

class function TVisualSurfaces.PanelSurface(const AStyle: TCustomStyleServices): TColor;
begin
  if Assigned(AStyle) then
    Result := AStyle.GetSystemColor(clWindow)
  else
    Result := clBtnFace;
end;

class function TVisualSurfaces.HoverSurface(const AStyle: TCustomStyleServices): TColor;
begin
  Result := TVisualTokens.SurfaceHover(ChromeBackground(AStyle));
end;

class function TVisualSurfaces.ActiveSurface(const AStyle: TCustomStyleServices): TColor;
begin
  Result := TVisualTokens.SurfaceActive(ChromeBackground(AStyle));
end;

end.


