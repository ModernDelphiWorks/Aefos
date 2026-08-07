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
  end;

implementation

uses
  Classes,
  IOUtils,
  Types,
  Aefos.Compat.Json,
  Aefos.Compat.JsonFormat,
  Aefos.Addons.Manifest,
  Aefos.Addons.Net,
  Aefos.Addons.PluginFormat;

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
  LFormat: TPluginFormat;
  LJson: string;
  LVal: TJSONValue;
  LObj: TJSONObject;
begin
  Result := False;
  LFormat := TAddonPluginFormat.Detect(ADir);
  if LFormat = pfNone then
    Exit;
  AEntry := Default(TAddonRegistryEntry);
  AEntry.Slug := TPath.GetFileName(ExcludeTrailingPathDelimiter(ADir));
  AEntry.Url := ADir;                       // a path store installs from disk
  AEntry.Trust := atCommunity;              // never "official" unless we said so
  AEntry.Name := AEntry.Slug;
  LJson := '';
  try
    if TFile.Exists(TAddonPluginFormat.ManifestPathOf(ADir, LFormat)) then
      LJson := TFile.ReadAllText(
        TAddonPluginFormat.ManifestPathOf(ADir, LFormat), TEncoding.UTF8);
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

class function TAddonCatalog.ToJson(
  const AResults: TArray<TAddonCatalogResult>): string;
var
  LRoot, LObj: TJSONObject;
  LAddons, LErrors: TJSONArray;
  LI, LJ: Integer;
begin
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
        LObj.AddPair('message', AResults[LI].Error);
        LErrors.AddElement(LObj);
        Continue;
      end;
      for LJ := 0 to High(AResults[LI].Rows) do
      begin
        LObj := TJSONObject.Create;
        LObj.AddPair('source', AResults[LI].Rows[LJ].Source);
        LObj.AddPair('slug', AResults[LI].Rows[LJ].Entry.Slug);
        LObj.AddPair('name', AResults[LI].Rows[LJ].Entry.Name);
        LObj.AddPair('version', AResults[LI].Rows[LJ].Entry.Version);
        LObj.AddPair('description', AResults[LI].Rows[LJ].Entry.Description);
        LObj.AddPair('trust', AResults[LI].Rows[LJ].Entry.Trust.ToStr);
        LAddons.AddElement(LObj);
      end;
    end;
    Result := LRoot.Format(2);
  finally
    LRoot.Free;
  end;
end;

end.
