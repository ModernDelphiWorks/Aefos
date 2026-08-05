unit Aefos.MCP.OTA.MessageTextPolicy;

{
  Pure display-text normalization seam (ESP-093, S1 / ADR-093-02 / BR1 / BR3).

  Pure RTL — no ToolsAPI, no VCL, no file IO. EnsureDisplayText repairs the
  "UTF-8 bytes decoded as a single-byte OEM/ANSI codepage" mojibake that arises
  when a non-ASCII MCP argument crosses a decode boundary that used the console
  OEM codepage instead of UTF-8 (upstream ask #9). Live S0 measured the boundary
  as CP850 (E2 80 94 "—" -> Ô Ç ö; C3 A7 C3 A3 "çã" -> ├ º ├ ú), not the
  Windows-1252 the architect assumed — both are covered below.

  The true decode boundary is corrected at the stdio<->pipe bridge
  (Test/MCP/mcp-bridge.ps1, InputEncoding=UTF8); this seam is the in-memory,
  idempotent repair applied at the Terminal display surfaces (consent dialog
  preview, audit-line preview) as defense-in-depth for any string that still
  arrives mojibake'd (a client bypassing the fixed bridge).

  Conservative + idempotent (ADR-093-02 / R2): a clean ASCII or Unicode string
  passes through byte-identical, and applying the function twice equals applying
  it once. Repair fires only when re-encoding the string through a candidate
  single-byte codepage yields a byte sequence that is well-formed UTF-8 with at
  least one multi-byte sequence AND the codepage round-trips every character
  faithfully (a character the codepage cannot represent vetoes that candidate).
  CP850 (the measured OEM console codepage) is tried first, then Windows-1252.

  #23 (GetCompilerErrors BRCC32) closed as no-viable-ota-path in S0 — OTA's
  IOTAMessageServices is add-only with no read-back of existing Messages/Build
  -pane lines — so ParseBrcc32ErrorLine is intentionally NOT part of this seam
  (ADR-093-03 / BR5); adding it would be dead code.
}

interface

type
  // Pure display-text normalization seam as a sealed static namespace
  // (see the unit header for the ESP-093 / ADR-093 contract). Never instantiated.
  TMessageTextPolicy = class sealed
  public
    // Repair UTF-8-as-OEM/ANSI mojibake in AText, returning faithful Unicode.
    // Idempotent: clean ASCII/Unicode passes through unchanged; double-apply =
    // single-apply. '' -> ''.
    class function EnsureDisplayText(const AText: string): string; static;
  end;

implementation

uses
  System.SysUtils;

const
  // Candidate single-byte codepages a non-UTF-8 decode boundary may have used.
  // CP850 is the measured OEM console codepage (ESP-093 S0); 1252 is the ANSI
  // fallback documented by the upstream ask. Tried in order; first hit wins.
  CMojibakeCodepages: array[0..1] of Integer = (850, 1252);

  CReplacementChar = #$FFFD;

// True when AText contains only 7-bit ASCII — nothing can be part of a multi-byte
// UTF-8 sequence, so the fast, always-safe passthrough path applies.
function _IsPureAscii(const AText: string): Boolean;
var
  LCh: Char;
begin
  for LCh in AText do
    if Ord(LCh) > $7F then
      Exit(False);
  Result := True;
end;

// Number of continuation bytes a UTF-8 lead byte announces: 0 for ASCII, 1..3
// for a multi-byte lead, -1 for a stray continuation or illegal lead byte.
function _Utf8FollowCount(AByte: Byte): Integer;
begin
  if AByte <= $7F then
    Result := 0
  else if (AByte >= $C2) and (AByte <= $DF) then
    Result := 1
  else if (AByte >= $E0) and (AByte <= $EF) then
    Result := 2
  else if (AByte >= $F0) and (AByte <= $F4) then
    Result := 3
  else
    Result := -1;
end;

// True when ABytes is well-formed UTF-8 carrying at least one multi-byte
// sequence. A pure-ASCII run (nothing to recover) and any malformed sequence
// (never repair on a guess) both return False.
function _IsMultibyteUtf8(const ABytes: TBytes): Boolean;
var
  LIdx, LLen, LFollow, LFor: Integer;
  LHasMulti: Boolean;
begin
  LHasMulti := False;
  LIdx := 0;
  LLen := Length(ABytes);
  while LIdx < LLen do
  begin
    LFollow := _Utf8FollowCount(ABytes[LIdx]);
    if (LFollow < 0) or (LIdx + LFollow >= LLen) then
      Exit(False);
    for LFor := 1 to LFollow do
      if (ABytes[LIdx + LFor] and $C0) <> $80 then
        Exit(False);
    if LFollow > 0 then
      LHasMulti := True;
    Inc(LIdx, LFollow + 1);
  end;
  Result := LHasMulti;
end;

// Attempt the repair through one codepage. True + ARepaired only when the
// codepage faithfully holds every char (encode->decode round-trips to AText) AND
// its bytes are well-formed multi-byte UTF-8 that decode without loss to a string
// different from AText.
function _TryRepair(const AText: string; ACodepage: Integer;
  out ARepaired: string): Boolean;
var
  LEnc: TEncoding;
  LBytes: TBytes;
  LDecoded: string;
begin
  Result := False;
  ARepaired := '';
  try
    LEnc := TEncoding.GetEncoding(ACodepage);
  except
    // Codepage unavailable on this host -> cannot repair through it (not an error
    // to surface: the caller simply falls through to the next candidate / no-op).
    Exit;
  end;
  try
    LBytes := LEnc.GetBytes(AText);
    // Faithfulness veto: an unrepresentable char is substituted on encode, so the
    // bytes no longer describe the original -> reject this candidate (R2 guard).
    if LEnc.GetString(LBytes) <> AText then
      Exit;
  finally
    LEnc.Free;
  end;
  if not _IsMultibyteUtf8(LBytes) then
    Exit;
  LDecoded := TEncoding.UTF8.GetString(LBytes);
  if (LDecoded = '') or (LDecoded = AText) or LDecoded.Contains(CReplacementChar) then
    Exit;
  ARepaired := LDecoded;
  Result := True;
end;

class function TMessageTextPolicy.EnsureDisplayText(const AText: string): string;
var
  LCp: Integer;
  LRepaired: string;
begin
  Result := AText;
  if (AText = '') or _IsPureAscii(AText) then
    Exit;
  for LCp in CMojibakeCodepages do
    if _TryRepair(AText, LCp, LRepaired) then
      Exit(LRepaired);
end;

end.
