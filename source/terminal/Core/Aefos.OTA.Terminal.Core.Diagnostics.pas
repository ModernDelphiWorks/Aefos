unit Aefos.OTA.Terminal.Core.Diagnostics;

{
  Pure self-diagnosis classifier seam (ESP-074, S1 / ADR-074-02 / BR28).

  Pure RTL - no ToolsAPI, no VCL, no I/O, no clock. The single source of truth
  for mapping the machine-readable signals the harness already emits (the MCP
  go-live exit code, the tools/list count, the last read availability, the last
  gated-call audit outcome, and the L1/L2/L5 layer results) onto a structured
  TDiagnosisResult: a category, a probable cause, and a suggested next flow.

  Mirrors the established pure-seam precedent (TestContract.ExitCodeFor,
  ConsentPolicy.ResolveTimedConsent, UnitCreatePolicy.ResolveUnitCreate): a
  deterministic function over an input record, unit-tested headless, with the
  ToolsAPI-bound I/O (gathering the signals, writing the envelope) living in the
  PowerShell orchestrator and the test runner.

  Classification lives ONLY here (BR28). The orchestrator never classifies; it
  gathers signals into a TDiagnosticSignals-shaped JSON and obtains the verdict
  via the additive runner --diagnose mode, which parses the JSON here and emits
  the delphi-test/1 diagnose envelope (additive layer:"L6-diagnose" + the
  additive diagnosis object - no schema bump, ADR-074-01).
}

interface

type
  // Diagnosis verdict. The kebab string form (CategoryToString) is the value
  // written into the diagnose envelope and referenced verbatim by the playbook.
  TDiagnosisCategory = (
    dcHealthy,            // loop reachable, catalog 119, reads live, no bad audit
    dcLoopDown,           // pipe/IDE absent - the MCP loop is unreachable
    dcCatalogDrift,       // loop reachable but tools/list <> 119
    dcReadStale,          // project expected open but a read returned unavailable
    dcConsentBroken,      // a gated call was made but no audit line was recorded
    dcMutationFailed,     // a gated mutation (AddUnit) consented but outcome=error
    dcHarnessNotStarted,  // the driver itself errored before reaching the loop
    dcIndeterminate       // signals do not match any known healthy/failure shape
  );

  // Resolved diagnosis. SuggestedFlow names the next canned flow to run, or '' on
  // a healthy verdict (nothing to do).
  TDiagnosisResult = record
    Category: TDiagnosisCategory;
    ProbableCause: string;
    SuggestedFlow: string;
    // Factory: fill the three fields in one call (replaces the old _Make helper).
    class function Create(const ACategory: TDiagnosisCategory;
      const ACause, AFlow: string): TDiagnosisResult; static;
  end;

  // Input signals gathered by the orchestrator from the existing thin drivers.
  // Every field is caller-supplied; the classifier never reads the environment.
  TDiagnosticSignals = record
    LoopReachable: Boolean;     // the MCP named pipe answered
    ToolsListCount: Integer;    // tools/list result count (expected 119)
    LastReadAvailable: Boolean; // the last read returned live context
    LastAuditOutcome: string;   // applied / error / denied / timeout-denied / ''
    L1Ok: Boolean;              // L1 unit suite green
    L2Ok: Boolean;              // L2 link-probe green
    L5Ok: Boolean;              // L5 in-IDE self-test green (L5-touching flows)
    GoLiveExitCode: Integer;    // mcp-golive.ps1 exit (0 pass / 1 fail / 2 err / 3 skip)
    ExpectProjectOpen: Boolean; // the flow expects an open project (reads matter)
    GatedCallMade: Boolean;     // the flow drove a consent-gated tools/call
  private
    // One decision each; Diagnose runs them in precedence order. These are the
    // former loose _Is*/_*Green classifiers, now living on the record they read.
    function IsHarnessDown: Boolean;
    function IsLoopDown: Boolean;
    function IsCatalogDrift: Boolean;
    function IsReadStale: Boolean;
    function IsConsentBroken: Boolean;
    function IsMutationFailed: Boolean;
    function LoopGreen: Boolean;
    function ContextGreen: Boolean;
    function GatesGreen: Boolean;
    function AuditClean: Boolean;
    function IsHealthy: Boolean;
  public
    // Factory: parse a signals-shaped JSON object (as the orchestrator writes it);
    // missing keys fall back to safe defaults (False / 0 / '').
    class function FromJson(const AJson: string): TDiagnosticSignals; static;
    // Pure classification of THIS signal set onto a single diagnosis.
    function Diagnose: TDiagnosisResult;
  end;

  // Enum helpers for the diagnosis category (kebab string + exit code). The
  // classification itself lives on TDiagnosticSignals.Diagnose; parsing lives on
  // TDiagnosticSignals.FromJson. Static-only sealed class.
  TDiagnostics = class sealed
  public
    // Kebab string form of a category - the value written into the diagnose
    // envelope and referenced verbatim in diagnose-playbook.md.
    class function CategoryToString(const ACategory: TDiagnosisCategory): string; static;

    // On-demand diagnose exit code: 0 healthy, 3 loop/harness down (skip, BR18),
    // 1 a classified defect to act on (catalog/read/consent/mutation/indeterminate).
    class function ExitCodeForDiagnosis(const ACategory: TDiagnosisCategory): Integer; static;
  end;

implementation

uses
  System.SysUtils,
  System.JSON;

const
  // The governed MCP catalog size (BR30; 115 -> 116 with ESP-096 CreateNewProject,
  // then 118 -> 119 with CloseAllProjects; -1 when the redundant generic
  // CreateNewProject tool was removed in favour of the six typed CreateProject<Type>
  // tools). A local convention constant, not a code dependency on the MCP
  // composition - keeps this unit RTL-only.
  // NOTE 2026-06-27: this baseline looks stale vs the live catalog (the six typed
  // CreateProject tools, templates, pytools and ProposeAefosIssue are not traced
  // above); recompute against an actual tools/list when convenient.
  EXPECTED_TOOL_COUNT = 118;

  CATEGORY_NAMES: array[TDiagnosisCategory] of string = (
    'healthy',
    'loop-down',
    'catalog-drift',
    'read-stale',
    'consent-broken',
    'mutation-failed',
    'harness-not-started',
    'indeterminate'
  );

class function TDiagnostics.CategoryToString(const ACategory: TDiagnosisCategory): string;
begin
  Result := CATEGORY_NAMES[ACategory];
end;

class function TDiagnostics.ExitCodeForDiagnosis(const ACategory: TDiagnosisCategory): Integer;
begin
  if ACategory = dcHealthy then
    Result := 0
  else if ACategory in [dcLoopDown, dcHarnessNotStarted] then
    Result := 3
  else
    Result := 1;
end;

{ TDiagnosisResult }

class function TDiagnosisResult.Create(const ACategory: TDiagnosisCategory;
  const ACause, AFlow: string): TDiagnosisResult;
begin
  Result.Category      := ACategory;
  Result.ProbableCause := ACause;
  Result.SuggestedFlow := AFlow;
end;

{ TDiagnosticSignals — per-category predicates (one decision each; Diagnose
  applies them in precedence order) }

function TDiagnosticSignals.IsHarnessDown: Boolean;
begin
  // The driver erroring out (exit 2) means we never got a trustworthy reading.
  Result := GoLiveExitCode = 2;
end;

function TDiagnosticSignals.IsLoopDown: Boolean;
begin
  // Pipe absent (exit 3) or no answer => the loop is unreachable; downstream
  // signals (catalog, reads) are meaningless until it is back up.
  Result := (not LoopReachable) or (GoLiveExitCode = 3);
end;

function TDiagnosticSignals.IsCatalogDrift: Boolean;
begin
  Result := LoopReachable and (ToolsListCount <> EXPECTED_TOOL_COUNT);
end;

function TDiagnosticSignals.IsReadStale: Boolean;
begin
  Result := ExpectProjectOpen and (not LastReadAvailable);
end;

function TDiagnosticSignals.IsConsentBroken: Boolean;
begin
  Result := GatedCallMade and (LastAuditOutcome = '');
end;

function TDiagnosticSignals.IsMutationFailed: Boolean;
begin
  Result := SameText(LastAuditOutcome, 'error');
end;

// Healthy is a strict positive: each sub-check stays a single concern.

function TDiagnosticSignals.LoopGreen: Boolean;
begin
  Result := LoopReachable
            and (ToolsListCount = EXPECTED_TOOL_COUNT)
            and (GoLiveExitCode = 0);
end;

function TDiagnosticSignals.ContextGreen: Boolean;
begin
  Result := (not ExpectProjectOpen) or LastReadAvailable;
end;

function TDiagnosticSignals.GatesGreen: Boolean;
begin
  Result := L1Ok and L2Ok;
end;

function TDiagnosticSignals.AuditClean: Boolean;
begin
  Result := not SameText(LastAuditOutcome, 'error');
end;

function TDiagnosticSignals.IsHealthy: Boolean;
begin
  Result := LoopGreen and ContextGreen and GatesGreen and AuditClean;
end;

function TDiagnosticSignals.Diagnose: TDiagnosisResult;
begin
  if IsHarnessDown then
    Exit(TDiagnosisResult.Create(dcHarnessNotStarted,
      'driver errored before reaching the loop (mcp-golive exit 2)', 'loop-health'));
  if IsLoopDown then
    Exit(TDiagnosisResult.Create(dcLoopDown,
      'MCP pipe/IDE unreachable (probe absent or exit 3)', 'loop-health'));
  if IsCatalogDrift then
    Exit(TDiagnosisResult.Create(dcCatalogDrift,
      'tools/list count differs from the expected 119 catalog', 'loop-health'));
  if IsReadStale then
    Exit(TDiagnosisResult.Create(dcReadStale,
      'project expected open but a read returned unavailable', 'read-context'));
  if IsConsentBroken then
    Exit(TDiagnosisResult.Create(dcConsentBroken,
      'a gated call was made but no audit line was recorded', 'consent-audit'));
  if IsMutationFailed then
    Exit(TDiagnosisResult.Create(dcMutationFailed,
      'a consented AddUnit mutation reported outcome=error', 'mutation-addunit'));
  if IsHealthy then
    Exit(TDiagnosisResult.Create(dcHealthy,
      'loop reachable, catalog 119, reads live, audit clean', ''));
  Result := TDiagnosisResult.Create(dcIndeterminate,
    'signals match no known healthy or failure shape', 'loop-health');
end;

// --- Signals JSON parsing (additive runner --diagnose input) -------------------

function _ReadBool(const AObj: TJSONObject; const AName: string;
  const ADefault: Boolean): Boolean;
var
  LValue: TJSONValue;
begin
  Result := ADefault;
  LValue := AObj.GetValue(AName);
  if LValue is TJSONBool then
    Result := TJSONBool(LValue).AsBoolean;
end;

function _ReadInt(const AObj: TJSONObject; const AName: string;
  const ADefault: Integer): Integer;
var
  LValue: TJSONValue;
begin
  Result := ADefault;
  LValue := AObj.GetValue(AName);
  if LValue is TJSONNumber then
    Result := TJSONNumber(LValue).AsInt;
end;

function _ReadStr(const AObj: TJSONObject; const AName, ADefault: string): string;
var
  LValue: TJSONValue;
begin
  Result := ADefault;
  LValue := AObj.GetValue(AName);
  if LValue is TJSONString then
    Result := TJSONString(LValue).Value;
end;

class function TDiagnosticSignals.FromJson(
  const AJson: string): TDiagnosticSignals;
var
  LObj: TJSONObject;
begin
  Result := Default(TDiagnosticSignals);
  LObj := TJSONObject.ParseJSONValue(AJson) as TJSONObject;
  if not Assigned(LObj) then
    Exit;
  try
    Result.LoopReachable     := _ReadBool(LObj, 'loopReachable', False);
    Result.ToolsListCount    := _ReadInt(LObj, 'toolsListCount', 0);
    Result.LastReadAvailable := _ReadBool(LObj, 'lastReadAvailable', False);
    Result.LastAuditOutcome  := _ReadStr(LObj, 'lastAuditOutcome', '');
    Result.L1Ok              := _ReadBool(LObj, 'l1Ok', False);
    Result.L2Ok              := _ReadBool(LObj, 'l2Ok', False);
    Result.L5Ok              := _ReadBool(LObj, 'l5Ok', False);
    Result.GoLiveExitCode    := _ReadInt(LObj, 'goLiveExitCode', 0);
    Result.ExpectProjectOpen := _ReadBool(LObj, 'expectProjectOpen', False);
    Result.GatedCallMade     := _ReadBool(LObj, 'gatedCallMade', False);
  finally
    LObj.Free;
  end;
end;

end.
