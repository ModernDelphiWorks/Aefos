unit Aefos.Addons.Sources;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

(*
  Aefos Addons - where the catalogue comes from.

  Until now there was exactly one place to install from: the Aefos gallery, its
  URL compiled in. That is fine for a hobby install and useless at a company,
  which keeps its own bundles in its own repository and cannot publish them to
  a public gallery to use them.

  So the sources are a LIST, not a setting. The official gallery and a private
  store are not alternatives - a user wants both at once, and each row in the
  catalogue remembers which store it came from. That is also what removes the
  ambiguity a single flat namespace would create: two stores may each ship a
  "review" addon, and with the source recorded they are simply two rows, not a
  collision to guess about.

  ONE FILE, TWO READERS. sources.json lives under ~/.aefos, which the CLI already
  owns and creates. Tools -> Options writes it and this reads it: the same bytes,
  no second copy of the truth to drift. It is deliberately NOT part of the shared
  config.json - that file already has two writers, and a third would be asking
  for the lossy-write bug we have already paid for once.

  KINDS. A source says how to READ AN INDEX, not what format the bundles are in;
  bundle format is measured from the bundle itself (Aefos.Addons.PluginFormat).

    aefos  - a registry.json in the Aefos gallery shape, fetched over HTTP.
    path   - a folder on disk (or a UNC share). Every subfolder carrying a
             manifest we recognise is one entry. A company share is a store.
    git    - a repository index fetched over HTTP. Kept in the enum so the
             config format does not have to change when it lands, and reported
             honestly as unsupported until then rather than failing obscurely.

  Absent file = the gallery alone, which is exactly today's behaviour. Nobody
  has to configure anything to keep what they already had.
*)

interface

uses
  SysUtils,
  Aefos.Addons.Types;

type
  { How a source's index is read. Not the bundle format - that is measured. }
  TAddonSourceKind = (askAefos, askPath, askGit);

  { One configured store. }
  TAddonSource = record
    Name: string;      // short id, used by --source and shown in the catalogue
    Kind: TAddonSourceKind;
    Location: string;  // URL for aefos/git, directory for path
    Enabled: Boolean;
  end;

  { One row of the merged catalogue: a registry entry plus where it came from. }
  TAddonCatalogRow = record
    Source: string;
    Entry: TAddonRegistryEntry;
  end;

  { Static, sealed namespace; never instantiated. }
  TAddonSources = class sealed
  public
    { Absolute path of sources.json (it may not exist). }
    class function ConfigPath: string; static;

    { The configured sources. A missing or unreadable file yields the single
      built-in gallery, so the CLI keeps working with no configuration at all. }
    class function Load: TArray<TAddonSource>; static;

    { Writes the list. Used by `aefos source add/remove` and, later, by the
      Options page - both go through here so the file has one writer shape. }
    class procedure Save(const ASources: TArray<TAddonSource>); static;

    { The built-in gallery row, which Load returns when nothing is configured.
      Named Builtin rather than Default because Default() is an intrinsic: inside
      the method the compiler resolved Default(TAddonSource) to the method itself. }
    class function Builtin: TAddonSource; static;

    { Parses "aefos"/"path"/"git"; anything else raises, because a source whose
      kind we guessed would read the wrong thing silently. }
    class function ParseKind(const AValue: string): TAddonSourceKind; static;
    class function KindToStr(const AKind: TAddonSourceKind): string; static;
  end;

implementation

uses
  Classes,
  IOUtils,
  Aefos.Compat.Json,
  Aefos.Compat.JsonFormat,
  Aefos.Addons.Paths;

const
  CFileName = 'sources.json';
  CDefaultName = 'aefos';

class function TAddonSources.ConfigPath: string;
begin
  Result := TPath.Combine(TAddonPaths.UserRoot, CFileName);
end;

class function TAddonSources.KindToStr(const AKind: TAddonSourceKind): string;
begin
  case AKind of
    askPath: Result := 'path';
    askGit:  Result := 'git';
  else
    Result := 'aefos';
  end;
end;

class function TAddonSources.ParseKind(const AValue: string): TAddonSourceKind;
begin
  if SameText(AValue, 'aefos') or (AValue = '') then
    Result := askAefos
  else if SameText(AValue, 'path') then
    Result := askPath
  else if SameText(AValue, 'git') then
    Result := askGit
  else
    raise EAddonManifest.CreateFmt(
      'unknown source kind "%s" in %s (use aefos, path or git).',
      [AValue, ConfigPath]);
end;

class function TAddonSources.Builtin: TAddonSource;
begin
  Result := Default(TAddonSource);
  Result.Name := CDefaultName;
  Result.Kind := askAefos;
  Result.Location := '';    // empty => TAddonNet.RegistryUrl, the built-in one
  Result.Enabled := True;
end;

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

function _BoolOrTrue(const AObj: TJSONObject; const AKey: string): Boolean;
var
  LVal: TJSONValue;
begin
  // Absent means enabled: a source someone bothered to add is on unless they
  // said otherwise, and a typo in the key must not silently hide a store.
  Result := True;
  if AObj = nil then
    Exit;
  LVal := AObj.Values[AKey];
  if LVal is TJSONBool then
    Result := TJSONBool(LVal).AsBoolean;
end;

class function TAddonSources.Load: TArray<TAddonSource>;
var
  LPath, LText: string;
  LVal, LListVal: TJSONValue;
  LArr: TJSONArray;
  LObj: TJSONObject;
  LIndex, LCount: Integer;
begin
  SetLength(Result, 0);
  LPath := ConfigPath;
  if not TFile.Exists(LPath) then
    Exit(TArray<TAddonSource>.Create(Builtin));
  try
    LText := TFile.ReadAllText(LPath, TEncoding.UTF8);
  except
    Exit(TArray<TAddonSource>.Create(Builtin));
  end;
  LVal := TJSONObject.ParseJSONValue(LText);
  try
    if not (LVal is TJSONObject) then
      Exit(TArray<TAddonSource>.Create(Builtin));
    LListVal := TJSONObject(LVal).Values['sources'];
    if not (LListVal is TJSONArray) then
      Exit(TArray<TAddonSource>.Create(Builtin));
    LArr := TJSONArray(LListVal);
    LCount := 0;
    SetLength(Result, LArr.Count);
    for LIndex := 0 to LArr.Count - 1 do
    begin
      if not (LArr.Items[LIndex] is TJSONObject) then
        Continue;
      LObj := TJSONObject(LArr.Items[LIndex]);
      Result[LCount].Name := _Str(LObj, 'name');
      if Result[LCount].Name = '' then
        Continue;                       // a nameless store cannot be referred to
      Result[LCount].Kind := ParseKind(_Str(LObj, 'kind'));
      Result[LCount].Location := _Str(LObj, 'location');
      if Result[LCount].Location = '' then
        Result[LCount].Location := _Str(LObj, 'url');   // friendlier alias
      Result[LCount].Enabled := _BoolOrTrue(LObj, 'enabled');
      Inc(LCount);
    end;
    SetLength(Result, LCount);
  finally
    LVal.Free;
  end;
  if Length(Result) = 0 then
    Result := TArray<TAddonSource>.Create(Builtin);
end;

class procedure TAddonSources.Save(const ASources: TArray<TAddonSource>);
var
  LRoot, LItem: TJSONObject;
  LArr: TJSONArray;
  LIndex: Integer;
begin
  LRoot := TJSONObject.Create;
  try
    LArr := TJSONArray.Create;
    LRoot.AddPair('sources', LArr);
    for LIndex := 0 to High(ASources) do
    begin
      LItem := TJSONObject.Create;
      LItem.AddPair('name', ASources[LIndex].Name);
      LItem.AddPair('kind', KindToStr(ASources[LIndex].Kind));
      LItem.AddPair('location', ASources[LIndex].Location);
      LItem.AddPair('enabled', TJSONBool.Create(ASources[LIndex].Enabled));
      LArr.AddElement(LItem);
    end;
    ForceDirectories(TAddonPaths.UserRoot);
    TFile.WriteAllBytes(ConfigPath, TEncoding.UTF8.GetBytes(LRoot.Format(2)));
  finally
    LRoot.Free;
  end;
end;

end.
