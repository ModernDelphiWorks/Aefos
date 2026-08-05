unit Aefos.OTA.Chat.Core.CommandRegistry.Types;

{
  Domain types for the canonical command registry (ESP-007, demand 3/5;
  extended by ESP-002, Epic 5/7 demand 2/6).

  Pure declarative unit: shape of the on-disk command catalogue plus the
  read/write contract consumed by demand 4/5 (ProjectContextBuilder + first
  wired action) and demand 5/5 (replicator). No file I/O, no OTA, no Win32.

  Architectural baseline:
    - ADR-008: canonical folder is `.aefos/commands/<name>/COMMAND.md`,
      project-scoped (anchored at the active Delphi project root).
    - ADR-009: command file format is Markdown body + minimal-YAML frontmatter
      (`name`, `description` required; `tags`, `version` optional).
    - ADR-010 (revised 2026-06-09): no pre-installed commands ship; the user
      authors their own. `EnsurePreinstalled` is retained on the contract as a
      no-op so the interface and the executor's lazy call stay stable.
    - ADR-011: registry has no caching layer for MVP; re-reads disk on each
      call.
    - ADR-089: the full command model (`TCanonicalCommand`, `TCommandReference`)
      is purely additive. `TCommandMetadata`, `List`, `Get`, `LoadBody` and
      their consumers stay unchanged; `TCommandMetadata` remains the
      lightweight list projection.
    - ADR-090: a command's references are auto-discovered from the optional
      `references/` subfolder — one `TCommandReference` per `*.md` file. There
      is no frontmatter reference index; the filesystem is the index.
    - ADR-091: the canonical `COMMAND.md` is executor-neutral and
      `.aefos/commands/` is the single command catalogue. Per-executor
      adaptation belongs exclusively to the replicator.

  Constraints:
    - Delphi 13 only (ADR-006).
    - No third-party libraries.
    - C-3 (ESP-002): this unit stays pure — no ToolsAPI, no VCL, no Win32,
      no file I/O.
}

interface

uses
  System.SysUtils;

type
  { Where a command's canonical folder lives. `csProject` is the active
    Delphi project's `.aefos\commands\` (ADR-008); `csGlobal` is the
    per-user `%USERPROFILE%\.aefos\commands\` catalogue that follows the user
    across every project (and is available even with no project open). A
    project command shadows a global command of the same name (project wins). }
  TCommandScope = (csProject, csGlobal);

  { Lightweight list projection of a command (name/description/version/tags/
    path/scope). Consumed by the palette/`/`-list and by CommandExecutor,
    CommandReplicator and ProjectContextBuilder. `Scope` (additive) records
    which catalogue the command was read from. }
  TCommandMetadata = record
    Name: string;
    Description: string;
    Version: string;
    Tags: TArray<string>;
    Path: string;
    Scope: TCommandScope;
  end;

  { One reference slice of a canonical command: a `*.md` file directly inside
    the command's `references/` subfolder (ADR-090). `Name` is the file name
    with the `.md` extension stripped; `Path` is the absolute file path. }
  TCommandReference = record
    Name: string;
    Path: string;
  end;

  { Full canonical command model (ADR-089). `Instructions` is the `COMMAND.md`
    body with frontmatter stripped; `References` is one entry per `*.md`
    file in the optional `references/` subfolder (empty when absent). }
  TCanonicalCommand = record
    Name: string;
    Description: string;
    Instructions: string;
    References: TArray<TCommandReference>;
  end;

  ICommandRegistry = interface
    ['{6F3D9A52-1C04-4B68-9E20-7B2A4F8D5C19}']
    function List: TArray<TCommandMetadata>;
    function Get(const ACommandName: string): TCommandMetadata;
    function LoadBody(const ACommandName: string): string;
    procedure EnsurePreinstalled;
    { Returns the full canonical model for the named command (ADR-089/090):
      `Instructions` = `COMMAND.md` body (frontmatter stripped), `References`
      auto-discovered from the optional `references/` subfolder. Raises the
      same exceptions as `Get` / `LoadBody`. }
    function LoadCommand(const ACommandName: string): TCanonicalCommand;
    { Returns the body of a reference slice file
      `<command>/references/<refName>.md`. Raises `ECommandNotFound` when the
      reference (or the command) does not exist, `ECommandFolderUnavailable`
      when there is no active project. }
    function LoadReference(const ACommandName, AReferenceName: string): string;
    { Persists ACommand to `<scope>\.aefos\commands\<slug>\COMMAND.md`
      (ADR-092). The one-argument overload targets `csProject` (backward
      compatible); the two-argument overload writes to the chosen scope —
      `csProject` = the active project (raises `ECommandFolderUnavailable`
      when none is open), `csGlobal` = `%USERPROFILE%\.aefos\commands\` (always
      available). Create-or-overwrite of `COMMAND.md` only — a pre-existing
      `references\` subfolder is left intact (BR-4). Frontmatter is
      executor-neutral (`name`, `description`; `tags` / `version` carried
      through only when the existing file already had them); body =
      `ACommand.Instructions`. Raises `ECommandMalformed` when `ACommand.Name`
      is not a filesystem-safe slug or `ACommand.Description` is empty. }
    procedure SaveCommand(const ACommand: TCanonicalCommand); overload;
    procedure SaveCommand(const ACommand: TCanonicalCommand;
      const AScope: TCommandScope); overload;
    { Persists the reference slice
      `.aefos\commands\<slug>\references\<refName>.md` (ADR-095).
      Create-or-overwrite of that one file only — `COMMAND.md` and any
      sibling reference are left untouched (BR-4); the `references\`
      subfolder is created when absent. `AContent` is written UTF-8
      (no BOM), atomically. Raises `ECommandMalformed` when `AReferenceName`
      is not a filesystem-safe slug (no file written),
      `ECommandFolderUnavailable` when there is no active project,
      `ECommandNotFound` when the command folder has no `COMMAND.md` (BR-2). }
    procedure SaveReference(const ACommandName, AReferenceName,
      AContent: string);
  end;

  ECommandRegistryError = class(Exception);
  ECommandNotFound = class(ECommandRegistryError);
  ECommandMalformed = class(ECommandRegistryError);
  ECommandFolderUnavailable = class(ECommandRegistryError);

implementation

end.
