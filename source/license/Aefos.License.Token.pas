unit Aefos.License.Token;

{
  Offline verification of the server's RS256 license token (Phase 2).

  The Edge Function signs a JWT (claims: license_id, fingerprint, tier, status,
  iat, exp) with its RSA-2048 private key. This unit verifies the signature OFFLINE with the
  matching PUBLIC key (embedded below) via Windows CNG (bcrypt.dll), so the cached
  license state cannot be forged by editing license.dat — a tampered token fails
  the signature check.

  Public key only (modulus + exponent) — safe to ship in the BPL. Pure WinAPI +
  RTL; no ToolsAPI/VCL.
}

interface

type
  TLicenseClaims = record
    Valid: Boolean;        // RS256 signature verified AND payload parsed
    Tier: string;
    Status: string;
    Fingerprint: string;
    Exp: Int64;            // expiry, unix seconds (the offline-grace deadline)
  end;

// Verifies the token's RS256 signature with the embedded public key and returns
// its claims. Valid=False on any failure (bad shape, bad signature, parse error).
// Does NOT check fingerprint/exp — the caller compares those to this machine/now.
function VerifyLicenseToken(const AToken: string): TLicenseClaims;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.NetEncoding,
  System.Hash,
  System.JSON;

const
  // RSA-2048 PUBLIC key matching the AEFOS_LICENSE_PRIVKEY_B64 server secret.
  // Big-endian modulus + exponent, standard base64. PUBLIC — safe to embed.
  PUB_MODULUS_B64 =
    '1b9YFBM4oOZ/64uW9JD3zhpwxH2DX8ALu+RNnMxoxWZcEAPwMEIOOD0te81xIFY/obo67ahNj/P' +
    'sPb/Vs1vdoNs4gzoZ8cHIsqm1nV1c9XJinxkcSvZSW2EQfpcC6oynUnGzh8gqDxBok3r1Xrl3WV' +
    'HCbJaeoTcbnHm1m+FdDtVNIgTYGbVoZu/5SvyG3InIgdN3NM2SXBO10fjBwPpn9Ih+flmssK6FX' +
    '+vUXVWargsX2AEDkPWBn91Jdy+mB9n5jk3rALkrCNNMK2hbpW+JxJThU9pDdKMMV6yXKCqe4C7R' +
    'gpJG8MnwW8tvEIavy566BRr3c7BcxJCdwSOFLiGNmQ==';
  PUB_EXPONENT_B64 = 'AQAB';

  bcryptlib = 'bcrypt.dll';
  BCRYPT_RSAPUBLIC_MAGIC = $31415352;     // 'RSA1'
  BCRYPT_PAD_PKCS1       = $00000002;

type
  BCRYPT_RSAKEY_BLOB = record
    Magic: ULONG;
    BitLength: ULONG;
    cbPublicExp: ULONG;
    cbModulus: ULONG;
    cbPrime1: ULONG;
    cbPrime2: ULONG;
  end;

  BCRYPT_PKCS1_PADDING_INFO = record
    pszAlgId: PWideChar;
  end;

function BCryptOpenAlgorithmProvider(out phAlgorithm: THandle;
  pszAlgId, pszImplementation: PWideChar; dwFlags: ULONG): Integer; stdcall;
  external bcryptlib name 'BCryptOpenAlgorithmProvider';
function BCryptCloseAlgorithmProvider(hAlgorithm: THandle;
  dwFlags: ULONG): Integer; stdcall;
  external bcryptlib name 'BCryptCloseAlgorithmProvider';
function BCryptImportKeyPair(hAlgorithm, hImportKey: THandle;
  pszBlobType: PWideChar; out phKey: THandle; pbInput: PByte; cbInput: ULONG;
  dwFlags: ULONG): Integer; stdcall;
  external bcryptlib name 'BCryptImportKeyPair';
function BCryptDestroyKey(hKey: THandle): Integer; stdcall;
  external bcryptlib name 'BCryptDestroyKey';
function BCryptVerifySignature(hKey: THandle; pPaddingInfo: Pointer;
  pbHash: PByte; cbHash: ULONG; pbSignature: PByte; cbSignature: ULONG;
  dwFlags: ULONG): Integer; stdcall;
  external bcryptlib name 'BCryptVerifySignature';

// base64url -> bytes (the JWT parts). Standard base64 helpers handle the rest.
function _B64UrlDecode(const AStr: string): TBytes;
var
  LNormalized: string;
begin
  LNormalized := AStr.Replace('-', '+', [rfReplaceAll]).Replace('_', '/', [rfReplaceAll]);
  case Length(LNormalized) mod 4 of
    2: LNormalized := LNormalized + '==';
    3: LNormalized := LNormalized + '=';
  end;
  Result := TNetEncoding.Base64.DecodeStringToBytes(LNormalized);
end;

// Builds the BCRYPT_RSAPUBLIC_BLOB (header + exponent + modulus) for import.
function _PublicKeyBlob: TBytes;
var
  LMod, LExp: TBytes;
  LHdr: BCRYPT_RSAKEY_BLOB;
begin
  LMod := TNetEncoding.Base64.DecodeStringToBytes(PUB_MODULUS_B64);  // big-endian
  LExp := TNetEncoding.Base64.DecodeStringToBytes(PUB_EXPONENT_B64);
  LHdr.Magic := BCRYPT_RSAPUBLIC_MAGIC;
  LHdr.BitLength := Length(LMod) * 8;
  LHdr.cbPublicExp := Length(LExp);
  LHdr.cbModulus := Length(LMod);
  LHdr.cbPrime1 := 0;
  LHdr.cbPrime2 := 0;
  SetLength(Result, SizeOf(LHdr) + Length(LExp) + Length(LMod));
  Move(LHdr, Result[0], SizeOf(LHdr));
  Move(LExp[0], Result[SizeOf(LHdr)], Length(LExp));
  Move(LMod[0], Result[SizeOf(LHdr) + Length(LExp)], Length(LMod));
end;

function _Sha256(const AText: string): TBytes;
var
  LHash: THashSHA2;
  LBytes: TBytes;
begin
  // Hash the explicit UTF-8 bytes (the server signs enc.encode(input)); the
  // input is pure ASCII, so this matches byte-for-byte.
  LBytes := TEncoding.UTF8.GetBytes(AText);
  LHash := THashSHA2.Create;  // SHA-256 default
  if Length(LBytes) > 0 then
    LHash.Update(LBytes[0], Length(LBytes));  // untyped overload: addr + length
  Result := LHash.HashAsBytes;
end;

function VerifyLicenseToken(const AToken: string): TLicenseClaims;
var
  LParts: TArray<string>;
  LSig, LHash, LBlob, LPayload: TBytes;
  LAlgHandle, LKeyHandle: THandle;
  LPad: BCRYPT_PKCS1_PADDING_INFO;
  LJson: TJSONValue;
  LObj: TJSONObject;
begin
  Result := Default(TLicenseClaims);
  LParts := AToken.Split(['.']);
  if Length(LParts) <> 3 then
    Exit;
  try
    LSig := _B64UrlDecode(LParts[2]);
    LHash := _Sha256(LParts[0] + '.' + LParts[1]);
    LBlob := _PublicKeyBlob;
    if (Length(LSig) = 0) or (Length(LHash) = 0) then
      Exit;

    if BCryptOpenAlgorithmProvider(LAlgHandle, 'RSA', nil, 0) <> 0 then
      Exit;
    try
      if BCryptImportKeyPair(LAlgHandle, 0, 'RSAPUBLICBLOB', LKeyHandle,
        @LBlob[0], Length(LBlob), 0) <> 0 then
        Exit;
      try
        LPad.pszAlgId := 'SHA256';
        // 0 == STATUS_SUCCESS: the signature is valid for this public key.
        if BCryptVerifySignature(LKeyHandle, @LPad, @LHash[0], Length(LHash),
          @LSig[0], Length(LSig), BCRYPT_PAD_PKCS1) <> 0 then
          Exit;

        LPayload := _B64UrlDecode(LParts[1]);
        LJson := TJSONObject.ParseJSONValue(TEncoding.UTF8.GetString(LPayload));
        if LJson is TJSONObject then
        try
          LObj := LJson as TJSONObject;
          Result.Tier := LObj.GetValue<string>('tier', '');
          Result.Status := LObj.GetValue<string>('status', '');
          Result.Fingerprint := LObj.GetValue<string>('fingerprint', '');
          Result.Exp := LObj.GetValue<Int64>('exp', 0);
          Result.Valid := True;
        finally
          LJson.Free;
        end
        else if Assigned(LJson) then
          LJson.Free;
      finally
        BCryptDestroyKey(LKeyHandle);
      end;
    finally
      BCryptCloseAlgorithmProvider(LAlgHandle, 0);
    end;
  except
    Result := Default(TLicenseClaims);
  end;
end;

end.
