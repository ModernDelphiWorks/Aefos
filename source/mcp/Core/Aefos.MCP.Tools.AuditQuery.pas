unit Aefos.MCP.Tools.AuditQuery;

(*
  Audit-log query MCP tool (ESP-002, Epic 1/3 Demand 4/5; ADR-212/ADR-213).

  Exposes one read-only tool, QueryAuditLog, that surfaces the destructive-
  action audit trail written by TMCPAuditLog (one JSONL object per line in
  %APPDATA%\Aefos\logs\mcp-audit-YYYY-MM-DD.jsonl) to the LLM and to the
  Epic 2/3 smoke harness.

  Classification (ADR-212):
    - Read-only — never consent-gated, never appends to the audit log. The
      registrar takes no facade: this is pure RTL file read + JSON parse, so
      the unit stays inside the MCP.Core boundary (C-1: no uses ToolsAPI /
      Vcl. / FMX.).

  Filters (only fields the writer records):
    - tool   -> recorded `tool`   (case-insensitive, exact; BR-7)
    - status -> recorded `outcome` (applied / denied / failed; BR-6)
    - from/to -> recorded `ts`     (inclusive lexicographic range; BR-5)
    - limit  -> newest-N cap (default 100, max 500; BR-8)
    - session_id -> recorded `session_id` (case-insensitive, exact; ADR-264).
      The writer stamps one id per MCP-server lifetime; a line lacking the
      field never matches an active session_id filter but is still returned by
      an unfiltered query (back-compat, BR-4). Supersedes the ADR-212 deferral.

  Query semantics (ADR-213):
    - Enumerate every mcp-audit-*.jsonl in TMCPAuditLog.LogDir (overridable in
      tests via the directory ctor seam, C-5). Files whose embedded date is
      entirely outside an explicit from/to are skipped as an optimisation
      (BR-2) — `ts` stays the line-level authority.
    - A line that is not a parseable JSON object, or lacks ts/tool/outcome, is
      skipped and counted in malformed_skipped — never aborts (BR-3).
    - Matches are ordered newest-first by `ts` (ties broken by reverse
      encounter order); `limit` caps the result and sets truncated.
    - Envelope: { entries[], returned, scanned, truncated, malformed_skipped }.

  ts is fixed-width local-time ISO (yyyy-mm-ddThh:nn:ss) so lexicographic
  comparison is correct (R-1: local-time semantics, debt #38; not corrected
  here).
*)

interface

uses
  Aefos.MCP.Server;

// Registers the read-only QueryAuditLog tool against AServer, resolving the
// logs directory from TMCPAuditLog.LogDir (the live %APPDATA% location).
procedure RegisterAuditQueryTools(const AServer: IMCPServer); overload;
// Test seam (C-5): same registration but reads from ALogDir instead of
// %APPDATA%, so DUnit queries a temp-dir fixture with zero pollution.
procedure RegisterAuditQueryTools(const AServer: IMCPServer;
  const ALogDir: string); overload;

implementation

uses
  System.SysUtils,
  System.JSON,
  System.Types,
  System.IOUtils,
  System.Generics.Collections,
  System.Generics.Defaults,
  Aefos.MCP.Types,
  Aefos.MCP.AuditLog;

type
  IMCPAuditQueryDispatch = interface
    ['{C4E1B7A2-9F36-4D58-8A07-2B3E6C1D9F40}']
    procedure RegisterAll(const AServer: IMCPServer);
    function HandleQuery(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
  end;

  // Parsed + validated filter set (BR-5..BR-8).
  TAuditQuery = record
    Tool: string;
    HasTool: Boolean;
    Status: string;
    HasStatus: Boolean;
    FromNorm: string;       // normalised yyyy-mm-ddThh:nn:ss lower bound
    HasFrom: Boolean;
    ToNorm: string;         // normalised yyyy-mm-ddThh:nn:ss upper bound
    HasTo: Boolean;
    SessionId: string;      // exact, case-insensitive correlation id (ADR-264)
    HasSessionId: Boolean;
    Limit: Integer;
  end;

  // One matching entry: the cloned record plus its sort keys (`ts` and the
  // global encounter order for the reverse-encounter tie-break, BR-8).
  TAuditMatch = record
    Timestamp: string;
    Order: Integer;
    Obj: TJSONObject;       // owned clone; freed by the handler
  end;

// ── Validation helpers ───────────────────────────────────────────────────

function _DigitsAt(const AText: string; const AStart, ACount: Integer): Boolean;
var
  LFor: Integer;
begin
  Result := True;
  for LFor := AStart to AStart + ACount - 1 do
    if not CharInSet(AText[LFor], ['0'..'9']) then
      Exit(False);
end;

// True when AText is exactly yyyy-mm-dd.
function _IsDateOnly(const AText: string): Boolean;
begin
  Result := (Length(AText) = 10) and _DigitsAt(AText, 1, 4) and (AText[5] = '-')
    and _DigitsAt(AText, 6, 2) and (AText[8] = '-') and _DigitsAt(AText, 9, 2);
end;

// True when AText is exactly yyyy-mm-ddThh:nn:ss.
function _IsDateTime(const AText: string): Boolean;
begin
  Result := (Length(AText) = 19) and _IsDateOnly(Copy(AText, 1, 10))
    and (AText[11] = 'T') and _DigitsAt(AText, 12, 2) and (AText[14] = ':')
    and _DigitsAt(AText, 15, 2) and (AText[17] = ':') and _DigitsAt(AText, 18, 2);
end;

// Normalises a from/to bound to a full yyyy-mm-ddThh:nn:ss (BR-5). Date-only
// expands to start-of-day (from) or end-of-day (to). Returns False on an
// unparseable value (handler maps that to -32602).
function _NormalizeBound(const AValue: string; const AIsTo: Boolean;
  out ANorm: string): Boolean;
begin
  ANorm := '';
  if _IsDateOnly(AValue) then
  begin
    if AIsTo then
      ANorm := AValue + 'T23:59:59'
    else
      ANorm := AValue + 'T00:00:00';
    Exit(True);
  end;
  if _IsDateTime(AValue) then
  begin
    ANorm := AValue;
    Exit(True);
  end;
  Result := False;
end;

function _IsValidStatus(const AValue: string): Boolean;
begin
  Result := SameText(AValue, 'applied') or SameText(AValue, 'denied')
    or SameText(AValue, 'failed');
end;

// Default 100, hard max 500 (BR-8); a non-positive request falls back to the
// default rather than returning nothing.
function _ClampLimit(const AValue: Integer): Integer;
begin
  if AValue < 1 then
    Result := 100
  else if AValue > 500 then
    Result := 500
  else
    Result := AValue;
end;

// Reads a string property; returns False when absent or not a JSON string.
function _GetStr(const AObj: TJSONObject; const AKey: string;
  out AValue: string): Boolean;
var
  LValue: TJSONValue;
begin
  AValue := '';
  LValue := AObj.GetValue(AKey);
  Result := LValue is TJSONString;
  if Result then
    AValue := TJSONString(LValue).Value;
end;

// ── Parameter reader ─────────────────────────────────────────────────────

// Reads and normalises one from/to bound (BR-5). Absent/blank → AHas False;
// an unparseable value raises -32602 (handler maps EMCPInvalidParams).
procedure _ReadBoundParam(const AParams: TJSONObject; const AKey: string;
  const AIsTo: Boolean; out AHas: Boolean; out ANorm: string);
var
  LRaw: string;
begin
  AHas := False;
  ANorm := '';
  if not (_GetStr(AParams, AKey, LRaw) and (Trim(LRaw) <> '')) then
    Exit;
  if not _NormalizeBound(LRaw, AIsTo, ANorm) then
    raise EMCPInvalidParams.Create('QueryAuditLog: invalid ' + AKey + ' "'
      + LRaw + '"');
  AHas := True;
end;

// Reads and validates the status filter (BR-6). Absent/blank → HasStatus
// False; an unrecognised value raises -32602.
procedure _ReadStatusParam(const AParams: TJSONObject; var AQuery: TAuditQuery);
var
  LRaw: string;
begin
  if not (_GetStr(AParams, 'status', LRaw) and (Trim(LRaw) <> '')) then
    Exit;
  if not _IsValidStatus(LRaw) then
    raise EMCPInvalidParams.Create('QueryAuditLog: invalid status "'
      + LRaw + '" (expected applied/denied/failed)');
  AQuery.Status := LRaw;
  AQuery.HasStatus := True;
end;

function _ReadParams(const AParams: TJSONObject): TAuditQuery;
var
  LValue: TJSONValue;
  LRaw: string;
begin
  Result := Default(TAuditQuery);
  Result.Limit := 100;
  if not Assigned(AParams) then
    Exit;
  if _GetStr(AParams, 'tool', LRaw) and (Trim(LRaw) <> '') then
  begin
    Result.Tool := LRaw;
    Result.HasTool := True;
  end;
  _ReadStatusParam(AParams, Result);
  _ReadBoundParam(AParams, 'from', False, Result.HasFrom, Result.FromNorm);
  _ReadBoundParam(AParams, 'to', True, Result.HasTo, Result.ToNorm);
  if _GetStr(AParams, 'session_id', LRaw) and (Trim(LRaw) <> '') then
  begin
    Result.SessionId := LRaw;
    Result.HasSessionId := True;
  end;
  LValue := AParams.GetValue('limit');
  if LValue is TJSONNumber then
    Result.Limit := _ClampLimit(TJSONNumber(LValue).AsInt);
end;

// ── Scan + filter ────────────────────────────────────────────────────────

// True when the recorded fields pass every active filter (BR-5..BR-7; ADR-264).
// ASessionId is the recorded value ('' when the line predates the field): an
// active session_id filter then excludes it, while an inactive one keeps it.
function _MatchEntry(const AQuery: TAuditQuery; const ATs, ATool, AOutcome,
  ASessionId: string): Boolean;
begin
  Result := False;
  if AQuery.HasTool and not SameText(ATool, AQuery.Tool) then
    Exit;
  if AQuery.HasStatus and not SameText(AOutcome, AQuery.Status) then
    Exit;
  if AQuery.HasFrom and (CompareStr(ATs, AQuery.FromNorm) < 0) then
    Exit;
  if AQuery.HasTo and (CompareStr(ATs, AQuery.ToNorm) > 0) then
    Exit;
  if AQuery.HasSessionId and not SameText(ASessionId, AQuery.SessionId) then
    Exit;
  Result := True;
end;

// Parses one JSONL line; counts it, applies the filters, and clones matches
// into AMatches. Blank lines are ignored; bad lines bump AMalformed (BR-3).
procedure _ProcessLine(const ALine: string; const AQuery: TAuditQuery;
  const AMatches: TList<TAuditMatch>; var AScanned, AMalformed: Integer);
var
  LValue: TJSONValue;
  LObj: TJSONObject;
  LTs, LTool, LOutcome, LSessionId: string;
  LMatch: TAuditMatch;
begin
  if Trim(ALine) = '' then
    Exit;
  LValue := TJSONObject.ParseJSONValue(ALine);
  try
    if not (LValue is TJSONObject) then
    begin
      Inc(AMalformed);
      Exit;
    end;
    LObj := TJSONObject(LValue);
    if not (_GetStr(LObj, 'ts', LTs) and _GetStr(LObj, 'tool', LTool)
      and _GetStr(LObj, 'outcome', LOutcome)) then
    begin
      Inc(AMalformed);
      Exit;
    end;
    Inc(AScanned);
    // session_id is optional: _GetStr leaves LSessionId '' for legacy lines so
    // an active filter excludes them while unfiltered queries keep them (BR-4).
    _GetStr(LObj, 'session_id', LSessionId);
    if not _MatchEntry(AQuery, LTs, LTool, LOutcome, LSessionId) then
      Exit;
    LMatch.Timestamp := LTs;
    LMatch.Order := AScanned;
    LMatch.Obj := TJSONObject(LObj.Clone);
    AMatches.Add(LMatch);
  finally
    LValue.Free;
  end;
end;

// Embedded yyyy-mm-dd of a mcp-audit-YYYY-MM-DD.jsonl file (empty if absent).
function _FileDate(const AFile: string): string;
const
  CPrefix = 'mcp-audit-';
var
  LName: string;
begin
  Result := '';
  LName := TPath.GetFileNameWithoutExtension(AFile);
  if LName.StartsWith(CPrefix) then
    Result := Copy(LName, Length(CPrefix) + 1, 10);
end;

// Scans one day-file unless its embedded date is wholly outside from/to (BR-2).
procedure _ScanFile(const AFile: string; const AQuery: TAuditQuery;
  const AMatches: TList<TAuditMatch>; var AScanned, AMalformed: Integer);
var
  LFileDate: string;
  LLines: TStringDynArray;
  LFor: Integer;
begin
  LFileDate := _FileDate(AFile);
  if (LFileDate <> '') and AQuery.HasFrom
    and (CompareStr(LFileDate, Copy(AQuery.FromNorm, 1, 10)) < 0) then
    Exit;
  if (LFileDate <> '') and AQuery.HasTo
    and (CompareStr(LFileDate, Copy(AQuery.ToNorm, 1, 10)) > 0) then
    Exit;
  LLines := TFile.ReadAllLines(AFile, TEncoding.UTF8);
  for LFor := 0 to High(LLines) do
    _ProcessLine(LLines[LFor], AQuery, AMatches, AScanned, AMalformed);
end;

// Newest-first by ts; ties broken by reverse encounter order (BR-8).
procedure _SortMatches(const AMatches: TList<TAuditMatch>);
begin
  AMatches.Sort(TComparer<TAuditMatch>.Construct(
    function(const ALeft, ARight: TAuditMatch): Integer
    begin
      Result := CompareStr(ARight.Timestamp, ALeft.Timestamp);
      if Result = 0 then
        Result := ARight.Order - ALeft.Order;
    end));
end;

// Builds the result envelope from the sorted matches (BR-4 shape on empty).
function _BuildResult(const AMatches: TList<TAuditMatch>;
  const ALimit, AScanned, AMalformed: Integer): TMCPToolResult;
var
  LRoot: TJSONObject;
  LEntries: TJSONArray;
  LFor, LReturned: Integer;
  LTruncated: Boolean;
begin
  LReturned := AMatches.Count;
  LTruncated := LReturned > ALimit;
  if LTruncated then
    LReturned := ALimit;
  LRoot := TJSONObject.Create;
  try
    LEntries := TJSONArray.Create;
    for LFor := 0 to LReturned - 1 do
      LEntries.AddElement(AMatches[LFor].Obj.Clone as TJSONValue);
    LRoot.AddPair('entries', LEntries);
    LRoot.AddPair('returned', TJSONNumber.Create(LReturned));
    LRoot.AddPair('scanned', TJSONNumber.Create(AScanned));
    LRoot.AddPair('truncated', TJSONBool.Create(LTruncated));
    LRoot.AddPair('malformed_skipped', TJSONNumber.Create(AMalformed));
    Result := TMCPToolResult.Text(LRoot.ToJSON);
  finally
    LRoot.Free;
  end;
end;

// ── Schema builders ──────────────────────────────────────────────────────

function _StrProp(const ADesc: string): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'string');
  Result.AddPair('description', ADesc);
end;

function _BuildInputSchema: TJSONObject;
var
  LProps, LStatus: TJSONObject;
  LEnum: TJSONArray;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LProps.AddPair('tool',
    _StrProp('Filter by recorded tool name (case-insensitive, exact match).'));
  LStatus := _StrProp('Filter by recorded outcome.');
  LEnum := TJSONArray.Create;
  LEnum.Add('applied');
  LEnum.Add('denied');
  LEnum.Add('failed');
  LStatus.AddPair('enum', LEnum);
  LProps.AddPair('status', LStatus);
  LProps.AddPair('from', _StrProp('Inclusive lower bound on ts (LOCAL time). '
    + 'yyyy-mm-dd or yyyy-mm-ddThh:nn:ss; date-only normalises to T00:00:00.'));
  LProps.AddPair('to', _StrProp('Inclusive upper bound on ts (LOCAL time). '
    + 'yyyy-mm-dd or yyyy-mm-ddThh:nn:ss; date-only normalises to T23:59:59.'));
  LProps.AddPair('session_id',
    _StrProp('Filter by recorded session id (case-insensitive, exact). One '
    + 'id is minted per MCP-server lifetime; lines without it are excluded '
    + 'under this filter.'));
  LProps.AddPair('limit', TJSONObject.Create
    .AddPair('type', 'integer')
    .AddPair('description', 'Max newest entries to return. Default 100, max 500.'));
  Result.AddPair('properties', LProps);
end;

function _BuildOutputSchema: TJSONObject;
var
  LProps, LEntries, LItems, LItemProps: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type', 'object');
  LProps := TJSONObject.Create;
  LEntries := TJSONObject.Create;
  LEntries.AddPair('type', 'array');
  LItems := TJSONObject.Create;
  LItems.AddPair('type', 'object');
  LItemProps := TJSONObject.Create;
  LItemProps.AddPair('ts', _StrProp('Local-time ISO timestamp.'));
  LItemProps.AddPair('tool', _StrProp('Recorded tool name.'));
  LItemProps.AddPair('args', _StrProp('Free-text args summary (verbatim).'));
  LItemProps.AddPair('consent', _StrProp('Recorded consent token.'));
  LItemProps.AddPair('outcome', _StrProp('applied / denied / failed.'));
  LItemProps.AddPair('session_id',
    _StrProp('Session correlation id (absent on pre-session lines).'));
  LItems.AddPair('properties', LItemProps);
  LEntries.AddPair('items', LItems);
  LProps.AddPair('entries', LEntries);
  LProps.AddPair('returned',
    TJSONObject.Create.AddPair('type', 'integer'));
  LProps.AddPair('scanned',
    TJSONObject.Create.AddPair('type', 'integer'));
  LProps.AddPair('truncated',
    TJSONObject.Create.AddPair('type', 'boolean'));
  LProps.AddPair('malformed_skipped',
    TJSONObject.Create.AddPair('type', 'integer'));
  Result.AddPair('properties', LProps);
end;

// ── Registrar ────────────────────────────────────────────────────────────

type
  TMCPAuditQueryRegistrar = class(TInterfacedObject, IMCPAuditQueryDispatch)
  private
    FLogDir: string;
    function _ResolveDir: string;
    function _HandleQuery(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult;
    function IMCPAuditQueryDispatch.HandleQuery = _HandleQuery;
    function _BuildDescriptor: TMCPToolDescriptor;
  public
    constructor Create(const ALogDir: string);
    procedure RegisterAll(const AServer: IMCPServer);
  end;

constructor TMCPAuditQueryRegistrar.Create(const ALogDir: string);
begin
  inherited Create;
  FLogDir := ALogDir;
end;

function TMCPAuditQueryRegistrar._ResolveDir: string;
begin
  // C-3: one source of the logs directory. Empty override → the live writer
  // location; a non-empty override is the DUnit temp-dir seam (C-5).
  if FLogDir <> '' then
    Result := FLogDir
  else
    Result := TMCPAuditLog.LogDir;
end;

function TMCPAuditQueryRegistrar._HandleQuery(const AParams: TJSONObject;
  const AContext: IMCPToolContext): TMCPToolResult;
var
  LQuery: TAuditQuery;
  LMatches: TList<TAuditMatch>;
  LScanned, LMalformed, LFor: Integer;
  LDir: string;
  LFiles: TStringDynArray;
begin
  LQuery := _ReadParams(AParams);            // raises -32602 on bad input
  LMatches := TList<TAuditMatch>.Create;
  try
    LScanned := 0;
    LMalformed := 0;
    LDir := _ResolveDir;
    if TDirectory.Exists(LDir) then          // BR-4: missing dir → empty shape
    begin
      LFiles := TDirectory.GetFiles(LDir, 'mcp-audit-*.jsonl');
      TArray.Sort<string>(LFiles);
      for LFor := 0 to High(LFiles) do
        _ScanFile(LFiles[LFor], LQuery, LMatches, LScanned, LMalformed);
    end;
    _SortMatches(LMatches);
    Result := _BuildResult(LMatches, LQuery.Limit, LScanned, LMalformed);
  finally
    for LFor := 0 to LMatches.Count - 1 do
      LMatches[LFor].Obj.Free;
    LMatches.Free;
  end;
end;

function TMCPAuditQueryRegistrar._BuildDescriptor: TMCPToolDescriptor;
var
  LDispatch: IMCPAuditQueryDispatch;
begin
  LDispatch := Self;
  Result := TMCPToolDescriptor.Create(
    'QueryAuditLog',
    'Query audit log',
    'Queries the audit trail (mcp-audit-YYYY-MM-DD.jsonl) of destructive '
    + 'actions. Read-only — never writes and never requires consent. '
    + 'Filters: tool / status / from / to / session_id / limit. The session_id '
    + 'correlates all actions within a single MCP-server lifetime. '
    + 'Returns the newest entries first with query metadata. '
    + 'Timestamps are local time.',
    _BuildInputSchema,
    _BuildOutputSchema,
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    begin
      Result := LDispatch.HandleQuery(AParams, AContext);
    end);
end;

procedure TMCPAuditQueryRegistrar.RegisterAll(const AServer: IMCPServer);
begin
  if not Assigned(AServer) then
    raise EArgumentNilException.Create(
      'TMCPAuditQueryRegistrar.RegisterAll: AServer');
  AServer.RegisterTool(_BuildDescriptor);
end;

procedure RegisterAuditQueryTools(const AServer: IMCPServer);
var
  LRegistrar: IMCPAuditQueryDispatch;
begin
  LRegistrar := TMCPAuditQueryRegistrar.Create('');
  LRegistrar.RegisterAll(AServer);
end;

procedure RegisterAuditQueryTools(const AServer: IMCPServer;
  const ALogDir: string);
var
  LRegistrar: IMCPAuditQueryDispatch;
begin
  LRegistrar := TMCPAuditQueryRegistrar.Create(ALogDir);
  LRegistrar.RegisterAll(AServer);
end;

end.
