unit Aefos.Lazarus.SessionStore;

{ TAefosLazJsonSessionStore -- the Lazarus chat session store (JSON, per file).

  The Lazarus twin of the Delphi ISessionStore
  (source/chat/Core/Aefos.OTA.Chat.Core.SessionStore.pas). It MIRRORS that unit's
  SHAPE -- persist / list / load / delete a chat session (id, title, times, the
  recorded conversation) so the header "sessions history" panel can list them and
  a click can replay one -- but it is a DIFFERENT implementation on purpose: the
  Delphi default provider is SQLite (SessionStore.SQLite), and porting SQLite to
  FPC is out of scope for this slice. This one is a small, dependency-free JSON
  store: one file per session at

      <root>\sessions\<id>.json

  ONE-BRAIN ALIGNMENT (owner rule, 2026-07-17): a user may hold a Delphi licence
  AND use Lazarus in parallel, so both editions share %APPDATA%\Aefos\. This store
  lives under the SAME root (<root> = %APPDATA%\Aefos) in the SAME folder the Delphi
  side uses for sessions (SessionsDir = ...\Aefos\sessions) and -- deliberately --
  writes the EXACT legacy per-session JSON shape the Delphi SQLite provider imports
  from there (SessionStore.SQLite._ReadJsonFile: id / title / cli / project /
  updated [ISO-8601, DateToISO8601] / count / messages [role/text]). So a session
  created in Lazarus is picked up by the Delphi brain on its one-time,
  non-destructive import. It stays JSON (not the Delphi SQLite aefos.db) ONLY
  because SQLite is not ported to FPC -- the format divergence the owner explicitly
  allows; the LOCATION and the JSON schema do NOT diverge. The reverse
  (Delphi SQLite -> Lazarus) is the genuine block: Lazarus cannot read the SQLite
  db, so Delphi-only sessions do not surface here.

  list = enumerate + sort by last-update DESCENDING (most recent first); load = read
  one file; save = rewrite one file on each settled turn (and before a new-session
  reset), exactly like the Delphi panel calls _SaveCurrentSession before it lists /
  clears.

  Mode: delphiunicode (string = UTF-16), matching the ported Core + Aefos.Compat.Json
  it builds JSON with. The chat controller compiles in mode delphi (string = UTF-8);
  every value crossing that boundary is converted explicitly through LazUTF8 in the
  controller, so this unit only ever sees UnicodeString. All literals here are pure
  ASCII (keys, the folder name, the ISO time format), so the file needs no BOM.

  Robustness: a malformed / locked / partial file never raises out of here -- a bad
  read is skipped (List) or reported as "not found" (TryLoad), a bad id is rejected
  before it can escape the sessions folder. The store is deliberately forgiving so a
  hand-edited or half-written file can never break the chat. }

{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}
{$H+}

interface

uses
  SysUtils,
  DateUtils,    // DateToISO8601 / ISO8601ToDate (the Delphi store's wire format)
  Classes,
  Aefos.Compat.IO,
  Aefos.Compat.Json;

type
  // One recorded turn line. Role is 'user' | 'assistant' -- the exact pair the
  // shell's dsReplay consumes ({role,text}); any other role is treated as
  // assistant on read.
  TAefosSessionMessage = record
    Role: UnicodeString;
    Text: UnicodeString;
    class function New(const ARole, AText: UnicodeString): TAefosSessionMessage; static;
  end;

  // A persisted session. Messages is empty in the LIGHT list (List) and populated
  // by TryLoad. Created/Updated are local times; Count is the user-message count
  // (the list subtitle), mirroring the Delphi TSessionEntry.Count.
  TAefosSessionEntry = record
    Id: UnicodeString;
    Title: UnicodeString;
    Created: TDateTime;
    Updated: TDateTime;
    Count: Integer;
    Messages: TArray<TAefosSessionMessage>;
  end;

  // Persistence contract (the Delphi ISessionStore shape, JSON-backed here).
  IAefosLazSessionStore = interface
    ['{7E4C2A91-5F38-4D6B-9C02-1A8E7B3F0D64}']
    procedure Save(const AEntry: TAefosSessionEntry);
    // Light list (no Messages), ordered by Updated DESCENDING.
    function List: TArray<TAefosSessionEntry>;
    // Full load (with Messages) to replay/resume a session.
    function TryLoad(const AId: UnicodeString; out AEntry: TAefosSessionEntry): Boolean;
    procedure Delete(const AId: UnicodeString);
  end;

  TAefosLazJsonSessionStore = class(TInterfacedObject, IAefosLazSessionStore)
  private
    // The shared Aefos data root (%APPDATA%\Aefos); the sessions live under
    // <FRoot>\lazarus-sessions. A test points this at a temp dir so the user's
    // real data is never touched.
    FRoot: UnicodeString;
    function _Dir: UnicodeString;
    function _PathFor(const AId: UnicodeString): UnicodeString;
    function _ReadEntry(const APath: UnicodeString; const AWithMessages: Boolean;
      out AEntry: TAefosSessionEntry): Boolean;
  public
    constructor Create(const ARoot: UnicodeString);
    procedure Save(const AEntry: TAefosSessionEntry);
    function List: TArray<TAefosSessionEntry>;
    function TryLoad(const AId: UnicodeString; out AEntry: TAefosSessionEntry): Boolean;
    procedure Delete(const AId: UnicodeString);
  end;

  // JSON serializers for the render protocol. Static -- they own no state; they
  // turn entries/messages into the exact JSON the shell's dsReplay /
  // dsShowSessions expect. Kept here (with Compat.Json) so the controller never
  // builds JSON across the mode boundary.
  TAefosSessionJson = class
  public
    // [{"role":..,"text":..},..] -- the array the shell's window.dsReplay consumes.
    class function BuildMessagesJson(
      const AMessages: TArray<TAefosSessionMessage>): UnicodeString; static;
    // Inverse of BuildMessagesJson: parse a [{"role","text"},..] array string back
    // into messages (used to hydrate a session loaded from the messages_json
    // column). A malformed/empty string yields an empty array (never raises).
    class function ParseMessagesJson(
      const AJson: UnicodeString): TArray<TAefosSessionMessage>; static;
    // [{id,title,cli,when,count,current}] -- the array window.dsShowSessions
    // consumes. cli is intentionally empty (vendor-neutral UI rule: never name a
    // CLI to the user); the shell renders "" cleanly. current flags the row whose
    // id equals ACurrentId. when is a short local timestamp for the subtitle.
    class function BuildSessionsListJson(
      const AEntries: TArray<TAefosSessionEntry>;
      const ACurrentId: UnicodeString): UnicodeString; static;
    // True when AId is a safe session id (a bare UUID: lowercase hex + hyphens),
    // so it can never escape the sessions folder. Rejects '', path separators and
    // '..'. Public so the controller can guard a shell-supplied id too.
    class function IsValidId(const AId: UnicodeString): Boolean; static;
  end;

// A bare lowercase UUID (no braces), the id shape the chat uses everywhere.
function NewSessionId: UnicodeString;

implementation

const
  // The SHARED sessions folder -- the SAME name the Delphi side uses (SessionsDir
  // = %APPDATA%\Aefos\sessions), so the Delphi SQLite provider imports what
  // Lazarus writes. NOT a gratuitous 'lazarus-*' path (one-brain rule).
  CSessionsFolder = 'sessions';

{ TAefosSessionMessage }

class function TAefosSessionMessage.New(const ARole,
  AText: UnicodeString): TAefosSessionMessage;
begin
  Result.Role := ARole;
  Result.Text := AText;
end;

// --- local helpers ---------------------------------------------------------

// Local-time ISO 8601, byte-identical to the Delphi store's _IsoOf
// (DateToISO8601(dt, False)) so the two brains agree on the `updated`/`created`
// wire format.
function _IsoOf(const ADateTime: TDateTime): UnicodeString;
begin
  // ISO-8601 stamps are pure ASCII; the explicit cast makes the RTL AnsiString
  // round-trip intentional (and silences the implicit-conversion warning).
  Result := UnicodeString(DateToISO8601(ADateTime, False));
end;

// Parses the ISO stamp back to a TDateTime, mirroring the Delphi store's _DtOf
// (ISO8601ToDate). Any malformed/empty input yields 0 (never raises) so a
// hand-edited or foreign file cannot break List's sort.
function _IsoToDateTime(const AText: UnicodeString): TDateTime;
begin
  if Trim(AText) = '' then
    Exit(0);
  try
    // ASCII stamp -> the AnsiString RTL API; explicit cast, no data loss.
    Result := ISO8601ToDate(AnsiString(AText), False);
  except
    Result := 0;
  end;
end;

function NewSessionId: UnicodeString;
var
  LGuid: TGUID;
  LText: UnicodeString;
begin
  // GUIDToString wraps the UUID in braces ({8-4-4-4-12}); strip them for the bare
  // lowercase form the chat uses (same as the controller's --session-id shape).
  CreateGUID(LGuid);
  LText := LowerCase(GUIDToString(LGuid));
  Result := Copy(LText, 2, Length(LText) - 2);
end;

{ TAefosLazJsonSessionStore }

constructor TAefosLazJsonSessionStore.Create(const ARoot: UnicodeString);
begin
  inherited Create;
  FRoot := ARoot;
end;

function TAefosLazJsonSessionStore._Dir: UnicodeString;
begin
  // TPath.Combine (Compat.IO) is UnicodeString end to end, so a %APPDATA% path
  // with a non-ASCII user name never round-trips through the ANSI codepage.
  Result := TPath.Combine(FRoot, CSessionsFolder);
end;

function TAefosLazJsonSessionStore._PathFor(const AId: UnicodeString): UnicodeString;
begin
  Result := TPath.Combine(_Dir, AId + '.json');
end;

procedure TAefosLazJsonSessionStore.Save(const AEntry: TAefosSessionEntry);
var
  LObj: TJSONObject;
  LArr: TJSONArray;
  LMsg: TJSONObject;
  LFor: Integer;
  LDir: UnicodeString;
begin
  // A missing/invalid id has nowhere to live -- there is nothing meaningful to
  // record, so skip (mirrors the Delphi _SaveCurrentSession id guard).
  if not TAefosSessionJson.IsValidId(AEntry.Id) then
    Exit;
  LDir := _Dir;
  if not TDirectory.Exists(LDir) then
    TDirectory.CreateDirectory(LDir);
  LObj := TJSONObject.Create;
  try
    LObj.AddPair('id', AEntry.Id);
    LObj.AddPair('title', AEntry.Title);
    // cli/project mirror the Delphi legacy JSON keys the SQLite import reads.
    // Both are empty here: cli is vendor-neutral (never named to the user), and
    // this IDE-free store has no active-project resolver -- harmless placeholders
    // that keep the schema identical so the Delphi brain imports cleanly.
    LObj.AddPair('cli', '');
    LObj.AddPair('project', '');
    LObj.AddPair('created', _IsoOf(AEntry.Created));
    LObj.AddPair('updated', _IsoOf(AEntry.Updated));
    LObj.AddPair('count', TJSONNumber.Create(Int64(AEntry.Count)));
    LArr := TJSONArray.Create;
    for LFor := 0 to High(AEntry.Messages) do
    begin
      LMsg := TJSONObject.Create;
      LMsg.AddPair('role', AEntry.Messages[LFor].Role);
      LMsg.AddPair('text', AEntry.Messages[LFor].Text);
      LArr.AddElement(LMsg);
    end;
    LObj.AddPair('messages', LArr);
    // A locked/broken write must never surface into the chat turn that triggered
    // it -- persistence is best-effort.
    try
      TFile.WriteAllText(_PathFor(AEntry.Id), LObj.ToJSON, TEncoding.UTF8);
    except
      // best-effort
    end;
  finally
    LObj.Free;
  end;
end;

function TAefosLazJsonSessionStore._ReadEntry(const APath: UnicodeString;
  const AWithMessages: Boolean; out AEntry: TAefosSessionEntry): Boolean;
var
  LRoot: TJSONValue;
  LObj: TJSONObject;
  LMsgs: TJSONValue;
  LArr: TJSONArray;
  LItem: TJSONValue;
  LMsgObj: TJSONObject;
  LFor: Integer;
  LText: UnicodeString;
begin
  Result := False;
  AEntry := Default(TAefosSessionEntry);
  if not TFile.Exists(APath) then
    Exit;
  try
    LText := TFile.ReadAllText(APath, TEncoding.UTF8);
  except
    Exit;
  end;
  LRoot := TJSONObject.ParseJSONValue(LText);
  if LRoot = nil then
    Exit;
  try
    if not (LRoot is TJSONObject) then
      Exit;
    LObj := TJSONObject(LRoot);
    AEntry.Id := LObj.GetValue<UnicodeString>('id', '');
    if AEntry.Id = '' then
      Exit;
    AEntry.Title := LObj.GetValue<UnicodeString>('title', '');
    AEntry.Created := _IsoToDateTime(LObj.GetValue<UnicodeString>('created', ''));
    AEntry.Updated := _IsoToDateTime(LObj.GetValue<UnicodeString>('updated', ''));
    AEntry.Count := LObj.GetValue<Integer>('count', 0);
    if AWithMessages then
    begin
      LMsgs := LObj.GetValue('messages');
      if LMsgs is TJSONArray then
      begin
        LArr := TJSONArray(LMsgs);
        SetLength(AEntry.Messages, LArr.Count);
        for LFor := 0 to LArr.Count - 1 do
        begin
          LItem := LArr.Items[LFor];
          if LItem is TJSONObject then
          begin
            LMsgObj := TJSONObject(LItem);
            AEntry.Messages[LFor] := TAefosSessionMessage.New(
              LMsgObj.GetValue<UnicodeString>('role', 'assistant'),
              LMsgObj.GetValue<UnicodeString>('text', ''));
          end
          else
            AEntry.Messages[LFor] := TAefosSessionMessage.New('assistant', '');
        end;
      end;
    end;
    Result := True;
  finally
    LRoot.Free;
  end;
end;

function TAefosLazJsonSessionStore.List: TArray<TAefosSessionEntry>;
var
  LFiles: TArray<UnicodeString>;
  LDir: UnicodeString;
  LFor: Integer;
  LCount: Integer;
  LEntry: TAefosSessionEntry;
  LI, LJ: Integer;
  LTmp: TAefosSessionEntry;
begin
  Result := nil;
  LDir := _Dir;
  if not TDirectory.Exists(LDir) then
    Exit;
  LFiles := TDirectory.GetFiles(LDir, '*.json', soTopDirectoryOnly);
  LCount := 0;
  SetLength(Result, Length(LFiles));
  for LFor := 0 to High(LFiles) do
  begin
    // Light read (no messages) -- the list subtitle needs only the metadata.
    if _ReadEntry(LFiles[LFor], False, LEntry) then
    begin
      Result[LCount] := LEntry;
      Inc(LCount);
    end;
  end;
  SetLength(Result, LCount);
  // Insertion sort by Updated DESCENDING (most recent first). The set is small
  // (one file per session), and a manual sort avoids an anonymous-method comparer
  // (FPC: no closures).
  for LI := 1 to High(Result) do
  begin
    LTmp := Result[LI];
    LJ := LI - 1;
    while (LJ >= 0) and (Result[LJ].Updated < LTmp.Updated) do
    begin
      Result[LJ + 1] := Result[LJ];
      Dec(LJ);
    end;
    Result[LJ + 1] := LTmp;
  end;
end;

function TAefosLazJsonSessionStore.TryLoad(const AId: UnicodeString;
  out AEntry: TAefosSessionEntry): Boolean;
begin
  AEntry := Default(TAefosSessionEntry);
  if not TAefosSessionJson.IsValidId(AId) then
    Exit(False);
  Result := _ReadEntry(_PathFor(AId), True, AEntry);
end;

procedure TAefosLazJsonSessionStore.Delete(const AId: UnicodeString);
begin
  if not TAefosSessionJson.IsValidId(AId) then
    Exit;
  try
    if TFile.Exists(_PathFor(AId)) then
      TFile.Delete(_PathFor(AId));
  except
    // best-effort
  end;
end;

{ TAefosSessionJson }

class function TAefosSessionJson.IsValidId(const AId: UnicodeString): Boolean;
var
  LFor: Integer;
  LCh: WideChar;
begin
  // A bare UUID is lowercase hex + hyphens. Rejecting anything else keeps a
  // shell-supplied id from ever escaping the sessions folder (no separators, no
  // '..'). Empty is invalid.
  Result := False;
  if AId = '' then
    Exit;
  for LFor := 1 to Length(AId) do
  begin
    LCh := AId[LFor];
    if not (((LCh >= '0') and (LCh <= '9'))
      or ((LCh >= 'a') and (LCh <= 'f'))
      or (LCh = '-')) then
      Exit;
  end;
  Result := True;
end;

class function TAefosSessionJson.BuildMessagesJson(
  const AMessages: TArray<TAefosSessionMessage>): UnicodeString;
var
  LArr: TJSONArray;
  LObj: TJSONObject;
  LFor: Integer;
begin
  LArr := TJSONArray.Create;
  try
    for LFor := 0 to High(AMessages) do
    begin
      LObj := TJSONObject.Create;
      LObj.AddPair('role', AMessages[LFor].Role);
      LObj.AddPair('text', AMessages[LFor].Text);
      LArr.AddElement(LObj);
    end;
    Result := LArr.ToJSON;
  finally
    LArr.Free;
  end;
end;

class function TAefosSessionJson.BuildSessionsListJson(
  const AEntries: TArray<TAefosSessionEntry>;
  const ACurrentId: UnicodeString): UnicodeString;
var
  LArr: TJSONArray;
  LObj: TJSONObject;
  LFor: Integer;
  LTitle: UnicodeString;
begin
  LArr := TJSONArray.Create;
  try
    for LFor := 0 to High(AEntries) do
    begin
      LObj := TJSONObject.Create;
      LObj.AddPair('id', AEntries[LFor].Id);
      LTitle := AEntries[LFor].Title;
      if Trim(LTitle) = '' then
        LTitle := '(untitled)';
      LObj.AddPair('title', LTitle);
      // Vendor-neutral: no CLI is named to the user (maintainer UI rule).
      LObj.AddPair('cli', '');
      LObj.AddPair('when', FormatDateTime('dd/mm hh:nn', AEntries[LFor].Updated));
      LObj.AddPair('count', TJSONNumber.Create(Int64(AEntries[LFor].Count)));
      LObj.AddPair('current', TJSONBool.Create(
        (AEntries[LFor].Id <> '') and (AEntries[LFor].Id = ACurrentId)));
      LArr.AddElement(LObj);
    end;
    Result := LArr.ToJSON;
  finally
    LArr.Free;
  end;
end;

class function TAefosSessionJson.ParseMessagesJson(
  const AJson: UnicodeString): TArray<TAefosSessionMessage>;
var
  LRoot: TJSONValue;
  LArr: TJSONArray;
  LItem: TJSONValue;
  LObj: TJSONObject;
  LFor: Integer;
  LKept: Integer;
begin
  Result := nil;
  if Trim(AJson) = '' then
    Exit;
  try
    LRoot := TJSONObject.ParseJSONValue(AJson);
  except
    LRoot := nil;
  end;
  if LRoot = nil then
    Exit;
  try
    if not (LRoot is TJSONArray) then
      Exit;
    LArr := TJSONArray(LRoot);
    SetLength(Result, LArr.Count);
    LKept := 0;
    for LFor := 0 to LArr.Count - 1 do
    begin
      LItem := LArr.Items[LFor];
      // SKIP any non-object element rather than inflating the count with an empty
      // placeholder -- a foreign/garbled array must not fabricate blank turns.
      if LItem is TJSONObject then
      begin
        LObj := TJSONObject(LItem);
        Result[LKept] := TAefosSessionMessage.New(
          LObj.GetValue<UnicodeString>('role', 'assistant'),
          LObj.GetValue<UnicodeString>('text', ''));
        Inc(LKept);
      end;
    end;
    SetLength(Result, LKept);
  finally
    LRoot.Free;
  end;
end;

end.
