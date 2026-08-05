unit Aefos.License.Gate;
{$IFDEF FPC}{$mode delphiunicode}{$H+}{$ENDIF}

{
  Public surface of the dedicated Aefos.License BPL (a passive runtime package
  both the Chat and Terminal design-time BPLs `require`). It exposes the ONE
  license gate the hosts call, plus the entry point to the activation screen.

  This package registers NOTHING in the IDE (no notifiers, no keyboard bindings)
  -> it is outside the unload-AV surface (UnloadContract). The hosts decide WHEN
  to show the screen (e.g. an "Aefos AI -> License..." menu item / Options button,
  or EnsureLicensed at Register when the trial has elapsed).
}

interface

const
  // Capabilities the gate checks per tier (Aefos Chat split, decided 2026-06-16).
  // PHILOSOPHY: gate the CONVENIENCE / auto-create, never the manual core. A free
  // user can still do everything BY HAND / externally (hand-write the .mcp.json,
  // type commands manually); Pro buys the in-IDE auto-create dialogs + execution
  // power. Enforced via LicenseEnforce — SOFT during beta (works + upsell), flip
  // GATE_HARD_MODE to True at GA.
  //
  // Community (free): the chat itself, INCLUDING the default agent mode, own API.
  AEFOS_CAP_CHAT     = 'chat';             // chat panel + conversation
  AEFOS_CAP_AGENT    = 'agent';            // agent is the default chat mode
  // Pro (execution power + the auto-create convenience; manual/external stays free):
  AEFOS_CAP_TERMINAL = 'terminal';         // the Aefos Terminal
  AEFOS_CAP_MCP      = 'mcp';              // MCP auto-setup/provision dialog
  AEFOS_CAP_COMMAND  = 'command-wizard';   // auto-create command dialog
  AEFOS_CAP_CONTEXT  = 'advanced-context'; // advanced project context
  AEFOS_CAP_HISTORY  = 'history';          // session history + templates
  AEFOS_CAP_AIFLOW   = 'ai-flow';          // silent reload (smooth AI workflow)

type
  // The one license gate as a sealed static namespace: the ONE gate the hosts
  // call, plus the entry to the activation screen. Never instantiated — the class
  // is the namespace; the redundant `License` prefix dies with the move (the class
  // already says "License"). Registers NOTHING in the IDE (UnloadContract).
  TLicenseGate = class sealed
  public
    // The gate: True when licensed features may run (active key, cached within
    // grace, or inside the trial). Offline-safe — never blocks on the network.
    class function IsUsable: Boolean; static;

    // A short, user-facing status line for a menu caption / Options label.
    class function StatusText: string; static;

    // A short label for a window title/tab: Trial / Free / Pro / Active / Expired...
    class function ShortLabel: string; static;

    // The IDE splash / About-list status. Like ShortLabel but the active
    // states read 'Licensed (Pro)' / 'Licensed (Free)' so the splash shows BOTH the
    // licensed-state and the tier in one line.
    class function SplashLabel: string; static;

    // The persistent Trial reminder shown as a clickable badge in the chat header
    // (e.g. 'Trial - 12 days left - Upgrade'). Returns '' when NOT on trial, so the
    // caller hides the badge. The urgency reminder that replaces per-action nags.
    class function TrialBadge: string; static;

    // Current tier: 'trial' while in trial, else the license tier, else 'community'.
    class function Tier: string; static;

    // Per-tier capability check: True when the current tier may use ACapability.
    class function Allows(const ACapability: string): Boolean; static;

    // True when a Pro SURFACE must not be shown at all for the current tier.
    //
    // Not the same question as Allows, and mixing them up is a real defect we
    // shipped: bare `not Allows(...)` hides the surface in every build, which
    // contradicts GATE_HARD_MODE. During the soft beta every other Pro surface
    // stays visible and merely upsells (Terminal MCP, AI Flow silent reload,
    // chat commands), so a menu item that silently vanishes for a Free tier is
    // both inconsistent and unexplainable to the user -- there is nothing on
    // screen to ask about. This names the rule once so the next call site cannot
    // get it wrong: hide ONLY when the build actually gates hard.
    class function HiddenByTier(const ACapability: string): Boolean; static;

    // PRIMARY paywall lever (provider gating): True when the current tier may use the
    // given AI provider/CLI. AProviderId is the executor token ('claude' | 'codex' |
    // 'copilot' | 'gemini'). Free is limited to the free provider(s); trial/paid get
    // all. The free taste is one const (FREE_PROVIDERS) — change it there.
    class function AllowsProvider(const AProviderId: string): Boolean; static;

    // True when the build BLOCKS Pro capabilities for Community (GA). Beta ships SOFT
    // (False): everything works, call sites only upsell. Flip GATE_HARD_MODE at GA.
    class function GateHard: Boolean; static;

    // The call-site gate. Returns True when the caller may PROCEED:
    //   - capability allowed for the tier  -> True,  AUpsell=''
    //   - not allowed, SOFT mode (beta)    -> True,  AUpsell=<nag the FIRST time only>
    //   - not allowed, HARD mode (GA)      -> False, AUpsell=<nag>
    // AUpsell is emitted ONCE per capability per session (so a loop won't spam); the
    // caller shows it in its OWN UI (chat toast / terminal line / dialog). The Gate
    // stays UI-agnostic and registers nothing in the IDE (UnloadContract).
    class function Enforce(const ACapability: string; out AUpsell: string): Boolean; static;

    // The upsell line for a capability (e.g. "The Aefos Terminal is a Pro feature").
    class function UpsellText(const ACapability: string): string; static;

    // Gate helper: returns IsUsable; when False, opens the activation screen
    // once and re-checks. Use this where the host wants to nudge activation.
    class function EnsureLicensed: Boolean; static;

    // Opens the activation/management screen (enter key, Activate, Deactivate,
    // status). Modal; safe to call from a menu/Options action on the main thread.
    class procedure ShowManager; static;
  end;

implementation

uses
  {$IFNDEF FPC}
  System.SysUtils,
  System.Classes,
  Aefos.License.Client,
  Aefos.License.UI;          // VCL activation screen (RAD Studio edition)
  {$ELSE}
  SysUtils,
  Classes,
  Aefos.License.Client,
  Aefos.Lazarus.License.UI;  // LCL activation screen (Lazarus edition twin)
  {$ENDIF}

const
  // Beta ships SOFT: Pro capabilities still run, call sites only upsell. Flip to
  // True at GA to actually block Community from Pro features. ONE-line switch.
  GATE_HARD_MODE = False;

  // The AI providers (executor tokens) available on the FREE Community tier; the
  // rest are Pro. Comma-delimited, lowercase, no spaces. THE free-tier "taste" —
  // change this one line to widen it. ollama = the local-models executor
  // (zero serving cost; maintainer decision 2026-07-08).
  FREE_PROVIDERS = 'gemini,copilot,ollama';

class function TLicenseGate.IsUsable: Boolean;
begin
  Result := Aefos.License.Client.LicenseIsUsable;
end;

class function TLicenseGate.StatusText: string;
var
  LInfo: TAefosLicenseInfo;
begin
  LInfo := LicenseCurrent;
  case LInfo.State of
    lsActive:
      if LInfo.ExpiresAt = '' then
        Result := 'License: active'
      else
        Result := 'License: active (until ' + Copy(LInfo.ExpiresAt, 1, 10) + ')';
    lsTrial:      Result := 'License: trial (' +
                              IntToStr(LInfo.TrialDaysLeft) + ' days left)';
    lsExpired:    Result := 'License: expired';
    lsSeatLimit:  Result := 'License: seat limit reached';
    lsInvalid:    Result := 'License: invalid key';
    lsUnlicensed: Result := 'License: not activated';
  else
    Result := 'License: unknown';
  end;
end;

class function TLicenseGate.ShortLabel: string;
var
  LInfo: TAefosLicenseInfo;
begin
  LInfo := LicenseCurrent;
  case LInfo.State of
    lsTrial:      Result := 'Trial';
    lsActive:
      if SameText(LInfo.Tier, 'pro') then Result := 'Pro'
      else if SameText(LInfo.Tier, 'free') then Result := 'Free'
      else if LInfo.Tier <> '' then
        Result := UpperCase(Copy(LInfo.Tier, 1, 1)) + Copy(LInfo.Tier, 2, MaxInt)
      else Result := 'Active';
    lsExpired:    Result := 'Expired';
    lsSeatLimit:  Result := 'Seat limit';
    lsInvalid:    Result := 'Invalid';
    lsUnlicensed: Result := 'Unlicensed';
  else
    Result := '';
  end;
end;

class function TLicenseGate.SplashLabel: string;
var
  LInfo: TAefosLicenseInfo;
  LTier: string;
begin
  LInfo := LicenseCurrent;
  case LInfo.State of
    lsTrial:      Result := 'Trial';
    lsActive:
      begin
        if SameText(LInfo.Tier, 'pro') then LTier := 'Pro'
        else if SameText(LInfo.Tier, 'free') then LTier := 'Free'
        else if LInfo.Tier <> '' then
          LTier := UpperCase(Copy(LInfo.Tier, 1, 1)) + Copy(LInfo.Tier, 2, MaxInt)
        else LTier := '';
        if LTier <> '' then
          Result := 'Licensed (' + LTier + ')'
        else
          Result := 'Licensed';
      end;
    lsExpired:    Result := 'Expired';
    lsSeatLimit:  Result := 'Seat limit';
    lsInvalid:    Result := 'Invalid';
    lsUnlicensed: Result := 'Unlicensed';
  else
    Result := '';
  end;
end;

class function TLicenseGate.TrialBadge: string;
var
  LInfo: TAefosLicenseInfo;
begin
  Result := '';
  LInfo := LicenseCurrent;
  if LInfo.State <> lsTrial then
    Exit;
  if LInfo.TrialDaysLeft = 1 then
    Result := 'Trial - 1 day left - Upgrade'
  else
    Result := Format('Trial - %d days left - Upgrade', [LInfo.TrialDaysLeft]);
end;

class function TLicenseGate.Tier: string;
var
  LInfo: TAefosLicenseInfo;
begin
  LInfo := LicenseCurrent;
  if LInfo.State = lsTrial then
    Result := 'trial'
  else if LInfo.Tier <> '' then
    Result := LowerCase(LInfo.Tier)
  else
    Result := 'community';
end;

class function TLicenseGate.Allows(const ACapability: string): Boolean;
var
  LTier: string;
begin
  // Community (free) capabilities — always allowed, any tier/state:
  //   chat + the default agent mode (the conversation is free; see PHILOSOPHY).
  if SameText(ACapability, AEFOS_CAP_CHAT)
     or SameText(ACapability, AEFOS_CAP_AGENT) then
    Exit(True);
  // Everything else (Terminal, MCP/command auto-create, advanced context,
  // history) needs a paid/trial tier.
  LTier := Tier;
  Result := SameText(LTier, 'trial') or SameText(LTier, 'pro')
    or SameText(LTier, 'founder') or SameText(LTier, 'team')
    or SameText(LTier, 'enterprise');
end;

class function TLicenseGate.HiddenByTier(const ACapability: string): Boolean;
begin
  Result := GateHard and (not Allows(ACapability));
end;

class function TLicenseGate.AllowsProvider(const AProviderId: string): Boolean;
var
  LTier: string;
begin
  // Trial/paid tiers may use any provider.
  LTier := Tier;
  if SameText(LTier, 'trial') or SameText(LTier, 'pro')
     or SameText(LTier, 'founder') or SameText(LTier, 'team')
     or SameText(LTier, 'enterprise') then
    Exit(True);
  // Free/community/expired/unlicensed: only the free provider(s). Wrap both sides
  // in commas so a token match is exact (no 'gem' matching 'gemini').
  {$IFNDEF FPC}
  Result := (',' + LowerCase(FREE_PROVIDERS) + ',').Contains(
            ',' + LowerCase(Trim(AProviderId)) + ',');
  {$ELSE}
  // FPC delphiunicode has no TStringHelper.Contains - Pos(needle, haystack) > 0
  // is the identical membership test.
  Result := Pos(',' + LowerCase(Trim(AProviderId)) + ',',
                ',' + LowerCase(FREE_PROVIDERS) + ',') > 0;
  {$ENDIF}
end;

class function TLicenseGate.GateHard: Boolean;
begin
  Result := GATE_HARD_MODE;
end;

class function TLicenseGate.UpsellText(const ACapability: string): string;
begin
  // Friendly, specific upsell per Pro capability. Manual/external paths stay free,
  // so the copy nudges to Pro for the CONVENIENCE, not to unlock a wall.
  if SameText(ACapability, AEFOS_CAP_TERMINAL) then
    Result := 'The Aefos Terminal is a Pro feature.'
  else if SameText(ACapability, AEFOS_CAP_MCP) then
    Result := 'Auto-setting up MCP is a Pro feature ' + #$2014 + ' on Community ' +
              'you can still configure the .mcp.json by hand.'
  else if SameText(ACapability, AEFOS_CAP_COMMAND) then
    Result := 'The command auto-create dialog is a Pro feature ' + #$2014 +
              ' on Community you can still add commands manually.'
  else if SameText(ACapability, AEFOS_CAP_CONTEXT) then
    Result := 'Advanced project context is a Pro feature.'
  else if SameText(ACapability, AEFOS_CAP_HISTORY) then
    Result := 'Session history and templates are a Pro feature.'
  else
    Result := 'This is a Pro feature.';
  Result := Result + ' Upgrade in Aefos AI ' + #$2192 + ' License' + #$2026;
end;

var
  // Capabilities already upsold this session, so LicenseEnforce nags ONCE per cap
  // (a loop calling a gated tool won't spam). Lazily created; main-thread use
  // (UI call sites) so no lock. Freed in finalization (passive BPL, safe).
  GUpsoldCaps: TStringList = nil;

class function TLicenseGate.Enforce(const ACapability: string; out AUpsell: string): Boolean;
begin
  AUpsell := '';
  if Allows(ACapability) then
    Exit(True);
  // Not allowed for this tier. Emit the upsell only the first time per cap.
  if GUpsoldCaps = nil then
  begin
    GUpsoldCaps := TStringList.Create;
    GUpsoldCaps.CaseSensitive := False;
    GUpsoldCaps.Sorted := True;
    GUpsoldCaps.Duplicates := dupIgnore;
  end;
  if GUpsoldCaps.IndexOf(ACapability) < 0 then
  begin
    GUpsoldCaps.Add(ACapability);
    AUpsell := UpsellText(ACapability);
  end;
  // SOFT (beta): proceed anyway. HARD (GA): block.
  Result := not GATE_HARD_MODE;
end;

class procedure TLicenseGate.ShowManager;
begin
  {$IFNDEF FPC}
  ShowAefosLicenseDialog;       // VCL screen
  {$ELSE}
  ShowAefosLazLicenseDialog;    // LCL screen (same fields/flow)
  {$ENDIF}
end;

class function TLicenseGate.EnsureLicensed: Boolean;
begin
  Result := IsUsable;
  if not Result then
  begin
    {$IFNDEF FPC}
    ShowAefosLicenseDialog;
    {$ELSE}
    ShowAefosLazLicenseDialog;
    {$ENDIF}
    Result := IsUsable;
  end;
end;

initialization

finalization
  FreeAndNil(GUpsoldCaps);

end.
