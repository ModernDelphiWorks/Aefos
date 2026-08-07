unit Aefos.Addons.Net;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  Aefos Addons - the side-effecting edge: download, integrity check, extract.

  Kept tiny and separate from the installer orchestration so the orchestration
  stays testable against fakes. The HTTP/SHA-256/ZIP edges go through the
  Aefos.Compat.Http, Aefos.Compat.Sha256 and Aefos.Compat.Zip shims (Delphi:
  System.Net.HttpClient / System.Hash / System.Zip; FPC: WinINet / hand-rolled
  SHA-256 / zipper), so this unit is single-source across both compilers. Every
  failure raises EAddonError with a plain-English reason.
}

interface

uses
  Aefos.Addons.Types;

type
  { Static, sealed namespace for the side-effecting network/integrity edge:
    download, sha-256, extract. Never instantiated; the class IS the namespace. }
  TAddonNet = class sealed
  public
    { The registry URL: %AEFOS_ADDONS_REGISTRY% when set, else the default. It may
      be an http(s) URL (the online gallery) OR a local filesystem path / file://
      URL (an offline, bundled registry.json - see DownloadText/DownloadFile). }
    class function RegistryUrl: string; static;

    { Fetches AUrl into ADestFile (overwriting). An http(s) AUrl is an HTTP GET
      (raises EAddonError on any non-2xx status or transport failure). A NON-http
      AUrl is a LOCAL source: an absolute path (or file:// URL) is copied straight
      off disk, and a RELATIVE path is resolved against the directory of the local
      registry (RegistryUrl) - so a bundled registry.json whose "url" is
      "addons/<slug>/<slug>-<ver>.zip" installs fully offline. }
    class procedure DownloadFile(const AUrl, ADestFile: string); static;

    { Returns AUrl's body as text (UTF-8). An http(s) AUrl is an HTTP GET; a
      NON-http AUrl is read straight off disk (absolute path or file:// URL). For
      registry.json, online or bundled/offline. }
    class function DownloadText(const AUrl: string): string; static;

    { Lowercase hex SHA-256 of a file's bytes. }
    class function Sha256OfFile(const APath: string): string; static;

    { Lowercase hex SHA-256 of a whole DIRECTORY, so a bundle that arrives as a
      folder (a path store - a company share) still has the one identity the
      rest of the system is built on: sha256 is what DecideUpdate compares, and
      a folder with no sha would read as "changed" on every single run.

      The digest is over a sorted "<relative path> <file sha>" listing, not over
      concatenated bytes: that way a file MOVED between folders changes the
      identity, which byte concatenation would miss. Paths are lowercased and
      slash-normalised (Windows treats those as the same file), and the sort is
      ORDINAL on purpose - a locale-aware collation would order the listing
      differently on two machines and invent a difference that is not there. }
    class function Sha256OfTree(const ADir: string): string; static;

    { Verifies AFile's SHA-256 equals AExpected (case-insensitive). Raises
      EAddonIntegrity on mismatch. }
    class procedure VerifySha256(const AFile, AExpected: string); static;

    { Extracts AZipFile into ADestDir (created if absent). Raises EAddonIntegrity
      on a malformed archive. }
    class procedure ExtractZip(const AZipFile, ADestDir: string); static;
  end;

implementation

uses
  SysUtils,
  Classes,
  Aefos.Compat.IO,
  Aefos.Compat.Http,
  Aefos.Compat.Sha256,
  Aefos.Compat.Zip;

const
  CDefaultRegistry =
    'https://raw.githubusercontent.com/ModernDelphiWorks/aefos-addons/main/registry.json';

// True when ARef is an http(s) URL (the online gallery). Anything else is
// treated as a LOCAL filesystem reference (a path or a file:// URL).
function _IsHttpRef(const ARef: string): Boolean;
begin
  Result := SameText(Copy(ARef, 1, 7), 'http://') or
            SameText(Copy(ARef, 1, 8), 'https://');
end;

// Turns a LOCAL reference (a plain path or a file:// URL) into a filesystem
// path. Forward slashes are normalised to backslashes; a "file:///C:/x" form
// (leading slash before the drive letter) is de-slashed. A plain path is
// returned as-is (still possibly relative - the caller anchors it).
function _LocalPathOf(const ARef: string): string;
var
  LPath: string;
begin
  LPath := ARef;
  if SameText(Copy(LPath, 1, 7), 'file://') then
  begin
    LPath := Copy(LPath, 8, MaxInt);                 // drop 'file://'
    // file:///C:/x -> a leading slash sits before the drive; strip it.
    if (Length(LPath) >= 3) and ((LPath[1] = '/') or (LPath[1] = '\')) and
       (LPath[3] = ':') then
      LPath := Copy(LPath, 2, MaxInt);
  end;
  Result := StringReplace(LPath, '/', '\', [rfReplaceAll]);
end;

// Resolves a LOCAL bundle reference taken from a bundled registry.json. An
// absolute path (or file:// URL) is normalised to a full path. A RELATIVE path
// is anchored on the directory of the local registry (RegistryUrl), so a
// registry.json's "url":"addons/<slug>/<zip>" points to the file beside it.
function _ResolveLocalBundle(const ARef: string): string;
var
  LPath, LRegDir: string;
begin
  LPath := _LocalPathOf(ARef);
  if TPath.IsPathRooted(LPath) then
    Exit(TPath.GetFullPath(LPath));
  LRegDir := ExtractFileDir(_LocalPathOf(TAddonNet.RegistryUrl));
  Result := TPath.GetFullPath(TPath.Combine(LRegDir, LPath));
end;

class function TAddonNet.RegistryUrl: string;
begin
  Result := GetEnvironmentVariable('AEFOS_ADDONS_REGISTRY');
  if Trim(Result) = '' then
    Result := CDefaultRegistry;
end;

class procedure TAddonNet.DownloadFile(const AUrl, ADestFile: string);
var
  LDir, LError, LSrc: string;
  LStatus: Integer;
begin
  LDir := ExtractFileDir(ADestFile);
  if (LDir <> '') and not ForceDirectories(LDir) then
    raise EAddonError.CreateFmt('cannot create "%s".', [LDir]);
  if not _IsHttpRef(AUrl) then
  begin
    // LOCAL/OFFLINE source: copy the bundle straight off disk. A relative "url"
    // is anchored on the local registry's directory (see _ResolveLocalBundle).
    LSrc := _ResolveLocalBundle(AUrl);
    if not TFile.Exists(LSrc) then
      raise EAddonError.CreateFmt('local addon file not found: %s', [LSrc]);
    TFile.Copy(LSrc, ADestFile, True);
    Exit;
  end;
  if not TAefosHttp.TryGetToFile(AUrl, ADestFile, LStatus, LError) then
    raise EAddonError.CreateFmt('download failed (%s): %s', [AUrl, LError]);
  if (LStatus < 200) or (LStatus >= 300) then
    raise EAddonError.CreateFmt('download failed (HTTP %d) for %s',
      [LStatus, AUrl]);
end;

class function TAddonNet.DownloadText(const AUrl: string): string;
var
  LBody, LError, LSrc: string;
  LStatus: Integer;
begin
  if not _IsHttpRef(AUrl) then
  begin
    // LOCAL/OFFLINE registry: read the file straight off disk (BOM stripped by
    // TFile.ReadAllText, matching the BOM strip the HTTP path does).
    LSrc := _LocalPathOf(AUrl);
    if not TPath.IsPathRooted(LSrc) then
      LSrc := TPath.GetFullPath(LSrc);
    if not TFile.Exists(LSrc) then
      raise EAddonError.CreateFmt('local registry not found: %s', [LSrc]);
    Exit(TFile.ReadAllText(LSrc, TEncoding.UTF8));
  end;
  if not TAefosHttp.TryGetText(AUrl, LStatus, LBody, LError) then
    raise EAddonError.CreateFmt('download failed (%s): %s', [AUrl, LError]);
  if (LStatus < 200) or (LStatus >= 300) then
    raise EAddonError.CreateFmt('download failed (HTTP %d) for %s',
      [LStatus, AUrl]);
  Result := LBody;
end;

class function TAddonNet.Sha256OfFile(const APath: string): string;
begin
  Result := TAefosSha256.HexDigestFile(APath);
end;

// Ordinal comparison, deliberately NOT the locale-aware default: the digest
// below depends on the ORDER, so two machines with different locales must not
// sort the same listing differently.
function _CompareOrdinal(AList: TStringList;
  AIndex1, AIndex2: Integer): Integer;
begin
  Result := CompareStr(AList[AIndex1], AList[AIndex2]);
end;

class function TAddonNet.Sha256OfTree(const ADir: string): string;
var
  LFiles: TArray<string>;
  LList: TStringList;
  LIndex, LRootLen: Integer;
  LRel: string;
begin
  if not TDirectory.Exists(ADir) then
    raise EAddonError.CreateFmt('bundle folder not found: %s', [ADir]);
  LFiles := TDirectory.GetFiles(ADir, '*', TSearchOption.soAllDirectories);
  LRootLen := Length(IncludeTrailingPathDelimiter(TPath.GetFullPath(ADir)));
  LList := TStringList.Create;
  try
    for LIndex := 0 to High(LFiles) do
    begin
      LRel := Copy(TPath.GetFullPath(LFiles[LIndex]), LRootLen + 1, MaxInt);
      LRel := LowerCase(StringReplace(LRel, '\', '/', [rfReplaceAll]));
      LList.Add(LRel + ' ' + TAefosSha256.HexDigestFile(LFiles[LIndex]));
    end;
    LList.CustomSort(_CompareOrdinal);
    Result := TAefosSha256.HexDigest(LList.Text);
  finally
    LList.Free;
  end;
end;

class procedure TAddonNet.VerifySha256(const AFile, AExpected: string);
var
  LActual: string;
begin
  LActual := TAddonNet.Sha256OfFile(AFile);
  if not SameText(LActual, Trim(AExpected)) then
    raise EAddonIntegrity.CreateFmt(
      'integrity check failed: expected sha256 %s, got %s.',
      [LowerCase(Trim(AExpected)), LActual]);
end;

class procedure TAddonNet.ExtractZip(const AZipFile, ADestDir: string);
begin
  if not ForceDirectories(ADestDir) then
    raise EAddonError.CreateFmt('cannot create "%s".', [ADestDir]);
  try
    TAefosZip.ExtractAll(AZipFile, ADestDir);
  except
    on E: Exception do
      raise EAddonIntegrity.CreateFmt('bad archive: %s', [E.Message]);
  end;
end;

end.
