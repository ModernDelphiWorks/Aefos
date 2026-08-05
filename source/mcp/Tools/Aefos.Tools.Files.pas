unit Aefos.Tools.Files;

(*
  Aefos.Tools.Files — disk IO layer for the tool suite.

  Closes the loop "agent sends a coordinate -> the real file is edited":
  load a file (decoding + detecting its BOM/EOL), apply a pure Tools.Text
  edit on the content, then write it back atomically PRESERVING the original
  BOM. The file's EOL survives automatically because Tools.Text preserves it.

  Safety:
    - Read-before-write: pass the SHA-256 hash from a prior load as
      AExpectedHash; the write is refused (tfStaleHash) when the file changed
      underneath. Same optimistic-concurrency idea as MCP.EditTracker, here for
      files on disk.
    - Atomic write: content goes to a temp sibling, then MoveFileEx replaces
      the target in one step (no half-written file on crash).
    - BOM preservation matters for Delphi: a .pas with non-ASCII literals must
      keep its UTF-8 BOM or the compiler reads it as ANSI (mojibake). See the
      project note feedback-delphi-utf8-bom.

  Boundary: RTL + Winapi only (MoveFileEx). No ToolsAPI, no Vcl./FMX. Depends
  on the pure Aefos.Tools.Text engine.

  Naming convention: MCP\Source\Tools\NAMING.md.
*)

interface

uses
  System.SysUtils,
  Aefos.Tools.Text;

type
  // A pure Tools.Text edit applied to a file's content (load -> edit -> save).
  TToolTextEdit = reference to function(const AContent: string): TToolTextResult;

  // Byte-order mark / encoding of a file on disk.
  TToolFileBom = (
    fbNone,     // no BOM (decoded/encoded as UTF-8 without preamble)
    fbUtf8,     // EF BB BF
    fbUtf16LE,  // FF FE
    fbUtf16BE   // FE FF
  );

  TToolFileOutcome = (
    tfApplied,    // operation succeeded
    tfNotFound,   // the file does not exist
    tfReadError,  // the file could not be read
    tfWriteError, // the file could not be written
    tfStaleHash,  // AExpectedHash no longer matches the file content
    tfTextError   // the underlying Tools.Text edit failed (see TextOutcome)
  );

  TToolFileInfo = record
    Exists: Boolean;
    Bom: TToolFileBom;
    Eol: string;      // detected dominant EOL
    Hash: string;     // SHA-256 (hex) of the decoded content
    Content: string;  // decoded text, without the BOM
  end;

  TToolFileResult = record
    Outcome: TToolFileOutcome;
    TextOutcome: TToolTextOutcome; // meaningful only when Outcome = tfTextError
    NewHash: string;               // SHA-256 of the written content
    Bom: TToolFileBom;             // BOM that was preserved on write
    function Ok: Boolean;
    function OutcomeText: string;
  end;

  // Disk IO layer for the tool suite as a sealed static namespace (see the unit
  // header). Never instantiated.
  TFileIO = class sealed
  public
    // ── Detection / hashing ──────────────────────────────────────────────────

    // The BOM implied by the leading bytes of ABytes.
    class function DetectBom(const ABytes: TBytes): TToolFileBom; static;

    // SHA-256 (lowercase hex) of the UTF-8 bytes of AContent. Matches the
    // MCP.EditTracker hash semantics so the two agree on a given content.
    class function HashContent(const AContent: string): string; static;

    // Human-readable BOM label.
    class function BomText(const ABom: TToolFileBom): string; static;

    // ── Raw load / save ──────────────────────────────────────────────────────

    // Reads APath, decoding by its BOM (UTF-8 when none). Fills AInfo.
    class function Load(const APath: string; out AInfo: TToolFileInfo): TToolFileOutcome; static;

    // Writes AContent to APath atomically, encoding it with ABom. Creates the
    // target directory when missing. The caller controls EOL via the content.
    class function Save(const APath, AContent: string;
      const ABom: TToolFileBom): TToolFileOutcome; static;

    // ── Edit-on-disk (load -> Tools.Text -> save, BOM preserved) ─────────────

    // Loads APath, optionally guards on AExpectedHash, runs AEdit on the content,
    // and writes the result back preserving the file's BOM.
    class function ApplyText(const APath, AExpectedHash: string;
      const AEdit: TToolTextEdit): TToolFileResult; static;

    // Named conveniences over ApplyText — one per Tools.Text mutator. Pass
    // AExpectedHash = '' to skip the read-before-write guard.
    class function InsertLine(const APath, AExpectedHash: string;
      const ALine: Integer; const AText: string): TToolFileResult; static;
    class function ReplaceLine(const APath, AExpectedHash: string;
      const ALine: Integer; const AText: string): TToolFileResult; static;
    class function RemoveLine(const APath, AExpectedHash: string;
      const ALine: Integer): TToolFileResult; static;
    class function RemoveLines(const APath, AExpectedHash: string;
      const AFromLine, AToLine: Integer): TToolFileResult; static;
    class function AppendLine(const APath, AExpectedHash: string;
      const AText: string): TToolFileResult; static;
    class function InsertAt(const APath, AExpectedHash: string;
      const ALine, AColumn: Integer; const AText: string): TToolFileResult; static;
    class function DeleteRange(const APath, AExpectedHash: string;
      const AStartLine, AStartCol, AEndLine, AEndCol: Integer): TToolFileResult; static;
    class function ReplaceRange(const APath, AExpectedHash: string;
      const AStartLine, AStartCol, AEndLine, AEndCol: Integer;
      const AText: string): TToolFileResult; static;

    // Re-saves APath with ATargetBom, content unchanged. Use to add a UTF-8 BOM to
    // a .pas that lacks one (fixes the ANSI/mojibake compilation trap).
    class function ConvertBom(const APath, AExpectedHash: string;
      const ATargetBom: TToolFileBom): TToolFileResult; static;
  end;

implementation

uses
  System.IOUtils,
  System.Hash,
  Winapi.Windows;

{ TToolFileResult }

function TToolFileResult.Ok: Boolean;
begin
  Result := Outcome = tfApplied;
end;

function TToolFileResult.OutcomeText: string;
begin
  case Outcome of
    tfApplied:    Result := 'applied';
    tfNotFound:   Result := 'not-found';
    tfReadError:  Result := 'read-error';
    tfWriteError: Result := 'write-error';
    tfStaleHash:  Result := 'stale-hash';
    tfTextError:  Result := 'text-error';
  else
    Result := 'unknown';
  end;
end;

// ── Detection / hashing ──────────────────────────────────────────────────

class function TFileIO.DetectBom(const ABytes: TBytes): TToolFileBom;
begin
  if (Length(ABytes) >= 3) and (ABytes[0] = $EF) and (ABytes[1] = $BB)
    and (ABytes[2] = $BF) then
    Exit(fbUtf8);
  if (Length(ABytes) >= 2) and (ABytes[0] = $FF) and (ABytes[1] = $FE) then
    Exit(fbUtf16LE);
  if (Length(ABytes) >= 2) and (ABytes[0] = $FE) and (ABytes[1] = $FF) then
    Exit(fbUtf16BE);
  Result := fbNone;
end;

class function TFileIO.HashContent(const AContent: string): string;
var
  LHash: THashSHA2;
begin
  LHash := THashSHA2.Create(THashSHA2.TSHA2Version.SHA256);
  LHash.Update(TEncoding.UTF8.GetBytes(AContent));
  Result := LowerCase(LHash.HashAsString);
end;

class function TFileIO.BomText(const ABom: TToolFileBom): string;
begin
  case ABom of
    fbNone:    Result := 'none';
    fbUtf8:    Result := 'utf-8';
    fbUtf16LE: Result := 'utf-16le';
    fbUtf16BE: Result := 'utf-16be';
  else
    Result := 'unknown';
  end;
end;

// ── Encode / decode ──────────────────────────────────────────────────────

function _Encode(const AContent: string; const ABom: TToolFileBom): TBytes;
var
  LEnc: TEncoding;
  LWithPreamble: Boolean;
begin
  case ABom of
    fbUtf16LE: begin LEnc := TEncoding.Unicode;          LWithPreamble := True; end;
    fbUtf16BE: begin LEnc := TEncoding.BigEndianUnicode; LWithPreamble := True; end;
    fbUtf8:    begin LEnc := TEncoding.UTF8;              LWithPreamble := True; end;
  else
    LEnc := TEncoding.UTF8; LWithPreamble := False;
  end;
  if LWithPreamble then
    Result := LEnc.GetPreamble + LEnc.GetBytes(AContent)
  else
    Result := LEnc.GetBytes(AContent);
end;

function _Decode(const ABytes: TBytes; out ABom: TToolFileBom): string;
var
  LEnc: TEncoding;
  LStart: Integer;
begin
  ABom := TFileIO.DetectBom(ABytes);
  case ABom of
    fbUtf8:    begin LEnc := TEncoding.UTF8;              LStart := 3; end;
    fbUtf16LE: begin LEnc := TEncoding.Unicode;          LStart := 2; end;
    fbUtf16BE: begin LEnc := TEncoding.BigEndianUnicode; LStart := 2; end;
  else
    LEnc := TEncoding.UTF8; LStart := 0;
  end;
  Result := LEnc.GetString(ABytes, LStart, Length(ABytes) - LStart);
end;

// ── Raw load / save ──────────────────────────────────────────────────────

class function TFileIO.Load(const APath: string; out AInfo: TToolFileInfo): TToolFileOutcome;
var
  LBytes: TBytes;
begin
  AInfo := Default(TToolFileInfo);
  if not TFile.Exists(APath) then
    Exit(tfNotFound);
  try
    LBytes := TFile.ReadAllBytes(APath);
  except
    Exit(tfReadError);
  end;
  AInfo.Exists := True;
  AInfo.Content := _Decode(LBytes, AInfo.Bom);
  AInfo.Eol := TTextEditor.DetectEol(AInfo.Content);
  AInfo.Hash := TFileIO.HashContent(AInfo.Content);
  Result := tfApplied;
end;

class function TFileIO.Save(const APath, AContent: string;
  const ABom: TToolFileBom): TToolFileOutcome;
var
  LBytes: TBytes;
  LTemp, LDir: string;
begin
  try
    LDir := TPath.GetDirectoryName(APath);
    if (LDir <> '') and not TDirectory.Exists(LDir) then
      TDirectory.CreateDirectory(LDir);
    LBytes := _Encode(AContent, ABom);
    LTemp := APath + '.dstmp';
    TFile.WriteAllBytes(LTemp, LBytes);
    if not MoveFileEx(PChar(LTemp), PChar(APath),
      MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
    begin
      try TFile.Delete(LTemp); except end;
      Exit(tfWriteError);
    end;
    Result := tfApplied;
  except
    Result := tfWriteError;
  end;
end;

// ── Edit-on-disk ─────────────────────────────────────────────────────────

function _FileFail(const AOutcome: TToolFileOutcome): TToolFileResult;
begin
  Result := Default(TToolFileResult);
  Result.Outcome := AOutcome;
end;

class function TFileIO.ApplyText(const APath, AExpectedHash: string;
  const AEdit: TToolTextEdit): TToolFileResult;
var
  LInfo: TToolFileInfo;
  LLoad, LSave: TToolFileOutcome;
  LEdit: TToolTextResult;
begin
  LLoad := TFileIO.Load(APath, LInfo);
  if LLoad <> tfApplied then
    Exit(_FileFail(LLoad));
  if (AExpectedHash <> '') and not SameText(AExpectedHash, LInfo.Hash) then
    Exit(_FileFail(tfStaleHash));
  LEdit := AEdit(LInfo.Content);
  if not LEdit.Ok then
  begin
    Result := _FileFail(tfTextError);
    Result.TextOutcome := LEdit.Outcome;
    Exit;
  end;
  LSave := TFileIO.Save(APath, LEdit.Content, LInfo.Bom);
  if LSave <> tfApplied then
    Exit(_FileFail(LSave));
  Result := Default(TToolFileResult);
  Result.Outcome := tfApplied;
  Result.Bom := LInfo.Bom;
  Result.NewHash := TFileIO.HashContent(LEdit.Content);
end;

class function TFileIO.InsertLine(const APath, AExpectedHash: string;
  const ALine: Integer; const AText: string): TToolFileResult;
begin
  Result := TFileIO.ApplyText(APath, AExpectedHash,
    function(const AContent: string): TToolTextResult
    begin
      Result := TTextEditor.InsertLine(AContent, ALine, AText);
    end);
end;

class function TFileIO.ReplaceLine(const APath, AExpectedHash: string;
  const ALine: Integer; const AText: string): TToolFileResult;
begin
  Result := TFileIO.ApplyText(APath, AExpectedHash,
    function(const AContent: string): TToolTextResult
    begin
      Result := TTextEditor.ReplaceLine(AContent, ALine, AText);
    end);
end;

class function TFileIO.RemoveLine(const APath, AExpectedHash: string;
  const ALine: Integer): TToolFileResult;
begin
  Result := TFileIO.ApplyText(APath, AExpectedHash,
    function(const AContent: string): TToolTextResult
    begin
      Result := TTextEditor.RemoveLine(AContent, ALine);
    end);
end;

class function TFileIO.RemoveLines(const APath, AExpectedHash: string;
  const AFromLine, AToLine: Integer): TToolFileResult;
begin
  Result := TFileIO.ApplyText(APath, AExpectedHash,
    function(const AContent: string): TToolTextResult
    begin
      Result := TTextEditor.RemoveLines(AContent, AFromLine, AToLine);
    end);
end;

class function TFileIO.AppendLine(const APath, AExpectedHash: string;
  const AText: string): TToolFileResult;
begin
  Result := TFileIO.ApplyText(APath, AExpectedHash,
    function(const AContent: string): TToolTextResult
    begin
      Result := TTextEditor.AppendLine(AContent, AText);
    end);
end;

class function TFileIO.InsertAt(const APath, AExpectedHash: string;
  const ALine, AColumn: Integer; const AText: string): TToolFileResult;
begin
  Result := TFileIO.ApplyText(APath, AExpectedHash,
    function(const AContent: string): TToolTextResult
    begin
      Result := TTextEditor.InsertAt(AContent, ALine, AColumn, AText);
    end);
end;

class function TFileIO.DeleteRange(const APath, AExpectedHash: string;
  const AStartLine, AStartCol, AEndLine, AEndCol: Integer): TToolFileResult;
begin
  Result := TFileIO.ApplyText(APath, AExpectedHash,
    function(const AContent: string): TToolTextResult
    begin
      Result := TTextEditor.DeleteRange(AContent, AStartLine, AStartCol,
        AEndLine, AEndCol);
    end);
end;

class function TFileIO.ReplaceRange(const APath, AExpectedHash: string;
  const AStartLine, AStartCol, AEndLine, AEndCol: Integer;
  const AText: string): TToolFileResult;
begin
  Result := TFileIO.ApplyText(APath, AExpectedHash,
    function(const AContent: string): TToolTextResult
    begin
      Result := TTextEditor.ReplaceRange(AContent, AStartLine, AStartCol,
        AEndLine, AEndCol, AText);
    end);
end;

class function TFileIO.ConvertBom(const APath, AExpectedHash: string;
  const ATargetBom: TToolFileBom): TToolFileResult;
var
  LInfo: TToolFileInfo;
  LLoad, LSave: TToolFileOutcome;
begin
  LLoad := TFileIO.Load(APath, LInfo);
  if LLoad <> tfApplied then
    Exit(_FileFail(LLoad));
  if (AExpectedHash <> '') and not SameText(AExpectedHash, LInfo.Hash) then
    Exit(_FileFail(tfStaleHash));
  LSave := TFileIO.Save(APath, LInfo.Content, ATargetBom);
  if LSave <> tfApplied then
    Exit(_FileFail(LSave));
  Result := Default(TToolFileResult);
  Result.Outcome := tfApplied;
  Result.Bom := ATargetBom;
  Result.NewHash := LInfo.Hash; // content unchanged
end;

end.
