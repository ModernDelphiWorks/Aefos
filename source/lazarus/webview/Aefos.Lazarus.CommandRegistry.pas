unit Aefos.Lazarus.CommandRegistry;

{ TAefosLazCommandRegistry -- the user command store for the Lazarus chat.

  The Lazarus twin of the RAD Studio TCommandRegistry
  (source/chat/Core/Aefos.OTA.Chat.Core.CommandRegistry.pas + its .Types unit). A
  user "command" is a named slash-command backed by a prompt template: typing
  /name in the chat expands to that template. This unit lists, loads and saves
  those commands.

  ONE BRAIN (owner rule 2026-07-17): a user may hold a RAD Studio licence AND run
  the Lazarus edition in parallel; commands authored in one IDE MUST appear in the
  other. So this store reads/writes the EXACT SAME on-disk catalogue and format as
  the Delphi registry, byte-compatibly:

    * Layout   : <root>\.aefos\commands\<name>\COMMAND.md (ADR-008).
    * Format   : minimal-YAML frontmatter (name, description required; tags,
                 version optional) + a Markdown body = the prompt instructions
                 (ADR-009).
    * Encoding : UTF-8, NO BOM, LF newlines, atomic write (temp file + rename) --
                 identical to the Delphi registry's _WriteAllTextUtf8Atomic. (Note:
                 this is why the file I/O here is raw byte streams and NOT
                 Aefos.Compat.IO.TFile.WriteAllText, whose UTF-8 write emits a BOM.)
    * Scopes   : csProject = the active project's .aefos\commands (project wins on
                 a name collision); csGlobal = %USERPROFILE%\.aefos\commands, the
                 per-user catalogue available with no project open. Same two roots
                 the Delphi registry uses (TCommandRegistry global default =
                 GetEnvironmentVariable('USERPROFILE')).

  Not a Delphi fork: the Delphi TCommandRegistry cannot be reused directly because
  its constructor takes TFunc<string> resolvers (function references), which FPC
  3.2.2 does not have -- this unit uses `of object` resolvers (the phase-D idiom),
  and re-implements the tiny frontmatter parser/renderer to match the Delphi bytes.
  Divergence is limited to the language seam (closures), NOT the on-disk contract.

  Mode delphi, string = UTF-8 AnsiString (the LCL boundary), like the sibling
  Aefos.Lazarus.MemoryStore: file bytes are UTF-8 and pass through the AnsiString
  buffers untouched (no platform-ANSI round-trip), so a command written here is
  byte-identical to one written by the RAD Studio plugin. No LCL dependency
  (Classes/SysUtils only) so the store is provable headlessly
  headlessly. Command names are restricted to an ASCII slug, so folder
  names are ASCII regardless of the root path's codepage. All literals are ASCII,
  so this file needs no BOM. }

{$mode delphi}
{$H+}

interface

type
  // Which catalogue a command lives in. Mirrors TCommandScope (csProject/csGlobal).
  TAefosLazCommandScope = (lcsProject, lcsGlobal);

  // Lightweight list projection (name/description/scope) -- feeds the "/" picker
  // and the modal's "Edit existing" dropdown. Mirrors TCommandMetadata.
  TAefosLazCommandMeta = record
    Name: string;
    Description: string;
    Scope: TAefosLazCommandScope;
  end;

  // Full command model. Mirrors TCanonicalCommand (Instructions = the COMMAND.md
  // body with frontmatter stripped). Found = whether the load resolved.
  TAefosLazCanonicalCommand = record
    Found: Boolean;
    Name: string;
    Description: string;
    Instructions: string;
    Scope: TAefosLazCommandScope;
  end;

  // Catalogue-root resolver. `of object` (FPC has no closures) -- the controller
  // binds its own methods here (project root from the active IDE project, global
  // root from %USERPROFILE%). Returns '' when unavailable (no active project) ->
  // that scope is skipped on read and rejected on write.
  TAefosLazRootResolver = function: string of object;

  TAefosLazCommandRegistry = class
  private
    FProjectRootResolver: TAefosLazRootResolver;
    FGlobalRootResolver: TAefosLazRootResolver;
    function _ResolveProject: string;
    function _ResolveGlobal: string;
    function _RootForScope(const AScope: TAefosLazCommandScope): string;
    function _CommandsDir(const ARoot: string): string;
    function _CommandDir(const ARoot, AName: string): string;
    function _CommandFile(const ARoot, AName: string): string;
    // Resolves the catalogue root (project first, then global) whose COMMAND.md
    // exists for AName. Project shadows global. False when in neither catalogue.
    function _FindCommandRoot(const AName: string; out ARoot: string;
      out AScope: TAefosLazCommandScope): Boolean;
    function _ReadFileUtf8(const APath: string): string;
    procedure _WriteAtomicNoBom(const APath, AContent: string);
    // Parses a COMMAND.md body. Frontmatter fields land in the out params (tags/
    // version carried through on save); ABody is the prompt. False when the file
    // is malformed (missing delimiters / required fields).
    function _ParseContent(const AContent: string;
      out AName, ADescription, ATags, AVersion, ABody: string): Boolean;
    function _RenderMarkdown(const AName, ADescription, AInstructions,
      ATags, AVersion: string): string;
    procedure _CollectFrom(const ARoot: string;
      const AScope: TAefosLazCommandScope; var AResult: TArray<TAefosLazCommandMeta>);
  public
    // The resolvers may be nil (a scope is then simply unavailable). Mirrors the
    // Delphi constructor's (project resolver, optional global resolver) shape.
    constructor Create(const AProjectRootResolver,
      AGlobalRootResolver: TAefosLazRootResolver);
    // Every parseable command across both catalogues (project shadows global on a
    // name collision). Malformed entries are silently skipped (defensive: one bad
    // file must not break the listing). Mirrors TCommandRegistry.List.
    function List: TArray<TAefosLazCommandMeta>;
    // Full model for AName (project first, then global). Found=False when absent
    // or malformed. Mirrors TCommandRegistry.LoadCommand (minus the exception).
    function LoadCommand(const AName: string;
      out ACommand: TAefosLazCanonicalCommand): Boolean;
    // The prompt body for AName -- what /name expands to at dispatch. Mirrors
    // TCommandRegistry.LoadBody. False (+ '') when the command does not resolve.
    function LoadBody(const AName: string; out ABody: string): Boolean;
    // Create-or-overwrite <scope>\.aefos\commands\<name>\COMMAND.md. Carries an
    // existing file's tags/version through (BR-2). Returns False + AError on an
    // invalid name, empty description, or an unavailable scope root (no project) --
    // no file is written. Mirrors TCommandRegistry.SaveCommand's validation, but
    // reports the failure by result rather than raising (the controller shows the
    // message inline, like the Delphi panel's ECommandRegistryError catch).
    function SaveCommand(const AName, ADescription, AInstructions: string;
      const AScope: TAefosLazCommandScope; out AError: string): Boolean;
    // True when AName is a non-empty, filesystem-safe slug (A-Z a-z 0-9 . _ -),
    // not '.'/'..' nor a reserved device name, <= 64 chars. Mirrors
    // IsValidCommandName. Static so the controller can pre-screen /name without a
    // registry instance.
    class function IsValidCommandName(const AName: string): Boolean; static;
  end;

implementation

uses
  Classes,
  SysUtils;

const
  COMMAND_FILE_NAME   = 'COMMAND.md';
  // Relative to a catalogue root. Backslash: this edition ships Windows-only, and
  // the Delphi twin's COMMANDS_FOLDER_REL is likewise '.aefos\commands'.
  COMMANDS_FOLDER_REL = '.aefos\commands';
  COMMAND_NAME_MAX_LEN = 64;
  LF = #10;

{ TAefosLazCommandRegistry }

constructor TAefosLazCommandRegistry.Create(const AProjectRootResolver,
  AGlobalRootResolver: TAefosLazRootResolver);
begin
  inherited Create;
  FProjectRootResolver := AProjectRootResolver;
  FGlobalRootResolver := AGlobalRootResolver;
end;

function TAefosLazCommandRegistry._ResolveProject: string;
begin
  Result := '';
  if Assigned(FProjectRootResolver) then
    Result := FProjectRootResolver();
end;

function TAefosLazCommandRegistry._ResolveGlobal: string;
begin
  Result := '';
  if Assigned(FGlobalRootResolver) then
    Result := FGlobalRootResolver();
end;

function TAefosLazCommandRegistry._RootForScope(
  const AScope: TAefosLazCommandScope): string;
begin
  if AScope = lcsGlobal then
    Result := _ResolveGlobal
  else
    Result := _ResolveProject;
end;

function TAefosLazCommandRegistry._CommandsDir(const ARoot: string): string;
begin
  Result := IncludeTrailingPathDelimiter(ARoot) + COMMANDS_FOLDER_REL;
end;

function TAefosLazCommandRegistry._CommandDir(const ARoot,
  AName: string): string;
begin
  Result := IncludeTrailingPathDelimiter(_CommandsDir(ARoot)) + Trim(AName);
end;

function TAefosLazCommandRegistry._CommandFile(const ARoot,
  AName: string): string;
begin
  Result := IncludeTrailingPathDelimiter(_CommandDir(ARoot, AName)) +
    COMMAND_FILE_NAME;
end;

function TAefosLazCommandRegistry._FindCommandRoot(const AName: string;
  out ARoot: string; out AScope: TAefosLazCommandScope): Boolean;
var
  LRoot: string;
begin
  Result := False;
  LRoot := _ResolveProject;
  if (LRoot <> '') and FileExists(_CommandFile(LRoot, AName)) then
  begin
    ARoot := LRoot;
    AScope := lcsProject;
    Exit(True);
  end;
  LRoot := _ResolveGlobal;
  if (LRoot <> '') and FileExists(_CommandFile(LRoot, AName)) then
  begin
    ARoot := LRoot;
    AScope := lcsGlobal;
    Exit(True);
  end;
end;

function TAefosLazCommandRegistry._ReadFileUtf8(const APath: string): string;
var
  LStream: TFileStream;
  LText: string;
begin
  Result := '';
  LText := '';
  LStream := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(LText, LStream.Size);
    if LStream.Size > 0 then
      LStream.ReadBuffer(LText[1], LStream.Size);
  finally
    LStream.Free;
  end;
  // The Delphi registry writes NO BOM, so a shared file never carries one; strip a
  // leading UTF-8 BOM defensively anyway so a hand-edited/BOM'd file still parses.
  if Copy(LText, 1, 3) = #$EF#$BB#$BF then
    Delete(LText, 1, 3);
  Result := LText;
end;

procedure TAefosLazCommandRegistry._WriteAtomicNoBom(const APath,
  AContent: string);
var
  LStream: TFileStream;
  LTemp: string;
begin
  // Atomic UTF-8 (no BOM) write, byte-identical to the Delphi registry's
  // _WriteAllTextUtf8Atomic: stage to <path>.tmp, then rename over the target.
  // AContent already holds UTF-8 bytes (the LCL string convention), so the raw
  // buffer write preserves them exactly -- no encoder, no preamble.
  LTemp := APath + '.tmp';
  LStream := TFileStream.Create(LTemp, fmCreate);
  try
    if AContent <> '' then
      LStream.WriteBuffer(AContent[1], Length(AContent));
  finally
    LStream.Free;
  end;
  try
    if FileExists(APath) then
      SysUtils.DeleteFile(APath);
    if not RenameFile(LTemp, APath) then
      raise EInOutError.CreateFmt('Cannot move "%s" to "%s".', [LTemp, APath]);
  except
    on E: Exception do
    begin
      try
        if FileExists(LTemp) then
          SysUtils.DeleteFile(LTemp);
      except
        // Best-effort cleanup -- never mask the original failure.
      end;
      raise;
    end;
  end;
end;

function TAefosLazCommandRegistry._ParseContent(const AContent: string;
  out AName, ADescription, ATags, AVersion, ABody: string): Boolean;
var
  LNorm: string;
  LLines: TStringList;
  LIndex: Integer;
  LFieldsStart: Integer;
  LClosing: Integer;
  LLine, LKey, LValue: string;
  LColon: Integer;
  LBody: string;
begin
  Result := False;
  AName := '';
  ADescription := '';
  ATags := '';
  AVersion := '';
  ABody := '';
  // Normalise newlines to LF, then split -- mirrors the Delphi parser.
  LNorm := StringReplace(AContent, #13#10, LF, [rfReplaceAll]);
  LNorm := StringReplace(LNorm, #13, LF, [rfReplaceAll]);
  LLines := TStringList.Create;
  try
    LLines.TextLineBreakStyle := tlbsLF;
    LLines.Text := LNorm;
    // Opening delimiter: the first non-blank line must be '---'.
    LFieldsStart := -1;
    for LIndex := 0 to LLines.Count - 1 do
    begin
      if Trim(LLines[LIndex]) = '---' then
      begin
        LFieldsStart := LIndex + 1;
        Break;
      end;
      if Trim(LLines[LIndex]) <> '' then
        Exit; // frontmatter must start with --- on the first non-blank line
    end;
    if LFieldsStart < 0 then
      Exit;
    // Fields until the closing '---'.
    LClosing := -1;
    LIndex := LFieldsStart;
    while LIndex < LLines.Count do
    begin
      LLine := LLines[LIndex];
      if Trim(LLine) = '---' then
      begin
        LClosing := LIndex;
        Break;
      end;
      if Trim(LLine) <> '' then
      begin
        LColon := Pos(':', LLine);
        if LColon <= 1 then
          Exit; // malformed frontmatter line (no key)
        LKey := Trim(Copy(LLine, 1, LColon - 1));
        LValue := Trim(Copy(LLine, LColon + 1, MaxInt));
        if SameText(LKey, 'name') then
          AName := LValue
        else if SameText(LKey, 'description') then
          ADescription := LValue
        else if SameText(LKey, 'version') then
          AVersion := LValue
        else if SameText(LKey, 'tags') then
          ATags := LValue;
      end;
      Inc(LIndex);
    end;
    if LClosing < 0 then
      Exit; // missing closing ---
    // Required fields.
    if (AName = '') or (ADescription = '') then
      Exit;
    // Body: the lines after the closing delimiter, joined by LF, one leading LF
    // trimmed -- mirrors _ExtractBody.
    LBody := '';
    for LIndex := LClosing + 1 to LLines.Count - 1 do
    begin
      if LBody <> '' then
        LBody := LBody + LF;
      LBody := LBody + LLines[LIndex];
    end;
    if (LBody <> '') and (LBody[1] = LF) then
      Delete(LBody, 1, 1);
    ABody := LBody;
    Result := True;
  finally
    LLines.Free;
  end;
end;

function TAefosLazCommandRegistry._RenderMarkdown(const AName, ADescription,
  AInstructions, ATags, AVersion: string): string;
begin
  // Executor-neutral frontmatter + body -- byte-identical to the Delphi
  // _RenderCommandMarkdown (LF newlines, tags/version emitted only when carried).
  Result := '---' + LF +
    'name: ' + Trim(AName) + LF +
    'description: ' + Trim(ADescription) + LF;
  if ATags <> '' then
    Result := Result + 'tags: ' + ATags + LF;
  if AVersion <> '' then
    Result := Result + 'version: ' + AVersion + LF;
  Result := Result + '---' + LF + AInstructions;
end;

procedure TAefosLazCommandRegistry._CollectFrom(const ARoot: string;
  const AScope: TAefosLazCommandScope;
  var AResult: TArray<TAefosLazCommandMeta>);
var
  LCommandsDir: string;
  LSearch: TSearchRec;
  LFolder, LFile, LContent: string;
  LName, LDesc, LTags, LVersion, LBody: string;
  LMeta: TAefosLazCommandMeta;
  LDup: Boolean;
  LI: Integer;
begin
  if ARoot = '' then
    Exit;
  LCommandsDir := _CommandsDir(ARoot);
  if not DirectoryExists(LCommandsDir) then
    Exit;
  if FindFirst(IncludeTrailingPathDelimiter(LCommandsDir) + '*', faDirectory,
    LSearch) <> 0 then
    Exit;
  try
    repeat
      if (LSearch.Name = '.') or (LSearch.Name = '..') then
        Continue;
      if (LSearch.Attr and faDirectory) = 0 then
        Continue;
      LFolder := LSearch.Name;
      LFile := IncludeTrailingPathDelimiter(
        IncludeTrailingPathDelimiter(LCommandsDir) + LFolder) + COMMAND_FILE_NAME;
      if not FileExists(LFile) then
        Continue;
      try
        LContent := _ReadFileUtf8(LFile);
      except
        Continue; // an unreadable file must not break the listing
      end;
      if not _ParseContent(LContent, LName, LDesc, LTags, LVersion, LBody) then
        Continue;
      // BR-1: the frontmatter name must match the folder name.
      if not SameText(LName, LFolder) then
        Continue;
      // Project shadows global: skip a name already collected (from the project
      // pass). Case-insensitive, like the Delphi dedupe.
      LDup := False;
      for LI := 0 to High(AResult) do
        if SameText(AResult[LI].Name, LName) then
        begin
          LDup := True;
          Break;
        end;
      if LDup then
        Continue;
      LMeta.Name := LName;
      LMeta.Description := LDesc;
      LMeta.Scope := AScope;
      SetLength(AResult, Length(AResult) + 1);
      AResult[High(AResult)] := LMeta;
    until FindNext(LSearch) <> 0;
  finally
    FindClose(LSearch);
  end;
end;

function TAefosLazCommandRegistry.List: TArray<TAefosLazCommandMeta>;
begin
  SetLength(Result, 0);
  // Project pass first so it wins on a name collision, then the per-user global
  // catalogue fills in the rest.
  _CollectFrom(_ResolveProject, lcsProject, Result);
  _CollectFrom(_ResolveGlobal, lcsGlobal, Result);
end;

function TAefosLazCommandRegistry.LoadCommand(const AName: string;
  out ACommand: TAefosLazCanonicalCommand): Boolean;
var
  LRoot: string;
  LScope: TAefosLazCommandScope;
  LContent: string;
  LNm, LDesc, LTags, LVersion, LBody: string;
begin
  ACommand := Default(TAefosLazCanonicalCommand);
  Result := False;
  if not _FindCommandRoot(AName, LRoot, LScope) then
    Exit;
  try
    LContent := _ReadFileUtf8(_CommandFile(LRoot, AName));
  except
    Exit;
  end;
  if not _ParseContent(LContent, LNm, LDesc, LTags, LVersion, LBody) then
    Exit;
  ACommand.Found := True;
  ACommand.Name := LNm;
  ACommand.Description := LDesc;
  ACommand.Instructions := LBody;
  ACommand.Scope := LScope;
  Result := True;
end;

function TAefosLazCommandRegistry.LoadBody(const AName: string;
  out ABody: string): Boolean;
var
  LCommand: TAefosLazCanonicalCommand;
begin
  ABody := '';
  Result := LoadCommand(AName, LCommand);
  if Result then
    ABody := LCommand.Instructions;
end;

function TAefosLazCommandRegistry.SaveCommand(const AName, ADescription,
  AInstructions: string; const AScope: TAefosLazCommandScope;
  out AError: string): Boolean;
var
  LRoot: string;
  LCommandDir: string;
  LCommandFile: string;
  LTags, LVersion: string;
  LExistingName, LExistingDesc, LExistingBody: string;
begin
  Result := False;
  AError := '';
  // Validate before touching the filesystem so an invalid name never creates a
  // folder (mirrors SaveCommand's AC-07).
  if not IsValidCommandName(Trim(AName)) then
  begin
    AError := Format('Invalid command name "%s": use only letters, digits, ' +
      'hyphen or underscore.', [AName]);
    Exit;
  end;
  if Trim(ADescription) = '' then
  begin
    AError := 'Command description is required.';
    Exit;
  end;
  LRoot := _RootForScope(AScope);
  if LRoot = '' then
  begin
    if AScope = lcsGlobal then
      AError := 'The global command catalogue is unavailable.'
    else
      AError := 'No active project; save this command as Global (all projects) ' +
        'instead, or open a project first.';
    Exit;
  end;
  LCommandDir := _CommandDir(LRoot, Trim(AName));
  LCommandFile := IncludeTrailingPathDelimiter(LCommandDir) + COMMAND_FILE_NAME;
  // Carry an existing file's tags/version through (BR-2).
  LTags := '';
  LVersion := '';
  if FileExists(LCommandFile) then
    try
      // On success LTags/LVersion hold the carried-through values; on a malformed
      // existing file they stay '' (the out params are reset by _ParseContent).
      _ParseContent(_ReadFileUtf8(LCommandFile), LExistingName, LExistingDesc,
        LTags, LVersion, LExistingBody);
    except
      LTags := '';
      LVersion := '';
    end;
  try
    if not ForceDirectories(LCommandDir) then
    begin
      AError := Format('Could not create the command folder "%s".', [LCommandDir]);
      Exit;
    end;
    _WriteAtomicNoBom(LCommandFile,
      _RenderMarkdown(Trim(AName), ADescription, AInstructions, LTags, LVersion));
    Result := True;
  except
    on E: Exception do
      AError := E.Message;
  end;
end;

class function TAefosLazCommandRegistry.IsValidCommandName(
  const AName: string): Boolean;
const
  RESERVED: array[0..21] of string = (
    'CON', 'PRN', 'AUX', 'NUL',
    'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
    'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9');
var
  LIndex: Integer;
  LCh: Char;
begin
  Result := False;
  if (AName = '') or (Length(AName) > COMMAND_NAME_MAX_LEN) then
    Exit;
  if (AName = '.') or (AName = '..') then
    Exit;
  for LIndex := 1 to Length(AName) do
  begin
    LCh := AName[LIndex];
    if not (((LCh >= 'A') and (LCh <= 'Z')) or
            ((LCh >= 'a') and (LCh <= 'z')) or
            ((LCh >= '0') and (LCh <= '9')) or
            (LCh = '.') or (LCh = '_') or (LCh = '-')) then
      Exit;
  end;
  for LIndex := Low(RESERVED) to High(RESERVED) do
    if SameText(AName, RESERVED[LIndex]) then
      Exit;
  Result := True;
end;

end.
