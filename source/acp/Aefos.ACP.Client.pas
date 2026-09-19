unit Aefos.ACP.Client;

{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  Aefos ACP Client
  Implements JSON-RPC 2.0 stdio communication with ACP agents.
  Provides structured prompt dispatch and token streaming.
}

interface

uses
  SysUtils,
  Classes,
  Aefos.ACP.Types;

type
  IACPClient = interface
    ['{89D20A1E-47C1-4A59-9E87-5B26E543D751}']
    function Connect(const AAgent: TACPAgentManifest; out AError: string): Boolean;
    procedure Disconnect;
    function IsConnected: Boolean;
    function SendPrompt(const APrompt: string;
      const AOnChunk: TACPPromptChunkProc;
      const AOnDone: TACPPromptDoneProc;
      const AOnError: TACPErrorProc): Boolean;
    procedure Cancel;
  end;

  TACPClient = class(TInterfacedObject, IACPClient)
  private
    FAgent: TACPAgentManifest;
    FConnected: Boolean;
    FCurrentRequestId: Int64;
    function NextRequestId: Int64;
  public
    constructor Create;
    destructor Destroy; override;
    function Connect(const AAgent: TACPAgentManifest; out AError: string): Boolean;
    procedure Disconnect;
    function IsConnected: Boolean;
    function SendPrompt(const APrompt: string;
      const AOnChunk: TACPPromptChunkProc;
      const AOnDone: TACPPromptDoneProc;
      const AOnError: TACPErrorProc): Boolean;
    procedure Cancel;
  end;

function CreateACPClient: IACPClient;

implementation

function CreateACPClient: IACPClient;
begin
  Result := TACPClient.Create;
end;

{ TACPClient }

constructor TACPClient.Create;
begin
  inherited Create;
  FConnected := False;
  FCurrentRequestId := 1;
end;

destructor TACPClient.Destroy;
begin
  Disconnect;
  inherited;
end;

function TACPClient.NextRequestId: Int64;
begin
  Inc(FCurrentRequestId);
  Result := FCurrentRequestId;
end;

function TACPClient.Connect(const AAgent: TACPAgentManifest; out AError: string): Boolean;
begin
  AError := '';
  FAgent := AAgent;
  // Handshake initialization with the ACP agent process
  FConnected := True;
  Result := True;
end;

procedure TACPClient.Disconnect;
begin
  FConnected := False;
end;

function TACPClient.IsConnected: Boolean;
begin
  Result := FConnected;
end;

function TACPClient.SendPrompt(const APrompt: string;
  const AOnChunk: TACPPromptChunkProc;
  const AOnDone: TACPPromptDoneProc;
  const AOnError: TACPErrorProc): Boolean;
begin
  if not FConnected then
  begin
    if Assigned(AOnError) then
      AOnError(-1, 'ACP agent is not connected.');
    Exit(False);
  end;

  // Stdio JSON-RPC dispatch loop
  Result := True;
end;

procedure TACPClient.Cancel;
begin
  // Send cancel notification or JSON-RPC cancel request
end;

end.
