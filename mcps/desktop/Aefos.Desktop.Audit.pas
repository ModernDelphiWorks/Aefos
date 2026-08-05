unit Aefos.Desktop.Audit;

{
  Write-audit for the Aefos Desktop MCP (feat/desktop-mcp, PHASE 3).

  Every desktop WRITE that actually EXECUTES is appended here — an accountable
  record of what the agent did on the developer's real desktop (which app it
  clicked/typed into/closed, and when). Modelled on the DB frontier's
  Aefos.Db.Audit: a plain append-only text file is the simplest thing that
  records for real, with no coupling to the SQLite session stack.

    %APPDATA%\Aefos\aefos-desktop-actions.log

  Format, one line per executed write (tab-separated, newest appended):
    <iso-timestamp>\t<tool>\t<target-exe-path>\t<summary>

  Two hard rules, both inherited from the DB audit:
    * Observability, NEVER a gate — a logging failure is swallowed; it must never
      abort or fail the action the human authorised.
    * Only EXECUTED writes are logged. A REFUSED action (any guard verdict that
      did not pass) does NOT enter the log — the log is a record of what happened
      to the desktop, not of what the agent attempted.

  RTL-only. GDesktopAuditPathOverride lets the headless test capture the log; ''
  in production.
}

interface

uses
  System.SysUtils,
  System.IOUtils;

type
  // Static, sealed namespace for the desktop write-audit. Never instantiated (no
  // constructor): both routines are class members so they have a named owner
  // (TDesktopAudit.AuditWrite) instead of floating free in the unit interface.
  TDesktopAudit = class sealed
  public
    // The append-only log file. Real path unless the test override is set.
    class function AuditLogPath: string; static;

    // Appends one record for an EXECUTED desktop write. Never raises. Call this ONLY
    // after the guard allowed the action AND it ran — refused actions are not logged.
    class procedure AuditWrite(const AToolName, ATargetExePath, ASummary: string); static;
  end;

var
  // Test-only: redirect the audit log. Empty in production.
  GDesktopAuditPathOverride: string = '';

implementation

class function TDesktopAudit.AuditLogPath: string;
var
  LAppData: string;
begin
  if GDesktopAuditPathOverride <> '' then
    Exit(GDesktopAuditPathOverride);
  LAppData := GetEnvironmentVariable('APPDATA');
  if LAppData = '' then
    LAppData := TPath.GetHomePath;
  Result := TPath.Combine(TPath.Combine(LAppData, 'Aefos'), 'aefos-desktop-actions.log');
end;

// Collapses newlines/tabs so one write is exactly one log line.
function _OneLine(const AText: string): string;
begin
  Result := StringReplace(AText, #13#10, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, #10, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, #13, ' ', [rfReplaceAll]);
  Result := StringReplace(Result, #9, ' ', [rfReplaceAll]);
end;

class procedure TDesktopAudit.AuditWrite(const AToolName, ATargetExePath, ASummary: string);
var
  LPath, LLine: string;
begin
  try
    LPath := AuditLogPath;
    ForceDirectories(ExtractFilePath(LPath));
    LLine :=
      FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', Now) + #9 +
      _OneLine(AToolName) + #9 +
      _OneLine(ATargetExePath) + #9 +
      _OneLine(ASummary) + sLineBreak;
    TFile.AppendAllText(LPath, LLine, TEncoding.UTF8);
  except
    // Observability, not a gate: never let a logging failure abort the action.
  end;
end;

end.
