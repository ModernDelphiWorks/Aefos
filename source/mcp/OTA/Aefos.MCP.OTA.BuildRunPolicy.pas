unit Aefos.MCP.OTA.BuildRunPolicy;

{
  Pure build/run decision seam (ESP-091, S2 / ADR-091-07 / BR10 / BR11 / R5 / R6).

  Pure RTL — no ToolsAPI, no VCL, no disk or process I/O. Carries the two
  OTA-free decisions the 7 build/run tools must make before the facade drives an
  IOTAProjectBuilder, the IDE debugger, or CreateProcess:

    - NormalizeBuildMode   — map the RunBuild `mode` argument ('', 'make',
                             'build', 'rebuild') to a canonical full-build flag,
                             refusing an unknown mode so the facade never guesses
                             a compile mode from an unrecognised string (backs
                             RunBuild, R6).
    - ClassifyExternalTool — classify a RunExternalTool argv as safe-to-spawn.
                             The tool can launch any executable, so a two-gate
                             destructive-token blocklist (mirroring the ESP-090
                             FormUsesWritePolicy ClassifyIDEAction shape) refuses
                             an empty, hard- or soft-destructive argv with a
                             kebab reason (BR11 / R5); everything else passes with
                             the resolved executable.

  This mirrors the ESP-073 UnitCreatePolicy / ESP-087 ContentWritePolicy /
  ESP-088 StructuralWritePolicy / ESP-089 ConfigWritePolicy / ESP-090
  FormUsesWritePolicy precedent: a pure, dependency-free seam unit-tested
  headless, with the OTA / OS wiring (the IOTAProjectBuilder build/clean, the
  IOTAProjectGroup iteration, the IOTADebuggerServices terminate, and the
  CreateProcess spawn) confined to the UI facade as the only OTA/OS-bound,
  structurally-exempt part (covered live, AC7).

  Destructive-token matching is per-argv-element and exact (after normalisation:
  lowercase, path stripped, executable extension dropped, leading switch chars
  removed), so a destructive command anywhere in the argv — executable or
  argument — is caught, while a safe name that merely contains a token as a
  substring (e.g. `delphi`, `model`) is not falsely refused.
}

interface

type
  // Pure build/run decision seam as a sealed static namespace
  // (see the unit header for the ESP-091 / ADR-091 contract). Never instantiated.
  TBuildRunPolicy = class sealed
  public
    // Map a RunBuild `mode` to a canonical full-build flag. '' and 'make'
    // (case-insensitive) select an incremental make (AFullBuild = False); 'build'
    // and 'rebuild' select a full build (AFullBuild = True). Any other value is
    // refused with 'unknown-build-mode' (Result = False), so the facade never
    // guesses a compile mode from an unrecognised string.
    class function NormalizeBuildMode(const AMode: string; out AFullBuild: Boolean;
      out AReason: string): Boolean; static;

    // Classify a RunExternalTool argv for execution (two-gate blocklist mirroring
    // FormUsesWritePolicy.ClassifyIDEAction).
    //
    //   Empty argv → 'empty-argv'; blank executable (argv[0]) → 'empty-tool'.
    //
    //   Gate 1 — hard block: tokens that format a disk, power off / restart the
    //   machine, or irreversibly wipe data (`format`, `shutdown`, `deltree`,
    //   `fdisk`, `diskpart`, `mkfs`, `cipher`, `sdelete`). Refused with
    //   'destructive-tool-refused'; no override.
    //
    //   Gate 2 — soft block: tokens for potentially destructive operations (`del`,
    //   `erase`, `rd`, `rmdir`, `rm`, `taskkill`, `reg`, `remove`). Refused with
    //   'destructive-tool-soft-blocked'; reserved for a future Force parameter.
    //
    //   Everything else passes (True, empty AReason) with AExe set to the trimmed
    //   argv[0]. Matching is per-element and case-insensitive over the whole argv,
    //   so a destructive token in either the executable or an argument is caught.
    class function ClassifyExternalTool(const AArgv: TArray<string>; out AExe: string;
      out AReason: string): Boolean; static;
  end;

implementation

uses
  System.SysUtils;

const
  // Gate 1 — hard-blocked command tokens. An argv element matching any of these
  // formats a disk, powers off / restarts the machine, or irreversibly wipes
  // data. Never overridable.
  CHardBlockTokens: array[0..7] of string =
    ('format', 'shutdown', 'deltree', 'fdisk', 'diskpart', 'mkfs', 'cipher',
     'sdelete');
  // Gate 2 — soft-blocked command tokens. Potentially destructive but sometimes
  // legitimate. Refused by default; reserved for a future Force = true override.
  CSoftBlockTokens: array[0..7] of string =
    ('del', 'erase', 'rd', 'rmdir', 'rm', 'taskkill', 'reg', 'remove');

class function TBuildRunPolicy.NormalizeBuildMode(const AMode: string; out AFullBuild: Boolean;
  out AReason: string): Boolean;
var
  LMode: string;
begin
  AFullBuild := False;
  AReason    := '';
  LMode      := LowerCase(Trim(AMode));
  if (LMode = '') or (LMode = 'make') then
    Exit(True); // incremental make (AFullBuild already False)
  if (LMode = 'build') or (LMode = 'rebuild') then
  begin
    AFullBuild := True;
    Exit(True);
  end;
  AReason := 'unknown-build-mode';
  Result  := False;
end;

// Normalise one argv element to its bare command token: lowercase, path
// stripped, a Windows executable/script extension dropped, and any leading
// switch characters ('/' '-') removed — so '/C', 'C:\Win\DEL.EXE', and '-rf'
// reduce to 'c', 'del', and 'rf' for an exact destructive-token comparison.
function _NormToken(const AValue: string): string;
var
  LExt: string;
begin
  Result := LowerCase(Trim(AValue));
  if Result = '' then
    Exit;
  Result := ExtractFileName(Result);
  LExt := ExtractFileExt(Result);
  if (LExt = '.exe') or (LExt = '.com') or (LExt = '.bat') or
     (LExt = '.cmd') then
    Delete(Result, Length(Result) - Length(LExt) + 1, Length(LExt));
  while (Result <> '') and ((Result[1] = '/') or (Result[1] = '-')) do
    Delete(Result, 1, 1);
end;

function _MatchesAny(const AToken: string;
  const ATokens: array of string): Boolean;
var
  LFor: Integer;
begin
  Result := False;
  if AToken = '' then
    Exit;
  for LFor := Low(ATokens) to High(ATokens) do
    if AToken = ATokens[LFor] then
      Exit(True);
end;

class function TBuildRunPolicy.ClassifyExternalTool(const AArgv: TArray<string>; out AExe: string;
  out AReason: string): Boolean;
var
  LFor: Integer;
  LToken: string;
begin
  AExe    := '';
  AReason := '';
  if Length(AArgv) = 0 then
  begin
    AReason := 'empty-argv';
    Exit(False);
  end;
  AExe := Trim(AArgv[0]);
  if AExe = '' then
  begin
    AReason := 'empty-tool';
    Exit(False);
  end;

  for LFor := 0 to High(AArgv) do
  begin
    LToken := _NormToken(AArgv[LFor]);
    if _MatchesAny(LToken, CHardBlockTokens) then
    begin
      AReason := 'destructive-tool-refused';
      Exit(False);
    end;
    if _MatchesAny(LToken, CSoftBlockTokens) then
    begin
      AReason := 'destructive-tool-soft-blocked';
      Exit(False);
    end;
  end;

  Result := True;
end;

end.
