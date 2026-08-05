unit Aefos.OTA.Terminal.UI.ActivityPulse;

{
  Terminal activity pulse, extracted from the TAefosTerminalDockForm god-form as a
  focused helper of the DockForm split (audit / form decomposition, ESP-059).

  Owns the "which views had recent output" state: the activity map + the ~350ms decay
  timer. A view is tracked when its tab opens (Track), flagged on output (NoteActivity,
  which starts the decay), queried while painting the tab strip (IsActive), and dropped
  when its pane/tab closes (Forget). When the decay timer fires it clears every flag and
  raises OnDecayed so the form repaints the tab strip (it invalidates the terminals
  list) — the helper owns no controls, so the repaint stays the form's job.

  The form keeps the view-model lookups (Host->view, tab->view) and wires each
  Host.OnActivity to a handler that calls NoteActivity; this helper only owns the
  map+timer. It holds nothing teardown-sensitive beyond its own timer, which its
  destructor disables and frees — the form's Destroy frees the helper after de-wiring
  every Host.OnActivity, so no callback can reach a freed helper.
}

interface

uses
  System.Classes,
  Vcl.ExtCtrls,
  System.Generics.Collections,
  Aefos.OTA.Terminal.UI.TerminalView;

type
  TTerminalActivityPulse = class
  private
    FMap: TDictionary<TAefosTerminalTerminalView, Boolean>;
    FTimer: TTimer;
    FOnDecayed: TNotifyEvent;
    procedure _OnTimer(Sender: TObject);
  public
    // AOnDecayed fires (on the main thread) after the decay clears the flags, so the
    // owner can repaint the tab strip. May be nil.
    constructor Create(const AOnDecayed: TNotifyEvent);
    destructor Destroy; override;
    // Register a view as tracked-but-idle (called when its tab opens).
    procedure Track(const AView: TAefosTerminalTerminalView);
    // Drop a view (called when its pane/tab closes).
    procedure Forget(const AView: TAefosTerminalTerminalView);
    // Flag a tracked view active and start the decay timer. Only flips a
    // tracked-but-idle view (mirrors the original guard).
    procedure NoteActivity(const AView: TAefosTerminalTerminalView);
    // True when AView is tracked and currently flagged active (for tab paint).
    function IsActive(const AView: TAefosTerminalTerminalView): Boolean;
  end;

implementation

constructor TTerminalActivityPulse.Create(const AOnDecayed: TNotifyEvent);
begin
  inherited Create;
  FOnDecayed := AOnDecayed;
  FMap := TDictionary<TAefosTerminalTerminalView, Boolean>.Create;
  FTimer := TTimer.Create(nil);
  FTimer.Enabled := False;
  FTimer.Interval := 350;
  FTimer.OnTimer := _OnTimer;
end;

destructor TTerminalActivityPulse.Destroy;
begin
  if Assigned(FTimer) then
    FTimer.Enabled := False;
  FTimer.Free;
  FMap.Free;
  inherited;
end;

procedure TTerminalActivityPulse.Track(const AView: TAefosTerminalTerminalView);
begin
  FMap.AddOrSetValue(AView, False);
end;

procedure TTerminalActivityPulse.Forget(const AView: TAefosTerminalTerminalView);
begin
  FMap.Remove(AView);
end;

procedure TTerminalActivityPulse.NoteActivity(const AView: TAefosTerminalTerminalView);
begin
  // Runs on the main thread (via Synchronize in TTerminalReaderThread.Execute).
  if FMap.ContainsKey(AView) and not FMap[AView] then
  begin
    FMap[AView] := True;
    if Assigned(FTimer) then
      FTimer.Enabled := True;
  end;
end;

function TTerminalActivityPulse.IsActive(const AView: TAefosTerminalTerminalView): Boolean;
begin
  Result := Assigned(AView) and FMap.ContainsKey(AView) and FMap[AView];
end;

procedure TTerminalActivityPulse._OnTimer(Sender: TObject);
var
  LView: TAefosTerminalTerminalView;
  LAnyCleared: Boolean;
begin
  // Clear all activity flags, notify the owner to repaint the tab strip, stop.
  LAnyCleared := False;
  for LView in FMap.Keys do
    if FMap[LView] then
    begin
      FMap[LView] := False;
      LAnyCleared := True;
    end;
  if LAnyCleared and Assigned(FOnDecayed) then
    FOnDecayed(Self);
  FTimer.Enabled := False;
end;

end.
