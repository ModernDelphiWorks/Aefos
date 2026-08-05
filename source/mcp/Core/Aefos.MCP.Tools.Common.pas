unit Aefos.MCP.Tools.Common;

{
  Shared base for the per-group MCP tool registrars (S1 audit — the #1 reuse ask).

  Every Tools.* registrar used to carry its OWN byte-for-byte copies of the same
  stateless helpers. They live ONCE here now, as protected methods on
  TMCPToolsRegistrarBase: a registrar inherits this base instead of
  TInterfacedObject and DROPS its local copies — the existing _BuildDescriptor(...)
  / _ConsentToken(...) call sites resolve to the inherited methods unchanged, so
  the extraction is pure and behaviour-preserving.
    - _BuildDescriptor — 8 identical class-method copies.
    - _ConsentToken    — 8 class-method + 9 free-function copies (17 -> 1).
    - _ReadString      — required-string param reader, all 12 class-method copies.

  Some registrars used UNIT-LEVEL FREE FUNCTIONS instead of class methods. The
  consent-token map existed in BOTH forms; the free-function form is consolidated
  as TMCPConsentToken.Token below and the base method _ConsentToken forwards to it, so
  there is ONE definition for both forms. 13 registrars now share this base.

  RTL + Aefos.MCP.Types only (TMCPToolDescriptor / TMCPToolHandler live there) —
  no new coupling, no cycle, stays in the MCP.Core BPL.
}

interface

uses
  System.JSON,
  Aefos.MCP.Types;

type
  // Common ancestor for the Tools.* registrars. Interface-implementing registrars
  // keep their dispatch interface in the class clause and just swap the ancestor:
  //   = class(TMCPToolsRegistrarBase, IMCPXDispatch)
  TMCPToolsRegistrarBase = class(TInterfacedObject)
  protected
    // Assembles a tool descriptor from its parts. Intent defaults to tiNeutral via
    // Default(); a guarded tool sets Result.Intent at the call site after this.
    function _BuildDescriptor(const AName, ATitle, ADesc: string;
      const AInput, AOutput: TJSONObject;
      const AHandler: TMCPToolHandler): TMCPToolDescriptor;
    // Maps a consent decision to its audit-log token.
    function _ConsentToken(const ADecision: TMCPConsentDecision): string;
    // Reads a REQUIRED string param; raises EMCPInvalidParams when missing or not
    // a JSON string.
    function _ReadString(const AParams: TJSONObject; const AName: string): string;
  end;

type
  // Consent-decision -> audit-token map as a sealed static namespace, for the
  // registrars that call it directly instead of inheriting the base class. Single
  // source: the base method _ConsentToken forwards to Token. Never instantiated.
  TMCPConsentToken = class sealed
  public
    class function Token(const ADecision: TMCPConsentDecision): string; static;
  end;

implementation

function TMCPToolsRegistrarBase._BuildDescriptor(const AName, ATitle, ADesc: string;
  const AInput, AOutput: TJSONObject;
  const AHandler: TMCPToolHandler): TMCPToolDescriptor;
begin
  Result := TMCPToolDescriptor.Create(
    AName,
    ATitle,
    ADesc,
    AInput,
    AOutput,
    AHandler);
end;

class function TMCPConsentToken.Token(const ADecision: TMCPConsentDecision): string;
begin
  case ADecision of
    cdAllowOnce:    Result := 'once';
    cdAllowSession: Result := 'session';
  else
    Result := 'denied';
  end;
end;

function TMCPToolsRegistrarBase._ConsentToken(
  const ADecision: TMCPConsentDecision): string;
begin
  Result := TMCPConsentToken.Token(ADecision);
end;

function TMCPToolsRegistrarBase._ReadString(const AParams: TJSONObject;
  const AName: string): string;
var
  LValue: TJSONValue;
begin
  if not Assigned(AParams) then
    raise EMCPInvalidParams.Create(AName + ' required');
  LValue := AParams.GetValue(AName);
  if not (Assigned(LValue) and (LValue is TJSONString)) then
    raise EMCPInvalidParams.Create(AName + ' required (string)');
  Result := TJSONString(LValue).Value;
end;

end.
