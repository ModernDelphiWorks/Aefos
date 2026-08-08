unit Aefos.Addons.Catalog;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

(*
  Aefos Addons - the merged list of what can be installed.

  This is the contract the IDE dialog will consume: ask the CLI what is
  available, get one row per addon with the store it came from. Written CLI-side
  on purpose - reading a store is real logic (fetch, parse, tolerate a store
  being down) and having it in two languages would mean fixing every bug twice.
  The plugin spawns aefos.exe and parses JSON; that is the whole coupling.

  WHY EACH ROW CARRIES ITS SOURCE. With more than one store, a bare name stops
  being an identity: the gallery and a company store may both publish "review".
  Carrying the source turns what would be a collision to guess about into two
  honest rows, and lets the install that follows say exactly which one it meant.

  A STORE THAT IS DOWN MUST NOT TAKE THE LIST WITH IT. Each source is read
  independently and a failure becomes a row-less error string, not an exception:
  a user whose company VPN is off should still see the gallery, with a line
  saying the other store could not be read. The alternative - one unreachable
  store and an empty dialog - looks like "there is nothing to install".
*)

interface

uses
  SysUtils,
  Aefos.Addons.Types,
  Aefos.Addons.Sources;

type
  { What one store answered. Error is empty when it answered normally. }
  TAddonCatalogResult = record
    Source: TAddonSource;
    Rows: TArray<TAddonCatalogRow>;
    Error: string;
  end;

  { Static, sealed namespace; never instantiated. }
  TAddonCatalog = class sealed
  public
    { Reads one store. Never raises for a store-side problem - the reason lands
      in Error so the caller can report it beside the stores that did answer. }
    class function ReadSource(const ASource: TAddonSource): TAddonCatalogResult; static;

    { Reads every ENABLED configured store, in configuration order. }
    class function ReadAll: TArray<TAddonCatalogResult>; static;

    { The merged catalogue as JSON - what the IDE dialog reads. Errors travel in
      the same document so the UI can show a store as unreachable instead of
      quietly listing fewer addons than exist. }
    class function ToJson(const AResults: TArray<TAddonCatalogResult>): string; static;

    { Finds ASlug across AResults. APreferSource, when non-empty, restricts the
      search to that store - which is how `--source` and the ledger's recorded
      source both say "this one, not the same name somewhere else".

      Raises rather than picking for you when the slug is in more than one
      store: with two stores a bare name is not an identity, and quietly
      choosing would install a stranger's addon under the name of the one the
      user meant. The message names the candidates so the fix is one flag away.

      A store that FAILED is reported inside the not-found message. "addon not
      found" while the store holding it was unreachable is a lie the user would
      act on. }
    class function Resolve(const AResults: TArray<TAddonCatalogResult>;
      const ASlug, APreferSource: string): TAddonCatalogRow; static;

    { Resolve over a freshly read catalogue - the single-shot form. }
    class function ResolveOne(const ASlug, APreferSource: string): TAddonCatalogRow; static;

    { Gives an entry the sha256 the rest of the system compares, when the store
      published none. Only a FOLDER bundle can be in that position - it is a
      directory, not a release - and the answer is measured from the tree.

      Lives here rather than in the installer because the catalogue needs the
      same answer to say whether an installed addon is current, and one
      measurement with two owners is how the two drift apart. }
    class procedure EnsureIdentity(var AEntry: TAddonRegistryEntry); static;
  end;

implementation

uses
  Classes,
  IOUtils,
  Types,
  Aefos.Compat.Json,
  Aefos.Compat.JsonFormat,
  Aefos.Addons.Manifest,
  Aefos.Addons.Ledger,
  Aefos.Addons.Net;

function _Str(const AObj: TJSONObject; const AKey: string): string;
var
  LVal: TJSONValue;
begin
  Result := '';
  if AObj = nil then
    Exit;
  LVal := AObj.Values[AKey];
  if LVal is TJSONString then
    Result := TJSONString(LVal).Value;
end;

{ Reads a bundle folder into a catalogue entry. The slug is the FOLDER name -
  it is what `aefos install` will be told and what uninstall will remove, so it
  has to be the thing the user can see and type, not a field inside a file. }
function _EntryFromDir(const ADir: string; out AEntry: TAddonRegistryEntry): Boolean;
var
  LManifestPath, LJson: string;
  LVal: TJSONValue;
  LObj: TJSONObject;
begin
  Result := False;
  // One format, ours: a folder is a bundle when it carries addon.json. Anything
  // else in a store folder is simply not an addon (a README, a build script),
  // which is why this returns False instead of raising.
  LManifestPath := TPath.Combine(ADir, 'addon.json');
  if not TFile.Exists(LManifestPath) then
    Exit;
  AEntry := Default(TAddonRegistryEntry);
  AEntry.Slug := TPath.GetFileName(ExcludeTrailingPathDelimiter(ADir));
  AEntry.Url := ADir;                       // a path store installs from disk
  AEntry.Trust := atCommunity;              // never "official" unless we said so
  AEntry.Name := AEntry.Slug;
  // A folder store has no registry to declare a type, so the type is MEASURED
  // from what the bundle actually carries - the same instinct as everywhere
  // else here. An MCP config makes it an MCP server, a tools folder makes it
  // tools, and anything else is a plain addon.
  if TFile.Exists(TPath.Combine(ADir, TPath.Combine('mcp', 'server.json'))) then
    AEntry.Kind := akMcp
  else if TDirectory.Exists(TPath.Combine(ADir, 'tools')) then
    AEntry.Kind := akTool
  else
    AEntry.Kind := akCommand;
  AEntry.KindName := AEntry.Kind.ToStr;
  LJson := '';
  try
    LJson := TFile.ReadAllText(LManifestPath, TEncoding.UTF8);
  except
    LJson := '';
  end;
  if LJson <> '' then
  begin
    LVal := TJSONObject.ParseJSONValue(LJson);
    try
      if LVal is TJSONObject then
      begin
        LObj := TJSONObject(LVal);
        AEntry.Version := _Str(LObj, 'version');
        AEntry.Description := _Str(LObj, 'description');
        if _Str(LObj, 'displayName') <> '' then
          AEntry.Name := _Str(LObj, 'displayName')
        else if _Str(LObj, 'name') <> '' then
          AEntry.Name := _Str(LObj, 'name');
      end;
    finally
      LVal.Free;
    end;
  end;
  Result := True;
end;

function _IsHttp(const ARef: string): Boolean;
begin
  Result := SameText(Copy(ARef, 1, 7), 'http://') or
            SameText(Copy(ARef, 1, 8), 'https://');
end;

// A registry may publish a RELATIVE url ("addons/x/x-1.0.0.zip"), and relative
// to WHAT was never asked while there was only one registry. With stores it has
// to be asked, and there is only one defensible answer: relative to the store
// that published it. Anchoring on the built-in gallery instead - which is what
// happened before this - pointed a company store's bundle at our download
// directory, and the error it produced named a path that never existed
// anywhere ("D:\repo\https:\raw.githubusercontent.com\...").
function _AbsolutizeUrl(const ABase, AUrl: string): string;
var
  LCut: Integer;
begin
  Result := AUrl;
  if (Result = '') or _IsHttp(Result) or
     SameText(Copy(Result, 1, 7), 'file://') then
    Exit;
  if TPath.IsPathRooted(Result) then
    Exit;
  if _IsHttp(ABase) then
  begin
    LCut := LastDelimiter('/', ABase);
    if LCut > 0 then
      Result := Copy(ABase, 1, LCut) + Result;
    Exit;
  end;
  if ABase <> '' then
    Result := TPath.GetFullPath(TPath.Combine(ExtractFileDir(ABase), Result));
end;

// "Official" is a fact about WHERE an addon came from, and until now it was a
// word the publisher wrote about itself. That mattered beyond the badge: the
// install consent gate skips the prompt for official-trust bundles, so any
// store whose registry.json said "trust": "official" could install an MCP
// server or a tools folder - code that then runs on the machine - without ever
// asking. So trust is clamped at the door: only the official store may hand
// out atOfficial, and every other store's rows are community whatever they
// claim. A store can still be trusted by the user; it just cannot self-declare.
procedure _ClampTrust(var AEntry: TAddonRegistryEntry;
  const ASource: TAddonSource);
begin
  if not ASource.Builtin then
    AEntry.Trust := atCommunity;
end;

// A store that could not be read may be the store that HAS the slug, so the
// not-found message has to carry it. Silence here would send the user hunting
// for a typo in a name that is perfectly correct.
function _ErrSuffix(const AErrors: string): string;
begin
  if AErrors = '' then
    Result := ''
  else
    Result := ' (a store could not be read, and may be the one that has it - ' +
      AErrors + ')';
end;

class function TAddonCatalog.ReadSource(
  const ASource: TAddonSource): TAddonCatalogResult;
var
  LEntries: TArray<TAddonRegistryEntry>;
  LDirs: TStringDynArray;
  LEntry: TAddonRegistryEntry;
  LIndex, LCount: Integer;
  LUrl: string;
begin
  Result := Default(TAddonCatalogResult);
  Result.Source := ASource;
  try
    case ASource.Kind of
      askAefos:
        begin
          LUrl := ASource.Location;
          if Trim(LUrl) = '' then
            LUrl := TAddonNet.RegistryUrl;   // the built-in gallery
          LEntries := TAddonManifestParser.ParseRegistry(
            TAddonNet.DownloadText(LUrl));
          SetLength(Result.Rows, Length(LEntries));
          for LIndex := 0 to High(LEntries) do
          begin
            Result.Rows[LIndex].Source := ASource.Name;
            Result.Rows[LIndex].Entry := LEntries[LIndex];
            Result.Rows[LIndex].Entry.Url :=
              _AbsolutizeUrl(LUrl, Result.Rows[LIndex].Entry.Url);
            _ClampTrust(Result.Rows[LIndex].Entry, ASource);
          end;
        end;
      askPath:
        begin
          if not TDirectory.Exists(ASource.Location) then
            raise EAddonError.CreateFmt('folder "%s" does not exist.',
              [ASource.Location]);
          LDirs := TDirectory.GetDirectories(ASource.Location);
          SetLength(Result.Rows, Length(LDirs));
          LCount := 0;
          for LIndex := 0 to High(LDirs) do
          begin
            if not _EntryFromDir(LDirs[LIndex], LEntry) then
              Continue;   // not a bundle - a store folder may hold other things
            Result.Rows[LCount].Source := ASource.Name;
            Result.Rows[LCount].Entry := LEntry;
            Inc(LCount);
          end;
          SetLength(Result.Rows, LCount);
        end;
    else
      // Named in the config format from the start so adding it later needs no
      // migration, and refused clearly until then. A source that silently
      // returns nothing reads as an empty store, which is a lie.
      raise EAddonError.Create(
        'git sources are not readable yet - use a path source, or the gallery.');
    end;
  except
    on E: Exception do
    begin
      SetLength(Result.Rows, 0);
      Result.Error := E.Message;
    end;
  end;
end;

class function TAddonCatalog.ReadAll: TArray<TAddonCatalogResult>;
var
  LSources: TArray<TAddonSource>;
  LIndex, LCount: Integer;
begin
  LSources := TAddonSources.Load;
  SetLength(Result, Length(LSources));
  LCount := 0;
  for LIndex := 0 to High(LSources) do
  begin
    if not LSources[LIndex].Enabled then
      Continue;
    Result[LCount] := ReadSource(LSources[LIndex]);
    Inc(LCount);
  end;
  SetLength(Result, LCount);
end;

class function TAddonCatalog.Resolve(
  const AResults: TArray<TAddonCatalogResult>;
  const ASlug, APreferSource: string): TAddonCatalogRow;
var
  LI, LJ, LFound: Integer;
  LCandidates, LErrors: string;
begin
  Result := Default(TAddonCatalogRow);
  LFound := 0;
  LCandidates := '';
  LErrors := '';
  for LI := 0 to High(AResults) do
  begin
    if AResults[LI].Error <> '' then
    begin
      if LErrors <> '' then
        LErrors := LErrors + '; ';
      LErrors := LErrors + AResults[LI].Source.Name + ': ' + AResults[LI].Error;
      Continue;
    end;
    if (APreferSource <> '') and
       not SameText(AResults[LI].Source.Name, APreferSource) then
      Continue;
    for LJ := 0 to High(AResults[LI].Rows) do
    begin
      if not SameText(AResults[LI].Rows[LJ].Entry.Slug, ASlug) then
        Continue;
      if LFound = 0 then
        Result := AResults[LI].Rows[LJ];
      Inc(LFound);
      if LCandidates <> '' then
        LCandidates := LCandidates + ', ';
      LCandidates := LCandidates + AResults[LI].Rows[LJ].Source;
    end;
  end;

  if LFound > 1 then
    raise EAddonError.CreateFmt(
      '"%s" exists in more than one store (%s). Say which one with ' +
      '--source <name>.', [ASlug, LCandidates]);

  if LFound = 0 then
  begin
    if APreferSource <> '' then
      raise EAddonNotFound.CreateFmt('addon "%s" is not in store "%s".%s',
        [ASlug, APreferSource, _ErrSuffix(LErrors)]);
    raise EAddonNotFound.CreateFmt('addon "%s" is not in any configured store.%s',
      [ASlug, _ErrSuffix(LErrors)]);
  end;
end;

class function TAddonCatalog.ResolveOne(
  const ASlug, APreferSource: string): TAddonCatalogRow;
begin
  Result := Resolve(ReadAll, ASlug, APreferSource);
end;

class procedure TAddonCatalog.EnsureIdentity(var AEntry: TAddonRegistryEntry);
begin
  if (Trim(AEntry.Sha256) = '') and TDirectory.Exists(AEntry.Url) then
    AEntry.Sha256 := TAddonNet.Sha256OfTree(AEntry.Url);
end;

// The button's own answer: available / installed / update. Computed here and
// not in the dialog, because deciding it needs the sha comparison and a folder
// bundle's MEASURED identity - logic that must not exist twice.
//
// The identity is measured only for rows that are actually installed, so the
// cost is bounded by what the user has rather than by how big the store is.
procedure _AddState(const AObj: TJSONObject;
  const AInstalled: TArray<TInstalledAddon>; const ARow: TAddonCatalogRow);
var
  LIndex: Integer;
  LItem: TInstalledAddon;
  LEntry: TAddonRegistryEntry;
  LHit: Boolean;
begin
  LHit := False;
  LItem := Default(TInstalledAddon);
  for LIndex := 0 to High(AInstalled) do
  begin
    if not SameText(AInstalled[LIndex].Slug, ARow.Entry.Slug) then
      Continue;
    // Slug alone is not identity once there are stores: the same name in two
    // stores is two different addons, and only the one actually installed may
    // claim the row. An empty recorded source is a pre-stores ledger, which
    // matched by slug and still does.
    if (AInstalled[LIndex].Source <> '') and
       not SameText(AInstalled[LIndex].Source, ARow.Source) then
      Continue;
    LItem := AInstalled[LIndex];
    LHit := True;
    Break;
  end;
  AObj.AddPair('installed', TJSONBool.Create(LHit));
  if not LHit then
  begin
    AObj.AddPair('state', 'available');
    Exit;
  end;
  AObj.AddPair('installedVersion', LItem.Version);
  LEntry := ARow.Entry;
  TAddonCatalog.EnsureIdentity(LEntry);
  if LItem.DecideUpdate(LEntry) = uaUpToDate then
    AObj.AddPair('state', 'installed')
  else
    AObj.AddPair('state', 'update');
end;

class function TAddonCatalog.ToJson(
  const AResults: TArray<TAddonCatalogResult>): string;
var
  LRoot, LObj: TJSONObject;
  LAddons, LErrors: TJSONArray;
  LInstalled: TArray<TInstalledAddon>;
  LEntry: TAddonRegistryEntry;
  LI, LJ: Integer;
begin
  LInstalled := TAddonLedger.Load;
  LRoot := TJSONObject.Create;
  try
    LAddons := TJSONArray.Create;
    LRoot.AddPair('addons', LAddons);
    LErrors := TJSONArray.Create;
    LRoot.AddPair('errors', LErrors);
    for LI := 0 to High(AResults) do
    begin
      if AResults[LI].Error <> '' then
      begin
        LObj := TJSONObject.Create;
        LObj.AddPair('source', AResults[LI].Source.Name);
        if AResults[LI].Source.Builtin then
          LObj.AddPair('origin', 'official')
        else
          LObj.AddPair('origin', 'custom');
        LObj.AddPair('message', AResults[LI].Error);
        LErrors.AddElement(LObj);
        Continue;
      end;
      for LJ := 0 to High(AResults[LI].Rows) do
      begin
        LEntry := AResults[LI].Rows[LJ].Entry;
        LObj := TJSONObject.Create;
        LObj.AddPair('source', AResults[LI].Rows[LJ].Source);
        // Where it came from, as a fact rather than a claim: the dialog splits
        // Official from Custom on this, and only the official store can be on
        // the left of that line.
        if AResults[LI].Source.Builtin then
          LObj.AddPair('origin', 'official')
        else
          LObj.AddPair('origin', 'custom');
        LObj.AddPair('slug', LEntry.Slug);
        LObj.AddPair('name', LEntry.Name);
        LObj.AddPair('version', LEntry.Version);
        LObj.AddPair('description', LEntry.Description);
        LObj.AddPair('trust', LEntry.Trust.ToStr);
        // The type as the store spelled it: the dialog builds one group per
        // distinct value, so a store publishing a type nobody has seen gets a
        // group of its own with nothing here to change.
        LObj.AddPair('kind', LEntry.KindName);
        // What the user would see on the button. Answering it HERE means the
        // dialog makes one call and never has to reconcile two lists itself.
        _AddState(LObj, LInstalled, AResults[LI].Rows[LJ]);
        LAddons.AddElement(LObj);
      end;
    end;
    Result := LRoot.Format(2);
  finally
    LRoot.Free;
  end;
end;

end.
