unit Aefos.OTA.Options.AIFlow;

(*
  Shared "AI Flow" Tools->Options page (Chat + Terminal).

  Lives in MCP.Tools.OTA — the package BOTH hosts already require — because the
  page must exist whether the user installed Chat, Terminal, or both (neither
  plugin package can own it). Each host calls RegisterAIFlowOptions on init and
  UnregisterAIFlowOptions on unload; registration is REFCOUNTED so the page is
  registered once while at least one host is alive, and the second host's call
  is a cheap no-op (mirrors the shared find-or-create main-menu pattern).

  What the page controls (mined 2026-06-11, see docs/ide-actions.md lineage):
  the IDE's own editor option "Ask To Reload Modified Files"
  (HKCU\<BDS base>\Editor\Options, REG_SZ True/False). With False the IDE
  auto-reloads files modified on disk WITHOUT the "has been changed, reload?"
  dialog — the global complement to the facade's per-write Refresh(True): it
  also silences writes the facade cannot see (pure Tools.Files, git, the CLI
  editing files directly). A real conflict (unsaved buffer + disk change) still
  prompts — by design.

  The base registry key comes from IOTAServices.GetBaseRegistryKey, so the page
  works on any BDS version, not just 37.0. The registry is the IDE's startup
  source for this option; flipping it via this page may only take full effect
  after an IDE restart (stated in the UI).

  ASCII-only literals on purpose (no UTF-8 BOM in this file).
*)

interface

uses
  System.SysUtils,
  System.Classes,
  Vcl.Forms,
  Vcl.Controls,
  Vcl.ComCtrls,
  Vcl.StdCtrls;

type
  TAefosAIFlowOptionsFrame = class(TFrame)
    lblTitle: TLabel;
    gbPermissions: TGroupBox;
    lblConsent: TLabel;
    cmbConsentMode: TComboBox;
    chkNativeTools: TCheckBox;
    // Says, per executor, whether the checkbox above can actually be honoured.
    // Three of the four CLIs have no per-tool lever in non-interactive mode, and
    // pretending otherwise is the exact complaint this feature answers.
    lblNativeTools: TLabel;
    gbEdits: TGroupBox;
    lblEditReview: TLabel;
    cmbEditReview: TComboBox;
    chkAgentAutoSave: TCheckBox;
    gbInline: TGroupBox;
    chkInlineEnabled: TCheckBox;
    lblInlineShortcut: TLabel;
    hkInlineShortcut: THotKey;
    // One "IDE behavior" box now carries both the silent-reload and the
    // WebView2 trace toggles: they were a group each, two boxes for two
    // checkboxes, and the inline-completion group needed the 60 vertical pixels
    // they were spending on borders.
    gbIDE: TGroupBox;
    chkSilentReload: TCheckBox;
    chkWebViewTrace: TCheckBox;
    gbIssue: TGroupBox;
    chkIssueReporting: TCheckBox;
    // Read-only. The point is DISCOVERY: these keys exist, they are bound at
    // BPL load, and nothing else in the IDE tells the user they are there --
    // a shortcut nobody knows about is a feature nobody has.
    gbShortcuts: TGroupBox;
    lblShortcutInline: TLabel;
    lblShortcutSuggest: TLabel;
    lblShortcutReview: TLabel;
    lblShortcutReplicate: TLabel;
  end;

  // The shared AI Flow page + its persisted knobs as a sealed static namespace.
  // Never instantiated - the class IS the namespace (host registration is
  // refcounted; see unit header).
  TAIFlowOptions = class sealed
  private
    // One-time lazy migration of the four agent knobs from the legacy IDE
    // registry into the shared %APPDATA%\Aefos\.aefos\config.json, so a GA user
    // who already set auto-approve/etc. in the registry does NOT lose it when
    // these knobs move to the shared "one brain" config. Runs at most once per
    // process (guarded by a static flag) and at most once per user (guarded by a
    // registry marker); after that the shared config is authoritative. On the
    // Lazarus edition there is no registry, so this path never runs there.
    class procedure _EnsureFlowMigrated; static;
  public
    // Host entry points (refcounted - see unit header).
    class procedure RegisterAIFlowOptions; static;
    class procedure UnregisterAIFlowOptions; static;

    // Persisted "Agent edit review" mode: how the agent's inline EditUnit diff is
    // gated in the editor - 0 = Wait for approval, 1 = Preview then auto-apply
    // (default), 2 = Apply silently. Lives in THIS shared MCP.Tools.OTA package so
    // both the change-review consumer (GutterReview) and this page reach it without a
    // Chat<->page dependency, and so the setting applies to Chat AND Terminal.
    // Stored in the SHARED %APPDATA%\Aefos\.aefos\config.json (key
    // agent_edit_review_mode) - the SAME brain as the Lazarus edition (owner rule
    // 2026-07-17). Out-of-range values normalise to 1.
    class function AgentEditReviewMode: Integer; static;
    class procedure SetAgentEditReviewMode(const AMode: Integer); static;

    // Persisted "Agent auto-save edits" toggle. When TRUE (default), the agent's whole-buffer
    // rewrite tools (AddEventHandler) auto-accept any still-unresolved review on the unit and
    // pass through - so a sequence of edits never blocks and the agent never calls SaveAll
    // itself. When FALSE, those tools refuse on a pending review so the user approves each diff
    // in the gutter. Stored in the SHARED config.json (key agent_auto_save).
    class function AgentAutoSave: Boolean; static;
    class procedure SetAgentAutoSave(const AEnabled: Boolean); static;

    // Persisted "Tool permissions" mode: how the agent's permission prompts (consent
    // for project-mutating tools) are handled - 0 = Ask every time (default), 1 =
    // Auto-approve edits but still ask for destructive ops (delete/overwrite/rename/
    // clean), 2 = Auto-approve everything (no prompts). Read by the workspace facade's
    // RequestConsent to short-circuit the modal. Stored in the SHARED config.json
    // (key agent_consent_mode). Out-of-range values normalise to 0.
    class function AgentConsentMode: Integer; static;
    class procedure SetAgentConsentMode(const AMode: Integer); static;

    // Persisted "Issue reporting" toggle. When TRUE, the ProposeAefosIssue tool opens
    // its editable confirmation dialog; when FALSE (default) the tool is inert and
    // returns a "disabled" result WITHOUT showing any UI - so a misbehaving/hallucinating
    // agent can never spam the dialog. Stored in the SHARED config.json (key
    // issue_reporting). The user opts in to send feedback.
    class function IssueReportingEnabled: Boolean; static;
    class procedure SetIssueReportingEnabled(const AEnabled: Boolean); static;

    // Persist ALL FOUR shared-config agent knobs (consent, edit-review, auto-save,
    // issue-reporting) in ONE atomic load-modify-store. Used by the Options page's
    // DialogClosed so an accepted dialog is all-or-nothing: the four setters no
    // longer run as four separate reads+writes where a mid-sequence failure could
    // drop three of them silently. Modes are clamped to their contracts (0..2, out
    // of range -> the knob's default). The migration guard runs once, as usual.
    class procedure SetAgentKnobs(const AConsentMode, AEditReviewMode: Integer;
      const AAutoSave, AIssueReporting: Boolean); static;

    // Whether the AI CLI may use its OWN file/shell tools (Write/Edit/Bash and
    // their equivalents), or must route every mutation through the Aefos MCP
    // tools, which are consent-gated.
    //   Honoured for real only where the CLI HAS a per-tool lever -- today that
    // is Claude alone. Codex, Copilot and Gemini need their "allow everything"
    // flags to run non-interactively at all (Codex's sandbox lift is what lets
    // OUR MCP calls through; without it the CLI auto-denies them), so they are
    // always in the permissive state. The Options page SAYS that per executor
    // instead of implying a uniformity that does not exist.
    class function AgentNativeTools: Boolean; static;
    class procedure SetAgentNativeTools(const AEnabled: Boolean); static;

    // ── Inline completion (ghost text) ────────────────────────────────────────
    // Read by the editor-side feature in the Chat package (which requires THIS
    // package, so the dependency runs the right way). Stored in the SHARED
    // config.json, like every other knob on this page.
    //
    // Enabled: the whole feature. OFF means the painter and the key bindings are
    // not even registered -- the point of the switch is that a user who does not
    // want it pays NOTHING for it, not that it stays wired and declines.
    class function InlineCompletionEnabled: Boolean; static;
    // The key that asks for a suggestion when Auto is off. Text form
    // ('Ctrl+Alt+Space'), never a numeric TShortCut - see the store's key notes.
    class function InlineCompletionShortcut: string; static;
    // All four in ONE atomic write, same all-or-nothing contract as SetAgentKnobs.
    class procedure SetInlineCompletionKnobs(const AEnabled: Boolean;
      const AShortcut: string); static;

    // Called AFTER an accepted dialog has persisted everything, so a feature can
    // re-read its knobs and re-wire itself without an IDE restart. PUSH, so
    // nothing has to poll the config file.
    //   The handler belongs to another package (Chat), so it MUST be cleared at
    // that package's teardown: a closure left here while its BPL unmaps is the
    // dangling-reference family the unload contract exists for. Pass nil to
    // clear. One consumer, deliberately - this is a wiring seam, not an event
    // bus, and a list would invite exactly the leak above.
    class procedure SetSettingsChangedHandler(const AHandler: TProc); static;
  end;

implementation

{$R *.dfm}

uses
  Winapi.Windows,
  System.Win.Registry,
  Vcl.Menus,
  Vcl.Dialogs,
  ToolsAPI,
  Aefos.OTA.Options.AIFlow.Store;

const
  AREA_NAME = 'Aefos';
  // Globally unique caption (the Options dialog keys frames by caption —
  // see the built-in 'Chat' page collision, 2026-06-07).
  CAPTION_AIFLOW = 'AI Flow';
  EDITOR_OPTIONS_SUBKEY = '\Editor\Options';
  ASK_RELOAD_VALUE = 'Ask To Reload Modified Files';
  // Our own settings live under a dedicated subkey of the BDS base key.
  AEFOS_SUBKEY = '\Aefos';
  EDIT_REVIEW_VALUE = 'AgentEditReviewMode';
  // WebView2 diagnostic trace toggle. Persisted here; ALSO drives the process env
  // var AEFOS_WEBVIEW_TRACE that the (leaf) WebView package reads at panel init —
  // we set the env from this setting so the user never touches the OS env by hand.
  WEBVIEW_TRACE_VALUE = 'WebViewTrace';
  WEBVIEW_TRACE_ENV = 'AEFOS_WEBVIEW_TRACE';
  // Agent auto-save (auto-accept pending reviews so edits pass without manual approval).
  AGENT_AUTOSAVE_VALUE = 'AgentAutoSave';
  // Tool-permission (consent) mode: 0 Ask / 1 Auto-approve edits / 2 Auto-approve all.
  AGENT_CONSENT_VALUE = 'AgentConsentMode';
  // Issue reporting: True = ProposeAefosIssue may open its dialog; default off.
  ISSUE_REPORTING_VALUE = 'IssueReportingEnabled';
  // One-time migration marker. Set to 'True' once the four legacy registry knobs
  // above have been imported into the shared config.json. Kept in the REGISTRY (a
  // Delphi-local bookkeeping flag), NOT in the shared config, on purpose: the
  // Chat/Options page and the Lazarus edition save config.json via TConfigService,
  // whose serialiser writes only its KNOWN keys - it would silently DROP a marker
  // key living in config.json, which would re-trigger the migration on the next
  // IDE start and clobber whatever the user set meanwhile. A registry marker can
  // never be dropped by a config save, so the migration is truly once-per-user.
  AGENT_MIGRATED_VALUE = 'AgentFlowMigratedFromRegistry';

// ── Registry knob ──────────────────────────────────────────────────────────

type
  // Registry persistence for the AI Flow knobs: ONE place that owns the
  // TRegistry create/open/read/write/free dance, so each getter/setter is a
  // single line instead of a 15-line boilerplate block. Reads/writes REG_SZ
  // values under HKCU\<BDS base>\<ASubKey>; callers pass the subkey
  // ('\Editor\Options' or '\Aefos') and the value name, so the exact registry
  // paths/values are BYTE-IDENTICAL to before. Never instantiated.
  TAIFlowSettings = class sealed
  private
    // Resolves 'HKCU\<BDS base>\<ASubKey>' from the live IDE (version-agnostic).
    // False when the IDE services are unavailable (AKey left '').
    class function _ResolveKey(const ASubKey: string; out AKey: string): Boolean; static;
  public
    // Reads a REG_SZ value; returns ADefault when the IDE services are absent,
    // the key cannot be opened, or the value does not exist.
    class function ReadString(const ASubKey, AName, ADefault: string): string; static;
    // Like ReadString but reports EXISTENCE: True + AValue set only when the IDE
    // services are present, the key opens, and the value exists. Used by the
    // one-time registry->shared-config migration to import ONLY explicit legacy
    // values (never a phantom default).
    class function TryReadString(const ASubKey, AName: string;
      out AValue: string): Boolean; static;
    // Writes a REG_SZ value (creating the key); a no-op when the IDE services
    // are absent or the key cannot be opened.
    class procedure WriteString(const ASubKey, AName, AValue: string); static;
    // Canonical 'True'/'False' text for a Boolean (the old CBool array, once).
    class function BoolText(const AValue: Boolean): string; static;
  end;

class function TAIFlowSettings._ResolveKey(const ASubKey: string;
  out AKey: string): Boolean;
var
  LServices: IOTAServices;
begin
  AKey := '';
  Result := Assigned(BorlandIDEServices)
    and Supports(BorlandIDEServices, IOTAServices, LServices);
  if Result then
    AKey := LServices.GetBaseRegistryKey + ASubKey;
end;

class function TAIFlowSettings.ReadString(const ASubKey, AName,
  ADefault: string): string;
var
  LKey: string;
  LReg: TRegistry;
begin
  Result := ADefault;
  if not _ResolveKey(ASubKey, LKey) then
    Exit;
  LReg := TRegistry.Create(KEY_READ);
  try
    LReg.RootKey := HKEY_CURRENT_USER;
    if LReg.OpenKeyReadOnly(LKey) and LReg.ValueExists(AName) then
      Result := LReg.ReadString(AName);
  finally
    LReg.Free;
  end;
end;

class function TAIFlowSettings.TryReadString(const ASubKey, AName: string;
  out AValue: string): Boolean;
var
  LKey: string;
  LReg: TRegistry;
begin
  AValue := '';
  Result := False;
  if not _ResolveKey(ASubKey, LKey) then
    Exit;
  LReg := TRegistry.Create(KEY_READ);
  try
    LReg.RootKey := HKEY_CURRENT_USER;
    if LReg.OpenKeyReadOnly(LKey) and LReg.ValueExists(AName) then
    begin
      AValue := LReg.ReadString(AName);
      Result := True;
    end;
  finally
    LReg.Free;
  end;
end;

class procedure TAIFlowSettings.WriteString(const ASubKey, AName,
  AValue: string);
var
  LKey: string;
  LReg: TRegistry;
begin
  if not _ResolveKey(ASubKey, LKey) then
    Exit;
  LReg := TRegistry.Create(KEY_READ or KEY_WRITE);
  try
    LReg.RootKey := HKEY_CURRENT_USER;
    if LReg.OpenKey(LKey, True) then
      LReg.WriteString(AName, AValue);
  finally
    LReg.Free;
  end;
end;

class function TAIFlowSettings.BoolText(const AValue: Boolean): string;
const
  CBool: array[Boolean] of string = ('False', 'True');
begin
  Result := CBool[AValue];
end;

// True = the IDE asks before reloading (its default when the value is absent).
function _ReadAskToReload: Boolean;
begin
  Result := not SameText(TAIFlowSettings.ReadString(
    EDITOR_OPTIONS_SUBKEY, ASK_RELOAD_VALUE, 'True'), 'False');
end;

procedure _WriteAskToReload(const AAsk: Boolean);
begin
  TAIFlowSettings.WriteString(EDITOR_OPTIONS_SUBKEY, ASK_RELOAD_VALUE,
    TAIFlowSettings.BoolText(AAsk));
end;

// ── Agent knobs: SHARED config.json (one brain) + one-time registry migration ─

var
  // Process-scoped guard so _EnsureFlowMigrated does its registry check at most
  // once per IDE session (after that the shared config is authoritative).
  GFlowMigrationChecked: Boolean = False;
  // The single settings-changed consumer. Cleared by its owner at teardown -
  // see SetSettingsChangedHandler.
  GSettingsChanged: TProc = nil;

// Normalises a mode integer to 0..2, mapping out-of-range to ADefault.
function _ClampMode(const AValue, ADefault: Integer): Integer;
begin
  Result := AValue;
  if (Result < 0) or (Result > 2) then
    Result := ADefault;
end;

class procedure TAIFlowOptions._EnsureFlowMigrated;
var
  LRaw: string;
begin
  if GFlowMigrationChecked then
    Exit;
  GFlowMigrationChecked := True;
  // Marker lives in the registry (see AGENT_MIGRATED_VALUE) - once set, the
  // shared config alone is authoritative and we never touch the registry knobs
  // again. On the Lazarus edition there is no IDE registry, so this whole unit
  // is Delphi-only; the migration simply never runs there (the Lazarus config is
  // already the source of truth).
  if not TAefosFlowMigration.MigrationPending(
       SameText(TAIFlowSettings.ReadString(
         AEFOS_SUBKEY, AGENT_MIGRATED_VALUE, 'False'), 'True')) then
    Exit;
  // Import ONLY knobs the user actually set in the legacy registry - a knob with
  // no explicit registry value is left at whatever the shared config already
  // holds (so a fresh user, or a Lazarus-first user whose Delphi registry is
  // empty, is never clobbered with a phantom default).
  if TAIFlowSettings.TryReadString(AEFOS_SUBKEY, AGENT_CONSENT_VALUE, LRaw) then
    TAefosFlowConfigStore.WriteInt(TAefosFlowConfigStore.KEY_AGENT_CONSENT_MODE,
      _ClampMode(StrToIntDef(LRaw, 0), 0));
  if TAIFlowSettings.TryReadString(AEFOS_SUBKEY, EDIT_REVIEW_VALUE, LRaw) then
    TAefosFlowConfigStore.WriteInt(TAefosFlowConfigStore.KEY_AGENT_EDIT_REVIEW_MODE,
      _ClampMode(StrToIntDef(LRaw, 1), 1));
  if TAIFlowSettings.TryReadString(AEFOS_SUBKEY, AGENT_AUTOSAVE_VALUE, LRaw) then
    // Permissive True (matches the legacy getter's `not SameText(v,'False')`), so
    // a corrupt/non-canonical registry value imports the SAME Boolean the old code
    // would have read - only an explicit 'False' migrates to off.
    TAefosFlowConfigStore.WriteBool(TAefosFlowConfigStore.KEY_AGENT_AUTO_SAVE,
      not SameText(LRaw, 'False'));
  if TAIFlowSettings.TryReadString(AEFOS_SUBKEY, ISSUE_REPORTING_VALUE, LRaw) then
    TAefosFlowConfigStore.WriteBool(TAefosFlowConfigStore.KEY_ISSUE_REPORTING,
      SameText(LRaw, 'True'));
  // Mark done so we never re-import (and so a later shared-config change is not
  // overwritten by the now-stale registry values).
  TAIFlowSettings.WriteString(AEFOS_SUBKEY, AGENT_MIGRATED_VALUE, 'True');
end;

// ── Agent edit-review mode knob (shared config.json) ────────────────────────

class function TAIFlowOptions.AgentEditReviewMode: Integer;
begin
  _EnsureFlowMigrated;
  // default = Preview; out-of-range normalises to 1
  Result := _ClampMode(TAefosFlowConfigStore.ReadInt(
    TAefosFlowConfigStore.KEY_AGENT_EDIT_REVIEW_MODE, 1), 1);
end;

class procedure TAIFlowOptions.SetAgentEditReviewMode(const AMode: Integer);
begin
  _EnsureFlowMigrated;
  TAefosFlowConfigStore.WriteInt(
    TAefosFlowConfigStore.KEY_AGENT_EDIT_REVIEW_MODE, _ClampMode(AMode, 1));
end;

// ── Agent auto-save knob (shared config.json) ───────────────────────────────

class function TAIFlowOptions.AgentAutoSave: Boolean;
begin
  _EnsureFlowMigrated;
  // Default = False: HONOUR "Inline edit review: Wait for my approval". The runtime default
  // must match the UI checkbox default (unchecked), so a review is NEVER auto-accepted on a
  // save unless the user EXPLICITLY opts into auto-save. (The non-blocking approver still lets
  // edits apply immediately; only a SAVE over a pending ✓/✗ gutter is gated by this.)
  Result := TAefosFlowConfigStore.ReadBool(
    TAefosFlowConfigStore.KEY_AGENT_AUTO_SAVE, False);
end;

class procedure TAIFlowOptions.SetAgentAutoSave(const AEnabled: Boolean);
begin
  _EnsureFlowMigrated;
  TAefosFlowConfigStore.WriteBool(
    TAefosFlowConfigStore.KEY_AGENT_AUTO_SAVE, AEnabled);
end;

// ── Tool-permission (consent) mode knob (shared config.json) ────────────────

class function TAIFlowOptions.AgentConsentMode: Integer;
begin
  _EnsureFlowMigrated;
  // default = Ask every time (safe; never auto-approves); out-of-range normalises to 0
  Result := _ClampMode(TAefosFlowConfigStore.ReadInt(
    TAefosFlowConfigStore.KEY_AGENT_CONSENT_MODE, 0), 0);
end;

class procedure TAIFlowOptions.SetAgentConsentMode(const AMode: Integer);
begin
  _EnsureFlowMigrated;
  TAefosFlowConfigStore.WriteInt(
    TAefosFlowConfigStore.KEY_AGENT_CONSENT_MODE, _ClampMode(AMode, 0));
end;

// ── Issue-reporting knob (shared config.json) ───────────────────────────────

class function TAIFlowOptions.IssueReportingEnabled: Boolean;
begin
  _EnsureFlowMigrated;
  // default = off (opt-in; a hallucinating agent cannot spam the dialog)
  Result := TAefosFlowConfigStore.ReadBool(
    TAefosFlowConfigStore.KEY_ISSUE_REPORTING, False);
end;

class procedure TAIFlowOptions.SetIssueReportingEnabled(const AEnabled: Boolean);
begin
  _EnsureFlowMigrated;
  TAefosFlowConfigStore.WriteBool(
    TAefosFlowConfigStore.KEY_ISSUE_REPORTING, AEnabled);
end;

// ── Batch write of the four shared-config knobs (one atomic store) ───────────

class procedure TAIFlowOptions.SetAgentKnobs(const AConsentMode,
  AEditReviewMode: Integer; const AAutoSave, AIssueReporting: Boolean);
begin
  _EnsureFlowMigrated;
  // Clamp the modes to their contracts here (the same defaults the individual
  // setters use), then hand the store ONE all-or-nothing load-modify-store.
  TAefosFlowConfigStore.UpdateFlowKnobs(
    _ClampMode(AConsentMode, 0), _ClampMode(AEditReviewMode, 1),
    AAutoSave, AIssueReporting);
end;

// ── WebView2 diagnostic trace knob (our own subkey + process env) ───────────

// Sets/clears the process env var the WebView package reads (non-empty = on; we
// CLEAR it when off so "0"/"false" can never accidentally keep it on — the leaf
// package's check is "non-empty"). Takes effect on the next Chat panel open.
procedure _ApplyWebViewTraceEnv(const AEnabled: Boolean);
begin
  if AEnabled then
    SetEnvironmentVariable(WEBVIEW_TRACE_ENV, '1')
  else
    SetEnvironmentVariable(WEBVIEW_TRACE_ENV, nil); // delete -> empty -> trace off
end;

function WebViewTraceEnabled: Boolean;
begin
  // default = off (a diagnostic, not a normal-use setting)
  Result := SameText(TAIFlowSettings.ReadString(
    AEFOS_SUBKEY, WEBVIEW_TRACE_VALUE, 'False'), 'True');
end;

procedure SetWebViewTraceEnabled(const AEnabled: Boolean);
begin
  TAIFlowSettings.WriteString(AEFOS_SUBKEY, WEBVIEW_TRACE_VALUE,
    TAIFlowSettings.BoolText(AEnabled));
  _ApplyWebViewTraceEnv(AEnabled);
end;

class function TAIFlowOptions.AgentNativeTools: Boolean;
begin
  Result := TAefosFlowConfigStore.ReadBool(
    TAefosFlowConfigStore.KEY_AGENT_NATIVE_TOOLS,
    TAefosFlowConfigStore.AGENT_NATIVE_TOOLS_DEFAULT);
end;

class procedure TAIFlowOptions.SetAgentNativeTools(const AEnabled: Boolean);
begin
  TAefosFlowConfigStore.WriteBool(
    TAefosFlowConfigStore.KEY_AGENT_NATIVE_TOOLS, AEnabled);
end;

class function TAIFlowOptions.InlineCompletionEnabled: Boolean;
begin
  Result := TAefosFlowConfigStore.ReadBool(
    TAefosFlowConfigStore.KEY_INLINE_ENABLED,
    TAefosFlowConfigStore.INLINE_DEFAULT_ENABLED);
end;

class function TAIFlowOptions.InlineCompletionShortcut: string;
begin
  Result := TAefosFlowConfigStore.ReadString(
    TAefosFlowConfigStore.KEY_INLINE_SHORTCUT,
    TAefosFlowConfigStore.INLINE_DEFAULT_SHORTCUT);
end;

class procedure TAIFlowOptions.SetInlineCompletionKnobs(const AEnabled: Boolean;
  const AShortcut: string);
begin
  TAefosFlowConfigStore.UpdateInlineKnobs(AEnabled, AShortcut);
end;

class procedure TAIFlowOptions.SetSettingsChangedHandler(const AHandler: TProc);
begin
  GSettingsChanged := AHandler;
end;

// Fired once, after everything an accepted dialog persists has been written.
// Guarded: a consumer that raises must not turn an OK into an error dialog, and
// must not stop the rest of the page's work.
procedure _NotifySettingsChanged;
begin
  if not Assigned(GSettingsChanged) then
    Exit;
  try
    GSettingsChanged();
  except
    on E: Exception do
      OutputDebugString(PChar('[Aefos] AI Flow settings handler: ' + E.Message));
  end;
end;

// ── INTAAddInOptions page ───────────────────────────────────────────────────

type
  TAIFlowAddInOptions = class(TInterfacedObject, INTAAddInOptions)
  private
    FFrame: TAefosAIFlowOptionsFrame;
    // Greys out what the switches above make meaningless: the delay belongs to
    // automatic mode, the shortcut only exists when automatic mode is off, and
    // none of it applies while the feature is off. A control that is live but
    // has no effect is a control that lies.
    procedure _InlineEnabledClick(ASender: TObject);
    // Keeps the shortcut list honest about the one entry the user controls.
    procedure _RefreshInlineShortcutLabel;
  public
    function GetArea: string;
    function GetCaption: string;
    function GetFrameClass: TCustomFrameClass;
    procedure FrameCreated(AFrame: TCustomFrame);
    procedure DialogClosed(Accepted: Boolean);
    function ValidateContents: Boolean;
    function GetHelpContext: Integer;
    function IncludeInIDEInsight: Boolean;
  end;

function TAIFlowAddInOptions.GetArea: string;
begin
  Result := AREA_NAME;
end;

function TAIFlowAddInOptions.GetCaption: string;
begin
  Result := CAPTION_AIFLOW;
end;

function TAIFlowAddInOptions.GetFrameClass: TCustomFrameClass;
begin
  Result := TAefosAIFlowOptionsFrame;
end;

procedure TAIFlowAddInOptions._RefreshInlineShortcutLabel;
var
  LKey: string;
begin
  if not Assigned(FFrame) then
    Exit;
  LKey := ShortCutToText(FFrame.hkInlineShortcut.HotKey);
  if Trim(LKey) = '' then
    LKey := TAefosFlowConfigStore.INLINE_DEFAULT_SHORTCUT;
  // Padded to the same column as the fixed rows in the .dfm. A proportional
  // font makes that approximate, which is fine -- the alternative is a grid for
  // four read-only lines.
  while Length(LKey) < 18 do
    LKey := LKey + ' ';
  if FFrame.chkInlineEnabled.Checked then
    FFrame.lblShortcutInline.Caption := LKey + 'Suggest code inline at the cursor'
  else
    FFrame.lblShortcutInline.Caption :=
      LKey + 'Suggest code inline at the cursor  (currently off)';
end;

procedure TAIFlowAddInOptions._InlineEnabledClick(ASender: TObject);
var
  LOn: Boolean;
begin
  if not Assigned(FFrame) then
    Exit;
  LOn := FFrame.chkInlineEnabled.Checked;
  FFrame.lblInlineShortcut.Enabled := LOn;
  FFrame.hkInlineShortcut.Enabled := LOn;
  _RefreshInlineShortcutLabel;
end;

procedure TAIFlowAddInOptions.FrameCreated(AFrame: TCustomFrame);
begin
  FFrame := AFrame as TAefosAIFlowOptionsFrame;
  // Tool-permission (consent) dropdown. Item order MUST match the mode contract
  // (0=Ask, 1=Auto-approve edits, 2=Auto-approve all) so ItemIndex maps 1:1 to
  // AgentConsentMode.
  FFrame.cmbConsentMode.Items.Clear;
  FFrame.cmbConsentMode.Items.Add('Ask every time (recommended)');
  FFrame.cmbConsentMode.Items.Add('Auto-approve edits, ask before destructive');
  FFrame.cmbConsentMode.Items.Add('Auto-approve everything (no prompts)');
  FFrame.cmbConsentMode.ItemIndex := TAIFlowOptions.AgentConsentMode;
  // Checked = silent (the IDE does NOT ask) - the inverse of the stored value.
  FFrame.chkSilentReload.Checked := not _ReadAskToReload;
  // Agent edit-review dropdown. Item order MUST match the mode contract
  // (0=Wait, 1=Preview, 2=Silent) so ItemIndex maps 1:1 to AgentEditReviewMode.
  FFrame.cmbEditReview.Items.Clear;
  FFrame.cmbEditReview.Items.Add('Wait for my approval');
  FFrame.cmbEditReview.Items.Add('Preview then apply (default)');
  FFrame.cmbEditReview.Items.Add('Apply silently');
  FFrame.cmbEditReview.ItemIndex := TAIFlowOptions.AgentEditReviewMode;
  // Agent auto-save (ungated — a workflow preference). Checked = edits pass automatically.
  FFrame.chkAgentAutoSave.Checked := TAIFlowOptions.AgentAutoSave;
  // WebView2 diagnostic trace (ungated — a support/diagnostic toggle).
  FFrame.chkWebViewTrace.Checked := WebViewTraceEnabled;
  // Issue reporting (ungated — opt-in; gates whether ProposeAefosIssue opens a dialog).
  FFrame.chkIssueReporting.Checked := TAIFlowOptions.IssueReportingEnabled;
  // Inline completion. The shortcut goes through a THotKey, not an edit box, so
  // the user PRESSES the combination instead of spelling it — and so a value
  // this page produces is always one TextToShortCut can read back.
  FFrame.chkNativeTools.Checked := TAIFlowOptions.AgentNativeTools;
  FFrame.lblNativeTools.Caption :=
    'Honoured for Claude Code, the only one of the four CLIs with a per-tool ' +
    'switch. Codex, Copilot and Gemini require their own tools to run without ' +
    'a human answering prompts, so they always have them.';
  FFrame.chkInlineEnabled.Checked := TAIFlowOptions.InlineCompletionEnabled;
  FFrame.hkInlineShortcut.HotKey :=
    TextToShortCut(TAIFlowOptions.InlineCompletionShortcut);
  // A shortcut the running VCL cannot parse would silently become "no shortcut
  // at all", which reads as a dead feature. Fall back to the default instead.
  if FFrame.hkInlineShortcut.HotKey = 0 then
    FFrame.hkInlineShortcut.HotKey := TextToShortCut(
      TAefosFlowConfigStore.INLINE_DEFAULT_SHORTCUT);
  FFrame.chkInlineEnabled.OnClick := _InlineEnabledClick;
  _InlineEnabledClick(nil);
  // The inline row is the only shortcut on this list the user can change, so its
  // caption is built from the setting rather than baked into the .dfm -- a
  // reference list that can go stale is worse than no list.
  _RefreshInlineShortcutLabel;
end;

procedure TAIFlowAddInOptions.DialogClosed(Accepted: Boolean);
var
  LSilent: Boolean;
begin
  if Accepted and Assigned(FFrame) then
  begin
    LSilent := FFrame.chkSilentReload.Checked;
    _WriteAskToReload(not LSilent);
    // Persist the four shared-config agent knobs (consent mode, edit-review mode,
    // auto-save, issue-reporting) in ONE atomic write. Doing it as a batch (was
    // four independent load/store setters) makes an accepted dialog all-or-nothing:
    // a mid-sequence failure can no longer save some knobs and silently drop the
    // rest. The combos are always populated with a valid selection here, so the
    // ItemIndex-es are the 0..2 modes (SetAgentKnobs clamps defensively anyway).
    TAIFlowOptions.SetAgentKnobs(
      FFrame.cmbConsentMode.ItemIndex, FFrame.cmbEditReview.ItemIndex,
      FFrame.chkAgentAutoSave.Checked, FFrame.chkIssueReporting.Checked);
    // Persist + apply the WebView2 diagnostic trace toggle (sets the env var).
    // Kept a separate write: it lives in the IDE registry (Delphi-local), not the
    // shared config, so it is not part of the shared-config batch.
    SetWebViewTraceEnabled(FFrame.chkWebViewTrace.Checked);
    // Inline completion, one atomic write of its own four knobs. ValidateContents
    // has already refused a non-numeric delay, so StrToIntDef's fallback here is
    // belt-and-braces rather than the real guard; the store clamps the range.
    TAIFlowOptions.SetInlineCompletionKnobs(FFrame.chkInlineEnabled.Checked,
      ShortCutToText(FFrame.hkInlineShortcut.HotKey));
    TAIFlowOptions.SetAgentNativeTools(FFrame.chkNativeTools.Checked);
    // Everything is on disk: tell whoever is listening to re-wire itself, so
    // the user sees the change now rather than after restarting the IDE.
    _NotifySettingsChanged;
  end;
  // The IDE frees the frame after the dialog closes (same lifecycle as the
  // Chat page, RN-004).
  FFrame := nil;
end;

function TAIFlowAddInOptions.ValidateContents: Boolean;
begin
  // Nothing on this page can be typed wrong any more. The one free-text field
  // was the automatic-mode delay, and automatic mode is gone; the shortcut comes
  // from a THotKey, which cannot produce an unparseable value.
  Result := True;
end;

function TAIFlowAddInOptions.GetHelpContext: Integer;
begin
  Result := 0;
end;

function TAIFlowAddInOptions.IncludeInIDEInsight: Boolean;
begin
  Result := True;
end;

// ── Refcounted host registration ────────────────────────────────────────────

var
  GRefCount: Integer = 0;
  GOption: INTAAddInOptions = nil;

class procedure TAIFlowOptions.RegisterAIFlowOptions;
var
  LServices: INTAEnvironmentOptionsServices;
begin
  Inc(GRefCount);
  if GRefCount <> 1 then
    Exit; // another host already registered the page
  // Honor the persisted WebView2-trace choice from IDE startup: push it into the
  // process env BEFORE the Chat panel/WebView initializes (the leaf package reads
  // the env at init). Without this, the registry value would only apply after the
  // user reopened the Options dialog.
  _ApplyWebViewTraceEnv(WebViewTraceEnabled);
  if Assigned(BorlandIDEServices)
    and Supports(BorlandIDEServices, INTAEnvironmentOptionsServices, LServices) then
  begin
    GOption := TAIFlowAddInOptions.Create;
    LServices.RegisterAddInOptions(GOption);
  end;
end;

class procedure TAIFlowOptions.UnregisterAIFlowOptions;
var
  LServices: INTAEnvironmentOptionsServices;
begin
  if GRefCount <= 0 then
    Exit;
  Dec(GRefCount);
  if (GRefCount <> 0) or not Assigned(GOption) then
    Exit; // another host still needs the page
  if Assigned(BorlandIDEServices)
    and Supports(BorlandIDEServices, INTAEnvironmentOptionsServices, LServices) then
    LServices.UnregisterAddInOptions(GOption);
  GOption := nil;
end;

end.
