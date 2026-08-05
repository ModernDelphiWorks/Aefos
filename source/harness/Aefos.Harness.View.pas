unit Aefos.Harness.View;

{ The IDE Harness (view side) — the named layer that encapsulates RAD Studio's
  Design/Code duality so every live tool draws on the SAME battle-tested
  primitives instead of re-implementing the seam. It is shared by the terminal
  AND the chat (both reach it through the MCP server / facade), so both get the
  intent->view policy for free.

  The five live form tools (Remove/Add component, Set component/form property,
  AddEventHandler) all repeated the same ~15-line block: marshal to the main
  thread (BR-7) -> resolve the module -> find the IOTAFormEditor -> Show
  (EnsureDesignView) -> resolve the native root via INTAComponent -> work ->
  try/except into a kebab reason (BR-3) -> MarkModified. That duplication is where
  bugs hide (the FMX `is`-false-negative, the .dfm clobber). WithLiveForm does the
  choreography ONCE; a tool only declares its INTENT and the work to run.

  The intent->view policy (CLAUDE.md) becomes EXECUTABLE here: a design intent
  ends in the Form Designer. Code intents get a separate transaction (later). }

interface

uses
  System.SysUtils,
  System.Classes,
  ToolsAPI,
  DesignIntf;

type
  // The intent that drives the view. Design intents bring the Form Designer
  // forward and end there (EnsureDesignView). Mutation also MarkModifies.
  TLiveIntent = (liDesignMutation, liDesignRead);

  // The view a module is showing NOW — the READ side of the Design/Code duality
  // (vs TLiveIntent = what a tool WANTS). Backs RULE #1's intent guard; the MCP
  // host maps it to its own enum, so the harness stays MCP-agnostic. lvNeither =
  // undeterminable — the guard never blocks on it.
  TLiveView = (lvNeither, lvDesign, lvCode);

  // What a WithLiveForm work block receives: the live form already resolved and
  // in the right view, plus failure signalling. The work only does the domain
  // step; resolution / marshalling / view / error-to-reason live in the harness.
  ILiveFormContext = interface
    ['{7F3A1C2D-5E6B-4A8C-9D0E-1F2A3B4C5D6E}']
    function FormEditor: IOTAFormEditor;
    // The native root TForm of the designer (via INTAComponent).
    function Form: TComponent;
    // The live form designer (IDesigner), resolved lazily; nil when unavailable.
    function Designer: IDesigner;
    // The named component on the form, or nil (TComponent.FindComponent).
    function FindComponent(const AName: string): TComponent;
    // Abort the work with a kebab reason; WithLiveForm then returns False.
    procedure Fail(const AReason: string);
    function Failed: Boolean;
    function Reason: string;
  end;

  // The domain step a tool runs inside WithLiveForm. `const` avoids interface
  // refcount churn and matches the facade's `procedure(const Ctx: ...)` blocks.
  TLiveFormWork = reference to procedure(const ACtx: ILiveFormContext);

  // The CODE-side counterpart of TLiveIntent. A code mutation brings the source
  // editor forward and ends in Code (EnsureCodeView); a code read is view-agnostic.
  TLiveSourceIntent = (lsCodeMutation, lsCodeRead);

  // What a WithLiveSource work block receives: the live source editor already
  // resolved and (for a mutation) in Code view, plus buffer read/replace + a line
  // reveal and failure signalling. The work only does the domain-specific surgery
  // (insert/replace/plan) and calls ReplaceWhole; resolution / marshalling / view /
  // error-to-reason live in the harness. The CODE twin of ILiveFormContext.
  ILiveSourceContext = interface
    ['{2D8B1C3E-6F7A-4B9D-8E0F-3A4B5C6D7E8F}']
    function SourceEditor: IOTASourceEditor;
    // The editor's file path (IOTASourceEditor.FileName).
    function UnitPath: string;
    // The full current buffer text (live, UTF-8 decoded).
    function ReadBuffer: string;
    // Replace the WHOLE buffer with ANewText in one undoable write; True on
    // success (and the transaction then reports AChanged=True).
    function ReplaceWhole(const ANewText: string): Boolean;
    // Scroll the top edit view to ALine (1-based) so freshly injected code is
    // on-screen; <=0 is a no-op. (EnsureCodeView with a line.)
    procedure RevealLine(const ALine: Integer);
    // Abort the work with a kebab reason; WithLiveSource then returns False.
    procedure Fail(const AReason: string);
    function Failed: Boolean;
    function Reason: string;
    // True once ReplaceWhole has committed at least one buffer write.
    function DidWrite: Boolean;
  end;

  // The domain step a tool runs inside WithLiveSource.
  TLiveSourceWork = reference to procedure(const ACtx: ILiveSourceContext);

  // The IDE-harness view seam as a sealed static namespace (RULE #1 / intent->view,
  // CLAUDE.md): the canonical home of the Design/Code duality primitives, shared by
  // the terminal AND the chat (both reach it through the MCP server / facade). Never
  // instantiated — the class is the namespace. WithLiveForm/WithLiveSource are the
  // symmetric design/code transactions every live tool draws on.
  THarnessView = class sealed
  public
    // ── Resolution primitives — the canonical home (the facade delegates here) ──
    // Resolves a unit by bare name or path; retries with `.pas` for a bare name.
    class function ResolveUnitModule(const AUnitNameOrPath: string;
      out AModule: IOTAModule): Boolean; static;
    // The first IOTAFormEditor of a module (a form module's designer), or nil.
    class function FirstFormEditor(const AModule: IOTAModule): IOTAFormEditor; static;

    // ── Code-side intent->view (the counterpart of WithLiveForm's design side) ──
    // EnsureCodeView: bring a source editor to the FRONT so a CODE mutation lands
    // AND ends in Code (the OTA F12), not behind a Form Designer that a preceding
    // design step left in front (intent->view policy, CLAUDE.md). Call it right
    // after resolving the editor, before the buffer edit / inline diff. No-op when
    // nil. Must run on the IDE main thread (the caller is already inside its
    // TThread.Synchronize).
    class procedure EnsureCodeView(const ASourceEditor: IOTASourceEditor);
      overload; static;

    // Same intent->view flip, but ALSO scrolls the top edit view to ALine (1-based)
    // and parks the caret at its start, so freshly INJECTED code (a handler/method
    // appended to the implementation section, far below the class's component
    // declarations) is actually ON-SCREEN — the human watching the IDE sees what the
    // agent wrote instead of a buffer that silently changed off-view. ALine <= 0
    // behaves like the plain overload (Show only). Main-thread only.
    class procedure EnsureCodeView(const ASourceEditor: IOTASourceEditor;
      const ALine: Integer); overload; static;

    // ── Current-view read (the counterpart of the EnsureXView write side) ────────
    // CurrentLiveView: the view the ACTIVE module is showing NOW
    // (IOTAModule.CurrentEditor) — a form editor => lvDesign, a source editor =>
    // lvCode, else lvNeither. The harness OWNS this read because it is the same
    // Design/Code seam as EnsureDesignView/EnsureCodeView; the MCP intent guard
    // consumes it (via the facade adapter). Main-thread only (the caller marshals).
    class function CurrentLiveView: TLiveView; static;

    // ── The live-form transaction ───────────────────────────────────────────────
    // Marshals to the IDE main thread (BR-7), resolves the form + native root,
    // applies the intent->view (EnsureDesignView), runs AWork, then MarkModifies on
    // success for a mutation. Exceptions never cross (BR-3) -> 'access-error'.
    // Returns False with AReason for any failure, including Ctx.Fail. AChanged is
    // True on a successful mutation.
    class function WithLiveForm(const AUnitName: string; const AIntent: TLiveIntent;
      const AWork: TLiveFormWork;
      out AChanged: Boolean; out AReason: string): Boolean; static;

    // ── The live-source transaction (the code twin of WithLiveForm) ──────────────
    // Marshals to the IDE main thread (BR-7), resolves the source editor (a BLANK
    // name targets the ACTIVE editor; a named/path unit resolves its module's first
    // source editor — anti-hallucination S3: a non-blank name that does not resolve
    // is refused, not silently applied to the active one), applies the intent->view
    // (EnsureCodeView for a mutation), runs AWork against the live buffer, and reports
    // AChanged when the work committed a write. Exceptions never cross (BR-3) ->
    // 'access-error'. Returns False with AReason for any failure, including Ctx.Fail.
    class function WithLiveSource(const AUnitName: string; const AIntent: TLiveSourceIntent;
      const AWork: TLiveSourceWork;
      out AChanged: Boolean; out AReason: string): Boolean; static;
  end;

implementation

uses
  System.Rtti,
  System.TypInfo,
  Vcl.Forms;

class function THarnessView.ResolveUnitModule(const AUnitNameOrPath: string;
  out AModule: IOTAModule): Boolean;
var
  LServices: IOTAModuleServices;
begin
  AModule := nil;
  Result := False;
  if AUnitNameOrPath = '' then Exit;
  if not Assigned(BorlandIDEServices) then Exit;
  if not Supports(BorlandIDEServices, IOTAModuleServices, LServices) then Exit;
  AModule := LServices.FindModule(AUnitNameOrPath);
  // Retry with `.pas` only for bare unit names. Dotted names like
  // "Aefos.MCP.AuditLog" have ExtractFileExt = ".AuditLog" (not ""), so check
  // for path separators instead of relying on ExtractFileExt = ''.
  if not Assigned(AModule)
    and (Pos('\', AUnitNameOrPath) = 0) and (Pos('/', AUnitNameOrPath) = 0)
    and not SameText(ExtractFileExt(AUnitNameOrPath), '.pas') then
    AModule := LServices.FindModule(AUnitNameOrPath + '.pas');
  Result := Assigned(AModule);
end;

class function THarnessView.FirstFormEditor(const AModule: IOTAModule): IOTAFormEditor;
var
  LFor: Integer;
begin
  Result := nil;
  if not Assigned(AModule) then Exit;
  for LFor := 0 to AModule.GetModuleFileCount - 1 do
    if Supports(AModule.GetModuleFileEditor(LFor), IOTAFormEditor, Result) then
      Exit;
  Result := nil;
end;

class procedure THarnessView.EnsureCodeView(const ASourceEditor: IOTASourceEditor);
begin
  if Assigned(ASourceEditor) then
    ASourceEditor.Show;
end;

class procedure THarnessView.EnsureCodeView(const ASourceEditor: IOTASourceEditor;
  const ALine: Integer);
var
  LES: IOTAEditorServices;
  LView: IOTAEditView;
  LPos: TOTAEditPos;
begin
  if not Assigned(ASourceEditor) then Exit;
  ASourceEditor.Show; // flip to Code first (the F12), same as the plain overload
  if ALine <= 0 then Exit;
  if not Supports(BorlandIDEServices, IOTAEditorServices, LES) then Exit;
  LView := LES.TopView;
  if not Assigned(LView) then Exit;
  LPos.Line := ALine;
  LPos.Col  := 1;
  LView.CursorPos := LPos;
  LView.MoveViewToCursor; // scroll so the injected line is visible, not buried
  LView.Paint;
end;

class function THarnessView.CurrentLiveView: TLiveView;
var
  LServices: IOTAModuleServices;
  LModule: IOTAModule;
  LEditor: IOTAEditor;
begin
  // The active module's CURRENT sub-editor is the seam: a form editor means the
  // Designer is up (Design), a source editor means the code editor is up (Code).
  // lvNeither when undeterminable (no module, Welcome page, etc.).
  Result := lvNeither;
  if not Assigned(BorlandIDEServices) then Exit;
  if not Supports(BorlandIDEServices, IOTAModuleServices, LServices) then Exit;
  LModule := LServices.CurrentModule;
  if not Assigned(LModule) then Exit;
  LEditor := LModule.CurrentEditor;
  if Supports(LEditor, IOTAFormEditor) then
    Result := lvDesign
  else if Supports(LEditor, IOTASourceEditor) then
    Result := lvCode;
end;

// The ACTIVE module — the form the user is currently looking at in the Designer
// (IOTAModuleServices.CurrentModule) — but ONLY when it actually owns a form
// editor. This is the fallback target for a design mutation whose unit name does
// not resolve: the maintainer's rule is "build into the OPEN form, never a
// phantom unit the agent invented". nil when no active form module exists.
function _ActiveFormModule: IOTAModule;
var
  LServices: IOTAModuleServices;
begin
  Result := nil;
  if not Assigned(BorlandIDEServices) then Exit;
  if not Supports(BorlandIDEServices, IOTAModuleServices, LServices) then Exit;
  Result := LServices.CurrentModule;
  if not Assigned(THarnessView.FirstFormEditor(Result)) then
    Result := nil;
end;

// Resolves the native root TForm of a form editor through INTAComponent — the
// rock-solid path used by every live tool (no version-specific enumeration).
function _RootForm(const AFormEditor: IOTAFormEditor): TComponent;
var
  LNative: INTAComponent;
begin
  Result := nil;
  if Supports(AFormEditor.GetRootComponent, INTAComponent, LNative) then
    Result := LNative.GetComponent;
end;

type
  TLiveFormContext = class(TInterfacedObject, ILiveFormContext)
  private
    FFormEditor: IOTAFormEditor;
    FForm: TComponent;
    FDesigner: IDesigner;
    FDesignerResolved: Boolean;
    FFailed: Boolean;
    FReason: string;
  public
    constructor Create(const AFormEditor: IOTAFormEditor;
      const AForm: TComponent);
    function FormEditor: IOTAFormEditor;
    function Form: TComponent;
    function Designer: IDesigner;
    function FindComponent(const AName: string): TComponent;
    procedure Fail(const AReason: string);
    function Failed: Boolean;
    function Reason: string;
  end;

constructor TLiveFormContext.Create(const AFormEditor: IOTAFormEditor;
  const AForm: TComponent);
begin
  inherited Create;
  FFormEditor := AFormEditor;
  FForm := AForm;
end;

function TLiveFormContext.FormEditor: IOTAFormEditor;
begin
  Result := FFormEditor;
end;

function TLiveFormContext.Form: TComponent;
begin
  Result := FForm;
end;

function TLiveFormContext.Designer: IDesigner;
var
  LRtti: TRttiContext;
  LProp: TRttiProperty;
  LVal: TValue;
begin
  if not FDesignerResolved then
  begin
    FDesignerResolved := True;
    FDesigner := nil;
    // VCL — UNCHANGED fast path. A VCL root is Vcl.Forms.TCustomForm, whose
    // public `Designer` is already an IDesigner. This line is byte-for-byte the
    // original behaviour, so VCL cannot regress.
    if FForm is TCustomForm then
      Supports(TCustomForm(FForm).Designer, IDesigner, FDesigner)
    // FMX / anything else — the OLD code stopped here and left FDesigner nil,
    // which is why FMX event wiring failed `designer-unavailable` (an FMX root
    // is FMX.Forms.TCommonCustomForm, never TCustomForm, so the `is` above is a
    // false-negative — the same trap as the AddComponent FMX-`is` bug). FMX
    // exposes a public `Designer` of type IDesignerHook (descends IDesigner);
    // read it generically by RTTI, WITHOUT adding an FMX-unit dependency to the
    // harness. This branch never runs for VCL, so it cannot affect it.
    else if Assigned(FForm) then
    begin
      LRtti := TRttiContext.Create;
      try
        LProp := LRtti.GetType(FForm.ClassType).GetProperty('Designer');
        if Assigned(LProp) and (LProp.PropertyType.TypeKind = tkInterface) then
        begin
          LVal := LProp.GetValue(FForm);
          if not LVal.IsEmpty then
            Supports(LVal.AsInterface, IDesigner, FDesigner);
        end;
      finally
        LRtti.Free;
      end;
    end;
  end;
  Result := FDesigner;
end;

function TLiveFormContext.FindComponent(const AName: string): TComponent;
begin
  if Assigned(FForm) then
    Result := FForm.FindComponent(AName)
  else
    Result := nil;
end;

procedure TLiveFormContext.Fail(const AReason: string);
begin
  FFailed := True;
  FReason := AReason;
end;

function TLiveFormContext.Failed: Boolean;
begin
  Result := FFailed;
end;

function TLiveFormContext.Reason: string;
begin
  Result := FReason;
end;

class function THarnessView.WithLiveForm(const AUnitName: string; const AIntent: TLiveIntent;
  const AWork: TLiveFormWork;
  out AChanged: Boolean; out AReason: string): Boolean;
var
  LResult, LChanged: Boolean;
  LReason: string;
begin
  LResult  := False;
  LChanged := False;
  LReason  := 'form-not-found';
  try
    TThread.Synchronize(nil,
      procedure
      var
        LModule: IOTAModule;
        LFormEditor: IOTAFormEditor;
        LForm: TComponent;
        LCtx: ILiveFormContext;
      begin
        if not THarnessView.ResolveUnitModule(AUnitName, LModule) then
          LModule := nil;
        LFormEditor := THarnessView.FirstFormEditor(LModule);
        // MODULE-FIRST fallback (intent->view policy): when the unit name is
        // BLANK, a DESIGN MUTATION builds into the form the user has OPEN in the
        // Designer (CurrentModule), so components sprout on screen instead of
        // failing form-not-found and pushing the agent onto a file-first
        // OverwriteFile that ends stuck in Code.
        //
        // Anti-hallucination (S3): the fallback applies ONLY to a blank name. A
        // NON-BLANK name that did not resolve to a live form module is a phantom
        // the agent invented (e.g. "Unit2") or a non-form unit — refuse with an
        // actionable reason instead of silently mutating whatever form happens to
        // be open. The agent self-corrects: open the named form, or omit the name
        // to target the open one. A read stays strict either way.
        if not Assigned(LFormEditor) and (AIntent = liDesignMutation) then
        begin
          if Trim(AUnitName) <> '' then
          begin
            LReason := 'unit-not-resolved';
            Exit;
          end;
          LModule := _ActiveFormModule;
          LFormEditor := THarnessView.FirstFormEditor(LModule);
        end;
        if not Assigned(LFormEditor) then
        begin
          LReason := 'form-not-found';
          Exit;
        end;
        // EnsureDesignView: a design MUTATION brings the Designer forward and
        // leaves it there (the change is seen live); a design read is
        // view-agnostic — it never moves the view (intent->view policy).
        if AIntent = liDesignMutation then
          LFormEditor.Show;
        LForm := _RootForm(LFormEditor);
        if not Assigned(LForm) then
        begin
          LReason := 'access-error';
          Exit;
        end;
        LCtx := TLiveFormContext.Create(LFormEditor, LForm);
        if Assigned(AWork) then
          AWork(LCtx);
        if LCtx.Failed then
        begin
          LReason := LCtx.Reason;
          Exit;
        end;
        if AIntent = liDesignMutation then
        begin
          LFormEditor.MarkModified;
          LChanged := True;
        end;
        LResult := True;
        LReason := '';
      end);
  except
    LResult  := False;
    LChanged := False;
    LReason  := 'access-error';
  end;
  AChanged := LChanged;
  if LResult then AReason := '' else AReason := LReason;
  Result := LResult;
end;

// ── Live-source primitives (harness-private). The Harness BPL is the LOW layer
//    that Tools.OTA depends on, so it cannot draw on FacadeShared — these mirror
//    its proven _FirstSourceEditor / _ActiveSourceEditor / _ReadBytes /
//    _ReplaceWholeBuffer bodies, ToolsAPI-only, no cross-BPL coupling. ──────────

function _FirstSourceEditor(const AModule: IOTAModule): IOTASourceEditor;
var
  LFor: Integer;
begin
  Result := nil;
  if not Assigned(AModule) then Exit;
  for LFor := 0 to AModule.GetModuleFileCount - 1 do
    if Supports(AModule.GetModuleFileEditor(LFor), IOTASourceEditor, Result) then
      Exit;
  Result := nil;
end;

function _ActiveSourceEditor: IOTASourceEditor;
var
  LServices: IOTAModuleServices;
  LModule: IOTAModule;
begin
  Result := nil;
  if not Assigned(BorlandIDEServices) then Exit;
  if not Supports(BorlandIDEServices, IOTAModuleServices, LServices) then Exit;
  LModule := LServices.CurrentModule;
  if Assigned(LModule) then
    Result := _FirstSourceEditor(LModule);
end;

function _ReadSourceBytes(const AReader: IOTAEditReader): string;
const
  CChunk = 256 * 1024;
var
  LChunk, LAll: TBytes;
  LRead, LPos, LTotal: Integer;
begin
  // R2: read the WHOLE buffer chunk by chunk (was a single 256KB GetText). The old cap made
  // _ReplaceSourceWhole's DeleteTo() cover only the first 256KB, so a unit >256KB kept its
  // original tail after a whole-buffer replace (silent corruption). Reading fully fixes both.
  Result := '';
  if not Assigned(AReader) then Exit;
  SetLength(LChunk, CChunk);
  LPos := 0;
  LTotal := 0;
  repeat
    LRead := AReader.GetText(LPos, PAnsiChar(@LChunk[0]), CChunk);
    if LRead > 0 then
    begin
      if LTotal + LRead > Length(LAll) then
        SetLength(LAll, (LTotal + LRead) * 2 + CChunk);
      Move(LChunk[0], LAll[LTotal], LRead);
      Inc(LTotal, LRead);
      Inc(LPos, LRead);
    end;
  until LRead < CChunk; // a short (or zero) read means we reached the buffer end
  if LTotal > 0 then
    Result := TEncoding.UTF8.GetString(LAll, 0, LTotal);
end;

procedure _RepaintTopEditView;
var
  LES: IOTAEditorServices;
begin
  if Supports(BorlandIDEServices, IOTAEditorServices, LES)
     and Assigned(LES.TopView) then
    LES.TopView.Paint;
end;

function _ReplaceSourceWhole(const ASource: IOTASourceEditor;
  const ANewText: string): Boolean;
var
  LWriter: IOTAEditWriter;
  LCurrent: string;
  LCurrentBytes: TBytes;
  LNewUtf8: UTF8String;
begin
  Result := False;
  if not Assigned(ASource) then Exit;
  LCurrent := _ReadSourceBytes(ASource.CreateReader);
  LCurrentBytes := TEncoding.UTF8.GetBytes(LCurrent);
  LNewUtf8 := UTF8Encode(ANewText);
  LWriter := ASource.CreateUndoableWriter;
  if not Assigned(LWriter) then Exit;
  // Insert the new text at position 0, then delete the original span — the
  // writer's output becomes exactly ANewText.
  LWriter.Insert(PAnsiChar(LNewUtf8));
  LWriter.DeleteTo(Length(LCurrentBytes));
  LWriter := nil;       // commit the edit before forcing the repaint
  _RepaintTopEditView;  // redraw now, not on the next user click
  Result := True;
end;

type
  TLiveSourceContext = class(TInterfacedObject, ILiveSourceContext)
  private
    FEditor: IOTASourceEditor;
    FFailed: Boolean;
    FReason: string;
    FDidWrite: Boolean;
  public
    constructor Create(const AEditor: IOTASourceEditor);
    function SourceEditor: IOTASourceEditor;
    function UnitPath: string;
    function ReadBuffer: string;
    function ReplaceWhole(const ANewText: string): Boolean;
    procedure RevealLine(const ALine: Integer);
    procedure Fail(const AReason: string);
    function Failed: Boolean;
    function Reason: string;
    function DidWrite: Boolean;
  end;

constructor TLiveSourceContext.Create(const AEditor: IOTASourceEditor);
begin
  inherited Create;
  FEditor := AEditor;
end;

function TLiveSourceContext.SourceEditor: IOTASourceEditor;
begin
  Result := FEditor;
end;

function TLiveSourceContext.UnitPath: string;
begin
  if Assigned(FEditor) then
    Result := FEditor.FileName
  else
    Result := '';
end;

function TLiveSourceContext.ReadBuffer: string;
begin
  if Assigned(FEditor) then
    Result := _ReadSourceBytes(FEditor.CreateReader)
  else
    Result := '';
end;

function TLiveSourceContext.ReplaceWhole(const ANewText: string): Boolean;
begin
  Result := _ReplaceSourceWhole(FEditor, ANewText);
  if Result then
    FDidWrite := True;
end;

procedure TLiveSourceContext.RevealLine(const ALine: Integer);
begin
  THarnessView.EnsureCodeView(FEditor, ALine);
end;

procedure TLiveSourceContext.Fail(const AReason: string);
begin
  FFailed := True;
  FReason := AReason;
end;

function TLiveSourceContext.Failed: Boolean;
begin
  Result := FFailed;
end;

function TLiveSourceContext.Reason: string;
begin
  Result := FReason;
end;

function TLiveSourceContext.DidWrite: Boolean;
begin
  Result := FDidWrite;
end;

class function THarnessView.WithLiveSource(const AUnitName: string; const AIntent: TLiveSourceIntent;
  const AWork: TLiveSourceWork;
  out AChanged: Boolean; out AReason: string): Boolean;
var
  LResult, LChanged: Boolean;
  LReason: string;
begin
  LResult  := False;
  LChanged := False;
  LReason  := 'unit-not-found';
  try
    TThread.Synchronize(nil,
      procedure
      var
        LModule: IOTAModule;
        LEditor: IOTASourceEditor;
        LCtx: ILiveSourceContext;
      begin
        // Resolve the source editor: a BLANK name targets the ACTIVE editor (the
        // scratch unit the user is in); a named/path unit resolves its module's
        // first source editor.
        LEditor := nil;
        if Trim(AUnitName) = '' then
          LEditor := _ActiveSourceEditor
        else if THarnessView.ResolveUnitModule(AUnitName, LModule) then
          LEditor := _FirstSourceEditor(LModule);
        if not Assigned(LEditor) then
        begin
          // Anti-hallucination (S3): a non-blank name that did not resolve to a
          // source editor is a phantom the agent invented — refuse with an
          // actionable reason instead of silently editing the active one.
          if Trim(AUnitName) <> '' then
            LReason := 'unit-not-resolved'
          else
            LReason := 'unit-not-found';
          Exit;
        end;
        // EnsureCodeView: a code MUTATION brings the editor forward and ends in
        // Code; a code read is view-agnostic (intent->view policy, CLAUDE.md).
        if AIntent = lsCodeMutation then
          THarnessView.EnsureCodeView(LEditor);
        LCtx := TLiveSourceContext.Create(LEditor);
        if Assigned(AWork) then
          AWork(LCtx);
        if LCtx.Failed then
        begin
          LReason := LCtx.Reason;
          Exit;
        end;
        LChanged := LCtx.DidWrite;
        LResult := True;
        LReason := '';
      end);
  except
    LResult  := False;
    LChanged := False;
    LReason  := 'access-error';
  end;
  AChanged := LChanged;
  if LResult then AReason := '' else AReason := LReason;
  Result := LResult;
end;

end.
