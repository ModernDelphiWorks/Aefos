unit Aefos.OTA.Terminal.MCP.AuditSummary;

{
  Pure audit-line preview formatter (ESP-070, S3 / ADR-070-04).

  RTL-only — deterministic, unit-tested. Formats the audit fields (args,
  consent, outcome) for human-readable display in the Options page or
  in-protocol via QueryAuditLog. No schema extension (frozen: ts/tool/
  args/consent/outcome per ADR-067).
}

interface

type
  TMCPAuditSummary = class
  public
    class function FormatLine(
      const ATool:    string;
      const AArgs:    string;
      const AConsent: string;
      const AOutcome: string): string;
    class function TruncateArgs(const AArgs: string;
      AMaxLen: Integer = 120): string;
    class function NormalizeConsent(const AConsent: string): string;
    class function NormalizeOutcome(const AOutcome: string): string;
  end;

implementation

uses
  System.SysUtils,
  Aefos.MCP.OTA.MessageTextPolicy;

class function TMCPAuditSummary.TruncateArgs(const AArgs: string;
  AMaxLen: Integer): string;
begin
  if Length(AArgs) <= AMaxLen then
    Result := AArgs
  else
    Result := Copy(AArgs, 1, AMaxLen) + '...';
end;

class function TMCPAuditSummary.NormalizeConsent(const AConsent: string): string;
begin
  if SameText(AConsent, 'allow-once') then
    Result := 'allow-once'
  else if SameText(AConsent, 'allow-session') then
    Result := 'allow-session'
  else if SameText(AConsent, 'denied') then
    Result := 'denied'
  else if AConsent = '' then
    Result := 'n/a'
  else
    Result := AConsent;
end;

class function TMCPAuditSummary.NormalizeOutcome(const AOutcome: string): string;
begin
  if SameText(AOutcome, 'applied') then
    Result := 'applied'
  else if SameText(AOutcome, 'error') then
    Result := 'error'
  else if SameText(AOutcome, 'not-available') then
    Result := 'not-available'
  else if SameText(AOutcome, 'denied') then
    Result := 'denied'
  else if AOutcome = '' then
    Result := 'n/a'
  else
    Result := AOutcome;
end;

class function TMCPAuditSummary.FormatLine(
  const ATool:    string;
  const AArgs:    string;
  const AConsent: string;
  const AOutcome: string): string;
begin
  // Repair UTF-8-as-OEM/ANSI mojibake (#9, ESP-093) on the FULL args BEFORE
  // truncation so a multi-byte sequence is never split mid-repair. EnsureDisplayText
  // is pure + idempotent, so FormatLine stays a pure, deterministic formatter.
  Result := Format('[%s] consent=%s outcome=%s args=%s',
    [ATool,
     NormalizeConsent(AConsent),
     NormalizeOutcome(AOutcome),
     TruncateArgs(TMessageTextPolicy.EnsureDisplayText(AArgs))]);
end;

end.
