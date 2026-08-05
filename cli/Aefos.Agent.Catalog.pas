unit Aefos.Agent.Catalog;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

(*
  Aefos Agent CLI - tool-catalog economy (pure, RTL-only, headless-testable).

  Harness contract P0-1: a local model must
  NOT receive all ~127 aefos tool schemas up front - serialized they are tens
  of KB and flood an 8-32k context window before work even starts. Instead:

    - the tools array carries ONLY the schemas loaded so far plus ONE meta-tool,
      GetToolSchema;
    - a system preamble announces the whole catalog as "name - summary" lines
      and tells the model to load a schema before calling an unloaded tool;
    - GetToolSchema is answered LOCALLY by the CLI from its cached tools/list
      (no pipe round-trip): an exact name loads that schema (the tool becomes
      callable on the next hop), a query searches the catalog.

  Zero server changes - this is client-side scaffolding only.
*)

interface

uses
  {$IFDEF FPC}
  SysUtils,
  Aefos.Compat.Json,
  {$ELSE}
  System.SysUtils,
  System.JSON,
  {$ENDIF}
  Aefos.Agent.MCP.Core;

const
  CGetToolSchemaName = 'GetToolSchema';
  // Auto mode: catalogs at or below this size ship full schemas (compaction
  // overhead isn't worth it); larger ones switch to the compact contract.
  CCompactAutoThreshold = 24;
  // A one-liner longer than this is cut at the last word boundary. Keeps the
  // preamble's per-tool cost bounded (~127 lines must stay cheap).
  CSummaryMaxLen = 100;

type
  { Static, sealed namespace for the tool-catalog economy (schema-on-demand).
    Never instantiated; the class IS the namespace. }
  TAgentCatalog = class sealed
  public
    // The catalog announcement, sent once as a system message. Lists every tool
    // as 'name - summary' and instructs the load-then-call protocol. The marker
    // prefix lets a resumed session detect the preamble is already present.
    class function PreambleMarker: string; static;
    class function BuildPreamble(const ATools: TArray<TMcpToolDef>): string; static;

    // The tools array for /api/chat under the compact contract: full schemas for
    // the tools in AExpanded (order preserved, unknown names skipped) plus the
    // GetToolSchema meta-tool. AExpanded empty => just the meta-tool.
    class function BuildCompactToolsJson(const ATools: TArray<TMcpToolDef>;
      const AExpanded: TArray<string>): string; static;

    // Handles a GetToolSchema call locally. AArgumentsJson may carry "name"
    // (exact, preferred) or "query" (search). An exact hit appends to AExpanded
    // (dedup) and returns the full definition; a query returns up to 8
    // 'name - summary' hits. AIsError mirrors the MCP result convention (True =
    // the text is an error the model should read and adapt to).
    class function HandleGetToolSchema(const ATools: TArray<TMcpToolDef>;
      const AArgumentsJson: string; var AExpanded: TArray<string>;
      out AResultText: string): Boolean; static;

    // One-liner of a tool description: first sentence, capped at CSummaryMaxLen.
    class function ToolSummary(const ADescription: string): string; static;
  end;

implementation

class function TAgentCatalog.ToolSummary(const ADescription: string): string;
var
  LDot: Integer;
  LCut: Integer;
begin
  Result := Trim(ADescription);
  // First sentence: cut at the first '. ' (a dot inside "e.g." rarely has the
  // trailing space; good enough for a summary line).
  LDot := Pos('. ', Result);
  if LDot > 0 then
    Result := Copy(Result, 1, LDot);
  if Length(Result) > CSummaryMaxLen then
  begin
    LCut := CSummaryMaxLen;
    while (LCut > 1) and (Result[LCut] <> ' ') do
      Dec(LCut);
    if LCut <= 1 then
      LCut := CSummaryMaxLen;
    Result := TrimRight(Copy(Result, 1, LCut)) + '...';
  end;
end;

class function TAgentCatalog.PreambleMarker: string;
begin
  Result := '[aefos tools]';
end;

class function TAgentCatalog.BuildPreamble(
  const ATools: TArray<TMcpToolDef>): string;
var
  LSb: TStringBuilder;
  LIndex: Integer;
begin
  LSb := TStringBuilder.Create;
  try
    LSb.Append(PreambleMarker);
    LSb.Append(' The aefos IDE exposes ');
    LSb.Append(IntToStr(Length(ATools)));
    LSb.Append(' tools, listed below as "name - summary". Only the tools in ');
    LSb.Append('your tools array are loaded. To use any other one, FIRST call ');
    LSb.Append(CGetToolSchemaName);
    LSb.Append(' with its exact name to load its parameter schema, THEN call ');
    LSb.Append('the tool itself on your next step.');
    for LIndex := 0 to High(ATools) do
    begin
      LSb.Append(#10);
      LSb.Append(ATools[LIndex].Name);
      LSb.Append(' - ');
      LSb.Append(ToolSummary(ATools[LIndex].Description));
    end;
    Result := LSb.ToString;
  finally
    LSb.Free;
  end;
end;

function _MetaToolDef: TMcpToolDef;
begin
  Result.Name := CGetToolSchemaName;
  Result.Description :=
    'Loads the full parameter schema of an aefos tool so it can be called. ' +
    'Pass the exact tool name in "name" (preferred), or a keyword in "query" ' +
    'to search the catalog. After a successful load, call the tool itself.';
  Result.InputSchemaJson :=
    '{"type":"object","properties":{' +
    '"name":{"type":"string","description":"exact tool name to load"},' +
    '"query":{"type":"string","description":"keyword to search when the ' +
    'exact name is unknown"}}}';
end;

function _FindTool(const ATools: TArray<TMcpToolDef>; const AName: string;
  out AIndex: Integer): Boolean;
var
  LIndex: Integer;
begin
  Result := False;
  AIndex := -1;
  for LIndex := 0 to High(ATools) do
    if SameText(ATools[LIndex].Name, AName) then
    begin
      AIndex := LIndex;
      Exit(True);
    end;
end;

class function TAgentCatalog.BuildCompactToolsJson(
  const ATools: TArray<TMcpToolDef>;
  const AExpanded: TArray<string>): string;
var
  LSubset: TArray<TMcpToolDef>;
  LCount, LIdx, LIndex: Integer;
begin
  SetLength(LSubset, Length(AExpanded) + 1);
  LCount := 0;
  for LIndex := 0 to High(AExpanded) do
    if _FindTool(ATools, AExpanded[LIndex], LIdx) then
    begin
      LSubset[LCount] := ATools[LIdx];
      Inc(LCount);
    end;
  LSubset[LCount] := _MetaToolDef;
  Inc(LCount);
  SetLength(LSubset, LCount);
  Result := TMcpWire.OllamaToolsJson(LSubset);
end;

procedure _AddExpanded(var AExpanded: TArray<string>; const AName: string);
var
  LIndex: Integer;
begin
  for LIndex := 0 to High(AExpanded) do
    if SameText(AExpanded[LIndex], AName) then
      Exit;
  AExpanded := AExpanded + [AName];
end;

class function TAgentCatalog.HandleGetToolSchema(
  const ATools: TArray<TMcpToolDef>;
  const AArgumentsJson: string; var AExpanded: TArray<string>;
  out AResultText: string): Boolean;
var
  LRoot: TJSONValue;
  LName, LQuery, LLowQ: string;
  LIdx, LIndex, LHits: Integer;
  LSb: TStringBuilder;
begin
  // Result mirrors the MCP isError convention: True = error text. Every path
  // below sets it explicitly.
  AResultText := '';
  LName := '';
  LQuery := '';
  LRoot := TJSONObject.ParseJSONValue(AArgumentsJson);
  try
    if LRoot is TJSONObject then
    begin
      TJSONObject(LRoot).TryGetValue<string>('name', LName);
      TJSONObject(LRoot).TryGetValue<string>('query', LQuery);
    end;
  finally
    LRoot.Free;
  end;

  // Exact name: load the schema and make the tool callable from the next hop.
  if Trim(LName) <> '' then
  begin
    if _FindTool(ATools, Trim(LName), LIdx) then
    begin
      _AddExpanded(AExpanded, ATools[LIdx].Name);
      AResultText := 'Loaded. The tool is callable from your next step.' + #10 +
        'name: ' + ATools[LIdx].Name + #10 +
        'description: ' + ATools[LIdx].Description + #10 +
        'parameters: ' + ATools[LIdx].InputSchemaJson;
      Exit(False);
    end;
    AResultText := 'No tool named "' + Trim(LName) + '" exists. Use "query" ' +
      'to search the catalog, or check the tools list in the system message.';
    Exit(True);
  end;

  // Query: search names + descriptions, list up to 8 hits.
  if Trim(LQuery) <> '' then
  begin
    LLowQ := LowerCase(Trim(LQuery));
    LSb := TStringBuilder.Create;
    try
      LHits := 0;
      for LIndex := 0 to High(ATools) do
        if (Pos(LLowQ, LowerCase(ATools[LIndex].Name)) > 0) or
           (Pos(LLowQ, LowerCase(ATools[LIndex].Description)) > 0) then
        begin
          if LHits > 0 then
            LSb.Append(#10);
          LSb.Append(ATools[LIndex].Name);
          LSb.Append(' - ');
          LSb.Append(ToolSummary(ATools[LIndex].Description));
          Inc(LHits);
          if LHits >= 8 then
            Break;
        end;
      if LHits = 0 then
      begin
        AResultText := 'No tool matches "' + Trim(LQuery) + '". Try another ' +
          'keyword or check the tools list in the system message.';
        Exit(True);
      end;
      AResultText := 'Matches (call ' + CGetToolSchemaName +
        ' with the exact "name" to load one):' + #10 + LSb.ToString;
      Exit(False);
    finally
      LSb.Free;
    end;
  end;

  AResultText := 'Pass "name" (exact tool name) or "query" (search keyword).';
  Result := True;
end;

end.
