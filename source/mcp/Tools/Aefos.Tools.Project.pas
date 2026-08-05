unit Aefos.Tools.Project;

(*
  Aefos.Tools.Project — project/tree-wide orchestrations.

  Thin, single-call seams that compose the lower layers (Batch / Templates /
  Files) into the exact operations the agent asks for at the project level —
  and that the OTA tool layer has no equivalent for:

    - TProjectOps.ReplaceText  : find & replace across a glob of files on disk
                            (OTA only has FindInProject, which is read-only).
    - TProjectOps.ConvertBom   : mass BOM/encoding fix over a glob (kills the
                            UTF-8-without-BOM mojibake trap — feedback-delphi-utf8-bom).
    - TProjectOps.ScaffoldFile : render a `{{...}}` template and write it to disk,
                            refusing to clobber an existing file (OTA has no
                            template library at all).

  These exist so the project-wide SEMANTICS (what counts as a match, idempotency,
  clobber refusal, error mapping) are locked and unit-tested in pure code. The
  future MCP tool handlers (ReplaceInProject / FixEncoding / ScaffoldUnit) wrap
  these 1:1 — engine=here, apply=there.

  Boundary: RTL + the pure Tools.* layers. No ToolsAPI, no Vcl./FMX.

  Naming convention: MCP\Source\Tools\NAMING.md (domain `Project`).
*)

interface

uses
  Aefos.Tools.Files,
  Aefos.Tools.Batch,
  Aefos.Tools.Templates;

type
  // Outcome of a scaffold (render -> write). FileOutcome is meaningful only when
  // TemplateOutcome = tplApplied; DestExists wins over both when the write was
  // refused to avoid clobbering an existing file.
  TToolScaffoldResult = record
    TemplateOutcome: TToolTemplateOutcome;
    FileOutcome: TToolFileOutcome;
    DestExists: Boolean;        // True when refused: ADestPath already existed
    DestPath: string;
    Unresolved: TArray<string>; // placeholder keys left without a value
    function Ok: Boolean;
    function OutcomeText: string;
  end;

  // Outcome of materialising a whole template FOLDER into a target directory
  // (render every file's name + content). Unresolved aggregates the missing
  // placeholder keys across all files; when non-empty NOTHING is written (a
  // half-materialised project is worse than none). MainFile is the relative
  // path of the .groupproj/.dproj/.dpr to open, '' when the template has none.
  TToolScaffoldFolderResult = record
    TemplateMissing: Boolean;   // template dir absent or empty
    DestExists: Boolean;        // refused: target dir already had content
    FilesWritten: Integer;
    FilesFailed: Integer;
    Written: TArray<string>;    // relative paths written (rendered names)
    Unresolved: TArray<string>; // placeholder keys left without a value
    MainFile: string;
    function Ok: Boolean;
    function OutcomeText: string;
  end;

  // Project/tree-wide orchestrations as a sealed static namespace (see the unit
  // header). Never instantiated.
  TProjectOps = class sealed
  public
    // ── Project-wide disk ops (glob + batch) ─────────────────────────────────

    // Replaces every occurrence of AFind with AReplace across every file under
    // ARoot matching AMask (e.g. '*.pas'). Files with no match are left untouched.
    class function ReplaceText(const ARoot, AMask: string;
      const ARecursive: Boolean; const AFind, AReplace: string;
      const ACaseSensitive: Boolean): TToolBatchResult; static;

    // Re-saves every file under ARoot matching AMask with ATargetBom, content
    // unchanged. Files already at ATargetBom are skipped (idempotent).
    class function ConvertBom(const ARoot, AMask: string;
      const ARecursive: Boolean; const ATargetBom: TToolFileBom): TToolBatchResult; static;

    // ── Scaffold (template -> disk) ──────────────────────────────────────────

    // Renders template ATemplateId from ATemplatesRoot with AVars and writes the
    // result to ADestPath with ABom. Refuses to overwrite an existing file unless
    // AAllowOverwrite. The directory is created when missing (via TFileIO.Save).
    class function ScaffoldFile(const ATemplatesRoot, ATemplateId: string;
      const AVars: TArray<TToolTemplateVar>; const ADestPath: string;
      const ABom: TToolFileBom;
      const AAllowOverwrite: Boolean): TToolScaffoldResult; static;

    // Materialises an entire template FOLDER (ATemplateDir) into ATargetDir: every
    // file's relative PATH and CONTENT is rendered with AVars ({{Key}}), so a file
    // named `{{Name}}.dpr` becomes `MyApp.dpr`. The manifest `template.json` at the
    // root is skipped. Known binary assets (.res/.ico/.png/...) are copied byte for
    // byte (only their name is rendered). Refuses to write into a non-empty
    // ATargetDir unless AAllowOverwrite. If any placeholder is unresolved NOTHING is
    // written (Unresolved lists them).
    class function ScaffoldFolder(const ATemplateDir, ATargetDir: string;
      const AVars: TArray<TToolTemplateVar>; const ABom: TToolFileBom;
      const AAllowOverwrite: Boolean): TToolScaffoldFolderResult; static;
  end;

implementation

uses
  System.SysUtils,
  System.IOUtils,
  System.Generics.Collections;

{ TToolScaffoldResult }

function TToolScaffoldResult.Ok: Boolean;
begin
  Result := (not DestExists) and (TemplateOutcome = tplApplied)
    and (FileOutcome = tfApplied);
end;

function TToolScaffoldResult.OutcomeText: string;
var
  LTemplate: TToolTemplateResult;
  LFile: TToolFileResult;
begin
  if TemplateOutcome <> tplApplied then
  begin
    LTemplate.Outcome := TemplateOutcome;
    Exit('template-' + LTemplate.OutcomeText);
  end;
  if DestExists then
    Exit('dest-exists');
  if FileOutcome <> tfApplied then
  begin
    LFile.Outcome := FileOutcome;
    Exit('file-' + LFile.OutcomeText);
  end;
  Result := 'applied';
end;

// ── Project-wide disk ops ────────────────────────────────────────────────

class function TProjectOps.ReplaceText(const ARoot, AMask: string;
  const ARecursive: Boolean; const AFind, AReplace: string;
  const ACaseSensitive: Boolean): TToolBatchResult;
begin
  Result := TFileBatch.ReplaceAll(TFileBatch.ListFiles(ARoot, AMask, ARecursive),
    AFind, AReplace, ACaseSensitive);
end;

class function TProjectOps.ConvertBom(const ARoot, AMask: string;
  const ARecursive: Boolean; const ATargetBom: TToolFileBom): TToolBatchResult;
begin
  Result := TFileBatch.ConvertBom(TFileBatch.ListFiles(ARoot, AMask, ARecursive),
    ATargetBom);
end;

// ── Scaffold ─────────────────────────────────────────────────────────────

class function TProjectOps.ScaffoldFile(const ATemplatesRoot, ATemplateId: string;
  const AVars: TArray<TToolTemplateVar>; const ADestPath: string;
  const ABom: TToolFileBom;
  const AAllowOverwrite: Boolean): TToolScaffoldResult;
var
  LRender: TToolTemplateResult;
begin
  Result := Default(TToolScaffoldResult);
  Result.DestPath := ADestPath;
  LRender := TTemplateEngine.RenderFile(ATemplatesRoot, ATemplateId, AVars);
  Result.TemplateOutcome := LRender.Outcome;
  Result.Unresolved := LRender.Unresolved;
  if not LRender.Ok then
    Exit;
  if (not AAllowOverwrite) and TFile.Exists(ADestPath) then
  begin
    Result.DestExists := True;
    Exit;
  end;
  Result.FileOutcome := TFileIO.Save(ADestPath, LRender.Content, ABom);
end;

{ TToolScaffoldFolderResult }

function TToolScaffoldFolderResult.Ok: Boolean;
begin
  Result := (not TemplateMissing) and (not DestExists)
    and (Length(Unresolved) = 0) and (FilesFailed = 0) and (FilesWritten > 0);
end;

function TToolScaffoldFolderResult.OutcomeText: string;
begin
  if TemplateMissing then
    Exit('template-missing');
  if DestExists then
    Exit('dest-exists');
  if Length(Unresolved) > 0 then
    Exit('missing-vars');
  if FilesFailed > 0 then
    Exit('partial-write');
  if FilesWritten = 0 then
    Exit('empty');
  Result := 'applied';
end;

type
  TScaffoldPlanItem = record
    DestRel: string;
    Content: string;
    Src: string;
    IsBinary: Boolean;
  end;

// Known binary assets are copied byte for byte (rendering them as text would
// corrupt them); only their file name is rendered.
function _IsBinaryAsset(const APath: string): Boolean;
const
  BIN: array[0..10] of string = ('.res', '.ico', '.bmp', '.png', '.gif',
    '.jpg', '.jpeg', '.dcu', '.exe', '.dll', '.bpl');
var
  LExt: string;
  LIndex: Integer;
begin
  LExt := LowerCase(ExtractFileExt(APath));
  for LIndex := Low(BIN) to High(BIN) do
    if LExt = BIN[LIndex] then
      Exit(True);
  Result := False;
end;

// The project/group file to open after materialising: .groupproj > .dproj > .dpr/.dpk.
function _PickMainFile(const ARelPaths: TArray<string>): string;
var
  LRel, LExt, LBest: string;
  LBestRank, LRank: Integer;
begin
  LBest := '';
  LBestRank := 0;
  for LRel in ARelPaths do
  begin
    LExt := LowerCase(ExtractFileExt(LRel));
    LRank := 0;
    if LExt = '.groupproj' then
      LRank := 3
    else if LExt = '.dproj' then
      LRank := 2
    else if (LExt = '.dpr') or (LExt = '.dpk') then
      LRank := 1;
    if LRank > LBestRank then
    begin
      LBestRank := LRank;
      LBest := LRel;
    end;
  end;
  Result := LBest;
end;

class function TProjectOps.ScaffoldFolder(const ATemplateDir, ATargetDir: string;
  const AVars: TArray<TToolTemplateVar>; const ABom: TToolFileBom;
  const AAllowOverwrite: Boolean): TToolScaffoldFolderResult;
var
  LFiles: TArray<string>;
  LSrc, LRel, LU, LDest, LDir: string;
  LNameR, LBodyR: TToolTemplateResult;
  LInfo: TToolFileInfo;
  LPlans: TList<TScaffoldPlanItem>;
  LPlan: TScaffoldPlanItem;
  LUnresolved, LWritten: TList<string>;
  LVars: TArray<TToolTemplateVar>;
  LVar: TToolTemplateVar;
  LHasGuid: Boolean;
begin
  Result := Default(TToolScaffoldFolderResult);
  // Auto-provide a fresh {{Guid}} (used for the .dproj <ProjectGuid>) unless the
  // caller already supplied one — so two projects materialised from the SAME
  // template never share a GUID (the IDE pops a "Duplicate GUID" dialog otherwise).
  // Format {XXXXXXXX-....}, uppercase, exactly what a .dproj ProjectGuid expects.
  LVars := AVars;
  LHasGuid := False;
  for LVar in LVars do
    if SameText(LVar.Key, 'Guid') then
    begin
      LHasGuid := True;
      Break;
    end;
  if not LHasGuid then
    LVars := LVars + [TToolTemplateVar.Make('Guid', TGUID.NewGuid.ToString)];
  if not TDirectory.Exists(ATemplateDir) then
  begin
    Result.TemplateMissing := True;
    Exit;
  end;
  LFiles := TDirectory.GetFiles(ATemplateDir, '*',
    TSearchOption.soAllDirectories);
  if Length(LFiles) = 0 then
  begin
    Result.TemplateMissing := True;
    Exit;
  end;
  if (not AAllowOverwrite) and TDirectory.Exists(ATargetDir)
    and (Length(TDirectory.GetFileSystemEntries(ATargetDir)) > 0) then
  begin
    Result.DestExists := True;
    Exit;
  end;

  LPlans := TList<TScaffoldPlanItem>.Create;
  LUnresolved := TList<string>.Create;
  LWritten := TList<string>.Create;
  try
    // Pass 1 — render names + contents, gather unresolved. Write nothing yet.
    for LSrc in LFiles do
    begin
      LRel := LSrc.Substring(Length(ATemplateDir)).TrimLeft([PathDelim]);
      if SameText(LRel, 'template.json') then
        Continue;
      LNameR := TTemplateEngine.Render(LRel, LVars);
      for LU in LNameR.Unresolved do
        if LUnresolved.IndexOf(LU) < 0 then
          LUnresolved.Add(LU);

      LPlan := Default(TScaffoldPlanItem);
      LPlan.DestRel := LNameR.Content;
      if _IsBinaryAsset(LRel) or (TFileIO.Load(LSrc, LInfo) <> tfApplied) then
      begin
        LPlan.IsBinary := True;
        LPlan.Src := LSrc;
      end
      else
      begin
        LBodyR := TTemplateEngine.Render(LInfo.Content, LVars);
        for LU in LBodyR.Unresolved do
          if LUnresolved.IndexOf(LU) < 0 then
            LUnresolved.Add(LU);
        LPlan.Content := LBodyR.Content;
      end;
      LPlans.Add(LPlan);
    end;

    // A missing var would bake `{{Key}}` into the project — refuse wholesale.
    if LUnresolved.Count > 0 then
    begin
      Result.Unresolved := LUnresolved.ToArray;
      Exit;
    end;

    // Pass 2 — write everything.
    for LPlan in LPlans do
    begin
      LDest := TPath.Combine(ATargetDir, LPlan.DestRel);
      if LPlan.IsBinary then
      begin
        LDir := ExtractFileDir(LDest);
        if (LDir <> '') and (not TDirectory.Exists(LDir)) then
          TDirectory.CreateDirectory(LDir);
        try
          TFile.Copy(LPlan.Src, LDest, AAllowOverwrite);
          LWritten.Add(LPlan.DestRel);
          Inc(Result.FilesWritten);
        except
          Inc(Result.FilesFailed);
        end;
      end
      else if TFileIO.Save(LDest, LPlan.Content, ABom) = tfApplied then
      begin
        LWritten.Add(LPlan.DestRel);
        Inc(Result.FilesWritten);
      end
      else
        Inc(Result.FilesFailed);
    end;

    Result.Written := LWritten.ToArray;
    Result.MainFile := _PickMainFile(Result.Written);
  finally
    LWritten.Free;
    LUnresolved.Free;
    LPlans.Free;
  end;
end;

end.
