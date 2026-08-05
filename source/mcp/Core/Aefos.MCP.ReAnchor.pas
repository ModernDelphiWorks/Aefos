unit Aefos.MCP.ReAnchor;

{
  Re-anchoring notifier core for the in-process MCP server
  (ESP-002, Epic 3/5 Demand 5/5; ADR-072).

  TMCPReAnchorNotifier maps an OTA event to the resource URIs whose content
  has gone stale and asks the injected IMCPNotificationPublisher to re-anchor
  them. It is the pure, timer-agnostic decision core:

    - The three discrete events (raProjectSwitched, raFileSaved,
      raActiveEditorChanged) emit immediately on NotifyEvent.
    - raCursorMoved only sets an internal pending flag; the aefos://
      cursor emission happens on Flush. Any number of raCursorMoved between
      two Flush calls coalesce into at most one cursor emission.

  The debounce timer is NOT here — it lives in the production OTA-event
  observer (Register.pas). This unit is fully unit-testable by calling
  NotifyEvent and Flush directly.

  Pure RTL — no ToolsAPI, no Vcl.*. The pending flag is lock-guarded
  defensively (NotifyEvent runs on the IDE main thread; Flush on the
  debounce timer — both main-thread in practice).
}

interface

uses
  System.SysUtils,
  System.SyncObjs,
  Aefos.MCP.Types;

type
  IMCPReAnchorNotifier = interface
    ['{3C8A1B7D-5E04-4F92-A671-0D2E9F4B3C81}']
    procedure NotifyEvent(const AEvent: TMCPReAnchorEvent);
    procedure Flush;
  end;

  TMCPReAnchorNotifier = class(TInterfacedObject, IMCPReAnchorNotifier)
  private
    FPublisher: IMCPNotificationPublisher;
    FLock: TCriticalSection;
    FCursorPending: Boolean;
  public
    constructor Create(const APublisher: IMCPNotificationPublisher);
    destructor Destroy; override;
    // IMCPReAnchorNotifier
    procedure NotifyEvent(const AEvent: TMCPReAnchorEvent);
    procedure Flush;
  end;

implementation

{ TMCPReAnchorNotifier }

constructor TMCPReAnchorNotifier.Create(
  const APublisher: IMCPNotificationPublisher);
begin
  inherited Create;
  if not Assigned(APublisher) then
    raise EArgumentNilException.Create('TMCPReAnchorNotifier: APublisher');
  FPublisher := APublisher;
  FLock := TCriticalSection.Create;
end;

destructor TMCPReAnchorNotifier.Destroy;
begin
  FLock.Free;
  inherited;
end;

procedure TMCPReAnchorNotifier.NotifyEvent(const AEvent: TMCPReAnchorEvent);
begin
  // Event -> resource-URI mapping (BR-8 / ADR-072).
  case AEvent of
    raProjectSwitched:
      begin
        FPublisher.NotifyResourceUpdated(MCP_RES_ACTIVE_PROJECT);
        FPublisher.NotifyResourceUpdated(MCP_RES_ACTIVE_UNIT);
      end;
    raFileSaved:
      FPublisher.NotifyResourceUpdated(MCP_RES_ACTIVE_UNIT);
    raActiveEditorChanged:
      begin
        FPublisher.NotifyResourceUpdated(MCP_RES_ACTIVE_UNIT);
        FPublisher.NotifyResourceUpdated(MCP_RES_CURSOR);
      end;
    raCursorMoved:
      begin
        FLock.Enter;
        try
          FCursorPending := True;
        finally
          FLock.Leave;
        end;
      end;
  end;
end;

procedure TMCPReAnchorNotifier.Flush;
var
  LPending: Boolean;
begin
  FLock.Enter;
  try
    LPending := FCursorPending;
    FCursorPending := False;
  finally
    FLock.Leave;
  end;
  if LPending then
    FPublisher.NotifyResourceUpdated(MCP_RES_CURSOR);
end;

end.
