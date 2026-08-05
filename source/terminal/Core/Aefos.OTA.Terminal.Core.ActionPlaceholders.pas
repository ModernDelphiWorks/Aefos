unit Aefos.OTA.Terminal.Core.ActionPlaceholders;

{$IFDEF FPC}{$mode delphi}{$H+}{$ENDIF}

(*
  Pure scanner + substitution helpers for ${name} placeholders carried inside
  TTerminalAction.ScriptLines - ESP-030 / ADR-030-01.

  Grammar (ADR-030-01): \$\{[A-Za-z_][A-Za-z0-9_]*\}. Case-sensitive. Anything
  that opens "${" but does not match the full token form is treated as
  literal text and left untouched. Substitution is single-pass: substituted
  values are not re-scanned for further placeholders.

  VCL-free by design - the unit mirrors the layering posture of
  Aefos.OTA.Terminal.Core.Actions.pas (no Vcl.* imports) so the runner can consume it from
  Core without dragging UI dependencies along.
*)

interface

uses
  {$IFDEF FPC}
  SysUtils, Generics.Collections;
  {$ELSE}
  System.SysUtils, System.Generics.Collections;
  {$ENDIF}

type
  /// <summary>
  /// Pure scanner + substitution helpers for <c>${name}</c> placeholders.
  /// Static-only: no instance, no constructor.
  /// </summary>
  TActionPlaceholders = class sealed
  public
    /// <summary>
    /// Walks AScriptLines and returns the deduplicated list of placeholder names
    /// in first-occurrence order. Tokens that do not match the strict
    /// <c>${identifier}</c> grammar are skipped without being reported.
    /// </summary>
    class function Scan(const AScriptLines: TArray<string>): TArray<string>; static;

    /// <summary>
    /// Returns a copy of AScriptLines with every matched <c>${name}</c> token
    /// replaced by <c>AValues[name]</c>. Tokens whose name is absent from the
    /// dictionary - and any fragment that fails the strict grammar - are left
    /// verbatim. Empty-string values substitute as empty (distinct from "no
    /// entry"). Substitution is single-pass.
    /// </summary>
    class function Substitute(const AScriptLines: TArray<string>;
      const AValues: TDictionary<string, string>): TArray<string>; static;
  end;

implementation

/// <summary>
/// True when ACh is a valid first character for a placeholder identifier
/// (letter or underscore - ASCII only, per ADR-030-01).
/// </summary>
function _IsIdentifierStart(const ACh: Char): Boolean; inline;
begin
  Result := ((ACh >= 'A') and (ACh <= 'Z'))
         or ((ACh >= 'a') and (ACh <= 'z'))
         or (ACh = '_');
end;

/// <summary>
/// True when ACh is a valid continuation character for a placeholder
/// identifier (letter, digit, or underscore).
/// </summary>
function _IsIdentifierPart(const ACh: Char): Boolean; inline;
begin
  Result := ((ACh >= 'A') and (ACh <= 'Z'))
         or ((ACh >= 'a') and (ACh <= 'z'))
         or ((ACh >= '0') and (ACh <= '9'))
         or (ACh = '_');
end;

/// <summary>
/// Attempts to match a <c>${identifier}</c> token in ALine starting at the
/// 1-based index APos (which must point at the literal '$'). On success
/// returns True with AName set to the captured identifier and AEndPos set to
/// the 1-based index just past the closing '}'. On failure returns False and
/// leaves the out parameters undefined; the caller advances by one char.
/// </summary>
function _TryParsePlaceholderAt(const ALine: string; const APos: Integer;
  out AName: string; out AEndPos: Integer): Boolean;
var
  LLen: Integer;
  LCur: Integer;
  LStart: Integer;
begin
  Result := False;
  LLen := Length(ALine);
  if (APos < 1) or (APos > LLen) then
    Exit;
  if ALine[APos] <> '$' then
    Exit;
  if APos + 1 > LLen then
    Exit;
  if ALine[APos + 1] <> '{' then
    Exit;
  LCur := APos + 2;
  if (LCur > LLen) or not _IsIdentifierStart(ALine[LCur]) then
    Exit;
  LStart := LCur;
  Inc(LCur);
  while (LCur <= LLen) and _IsIdentifierPart(ALine[LCur]) do
    Inc(LCur);
  if (LCur > LLen) or (ALine[LCur] <> '}') then
    Exit;
  AName := Copy(ALine, LStart, LCur - LStart);
  AEndPos := LCur + 1;
  Result := True;
end;

class function TActionPlaceholders.Scan(const AScriptLines: TArray<string>): TArray<string>;
var
  LList: TList<string>;
  LSeen: TDictionary<string, Boolean>;
  LLine: string;
  LPos: Integer;
  LLen: Integer;
  LName: string;
  LEnd: Integer;
begin
  LList := TList<string>.Create;
  LSeen := TDictionary<string, Boolean>.Create;
  try
    for LLine in AScriptLines do
    begin
      LPos := 1;
      LLen := Length(LLine);
      while LPos <= LLen do
      begin
        if (LLine[LPos] = '$')
          and _TryParsePlaceholderAt(LLine, LPos, LName, LEnd) then
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
    end;
    Result := LList.ToArray;
  finally
    LSeen.Free;
    LList.Free;
  end;
end;

class function TActionPlaceholders.Substitute(const AScriptLines: TArray<string>;
  const AValues: TDictionary<string, string>): TArray<string>;
var
  LOut: TArray<string>;
  LIndex: Integer;
  LLine: string;
  LBuilder: TStringBuilder;
  LPos: Integer;
  LLen: Integer;
  LName: string;
  LEnd: Integer;
  LValue: string;
begin
  SetLength(LOut, Length(AScriptLines));
  for LIndex := 0 to High(AScriptLines) do
  begin
    LLine := AScriptLines[LIndex];
    LLen := Length(LLine);
    LBuilder := TStringBuilder.Create(LLen);
    try
      LPos := 1;
      while LPos <= LLen do
      begin
        if (LLine[LPos] = '$')
          and _TryParsePlaceholderAt(LLine, LPos, LName, LEnd) then
        begin
          if Assigned(AValues) and AValues.TryGetValue(LName, LValue) then
            LBuilder.Append(LValue)
          else
            LBuilder.Append(Copy(LLine, LPos, LEnd - LPos));
          LPos := LEnd;
        end
        else
        begin
          LBuilder.Append(LLine[LPos]);
          Inc(LPos);
        end;
      end;
      LOut[LIndex] := LBuilder.ToString;
    finally
      LBuilder.Free;
    end;
  end;
  Result := LOut;
end;

end.


