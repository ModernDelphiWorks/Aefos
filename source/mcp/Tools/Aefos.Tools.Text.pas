unit Aefos.Tools.Text;

{
  Aefos.Tools.Text — pure line/column text manipulation engine.

  The mechanical executor behind the file-editing tool suite. The CALLER (the
  agent) supplies the coordinates — 1-based line and column — and a small
  payload; this unit performs the edit on the in-memory content and returns the
  full resulting text. No guessing, no anchoring, no parsing: the intelligence
  lives in the caller, the mechanics live here.

  Design contract:
    - Coordinates are 1-based. Line in [1, LineCount]; Column in
      [1, Length(line)+1] (column = Length+1 means "just past the last char").
    - The document is modelled as EOL-count + 1 segments (a trailing newline
      yields a final empty line, exactly like a code editor). Split/Join
      round-trips any input losslessly for a single EOL style.
    - The detected dominant EOL (CRLF / LF / CR) is preserved on output, and
      any inserted multi-line payload is normalised to that same EOL.
    - Every mutator returns TToolTextResult: an outcome enum plus the new
      content. Out-of-range coordinates never raise — they return a typed
      outcome the tool layer maps to an MCP error.

  Boundary: pure RTL. Zero ToolsAPI, zero Vcl./FMX., zero file IO. This unit is
  callable headless and from the IDE alike, and is fully unit-testable.
}

interface

type
  // Outcome of a text mutation. The tool layer maps these to MCP error codes.
  TToolTextOutcome = (
    ttApplied,          // the edit was applied; Content holds the new text
    ttLineOutOfRange,   // a line coordinate fell outside [1, LineCount(+1)]
    ttColumnOutOfRange, // a column coordinate fell outside [1, LineLen+1]
    ttInvalidArgument   // an argument pair is inconsistent (e.g. end < start)
  );

  TToolTextResult = record
    Outcome: TToolTextOutcome;
    Content: string;    // full resulting content (valid only when Ok)
    Line: Integer;      // 1-based line where the edit landed (0 when N/A)
    Column: Integer;    // 1-based column where the edit landed (0 when N/A)
    LinesAffected: Integer; // lines inserted / replaced / removed
    function Ok: Boolean;
    function OutcomeText: string;
  end;

  // A located occurrence returned by TTextEditor.FindAll (1-based Line/Column).
  TToolTextMatch = record
    Line: Integer;
    Column: Integer;
    Length: Integer;
  end;

  // Pure line/column text manipulation engine as a sealed static namespace
  // (see the unit header for the design contract). Never instantiated.
  TTextEditor = class sealed
  public
    // ── Queries (pure, never fail) ───────────────────────────────────────────

    // Number of lines, editor-style: '' is 1 (empty) line, 'a'#13#10 is 2 lines.
    class function CountLines(const AContent: string): Integer; static;

    // The 1-based line ALine, without its terminator. '' when out of range.
    class function GetLine(const AContent: string; const ALine: Integer): string; static;

    // The dominant end-of-line marker. Defaults to CRLF for content with none.
    class function DetectEol(const AContent: string): string; static;

    // ── Whole-line mutators ──────────────────────────────────────────────────

    // Inserts AText as new line(s) so that AText becomes line ALine; existing
    // line ALine and below shift down. ALine in [1, LineCount+1] (append = +1).
    class function InsertLine(const AContent: string; const ALine: Integer;
      const AText: string): TToolTextResult; static;

    // Replaces line ALine with AText (which may itself span multiple lines).
    class function ReplaceLine(const AContent: string; const ALine: Integer;
      const AText: string): TToolTextResult; static;

    // Removes line ALine.
    class function RemoveLine(const AContent: string;
      const ALine: Integer): TToolTextResult; static;

    // Removes the inclusive line range [AFromLine, AToLine].
    class function RemoveLines(const AContent: string;
      const AFromLine, AToLine: Integer): TToolTextResult; static;

    // Appends AText as a new final line, respecting an existing trailing newline
    // (a file ending in EOL gains a line BEFORE the trailing blank).
    class function AppendLine(const AContent: string;
      const AText: string): TToolTextResult; static;

    // ── Column-precise mutators ──────────────────────────────────────────────

    // Inserts AText inside line ALine at column AColumn. AText may be multi-line;
    // embedded newlines split the line. AColumn in [1, Length(line)+1].
    class function InsertAt(const AContent: string; const ALine, AColumn: Integer;
      const AText: string): TToolTextResult; static;

    // Deletes the half-open range [(AStartLine,AStartCol) .. (AEndLine,AEndCol)).
    class function DeleteRange(const AContent: string;
      const AStartLine, AStartCol, AEndLine, AEndCol: Integer): TToolTextResult; static;

    // Replaces the half-open range above with AText.
    class function ReplaceRange(const AContent: string;
      const AStartLine, AStartCol, AEndLine, AEndCol: Integer;
      const AText: string): TToolTextResult; static;

    // ── Search ───────────────────────────────────────────────────────────────

    // Every occurrence of ANeedle, line by line (1-based Line/Column). Empty when
    // ANeedle is empty.
    class function FindAll(const AContent, ANeedle: string;
      const ACaseSensitive: Boolean): TArray<TToolTextMatch>; static;

    // Replaces every occurrence of AFind with AReplace. LinesAffected carries the
    // number of replacements. ttInvalidArgument when AFind is empty.
    class function ReplaceAll(const AContent, AFind, AReplace: string;
      const ACaseSensitive: Boolean): TToolTextResult; static;
  end;

implementation

uses
  System.SysUtils,
  System.StrUtils,
  System.Generics.Collections;

{ TToolTextResult }

function TToolTextResult.Ok: Boolean;
begin
  Result := Outcome = ttApplied;
end;

function TToolTextResult.OutcomeText: string;
begin
  case Outcome of
    ttApplied:          Result := 'applied';
    ttLineOutOfRange:   Result := 'line-out-of-range';
    ttColumnOutOfRange: Result := 'column-out-of-range';
    ttInvalidArgument:  Result := 'invalid-argument';
  else
    Result := 'unknown';
  end;
end;

// ── EOL detection / split / join ─────────────────────────────────────────

class function TTextEditor.DetectEol(const AContent: string): string;
var
  LPos, LCrlf, LLf, LCr: Integer;
begin
  LCrlf := 0; LLf := 0; LCr := 0;
  LPos := 1;
  while LPos <= Length(AContent) do
  begin
    if AContent[LPos] = #13 then
    begin
      if (LPos < Length(AContent)) and (AContent[LPos + 1] = #10) then
      begin
        Inc(LCrlf); Inc(LPos, 2); Continue;
      end;
      Inc(LCr); Inc(LPos); Continue;
    end;
    if AContent[LPos] = #10 then
    begin
      Inc(LLf); Inc(LPos); Continue;
    end;
    Inc(LPos);
  end;
  if (LCrlf >= LLf) and (LCrlf >= LCr) then
    Result := #13#10
  else if LLf >= LCr then
    Result := #10
  else
    Result := #13;
end;

// Splits content into EOL-count + 1 segments (terminators removed). '' yields
// a single empty segment; the round-trip _Join(_Split(x)) restores x.
function _Split(const AContent: string): TArray<string>;
var
  LList: TList<string>;
  LPos, LStart: Integer;
begin
  LList := TList<string>.Create;
  try
    LStart := 1;
    LPos := 1;
    while LPos <= Length(AContent) do
    begin
      if AContent[LPos] = #13 then
      begin
        LList.Add(Copy(AContent, LStart, LPos - LStart));
        if (LPos < Length(AContent)) and (AContent[LPos + 1] = #10) then
          Inc(LPos);
        Inc(LPos);
        LStart := LPos;
      end
      else if AContent[LPos] = #10 then
      begin
        LList.Add(Copy(AContent, LStart, LPos - LStart));
        Inc(LPos);
        LStart := LPos;
      end
      else
        Inc(LPos);
    end;
    LList.Add(Copy(AContent, LStart, Length(AContent) - LStart + 1));
    Result := LList.ToArray;
  finally
    LList.Free;
  end;
end;

function _Join(const ASegments: TArray<string>; const AEol: string): string;
var
  LBuilder: TStringBuilder;
  LFor: Integer;
begin
  LBuilder := TStringBuilder.Create;
  try
    for LFor := 0 to High(ASegments) do
    begin
      if LFor > 0 then
        LBuilder.Append(AEol);
      LBuilder.Append(ASegments[LFor]);
    end;
    Result := LBuilder.ToString;
  finally
    LBuilder.Free;
  end;
end;

// Re-expresses AText's own newlines as AEol so an inserted payload matches the
// document's EOL style.
function _NormalizeEol(const AText, AEol: string): string;
begin
  Result := _Join(_Split(AText), AEol);
end;

// ── Result builders ──────────────────────────────────────────────────────

function _Fail(const AOutcome: TToolTextOutcome): TToolTextResult;
begin
  Result := Default(TToolTextResult);
  Result.Outcome := AOutcome;
end;

function _Ok(const AContent: string; const ALine, AColumn,
  ALinesAffected: Integer): TToolTextResult;
begin
  Result.Outcome := ttApplied;
  Result.Content := AContent;
  Result.Line := ALine;
  Result.Column := AColumn;
  Result.LinesAffected := ALinesAffected;
end;

// Replaces the inclusive segment slot range [AFrom..ATo] of ASegments with
// ANew, returning the rebuilt array. AFrom > ATo inserts at AFrom.
function _Splice(const ASegments: TArray<string>; const AFrom, ATo: Integer;
  const ANew: TArray<string>): TArray<string>;
var
  LList: TList<string>;
  LFor: Integer;
begin
  LList := TList<string>.Create;
  try
    for LFor := 0 to AFrom - 1 do
      LList.Add(ASegments[LFor]);
    for LFor := 0 to High(ANew) do
      LList.Add(ANew[LFor]);
    for LFor := ATo + 1 to High(ASegments) do
      LList.Add(ASegments[LFor]);
    Result := LList.ToArray;
  finally
    LList.Free;
  end;
end;

// ── Queries ──────────────────────────────────────────────────────────────

class function TTextEditor.CountLines(const AContent: string): Integer;
begin
  Result := Length(_Split(AContent));
end;

class function TTextEditor.GetLine(const AContent: string; const ALine: Integer): string;
var
  LSegments: TArray<string>;
begin
  LSegments := _Split(AContent);
  if (ALine < 1) or (ALine > Length(LSegments)) then
    Exit('');
  Result := LSegments[ALine - 1];
end;

// ── Whole-line mutators ──────────────────────────────────────────────────

class function TTextEditor.InsertLine(const AContent: string; const ALine: Integer;
  const AText: string): TToolTextResult;
var
  LSegments, LNew: TArray<string>;
  LEol: string;
begin
  LSegments := _Split(AContent);
  if (ALine < 1) or (ALine > Length(LSegments) + 1) then
    Exit(_Fail(ttLineOutOfRange));
  LEol := TTextEditor.DetectEol(AContent);
  LNew := _Split(_NormalizeEol(AText, LEol));
  // Insert before slot (ALine-1): _Splice with AFrom > ATo inserts.
  Result := _Ok(_Join(_Splice(LSegments, ALine - 1, ALine - 2, LNew), LEol),
    ALine, 1, Length(LNew));
end;

class function TTextEditor.ReplaceLine(const AContent: string; const ALine: Integer;
  const AText: string): TToolTextResult;
var
  LSegments, LNew: TArray<string>;
  LEol: string;
begin
  LSegments := _Split(AContent);
  if (ALine < 1) or (ALine > Length(LSegments)) then
    Exit(_Fail(ttLineOutOfRange));
  LEol := TTextEditor.DetectEol(AContent);
  LNew := _Split(_NormalizeEol(AText, LEol));
  Result := _Ok(_Join(_Splice(LSegments, ALine - 1, ALine - 1, LNew), LEol),
    ALine, 1, Length(LNew));
end;

class function TTextEditor.RemoveLine(const AContent: string;
  const ALine: Integer): TToolTextResult;
begin
  Result := TTextEditor.RemoveLines(AContent, ALine, ALine);
end;

class function TTextEditor.RemoveLines(const AContent: string;
  const AFromLine, AToLine: Integer): TToolTextResult;
var
  LSegments: TArray<string>;
  LEol: string;
begin
  if AFromLine > AToLine then
    Exit(_Fail(ttInvalidArgument));
  LSegments := _Split(AContent);
  if (AFromLine < 1) or (AToLine > Length(LSegments)) then
    Exit(_Fail(ttLineOutOfRange));
  LEol := TTextEditor.DetectEol(AContent);
  Result := _Ok(_Join(_Splice(LSegments, AFromLine - 1, AToLine - 1, []), LEol),
    AFromLine, 1, AToLine - AFromLine + 1);
end;

class function TTextEditor.AppendLine(const AContent: string;
  const AText: string): TToolTextResult;
var
  LSegments, LNew: TArray<string>;
  LEol: string;
  LPos: Integer;
begin
  LSegments := _Split(AContent);
  LEol := TTextEditor.DetectEol(AContent);
  LNew := _Split(_NormalizeEol(AText, LEol));
  // Respect a trailing newline: insert before the final empty segment so the
  // appended line lands above the trailing blank rather than after it.
  if (Length(LSegments) > 0) and (LSegments[High(LSegments)] = '') then
    LPos := High(LSegments)
  else
    LPos := Length(LSegments);
  Result := _Ok(_Join(_Splice(LSegments, LPos, LPos - 1, LNew), LEol),
    LPos + 1, 1, Length(LNew));
end;

// ── Column-precise mutators ──────────────────────────────────────────────

// Merges textual fragments AText (already EOL-split into LText) into a single
// line slot at LSeg, between LLeft and LRight, returning the new slots.
function _InjectIntoLine(const ALeft, ARight: string;
  const AText: TArray<string>): TArray<string>;
var
  LList: TList<string>;
  LFor: Integer;
begin
  LList := TList<string>.Create;
  try
    if Length(AText) = 1 then
      LList.Add(ALeft + AText[0] + ARight)
    else
    begin
      LList.Add(ALeft + AText[0]);
      for LFor := 1 to High(AText) - 1 do
        LList.Add(AText[LFor]);
      LList.Add(AText[High(AText)] + ARight);
    end;
    Result := LList.ToArray;
  finally
    LList.Free;
  end;
end;

class function TTextEditor.InsertAt(const AContent: string; const ALine, AColumn: Integer;
  const AText: string): TToolTextResult;
var
  LSegments, LText, LNew: TArray<string>;
  LEol, LSeg, LLeft, LRight: string;
begin
  LSegments := _Split(AContent);
  if (ALine < 1) or (ALine > Length(LSegments)) then
    Exit(_Fail(ttLineOutOfRange));
  LSeg := LSegments[ALine - 1];
  if (AColumn < 1) or (AColumn > Length(LSeg) + 1) then
    Exit(_Fail(ttColumnOutOfRange));
  LEol := TTextEditor.DetectEol(AContent);
  LText := _Split(_NormalizeEol(AText, LEol));
  LLeft := Copy(LSeg, 1, AColumn - 1);
  LRight := Copy(LSeg, AColumn, MaxInt);
  LNew := _InjectIntoLine(LLeft, LRight, LText);
  Result := _Ok(_Join(_Splice(LSegments, ALine - 1, ALine - 1, LNew), LEol),
    ALine, AColumn, Length(LText));
end;

// Validates the half-open range against the live segments. Returns the failing
// outcome, or ttApplied when the range is well-formed.
function _ValidateRange(const ASegments: TArray<string>;
  const AStartLine, AStartCol, AEndLine, AEndCol: Integer): TToolTextOutcome;
begin
  if (AStartLine < 1) or (AEndLine > Length(ASegments)) then
    Exit(ttLineOutOfRange);
  if (AStartLine > AEndLine)
    or ((AStartLine = AEndLine) and (AStartCol > AEndCol)) then
    Exit(ttInvalidArgument);
  if (AStartCol < 1) or (AStartCol > Length(ASegments[AStartLine - 1]) + 1) then
    Exit(ttColumnOutOfRange);
  if (AEndCol < 1) or (AEndCol > Length(ASegments[AEndLine - 1]) + 1) then
    Exit(ttColumnOutOfRange);
  Result := ttApplied;
end;

class function TTextEditor.DeleteRange(const AContent: string;
  const AStartLine, AStartCol, AEndLine, AEndCol: Integer): TToolTextResult;
var
  LSegments: TArray<string>;
  LEol, LLeft, LRight, LMerged: string;
  LCheck: TToolTextOutcome;
begin
  LSegments := _Split(AContent);
  LCheck := _ValidateRange(LSegments, AStartLine, AStartCol, AEndLine, AEndCol);
  if LCheck <> ttApplied then
    Exit(_Fail(LCheck));
  LEol := TTextEditor.DetectEol(AContent);
  LLeft := Copy(LSegments[AStartLine - 1], 1, AStartCol - 1);
  LRight := Copy(LSegments[AEndLine - 1], AEndCol, MaxInt);
  LMerged := LLeft + LRight;
  Result := _Ok(
    _Join(_Splice(LSegments, AStartLine - 1, AEndLine - 1, [LMerged]), LEol),
    AStartLine, AStartCol, AEndLine - AStartLine + 1);
end;

class function TTextEditor.ReplaceRange(const AContent: string;
  const AStartLine, AStartCol, AEndLine, AEndCol: Integer;
  const AText: string): TToolTextResult;
var
  LDeleted: TToolTextResult;
begin
  LDeleted := TTextEditor.DeleteRange(AContent, AStartLine, AStartCol,
    AEndLine, AEndCol);
  if not LDeleted.Ok then
    Exit(LDeleted);
  Result := TTextEditor.InsertAt(LDeleted.Content, AStartLine, AStartCol, AText);
end;

// ── Search ───────────────────────────────────────────────────────────────

class function TTextEditor.FindAll(const AContent, ANeedle: string;
  const ACaseSensitive: Boolean): TArray<TToolTextMatch>;
var
  LSegs: TArray<string>;
  LList: TList<TToolTextMatch>;
  LFor, LPos: Integer;
  LHay, LNdl: string;
  LMatch: TToolTextMatch;
begin
  SetLength(Result, 0);
  if ANeedle = '' then
    Exit;
  LSegs := _Split(AContent);
  LList := TList<TToolTextMatch>.Create;
  try
    for LFor := 0 to High(LSegs) do
    begin
      if ACaseSensitive then
      begin
        LHay := LSegs[LFor];
        LNdl := ANeedle;
      end
      else
      begin
        LHay := LowerCase(LSegs[LFor]);
        LNdl := LowerCase(ANeedle);
      end;
      LPos := Pos(LNdl, LHay);
      while LPos > 0 do
      begin
        LMatch.Line := LFor + 1;
        LMatch.Column := LPos;
        LMatch.Length := Length(ANeedle);
        LList.Add(LMatch);
        LPos := PosEx(LNdl, LHay, LPos + Length(LNdl));
      end;
    end;
    Result := LList.ToArray;
  finally
    LList.Free;
  end;
end;

class function TTextEditor.ReplaceAll(const AContent, AFind, AReplace: string;
  const ACaseSensitive: Boolean): TToolTextResult;
var
  LHay, LNdl, LRep: string;
  LCount, LPos: Integer;
  LFlags: TReplaceFlags;
begin
  if AFind = '' then
    Exit(_Fail(ttInvalidArgument));
  if ACaseSensitive then
  begin
    LHay := AContent;
    LNdl := AFind;
  end
  else
  begin
    LHay := LowerCase(AContent);
    LNdl := LowerCase(AFind);
  end;
  LCount := 0;
  LPos := Pos(LNdl, LHay);
  while LPos > 0 do
  begin
    Inc(LCount);
    LPos := PosEx(LNdl, LHay, LPos + Length(LNdl));
  end;
  LRep := _NormalizeEol(AReplace, TTextEditor.DetectEol(AContent));
  LFlags := [rfReplaceAll];
  if not ACaseSensitive then
    Include(LFlags, rfIgnoreCase);
  Result := _Ok(StringReplace(AContent, AFind, LRep, LFlags), 0, 0, LCount);
end;

end.
