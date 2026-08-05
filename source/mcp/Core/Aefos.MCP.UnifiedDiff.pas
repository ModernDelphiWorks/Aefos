unit Aefos.MCP.UnifiedDiff;

{
  Pure line diff + unified-diff renderer (VCS/IDE-diff group).

  Zero ToolsAPI, zero I/O, zero state — the whole decision surface is here so it
  can be asserted headless. The OTA side
  (Aefos.MCP.OTA.DiffViewService) only fetches the two texts; the DIFF itself is
  this unit.

  Algorithm: Myers O(ND) greedy with a per-D trace, then a backtrack that yields
  the edit script. Line-based (the unit of a unified diff), CRLF/CR normalized to
  LF before comparing so a line-ending-only delta never shows as a change.

  MEMORY (this runs in a Win32 design-time BPL inside an already-fat IDE process,
  so an OOM here can land on somebody ELSE's allocation):
    - The common PREFIX and SUFFIX are trimmed before Myers even starts, so the
      D the algorithm has to walk is the size of the real edit, not of the file.
    - Each D step snapshots only the LIVE WINDOW of the V vector (2*D+3 ints),
      never the whole vector — total trace is O(D^2) ints, not O(D*(N+M)).
    - Both the line count and the edit distance are HARD-CAPPED. Over the cap the
      renderer refuses with the machine-actionable reason 'diff-too-large'
      instead of allocating (or raising EOutOfMemory).
  With MAX_EDIT_DISTANCE = 3000 the worst-case trace is ~9M ints (~36 MB) and is
  only reached by a pathological all-lines-differ input.

  FINAL NEWLINE: whether a side ends with a newline is part of its content. A
  file that only lost its trailing newline still produces a patch (and carries
  the `\ No newline at end of file` marker), otherwise the tool would answer
  "not dirty" about a buffer that does NOT match HEAD, and the patch would not
  apply with `git apply`.
}

interface

type
  TDiffOpKind = (dokEqual, dokDelete, dokInsert);

  TDiffOp = record
    Kind: TDiffOpKind;
    OldIndex: Integer;  // 0-based index into the old lines (-1 for dokInsert)
    NewIndex: Integer;  // 0-based index into the new lines (-1 for dokDelete)
  end;

const
  // Refusal thresholds — see the MEMORY note above.
  MAX_DIFF_LINES     = 100000;  // per side
  MAX_EDIT_DISTANCE  = 3000;    // Myers D (inserted + deleted lines)

  NO_NEWLINE_MARKER = '\ No newline at end of file';

// Splits text into lines, normalizing CRLF/CR to LF. A single trailing newline
// does NOT produce a phantom final empty line.
function SplitTextLines(const AText: string): TArray<string>;

// SplitTextLines + the fact the caller MUST NOT lose: did the text end with a
// newline? (An empty text reports True — there is no dangling last line.)
function SplitTextLinesEx(const AText: string;
  out AEndsWithNewline: Boolean): TArray<string>;

// The Myers edit script between two line arrays. Returns an empty script when
// the input exceeds the caps (use TryDiffLines when the reason matters).
function DiffLines(const AOld, ANew: TArray<string>): TArray<TDiffOp>;

// The capped form: False + AReason='diff-too-large' when the input is beyond
// what a design-time BPL may safely allocate for.
function TryDiffLines(const AOld, ANew: TArray<string>;
  out AOps: TArray<TDiffOp>; out AReason: string): Boolean;

// Renders a unified diff. APatch is '' when the two texts are identical (after
// line-ending normalization) — the caller reports "no changes" rather than an
// empty patch. AContext < 0 is clamped to 0. False + AReason='diff-too-large'
// when the input is past the caps: a REFUSAL, never an exception.
function TryBuildUnifiedDiff(const AOldText, ANewText, AOldLabel,
  ANewLabel: string; const AContext: Integer; out APatch: string;
  out AReason: string): Boolean;

// Convenience wrapper: the patch, or '' when identical OR refused.
function BuildUnifiedDiff(const AOldText, ANewText, AOldLabel,
  ANewLabel: string; const AContext: Integer): string;

implementation

uses
  System.SysUtils;

function SplitTextLinesEx(const AText: string;
  out AEndsWithNewline: Boolean): TArray<string>;
var
  LNorm: string;
  LParts: TArray<string>;
  LCount: Integer;
begin
  AEndsWithNewline := True;
  if AText = '' then
    Exit(nil);
  LNorm := StringReplace(AText, #13#10, #10, [rfReplaceAll]);
  LNorm := StringReplace(LNorm, #13, #10, [rfReplaceAll]);
  AEndsWithNewline := LNorm[Length(LNorm)] = #10;
  LParts := LNorm.Split([#10]);
  LCount := Length(LParts);
  // A trailing newline yields a final empty element — drop it (the line count of
  // "a\n" is 1, not 2). The FACT of that newline survives in AEndsWithNewline.
  if (LCount > 0) and (LParts[LCount - 1] = '') then
    SetLength(LParts, LCount - 1);
  Result := LParts;
end;

function SplitTextLines(const AText: string): TArray<string>;
var
  LEndsNL: Boolean;
begin
  Result := SplitTextLinesEx(AText, LEndsNL);
end;

function _MakeOp(const AKind: TDiffOpKind;
  const AOldIndex, ANewIndex: Integer): TDiffOp;
begin
  Result.Kind := AKind;
  Result.OldIndex := AOldIndex;
  Result.NewIndex := ANewIndex;
end;

// Walks the D-trace backwards, emitting the edit script in reverse, then flips
// it. ATrace[D] is the LIVE WINDOW of the V vector as it stood BEFORE step D:
// window index of diagonal K is K + D + 1. AOldBase/ANewBase shift the emitted
// indices back onto the untrimmed line arrays.
function _Backtrack(const ATrace: TArray<TArray<Integer>>;
  const AEndX, AEndY, AOldBase, ANewBase: Integer): TArray<TDiffOp>;
var
  LRev: TArray<TDiffOp>;
  LV: TArray<Integer>;
  LD, LK, LX, LY, LPrevK, LPrevX, LPrevY, LFor, LCount: Integer;
begin
  SetLength(LRev, 0);
  LX := AEndX;
  LY := AEndY;
  for LD := High(ATrace) downto 0 do
  begin
    LV := ATrace[LD];
    LK := LX - LY;
    if (LK = -LD) or
       ((LK <> LD) and (LV[LK + LD] < LV[LK + LD + 2])) then
      LPrevK := LK + 1
    else
      LPrevK := LK - 1;
    LPrevX := LV[LPrevK + LD + 1];
    LPrevY := LPrevX - LPrevK;
    while (LX > LPrevX) and (LY > LPrevY) do
    begin
      LRev := LRev + [_MakeOp(dokEqual, AOldBase + LX - 1, ANewBase + LY - 1)];
      Dec(LX);
      Dec(LY);
    end;
    if LD > 0 then
    begin
      if LX = LPrevX then
        LRev := LRev + [_MakeOp(dokInsert, -1, ANewBase + LPrevY)]
      else
        LRev := LRev + [_MakeOp(dokDelete, AOldBase + LPrevX, -1)];
    end;
    LX := LPrevX;
    LY := LPrevY;
  end;
  LCount := Length(LRev);
  SetLength(Result, LCount);
  for LFor := 0 to LCount - 1 do
    Result[LFor] := LRev[LCount - 1 - LFor];
end;

// Myers over the TRIMMED middle (AOld[AOldBase..] / ANew[ANewBase..], LN/LM
// long). Emits ops carrying UNTRIMMED indices.
function _MyersMiddle(const AOld, ANew: TArray<string>;
  const AOldBase, ANewBase, AN, AM: Integer;
  out AOps: TArray<TDiffOp>; out AReason: string): Boolean;
var
  LMaxD, LOffset, LD, LK, LX, LY, LFor: Integer;
  LV: TArray<Integer>;
  LTrace: TArray<TArray<Integer>>;
  LWindow: TArray<Integer>;
begin
  SetLength(AOps, 0);
  AReason := '';
  Result := True;
  if (AN = 0) and (AM = 0) then
    Exit;
  // The theoretical worst case. It is NOT a refusal on its own: after the
  // prefix/suffix trim the REAL D is usually tiny, so we only refuse below, the
  // moment D actually crosses MAX_EDIT_DISTANCE.
  LMaxD := AN + AM;
  LOffset := LMaxD + 1;
  SetLength(LV, 2 * LMaxD + 3);
  SetLength(LTrace, 0);
  for LD := 0 to LMaxD do
  begin
    if LD > MAX_EDIT_DISTANCE then
    begin
      // Past the cap: refuse instead of growing the trace any further. Free what
      // we already hold — this runs inside the IDE process.
      SetLength(LTrace, 0);
      SetLength(AOps, 0);
      AReason := 'diff-too-large';
      Exit(False);
    end;
    // Snapshot only the LIVE WINDOW (diagonals -D-1..D+1): 2*D+3 ints. The full
    // vector would make the trace O(D*(N+M)) and blow up a 32-bit process.
    SetLength(LWindow, 2 * LD + 3);
    for LFor := 0 to 2 * LD + 2 do
      LWindow[LFor] := LV[LOffset - LD - 1 + LFor];
    LTrace := LTrace + [LWindow];
    LK := -LD;
    while LK <= LD do
    begin
      if (LK = -LD) or
         ((LK <> LD) and (LV[LOffset + LK - 1] < LV[LOffset + LK + 1])) then
        LX := LV[LOffset + LK + 1]
      else
        LX := LV[LOffset + LK - 1] + 1;
      LY := LX - LK;
      while (LX < AN) and (LY < AM)
        and (AOld[AOldBase + LX] = ANew[ANewBase + LY]) do
      begin
        Inc(LX);
        Inc(LY);
      end;
      LV[LOffset + LK] := LX;
      if (LX >= AN) and (LY >= AM) then
      begin
        AOps := _Backtrack(LTrace, AN, AM, AOldBase, ANewBase);
        Exit(True);
      end;
      Inc(LK, 2);
    end;
  end;
end;

function TryDiffLines(const AOld, ANew: TArray<string>;
  out AOps: TArray<TDiffOp>; out AReason: string): Boolean;
var
  LN, LM, LPrefix, LSuffix, LFor: Integer;
  LMiddle: TArray<TDiffOp>;
  LOps: TArray<TDiffOp>;
begin
  SetLength(AOps, 0);
  AReason := '';
  LN := Length(AOld);
  LM := Length(ANew);
  if (LN > MAX_DIFF_LINES) or (LM > MAX_DIFF_LINES) then
  begin
    AReason := 'diff-too-large';
    Exit(False);
  end;
  // Trim the common prefix / suffix: the edit distance Myers must walk is then
  // the size of the CHANGE, not of the file. This is what keeps a one-line edit
  // in a 10k-line unit at D = 2.
  LPrefix := 0;
  while (LPrefix < LN) and (LPrefix < LM)
    and (AOld[LPrefix] = ANew[LPrefix]) do
    Inc(LPrefix);
  LSuffix := 0;
  while (LSuffix < LN - LPrefix) and (LSuffix < LM - LPrefix)
    and (AOld[LN - 1 - LSuffix] = ANew[LM - 1 - LSuffix]) do
    Inc(LSuffix);
  if not _MyersMiddle(AOld, ANew, LPrefix, LPrefix,
    LN - LPrefix - LSuffix, LM - LPrefix - LSuffix, LMiddle, AReason) then
    Exit(False);
  SetLength(LOps, 0);
  for LFor := 0 to LPrefix - 1 do
    LOps := LOps + [_MakeOp(dokEqual, LFor, LFor)];
  LOps := LOps + LMiddle;
  for LFor := 0 to LSuffix - 1 do
    LOps := LOps + [_MakeOp(dokEqual, LN - LSuffix + LFor,
      LM - LSuffix + LFor)];
  AOps := LOps;
  Result := True;
end;

function DiffLines(const AOld, ANew: TArray<string>): TArray<TDiffOp>;
var
  LReason: string;
begin
  if not TryDiffLines(AOld, ANew, Result, LReason) then
    SetLength(Result, 0);
end;

function _HasChange(const AOps: TArray<TDiffOp>): Boolean;
var
  LFor: Integer;
begin
  Result := False;
  for LFor := 0 to High(AOps) do
    if AOps[LFor].Kind <> dokEqual then
      Exit(True);
end;

// A side that lost (or gained) its trailing newline has CHANGED even when every
// line is equal. Split the trailing equal op into delete+insert so the patch
// shows it — exactly what `git diff` does.
procedure _ForceTrailingNewlineChange(var AOps: TArray<TDiffOp>;
  const AOldNL, ANewNL: Boolean; const AOldHigh, ANewHigh: Integer);
var
  LLast: Integer;
  LOp: TDiffOp;
  LHead: TArray<TDiffOp>;
begin
  if AOldNL = ANewNL then
    Exit;
  LLast := High(AOps);
  if LLast < 0 then
    Exit;
  LOp := AOps[LLast];
  if (LOp.Kind <> dokEqual) or (LOp.OldIndex <> AOldHigh)
    or (LOp.NewIndex <> ANewHigh) then
    Exit;  // the last line already differs — the marker alone tells the story
  LHead := Copy(AOps, 0, LLast);
  AOps := LHead + [_MakeOp(dokDelete, LOp.OldIndex, -1),
                   _MakeOp(dokInsert, -1, LOp.NewIndex)];
end;

// Renders one hunk (ops[AStart..AStop]) into AText. AOldConsumed/ANewConsumed
// are the counts of old/new lines that precede AStart.
procedure _EmitHunk(var AText: string; const AOps: TArray<TDiffOp>;
  const AOld, ANew: TArray<string>; const AOldNL, ANewNL: Boolean;
  const AStart, AStop: Integer; const AOldConsumed, ANewConsumed: Integer);
var
  LFor: Integer;
  LOldCount, LNewCount, LOldStart, LNewStart: Integer;
  LOp: TDiffOp;
begin
  LOldCount := 0;
  LNewCount := 0;
  for LFor := AStart to AStop do
    case AOps[LFor].Kind of
      dokEqual:  begin Inc(LOldCount); Inc(LNewCount); end;
      dokDelete: Inc(LOldCount);
      dokInsert: Inc(LNewCount);
    end;
  // Unified-diff convention: an empty side is anchored at the preceding line.
  if LOldCount = 0 then
    LOldStart := AOldConsumed
  else
    LOldStart := AOldConsumed + 1;
  if LNewCount = 0 then
    LNewStart := ANewConsumed
  else
    LNewStart := ANewConsumed + 1;
  AText := AText + Format('@@ -%d,%d +%d,%d @@'#10,
    [LOldStart, LOldCount, LNewStart, LNewCount]);
  for LFor := AStart to AStop do
  begin
    LOp := AOps[LFor];
    case LOp.Kind of
      dokEqual:
        begin
          AText := AText + ' ' + AOld[LOp.OldIndex] + #10;
          // Both sides end here and NEITHER carries a final newline.
          if (not AOldNL) and (not ANewNL)
            and (LOp.OldIndex = High(AOld)) and (LOp.NewIndex = High(ANew)) then
            AText := AText + NO_NEWLINE_MARKER + #10;
        end;
      dokDelete:
        begin
          AText := AText + '-' + AOld[LOp.OldIndex] + #10;
          if (not AOldNL) and (LOp.OldIndex = High(AOld)) then
            AText := AText + NO_NEWLINE_MARKER + #10;
        end;
      dokInsert:
        begin
          AText := AText + '+' + ANew[LOp.NewIndex] + #10;
          if (not ANewNL) and (LOp.NewIndex = High(ANew)) then
            AText := AText + NO_NEWLINE_MARKER + #10;
        end;
    end;
  end;
end;

function TryBuildUnifiedDiff(const AOldText, ANewText, AOldLabel,
  ANewLabel: string; const AContext: Integer; out APatch: string;
  out AReason: string): Boolean;
var
  LOld, LNew: TArray<string>;
  LOldNL, LNewNL: Boolean;
  LOps: TArray<TDiffOp>;
  LCtx, LFor, LStart, LStop, LScan: Integer;
  LOldConsumed, LNewConsumed, LOldBefore, LNewBefore: Integer;
begin
  APatch := '';
  AReason := '';
  LOld := SplitTextLinesEx(AOldText, LOldNL);
  LNew := SplitTextLinesEx(ANewText, LNewNL);
  if not TryDiffLines(LOld, LNew, LOps, AReason) then
    Exit(False);
  _ForceTrailingNewlineChange(LOps, LOldNL, LNewNL, High(LOld), High(LNew));
  Result := True;
  if not _HasChange(LOps) then
    Exit;
  LCtx := AContext;
  if LCtx < 0 then
    LCtx := 0;
  APatch := '--- ' + AOldLabel + #10 + '+++ ' + ANewLabel + #10;

  LOldConsumed := 0;   // old lines consumed by ops strictly before LFor
  LNewConsumed := 0;
  LFor := 0;
  while LFor <= High(LOps) do
  begin
    if LOps[LFor].Kind = dokEqual then
    begin
      Inc(LOldConsumed);
      Inc(LNewConsumed);
      Inc(LFor);
      Continue;
    end;
    // Hunk start: back up over at most LCtx leading context lines.
    LStart := LFor;
    LOldBefore := LOldConsumed;
    LNewBefore := LNewConsumed;
    while (LStart > 0) and (LOps[LStart - 1].Kind = dokEqual) and
          (LFor - LStart < LCtx) do
    begin
      Dec(LStart);
      Dec(LOldBefore);
      Dec(LNewBefore);
    end;
    // Extend forward: absorb changes plus up to LCtx trailing context.
    LStop := LFor;
    LScan := LFor;
    while LScan <= High(LOps) do
    begin
      if LOps[LScan].Kind <> dokEqual then
      begin
        LStop := LScan;
        Inc(LScan);
        Continue;
      end;
      // Two changes separated by <= 2*LCtx equal lines share a hunk (their
      // context windows would otherwise overlap and emit the same line twice).
      if LScan - LStop <= 2 * LCtx then
      begin
        Inc(LScan);
        Continue;
      end;
      Break;
    end;
    // LStop is the last CHANGE op; add the trailing context back in.
    LStop := LStop + LCtx;
    if LStop > High(LOps) then
      LStop := High(LOps);
    _EmitHunk(APatch, LOps, LOld, LNew, LOldNL, LNewNL, LStart, LStop,
      LOldBefore, LNewBefore);
    // Advance the consumed counters over everything the hunk emitted, minus the
    // leading context we had already counted.
    for LScan := LFor to LStop do
      case LOps[LScan].Kind of
        dokEqual:  begin Inc(LOldConsumed); Inc(LNewConsumed); end;
        dokDelete: Inc(LOldConsumed);
        dokInsert: Inc(LNewConsumed);
      end;
    LFor := LStop + 1;
  end;
end;

function BuildUnifiedDiff(const AOldText, ANewText, AOldLabel,
  ANewLabel: string; const AContext: Integer): string;
var
  LReason: string;
begin
  if not TryBuildUnifiedDiff(AOldText, ANewText, AOldLabel, ANewLabel,
    AContext, Result, LReason) then
    Result := '';
end;

end.
