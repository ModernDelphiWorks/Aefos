unit Aefos.OTA.Chat.UI.Options.ChatFrame;

{
  Chat / Executor page for the Aefos node in Tools->Options
  (ESP-002, Epic 4/4, Demand 1/1, ADR-208).

  A plain TFrame embedded by the IDE through INTAAddInOptions. It owns no
  config logic: it renders the executor kind, executor path (+ browse), model
  (editable combo guided by SuggestedModels), and maps them to/from a
  TOptionsConfigBinding (the ToolsAPI-free seam). With no active project every
  input is disabled and an explanatory note is shown (RN-002).

  The owning INTAAddInOptions (in UI.Options.Registration) calls LoadFrom in
  FrameCreated and StoreTo in ValidateContents/DialogClosed.
}

interface

uses
  System.Classes,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.StdCtrls,
  Vcl.ComCtrls,
  Vcl.Dialogs,
  Aefos.Provider.Types,
  Aefos.OTA.Chat.UI.Options.Binding;

type
  // Ref-counted liveness flag shared between the frame and a worker thread's
  // queued UI callback (see TAefosChatOptionsFrame.FAlive).
  IAliveToken = interface
    ['{6F2A1B4C-9D3E-4A77-B0C1-2E8F5A6D9C31}']
    function IsAlive: Boolean;
    procedure Kill;
  end;

  TAefosChatOptionsFrame = class(TFrame)
    LabelHeading: TLabel;
    LabelExecutor: TLabel;
    ComboExecutor: TComboBox;
    LabelExecutorPath: TLabel;
    EditExecutorPath: TEdit;
    ButtonBrowse: TButton;
    ButtonLogin: TButton;
    // Link-style "Download the CLI" — same visual family as LabelApiKeyGetLink
    // (Gemini's "Get a free API key" link): a plain TLabel, not a TButton, per
    // the maintainer's explicit ask (parity with the Gemini link).
    LabelDownloadCli: TLabel;
    // Per-provider settings tabs: Gemini (API key) and Ollama (endpoint URL).
    // Always visible; the executor switch just brings the matching tab to
    // front (_ApplyExecutorKindUi).
    PageProviders: TPageControl;
    TabGemini: TTabSheet;
    TabOllama: TTabSheet;
    LabelOllamaUrl: TLabel;
    EditOllamaUrl: TEdit;
    LabelApiKey: TLabel;
    EditApiKey: TEdit;
    LabelApiKeyGetLink: TLabel;
    LabelModel: TLabel;
    ComboModel: TComboBox;
    ButtonAddModel: TButton;
    ButtonRemoveModel: TButton;
    LabelTimeout: TLabel;
    EditTimeout: TEdit;
    LabelOutputFilter: TLabel;
    ComboOutputFilter: TComboBox;
    LabelNote: TLabel;
    OpenDialog: TOpenDialog;
    LabelRequirementsHeading: TLabel;
    LabelRequirements: TLabel;
    // MCP section (merged from the former standalone "MCP Server" page) —
    // read-only info about the in-process MCP server.
    LabelMcpHeading: TLabel;
    LabelAuditCaption: TLabel;
    EditAuditPath: TEdit;
    LabelServerCaption: TLabel;
    EditServerInfo: TEdit;
    ButtonTestConnection: TButton;
    LabelTestStatus: TLabel;
    ButtonTestMcp: TButton;
    LabelMcpTestStatus: TLabel;
    procedure ButtonBrowseClick(Sender: TObject);
    procedure ButtonLoginClick(Sender: TObject);
    procedure LabelDownloadCliClick(Sender: TObject);
    procedure ButtonTestConnectionClick(Sender: TObject);
    procedure ButtonTestMcpClick(Sender: TObject);
    procedure ButtonAddModelClick(Sender: TObject);
    procedure ButtonRemoveModelClick(Sender: TObject);
    procedure ComboExecutorChange(Sender: TObject);
    procedure EditApiKeyExit(Sender: TObject);
    procedure LabelApiKeyGetLinkClick(Sender: TObject);
  private
    // Liveness token: the IDE can destroy this Options frame (dialog closed)
    // while a Test CLI/MCP worker thread is still running. The thread's
    // TThread.Queue UI update captures this ref-counted token (which outlives
    // the frame) and only touches the controls while the frame is still alive —
    // otherwise a freed control's WM_SETTEXT crashes through the VCL Styles hook.
    FAlive: IAliveToken;
    // The executor kind currently reflected in ComboModel — so an executor
    // switch can stash the model the user had for the kind being LEFT before
    // recalling the kind being entered (per-executor model memory).
    FModelKind: TExecutorKind;
    // True while LoadFrom populates the controls, so the ComboExecutor.OnChange
    // handler doesn't stash a stale model under an uninitialised kind.
    FLoading: Boolean;
    procedure _PopulateExecutors;
    procedure _PopulateModels(const AKind: TExecutorKind);
    procedure _PopulateOutputFilters;
    // Per-kind UI: hides the executor-path row for ekOllama (a local runtime
    // has no binary, path, Browse or login) and brings the provider tab that
    // matches the selected kind to front.
    procedure _ApplyExecutorKindUi(const AKind: TExecutorKind);
    // Async `<cli> login status` probe: flips the Login button caption to
    // "Logged in" when the CLI reports an authenticated session, so a user who
    // already logged in is not nagged by a bare "Login" (field report
    // 2026-07-08). A CLI without the subcommand just exits non-zero and the
    // caption stays "Login". The button stays enabled either way (re-login).
    procedure _RefreshLoginState(const AKind: TExecutorKind);
    procedure _SetInputsEnabled(const AEnabled: Boolean);
    // The CLI path the actions should use: the typed path when set, else the
    // binary auto-resolved on PATH (env AEFOS_CLI -> PATH) for the selected
    // executor — so first-run works without typing a path when the CLI is
    // installed. '' only when nothing resolves.
    function _EffectiveCliPath: string;
  public
    // Renders the static read-only requirements group from the single in-code
    // source of truth (ADR-276/277). No config binding, no ValidateContents
    // role -- the group is informational only (ADR-210 static-frame precedent).
    constructor Create(AOwner: TComponent); override;
    // Kills the liveness token so any pending worker-thread UI callback becomes
    // a no-op instead of touching a freed control.
    destructor Destroy; override;
    // Populates the controls from the binding's State and toggles the
    // no-active-project note (RN-002).
    procedure LoadFrom(const ABinding: TOptionsConfigBinding);
    // Reads the controls back into the binding's State (called on validate /
    // accept). A no-op effect when inputs are disabled — the state simply
    // mirrors the disabled values.
    procedure StoreTo(const ABinding: TOptionsConfigBinding);
  end;

implementation

{$R *.dfm}

uses
  System.SysUtils,
  Winapi.Windows,
  Winapi.ShellAPI,
  ToolsAPI,
  Aefos.Tools.Process,
  Aefos.MCP.AuditLog,
  Aefos.OTA.Chat.Core.CLIBinaryResolver,
  Aefos.MCP.Provision,
  Aefos.Provider.Registry,
  Aefos.Provider.Ollama,
  Aefos.Provider.Codex,
  Aefos.OTA.Chat.Core.Dispatcher.Types,
  Aefos.OTA.Chat.Core.SupportInfo;

type
  // Trivial ref-counted implementation of IAliveToken. The frame holds one ref;
  // a worker thread's queued callback holds another, so it survives the frame.
  TAliveToken = class(TInterfacedObject, IAliveToken)
  private
    FAlive: Boolean;
    function IsAlive: Boolean;
    procedure Kill;
  public
    constructor Create;
  end;

constructor TAliveToken.Create;
begin
  inherited Create;
  FAlive := True;
end;

function TAliveToken.IsAlive: Boolean;
begin
  Result := FAlive;
end;

procedure TAliveToken.Kill;
begin
  FAlive := False;
end;

constructor TAefosChatOptionsFrame.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FAlive := TAliveToken.Create;
  FModelKind := ekClaude;
  // The requirements text is sourced from Chat.Core.SupportInfo so the Options
  // group never drifts from the About dialog or the docs (BR-1 / C-4).
  LabelRequirements.Caption := FormatRequirements;
end;

destructor TAefosChatOptionsFrame.Destroy;
begin
  // Any in-flight Test worker's queued UI update becomes a no-op from here on.
  if Assigned(FAlive) then
    FAlive.Kill;
  inherited Destroy;
end;

function TAefosChatOptionsFrame._EffectiveCliPath: string;
var
  LKind: TExecutorKind;
begin
  Result := Trim(EditExecutorPath.Text);
  if Result <> '' then
    Exit;
  LKind := ekClaude;
  if ComboExecutor.ItemIndex >= 0 then
    LKind := TExecutorKind(ComboExecutor.ItemIndex);
  Result := ResolveCLIBinary('', TProviderRegistry.ResolveExecutorProfile(LKind).BinaryName);
end;

procedure TAefosChatOptionsFrame._RefreshLoginState(
  const AKind: TExecutorKind);
var
  LPath: string;
  LAlive: IAliveToken;
begin
  ButtonLogin.Caption := 'Login';
  // Codex ONLY: `codex login status` is a real subcommand (exit 0 + "Logged
  // in ..."). For the other CLIs a bare `login status` would be parsed as a
  // POSITIONAL PROMPT (Claude/Gemini run piped input as a print-mode turn) —
  // a background probe must never risk dispatching an actual AI turn.
  if AKind <> ekCodex then
    Exit;
  LPath := _EffectiveCliPath;
  if LPath = '' then
    Exit;
  LAlive := FAlive;
  TThread.CreateAnonymousThread(
    procedure
    var
      LRes: TToolProcessResult;
      LLow: string;
      LLogged: Boolean;
    begin
      // Codex/Copilot expose `login status` (exit 0 + "Logged in ..." when
      // authenticated). "not logged in" must be excluded explicitly — it
      // contains "logged in" as a substring.
      LRes := TProcessRunner.Run(LPath, 'login status', '', '', 8000);
      LLow := LowerCase(LRes.StdOut + ' ' + LRes.StdErr);
      LLogged := LRes.Ok and (Pos('logged in', LLow) > 0) and
        (Pos('not logged in', LLow) = 0);
      TThread.Queue(nil,
        procedure
        begin
          // Only apply while the frame is alive AND the user has not switched
          // executors since the probe started (a stale answer would mislabel
          // the other CLI's button).
          if not LAlive.IsAlive then
            Exit;
          if LLogged and (ComboExecutor.ItemIndex >= 0) and
             (TExecutorKind(ComboExecutor.ItemIndex) = AKind) then
            ButtonLogin.Caption := 'Logged in';
        end);
    end).Start;
end;

procedure TAefosChatOptionsFrame.ButtonLoginClick(Sender: TObject);
var
  LPath: string;
begin
  LPath := _EffectiveCliPath;
  if LPath = '' then
  begin
    LabelTestStatus.Caption := 'No AI CLI found — install Claude Code or set the path.';
    Exit;
  end;
  // Open a visible console running `<cli> login` so the user completes the
  // provider's OAuth/browser flow (Copilot/Codex expose a `login` subcommand).
  // /k keeps the window open so any prompt or result stays readable.
  ShellExecute(0, 'open', 'cmd.exe',
    PChar('/k ""' + LPath + '" login"'), nil, SW_SHOWNORMAL);
end;

procedure TAefosChatOptionsFrame.ButtonTestConnectionClick(Sender: TObject);
var
  LPath: string;
  LAlive: IAliveToken;
  LKind: TExecutorKind;
  LUrl: string;
begin
  LKind := ekClaude;
  if ComboExecutor.ItemIndex >= 0 then
    LKind := TExecutorKind(ComboExecutor.ItemIndex);
  if LKind = ekOllama then
  begin
    // Local models: ping the endpoint (/api/tags) instead of probing a CLI
    // binary. The transport marshals the callback to the main thread; FAlive
    // guards a frame freed while the ping ran. Bonus: a successful ping
    // refreshes the model combo with the ACTUAL local model list.
    ButtonTestConnection.Enabled := False;
    LabelTestStatus.Caption := 'Testing...';
    LAlive := FAlive;
    LUrl := Trim(EditOllamaUrl.Text);
    NewOllamaTransport.FetchModels(LUrl,
      procedure(const AModels: TArray<string>; const AError: string)
      var
        LIndex: Integer;
        LTyped: string;
      begin
        if not LAlive.IsAlive then
          Exit;
        ButtonTestConnection.Enabled := True;
        if AError <> '' then
        begin
          LabelTestStatus.Caption := 'Failed: is Ollama running?';
          Exit;
        end;
        if Length(AModels) = 0 then
        begin
          LabelTestStatus.Caption := 'Endpoint OK - no models pulled yet';
          Exit;
        end;
        LabelTestStatus.Caption := Format('Endpoint OK - %d model(s)',
          [Length(AModels)]);
        // Refresh the combo with the real local list (keep the typed text;
        // only while the local kind is still the selected one).
        if (ComboExecutor.ItemIndex >= 0) and
           (TExecutorKind(ComboExecutor.ItemIndex) = ekOllama) then
        begin
          LTyped := ComboModel.Text;
          ComboModel.Items.BeginUpdate;
          try
            for LIndex := 0 to High(AModels) do
              if ComboModel.Items.IndexOf(AModels[LIndex]) < 0 then
                ComboModel.Items.Add(AModels[LIndex]);
          finally
            ComboModel.Items.EndUpdate;
          end;
          ComboModel.Text := LTyped;
        end;
      end);
    Exit;
  end;
  LPath := _EffectiveCliPath;
  if LPath = '' then
  begin
    LabelTestStatus.Caption := 'No AI CLI found — install Claude Code or set the path.';
    Exit;
  end;
  ButtonTestConnection.Enabled := False;
  LabelTestStatus.Caption := 'Testing...';
  // Re-check auth opportunistically — "Test CLI" is the natural "did my login
  // work?" click right after the console login flow finishes.
  _RefreshLoginState(LKind);
  // TProcessRunner.Run MUST run off the IDE main thread (it would otherwise freeze the
  // IDE); the result is marshalled back via Queue. --version is a free, fast
  // liveness ping for the CLI. The queued callback is guarded by FAlive so a
  // closed Options dialog (freed frame) can't crash on a dead control.
  LAlive := FAlive;
  TThread.CreateAnonymousThread(
    procedure
    var
      LRes: TToolProcessResult;
      LMsg, LOut: string;
      LSp: Integer;
      LModels: TArray<string>;
    begin
      LRes := TProcessRunner.Run(LPath, '--version', '', '', 8000);
      LOut := Trim(LRes.StdOut);
      LSp := Pos(' ', LOut);
      if LSp > 1 then
        LOut := Copy(LOut, 1, LSp - 1); // first token = the version number
      // STANDARD Test contract: the button also refreshes the model list when
      // the provider exposes a REAL source. Codex: the CLI's own per-account
      // catalog cache ($CODEX_HOME\models_cache.json — no process spawn, and
      // it reflects what the logged plan actually accepts). Ollama does the
      // same via /api/tags; Claude/Copilot/Gemini publish no list, so their
      // curated seed + the "+" button remain the source (no false promise).
      SetLength(LModels, 0);
      if (LKind = ekCodex) and LRes.Ok then
        LModels := LoadCodexCachedModels;
      if LRes.Ok and (Length(LModels) > 0) then
        LMsg := Format('Connected %s - %d model(s) on your account',
          [LOut, Length(LModels)])
      else if LRes.Ok then
        LMsg := 'Connected ' + LOut
      else if LRes.Outcome = poSpawnError then
        LMsg := 'Failed (bad path?)'
      else if LRes.Outcome = poTimedOut then
        LMsg := 'Failed (timeout)'
      else
        LMsg := 'Failed (exit ' + IntToStr(LRes.ExitCode) + ')';
      TThread.Queue(nil,
        procedure
        var
          LIndex: Integer;
          LTyped: string;
        begin
          if not LAlive.IsAlive then
            Exit; // frame destroyed while the test ran — nothing to update
          LabelTestStatus.Caption := LMsg;
          ButtonTestConnection.Enabled := True;
          // Merge the discovered list into the combo AND models.json (so the
          // chat header selector sees it too) — only while the tested kind is
          // still the selected one (stale-guard, same as the Ollama path).
          if (Length(LModels) > 0) and (ComboExecutor.ItemIndex >= 0) and
             (TExecutorKind(ComboExecutor.ItemIndex) = LKind) then
          begin
            LTyped := ComboModel.Text;
            ComboModel.Items.BeginUpdate;
            try
              for LIndex := 0 to High(LModels) do
                if ComboModel.Items.IndexOf(LModels[LIndex]) < 0 then
                begin
                  ComboModel.Items.Add(LModels[LIndex]);
                  TExecutorModels.AddModelForKind(LKind, LModels[LIndex]);
                end;
            finally
              ComboModel.Items.EndUpdate;
            end;
            ComboModel.Text := LTyped;
          end;
        end);
    end).Start;
end;

// Folder of the active project (where its .mcp.json lives) — the cwd `mcp list`
// needs to see the project-scoped aefos server. '' when no project is open.
function _ActiveProjectDir: string;
var
  LSvc: IOTAModuleServices;
  LGroup: IOTAProjectGroup;
begin
  Result := '';
  if Supports(BorlandIDEServices, IOTAModuleServices, LSvc) then
  begin
    LGroup := LSvc.MainProjectGroup;
    if Assigned(LGroup) and Assigned(LGroup.ActiveProject) then
      Result := ExtractFilePath(LGroup.ActiveProject.FileName);
  end;
end;

procedure TAefosChatOptionsFrame.ButtonTestMcpClick(Sender: TObject);
var
  LPath, LDir, LUpsell, LBridge: string;
  LAlive: IAliveToken;
  LKind: TExecutorKind;
begin
  LKind := ekClaude;
  if ComboExecutor.ItemIndex >= 0 then
    LKind := TExecutorKind(ComboExecutor.ItemIndex);
  // Local models (Phase D): the shipped AefosAgent.exe speaks the aefos MCP
  // natively over the pipe. Test the REAL chain by running it with --mcp-probe
  // (connect -> initialize -> tools/list); success prints "aefos MCP: N tools".
  if LKind = ekOllama then
  begin
    // Honour the optional CLI-path override (same as dispatch) ONLY when it is
    // an Aefos agent binary - the path field is shared across executor kinds,
    // so it can hold a stale foreign CLI (claude/gemini) after a switch; blank
    // or foreign falls back to the bundled/provisioned exe - so Test probes
    // the SAME binary a real run would use.
    LPath := Trim(EditExecutorPath.Text);
    if (LPath <> '') and (not SameText(Copy(ExtractFileName(LPath), 1,
      Length('AefosAgent')), 'AefosAgent')) then
      LPath := '';
    if LPath = '' then
      LPath := IncludeTrailingPathDelimiter(GetEnvironmentVariable('APPDATA')) +
        'Aefos\bin\AefosAgent.exe';
    if not FileExists(LPath) then
    begin
      LabelMcpTestStatus.Caption :=
        'Failed - Aefos agent CLI not found (reinstall Aefos, or set the path).';
      Exit;
    end;
    ButtonTestMcp.Enabled := False;
    LabelMcpTestStatus.Caption := 'Checking...';
    LAlive := FAlive;
    LBridge := LPath; // reuse the captured local for the worker closure
    TThread.CreateAnonymousThread(
      procedure
      var
        LRes: TToolProcessResult;
        LMsg: string;
      begin
        LRes := TProcessRunner.Run(LBridge,
          '--mcp-probe --mcp-pipe aefos-mcp-plugin', '', '', 15000);
        if LRes.Outcome = poSpawnError then
          LMsg := 'Failed (could not start the agent CLI)'
        else if LRes.Outcome = poTimedOut then
          LMsg := 'Failed (timeout)'
        else if Pos('aefos mcp:', LowerCase(LRes.StdOut)) > 0 then
          LMsg := Trim(LRes.StdOut) // "aefos MCP: N tools (server)"
        else
          LMsg := 'Failed - the aefos MCP host did not answer (restart the IDE?)';
        TThread.Queue(nil,
          procedure
          begin
            if not LAlive.IsAlive then
              Exit;
            LabelMcpTestStatus.Caption := LMsg;
            ButtonTestMcp.Enabled := True;
          end);
      end).Start;
    Exit;
  end;
  if LUpsell <> '' then
    ShowMessage(LUpsell);
  if LKind = ekCodex then
  begin
    // Codex reads NO config file for MCP — the dispatcher injects the aefos
    // server per invocation via `-c mcp_servers.*` TOML overrides — so
    // `codex mcp list` (which only reads ~/.codex/config.toml) can NEVER list
    // it: probing it was a guaranteed false negative ("aefos not found in this
    // project", field report 2026-07-08). Test the REAL chain instead: run the
    // bridge exactly as the dispatch does and perform a live MCP initialize
    // handshake (bridge -> named pipe -> in-process server). stdin EOF after
    // the one frame makes the bridge exit cleanly.
    TMCPProvision.EnsureBridge;
    LBridge := TMCPProvision.BridgePath;
    ButtonTestMcp.Enabled := False;
    LabelMcpTestStatus.Caption := 'Checking...';
    LAlive := FAlive;
    TThread.CreateAnonymousThread(
      procedure
      var
        LRes: TToolProcessResult;
        LMsg: string;
      begin
        LRes := TProcessRunner.Run('powershell',
          '-ExecutionPolicy Bypass -NonInteractive -File "' + LBridge +
          '" -Session plugin',
          '{"jsonrpc":"2.0","id":1,"method":"initialize","params":' +
          '{"protocolVersion":"2025-06-18","capabilities":{},' +
          '"clientInfo":{"name":"aefos-options-test","version":"1.0"}}}'#10,
          '', 15000);
        if LRes.Outcome = poSpawnError then
          LMsg := 'Failed (could not start PowerShell)'
        else if LRes.Outcome = poTimedOut then
          LMsg := 'Failed (timeout)'
        else if Pos('"serverinfo"', LowerCase(LRes.StdOut)) > 0 then
          LMsg := 'aefos connected (Codex wires it per run - nothing to configure)'
        else
          LMsg := 'Failed - the aefos MCP host did not answer (restart the IDE?)';
        TThread.Queue(nil,
          procedure
          begin
            if not LAlive.IsAlive then
              Exit; // frame destroyed while the handshake ran
            LabelMcpTestStatus.Caption := LMsg;
            ButtonTestMcp.Enabled := True;
          end);
      end).Start;
    Exit;
  end;
  LPath := _EffectiveCliPath;
  if LPath = '' then
  begin
    LabelMcpTestStatus.Caption := 'No AI CLI found — install Claude Code or set the path.';
    Exit;
  end;
  LDir := _ActiveProjectDir;
  if LDir = '' then
  begin
    LabelMcpTestStatus.Caption := 'Open a project first (the check runs in its folder).';
    Exit;
  end;
  // Self-provision before checking, PER EXECUTOR (so `mcp list` reads what the
  // chat dispatch will use): Gemini reads ~/.gemini/settings.json and ignores
  // the project .mcp.json, so it needs TMCPProvision.EnsureGeminiConfig; the others use the
  // project .mcp.json. Both also ensure the bridge — a fresh, installer-less
  // setup configures itself on the first click.
  if LKind = ekGemini then
    TMCPProvision.EnsureGeminiConfig('plugin')
  else
    TMCPProvision.EnsureProjectConfig(LDir, 'plugin');
  ButtonTestMcp.Enabled := False;
  LabelMcpTestStatus.Caption := 'Checking...';
  // Runs `<cli> mcp list` IN the project folder on a worker thread, then looks
  // for "aefos" in the output. NOTE: only Claude's `mcp list` performs a live
  // handshake and prints "Connected"; Copilot/Gemini just LIST the configured
  // server (e.g. "aefos (local)"), so "aefos present" is the success signal
  // for them — requiring the word "connected" was a false-negative. (Codex
  // never reaches here — it is probed via the bridge handshake above.)
  // FAlive guards the queued result against the Options dialog being closed
  // (frame freed) while the up-to-15s `mcp list` is still running.
  LAlive := FAlive;
  TThread.CreateAnonymousThread(
    procedure
    var
      LRes: TToolProcessResult;
      LMsg, LLow: string;
    begin
      LRes := TProcessRunner.Run(LPath, 'mcp list', '', LDir, 15000);
      LLow := LowerCase(LRes.StdOut);
      if LRes.Outcome = poSpawnError then
        LMsg := 'Failed (bad path?)'
      else if LRes.Outcome = poTimedOut then
        LMsg := 'Failed (timeout)'
      else if (Pos('aefos', LLow) > 0) and (Pos('connected', LLow) > 0) then
        LMsg := 'aefos connected'
      else if Pos('aefos', LLow) > 0 then
      begin
        // Listed but no "connected" line. For Claude that means it tried and
        // failed; for the other CLIs (no live status in `mcp list`) it's the
        // normal, healthy output — report it as configured, not as a failure.
        if LKind = ekClaude then
          LMsg := 'aefos listed but not connected'
        else
          LMsg := 'aefos configured (this CLI does not report live status)';
      end
      else
        LMsg := 'aefos not found in this project';
      TThread.Queue(nil,
        procedure
        begin
          if not LAlive.IsAlive then
            Exit; // frame destroyed while `mcp list` ran — nothing to update
          LabelMcpTestStatus.Caption := LMsg;
          ButtonTestMcp.Enabled := True;
        end);
    end).Start;
end;

procedure TAefosChatOptionsFrame._PopulateExecutors;
var
  LKind: TExecutorKind;
  LName: string;
begin
  ComboExecutor.Items.BeginUpdate;
  try
    ComboExecutor.Items.Clear;
    for LKind := Low(TExecutorKind) to High(TExecutorKind) do
    begin
      LName := TProviderRegistry.ExecutorKindDisplayName(LKind);
      ComboExecutor.Items.Add(LName);
    end;
  finally
    ComboExecutor.Items.EndUpdate;
  end;
end;

procedure TAefosChatOptionsFrame._PopulateModels(
  const AKind: TExecutorKind);
var
  LModels: TArray<string>;
  LIndex: Integer;
  LTyped: string;
begin
  // Preserve a value the user typed across an executor switch (BR-3).
  LTyped := ComboModel.Text;
  LModels := TExecutorModels.ModelsForKind(AKind);
  ComboModel.Items.BeginUpdate;
  try
    ComboModel.Items.Clear;
    for LIndex := 0 to High(LModels) do
      ComboModel.Items.Add(LModels[LIndex]);
  finally
    ComboModel.Items.EndUpdate;
  end;
  ComboModel.Text := LTyped;
end;

procedure TAefosChatOptionsFrame.ButtonAddModelClick(Sender: TObject);
var
  LKind: TExecutorKind;
  LModel: string;
begin
  LModel := Trim(ComboModel.Text);
  if (LModel = '') or (ComboExecutor.ItemIndex < 0) then
    Exit;
  // Persist the typed model into models.json for the selected executor, then
  // refresh the list so it shows in the dropdown (and the chat selector). No
  // BPL rebuild needed for a newly shipped model.
  LKind := TExecutorKind(ComboExecutor.ItemIndex);
  TExecutorModels.AddModelForKind(LKind, LModel);
  _PopulateModels(LKind);
  ComboModel.Text := LModel;
end;

procedure TAefosChatOptionsFrame.ButtonRemoveModelClick(Sender: TObject);
var
  LKind: TExecutorKind;
  LModel: string;
begin
  LModel := Trim(ComboModel.Text);
  if (LModel = '') or (ComboExecutor.ItemIndex < 0) then
    Exit;
  // Drop the typed/selected model from models.json (e.g. a typo'd id) and
  // refresh the list — no need to hand-edit the file.
  LKind := TExecutorKind(ComboExecutor.ItemIndex);
  TExecutorModels.RemoveModelForKind(LKind, LModel);
  ComboModel.Text := '';
  _PopulateModels(LKind);
end;

procedure TAefosChatOptionsFrame._PopulateOutputFilters;
begin
  // Index order MUST match TOutputFilterPolicy (ofpStrip=0, ofpRaw=1) so the
  // ItemIndex maps directly to/from the enum via Ord (ADR-289).
  ComboOutputFilter.Items.BeginUpdate;
  try
    ComboOutputFilter.Items.Clear;
    ComboOutputFilter.Items.Add('Strip ANSI escapes (default)');
    ComboOutputFilter.Items.Add('Raw (preserve escapes)');
  finally
    ComboOutputFilter.Items.EndUpdate;
  end;
end;

procedure TAefosChatOptionsFrame._SetInputsEnabled(
  const AEnabled: Boolean);
begin
  ComboExecutor.Enabled := AEnabled;
  EditExecutorPath.Enabled := AEnabled;
  ButtonBrowse.Enabled := AEnabled;
  ComboModel.Enabled := AEnabled;
  EditTimeout.Enabled := AEnabled;
  ComboOutputFilter.Enabled := AEnabled;
  EditOllamaUrl.Enabled := AEnabled;
  LabelNote.Visible := not AEnabled;
end;

procedure TAefosChatOptionsFrame._ApplyExecutorKindUi(
  const AKind: TExecutorKind);
var
  LLocal: Boolean;
begin
  LLocal := AKind = ekOllama;
  // ekOllama drives OUR shipped AefosAgent.exe. The path row is shown as an
  // OPTIONAL OVERRIDE (blank = the bundled, auto-resolved CLI; set it only to
  // point at a custom/dev build) with Browse; Login stays hidden (Ollama has
  // no login). A distinct label + hint make "you don't have to fill this"
  // obvious - unlike the bring-your-own CLIs where the path is expected.
  LabelExecutorPath.Visible := True;
  EditExecutorPath.Visible := True;
  ButtonBrowse.Visible := True;
  ButtonLogin.Visible := not LLocal;
  if LLocal then
  begin
    LabelExecutorPath.Caption := 'Agent CLI path (optional):';
    EditExecutorPath.TextHint := 'blank = bundled Aefos agent CLI';
  end
  else
  begin
    LabelExecutorPath.Caption := 'Executor path:';
    EditExecutorPath.TextHint := '';
  end;
  // The MCP section is BACK for ekOllama (Phase D): the local agent CLI speaks
  // the aefos MCP natively over the pipe, so audit log / server / Test MCP all
  // apply again - Test MCP now runs a real handshake via AefosAgent --mcp-probe.
  LabelMcpHeading.Visible := True;
  LabelAuditCaption.Visible := True;
  EditAuditPath.Visible := True;
  LabelServerCaption.Visible := True;
  EditServerInfo.Visible := True;
  ButtonTestMcp.Visible := True;
  LabelMcpTestStatus.Visible := True;
  // (No longer cleared for ekOllama: the field is now the optional CLI
  // override, so a value the user typed must survive an executor round-trip.)
  // The test button pings the endpoint (not a CLI) for the local kind, and a
  // status line from the previous kind would mislead — reset it.
  if LLocal then
    ButtonTestConnection.Caption := 'Test'
  else
    ButtonTestConnection.Caption := 'Test CLI';
  LabelTestStatus.Caption := '';
  // Same for the MCP probe: its result is per-executor (Codex is handshake-
  // probed, the others via `mcp list`), so a stale verdict would mislead.
  LabelMcpTestStatus.Caption := '';
  // Reflect the new CLI's auth state on the Login button (async, guarded).
  _RefreshLoginState(AKind);
  // The download link always targets the SELECTED executor (the fallback for the
  // CLIs Aefos does NOT bundle — Claude/Copilot). A kind with no download page
  // hides the link entirely — an invisible link beats a dead one (no click => no
  // empty/broken URL to open).
  LabelDownloadCli.Visible := TExecutorDownloads.DownloadUrlForKind(AKind) <> '';
  // Bring the matching provider tab to front (both stay reachable).
  if LLocal then
    PageProviders.ActivePage := TabOllama
  else if AKind = ekGemini then
    PageProviders.ActivePage := TabGemini;
end;

procedure TAefosChatOptionsFrame.LoadFrom(
  const ABinding: TOptionsConfigBinding);
var
  LState: TOptionsEditState;
begin
  FLoading := True;
  try
  _PopulateExecutors;
  LState := ABinding.State;
  ComboExecutor.ItemIndex := Ord(LState.Executor);
  EditExecutorPath.Text := LState.ExecutorPath;
  EditOllamaUrl.Text := LState.OllamaBaseUrl;
  _ApplyExecutorKindUi(LState.Executor);
  // Populate the list, then pick the model PER EXECUTOR: prefer the model
  // remembered for this kind; fall back to the persisted single Model (first
  // run / migration), then the first suggestion. A model that is not in the
  // suggestions is kept verbatim (BR-3).
  _PopulateModels(LState.Executor);
  FModelKind := LState.Executor;
  ComboModel.Text := TExecutorModels.SelectedModelForKind(LState.Executor);
  if ComboModel.Text = '' then
    ComboModel.Text := LState.Model;
  if (ComboModel.Text = '') and (ComboModel.Items.Count > 0) then
    ComboModel.Text := ComboModel.Items[0];
  EditApiKey.Text := TExecutorApiKeys.ApiKeyForKind(LState.Executor);
  EditTimeout.Text := IntToStr(LState.TimeoutSeconds);
  // (login-state probe already ran via _ApplyExecutorKindUi above)
  _PopulateOutputFilters;
  ComboOutputFilter.ItemIndex := Ord(LState.OutputFilter);
  _SetInputsEnabled(ABinding.HasActiveProject);
  // MCP section: read-only info about the in-process MCP server.
  EditAuditPath.Text := TMCPAuditLog.LogFilePath;
  EditServerInfo.Text :=
    'In-process MCP server (aefos) - hosted by the plugin; ' +
    'OTA tools exposed to the spawned CLI over a per-dispatch named pipe.';
  finally
    FLoading := False;
  end;
end;

procedure TAefosChatOptionsFrame.StoreTo(
  const ABinding: TOptionsConfigBinding);
var
  LState: TOptionsEditState;
begin
  LState := ABinding.State;
  if ComboExecutor.ItemIndex >= 0 then
  begin
    LState.Executor := TExecutorKind(ComboExecutor.ItemIndex);
    // Remember this executor's model so it is recalled next time (and never
    // leaks to another provider). Config.Model below still holds the CURRENT
    // executor's model — the dispatch reads that.
    TExecutorModels.SetSelectedModelForKind(LState.Executor, ComboModel.Text);
  end;
  LState.ExecutorPath := EditExecutorPath.Text;
  LState.OllamaBaseUrl := Trim(EditOllamaUrl.Text);
  LState.Model := ComboModel.Text;
  // A blank or non-numeric entry defaults to 0 (disabled); negatives clamp to 0.
  LState.TimeoutSeconds := StrToIntDef(Trim(EditTimeout.Text), 0);
  if LState.TimeoutSeconds < 0 then
    LState.TimeoutSeconds := 0;
  if ComboOutputFilter.ItemIndex >= 0 then
    LState.OutputFilter := TOutputFilterPolicy(ComboOutputFilter.ItemIndex);
  ABinding.State := LState;
end;

procedure TAefosChatOptionsFrame.ComboExecutorChange(Sender: TObject);
var
  LNewKind: TExecutorKind;
begin
  // BR-5: the model suggestion list tracks the selected executor.
  if FLoading or (ComboExecutor.ItemIndex < 0) then
    Exit;
  LNewKind := TExecutorKind(ComboExecutor.ItemIndex);
  // Per-executor model memory: stash the model the user had for the kind being
  // LEFT, then recall the one for the kind being entered — so a Claude/Copilot
  // model never carries into Gemini (which would 404). Falls back to the first
  // suggestion when nothing is remembered for the new kind.
  TExecutorModels.SetSelectedModelForKind(FModelKind, ComboModel.Text);
  _PopulateModels(LNewKind);
  ComboModel.Text := TExecutorModels.SelectedModelForKind(LNewKind);
  if (ComboModel.Text = '') and (ComboModel.Items.Count > 0) then
    ComboModel.Text := ComboModel.Items[0];
  FModelKind := LNewKind;
  EditApiKey.Text := TExecutorApiKeys.ApiKeyForKind(LNewKind);
  // Clears both per-executor status labels and re-probes login state too.
  _ApplyExecutorKindUi(LNewKind);
end;

procedure TAefosChatOptionsFrame.EditApiKeyExit(Sender: TObject);
begin
  // Persist the key for the selected executor the moment the field loses focus
  // (incl. when switching executors), so it survives without an explicit Save.
  if ComboExecutor.ItemIndex >= 0 then
    TExecutorApiKeys.SetApiKeyForKind(TExecutorKind(ComboExecutor.ItemIndex), EditApiKey.Text);
end;

procedure TAefosChatOptionsFrame.LabelApiKeyGetLinkClick(Sender: TObject);
begin
  // Open Google AI Studio in the default browser so the user can mint a free
  // Gemini API key (the OAuth "Sign in with Google" flow was retired by Google
  // for individuals — an API key is the working path). Aefos injects the key
  // as GEMINI_API_KEY into the spawned CLI, so no system env var is needed.
  ShellExecute(0, 'open', 'https://aistudio.google.com/apikey',
    nil, nil, SW_SHOWNORMAL);
end;

procedure TAefosChatOptionsFrame.LabelDownloadCliClick(Sender: TObject);
var
  LKind: TExecutorKind;
  LUrl: string;
begin
  // Fallback for the CLIs Aefos does NOT bundle (Claude/Copilot) — this just
  // hands the user off to the SELECTED executor's own official download page,
  // so it never goes stale or carries a passive. Aefos owns no credentials.
  LKind := ekClaude;
  if ComboExecutor.ItemIndex >= 0 then
    LKind := TExecutorKind(ComboExecutor.ItemIndex);
  LUrl := TExecutorDownloads.DownloadUrlForKind(LKind);
  if LUrl = '' then
    Exit;
  ShellExecute(0, 'open', PChar(LUrl), nil, nil, SW_SHOWNORMAL);
end;

procedure TAefosChatOptionsFrame.ButtonBrowseClick(Sender: TObject);
begin
  if EditExecutorPath.Text <> '' then
    OpenDialog.FileName := EditExecutorPath.Text;
  if OpenDialog.Execute then
    EditExecutorPath.Text := OpenDialog.FileName;
end;

end.
