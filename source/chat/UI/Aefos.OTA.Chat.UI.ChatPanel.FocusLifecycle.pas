unit Aefos.OTA.Chat.UI.ChatPanel.FocusLifecycle;

{
  Plain-VCL focus/dock lifecycle seam extracted from TAefosChatPanel
  (ADR-219). It owns the focus-restoration logic that used to live inside the
  OTA-coupled TDockableForm subclass: the SetParent-driven focus restore, the
  queued/direct focus dispatch, the shutdown/validity guards, and the
  queued-event drain.

  No `uses ToolsAPI`, `DockForm`, or any OTA service — only RTL + plain VCL
  (TWinControl / TCustomForm). It therefore links into a console/VCL EXE with
  no F2613 (ADR-115 / project_toolsapi_exe_constraint), which is what makes the
  dock Access Violation reproducible in a standalone repro and regression-tested in
  the console test runner.

  Validity invariant (ADR-220 / BR-1): no deferred or queued focus operation may
  dereference the panel after it has been unparented or entered csDestroying.
  The mechanism is a monotonic generation token:

    * every re-parent (SetParent) and every teardown transition bumps the
      generation (Invalidate);
    * a focus op captures the generation at schedule time and is a no-op at
      execution time if the generation has since advanced — i.e. a handle being
      recreated mid-dock, or a panel torn down, can no longer be touched by a
      focus op that was scheduled before the transition;
    * the ManualFloat/teardown path drains the single coalesced queued event
      (RemoveQueuedEvents) AND advances the generation, so both the deferred
      (TThread.Queue) and the direct (WM_SETFOCUS) paths are covered.

  Genuine activation still restores focus (BR-3): a fresh schedule captures the
  current generation, so it runs.
}

interface

uses
  System.Classes,
  Vcl.Controls;

type
  // Owns the focus/dock lifecycle for a single host control (the chat panel).
  // Created by TAefosChatPanel with the panel as AHost; SetTarget wires
  // the input control that should receive focus.
  TChatPanelFocusLifecycle = class
  private
    FHost: TWinControl;
    FTarget: TWinControl;
    FGeneration: Cardinal;
    FPendingToken: Cardinal;
    FShuttingDown: Boolean;
    FRestoreCount: Cardinal;
    procedure _OnQueuedRestore;
    procedure _ApplyFocus;
  public
    constructor Create(const AHost: TWinControl);

    procedure SetTarget(const ATarget: TWinControl);

    // --- Production lifecycle hooks (called by TAefosChatPanel) --------

    // Call from the host's SetParent override. Advances the generation (so any
    // op queued before this re-parent is invalidated) and, when re-parented to
    // a real parent, schedules a fresh focus restore.
    procedure HandleSetParent(const AParent: TWinControl);

    // Deferred focus restore (TThread.Queue path) — WM_SETFOCUS / CM_ACTIVATE /
    // WM_MOUSEACTIVATE. Coalesces to a single pending event.
    procedure ScheduleRestore;

    // Synchronous/direct focus restore. Guarded by the same invariant; a no-op
    // during shutdown or while the host/target is destroying.
    procedure RestoreNow;

    // Teardown: mark shutting down and drain any pending queued op. Call before
    // ManualFloat and before freeing the seam.
    procedure BeginShutdown;

    // Cancel pending queued ops and advance the generation (without entering the
    // shutting-down state). Used around the ManualFloat re-parent.
    procedure Drain;

    // --- Validity-invariant primitives (drivable without a message loop) -----

    // The current generation. A scheduler captures this and passes it back to
    // RestoreWithToken / ShouldRestore.
    function CaptureToken: Cardinal;

    // Advance the generation: any token captured before now becomes stale.
    procedure Invalidate;

    // The invariant: True iff a focus op carrying AToken may safely run now.
    function ShouldRestore(const AToken: Cardinal): Boolean;

    // Run the focus restore iff ShouldRestore(AToken); otherwise a no-op.
    procedure RestoreWithToken(const AToken: Cardinal);

    property Generation: Cardinal read FGeneration;
    // Number of times the invariant permitted a restore (diagnostics/tests).
    property RestoreCount: Cardinal read FRestoreCount;
    property ShuttingDown: Boolean read FShuttingDown;
    property Host: TWinControl read FHost;
    property Target: TWinControl read FTarget;
  end;

implementation

uses
  Winapi.Windows,
  Vcl.Forms;

{ TChatPanelFocusLifecycle }

constructor TChatPanelFocusLifecycle.Create(const AHost: TWinControl);
begin
  inherited Create;
  FHost := AHost;
  // Start at 1 so the sentinel token 0 is never treated as a live generation.
  FGeneration := 1;
end;

procedure TChatPanelFocusLifecycle.SetTarget(const ATarget: TWinControl);
begin
  FTarget := ATarget;
end;

function TChatPanelFocusLifecycle.CaptureToken: Cardinal;
begin
  Result := FGeneration;
end;

procedure TChatPanelFocusLifecycle.Invalidate;
begin
  Inc(FGeneration);
end;

function TChatPanelFocusLifecycle.ShouldRestore(const AToken: Cardinal): Boolean;
begin
  // Stale (a re-parent/teardown happened since the op was scheduled), shutting
  // down, or the host/target is gone or being destroyed → never touch state.
  Result := (not FShuttingDown)
    and (AToken = FGeneration)
    and Assigned(FHost)
    and (not (csDestroying in FHost.ComponentState))
    and Assigned(FTarget)
    and (not (csDestroying in FTarget.ComponentState));
end;

procedure TChatPanelFocusLifecycle.RestoreWithToken(const AToken: Cardinal);
begin
  if not ShouldRestore(AToken) then
    Exit;
  Inc(FRestoreCount);
  _ApplyFocus;
end;

procedure TChatPanelFocusLifecycle._ApplyFocus;
var
  LParentForm: TCustomForm;
begin
  if not Assigned(FTarget) then
    Exit;
  // Guard before touching .Handle so a stale/uncreated control is never forced
  // to allocate a window here.
  if not FTarget.HandleAllocated then
    Exit;
  if not FTarget.CanFocus then
    Exit;
  try
    // Win32 SetFocus directly: bypasses VCL dock-host interception that
    // overrides TWinControl.SetFocus before it returns.
    Winapi.Windows.SetFocus(FTarget.Handle);
    if Assigned(FHost) then
    begin
      LParentForm := GetParentForm(FHost);
      if Assigned(LParentForm)
        and (not (csDestroying in LParentForm.ComponentState)) then
        LParentForm.ActiveControl := FTarget;
    end;
    // Force a repaint so caret and buffered text appear immediately.
    RedrawWindow(FTarget.Handle, nil, 0,
      RDW_INVALIDATE or RDW_UPDATENOW or RDW_ERASE);
  except
    // Never propagate exceptions from focus restoration.
  end;
end;

procedure TChatPanelFocusLifecycle._OnQueuedRestore;
begin
  RestoreWithToken(FPendingToken);
end;

procedure TChatPanelFocusLifecycle.ScheduleRestore;
begin
  if FShuttingDown then
    Exit;
  // Coalesce: keep at most one pending event so stacked re-parents do not pile
  // up focus ops. _OnQueuedRestore is a bound method, so it is drainable via
  // RemoveQueuedEvents (anonymous closures are not).
  TThread.RemoveQueuedEvents(_OnQueuedRestore);
  FPendingToken := FGeneration;
  TThread.Queue(nil, _OnQueuedRestore);
end;

procedure TChatPanelFocusLifecycle.HandleSetParent(const AParent: TWinControl);
begin
  // Every re-parent invalidates any op scheduled before it (the mid-dock,
  // handle-recreate AV). Only a re-parent to a real parent schedules a fresh
  // restore — undock-to-float leaves focus to WM_SETFOCUS/CM_ACTIVATE.
  Invalidate;
  if FShuttingDown then
    Exit;
  if Assigned(AParent) then
    ScheduleRestore;
end;

procedure TChatPanelFocusLifecycle.RestoreNow;
begin
  // Synchronous path: reflects the current state, so it carries the current
  // generation; the shutdown/destroying guards still apply.
  RestoreWithToken(FGeneration);
end;

procedure TChatPanelFocusLifecycle.Drain;
begin
  Invalidate;
  TThread.RemoveQueuedEvents(_OnQueuedRestore);
end;

procedure TChatPanelFocusLifecycle.BeginShutdown;
begin
  FShuttingDown := True;
  Drain;
end;

end.
