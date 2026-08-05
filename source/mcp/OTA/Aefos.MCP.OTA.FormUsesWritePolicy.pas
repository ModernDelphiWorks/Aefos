unit Aefos.MCP.OTA.FormUsesWritePolicy;

{
  Pure form-designer / source-uses write policy seam (ESP-090, S2 / ADR-090-07 /
  BR10 / BR11 / R1 / R4).

  Pure RTL — no ToolsAPI, no VCL, no disk write. Carries the two OTA-free
  decisions the 8 form/uses writes must make before the facade touches an
  IOTAModule buffer, a `.dfm` file, or INTAServices.ActionList:

    - MergeUsesUnit        — add a unit to a parsed `uses` entry list IF absent
                             (case-insensitive), never dropping or duplicating an
                             existing entry (backs AddToUses, R1).
    - RemoveUsesUnit       — drop every case-insensitive match of a unit from a
                             parsed `uses` entry list, every other entry kept
                             verbatim and in order (backs RemoveFromUses, R1).
    - BuildUsesClauseBody  — re-emit a parsed/merged entry list as the body text
                             that sits between `uses` and `;` (one entry per line,
                             two-space indent), so the facade can splice it back
                             into the unit source without reformatting the rest of
                             the file.
    - ClassifyIDEAction    — classify a named IDE action as safe-to-invoke. The
                             generic ExecuteIDEAction tool can reach destructive /
                             global IDE state, so a two-gate substring BLOCKLIST
                             (hard- and soft-block token sets) refuses names that
                             match a block token with a kebab reason; everything
                             else passes (BR11 / R4).

  The add/remove operations never drop or duplicate an existing entry (R1):
  membership and de-dup are case-insensitive — Delphi unit identifiers are
  case-insensitive, so two entries differing only by case denote the same unit.

  This mirrors the ESP-073 UnitCreatePolicy / ESP-087 ContentWritePolicy /
  ESP-088 StructuralWritePolicy / ESP-089 ConfigWritePolicy precedent: a pure,
  dependency-free seam unit-tested headless, with the OTA wiring (the module
  buffer / `.dfm` read-modify-write, the `.dpr`/main-form open-project sentinels,
  and the INTAServices.ActionList lookup + Execute) confined to the UI facade as
  the only OTA-bound, structurally-exempt part (covered live, AC7).
}

interface

type
  // Pure form-designer / source-uses write policy seam as a sealed static
  // namespace (see the unit header for the ESP-090 / ADR-090 contract). Never
  // instantiated.
  TFormUsesWritePolicy = class sealed
  public
    // Add AUnitToAdd to ACurrent when absent (case-insensitive membership),
    // preserving ACurrent verbatim and appending the new entry at the end. ANew
    // echoes ACurrent and AChanged is False on a no-op (already present). Result is
    // False only for a blank AUnitToAdd (nothing to add); True otherwise.
    class function MergeUsesUnit(const ACurrent: TArray<string>; const AUnitToAdd: string;
      out ANew: TArray<string>; out AChanged: Boolean): Boolean; static;

    // Remove every case-insensitive match of AUnitToRemove from ACurrent, keeping
    // every other entry verbatim and in order. AChanged reflects whether anything
    // was dropped (False = absent, an idempotent no-op). Result is False only for a
    // blank AUnitToRemove (nothing to remove); True otherwise.
    class function RemoveUsesUnit(const ACurrent: TArray<string>;
      const AUnitToRemove: string;
      out ANew: TArray<string>; out AChanged: Boolean): Boolean; static;

    // Re-emit AEntries as a `uses`-clause body (the text between `uses` and `;`):
    // one entry per line, two-space indent, comma-separated. An empty list yields a
    // single space (the caller never removes the last unit of a clause). Entries are
    // emitted verbatim and in order — no drop, no dup, no reordering.
    class function BuildUsesClauseBody(const AEntries: TArray<string>): string; static;

    // Classify a named IDE action for execution (two-gate blocklist).
    //
    //   Gate 1 — hard block: substrings that indicate IDE-closing or irreversible
    //   operations (`exit`, `quit`, etc.). Refused with `destructive-action-refused`;
    //   no override.
    //
    //   Gate 2 — soft block: substrings for potentially destructive operations
    //   (`delete`, `clean`, `revert`, etc.). Refused with
    //   `destructive-action-soft-blocked`; reserved for a future `Force` parameter.
    //
    //   Everything else passes (True, empty AReason). The facade performs the
    //   actual `INTAServices.ActionList` lookup and returns `action-not-found` when
    //   the action does not exist in the live IDE.
    //
    //   Empty name → `empty-action`.
    class function ClassifyIDEAction(const AActionName: string;
      out AReason: string): Boolean; static;
  end;

implementation

uses
  System.SysUtils,
  System.Generics.Collections;

const
  // Gate 1 — hard-blocked substrings. Actions matching these close the IDE,
  // terminate processes, or irreversibly destroy state. Never overridable.
  CHardBlockTokens: array[0..5] of string =
    ('exit', 'quit', 'terminate', 'kill', 'erase', 'uninstall');
  // Gate 2 — soft-blocked substrings. Potentially destructive but sometimes
  // legitimate. Refused by default; reserved for a future Force=true override.
  CSoftBlockTokens: array[0..5] of string =
    ('delete', 'remove', 'clean', 'revert', 'reset', 'drop');

// Case-insensitive membership of AEntry in AList.
function _ContainsUnit(const AList: TArray<string>; const AEntry: string): Boolean;
var
  LFor: Integer;
begin
  Result := False;
  for LFor := 0 to High(AList) do
    if SameText(AList[LFor], AEntry) then
      Exit(True);
end;

class function TFormUsesWritePolicy.MergeUsesUnit(const ACurrent: TArray<string>; const AUnitToAdd: string;
  out ANew: TArray<string>; out AChanged: Boolean): Boolean;
var
  LEntry: string;
begin
  ANew     := ACurrent;
  AChanged := False;
  LEntry   := Trim(AUnitToAdd);
  if LEntry = '' then
    Exit(False);

  if _ContainsUnit(ACurrent, LEntry) then
    Exit(True); // already present — valid no-op, original preserved

  ANew := ACurrent + [LEntry];
  AChanged := True;
  Result   := True;
end;

class function TFormUsesWritePolicy.RemoveUsesUnit(const ACurrent: TArray<string>;
  const AUnitToRemove: string;
  out ANew: TArray<string>; out AChanged: Boolean): Boolean;
var
  LEntry: string;
  LKept: TList<string>;
  LFor: Integer;
begin
  ANew     := ACurrent;
  AChanged := False;
  LEntry   := Trim(AUnitToRemove);
  if LEntry = '' then
    Exit(False);

  LKept := TList<string>.Create;
  try
    for LFor := 0 to High(ACurrent) do
      if SameText(ACurrent[LFor], LEntry) then
        AChanged := True
      else
        LKept.Add(ACurrent[LFor]);
    ANew := LKept.ToArray;
  finally
    LKept.Free;
  end;
  Result := True;
end;

class function TFormUsesWritePolicy.BuildUsesClauseBody(const AEntries: TArray<string>): string;
var
  LFor: Integer;
begin
  if Length(AEntries) = 0 then
    Exit(' ');
  Result := '';
  for LFor := 0 to High(AEntries) do
  begin
    Result := Result + sLineBreak + '  ' + AEntries[LFor];
    if LFor < High(AEntries) then
      Result := Result + ',';
  end;
end;

class function TFormUsesWritePolicy.ClassifyIDEAction(const AActionName: string;
  out AReason: string): Boolean;
var
  LName, LLower: string;
  LFor: Integer;
begin
  AReason := '';
  LName := Trim(AActionName);
  if LName = '' then
  begin
    AReason := 'empty-action';
    Exit(False);
  end;

  LLower := LowerCase(LName);

  for LFor := Low(CHardBlockTokens) to High(CHardBlockTokens) do
    if Pos(CHardBlockTokens[LFor], LLower) > 0 then
    begin
      AReason := 'destructive-action-refused';
      Exit(False);
    end;

  for LFor := Low(CSoftBlockTokens) to High(CSoftBlockTokens) do
    if Pos(CSoftBlockTokens[LFor], LLower) > 0 then
    begin
      AReason := 'destructive-action-soft-blocked';
      Exit(False);
    end;

  Result := True;
end;

end.
