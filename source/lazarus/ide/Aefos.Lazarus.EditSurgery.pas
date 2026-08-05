unit Aefos.Lazarus.EditSurgery;

{ Aefos AI - Lazarus edition: pure text-surgery seam for the Phase H editor
  write slice.

  Semantics ported VERBATIM from the Delphi
  source\mcp\OTA\Aefos.MCP.OTA.ContentWritePolicy.pas (InsertTextAt /
  ReplaceInBuffer and their EOL / line-column helpers), so the Lazarus write
  slice reproduces the OTA write BEHAVIOUR exactly - only the mechanics differ
  (a live TSourceEditorInterface buffer here vs an IOTAEditWriter there). That
  Delphi unit can't be reused directly: it lives outside the Lazarus package
  search path and is dotted (System.SysUtils / System.IOUtils /
  System.Generics.Collections) + depends on the OTA-side PasParser; this is the
  small, dependency-free port of just the two surgeries Phase H needs.

  Pure RTL only (no LCL, no IDEIntf, no disk). All operations take and return
  UnicodeString (the MCP core's string), so the facade converts UTF-8<->UTF-16
  only at the IDEIntf boundary, never here.

  Line/column inputs are 1-based; column 1 is the position before the first
  character of the line (the OTA caret convention the ports share). }

{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

interface

type
  { Sealed static namespace, mirroring TContentWritePolicy. Never instantiated. }
  TAefosEditSurgery = class sealed
  public
    // Insert AText at the (ALine, ACol) caret in ASource, returning the new full
    // source in ANew. False (with ASource echoed) when the caret is invalid.
    class function InsertTextAt(const ASource, AText: UnicodeString;
      const ALine, ACol: Integer; out ANew: UnicodeString): Boolean; static;

    // Find/replace AFind with AReplace over ASource. AAll replaces every match,
    // else only the first. ACount carries the substitution count. Always
    // succeeds (a zero-match call is a valid no-op, ACount = 0); False only when
    // AFind is empty (nothing to search for).
    class function ReplaceInBuffer(const ASource, AFind, AReplace: UnicodeString;
      const AAll: Boolean; out ANew: UnicodeString; out ACount: Integer): Boolean; static;
  end;

implementation

uses
  SysUtils;

// ---------------------------------------------------------------------------
// EOL handling - preserve the buffer's dominant line ending across a surgery.
// ---------------------------------------------------------------------------

function _DetectEol(const ASource: UnicodeString): UnicodeString;
begin
  if Pos(UnicodeString(#13#10), ASource) > 0 then
    Result := #13#10
  else if Pos(UnicodeString(#10), ASource) > 0 then
    Result := #10
  else if Pos(UnicodeString(#13), ASource) > 0 then
    Result := #13
  else
    Result := #13#10;
end;

// Re-encode any line endings inside AText to AEol so inserted text matches the
// host buffer. Pure UnicodeString scan - NOT SysUtils.StringReplace, which is
// AnsiString-typed and would round-trip non-ASCII through the ANSI codepage
// (data loss). CRLF, lone CR and lone LF all collapse to one AEol.
function _NormalizeEol(const AText, AEol: UnicodeString): UnicodeString;
var
  LIdx, LLen: Integer;
  LCh: WideChar;
begin
  Result := '';
  LIdx := 1;
  LLen := Length(AText);
  while LIdx <= LLen do
  begin
    LCh := AText[LIdx];
    if LCh = #13 then
    begin
      Result := Result + AEol;
      if (LIdx < LLen) and (AText[LIdx + 1] = #10) then
        Inc(LIdx); // consume the LF half of a CRLF
    end
    else if LCh = #10 then
      Result := Result + AEol
    else
      Result := Result + LCh;
    Inc(LIdx);
  end;
end;

// 1-based character index in ASource of the (ALine, ACol) caret. CRLF counts as
// one line break. A caret past the end clamps to Length+1.
function _IndexOfLineCol(const ASource: UnicodeString;
  const ALine, ACol: Integer): Integer;
var
  LIdx, LLine, LCol: Integer;
begin
  LLine := 1;
  LCol  := 1;
  LIdx  := 1;
  while LIdx <= Length(ASource) do
  begin
    if (LLine = ALine) and (LCol = ACol) then
    begin
      Result := LIdx;
      Exit;
    end;
    case ASource[LIdx] of
      #13:
        begin
          if (LIdx < Length(ASource)) and (ASource[LIdx + 1] = #10) then
            Inc(LIdx);
          Inc(LLine);
          LCol := 1;
        end;
      #10:
        begin
          Inc(LLine);
          LCol := 1;
        end;
    else
      Inc(LCol);
    end;
    Inc(LIdx);
  end;
  Result := Length(ASource) + 1;
end;

class function TAefosEditSurgery.InsertTextAt(const ASource, AText: UnicodeString;
  const ALine, ACol: Integer; out ANew: UnicodeString): Boolean;
var
  LAt: Integer;
begin
  ANew := ASource;
  Result := False;
  if (ALine < 1) or (ACol < 1) then
    Exit;
  LAt := _IndexOfLineCol(ASource, ALine, ACol);
  ANew := Copy(ASource, 1, LAt - 1) +
          _NormalizeEol(AText, _DetectEol(ASource)) +
          Copy(ASource, LAt, MaxInt);
  Result := True;
end;

class function TAefosEditSurgery.ReplaceInBuffer(const ASource, AFind,
  AReplace: UnicodeString; const AAll: Boolean; out ANew: UnicodeString;
  out ACount: Integer): Boolean;
var
  LFrom, LAt: Integer;
  LBuilder: TUnicodeStringBuilder;
begin
  ANew := ASource;
  ACount := 0;
  if AFind = '' then
  begin
    Result := False;
    Exit;
  end;
  // Builder accumulation: plain concatenation is O(n^2) over a buffer with
  // many hits - this is a future MCP tool path over whole units. The type
  // must be TUnicodeStringBuilder EXPLICITLY: in FPC 3.2.2 the TStringBuilder
  // alias is ALWAYS TAnsiStringBuilder (sysstrh.inc:339, no mode conditional),
  // which would silently round-trip UnicodeString through the ANSI codepage.
  LBuilder := TUnicodeStringBuilder.Create;
  try
    LFrom := 1;
    repeat
      LAt := Pos(AFind, ASource, LFrom); // 1-based hit, 0 when none (FPC 3-arg Pos)
      if LAt = 0 then
        Break;
      LBuilder.Append(Copy(ASource, LFrom, LAt - LFrom));
      LBuilder.Append(AReplace);
      Inc(ACount);
      LFrom := LAt + Length(AFind);
      if not AAll then
        Break;
    until False;
    LBuilder.Append(Copy(ASource, LFrom, MaxInt));
    ANew := LBuilder.ToString;
  finally
    LBuilder.Free;
  end;
  Result := True;
end;

end.
