unit Aefos.Compat.MainThread;

(*
  Deferred main-thread execution (Aefos -> Delphi 10 Seattle).

  TThread.ForceQueue is the RTL method that runs a closure on the main thread
  LATER - always later, even when the caller is already the main thread. Aefos
  depends on that "always" in the gutter-review notifiers: a view or module
  notifier must never unregister itself from inside its own callback, so the save
  paths defer the tidy-up. TThread.Queue is NOT a substitute: called from the main
  thread it runs the closure immediately, which is precisely the reentrancy the
  deferral exists to avoid - and the failure mode is an access violation inside
  the IDE, the exact class of bug this codebase has already paid for once.

  Older IDEs have no ForceQueue, so this unit supplies the same guarantee the way
  it was done before the RTL offered it: post a message to a hidden window and
  run the closure when the message loop gets to it. The current call stack is
  guaranteed to have unwound by then, because a posted message is not dispatched
  until the thread next pumps.

  WHERE THE BOUNDARY SITS, AND WHY IT LEANS THIS WAY: measured absent in 10
  Seattle and in 10.1 Berlin, measured present in Delphi 11. Nobody here has
  10.2/10.3/10.4 to test, so the gate sits at the lowest PROVEN version instead of
  at a guess - meaning those three take the fallback even if their RTL would have
  served. That is the harmless direction: the fallback compiles and behaves
  correctly everywhere, while a gate guessed too low breaks the build outright.
  An earlier guess here said "anything above Seattle"; Berlin disproved it the day
  it was installed.

  A version number is a blunt instrument for this in the first place. The IDEs
  being tested are BASE installs with no update packs, and an RTL addition that
  arrived in an update is invisible to CompilerVersion - which does not move
  between updates. Where the thing being detected is a FILE, prefer measuring it:
  scripts\build-packages.ps1 does exactly that for static SQLite. A method on a
  class has no such handle, which is the only reason this one is still a number.

  Everything here is ours - the Win32 message queue is the platform's, and the
  window/closure plumbing is written for this unit.

  BPL UNLOAD (house rule, non-negotiable): the hidden window's WndProc points
  INTO this package. A window outliving the BPL means the IDE dispatches into an
  unmapped address. Finalization therefore destroys the window and drops any
  closures still queued - see the finalization block, and do not "simplify" it.
*)

interface

type
  TAefosMainThreadProc = reference to procedure;

  { Static namespace for main-thread scheduling. Never instantiated. }
  TAefosMainThread = class sealed
  public
    // Runs AProc on the main thread AFTER the current call stack unwinds -
    // never inline, even when called from the main thread itself.
    class procedure ForceQueue(const AProc: TAefosMainThreadProc); static;
  end;

implementation

uses
  {$IF CompilerVersion >= 35}  // Delphi 11+: the RTL has ForceQueue (see note above)
  System.Classes,
  {$ELSE}
  Winapi.Windows,
  Winapi.Messages,
  // System.Classes, NOT Vcl.Forms: AllocateHWnd lives in Classes, and
  // Aefos.MCP.Core is an RTL-only package that does not require vcl. Pulling
  // Vcl.Forms in here makes the compiler try to absorb it into MCP.Core and the
  // build dies with "Packages 'Aefos.MCP.Core' and 'vcl' both contain unit
  // 'Vcl.Forms'". The layering is deliberate - do not reach for the VCL here.
  System.Classes,
  System.SysUtils,
  System.Generics.Collections,
  {$IFEND}
  System.SyncObjs;

{$IF CompilerVersion >= 35}

class procedure TAefosMainThread.ForceQueue(const AProc: TAefosMainThreadProc);
begin
  // The RTL already guarantees the semantics; just forward.
  TThread.ForceQueue(nil, TThreadProcedure(AProc));
end;

{$ELSE}

const
  // Private to this window - no other code sees this HWND.
  WM_AEFOS_RUN_QUEUED = WM_USER + 4711;

type
  // AllocateHWnd wants a method pointer, not a plain procedure, so the pump owns
  // its handler. One instance, created on first use, destroyed at finalization.
  TAefosQueuePump = class
  public
    procedure WndProc(var AMessage: TMessage);
  end;

var
  GWindow: HWND = 0;
  GPump: TAefosQueuePump = nil;
  GLock: TCriticalSection = nil;
  GPending: TList<TAefosMainThreadProc> = nil;

// Runs one queued closure per message. Failures are swallowed on purpose: this
// is a message handler inside the IDE, and letting an exception escape a WndProc
// is how a plugin takes the host down with it.
procedure TAefosQueuePump.WndProc(var AMessage: TMessage);
var
  LProc: TAefosMainThreadProc;
begin
  if AMessage.Msg <> WM_AEFOS_RUN_QUEUED then
  begin
    AMessage.Result := DefWindowProc(GWindow, AMessage.Msg, AMessage.WParam,
      AMessage.LParam);
    Exit;
  end;

  LProc := nil;
  GLock.Enter;
  try
    if (GPending <> nil) and (GPending.Count > 0) then
    begin
      LProc := GPending[0];
      GPending.Delete(0);
    end;
  finally
    GLock.Leave;
  end;

  if Assigned(LProc) then
    try
      LProc();
    except
      // Deliberately silent - see the comment above.
    end;
end;

class procedure TAefosMainThread.ForceQueue(const AProc: TAefosMainThreadProc);
begin
  if not Assigned(AProc) then
    Exit;
  GLock.Enter;
  try
    if GPending = nil then
      Exit;                         // finalization already ran
    if GWindow = 0 then
    begin
      GPump := TAefosQueuePump.Create;
      GWindow := AllocateHWnd(GPump.WndProc);
    end;
    GPending.Add(AProc);
  finally
    GLock.Leave;
  end;
  // PostMessage, never SendMessage: posting is what makes this deferred. One
  // message per closure keeps the pairing exact.
  PostMessage(GWindow, WM_AEFOS_RUN_QUEUED, 0, 0);
end;

{$IFEND}

initialization
{$IF CompilerVersion < 35}
  GLock := TCriticalSection.Create;
  GPending := TList<TAefosMainThreadProc>.Create;
{$IFEND}

finalization
{$IF CompilerVersion < 35}
  // Order matters. Take the window down FIRST so nothing can be dispatched into
  // this package once the closures are gone, then release the queue. A closure
  // still pending at unload is DROPPED, not run: its captured state belongs to a
  // package that is going away.
  GLock.Enter;
  try
    if GWindow <> 0 then
    begin
      DeallocateHWnd(GWindow);
      GWindow := 0;
    end;
    FreeAndNil(GPump);
    FreeAndNil(GPending);
  finally
    GLock.Leave;
  end;
  FreeAndNil(GLock);
{$IFEND}

end.
