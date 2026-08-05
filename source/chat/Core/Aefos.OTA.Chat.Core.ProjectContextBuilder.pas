unit Aefos.OTA.Chat.Core.ProjectContextBuilder;

{
  Project context builder (ESP-008, demand 4/5).

  Turns (active project info, user selection) into a TProjectContext record
  and a deterministic Markdown rendering. No OTA imports — the active-project
  resolver is injected as a TFunc<TActiveProjectInfo> lambda; Register.pas
  wires the OTA call and the unit stays console-DUnit-testable.

  Architectural baseline:
    - ADR-016: 32 KB byte cap on the active unit body, deterministic byte cut
      (no smart line-end alignment). Truncation flagged as a Markdown footnote.
    - C-5: no coupling to dispatcher or registry — builder is isolated.
}

interface

uses
  System.SysUtils,
  Aefos.OTA.Chat.Core.ProjectContextBuilder.Types;

const
  ACTIVE_UNIT_MAX_BYTES = 32 * 1024;

type
  TProjectContextBuilder = class(TInterfacedObject, IProjectContextBuilder)
  private
    FResolver: TFunc<TActiveProjectInfo>;
    function _RequireInfo: TActiveProjectInfo;
    function _CapBody(const ABody: string; out ATruncated: Boolean): string;
    function _RenderProjectHeader(const AContext: TProjectContext): string;
    function _RenderActiveUnit(const AContext: TProjectContext): string;
  public
    constructor Create(const AResolver: TFunc<TActiveProjectInfo>);
    function Build(const ASelection: string): TProjectContext;
    function Render(const AContext: TProjectContext): string;
  end;

implementation

constructor TProjectContextBuilder.Create(
  const AResolver: TFunc<TActiveProjectInfo>);
begin
  inherited Create;
  if not Assigned(AResolver) then
    raise EArgumentNilException.Create(
      'TProjectContextBuilder requires a non-nil resolver');
  FResolver := AResolver;
end;

function TProjectContextBuilder._RequireInfo: TActiveProjectInfo;
begin
  Result := FResolver();
  if (Result.ProjectName = '') and (Result.ProjectFile = '') and
     (Result.ActiveUnitName = '') and (Result.ActiveUnitBody = '') then
    raise EProjectContextError.Create(
      'No active Delphi project; cannot build context');
end;

function TProjectContextBuilder._CapBody(const ABody: string;
  out ATruncated: Boolean): string;
var
  LBytes: TBytes;
  LCut: TBytes;
begin
  ATruncated := False;
  if ABody = '' then
    Exit('');
  LBytes := TEncoding.UTF8.GetBytes(ABody);
  if Length(LBytes) <= ACTIVE_UNIT_MAX_BYTES then
    Exit(ABody);
  ATruncated := True;
  SetLength(LCut, ACTIVE_UNIT_MAX_BYTES);
  Move(LBytes[0], LCut[0], ACTIVE_UNIT_MAX_BYTES);
  Result := TEncoding.UTF8.GetString(LCut);
end;

function TProjectContextBuilder.Build(
  const ASelection: string): TProjectContext;
var
  LInfo: TActiveProjectInfo;
  LTruncated: Boolean;
begin
  LInfo := _RequireInfo;
  Result.Selection := ASelection;
  Result.ProjectName := LInfo.ProjectName;
  Result.ProjectFile := LInfo.ProjectFile;
  Result.ActiveUnitName := LInfo.ActiveUnitName;
  Result.ActiveUnitBody := _CapBody(LInfo.ActiveUnitBody, LTruncated);
  Result.ActiveUnitTruncated := LTruncated;
end;

function TProjectContextBuilder._RenderProjectHeader(
  const AContext: TProjectContext): string;
begin
  Result :=
    '## Project' + sLineBreak +
    '- Name: ' + AContext.ProjectName + sLineBreak +
    '- File: ' + AContext.ProjectFile + sLineBreak;
end;

function TProjectContextBuilder._RenderActiveUnit(
  const AContext: TProjectContext): string;
begin
  if AContext.ActiveUnitName = '' then
    Exit('');
  Result :=
    sLineBreak +
    '## Active unit: ' + AContext.ActiveUnitName + sLineBreak +
    sLineBreak +
    '```pascal' + sLineBreak +
    AContext.ActiveUnitBody + sLineBreak +
    '```' + sLineBreak;
  if AContext.ActiveUnitTruncated then
    Result := Result + sLineBreak +
      '> _Active unit truncated at 32 KB._' + sLineBreak;
end;

function TProjectContextBuilder.Render(
  const AContext: TProjectContext): string;
begin
  Result := _RenderProjectHeader(AContext) + _RenderActiveUnit(AContext);
end;

end.
