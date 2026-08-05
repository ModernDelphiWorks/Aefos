unit Aefos.Data.AuditLog;

(*
  SQLite-backed IMCPAuditLog — Phase 2 of the JSON/text -> SQLite migration.

  Appends one row per destructive-tool invocation to the `audit` table in the
  shared Aefos.Data SQLite database (the same %AppData%\Roaming\Aefos\
  aefos.db that holds sessions). It is a DROP-IN alternative to the JSONL
  TMCPAuditLog (Aefos.MCP.AuditLog) — SAME IMCPAuditLog interface — so the
  composition root injects whichever it wants. The audit GROWS without bound, so a
  table + indexes turns the O(n) JSONL scan into an O(log n) query.

  This unit is the WRITER only. The QueryAuditLog reader rewrite (SQL instead of a
  file scan) and the composition-root wiring (Chat Register + Terminal Composition)
  are separate, later steps. Until those land, nothing constructs this class — it is
  a self-contained building block.

  PARKED 2026-06-15: removed from Aefos.Data.dpk (it was compiled-but-never-built
  dead weight). The source is kept here for the Phase-2 project; re-add it to the
  .dpk contains + .dproj DCCReference when the writer + reader migration is scheduled.

  Schema (ts is fixed-width local-time ISO so lexicographic compare = chronological,
  matching the JSONL writer and QueryAuditLog's ts range filters):

    audit(id INTEGER PK AUTOINCREMENT, ts, tool, args, consent, outcome, session_id)
    + indexes on ts, tool, session_id.

  Failure policy (BR-9): the audit log is observability, not a gate — a write
  failure is swallowed (logged via OutputDebugString), never aborts the tool, exactly
  like TMCPAuditLog.

  Threading: the shared ISQLiteDatabase serialises all access through Lock/Unlock.
*)

interface

uses
  Aefos.MCP.AuditLog;

type
  TSQLiteAuditLog = class(TInterfacedObject, IMCPAuditLog)
  private
    FSessionId: string;
    procedure _EnsureSchema;
  public
    // ASessionId: the correlation id minted once per MCP-server lifetime by the
    // composition root (may be '' for the session-less path).
    constructor Create(const ASessionId: string);
    // IMCPAuditLog
    procedure Append(const AToolName, AArgsSummary, AConsent, AOutcome: string);
  end;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  Aefos.Data.SQLite;

{ TSQLiteAuditLog }

constructor TSQLiteAuditLog.Create(const ASessionId: string);
begin
  inherited Create;
  FSessionId := ASessionId;
  _EnsureSchema;
end;

procedure TSQLiteAuditLog._EnsureSchema;
var
  LDb: ISQLiteDatabase;
begin
  LDb := SQLiteDatabase;
  LDb.Lock;
  try
    LDb.Connection.ExecSQL(
      'CREATE TABLE IF NOT EXISTS audit (' +
      '  id         INTEGER PRIMARY KEY AUTOINCREMENT,' +
      '  ts         TEXT NOT NULL,' +
      '  tool       TEXT NOT NULL,' +
      '  args       TEXT,' +
      '  consent    TEXT,' +
      '  outcome    TEXT NOT NULL,' +
      '  session_id TEXT' +
      ')');
    LDb.Connection.ExecSQL(
      'CREATE INDEX IF NOT EXISTS ix_audit_ts ON audit (ts)');
    LDb.Connection.ExecSQL(
      'CREATE INDEX IF NOT EXISTS ix_audit_tool ON audit (tool)');
    LDb.Connection.ExecSQL(
      'CREATE INDEX IF NOT EXISTS ix_audit_session ON audit (session_id)');
  finally
    LDb.Unlock;
  end;
end;

procedure TSQLiteAuditLog.Append(const AToolName, AArgsSummary, AConsent,
  AOutcome: string);
var
  LDb: ISQLiteDatabase;
  LTs: string;
begin
  // Fixed-width local-time ISO (yyyy-mm-ddThh:nn:ss): the same shape the JSONL
  // writer emits and QueryAuditLog's lexicographic from/to filters expect.
  LTs := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', Now);
  try
    LDb := SQLiteDatabase;
    LDb.Lock;
    try
      LDb.Connection.ExecSQL(
        'INSERT INTO audit (ts, tool, args, consent, outcome, session_id) ' +
        'VALUES (:ts, :tool, :args, :consent, :outcome, :sid)',
        [LTs, AToolName, AArgsSummary, AConsent, AOutcome, FSessionId]);
    finally
      LDb.Unlock;
    end;
  except
    on E: Exception do
      // BR-9: observability, not a gate — swallow + log, never abort the tool.
      OutputDebugString(PChar('Aefos.Data.AuditLog: ' + E.Message));
  end;
end;

end.
