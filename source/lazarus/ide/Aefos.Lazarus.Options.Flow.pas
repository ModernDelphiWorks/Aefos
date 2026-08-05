unit Aefos.Lazarus.Options.Flow;

{ Aefos AI - Lazarus edition: the "AI Flow" IDE options page.

  A second editor under the "Aefos AI" options group, mirroring the RAD Studio
  plugin's shared "AI Flow" page (Aefos.OTA.Options.AIFlow). It surfaces the
  agent-behaviour knobs the owner asked for - "auto approve" and "ask
  authorization for execution" - plus the edit-review, auto-save and issue-
  reporting preferences, reaching parity with the Delphi page's control set.

  ONE BRAIN persistence (owner rule 2026-07-17): these knobs are read/written
  through the SHARED config core (Aefos.OTA.Chat.Core.Config) against the GLOBAL
  root %APPDATA%\Aefos, i.e. the SAME %APPDATA%\Aefos\.aefos\config.json file and
  the SAME TConfig record the RAD Studio plugin uses - NOT a lazarus-only store.
  A user who runs both editions shares auto-approve / authorize-execution across
  them. The page follows the shared binding's read-modify-write discipline (load
  the full snapshot, overlay only the fields this page owns, save) so a sibling
  page saved in the same dialog is never clobbered.

  NOTE on the RAD side: the Delphi "AI Flow" page currently persists the same
  knobs in the IDE registry (<BDS base>\Aefos); the fields now ALSO live in the
  shared config.json, so repointing the RAD page/consumer at TConfig completes
  the unification (a RAD-side follow-up - the file is already shared).

  Consumption honesty (the port degrades honest, it never fakes a live knob):
    * Tool permissions (consent) mode is LIVE on the port - the Lazarus MCP tools
      registrar's write-consent gate reads TConfig.AgentConsentMode: "Auto-
      approve ..." (1/2) grants writes without the modal; "Ask every time" (0)
      keeps the per-session consent prompt. This is the owner's "auto approve /
      pedir autorizacao para execucao" made real on the port.
    * Agent edit-review mode is LIVE - the inline-diff review gutter
      (Aefos.Lazarus.GutterReview) sprouts the red/green diff on every applied edit
      unless "Apply silently" is chosen.
    * Agent auto-save is LIVE - when enabled, the review gutter still SHOWS the diff
      but auto-approves it on the next save / next edit over it
      (TAefosLazGutterReview.AutoSaveEnabled), the port twin of the RAD auto-accept
      predicate (Aefos.OTA.IDE.GutterReview.pas:2037).
    * Issue reporting is LIVE - the Lazarus ProposeAefosIssue MCP tool
      (Aefos.Lazarus.IssueReport, registered in Aefos.Lazarus.McpTools) reads THIS
      toggle: when OFF (default) the tool returns {sent:false} without opening any
      UI; when ON, a connected AI can pop the editable issue dialog. The Lazarus
      consumer that was a later slice has landed (twin of the RAD
      Aefos.OTA.MCP.IssueReport tool).

  Built in code (like the sibling AI Chat page), so the accompanying .lfm carries
  ONLY the empty frame root - required so TCustomFrame.Create's
  InitInheritedComponent finds a resource (customframe.inc:215 raises
  EResNotFound otherwise). All literals ASCII, so the file needs no BOM. }

{$mode delphi}
{$H+}

interface

uses
  Classes,
  Controls,
  StdCtrls,
  IDEOptEditorIntf,
  IDEOptionsIntf,
  Aefos.OTA.Chat.Core.Config.Types;

type
  { The Aefos AI "AI Flow" options page (agent-behaviour knobs) - Delphi parity. }
  TAefosFlowOptionsFrame = class(TAbstractIDEOptionsEditor)
  private
    FBuilt: Boolean;
    FHeaderLabel: TLabel;
    FConsentLabel: TLabel;
    FConsentCombo: TComboBox;
    FConsentHint: TLabel;
    FEditReviewLabel: TLabel;
    FEditReviewCombo: TComboBox;
    FAutoSaveCheck: TCheckBox;
    FIssueReportCheck: TCheckBox;
    FSeamNote: TLabel;
    { The GLOBAL config root the shared core resolves against - %APPDATA%\Aefos.
      Returned as UnicodeString to bind the delphiunicode resolver seam (mirror
      of the AI Chat page). }
    function _ResolveConfigRoot: UnicodeString;
    { A fresh shared config service bound to the global root. }
    function _BuildConfigService: IConfig;
  public
    function GetTitle: String; override;
    procedure Setup(ADialog: TAbstractOptionsEditorDialog); override;
    procedure ReadSettings(AOptions: TAbstractIDEOptions); override;
    procedure WriteSettings(AOptions: TAbstractIDEOptions); override;
    class function SupportedOptionsClass: TAbstractIDEOptionsClass; override;
  end;

implementation

uses
  SysUtils,
  LazUTF8,
  LazLoggerBase,               // DebugLn for the before-Setup breadcrumbs
  Aefos.Lazarus.OptionsGroup,  // TAefosIDEOptions (the shared group container)
  Aefos.OTA.Chat.Core.Config;

const
  cXLabel = 12;
  cXInput = 200;
  cWInput = 320;

function TAefosFlowOptionsFrame._ResolveConfigRoot: UnicodeString;
var
  LAppData: string;
begin
  // %APPDATA%\Aefos - identical to the RAD plugin's global root, so the file the
  // core reads/writes is exactly %APPDATA%\Aefos\.aefos\config.json for both.
  LAppData := GetEnvironmentVariable('APPDATA');
  Result := UTF8ToUTF16(LAppData + '\Aefos');
end;

function TAefosFlowOptionsFrame._BuildConfigService: IConfig;
var
  LResolver: TConfigRootResolver;
begin
  // Bind the resolver as a method pointer (of object) - the FPC delphi-mode idiom
  // for the shared config seam (mirror of the AI Chat page's _BuildConfigService).
  LResolver := Self._ResolveConfigRoot;
  Result := TConfigService.Create(LResolver);
end;

function TAefosFlowOptionsFrame.GetTitle: String;
begin
  // Mirrors the RAD Studio page caption (Tools > Options > Aefos > AI Flow).
  Result := 'AI Flow';
end;

procedure TAefosFlowOptionsFrame.Setup(ADialog: TAbstractOptionsEditorDialog);
begin
  if FBuilt then
    Exit;
  FBuilt := True;

  FHeaderLabel := TLabel.Create(Self);
  FHeaderLabel.Parent := Self;
  FHeaderLabel.Left := cXLabel;
  FHeaderLabel.Top := 12;
  FHeaderLabel.Caption := 'Agent behaviour and permissions';

  // --- Tool permissions (consent) mode --------------------------------------
  FConsentLabel := TLabel.Create(Self);
  FConsentLabel.Parent := Self;
  FConsentLabel.Left := cXLabel;
  FConsentLabel.Top := 51;
  FConsentLabel.Caption := 'Tool permissions:';

  FConsentCombo := TComboBox.Create(Self);
  FConsentCombo.Parent := Self;
  FConsentCombo.Left := cXInput;
  FConsentCombo.Top := 47;
  FConsentCombo.Width := cWInput;
  FConsentCombo.Style := csDropDownList;
  // Item order MUST match the 0/1/2 mode contract (Delphi parity) so ItemIndex
  // maps 1:1 to TConfig.AgentConsentMode.
  FConsentCombo.Items.Add('Ask every time (recommended)');
  FConsentCombo.Items.Add('Auto-approve edits, ask before destructive');
  FConsentCombo.Items.Add('Auto-approve everything (no prompts)');

  FConsentHint := TLabel.Create(Self);
  FConsentHint.Parent := Self;
  FConsentHint.Left := cXInput;
  FConsentHint.Top := 75;
  FConsentHint.Caption :=
    'Governs whether a connected AI must ask before editing your code.';

  // --- Agent edit review mode ------------------------------------------------
  FEditReviewLabel := TLabel.Create(Self);
  FEditReviewLabel.Parent := Self;
  FEditReviewLabel.Left := cXLabel;
  FEditReviewLabel.Top := 111;
  FEditReviewLabel.Caption := 'Inline edit review:';

  FEditReviewCombo := TComboBox.Create(Self);
  FEditReviewCombo.Parent := Self;
  FEditReviewCombo.Left := cXInput;
  FEditReviewCombo.Top := 107;
  FEditReviewCombo.Width := cWInput;
  FEditReviewCombo.Style := csDropDownList;
  // 0=Wait, 1=Preview (default), 2=Silent - matches TConfig.AgentEditReviewMode.
  FEditReviewCombo.Items.Add('Wait for my approval');
  FEditReviewCombo.Items.Add('Preview then apply (default)');
  FEditReviewCombo.Items.Add('Apply silently');

  FAutoSaveCheck := TCheckBox.Create(Self);
  FAutoSaveCheck.Parent := Self;
  FAutoSaveCheck.Left := cXLabel;
  FAutoSaveCheck.Top := 143;
  FAutoSaveCheck.Width := cWInput + cXInput;
  FAutoSaveCheck.Caption := 'Agent auto-save edits (pass pending reviews automatically)';

  FIssueReportCheck := TCheckBox.Create(Self);
  FIssueReportCheck.Parent := Self;
  FIssueReportCheck.Left := cXLabel;
  FIssueReportCheck.Top := 171;
  FIssueReportCheck.Width := cWInput + cXInput;
  FIssueReportCheck.Caption := 'Allow the assistant to open an issue-report dialog';

  // --- Honest seam note ------------------------------------------------------
  FSeamNote := TLabel.Create(Self);
  FSeamNote.Parent := Self;
  FSeamNote.Left := cXLabel;
  FSeamNote.Top := 211;
  FSeamNote.WordWrap := True;
  FSeamNote.AutoSize := True;
  FSeamNote.Anchors := [akLeft, akTop, akRight];
  FSeamNote.BorderSpacing.Right := cXLabel;
  FSeamNote.Width := Self.ClientWidth - (cXLabel * 2);
  FSeamNote.Caption :=
    'Tool permissions, inline edit review and auto-save apply now: a connected AI ' +
    'is auto-approved or prompted per these settings, and edits show an inline ' +
    'diff you approve or reject (auto-approved on save when auto-save is on). ' +
    'Issue reporting applies now too: when on, a connected AI can open the ' +
    'editable issue-report dialog; when off it cannot. Shared with the RAD Studio ' +
    'plugin in %APPDATA%\Aefos\.aefos\config.json.';
end;

procedure TAefosFlowOptionsFrame.ReadSettings(AOptions: TAbstractIDEOptions);
var
  LConfig: IConfig;
  LSnap: TConfig;
begin
  // Refuse a before-Setup call: every control below is created inside Setup, so
  // the first assignment would dereference nil and raise an access violation
  // while the IDE opens its options dialog. Same guard, same reason, as the
  // sibling pages of this group (Aefos.Lazarus.Options.pas ReadSettings) - the
  // dialog shows all four together, so hardening one page alone fixes nothing.
  if not FBuilt then
  begin
    DebugLn('[AefosAI] options(flow): ReadSettings called BEFORE Setup - skipping');
    Exit;
  end;
  // AOptions is ignored: the knobs live in the SHARED config.json (see header).
  LConfig := _BuildConfigService;
  LConfig.Load;
  LSnap := LConfig.Snapshot;
  FConsentCombo.ItemIndex := LSnap.AgentConsentMode;
  FEditReviewCombo.ItemIndex := LSnap.AgentEditReviewMode;
  FAutoSaveCheck.Checked := LSnap.AgentAutoSave;
  FIssueReportCheck.Checked := LSnap.IssueReporting;
end;

procedure TAefosFlowOptionsFrame.WriteSettings(AOptions: TAbstractIDEOptions);
var
  LConfig: IConfig;
  LSnap: TConfig;
begin
  // A page that was never built has no edits to save, and reading ItemIndex off a
  // nil combo to find that out is the fault itself.
  if not FBuilt then
  begin
    DebugLn('[AefosAI] options(flow): WriteSettings called BEFORE Setup - nothing to save');
    Exit;
  end;
  // Load first, then overlay ONLY the fields this page owns, so keys other pages
  // edit (executor, model, timeout, ...) survive - one config file, both IDEs.
  LConfig := _BuildConfigService;
  LConfig.Load;
  LSnap := LConfig.Snapshot;
  if FConsentCombo.ItemIndex >= 0 then
    LSnap.AgentConsentMode := FConsentCombo.ItemIndex;
  if FEditReviewCombo.ItemIndex >= 0 then
    LSnap.AgentEditReviewMode := FEditReviewCombo.ItemIndex;
  LSnap.AgentAutoSave := FAutoSaveCheck.Checked;
  LSnap.IssueReporting := FIssueReportCheck.Checked;
  LConfig.Save(LSnap);
end;

class function TAefosFlowOptionsFrame.SupportedOptionsClass: TAbstractIDEOptionsClass;
begin
  Result := TAefosIDEOptions;
end;

{$R *.lfm}

end.
