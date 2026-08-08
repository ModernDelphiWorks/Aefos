unit Aefos.Addons.Installer;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  Aefos Addons - install/uninstall/update/list orchestration.

  Ties the pieces together: resolve a slug from the registry, download + verify
  the pinned zip, extract, validate the bundle, lay out the present artifacts
  under ~/.aefos, refresh the MCP aggregate the plugin merges, and record the
  ledger. Every layout target is slug-scoped under ~/.aefos, so uninstall is a
  bounded delete of exactly this addon's three folders.

  Progress is reported through an injected line-sink so the dpr owns stdout.
}

interface

uses
  SysUtils,
  Aefos.Addons.Types;

type
  // The progress line sink. Alias of the one declaration in Aefos.Addons.Types
  // (which carries the FPC branch): on Delphi a `reference to` so a standalone
  // or captured proc binds, on FPC 3.2.2 a plain procedural type because it has
  // no anonymous methods.
  // KNOWN DIVERGENCE: the two branches are DIFFERENT types. Passing a
  // capturing anonymous method on the Delphi side compiles there but will
  // break the FPC build - keep call sites on plain procedures (or convert
  // this to a carrier-object callback when a closure becomes necessary).
  TAddonLog = TAddonLogProc;

  TInstallOptions = record
    Yes: Boolean;       // --yes: pre-consent third-party (mcp/tools) code
    AefosVersion: string; // installed Aefos version for the requirement gate
    Source: string;     // --source: which store to take the slug from ('' = any)
    { Factory: one named owner for building the options record instead of a
      Default() + field-by-field fill at the call site. }
    class function Create(AYes: Boolean;
      const AAefosVersion: string; const ASource: string = ''): TInstallOptions; static;
  end;

  { Static, sealed namespace for install/uninstall/update/list orchestration.
    Never instantiated; the class IS the namespace, so the old 'Addon(s)' name
    prefixes/suffixes are gone. }
  TAddonInstaller = class sealed
  public
    { Installs (or reinstalls) ASlug at the registry's pinned version. Raises an
      EAddonError subclass on any failure; a partial extract is cleaned up. }
    class procedure Install(const ASlug: string; const AOptions: TInstallOptions;
      const ALog: TAddonLog); static;

    { Removes ASlug: deletes its slug-scoped folders, refreshes the MCP
      aggregate, drops it from the ledger. Raises EAddonNotFound when it is not
      installed. }
    class procedure Uninstall(const ASlug: string; const ALog: TAddonLog); static;

    { Sha-aware update of a single slug. Loads the ledger, fetches the registry,
      and compares (DecideUpdate): up-to-date => reports and does nothing (no
      download); changed => clean-replace via Install. Raises EAddonNotFound when
      the slug is not installed, or not in the registry. }
    class procedure Update(const ASlug: string; const AOptions: TInstallOptions;
      const ALog: TAddonLog); static;

    { Sha-aware update of EVERY installed slug. Fetches the registry once, then
      runs the DecideUpdate comparison per installed addon; refreshes the changed
      ones and reports the up-to-date ones. A slug no longer in the registry is
      warned and skipped (never errors the whole run). Ends with a summary. }
    class procedure UpdateAll(const AOptions: TInstallOptions;
      const ALog: TAddonLog); static;

    { Dry-run: reports "<slug>: update available" / "<slug>: current" without
      installing anything. ASlug empty => every installed addon; otherwise just
      that one (raises EAddonNotFound when it is not installed). }
    class procedure CheckUpdates(const ASlug: string; const ALog: TAddonLog); static;

    { Prints the ledger (one line per installed addon) via ALog. }
    class procedure List(const ALog: TAddonLog); static;
  end;

implementation

uses
  Classes,
  DateUtils,
  Aefos.Compat.IO,
  Aefos.Compat.Json,
  Generics.Collections,
  Aefos.Addons.Paths,
  Aefos.Addons.Manifest,
  Aefos.Addons.PluginFormat,
  Aefos.Addons.Sources,
  Aefos.Addons.Catalog,
  Aefos.Addons.Ledger,
  Aefos.Addons.McpRewrite,
  Aefos.Addons.Net,
  Aefos.Compat.JsonFormat;

// Classic-RTL string helpers (FPC 3.2.2 has no TStringHelper): kept
// unit-private, byte-identical to the Delphi string methods they replace.

// string.Split(delims): splits on any delimiter char, keeping empty segments;
// an empty AText yields a zero-length array.
function _SplitStr(const AText: string;
  const ADelims: array of Char): TArray<string>;
var
  LIndex, LStart, LCount, LDelim: Integer;
  LIsDelim: Boolean;
begin
  SetLength(Result, 0);
  if AText = '' then
    Exit;
  LStart := 1;
  LCount := 0;
  for LIndex := 1 to Length(AText) do
  begin
    LIsDelim := False;
    for LDelim := 0 to High(ADelims) do
      if AText[LIndex] = ADelims[LDelim] then
      begin
        LIsDelim := True;
        Break;
      end;
    if LIsDelim then
    begin
      SetLength(Result, LCount + 1);
      Result[LCount] := Copy(AText, LStart, LIndex - LStart);
      Inc(LCount);
      LStart := LIndex + 1;
    end;
  end;
  SetLength(Result, LCount + 1);
  Result[LCount] := Copy(AText, LStart, Length(AText) - LStart + 1);
end;

function _InCharSet(const ACh: Char; const AChars: array of Char): Boolean;
var
  LIndex: Integer;
begin
  for LIndex := 0 to High(AChars) do
    if ACh = AChars[LIndex] then
      Exit(True);
  Result := False;
end;

// string.Substring(startIndex): 0-based start, to the end of the string.
function _SubstrFrom(const AText: string; const AStart0: Integer): string;
begin
  if AStart0 >= Length(AText) then
    Exit('');
  Result := Copy(AText, AStart0 + 1, Length(AText) - AStart0);
end;

// string.TrimLeft(chars): drop leading chars in the set.
function _TrimLeftChars(const AText: string;
  const AChars: array of Char): string;
var
  LIndex: Integer;
begin
  LIndex := 1;
  while (LIndex <= Length(AText)) and _InCharSet(AText[LIndex], AChars) do
    Inc(LIndex);
  Result := Copy(AText, LIndex, Length(AText) - LIndex + 1);
end;

// string.TrimRight(chars): drop trailing chars in the set.
function _TrimRightChars(const AText: string;
  const AChars: array of Char): string;
var
  LLast: Integer;
begin
  LLast := Length(AText);
  while (LLast >= 1) and _InCharSet(AText[LLast], AChars) do
    Dec(LLast);
  Result := Copy(AText, 1, LLast);
end;

// string.StartsWith(prefix, True): case-insensitive.
function _StartsWithCI(const AText, APrefix: string): Boolean;
begin
  Result := SameText(Copy(AText, 1, Length(APrefix)), APrefix);
end;

// string.Contains(sub).
function _ContainsText(const AText, ASub: string): Boolean;
begin
  Result := Pos(ASub, AText) > 0;
end;

{ TInstallOptions }

class function TInstallOptions.Create(AYes: Boolean;
  const AAefosVersion: string; const ASource: string): TInstallOptions;
begin
  Result := Default(TInstallOptions);
  Result.Yes := AYes;
  Result.AefosVersion := AAefosVersion;
  Result.Source := ASource;
end;

{ TAddonInstaller }

function _NowUtcIso: string;
var
  LNow: TDateTime;
begin
  {$IFDEF FPC}
  LNow := LocalTimeToUniversal(Now);
  {$ELSE}
  LNow := TTimeZone.Local.ToUniversalTime(Now);
  {$ENDIF}
  Result := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"', LNow);
end;

// A human label for a version that may be empty (evergreen). Prints "v<X>" when
// a version is stamped, and "current" when it is not - so a log line never emits
// a bare "v" with nothing after it.
function _VerLabel(const AVersion: string): string;
begin
  if Trim(AVersion) = '' then
    Result := 'current'
  else
    Result := 'v' + Trim(AVersion);
end;

// Which store an update should look in: an explicit --source wins, otherwise
// the store this addon was installed FROM. Falling back to "any store" only
// happens for a ledger written before sources existed.
function _PreferredSource(const AOptions: TInstallOptions;
  const AItem: TInstalledAddon): string;
begin
  if Trim(AOptions.Source) <> '' then
    Result := AOptions.Source
  else
    Result := AItem.Source;
end;

// A folder bundle publishes no sha - it is a directory, not a release - so one
// is MEASURED before any comparison. Without this every update run would find
// an empty sha against a recorded one, call it "changed", and reinstall an
// addon that has not moved. The measurement itself lives on the catalogue,
// which needs the same answer to say whether a row is current.
procedure _EnsureIdentity(var AEntry: TAddonRegistryEntry);
begin
  TAddonCatalog.EnsureIdentity(AEntry);
end;

// Recursively copies ASrcDir into ADstDir, appending every written file to
// AFiles. No-op when ASrcDir is absent (artifact simply not shipped).
procedure _CopyTree(const ASrcDir, ADstDir: string;
  const AFiles: TList<string>);
var
  LFiles, LDirs: TArray<string>;
  LIndex: Integer;
  LRel, LTarget: string;
begin
  if not TDirectory.Exists(ASrcDir) then
    Exit;
  ForceDirectories(ADstDir);
  LDirs := TDirectory.GetDirectories(ASrcDir, '*', TSearchOption.soAllDirectories);
  for LIndex := 0 to High(LDirs) do
  begin
    LRel := _SubstrFrom(LDirs[LIndex], Length(ASrcDir));
    ForceDirectories(TPath.Combine(ADstDir, _TrimLeftChars(LRel, ['\', '/'])));
  end;
  LFiles := TDirectory.GetFiles(ASrcDir, '*', TSearchOption.soAllDirectories);
  for LIndex := 0 to High(LFiles) do
  begin
    LRel := _TrimLeftChars(_SubstrFrom(LFiles[LIndex], Length(ASrcDir)), ['\', '/']);
    LTarget := TPath.Combine(ADstDir, LRel);
    ForceDirectories(ExtractFileDir(LTarget));
    TFile.Copy(LFiles[LIndex], LTarget, True);
    AFiles.Add(LTarget);
  end;
end;

procedure _CopyOneFile(const ASrcFile, ADstFile: string;
  const AFiles: TList<string>);
begin
  if not TFile.Exists(ASrcFile) then
    Exit;
  ForceDirectories(ExtractFileDir(ADstFile));
  TFile.Copy(ASrcFile, ADstFile, True);
  AFiles.Add(ADstFile);
end;

// Lays down an addon's mcp.json from its bundle server.json, substituting the
// ${ADDON_ROOT} token with AAddonRootAbs (the addon's absolute install dir) so
// a RAW spawn (no shell, no %VAR% expansion) can launch the server command.
// A server.json without the token is written byte-for-byte unchanged.
procedure _WriteMcpFragment(const ASrcFile, ADstFile, AAddonRootAbs: string;
  const AFiles: TList<string>);
var
  LJson: string;
begin
  if not TFile.Exists(ASrcFile) then
    Exit;
  LJson := TFile.ReadAllText(ASrcFile, TEncoding.UTF8);
  LJson := TAddonMcpRewrite.RewriteRootToken(LJson, AAddonRootAbs);
  ForceDirectories(ExtractFileDir(ADstFile));
  TFile.WriteAllBytes(ADstFile, TEncoding.UTF8.GetBytes(LJson));
  AFiles.Add(ADstFile);
end;

// Rebuilds ~/.aefos\addons\mcp-servers.json from every ledger addon that ships
// an mcp.json fragment. The plugin merges this file into aefos-mcp.json; the
// CLI never writes aefos-mcp.json itself (contract §5).
procedure _RefreshMcpAggregate;
var
  LItems: TArray<TInstalledAddon>;
  LIndex: Integer;
  LFragPath, LFrag: string;
  LRoot, LServers: TJSONObject;
  LFragVal: TJSONValue;
  LPair: TJSONPair;
  LBytes: TBytes;
begin
  LItems := TAddonLedger.Load;
  LRoot := TJSONObject.Create;
  try
    LServers := TJSONObject.Create;
    LRoot.AddPair('mcpServers', LServers);
    for LIndex := 0 to High(LItems) do
    begin
      if not LItems[LIndex].Artifacts.HasMcp then
        Continue;
      LFragPath := TPath.Combine(TAddonPaths.AddonDir(LItems[LIndex].Slug), 'mcp.json');
      if not TFile.Exists(LFragPath) then
        Continue;
      try
        LFrag := TFile.ReadAllText(LFragPath, TEncoding.UTF8);
      except
        Continue;
      end;
      // Resolve ${ADDON_ROOT} against this addon's absolute install dir before
      // merging, so the aggregate the plugin consumes never carries a token or
      // %VAR% a raw spawn cannot expand. No-op for token-less fragments.
      LFrag := TAddonMcpRewrite.RewriteRootToken(LFrag, TAddonPaths.AddonDir(LItems[LIndex].Slug));
      LFragVal := TJSONObject.ParseJSONValue(LFrag);
      try
        if LFragVal is TJSONObject then
          for LPair in TJSONObject(LFragVal) do
            LServers.AddPair(LPair.JsonString.Value, LPair.JsonValue.Clone as TJSONValue);
      finally
        LFragVal.Free;
      end;
    end;
    ForceDirectories(TAddonPaths.AddonsRoot);
    LBytes := TEncoding.UTF8.GetBytes(LRoot.Format(2));
    TFile.WriteAllBytes(TAddonPaths.McpAggregatePath, LBytes);
  finally
    LRoot.Free;
  end;
end;

procedure _RemoveSlugDirs(const ASlug: string);
var
  LDir: string;
  LNamed: TArray<string>;
  LIndex: Integer;
begin
  for LDir in [TAddonPaths.CommandDir(ASlug), TAddonPaths.SkillDir(ASlug), TAddonPaths.TemplateDir(ASlug),
    TAddonPaths.AddonDir(ASlug)] do
    if TDirectory.Exists(LDir) then
      TDirectory.Delete(LDir, True);
  // A multi-artifact bundle spreads over <root>\<slug>.<name>, which is not one
  // directory this can name up front. Sweeping the pattern is what makes a
  // reinstall clean-replace: an addon that DROPPED a command or skill in its
  // new version would otherwise leave the old one behind, still loaded, forever.
  for LDir in [TAddonPaths.CommandsRoot, TAddonPaths.SkillsRoot] do
  begin
    if not TDirectory.Exists(LDir) then
      Continue;
    LNamed := TDirectory.GetDirectories(LDir, ASlug + '.*');
    for LIndex := 0 to High(LNamed) do
      if TDirectory.Exists(LNamed[LIndex]) then
        TDirectory.Delete(LNamed[LIndex], True);
  end;
end;

// The trigger names the chat will really show, taken from the directories that
// were laid down under commands\ rather than from the slug. An install[]-mapped
// bundle is covered by the same walk, so the announcement follows whatever the
// mapping chose to create.
function _CommandNamesFrom(const ARoots: TList<string>): string;
var
  LIndex: Integer;
  LParent: string;
begin
  Result := '';
  LParent := ExcludeTrailingPathDelimiter(TAddonPaths.CommandsRoot);
  for LIndex := 0 to ARoots.Count - 1 do
    if SameText(ExcludeTrailingPathDelimiter(ExtractFileDir(
      ExcludeTrailingPathDelimiter(ARoots[LIndex]))), LParent) then
    begin
      if Result <> '' then
        Result := Result + ', ';
      Result := Result + '/' +
        ExtractFileName(ExcludeTrailingPathDelimiter(ARoots[LIndex]));
    end;
end;

// Lays down the addon's command(s). TWO bundle layouts are accepted on purpose:
//
//   command\COMMAND.md      one command - every addon in the gallery today
//                           -> commands\<slug>\COMMAND.md        (/<slug>)
//   commands\<name>\        SEVERAL commands, a folder each
//                           -> commands\<slug>.<name>\COMMAND.md (/<slug>.<name>)
//
// The plural is a FOLDER per command, not a file per command, because that is
// what the chat's command registry reads: it keys a command by its directory
// name and loads <dir>\COMMAND.md, with an optional references\ beside it
// (Aefos.OTA.Chat.Core.CommandRegistry). Copying loose .md files here would
// install commands the picker never shows - present on disk, dead in the IDE.
procedure _InstallCommands(const ABundleDir, ASlug: string;
  const AFiles, ARoots: TList<string>; const ALog: TAddonLog);
var
  LPluralDir, LTargetDir: string;
  LDirs: TArray<string>;
  LIndex, LBefore: Integer;
begin
  LBefore := AFiles.Count;
  LPluralDir := TPath.Combine(ABundleDir, 'commands');
  if TDirectory.Exists(LPluralDir) then
  begin
    LDirs := TDirectory.GetDirectories(LPluralDir);
    for LIndex := 0 to High(LDirs) do
    begin
      LTargetDir := TAddonPaths.CommandDirNamed(ASlug, ExtractFileName(LDirs[LIndex]));
      // The whole folder, so an optional references\ travels with its command.
      _CopyTree(LDirs[LIndex], LTargetDir, AFiles);
      ARoots.Add(LTargetDir);
      ALog('  + command  ' + LTargetDir);
    end;
  end
  else
  begin
    LTargetDir := TAddonPaths.CommandDir(ASlug);
    _CopyOneFile(TPath.Combine(ABundleDir, 'command\COMMAND.md'),
      TPath.Combine(LTargetDir, 'COMMAND.md'), AFiles);
    ARoots.Add(LTargetDir);
    ALog('  + command  ' + LTargetDir);
  end;
  // Declared and empty is never a success - it means addon.json disagrees with
  // the bundle, and a silent no-op would be recorded in the ledger as installed.
  if AFiles.Count = LBefore then
    raise EAddonIntegrity.CreateFmt(
      'addon "%s" declares a command but the bundle carries neither ' +
      'command\COMMAND.md nor any commands\<name>\.', [ASlug]);
end;

// Lays down the addon's skill(s), same two-layout rule as the commands above:
//
//   skill\                one skill  -> skills\<slug>\
//   skills\<name>\        SEVERAL    -> skills\<slug>.<name>\
//
// The prefix on the plural form is what keeps two addons from overwriting each
// other in the flat skills root (see TAddonPaths.SkillDirNamed).
procedure _InstallSkills(const ABundleDir, ASlug: string;
  const AFiles, ARoots: TList<string>; const ALog: TAddonLog);
var
  LPluralDir, LTargetDir: string;
  LDirs: TArray<string>;
  LIndex, LBefore: Integer;
begin
  LBefore := AFiles.Count;
  LPluralDir := TPath.Combine(ABundleDir, 'skills');
  if TDirectory.Exists(LPluralDir) then
  begin
    LDirs := TDirectory.GetDirectories(LPluralDir);
    for LIndex := 0 to High(LDirs) do
    begin
      // ExtractFileName over a directory path with no trailing separator is the
      // folder's own name - the skill name the bundle chose.
      LTargetDir := TAddonPaths.SkillDirNamed(ASlug, ExtractFileName(LDirs[LIndex]));
      _CopyTree(LDirs[LIndex], LTargetDir, AFiles);
      ARoots.Add(LTargetDir);
      ALog('  + skill    ' + LTargetDir);
    end;
  end
  else
  begin
    LTargetDir := TAddonPaths.SkillDir(ASlug);
    _CopyTree(TPath.Combine(ABundleDir, 'skill'), LTargetDir, AFiles);
    ARoots.Add(LTargetDir);
    ALog('  + skill    ' + LTargetDir);
  end;
  if AFiles.Count = LBefore then
    raise EAddonIntegrity.CreateFmt(
      'addon "%s" declares a skill but the bundle carries neither skill\ ' +
      'nor any skills\<name>\.', [ASlug]);
end;

procedure _RequireConsent(const AEntry: TAddonRegistryEntry;
  const AManifest: TAddonManifest; const AOptions: TInstallOptions;
  const ALog: TAddonLog);
var
  LRunsCode: Boolean;
begin
  LRunsCode := AManifest.Artifacts.HasMcp or AManifest.Artifacts.HasTools;
  if LRunsCode and (AEntry.Trust <> atOfficial) and (not AOptions.Yes) then
    raise EAddonError.CreateFmt(
      'addon "%s" is community-trust and ships runnable code (mcp/tools). ' +
      'Re-run with --yes to consent to installing third-party code.',
      [AEntry.Slug]);
  if LRunsCode then
    ALog(Format('  ! %s ships runnable code (%s-trust) - it will run on your machine.',
      [AEntry.Slug, AEntry.Trust.ToStr]));
end;

// True when APath resolves inside ~/.aefos — the containment guard so a
// malicious target_path ("..\..\Windows") can never escape the content root.
function _UnderUserRoot(const APath: string): Boolean;
var
  LRoot, LFull: string;
begin
  LRoot := IncludeTrailingPathDelimiter(TPath.GetFullPath(TAddonPaths.UserRoot));
  LFull := TPath.GetFullPath(APath);
  Result := _StartsWithCI(LFull, LRoot) or
    SameText(ExcludeTrailingPathDelimiter(LFull), ExcludeTrailingPathDelimiter(LRoot));
end;

// Resolves a mapping's Source against the extracted bundle. The portal may
// publish a REPO-relative source ("addons/<slug>/command/") while the extracted
// bundle is slug-rooted, so the real content lives at "<bundle>/command/". Try
// the source as-is first; if that folder is absent, fall back to just its last
// path segment ("addons/<slug>/command/" -> "command" -> "<bundle>/command").
// Returns '' when neither resolves to an existing directory.
function _ResolveMappingSource(const ABundleDir, ASource: string): string;
var
  LDirect, LSeg, LFallback: string;
  LParts: TArray<string>;
begin
  LDirect := TPath.Combine(ABundleDir, ASource);
  if TDirectory.Exists(LDirect) then
    Exit(LDirect);
  LParts := _SplitStr(_TrimRightChars(ASource, ['\', '/']), ['\', '/']);
  if Length(LParts) > 0 then
  begin
    LSeg := LParts[High(LParts)];
    if LSeg <> '' then
    begin
      LFallback := TPath.Combine(ABundleDir, LSeg);
      if TDirectory.Exists(LFallback) then
        Exit(LFallback);
    end;
  end;
  Result := '';
end;

// Applies the portal's install[] mappings: each { source, target_path } copies
// the bundle-relative folder into ~/.aefos\target_path (clean-replaced). Records
// every written file (AFiles) and each target dir (ARoots, for uninstall), and
// infers the ledger artifacts from the target's first segment.
procedure _ApplyInstallMappings(const ABundleDir: string;
  const AMappings: TArray<TAddonInstallMapping>;
  const AFiles, ARoots: TList<string>; out AArtifacts: TAddonArtifacts;
  const ALog: TAddonLog);
var
  LIndex: Integer;
  LSrc, LDst, LSeg: string;
  LSegParts: TArray<string>;
begin
  AArtifacts := Default(TAddonArtifacts);
  for LIndex := 0 to High(AMappings) do
  begin
    LSrc := _ResolveMappingSource(ABundleDir, AMappings[LIndex].Source);
    LDst := TPath.GetFullPath(TPath.Combine(TAddonPaths.UserRoot,
      AMappings[LIndex].TargetPath));
    if not _UnderUserRoot(LDst) then
      raise EAddonIntegrity.CreateFmt(
        'install target "%s" escapes ~/.aefos.', [AMappings[LIndex].TargetPath]);
    if LSrc = '' then
    begin
      ALog(Format('  ! mapping source "%s" not in bundle - skipped.',
        [AMappings[LIndex].Source]));
      Continue;
    end;
    if TDirectory.Exists(LDst) then
      TDirectory.Delete(LDst, True);           // clean-replace this target
    _CopyTree(LSrc, LDst, AFiles);
    ARoots.Add(ExcludeTrailingPathDelimiter(LDst));
    // A degenerate target_path ('/' or '\') trims+splits to a ZERO-length
    // array (Split('') = empty array - proven on the real RTL), so [0] here
    // was an unguarded read; classify it as nothing instead of crashing.
    LSegParts := _SplitStr(_TrimLeftChars(AMappings[LIndex].TargetPath,
      ['\', '/']), ['\', '/']);
    if Length(LSegParts) > 0 then
      LSeg := LowerCase(LSegParts[0])
    else
      LSeg := '';
    if LSeg = 'commands' then AArtifacts.HasCommand := True
    else if LSeg = 'skills' then AArtifacts.HasSkill := True
    else if LSeg = 'addons' then
    begin
      if _ContainsText(LowerCase(AMappings[LIndex].Source), 'mcp') then AArtifacts.HasMcp := True;
      if _ContainsText(LowerCase(AMappings[LIndex].Source), 'tool') then AArtifacts.HasTools := True;
    end;
    ALog(Format('  + %-8s %s', [LSeg, LDst]));
  end;
end;

class procedure TAddonInstaller.Install(const ASlug: string;
  const AOptions: TInstallOptions; const ALog: TAddonLog);
var
  LRow: TAddonCatalogRow;
  LEntry: TAddonRegistryEntry;
  LManifest: TAddonManifest;
  LTempZip, LTempDir, LBundleDir, LStoreDir, LManifestPath, LShortSha: string;
  LFormat: TPluginFormat;
  LFiles, LRoots, LScratch: TList<string>;
  LArts: TAddonArtifacts;
  LItem: TInstalledAddon;
  LCommands: string;
begin
  if not TAddonPaths.IsValidSlug(ASlug) then
    raise EAddonError.CreateFmt('invalid addon slug "%s".', [ASlug]);

  // Resolution goes through the CATALOGUE, not a compiled-in gallery URL: with
  // stores configured, "install <slug>" has to be able to mean the company's
  // store. Ambiguity raises inside Resolve rather than being guessed here.
  ALog(Format('Resolving %s ...', [ASlug]));
  LRow := TAddonCatalog.ResolveOne(ASlug, AOptions.Source);
  LEntry := LRow.Entry;
  ALog(Format('  found in %s', [LRow.Source]));

  if not TAddonVersion.Satisfies(AOptions.AefosVersion, LEntry.RequiresAefos) then
    raise EAddonRequirement.CreateFmt(
      'addon "%s" requires Aefos %s but this is %s.',
      [ASlug, LEntry.RequiresAefos, AOptions.AefosVersion]);

  // A store may hand us a bundle already unpacked - that is what a path store
  // (a folder, a company share) IS. Measured, never declared: a URL that names
  // an existing directory is a folder bundle, everything else is an archive.
  // Same instinct as the SQLite gate - where the thing is a FILE, measure it.
  LStoreDir := '';
  if TDirectory.Exists(LEntry.Url) then
    LStoreDir := TPath.GetFullPath(LEntry.Url);

  LTempZip := '';
  LTempDir := '';
  LBundleDir := '';
  try
    if LStoreDir <> '' then
    begin
      ALog(Format('Reading %s from %s ...', [ASlug, LStoreDir]));
      // The folder has no published sha, so it gets a MEASURED one - the same
      // identity the rest of the system compares, computed over the tree.
      // Without it every `update` would see "changed" and reinstall forever.
      // Measured on the ORIGINAL, before the copy, because the store's content
      // is what the identity is OF.
      LEntry.Sha256 := TAddonNet.Sha256OfTree(LStoreDir);

      // Then COPY it, and read the copy. Reading a store in place looks free
      // and is not: adopting a foreign bundle STAGES normalised artifacts into
      // <bundle>\_aefos\, so working in place would write into somebody else's
      // store - which fails outright on a read-only share, and otherwise
      // changes the very tree we just measured, so every later run would report
      // an update that nobody made. Every other path already owned its tree;
      // this restores that invariant instead of making the writer conditional.
      LTempDir := TPath.Combine(TPath.GetTempPath,
        'aefos-addon-' + ASlug + '-' + Copy(LEntry.Sha256, 1, 12));
      if TDirectory.Exists(LTempDir) then
        TDirectory.Delete(LTempDir, True);
      LBundleDir := TPath.Combine(LTempDir, ASlug);
      LScratch := TList<string>.Create;
      try
        _CopyTree(LStoreDir, LBundleDir, LScratch);
      finally
        LScratch.Free;
      end;
    end
    else
    begin
      // Over the network the sha is the only thing between the user and
      // whatever answered the request, so an entry without one is refused
      // rather than installed unverified.
      if Trim(LEntry.Sha256) = '' then
        raise EAddonIntegrity.CreateFmt(
          'store "%s" published no sha256 for "%s", so the download cannot be ' +
          'verified.', [LRow.Source, ASlug]);
      // The temp discriminator must not depend on a version that may be empty
      // (evergreen). The sha256 is always present and IS the identity, so a
      // short prefix of it is the stable temp key.
      LShortSha := Copy(LEntry.Sha256, 1, 12);
      LTempDir := TPath.Combine(TPath.GetTempPath,
        'aefos-addon-' + ASlug + '-' + LShortSha);
      LTempZip := LTempDir + '.zip';

      ALog(Format('Downloading %s %s ...', [ASlug, _VerLabel(LEntry.Version)]));
      TAddonNet.DownloadFile(LEntry.Url, LTempZip);
      ALog('Verifying integrity (sha256) ...');
      TAddonNet.VerifySha256(LTempZip, LEntry.Sha256);

      if TDirectory.Exists(LTempDir) then
        TDirectory.Delete(LTempDir, True);
      TAddonNet.ExtractZip(LTempZip, LTempDir);

      // The archive must carry exactly one top-level <slug>\ folder.
      LBundleDir := TPath.Combine(LTempDir, ASlug);
      if not TDirectory.Exists(LBundleDir) then
        raise EAddonIntegrity.CreateFmt(
          'archive for "%s" has no top-level "%s\" folder.', [ASlug, ASlug]);
    end;
    // An addon is a directory under a JSON manifest, and Aefos is not the only
    // one packaging that shape. addon.json stays native and keeps priority;
    // when it is absent the bundle may still be a perfectly good agent plugin -
    // Agent Plugins 1.0, Copilot or Claude, which differ from one another only
    // in where two files sit. Reading those costs a detection table and buys
    // every bundle already published elsewhere, including the marketplace a
    // user's employer keeps.
    //
    // Nothing is renamed by this: what gets installed is still an addon, still
    // recorded in the same ledger, still removed by the same uninstall. Only
    // the manifest it was read from differs.
    LFormat := TAddonPluginFormat.Detect(LBundleDir);
    if LFormat = pfAefos then
    begin
      LManifestPath := TPath.Combine(LBundleDir, 'addon.json');
      LManifest := TAddonManifestParser.ParseManifest(
        TFile.ReadAllText(LManifestPath, TEncoding.UTF8));
      if not SameText(LManifest.Slug, ASlug) then
        raise EAddonManifest.CreateFmt(
          'bundle slug "%s" does not match "%s".', [LManifest.Slug, ASlug]);
      // Version cross-check only when BOTH sides carry one. Under evergreen an
      // empty version on either side is legitimate; the sha256 verification above
      // already guarantees the bytes match. The slug guard stays unconditional.
      if (LManifest.Version <> '') and (LEntry.Version <> '') and
         not SameText(LManifest.Version, LEntry.Version) then
        raise EAddonManifest.CreateFmt(
          'bundle version "%s" does not match registry "%s".',
          [LManifest.Version, LEntry.Version]);
    end
    else if LFormat = pfNone then
      raise EAddonManifest.CreateFmt(
        'bundle "%s" carries no manifest Aefos can read (addon.json, ' +
        'plugin.json or .claude-plugin\plugin.json).', [ASlug])
    else
    begin
      ALog(Format('Reading as %s (this bundle has no addon.json) ...',
        [TAddonPluginFormat.FormatName(LFormat)]));
      // A foreign bundle carries no slug of ours to cross-check against, so the
      // registry entry is the only authority on identity - which is exactly what
      // the sha256 above already verified.
      LManifest := TAddonPluginFormat.Adopt(LBundleDir, ASlug, LFormat, ALog);
      LManifest.RequiresAefos := LEntry.RequiresAefos;
    end;

    _RequireConsent(LEntry, LManifest, AOptions, ALog);

    LFiles := TList<string>.Create;
    LRoots := TList<string>.Create;
    try
      if Length(LManifest.Install) > 0 then
      begin
        // Portal manifest: explicit source -> ~/.aefos\target_path mappings.
        _ApplyInstallMappings(LBundleDir, LManifest.Install, LFiles, LRoots,
          LArts, ALog);
        // A declared install mapping that copies NOTHING is never a success -
        // it means the bundle layout did not match addon.json. Fail loudly so a
        // silent no-op can never be recorded as "installed" again.
        if LFiles.Count = 0 then
          raise EAddonIntegrity.CreateFmt(
            'install copied no files for "%s" - the addon.json install mapping ' +
            'did not match the bundle layout.', [ASlug]);
      end
      else
      begin
        // Fixed-layout fallback (artifacts booleans): clean-replace slug dirs.
        _RemoveSlugDirs(ASlug);
        LArts := LManifest.Artifacts;
        if LArts.HasCommand then
          _InstallCommands(LBundleDir, ASlug, LFiles, LRoots, ALog);
        if LArts.HasSkill then
          _InstallSkills(LBundleDir, ASlug, LFiles, LRoots, ALog);
        if LArts.HasMcp then
        begin
          // Resolve ${ADDON_ROOT} to the absolute install dir so a raw MCP
          // spawn (no shell) can find the server command.
          _WriteMcpFragment(TPath.Combine(LBundleDir, 'mcp\server.json'),
            TPath.Combine(TAddonPaths.AddonDir(ASlug), 'mcp.json'), TAddonPaths.AddonDir(ASlug), LFiles);
          LRoots.Add(TAddonPaths.AddonDir(ASlug));
          ALog('  + mcp      ' + TPath.Combine(TAddonPaths.AddonDir(ASlug), 'mcp.json'));
        end;
        if LArts.HasTools then
        begin
          _CopyTree(TPath.Combine(LBundleDir, 'tools'),
            TPath.Combine(TAddonPaths.AddonDir(ASlug), 'tools'), LFiles);
          LRoots.Add(TAddonPaths.AddonDir(ASlug));
          ALog('  + tools    ' + TPath.Combine(TAddonPaths.AddonDir(ASlug), 'tools'));
        end;
        if LArts.HasTemplates then
        begin
          // Carry-along scaffolds (ADR-0001 §Decision 4): NOT a type, a folder the
          // addon carries. Installs scoped to the slug so the command/OKF that
          // references it resolves by slug and there is no global collision.
          _CopyTree(TPath.Combine(LBundleDir, 'templates'), TAddonPaths.TemplateDir(ASlug),
            LFiles);
          LRoots.Add(TAddonPaths.TemplateDir(ASlug));
          ALog('  + templates ' + TAddonPaths.TemplateDir(ASlug));
        end;
      end;

      LItem := Default(TInstalledAddon);
      LItem.Slug := ASlug;
      LItem.Version := LEntry.Version;
      LItem.Trust := LEntry.Trust;
      LItem.Sha256 := LEntry.Sha256;
      // Which store it came from, so update returns to the SAME one instead of
      // whichever store happens to publish the name next time.
      LItem.Source := LRow.Source;
      LItem.InstalledAt := _NowUtcIso;
      LItem.Artifacts := LArts;
      LItem.Files := LFiles.ToArray;
      LItem.Roots := LRoots.ToArray;
      TAddonLedger.Save(TAddonLedger.Upsert(TAddonLedger.Load, LItem));
      // Read the trigger names off what was actually laid down, while the roots
      // are still alive - a multi-command bundle installs /<slug>.<name>, so
      // announcing "/<slug>" would name a command that does not exist.
      LCommands := _CommandNamesFrom(LRoots);
    finally
      LRoots.Free;
      LFiles.Free;
    end;

    if LArts.HasMcp then
    begin
      _RefreshMcpAggregate;
      ALog('  * MCP server registered (plugin picks it up on next provision).');
    end;

    ALog(Format('Installed %s %s.', [ASlug, _VerLabel(LEntry.Version)]));
    if LCommands <> '' then
      ALog('  Now available in Aefos chat: ' + LCommands);
  finally
    try
      // LTempDir is always OURS - a folder bundle was copied into it, never
      // read in place - so this never reaches into a store. LStoreDir is not
      // touched here, and must not be.
      if (LTempZip <> '') and TFile.Exists(LTempZip) then
        TFile.Delete(LTempZip);
      if (LTempDir <> '') and TDirectory.Exists(LTempDir) then
        TDirectory.Delete(LTempDir, True);
    except
      // best-effort temp cleanup
    end;
  end;
end;

class procedure TAddonInstaller.Uninstall(const ASlug: string;
  const ALog: TAddonLog);
var
  LItems: TArray<TInstalledAddon>;
  LItem: TInstalledAddon;
  LRoot: string;
begin
  if not TAddonPaths.IsValidSlug(ASlug) then
    raise EAddonError.CreateFmt('invalid addon slug "%s".', [ASlug]);
  LItems := TAddonLedger.Load;
  if not TAddonLedger.TryFind(LItems, ASlug, LItem) then
    raise EAddonNotFound.CreateFmt('addon "%s" is not installed.', [ASlug]);
  // Remove exactly the target dirs recorded at install (guarded under ~/.aefos);
  // fall back to the slug dirs for a pre-Roots ledger entry.
  if Length(LItem.Roots) > 0 then
  begin
    for LRoot in LItem.Roots do
      if _UnderUserRoot(LRoot) and TDirectory.Exists(LRoot) then
        TDirectory.Delete(LRoot, True);
  end
  else
    _RemoveSlugDirs(ASlug);
  TAddonLedger.Save(TAddonLedger.Remove(LItems, ASlug));
  if LItem.Artifacts.HasMcp then
    _RefreshMcpAggregate;
  ALog(Format('Removed %s %s.', [ASlug, _VerLabel(LItem.Version)]));
end;

class procedure TAddonInstaller.Update(const ASlug: string;
  const AOptions: TInstallOptions; const ALog: TAddonLog);
var
  LItems: TArray<TInstalledAddon>;
  LItem: TInstalledAddon;
  LRow: TAddonCatalogRow;
  LEntry: TAddonRegistryEntry;
  LOpts: TInstallOptions;
begin
  LItems := TAddonLedger.Load;
  if not TAddonLedger.TryFind(LItems, ASlug, LItem) then
    raise EAddonNotFound.CreateFmt('addon "%s" is not installed.', [ASlug]);
  LRow := TAddonCatalog.ResolveOne(ASlug, _PreferredSource(AOptions, LItem));
  LEntry := LRow.Entry;
  _EnsureIdentity(LEntry);
  case LItem.DecideUpdate(LEntry) of
    uaUpToDate:
      ALog(Format('%s is already current.', [ASlug]));
    uaUpdate:
      begin
        ALog(Format('Updating %s ...', [ASlug]));
        // Clean-replace at the store's current build (install re-verifies sha).
        // The store is PINNED to the one just resolved: re-resolving inside
        // Install could land on a different store between the two calls.
        LOpts := AOptions;
        LOpts.Source := LRow.Source;
        TAddonInstaller.Install(ASlug, LOpts, ALog);
      end;
  end;
end;

class procedure TAddonInstaller.UpdateAll(const AOptions: TInstallOptions;
  const ALog: TAddonLog);
var
  LItems: TArray<TInstalledAddon>;
  LResults: TArray<TAddonCatalogResult>;
  LRow: TAddonCatalogRow;
  LEntry: TAddonRegistryEntry;
  LOpts: TInstallOptions;
  LIndex, LUpdated, LCurrent: Integer;
  LSlug: string;
  LResolved: Boolean;
begin
  LItems := TAddonLedger.Load;
  if Length(LItems) = 0 then
  begin
    ALog('No addons installed.');
    Exit;
  end;
  // Every store is read ONCE for the whole run, not once per installed addon.
  LResults := TAddonCatalog.ReadAll;
  LUpdated := 0;
  LCurrent := 0;
  for LIndex := 0 to High(LItems) do
  begin
    LSlug := LItems[LIndex].Slug;
    // One addon that cannot be resolved (store removed, name now ambiguous)
    // must not take the other twenty with it.
    LResolved := False;
    LRow := Default(TAddonCatalogRow);
    try
      LRow := TAddonCatalog.Resolve(LResults, LSlug,
        _PreferredSource(AOptions, LItems[LIndex]));
      LResolved := True;
    except
      on E: EAddonError do
        ALog(Format('  ! %s: %s - skipped.', [LSlug, E.Message]));
    end;
    if not LResolved then
      Continue;
    LEntry := LRow.Entry;
    _EnsureIdentity(LEntry);
    case LItems[LIndex].DecideUpdate(LEntry) of
      uaUpToDate:
        begin
          ALog(Format('%s is already current.', [LSlug]));
          Inc(LCurrent);
        end;
      uaUpdate:
        begin
          ALog(Format('Updating %s ...', [LSlug]));
          LOpts := AOptions;
          LOpts.Source := LRow.Source;
          TAddonInstaller.Install(LSlug, LOpts, ALog);
          Inc(LUpdated);
        end;
    end;
  end;
  ALog(Format('%d updated, %d already current.', [LUpdated, LCurrent]));
end;

class procedure TAddonInstaller.CheckUpdates(const ASlug: string;
  const ALog: TAddonLog);
var
  LItems: TArray<TInstalledAddon>;
  LResults: TArray<TAddonCatalogResult>;
  LItem: TInstalledAddon;
  LIndex: Integer;

  procedure ReportOne(const AItem: TInstalledAddon);
  var
    LRow: TAddonCatalogRow;
    LFound: TAddonRegistryEntry;
  begin
    // A dry-run reports; it never fails the run. An unresolvable slug is a
    // finding to print, exactly like "update available" is.
    try
      LRow := TAddonCatalog.Resolve(LResults, AItem.Slug, AItem.Source);
    except
      on E: EAddonError do
      begin
        ALog(Format('%s: %s', [AItem.Slug, E.Message]));
        Exit;
      end;
    end;
    LFound := LRow.Entry;
    _EnsureIdentity(LFound);
    if AItem.DecideUpdate(LFound) = uaUpToDate then
      ALog(Format('%s: current', [AItem.Slug]))
    else
      ALog(Format('%s: update available', [AItem.Slug]));
  end;

begin
  LItems := TAddonLedger.Load;
  LResults := TAddonCatalog.ReadAll;
  if ASlug <> '' then
  begin
    if not TAddonLedger.TryFind(LItems, ASlug, LItem) then
      raise EAddonNotFound.CreateFmt('addon "%s" is not installed.', [ASlug]);
    ReportOne(LItem);
    Exit;
  end;
  if Length(LItems) = 0 then
  begin
    ALog('No addons installed.');
    Exit;
  end;
  for LIndex := 0 to High(LItems) do
    ReportOne(LItems[LIndex]);
end;

class procedure TAddonInstaller.List(const ALog: TAddonLog);
var
  LItems: TArray<TInstalledAddon>;
  LIndex: Integer;
  LKinds: string;
begin
  LItems := TAddonLedger.Load;
  if Length(LItems) = 0 then
  begin
    ALog('No addons installed.');
    Exit;
  end;
  ALog(Format('%d addon(s) installed:', [Length(LItems)]));
  for LIndex := 0 to High(LItems) do
  begin
    LKinds := '';
    if LItems[LIndex].Artifacts.HasCommand then LKinds := LKinds + 'command ';
    if LItems[LIndex].Artifacts.HasSkill then LKinds := LKinds + 'skill ';
    if LItems[LIndex].Artifacts.HasMcp then LKinds := LKinds + 'mcp ';
    if LItems[LIndex].Artifacts.HasTools then LKinds := LKinds + 'tools ';
    // _VerLabel prints "current" for an evergreen (versionless) entry, never a
    // bare "v". The store is shown because with more than one configured, "which
    // review is this?" is a real question the list has to answer.
    ALog(Format('  %-28s %-11s [%s] %-10s %s',
      [LItems[LIndex].Slug, _VerLabel(LItems[LIndex].Version),
       LItems[LIndex].Trust.ToStr, LItems[LIndex].Source, Trim(LKinds)]));
  end;
end;

end.
