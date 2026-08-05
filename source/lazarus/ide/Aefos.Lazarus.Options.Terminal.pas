unit Aefos.Lazarus.Options.Terminal;

{ Aefos AI - Lazarus edition: the "Terminal" IDE options page.

  The third editor under the "Aefos AI" options group, mirroring the RAD Studio
  plugin's "Terminal" page (Aefos.OTA.Terminal.UI.Options), which configures the
  Terminal's hosted MCP server (enable, session, audit, consent timeout).

  Honest port scoping: the Lazarus terminal engine is not yet wired to a UI, so
  the port has a SINGLE in-process MCP host (Aefos.Lazarus.McpHost) rather than a
  per-terminal one. This page therefore surfaces the one setting that genuinely
  applies on the port today - whether that hosted Aefos MCP server should start
  automatically at IDE load - plus a live read-only status, and a note that the
  full terminal (session/audit/consent-timeout knobs) arrives in a later slice.
  The autostart preference is CONSUMED at package load (RegisterAefosTerminal
  OptionsPage), so ticking it and restarting the IDE actually starts the server.

  ONE BRAIN persistence (owner rule 2026-07-17): the preference lives in the
  SHARED config core (TConfig.McpAutostart) at %APPDATA%\Aefos\.aefos\config.json,
  under the same root as every other Aefos setting - no lazarus-only store. The
  RAD plugin has no MCP-autostart concept (its Terminal MCP host uses a separate
  INI), so this one key is inert on the RAD side but round-trips there safely.

  Built in code (like the sibling pages); the .lfm carries only the empty frame
  root (InitInheritedComponent resource requirement). All literals ASCII - no BOM. }

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
  { The Aefos AI "Terminal" options page (hosted MCP server) - Delphi parity. }
  TAefosTerminalOptionsFrame = class(TAbstractIDEOptionsEditor)
  private
    FBuilt: Boolean;
    FHeaderLabel: TLabel;
    FAutostartCheck: TCheckBox;
    FPipeLabel: TLabel;
    FStatusButton: TButton;
    FStatusLabel: TLabel;
    FSeamNote: TLabel;
    function _ResolveConfigRoot: UnicodeString;
    function _BuildConfigService: IConfig;
    procedure _RefreshStatusClick(ASender: TObject);
    procedure _UpdateStatus;
  public
    function GetTitle: String; override;
    procedure Setup(ADialog: TAbstractOptionsEditorDialog); override;
    procedure ReadSettings(AOptions: TAbstractIDEOptions); override;
    procedure WriteSettings(AOptions: TAbstractIDEOptions); override;
    class function SupportedOptionsClass: TAbstractIDEOptionsClass; override;
  end;

{ Registers the Terminal editor page under the shared Aefos AI group AND honours
  the persisted MCP-autostart preference at IDE load. Called once from the AI
  Chat page's RegisterAefosOptionsPage (which owns the group index). }
procedure RegisterAefosTerminalOptionsPage(const AGroupIndex, APageIndex: Integer);

implementation

uses
  SysUtils,
  LazUTF8,
  LazLoggerBase,
  Aefos.Lazarus.OptionsGroup,  // TAefosIDEOptions (the shared group container)
  Aefos.Lazarus.McpHost,
  Aefos.OTA.Chat.Core.Config;

const
  cXLabel = 12;

function TAefosTerminalOptionsFrame._ResolveConfigRoot: UnicodeString;
var
  LAppData: string;
begin
  LAppData := GetEnvironmentVariable('APPDATA');
  Result := UTF8ToUTF16(LAppData + '\Aefos');
end;

function TAefosTerminalOptionsFrame._BuildConfigService: IConfig;
var
  LResolver: TConfigRootResolver;
begin
  LResolver := Self._ResolveConfigRoot;
  Result := TConfigService.Create(LResolver);
end;

function TAefosTerminalOptionsFrame.GetTitle: String;
begin
  // Mirrors the RAD Studio page caption (Tools > Options > Aefos > Terminal).
  Result := 'Terminal';
end;

procedure TAefosTerminalOptionsFrame._UpdateStatus;
begin
  // Never forces the host singleton into existence just to read state
  // (AefosLazMcpHostExists gate), so opening the page does not start anything.
  if AefosLazMcpHostExists and AefosLazMcpHost.Started then
    FStatusLabel.Caption := 'Running on ' + UTF16ToUTF8(AefosLazMcpHost.PipeName)
  else
    FStatusLabel.Caption := 'Not running';
end;

procedure TAefosTerminalOptionsFrame._RefreshStatusClick(ASender: TObject);
begin
  // Start the hosted server on demand (idempotent, never raises out) then
  // reflect its live state - the honest analog of the RAD "Test MCP" probe.
  try
    AefosLazMcpHost.Start;
  except
    on E: Exception do
      DebugLn('[AefosAI] terminal options: MCP start RAISED '
        + E.ClassName + ': ' + E.Message);
  end;
  _UpdateStatus;
end;

procedure TAefosTerminalOptionsFrame.Setup(ADialog: TAbstractOptionsEditorDialog);
begin
  if FBuilt then
    Exit;
  FBuilt := True;

  FHeaderLabel := TLabel.Create(Self);
  FHeaderLabel.Parent := Self;
  FHeaderLabel.Left := cXLabel;
  FHeaderLabel.Top := 12;
  FHeaderLabel.Caption := 'Aefos MCP server (hosted in-process by the IDE)';

  FAutostartCheck := TCheckBox.Create(Self);
  FAutostartCheck.Parent := Self;
  FAutostartCheck.Left := cXLabel;
  FAutostartCheck.Top := 47;
  FAutostartCheck.Width := 480;
  FAutostartCheck.Caption :=
    'Start the Aefos MCP server automatically when the IDE loads';

  FPipeLabel := TLabel.Create(Self);
  FPipeLabel.Parent := Self;
  FPipeLabel.Left := cXLabel;
  FPipeLabel.Top := 83;
  FPipeLabel.Caption := 'Server status:';

  FStatusLabel := TLabel.Create(Self);
  FStatusLabel.Parent := Self;
  FStatusLabel.Left := cXLabel + 96;
  FStatusLabel.Top := 83;
  FStatusLabel.Caption := 'Not running';

  FStatusButton := TButton.Create(Self);
  FStatusButton.Parent := Self;
  FStatusButton.Left := cXLabel;
  FStatusButton.Top := 111;
  FStatusButton.Width := 140;
  FStatusButton.Caption := 'Start / refresh';
  FStatusButton.OnClick := Self._RefreshStatusClick;

  FSeamNote := TLabel.Create(Self);
  FSeamNote.Parent := Self;
  FSeamNote.Left := cXLabel;
  FSeamNote.Top := 155;
  FSeamNote.WordWrap := True;
  FSeamNote.AutoSize := True;
  FSeamNote.Anchors := [akLeft, akTop, akRight];
  FSeamNote.BorderSpacing.Right := cXLabel;
  FSeamNote.Width := Self.ClientWidth - (cXLabel * 2);
  FSeamNote.Caption :=
    'The Aefos MCP server lets a connected AI CLI drive the IDE. The full ' +
    'Lazarus terminal (session name, audit path and consent timeout) arrives ' +
    'in a later slice; only the autostart preference applies today. Shared with ' +
    'the RAD Studio plugin in %APPDATA%\Aefos\.aefos\config.json.';
end;

procedure TAefosTerminalOptionsFrame.ReadSettings(AOptions: TAbstractIDEOptions);
var
  LConfig: IConfig;
begin
  // Refuse a before-Setup call: FAutostartCheck is created inside Setup, so the
  // assignment two lines down would dereference nil and raise an access violation
  // while the IDE opens its options dialog. Same guard as the sibling pages.
  if not FBuilt then
  begin
    DebugLn('[AefosAI] options(terminal): ReadSettings called BEFORE Setup - skipping');
    Exit;
  end;
  // AOptions is ignored: the preference lives in the SHARED config.json.
  LConfig := _BuildConfigService;
  LConfig.Load;
  FAutostartCheck.Checked := LConfig.Snapshot.McpAutostart;
  _UpdateStatus;
end;

procedure TAefosTerminalOptionsFrame.WriteSettings(AOptions: TAbstractIDEOptions);
var
  LConfig: IConfig;
  LSnap: TConfig;
begin
  // A page that was never built has no edits to save, and FAutostartCheck.Checked
  // would be the nil dereference that told us so.
  if not FBuilt then
  begin
    DebugLn('[AefosAI] options(terminal): WriteSettings called BEFORE Setup - nothing to save');
    Exit;
  end;
  // Read-modify-write: preserve every sibling field, overlay only autostart.
  LConfig := _BuildConfigService;
  LConfig.Load;
  LSnap := LConfig.Snapshot;
  LSnap.McpAutostart := FAutostartCheck.Checked;
  LConfig.Save(LSnap);
end;

class function TAefosTerminalOptionsFrame.SupportedOptionsClass: TAbstractIDEOptionsClass;
begin
  Result := TAefosIDEOptions;
end;

type
  { Minimal of-object carrier for the shared config resolver seam - supplies the
    global root without instantiating a TFrame (which would load its .lfm just to
    read a path). Never held past the one Load. }
  TAefosMcpConfigProbe = class
    function Root: UnicodeString;
  end;

function TAefosMcpConfigProbe.Root: UnicodeString;
var
  LAppData: string;
begin
  LAppData := GetEnvironmentVariable('APPDATA');
  Result := UTF8ToUTF16(LAppData + '\Aefos');
end;

{ Load-time autostart consumption. Builds a throwaway config service against the
  global root to read TConfig.McpAutostart (same file the page writes). }
function _McpAutostartWanted: Boolean;
var
  LProbe: TAefosMcpConfigProbe;
  LResolver: TConfigRootResolver;
  LConfig: IConfig;
begin
  LProbe := TAefosMcpConfigProbe.Create;
  try
    LResolver := LProbe.Root;
    LConfig := TConfigService.Create(LResolver);
    LConfig.Load;
    Result := LConfig.Snapshot.McpAutostart;
  finally
    LProbe.Free;
  end;
end;

procedure RegisterAefosTerminalOptionsPage(const AGroupIndex, APageIndex: Integer);
begin
  RegisterIDEOptionsEditor(AGroupIndex, TAefosTerminalOptionsFrame, APageIndex);
  // Honour the persisted autostart preference at load (default False, so a fresh
  // install is byte-identical: nothing starts unless the user opted in). Guarded
  // + idempotent: the IDE keeps loading whatever happens.
  if _McpAutostartWanted then
  begin
    DebugLn('[AefosAI] terminal options: MCP autostart preference = on -> starting host');
    try
      AefosLazMcpHost.Start;
    except
      on E: Exception do
        DebugLn('[AefosAI] terminal options: MCP autostart RAISED '
          + E.ClassName + ': ' + E.Message);
    end;
  end;
end;

{$R *.lfm}

end.
