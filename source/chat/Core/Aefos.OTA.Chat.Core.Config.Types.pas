unit Aefos.OTA.Chat.Core.Config.Types;

{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  Domain types for the Aefos configuration
  (ESP-002, Epic 2/4, Demand 1/4).

  Declares the snapshot record, the persistence interface, the exception
  family, and the default-value builder. No I/O, no JSON, no OTA — pure
  contract definitions consumed by Core.Config.

  Architectural baseline:
    - ADR-035: JSON at <root>\.aefos\config.json. NOTE: <root> is injected; the
      shipped wiring uses the GLOBAL per-user root %APPDATA%\Aefos (IDE-wide, NOT
      per-project) so Options works with no project open (install-feedback #1).
    - ADR-036: env var > config > PATH > bundled-bin resolution order.
    - BR-3: defaults returned silently when file/field is absent.
}

interface

uses
  SysUtils,
  Aefos.Provider.Types,
  Aefos.OTA.Chat.Core.Dispatcher.Types;

type
  // Dev/maintainer toggle for the MCP Tool Inspector (Epic 7/7 Demand 1/8,
  // ADR-119). Hidden by default; flipping `enabled: true` reveals the
  // `Tools` → `MCP Tool Inspector (Dev)` menu entry on the next menu open.
  TInspectorConfig = record
    Enabled: Boolean;
  end;

  TConfig = record
    ExecutorPath: string;
    Model: string;
    Executor: TExecutorKind;
    Inspector: TInspectorConfig;
    // Total-run timeout in seconds (ADR-290). 0 = disabled (default). Surfaced
    // to the user in seconds; the engine maps it to TDispatchRequest.TimeoutMs.
    TimeoutSeconds: Integer;
    // Stdout output-filter policy (ADR-289/290). Default ofpStrip preserves
    // today's NO_COLOR + CSI-strip behaviour.
    OutputFilter: TOutputFilterPolicy;
    // Local-model (ekOllama) endpoint base URL. '' means the transport's
    // default (http://localhost:11434). Ignored by every other executor.
    OllamaBaseUrl: string;
    // Agent behaviour / permission knobs (ADR-216 family). Persisted in the SAME
    // %APPDATA%\Aefos\.aefos\config.json as the fields above, so a user who runs
    // BOTH the RAD Studio plugin and the Lazarus edition has ONE brain: auto-
    // approve / authorize-execution and the review preferences are shared IDE-
    // wide across both editions (owner rule 2026-07-17). NOTE: the RAD Studio
    // plugin's own "AI Flow" page currently reads/writes these from the IDE
    // registry (Aefos.OTA.Options.AIFlow); the Lazarus edition reads/writes them
    // HERE. Repointing the RAD side at this record is the remaining unification
    // step (see the port report) - the fields already live in one file.
    //   AgentConsentMode:    0 = Ask every time (default), 1 = Auto-approve
    //                        edits (ask before destructive), 2 = Auto-approve
    //                        everything. Out-of-range normalises to 0.
    //   AgentEditReviewMode: 0 = Wait for approval, 1 = Preview then apply
    //                        (default), 2 = Apply silently. Out-of-range -> 1.
    AgentConsentMode: Integer;
    AgentEditReviewMode: Integer;
    AgentAutoSave: Boolean;
    IssueReporting: Boolean;
    // Lazarus-only: start the hosted Aefos MCP server at IDE load. The RAD
    // plugin has no equivalent (its Terminal MCP host uses a separate INI), so
    // this key sits under the same root but is inert on the RAD side - kept in
    // the shared record only so a RAD Options save round-trips (never drops) it.
    McpAutostart: Boolean;
  end;

  IConfig = interface
    ['{4F1A8D2B-6E73-4B85-AC31-1D9B7F6E2A48}']
    procedure Load;
    procedure Save(const AConfig: TConfig);
    function Snapshot: TConfig;
  end;

  EConfigError = class(Exception);
  EConfigSaveFailed = class(EConfigError);

function DefaultConfig: TConfig;

implementation

function DefaultConfig: TConfig;
begin
  Result.ExecutorPath := '';
  Result.Model := '';
  // Fresh-install default = the bundled, ready-to-use CLI (codex ships in the
  // installer). With ExecutorPath empty the resolver's bundled-bin rung finds
  // %APPDATA%\Aefos\bin\codex.exe, so Tools -> Options -> Aefos -> AI Chat opens
  // on a working executor with zero setup. Guarded by TFile.Exists upstream: a
  // build that did NOT bundle codex simply shows the "set executor" onboarding
  // (never worse than before). A user's own choice persists per-project in
  // .aefos\config.json and always overrides this. NOTE: the parse-fallback for an
  // UNKNOWN token stays ekClaude (ParseExecutorKind) — this is only the no-file
  // default.
  Result.Executor := ekCodex;
  // ADR-119: Inspector hidden by default. End-user installations never see
  // it without flipping `inspector.enabled = true` in config.json.
  Result.Inspector.Enabled := False;
  // ADR-288/289/290: timeout disabled + strip filter keep every existing
  // install byte-identical (BR-1).
  Result.TimeoutSeconds := 0;
  Result.OutputFilter := ofpStrip;
  Result.OllamaBaseUrl := '';
  // ADR-216 family: safe defaults keep every existing install byte-identical -
  // Ask every time (never silently auto-approves), Preview edits, no auto-save,
  // issue reporting off (opt-in), MCP autostart off.
  Result.AgentConsentMode := 0;
  Result.AgentEditReviewMode := 1;
  Result.AgentAutoSave := False;
  Result.IssueReporting := False;
  Result.McpAutostart := False;
end;

end.
