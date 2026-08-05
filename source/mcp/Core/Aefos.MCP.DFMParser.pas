unit Aefos.MCP.DFMParser;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

(*
  Text-DFM parser helpers for the Forms & DFM MCP tools (ESP-002, Epic 7/7
  Demand 6/8, ADR-139 / ADR-140).

  Scope: minimal, line-oriented parse over text-format DFM. Handles object /
  inherited / inline headers, end markers, scalar property assignments
  (`Name = value`), and nested object blocks. NOT a general DFM grammar —
  set literals, multi-line strings, item lists, and binary data blobs are
  returned verbatim as the property's value (single-line capture). Anything
  the parser cannot understand is surfaced as `dfm-parse-error` at the
  tool layer.

  Boundary (ADR-115 / BR-1): zero `uses ToolsAPI`. This unit is RTL-only
  and is safe to link into the test EXE.

  Cognitive complexity per ESP C-5: every public function ≤ 15. Helpers
  marked with `_` keep the public surface narrow.
*)

interface

uses
  SysUtils;

type
  TDFMPropertyPair = record
    Name: string;
    Value: string;
  end;

  TDFMComponentRef = record
    Name: string;
    TypeName: string;
    Owner: string;  // empty for immediate children of the form
  end;

type
  // Minimal line-oriented text-DFM parser as a sealed static namespace (never
  // instantiated). RTL-only — safe to link into the test EXE.
  TDFMParser = class sealed
  public
    // Returns True when ABytes is a binary-format DFM (first byte $FF — magic
    // header) per ADR-140. Empty input is treated as not-binary.
    class function IsBinaryDFM(const ABytes: TBytes): Boolean; static;

    // Returns the [Name, TypeName] of the form header (`object Form1: TForm1`
    // or the inherited/inline equivalents). Returns empty strings when the
    // header cannot be located.
    class function ParseFormHeader(const AContent: string;
      out AName, ATypeName: string): Boolean; static;

    // Returns the immediate-child component blocks of the form (depth 2 from
    // the top of the file = depth 1 from the form body). Nested grandchildren
    // are not flattened.
    class function EnumerateImmediateChildren(
      const AContent: string): TArray<TDFMComponentRef>; static;

    // Every component on the form, at EVERY depth, in document order, each
    // carrying the name of the component that contains it (the form root's own
    // name for a direct child).
    //
    // EnumerateImmediateChildren stops at depth 2, which is right for the jobs
    // that mean "the form's own fields" -- and catastrophic for the job that
    // means "what is on this form". A form whose controls all live inside a
    // TPageControl enumerated as exactly ONE component, so an agent reading it
    // saw a .pas full of fields against a form with a single control and
    // concluded the two were desynced (field report, 2026-08-04). They were not.
    // The reader was looking one level deep while the write guard walked the
    // whole tree -- the two disagreeing about the same form is what made the
    // conclusion so convincing.
    class function EnumerateAllComponents(
      const AContent: string): TArray<TDFMComponentRef>; static;

    // Returns the property assignments at the form's top scope (depth 1).
    // Nested objects' properties are excluded.
    class function ExtractTopLevelProperties(
      const AContent: string): TArray<TDFMPropertyPair>; static;

    // Returns the property assignments scoped to AComponentName (any depth ≥ 2).
    // Empty array when the component is not found.
    class function ExtractComponentProperties(const AContent,
      AComponentName: string): TArray<TDFMPropertyPair>; static;

    // Replaces (or appends) APropName at the form's top scope. Returns the
    // rewritten content; AChanged is False when the existing value already
    // matched APropValue (BR-5 idempotency).
    class function ReplaceFormProperty(const AContent, APropName, APropValue: string;
      out AChanged: Boolean): string; static;

    // Replaces (or appends) APropName scoped to AComponentName. AChanged is
    // False on identical value (BR-5). AFound is False when the component is
    // not present — caller surfaces `component-not-found` to the LLM.
    class function ReplaceComponentProperty(const AContent, AComponentName, APropName,
      APropValue: string; out AChanged, AFound: Boolean): string; static;
  end;

implementation

uses
  Classes,
  Generics.Collections;

const
  CFormHeaderPrefixObject    = 'object ';
  CFormHeaderPrefixInherited = 'inherited ';
  CFormHeaderPrefixInline    = 'inline ';
  CEndMarker                 = 'end';

// Returns True when ALine starts (case-insensitive) with one of the three
// DFM block-opener prefixes. Strips out the prefix into APayload so the
// caller can parse `Name: TypeName` from the right-hand side.
function _IsBlockOpener(const ALine: string; out APayload: string): Boolean;
begin
  Result := False;
  APayload := '';
  if SameText(Copy(ALine, 1, Length(CFormHeaderPrefixObject)),
    CFormHeaderPrefixObject) then
  begin
    APayload := Copy(ALine, Length(CFormHeaderPrefixObject) + 1, MaxInt);
    Exit(True);
  end;
  if SameText(Copy(ALine, 1, Length(CFormHeaderPrefixInherited)),
    CFormHeaderPrefixInherited) then
  begin
    APayload := Copy(ALine, Length(CFormHeaderPrefixInherited) + 1, MaxInt);
    Exit(True);
  end;
  if SameText(Copy(ALine, 1, Length(CFormHeaderPrefixInline)),
    CFormHeaderPrefixInline) then
  begin
    APayload := Copy(ALine, Length(CFormHeaderPrefixInline) + 1, MaxInt);
    Exit(True);
  end;
end;

// Splits `Name: TypeName` (DFM header payload) into the two components.
// Returns False when the colon is missing.
function _SplitNameType(const APayload: string;
  out AName, ATypeName: string): Boolean;
var
  LColon: Integer;
begin
  Result := False;
  AName := '';
  ATypeName := '';
  LColon := Pos(':', APayload);
  if LColon <= 1 then
    Exit;
  AName := Trim(Copy(APayload, 1, LColon - 1));
  ATypeName := Trim(Copy(APayload, LColon + 1, MaxInt));
  // Trim a trailing `[index]` (collection item marker — not needed for our
  // ListFormComponents schema; we ignore the index).
  if Pos('[', ATypeName) > 0 then
    ATypeName := Trim(Copy(ATypeName, 1, Pos('[', ATypeName) - 1));
  Result := (AName <> '') and (ATypeName <> '');
end;

class function TDFMParser.IsBinaryDFM(const ABytes: TBytes): Boolean;
begin
  if Length(ABytes) = 0 then
    Exit(False);
  Result := ABytes[0] = $FF;
end;

class function TDFMParser.ParseFormHeader(const AContent: string;
  out AName, ATypeName: string): Boolean;
var
  LLines: TStringList;
  LFor: Integer;
  LLine, LPayload: string;
begin
  AName := '';
  ATypeName := '';
  Result := False;
  LLines := TStringList.Create;
  try
    LLines.Text := AContent;
    for LFor := 0 to LLines.Count - 1 do
    begin
      LLine := Trim(LLines[LFor]);
      if LLine = '' then
        Continue;
      if _IsBlockOpener(LLine, LPayload) then
      begin
        Result := _SplitNameType(LPayload, AName, ATypeName);
        Exit;
      end;
    end;
  finally
    LLines.Free;
  end;
end;

// Single-pass walker context shared by the enumeration / extraction
// functions. Encapsulates current depth so the public functions stay short.
type
  TDFMWalker = record
    Lines: TStringList;
    Depth: Integer;
  end;

function _NewWalker(const AContent: string): TDFMWalker;
begin
  Result.Lines := TStringList.Create;
  Result.Lines.Text := AContent;
  Result.Depth := 0;
end;

procedure _FreeWalker(var AWalker: TDFMWalker);
begin
  AWalker.Lines.Free;
  AWalker.Lines := nil;
end;

// Returns the kind of structural line at AIndex inside AWalker:
//   0 = ignorable (blank / property / continuation)
//   1 = block opener; APayload carries the `Name: Type` substring
//   2 = end marker (`end`)
function _ClassifyLine(const ALine: string; out APayload: string): Integer;
begin
  if _IsBlockOpener(Trim(ALine), APayload) then
    Exit(1);
  if SameText(Trim(ALine), CEndMarker) then
    Exit(2);
  Result := 0;
end;

class function TDFMParser.EnumerateImmediateChildren(
  const AContent: string): TArray<TDFMComponentRef>;
var
  LWalker: TDFMWalker;
  LFor, LKind: Integer;
  LPayload, LName, LType: string;
  LResult: TList<TDFMComponentRef>;
  LItem: TDFMComponentRef;
begin
  SetLength(Result, 0);
  LResult := TList<TDFMComponentRef>.Create;
  LWalker := _NewWalker(AContent);
  try
    for LFor := 0 to LWalker.Lines.Count - 1 do
    begin
      LKind := _ClassifyLine(LWalker.Lines[LFor], LPayload);
      if LKind = 1 then
      begin
        Inc(LWalker.Depth);
        if (LWalker.Depth = 2) and _SplitNameType(LPayload, LName, LType) then
        begin
          LItem.Name := LName;
          LItem.TypeName := LType;
          LItem.Owner := '';
          LResult.Add(LItem);
        end;
      end
      else if LKind = 2 then
        Dec(LWalker.Depth);
    end;
    Result := LResult.ToArray;
  finally
    _FreeWalker(LWalker);
    LResult.Free;
  end;
end;

class function TDFMParser.EnumerateAllComponents(
  const AContent: string): TArray<TDFMComponentRef>;
var
  LWalker: TDFMWalker;
  LFor, LKind: Integer;
  LPayload, LName, LType: string;
  LResult: TList<TDFMComponentRef>;
  LItem: TDFMComponentRef;
  LStack: TArray<string>;
begin
  SetLength(Result, 0);
  LResult := TList<TDFMComponentRef>.Create;
  LWalker := _NewWalker(AContent);
  try
    SetLength(LStack, 0);
    for LFor := 0 to LWalker.Lines.Count - 1 do
    begin
      LKind := _ClassifyLine(LWalker.Lines[LFor], LPayload);
      if LKind = 1 then
      begin
        Inc(LWalker.Depth);
        if not _SplitNameType(LPayload, LName, LType) then
        begin
          // An opener we cannot name still opens a scope. Pushing a placeholder
          // keeps the stack aligned with the depth, so every LATER component
          // still reports the right owner instead of being shifted by one.
          SetLength(LStack, Length(LStack) + 1);
          LStack[High(LStack)] := '';
          Continue;
        end;
        if LWalker.Depth >= 2 then
        begin
          LItem.Name := LName;
          LItem.TypeName := LType;
          if Length(LStack) > 0 then
            LItem.Owner := LStack[High(LStack)]
          else
            LItem.Owner := '';
          LResult.Add(LItem);
        end;
        SetLength(LStack, Length(LStack) + 1);
        LStack[High(LStack)] := LName;
      end
      else if LKind = 2 then
      begin
        Dec(LWalker.Depth);
        if Length(LStack) > 0 then
          SetLength(LStack, Length(LStack) - 1);
      end;
    end;
    Result := LResult.ToArray;
  finally
    _FreeWalker(LWalker);
    LResult.Free;
  end;
end;

// Parses an assignment line `Name = Value`. Returns False when the line
// does not contain a top-level `=` (collection items, set literals already
// nested, etc.).
function _ParseAssignment(const ALine: string;
  out AName, AValue: string): Boolean;
var
  LEq: Integer;
  LTrim: string;
begin
  Result := False;
  AName := '';
  AValue := '';
  LTrim := Trim(ALine);
  if LTrim = '' then
    Exit;
  LEq := Pos('=', LTrim);
  if LEq <= 1 then
    Exit;
  AName := Trim(Copy(LTrim, 1, LEq - 1));
  AValue := Trim(Copy(LTrim, LEq + 1, MaxInt));
  // Reject identifiers that contain whitespace or `:` — those are headers
  // or malformed assignments, not properties.
  if (AName = '') or (Pos(' ', AName) > 0) or (Pos(':', AName) > 0) then
  begin
    AName := '';
    AValue := '';
    Exit;
  end;
  Result := True;
end;

class function TDFMParser.ExtractTopLevelProperties(
  const AContent: string): TArray<TDFMPropertyPair>;
var
  LWalker: TDFMWalker;
  LFor, LKind: Integer;
  LPayload, LName, LValue: string;
  LResult: TList<TDFMPropertyPair>;
  LItem: TDFMPropertyPair;
begin
  SetLength(Result, 0);
  LResult := TList<TDFMPropertyPair>.Create;
  LWalker := _NewWalker(AContent);
  try
    for LFor := 0 to LWalker.Lines.Count - 1 do
    begin
      LKind := _ClassifyLine(LWalker.Lines[LFor], LPayload);
      if LKind = 1 then
        Inc(LWalker.Depth)
      else if LKind = 2 then
        Dec(LWalker.Depth)
      else if LWalker.Depth = 1 then
      begin
        if _ParseAssignment(LWalker.Lines[LFor], LName, LValue) then
        begin
          LItem.Name := LName;
          LItem.Value := LValue;
          LResult.Add(LItem);
        end;
      end;
    end;
    Result := LResult.ToArray;
  finally
    _FreeWalker(LWalker);
    LResult.Free;
  end;
end;

// Component-scoped walker state. Tracks whether we are inside the target
// component and at what depth so we only collect direct assignments.
type
  TComponentScope = record
    Walker: TDFMWalker;
    InTarget: Boolean;
    TargetDepth: Integer;
  end;

function _OpenComponentScope(const AContent: string): TComponentScope;
begin
  Result.Walker := _NewWalker(AContent);
  Result.InTarget := False;
  Result.TargetDepth := -1;
end;

procedure _CloseComponentScope(var AScope: TComponentScope);
begin
  _FreeWalker(AScope.Walker);
end;

// Updates AScope after a structural line. Returns True when AScope.InTarget
// is now active for the current line index (caller uses it to decide if it
// must collect/replace).
procedure _StepComponentBlock(var AScope: TComponentScope;
  const AComponentName: string; const AKind: Integer;
  const APayload: string);
var
  LName, LType: string;
begin
  if AKind = 1 then
  begin
    Inc(AScope.Walker.Depth);
    if not AScope.InTarget then
      if _SplitNameType(APayload, LName, LType)
        and SameText(LName, AComponentName) then
      begin
        AScope.InTarget := True;
        AScope.TargetDepth := AScope.Walker.Depth;
      end;
  end
  else if AKind = 2 then
  begin
    if AScope.InTarget and (AScope.Walker.Depth = AScope.TargetDepth) then
      AScope.InTarget := False;
    Dec(AScope.Walker.Depth);
  end;
end;

class function TDFMParser.ExtractComponentProperties(const AContent,
  AComponentName: string): TArray<TDFMPropertyPair>;
var
  LScope: TComponentScope;
  LFor, LKind: Integer;
  LPayload, LName, LValue: string;
  LResult: TList<TDFMPropertyPair>;
  LItem: TDFMPropertyPair;
begin
  SetLength(Result, 0);
  LResult := TList<TDFMPropertyPair>.Create;
  LScope := _OpenComponentScope(AContent);
  try
    for LFor := 0 to LScope.Walker.Lines.Count - 1 do
    begin
      LKind := _ClassifyLine(LScope.Walker.Lines[LFor], LPayload);
      if LKind <> 0 then
        _StepComponentBlock(LScope, AComponentName, LKind, LPayload)
      else if LScope.InTarget
        and (LScope.Walker.Depth = LScope.TargetDepth) then
      begin
        if _ParseAssignment(LScope.Walker.Lines[LFor], LName, LValue) then
        begin
          LItem.Name := LName;
          LItem.Value := LValue;
          LResult.Add(LItem);
        end;
      end;
    end;
    Result := LResult.ToArray;
  finally
    _CloseComponentScope(LScope);
    LResult.Free;
  end;
end;

// Builds the formatted assignment string `<Indent><Name> = <Value>`.
function _FormatAssignment(const AIndent, AName, AValue: string): string;
begin
  Result := AIndent + AName + ' = ' + AValue;
end;

// In-place rewrite of a single assignment line. Returns the new line text,
// AChanged = True when the value moved, AChanged = False when identical.
function _RewriteAssignment(const ALine, AName, AValue, AIndent: string;
  out AChanged: Boolean): string;
var
  LCurName, LCurValue: string;
begin
  AChanged := False;
  Result := ALine;
  if not _ParseAssignment(ALine, LCurName, LCurValue) then
    Exit;
  if not SameText(LCurName, AName) then
    Exit;
  if LCurValue = AValue then
    Exit;  // BR-5 idempotency
  Result := _FormatAssignment(AIndent, AName, AValue);
  AChanged := True;
end;

// Returns True when the assignment on ALine names AName (case-insensitive,
// trimmed). Used to detect idempotent matches that did not change the value.
function _IsAssignmentNamed(const ALine, AName: string): Boolean;
var
  LEq: Integer;
begin
  LEq := Pos('=', ALine);
  if LEq <= 0 then
    Exit(False);
  Result := SameText(Trim(Copy(ALine, 1, LEq - 1)), AName);
end;

// In-place rewrite of one candidate line at AIndex. Returns True when the
// line matched the target AName (whether the value moved or was already
// identical). AChanged reflects only the mutating case.
function _ApplyPropertyAtLine(const ALines: TStringList;
  const AIndex: Integer; const AName, AValue, AIndent: string;
  out AChanged: Boolean): Boolean;
var
  LRewritten: string;
  LWasChanged: Boolean;
begin
  AChanged := False;
  LRewritten := _RewriteAssignment(ALines[AIndex], AName, AValue, AIndent,
    LWasChanged);
  if LRewritten <> ALines[AIndex] then
  begin
    ALines[AIndex] := LRewritten;
    AChanged := True;
    Exit(True);
  end;
  Result := (not LWasChanged) and _IsAssignmentNamed(ALines[AIndex], AName);
end;

// Tracks form-scope walking state while ReplaceFormProperty scans the file.
// LKind 1/2/0 = open/close/non-structural (already classified by caller).
procedure _StepFormScope(var ADepth, AFormBodyAt: Integer;
  const ALineIndex, AKind: Integer);
begin
  if AKind = 1 then
  begin
    Inc(ADepth);
    if (ADepth = 1) and (AFormBodyAt < 0) then
      AFormBodyAt := ALineIndex + 1;
  end
  else if AKind = 2 then
    Dec(ADepth);
end;

class function TDFMParser.ReplaceFormProperty(const AContent, APropName, APropValue: string;
  out AChanged: Boolean): string;
var
  LWalker: TDFMWalker;
  LFor, LKind, LFormBodyAt: Integer;
  LPayload: string;
  LFound, LLineChanged: Boolean;
begin
  AChanged := False;
  Result := AContent;
  LWalker := _NewWalker(AContent);
  try
    LFound := False;
    LFormBodyAt := -1;
    for LFor := 0 to LWalker.Lines.Count - 1 do
    begin
      LKind := _ClassifyLine(LWalker.Lines[LFor], LPayload);
      if LKind <> 0 then
        _StepFormScope(LWalker.Depth, LFormBodyAt, LFor, LKind)
      else if LWalker.Depth = 1 then
        if _ApplyPropertyAtLine(LWalker.Lines, LFor, APropName, APropValue,
          '  ', LLineChanged) then
        begin
          AChanged := AChanged or LLineChanged;
          LFound := True;
          Break;
        end;
    end;
    if (not LFound) and (LFormBodyAt >= 0) then
    begin
      LWalker.Lines.Insert(LFormBodyAt,
        _FormatAssignment('  ', APropName, APropValue));
      AChanged := True;
    end;
    if AChanged then
      Result := LWalker.Lines.Text;
  finally
    _FreeWalker(LWalker);
  end;
end;

// Updates component-scope tracking on a structural line. Sets ABodyAt the
// first time we enter the target block, so the caller can insert an
// assignment after the header if no existing property matched.
procedure _TrackComponentScope(var AScope: TComponentScope;
  var ABodyAt: Integer; const AComponentName, APayload: string;
  const ALineIndex, AKind: Integer; out AFound: Boolean);
begin
  AFound := False;
  _StepComponentBlock(AScope, AComponentName, AKind, APayload);
  if (AKind = 1) and AScope.InTarget and (ABodyAt = -1)
    and (AScope.Walker.Depth = AScope.TargetDepth) then
  begin
    AFound := True;
    ABodyAt := ALineIndex + 1;
  end;
end;

type
  TComponentRewriteOp = record
    ComponentName: string;
    PropName: string;
    PropValue: string;
  end;

// Processes one DFM line for ReplaceComponentProperty. Updates scope state
// in place and returns True when the caller should break out of the scan
// (target property matched — either rewritten or already idempotent).
function _StepComponentRewrite(var AScope: TComponentScope;
  var ABodyAt: Integer; var AFound, AChanged: Boolean;
  const AOp: TComponentRewriteOp; const ALineIndex: Integer): Boolean;
var
  LKind: Integer;
  LPayload: string;
  LStepFound, LLineChanged: Boolean;
begin
  Result := False;
  LKind := _ClassifyLine(AScope.Walker.Lines[ALineIndex], LPayload);
  if LKind <> 0 then
  begin
    _TrackComponentScope(AScope, ABodyAt, AOp.ComponentName, LPayload,
      ALineIndex, LKind, LStepFound);
    if LStepFound then
      AFound := True;
    Exit;
  end;
  if not (AScope.InTarget
    and (AScope.Walker.Depth = AScope.TargetDepth)) then
    Exit;
  if _ApplyPropertyAtLine(AScope.Walker.Lines, ALineIndex, AOp.PropName,
    AOp.PropValue, '    ', LLineChanged) then
  begin
    AChanged := AChanged or LLineChanged;
    Result := True;
  end;
end;

class function TDFMParser.ReplaceComponentProperty(const AContent, AComponentName, APropName,
  APropValue: string; out AChanged, AFound: Boolean): string;
var
  LScope: TComponentScope;
  LFor, LComponentBodyAt: Integer;
  LDone: Boolean;
  LOp: TComponentRewriteOp;
begin
  AChanged := False;
  AFound := False;
  LDone := False;
  Result := AContent;
  LComponentBodyAt := -1;
  LOp.ComponentName := AComponentName;
  LOp.PropName := APropName;
  LOp.PropValue := APropValue;
  LScope := _OpenComponentScope(AContent);
  try
    for LFor := 0 to LScope.Walker.Lines.Count - 1 do
      if _StepComponentRewrite(LScope, LComponentBodyAt, AFound, AChanged,
        LOp, LFor) then
      begin
        LDone := True;
        Break;
      end;
    if AFound and (not LDone) and (LComponentBodyAt >= 0) then
    begin
      LScope.Walker.Lines.Insert(LComponentBodyAt,
        _FormatAssignment('    ', APropName, APropValue));
      AChanged := True;
    end;
    if AChanged then
      Result := LScope.Walker.Lines.Text;
  finally
    _CloseComponentScope(LScope);
  end;
end;

end.
