unit Aefos.OTA.Chat.UI.Options.ChatFrame;

interface

uses
  System.Classes,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.StdCtrls,
  Vcl.Dialogs,
  Aefos.OTA.Chat.UI.Options.Binding;

type
  IAliveToken = interface
    ['{6F2A1B4C-9D3E-4A77-B0C1-2E8F5A6D9C31}']
    function IsAlive: Boolean;
    procedure Kill;
  end;

  TAefosChatOptionsFrame = class(TFrame)
    LabelHeading: TLabel;
    LabelNote: TLabel;
    GroupBoxExecution: TGroupBox;
    LabelTimeout: TLabel;
    EditTimeout: TEdit;
    LabelOutputFilter: TLabel;
    ComboOutputFilter: TComboBox;
    GroupBoxMCP: TGroupBox;
    LabelAuditCaption: TLabel;
    EditAuditPath: TEdit;
    LabelServerCaption: TLabel;
    EditServerInfo: TEdit;
    ButtonTestMcp: TButton;
    LabelMcpTestStatus: TLabel;
    GroupBoxRequirements: TGroupBox;
    LabelRequirements: TLabel;
    procedure ButtonTestMcpClick(Sender: TObject);
  private
    FAlive: IAliveToken;
    procedure _PopulateOutputFilters;
    procedure _SetInputsEnabled(const AEnabled: Boolean);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure LoadFrom(const ABinding: TOptionsConfigBinding);
    procedure StoreTo(const ABinding: TOptionsConfigBinding);
  end;

implementation

{$R *.dfm}

uses
  System.SysUtils,
  Winapi.Windows,
  Aefos.Tools.Process,
  Aefos.MCP.AuditLog,
  Aefos.MCP.Provision,
  Aefos.OTA.Chat.Core.Dispatcher.Types,
  Aefos.OTA.Chat.Core.SupportInfo;

type
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

{ TAefosChatOptionsFrame }

constructor TAefosChatOptionsFrame.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FAlive := TAliveToken.Create;
  LabelRequirements.Caption := FormatRequirements;
end;

destructor TAefosChatOptionsFrame.Destroy;
begin
  if Assigned(FAlive) then
    FAlive.Kill;
  inherited Destroy;
end;

procedure TAefosChatOptionsFrame._PopulateOutputFilters;
begin
  ComboOutputFilter.Items.BeginUpdate;
  try
    ComboOutputFilter.Items.Clear;
    ComboOutputFilter.Items.Add('Strip ANSI escapes (default)');
    ComboOutputFilter.Items.Add('Raw (preserve escapes)');
  finally
    ComboOutputFilter.Items.EndUpdate;
  end;
end;

procedure TAefosChatOptionsFrame._SetInputsEnabled(const AEnabled: Boolean);
begin
  EditTimeout.Enabled := AEnabled;
  ComboOutputFilter.Enabled := AEnabled;
  LabelNote.Visible := not AEnabled;
end;

procedure TAefosChatOptionsFrame.ButtonTestMcpClick(Sender: TObject);
var
  LBridge: string;
  LAlive: IAliveToken;
begin
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
        LMsg := 'aefos connected (in-process MCP server active)'
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
end;

procedure TAefosChatOptionsFrame.LoadFrom(const ABinding: TOptionsConfigBinding);
var
  LState: TOptionsEditState;
begin
  LState := ABinding.State;
  EditTimeout.Text := IntToStr(LState.TimeoutSeconds);
  _PopulateOutputFilters;
  ComboOutputFilter.ItemIndex := Ord(LState.OutputFilter);
  _SetInputsEnabled(ABinding.HasActiveProject);
  EditAuditPath.Text := TMCPAuditLog.LogFilePath;
  EditServerInfo.Text :=
    'In-process MCP server (aefos) - hosted by the plugin; ' +
    'OTA tools exposed to the spawned CLI over a per-dispatch named pipe.';
  LabelMcpTestStatus.Caption := '';
end;

procedure TAefosChatOptionsFrame.StoreTo(const ABinding: TOptionsConfigBinding);
var
  LState: TOptionsEditState;
begin
  LState := ABinding.State;
  LState.TimeoutSeconds := StrToIntDef(Trim(EditTimeout.Text), 0);
  if LState.TimeoutSeconds < 0 then
    LState.TimeoutSeconds := 0;
  if ComboOutputFilter.ItemIndex >= 0 then
    LState.OutputFilter := TOutputFilterPolicy(ComboOutputFilter.ItemIndex);
  ABinding.State := LState;
end;

end.
