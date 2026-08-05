unit Aefos.Lazarus.PyToolsStore;

{ Aefos AI - Lazarus edition: PyTools file store (LCL-free model).

  The pure file/JSON model behind the Lazarus "Python Tools" manager window
  (Aefos.Lazarus.PyToolsWindow). It is the exact same drop-a-folder store the
  RAD Studio plugin uses - see source\mcp\OTA\Aefos.OTA.MCP.PyToolsManager.pas
  (the Delphi manager dialog) and source\mcp\Core\Aefos.MCP.Tools.PyTools.pas
  (the Delphi MCP registrar that loads them at server start):

    %APPDATA%\Aefos\pytools\<name>\tool.json   (manifest)
    %APPDATA%\Aefos\pytools\<name>\main.py      (JSON stdin -> JSON stdout)

  tool.json fields mirror the Delphi manager byte-for-byte in MEANING:
    name (identifier), description, inputSchema (a JSON object), entry
    ("main.py"), python ("" = auto-resolve), timeoutMs.

  Because the folder layout AND %APPDATA%\Aefos root are identical to the Delphi
  side (Aefos.Lazarus.Options resolves the same %APPDATA%\Aefos), a tool created
  here is loaded verbatim by the RAD Studio MCP host, and vice-versa - one store,
  both editions.

  SEAM / TODO (honest degrade): the Lazarus hosted MCP server
  (Aefos.Lazarus.McpHost / Aefos.Lazarus.McpTools) does NOT yet REGISTER these
  tools on its pipe - that runtime (interpreter resolve + subprocess run +
  consent/audit gate) lives in source\mcp\Tools (Winapi + System.JSON) and is not
  on the Lazarus package unit path. This unit + the window are the MANAGE side
  (create/edit/delete the identical files); the RUN side on Lazarus is a separate
  future slice. Until then the files these produce are served by the Delphi host
  when the same %APPDATA% profile drives RAD Studio.

  Deliberately LCL-free (SysUtils/Classes/fpjson only) so a headless proof can
  round-trip the store with no GUI. All literals are
  ASCII, so the file needs no BOM.

  Mode delphi: string = UTF-8 AnsiString, conversion-free with the LCL window and
  with fpjson (whose TJSONStringType is UTF-8). }

{$mode delphi}
{$H+}

interface

type
  { One PyTool as the window edits it. SchemaJson is the pretty-printed
    inputSchema JSON text; Code is the main.py body. }
  TAefosPyToolSpec = record
    Name: string;
    Description: string;
    TimeoutMs: Integer;
    SchemaJson: string;
    Code: string;
  end;

  TAefosPyToolNames = array of string;

  { The store as a sealed static namespace (no loose routines - house style). All
    methods take the root explicitly so the headless proof can point them at a
    temp folder; the window passes DefaultRoot. }
  TAefosLazPyToolsStore = class
  public
    const
      DefaultTimeoutMs = 10000;
      EntryFile        = 'main.py';
      ManifestFile     = 'tool.json';
    // %APPDATA%\Aefos\pytools - the SAME root the RAD Studio plugin uses.
    class function DefaultRoot: string; static;
    // A non-empty identifier of letters, digits and underscore (mirrors the
    // Delphi manager's _IsValidToolName).
    class function IsValidName(const AName: string): Boolean; static;
    // Default templates for a brand-new tool (identical to the Delphi manager).
    class function MainPyTemplate: string; static;
    class function SchemaTemplate: string; static;
    // The <name> of every folder under ARoot that carries a tool.json.
    class function ListTools(const ARoot: string): TAefosPyToolNames; static;
    // Loads <ARoot>\<AName>\tool.json (+ its entry file) into ASpec. False when
    // the folder/manifest is missing or the manifest is not a JSON object.
    class function Load(const ARoot, AName: string;
      out ASpec: TAefosPyToolSpec): Boolean; static;
    // Writes ASpec as <ARoot>\<Name>\tool.json + main.py. Validates the name and
    // that SchemaJson parses (empty schema falls back to {"type":"object"}).
    // Returns False with AError set on any failure.
    class function Save(const ARoot: string; const ASpec: TAefosPyToolSpec;
      out AError: string): Boolean; static;
    // Removes <ARoot>\<AName> and its contents. True also when it was absent.
    class function Delete(const ARoot, AName: string;
      out AError: string): Boolean; static;
  end;

implementation

uses
  SysUtils,
  Classes,
  fpjson,
  jsonparser;

{ ---- file helpers (UTF-8 bytes in a mode-delphi AnsiString) --------------- }

// Reads AFile as raw UTF-8 bytes into the string (BOM stripped). In mode delphi
// the string IS the UTF-8 byte sequence the LCL and fpjson both expect.
function _ReadAllText(const AFile: string): string;
var
  LStream: TFileStream;
  LSize: Int64;
begin
  Result := '';
  LStream := TFileStream.Create(AFile, fmOpenRead or fmShareDenyWrite);
  try
    LSize := LStream.Size;
    if LSize > 0 then
    begin
      SetLength(Result, LSize);
      LStream.ReadBuffer(Result[1], LSize);
    end;
  finally
    LStream.Free;
  end;
  // Strip a UTF-8 BOM if a Delphi-written file carried one (TEncoding.UTF8 does).
  if (Length(Result) >= 3) and (Result[1] = #$EF) and (Result[2] = #$BB)
    and (Result[3] = #$BF) then
    Delete(Result, 1, 3);
end;

// Writes AText as UTF-8 bytes (no BOM). The RAD Studio reader (TEncoding.UTF8)
// and Python both accept BOM-less UTF-8, so the tool round-trips both editions.
procedure _WriteAllText(const AFile, AText: string);
var
  LStream: TFileStream;
begin
  LStream := TFileStream.Create(AFile, fmCreate);
  try
    if Length(AText) > 0 then
      LStream.WriteBuffer(AText[1], Length(AText));
  finally
    LStream.Free;
  end;
end;

// Parses AText, returning nil (never raising) on malformed input.
function _TryParse(const AText: string): TJSONData;
begin
  Result := nil;
  try
    Result := GetJSON(AText);
  except
    Result := nil;
  end;
end;

// Recursively deletes ADir and everything under it. True on full success.
function _DeleteDirTree(const ADir: string): Boolean;
var
  LRec: TSearchRec;
  LBase, LFull: string;
begin
  Result := True;
  LBase := IncludeTrailingPathDelimiter(ADir);
  if FindFirst(LBase + '*', faAnyFile, LRec) = 0 then
    try
      repeat
        if (LRec.Name = '.') or (LRec.Name = '..') then
          Continue;
        LFull := LBase + LRec.Name;
        if (LRec.Attr and faDirectory) <> 0 then
          Result := _DeleteDirTree(LFull) and Result
        else
        begin
          FileSetAttr(LFull, faNormal);
          Result := DeleteFile(LFull) and Result;
        end;
      until FindNext(LRec) <> 0;
    finally
      FindClose(LRec);
    end;
  Result := RemoveDir(ADir) and Result;
end;

{ ---- TAefosLazPyToolsStore ------------------------------------------------- }

class function TAefosLazPyToolsStore.DefaultRoot: string;
var
  LAppData: string;
begin
  // %APPDATA%\Aefos\pytools - identical to Aefos.Lazarus.Options' %APPDATA%\Aefos
  // and the RAD Studio plugin's TMCPProvision.AppDataDir + 'pytools'.
  LAppData := SysUtils.GetEnvironmentVariable('APPDATA');
  Result := IncludeTrailingPathDelimiter(LAppData) + 'Aefos' + PathDelim
    + 'pytools';
end;

class function TAefosLazPyToolsStore.IsValidName(const AName: string): Boolean;
var
  LIndex: Integer;
  LCh: Char;
begin
  Result := AName <> '';
  if not Result then
    Exit;
  for LIndex := 1 to Length(AName) do
  begin
    LCh := AName[LIndex];
    if not (((LCh >= 'A') and (LCh <= 'Z'))
         or ((LCh >= 'a') and (LCh <= 'z'))
         or ((LCh >= '0') and (LCh <= '9'))
         or (LCh = '_')) then
      Exit(False);
  end;
end;

class function TAefosLazPyToolsStore.MainPyTemplate: string;
begin
  Result :=
    '"""Aefos Python tool. Contract: JSON in on stdin, JSON out on stdout."""'
      + sLineBreak +
    'import sys, json' + sLineBreak + sLineBreak +
    'try:' + sLineBreak +
    '    sys.stdin.reconfigure(encoding="utf-8")' + sLineBreak +
    '    sys.stdout.reconfigure(encoding="utf-8")' + sLineBreak +
    'except Exception:' + sLineBreak +
    '    pass' + sLineBreak + sLineBreak +
    'payload = json.load(sys.stdin)' + sLineBreak +
    'text = payload.get("text", "")' + sLineBreak +
    'json.dump({"result": text.upper()}, sys.stdout, ensure_ascii=False)'
      + sLineBreak;
end;

class function TAefosLazPyToolsStore.SchemaTemplate: string;
begin
  Result :=
    '{' + sLineBreak +
    '  "type": "object",' + sLineBreak +
    '  "properties": {' + sLineBreak +
    '    "text": { "type": "string", "description": "text to transform" }'
      + sLineBreak +
    '  },' + sLineBreak +
    '  "required": ["text"]' + sLineBreak +
    '}';
end;

class function TAefosLazPyToolsStore.ListTools(
  const ARoot: string): TAefosPyToolNames;
var
  LRec: TSearchRec;
  LBase: string;
begin
  SetLength(Result, 0);
  if not DirectoryExists(ARoot) then
    Exit;
  LBase := IncludeTrailingPathDelimiter(ARoot);
  if FindFirst(LBase + '*', faDirectory, LRec) = 0 then
    try
      repeat
        if (LRec.Attr and faDirectory) = 0 then
          Continue;
        if (LRec.Name = '.') or (LRec.Name = '..') then
          Continue;
        if FileExists(LBase + LRec.Name + PathDelim + ManifestFile) then
        begin
          SetLength(Result, Length(Result) + 1);
          Result[High(Result)] := LRec.Name;
        end;
      until FindNext(LRec) <> 0;
    finally
      FindClose(LRec);
    end;
end;

class function TAefosLazPyToolsStore.Load(const ARoot, AName: string;
  out ASpec: TAefosPyToolSpec): Boolean;
var
  LDir, LManifest, LCodePath, LEntry: string;
  LData, LNode: TJSONData;
  LJson: TJSONObject;
begin
  Result := False;
  ASpec := Default(TAefosPyToolSpec);
  ASpec.TimeoutMs := DefaultTimeoutMs;
  LDir := IncludeTrailingPathDelimiter(ARoot) + AName;
  LManifest := IncludeTrailingPathDelimiter(LDir) + ManifestFile;
  if not FileExists(LManifest) then
    Exit;
  LData := _TryParse(_ReadAllText(LManifest));
  if not (LData is TJSONObject) then
  begin
    LData.Free;
    Exit;
  end;
  LJson := TJSONObject(LData);
  try
    ASpec.Name := LJson.Get('name', AName);
    ASpec.Description := LJson.Get('description', '');
    LNode := LJson.Find('timeoutMs');
    if (LNode <> nil) and (LNode.JSONType = jtNumber) then
      ASpec.TimeoutMs := LNode.AsInteger
    else
      ASpec.TimeoutMs := DefaultTimeoutMs;
    LEntry := LJson.Get('entry', EntryFile);
    LNode := LJson.Find('inputSchema');
    if LNode <> nil then
      ASpec.SchemaJson := LNode.FormatJSON
    else
      ASpec.SchemaJson := '';
    LCodePath := IncludeTrailingPathDelimiter(LDir) + LEntry;
    if FileExists(LCodePath) then
      ASpec.Code := _ReadAllText(LCodePath)
    else
      ASpec.Code := '';
    Result := True;
  finally
    LJson.Free;
  end;
end;

class function TAefosLazPyToolsStore.Save(const ARoot: string;
  const ASpec: TAefosPyToolSpec; out AError: string): Boolean;
var
  LName, LDir, LSchemaText: string;
  LSchema: TJSONData;
  LManifest: TJSONObject;
  LTimeout: Integer;
begin
  Result := False;
  AError := '';
  LName := Trim(ASpec.Name);
  if not IsValidName(LName) then
  begin
    AError := 'Name must be a non-empty identifier (letters, digits, underscore).';
    Exit;
  end;
  // inputSchema must be valid JSON (it becomes the tool's schema).
  LSchemaText := Trim(ASpec.SchemaJson);
  if LSchemaText = '' then
    LSchemaText := '{"type":"object"}';
  LSchema := _TryParse(LSchemaText);
  if LSchema = nil then
  begin
    AError := 'inputSchema is not valid JSON.';
    Exit;
  end;
  LTimeout := ASpec.TimeoutMs;
  if LTimeout <= 0 then
    LTimeout := DefaultTimeoutMs;

  LDir := IncludeTrailingPathDelimiter(ARoot) + LName;
  try
    if not DirectoryExists(LDir) then
      ForceDirectories(LDir);
    LManifest := TJSONObject.Create;
    try
      LManifest.Add('name', LName);
      LManifest.Add('description', ASpec.Description);
      LManifest.Add('inputSchema', LSchema); // fpjson takes node ownership
      LSchema := nil;
      LManifest.Add('entry', EntryFile);
      LManifest.Add('python', '');
      LManifest.Add('timeoutMs', LTimeout);
      _WriteAllText(IncludeTrailingPathDelimiter(LDir) + ManifestFile,
        LManifest.FormatJSON);
    finally
      LManifest.Free;
    end;
    _WriteAllText(IncludeTrailingPathDelimiter(LDir) + EntryFile, ASpec.Code);
    Result := True;
  except
    on E: Exception do
    begin
      LSchema.Free; // nil-safe once ownership was transferred to the manifest
      AError := 'Could not save the tool: ' + E.Message;
      Result := False;
    end;
  end;
end;

class function TAefosLazPyToolsStore.Delete(const ARoot, AName: string;
  out AError: string): Boolean;
var
  LDir: string;
begin
  Result := False;
  AError := '';
  LDir := IncludeTrailingPathDelimiter(ARoot) + AName;
  try
    if DirectoryExists(LDir) then
      Result := _DeleteDirTree(LDir)
    else
      Result := True;
    if not Result then
      AError := 'Could not delete the tool folder (a file may be locked).';
  except
    on E: Exception do
    begin
      AError := 'Could not delete: ' + E.Message;
      Result := False;
    end;
  end;
end;

end.
