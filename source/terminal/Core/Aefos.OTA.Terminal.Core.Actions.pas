unit Aefos.OTA.Terminal.Core.Actions;

{$IFDEF FPC}{$mode delphi}{$H+}{$ENDIF}

interface

uses
  {$IFDEF FPC}
  SysUtils, Classes, Generics.Collections;
  {$ELSE}
  System.SysUtils, System.Classes, System.Generics.Collections;
  {$ENDIF}

const
  /// <summary>
  /// Category an action is filed under when no explicit category is set.
  /// </summary>
  DEFAULT_ACTION_CATEGORY = 'General';

type
  /// <summary>
  /// Numeric keyboard-shortcut alias compatible with Vcl.Menus.TShortCut.
  /// Declared locally so the domain unit stays free of VCL imports
  /// (ADR-029-01). Defined as a plain Word alias (not <c>type Word</c>) so
  /// callers in the persistence / UI layer can convert against Word and
  /// Vcl.Menus.TShortCut without losing the dcc32 dotted-type-qualifier
  /// (`Vcl.Menus.TShortCut`) — that form does not parse as a type cast in
  /// dcc32 37.0. The ADR letter said <c>type Word</c>; the layering goals
  /// (no VCL in the domain unit, Word-compatible) are preserved.
  /// </summary>
  TShortCut = Word;

const
  /// <summary>
  /// Aefos.OTA.Terminal built-in shortcuts that user-defined actions are never allowed
  /// to override. Values mirror the ShortCut() calls in
  /// Aefos.OTA.Terminal.UI.KeyBinding.BindKeyboard: Ctrl+` (VK_OEM_3=192=$C0),
  /// Ctrl+Shift+Enter (VK_RETURN=13=$0D), Ctrl+Alt+A (Ord('A')=65=$41).
  /// TShortCut packing (Vcl.Menus): the low word carries the virtual-key code
  /// and the high word carries the shift mask
  /// (scShift=$2000, scCtrl=$4000, scAlt=$8000). Entry [2] swapped from
  /// Ctrl+Shift+A to Ctrl+Alt+A per ADR-054-02 (#87 collision fix).
  /// </summary>
  RESERVED_SHORTCUTS: array[0..2] of TShortCut = (
    TShortCut($4000 or 192),         // Ctrl+`            (scCtrl | VK_OEM_3)
    TShortCut($4000 or $2000 or 13), // Ctrl+Shift+Enter  (scCtrl | scShift | VK_RETURN)
    TShortCut($4000 or $8000 or 65)  // Ctrl+Alt+A        (scCtrl | scAlt | Ord('A'))
  );

type
  /// <summary>
  /// Aggregate result of a catalog import (ESP-031). All counters are zero on
  /// a parse/read failure; LastError carries a diagnostic message in that
  /// case. A successful import populates Added / Skipped / ShortcutsDropped
  /// and leaves LastError empty.
  /// </summary>
  TActionImportReport = record
    Added: Integer;
    Skipped: Integer;
    ShortcutsDropped: Integer;
    LastError: string;
  end;

  /// <summary>
  /// A named, categorized terminal action — a single command or a multi-line
  /// script the developer runs in the active terminal. Pure domain data, no
  /// VCL or UI dependency.
  /// </summary>
  TTerminalAction = class
  private
    FId: string;
    FName: string;
    FCategory: string;
    FDescription: string;
    FScriptLines: TArray<string>;
    FProfileName: string;
    FWorkingDir: string;
    FConfirmBeforeRun: Boolean;
    FShortcut: TShortCut;
    function _GetEffectiveCategory: string;
  public
    /// <summary>
    /// Returns True when the action has a non-empty name and at least one
    /// non-empty script line.
    /// </summary>
    function IsValid: Boolean;

    /// <summary>Stable identifier; assigned by the catalog when blank.</summary>
    property Id: string read FId write FId;
    /// <summary>Display name; unique within its effective category.</summary>
    property Name: string read FName write FName;
    /// <summary>Raw category; a blank value resolves to General.</summary>
    property Category: string read FCategory write FCategory;
    /// <summary>Free-form description of what the action does.</summary>
    property Description: string read FDescription write FDescription;
    /// <summary>Script lines sent, in order, to the terminal.</summary>
    property ScriptLines: TArray<string> read FScriptLines write FScriptLines;
    /// <summary>Optional shell profile the action is associated with.</summary>
    property ProfileName: string read FProfileName write FProfileName;
    /// <summary>Optional working directory hint.</summary>
    property WorkingDir: string read FWorkingDir write FWorkingDir;
    /// <summary>When True, the runner asks for confirmation before running.</summary>
    property ConfirmBeforeRun: Boolean read FConfirmBeforeRun write FConfirmBeforeRun;
    /// <summary>
    /// Optional IDE-wide keyboard shortcut bound to this action. A value of
    /// 0 means no binding. Uniqueness and reserved-value rules are enforced
    /// by TActionCatalog.Validate (ADR-029-01).
    /// </summary>
    property Shortcut: TShortCut read FShortcut write FShortcut;
    /// <summary>Category the action is grouped under; General when blank.</summary>
    property EffectiveCategory: string read _GetEffectiveCategory;
  end;

  /// <summary>
  /// In-memory catalog of terminal actions with validation and category
  /// grouping. Owns every action it holds.
  /// </summary>
  TActionCatalog = class
  private
    FActions: TObjectList<TTerminalAction>;
    function _IndexOfId(const AId: string): Integer;
    function _HasDuplicateName(const AAction: TTerminalAction): Boolean;
    function _HasDuplicateShortcut(const AAction: TTerminalAction;
      out AConflict: TTerminalAction): Boolean;
    function _ScriptHasContent(const AAction: TTerminalAction): Boolean;
    class function _IsReservedShortcut(const AShortcut: TShortCut): Boolean;
  public
    constructor Create;
    destructor Destroy; override;

    /// <summary>
    /// Validates AAction against the catalog rules. Returns False and an error
    /// message when the name is empty, no non-empty script line exists, or the
    /// name is duplicated within its category.
    /// </summary>
    function Validate(const AAction: TTerminalAction; out AError: string): Boolean;
    /// <summary>
    /// Adds AAction, taking ownership. Returns False — and frees AAction — when
    /// it is invalid or its id already exists. A blank id is generated.
    /// </summary>
    function Add(const AAction: TTerminalAction): Boolean;
    /// <summary>
    /// Replaces the entry sharing AAction's id, taking ownership of AAction.
    /// Returns False — and frees AAction — when invalid or the id is unknown.
    /// </summary>
    function Update(const AAction: TTerminalAction): Boolean;
    /// <summary>Removes the action with AId. Returns True when one was removed.</summary>
    function Remove(const AId: string): Boolean;
    /// <summary>Finds an action by id, or nil when none matches.</summary>
    function Find(const AId: string): TTerminalAction;

    /// <summary>
    /// Returns True when AShortcut is one of the Aefos.OTA.Terminal-reserved bindings
    /// (Ctrl+`, Ctrl+Shift+Enter, Ctrl+Alt+A). Exposed publicly so the
    /// import path (ESP-031) can resolve shortcut conflicts before calling
    /// Add. AShortcut = 0 is never reserved.
    /// </summary>
    class function IsReservedShortcut(const AShortcut: TShortCut): Boolean; static;

    /// <summary>
    /// Returns True when any action in the catalog already binds AShortcut.
    /// AShortcut = 0 always resolves to False. Exposed for the import path
    /// (ESP-031) so the conflict detection runs without re-implementing
    /// the catalog's private shortcut walk.
    /// </summary>
    function HasShortcut(const AShortcut: TShortCut): Boolean;

    /// <summary>Distinct effective categories, alphabetically sorted.</summary>
    function Categories: TArray<string>;
    /// <summary>Actions filed under ACategory, in insertion order.</summary>
    function ActionsInCategory(const ACategory: string): TArray<TTerminalAction>;
    /// <summary>Every action in the catalog, in insertion order.</summary>
    function AllActions: TArray<TTerminalAction>;
    /// <summary>Number of actions held.</summary>
    function Count: Integer;
  end;

implementation

{ TTerminalAction }

function TTerminalAction._GetEffectiveCategory: string;
begin
  Result := FCategory.Trim;
  if Result = '' then
    Result := DEFAULT_ACTION_CATEGORY;
end;

function TTerminalAction.IsValid: Boolean;
var
  LLine: string;
begin
  if FName.Trim = '' then
    Exit(False);
  for LLine in FScriptLines do
    if LLine.Trim <> '' then
      Exit(True);
  Result := False;
end;

{ TActionCatalog }

constructor TActionCatalog.Create;
begin
  inherited Create;
  FActions := TObjectList<TTerminalAction>.Create(True);
end;

destructor TActionCatalog.Destroy;
begin
  FActions.Free;
  inherited;
end;

function TActionCatalog._IndexOfId(const AId: string): Integer;
var
  LIndex: Integer;
begin
  for LIndex := 0 to FActions.Count - 1 do
    if FActions[LIndex].Id = AId then
      Exit(LIndex);
  Result := -1;
end;

function TActionCatalog._ScriptHasContent(const AAction: TTerminalAction): Boolean;
var
  LLine: string;
begin
  for LLine in AAction.ScriptLines do
    if LLine.Trim <> '' then
      Exit(True);
  Result := False;
end;

function TActionCatalog._HasDuplicateName(const AAction: TTerminalAction): Boolean;
var
  LExisting: TTerminalAction;
begin
  for LExisting in FActions do
  begin
    if LExisting.Id = AAction.Id then
      Continue;
    if SameText(LExisting.Name.Trim, AAction.Name.Trim) and
       SameText(LExisting.EffectiveCategory, AAction.EffectiveCategory) then
      Exit(True);
  end;
  Result := False;
end;

function TActionCatalog._HasDuplicateShortcut(const AAction: TTerminalAction;
  out AConflict: TTerminalAction): Boolean;
var
  LExisting: TTerminalAction;
begin
  AConflict := nil;
  if AAction.Shortcut = 0 then
    Exit(False);
  for LExisting in FActions do
  begin
    if LExisting.Id = AAction.Id then
      Continue;
    if LExisting.Shortcut = AAction.Shortcut then
    begin
      AConflict := LExisting;
      Exit(True);
    end;
  end;
  Result := False;
end;

class function TActionCatalog._IsReservedShortcut(
  const AShortcut: TShortCut): Boolean;
var
  LIndex: Integer;
begin
  if AShortcut = 0 then
    Exit(False);
  for LIndex := 0 to High(RESERVED_SHORTCUTS) do
    if RESERVED_SHORTCUTS[LIndex] = AShortcut then
      Exit(True);
  Result := False;
end;

class function TActionCatalog.IsReservedShortcut(
  const AShortcut: TShortCut): Boolean;
begin
  Result := _IsReservedShortcut(AShortcut);
end;

function TActionCatalog.HasShortcut(const AShortcut: TShortCut): Boolean;
var
  LExisting: TTerminalAction;
begin
  if AShortcut = 0 then
    Exit(False);
  for LExisting in FActions do
    if LExisting.Shortcut = AShortcut then
      Exit(True);
  Result := False;
end;

function TActionCatalog.Validate(const AAction: TTerminalAction;
  out AError: string): Boolean;
var
  LConflict: TTerminalAction;
begin
  AError := '';
  if not Assigned(AAction) then
  begin
    AError := 'The action is not assigned.';
    Exit(False);
  end;
  if AAction.Name.Trim = '' then
  begin
    AError := 'The action name cannot be empty.';
    Exit(False);
  end;
  if not _ScriptHasContent(AAction) then
  begin
    AError := 'The action must have at least one non-empty script line.';
    Exit(False);
  end;
  if _HasDuplicateName(AAction) then
  begin
    AError := Format('An action named "%s" already exists in category "%s".',
      [AAction.Name.Trim, AAction.EffectiveCategory]);
    Exit(False);
  end;
  // Numeric shortcut surfaces here; the UI rewrites the value to a display
  // string before showing it (ADR-029-01: catalog stays VCL-free).
  if _HasDuplicateShortcut(AAction, LConflict) then
  begin
    AError := Format('shortcut %d is already used by action "%s".',
      [AAction.Shortcut, LConflict.Name]);
    Exit(False);
  end;
  if _IsReservedShortcut(AAction.Shortcut) then
  begin
    AError := Format('shortcut %d is reserved by Aefos.OTA.Terminal.',
      [AAction.Shortcut]);
    Exit(False);
  end;
  Result := True;
end;

function TActionCatalog.Add(const AAction: TTerminalAction): Boolean;
var
  LError: string;
begin
  Result := False;
  if not Assigned(AAction) then
    Exit;

  if AAction.Id.Trim = '' then
    AAction.Id := TGUID.NewGuid.ToString;

  if (_IndexOfId(AAction.Id) >= 0) or not Validate(AAction, LError) then
  begin
    AAction.Free;
    Exit;
  end;

  FActions.Add(AAction);
  Result := True;
end;

function TActionCatalog.Update(const AAction: TTerminalAction): Boolean;
var
  LIndex: Integer;
  LError: string;
begin
  Result := False;
  if not Assigned(AAction) then
    Exit;

  LIndex := _IndexOfId(AAction.Id);
  if (LIndex < 0) or not Validate(AAction, LError) then
  begin
    AAction.Free;
    Exit;
  end;

  FActions[LIndex] := AAction;
  Result := True;
end;

function TActionCatalog.Remove(const AId: string): Boolean;
var
  LIndex: Integer;
begin
  LIndex := _IndexOfId(AId);
  Result := LIndex >= 0;
  if Result then
    FActions.Delete(LIndex);
end;

function TActionCatalog.Find(const AId: string): TTerminalAction;
var
  LIndex: Integer;
begin
  LIndex := _IndexOfId(AId);
  if LIndex >= 0 then
    Result := FActions[LIndex]
  else
    Result := nil;
end;

function TActionCatalog.Categories: TArray<string>;
var
  LList: TStringList;
  LAction: TTerminalAction;
begin
  LList := TStringList.Create;
  try
    LList.Sorted := True;
    LList.Duplicates := dupIgnore;
    LList.CaseSensitive := False;
    for LAction in FActions do
      LList.Add(LAction.EffectiveCategory);
    Result := LList.ToStringArray;
  finally
    LList.Free;
  end;
end;

function TActionCatalog.ActionsInCategory(
  const ACategory: string): TArray<TTerminalAction>;
var
  LResult: TList<TTerminalAction>;
  LAction: TTerminalAction;
  LCategory: string;
begin
  LCategory := ACategory.Trim;
  if LCategory = '' then
    LCategory := DEFAULT_ACTION_CATEGORY;

  LResult := TList<TTerminalAction>.Create;
  try
    for LAction in FActions do
      if SameText(LAction.EffectiveCategory, LCategory) then
        LResult.Add(LAction);
    Result := LResult.ToArray;
  finally
    LResult.Free;
  end;
end;

function TActionCatalog.AllActions: TArray<TTerminalAction>;
begin
  Result := FActions.ToArray;
end;

function TActionCatalog.Count: Integer;
begin
  Result := FActions.Count;
end;

end.


