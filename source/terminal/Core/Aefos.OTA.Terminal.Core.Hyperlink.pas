unit Aefos.OTA.Terminal.Core.Hyperlink;
{$IFDEF FPC}{$mode delphi}{$H+}{$ENDIF}

(*
  Pure hyperlink helpers for ESP-033 / E3.D2.

  Responsibilities split across three layers (see ADR-033-03):

    1. ParseOsc8Fragment — decodes the OSC 8 payload libvterm delivers via
       the unrecognised_fallbacks hook into (params, URL).
    2. IsAllowedScheme / IsUrlAllowed — pure policy gate. The default
       allow-list is the hardcoded constant DefaultAllowedSchemes; v1 ships
       without settings exposure (BR2).
    3. THyperlink.Open — the ONE Win32 call site for ShellExecuteW. Applies
       the policy gate, silently rejects everything else.

  Unit purity rule: no VCL, no libvterm. Only Winapi.ShellAPI for the
  dispatcher — see ESP-033 OP1 for the alternative that moves the dispatcher
  out to Aefos.OTA.Terminal.Core.HyperlinkDispatch if a future cycle needs the policy unit
  to stay strictly OS-free.

  Conventions: locals `L*`, params `A*` with `const`, private routines `_*`.
*)

interface

uses
  {$IFNDEF FPC}System.SysUtils{$ELSE}SysUtils{$ENDIF};

type
  /// <summary>Half-open cell range [StartCol, EndCol) within a row that maps
  /// to an URL slot in the buffer's URL pool. Moved here from
  /// Aefos.OTA.Terminal.Core.VTermBuffer (ESP-034 / OP1) so the pure Aefos.OTA.Terminal.Core.Reflow unit
  /// can depend on it without pulling in libvterm. ESP-033 / ADR-033-02.</summary>
  TLinkRange = record
    StartCol: Integer;
    EndCol:   Integer;
    UrlIdx:   Integer;
  end;

  { A row's worth of link ranges. FPC's delphi-mode parser rejects instantiating a
    nested generic with a constructor - TList<TArray<TLinkRange>>.Create trips on
    the ">>.Create". This named alias lets those sites read TList<TLinkRangeArray>.
    Delphi accepts the alias identically. }
  TLinkRangeArray = TArray<TLinkRange>;

const
  /// <summary>Maximum hyperlink length accepted by the dispatcher. Matches
  /// the practical browser cap (Chrome ~2083, IE ~2048) per ADR-033-03.</summary>
  DEFAULT_MAX_URL_LEN = 2048;

type
  /// <summary>Pure hyperlink helpers grouped as a stateless facade. Every
  /// member is a class-static function — no instance is ever created.</summary>
  THyperlink = class sealed
  public
    /// <summary>Decodes an OSC 8 fragment. Tolerates two shapes:
    /// (a) `8;params;URI` — the literal OSC body including the command prefix
    /// (b) `params;URI` — the fragment libvterm delivers (command already stripped)
    /// Returns False only when AFragment is empty. AParams and AUrl are out
    /// strings; an empty AUrl signals a close OSC 8 per the iTerm2 convention.</summary>
    class function ParseOsc8Fragment(const AFragment: TBytes;
      out AParams, AUrl: string): Boolean; static;

    /// <summary>Extracts the scheme part (everything before the first `:`).
    /// Returns '' when no colon is present. Result is lowercased.</summary>
    class function ExtractScheme(const AUrl: string): string; static;

    /// <summary>True when the URL's scheme is in the allow-list (case-insensitive).</summary>
    class function IsAllowedScheme(const AUrl: string;
      const AAllowed: TArray<string>): Boolean; static;

    /// <summary>Full policy gate: non-empty AND length ≤ AMaxLen AND scheme
    /// in AAllowed. Per ADR-033-03 / BR1.</summary>
    class function IsUrlAllowed(const AUrl: string; const AAllowed: TArray<string>;
      const AMaxLen: Integer): Boolean; static;

    /// <summary>Hardcoded v1 allow-list: http, https, mailto, file. Future
    /// demand exposes this via Aefos.OTA.Terminal.Core.Profiles.</summary>
    class function DefaultAllowedSchemes: TArray<string>; static;

    /// <summary>Single ShellExecuteW call site. Silently rejects URLs that fail
    /// the policy gate. Returns True if the OS handler was invoked, False if
    /// the URL was rejected. Per ADR-033-03 / BR1.</summary>
    class function Open(const AUrl: string): Boolean; static;

    /// <summary>Pure routing decision for an OSC 8 click: True only when the
    /// left mouse button is down, Ctrl is held, and the cell carries a URL.
    /// Used by TTerminalCanvas.MouseDown to gate the ShellExecute path (H-2 /
    /// H-7) and kept headlessly testable per ADR-056-03 / BR4.</summary>
    class function ShouldDispatchOnLeftClick(const AIsLeftButton, ACtrlHeld:
      Boolean; const AUrl: string): Boolean; static;
  end;

implementation

uses
  {$IFDEF FPC}Windows, ShellApi{$ELSE}Winapi.Windows, Winapi.ShellAPI{$ENDIF};

function _IsAllDigits(const AStr: string): Boolean;
var
  LIndex: Integer;
begin
  if AStr = '' then
    Exit(False);
  for LIndex := 1 to Length(AStr) do
    if not CharInSet(AStr[LIndex], ['0'..'9']) then
      Exit(False);
  Result := True;
end;

function _BytesToUtf8(const ABytes: TBytes): string;
begin
  if Length(ABytes) = 0 then
    Result := ''
  else
    Result := TEncoding.UTF8.GetString(ABytes);
end;

class function THyperlink.ParseOsc8Fragment(const AFragment: TBytes;
  out AParams, AUrl: string): Boolean;
var
  LStr: string;
  LSemi: Integer;
  LFirst: string;
begin
  AParams := '';
  AUrl := '';
  if Length(AFragment) = 0 then
    Exit(False);
  LStr := _BytesToUtf8(AFragment);
  // Tolerate a leading "N;" command prefix (the test harness feeds the full
  // OSC body; libvterm in production strips the prefix before delivery).
  LSemi := Pos(';', LStr);
  if LSemi > 1 then
  begin
    LFirst := Copy(LStr, 1, LSemi - 1);
    if _IsAllDigits(LFirst) then
      LStr := Copy(LStr, LSemi + 1, MaxInt);
  end;
  // Split remainder at the first ';' into (params, URI). When no semicolon
  // is present the whole payload is taken as the URI (short form `8;URI`).
  LSemi := Pos(';', LStr);
  if LSemi = 0 then
    AUrl := LStr
  else
  begin
    AParams := Copy(LStr, 1, LSemi - 1);
    AUrl := Copy(LStr, LSemi + 1, MaxInt);
  end;
  Result := True;
end;

class function THyperlink.ExtractScheme(const AUrl: string): string;
var
  LColon: Integer;
begin
  LColon := Pos(':', AUrl);
  if LColon <= 1 then
    Exit('');
  Result := LowerCase(Copy(AUrl, 1, LColon - 1));
end;

class function THyperlink.IsAllowedScheme(const AUrl: string;
  const AAllowed: TArray<string>): Boolean;
var
  LScheme: string;
  LIndex: Integer;
begin
  LScheme := ExtractScheme(AUrl);
  if LScheme = '' then
    Exit(False);
  for LIndex := 0 to High(AAllowed) do
    if SameText(AAllowed[LIndex], LScheme) then
      Exit(True);
  Result := False;
end;

class function THyperlink.IsUrlAllowed(const AUrl: string; const AAllowed: TArray<string>;
  const AMaxLen: Integer): Boolean;
begin
  Result := (AUrl <> '')
    and (Length(AUrl) <= AMaxLen)
    and IsAllowedScheme(AUrl, AAllowed);
end;

class function THyperlink.DefaultAllowedSchemes: TArray<string>;
begin
  Result := TArray<string>.Create('http', 'https', 'mailto', 'file');
end;

class function THyperlink.Open(const AUrl: string): Boolean;
begin
  // ADR-056-03 (H-5): explicit length cap as the FIRST guard so every future
  // exit point — including any scheme-specific shortcut a later edit might
  // add — is gated before reaching ShellExecuteW. Redundant with the cap
  // inside IsUrlAllowed; kept intentionally to harden the call site.
  if Length(AUrl) > DEFAULT_MAX_URL_LEN then
    Exit(False);
  if not IsUrlAllowed(AUrl, DefaultAllowedSchemes, DEFAULT_MAX_URL_LEN) then
    Exit(False);
  ShellExecuteW(0, nil, PWideChar(AUrl), nil, nil, SW_SHOWNORMAL);
  Result := True;
end;

class function THyperlink.ShouldDispatchOnLeftClick(const AIsLeftButton, ACtrlHeld:
  Boolean; const AUrl: string): Boolean;
begin
  Result := AIsLeftButton and ACtrlHeld and (AUrl <> '');
end;

end.


