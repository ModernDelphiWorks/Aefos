unit Aefos.Compat.Zip;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  ZIP extraction compatibility shim (Aefos -> Lazarus port, Milestone 1).

  Single uses-target for the ONE zip operation the addon manager performs:
  extract an entire archive into a destination folder (Aefos.Addons.Net's
  ExtractZip). Kept deliberately minimal - the CLI never creates or edits zips.

  - Delphi (not FPC): delegates to System.Zip.TZipFile (Open + ExtractAll).
  - FPC: uses the RTL's own `zipper` (paszlib) TUnZipper - already part of the
    FPC distribution, so the exe gains NO extra runtime dependency.

  ZIP-SLIP GUARD (both compilers): before extraction, every entry name in the
  archive is validated - absolute paths, drive/stream colons and any `..` path
  segment are rejected with EZipUnsafeEntry. FPC's TUnZipper performs NO such
  sanitisation of its own (verified in zipper.pp: GetOutputFileName just
  concatenates OutputPath + DiskFileName), and System.Zip's behaviour across
  Delphi versions is not documented - so the shim enforces the rule itself,
  identically on both sides. Addon archives come from a remote registry; a
  crafted entry must never be able to write outside the destination folder.

  API SURFACE COVERED:
    TAefosZip.ExtractAll(zipFile, destDir) -- inflate the whole archive under
      destDir, recreating its directory structure. Raises on a malformed
      archive or an unsafe entry name (the caller wraps that into a
      plain-English integrity error).
}

interface

uses
  SysUtils;

type
  // Raised when an archive entry's name would escape the destination folder.
  EZipUnsafeEntry = class(Exception);

  { Static, sealed namespace for archive extraction. Never instantiated. }
  TAefosZip = class sealed
  public
    class procedure ExtractAll(const AZipFile, ADestDir: string); static;
  end;

implementation

uses
{$IFNDEF FPC}
  System.Zip;
{$ELSE}
  zipper;
{$ENDIF}

// Rejects entry names that could write outside the extraction root: absolute
// paths (leading slash), drive/alternate-stream colons, and `..` segments.
// Pure string logic, shared verbatim by both compiler branches.
procedure _AssertSafeEntryName(const AEntryName, AZipFile: string);
var
  LNormalized: string;
  LSegments: array of string;
  LStart, LIndex, LCount: Integer;
begin
  LNormalized := StringReplace(AEntryName, '\', '/', [rfReplaceAll]);
  if (LNormalized <> '') and (LNormalized[1] = '/') then
    raise EZipUnsafeEntry.CreateFmt(
      'Unsafe zip entry (absolute path) "%s" in %s', [AEntryName, AZipFile]);
  if Pos(':', LNormalized) > 0 then
    raise EZipUnsafeEntry.CreateFmt(
      'Unsafe zip entry (drive or stream colon) "%s" in %s', [AEntryName, AZipFile]);
  // Split on '/' and reject any segment that is exactly '..'.
  SetLength(LSegments, 0);
  LCount := 0;
  LStart := 1;
  for LIndex := 1 to Length(LNormalized) + 1 do
    if (LIndex > Length(LNormalized)) or (LNormalized[LIndex] = '/') then
    begin
      SetLength(LSegments, LCount + 1);
      LSegments[LCount] := Copy(LNormalized, LStart, LIndex - LStart);
      Inc(LCount);
      LStart := LIndex + 1;
    end;
  for LIndex := 0 to LCount - 1 do
    if LSegments[LIndex] = '..' then
      raise EZipUnsafeEntry.CreateFmt(
        'Unsafe zip entry (parent-directory segment) "%s" in %s', [AEntryName, AZipFile]);
end;

{$IFNDEF FPC}

class procedure TAefosZip.ExtractAll(const AZipFile, ADestDir: string);
var
  LZip: TZipFile;
  LIndex: Integer;
begin
  LZip := TZipFile.Create;
  try
    LZip.Open(AZipFile, zmRead);
    for LIndex := 0 to LZip.FileCount - 1 do
      _AssertSafeEntryName(LZip.FileNames[LIndex], AZipFile);
    LZip.ExtractAll(ADestDir);
  finally
    LZip.Free;
  end;
end;

{$ELSE}

class procedure TAefosZip.ExtractAll(const AZipFile, ADestDir: string);
var
  LUnzip: TUnZipper;
  LIndex: Integer;
begin
  LUnzip := TUnZipper.Create;
  try
    LUnzip.FileName := AZipFile;
    LUnzip.Examine;
    for LIndex := 0 to LUnzip.Entries.Count - 1 do
      _AssertSafeEntryName(LUnzip.Entries[LIndex].ArchiveFileName, AZipFile);
    LUnzip.OutputPath := ADestDir;
    LUnzip.UnZipAllFiles;
  finally
    LUnzip.Free;
  end;
end;

{$ENDIF}

end.
