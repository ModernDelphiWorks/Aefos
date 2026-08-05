unit Aefos.MCP.Tools.VCS;

{
  MCP tool registrar for the IDE-only VCS family — the three things that exist
  ONLY inside the IDE and that a raw terminal can never reach:

    ShowDiffInIDE       -> the IDE's own native diff viewer (no git, no repo)
    GetFileHistory      -> the IDE's own file-history providers (no subprocess),
                           falling back to `git log` when none is registered
    GetDiffOfActiveFile -> the DIRTY editor buffer vs HEAD (`git diff` only ever
                           sees the disk; the IDE sees the unsaved buffer)

  Deliberately NOT here: status / log / branch / blame / commit. Those are plain
  git and already live in Aefos.MCP.Tools.Git (subprocess, MCP.Core) — this unit
  does not duplicate them and does not register Aefos as an IDE VCS provider
  (IOTAVersionControlNotifier is a VENDOR API — you implement it to PLUG a VCS
  into the IDE; it returns no data to a consumer).

  Layering: OTA is confined to Aefos.MCP.OTA.DiffViewService, the diff rendering
  is the headless-tested pure Aefos.MCP.UnifiedDiff, and the committed side comes
  from the existing IMCPGitFacade — no second git facade.

  RULE #1: every tool here is READ/VIEW-ONLY. None declares a Design or Code
  intent and none moves the active module's view; ShowDiffInIDE opens a separate
  diff window, which leaves the Designer/Editor state untouched.
}

interface

uses
  Aefos.MCP.Server,
  Aefos.MCP.GitFacade;

// Registers the IDE-only VCS tool family. AGit backs the HEAD side of
// GetDiffOfActiveFile and the git-log fallback of GetFileHistory; pass the SAME
// facade instance the Git group already uses.
procedure RegisterVCSTools(const AServer: IMCPServer;
  const AGit: IMCPGitFacade);

implementation

uses
  System.SysUtils,
  System.JSON,
  Aefos.MCP.Types,
  Aefos.MCP.UnifiedDiff,
  Aefos.MCP.OTA.DiffViewService;

const
  DEFAULT_HISTORY_ENTRIES = 20;
  DIFF_CONTEXT_LINES      = 3;

function _Schema(const AJson: string): TJSONObject;
begin
  // The server takes ownership of the returned object after RegisterTool.
  Result := TJSONObject.ParseJSONValue(AJson) as TJSONObject;
  if Result = nil then
    Result := TJSONObject.ParseJSONValue('{"type":"object","properties":{}}')
      as TJSONObject;
end;

function _Res(const AContent: string): TMCPToolResult;
begin
  Result := Default(TMCPToolResult);
  Result.Content := AContent;
end;

// Machine-actionable failure: the kebab reason IS the payload the agent keys off
// (same contract as the debug family / the view guard).
function _Err(const AReason: string): TMCPToolResult;
var
  LObj: TJSONObject;
begin
  LObj := TJSONObject.Create;
  try
    LObj.AddPair('error', AReason);
    Result := _Res(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function _ParamStr(const AParams: TJSONObject; const AName: string;
  const ADefault: string): string;
var
  LVal: TJSONValue;
begin
  Result := ADefault;
  if not Assigned(AParams) then
    Exit;
  LVal := AParams.GetValue(AName);
  if LVal is TJSONString then
    Result := TJSONString(LVal).Value;
end;

function _ParamInt(const AParams: TJSONObject; const AName: string;
  const ADefault: Integer): Integer;
var
  LVal: TJSONValue;
begin
  Result := ADefault;
  if not Assigned(AParams) then
    Exit;
  LVal := AParams.GetValue(AName);
  if LVal is TJSONNumber then
    Result := TJSONNumber(LVal).AsInt;
end;

function _ParamBool(const AParams: TJSONObject; const AName: string;
  const ADefault: Boolean): Boolean;
var
  LVal: TJSONValue;
begin
  Result := ADefault;
  if not Assigned(AParams) then
    Exit;
  LVal := AParams.GetValue(AName);
  if LVal is TJSONBool then
    Result := TJSONBool(LVal).AsBoolean;
end;

function _Desc(const AName, ATitle, ADescription: string;
  const ASchema: TJSONObject;
  const AHandler: TMCPToolHandler): TMCPToolDescriptor;
begin
  Result := Default(TMCPToolDescriptor);
  Result.Name := AName;
  Result.Title := ATitle;
  Result.Description := ADescription;
  Result.InputSchema := ASchema;
  Result.Handler := AHandler;
end;

// --- ShowDiffInIDE ----------------------------------------------------------

function _HandleShowDiffInIDE(const AParams: TJSONObject): TMCPToolResult;
var
  LLeft, LRight, LLeftTitle, LRightTitle, LLeftFile, LRightFile: string;
  LReason: string;
begin
  LLeft := _ParamStr(AParams, 'left', '');
  LRight := _ParamStr(AParams, 'right', '');
  if (LLeft = '') and (LRight = '') then
    Exit(_Err('empty-diff'));
  LLeftTitle := _ParamStr(AParams, 'leftTitle', 'Left');
  LRightTitle := _ParamStr(AParams, 'rightTitle', 'Right');
  LLeftFile := _ParamStr(AParams, 'leftFile', '');
  LRightFile := _ParamStr(AParams, 'rightFile', '');
  if DiffShowInIDE(LLeft, LRight, LLeftTitle, LRightTitle, LLeftFile,
    LRightFile, LReason) then
    Result := _Res('{"shown":true}')
  else
    Result := _Res('{"shown":false,"error":' +
      TJSONString.Create(LReason).ToString + '}');
end;

// --- GetFileHistory ---------------------------------------------------------

function _HistoryJson(const AProvider, AFile: string;
  const AEntries: TArray<TIDEHistoryEntry>;
  const AIncludeContent: Boolean): TMCPToolResult;
var
  LObj, LItem: TJSONObject;
  LArr: TJSONArray;
  LFor: Integer;
begin
  LObj := TJSONObject.Create;
  try
    LObj.AddPair('source', 'ide-history-provider');
    LObj.AddPair('provider', AProvider);
    LObj.AddPair('file', AFile);
    LArr := TJSONArray.Create;
    for LFor := 0 to High(AEntries) do
    begin
      LItem := TJSONObject.Create;
      LItem.AddPair('ident', AEntries[LFor].Ident);
      LItem.AddPair('author', AEntries[LFor].Author);
      LItem.AddPair('date', AEntries[LFor].Date);
      LItem.AddPair('comment', AEntries[LFor].Comment);
      LItem.AddPair('style', AEntries[LFor].Style);
      if AIncludeContent then
      begin
        LItem.AddPair('content', AEntries[LFor].Content);
        if AEntries[LFor].Truncated then
          LItem.AddPair('truncated', TJSONBool.Create(True));
      end;
      LArr.AddElement(LItem);
    end;
    LObj.AddPair('revisions', LArr);
    Result := _Res(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

// Fallback when the IDE has no history provider registered: the plain `git log`
// the existing facade already speaks. Same shape, different "source" so the
// agent knows which world it is looking at (no revision CONTENT here).
function _HistoryFromGit(const AGit: IMCPGitFacade;
  const AFile: string; const AMax: Integer): TMCPToolResult;
var
  LCommits: TArray<TGitLogEntry>;
  LError: string;
  LObj, LItem: TJSONObject;
  LArr: TJSONArray;
  LFor, LMax: Integer;
begin
  // "all" (maxEntries <= 0) is the DiffReadFileHistory contract, but the git
  // facade's GetLog rejects a non-positive count with 'invalid-count'. Since
  // most installs have NO history provider, this fallback is the COMMON path —
  // clamp to the default rather than surface an error the agent did not cause.
  LMax := AMax;
  if LMax <= 0 then
    LMax := DEFAULT_HISTORY_ENTRIES;
  if not AGit.GetLog(LMax, LCommits, LError) then
    Exit(_Err(LError));
  LObj := TJSONObject.Create;
  try
    LObj.AddPair('source', 'git-log-fallback');
    LObj.AddPair('file', AFile);
    LObj.AddPair('note', 'No IDE file-history provider is registered; this is ' +
      'repository-wide git log, not per-file history, and carries no revision ' +
      'content.');
    LArr := TJSONArray.Create;
    for LFor := 0 to High(LCommits) do
    begin
      LItem := TJSONObject.Create;
      LItem.AddPair('ident', LCommits[LFor].Hash);
      LItem.AddPair('author', LCommits[LFor].Author);
      LItem.AddPair('date', LCommits[LFor].Date);
      LItem.AddPair('comment', LCommits[LFor].Message);
      LArr.AddElement(LItem);
    end;
    LObj.AddPair('revisions', LArr);
    Result := _Res(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function _HandleGetFileHistory(const AParams: TJSONObject;
  const AGit: IMCPGitFacade): TMCPToolResult;
var
  LFile, LProvider, LResolved, LReason: string;
  LMax: Integer;
  LIncludeContent: Boolean;
  LEntries: TArray<TIDEHistoryEntry>;
begin
  LFile := _ParamStr(AParams, 'file', '');
  if LFile = '' then
    Exit(_Err('file-required'));
  LMax := _ParamInt(AParams, 'maxEntries', DEFAULT_HISTORY_ENTRIES);
  LIncludeContent := _ParamBool(AParams, 'includeContent', False);
  if DiffReadFileHistory(LFile, LMax, LIncludeContent, LEntries, LProvider,
    LResolved, LReason) then
    Exit(_HistoryJson(LProvider, LResolved, LEntries, LIncludeContent));
  if (LReason = 'no-history-provider') or (LReason = 'no-history') then
    Exit(_HistoryFromGit(AGit, LFile, LMax));
  Result := _Err(LReason);
end;

// --- GetDiffOfActiveFile ----------------------------------------------------

function _DiffJson(const AFile, APatch: string; const AShowInIDE: Boolean;
  const AShown: Boolean; const AShowReason: string): TMCPToolResult;
var
  LObj: TJSONObject;
begin
  LObj := TJSONObject.Create;
  try
    LObj.AddPair('file', AFile);
    LObj.AddPair('dirty', TJSONBool.Create(APatch <> ''));
    LObj.AddPair('patch', APatch);
    if AShowInIDE then
    begin
      LObj.AddPair('shownInIDE', TJSONBool.Create(AShown));
      if not AShown then
        LObj.AddPair('showError', AShowReason);
    end;
    Result := _Res(LObj.ToJSON);
  finally
    LObj.Free;
  end;
end;

function _HandleGetDiffOfActiveFile(const AParams: TJSONObject;
  const AGit: IMCPGitFacade): TMCPToolResult;
var
  LUnit, LFile, LBuffer, LHead, LPatch, LReason, LShowReason: string;
  LLeftTitle: string;
  LShow, LShown: Boolean;
begin
  LUnit := _ParamStr(AParams, 'unit', '');
  if LUnit = '' then
  begin
    if not DiffReadActiveSource(LFile, LBuffer, LReason) then
      Exit(_Err(LReason));
  end
  else
    if not DiffReadUnitSource(LUnit, LFile, LBuffer, LReason) then
      Exit(_Err(LReason));
  LLeftTitle := 'HEAD';
  if not AGit.GetFileAtHead(LFile, LHead, LReason) then
  begin
    // A file the agent JUST created is not at HEAD — that is the COMMON case,
    // not an error. `git` would show the whole file as an addition, and our
    // renderer produces exactly that from an empty HEAD side. Only 'not-in-head'
    // degrades this way; a real git failure still surfaces.
    if LReason <> 'not-in-head' then
      Exit(_Err(LReason));
    LHead := '';
    LLeftTitle := 'HEAD (new file — not yet committed)';
  end;
  // The LIVE buffer is the "new" side — that is the whole point: `git diff`
  // compares HEAD against the DISK and cannot see the unsaved editor.
  if not TryBuildUnifiedDiff(LHead, LBuffer, 'HEAD:' + LFile,
    'BUFFER:' + LFile, DIFF_CONTEXT_LINES, LPatch, LReason) then
    Exit(_Err(LReason));  // 'diff-too-large' — a refusal, never an exception
  LShow := _ParamBool(AParams, 'showInIDE', False);
  LShown := False;
  LShowReason := '';
  if LShow and (LPatch <> '') then
    LShown := DiffShowInIDE(LHead, LBuffer, LLeftTitle,
      'Editor buffer (unsaved)', LFile, LFile, LShowReason);
  Result := _DiffJson(LFile, LPatch, LShow and (LPatch <> ''), LShown,
    LShowReason);
end;

// --- registration -----------------------------------------------------------

procedure RegisterVCSTools(const AServer: IMCPServer;
  const AGit: IMCPGitFacade);
var
  LGit: IMCPGitFacade;
begin
  if not Assigned(AServer) then
    raise EArgumentNilException.Create('RegisterVCSTools: AServer');
  if not Assigned(AGit) then
    raise EArgumentNilException.Create('RegisterVCSTools: AGit');
  LGit := AGit;

  AServer.RegisterTool(_Desc('ShowDiffInIDE', 'Show diff in the IDE',
    'Opens the IDE''s OWN native diff viewer on two texts ("left" and "right") ' +
    'and returns immediately. Use this INSTEAD of pasting a patch into the ' +
    'chat when you want the user to SEE a change: the user gets the real, ' +
    'side-by-side Delphi diff window. Needs no git and no repository — the two ' +
    'texts are whatever you pass. Optional "leftTitle"/"rightTitle" label the ' +
    'panes and "leftFile"/"rightFile" tell the viewer the real paths. ' +
    'Read-only: it changes no file and does NOT move the Designer/Editor view.',
    _Schema('{"type":"object","properties":{"left":{"type":"string"},' +
      '"right":{"type":"string"},"leftTitle":{"type":"string"},' +
      '"rightTitle":{"type":"string"},"leftFile":{"type":"string"},' +
      '"rightFile":{"type":"string"}},"required":["left","right"]}'),
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := _HandleShowDiffInIDE(AParams);
    end));

  AServer.RegisterTool(_Desc('GetFileHistory', 'Get file history',
    'Revision history of a file straight from the IDE''s OWN version-control ' +
    'provider (no subprocess): ident/author/date/comment per revision, and — ' +
    'with "includeContent":true — the FULL SOURCE of each revision, which lets ' +
    'you diff any past revision against today. "file" is a unit name or a path. ' +
    '"maxEntries" defaults to 20. If this IDE has no history provider ' +
    'registered, the answer falls back to git log (marked ' +
    '"source":"git-log-fallback", repository-wide, no content). Read-only.',
    _Schema('{"type":"object","properties":{"file":{"type":"string"},' +
      '"maxEntries":{"type":"integer"},' +
      '"includeContent":{"type":"boolean"}},"required":["file"]}'),
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := _HandleGetFileHistory(AParams, LGit);
    end));

  AServer.RegisterTool(_Desc('GetDiffOfActiveFile',
    'Diff the unsaved buffer against HEAD',
    'Unified diff of the LIVE EDITOR BUFFER (unsaved edits included) against ' +
    'the committed version at git HEAD. This is what a terminal CANNOT do: ' +
    '`git diff` only sees the file on DISK, so it is blind to everything the ' +
    'user (or you) has typed but not saved. Defaults to the active editor; ' +
    'pass "unit" to target another unit by name or path. Pass ' +
    '"showInIDE":true to ALSO open the IDE''s native diff viewer on the two ' +
    'sides. Returns "dirty":false with an empty patch when the buffer matches ' +
    'HEAD. Read-only: nothing is saved, nothing is committed, the view does ' +
    'not move.',
    _Schema('{"type":"object","properties":{"unit":{"type":"string"},' +
      '"showInIDE":{"type":"boolean"}}}'),
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := _HandleGetDiffOfActiveFile(AParams, LGit);
    end));
end;

end.
