unit Aefos.Compat.IO;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  System.IOUtils compatibility shim (Aefos -> Lazarus port, Milestone 1).

  Single uses-target replacing `uses System.IOUtils` in the swept MCP core AND
  the addon-manager CLI (aefos.exe) chain. FPC 3.2.2 ships no System.IOUtils
  unit, so the TPath/TFile/TDirectory members Aefos actually uses are shimmed
  here over the FPC RTL (SysUtils/Classes only - no LazUtils, no fileutil).

  - Delphi (not FPC): pure TYPE ALIASES onto System.IOUtils (identical behaviour).
  - FPC: minimal static classes over SysUtils/Classes.

  API SURFACE COVERED (the exact set used by Aefos.MCP.AuditLog +
  Aefos.MCP.InspectorBridge + the aefos.exe addon-manager chain):
    TSearchOption : soTopDirectoryOnly | soAllDirectories
    TPath      : Combine(a,b); GetDirectoryName(path); GetFullPath(path);
                 GetTempPath; GetHomePath; IsPathRooted(path)
    TDirectory : CreateDirectory(path)  -- full path (ForceDirectories);
                 Exists(path); Delete(path, recursive);
                 GetDirectories(path, mask, option);
                 GetFiles(path, mask, option)
    TFile      : Exists(path); GetSize(path); AppendAllText(path, text, enc);
                 Copy(src, dst, overwrite); Delete(path); Move(src, dst);
                 ReadAllText(path, enc); ReadAllBytes(path);
                 WriteAllText(path, text, enc); WriteAllBytes(path, bytes)

  FPC deviations (documented; behaviour proven byte-identical for Aefos use):
    * GetDirectories/GetFiles return FULL paths (as System.IOUtils does), built
      as <path><PathDelim><name>. The '*' mask matches everything; other masks
      are honoured by FindFirst's native wildcarding at each level.
    * ReadAllText strips a leading UTF-8 BOM (EF BB BF) before decoding, exactly
      like System.IOUtils.TFile.ReadAllText, so a BOM'd file round-trips clean.
    * WriteAllText WRITES the encoding's preamble first (a UTF-8 BOM for
      TEncoding.UTF8), exactly like System.IOUtils.TFile.WriteAllText. That is
      what keeps a file written by the Lazarus edition byte-compatible with the
      same file written by the RAD Studio plugin (models.json is shared).
    * Copy does a stream copy (no CopyFileW): overwrite=False + existing dest
      raises EInOutError, matching System.IOUtils' EInOutError-on-collision.
    * GetHomePath returns %APPDATA% (the Roaming profile), which is what
      System.IOUtils.TPath.GetHomePath returns ON WINDOWS - the only platform
      Aefos ships. It is NOT the POSIX $HOME meaning; a future non-Windows
      target must revisit this (the shipped Aefos roots all sit under %APPDATA%).
}

interface

{$IFNDEF FPC}

uses
  System.IOUtils;

type
  TPath         = System.IOUtils.TPath;
  TFile         = System.IOUtils.TFile;
  TDirectory    = System.IOUtils.TDirectory;
  TSearchOption = System.IOUtils.TSearchOption;

{$ELSE}

uses
  SysUtils,
  Classes;

type
  // Mirrors System.IOUtils.TSearchOption.
  TSearchOption = (soTopDirectoryOnly, soAllDirectories);

  TPath = class sealed
  public
    class function Combine(const APathA, APathB: string): string; static;
    class function GetDirectoryName(const APath: string): string; static;
    class function GetFullPath(const APath: string): string; static;
    class function GetTempPath: string; static;
    // Windows semantics of System.IOUtils.TPath.GetHomePath: the per-user
    // Roaming application-data folder (%APPDATA%), NOT the POSIX home.
    class function GetHomePath: string; static;
    // True when APath is absolute (System.IOUtils semantics on Windows: a
    // drive-rooted "C:\x", a root-relative "\x", or a UNC "\\host\share").
    // Consumed by the shared CLI dispatcher's executor resolution: an absolute
    // candidate is taken verbatim, a bare name is searched on PATH.
    class function IsPathRooted(const APath: string): Boolean; static;
  end;

  TDirectory = class sealed
  public
    class procedure CreateDirectory(const APath: string); static;
    class function Exists(const APath: string): Boolean; static;
    class procedure Delete(const APath: string; const ARecursive: Boolean); static;
    class function GetDirectories(const APath, ASearchPattern: string;
      const AOption: TSearchOption): TArray<string>; static;
    class function GetFiles(const APath, ASearchPattern: string;
      const AOption: TSearchOption): TArray<string>; static;
  end;

  TFile = class sealed
  public
    class function Exists(const APath: string): Boolean; static;
    class function GetSize(const APath: string): Int64; static;
    class procedure AppendAllText(const APath, AContents: string;
      const AEncoding: TEncoding); static;
    class procedure Copy(const ASource, ADest: string;
      const AOverwrite: Boolean); static;
    class procedure Delete(const APath: string); static;
    class procedure Move(const ASource, ADest: string); static;
    class function ReadAllText(const APath: string;
      const AEncoding: TEncoding): string; static;
    class function ReadAllBytes(const APath: string): TBytes; static;
    class procedure WriteAllText(const APath, AContents: string;
      const AEncoding: TEncoding); static;
    class procedure WriteAllBytes(const APath: string; const ABytes: TBytes); static;
  end;

{$ENDIF}

implementation

{$IFDEF FPC}

{ TPath }

class function TPath.Combine(const APathA, APathB: string): string;
begin
  if APathA = '' then
    Result := APathB
  else if APathB = '' then
    Result := APathA
  else
    Result := IncludeTrailingPathDelimiter(APathA) + APathB;
end;

class function TPath.GetDirectoryName(const APath: string): string;
begin
  Result := ExcludeTrailingPathDelimiter(ExtractFilePath(APath));
end;

class function TPath.GetFullPath(const APath: string): string;
begin
  Result := ExpandFileName(APath);
end;

class function TPath.GetTempPath: string;
begin
  Result := IncludeTrailingPathDelimiter(GetTempDir);
end;

class function TPath.GetHomePath: string;
begin
  // System.IOUtils resolves CSIDL_APPDATA; %APPDATA% is the same folder for
  // every process the IDE ever runs under, and is what the SHIPPED Aefos roots
  // (config.json, models.json) are already anchored to.
  Result := GetEnvironmentVariable('APPDATA');
end;

class function TPath.IsPathRooted(const APath: string): Boolean;
begin
  // Mirrors System.IOUtils.TPath.IsPathRooted on Windows: rooted means the path
  // starts at a root, which is either a path delimiter (covers both "\x" and the
  // UNC "\\host\share") or a "<drive>:" prefix. Note this is NOT "is absolute":
  // "C:x" and "\x" are rooted but drive/CWD-relative -- exactly System.IOUtils'
  // contract, and enough for the caller (a rooted executor candidate is taken
  // verbatim and then checked with TFile.Exists).
  Result := False;
  if APath = '' then
    Exit;
  if (APath[1] = '\') or (APath[1] = '/') then
    Exit(True);
  Result := (Length(APath) >= 2) and (APath[2] = ':');
end;

{ TDirectory }

class procedure TDirectory.CreateDirectory(const APath: string);
begin
  if (APath <> '') and not SysUtils.DirectoryExists(APath) then
    if not ForceDirectories(APath) then
      raise EInOutError.CreateFmt('Cannot create directory: %s', [APath]);
end;

class function TDirectory.Exists(const APath: string): Boolean;
begin
  Result := SysUtils.DirectoryExists(APath);
end;

class procedure TDirectory.Delete(const APath: string;
  const ARecursive: Boolean);
var
  LSearch: TSearchRec;
  LChild: string;
begin
  if not SysUtils.DirectoryExists(APath) then
    Exit;
  if ARecursive then
  begin
    if FindFirst(IncludeTrailingPathDelimiter(APath) + '*', faAnyFile,
      LSearch) = 0 then
    try
      repeat
        if (LSearch.Name = '.') or (LSearch.Name = '..') then
          Continue;
        LChild := IncludeTrailingPathDelimiter(APath) + LSearch.Name;
        if (LSearch.Attr and faDirectory) <> 0 then
          TDirectory.Delete(LChild, True)
        else
          SysUtils.DeleteFile(LChild);
      until FindNext(LSearch) <> 0;
    finally
      FindClose(LSearch);
    end;
  end;
  if not RemoveDir(APath) then
    raise EInOutError.CreateFmt('Cannot remove directory: %s', [APath]);
end;

// Shared recursive walk: appends matching entries (files or dirs, per AWantDirs)
// as full paths into AResult. Recurses into every subdirectory when AOption is
// soAllDirectories, regardless of the leaf pattern.
procedure _Walk(const APath, ASearchPattern: string;
  const AOption: TSearchOption; const AWantDirs: Boolean;
  var AResult: TArray<string>);
var
  LSearch: TSearchRec;
  LBase, LChild: string;
  LIsDir: Boolean;
begin
  LBase := IncludeTrailingPathDelimiter(APath);
  // Pass 1: emit entries matching the pattern at this level.
  if FindFirst(LBase + ASearchPattern, faAnyFile, LSearch) = 0 then
  try
    repeat
      if (LSearch.Name = '.') or (LSearch.Name = '..') then
        Continue;
      LIsDir := (LSearch.Attr and faDirectory) <> 0;
      if LIsDir = AWantDirs then
      begin
        SetLength(AResult, Length(AResult) + 1);
        AResult[High(AResult)] := LBase + LSearch.Name;
      end;
    until FindNext(LSearch) <> 0;
  finally
    FindClose(LSearch);
  end;
  // Pass 2: recurse into every subdirectory (independent of the pattern).
  if AOption = soAllDirectories then
    if FindFirst(LBase + '*', faDirectory, LSearch) = 0 then
    try
      repeat
        if (LSearch.Name = '.') or (LSearch.Name = '..') then
          Continue;
        if (LSearch.Attr and faDirectory) <> 0 then
        begin
          LChild := LBase + LSearch.Name;
          _Walk(LChild, ASearchPattern, AOption, AWantDirs, AResult);
        end;
      until FindNext(LSearch) <> 0;
    finally
      FindClose(LSearch);
    end;
end;

class function TDirectory.GetDirectories(const APath, ASearchPattern: string;
  const AOption: TSearchOption): TArray<string>;
begin
  SetLength(Result, 0);
  _Walk(APath, ASearchPattern, AOption, True, Result);
end;

class function TDirectory.GetFiles(const APath, ASearchPattern: string;
  const AOption: TSearchOption): TArray<string>;
begin
  SetLength(Result, 0);
  _Walk(APath, ASearchPattern, AOption, False, Result);
end;

{ TFile }

class function TFile.Exists(const APath: string): Boolean;
begin
  Result := FileExists(APath);
end;

class function TFile.GetSize(const APath: string): Int64;
var
  LStream: TFileStream;
begin
  LStream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    Result := LStream.Size;
  finally
    LStream.Free;
  end;
end;

class procedure TFile.AppendAllText(const APath, AContents: string;
  const AEncoding: TEncoding);
var
  LStream: TFileStream;
  LBytes: TBytes;
begin
  LBytes := AEncoding.GetBytes(AContents);
  if FileExists(APath) then
    LStream := TFileStream.Create(APath, fmOpenReadWrite or fmShareDenyWrite)
  else
    LStream := TFileStream.Create(APath, fmCreate or fmShareDenyWrite);
  try
    LStream.Seek(Int64(0), soEnd);
    if Length(LBytes) > 0 then
      LStream.WriteBuffer(LBytes[0], Length(LBytes));
  finally
    LStream.Free;
  end;
end;

class procedure TFile.Copy(const ASource, ADest: string;
  const AOverwrite: Boolean);
var
  LSrc, LDst: TFileStream;
begin
  if FileExists(ADest) and not AOverwrite then
    raise EInOutError.CreateFmt('Destination already exists: %s', [ADest]);
  LSrc := TFileStream.Create(ASource, fmOpenRead or fmShareDenyWrite);
  try
    LDst := TFileStream.Create(ADest, fmCreate or fmShareDenyWrite);
    try
      LDst.CopyFrom(LSrc, LSrc.Size);
    finally
      LDst.Free;
    end;
  finally
    LSrc.Free;
  end;
end;

class procedure TFile.Delete(const APath: string);
begin
  if FileExists(APath) and not SysUtils.DeleteFile(APath) then
    raise EInOutError.CreateFmt('Cannot delete file: %s', [APath]);
end;

class procedure TFile.Move(const ASource, ADest: string);
begin
  if not RenameFile(ASource, ADest) then
    raise EInOutError.CreateFmt('Cannot move "%s" to "%s".', [ASource, ADest]);
end;

class function TFile.ReadAllText(const APath: string;
  const AEncoding: TEncoding): string;
var
  LStream: TFileStream;
  LBytes: TBytes;
  LStart: Integer;
begin
  LStream := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(LBytes, LStream.Size);
    if Length(LBytes) > 0 then
      LStream.ReadBuffer(LBytes[0], Length(LBytes));
  finally
    LStream.Free;
  end;
  // Strip a leading UTF-8 BOM so a BOM'd file decodes like System.IOUtils does.
  LStart := 0;
  if (Length(LBytes) >= 3) and (LBytes[0] = $EF) and (LBytes[1] = $BB) and
    (LBytes[2] = $BF) then
    LStart := 3;
  Result := AEncoding.GetString(LBytes, LStart, Length(LBytes) - LStart);
end;

class function TFile.ReadAllBytes(const APath: string): TBytes;
var
  LStream: TFileStream;
begin
  // Raw bytes, no BOM stripping and no decoding (System.IOUtils parity). The
  // caller owns any encoding decision - Core.Config reads bytes then decodes
  // UTF-8 itself.
  LStream := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, LStream.Size);
    if Length(Result) > 0 then
      LStream.ReadBuffer(Result[0], Length(Result));
  finally
    LStream.Free;
  end;
end;

class procedure TFile.WriteAllText(const APath, AContents: string;
  const AEncoding: TEncoding);
var
  LStream: TFileStream;
  LBytes, LPreamble: TBytes;
begin
  // System.IOUtils order: truncate, write the encoding preamble (the UTF-8 BOM),
  // then the encoded text. Reproduced exactly so a shared file (models.json)
  // stays byte-compatible with whatever the Delphi plugin last wrote.
  LStream := TFileStream.Create(APath, fmCreate or fmShareDenyWrite);
  try
    LPreamble := AEncoding.GetPreamble;
    if Length(LPreamble) > 0 then
      LStream.WriteBuffer(LPreamble[0], Length(LPreamble));
    LBytes := AEncoding.GetBytes(AContents);
    if Length(LBytes) > 0 then
      LStream.WriteBuffer(LBytes[0], Length(LBytes));
  finally
    LStream.Free;
  end;
end;

class procedure TFile.WriteAllBytes(const APath: string; const ABytes: TBytes);
var
  LStream: TFileStream;
begin
  LStream := TFileStream.Create(APath, fmCreate or fmShareDenyWrite);
  try
    if Length(ABytes) > 0 then
      LStream.WriteBuffer(ABytes[0], Length(ABytes));
  finally
    LStream.Free;
  end;
end;

{$ENDIF}

end.
