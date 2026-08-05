unit Aefos.OTA.Chat.Core.ChatCommand;

{
  Slash-command parsing for the in-IDE chat panel (ESP-002, Epic 5/7,
  Demand 1/6).

  Pure helper unit: slash-trigger detection, query extraction, insert-text
  construction and leading-slash stripping. No OTA, no VCL, no Win32, no
  file I/O (C-3) — fully unit-testable on the QA bench.

  - BR-2: the chat panel's '/' command list triggers only when '/' is the
    first non-whitespace character of the current input line. A '/' typed
    elsewhere is literal text and must not open the list.
  - BR-3: selecting a list entry inserts '/<name> ' (single trailing space)
    into the input; BuildInsertText constructs that text.
  - StripLeadingSlash centralises the dispatch-string normalisation the WIP
    kept inline in ChatPanel._DispatchCommand.

  Constraints:
    - Delphi 13 only (C-1).
    - No conditional-compilation compatibility shims.
}

interface

// Reports whether AInput begins (after optional leading whitespace, on its
// first line) with a '/'. When it does, AQuery receives the text that
// follows the '/' on that line; otherwise AQuery is empty. BR-2.
function IsSlashTrigger(const AInput: string; out AQuery: string): Boolean;

// Builds the text inserted into the chat input when a list entry is picked:
// '/<name> ' with exactly one trailing space (BR-3). A leading '/' already
// present in AName is not duplicated.
function BuildInsertText(const AName: string): string;

// Returns ACommand trimmed, with a single leading '/' (if any) removed and
// the remainder trimmed again. Centralises the dispatch-string normalisation.
function StripLeadingSlash(const ACommand: string): string;

implementation

uses
  System.SysUtils;

// Returns AInput truncated at the first CR or LF — a slash command lives on
// a single line, so detection only inspects the first one.
function _FirstLine(const AInput: string): string;
var
  LBreak: Integer;
  LFor: Integer;
begin
  LBreak := 0;
  for LFor := 1 to Length(AInput) do
    if (AInput[LFor] = #13) or (AInput[LFor] = #10) then
    begin
      LBreak := LFor;
      Break;
    end;
  if LBreak > 0 then
    Result := Copy(AInput, 1, LBreak - 1)
  else
    Result := AInput;
end;

function IsSlashTrigger(const AInput: string; out AQuery: string): Boolean;
var
  LLine: string;
  LFor: Integer;
  LCh: Char;
begin
  AQuery := '';
  Result := False;
  LLine := _FirstLine(AInput);
  for LFor := 1 to Length(LLine) do
  begin
    LCh := LLine[LFor];
    if (LCh = ' ') or (LCh = #9) then
      Continue;
    // First non-whitespace character found — it decides the trigger.
    Result := LCh = '/';
    if Result then
      AQuery := Copy(LLine, LFor + 1, MaxInt);
    Exit;
  end;
end;

function BuildInsertText(const AName: string): string;
var
  LName: string;
begin
  LName := Trim(AName);
  if (Length(LName) > 0) and (LName[1] = '/') then
    LName := Copy(LName, 2, MaxInt);
  Result := '/' + LName + ' ';
end;

function StripLeadingSlash(const ACommand: string): string;
begin
  Result := Trim(ACommand);
  if (Length(Result) > 0) and (Result[1] = '/') then
    Result := Trim(Copy(Result, 2, MaxInt));
end;

end.
