unit Aefos.Lazarus.IdeSilence;

{ Aefos AI - Lazarus edition: keep IDE modals off the MCP pipe, AT RUNTIME.

  WHY THIS UNIT EXISTS
  --------------------
  Every Lazarus modal is pumped by the IDE MAIN THREAD - the same thread the
  in-process MCP host runs its tool calls on (Aefos.Lazarus.McpHost._Marshal ->
  TThread.Synchronize). While a modal is up the pipe does not answer, so an agent
  with no human in front of the IDE keeps firing tools into a frozen pipe: a
  deadlock that only a click can end.

  Until 2026-07-27 this was solved by the INSTALLER, which rewrote three keys in
  the user's environmentoptions.xml (DebuggerOptions/ShowStopMessage=False,
  DebuggerOptions/DebuggerShowExitCodeMessage=False and
  EnvironmentOptions/CheckDiskChangesWithLoading=True). That broke the owner's
  hard rule - an install may only ADD to the IDE's XML, never ALTER a value the
  user owns - and it also billed OUR convenience to the human forever: after
  uninstalling Aefos his debugger still would not tell him a program had stopped.

  So the protection moved HERE, where it belongs: our package is linked into the
  IDE, so it can neutralize the modal for the exact window in which the pipe is at
  risk, and leave the user's preferences untouched and unread. Nothing in this
  unit writes configuration.

  WHAT IT DOES
  ------------
  1. DEBUGGER "Execution stopped" / exit-code boxes (ide\debugmanager.pas:1580-1602)
     Both are guarded by `if not FDebugger.SkipStopMessage`. SkipStopMessage is the
     IDE'S OWN one-shot opt-out (dbgintfdebuggerbase.pp:1763 SetSkipStopMessage,
     public; cleared again by TDebuggerIntf.SetState on any transition that is not
     dsStop, :5994). We register a debugger state-change handler
     (basedebugmanager.pas:226 RegisterStateChangeHandler); TDebugManager runs the
     whole notification list at debugmanager.pas:1479 - BEFORE the dsStop dialog
     block at :1574 - so a handler that calls SetSkipStopMessage there suppresses
     BOTH boxes for that stop and only that stop.
     It fires ONLY for a run Aefos itself dispatched (ArmDebuggerStopSilence, called
     by the RunProject / StopProject / DebugContinue tool paths). A run the DEVELOPER
     started with F9 still shows him exactly the dialogs he configured.

  2. DISK-DIFF "Some files have changed on disk" (ide\diskdiffsdialog.pas)
     Raised from TMainIDE.DoCheckFilesOnDisk, whose FIRST line is
     `if not CheckFilesOnDiskEnabled then exit` (ide\main.pp:8856). That flag is a
     PUBLIC read/write property of TLazIDEInterface (ideintf\lazideintf.pas:589) -
     reachable from any design-time package through the global LazarusIDE. (The
     2026-07-19 commit that added the config seed recorded "CheckFilesOnDiskEnabled
     is a private TMainIDE field"; it is not, and that mistake is what sent the fix
     into the user's XML.)
     BeginPipeCritical / EndPipeCritical turn the check off for the duration of ONE
     marshalled MCP tool call and put the user's own value straight back. That is
     the window that deadlocks: DoBuildProject runs DoCheckFilesOnDisk in its own
     finally (main.pp:7273), i.e. INSIDE the agent's BuildProject call. Outside that
     window the IDE checks the disk exactly as the user configured it - and a check
     triggered while the human is driving (HandleApplicationActivate, main.pp:12649)
     still prompts him, which is correct: he is there to answer it.

  HONEST LIMIT: a disk-diff check triggered between tool calls (the human alt-tabs
  back into the IDE) can still raise the modal. That is a human at the keyboard, not
  an agent in the dark, and suppressing it would mean silently overriding an IDE
  behaviour the user never asked us to change - the very thing this unit undoes.

  Threading: every entry point touches LazarusIDE / DebugBoss and MUST be called on
  the IDE main thread. Nothing here marshals; the callers already run marshalled.

  Mode delphiunicode, matching the MCP core and the debug service. All literals are
  ASCII, so the file needs no BOM. }

{$IFDEF FPC}{$mode delphiunicode}{$H+}{$ENDIF}

interface

type
  { Runtime modal-tamer. All state is process-wide (one IDE, one debugger, one
    LazarusIDE), so the API is class methods over a private singleton hook. }
  TAefosIdeSilence = class
  public
    { Arm the ONE-SHOT debugger stop silence for the run Aefos is about to
      dispatch. Consumed by the next dsStop (or dropped when the debugger falls
      back to idle without stopping), so it can never silence more than the single
      stop it was armed for. Safe to call repeatedly and before any debugger
      exists. }
    class procedure ArmDebuggerStopSilence;
    { Open a window in which no disk-diff modal may block the MCP pipe. Nestable;
      the user's CheckFilesOnDiskEnabled is captured on the outermost Begin and
      restored on the matching End. }
    class procedure BeginPipeCritical;
    class procedure EndPipeCritical;
    { Drop the debugger hook. Called from finalization; also safe to call early. }
    class procedure Shutdown;
  end;

implementation

uses
  SysUtils,
  LazIDEIntf,                 // LazarusIDE.CheckFilesOnDiskEnabled (lazideintf.pas:589)
  BaseDebugManager,           // DebugBoss.RegisterStateChangeHandler (basedebugmanager.pas:226)
  LazDebuggerIntfBaseTypes,   // TDBGState (dsStop / dsIdle / dsNone / dsDestroying)
  DbgIntfDebuggerBase;        // TDebuggerIntf.SetSkipStopMessage (dbgintfdebuggerbase.pp:1763)

type
  { The object that owns the debugger state-change callback. A method pointer of an
    INSTANCE (not a class method) is what TMethodList stores, and keeping it on a
    singleton gives finalization something concrete to unregister - the IDE must
    never be left holding a callback of ours (CLAUDE.md IDE-unload rule 2, which
    still applies even though this package is statically linked). }
  TAefosIdeSilenceHook = class
  private
    FRegistered: Boolean;
    FStopArmed: Boolean;
    FCriticalDepth: Integer;
    // True only while we really hold the user's value (i.e. we read it and put
    // False in its place). Without it, a Begin that ran before LazarusIDE existed
    // would let the matching End write a value we never read.
    FCriticalHeld: Boolean;
    FSavedCheckFiles: Boolean;
    procedure _EnsureRegistered;
    procedure _DebuggerStateChanged(ADebugger: TDebuggerIntf;
      AnOldState: TDBGState);
  public
    procedure ArmStopSilence;
    procedure BeginCritical;
    procedure EndCritical;
    procedure Unregister;
  end;

var
  { Created in initialization (the constructor touches nothing but its own fields,
    so it is safe that early) and dropped in finalization. Every public entry point
    below tolerates it being nil, so a teardown race can never fault. }
  GHook: TAefosIdeSilenceHook = nil;

{ TAefosIdeSilenceHook }

procedure TAefosIdeSilenceHook._EnsureRegistered;
begin
  if FRegistered then
    Exit;
  // DebugBoss is created by the IDE during startup, which may be AFTER our
  // package's initialization - so registration is lazy, on first arm, never at
  // load time.
  if DebugBoss = nil then
    Exit;
  try
    DebugBoss.RegisterStateChangeHandler(_DebuggerStateChanged);
    FRegistered := True;
  except
    // A hook we could not install must never take the IDE down with it: the
    // dialog simply stays visible, which is the pre-Aefos behaviour.
    FRegistered := False;
  end;
end;

procedure TAefosIdeSilenceHook._DebuggerStateChanged(ADebugger: TDebuggerIntf;
  AnOldState: TDBGState);
begin
  if ADebugger = nil then
    Exit;
  case ADebugger.State of
    dsStop:
      begin
        // The dialog block at debugmanager.pas:1574 runs LATER in this same
        // notification, so setting the flag now is what suppresses it.
        if FStopArmed then
          ADebugger.SetSkipStopMessage;
        FStopArmed := False; // one shot, consumed
      end;
    dsIdle, dsNone, dsDestroying:
      // The session ended without ever reaching dsStop (failed launch, reset).
      // Drop the arm rather than let it leak into the developer's next F9 run.
      FStopArmed := False;
  end;
end;

procedure TAefosIdeSilenceHook.ArmStopSilence;
begin
  _EnsureRegistered;
  if FRegistered then
    FStopArmed := True;
end;

procedure TAefosIdeSilenceHook.BeginCritical;
begin
  Inc(FCriticalDepth);
  if FCriticalDepth <> 1 then
    Exit; // already inside a critical window; the outermost one owns the value
  FCriticalHeld := False;
  if LazarusIDE = nil then
    Exit;
  FSavedCheckFiles := LazarusIDE.CheckFilesOnDiskEnabled;
  LazarusIDE.CheckFilesOnDiskEnabled := False;
  FCriticalHeld := True;
end;

procedure TAefosIdeSilenceHook.EndCritical;
begin
  if FCriticalDepth <= 0 then
    Exit; // unbalanced End (cannot happen from the guarded callers) - ignore
  Dec(FCriticalDepth);
  if FCriticalDepth <> 0 then
    Exit;
  if not FCriticalHeld then
    Exit; // we never took the value - so we have nothing to give back
  FCriticalHeld := False;
  if LazarusIDE = nil then
    Exit;
  LazarusIDE.CheckFilesOnDiskEnabled := FSavedCheckFiles;
end;

procedure TAefosIdeSilenceHook.Unregister;
begin
  if not FRegistered then
    Exit;
  FRegistered := False;
  if DebugBoss = nil then
    Exit;
  try
    DebugBoss.UnregisterStateChangeHandler(_DebuggerStateChanged);
  except
    // Teardown must never raise (CLAUDE.md).
  end;
end;

{ TAefosIdeSilence }

class procedure TAefosIdeSilence.ArmDebuggerStopSilence;
begin
  if GHook <> nil then
    GHook.ArmStopSilence;
end;

class procedure TAefosIdeSilence.BeginPipeCritical;
begin
  if GHook <> nil then
    GHook.BeginCritical;
end;

class procedure TAefosIdeSilence.EndPipeCritical;
begin
  if GHook <> nil then
    GHook.EndCritical;
end;

class procedure TAefosIdeSilence.Shutdown;
begin
  if GHook = nil then
    Exit;
  GHook.Unregister;
  FreeAndNil(GHook);
end;

initialization
  GHook := TAefosIdeSilenceHook.Create;

finalization
  TAefosIdeSilence.Shutdown;

end.
