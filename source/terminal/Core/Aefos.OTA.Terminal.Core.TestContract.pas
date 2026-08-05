unit Aefos.OTA.Terminal.Core.TestContract;

/// <summary>
/// Pure contract unit for machine-readable test results (delphi-test/1).
/// Dependencies: RTL + System.JSON only — no VCL, no ToolsAPI (BR1, ADR-066-02).
/// Never calls Now/Random; all values are caller-supplied (BR8).
/// </summary>

interface

const
  /// <summary>Frozen schema identifier. Bump to 'delphi-test/2' on any breaking change (ADR-066-03).</summary>
  DELPHI_TEST_SCHEMA = 'delphi-test/1';

type
  /// <summary>
  /// Deterministic exit-code taxonomy.
  /// Single source of truth for 0/1/2/3 mapping (BR3, ADR-066-03).
  /// </summary>
  TTestExitCause = (
    tecAllPassed,           { 0: every test passed }
    tecTestFailure,         { 1: at least one test failed or errored }
    tecBuildFailure,        { 2: build could not produce the test binary }
    tecHarnessNotStarted    { 3: test harness could not start }
  );

  /// <summary>Per-failure entry in the failures[] array of the contract document.</summary>
  TTestFailureEntry = record
    Id: string;
    Expected: string;
    Actual: string;
    Evidence: string;
  end;

  /// <summary>Summary block: total, passed, failed, skipped counts.</summary>
  TTestSummary = record
    Total: Integer;
    Passed: Integer;
    Failed: Integer;
    Skipped: Integer;
    /// <summary>
    /// Build a summary from its parts, deriving Total = Passed + Failed +
    /// Skipped so the count can never drift from the parts. This is the one
    /// authoritative constructor for a delphi-test/1 summary.
    /// </summary>
    class function Create(const APassed, AFailed,
      ASkipped: Integer): TTestSummary; static;
  end;

  /// <summary>
  /// Additive optional diagnosis block (ESP-074, layer "L6-diagnose"). Emitted as
  /// the top-level "diagnosis" object only when Category is non-empty, so every
  /// existing L1/L2/L4/L5 document stays byte-identical (ADR-074-01, additive only).
  /// </summary>
  TTestDiagnosis = record
    Category: string;
    ProbableCause: string;
    SuggestedFlow: string;
  end;

  /// <summary>Root document record for the delphi-test/1 schema (ADR-066-03).</summary>
  TTestContractDoc = record
    Schema: string;
    Layer: string;
    Package: string;
    AllPassed: Boolean;
    Summary: TTestSummary;
    Failures: TArray<TTestFailureEntry>;
    Artifacts: TArray<string>;
    /// <summary>Optional probe mode ("link-probe" or "loadpackage"). Included in JSON only when non-empty.</summary>
    Mode: string;
    /// <summary>Optional L6 diagnosis. Emitted only when Category is non-empty (ADR-074-01).</summary>
    Diagnosis: TTestDiagnosis;
    /// <summary>Serialise this document to canonical delphi-test/1 JSON.</summary>
    function ToJson: string;
  end;

  /// <summary>
  /// Canonical delphi-test/1 serialiser + exit-code taxonomy. Static-only
  /// sealed class — the single writer of the contract JSON (BR3).
  /// </summary>
  TTestContractBuilder = class sealed
  public
    /// <summary>
    /// Serialise ADoc to a canonical delphi-test/1 JSON string.
    /// Caller populates all fields including run-id (clock-free, BR8).
    /// </summary>
    class function BuildContractJson(const ADoc: TTestContractDoc): string; static;

    /// <summary>Map ACause to the deterministic integer exit code 0/1/2/3 (BR3).</summary>
    class function ExitCodeFor(const ACause: TTestExitCause): Integer; static;
  end;

implementation

uses
  System.JSON;

{ TTestSummary }

class function TTestSummary.Create(const APassed, AFailed,
  ASkipped: Integer): TTestSummary;
begin
  Result.Passed  := APassed;
  Result.Failed  := AFailed;
  Result.Skipped := ASkipped;
  Result.Total   := APassed + AFailed + ASkipped;
end;

{ TTestContractDoc }

function TTestContractDoc.ToJson: string;
begin
  Result := TTestContractBuilder.BuildContractJson(Self);
end;

class function TTestContractBuilder.BuildContractJson(const ADoc: TTestContractDoc): string;
var
  LRoot: TJSONObject;
  LSummary: TJSONObject;
  LDiagnosis: TJSONObject;
  LFailures: TJSONArray;
  LEntry: TJSONObject;
  LArtifacts: TJSONArray;
  LItem: TTestFailureEntry;
  LIndex: Integer;
begin
  LRoot := TJSONObject.Create;
  try
    LRoot.AddPair('schema', ADoc.Schema);
    LRoot.AddPair('layer', ADoc.Layer);
    LRoot.AddPair('package', ADoc.Package);
    LRoot.AddPair('ok', TJSONBool.Create(ADoc.AllPassed));

    LSummary := TJSONObject.Create;
    LSummary.AddPair('total', TJSONNumber.Create(ADoc.Summary.Total));
    LSummary.AddPair('passed', TJSONNumber.Create(ADoc.Summary.Passed));
    LSummary.AddPair('failed', TJSONNumber.Create(ADoc.Summary.Failed));
    LSummary.AddPair('skipped', TJSONNumber.Create(ADoc.Summary.Skipped));
    LRoot.AddPair('summary', LSummary);

    LFailures := TJSONArray.Create;
    for LItem in ADoc.Failures do
    begin
      LEntry := TJSONObject.Create;
      LEntry.AddPair('id', LItem.Id);
      LEntry.AddPair('expected', LItem.Expected);
      LEntry.AddPair('actual', LItem.Actual);
      LEntry.AddPair('evidence', LItem.Evidence);
      LFailures.Add(LEntry);
    end;
    LRoot.AddPair('failures', LFailures);

    LArtifacts := TJSONArray.Create;
    for LIndex := 0 to High(ADoc.Artifacts) do
      LArtifacts.Add(ADoc.Artifacts[LIndex]);
    LRoot.AddPair('artifacts', LArtifacts);

    if ADoc.Mode <> '' then
      LRoot.AddPair('mode', ADoc.Mode);

    if ADoc.Diagnosis.Category <> '' then
    begin
      LDiagnosis := TJSONObject.Create;
      LDiagnosis.AddPair('category', ADoc.Diagnosis.Category);
      LDiagnosis.AddPair('probableCause', ADoc.Diagnosis.ProbableCause);
      LDiagnosis.AddPair('suggestedFlow', ADoc.Diagnosis.SuggestedFlow);
      LRoot.AddPair('diagnosis', LDiagnosis);
    end;

    Result := LRoot.Format(2);
  finally
    LRoot.Free;
  end;
end;

class function TTestContractBuilder.ExitCodeFor(const ACause: TTestExitCause): Integer;
begin
  case ACause of
    tecAllPassed:         Result := 0;
    tecTestFailure:       Result := 1;
    tecBuildFailure:      Result := 2;
    tecHarnessNotStarted: Result := 3;
  else
    Result := 1;
  end;
end;

end.


