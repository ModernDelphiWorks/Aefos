unit Aefos.License.Client;
{$IFDEF FPC}{$mode delphiunicode}{$H+}{$ENDIF}

{
  Aefos licensing client (Phase 1 — online activate/validate + local cache).

  Node-locked seat with self-transfer. The server (a Supabase Edge Function
  named `license`) enforces the seat limit atomically: one key can
  never have more active fingerprints than its seats (default 1) -> a single
  license never enables a second IDE at the same time.

  This unit:
   - computes a stable fingerprint for THIS Delphi copy on THIS machine/user;
   - calls the Edge Function to activate / deactivate / validate (heartbeat);
   - caches the last good result at %APPDATA%\Aefos\license.dat so the IDE keeps
     working OFFLINE within a grace window, and runs a built-in TRIAL when no key
     is present yet.

  PHASE 2 (later): the server will return an RS256-signed token; this unit will
  verify it offline via Windows CNG (embedded RSA public key) for tamper
  resistance. Phase 1 trusts the cached result (good enough to wire the flow).

  Lives in the dedicated Aefos.License BPL (a passive runtime package both the
  Chat and Terminal design BPLs `require`) so they share ONE license gate.
  Pure RTL + WinAPI + System.Net — no ToolsAPI, no VCL, so it is unit-testable.
}

interface

type
  TAefosLicenseState = (
    lsUnknown,      // not yet checked this session
    lsActive,       // a valid key, bound to this machine
    lsTrial,        // no key, still inside the trial window
    lsExpired,      // key/subscription past expires_at, or trial elapsed
    lsInvalid,      // server rejected the key
    lsSeatLimit,    // key valid but all seats are used elsewhere
    lsUnlicensed    // no key and trial elapsed
  );

  TAefosLicenseInfo = record
    State: TAefosLicenseState;
    Key: string;
    Reason: string;        // server reason on failure (invalid-key/seat-limit/expired)
    ExpiresAt: string;     // ISO-8601; '' = perpetual
    Seats: Integer;
    SeatsUsed: Integer;
    TrialDaysLeft: Integer;
    Tier: string;          // license tier (free/pro/...) — for per-tier gating
    FromCache: Boolean;    // True when answered offline from the cached result
  end;

// SHA-256 of (MachineGuid + UserName + ComputerName + BdsVer) — identifies one
// Delphi copy for one user on one machine. (Phase 2 may switch UserName -> SID.)
function LicenseFingerprint: string;

// Online: bind this fingerprint to AKey (consumes/refreshes a seat). On success
// the key + result are cached. Returns the resulting info either way.
function LicenseActivate(const AKey: string; out AInfo: TAefosLicenseInfo): Boolean;

// Online: capture the lead (email/name/company/consent), mint-or-find a free
// license, and activate THIS machine — all server-side, in one call. On success
// the issued key is cached (so the IDE is immediately licensed) and the server
// emails the serial. The Free->Licensed registration funnel.
function LicenseRegister(const AEmail, AName, ACompany: string;
  const AConsent: Boolean; out AInfo: TAefosLicenseInfo): Boolean;

// Online: free this fingerprint's seat for the stored key (self-transfer), then
// drop the local cache so this IDE falls back to trial/unlicensed.
function LicenseDeactivate(out AReason: string): Boolean;

// Online heartbeat for the stored key: refreshes last_seen + the cache. Catches
// remote deactivation / revocation / expiry.
function LicenseValidate(out AInfo: TAefosLicenseInfo): Boolean;

// Offline-friendly current state: stored key within grace => lsActive(FromCache);
// no key but within trial => lsTrial; otherwise lsExpired/lsUnlicensed. Never
// hits the network — call this for the gate on every IDE start; call
// LicenseValidate opportunistically when online.
function LicenseCurrent: TAefosLicenseInfo;

// The gate: True when the plugin's licensed features may run (active, or cached
// within grace, or in trial).
function LicenseIsUsable: Boolean;

implementation

uses
  {$IFNDEF FPC}
  System.SysUtils,
  System.Classes,
  System.Hash,
  System.JSON,
  System.IOUtils,
  System.DateUtils,
  System.Net.HttpClient,
  System.Net.URLClient,
  Winapi.Windows,
  System.Win.Registry,
  Aefos.License.Token;
  {$ELSE}
  // FPC/Lazarus edition: the Delphi RTL units are replaced by the cross-compiler
  // compat shims (same behaviour, one source). The RS256 token verifier
  // (Aefos.License.Token) uses Windows CNG + System.* only and is NOT ported this
  // round, so it is Delphi-only; on FPC the token block below is compiled out and
  // the client falls back to the Phase-1 grace/trial logic (documented at the
  // token block).
  SysUtils,
  DateUtils,          // LocalTimeToUniversal / DateToISO8601 / TryISO8601ToDate / IncDay / DaysBetween
  Registry,           // TRegistry (fcl-registry)
  Windows,            // HKEY_LOCAL_MACHINE / KEY_READ / KEY_WOW64_64KEY
  Aefos.Compat.Sha256,
  Aefos.Compat.Json,
  Aefos.Compat.IO,
  Aefos.Compat.Http;
  {$ENDIF}

const
  // Client config for project eoaqhticowfjbyoihtin. The publishable key is PUBLIC
  // (safe to embed); the Edge Function holds the service-role secret server-side.
  LICENSE_FN_URL = 'https://eoaqhticowfjbyoihtin.supabase.co/functions/v1/license';
  LICENSE_API_KEY = 'sb_publishable_ZoCnFaedCZCi7w82xLtogQ_k0q_c-pZ';
  {$IFNDEF FPC}
  BDS_VER         = '37.0';
  {$ELSE}
  // "License per IDE" (owner decision): the IDE-tag component of the fingerprint
  // is what makes the Delphi and the Lazarus editions register as DISTINCT
  // nodes/seats on the server, even on the same machine+user. The Lazarus tag is
  // a STABLE family token (NOT versioned) so a Lazarus upgrade (2.2 -> 3.0) never
  // burns the user's seat; the Delphi side stays versioned via BDS_VER. Only the
  // fingerprint VALUE changes here - the Edge Function protocol is identical.
  LAZ_IDE_TAG     = 'lazarus';
  {$ENDIF}

  GRACE_DAYS = 14;  // offline tolerance for an activated key
  TRIAL_DAYS = 14;  // unlicensed trial window

// Local->UTC "now". On Delphi via TTimeZone; on FPC via DateUtils
// LocalTimeToUniversal (FPC has no System.DateUtils.TTimeZone). Both yield the
// same instant, so the grace/trial math is identical across editions.
function _NowUtc: TDateTime;
begin
  {$IFDEF FPC}
  Result := LocalTimeToUniversal(Now);
  {$ELSE}
  Result := TTimeZone.Local.ToUniversalTime(Now);
  {$ENDIF}
end;

// ── Local store: %APPDATA%\Aefos\license.dat (small JSON) ─────────────────────

function _StorePath: string;
begin
  Result := TPath.Combine(
    TPath.Combine(TPath.GetHomePath, 'Aefos'), 'license.dat');
end;

function _LoadStore: TJSONObject;
var
  LText: string;
begin
  Result := nil;
  try
    if TFile.Exists(_StorePath) then
    begin
      LText := TFile.ReadAllText(_StorePath, TEncoding.UTF8);
      Result := TJSONObject.ParseJSONValue(LText) as TJSONObject;
    end;
  except
    Result := nil;
  end;
  if not Assigned(Result) then
    Result := TJSONObject.Create;
end;

procedure _SaveStore(const AObj: TJSONObject);
begin
  try
    TDirectory.CreateDirectory(TPath.GetDirectoryName(_StorePath));
    TFile.WriteAllText(_StorePath, AObj.ToJSON, TEncoding.UTF8);
  except
    // best-effort persistence; a read-only profile just loses offline grace
  end;
end;

function _NowUtcIso: string;
begin
  Result := DateToISO8601(_NowUtc, True);
end;

// ── Fingerprint ───────────────────────────────────────────────────────────────

function _RegRead(ARoot: HKEY; const AKey, AName: string): string;
var
  LReg: TRegistry;
begin
  Result := '';
  LReg := TRegistry.Create(KEY_READ or KEY_WOW64_64KEY);
  try
    LReg.RootKey := ARoot;
    if LReg.OpenKeyReadOnly(AKey) then
      try
        if LReg.ValueExists(AName) then
          Result := LReg.ReadString(AName);
      finally
        LReg.CloseKey;
      end;
  except
    Result := '';
  end;
  LReg.Free;
end;

function _Env(const AName: string): string;
{$IFNDEF FPC}
var
  LBuf: array[0..1023] of Char;
  LLen: DWORD;
begin
  LLen := GetEnvironmentVariable(PChar(AName), LBuf, Length(LBuf));
  if (LLen > 0) and (LLen < DWORD(Length(LBuf))) then
    SetString(Result, LBuf, LLen)
  else
    Result := '';
end;
{$ELSE}
begin
  // SysUtils.GetEnvironmentVariable (1-arg, returns the value) - `uses Windows`
  // otherwise sequesters the 3-arg WinAPI form.
  Result := SysUtils.GetEnvironmentVariable(AName);
end;
{$ENDIF}

function LicenseFingerprint: string;
var
  LMachineGuid, LRaw: string;
begin
  LMachineGuid := _RegRead(HKEY_LOCAL_MACHINE,
    'SOFTWARE\Microsoft\Cryptography', 'MachineGuid');
  {$IFNDEF FPC}
  LRaw := LMachineGuid + '|' + _Env('USERNAME') + '|' +
          _Env('COMPUTERNAME') + '|' + BDS_VER;
  Result := THashSHA2.GetHashString(LRaw);  // default version is SHA-256
  {$ELSE}
  // Lazarus seat: the IDE-tag is the stable 'lazarus' family token (see the const
  // comment) so Delphi and Lazarus on the same machine hash to DIFFERENT
  // fingerprints -> separate seats. SHA-256 lowercase hex matches the Delphi hash.
  LRaw := LMachineGuid + '|' + _Env('USERNAME') + '|' +
          _Env('COMPUTERNAME') + '|' + LAZ_IDE_TAG;
  Result := TAefosSha256.HexDigest(LRaw);
  {$ENDIF}
end;

// ── HTTP to the Edge Function ─────────────────────────────────────────────────

// POSTs a prepared JSON body to the Edge Function and returns the parsed JSON
// object (caller owns it), or nil on a transport failure (offline / timeout).
{$IFNDEF FPC}
function _Post(const ABody: string): TJSONObject;
var
  LHttp: THTTPClient;
  LBody: TStringStream;
  LResp: IHTTPResponse;
begin
  LHttp := nil;
  LBody := nil;
  try
    try
      LHttp := THTTPClient.Create;
      LBody := TStringStream.Create(ABody, TEncoding.UTF8);
      LHttp.ConnectionTimeout := 8000;
      LHttp.ResponseTimeout := 12000;
      LHttp.CustomHeaders['apikey'] := LICENSE_API_KEY;
      LHttp.ContentType := 'application/json';
      LResp := LHttp.Post(LICENSE_FN_URL, LBody);
      Result := TJSONObject.ParseJSONValue(
        LResp.ContentAsString(TEncoding.UTF8)) as TJSONObject;
    except
      Result := nil; // offline / DNS / timeout / parse — caller falls back to cache
    end;
  finally
    LBody.Free;
    LHttp.Free;
  end;
end;
{$ELSE}
function _Post(const ABody: string): TJSONObject;
var
  LStatus: Integer;
  LResp, LErr: string;
begin
  // Same request as the Delphi THTTPClient path: JSON body + the 'apikey' header
  // the Edge Function expects, routed through the cross-compiler HTTP shim
  // (WinINet on FPC). A transport failure or malformed reply yields nil, so the
  // caller falls back to the cache exactly like the Delphi branch.
  Result := nil;
  try
    if TAefosHttp.TryPostText(LICENSE_FN_URL, ABody, 'application/json', 12000,
      LStatus, LResp, LErr, 'apikey: ' + LICENSE_API_KEY + #13#10) then
      Result := TJSONObject.ParseJSONValue(LResp) as TJSONObject;
  except
    Result := nil;
  end;
end;
{$ENDIF}

// Builds the {action,key,fingerprint,machine_label} body and POSTs it.
function _Call(const AAction, AKey: string): TJSONObject;
var
  LJson: TJSONObject;
  LReq: string;
begin
  LJson := TJSONObject.Create;
  try
    LJson.AddPair('action', AAction);
    LJson.AddPair('key', AKey);
    LJson.AddPair('fingerprint', LicenseFingerprint);
    LJson.AddPair('machine_label', _Env('COMPUTERNAME') + ' / ' + _Env('USERNAME'));
    LReq := LJson.ToJSON;
  finally
    LJson.Free;
  end;
  Result := _Post(LReq);
end;

function _JStr(const AObj: TJSONObject; const AName: string): string;
var
  LV: TJSONValue;
begin
  Result := '';
  if Assigned(AObj) then
  begin
    LV := AObj.GetValue(AName);
    if Assigned(LV) and not (LV is TJSONNull) then
      Result := LV.Value;
  end;
end;

function _JInt(const AObj: TJSONObject; const AName: string): Integer;
begin
  Result := StrToIntDef(_JStr(AObj, AName), 0);
end;

function _JBool(const AObj: TJSONObject; const AName: string): Boolean;
var
  LV: TJSONValue;
begin
  Result := False;
  if Assigned(AObj) then
  begin
    LV := AObj.GetValue(AName);
    {$IFNDEF FPC}
    Result := Assigned(LV) and (LV is TJSONTrue);
    {$ELSE}
    // The compat JSON shim has no TJSONTrue/TJSONFalse split - read the boolean
    // off TJSONBool instead (a false value is a TJSONBool with AsBoolean=False).
    Result := (LV is TJSONBool) and TJSONBool(LV).AsBoolean;
    {$ENDIF}
  end;
end;

// Maps a successful server payload to info + writes the cache (key + now + meta).
procedure _CacheSuccess(const AKey: string; const AObj: TJSONObject);
var
  LStore, LOld: TJSONObject;
  LTier, LToken: string;
begin
  // A tier-less response (e.g. an older heartbeat) must NOT wipe the cached tier
  // — fall back to whatever the cache already holds.
  LTier := _JStr(AObj, 'tier');
  LToken := _JStr(AObj, 'token');
  if (LTier = '') or (LToken = '') then
  begin
    LOld := _LoadStore;
    try
      if LTier = '' then LTier := _JStr(LOld, 'tier');
      if LToken = '' then LToken := _JStr(LOld, 'token');
    finally
      LOld.Free;
    end;
  end;
  LStore := TJSONObject.Create;
  try
    LStore.AddPair('key', AKey);
    LStore.AddPair('last_ok_utc', _NowUtcIso);
    LStore.AddPair('expires_at', _JStr(AObj, 'expires_at'));
    LStore.AddPair('tier', LTier);
    LStore.AddPair('token', LToken);
    LStore.AddPair('seats', TJSONNumber.Create(_JInt(AObj, 'seats')));
    LStore.AddPair('used', TJSONNumber.Create(_JInt(AObj, 'used')));
    // Preserve the original trial install stamp if present.
    _SaveStore(LStore);
  finally
    LStore.Free;
  end;
end;

function _Expired(const AIso: string): Boolean;
var
  LDt: TDateTime;
begin
  if Trim(AIso) = '' then Exit(False); // perpetual
  if not TryISO8601ToDate(AIso, LDt, True) then Exit(False);
  Result := LDt < _NowUtc;
end;

// ── Public API ────────────────────────────────────────────────────────────────

function LicenseActivate(const AKey: string; out AInfo: TAefosLicenseInfo): Boolean;
var
  LObj: TJSONObject;
begin
  AInfo := Default(TAefosLicenseInfo);
  AInfo.Key := AKey;
  LObj := _Call('activate', AKey);
  try
    if not Assigned(LObj) then
    begin
      AInfo.State := lsUnknown;
      AInfo.Reason := 'offline';
      Exit(False);
    end;
    if _JBool(LObj, 'ok') then
    begin
      AInfo.ExpiresAt := _JStr(LObj, 'expires_at');
      AInfo.Tier := _JStr(LObj, 'tier');
      AInfo.Seats := _JInt(LObj, 'seats');
      AInfo.SeatsUsed := _JInt(LObj, 'used');
      AInfo.State := lsActive;
      _CacheSuccess(AKey, LObj);
      Exit(True);
    end;
    AInfo.Reason := _JStr(LObj, 'error');
    if AInfo.Reason = 'seat-limit' then AInfo.State := lsSeatLimit
    else if AInfo.Reason = 'expired' then AInfo.State := lsExpired
    else AInfo.State := lsInvalid;
    Result := False;
  finally
    LObj.Free;
  end;
end;

function LicenseRegister(const AEmail, AName, ACompany: string;
  const AConsent: Boolean; out AInfo: TAefosLicenseInfo): Boolean;
var
  LJson, LObj: TJSONObject;
  LReq: string;
begin
  AInfo := Default(TAefosLicenseInfo);
  LJson := TJSONObject.Create;
  try
    LJson.AddPair('action', 'register');
    LJson.AddPair('email', AEmail);
    LJson.AddPair('name', AName);
    LJson.AddPair('company', ACompany);
    LJson.AddPair('consent', TJSONBool.Create(AConsent));
    LJson.AddPair('fingerprint', LicenseFingerprint);
    LJson.AddPair('machine_label', _Env('COMPUTERNAME') + ' / ' + _Env('USERNAME'));
    LReq := LJson.ToJSON;
  finally
    LJson.Free;
  end;
  LObj := _Post(LReq);
  try
    if not Assigned(LObj) then
    begin
      AInfo.State := lsUnknown;
      AInfo.Reason := 'offline';
      Exit(False);
    end;
    if _JBool(LObj, 'ok') then
    begin
      AInfo.Key := _JStr(LObj, 'key');
      AInfo.ExpiresAt := _JStr(LObj, 'expires_at');
      AInfo.Tier := _JStr(LObj, 'tier');
      AInfo.Seats := _JInt(LObj, 'seats');
      AInfo.SeatsUsed := _JInt(LObj, 'used');
      AInfo.State := lsActive;
      _CacheSuccess(AInfo.Key, LObj); // issued key cached => IDE is now licensed
      Exit(True);
    end;
    AInfo.Reason := _JStr(LObj, 'error');
    if AInfo.Reason = 'seat-limit' then
      AInfo.State := lsSeatLimit
    else
      AInfo.State := lsInvalid; // invalid-email / consent-required / server-error
    Result := False;
  finally
    LObj.Free;
  end;
end;

function LicenseDeactivate(out AReason: string): Boolean;
var
  LStore, LObj: TJSONObject;
  LKey: string;
begin
  AReason := '';
  LStore := _LoadStore;
  try
    LKey := _JStr(LStore, 'key');
  finally
    LStore.Free;
  end;
  if LKey = '' then
  begin
    AReason := 'no-key';
    Exit(False);
  end;
  LObj := _Call('deactivate', LKey);
  try
    if not Assigned(LObj) then
    begin
      AReason := 'offline';
      Exit(False);
    end;
    Result := _JBool(LObj, 'ok');
    if Result then
    begin
      try TFile.Delete(_StorePath); except end;
    end
    else
      AReason := _JStr(LObj, 'error');
  finally
    LObj.Free;
  end;
end;

function LicenseValidate(out AInfo: TAefosLicenseInfo): Boolean;
var
  LStore, LObj: TJSONObject;
  LKey: string;
begin
  AInfo := Default(TAefosLicenseInfo);
  LStore := _LoadStore;
  try
    LKey := _JStr(LStore, 'key');
  finally
    LStore.Free;
  end;
  AInfo.Key := LKey;
  if LKey = '' then
  begin
    AInfo := LicenseCurrent; // no key -> trial/unlicensed
    Exit(AInfo.State = lsTrial);
  end;
  LObj := _Call('validate', LKey);
  try
    if not Assigned(LObj) then
    begin
      AInfo := LicenseCurrent; // offline -> cached grace
      Exit(LicenseIsUsable);
    end;
    if _JBool(LObj, 'ok') and SameText(_JStr(LObj, 'status'), 'active')
       and _JBool(LObj, 'bound') and not _Expired(_JStr(LObj, 'expires_at')) then
    begin
      AInfo.State := lsActive;
      AInfo.ExpiresAt := _JStr(LObj, 'expires_at');
      _CacheSuccess(LKey, LObj);
      Exit(True);
    end;
    // server says not-bound / revoked / expired -> drop the cache, fall to trial
    try TFile.Delete(_StorePath); except end;
    AInfo := LicenseCurrent;
    Result := False;
  finally
    LObj.Free;
  end;
end;

// A "baseline" tier grants only the free capability set, so it needs no
// cryptographic proof and is safe to honor from the editable plaintext cache.
// Every elevated tier (trial/pro/founder/team/enterprise/...) MUST be backed by
// a verified RS256 token — otherwise a hand-edited license.dat (or an AI asked
// to do it) could fake Pro by writing "tier":"pro" into the plaintext store.
function _IsBaselineTier(const ATier: string): Boolean;
begin
  Result := (ATier = '') or SameText(ATier, 'free') or SameText(ATier, 'community');
end;

function LicenseCurrent: TAefosLicenseInfo;
var
  LStore: TJSONObject;
  LKey, LLastOk, LExpires: string;
  LDt: TDateTime;
  LFirstSeen: string;
  {$IFNDEF FPC}
  // The signed-token (Phase 2) path is Delphi-only this round - see the token
  // block below. Its locals do not exist on the FPC side.
  LToken: string;
  LClaims: TLicenseClaims;
  {$ENDIF}
begin
  Result := Default(TAefosLicenseInfo);
  LStore := _LoadStore;
  try
    LKey := _JStr(LStore, 'key');
    LLastOk := _JStr(LStore, 'last_ok_utc');
    LExpires := _JStr(LStore, 'expires_at');
    LFirstSeen := _JStr(LStore, 'trial_first_utc');

    if LKey <> '' then
    begin
      Result.Key := LKey;
      Result.ExpiresAt := LExpires;
      Result.Tier := _JStr(LStore, 'tier');
      Result.FromCache := True;

      // Phase 2: a signed token, when present, is the tamper-evident source of
      // truth. It must verify with the embedded public key, be bound to THIS
      // machine, not be expired, and say active. A forged/edited token fails the
      // RS256 check -> not active.
      //
      // FPC/Lazarus (Phase-1 this round): the RS256 verifier (Windows CNG) is NOT
      // ported yet, so this whole signed-token block is compiled out. The client
      // then relies on the plaintext grace/trial logic below. Consequence: a
      // paid/elevated tier read from the SHARED license.dat cannot be
      // cryptographically proven on FPC, so the anti-tamper cap below pins the
      // *tier* to 'free' - but ACCESS is still granted during the grace window,
      // and GATE_HARD_MODE=False (soft beta) means Pro features still run + upsell.
      // TODO(Phase-2): port Aefos.License.Token to FPC (bcrypt.dll externals +
      // base64-decode/raw-SHA256 compat) to honor the real Pro tier on Lazarus.
      {$IFNDEF FPC}
      LToken := _JStr(LStore, 'token');
      if LToken <> '' then
      begin
        LClaims := VerifyLicenseToken(LToken);
        if LClaims.Valid
           and (LClaims.Fingerprint = LicenseFingerprint)
           and SameText(LClaims.Status, 'active')
           and (LClaims.Exp > DateTimeToUnix(_NowUtc, True)) then
        begin
          Result.Tier := LClaims.Tier; // trusted: from the RS256-signed token
          Result.State := lsActive;
        end
        else
        begin
          // Token present but NOT valid-and-active (forged/edited signature,
          // wrong machine, or expired): do not fall back to trusting the
          // plaintext tier — cap it to 'free' so a tampered cache can't keep Pro.
          if not _IsBaselineTier(Result.Tier) then
            Result.Tier := 'free';
          Result.State := lsExpired; // bad signature / wrong machine / expired
        end;
        Exit;
      end;
      {$ENDIF}

      // No valid signed token below this point. Anti-tamper: a paid/elevated
      // tier cannot be proven without an RS256 token, so it MUST NOT be honored
      // from the editable plaintext cache — cap it to 'free'. The grace logic
      // below still grants ACCESS during the offline window; only the *tier* is
      // capped, so Pro features stay locked until a verified token is present.
      // A legitimate Phase-1/legacy Pro re-earns its real tier on the next
      // online validate, which now always returns a signed token.
      if not _IsBaselineTier(Result.Tier) then
        Result.Tier := 'free';

      // No token (Phase-1 server or legacy cache): fall back to the plaintext
      // grace window since the last successful online check.
      if _Expired(LExpires) then
      begin
        Result.State := lsExpired;
        Exit;
      end;
      if TryISO8601ToDate(LLastOk, LDt, True)
         and (_NowUtc <= IncDay(LDt, GRACE_DAYS)) then
        Result.State := lsActive
      else
        Result.State := lsExpired; // grace elapsed -> must re-validate online
      Exit;
    end;

    // No key -> trial. Stamp the first run if not yet recorded.
    if LFirstSeen = '' then
    begin
      LFirstSeen := _NowUtcIso;
      LStore.RemovePair('trial_first_utc').Free;
      LStore.AddPair('trial_first_utc', LFirstSeen);
      _SaveStore(LStore);
    end;
    if TryISO8601ToDate(LFirstSeen, LDt, True) then
    begin
      Result.TrialDaysLeft :=
        TRIAL_DAYS - DaysBetween(_NowUtc, LDt);
      if Result.TrialDaysLeft > 0 then
        Result.State := lsTrial
      else
        Result.State := lsUnlicensed;
    end
    else
      Result.State := lsUnlicensed;
  finally
    LStore.Free;
  end;
end;

function LicenseIsUsable: Boolean;
begin
  Result := LicenseCurrent.State in [lsActive, lsTrial];
end;

end.
