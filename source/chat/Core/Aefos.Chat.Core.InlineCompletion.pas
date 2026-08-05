unit Aefos.Chat.Core.InlineCompletion;

{$IFDEF FPC}{$mode delphiunicode}{$H+}{$ENDIF}

{
  Inline completion (ghost text) -- the PURE policy.

  What was measured before any of this was written (2026-08-03), because it is
  what shaped the design:

    * Painting ghost text in the RAD Studio editor WITHOUT touching the buffer is
      possible: ToolsAPI.Editor.INTACodeEditorEvents.PaintLine at plsEndPaint.
      Proven on screen. (The reference implementation we studied inserts REAL
      blank lines to make room, which marks the file Modified before the user
      typed anything. We do not.)
    * The editor NEVER paints below the end of the file -- measured: 199-line
      file, highest line the editor asked us to paint was 199.
    * An agentic CLI turn costs ~4s regardless of model or of keeping the process
      warm (a warm mcp-server still answered in 4.0s, and `initialize` was 0.12s,
      so the cost is the cloud round-trip, not our spawn). A local FIM model
      answers in ~300ms warm. Ghost-as-you-type is therefore a LOCAL-model
      feature; the CLI path can only ever be an explicit "complete here" key.

  ONE LINE WAS NOT ENOUGH (owner verdict, 2026-08-03: "esta longe de estar bom").
  A completion that shows a single line looks weaker than it is: the model
  routinely has a whole block ready (measured: try/LoadFromFile/Assign/finally/
  Free/end -- six lines in 3.4s on qwen2.5-coder:14b) and we were throwing five
  of them away. So the suggestion is now a BLOCK: every line the model offers,
  up to INLINE_MAX_LINES, and the IDE layer paints the extra lines over the
  lines that follow the caret -- still without writing one byte to the buffer.

  Why the sanitising is not paranoia. A completion model returns whatever it
  likes: a fenced block, an echo of the code that is already there, the rest of
  the unit including `end.`, or nothing but whitespace. Painting that verbatim
  would offer a suggestion identical to what is already written -- so pressing
  Tab appears to do nothing -- or a block that re-declares code the file already
  has. Every rejection and every cut below is a shape that would otherwise reach
  the editor.

  Purity: no ToolsAPI, no Vcl.*/LCL, no I/O, no JSON. Both editions share it and
  a headless test drives it. ASCII only: no BOM needed.
}

interface

uses
  {$IFDEF FPC}
  SysUtils;
  {$ELSE}
  System.SysUtils;
  {$ENDIF}

const
  // How much code around the caret to send. Enough for the model to see the
  // routine it is inside, small enough to keep the prompt-eval in the tens of
  // milliseconds (measured 30ms at this size on a 14B/RTX 3060).
  INLINE_PREFIX_CHARS = 4000;
  INLINE_SUFFIX_CHARS = 2000;
  // Room for a BLOCK, not a line. At 64 the model was cut off mid-suggestion
  // whenever it had something real to offer; the measured six-line try/finally
  // needed ~90. The server is NOT told to stop at the newline: the first break
  // is the model saying "this goes on a new line", and cutting it there returned
  // an empty string for every complete line -- which is most of real code.
  INLINE_MAX_TOKENS = 256;
  // How many lines may be SHOWN. Not a model limit -- a screen one: the ghost
  // paints over the lines that follow the caret, so a longer block would hide
  // more of the user's file than a preview has any right to.
  INLINE_MAX_LINES = 8;
  // Low but not zero: at 0 the model repeats boilerplate more eagerly.
  INLINE_TEMPERATURE = 0.1;
  // Keep the model resident far longer than the server's 5-minute default --
  // a cold 14B load off a slow disk measured 99 seconds.
  INLINE_KEEP_ALIVE_SECONDS = 1800;

type
  // Why a suggestion was not offered. Kebab-case so a caller can log it or show
  // it in a diagnostic without parsing prose -- same convention as the MCP
  // guard verdicts.
  TInlineRejectReason = (
    irNone,                 // accepted
    irEmpty,                // model returned nothing usable
    irOnlyWhitespace,       // ... or only spaces/tabs
    irDuplicatesLine,       // repeats what is already on the caret line
    irDuplicatesSuffix,     // repeats the code that already follows the caret
    irNoRoomOnLine);        // the caret is not at the end of the line

  TInlineSuggestion = record
    // The whole suggestion, one entry per line, in the order it will be
    // inserted. Empty unless Accepted. Line breaks are NOT embedded: the IDE
    // layer joins them with the platform break on accept, and paints them one
    // per editor line before that.
    Lines: TArray<string>;
    Accepted: Boolean;             // False => nothing may be painted
    Reason: TInlineRejectReason;
    // True when the model's answer belongs on a NEW line rather than as a
    // suffix of the caret line. This is the COMMON case in real code and it was
    // very nearly designed out: with `stop` set to newline the server truncated
    // exactly the token that says "next line", so the reply came back EMPTY and
    // the feature looked broken on anything but an unfinished line. Measured
    // side by side (2026-08-03): same caret, stop=newline -> '', no stop ->
    // '\n    Exit;'.
    NewLine: Boolean;
    // The block is longer than INLINE_MAX_LINES, so more of it exists than the
    // caller should paint. NOTHING has been dropped -- Lines is always the whole
    // suggestion, and accepting inserts all of it. This flag only tells the
    // painter that it is showing a part, so it can say so instead of ending the
    // preview mid-thought.
    Truncated: Boolean;
  end;

  { Sealed static namespace (house rule: no loose exported routines). }
  TAefosInlineCompletion = class sealed
  private
    class function _SplitLines(const AText: string): TArray<string>; static;
    class function _StripFence(const AText: string): string; static;
    // How many lines from AIndex onwards reproduce, in order, the code that
    // already follows the caret.
    class function _SuffixRun(const ALines, ASuffixLines: TArray<string>;
      const AIndex: Integer): Integer; static;
    class function _IsOverrun(const ALine: string): Boolean; static;
  public
    // The text BEFORE the caret, clipped to the window. Clipped at the FRONT
    // (the code nearest the caret is what matters) and never mid-line, so the
    // model is not handed half a statement as its first token.
    class function BuildPrefix(const ADocument: string;
      const ACaretOffset: Integer): string; static;
    // The text AFTER the caret, clipped at the BACK for the same reason.
    class function BuildSuffix(const ADocument: string;
      const ACaretOffset: Integer): string; static;
    // Turns a raw model reply into something paintable, or refuses it.
    //   ALineText / ACaretColumn describe the caret line so the obvious
    // no-ops can be caught: a suggestion equal to what is already there, or a
    // caret sitting in the MIDDLE of a line (where the first ghost line would be
    // painted over the user's own code).
    //   ASuffix is what already follows the caret, and it does two jobs: it
    // catches a one-line suggestion that merely repeats the next real line, and
    // it CUTS a block at the point where the model stopped inventing and started
    // reproducing the file.
    class function Sanitize(const ARaw, ALineText: string;
      const ACaretColumn: Integer;
      const ASuffix: string): TInlineSuggestion; static;
    // The first line -- what the caret line itself shows.
    class function FirstLine(const ASuggestion: TInlineSuggestion): string; static;
    class function LineCount(const ASuggestion: TInlineSuggestion): Integer; static;
    // The text to INSERT, with ALineBreak between lines. The caller passes its
    // platform break; this unit stays free of any notion of one.
    class function JoinLines(const ASuggestion: TInlineSuggestion;
      const ALineBreak: string): string; static;
    // The kebab-case name of a rejection, for logs/diagnostics.
    class function ReasonToken(const AReason: TInlineRejectReason): string; static;

    // ── The CLI path ─────────────────────────────────────────────────────────
    // A local FIM model is handed prefix and suffix and completes the hole. An
    // agentic CLI cannot do that: it is an instruct model behind a command line,
    // it has never heard of fill-in-the-middle, and it will happily answer in
    // prose. So it gets a PROMPT, and its answer gets a harder scrub.
    //   This path exists because the feature was otherwise inert for anyone
    // without Ollama installed -- which is nearly everyone. An explicit key
    // press can afford the ~4s a CLI turn costs; that is exactly why automatic
    // mode was dropped and this was not.
    class function BuildInstructPrompt(const APrefix, ASuffix: string): string; static;
    // Strips what an instruct model says AROUND the code: a lead-in sentence, a
    // sign-off, a fenced block's fence. Returns only what can be code.
    //   Deliberately NOT clever. It keeps the first fenced block when there is
    // one (models fence code far more often than they fence prose), and
    // otherwise drops leading and trailing lines that read as sentences. A line
    // is treated as prose only when it has no code punctuation at all and ends
    // like a sentence -- so `end;` and `Result := X;` are never mistaken for it.
    class function StripProse(const ARaw: string): string; static;
  end;

implementation

class function TAefosInlineCompletion.BuildPrefix(const ADocument: string;
  const ACaretOffset: Integer): string;
var
  LStart: Integer;
  LScan: Integer;
begin
  Result := '';
  if (ADocument = '') or (ACaretOffset <= 1) then
    Exit;
  LStart := ACaretOffset - INLINE_PREFIX_CHARS;
  if LStart < 1 then
    LStart := 1
  else
  begin
    // Walk FORWARD to the next line break so the window starts on a line
    // boundary. A prefix that begins mid-identifier makes the model complete
    // the fragment rather than the code.
    LScan := LStart;
    while (LScan < ACaretOffset) and (ADocument[LScan] <> #10) do
      Inc(LScan);
    if LScan < ACaretOffset then
      LStart := LScan + 1;
  end;
  Result := Copy(ADocument, LStart, ACaretOffset - LStart);
end;

class function TAefosInlineCompletion.BuildSuffix(const ADocument: string;
  const ACaretOffset: Integer): string;
var
  LLen: Integer;
  LStop: Integer;
  LScan: Integer;
begin
  Result := '';
  LLen := Length(ADocument);
  if (ADocument = '') or (ACaretOffset > LLen) then
    Exit;
  LStop := ACaretOffset + INLINE_SUFFIX_CHARS;
  if LStop > LLen then
    LStop := LLen
  else
  begin
    // Walk BACK to a line break for the same reason, in the other direction.
    LScan := LStop;
    while (LScan > ACaretOffset) and (ADocument[LScan] <> #10) do
      Dec(LScan);
    if LScan > ACaretOffset then
      LStop := LScan;
  end;
  Result := Copy(ADocument, ACaretOffset, LStop - ACaretOffset + 1);
end;

class function TAefosInlineCompletion._SplitLines(
  const AText: string): TArray<string>;
var
  LCount: Integer;
  LScan: Integer;
  LStart: Integer;
begin
  Result := nil;
  if AText = '' then
    Exit;
  LCount := 1;
  for LScan := 1 to Length(AText) do
    if AText[LScan] = #10 then
      Inc(LCount);
  SetLength(Result, LCount);
  LCount := 0;
  LStart := 1;
  for LScan := 1 to Length(AText) do
    if AText[LScan] = #10 then
    begin
      Result[LCount] := Copy(AText, LStart, LScan - LStart);
      Inc(LCount);
      LStart := LScan + 1;
    end;
  Result[LCount] := Copy(AText, LStart, Length(AText) - LStart + 1);
end;

class function TAefosInlineCompletion._StripFence(const AText: string): string;
var
  LBreak: Integer;
  LPos: Integer;
begin
  // A completion model that was asked for code sometimes answers with a fenced
  // block anyway. Strip the fence rather than paint backticks into the editor.
  Result := AText;
  if Copy(Result, 1, 3) <> '```' then
    Exit;
  LBreak := Pos(#10, Result);
  if LBreak > 0 then
    Result := Copy(Result, LBreak + 1, Length(Result))
  else
    Result := '';
  LPos := Pos('```', Result);
  if LPos > 0 then
    Result := Copy(Result, 1, LPos - 1);
end;

class function TAefosInlineCompletion._IsOverrun(const ALine: string): Boolean;
var
  LTrimmed: string;
begin
  LTrimmed := Trim(ALine);
  // `end.` terminates the UNIT: past it the model is writing a second file, not
  // finishing this statement. A closing fence anywhere means the same thing --
  // the model went back to talking. `end;` is deliberately NOT here: it is the
  // legitimate last line of most blocks worth suggesting.
  Result := SameText(LTrimmed, 'end.') or (Copy(LTrimmed, 1, 3) = '```');
end;

class function TAefosInlineCompletion._SuffixRun(const ALines,
  ASuffixLines: TArray<string>; const AIndex: Integer): Integer;
var
  LRun: Integer;
begin
  // Compared with the INDENTATION KEPT (TrimRight, not Trim), and that is the
  // whole reason this works. Measured on a real reply (2026-08-04) the model
  // closed its own try/finally with an indented "  end;" and THEN closed the
  // routine with a column-0 "end;" that the file already had, before wandering
  // into a brand-new procedure. Fully trimmed, those two lines are the same
  // string and no rule can tell "the block closing itself" from "the model
  // reproducing the file". With the leading whitespace kept they are different,
  // and one exact match is enough to cut.
  LRun := 0;
  while (AIndex + LRun <= High(ALines)) and (LRun <= High(ASuffixLines)) and
        (Trim(ALines[AIndex + LRun]) <> '') and
        SameText(TrimRight(ALines[AIndex + LRun]),
                 TrimRight(ASuffixLines[LRun])) do
    Inc(LRun);
  Result := LRun;
end;

class function TAefosInlineCompletion.Sanitize(const ARaw, ALineText: string;
  const ACaretColumn: Integer; const ASuffix: string): TInlineSuggestion;
var
  LText: string;
  LLines: TArray<string>;
  LSuffixLines: TArray<string>;
  LSuffixStart: Integer;
  LTrimmedSuffix: TArray<string>;
  LScan: Integer;
  LCut: Integer;
  LRun: Integer;
  LCutReason: TInlineRejectReason;
  LTruncated: Boolean;

  function _Reject(const AReason: TInlineRejectReason): TInlineSuggestion;
  begin
    Result := Default(TInlineSuggestion);
    Result.Reason := AReason;
  end;

begin
  Result := Default(TInlineSuggestion);
  LText := StringReplace(ARaw, #13#10, #10, [rfReplaceAll]);
  LText := StringReplace(LText, #13, #10, [rfReplaceAll]);
  LText := _StripFence(LText);
  // A leading line break is the model saying "what comes next goes on a NEW
  // line". That is the ordinary answer whenever the caret line is already
  // complete -- i.e. most of real code -- so it must be understood, not thrown
  // away.
  while (LText <> '') and (LText[1] = #10) do
  begin
    Result.NewLine := True;
    LText := Copy(LText, 2, Length(LText));
  end;
  if Trim(LText) = '' then
  begin
    if LText = '' then
      Exit(_Reject(irEmpty));
    Exit(_Reject(irOnlyWhitespace));
  end;

  LLines := _SplitLines(LText);

  // The code that already follows the caret, as lines, with the leading blanks
  // dropped so line 0 is the next REAL line.
  LSuffixLines := _SplitLines(StringReplace(
    StringReplace(ASuffix, #13#10, #10, [rfReplaceAll]), #13, #10, [rfReplaceAll]));
  LSuffixStart := 0;
  while (LSuffixStart <= High(LSuffixLines)) and
        (Trim(LSuffixLines[LSuffixStart]) = '') do
    Inc(LSuffixStart);
  SetLength(LTrimmedSuffix, Length(LSuffixLines) - LSuffixStart);
  for LScan := 0 to High(LTrimmedSuffix) do
    LTrimmedSuffix[LScan] := LSuffixLines[LSuffixStart + LScan];

  // Where the suggestion stops being a suggestion. Two ways it happens, both
  // seen live: the model runs off the end of the unit (`end.`, a closing
  // fence), or it catches up with the file and starts REPRODUCING the code that
  // is already below the caret.
  //   The second one needs care, and the obvious rule is WRONG. Cutting at any
  // line that TRIMS to the next real line would amputate the `end;` that closes
  // the block the model just wrote -- a try/finally suggestion ends in `end;`
  // and so does the routine below it, every time -- and accepting that leaves
  // the file uncompilable. The distinction that survives both cases is the
  // INDENTATION (see _SuffixRun): the block's own `end;` is indented, the file's
  // is at column 0. So one exact match, whitespace included, is enough to cut.
  LCut := Length(LLines);
  LCutReason := irNone;
  for LScan := 0 to High(LLines) do
  begin
    if _IsOverrun(LLines[LScan]) then
    begin
      LCut := LScan;
      LCutReason := irEmpty;
      Break;
    end;
    LRun := _SuffixRun(LLines, LTrimmedSuffix, LScan);
    if LRun >= 1 then
    begin
      LCut := LScan;
      LCutReason := irDuplicatesSuffix;
      Break;
    end;
  end;
  SetLength(LLines, LCut);

  // Trailing blank lines are invisible in a ghost and become real on accept.
  while (Length(LLines) > 0) and (Trim(LLines[High(LLines)]) = '') do
    SetLength(LLines, Length(LLines) - 1);
  if Length(LLines) = 0 then
  begin
    if LCutReason = irNone then
      Exit(_Reject(irOnlyWhitespace));
    Exit(_Reject(LCutReason));
  end;

  // INLINE_MAX_LINES is a PAINTING limit, and it must never become a CONTENT
  // limit. Dropping the tail here produced code that does not compile: a block
  // of `if ... then begin ... ShowValue(X);` was accepted with its `end;` cut
  // off, because the cap had thrown the last line away before Tab ever ran
  // (owner screenshot, 2026-08-04). A suggestion is offered whole or not at all;
  // the caller paints as much of it as fits and says how much it is not showing.
  LTruncated := Length(LLines) > INLINE_MAX_LINES;
  for LScan := 0 to High(LLines) do
    LLines[LScan] := TrimRight(LLines[LScan]);

  // The caret must be at the END of its line. Anywhere else, the user's own
  // text already occupies the space where the first ghost line would be drawn.
  if (ACaretColumn >= 1) and (ACaretColumn <= Length(TrimRight(ALineText))) then
    Exit(_Reject(irNoRoomOnLine));

  // A suggestion that opens with the line the user already wrote is the worst
  // failure mode of the feature: the ghost looks real and Tab appears to do
  // nothing at all.
  if SameText(Trim(LLines[0]), Trim(ALineText)) then
    Exit(_Reject(irDuplicatesLine));

  Result.Lines := LLines;
  Result.Truncated := LTruncated;
  Result.Accepted := True;
  Result.Reason := irNone;
end;

class function TAefosInlineCompletion.FirstLine(
  const ASuggestion: TInlineSuggestion): string;
begin
  if Length(ASuggestion.Lines) = 0 then
    Result := ''
  else
    Result := ASuggestion.Lines[0];
end;

class function TAefosInlineCompletion.LineCount(
  const ASuggestion: TInlineSuggestion): Integer;
begin
  Result := Length(ASuggestion.Lines);
end;

class function TAefosInlineCompletion.JoinLines(
  const ASuggestion: TInlineSuggestion; const ALineBreak: string): string;
var
  LScan: Integer;
begin
  Result := '';
  for LScan := 0 to High(ASuggestion.Lines) do
  begin
    if LScan > 0 then
      Result := Result + ALineBreak;
    Result := Result + ASuggestion.Lines[LScan];
  end;
end;

class function TAefosInlineCompletion.BuildInstructPrompt(const APrefix,
  ASuffix: string): string;
begin
  // Everything in here is an instruction the FIM path does not need, and every
  // line of it is paying for a behaviour an instruct model exhibits by default:
  // it explains, it apologises, it repeats the code you gave it, and it wraps
  // the answer in a fence. Saying "no explanation" once is not enough -- the
  // shape of the request has to make prose obviously wrong.
  Result :=
    'Continue this Delphi source file at the cursor marker.' + #10 +
    'Reply with the code that belongs at the marker and NOTHING else: no' + #10 +
    'explanation, no commentary, no markdown fence, no repetition of the code' + #10 +
    'that is already there. Keep the indentation of the surrounding code.' + #10 +
    'Always answer with at least one line of code -- your best guess at what' + #10 +
    'the developer is about to type.' + #10 + #10 +
    '=== BEFORE THE CURSOR ===' + #10 +
    APrefix + #10 +
    '=== AFTER THE CURSOR ===' + #10 +
    ASuffix;
end;

class function TAefosInlineCompletion.StripProse(const ARaw: string): string;
var
  LLines: TArray<string>;
  LFirst: Integer;
  LLast: Integer;
  LScan: Integer;
  LFenceStart: Integer;
  LFenceEnd: Integer;
  LText: string;

  // A line with no code punctuation at all that ends like a sentence. The test
  // is deliberately conservative in the direction that matters: keeping a line
  // of prose is ugly, but DROPPING a line of code is a broken paste.
  function _IsProse(const ALine: string): Boolean;
  var
    LTrim: string;
  begin
    LTrim := Trim(ALine);
    Result := False;
    if LTrim = '' then
      Exit;
    if (Pos(';', LTrim) > 0) or (Pos(':=', LTrim) > 0) or (Pos('(', LTrim) > 0) or
       (Pos('//', LTrim) > 0) or (Pos('{', LTrim) > 0) then
      Exit;
    Result := (LTrim[Length(LTrim)] = ':') or (LTrim[Length(LTrim)] = '.') or
              (Pos(' ', LTrim) > 0);
  end;

begin
  LText := StringReplace(ARaw, #13#10, #10, [rfReplaceAll]);
  LText := StringReplace(LText, #13, #10, [rfReplaceAll]);
  LLines := _SplitLines(LText);
  if Length(LLines) = 0 then
    Exit('');

  // A fenced block wins outright. When a model fences anything, it is the code.
  LFenceStart := -1;
  for LScan := 0 to High(LLines) do
    if Copy(Trim(LLines[LScan]), 1, 3) = '```' then
    begin
      LFenceStart := LScan;
      Break;
    end;
  if LFenceStart >= 0 then
  begin
    LFenceEnd := Length(LLines);
    for LScan := LFenceStart + 1 to High(LLines) do
      if Copy(Trim(LLines[LScan]), 1, 3) = '```' then
      begin
        LFenceEnd := LScan;
        Break;
      end;
    Result := '';
    for LScan := LFenceStart + 1 to LFenceEnd - 1 do
    begin
      if Result <> '' then
        Result := Result + #10;
      Result := Result + LLines[LScan];
    end;
    Exit;
  end;

  // No fence: shave prose off both ends, never from the middle. A sentence
  // BETWEEN two lines of code is far more likely to be a comment the model
  // wrote badly than something worth deleting from the user's paste.
  LFirst := 0;
  while (LFirst <= High(LLines)) and
        ((Trim(LLines[LFirst]) = '') or _IsProse(LLines[LFirst])) do
    Inc(LFirst);
  LLast := High(LLines);
  while (LLast >= LFirst) and
        ((Trim(LLines[LLast]) = '') or _IsProse(LLines[LLast])) do
    Dec(LLast);
  Result := '';
  for LScan := LFirst to LLast do
  begin
    if LScan > LFirst then
      Result := Result + #10;
    Result := Result + LLines[LScan];
  end;
end;

class function TAefosInlineCompletion.ReasonToken(
  const AReason: TInlineRejectReason): string;
begin
  case AReason of
    irNone: Result := 'accepted';
    irEmpty: Result := 'inline-empty';
    irOnlyWhitespace: Result := 'inline-only-whitespace';
    irDuplicatesLine: Result := 'inline-duplicates-line';
    irDuplicatesSuffix: Result := 'inline-duplicates-suffix';
    irNoRoomOnLine: Result := 'inline-no-room-on-line';
  else
    Result := '';
  end;
end;

end.
