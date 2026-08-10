unit Aefos.MCP.OTA.FormDesignerService;

{
  Form-designer domain (reads + writes), extracted from the TMCPWorkspaceFacade
  god-object as a focused service of the SOLID split (audit S6 / facade split).
  The largest single domain — every tool that reads or mutates a VCL/FMX form.

  Reads (DFM serialization + DFMParser): ListProjectForms, GetDFMContent,
  GetFormProperties, ListFormComponents, GetComponentProperties.
  View-switch (RULE #1 exempt): OpenFormDesigner, OpenDFMTextEditor.
  Live-designer writes (via the WithLiveForm harness): SetFormProperty,
  SetComponentProperty, RemoveComponent, AddComponent, AddEventHandler.
  Disk-DFM write: SetDFMContent.

  The hard seam (the live Form Designer) is already a shared free-function API in
  Aefos.Harness.View — WithLiveForm marshals to the IDE main thread, resolves the
  unit -> IOTAModule -> IOTAFormEditor -> native root TComponent + IDesigner into an
  ILiveFormContext, applies intent->view, runs the work closure and converts
  Ctx.Fail into Result=False. The Set/Add/Remove methods obtain the live form purely
  through Ctx.Form / Ctx.FindComponent / Ctx.Designer; the VCL/FMX class-group gotcha
  (ActivateClassGroup/GetClass + the FMX Position-discriminator) lives inline in
  AddComponent. AddEventHandler is intentionally atomic (it spans the designer .dfm
  wire AND the code-side handler body through the review gate) — kept whole, per
  CLAUDE.md (the two-step InsertMethod+SetProperty it replaced was the bug).

  Bodies moved VERBATIM from the facade (only the class qualifier changes). The
  form-resolution + DFM helpers move WITH the service (they are form-only). The dead
  _ReadScratchFormDfmText (zero call sites) was dropped, not moved. No FAudit. The
  facade keeps its frozen IMCPWorkspaceFacade methods and delegates each to a
  refcounted FFormDesigner field.
}

interface

uses
  Aefos.MCP.Types;

type
  IMCPFormDesignerService = interface
    ['{1A7C3E94-9D85-4B40-8F27-3C6A1B5E8D90}']
    // SaveAllFiles guard V2: '' when safe, else an actionable message when ANY open form
    // wires a .dfm event to a handler that is not in the live .pas yet (saving would let
    // the IDE strip the wire). Main-thread read of the LIVE designer + source buffer.
    function SaveGuardDanglingReason: string;
    // Agent vision: render the LIVE designer form to a PNG (base64). AUnitName
    // empty => the form open in the Designer. False + AReason on failure.
    function CaptureActiveFormPng(const AUnitName: string;
      out ABase64, APngPath, AReason: string): Boolean;
    function ListProjectForms: TArray<TMCPRecordProjectForm>;
    function GetDFMContent(const AUnitName: string;
      out AContent: string; out AIsBinary: Boolean): Boolean;
    function SetDFMContent(const AUnitName, ADFMSource: string;
      out AReason: string): Boolean;
    function GetFormProperties(const AUnitName: string;
      out AProperties: TArray<TMCPRecordDFMProperty>): Boolean;
    function SetFormProperty(const AUnitName, APropName, APropValue: string;
      out AChanged: Boolean; out AReason: string): Boolean;
    function ListFormComponents(const AUnitName: string;
      out AComponents: TArray<TMCPRecordDFMComponent>): Boolean;
    function GetComponentProperties(const AUnitName, AComponentName: string;
      out AProperties: TArray<TMCPRecordDFMProperty>): Boolean;
    function SetComponentProperty(const AUnitName, AComponentName, APropName,
      APropValue: string; out AChanged: Boolean; out AReason: string): Boolean;
    function OpenFormDesigner(const AUnitName: string;
      out AChanged: Boolean; out AReason: string): Boolean;
    function OpenDFMTextEditor(const AUnitName: string;
      out AChanged: Boolean; out AReason: string): Boolean;
    function RemoveComponent(const AUnitName, AComponentName: string;
      out AChanged: Boolean; out AReason: string): Boolean;
    function AddComponent(const AUnitName, AComponentClass, AComponentName,
      AParent: string;
      const ALeft, ATop, AWidth, AHeight: Integer;
      out AChanged: Boolean; out AReason: string): Boolean;
    function AddEventHandler(const AUnitName, AComponentName, AEventName,
      AHandlerName, ABody: string;
      out AChanged: Boolean; out AReason: string): Boolean;
  end;

// Factory — the facade calls this once in its constructor.
function NewMCPFormDesignerService: IMCPFormDesignerService;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.Rtti,
  System.TypInfo,
  System.IOUtils,
  Aefos.Compat.IO,
  System.NetEncoding,
  System.Generics.Collections,
  Vcl.Controls,
  Vcl.Forms,           // TCustomForm.GetFormImage (agent-vision CaptureForm)
  Vcl.Graphics,        // TBitmap
  Vcl.Imaging.pngimage, // TPngImage
  DesignIntf,
  ToolsAPI,
  Aefos.MCP.DFMParser,
  Aefos.Harness.View,
  Aefos.MCP.FlowGuide, // TFlowGuide.DanglingHandlerReason (SaveAllFiles guard V2)
  Aefos.MCP.OTA.FacadeShared,
  Aefos.MCP.OTA.ReviewGate,
  Aefos.MCP.OTA.ContentWritePolicy;

type
  TMCPFormDesignerService = class(TInterfacedObject, IMCPFormDesignerService)
  public
    function SaveGuardDanglingReason: string;
    // Agent vision: render the LIVE designer form to a PNG (base64). AUnitName
    // empty => the form open in the Designer. False + AReason on failure.
    function CaptureActiveFormPng(const AUnitName: string;
      out ABase64, APngPath, AReason: string): Boolean;
    function ListProjectForms: TArray<TMCPRecordProjectForm>;
    function GetDFMContent(const AUnitName: string;
      out AContent: string; out AIsBinary: Boolean): Boolean;
    function SetDFMContent(const AUnitName, ADFMSource: string;
      out AReason: string): Boolean;
    function GetFormProperties(const AUnitName: string;
      out AProperties: TArray<TMCPRecordDFMProperty>): Boolean;
    function SetFormProperty(const AUnitName, APropName, APropValue: string;
      out AChanged: Boolean; out AReason: string): Boolean;
    function ListFormComponents(const AUnitName: string;
      out AComponents: TArray<TMCPRecordDFMComponent>): Boolean;
    function GetComponentProperties(const AUnitName, AComponentName: string;
      out AProperties: TArray<TMCPRecordDFMProperty>): Boolean;
    function SetComponentProperty(const AUnitName, AComponentName, APropName,
      APropValue: string; out AChanged: Boolean; out AReason: string): Boolean;
    function OpenFormDesigner(const AUnitName: string;
      out AChanged: Boolean; out AReason: string): Boolean;
    function OpenDFMTextEditor(const AUnitName: string;
      out AChanged: Boolean; out AReason: string): Boolean;
    function RemoveComponent(const AUnitName, AComponentName: string;
      out AChanged: Boolean; out AReason: string): Boolean;
    function AddComponent(const AUnitName, AComponentClass, AComponentName,
      AParent: string;
      const ALeft, ATop, AWidth, AHeight: Integer;
      out AChanged: Boolean; out AReason: string): Boolean;
    function AddEventHandler(const AUnitName, AComponentName, AEventName,
      AHandlerName, ABody: string;
      out AChanged: Boolean; out AReason: string): Boolean;
  end;

// '.dfm' (VCL) or '.fmx' (FMX) sibling of AUnitPasPath, whichever EXISTS, or ''
// when the unit owns no form file. Probe VCL first (the common case), then FMX.
function _ExistingFormFile(const AUnitPasPath: string): string;
begin
  Result := ChangeFileExt(AUnitPasPath, '.dfm');
  if TFile.Exists(Result) then Exit;
  Result := ChangeFileExt(AUnitPasPath, '.fmx');
  if TFile.Exists(Result) then Exit;
  Result := '';
end;

function _TryBuildProjectForm(const AInfo: IOTAModuleInfo;
  out AItem: TMCPRecordProjectForm): Boolean;
var
  LDFMPath, LUnitName: string;
begin
  Result := False;
  AItem := Default(TMCPRecordProjectForm);
  if not Assigned(AInfo) then Exit;
  if not SameText(ExtractFileExt(AInfo.FileName), '.pas') then Exit;
  LDFMPath := _ExistingFormFile(AInfo.FileName); // .dfm (VCL) or .fmx (FMX)
  if LDFMPath = '' then Exit;
  LUnitName := AInfo.Name;
  if LUnitName = '' then
    LUnitName := ChangeFileExt(ExtractFileName(AInfo.FileName), '');
  AItem.Name       := LUnitName;
  AItem.ModulePath := AInfo.FileName;
  AItem.DfmPath    := LDFMPath;
  Result := True;
end;

// Resolves AUnitName to the `.dfm` path of an active (scratch) project form
// module (ADR-090-07 / BR10 — a form outside the active project does not
// resolve, so SetDFMContent / SetFormProperty / SetComponentProperty refuse it
// with `form-not-found`). Runs on the OTA main thread.
function _ResolveScratchFormDfm(const AUnitName: string;
  out ADfmPath: string): Boolean;
var
  LProject: IOTAProject;
  LFor: Integer;
  LItem: TMCPRecordProjectForm;
  LBase: string;
begin
  Result := False;
  ADfmPath := '';
  if not TFacadeShared.TryProject(LProject) then Exit;
  LBase := ChangeFileExt(ExtractFileName(AUnitName), '');
  for LFor := 0 to LProject.GetModuleCount - 1 do
    if _TryBuildProjectForm(LProject.GetModule(LFor), LItem) then
      if SameText(LItem.Name, AUnitName)
        or SameText(LItem.Name + '.pas', AUnitName)
        or SameText(ChangeFileExt(ExtractFileName(LItem.ModulePath), ''), LBase) then
      begin
        ADfmPath := LItem.DfmPath;
        Exit(True);
      end;
end;

// Resolves AUnitName to its on-disk `.dfm`, materializing it first for a freshly
// created, never-saved form (whose `.dfm` lives only in memory, so the disk
// resolver above returns False). This is the maintainer's rule — "if a project is
// open, save it, THEN proceed" — enforced IN THE TOOL, not in agent reasoning:
// find the LIVE module and IOTAModule.Save so the `.pas`/`.dfm` land on disk, then
// resolve. False (`form-not-found`) only when no live module resolves — e.g. no
// project open, the agent's cue to CreateNewProject first. OTA main thread
// (callers already Synchronize).
function _EnsureFormDfmOnDisk(const AUnitName: string;
  out ADfmPath, AReason: string): Boolean;
var
  LModule: IOTAModule;
  LMS: IOTAModuleServices;
begin
  ADfmPath := '';
  AReason  := 'form-not-found';
  if _ResolveScratchFormDfm(AUnitName, ADfmPath) then
    Exit(True);
  if not TFacadeShared.ResolveUnitModule(AUnitName, LModule) then
  begin
    // MODULE-FIRST fallback: an unresolved/phantom unit name targets the form
    // the user has OPEN in the Designer (CurrentModule) instead of failing
    // form-not-found and pushing the agent onto a raw OverwriteFile. Only a
    // module that owns a form qualifies (checked when its .dfm resolves below).
    if Supports(BorlandIDEServices, IOTAModuleServices, LMS) then
      LModule := LMS.CurrentModule;
    if not Assigned(LModule) then
      Exit(False); // no live module => genuinely not found (no project open)
  end;
  try
    LModule.Save(False, True); // flush the in-memory form to its .pas/.dfm on disk
  except
    on E: Exception do
    begin
      AReason := 'form-not-saved';
      Exit(False);
    end;
  end;
  // Derive the form file from the resolved module's OWN .pas path. Re-resolving
  // by AUnitName would fail on the CurrentModule fallback (its real name differs
  // from the phantom name the agent passed). `.dfm` (VCL) or `.fmx` (FMX); a
  // non-form module has neither => the empty result reports form-not-found.
  ADfmPath := _ExistingFormFile(LModule.FileName);
  Result := ADfmPath <> '';
  if not Result then AReason := 'form-not-found';
end;

// Brings AUnitName's form Designer to the front so a design mutation ENDS on the
// Designer and the user sees it happen (INTENT->VIEW; mirrors OpenFormDesigner).
// Best-effort: a missing form editor or a Show failure must never break the write.
procedure _ShowFormDesigner(const AUnitName: string);
var
  LModule: IOTAModule;
  LMS: IOTAModuleServices;
  LFor: Integer;
  LFormEditor: IOTAFormEditor;
begin
  try
    if not TFacadeShared.ResolveUnitModule(AUnitName, LModule) then
    begin
      // Mirror the module-first fallback: an unresolved name shows the form
      // currently OPEN in the Designer (CurrentModule) so the mutation still
      // ends in Design view.
      if Supports(BorlandIDEServices, IOTAModuleServices, LMS) then
        LModule := LMS.CurrentModule;
      if not Assigned(LModule) then Exit;
    end;
    for LFor := 0 to LModule.GetModuleFileCount - 1 do
      if Supports(LModule.GetModuleFileEditor(LFor), IOTAFormEditor, LFormEditor) then
      begin
        LFormEditor.Show;
        Exit;
      end;
  except
    // best-effort view polish
  end;
end;

// Serialize a live (possibly unsaved) design form to text DFM via the VCL
// streaming system, so the structured DFM reads observe the Designer's in-memory
// state instead of the on-disk .dfm — which is stale while the designer holds
// unsaved edits. Returns False when the form is not open in a live
// IOTAFormEditor (caller then falls back to the disk read). Marshals to the IDE
// main thread (BR7); the module->text serialization is the shared
// TFacadeShared.TryModuleLiveDfmText (the desync guard reads through it too).
function _TryReadLiveFormDfm(const AUnitName: string;
  out ADfmText: string): Boolean;
var
  LOk: Boolean;
  LText: string;
begin
  LOk := False;
  LText := '';
  try
    TThread.Synchronize(nil, procedure
    var
      LModule: IOTAModule;
    begin
      if not TFacadeShared.ResolveUnitModule(AUnitName, LModule) then Exit;
      LOk := TFacadeShared.TryModuleLiveDfmText(LModule, LText);
    end);
  except
    LOk := False;
    LText := '';
  end;
  ADfmText := LText;
  Result := LOk;
end;

// True for an FMX TAlphaColor literal as serialized in a .fmx: 'x' + 8 hex digits
// (xAARRGGBB). VCL color values never take this form, so using it to recover from
// a failed conversion below can only ever help an FMX set, never change VCL.
function _IsFmxColorLiteral(const AValue: string): Boolean;
var
  LFor: Integer;
begin
  // 'x'/'X'/'$' + 8 hex digits: an FMX TAlphaColor literal (xAARRGGBB, the .fmx
  // form) or a plain $-hex. A VCL color value never takes this exact shape.
  Result := (Length(AValue) = 9) and CharInSet(AValue[1], ['x', 'X', '$']);
  if not Result then Exit;
  for LFor := 2 to 9 do
    if not CharInSet(AValue[LFor], ['0'..'9', 'a'..'f', 'A'..'F']) then
      Exit(False);
end;

// Sets APropName on the live native AInstance from the string AValue via
// published-property RTTI — the live equivalent of the old .dfm text write,
// with NO disk write and NO TFacadeShared.RefreshModuleFromDisk(Force) (the confirmed
// clobber that reverted an unsaved .pas buffer). Ordinary scalar / enum / set /
// string props convert from the string through System.TypInfo.SetPropValue's
// Variant path; the designer re-renders the change in place. Event/method props
// (OnClick, ...) cannot be wired from a name here — that needs the designer
// (the atomic AddEventHandler), so they are REJECTED with a clear reason rather
// than silently mis-set. Caller must run on the IDE main thread.
function _LiveSetPublishedProp(AInstance: TObject;
  const APropName, AValue: string; out AReason: string): Boolean;
var
  LCtx: TRttiContext;
  LProp: TRttiProperty;
  LType: TRttiType;
  LTarget: TObject;
  LParts: TArray<string>;
  LLast: string;
  LPropTypeName: string;
  LIdx: Integer;
begin
  Result := False;
  LPropTypeName := '';
  if AInstance = nil then
  begin
    AReason := 'access-error';
    Exit;
  end;
  LCtx := TRttiContext.Create;
  try
    // Walk a dotted path (e.g. 'Font.Height'): each leading segment must be a
    // published class sub-object (TFont, ...), so the FINAL segment is set on the
    // owning sub-instance, not the root. A single name (Caption) skips the loop and
    // behaves exactly as before.
    LParts := APropName.Split(['.']);
    LTarget := AInstance;
    LType := LCtx.GetType(LTarget.ClassType);
    for LIdx := 0 to High(LParts) - 1 do
    begin
      LProp := LType.GetProperty(LParts[LIdx]);
      if (LProp = nil) or (LProp.PropertyType.TypeKind <> tkClass) then
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
      LType := LCtx.GetType(LTarget.ClassType);
    end;
    LLast := LParts[High(LParts)];
    LProp := LType.GetProperty(LLast);
    if LProp = nil then
    begin
      AReason := 'property-not-found';
      Exit;
    end;
    if LProp.PropertyType.TypeKind = tkMethod then
    begin
      AReason := 'event-property-needs-AddEventHandler';
      Exit;
    end;
    if not LProp.IsWritable then
    begin
      AReason := 'property-read-only';
      Exit;
    end;
    LPropTypeName := LProp.PropertyType.Name;
  finally
    LCtx.Free;
  end;
  // NAMED-CONSTANT props: TColor (clWhite) and TCursor (crHandPoint) are integer
  // subtypes whose names live in the VCL Ident registries, NOT in enum RTTI, so
  // SetPropValue's StrToInt path rejects the name. Route them through StringToColor
  // / StringToCursor, which accept the NAME and a $hex/numeric value alike — the
  // agent writes the obvious 'clWhite' instead of a BGR hex. VCL branch only; the
  // FMX TAlphaColor 'xAARRGGBB' literal is still handled in the except below.
  if SameText(LPropTypeName, 'TColor') then
  begin
    try
      SetOrdProp(LTarget, LLast, StringToColor(AValue));
      AReason := '';
      Exit(True);
    except
      AReason := 'value-conversion-failed';
      Exit(False);
    end;
  end
  else if SameText(LPropTypeName, 'TCursor') then
  begin
    try
      SetOrdProp(LTarget, LLast, StringToCursor(AValue));
      AReason := '';
      Exit(True);
    except
      AReason := 'value-conversion-failed';
      Exit(False);
    end;
  end;
  try
    SetPropValue(LTarget, LLast, AValue);
    AReason := '';
    Result := True;
  except
    on E: Exception do
    begin
      // FMX serializes TAlphaColor (an unsigned 32-bit) as 'xAARRGGBB'.
      // SetPropValue routes through StrToInt, which (a) rejects the 'x' prefix and
      // (b) overflows on a high-bit-set value like $FF6750A4 (> 32-bit MaxInt).
      // Parse the 8 hex digits as Int64 and write the 32-bit bit-pattern straight
      // to the ordinal property. Only runs AFTER a genuine failure, only for the
      // unambiguous x/$+8hex shape, so string/ordinal sets are never perturbed and
      // the VCL path is untouched.
      if _IsFmxColorLiteral(AValue) then
      try
        SetOrdProp(LTarget, LLast,
          Integer(StrToInt64('$' + Copy(AValue, 2, MaxInt))));
        AReason := '';
        Result := True;
        Exit;
      except
      end;
      AReason := 'value-conversion-failed';
    end;
  end;
end;

// Builds a Pascal handler signature ('procedure Name(Sender: TObject);') from an
// event property's method-type RTTI, so AddEventHandler can create the handler
// with the CORRECT parameter list for ANY event (OnKeyPress's var Key, etc.),
// not just OnClick. Falls back to a TNotifyEvent shape when the type is unusual.
function _BuildEventSignature(const AHandlerName: string;
  const AEventType: TRttiType): string;
var
  LMethType: TRttiMethodType;
  LParams: TArray<TRttiParameter>;
  LParts: TArray<string>;
  LFor: Integer;
  LMod, LTypeName, LParamList: string;
begin
  if not (AEventType is TRttiMethodType) then
    Exit('procedure ' + AHandlerName + '(Sender: TObject);');
  LMethType := TRttiMethodType(AEventType);
  LParams := LMethType.GetParameters;
  SetLength(LParts, Length(LParams));
  for LFor := 0 to High(LParams) do
  begin
    LMod := '';
    if pfVar in LParams[LFor].Flags then
      LMod := 'var '
    else if pfConst in LParams[LFor].Flags then
      LMod := 'const '
    else if pfOut in LParams[LFor].Flags then
      LMod := 'out ';
    if Assigned(LParams[LFor].ParamType) then
      LTypeName := LParams[LFor].ParamType.Name
    else
      LTypeName := 'TObject';
    LParts[LFor] := LMod + LParams[LFor].Name + ': ' + LTypeName;
  end;
  LParamList := '';
  if Length(LParts) > 0 then
    LParamList := '(' + string.Join('; ', LParts) + ')';
  if (LMethType.MethodKind = mkFunction) and Assigned(LMethType.ReturnType) then
    Result := 'function ' + AHandlerName + LParamList + ': ' +
      LMethType.ReturnType.Name + ';'
  else
    Result := 'procedure ' + AHandlerName + LParamList + ';';
end;

// The full source line of ABuf that contains AQualName (the qualified impl header
// `procedure TForm.Handler(...)`, unique because the bare published decl is NOT
// class-qualified) — verbatim, with its own indentation, so a review block built
// from it matches the buffer byte-for-byte. '' when not found.
function _MethodHeaderLine(const ABuf, AQualName: string): string;
var
  LPos, LStart, LEnd: Integer;
begin
  Result := '';
  LPos := Pos(AQualName, ABuf);
  if LPos = 0 then
    Exit;
  LStart := LPos;
  while (LStart > 1) and not CharInSet(ABuf[LStart - 1], [#10, #13]) do
    Dec(LStart);
  LEnd := LPos;
  while (LEnd <= Length(ABuf)) and not CharInSet(ABuf[LEnd], [#10, #13]) do
    Inc(LEnd);
  Result := Copy(ABuf, LStart, LEnd - LStart);
end;

// EOL of ABuf: CRLF when present (the editor buffer convention), else LF — so a
// review block joined with it anchors against the live buffer.
function _BufferEol(const ABuf: string): string;
begin
  if Pos(#13#10, ABuf) > 0 then
    Result := #13#10
  else
    Result := #10;
end;

{ ── TMCPFormDesignerService ────────────────────────────────────────────── }

// SaveAllFiles guard V2 (fires independent of auto-accept): scan every OPEN form module
// and refuse the save when its LIVE .dfm wires an event to a handler that is not in the
// LIVE .pas buffer yet — saving would let the Delphi IDE strip the .dfm wire. Reads the
// live designer (_TryReadLiveFormDfm via GetDFMContent) + the live source buffer (not
// disk), so a handler the agent just added but did not save still counts as present. The
// pure dangling decision lives in TFlowGuide.DanglingHandlerReason. Main-thread only.
function TMCPFormDesignerService.SaveGuardDanglingReason: string;
var
  LMS: IOTAModuleServices;
  LModule: IOTAModule;
  LForm: IOTAFormEditor;
  LSrc: IOTASourceEditor;
  LI, LE: Integer;
  LDfm, LPas, LReason, LUnitName: string;
  LIsBinary: Boolean;
begin
  Result := '';
  if not TFacadeShared.TryModuleServices(LMS) then
    Exit;
  for LI := 0 to LMS.GetModuleCount - 1 do
  begin
    LModule := LMS.GetModule(LI);
    if not Assigned(LModule) then
      Continue;
    // A form module carries an IOTAFormEditor among its file editors.
    LForm := nil;
    for LE := 0 to LModule.GetModuleFileCount - 1 do
      if Supports(LModule.GetModuleFileEditor(LE), IOTAFormEditor, LForm) then
        Break;
    if not Assigned(LForm) then
      Continue;
    LSrc := TFacadeShared.FirstSourceEditor(LModule);
    if not Assigned(LSrc) then
      Continue;
    LPas := TFacadeShared.ReadBytes(LSrc.CreateReader);
    LUnitName := ChangeFileExt(ExtractFileName(LModule.FileName), '');
    if (not GetDFMContent(LUnitName, LDfm, LIsBinary)) or LIsBinary then
      Continue;
    LReason := TFlowGuide.DanglingHandlerReason(LDfm, LPas);
    if LReason <> '' then
      Exit(LReason);
  end;
end;

function TMCPFormDesignerService.ListProjectForms: TArray<TMCPRecordProjectForm>;
var
  LResult: TArray<TMCPRecordProjectForm>;
begin
  LResult := [];
  try
    TThread.Synchronize(nil, procedure
    var
      LProject: IOTAProject;
      LFor: Integer;
      LList: TList<TMCPRecordProjectForm>;
      LItem: TMCPRecordProjectForm;
    begin
      if not TFacadeShared.TryProject(LProject) then Exit;
      LList := TList<TMCPRecordProjectForm>.Create;
      try
        for LFor := 0 to LProject.GetModuleCount - 1 do
          if _TryBuildProjectForm(LProject.GetModule(LFor), LItem) then
            LList.Add(LItem);
        LResult := LList.ToArray;
      finally
        LList.Free;
      end;
    end);
  except
    LResult := [];
  end;
  Result := LResult;
end;

function TMCPFormDesignerService.GetDFMContent(const AUnitName: string;
  out AContent: string; out AIsBinary: Boolean): Boolean;
var
  LForms: TArray<TMCPRecordProjectForm>;
  LDFMPath, LBase: string;
  LFor: Integer;
  LBytes: TBytes;
begin
  AContent  := '';
  AIsBinary := False;
  Result    := False;
  // Prefer the live designer state (reflects unsaved edits); fall back to the
  // on-disk .dfm below when the form is not open in a live designer.
  if _TryReadLiveFormDfm(AUnitName, AContent) then
  begin
    AIsBinary := False;
    Exit(True);
  end;
  try
    LForms := ListProjectForms;
    LDFMPath := '';
    LBase := ChangeFileExt(ExtractFileName(AUnitName), '');
    for LFor := 0 to High(LForms) do
      if SameText(LForms[LFor].Name, AUnitName)
        or SameText(LForms[LFor].Name + '.pas', AUnitName)
        or SameText(ChangeFileExt(ExtractFileName(LForms[LFor].ModulePath), ''),
          LBase) then
      begin
        LDFMPath := LForms[LFor].DfmPath;
        Break;
      end;
    if LDFMPath = '' then Exit;
    LBytes := TFile.ReadAllBytes(LDFMPath);
    if TDFMParser.IsBinaryDFM(LBytes) then
    begin
      // ADR-140 discriminator: binary DFM returned as base64.
      AContent  := TNetEncoding.Base64.EncodeBytesToString(LBytes);
      AIsBinary := True;
    end
    else
      AContent := TAefosText.ReadAllUtf8(LDFMPath);
    Result := True;
  except
    AContent  := '';
    AIsBinary := False;
    Result    := False;
  end;
end;

// The form unit's CURRENT source: the live editor buffer when the module is open
// (an unsaved field the agent just gained via AddComponent still counts — reading
// disk here would false-reject a legit flow), else the on-disk `.pas` sibling of
// ADfmPath. '' when neither reads (caller then SKIPS the guard — fail open, the
// guard must never block on its own plumbing). OTA main thread.
function _ReadFormPasSource(const AUnitName, ADfmPath: string): string;
var
  LModule: IOTAModule;
  LMS: IOTAModuleServices;
  LSrc: IOTASourceEditor;
  LPasPath: string;
begin
  Result := '';
  try
    if not TFacadeShared.ResolveUnitModule(AUnitName, LModule) then
      // Mirror _EnsureFormDfmOnDisk's module-first fallback (phantom unit name
      // => the form open in the Designer).
      if Supports(BorlandIDEServices, IOTAModuleServices, LMS) then
        LModule := LMS.CurrentModule;
    if Assigned(LModule) then
    begin
      LSrc := TFacadeShared.FirstSourceEditor(LModule);
      if Assigned(LSrc) then
        Result := TFacadeShared.ReadBytes(LSrc.CreateReader);
    end;
    if Result <> '' then
      Exit;
    LPasPath := ChangeFileExt(ADfmPath, '.pas');
    if TFile.Exists(LPasPath) then
      Result := TFile.ReadAllText(LPasPath);
  except
    Result := '';
  end;
end;

// Replace a scratch-project form's `.dfm` source (ESP-090). The whole-source
// replacement is written to the resolved scratch-form `.dfm` on disk so a
// follow-up GetDFMContent (a disk read) observes it (R5); a form outside the
// active project does not resolve and is refused with `form-not-found` (BR10).
// The original `.dfm` is the read-first baseline for reversibility (AC7).
// PAS<->DFM DESYNC GUARD (its-own-guardian, RULE #1 philosophy): a .dfm that
// declares components the form class does not would break the module on reload
// ("declaration of X does not exist" / stripped objects) — the signature of an
// agent trying to BUILD a form via one bulk DFM write instead of AddComponent.
// The command refuses WITHOUT writing and the reason steers it to AddComponent;
// the description already said so — the guard now enforces it.
function TMCPFormDesignerService.SetDFMContent(const AUnitName,
  ADFMSource: string; out AReason: string): Boolean;
var
  LResult: Boolean;
  LReason: string;
begin
  LResult := False;
  LReason := 'form-not-found';
  try
    TThread.Synchronize(nil, procedure
    var
      LDfmPath, LPas, LGuard, LOldDfm: string;
      LModule: IOTAModule;
    begin
      // Materialize the .dfm first (saves a never-saved scratch form) so a brand
      // new project resolves instead of failing form-not-found — the reason the
      // agent used to fall back to a raw OverwriteFile that bypassed the Designer.
      if not _EnsureFormDfmOnDisk(AUnitName, LDfmPath, LReason) then
        Exit; // LReason already set (form-not-found / form-not-saved)
      LPas := _ReadFormPasSource(AUnitName, LDfmPath);
      if LPas <> '' then
      begin
        LGuard := TFlowGuide.DfmUndeclaredComponentsReason(ADFMSource, LPas);
        if LGuard <> '' then
        begin
          LReason := LGuard;
          Exit; // refused BEFORE the write — nothing mutated
        end;
      end;
      // DESIGNER-REQUIRED GUARD (closes the bypass): a NEW control enters a form
      // ONLY via AddComponent (it sprouts LIVE in the Designer; the IDE declares
      // the field). SetDFMContent may reposition/restyle EXISTING controls, never
      // introduce them. Compared against the LIVE form (in-memory truth), so first
      // declaring the fields in the .pas cannot sneak a bulk form-build past the
      // pas<->dfm guard above.
      LOldDfm := '';
      if TFacadeShared.ResolveUnitModule(AUnitName, LModule) then
        if not TFacadeShared.TryModuleLiveDfmText(LModule, LOldDfm) then
          LOldDfm := '';
      if LOldDfm = '' then
        try
          LOldDfm := TAefosText.ReadAllUtf8(LDfmPath);
        except
          LOldDfm := '';
        end;
      LGuard := TFlowGuide.DfmAddsUndesignedComponentsReason(ADFMSource, LOldDfm);
      if LGuard <> '' then
      begin
        LReason := LGuard;
        Exit; // refused BEFORE the write — nothing mutated
      end;
      try
        TFile.WriteAllText(LDfmPath, ADFMSource, TEncoding.UTF8);
        // Silent reload so an open designer/text view re-renders the new DFM
        // in place — no "file has been changed, reload?" dialog.
        TFacadeShared.RefreshModuleFromDisk(LDfmPath);
        // INTENT->VIEW: a design mutation must end on the Designer so the user
        // watches the form change happen (not a silent disk write).
        _ShowFormDesigner(AUnitName);
        LResult := True;
        LReason := '';
      except
        on E: Exception do
          LReason := E.Message;
      end;
    end);
  except
    on E: Exception do
    begin
      LResult := False;
      LReason := E.Message;
    end;
  end;
  if LResult then AReason := '' else AReason := LReason;
  Result := LResult;
end;

function TMCPFormDesignerService.GetFormProperties(const AUnitName: string;
  out AProperties: TArray<TMCPRecordDFMProperty>): Boolean;
var
  LContent: string;
  LIsBinary: Boolean;
  LPairs: TArray<TDFMPropertyPair>;
  LFor: Integer;
begin
  AProperties := [];
  Result := False;
  if not GetDFMContent(AUnitName, LContent, LIsBinary) then Exit;
  if LIsBinary then Exit;
  try
    LPairs := TDFMParser.ExtractTopLevelProperties(LContent);
    SetLength(AProperties, Length(LPairs));
    for LFor := 0 to High(LPairs) do
    begin
      AProperties[LFor].Name  := LPairs[LFor].Name;
      AProperties[LFor].Value := LPairs[LFor].Value;
    end;
    Result := True;
  except
    AProperties := [];
    Result := False;
  end;
end;

// Live form-property set via the IDE Harness. The work only does the RTTI set
// on the native form root — no .dfm disk write, no force refresh (the clobber).
function TMCPFormDesignerService.SetFormProperty(const AUnitName,
  APropName, APropValue: string;
  out AChanged: Boolean; out AReason: string): Boolean;
begin
  Result := THarnessView.WithLiveForm(AUnitName, liDesignMutation,
    procedure(const Ctx: ILiveFormContext)
    var
      LSetReason: string;
    begin
      if not _LiveSetPublishedProp(Ctx.Form, APropName, APropValue, LSetReason) then
        Ctx.Fail(LSetReason);
    end,
    AChanged, AReason);
end;

function TMCPFormDesignerService.ListFormComponents(const AUnitName: string;
  out AComponents: TArray<TMCPRecordDFMComponent>): Boolean;
var
  LContent: string;
  LIsBinary: Boolean;
  LChildren: TArray<TDFMComponentRef>;
  LFor: Integer;
begin
  AComponents := [];
  Result := False;
  if not GetDFMContent(AUnitName, LContent, LIsBinary) then Exit;
  if LIsBinary then Exit;
  try
    // EVERY component, at every depth -- not just the form's direct children.
    // A form whose controls live inside a TPageControl reported exactly ONE
    // component here, and an agent reading that against a .pas full of fields
    // concluded the two were desynced (field report, 2026-08-04). Each entry
    // carries its Owner, so the nesting the agent needs is in the answer rather
    // than missing from it.
    LChildren := TDFMParser.EnumerateAllComponents(LContent);
    SetLength(AComponents, Length(LChildren));
    for LFor := 0 to High(LChildren) do
    begin
      AComponents[LFor].Name     := LChildren[LFor].Name;
      AComponents[LFor].TypeName := LChildren[LFor].TypeName;
      AComponents[LFor].Owner    := LChildren[LFor].Owner;
    end;
    Result := True;
  except
    AComponents := [];
    Result := False;
  end;
end;

function TMCPFormDesignerService.GetComponentProperties(
  const AUnitName, AComponentName: string;
  out AProperties: TArray<TMCPRecordDFMProperty>): Boolean;
var
  LContent: string;
  LIsBinary: Boolean;
  LPairs: TArray<TDFMPropertyPair>;
  LFor: Integer;
begin
  AProperties := [];
  Result := False;
  if not GetDFMContent(AUnitName, LContent, LIsBinary) then Exit;
  if LIsBinary then Exit;
  try
    LPairs := TDFMParser.ExtractComponentProperties(LContent, AComponentName);
    SetLength(AProperties, Length(LPairs));
    for LFor := 0 to High(LPairs) do
    begin
      AProperties[LFor].Name  := LPairs[LFor].Name;
      AProperties[LFor].Value := LPairs[LFor].Value;
    end;
    Result := True;
  except
    AProperties := [];
    Result := False;
  end;
end;

// Live component-property set via the IDE Harness. The work resolves the target
// and does the RTTI set on the native component — no .dfm disk write, no force
// refresh (the confirmed clobber). The designer re-renders the change in place.
function TMCPFormDesignerService.SetComponentProperty(const AUnitName,
  AComponentName, APropName, APropValue: string;
  out AChanged: Boolean; out AReason: string): Boolean;
begin
  Result := THarnessView.WithLiveForm(AUnitName, liDesignMutation,
    procedure(const Ctx: ILiveFormContext)
    var
      LTarget: TComponent;
      LSetReason: string;
    begin
      LTarget := Ctx.FindComponent(AComponentName);
      if not Assigned(LTarget) then
      begin
        Ctx.Fail('component-not-found');
        Exit;
      end;
      if not _LiveSetPublishedProp(LTarget, APropName, APropValue, LSetReason) then
        Ctx.Fail(LSetReason);
    end,
    AChanged, AReason);
end;

function TMCPFormDesignerService.OpenFormDesigner(const AUnitName: string;
  out AChanged: Boolean; out AReason: string): Boolean;
var
  LResult, LChanged: Boolean;
  LReason: string;
begin
  LResult  := False;
  LChanged := False;
  LReason  := 'no-active-project';
  try
    TThread.Synchronize(nil, procedure
    var
      LMS: IOTAModuleServices;
      LModule: IOTAModule;
      LFor: Integer;
      LFormEditor: IOTAFormEditor;
    begin
      if not TFacadeShared.TryModuleServices(LMS) then Exit;
      if not TFacadeShared.ResolveUnitModule(AUnitName, LModule) then
      begin
        LReason := 'form-not-found';
        Exit;
      end;
      LReason := 'form-not-found';
      for LFor := 0 to LModule.GetModuleFileCount - 1 do
        if Supports(LModule.GetModuleFileEditor(LFor), IOTAFormEditor, LFormEditor) then
        begin
          LFormEditor.Show;
          LChanged := True;
          LReason  := '';
          LResult  := True;
          Exit;
        end;
    end);
  except
    LResult  := False;
    LChanged := False;
    LReason  := 'access-error';
  end;
  AChanged := LChanged;
  AReason  := LReason;
  Result   := LResult;
end;

function TMCPFormDesignerService.OpenDFMTextEditor(const AUnitName: string;
  out AChanged: Boolean; out AReason: string): Boolean;
var
  LResult, LChanged: Boolean;
  LReason: string;
begin
  LResult  := False;
  LChanged := False;
  LReason  := 'not-available';
  try
    TThread.Synchronize(nil, procedure
    var
      LMS: IOTAModuleServices;
      LModule: IOTAModule;
      LFor: Integer;
      LSource: IOTASourceEditor;
    begin
      if not TFacadeShared.TryModuleServices(LMS) then Exit;
      if not TFacadeShared.ResolveUnitModule(AUnitName, LModule) then
      begin
        LReason := 'form-not-found';
        Exit;
      end;
      LReason := 'dfm-editor-not-found';
      for LFor := 0 to LModule.GetModuleFileCount - 1 do
        if Supports(LModule.GetModuleFileEditor(LFor), IOTASourceEditor, LSource) then
          if SameText(TPath.GetExtension(LSource.FileName), '.dfm') then
          begin
            LSource.Show;
            LChanged := True;
            LReason  := '';
            LResult  := True;
            Exit;
          end;
    end);
  except
    LResult  := False;
    LChanged := False;
    LReason  := 'access-error';
  end;
  AChanged := LChanged;
  AReason  := LReason;
  Result   := LResult;
end;

// First live-designer mutation (vs the disk-text rewrite the Set* writers use).
// Resolves the form's IOTAFormEditor (same seam as OpenFormDesigner), brings the
// Designer to front (EnsureDesignView, so the user sees the removal happen), then
// frees the live native component via INTAComponent. Freeing a designer-managed
// component fires the IDE's opRemove notification, which drops the published field
// from the .pas on its own — no .pas text surgery, no RunBuild. The module is left
// modified (MarkModified) for a follow-up SaveActiveFile. INTAComponent and
// IOTAFormEditor are pure ToolsAPI — no DesignIntf/designide dependency added.
// Live designer delete via the IDE Harness (first tool migrated onto it).
// WithLiveForm marshals to the main thread, resolves the form + native root,
// EnsureDesignView and MarkModified — this method only says WHAT to do. Freeing
// the live component fires opRemove, which the IDE designer handles by dropping
// the published .pas field for us — no .pas text surgery.
function TMCPFormDesignerService.RemoveComponent(const AUnitName,
  AComponentName: string;
  out AChanged: Boolean; out AReason: string): Boolean;
begin
  Result := THarnessView.WithLiveForm(AUnitName, liDesignMutation,
    procedure(const Ctx: ILiveFormContext)
    var
      LTarget: TComponent;
    begin
      LTarget := Ctx.FindComponent(AComponentName);
      if not Assigned(LTarget) then
      begin
        Ctx.Fail('component-not-found');
        Exit;
      end;
      LTarget.Free;
    end,
    AChanged, AReason);
end;

// Inverse of RemoveComponent: create a component through the live designer so the
// IDE declares the published field in the .pas itself (no .pas text written by the
// agent). Same seam as RemoveComponent — resolve IOTAFormEditor, Show
// (EnsureDesignView), then CreateComponent under the root. The created instance is
// renamed to AComponentName (the designer keeps the field in sync). Pure ToolsAPI.
// Live designer create via the IDE Harness (inverse of RemoveComponent). The
// work resolves the class in the FORM'S framework class group and creates the
// component under the form; the IDE declares the published .pas field itself.
function TMCPFormDesignerService.AddComponent(const AUnitName, AComponentClass,
  AComponentName, AParent: string;
  const ALeft, ATop, AWidth, AHeight: Integer;
  out AChanged: Boolean; out AReason: string): Boolean;
var
  LAdjust: string;
begin
  LAdjust := '';
  Result := THarnessView.WithLiveForm(AUnitName, liDesignMutation,
    procedure(const Ctx: ILiveFormContext)
    var
      LForm, LNewComp, LParentComp: TComponent;
      LPersist, LPrevGroup: TPersistentClass;
      LClass: TComponentClass;
      LPosObj, LSizeObj: TObject;
      LRttiCtx: TRttiContext;
      LRProp: TRttiProperty;
    begin
      LForm := Ctx.Form;
      // Resolve the class by name in the FORM'S framework class group. Both VCL
      // and FMX register a class literally named 'TButton'; the global GetClass
      // returns whichever registered last (often FMX), which on a VCL form yields
      // a non-visual FMX control and an AV when treated as a VCL control. Activate
      // the group of the form's own root class so GetClass resolves the matching
      // (here VCL) class, then restore the previous group.
      LPrevGroup := ActivateClassGroup(TPersistentClass(LForm.ClassType));
      LPersist := GetClass(AComponentClass);
      if Assigned(LPrevGroup) then
        ActivateClassGroup(LPrevGroup);
      if (LPersist = nil) or not LPersist.InheritsFrom(TComponent) then
      begin
        Ctx.Fail('unknown-class');
        Exit;
      end;
      LClass := TComponentClass(LPersist);
      // Resolve the REQUIRED parent container BEFORE creating the control, so a
      // bad parent fails clean (nothing to free). The agent must always say WHERE
      // the control nests — a container (panel/group-box) or the form's own name
      // for a top-level control — so nothing lands invisibly behind another
      // control (the classic "everything ends up behind the panel" bug). Empty is
      // rejected at the tool layer; treat empty or the form's own name as the form.
      if (AParent = '') or SameText(AParent, LForm.Name) then
        LParentComp := LForm
      else
        LParentComp := LForm.FindComponent(AParent);
      if LParentComp = nil then
      begin
        Ctx.Fail('parent-not-found: no component named "' + AParent +
          '" on this form. Pass an existing container, or the form name "' +
          LForm.Name + '" for a top-level control (list names with ' +
          'ListFormComponents).');
        Exit;
      end;
      // On a VCL form the container must be a windowed control; the FMX branch
      // resolves parent via extended RTTI below and accepts any TFmxObject.
      if (LForm is TWinControl) and not (LParentComp is TWinControl) then
      begin
        Ctx.Fail('parent-not-container: "' + AParent + '" is not a container ' +
          '(TWinControl). Pass a panel/group-box, or the form name for a ' +
          'top-level control.');
        Exit;
      end;
      // Native create with Owner = the form. Owner insertion fires opInsert,
      // which the IDE designer handles by declaring the published field in the
      // .pas (symmetric to RemoveComponent's Free -> opRemove field cleanup).
      // This sidesteps the designer's "class not applicable to this module" gate
      // that both IDesigner.CreateComponent and IOTAFormEditor.CreateComponent
      // enforce.
      LNewComp := LClass.Create(LForm);
      try
        if AComponentName <> '' then
          LNewComp.Name := AComponentName;
        // The class is resolved in the form's framework group, so the new
        // instance is a genuine VCL control — the `is` checks are precise and
        // parenting/bounds operate on a matching layout.
        if (LNewComp is TControl) and (LForm is TWinControl) then
        begin
          TControl(LNewComp).Parent := TWinControl(LParentComp);
          // Auto-sizing controls (TEdit etc. default AutoSize=True) reset Height to
          // the font height inside SetBounds, silently dropping a requested Height.
          // An explicit Height>0 is unambiguous geometry intent: disable AutoSize
          // first so the height sticks.
          if (AHeight > 0) and IsPublishedProp(LNewComp, 'AutoSize') and
             (GetOrdProp(LNewComp, 'AutoSize') <> 0) then
            SetOrdProp(LNewComp, 'AutoSize', 0);
          TControl(LNewComp).SetBounds(ALeft, ATop, AWidth, AHeight);
          // Honesty: if the framework still overrode the height, report it instead
          // of a clean success — the caller revalidates from AReason.
          if (AHeight > 0) and (TControl(LNewComp).Height <> AHeight) then
            LAdjust := Format('height-adjusted-to-%d', [TControl(LNewComp).Height]);
        end
        else if IsPublishedProp(LNewComp, 'Position') then
        begin
          // FMX path. This unit is compiled VCL-side, so the TControl/TWinControl
          // casts above never match an FMX form. Two FMX-specific facts:
          // (1) The designer does NOT auto-parent an owned FMX control — without an
          //     explicit Parent it serializes (owner-nested in the .fmx) but stays
          //     Parent=nil in the LIVE designer, so it is invisible until a reload
          //     re-parents it (the Alt+F12 round-trip). Parent is a PUBLIC property
          //     (not published), so classic RTTI can't reach it — set it via
          //     extended RTTI so the control sprouts immediately.
          // (2) Geometry lives in the PUBLISHED sub-objects Size (Size.Width/Height)
          //     and Position (X/Y); the public Width/Height aren't published, so
          //     SetFloatProp on them is a no-op. We set the sub-objects classically.
          // No FMX-unit dependency, VCL branch untouched. Published 'Position'
          // (absent on VCL controls) is the discriminator.
          LRttiCtx := TRttiContext.Create;
          try
            LRProp := LRttiCtx.GetType(LNewComp.ClassType).GetProperty('Parent');
            if Assigned(LRProp) and LRProp.IsWritable then
              LRProp.SetValue(LNewComp, TValue.From<TObject>(LParentComp));
          finally
            LRttiCtx.Free;
          end;
          LSizeObj := GetObjectProp(LNewComp, 'Size');
          if Assigned(LSizeObj) then
          begin
            if AWidth > 0 then
              SetFloatProp(LSizeObj, 'Width', AWidth);
            if AHeight > 0 then
              SetFloatProp(LSizeObj, 'Height', AHeight);
          end;
          LPosObj := GetObjectProp(LNewComp, 'Position');
          if Assigned(LPosObj) then
          begin
            SetFloatProp(LPosObj, 'X', ALeft);
            SetFloatProp(LPosObj, 'Y', ATop);
          end;
        end;
      except
        LNewComp.Free;
        Ctx.Fail('create-failed');
        Exit;
      end;
    end,
    AChanged, AReason);
  // Surface a geometry override on success (WithLiveForm clears AReason on success,
  // and an out-param cannot be captured inside the closure — apply it here).
  if Result and (LAdjust <> '') then
    AReason := LAdjust;
end;

// Agent vision. Renders the LIVE designer form (its real child controls, as laid
// out) to a PNG and returns it base64-encoded, so a vision-capable model can SEE
// what it is building and self-correct (a leftover Caption, a missing glyph, a
// misalignment). Read intent (liDesignRead) — it never moves the view or mutates.
// VCL only (GetFormImage is a TCustomForm method); an FMX form fails clean with
// capture-unsupported. No RunProject needed — this is the fast look-and-fix loop.
function TMCPFormDesignerService.CaptureActiveFormPng(const AUnitName: string;
  out ABase64, APngPath, AReason: string): Boolean;
var
  LB64, LPath: string;
  LChanged: Boolean;
begin
  LB64 := '';
  LPath := '';
  Result := THarnessView.WithLiveForm(AUnitName, liDesignRead,
    procedure(const Ctx: ILiveFormContext)
    var
      LForm: TComponent;
      LBmp: TBitmap;
      LPng: TPngImage;
      LStream: TMemoryStream;
      LBytes: TBytes;
      LDir, LFile: string;
    begin
      LForm := Ctx.Form;
      if not (LForm is TCustomForm) then
      begin
        Ctx.Fail('capture-unsupported: only VCL forms can be captured as an image');
        Exit;
      end;
      LBmp := TCustomForm(LForm).GetFormImage;
      try
        LPng := TPngImage.Create;
        try
          LPng.Assign(LBmp);
          LStream := TMemoryStream.Create;
          try
            LPng.SaveToStream(LStream);
            SetLength(LBytes, LStream.Size);
            if LStream.Size > 0 then
            begin
              LStream.Position := 0;
              LStream.ReadBuffer(LBytes[0], LStream.Size);
            end;
            LB64 := TNetEncoding.Base64.EncodeBytesToString(LBytes);
            // Also persist the PNG so a human can open it (visual audit trail).
            // Named by the form so re-captures overwrite rather than pile up.
            LDir := TPath.Combine(TPath.GetTempPath, 'Aefos' + PathDelim + 'captures');
            try
              TDirectory.CreateDirectory(LDir);
              LFile := TPath.Combine(LDir, LForm.Name + '.png');
              LStream.Position := 0;
              LStream.SaveToFile(LFile);
              LPath := LFile;
            except
              // Disk write is best-effort; the base64 (agent vision) still returns.
              LPath := '';
            end;
          finally
            LStream.Free;
          end;
        finally
          LPng.Free;
        end;
      finally
        LBmp.Free;
      end;
    end,
    LChanged, AReason);
  if Result then
  begin
    ABase64 := LB64;
    APngPath := LPath;
  end
  else
  begin
    ABase64 := '';
    APngPath := '';
  end;
end;

// Atomic event-handler wire (the designer's double-click). Resolves the live
// form designer (IDesigner — `designide` is already a requires of the Tools.OTA
// package, so no new dependency), creates AHandlerName in the .pas's published
// auto-managed section via IDesigner.CreateMethod (or links the existing method
// of that name) AND assigns it to the component's AEventName so the .dfm gets
// the `OnX = Handler` wire — one designer transaction. No disk write, no
// TFacadeShared.RefreshModuleFromDisk(Force), so the buffer-vs-disk clobber cannot occur.
// CreateMethod is what lets us wire an event to a not-yet-compiled handler (a
// plain RTTI SetMethodProp cannot — there is no compiled method address yet).
function TMCPFormDesignerService.AddEventHandler(const AUnitName, AComponentName,
  AEventName, AHandlerName, ABody: string;
  out AChanged: Boolean; out AReason: string): Boolean;
begin
  Result := THarnessView.WithLiveForm(AUnitName, liDesignMutation,
    procedure(const Ctx: ILiveFormContext)
    var
      LTarget: TComponent;
      LDesigner: IDesigner;
      LRtti: TRttiContext;
      LProp: TRttiProperty;
      LPropInfo: PPropInfo;
      LMethod: TMethod;
      LHandler, LFormClass, LSig, LBuf, LNewBuf, LMName, LPlanReason: string;
      LOldBlock, LNewBlock, LHdr, LEol, LDiffReason: string;
      LModule: IOTAModule;
      LSource: IOTASourceEditor;
      LIsForm, LWantBodyReview: Boolean;
      LApprover: IMCPDiffApprover;
      LDecision: TMCPDiffDecision;
      LRevealLine: Integer;
    begin
      LIsForm := False;
      LRevealLine := 0;
      LTarget := Ctx.FindComponent(AComponentName);
      if not Assigned(LTarget) then
      begin
        // The form ROOT is a legitimate event target (FormCreate / OnShow /
        // OnClose live on it), but TComponent.FindComponent only returns CHILD
        // controls, never the root — so wire the form itself when the caller
        // names it (its instance Name or class) or leaves the component empty.
        // Without this the form's own events are unreachable through the designer.
        if (Trim(AComponentName) = '')
           or SameText(AComponentName, Ctx.Form.Name)
           or SameText(AComponentName, Ctx.Form.ClassName) then
        begin
          LTarget := Ctx.Form;
          LIsForm := True;
        end;
      end;
      if not Assigned(LTarget) then
      begin
        Ctx.Fail('component-not-found');
        Exit;
      end;
      // The live form designer (IDesignerHook -> IDesigner) is the seam that
      // creates+tracks event methods by name (lazily resolved by the harness).
      LDesigner := Ctx.Designer;
      if not Assigned(LDesigner) then
      begin
        Ctx.Fail('designer-unavailable');
        Exit;
      end;
      // REVIEW-PENDING GUARD (maintainer decision, 2026-06-23): the change-review NEVER stops
      // the agent — the gutter diff stays for the HUMAN to see, but a pending review must never
      // refuse a command. AddEventHandler both drops a stub into the .pas (PlanMethodInsertion +
      // ReplaceWholeBuffer, whole-buffer) AND wires the event in the .dfm. If the unit still
      // carries UNRESOLVED change-review blocks (stacked old+new from a prior EditUnit/handler),
      // the plan would parse polluted Pascal and mangle the unit. So when a review is pending we
      // ALWAYS auto-accept the prior review (flush red, keep green = the same outcome as Save) so
      // the buffer is clean, then LET THIS EDIT PASS. There is no refusal path: the agent is never
      // blocked, and the next edit still renders its own green diff in the gutter for review.
      LSource := nil;
      if TFacadeShared.ResolveUnitModule(AUnitName, LModule) then
        LSource := TFacadeShared.FirstSourceEditor(LModule);
      if Assigned(LSource) and TReviewGate.ReviewPendingForUnit(LSource.FileName) then
        TReviewGate.RunReviewSaveFlush;
      LRtti := TRttiContext.Create;
      try
        LProp := LRtti.GetType(LTarget.ClassType).GetProperty(AEventName);
        if (LProp = nil) or (LProp.PropertyType.TypeKind <> tkMethod) then
        begin
          Ctx.Fail('event-not-found');
          Exit;
        end;
        LPropInfo := (LProp as TRttiInstanceProperty).PropInfo;
        // Default handler name follows the IDE convention: Comp + Event-minus-'On'.
        LHandler := Trim(AHandlerName);
        if LHandler = '' then
        begin
          LHandler := AEventName;
          if LHandler.ToLower.StartsWith('on') then
            LHandler := Copy(LHandler, 3, MaxInt);
          // IDE convention: the form's OWN events use the 'Form' prefix
          // (FormCreate / FormShow), NOT the form's instance name; child controls
          // use the component name (Button1Click).
          if LIsForm then
            LHandler := 'Form' + LHandler
          else
            LHandler := AComponentName + LHandler;
        end;
        // ATOMIC BODY + REVIEWABLE: when a body is requested and the handler is
        // not implemented yet, first drop the EMPTY wired stub (decl in the
        // published section + an empty `begin end;` impl) — designer boilerplate,
        // no review value, exactly the IDE double-click stub. The agent's BODY is
        // then filled in through the change-review gutter (after the .dfm wire,
        // below) so generated code lands as a red/green diff the user can
        // approve/reject — the DIFF a designer-written handler used to skip. The
        // empty stub gives the body diff a CONTIGUOUS anchor (header + begin + end;),
        // unlike the whole-method change, which straddles the disjoint decl+impl
        // insertion points. Live-buffer only: no disk write, no clobber. Idempotent
        // — an existing implementation is never overwritten.
        LWantBodyReview := False;
        if Trim(ABody) <> '' then
        begin
          LFormClass := Ctx.Form.ClassName;
          LSig := _BuildEventSignature(LHandler, LProp.PropertyType);
          LSource := nil;
          if TFacadeShared.ResolveUnitModule(AUnitName, LModule) then
            LSource := TFacadeShared.FirstSourceEditor(LModule);
          if Assigned(LSource) then
          begin
            LBuf := TFacadeShared.ReadBytes(LSource.CreateReader);
            if (Pos(LFormClass + '.' + LHandler, LBuf) = 0) and
               TContentWritePolicy.PlanMethodInsertion(LBuf, LFormClass, LSig, '', LNewBuf, LMName,
                 LPlanReason) then
            begin
              // Build the body diff against the just-planned empty stub: OLD is
              // its `header / begin / end;`, NEW splices the indented body between
              // begin and end; (IndentMethodBody renders it exactly as
              // PlanMethodInsertion would, so the applied code is identical).
              LHdr := _MethodHeaderLine(LNewBuf, LFormClass + '.' + LHandler);
              LEol := _BufferEol(LNewBuf);
              LOldBlock := LHdr + LEol + 'begin' + LEol + 'end;';
              LNewBlock := LHdr + LEol + 'begin' + LEol +
                string.Join(LEol, TContentWritePolicy.IndentMethodBody(ABody)) + LEol + 'end;';
              TFacadeShared.ReplaceWholeBuffer(LSource, LNewBuf);
              // Line of the just-inserted implementation header (TForm.Handler) so
              // the view scrolls to the new body instead of leaving it buried below
              // the published component declarations.
              LRevealLine := TFacadeShared.LineOfOffset(LNewBuf,
                Pos(LFormClass + '.' + LHandler, LNewBuf));
              LWantBodyReview := (LHdr <> '') and (LOldBlock <> LNewBlock);
            end;
          end;
        end;
        // Creates the handler in the published section (or links the existing
        // one) and yields a TMethod carrying the name association even for a
        // not-yet-compiled method.
        LMethod := LDesigner.CreateMethod(LHandler,
          GetTypeData(LProp.PropertyType.Handle));
      finally
        LRtti.Free;
      end;
      // Wire the event -> the .dfm serialises `AEventName = LHandler` on save.
      SetMethodProp(LTarget, LPropInfo, LMethod);
      LDesigner.Modified;
      // intent->view (CLAUDE.md): a pure wire (empty body) leaves the view in
      // Design. When a body was requested, fill it through the change-review gutter
      // NOW — AFTER the .dfm wire, so there is no buffer-vs-designer fight: the
      // approver shows the agent's code as a red/green diff and applies it on
      // approve (Model B, non-blocking). ddUnavailable (review off / source not
      // shown) splices the body in silently so it is never lost. Either way the
      // view ends in Code on the new handler — mirroring the designer double-click
      // (Design to wire, Code to show the body).
      if LWantBodyReview and Assigned(LSource) then
      begin
        LDiffReason := '';
        LApprover := TReviewGate.GlobalDiffApprover;
        if Assigned(LApprover) then
          LDecision := LApprover.ReviewEdit(LSource.FileName, LOldBlock,
            LNewBlock, LDiffReason)
        else
          LDecision := ddUnavailable;
        if LDecision = ddUnavailable then
        begin
          // No reviewer: splice the body into the empty stub directly so the
          // generated handler is complete (the pre-review behaviour).
          LBuf := TFacadeShared.ReadBytes(LSource.CreateReader);
          LBuf := StringReplace(LBuf, LOldBlock, LNewBlock, []);
          TFacadeShared.ReplaceWholeBuffer(LSource, LBuf);
        end;
        THarnessView.EnsureCodeView(LSource, LRevealLine);
      end;
    end,
    AChanged, AReason);
end;

function NewMCPFormDesignerService: IMCPFormDesignerService;
begin
  Result := TMCPFormDesignerService.Create;
end;

end.
