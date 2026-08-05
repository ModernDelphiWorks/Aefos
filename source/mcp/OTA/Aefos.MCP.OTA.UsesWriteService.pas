unit Aefos.MCP.OTA.UsesWriteService;

{
  Uses-clause read+write domain, extracted from the TMCPWorkspaceFacade god-object
  as a focused service of the SOLID split (audit S6 / facade split).

  Owns GetUnitUses (parse a unit's interface+implementation uses clauses) and the
  two writers AddToUses / RemoveFromUses, plus their text helpers — the uses-clause
  lexer (_FlushUsesEntry / _StepUsesChar / _ParseUsesEntries), the span locators
  (_FindUsesClause / _SpliceUsesClause / _InsertUsesClause), the section normalizer
  and the active-project guard, and the pure source transforms
  (_ComputeAddToUses / _ComputeRemoveFromUses). The pure membership decisions stay in
  the FormUsesWritePolicy seam (MergeUsesUnit / RemoveUsesUnit / BuildUsesClauseBody).

  AddToUses / RemoveFromUses are buffer-based + REVIEWABLE: they read the live source
  editor, compute the new whole-buffer with the pure transform, and route the replace
  through the ✓/✗ inline-diff gate (_ApplyReviewedReplace → ReviewGate.TReviewGate.ReviewBufferChange,
  falling back to the WithLiveSource S2 seam when no approver). Same three-step plan/
  review/apply as InsertMethod — so a uses edit shows the gutter and is rejectable,
  and it no longer round-trips a stale .pas on disk (the old silent-write clobber path).

  Dependencies are drawn from already-shared units: FacadeShared (FindUnitPath /
  ResolveUnitModule / FirstSourceEditor / ActiveSourceEditor / ReadBytes),
  FormUsesWritePolicy, ReviewGate and Aefos.Harness.View. The OTA source editor
  (IOTASourceEditor) is referenced for the buffer read; no facade state (no FAudit).
  The facade delegates its frozen IMCPWorkspaceFacade methods to a refcounted
  FUsesWrite field.
}

interface

type
  IMCPUsesWriteService = interface
    ['{5E9C2A18-7D63-4B40-8F27-3A6C1B5E8D40}']
    function GetUnitUses(const AUnitName: string;
      out AInterfaceUses, AImplementationUses: TArray<string>): Boolean;
    function AddToUses(const ATargetUnit, AUnitToAdd, ASection: string;
      out AChanged: Boolean): Boolean;
    function RemoveFromUses(const ATargetUnit, AUnitToRemove: string;
      out AChanged: Boolean): Boolean;
  end;

// Factory — the facade calls this once in its constructor.
function NewMCPUsesWriteService: IMCPUsesWriteService;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  System.IOUtils,
  ToolsAPI,
  Aefos.Harness.View,         // WithLiveSource (S2 code-mutation seam, silent apply)
  Aefos.MCP.Types,            // TMCPDiffDecision
  Aefos.MCP.OTA.FacadeShared,
  Aefos.MCP.OTA.ReviewGate,   // TReviewGate.ReviewBufferChange (the ✓/✗ inline-diff gate)
  Aefos.MCP.OTA.FormUsesWritePolicy;

type
  TMCPUsesWriteService = class(TInterfacedObject, IMCPUsesWriteService)
  public
    function GetUnitUses(const AUnitName: string;
      out AInterfaceUses, AImplementationUses: TArray<string>): Boolean;
    function AddToUses(const ATargetUnit, AUnitToAdd, ASection: string;
      out AChanged: Boolean): Boolean;
    function RemoveFromUses(const ATargetUnit, AUnitToRemove: string;
      out AChanged: Boolean): Boolean;
  end;

// Strips an optional `in '<path>'` qualifier and adds the bare unit name.
procedure _FlushUsesEntry(const ABuf: TStringBuilder;
  const AResult: TList<string>);
var
  LBare: string;
  LInPos: Integer;
begin
  LBare := Trim(ABuf.ToString);
  if LBare <> '' then
  begin
    LInPos := Pos(' in ', LowerCase(LBare));
    if LInPos > 0 then
      LBare := Trim(Copy(LBare, 1, LInPos - 1));
    if LBare <> '' then
      AResult.Add(LBare);
  end;
  ABuf.Clear;
end;

// Lexes one uses-clause char, tracking comment state and flushing on commas.
procedure _StepUsesChar(const ABody: string; const APos: Integer;
  var ABraceComment, ALineComment: Boolean;
  const ABuf: TStringBuilder; const AResult: TList<string>);
var
  LCh: Char;
begin
  LCh := ABody[APos];
  if ALineComment then
  begin
    if (LCh = #10) or (LCh = #13) then
      ALineComment := False;
  end
  else if ABraceComment then
  begin
    if LCh = '}' then
      ABraceComment := False;
  end
  else if LCh = '{' then
    ABraceComment := True
  else if (LCh = '/') and (APos < Length(ABody)) and (ABody[APos + 1] = '/') then
    ALineComment := True
  else if LCh = ',' then
    _FlushUsesEntry(ABuf, AResult)
  else
    ABuf.Append(LCh);
end;

// Parses a uses-clause body into bare unit identifiers.
function _ParseUsesEntries(const AClauseBody: string): TArray<string>;
var
  LBuf: TStringBuilder;
  LFor: Integer;
  LInBraceComment, LInLineComment: Boolean;
  LResult: TList<string>;
begin
  LResult := TList<string>.Create;
  LBuf := TStringBuilder.Create;
  try
    LInBraceComment := False;
    LInLineComment := False;
    for LFor := 1 to Length(AClauseBody) do
      _StepUsesChar(AClauseBody, LFor, LInBraceComment, LInLineComment,
        LBuf, LResult);
    _FlushUsesEntry(LBuf, LResult);
    Result := LResult.ToArray;
  finally
    LBuf.Free;
    LResult.Free;
  end;
end;

// Returns the text between a section's `uses` and the next `;`.
function _FindUsesClause(const ASource, ASectionKeyword: string;
  out ABody: string): Boolean;
var
  LLower: string;
  LSectionAt, LUsesAt, LSemiAt, LBodyStart: Integer;
begin
  Result := False;
  ABody := '';
  LLower := LowerCase(ASource);
  LSectionAt := Pos(LowerCase(ASectionKeyword), LLower);
  if LSectionAt = 0 then Exit;
  LUsesAt := Pos('uses', LLower, LSectionAt + Length(ASectionKeyword));
  if LUsesAt = 0 then Exit;
  // For the interface section, never spill into implementation's uses.
  if SameText(ASectionKeyword, 'interface') then
  begin
    LSectionAt := Pos('implementation', LLower);
    if (LSectionAt > 0) and (LUsesAt > LSectionAt) then Exit;
  end;
  LSemiAt := Pos(';', ASource, LUsesAt + 4);
  if LSemiAt = 0 then Exit;
  LBodyStart := LUsesAt + 4;
  ABody := Copy(ASource, LBodyStart, LSemiAt - LBodyStart);
  Result := True;
end;

function _IsActiveProjectModule(const APath: string): Boolean;
var
  LPaths: TArray<string>;
  LFor: Integer;
begin
  Result := False;
  if APath = '' then Exit;
  LPaths := TFacadeShared.EnumProjectUnitPaths;
  for LFor := 0 to High(LPaths) do
    if SameText(LPaths[LFor], APath) then
      Exit(True);
end;

// Replaces the body of ASectionKeyword's `uses` clause (the text between `uses`
// and the terminating `;`) with ANewBody, leaving every other byte of ASource
// verbatim. Mirrors _FindUsesClause's span location so the interface section
// never spills into implementation's clause. False when the section/clause is
// absent (R1 — no partial rewrite).
function _SpliceUsesClause(const ASource, ASectionKeyword, ANewBody: string;
  out ANewSource: string): Boolean;
var
  LLower: string;
  LSectionAt, LUsesAt, LSemiAt, LBodyStart, LImplAt: Integer;
begin
  Result := False;
  ANewSource := ASource;
  LLower := LowerCase(ASource);
  LSectionAt := Pos(LowerCase(ASectionKeyword), LLower);
  if LSectionAt = 0 then Exit;
  LUsesAt := Pos('uses', LLower, LSectionAt + Length(ASectionKeyword));
  if LUsesAt = 0 then Exit;
  if SameText(ASectionKeyword, 'interface') then
  begin
    LImplAt := Pos('implementation', LLower);
    if (LImplAt > 0) and (LUsesAt > LImplAt) then Exit;
  end;
  LSemiAt := Pos(';', ASource, LUsesAt + 4);
  if LSemiAt = 0 then Exit;
  LBodyStart := LUsesAt + 4;
  ANewSource := Copy(ASource, 1, LBodyStart - 1) + ANewBody +
    Copy(ASource, LSemiAt, MaxInt);
  Result := True;
end;

// Inserts a new `uses AUnitToAdd;` block immediately after ASectionKeyword in
// ASource when no `uses` clause exists in that section yet — the insert point
// is the first character of the line following the section keyword line. False
// when the section keyword is absent (R1 — no partial write). Used by AddToUses
// to handle units whose implementation section has no `uses` yet.
function _InsertUsesClause(const ASource, ASectionKeyword, AUnitToAdd: string;
  out ANewSource: string): Boolean;
var
  LLower: string;
  LSectionAt, LInsertAt: Integer;
  LNewBlock: string;
begin
  Result    := False;
  ANewSource := ASource;
  if Trim(AUnitToAdd) = '' then Exit;
  LLower := LowerCase(ASource);
  LSectionAt := Pos(LowerCase(ASectionKeyword), LLower);
  if LSectionAt = 0 then Exit;
  // Advance past the keyword and any trailing blanks/tabs on its line.
  LInsertAt := LSectionAt + Length(ASectionKeyword);
  while (LInsertAt <= Length(ASource)) and
    CharInSet(ASource[LInsertAt], [' ', #9]) do
    Inc(LInsertAt);
  // Skip the line-ending after the keyword.
  if (LInsertAt <= Length(ASource)) and (ASource[LInsertAt] = #13) then
    Inc(LInsertAt);
  if (LInsertAt <= Length(ASource)) and (ASource[LInsertAt] = #10) then
    Inc(LInsertAt);
  LNewBlock := sLineBreak + 'uses' + sLineBreak + '  ' + Trim(AUnitToAdd) + ';' + sLineBreak;
  ANewSource := Copy(ASource, 1, LInsertAt - 1) + LNewBlock +
    Copy(ASource, LInsertAt, MaxInt);
  Result := True;
end;

// Normalizes a requested `uses` section name to 'interface'/'implementation';
// empty defaults to 'interface'. Empty result = unsupported section.
function _NormalizeUsesSection(const ASection: string): string;
begin
  Result := LowerCase(Trim(ASection));
  if Result = '' then
    Result := 'interface';
  if (Result <> 'interface') and (Result <> 'implementation') then
    Result := '';
end;

// Pure source transform (no I/O): merges AUnitToAdd into ASection's `uses` clause of
// ASource (or inserts a fresh clause when absent), returning the new source in
// ANewSource. Result=True on success; AChanged=True only when the source actually
// changed (an already-present unit is a valid no-op: Result=True, AChanged=False).
// Extracted from the old disk-based _DoAddToUses so the live AddToUses can route the
// whole-buffer replace through the review gate. Backs R1 (no drop/dup).
function _ComputeAddToUses(const ASource, ASection, AUnitToAdd: string;
  out ANewSource: string; out AChanged: Boolean): Boolean;
var
  LClause, LNewBody: string;
  LEntries, LNewEntries: TArray<string>;
  LMerged: Boolean;
begin
  Result     := False;
  AChanged   := False;
  ANewSource := ASource;
  if ASource = '' then Exit;
  if not _FindUsesClause(ASource, ASection, LClause) then
  begin
    // No existing clause in this section — insert a new one (R1: no existing
    // units to drop/dup; single-unit insert is always a change).
    if not _InsertUsesClause(ASource, ASection, AUnitToAdd, ANewSource) then Exit;
    AChanged := True;
    Result   := True;
    Exit;
  end;
  LEntries := _ParseUsesEntries(LClause);
  if not TFormUsesWritePolicy.MergeUsesUnit(LEntries, AUnitToAdd, LNewEntries, LMerged) then Exit;
  if not LMerged then
  begin
    Result := True; // already present — valid no-op
    Exit;
  end;
  LNewBody := TFormUsesWritePolicy.BuildUsesClauseBody(LNewEntries);
  if not _SpliceUsesClause(ASource, ASection, LNewBody, ANewSource) then Exit;
  AChanged := True;
  Result   := True;
end;

// Pure source transform (no I/O): removes AUnitToRemove from both interface and
// implementation `uses` clauses of ASource, returning the new source in ANewSource.
// Result=True for any non-empty source (absent unit is a valid idempotent no-op:
// AChanged=False); AChanged=True only when at least one clause was rewritten.
// Extracted from the old disk-based _DoRemoveFromUses. Backs R1 (no drop/dup).
function _ComputeRemoveFromUses(const ASource, AUnitToRemove: string;
  out ANewSource: string; out AChanged: Boolean): Boolean;
const
  CSections: array[0..1] of string = ('interface', 'implementation');
var
  LClause, LNewBody, LSpliced: string;
  LEntries, LNewEntries: TArray<string>;
  LDropped: Boolean;
  LFor: Integer;
begin
  Result     := False;
  AChanged   := False;
  ANewSource := ASource;
  if ASource = '' then Exit;
  for LFor := Low(CSections) to High(CSections) do
  begin
    if not _FindUsesClause(ANewSource, CSections[LFor], LClause) then Continue;
    LEntries := _ParseUsesEntries(LClause);
    if not TFormUsesWritePolicy.RemoveUsesUnit(LEntries, AUnitToRemove, LNewEntries, LDropped) then
      Continue;
    if not LDropped then Continue;
    LNewBody := TFormUsesWritePolicy.BuildUsesClauseBody(LNewEntries);
    if _SpliceUsesClause(ANewSource, CSections[LFor], LNewBody, LSpliced) then
    begin
      ANewSource := LSpliced;
      AChanged   := True;
    end;
  end;
  Result := True; // non-empty source processed (absent unit => AChanged=False no-op)
end;

// Steps 2-3 of a reviewed whole-buffer edit, shared by AddToUses/RemoveFromUses.
// AChanged in = did Step 1 produce a change (a no-op short-circuits to True). When an
// approver is registered, route the replace through the ✓/✗ inline-diff gate (so a
// uses edit is reviewable + rejectable just like EditUnit/InsertMethod): ddApplied =>
// applied; ddRejected => False (the user's note is pulled via GetReviewFeedback).
// ddUnavailable (no approver / review off) => apply silently via the WithLiveSource
// S2 seam. Runs OFF the main thread (the gate + the seam marshal themselves), exactly
// like InsertMethod. AOutChanged echoes whether content actually changed.
function _ApplyReviewedReplace(const APath, ACurrent, ANew: string;
  const AChanged: Boolean; out AOutChanged: Boolean): Boolean;
var
  LDiffReason, LReason: string;
  LApplied: Boolean;
begin
  AOutChanged := False;
  if not AChanged then
    Exit(True); // valid no-op (already-present add / absent remove)
  case TReviewGate.ReviewBufferChange(APath, ACurrent, ANew, LDiffReason) of
    ddApplied:
      begin
        AOutChanged := True;
        Exit(True);
      end;
    ddRejected:
      Exit(False);
  end;
  LReason := 'edit-failed';
  Result := THarnessView.WithLiveSource(APath, lsCodeMutation,
    procedure(const Ctx: ILiveSourceContext)
    begin
      if not Ctx.ReplaceWhole(ANew) then
        Ctx.Fail('edit-failed');
    end,
    LApplied, LReason);
  AOutChanged := Result;
end;

{ ── TMCPUsesWriteService ───────────────────────────────────────────────── }

function TMCPUsesWriteService.GetUnitUses(const AUnitName: string;
  out AInterfaceUses, AImplementationUses: TArray<string>): Boolean;
var
  LFilePath, LSource, LClause: string;
begin
  AInterfaceUses      := [];
  AImplementationUses := [];
  Result              := False;
  LFilePath := '';
  try
    TThread.Synchronize(nil, procedure
    begin
      LFilePath := TFacadeShared.FindUnitPath(AUnitName);
    end);
  except
    LFilePath := '';
  end;
  if LFilePath = '' then Exit;
  try
    LSource := TFile.ReadAllText(LFilePath, TEncoding.UTF8);
  except
    LSource := '';
  end;
  if LSource = '' then Exit;
  try
    if _FindUsesClause(LSource, 'interface', LClause) then
      AInterfaceUses := _ParseUsesEntries(LClause);
    if _FindUsesClause(LSource, 'implementation', LClause) then
      AImplementationUses := _ParseUsesEntries(LClause);
    Result := True;
  except
    Result := False;
  end;
end;

// Add AUnitToAdd to ATargetUnit's `uses` clause in ASection (ESP-090). The pure
// FormUsesWritePolicy.MergeUsesUnit decides membership/merge (no drop/dup, R1);
// an already-present unit is a valid no-op. Scratch-module-scoped (BR10).
// GetUnitUses is the live acceptance read. The whole-buffer replace is now routed
// through the ✓/✗ review gate (buffer-based, like EditUnit/InsertMethod) instead of
// the old silent disk write — so the edit is reviewable AND never refreshes from a
// stale .pas (the clobber path).
function TMCPUsesWriteService.AddToUses(const ATargetUnit, AUnitToAdd,
  ASection: string; out AChanged: Boolean): Boolean;
var
  LEditorRef: IOTASourceEditor;
  LSection, LPath, LCurrent, LNew: string;
  LComputeOk, LChanged: Boolean;
begin
  AChanged   := False;
  LSection   := _NormalizeUsesSection(ASection);
  if LSection = '' then Exit(False);
  LEditorRef := nil;
  LComputeOk := False;
  LChanged   := False;
  // Step 1 (main thread): resolve the editor, read the BUFFER, compute the new
  // content — no mutation, so the approver can preview it.
  try
    TThread.Synchronize(nil, procedure
    var
      LModule: IOTAModule;
    begin
      if (Trim(ATargetUnit) <> '') and TFacadeShared.ResolveUnitModule(ATargetUnit, LModule) then
        LEditorRef := TFacadeShared.FirstSourceEditor(LModule);
      if not Assigned(LEditorRef) then
        if not TFacadeShared.ActiveSourceEditor(LEditorRef) then
          Exit;
      LPath := LEditorRef.FileName;
      if not _IsActiveProjectModule(LPath) then
      begin
        LEditorRef := nil; // scratch-module-scoped (BR10)
        Exit;
      end;
      LCurrent   := TFacadeShared.ReadBytes(LEditorRef.CreateReader);
      LComputeOk := _ComputeAddToUses(LCurrent, LSection, AUnitToAdd, LNew, LChanged);
    end);
  except
    Exit(False);
  end;
  if not Assigned(LEditorRef) or not LComputeOk then Exit(False);
  // Steps 2-3: review gate, then silent apply when no approver.
  Result := _ApplyReviewedReplace(LPath, LCurrent, LNew, LChanged, AChanged);
end;

// Remove AUnitToRemove from ATargetUnit's `uses` clauses (interface +
// implementation) (ESP-090). The pure FormUsesWritePolicy.RemoveUsesUnit drops
// only the named unit, every other entry kept verbatim (no drop/dup, R1); an
// absent unit is a valid idempotent no-op. Scratch-module-scoped (BR10).
// GetUnitUses is the live acceptance read. Routed through the ✓/✗ review gate
// (buffer-based) like AddToUses.
function TMCPUsesWriteService.RemoveFromUses(const ATargetUnit,
  AUnitToRemove: string; out AChanged: Boolean): Boolean;
var
  LEditorRef: IOTASourceEditor;
  LPath, LCurrent, LNew: string;
  LComputeOk, LChanged: Boolean;
begin
  AChanged   := False;
  LEditorRef := nil;
  LComputeOk := False;
  LChanged   := False;
  // Step 1 (main thread): resolve the editor, read the BUFFER, compute the new content.
  try
    TThread.Synchronize(nil, procedure
    var
      LModule: IOTAModule;
    begin
      if (Trim(ATargetUnit) <> '') and TFacadeShared.ResolveUnitModule(ATargetUnit, LModule) then
        LEditorRef := TFacadeShared.FirstSourceEditor(LModule);
      if not Assigned(LEditorRef) then
        if not TFacadeShared.ActiveSourceEditor(LEditorRef) then
          Exit;
      LPath := LEditorRef.FileName;
      if not _IsActiveProjectModule(LPath) then
      begin
        LEditorRef := nil; // scratch-module-scoped (BR10)
        Exit;
      end;
      LCurrent   := TFacadeShared.ReadBytes(LEditorRef.CreateReader);
      LComputeOk := _ComputeRemoveFromUses(LCurrent, AUnitToRemove, LNew, LChanged);
    end);
  except
    Exit(False);
  end;
  if not Assigned(LEditorRef) or not LComputeOk then Exit(False);
  // Steps 2-3: review gate, then silent apply when no approver.
  Result := _ApplyReviewedReplace(LPath, LCurrent, LNew, LChanged, AChanged);
end;

function NewMCPUsesWriteService: IMCPUsesWriteService;
begin
  Result := TMCPUsesWriteService.Create;
end;

end.
