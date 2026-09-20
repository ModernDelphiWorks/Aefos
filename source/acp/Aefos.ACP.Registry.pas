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
  {$IFDEF FPC}
  Aefos.Compat.IO,
  Aefos.Compat.Json,
  {$ELSE}
  System.IOUtils,
  System.JSON,
  {$ENDIF}
  Aefos.Compat.Http,
  Aefos.ACP.Types;

type
  TACPRegistryChangeEvent = procedure of object;

  IACPRegistry = interface
    ['{7E82C24B-B394-4F93-8A7E-D46F50E34C68}']
    function GetInstalledAgents: TArray<TACPAgentManifest>;
    function GetCatalogAgents: TArray<TACPAgentManifest>;
    function GetActiveAgent(out AAgent: TACPAgentManifest): Boolean;
    procedure SetActiveAgent(const AAgentId: string);
    procedure SetActiveModel(const AModelId: string);
    procedure SaveAgentConfig(const AAgent: TACPAgentManifest);
    procedure InstallAgent(const AAgentId: string; const AExecutablePath: string);
    procedure UninstallAgent(const AAgentId: string);
    procedure AddModelToAgent(const AAgentId: string; const AModelId, AModelName: string);
    procedure RemoveModelFromAgent(const AAgentId: string; const AModelId: string);
    function FetchRemoteCatalog(out AError: string): Boolean;
    procedure Reload;
    procedure RegisterChangeListener(AListener: TACPRegistryChangeEvent);
    procedure UnregisterChangeListener(AListener: TACPRegistryChangeEvent);
  end;

  TACPRegistry = class(TInterfacedObject, IACPRegistry)
  private
    FStorePath: string;
    FCatalogCachePath: string;
    FInstalled: TArray<TACPAgentManifest>;
    FCatalog: TArray<TACPAgentManifest>;
    FListeners: TArray<TACPRegistryChangeEvent>;
    procedure EnsureBaseCatalog;
    procedure LoadCatalogFromCache;
    procedure LoadStore;
    procedure SaveStore;
    procedure NotifyChange;
  public
    constructor Create(const AStoreDir: string = '');
    function GetInstalledAgents: TArray<TACPAgentManifest>;
    function GetCatalogAgents: TArray<TACPAgentManifest>;
    function GetActiveAgent(out AAgent: TACPAgentManifest): Boolean;
    procedure SetActiveAgent(const AAgentId: string);
    procedure SetActiveModel(const AModelId: string);
    procedure SaveAgentConfig(const AAgent: TACPAgentManifest);
    procedure InstallAgent(const AAgentId: string; const AExecutablePath: string);
    procedure UninstallAgent(const AAgentId: string);
    procedure AddModelToAgent(const AAgentId: string; const AModelId, AModelName: string);
    procedure RemoveModelFromAgent(const AAgentId: string; const AModelId: string);
    function FetchRemoteCatalog(out AError: string): Boolean;
    procedure Reload;
    procedure RegisterChangeListener(AListener: TACPRegistryChangeEvent);
    procedure UnregisterChangeListener(AListener: TACPRegistryChangeEvent);
  end;

function DefaultACPRegistry: IACPRegistry;
function SanitizeModelId(const AId: string): string;

implementation

var
  GDefaultRegistry: IACPRegistry = nil;

function SanitizeModelId(const AId: string): string;
var
  I: Integer;
  LPrevDash: Boolean;
  C: Char;
begin
  Result := '';
  LPrevDash := False;
  for I := 1 to Length(AId) do
  begin
    C := AId[I];
    if CharInSet(C, [' ', #9, #10, #13, '_']) then
      C := '-';
    if C = '-' then
    begin
      if not LPrevDash and (Result <> '') then
      begin
        Result := Result + '-';
        LPrevDash := True;
      end;
    end
    else
    begin
      Result := Result + C;
      LPrevDash := False;
    end;
  end;
  while (Result <> '') and (Result[Length(Result)] = '-') do
    Delete(Result, Length(Result), 1);
end;

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
  LLegacyDir: string;
begin
  inherited Create;
  if AStoreDir <> '' then
    LDir := AStoreDir
  else
  begin
    LDir := TPath.Combine(TPath.Combine(TPath.GetHomePath, 'Aefos'), 'acp');
    // Migrate from legacy nested AppData path if needed
    LLegacyDir := TPath.Combine(TPath.Combine(TPath.GetHomePath, 'AppData\Roaming\Aefos'), 'acp');
    if not TFile.Exists(TPath.Combine(LDir, 'registry.json')) and TFile.Exists(TPath.Combine(LLegacyDir, 'registry.json')) then
    begin
      ForceDirectories(LDir);
      TFile.Copy(TPath.Combine(LLegacyDir, 'registry.json'), TPath.Combine(LDir, 'registry.json'), True);
    end;
  end;

  ForceDirectories(LDir);
  FStorePath := TPath.Combine(LDir, 'registry.json');
  FCatalogCachePath := TPath.Combine(LDir, 'catalog_cache.json');
  EnsureBaseCatalog;
  LoadCatalogFromCache;
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

  SetLength(LAgent.Models, 5);
  LModel.Id := 'sonnet';
  LModel.Name := 'Claude Sonnet';
  LModel.Description := 'Fast, frontier coding and reasoning';
  LModel.ContextLength := 200000;
  LModel.SupportsTools := True;
  LModel.IsCustom := False;
  LAgent.Models[0] := LModel;

  LModel.Id := 'opus';
  LModel.Name := 'Claude Opus';
  LModel.Description := 'Deep analysis and complex reasoning';
  LModel.ContextLength := 200000;
  LModel.SupportsTools := True;
  LModel.IsCustom := False;
  LAgent.Models[1] := LModel;

  LModel.Id := 'haiku';
  LModel.Name := 'Claude Haiku';
  LModel.Description := 'Lightweight, rapid response model';
  LModel.ContextLength := 200000;
  LModel.SupportsTools := True;
  LModel.IsCustom := False;
  LAgent.Models[2] := LModel;

  LModel.Id := 'claude-sonnet-4-6';
  LModel.Name := 'Claude Sonnet 4.6';
  LModel.Description := 'Canonical Anthropic Sonnet model';
  LModel.ContextLength := 200000;
  LModel.SupportsTools := True;
  LModel.IsCustom := False;
  LAgent.Models[3] := LModel;

  LModel.Id := 'claude-opus-4-7';
  LModel.Name := 'Claude Opus 4.7';
  LModel.Description := 'Canonical Anthropic Opus model';
  LModel.ContextLength := 200000;
  LModel.SupportsTools := True;
  LModel.IsCustom := False;
  LAgent.Models[4] := LModel;

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

  LoadCatalogFromCache;
end;

procedure TACPRegistry.LoadStore;
var
  LContent, LActiveId: string;
  LRoot: TJSONObject;
  LInstalledArr, LModelsArr: TJSONArray;
  LVal, LModelVal: TJSONValue;
  LAgentObj, LModelObj: TJSONObject;
  LAgentId, LModelId: string;
  LAgent: TACPAgentManifest;
  LFoundInCatalog, LHadActive: Boolean;
  LCatalogIdx, I, J, LAuthKindInt: Integer;
  LModel: TACPModelInfo;
begin
  SetLength(FInstalled, 0);

  if TFile.Exists(FStorePath) then
  begin
    try
      LContent := TFile.ReadAllText(FStorePath, TEncoding.UTF8);
      LRoot := TJSONObject.ParseJSONValue(LContent) as TJSONObject;
      if Assigned(LRoot) then
      begin
        try
          if not (LRoot.TryGetValue<string>('activeAgent', LActiveId)) then
            LActiveId := '';

          if (LRoot.TryGetValue<TJSONArray>('installed', LInstalledArr)) and Assigned(LInstalledArr) then
          begin
            for I := 0 to LInstalledArr.Count - 1 do
            begin
              LVal := LInstalledArr.Items[I];
              if not (LVal is TJSONObject) then
                Continue;
              LAgentObj := LVal as TJSONObject;
              if (not (LAgentObj.TryGetValue<string>('id', LAgentId))) or (LAgentId = '') then
                Continue;

              LFoundInCatalog := False;
              for LCatalogIdx := 0 to High(FCatalog) do
              begin
                if SameText(FCatalog[LCatalogIdx].Id, LAgentId) then
                begin
                  LAgent := FCatalog[LCatalogIdx];
                  LFoundInCatalog := True;
                  Break;
                end;
              end;

              if not LFoundInCatalog then
              begin
                FillChar(LAgent, SizeOf(LAgent), 0);
                LAgent.Id := LAgentId;
                LAgent.Name := LAgentId;
              end;

              LAgent.Installed := True;
              LAgentObj.TryGetValue<string>('executablePath', LAgent.ExecutablePath);
              LAgentObj.TryGetValue<string>('selectedModelId', LAgent.SelectedModelId);
              if LAgentObj.TryGetValue<Integer>('selectedAuthKind', LAuthKindInt) then
                LAgent.SelectedAuthKind := TACPAuthKind(LAuthKindInt);

              if (LAgentObj.TryGetValue<TJSONArray>('models', LModelsArr)) and Assigned(LModelsArr) and (LModelsArr.Count > 0) then
              begin
                SetLength(LAgent.Models, 0);
                for J := 0 to LModelsArr.Count - 1 do
                begin
                  LModelVal := LModelsArr.Items[J];
                  if not (LModelVal is TJSONObject) then
                    Continue;
                  LModelObj := LModelVal as TJSONObject;
                  if (not (LModelObj.TryGetValue<string>('id', LModelId))) or (LModelId = '') then
                    Continue;
                  FillChar(LModel, SizeOf(LModel), 0);
                  LModel.Id := LModelId;
                  if (not (LModelObj.TryGetValue<string>('name', LModel.Name))) or (LModel.Name = '') then
                    LModel.Name := LModel.Id;
                  LModelObj.TryGetValue<string>('description', LModel.Description);
                  LModelObj.TryGetValue<Integer>('contextLength', LModel.ContextLength);
                  LModelObj.TryGetValue<Boolean>('supportsTools', LModel.SupportsTools);
                  LModelObj.TryGetValue<Boolean>('isCustom', LModel.IsCustom);
                  SetLength(LAgent.Models, Length(LAgent.Models) + 1);
                  LAgent.Models[High(LAgent.Models)] := LModel;
                end;
              end;

              if LActiveId <> '' then
                LAgent.Active := SameText(LAgent.Id, LActiveId)
              else
                LAgentObj.TryGetValue<Boolean>('active', LAgent.Active);

              LAgent.Status := asConnected;
              LAgent.StatusMessage := 'Ready';

              SetLength(FInstalled, Length(FInstalled) + 1);
              FInstalled[High(FInstalled)] := LAgent;
            end;
          end;
        finally
          LRoot.Free;
        end;
      end;
    except
      SetLength(FInstalled, 0);
    end;
  end;

  if Length(FInstalled) = 0 then
  begin
    for LCatalogIdx := 0 to High(FCatalog) do
    begin
      if SameText(FCatalog[LCatalogIdx].Id, 'claude-acp') then
      begin
        SetLength(FInstalled, 1);
        FInstalled[0] := FCatalog[LCatalogIdx];
        FInstalled[0].Installed := True;
        FInstalled[0].Active := True;
        FInstalled[0].SelectedModelId := 'claude-3-7-sonnet-latest';
        FInstalled[0].SelectedAuthKind := akOAuthBrowser;
        FInstalled[0].Status := asConnected;
        FInstalled[0].StatusMessage := 'Ready';
        Break;
      end;
    end;
    SaveStore;
  end
  else
  begin
    LHadActive := False;
    for I := 0 to High(FInstalled) do
    begin
      if FInstalled[I].Active then
      begin
        LHadActive := True;
        if (FInstalled[I].SelectedModelId = '') and (Length(FInstalled[I].Models) > 0) then
          FInstalled[I].SelectedModelId := FInstalled[I].Models[0].Id;
        Break;
      end;
    end;
    if not LHadActive and (Length(FInstalled) > 0) then
    begin
      FInstalled[0].Active := True;
      if (FInstalled[0].SelectedModelId = '') and (Length(FInstalled[0].Models) > 0) then
        FInstalled[0].SelectedModelId := FInstalled[0].Models[0].Id;
      SaveStore;
    end;
  end;
end;

procedure TACPRegistry.SaveStore;
var
  LRoot: TJSONObject;
  LArr, LModelsArr: TJSONArray;
  LAgentObj, LModelObj: TJSONObject;
  LAgent: TACPAgentManifest;
  LModel: TACPModelInfo;
  LActiveId: string;
begin
  LRoot := TJSONObject.Create;
  try
    LActiveId := '';
    for LAgent in FInstalled do
      if LAgent.Active then
      begin
        LActiveId := LAgent.Id;
        Break;
      end;
    if (LActiveId = '') and (Length(FInstalled) > 0) then
      LActiveId := FInstalled[0].Id;
    LRoot.AddPair('activeAgent', LActiveId);

    LArr := TJSONArray.Create;
    for LAgent in FInstalled do
    begin
      LAgentObj := TJSONObject.Create;
      LAgentObj.AddPair('id', LAgent.Id);
      LAgentObj.AddPair('executablePath', LAgent.ExecutablePath);
      LAgentObj.AddPair('selectedModelId', LAgent.SelectedModelId);
      LAgentObj.AddPair('selectedAuthKind', TJSONNumber.Create(Ord(LAgent.SelectedAuthKind)));
      LAgentObj.AddPair('active', TJSONBool.Create(LAgent.Active));

      LModelsArr := TJSONArray.Create;
      for LModel in LAgent.Models do
      begin
        LModelObj := TJSONObject.Create;
        LModelObj.AddPair('id', LModel.Id);
        LModelObj.AddPair('name', LModel.Name);
        LModelObj.AddPair('description', LModel.Description);
        LModelObj.AddPair('contextLength', TJSONNumber.Create(LModel.ContextLength));
        LModelObj.AddPair('supportsTools', TJSONBool.Create(LModel.SupportsTools));
        LModelObj.AddPair('isCustom', TJSONBool.Create(LModel.IsCustom));
        LModelsArr.AddElement(LModelObj);
      end;
      LAgentObj.AddPair('models', LModelsArr);
      LArr.AddElement(LAgentObj);
    end;
    LRoot.AddPair('installed', LArr);

    ForceDirectories(ExtractFileDir(FStorePath));
    TFile.WriteAllText(FStorePath, LRoot.ToJSON, TEncoding.UTF8);
  finally
    LRoot.Free;
  end;
end;

function TACPRegistry.GetInstalledAgents: TArray<TACPAgentManifest>;
begin
  Result := FInstalled;
end;

function TACPRegistry.GetCatalogAgents: TArray<TACPAgentManifest>;
var
  LCatalogIndex, LInstalledIndex: Integer;
begin
  Result := Copy(FCatalog);
  for LCatalogIndex := 0 to High(Result) do
  begin
    Result[LCatalogIndex].Installed := False;
    for LInstalledIndex := 0 to High(FInstalled) do
    begin
      if SameText(FInstalled[LInstalledIndex].Id, Result[LCatalogIndex].Id) then
      begin
        Result[LCatalogIndex].Installed := True;
        Break;
      end;
    end;
  end;
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
    FInstalled[0].Active := True;
    if (FInstalled[0].SelectedModelId = '') and (Length(FInstalled[0].Models) > 0) then
      FInstalled[0].SelectedModelId := FInstalled[0].Models[0].Id;
    AAgent := FInstalled[0];
    SaveStore;
    Result := True;
  end;
end;

procedure TACPRegistry.SetActiveAgent(const AAgentId: string);
var
  LAgentIndex: Integer;
begin
  for LAgentIndex := 0 to High(FInstalled) do
  begin
    FInstalled[LAgentIndex].Active := SameText(FInstalled[LAgentIndex].Id, AAgentId);
    if FInstalled[LAgentIndex].Active and (FInstalled[LAgentIndex].SelectedModelId = '') and (Length(FInstalled[LAgentIndex].Models) > 0) then
      FInstalled[LAgentIndex].SelectedModelId := FInstalled[LAgentIndex].Models[0].Id;
  end;
  SaveStore;
  NotifyChange;
end;

procedure TACPRegistry.SetActiveModel(const AModelId: string);
var
  LAgentIndex: Integer;
begin
  for LAgentIndex := 0 to High(FInstalled) do
  begin
    if FInstalled[LAgentIndex].Active then
    begin
      FInstalled[LAgentIndex].SelectedModelId := AModelId;
      SaveStore;
      NotifyChange;
      Exit;
    end;
  end;
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
  NotifyChange;
end;

procedure TACPRegistry.InstallAgent(const AAgentId: string; const AExecutablePath: string);
var
  LAgentIndex: Integer;
  LNew: TACPAgentManifest;
  LFound: Boolean;
begin
  for LAgentIndex := 0 to High(FInstalled) do
    if SameText(FInstalled[LAgentIndex].Id, AAgentId) then
      Exit; // Already installed

  LFound := False;
  for LAgentIndex := 0 to High(FCatalog) do
  begin
    if SameText(FCatalog[LAgentIndex].Id, AAgentId) then
    begin
      LNew := FCatalog[LAgentIndex];
      LFound := True;
      Break;
    end;
  end;

  if not LFound then
  begin
    FillChar(LNew, SizeOf(LNew), 0);
    LNew.Id := AAgentId;
    LNew.Name := AAgentId;
  end;

  LNew.Installed := True;
  LNew.ExecutablePath := AExecutablePath;
  LNew.Status := asDisconnected;
  LNew.StatusMessage := 'Configured';

  if Length(LNew.Models) = 0 then
  begin
    SetLength(LNew.Models, 1);
    LNew.Models[0].Id := 'default';
    LNew.Models[0].Name := 'Default Model';
    LNew.Models[0].Description := 'Default model for ' + LNew.Name;
    LNew.Models[0].ContextLength := 128000;
    LNew.Models[0].SupportsTools := True;
    LNew.Models[0].IsCustom := False;
    LNew.SelectedModelId := 'default';
  end
  else if LNew.SelectedModelId = '' then
    LNew.SelectedModelId := LNew.Models[0].Id;

  if Length(LNew.AuthMethods) = 0 then
  begin
    SetLength(LNew.AuthMethods, 1);
    LNew.AuthMethods[0].Kind := akApiKey;
    LNew.AuthMethods[0].Name := 'API Key';
    LNew.AuthMethods[0].Description := 'API Key for ' + LNew.Name;
    LNew.SelectedAuthKind := akApiKey;
  end
  else
    LNew.SelectedAuthKind := LNew.AuthMethods[0].Kind;

  if Length(FInstalled) = 0 then
    LNew.Active := True;

  SetLength(FInstalled, Length(FInstalled) + 1);
  FInstalled[High(FInstalled)] := LNew;
  SaveStore;
  NotifyChange;
end;

procedure TACPRegistry.UninstallAgent(const AAgentId: string);
var
  LAgentIndex, I: Integer;
  LWasActive: Boolean;
begin
  LWasActive := False;
  for LAgentIndex := 0 to High(FInstalled) do
  begin
    if SameText(FInstalled[LAgentIndex].Id, AAgentId) then
    begin
      LWasActive := FInstalled[LAgentIndex].Active;
      for I := LAgentIndex to High(FInstalled) - 1 do
        FInstalled[I] := FInstalled[I + 1];
      SetLength(FInstalled, Length(FInstalled) - 1);
      Break;
    end;
  end;

  if LWasActive and (Length(FInstalled) > 0) then
  begin
    FInstalled[0].Active := True;
    if (FInstalled[0].SelectedModelId = '') and (Length(FInstalled[0].Models) > 0) then
      FInstalled[0].SelectedModelId := FInstalled[0].Models[0].Id;
  end;

  SaveStore;
  NotifyChange;
end;

procedure TACPRegistry.RegisterChangeListener(AListener: TACPRegistryChangeEvent);
var
  I: Integer;
  LMethodA, LMethodB: TMethod;
begin
  LMethodA := TMethod(AListener);
  for I := 0 to High(FListeners) do
  begin
    LMethodB := TMethod(FListeners[I]);
    if (LMethodA.Code = LMethodB.Code) and (LMethodA.Data = LMethodB.Data) then
      Exit;
  end;
  SetLength(FListeners, Length(FListeners) + 1);
  FListeners[High(FListeners)] := AListener;
end;

procedure TACPRegistry.UnregisterChangeListener(AListener: TACPRegistryChangeEvent);
var
  I, J: Integer;
  LMethodA, LMethodB: TMethod;
begin
  LMethodA := TMethod(AListener);
  for I := 0 to High(FListeners) do
  begin
    LMethodB := TMethod(FListeners[I]);
    if (LMethodA.Code = LMethodB.Code) and (LMethodA.Data = LMethodB.Data) then
    begin
      for J := I to High(FListeners) - 1 do
        FListeners[J] := FListeners[J + 1];
      SetLength(FListeners, Length(FListeners) - 1);
      Break;
    end;
  end;
end;

procedure TACPRegistry.NotifyChange;
var
  LCopy: TArray<TACPRegistryChangeEvent>;
  I: Integer;
begin
  if Length(FListeners) = 0 then
    Exit;
  LCopy := Copy(FListeners);
  for I := 0 to High(LCopy) do
  begin
    try
      LCopy[I]();
    except
      // Suppress UI exceptions during listener notification
    end;
  end;
end;

procedure TACPRegistry.AddModelToAgent(const AAgentId: string; const AModelId, AModelName: string);
var
  LAgentIndex: Integer;
  LModelIndex: Integer;
  LNewModel: TACPModelInfo;
  LSanitizedId, LSanitizedName: string;
begin
  LSanitizedId := SanitizeModelId(AModelId);
  if LSanitizedId = '' then
    Exit;

  if Trim(AModelName) <> '' then
    LSanitizedName := SanitizeModelId(AModelName)
  else
    LSanitizedName := LSanitizedId;

  for LAgentIndex := 0 to High(FInstalled) do
  begin
    if SameText(FInstalled[LAgentIndex].Id, AAgentId) then
    begin
      for LModelIndex := 0 to High(FInstalled[LAgentIndex].Models) do
      begin
        if SameText(FInstalled[LAgentIndex].Models[LModelIndex].Id, LSanitizedId) then
        begin
          FInstalled[LAgentIndex].SelectedModelId := LSanitizedId;
          SaveStore;
          NotifyChange;
          Exit;
        end;
      end;

      LNewModel.Id := LSanitizedId;
      LNewModel.Name := LSanitizedName;
      LNewModel.Description := 'User custom model';
      LNewModel.ContextLength := 128000;
      LNewModel.SupportsTools := True;
      LNewModel.IsCustom := True;

      SetLength(FInstalled[LAgentIndex].Models, Length(FInstalled[LAgentIndex].Models) + 1);
      FInstalled[LAgentIndex].Models[High(FInstalled[LAgentIndex].Models)] := LNewModel;
      FInstalled[LAgentIndex].SelectedModelId := LNewModel.Id;
      SaveStore;
      NotifyChange;
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
        NotifyChange;
      end;
      Break;
    end;
  end;
end;

procedure TACPRegistry.LoadCatalogFromCache;
var
  LContent: string;
  LJsonVal: TJSONValue;
  LJsonObj, LAgentObj, LDistObj, LNpxObj: TJSONObject;
  LAgentsArr, LAuthorsArr: TJSONArray;
  I, J, LExistingIndex, LInstIndex: Integer;
  LAgent: TACPAgentManifest;
  LAuthorsStr: string;
begin
  if not TFile.Exists(FCatalogCachePath) then
    Exit;

  try
    LContent := TFile.ReadAllText(FCatalogCachePath, TEncoding.UTF8);
    LJsonVal := TJSONObject.ParseJSONValue(LContent);
    if not (LJsonVal is TJSONObject) then
    begin
      LJsonVal.Free;
      Exit;
    end;

    LJsonObj := TJSONObject(LJsonVal);
    try
      LAgentsArr := LJsonObj.Values['agents'] as TJSONArray;
      if LAgentsArr = nil then
        Exit;

      for I := 0 to LAgentsArr.Count - 1 do
      begin
        if not (LAgentsArr.Items[I] is TJSONObject) then
          Continue;
        LAgentObj := TJSONObject(LAgentsArr.Items[I]);

        FillChar(LAgent, SizeOf(LAgent), 0);
        if LAgentObj.Values['id'] <> nil then
          LAgent.Id := LAgentObj.Values['id'].Value;
        if LAgent.Id = '' then
          Continue;

        if LAgentObj.Values['name'] <> nil then
          LAgent.Name := LAgentObj.Values['name'].Value
        else
          LAgent.Name := LAgent.Id;

        if LAgentObj.Values['version'] <> nil then
          LAgent.Version := LAgentObj.Values['version'].Value;
        if LAgentObj.Values['description'] <> nil then
          LAgent.Description := LAgentObj.Values['description'].Value;
        if LAgentObj.Values['license'] <> nil then
          LAgent.License := LAgentObj.Values['license'].Value;
        if LAgentObj.Values['license_url'] <> nil then
          LAgent.LicenseUrl := LAgentObj.Values['license_url'].Value;
        if LAgentObj.Values['repository'] <> nil then
          LAgent.RepositoryUrl := LAgentObj.Values['repository'].Value;

        LAuthorsArr := LAgentObj.Values['authors'] as TJSONArray;
        if LAuthorsArr <> nil then
        begin
          LAuthorsStr := '';
          for J := 0 to LAuthorsArr.Count - 1 do
          begin
            if LAuthorsStr <> '' then
              LAuthorsStr := LAuthorsStr + ', ';
            LAuthorsStr := LAuthorsStr + LAuthorsArr.Items[J].Value;
          end;
          LAgent.Authors := LAuthorsStr;
        end;

        LDistObj := LAgentObj.Values['distribution'] as TJSONObject;
        if LDistObj <> nil then
        begin
          if LDistObj.Values['npx'] is TJSONObject then
          begin
            LNpxObj := TJSONObject(LDistObj.Values['npx']);
            LAgent.Distribution.PackageType := 'npx';
            if LNpxObj.Values['package'] <> nil then
              LAgent.Distribution.PackageName := LNpxObj.Values['package'].Value;
          end
          else if LDistObj.Values['uvx'] is TJSONObject then
          begin
            LAgent.Distribution.PackageType := 'uvx';
            if TJSONObject(LDistObj.Values['uvx']).Values['package'] <> nil then
              LAgent.Distribution.PackageName := TJSONObject(LDistObj.Values['uvx']).Values['package'].Value;
          end
          else if LDistObj.Values['binary'] is TJSONObject then
          begin
            LAgent.Distribution.PackageType := 'binary';
            LAgent.Distribution.PackageName := LAgent.Id;
          end;
        end;

        for LInstIndex := 0 to High(FInstalled) do
        begin
          if SameText(FInstalled[LInstIndex].Id, LAgent.Id) then
          begin
            LAgent.Installed := True;
            Break;
          end;
        end;

        LExistingIndex := -1;
        for J := 0 to High(FCatalog) do
        begin
          if SameText(FCatalog[J].Id, LAgent.Id) then
          begin
            LExistingIndex := J;
            Break;
          end;
        end;

        if LExistingIndex >= 0 then
        begin
          FCatalog[LExistingIndex].Version := LAgent.Version;
          FCatalog[LExistingIndex].Description := LAgent.Description;
          FCatalog[LExistingIndex].Authors := LAgent.Authors;
          FCatalog[LExistingIndex].License := LAgent.License;
          FCatalog[LExistingIndex].RepositoryUrl := LAgent.RepositoryUrl;
          FCatalog[LExistingIndex].Distribution := LAgent.Distribution;
          FCatalog[LExistingIndex].Installed := LAgent.Installed;
        end
        else
        begin
          SetLength(FCatalog, Length(FCatalog) + 1);
          FCatalog[High(FCatalog)] := LAgent;
        end;
      end;
    finally
      LJsonObj.Free;
    end;
  except
    // Non-critical cache parsing
  end;
end;

function TACPRegistry.FetchRemoteCatalog(out AError: string): Boolean;
var
  LStatusCode: Integer;
  LContent: string;
begin
  AError := '';
  try
    if TAefosHttp.TryGetText('https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json',
      LStatusCode, LContent, AError) then
    begin
      if (LStatusCode >= 200) and (LStatusCode < 300) then
      begin
        TFile.WriteAllText(FCatalogCachePath, LContent, TEncoding.UTF8);
        LoadCatalogFromCache;
        NotifyChange;
        Result := True;
      end
      else
      begin
        AError := 'HTTP ' + IntToStr(LStatusCode);
        Result := False;
      end;
    end
    else
      Result := False;
  except
    on E: Exception do
    begin
      AError := E.Message;
      Result := False;
    end;
  end;
end;

procedure TACPRegistry.Reload;
begin
  LoadStore;
  NotifyChange;
end;

end.
