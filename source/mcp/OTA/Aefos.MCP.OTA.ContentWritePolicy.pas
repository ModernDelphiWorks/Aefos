unit Aefos.MCP.OTA.ContentWritePolicy;

{
  Pure content-write policy seam (ESP-087, S2 / ADR-087-07 / BR10).

  Pure RTL + the frozen Core PasParser — no ToolsAPI, no VCL, no disk write.
  Carries every OTA-free decision the six editor-manipulation content writes
  must make before the facade touches an IOTAEditWriter or the disk:

    - InsertTextAt        — insert at a (line, col) caret position
                            (backs InsertCodeAtCursor)
    - ReplaceTextRange    — replace a (startLine,startCol)..(endLine,endCol)
                            selection (backs ReplaceEditorSelection)
    - ReplaceInBuffer     — find/replace over a buffer, all-or-first, with the
                            replacement count (backs ReplaceInEditor)
    - PlanMethodInsertion — resolve target class, find the class-decl and the
                            implementation insertion points, assemble the
                            qualified method, and emit the new full source
                            (backs InsertMethod)
    - ConfineWritePath    — confine an OverwriteFile target to a root directory,
                            refusing absolute / `..` escapes (backs OverwriteFile,
                            ADR-087-07 confinement)

  Every buffer surgery returns the COMPLETE new source, so the UI facade owns a
  single OTA primitive (whole-buffer replace via one undoable IOTAEditWriter, R1)
  fed by these pure decisions. This mirrors the ESP-073 UnitCreatePolicy
  precedent: a pure, dependency-free seam unit-tested headless with a thin OTA
  caller (the only OTA-bound, structurally-exempt part, covered live, AC7).

  Line/column inputs are 1-based; column 1 is the position before the first
  character of the line (OTA caret convention). Tab-expanded columns are not
  modelled — the scratch buffers are space-indented Pascal (documented
  assumption, ESP-087 constraints).
}

interface

type
  // Resolved OverwriteFile decision. When Accepted, FullPath is the confined
  // absolute path the facade will write; otherwise Reason explains the refusal
  // (no bytes written — ADR-087-07 non-partial sentinel).
  TConfinedWrite = record
    Accepted: Boolean;
    FullPath: string;   // confined absolute target (accepted only)
    Reason: string;     // kebab refusal reason (rejected only)
  end;

  // Pure content-write policy seam as a sealed static namespace
  // (see the unit header for the ESP-087 / ADR-087 contract). Never instantiated.
  TContentWritePolicy = class sealed
  public
    // Insert AText at the (ALine, ACol) caret in ASource, returning the new full
    // source in ANew. False (with ASource echoed) when the caret is unresolvable.
    class function InsertTextAt(const ASource, AText: string;
      const ALine, ACol: Integer; out ANew: string): Boolean; static;

    // Replace the [ (AStartLine,AStartCol) , (AEndLine,AEndCol) ) range of ASource
    // with ANewText. End column is exclusive (OTA block convention). False when the
    // range is degenerate or unresolvable.
    class function ReplaceTextRange(const ASource, ANewText: string;
      const AStartLine, AStartCol, AEndLine, AEndCol: Integer;
      out ANew: string): Boolean; static;

    // Find/replace AFind with AReplace over ASource. AAll replaces every match;
    // otherwise only the first. ACount carries the number of substitutions. Always
    // succeeds (a zero-match call is a valid no-op returning ACount = 0); False only
    // when AFind is empty (nothing to search for).
    class function ReplaceInBuffer(const ASource, AFind, AReplace: string;
      const AAll: Boolean; out ANew: string; out ACount: Integer): Boolean; static;

    // Resolve AClassName in ASource, assemble the qualified method from ASignature
    // + ABody, and emit the new full source with the declaration inserted into the
    // class and the implementation inserted before the unit terminator. False (with
    // AReason a kebab cause: class-not-found / invalid-signature / malformed-unit)
    // when the unit cannot host the method. AMethodName carries the parsed name.
    class function PlanMethodInsertion(const ASource, AClassName, ASignature, ABody: string;
      out ANew, AMethodName, AReason: string): Boolean; static;

    // Confine ATargetPath to ARootDir. Accepts only when the canonical target
    // resolves inside the root; refuses absolute-elsewhere / `..`-escape / blank-root
    // targets with a kebab reason and no FullPath (ADR-087-07).
    class function ConfineWritePath(const ATargetPath, ARootDir: string): TConfinedWrite; static;

    // Re-indent ABody to a method body: strips the common leading indent (keeping
    // relative nesting) and prefixes 2 spaces; blank lines stay blank. Shared so a
    // caller can render a body block IDENTICALLY to PlanMethodInsertion (e.g. the
    // AddEventHandler review diff that fills an empty stub's begin..end).
    class function IndentMethodBody(const ABody: string): TArray<string>; static;
  end;

implementation

uses
  System.SysUtils,
  System.IOUtils,
  System.Generics.Collections,
  Aefos.MCP.PasParser;

const
  CIdentFirst = ['A'..'Z', 'a'..'z', '_'];
  CIdentRest  = ['A'..'Z', 'a'..'z', '0'..'9', '_'];

// ---------------------------------------------------------------------------
// EOL handling — preserve the unit's dominant line ending across a surgery.
// ---------------------------------------------------------------------------

function _DetectEol(const ASource: string): string;
begin
  if ASource.Contains(#13#10) then
    Result := #13#10
  else if ASource.Contains(#10) then
    Result := #10
  else if ASource.Contains(#13) then
    Result := #13
  else
    Result := #13#10;
end;

// Re-encode any line endings inside AText to AEol so inserted text matches the
// host buffer.
function _NormalizeEol(const AText, AEol: string): string;
begin
  Result := AText.Replace(#13#10, #10, [rfReplaceAll])
                 .Replace(#13, #10, [rfReplaceAll])
                 .Replace(#10, AEol, [rfReplaceAll]);
end;

// 1-based character index in ASource of the (ALine, ACol) caret. CRLF counts as
// one line break. A caret past the end clamps to Length+1.
function _IndexOfLineCol(const ASource: string;
  const ALine, ACol: Integer): Integer;
var
  LIdx, LLine, LCol: Integer;
begin
  LLine := 1;
  LCol  := 1;
  LIdx  := 1;
  while LIdx <= Length(ASource) do
  begin
    if (LLine = ALine) and (LCol = ACol) then
      Exit(LIdx);
    case ASource[LIdx] of
      #13:
        begin
          if (LIdx < Length(ASource)) and (ASource[LIdx + 1] = #10) then
            Inc(LIdx);
          Inc(LLine);
          LCol := 1;
        end;
      #10:
        begin
          Inc(LLine);
          LCol := 1;
        end;
    else
      Inc(LCol);
    end;
    Inc(LIdx);
  end;
  Result := Length(ASource) + 1;
end;

// ---------------------------------------------------------------------------
// InsertTextAt / ReplaceTextRange — caret- and range-targeted edits.
// ---------------------------------------------------------------------------

class function TContentWritePolicy.InsertTextAt(const ASource, AText: string;
  const ALine, ACol: Integer; out ANew: string): Boolean;
var
  LAt: Integer;
begin
  ANew := ASource;
  Result := False;
  if (ALine < 1) or (ACol < 1) then
    Exit;
  LAt := _IndexOfLineCol(ASource, ALine, ACol);
  ANew := Copy(ASource, 1, LAt - 1) +
          _NormalizeEol(AText, _DetectEol(ASource)) +
          Copy(ASource, LAt, MaxInt);
  Result := True;
end;

class function TContentWritePolicy.ReplaceTextRange(const ASource, ANewText: string;
  const AStartLine, AStartCol, AEndLine, AEndCol: Integer;
  out ANew: string): Boolean;
var
  LStart, LEnd: Integer;
begin
  ANew := ASource;
  Result := False;
  if (AStartLine < 1) or (AStartCol < 1) or (AEndLine < 1) or (AEndCol < 1) then
    Exit;
  LStart := _IndexOfLineCol(ASource, AStartLine, AStartCol);
  LEnd   := _IndexOfLineCol(ASource, AEndLine, AEndCol);
  if LEnd < LStart then
    Exit;
  ANew := Copy(ASource, 1, LStart - 1) +
          _NormalizeEol(ANewText, _DetectEol(ASource)) +
          Copy(ASource, LEnd, MaxInt);
  Result := True;
end;

// ---------------------------------------------------------------------------
// ReplaceInBuffer — counted find/replace, all or first.
// ---------------------------------------------------------------------------

class function TContentWritePolicy.ReplaceInBuffer(const ASource, AFind, AReplace: string;
  const AAll: Boolean; out ANew: string; out ACount: Integer): Boolean;
var
  LBuilder: TStringBuilder;
  LAt, LFrom: Integer;
begin
  ANew := ASource;
  ACount := 0;
  if AFind = '' then
    Exit(False);

  LBuilder := TStringBuilder.Create;
  try
    LFrom := 1;
    repeat
      LAt := ASource.IndexOf(AFind, LFrom - 1) + 1; // 1-based hit, 0 when none
      if LAt = 0 then
        Break;
      LBuilder.Append(Copy(ASource, LFrom, LAt - LFrom));
      LBuilder.Append(AReplace);
      Inc(ACount);
      LFrom := LAt + Length(AFind);
      if not AAll then
        Break;
    until False;
    LBuilder.Append(Copy(ASource, LFrom, MaxInt));
    ANew := LBuilder.ToString;
  finally
    LBuilder.Free;
  end;
  Result := True;
end;

// ---------------------------------------------------------------------------
// PlanMethodInsertion — structured method insertion (decl + impl).
// ---------------------------------------------------------------------------

// Significant (non-trivia) tokens, preserving line numbers — structural scans
// ignore whitespace and comments.
function _SignificantTokens(
  const ATokens: TArray<TPasToken>): TArray<TPasToken>;
var
  LList: TList<TPasToken>;
  LFor: Integer;
begin
  LList := TList<TPasToken>.Create;
  try
    for LFor := 0 to High(ATokens) do
      if not (ATokens[LFor].Kind in [tkWhitespace, tkComment]) then
        LList.Add(ATokens[LFor]);
    Result := LList.ToArray;
  finally
    LList.Free;
  end;
end;

// Index in ASig of the `class`/`object` keyword that opens AClassName's body,
// or -1 when no hostable declaration is found (forward decl / `class of` are
// skipped — they open no block).
function _FindClassHeaderStart(const ASig: TArray<TPasToken>;
  const AClassName: string): Integer;
var
  LFor: Integer;
  LNextLow: string;
begin
  Result := -1;
  for LFor := 0 to High(ASig) - 3 do
    if (ASig[LFor].Kind = tkIdentifier) and
       SameText(ASig[LFor].Text, AClassName) and
       (ASig[LFor + 1].Text = '=') and
       (SameText(ASig[LFor + 2].Text, 'class') or
        SameText(ASig[LFor + 2].Text, 'object')) then
    begin
      LNextLow := ASig[LFor + 3].Lower;
      if (LNextLow = ';') or (LNextLow = 'of') then
        Continue; // forward decl or `class of` — not a hostable body
      Exit(LFor + 2);
    end;
end;

// Line of the `end` that closes the block opened at AStartIdx (the class/object
// keyword), tracking record/case nesting, or 0 when the block never balances.
function _MatchingEndLine(const ASig: TArray<TPasToken>;
  const AStartIdx: Integer): Integer;
var
  LFor, LDepth: Integer;
  LLow: string;
begin
  Result := 0;
  LDepth := 1; // the opening class/object keyword
  for LFor := AStartIdx + 1 to High(ASig) do
  begin
    LLow := ASig[LFor].Lower;
    if (LLow = 'record') or (LLow = 'case') then
      Inc(LDepth)
    else if LLow = 'end' then
    begin
      Dec(LDepth);
      if LDepth = 0 then
        Exit(ASig[LFor].Line);
    end;
  end;
end;

// Line of the `end` that closes AClassName's declaration, or 0 when the class
// body is not found. Tracks record/case nesting; ignores `class procedure` /
// `class function` member modifiers (they open no block).
function _ClassDeclEndLine(const ATokens: TArray<TPasToken>;
  const AClassName: string): Integer;
var
  LSig: TArray<TPasToken>;
  LStart: Integer;
begin
  Result := 0;
  LSig := _SignificantTokens(ATokens);
  LStart := _FindClassHeaderStart(LSig, AClassName);
  if LStart < 0 then
    Exit;
  Result := _MatchingEndLine(LSig, LStart);
end;

// Line of the unit terminator `end.`, or 0 when absent.
function _UnitEndLine(const ATokens: TArray<TPasToken>): Integer;
var
  LSig: TArray<TPasToken>;
  LFor: Integer;
begin
  Result := 0;
  LSig := _SignificantTokens(ATokens);
  for LFor := High(LSig) downto 1 do
    if SameText(LSig[LFor].Text, '.') and SameText(LSig[LFor - 1].Text, 'end') then
      Exit(LSig[LFor - 1].Line);
end;

// Split off the leading identifier of ARest, returning the name and the tail
// (params + return type, minus any trailing `;`).
procedure _SplitNameAndTail(const ARest: string; out AName, ATail: string);
var
  LIdx: Integer;
begin
  AName := '';
  ATail := '';
  if (ARest = '') or not CharInSet(ARest[1], CIdentFirst) then
    Exit;
  LIdx := 1;
  while (LIdx <= Length(ARest)) and CharInSet(ARest[LIdx], CIdentRest) do
    Inc(LIdx);
  AName := Copy(ARest, 1, LIdx - 1);
  ATail := Copy(ARest, LIdx, MaxInt).TrimRight([';', ' ', #9]);
end;

// Build the qualified implementation header (`procedure TFoo.Bar(...);`) from a
// declaration signature, and surface the method name. False on a malformed
// signature (no kind keyword / no method name).
function _QualifyHeader(const ASignature, AClassName: string;
  out AHeader, AMethodName: string): Boolean;
var
  LCore, LPrefix, LKind, LAfterKind, LTail: string;
  LSpace: Integer;
begin
  AHeader := '';
  AMethodName := '';
  LCore := ASignature.Trim.TrimRight([';']).Trim;
  if LCore = '' then
    Exit(False);

  // Optional `class ` method modifier kept ahead of the kind keyword.
  LPrefix := '';
  if LCore.ToLower.StartsWith('class ') then
  begin
    LPrefix := 'class ';
    LCore := Copy(LCore, Length('class ') + 1, MaxInt).Trim;
  end;

  LSpace := Pos(' ', LCore);
  if LSpace = 0 then
    Exit(False);
  LKind := Copy(LCore, 1, LSpace - 1);
  LAfterKind := Copy(LCore, LSpace + 1, MaxInt).Trim;

  _SplitNameAndTail(LAfterKind, AMethodName, LTail);
  if AMethodName = '' then
    Exit(False);

  AHeader := LPrefix + LKind + ' ' + AClassName + '.' + AMethodName + LTail + ';';
  Result := True;
end;

function _Lines(const ASource: string): TArray<string>;
var
  LNorm: string;
begin
  LNorm := ASource.Replace(#13#10, #10, [rfReplaceAll]).Replace(#13, #10, [rfReplaceAll]);
  Result := LNorm.Split([#10]);
end;

// Count the leading ASCII spaces of a line (0 for a flush-left or blank line).
function _LeadingSpaces(const ALine: string): Integer;
var
  LFor: Integer;
begin
  Result := 0;
  for LFor := 1 to Length(ALine) do
    if ALine[LFor] = ' ' then
      Inc(Result)
    else
      Break;
end;

// Indent every non-blank body line by two spaces for the implementation block.
// The caller's body is first DEDENTED (the common leading indentation across all
// non-blank lines is stripped) so a flush-left body and an already-indented body
// come out identical — the caller's indentation never STACKS on top of ours.
// Relative nesting is preserved (a line indented one extra level stays nested).
function _IndentBody(const ABody: string): TArray<string>;
var
  LLines: TArray<string>;
  LFor, LMin, LLead: Integer;
  LLine: string;
  LList: TList<string>;
begin
  LList := TList<string>.Create;
  try
    if ABody.Trim <> '' then
    begin
      LLines := _Lines(ABody);
      LMin := MaxInt;
      for LFor := 0 to High(LLines) do
        if LLines[LFor].Trim <> '' then
        begin
          LLead := _LeadingSpaces(LLines[LFor]);
          if LLead < LMin then
            LMin := LLead;
        end;
      if LMin = MaxInt then
        LMin := 0;
      for LFor := 0 to High(LLines) do
        if LLines[LFor].Trim = '' then
          LList.Add('')
        else
        begin
          LLine := LLines[LFor].TrimRight;
          if LMin > 0 then
            Delete(LLine, 1, LMin); // strip the common indent, keep relative nesting
          LList.Add('  ' + LLine);
        end;
    end;
    Result := LList.ToArray;
  finally
    LList.Free;
  end;
end;

class function TContentWritePolicy.IndentMethodBody(const ABody: string): TArray<string>;
begin
  Result := _IndentBody(ABody);
end;

// Line of the first explicit visibility specifier (private / protected / public
// / published / strict / automated) inside AClassName's body, or 0 when the
// class declares none. Everything between the class header and that first
// specifier is the IDE's implicit published, auto-managed section — where the
// designer puts fields (Button1: TButton) and event handlers (FormCreate). A
// new event handler MUST join them there, NOT in a trailing `public` block, or
// the IDE won't recognise it as a designer-managed handler (intent->view
// policy, CLAUDE.md). Returns 0 => no explicit section => the whole body is
// published, so the caller falls back to inserting before the closing `end`.
function _PublishedSectionEndLine(const ATokens: TArray<TPasToken>;
  const AClassName: string): Integer;
var
  LSig: TArray<TPasToken>;
  LStart, LEndLine, LFor: Integer;
  LLow: string;
begin
  Result := 0;
  LSig := _SignificantTokens(ATokens);
  LStart := _FindClassHeaderStart(LSig, AClassName);
  if LStart < 0 then
    Exit;
  LEndLine := _MatchingEndLine(LSig, LStart);
  if LEndLine = 0 then
    Exit;
  for LFor := LStart + 1 to High(LSig) do
  begin
    if LSig[LFor].Line >= LEndLine then
      Break; // never spill past this class's `end` into a later type
    LLow := LSig[LFor].Lower;
    if (LLow = 'private') or (LLow = 'protected') or (LLow = 'public') or
       (LLow = 'published') or (LLow = 'strict') or (LLow = 'automated') then
    begin
      // A real specifier is a bare keyword; a member that merely happens to be
      // named like one (`Public: Integer;` / `Public = 1;`) is followed by ':'
      // or '=' — skip those false positives.
      if (LFor < High(LSig)) and
         ((LSig[LFor + 1].Text = ':') or (LSig[LFor + 1].Text = '=')) then
        Continue;
      Exit(LSig[LFor].Line);
    end;
  end;
end;

class function TContentWritePolicy.PlanMethodInsertion(const ASource, AClassName, ASignature, ABody: string;
  out ANew, AMethodName, AReason: string): Boolean;
var
  LTokens: TArray<TPasToken>;
  LClassEnd, LUnitEnd, LDeclLine: Integer;
  LHeader, LEol: string;
  LLines, LBodyLines: TArray<string>;
  LResult: TList<string>;
  LFor: Integer;
  LDecl: string;
begin
  ANew := ASource;
  AMethodName := '';
  AReason := '';

  if Trim(AClassName) = '' then
  begin
    AReason := 'class-not-found';
    Exit(False);
  end;

  LTokens := TPasParser.Tokenize(ASource);
  LClassEnd := _ClassDeclEndLine(LTokens, AClassName);
  if LClassEnd = 0 then
  begin
    AReason := 'class-not-found';
    Exit(False);
  end;

  LUnitEnd := _UnitEndLine(LTokens);
  if LUnitEnd = 0 then
  begin
    AReason := 'malformed-unit';
    Exit(False);
  end;

  if not _QualifyHeader(ASignature, AClassName, LHeader, AMethodName) then
  begin
    AReason := 'invalid-signature';
    Exit(False);
  end;

  // Declaration target: the implicit published section (just before the first
  // explicit visibility specifier) so handlers join the designer-managed
  // members; only when the class declares no explicit section does the whole
  // body count as published and the decl goes before the closing `end`.
  LDeclLine := _PublishedSectionEndLine(LTokens, AClassName);
  if LDeclLine = 0 then
    LDeclLine := LClassEnd;

  LEol := _DetectEol(ASource);
  LDecl := '    ' + ASignature.Trim;
  if not LDecl.EndsWith(';') then
    LDecl := LDecl + ';';
  LBodyLines := _IndentBody(ABody);

  LLines := _Lines(ASource);
  LResult := TList<string>.Create;
  try
    for LFor := 0 to High(LLines) do
    begin
      // Implementation block goes just before the unit terminator line; the
      // declaration just before the class's closing `end` line. Both indices
      // are read from the original token lines, so inserting before each line
      // as we stream keeps them correct (decl line < unit-end line).
      if LFor = LUnitEnd - 1 then
      begin
        // Separate from the preceding code with EXACTLY one blank line: add the
        // leading blank ONLY when the previous emitted line isn't already blank.
        // Each method also emits its own trailing blank, so two methods inserted
        // one-per-call would otherwise double up (prev's trailing + next's
        // leading = 2 blanks); this collapses adjacent methods to a single blank
        // line (the IDE convention) and also covers a unit with no blank before
        // the terminating `end.`.
        if (LResult.Count > 0) and (LResult[LResult.Count - 1].Trim <> '') then
          LResult.Add('');
        LResult.Add(LHeader);
        LResult.Add('begin');
        LResult.AddRange(LBodyLines);
        LResult.Add('end;');
        LResult.Add('');
      end;
      if LFor = LDeclLine - 1 then
        LResult.Add(LDecl);
      LResult.Add(LLines[LFor]);
    end;
    ANew := string.Join(LEol, LResult.ToArray);
  finally
    LResult.Free;
  end;
  Result := True;
end;

// ---------------------------------------------------------------------------
// ConfineWritePath — OverwriteFile target confinement (ADR-087-07).
// ---------------------------------------------------------------------------

// Case-insensitive containment of a normalized absolute path under a normalized
// absolute root. The trailing delimiter stops `app` matching `app-evil`.
function _IsWithinRoot(const AFull, ARootFull: string): Boolean;
var
  LRootSlash: string;
begin
  LRootSlash := IncludeTrailingPathDelimiter(ARootFull);
  Result := AFull.StartsWith(LRootSlash, True) or
            SameText(AFull, ExcludeTrailingPathDelimiter(LRootSlash));
end;

class function TContentWritePolicy.ConfineWritePath(const ATargetPath, ARootDir: string): TConfinedWrite;
var
  LRootFull, LCombined, LFull: string;
begin
  Result := Default(TConfinedWrite);

  if Trim(ARootDir) = '' then
  begin
    Result.Reason := 'no-active-editor';
    Exit;
  end;
  if Trim(ATargetPath) = '' then
  begin
    Result.Reason := 'empty-path';
    Exit;
  end;

  // Pure normalization — TPath.GetFullPath does not touch the disk. A target
  // that fails to normalize is treated as an escape (cannot be confined).
  try
    if TPath.IsPathRooted(ATargetPath) then
      LCombined := ATargetPath
    else
      LCombined := TPath.Combine(ARootDir, ATargetPath);
    LRootFull := TPath.GetFullPath(ARootDir);
    LFull     := TPath.GetFullPath(LCombined);
  except
    Result.Reason := 'path-escape';
    Exit;
  end;

  if not _IsWithinRoot(LFull, LRootFull) then
  begin
    Result.Reason := 'path-escape';
    Exit;
  end;

  Result.Accepted := True;
  Result.FullPath := LFull;
end;

end.
