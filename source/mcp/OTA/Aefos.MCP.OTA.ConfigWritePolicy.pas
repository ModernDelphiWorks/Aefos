unit Aefos.MCP.OTA.ConfigWritePolicy;

{
  Pure configuration-write policy seam (ESP-089, S2 / ADR-089-07 / BR10 / R1).

  Pure RTL — no ToolsAPI, no VCL, no disk write. Carries every OTA-free decision
  the 16 configuration / project-options writes must make before the facade
  touches IOTAProjectOptions, IOTAEnvironmentOptions, or IOTAProject:

    - ParseOptionList     — split a `;`-delimited option string (defines, search
                            path, library path) into trimmed, non-empty entries.
    - JoinOptionList      — re-join entries into a `;`-delimited string.
    - AppendRawEntry      — append a single entry to a raw option string IF absent
                            (case-insensitive), PRESERVING the original prefix
                            verbatim (backs AddConditionalDefine / AddToSearchPath
                            and the IDE-global AddToLibraryPath whose original raw
                            value must round-trip byte-identical on revert, BR11).
    - RemoveOptionEntry   — drop every case-insensitive match from a list, re-join
                            (backs RemoveConditionalDefine).
    - NormalizeOptionList — dedupe (case-insensitive, first occurrence wins),
                            order preserved, re-join (backs SetConditionalDefines /
                            SetSearchPath — a clean replace with no drop/dup, R1).
    - ConfineConfigPath   — confine a path-bearing config target (resource file /
                            DCU dir / output dir / search entry) to the project
                            root, refusing an out-of-root target (carried
                            ADR-088-07 / ADR-089-07, reuses ContentWritePolicy).

  The add/remove/set operations never drop or duplicate an existing entry (R1):
  AppendRawEntry keeps the original string intact and only appends; the list ops
  parse → transform → JoinOptionList. Dedup/membership is case-insensitive —
  Delphi `$IFDEF` is case-insensitive and Windows paths are case-insensitive, so
  two entries differing only by case denote the same define/path.

  This mirrors the ESP-073 UnitCreatePolicy / ESP-087 ContentWritePolicy /
  ESP-088 StructuralWritePolicy precedent: a pure, dependency-free seam unit-
  tested headless, with the OTA wiring (TThread.Synchronize + IOTAOptions.Values
  read-modify-write + the IDE-global library-path append/revert) confined to the
  UI facade as the only OTA-bound, structurally-exempt part (covered live, AC7).
}

interface

type
  // Pure configuration-write policy seam as a sealed static namespace
  // (see the unit header for the ESP-089 / ADR-089 contract). Never instantiated.
  TConfigWritePolicy = class sealed
  public
    // Split a `;`-delimited option string into trimmed, non-empty entries.
    class function ParseOptionList(const AValue: string): TArray<string>; static;

    // Join entries into a `;`-delimited string (entries emitted verbatim, in order).
    class function JoinOptionList(const AEntries: array of string): string; static;

    // Append AEntry to ACurrentRaw's list when absent (case-insensitive membership),
    // preserving ACurrentRaw verbatim and appending `;AEntry` (or AEntry alone for a
    // blank/all-separator current value). ANew echoes ACurrentRaw and AChanged is
    // False on a no-op (already present). Result is False only for a blank AEntry
    // (nothing to add); True otherwise. The verbatim-prefix guarantee lets the
    // IDE-global library path round-trip byte-identical on revert (BR11).
    class function AppendRawEntry(const ACurrentRaw, AEntry: string;
      out ANew: string; out AChanged: Boolean): Boolean; static;

    // Remove every case-insensitive match of AEntry from ACurrentRaw's list and
    // re-join. AChanged reflects whether anything was dropped. Result is False only
    // for a blank AEntry (nothing to remove); True otherwise.
    class function RemoveOptionEntry(const ACurrentRaw, AEntry: string;
      out ANew: string; out AChanged: Boolean): Boolean; static;

    // Dedupe AEntries case-insensitively (first occurrence wins), drop blanks,
    // preserve order, and re-join into the replacement option string. Always
    // succeeds (an empty/all-blank input yields an empty string — a valid clear).
    class function NormalizeOptionList(const AEntries: array of string;
      out ANew: string): Boolean; static;

    // Confine a path-bearing configuration target to AProjectRoot, returning the
    // canonical absolute path or a kebab refusal reason. Thin reuse of the shared
    // ContentWritePolicy confinement predicate (ADR-089-07 carried from ADR-088-07).
    class function ConfineConfigPath(const ATargetPath, AProjectRoot: string;
      out AFullPath, AReason: string): Boolean; static;
  end;

implementation

uses
  System.SysUtils,
  System.Generics.Collections,
  Aefos.MCP.OTA.ContentWritePolicy;

class function TConfigWritePolicy.ParseOptionList(const AValue: string): TArray<string>;
var
  LParts: TArray<string>;
  LFor, LWrite: Integer;
  LEntry: string;
begin
  SetLength(Result, 0);
  if AValue = '' then Exit;
  LParts := AValue.Split([';']);
  SetLength(Result, Length(LParts));
  LWrite := 0;
  for LFor := 0 to High(LParts) do
  begin
    LEntry := Trim(LParts[LFor]);
    if LEntry <> '' then
    begin
      Result[LWrite] := LEntry;
      Inc(LWrite);
    end;
  end;
  SetLength(Result, LWrite);
end;

class function TConfigWritePolicy.JoinOptionList(const AEntries: array of string): string;
var
  LFor: Integer;
begin
  Result := '';
  for LFor := Low(AEntries) to High(AEntries) do
  begin
    if Result <> '' then
      Result := Result + ';';
    Result := Result + AEntries[LFor];
  end;
end;

// Case-insensitive membership of AEntry in AList (a parsed option list).
function _Contains(const AList: TArray<string>; const AEntry: string): Boolean;
var
  LFor: Integer;
begin
  Result := False;
  for LFor := 0 to High(AList) do
    if SameText(AList[LFor], AEntry) then
      Exit(True);
end;

class function TConfigWritePolicy.AppendRawEntry(const ACurrentRaw, AEntry: string;
  out ANew: string; out AChanged: Boolean): Boolean;
var
  LEntry, LTrimmedRaw: string;
begin
  ANew     := ACurrentRaw;
  AChanged := False;
  LEntry   := Trim(AEntry);
  if LEntry = '' then
    Exit(False);

  if _Contains(TConfigWritePolicy.ParseOptionList(ACurrentRaw), LEntry) then
    Exit(True); // already present — valid no-op, original preserved

  // Preserve ACurrentRaw verbatim; only append. A raw made entirely of blanks /
  // separators carries no entries, so the new value is the entry alone.
  LTrimmedRaw := Trim(ACurrentRaw);
  if (LTrimmedRaw = '') or (LTrimmedRaw = ';') then
    ANew := LEntry
  else if ACurrentRaw.EndsWith(';') then
    ANew := ACurrentRaw + LEntry
  else
    ANew := ACurrentRaw + ';' + LEntry;

  AChanged := True;
  Result   := True;
end;

class function TConfigWritePolicy.RemoveOptionEntry(const ACurrentRaw, AEntry: string;
  out ANew: string; out AChanged: Boolean): Boolean;
var
  LEntry: string;
  LKept: TList<string>;
  LParsed: TArray<string>;
  LFor: Integer;
begin
  ANew     := ACurrentRaw;
  AChanged := False;
  LEntry   := Trim(AEntry);
  if LEntry = '' then
    Exit(False);

  LParsed := TConfigWritePolicy.ParseOptionList(ACurrentRaw);
  LKept := TList<string>.Create;
  try
    for LFor := 0 to High(LParsed) do
      if SameText(LParsed[LFor], LEntry) then
        AChanged := True
      else
        LKept.Add(LParsed[LFor]);
    ANew := TConfigWritePolicy.JoinOptionList(LKept.ToArray);
  finally
    LKept.Free;
  end;
  Result := True;
end;

class function TConfigWritePolicy.NormalizeOptionList(const AEntries: array of string;
  out ANew: string): Boolean;
var
  LKept: TList<string>;
  LFor: Integer;
  LEntry: string;
begin
  LKept := TList<string>.Create;
  try
    for LFor := Low(AEntries) to High(AEntries) do
    begin
      LEntry := Trim(AEntries[LFor]);
      if (LEntry <> '') and not _Contains(LKept.ToArray, LEntry) then
        LKept.Add(LEntry);
    end;
    ANew := TConfigWritePolicy.JoinOptionList(LKept.ToArray);
  finally
    LKept.Free;
  end;
  Result := True;
end;

class function TConfigWritePolicy.ConfineConfigPath(const ATargetPath, AProjectRoot: string;
  out AFullPath, AReason: string): Boolean;
var
  LConfined: TConfinedWrite;
begin
  // Callers must pass a distinct temp for AFullPath (an `out` string is reset to
  // '' at the call site, which would erase an aliased ATargetPath input).
  LConfined := TContentWritePolicy.ConfineWritePath(ATargetPath, AProjectRoot);
  AFullPath := '';
  AReason   := '';
  Result := LConfined.Accepted;
  if Result then
    AFullPath := LConfined.FullPath
  else
    AReason := LConfined.Reason;
end;

end.
