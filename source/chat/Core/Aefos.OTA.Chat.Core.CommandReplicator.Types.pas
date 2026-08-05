unit Aefos.OTA.Chat.Core.CommandReplicator.Types;

{
  Domain types for the command replicator (ESP-009, demand 5/5).

  Pure declarative unit: shape of the replication report and the read-only
  contract consumed by the menu adapter. No file I/O, no OTA, no Win32.

  Architectural baseline:
    - ADR-018: full mirror of `.aefos\commands\` to `.claude\commands\`,
      unconditional overwrite, per-command failures isolated.
    - ADR-019: identity copy in MVP; no format conversion. Superseded by
      ADR-079 for the Codex path (per-profile command-replication strategy);
      ADR-019 still governs the Claude path (byte-identical identity copy).
    - ADR-021: partial-success allowed; report is the only output channel
      (no log file).
    - ADR-079: the per-executor replica layout + content transform is owned
      by `IExecutorProfile`; the replicator delegates both to the profile.
    - ADR-097: the replicator mirrors the complete canonical command
      (`COMMAND.md` + every reference slice) and clean-rebuilds each command's
      replica subtree; `TReplicationFailure` carries `ReferenceName` so a
      reference-level failure is reported distinctly from a command-level one.

  Constraints:
    - Delphi 13 only (ADR-006).
    - No third-party libraries.
}

interface

uses
  System.SysUtils;

type
  { One failed file in a replication run (ADR-097). `ReferenceName` is empty
    for a `COMMAND.md`-level failure (or a `LoadCommand` failure on a malformed
    command) and carries the reference slice name for a reference-level
    failure, so the report distinguishes the two. }
  TReplicationFailure = record
    CommandName: string;
    ReferenceName: string;
    Reason: string;
  end;

  TReplicationReport = record
    Succeeded: TArray<string>;
    Failures: TArray<TReplicationFailure>;
    TargetRoot: string;
  end;

  ICommandReplicator = interface
    ['{2C1E4D8A-9B6F-4A35-8D7C-1F0E2A4B6C8E}']
    function Replicate: TReplicationReport;
  end;

  ECommandReplicatorError = class(Exception);
  EReplicatorRootUnavailable = class(ECommandReplicatorError);

implementation

end.
