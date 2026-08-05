unit Aefos.MCP.OTA.ConsentPolicy;

{
  Bounded consent-wait decision seam (ESP-071, S1 / ADR-071-01 / BR14).

  Pure RTL — no ToolsAPI, no VCL, no wall-clock. The MCP worker thread shows
  the consent modal on the IDE main thread (BR7) but waits at most a configured
  timeout for the answer. This unit owns the decision rule that maps an answered
  / timed-out prompt to a TMCPConsentDecision, so the headless runner can prove
  the rule without a live IDE. The wait/marshal wiring lives in the UI facade
  (Aefos.MCP.OTA.WorkspaceFacade) and is the only OTA-bound,
  structurally-exempt part.

  Rule (BR14):
    - ATimeoutMs = 0  -> indefinite block (the documented D2 behaviour): the
      wait never expires, so the operator's answer is always honoured.
    - answered at or before the deadline -> the operator's decision stands.
    - unanswered, or answered after the deadline -> cdDenied (safe default).

  The elapsed/timeout pair is injected by the caller, keeping the function
  deterministic and clock-free for unit tests (boundary at exactly the timeout).
}

interface

uses
  Aefos.MCP.Types;

const
  // Generous finite default (ESP-071 R2): long enough for an operator who is
  // simply thinking, short enough that an abandoned prompt cannot stall the
  // loop forever. Override on Tools->Options->Aefos->Terminal; 0 = wait
  // indefinitely (the documented D2 block).
  MCP_DEFAULT_CONSENT_TIMEOUT_SECS = 120;

type
  // Bounded consent-wait decision seam as a sealed static namespace
  // (see the unit header for the ESP-071 / ADR-071 contract). Never instantiated.
  TConsentPolicy = class sealed
  public
    // Maps an answered/timed-out consent prompt to the effective decision (BR14).
    class function ResolveTimedConsent(const AAnswered: Boolean;
      const AAnswer: TMCPConsentDecision;
      const AElapsedMs, ATimeoutMs: Cardinal): TMCPConsentDecision; static;
  end;

implementation

class function TConsentPolicy.ResolveTimedConsent(const AAnswered: Boolean;
  const AAnswer: TMCPConsentDecision;
  const AElapsedMs, ATimeoutMs: Cardinal): TMCPConsentDecision;
begin
  // 0/blank timeout reproduces the documented D2 indefinite-block behaviour:
  // the wait does not expire, so the answered decision is preserved as-is.
  if ATimeoutMs = 0 then
    Exit(AAnswer);
  // The operator answered within the bounded wait (boundary inclusive).
  if AAnswered and (AElapsedMs <= ATimeoutMs) then
    Exit(AAnswer);
  // Unanswered or answered after the deadline -> safe-default Deny (BR12/BR14).
  Result := cdDenied;
end;

end.
