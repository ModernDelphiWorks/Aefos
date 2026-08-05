unit Aefos.MCP.OTA.ReviewGate;

{
  Change-review gate — the cross-cutting seam between the gutter-review BPL (which
  REGISTERS the red/green approver + its predicates) and the MCP write/save tools
  (which CONSULT them). Extracted from the TMCPWorkspaceFacade god-object as a
  shared foundation unit of the SOLID split (audit S6 / facade split) — a sibling
  of Aefos.MCP.OTA.FacadeShared, NOT a domain service.

  It exists because review is a concern shared by many domains at once: EditUnit /
  ReplaceInEditor / SetEditorFullContent (editor write), InsertMethod (code
  insight) and AddEventHandler (forms) all route through the same approver, and
  every save path runs the same pre-save flush. Hoisting the four seams here lets
  each of those services come out of the facade independently while still resolving
  the one approver — none of them needs to see the others, and the gutter-review
  registrar no longer depends on the facade at all (it now uses this unit).

  Four process-global seams, each set by the gutter-review BPL and cleared (nil) on
  unload so the ref never dangles into an unmapped BPL:
    - diff approver         (SetGlobalDiffApprover / GlobalDiffApprover)
    - pre-save flush        (SetReviewSaveFlush / RunReviewSaveFlush)
    - pending-review query  (SetReviewPendingQuery / ReviewPendingForUnit)
    - auto-accept predicate (SetReviewAutoAccept / ReviewAutoAccept)

  Bodies moved VERBATIM from the facade. The higher-level ReviewBufferChange wrapper
  (and its ChangedSpan diff-localizer) live here too, resolving GlobalDiffApprover
  locally. All routines are now class methods of TReviewGate (the seam's named owner).
}

interface

uses
  System.SysUtils,
  Aefos.MCP.Types;

type
  // The change-review seam as a sealed static namespace (never instantiated). The
  // process-global registrations it fronts live in the implementation section and
  // are cleared (nil) on BPL unload; every routine here is a class method so the
  // seam has a named owner instead of a loose grab-bag of unit functions.
  TReviewGate = class sealed
  public
    // Inline diff approval seam (ESP 2026-06-10). The Chat BPL registers an approver
    // that routes the agent's EditUnit through the red/green editor diff; nil = apply
    // silently (current behaviour).
    class procedure SetGlobalDiffApprover(const AApprover: IMCPDiffApprover); static;
    class function GlobalDiffApprover: IMCPDiffApprover; static;
    // Pre-save flush seam. The gutter-review BPL registers a proc that strips its pending
    // "before" (red) blocks from the buffer BEFORE any module write, so a save never persists
    // the doubled old+new review text. nil = no review active. Called on the main thread from
    // the facade's save methods, right before IOTAModule.Save.
    class procedure SetReviewSaveFlush(const AProc: TProc); static;
    class procedure RunReviewSaveFlush; static;
    // Pending-review query seam. The gutter-review BPL registers a predicate reporting whether
    // a unit still has UNRESOLVED red/green review blocks stacked in its buffer. Whole-buffer
    // event/code rewrite tools (AddEventHandler) consult it and REFUSE ('review-pending') rather
    // than parse + overwrite a polluted buffer — which mangles the .pas and makes the IDE strip
    // the matching .dfm event wires (the proven nota-10 break, 2026-06-23). nil = no review
    // active (no guard). Cleared on unload so it never dangles into an unmapped BPL.
    class procedure SetReviewPendingQuery(const AFunc: TFunc<string, Boolean>); static;
    class function ReviewPendingForUnit(const AUnitPath: string): Boolean; static;
    // GLOBAL twin of the above: True when ANY unit still has unresolved review blocks
    // (the gutter-review BPL registers GChanges.Count > 0). The SaveAllFiles guard
    // consults it so a save cannot silently auto-accept + clear pending ✓/✗ gutters the
    // user has not resolved. nil = no review active (no guard).
    class procedure SetReviewPendingGlobalQuery(const AFunc: TFunc<Boolean>); static;
    class function ReviewPendingGlobal: Boolean; static;
    // Auto-accept (agent auto-save) seam. The gutter-review BPL registers a predicate that
    // reflects the "AI Flow → Agent auto-save edits" setting. When TRUE, the review-pending
    // guard does NOT refuse a whole-buffer rewrite (AddEventHandler) that lands on a unit with
    // an unresolved review: it AUTO-ACCEPTS the prior review first (flush red, keep green — the
    // same outcome as the user calling Save) so the buffer is clean, then lets the edit pass.
    // When FALSE, the guard refuses as before so diffs persist for manual approval. This moves
    // the "save to unblock" decision out of the agent's hands and into a config (2026-06-23).
    // nil = honour "let it pass" by default (no manual-approval gate registered).
    class procedure SetReviewAutoAccept(const AFunc: TFunc<Boolean>); static;
    class function ReviewAutoAccept: Boolean; static;

    // --- diff-localization + whole-buffer review wrapper ----------------------
    // These two are the WRITE side of the gate (consumed by the editor-write, code-
    // insight and forms services); they live here next to the approver they drive.

    // Minimal changed LINE SPAN between AOld and ANew: AOldSpan = the old lines from
    // the first differing line to the last, ANewSpan = the matching new lines. Feeds
    // any whole-buffer change (single OR scattered global Find/Replace) into the
    // line-based inline diff as ONE contiguous block — interspersed unchanged lines
    // inside the span are preserved verbatim in ANewSpan, so applying the block is an
    // exact replacement. False when the texts are equal or the old span is empty.
    class function ChangedSpan(const AOld, ANew: string;
      out AOldSpan, ANewSpan: string): Boolean; static;

    // Route a whole-buffer change (AOld -> ANew) through the inline diff approver so
    // ANY code-writing tool — not just EditUnit — is reviewable + rejectable-with-reason
    // (ESP, maintainer ask). ChangedSpan localizes the diff to the changed block —
    // including pure insertions, which it anchors on the unchanged lines adjacent to the
    // insertion point so the gutter shows a small block instead of the whole buffer. Only
    // an all-blank anchor (or a degenerate span) still falls back to a whole-buffer diff
    // (always locatable). Returns the approver's decision and the user's optional rejection
    // note in AReason. ddUnavailable when no approver is registered / review is off /
    // nothing changed — the caller then applies silently.
    class function ReviewBufferChange(const AUnitPath, AOld, ANew: string;
      out AReason: string): TMCPDiffDecision; static;
  end;

implementation

var
  // Process-global inline diff approver (see interface). Interface ref so it is
  // reference-counted; the Chat BPL clears it (nil) on unload.
  GGlobalDiffApprover: IMCPDiffApprover = nil;

class procedure TReviewGate.SetGlobalDiffApprover(const AApprover: IMCPDiffApprover);
begin
  GGlobalDiffApprover := AApprover;
end;

class function TReviewGate.GlobalDiffApprover: IMCPDiffApprover;
begin
  Result := GGlobalDiffApprover;
end;

var
  // Process-global pre-save flush (see interface). Set by the gutter-review BPL; nil = no
  // review pending. Cleared on unload so it never dangles into an unmapped BPL.
  GReviewSaveFlush: TProc = nil;

class procedure TReviewGate.SetReviewSaveFlush(const AProc: TProc);
begin
  GReviewSaveFlush := AProc;
end;

// Runs the registered pre-save flush (strips review "before" blocks) on the calling
// (main) thread. Best-effort: a failure must never abort the save.
class procedure TReviewGate.RunReviewSaveFlush;
begin
  if Assigned(GReviewSaveFlush) then
    try
      GReviewSaveFlush();
    except
      // never let a flush failure break the save
    end;
end;

var
  // Process-global pending-review predicate (see interface). Set by the gutter-review BPL;
  // nil = no review pending. Cleared on unload so it never dangles into an unmapped BPL.
  GReviewPendingQuery: TFunc<string, Boolean> = nil;

class procedure TReviewGate.SetReviewPendingQuery(const AFunc: TFunc<string, Boolean>);
begin
  GReviewPendingQuery := AFunc;
end;

// True when AUnitPath still carries UNRESOLVED change-review blocks. Best-effort: any failure
// (or no review registered) reports False so the guard never blocks a legitimate write.
class function TReviewGate.ReviewPendingForUnit(const AUnitPath: string): Boolean;
begin
  Result := False;
  if (Trim(AUnitPath) <> '') and Assigned(GReviewPendingQuery) then
    try
      Result := GReviewPendingQuery(AUnitPath);
    except
      Result := False;
    end;
end;

var
  // Process-global "any review pending" predicate (see interface). Set by the gutter-review
  // BPL; nil = no review active. Cleared on unload so it never dangles into an unmapped BPL.
  GReviewPendingGlobalQuery: TFunc<Boolean> = nil;

class procedure TReviewGate.SetReviewPendingGlobalQuery(const AFunc: TFunc<Boolean>);
begin
  GReviewPendingGlobalQuery := AFunc;
end;

// True when ANY unit still carries UNRESOLVED change-review blocks. Best-effort: any
// failure (or no review registered) reports False so the guard never blocks a save the
// user would expect to succeed.
class function TReviewGate.ReviewPendingGlobal: Boolean;
begin
  Result := False;
  if Assigned(GReviewPendingGlobalQuery) then
    try
      Result := GReviewPendingGlobalQuery();
    except
      Result := False;
    end;
end;

var
  // Process-global auto-accept predicate (see interface). Set by the gutter-review BPL from
  // the "Agent auto-save edits" AI Flow setting. Cleared on unload so it never dangles.
  GReviewAutoAcceptQuery: TFunc<Boolean> = nil;

class procedure TReviewGate.SetReviewAutoAccept(const AFunc: TFunc<Boolean>);
begin
  GReviewAutoAcceptQuery := AFunc;
end;

// True when the agent may auto-save (auto-accept the prior review) to keep flowing. Defaults
// to TRUE so that, absent any registered manual-approval gate, edits simply pass through —
// the maintainer's "let it pass even if the previous review is unresolved" contract.
class function TReviewGate.ReviewAutoAccept: Boolean;
begin
  Result := True;
  if Assigned(GReviewAutoAcceptQuery) then
    try
      Result := GReviewAutoAcceptQuery();
    except
      Result := True;
    end;
end;

class function TReviewGate.ChangedSpan(const AOld, ANew: string;
  out AOldSpan, ANewSpan: string): Boolean;
var
  LOld, LNew: TArray<string>;
  LTop, LBotOld, LBotNew: Integer;
  LAncTop, LAncBot, LNewEnd: Integer;
begin
  AOldSpan := '';
  ANewSpan := '';
  Result := False;
  if AOld = ANew then
    Exit;
  LOld := AOld.Replace(#13#10, #10).Replace(#13, #10).Split([#10]);
  LNew := ANew.Replace(#13#10, #10).Replace(#13, #10).Split([#10]);
  LTop := 0;                                   // skip equal leading lines
  while (LTop <= High(LOld)) and (LTop <= High(LNew)) and
        (LOld[LTop] = LNew[LTop]) do
    Inc(LTop);
  LBotOld := High(LOld);                        // skip equal trailing lines
  LBotNew := High(LNew);
  while (LBotOld >= LTop) and (LBotNew >= LTop) and
        (LOld[LBotOld] = LNew[LBotNew]) do
  begin
    Dec(LBotOld);
    Dec(LBotNew);
  end;
  if LBotOld < LTop then
  begin
    // Pure insertion (no old lines removed). Anchor the diff on the unchanged lines
    // ADJACENT to the insertion point — the common-prefix tail (LTop-1) and the
    // common-suffix head (LTop) — so the approver can locate a small, real block (and
    // show the inserted lines BETWEEN them) instead of falling back to a whole-buffer
    // diff (the "changed everything" UX). AOldSpan = the anchor lines; ANewSpan = the
    // same anchors with the inserted lines spliced in. A two-line anchor is far more
    // locatable than a bare blank line; an all-blank anchor still trips the caller's
    // Trim guard and falls back to the whole-buffer diff (safe).
    if LTop > 0 then
      LAncTop := LTop - 1          // include the prefix-tail anchor when present
    else
      LAncTop := LTop;             // insertion at the very top — suffix-head only
    if LTop > High(LOld) then
    begin
      LAncBot := High(LOld);       // insertion at EOF — prefix-tail anchor only
      LNewEnd := LBotNew;
    end
    else
    begin
      LAncBot := LTop;             // include the suffix-head anchor
      LNewEnd := LBotNew + 1;      // ...and its image in the new text
    end;
    if (LAncTop >= 0) and (LAncBot >= LAncTop) and (LNewEnd >= LAncTop) then
    begin
      AOldSpan := string.Join(#13#10, LOld, LAncTop, LAncBot - LAncTop + 1);
      ANewSpan := string.Join(#13#10, LNew, LAncTop, LNewEnd - LAncTop + 1);
      Result := True;
    end;
    Exit;
  end;
  AOldSpan := string.Join(#13#10, LOld, LTop, LBotOld - LTop + 1);
  if LBotNew >= LTop then
    ANewSpan := string.Join(#13#10, LNew, LTop, LBotNew - LTop + 1);
  Result := True;
end;

class function TReviewGate.ReviewBufferChange(const AUnitPath, AOld, ANew: string;
  out AReason: string): TMCPDiffDecision;
var
  LApprover: IMCPDiffApprover;
  LOldBlock, LNewBlock: string;
begin
  AReason := '';
  Result := ddUnavailable;
  if AOld = ANew then
    Exit;
  LApprover := GlobalDiffApprover;
  if not Assigned(LApprover) then
    Exit;
  if ChangedSpan(AOld, ANew, LOldBlock, LNewBlock) and (Trim(LOldBlock) <> '') then
    Result := LApprover.ReviewEdit(AUnitPath, LOldBlock, LNewBlock, AReason)
  else
    Result := LApprover.ReviewEdit(AUnitPath, AOld, ANew, AReason);
end;

end.
