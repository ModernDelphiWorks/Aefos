unit Aefos.OTA.Terminal.UI.ContextProvider;

(*
  OTA-backed IIDEContextProvider for the AI-CLI context strip - ESP-076, S2 /
  ADR-076-02.

  Feeds a live TIDEContextSnapshot to the strip by REUSING the existing ESP-070
  situational reads on TMCPWorkspaceFacade (GetActiveProject /
  GetCursorPosition / GetSelection) - no new OTA code, no new MCP tool (BR1).
  The facade already marshals every OTA call to the IDE main thread and
  sentinel-degrades on no-project / no-editor / any failure, so this provider
  simply maps the read records into the pure Core snapshot and never raises (BR5).

  The facade is injectable (constructor arg) so the mapping can be driven by a
  fake in isolation; the default path constructs the real OTA facade. This unit
  uses ToolsAPI (via the facade) and is never linked by the headless runner - the
  mapping is proven live (AC9) and the seam contract is proven headless via the
  Core stub test (AC5).
*)

interface

uses
  Aefos.MCP.Types,
  Aefos.OTA.Terminal.Core.ContextStrip;

type
  TOTAIDEContextProvider = class(TInterfacedObject, IIDEContextProvider)
  private
    FFacade: IMCPWorkspaceFacade;
  public
    /// <summary>Wraps <c>AFacade</c>, or constructs the real OTA-backed facade
    /// when <c>nil</c>. Consent timeout 0 / no audit path: this provider only
    /// ever calls read methods, which never request consent or audit.</summary>
    constructor Create(const AFacade: IMCPWorkspaceFacade = nil);
    /// <summary>Live IDE context, or a blank snapshot when nothing is open /
    /// any OTA read degrades. Never raises (BR5).</summary>
    function GetSnapshot: TIDEContextSnapshot;
  end;

implementation

uses
  Aefos.MCP.OTA.WorkspaceFacade;

constructor TOTAIDEContextProvider.Create(const AFacade: IMCPWorkspaceFacade);
begin
  inherited Create;
  if Assigned(AFacade) then
    FFacade := AFacade
  else
    FFacade := TMCPWorkspaceFacade.Create(0, '');
end;

function TOTAIDEContextProvider.GetSnapshot: TIDEContextSnapshot;
var
  LProject: TMCPActiveProjectInfo;
  LCursor: TMCPCursorInfo;
  LSelection: TMCPSelectionInfo;
begin
  Result := TIDEContextSnapshot.Empty;
  if not Assigned(FFacade) then
    Exit;
  try
    LProject := FFacade.GetActiveProject;
    if LProject.Available then
      Result.ProjectName := LProject.Name;

    LCursor := FFacade.GetCursorPosition;
    if LCursor.Available then
    begin
      Result.UnitPath := LCursor.UnitPath;
      Result.Line     := LCursor.Line;
      Result.Col      := LCursor.Column;
    end;

    LSelection := FFacade.GetSelection;
    if LSelection.Available then
      Result.SelLength := Length(LSelection.Text);
  except
    // Defence in depth - the facade already sentinel-degrades, but the strip
    // must never propagate an exception into the IDE main thread (BR5).
    Result := TIDEContextSnapshot.Empty;
  end;
end;

end.
