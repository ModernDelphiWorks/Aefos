unit Aefos.MCP.Resources;

{
  Thread-safe resource registry for the in-process MCP server
  (ESP-002, Epic 3/5 Demand 5/5; ADR-071).

  TMCPResourceRegistry holds a lock-guarded, registration-ordered list of
  TMCPResourceDescriptor. It is the substrate of the resources capability:
  the server reads it for resources/list and resources/read.

  Pure RTL — no ToolsAPI, no Vcl.*. The registry stores provider callbacks
  but never invokes them; the server invokes a descriptor's Provider when
  it handles resources/read.

  Lifetime: session-scoped (ADR-056) — created and freed with the server.
}

interface

uses
  System.SysUtils,
  System.SyncObjs,
  System.Generics.Collections,
  Aefos.MCP.Types;

type
  TMCPResourceRegistry = class(TInterfacedObject, IMCPResourceRegistry)
  private
    FItems: TList<TMCPResourceDescriptor>;
    FLock: TCriticalSection;
  public
    constructor Create;
    destructor Destroy; override;
    // IMCPResourceRegistry
    procedure Register(const ADescriptor: TMCPResourceDescriptor);
    function List: TArray<TMCPResourceDescriptor>;
    function TryGet(const AUri: string;
      out ADescriptor: TMCPResourceDescriptor): Boolean;
  end;

implementation

{ TMCPResourceRegistry }

constructor TMCPResourceRegistry.Create;
begin
  inherited Create;
  FItems := TList<TMCPResourceDescriptor>.Create;
  FLock := TCriticalSection.Create;
end;

destructor TMCPResourceRegistry.Destroy;
begin
  FItems.Free;
  FLock.Free;
  inherited;
end;

procedure TMCPResourceRegistry.Register(
  const ADescriptor: TMCPResourceDescriptor);
begin
  if ADescriptor.Uri = '' then
    raise EArgumentException.Create(
      'TMCPResourceRegistry.Register: URI required');
  FLock.Enter;
  try
    FItems.Add(ADescriptor);
  finally
    FLock.Leave;
  end;
end;

function TMCPResourceRegistry.List: TArray<TMCPResourceDescriptor>;
begin
  FLock.Enter;
  try
    Result := FItems.ToArray;
  finally
    FLock.Leave;
  end;
end;

function TMCPResourceRegistry.TryGet(const AUri: string;
  out ADescriptor: TMCPResourceDescriptor): Boolean;
var
  LItem: TMCPResourceDescriptor;
begin
  Result := False;
  ADescriptor := Default(TMCPResourceDescriptor);
  FLock.Enter;
  try
    for LItem in FItems do
      if LItem.Uri = AUri then
      begin
        ADescriptor := LItem;
        Exit(True);
      end;
  finally
    FLock.Leave;
  end;
end;

end.
