unit Aefos.Data.SQLite;

(*
  Shared FireDAC / SQLite foundation for the Chat BPL's local persistence.

  Phase 1 (sessions): a single SQLite database file at
    %AppData%\Roaming\Aefos\aefos.db
  opened once and guarded by a critical section. FireDAC's TFDConnection is not
  safe to share across threads, so EVERY access serialises through Lock/Unlock.

  SQLite is STATICALLY linked (FireDAC.Phys.SQLiteWrapper.Stat) — no sqlite3.dll
  is shipped or required at runtime.

  WAL journaling keeps readers from blocking the single writer; a small key/value
  `meta` table backs migration flags (e.g. one-time legacy-import guards).

  PHASE-2 NOTE: this foundation has been extracted into the shared `Aefos.Data`
  package (Aefos.Data.dpk) so MCP.Core's rtl-only `requires` stays intact
  (Tests.MCPCorePackage). Still pending: when the audit log moves to SQLite,
  inject the SQLite IMCPAuditLog via the composition root rather than linking it
  into Core.
*)

interface

uses
  FireDAC.Comp.Client;

type
  // A process-wide SQLite handle. Callers MUST wrap any use of Connection in a
  // Lock/Unlock pair; the meta helpers self-lock.
  ISQLiteDatabase = interface
    ['{6B1D9F2A-4C73-4E18-9A52-7F3C8D0E1B64}']
    function Connection: TFDConnection;
    procedure Lock;
    procedure Unlock;
    // Migration-flag helpers over the `meta` k/v table. Self-locking.
    function MetaGet(const AKey, ADefault: string): string;
    procedure MetaSet(const AKey, AValue: string);
  end;

// Lazy, process-wide singleton on the default db path. Thread-safe.
function SQLiteDatabase: ISQLiteDatabase;
// Default db file: %AppData%\Roaming\Aefos\aefos.db.
function DefaultSQLiteDatabasePath: string;
// Test seam: a fresh database object bound to an explicit file (e.g. a temp path).
function OpenSQLiteDatabase(const APath: string): ISQLiteDatabase;

implementation

uses
  System.SysUtils,
  System.SyncObjs,
  System.IOUtils,
  System.Variants,
  FireDAC.Stan.Intf,
  FireDAC.Stan.Def,
  FireDAC.Stan.Async,
  FireDAC.DApt,
  FireDAC.Phys,
  FireDAC.Phys.SQLite,
  FireDAC.Phys.SQLiteDef
  // Static SQLite: pulling this unit in is what links the engine into the BPL,
  // so no sqlite3.dll has to travel beside it.
  //
  // It is not in every FireDAC. MEASURED, not assumed: absent from 10 Seattle
  // (lib\win32\release carries FireDAC.Phys.SQLiteWrapper.dcu with no .Stat
  // sibling), present in Delphi 11. The exact release that added it is NOT
  // established - Embarcadero documents the unit without dating it - so this
  // guard says "anything above Seattle", the simplest reading consistent with
  // both measurements.
  //
  // If a 10.1/10.2/10.3 build ever fails on this line, that is this guard being
  // wrong rather than the tree: raise the number to the first version that has
  // the unit. Where it is absent FireDAC falls back to loading sqlite3.dll at
  // run time, so the breakage moves from compile time to first database open -
  // which is exactly why this note is here and not in a commit message.
  {$IF CompilerVersion > 30}   // > 10 Seattle
  , FireDAC.Phys.SQLiteWrapper.Stat
  {$IFEND}
  ;

type
  TSQLiteDatabase = class(TInterfacedObject, ISQLiteDatabase)
  private
    FLock: TCriticalSection;
    FConn: TFDConnection;
    procedure _Bootstrap;
  public
    constructor Create(const APath: string);
    destructor Destroy; override;
    function Connection: TFDConnection;
    procedure Lock;
    procedure Unlock;
    function MetaGet(const AKey, ADefault: string): string;
    procedure MetaSet(const AKey, AValue: string);
  end;

var
  GSingleton: ISQLiteDatabase;
  GSingletonLock: TCriticalSection;

function DefaultSQLiteDatabasePath: string;
begin
  // %AppData% (TPath.GetHomePath on Windows) \ Aefos \ aefos.db —
  // next to the legacy sessions\ and logs\ folders.
  Result := TPath.Combine(TPath.Combine(TPath.GetHomePath, 'Aefos'),
    'aefos.db');
end;

{ TSQLiteDatabase }

constructor TSQLiteDatabase.Create(const APath: string);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  TDirectory.CreateDirectory(TPath.GetDirectoryName(APath));
  FConn := TFDConnection.Create(nil);
  FConn.LoginPrompt := False;
  FConn.Params.DriverID := 'SQLite';
  FConn.Params.Database := APath;
  FConn.Connected := True;
  _Bootstrap;
end;

destructor TSQLiteDatabase.Destroy;
begin
  if Assigned(FConn) then
  begin
    try
      FConn.Connected := False;
    except
      // closing a half-open connection on teardown must never raise
    end;
    FConn.Free;
  end;
  FLock.Free;
  inherited;
end;

procedure TSQLiteDatabase._Bootstrap;
begin
  // Pragmas via ExecSQL (robust across FireDAC versions); then the meta table.
  FConn.ExecSQL('PRAGMA journal_mode=WAL');
  FConn.ExecSQL('PRAGMA synchronous=NORMAL');
  // busy_timeout: wait out a lock instead of failing SQLITE_BUSY immediately. This
  // matters now that the Lazarus edition can open the SAME aefos.db concurrently
  // (its static-SQLite store sets the same pragma); under dual-IDE contention the
  // writer retries for up to 5 s rather than erroring. WAL is still single-writer,
  // so simultaneous writers serialise here rather than one failing outright.
  FConn.ExecSQL('PRAGMA busy_timeout=5000');
  FConn.ExecSQL('CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT)');
end;

function TSQLiteDatabase.Connection: TFDConnection;
begin
  Result := FConn;
end;

procedure TSQLiteDatabase.Lock;
begin
  FLock.Enter;
end;

procedure TSQLiteDatabase.Unlock;
begin
  FLock.Leave;
end;

function TSQLiteDatabase.MetaGet(const AKey, ADefault: string): string;
var
  LVal: Variant;
begin
  Lock;
  try
    LVal := FConn.ExecSQLScalar('SELECT v FROM meta WHERE k = :k', [AKey]);
    if VarIsNull(LVal) or VarIsEmpty(LVal) then
      Result := ADefault
    else
      Result := VarToStr(LVal);
  finally
    Unlock;
  end;
end;

procedure TSQLiteDatabase.MetaSet(const AKey, AValue: string);
begin
  Lock;
  try
    FConn.ExecSQL(
      'INSERT INTO meta (k, v) VALUES (:k, :v) ' +
      'ON CONFLICT(k) DO UPDATE SET v = excluded.v', [AKey, AValue]);
  finally
    Unlock;
  end;
end;

{ unit-level accessors }

function OpenSQLiteDatabase(const APath: string): ISQLiteDatabase;
begin
  Result := TSQLiteDatabase.Create(APath);
end;

function SQLiteDatabase: ISQLiteDatabase;
begin
  GSingletonLock.Enter;
  try
    if GSingleton = nil then
      GSingleton := TSQLiteDatabase.Create(DefaultSQLiteDatabasePath);
    Result := GSingleton;
  finally
    GSingletonLock.Leave;
  end;
end;

initialization
  GSingletonLock := TCriticalSection.Create;

finalization
  // Drop the singleton before FireDAC's own finalization so the connection
  // closes cleanly while the BPL is still loaded (BPL-unload hygiene).
  GSingleton := nil;
  GSingletonLock.Free;

end.
