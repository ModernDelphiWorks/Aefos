unit Aefos.OTA.Terminal.Core.Mustache;

(*
  Pure scanner + substitution helpers for {{dotted.name}} Mustache-style
  variables consumed by snippets - ESP-060 / ADR-060-01.

  Grammar (ADR-060-01): {{ \s* ident( "." ident )* \s* }}, where
  ident = [A-Za-z_][A-Za-z0-9_]*. Case-sensitive. Operates over the whole
  text including line breaks. Whitespace immediately inside the braces is
  tolerated. Anything that opens "{{" but does not match the full token form
  is treated as literal text and left untouched. Substitution is single-pass:
  substituted values are not re-scanned for further variables (BR4).

  VCL-free by design - the unit mirrors the layering posture of
  Aefos.OTA.Terminal.Core.ActionPlaceholders.pas (no Vcl.* imports) so snippet consumers can
  resolve variables from Core without dragging UI dependencies along. A
  distinct grammar and a distinct consumer keep this separate from the
  ${name} resolver (ADR-060-01).
*)

interface

uses
  System.Generics.Collections;

type
  /// <summary>
  /// Pure scanner + substitution engine for {{dotted.name}} Mustache-style
  /// variables. Stateless: all members are static.
  /// </summary>
  TMustacheEngine = class sealed
    /// <summary>
    /// Walks AText and returns the deduplicated list of variable names in
    /// first-occurrence order. A dotted name (e.g. <c>git.branch</c>) is captured
    /// whole. Fragments that do not match the strict <c>{{name}}</c> grammar are
    /// skipped without being reported.
    /// </summary>
    class function ScanVars(const AText: string): TArray<string>; static;

    /// <summary>
    /// Returns a copy of AText with every matched <c>{{name}}</c> token replaced
    /// by <c>AValues[name]</c>. Tokens whose name is absent from the dictionary -
    /// and any fragment that fails the strict grammar - are left verbatim.
    /// Empty-string values substitute as empty (distinct from "no entry").
    /// Substitution is single-pass.
    /// </summary>
    class function Substitute(const AText: string;
      const AValues: TDictionary<string, string>): string; static;
  end;

implementation

uses
  System.SysUtils;

/// <summary>
/// True when ACh is a valid first character for a variable identifier
/// (letter or underscore - ASCII only, per ADR-060-01).
/// </summary>
function _IsIdentifierStart(const ACh: Char): Boolean; inline;
begin
  Result := ((ACh >= 'A') and (ACh <= 'Z'))
         or ((ACh >= 'a') and (ACh <= 'z'))
         or (ACh = '_');
end;

/// <summary>
/// True when ACh is a valid continuation character for a variable identifier
/// (letter, digit, or underscore).
/// </summary>
function _IsIdentifierPart(const ACh: Char): Boolean; inline;
begin
  Result := ((ACh >= 'A') and (ACh <= 'Z'))
         or ((ACh >= 'a') and (ACh <= 'z'))
         or ((ACh >= '0') and (ACh <= '9'))
         or (ACh = '_');
end;

/// <summary>
/// True when ACh is whitespace tolerated inside the braces (space, tab,
/// CR, LF), matching the \s* of the grammar.
/// </summary>
function _IsBraceSpace(const ACh: Char): Boolean; inline;
begin
  Result := (ACh = ' ') or (ACh = #9) or (ACh = #10) or (ACh = #13);
end;

/// <summary>
/// Parses a dotted identifier (<c>ident ( "." ident )*</c>) in AText starting
/// at the 1-based index ACur, which must already point at an identifier-start
/// char. On success returns True with AName set to the whole dotted name and
/// ACur advanced just past the last consumed char. A trailing or empty dotted
/// segment (e.g. <c>git.</c>) yields False so the caller leaves it literal.
/// </summary>
function _ParseDottedIdent(const AText: string; var ACur: Integer;
  out AName: string): Boolean;
var
  LLen: Integer;
  LStart: Integer;
begin
  AName := '';
  LLen := Length(AText);
  repeat
    LStart := ACur;
    Inc(ACur);
    while (ACur <= LLen) and _IsIdentifierPart(AText[ACur]) do
      Inc(ACur);
    AName := AName + Copy(AText, LStart, ACur - LStart);

    // A "." continues the name only when an identifier start follows it.
    if (ACur > LLen) or (AText[ACur] <> '.') then
      Break;
    if (ACur + 1 > LLen) or not _IsIdentifierStart(AText[ACur + 1]) then
      Exit(False); // trailing/empty dotted segment -> malformed, leave literal
    AName := AName + '.';
    Inc(ACur);
  until False;
  Result := True;
end;

/// <summary>
/// Attempts to match a <c>{{ dotted.name }}</c> token in AText starting at the
/// 1-based index APos (which must point at the first '{'). On success returns
/// True with AName set to the captured dotted identifier and AEndPos set to
/// the 1-based index just past the closing '}}'. On failure returns False and
/// leaves the out parameters undefined; the caller advances by one char.
/// </summary>
function _TryParseMustacheAt(const AText: string; const APos: Integer;
  out AName: string; out AEndPos: Integer): Boolean;
var
  LLen: Integer;
  LCur: Integer;
begin
  Result := False;
  AName := '';
  LLen := Length(AText);
  if (APos < 1) or (APos + 1 > LLen) then
    Exit;
  if (AText[APos] <> '{') or (AText[APos + 1] <> '{') then
    Exit;

  LCur := APos + 2;
  while (LCur <= LLen) and _IsBraceSpace(AText[LCur]) do
    Inc(LCur);

  // First identifier segment is mandatory.
  if (LCur > LLen) or not _IsIdentifierStart(AText[LCur]) then
    Exit;

  if not _ParseDottedIdent(AText, LCur, AName) then
    Exit;

  while (LCur <= LLen) and _IsBraceSpace(AText[LCur]) do
    Inc(LCur);

  if (LCur + 1 > LLen) or (AText[LCur] <> '}') or (AText[LCur + 1] <> '}') then
    Exit;

  AEndPos := LCur + 2;
  Result := True;
end;

class function TMustacheEngine.ScanVars(const AText: string): TArray<string>;
var
  LList: TList<string>;
  LSeen: TDictionary<string, Boolean>;
  LPos: Integer;
  LLen: Integer;
  LName: string;
  LEnd: Integer;
begin
  LList := TList<string>.Create;
  LSeen := TDictionary<string, Boolean>.Create;
  try
    LPos := 1;
    LLen := Length(AText);
    while LPos <= LLen do
    begin
      if (AText[LPos] = '{')
        and _TryParseMustacheAt(AText, LPos, LName, LEnd) then
      begin
        if not LSeen.ContainsKey(LName) then
        begin
          LSeen.Add(LName, True);
          LList.Add(LName);
        end;
        LPos := LEnd;
      end
      else
        Inc(LPos);
    end;
    Result := LList.ToArray;
  finally
    LSeen.Free;
    LList.Free;
  end;
end;

class function TMustacheEngine.Substitute(const AText: string;
  const AValues: TDictionary<string, string>): string;
var
  LBuilder: TStringBuilder;
  LPos: Integer;
  LLen: Integer;
  LName: string;
  LEnd: Integer;
  LValue: string;
begin
  LLen := Length(AText);
  LBuilder := TStringBuilder.Create(LLen);
  try
    LPos := 1;
    while LPos <= LLen do
    begin
      if (AText[LPos] = '{')
        and _TryParseMustacheAt(AText, LPos, LName, LEnd) then
      begin
        if Assigned(AValues) and AValues.TryGetValue(LName, LValue) then
          LBuilder.Append(LValue)
        else
          LBuilder.Append(Copy(AText, LPos, LEnd - LPos));
        LPos := LEnd;
      end
      else
      begin
        LBuilder.Append(AText[LPos]);
        Inc(LPos);
      end;
    end;
    Result := LBuilder.ToString;
  finally
    LBuilder.Free;
  end;
end;

end.


