unit Aefos.MCP.OTA.CodeInsightWriteService;

{
  Code-insight WRITE tools, extracted from the TMCPWorkspaceFacade god-object as a
  focused service of the SOLID split (audit S6 / facade split).

  Owns InsertMethod — insert a method (signature + body) into a class on the active
  scratch unit, routed through the change-review gate. The OTA-free structure
  decisions (class resolution, decl + implementation insertion points, the qualified
  header) live in ContentWritePolicy.PlanMethodInsertion; this service marshals the
  resulting whole-buffer replace as one undoable OTA write. No facade state (no
  FAudit), no public-method delegation: every dependency is drawn from an already-
  shared unit —
    - FacadeShared: ResolveUnitModule / FirstSourceEditor / ActiveSourceEditor /
      ReadBytes / ReplaceWholeBuffer / LineOfOffset
    - ReviewGate:   TReviewGate.ReviewBufferChange
    - ContentWritePolicy: PlanMethodInsertion
    - Aefos.Harness.View: EnsureCodeView (RULE #1 — the insert lands/ends in Code)

  Body moved VERBATIM from the facade (only the class qualifier changes), so the
  three-step plan/review/apply flow, the ddApplied/ddRejected handling and the
  intent->view reveal of the inserted method are identical. The facade keeps its
  frozen IMCPWorkspaceFacade.InsertMethod and delegates it to a refcounted
  FCodeInsight field.
}

interface

type
  IMCPCodeInsightWriteService = interface
    ['{4D7C1E94-8B53-4A20-9F38-2C6A1B5E8D70}']
    function InsertMethod(const AUnitName, AClassName, ASignature, ABody: string;
      out AChanged: Boolean; out AReason: string): Boolean;
  end;

// Factory — the facade calls this once in its constructor.
function NewMCPCodeInsightWriteService: IMCPCodeInsightWriteService;

implementation

uses
  System.SysUtils,
  System.Classes,
  ToolsAPI,
  Aefos.Harness.View,
  Aefos.MCP.Types,
  Aefos.MCP.OTA.FacadeShared,
  Aefos.MCP.OTA.ReviewGate,
  Aefos.MCP.OTA.ContentWritePolicy;

type
  TMCPCodeInsightWriteService = class(TInterfacedObject, IMCPCodeInsightWriteService)
  public
    function InsertMethod(const AUnitName, AClassName, ASignature, ABody: string;
      out AChanged: Boolean; out AReason: string): Boolean;
  end;

function TMCPCodeInsightWriteService.InsertMethod(const AUnitName, AClassName,
  ASignature, ABody: string;
  out AChanged: Boolean; out AReason: string): Boolean;
var
  LChanged, LPlanOk: Boolean;
  LReason, LCurrent, LNew, LMethodName, LPlanReason, LUnitPath, LDiffReason: string;
  LEditorRef: IOTASourceEditor;
begin
  LPlanOk  := False;
  LEditorRef := nil;
  // Step 1 (main thread): resolve the target editor, read the buffer and compute
  // the new content. No mutation yet, so the approver can preview it.
  try
    TThread.Synchronize(nil, procedure
    var
      LModule: IOTAModule;
    begin
      if (Trim(AUnitName) <> '') and TFacadeShared.ResolveUnitModule(AUnitName, LModule) then
        LEditorRef := TFacadeShared.FirstSourceEditor(LModule);
      if not Assigned(LEditorRef) then
        if not TFacadeShared.ActiveSourceEditor(LEditorRef) then
          Exit;
      LUnitPath := LEditorRef.FileName;
      LCurrent := TFacadeShared.ReadBytes(LEditorRef.CreateReader);
      LPlanOk := TContentWritePolicy.PlanMethodInsertion(LCurrent, AClassName, ASignature, ABody,
        LNew, LMethodName, LPlanReason);
    end);
  except
    on E: Exception do
    begin
      AChanged := False; AReason := E.Message; Exit(False);
    end;
  end;
  if not Assigned(LEditorRef) then
  begin
    AChanged := False; AReason := 'no-active-editor'; Exit(False);
  end;
  if not LPlanOk then
  begin
    AChanged := False; AReason := LPlanReason; Exit(False);
  end;

  // Step 2 (off the main thread, like EditUnit): route through the inline diff so
  // the insertion is reviewable + rejectable-with-reason. ddApplied => the approver
  // applied it; ddRejected => abort with the user's note; ddUnavailable => fall
  // through to the silent apply below.
  case TReviewGate.ReviewBufferChange(LUnitPath, LCurrent, LNew, LDiffReason) of
    ddApplied:
      begin
        AChanged := True; AReason := ''; Exit(True);
      end;
    ddRejected:
      begin
        AChanged := False;
        if LDiffReason <> '' then
          AReason := 'change rejected by the user in the inline diff: ' + LDiffReason
        else
          AReason := 'change rejected by the user in the inline diff';
        Exit(False);
      end;
  end;

  // Step 3 (silent apply) — no approver / review off — via the WithLiveSource
  // harness seam (S2, the code twin of WithLiveForm). Re-resolves the SAME editor
  // by the path Step 1 captured (LUnitPath), flips to Code, replaces the buffer and
  // reveals the inserted method — mirrors EditUnit / InsertCodeAtCursor. Passing the
  // resolved path (not the raw AUnitName) keeps Step 3 on Step 1's exact editor.
  LReason := 'edit-failed';
  Result := THarnessView.WithLiveSource(LUnitPath, lsCodeMutation,
    procedure(const Ctx: ILiveSourceContext)
    begin
      if Ctx.ReplaceWhole(LNew) then
        Ctx.RevealLine(TFacadeShared.LineOfOffset(LNew, Pos(AClassName + '.' + LMethodName, LNew)))
      else
        Ctx.Fail('edit-failed');
    end,
    LChanged, LReason);
  AChanged := Result;
  AReason  := LReason;
end;

function NewMCPCodeInsightWriteService: IMCPCodeInsightWriteService;
begin
  Result := TMCPCodeInsightWriteService.Create;
end;

end.
