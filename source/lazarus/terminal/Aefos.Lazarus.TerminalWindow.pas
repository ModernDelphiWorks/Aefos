unit Aefos.Lazarus.TerminalWindow;

{ TAefosLazTerminalWindow -- the LCL "Aefos AI Terminal" window (Lazarus edition).

  A form hosting the native terminal control (TAefosLazTerminalControl) client-
  aligned. On first show it spawns cmd.exe behind a pseudo-console and streams its
  output live onto the grid; the user types and sees output, exactly like the Delphi
  Terminal dock.

  DOCKABLE PANEL: the window is registered with the IDE's own window-creation seam
  (IDEWindowCreators.Add, IDEIntf), so when AnchorDocking is active it behaves like a
  native IDE tool panel -- the user docks/undocks it (a bottom tool panel by default,
  the natural home for a terminal). The registered form Name (cAefosTerminalFormName)
  keys the IDE layout/dock persistence. Showing routes through
  IDEWindowCreators.ShowForm (create-on-demand + dock); if IDE docking is unavailable
  it degrades to a plain floating Show. This mirrors TAefosLazChatDock exactly
  (source\lazarus\webview\Aefos.Lazarus.ChatWindow.pas).

  Built in code (no .lfm): a single reusable instance whose lifetime is the IDE's.
  The IDE-held creator reference is dropped at finalization (IDE-unload discipline). }

{$mode delphi}
{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls,
  Aefos.OTA.Terminal.Core.ActionRunner,
  Aefos.Lazarus.TerminalControl;

type
  TAefosLazTerminalWindow = class(TForm)
  private
    FTerm: TAefosLazTerminalControl;
  protected
    procedure DoShow; override;
  public
    constructor CreateNew(AOwner: TComponent; Num: Integer = 0); override;
  end;

  { TAefosLazTerminalDock -- registers the terminal window as a native, DOCKABLE IDE
    panel and shows/focuses it on demand. All entry points are class methods so no
    loose product routines are exported (the IDEWindowCreators create-callback itself
    is the implementation-section IDE callback the IDEIntf shape mandates). }
  TAefosLazTerminalDock = class
  public
    { Registers the dockable window creator with the IDE. Call at package LOAD
      (like the menu). Idempotent + guarded: never raises, no-op when the IDE
      window seam is unavailable. }
    class procedure RegisterDockable;
    { Shows/focuses the terminal: the native docked panel when the creator is
      registered (AnchorDocking docks it), else a floating fallback window. }
    class procedure Show;
    { Removes the IDE-held creator reference at teardown (IDE-unload discipline). }
    class procedure UnregisterDockable;
    { The live terminal's input channel for the Action Center runner, or nil when
      no terminal window exists yet. The single-window Lazarus edition has one
      terminal, so "active" == that window's control (the Delphi edition tracks a
      focused view among many). The control is non-refcounted, so the returned
      interface never affects its lifetime. }
    class function ActiveTerminalInput: ITerminalInput;
  end;

implementation

uses
  IDEWindowIntf;

const
  { The IDE-window registration id. Must be a valid identifier: it also becomes the
    form's Name -- the key AnchorDocking and the IDE layout storage persist on. }
  cAefosTerminalFormName = 'AefosAITerminal';

var
  GTerminalWindow: TAefosLazTerminalWindow = nil;
  GTerminalCreator: TIDEWindowCreator = nil;

{ The IDE window-creation callback IDEWindowCreators invokes on demand. A plain
  implementation-level procedure is the contract IDEWindowIntf requires (the same
  shape every Lazarus dockable window uses) -- an IDE callback, not loose product
  API. Creates the single terminal window on first use and stamps its Name so the
  layout/dock persistence keys on it. }
procedure _CreateAefosTerminalWindow(Sender: TObject; aFormName: string;
  var AForm: TCustomForm; DoDisableAutoSizing: Boolean);
begin
  if CompareText(aFormName, cAefosTerminalFormName) <> 0 then
    Exit;
  if GTerminalWindow = nil then
  begin
    GTerminalWindow := TAefosLazTerminalWindow.CreateNew(Application);
    GTerminalWindow.Name := aFormName;
  end;
  // Honor the IDEWindowIntf contract: when DoDisableAutoSizing is True the caller
  // (the AnchorDocking dock master) balances it with EnableAutoSizing after we
  // return, so the create-callback MUST hand back a form whose auto-sizing is
  // already disabled (mirrors TAefosLazChatDock's _CreateAefosChatWindow).
  if DoDisableAutoSizing then
    GTerminalWindow.DisableAutoSizing;
  AForm := GTerminalWindow;
end;

{ Fallback: open the terminal as a plain floating window when IDE docking is not
  available (IDEWindowCreators unset / creator not registered). }
procedure _ShowFloatingFallback;
begin
  if GTerminalWindow = nil then
    GTerminalWindow := TAefosLazTerminalWindow.CreateNew(Application);
  GTerminalWindow.Show;
  GTerminalWindow.BringToFront;
end;

{ TAefosLazTerminalDock }

class procedure TAefosLazTerminalDock.RegisterDockable;
begin
  { IDEWindowCreators is provided by the IDE core (IDEIntf); when AnchorDocking is
    present, ShowForm routes through IDEDockMaster and the panel becomes dockable.
    Idempotent + guarded so a failure only degrades to the floating fallback. }
  if IDEWindowCreators = nil then
    Exit;
  if GTerminalCreator <> nil then
    Exit;
  try
    GTerminalCreator := IDEWindowCreators.Add(cAefosTerminalFormName,
      @_CreateAefosTerminalWindow, nil,
      { Default placement HINTS (the dock master may override): a bottom tool
        panel spanning most of the width, ~240 px tall -- a terminal's home. }
      '10%', '70%', '80%', '+240',
      '', alBottom);
  except
    GTerminalCreator := nil;
  end;
end;

class procedure TAefosLazTerminalDock.Show;
begin
  { Prefer the native docked panel: ShowForm create-on-demands the form via the
    creator and, when AnchorDocking is active, docks it. Fall back to floating. }
  if (IDEWindowCreators <> nil) and (GTerminalCreator <> nil) then
    IDEWindowCreators.ShowForm(cAefosTerminalFormName, True)
  else
    _ShowFloatingFallback;
end;

class procedure TAefosLazTerminalDock.UnregisterDockable;
var
  LIndex: Integer;
begin
  { IDE-unload discipline: drop the IDE-held reference to our create-proc so no
    dangling pointer into this unit survives. Guarded: IDEWindowCreators may already
    be gone at finalization order. }
  if (GTerminalCreator <> nil) and (IDEWindowCreators <> nil) then
  begin
    try
      LIndex := IDEWindowCreators.IndexOfName(cAefosTerminalFormName);
      if LIndex >= 0 then
        IDEWindowCreators.Delete(LIndex);
    except
    end;
  end;
  GTerminalCreator := nil;
end;

class function TAefosLazTerminalDock.ActiveTerminalInput: ITerminalInput;
begin
  { FTerm is private to TAefosLazTerminalWindow but unit-visible here (same unit).
    Return nil when no window / control exists yet; the runner then reports
    aroNoActiveSession, and even when a control exists its IsActive gate still
    guards against a shell that has not started / already exited. }
  Result := nil;
  if (GTerminalWindow <> nil) and (GTerminalWindow.FTerm <> nil) then
    Result := GTerminalWindow.FTerm as ITerminalInput;
end;

{ TAefosLazTerminalWindow }

constructor TAefosLazTerminalWindow.CreateNew(AOwner: TComponent; Num: Integer);
begin
  inherited CreateNew(AOwner, Num);
  Caption := 'Aefos AI Terminal';
  Width := 720;
  Height := 420;
  Position := poScreenCenter;

  FTerm := TAefosLazTerminalControl.Create(Self);
  FTerm.Parent := Self;
  FTerm.Align := alClient;
end;

procedure TAefosLazTerminalWindow.DoShow;
begin
  inherited DoShow;
  // Spawn the shell on the first show (the handle + metrics are ready by now, so
  // the pseudo-console starts at the painted grid size). Guarded inside StartShell.
  if Assigned(FTerm) and not FTerm.Started then
  begin
    FTerm.StartShell('cmd.exe');
    if FTerm.CanFocus then
      FTerm.SetFocus;
  end;
end;

finalization
  // Mirror the chat window singleton: the package is statically linked, so this
  // runs only at IDE shutdown. Drop the IDE-held creator reference FIRST (unload
  // discipline), then close and free the single window. Guarded so shutdown never
  // raises.
  TAefosLazTerminalDock.UnregisterDockable;
  if GTerminalWindow <> nil then
  begin
    try
      GTerminalWindow.Close;
    except
    end;
    FreeAndNil(GTerminalWindow);
  end;

end.
