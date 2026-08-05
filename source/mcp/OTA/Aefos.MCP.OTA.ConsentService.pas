unit Aefos.MCP.OTA.ConsentService;

{
  Consent / approval domain, extracted from the TMCPWorkspaceFacade god-object as
  a focused service of the SOLID split (audit S6 / facade split).

  Owns RequestConsent and the consent machinery: the refcounted IConsentSlot /
  TConsentSlot answer carrier, the _IsDestructiveTool gate, the _ShowConsentModal
  helper, and the PROCESS-GLOBAL presenter seam (GGlobalConsentPresenter +
  SetGlobalConsentPresenter / GlobalConsentPresenter) the Chat BPL injects into.

  STATE: the service owns FConsentTimeoutMs and FConsentPresenter (the per-instance
  presenter). The audit log FAudit is INJECTED (not owned) because it is a
  cross-cutting logger the facade also writes from other domains — so the facade
  keeps FAudit and hands it to this service's constructor.

  Bodies moved VERBATIM from the facade (only the class qualifier / field access
  changes), so behaviour is identical. The facade keeps its frozen
  IMCPWorkspaceFacade.RequestConsent + the ConsentPresenter property and forwards
  both to a refcounted FConsent field. The Chat BPL's SetGlobalConsentPresenter
  calls now resolve to this unit (a uses-clause change, same BPL).
}

interface

uses
  Aefos.MCP.Types,
  Aefos.MCP.AuditLog;

type
  IMCPConsentService = interface
    ['{2F6C1A94-8D53-4B70-9E28-3A7C1E5B8D40}']
    function RequestConsent(const AToolName, ASummary,
      ADetail: string): TMCPConsentDecision;
    function GetConsentPresenter: IMCPConsentPresenter;
    procedure SetConsentPresenter(const AValue: IMCPConsentPresenter);
    property ConsentPresenter: IMCPConsentPresenter
      read GetConsentPresenter write SetConsentPresenter;
  end;

// Process-global consent presenter fallback (Dependency Inversion). Set by the
// Chat BPL so that ANY facade instance — regardless of which MCP server/pipe
// answered the request — routes destructive-action consent to the chat's HTML
// modal. When nil, or when the presenter declines (chat panel not ready),
// RequestConsent uses its built-in VCL modal. The Chat BPL must clear it on
// unload (set nil) so the interface ref does not dangle past teardown.
procedure SetGlobalConsentPresenter(const APresenter: IMCPConsentPresenter);
function GlobalConsentPresenter: IMCPConsentPresenter;

// Factory — the facade calls this once in its constructor, injecting the shared
// audit log it still owns.
function NewMCPConsentService(const ATimeoutMs: Cardinal;
  const AAudit: IMCPAuditLog): IMCPConsentService;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Diagnostics,
  Aefos.OTA.Options.AIFlow,
  Aefos.MCP.OTA.ConsentPolicy,
  Aefos.OTA.UI.MCPConsentDialog;

type
  // A refcounted slot the bounded-wait path resolves the modal answer into, so
  // the slot outlives both the worker (which may time out and return) and a
  // late-arriving modal closure that still holds a reference.
  IConsentSlot = interface
    ['{B5F4C1A2-9E3D-4A7C-8B61-2F0D7C5A91E4}']
    function Event: TEvent;
    procedure Resolve(const ADecision: TMCPConsentDecision);
    function Answered: Boolean;
    function Answer: TMCPConsentDecision;
  end;

  TConsentSlot = class(TInterfacedObject, IConsentSlot)
  private
    FEvent: TEvent;
    FLock: TCriticalSection;
    FAnswered: Boolean;
    FAnswer: TMCPConsentDecision;
  public
    constructor Create;
    destructor Destroy; override;
    function Event: TEvent;
    procedure Resolve(const ADecision: TMCPConsentDecision);
    function Answered: Boolean;
    function Answer: TMCPConsentDecision;
  end;

  TMCPConsentService = class(TInterfacedObject, IMCPConsentService)
  private
    // Bounded consent wait (ESP-071 / BR14). 0 = wait indefinitely (D2).
    FConsentTimeoutMs: Cardinal;
    // Per-instance consent presenter (nil = default blocking VCL modal). The Chat
    // BPL injects an HTML/WebView2 presenter (ADR-216). Resolved with the
    // process-global fallback in RequestConsent.
    FConsentPresenter: IMCPConsentPresenter;
    // Cross-cutting audit log INJECTED by the facade (the facade still owns it and
    // writes nav/edit lines from other domains).
    FAudit: IMCPAuditLog;
  public
    constructor Create(const ATimeoutMs: Cardinal; const AAudit: IMCPAuditLog);
    function RequestConsent(const AToolName, ASummary,
      ADetail: string): TMCPConsentDecision;
    function GetConsentPresenter: IMCPConsentPresenter;
    procedure SetConsentPresenter(const AValue: IMCPConsentPresenter);
  end;

var
  // Process-global consent presenter fallback (see interface). Interface ref so
  // it is reference-counted; the Chat BPL clears it (nil) on unload.
  GGlobalConsentPresenter: IMCPConsentPresenter = nil;

procedure SetGlobalConsentPresenter(const APresenter: IMCPConsentPresenter);
begin
  GGlobalConsentPresenter := APresenter;
end;

function GlobalConsentPresenter: IMCPConsentPresenter;
begin
  Result := GGlobalConsentPresenter;
end;

{ ── TConsentSlot — refcounted answer carrier ──────────────────────────── }

constructor TConsentSlot.Create;
begin
  inherited Create;
  FEvent := TEvent.Create(nil, True, False, '');
  FLock := TCriticalSection.Create;
  FAnswered := False;
  FAnswer := cdDenied;
end;

destructor TConsentSlot.Destroy;
begin
  FLock.Free;
  FEvent.Free;
  inherited;
end;

function TConsentSlot.Event: TEvent;
begin
  Result := FEvent;
end;

procedure TConsentSlot.Resolve(const ADecision: TMCPConsentDecision);
begin
  FLock.Enter;
  try
    FAnswer := ADecision;
    FAnswered := True;
  finally
    FLock.Leave;
  end;
  FEvent.SetEvent;
end;

function TConsentSlot.Answered: Boolean;
begin
  FLock.Enter;
  try
    Result := FAnswered;
  finally
    FLock.Leave;
  end;
end;

function TConsentSlot.Answer: TMCPConsentDecision;
begin
  FLock.Enter;
  try
    Result := FAnswer;
  finally
    FLock.Leave;
  end;
end;

function _IsDestructiveTool(const AToolName: string): Boolean;
const
  CDestructive: array[0..12] of string = (
    'DeleteUnit', 'OverwriteFile', 'RemoveUnitFromProject',
    'RemoveProjectFromGroup', 'RemovePackageFromProject', 'RenameProject',
    'RenameDPR', 'RenameUnit', 'MoveUnitToFolder', 'CleanProject',
    'ReplaceInProject', 'SetEditorFullContent', 'CloseAllProjects');
var
  LName: string;
begin
  Result := False;
  for LName in CDestructive do
    if SameText(LName, AToolName) then
      Exit(True);
end;

// Shows the modal on the current thread. Called either from a TThread.Queue
// closure (already on the main thread, bounded path) or inside Synchronize
// (indefinite path). Never raises across the boundary (BR3).
function _ShowConsentModal(const AToolName, ASummary,
  ADetail: string): TMCPConsentDecision;
begin
  try
    Result := TMCPConsentDialog.Execute(AToolName, ASummary, ADetail);
  except
    Result := cdDenied;
  end;
end;

{ ── TMCPConsentService ─────────────────────────────────────────────────── }

constructor TMCPConsentService.Create(const ATimeoutMs: Cardinal;
  const AAudit: IMCPAuditLog);
begin
  inherited Create;
  FConsentTimeoutMs := ATimeoutMs;
  FAudit := AAudit;
end;

function TMCPConsentService.GetConsentPresenter: IMCPConsentPresenter;
begin
  Result := FConsentPresenter;
end;

procedure TMCPConsentService.SetConsentPresenter(
  const AValue: IMCPConsentPresenter);
begin
  FConsentPresenter := AValue;
end;

function TMCPConsentService.RequestConsent(const AToolName,
  ASummary, ADetail: string): TMCPConsentDecision;
var
  LSlot: IConsentSlot;
  LWatch: TStopwatch;
  LAnswered: Boolean;
  LAnswer: TMCPConsentDecision;
  LElapsed: Cardinal;
  LPresenter: IMCPConsentPresenter;
  LDecision: TMCPConsentDecision;
  LConsentMode: Integer;
begin
  // Auto-approve permission mode (Tools->Options->AI Flow). When the user opts in,
  // short-circuit the prompt entirely BEFORE any presenter/modal: mode 2 approves
  // every gated tool; mode 1 approves edits but still prompts for irreversible/
  // destructive structural ops. The action is still recorded in the audit log so
  // an auto-approval is never silent on the record. Mode 0 (default) falls through
  // to the normal prompt.
  LConsentMode := TAIFlowOptions.AgentConsentMode;
  if (LConsentMode >= 2) or
     ((LConsentMode = 1) and not _IsDestructiveTool(AToolName)) then
  begin
    if Assigned(FAudit) then
      FAudit.Append(AToolName, ASummary, 'auto-approved',
        'auto-approve-mode-' + IntToStr(LConsentMode));
    Exit(cdAllowOnce);
  end;
  // Decoupled consent (DIP): delegate to the injected presenter, else the
  // process-global one (set by the Chat BPL). The presenter OWNS its own
  // rendering AND threading (the HTML presenter pumps the message loop itself).
  // If it handles the request we are done; if it declines (False — e.g. the chat
  // panel is not ready) we fall through to the built-in VCL modal below, which
  // owns its own thread model (Synchronize + ShowModal that pumps).
  LPresenter := FConsentPresenter;
  if not Assigned(LPresenter) then
    LPresenter := GGlobalConsentPresenter;
  if Assigned(LPresenter) then
  begin
    LDecision := cdDenied;
    try
      if LPresenter.TryRequestDecision(AToolName, ASummary, ADetail, LDecision) then
        Exit(LDecision);
    except
      // The presenter raised (e.g. the HTML chat surface is unavailable/not
      // ready because the Chat panel is closed and the flow is driven from the
      // external terminal). Do NOT deny here (C1): swallow the fault and fall
      // through to the built-in VCL modal below — the same reachable surface the
      // False-decline path uses — so a terminal user still gets a prompt.
      LDecision := cdDenied;
    end;
  end;
  // Indefinite block (0): preserve the documented D2 behaviour exactly — the
  // worker waits on the main-thread modal via Synchronize with no timeout.
  if FConsentTimeoutMs = 0 then
  begin
    LAnswer := cdDenied;
    try
      TThread.Synchronize(nil, procedure
      begin
        LAnswer := _ShowConsentModal(AToolName, ASummary, ADetail);
      end);
    except
      LAnswer := cdDenied;
    end;
    Exit(LAnswer);
  end;

  // Bounded wait (BR14): queue the modal to the main thread (BR7) and wait at
  // most the configured timeout. The slot is refcounted, so a late modal that
  // resolves after the worker has already timed out cannot touch freed memory.
  LSlot := TConsentSlot.Create;
  try
    TThread.Queue(nil, procedure
    begin
      LSlot.Resolve(_ShowConsentModal(AToolName, ASummary, ADetail));
    end);

    LWatch := TStopwatch.StartNew;
    LSlot.Event.WaitFor(FConsentTimeoutMs);
    LElapsed := Cardinal(LWatch.ElapsedMilliseconds);

    LAnswered := LSlot.Answered;
    LAnswer := LSlot.Answer;
  except
    LAnswered := False;
    LAnswer := cdDenied;
    LElapsed := FConsentTimeoutMs + 1;
  end;

  Result := TConsentPolicy.ResolveTimedConsent(LAnswered, LAnswer, LElapsed, FConsentTimeoutMs);

  // Record the timeout as an additive outcome value (ADR-070-04). Core also
  // audits its own 'denied' line for the returned cdDenied; this consumer-side
  // line distinguishes the unanswered-timeout cause (BR14).
  if not LAnswered then
    FAudit.Append(AToolName, ASummary, 'timeout', 'timeout-denied');
end;

function NewMCPConsentService(const ATimeoutMs: Cardinal;
  const AAudit: IMCPAuditLog): IMCPConsentService;
begin
  Result := TMCPConsentService.Create(ATimeoutMs, AAudit);
end;

end.
