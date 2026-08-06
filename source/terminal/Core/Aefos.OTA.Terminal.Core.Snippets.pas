unit Aefos.OTA.Terminal.Core.Snippets;

(*
  3-tier snippet store - ESP-060 / ADR-060-03..05.

  Snippets are grouped in three scopes:
    - ssPersonal : %APPDATA%\ModernDelphiWorks\Aefos.OTA.Terminal\snippets.json (per user).
    - ssProject  : <ProjectPath>\.delphi\snippets\project.json (project-local).
    - ssTeam     : <TeamPath>\.delphi\snippets\team.json (intended git-tracked).

  ProjectPath / TeamPath are injected by the IDE layer (empty = that scope is
  inert). Core never calls ToolsAPI (BR1). Each file persists as a v2 envelope
  { "formatVersion": 2, "snippets": [ { "title","command","tags":[] } ] }. A
  legacy flat array (no formatVersion) is loaded into ssPersonal and migrated
  to v2 only on the next save - never destructively on load (ADR-060-05/BR5).

  The class name and the Snippets property are preserved so existing popup /
  manage-form call sites keep compiling; the new surface is additive
  (ADR-060-03).
*)

interface

uses
  System.JSON, System.Generics.Collections;

type
  /// <summary>Storage scope of a snippet (ADR-060-03).</summary>
  TSnippetScope = (ssPersonal, ssProject, ssTeam);

  TSnippet = class
  private
    FTitle: string;
    FCommand: string;
    FScope: TSnippetScope;
    FTags: TArray<string>;
  public
    /// <summary>Personal, untagged snippet - the legacy 2-field shape.</summary>
    constructor Create(const ATitle, ACommand: string); overload;
    /// <summary>Full snippet with explicit scope and tags.</summary>
    constructor Create(const ATitle, ACommand: string;
      const AScope: TSnippetScope; const ATags: TArray<string>); overload;
    property Title: string read FTitle write FTitle;
    property Command: string read FCommand write FCommand;
    property Scope: TSnippetScope read FScope write FScope;
    property Tags: TArray<string> read FTags write FTags;
  end;

  TSnippetManager = class
  private
    FSnippets: TObjectList<TSnippet>;
    FProjectPath: string;
    FTeamPath: string;
    function _GetPersonalPath: string;
    function _ScopeFile(const ARoot, AFileName: string): string;
    function _ScopePath(const AScope: TSnippetScope): string;
    procedure _SeedDefaults;
    procedure _LoadScope(const AScope: TSnippetScope);
    procedure _LoadFromFile(const APath: string; const AScope: TSnippetScope);
    procedure _LoadArray(const AArray: TJSONArray; const AScope: TSnippetScope);
    procedure _SaveScope(const AScope: TSnippetScope);
    function _ReadTags(const AObject: TJSONObject): TArray<string>;
  public
    constructor Create;
    destructor Destroy; override;

    procedure LoadFromJson;
    procedure SaveToJson;
    /// <summary>Re-reads every active scope (Personal always; Project/Team
    /// only when their path is set). Call after changing ProjectPath/TeamPath.</summary>
    procedure Reload;

    /// <summary>Snippets belonging to a single scope, in load order.</summary>
    function SnippetsByScope(const AScope: TSnippetScope): TArray<TSnippet>;

    /// <summary>Merged list of all loaded snippets (every active scope).</summary>
    property Snippets: TObjectList<TSnippet> read FSnippets;
    /// <summary>Project root that hosts project.json (empty = inert).</summary>
    property ProjectPath: string read FProjectPath write FProjectPath;
    /// <summary>Root that hosts the shared team.json (empty = inert).</summary>
    property TeamPath: string read FTeamPath write FTeamPath;
  end;

implementation

uses
  System.SysUtils, System.IOUtils;

const
  CFormatVersion = 2;

{ TSnippet }

constructor TSnippet.Create(const ATitle, ACommand: string);
begin
  Create(ATitle, ACommand, ssPersonal, []);
end;

constructor TSnippet.Create(const ATitle, ACommand: string;
  const AScope: TSnippetScope; const ATags: TArray<string>);
begin
  inherited Create;
  FTitle := ATitle;
  FCommand := ACommand;
  FScope := AScope;
  FTags := ATags;
end;

{ TSnippetManager }

constructor TSnippetManager.Create;
begin
  inherited Create;
  FSnippets := TObjectList<TSnippet>.Create(True);
  FProjectPath := '';
  FTeamPath := '';
  LoadFromJson;
end;

destructor TSnippetManager.Destroy;
begin
  FSnippets.Free;
  inherited;
end;

function TSnippetManager._GetPersonalPath: string;
var
  LAppData: string;
  LDir: string;
begin
  LAppData := GetEnvironmentVariable('APPDATA');
  LDir := TPath.Combine(TPath.Combine(LAppData, 'ModernDelphiWorks'), 'Aefos.OTA.Terminal');
  if not TDirectory.Exists(LDir) then
    TDirectory.CreateDirectory(LDir);
  Result := TPath.Combine(LDir, 'snippets.json');
end;

function TSnippetManager._ScopeFile(const ARoot, AFileName: string): string;
begin
  Result := TPath.Combine(
    TPath.Combine(TPath.Combine(ARoot, '.delphi'), 'snippets'), AFileName);
end;

function TSnippetManager._ScopePath(const AScope: TSnippetScope): string;
begin
  case AScope of
    ssProject:
      if FProjectPath <> '' then
        Result := _ScopeFile(FProjectPath, 'project.json')
      else
        Result := '';
    ssTeam:
      if FTeamPath <> '' then
        Result := _ScopeFile(FTeamPath, 'team.json')
      else
        Result := '';
  else
    Result := _GetPersonalPath;
  end;
end;

function TSnippetManager._ReadTags(const AObject: TJSONObject): TArray<string>;
var
  LValue: TJSONValue;
  LArray: TJSONArray;
  LList: TList<string>;
  LIndex: Integer;
begin
  Result := [];
  LValue := AObject.GetValue('tags');
  if not (LValue is TJSONArray) then
    Exit;
  LArray := TJSONArray(LValue);
  LList := TList<string>.Create;
  try
    for LIndex := 0 to LArray.Count - 1 do
      // .Items[] rather than a bare index: TJSONArray has always had Items, but
      // only made it the DEFAULT property in a release after 10 Seattle, where
      // the bare form reads as "class does not have a default property".
      // Spelling it out works on every version and needs no guard.
      LList.Add(LArray.Items[LIndex].Value);
    Result := LList.ToArray;
  finally
    LList.Free;
  end;
end;

procedure TSnippetManager._LoadArray(const AArray: TJSONArray;
  const AScope: TSnippetScope);
var
  LIndex: Integer;
  LObj: TJSONObject;
begin
  for LIndex := 0 to AArray.Count - 1 do
  begin
    if not (AArray.Items[LIndex] is TJSONObject) then
      Continue;
    LObj := TJSONObject(AArray.Items[LIndex]);
    FSnippets.Add(TSnippet.Create(
      LObj.GetValue<string>('title', ''),
      LObj.GetValue<string>('command', ''),
      AScope,
      _ReadTags(LObj)));
  end;
end;

procedure TSnippetManager._LoadFromFile(const APath: string;
  const AScope: TSnippetScope);
var
  LContent: string;
  LValue: TJSONValue;
  LSnippets: TJSONValue;
begin
  LContent := TFile.ReadAllText(APath);
  if LContent.Trim = '' then
    Exit;

  LValue := TJSONObject.ParseJSONValue(LContent);
  if not Assigned(LValue) then
    Exit;
  try
    if LValue is TJSONArray then
      // Legacy flat array (no formatVersion) - load as this scope (BR5).
      _LoadArray(TJSONArray(LValue), AScope)
    else if LValue is TJSONObject then
    begin
      LSnippets := TJSONObject(LValue).GetValue('snippets');
      if LSnippets is TJSONArray then
        _LoadArray(TJSONArray(LSnippets), AScope);
    end;
  finally
    LValue.Free;
  end;
end;

procedure TSnippetManager._SeedDefaults;
begin
  FSnippets.Add(TSnippet.Create('Git Status', 'git status'));
  FSnippets.Add(TSnippet.Create('Git Log (Recent)', 'git log -n 5 --oneline'));
  FSnippets.Add(TSnippet.Create('Directory List', 'dir'));
  FSnippets.Add(TSnippet.Create('MSBuild Debug', 'msbuild /t:Build /p:Config=Debug'));
  _SaveScope(ssPersonal);
end;

procedure TSnippetManager._LoadScope(const AScope: TSnippetScope);
var
  LPath: string;
begin
  LPath := _ScopePath(AScope);
  if LPath = '' then
    Exit; // inert scope (no path injected)

  if TFile.Exists(LPath) then
    _LoadFromFile(LPath, AScope)
  else if AScope = ssPersonal then
    _SeedDefaults; // first run: seed + persist Personal
end;

procedure TSnippetManager.LoadFromJson;
begin
  FSnippets.Clear;
  _LoadScope(ssPersonal);
  if FProjectPath <> '' then
    _LoadScope(ssProject);
  if FTeamPath <> '' then
    _LoadScope(ssTeam);
end;

procedure TSnippetManager.Reload;
begin
  LoadFromJson;
end;

procedure TSnippetManager._SaveScope(const AScope: TSnippetScope);
var
  LPath: string;
  LDir: string;
  LRoot: TJSONObject;
  LArray: TJSONArray;
  LObj: TJSONObject;
  LTagsArray: TJSONArray;
  LSnippet: TSnippet;
  LTag: string;
begin
  LPath := _ScopePath(AScope);
  if LPath = '' then
    Exit;

  LDir := TPath.GetDirectoryName(LPath);
  if (LDir <> '') and not TDirectory.Exists(LDir) then
    TDirectory.CreateDirectory(LDir);

  LRoot := TJSONObject.Create;
  try
    LRoot.AddPair('formatVersion', TJSONNumber.Create(CFormatVersion));
    LArray := TJSONArray.Create;
    for LSnippet in FSnippets do
    begin
      if LSnippet.Scope <> AScope then
        Continue;
      LObj := TJSONObject.Create;
      LObj.AddPair('title', LSnippet.Title);
      LObj.AddPair('command', LSnippet.Command);
      LTagsArray := TJSONArray.Create;
      for LTag in LSnippet.Tags do
        LTagsArray.Add(LTag);
      LObj.AddPair('tags', LTagsArray);
      LArray.AddElement(LObj);
    end;
    LRoot.AddPair('snippets', LArray);
    TFile.WriteAllText(LPath, LRoot.ToJSON);
  finally
    LRoot.Free;
  end;
end;

procedure TSnippetManager.SaveToJson;
begin
  _SaveScope(ssPersonal);
  if FProjectPath <> '' then
    _SaveScope(ssProject);
  if FTeamPath <> '' then
    _SaveScope(ssTeam);
end;

function TSnippetManager.SnippetsByScope(
  const AScope: TSnippetScope): TArray<TSnippet>;
var
  LList: TList<TSnippet>;
  LSnippet: TSnippet;
begin
  LList := TList<TSnippet>.Create;
  try
    for LSnippet in FSnippets do
      if LSnippet.Scope = AScope then
        LList.Add(LSnippet);
    Result := LList.ToArray;
  finally
    LList.Free;
  end;
end;

end.


