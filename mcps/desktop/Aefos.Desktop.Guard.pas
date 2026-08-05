unit Aefos.Desktop.Guard;

{
  The DETERMINISTIC security policy engine of the Aefos Desktop MCP
  (feat/desktop-mcp, PHASE 3). Pure / RTL-only — no UIA, no Winapi, no window,
  no side effect — so it is exhaustively unit-testable headless, exactly like the
  DB frontier's Aefos.Db.SqlGuard.

  THIS IS THE SAFETY BOUNDARY, not a convenience. The Desktop MCP can move the
  real mouse/keyboard and close/kill windows on the developer's live desktop, and
  the caller is a language model. So the guard follows RULE #1: correctness lives
  in the guard, never trusted to the agent's reasoning. Every mutating action is
  classified and GUARDED before anything happens; a mismatch is refused WITHOUT
  acting and returns a machine-actionable kebab verdict so the agent self-corrects.

  What this unit ENCODES (the security model of the master plan, distilled to a
  pure decision — inputs: a resolved target + config + the two consent keys;
  output: a verdict):

    * Intent tiers per tool (a tool->tier table):
        READ         list_windows / window_tree / element_find
        CAPTURE      screen_capture / ocr_read      (pixels — see below)
        WRITE        click / type_text / focus / move
        DESTRUCTIVE  close / kill / confirm-dialog

    * CAPTURE is its OWN tier, NOT free read (finding C3). Structured reads can be
      REDACTED — a title is replaced by '[redacted]' and the agent still gets the
      hwnd/control type it needs to navigate. PIXELS CANNOT: a bitmap of a window
      is all of its contents at once, and there is no partial form of it to hand
      back. So capture is not "allowed but redacted" — out of scope it is REFUSED
      outright (desktop-out-of-scope), and a deny-listed app is REFUSED
      (desktop-denied-app). It still needs NO host consent and NO confirmation:
      capture mutates nothing. Scope is the whole gate, and it is a hard one.
      (The other half of C3 — never steal the foreground to capture — is the
      caller's duty: PrintWindow, never SetForegroundWindow+BitBlt. The guard
      cannot enforce that; the capture unit's contract does.)

    * Target identity is the EXE PATH, never the title (finding H4 — a title is
      spoofable: any process can SetWindowText). The caller resolves the target
      to (hwnd, pid, exe_path) from a live enumeration and the guard matches the
      exe_path against the allow/deny lists. DENY ALWAYS WINS (password managers,
      banking) => desktop-denied-app. Out of the allow-list => desktop-out-of-scope.

    * READ privacy (finding M7 — proven live: even ENUMERATING a window leaks its
      private title to the cloud model). The guard classifies reads too: a window
      whose exe_path matches the deny-list, OR any non-in-scope window when the
      operator has not granted whole-desktop read consent, has its title/contents
      REDACTED (the caller returns handle/type only). Read has zero mutation risk
      but real privacy risk, so it is NOT unconditionally free.

    * WRITE needs BOTH keys: (a) host consent — a boolean the guard only CONSUMES;
      its ORIGIN is the trusted signed binary-harness (a future phase), never a
      file the agent can write — AND (b) the target is in scope. Missing host
      consent => desktop-input-disabled. DESTRUCTIVE needs a THIRD deliberate
      signal, AConfirmed (human confirmation) => desktop-requires-confirmation
      when absent.

    * M6 — a shell/terminal/browser-address-bar must NEVER be a target of
      type_text (typing there = arbitrary command execution). The guard refuses
      typed input into a HARD BUILT-IN class of executables (cmd/powershell/pwsh/
      wt/conhost/terminal/browsers) plus any config extras, REGARDLESS of the
      allow-list => desktop-forbidden-target-class. Built-in so it can never be
      config'd away by omission.

  Asymmetry, deliberate: a false NEGATIVE (refusing a legitimate action) is a
  nuisance the agent recovers from; a false POSITIVE (acting on the wrong window
  or a denied app) can overwrite a file or leak a password. When in doubt, refuse.
}

interface

uses
  System.SysUtils,
  System.Classes;

type
  // The intent tiers of the desktop surface, plus the catch-all for a tool name
  // the table does not know (which is itself refused — a new mutating tool must
  // be classified before it can act). dtCapture sits between read and write: it
  // mutates nothing, but it exfiltrates a window's ENTIRE visible contents as
  // pixels, so it is scope-gated instead of redacted (C3).
  TDesktopTier = (dtRead, dtCapture, dtWrite, dtDestructive, dtUnknown);

  // A target already RESOLVED by the caller from a LIVE enumeration. Identity is
  // the EXE PATH (H4). HWnd/Pid travel along for the caller's TOCTOU re-check
  // (re-verify the same pid still owns the hwnd immediately before acting); the
  // PURE guard reasons only about ExePath.
  TDesktopTarget = record
    HWnd: NativeInt;
    Pid: Cardinal;
    ExePath: string;
    // Factory instead of the repeated Default(TDesktopTarget) + field-by-field
    // fill: one named owner for building a resolved target. Pure, no side effect.
    class function Create(AHWnd: NativeInt; APid: Cardinal;
      const AExePath: string): TDesktopTarget; static;
  end;

  // The policy configuration. In production this is sourced from the trusted
  // binary-harness interaction, NOT a file the agent can forge.
  TDesktopPolicyConfig = record
    // Exe-path globs (case-insensitive, '*' and '?') that MAY be written to.
    AllowList: TArray<string>;
    // Exe-path globs that must NEVER be touched. Deny always wins over allow, and
    // also forces title redaction on the read tier.
    DenyList: TArray<string>;
    // EXTRA exe-path globs that must never receive typed input, ON TOP of the
    // hard built-in class (CDefaultForbiddenTypeExes).
    ForbiddenTypeTargets: TArray<string>;
    // Whole-desktop read consent. When False (the default), the read tier returns
    // raw titles ONLY for in-scope (allow-listed) windows and redacts every other.
    AllowUnscopedRead: Boolean;
  end;

  TDesktopVerdict = record
    Allowed: Boolean;
    Reason: string;      // kebab code, agent-actionable; '' when Allowed
    Tier: TDesktopTier;
    // Read tier only: the caller MUST omit/redact this window's title + contents
    // before returning them to the model (privacy gate, finding M7).
    RedactTitle: Boolean;
    // Factories that name the two verdict shapes the guard emits, so the policy
    // engine reads as 'Exit(Deny(...))' / 'Exit(Allow(...))' instead of a repeated
    // Default + three-field fill. RedactTitle defaults False (a Deny/plain Allow);
    // ClassifyRead sets it explicitly because a read is allowed-but-maybe-redacted.
    class function Allow(ATier: TDesktopTier): TDesktopVerdict; static;
    class function Deny(ATier: TDesktopTier;
      const AReason: string): TDesktopVerdict; static;
  end;

const
  // Kebab verdicts (RULE #1 style — the agent reads the reason and self-corrects).
  DESKTOP_REASON_UNKNOWN_TOOL     = 'desktop-unknown-tool';
  DESKTOP_REASON_OUT_OF_SCOPE     = 'desktop-out-of-scope';
  DESKTOP_REASON_DENIED_APP       = 'desktop-denied-app';
  DESKTOP_REASON_INPUT_DISABLED   = 'desktop-input-disabled';
  DESKTOP_REASON_REQUIRES_CONFIRM = 'desktop-requires-confirmation';
  DESKTOP_REASON_FORBIDDEN_CLASS  = 'desktop-forbidden-target-class';

  // Hard, built-in class of executables that must NEVER receive synthesised typed
  // input (finding M6): typing into a shell/terminal/address bar = arbitrary
  // command execution. Enforced even when the config forbidden list is empty, so
  // the protection cannot be config'd away by omission. Patterns require a path
  // separator before the exe name so 'notcmd.exe' does not match '*\cmd.exe'.
  CDefaultForbiddenTypeExes: array[0..13] of string = (
    '*\cmd.exe', '*\powershell.exe', '*\pwsh.exe', '*\wt.exe',
    '*\conhost.exe', '*\windowsterminal.exe', '*\openconsole.exe', '*\bash.exe',
    '*\chrome.exe', '*\msedge.exe', '*\firefox.exe', '*\brave.exe',
    '*\opera.exe', '*aefos*terminal*');

type
  // Static, sealed namespace for the deterministic desktop security policy. Never
  // instantiated (no constructor): every routine is a class function so it has a
  // named owner (e.g. TDesktopGuard.Decide) instead of floating free in the unit
  // interface. The class IS the namespace, so the old 'Desktop' name prefix is gone.
  TDesktopGuard = class sealed
  public
    // The tool->tier classification. Names are normalised (lower-cased, a leading
    // 'desktop_' prefix stripped), so both 'desktop_type_text' and 'type_text' land
    // on the same tier. An unknown name => dtUnknown (refused by TDesktopGuard.Decide).
    class function ToolTier(const AToolName: string): TDesktopTier; static;

    // True when the tool WRITES TEXT (type_text / set_value) — the tools the M6
    // shell/terminal/browser ban applies to.
    class function ToolTypesText(const AToolName: string): Boolean; static;

    // The normalised form used for classification (exposed for the tests).
    class function NormalizeToolName(const AToolName: string): string; static;

    // Case-insensitive glob match ('*' any run, '?' one char) over the whole string.
    class function GlobMatch(const APattern, AText: string): Boolean; static;

    // True when AExePath matches ANY of APatterns (empty list => False).
    class function MatchesAny(const AExePath: string;
      const APatterns: array of string): Boolean; static;

    // Splits a ';'-separated list (the ini/harness format, e.g. '*keepass*;*bank*')
    // into trimmed, non-empty patterns.
    class function ParseList(const AText: string): TArray<string>; static;

    // Classifies a READ action against a target: always Allowed (reads never mutate),
    // but sets RedactTitle per the privacy rule (M7).
    class function ClassifyRead(const ATarget: TDesktopTarget;
      const AConfig: TDesktopPolicyConfig): TDesktopVerdict; static;

    // Classifies a CAPTURE action (screen_capture / ocr_read) against a target.
    // Unlike a read, this can NOT be softened by redaction — a bitmap is the whole
    // window — so it is REFUSED unless the target is in scope (C3):
    //   unresolved exe path       => desktop-out-of-scope  (identity unverifiable)
    //   deny-listed app           => desktop-denied-app    (deny always wins)
    //   not allow-listed, and no whole-desktop read consent => desktop-out-of-scope
    // Needs no host consent and no confirmation: capture mutates nothing.
    class function ClassifyCapture(const ATarget: TDesktopTarget;
      const AConfig: TDesktopPolicyConfig): TDesktopVerdict; static;

    // THE decision. Classifies AToolName, then for a write/destructive action applies
    // deny-list -> forbidden-type-class -> allow-list -> host consent -> confirmation,
    // in that precedence. For a read it delegates to ClassifyRead. Pure.
    //   AHostConsent  KEY 1 — the human/harness enabled input (guard only CONSUMES it)
    //   AConfirmed    KEY 4 — a human confirmed this specific destructive action
    class function Decide(const AToolName: string;
      const ATarget: TDesktopTarget;
      const AConfig: TDesktopPolicyConfig;
      const AHostConsent: Boolean;
      const AConfirmed: Boolean): TDesktopVerdict; static;
  end;

implementation

const
  // The tool->tier table. Kept as exhaustive name lists (incl. common aliases)
  // so a future phase's tool name resolves without a code change here.
  CReadTools: array[0..6] of string = (
    'ping', 'list_windows', 'window_list', 'window_tree', 'tree',
    'element_find', 'find_element');

  // Pixel-level reads. Deliberately NOT in CReadTools (C3): they cannot be
  // redacted, so they are scope-gated instead. 'window_capture' is the accurate
  // name — capture is always ONE window, never the whole screen — with
  // 'screen_capture' kept as the alias the plan/agents may say.
  CCaptureTools: array[0..5] of string = (
    'window_capture', 'screen_capture', 'capture', 'ocr', 'ocr_read',
    'window_ocr');

  CWriteTools: array[0..9] of string = (
    'click', 'element_invoke', 'invoke', 'type_text', 'type',
    'window_focus', 'focus', 'window_move', 'move', 'set_value');

  CDestructiveTools: array[0..5] of string = (
    'window_close', 'close', 'process_kill', 'kill', 'confirm', 'confirm_dialog');

  // The text-writing subset of the write tier (the M6 ban targets these).
  CTypeTools: array[0..2] of string = ('type_text', 'type', 'set_value');

{ TDesktopTarget }

class function TDesktopTarget.Create(AHWnd: NativeInt; APid: Cardinal;
  const AExePath: string): TDesktopTarget;
begin
  Result := Default(TDesktopTarget);
  Result.HWnd := AHWnd;
  Result.Pid := APid;
  Result.ExePath := AExePath;
end;

{ TDesktopVerdict }

class function TDesktopVerdict.Allow(ATier: TDesktopTier): TDesktopVerdict;
begin
  Result := Default(TDesktopVerdict);
  Result.Allowed := True;
  Result.Tier := ATier;
end;

class function TDesktopVerdict.Deny(ATier: TDesktopTier;
  const AReason: string): TDesktopVerdict;
begin
  Result := Default(TDesktopVerdict);
  Result.Allowed := False;
  Result.Reason := AReason;
  Result.Tier := ATier;
end;

{ TDesktopGuard }

class function TDesktopGuard.NormalizeToolName(const AToolName: string): string;
begin
  Result := LowerCase(Trim(AToolName));
  if Copy(Result, 1, 8) = 'desktop_' then
    Result := Copy(Result, 9, Length(Result) - 8);
end;

function _InSet(const AName: string; const ASet: array of string): Boolean;
var
  LIndex: Integer;
begin
  Result := False;
  for LIndex := Low(ASet) to High(ASet) do
    if ASet[LIndex] = AName then
      Exit(True);
end;

class function TDesktopGuard.ToolTier(const AToolName: string): TDesktopTier;
var
  LName: string;
begin
  LName := NormalizeToolName(AToolName);
  if _InSet(LName, CReadTools) then
    Result := dtRead
  else if _InSet(LName, CCaptureTools) then
    Result := dtCapture
  else if _InSet(LName, CDestructiveTools) then
    Result := dtDestructive
  else if _InSet(LName, CWriteTools) then
    Result := dtWrite
  else
    Result := dtUnknown;
end;

class function TDesktopGuard.ToolTypesText(const AToolName: string): Boolean;
begin
  Result := _InSet(NormalizeToolName(AToolName), CTypeTools);
end;

class function TDesktopGuard.GlobMatch(const APattern, AText: string): Boolean;
var
  LPat, LTxt: string;
  LPatIdx, LTxtIdx, LStarPatIdx, LStarTxtIdx: Integer;
begin
  LPat := LowerCase(APattern);
  LTxt := LowerCase(AText);
  LPatIdx := 1;
  LTxtIdx := 1;
  LStarPatIdx := 0;
  LStarTxtIdx := 0;
  while LTxtIdx <= Length(LTxt) do
  begin
    if (LPatIdx <= Length(LPat)) and
       ((LPat[LPatIdx] = '?') or (LPat[LPatIdx] = LTxt[LTxtIdx])) then
    begin
      Inc(LPatIdx);
      Inc(LTxtIdx);
    end
    else if (LPatIdx <= Length(LPat)) and (LPat[LPatIdx] = '*') then
    begin
      LStarPatIdx := LPatIdx;
      LStarTxtIdx := LTxtIdx;
      Inc(LPatIdx);
    end
    else if LStarPatIdx <> 0 then
    begin
      LPatIdx := LStarPatIdx + 1;
      Inc(LStarTxtIdx);
      LTxtIdx := LStarTxtIdx;
    end
    else
      Exit(False);
  end;
  while (LPatIdx <= Length(LPat)) and (LPat[LPatIdx] = '*') do
    Inc(LPatIdx);
  Result := LPatIdx > Length(LPat);
end;

class function TDesktopGuard.MatchesAny(const AExePath: string;
  const APatterns: array of string): Boolean;
var
  LIndex: Integer;
begin
  Result := False;
  if Trim(AExePath) = '' then
    Exit;
  for LIndex := Low(APatterns) to High(APatterns) do
    if GlobMatch(APatterns[LIndex], AExePath) then
      Exit(True);
end;

class function TDesktopGuard.ParseList(const AText: string): TArray<string>;
var
  LParts: TArray<string>;
  LPart, LTrimmed: string;
begin
  Result := nil;
  if Trim(AText) = '' then
    Exit;
  LParts := AText.Split([';']);
  for LPart in LParts do
  begin
    LTrimmed := Trim(LPart);
    if LTrimmed <> '' then
      Result := Result + [LTrimmed];
  end;
end;

class function TDesktopGuard.ClassifyRead(const ATarget: TDesktopTarget;
  const AConfig: TDesktopPolicyConfig): TDesktopVerdict;
var
  LDeny, LAllow: Boolean;
begin
  Result := Default(TDesktopVerdict);
  Result.Tier := dtRead;
  Result.Allowed := True;   // a read never mutates; the gate here is privacy
  Result.Reason := '';
  LDeny := MatchesAny(ATarget.ExePath, AConfig.DenyList);
  LAllow := MatchesAny(ATarget.ExePath, AConfig.AllowList);
  // Redact when the window is deny-listed, OR it is not an in-scope target and
  // the operator has not granted whole-desktop read consent (M7).
  Result.RedactTitle := LDeny or ((not LAllow) and (not AConfig.AllowUnscopedRead));
end;

class function TDesktopGuard.ClassifyCapture(const ATarget: TDesktopTarget;
  const AConfig: TDesktopPolicyConfig): TDesktopVerdict;
begin
  // RedactTitle stays False for every branch — meaningless for pixels: a capture
  // out of scope is refused, never softened. Deny/Allow carry that default.

  // Identity must be resolved (H4) — capturing a window we cannot attribute to a
  // process means we cannot honour the deny-list at all. Refuse.
  if Trim(ATarget.ExePath) = '' then
    Exit(TDesktopVerdict.Deny(dtCapture, DESKTOP_REASON_OUT_OF_SCOPE));

  // Deny always wins — a password manager's pixels ARE the password.
  if MatchesAny(ATarget.ExePath, AConfig.DenyList) then
    Exit(TDesktopVerdict.Deny(dtCapture, DESKTOP_REASON_DENIED_APP));

  // In scope, or the operator granted whole-desktop read consent. Otherwise the
  // agent may not photograph a window it was never pointed at.
  if (not MatchesAny(ATarget.ExePath, AConfig.AllowList)) and
     (not AConfig.AllowUnscopedRead) then
    Exit(TDesktopVerdict.Deny(dtCapture, DESKTOP_REASON_OUT_OF_SCOPE));

  Result := TDesktopVerdict.Allow(dtCapture);
end;

class function TDesktopGuard.Decide(const AToolName: string;
  const ATarget: TDesktopTarget;
  const AConfig: TDesktopPolicyConfig;
  const AHostConsent: Boolean;
  const AConfirmed: Boolean): TDesktopVerdict;
var
  LTier: TDesktopTier;
begin
  LTier := ToolTier(AToolName);

  // A tool the table does not classify is refused — a new mutating tool must be
  // tiered before it can act (the guard is never bypassed by an unknown name).
  if LTier = dtUnknown then
    Exit(TDesktopVerdict.Deny(LTier, DESKTOP_REASON_UNKNOWN_TOOL));

  if LTier = dtRead then
    Exit(ClassifyRead(ATarget, AConfig));

  // Pixels: scope-gated, never redacted, never consent/confirmation-gated (C3).
  if LTier = dtCapture then
    Exit(ClassifyCapture(ATarget, AConfig));

  // --- write / destructive from here ---------------------------------------

  // Identity must be resolved (H4): with no exe path we cannot verify the target,
  // and the Notepad lesson banned acting on an unverified window. Refuse.
  if Trim(ATarget.ExePath) = '' then
    Exit(TDesktopVerdict.Deny(LTier, DESKTOP_REASON_OUT_OF_SCOPE));

  // Deny-list wins over EVERYTHING (password managers, banking).
  if MatchesAny(ATarget.ExePath, AConfig.DenyList) then
    Exit(TDesktopVerdict.Deny(LTier, DESKTOP_REASON_DENIED_APP));

  // M6 — typing into a shell/terminal/browser is arbitrary command execution.
  // Refused regardless of the allow-list, on the hard built-in class + config
  // extras. (Only the text-writing tools; a plain click/focus is not covered.)
  if ToolTypesText(AToolName) and
     (MatchesAny(ATarget.ExePath, CDefaultForbiddenTypeExes) or
      MatchesAny(ATarget.ExePath, AConfig.ForbiddenTypeTargets)) then
    Exit(TDesktopVerdict.Deny(LTier, DESKTOP_REASON_FORBIDDEN_CLASS));

  // KEY 3 — in scope? The agent controls the app the human named, never the
  // whole desktop.
  if not MatchesAny(ATarget.ExePath, AConfig.AllowList) then
    Exit(TDesktopVerdict.Deny(LTier, DESKTOP_REASON_OUT_OF_SCOPE));

  // KEY 1 — host consent. Sourced from the trusted binary-harness (a future
  // phase); the guard only CONSUMES the boolean, it can never self-grant it.
  if not AHostConsent then
    Exit(TDesktopVerdict.Deny(LTier, DESKTOP_REASON_INPUT_DISABLED));

  // KEY 4 — a destructive (close/kill/confirm) action needs the extra human
  // confirmation signal; irreversible => synchronous consent, not a mere flag.
  if (LTier = dtDestructive) and (not AConfirmed) then
    Exit(TDesktopVerdict.Deny(LTier, DESKTOP_REASON_REQUIRES_CONFIRM));

  Result := TDesktopVerdict.Allow(LTier);
end;

end.
