unit Aefos.Agent.Orientation;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

(*
  Aefos Agent CLI - turn-start orientation (pure, RTL-only, headless-testable).

  Harness contract P0-2: a harnessed agent
  receives its environment BEFORE the first hop (project, active file, debugger
  state, branch) instead of spending tool calls asking "where am I?". The CLI
  gathers the four snapshots with cheap read-only MCP calls; this unit only
  FORMATS them into the single system line - so the formatting is testable
  without a pipe, and any missing/failed probe degrades to omission.
*)

interface

uses
  {$IFDEF FPC}
  SysUtils,
  Aefos.Compat.Json;
  {$ELSE}
  System.SysUtils,
  System.JSON;
  {$ENDIF}

type
  { Static, sealed namespace for the turn-start orientation line. Never
    instantiated; the class IS the namespace. }
  TAgentOrientation = class sealed
  public
    // Formats '[environment] project=... (Win32) | file=... | debugger=... |
    // branch=...' from the four tool-result JSONs. Every input is optional (''
    // or unparseable pieces are skipped); returns '' when NOTHING was usable, so
    // the caller just doesn't inject a message.
    class function BuildLine(const AProjectJson, AActiveFileJson,
      ADebugStateJson, ABranchJson: string): string; static;

    class function Marker: string; static;
  end;

implementation

function _Parse(const AJson: string): TJSONObject;
var
  LVal: TJSONValue;
begin
  Result := nil;
  if AJson = '' then
    Exit;
  LVal := TJSONObject.ParseJSONValue(AJson);
  if LVal is TJSONObject then
    Result := TJSONObject(LVal)
  else
    LVal.Free;
end;

class function TAgentOrientation.Marker: string;
begin
  Result := '[environment]';
end;

class function TAgentOrientation.BuildLine(const AProjectJson, AActiveFileJson,
  ADebugStateJson, ABranchJson: string): string;
var
  LObj: TJSONObject;
  LSb: TStringBuilder;
  LName, LPlatform, LFile, LState, LBranch: string;
  LAny: Boolean;

  procedure _Sep;
  begin
    if LAny then
      LSb.Append(' | ');
    LAny := True;
  end;

begin
  Result := '';
  LAny := False;
  LSb := TStringBuilder.Create;
  try
    LSb.Append(TAgentOrientation.Marker);
    LSb.Append(' ');

    // GetActiveProject -> {"project_name":..,"project_path":..,"target_platform":..}
    LObj := _Parse(AProjectJson);
    if LObj <> nil then
    try
      LName := '';
      LPlatform := '';
      LObj.TryGetValue<string>('project_name', LName);
      LObj.TryGetValue<string>('target_platform', LPlatform);
      if LName <> '' then
      begin
        _Sep;
        LSb.Append('project=');
        LSb.Append(LName);
        if LPlatform <> '' then
        begin
          LSb.Append(' (');
          LSb.Append(LPlatform);
          LSb.Append(')');
        end;
      end;
    finally
      LObj.Free;
    end;

    // GetEditorActiveFile -> {"name":..,"path":..}
    LObj := _Parse(AActiveFileJson);
    if LObj <> nil then
    try
      LFile := '';
      LObj.TryGetValue<string>('name', LFile);
      if LFile <> '' then
      begin
        _Sep;
        LSb.Append('active file=');
        LSb.Append(LFile);
      end;
    finally
      LObj.Free;
    end;

    // GetDebugState -> {"state":..,...}
    LObj := _Parse(ADebugStateJson);
    if LObj <> nil then
    try
      LState := '';
      LObj.TryGetValue<string>('state', LState);
      if LState <> '' then
      begin
        _Sep;
        LSb.Append('debugger=');
        LSb.Append(LState);
      end;
    finally
      LObj.Free;
    end;

    // GetGitCurrentBranch -> {"branch":..} (or {"value":..} - accept both)
    LObj := _Parse(ABranchJson);
    if LObj <> nil then
    try
      LBranch := '';
      // Parenthesise the generic call under `not` (FPC generic-call parse).
      if not (LObj.TryGetValue<string>('branch', LBranch)) then
        LObj.TryGetValue<string>('value', LBranch);
      if LBranch <> '' then
      begin
        _Sep;
        LSb.Append('branch=');
        LSb.Append(LBranch);
      end;
    finally
      LObj.Free;
    end;

    if LAny then
      Result := LSb.ToString;
  finally
    LSb.Free;
  end;
end;

end.
