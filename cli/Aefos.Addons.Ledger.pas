unit Aefos.Addons.Ledger;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  Aefos Addons - the installed-addon ledger (~/.aefos\addons\installed.json).

  The record of what install laid down, so update/uninstall/list are exact.
  Serialisation is split from I/O: Serialize/Deserialize are pure (asserted by
  the suite); Load/Save add atomic UTF-8 (no BOM) disk I/O on top.
}

interface

uses
  Aefos.Addons.Types;

type
  { Static, sealed namespace for the installed-addon ledger. Never instantiated;
    the class IS the namespace, so the old 'Ledger' name suffix is gone. }
  TAddonLedger = class sealed
  public
    { Pure: ledger records <-> JSON text. }
    class function Serialize(const AItems: TArray<TInstalledAddon>): string; static;
    class function Deserialize(const AJson: string): TArray<TInstalledAddon>; static;

    { Reads installed.json; returns an empty array when the file is absent or
      unreadable (a missing ledger is "nothing installed", never an error). }
    class function Load: TArray<TInstalledAddon>; static;

    { Writes installed.json atomically (temp + rename), UTF-8 without BOM. }
    class procedure Save(const AItems: TArray<TInstalledAddon>); static;

    { Finds ASlug in AItems (case-insensitive); returns True + the record. }
    class function TryFind(const AItems: TArray<TInstalledAddon>;
      const ASlug: string; out AItem: TInstalledAddon): Boolean; static;

    { Returns AItems without any entry whose slug matches ASlug (case-insensitive). }
    class function Remove(const AItems: TArray<TInstalledAddon>;
      const ASlug: string): TArray<TInstalledAddon>; static;

    { Returns AItems with AItem added, replacing any existing same-slug entry. }
    class function Upsert(const AItems: TArray<TInstalledAddon>;
      const AItem: TInstalledAddon): TArray<TInstalledAddon>; static;
  end;

implementation

uses
  SysUtils,
  Classes,
  Aefos.Compat.IO,
  Aefos.Compat.Json,
  Generics.Collections,
  Aefos.Addons.Paths,
  Aefos.Compat.JsonFormat;

function _ArtifactsToJson(const A: TAddonArtifacts): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('command', TJSONBool.Create(A.HasCommand));
  Result.AddPair('skill', TJSONBool.Create(A.HasSkill));
  Result.AddPair('mcp', TJSONBool.Create(A.HasMcp));
  Result.AddPair('tools', TJSONBool.Create(A.HasTools));
  Result.AddPair('templates', TJSONBool.Create(A.HasTemplates));
end;

function _ItemToJson(const AItem: TInstalledAddon): TJSONObject;
var
  LFiles: TJSONArray;
  LIndex: Integer;
begin
  Result := TJSONObject.Create;
  Result.AddPair('slug', AItem.Slug);
  Result.AddPair('version', AItem.Version);
  Result.AddPair('trust', AItem.Trust.ToStr);
  Result.AddPair('sha256', AItem.Sha256);
  Result.AddPair('installedAt', AItem.InstalledAt);
  Result.AddPair('source', AItem.Source);
  Result.AddPair('artifacts', _ArtifactsToJson(AItem.Artifacts));
  LFiles := TJSONArray.Create;
  for LIndex := 0 to High(AItem.Files) do
    LFiles.Add(AItem.Files[LIndex]);
  Result.AddPair('files', LFiles);
  LFiles := TJSONArray.Create;
  for LIndex := 0 to High(AItem.Roots) do
    LFiles.Add(AItem.Roots[LIndex]);
  Result.AddPair('roots', LFiles);
end;

class function TAddonLedger.Serialize(
  const AItems: TArray<TInstalledAddon>): string;
var
  LRoot: TJSONObject;
  LArr: TJSONArray;
  LIndex: Integer;
begin
  LRoot := TJSONObject.Create;
  try
    LRoot.AddPair('schema', TJSONNumber.Create(1));
    LArr := TJSONArray.Create;
    for LIndex := 0 to High(AItems) do
      LArr.AddElement(_ItemToJson(AItems[LIndex]));
    LRoot.AddPair('installed', LArr);
    Result := LRoot.Format(2);
  finally
    LRoot.Free;
  end;
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

function _Bool(const AObj: TJSONObject; const AKey: string): Boolean;
begin
  Result := (AObj <> nil) and (AObj.Values[AKey] is TJSONBool) and
    TJSONBool(AObj.Values[AKey]).AsBoolean;
end;

function _ItemFromJson(const AObj: TJSONObject): TInstalledAddon;
var
  LArt, LFiles: TJSONValue;
  LArtObj: TJSONObject;
  LArr: TJSONArray;
  LIndex: Integer;
  LList: TList<string>;
begin
  Result := Default(TInstalledAddon);
  Result.Slug := _Str(AObj, 'slug');
  Result.Version := _Str(AObj, 'version');
  Result.Trust := TAddonTrust.Parse(_Str(AObj, 'trust'));
  Result.Sha256 := _Str(AObj, 'sha256');
  Result.InstalledAt := _Str(AObj, 'installedAt');
  // Absent in a ledger written before stores existed. Empty means "wherever it
  // can be found", which is what that older install actually meant.
  Result.Source := _Str(AObj, 'source');
  LArt := AObj.Values['artifacts'];
  if LArt is TJSONObject then
  begin
    LArtObj := TJSONObject(LArt);
    Result.Artifacts.HasCommand := _Bool(LArtObj, 'command');
    Result.Artifacts.HasSkill := _Bool(LArtObj, 'skill');
    Result.Artifacts.HasMcp := _Bool(LArtObj, 'mcp');
    Result.Artifacts.HasTools := _Bool(LArtObj, 'tools');
    Result.Artifacts.HasTemplates := _Bool(LArtObj, 'templates');
  end;
  LFiles := AObj.Values['files'];
  if LFiles is TJSONArray then
  begin
    LArr := TJSONArray(LFiles);
    LList := TList<string>.Create;
    try
      for LIndex := 0 to LArr.Count - 1 do
        if LArr.Items[LIndex] is TJSONString then
          LList.Add(TJSONString(LArr.Items[LIndex]).Value);
      Result.Files := LList.ToArray;
    finally
      LList.Free;
    end;
  end;
  LFiles := AObj.Values['roots'];
  if LFiles is TJSONArray then
  begin
    LArr := TJSONArray(LFiles);
    LList := TList<string>.Create;
    try
      for LIndex := 0 to LArr.Count - 1 do
        if LArr.Items[LIndex] is TJSONString then
          LList.Add(TJSONString(LArr.Items[LIndex]).Value);
      Result.Roots := LList.ToArray;
    finally
      LList.Free;
    end;
  end;
end;

class function TAddonLedger.Deserialize(
  const AJson: string): TArray<TInstalledAddon>;
var
  LRoot: TJSONValue;
  LObj: TJSONObject;
  LArr: TJSONArray;
  LIndex: Integer;
  LList: TList<TInstalledAddon>;
begin
  if Trim(AJson) = '' then
    Exit(nil);
  LRoot := TJSONObject.ParseJSONValue(AJson);
  if not (LRoot is TJSONObject) then
  begin
    LRoot.Free;
    Exit(nil);
  end;
  try
    LObj := TJSONObject(LRoot);
    if not (LObj.Values['installed'] is TJSONArray) then
      Exit(nil);
    LArr := TJSONArray(LObj.Values['installed']);
    LList := TList<TInstalledAddon>.Create;
    try
      for LIndex := 0 to LArr.Count - 1 do
        if LArr.Items[LIndex] is TJSONObject then
          LList.Add(_ItemFromJson(TJSONObject(LArr.Items[LIndex])));
      Result := LList.ToArray;
    finally
      LList.Free;
    end;
  finally
    LRoot.Free;
  end;
end;

class function TAddonLedger.Load: TArray<TInstalledAddon>;
var
  LPath: string;
begin
  LPath := TAddonPaths.LedgerPath;
  if not TFile.Exists(LPath) then
    Exit(nil);
  try
    Result := TAddonLedger.Deserialize(TFile.ReadAllText(LPath, TEncoding.UTF8));
  except
    on E: Exception do
      Result := nil; // an unreadable ledger reads as "nothing installed"
  end;
end;

class procedure TAddonLedger.Save(const AItems: TArray<TInstalledAddon>);
var
  LPath, LTemp, LDir: string;
  LBytes: TBytes;
  LStream: TFileStream;
begin
  LPath := TAddonPaths.LedgerPath;
  LDir := ExtractFileDir(LPath);
  if not ForceDirectories(LDir) then
    raise EAddonError.CreateFmt('cannot create "%s".', [LDir]);
  LTemp := LPath + '.tmp';
  LBytes := TEncoding.UTF8.GetBytes(TAddonLedger.Serialize(AItems));
  LStream := TFileStream.Create(LTemp, fmCreate);
  try
    if Length(LBytes) > 0 then
      LStream.WriteBuffer(LBytes[0], Length(LBytes));
  finally
    LStream.Free;
  end;
  if TFile.Exists(LPath) then
    TFile.Delete(LPath);
  TFile.Move(LTemp, LPath);
end;

class function TAddonLedger.TryFind(const AItems: TArray<TInstalledAddon>;
  const ASlug: string; out AItem: TInstalledAddon): Boolean;
var
  LIndex: Integer;
begin
  for LIndex := 0 to High(AItems) do
    if SameText(AItems[LIndex].Slug, ASlug) then
    begin
      AItem := AItems[LIndex];
      Exit(True);
    end;
  AItem := Default(TInstalledAddon);
  Result := False;
end;

class function TAddonLedger.Remove(const AItems: TArray<TInstalledAddon>;
  const ASlug: string): TArray<TInstalledAddon>;
var
  LIndex: Integer;
  LList: TList<TInstalledAddon>;
begin
  LList := TList<TInstalledAddon>.Create;
  try
    for LIndex := 0 to High(AItems) do
      if not SameText(AItems[LIndex].Slug, ASlug) then
        LList.Add(AItems[LIndex]);
    Result := LList.ToArray;
  finally
    LList.Free;
  end;
end;

class function TAddonLedger.Upsert(const AItems: TArray<TInstalledAddon>;
  const AItem: TInstalledAddon): TArray<TInstalledAddon>;
begin
  Result := TAddonLedger.Remove(AItems, AItem.Slug) + [AItem];
end;

end.
