unit Aefos.OTA.Chat.Adapter.AgentSuggest;

{
  Adapter for the "Suggest from Selection" keyboard shortcut (ESP-008,
  demand 4/5).

  Registers Ctrl+Alt+F10 via IOTAKeyBindingServices, reads the active
  editor selection via IOTAEditBlock.Text, and delegates to ICommandExecutor
  with the hardcoded command name 'suggest' (BR-1). Empty selection short-circuits
  via IOutputPanelSurface.ReportError(ENoSelection).

  Per ADR-017 the legacy agent-service surface is gone; this unit no longer
  imports the legacy service nor UI.AgentStatus. The pure helper
  TAefosAgentSuggestAdapter.ReadSelectionText is a static class method so DUnit
  can cover the empty/non-empty branches without a live RAD Studio environment.

  No exception escapes the dispatch: every Exception thrown through the
  executor is caught and forwarded to IOutputPanelSurface.ReportError.

  TEARDOWN MODEL (mirrors the Terminal BPL's TAefosTerminalKeyBinding —
  the structurally clean pattern that never crashes on unload): the binding
  object is owned SOLELY by the IDE (handed over via AddKeyboardBinding). We
  keep ONLY the integer index — never a raw pointer to the object — and never
  write into the object after creation. The executor/surface live in module
  vars resolved lazily at trigger time, so the binding holds no refs that need
  early teardown. This removes the use-after-free the old design caused: it
  stored a raw GBinding pointer and ClearAgentSuggestSurface wrote into it, but
  the IDE's TKeyboardServices.UnInstallingPackage frees the binding on package
  unload -> the raw pointer dangled -> "block modified after freed" / FastMM.
}

interface

uses
  System.SysUtils,
  System.Classes,
  Vcl.Menus,
  ToolsAPI,
  Aefos.OTA.Chat.Core.CommandExecutor,
  Aefos.OTA.Chat.UI.OutputPanel.Edge;

const
  DefaultShortcutText = 'Ctrl+Alt+F10';
  BindingDisplayName  = 'Aefos Suggest from Selection';
  BindingName         = 'Aefos.CommandExecutor.Suggest';

type
  // Stateless IOTAKeyboardBinding (Terminal pattern). Holds NO executor/surface
  // refs and no back-pointer to module state; resolves the current executor and
  // surface from module vars at shortcut time. The IDE owns this object.
  TAefosAgentKeyboardBinding = class(TNotifierObject, IOTAKeyboardBinding)
  protected
    procedure _HandleShortcut(const AContext: IOTAKeyContext;
      AKeyCode: TShortcut; var ABindingResult: TKeyBindingResult);
  public
    function GetBindingType: TBindingType;
    function GetDisplayName: string;
    function GetName: string;
    procedure BindKeyboard(const ABindingServices: IOTAKeyBindingServices);
  end;

type
  // Sealed static namespace for the Suggest-from-Selection composition-root
  // entry points (were loose interface routines nobody owned). Never
  // instantiated. Method bodies, the GExecutor/GSurface/GKeyboardBindingIndex
  // module vars and the AddKeyboardBinding/RemoveKeyboardBinding teardown are
  // byte-frozen (UnloadContract — THE LAW); the call sites in Register.pas and
  // this unit's finalization change by NAME QUALIFICATION only.
  TAefosAgentSuggestAdapter = class sealed
  public
    class function ReadSelectionText(const AView: IOTAEditView): string; static;
    class procedure RegisterSelf(const AExecutor: ICommandExecutor;
      const ASurface: IOutputPanelSurface); static;
    class procedure UnregisterSelf; static;
    class procedure ClearAgentSuggestSurface; static;
  end;

implementation

uses
  Winapi.Windows,
  Aefos.OTA.Chat.Core.AgentSuggest;

var
  // Terminal-pattern lifetime: keep ONLY the index. The binding object is owned
  // by the IDE — there is no raw object pointer to dangle on unload. The executor
  // and surface are module refs, resolved lazily at trigger time.
  GKeyboardBindingIndex: Integer = -1;
  GExecutor: ICommandExecutor = nil;
  GSurface: IOutputPanelSurface = nil;

class function TAefosAgentSuggestAdapter.ReadSelectionText(const AView: IOTAEditView): string;
var
  LBlock: IOTAEditBlock;
begin
  Result := '';
  if not Assigned(AView) then
    Exit;
  LBlock := AView.Block;
  if not Assigned(LBlock) then
    Exit;
  Result := LBlock.Text;
end;

// Shared trigger for BOTH the keyboard shortcut and the menu action. Resolves
// the executor/surface from module state — no binding-object pointer involved.
procedure _DoSuggestFromActiveEditor;
var
  LEditorServices: IOTAEditorServices;
  LView: IOTAEditView;
  LSelection: string;
begin
  if not (Assigned(GExecutor) and Assigned(GSurface)) then
    Exit;
  LEditorServices := BorlandIDEServices as IOTAEditorServices;
  if not Assigned(LEditorServices) then
  begin
    GSurface.Show;
    GSurface.ReportError(Exception.Create('No active editor services'));
    Exit;
  end;
  LView := LEditorServices.TopView;
  if not Assigned(LView) then
  begin
    GSurface.Show;
    GSurface.ReportError(Exception.Create('No active editor view'));
    Exit;
  end;
  LSelection := TAefosAgentSuggestAdapter.ReadSelectionText(LView);
  DispatchSuggest(GExecutor, GSurface, LSelection);
end;

class procedure TAefosAgentSuggestAdapter.RegisterSelf(const AExecutor: ICommandExecutor;
  const ASurface: IOutputPanelSurface);
var
  LServices: IOTAKeyboardServices;
begin
  if not Assigned(AExecutor) then
    raise EArgumentNilException.Create(
      'RegisterSelf requires a non-nil ICommandExecutor');
  if not Assigned(ASurface) then
    raise EArgumentNilException.Create(
      'RegisterSelf requires a non-nil IOutputPanelSurface');
  // Refresh the module refs every call (e.g. on a runtime executor switch).
  GExecutor := AExecutor;
  GSurface := ASurface;
  // The binding is handed to the IDE exactly once; later calls only refresh refs.
  if GKeyboardBindingIndex >= 0 then
    Exit;
  LServices := BorlandIDEServices as IOTAKeyboardServices;
  if not Assigned(LServices) then
    Exit;
  try
    // Create inline and give ownership to the IDE. We keep ONLY the index — no
    // pointer to the object survives this call (Terminal pattern).
    GKeyboardBindingIndex :=
      LServices.AddKeyboardBinding(TAefosAgentKeyboardBinding.Create);
  except
    on E: Exception do
      OutputDebugString(PChar('[Aefos] RegisterSelf AgentSuggest keyboard binding failed: ' + E.Message));
  end;
end;

class procedure TAefosAgentSuggestAdapter.UnregisterSelf;
var
  LServices: IOTAKeyboardServices;
begin
  // *** BEFORE CHANGING THIS: read Aefos.OTA.Chat.UnloadContract (the law). ***
  // Explicitly remove the binding (Terminal pattern — the proven-clean one).
  // Map forensics (2026-06-11): relying on the IDE's package-unload cleanup is
  // WRONG — the IDE releases the binding object only AFTER the BPL unmaps, so
  // TObject.Free reads TAefosAgentKeyboardBinding's dead VMT (AV at
  // rtl370+100C2, RVA 0x16A44 in this BPL) and the aborted unload locks the
  // .bpl (the chronic rebuild F2039). The Terminal BPL removes its binding
  // explicitly at teardown and unloads clean; do the same. Guarded so a
  // binding the IDE already dropped never aborts teardown.
  if (GKeyboardBindingIndex >= 0) and
     Supports(BorlandIDEServices, IOTAKeyboardServices, LServices) then
    try
      LServices.RemoveKeyboardBinding(GKeyboardBindingIndex);
    except
      on E: Exception do
        OutputDebugString(PChar(
          '[Aefos] AgentSuggest RemoveKeyboardBinding: ' + E.Message));
    end;
  GExecutor := nil;
  GKeyboardBindingIndex := -1;
end;

class procedure TAefosAgentSuggestAdapter.ClearAgentSuggestSurface;
begin
  // Drop the surface ref WITHOUT calling _Release: during finalization GOutputPanel
  // may already be freed, so a normal release would _Release a dead object. The raw
  // cast clears the slot without touching the (possibly freed) instance.
  if Assigned(GSurface) then
    Pointer(GSurface) := nil;
end;

function TAefosAgentKeyboardBinding.GetBindingType: TBindingType;
begin
  Result := btPartial;
end;

function TAefosAgentKeyboardBinding.GetDisplayName: string;
begin
  Result := BindingDisplayName;
end;

function TAefosAgentKeyboardBinding.GetName: string;
begin
  Result := BindingName;
end;

procedure TAefosAgentKeyboardBinding.BindKeyboard(
  const ABindingServices: IOTAKeyBindingServices);
begin
  ABindingServices.AddKeyBinding([TextToShortCut(DefaultShortcutText)],
    _HandleShortcut, nil);
end;

procedure TAefosAgentKeyboardBinding._HandleShortcut(
  const AContext: IOTAKeyContext; AKeyCode: TShortcut;
  var ABindingResult: TKeyBindingResult);
begin
  ABindingResult := krHandled;
  _DoSuggestFromActiveEditor;
end;

initialization

finalization
  // Guarded: an exception escaping finalization aborts the IDE's BPL unload.
  try
    TAefosAgentSuggestAdapter.UnregisterSelf;
  except // NOSONAR — teardown must never raise.
    on E: Exception do
      OutputDebugString(PChar(
        'Aefos teardown [AgentSuggest.finalization]: '
        + E.ClassName + ' - ' + E.Message));
  end;

end.
