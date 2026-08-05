unit Aefos.Addons.Manifest;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  Aefos Addons - JSON parsers for registry.json and addon.json (contract §2/§4).

  Parsing is a pure function over a JSON string (no network, no disk) so the
  pure suite can assert it directly. A malformed document raises EAddonManifest
  with a plain-English reason.
}

interface

uses
  SysUtils,
  Aefos.Addons.Types;

type
  { Static, sealed namespace for the registry.json / addon.json JSON parsers.
    Never instantiated; the class IS the namespace. }
  TAddonManifestParser = class sealed
  public
    { Parses the whole registry.json into its addon entries. Raises
      EAddonManifest on a malformed document. Unknown fields are tolerated. }
    class function ParseRegistry(
      const AJson: string): TArray<TAddonRegistryEntry>; static;

    { Finds one slug in a parsed registry. Raises EAddonNotFound when absent. }
    class function FindEntry(const AEntries: TArray<TAddonRegistryEntry>;
      const ASlug: string): TAddonRegistryEntry; static;

    { Parses a bundle's addon.json. Raises EAddonManifest on a malformed document. }
    class function ParseManifest(const AJson: string): TAddonManifest; static;
  end;

implementation

uses
  Generics.Collections,
  Aefos.Compat.Json;

function _Str(const AObj: TJSONObject; const AKey: string): string;
var
  LVal: TJSONValue;
begin
  Result := '';
  if AObj = nil then
    Exit;
  LVal := AObj.Values[AKey];
  if LVal is TJSONString then
    Result := TJSONString(LVal).Value
  else if (LVal <> nil) and not (LVal is TJSONNull) then
    Result := LVal.Value;
end;

function _Bool(const AObj: TJSONObject; const AKey: string): Boolean;
var
  LVal: TJSONValue;
begin
  Result := False;
  if AObj = nil then
    Exit;
  LVal := AObj.Values[AKey];
  if LVal is TJSONBool then
    Result := TJSONBool(LVal).AsBoolean;
end;

function _RequiresAefos(const AObj: TJSONObject): string;
var
  LReq: TJSONValue;
begin
  Result := '';
  if AObj = nil then
    Exit;
  LReq := AObj.Values['requirements'];
  if LReq is TJSONObject then
    Result := _Str(TJSONObject(LReq), 'aefos_version');
end;

function _ParseEntry(const AObj: TJSONObject): TAddonRegistryEntry;
begin
  Result := Default(TAddonRegistryEntry);
  Result.Slug := _Str(AObj, 'slug');
  Result.Name := _Str(AObj, 'name');
  Result.Version := _Str(AObj, 'version');
  Result.Description := _Str(AObj, 'description');
  Result.Kind := TAddonKind.Parse(_Str(AObj, 'type'));
  Result.Trust := TAddonTrust.Parse(_Str(AObj, 'trust'));
  Result.Url := _Str(AObj, 'url');
  Result.Sha256 := LowerCase(Trim(_Str(AObj, 'sha256')));
  Result.RequiresAefos := _RequiresAefos(AObj);
  if Result.Slug = '' then
    raise EAddonManifest.Create('registry entry is missing "slug".');
  // "version" is OPTIONAL (ADR-0001: evergreen distribution). An entry with no
  // version is valid - the sha256 below is the identity. slug/url/sha256 stay
  // required.
  if Result.Url = '' then
    raise EAddonManifest.CreateFmt(
      'registry entry "%s" is missing "url".', [Result.Slug]);
  if Result.Sha256 = '' then
    raise EAddonManifest.CreateFmt(
      'registry entry "%s" is missing "sha256".', [Result.Slug]);
end;

class function TAddonManifestParser.ParseRegistry(
  const AJson: string): TArray<TAddonRegistryEntry>;
var
  LRoot: TJSONValue;
  LObj: TJSONObject;
  LArr: TJSONArray;
  LIndex: Integer;
  LList: TList<TAddonRegistryEntry>;
begin
  LRoot := TJSONObject.ParseJSONValue(AJson);
  if not (LRoot is TJSONObject) then
  begin
    LRoot.Free;
    raise EAddonManifest.Create('registry.json is not a JSON object.');
  end;
  try
    LObj := TJSONObject(LRoot);
    if not (LObj.Values['addons'] is TJSONArray) then
      raise EAddonManifest.Create('registry.json has no "addons" array.');
    LArr := TJSONArray(LObj.Values['addons']);
    LList := TList<TAddonRegistryEntry>.Create;
    try
      for LIndex := 0 to LArr.Count - 1 do
        if LArr.Items[LIndex] is TJSONObject then
          LList.Add(_ParseEntry(TJSONObject(LArr.Items[LIndex])));
      Result := LList.ToArray;
    finally
      LList.Free;
    end;
  finally
    LRoot.Free;
  end;
end;

class function TAddonManifestParser.FindEntry(
  const AEntries: TArray<TAddonRegistryEntry>;
  const ASlug: string): TAddonRegistryEntry;
var
  LIndex: Integer;
begin
  for LIndex := 0 to High(AEntries) do
    if SameText(AEntries[LIndex].Slug, ASlug) then
      Exit(AEntries[LIndex]);
  raise EAddonNotFound.CreateFmt('addon "%s" is not in the registry.', [ASlug]);
end;

// Reads every { source, target_path } object out of AArr into AList. Non-object
// items and entries missing either key are skipped (never raises on a bad key).
procedure _CollectInstallArray(const AArr: TJSONArray;
  const AList: TList<TAddonInstallMapping>);
var
  LIndex: Integer;
  LItem: TJSONObject;
  LMap: TAddonInstallMapping;
begin
  if AArr = nil then
    Exit;
  for LIndex := 0 to AArr.Count - 1 do
  begin
    if not (AArr.Items[LIndex] is TJSONObject) then
      Continue;
    LItem := TJSONObject(AArr.Items[LIndex]);
    LMap.Source := _Str(LItem, 'source');
    LMap.TargetPath := _Str(LItem, 'target_path');
    if (LMap.Source <> '') and (LMap.TargetPath <> '') then
      AList.Add(LMap);
  end;
end;

// Parses the portal's `install` mappings. TWO wire shapes are accepted:
//   1. a FLAT array:   "install": [{ source, target_path }, ...]
//   2. an OBJECT with per-kind sub-arrays (the shape the portal publishes):
//      "install": { "commands": [...], "skills": [...], "addons": [...] }
// In the object form every sub-array is flattened into one mapping list. Absent
// or malformed entries are skipped; an empty result means "use the artifacts
// layout". Every cast is guarded (never a bare `as` that could raise).
function _ParseInstall(const AObj: TJSONObject): TArray<TAddonInstallMapping>;
var
  LVal, LSub: TJSONValue;
  LInstallObj: TJSONObject;
  LPair: TJSONPair;
  LList: TList<TAddonInstallMapping>;
begin
  LVal := AObj.Values['install'];
  LList := TList<TAddonInstallMapping>.Create;
  try
    if LVal is TJSONArray then
      // Shape 1: a flat array of { source, target_path }.
      _CollectInstallArray(TJSONArray(LVal), LList)
    else if LVal is TJSONObject then
    begin
      // Shape 2: an object whose every value is a sub-array (commands/skills/
      // addons/...). Flatten each sub-array; ignore any non-array member.
      LInstallObj := TJSONObject(LVal);
      for LPair in LInstallObj do
      begin
        LSub := LPair.JsonValue;
        if LSub is TJSONArray then
          _CollectInstallArray(TJSONArray(LSub), LList);
      end;
    end;
    if LList.Count = 0 then
      Exit(nil);
    Result := LList.ToArray;
  finally
    LList.Free;
  end;
end;

class function TAddonManifestParser.ParseManifest(
  const AJson: string): TAddonManifest;
var
  LRoot: TJSONValue;
  LObj: TJSONObject;
  LArt: TJSONValue;
  LArtObj: TJSONObject;
begin
  LRoot := TJSONObject.ParseJSONValue(AJson);
  if not (LRoot is TJSONObject) then
  begin
    LRoot.Free;
    raise EAddonManifest.Create('addon.json is not a JSON object.');
  end;
  try
    LObj := TJSONObject(LRoot);
    Result := Default(TAddonManifest);
    Result.Slug := _Str(LObj, 'slug');
    Result.Version := _Str(LObj, 'version');
    Result.Name := _Str(LObj, 'name');
    Result.Description := _Str(LObj, 'description');
    Result.Trust := TAddonTrust.Parse(_Str(LObj, 'trust'));
    Result.RequiresAefos := _RequiresAefos(LObj);
    LArt := LObj.Values['artifacts'];
    if LArt is TJSONObject then
    begin
      LArtObj := TJSONObject(LArt);
      Result.Artifacts.HasCommand := _Bool(LArtObj, 'command');
      Result.Artifacts.HasSkill := _Bool(LArtObj, 'skill');
      Result.Artifacts.HasMcp := _Bool(LArtObj, 'mcp');
      Result.Artifacts.HasTools := _Bool(LArtObj, 'tools');
      Result.Artifacts.HasTemplates := _Bool(LArtObj, 'templates');
    end;
    Result.Install := _ParseInstall(LObj);
    if Result.Slug = '' then
      raise EAddonManifest.Create('addon.json is missing "slug".');
    if Result.Version = '' then
      raise EAddonManifest.Create('addon.json is missing "version".');
  finally
    LRoot.Free;
  end;
end;

end.
