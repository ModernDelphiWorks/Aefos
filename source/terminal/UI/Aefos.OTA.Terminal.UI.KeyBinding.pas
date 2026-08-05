unit Aefos.OTA.Terminal.UI.KeyBinding;

interface

{$I ..\Aefos.OTA.Terminal.inc}

uses
  ToolsAPI,
  System.SysUtils,
  Aefos.OTA.Terminal.Core.Actions,
  Aefos.OTA.Terminal.Core.ActionRunner;

type
  /// <summary>
  ///   Implements IOTAKeyboardBinding to register global keyboard shortcuts
  ///   for Aefos.OTA.Terminal: Toggle Terminal (Ctrl+`), Run Selection
  ///   (Ctrl+Shift+Enter), Toggle Action Center (Ctrl+Alt+A), plus one
  ///   entry per non-zero-shortcut action in the live TActionCatalog.
  ///   Handlers are declared in the implementation section to avoid the
  ///   TShortCut/TKeyBindingProc type-identity issue with designide.dcp.
  /// </summary>
  TAefosTerminalKeyBinding = class(TNotifierObject, IOTAKeyboardBinding)
  public
    { IOTAKeyboardBinding }
    function GetBindingType: TBindingType;
    function GetDisplayName: string;
    function GetName: string;
    procedure BindKeyboard(const ABindingServices: IOTAKeyBindingServices);
  end;

  /// <summary>
  ///   Pure-data row exposed to headless tests: one keybinding the BPL
  ///   intends to register. An empty <c>ActionId</c> marks a built-in
  ///   Aefos.OTA.Terminal shortcut whose handler is hard-coded; a non-empty
  ///   <c>ActionId</c> identifies a catalog-driven action that the dispatch
  ///   table forwards to via <c>HandleRunActionById</c>. Drives
  ///   <c>TAefosTerminalKeyBindingRegistry.BuildBindingSet</c> and AC8 (ADR-029-02).
  /// </summary>
  TBindingDescriptor = record
    Shortcut: TShortCut;
    ActionId: string;
    /// <summary>
    ///   Builds a descriptor in a single expression so
    ///   <c>BuildBindingSet</c> no longer reuses one mutable local and
    ///   overwrites it field-by-field per entry. Built-in shortcuts pass only
    ///   <c>AShortcut</c> (ActionId defaults to '' — the built-in marker);
    ///   catalog-driven entries pass both the shortcut and the action id.
    ///   The parameter is the raw <c>Word</c> domain (what <c>TShortCut</c>
    ///   aliases) so the interface/implementation signatures bind to one type:
    ///   the implementation's <c>uses Vcl.Menus</c> would otherwise rebind a
    ///   <c>TShortCut</c> parameter to a distinct named type under designide
    ///   (the same identity trap documented at the unit header) and raise E2037.
    /// </summary>
    class function Create(const AShortcut: Word;
      const AActionId: string = ''): TBindingDescriptor; static;
  end;

  /// <summary>
  ///   Static owner of Aefos.OTA.Terminal's global keyboard-binding lifecycle:
  ///   derives the binding set (<c>BuildBindingSet</c>), registers /
  ///   re-registers it against the live IDE (<c>Register</c>) and tears it down
  ///   (<c>Unregister</c>). The <c>AddKeyboardBinding</c> ⇄
  ///   <c>RemoveKeyboardBinding</c> pairing that <c>Register</c>/<c>Unregister</c>
  ///   drive is part of the IDE-unload contract — see CLAUDE.md.
  /// </summary>
  TAefosTerminalKeyBindingRegistry = class sealed
  private
    class var FActionPlaceholderResolver: TActionPlaceholderResolver;
  public
    /// <summary>
    ///   Derives the full keybinding set the BPL should register for ACatalog:
    ///   the three built-in Aefos.OTA.Terminal shortcuts (Ctrl+`, Ctrl+Shift+Enter,
    ///   Ctrl+Alt+A — ActionId empty) plus one entry per action whose
    ///   <c>Shortcut</c> is non-zero (ActionId = action.Id). Pure function: no
    ///   OTA, no VCL, safe to call from headless tests (ADR-029-02).
    /// </summary>
    class function BuildBindingSet(
      const ACatalog: TActionCatalog): TArray<TBindingDescriptor>; static;

    /// <summary>
    ///   Registers (or re-registers) Aefos.OTA.Terminal's keyboard bindings against the
    ///   live IDE. The previous registration, if any, is removed first so the
    ///   IDE picks up the updated set (OTA caches BindKeyboard's result, so a
    ///   remove-then-add cycle is the documented refresh pattern,
    ///   ADR-029-02). The catalog reference is stored module-scope so
    ///   <c>HandleRunActionById</c> can resolve action ids at fire time; the
    ///   caller retains ownership of ACatalog.
    /// </summary>
    class procedure Register(const ACatalog: TActionCatalog); static;

    /// <summary>
    ///   Removes Aefos.OTA.Terminal's keyboard bindings from the live IDE and drops the
    ///   module-scope catalog reference. Safe to call when no binding is
    ///   currently registered.
    /// </summary>
    class procedure Unregister; static;

    /// <summary>
    ///   Unit-level bridge that lets <c>HandleRunActionById</c> reach the
    ///   Action Center view's placeholder-prompt dialog without the keybinding
    ///   handler taking a dependency on the view (ADR-030-02). The view sets
    ///   this in its constructor and clears it in its destructor; consumers
    ///   must tolerate a <c>nil</c> read (treated as "no resolver available"
    ///   by <c>TActionRunner.RunAction</c>, which surfaces <c>aroCancelled</c>).
    /// </summary>
    class property ActionPlaceholderResolver: TActionPlaceholderResolver
      read FActionPlaceholderResolver write FActionPlaceholderResolver;
  end;

implementation

uses
  Vcl.Menus,
  System.Classes,
  System.Generics.Collections,
  Winapi.Windows,
  Aefos.OTA.Terminal.UI.DockForm,
  Aefos.OTA.Terminal.UI.ActionCenterView;

// ---------------------------------------------------------------------------
//  Handler helper — declared in implementation to avoid the TShortCut /
//  TKeyBindingProc type-identity mismatch that arises when Vcl.Menus is
//  referenced from the interface section while designide.dcp provides its
//  own embedded copy of the same unit.
// ---------------------------------------------------------------------------
type
  TAefosTerminalKeyBindingHandler = class
  private
    function _GetEditorSelection: string;
    function _GetCurrentLine: string;
  public
    procedure HandleToggleTerminal(const AContext: IOTAKeyContext;
      AKeyCode: TShortCut; var ABindingResult: TKeyBindingResult);
    procedure HandleRunSelection(const AContext: IOTAKeyContext;
      AKeyCode: TShortCut; var ABindingResult: TKeyBindingResult);
    procedure HandleToggleActionCenter(const AContext: IOTAKeyContext;
      AKeyCode: TShortCut; var ABindingResult: TKeyBindingResult);
    procedure HandleRunActionById(const AContext: IOTAKeyContext;
      AKeyCode: TShortCut; var ABindingResult: TKeyBindingResult);
  end;

var
  GHandler: TAefosTerminalKeyBindingHandler;
  GShortcutToActionId: TDictionary<Word, string>;
  // Weak reference to the catalog whose shortcuts are currently registered;
  // owned by the wizard / Action Center view, not by this unit.
  GLiveCatalog: TActionCatalog;
  // Index returned by IOTAKeyboardServices.AddKeyboardBinding on the most
  // recent Register call. -1 means "no binding currently registered".
  GCurrentBindingIndex: Integer = -1;

{ TBindingDescriptor }

class function TBindingDescriptor.Create(const AShortcut: Word;
  const AActionId: string): TBindingDescriptor;
begin
  Result.Shortcut := AShortcut;
  Result.ActionId := AActionId;
end;

{ TAefosTerminalKeyBindingRegistry }

class function TAefosTerminalKeyBindingRegistry.BuildBindingSet(
  const ACatalog: TActionCatalog): TArray<TBindingDescriptor>;
var
  LList: TList<TBindingDescriptor>;
  LAction: TTerminalAction;
begin
  LList := TList<TBindingDescriptor>.Create;
  try
    // Built-ins first — keep ActionId empty (the factory default) so the IDE
    // dispatcher and tests can distinguish them from catalog-driven entries.
    LList.Add(TBindingDescriptor.Create(RESERVED_SHORTCUTS[0])); // Ctrl+`
    LList.Add(TBindingDescriptor.Create(RESERVED_SHORTCUTS[1])); // Ctrl+Shift+Enter
    LList.Add(TBindingDescriptor.Create(RESERVED_SHORTCUTS[2])); // Ctrl+Alt+A

    if Assigned(ACatalog) then
      for LAction in ACatalog.AllActions do
        if LAction.Shortcut <> 0 then
          LList.Add(TBindingDescriptor.Create(LAction.Shortcut, LAction.Id));

    Result := LList.ToArray;
  finally
    LList.Free;
  end;
end;

class procedure TAefosTerminalKeyBindingRegistry.Register(const ACatalog: TActionCatalog);
var
  LKeyboardServices: IOTAKeyboardServices;
begin
  if not Supports(BorlandIDEServices, IOTAKeyboardServices, LKeyboardServices) then
    Exit;
  if GCurrentBindingIndex >= 0 then
  begin
    LKeyboardServices.RemoveKeyboardBinding(GCurrentBindingIndex);
    GCurrentBindingIndex := -1;
  end;
  GLiveCatalog := ACatalog;
  // Guard against "duplicate keybinding" raised when a previous package load
  // did not remove the binding (e.g. wizard destructor skipped because
  // RemoveWizard threw during reinstall — issue #33). The finalization
  // backstop below handles the normal path; this catch prevents the IDE from
  // showing an error dialog on the rare reinstall-without-IDE-restart path.
  try
    GCurrentBindingIndex :=
      LKeyboardServices.AddKeyboardBinding(TAefosTerminalKeyBinding.Create);
  except
    on E: Exception do
      OutputDebugString(PChar('Aefos.OTA.Terminal: AddKeyboardBinding failed - '
        + E.ClassName + ': ' + E.Message));
  end;
end;

class procedure TAefosTerminalKeyBindingRegistry.Unregister;
var
  LKeyboardServices: IOTAKeyboardServices;
begin
  if (GCurrentBindingIndex >= 0) and
     Supports(BorlandIDEServices, IOTAKeyboardServices, LKeyboardServices) then
    LKeyboardServices.RemoveKeyboardBinding(GCurrentBindingIndex);
  GCurrentBindingIndex := -1;
  GLiveCatalog := nil;
  if Assigned(GShortcutToActionId) then
    GShortcutToActionId.Clear;
end;

{ TAefosTerminalKeyBinding }

function TAefosTerminalKeyBinding.GetBindingType: TBindingType;
begin
  Result := btPartial;
end;

function TAefosTerminalKeyBinding.GetDisplayName: string;
begin
  Result := 'Aefos.OTA.Terminal';
end;

function TAefosTerminalKeyBinding.GetName: string;
begin
  Result := 'Aefos.OTA.Terminal.UI.KeyBindings';
end;

procedure TAefosTerminalKeyBinding.BindKeyboard(const ABindingServices: IOTAKeyBindingServices);
var
  LDescriptors: TArray<TBindingDescriptor>;
  LDesc: TBindingDescriptor;
begin
  // Ctrl+` (backtick — VK_OEM_3 = 192) — Toggle Terminal
  ABindingServices.AddKeyBinding(
    [ShortCut(VK_OEM_3, [ssCtrl])],
    GHandler.HandleToggleTerminal,
    nil
  );
  // Ctrl+Shift+Enter — Run Selection
  ABindingServices.AddKeyBinding(
    [ShortCut(VK_RETURN, [ssCtrl, ssShift])],
    GHandler.HandleRunSelection,
    nil
  );
  // Ctrl+Alt+A — Toggle Action Center (ADR-054-02: swapped from
  // Ctrl+Shift+A to avoid Windows-level screen-capture chord collision, #87).
  ABindingServices.AddKeyBinding(
    [ShortCut(Ord('A'), [ssCtrl, ssAlt])],
    GHandler.HandleToggleActionCenter,
    nil
  );

  // Per-action shortcuts from the live catalog. BuildBindingSet also returns
  // the three built-ins (ActionId empty) for parity with AC8; skip them here
  // since the dedicated handlers above already own them.
  GShortcutToActionId.Clear;
  if not Assigned(GLiveCatalog) then
    Exit;
  LDescriptors := TAefosTerminalKeyBindingRegistry.BuildBindingSet(GLiveCatalog);
  for LDesc in LDescriptors do
  begin
    if LDesc.ActionId = '' then
      Continue;
    // TShortCut in implementation scope resolves to Vcl.Menus.TShortCut (last
    // uses entry); the cast widens the domain Word alias to AddKeyBinding's
    // parameter type without invoking the dotted-qualifier syntax that dcc32
    // 37.0 refuses for type names.
    ABindingServices.AddKeyBinding(
      [TShortCut(LDesc.Shortcut)],
      GHandler.HandleRunActionById,
      nil
    );
    GShortcutToActionId.AddOrSetValue(Word(LDesc.Shortcut), LDesc.ActionId);
  end;
end;

{ TAefosTerminalKeyBindingHandler }

procedure TAefosTerminalKeyBindingHandler.HandleToggleTerminal(
  const AContext: IOTAKeyContext; AKeyCode: TShortCut;
  var ABindingResult: TKeyBindingResult);
var
  LDockForm: TAefosTerminalDockForm;
begin
  ABindingResult := krHandled;
  LDockForm := AefosTerminalDockForm;
  if not Assigned(LDockForm) then
  begin
    ShowAefosTerminalDockForm;
    Exit;
  end;
  if not IsConsole then
  begin
    if LDockForm.Visible then
      LDockForm.Hide
    else
      LDockForm.Show;
  end;
end;

procedure TAefosTerminalKeyBindingHandler.HandleRunSelection(
  const AContext: IOTAKeyContext; AKeyCode: TShortCut;
  var ABindingResult: TKeyBindingResult);
var
  LText: string;
  LDockForm: TAefosTerminalDockForm;
begin
  ABindingResult := krHandled;
  LText := _GetEditorSelection;
  if LText = '' then
    LText := _GetCurrentLine;

  LDockForm := AefosTerminalDockForm;
  if not Assigned(LDockForm) then
  begin
    ShowAefosTerminalDockForm;
    LDockForm := AefosTerminalDockForm;
  end;
  if Assigned(LDockForm) then
    LDockForm.SendCommandToActivePane(LText);
end;

procedure TAefosTerminalKeyBindingHandler.HandleToggleActionCenter(
  const AContext: IOTAKeyContext; AKeyCode: TShortCut;
  var ABindingResult: TKeyBindingResult);
begin
  ABindingResult := krHandled;
  ToggleActionCenterView;
end;

procedure TAefosTerminalKeyBindingHandler.HandleRunActionById(
  const AContext: IOTAKeyContext; AKeyCode: TShortCut;
  var ABindingResult: TKeyBindingResult);
var
  LActionId: string;
  LAction: TTerminalAction;
  LRunner: TActionRunner;
begin
  // Always mark krHandled — even when no live catalog or no matching action
  // — to stay consistent with the existing built-in handlers and avoid the
  // IDE re-dispatching the keystroke to another binding silently. Mirrors
  // the "silent no-op when terminal not available" pattern of HandleRunSelection.
  ABindingResult := krHandled;
  if not Assigned(GLiveCatalog) then
    Exit;
  if not Assigned(GShortcutToActionId) or
     not GShortcutToActionId.TryGetValue(Word(AKeyCode), LActionId) then
    Exit;
  LAction := GLiveCatalog.Find(LActionId);
  if not Assigned(LAction) then
    Exit;
  LRunner := TActionRunner.Create;
  try
    LRunner.RunAction(LAction, AefosOTATerminalActiveTerminalInput, nil,
      TAefosTerminalKeyBindingRegistry.ActionPlaceholderResolver);
  finally
    LRunner.Free;
  end;
end;

function TAefosTerminalKeyBindingHandler._GetEditorSelection: string;
var
  LEditorServices: IOTAEditorServices;
  LTopView: IOTAEditView;
  LBlock: IOTAEditBlock;
begin
  Result := '';
  if not Supports(BorlandIDEServices, IOTAEditorServices, LEditorServices) then
    Exit;
  LTopView := LEditorServices.TopView;
  if not Assigned(LTopView) then
    Exit;
  LBlock := LTopView.GetBlock;
  if not Assigned(LBlock) then
    Exit;
  if (LBlock.StartingRow <> LBlock.EndingRow) or
     (LBlock.StartingColumn <> LBlock.EndingColumn) then
    Result := LBlock.Text;
end;

function TAefosTerminalKeyBindingHandler._GetCurrentLine: string;
var
  LEditorServices: IOTAEditorServices;
  LTopView: IOTAEditView;
  LEditPos: TOTAEditPos;
  LCharPos: TOTACharPos;
  LStartPos: Longint;
  LReader: IOTAEditReader;
  LBuf: array[0..4095] of AnsiChar;
  LLen: Longint;
  LCrPos: Integer;
  LLfPos: Integer;
begin
  Result := '';
  if not Supports(BorlandIDEServices, IOTAEditorServices, LEditorServices) then
    Exit;
  LTopView := LEditorServices.TopView;
  if not Assigned(LTopView) then
    Exit;

  // Convert edit pos to buffer char pos (EdPosToCharPos = True)
  LEditPos := LTopView.CursorPos;
  LTopView.ConvertPos(True, LEditPos, LCharPos);

  // Move to beginning of the current line and get file position
  LCharPos.CharIndex := 0;
  LStartPos := LTopView.CharPosToPos(LCharPos);

  LReader := LTopView.Buffer.CreateReader;
  if not Assigned(LReader) then
    Exit;

  // Read up to 4 KB from line start
  LLen := LReader.GetText(LStartPos, @LBuf[0], SizeOf(LBuf) - 1);
  if LLen <= 0 then
    Exit;
  LBuf[LLen] := #0;

  Result := string(AnsiString(@LBuf[0]));

  // Trim to end of first line
  LCrPos := Pos(#13, Result);
  if LCrPos > 0 then
    Result := Copy(Result, 1, LCrPos - 1);
  LLfPos := Pos(#10, Result);
  if LLfPos > 0 then
    Result := Copy(Result, 1, LLfPos - 1);
  Result := Trim(Result);
end;

initialization
  GHandler := TAefosTerminalKeyBindingHandler.Create;
  GShortcutToActionId := TDictionary<Word, string>.Create;

finalization
  // Backstop: if TAefosTerminalWizard.Destroy did not run (e.g. RemoveWizard raised
  // and swallowed the exception, leaving the wizard's refcount > 0 — issue #33),
  // the binding is still live in the IDE and GCurrentBindingIndex is still valid.
  // Remove it here before GHandler is freed so no dangling callbacks remain.
  // When the wizard destructor ran normally, GCurrentBindingIndex is already -1
  // and this is a safe no-op.
  TAefosTerminalKeyBindingRegistry.Unregister;
  TAefosTerminalKeyBindingRegistry.ActionPlaceholderResolver := nil;
  FreeAndNil(GShortcutToActionId);
  FreeAndNil(GHandler);

end.




