unit Aefos.OTA.Terminal.UI.ActionExec;

{
  Terminal action execution, extracted from the TAefosTerminalDockForm god-form as the
  first focused helper of the DockForm split (audit / form decomposition).

  Owns "run a saved terminal action by id": load the catalog (TActionStore), find the
  action, and run it through TActionRunner against the supplied ITerminalInput, with the
  confirm + placeholder-resolve callbacks. _ConfirmRun (a plain MessageDlg) and
  _ResolvePlaceholders (delegating to TAefosTerminalKeyBindingRegistry.ActionPlaceholderResolver, falling
  back to the Action Center) moved here VERBATIM — neither touches form state, so the
  executor is fully standalone (it takes the active terminal input as a parameter, NOT
  a back-reference to the form). The form keeps a thin _RunActionById shim that forwards
  to a refcounted-free FActionExecutor field.

  This is the safest first slice of the DockForm split: zero owned controls, no .dfm
  ties, no participation in the form's teardown sequence, and one inbound seam
  (ActiveTerminalInput). Reused by the new-tab menu, the actions sidebar and the
  command palette through the form's shim.
}

interface

uses
  System.Generics.Collections,
  Aefos.OTA.Terminal.Core.ActionRunner,
  Aefos.OTA.Terminal.Core.Actions;

type
  TTerminalActionExecutor = class
  private
    function _ConfirmRun(const AAction: TTerminalAction): Boolean;
    function _ResolvePlaceholders(const AAction: TTerminalAction;
      const ANames: TArray<string>;
      out AValues: TDictionary<string, string>): Boolean;
  public
    // Run the saved action with the given id against the active terminal input.
    // A blank id, an unknown id, or a user-cancelled run is a quiet no-op; a real
    // failure surfaces a warning dialog (same behaviour as the old form method).
    procedure RunById(const AActionId: string; const AInput: ITerminalInput);
  end;

implementation

uses
  System.SysUtils,
  System.UITypes,
  Vcl.Dialogs,
  Aefos.OTA.Terminal.Core.ActionStore,
  Aefos.OTA.Terminal.UI.ActionCenterView,
  Aefos.OTA.Terminal.UI.KeyBinding;

{ TTerminalActionExecutor }

procedure TTerminalActionExecutor.RunById(const AActionId: string;
  const AInput: ITerminalInput);
var
  LActionStore: TActionStore;
  LActionCatalog: TActionCatalog;
  LAction: TTerminalAction;
  LRunner: TActionRunner;
  LResult: TActionRunResult;
begin
  if AActionId = '' then Exit;

  LActionStore := TActionStore.Create;
  try
    LActionCatalog := LActionStore.LoadCatalog;
    try
      LAction := LActionCatalog.Find(AActionId);
      if Assigned(LAction) then
      begin
        LRunner := TActionRunner.Create;
        try
          LResult := LRunner.RunAction(LAction, AInput, _ConfirmRun, _ResolvePlaceholders);
          if not LResult.IsSuccess and (LResult.Outcome <> aroCancelled) then
            MessageDlg(LResult.Message, mtWarning, [mbOK], 0);
        finally
          LRunner.Free;
        end;
      end;
    finally
      LActionCatalog.Free;
    end;
  finally
    LActionStore.Free;
  end;
end;

function TTerminalActionExecutor._ConfirmRun(const AAction: TTerminalAction): Boolean;
begin
  Result := MessageDlg(Format('Run action "%s"?', [AAction.Name]),
    mtConfirmation, [mbYes, mbNo], 0) = mrYes;
end;

function TTerminalActionExecutor._ResolvePlaceholders(
  const AAction: TTerminalAction; const ANames: TArray<string>;
  out AValues: TDictionary<string, string>): Boolean;
begin
  Result := False;
  AValues := nil;
  if Assigned(Aefos.OTA.Terminal.UI.KeyBinding.TAefosTerminalKeyBindingRegistry.ActionPlaceholderResolver) then
    Result := Aefos.OTA.Terminal.UI.KeyBinding.TAefosTerminalKeyBindingRegistry.ActionPlaceholderResolver(AAction, ANames, AValues)
  else
  begin
    ShowAefosActionCenterView;
    if Assigned(Aefos.OTA.Terminal.UI.KeyBinding.TAefosTerminalKeyBindingRegistry.ActionPlaceholderResolver) then
      Result := Aefos.OTA.Terminal.UI.KeyBinding.TAefosTerminalKeyBindingRegistry.ActionPlaceholderResolver(AAction, ANames, AValues);
  end;
end;

end.
