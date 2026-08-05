unit Aefos.Tools.Batch;

(*
  Aefos.Tools.Batch — multi-file operations over the disk layer.

  The biggest token saver: the agent names a fileset (or a glob) and ONE
  operation, and the tool fans it out — instead of editing each file in a
  separate round-trip. E.g. "add a UTF-8 BOM to every .pas under Source", or
  "replace FooOld with FooNew across the project".

  Each batch reports per-file outcomes and only rewrites files that actually
  changed (a no-match file is left untouched, not re-saved). BOM and EOL are
  preserved per file via the Files layer.

  Boundary: RTL + the pure Tools.Text / Tools.Files layers. No ToolsAPI/VCL.

  Naming convention: MCP\Source\Tools\NAMING.md.
*)

interface

uses
  System.SysUtils,
  Aefos.Tools.Text,
  Aefos.Tools.Files;

type
  TToolBatchItem = record
    Path: string;
    Outcome: TToolFileOutcome; // tfApplied even when Changed is False
    Changed: Boolean;          // True only when the file was rewritten
    NewHash: string;
  end;

  TToolBatchResult = record
    Total: Integer;            // files visited
    Changed: Integer;          // files actually rewritten
    Failed: Integer;           // files whose op did not apply
    Items: TArray<TToolBatchItem>;
  end;

  // Multi-file operations over the disk layer as a sealed static namespace
  // (see the unit header). Never instantiated.
  TFileBatch = class sealed
  public
    // Enumerates files under ARoot matching AMask (e.g. '*.pas'). Empty when the
    // directory does not exist.
    class function ListFiles(const ARoot, AMask: string;
      const ARecursive: Boolean): TArray<string>; static;

    // Applies AEdit to every path. Files whose content is unchanged by the edit
    // are left on disk untouched (Changed = False).
    class function Apply(const APaths: TArray<string>;
      const AEdit: TToolTextEdit): TToolBatchResult; static;

    // Replaces every occurrence of AFind with AReplace across all paths.
    class function ReplaceAll(const APaths: TArray<string>;
      const AFind, AReplace: string;
      const ACaseSensitive: Boolean): TToolBatchResult; static;

    // Re-saves every path with ATargetBom (content untouched). Files already at
    // ATargetBom are skipped (Changed = False) — the op is idempotent.
    class function ConvertBom(const APaths: TArray<string>;
      const ATargetBom: TToolFileBom): TToolBatchResult; static;
  end;

implementation

uses
  System.IOUtils;

class function TFileBatch.ListFiles(const ARoot, AMask: string;
  const ARecursive: Boolean): TArray<string>;
var
  LOption: TSearchOption;
begin
  SetLength(Result, 0);
  if not TDirectory.Exists(ARoot) then
    Exit;
  if ARecursive then
    LOption := TSearchOption.soAllDirectories
  else
    LOption := TSearchOption.soTopDirectoryOnly;
  Result := TDirectory.GetFiles(ARoot, AMask, LOption);
end;

// Tallies an item into a result accumulator.
procedure _Tally(var AResult: TToolBatchResult; const AItem: TToolBatchItem);
begin
  AResult.Items[AResult.Total] := AItem;
  Inc(AResult.Total);
  if not (AItem.Outcome = tfApplied) then
    Inc(AResult.Failed)
  else if AItem.Changed then
    Inc(AResult.Changed);
end;

class function TFileBatch.Apply(const APaths: TArray<string>;
  const AEdit: TToolTextEdit): TToolBatchResult;
var
  LFor: Integer;
  LInfo: TToolFileInfo;
  LLoad, LSave: TToolFileOutcome;
  LEdit: TToolTextResult;
  LItem: TToolBatchItem;
begin
  Result := Default(TToolBatchResult);
  SetLength(Result.Items, Length(APaths));
  for LFor := 0 to High(APaths) do
  begin
    LItem := Default(TToolBatchItem);
    LItem.Path := APaths[LFor];
    LLoad := TFileIO.Load(APaths[LFor], LInfo);
    if LLoad <> tfApplied then
    begin
      LItem.Outcome := LLoad;
      _Tally(Result, LItem);
      Continue;
    end;
    LEdit := AEdit(LInfo.Content);
    if not LEdit.Ok then
    begin
      LItem.Outcome := tfTextError;
      _Tally(Result, LItem);
      Continue;
    end;
    if LEdit.Content = LInfo.Content then
    begin
      LItem.Outcome := tfApplied;
      LItem.Changed := False;
      LItem.NewHash := LInfo.Hash;
      _Tally(Result, LItem);
      Continue;
    end;
    LSave := TFileIO.Save(APaths[LFor], LEdit.Content, LInfo.Bom);
    if LSave <> tfApplied then
    begin
      LItem.Outcome := LSave;
      _Tally(Result, LItem);
      Continue;
    end;
    LItem.Outcome := tfApplied;
    LItem.Changed := True;
    LItem.NewHash := TFileIO.HashContent(LEdit.Content);
    _Tally(Result, LItem);
  end;
end;

class function TFileBatch.ReplaceAll(const APaths: TArray<string>;
  const AFind, AReplace: string;
  const ACaseSensitive: Boolean): TToolBatchResult;
begin
  Result := TFileBatch.Apply(APaths,
    function(const AContent: string): TToolTextResult
    begin
      Result := TTextEditor.ReplaceAll(AContent, AFind, AReplace, ACaseSensitive);
    end);
end;

class function TFileBatch.ConvertBom(const APaths: TArray<string>;
  const ATargetBom: TToolFileBom): TToolBatchResult;
var
  LFor: Integer;
  LInfo: TToolFileInfo;
  LLoad, LSave: TToolFileOutcome;
  LItem: TToolBatchItem;
begin
  Result := Default(TToolBatchResult);
  SetLength(Result.Items, Length(APaths));
  for LFor := 0 to High(APaths) do
  begin
    LItem := Default(TToolBatchItem);
    LItem.Path := APaths[LFor];
    LLoad := TFileIO.Load(APaths[LFor], LInfo);
    if LLoad <> tfApplied then
    begin
      LItem.Outcome := LLoad;
      _Tally(Result, LItem);
      Continue;
    end;
    LItem.NewHash := LInfo.Hash;
    if LInfo.Bom = ATargetBom then
    begin
      LItem.Outcome := tfApplied;
      LItem.Changed := False;
      _Tally(Result, LItem);
      Continue;
    end;
    LSave := TFileIO.Save(APaths[LFor], LInfo.Content, ATargetBom);
    if LSave <> tfApplied then
    begin
      LItem.Outcome := LSave;
      _Tally(Result, LItem);
      Continue;
    end;
    LItem.Outcome := tfApplied;
    LItem.Changed := True;
    _Tally(Result, LItem);
  end;
end;

end.
