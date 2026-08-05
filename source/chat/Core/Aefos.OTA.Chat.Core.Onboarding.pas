unit Aefos.OTA.Chat.Core.Onboarding;

{
  First-run onboarding evaluator (ESP-002, Epic 2/4, Demand 2/3, ADR-273).

  Pure, derived decision logic for the Chat panel's first-run empty-state.
  EvaluateOnboarding maps the live facts the panel already holds — the
  resolved CLI path (or ''), the active executor kind, and the command count —
  onto an ordered guided checklist (set executor -> create first command ->
  run first dispatch) and a single TOnboardingState.

  Architectural baseline:
    - ADR-273: state is DERIVED every call from the injected input; nothing
      is persisted (BR-1). A stale flag could claim "done" while the CLI is
      gone, so the truth is recomputed from the real config + filesystem.
    - ADR-275: detection upstream reuses ResolveCLIBinary; this evaluator is
      executor-agnostic — it consumes only a resolved path + kind, so Codex
      slots in later without touching it (BR-4).

  C-1 / BR-2: this unit is pure — no ToolsAPI, no Vcl.*, no FMX.*, no file
  I/O. Inputs are injected; the result is a value. Added to
  the coverage list and held at >=80% line coverage.
}

interface

uses
  Aefos.Provider.Types;

type
  { Derived first-run state. Onboarding guidance is shown only when the state
    is not osReady (BR-5 / AC-07). }
  TOnboardingState = (osNeedsExecutor, osNeedsCommand, osReady);

  { One ordered guidance step. Done is derived from the input on every call;
    a step is "current" when it is the first one still pending. }
  TOnboardingStep = record
    Caption: string;
    Done: Boolean;
  end;

  { The facts the panel feeds the evaluator. ResolvedCliPath is '' when no CLI
    resolves (env -> config -> PATH all empty, or a config path set but absent
    on disk — AC-06). CommandCount is the length of TCommandRegistry.List. }
  TOnboardingInput = record
    ResolvedCliPath: string;
    Executor: TExecutorKind;
    CommandCount: Integer;
  end;

  { The derived plan: the overall state, the ordered step list with per-step
    done/pending status, and the index of the current (first pending) step —
    -1 when every step is done (osReady). }
  TOnboardingPlan = record
    State: TOnboardingState;
    Steps: TArray<TOnboardingStep>;
    CurrentStepIndex: Integer;
  end;

const
  ONBOARDING_STEP_EXECUTOR = 'Set the external AI CLI';
  ONBOARDING_STEP_COMMAND = 'Create your first command';
  ONBOARDING_STEP_DISPATCH = 'Run your first command';
  ONBOARDING_NO_CURRENT_STEP = -1;

{ Derives the onboarding plan from AInput. Pure: same input -> same output,
  no side effects. The step list is always ordered
  executor -> command -> dispatch (AC-04). }
function EvaluateOnboarding(const AInput: TOnboardingInput): TOnboardingPlan;

implementation

function _DeriveState(const AInput: TOnboardingInput): TOnboardingState;
begin
  // A config path set but missing on disk reaches here as '' (the upstream
  // ResolveCLIBinary already applied TFile.Exists), so empty == not resolved
  // (AC-01 / AC-06).
  if AInput.ResolvedCliPath = '' then
    Result := osNeedsExecutor
  else if AInput.CommandCount < 1 then
    Result := osNeedsCommand
  else
    Result := osReady;
end;

function _BuildSteps(const AInput: TOnboardingInput;
  const AState: TOnboardingState): TArray<TOnboardingStep>;
begin
  SetLength(Result, 3);
  // Step 0 — set executor: done once a CLI resolves.
  Result[0].Caption := ONBOARDING_STEP_EXECUTOR;
  Result[0].Done := AInput.ResolvedCliPath <> '';
  // Step 1 — create first command: done once at least one command exists.
  Result[1].Caption := ONBOARDING_STEP_COMMAND;
  Result[1].Done := AInput.CommandCount >= 1;
  // Step 2 — run first dispatch: the terminal call-to-action; complete only
  // when executor + command are both ready (osReady), which also unlocks the
  // happy-path welcome->output flow.
  Result[2].Caption := ONBOARDING_STEP_DISPATCH;
  Result[2].Done := AState = osReady;
end;

function _FirstPendingIndex(const ASteps: TArray<TOnboardingStep>): Integer;
var
  LIndex: Integer;
begin
  // The "current" step is the first one still pending; steps before it are
  // necessarily done (AC-04). All done -> ONBOARDING_NO_CURRENT_STEP.
  for LIndex := Low(ASteps) to High(ASteps) do
    if not ASteps[LIndex].Done then
      Exit(LIndex);
  Result := ONBOARDING_NO_CURRENT_STEP;
end;

function EvaluateOnboarding(const AInput: TOnboardingInput): TOnboardingPlan;
begin
  Result.State := _DeriveState(AInput);
  Result.Steps := _BuildSteps(AInput, Result.State);
  Result.CurrentStepIndex := _FirstPendingIndex(Result.Steps);
end;

end.
