unit Aefos.Compat.JsonFormat;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

(*
  TJSONValue.Format compatibility (Aefos -> Delphi 10 Seattle).

  System.JSON only grew Format(indent) - the pretty-printing serializer - in a
  release after 10 Seattle. Aefos calls it in fifteen places across seven units,
  and every one of them writes a file a HUMAN opens: .mcp.json, the chat config,
  a PyTools manifest, the AI-flow store, an addon ledger. Emitting those on one
  long line would be a real downgrade, not a cosmetic one.

  Fifteen version-guard blocks would be fifteen chances to fix one and miss the
  others. A CLASS HELPER puts it in exactly one place and leaves every call site
  untouched: on a compiler that has Format, this unit adds nothing and the RTL
  method is used; on Seattle the helper supplies it with the same name and
  signature, so a call reads and means the same thing either way.

  It helps TJSONAncestor rather than TJSONValue so one declaration reaches
  TJSONObject, TJSONArray and every other descendant.

  FPC: nothing here. Aefos.Compat.Json's own wrapper already implements Format,
  so this unit exists - harmless in a uses clause on both compilers - and is
  empty.

  ONE CAVEAT worth knowing: only ONE class helper for a type is active at a given
  point in the source, so another helper on TJSONAncestor in scope with this one
  would silently win. Nothing else in the tree helps that type today.

  (This header is a parenthesis-star comment on purpose: it needs to mention
  compiler directives, and a brace comment ends at the first closing brace -
  which a directive carries. That mistake cost a build round trip.)
*)

interface

{$IFNDEF FPC}
{$IF CompilerVersion < 35}   // below Delphi 11: see the boundary note above

uses
  System.JSON;

type
  TAefosJsonFormatHelper = class helper for TJSONAncestor
  public
    // Pretty-prints this value, indenting each nested level by AIndent spaces -
    // the signature System.JSON adopted later.
    function Format(const AIndent: Integer = 2): string;
  end;

{$IFEND}
{$ENDIF}

implementation

{$IFNDEF FPC}
{$IF CompilerVersion < 35}

uses
  System.SysUtils;

(*
  Re-indents compact JSON text.

  Deliberately a pass over the SERIALIZED form rather than a walk of the object
  tree: ToJSON is the one method every System.JSON version has and agrees on, so
  this cannot drift with the class API.

  The whole job is knowing when a brace is structure and when it is merely a
  character inside a string - hence LInString/LEscaped. Without them a Windows
  path holding brace characters would be read as an object and wreck the layout.
  LEscaped toggles rather than latching, because a backslash can escape another
  backslash - and a value ending in one would otherwise swallow its closing quote.
*)
function TAefosJsonFormatHelper.Format(const AIndent: Integer): string;
var
  LCompact: string;
  LBuilder: TStringBuilder;
  LIndex, LLevel: Integer;
  LChar, LNext, LPrev: Char;
  LInString, LEscaped: Boolean;

  procedure NewLineAt(const ALevel: Integer);
  begin
    LBuilder.Append(sLineBreak);
    if (AIndent > 0) and (ALevel > 0) then
      LBuilder.Append(StringOfChar(' ', AIndent * ALevel));
  end;

begin
  LCompact := Self.ToJSON;
  LLevel := 0;
  LInString := False;
  LEscaped := False;
  LBuilder := TStringBuilder.Create;
  try
    for LIndex := 1 to Length(LCompact) do
    begin
      LChar := LCompact[LIndex];

      if LInString then
      begin
        LBuilder.Append(LChar);
        if LEscaped then
          LEscaped := False
        else if LChar = '\' then
          LEscaped := True
        else if LChar = '"' then
          LInString := False;
        Continue;
      end;

      if LIndex < Length(LCompact) then
        LNext := LCompact[LIndex + 1]
      else
        LNext := #0;
      if LIndex > 1 then
        LPrev := LCompact[LIndex - 1]
      else
        LPrev := #0;

      case LChar of
        '"':
          begin
            LInString := True;
            LBuilder.Append(LChar);
          end;
        '{', '[':
          begin
            LBuilder.Append(LChar);
            // An empty container stays on one line, which is what the RTL does.
            // An indented blank line opened for nothing is the tell-tale of a
            // hand-rolled formatter.
            if ((LChar = '{') and (LNext = '}')) or ((LChar = '[') and (LNext = ']')) then
              Continue;
            Inc(LLevel);
            NewLineAt(LLevel);
          end;
        '}', ']':
          begin
            // Closing an empty container: its opener already declined to indent,
            // so this must not dedent either.
            if ((LChar = '}') and (LPrev = '{')) or ((LChar = ']') and (LPrev = '[')) then
            begin
              LBuilder.Append(LChar);
              Continue;
            end;
            Dec(LLevel);
            NewLineAt(LLevel);
            LBuilder.Append(LChar);
          end;
        ',':
          begin
            LBuilder.Append(LChar);
            NewLineAt(LLevel);
          end;
        ':':
          LBuilder.Append(': ');
      else
        LBuilder.Append(LChar);
      end;
    end;
    Result := LBuilder.ToString;
  finally
    LBuilder.Free;
  end;
end;

{$IFEND}
{$ENDIF}

end.
