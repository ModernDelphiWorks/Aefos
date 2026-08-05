unit Aefos.MCP.IntentGuard;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  RULE #1 (CLAUDE.md), single source of truth. Every mutating MCP command has an
  INTENT (design or code) and must run with the IDE in the matching view; Delphi
  is modal (a module shows the Form Designer OR the editor, never both). Each tool
  DECLARES its own intent in TMCPToolDescriptor.Intent (correct by construction, no
  name table to drift); this unit owns the enum, the one rule string per intent,
  the one rejection message, and a DEBUG self-test that catches a mutating tool
  which forgot to declare. RegisterTool reads the declared intent for both the
  description suffix and the guard — no per-tool copies of the rule text.

  Core stays OTA-free: the live view check is injected by the OTA layer as a
  TMCPViewProvider; this unit only classifies, phrases and decides. Strings are
  English-only and terse (they ship on every tools/list + every rejection). }

interface

type
  // The view a command needs (and what the IDE is currently showing).
  TMCPToolIntent = (tiNeutral, tiDesign, tiCode);

  // The OTA layer injects this so Core never imports ToolsAPI. Returns the view
  // the IDE is showing NOW (IOTAModule.CurrentEditor); tiNeutral when unknown.
  // FPC 3.2.2 has no anonymous-method (`reference to`) support; the OTA layer
  // that assigns this is Delphi-only (phase F), so the FPC build gets a
  // method-pointer placeholder purely so the type declaration compiles — nothing
  // in this unit's own pure logic uses it.
{$IFNDEF FPC}
  TMCPViewProvider = reference to function: TMCPToolIntent;
{$ELSE}
  TMCPViewProvider = function: TMCPToolIntent of object;
{$ENDIF}

const
  // Machine-actionable rejection reason codes (the agent self-corrects on these).
  MCP_REASON_WRONG_VIEW_DESIGN = 'wrong-view-design'; // in Design, got CODE cmd
  MCP_REASON_WRONG_VIEW_CODE   = 'wrong-view-code';   // in Code, got DESIGN cmd

type
  // RULE #1 decision surface as a sealed static namespace: classify a tool's
  // intent, phrase its rule/rejection, decide a view mismatch. Never instantiated
  // (the class is the namespace — no per-tool copies of the rule text).
  TIntentGuard = class sealed
  public
    // DEBUG self-test oracle (no positive name table any more — each tool DECLARES
    // its intent in TMCPToolDescriptor.Intent). Returns True when AName carries a
    // mutating prefix (Add/Set/Remove/Insert/Replace) yet declares tiNeutral AND is
    // not in the reviewed view-neutral allowlist — i.e. a mutating tool that forgot
    // to declare a design/code intent. RegisterTool asserts on this in DEBUG so the
    // failure is LOUD at registration instead of a silent loss of the guard.
    class function MutatingNameNeedsIntent(const AName: string;
      const AIntent: TMCPToolIntent): Boolean; static;

    // One-line rule appended to a guarded tool's description. '' for tiNeutral.
    class function IntentRuleSuffix(const AIntent: TMCPToolIntent): string; static;

    // Reject reason code for sending AIntent while the IDE shows ACurrent. '' = ok.
    class function WrongViewReason(const AIntent, ACurrent: TMCPToolIntent): string; static;

    // Terse English message paired with WrongViewReason (tells the agent the fix).
    class function WrongViewMessage(const AReason: string): string; static;
  end;

implementation

uses
  SysUtils;

const
  // Mutating verb prefixes the DEBUG self-test screens for. Historically every
  // view-mutating tool starts with one of these; a new tool that does and stays
  // tiNeutral (and is not allowlisted below) is almost certainly a forgotten
  // intent declaration.
  CMutatingPrefixes: array[0..9] of string = (
    'Add', 'Set', 'Remove', 'Insert', 'Replace',
    // R9: the oracle was blind to these whole-file / structural mutating verbs, so a
    // forgotten-intent tool named Overwrite*/Delete*/Rename*/Move*/Fix* leaked past the
    // self-test. Now screened too; the neutral ones are allowlisted just below.
    'Overwrite', 'Delete', 'Rename', 'Move', 'Fix');

  // Tools whose NAME carries a mutating prefix but that are legitimately view-
  // NEUTRAL: they mutate project / group / file / config / search-path / editor-
  // cursor state, not the active module's Design or Code view. Listed explicitly
  // so the self-test does not false-flag them. Reviewed 2026-06-27; keep in sync
  // when a genuinely view-neutral mutating-prefixed tool is added (the alternative
  // — a silent miss — is exactly what this guard exists to prevent).
  // NOTE: SetDFMContent / SetDPRContent write whole-file content and self-manage
  // the view (save-first + show); kept neutral here to preserve current behaviour
  // — revisit if they should become design/code-guarded.
  // Debug family: SetBreakpoint / SetTracepoint / RemoveBreakpoint /
  // SetCurrentThread mutate DEBUGGER state (breakpoint list, current-thread
  // selection), never the active module's Design/Code view - view-neutral by
  // design. (RunToLine / GetExceptionInfo carry no mutating prefix, so the
  // oracle never screens them.)
  CNeutralMutators: array[0..36] of string = (
    'AddConditionalDefine', 'AddPackageToProject', 'AddProjectToGroup',
    'AddResourceFile', 'AddToLibraryPath', 'AddToSearchPath', 'AddUnit',
    'AddUnitToProject', 'RemoveConditionalDefine', 'RemovePackageFromProject',
    'RemoveProjectFromGroup', 'RemoveUnitFromProject',
    'ReplaceInProject', 'SetActiveConfiguration', 'SetActiveProject',
    'SetActiveProjectPlatform', 'SetConditionalDefines', 'SetDCUOutputDir',
    'SetDFMContent', 'SetDPRContent', 'SetEditorCursorPosition', 'SetMainForm',
    'SetProjectDescription', 'SetProjectOutputDir', 'SetProjectVersion',
    'SetSearchPath',
    // R9: whole-file / structural writers, view-neutral like SetDFMContent/SetDPRContent
    // (they self-manage the view or touch project/file structure, not the active
    // module's Design/Code view). OverwriteFile refuses .dfm + phantom .pas and is
    // consent-gated; the Rename/Move/Delete/Fix ops are project-structural.
    'DeleteUnit', 'FixEncoding', 'MoveUnitToFolder', 'OverwriteFile',
    'RenameDPR', 'RenameProject', 'RenameUnit',
    // Debug family (see the note above the array).
    'SetBreakpoint', 'SetTracepoint', 'RemoveBreakpoint', 'SetCurrentThread');

  // The single rule string per intent — short on purpose (ships everywhere).
  SDesignRule =
    ' [design cmd: needs Design view (call OpenFormDesigner first). Static UI ' +
    'state — Caption/Text, Font, Fill/Stroke/colors, size, TextPrompt, Visible, ' +
    'Align — goes HERE via SetComponentProperty (nested ok, e.g. Fill.Color), ' +
    'NOT in FormCreate.]';
  SCodeRule =
    ' [code cmd: needs Code view (call OpenUnitInEditor first). Only runtime ' +
    'logic here — never static design state.]';

class function TIntentGuard.MutatingNameNeedsIntent(const AName: string;
  const AIntent: TMCPToolIntent): Boolean;
var
  LPrefix, LNeutral: string;
  LLooksMutating: Boolean;
begin
  Result := False;
  if AIntent <> tiNeutral then
    Exit; // the tool declared design/code intent — nothing to flag
  LLooksMutating := False;
  for LPrefix in CMutatingPrefixes do
    // Case-sensitive prefix test (classic RTL form of the Delphi-only
    // AName.StartsWith helper, which FPC 3.2.2 lacks).
    if Copy(AName, 1, Length(LPrefix)) = LPrefix then
    begin
      LLooksMutating := True;
      Break;
    end;
  if not LLooksMutating then
    Exit; // a read/build/run/git/view-switch name — neutral is correct
  for LNeutral in CNeutralMutators do
    if SameText(LNeutral, AName) then
      Exit; // explicitly reviewed as view-neutral
  Result := True; // mutating-looking, neutral, not allowlisted => needs a decision
end;

class function TIntentGuard.IntentRuleSuffix(const AIntent: TMCPToolIntent): string;
begin
  case AIntent of
    tiDesign: Result := SDesignRule;
    tiCode:   Result := SCodeRule;
  else
    Result := '';
  end;
end;

class function TIntentGuard.WrongViewReason(const AIntent, ACurrent: TMCPToolIntent): string;
begin
  // Only a real cross-view mismatch rejects. tiNeutral on either side = allow
  // (unguarded tool, or the view is unknown — never block on uncertainty).
  if (AIntent = tiCode) and (ACurrent = tiDesign) then
    Result := MCP_REASON_WRONG_VIEW_DESIGN
  else if (AIntent = tiDesign) and (ACurrent = tiCode) then
    Result := MCP_REASON_WRONG_VIEW_CODE
  else
    Result := '';
end;

class function TIntentGuard.WrongViewMessage(const AReason: string): string;
begin
  if AReason = MCP_REASON_WRONG_VIEW_DESIGN then
    Result := 'IDE is in Design but this is a code command. ' +
      'Call OpenUnitInEditor, then resend.'
  else if AReason = MCP_REASON_WRONG_VIEW_CODE then
    Result := 'IDE is in Code but this is a design command. ' +
      'Call OpenFormDesigner, then resend.'
  else
    Result := '';
end;

end.
