unit Aefos.Lazarus.SessionStore.SQLite;

{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}
{$H+}

{ The DEFAULT Lazarus chat session store: one row per session in the SHARED
  %APPDATA%\Aefos\aefos.db -- the SAME SQLite file (and, VERBATIM, the SAME
  `sessions` schema) the Delphi FireDAC edition uses
  (source/chat/Core/Aefos.OTA.Chat.Core.SessionStore.SQLite.pas).

  This is the FPC twin of the Delphi SessionStore.SQLite provider, and it makes
  session history a genuine ONE BRAIN in BOTH directions: a session written in
  Lazarus is read by the Delphi brain and vice-versa (the old JSON store was
  Lazarus->Delphi only, via a one-time import). On first use it migrates the
  legacy <root>\sessions\*.json files into the table ONCE, guarded by the SAME
  `meta` flag (`sessions_imported_v1`) the Delphi side uses, so the two editions
  never double-import and never clobber (INSERT OR IGNORE).

  It implements the SAME IAefosLazSessionStore contract (from the sibling
  Aefos.Lazarus.SessionStore unit), so the ChatController only changes which store
  its _Store factory builds. Records stay UnicodeString (delphiunicode); every
  value is converted to/from UTF-8 (the SQLite C ABI's encoding) at the wrapper
  seam. This unit -- and ONLY this unit -- pulls in the statically-linked SQLite
  (Aefos.Lazarus.SQLite, which carries the LINK directive), keeping the contract
  unit and the JSON store link-free (mirroring the Delphi split). }

interface

uses
  {$IFDEF FPC}SysUtils{$ELSE}System.SysUtils{$ENDIF},
  Aefos.Lazarus.SessionStore;

type
  TAefosLazSqliteSessionStore = class(TInterfacedObject, IAefosLazSessionStore)
  private
    FRoot: UnicodeString;
    FReady: Boolean;
    function _DbPath: UnicodeString;
    // Returns the PROCESS-WIDE shared db (never owned/freed here) as an opaque
    // TObject; the implementation casts it to TAefosLazSQLiteDb.
    function _Open: TObject;
    // Assumes the db lock is held by the caller (a public method).
    procedure _EnsureReadyLocked;
    procedure _CreateSchema;
    procedure _ImportLegacy;
    procedure _WriteRow(const AEntry: TAefosSessionEntry;
      const AInsertOrIgnore: Boolean);
  public
    constructor Create(const ARoot: UnicodeString);
    procedure Save(const AEntry: TAefosSessionEntry);
    function List: TArray<TAefosSessionEntry>;
    function TryLoad(const AId: UnicodeString; out AEntry: TAefosSessionEntry): Boolean;
    procedure Delete(const AId: UnicodeString);
  end;

implementation

uses
  {$IFDEF FPC}DateUtils{$ELSE}System.DateUtils{$ENDIF},
  Aefos.Compat.IO,      // TPath / TDirectory (the FPC-safe UnicodeString twins)
  Aefos.Lazarus.SQLite;

const
  // Lazarus's OWN one-time-import flag -- deliberately DISTINCT from the Delphi
  // provider's `sessions_imported_v1`. The two editions read the SAME shared
  // sessions\*.json legacy folder, so each must scan it once on ITS first run:
  // a shared flag would let whichever edition ran first suppress the other's
  // import and orphan its legacy sessions. `_WriteRow(..., True)` uses
  // INSERT OR IGNORE, so both scans converge with zero duplication/clobber even
  // if both run.
  CImportFlagKey = 'sessions_imported_v1_lazarus';
  // The db file name next to the legacy sessions\ folder and logs\ -- byte-for-byte
  // the Delphi DefaultSQLiteDatabasePath tail (%APPDATA%\Aefos\aefos.db).
  CDbFileName = 'aefos.db';

// --- local helpers ---------------------------------------------------------

// UTF-8 seam (delphiunicode <-> the SQLite C ABI). The record fields are
// UnicodeString (UTF-16); the SQLite wrapper speaks UTF-8 RawByteString.
function _ToU8(const AValue: UnicodeString): RawByteString;
begin
  Result := UTF8Encode(AValue);
end;

function _FromU8(const AValue: RawByteString): UnicodeString;
begin
  Result := UTF8Decode(AValue);
end;

// Local-time ISO 8601, byte-identical to the Delphi store's _IsoOf
// (DateToISO8601(dt, False)) so the two brains agree on the `updated` wire format.
function _IsoOf(const ADateTime: TDateTime): UnicodeString;
begin
  Result := UnicodeString(DateToISO8601(ADateTime, False));
end;

function _IsoToDateTime(const AText: UnicodeString): TDateTime;
begin
  if Trim(AText) = '' then
    Exit(0);
  try
    Result := ISO8601ToDate(AnsiString(AText), False);
  except
    Result := 0;
  end;
end;

{ TAefosLazSqliteSessionStore }

constructor TAefosLazSqliteSessionStore.Create(const ARoot: UnicodeString);
begin
  inherited Create;
  FRoot := ARoot;
  FReady := False;
  // No Destroy override: the store does NOT own the db. The connection is the
  // process-wide singleton (TAefosLazSQLiteDb.Shared), opened once and released in
  // Aefos.Lazarus.SQLite's finalization -- so creating a store per _Store call
  // never reopens/checkpoints (mirrors the Delphi long-lived SQLiteDatabase()).
end;

function TAefosLazSqliteSessionStore._DbPath: UnicodeString;
begin
  Result := TPath.Combine(FRoot, CDbFileName);
end;

function TAefosLazSqliteSessionStore._Open: TObject;
begin
  // Ensure the root exists (a test points FRoot at a fresh temp dir), then borrow
  // the process-wide shared connection for this path.
  if not TDirectory.Exists(FRoot) then
    TDirectory.CreateDirectory(FRoot);
  Result := TAefosLazSQLiteDb.Shared(_ToU8(_DbPath));
end;

procedure TAefosLazSqliteSessionStore._CreateSchema;
var
  LDb: TAefosLazSQLiteDb;
begin
  // VERBATIM from the Delphi _CreateSchema so the two editions share one table.
  LDb := TAefosLazSQLiteDb(_Open);
  LDb.Exec(
    'CREATE TABLE IF NOT EXISTS sessions (' +
    '  id            TEXT PRIMARY KEY,' +
    '  title         TEXT,' +
    '  cli           TEXT,' +
    '  project       TEXT,' +
    '  updated       TEXT,' +
    '  msg_count     INTEGER,' +
    '  messages_json TEXT' +
    ')');
  LDb.Exec('CREATE INDEX IF NOT EXISTS ix_sessions_updated ON sessions (updated)');
end;

procedure TAefosLazSqliteSessionStore._WriteRow(
  const AEntry: TAefosSessionEntry; const AInsertOrIgnore: Boolean);
var
  LDb: TAefosLazSQLiteDb;
  LStmt: TAefosLazSQLiteStmt;
  LSql: RawByteString;
  LMsgs: UnicodeString;
begin
  if not TAefosSessionJson.IsValidId(AEntry.Id) then
    Exit;
  LMsgs := TAefosSessionJson.BuildMessagesJson(AEntry.Messages);
  if Trim(LMsgs) = '' then
    LMsgs := '[]';
  if AInsertOrIgnore then
    LSql :=
      'INSERT OR IGNORE INTO sessions ' +
      '(id, title, cli, project, updated, msg_count, messages_json) ' +
      'VALUES (?, ?, ?, ?, ?, ?, ?)'
  else
    // On UPDATE, do NOT touch cli/project: the row may have been created by the
    // Delphi brain (which DOES set them), and Lazarus never has real values for
    // them -- resuming a Delphi session + one Lazarus turn must not wipe that
    // metadata. On a fresh INSERT they land as '' (bound below), matching the
    // JSON store; the schema/columns still match the Delphi side.
    LSql :=
      'INSERT INTO sessions ' +
      '(id, title, cli, project, updated, msg_count, messages_json) ' +
      'VALUES (?, ?, ?, ?, ?, ?, ?) ' +
      'ON CONFLICT(id) DO UPDATE SET ' +
      'title = excluded.title, updated = excluded.updated, ' +
      'msg_count = excluded.msg_count, messages_json = excluded.messages_json';
  LDb := TAefosLazSQLiteDb(_Open);
  LStmt := LDb.Prepare(LSql);
  try
    LStmt.BindText(1, _ToU8(AEntry.Id));
    LStmt.BindText(2, _ToU8(AEntry.Title));
    // cli/project stay empty here (vendor-neutral + no IDE project resolver),
    // exactly like the JSON store -- the schema/columns still match the Delphi side.
    LStmt.BindText(3, '');
    LStmt.BindText(4, '');
    LStmt.BindText(5, _ToU8(_IsoOf(AEntry.Updated)));
    LStmt.BindInt(6, AEntry.Count);
    LStmt.BindText(7, _ToU8(LMsgs));
    LStmt.Step; // runs to completion (no result rows)
  finally
    LStmt.Free;
  end;
end;

procedure TAefosLazSqliteSessionStore._ImportLegacy;
var
  LDb: TAefosLazSQLiteDb;
  LJson: TAefosLazJsonSessionStore;
  LLight: TArray<TAefosSessionEntry>;
  LFull: TAefosSessionEntry;
  LFor: Integer;
begin
  LDb := TAefosLazSQLiteDb(_Open);
  // Already imported (by either edition)? Nothing to do -- the db is authoritative.
  if _FromU8(LDb.MetaGet(CImportFlagKey, '')) = '1' then
    Exit;
  // Read the legacy <root>\sessions\*.json (the same files the Delphi importer
  // reads) via the JSON store, and INSERT OR IGNORE each -- never clobbering a row
  // the db (or the Delphi brain) already owns.
  LJson := TAefosLazJsonSessionStore.Create(FRoot);
  try
    LLight := LJson.List;
    for LFor := 0 to High(LLight) do
    begin
      if LJson.TryLoad(LLight[LFor].Id, LFull) and (LFull.Id <> '') then
        try
          _WriteRow(LFull, True);
        except
          // a single bad row never aborts the import
        end;
    end;
  finally
    LJson.Free;
  end;
  LDb.MetaSet(CImportFlagKey, '1');
end;

procedure TAefosLazSqliteSessionStore._EnsureReadyLocked;
begin
  // Caller holds the db lock. Idempotent schema (CREATE IF NOT EXISTS) + the
  // one-time legacy import (guarded by the Lazarus meta flag). Cheap to re-run.
  if FReady then
    Exit;
  _CreateSchema;
  _ImportLegacy;
  FReady := True;
end;

procedure TAefosLazSqliteSessionStore.Save(const AEntry: TAefosSessionEntry);
var
  LDb: TAefosLazSQLiteDb;
begin
  if not TAefosSessionJson.IsValidId(AEntry.Id) then
    Exit;
  try
    LDb := TAefosLazSQLiteDb(_Open);
    LDb.Lock;
    try
      _EnsureReadyLocked;
      _WriteRow(AEntry, False);
    finally
      LDb.Unlock;
    end;
  except
    // Persistence is best-effort; a store error must never break the chat turn.
  end;
end;

function TAefosLazSqliteSessionStore.List: TArray<TAefosSessionEntry>;
var
  LDb: TAefosLazSQLiteDb;
  LStmt: TAefosLazSQLiteStmt;
  LEntry: TAefosSessionEntry;
  LCount: Integer;
begin
  Result := nil;
  try
    LDb := TAefosLazSQLiteDb(_Open);
    LDb.Lock;
    try
      _EnsureReadyLocked;
      // Light list (no messages_json) ordered by the TEXT `updated` DESC -- the ISO
      // stamp sorts chronologically, matching the Delphi LoadSessions query.
      LStmt := LDb.Prepare(
        'SELECT id, title, updated, msg_count FROM sessions ORDER BY updated DESC');
      try
        LCount := 0;
        while LStmt.Step do
        begin
          LEntry := Default(TAefosSessionEntry);
          LEntry.Id := _FromU8(LStmt.ColTextUtf8(0));
          LEntry.Title := _FromU8(LStmt.ColTextUtf8(1));
          LEntry.Updated := _IsoToDateTime(_FromU8(LStmt.ColTextUtf8(2)));
          // No `created` column in the shared schema; the list only shows Updated,
          // so mirror it (honest: Lazarus does not persist a separate created time).
          LEntry.Created := LEntry.Updated;
          LEntry.Count := LStmt.ColInt(3);
          SetLength(Result, LCount + 1);
          Result[LCount] := LEntry;
          Inc(LCount);
        end;
      finally
        LStmt.Free;
      end;
    finally
      LDb.Unlock;
    end;
  except
    // A store failure must never break the panel: return what we have.
  end;
end;

function TAefosLazSqliteSessionStore.TryLoad(const AId: UnicodeString;
  out AEntry: TAefosSessionEntry): Boolean;
var
  LDb: TAefosLazSQLiteDb;
  LStmt: TAefosLazSQLiteStmt;
begin
  AEntry := Default(TAefosSessionEntry);
  Result := False;
  if not TAefosSessionJson.IsValidId(AId) then
    Exit(False);
  try
    LDb := TAefosLazSQLiteDb(_Open);
    LDb.Lock;
    try
      _EnsureReadyLocked;
      LStmt := LDb.Prepare(
        'SELECT id, title, updated, msg_count, messages_json ' +
        'FROM sessions WHERE id = ?');
      try
        LStmt.BindText(1, _ToU8(AId));
        if LStmt.Step then
        begin
          AEntry.Id := _FromU8(LStmt.ColTextUtf8(0));
          AEntry.Title := _FromU8(LStmt.ColTextUtf8(1));
          AEntry.Updated := _IsoToDateTime(_FromU8(LStmt.ColTextUtf8(2)));
          AEntry.Created := AEntry.Updated;
          AEntry.Count := LStmt.ColInt(3);
          AEntry.Messages :=
            TAefosSessionJson.ParseMessagesJson(_FromU8(LStmt.ColTextUtf8(4)));
          Result := True;
        end;
      finally
        LStmt.Free;
      end;
    finally
      LDb.Unlock;
    end;
  except
    Result := False;
  end;
end;

procedure TAefosLazSqliteSessionStore.Delete(const AId: UnicodeString);
var
  LDb: TAefosLazSQLiteDb;
  LStmt: TAefosLazSQLiteStmt;
begin
  if not TAefosSessionJson.IsValidId(AId) then
    Exit;
  try
    LDb := TAefosLazSQLiteDb(_Open);
    LDb.Lock;
    try
      _EnsureReadyLocked;
      LStmt := LDb.Prepare('DELETE FROM sessions WHERE id = ?');
      try
        LStmt.BindText(1, _ToU8(AId));
        LStmt.Step;
      finally
        LStmt.Free;
      end;
    finally
      LDb.Unlock;
    end;
  except
    // Best-effort delete; never raise.
  end;
end;

end.
