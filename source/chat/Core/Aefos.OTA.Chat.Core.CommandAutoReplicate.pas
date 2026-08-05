unit Aefos.OTA.Chat.Core.CommandAutoReplicate;

{
  Auto-replication coordinator (ESP-002, Epic 2/3 Demand 3/4, ADR-255).

  Two pure functions:
    TryAutoReplicate       - error-isolating wrapper around ICommandReplicator.Replicate.
    FormatAutoReplicationSummary - returns a single human-readable summary line.

  Constraints (C-2, AC-06):
    - RTL-only: no uses ToolsAPI, Vcl.*, FMX.*.
    - No file I/O, no state. Drives only the injected replicator (ADR-255).
    - Delphi 13 only (ADR-006).
}

interface

uses
  Aefos.OTA.Chat.Core.CommandReplicator.Types;

{ Calls AReplicator.Replicate once. Catches all exceptions (incl.
  EReplicatorRootUnavailable) and returns a benign default report with
  TargetRoot='' — the error sentinel for FormatAutoReplicationSummary.
  Never re-raises (BR-3 / ADR-255). }
function TryAutoReplicate(
  const AReplicator: ICommandReplicator): TReplicationReport;

{ Returns a single line summarising AReport. TargetRoot='' (error/no-project)
  yields "not published"; 0 commands yields "0 commands synced";
  N commands yields "N command(s) synced to <root>" optionally suffixed
  "; M failed" when failures are present (AC-02/AC-03/AC-04/AC-05). }
function FormatAutoReplicationSummary(
  const AReport: TReplicationReport): string;

implementation

uses
  System.SysUtils,
  System.StrUtils;

function TryAutoReplicate(
  const AReplicator: ICommandReplicator): TReplicationReport;
begin
  try
    Result := AReplicator.Replicate;
  except
    on E: Exception do
      Result := Default(TReplicationReport);
  end;
end;

function FormatAutoReplicationSummary(
  const AReport: TReplicationReport): string;
var
  LCount: Integer;
  LFailCount: Integer;
begin
  if AReport.TargetRoot = '' then
  begin
    Result := #$21BB + ' not published (no active project)';
    Exit;
  end;
  LCount := Length(AReport.Succeeded);
  LFailCount := Length(AReport.Failures);
  if LCount = 0 then
    Result := #$21BB + ' 0 commands synced'
  else
    Result := Format(#$21BB + ' %d command%s synced to %s',
      [LCount, IfThen(LCount = 1, '', 's'), AReport.TargetRoot]);
  if LFailCount > 0 then
    Result := Result + Format('; %d failed', [LFailCount]);
end;

end.
