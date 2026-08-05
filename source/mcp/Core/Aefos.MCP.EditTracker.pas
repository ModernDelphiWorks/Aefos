unit Aefos.MCP.EditTracker;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  Session-scoped read-before-edit hash tracker (ESP-002, Epic 3/5 Demand 2/5).

  Optimistic-concurrency support for the EditUnit write tool (ADR-060):
    - ReadUnit records the SHA-256 of every unit body it returns.
    - EditUnit re-reads the live content, re-hashes it, and refuses the
      edit when the unit was never read or the hash no longer matches.

  The tracker is a thread-safe map of normalized unit path -> SHA-256 hex.
  It carries no OTA / VCL dependency and compiles standalone.

  Lifetime (ADR-056): one tracker per TMCPServer instance; created with the
  server and discarded when it stops. No state survives across runs.
}

interface

type
  // Read-before-edit hash tracker. 'Record' is escaped (&Record) because
  // 'record' is a reserved word.
  IMCPEditTracker = interface
    ['{4E9C1A37-2D58-4B6F-9C81-7A0E3F2D5B14}']
    procedure &Record(const AUnitPath, AContent: string);
    function TryGetHash(const AUnitPath: string; out AHash: string): Boolean;
    function WasRead(const AUnitPath: string): Boolean;
    procedure Forget(const AUnitPath: string);
  end;

  TMCPEditTracker = class(TInterfacedObject, IMCPEditTracker)
  private
    FLock: TObject;
    FHashes: TObject; // TDictionary<string, string>; opaque to keep uses lean
    function _NormalizePath(const AUnitPath: string): string;
  public
    constructor Create;
    destructor Destroy; override;
    // IMCPEditTracker
    procedure &Record(const AUnitPath, AContent: string);
    function TryGetHash(const AUnitPath: string; out AHash: string): Boolean;
    function WasRead(const AUnitPath: string): Boolean;
    procedure Forget(const AUnitPath: string);
    // SHA-256 of the UTF-8 bytes of AContent, rendered lowercase hex.
    class function HashContent(const AContent: string): string;
  end;

implementation

uses
  SysUtils,
  Aefos.Compat.Sha256,
  SyncObjs,
  Generics.Collections;

type
  THashMap = TDictionary<string, string>;

{ TMCPEditTracker }

constructor TMCPEditTracker.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FHashes := THashMap.Create;
end;

destructor TMCPEditTracker.Destroy;
begin
  FHashes.Free;
  FLock.Free;
  inherited;
end;

class function TMCPEditTracker.HashContent(const AContent: string): string;
begin
  // SHA-256 of the UTF-8 bytes, lowercase hex (via the cross-compiler shim).
  Result := TAefosSha256.HexDigest(AContent);
end;

function TMCPEditTracker._NormalizePath(const AUnitPath: string): string;
begin
  // Windows paths are case-insensitive; fold case so ReadUnit and EditUnit
  // key the same unit identically (BR-3).
  Result := LowerCase(Trim(AUnitPath));
end;

procedure TMCPEditTracker.&Record(const AUnitPath, AContent: string);
var
  LHash: string;
begin
  LHash := HashContent(AContent);  // hash outside the lock
  TCriticalSection(FLock).Enter;
  try
    THashMap(FHashes).AddOrSetValue(_NormalizePath(AUnitPath), LHash);
  finally
    TCriticalSection(FLock).Leave;
  end;
end;

function TMCPEditTracker.TryGetHash(const AUnitPath: string;
  out AHash: string): Boolean;
begin
  TCriticalSection(FLock).Enter;
  try
    Result := THashMap(FHashes).TryGetValue(_NormalizePath(AUnitPath), AHash);
  finally
    TCriticalSection(FLock).Leave;
  end;
end;

function TMCPEditTracker.WasRead(const AUnitPath: string): Boolean;
begin
  TCriticalSection(FLock).Enter;
  try
    Result := THashMap(FHashes).ContainsKey(_NormalizePath(AUnitPath));
  finally
    TCriticalSection(FLock).Leave;
  end;
end;

procedure TMCPEditTracker.Forget(const AUnitPath: string);
begin
  TCriticalSection(FLock).Enter;
  try
    THashMap(FHashes).Remove(_NormalizePath(AUnitPath));
  finally
    TCriticalSection(FLock).Leave;
  end;
end;

end.
