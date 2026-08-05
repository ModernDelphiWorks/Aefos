unit Aefos.OTA.Chat.Core.AgentSuggest;

{
  ToolsAPI-free dispatch seam for the "Suggest from Selection" keyboard shortcut
  (ESP-004, demand 2/4; ADR-235).

  Body lifted verbatim from Adapter.AgentSuggest._TriggerSuggest to enable
  headless DUnit coverage. The OTA keyboard-binding shell delegates here;
  the ToolsAPI coupling stays in Adapter.AgentSuggest.
}

interface

uses
  Aefos.OTA.Chat.Core.CommandExecutor,
  Aefos.OTA.Chat.UI.OutputPanel.Edge;

const
  HardcodedCommandName = 'suggest';

procedure DispatchSuggest(const AExecutor: ICommandExecutor;
  const ASurface: IOutputPanelSurface; const ASelection: string);

implementation

uses
  System.SysUtils;

procedure DispatchSuggest(const AExecutor: ICommandExecutor;
  const ASurface: IOutputPanelSurface; const ASelection: string);
begin
  // Bring the chat to front IMMEDIATELY (even from the Welcome screen) so the dev
  // SEES it start thinking - the perceived "freeze" was the panel staying hidden
  // while the CLI ran. Show first, then dispatch.
  ASurface.Show;
  // Begin the turn NOW: Clear dismisses the Welcome screen and shows the pulsing
  // brain right away. Without this the Welcome page stayed up until the first
  // response chunk arrived (dsAppend), so the dev saw no sign it was working.
  // Clear only resets the streaming state - it does NOT wipe the conversation.
  ASurface.Clear;
  try
    AExecutor.Execute(HardcodedCommandName, ASelection);
  except
    on E: Exception do
      ASurface.ReportError(E);
  end;
end;

end.
