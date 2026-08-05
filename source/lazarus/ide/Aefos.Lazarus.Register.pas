unit Aefos.Lazarus.Register;

{ Aefos AI - Lazarus edition (design package skeleton).

  Registers a top-level "Aefos AI" menu in the Lazarus IDE at package LOAD,
  mirroring the Delphi plugin's register-at-load doctrine. This is the first
  visible-in-IDE artifact of the Lazarus port; it exposes only an About dialog
  and a link to the product web page. No editor, chat or designer features live
  here yet - those arrive in later phases.

  Menu registration uses MenuIntf (RegisterIDESubMenu / RegisterIDEMenuCommand),
  anchored on mnuView so "Aefos AI" lives UNDER the IDE's View menu -- the native
  Lazarus home for tool-window access, and the SAME place the Delphi edition puts
  it (Aefos.OTA.Chat.Adapter.MainMenu, maintainer decision 2026-06-08).
  See C:\lazarus\components\ideintf\menuintf.pas:
    - mnuView (View menu section) declared at line 278; mnuMain at line 251
    - RegisterIDESubMenu (Parent; Name; Caption; ...) at line 478
    - RegisterIDEMenuCommand (Parent; Name; Caption; OnClickMethod; ...) at 504

  Mode note: this IDE-glue unit compiles in mode delphi rather than the port's
  general delphiunicode choice. Every string it touches is an LCL/IDEIntf
  AnsiString (UTF-8); mode delphi makes string = that AnsiString, so the LCL
  boundary is conversion-free. The delphiunicode default targets the ported
  text-processing units where UnicodeString semantics matter - not this glue.
  All literals are pure ASCII, so the file needs no BOM. }

{$mode delphi}
{$H+}

interface

{ Register is the platform-mandated entry point Lazarus calls for every unit
  flagged HasRegisterProc in the package. It is the only loose routine allowed
  here - it is the IDE contract, not project style. }
procedure Register;

implementation

uses
  Classes,
  SysUtils,
  Dialogs,
  LCLIntf,
  LCLType,
  LazUTF8,
  LazLoggerBase,
  MenuIntf,
  IDECommands,
  LazIDEIntf,
  Aefos.MCP.IntentGuard,
  Aefos.MCP.Types,
  Aefos.Compat.Json,
  Aefos.Lazarus.WorkspaceFacade,
  Aefos.Lazarus.GutterReview,
  Aefos.Lazarus.FormDesigner,
  Aefos.Lazarus.McpHost,
  Aefos.Lazarus.Options,
  Aefos.Lazarus.PyToolsWindow,
  Aefos.Lazarus.ChatWindow,
  Aefos.Lazarus.TerminalWindow,
  Aefos.Lazarus.ActionCenterWindow,
  Aefos.Lazarus.AboutForm,
  Aefos.Lazarus.AppIdentity;

type
  { All menu click handlers live as class methods so no loose procedures are
    exported; they are assigned to the MenuIntf TNotifyEvent slots. }
  TAefosLazMenu = class
  public
    class procedure HandleAbout(ASender: TObject);
    class procedure HandleWeb(ASender: TObject);
    { Opens Tools > Options at the Aefos AI page. Deep-link caveat honoured in
      the body. }
    class procedure HandleOptions(ASender: TObject);
    {$IFDEF AEFOS_DIAG_MENU}
    { Diagnostic: exercises the MCP workspace-facade read slice live against the
      running IDE (Phase F). Proves the OTA-free core's IDE contract is met by
      the Lazarus IDEIntf backend without any chat/server machinery. }
    class procedure HandleFacadeSmoke(ASender: TObject);
    { Diagnostic: exercises the Phase H editor WRITE slice - inserts a labeled
      comment at the top of the active unit inside ONE undo block (single Ctrl+Z
      reverts) and ends in the code editor (RULE #1). }
    class procedure HandleWriteSmoke(ASender: TObject);
    { Diagnostic: exercises the Phase J LIVE FORM DESIGNER on the ACTIVE form -
      flips to Design, sprouts a TButton live (the IDE declares its published
      field), sets its Caption via RTTI, and reads the live .lfm back. Proves the
      moat in-IDE with one click (it has a headless twin). }
    class procedure HandleDesignSmoke(ASender: TObject);
    {$ENDIF}
    { Start/stop the hosted MCP server (Aefos.Lazarus.McpHost). Toggles the
      single owned server; the menu caption reflects the resulting state. This is
      the payoff of the port: an AI CLI connects to the named pipe and drives the
      IDE through the live read/editor tools. }
    class procedure HandleToggleMcp(ASender: TObject);
    { Opens the LCL "Aefos AI Chat" window (Phase M first slice): a windowed
      WebView2 host (Aefos's own clean-room SDK, no CEF) showing a minimal shell
      that proves the JS<->Pascal bridge live. The full chat loop (executor
      dispatch / streaming) is a later slice. }
    class procedure HandleOpenChat(ASender: TObject);
    { Opens the "Python Tools" manager window (Aefos.Lazarus.PyToolsWindow): a
      native LCL dialog to create/edit/delete the drop-a-folder Python tools in
      %APPDATA%\Aefos\pytools - the SAME store the RAD Studio plugin uses. Never
      raises out (it only edits files; a fault is logged, not propagated). }
    class procedure HandleOpenPyTools(ASender: TObject);
    { Opens the "Aefos AI Terminal" window (Aefos.Lazarus.TerminalWindow): a native
      LCL terminal control docked (AnchorDocking) as a bottom IDE tool panel, hosting
      a live cmd.exe behind a pseudo-console. The user types and sees output. Never
      raises out - a spawn failure only shows a notice on the grid. }
    class procedure HandleOpenTerminal(ASender: TObject);
    { Opens the "Aefos AI - Action Center" window (Aefos.Lazarus.ActionCenterWindow):
      a floating LCL panel listing the saved terminal actions grouped by category,
      with Run/New/Edit/Delete. Double-click / Run injects the action's script
      lines into the open terminal. Never raises out - a fault only logs. }
    class procedure HandleOpenActionCenter(ASender: TObject);
    { Opens the license activation/management screen (the shared cross-compiler
      gate's LCL UI): fingerprint, status, key field, Activate/Deactivate/
      Register/Close. Mirrors the Delphi Chat host's "License..." item; refreshes
      its own caption to the live status after the dialog closes. }
    { Change-review gutter (Model B) resolvers. "Approve All Changes" keeps every
      applied agent edit and drops the markers; "Reject All Changes" restores each
      unit's pre-edit text and drops the markers. Both are safe no-ops when nothing
      is pending, and guarded so a fault never crashes the IDE. }
    class procedure HandleApproveAll(ASender: TObject);
    class procedure HandleRejectAll(ASender: TObject);
  end;

const
  cProductName  = 'Aefos AI';
  cEditionLine  = 'Lazarus edition - under construction.';
  cVersionLine  = 'Version 0.1.0';
  cWebUrl       = 'https://www.pubpascal.dev';

  { Menu captions. Three ASCII dots stand in for the ellipsis (BOM-free); the
    Delphi edition uses a real U+2026, but that is a visually identical glyph and
    keeping ASCII here preserves this glue unit's BOM-free/pure-ASCII property. }
  cAboutCaption   = 'About Aefos AI...';
  cWebCaption     = 'Aefos AI on the web';
  cOptionsCaption = 'Options...';
  {$IFDEF AEFOS_DIAG_MENU}
  cSmokeCaption   = 'MCP facade smoke (diagnostic)...';
  cWriteSmokeCaption = 'MCP write smoke: insert top comment (diagnostic)...';
  cDesignSmokeCaption = 'MCP design smoke: sprout a live button (diagnostic)...';
  {$ENDIF}
  { The "Aefos AI (Chat)" submenu caption mirrors the Delphi edition's TopMenuCaption
    (Aefos.OTA.Chat.Adapter.MainMenu.TopMenuCaption) so both IDEs show the SAME group
    name under View. "Open Chat" is the Delphi caption for the chat-open item
    (Aefos.OTA.Chat.Register._InitChatMenuBar:3215), NOT the old "Aefos AI Chat...". }
  cChatMenuCaption    = 'Aefos AI (Chat)';
  cOpenChatCaption    = 'Open Chat';
  { The PyTools group mirrors the Delphi edition's single top-level "Aefos PyTools"
    item under View (Aefos.OTA.MCP.PyToolsManager.CMenuCaption), a direct-click
    entry (no "Python Tools..." child) that opens the manager. }
  cPyToolsCaption     = 'Aefos PyTools';
  { Same tag the Delphi edition appends, so the two editions read identically for
    the same license state. }
  cPyToolsProTag      = '   (Pro)';
  { The "Aefos AI (Terminal)" sibling mirrors the Delphi edition's terminal group
    under View; "Open Terminal" opens the docked terminal panel. }
  cTerminalMenuCaption = 'Aefos AI (Terminal)';
  cOpenTerminalCaption = 'Open Terminal';
  { "Action Center" opens the saved-actions catalog window; it sits next to
    "Open Terminal" in the OPEN section, matching the Delphi terminal group order
    (Open Terminal / Action Center). }
  cActionCenterCaption = 'Action Center';
  { The toggle caption reflects state: "Start ..." when stopped, "Stop ..." when
    the server is listening (English-only, vendor-neutral). }
  cMcpStartCaption = 'Start Aefos MCP server';
  cMcpStopCaption  = 'Stop Aefos MCP server';
  { Change-review gutter items (Model B parity with the Delphi approve/reject-all). }
  cApproveAllCaption = 'Approve All Changes';
  cRejectAllCaption  = 'Reject All Changes';

  { Stable, unique IDE menu-path identifiers. }
  cMenuChatRootName  = 'itmAefosAIChatMenu';
  { Sections inside the Chat submenu -- each renders as a group separated by a
    divider line (TIDEMenuSection auto-inserts top/bottom separators between
    adjacent sections), mirroring the single separator the Delphi Chat submenu
    places after "Open Chat". }
  cSecChatOpenName   = 'secAefosAIChatOpen';
  cSecChatInfoName   = 'secAefosAIChatInfo';
  cSecChatMcpName    = 'secAefosAIChatMcp';
  {$IFDEF AEFOS_DIAG_MENU}
  cSecChatDiagName   = 'secAefosAIChatDiag';
  {$ENDIF}
  cMenuAboutName     = 'itmAefosAIAbout';
  cMenuWebName       = 'itmAefosAIWeb';
  cMenuOptionsName   = 'itmAefosAIOptions';
  {$IFDEF AEFOS_DIAG_MENU}
  cMenuSmokeName     = 'itmAefosAIFacadeSmoke';
  cMenuWriteSmokeName = 'itmAefosAIWriteSmoke';
  cMenuDesignSmokeName = 'itmAefosAIDesignSmoke';
  {$ENDIF}
  cMenuChatName      = 'itmAefosAIChat';
  cMenuPyToolsName   = 'itmAefosAIPyTools';
  cMenuTerminalRootName = 'itmAefosAITerminalMenu';
  cSecTerminalOpenName  = 'secAefosAITerminalOpen';
  cMenuTerminalName     = 'itmAefosAITerminal';
  cMenuTerminalActionCenterName = 'itmAefosAITerminalActionCenter';
  { Info block of the Terminal submenu -- License + About, mirroring the Delphi
    edition's terminal group (which carries the SAME live-license + About items
    the Chat submenu does). "Action Center" now lives in the OPEN section above
    (cSecTerminalOpenName), next to "Open Terminal", matching the Delphi order. }
  cSecTerminalInfoName    = 'secAefosAITerminalInfo';
  cMenuTerminalLicenseName = 'itmAefosAITerminalLicense';
  cMenuTerminalAboutName   = 'itmAefosAITerminalAbout';
  cMenuMcpToggleName = 'itmAefosAIMcpToggle';
  cSecChatReviewName = 'secAefosAIChatReview';
  cMenuApproveAllName = 'itmAefosAIApproveAll';
  cMenuRejectAllName  = 'itmAefosAIRejectAll';
  { Environment override: when AEFOS_LAZ_MCP_AUTOSTART=1, Register starts the MCP
    server at package load. This is how the headless runtime proof drives the
    server without a mouse click (the IDE cannot be clicked in a smoke run); it
    also lets a power user auto-enable the server. }
  cAutostartEnvVar = 'AEFOS_LAZ_MCP_AUTOSTART';

  { The IDE command (a rebindable shortcut) for the About action. Registered in
    the standard 'Custom' command category so it shows up in the keymap editor
    under a scope where a global shortcut fires. }
  cCmdShowAboutName = 'AefosShowAbout';
  cCmdShowAboutText = 'Show Aefos AI About';

  { Teardown/registration breadcrumb tag - visible only with --debug-log, the
    Lazarus twin of the Delphi side's teardown-log discipline. }
  cLogTag = '[AefosAI] ';

var
  { The toggle menu item, kept so its caption can be flipped to reflect the
    running state after a toggle or an autostart. }
  GMcpToggleItem: TIDEMenuCommand = nil;
  { The License menu item, kept so its caption can be refreshed to the live
    license status (trial/active/expired/...) after the dialog closes. }
  GLicenseItem: TIDEMenuCommand = nil;
  { The Terminal submenu's own License item -- a distinct menu command from the
    Chat one, so its live caption is refreshed alongside GLicenseItem. }
  GTerminalLicenseItem: TIDEMenuCommand = nil;

{ --- License gates -------------------------------------------------------------

  Both wrap the gate in try/except, and that is not defensive habit: the gate
  reads an on-disk record and a clock, these run INSIDE Register, and CLAUDE.md
  rule #4 is that registration must never raise. The fallback direction differs
  per question, and each is chosen so a broken license file cannot punish the
  user:

    * a failed read must not HIDE a menu he paid for  -> PyTools defaults to shown
    * a failed read must not WITHHOLD the server      -> MCP defaults to allowed

  Same conclusion both times: when we cannot tell, we do not take anything away. }

{ Pro, but hidden ONLY where the build gates hard -- the exact shape of the RAD
  Studio edition's RegisterPyToolsMenu. Was a bare Allows on both sides, which
  hid the item for a free tier in every build while every other Pro surface
  honoured GATE_HARD_MODE and stayed visible through the soft beta. }
{ Flips the toggle caption to match the current server state. Never creates the
  host singleton just to read state (AefosLazMcpHostExists gate), so calling it
  before any start leaves the host uncreated. }
procedure _UpdateMcpToggleCaption;
var
  LRunning: Boolean;
begin
  if GMcpToggleItem = nil then
    Exit;
  LRunning := AefosLazMcpHostExists and AefosLazMcpHost.Started;
  if LRunning then
    GMcpToggleItem.Caption := cMcpStopCaption
  else
    GMcpToggleItem.Caption := cMcpStartCaption;
end;

class procedure TAefosLazMenu.HandleToggleMcp(ASender: TObject);
begin
  { A user click: creating the host here is expected. Start/Stop are idempotent
    and never raise out, so the toggle can never crash the IDE. }
  if AefosLazMcpHost.Started then
  begin
    DebugLn(cLogTag + 'MCP toggle: STOP requested');
    AefosLazMcpHost.Stop;
  end
  else
  begin
    DebugLn(cLogTag + 'MCP toggle: START requested');
    { Same Pro gate as the autostart path and as the RAD Studio terminal host
      (Terminal.UI.Wizard.pas:549). It answers an explicit click, so unlike the
      silent autostart it SAYS why nothing happened -- refusing without a reason
      is the failure mode that made the pipe-busy bug look like a broken feature. }
    AefosLazMcpHost.Start;
    { The user just ASKED for the server. Silence on failure is what made the
      usual cause -- a second IDE already holding the fixed pipe name -- look like
      the feature was broken. This dialog is safe: it answers an explicit click,
      not an agent tool call, so it cannot be the modal that freezes the pipe. }
    if (not AefosLazMcpHost.Started) and (AefosLazMcpHost.LastStartError <> '') then
      MessageDlg(cProductName, UTF16ToUTF8(AefosLazMcpHost.LastStartError),
        mtWarning, [mbOK], 0);
  end;
  _UpdateMcpToggleCaption;
end;

class procedure TAefosLazMenu.HandleAbout(ASender: TObject);
begin
  // Branded modal (black canvas + Aefos lockup logo), the LCL twin of the Delphi
  // Chat host's About dialog - replaces the old plain MessageDlg.
  ShowLazAboutDialog;
end;

class procedure TAefosLazMenu.HandleWeb(ASender: TObject);
begin
  OpenURL(cWebUrl);
end;

class procedure TAefosLazMenu.HandleOptions(ASender: TObject);
begin
  // Deep-link into Tools > Options at the Aefos AI executor page. IDEIntf's
  // DoOpenIDEOptions(EditorClass) selects our editor node by class - a stronger
  // seam than the generic OpenEditor(EditorClass) (01-ideintf-core.md gap #2:
  // exact-page focus was the OTA EditOptions(Area, PageCaption) concern). We
  // pass the concrete editor class, so the dialog opens ON the Aefos AI node;
  // whether it also scrolls/focuses that exact node in every Lazarus build is
  // the LIVE-VERIFY item (running IDE) - the call is honest, not faked, and
  // degrades to opening the dialog if the build cannot focus the node.
  if LazarusIDE <> nil then
    LazarusIDE.DoOpenIDEOptions(TAefosOptionsFrame);
end;

{ Refresh every live "License: <state>" menu caption (Chat submenu + Terminal
  submenu) to the current gate status. StatusText is UnicodeString (the gate
  core); convert to the LCL UTF-8 AnsiString caption at the boundary. Guarded so a
  gate-read failure leaves the static fallback caption instead of raising. }
{$IFDEF AEFOS_DIAG_MENU}
class procedure TAefosLazMenu.HandleFacadeSmoke(ASender: TObject);
var
  LFacade: IMCPWorkspaceFacade;
  { The facade's `string` members are UnicodeString (Aefos.MCP.Types compiles in
    delphiunicode); this glue is mode delphi, so results cross back to UTF-8 via
    LazUTF8.UTF16ToUTF8 - the mirror of the facade's own UTF8ToUTF16 boundary. }
  LNameU, LPathU, LContentU, LActionsU: UnicodeString;
  LName, LPath, LIntent, LCount: string;
  LBytes: Integer;
  LJson: TJSONValue;
  LCountVal: TJSONValue;
begin
  LFacade := NewAefosLazWorkspaceFacade;

  { Active editor file (name + path). }
  if LFacade.GetEditorActiveFile(LNameU, LPathU) then
  begin
    LName := UTF16ToUTF8(LNameU);
    LPath := UTF16ToUTF8(LPathU);
  end
  else
  begin
    LName := '(none)';
    LPath := '(none)';
  end;

  { Live source text -> UTF-8 byte count. }
  LBytes := 0;
  if LFacade.GetEditorFullContent(LContentU) then
    LBytes := Length(UTF16ToUTF8(LContentU));

  { RULE #1 view intent (Lazarus form: live-designer existence). }
  case LFacade.CurrentIdeViewIntent of
    tiDesign: LIntent := 'Design (a live designer exists for this unit)';
    tiCode:   LIntent := 'Code (source editor active, no live designer)';
  else
    LIntent := 'Neutral (no active editor)';
  end;

  { IDE command catalog -> parse the count out of the facade JSON. }
  LCount := '?';
  LActionsU := LFacade.ListIDEActions('');
  LJson := TJSONObject.ParseJSONValue(LActionsU);
  try
    if (LJson <> nil) and (LJson is TJSONObject) then
    begin
      LCountVal := TJSONObject(LJson).GetValue('count');
      if LCountVal <> nil then
        LCount := UTF16ToUTF8(LCountVal.Value);
    end;
  finally
    LJson.Free;
  end;

  MessageDlg(cProductName,
    'Aefos AI - MCP facade smoke (read slice, diagnostic)' + LineEnding + LineEnding
    + 'Active unit  : ' + LName + LineEnding
    + 'Path         : ' + LPath + LineEnding
    + 'Source bytes : ' + IntToStr(LBytes) + ' (UTF-8)' + LineEnding
    + 'View intent  : ' + LIntent + LineEnding
    + 'IDE commands : ' + LCount + LineEnding + LineEnding
    + 'Backend: Aefos.Lazarus.WorkspaceFacade (Phase F read slice).' + LineEnding
    + 'Write / design members raise ENotSupportedException until phase H+.',
    mtInformation, [mbOK], 0);
end;

class procedure TAefosLazMenu.HandleWriteSmoke(ASender: TObject);
var
  LFacade: IMCPWorkspaceFacade;
  LNameU, LPathU, LContentU, LNewU: UnicodeString;
  LName: string;
  LOk: Boolean;
begin
  LFacade := NewAefosLazWorkspaceFacade;

  { Need an active source editor to write into. }
  if not LFacade.GetEditorActiveFile(LNameU, LPathU) then
  begin
    MessageDlg(cProductName,
      'MCP write smoke: no active source editor. Open a unit and retry.',
      mtWarning, [mbOK], 0);
    Exit;
  end;
  LName := UTF16ToUTF8(LNameU);

  if not LFacade.GetEditorFullContent(LContentU) then
  begin
    MessageDlg(cProductName,
      'MCP write smoke: could not read the active buffer.',
      mtWarning, [mbOK], 0);
    Exit;
  end;

  { Prepend a clearly-labeled diagnostic comment. SetEditorFullContent wraps the
    whole replace in one undo block, so a single Ctrl+Z reverts it; the write
    also flips to and ends in the code editor (RULE #1, doctrine 2). All literals
    are ASCII, so UTF8ToUTF16 of the prefix is exact. }
  LNewU := UTF8ToUTF16('// Aefos AI write-slice smoke (diagnostic) - '
      + FormatDateTime('yyyy-mm-dd hh:nn:ss', Now)
      + ' - single Undo (Ctrl+Z) reverts this line.' + LineEnding)
    + LContentU;

  LOk := LFacade.SetEditorFullContent(LNewU);

  MessageDlg(cProductName,
    'Aefos AI - MCP write-slice smoke (Phase H, diagnostic)' + LineEnding + LineEnding
    + 'Active unit  : ' + LName + LineEnding
    + 'Write result : ' + BoolToStr(LOk, True) + LineEnding + LineEnding
    + 'A diagnostic comment was inserted at the TOP of the buffer inside ONE' + LineEnding
    + 'undo block. Press Ctrl+Z once to revert it. The editor is now focused' + LineEnding
    + '(a code write lands AND ends in Code).',
    mtInformation, [mbOK], 0);
end;

class procedure TAefosLazMenu.HandleDesignSmoke(ASender: TObject);
var
  LReason, LLfm: string;
  LShown, LAdded, LSetProp, LRead: Boolean;
  LButtonSeen: Boolean;
const
  cComp = 'AefosSmokeButton';
begin
  { The engine is mode delphi (UTF-8 string), same as this glue - no conversion.
    An empty unit name targets the form the user has OPEN (module-first). }
  LShown := TAefosLazFormDesigner.ShowFormDesigner('', LReason);
  LAdded := TAefosLazFormDesigner.AddComponent('', 'TButton', cComp, '',
    24, 24, 90, 30, LReason);
  if not LAdded then
  begin
    MessageDlg(cProductName,
      'MCP design smoke: AddComponent did not apply.' + LineEnding
      + 'Reason: ' + LReason + LineEnding + LineEnding
      + 'Open a FORM unit and show its Form Designer, then retry ' +
      '(AddComponent needs a live designer for the active form).',
      mtWarning, [mbOK], 0);
    Exit;
  end;
  LSetProp := TAefosLazFormDesigner.SetComponentProperty('', cComp,
    'Caption', 'Aefos', LReason);
  LRead := TAefosLazFormDesigner.GetLiveFormLfm('', LLfm);
  LButtonSeen := LRead and (Pos(cComp, LLfm) > 0);

  MessageDlg(cProductName,
    'Aefos AI - MCP design smoke (Phase J, diagnostic)' + LineEnding + LineEnding
    + 'ShowFormDesigner    : ' + BoolToStr(LShown, True) + LineEnding
    + 'AddComponent TButton: ' + BoolToStr(LAdded, True)
      + ' (name ' + cComp + ')' + LineEnding
    + 'SetProperty Caption : ' + BoolToStr(LSetProp, True) + LineEnding
    + 'Live .lfm read      : ' + BoolToStr(LRead, True) + LineEnding
    + 'Button in live .lfm : ' + BoolToStr(LButtonSeen, True) + LineEnding
    + LineEnding
    + 'The button SPROUTED on the live form and the IDE declared its published' + LineEnding
    + 'field in the .pas (watch the source). Ctrl+Z in the designer removes it.',
    mtInformation, [mbOK], 0);
end;
{$ENDIF}

class procedure TAefosLazMenu.HandleOpenChat(ASender: TObject);
begin
  { A user click: show/focus the chat -- the native DOCKED IDE panel when
    AnchorDocking is active, else a floating fallback window (create-on-demand).
    Never raises out - the WebView2 host degrades to OnFailed if the runtime/loader
    is absent, so the click can never crash the IDE. }
  try
    TAefosLazChatDock.Show;
  except
    on E: Exception do
      DebugLn(cLogTag + 'HandleOpenChat RAISED ' + E.ClassName + ': ' + E.Message);
  end;
end;

class procedure TAefosLazMenu.HandleOpenPyTools(ASender: TObject);
begin
  { A user click: show the modal PyTools manager. It only edits files under
    %APPDATA%\Aefos\pytools, so it can never touch the IDE editor/designer.
    Guarded so a fault only logs and never crashes the IDE. }
  try
    TAefosLazPyTools.ShowManager;
  except
    on E: Exception do
      DebugLn(cLogTag + 'HandleOpenPyTools RAISED '
        + E.ClassName + ': ' + E.Message);
  end;
end;

class procedure TAefosLazMenu.HandleApproveAll(ASender: TObject);
begin
  { Keep every applied agent edit; drop the review markers. No-op when nothing is
    pending. Guarded so a fault only logs and never crashes the IDE. }
  try
    TAefosLazGutterReview.ApproveAll;
  except
    on E: Exception do
      DebugLn(cLogTag + 'HandleApproveAll RAISED ' + E.ClassName + ': ' + E.Message);
  end;
end;

class procedure TAefosLazMenu.HandleRejectAll(ASender: TObject);
begin
  { Restore each unit's pre-edit text; drop the review markers. No-op when nothing
    is pending. Guarded so a fault only logs and never crashes the IDE. }
  try
    TAefosLazGutterReview.RejectAll;
  except
    on E: Exception do
      DebugLn(cLogTag + 'HandleRejectAll RAISED ' + E.ClassName + ': ' + E.Message);
  end;
end;

class procedure TAefosLazMenu.HandleOpenTerminal(ASender: TObject);
begin
  { A user click: show/focus the terminal -- the native DOCKED IDE panel when
    AnchorDocking is active, else a floating fallback window (create-on-demand).
    Never raises out - a shell-spawn failure only shows a notice on the grid. }
  try
    TAefosLazTerminalDock.Show;
  except
    on E: Exception do
      DebugLn(cLogTag + 'HandleOpenTerminal RAISED ' + E.ClassName + ': ' + E.Message);
  end;
end;

class procedure TAefosLazMenu.HandleOpenActionCenter(ASender: TObject);
begin
  { A user click: show/focus the saved-actions catalog window (create-on-demand,
    floating). It only reads/writes actions.json and injects script lines into the
    open terminal, so it can never touch the IDE editor/designer. Guarded so a
    fault only logs and never crashes the IDE. }
  try
    TAefosLazActionCenter.Show;
  except
    on E: Exception do
      DebugLn(cLogTag + 'HandleOpenActionCenter RAISED '
        + E.ClassName + ': ' + E.Message);
  end;
end;

procedure Register;
var
  LChatRoot: TIDEMenuSection;
  LTerminalRoot: TIDEMenuSection;
  LSecTerminalOpen: TIDEMenuSection;
  LSecTerminalInfo: TIDEMenuSection;
  LTerminal: TNotifyEvent;
  LActionCenter: TNotifyEvent;
  LSecOpen: TIDEMenuSection;
  LSecInfo: TIDEMenuSection;
  LSecReview: TIDEMenuSection;
  LSecMcp: TIDEMenuSection;
  {$IFDEF AEFOS_DIAG_MENU}
  LSecDiag: TIDEMenuSection;
  {$ENDIF}
  LAbout: TNotifyEvent;
  LWeb: TNotifyEvent;
  LOptions: TNotifyEvent;
  {$IFDEF AEFOS_DIAG_MENU}
  LSmoke: TNotifyEvent;
  LWriteSmoke: TNotifyEvent;
  LDesignSmoke: TNotifyEvent;
  {$ENDIF}
  LChat: TNotifyEvent;
  LPyTools: TNotifyEvent;
  LToggleMcp: TNotifyEvent;
  LApproveAll: TNotifyEvent;
  LRejectAll: TNotifyEvent;
  LCmdCategory: TIDECommandCategory;
  LAboutCommand: TIDECommand;
begin
  { Breadcrumb: Register RAN. If this line is absent from the debug log, the IDE
    never dispatched our unit's Register (look for a "register failed" line -
    packagesystem.pas RegisterUnitHandler could not match the unit in the lpk). }
  DebugLn(cLogTag + 'Register: begin (Aefos.Lazarus.Register)');

  { The IDE's OWN look, first thing: this exe is a SECOND Lazarus built by the
    Aefos installer and living beside the user's own one, and both carried the
    same MAINICON out of his ide\lazarus.res - indistinguishable in the taskbar
    and in Alt+Tab. One assignment to Application.Icon fixes both surfaces
    (see Aefos.Lazarus.AppIdentity for why that is the whole answer). It runs
    here because Register is dispatched from TMainIDE.Create, i.e. after
    Application.Initialize created the application window. ApplyIcon never
    raises; the guard is belt-and-braces, like the other registrations below. }
  try
    TAefosLazAppIdentity.ApplyIcon;
  except
    on E: Exception do
      DebugLn(cLogTag + 'Register: application icon RAISED '
        + E.ClassName + ': ' + E.Message);
  end;

  { Class methods form the method pointers the MenuIntf slots expect. }
  LAbout := TAefosLazMenu.HandleAbout;
  LWeb := TAefosLazMenu.HandleWeb;
  LOptions := TAefosLazMenu.HandleOptions;
  {$IFDEF AEFOS_DIAG_MENU}
  LSmoke := TAefosLazMenu.HandleFacadeSmoke;
  LWriteSmoke := TAefosLazMenu.HandleWriteSmoke;
  LDesignSmoke := TAefosLazMenu.HandleDesignSmoke;
  {$ENDIF}
  LChat := TAefosLazMenu.HandleOpenChat;
  LPyTools := TAefosLazMenu.HandleOpenPyTools;
  LTerminal := TAefosLazMenu.HandleOpenTerminal;
  LActionCenter := TAefosLazMenu.HandleOpenActionCenter;
  LToggleMcp := TAefosLazMenu.HandleToggleMcp;
  LApproveAll := TAefosLazMenu.HandleApproveAll;
  LRejectAll := TAefosLazMenu.HandleRejectAll;

  { Register the About action as a rebindable IDE command with a default
    shortcut (Ctrl+Shift+Alt+A), in the standard 'Custom' category so it appears
    in the keymap editor. The About menu item then REUSES this command, so the
    shortcut and the menu entry are one action (idecommands.pas:826). If the
    Custom category is somehow absent, fall back to a command-less menu item so
    registration never fails. }
  LAboutCommand := nil;
  LCmdCategory := IDECommandList.FindCategoryByName(CommandCategoryCustomName);
  if LCmdCategory <> nil then
    LAboutCommand := RegisterIDECommand(LCmdCategory,
      cCmdShowAboutName, cCmdShowAboutText,
      IDEShortCut(VK_A, [ssCtrl, ssShift, ssAlt], VK_UNKNOWN, []),
      CleanIDEShortCut, LAbout, nil);

  DebugLn(cLogTag + 'Register: about-command registered = '
    + BoolToStr(LAboutCommand <> nil, True));

  { The View menu is structured to MIRROR the Delphi edition's professional
    layout (Aefos.OTA.Chat.Register._InitChatMenuBar + Aefos.OTA.MCP.PyToolsManager):
    two sibling groups under View --

      View > Aefos AI (Chat)   (submenu)
                 Open Chat
                 --------------------------
                 Options...
                 About Aefos AI...
                 Aefos AI on the web
                 --------------------------
                 Start Aefos MCP server
      View > Aefos PyTools     (direct-click item)

    The Delphi "Aefos AI (Terminal)" sibling is now ALSO created (below, after the
    PyTools sibling): the Lazarus edition ships a native docked terminal
    (Aefos.Lazarus.TerminalWindow), so the group is real, not an empty shell. No
    glyphs are used -- the Delphi View items carry no bitmaps either, so parity means
    glyph-free grouping.

    Still registered at BPL LOAD (the register-at-load doctrine is unchanged) and
    anchored on mnuView; IDEIntf owns these items for the process lifetime, exactly
    as the pre-restructure code left them (no explicit finalization existed and none
    is added -- the tree is purely reorganised). }
  LChatRoot := RegisterIDESubMenu(mnuView, cMenuChatRootName, cChatMenuCaption);
  DebugLn(cLogTag + 'Register: View "' + cChatMenuCaption + '" submenu created = '
    + BoolToStr(LChatRoot <> nil, True)
    + '; mnuView child count now = ' + IntToStr(mnuView.Count));

  { Group 1 -- open the chat (top of the submenu, like Delphi's "Open Chat"). }
  LSecOpen := RegisterIDEMenuSection(LChatRoot, cSecChatOpenName);
  { The LCL chat window: windowed WebView2 host + bridge. }
  RegisterIDEMenuCommand(LSecOpen, cMenuChatName, cOpenChatCaption, LChat);

  { Group 2 -- settings + product info (Options / About / web), the block the
    Delphi submenu places below the separator. }
  LSecInfo := RegisterIDEMenuSection(LChatRoot, cSecChatInfoName);
  { Deep-link into Tools > Options at the Aefos AI executor page. }
  RegisterIDEMenuCommand(LSecInfo, cMenuOptionsName, cOptionsCaption, LOptions);
  if LAboutCommand <> nil then
    { Menu item bound to the command: caption + shortcut come from the command. }
    RegisterIDEMenuCommand(LSecInfo, cMenuAboutName, cAboutCaption, nil, nil,
      LAboutCommand)
  else
    RegisterIDEMenuCommand(LSecInfo, cMenuAboutName, cAboutCaption, LAbout);
  RegisterIDEMenuCommand(LSecInfo, cMenuWebName, cWebCaption, LWeb);
  { The three MCP smoke items were phase-verification proofs (F/H/J) shown live
    while the port was built. They are DIAGNOSTIC, not product, so they no longer
    ship in the user-facing menu -- gated behind AEFOS_DIAG_MENU (off by default;
    define it to bring them back for seam debugging). The handlers below stay
    compiled so re-enabling is a one-define change. }
  {$IFDEF AEFOS_DIAG_MENU}
  LSecDiag := RegisterIDEMenuSection(LChatRoot, cSecChatDiagName);
  RegisterIDEMenuCommand(LSecDiag, cMenuSmokeName, cSmokeCaption, LSmoke);
  RegisterIDEMenuCommand(LSecDiag, cMenuWriteSmokeName, cWriteSmokeCaption, LWriteSmoke);
  RegisterIDEMenuCommand(LSecDiag, cMenuDesignSmokeName, cDesignSmokeCaption, LDesignSmoke);
  {$ENDIF}

  { Group 2b -- change-review gutter (Model B) resolve actions. Its own section so
    a divider separates it from the info block. "Approve All Changes" keeps every
    applied agent edit; "Reject All Changes" restores each unit's pre-edit text.
    Both drop the gutter markers; both are safe no-ops when nothing is pending.
    Markers appear only when the shared "AgentEditReviewMode" is not "Apply
    silently" (Tools > Options > Aefos > AI Flow -> Inline edit review). }
  LSecReview := RegisterIDEMenuSection(LChatRoot, cSecChatReviewName);
  RegisterIDEMenuCommand(LSecReview, cMenuApproveAllName, cApproveAllCaption,
    LApproveAll);
  RegisterIDEMenuCommand(LSecReview, cMenuRejectAllName, cRejectAllCaption,
    LRejectAll);

  { Group 3 -- the hosted MCP server toggle (the payoff of the port). Its own
    section so a divider sets it apart from the info block. Caption starts as
    "Start ..." and flips after each toggle / autostart to reflect the state. }
  LSecMcp := RegisterIDEMenuSection(LChatRoot, cSecChatMcpName);
  GMcpToggleItem := RegisterIDEMenuCommand(LSecMcp, cMenuMcpToggleName,
    cMcpStartCaption, LToggleMcp);

  { Sibling group under View -- the "Aefos PyTools" manager, a direct-click item
    exactly like the Delphi edition's single top-level PyTools entry. Create/edit/
    delete drop-a-folder Python tools in %APPDATA%\Aefos\pytools (the SAME store
    the RAD Studio plugin edits).

    Pro, and hidden ONLY at GA -- the exact shape of the RAD Studio edition's
    RegisterPyToolsMenu. Parity is still the point; what changed is that BOTH
    editions now honour GATE_HARD_MODE instead of hiding unconditionally, so
    during the soft beta the item is present and tagged '(Pro)' on both sides.
    Guarded because a license read must never abort menu registration
    (CLAUDE.md rule #4). }
  RegisterIDEMenuCommand(mnuView, cMenuPyToolsName, cPyToolsCaption, LPyTools);

  { Sibling group under View -- "Aefos AI (Terminal)", mirroring the chat submenu
    shape and the Delphi edition's terminal group:

      View > Aefos AI (Terminal)   (submenu)
                 Open Terminal
                 Action Center
                 --------------------------
                 About Aefos AI...

    "Open Terminal" shows/docks the native terminal panel
    (Aefos.Lazarus.TerminalWindow); "Action Center" opens the saved-actions catalog
    window (Aefos.Lazarus.ActionCenterWindow), matching the Delphi terminal group
    order. The info block reuses the SAME About dialog the Chat submenu uses,
    so parity is real, not faked. }
  LTerminalRoot := RegisterIDESubMenu(mnuView, cMenuTerminalRootName,
    cTerminalMenuCaption);
  LSecTerminalOpen := RegisterIDEMenuSection(LTerminalRoot, cSecTerminalOpenName);
  RegisterIDEMenuCommand(LSecTerminalOpen, cMenuTerminalName, cOpenTerminalCaption,
    LTerminal);
  RegisterIDEMenuCommand(LSecTerminalOpen, cMenuTerminalActionCenterName,
    cActionCenterCaption, LActionCenter);

  { Info block -- its own section so a divider separates it from "Open Terminal".
    About reuses the same handler as the Chat submenu (no shortcut here -- the
    Chat/About item already owns the rebindable command). }
  LSecTerminalInfo := RegisterIDEMenuSection(LTerminalRoot, cSecTerminalInfoName);
  RegisterIDEMenuCommand(LSecTerminalInfo, cMenuTerminalAboutName, cAboutCaption,
    LAbout);

  { Register the terminal as a native DOCKABLE IDE panel (at LOAD, like the menu) so
    AnchorDocking can dock it as a bottom tool panel. Guarded so a failure only logs
    and degrades to a floating window -- it never blocks IDE startup. }
  try
    TAefosLazTerminalDock.RegisterDockable;
  except
    on E: Exception do
      DebugLn(cLogTag + 'Register: terminal dockable registration RAISED '
        + E.ClassName + ': ' + E.Message);
  end;

  { Register the chat as a native DOCKABLE IDE panel (at LOAD, like the menu) so
    AnchorDocking can dock it beside the editor. Guarded so a failure only logs and
    degrades to a floating window -- it never blocks IDE startup. }
  try
    TAefosLazChatDock.RegisterDockable;
  except
    on E: Exception do
      DebugLn(cLogTag + 'Register: chat dockable registration RAISED '
        + E.ClassName + ': ' + E.Message);
  end;

  DebugLn(cLogTag + 'Register: "' + cChatMenuCaption + '" submenu populated ('
    + IntToStr(LChatRoot.Count) + ' section(s)); PyTools sibling + MCP toggle '
    + 'registered = ' + BoolToStr(GMcpToggleItem <> nil, True));

  { Optional autostart (headless runtime proof + power-user opt-in). Guarded so a
    failure only logs; the IDE keeps loading regardless.

    Pro gate, mirroring the RAD Studio terminal host
    (Aefos.OTA.Terminal.UI.Wizard.pas:549-551): MCP is the paywall -- the free
    tier gets the product but NOT the server that lets the AI drive the IDE. The
    test is GateHard AND NOT Allows, exactly as there, so during beta
    (GATE_HARD_MODE off) the server still starts for everyone and only GA
    actually withholds it. }
  if GetEnvironmentVariable(cAutostartEnvVar) = '1' then
  begin
    DebugLn(cLogTag + 'Register: ' + cAutostartEnvVar
      + '=1 -> starting hosted MCP server');
    try
      AefosLazMcpHost.Start;
    except
      on E: Exception do
        DebugLn(cLogTag + 'Register: MCP autostart RAISED '
          + E.ClassName + ': ' + E.Message);
    end;
  end;
  _UpdateMcpToggleCaption;

  { Register the "Aefos AI" options group + executor-settings editor page
    (ideopteditorintf.pas:167). Runs at package LOAD, like the menu. }
  try
    RegisterAefosOptionsPage;
  except
    on E: Exception do
      DebugLn(cLogTag + 'Register: options-page registration RAISED '
        + E.ClassName + ': ' + E.Message);
  end;

  DebugLn(cLogTag + 'Register: end (menu + options page registered)');
end;

end.
