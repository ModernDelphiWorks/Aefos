unit Aefos.OTA.Chat.Core.CommandRegistry;

{
  Command registry implementation (ESP-007, demand 3/5; extended by ESP-002,
  Epic 5/7 demand 2/6).

  Lists, loads, and validates command files under
  `<active-project>\.aefos\commands\<name>\COMMAND.md`. The chat ships NO
  pre-installed commands (decision 2026-06-09); the user authors their own.

  ESP-002 adds the full-model read path: `LoadCommand` returns a
  `TCanonicalCommand` (instructions = `COMMAND.md` body, references
  auto-discovered from the optional `references/` subfolder) and
  `LoadReference` returns a single reference slice body. The full model is
  purely additive — `TCommandMetadata`, `List`, `Get`, `LoadBody` are
  unchanged (ADR-089).

  Architectural baseline:
    - ADR-008: project-scoped canonical folder.
    - ADR-009: hand-rolled minimal-YAML frontmatter parser. Supports:
        * `key: value` pairs (string scalars).
        * `tags` as a comma-separated list (post-split, post-trim).
        * Required fields: `name`, `description`.
        * Optional fields: `tags`, `version`. Unknown fields tolerated.
      Does NOT support: anchors, flow sequences, nested mappings,
      quoted strings with escapes, multi-line scalars.
    - ADR-010 (revised 2026-06-09): no pre-installed commands ship.
      `EnsurePreinstalled` is retained on the ICommandRegistry contract as a
      no-op so the interface and the executor's lazy call stay stable.
    - ADR-011: no cache. Each public call re-reads disk.
    - ADR-090: a command's references are the `*.md` files directly inside an
      optional `references/` subfolder; `LoadCommand` enumerates that folder
      non-recursively. No frontmatter reference index.

  Threading: synchronous file I/O on the calling thread. No background
  work. No locks needed (no shared mutable state beyond the resolver).

  Encoding: UTF-8 without BOM for both read and write.
}

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  Aefos.OTA.Chat.Core.CommandRegistry.Types;

type
  TCommandRegistry = class(TInterfacedObject, ICommandRegistry)
  private
    FProjectRootResolver: TFunc<string>;
    FGlobalRootResolver: TFunc<string>;
    function _ResolveProjectRoot: string;
    function _ResolveGlobalRoot: string;
    function _RequireProjectRoot: string;
    function _RequireRootForScope(const AScope: TCommandScope): string;
    function _CommandsDir(const AProjectRoot: string): string;
    function _CommandFile(const AProjectRoot, ACommandName: string): string;
    function _ReferenceFile(const AProjectRoot, ACommandName,
      AReferenceName: string): string;
    function _CommandDir(const AProjectRoot, ACommandName: string): string;
    // Resolves the catalogue root (project first, then global) whose
    // COMMAND.md exists for ACommandName. Project shadows global (BR: project
    // wins). Returns False when the command is in neither catalogue.
    function _FindCommandRoot(const ACommandName: string; out ARoot: string;
      out AScope: TCommandScope): Boolean;
    function _BuildMetadata(const ACommandDir, ACommandFile: string): TCommandMetadata;
    function _DiscoverReferences(
      const ACommandDir: string): TArray<TCommandReference>;
    procedure _CollectFromRoot(const ARoot: string; const AScope: TCommandScope;
      const ACollected: TList<TCommandMetadata>;
      const ASeen: TDictionary<string, Byte>);
    procedure _TryAppendCommand(const ACommandDir: string;
      const AScope: TCommandScope;
      const ACollected: TList<TCommandMetadata>;
      const ASeen: TDictionary<string, Byte>);
  public
    constructor Create(const AProjectRootResolver: TFunc<string>;
      const AGlobalRootResolver: TFunc<string> = nil);
    {
      Returns metadata for every command under
      `<root>\.aefos\commands\` whose `COMMAND.md` parses successfully.
      Returns an empty array when the resolver returns '' or the folder
      does not exist. Malformed entries are silently skipped — defensive
      behavior so one bad file does not break the listing UI.
    }
    function List: TArray<TCommandMetadata>;
    {
      Returns metadata for the named command. Raises:
        - ECommandFolderUnavailable when the resolver returns ''.
        - ECommandNotFound when the command folder or `COMMAND.md` is missing.
        - ECommandMalformed on parse error or when `name:` differs from
          the folder name (BR-1).
    }
    function Get(const ACommandName: string): TCommandMetadata;
    {
      Returns the body of `COMMAND.md` (substring after the closing
      frontmatter delimiter, with one leading newline trimmed if present).
      Same exception contract as Get.
    }
    function LoadBody(const ACommandName: string): string;
    {
      Returns the full canonical model for the named command (ADR-089/090):
        - Name/Description/Instructions parsed from `COMMAND.md` (frontmatter
          stripped for Instructions);
        - References = one TCommandReference per `*.md` file in the optional
          `<name>\references\` subfolder, empty array when absent (AC-07).
      Same exception contract as Get/LoadBody:
        - ECommandFolderUnavailable when the resolver returns ''.
        - ECommandNotFound when the command folder or `COMMAND.md` is missing.
        - ECommandMalformed on parse error (AC-10).
    }
    function LoadCommand(const ACommandName: string): TCanonicalCommand;
    {
      Returns the body of the reference slice
      `<name>\references\<refName>.md`. The `.md` extension is appended when
      absent. Raises:
        - ECommandFolderUnavailable when the resolver returns ''.
        - ECommandNotFound when the reference file is missing (AC-06).
    }
    function LoadReference(const ACommandName,
      AReferenceName: string): string;
    {
      Persists ACommand to `.aefos\commands\<slug>\COMMAND.md` (ADR-092):
        - resolves the folder slug from ACommand.Name (CommandFolderSlug);
        - renders executor-neutral frontmatter (`name`, `description`;
          `tags` / `version` carried through only when the existing file
          already had them) plus body = ACommand.Instructions;
        - writes COMMAND.md atomically (temp file + rename).
      Create-or-overwrite of COMMAND.md only — any `references\` subfolder is
      left untouched (BR-4). Raises:
        - ECommandFolderUnavailable when the resolver returns ''.
        - ECommandMalformed when ACommand.Name is not a valid command name or
          ACommand.Description is empty (no folder is created).
    }
    procedure SaveCommand(const ACommand: TCanonicalCommand); overload;
    procedure SaveCommand(const ACommand: TCanonicalCommand;
      const AScope: TCommandScope); overload;
    {
      Persists the reference slice
      `.aefos\commands\<slug>\references\<refName>.md` (ADR-095):
        - validates AReferenceName with IsValidCommandName before any file
          I/O (BR-3) — an unsafe name never reaches the filesystem;
        - requires the command folder to already contain COMMAND.md (BR-2);
        - ensures the `references\` subfolder exists;
        - writes the slice atomically (UTF-8, no BOM).
      Create-or-overwrite of that one file only — COMMAND.md and any sibling
      reference are left untouched (BR-4). Raises:
        - ECommandMalformed when AReferenceName is not a valid slug (no file
          written);
        - ECommandFolderUnavailable when the resolver returns '';
        - ECommandNotFound when the command has no COMMAND.md.
    }
    procedure SaveReference(const ACommandName, AReferenceName,
      AContent: string);
    {
      Materialises the pre-installed `/init` command into
      `<root>\.aefos\commands\init\COMMAND.md` when missing. No-op when
      the file already exists (BR-5: user edits preserved). Raises
      ECommandFolderUnavailable when the resolver returns ''.
    }
    procedure EnsurePreinstalled;
  end;

{ Maps a command name to its filesystem folder slug — the single name->folder
  rule shared by SaveCommand and LoadCommand's folder resolution (BR-3 / C-8).
  A valid command name has no surrounding whitespace and no non-slug
  characters, so for valid input the slug is the name itself. }
function CommandFolderSlug(const AName: string): string;

{ True when AName is a non-empty, filesystem-safe command name: only the
  characters A-Z a-z 0-9 . _ - , no path separators, not `.` / `..`, not a
  reserved Windows device name. Pure — no VCL, no file I/O (C-9 / AC-07). }
function IsValidCommandName(const AName: string): Boolean;

implementation

uses
  System.Classes,
  System.IOUtils;

const
  COMMAND_FILE_NAME = 'COMMAND.md';
  COMMANDS_FOLDER_REL = '.aefos\commands';
  REFERENCES_FOLDER_NAME = 'references';
  MD_EXTENSION = '.md';
  COMMAND_NAME_MAX_LEN = 64;

type
  TFrontmatterParseResult = record
    Name: string;
    Description: string;
    Version: string;
    Tags: TArray<string>;
    BodyText: string;
  end;

function _SplitTags(const ATagsValue: string): TArray<string>;
var
  LRaw: TArray<string>;
  LBuilder: TList<string>;
  LIndex: Integer;
  LTrimmed: string;
begin
  LRaw := ATagsValue.Split([',']);
  LBuilder := TList<string>.Create;
  try
    for LIndex := 0 to High(LRaw) do
    begin
      LTrimmed := Trim(LRaw[LIndex]);
      if LTrimmed <> '' then
        LBuilder.Add(LTrimmed);
    end;
    Result := LBuilder.ToArray;
  finally
    LBuilder.Free;
  end;
end;

function _NormalizeNewlines(const AInput: string): string;
begin
  Result := StringReplace(AInput, #13#10, #10, [rfReplaceAll]);
  Result := StringReplace(Result, #13, #10, [rfReplaceAll]);
end;

procedure _AssignField(var AResult: TFrontmatterParseResult;
  const AKey, AValue: string);
begin
  if SameText(AKey, 'name') then
    AResult.Name := AValue
  else if SameText(AKey, 'description') then
    AResult.Description := AValue
  else if SameText(AKey, 'version') then
    AResult.Version := AValue
  else if SameText(AKey, 'tags') then
    AResult.Tags := _SplitTags(AValue);
end;

procedure _ParseFrontmatterLine(const ALine: string;
  var AResult: TFrontmatterParseResult);
var
  LColonPos: Integer;
  LKey, LValue: string;
begin
  if Trim(ALine) = '' then
    Exit;
  LColonPos := Pos(':', ALine);
  if LColonPos <= 1 then
    raise ECommandMalformed.CreateFmt(
      'Invalid frontmatter line (no key): "%s"', [ALine]);
  LKey := Trim(Copy(ALine, 1, LColonPos - 1));
  LValue := Trim(Copy(ALine, LColonPos + 1, MaxInt));
  if LKey = '' then
    raise ECommandMalformed.CreateFmt(
      'Invalid frontmatter line (empty key): "%s"', [ALine]);
  _AssignField(AResult, LKey, LValue);
end;

function _FindOpeningDelimiter(const ALines: TArray<string>): Integer;
var
  LIndex: Integer;
  LTrimmed: string;
begin
  for LIndex := 0 to High(ALines) do
  begin
    LTrimmed := Trim(ALines[LIndex]);
    if LTrimmed = '---' then
      Exit(LIndex + 1);
    if LTrimmed <> '' then
      raise ECommandMalformed.Create(
        'Frontmatter must start with --- delimiter on first non-blank line');
  end;
  raise ECommandMalformed.Create('Missing opening --- delimiter');
end;

function _ReadFrontmatterFields(const ALines: TArray<string>;
  const AStartIndex: Integer; out AClosingIndex: Integer): TFrontmatterParseResult;
var
  LIndex: Integer;
begin
  Result := Default(TFrontmatterParseResult);
  LIndex := AStartIndex;
  while LIndex <= High(ALines) do
  begin
    if Trim(ALines[LIndex]) = '---' then
    begin
      AClosingIndex := LIndex;
      Exit;
    end;
    _ParseFrontmatterLine(ALines[LIndex], Result);
    Inc(LIndex);
  end;
  raise ECommandMalformed.Create('Missing closing --- delimiter');
end;

function _ExtractBody(const ALines: TArray<string>;
  const AAfterClosingIndex: Integer): string;
var
  LBuilder: TStringBuilder;
  LIndex: Integer;
begin
  LBuilder := TStringBuilder.Create;
  try
    for LIndex := AAfterClosingIndex to High(ALines) do
    begin
      if LBuilder.Length > 0 then
        LBuilder.Append(#10);
      LBuilder.Append(ALines[LIndex]);
    end;
    Result := LBuilder.ToString;
  finally
    LBuilder.Free;
  end;
  if (Length(Result) > 0) and (Result[Low(Result)] = #10) then
    Delete(Result, Low(Result), 1);
end;

procedure _ValidateRequiredFields(const AResult: TFrontmatterParseResult);
begin
  if AResult.Name = '' then
    raise ECommandMalformed.Create('Required frontmatter field "name" is missing');
  if AResult.Description = '' then
    raise ECommandMalformed.Create(
      'Required frontmatter field "description" is missing');
end;

function _ParseFrontmatter(const AContent: string): TFrontmatterParseResult;
var
  LLines: TArray<string>;
  LFieldsStart: Integer;
  LClosingIndex: Integer;
begin
  LLines := _NormalizeNewlines(AContent).Split([#10]);
  LFieldsStart := _FindOpeningDelimiter(LLines);
  Result := _ReadFrontmatterFields(LLines, LFieldsStart, LClosingIndex);
  _ValidateRequiredFields(Result);
  Result.BodyText := _ExtractBody(LLines, LClosingIndex + 1);
end;

function _ReadAllTextUtf8(const APath: string): string;
var
  LBytes: TBytes;
begin
  LBytes := TFile.ReadAllBytes(APath);
  Result := TEncoding.UTF8.GetString(LBytes);
end;

procedure _WriteAllTextUtf8NoBom(const APath, AContent: string);
var
  LBytes: TBytes;
  LStream: TFileStream;
begin
  LBytes := TEncoding.UTF8.GetBytes(AContent);
  LStream := TFileStream.Create(APath, fmCreate);
  try
    if Length(LBytes) > 0 then
      LStream.WriteBuffer(LBytes[0], Length(LBytes));
  finally
    LStream.Free;
  end;
end;

{ Atomic UTF-8 (no BOM) write: stage to `<path>.tmp` then rename over the
  target — the `palette-state.json` pattern (ADR-092). A partially written
  file is never observed at APath; on a rename failure the temp file is
  cleaned up best-effort and the original exception is re-raised. }
procedure _WriteAllTextUtf8Atomic(const APath, AContent: string);
var
  LTempPath: string;
begin
  LTempPath := APath + '.tmp';
  _WriteAllTextUtf8NoBom(LTempPath, AContent);
  try
    if TFile.Exists(APath) then
      TFile.Delete(APath);
    TFile.Move(LTempPath, APath);
  except
    on E: Exception do
    begin
      try
        if TFile.Exists(LTempPath) then
          TFile.Delete(LTempPath);
      except
        // Best-effort cleanup — never mask the original failure.
      end;
      raise;
    end;
  end;
end;

function CommandFolderSlug(const AName: string): string;
begin
  Result := Trim(AName);
end;

function _IsSlugChar(const AChar: Char): Boolean;
begin
  Result := CharInSet(AChar,
    ['A'..'Z', 'a'..'z', '0'..'9', '.', '_', '-']);
end;

function _IsReservedDeviceName(const AName: string): Boolean;
const
  RESERVED: array[0..21] of string = (
    'CON', 'PRN', 'AUX', 'NUL',
    'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
    'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9');
var
  LIndex: Integer;
begin
  Result := False;
  for LIndex := Low(RESERVED) to High(RESERVED) do
    if SameText(AName, RESERVED[LIndex]) then
      Exit(True);
end;

function IsValidCommandName(const AName: string): Boolean;
var
  LIndex: Integer;
begin
  if (AName = '') or (Length(AName) > COMMAND_NAME_MAX_LEN) then
    Exit(False);
  if (AName = '.') or (AName = '..') then
    Exit(False);
  for LIndex := Low(AName) to High(AName) do
    if not _IsSlugChar(AName[LIndex]) then
      Exit(False);
  Result := not _IsReservedDeviceName(AName);
end;

{ Renders the executor-neutral COMMAND.md for ACommand. When AExistingFile is a
  parseable command file, its `tags` / `version` are carried through (BR-2);
  all other content comes from ACommand. Body = ACommand.Instructions. }
function _RenderCommandMarkdown(const ACommand: TCanonicalCommand;
  const AExistingFile: string): string;
var
  LCarry: TFrontmatterParseResult;
  LBuilder: TStringBuilder;
begin
  LCarry := Default(TFrontmatterParseResult);
  if TFile.Exists(AExistingFile) then
    try
      LCarry := _ParseFrontmatter(_ReadAllTextUtf8(AExistingFile));
    except
      on E: ECommandRegistryError do
        LCarry := Default(TFrontmatterParseResult);
    end;
  LBuilder := TStringBuilder.Create;
  try
    LBuilder.Append('---').Append(#10);
    LBuilder.Append('name: ').Append(CommandFolderSlug(ACommand.Name)).Append(#10);
    LBuilder.Append('description: ').Append(Trim(ACommand.Description)).Append(#10);
    if Length(LCarry.Tags) > 0 then
      LBuilder.Append('tags: ').Append(string.Join(', ', LCarry.Tags)).Append(#10);
    if LCarry.Version <> '' then
      LBuilder.Append('version: ').Append(LCarry.Version).Append(#10);
    LBuilder.Append('---').Append(#10);
    LBuilder.Append(ACommand.Instructions);
    Result := LBuilder.ToString;
  finally
    LBuilder.Free;
  end;
end;

{ TCommandRegistry }

constructor TCommandRegistry.Create(const AProjectRootResolver: TFunc<string>;
  const AGlobalRootResolver: TFunc<string> = nil);
begin
  inherited Create;
  if not Assigned(AProjectRootResolver) then
    raise EArgumentNilException.Create('AProjectRootResolver must be assigned');
  FProjectRootResolver := AProjectRootResolver;
  // Default global root = %USERPROFILE% (its `.aefos\commands\` is the per-user
  // catalogue). Injectable so tests can point it at a temp folder.
  if Assigned(AGlobalRootResolver) then
    FGlobalRootResolver := AGlobalRootResolver
  else
    FGlobalRootResolver :=
      function: string
      begin
        Result := GetEnvironmentVariable('USERPROFILE');
      end;
end;

function TCommandRegistry._ResolveProjectRoot: string;
begin
  Result := FProjectRootResolver();
end;

function TCommandRegistry._ResolveGlobalRoot: string;
begin
  if Assigned(FGlobalRootResolver) then
    Result := FGlobalRootResolver()
  else
    Result := '';
end;

function TCommandRegistry._RequireProjectRoot: string;
begin
  Result := _ResolveProjectRoot;
  if Result = '' then
    raise ECommandFolderUnavailable.Create(
      'No active Delphi project; .aefos\commands folder is unavailable');
end;

function TCommandRegistry._RequireRootForScope(
  const AScope: TCommandScope): string;
begin
  if AScope = csGlobal then
  begin
    Result := _ResolveGlobalRoot;
    if Result = '' then
      raise ECommandFolderUnavailable.Create(
        'The global command catalogue (%USERPROFILE%\.aefos\commands) is unavailable');
  end
  else
    Result := _RequireProjectRoot;
end;

// Project first, then global — a project command shadows a same-named global
// one. Returns the catalogue root + scope whose COMMAND.md exists.
function TCommandRegistry._FindCommandRoot(const ACommandName: string;
  out ARoot: string; out AScope: TCommandScope): Boolean;
var
  LRoot: string;
begin
  LRoot := _ResolveProjectRoot;
  if (LRoot <> '') and TFile.Exists(_CommandFile(LRoot, ACommandName)) then
  begin
    ARoot := LRoot;
    AScope := csProject;
    Exit(True);
  end;
  LRoot := _ResolveGlobalRoot;
  if (LRoot <> '') and TFile.Exists(_CommandFile(LRoot, ACommandName)) then
  begin
    ARoot := LRoot;
    AScope := csGlobal;
    Exit(True);
  end;
  Result := False;
end;

function TCommandRegistry._CommandsDir(const AProjectRoot: string): string;
begin
  Result := TPath.Combine(AProjectRoot, COMMANDS_FOLDER_REL);
end;

function TCommandRegistry._CommandDir(const AProjectRoot,
  ACommandName: string): string;
begin
  // Folder resolution goes through the single slug rule shared with
  // SaveCommand (BR-3 / C-8). For a folder-derived name the slug is identity.
  Result := TPath.Combine(_CommandsDir(AProjectRoot),
    CommandFolderSlug(ACommandName));
end;

function TCommandRegistry._CommandFile(const AProjectRoot,
  ACommandName: string): string;
begin
  Result := TPath.Combine(_CommandDir(AProjectRoot, ACommandName),
    COMMAND_FILE_NAME);
end;

function TCommandRegistry._ReferenceFile(const AProjectRoot, ACommandName,
  AReferenceName: string): string;
var
  LFileName: string;
begin
  LFileName := AReferenceName;
  if not LFileName.EndsWith(MD_EXTENSION, True) then
    LFileName := LFileName + MD_EXTENSION;
  Result := TPath.Combine(_CommandDir(AProjectRoot, ACommandName),
    TPath.Combine(REFERENCES_FOLDER_NAME, LFileName));
end;

function TCommandRegistry._BuildMetadata(const ACommandDir,
  ACommandFile: string): TCommandMetadata;
var
  LContent: string;
  LParsed: TFrontmatterParseResult;
  LFolderName: string;
begin
  LContent := _ReadAllTextUtf8(ACommandFile);
  LParsed := _ParseFrontmatter(LContent);
  LFolderName := TPath.GetFileName(ACommandDir);
  if not SameText(LParsed.Name, LFolderName) then
    raise ECommandMalformed.CreateFmt(
      'Command name "%s" does not match folder name "%s"',
      [LParsed.Name, LFolderName]);
  Result.Name := LParsed.Name;
  Result.Description := LParsed.Description;
  Result.Version := LParsed.Version;
  Result.Tags := LParsed.Tags;
  Result.Path := ACommandFile;
end;

function TCommandRegistry._DiscoverReferences(
  const ACommandDir: string): TArray<TCommandReference>;
var
  LRefDir: string;
  LFiles: TArray<string>;
  LIndex: Integer;
  LRef: TCommandReference;
  LCollected: TList<TCommandReference>;
begin
  LRefDir := TPath.Combine(ACommandDir, REFERENCES_FOLDER_NAME);
  if not TDirectory.Exists(LRefDir) then
    Exit(nil);
  LFiles := TDirectory.GetFiles(LRefDir, '*' + MD_EXTENSION);
  LCollected := TList<TCommandReference>.Create;
  try
    for LIndex := 0 to High(LFiles) do
    begin
      LRef.Name := TPath.GetFileNameWithoutExtension(LFiles[LIndex]);
      LRef.Path := LFiles[LIndex];
      LCollected.Add(LRef);
    end;
    Result := LCollected.ToArray;
  finally
    LCollected.Free;
  end;
end;

procedure TCommandRegistry._TryAppendCommand(const ACommandDir: string;
  const AScope: TCommandScope;
  const ACollected: TList<TCommandMetadata>;
  const ASeen: TDictionary<string, Byte>);
var
  LCommandFile: string;
  LMeta: TCommandMetadata;
  LKey: string;
begin
  LCommandFile := TPath.Combine(ACommandDir, COMMAND_FILE_NAME);
  if not TFile.Exists(LCommandFile) then
    Exit;
  try
    LMeta := _BuildMetadata(ACommandDir, LCommandFile);
  except
    on E: ECommandRegistryError do
      // Defensive: a single malformed command must not break the listing.
      Exit;
  end;
  // Project shadows global: a name already collected (from the project pass)
  // suppresses the global entry of the same name.
  LKey := LowerCase(LMeta.Name);
  if ASeen.ContainsKey(LKey) then
    Exit;
  LMeta.Scope := AScope;
  ASeen.Add(LKey, 0);
  ACollected.Add(LMeta);
end;

procedure TCommandRegistry._CollectFromRoot(const ARoot: string;
  const AScope: TCommandScope;
  const ACollected: TList<TCommandMetadata>;
  const ASeen: TDictionary<string, Byte>);
var
  LCommandsDir: string;
  LDirs: TArray<string>;
  LDirIndex: Integer;
begin
  if ARoot = '' then
    Exit;
  LCommandsDir := _CommandsDir(ARoot);
  if not TDirectory.Exists(LCommandsDir) then
    Exit;
  LDirs := TDirectory.GetDirectories(LCommandsDir);
  for LDirIndex := 0 to High(LDirs) do
    _TryAppendCommand(LDirs[LDirIndex], AScope, ACollected, ASeen);
end;

function TCommandRegistry.List: TArray<TCommandMetadata>;
var
  LCollected: TList<TCommandMetadata>;
  LSeen: TDictionary<string, Byte>;
begin
  LCollected := TList<TCommandMetadata>.Create;
  LSeen := TDictionary<string, Byte>.Create;
  try
    // Project pass first so it wins on name collisions, then the per-user
    // global catalogue fills in commands the project does not override.
    _CollectFromRoot(_ResolveProjectRoot, csProject, LCollected, LSeen);
    _CollectFromRoot(_ResolveGlobalRoot, csGlobal, LCollected, LSeen);
    Result := LCollected.ToArray;
  finally
    LSeen.Free;
    LCollected.Free;
  end;
end;

function TCommandRegistry.Get(const ACommandName: string): TCommandMetadata;
var
  LRoot: string;
  LScope: TCommandScope;
  LCommandFile: string;
  LCommandDir: string;
begin
  if not _FindCommandRoot(ACommandName, LRoot, LScope) then
    raise ECommandNotFound.CreateFmt('Command "%s" not found', [ACommandName]);
  LCommandFile := _CommandFile(LRoot, ACommandName);
  LCommandDir := TPath.GetDirectoryName(LCommandFile);
  Result := _BuildMetadata(LCommandDir, LCommandFile);
  Result.Scope := LScope;
end;

function TCommandRegistry.LoadBody(const ACommandName: string): string;
var
  LRoot: string;
  LScope: TCommandScope;
  LCommandFile: string;
  LContent: string;
  LParsed: TFrontmatterParseResult;
begin
  if not _FindCommandRoot(ACommandName, LRoot, LScope) then
    raise ECommandNotFound.CreateFmt('Command "%s" not found', [ACommandName]);
  LCommandFile := _CommandFile(LRoot, ACommandName);
  LContent := _ReadAllTextUtf8(LCommandFile);
  LParsed := _ParseFrontmatter(LContent);
  Result := LParsed.BodyText;
end;

function TCommandRegistry.LoadCommand(const ACommandName: string): TCanonicalCommand;
var
  LRoot: string;
  LScope: TCommandScope;
  LCommandFile: string;
  LCommandDir: string;
  LParsed: TFrontmatterParseResult;
begin
  if not _FindCommandRoot(ACommandName, LRoot, LScope) then
    raise ECommandNotFound.CreateFmt('Command "%s" not found', [ACommandName]);
  LCommandFile := _CommandFile(LRoot, ACommandName);
  LParsed := _ParseFrontmatter(_ReadAllTextUtf8(LCommandFile));
  LCommandDir := TPath.GetDirectoryName(LCommandFile);
  Result.Name := LParsed.Name;
  Result.Description := LParsed.Description;
  Result.Instructions := LParsed.BodyText;
  Result.References := _DiscoverReferences(LCommandDir);
end;

function TCommandRegistry.LoadReference(const ACommandName,
  AReferenceName: string): string;
var
  LRoot: string;
  LScope: TCommandScope;
  LRefFile: string;
begin
  if not _FindCommandRoot(ACommandName, LRoot, LScope) then
    raise ECommandNotFound.CreateFmt('Command "%s" not found', [ACommandName]);
  LRefFile := _ReferenceFile(LRoot, ACommandName, AReferenceName);
  if not TFile.Exists(LRefFile) then
    raise ECommandNotFound.CreateFmt(
      'Reference "%s" of command "%s" not found at %s',
      [AReferenceName, ACommandName, LRefFile]);
  Result := _ReadAllTextUtf8(LRefFile);
end;

procedure TCommandRegistry.SaveCommand(const ACommand: TCanonicalCommand);
begin
  // Backward-compatible default: the project catalogue (ADR-008).
  SaveCommand(ACommand, csProject);
end;

procedure TCommandRegistry.SaveCommand(const ACommand: TCanonicalCommand;
  const AScope: TCommandScope);
var
  LRoot: string;
  LCommandDir: string;
  LCommandFile: string;
begin
  // Validate before touching the filesystem so an invalid name never
  // creates a folder (AC-07).
  if not IsValidCommandName(ACommand.Name) then
    raise ECommandMalformed.CreateFmt(
      'Invalid command name "%s": not a filesystem-safe slug', [ACommand.Name]);
  if Trim(ACommand.Description) = '' then
    raise ECommandMalformed.Create('Command description is required');
  LRoot := _RequireRootForScope(AScope);
  LCommandDir := _CommandDir(LRoot, ACommand.Name);
  LCommandFile := TPath.Combine(LCommandDir, COMMAND_FILE_NAME);
  // _RenderCommandMarkdown reads LCommandFile (when present) to carry `tags` /
  // `version` through (BR-2); ensure the folder exists for the atomic write.
  TDirectory.CreateDirectory(LCommandDir);
  _WriteAllTextUtf8Atomic(LCommandFile,
    _RenderCommandMarkdown(ACommand, LCommandFile));
end;

procedure TCommandRegistry.SaveReference(const ACommandName, AReferenceName,
  AContent: string);
var
  LRoot: string;
  LScope: TCommandScope;
  LRefFile: string;
begin
  // Validate the reference name before any file I/O (BR-3) so an unsafe
  // name never reaches the filesystem.
  if not IsValidCommandName(AReferenceName) then
    raise ECommandMalformed.CreateFmt(
      'Invalid reference name "%s": not a filesystem-safe slug',
      [AReferenceName]);
  // BR-2: a reference can only be sliced into an already-saved command — and
  // it lands in whichever catalogue (project/global) already holds it.
  if not _FindCommandRoot(ACommandName, LRoot, LScope) then
    raise ECommandNotFound.CreateFmt('Command "%s" not found', [ACommandName]);
  LRefFile := _ReferenceFile(LRoot, ACommandName, AReferenceName);
  // Create-or-overwrite of that one file only (BR-4); ensure references\.
  TDirectory.CreateDirectory(TPath.GetDirectoryName(LRefFile));
  _WriteAllTextUtf8Atomic(LRefFile, AContent);
end;

procedure TCommandRegistry.EnsurePreinstalled;
begin
  // Command-only (decision 2026-06-09): the chat no longer ships preinstalled
  // commands - the init/search built-ins were removed. The user creates their own commands, so
  // there is nothing to materialise. Kept as a no-op so the ICommandRegistry
  // contract and the executor's lazy call stay unaffected.
end;

end.
