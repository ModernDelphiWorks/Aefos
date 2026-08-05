unit Aefos.OTA.Chat.Core.MainMenu;

{
  Domain unit for the OTA main-menu feature.
  Declares the TMenuAction enum, the TMenuItemDescriptor record, the
  TMainMenuAdapterConfig record, the DefaultMenuItems helper, and the
  OTA_PLUGIN_VERSION literal.

  The menu surface is intentionally minimal: DefaultMenuItems = Open Chat +
  About. The chat panel is the primary entry point; the command-replicate action
  survives as a Ctrl+Alt+F11 keyboard binding (Adapter.MainMenu) and AgentSuggest
  as Ctrl+Alt+F10 (Adapter.AgentSuggest).

  OTA_PLUGIN_VERSION is now only a FALLBACK: SupportInfo.PluginVersion reads the
  BPL's FILEVERSION (from the .dproj) first, so the version comes from ONE source
  (the .dproj, bumped by scripts/bump-version.ps1) and the Chat can't drift from the
  Terminal. This literal is used only when the module carries no version resource.
}

interface

uses
  System.SysUtils,
  Aefos.OTA.Chat.Core.CommandReplicator.Types,
  Aefos.OTA.Chat.UI.OutputPanel.Edge;

const
  OTA_PLUGIN_VERSION = '1.3.0';

type
  TMenuAction = (maAgentSuggest, maCommandReplicate, maAbout, maShowChat);

  TMenuItemDescriptor = record
    Action: TMenuAction;
    Caption: string;
    ShortcutText: string;
    IsSeparator: Boolean;
  end;

  TShowChatProc = reference to procedure;

  TMainMenuAdapterConfig = record
    ReplicatorService: ICommandReplicator;
    ReplicatorSurface: IOutputPanelSurface;
    ShowChat: TShowChatProc;
  end;

function DefaultMenuItems: TArray<TMenuItemDescriptor>;

implementation

function DefaultMenuItems: TArray<TMenuItemDescriptor>;
begin
  SetLength(Result, 3);

  Result[0].Action := maShowChat;
  Result[0].Caption := 'Open Chat';
  Result[0].ShortcutText := '';
  Result[0].IsSeparator := False;

  Result[1].Action := maShowChat;
  Result[1].Caption := '';
  Result[1].ShortcutText := '';
  Result[1].IsSeparator := True;

  Result[2].Action := maAbout;
  Result[2].Caption := 'About Aefos' + #$2026;
  Result[2].ShortcutText := '';
  Result[2].IsSeparator := False;
end;

end.
