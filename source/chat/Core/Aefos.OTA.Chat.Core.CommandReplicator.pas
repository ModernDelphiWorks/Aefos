unit Aefos.OTA.Chat.Core.CommandReplicator;

{
  Command replicator implementation (ESP-009, demand 5/5; updated for
  ADR-038 in ESP-002 Demand 1/4 of Epic 2/4; for ADR-079 in ESP-005
  Demand 3/5 of Epic 4/5; for ADR-097/098 in ESP-002 Demand 5/6 of
  Epic 5/7).

  Mirrors every canonical command under `<root>\.aefos\commands\<name>\`
  to `<root>\<target>\<replicaRelPath>`. The replicator is the single,
  complete writer of every executor replica tree (ADR-097): per command it
  loads the full `TCanonicalCommand` via `ICommandRegistry.LoadCommand`,
  clean-rebuilds the per-command replica subtree `<targetRoot>\<name>\` so a
  reference removed from canonical never lingers (BR-5), writes the
  `COMMAND.md` replica, then identity-copies every `references\<ref>.md`
  slice.

  The per-command replica layout and content transform are owned by the
  injected `IExecutorProfile` (ADR-079/098): when `RequiresCommandConversion`
  is `False` the `COMMAND.md` replica is a byte-identical identity copy via
  `TFile.Copy(..., True)` (ADR-019 still governs the Claude path); when
  `True` the canonical file is read, passed through
  `IExecutorProfile.ConvertCommand`, and written as UTF-8 without BOM (the
  Codex frontmatter-stripping path). Reference slices are always
  identity-copied — they carry no frontmatter (BR-3); their layout is given
  by `IExecutorProfile.ReferenceReplicaRelPath`. Per-command and per-reference
  failures are caught and recorded in `TReplicationReport.Failures`
  (`ReferenceName` empty for a command-level failure); the loop never aborts
  on a single failure (ADR-018, ADR-021).

  Project root is resolved via a `TFunc<string>` lambda (same pattern as
  `Core.CommandRegistry`). The replication target root is always governed by
  `IExecutorProfile.ResolveReplicationRoot` (ADR-239); the legacy
  `replicator_target` override has been retired.
  An empty root resolver result raises `EReplicatorRootUnavailable`.

  Threading: synchronous file I/O on the calling thread. No background
  work, no locks.
}

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  Aefos.OTA.Chat.Core.CommandRegistry.Types,
  Aefos.OTA.Chat.Core.CommandReplicator.Types,
  Aefos.Provider.Types;

type
  TCommandReplicator = class(TInterfacedObject, ICommandReplicator)
  private
    FRegistry: ICommandRegistry;
    FProjectRootResolver: TFunc<string>;
    FProfile: IExecutorProfile;
    function _RequireProjectRoot: string;
    procedure _WriteConvertedCommand(const ACanonicalPath,
      ATargetFile: string);
    procedure _RecordFailure(const AFailures: TList<TReplicationFailure>;
      const ACommandName, AReferenceName, AReason: string);
    procedure _CleanCommandSubtree(const ATargetRoot, ACommandName: string);
    procedure _CopyCommandFile(const ACommand: TCommandMetadata;
      const ATargetRoot: string);
    procedure _CopyReferenceFile(const ACommandName: string;
      const AReference: TCommandReference; const ATargetRoot: string);
    procedure _TryCopyReference(const ACommandName: string;
      const AReference: TCommandReference; const ATargetRoot: string;
      const AFailures: TList<TReplicationFailure>);
    procedure _TryReplicateCommand(const ACommand: TCommandMetadata;
      const ATargetRoot: string;
      const ASucceeded: TList<string>;
      const AFailures: TList<TReplicationFailure>);
  public
    constructor Create(const ARegistry: ICommandRegistry;
      const AProjectRootResolver: TFunc<string>;
      const AProfile: IExecutorProfile);
    function Replicate: TReplicationReport;
  end;

implementation

uses
  System.IOUtils;

constructor TCommandReplicator.Create(const ARegistry: ICommandRegistry;
  const AProjectRootResolver: TFunc<string>;
  const AProfile: IExecutorProfile);
begin
  inherited Create;
  if not Assigned(ARegistry) then
    raise EArgumentNilException.Create('ARegistry must be assigned');
  if not Assigned(AProjectRootResolver) then
    raise EArgumentNilException.Create('AProjectRootResolver must be assigned');
  if not Assigned(AProfile) then
    raise EArgumentNilException.Create('AProfile must be assigned');
  FRegistry := ARegistry;
  FProjectRootResolver := AProjectRootResolver;
  FProfile := AProfile;
end;

function TCommandReplicator._RequireProjectRoot: string;
begin
  Result := FProjectRootResolver();
  if Result = '' then
    raise EReplicatorRootUnavailable.Create(
      'No active Delphi project; the commands replication target is unavailable');
end;

procedure TCommandReplicator._WriteConvertedCommand(const ACanonicalPath,
  ATargetFile: string);
var
  LCanonical: string;
  LConverted: string;
begin
  // Read tolerating a BOM, convert, write UTF-8 without BOM (R-3):
  // TEncoding.UTF8.GetBytes emits no preamble.
  LCanonical := TFile.ReadAllText(ACanonicalPath, TEncoding.UTF8);
  LConverted := FProfile.ConvertCommand(LCanonical);
  TFile.WriteAllBytes(ATargetFile, TEncoding.UTF8.GetBytes(LConverted));
end;

procedure TCommandReplicator._RecordFailure(
  const AFailures: TList<TReplicationFailure>;
  const ACommandName, AReferenceName, AReason: string);
var
  LFailure: TReplicationFailure;
begin
  LFailure.CommandName := ACommandName;
  LFailure.ReferenceName := AReferenceName;
  LFailure.Reason := AReason;
  AFailures.Add(LFailure);
end;

// Drift control (BR-5 / ADR-097): recursively delete the per-command replica
// subtree before any write so a reference removed from canonical does not
// linger. The delete is bounded to exactly `<ATargetRoot>\<ACommandName>\`
// and nothing above it (C-8); the root resolver already raised
// EReplicatorRootUnavailable on an empty root before this point.
procedure TCommandReplicator._CleanCommandSubtree(const ATargetRoot,
  ACommandName: string);
var
  LSubtree: string;
begin
  LSubtree := TPath.Combine(ATargetRoot, ACommandName);
  if TDirectory.Exists(LSubtree) then
    TDirectory.Delete(LSubtree, True);
end;

// Writes the COMMAND.md replica via the profile-owned layout + transform
// (ADR-079, unchanged): identity TFile.Copy when no conversion is needed,
// otherwise the read -> ConvertCommand -> UTF-8-no-BOM write path.
procedure TCommandReplicator._CopyCommandFile(const ACommand: TCommandMetadata;
  const ATargetRoot: string);
var
  LTargetFile: string;
  LTargetDir: string;
begin
  LTargetFile := TPath.Combine(ATargetRoot,
    FProfile.CommandReplicaRelPath(ACommand.Name));
  LTargetDir := ExtractFileDir(LTargetFile);
  if not ForceDirectories(LTargetDir) then
    raise ECommandReplicatorError.CreateFmt(
      'Cannot create target folder "%s"', [LTargetDir]);
  if FProfile.RequiresCommandConversion then
    _WriteConvertedCommand(ACommand.Path, LTargetFile)
  else
    TFile.Copy(ACommand.Path, LTargetFile, True);
end;

// Identity-copies one reference slice (BR-3): the canonical file is copied
// verbatim — no frontmatter conversion ever applies to a reference. The
// layout is profile-owned via ReferenceReplicaRelPath (ADR-098, C-6).
procedure TCommandReplicator._CopyReferenceFile(const ACommandName: string;
  const AReference: TCommandReference; const ATargetRoot: string);
var
  LTargetFile: string;
  LTargetDir: string;
begin
  LTargetFile := TPath.Combine(ATargetRoot,
    FProfile.ReferenceReplicaRelPath(ACommandName, AReference.Name));
  LTargetDir := ExtractFileDir(LTargetFile);
  if not ForceDirectories(LTargetDir) then
    raise ECommandReplicatorError.CreateFmt(
      'Cannot create target folder "%s"', [LTargetDir]);
  TFile.Copy(AReference.Path, LTargetFile, True);
end;

procedure TCommandReplicator._TryCopyReference(const ACommandName: string;
  const AReference: TCommandReference; const ATargetRoot: string;
  const AFailures: TList<TReplicationFailure>);
begin
  try
    _CopyReferenceFile(ACommandName, AReference, ATargetRoot);
  except
    on E: Exception do
      _RecordFailure(AFailures, ACommandName, AReference.Name, E.Message);
  end;
end;

// Replicates one complete command (ADR-097): clean-rebuild the subtree, write
// the COMMAND.md replica, then identity-copy every reference. A LoadCommand
// failure (malformed command) is a command-level failure; per-command and
// per-reference failures are isolated and the run continues (BR-6).
procedure TCommandReplicator._TryReplicateCommand(const ACommand: TCommandMetadata;
  const ATargetRoot: string;
  const ASucceeded: TList<string>;
  const AFailures: TList<TReplicationFailure>);
var
  LCanonical: TCanonicalCommand;
  LIndex: Integer;
begin
  try
    LCanonical := FRegistry.LoadCommand(ACommand.Name);
  except
    on E: Exception do
    begin
      _RecordFailure(AFailures, ACommand.Name, '', E.Message);
      Exit;
    end;
  end;
  try
    _CleanCommandSubtree(ATargetRoot, ACommand.Name);
    _CopyCommandFile(ACommand, ATargetRoot);
    ASucceeded.Add(ACommand.Name);
  except
    on E: Exception do
      _RecordFailure(AFailures, ACommand.Name, '', E.Message);
  end;
  for LIndex := 0 to High(LCanonical.References) do
    _TryCopyReference(ACommand.Name, LCanonical.References[LIndex],
      ATargetRoot, AFailures);
end;

function TCommandReplicator.Replicate: TReplicationReport;
var
  LRoot: string;
  LTargetRoot: string;
  LCommands: TArray<TCommandMetadata>;
  LIndex: Integer;
  LSucceeded: TList<string>;
  LFailures: TList<TReplicationFailure>;
begin
  LRoot := _RequireProjectRoot;
  // ADR-239: profile is the sole authority for the replication root.
  LTargetRoot := FProfile.ResolveReplicationRoot(LRoot);
  Result.TargetRoot := LTargetRoot;
  LCommands := FRegistry.List;
  LSucceeded := TList<string>.Create;
  LFailures := TList<TReplicationFailure>.Create;
  try
    for LIndex := 0 to High(LCommands) do
      _TryReplicateCommand(LCommands[LIndex], LTargetRoot, LSucceeded, LFailures);
    Result.Succeeded := LSucceeded.ToArray;
    Result.Failures := LFailures.ToArray;
  finally
    LFailures.Free;
    LSucceeded.Free;
  end;
end;

end.
