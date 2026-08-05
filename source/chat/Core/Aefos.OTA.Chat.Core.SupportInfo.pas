unit Aefos.OTA.Chat.Core.SupportInfo;

{
  Single in-code source of truth for the plugin's identity facts
  (ESP-002, Epic 2/4, Demand 3/3, ADR-276).

  Pure, RTL-only carrier of the support facts the product must surface
  consistently: the plugin version (re-exported from OTA_PLUGIN_VERSION, never
  redefined here), the RAD Studio floor, the operating system, the
  external-CLI requirement, and the branding-doc pointer. Two pure formatters
  build the strings the UI consumes without re-typing any fact:
    - FormatAboutLines: the extra About-dialog lines (floor + external CLI).
    - FormatRequirements: a compact requirements block (version + floor + OS +
      external CLI) for the read-only Options group.

  Architectural baseline:
    - ADR-276: every surfaced support fact originates here (BR-1). About,
      Options, and the docs read these constants/formatters; no surface
      re-declares the version literal or hard-codes a divergent floor string.
    - BR-2: the version is read-only -- this unit re-exports OTA_PLUGIN_VERSION
      via PluginVersion and never assigns a different value (versioning
      blackout).

  C-1 / BR-6: this unit is pure -- no Vcl.*, no ToolsAPI, no FMX.*, no Winapi.*,
  no file I/O, no process spawn. The only non-RTL dependency is
  Chat.Core.MainMenu, imported solely to re-export the single version literal it
  owns (so no second copy of the version exists anywhere). Added to
  the coverage list and held at >=80% line coverage.
}

interface

const
  { Canonical, maintainer-curated facts. The RAD Studio floor is locked at
    Delphi 13 (ADR-006); the plugin is Windows-only; the external CLI is
    Codex and Gemini are bundled; Claude Code and Copilot are user-supplied
    (the plugin owns no credentials). }
  SUPPORT_IDE_FLOOR = 'RAD Studio Delphi 13';
  SUPPORT_OS = 'Windows';
  SUPPORT_CLI_REQUIREMENT =
    'AI CLI: Codex and Gemini are bundled; Claude Code and Copilot are ' +
    'user-supplied. The plugin owns no credentials.';
  SUPPORT_BRANDING_DOC = 'docs/branding/SUITE-BRANDING.md';

  { Line labels for the formatted blocks. Kept as named constants so the same
    label is reused by both formatters without a duplicated literal. }
  SUPPORT_LABEL_VERSION = 'Version: ';
  SUPPORT_LABEL_REQUIRES = 'Requires: ';
  SUPPORT_LABEL_OS = 'OS: ';

{ Re-exports the single version literal OTA_PLUGIN_VERSION (BR-2). No second
  version literal exists -- this reads the constant declared in
  Chat.Core.MainMenu. }
function PluginVersion: string;

{ The extra About-dialog lines: the RAD Studio floor requirement and the
  external-CLI requirement, in that order. Pure: same output every call. }
function FormatAboutLines: string;

{ A compact requirements block for the read-only Options group: version, RAD
  Studio floor, OS, and the external-CLI requirement. Pure. }
function FormatRequirements: string;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  Aefos.OTA.Chat.Core.MainMenu;

// Reads THIS BPL's FILEVERSION (set from the .dproj VerInfo) as 'M.m.p'. Same
// approach as the Terminal's Branding._ModuleVersion — so the version has ONE source
// of truth (the .dproj, bumped by scripts/bump-version.ps1) and the Chat can never
// drift from the Terminal again (the old bug: the hardcoded OTA_PLUGIN_VERSION const
// shipped 0.17 while the Terminal read 0.18 from its FileVersion). '' when no version
// resource is present.
function _ModuleVersion: string;
var
  LPath: array[0..MAX_PATH] of Char;
  LSize, LDummy: DWORD;
  LBuf: TBytes;
  LInfo: PVSFixedFileInfo;
  LLen: UINT;
begin
  Result := '';
  if GetModuleFileName(HInstance, LPath, Length(LPath)) = 0 then
    Exit;
  LSize := GetFileVersionInfoSize(LPath, LDummy);
  if LSize = 0 then
    Exit;
  SetLength(LBuf, LSize);
  if not GetFileVersionInfo(LPath, 0, LSize, LBuf) then
    Exit;
  if not VerQueryValue(Pointer(LBuf), '\', Pointer(LInfo), LLen) then
    Exit;
  Result := Format('%d.%d.%d',
    [HiWord(LInfo.dwFileVersionMS), LoWord(LInfo.dwFileVersionMS),
     HiWord(LInfo.dwFileVersionLS)]);
end;

function PluginVersion: string;
begin
  // FILEVERSION (from the .dproj) is the primary source; OTA_PLUGIN_VERSION is only a
  // fallback so the version is never blank on a build without VerInfo.
  Result := _ModuleVersion;
  if Result = '' then
    Result := OTA_PLUGIN_VERSION;
end;

function _RequiresLine: string;
begin
  Result := SUPPORT_LABEL_REQUIRES + SUPPORT_IDE_FLOOR;
end;

function FormatAboutLines: string;
begin
  Result := _RequiresLine + sLineBreak + SUPPORT_CLI_REQUIREMENT;
end;

function FormatRequirements: string;
begin
  Result :=
    SUPPORT_LABEL_VERSION + PluginVersion + sLineBreak +
    _RequiresLine + sLineBreak +
    SUPPORT_LABEL_OS + SUPPORT_OS + sLineBreak +
    SUPPORT_CLI_REQUIREMENT;
end;

end.
