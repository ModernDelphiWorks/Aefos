unit Aefos.Compat.Sha256;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  SHA-256 compatibility shim (Aefos -> Lazarus port, Milestone 1 / Phase A).

  Single uses-target for SHA-256 hashing so the swept MCP core stays
  single-source across Delphi and FPC 3.2.2.

  - Delphi (not FPC): delegates to System.Hash.THashSHA2 (byte-identical
    to the pre-shim behaviour).
  - FPC: a hand-rolled FIPS 180-4 SHA-256. FPC 3.2.2's RTL ships
    no SHA-256 (the `hash` package carries only md5/sha1/hmac/crc), so a
    self-contained implementation is required -- no third-party dependency.

  Both sides return the digest as LOWERCASE hex, matching the original
  `LowerCase(THashSHA2.HashAsString)` call site in Aefos.MCP.EditTracker.

  Known-answer vectors (verified in the pure suite):
    ''    -> e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    'abc' -> ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
}

interface

{$IFNDEF FPC}
uses
  System.SysUtils;
{$ELSE}
uses
  SysUtils,
  Classes;
{$ENDIF}

type
  // Static namespace: SHA-256 of a UTF-8 string or a raw byte array,
  // rendered as lowercase hex. Never instantiated.
  TAefosSha256 = class sealed
  public
    // SHA-256 of the UTF-8 encoding of AText, as lowercase hex (64 chars).
    class function HexDigest(const AText: string): string; overload; static;
    // SHA-256 of the raw bytes, as lowercase hex (64 chars).
    class function HexDigest(const ABytes: TBytes): string; overload; static;
    // SHA-256 of a file's bytes, as lowercase hex (64 chars).
    class function HexDigestFile(const APath: string): string; static;
  end;

implementation

{$IFNDEF FPC}

uses
  System.Hash;

class function TAefosSha256.HexDigest(const AText: string): string;
begin
  Result := LowerCase(THashSHA2.GetHashString(AText, THashSHA2.TSHA2Version.SHA256));
end;

class function TAefosSha256.HexDigest(const ABytes: TBytes): string;
var
  LHash: THashSHA2;
begin
  LHash := THashSHA2.Create(THashSHA2.TSHA2Version.SHA256);
  LHash.Update(ABytes);
  Result := LowerCase(LHash.HashAsString);
end;

class function TAefosSha256.HexDigestFile(const APath: string): string;
begin
  Result := LowerCase(THashSHA2.GetHashStringFromFile(APath,
    THashSHA2.TSHA2Version.SHA256));
end;

{$ELSE}

{$Q-}{$R-}   // SHA-256 relies on 32-bit modular (wrapping) arithmetic.

type
  TSha256State = array[0..7] of Cardinal;
  TSha256Block = array[0..15] of Cardinal;

const
  CSha256K: array[0..63] of Cardinal = (
    $428a2f98, $71374491, $b5c0fbcf, $e9b5dba5, $3956c25b, $59f111f1, $923f82a4, $ab1c5ed5,
    $d807aa98, $12835b01, $243185be, $550c7dc3, $72be5d74, $80deb1fe, $9bdc06a7, $c19bf174,
    $e49b69c1, $efbe4786, $0fc19dc6, $240ca1cc, $2de92c6f, $4a7484aa, $5cb0a9dc, $76f988da,
    $983e5152, $a831c66d, $b00327c8, $bf597fc7, $c6e00bf3, $d5a79147, $06ca6351, $14292967,
    $27b70a85, $2e1b2138, $4d2c6dfc, $53380d13, $650a7354, $766a0abb, $81c2c92e, $92722c85,
    $a2bfe8a1, $a81a664b, $c24b8b70, $c76c51a3, $d192e819, $d6990624, $f40e3585, $106aa070,
    $19a4c116, $1e376c08, $2748774c, $34b0bcb5, $391c0cb3, $4ed8aa4a, $5b9cca4f, $682e6ff3,
    $748f82ee, $78a5636f, $84c87814, $8cc70208, $90befffa, $a4506ceb, $bef9a3f7, $c67178f2);

function _RotR(const AValue: Cardinal; const ABits: Byte): Cardinal; inline;
begin
  Result := (AValue shr ABits) or (AValue shl (32 - ABits));
end;

procedure _ProcessBlock(var AState: TSha256State; const ABlock: TSha256Block);
var
  LW: array[0..63] of Cardinal;
  LIndex: Integer;
  LA, LB, LC, LD, LE, LF, LG, LH: Cardinal;
  LS0, LS1, LCh, LMaj, LT1, LT2: Cardinal;
begin
  for LIndex := 0 to 15 do
    LW[LIndex] := ABlock[LIndex];
  for LIndex := 16 to 63 do
  begin
    LS0 := _RotR(LW[LIndex - 15], 7) xor _RotR(LW[LIndex - 15], 18) xor (LW[LIndex - 15] shr 3);
    LS1 := _RotR(LW[LIndex - 2], 17) xor _RotR(LW[LIndex - 2], 19) xor (LW[LIndex - 2] shr 10);
    LW[LIndex] := LW[LIndex - 16] + LS0 + LW[LIndex - 7] + LS1;
  end;

  LA := AState[0]; LB := AState[1]; LC := AState[2]; LD := AState[3];
  LE := AState[4]; LF := AState[5]; LG := AState[6]; LH := AState[7];

  for LIndex := 0 to 63 do
  begin
    LS1 := _RotR(LE, 6) xor _RotR(LE, 11) xor _RotR(LE, 25);
    LCh := (LE and LF) xor ((not LE) and LG);
    LT1 := LH + LS1 + LCh + CSha256K[LIndex] + LW[LIndex];
    LS0 := _RotR(LA, 2) xor _RotR(LA, 13) xor _RotR(LA, 22);
    LMaj := (LA and LB) xor (LA and LC) xor (LB and LC);
    LT2 := LS0 + LMaj;
    LH := LG; LG := LF; LF := LE; LE := LD + LT1;
    LD := LC; LC := LB; LB := LA; LA := LT1 + LT2;
  end;

  AState[0] := AState[0] + LA; AState[1] := AState[1] + LB;
  AState[2] := AState[2] + LC; AState[3] := AState[3] + LD;
  AState[4] := AState[4] + LE; AState[5] := AState[5] + LF;
  AState[6] := AState[6] + LG; AState[7] := AState[7] + LH;
end;

function _Sha256Raw(const ABytes: TBytes): string;
var
  LState: TSha256State;
  LBlock: TSha256Block;
  LPadded: TBytes;
  LMsgLen, LTotalLen, LOffset, LBlockStart: Integer;
  LBitLen: UInt64;
  LIndex, LByteIndex: Integer;
  LHexDigits: string;
  LWord: Cardinal;
begin
  LState[0] := $6a09e667; LState[1] := $bb67ae85;
  LState[2] := $3c6ef372; LState[3] := $a54ff53a;
  LState[4] := $510e527f; LState[5] := $9b05688c;
  LState[6] := $1f83d9ab; LState[7] := $5be0cd19;

  LMsgLen := Length(ABytes);
  LBitLen := UInt64(LMsgLen) * 8;

  // Padded length: message + 0x80 + zeros to reach 56 mod 64 + 8 length bytes.
  LTotalLen := LMsgLen + 1;
  while (LTotalLen mod 64) <> 56 do
    Inc(LTotalLen);
  Inc(LTotalLen, 8);

  SetLength(LPadded, LTotalLen);
  if LMsgLen > 0 then
    Move(ABytes[0], LPadded[0], LMsgLen);
  LPadded[LMsgLen] := $80;
  for LOffset := LMsgLen + 1 to LTotalLen - 9 do
    LPadded[LOffset] := 0;
  // Big-endian 64-bit bit length in the final 8 bytes.
  for LIndex := 0 to 7 do
    LPadded[LTotalLen - 1 - LIndex] := Byte((LBitLen shr (8 * LIndex)) and $FF);

  LBlockStart := 0;
  while LBlockStart < LTotalLen do
  begin
    for LIndex := 0 to 15 do
    begin
      LByteIndex := LBlockStart + LIndex * 4;
      LBlock[LIndex] := (Cardinal(LPadded[LByteIndex]) shl 24) or
                        (Cardinal(LPadded[LByteIndex + 1]) shl 16) or
                        (Cardinal(LPadded[LByteIndex + 2]) shl 8) or
                        (Cardinal(LPadded[LByteIndex + 3]));
    end;
    _ProcessBlock(LState, LBlock);
    Inc(LBlockStart, 64);
  end;

  LHexDigits := '0123456789abcdef';
  SetLength(Result, 64);
  for LIndex := 0 to 7 do
  begin
    LWord := LState[LIndex];
    for LByteIndex := 0 to 3 do
    begin
      Result[LIndex * 8 + LByteIndex * 2 + 1] := LHexDigits[((LWord shr (24 - LByteIndex * 8)) shr 4) and $0F + 1];
      Result[LIndex * 8 + LByteIndex * 2 + 2] := LHexDigits[((LWord shr (24 - LByteIndex * 8))) and $0F + 1];
    end;
  end;
end;

class function TAefosSha256.HexDigest(const AText: string): string;
begin
  Result := _Sha256Raw(TEncoding.UTF8.GetBytes(AText));
end;

class function TAefosSha256.HexDigest(const ABytes: TBytes): string;
begin
  Result := _Sha256Raw(ABytes);
end;

class function TAefosSha256.HexDigestFile(const APath: string): string;
var
  LStream: TFileStream;
  LBytes: TBytes;
begin
  LStream := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(LBytes, LStream.Size);
    if Length(LBytes) > 0 then
      LStream.ReadBuffer(LBytes[0], Length(LBytes));
  finally
    LStream.Free;
  end;
  Result := _Sha256Raw(LBytes);
end;

{$ENDIF}

end.
