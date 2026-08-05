unit Aefos.OTA.Terminal.Core.GlyphSupport;

/// <summary>
/// Pure helpers for terminal glyph selection (ESP-081 / ADR-081-01).
///
/// Two concerns, both decoupled from the IDE and any GDI handle so they are
/// headlessly unit-testable:
///   * <c>ClassifyCodepoint</c> — buckets a Unicode codepoint into normal /
///     BMP private-use / supplementary-plane. Used to reason about whether a
///     glyph fits in a single-<c>Char</c> terminal cell (ADR-081-03 / AC9).
///   * <c>NormalizeFontName</c> — maps legacy / Nerd-Font-incapable persisted
///     font names to the embedded <c>CaskaydiaCove NFM</c> face so the canvas
///     realizes a face that actually carries the powerline / BMP-PUA glyphs
///     (ESP-081 S0 root cause; ADR-081-01).
/// </summary>

interface

type
  /// <summary>
  /// Classification of a Unicode codepoint by the region that determines how it
  /// can be stored and rendered in a single-<c>Char</c> terminal cell.
  /// </summary>
  TCodepointClass = (
    /// Ordinary BMP codepoint outside the private-use area.
    ccNormal,
    /// BMP private-use area ($E000..$F8FF) — Nerd Font / powerline glyphs.
    ccBmpPua,
    /// Supplementary plane (> $FFFF) — cannot fit in one UTF-16 code unit.
    ccSupplementary);

const
  /// <summary>The embedded Nerd Font face registered FR_PRIVATE at startup.</summary>
  TERMINAL_NERD_FONT = 'CaskaydiaCove NFM';

  /// <summary>BMP private-use area bounds (inclusive).</summary>
  BMP_PUA_FIRST = $E000;
  BMP_PUA_LAST  = $F8FF;

  /// <summary>Last codepoint representable in a single UTF-16 code unit.</summary>
  BMP_LAST = $FFFF;

type
  /// <summary>Pure glyph-selection helpers grouped as a stateless facade.
  /// Every member is a class-static function — no instance is ever created.</summary>
  TGlyphSupport = class sealed
  public
    /// <summary>
    /// Classifies <c>ACodepoint</c> as normal, BMP private-use, or supplementary.
    /// </summary>
    class function ClassifyCodepoint(const ACodepoint: Cardinal): TCodepointClass; static;

    /// <summary>
    /// Returns the face the terminal canvas should realize for <c>AFontName</c>.
    /// Legacy / Nerd-Font-incapable names (e.g. a persisted <c>Cascadia Code</c>)
    /// are mapped to the embedded <c>CaskaydiaCove NFM</c> face; any other name is
    /// returned unchanged. Comparison is case-insensitive (ESP-081 S0 / ADR-081-01).
    /// </summary>
    class function NormalizeFontName(const AFontName: string): string; static;
  end;

implementation

uses
  System.SysUtils;

const
  // Persisted names known to lack the powerline / BMP-PUA glyph set; every one
  // is normalized to the embedded Nerd Font face. 'Cascadia Code' is the value
  // ESP-081 S0 found persisted in config.ini and missed by the prior migration.
  LEGACY_INCAPABLE_NAMES: array[0..3] of string = (
    'Consolas',
    'Cascadia Code',
    'CaskaydiaCove NF',
    'CaskaydiaCove Nerd Font Mono');

class function TGlyphSupport.ClassifyCodepoint(const ACodepoint: Cardinal): TCodepointClass;
begin
  if ACodepoint > BMP_LAST then
    Result := ccSupplementary
  else if (ACodepoint >= BMP_PUA_FIRST) and (ACodepoint <= BMP_PUA_LAST) then
    Result := ccBmpPua
  else
    Result := ccNormal;
end;

class function TGlyphSupport.NormalizeFontName(const AFontName: string): string;
var
  LLegacy: string;
begin
  // The whole Cascadia* family (Cascadia Code, Cascadia Mono, and EVERY weight
  // variant - e.g. a config carrying 'Cascadia Code ExtraLight') lacks the
  // powerline / BMP-PUA glyphs, so map the family by PREFIX. This ends the
  // whack-a-mole the exact-match list caused (ESP-081 caught 'Cascadia Code',
  // then a persisted 'Cascadia Code ExtraLight' slipped through -> tofu). The
  // Nerd-patched face is 'Caskaydia*' (with a K), so this never swallows it.
  if SameText(Copy(Trim(AFontName), 1, 8), 'Cascadia') then
    Exit(TERMINAL_NERD_FONT);
  for LLegacy in LEGACY_INCAPABLE_NAMES do
    if SameText(AFontName, LLegacy) then
      Exit(TERMINAL_NERD_FONT);
  Result := AFontName;
end;

end.
