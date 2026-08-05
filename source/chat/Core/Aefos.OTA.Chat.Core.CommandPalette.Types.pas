unit Aefos.OTA.Chat.Core.CommandPalette.Types;

{
  Domain types for the command palette (ESP-002, Epic 2/4).

  Pure declarative unit shared by the palette logic, the modal form,
  and the action catalog. ADR-045 extends TCommandKind with ckAction and
  introduces TActionId so action selections can be dispatched without
  coupling Core.CommandPalette.* to Core.MainMenu (C-3). ADR-046 declares
  IActionCatalog as the live-action source consumed by TCommandPalette.

  Architectural baseline:
    - ADR-040: modal TForm per-call hosting (form lifetime is bounded).
    - ADR-041: case-insensitive substring match against Name + Description.
    - ADR-042: in-memory recents only (no disk I/O in this demand).
    - ADR-043: ICommandRegistry.List called on each Search (no caching).
    - ADR-045: TCommandKind = (ckCommand, ckAction); TActionId is a local enum.
    - ADR-046: IActionCatalog supplies the live-action list to the palette.

  Constraints:
    - Delphi 13 only (ADR-006).
    - No OTA, no VCL, no Win32 imports (C-2).
    - No dependency on Core.MainMenu (C-3).
}

interface

uses
  System.SysUtils;

type
  TCommandKind = (ckCommand, ckAction);

  TActionId = (aiAgentSuggest, aiCommandReplicate, aiConfiguration);

  TCommandEntry = record
    Name: string;
    Description: string;
    CommandName: string;
    Kind: TCommandKind;
    ActionId: TActionId;
  end;

  ICommandPalette = interface
    ['{2A1E4F87-90B3-4B9F-8C71-7E1F5A4D6B22}']
    function Search(const AQuery: string): TArray<TCommandEntry>;
    procedure AddRecent(const AEntry: TCommandEntry);
    function GetRecents: TArray<TCommandEntry>;
    function ListForInline(const AQuery: string): TArray<TCommandEntry>;
  end;

  IActionCatalog = interface
    ['{D4C1B9F7-3A52-4E68-9B0F-7E2A4D5C1A38}']
    function List: TArray<TCommandEntry>;
  end;

  ECommandPaletteError = class(Exception);

implementation

end.
