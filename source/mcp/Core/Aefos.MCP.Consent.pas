unit Aefos.MCP.Consent;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  Session-scoped per-tool consent registry (ESP-002, Epic 3/5 Demand 3/5).

  Destructive-action gating (ADR-064):
    - The first invocation of each destructive tool shows a confirmation
      modal. When the user picks "Allow for this session", the tool name is
      recorded here so subsequent calls to the same tool skip the modal.
    - The grant is keyed by exact tool name — a grant for DeleteUnit does
      not suppress the prompt for OverwriteFile.

  Lifetime (ADR-056): one registry per TMCPServer session, created with the
  tools registrar and discarded when the server stops. No grant survives a
  /agentname re-invocation.

  Threading (BR-12): the registry is consulted on the MCP worker thread; it
  carries no OTA / VCL dependency and is guarded by a critical section.
}

interface

type
  // Session-scoped set of destructive-tool names that hold a
  // "for this session" grant.
  IMCPConsentRegistry = interface
    ['{1F6B4D29-3A57-4C8E-9B02-6D8E1A3F7C45}']
    function IsSessionAllowed(const AToolName: string): Boolean;
    procedure GrantSession(const AToolName: string);
    procedure Revoke(const AToolName: string);
  end;

  TMCPConsentRegistry = class(TInterfacedObject, IMCPConsentRegistry)
  private
    FLock: TObject;
    FGranted: TObject; // TDictionary<string, Boolean>; opaque to keep uses lean
  public
    constructor Create;
    destructor Destroy; override;
    // IMCPConsentRegistry
    function IsSessionAllowed(const AToolName: string): Boolean;
    procedure GrantSession(const AToolName: string);
    procedure Revoke(const AToolName: string);
  end;

implementation

uses
  SyncObjs,
  Generics.Collections;

type
  TGrantMap = TDictionary<string, Boolean>;

{ TMCPConsentRegistry }

constructor TMCPConsentRegistry.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FGranted := TGrantMap.Create;
end;

destructor TMCPConsentRegistry.Destroy;
begin
  FGranted.Free;
  FLock.Free;
  inherited;
end;

function TMCPConsentRegistry.IsSessionAllowed(const AToolName: string): Boolean;
begin
  // Exact, case-sensitive match — tool names are fixed identifiers (ADR-064).
  TCriticalSection(FLock).Enter;
  try
    Result := TGrantMap(FGranted).ContainsKey(AToolName);
  finally
    TCriticalSection(FLock).Leave;
  end;
end;

procedure TMCPConsentRegistry.GrantSession(const AToolName: string);
begin
  TCriticalSection(FLock).Enter;
  try
    TGrantMap(FGranted).AddOrSetValue(AToolName, True);
  finally
    TCriticalSection(FLock).Leave;
  end;
end;

procedure TMCPConsentRegistry.Revoke(const AToolName: string);
begin
  TCriticalSection(FLock).Enter;
  try
    TGrantMap(FGranted).Remove(AToolName);
  finally
    TCriticalSection(FLock).Leave;
  end;
end;

end.
