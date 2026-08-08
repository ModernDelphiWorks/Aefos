unit Aefos.Addons.Types;
{$IFDEF FPC}{$mode delphiunicode}{$modeswitch typehelpers}{$ENDIF}

{
  Aefos Addons - shared domain types for the addon package manager (aefos.exe).

  Pure declarative unit: the shape of a registry entry, a bundle manifest and a
  ledger record. No file I/O, no HTTP, no OTA - so the pure suite can assert the
  parsers/comparers over these records without touching the network or disk.

  See meta\aefos-addons-contract.md for the on-the-wire schema.
}

interface

uses
  SysUtils;

type
  { Called with one human-readable line of progress. ONE declaration for the
    whole addon stack - every other unit ALIASES this one instead of repeating
    the declaration.

    Why it has to live here: two structurally identical "reference to procedure"
    declarations are two DIFFERENT types, and a compiler older than Athens
    refuses to pass one where the other is expected (E2010 Incompatible types,
    measured on Delphi 11 / compiler 35.0). Athens and up happen to accept it,
    so the duplicate only breaks where nobody looks. An alias is the same type
    everywhere, which is what makes the handler cross unit boundaries at all.

    FPC 3.2.2 has no anonymous methods, so there it stays a plain procedural
    type - see the KNOWN DIVERGENCE note in Aefos.Addons.Installer. }
{$IFDEF FPC}
  TAddonLogProc = procedure(const ALine: string);
{$ELSE}
  TAddonLogProc = reference to procedure(const ALine: string);
{$ENDIF}

  { The primary kind used for portal filtering. A bundle may still carry more
    than one artifact regardless of its declared primary type. }
  TAddonKind = (akCommand, akMcp, akTool);

  { Enum helper: string <-> TAddonKind, so the conversion has a named owner on
    the type itself instead of a loose parse/to-string function pair. }
  TAddonKindHelper = record helper for TAddonKind
    { Parses "command"/"mcp"/"tool" (case-insensitive); unknown => akCommand. }
    class function Parse(const AValue: string): TAddonKind; static;
    function ToStr: string;
  end;

  { Trust tier. Community bundles that ship runnable code (mcp/tools) require an
    explicit consent before install. }
  TAddonTrust = (atOfficial, atCommunity);

  { Enum helper: string <-> TAddonTrust. }
  TAddonTrustHelper = record helper for TAddonTrust
    { Parses "official"/"community" (case-insensitive); anything else =>
      atCommunity (the safe default - an unknown tier is treated as untrusted). }
    class function Parse(const AValue: string): TAddonTrust; static;
    function ToStr: string;
  end;

  { Which optional artifacts a bundle carries (from addon.json "artifacts"). }
  TAddonArtifacts = record
    HasCommand: Boolean;
    HasSkill: Boolean;
    HasMcp: Boolean;
    HasTools: Boolean;
    HasTemplates: Boolean;   // templates/ present -> ~/.aefos/templates/<slug>/
  end;

  { One `install[]` mapping (the portal's manifest form): copy the bundle-relative
    folder Source into ~/.aefos\TargetPath. }
  TAddonInstallMapping = record
    Source: string;      // relative to the bundle root, e.g. "command/"
    TargetPath: string;  // relative to ~/.aefos, e.g. "commands/janus-orm/"
  end;

  { One row of registry.json "addons": everything the CLI needs to resolve and
    download a slug at a pinned version. }
  TAddonRegistryEntry = record
    Slug: string;
    Name: string;
    Version: string;
    Description: string;
    Kind: TAddonKind;
    { The type as the STORE spelled it, kept beside the parsed enum on purpose.
      Kind.Parse folds anything it does not know into akCommand, which is right
      for behaviour and wrong for display: a store that starts publishing a new
      type would have it silently filed under an old one. The UI groups by this
      string, so a new type becomes a new group with nothing here to rebuild. }
    KindName: string;
    Trust: TAddonTrust;
    Url: string;            // the versioned .zip
    Sha256: string;         // lowercase hex of the .zip
    RequiresAefos: string;  // requirements.aefos_version, e.g. ">=1.0.0"
  end;

  { The bundle manifest (addon.json) read from inside the extracted zip.
    `Install` (the portal's mapping form) takes precedence over `Artifacts`
    (the fixed-layout fallback) when present. }
  TAddonManifest = record
    Slug: string;
    Version: string;
    Name: string;
    Description: string;
    Trust: TAddonTrust;
    RequiresAefos: string;
    Artifacts: TAddonArtifacts;
    Install: TArray<TAddonInstallMapping>;
  end;

  { The action auto-update takes for one installed slug, decided by comparing
    the installed sha to the registry's current sha (ADR-0001 Decision 2:
    sha256 is the identity, version is informational). }
  TUpdateAction = (uaUpToDate, uaUpdate, uaNotInstalled);

  { One installed addon as recorded in the ledger installed.json. Files are the
    absolute paths laid down, so uninstall can reverse exactly what install did. }
  TInstalledAddon = record
    Slug: string;
    Version: string;
    Trust: TAddonTrust;
    Sha256: string;
    InstalledAt: string;    // ISO-8601 UTC
    { Which configured store this came from. Recorded so update goes back to the
      SAME store: with two stores a bare slug stops being an identity, and an
      update that silently switched a company addon for a same-named gallery one
      would be a supply-chain swap performed by us. Empty on a ledger written
      before sources existed, which reads as "wherever it can be found". }
    Source: string;
    { Where the bundle LIVES, for an addon that was LINKED instead of copied.
      Empty for a copied one.

      A folder store is somewhere permanent, so an addon taken from one needs no
      second copy of itself under ~/.aefos: install RECORDS the folder, and the
      plugin reads the commands where they already are. Editing the bundle is
      then live, and there is exactly one copy on disk to keep straight.

      The cost is paid where it is stated: move or delete that folder and the
      commands stop resolving. An archive store has no such folder, so bundles
      from one are still copied. }
    Origin: string;
    Artifacts: TAddonArtifacts;
    Files: TArray<string>;
    Roots: TArray<string>;  // absolute ~/.aefos target dirs to remove on uninstall
    { Decides whether this installed addon needs a refresh against the registry's
      current entry. The sha256 is the identity: equal (case-insensitive) => the
      on-disk build already matches => uaUpToDate; differ => uaUpdate. Version
      numbers are informational and never drive the decision. Only reached with a
      record that IS installed, so it never returns uaNotInstalled. }
    function DecideUpdate(const AEntry: TAddonRegistryEntry): TUpdateAction;
  end;

  EAddonError = class(Exception);
  EAddonNotFound = class(EAddonError);
  EAddonManifest = class(EAddonError);
  EAddonIntegrity = class(EAddonError);     // sha mismatch / malformed zip
  EAddonRequirement = class(EAddonError);   // aefos_version gate failed

  { Version comparison + requirement matching for the dotted-numeric addon
    versions. Static, sealed namespace - never instantiated. }
  TAddonVersion = class sealed
  public
    { Compares two dotted numeric versions ("1.2.0" vs "1.10.0"). Missing
      segments count as 0; non-numeric segments compare as 0. Returns -1/0/1. }
    class function Compare(const ALeft, ARight: string): Integer; static;
    { True when AInstalled satisfies the requirement ARequirement of the forms
      ">=X", ">X", "=X"/"X", "<=X", "<X". An empty requirement is always
      satisfied. Malformed requirements are treated as satisfied (fail-open on
      the gate text, never block a valid install on a typo). }
    class function Satisfies(const AInstalled, ARequirement: string): Boolean; static;
  end;

implementation

uses
  StrUtils;

// Classic-RTL string helpers (FPC 3.2.2 has no TStringHelper): kept
// unit-private, byte-identical to the Delphi string methods they replace for
// the inputs this unit sees (dotted numeric versions, no consecutive dots).

// Mirrors string.Split(delims): splits AText on any delimiter char, keeping
// empty segments; an empty AText yields a zero-length array.
function _SplitStr(const AText: string;
  const ADelims: array of Char): TArray<string>;
var
  LIndex, LStart, LCount, LDelim: Integer;
  LIsDelim: Boolean;
begin
  SetLength(Result, 0);
  if AText = '' then
    Exit;
  LStart := 1;
  LCount := 0;
  for LIndex := 1 to Length(AText) do
  begin
    LIsDelim := False;
    for LDelim := 0 to High(ADelims) do
      if AText[LIndex] = ADelims[LDelim] then
      begin
        LIsDelim := True;
        Break;
      end;
    if LIsDelim then
    begin
      SetLength(Result, LCount + 1);
      Result[LCount] := Copy(AText, LStart, LIndex - LStart);
      Inc(LCount);
      LStart := LIndex + 1;
    end;
  end;
  SetLength(Result, LCount + 1);
  Result[LCount] := Copy(AText, LStart, Length(AText) - LStart + 1);
end;

// Mirrors string.StartsWith(prefix) (case-sensitive), including the RTL's
// empty-prefix rule: StartsWith('') is True.
function _StartsWith(const AText, APrefix: string): Boolean;
begin
  Result := Copy(AText, 1, Length(APrefix)) = APrefix;
end;

{ TAddonTrustHelper }

class function TAddonTrustHelper.Parse(const AValue: string): TAddonTrust;
begin
  if SameText(Trim(AValue), 'official') then
    Result := atOfficial
  else
    Result := atCommunity;
end;

function TAddonTrustHelper.ToStr: string;
begin
  if Self = atOfficial then
    Result := 'official'
  else
    Result := 'community';
end;

{ TAddonKindHelper }

class function TAddonKindHelper.Parse(const AValue: string): TAddonKind;
var
  LValue: string;
begin
  LValue := Trim(AValue);
  if SameText(LValue, 'mcp') then
    Result := akMcp
  else if SameText(LValue, 'tool') or SameText(LValue, 'tools') then
    Result := akTool
  else
    Result := akCommand;
end;

function TAddonKindHelper.ToStr: string;
begin
  case Self of
    akMcp: Result := 'mcp';
    akTool: Result := 'tool';
  else
    Result := 'command';
  end;
end;

{ TInstalledAddon }

function TInstalledAddon.DecideUpdate(
  const AEntry: TAddonRegistryEntry): TUpdateAction;
begin
  if SameText(Trim(Self.Sha256), Trim(AEntry.Sha256)) then
    Result := uaUpToDate
  else
    Result := uaUpdate;
end;

{ TAddonVersion }

function _SegAt(const AParts: TArray<string>; const AIndex: Integer): Integer;
begin
  if AIndex > High(AParts) then
    Exit(0);
  Result := StrToIntDef(Trim(AParts[AIndex]), 0);
end;

class function TAddonVersion.Compare(const ALeft, ARight: string): Integer;
var
  LLeft, LRight: TArray<string>;
  LCount, LIndex, LVa, LVb: Integer;
begin
  LLeft := _SplitStr(ALeft, ['.']);
  LRight := _SplitStr(ARight, ['.']);
  LCount := Length(LLeft);
  if Length(LRight) > LCount then
    LCount := Length(LRight);
  for LIndex := 0 to LCount - 1 do
  begin
    LVa := _SegAt(LLeft, LIndex);
    LVb := _SegAt(LRight, LIndex);
    if LVa < LVb then
      Exit(-1);
    if LVa > LVb then
      Exit(1);
  end;
  Result := 0;
end;

class function TAddonVersion.Satisfies(const AInstalled,
  ARequirement: string): Boolean;
var
  LReq, LOp, LVer: string;
  LCmp: Integer;
begin
  LReq := Trim(ARequirement);
  if LReq = '' then
    Exit(True);
  // Peel the leading operator; default '=' when only a bare version is given.
  if _StartsWith(LReq, '>=') then begin LOp := '>='; LVer := Copy(LReq, 3, MaxInt); end
  else if _StartsWith(LReq, '<=') then begin LOp := '<='; LVer := Copy(LReq, 3, MaxInt); end
  else if _StartsWith(LReq, '>') then begin LOp := '>'; LVer := Copy(LReq, 2, MaxInt); end
  else if _StartsWith(LReq, '<') then begin LOp := '<'; LVer := Copy(LReq, 2, MaxInt); end
  else if _StartsWith(LReq, '=') then begin LOp := '='; LVer := Copy(LReq, 2, MaxInt); end
  else begin LOp := '='; LVer := LReq; end;
  LVer := Trim(LVer);
  if LVer = '' then
    Exit(True); // malformed => fail-open
  LCmp := TAddonVersion.Compare(Trim(AInstalled), LVer);
  if LOp = '>=' then Result := LCmp >= 0
  else if LOp = '<=' then Result := LCmp <= 0
  else if LOp = '>' then Result := LCmp > 0
  else if LOp = '<' then Result := LCmp < 0
  else Result := LCmp = 0;
end;

end.
