unit Aefos.OTA.Terminal.UI.Wizard;

interface

{$I ..\Aefos.OTA.Terminal.inc}

uses
  ToolsAPI,
  Menus,
  Classes,
  SysUtils,
  Winapi.Messages,
  Vcl.Forms;

type
  /// <summary>Identifies which Aefos.OTA.Terminal panel the shared recreate-helper
  /// targets (ADR-054-01).</summary>
  TAefosTerminalPanelKind = (pkTerminal, pkActionCenter);

  TAefosTerminalWizard = class(TNotifierObject, IOTAWizard)
  private
    FMenuItem: TMenuItem;
    FActionCenterMenuItem: TMenuItem;
    FBootCatalog: TObject;
    FPriorAppShortCut: TShortCutEvent;
    FAppShortCutInstalled: Boolean;
{$IFDEF AEFOS_OTA_TERMINAL_SELFTEST}
    FChannel: TObject; { TIdeSelfTestChannel — typed as TObject to avoid forward-decl }
{$ENDIF}
    FMCPBinding: TObject;        { TMCPConfigBinding }
    FMCPHost:    TObject;        { TTerminalMCPHost }
    FMCPOptions: INTAAddInOptions;
    procedure MenuClick(Sender: TObject);
    procedure _ActionCenterMenuClick(Sender: TObject);
    procedure _AboutMenuClick(Sender: TObject);
    procedure _LicenseMenuClick(Sender: TObject);
    procedure _OpenOrRecreatePanel(APanel: TAefosTerminalPanelKind);
    procedure CreateMenu;
    procedure RemoveMenu;
    procedure _RegisterKeyBinding;
    procedure _UnregisterKeyBinding;
    procedure _ActionCenterCatalogChanged(Sender: TObject);
    procedure _ReloadBootCatalog;
    procedure _AppShortCut(var AMsg: TWMKey; var AHandled: Boolean);
    procedure _InstallAppShortCutHook;
    procedure _UninstallAppShortCutHook;
    procedure _RegisterMCPOptions;
    procedure _UnregisterMCPOptions;
    procedure _StartMCPHostIfEnabled;
    procedure _StopMCPHost;
    procedure _OnMCPConfigChanged;
  public
    constructor Create;
    destructor Destroy; override;
    { IOTAWizard }
    function GetIDString: string;
    function GetName: string;
    function GetState: TWizardState;
    procedure Execute;
  end;

procedure Register;

implementation

uses
  Winapi.Windows,
  Aefos.OTA.Terminal.UI.DockForm,
  Aefos.OTA.Terminal.UI.TerminalView,
  Aefos.OTA.Terminal.UI.TerminalCanvas,
  Aefos.OTA.Terminal.Core.Actions,
  Aefos.OTA.Terminal.Core.ActionStore,
  Aefos.OTA.Terminal.UI.ActionCenterView,
  Aefos.OTA.Terminal.UI.KeyBinding,
  Aefos.OTA.Terminal.MCP.Config,
  Aefos.OTA.Terminal.MCP.Host,
  Aefos.MCP.Provision,
  Aefos.OTA.MCP.PyToolsManager,
  Aefos.MCP.OTA.WorkspaceFacade,
  Aefos.OTA.Terminal.UI.Options,
  Aefos.OTA.Options.AIFlow,
  Aefos.OTA.IDE.GutterReview,
  Aefos.OTA.Terminal.UI.Branding,
  Aefos.OTA.Terminal.UI.AboutForm,
  Aefos.License.Gate
{$IFDEF AEFOS_OTA_TERMINAL_SELFTEST}
  , Aefos.OTA.Terminal.UI.SelfTestChannel
{$ENDIF}
  ;

var
  GAefosTerminalWizard: IOTAWizard = nil;
  GAefosTerminalWizardIndex: Integer = -1;

procedure Register;
begin
  GAefosTerminalWizard := TAefosTerminalWizard.Create;
  GAefosTerminalWizardIndex := (BorlandIDEServices as IOTAWizardServices).AddWizard(GAefosTerminalWizard);
end;

{ TAefosTerminalWizard }

constructor TAefosTerminalWizard.Create;
begin
  inherited Create;
  // Splash-screen + About-box branding for this BPL, independent of the Chat
  // plugin (this is registered at load while the IDE splash is up). Never raise
  // into wizard construction.
  try
    RegisterTerminalBranding;
  except
    on E: Exception do
      OutputDebugString(PChar('Aefos.OTA.Terminal: branding failed: '
        + E.ClassName + ' - ' + E.Message));
  end;
  // Ensure the MCP bridge exists in %APPDATA%\Aefos so a Terminal-only install
  // (no Chat BPL, no installer) still has the bridge. Shared provisioning from
  // Aefos.MCP.Core; never raise into construction.
  try
    TMCPProvision.EnsureBridge;
  except
    on E: Exception do
      OutputDebugString(PChar('Aefos.OTA.Terminal: TMCPProvision.EnsureBridge failed: '
        + E.Message));
  end;
  CreateMenu;
  // Single shared top-level "Aefos PyTools" item (refcounted across both hosts,
  // Pro-only/hidden for Free). No-op if the Chat BPL already registered it.
  Aefos.OTA.MCP.PyToolsManager.RegisterPyToolsMenu;
  // Subscribe before _RegisterKeyBinding so any view created during
  // startup also picks up the hook.
  AefosTerminalActionCenterChangedHook := _ActionCenterCatalogChanged;
  // The old TAefosTerminalIDEHooks (IOTAIDENotifier) unit was removed (2026-06-15).
  // It delivered nothing functional — auto-sync never fired (chkAutoSync was always
  // nil) and the 'Open Aefos.OTA.Terminal Here' menus never worked (known bug #9:
  // AddActionMenu always raises) — yet its IOTAIDENotifier registration was the
  // dominant crash source: a stale notifier left in the IDE's list faulted
  // SendFileNotification on every rebuild / project close / file open (issue #33).
  // If IDE notifiers / context menus are ever wanted, implement them fresh.
  _RegisterKeyBinding;
  // Editor change-review (red/green diff + per-change apply/reject), shared from
  // Aefos.MCP.Tools.OTA so a Terminal-only/Studio install gets it without the Chat
  // BPL. Idempotent — the Chat wizard also calls it; teardown is the unit's
  // finalization (once, on the shared BPL unmap). Never raise into construction.
  try
    TGutterReview.RegisterGutterReview;
  except
    on E: Exception do
      OutputDebugString(PChar('Aefos.OTA.Terminal: RegisterGutterReview failed: '
        + E.Message));
  end;
  _InstallAppShortCutHook;
{$IFDEF AEFOS_OTA_TERMINAL_SELFTEST}
  FChannel := TIdeSelfTestChannel.Create;
  (FChannel as TIdeSelfTestChannel).Start;
{$ENDIF}
  FMCPBinding := TMCPConfigBinding.Create;
  FMCPOptions := TTerminalMCPOptions.Create(
    (FMCPBinding as TMCPConfigBinding), _OnMCPConfigChanged);
  _RegisterMCPOptions;
  _StartMCPHostIfEnabled;
end;

destructor TAefosTerminalWizard.Destroy;

  procedure _Guarded(const AName: string; const AStep: TProc);
  begin
    try
      AStep;
    except // NOSONAR - exception is logged via OutputDebugString; teardown must never raise (see destructor comment).
      on E: Exception do
        OutputDebugString(PChar('Aefos.OTA.Terminal teardown [' + AName + ']: '
          + E.ClassName + ' - ' + E.Message));
    end;
  end;

begin
  // Package teardown must never raise: an exception escaping this destructor
  // aborts the IDE's package unload, leaving the wizard / IDE notifier / key
  // binding registered against unloaded code — the next IDE operation then
  // faults (issue #33: AV on uninstall, 'Invalid pointer operation' on
  // rebuild, AV in SendFileNotification on shutdown). Each step is isolated
  // and logged via OutputDebugString so the teardown always runs to
  // completion. The dock form is freed here, while this package's code is
  // still loaded, so its terminal views, hosts and reader threads tear down
  // before the BPL image is unmapped.
{$IFDEF AEFOS_OTA_TERMINAL_SELFTEST}
  _Guarded('SelfTestChannel', procedure
                              begin
                                (FChannel as TIdeSelfTestChannel).Stop;
                                FreeAndNil(FChannel);
                              end);
{$ENDIF}
  _Guarded('MCPHost',    procedure begin _StopMCPHost; end);
  _Guarded('MCPOptions', procedure begin _UnregisterMCPOptions; FMCPOptions := nil; end);
  _Guarded('MCPBinding', procedure begin FreeAndNil(FMCPBinding); end);
  _Guarded('Branding',   procedure begin UnregisterTerminalBranding; end);
  _Guarded('AppShortCut', procedure begin _UninstallAppShortCutHook; end);
  _Guarded('KeyBinding',  procedure begin _UnregisterKeyBinding; end);
  _Guarded('PyToolsMenu', procedure begin Aefos.OTA.MCP.PyToolsManager.UnregisterPyToolsMenu; end);
  _Guarded('Menu',        procedure begin RemoveMenu; end);
  _Guarded('DockForm',    procedure
                          begin
                            if Assigned(AefosTerminalDockForm) then
                            begin
                              AefosTerminalDockForm.Hide;
                              AefosTerminalDockForm.Parent := nil;
                              FreeAndNil(AefosTerminalDockForm);
                            end;
                          end);
  AefosTerminalDockForm := nil;
  _Guarded('ActionCenter', procedure
                           begin
                             if Assigned(AefosActionCenterView) then
                             begin
                               AefosActionCenterView.Hide;
                               AefosActionCenterView.Parent := nil;
                               FreeAndNil(AefosActionCenterView);
                             end;
                           end);
  AefosActionCenterView := nil;
  inherited;
end;

const
  // This BPL's OWN top-level menu (under View), with a UNIQUE caption only this
  // BPL ever touches — no cross-BPL coordination, so it can never duplicate. The
  // '(Chat)'/'(Terminal)' suffix keeps the two Aefos menus visually adjacent
  // under View (maintainer decision 2026-06-08; shared-parent model abandoned).
  TERMINAL_PARENT_CAPTION  = 'Aefos AI (Terminal)';

// Returns the menu under which this BPL's own top-level menu lives: the IDE
// 'View' menu, falling back to the menu bar root if View is absent. No shared
// parent and no find-or-create across BPLs — the duplication class is gone.
function _FindMenuHost: TMenuItem;
var
  LServices: INTAServices;
  LMainMenu: TMainMenu;
begin
  Result := nil;
  if not Supports(BorlandIDEServices, INTAServices, LServices) then
    Exit;
  LMainMenu := LServices.MainMenu;
  if not Assigned(LMainMenu) then
    Exit;
  Result := LMainMenu.Items.Find('View');
  if not Assigned(Result) then
    Result := LMainMenu.Items;
end;

procedure _RemoveSubMenu(const AParent: TMenuItem; const ACaption: string);
var
  LIndex: Integer;
begin
  if not Assigned(AParent) then
    Exit;
  for LIndex := AParent.Count - 1 downto 0 do
    try
      if SameText(AParent.Items[LIndex].Caption, ACaption) then
        AParent.Items[LIndex].Free;
    except
      on E: Exception do
        OutputDebugString(PChar('Aefos.OTA.Terminal: ignored stale menu item - '
          + E.Message));
    end;
end;

procedure TAefosTerminalWizard.CreateMenu;
var
  LParent: TMenuItem;
  LOpenItem: TMenuItem;
  LSepItem: TMenuItem;
  LLicenseItem: TMenuItem;
  LAboutItem: TMenuItem;
begin
  LParent := _FindMenuHost;
  if not Assigned(LParent) then
    Exit;
  // Drop any stale 'Aefos AI (Terminal)' from a previous load, then create
  // ours fresh. Unique caption => only this BPL matches, so this never touches the
  // Chat menu nor accumulates duplicates.
  _RemoveSubMenu(LParent, TERMINAL_PARENT_CAPTION);

  // FMenuItem is this BPL's OWN top-level menu under View (Open Terminal + Action
  // Center go directly under it).
  FMenuItem := TMenuItem.Create(LParent);
  FMenuItem.Caption := TERMINAL_PARENT_CAPTION;

  LOpenItem := TMenuItem.Create(FMenuItem);
  LOpenItem.Caption := 'Open Terminal';
  LOpenItem.OnClick := MenuClick;
  FMenuItem.Add(LOpenItem);

  FActionCenterMenuItem := TMenuItem.Create(FMenuItem);
  FActionCenterMenuItem.Caption := 'Action Center';
  FActionCenterMenuItem.OnClick := _ActionCenterMenuClick;
  FMenuItem.Add(FActionCenterMenuItem);

  LSepItem := TMenuItem.Create(FMenuItem);
  LSepItem.Caption := '-';
  FMenuItem.Add(LSepItem);

  LLicenseItem := TMenuItem.Create(FMenuItem);
  // License state in the menu, computed at LOAD (visible from IDE startup).
  try
    LLicenseItem.Caption := Aefos.License.Gate.TLicenseGate.StatusText;
  except
    LLicenseItem.Caption := 'License' + #$2026;
  end;
  LLicenseItem.OnClick := _LicenseMenuClick;
  FMenuItem.Add(LLicenseItem);

  LAboutItem := TMenuItem.Create(FMenuItem);
  LAboutItem.Caption := 'About Aefos' + #$2026;
  LAboutItem.OnClick := _AboutMenuClick;
  FMenuItem.Add(LAboutItem);

  LParent.Add(FMenuItem);
end;

procedure TAefosTerminalWizard.RemoveMenu;
begin
  // Defensive: freeing a menu item must never abort package uninstall. Remove ONLY
  // our own top-level menu — its 'Action Center' child is freed with it, and the
  // TMenuItem destructor unparents it from View. No shared parent to clean up, so
  // the host (View) is never touched.
  FActionCenterMenuItem := nil;
  try
    FreeAndNil(FMenuItem);
  except
    FMenuItem := nil;
  end;
end;


procedure TAefosTerminalWizard.Execute;
begin
  ShowAefosTerminalDockForm;
end;

function TAefosTerminalWizard.GetIDString: string;
begin
  Result := 'Aefos.OTA.Terminal';
end;

function TAefosTerminalWizard.GetName: string;
begin
  Result := 'Aefos.OTA.Terminal';
end;

function TAefosTerminalWizard.GetState: TWizardState;
begin
  Result := [wsEnabled];
end;

procedure TAefosTerminalWizard._ReloadBootCatalog;
var
  LStore: TActionStore;
begin
  FreeAndNil(FBootCatalog);
  LStore := TActionStore.Create;
  try
    FBootCatalog := LStore.LoadCatalog;
  finally
    LStore.Free;
  end;
end;

procedure TAefosTerminalWizard._RegisterKeyBinding;
begin
  // Bootstrap registration: load the persisted catalog so per-action
  // shortcuts are live at IDE startup, before the user opens the Action
  // Center panel for the first time (ADR-029-02).
  _ReloadBootCatalog;
  TAefosTerminalKeyBindingRegistry.Register(FBootCatalog as TActionCatalog);
end;

procedure TAefosTerminalWizard._UnregisterKeyBinding;
begin
  // Detach the global hook first so a still-alive view does not call back
  // into a half-torn-down wizard during finalization.
  AefosTerminalActionCenterChangedHook := nil;
  TAefosTerminalKeyBindingRegistry.Unregister;
  FreeAndNil(FBootCatalog);
end;

procedure TAefosTerminalWizard._ActionCenterCatalogChanged(Sender: TObject);
var
  LView: TActionCenterView;
begin
  if Sender is TActionCenterView then
  begin
    // The view has just persisted (or just constructed). Re-register against
    // the view's live FCatalog so keystrokes resolve against the same
    // instance the user is editing.
    LView := TActionCenterView(Sender);
    TAefosTerminalKeyBindingRegistry.Register(LView.Catalog);
  end
  else
  begin
    // Sender = nil signals view teardown. Reload from disk so per-action
    // shortcuts persisted this session stay active and GLiveCatalog stops
    // pointing at the view's about-to-be-freed catalog.
    _ReloadBootCatalog;
    TAefosTerminalKeyBindingRegistry.Register(FBootCatalog as TActionCatalog);
  end;
end;

procedure TAefosTerminalWizard._OpenOrRecreatePanel(APanel: TAefosTerminalPanelKind);
begin
  // ADR-054-01: shared recreate-on-stale-reference path for both panels.
  // After a close-via-X teardown the dock form / action-center view destructor
  // nils its module-scope singleton, so the ShowXxx call below sees
  // Assigned=False and materializes a fresh instance with theme + layout
  // restored. The csDestroying guard covers the rare race where the singleton
  // still points at a form whose destructor has started but not yet nilled the
  // singleton (e.g. wizard teardown reordering).
  case APanel of
    TAefosTerminalPanelKind.pkTerminal:
      begin
        if Assigned(AefosTerminalDockForm) and
           (csDestroying in AefosTerminalDockForm.ComponentState) then
          AefosTerminalDockForm := nil;
        ShowAefosTerminalDockForm;
      end;
    TAefosTerminalPanelKind.pkActionCenter:
      begin
        if Assigned(AefosActionCenterView) and
           (csDestroying in AefosActionCenterView.ComponentState) then
          AefosActionCenterView := nil;
        ShowAefosActionCenterView;
      end;
  end;
end;

procedure TAefosTerminalWizard.MenuClick(Sender: TObject);
begin
  // The Terminal itself is FREE (decided 2026-06-16). The Pro paywall is the MCP
  // server (the AI driving the IDE) — gated in _StartMCPHostIfEnabled — so a free
  // user gets the terminal but WITHOUT the IDE tools.
  _OpenOrRecreatePanel(TAefosTerminalPanelKind.pkTerminal);
end;

procedure TAefosTerminalWizard._ActionCenterMenuClick(Sender: TObject);
begin
  _OpenOrRecreatePanel(TAefosTerminalPanelKind.pkActionCenter);
end;

procedure TAefosTerminalWizard._AboutMenuClick(Sender: TObject);
begin
  // Branded modal About (logo lockup + support facts, version from FILEVERSION).
  ShowTerminalAboutDialog;
end;

procedure TAefosTerminalWizard._LicenseMenuClick(Sender: TObject);
begin
  // Opens the Aefos.License BPL's activation screen (shared with Chat).
  Aefos.License.Gate.TLicenseGate.ShowManager;
  // Refresh the menu caption so a just-activated state shows without a restart.
  if Sender is TMenuItem then
    try
      TMenuItem(Sender).Caption := Aefos.License.Gate.TLicenseGate.StatusText;
    except
    end;
end;

procedure TAefosTerminalWizard._AppShortCut(var AMsg: TWMKey; var AHandled: Boolean);
begin
  // Application.OnShortCut runs before any form's IsShortCut, so this fires
  // even when the dock form is not Screen.ActiveCustomForm (i.e. while the
  // terminal is docked inside the IDE main form). Intercept plain Ctrl+C
  // when the terminal canvas is focused, route to the canvas, and stop the
  // IDE's global Edit > Copy action. Chain to any prior handler so other
  // plugins that hooked OnShortCut before us keep working.
  if (AMsg.CharCode = Ord('C')) and
     (GetKeyState(VK_CONTROL) < 0) and
     (GetKeyState(VK_MENU) >= 0) and
     (GetKeyState(VK_SHIFT) >= 0) and
     Assigned(AefosTerminalDockForm) and
     Assigned(AefosTerminalDockForm.FocusedView) and
     Assigned(AefosTerminalDockForm.FocusedView.TerminalCanvas) and
     AefosTerminalDockForm.FocusedView.TerminalCanvas.Focused then
  begin
    AefosTerminalDockForm.FocusedView.TerminalCanvas.SendCtrlC;
    AHandled := True;
    Exit;
  end;
  if Assigned(FPriorAppShortCut) then
    FPriorAppShortCut(AMsg, AHandled);
end;

procedure TAefosTerminalWizard._InstallAppShortCutHook;
begin
  if FAppShortCutInstalled then
    Exit;
  FPriorAppShortCut := Application.OnShortCut;
  Application.OnShortCut := _AppShortCut;
  FAppShortCutInstalled := True;
end;

procedure TAefosTerminalWizard._UninstallAppShortCutHook;
begin
  // Restore the prior handler. If another plugin chained over us after we
  // installed, this overwrites their chain — acceptable trade-off during
  // BPL teardown; the alternative would leave our freed method address in
  // Application.OnShortCut and fault the IDE on the next shortcut.
  if not FAppShortCutInstalled then
    Exit;
  Application.OnShortCut := FPriorAppShortCut;
  FAppShortCutInstalled := False;
end;

procedure TAefosTerminalWizard._RegisterMCPOptions;
var
  LEnvSvc: INTAEnvironmentOptionsServices;
begin
  // Shared AI Flow page (silent-reload knob) from MCP.Tools.OTA — refcounted,
  // so registering here is a no-op when the Chat BPL already did it.
  TAIFlowOptions.RegisterAIFlowOptions;
  if not Assigned(FMCPOptions) then
    Exit;
  if Supports(BorlandIDEServices, INTAEnvironmentOptionsServices, LEnvSvc) then
    LEnvSvc.RegisterAddInOptions(FMCPOptions);
end;

procedure TAefosTerminalWizard._UnregisterMCPOptions;
var
  LEnvSvc: INTAEnvironmentOptionsServices;
begin
  TAIFlowOptions.UnregisterAIFlowOptions;
  if not Assigned(FMCPOptions) then
    Exit;
  if Supports(BorlandIDEServices, INTAEnvironmentOptionsServices, LEnvSvc) then
    LEnvSvc.UnregisterAddInOptions(FMCPOptions);
end;

procedure TAefosTerminalWizard._StartMCPHostIfEnabled;
var
  LConfig: TMCPTerminalConfig;
begin
  if not Assigned(FMCPBinding) then
    Exit;
  LConfig := (FMCPBinding as TMCPConfigBinding).Current;
  if not LConfig.Enabled then
    Exit;
  // MCP is the Pro paywall: the free tier gets the Terminal but WITHOUT the MCP
  // server (the AI cannot drive the IDE). Beta is SOFT (GATE_HARD_MODE off) so the
  // server still starts for everyone to test; at GA the free tier gets no MCP.
  if Aefos.License.Gate.TLicenseGate.GateHard
     and not Aefos.License.Gate.TLicenseGate.Allows(AEFOS_CAP_MCP) then
    Exit;
  if not Assigned(FMCPHost) then
    FMCPHost := TTerminalMCPHost.Create(LConfig,
      TMCPWorkspaceFacade.Create(
        Cardinal(LConfig.ConsentTimeoutSecs) * 1000, LConfig.AuditPath));
  // Starting the MCP server must NEVER abort plugin registration. CreateNamedPipe
  // returns EOSError 231 (ERROR_PIPE_BUSY) when the pipe name already has
  // PIPE_MAX_INSTANCES handles alive — e.g. a server leaked by a prior load whose
  // worker threads force-leaked on Stop (BR-7), or another Aefos host
  // already serving this session's pipe name. Unguarded, that exception escaped
  // Register and the IDE disabled the whole Aefos.OTA.Terminal package
  // (issue: 'Registration procedure ... raised exception class EOSError. Code:
  // 231'). Degrade instead: log and drop the half-built host so a later
  // _OnMCPConfigChanged (or a fresh IDE session) can retry cleanly. The plugin
  // and its terminal UI load regardless.
  try
    (FMCPHost as TTerminalMCPHost).Start;
  except
    on E: Exception do
    begin
      OutputDebugString(PChar('Aefos.OTA.Terminal: MCP host start failed ('
        + E.ClassName + ' - ' + E.Message + '); plugin loaded, MCP server off. '
        + 'Pipe in use? Restart the IDE or change the Terminal MCP session name.'));
      FreeAndNil(FMCPHost);
    end;
  end;
end;

procedure TAefosTerminalWizard._StopMCPHost;
begin
  if Assigned(FMCPHost) then
  begin
    (FMCPHost as TTerminalMCPHost).Stop;
    FreeAndNil(FMCPHost);
  end;
end;

procedure TAefosTerminalWizard._OnMCPConfigChanged;
begin
  // No-op apply guard: 'Test MCP' (and DialogClosed OK) applies on EVERY
  // click, but bouncing a healthy host to IDENTICAL config drops connected
  // clients for nothing — and the stop-join is where a mid-dispatch worker
  // can leak (field crash 2026-07-08: C0150014 right after the click,
  // 'Unknown Hard Error' on IDE close). A host that failed to start (or is
  // disabled) still falls through, so the click keeps working as a retry.
  if Assigned(FMCPHost) and (FMCPHost as TTerminalMCPHost).Started and
     (FMCPHost as TTerminalMCPHost).Matches((FMCPBinding as TMCPConfigBinding).Current) then
    Exit;
  _StopMCPHost;
  _StartMCPHostIfEnabled;
end;

initialization

finalization
  // The wizard is added via IOTAWizardServices.AddWizard, which does not own
  // it (TNotifierObject is not reference-counted). It MUST be removed and
  // freed here, in package finalization, while the BPL image is still mapped.
  // Otherwise the IDE keeps a dangling IOTAWizard pointer (faulting on the
  // next 'Checking project dependencies' / rebuild / uninstall) and the
  // IOTAIDENotifier registered by the IDE hooks stays in the IDE notifier
  // list (faulting on project-group close / IDE shutdown). RemoveWizard drops
  // the IDE slot; FreeAndNil runs TAefosTerminalWizard.Destroy, which unregisters
  // the key binding, the IDE hooks notifier and the menus, and frees the
  // dock form — all the teardown the IDE would otherwise never trigger.
  if GAefosTerminalWizardIndex >= 0 then
  begin
    try
      (BorlandIDEServices as IOTAWizardServices).RemoveWizard(GAefosTerminalWizardIndex);
    except
      on E: Exception do
        OutputDebugString(PChar('Aefos.OTA.Terminal: RemoveWizard failed - ' + E.Message));
    end;
    GAefosTerminalWizardIndex := -1;
  end;
  try
    GAefosTerminalWizard := nil;
  except
    on E: Exception do
      OutputDebugString(PChar('Aefos.OTA.Terminal: wizard teardown failed - ' + E.Message));
  end;

end.



