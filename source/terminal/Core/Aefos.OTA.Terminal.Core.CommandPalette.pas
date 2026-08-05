unit Aefos.OTA.Terminal.Core.CommandPalette;

{
  Pure command-palette model for V.5 (ESP-062 / ADR-062-01 / ADR-062-02).

  Holds the palette command list as plain data and filters / sorts it through
  Aefos.OTA.Terminal.Core.FuzzyMatch. VCL-free and IDE-free so it is headless-testable (target
  >= 80% coverage). The live action references (TProc dispatch) are attached in
  the IDE layer (Aefos.OTA.Terminal.UI.CommandPaletteView / Aefos.OTA.Terminal.UI.DockForm) so this unit
  never duplicates a profile / action / snippet definition (BR1) and never
  reimplements a handler (BR2). See [[mobaxterm-ux-reference]].
}

interface

type
  /// <summary>
  ///   Source category of a palette command. Drives the row label / accent in
  ///   the overlay; the pure unit only carries the value (A4).
  /// </summary>
  TPaletteCategory = (pcProfile, pcAction, pcSnippet, pcBuiltin, pcHistory);

  /// <summary>
  ///   One palette entry as data only — no live action reference (ADR-062-01).
  ///   The IDE layer pairs each record with a dispatch closure that calls the
  ///   existing handler.
  /// </summary>
  TPaletteCommand = record
    /// <summary>Stable unique id (e.g. <c>profile:0</c>, <c>action:&lt;guid&gt;</c>,
    /// <c>snippet:3</c>, <c>builtin:split-h</c>). Identifies the entry when the
    /// IDE layer maps a filtered result back to its dispatch.</summary>
    Id: string;
    /// <summary>Source category (profile / action / snippet / built-in).</summary>
    Category: TPaletteCategory;
    /// <summary>Display title, e.g. <c>Open: pwsh</c> or <c>Split Horizontally</c>.</summary>
    Title: string;
    /// <summary>Secondary hint (executable summary, action category, snippet scope).</summary>
    Subtitle: string;
    /// <summary>Stable tie-break key for equal scores; the adapter sets it
    /// (defaults to <c>Title</c> when left blank).</summary>
    SortKey: string;
  end;

  /// <summary>
  ///   Pure filter / sort model for the command palette. Stateless: all members
  ///   are static.
  /// </summary>
  TCommandPaletteFilter = class sealed
    /// <summary>
    ///   Filters <c>AAll</c> by <c>AQuery</c> using <see cref="TFuzzyMatcher.Match"/>
    ///   against each command's <c>Title</c>, drops non-matches, and sorts the
    ///   survivors by score (descending) then sort key (ascending, case-insensitive),
    ///   with the original position as a final tie-break so the order is stable. A
    ///   blank / whitespace query returns the full list verbatim, preserving the
    ///   caller's grouping (AC2).
    /// </summary>
    class function Filter(const AAll: TArray<TPaletteCommand>;
      const AQuery: string): TArray<TPaletteCommand>; static;

    /// <summary>
    ///   Human-readable single-word label for a category, used as the row badge in
    ///   the overlay (pure formatting helper, ADR-062-02 scope item 2).
    /// </summary>
    class function CategoryLabel(const ACategory: TPaletteCategory): string; static;
  end;

implementation

uses
  System.SysUtils,
  System.Generics.Collections,
  System.Generics.Defaults,
  Aefos.OTA.Terminal.Core.FuzzyMatch;

type
  /// <summary>Internal scored row: keeps the original index for a stable sort.</summary>
  TScoredCommand = record
    Command: TPaletteCommand;
    Score: Integer;
    Order: Integer;
  end;

function _EffectiveSortKey(const ACommand: TPaletteCommand): string;
begin
  if ACommand.SortKey <> '' then
    Result := ACommand.SortKey
  else
    Result := ACommand.Title;
end;

function _CompareScored(const ALeft, ARight: TScoredCommand): Integer;
begin
  // Higher score first.
  Result := ARight.Score - ALeft.Score;
  if Result <> 0 then
    Exit;
  // Equal score: sort key ascending, case-insensitive.
  Result := CompareText(_EffectiveSortKey(ALeft.Command),
    _EffectiveSortKey(ARight.Command));
  if Result <> 0 then
    Exit;
  // Full tie: original order keeps the sort stable.
  Result := ALeft.Order - ARight.Order;
end;

class function TCommandPaletteFilter.Filter(const AAll: TArray<TPaletteCommand>;
  const AQuery: string): TArray<TPaletteCommand>;
var
  LScored: TList<TScoredCommand>;
  LRow: TScoredCommand;
  LIndex: Integer;
  LScore: Integer;
begin
  if AQuery.Trim = '' then
    Exit(Copy(AAll)); // full list verbatim, grouping preserved (AC2)

  LScored := TList<TScoredCommand>.Create;
  try
    for LIndex := 0 to High(AAll) do
      if TFuzzyMatcher.Match(AQuery, AAll[LIndex].Title, LScore) then
      begin
        LRow.Command := AAll[LIndex];
        LRow.Score := LScore;
        LRow.Order := LIndex;
        LScored.Add(LRow);
      end;

    LScored.Sort(TComparer<TScoredCommand>.Construct(_CompareScored));

    SetLength(Result, LScored.Count);
    for LIndex := 0 to LScored.Count - 1 do
      Result[LIndex] := LScored[LIndex].Command;
  finally
    LScored.Free;
  end;
end;

class function TCommandPaletteFilter.CategoryLabel(const ACategory: TPaletteCategory): string;
begin
  case ACategory of
    pcProfile: Result := 'Profile';
    pcAction:  Result := 'Action';
    pcSnippet: Result := 'Snippet';
    pcHistory: Result := 'Recent';
  else
    Result := 'Command';
  end;
end;

end.


