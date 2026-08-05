unit Aefos.MCP.DPRParser;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

(*
  Minimal `.dpr` parser for the DPR MCP tools (ESP-002, Epic 7/7 Demand 6/8,
  ADR-139).

  Scope: enumerates `Application.CreateForm(TFormClass, FormVar);` calls
  and reorders/inserts a target form to position 0 for `SetMainForm`.
  Out-of-grammar input (no `Application.CreateForm` calls) returns the
  source unchanged with `AChanged=False`.

  Boundary (ADR-115 / BR-1): zero `uses ToolsAPI`. RTL-only.
*)

interface

type
  TDPRCreateFormCall = record
    FormClass: string;     // e.g. `TMainForm`
    FormVar: string;       // e.g. `MainForm`
    UnitName: string;      // best-effort — derived from form class
    LineIndex: Integer;    // 0-based line in the DPR
    RawLine: string;       // verbatim original line including indent
  end;

// Enumerates every `Application.CreateForm(TXxx, YyyVar);` call found in
// ADPRContent. The match is line-oriented and case-insensitive on the
// keyword `Application.CreateForm`; the argument list is captured by
// finding the first `(` and the matching `)` on the same line.
function EnumerateCreateFormCalls(
  const ADPRContent: string): TArray<TDPRCreateFormCall>;

// Returns the DPR content with the `Application.CreateForm` call referring
// to ATargetFormClass moved to position 0 (first CreateForm). Other calls
// preserve their relative order. AChanged is False when the target is
// already at position 0 (BR-5 idempotency) OR when the target is not found.
// The caller is expected to surface the "not found" path as an error.
function ReorderMainForm(const ADPRContent, ATargetFormClass: string;
  out AChanged: Boolean): string;

implementation

uses
  SysUtils,
  Classes,
  Generics.Collections;

const
  CCreateFormKeyword = 'Application.CreateForm';

// Returns True when ALine is a `Application.CreateForm(...)` call line.
// APos is the 1-based position of `Application` inside ALine.
function _IsCreateFormLine(const ALine: string; out APos: Integer): Boolean;
var
  LLower: string;
begin
  LLower := LowerCase(ALine);
  APos := Pos(LowerCase(CCreateFormKeyword), LLower);
  Result := APos > 0;
end;

// Extracts the substring between the first `(` and the matching `)` after
// AStartPos in ALine. Returns False when no balanced parens exist on the
// line (out-of-grammar — multi-line calls are rare for CreateForm).
function _ExtractArgList(const ALine: string; const AStartPos: Integer;
  out AArgs: string): Boolean;
var
  LOpen, LClose: Integer;
begin
  Result := False;
  AArgs := '';
  LOpen := Pos('(', ALine, AStartPos);
  if LOpen = 0 then
    Exit;
  LClose := Pos(')', ALine, LOpen);
  if LClose = 0 then
    Exit;
  AArgs := Trim(Copy(ALine, LOpen + 1, LClose - LOpen - 1));
  Result := AArgs <> '';
end;

// Splits "TFormClass, FormVar" into the two identifiers. Returns False on
// missing comma or empty halves.
function _SplitArgs(const AArgs: string;
  out AFormClass, AFormVar: string): Boolean;
var
  LComma: Integer;
begin
  Result := False;
  AFormClass := '';
  AFormVar := '';
  LComma := Pos(',', AArgs);
  if LComma <= 1 then
    Exit;
  AFormClass := Trim(Copy(AArgs, 1, LComma - 1));
  AFormVar := Trim(Copy(AArgs, LComma + 1, MaxInt));
  Result := (AFormClass <> '') and (AFormVar <> '');
end;

// Derives a best-effort UnitName from the form class — strips the leading
// `T` from `TFooBar` → `FooBar`. The MCP tool layer only cares about the
// returned field; the LLM uses it for context, never for resolution.
function _DeriveUnitName(const AFormClass: string): string;
begin
  if (Length(AFormClass) > 1)
    and (AFormClass[1] = 'T')
    and CharInSet(AFormClass[2], ['A'..'Z']) then
    Result := Copy(AFormClass, 2, MaxInt)
  else
    Result := AFormClass;
end;

function EnumerateCreateFormCalls(
  const ADPRContent: string): TArray<TDPRCreateFormCall>;
var
  LLines: TStringList;
  LFor, LPos: Integer;
  LArgs, LClass, LVar: string;
  LResult: TList<TDPRCreateFormCall>;
  LItem: TDPRCreateFormCall;
begin
  SetLength(Result, 0);
  LLines := TStringList.Create;
  LResult := TList<TDPRCreateFormCall>.Create;
  try
    LLines.Text := ADPRContent;
    for LFor := 0 to LLines.Count - 1 do
    begin
      if not _IsCreateFormLine(LLines[LFor], LPos) then
        Continue;
      if not _ExtractArgList(LLines[LFor], LPos, LArgs) then
        Continue;
      if not _SplitArgs(LArgs, LClass, LVar) then
        Continue;
      LItem.FormClass := LClass;
      LItem.FormVar := LVar;
      LItem.UnitName := _DeriveUnitName(LClass);
      LItem.LineIndex := LFor;
      LItem.RawLine := LLines[LFor];
      LResult.Add(LItem);
    end;
    Result := LResult.ToArray;
  finally
    LResult.Free;
    LLines.Free;
  end;
end;

// Locates the call that targets ATargetFormClass inside ACalls. Returns
// -1 when none matches.
function _FindCallIndex(const ACalls: TArray<TDPRCreateFormCall>;
  const ATargetFormClass: string): Integer;
var
  LFor: Integer;
begin
  Result := -1;
  for LFor := 0 to High(ACalls) do
    if SameText(ACalls[LFor].FormClass, ATargetFormClass) then
      Exit(LFor);
end;

function ReorderMainForm(const ADPRContent, ATargetFormClass: string;
  out AChanged: Boolean): string;
var
  LCalls: TArray<TDPRCreateFormCall>;
  LTarget, LFirstLine, LFor: Integer;
  LLines: TStringList;
  LTargetLine: string;
begin
  AChanged := False;
  Result := ADPRContent;
  LCalls := EnumerateCreateFormCalls(ADPRContent);
  if Length(LCalls) = 0 then
    Exit;
  LTarget := _FindCallIndex(LCalls, ATargetFormClass);
  if LTarget < 0 then
    Exit;
  // Idempotent: already the first call.
  if LTarget = 0 then
    Exit;
  // Move LCalls[LTarget]'s line above the line of LCalls[0]. We physically
  // delete the target line and insert a copy just before the current first
  // CreateForm line. Lines between the two are preserved in place.
  LFirstLine := LCalls[0].LineIndex;
  LLines := TStringList.Create;
  try
    LLines.Text := ADPRContent;
    LTargetLine := LLines[LCalls[LTarget].LineIndex];
    LLines.Delete(LCalls[LTarget].LineIndex);
    // After deletion, line indices > LCalls[LTarget].LineIndex shift -1.
    // LFirstLine < LCalls[LTarget].LineIndex (target was below first), so
    // it does not shift.
    LFor := LFirstLine;
    LLines.Insert(LFor, LTargetLine);
    Result := LLines.Text;
    AChanged := True;
  finally
    LLines.Free;
  end;
end;

end.
