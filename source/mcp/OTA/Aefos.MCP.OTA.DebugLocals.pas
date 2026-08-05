unit Aefos.MCP.OTA.DebugLocals;

{
  Pure locals-from-source extraction for the agent debugger (future plan:
  .local-readonly\ota-agent-debug-plan.md - the Locals GAP workaround).

  The OTA exposes NO locals-view API, but an agent does not need one: given
  the unit SOURCE and the stopped LINE, this seam finds the enclosing routine
  and extracts the inspectable names - parameters (including implicit Self for
  methods) and the routine's var/const declarations. The debug tool then
  drives IOTAThread.Evaluate over each name, which is exactly what a human
  reads off the Locals window.

  Pure RTL - no ToolsAPI, no VCL, no I/O: source text in, names out - so the
  whole extraction is headless-tested. Heuristic by design (a full Pascal
  parser is not the bar): it recognises the dominant real-world shapes -
  procedure/function/constructor/destructor headers with (), multi-line
  headers, class methods (ClassName.Method), overloads, nested var blocks,
  inline comments - and degrades to fewer names, never to wrong offsets
  (names are only ever taken from parameter lists and var/const sections).
}

interface

type
  TDebugLocalKind = (dlSelf, dlParam, dlVar);

  TDebugLocal = record
    Name: string;
    Kind: TDebugLocalKind;
  end;

// Extracts the inspectable names of the routine that CONTAINS ALine (1-based)
// in ASource. Empty when the line is not inside a recognisable routine body.
// Order: Self (when a method), parameters in declaration order, then var/const
// names in declaration order. Duplicates are collapsed (first kind wins).
function ExtractLocalsAtLine(const ASource: string;
  const ALine: Integer): TArray<TDebugLocal>;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.Character;

const
  CHeaderKeywords: array[0..4] of string =
    ('procedure', 'function', 'constructor', 'destructor', 'operator');

function _IsIdentStart(const C: Char): Boolean;
begin
  Result := C.IsLetter or (C = '_');
end;

function _IsIdentChar(const C: Char): Boolean;
begin
  Result := C.IsLetterOrDigit or (C = '_');
end;

// Strips // line comments and { } / (* *) block comments and single-quoted
// strings, preserving LINE STRUCTURE (newlines kept) so line indices hold.
function _StripNoise(const ASource: string): string;
var
  LSB: TStringBuilder;
  I, LLen: Integer;
begin
  LSB := TStringBuilder.Create(Length(ASource));
  try
    I := 1;
    LLen := Length(ASource);
    while I <= LLen do
    begin
      // '...' string literal
      if ASource[I] = '''' then
      begin
        Inc(I);
        while (I <= LLen) and (ASource[I] <> '''') do
          Inc(I);
        Inc(I);
        LSB.Append(' ');
        Continue;
      end;
      // // line comment
      if (ASource[I] = '/') and (I < LLen) and (ASource[I + 1] = '/') then
      begin
        while (I <= LLen) and (ASource[I] <> #10) do
          Inc(I);
        Continue;
      end;
      // { } block comment (may span lines - keep the newlines)
      if ASource[I] = '{' then
      begin
        while (I <= LLen) and (ASource[I] <> '}') do
        begin
          if ASource[I] = #10 then
            LSB.Append(#10);
          Inc(I);
        end;
        Inc(I);
        Continue;
      end;
      // (* *) block comment
      if (ASource[I] = '(') and (I < LLen) and (ASource[I + 1] = '*') then
      begin
        Inc(I, 2);
        while (I < LLen) and
          not ((ASource[I] = '*') and (ASource[I + 1] = ')')) do
        begin
          if ASource[I] = #10 then
            LSB.Append(#10);
          Inc(I);
        end;
        Inc(I, 2);
        Continue;
      end;
      LSB.Append(ASource[I]);
      Inc(I);
    end;
    Result := LSB.ToString;
  finally
    LSB.Free;
  end;
end;

// True when the trimmed line STARTS a routine header, out its keyword length.
function _IsHeaderLine(const ALine: string; out AIsMethod: Boolean): Boolean;
var
  LTrim: string;
  LKw: string;
begin
  Result := False;
  AIsMethod := False;
  LTrim := ALine.TrimLeft.ToLower;
  // 'class procedure' / 'class function' methods
  if LTrim.StartsWith('class ') then
  begin
    LTrim := Copy(LTrim, 7, MaxInt).TrimLeft;
    AIsMethod := True;
  end;
  for LKw in CHeaderKeywords do
    if LTrim.StartsWith(LKw) and
      ((Length(LTrim) = Length(LKw)) or
       not _IsIdentChar(LTrim[Length(LKw) + 1])) then
      Exit(True);
end;

// Splits a parameter-list body 'const A, B: T1; var C: T2 = def' into names.
procedure _ParamNames(const AParams: string; var AOut: TArray<TDebugLocal>);
var
  LGroups: TArray<string>;
  LGroup, LNamePart, LName: string;
  LColon: Integer;
  LLocal: TDebugLocal;
begin
  LGroups := AParams.Split([';']);
  for LGroup in LGroups do
  begin
    LNamePart := LGroup;
    LColon := Pos(':', LNamePart);
    if LColon > 0 then
      LNamePart := Copy(LNamePart, 1, LColon - 1);
    // drop the const/var/out/[ref] modifiers
    LNamePart := LNamePart.Trim;
    if LNamePart.ToLower.StartsWith('const ') then
      LNamePart := Copy(LNamePart, 7, MaxInt)
    else if LNamePart.ToLower.StartsWith('var ') then
      LNamePart := Copy(LNamePart, 5, MaxInt)
    else if LNamePart.ToLower.StartsWith('out ') then
      LNamePart := Copy(LNamePart, 5, MaxInt);
    for LName in LNamePart.Split([',']) do
      if (LName.Trim <> '') and _IsIdentStart(LName.Trim[1]) then
      begin
        LLocal.Name := LName.Trim;
        LLocal.Kind := dlParam;
        AOut := AOut + [LLocal];
      end;
  end;
end;

function ExtractLocalsAtLine(const ASource: string;
  const ALine: Integer): TArray<TDebugLocal>;
var
  LOut: TArray<TDebugLocal>;
  LSeen: string;
  LLines: TArray<string>;
  LClean: string;
  I, LHeaderIdx, LDepth: Integer;
  LIsMethod, LDummy, LInVars: Boolean;
  LHeaderText, LTrim, LLower, LNamePart, LName: string;
  LParOpen, LParClose, LColon, LEq: Integer;
  LLocal: TDebugLocal;
  LParams: TArray<TDebugLocal>;

  procedure _Emit(const AName: string; const AKind: TDebugLocalKind);
  begin
    // collapse duplicates, case-insensitive (Pascal identifiers)
    if Pos('|' + AName.ToLower + '|', LSeen) > 0 then
      Exit;
    LSeen := LSeen + '|' + AName.ToLower + '|';
    LLocal.Name := AName;
    LLocal.Kind := AKind;
    LOut := LOut + [LLocal];
  end;

begin
  Result := nil;
  LOut := nil;
  LSeen := '';
  if (ALine < 1) or (ASource = '') then
    Exit;
  LClean := _StripNoise(ASource);
  LLines := LClean.Split([#10]);
  for I := 0 to High(LLines) do
    LLines[I] := LLines[I].TrimRight([#13]);
  if ALine > Length(LLines) then
    Exit;

  // Walk BACKWARD from the stopped line to the nearest routine header. For a
  // nested routine that is the INNER header - which is exactly whose locals
  // are in scope at the stop.
  LHeaderIdx := -1;
  LIsMethod := False;
  for I := ALine - 1 downto 0 do
    if _IsHeaderLine(LLines[I], LIsMethod) then
    begin
      LHeaderIdx := I;
      Break;
    end;
  if LHeaderIdx < 0 then
    Exit;

  // Gather the FULL header (may span lines until ';' outside parens).
  LHeaderText := '';
  LDepth := 0;
  for I := LHeaderIdx to High(LLines) do
  begin
    LHeaderText := LHeaderText + ' ' + LLines[I];
    LDepth := LDepth + LLines[I].CountChar('(') - LLines[I].CountChar(')');
    if (LDepth <= 0) and LLines[I].Contains(';') then
      Break;
  end;

  // Method (ClassName.Name before the paren) => implicit Self.
  LParOpen := Pos('(', LHeaderText);
  if LParOpen > 0 then
    LIsMethod := LIsMethod or (Pos('.', Copy(LHeaderText, 1, LParOpen)) > 0)
  else
    LIsMethod := LIsMethod or (Pos('.', LHeaderText) > 0);
  if LIsMethod then
    _Emit('Self', dlSelf);

  // Parameters between the header's balanced ( ).
  if LParOpen > 0 then
  begin
    LParClose := LParOpen + 1;
    LDepth := 1;
    while (LParClose <= Length(LHeaderText)) and (LDepth > 0) do
    begin
      if LHeaderText[LParClose] = '(' then
        Inc(LDepth)
      else if LHeaderText[LParClose] = ')' then
        Dec(LDepth);
      Inc(LParClose);
    end;
    LParams := nil;
    _ParamNames(Copy(LHeaderText, LParOpen + 1, LParClose - LParOpen - 2),
      LParams);
    for I := 0 to High(LParams) do
      _Emit(LParams[I].Name, dlParam);
  end;

  // Functions expose the implicit Result.
  if LHeaderText.TrimLeft.ToLower.StartsWith('function') or
    LHeaderText.TrimLeft.ToLower.StartsWith('class function') then
    _Emit('Result', dlVar);

  // var/const sections between the header and the body's begin. A nested
  // header or 'type'/'label' ends the scan (nested locals are the inner
  // routine's business - see the backward walk above).
  LInVars := False;
  for I := LHeaderIdx + 1 to High(LLines) do
  begin
    LTrim := LLines[I].Trim;
    LLower := LTrim.ToLower;
    if LLower = '' then
      Continue;
    if (LLower = 'begin') or LLower.StartsWith('begin ') or
      _IsHeaderLine(LLines[I], LDummy) or (LLower = 'type') or
      (LLower = 'label') or LLower.StartsWith('type ') then
      Break;
    if (LLower = 'var') or (LLower = 'const') then
    begin
      LInVars := True;
      Continue;
    end;
    if LLower.StartsWith('var ') or LLower.StartsWith('const ') then
    begin
      LInVars := True;
      LTrim := Copy(LTrim, Pos(' ', LTrim) + 1, MaxInt).Trim;
      LLower := LTrim.ToLower;
    end;
    if not LInVars then
      Continue;
    // 'A, B: Integer;' -> names before ':'; 'C = 5;' -> name before '='.
    LColon := Pos(':', LTrim);
    LEq := Pos('=', LTrim);
    if (LColon = 0) and (LEq = 0) then
      Continue;
    if (LColon > 0) and ((LEq = 0) or (LColon < LEq)) then
      LNamePart := Copy(LTrim, 1, LColon - 1)
    else
      LNamePart := Copy(LTrim, 1, LEq - 1);
    for LName in LNamePart.Split([',']) do
      if (LName.Trim <> '') and _IsIdentStart(LName.Trim[1]) then
        _Emit(LName.Trim, dlVar);
  end;

  Result := LOut;
end;

end.
