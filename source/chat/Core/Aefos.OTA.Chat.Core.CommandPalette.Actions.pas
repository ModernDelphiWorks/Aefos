unit Aefos.OTA.Chat.Core.CommandPalette.Actions;

{
  Live-action catalog for the command palette (ESP-002, Epic 2/4, Demand 3/4).

  Implements IActionCatalog per ADR-046: returns the fixed list of live
  plugin actions that the palette must surface alongside user commands. The
  composition root wires this catalog into TCommandPalette; tests substitute
  a stub.

  Action labels mirror the legacy menu captions (without the keyboard-hint
  suffix). Descriptions are short imperative sentences usable as filter
  targets by the palette's substring matcher (ADR-041).

  Architectural baseline:
    - ADR-045: TCommandKind extended with ckAction; TActionId selects the
      handler at the composition-root dispatch switch.
    - ADR-046: catalog is the single source of "which actions show up in
      the palette"; future additions are an O(1) edit here.

  Constraints:
    - Delphi 13 only (ADR-006).
    - No OTA, no VCL, no Win32 imports (C-2).
}

interface

uses
  Aefos.OTA.Chat.Core.CommandPalette.Types;

type
  TActionCatalog = class(TInterfacedObject, IActionCatalog)
  public
    function List: TArray<TCommandEntry>;
  end;

implementation

function _MakeAction(const AName, ADescription: string;
  const AId: TActionId): TCommandEntry;
begin
  Result := Default(TCommandEntry);
  Result.Name := AName;
  Result.Description := ADescription;
  Result.CommandName := '';
  Result.Kind := ckAction;
  Result.ActionId := AId;
end;

{ TActionCatalog }

function TActionCatalog.List: TArray<TCommandEntry>;
begin
  SetLength(Result, 3);
  Result[0] := _MakeAction(
    'Suggest from Selection',
    'Ask the active executor for suggestions on the current selection.',
    aiAgentSuggest);
  Result[1] := _MakeAction(
    'Save Commands to the AI CLI',
    'Replicate canonical commands to the active executor target folder.',
    aiCommandReplicate);
  Result[2] := _MakeAction(
    'Configuration',
    'Open the Aefos configuration dialog.',
    aiConfiguration);
end;

end.
