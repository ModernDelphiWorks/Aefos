unit Aefos.OTA.Terminal.Core.SlashCommands;

{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  Terminal-side reader of the user's `/command` catalogue — the addon/global
  commands the chat authors under `.aefos\commands\`. The Terminal surfaces the
  same commands (in a picker / palette) and, on selection, injects the trigger
  into the active AI-CLI session's PTY (TTerminalHost.SendInput). This unit is
  the DATA layer only: it lists + parses; the UI + injection live elsewhere.

  Two catalogues are merged, exactly like the chat's registry:
    - global:  %USERPROFILE%\.aefos\commands\<name>\COMMAND.md
    - project: <project>\.aefos\commands\<name>\COMMAND.md   (shadows global)

  Pure RTL + file I/O — no ToolsAPI, no VCL — so the pure suite can assert it.
  COMMAND.md is executor-neutral: YAML-ish frontmatter (name/description) + body.
}

interface

uses
  {$IFDEF FPC}SysUtils{$ELSE}System.SysUtils{$ENDIF};

type
  { Where a command was read from. }
  TSlashCommandScope = (scsProject, scsGlobal);

  { One `/command`: `Name` is the trigger without the slash (so `Trigger` =
    '/' + Name); `Body` is the COMMAND.md body (the prompt) with frontmatter
    stripped; `Path` is the COMMAND.md file. }
  TSlashCommand = record
    Name: string;
    Description: string;
    Body: string;
    Trigger: string;
    Path: string;
    Scope: TSlashCommandScope;
  end;

{ %USERPROFILE%\.aefos\commands — the per-user global catalogue. '' when
  %USERPROFILE% is unset. }
function GlobalCommandsDir: string;

{ Merged list of commands: project (when AProjectRoot <> '') first, then the
  global catalogue for names the project does not shadow. Sorted by Name.
  Never raises — an unreadable/malformed entry is skipped. }
function ListSlashCommands(const AProjectRoot: string): TArray<TSlashCommand>;

{ Parses a COMMAND.md's raw text into Name/Description/Body (frontmatter
  stripped). Returns False when the required `name`/`description` are absent.
  Pure — no file I/O. }
function ParseCommandMarkdown(const AContent: string;
  out AName, ADescription, ABody: string): Boolean;

{ The text to inject into the active session's PTY for ACommand. When
  ASlashCapable (the active AI CLI understands slash-commands — claude/codex/
  gemini, whose replicated command dir the CLI expands), we send the compact
  Trigger ('/name') and let the CLI expand it. Otherwise (a plain shell, or a
  CLI without slash-commands) we send the expanded prompt Body so the command
  still "works". A trailing newline is NOT added here — the caller decides
  whether to submit (WriteText + sLineBreak) or just insert. Pure. }
function SlashInjectionText(const ACommand: TSlashCommand;
  const ASlashCapable: Boolean): string;

implementation

uses
  {$IFDEF FPC}
  Classes,
  Aefos.Compat.IO,          // TPath / TFile / TDirectory / TSearchOption (FPC twins)
  Generics.Collections,
  Generics.Defaults;
  {$ELSE}
  System.Classes,
  System.Types,
  System.IOUtils,
  System.Generics.Collections,
  System.Generics.Defaults;
  {$ENDIF}

const
  COMMANDS_REL   = '.aefos\commands';
  COMMAND_FILE   = 'COMMAND.md';

function GlobalCommandsDir: string;
var
  LProfile: string;
begin
  LProfile := GetEnvironmentVariable('USERPROFILE');
  if LProfile = '' then
    Exit('');
  Result := TPath.Combine(LProfile, COMMANDS_REL);
end;

function _NormalizeNewlines(const AInput: string): string;
begin
  Result := StringReplace(AInput, #13#10, #10, [rfReplaceAll]);
  Result := StringReplace(Result, #13, #10, [rfReplaceAll]);
end;

{$IFDEF FPC}
// FPC's TStringHelper is AnsiString-only, so the Delphi `string.Split([#10])`
// (used in the {$ELSE} arm of ParseCommandMarkdown) does not resolve on the
// UnicodeString this unit is compiled with under {$mode delphiunicode}. Split on
// LF explicitly with the same result shape (one entry per line).
function _SplitLF(const AInput: string): TArray<string>;
var
  LIndex, LStart, LCount: Integer;
begin
  SetLength(Result, 0);
  LCount := 0;
  LStart := 1;
  for LIndex := 1 to Length(AInput) do
    if AInput[LIndex] = #10 then
    begin
      SetLength(Result, LCount + 1);
      Result[LCount] := Copy(AInput, LStart, LIndex - LStart);
      Inc(LCount);
      LStart := LIndex + 1;
    end;
  SetLength(Result, LCount + 1);
  Result[LCount] := Copy(AInput, LStart, Length(AInput) - LStart + 1);
end;
{$ENDIF}

// Named comparer (the FPC compiler has no anonymous methods; a named global
// function binds TComparer.Construct on BOTH compilers -- the repo convention,
// see Aefos.OTA.Terminal.Core.CommandPalette._CompareScored). FPC's
// TComparisonFunc takes `constref` params (Delphi's TComparison takes `const`);
// the modifier is the only source difference between the arms.
function _CompareSlashByName(
  {$IFDEF FPC}constref{$ELSE}const{$ENDIF} A, B: TSlashCommand): Integer;
begin
  Result := CompareText(A.Name, B.Name);
end;

function ParseCommandMarkdown(const AContent: string;
  out AName, ADescription, ABody: string): Boolean;
var
  LLines: TArray<string>;
  LIndex, LClose, LColon: Integer;
  LOpened: Boolean;
  LLine, LKey, LValue: string;
begin
  AName := '';
  ADescription := '';
  ABody := '';
  LLines := {$IFDEF FPC}_SplitLF(_NormalizeNewlines(AContent))
    {$ELSE}_NormalizeNewlines(AContent).Split([#10]){$ENDIF};
  // Find the opening --- (first non-blank line must be it).
  LOpened := False;
  LIndex := 0;
  while LIndex <= High(LLines) do
  begin
    if Trim(LLines[LIndex]) = '' then
    begin
      Inc(LIndex);
      Continue;
    end;
    LOpened := Trim(LLines[LIndex]) = '---';
    Break;
  end;
  if not LOpened then
    Exit(False);
  Inc(LIndex);
  // Read frontmatter key: value until the closing ---.
  LClose := -1;
  while LIndex <= High(LLines) do
  begin
    LLine := LLines[LIndex];
    if Trim(LLine) = '---' then
    begin
      LClose := LIndex;
      Break;
    end;
    LColon := Pos(':', LLine);
    if LColon > 1 then
    begin
      LKey := Trim(Copy(LLine, 1, LColon - 1));
      LValue := Trim(Copy(LLine, LColon + 1, MaxInt));
      if SameText(LKey, 'name') then
        AName := LValue
      else if SameText(LKey, 'description') then
        ADescription := LValue;
    end;
    Inc(LIndex);
  end;
  if LClose < 0 then
    Exit(False);
  // Body = everything after the closing ---, one leading blank line trimmed. A
  // plain concat rather than a TStringBuilder: FPC 3.2.2's TStringBuilder is
  // Ansi-only and its Append overloads are ambiguous on the UnicodeString this
  // unit compiles with under {$mode delphiunicode}. The join semantics (LF between
  // lines, no leading LF, mirroring `if Length > 0 then Append(#10)`) are identical.
  ABody := '';
  for LIndex := LClose + 1 to High(LLines) do
  begin
    if Length(ABody) > 0 then
      ABody := ABody + #10;
    ABody := ABody + LLines[LIndex];
  end;
  if (Length(ABody) > 0) and (ABody[Low(ABody)] = #10) then
    Delete(ABody, Low(ABody), 1);
  Result := (AName <> '') and (ADescription <> '');
end;

function _ReadUtf8(const APath: string): string;
var
  LBytes: TBytes;
begin
  LBytes := TFile.ReadAllBytes(APath);
  Result := TEncoding.UTF8.GetString(LBytes);
end;

// Appends the commands under ACommandsDir to ACollected, skipping any Name
// already in ASeen (case-insensitive). Malformed entries are ignored.
procedure _CollectFrom(const ACommandsDir: string; const AScope: TSlashCommandScope;
  const ACollected: TList<TSlashCommand>; const ASeen: TDictionary<string, Byte>);
var
  LDirs: TStringDynArray;
  LIndex: Integer;
  LFile, LName, LDesc, LBody, LKey: string;
  LCmd: TSlashCommand;
begin
  if (ACommandsDir = '') or not TDirectory.Exists(ACommandsDir) then
    Exit;
  LDirs := TDirectory.GetDirectories(ACommandsDir
    {$IFDEF FPC}, '*', soTopDirectoryOnly{$ENDIF});
  for LIndex := 0 to High(LDirs) do
  begin
    LFile := TPath.Combine(LDirs[LIndex], COMMAND_FILE);
    if not TFile.Exists(LFile) then
      Continue;
    try
      if not ParseCommandMarkdown(_ReadUtf8(LFile), LName, LDesc, LBody) then
        Continue;
    except
      Continue;
    end;
    LKey := LowerCase(LName);
    if ASeen.ContainsKey(LKey) then
      Continue;
    ASeen.Add(LKey, 0);
    LCmd := Default(TSlashCommand);
    LCmd.Name := LName;
    LCmd.Description := LDesc;
    LCmd.Body := LBody;
    LCmd.Trigger := '/' + LName;
    LCmd.Path := LFile;
    LCmd.Scope := AScope;
    ACollected.Add(LCmd);
  end;
end;

function SlashInjectionText(const ACommand: TSlashCommand;
  const ASlashCapable: Boolean): string;
begin
  if ASlashCapable then
    Result := ACommand.Trigger
  else
    Result := ACommand.Body;
end;

function ListSlashCommands(const AProjectRoot: string): TArray<TSlashCommand>;
var
  LCollected: TList<TSlashCommand>;
  LSeen: TDictionary<string, Byte>;
begin
  LCollected := TList<TSlashCommand>.Create;
  LSeen := TDictionary<string, Byte>.Create;
  try
    // Project first so it shadows global on a name clash.
    if AProjectRoot <> '' then
      _CollectFrom(TPath.Combine(AProjectRoot, COMMANDS_REL), scsProject,
        LCollected, LSeen);
    _CollectFrom(GlobalCommandsDir, scsGlobal, LCollected, LSeen);
    LCollected.Sort(TComparer<TSlashCommand>.Construct(_CompareSlashByName));
    Result := LCollected.ToArray;
  finally
    LSeen.Free;
    LCollected.Free;
  end;
end;

end.
