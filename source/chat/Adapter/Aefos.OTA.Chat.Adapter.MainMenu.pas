unit Aefos.OTA.Chat.Adapter.MainMenu;

{
  Adapter for the OTA main-menu surface.
  Registers this BPL's own 'Aefos AI (Chat)' top-level TMenuItem under the
  IDE 'View' menu (unique caption — no cross-BPL coordination) and populates it
  from the canonical DefaultMenuItems list (Open Chat + About).

  maCommandReplicate runs the replicator and renders a Markdown report to the
  WebView2 output panel (_OnCommandReplicate). Its Ctrl+Alt+F11 keyboard binding
  is registered here through IOTAKeyboardServices by AttachToMainMenu, paired
  with the teardown in DetachFromMainMenu. The AgentSuggest Ctrl+Alt+F10 binding
  lives in Adapter.AgentSuggest.
}

interface

uses
  System.SysUtils,
  System.Classes,
  Vcl.Menus,
  Aefos.OTA.Chat.Core.MainMenu,
  Aefos.OTA.Chat.Core.CommandReplicator.Types,
  Aefos.OTA.Chat.UI.OutputPanel.Edge;

const
  // This BPL's OWN top-level menu (under View), with a UNIQUE caption only this
  // BPL ever touches — no cross-BPL coordination, so it can never duplicate. The
  // '(Chat)'/'(Terminal)' suffix keeps the two Aefos menus visually adjacent
  // under View (maintainer decision 2026-06-08; shared-parent model abandoned).
  TopMenuCaption        = 'Aefos AI (Chat)';

type
  TAefosMainMenuAdapter = class
  private
    FReplicatorService: ICommandReplicator;
    FReplicatorSurface: IOutputPanelSurface;
    FShowChat: TShowChatProc;
    FReplicateBindingIndex: Integer;
    procedure _OnCommandReplicate;
    procedure _OnShowChat;
    function _RenderReportMarkdown(const AReport: TReplicationReport): string;
    procedure _AppendSucceeded(const ABuilder: TStringBuilder;
      const ASucceeded: TArray<string>);
    procedure _AppendFailed(const ABuilder: TStringBuilder;
      const AFailures: TArray<TReplicationFailure>);
    procedure _ShowAbout;
    procedure _RegisterKeyboardBindings;
    procedure _UnregisterKeyboardBindings;
  protected
    procedure _Dispatch(const AAction: TMenuAction);
  public
    constructor Create(const AConfig: TMainMenuAdapterConfig);
    destructor Destroy; override;
    procedure AttachToMainMenu;
    procedure DetachFromMainMenu;
    procedure RunCommandReplicate;
  end;

type
  // Sealed static namespace for the main-menu composition-root entry points
  // (were loose interface routines). Never instantiated. Bodies, the
  // GMainMenuAdapter module var and the guarded keyboard-binding teardown
  // (TAefosMainMenuAdapter._UnregisterKeyboardBindings) are byte-frozen
  // (UnloadContract); Register.pas call sites change by class qualification only.
  TAefosMainMenuStaticAdapter = class sealed
  public
    class procedure RegisterSelf(const AConfig: TMainMenuAdapterConfig); static;
    class procedure UnregisterSelf; static;
    class procedure ClearMainMenuSurface; static;
    class procedure RunCommandReplicate; static;
  end;

implementation

uses
  Winapi.Windows,
  Vcl.Dialogs,
  ToolsAPI,
  Aefos.OTA.Chat.UI.AboutForm;

const
  ReplicateShortcutText    = 'Ctrl+Alt+F11';
  ReplicateBindingName     = 'Aefos.CommandReplicate.Run';
  ReplicateBindingDisp     = 'Aefos Save Commands to the AI CLI';

type
  TPaletteHandlerProc = reference to procedure;

  TAefosMenuKeyboardBinding = class(TInterfacedObject, IOTAKeyboardBinding)
  private
    FShortcutText: string;
    FDisplayName: string;
    FName: string;
    FHandler: TPaletteHandlerProc;
    procedure _HandleShortcut(const AContext: IOTAKeyContext;
      AKeyCode: TShortcut; var ABindingResult: TKeyBindingResult);
  public
    constructor Create(const AShortcutText, ADisplayName, AName: string;
      const AHandler: TPaletteHandlerProc);
    function GetBindingType: TBindingType;
    function GetDisplayName: string;
    function GetName: string;
    procedure BindKeyboard(const ABindingServices: IOTAKeyBindingServices);
    procedure AfterSave;
    procedure BeforeSave;
    procedure Destroyed;
    procedure Modified;
  end;

var
  GMainMenuAdapter: TAefosMainMenuAdapter;

{ TAefosMenuKeyboardBinding }

constructor TAefosMenuKeyboardBinding.Create(
  const AShortcutText, ADisplayName, AName: string;
  const AHandler: TPaletteHandlerProc);
begin
  inherited Create;
  if not Assigned(AHandler) then
    raise EArgumentNilException.Create(
      'TAefosMenuKeyboardBinding requires a non-nil handler');
  FShortcutText := AShortcutText;
  FDisplayName := ADisplayName;
  FName := AName;
  FHandler := AHandler;
end;

function TAefosMenuKeyboardBinding.GetBindingType: TBindingType;
begin
  Result := btPartial;
end;

function TAefosMenuKeyboardBinding.GetDisplayName: string;
begin
  Result := FDisplayName;
end;

function TAefosMenuKeyboardBinding.GetName: string;
begin
  Result := FName;
end;

procedure TAefosMenuKeyboardBinding.BindKeyboard(
  const ABindingServices: IOTAKeyBindingServices);
begin
  ABindingServices.AddKeyBinding([TextToShortCut(FShortcutText)],
    _HandleShortcut, nil);
end;

procedure TAefosMenuKeyboardBinding._HandleShortcut(
  const AContext: IOTAKeyContext; AKeyCode: TShortcut;
  var ABindingResult: TKeyBindingResult);
begin
  ABindingResult := krHandled;
  try
    FHandler();
  except
    on E: Exception do
      ShowMessage('Aefos error: ' + E.Message);
  end;
end;

procedure TAefosMenuKeyboardBinding.AfterSave;
begin
end;

procedure TAefosMenuKeyboardBinding.BeforeSave;
begin
end;

procedure TAefosMenuKeyboardBinding.Destroyed;
begin
end;

procedure TAefosMenuKeyboardBinding.Modified;
begin
end;

class procedure TAefosMainMenuStaticAdapter.RegisterSelf(const AConfig: TMainMenuAdapterConfig);
begin
  if Assigned(GMainMenuAdapter) then
    Exit;
  GMainMenuAdapter := TAefosMainMenuAdapter.Create(AConfig);
  GMainMenuAdapter.AttachToMainMenu;
end;

class procedure TAefosMainMenuStaticAdapter.UnregisterSelf;
begin
  if not Assigned(GMainMenuAdapter) then
    Exit;
  GMainMenuAdapter.DetachFromMainMenu;
  FreeAndNil(GMainMenuAdapter);
end;

class procedure TAefosMainMenuStaticAdapter.ClearMainMenuSurface;
begin
  if Assigned(GMainMenuAdapter) then
    Pointer(GMainMenuAdapter.FReplicatorSurface) := nil;
end;

class procedure TAefosMainMenuStaticAdapter.RunCommandReplicate;
begin
  if not Assigned(GMainMenuAdapter) then
    Exit;
  GMainMenuAdapter.RunCommandReplicate;
end;

{ TAefosMainMenuAdapter }

constructor TAefosMainMenuAdapter.Create(const AConfig: TMainMenuAdapterConfig);
begin
  inherited Create;
  if not Assigned(AConfig.ReplicatorService) then
    raise EArgumentNilException.Create('AConfig.ReplicatorService');
  if not Assigned(AConfig.ReplicatorSurface) then
    raise EArgumentNilException.Create('AConfig.ReplicatorSurface');
  FReplicatorService := AConfig.ReplicatorService;
  FReplicatorSurface := AConfig.ReplicatorSurface;
  FShowChat := AConfig.ShowChat;
  FReplicateBindingIndex := -1;
end;

destructor TAefosMainMenuAdapter.Destroy;
begin
  DetachFromMainMenu;
  inherited;
end;

procedure TAefosMainMenuAdapter.AttachToMainMenu;
begin
  // The visible 'Aefos AI (Chat)' menu (Open Chat + About) is built at BPL load
  // by the composition root (Register._InitChatMenuBar), mirroring the Terminal
  // BPL so the menu shows on the Welcome page before any project is open —
  // an explicit, repeated maintainer requirement. This adapter owns ONLY the
  // Ctrl+Alt+F11 replicate keyboard binding, which depends on the executor
  // graph and is therefore registered when the graph first resolves (so it
  // never constructs against a nil replicator). NOTE: the chronic rebuild AV
  // was NOT this menu — it was bindings missing explicit removal (see
  // _UnregisterKeyboardBindings); reverting this menu never fixed anything.
  _RegisterKeyboardBindings;
end;

procedure TAefosMainMenuAdapter.DetachFromMainMenu;
begin
  _UnregisterKeyboardBindings;
end;

procedure TAefosMainMenuAdapter._RegisterKeyboardBindings;
var
  LServices: IOTAKeyboardServices;
  LReplicate: IOTAKeyboardBinding;
begin
  LServices := BorlandIDEServices as IOTAKeyboardServices;
  if not Assigned(LServices) then
    Exit;
  try
    if FReplicateBindingIndex < 0 then
    begin
      LReplicate := TAefosMenuKeyboardBinding.Create(
        ReplicateShortcutText, ReplicateBindingDisp, ReplicateBindingName,
        procedure
        begin
          TAefosMainMenuStaticAdapter.RunCommandReplicate;
        end);
      FReplicateBindingIndex := LServices.AddKeyboardBinding(LReplicate);
    end;
  except
    on E: Exception do
      OutputDebugString(PChar('[Aefos] _RegisterKeyboardBindings Replicate failed: ' + E.Message));
  end;
end;

procedure TAefosMainMenuAdapter._UnregisterKeyboardBindings;
var
  LServices: IOTAKeyboardServices;
begin
  // *** BEFORE CHANGING THIS: read Aefos.OTA.Chat.UnloadContract (the law). ***
  // Explicitly remove the replicate binding (Terminal pattern). The earlier
  // belief that the IDE auto-removes a package's bindings on unload proved
  // WRONG by map forensics (2026-06-11): the IDE destroys the binding object
  // only AFTER the BPL unmaps — TObject.Free then reads the dead VMT (AV at
  // rtl370+100C2) and the aborted unload locks the .bpl (rebuild F2039).
  // Guarded so a binding the IDE already dropped never aborts teardown.
  if (FReplicateBindingIndex >= 0) and
     Supports(BorlandIDEServices, IOTAKeyboardServices, LServices) then
    try
      LServices.RemoveKeyboardBinding(FReplicateBindingIndex);
    except
      on E: Exception do
        OutputDebugString(PChar(
          '[Aefos] MainMenu RemoveKeyboardBinding: ' + E.Message));
    end;
  FReplicateBindingIndex := -1;
end;

procedure TAefosMainMenuAdapter.RunCommandReplicate;
begin
  _Dispatch(maCommandReplicate);
end;

procedure TAefosMainMenuAdapter._AppendSucceeded(
  const ABuilder: TStringBuilder; const ASucceeded: TArray<string>);
var
  LIndex: Integer;
begin
  ABuilder.Append('### Succeeded (').Append(Length(ASucceeded))
    .AppendLine(')');
  if Length(ASucceeded) = 0 then
    ABuilder.AppendLine('_None._')
  else
    for LIndex := 0 to High(ASucceeded) do
      ABuilder.Append('- ').AppendLine(ASucceeded[LIndex]);
end;

procedure TAefosMainMenuAdapter._AppendFailed(
  const ABuilder: TStringBuilder; const AFailures: TArray<TReplicationFailure>);
var
  LIndex: Integer;
  LFailure: TReplicationFailure;
begin
  ABuilder.Append('### Failed (').Append(Length(AFailures))
    .AppendLine(')');
  if Length(AFailures) = 0 then
    ABuilder.AppendLine('_None._')
  else
    for LIndex := 0 to High(AFailures) do
    begin
      LFailure := AFailures[LIndex];
      ABuilder.Append('- **').Append(LFailure.CommandName)
        .Append('**: ').AppendLine(LFailure.Reason);
    end;
end;

function TAefosMainMenuAdapter._RenderReportMarkdown(
  const AReport: TReplicationReport): string;
var
  LBuilder: TStringBuilder;
begin
  LBuilder := TStringBuilder.Create;
  try
    LBuilder.AppendLine('## Replication report');
    LBuilder.AppendLine('');
    LBuilder.Append('Target: `').Append(AReport.TargetRoot).AppendLine('`');
    LBuilder.AppendLine('');
    _AppendSucceeded(LBuilder, AReport.Succeeded);
    LBuilder.AppendLine('');
    _AppendFailed(LBuilder, AReport.Failures);
    Result := LBuilder.ToString;
  finally
    LBuilder.Free;
  end;
end;

procedure TAefosMainMenuAdapter._OnCommandReplicate;
var
  LReport: TReplicationReport;
begin
  try
    LReport := FReplicatorService.Replicate;
  except
    on E: EReplicatorRootUnavailable do
    begin
      ShowMessage('No active project — open a Delphi project first.');
      Exit;
    end;
    on E: Exception do
    begin
      ShowMessage('Aefos replicator error: ' + E.Message);
      Exit;
    end;
  end;
  FReplicatorSurface.Show;
  FReplicatorSurface.Clear;
  FReplicatorSurface.AppendChunk(_RenderReportMarkdown(LReport), stStdout);
  FReplicatorSurface.ReportComplete(0);
  ShowMessage(Format('%d commands saved to %s; %d failed.',
    [Length(LReport.Succeeded), LReport.TargetRoot, Length(LReport.Failures)]));
end;

procedure TAefosMainMenuAdapter._ShowAbout;
begin
  // Branded modal About (logo lockup + support facts from SupportInfo).
  ShowChatAboutDialog;
end;

procedure TAefosMainMenuAdapter._Dispatch(const AAction: TMenuAction);
begin
  case AAction of
    maCommandReplicate:
      try
        _OnCommandReplicate;
      except
        on E: Exception do
          ShowMessage('Aefos error: ' + E.Message);
      end;
    maAbout:
      try
        _ShowAbout;
      except
        on E: Exception do
          ShowMessage('Aefos error: ' + E.Message);
      end;
    maShowChat:
      try
        _OnShowChat;
      except
        on E: Exception do
          ShowMessage('Aefos error: ' + E.Message);
      end;
  end;
end;

procedure TAefosMainMenuAdapter._OnShowChat;
begin
  if Assigned(FShowChat) then
    FShowChat();
end;

initialization

finalization
  // Guarded: an exception escaping finalization aborts the IDE's BPL unload
  // and leaves keyboard bindings / menu items registered against unmapped
  // code (next IDE call faults reading 0x80808078, the FastMM freed-memory
  // sentinel).
  try
    TAefosMainMenuStaticAdapter.UnregisterSelf;
  except // NOSONAR — teardown must never raise.
    on E: Exception do
      OutputDebugString(PChar(
        'Aefos teardown [MainMenu.finalization]: '
        + E.ClassName + ' - ' + E.Message));
  end;

end.
