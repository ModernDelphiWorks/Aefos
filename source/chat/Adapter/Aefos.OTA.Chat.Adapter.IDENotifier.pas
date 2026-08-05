unit Aefos.OTA.Chat.Adapter.IDENotifier;

{
  IDE notifier adapter — registers the OTA plugin with the RAD Studio IDE.
  Pattern sourced from Delphi-AI-Developer reference (TNotifierObject + BorlandIDEServices).

  Per ADR-083 dispatches ofnActiveProjectChanged to a unit-level handler
  (registered via RegisterExecutorReResolveHandler, cleared by
  UnregisterNotifier) which drives the deferred / runtime executor-graph
  re-resolution in the composition root; no exception escapes the callback.

  ADR-001 (2026-05-05): the bridge-client plumbing (FBridgeClient,
  _InitBridge, _ShutdownBridge) was removed when the named-pipe transport to
  the deprecated Rust CLI was dropped.

  ADR-103 (2026-05-20, Epic 6/7 Demand 2/5): the project-index handler hook
  (RegisterProjectIndexHandler / UnregisterProjectIndexHandler /
  GProjectIndexHandler) and the ofnFileOpened / ofnFileClosing dispatch arms
  were removed when the ProjectIndex* and Symbol* module families were
  dropped. The ofnActiveProjectChanged path stays verbatim.

  ADR-258/259 (2026-06-02, Epic 3/3 Demand 1/3): the notifier was reduced to a
  no-op under ADR-082 because running the full executor-graph teardown/rebuild
  synchronously inside FileNotification re-entered the mid-notification IDE and
  corrupted the compile cache. It is now re-enabled SAFELY: a real
  IOTAIDENotifier is registered via (BorlandIDEServices as IOTAServices)
  .AddNotifier; FileNotification acts only on ofnActiveProjectChanged and posts
  the registered re-resolve handler DEFERRED onto the main-thread queue
  (TThread.ForceQueue) — never inline — so the heavy rebuild runs after the IDE
  finishes its notification. The deferred proc is exception-isolated; no
  exception escapes the IDE callback. UnregisterNotifier removes the notifier
  via its stored index and is idempotent.
}

interface

uses
  System.SysUtils;

type
  // Sealed static namespace for the IDE-notifier composition-root entry points
  // (were loose interface routines). Never instantiated. Bodies, the
  // GExecutorReResolveHandler/GNotifierIndex module vars and the guarded
  // RemoveNotifier teardown are byte-frozen (UnloadContract); Register.pas call
  // sites change by class qualification only.
  TAefosIDENotifierAdapter = class sealed
  public
    class procedure RegisterSelf; static;
    class procedure RegisterExecutorReResolveHandler(const AHandler: TProc); static;
    class procedure UnregisterNotifier; static;
  end;

implementation

uses
  System.Classes,
  Winapi.Windows,
  ToolsAPI;

type
  // ADR-258/259: the real IDE notifier. TNotifierObject supplies the empty
  // IOTANotifier members; only the IOTAIDENotifier methods are implemented.
  // FileNotification is the sole active arm (ofnActiveProjectChanged); the
  // compile hooks stay no-ops (ADR-103).
  TAefosIDENotifier = class(TNotifierObject, IOTANotifier, IOTAIDENotifier)
  public
    // IOTAIDENotifier
    procedure FileNotification(NotifyCode: TOTAFileNotification;
      const FileName: string; var Cancel: Boolean);
    procedure BeforeCompile(const Project: IOTAProject; var Cancel: Boolean);
    procedure AfterCompile(Succeeded: Boolean);
  end;

const
  // Sentinel for "no notifier registered" — AddNotifier never returns it.
  NOT_REGISTERED = -1;

var
  GExecutorReResolveHandler: TProc = nil;
  GNotifierIndex: Integer = NOT_REGISTERED;

procedure _DispatchReResolve;
var
  LHandler: TProc;
begin
  LHandler := GExecutorReResolveHandler;
  if not Assigned(LHandler) then
    Exit;
  // BR-2 / BR-3: run the re-resolve AFTER the IDE callback returns, on the main
  // thread (where menu/panel mutation is safe), and never let an exception
  // escape back into the IDE notification path.
  TThread.ForceQueue(nil,
    procedure
    begin
      try
        LHandler();
      except
        on E: Exception do
          OutputDebugString(PChar(
            'Aefos._DispatchReResolve failed: ' + E.Message));
      end;
    end);
end;

procedure TAefosIDENotifier.FileNotification(
  NotifyCode: TOTAFileNotification; const FileName: string; var Cancel: Boolean);
begin
  // ADR-259: act ONLY on the active-project change; never set Cancel; no other
  // dispatch arms (ADR-103 stays removed). The actual re-resolve is deferred
  // off this callback by _DispatchReResolve (BR-2).
  if NotifyCode = ofnActiveProjectChanged then
    _DispatchReResolve;
end;

procedure TAefosIDENotifier.BeforeCompile(const Project: IOTAProject;
  var Cancel: Boolean);
begin
  // No-op (ADR-103): Aefos does not gate compilation.
end;

procedure TAefosIDENotifier.AfterCompile(Succeeded: Boolean);
begin
  // No-op (ADR-103): Aefos does not react to compile completion.
end;

class procedure TAefosIDENotifierAdapter.RegisterSelf;
var
  LServices: IOTAServices;
begin
  // ADR-258: re-enable the real IOTAIDENotifier (was a no-op since ADR-082).
  // Idempotent — a second call with no intervening unregister is ignored.
  if GNotifierIndex <> NOT_REGISTERED then
    Exit;
  if Supports(BorlandIDEServices, IOTAServices, LServices) then
    GNotifierIndex := LServices.AddNotifier(TAefosIDENotifier.Create);
end;

class procedure TAefosIDENotifierAdapter.UnregisterNotifier;
var
  LServices: IOTAServices;
begin
  // BR-5: remove the registered notifier via its stored index; idempotent and
  // safe when nothing was registered.
  if GNotifierIndex <> NOT_REGISTERED then
  begin
    if Supports(BorlandIDEServices, IOTAServices, LServices) then
      LServices.RemoveNotifier(GNotifierIndex);
    GNotifierIndex := NOT_REGISTERED;
  end;
  GExecutorReResolveHandler := nil;
end;

class procedure TAefosIDENotifierAdapter.RegisterExecutorReResolveHandler(const AHandler: TProc);
begin
  GExecutorReResolveHandler := AHandler;
end;

initialization

finalization
  GExecutorReResolveHandler := nil;

end.
