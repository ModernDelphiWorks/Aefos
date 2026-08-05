unit Aefos.MCP.OTA.DProjParser;

{
  Pure .dproj XML parse seam (ESP-092, S1 / ADR-092-02 / BR1 / BR4).

  Pure RTL — no ToolsAPI, no VCL, no file IO. Each function takes the .dproj XML
  content as a string and returns the parsed value; the facade owns the impure
  boundary (resolve the .dproj path via OTA on the main thread -> read the file
  -> call one of these functions -> return). This split keeps the parse logic
  headless-testable (ADR-092-02) and mirrors the campaign seam precedent
  (ConsentPolicy / ContentWritePolicy / ConfigWritePolicy / BuildRunPolicy).

  Promotes four project-read MCP tools from honest CAVEAT '' sentinels to real
  values read straight from the active project's .dproj XML, never forking the
  frozen Core (ADR-092-01 / BR1). Reads only; the file is never written
  (ADR-092-03 / BR4).

    - ParseProjectGuid        — <ProjectGuid> inner text.
    - ParseProjectVersion     — composes major.minor.release.build from the
                                discrete <VerInfo_MajorVer> / ...MinorVer /
                                ...Release / ...Build elements, falling back to
                                FileVersion= (then ProductVersion=) inside
                                <VerInfo_Keys>; missing parts -> 0.
    - ParseProjectDescription — FileDescription= in <VerInfo_Keys> when it is a
                                real value (non-empty, not a bare MSBuild macro),
                                else the dedicated <Description> element.
    - ParseDcuOutputDir       — config-scoped <DCC_DcuOutput> (then <DcuOutput>):
                                a value whose enclosing <PropertyGroup> Condition
                                mentions AConfig wins; otherwise the first
                                occurrence (typically the Base group).

  Malformed / absent XML yields '' with no exception (the scans are position
  based and bounded by Pos/PosEx). A leading UTF-8 BOM in the string is tolerated
  for the same reason. The five predefined XML entities are decoded in the
  returned text where a literal value is expected.
}

interface

type
  // Pure .dproj XML parse seam as a sealed static namespace
  // (see the unit header for the ESP-092 / ADR-092 contract). Never instantiated.
  TDProjParser = class sealed
  public
    // <ProjectGuid> inner text, trimmed. '' when absent/empty/unterminated.
    class function ParseProjectGuid(const AXml: string): string; static;

    // Composed major.minor.release.build. Prefers the discrete VerInfo_* elements,
    // then FileVersion= / ProductVersion= in <VerInfo_Keys>. Missing parts -> 0.
    // '' when no version information is present at all.
    class function ParseProjectVersion(const AXml: string): string; static;

    // Project description: a real FileDescription= from <VerInfo_Keys> (preferred),
    // else the dedicated <Description> element. '' when neither carries a real value.
    class function ParseProjectDescription(const AXml: string): string; static;

    // Config-scoped DCU output dir. A <DCC_DcuOutput>/<DcuOutput> inside a
    // PropertyGroup whose Condition mentions AConfig wins; else the first found.
    // '' when absent. AConfig may be '' to always take the first occurrence.
    class function ParseDcuOutputDir(const AXml, AConfig: string): string; static;
  end;

implementation

uses
  System.SysUtils,
  System.StrUtils;

// Inner text of the first <ATag>...</ATag> in AXml ('' when absent/unterminated).
function _FindTagValue(const AXml, ATag: string): string;
var
  LOpen, LClose: string;
  LStart, LContent, LEnd: Integer;
begin
  Result := '';
  LOpen := '<' + ATag + '>';
  LClose := '</' + ATag + '>';
  LStart := Pos(LOpen, AXml);
  if LStart = 0 then
    Exit;
  LContent := LStart + Length(LOpen);
  LEnd := PosEx(LClose, AXml, LContent);
  if LEnd = 0 then
    Exit;
  Result := Copy(AXml, LContent, LEnd - LContent);
end;

// Decode the five predefined XML entities (&amp; resolved last to avoid
// re-decoding entities that legitimately contained an ampersand sequence).
function _DecodeXml(const AValue: string): string;
begin
  Result := AValue;
  Result := StringReplace(Result, '&lt;', '<', [rfReplaceAll]);
  Result := StringReplace(Result, '&gt;', '>', [rfReplaceAll]);
  Result := StringReplace(Result, '&quot;', '"', [rfReplaceAll]);
  Result := StringReplace(Result, '&apos;', '''', [rfReplaceAll]);
  Result := StringReplace(Result, '&amp;', '&', [rfReplaceAll]);
end;

// Value of AKey ('Key=value') inside a ';'-delimited VerInfo_Keys string.
function _ExtractKey(const AKeys, AKey: string): string;
var
  LParts: TArray<string>;
  LPrefix, LEntry: string;
  LFor: Integer;
begin
  Result := '';
  LPrefix := AKey + '=';
  LParts := AKeys.Split([';']);
  for LFor := 0 to High(LParts) do
  begin
    LEntry := Trim(LParts[LFor]);
    if LEntry.StartsWith(LPrefix, True) then
      Exit(Trim(Copy(LEntry, Length(LPrefix) + 1, MaxInt)));
  end;
end;

// Trimmed value, or '0' when blank — one version part.
function _PartOrZero(const AValue: string): string;
begin
  Result := Trim(AValue);
  if Result = '' then
    Result := '0';
end;

// Pad a dotted version string to exactly four parts, missing parts -> '0'.
function _NormalizeVersion(const AValue: string): string;
var
  LParts: TArray<string>;
  LFor: Integer;
begin
  LParts := AValue.Split(['.']);
  SetLength(LParts, 4);
  Result := '';
  for LFor := 0 to 3 do
  begin
    if LFor > 0 then
      Result := Result + '.';
    Result := Result + _PartOrZero(LParts[LFor]);
  end;
end;

// True when AValue is a bare MSBuild macro such as $(MSBuildProjectName) — the
// pure parser cannot expand it, so it is treated as "no real value" (R3).
function _IsMsBuildMacro(const AValue: string): Boolean;
var
  LTrim: string;
begin
  LTrim := Trim(AValue);
  Result := LTrim.StartsWith('$(') and LTrim.EndsWith(')');
end;

// Value of the Condition="..." attribute of an opening-tag fragment ('' if none).
function _ExtractCondition(const AOpenTag: string): string;
var
  LMarker: string;
  LStart, LEnd: Integer;
begin
  Result := '';
  LMarker := 'Condition="';
  LStart := Pos(LMarker, AOpenTag);
  if LStart = 0 then
    Exit;
  LStart := LStart + Length(LMarker);
  LEnd := PosEx('"', AOpenTag, LStart);
  if LEnd = 0 then
    Exit;
  Result := Copy(AOpenTag, LStart, LEnd - LStart);
end;

// Advance APos through <PropertyGroup ...>...</PropertyGroup> blocks, yielding the
// Condition attribute and inner body of each. False when none remain.
function _NextPropertyGroup(const AXml: string; var APos: Integer;
  out ACondition, AInner: string): Boolean;
const
  CClose = '</PropertyGroup>';
var
  LOpenStart, LOpenEnd, LCloseStart: Integer;
begin
  Result := False;
  ACondition := '';
  AInner := '';
  LOpenStart := PosEx('<PropertyGroup', AXml, APos);
  if LOpenStart = 0 then
    Exit;
  LOpenEnd := PosEx('>', AXml, LOpenStart);
  if LOpenEnd = 0 then
    Exit;
  ACondition := _ExtractCondition(Copy(AXml, LOpenStart, LOpenEnd - LOpenStart + 1));
  LCloseStart := PosEx(CClose, AXml, LOpenEnd);
  if LCloseStart = 0 then
    Exit;
  AInner := Copy(AXml, LOpenEnd + 1, LCloseStart - LOpenEnd - 1);
  APos := LCloseStart + Length(CClose);
  Result := True;
end;

// Config-scoped lookup of ATag across PropertyGroup blocks: a block whose
// Condition mentions AConfig wins; otherwise the first occurrence is returned.
function _FindConfigScopedDir(const AXml, ATag, AConfig: string): string;
var
  LPos: Integer;
  LCond, LInner, LVal, LFallback: string;
begin
  Result := '';
  LFallback := '';
  LPos := 1;
  while _NextPropertyGroup(AXml, LPos, LCond, LInner) do
  begin
    LVal := Trim(_FindTagValue(LInner, ATag));
    if LVal = '' then
      Continue;
    if (AConfig <> '') and (Pos(LowerCase(AConfig), LowerCase(LCond)) > 0) then
      Exit(LVal);
    if LFallback = '' then
      LFallback := LVal;
  end;
  Result := LFallback;
end;

class function TDProjParser.ParseProjectGuid(const AXml: string): string;
begin
  Result := Trim(_FindTagValue(AXml, 'ProjectGuid'));
end;

class function TDProjParser.ParseProjectVersion(const AXml: string): string;
var
  LMajor, LMinor, LRelease, LBuild, LKeys, LFileVer: string;
begin
  Result := '';
  LMajor := _FindTagValue(AXml, 'VerInfo_MajorVer');
  LMinor := _FindTagValue(AXml, 'VerInfo_MinorVer');
  LRelease := _FindTagValue(AXml, 'VerInfo_Release');
  LBuild := _FindTagValue(AXml, 'VerInfo_Build');
  if (Trim(LMajor) <> '') or (Trim(LMinor) <> '') or
     (Trim(LRelease) <> '') or (Trim(LBuild) <> '') then
  begin
    Result := _PartOrZero(LMajor) + '.' + _PartOrZero(LMinor) + '.' +
              _PartOrZero(LRelease) + '.' + _PartOrZero(LBuild);
    Exit;
  end;
  LKeys := _FindTagValue(AXml, 'VerInfo_Keys');
  if LKeys = '' then
    Exit;
  LFileVer := _ExtractKey(LKeys, 'FileVersion');
  if LFileVer = '' then
    LFileVer := _ExtractKey(LKeys, 'ProductVersion');
  if LFileVer <> '' then
    Result := _NormalizeVersion(LFileVer);
end;

class function TDProjParser.ParseProjectDescription(const AXml: string): string;
var
  LKeys, LFileDesc, LDesc: string;
begin
  Result := '';
  LKeys := _FindTagValue(AXml, 'VerInfo_Keys');
  if LKeys <> '' then
  begin
    LFileDesc := _ExtractKey(LKeys, 'FileDescription');
    if (LFileDesc <> '') and not _IsMsBuildMacro(LFileDesc) then
      Exit(_DecodeXml(LFileDesc));
  end;
  LDesc := Trim(_FindTagValue(AXml, 'Description'));
  if LDesc <> '' then
    Result := _DecodeXml(LDesc);
end;

class function TDProjParser.ParseDcuOutputDir(const AXml, AConfig: string): string;
begin
  Result := _FindConfigScopedDir(AXml, 'DCC_DcuOutput', AConfig);
  if Result = '' then
    Result := _FindConfigScopedDir(AXml, 'DcuOutput', AConfig);
end;

end.
