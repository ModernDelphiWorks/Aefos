unit Aefos.Lazarus.SQLite;

{$IFDEF FPC}{$mode delphi}{$H+}{$ENDIF}

{ Minimal DLL-backed SQLite for the Lazarus/FPC edition -- the FPC twin of the
  Delphi FireDAC foundation (source/data/Aefos.Data.SQLite.pas).

  WHY this exists: the Delphi edition operates the shared %APPDATA%\Aefos\aefos.db
  through FireDAC's own bundled SQLite. FPC/Lazarus has no FireDAC, so this unit
  drives SQLite directly.

  WHY A DLL (and NOT a static object -- changed 2026-07-18): this unit used to
  LINK-directive a statically-compiled sqlite3_fpc.o plus the mingw import libs. That
  made the IDE's link depend on the SQLite object + mingwex/ucrt/libgcc/kernel32
  being on the linker's -Fo/-Fl search path. Our installer supplied those on the
  first install, but any LATER, NORMAL IDE rebuild -- e.g. the user opening
  Package > Install/Uninstall Packages to add AnchorDocking, which runs a plain
  `lazbuild --build-ide` with NO custom -Fo/-Fl -- could not find the object/libs
  and FAILED ("Object sqlite3_fpc.o not found / Import library not found"). Our
  plugin thereby made the user's IDE non-rebuildable by normal means. Unacceptable.

  So SQLite is now loaded at RUNTIME from a standard i386 sqlite3.dll shipped
  beside lazarus.exe (exactly like the WebView2Loader.dll the chat already ships).
  There is ZERO link-time C dependency: the IDE links with default options, so
  `lazbuild --build-ide` (AnchorDocking or any package) just works. The DLL is
  built from the same vendored amalgamation (scripts/build-sqlite-fpc.ps1 -Dll),
  so the on-disk file stays byte-standard "SQLite format 3" -- the SAME aefos.db
  FireDAC reads on the Delphi side (one brain preserved).

  This wraps only what the session store needs: open (WAL + busy_timeout), exec,
  a tiny prepared-statement cursor (bind text/int, step, read text/int), a scalar
  meta k/v helper mirroring the Delphi `meta` table, checkpoint-on-close, and a
  critical section (Lock/Unlock) so concurrent callers serialise like the Delphi
  ISQLiteDatabase does. All payload strings cross the boundary as RawByteString
  UTF-8 (the C ABI's encoding); the caller converts to/from UnicodeString. }

interface

uses
  {$IFDEF FPC}SysUtils, SyncObjs, DynLibs{$ELSE}System.SysUtils, System.SyncObjs, Winapi.Windows{$ENDIF};

type
  EAefosLazSQLite = class(Exception);

  // A prepared statement cursor. Owned by the caller; ALWAYS Free it (which
  // finalises the underlying sqlite3_stmt). Step returns True while a row is
  // available; the Col* readers are valid only after a True Step.
  TAefosLazSQLiteStmt = class
  private
    FStmt: Pointer;
    FDbForErr: Pointer;
  public
    constructor Create(AStmt, ADbForErr: Pointer);
    destructor Destroy; override;
    // 1-based parameter index (SQLite convention). Text is UTF-8; a copy is taken
    // (SQLITE_TRANSIENT) so the caller's buffer need not outlive the bind.
    procedure BindText(AIndex: Integer; const AValueUtf8: RawByteString);
    procedure BindInt(AIndex: Integer; AValue: Integer);
    function Step: Boolean;
    // 0-based column index. Text comes back as UTF-8 bytes.
    function ColTextUtf8(AIndex: Integer): RawByteString;
    function ColInt(AIndex: Integer): Integer;
  end;

  // A process-wide-ish SQLite handle over one db file. Mirrors the shape of the
  // Delphi ISQLiteDatabase (Connection/Lock/Unlock/MetaGet/MetaSet) closely
  // enough that the session store reads almost identically on both sides.
  TAefosLazSQLiteDb = class
  private
    class var FOpenCount: Integer;   // total real sqlite opens this process (proof)
  private
    FDb: Pointer;
    FLock: TCriticalSection;
    procedure _Check(ARc: Integer; const AWhat: string);
    procedure _Bootstrap(ABusyTimeoutMs: Integer);
  public
    // Opens (creating if needed) the db at APathUtf8 (a UTF-8 filesystem path),
    // enables WAL + synchronous=NORMAL + busy_timeout, and ensures the `meta`
    // table. Raises EAefosLazSQLite on failure. Prefer Shared() for the process
    // db; this ctor is for INDEPENDENT connections (tests / an extra reader).
    constructor Create(const APathUtf8: RawByteString; ABusyTimeoutMs: Integer = 5000);
    // Checkpoints the WAL (TRUNCATE, so no -wal/-shm residue) and closes. For the
    // Shared() singleton this runs ONLY at process shutdown (finalization).
    destructor Destroy; override;
    procedure Lock;
    procedure Unlock;
    // One-shot statement with no result (DDL / INSERT / DELETE). Raises on error.
    procedure Exec(const ASqlUtf8: RawByteString);
    // Prepares a cursor; caller Frees it. Raises on a malformed statement.
    function Prepare(const ASqlUtf8: RawByteString): TAefosLazSQLiteStmt;
    // Migration-flag helpers over `meta` (mirror Delphi MetaGet/MetaSet). Callers
    // hold no lock; these self-lock (the process lock is re-entrant).
    function MetaGet(const AKeyUtf8, ADefaultUtf8: RawByteString): RawByteString;
    procedure MetaSet(const AKeyUtf8, AValueUtf8: RawByteString);
    // The loaded SQLite library version ("3.46.1"), for diagnostics/proofs.
    // Forces the sqlite3.dll load if not already loaded.
    class function LibVersion: RawByteString; static;
    // Eagerly load sqlite3.dll (idempotent). Raises EAefosLazSQLite if the DLL is
    // absent/unreadable, so a host can fail fast with a clear message instead of
    // on the first db operation. Callers do NOT have to call this -- Create and
    // LibVersion self-load -- but it is handy for a startup probe / test.
    class procedure EnsureLibraryLoaded; static;
    // The lazy PROCESS-WIDE singleton for APathUtf8 -- the FPC twin of the Delphi
    // SQLiteDatabase() (Aefos.Data.SQLite.pas). One open connection for the life of
    // the process (released in this unit's finalization), so callers never open
    // per operation. Switching to a different path retires the previous singleton
    // (only tests do that; production uses one path). Callers must NOT Free it.
    class function Shared(const APathUtf8: RawByteString): TAefosLazSQLiteDb; static;
    // How many real sqlite connections were opened this process -- lets a test
    // prove the singleton is reused (stays 1) rather than reopened per call.
    class function OpenCount: Integer; static;
  end;

implementation

const
  SQLITE_OK   = 0;
  SQLITE_ROW  = 100;

  SQLITE_OPEN_READWRITE = $00000002;
  SQLITE_OPEN_CREATE    = $00000004;

  // ((sqlite3_destructor_type)-1): tell SQLite to COPY the bound text.
  SQLITE_TRANSIENT = Pointer(-1);

  // The standard i386 SQLite library shipped beside lazarus.exe (built from the
  // vendored amalgamation by scripts\build-sqlite-fpc.ps1 -Dll). Default DLL
  // search order looks in the host exe's own directory first, so our shipped copy
  // wins over any stray sqlite3.dll on PATH.
  SQLITE_DLL_NAME = 'sqlite3.dll';

type
  TSQLiteDestructor = Pointer;

  // ── C ABI function-pointer types (the documented C-import exception to the
  // no-loose-function rule; kept unit-private in the implementation section).
  // The DLL exports plain cdecl names (sqlite3_open_v2, ...) -- verified with
  // objdump on the built DLL -- so GetProcedureAddress resolves them directly. ──
  TSqliteLibVersion   = function: PAnsiChar; cdecl;
  TSqliteOpenV2       = function(filename: PAnsiChar; var ppDb: Pointer;
    flags: Integer; zVfs: PAnsiChar): Integer; cdecl;
  TSqliteClose        = function(db: Pointer): Integer; cdecl;
  TSqliteExec         = function(db: Pointer; sql: PAnsiChar; cb: Pointer;
    user: Pointer; errmsg: PPAnsiChar): Integer; cdecl;
  TSqliteErrmsg       = function(db: Pointer): PAnsiChar; cdecl;
  TSqliteBusyTimeout  = function(db: Pointer; ms: Integer): Integer; cdecl;
  TSqlitePrepareV2    = function(db: Pointer; zSql: PAnsiChar; nByte: Integer;
    var ppStmt: Pointer; pzTail: PPAnsiChar): Integer; cdecl;
  TSqliteStep         = function(stmt: Pointer): Integer; cdecl;
  TSqliteFinalize     = function(stmt: Pointer): Integer; cdecl;
  TSqliteBindText     = function(stmt: Pointer; idx: Integer; text: PAnsiChar;
    nByte: Integer; destr: TSQLiteDestructor): Integer; cdecl;
  TSqliteBindInt      = function(stmt: Pointer; idx: Integer; value: Integer): Integer; cdecl;
  TSqliteColumnInt    = function(stmt: Pointer; iCol: Integer): Integer; cdecl;
  TSqliteColumnText   = function(stmt: Pointer; iCol: Integer): PAnsiChar; cdecl;

var
  // Resolved once from sqlite3.dll by TAefosLazSQLiteDb.EnsureLibraryLoaded. Named
  // exactly like the C entry points so the method bodies below read unchanged.
  sqlite3_libversion:   TSqliteLibVersion  = nil;
  sqlite3_open_v2:      TSqliteOpenV2      = nil;
  sqlite3_close:        TSqliteClose       = nil;
  sqlite3_exec:         TSqliteExec        = nil;
  sqlite3_errmsg:       TSqliteErrmsg      = nil;
  sqlite3_busy_timeout: TSqliteBusyTimeout = nil;
  sqlite3_prepare_v2:   TSqlitePrepareV2   = nil;
  sqlite3_step:         TSqliteStep        = nil;
  sqlite3_finalize:     TSqliteFinalize    = nil;
  sqlite3_bind_text:    TSqliteBindText    = nil;
  sqlite3_bind_int:     TSqliteBindInt     = nil;
  sqlite3_column_int:   TSqliteColumnInt   = nil;
  sqlite3_column_text:  TSqliteColumnText  = nil;

  GSqliteLib:     {$IFDEF FPC}TLibHandle{$ELSE}HMODULE{$ENDIF} = 0;
  GSqliteLoaded:  Boolean = False;
  GSqliteLoadLock: TCriticalSection = nil;

{ Library loader -- resolves the sqlite3.dll entry points once, thread-safely. }

class procedure TAefosLazSQLiteDb.EnsureLibraryLoaded;

  function _Proc(const AName: AnsiString): Pointer;
  begin
    {$IFDEF FPC}
    Result := GetProcedureAddress(GSqliteLib, AName);
    {$ELSE}
    Result := GetProcAddress(GSqliteLib, PAnsiChar(AName));
    {$ENDIF}
    if Result = nil then
      raise EAefosLazSQLite.CreateFmt('sqlite3.dll is missing export "%s"', [string(AName)]);
  end;

begin
  if GSqliteLoaded then
    Exit;
  GSqliteLoadLock.Enter;
  try
    if GSqliteLoaded then
      Exit;
    GSqliteLib := LoadLibrary(SQLITE_DLL_NAME);
    if GSqliteLib = {$IFDEF FPC}NilHandle{$ELSE}0{$ENDIF} then
      raise EAefosLazSQLite.Create(
        'Cannot load ' + SQLITE_DLL_NAME + ' (expected beside the host ' +
        'executable). Reinstall the Aefos AI Lazarus edition.');
    sqlite3_libversion   := TSqliteLibVersion(_Proc('sqlite3_libversion'));
    sqlite3_open_v2      := TSqliteOpenV2(_Proc('sqlite3_open_v2'));
    sqlite3_close        := TSqliteClose(_Proc('sqlite3_close'));
    sqlite3_exec         := TSqliteExec(_Proc('sqlite3_exec'));
    sqlite3_errmsg       := TSqliteErrmsg(_Proc('sqlite3_errmsg'));
    sqlite3_busy_timeout := TSqliteBusyTimeout(_Proc('sqlite3_busy_timeout'));
    sqlite3_prepare_v2   := TSqlitePrepareV2(_Proc('sqlite3_prepare_v2'));
    sqlite3_step         := TSqliteStep(_Proc('sqlite3_step'));
    sqlite3_finalize     := TSqliteFinalize(_Proc('sqlite3_finalize'));
    sqlite3_bind_text    := TSqliteBindText(_Proc('sqlite3_bind_text'));
    sqlite3_bind_int     := TSqliteBindInt(_Proc('sqlite3_bind_int'));
    sqlite3_column_int   := TSqliteColumnInt(_Proc('sqlite3_column_int'));
    sqlite3_column_text  := TSqliteColumnText(_Proc('sqlite3_column_text'));
    GSqliteLoaded := True;
  finally
    GSqliteLoadLock.Leave;
  end;
end;

{ TAefosLazSQLiteStmt }

constructor TAefosLazSQLiteStmt.Create(AStmt, ADbForErr: Pointer);
begin
  inherited Create;
  FStmt := AStmt;
  FDbForErr := ADbForErr;
end;

destructor TAefosLazSQLiteStmt.Destroy;
begin
  if FStmt <> nil then
    sqlite3_finalize(FStmt);
  FStmt := nil;
  inherited Destroy;
end;

procedure TAefosLazSQLiteStmt.BindText(AIndex: Integer;
  const AValueUtf8: RawByteString);
begin
  // Length in BYTES (UTF-8); SQLITE_TRANSIENT makes SQLite copy the buffer.
  sqlite3_bind_text(FStmt, AIndex, PAnsiChar(AValueUtf8),
    Length(AValueUtf8), SQLITE_TRANSIENT);
end;

procedure TAefosLazSQLiteStmt.BindInt(AIndex: Integer; AValue: Integer);
begin
  sqlite3_bind_int(FStmt, AIndex, AValue);
end;

function TAefosLazSQLiteStmt.Step: Boolean;
begin
  Result := sqlite3_step(FStmt) = SQLITE_ROW;
end;

function TAefosLazSQLiteStmt.ColTextUtf8(AIndex: Integer): RawByteString;
var
  LPtr: PAnsiChar;
begin
  LPtr := sqlite3_column_text(FStmt, AIndex);
  if LPtr = nil then
    Result := ''
  else
    Result := RawByteString(LPtr); // NUL-terminated UTF-8 -> copied
end;

function TAefosLazSQLiteStmt.ColInt(AIndex: Integer): Integer;
begin
  Result := sqlite3_column_int(FStmt, AIndex);
end;

{ TAefosLazSQLiteDb }

constructor TAefosLazSQLiteDb.Create(const APathUtf8: RawByteString;
  ABusyTimeoutMs: Integer);
begin
  inherited Create;
  EnsureLibraryLoaded;
  FLock := TCriticalSection.Create;
  FDb := nil;
  if sqlite3_open_v2(PAnsiChar(APathUtf8), FDb,
    SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE, nil) <> SQLITE_OK then
  begin
    // open_v2 may still hand back a handle carrying the error message.
    if FDb <> nil then
      sqlite3_close(FDb);
    FDb := nil;
    raise EAefosLazSQLite.Create('sqlite3_open_v2 failed');
  end;
  _Bootstrap(ABusyTimeoutMs);
  Inc(FOpenCount);
end;

destructor TAefosLazSQLiteDb.Destroy;
begin
  if FDb <> nil then
  begin
    // Checkpoint the WAL so no -wal/-shm sidecar is orphaned for the OTHER
    // process (the Delphi/FireDAC brain) to trip over; TRUNCATE shrinks it to 0.
    try
      sqlite3_exec(FDb, 'PRAGMA wal_checkpoint(TRUNCATE)', nil, nil, nil);
    except
      // best-effort on teardown
    end;
    sqlite3_close(FDb);
    FDb := nil;
  end;
  FLock.Free;
  inherited Destroy;
end;

procedure TAefosLazSQLiteDb._Check(ARc: Integer; const AWhat: string);
var
  LMsg: PAnsiChar;
begin
  if ARc = SQLITE_OK then
    Exit;
  LMsg := sqlite3_errmsg(FDb);
  if LMsg = nil then
    raise EAefosLazSQLite.CreateFmt('%s failed (rc=%d)', [AWhat, ARc])
  else
    raise EAefosLazSQLite.CreateFmt('%s failed: %s', [AWhat, string(RawByteString(LMsg))]);
end;

procedure TAefosLazSQLiteDb._Bootstrap(ABusyTimeoutMs: Integer);
begin
  // Mirror the Delphi _Bootstrap: WAL + synchronous=NORMAL + the meta k/v table.
  // busy_timeout lets a writer wait out the OTHER process's lock instead of
  // failing SQLITE_BUSY immediately (two-process concurrency, WAL single-writer).
  sqlite3_busy_timeout(FDb, ABusyTimeoutMs);
  Exec('PRAGMA journal_mode=WAL');
  Exec('PRAGMA synchronous=NORMAL');
  Exec('CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT)');
end;

procedure TAefosLazSQLiteDb.Lock;
begin
  FLock.Enter;
end;

procedure TAefosLazSQLiteDb.Unlock;
begin
  FLock.Leave;
end;

procedure TAefosLazSQLiteDb.Exec(const ASqlUtf8: RawByteString);
var
  LRc: Integer;
begin
  LRc := sqlite3_exec(FDb, PAnsiChar(ASqlUtf8), nil, nil, nil);
  _Check(LRc, 'exec');
end;

function TAefosLazSQLiteDb.Prepare(
  const ASqlUtf8: RawByteString): TAefosLazSQLiteStmt;
var
  LStmt: Pointer;
begin
  LStmt := nil;
  // nByte = -1: read to the first NUL. pzTail = nil: single statement.
  _Check(sqlite3_prepare_v2(FDb, PAnsiChar(ASqlUtf8), -1, LStmt, nil), 'prepare');
  Result := TAefosLazSQLiteStmt.Create(LStmt, FDb);
end;

function TAefosLazSQLiteDb.MetaGet(
  const AKeyUtf8, ADefaultUtf8: RawByteString): RawByteString;
var
  LStmt: TAefosLazSQLiteStmt;
begin
  Result := ADefaultUtf8;
  Lock;
  try
    LStmt := Prepare('SELECT v FROM meta WHERE k = ?');
    try
      LStmt.BindText(1, AKeyUtf8);
      if LStmt.Step then
        Result := LStmt.ColTextUtf8(0);
    finally
      LStmt.Free;
    end;
  finally
    Unlock;
  end;
end;

procedure TAefosLazSQLiteDb.MetaSet(const AKeyUtf8, AValueUtf8: RawByteString);
var
  LStmt: TAefosLazSQLiteStmt;
begin
  Lock;
  try
    LStmt := Prepare(
      'INSERT INTO meta (k, v) VALUES (?, ?) ' +
      'ON CONFLICT(k) DO UPDATE SET v = excluded.v');
    try
      LStmt.BindText(1, AKeyUtf8);
      LStmt.BindText(2, AValueUtf8);
      LStmt.Step; // runs to completion (no rows)
    finally
      LStmt.Free;
    end;
  finally
    Unlock;
  end;
end;

class function TAefosLazSQLiteDb.LibVersion: RawByteString;
begin
  EnsureLibraryLoaded;
  Result := RawByteString(sqlite3_libversion);
end;

// ── Process-wide singleton (the FPC twin of Delphi's SQLiteDatabase()) ────────
var
  GSharedDb: TAefosLazSQLiteDb = nil;
  GSharedPathU8: RawByteString = '';
  GSharedLock: TCriticalSection = nil;

class function TAefosLazSQLiteDb.Shared(
  const APathUtf8: RawByteString): TAefosLazSQLiteDb;
begin
  GSharedLock.Enter;
  try
    // A different db path (only a test switching its temp root) retires the old
    // singleton -- checkpoint + close -- before opening the new one. Production
    // always asks for the same %APPDATA%\Aefos\aefos.db.
    if (GSharedDb <> nil) and (GSharedPathU8 <> APathUtf8) then
    begin
      GSharedDb.Free;
      GSharedDb := nil;
    end;
    if GSharedDb = nil then
    begin
      GSharedDb := TAefosLazSQLiteDb.Create(APathUtf8);
      GSharedPathU8 := APathUtf8;
    end;
    Result := GSharedDb;
  finally
    GSharedLock.Leave;
  end;
end;

class function TAefosLazSQLiteDb.OpenCount: Integer;
begin
  Result := FOpenCount;
end;

initialization
  GSharedLock := TCriticalSection.Create;
  GSqliteLoadLock := TCriticalSection.Create;

finalization
  // Release the singleton BEFORE the unit unloads (BPL/exe teardown hygiene): the
  // destructor checkpoints the WAL (TRUNCATE -> no -wal/-shm residue for the Delphi
  // brain) and closes the connection. Never raise out of finalization.
  if GSharedDb <> nil then
  begin
    try
      GSharedDb.Free;
    except
      // teardown must not raise
    end;
    GSharedDb := nil;
  end;
  // Unload sqlite3.dll AFTER the db is closed (order matters: closing calls into
  // the DLL). Never raise out of finalization.
  if GSqliteLib <> {$IFDEF FPC}NilHandle{$ELSE}0{$ENDIF} then
  begin
    try
      {$IFDEF FPC}UnloadLibrary(GSqliteLib);{$ELSE}FreeLibrary(GSqliteLib);{$ENDIF}
    except
      // teardown must not raise
    end;
    GSqliteLib := {$IFDEF FPC}NilHandle{$ELSE}0{$ENDIF};
    GSqliteLoaded := False;
  end;
  GSharedLock.Free;
  GSharedLock := nil;
  GSqliteLoadLock.Free;
  GSqliteLoadLock := nil;

end.
