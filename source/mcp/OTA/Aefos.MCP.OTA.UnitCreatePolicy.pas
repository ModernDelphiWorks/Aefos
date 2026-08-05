unit Aefos.MCP.OTA.UnitCreatePolicy;

{
  Pure unit/file-create policy seam (ESP-073, S1 / ADR-073-02/03 / BR21/BR23).

  Pure RTL — no ToolsAPI, no VCL, no disk write. Carries every OTA-free
  decision the first real mutation (AddUnit) must make before any IOTAProject
  write happens: validate the requested unit name + module type, resolve and
  confine the target path to the active project root (reject absolute / `..`
  escapes), and refuse a silent overwrite of an existing file (safe default:
  refuse; an explicit overwrite flag is required to replace). Each rejection is
  mapped onto Core's frozen TMCPFileActionOutcome vocabulary (BR24 — no new
  audit value).

  The OTA wiring (TThread.Synchronize + IOTAModuleServices/IOTAProject) lives in
  the UI facade (Aefos.MCP.OTA.WorkspaceFacade) and is the only
  OTA-bound, structurally-exempt part (covered live, AC7). This mirrors the
  ESP-071 ConsentPolicy precedent: a pure, dependency-injected seam unit-tested
  headless with a thin OTA caller.

  File existence is injected (TUnitExistsFunc) so the rule stays deterministic
  and disk-free for unit tests — exactly as ConsentPolicy injects elapsed/timeout
  instead of reading the wall clock.
}

interface

uses
  Aefos.MCP.Types;

type
  // Why a create was refused. Maps 1:1 onto a TMCPFileActionOutcome inside
  // Core's frozen audit/return vocabulary (BR24 — no new value added).
  TUnitCreateRejection = (
    ucrNone,             // accepted — the plan is valid
    ucrNoProjectRoot,    // empty/blank project root (no active project)
    ucrInvalidName,      // unit name / module type rejected
    ucrPathEscape,       // target resolves outside the active project root
    ucrOverwriteRefused  // target exists and overwrite was not requested
  );

  // Resolved create decision. When Accepted, FullPath is the confined absolute
  // path the facade will write; otherwise Rejection/Outcome/Reason explain why.
  TUnitCreatePlan = record
    FullPath: string;                 // confined absolute target (accepted only)
    UnitName: string;                 // validated unit name (no extension)
    Overwrite: Boolean;               // replacing an existing file is permitted
    Rejection: TUnitCreateRejection;  // ucrNone => accepted
    Outcome: TMCPFileActionOutcome;   // mapped Core outcome (BR24)
    Reason: string;                   // kebab reason surfaced as AError on reject
    function Accepted: Boolean;
  end;

  // Injected existence probe — the facade passes TFile.Exists; tests a stub.
  TUnitExistsFunc = reference to function(const APath: string): Boolean;

  // Pure unit/file-create policy seam as a sealed static namespace
  // (see the unit header for the ESP-073 / ADR-073 contract). Never instantiated.
  TUnitCreatePolicy = class sealed
  public
    // Pure decision: validate name/type, confine the target path to AProjectRoot,
    // then apply the overwrite safe-default. No disk I/O — existence comes from
    // AExists. AAllowOverwrite is the explicit replace flag (BR21).
    class function ResolveUnitCreate(const AUnitPath, AProjectRoot: string;
      const AAllowOverwrite: Boolean;
      const AExists: TUnitExistsFunc): TUnitCreatePlan; static;

    // True when AName is an acceptable Pascal unit name (dotted segments allowed,
    // each a valid identifier; no empty segment, so no leading/trailing/double dot).
    class function IsValidUnitName(const AName: string): Boolean; static;
  end;

implementation

uses
  System.SysUtils,
  System.IOUtils;

function TUnitCreatePlan.Accepted: Boolean;
begin
  Result := Rejection = ucrNone;
end;

function _IsIdentSegment(const ASeg: string): Boolean;
var
  LIndex: Integer;
begin
  Result := False;
  if ASeg = '' then
    Exit;
  if not CharInSet(ASeg[1], ['A'..'Z', 'a'..'z', '_']) then
    Exit;
  for LIndex := 2 to Length(ASeg) do
    if not CharInSet(ASeg[LIndex], ['A'..'Z', 'a'..'z', '0'..'9', '_']) then
      Exit;
  Result := True;
end;

class function TUnitCreatePolicy.IsValidUnitName(const AName: string): Boolean;
var
  LSegment: string;
begin
  if AName = '' then
    Exit(False);
  for LSegment in AName.Split(['.']) do
    if not _IsIdentSegment(LSegment) then
      Exit(False);
  Result := True;
end;

// Case-insensitive containment of a normalized absolute path under a normalized
// absolute root. The trailing delimiter prevents `app` matching `app-evil`.
function _IsWithinRoot(const AFull, ARootFull: string): Boolean;
var
  LRootSlash: string;
begin
  LRootSlash := IncludeTrailingPathDelimiter(ARootFull);
  Result := AFull.StartsWith(LRootSlash, True) or
            SameText(AFull, ExcludeTrailingPathDelimiter(LRootSlash));
end;

class function TUnitCreatePolicy.ResolveUnitCreate(const AUnitPath, AProjectRoot: string;
  const AAllowOverwrite: Boolean;
  const AExists: TUnitExistsFunc): TUnitCreatePlan;
var
  LRootFull, LCombined, LFull, LExt, LUnitName: string;
begin
  Result := Default(TUnitCreatePlan);
  Result.Overwrite := AAllowOverwrite;

  // No active project root => no place to confine the create (BR21).
  if Trim(AProjectRoot) = '' then
  begin
    Result.Rejection := ucrNoProjectRoot;
    Result.Outcome   := faNoActiveProject;
    Result.Reason    := 'no-active-project';
    Exit;
  end;

  // Name + module type: a `.pas` unit with a valid (dotted) Pascal name.
  LExt      := TPath.GetExtension(AUnitPath);
  LUnitName := TPath.GetFileNameWithoutExtension(AUnitPath);
  if (not SameText(LExt, '.pas')) or (not TUnitCreatePolicy.IsValidUnitName(LUnitName)) then
  begin
    Result.Rejection := ucrInvalidName;
    Result.Outcome   := faAccessError;
    Result.Reason    := 'invalid-unit-name';
    Exit;
  end;
  Result.UnitName := LUnitName;

  // Path confinement: resolve against the project root and reject any target
  // that escapes it (absolute path elsewhere, or `..` traversal). Pure string
  // normalization — TPath.GetFullPath does not touch the disk. A path that does
  // not normalize is treated as an escape (cannot be confined).
  try
    if TPath.IsPathRooted(AUnitPath) then
      LCombined := AUnitPath
    else
      LCombined := TPath.Combine(AProjectRoot, AUnitPath);
    LRootFull := TPath.GetFullPath(AProjectRoot);
    LFull     := TPath.GetFullPath(LCombined);
  except
    Result.Rejection := ucrPathEscape;
    Result.Outcome   := faAccessError;
    Result.Reason    := 'path-escape';
    Exit;
  end;

  if not _IsWithinRoot(LFull, LRootFull) then
  begin
    Result.Rejection := ucrPathEscape;
    Result.Outcome   := faAccessError;
    Result.Reason    := 'path-escape';
    Exit;
  end;
  Result.FullPath := LFull;

  // Overwrite safe-default: refuse an existing target unless explicitly allowed
  // (BR21). AddUnit's Core schema exposes no overwrite arg, so the facade always
  // passes False; the allow path is exercised by the unit tests.
  if (Assigned(AExists) and AExists(LFull)) and (not AAllowOverwrite) then
  begin
    Result.Rejection := ucrOverwriteRefused;
    Result.Outcome   := faAlreadyExists;
    Result.Reason    := 'already-exists';
    Exit;
  end;

  // Accepted — the facade performs the confined OTA write.
  Result.Rejection := ucrNone;
  Result.Outcome   := faApplied;
  Result.Reason    := '';
end;

end.
