unit Aefos.MCP.OTA.RecentFilesPolicy;

{
  Pure recent-files ordering/normalization seam (ESP-094, S1 / ADR-094-02 / BR3).

  Pure RTL — no ToolsAPI, no registry, no file IO. Shapes the raw IDE "Reopen"
  history entries (read impurely by the facade) into the ordered, deduped
  file-MRU list returned by GetRecentFiles. The facade owns the impure read at
  its boundary and pipes the raw entries through this seam.

  S0 (live BDS 37.0) pinned the read source: the File ▸ Reopen file history is
  persisted under the IDE registry hive as a "Closed Files" key whose values are
  named File_0, File_1, … (File_0 = most recent, suffix ascending = MRU order).
  Recent *projects* live in a separate "Closed Projects" key and are out of scope
  (GetRecentFiles is the file MRU only). The architect's assumed single "Reopen"
  key with File<N>/Project<N> value-name discrimination did not match the live
  hive (ADR-094-03 / R2 anticipated this drift); the seam stays version-agnostic
  by operating on (valueName, path) pairs only.

  Each "Closed Files" value is a typed CSV, not a bare path:
    TSourceModule,'C:\…\Unit1.pas',0,1,1,1,18,0,0,,
  the path is the second, single-quoted field. ExtractReopenPath parses that
  field (S0-forced; ADR-094-02 keeps OrderReopenEntries on already-extracted
  (valueName, path) pairs). NormalizeRecentFiles is idempotent on an already-clean
  list (ADR-094-02 / R4: faithful to the menu — no FileExists stat-and-drop).
}

interface

uses
  System.Generics.Collections;

type
  // Pure recent-files ordering/normalization seam as a sealed static namespace
  // (see the unit header for the ESP-094 / ADR-094 contract). Never instantiated.
  TRecentFilesPolicy = class sealed
  public
    // Extract the file path from one RAD Studio "Closed Files" registry value.
    // The live value format is `TSourceModule,'<path>',<flags…>`; the path is the
    // second, single-quoted field, with embedded quotes doubled (Pascal-style).
    // Returns '' when the value carries no quoted path. Pure.
    class function ExtractReopenPath(const AValue: string): string; static;

    // Order raw (valueName, path) Reopen entries into a most-recent-first path list.
    // Selects File<N>/File_<N> value names only (numeric suffix ascending, 0 = most
    // recent); Project<N> and any non-File name are skipped. The path in each pair is
    // returned verbatim (cleanup is NormalizeRecentFiles' job). Pure.
    class function OrderReopenEntries(const AEntries: TArray<TPair<string, string>>): TArray<string>; static;

    // Normalize a most-recent-first path list: trim, drop blanks, case-insensitive
    // dedupe keeping the first (most-recent) occurrence, preserve order, cap at ACap
    // (ACap <= 0 = no cap). Idempotent on an already-clean list. Pure.
    class function NormalizeRecentFiles(const APaths: TArray<string>; ACap: Integer): TArray<string>; static;
  end;

implementation

uses
  System.SysUtils,
  System.StrUtils,
  System.Generics.Defaults;

class function TRecentFilesPolicy.ExtractReopenPath(const AValue: string): string;
var
  LIdx, LLen, LFirst: Integer;
  LBuilder: TStringBuilder;
begin
  Result := '';
  LFirst := Pos('''', AValue);
  if LFirst = 0 then
    Exit;
  LLen := Length(AValue);
  LIdx := LFirst + 1;
  LBuilder := TStringBuilder.Create;
  try
    while LIdx <= LLen do
    begin
      if AValue[LIdx] <> '''' then
      begin
        LBuilder.Append(AValue[LIdx]);
        Inc(LIdx);
      end
      else if (LIdx < LLen) and (AValue[LIdx + 1] = '''') then
      begin
        // Doubled quote = one literal quote inside the path.
        LBuilder.Append('''');
        Inc(LIdx, 2);
      end
      else
        Break; // closing quote of the path field
    end;
    Result := LBuilder.ToString;
  finally
    LBuilder.Free;
  end;
end;

// Numeric MRU index of a File<N>/File_<N> value name. False (and skip) for
// Project<N> and any name without a "File" prefix + trailing digit run.
function _ReopenIndex(const AValueName: string; out AIndex: Integer): Boolean;
var
  LLen, LStart: Integer;
begin
  Result := False;
  AIndex := 0;
  if not StartsText('File', AValueName) then
    Exit;
  LLen := Length(AValueName);
  LStart := LLen;
  while (LStart >= 1) and CharInSet(AValueName[LStart], ['0'..'9']) do
    Dec(LStart);
  if LStart = LLen then
    Exit; // "File" prefix but no numeric suffix
  AIndex := StrToInt(Copy(AValueName, LStart + 1, LLen - LStart));
  Result := True;
end;

class function TRecentFilesPolicy.OrderReopenEntries(const AEntries: TArray<TPair<string, string>>): TArray<string>;
var
  LSelected: TList<TPair<Integer, string>>;
  LEntry: TPair<string, string>;
  LIndex, LI: Integer;
  LResult: TArray<string>;
begin
  LSelected := TList<TPair<Integer, string>>.Create;
  try
    for LEntry in AEntries do
      if _ReopenIndex(LEntry.Key, LIndex) then
        LSelected.Add(TPair<Integer, string>.Create(LIndex, LEntry.Value));
    LSelected.Sort(TComparer<TPair<Integer, string>>.Construct(
      function(const L, R: TPair<Integer, string>): Integer
      begin
        Result := L.Key - R.Key;
      end));
    SetLength(LResult, LSelected.Count);
    for LI := 0 to LSelected.Count - 1 do
      LResult[LI] := LSelected[LI].Value;
  finally
    LSelected.Free;
  end;
  Result := LResult;
end;

class function TRecentFilesPolicy.NormalizeRecentFiles(const APaths: TArray<string>; ACap: Integer): TArray<string>;
var
  LSeen: TDictionary<string, Boolean>;
  LResult: TList<string>;
  LPath, LTrimmed, LKey: string;
begin
  LSeen := TDictionary<string, Boolean>.Create;
  LResult := TList<string>.Create;
  try
    for LPath in APaths do
    begin
      if (ACap > 0) and (LResult.Count >= ACap) then
        Break;
      LTrimmed := Trim(LPath);
      if LTrimmed = '' then
        Continue;
      LKey := LowerCase(LTrimmed);
      if LSeen.ContainsKey(LKey) then
        Continue;
      LSeen.Add(LKey, True);
      LResult.Add(LTrimmed);
    end;
    Result := LResult.ToArray;
  finally
    LResult.Free;
    LSeen.Free;
  end;
end;

end.
