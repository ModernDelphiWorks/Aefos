unit Aefos.OTA.Chat.Core.PaletteState.Types;

{
  Persistence contract for the command palette (ESP-002, Epic 2/4,
  Demand 4/4).

  Pure declarative unit. Defines the IPaletteState collaborator that
  TCommandPalette consumes to seed recents on construction and to
  persist them after each AddRecent. Implementation lives in
  Core.PaletteState; tests can supply a stub.

  Architectural baseline:
    - ADR-049: state stored at <root>\.aefos\palette-state.json.
    - ADR-050: persistence is a dedicated collaborator; the palette
      stays I/O-free.
    - ADR-053: TCommandPalette accepts IPaletteState as a third
      constructor parameter; nil disables persistence.

  Constraints:
    - Delphi 13 only (ADR-006).
    - No System.IOUtils, no System.JSON, no Winapi.Windows here.
    - No VCL, no OTA.
}

interface

uses
  System.SysUtils,
  Aefos.OTA.Chat.Core.CommandPalette.Types;

type
  IPaletteState = interface
    ['{6F2E0B4C-9D7A-4E1B-9F5C-3A8E1D2B7C90}']
    function Load: TArray<TCommandEntry>;
    procedure Save(const ARecents: TArray<TCommandEntry>);
  end;

  EPaletteStateError = class(Exception);
  EPaletteStateSaveFailed = class(EPaletteStateError);

implementation

end.
