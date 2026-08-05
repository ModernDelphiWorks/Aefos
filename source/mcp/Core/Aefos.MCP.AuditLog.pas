unit Aefos.MCP.AuditLog;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  Minimal JSONL audit log for destructive-tool invocations
  (ESP-002, Epic 3/5 Demand 3/5 — scope extension SE-2; ADR-067).

  Every destructive-tool invocation (applied, error, or user-denied) appends
  exactly one JSON object per line to:

    %APPDATA%\Aefos\logs\mcp-audit-YYYY-MM-DD.jsonl

  Each line is a JSON object with keys ts, tool, args, consent, outcome and,
  when a session id was injected, a trailing session_id correlation key
  (ESP-002, Epic 3/3 Demand 3/3; ADR-263/264). The composition root mints one
  session id per MCP-server lifetime and injects it through the ASessionId
  constructor; the key is emitted only when non-empty so old, session-less
  lines stay byte-identical and still parse (BR-3/BR-4).

  Failure policy (BR-9): the audit log is observability, not a gate. A
  write failure is caught, reported via OutputDebugString, and swallowed —
  it never aborts the destructive tool.

  Threading: Append runs on the MCP worker thread (no OTA / VCL); writes
  are serialised by a critical section and use append mode.

  Tests inject a temp-file path through the overloaded constructor so the
  DUnit fixture never pollutes %APPDATA%.
}

interface

type
  // Append-only writer of one JSONL line per destructive-tool invocation.
  IMCPAuditLog = interface
    ['{8C2E5A14-7B93-4D6F-A081-3E9C2D5B7F60}']
    procedure Append(const AToolName, AArgsSummary, AConsent,
      AOutcome: string);
  end;

  TMCPAuditLog = class(TInterfacedObject, IMCPAuditLog)
  private
    FLock: TObject;
    FFilePath: string;
    FSessionId: string;
  public
    constructor Create; overload;
    constructor Create(const AFilePath: string); overload;
    // Composition-root seam (ADR-263): a plugin-minted session id stamped on
    // every line so an LLM can correlate all audited actions of one MCP-server
    // lifetime. Pass '' for the session-less degenerate path (BR-3).
    constructor Create(const AFilePath, ASessionId: string); overload;
    destructor Destroy; override;
    // IMCPAuditLog
    procedure Append(const AToolName, AArgsSummary, AConsent,
      AOutcome: string);
    // Logs directory: %APPDATA%\Aefos\logs (the locked C-11 location).
    // Single source shared by the writer and the QueryAuditLog reader (C-3).
    class function LogDir: string;
    // Default JSONL path: %APPDATA%\Aefos\logs\mcp-audit-<date>.jsonl.
    class function LogFilePath: string;
  end;

implementation

uses
  // Winapi-scoped units stay dotted on Delphi: not every consumer .dproj config
  // carries the Winapi unit-scope prefix (System.* is safe, Winapi.* is not).
{$IFDEF FPC}
  Windows,
{$ELSE}
  Winapi.Windows,
{$ENDIF}
  SysUtils,
  SyncObjs,
  Aefos.Compat.IO,
  Aefos.Compat.Json;

{ TMCPAuditLog }

constructor TMCPAuditLog.Create;
begin
  Create(LogFilePath, '');
end;

constructor TMCPAuditLog.Create(const AFilePath: string);
begin
  Create(AFilePath, '');
end;

constructor TMCPAuditLog.Create(const AFilePath, ASessionId: string);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FFilePath := AFilePath;
  FSessionId := ASessionId;
end;

destructor TMCPAuditLog.Destroy;
begin
  FLock.Free;
  inherited;
end;

class function TMCPAuditLog.LogDir: string;
begin
  // %APPDATA%\Aefos\logs — the locked session-log location (C-11).
  Result := TPath.Combine(TPath.Combine(GetEnvironmentVariable('APPDATA'),
    'Aefos'), 'logs');
end;

class function TMCPAuditLog.LogFilePath: string;
begin
  // Delegates to LogDir so writer and reader resolve one directory (C-3).
  // Behaviour-identical to the previous inline path build (AC-10).
  Result := TPath.Combine(LogDir,
    'mcp-audit-' + FormatDateTime('yyyy-mm-dd', Now) + '.jsonl');
end;

procedure TMCPAuditLog.Append(const AToolName, AArgsSummary, AConsent,
  AOutcome: string);
var
  LEntry: TJSONObject;
  LLine: string;
begin
  // Build the JSONL line off-lock; only the file write is serialised.
  LEntry := TJSONObject.Create;
  try
    LEntry.AddPair('ts', FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', Now));
    LEntry.AddPair('tool', AToolName);
    LEntry.AddPair('args', AArgsSummary);
    LEntry.AddPair('consent', AConsent);
    LEntry.AddPair('outcome', AOutcome);
    // Additive, non-breaking (BR-3): emit the correlation key only when a
    // session id was injected so the session-less path stays byte-stable.
    if FSessionId <> '' then
      LEntry.AddPair('session_id', FSessionId);
    LLine := LEntry.ToJSON;
  finally
    LEntry.Free;
  end;
  try
    TCriticalSection(FLock).Enter;
    try
      TDirectory.CreateDirectory(TPath.GetDirectoryName(FFilePath));
      TFile.AppendAllText(FFilePath, LLine + sLineBreak, TEncoding.UTF8);
    finally
      TCriticalSection(FLock).Leave;
    end;
  except
    // BR-9: a write failure is observability noise, never a tool abort.
    on E: Exception do
      // FPC's unqualified OutputDebugString is the ANSI overload (PAnsiChar);
      // the wide overload matches the Delphi PChar=PWideChar this line assumes.
{$IFDEF FPC}
      OutputDebugStringW(PWideChar('Aefos.MCPAuditLog: ' + E.Message));
{$ELSE}
      OutputDebugString(PChar('Aefos.MCPAuditLog: ' + E.Message));
{$ENDIF}
  end;
end;

end.
