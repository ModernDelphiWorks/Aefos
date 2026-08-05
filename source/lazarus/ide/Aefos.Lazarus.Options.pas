unit Aefos.Lazarus.Options;

{ Aefos AI - Lazarus edition: the "Aefos AI" IDE options page (executor settings).

  A TAbstractIDEOptionsEditor frame (ideopteditorintf.pas:66, registered via
  RegisterIDEOptionsEditor :167) that reaches PARITY with the RAD Studio plugin's
  Tools > Options > Aefos > AI Chat page. It reads and writes the REAL, shared
  config core (Aefos.OTA.Chat.Core.Config) against the GLOBAL per-user root
  %APPDATA%\Aefos\.aefos\config.json - the SAME file the RAD Studio plugin uses,
  so one config genuinely serves both IDEs.

  Parity surface mirrored from the Delphi ChatFrame:
    * Executor kind (combo, drives the per-executor UI on change).
    * Executor path (+ Browse); relabelled "Agent CLI path (optional)" for the
      local runtime, exactly like the Delphi page.
    * Model as an editable DROPDOWN with Add / Remove, backed by the SHARED
      TExecutorModelStore (%APPDATA%\Aefos\models.json) - the same file the chat
      header selector and the RAD Studio page use, so the two IDEs never diverge.
    * Per-executor fields switched on executor change: an API Key field (+ a
      "Get a free API key" link) for the key-authenticated cloud CLIs, persisted
      via the shared TExecutorApiKeys; an Ollama base URL field for the local
      runtime, persisted to the shared TConfig.
    * A "Download the CLI" link and a "Log in" action, matching the Delphi page.
    * Test CLI: resolves the configured executable off the shared ladder
      (ResolveCLIBinary) and actually runs it (--version) on a worker thread,
      reporting OK/failure in a status label. For the local runtime the same
      button pings the Ollama endpoint (GET /api/tags), mirroring Delphi.
    * Test MCP: starts / confirms the Lazarus hosted MCP server
      (Aefos.Lazarus.McpHost) and reports reachability.

    * Total-run timeout (seconds; 0 = disabled) and the stdout output-filter
      policy - the two fields the port skipped before, now at depth parity with
      the Delphi ChatFrame. Both map onto the shared TConfig and are consumed by
      the shared CLIDispatcher / CommandExecutor.

  The one field this page still does not surface (the dev inspector flag) is
  preserved on Save by loading the current snapshot first and overwriting only
  the keys this page owns - the same read-modify-write discipline the Delphi
  binding uses, so the AI Flow / Terminal sibling pages are never clobbered.

  Reasoning-effort is deliberately NOT on this page: it is not on the Delphi
  Options page either - the effort pill lives in the chat header
  (TExecutorCapabilities.SupportsReasoningEffort). Matching Delphi, this page
  leaves effort to the header.

  Async discipline (the port's lifetime rule): FPC 3.2.2 has no closures, so the
  Test-CLI worker is a TThread carrier with a bound method, and both the worker
  and the Ollama endpoint-ping sink consult a ref-counted liveness token before
  touching this frame - a result that lands after the page closed is a safe
  no-op (the frame kills the token in Destroy). The IDE main thread is never
  blocked: the CLI runs on the worker and marshals its result back via
  Synchronize; the Ollama transport marshals on its own worker.

  Mode: delphi - IDE glue over the LCL, whose strings are UTF-8 AnsiString. The
  shared config/store/keys cores compile in delphiunicode (string = UnicodeString);
  every value crossing that boundary is converted explicitly via LazUTF8
  (UTF8ToUTF16 / UTF16ToUTF8), never through the platform ANSI codepage (the
  WorkspaceFacade/Register twin rule). All literals are ASCII, so the file needs
  no BOM.

  Controls are built in code (Setup) rather than streamed from a designed .lfm:
  the accompanying Aefos.Lazarus.Options.lfm carries ONLY the empty frame root
  (required so TCustomFrame.Create's InitInheritedComponent finds a resource -
  customframe.inc:215 raises EResNotFound otherwise), which keeps the single
  runtime-streamed line trivial and puts every child control on a deterministic
  code path. }

{$mode delphi}
{$H+}

interface

uses
  Classes,
  SysUtils,
  Controls,
  StdCtrls,
  ComCtrls,
  Dialogs,
  IDEOptEditorIntf,
  IDEOptionsIntf,
  Aefos.Provider.Types,
  Aefos.OTA.Chat.Core.Config.Types;

type
  { Ref-counted liveness flag shared between the frame and its async workers
    (the Test-CLI thread and the Ollama endpoint-ping sink). The frame holds one
    ref and kills it in Destroy; a worker holds another, so a callback that lands
    after the page closed sees IsAlive=False and never touches a freed control. }
  IAefosOptLive = interface
    ['{2C7B4E19-3A6D-4F58-9E0B-8D1C5A7F2B44}']
    function IsAlive: Boolean;
    procedure Kill;
  end;

  { The Aefos AI options page (executor settings) - Delphi parity. }
  TAefosOptionsFrame = class(TAbstractIDEOptionsEditor)
  private
    FBuilt: Boolean;
    { True while ReadSettings populates the controls, so the executor combo's
      OnChange does not stash a stale model under an uninitialised kind. }
    FLoading: Boolean;
    { The executor kind currently reflected in the model combo, so an executor
      switch can stash the model the user had for the kind being LEFT before
      recalling the kind being entered (per-executor model memory - Delphi BR). }
    FModelKind: TExecutorKind;
    { Liveness token for the async Test actions (see IAefosOptLive). }
    FLive: IAefosOptLive;
    { Kept alive while an Ollama endpoint ping is in flight. }
    FOllamaTransport: IInterface;

    { --- Executor group (Chat / Executor settings heading) ------------------ }
    FHeaderLabel: TLabel;
    FExecutorLabel: TLabel;
    FExecutorCombo: TComboBox;
    { Test CLI + its status now share the executor row (Delphi ChatFrame parity:
      ComboExecutor + ButtonTestConnection on the same line). }
    FTestCliButton: TButton;
    FTestStatus: TLabel;
    FPathLabel: TLabel;
    FPathEdit: TEdit;
    FBrowseButton: TButton;
    { Login now shares the path row with Browse (Delphi parity: EditExecutorPath +
      Browse + Login on one line). }
    FLoginButton: TButton;
    { The official download page link, under the path row. }
    FDownloadLink: TLabel;
    FModelLabel: TLabel;
    FModelCombo: TComboBox;
    FAddModelButton: TButton;
    FRemoveModelButton: TButton;
    { Depth parity with the RAD Studio ChatFrame (the two fields the port skipped
      before): the total-run timeout (seconds; 0 = disabled) and the stdout
      output-filter policy. Both map straight onto the shared TConfig and are
      consumed by the shared CLIDispatcher / CommandExecutor, so they apply on the
      external-CLI dispatch path exactly as on the RAD side. }
    FTimeoutLabel: TLabel;
    FTimeoutEdit: TEdit;
    FOutputFilterLabel: TLabel;
    FOutputFilterCombo: TComboBox;
    { --- Provider settings PageControl (Delphi PageProviders parity) --------- }
    { A tabbed provider band: the Gemini tab carries the API key (+ the "Get a
      free API key" link) for the key-authenticated cloud CLIs; the Ollama tab
      carries the local-runtime endpoint URL. Both tabs are always present; the
      executor switch brings the matching tab to front (_ApplyExecutorKindUi),
      exactly like the RAD Studio ChatFrame. }
    FPageProviders: TPageControl;
    FTabGemini: TTabSheet;
    FTabOllama: TTabSheet;
    FApiKeyLabel: TLabel;
    FApiKeyEdit: TEdit;
    FGetKeyLink: TLabel;
    FOllamaUrlLabel: TLabel;
    FOllamaUrlEdit: TEdit;
    { --- MCP settings group (Delphi "MCP settings" section parity) ----------- }
    { Boxed group: the audit-log path (read-only, the SHARED %APPDATA%\Aefos\logs
      file the RAD plugin also writes) + the hosted MCP server info (read-only) +
      Test MCP with its status. }
    FMcpGroup: TGroupBox;
    FAuditLabel: TLabel;
    FAuditEdit: TEdit;
    FServerLabel: TLabel;
    FServerEdit: TEdit;
    FTestMcpButton: TButton;
    FMcpStatus: TLabel;
    { --- Requirements block (Delphi Requirements section parity) ------------- }
    FReqHeading: TLabel;
    FReqLabel: TLabel;

    { The GLOBAL config root the shared core resolves against - %APPDATA%\Aefos.
      Returned as UnicodeString to match the core's delphiunicode signature. }
    function _ResolveConfigRoot: UnicodeString;
    { A fresh config service bound to the global root (mirrors the OTA plugin's
      _InitConfig composition). }
    function _BuildConfigService: IConfig;
    { The currently selected executor kind (ekClaude when the combo is empty). }
    function _SelectedKind: TExecutorKind;
    { The CLI path a Test/Login should use: the typed path when set, else the
      binary auto-resolved off the shared ladder for the selected executor. UTF-8. }
    function _EffectiveCliPath(const AKind: TExecutorKind): string;
    { Populate the model dropdown from the shared store for AKind, preserving a
      value the user has typed (Delphi BR-3). }
    procedure _PopulateModels(const AKind: TExecutorKind);
    { Per-kind UI: relabel the path row for the local runtime, and show the API
      key band vs the Ollama URL band, plus the login/download affordances. }
    procedure _ApplyExecutorKindUi(const AKind: TExecutorKind);
    { Reflect the CLI login state on the Log-in button: default caption for the
      kind, then (Codex/Copilot only, which expose a real `login status`
      subcommand) probe `<cli> login status` async and flip to "Logged in" when
      authenticated. Mirrors the Delphi ChatFrame._RefreshLoginState. }
    procedure _RefreshLoginState(const AKind: TExecutorKind);
    { Pings the Ollama endpoint (GET /api/tags) on the transport's own worker. }
    procedure _TestOllamaEndpoint;

    procedure _BrowseClick(ASender: TObject);
    procedure _ExecutorChange(ASender: TObject);
    procedure _AddModelClick(ASender: TObject);
    procedure _RemoveModelClick(ASender: TObject);
    procedure _ApiKeyExit(ASender: TObject);
    procedure _GetKeyClick(ASender: TObject);
    procedure _DownloadClick(ASender: TObject);
    procedure _LoginClick(ASender: TObject);
    procedure _TestCliClick(ASender: TObject);
    procedure _TestMcpClick(ASender: TObject);
    { Main-thread result sinks for the async workers (token-guarded by callers). }
    procedure _OnCliProbeResult(const AMessage: string);
    procedure _OnOllamaTested(const AModels: TArray<UnicodeString>;
      const AError: UnicodeString);
    { Main-thread sink for the login probe (token-guarded by the caller): flips the
      button to "Logged in" only while the frame is alive AND the probed kind is
      still the one selected (a stale answer must not mislabel another CLI). }
    procedure _OnLoginProbed(const AKind: TExecutorKind; const ALogged: Boolean);
  public
    constructor Create(TheOwner: TComponent); override;
    destructor Destroy; override;
    function GetTitle: String; override;
    procedure Setup(ADialog: TAbstractOptionsEditorDialog); override;
    procedure ReadSettings(AOptions: TAbstractIDEOptions); override;
    procedure WriteSettings(AOptions: TAbstractIDEOptions); override;
    class function SupportedOptionsClass: TAbstractIDEOptionsClass; override;
  end;

{ Registers the "Aefos AI" options group + the executor-settings editor. Called
  once from the package Register at IDE load. }
procedure RegisterAefosOptionsPage;

implementation

uses
  Graphics,
  LCLType,
  LCLIntf,
  Process,
  UTF8Process,
  LazUTF8,
  LazLoggerBase,
  Aefos.Provider.Kinds,
  Aefos.Provider.Registry,
  Aefos.Provider.Ollama,
  Aefos.Executor.Models,
  Aefos.OTA.Chat.UI.Options.Binding,
  Aefos.OTA.Chat.Core.CLIBinaryResolver,
  Aefos.OTA.Chat.Core.Dispatcher.Types,   // TOutputFilterPolicy, ofpStrip/ofpRaw
  Aefos.MCP.AuditLog,                      // TMCPAuditLog.LogFilePath (shared path)
  // The shared cross-compiler license gate: the "(Pro)" tag on gated providers
  // and the Pro gate on MCP auto-setup, mirroring the RAD Studio options frame.
  // {$mode delphiunicode}, so everything it returns crosses through UTF16ToUTF8.
  Aefos.License.Gate,
  Aefos.Lazarus.McpHost,
  Aefos.Lazarus.OptionsGroup,             // TAefosIDEOptions (shared group node)
  Aefos.Lazarus.Options.Flow,             // sibling editor pages (same group)
  Aefos.Lazarus.Options.Terminal,
  Aefos.OTA.Chat.Core.Config;

const
  { Base index for the Aefos AI options group. GetFreeIDEOptionsGroupIndex finds
    the first free slot at/after this, so "Aefos AI" lands as its own top-level
    node without colliding.

    WHY 450 AND NOT SOMETHING SAFELY HUGE. The tree is ordered by this number, and
    the IDE's own groups are (buildintf\ideoptionsintf.pas:156-213):

        Environment 100 · Editor 200 · Codetools 300 · CodeExplorer 350
        Debugger 400 · [450 = us] · Help 500

    The first value here was 1000 - "well past the built-ins", which sounds safe
    and reads badly: Help is last by convention in every application, so sitting
    BELOW it made the product look like an appendix bolted onto the IDE rather
    than one of its features. 450 is the last FEATURE slot, immediately before
    Help, which is where a first-class group belongs.

    Still collision-free: the built-ins occupy 100/200/300/350/400/500 and nothing
    sits at 450, while the project- and package-scoped groups live at 100100+ and
    200100+ (:217-256) and are shown in different dialogs entirely. And the call is
    GetFreeIDEOptionsGroupIndex, not a bare literal - if 450 ever were taken, the
    next free slot is used instead of overwriting someone. }
  cAefosOptionsGroupBase = 450;

  { The editor-page index WITHIN the Aefos AI group. Our group holds exactly one
    editor, so this is a fixed literal - the standard Lazarus pattern.

    It MUST NOT be computed with GetFreeIDEOptionsIndex on a freshly-registered
    group: in Lazarus 2.2.6, RegisterIDEOptionsGroup leaves the group's Items
    list NIL (ideopteditorintf.pas:612), and GetFreeIDEOptionsIndex dereferences
    Rec^.Items WITHOUT a nil-check (:242) - so calling it before the first editor
    exists is a nil-dereference => EAccessViolation at IDE startup. }
  cAefosOptionsPageIndex = 1;

  { Sibling editor pages under the same "Aefos AI" group: "AI Flow" (agent
    behaviour / permissions) and "Terminal" (hosted MCP server). Fixed literals
    for the SAME reason as the Chat page above (never GetFreeIDEOptionsIndex).
    The Chat editor registers FIRST - creating the group's Items list - so these
    two safely add onto the existing list at their own indices. }
  cAefosFlowPageIndex = 2;
  cAefosTerminalPageIndex = 3;

  { Google AI Studio - where the user mints a free key for the key-authenticated
    cloud CLI. Vendor-neutral label; Aefos injects the key as the provider's env
    var so no system env var or IDE restart is needed. }
  cGetKeyUrl = 'https://aistudio.google.com/apikey';

  { Layout grid (px). Kept as constants so the two-column vertical rhythm reads at
    a glance: cXLabel is the left label column, cXInput the input column. Trailing
    controls (Browse/Login, the output-filter combo, the provider PageControl and
    the MCP group) end at cRightEdge and are anchored akRight, so on a narrower
    hosted panel they pull IN with the frame instead of clipping. }
  cXLabel   = 12;
  cXInput   = 132;
  { The proven right boundary shared with the sibling AI Flow page (the owner
    confirmed it fits the hosted options panel with no horizontal scrollbar):
    every wide edit / container ends here and is anchored akRight, so on a
    narrower hosted panel it pulls in with the frame instead of clipping. The
    frame .lfm is 560 wide (wider than the ~520 runtime viewport) precisely so
    akRight controls pull INWARD (the safe direction) when the frame is aligned
    alClient into the options ScrollBox. }
  cRightEdge = 520;

var
  { The registered group index (also the editor's group), captured at
    registration so nothing hard-codes it. The group container class + its
    singleton now live in Aefos.Lazarus.OptionsGroup (extracted to keep the
    sibling pages dependency-acyclic for the IDE static-link rebuild). }
  GAefosOptionsGroupIndex: Integer = 0;

type
  { Trivial ref-counted IAefosOptLive. The frame holds one ref; each async worker
    holds another, so a worker outlives a frame freed mid-run. }
  TAefosOptLive = class(TInterfacedObject, IAefosOptLive)
  private
    FAlive: Boolean;
  public
    constructor Create;
    function IsAlive: Boolean;
    procedure Kill;
  end;

  { Runs "<cli> --version" on a private worker thread and marshals a one-line
    verdict back to the frame. Mirrors the Delphi ButtonTestConnectionClick probe
    (TProcessRunner.Run + --version), retargeted at the LCL TProcessUTF8 seam so
    a non-ASCII install path survives (UTF-8). Never blocks the IDE main thread;
    the result is delivered via Synchronize and gated on the liveness token. }
  TAefosCliProbe = class(TThread)
  private
    FOwner: TAefosOptionsFrame;
    FLive: IAefosOptLive;
    FExe: string;   // UTF-8
    FMsg: string;   // UTF-8 verdict
    procedure _Deliver;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TAefosOptionsFrame; const AExe: string;
      const ALive: IAefosOptLive);
  end;

  { Runs "<cli> login status" on a private worker thread and marshals a
    logged-in / not verdict back to the frame. Mirrors the Delphi ChatFrame
    _RefreshLoginState probe (TProcessRunner.Run 'login status' + the
    "logged in" / not-"not logged in" parse), retargeted at the LCL TProcessUTF8
    seam. Never blocks the IDE main thread; the result is delivered via
    Synchronize and gated on the liveness token. Only spawned for the executors
    that expose a real `login status` subcommand (Codex/Copilot) - never for the
    CLIs that would parse a bare "login status" as a prompt turn. }
  TAefosLoginProbe = class(TThread)
  private
    FOwner: TAefosOptionsFrame;
    FLive: IAefosOptLive;
    FExe: string;              // UTF-8
    FKind: TExecutorKind;
    FLogged: Boolean;
    procedure _Deliver;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TAefosOptionsFrame; const AExe: string;
      const AKind: TExecutorKind; const ALive: IAefosOptLive);
  end;

  { The models sink handed to IOllamaTransport.FetchModels. The transport stores
    a bare "of object" pointer and does NOT refcount it, so a /api/tags reply that
    lands after the frame is freed would be a use-after-free. It self-holds via
    FSelf, consults FLive before touching the owner, and releases FSelf as its
    last instruction. FetchModels fires exactly once, so every delivery is
    terminal (the C1-class discipline mirrored from Aefos.Lazarus.ChatController). }
  TAefosOptModelsSink = class(TInterfacedObject)
  private
    FOwner: TAefosOptionsFrame;
    FLive: IAefosOptLive;
    FSelf: IInterface;
  public
    constructor Create(AOwner: TAefosOptionsFrame; const ALive: IAefosOptLive);
    procedure Deliver(const AModels: TArray<UnicodeString>;
      const AError: UnicodeString);
  end;

{ TAefosOptLive }

constructor TAefosOptLive.Create;
begin
  inherited Create;
  FAlive := True;
end;

function TAefosOptLive.IsAlive: Boolean;
begin
  Result := FAlive;
end;

procedure TAefosOptLive.Kill;
begin
  FAlive := False;
end;

{ TAefosCliProbe }

constructor TAefosCliProbe.Create(AOwner: TAefosOptionsFrame; const AExe: string;
  const ALive: IAefosOptLive);
begin
  FOwner := AOwner;
  FExe := AExe;
  FLive := ALive;
  FreeOnTerminate := True;
  inherited Create(False);   // start at once
end;

procedure TAefosCliProbe.Execute;
var
  LProc: TProcessUTF8;
  LStream: TMemoryStream;
  LBuf: array[0..4095] of Byte;
  LAvail, LN: LongInt;
  LDeadline: QWord;
  LTimedOut, LSpawnOk: Boolean;
  LExit: Integer;
  LBytes: TBytes;
  LOut: string;
  LSp: Integer;
  LMethod: TThreadMethod;
begin
  LSpawnOk := False;
  LTimedOut := False;
  LExit := 0;
  LOut := '';
  LProc := TProcessUTF8.Create(nil);
  LStream := TMemoryStream.Create;
  try
    try
      LProc.Executable := FExe;
      LProc.Parameters.Add('--version');
      // Merge stderr into stdout so a CLI that prints its banner to stderr still
      // reads as connected; no console window; capture via pipes.
      LProc.Options := [poUsePipes, poNoConsole, poStderrToOutPut];
      LProc.Execute;
      LSpawnOk := True;
      LDeadline := GetTickCount64 + 8000;
      while True do
      begin
        while LProc.Output.NumBytesAvailable > 0 do
        begin
          LAvail := LProc.Output.NumBytesAvailable;
          if LAvail > SizeOf(LBuf) then
            LAvail := SizeOf(LBuf);
          LN := LProc.Output.Read(LBuf[0], LAvail);
          if LN > 0 then
            LStream.Write(LBuf[0], LN)
          else
            Break;
        end;
        if not LProc.Running then
          Break;
        if GetTickCount64 > LDeadline then
        begin
          LTimedOut := True;
          try
            LProc.Terminate(1);
          except
            // best effort
          end;
          Break;
        end;
        Sleep(20);
      end;
      // Final drain to catch the tail after exit / kill.
      while LProc.Output.NumBytesAvailable > 0 do
      begin
        LAvail := LProc.Output.NumBytesAvailable;
        if LAvail > SizeOf(LBuf) then
          LAvail := SizeOf(LBuf);
        LN := LProc.Output.Read(LBuf[0], LAvail);
        if LN > 0 then
          LStream.Write(LBuf[0], LN)
        else
          Break;
      end;
      if not LTimedOut then
        LExit := LProc.ExitStatus;
    except
      // Execute raised => the binary could not be started (bad path / spawn fail).
      LSpawnOk := False;
    end;
    if LStream.Size > 0 then
    begin
      SetLength(LBytes, LStream.Size);
      LStream.Position := 0;
      LStream.ReadBuffer(LBytes[0], LStream.Size);
      LOut := Trim(UTF16ToUTF8(TEncoding.UTF8.GetString(LBytes)));
    end;
  finally
    LStream.Free;
    LProc.Free;
  end;

  if not LSpawnOk then
    FMsg := 'Failed to start the CLI (check the Executable path).'
  else if LTimedOut then
    FMsg := 'Failed (timeout)'
  else if LExit = 0 then
  begin
    // First token = the version number (the CLI usually prints "x.y.z ...").
    LSp := Pos(' ', LOut);
    if LSp > 1 then
      LOut := Copy(LOut, 1, LSp - 1);
    if LOut <> '' then
      FMsg := 'Connected ' + LOut
    else
      FMsg := 'Connected';
  end
  else
    FMsg := Format('Failed (exit %d)', [LExit]);

  LMethod := _Deliver;
  Synchronize(LMethod);
end;

procedure TAefosCliProbe._Deliver;
begin
  // Runs on the IDE main thread - the same thread that runs the frame's Destroy,
  // so this either completes before the frame dies or sees a dead token after.
  if (FLive <> nil) and FLive.IsAlive and (FOwner <> nil) then
    FOwner._OnCliProbeResult(FMsg);
end;

{ TAefosLoginProbe }

constructor TAefosLoginProbe.Create(AOwner: TAefosOptionsFrame; const AExe: string;
  const AKind: TExecutorKind; const ALive: IAefosOptLive);
begin
  FOwner := AOwner;
  FExe := AExe;
  FKind := AKind;
  FLive := ALive;
  FLogged := False;
  FreeOnTerminate := True;
  inherited Create(False);   // start at once
end;

procedure TAefosLoginProbe.Execute;
var
  LProc: TProcessUTF8;
  LStream: TMemoryStream;
  LBuf: array[0..4095] of Byte;
  LAvail, LN: LongInt;
  LDeadline: QWord;
  LTimedOut, LSpawnOk: Boolean;
  LExit: Integer;
  LBytes: TBytes;
  LLow: string;
  LMethod: TThreadMethod;
begin
  LSpawnOk := False;
  LTimedOut := False;
  LExit := 0;
  LLow := '';
  LProc := TProcessUTF8.Create(nil);
  LStream := TMemoryStream.Create;
  try
    try
      LProc.Executable := FExe;
      // `login status` = two positional args; merge stderr so a banner printed
      // there still reads; no console window.
      LProc.Parameters.Add('login');
      LProc.Parameters.Add('status');
      LProc.Options := [poUsePipes, poNoConsole, poStderrToOutPut];
      LProc.Execute;
      LSpawnOk := True;
      LDeadline := GetTickCount64 + 8000;
      while True do
      begin
        while LProc.Output.NumBytesAvailable > 0 do
        begin
          LAvail := LProc.Output.NumBytesAvailable;
          if LAvail > SizeOf(LBuf) then
            LAvail := SizeOf(LBuf);
          LN := LProc.Output.Read(LBuf[0], LAvail);
          if LN > 0 then
            LStream.Write(LBuf[0], LN)
          else
            Break;
        end;
        if not LProc.Running then
          Break;
        if GetTickCount64 > LDeadline then
        begin
          LTimedOut := True;
          try
            LProc.Terminate(1);
          except
            // best effort
          end;
          Break;
        end;
        Sleep(20);
      end;
      // Final drain to catch the tail after exit / kill.
      while LProc.Output.NumBytesAvailable > 0 do
      begin
        LAvail := LProc.Output.NumBytesAvailable;
        if LAvail > SizeOf(LBuf) then
          LAvail := SizeOf(LBuf);
        LN := LProc.Output.Read(LBuf[0], LAvail);
        if LN > 0 then
          LStream.Write(LBuf[0], LN)
        else
          Break;
      end;
      if not LTimedOut then
        LExit := LProc.ExitStatus;
    except
      // Execute raised => the binary could not be started (bad path / spawn fail).
      LSpawnOk := False;
    end;
    if LStream.Size > 0 then
    begin
      SetLength(LBytes, LStream.Size);
      LStream.Position := 0;
      LStream.ReadBuffer(LBytes[0], LStream.Size);
      LLow := LowerCase(UTF16ToUTF8(TEncoding.UTF8.GetString(LBytes)));
    end;
  finally
    LStream.Free;
    LProc.Free;
  end;

  // Logged in = clean exit AND the banner says "logged in" but NOT "not logged
  // in" (which contains "logged in" as a substring). Mirrors the Delphi parse.
  FLogged := LSpawnOk and (not LTimedOut) and (LExit = 0) and
    (Pos('logged in', LLow) > 0) and (Pos('not logged in', LLow) = 0);

  LMethod := _Deliver;
  Synchronize(LMethod);
end;

procedure TAefosLoginProbe._Deliver;
begin
  // IDE main thread (same thread as Destroy): completes before the frame dies or
  // sees a dead token after.
  if (FLive <> nil) and FLive.IsAlive and (FOwner <> nil) then
    FOwner._OnLoginProbed(FKind, FLogged);
end;

{ TAefosOptModelsSink }

constructor TAefosOptModelsSink.Create(AOwner: TAefosOptionsFrame;
  const ALive: IAefosOptLive);
begin
  inherited Create;
  FOwner := AOwner;
  FLive := ALive;
  FSelf := Self;   // survive independent of the owner until the reply lands
end;

procedure TAefosOptModelsSink.Deliver(const AModels: TArray<UnicodeString>;
  const AError: UnicodeString);
begin
  // MAIN thread (the transport marshals via Synchronize on FPC). Gate on the
  // token: after the frame is torn down we must never touch FOwner.
  try
    if (FLive <> nil) and FLive.IsAlive and (FOwner <> nil) then
      FOwner._OnOllamaTested(AModels, AError);
  except
    // Never raise across the transport's marshalled call.
  end;
  FSelf := nil;   // MUST be the last statement -- may free Self here.
end;

{ TAefosOptionsFrame }

constructor TAefosOptionsFrame.Create(TheOwner: TComponent);
begin
  inherited Create(TheOwner);
  FLive := TAefosOptLive.Create;
  FModelKind := ekClaude;
end;

destructor TAefosOptionsFrame.Destroy;
begin
  // Any in-flight Test worker's marshalled result becomes a no-op from here on.
  if Assigned(FLive) then
    FLive.Kill;
  FOllamaTransport := nil;
  inherited Destroy;
end;

function TAefosOptionsFrame.GetTitle: String;
begin
  // Mirrors the RAD Studio page (Tools > Options > Aefos > AI Chat).
  Result := 'AI Chat';
end;

function TAefosOptionsFrame._ResolveConfigRoot: UnicodeString;
var
  LAppData: string;
begin
  // %APPDATA%\Aefos - the GLOBAL, IDE-wide, per-Windows-profile root. Identical
  // to the RAD Studio plugin's _ResolveGlobalConfigRoot, so the file the core
  // reads/writes is exactly %APPDATA%\Aefos\.aefos\config.json for both IDEs.
  LAppData := GetEnvironmentVariable('APPDATA');
  Result := UTF8ToUTF16(LAppData + '\Aefos');
end;

function TAefosOptionsFrame._BuildConfigService: IConfig;
var
  LResolver: TConfigRootResolver;
begin
  // Assign the method to a typed variable first so it binds as a method pointer
  // (of object), never a call - the FPC delphi-mode idiom for the resolver seam.
  LResolver := Self._ResolveConfigRoot;
  Result := TConfigService.Create(LResolver);
end;

function TAefosOptionsFrame._SelectedKind: TExecutorKind;
begin
  Result := ekClaude;
  if FExecutorCombo.ItemIndex >= 0 then
    Result := TExecutorKind(FExecutorCombo.ItemIndex);
end;

function TAefosOptionsFrame._EffectiveCliPath(const AKind: TExecutorKind): string;
var
  LBinary: UnicodeString;
begin
  // The typed path wins verbatim (mirrors the Delphi _EffectiveCliPath); only
  // when it is blank do we auto-resolve off the shared ladder (AEFOS_CLI -> PATH
  // -> the installer-bundled bin) using the executor's own default binary name.
  Result := Trim(FPathEdit.Text);
  if Result <> '' then
    Exit;
  LBinary := TProviderRegistry.ResolveExecutorProfile(AKind).BinaryName;
  Result := UTF16ToUTF8(ResolveCLIBinary('', LBinary));
end;

procedure TAefosOptionsFrame._PopulateModels(const AKind: TExecutorKind);
var
  LModels: TArray<UnicodeString>;
  LTyped: string;
  LFor: Integer;
begin
  // Preserve a value the user typed across an executor switch (Delphi BR-3).
  LTyped := FModelCombo.Text;
  LModels := TExecutorModelStore.ModelsForKind(AKind);
  FModelCombo.Items.BeginUpdate;
  try
    FModelCombo.Items.Clear;
    for LFor := 0 to High(LModels) do
      FModelCombo.Items.Add(UTF16ToUTF8(LModels[LFor]));
  finally
    FModelCombo.Items.EndUpdate;
  end;
  FModelCombo.Text := LTyped;
end;

procedure TAefosOptionsFrame._ApplyExecutorKindUi(const AKind: TExecutorKind);
var
  LLocal: Boolean;
begin
  LLocal := AKind = ekOllama;
  // The local runtime drives OUR bundled agent CLI, so the path is an OPTIONAL
  // override (blank = the bundled/auto-resolved CLI) - relabel + hint it exactly
  // like the Delphi page; the external CLIs expect the path.
  if LLocal then
  begin
    FPathLabel.Caption := 'Agent CLI path (optional):';
    FPathEdit.TextHint := 'blank = bundled Aefos agent CLI';
  end
  else
  begin
    FPathLabel.Caption := 'Executable path:';
    FPathEdit.TextHint := '';
  end;
  // Provider tabs stay BOTH present (Delphi PageProviders parity); the executor
  // switch just brings the matching tab to front: the local runtime -> Ollama
  // (endpoint URL), Gemini -> Gemini (API key). For the login-based CLIs
  // (Claude/Codex/Copilot) the Gemini tab is fronted (its API-key field is
  // simply empty for them - harmless, and the "get a key" link below is hidden).
  if LLocal then
    FPageProviders.ActivePage := FTabOllama
  else
    FPageProviders.ActivePage := FTabGemini;
  // The "get a key" link only makes sense where the executor authenticates by
  // key (Gemini today - ApiKeyEnvVarFor names an env var); the login-based CLIs
  // have no key page. Vendor-neutral label.
  FGetKeyLink.Visible := (not LLocal) and
    (TExecutorApiKeys.ApiKeyEnvVarFor(AKind) <> '');
  // Login is for the external CLIs (the local runtime has no login); the
  // download link targets the SELECTED executor's official page when it has one.
  FLoginButton.Visible := not LLocal;
  FDownloadLink.Visible := TExecutorDownloads.DownloadUrlForKind(AKind) <> '';
  // The Test button pings the endpoint (not a CLI) for the local kind.
  if LLocal then
    FTestCliButton.Caption := 'Test'
  else
    FTestCliButton.Caption := 'Test CLI';
  // A status line from the previous kind would mislead - reset both.
  FTestStatus.Caption := '';
  FMcpStatus.Caption := '';
  // Reflect the CLI login state on the Log-in button for the entered kind (resets
  // to the default caption first, then probes Codex/Copilot async). Covers both
  // page-open (ReadSettings calls this) and executor switch (_ExecutorChange).
  _RefreshLoginState(AKind);
end;

procedure TAefosOptionsFrame._RefreshLoginState(const AKind: TExecutorKind);
var
  LPath: string;
begin
  if FLoginButton = nil then
    Exit;
  // Default caption for every kind; only a confirmed probe flips it to "Logged
  // in". Keeps the port's existing "Log in" wording (Delphi uses "Login").
  FLoginButton.Caption := 'Log in';
  // Codex/Copilot ONLY expose a real `login status` subcommand (exit 0 + "Logged
  // in ..."). For Claude/Gemini a bare `login status` would be parsed as a
  // POSITIONAL PROMPT and could dispatch an actual AI turn - never probe those.
  // The local runtime (Ollama) has no login and hides the button entirely.
  if not (AKind in [ekCodex, ekCopilot]) then
    Exit;
  LPath := _EffectiveCliPath(AKind);
  if LPath = '' then
    Exit;
  // Off the IDE main thread (a blocking `login status` would freeze Options). The
  // worker flips the caption via a token-guarded Synchronize and self-frees
  // (FreeOnTerminate), owning its own lifetime.
  TAefosLoginProbe.Create(Self, LPath, AKind, FLive);
end;

procedure TAefosOptionsFrame._OnLoginProbed(const AKind: TExecutorKind;
  const ALogged: Boolean);
begin
  // Only apply while this kind is STILL the selected one (the user may have
  // switched executors while the probe ran; a stale answer must not mislabel the
  // other CLI's button). The button stays enabled either way, so a re-login is
  // always one click away.
  if ALogged and (FLoginButton <> nil) and (_SelectedKind = AKind) then
    FLoginButton.Caption := 'Logged in';
end;

procedure TAefosOptionsFrame.Setup(ADialog: TAbstractOptionsEditorDialog);
var
  LKind: TExecutorKind;
  LItemText: string;
begin
  if FBuilt then
    Exit;
  FBuilt := True;

  // === Chat / Executor settings ============================================
  FHeaderLabel := TLabel.Create(Self);
  FHeaderLabel.Parent := Self;
  FHeaderLabel.Left := cXLabel;
  FHeaderLabel.Top := 8;
  FHeaderLabel.Font.Style := [fsBold];
  FHeaderLabel.Caption := 'Chat / Executor settings';

  // --- Executor row: combo + Test CLI + status (one line, Delphi parity) -----
  FExecutorLabel := TLabel.Create(Self);
  FExecutorLabel.Parent := Self;
  FExecutorLabel.Left := cXLabel;
  FExecutorLabel.Top := 36;
  FExecutorLabel.Caption := 'Executor:';

  FExecutorCombo := TComboBox.Create(Self);
  FExecutorCombo.Parent := Self;
  FExecutorCombo.Left := cXInput;
  FExecutorCombo.Top := 32;
  FExecutorCombo.Width := 170;
  FExecutorCombo.Style := csDropDownList;
  // Populated in TExecutorKind order, so ItemIndex = Ord(kind).
  //
  // Quiet Pro lock, mirroring the RAD Studio frame
  // (Aefos.OTA.Chat.UI.Options.ChatFrame.pas:649): a provider outside the free
  // tier carries a "(Pro)" tag so the wall is self-evident in the selector - no
  // nag, no disabled item. Provider gating is the PRIMARY paywall, and the label
  // is informational during beta; GATE_HARD_MODE is what makes it bite at GA.
  // Item order stays ordinal, so ItemIndex <-> TExecutorKind still maps 1:1 and
  // every ItemIndex-based read in this frame keeps working untouched.
  for LKind := Low(TExecutorKind) to High(TExecutorKind) do
  begin
    LItemText := UTF16ToUTF8(TExecutorKinds.ExecutorKindDisplayName(LKind));
    if not TLicenseGate.AllowsProvider(
             TExecutorKinds.ExecutorKindToString(LKind)) then
      LItemText := LItemText + '   (Pro)';
    FExecutorCombo.Items.Add(LItemText);
  end;
  FExecutorCombo.OnChange := Self._ExecutorChange;

  FTestCliButton := TButton.Create(Self);
  FTestCliButton.Parent := Self;
  FTestCliButton.Left := cXInput + 178;    // just right of the executor combo
  FTestCliButton.Top := 31;
  FTestCliButton.Width := 86;
  FTestCliButton.Caption := 'Test CLI';
  FTestCliButton.OnClick := Self._TestCliClick;

  FTestStatus := TLabel.Create(Self);
  FTestStatus.Parent := Self;
  FTestStatus.Left := cXInput + 272;
  FTestStatus.Top := 36;
  // Autosize label: grows rightward from here (same as the Delphi status label).
  FTestStatus.Caption := '';

  // --- Path row: edit + Browse + Login (one line, Delphi parity) -------------
  FPathLabel := TLabel.Create(Self);
  FPathLabel.Parent := Self;
  FPathLabel.Left := cXLabel;
  FPathLabel.Top := 66;
  FPathLabel.Caption := 'Executable path:';

  FPathEdit := TEdit.Create(Self);
  FPathEdit.Parent := Self;
  FPathEdit.Left := cXInput;
  FPathEdit.Top := 62;
  FPathEdit.Width := 218;
  // Stretch with the panel so the two trailing buttons always stay inside the
  // right border (no clip / no horizontal scrollbar).
  FPathEdit.Anchors := [akLeft, akTop, akRight];

  FLoginButton := TButton.Create(Self);
  FLoginButton.Parent := Self;
  FLoginButton.Left := cRightEdge - 84;    // pinned to the right boundary
  FLoginButton.Top := 61;
  FLoginButton.Width := 84;
  FLoginButton.Caption := 'Log in';
  FLoginButton.Anchors := [akTop, akRight];
  FLoginButton.OnClick := Self._LoginClick;

  FBrowseButton := TButton.Create(Self);
  FBrowseButton.Parent := Self;
  FBrowseButton.Left := cRightEdge - 84 - 6 - 72;   // left of Login
  FBrowseButton.Top := 61;
  FBrowseButton.Width := 72;
  FBrowseButton.Caption := 'Browse...';
  FBrowseButton.Anchors := [akTop, akRight];
  FBrowseButton.OnClick := Self._BrowseClick;

  // --- Download-the-CLI link (under the path row) ----------------------------
  FDownloadLink := TLabel.Create(Self);
  FDownloadLink.Parent := Self;
  FDownloadLink.Left := cXInput;
  FDownloadLink.Top := 90;
  FDownloadLink.Caption := 'Download the CLI -> official page';
  FDownloadLink.Font.Color := clBlue;
  FDownloadLink.Font.Style := [fsUnderline];
  FDownloadLink.Cursor := crHandPoint;
  FDownloadLink.OnClick := Self._DownloadClick;

  // --- Model row: combo + [+] [-] --------------------------------------------
  FModelLabel := TLabel.Create(Self);
  FModelLabel.Parent := Self;
  FModelLabel.Left := cXLabel;
  FModelLabel.Top := 118;
  FModelLabel.Caption := 'Model:';

  FModelCombo := TComboBox.Create(Self);
  FModelCombo.Parent := Self;
  FModelCombo.Left := cXInput;
  FModelCombo.Top := 114;
  FModelCombo.Width := 180;
  // Editable: an off-list or future model is still accepted and saved verbatim.
  FModelCombo.Style := csDropDown;

  FAddModelButton := TButton.Create(Self);
  FAddModelButton.Parent := Self;
  FAddModelButton.Left := cXInput + 184;
  FAddModelButton.Top := 113;
  FAddModelButton.Width := 30;
  FAddModelButton.Hint := 'Add the typed model to the list';
  FAddModelButton.ShowHint := True;
  FAddModelButton.Caption := '+';
  FAddModelButton.OnClick := Self._AddModelClick;

  FRemoveModelButton := TButton.Create(Self);
  FRemoveModelButton.Parent := Self;
  FRemoveModelButton.Left := cXInput + 216;
  FRemoveModelButton.Top := 113;
  FRemoveModelButton.Width := 30;
  FRemoveModelButton.Hint := 'Remove the typed/selected model from the list';
  FRemoveModelButton.ShowHint := True;
  FRemoveModelButton.Caption := '-';
  FRemoveModelButton.OnClick := Self._RemoveModelClick;

  // --- Depth parity: total-run timeout + output filter (one line) ------------
  FTimeoutLabel := TLabel.Create(Self);
  FTimeoutLabel.Parent := Self;
  FTimeoutLabel.Left := cXLabel;
  FTimeoutLabel.Top := 150;
  FTimeoutLabel.Caption := 'Run timeout (seconds):';

  FTimeoutEdit := TEdit.Create(Self);
  FTimeoutEdit.Parent := Self;
  FTimeoutEdit.Left := cXInput;
  FTimeoutEdit.Top := 146;
  FTimeoutEdit.Width := 70;
  FTimeoutEdit.TextHint := '0 = no timeout';

  FOutputFilterLabel := TLabel.Create(Self);
  FOutputFilterLabel.Parent := Self;
  FOutputFilterLabel.Left := cXInput + 86;
  FOutputFilterLabel.Top := 150;
  FOutputFilterLabel.Caption := 'Output filter:';

  FOutputFilterCombo := TComboBox.Create(Self);
  FOutputFilterCombo.Parent := Self;
  FOutputFilterCombo.Left := cXInput + 172;
  FOutputFilterCombo.Top := 146;
  FOutputFilterCombo.Width := cRightEdge - (cXInput + 172);
  FOutputFilterCombo.Anchors := [akLeft, akTop, akRight];
  FOutputFilterCombo.Style := csDropDownList;
  // Index order MUST match TOutputFilterPolicy (ofpStrip=0, ofpRaw=1) so
  // ItemIndex maps 1:1 to/from the enum via Ord (RAD ChatFrame parity).
  FOutputFilterCombo.Items.Add('Strip ANSI escapes (default)');
  FOutputFilterCombo.Items.Add('Raw (preserve escapes)');

  // === Provider settings (Gemini | Ollama tabs) =============================
  FPageProviders := TPageControl.Create(Self);
  FPageProviders.Parent := Self;
  FPageProviders.Left := cXLabel;
  FPageProviders.Top := 176;
  FPageProviders.Width := cRightEdge - cXLabel;
  // Tall enough for the Gemini tab's three rows (label + key edit + get-key link)
  // below the tab strip (~28px), while keeping the page short enough that the
  // whole frame fits the ~455px options viewport without clipping.
  FPageProviders.Height := 96;
  FPageProviders.Anchors := [akLeft, akTop, akRight];

  FTabGemini := TTabSheet.Create(FPageProviders);
  FTabGemini.PageControl := FPageProviders;
  FTabGemini.Caption := 'Gemini';

  FApiKeyLabel := TLabel.Create(Self);
  FApiKeyLabel.Parent := FTabGemini;
  FApiKeyLabel.Left := 10;
  FApiKeyLabel.Top := 10;
  FApiKeyLabel.Caption := 'API key:';

  FApiKeyEdit := TEdit.Create(Self);
  FApiKeyEdit.Parent := FTabGemini;
  FApiKeyEdit.Left := 10;
  FApiKeyEdit.Top := 26;
  // Fixed width (like the Delphi tab edit): the tab's ClientWidth is not reliable
  // at Setup (no handle yet), and 430 fits the tab even after the page control
  // pulls in with a narrower hosted panel.
  FApiKeyEdit.Width := 430;
  FApiKeyEdit.PasswordChar := '*';
  FApiKeyEdit.TextHint := 'paste your provider API key';
  FApiKeyEdit.OnExit := Self._ApiKeyExit;

  FGetKeyLink := TLabel.Create(Self);
  FGetKeyLink.Parent := FTabGemini;
  FGetKeyLink.Left := 10;
  FGetKeyLink.Top := 52;
  FGetKeyLink.Caption := 'Get a free API key -> Google AI Studio';
  FGetKeyLink.Font.Color := clBlue;
  FGetKeyLink.Font.Style := [fsUnderline];
  FGetKeyLink.Cursor := crHandPoint;
  FGetKeyLink.OnClick := Self._GetKeyClick;

  FTabOllama := TTabSheet.Create(FPageProviders);
  FTabOllama.PageControl := FPageProviders;
  FTabOllama.Caption := 'Ollama';

  FOllamaUrlLabel := TLabel.Create(Self);
  FOllamaUrlLabel.Parent := FTabOllama;
  FOllamaUrlLabel.Left := 10;
  FOllamaUrlLabel.Top := 10;
  FOllamaUrlLabel.Caption := 'Endpoint URL:';

  FOllamaUrlEdit := TEdit.Create(Self);
  FOllamaUrlEdit.Parent := FTabOllama;
  FOllamaUrlEdit.Left := 10;
  FOllamaUrlEdit.Top := 26;
  FOllamaUrlEdit.Width := 430;
  FOllamaUrlEdit.TextHint := 'blank = http://localhost:11434';

  // === MCP settings (boxed group) ==========================================
  FMcpGroup := TGroupBox.Create(Self);
  FMcpGroup.Parent := Self;
  FMcpGroup.Left := cXLabel;
  FMcpGroup.Top := 280;
  FMcpGroup.Width := cRightEdge - cXLabel;
  // Tall enough for two info rows + the Test MCP button below the caption band
  // (the group's client area excludes the caption).
  FMcpGroup.Height := 108;
  FMcpGroup.Anchors := [akLeft, akTop, akRight];
  FMcpGroup.Caption := 'MCP settings';

  FAuditLabel := TLabel.Create(Self);
  FAuditLabel.Parent := FMcpGroup;
  FAuditLabel.Left := 10;
  FAuditLabel.Top := 8;
  FAuditLabel.Caption := 'Audit log:';

  FAuditEdit := TEdit.Create(Self);
  FAuditEdit.Parent := FMcpGroup;
  FAuditEdit.Left := 78;
  FAuditEdit.Top := 4;
  // Fixed width (the group's ClientWidth is not reliable at Setup); read-only, so
  // the full path is reachable by scrolling the field on focus.
  FAuditEdit.Width := 370;
  FAuditEdit.ReadOnly := True;

  FServerLabel := TLabel.Create(Self);
  FServerLabel.Parent := FMcpGroup;
  FServerLabel.Left := 10;
  FServerLabel.Top := 36;
  FServerLabel.Caption := 'Server:';

  FServerEdit := TEdit.Create(Self);
  FServerEdit.Parent := FMcpGroup;
  FServerEdit.Left := 78;
  FServerEdit.Top := 32;
  FServerEdit.Width := 370;
  FServerEdit.ReadOnly := True;

  FTestMcpButton := TButton.Create(Self);
  FTestMcpButton.Parent := FMcpGroup;
  FTestMcpButton.Left := 10;
  FTestMcpButton.Top := 60;
  FTestMcpButton.Width := 120;
  FTestMcpButton.Caption := 'Test MCP';
  FTestMcpButton.OnClick := Self._TestMcpClick;

  FMcpStatus := TLabel.Create(Self);
  FMcpStatus.Parent := FMcpGroup;
  FMcpStatus.Left := 138;
  FMcpStatus.Top := 65;
  FMcpStatus.Caption := '';

  // === Requirements =========================================================
  FReqHeading := TLabel.Create(Self);
  FReqHeading.Parent := Self;
  FReqHeading.Left := cXLabel;
  FReqHeading.Top := 394;
  FReqHeading.Font.Style := [fsBold];
  FReqHeading.Caption := 'Requirements';

  FReqLabel := TLabel.Create(Self);
  FReqLabel.Parent := Self;
  FReqLabel.Left := cXLabel;
  FReqLabel.Top := 412;
  // Wraps to the frame's real hosted width (never a fixed pixel clip). Kept short
  // (two lines at the hosted width) so the whole frame fits the ~455px options
  // viewport, which clips rather than scrolls a taller alClient editor.
  FReqLabel.WordWrap := True;
  FReqLabel.AutoSize := True;
  FReqLabel.Anchors := [akLeft, akTop, akRight];
  FReqLabel.BorderSpacing.Right := cXLabel;
  FReqLabel.Width := cRightEdge - cXLabel;
  FReqLabel.Caption :=
    'Requires Lazarus (FPC) on Windows. Codex and Gemini are bundled; Claude ' +
    'Code and Copilot are user-supplied; local models run via Ollama. Config, ' +
    'models and API keys are stored under %APPDATA%\Aefos, shared with the RAD ' +
    'Studio plugin.';
end;

procedure TAefosOptionsFrame._BrowseClick(ASender: TObject);
var
  LDialog: TOpenDialog;
begin
  LDialog := TOpenDialog.Create(nil);
  try
    LDialog.Title := 'Select the AI CLI executable';
    LDialog.Filter := 'Executables (*.exe)|*.exe|All files (*.*)|*.*';
    LDialog.Options := LDialog.Options + [ofFileMustExist];
    if Trim(FPathEdit.Text) <> '' then
      LDialog.FileName := FPathEdit.Text;
    if LDialog.Execute then
      FPathEdit.Text := LDialog.FileName;
  finally
    LDialog.Free;
  end;
end;

procedure TAefosOptionsFrame._ExecutorChange(ASender: TObject);
var
  LNewKind: TExecutorKind;
  LSelected: string;
begin
  if FLoading or (FExecutorCombo.ItemIndex < 0) then
    Exit;
  LNewKind := TExecutorKind(FExecutorCombo.ItemIndex);
  // Per-executor model memory: stash the model the user had for the kind being
  // LEFT, then recall the one for the kind being entered - so a Claude/Copilot
  // model never carries into Gemini (which would 404). Same rule as Delphi.
  TExecutorModelStore.SetSelectedModelForKind(FModelKind,
    UTF8ToUTF16(FModelCombo.Text));
  _PopulateModels(LNewKind);
  LSelected := UTF16ToUTF8(TExecutorModelStore.SelectedModelForKind(LNewKind));
  if (LSelected = '') and (FModelCombo.Items.Count > 0) then
    LSelected := FModelCombo.Items[0];
  FModelCombo.Text := LSelected;
  FModelKind := LNewKind;
  // Recall this executor's key (the field for the kind being LEFT was persisted
  // on the edit's OnExit, which fired as focus moved to the combo).
  FApiKeyEdit.Text := UTF16ToUTF8(TExecutorApiKeys.ApiKeyForKind(LNewKind));
  _ApplyExecutorKindUi(LNewKind);
end;

procedure TAefosOptionsFrame._AddModelClick(ASender: TObject);
var
  LKind: TExecutorKind;
  LModel: string;
begin
  LModel := Trim(FModelCombo.Text);
  if (LModel = '') or (FExecutorCombo.ItemIndex < 0) then
    Exit;
  // Persist the typed model into models.json for the selected executor, then
  // refresh the list so it shows in the dropdown (and the chat selector). No
  // rebuild needed for a newly shipped model.
  LKind := _SelectedKind;
  TExecutorModelStore.AddModelForKind(LKind, UTF8ToUTF16(LModel));
  _PopulateModels(LKind);
  FModelCombo.Text := LModel;
end;

procedure TAefosOptionsFrame._RemoveModelClick(ASender: TObject);
var
  LKind: TExecutorKind;
  LModel: string;
begin
  LModel := Trim(FModelCombo.Text);
  if (LModel = '') or (FExecutorCombo.ItemIndex < 0) then
    Exit;
  // Drop the typed/selected model from models.json (e.g. a typo'd id) and
  // refresh the list - no need to hand-edit the file.
  LKind := _SelectedKind;
  TExecutorModelStore.RemoveModelForKind(LKind, UTF8ToUTF16(LModel));
  FModelCombo.Text := '';
  _PopulateModels(LKind);
end;

procedure TAefosOptionsFrame._ApiKeyExit(ASender: TObject);
begin
  // Persist the key for the selected executor the moment the field loses focus
  // (incl. when switching executors), so it survives without an explicit Save.
  if FExecutorCombo.ItemIndex >= 0 then
    TExecutorApiKeys.SetApiKeyForKind(_SelectedKind, UTF8ToUTF16(FApiKeyEdit.Text));
end;

procedure TAefosOptionsFrame._GetKeyClick(ASender: TObject);
begin
  // Open the provider's key page in the default browser. Aefos injects the key
  // as the provider's env var into the spawned CLI, so no system env var is needed.
  OpenURL(cGetKeyUrl);
end;

procedure TAefosOptionsFrame._DownloadClick(ASender: TObject);
var
  LUrl: string;
begin
  // Hand the user off to the SELECTED executor's own official download page - so
  // it never goes stale. Aefos owns no credentials.
  LUrl := UTF16ToUTF8(TExecutorDownloads.DownloadUrlForKind(_SelectedKind));
  if LUrl <> '' then
    OpenURL(LUrl);
end;

procedure TAefosOptionsFrame._LoginClick(ASender: TObject);
var
  LProc: TProcessUTF8;
  LPath: string;
begin
  // Launch "<cli> login" in its own console so the user completes the provider's
  // OAuth/device flow (the CLIs that expose a login subcommand). Detached: we do
  // not wait, and freeing the TProcess does not kill the child.
  LPath := _EffectiveCliPath(_SelectedKind);
  if LPath = '' then
  begin
    FTestStatus.Caption :=
      'No AI CLI found - set the Executable path or put it on PATH.';
    Exit;
  end;
  try
    LProc := TProcessUTF8.Create(nil);
    try
      LProc.Executable := LPath;
      LProc.Parameters.Add('login');
      LProc.Options := [poNewConsole];
      LProc.Execute;
    finally
      LProc.Free;
    end;
  except
    on E: Exception do
      FTestStatus.Caption := 'Could not start the login flow: ' + E.Message;
  end;
end;

procedure TAefosOptionsFrame._TestCliClick(ASender: TObject);
var
  LKind: TExecutorKind;
  LPath: string;
begin
  LKind := _SelectedKind;
  if LKind = ekOllama then
  begin
    _TestOllamaEndpoint;
    Exit;
  end;
  LPath := _EffectiveCliPath(LKind);
  if LPath = '' then
  begin
    FTestStatus.Caption :=
      'No AI CLI found - set the Executable path or put it on PATH.';
    Exit;
  end;
  FTestCliButton.Enabled := False;
  FTestStatus.Caption := 'Testing...';
  // Off the IDE main thread (a blocking --version would otherwise freeze the
  // IDE). The worker re-enables the button and sets the verdict via a
  // token-guarded Synchronize. FreeOnTerminate: it owns its own lifetime.
  TAefosCliProbe.Create(Self, LPath, FLive);
end;

procedure TAefosOptionsFrame._TestOllamaEndpoint;
var
  LTransport: IOllamaTransport;
  LSink: TAefosOptModelsSink;
  LOnModels: TOllamaModelsEvent;
begin
  FTestCliButton.Enabled := False;
  FTestStatus.Caption := 'Testing...';
  // Ping GET /api/tags on the transport's own worker; the sink pushes the result
  // to the main thread. A blank URL lets the transport apply its localhost default.
  LTransport := NewOllamaTransport;
  FOllamaTransport := LTransport;   // keep it alive across the async fetch
  LSink := TAefosOptModelsSink.Create(Self, FLive);
  LOnModels := LSink.Deliver;       // bind as a method pointer (FPC idiom)
  LTransport.FetchModels(UTF8ToUTF16(Trim(FOllamaUrlEdit.Text)), LOnModels);
end;

procedure TAefosOptionsFrame._TestMcpClick(ASender: TObject);
var
  // UnicodeString: the gate is {$mode delphiunicode}, so its `out` parameter is
  // UTF-16 and a plain (UTF-8) local would not bind.
  LUpsell: UnicodeString;
begin
  // Pro gate, mirroring Aefos.OTA.Chat.UI.Options.ChatFrame.pas:511. The MCP
  // AUTO-setup is the Pro convenience; hand-writing the config stays free. Soft
  // during beta (GATE_HARD_MODE off): it runs and upsells once. At GA the same
  // line refuses and says so in the status label the user is already looking at.
  if not TLicenseGate.Enforce(AEFOS_CAP_MCP, LUpsell) then
  begin
    FMcpStatus.Caption := 'MCP auto-setup is a Pro feature.';
    Exit;
  end;
  if LUpsell <> '' then
    ShowMessage(UTF16ToUTF8(LUpsell));
  // The Lazarus MCP host is IN-PROCESS (statically linked into lazarus.exe), so
  // "reachability" is simply: start it (idempotent, never raises out) and confirm
  // it is listening on its named pipe. This is the honest analog of the Delphi
  // ButtonTestMcpClick handshake retargeted at AefosLazMcpHost - it starts the
  // REAL server a connecting CLI would use and reports its REAL state.
  try
    AefosLazMcpHost.Start;
    if AefosLazMcpHost.Started then
      FMcpStatus.Caption :=
        'MCP server listening on ' + UTF16ToUTF8(AefosLazMcpHost.PipeName)
    else if AefosLazMcpHost.LastStartError <> '' then
      // The host knows WHY. Sending the user to a debug log they cannot see
      // (the IDE only writes one when launched with --debug-log) was the same as
      // saying nothing.
      FMcpStatus.Caption := UTF16ToUTF8(AefosLazMcpHost.LastStartError)
    else
      FMcpStatus.Caption :=
        'Failed to start the MCP server (see the IDE debug log).';
  except
    on E: Exception do
      FMcpStatus.Caption := 'Failed: ' + E.Message;
  end;
end;

procedure TAefosOptionsFrame._OnCliProbeResult(const AMessage: string);
begin
  FTestStatus.Caption := AMessage;
  FTestCliButton.Enabled := True;
  // After a successful CLI probe the user may have just authenticated (or the
  // path just became valid), so re-check the login state - same trigger as the
  // Delphi page (refresh after Test CLI).
  _RefreshLoginState(_SelectedKind);
end;

procedure TAefosOptionsFrame._OnOllamaTested(const AModels: TArray<UnicodeString>;
  const AError: UnicodeString);
var
  LFor: Integer;
  LName: string;
begin
  FTestCliButton.Enabled := True;
  if AError <> '' then
  begin
    FTestStatus.Caption := 'Failed: is the local runtime running?';
    Exit;
  end;
  if Length(AModels) = 0 then
  begin
    FTestStatus.Caption := 'Endpoint OK - no models pulled yet';
    Exit;
  end;
  FTestStatus.Caption := Format('Endpoint OK - %d model(s)', [Length(AModels)]);
  // Bonus (same as Delphi): fold the REAL local list into the combo, but only
  // while the local runtime is still the selected executor. Keep the typed text.
  if _SelectedKind <> ekOllama then
    Exit;
  FModelCombo.Items.BeginUpdate;
  try
    for LFor := 0 to High(AModels) do
    begin
      LName := UTF16ToUTF8(AModels[LFor]);
      if FModelCombo.Items.IndexOf(LName) < 0 then
        FModelCombo.Items.Add(LName);
    end;
  finally
    FModelCombo.Items.EndUpdate;
  end;
end;

procedure TAefosOptionsFrame.ReadSettings(AOptions: TAbstractIDEOptions);
var
  LConfig: IConfig;
  LSnap: TConfig;
  LModel: string;
begin
  // AOptions is ignored: Aefos owns its own JSON (see the unit header).
  //
  // NOTHING BELOW MAY RUN BEFORE Setup. Every control this method writes to is
  // created INSIDE Setup (FExecutorCombo at :881 and the rest after it), so on a
  // ReadSettings-before-Setup call the very first assignment
  // (FExecutorCombo.ItemIndex) dereferences nil -- an access violation raised
  // while the IDE is opening its options dialog, which is precisely the symptom a
  // partner reported: an AV on clicking Options, dismissable, IDE survives.
  //
  // This asymmetry was already known on the other side of the pair: WriteSettings
  // carries a comment saying "WriteSettings before Setup - the dialog contract
  // should prevent this" and defends itself with a range check. Whoever wrote that
  // had seen the order not being guaranteed, hardened the SAVE path, and left the
  // LOAD path bare - the one that runs when the dialog opens.
  //
  // So it is refused here instead of merely survived. An unbuilt page shows empty
  // (Setup populates it a moment later on the normal path) and says so in the log;
  // it never faults.
  if not FBuilt then
  begin
    DebugLn('[AefosAI] options: ReadSettings called BEFORE Setup - ',
      'skipping (the page controls do not exist yet)');
    Exit;
  end;
  FLoading := True;
  try
    LConfig := _BuildConfigService;
    LConfig.Load;
    LSnap := LConfig.Snapshot;
    FExecutorCombo.ItemIndex := Ord(LSnap.Executor);
    FPathEdit.Text := UTF16ToUTF8(LSnap.ExecutorPath);
    FOllamaUrlEdit.Text := UTF16ToUTF8(LSnap.OllamaBaseUrl);
    _ApplyExecutorKindUi(LSnap.Executor);
    // Populate the list, then pick the model PER EXECUTOR: prefer the model
    // remembered for this kind; fall back to the persisted single Model (first
    // run / migration), then the first suggestion. Off-list models kept verbatim.
    _PopulateModels(LSnap.Executor);
    FModelKind := LSnap.Executor;
    LModel := UTF16ToUTF8(TExecutorModelStore.SelectedModelForKind(LSnap.Executor));
    if LModel = '' then
      LModel := UTF16ToUTF8(LSnap.Model);
    if (LModel = '') and (FModelCombo.Items.Count > 0) then
      LModel := FModelCombo.Items[0];
    FModelCombo.Text := LModel;
    FApiKeyEdit.Text := UTF16ToUTF8(TExecutorApiKeys.ApiKeyForKind(LSnap.Executor));
    // Depth parity: total-run timeout (seconds) + output-filter policy.
    FTimeoutEdit.Text := IntToStr(LSnap.TimeoutSeconds);
    FOutputFilterCombo.ItemIndex := Ord(LSnap.OutputFilter);
    // MCP settings (read-only info). The audit path is the SHARED
    // %APPDATA%\Aefos\logs\mcp-audit-<date>.jsonl the RAD plugin also writes
    // (TMCPAuditLog.LogFilePath - one brain). The server line reports the
    // in-process host + its named pipe (the honest Lazarus analog of the RAD
    // "In-process MCP server (aefos)" info: here the server is statically linked
    // into lazarus.exe and reached over a per-IDE named pipe).
    FAuditEdit.Text := UTF16ToUTF8(TMCPAuditLog.LogFilePath);
    FServerEdit.Text :=
      'aefos (in-process, hosted by the Lazarus package) - named pipe: ' +
      UTF16ToUTF8(AefosLazMcpHost.PipeName);
  except
    // WHY THIS SWALLOWS.
    //
    // ReadSettings is called by the IDE while the options dialog is opening, and
    // it touches a lot of the outside world: the shared JSON config, the model
    // store, the API-key store, the MCP audit path, the host's pipe name. If ANY
    // of that raises, the exception escapes into the IDE's dialog code and the
    // user gets "Access violation - press OK to ignore at the risk of data
    // corruption" the moment he clicks Options. A partner reported exactly that,
    // dismissable, with the IDE surviving afterwards - the signature of a fault
    // thrown inside a page's load, not a dead IDE.
    //
    // A half-populated page he can still read and correct beats a dialog that
    // greets him with an AV. So the fault is contained HERE, at our own boundary,
    // and never silently: the breadcrumb below names the unit, the class and the
    // message, so the next report points at the real cause instead of at "the
    // Options screen". It is deliberately NOT a MessageDlg - a modal raised while
    // the options dialog builds is its own hazard.
    on E: Exception do
      DebugLn('[AefosAI] options: ReadSettings RAISED ', E.ClassName, ': ',
        E.Message, ' - the page is shown partially populated');
  end;
  FLoading := False;
end;

procedure TAefosOptionsFrame.WriteSettings(AOptions: TAbstractIDEOptions);
var
  LConfig: IConfig;
  LSnap: TConfig;
  LIndex: Integer;
  LKind: TExecutorKind;
begin
  // Guarded for the same reason ReadSettings is, but the stakes differ and so
  // does the honesty required. This runs when he presses OK, so an escaping
  // exception is an AV on top of settings that were NOT saved. Swallowing it
  // silently would be worse than the AV: he would close the dialog believing his
  // change landed. So the fault is contained and ANNOUNCED - the breadcrumb says
  // the save did not complete, which is the one fact he needs.
  //
  // AND THE SAME ORDERING REFUSAL AS ReadSettings, because the existing defence
  // here was aimed one step too late: the range check below reads
  // FExecutorCombo.ItemIndex, and on a before-Setup call that read is ITSELF the
  // nil dereference it was meant to protect against. Guarding the VALUE cannot
  // help when the OBJECT is absent.
  //
  // Nothing is lost by refusing: a page that was never built has no edits to save.
  if not FBuilt then
  begin
    DebugLn('[AefosAI] options: WriteSettings called BEFORE Setup - ',
      'nothing to save (the page was never built)');
    Exit;
  end;
  try
  // Load first, then overwrite ONLY the keys this page edits, so fields it does
  // not surface (inspector, timeout, output filter) survive - one config file
  // serves both IDEs without either clobbering the other.
  LConfig := _BuildConfigService;
  LConfig.Load;
  LSnap := LConfig.Snapshot;
  LIndex := FExecutorCombo.ItemIndex;
  if (LIndex >= Ord(Low(TExecutorKind))) and (LIndex <= Ord(High(TExecutorKind))) then
  begin
    LKind := TExecutorKind(LIndex);
    LSnap.Executor := LKind;
    // Remember this executor's model so it is recalled next time (and never
    // leaks to another provider). Config.Model below holds the CURRENT model.
    TExecutorModelStore.SetSelectedModelForKind(LKind,
      UTF8ToUTF16(Trim(FModelCombo.Text)));
    // Belt and suspenders: persist the API key for the selected key-auth
    // executor even if the edit never fired OnExit before OK.
    if TExecutorApiKeys.ApiKeyEnvVarFor(LKind) <> '' then
      TExecutorApiKeys.SetApiKeyForKind(LKind, UTF8ToUTF16(Trim(FApiKeyEdit.Text)));
  end
  else
    // Combo not populated (WriteSettings before Setup - the dialog contract
    // should prevent this): keep the LOADED executor rather than silently forcing
    // a default; the other keys still save.
    DebugLn('[AefosAI] options: executor combo out of range (', IntToStr(LIndex),
      ') - keeping the stored executor');
  LSnap.ExecutorPath := UTF8ToUTF16(Trim(FPathEdit.Text));
  LSnap.Model := UTF8ToUTF16(Trim(FModelCombo.Text));
  LSnap.OllamaBaseUrl := UTF8ToUTF16(Trim(FOllamaUrlEdit.Text));
  // Depth parity: total-run timeout (blank/non-numeric/negative -> 0 = disabled)
  // + output-filter policy (ItemIndex maps 1:1 to TOutputFilterPolicy via Ord).
  LSnap.TimeoutSeconds := StrToIntDef(Trim(FTimeoutEdit.Text), 0);
  if LSnap.TimeoutSeconds < 0 then
    LSnap.TimeoutSeconds := 0;
  if FOutputFilterCombo.ItemIndex >= 0 then
    LSnap.OutputFilter := TOutputFilterPolicy(FOutputFilterCombo.ItemIndex);
  LConfig.Save(LSnap);
  except
    on E: Exception do
      DebugLn('[AefosAI] options: WriteSettings RAISED ', E.ClassName, ': ',
        E.Message, ' - YOUR CHANGES ON THIS PAGE WERE NOT SAVED');
  end;
end;

class function TAefosOptionsFrame.SupportedOptionsClass: TAbstractIDEOptionsClass;
begin
  Result := TAefosIDEOptions;
end;

procedure RegisterAefosOptionsPage;
begin
  DebugLn('[AefosAI] options: RegisterAefosOptionsPage begin');
  GAefosOptionsGroupIndex := GetFreeIDEOptionsGroupIndex(cAefosOptionsGroupBase);
  DebugLn('[AefosAI] options: free group index = ',
    IntToStr(GAefosOptionsGroupIndex));
  RegisterIDEOptionsGroup(GAefosOptionsGroupIndex, TAefosIDEOptions);
  DebugLn('[AefosAI] options: group registered');
  { Fixed literal page index - NEVER GetFreeIDEOptionsIndex here: the group was
    just created with Items = nil (ideopteditorintf.pas:612) and GetFreeIDEOptions
    Index dereferences Rec^.Items with no nil guard (:242) => the startup AV.
    RegisterIDEOptionsEditor itself creates the Items list (:216-217). }
  RegisterIDEOptionsEditor(GAefosOptionsGroupIndex, TAefosOptionsFrame,
    cAefosOptionsPageIndex);
  { Sibling pages under the same group (registered AFTER the Chat editor created
    the Items list): the "AI Flow" agent-behaviour/permission knobs and the
    "Terminal" MCP-server page. The Terminal registration ALSO honours the
    persisted MCP-autostart preference at load. Both guarded so a failure only
    logs and the Chat page still stands. }
  try
    RegisterIDEOptionsEditor(GAefosOptionsGroupIndex, TAefosFlowOptionsFrame,
      cAefosFlowPageIndex);
  except
    on E: Exception do
      DebugLn('[AefosAI] options: AI Flow editor registration RAISED ',
        E.ClassName, ': ', E.Message);
  end;
  try
    RegisterAefosTerminalOptionsPage(GAefosOptionsGroupIndex,
      cAefosTerminalPageIndex);
  except
    on E: Exception do
      DebugLn('[AefosAI] options: Terminal editor registration RAISED ',
        E.ClassName, ': ', E.Message);
  end;
  DebugLn('[AefosAI] options: group+editors registered at group index ',
    IntToStr(GAefosOptionsGroupIndex));
end;

{$R *.lfm}

end.
