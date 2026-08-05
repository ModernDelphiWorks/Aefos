unit Aefos.OTA.Terminal.Core.FuzzyMatch;

{
  Pure fuzzy matcher for the V.5 command palette (ESP-062 / ADR-062-02).

  Case-insensitive subsequence matching with a weighted score. No VCL, no IDE
  types, allocation-light (character-level comparison — no intermediate
  lowercase strings). This is the headless-testable core of the palette's
  ranking (target >= 80% coverage); the overlay and the command adapters live
  in the IDE layer. See [[mobaxterm-ux-reference]].

  Scoring intent (BR3): a contiguous / prefix hit must outrank a scattered hit,
  matches at word boundaries are rewarded, and an earlier first match beats a
  later one. The exact weights are tunable here without touching the UI.
}

interface

type
  /// <summary>
  ///   Pure fuzzy matcher for the command palette. Stateless: the single member
  ///   is static.
  /// </summary>
  TFuzzyMatcher = class sealed
    /// <summary>
    ///   Pure fuzzy matcher. Returns <c>True</c> when every character of
    ///   <c>APattern</c> occurs in <c>ACandidate</c> in order (a case-insensitive
    ///   subsequence) and assigns <c>AScore</c> a relevance weight: higher is a
    ///   better match. Contiguous runs, word-start hits and earlier matches all
    ///   raise the score. An empty pattern matches every candidate with a neutral
    ///   score of <c>0</c>. On a non-match the result is <c>False</c> and
    ///   <c>AScore</c> is <c>0</c>.
    /// </summary>
    class function Match(const APattern, ACandidate: string;
      out AScore: Integer): Boolean; static;
  end;

implementation

uses
  System.Character;

const
  // Reward weights tuned so a prefix / contiguous hit clearly outranks a
  // scattered one (ADR-062-02). Kept as named constants so ranking is
  // adjustable without touching the algorithm.
  SCORE_PER_MATCH    = 8;   // each matched character
  BONUS_CONTIGUOUS   = 12;  // match immediately after the previous match
  BONUS_WORD_START   = 10;  // match at index 1 or after a separator
  PENALTY_LEADING    = 2;   // per character skipped before the first match
  PENALTY_GAP        = 1;   // per character skipped between two matches

/// <summary>
///   True when the candidate character at <c>AIndex</c> (1-based) starts a
///   word: position 1, or preceded by a non-alphanumeric separator.
/// </summary>
function _IsWordStart(const ACandidate: string; const AIndex: Integer): Boolean;
begin
  if AIndex <= 1 then
    Exit(True);
  Result := not ACandidate[AIndex - 1].IsLetterOrDigit;
end;

class function TFuzzyMatcher.Match(const APattern, ACandidate: string;
  out AScore: Integer): Boolean;
var
  LPatIndex: Integer;
  LCandIndex: Integer;
  LPrevMatch: Integer;
begin
  AScore := 0;
  if APattern = '' then
    Exit(True); // empty pattern matches all, neutral score (BR3)

  LPatIndex := 1;
  LPrevMatch := 0; // 0 = no match recorded yet
  for LCandIndex := 1 to Length(ACandidate) do
  begin
    if LPatIndex > Length(APattern) then
      Break;
    if ACandidate[LCandIndex].ToLower <> APattern[LPatIndex].ToLower then
      Continue;

    Inc(AScore, SCORE_PER_MATCH);
    if LPrevMatch = 0 then
      Dec(AScore, (LCandIndex - 1) * PENALTY_LEADING)  // earlier start = better
    else if LCandIndex = LPrevMatch + 1 then
      Inc(AScore, BONUS_CONTIGUOUS)                    // adjacent to last match
    else
      Dec(AScore, (LCandIndex - LPrevMatch - 1) * PENALTY_GAP); // scattered

    if _IsWordStart(ACandidate, LCandIndex) then
      Inc(AScore, BONUS_WORD_START);

    LPrevMatch := LCandIndex;
    Inc(LPatIndex);
  end;

  Result := LPatIndex > Length(APattern);
  if not Result then
    AScore := 0;
end;

end.


