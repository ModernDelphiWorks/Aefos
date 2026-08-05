unit Aefos.Lazarus.MemoryStore;

{ TAefosLazMemoryStore -- the global chat "memory" store for the Lazarus chat
  composer (the brain button on the composer action bar).

  A SINGLE global memory text, SHARED with the RAD Studio plugin so the two IDEs
  agree on ONE memory -- the same cross-IDE shared-state rule that already governs
  models.json and config.json. The Delphi twin is TChatGlobalSettings.LoadMemory /
  SaveMemory (source/chat/Core/Aefos.OTA.Chat.Core.CommandExecutor.pas), which
  stores %APPDATA%\Aefos\memory.md as UTF-8 WITH a BOM (TFile.WriteAllText +
  TEncoding.UTF8). This unit reads/writes THE SAME file, byte-compatibly: it emits
  the UTF-8 BOM on save and strips a leading BOM on load, so a memory edited in one
  IDE shows up in the other.

  Mode delphi, string = UTF-8 AnsiString (the LCL boundary): the memory text
  crosses to the WebView shell as UTF-8, so this unit keeps everything in UTF-8 and
  never touches the platform ANSI codepage. No LCL dependency (Classes/SysUtils
  only) so the store is provable headlessly. All
  literals are ASCII, so this file needs no BOM. }

{$mode delphi}
{$H+}

interface

type
  // Static facade (house rule: no loose exported routines -- interface routines
  // live in a class). ARoot is the config root the controller resolves (defaults
  // to %APPDATA%\Aefos), passed in so a test can point the store at a temp dir and
  // never touch the user's real memory file.
  TAefosLazMemoryStore = class
  private
    class function _MemoryPath(const ARoot: string): string; static;
  public
    // The current global memory text (UTF-8), trimmed; '' when the file is absent
    // or unreadable -- a locked/garbled memory file must never break the chat.
    class function Load(const ARoot: string): string; static;
    // Persist the edited memory text (UTF-8 + BOM). Creates ARoot if needed.
    class procedure Save(const ARoot: string; const AText: string); static;
  end;

implementation

uses
  Classes,
  SysUtils;

const
  // Byte-identical to the Delphi twin: same file name, same UTF-8 BOM.
  CMemoryFile = 'memory.md';
  CUtf8Bom    = #$EF#$BB#$BF;

class function TAefosLazMemoryStore._MemoryPath(const ARoot: string): string;
begin
  Result := IncludeTrailingPathDelimiter(ARoot) + CMemoryFile;
end;

class function TAefosLazMemoryStore.Load(const ARoot: string): string;
var
  LStream: TFileStream;
  LPath: string;
  LText: string;
begin
  Result := '';
  LText := '';
  LPath := _MemoryPath(ARoot);
  if not FileExists(LPath) then
    Exit;
  try
    LStream := TFileStream.Create(LPath, fmOpenRead or fmShareDenyWrite);
    try
      SetLength(LText, LStream.Size);
      if LStream.Size > 0 then
        LStream.ReadBuffer(LText[1], LStream.Size);
    finally
      LStream.Free;
    end;
    // Strip a leading UTF-8 BOM (the Delphi twin writes one via TEncoding.UTF8).
    if Copy(LText, 1, Length(CUtf8Bom)) = CUtf8Bom then
      Delete(LText, 1, Length(CUtf8Bom));
    Result := Trim(LText);
  except
    // A locked/garbled memory file must never break the chat.
    Result := '';
  end;
end;

class procedure TAefosLazMemoryStore.Save(const ARoot: string;
  const AText: string);
var
  LStream: TFileStream;
  LPath: string;
  LOut: string;
begin
  LPath := _MemoryPath(ARoot);
  ForceDirectories(ExtractFileDir(LPath));
  // UTF-8 + BOM, byte-compatible with the Delphi twin's TFile.WriteAllText(...,
  // TEncoding.UTF8) so the shared file round-trips across the two IDEs.
  LOut := CUtf8Bom + AText;
  LStream := TFileStream.Create(LPath, fmCreate);
  try
    if LOut <> '' then
      LStream.WriteBuffer(LOut[1], Length(LOut));
  finally
    LStream.Free;
  end;
end;

end.
