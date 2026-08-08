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

  KINDS. A source says how to READ AN INDEX. The bundles themselves are always
  in the one Aefos format (addon.json - docs\addons-contract.md).

    aefos  - a registry.json in the Aefos gallery shape, fetched over HTTP.
    path   - a folder on disk (or a UNC share). Every subfolder carrying an
             addon.json is one entry. A company share is a store.
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

  { One store. }
  TAddonSource = record
    Name: string;      // short id, used by --source and shown in the catalogue
    Kind: TAddonSourceKind;
    Location: string;  // URL for aefos/git, directory for path
    Enabled: Boolean;
    { True for the ONE official store, which is not configured and cannot be
      repointed. Everything else is a store somebody added, and the difference
      is load-bearing rather than cosmetic - see Load. }
    Builtin: Boolean;
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

    { Every store: the OFFICIAL one first, always, then whatever sources.json
      adds. The official store is not part of the file and cannot be removed
      from it - configuring a company store must not cost you the gallery,
      which is exactly what a list that REPLACED the default used to do.

      An entry named "aefos" may only turn the official store OFF. It cannot
      repoint it: a store you can silently repoint is the whole supply-chain
      risk, and "official" has to mean "came from the official store" rather
      than "said it was official". (The offline installer's escape hatch stays
      where it was, in %AEFOS_ADDONS_REGISTRY%, which is deliberate and local.) }
    class function Load: TArray<TAddonSource>; static;

    { Writes the list. Every writer goes through here so the file has one writer
      shape - including the store window, which edits the list by running the
      CLI rather than writing the file itself. }
    class procedure Save(const ASources: TArray<TAddonSource>); static;

    { The three edits, each Load-modify-Save so the file is never half a list.
      They RAISE on a refusal (EAddonManifest) instead of returning a flag: every
      caller here reports errors the same way, and a silently ignored edit in a
      store list is the kind of thing nobody notices until an install goes to the
      wrong place. }
    class procedure Add(const AName, AKind, ALocation: string); static;
    class procedure Remove(const AName: string); static;
    class procedure SetEnabled(const AName: string; const AEnabled: Boolean); static;

    { The list as JSON, which is how the store window reads it. Same shape as the
      catalogue's rows: what it is, where it reads, whether it is on. }
    class function ToJson(const ASources: TArray<TAddonSource>): string; static;

    { The official gallery row, which Load always returns first.
      Named Builtin rather than Default because Default() is an intrinsic: inside
      the method the compiler resolved Default(TAddonSource) to the method itself. }
    class function Builtin: TAddonSource; static;

    { The reserved name of the official store. Exposed so the Options page can
      refuse it as a name for a custom store instead of writing a file the CLI
      would then quietly ignore. }
    class function BuiltinName: string; static;

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
  Result.Builtin := True;
end;

class function TAddonSources.BuiltinName: string;
begin
  Result := CDefaultName;
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
  LPath, LText, LName: string;
  LVal, LListVal: TJSONValue;
  LArr: TJSONArray;
  LObj: TJSONObject;
  LIndex, LCount: Integer;
begin
  // The official store is position zero, before anything is read. Nothing in
  // the file can remove it; one thing in the file can switch it off.
  SetLength(Result, 1);
  Result[0] := Builtin;
  LCount := 1;

  LPath := ConfigPath;
  if not TFile.Exists(LPath) then
    Exit;
  try
    LText := TFile.ReadAllText(LPath, TEncoding.UTF8);
  except
    Exit;                               // unreadable config => official alone
  end;
  LVal := TJSONObject.ParseJSONValue(LText);
  try
    if not (LVal is TJSONObject) then
      Exit;
    LListVal := TJSONObject(LVal).Values['sources'];
    if not (LListVal is TJSONArray) then
      Exit;
    LArr := TJSONArray(LListVal);
    SetLength(Result, LArr.Count + 1);
    for LIndex := 0 to LArr.Count - 1 do
    begin
      if not (LArr.Items[LIndex] is TJSONObject) then
        Continue;
      LObj := TJSONObject(LArr.Items[LIndex]);
      LName := _Str(LObj, 'name');
      if LName = '' then
        Continue;                       // a nameless store cannot be referred to
      if SameText(LName, CDefaultName) then
      begin
        // The reserved name. It may say enabled:false and nothing else: a
        // location here would silently REPLACE the official store, and every
        // addon it published would then wear the official badge.
        Result[0].Enabled := _BoolOrTrue(LObj, 'enabled');
        Continue;
      end;
      Result[LCount].Name := LName;
      Result[LCount].Kind := ParseKind(_Str(LObj, 'kind'));
      Result[LCount].Location := _Str(LObj, 'location');
      if Result[LCount].Location = '' then
        Result[LCount].Location := _Str(LObj, 'url');   // friendlier alias
      Result[LCount].Enabled := _BoolOrTrue(LObj, 'enabled');
      Result[LCount].Builtin := False;
      Inc(LCount);
    end;
    SetLength(Result, LCount);
  finally
    LVal.Free;
  end;
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
      if ASources[LIndex].Builtin then
      begin
        // The official store is not configuration, so it is not written back -
        // round-tripping it would put a location in the file, and Load refuses
        // to read one. The single thing worth persisting is it being OFF.
        if not ASources[LIndex].Enabled then
        begin
          LItem := TJSONObject.Create;
          LItem.AddPair('name', ASources[LIndex].Name);
          LItem.AddPair('enabled', TJSONBool.Create(False));
          LArr.AddElement(LItem);
        end;
        Continue;
      end;
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

{ Index of a store by name, or -1. }
function _IndexOf(const ASources: TArray<TAddonSource>;
  const AName: string): Integer;
var
  LIndex: Integer;
begin
  Result := -1;
  for LIndex := 0 to High(ASources) do
    if SameText(ASources[LIndex].Name, AName) then
      Exit(LIndex);
end;

class procedure TAddonSources.Add(const AName, AKind, ALocation: string);
var
  LSources: TArray<TAddonSource>;
  LKind: TAddonSourceKind;
  LNew: TAddonSource;
begin
  if Trim(AName) = '' then
    raise EAddonManifest.Create('A store needs a name.');
  // The name is how --source refers to the store, so it has to survive being a
  // command-line word. Refusing here beats writing a store nobody can select.
  if Pos(' ', AName) > 0 then
    raise EAddonManifest.CreateFmt(
      'Store name "%s" cannot contain spaces - it is used as "--source %s".',
      [AName, AName]);
  if SameText(AName, CDefaultName) then
    raise EAddonManifest.CreateFmt(
      '"%s" is the official gallery and cannot be redefined. It can only be ' +
      'turned off (aefos sources disable %s).', [CDefaultName, CDefaultName]);
  LKind := ParseKind(AKind);
  if LKind = askGit then
    raise EAddonManifest.Create(
      'git stores are not supported yet. Use kind "path" for a folder or ' +
      'share, or "aefos" for a registry.json over HTTP.');

  LSources := Load;
  if _IndexOf(LSources, AName) >= 0 then
    raise EAddonManifest.CreateFmt(
      'There is already a store called "%s". Remove it first, or pick ' +
      'another name.', [AName]);

  LNew := Default(TAddonSource);
  LNew.Name := AName;
  LNew.Kind := LKind;
  LNew.Location := ALocation;
  LNew.Enabled := True;
  LNew.Builtin := False;
  SetLength(LSources, Length(LSources) + 1);
  LSources[High(LSources)] := LNew;
  Save(LSources);
end;

class procedure TAddonSources.Remove(const AName: string);
var
  LSources: TArray<TAddonSource>;
  LAt, LIndex: Integer;
begin
  if SameText(AName, CDefaultName) then
    raise EAddonManifest.CreateFmt(
      'The official gallery cannot be removed. Turn it off instead ' +
      '(aefos sources disable %s).', [CDefaultName]);
  LSources := Load;
  LAt := _IndexOf(LSources, AName);
  if LAt < 0 then
    raise EAddonManifest.CreateFmt('There is no store called "%s".', [AName]);
  for LIndex := LAt to High(LSources) - 1 do
    LSources[LIndex] := LSources[LIndex + 1];
  SetLength(LSources, Length(LSources) - 1);
  Save(LSources);
end;

class procedure TAddonSources.SetEnabled(const AName: string;
  const AEnabled: Boolean);
var
  LSources: TArray<TAddonSource>;
  LAt: Integer;
begin
  LSources := Load;
  LAt := _IndexOf(LSources, AName);
  if LAt < 0 then
    raise EAddonManifest.CreateFmt('There is no store called "%s".', [AName]);
  // The official store is the one entry whose ONLY writable field is this, and
  // Save already knows to persist nothing else about it.
  LSources[LAt].Enabled := AEnabled;
  Save(LSources);
end;

class function TAddonSources.ToJson(
  const ASources: TArray<TAddonSource>): string;
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
      // The official store's location is not configuration and Load never reads
      // one, so it travels empty rather than as the URL compiled in - a URL here
      // would look editable in the window, and it is not.
      if ASources[LIndex].Builtin then
        LItem.AddPair('location', '')
      else
        LItem.AddPair('location', ASources[LIndex].Location);
      LItem.AddPair('enabled', TJSONBool.Create(ASources[LIndex].Enabled));
      LItem.AddPair('builtin', TJSONBool.Create(ASources[LIndex].Builtin));
      LArr.AddElement(LItem);
    end;
    Result := LRoot.Format(2);
  finally
    LRoot.Free;
  end;
end;

end.
