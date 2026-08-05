unit Aefos.OTA.Chat.Core.SessionStore.SQLite;

(*
  SQLite-backed ISessionStore provider (phase 1 of the JSON/text -> SQLite move).

  Each session is one row in the shared database
    %AppData%\Roaming\Aefos\aefos.db   (table `sessions`)
  over the FireDAC foundation in Aefos.Data.SQLite (static-linked
  SQLite, WAL, single connection serialised by a critical section).

  The legacy one-JSON-file-per-session files under ...\Aefos\sessions\ are
  imported ONCE on first use and then left in place (non-destructive) — the move
  is reversible and no history is lost.

  This unit self-registers as the default provider in `initialization`, so simply
  linking it into the package wires it up. Tests can override via
  SetSessionStoreProvider.
*)

interface

uses
  Aefos.OTA.Chat.Core.SessionStore;

// Factory for the SQLite provider (also used by the self-registration below).
function CreateSQLiteSessionStore: ISessionStore;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.IOUtils,
  System.JSON,
  System.DateUtils,
  System.Generics.Collections,
  FireDAC.Comp.Client,
  Aefos.Data.SQLite;

const
  CImportFlag = 'sessions_imported_v1';

type
  TSQLiteSessionStore = class(TInterfacedObject, ISessionStore)
  private
    FReady: Boolean;
    procedure _EnsureReady;
    procedure _CreateSchema(const ADb: ISQLiteDatabase);
    procedure _MigrateSchema(const ADb: ISQLiteDatabase);
    procedure _ImportLegacy(const ADb: ISQLiteDatabase);
    procedure _Write(const ADb: ISQLiteDatabase; const AEntry: TSessionEntry;
      const AInsertOrIgnore: Boolean);
  public
    procedure SaveSession(const AEntry: TSessionEntry);
    function LoadSessions: TArray<TSessionEntry>;
    function TryLoadSession(const AId: string;
      out AEntry: TSessionEntry): Boolean;
    procedure DeleteSession(const AId: string);
  end;

// ── Helpers ──────────────────────────────────────────────────────────────────

// Fixed-width local-time ISO so the TEXT `updated` column sorts chronologically.
function _IsoOf(const ADt: TDateTime): string;
begin
  Result := DateToISO8601(ADt, False);
end;

function _DtOf(const AIso: string): TDateTime;
begin
  if AIso = '' then
    Exit(0);
  try
    Result := ISO8601ToDate(AIso, False);
  except
    Result := 0;
  end;
end;

// Parses one legacy <id>.json into a full entry (incl. messages). Corrupt/locked
// files return False and are skipped — never raised.
function _ReadJsonFile(const APath: string; out AEntry: TSessionEntry): Boolean;
var
  LText: string;
  LValue: TJSONValue;
  LObj: TJSONObject;
  LUpdated: string;
  LMessages: TJSONValue;
begin
  AEntry := Default(TSessionEntry);
  try
    if not TFile.Exists(APath) then
      Exit(False);
    LText := TFile.ReadAllText(APath, TEncoding.UTF8);
    LValue := TJSONObject.ParseJSONValue(LText);
    if LValue = nil then
      Exit(False);
    try
      if not (LValue is TJSONObject) then
        Exit(False);
      LObj := TJSONObject(LValue);
      LObj.TryGetValue<string>('id', AEntry.Id);
      LObj.TryGetValue<string>('title', AEntry.Title);
      LObj.TryGetValue<string>('cli', AEntry.Cli);
      LObj.TryGetValue<string>('project', AEntry.Project);
      LUpdated := '';
      LObj.TryGetValue<string>('updated', LUpdated);
      AEntry.Updated := _DtOf(LUpdated);
      LObj.TryGetValue<Integer>('count', AEntry.Count);
      AEntry.MessagesJson := '';
      if LObj.TryGetValue<TJSONValue>('messages', LMessages)
        and (LMessages <> nil) then
        AEntry.MessagesJson := LMessages.ToJSON;
      Result := True;
    finally
      LValue.Free;
    end;
  except
    Result := False;
  end;
end;

{ TSQLiteSessionStore }

procedure TSQLiteSessionStore._CreateSchema(const ADb: ISQLiteDatabase);
begin
  ADb.Connection.ExecSQL(
    'CREATE TABLE IF NOT EXISTS sessions (' +
    '  id            TEXT PRIMARY KEY,' +
    '  title         TEXT,' +
    '  cli           TEXT,' +
    '  project       TEXT,' +
    '  updated       TEXT,' +
    '  msg_count     INTEGER,' +
    '  messages_json TEXT' +
    ')');
  ADb.Connection.ExecSQL(
    'CREATE INDEX IF NOT EXISTS ix_sessions_updated ON sessions (updated)');
end;

// Versioned, one-shot data migrations. Guarded by PRAGMA user_version so each
// one runs once per database and never on a db created after it.
procedure TSQLiteSessionStore._MigrateSchema(const ADb: ISQLiteDatabase);
var
  LQ: TFDQuery;
  LVersion: Integer;
begin
  LVersion := 0;
  LQ := TFDQuery.Create(nil);
  try
    LQ.Connection := ADb.Connection;
    LQ.Open('PRAGMA user_version');
    if not LQ.Eof then
      LVersion := LQ.Fields[0].AsInteger;
  finally
    LQ.Free;
  end;

  // v1 -- retire the constant 'claude'.
  //
  // Until now the panel wrote a hard-coded 'claude' into every session it saved,
  // whatever executor had actually run it. So the column is not "mostly right
  // with some wrong rows": it is a CONSTANT, and carries no information about
  // any row, including the ones that really were Claude. Clearing it is not data
  // loss -- there was never any data. What it buys is that the list stops
  // asserting something it cannot know; a row re-labels itself truthfully the
  // next time its conversation is saved.
  if LVersion < 1 then
  begin
    ADb.Connection.ExecSQL('UPDATE sessions SET cli = '''' ');
    ADb.Connection.ExecSQL('PRAGMA user_version = 1');
  end;
end;

// Inserts/updates one row. AInsertOrIgnore = legacy-import mode: never clobber a
// row that already exists (the live session is authoritative).
procedure TSQLiteSessionStore._Write(const ADb: ISQLiteDatabase;
  const AEntry: TSessionEntry; const AInsertOrIgnore: Boolean);
var
  LSql, LMsgs: string;
begin
  LMsgs := AEntry.MessagesJson;
  if Trim(LMsgs) = '' then
    LMsgs := '[]';
  if AInsertOrIgnore then
    LSql :=
      'INSERT OR IGNORE INTO sessions ' +
      '(id, title, cli, project, updated, msg_count, messages_json) ' +
      'VALUES (:id, :title, :cli, :project, :updated, :count, :msgs)'
  else
    LSql :=
      'INSERT INTO sessions ' +
      '(id, title, cli, project, updated, msg_count, messages_json) ' +
      'VALUES (:id, :title, :cli, :project, :updated, :count, :msgs) ' +
      'ON CONFLICT(id) DO UPDATE SET ' +
      'title = excluded.title, cli = excluded.cli, ' +
      'project = excluded.project, updated = excluded.updated, ' +
      'msg_count = excluded.msg_count, messages_json = excluded.messages_json';
  ADb.Connection.ExecSQL(LSql,
    [AEntry.Id, AEntry.Title, AEntry.Cli, AEntry.Project,
     _IsoOf(AEntry.Updated), AEntry.Count, LMsgs]);
end;

// One-time, non-destructive import of legacy sessions\*.json. Runs under the db
// lock (held by the caller). INSERT OR IGNORE so re-running can never clobber.
procedure TSQLiteSessionStore._ImportLegacy(const ADb: ISQLiteDatabase);
var
  LDir, LPath: string;
  LFiles: TArray<string>;
  LEntry: TSessionEntry;
begin
  if ADb.MetaGet(CImportFlag, '') = '1' then
    Exit;
  LDir := SessionsDir;
  if TDirectory.Exists(LDir) then
  begin
    try
      LFiles := TDirectory.GetFiles(LDir, '*.json');
    except
      LFiles := nil;
    end;
    for LPath in LFiles do
      if _ReadJsonFile(LPath, LEntry) and (LEntry.Id <> '') then
        try
          _Write(ADb, LEntry, True);
        except
          // a single bad row never aborts the import
        end;
  end;
  ADb.MetaSet(CImportFlag, '1');
end;

// Ensures schema + one-time legacy import + data migrations exactly once, under
// the db lock.
procedure TSQLiteSessionStore._EnsureReady;
var
  LDb: ISQLiteDatabase;
begin
  if FReady then
    Exit;
  LDb := SQLiteDatabase;
  LDb.Lock;
  try
    if not FReady then
    begin
      _CreateSchema(LDb);
      // AFTER the import on purpose: the legacy .json rows carry the same
      // constant 'claude', so they must pass through the migration too rather
      // than land behind it.
      _ImportLegacy(LDb);
      _MigrateSchema(LDb);
      FReady := True;
    end;
  finally
    LDb.Unlock;
  end;
end;

procedure TSQLiteSessionStore.SaveSession(const AEntry: TSessionEntry);
var
  LDb: ISQLiteDatabase;
begin
  if AEntry.Id = '' then
    Exit;
  try
    _EnsureReady;
    LDb := SQLiteDatabase;
    LDb.Lock;
    try
      _Write(LDb, AEntry, False);
    finally
      LDb.Unlock;
    end;
  except
    on E: Exception do
      // A DB error must never break the caller (matches the old file behaviour).
      OutputDebugString(PChar('Aefos.SessionStore.Save: ' + E.Message));
  end;
end;

function TSQLiteSessionStore.LoadSessions: TArray<TSessionEntry>;
var
  LDb: ISQLiteDatabase;
  LQ: TFDQuery;
  LList: TList<TSessionEntry>;
  LEntry: TSessionEntry;
begin
  LList := TList<TSessionEntry>.Create;
  try
    try
      _EnsureReady;
      LDb := SQLiteDatabase;
      LDb.Lock;
      try
        LQ := TFDQuery.Create(nil);
        try
          LQ.Connection := LDb.Connection;
          LQ.Open('SELECT id, title, cli, project, updated, msg_count ' +
            'FROM sessions ORDER BY updated DESC');
          while not LQ.Eof do
          begin
            LEntry := Default(TSessionEntry);
            LEntry.Id := LQ.FieldByName('id').AsString;
            LEntry.Title := LQ.FieldByName('title').AsString;
            LEntry.Cli := LQ.FieldByName('cli').AsString;
            LEntry.Project := LQ.FieldByName('project').AsString;
            LEntry.Updated := _DtOf(LQ.FieldByName('updated').AsString);
            LEntry.Count := LQ.FieldByName('msg_count').AsInteger;
            LEntry.MessagesJson := '';
            LList.Add(LEntry);
            LQ.Next;
          end;
        finally
          LQ.Free;
        end;
      finally
        LDb.Unlock;
      end;
    except
      // A store failure must never break the panel: return what we have.
    end;
    Result := LList.ToArray;
  finally
    LList.Free;
  end;
end;

function TSQLiteSessionStore.TryLoadSession(const AId: string;
  out AEntry: TSessionEntry): Boolean;
var
  LDb: ISQLiteDatabase;
  LQ: TFDQuery;
begin
  AEntry := Default(TSessionEntry);
  Result := False;
  if AId = '' then
    Exit(False);
  try
    _EnsureReady;
    LDb := SQLiteDatabase;
    LDb.Lock;
    try
      LQ := TFDQuery.Create(nil);
      try
        LQ.Connection := LDb.Connection;
        LQ.SQL.Text :=
          'SELECT id, title, cli, project, updated, msg_count, messages_json ' +
          'FROM sessions WHERE id = :id';
        LQ.ParamByName('id').AsString := AId;
        LQ.Open;
        if not LQ.Eof then
        begin
          AEntry.Id := LQ.FieldByName('id').AsString;
          AEntry.Title := LQ.FieldByName('title').AsString;
          AEntry.Cli := LQ.FieldByName('cli').AsString;
          AEntry.Project := LQ.FieldByName('project').AsString;
          AEntry.Updated := _DtOf(LQ.FieldByName('updated').AsString);
          AEntry.Count := LQ.FieldByName('msg_count').AsInteger;
          AEntry.MessagesJson := LQ.FieldByName('messages_json').AsString;
          Result := True;
        end;
      finally
        LQ.Free;
      end;
    finally
      LDb.Unlock;
    end;
  except
    Result := False;
  end;
end;

procedure TSQLiteSessionStore.DeleteSession(const AId: string);
var
  LDb: ISQLiteDatabase;
begin
  if AId = '' then
    Exit;
  try
    _EnsureReady;
    LDb := SQLiteDatabase;
    LDb.Lock;
    try
      LDb.Connection.ExecSQL('DELETE FROM sessions WHERE id = :id', [AId]);
    finally
      LDb.Unlock;
    end;
  except
    // Best-effort delete; never raise.
  end;
end;

function CreateSQLiteSessionStore: ISessionStore;
begin
  Result := TSQLiteSessionStore.Create;
end;

initialization
  // Self-register as the default provider: linking this unit wires SQLite in.
  SetSessionStoreProvider(CreateSQLiteSessionStore);

finalization
  SetSessionStoreProvider(nil);

end.
