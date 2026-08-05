unit Aefos.OTA.Terminal.MCP.Config;

interface

uses
  System.SysUtils,
  System.IniFiles,
  System.IOUtils;

const
  MCP_DEFAULT_SESSION  = 'terminal';
  MCP_PIPE_NAME_PREFIX = '\\.\pipe\aefos-mcp-';

type
  TMCPTerminalConfig = record
    Enabled: Boolean;
    SessionName: string;
    AuditPath: string;
    // Seconds the MCP worker waits for a consent answer before safe-default
    // Deny (ESP-071 / BR14). 0 = wait indefinitely (documented D2 behaviour).
    ConsentTimeoutSecs: Integer;
  end;

  TMCPConfigBinding = class
  private
    FConfig: TMCPTerminalConfig;
    FIniPath: string;
    procedure _Load;
    procedure _Save;
  public
    constructor Create; overload;
    constructor Create(const AIniPath: string); overload;
    function Current: TMCPTerminalConfig;
    procedure BeginEdit(out AConfig: TMCPTerminalConfig);
    procedure Accept(const AConfig: TMCPTerminalConfig);
    procedure Cancel;
    class function DefaultSession: string;
    class function PipeNameForSession(const ASession: string): string;
  end;

implementation

uses
  Aefos.MCP.OTA.ConsentPolicy;

const
  CSECTION    = 'MCP';
  CKEY_ENABLED = 'Enabled';
  CKEY_SESSION = 'SessionName';
  CKEY_AUDIT   = 'AuditPath';
  CKEY_TIMEOUT = 'ConsentTimeoutSecs';

function _DefaultIniPath: string;
begin
  Result := TPath.Combine(
    TPath.Combine(GetEnvironmentVariable('APPDATA'), 'Aefos'),
    'terminal-mcp.ini');
end;

{ TMCPConfigBinding }

constructor TMCPConfigBinding.Create;
begin
  Create(_DefaultIniPath);
end;

constructor TMCPConfigBinding.Create(const AIniPath: string);
begin
  inherited Create;
  FIniPath := AIniPath;
  _Load;
end;

procedure TMCPConfigBinding._Load;
var
  LIni: TIniFile;
begin
  FConfig.Enabled            := False;
  FConfig.SessionName        := MCP_DEFAULT_SESSION;
  FConfig.AuditPath          := '';
  FConfig.ConsentTimeoutSecs := MCP_DEFAULT_CONSENT_TIMEOUT_SECS;
  if not TFile.Exists(FIniPath) then
    Exit;
  LIni := TIniFile.Create(FIniPath);
  try
    FConfig.Enabled     := LIni.ReadBool(CSECTION, CKEY_ENABLED, False);
    FConfig.SessionName := LIni.ReadString(CSECTION, CKEY_SESSION, MCP_DEFAULT_SESSION);
    FConfig.AuditPath   := LIni.ReadString(CSECTION, CKEY_AUDIT, '');
    FConfig.ConsentTimeoutSecs := LIni.ReadInteger(CSECTION, CKEY_TIMEOUT,
      MCP_DEFAULT_CONSENT_TIMEOUT_SECS);
    if FConfig.SessionName = '' then
      FConfig.SessionName := MCP_DEFAULT_SESSION;
    // Negative is meaningless; fall back to 0 = indefinite (BR14).
    if FConfig.ConsentTimeoutSecs < 0 then
      FConfig.ConsentTimeoutSecs := 0;
  finally
    LIni.Free;
  end;
end;

procedure TMCPConfigBinding._Save;
var
  LIni: TIniFile;
  LDir: string;
begin
  LDir := TPath.GetDirectoryName(FIniPath);
  if (LDir <> '') and not TDirectory.Exists(LDir) then
    TDirectory.CreateDirectory(LDir);
  LIni := TIniFile.Create(FIniPath);
  try
    LIni.WriteBool(CSECTION, CKEY_ENABLED, FConfig.Enabled);
    LIni.WriteString(CSECTION, CKEY_SESSION, FConfig.SessionName);
    LIni.WriteString(CSECTION, CKEY_AUDIT, FConfig.AuditPath);
    LIni.WriteInteger(CSECTION, CKEY_TIMEOUT, FConfig.ConsentTimeoutSecs);
  finally
    LIni.Free;
  end;
end;

function TMCPConfigBinding.Current: TMCPTerminalConfig;
begin
  Result := FConfig;
end;

procedure TMCPConfigBinding.BeginEdit(out AConfig: TMCPTerminalConfig);
begin
  AConfig := FConfig;
end;

procedure TMCPConfigBinding.Accept(const AConfig: TMCPTerminalConfig);
begin
  FConfig := AConfig;
  _Save;
end;

procedure TMCPConfigBinding.Cancel;
begin
  // no-op: no uncommitted state to discard
end;

class function TMCPConfigBinding.DefaultSession: string;
begin
  Result := MCP_DEFAULT_SESSION;
end;

class function TMCPConfigBinding.PipeNameForSession(const ASession: string): string;
begin
  Result := MCP_PIPE_NAME_PREFIX + ASession;
end;

end.
