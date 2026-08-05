unit Aefos.OTA.Terminal.UI.Options;

interface

uses
  System.SysUtils,
  System.Classes,
  Vcl.Controls,
  Vcl.StdCtrls,
  Vcl.Forms,
  ToolsAPI,
  Aefos.OTA.Terminal.MCP.Config;

type
  TTerminalMCPOptionsFrame = class(TFrame)
    LblEnabled:      TLabel;
    ChkEnabled:      TCheckBox;
    LblSession:      TLabel;
    EdtSession:      TEdit;
    LblAuditPath:    TLabel;
    EdtAuditPath:    TEdit;
    BtnOpenAuditDir: TButton;
    LblAuditResolved: TLabel;
    LblConsentTimeout: TLabel;
    EdtConsentTimeout: TEdit;
    BtnTestMcp: TButton;
    LblMcpStatus: TLabel;
    procedure BtnOpenAuditDirClick(Sender: TObject);
    procedure BtnTestMcpClick(Sender: TObject);
  public
    // Set by the owning INTAAddInOptions: applies the current frame edits
    // (save + (re)start the MCP host) so 'Test MCP' reflects the live checkbox
    // instead of only the pre-dialog state.
    OnApply: TProc;
    procedure LoadFrom(const AConfig: TMCPTerminalConfig);
    procedure SaveTo(out AConfig: TMCPTerminalConfig);
  private
    function _ResolvedAuditDir: string;
  end;

  TTerminalMCPOptions = class(TInterfacedObject, INTAAddInOptions)
  private
    FBinding:   TMCPConfigBinding;
    FFrame:     TTerminalMCPOptionsFrame;
    FOnChanged: TProc;
  public
    constructor Create(const ABinding: TMCPConfigBinding;
      const AOnChanged: TProc);
    function GetArea: string;
    function GetCaption: string;
    function GetFrameClass: TCustomFrameClass;
    procedure FrameCreated(AFrame: TCustomFrame);
    function GetHelpContext: Integer;
    function IncludeInIDEInsight: Boolean;
    function ValidateContents: Boolean;
    procedure DialogClosed(Accepted: Boolean);
  end;

implementation

{$R *.dfm}

uses
  System.IOUtils,
  Winapi.ShellAPI,
  Winapi.Windows,
  Aefos.MCP.AuditLog;

{ TTerminalMCPOptionsFrame }

function TTerminalMCPOptionsFrame._ResolvedAuditDir: string;
var
  LPath: string;
begin
  LPath := Trim(EdtAuditPath.Text);
  if LPath = '' then
    Result := TMCPAuditLog.LogDir
  else
    Result := TPath.GetDirectoryName(LPath);
end;

procedure TTerminalMCPOptionsFrame.LoadFrom(const AConfig: TMCPTerminalConfig);
begin
  ChkEnabled.Checked  := AConfig.Enabled;
  EdtSession.Text     := AConfig.SessionName;
  EdtAuditPath.Text   := AConfig.AuditPath;
  EdtConsentTimeout.Text := IntToStr(AConfig.ConsentTimeoutSecs);
  LblAuditResolved.Caption := _ResolvedAuditDir;
end;

procedure TTerminalMCPOptionsFrame.SaveTo(out AConfig: TMCPTerminalConfig);
begin
  AConfig.Enabled     := ChkEnabled.Checked;
  AConfig.SessionName := EdtSession.Text;
  AConfig.AuditPath   := EdtAuditPath.Text;
  // Blank / non-numeric / negative -> 0 = wait indefinitely (BR14, D2 block).
  AConfig.ConsentTimeoutSecs := StrToIntDef(Trim(EdtConsentTimeout.Text), 0);
  if AConfig.ConsentTimeoutSecs < 0 then
    AConfig.ConsentTimeoutSecs := 0;
  if AConfig.SessionName = '' then
    AConfig.SessionName := TMCPConfigBinding.DefaultSession;
end;

procedure TTerminalMCPOptionsFrame.BtnOpenAuditDirClick(Sender: TObject);
var
  LDir: string;
begin
  LDir := _ResolvedAuditDir;
  if not TDirectory.Exists(LDir) then
    TDirectory.CreateDirectory(LDir);
  ShellExecute(0, 'explore', PChar(LDir), nil, nil, SW_SHOWNORMAL);
end;

procedure TTerminalMCPOptionsFrame.BtnTestMcpClick(Sender: TObject);
var
  LPipe, LSession: string;
begin
  // Apply the current edits first (save + (re)start the host) so testing right
  // after ticking 'Enable MCP server' actually starts the server. Without this
  // the probe only ever saw the pre-dialog state and reported 'not running'
  // until the user clicked OK and reopened Options.
  if Assigned(OnApply) then
    OnApply;
  LSession := Trim(EdtSession.Text);
  if LSession = '' then
    LSession := TMCPConfigBinding.DefaultSession;
  // When enabled, the MCP server listens on this named pipe. A successful
  // WaitNamedPipe means an instance is up; ERROR_SEM_TIMEOUT = up but busy
  // serving; anything else = nothing listening.
  LPipe := TMCPConfigBinding.PipeNameForSession(LSession);
  if WaitNamedPipe(PChar(LPipe), 1000) then
    LblMcpStatus.Caption := 'MCP server running'
  else if GetLastError = ERROR_SEM_TIMEOUT then
    LblMcpStatus.Caption := 'running (busy)'
  else if not ChkEnabled.Checked then
    LblMcpStatus.Caption := 'not running (MCP server disabled)'
  else
    LblMcpStatus.Caption := 'not running (start failed - pipe busy? restart IDE)';
end;

{ TTerminalMCPOptions }

constructor TTerminalMCPOptions.Create(const ABinding: TMCPConfigBinding;
  const AOnChanged: TProc);
begin
  inherited Create;
  FBinding   := ABinding;
  FOnChanged := AOnChanged;
end;

function TTerminalMCPOptions.GetArea: string;
begin
  Result := 'Aefos';
end;

function TTerminalMCPOptions.GetCaption: string;
begin
  Result := 'Terminal';
end;

function TTerminalMCPOptions.GetFrameClass: TCustomFrameClass;
begin
  Result := TTerminalMCPOptionsFrame;
end;

procedure TTerminalMCPOptions.FrameCreated(AFrame: TCustomFrame);
begin
  FFrame := AFrame as TTerminalMCPOptionsFrame;
  FFrame.LoadFrom(FBinding.Current);
  // Lets 'Test MCP' apply the live edits (save + restart host) before probing —
  // same path as DialogClosed(OK), so testing reflects the current checkbox.
  FFrame.OnApply :=
    procedure
    var
      LConfig: TMCPTerminalConfig;
    begin
      if not Assigned(FFrame) then
        Exit;
      FFrame.SaveTo(LConfig);
      FBinding.Accept(LConfig);
      if Assigned(FOnChanged) then
        FOnChanged;
    end;
end;

function TTerminalMCPOptions.GetHelpContext: Integer;
begin
  Result := 0;
end;

function TTerminalMCPOptions.IncludeInIDEInsight: Boolean;
begin
  Result := True;
end;

function TTerminalMCPOptions.ValidateContents: Boolean;
begin
  Result := True;
end;

procedure TTerminalMCPOptions.DialogClosed(Accepted: Boolean);
var
  LConfig: TMCPTerminalConfig;
begin
  if Accepted then
  begin
    if Assigned(FFrame) then
    begin
      FFrame.SaveTo(LConfig);
      FBinding.Accept(LConfig);
    end;
    if Assigned(FOnChanged) then
      FOnChanged;
  end
  else
    FBinding.Cancel;
end;

end.
