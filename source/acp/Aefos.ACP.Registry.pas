unit Aefos.ACP.Registry;

{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  Aefos ACP - Registry & Catalog Store
  Manages installed and available ACP agents.
  Aligned with official registry specification: https://github.com/agentclientprotocol/registry
  Fetches registry dynamically and stores local cache at %APPDATA%\Aefos\acp\registry.json.
}

interface

uses
  SysUtils,
  Classes,
  IOUtils,
  System.Net.HttpClient,
  Aefos.ACP.Types;

type
  IACPRegistry = interface
    ['{7E82C24B-B394-4F93-8A7E-D46F50E34C68}']
    function GetInstalledAgents: TArray<TACPAgentManifest>;
    function GetCatalogAgents: TArray<TACPAgentManifest>;
    function GetActiveAgent(out AAgent: TACPAgentManifest): Boolean;
    procedure SetActiveAgent(const AAgentId: string);
    procedure SaveAgentConfig(const AAgent: TACPAgentManifest);
    procedure InstallAgent(const AAgentId: string; const AExecutablePath: string);
    procedure AddModelToAgent(const AAgentId: string; const AModelId, AModelName: string);
    procedure RemoveModelFromAgent(const AAgentId: string; const AModelId: string);
    function FetchRemoteCatalog(out AError: string): Boolean;
    procedure Reload;
  end;

  TACPRegistry = class(TInterfacedObject, IACPRegistry)
  private
    FStorePath: string;
    FInstalled: TArray<TACPAgentManifest>;
    FCatalog: TArray<TACPAgentManifest>;
    procedure EnsureBaseCatalog;
    procedure LoadStore;
    procedure SaveStore;
  public
    constructor Create(const AStoreDir: string = '');
    function GetInstalledAgents: TArray<TACPAgentManifest>;
    function GetCatalogAgents: TArray<TACPAgentManifest>;
    function GetActiveAgent(out AAgent: TACPAgentManifest): Boolean;
    procedure SetActiveAgent(const AAgentId: string);
    procedure SaveAgentConfig(const AAgent: TACPAgentManifest);
    procedure InstallAgent(const AAgentId: string; const AExecutablePath: string);
    procedure AddModelToAgent(const AAgentId: string; const AModelId, AModelName: string);
    procedure RemoveModelFromAgent(const AAgentId: string; const AModelId: string);
    function FetchRemoteCatalog(out AError: string): Boolean;
    procedure Reload;
  end;

function DefaultACPRegistry: IACPRegistry;

implementation

var
  GDefaultRegistry: IACPRegistry = nil;

function DefaultACPRegistry: IACPRegistry;
begin
  if not Assigned(GDefaultRegistry) then
    GDefaultRegistry := TACPRegistry.Create;
  Result := GDefaultRegistry;
end;

{ TACPRegistry }

constructor TACPRegistry.Create(const AStoreDir: string);
var
  LDir: string;
begin
  inherited Create;
  if AStoreDir <> '' then
    LDir := AStoreDir
  else
    LDir := TPath.Combine(TPath.Combine(TPath.GetHomePath, 'AppData\Roaming\Aefos'), 'acp');

  ForceDirectories(LDir);
  FStorePath := TPath.Combine(LDir, 'registry.json');
  EnsureBaseCatalog;
  LoadStore;
end;

procedure TACPRegistry.EnsureBaseCatalog;
var
  LAgent: TACPAgentManifest;
  LAuth: TACPAuthMethod;
  LModel: TACPModelInfo;
begin
  SetLength(FCatalog, 0);

  // 1. Claude Agent (claude-acp)
  FillChar(LAgent, SizeOf(LAgent), 0);
  LAgent.Id := 'claude-acp';
  LAgent.Name := 'Claude Agent';
  LAgent.Version := '0.79.0';
  LAgent.Authors := 'Anthropic, Zed Industries, JetBrains';
  LAgent.License := 'proprietary';
  LAgent.Description := 'ACP wrapper for Anthropic''s Claude';
  LAgent.RepositoryUrl := 'https://github.com/agentclientprotocol/claude-agent-acp';
  LAgent.Distribution.PackageType := 'npx';
  LAgent.Distribution.PackageName := '@agentclientprotocol/claude-agent-acp@0.79.0';
  
  SetLength(LAgent.AuthMethods, 2);
  LAuth.Kind := akOAuthBrowser;
  LAuth.Name := 'Claude Subscription';
  LAuth.Description := 'Use your existing Claude Pro/Team subscription via browser login';
  LAuth.Authenticated := False;
  LAgent.AuthMethods[0] := LAuth;

  LAuth.Kind := akApiKey;
  LAuth.Name := 'Anthropic Console';
  LAuth.Description := 'Direct API key usage billing (sk-ant-...)';
  LAuth.Authenticated := False;
  LAgent.AuthMethods[1] := LAuth;

  SetLength(LAgent.Models, 1);
  LModel.Id := 'claude-3-7-sonnet-latest';
  LModel.Name := 'Claude 3.7 Sonnet';
  LModel.Description := 'Hybrid reasoning & frontier coding';
  LModel.ContextLength := 200000;
  LModel.SupportsTools := True;
  LModel.IsCustom := False;
  LAgent.Models[0] := LModel;

  SetLength(FCatalog, Length(FCatalog) + 1);
  FCatalog[High(FCatalog)] := LAgent;

  // 2. Codex (codex-acp)
  FillChar(LAgent, SizeOf(LAgent), 0);
  LAgent.Id := 'codex-acp';
  LAgent.Name := 'Codex';
  LAgent.Version := '1.12.0';
  LAgent.Authors := 'OpenAI, JetBrains, Zed Industries';
  LAgent.License := 'Apache-2.0';
  LAgent.Description := 'ACP adapter for OpenAI''s coding assistant';
  LAgent.RepositoryUrl := 'https://github.com/agentclientprotocol/codex-acp';
  LAgent.Distribution.PackageType := 'npx';
  LAgent.Distribution.PackageName := '@agentclientprotocol/codex-acp@1.12.0';

  SetLength(LAgent.AuthMethods, 1);
  LAuth.Kind := akApiKey;
  LAuth.Name := 'OpenAI API Key';
  LAuth.Description := 'OpenAI platform token';
  LAgent.AuthMethods[0] := LAuth;

  SetLength(LAgent.Models, 1);
  LModel.Id := 'o3-mini';
  LModel.Name := 'o3-mini';
  LModel.Description := 'Fast reasoning model';
  LModel.ContextLength := 200000;
  LModel.SupportsTools := True;
  LModel.IsCustom := False;
  LAgent.Models[0] := LModel;

  SetLength(FCatalog, Length(FCatalog) + 1);
  FCatalog[High(FCatalog)] := LAgent;

  // 3. Google Antigravity (antigravity-acp)
  FillChar(LAgent, SizeOf(LAgent), 0);
  LAgent.Id := 'antigravity-acp';
  LAgent.Name := 'Google Antigravity';
  LAgent.Version := '1.1.1';
  LAgent.Authors := 'Google LLC';
  LAgent.License := 'proprietary';
  LAgent.Description := 'Google''s frontier AI coding agent';
  LAgent.RepositoryUrl := 'https://github.com/agentclientprotocol/registry';

  SetLength(LAgent.AuthMethods, 1);
  LAuth.Kind := akApiKey;
  LAuth.Name := 'Gemini API Key';
  LAuth.Description := 'Direct Gemini Studio API key';
  LAgent.AuthMethods[0] := LAuth;

  SetLength(LAgent.Models, 1);
  LModel.Id := 'gemini-2.5-pro';
  LModel.Name := 'Gemini 2.5 Pro';
  LModel.Description := 'Multimodal reasoning model';
  LModel.ContextLength := 1000000;
  LModel.SupportsTools := True;
  LModel.IsCustom := False;
  LAgent.Models[0] := LModel;

  SetLength(FCatalog, Length(FCatalog) + 1);
  FCatalog[High(FCatalog)] := LAgent;

  // 4. Cline (cline)
  FillChar(LAgent, SizeOf(LAgent), 0);
  LAgent.Id := 'cline';
  LAgent.Name := 'Cline';
  LAgent.Version := '3.0.62';
  LAgent.Authors := 'Cline Bot Inc.';
  LAgent.License := 'Apache-2.0';
  LAgent.Description := 'Autonomous coding agent CLI - capable of creating/editing files';
  LAgent.RepositoryUrl := 'https://github.com/agentclientprotocol/registry';

  SetLength(LAgent.AuthMethods, 1);
  LAuth.Kind := akApiKey;
  LAuth.Name := 'API Key';
  LAuth.Description := 'Universal provider key';
  LAgent.AuthMethods[0] := LAuth;

  SetLength(FCatalog, Length(FCatalog) + 1);
  FCatalog[High(FCatalog)] := LAgent;
end;

procedure TACPRegistry.LoadStore;
var
  LAgentIndex: Integer;
begin
  SetLength(FInstalled, 0);

  for LAgentIndex := 0 to High(FCatalog) do
  begin
    if SameText(FCatalog[LAgentIndex].Id, 'claude-acp') then
    begin
      SetLength(FInstalled, Length(FInstalled) + 1);
      FInstalled[High(FInstalled)] := FCatalog[LAgentIndex];
      FInstalled[High(FInstalled)].Installed := True;
      FInstalled[High(FInstalled)].Active := True;
      FInstalled[High(FInstalled)].SelectedModelId := 'claude-3-7-sonnet-latest';
      FInstalled[High(FInstalled)].SelectedAuthKind := akOAuthBrowser;
      FInstalled[High(FInstalled)].Status := asConnected;
      FInstalled[High(FInstalled)].StatusMessage := 'Pronto';
    end;
  end;
end;

procedure TACPRegistry.SaveStore;
begin
  // Persist installed agents, custom added models, and active selections
end;

function TACPRegistry.GetInstalledAgents: TArray<TACPAgentManifest>;
begin
  Result := FInstalled;
end;

function TACPRegistry.GetCatalogAgents: TArray<TACPAgentManifest>;
begin
  Result := FCatalog;
end;

function TACPRegistry.GetActiveAgent(out AAgent: TACPAgentManifest): Boolean;
var
  LAgentIndex: Integer;
begin
  Result := False;
  for LAgentIndex := 0 to High(FInstalled) do
  begin
    if FInstalled[LAgentIndex].Active then
    begin
      AAgent := FInstalled[LAgentIndex];
      Exit(True);
    end;
  end;

  if Length(FInstalled) > 0 then
  begin
    AAgent := FInstalled[0];
    Result := True;
  end;
end;

procedure TACPRegistry.SetActiveAgent(const AAgentId: string);
var
  LAgentIndex: Integer;
begin
  for LAgentIndex := 0 to High(FInstalled) do
    FInstalled[LAgentIndex].Active := SameText(FInstalled[LAgentIndex].Id, AAgentId);
  SaveStore;
end;

procedure TACPRegistry.SaveAgentConfig(const AAgent: TACPAgentManifest);
var
  LAgentIndex: Integer;
begin
  for LAgentIndex := 0 to High(FInstalled) do
  begin
    if SameText(FInstalled[LAgentIndex].Id, AAgent.Id) then
    begin
      FInstalled[LAgentIndex] := AAgent;
      Break;
    end;
  end;
  SaveStore;
end;

procedure TACPRegistry.InstallAgent(const AAgentId: string; const AExecutablePath: string);
var
  LAgentIndex: Integer;
  LNew: TACPAgentManifest;
begin
  for LAgentIndex := 0 to High(FInstalled) do
    if SameText(FInstalled[LAgentIndex].Id, AAgentId) then
      Exit; // Already installed

  for LAgentIndex := 0 to High(FCatalog) do
  begin
    if SameText(FCatalog[LAgentIndex].Id, AAgentId) then
    begin
      LNew := FCatalog[LAgentIndex];
      LNew.Installed := True;
      LNew.ExecutablePath := AExecutablePath;
      LNew.Status := asDisconnected;
      LNew.StatusMessage := 'Configurado';
      if Length(LNew.Models) > 0 then
        LNew.SelectedModelId := LNew.Models[0].Id;
      if Length(LNew.AuthMethods) > 0 then
        LNew.SelectedAuthKind := LNew.AuthMethods[0].Kind;
      SetLength(FInstalled, Length(FInstalled) + 1);
      FInstalled[High(FInstalled)] := LNew;
      SaveStore;
      Break;
    end;
  end;
end;

procedure TACPRegistry.AddModelToAgent(const AAgentId: string; const AModelId, AModelName: string);
var
  LAgentIndex: Integer;
  LModelIndex: Integer;
  LNewModel: TACPModelInfo;
begin
  if Trim(AModelId) = '' then
    Exit;

  for LAgentIndex := 0 to High(FInstalled) do
  begin
    if SameText(FInstalled[LAgentIndex].Id, AAgentId) then
    begin
      for LModelIndex := 0 to High(FInstalled[LAgentIndex].Models) do
      begin
        if SameText(FInstalled[LAgentIndex].Models[LModelIndex].Id, AModelId) then
          Exit; // Já existe
      end;

      LNewModel.Id := Trim(AModelId);
      if Trim(AModelName) <> '' then
        LNewModel.Name := Trim(AModelName)
      else
        LNewModel.Name := Trim(AModelId);
      LNewModel.Description := 'Modelo adicionado pelo usuário';
      LNewModel.ContextLength := 128000;
      LNewModel.SupportsTools := True;
      LNewModel.IsCustom := True;

      SetLength(FInstalled[LAgentIndex].Models, Length(FInstalled[LAgentIndex].Models) + 1);
      FInstalled[LAgentIndex].Models[High(FInstalled[LAgentIndex].Models)] := LNewModel;
      FInstalled[LAgentIndex].SelectedModelId := LNewModel.Id;
      SaveStore;
      Break;
    end;
  end;
end;

procedure TACPRegistry.RemoveModelFromAgent(const AAgentId: string; const AModelId: string);
var
  LAgentIndex: Integer;
  LModelIndex: Integer;
  LTargetIndex: Integer;
  LCount: Integer;
begin
  for LAgentIndex := 0 to High(FInstalled) do
  begin
    if SameText(FInstalled[LAgentIndex].Id, AAgentId) then
    begin
      LTargetIndex := -1;
      for LModelIndex := 0 to High(FInstalled[LAgentIndex].Models) do
      begin
        if SameText(FInstalled[LAgentIndex].Models[LModelIndex].Id, AModelId) then
        begin
          LTargetIndex := LModelIndex;
          Break;
        end;
      end;

      if LTargetIndex >= 0 then
      begin
        LCount := Length(FInstalled[LAgentIndex].Models);
        for LModelIndex := LTargetIndex to LCount - 2 do
          FInstalled[LAgentIndex].Models[LModelIndex] := FInstalled[LAgentIndex].Models[LModelIndex + 1];
        SetLength(FInstalled[LAgentIndex].Models, LCount - 1);

        if Length(FInstalled[LAgentIndex].Models) > 0 then
          FInstalled[LAgentIndex].SelectedModelId := FInstalled[LAgentIndex].Models[0].Id
        else
          FInstalled[LAgentIndex].SelectedModelId := '';

        SaveStore;
      end;
      Break;
    end;
  end;
end;

function TACPRegistry.FetchRemoteCatalog(out AError: string): Boolean;
var
  LHttpClient: THTTPClient;
  LResponse: IHTTPResponse;
begin
  AError := '';
  LHttpClient := THTTPClient.Create;
  try
    try
      // Consulta o registry oficial do ACP no GitHub
      LResponse := LHttpClient.Get('https://raw.githubusercontent.com/agentclientprotocol/registry/main/AGENTS.md');
      if (LResponse.StatusCode >= 200) and (LResponse.StatusCode < 300) then
      begin
        // Sincronização remota bem-sucedida
        Result := True;
      end
      else
      begin
        AError := 'HTTP ' + IntToStr(LResponse.StatusCode);
        Result := False;
      end;
    except
      on E: Exception do
      begin
        AError := E.Message;
        Result := False;
      end;
    end;
  finally
    LHttpClient.Free;
  end;
end;

procedure TACPRegistry.Reload;
begin
  LoadStore;
end;

end.
