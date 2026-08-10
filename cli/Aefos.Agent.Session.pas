unit Aefos.Agent.Session;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  Aefos Agent CLI - conversation session store (RTL-only).

  One JSON file per conversation (sessions root defaults to
  %APPDATA%\Aefos\sessions\<id>.json) holding the ordered message history.
  This is what gives local models multi-turn memory AND --resume parity with
  the CLI executors (the chat's send-during-run queue re-dispatches with
  --resume). Every function takes the root as a parameter so the pure suite
  exercises the store against a scratch directory.
}

interface

uses
  {$IFDEF FPC}
  Windows,
  SysUtils,
  Classes,
  Aefos.Compat.IO,
  Aefos.Compat.Json,
  {$ELSE}
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  Aefos.Compat.IO,
  System.JSON,
  {$ENDIF}
  Aefos.Provider.Ollama.Core;

type
  { Static, sealed namespace for the conversation session store. Never
    instantiated; the class IS the namespace, so the old 'Session'/'Agent' name
    prefixes are gone. }
  TAgentSession = class sealed
  public
    // New collision-safe id, filesystem- and IsValidSessionId-friendly
    // (lowercase hex of a GUID, dash-separated groups preserved).
    class function NewId: string; static;

    // %APPDATA%\Aefos\sessions - the production root. Tests pass their own.
    class function DefaultRoot: string; static;

    // Full path of a session file under ARoot. AId MUST already be validated
    // (TAgentArgs.IsValidSessionId) - this is a pure join, not a sanitizer.
    class function FilePath(const ARoot, AId: string): string; static;

    // Loads the ordered history. False + AError when the file is missing or
    // malformed; the caller decides whether that is fatal (--resume of an
    // unknown id) or fine (fresh session).
    class function LoadMessages(const ARoot, AId: string;
      out AMessages: TArray<TOllamaMessage>; out AError: string): Boolean; static;

    // Writes the full ordered history (create or overwrite), UTF-8 without BOM.
    // Raises on I/O failure - the CLI surfaces it as a plain error and exits.
    class procedure SaveMessages(const ARoot, AId: string;
      const AMessages: TArray<TOllamaMessage>); static;
  end;

implementation

{$IFDEF FPC}
const
  // Present in Winapi.Windows but not FPC's Windows unit (3.2.2).
  MOVEFILE_WRITE_THROUGH = $00000008;
{$ENDIF}

class function TAgentSession.NewId: string;
var
  LGuid: TGUID;
begin
  CreateGUID(LGuid);
  Result := LowerCase(GUIDToString(LGuid));
  // '{xxxxxxxx-xxxx-...}' -> 'xxxxxxxx-xxxx-...' (keep dashes: valid id chars).
  // StringReplace(rfReplaceAll) is byte-identical to string.Replace (no
  // TStringHelper on FPC 3.2.2).
  Result := StringReplace(Result, '{', '', [rfReplaceAll]);
  Result := StringReplace(Result, '}', '', [rfReplaceAll]);
end;

class function TAgentSession.DefaultRoot: string;
begin
  Result := TPath.Combine(TPath.Combine(
    GetEnvironmentVariable('APPDATA'), 'Aefos'), 'sessions');
end;

class function TAgentSession.FilePath(const ARoot, AId: string): string;
begin
  Result := TPath.Combine(ARoot, AId + '.json');
end;

class function TAgentSession.LoadMessages(const ARoot, AId: string;
  out AMessages: TArray<TOllamaMessage>; out AError: string): Boolean;
var
  LPath, LRole, LContent: string;
  LRoot: TJSONValue;
  LArr: TJSONArray;
  LItem, LCallsVal: TJSONValue;
  LObj: TJSONObject;
  LCount: Integer;
begin
  Result := False;
  AMessages := nil;
  AError := '';
  LPath := TAgentSession.FilePath(ARoot, AId);
  if not TFile.Exists(LPath) then
  begin
    AError := 'Session "' + AId + '" was not found.';
    Exit;
  end;
  LRoot := TJSONObject.ParseJSONValue(
    TAefosText.ReadAllUtf8(LPath));
  try
    if not (LRoot is TJSONObject) then
    begin
      AError := 'Session "' + AId + '" is not readable (malformed file).';
      Exit;
    end;
    // TryGetValue, not `as`: a "messages" key that exists but is NOT an array
    // (hand-edited/corrupt file) would make `as TJSONArray` raise EInvalidCast,
    // breaking the "False + AError" contract (review S8, 2026-07-09).
    LArr := nil;
    // Parenthesise generic calls adjacent to not/or (FPC generic-call parse).
    if not (TJSONObject(LRoot).TryGetValue<TJSONArray>('messages', LArr)) or
      (LArr = nil) then
    begin
      AError := 'Session "' + AId + '" is not readable (no messages).';
      Exit;
    end;
    LCount := 0;
    SetLength(AMessages, LArr.Count);
    for LItem in LArr do
    begin
      if not (LItem is TJSONObject) then
        Continue;
      LObj := TJSONObject(LItem);
      if not (LObj.TryGetValue<string>('role', LRole)) then
        Continue;
      // Content is optional: an assistant-with-tool_calls turn often has none.
      if not (LObj.TryGetValue<string>('content', LContent)) then
        LContent := '';
      AMessages[LCount] := TOllamaMessage.New(LRole, LContent);
      // Restore the agent-loop fields so a resumed agent turn keeps its tool
      // fidelity (review S1, 2026-07-09): role:"tool" -> tool_name; an
      // assistant that called tools -> the tool_calls array (raw).
      LObj.TryGetValue<string>('tool_name', AMessages[LCount].ToolName);
      LCallsVal := LObj.GetValue('tool_calls');
      if LCallsVal is TJSONArray then
        AMessages[LCount].ToolCallsJson := LCallsVal.ToJSON;
      Inc(LCount);
    end;
    SetLength(AMessages, LCount);
    Result := True;
  finally
    LRoot.Free;
  end;
end;

class procedure TAgentSession.SaveMessages(const ARoot, AId: string;
  const AMessages: TArray<TOllamaMessage>);
var
  LRoot: TJSONObject;
  LArr: TJSONArray;
  LObj: TJSONObject;
  LCalls: TJSONValue;
  LPath, LTmp: string;
  LErr: DWORD;
  LIndex: Integer;
begin
  TDirectory.CreateDirectory(ARoot);
  LRoot := TJSONObject.Create;
  try
    LArr := TJSONArray.Create;
    LRoot.AddPair('messages', LArr);
    for LIndex := 0 to High(AMessages) do
    begin
      LObj := TJSONObject.Create;
      LArr.AddElement(LObj);
      LObj.AddPair('role', AMessages[LIndex].Role);
      LObj.AddPair('content', AMessages[LIndex].Content);
      // Persist the agent-loop fields (review S1): a resumed session must keep
      // tool linkage. Emitted only when carried, so plain chat is unchanged.
      if AMessages[LIndex].ToolName <> '' then
        LObj.AddPair('tool_name', AMessages[LIndex].ToolName);
      if AMessages[LIndex].ToolCallsJson <> '' then
      begin
        LCalls := TJSONObject.ParseJSONValue(AMessages[LIndex].ToolCallsJson);
        if LCalls is TJSONArray then
          LObj.AddPair('tool_calls', LCalls)
        else
          LCalls.Free; // malformed: drop rather than emit garbage
      end;
    end;
    // Atomic write (review S5): write a temp file then MoveFileEx-replace, so a
    // kill/crash mid-save (the chat's Stop hard-kills this process) can never
    // truncate the live session file. UTF-8 without BOM (machine-read JSON).
    LPath := TAgentSession.FilePath(ARoot, AId);
    LTmp := LPath + '.tmp';
    TFile.WriteAllBytes(LTmp, TEncoding.UTF8.GetBytes(LRoot.ToJSON));
    // Explicit -W on FPC: its Windows unit's unsuffixed MoveFileEx/DeleteFile
    // take ANSI PChar, but PChar is PWideChar under {$mode delphiunicode}.
    {$IFDEF FPC}
    if not MoveFileExW(PWideChar(LTmp), PWideChar(LPath),
      MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
    begin
      // Capture the move's error BEFORE DeleteFile clobbers GetLastError to 0.
      LErr := GetLastError;
      DeleteFileW(PWideChar(LTmp));
      RaiseLastOSError(LErr);
    end;
    {$ELSE}
    if not MoveFileEx(PChar(LTmp), PChar(LPath),
      MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
    begin
      // Capture the move's error BEFORE DeleteFile succeeds and clobbers
      // GetLastError to 0 (spot-check LOW, 2026-07-09).
      LErr := GetLastError;
      DeleteFile(PChar(LTmp));
      RaiseLastOSError(LErr);
    end;
    {$ENDIF}
  finally
    LRoot.Free;
  end;
end;

end.
