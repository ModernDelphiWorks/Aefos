unit Aefos.MCP.PasParser;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

(*
  Minimal Pascal source parser for the Code Insight MCP tools
  (ESP-002, Epic 7/7 Demand 7/8, ADR-142/143).

  Scope (BR-3 / BR-6):
    - Tokenizes `.pas` source into identifier, keyword, string, comment,
      symbol, number, and whitespace tokens.
    - Enumerates top-level declarations (class, record, interface, function,
      procedure, var, const, type) for GetSymbolsInUnit.
    - Enumerates class members (fields, methods, properties) with visibility
      for GetClassMembers.
    - Locates a method body (begin..end of the matching `procedure`/
      `function` in the implementation section) for GetMethodBody.
    - Enumerates token-bounded identifier usages for FindSymbolUsages
      (strings + comments excluded; substring matches discarded — ADR-143).
    - Computes the parent-class link for the inheritance chain helper.
    - Locates the interface section's `end.` for InsertMethod's interface
      anchor and the implementation section's `end.` for the body anchor.

  Out of scope (BR-6 — degrades to "pas-parse-error" at the tool layer):
    - Generic constraints, attributes, anonymous methods, inline vars.

  Boundary (ADR-115 / BR-1): zero `uses ToolsAPI`. RTL-only.
*)

interface

type
  TPasTokenKind = (
    tkUnknown,
    tkWhitespace,
    tkComment,
    tkString,
    tkNumber,
    tkIdentifier,
    tkKeyword,
    tkSymbol
  );

  TPasToken = record
    Kind: TPasTokenKind;
    Text: string;        // raw token text
    Lower: string;       // LowerCase(Text) — cached for identifier matches
    Line: Integer;       // 1-based
    Column: Integer;     // 1-based
  end;

  // Symbol kind for GetSymbolsInUnit (BR-6).
  TPasSymbolKind = (
    skClass,
    skRecord,
    skInterface,
    skFunction,
    skProcedure,
    skVar,
    skConst,
    skType
  );

  TPasSymbolRef = record
    Name: string;
    Kind: TPasSymbolKind;
    Line: Integer;       // 1-based line of declaration
  end;

  TPasVisibility = (
    vPublished,          // default block before any visibility keyword
    vPrivate,
    vProtected,
    vPublic,
    vAutomated
  );

  TPasMemberKind = (
    mkField,
    mkMethod,
    mkProperty,
    mkConst,
    mkType
  );

  TPasMemberRef = record
    Name: string;
    Kind: TPasMemberKind;
    Visibility: TPasVisibility;
    Line: Integer;
  end;

  TPasIdentifierUsage = record
    Line: Integer;
    Column: Integer;
    Context: string;     // entire source line containing the match
  end;

type
  // Pure line/token Pascal parser as a sealed static namespace (never
  // instantiated) — every method is side-effect-free.
  TPasParser = class sealed
  public
    class function Tokenize(const ASource: string): TArray<TPasToken>; static;

    class function FindUnitSymbols(
      const ATokens: TArray<TPasToken>): TArray<TPasSymbolRef>; static;

    // Returns the visibility-tagged members of AClassName declared anywhere in
    // ATokens. Returns an empty array when the class is not declared.
    class function FindClassMembers(const ATokens: TArray<TPasToken>;
      const AClassName: string): TArray<TPasMemberRef>; static;

    // Returns the verbatim source between `begin` and the matching `end;` for
    // the first implementation-section method whose unqualified or qualified
    // name matches AMethodName (case-insensitive). Empty when not found.
    class function FindMethodBody(const ASource: string;
      const ATokens: TArray<TPasToken>;
      const AMethodName: string): string; static;

    // Returns the parent class name of AClassName declared in ATokens, or empty
    // when AClassName is not declared or has no explicit ancestor.
    class function FindParentClassName(const ATokens: TArray<TPasToken>;
      const AClassName: string): string; static;

    // Enumerates every token-bounded identifier usage of ASymbol inside
    // ASource (case-insensitive). Strings, comments and partial matches are
    // skipped per ADR-143.
    class function EnumerateIdentifierUsages(const ASource: string;
      const ATokens: TArray<TPasToken>;
      const ASymbol: string): TArray<TPasIdentifierUsage>; static;

    // Symbol-kind string for the MCP `kind` field on GetSymbolsInUnit.
    class function SymbolKindToString(const AKind: TPasSymbolKind): string; static;
    // Member-kind string for the MCP `kind` field on GetClassMembers.
    class function MemberKindToString(const AKind: TPasMemberKind): string; static;
    // Visibility string for the MCP `visibility` field on GetClassMembers.
    class function VisibilityToString(const AVisibility: TPasVisibility): string; static;
  end;

implementation

uses
  SysUtils,
  Generics.Collections;

// ── Keyword set ───────────────────────────────────────────────────────

function _IsPascalKeyword(const ALower: string): Boolean;
const
  CKeywords: array[0..47] of string = (
    'and','array','as','asm','begin','case','class','const','constructor',
    'destructor','div','do','downto','else','end','except','file','finally',
    'for','function','goto','if','implementation','in','inherited','initialization',
    'inline','interface','is','label','mod','nil','not','object','of','or',
    'packed','procedure','program','property','record','repeat','set','shl',
    'shr','string','then','threadvar'
  );
  CKeywords2: array[0..19] of string = (
    'to','try','type','unit','until','uses','var','while','with','xor',
    'finalization','library','out','resourcestring','strict',
    'private','protected','public','published','automated'
  );
var
  LFor: Integer;
begin
  for LFor := 0 to High(CKeywords) do
    if ALower = CKeywords[LFor] then
      Exit(True);
  for LFor := 0 to High(CKeywords2) do
    if ALower = CKeywords2[LFor] then
      Exit(True);
  Result := False;
end;

// ── Tokenizer helpers ────────────────────────────────────────────────

procedure _SkipWhitespace(const ASource: string; var APos: Integer;
  var ALine, ACol: Integer);
var
  LCh: Char;
begin
  while APos <= Length(ASource) do
  begin
    LCh := ASource[APos];
    if LCh = #13 then
    begin
      Inc(APos);
      if (APos <= Length(ASource)) and (ASource[APos] = #10) then
        Inc(APos);
      Inc(ALine);
      ACol := 1;
    end
    else if LCh = #10 then
    begin
      Inc(APos);
      Inc(ALine);
      ACol := 1;
    end
    else if (LCh = ' ') or (LCh = #9) then
    begin
      Inc(APos);
      Inc(ACol);
    end
    else
      Break;
  end;
end;

procedure _ReadBraceComment(const ASource: string; var APos: Integer;
  var ALine, ACol: Integer; out AText: string);
var
  LStart: Integer;
  LCh: Char;
begin
  LStart := APos;
  Inc(APos); Inc(ACol);  // skip '{'
  while APos <= Length(ASource) do
  begin
    LCh := ASource[APos];
    if LCh = '}' then
    begin
      Inc(APos); Inc(ACol);
      Break;
    end
    else if LCh = #13 then
    begin
      Inc(APos);
      if (APos <= Length(ASource)) and (ASource[APos] = #10) then
        Inc(APos);
      Inc(ALine);
      ACol := 1;
    end
    else if LCh = #10 then
    begin
      Inc(APos);
      Inc(ALine);
      ACol := 1;
    end
    else
    begin
      Inc(APos); Inc(ACol);
    end;
  end;
  AText := Copy(ASource, LStart, APos - LStart);
end;

procedure _ReadParenStarComment(const ASource: string; var APos: Integer;
  var ALine, ACol: Integer; out AText: string);
var
  LStart: Integer;
  LCh: Char;
begin
  LStart := APos;
  Inc(APos, 2); Inc(ACol, 2);  // skip '(*'
  while APos < Length(ASource) do
  begin
    LCh := ASource[APos];
    if (LCh = '*') and (ASource[APos + 1] = ')') then
    begin
      Inc(APos, 2); Inc(ACol, 2);
      Break;
    end
    else if LCh = #13 then
    begin
      Inc(APos);
      if (APos <= Length(ASource)) and (ASource[APos] = #10) then
        Inc(APos);
      Inc(ALine);
      ACol := 1;
    end
    else if LCh = #10 then
    begin
      Inc(APos);
      Inc(ALine);
      ACol := 1;
    end
    else
    begin
      Inc(APos); Inc(ACol);
    end;
  end;
  AText := Copy(ASource, LStart, APos - LStart);
end;

procedure _ReadLineComment(const ASource: string; var APos: Integer;
  var ACol: Integer; out AText: string);
var
  LStart: Integer;
begin
  LStart := APos;
  while (APos <= Length(ASource))
    and (ASource[APos] <> #13) and (ASource[APos] <> #10) do
  begin
    Inc(APos); Inc(ACol);
  end;
  AText := Copy(ASource, LStart, APos - LStart);
end;

procedure _ReadString(const ASource: string; var APos: Integer;
  var ACol: Integer; out AText: string);
var
  LStart: Integer;
begin
  // Pascal string: '...' with '' as escaped quote. Stops at EOL or end.
  LStart := APos;
  Inc(APos); Inc(ACol);
  while APos <= Length(ASource) do
  begin
    if ASource[APos] = '''' then
    begin
      Inc(APos); Inc(ACol);
      if (APos <= Length(ASource)) and (ASource[APos] = '''') then
      begin
        // Escaped quote — continue.
        Inc(APos); Inc(ACol);
      end
      else
        Break;
    end
    else if (ASource[APos] = #13) or (ASource[APos] = #10) then
      Break
    else
    begin
      Inc(APos); Inc(ACol);
    end;
  end;
  AText := Copy(ASource, LStart, APos - LStart);
end;

function _IsIdentStart(const ACh: Char): Boolean;
begin
  Result := CharInSet(ACh, ['A'..'Z', 'a'..'z', '_']);
end;

function _IsIdentCont(const ACh: Char): Boolean;
begin
  Result := CharInSet(ACh, ['A'..'Z', 'a'..'z', '_', '0'..'9']);
end;

procedure _ReadIdent(const ASource: string; var APos: Integer;
  var ACol: Integer; out AText: string);
var
  LStart: Integer;
begin
  LStart := APos;
  while (APos <= Length(ASource)) and _IsIdentCont(ASource[APos]) do
  begin
    Inc(APos); Inc(ACol);
  end;
  AText := Copy(ASource, LStart, APos - LStart);
end;

procedure _ReadNumber(const ASource: string; var APos: Integer;
  var ACol: Integer; out AText: string);
var
  LStart: Integer;
begin
  LStart := APos;
  // Tolerates hex prefix ($) and decimal digits, plus optional `.digits`.
  if (APos <= Length(ASource)) and (ASource[APos] = '$') then
  begin
    Inc(APos); Inc(ACol);
    while (APos <= Length(ASource))
      and CharInSet(ASource[APos], ['0'..'9', 'A'..'F', 'a'..'f']) do
    begin
      Inc(APos); Inc(ACol);
    end;
  end
  else
  begin
    while (APos <= Length(ASource))
      and CharInSet(ASource[APos], ['0'..'9', '.']) do
    begin
      Inc(APos); Inc(ACol);
    end;
  end;
  AText := Copy(ASource, LStart, APos - LStart);
end;

// ── Tokenize — single public tokenizer entry ──────────────────────

// Returns True when the position starts a `(* ... *)` comment.
function _IsParenStarStart(const ASource: string; const APos: Integer): Boolean;
begin
  Result := (ASource[APos] = '(') and (APos < Length(ASource))
    and (ASource[APos + 1] = '*');
end;

// Returns True when the position starts a `// ...` line comment.
function _IsLineCommentStart(const ASource: string; const APos: Integer): Boolean;
begin
  Result := (ASource[APos] = '/') and (APos < Length(ASource))
    and (ASource[APos + 1] = '/');
end;

// Dispatches a single token read starting at APos. Updates position/line/col
// and fills AToken (caller already filled AToken.Line / AToken.Column).
procedure _ReadNextToken(const ASource: string; var APos: Integer;
  var ALine, ACol: Integer; var AToken: TPasToken);
var
  LCh: Char;
begin
  LCh := ASource[APos];
  if LCh = '{' then
  begin
    AToken.Kind := tkComment;
    _ReadBraceComment(ASource, APos, ALine, ACol, AToken.Text);
    Exit;
  end;
  if _IsParenStarStart(ASource, APos) then
  begin
    AToken.Kind := tkComment;
    _ReadParenStarComment(ASource, APos, ALine, ACol, AToken.Text);
    Exit;
  end;
  if _IsLineCommentStart(ASource, APos) then
  begin
    AToken.Kind := tkComment;
    _ReadLineComment(ASource, APos, ACol, AToken.Text);
    Exit;
  end;
  if LCh = '''' then
  begin
    AToken.Kind := tkString;
    _ReadString(ASource, APos, ACol, AToken.Text);
    Exit;
  end;
  if _IsIdentStart(LCh) then
  begin
    _ReadIdent(ASource, APos, ACol, AToken.Text);
    AToken.Lower := LowerCase(AToken.Text);
    if _IsPascalKeyword(AToken.Lower) then
      AToken.Kind := tkKeyword
    else
      AToken.Kind := tkIdentifier;
    Exit;
  end;
  if CharInSet(LCh, ['0'..'9', '$']) then
  begin
    AToken.Kind := tkNumber;
    _ReadNumber(ASource, APos, ACol, AToken.Text);
    Exit;
  end;
  AToken.Kind := tkSymbol;
  AToken.Text := LCh;
  Inc(APos); Inc(ACol);
end;

class function TPasParser.Tokenize(const ASource: string): TArray<TPasToken>;
var
  LResult: TList<TPasToken>;
  LPos, LLine, LCol: Integer;
  LToken: TPasToken;
begin
  SetLength(Result, 0);
  LResult := TList<TPasToken>.Create;
  try
    LPos := 1;
    LLine := 1;
    LCol := 1;
    while LPos <= Length(ASource) do
    begin
      _SkipWhitespace(ASource, LPos, LLine, LCol);
      if LPos > Length(ASource) then
        Break;
      LToken := Default(TPasToken);
      LToken.Line := LLine;
      LToken.Column := LCol;
      _ReadNextToken(ASource, LPos, LLine, LCol, LToken);
      LResult.Add(LToken);
    end;
    Result := LResult.ToArray;
  finally
    LResult.Free;
  end;
end;

// ── Helpers over a TArray<TPasToken> ─────────────────────────────────

// Returns the index of the first non-comment, non-whitespace token at or
// after AStart, or -1 when none exists.
function _NextSignificant(const ATokens: TArray<TPasToken>;
  const AStart: Integer): Integer;
var
  LFor: Integer;
begin
  Result := -1;
  for LFor := AStart to High(ATokens) do
    if not (ATokens[LFor].Kind in [tkComment, tkWhitespace]) then
      Exit(LFor);
end;

// Returns the index of the first keyword whose lowered text matches AKey at
// or after AStart, or -1 when none exists.
function _FindKeyword(const ATokens: TArray<TPasToken>;
  const AStart: Integer; const AKey: string): Integer;
var
  LFor: Integer;
begin
  Result := -1;
  for LFor := AStart to High(ATokens) do
    if (ATokens[LFor].Kind = tkKeyword)
      and (ATokens[LFor].Lower = AKey) then
      Exit(LFor);
end;

// Returns the index of the implementation keyword, or -1.
function _ImplementationStart(const ATokens: TArray<TPasToken>): Integer;
begin
  Result := _FindKeyword(ATokens, 0, 'implementation');
end;

// ── FindUnitSymbols (GetSymbolsInUnit) ───────────────────────────────

procedure _AppendSymbol(const AList: TList<TPasSymbolRef>;
  const AName: string; const AKind: TPasSymbolKind; const ALine: Integer);
var
  LItem: TPasSymbolRef;
begin
  LItem.Name := AName;
  LItem.Kind := AKind;
  LItem.Line := ALine;
  AList.Add(LItem);
end;

// Identifies the kind of a `type Name = ...` declaration by inspecting the
// token following `=`. Returns skType when the right-hand side is not one
// of the recognised kinds.
function _ClassifyTypeRhs(const ATokens: TArray<TPasToken>;
  const AEqIndex: Integer): TPasSymbolKind;
var
  LIdx: Integer;
  LTok: TPasToken;
begin
  Result := skType;
  LIdx := _NextSignificant(ATokens, AEqIndex + 1);
  if LIdx < 0 then
    Exit;
  LTok := ATokens[LIdx];
  if LTok.Kind = tkKeyword then
  begin
    if LTok.Lower = 'class' then Exit(skClass);
    if LTok.Lower = 'record' then Exit(skRecord);
    if LTok.Lower = 'interface' then Exit(skInterface);
    if (LTok.Lower = 'object') then Exit(skClass);
  end;
end;

// Collects every `type Name = ...` row inside a type-section run that
// begins right after the `type` keyword at AStart. Stops at the next
// section keyword (var/const/begin/procedure/function/implementation/end).
procedure _CollectTypeSection(const ATokens: TArray<TPasToken>;
  const AStart: Integer; const AList: TList<TPasSymbolRef>);
var
  LFor: Integer;
  LTok: TPasToken;
  LName: string;
  LLine, LEqIdx: Integer;
begin
  LFor := AStart;
  while LFor <= High(ATokens) do
  begin
    LTok := ATokens[LFor];
    if (LTok.Kind = tkKeyword) then
    begin
      if (LTok.Lower = 'var') or (LTok.Lower = 'const')
        or (LTok.Lower = 'procedure') or (LTok.Lower = 'function')
        or (LTok.Lower = 'implementation') or (LTok.Lower = 'begin')
        or (LTok.Lower = 'end') or (LTok.Lower = 'resourcestring')
        or (LTok.Lower = 'threadvar') then
        Break;
    end;
    if LTok.Kind = tkIdentifier then
    begin
      LName := LTok.Text;
      LLine := LTok.Line;
      LEqIdx := _NextSignificant(ATokens, LFor + 1);
      if (LEqIdx >= 0) and (ATokens[LEqIdx].Kind = tkSymbol)
        and (ATokens[LEqIdx].Text = '=') then
      begin
        _AppendSymbol(AList, LName, _ClassifyTypeRhs(ATokens, LEqIdx), LLine);
        LFor := LEqIdx + 1;
        Continue;
      end;
    end;
    Inc(LFor);
  end;
end;

// Collects every `Name : Type;` row inside a var or const section. The
// section ends at the next section keyword. AKind selects skVar or skConst.
procedure _CollectVarConstSection(const ATokens: TArray<TPasToken>;
  const AStart: Integer; const AKind: TPasSymbolKind;
  const AList: TList<TPasSymbolRef>);
var
  LFor: Integer;
  LTok: TPasToken;
  LColon: Integer;
begin
  LFor := AStart;
  while LFor <= High(ATokens) do
  begin
    LTok := ATokens[LFor];
    if LTok.Kind = tkKeyword then
    begin
      if (LTok.Lower = 'var') or (LTok.Lower = 'const')
        or (LTok.Lower = 'type') or (LTok.Lower = 'procedure')
        or (LTok.Lower = 'function') or (LTok.Lower = 'implementation')
        or (LTok.Lower = 'begin') or (LTok.Lower = 'end')
        or (LTok.Lower = 'resourcestring') or (LTok.Lower = 'threadvar') then
        Break;
    end;
    if LTok.Kind = tkIdentifier then
    begin
      LColon := _NextSignificant(ATokens, LFor + 1);
      if (LColon >= 0) and (ATokens[LColon].Kind = tkSymbol)
        and ((ATokens[LColon].Text = ':') or (ATokens[LColon].Text = '=')) then
      begin
        _AppendSymbol(AList, LTok.Text, AKind, LTok.Line);
      end;
    end;
    Inc(LFor);
  end;
end;

// Appends the routine declared at the `procedure`/`function` keyword AKwIndex
// to AList. No-op when the signature identifier is missing.
procedure _AppendRoutineSymbol(const ATokens: TArray<TPasToken>;
  const AKwIndex: Integer; const AList: TList<TPasSymbolRef>);
var
  LSigIdx: Integer;
  LKind: TPasSymbolKind;
begin
  if ATokens[AKwIndex].Lower = 'function' then
    LKind := skFunction
  else
    LKind := skProcedure;
  LSigIdx := _NextSignificant(ATokens, AKwIndex + 1);
  if (LSigIdx >= 0) and (ATokens[LSigIdx].Kind = tkIdentifier) then
    _AppendSymbol(AList, ATokens[LSigIdx].Text, LKind,
      ATokens[LSigIdx].Line);
end;

// Dispatches the keyword at AKwIndex to the matching collector. No-op for
// keywords that do not start a tracked section.
procedure _DispatchInterfaceKeyword(const ATokens: TArray<TPasToken>;
  const AKwIndex: Integer; const AList: TList<TPasSymbolRef>);
var
  LLower: string;
begin
  LLower := ATokens[AKwIndex].Lower;
  if LLower = 'type' then
    _CollectTypeSection(ATokens, AKwIndex + 1, AList)
  else if (LLower = 'var') or (LLower = 'threadvar') then
    _CollectVarConstSection(ATokens, AKwIndex + 1, skVar, AList)
  else if LLower = 'const' then
    _CollectVarConstSection(ATokens, AKwIndex + 1, skConst, AList)
  else if (LLower = 'function') or (LLower = 'procedure') then
    _AppendRoutineSymbol(ATokens, AKwIndex, AList);
end;

class function TPasParser.FindUnitSymbols(
  const ATokens: TArray<TPasToken>): TArray<TPasSymbolRef>;
var
  LList: TList<TPasSymbolRef>;
  LFor, LImplStart: Integer;
begin
  SetLength(Result, 0);
  LList := TList<TPasSymbolRef>.Create;
  try
    LImplStart := _ImplementationStart(ATokens);
    LFor := 0;
    while LFor <= High(ATokens) do
    begin
      // Stop at implementation — interface section only (BR-4).
      if (LImplStart >= 0) and (LFor >= LImplStart) then
        Break;
      if ATokens[LFor].Kind = tkKeyword then
        _DispatchInterfaceKeyword(ATokens, LFor, LList);
      Inc(LFor);
    end;
    Result := LList.ToArray;
  finally
    LList.Free;
  end;
end;

// ── FindClassMembers (GetClassMembers) ───────────────────────────────

// Locates the index of the `class` keyword that opens AClassName's
// declaration: `TFoo = class ...`. Returns -1 when not found.
function _FindClassDeclStart(const ATokens: TArray<TPasToken>;
  const AClassName: string): Integer;
var
  LFor, LEq, LKw: Integer;
  LLower: string;
begin
  Result := -1;
  LLower := LowerCase(AClassName);
  for LFor := 0 to High(ATokens) do
  begin
    if (ATokens[LFor].Kind = tkIdentifier)
      and (ATokens[LFor].Lower = LLower) then
    begin
      LEq := _NextSignificant(ATokens, LFor + 1);
      if (LEq < 0) or (ATokens[LEq].Kind <> tkSymbol)
        or (ATokens[LEq].Text <> '=') then
        Continue;
      LKw := _NextSignificant(ATokens, LEq + 1);
      if (LKw >= 0) and (ATokens[LKw].Kind = tkKeyword)
        and (ATokens[LKw].Lower = 'class') then
        Exit(LKw);
    end;
  end;
end;

// Locates the index of the closing `end` for the class block that begins
// with the `class` keyword at AClassKw. Returns -1 when not balanced.
// Tracks nested record/class introducers so a nested type does not steal
// the closing `end`.
// Skips a `(TAncestor, ...)` ancestor list starting at AFromIdx. Returns the
// index just past the closing `)` when present, otherwise AFromIdx unchanged.
function _SkipAncestorList(const ATokens: TArray<TPasToken>;
  const AFromIdx: Integer): Integer;
var
  LParen: Integer;
begin
  Result := AFromIdx;
  LParen := _NextSignificant(ATokens, AFromIdx);
  if (LParen < 0) or (ATokens[LParen].Kind <> tkSymbol)
    or (ATokens[LParen].Text <> '(') then
    Exit;
  while LParen <= High(ATokens) do
  begin
    if (ATokens[LParen].Kind = tkSymbol)
      and (ATokens[LParen].Text = ')') then
      Exit(LParen + 1);
    Inc(LParen);
  end;
end;

// Returns True when the keyword opens a nested type block that bumps the
// class-end depth counter.
function _IsNestedTypeOpener(const ALower: string): Boolean;
begin
  Result := (ALower = 'class') or (ALower = 'record') or (ALower = 'object');
end;

function _FindClassDeclEnd(const ATokens: TArray<TPasToken>;
  const AClassKw: Integer): Integer;
var
  LFor, LDepth: Integer;
  LTok: TPasToken;
begin
  Result := -1;
  LDepth := 1;
  LFor := _SkipAncestorList(ATokens, AClassKw + 1);
  while LFor <= High(ATokens) do
  begin
    LTok := ATokens[LFor];
    if LTok.Kind = tkKeyword then
    begin
      if _IsNestedTypeOpener(LTok.Lower) then
        Inc(LDepth)
      else if LTok.Lower = 'end' then
      begin
        Dec(LDepth);
        if LDepth = 0 then
          Exit(LFor);
      end;
    end;
    Inc(LFor);
  end;
end;

// Returns True when the keyword token is a visibility marker. The caller
// updates the visibility accumulator on hit.
function _IsVisibilityKeyword(const ALower: string;
  out AVis: TPasVisibility): Boolean;
begin
  Result := True;
  if ALower = 'private' then AVis := vPrivate
  else if ALower = 'protected' then AVis := vProtected
  else if ALower = 'public' then AVis := vPublic
  else if ALower = 'published' then AVis := vPublished
  else if ALower = 'automated' then AVis := vAutomated
  else
    Result := False;
end;

// Appends one named member starting at AKwIndex (a keyword whose next
// significant token is the member identifier). No-op when missing.
procedure _AppendNamedMember(const ATokens: TArray<TPasToken>;
  const AKwIndex: Integer; const AKind: TPasMemberKind;
  const AVisibility: TPasVisibility; const AList: TList<TPasMemberRef>);
var
  LSigIdx: Integer;
  LItem: TPasMemberRef;
begin
  LSigIdx := _NextSignificant(ATokens, AKwIndex + 1);
  if (LSigIdx < 0) or (ATokens[LSigIdx].Kind <> tkIdentifier) then
    Exit;
  LItem.Name := ATokens[LSigIdx].Text;
  LItem.Kind := AKind;
  LItem.Visibility := AVisibility;
  LItem.Line := ATokens[LSigIdx].Line;
  AList.Add(LItem);
end;

// Maps a class-body keyword to its member kind. Returns False when the
// keyword does not introduce a named member.
function _ClassifyMemberKeyword(const ALower: string;
  out AKind: TPasMemberKind): Boolean;
begin
  Result := True;
  if (ALower = 'procedure') or (ALower = 'function')
    or (ALower = 'constructor') or (ALower = 'destructor') then
    AKind := mkMethod
  else if ALower = 'property' then
    AKind := mkProperty
  else if ALower = 'const' then
    AKind := mkConst
  else if ALower = 'type' then
    AKind := mkType
  else
    Result := False;
end;

// Appends a field declaration when the identifier at AIdentIdx is followed by
// `:` or `,` (field-list head). No-op otherwise.
procedure _TryAppendField(const ATokens: TArray<TPasToken>;
  const AIdentIdx: Integer; const AVisibility: TPasVisibility;
  const AList: TList<TPasMemberRef>);
var
  LSigIdx: Integer;
  LItem: TPasMemberRef;
begin
  LSigIdx := _NextSignificant(ATokens, AIdentIdx + 1);
  if (LSigIdx < 0) or (ATokens[LSigIdx].Kind <> tkSymbol) then
    Exit;
  if (ATokens[LSigIdx].Text <> ':') and (ATokens[LSigIdx].Text <> ',') then
    Exit;
  LItem.Name := ATokens[AIdentIdx].Text;
  LItem.Kind := mkField;
  LItem.Visibility := AVisibility;
  LItem.Line := ATokens[AIdentIdx].Line;
  AList.Add(LItem);
end;

// Walks the class body from AStart to AStop (inclusive of the body, EXCLUSIVE
// of the closing `end`) and accumulates members.
procedure _CollectClassMembers(const ATokens: TArray<TPasToken>;
  const AStart, AStop: Integer; const AList: TList<TPasMemberRef>);
var
  LFor: Integer;
  LTok: TPasToken;
  LVis: TPasVisibility;
  LMemberKind: TPasMemberKind;
begin
  LVis := vPublished;
  LFor := AStart;
  while LFor < AStop do
  begin
    LTok := ATokens[LFor];
    if LTok.Kind = tkKeyword then
    begin
      if _IsVisibilityKeyword(LTok.Lower, LVis) then
      begin
        Inc(LFor);
        Continue;
      end;
      if _ClassifyMemberKeyword(LTok.Lower, LMemberKind) then
      begin
        _AppendNamedMember(ATokens, LFor, LMemberKind, LVis, AList);
        Inc(LFor);
        Continue;
      end;
    end
    else if LTok.Kind = tkIdentifier then
      _TryAppendField(ATokens, LFor, LVis, AList);
    Inc(LFor);
  end;
end;

class function TPasParser.FindClassMembers(const ATokens: TArray<TPasToken>;
  const AClassName: string): TArray<TPasMemberRef>;
var
  LList: TList<TPasMemberRef>;
  LStart, LEnd: Integer;
begin
  SetLength(Result, 0);
  LStart := _FindClassDeclStart(ATokens, AClassName);
  if LStart < 0 then
    Exit;
  LEnd := _FindClassDeclEnd(ATokens, LStart);
  if LEnd < 0 then
    Exit;
  LList := TList<TPasMemberRef>.Create;
  try
    // Skip the `class` keyword itself.
    _CollectClassMembers(ATokens, LStart + 1, LEnd, LList);
    Result := LList.ToArray;
  finally
    LList.Free;
  end;
end;

// ── FindMethodBody (GetMethodBody) ───────────────────────────────────

// Returns True when the identifier (case-insensitive) at AIdx is the target
// method name. Accepts a bare name (`Foo`) or class-qualified (`TBar.Foo`).
// On match, AClassName receives the qualifier (empty when bare).
function _MatchMethodNameAt(const ATokens: TArray<TPasToken>;
  const AIdx: Integer; const ATarget: string;
  out AStartIdx: Integer): Boolean;
var
  LLower, LBare: string;
  LDotIdx: Integer;
begin
  Result := False;
  AStartIdx := AIdx;
  LLower := LowerCase(ATarget);
  LDotIdx := Pos('.', LLower);
  if (ATokens[AIdx].Kind <> tkIdentifier) then
    Exit;
  if LDotIdx > 0 then
  begin
    // Qualified target — match `Class.Name` exactly.
    if (AIdx + 2 > High(ATokens)) then
      Exit;
    LBare := LowerCase(ATokens[AIdx].Text) + '.'
      + LowerCase(ATokens[AIdx + 2].Text);
    Result := (ATokens[AIdx + 1].Kind = tkSymbol)
      and (ATokens[AIdx + 1].Text = '.')
      and (LBare = LLower);
    if Result then
      AStartIdx := AIdx + 2;
    Exit;
  end;
  // Bare target — accept either `Foo` directly or the second half of
  // `TBar.Foo`. When the token at AIdx is followed by `.<target>` we
  // advance AStartIdx so the begin-scan starts past the qualifier.
  if (ATokens[AIdx].Lower = LLower) then
    Exit(True);
  if (AIdx + 2 <= High(ATokens))
    and (ATokens[AIdx].Kind = tkIdentifier)
    and (ATokens[AIdx + 1].Kind = tkSymbol)
    and (ATokens[AIdx + 1].Text = '.')
    and (ATokens[AIdx + 2].Kind = tkIdentifier)
    and (ATokens[AIdx + 2].Lower = LLower) then
  begin
    AStartIdx := AIdx + 2;
    Exit(True);
  end;
end;

// Finds the index of `begin` that opens the body of the method whose
// signature starts at AIdx (immediately after `procedure`/`function`).
// Returns -1 when the body cannot be located.
function _FindMethodBeginAt(const ATokens: TArray<TPasToken>;
  const AIdx: Integer): Integer;
var
  LFor: Integer;
  LTok: TPasToken;
begin
  Result := -1;
  LFor := AIdx;
  while LFor <= High(ATokens) do
  begin
    LTok := ATokens[LFor];
    if LTok.Kind = tkKeyword then
    begin
      if LTok.Lower = 'begin' then
        Exit(LFor);
      // A new top-level declaration or `end.` — abort.
      if (LTok.Lower = 'procedure') or (LTok.Lower = 'function')
        or (LTok.Lower = 'constructor') or (LTok.Lower = 'destructor')
        or (LTok.Lower = 'end') then
      begin
        if LTok.Lower = 'end' then
          Exit;
        Break;
      end;
    end;
    Inc(LFor);
  end;
end;

// Finds the matching `end` for the `begin` at ABegin. Tracks nested
// begin/case/asm/try introducers. Returns -1 when unbalanced.
// Returns True when the keyword opens a nested block that bumps the
// matching-end depth counter.
function _IsBlockOpenerKeyword(const ALower: string): Boolean;
begin
  Result := (ALower = 'begin') or (ALower = 'case') or (ALower = 'try')
    or (ALower = 'asm') or (ALower = 'record');
end;

function _FindMatchingEnd(const ATokens: TArray<TPasToken>;
  const ABegin: Integer): Integer;
var
  LFor, LDepth: Integer;
  LTok: TPasToken;
begin
  Result := -1;
  LDepth := 1;
  LFor := ABegin + 1;
  while LFor <= High(ATokens) do
  begin
    LTok := ATokens[LFor];
    if LTok.Kind = tkKeyword then
    begin
      if _IsBlockOpenerKeyword(LTok.Lower) then
        Inc(LDepth)
      else if LTok.Lower = 'end' then
      begin
        Dec(LDepth);
        if LDepth = 0 then
          Exit(LFor);
      end;
    end;
    Inc(LFor);
  end;
end;

// Converts a 1-based (ALine, ACol) into a 1-based absolute offset inside
// ASource. Returns 0 when the address is out of range.
function _LocateOffset(const ASource: string;
  const ALine, ACol: Integer): Integer; forward;

// Returns True when the keyword introduces an implementation-section routine.
function _IsRoutineIntroducer(const ALower: string): Boolean;
begin
  Result := (ALower = 'procedure') or (ALower = 'function')
    or (ALower = 'constructor') or (ALower = 'destructor');
end;

// Extracts the body source for the routine matched at LSigIdx. Returns the
// source slice or '' when the body cannot be located.
function _ExtractMethodBodySource(const ASource: string;
  const ATokens: TArray<TPasToken>; const ASigIdx: Integer): string;
var
  LBeginIdx, LEndIdx, LStartOffset, LStopOffset: Integer;
begin
  Result := '';
  LBeginIdx := _FindMethodBeginAt(ATokens, ASigIdx);
  if LBeginIdx < 0 then
    Exit;
  LEndIdx := _FindMatchingEnd(ATokens, LBeginIdx);
  if LEndIdx < 0 then
    Exit;
  LStartOffset := _LocateOffset(ASource, ATokens[LBeginIdx].Line,
    ATokens[LBeginIdx].Column);
  LStopOffset := _LocateOffset(ASource, ATokens[LEndIdx].Line,
    ATokens[LEndIdx].Column + Length(ATokens[LEndIdx].Text));
  if (LStartOffset > 0) and (LStopOffset >= LStartOffset) then
    Result := Copy(ASource, LStartOffset, LStopOffset - LStartOffset);
end;

class function TPasParser.FindMethodBody(const ASource: string;
  const ATokens: TArray<TPasToken>;
  const AMethodName: string): string;
var
  LImplStart, LFor, LSigIdx: Integer;
  LTok: TPasToken;
begin
  Result := '';
  LImplStart := _ImplementationStart(ATokens);
  if LImplStart < 0 then
    Exit;
  LFor := LImplStart + 1;
  while LFor <= High(ATokens) do
  begin
    LTok := ATokens[LFor];
    if (LTok.Kind = tkKeyword) and _IsRoutineIntroducer(LTok.Lower) then
    begin
      LSigIdx := _NextSignificant(ATokens, LFor + 1);
      if LSigIdx < 0 then
        Break;
      if _MatchMethodNameAt(ATokens, LSigIdx, AMethodName, LSigIdx) then
      begin
        Result := _ExtractMethodBodySource(ASource, ATokens, LSigIdx);
        Exit;
      end;
    end;
    Inc(LFor);
  end;
end;

// Advances APos past a CR, CRLF or LF newline sequence starting at APos.
// Returns True when a newline was consumed (and ALine bumped, ACol reset).
function _AdvanceNewline(const ASource: string; var APos: Integer;
  var ALine, ACol: Integer): Boolean;
begin
  Result := False;
  if APos > Length(ASource) then
    Exit;
  if ASource[APos] = #13 then
  begin
    Inc(APos);
    if (APos <= Length(ASource)) and (ASource[APos] = #10) then
      Inc(APos);
    Inc(ALine);
    ACol := 1;
    Exit(True);
  end;
  if ASource[APos] = #10 then
  begin
    Inc(APos);
    Inc(ALine);
    ACol := 1;
    Exit(True);
  end;
end;

function _LocateOffset(const ASource: string;
  const ALine, ACol: Integer): Integer;
var
  LPos, LLine, LCol: Integer;
begin
  Result := 0;
  LPos := 1;
  LLine := 1;
  LCol := 1;
  while LPos <= Length(ASource) do
  begin
    if (LLine = ALine) and (LCol = ACol) then
      Exit(LPos);
    if not _AdvanceNewline(ASource, LPos, LLine, LCol) then
    begin
      Inc(LPos);
      Inc(LCol);
    end;
  end;
  if (LLine = ALine) and (LCol = ACol) then
    Exit(LPos);
end;

// ── FindParentClassName (GetInheritanceChain helper) ─────────────────

class function TPasParser.FindParentClassName(const ATokens: TArray<TPasToken>;
  const AClassName: string): string;
var
  LClassKw, LIdx: Integer;
begin
  Result := '';
  LClassKw := _FindClassDeclStart(ATokens, AClassName);
  if LClassKw < 0 then
    Exit;
  LIdx := _NextSignificant(ATokens, LClassKw + 1);
  if (LIdx < 0) or (ATokens[LIdx].Kind <> tkSymbol)
    or (ATokens[LIdx].Text <> '(') then
    Exit;
  LIdx := _NextSignificant(ATokens, LIdx + 1);
  if (LIdx >= 0) and (ATokens[LIdx].Kind = tkIdentifier) then
    Result := ATokens[LIdx].Text;
end;

// ── EnumerateIdentifierUsages (FindSymbolUsages) ─────────────────────

// Returns the 1-based start offset of ALine inside ASource (ALine is 1-based).
// Skips a CR, CRLF or LF newline sequence starting at APos. Returns True
// when a newline was consumed (and ALine bumped).
function _SkipNewline(const ASource: string; var APos: Integer;
  var ACurLine: Integer): Boolean;
begin
  Result := False;
  if APos > Length(ASource) then
    Exit;
  if ASource[APos] = #13 then
  begin
    Inc(APos);
    if (APos <= Length(ASource)) and (ASource[APos] = #10) then
      Inc(APos);
    Inc(ACurLine);
    Exit(True);
  end;
  if ASource[APos] = #10 then
  begin
    Inc(APos);
    Inc(ACurLine);
    Exit(True);
  end;
end;

function _LineStartOffset(const ASource: string; const ALine: Integer): Integer;
var
  LPos, LCurLine: Integer;
begin
  Result := 1;
  if ALine <= 1 then
    Exit;
  LPos := 1;
  LCurLine := 1;
  while LPos <= Length(ASource) do
  begin
    if _SkipNewline(ASource, LPos, LCurLine) then
    begin
      if LCurLine = ALine then
        Exit(LPos);
    end
    else
      Inc(LPos);
  end;
  Result := 0;
end;

// Returns the full source line ALine (1-based). Empty on out-of-range.
function _ReadLine(const ASource: string; const ALine: Integer): string;
var
  LStart, LPos: Integer;
begin
  Result := '';
  LStart := _LineStartOffset(ASource, ALine);
  if LStart <= 0 then
    Exit;
  LPos := LStart;
  while LPos <= Length(ASource) do
  begin
    if (ASource[LPos] = #13) or (ASource[LPos] = #10) then
      Break;
    Inc(LPos);
  end;
  Result := Copy(ASource, LStart, LPos - LStart);
end;

class function TPasParser.EnumerateIdentifierUsages(const ASource: string;
  const ATokens: TArray<TPasToken>;
  const ASymbol: string): TArray<TPasIdentifierUsage>;
var
  LList: TList<TPasIdentifierUsage>;
  LLower: string;
  LFor: Integer;
  LItem: TPasIdentifierUsage;
begin
  SetLength(Result, 0);
  if Trim(ASymbol) = '' then
    Exit;
  LLower := LowerCase(ASymbol);
  LList := TList<TPasIdentifierUsage>.Create;
  try
    for LFor := 0 to High(ATokens) do
    begin
      // ADR-143: only identifier tokens match. Comments + strings are NEVER
      // identifier tokens, so they cannot produce false positives.
      if (ATokens[LFor].Kind = tkIdentifier)
        and (ATokens[LFor].Lower = LLower) then
      begin
        LItem.Line := ATokens[LFor].Line;
        LItem.Column := ATokens[LFor].Column;
        LItem.Context := _ReadLine(ASource, LItem.Line);
        LList.Add(LItem);
      end;
    end;
    Result := LList.ToArray;
  finally
    LList.Free;
  end;
end;

// ── Enum → string ────────────────────────────────────────────────────

class function TPasParser.SymbolKindToString(const AKind: TPasSymbolKind): string;
begin
  case AKind of
    skClass:     Result := 'class';
    skRecord:    Result := 'record';
    skInterface: Result := 'interface';
    skFunction:  Result := 'function';
    skProcedure: Result := 'procedure';
    skVar:       Result := 'var';
    skConst:     Result := 'const';
    skType:      Result := 'type';
  else
    Result := 'unknown';
  end;
end;

class function TPasParser.MemberKindToString(const AKind: TPasMemberKind): string;
begin
  case AKind of
    mkField:    Result := 'field';
    mkMethod:   Result := 'method';
    mkProperty: Result := 'property';
    mkConst:    Result := 'const';
    mkType:     Result := 'type';
  else
    Result := 'unknown';
  end;
end;

class function TPasParser.VisibilityToString(const AVisibility: TPasVisibility): string;
begin
  case AVisibility of
    vPrivate:   Result := 'private';
    vProtected: Result := 'protected';
    vPublic:    Result := 'public';
    vPublished: Result := 'published';
    vAutomated: Result := 'automated';
  else
    Result := 'published';
  end;
end;

end.
