unit Aefos.OTA.Chat.Adapter.DebuggerNotifier;

{
  Debugger notifier adapter — restores the chat dock after a Run/Debug round-trip.

  THE PROBLEM (see [[project-dock-layout-persistence]]):
  The chat dock deliberately does NOT call RegisterFieldAddress /
  RegisterDesktopFormClass (see ChatPanel.RegisterChatPanel) because that
  desktop-persistence pair, in an unloadable design-time BPL, leaves a dangling
  class pointer in the IDE's desktop manager -> the unload AV the maintainer
  fought for days. The price: when the IDE switches Default Layout -> Debug
  Layout (on Run) -> back to Default Layout (on Stop), the desktop manager drops
  our (unregistered) dock and never recreates it, so the chat vanishes and does
  not return.

  PATH B (no IDE desktop-persistence registration -> no unload-AV risk):
  watch the debugger ourselves. On ProcessCreated (debug start) remember whether
  the chat was open; on ProcessDestroyed (debug end -> the IDE returns to the
  Default layout) re-show it — DEFERRED off the IDE callback via
  TThread.ForceQueue, so the re-show runs AFTER the layout finishes loading and
  never re-enters the IDE mid-notification.

  ===========================================================================
  UNLOAD CONTRACT COMPLIANCE — read Aefos.OTA.Chat.UnloadContract (THE LAW)
  before touching this. This adapter registers an IOTADebuggerNotifier, which
  the IDE HOLDS. Per Rule 2, an IDE-held reference must not point into this BPL
  after finalization:
    - the notifier is removed by its STORED INDEX at teardown, guarded by
      Supports + try/except, and is idempotent (mirrors Adapter.IDENotifier);
    - the injected cross-BPL handlers (GIsVisible / GReshow) are nil'd in
      UnregisterNotifier AND in finalization (Rule 2: nil cross-BPL globals);
    - teardown is routed through Register._GuardedShutdown (Rule 4).
  The deferred dispatch uses the SAME TThread.ForceQueue(captured-handler)
  pattern already blessed in Adapter.IDENotifier._DispatchReResolve.
  ===========================================================================
}

interface

uses
  System.SysUtils;

type
  // Sealed static namespace for the debugger-notifier composition-root entry
  // points (were loose interface routines). Never instantiated. Bodies, the
  // GNotifierIndex/GIsVisible/GReshow/GWasVisible module vars and the guarded
  // RemoveNotifier teardown are byte-frozen (UnloadContract); Register.pas call
  // sites change by class qualification only.
  TAefosDebuggerNotifierAdapter = class sealed
  public
    // Registers the IOTADebuggerNotifier (idempotent). Call from the composition
    // root at chat init, AFTER RegisterChatReshowHandlers so a process event that
    // fires immediately already has its handlers.
    class procedure RegisterSelf; static;

    // Injects the chat hooks the notifier drives (kept decoupled from the UI,
    // like Adapter.IDENotifier's re-resolve handler): AIsVisible answers "is the
    // chat dock currently open?"; AReshow brings it back (ShowDockableForm).
    // Both run on the main thread.
    class procedure RegisterChatReshowHandlers(const AIsVisible: TFunc<Boolean>;
      const AReshow: TProc); static;

    // Removes the notifier by stored index (guarded, idempotent) and nils the
    // injected handlers. THE LAW — pair every AddNotifier with this at teardown.
    class procedure UnregisterNotifier; static;
  end;

implementation

uses
  System.Classes,
  Winapi.Windows,
  ToolsAPI;

type
  // TNotifierObject supplies the empty IOTANotifier members; only the four
  // IOTADebuggerNotifier methods are implemented (AddNotifier takes the base
  // IOTADebuggerNotifier, so implementing it is sufficient across D13).
  TAefosDebuggerNotifier = class(TNotifierObject, IOTANotifier,
    IOTADebuggerNotifier)
  public
    procedure BreakpointAdded(const Breakpoint: IOTABreakpoint);
    procedure BreakpointDeleted(const Breakpoint: IOTABreakpoint);
    procedure ProcessCreated(const Process: IOTAProcess);
    procedure ProcessDestroyed(const Process: IOTAProcess);
  end;

const
  // Sentinel for "no notifier registered" — AddNotifier never returns it.
  NOT_REGISTERED = -1;

var
  GNotifierIndex: Integer = NOT_REGISTERED;
  GIsVisible: TFunc<Boolean> = nil;
  GReshow: TProc = nil;
  // Whether the chat dock was open when the debug session started — the gate
  // for re-showing it when the session ends.
  GWasVisible: Boolean = False;

procedure TAefosDebuggerNotifier.ProcessCreated(const Process: IOTAProcess);
begin
  // Debug session starting -> the IDE is about to switch to the Debug desktop
  // layout, which hides our (intentionally non-desktop-persisted) dock. Capture
  // whether the user had it open. Exception-isolated: never disturb the IDE.
  try
    if Assigned(GIsVisible) then
      GWasVisible := GIsVisible();
  except
    on E: Exception do
      OutputDebugString(PChar(
        '[Aefos] DebuggerNotifier.ProcessCreated: ' + E.Message));
  end;
end;

procedure TAefosDebuggerNotifier.ProcessDestroyed(const Process: IOTAProcess);
var
  LReshow: TProc;
begin
  // Debug session ended -> the IDE returns to the Default layout and drops our
  // dock. If the user had it open, bring it back — but DEFERRED off this IDE
  // callback (TThread.ForceQueue), so it runs AFTER the layout finishes loading
  // (else the layout load clobbers the re-show) and never re-enters the IDE
  // mid-notification (the ADR-258/259 inline-rebuild hazard).
  if not GWasVisible then
    Exit;
  GWasVisible := False;
  LReshow := GReshow; // local copy; the queued closure must not read the global
  if not Assigned(LReshow) then
    Exit;
  TThread.ForceQueue(nil,
    procedure
    begin
      try
        LReshow();
      except
        on E: Exception do
          OutputDebugString(PChar(
            '[Aefos] DebuggerNotifier reshow: ' + E.Message));
      end;
    end);
end;

procedure TAefosDebuggerNotifier.BreakpointAdded(
  const Breakpoint: IOTABreakpoint);
begin
  // No-op: Aefos does not react to breakpoints.
end;

procedure TAefosDebuggerNotifier.BreakpointDeleted(
  const Breakpoint: IOTABreakpoint);
begin
  // No-op.
end;

class procedure TAefosDebuggerNotifierAdapter.RegisterSelf;
var
  LDebugger: IOTADebuggerServices;
begin
  // Idempotent — a second call with no intervening unregister is ignored.
  if GNotifierIndex <> NOT_REGISTERED then
    Exit;
  if Supports(BorlandIDEServices, IOTADebuggerServices, LDebugger) then
    GNotifierIndex := LDebugger.AddNotifier(TAefosDebuggerNotifier.Create);
end;

class procedure TAefosDebuggerNotifierAdapter.RegisterChatReshowHandlers(
  const AIsVisible: TFunc<Boolean>; const AReshow: TProc);
begin
  GIsVisible := AIsVisible;
  GReshow := AReshow;
end;

class procedure TAefosDebuggerNotifierAdapter.UnregisterNotifier;
var
  LDebugger: IOTADebuggerServices;
begin
  // THE LAW (UnloadContract Rule 2): remove the IDE-held notifier by its stored
  // index, guarded; the IDE does NOT reliably drop a package's debugger
  // notifier before the BPL unmaps -> a dead-VMT read = the chronic unload AV.
  if GNotifierIndex <> NOT_REGISTERED then
  begin
    if Supports(BorlandIDEServices, IOTADebuggerServices, LDebugger) then
      try
        LDebugger.RemoveNotifier(GNotifierIndex);
      except
        on E: Exception do
          OutputDebugString(PChar(
            '[Aefos] DebuggerNotifier RemoveNotifier: ' + E.Message));
      end;
    GNotifierIndex := NOT_REGISTERED;
  end;
  // Rule 2: nil the cross-BPL handler globals so nothing points back into us.
  GIsVisible := nil;
  GReshow := nil;
  GWasVisible := False;
end;

initialization

finalization
  // Belt-and-suspenders (the real teardown is Register._GuardedShutdown):
  // never leave handler closures pointing into this BPL after unmap.
  GIsVisible := nil;
  GReshow := nil;

end.
