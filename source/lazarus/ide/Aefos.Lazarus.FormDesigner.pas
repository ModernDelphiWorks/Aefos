unit Aefos.Lazarus.FormDesigner;

{ Aefos AI - Lazarus edition: LIVE FORM DESIGNER engine (Phase J).

  The Lazarus twin of the Delphi form-designer service
  (source\mcp\OTA\Aefos.MCP.OTA.FormDesignerService.pas). It is the product's
  biggest moat: an AI agent adds a component and it SPROUTS live in the Lazarus
  Form Designer, and the IDE declares the published field in the .pas - exactly
  like the RAD Studio side, only on the IDEIntf/designer seams instead of OTA.

  The semantics follow the Delphi service; only the seams change (and every FMX
  branch is DELETED - Lazarus has no FMX, so the ActivateClassGroup class-group
  gotcha and the TAlphaColor 'xAARRGGBB' recovery become dead code, per
  meta\lazarus-port\02-designer.md).

  DIVERGENCES from a 1:1 port of TDesigner.AddComponent (designer.pp:703),
  disclosed after an adversarial review (2026-07-16) - each is a deliberate,
  seam-forced choice, NOT an oversight:
    * PALETTE-ONLY class resolution. TMainIDE.PropHookPersistentAdded
      (main.pp:13297) writes the published .pas field ONLY when the class is on
      the IDE component palette (FindRegComponent) or is a project component
      class; an RTL Classes.GetClass-resolved class gets NO field. So a GetClass
      fallback would create an orphan control and report a phantom success -
      AddComponent therefore rejects a non-palette class ('class-not-registered')
      rather than trust GetClass.
    * The native AddComponent's TheFormEditor.ClassDependsOnComponent (cycle
      reject) and TheFormEditor.FixupReferences (frame->datamodule cross-refs)
      live on the IDE-internal TCustomFormEditor (customformeditor.pp) - they are
      NOT on the public TAbstractFormEditor that this IDEIntf-only design package
      is allowed to reference, so they are DEFERRED. Mitigation: with palette-only
      resolution the agent adds standard controls, not frame/datamodule classes,
      so the frame-cycle / cross-ref paths those two guard are not reached; a bad
      cross-reference would still surface at compile. The reachable half of the
      native safety - PropertyEditorHook.BeforeAddPersistent (add-veto,
      propedits.pp:6700 / main.pp:13223) and the csSetCaption blank-caption
      mirror (designer.pp:755) and AddUndoAction (Ctrl+Z parity,
      componenteditors.pas:95) - IS performed.

  Seams:

    Get designer   : LazarusIDE.GetDesignerForProjectEditor(editor, LoadForm:=
                     False) (lazideintf.pas:447) -> TIDesigner, cast to
                     TComponentEditorDesigner (componenteditors.pas:57). The
                     designed root is the designer's own Form (componenteditors
                     .pas:111), so we never depend on the GLOBAL hook's active
                     LookupRoot being the target unit.
    Property hook  : TComponentEditorDesigner.PropertyEditorHook (== the
                     GlobalDesignHook, propedits.pp:1794) drives every notify.
    AddComponent   : FormEditingHook.CreateComponent(parent, class, '', L,T,W,H,
                     True) (formeditingintf.pas:216) creates the native control +
                     JIT class; then hook.PersistentAdded(comp, True)
                     (propedits.pp:1490) fires TMainIDE.PropHookPersistentAdded
                     (main.pp:13285), which writes the published field to the
                     .pas via CodeTools. This is the exact split TDesigner
                     .AddComponent uses (designer.pp:703: CreateComponent then
                     NotifyComponentAdded -> PersistentAdded), replicated so the
                     control gets the caller's NAME before the field is written
                     (NotifyComponentAdded keeps a non-empty Name - designer.pp
                     :1639), instead of the palette drop's auto Button1.
    RemoveComponent: hook.DeletePersistent(var persistent) (propedits.pp:1493) -
                     frees the control AND drops its published field.
    SetProperty    : classic System.TypInfo RTTI on the live component (dotted
                     path walk ported from the Delphi _LiveSetPublishedProp),
                     then hook.Modified(target) (propedits.pp:1509) -> OI refresh
                     + .lfm dirty + re-render in place.
    AddEventHandler: hook.CreateMethod(name, typeinfo, persistent, path)
                     (propedits.pp:1458) writes the wired handler into the
                     published section via CodeTools AND yields a TMethod;
                     SetMethodProp wires the .lfm event; hook.Modified commits;
                     LazarusIDE.DoShowMethod(editor, name) (lazideintf.pas:455)
                     jumps to it - the designer double-click, one to one.
    Live read      : WriteComponentAsTextToStream serializes the LIVE form to
                     .lfm text (reflects unsaved edits - Caption a SetProperty
                     just applied), the analog of the Delphi _TryReadLiveFormDfm.
    Capture        : LCL TCustomForm.GetFormImage (forms.pp:647) -> PNG base64.

  RULE #1 (INTENT->VIEW, CLAUDE.md): every DESIGN mutation EnsureDesignView and
  ENDS in Design - it brings the unit's Form Designer to the front via
  LazarusIDE.DoShowDesignerFormOfSrc(editor) (lazideintf.pas:454) so the user
  watches it flip and the mutation lands on the Designer. The server-side view
  guard (facade.CurrentIdeViewIntent, the designer-EXISTENCE rewrite) already
  rejected a design command sent with no live designer BEFORE we get here; this
  is the "end in Design" polish, and view-switch is exempt from the guard.

  Threading: the Lazarus IDE is single-threaded. These methods run on the IDE
  main thread (the MCP host marshals server->main once; the facade calls straight
  through) - so, unlike the Delphi service, there is NO TThread.Synchronize hop
  here.

  Boundary: this unit is LCL/IDEIntf glue, so it compiles in mode delphi - its
  `string` is the UTF-8 AnsiString every LCL/IDEIntf API speaks. The facade
  (Aefos.Lazarus.WorkspaceFacade, delphiunicode) converts UnicodeString<->UTF-8
  at its boundary (_ToLcl/_FromLcl) before/after calling here, exactly as it
  already does for the editor-write slice. All literals are ASCII, so the file
  needs no BOM. No loose routines (static-class namespace); no inline var; L/A
  prefixes; English-only, vendor-neutral. }

{$mode delphi}
{$H+}

interface

uses
  Classes,
  SysUtils;

type
  { Live-designer engine as a sealed static namespace (never instantiated) - the
    Lazarus twin of TMCPFormDesignerService. Every method runs on the IDE main
    thread and speaks UTF-8 `string` (the LCL convention); the facade converts at
    its UnicodeString boundary. AReason carries a machine-actionable code on
    failure (mirrors the Delphi service's reason codes) and is '' on success. }
  TAefosLazFormDesigner = class sealed
  public
    // Creates AComponentClass live under AParent (or the form) and lets the IDE
    // declare the published field in the .pas. Ends in Design. AComponentName
    // renames the control BEFORE the field is written (so the field carries it).
    class function AddComponent(const AUnitName, AComponentClass,
      AComponentName, AParent: string;
      const ALeft, ATop, AWidth, AHeight: Integer;
      out AReason: string): Boolean; static;
    // Frees the live control and drops its published field (DeletePersistent).
    class function RemoveComponent(const AUnitName, AComponentName: string;
      out AReason: string): Boolean; static;
    // RTTI set on the live component (dotted path supported); designer re-renders.
    class function SetComponentProperty(const AUnitName, AComponentName,
      APropName, APropValue: string; out AReason: string): Boolean; static;
    // RTTI set on the live form root.
    class function SetFormProperty(const AUnitName, APropName,
      APropValue: string; out AReason: string): Boolean; static;
    // Atomic event wire: creates the handler in the published section AND wires
    // the .lfm event, then jumps to the handler (the designer double-click).
    class function AddEventHandler(const AUnitName, AComponentName, AEventName,
      AHandlerName, ABody: string; out AReason: string): Boolean; static;
    // Design read: serialize the LIVE form (with unsaved edits) to .lfm text.
    // False when the unit has no live designer (caller falls back to disk).
    class function GetLiveFormLfm(const AUnitName: string;
      out ALfmText: string): Boolean; static;
    // Agent vision: render the live form to a PNG (base64 + a temp file path).
    class function CaptureActiveFormPng(const AUnitName: string;
      out ABase64, APngPath, AReason: string): Boolean; static;
    // View-switch (RULE #1 exempt): bring/create the unit's Form Designer to the
    // front (DoShowDesignerFormOfSrc). The OpenFormDesigner tool's seam.
    class function ShowFormDesigner(const AUnitName: string;
      out AReason: string): Boolean; static;
  end;

implementation

uses
  TypInfo,
  StrUtils,              // PosEx (body splice)
  base64,
  Forms,                 // TCustomForm, TIDesigner, Screen, GetFormImage
  Controls,              // TControl, TWinControl, StringToCursor
  Graphics,              // TBitmap, TColor, StringToColor, TPortableNetworkGraphic
  LazIDEIntf,            // LazarusIDE (GetDesignerForProjectEditor / DoShow*)
  SrcEditorIntf,         // SourceEditorManagerIntf, TSourceEditorInterface
  FormEditingIntf,       // FormEditingHook (CreateComponent)
  ComponentEditors,      // TComponentEditorDesigner (Form, PropertyEditorHook, DeleteSelection)
  ComponentReg,          // IDEComponentPalette.FindRegComponent (class-by-name resolution)
  PropEdits,             // TPropertyEditorHook, GlobalDesignHook
  LResources;            // WriteComponentAsTextToStream (live form -> .lfm text)

// ---------------------------------------------------------------------------
// Editor + designer resolution (main-thread; single-threaded IDE).
// ---------------------------------------------------------------------------

// The source editor for AUnitName: an exact full-path match first, then a
// base-filename scan over the open editors (AUnitName may be a bare 'Unit1' /
// 'unit1.pas'), then the ACTIVE editor as a module-first fallback (a phantom
// name targets the form the user has open - mirrors the Delphi CurrentModule
// fallback). nil when no editor is open at all.
function _ResolveEditor(const AUnitName: string): TSourceEditorInterface;
var
  LIdx: Integer;
  LEd: TSourceEditorInterface;
  LWant, LWantBase, LBase: string;
begin
  Result := nil;
  if SourceEditorManagerIntf = nil then
    Exit;
  if AUnitName <> '' then
  begin
    Result := SourceEditorManagerIntf.SourceEditorIntfWithFilename(AUnitName);
    if Result <> nil then
      Exit;
    LWant := LowerCase(ExtractFileName(AUnitName));
    LWantBase := LowerCase(ChangeFileExt(ExtractFileName(AUnitName), ''));
    for LIdx := 0 to SourceEditorManagerIntf.UniqueSourceEditorCount - 1 do
    begin
      LEd := SourceEditorManagerIntf.UniqueSourceEditors[LIdx];
      LBase := LowerCase(ExtractFileName(LEd.FileName));
      if (LBase = LWant) or (LowerCase(ChangeFileExt(LBase, '')) = LWantBase) then
        Exit(LEd);
    end;
  end;
  // Module-first fallback: the form the user has open in the editor.
  Result := SourceEditorManagerIntf.ActiveEditor;
end;

// Resolves AUnitName to its live designer + designed root component. False (with
// a machine-actionable AReason) when there is no open editor / no live designer
// / an unexpected designer class. AEditor is handed back so the caller can
// EnsureDesignView (DoShowDesignerFormOfSrc) and DoShowMethod on it.
function _ResolveDesigner(const AUnitName: string;
  out AEditor: TSourceEditorInterface;
  out ADesigner: TComponentEditorDesigner;
  out AHook: TPropertyEditorHook;
  out ARoot: TComponent; out AReason: string): Boolean;
var
  LDsg: TIDesigner;
begin
  Result := False;
  AEditor := nil;
  ADesigner := nil;
  AHook := nil;
  ARoot := nil;
  AReason := 'form-not-found';
  if LazarusIDE = nil then
    Exit;
  AEditor := _ResolveEditor(AUnitName);
  if AEditor = nil then
    Exit; // no editor open at all
  // LoadForm MUST stay False: True materializes a designer as a side effect
  // (a mutating read). A design mutation with no live designer is rejected here
  // (the server guard already rejected it up front; this is belt-and-braces).
  LDsg := LazarusIDE.GetDesignerForProjectEditor(AEditor, False);
  if LDsg = nil then
  begin
    AReason := 'no-live-designer';
    Exit;
  end;
  if not (LDsg is TComponentEditorDesigner) then
  begin
    AReason := 'designer-unavailable';
    Exit;
  end;
  ADesigner := TComponentEditorDesigner(LDsg);
  AHook := ADesigner.PropertyEditorHook;
  if AHook = nil then
    AHook := GlobalDesignHook;
  // Prefer the designer's OWN form (correct even if another designer is active);
  // fall back to the hook's LookupRoot for a datamodule/frame proxy.
  ARoot := ADesigner.Form;
  if (ARoot = nil) and (AHook <> nil) and (AHook.LookupRoot is TComponent) then
    ARoot := TComponent(AHook.LookupRoot);
  if ARoot = nil then
  begin
    AReason := 'form-not-found';
    Exit;
  end;
  AReason := '';
  Result := True;
end;

// EnsureDesignView (RULE #1 doctrine 1): bring the unit's Form Designer to the
// front so a design mutation ENDS in Design and the user sees it. Best-effort -
// a failure must never break the write (mirrors the Delphi _ShowFormDesigner).
procedure _EnsureDesignView(AEditor: TSourceEditorInterface);
begin
  if (LazarusIDE = nil) or (AEditor = nil) then
    Exit;
  try
    LazarusIDE.DoShowDesignerFormOfSrc(AEditor);
    // DOCKED FORM EDITOR flip. When the "Docked Form Editor" is active (the default
    // on the developer's 4.x install), the source editor has Code|Form|Anchors TABS
    // and DoShowDesignerFormOfSrc shows the designer WITHOUT bringing the Form tab
    // forward -- so the mutation lands but the user keeps seeing Code (the view
    // never "flips to Design" like RULE #1 promises and like Delphi does natively).
    // IDETabMaster is non-nil ONLY when the docked form editor is active (nil for a
    // floating designer, where DoShowDesignerFormOfSrc already brought it up); its
    // ShowDesigner is the DIRECTED page switch behind F12/ecToggleFormUnit -- no
    // toggle gamble, always ends on the Form page. Proven 2026-07-20: without this
    // the agent built the whole form yet the user never saw the designer.
    if IDETabMaster <> nil then
      IDETabMaster.ShowDesigner(AEditor);
  except
    // best-effort view polish
  end;
end;

// ---------------------------------------------------------------------------
// Live RTTI property set - ported VERBATIM from the Delphi service's
// _LiveSetPublishedProp, rewritten on classic System.TypInfo (FPC has no mature
// extended RTTI) and with the FMX TAlphaColor branch DELETED (no FMX here). The
// dotted-path walk, the tkMethod rejection, the read-only rejection, and the
// TColor/TCursor named-constant special-cases are preserved 1:1.
// ---------------------------------------------------------------------------
function _LiveSetPublishedProp(AInstance: TObject;
  const APropName, AValue: string; out AReason: string): Boolean;
var
  LParts: TStringList;
  LTarget: TObject;
  LPropInfo: PPropInfo;
  LLast, LTypeName: string;
  LIdx: Integer;
begin
  Result := False;
  if AInstance = nil then
  begin
    AReason := 'access-error';
    Exit;
  end;
  // Walk a dotted path (e.g. 'Font.Height'): each leading segment must be a
  // published class sub-object (TFont, ...), so the FINAL segment is set on the
  // owning sub-instance. A single name (Caption) skips the loop. Split on '.'
  // manually (no string-helper dependency across FPC modes).
  LParts := TStringList.Create;
  try
    LParts.Delimiter := '.';
    LParts.StrictDelimiter := True;
    LParts.DelimitedText := APropName;
    LTarget := AInstance;
    for LIdx := 0 to LParts.Count - 2 do
    begin
      LPropInfo := GetPropInfo(LTarget, LParts[LIdx]);
      if (LPropInfo = nil) or (LPropInfo^.PropType^.Kind <> tkClass) then
      begin
        AReason := 'property-not-found';
        Exit;
      end;
      LTarget := GetObjectProp(LTarget, LParts[LIdx]);
      if LTarget = nil then
      begin
        AReason := 'property-not-found';
        Exit;
      end;
    end;
    if LParts.Count = 0 then
    begin
      AReason := 'property-not-found';
      Exit;
    end;
    LLast := LParts[LParts.Count - 1];
  finally
    LParts.Free;
  end;
  LPropInfo := GetPropInfo(LTarget, LLast);
  if LPropInfo = nil then
  begin
    AReason := 'property-not-found';
    Exit;
  end;
  if LPropInfo^.PropType^.Kind = tkMethod then
  begin
    AReason := 'event-property-needs-AddEventHandler';
    Exit;
  end;
  if LPropInfo^.SetProc = nil then
  begin
    AReason := 'property-read-only';
    Exit;
  end;
  LTypeName := LPropInfo^.PropType^.Name;
  // NAMED-CONSTANT props: TColor (clWhite) and TCursor (crHandPoint) are integer
  // subtypes whose names live in the LCL Ident registries, NOT in enum RTTI, so
  // the generic SetPropValue/StrToInt path rejects the name. Route them through
  // StringToColor / StringToCursor, which accept the NAME and $hex/numeric alike.
  if SameText(LTypeName, 'TColor') then
  begin
    try
      SetOrdProp(LTarget, LPropInfo, StringToColor(AValue));
      AReason := '';
      Exit(True);
    except
      AReason := 'value-conversion-failed';
      Exit(False);
    end;
  end
  else if SameText(LTypeName, 'TCursor') then
  begin
    try
      SetOrdProp(LTarget, LPropInfo, StringToCursor(AValue));
      AReason := '';
      Exit(True);
    except
      AReason := 'value-conversion-failed';
      Exit(False);
    end;
  end;
  try
    // FPC's SetPropValue takes a Variant and, like Delphi's, resolves enum names
    // (GetEnumValue), ordinals and strings from the string value.
    SetPropValue(LTarget, LLast, AValue);
    AReason := '';
    Result := True;
  except
    AReason := 'value-conversion-failed';
  end;
end;

// ---------------------------------------------------------------------------
// TAefosLazFormDesigner
// ---------------------------------------------------------------------------

class function TAefosLazFormDesigner.AddComponent(const AUnitName,
  AComponentClass, AComponentName, AParent: string;
  const ALeft, ATop, AWidth, AHeight: Integer; out AReason: string): Boolean;
var
  LEditor: TSourceEditorInterface;
  LDesigner: TComponentEditorDesigner;
  LHook: TPropertyEditorHook;
  LRoot, LParentComp, LNewComp: TComponent;
  LClass: TComponentClass;
  LReg: TRegisteredComponent;
begin
  Result := False;
  if not _ResolveDesigner(AUnitName, LEditor, LDesigner, LHook, LRoot, AReason) then
    Exit;
  if FormEditingHook = nil then
  begin
    AReason := 'designer-unavailable';
    Exit;
  end;
  // Resolve the class by name via the IDE component PALETTE ONLY. LCL components
  // register with the palette (RegisterComponents), not the RTL RegisterClass
  // table, and - decisively - TMainIDE.PropHookPersistentAdded writes the
  // published source field ONLY for a class the palette knows (FindRegComponent)
  // or a project component class (main.pp:13297-13303); a class resolved by RTL
  // Classes.GetClass gets NO field, so a GetClass fallback would leave an ORPHAN
  // control and let AddComponent report a phantom success. We therefore trust the
  // palette exactly as the native designer does, and fail clean otherwise.
  // Lazarus has no VCL/FMX split, so the class-group gotcha the Delphi side
  // fought does not exist here.
  LClass := nil;
  LReg := nil;
  if IDEComponentPalette <> nil then
  begin
    LReg := IDEComponentPalette.FindRegComponent(AComponentClass);
    if LReg <> nil then
      LClass := LReg.ComponentClass;
  end;
  if LClass = nil then
  begin
    AReason := 'class-not-registered';
    Exit;
  end;
  // Resolve the REQUIRED parent container BEFORE creating anything (a bad parent
  // fails clean). Empty or the form's own name => the form itself.
  if (AParent = '') or SameText(AParent, LRoot.Name) then
    LParentComp := LRoot
  else
    LParentComp := LRoot.FindComponent(AParent);
  if LParentComp = nil then
  begin
    AReason := 'parent-not-found: no component named "' + AParent +
      '" on this form. Pass an existing container, or the form name "' +
      LRoot.Name + '" for a top-level control (list names with ' +
      'ListFormComponents).';
    Exit;
  end;
  if (LRoot is TWinControl) and (LParentComp is TControl)
    and not (LParentComp is TWinControl) then
  begin
    AReason := 'parent-not-container: "' + AParent + '" is not a container ' +
      '(TWinControl). Pass a panel/group-box, or the form name for a ' +
      'top-level control.';
    Exit;
  end;
  // Name collision guard: a rename to an in-use name raises EComponentError.
  if (AComponentName <> '') and (LRoot.FindComponent(AComponentName) <> nil) then
  begin
    AReason := 'name-in-use';
    Exit;
  end;
  // Bring the TARGET designer to front FIRST so the add-veto below (which checks
  // the ACTIVE unit's source) and the field-writing PersistentAdded operate on
  // this unit, not whatever form happened to be focused.
  _EnsureDesignView(LEditor);
  // Native designer parity (designer.pp:719): the hook's add-veto
  // (TMainIDE.PropHookBeforeAddPersistent, main.pp:13223) rejects a control under
  // a non-container parent AND a unit whose interface has syntax errors CodeTools
  // cannot insert the field into - the exact conditions under which
  // PersistentAdded would silently write NO field. Respect a False return instead
  // of reporting a phantom success. (The native ClassDependsOnComponent cycle
  // guard and FixupReferences are IDE-internal - see the DIVERGENCES header.)
  if (LHook <> nil) and not LHook.BeforeAddPersistent(LDesigner, LClass, LParentComp) then
  begin
    AReason := 'add-rejected';
    Exit;
  end;
  // Create the native control + JIT class. DisableAutoSize=True matches the
  // designer's own drop (re-enabled below). The control is NOT in the source yet.
  try
    LNewComp := FormEditingHook.CreateComponent(LParentComp, LClass, '',
      ALeft, ATop, AWidth, AHeight, True);
  except
    LNewComp := nil;
  end;
  if LNewComp = nil then
  begin
    AReason := 'create-failed';
    Exit;
  end;
  try
    // Rename BEFORE the field is written so the published .pas field carries the
    // caller's name (PropHookPersistentAdded keeps a non-empty Name).
    if AComponentName <> '' then
      LNewComp.Name := AComponentName;
    // Re-enable auto-sizing the create disabled (designer.pp:743 parity) and
    // make it visible so it sprouts immediately in the Designer.
    if LNewComp is TControl then
    begin
      TControl(LNewComp).EnableAutoSizing;
      TControl(LNewComp).Visible := True;
      // Native drop parity (designer.pp:755): a control that shows its Name as
      // its Caption (csSetCaption: buttons, labels, check boxes) is dropped with
      // Caption := Name, so it is not blank. Only when the class left it empty.
      if (csSetCaption in TControl(LNewComp).ControlStyle)
        and (TControl(LNewComp).Caption = '') then
        TControl(LNewComp).Caption := LNewComp.Name;
    end;
    // Point the process-wide hook at THIS root before Modified so it flags the
    // targeted designer, not the currently-focused one (propedits.pp:6960).
    LHook.LookupRoot := LRoot;
    // Declare the published field in the .pas + select + update OI. Fires
    // TMainIDE.PropHookPersistentAdded (main.pp:13285), which CodeTools-writes
    // the field (finalized on the next IDE Idle).
    LHook.PersistentAdded(LNewComp, True);
    LHook.Modified(LNewComp);
  except
    on E: Exception do
    begin
      try
        LNewComp.Free;
      except
      end;
      AReason := 'create-failed: ' + E.Message;
      Exit;
    end;
  end;
  // IDE-native Undo parity (designer.pp:777): register the add so the user's
  // Ctrl+Z removes the agent-dropped control exactly like a manual drop. Best
  // effort - the add stands even if the undo stack rejects it. (RemoveComponent
  // is the compensating action regardless.)
  try
    LDesigner.AddUndoAction(LNewComp, uopAdd, True, 'Name', '', LNewComp.Name);
  except
    // best-effort undo registration
  end;
  // INTENT->VIEW: end in Design so the user watches it appear.
  _EnsureDesignView(LEditor);
  AReason := '';
  Result := True;
end;

class function TAefosLazFormDesigner.RemoveComponent(const AUnitName,
  AComponentName: string; out AReason: string): Boolean;
var
  LEditor: TSourceEditorInterface;
  LDesigner: TComponentEditorDesigner;
  LHook: TPropertyEditorHook;
  LRoot: TComponent;
  LTarget: TComponent;
  LPersist: TPersistent;
begin
  Result := False;
  if not _ResolveDesigner(AUnitName, LEditor, LDesigner, LHook, LRoot, AReason) then
    Exit;
  LTarget := LRoot.FindComponent(AComponentName);
  if LTarget = nil then
  begin
    AReason := 'component-not-found';
    Exit;
  end;
  // DeletePersistent frees the control AND drops its published .pas field (its
  // opRemove analog), exactly like the Delphi RemoveComponent's Free -> opRemove.
  LPersist := LTarget;
  try
    LHook.DeletePersistent(LPersist);
  except
    on E: Exception do
    begin
      AReason := 'remove-failed: ' + E.Message;
      Exit;
    end;
  end;
  _EnsureDesignView(LEditor);
  AReason := '';
  Result := True;
end;

class function TAefosLazFormDesigner.SetComponentProperty(const AUnitName,
  AComponentName, APropName, APropValue: string; out AReason: string): Boolean;
var
  LEditor: TSourceEditorInterface;
  LDesigner: TComponentEditorDesigner;
  LHook: TPropertyEditorHook;
  LRoot: TComponent;
  LTarget: TComponent;
begin
  Result := False;
  if not _ResolveDesigner(AUnitName, LEditor, LDesigner, LHook, LRoot, AReason) then
    Exit;
  LTarget := LRoot.FindComponent(AComponentName);
  if LTarget = nil then
  begin
    AReason := 'component-not-found';
    Exit;
  end;
  if not _LiveSetPublishedProp(LTarget, APropName, APropValue, AReason) then
    Exit;
  // Point the hook at THIS root before Modified so the CORRECT form is flagged
  // dirty - the non-editor Modified branch marks FLookupRoot's designer, which is
  // whatever form is focused unless we set it (propedits.pp:6960).
  LHook.LookupRoot := LRoot;
  // Notify: OI refresh + .lfm dirty + re-render in place (propedits.pp:1509).
  LHook.Modified(LTarget, APropName);
  _EnsureDesignView(LEditor);
  AReason := '';
  Result := True;
end;

class function TAefosLazFormDesigner.SetFormProperty(const AUnitName,
  APropName, APropValue: string; out AReason: string): Boolean;
var
  LEditor: TSourceEditorInterface;
  LDesigner: TComponentEditorDesigner;
  LHook: TPropertyEditorHook;
  LRoot: TComponent;
begin
  Result := False;
  if not _ResolveDesigner(AUnitName, LEditor, LDesigner, LHook, LRoot, AReason) then
    Exit;
  if not _LiveSetPublishedProp(LRoot, APropName, APropValue, AReason) then
    Exit;
  // Flag THIS root's designer dirty, not the focused one (propedits.pp:6960).
  LHook.LookupRoot := LRoot;
  LHook.Modified(LRoot, APropName);
  _EnsureDesignView(LEditor);
  AReason := '';
  Result := True;
end;

// Best-effort body splice into the just-created empty stub. CreateMethod writes
// `procedure TForm1.Handler(...); begin end;` synchronously via CodeTools, so the
// live buffer already carries it; we find that method's `begin`..`end;` and, when
// empty, replace it with the indented body. Any miss leaves the wired stub intact
// (never worse than the designer double-click). Mirrors the Delphi ddUnavailable
// silent-splice path.
function _SpliceHandlerBody(AEditor: TSourceEditorInterface;
  const AQualName, ABody: string): Boolean;
var
  LBuf, LNew, LEol, LIndentBody: string;
  LHdrPos, LBeginPos, LEndPos, LLineStart: Integer;
  LBodyLines: TStringList;
  LI: Integer;
begin
  Result := False;
  if (AEditor = nil) or (Trim(ABody) = '') then
    Exit;
  LBuf := AEditor.SourceText;
  LHdrPos := Pos(AQualName, LBuf);
  if LHdrPos = 0 then
    Exit;
  LBeginPos := PosEx('begin', LBuf, LHdrPos);
  if LBeginPos = 0 then
    Exit;
  LEndPos := PosEx('end;', LBuf, LBeginPos);
  if LEndPos = 0 then
    Exit;
  // Only splice a genuinely EMPTY stub (nothing but whitespace between begin and
  // end;) so a real body is never clobbered (idempotent).
  if Trim(Copy(LBuf, LBeginPos + Length('begin'),
       LEndPos - (LBeginPos + Length('begin')))) <> '' then
    Exit;
  if Pos(#13#10, LBuf) > 0 then
    LEol := #13#10
  else
    LEol := #10;
  LBodyLines := TStringList.Create;
  try
    LBodyLines.Text := ABody;
    LIndentBody := '';
    for LI := 0 to LBodyLines.Count - 1 do
      LIndentBody := LIndentBody + '  ' + LBodyLines[LI] + LEol;
  finally
    LBodyLines.Free;
  end;
  LNew := Copy(LBuf, 1, LBeginPos + Length('begin') - 1) + LEol
    + LIndentBody
    + Copy(LBuf, LEndPos, MaxInt);
  LLineStart := AEditor.LineCount;
  if LLineStart < 1 then
    LLineStart := 1;
  AEditor.BeginUndoBlock;
  try
    AEditor.ReplaceLines(1, LLineStart, LNew);
  finally
    AEditor.EndUndoBlock;
  end;
  Result := True;
end;

class function TAefosLazFormDesigner.AddEventHandler(const AUnitName,
  AComponentName, AEventName, AHandlerName, ABody: string;
  out AReason: string): Boolean;
var
  LEditor: TSourceEditorInterface;
  LDesigner: TComponentEditorDesigner;
  LHook: TPropertyEditorHook;
  LRoot: TComponent;
  LTarget: TComponent;
  LPropInfo: PPropInfo;
  LMethod: TMethod;
  LHandler, LRootClass: string;
begin
  Result := False;
  if not _ResolveDesigner(AUnitName, LEditor, LDesigner, LHook, LRoot, AReason) then
    Exit;
  // The form ROOT is a legitimate event target (FormShow/OnCreate live on it),
  // but FindComponent returns only CHILD controls, so wire the form itself when
  // the caller names it (instance/class) or leaves the component empty.
  LTarget := LRoot.FindComponent(AComponentName);
  if (LTarget = nil)
    and ((Trim(AComponentName) = '')
      or SameText(AComponentName, LRoot.Name)
      or SameText(AComponentName, LRoot.ClassName)) then
    LTarget := LRoot;
  if LTarget = nil then
  begin
    AReason := 'component-not-found';
    Exit;
  end;
  LPropInfo := GetPropInfo(LTarget, AEventName);
  if (LPropInfo = nil) or (LPropInfo^.PropType^.Kind <> tkMethod) then
  begin
    AReason := 'event-not-found';
    Exit;
  end;
  // Default handler name follows the IDE convention: the form's own events use
  // the 'Form' prefix (FormCreate), child controls use the component name.
  LHandler := Trim(AHandlerName);
  if LHandler = '' then
  begin
    LHandler := AEventName;
    if LowerCase(Copy(LHandler, 1, 2)) = 'on' then
      LHandler := Copy(LHandler, 3, MaxInt);
    if LTarget = LRoot then
      LHandler := 'Form' + LHandler
    else
      LHandler := AComponentName + LHandler;
  end;
  LRootClass := LRoot.ClassName;
  try
    // CreateMethod writes the wired handler into the published section (via
    // CodeTools) AND returns a TMethod carrying the name association - even for a
    // not-yet-compiled method (a plain SetMethodProp could not). The 3rd/4th args
    // MUST mirror the native TMethodPropertyEditor call exactly:
    // CreateMethod(name, type, GetComponent(0), GetPropertyPath(0)) where
    // GetComponent(0) is the EVENT-OWNING component (LTarget, NOT the form root)
    // and GetPropertyPath(0) = Component.ClassName+'.'+PropName (propedits.pp:2945,
    // :5118). TMainIDE.PropHookCreateMethod derives the handler's parameter types
    // by looking APropertyPath up in GetClassUnitName(APersistent) (main.pp:13025):
    // passing the form root instead resolves the wrong unit ('Unit1' vs the
    // control's declaring unit) and CreatePublishedMethod returns False -> the
    // 'Unable to create new method' failure.
    LMethod := LHook.CreateMethod(LHandler, LPropInfo^.PropType, LTarget,
      LTarget.ClassName + '.' + AEventName);
    // CreateMethod returns a NULL method WITHOUT raising when the name fails
    // LazIsValidIdent or no handler is registered (propedits.pp:6373-6384).
    // Wiring that null method through SetMethodProp would SILENTLY CLEAR whatever
    // handler was already on this event and still report success - reject first.
    if (LMethod.Code = nil) and (LMethod.Data = nil) then
    begin
      AReason := 'invalid-handler-name';
      Result := False;
      Exit;
    end;
    // Wire the event -> the .lfm serialises `AEventName = LHandler`.
    SetMethodProp(LTarget, LPropInfo, LMethod);
    // Flag THIS root's designer dirty, not the focused one (propedits.pp:6960).
    LHook.LookupRoot := LRoot;
    LHook.Modified(LTarget, AEventName);
  except
    on E: Exception do
    begin
      AReason := 'wire-failed: ' + E.Message;
      Exit;
    end;
  end;
  // Fill the body into the empty stub (best-effort; the wire stands regardless).
  _SpliceHandlerBody(LEditor, LRootClass + '.' + LHandler, ABody);
  // intent->view: a handler edit ENDS in Code on the new body (DoShowMethod jumps
  // the source editor to the handler) - the designer double-click's Code half.
  try
    LazarusIDE.DoShowMethod(LEditor, LHandler);
  except
    // best-effort jump
  end;
  AReason := '';
  Result := True;
end;

class function TAefosLazFormDesigner.GetLiveFormLfm(const AUnitName: string;
  out ALfmText: string): Boolean;
var
  LEditor: TSourceEditorInterface;
  LDesigner: TComponentEditorDesigner;
  LHook: TPropertyEditorHook;
  LRoot: TComponent;
  LReason: string;
  LStream: TStringStream;
begin
  Result := False;
  ALfmText := '';
  if not _ResolveDesigner(AUnitName, LEditor, LDesigner, LHook, LRoot, LReason) then
    Exit;
  // Serialize the LIVE root to .lfm text (same FCL text machinery as the .dfm;
  // reflects unsaved edits - a Caption SetComponentProperty just applied shows
  // here). The analog of the Delphi _TryReadLiveFormDfm.
  LStream := TStringStream.Create('');
  try
    try
      WriteComponentAsTextToStream(LStream, LRoot);
      ALfmText := LStream.DataString;
      Result := True;
    except
      ALfmText := '';
      Result := False;
    end;
  finally
    LStream.Free;
  end;
end;

class function TAefosLazFormDesigner.CaptureActiveFormPng(const AUnitName: string;
  out ABase64, APngPath, AReason: string): Boolean;
var
  LEditor: TSourceEditorInterface;
  LDesigner: TComponentEditorDesigner;
  LHook: TPropertyEditorHook;
  LRoot: TComponent;
  LBmp: TBitmap;
  LPng: TPortableNetworkGraphic;
  LMem: TMemoryStream;
  LB64: TBase64EncodingStream;
  LOut: TStringStream;
  LDir, LFile: string;
begin
  Result := False;
  ABase64 := '';
  APngPath := '';
  if not _ResolveDesigner(AUnitName, LEditor, LDesigner, LHook, LRoot, AReason) then
    Exit;
  if not (LRoot is TCustomForm) then
  begin
    AReason := 'capture-unsupported: only a form root can be captured as an image';
    Exit;
  end;
  LBmp := TCustomForm(LRoot).GetFormImage;
  try
    LPng := TPortableNetworkGraphic.Create;
    try
      LPng.Assign(LBmp);
      LMem := TMemoryStream.Create;
      try
        LPng.SaveToStream(LMem);
        LMem.Position := 0;
        LOut := TStringStream.Create('');
        try
          LB64 := TBase64EncodingStream.Create(LOut);
          try
            LB64.CopyFrom(LMem, LMem.Size);
          finally
            LB64.Free; // flushes the final quantum
          end;
          ABase64 := LOut.DataString;
        finally
          LOut.Free;
        end;
        // Best-effort: also drop the PNG so a human can open it.
        try
          LDir := IncludeTrailingPathDelimiter(GetTempDir)
            + 'Aefos' + PathDelim + 'captures';
          ForceDirectories(LDir);
          LFile := IncludeTrailingPathDelimiter(LDir) + LRoot.Name + '.png';
          LMem.Position := 0;
          LMem.SaveToFile(LFile);
          APngPath := LFile;
        except
          APngPath := '';
        end;
      finally
        LMem.Free;
      end;
    finally
      LPng.Free;
    end;
  finally
    LBmp.Free;
  end;
  AReason := '';
  Result := True;
end;

class function TAefosLazFormDesigner.ShowFormDesigner(const AUnitName: string;
  out AReason: string): Boolean;
var
  LEditor: TSourceEditorInterface;
begin
  Result := False;
  AReason := 'form-not-found';
  if LazarusIDE = nil then
    Exit;
  LEditor := _ResolveEditor(AUnitName);
  if LEditor = nil then
    Exit; // no editor open
  // DoShowDesignerFormOfSrc is the view-switch: it shows (materializing if
  // needed) the Form Designer for this unit and brings it to front. A code-only
  // unit produces no designer form; that surfaces as a best-effort no change.
  try
    LazarusIDE.DoShowDesignerFormOfSrc(LEditor);
    // Docked Form Editor: flip the source editor's Code|Form tab to the designer
    // (DoShowDesignerFormOfSrc alone does not, so OpenFormDesigner reported success
    // yet the view stayed on Code). IDETabMaster is non-nil only when the docked
    // form editor is active; ShowDesigner is the directed page switch (F12 twin).
    if IDETabMaster <> nil then
      IDETabMaster.ShowDesigner(LEditor);
    AReason := '';
    Result := True;
  except
    on E: Exception do
      AReason := E.Message;
  end;
end;

end.
