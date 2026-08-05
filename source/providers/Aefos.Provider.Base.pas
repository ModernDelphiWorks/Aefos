unit Aefos.Provider.Base;

{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  Shared primitives every provider driver draws on, so each driver
  (Aefos.Provider.Claude/.Codex/.Copilot/.Gemini) only declares its own
  per-executor differences. RTL-only (System.SysUtils / System.IOUtils);
  no ToolsAPI, no Vcl.*, no file I/O.
}

interface

const
  MD_EXTENSION = '.md';
  // The default MCP server key every driver injects when the executor does not
  // override it (TProviderDispatchContext.McpServerName = ''). The RAD Studio
  // edition always resolves to this; the Lazarus edition passes a distinct name.
  DEFAULT_MCP_SERVER_NAME = 'aefos';

type
  { Pulls a CLI-minted conversation id out of a finished run's output. Shared by
    every ssCaptured driver (Codex, the Aefos agent CLI), so the parsing rule --
    and its edge cases -- live in ONE place instead of once per driver. Sealed
    static namespace (house rule: no loose exported routines); never
    instantiated. }
  TCliSessionScraper = class sealed
  public
    // Finds the LAST `<AMarker><id>` in AOutput and returns the id.
    //   LAST, not first, on purpose: a resumed run echoes its header again, and
    // a run the model-fallback self-heal RE-dispatched carries two headers --
    // the newest one is the conversation the NEXT turn must resume.
    //   The id runs to the first character that is neither a hex digit nor a
    // dash, so a trailing CR/LF, an ANSI remnant or punctuation can never end
    // up glued to it. Both ssCaptured CLIs mint dash-separated lowercase hex.
    // False when the marker is absent or nothing id-shaped follows it.
    class function TryIdAfterMarker(const AOutput, AMarker: UnicodeString;
      out AId: UnicodeString): Boolean; static;
  end;

// Resolves the MCP server key a driver should inject: the context override when
// present, else DEFAULT_MCP_SERVER_NAME. Single-sourced so every driver's MCP
// flag (mcp_servers.<name> / mcp__<name> / --allowed-mcp-server-names <name>)
// names the SAME host, and the RAD Studio path stays byte-identical ('aefos').
function ResolveMcpServerName(const AName: string): string;

// The `--model <model>` arg pair shared by Claude/Codex/Copilot (Gemini uses
// `-m` and inlines its own). Empty model -> no args. Sanitises the model first.
function BuildModelArgs(const AModel: string): TArray<string>;

// Strips a trailing " (annotation)" a user or a picker may have appended to a
// model id (e.g. "gemini-3.5-flash (Low)") and trims it. Such an annotation is
// never part of a real model id and, passed verbatim to the CLI, produces a
// cryptic provider 400. Empty/plain names pass through unchanged.
function SanitizeModelForCli(const AModel: string): string;

// ADR-098: a reference slice keeps its `<name>\references\<ref>.md` layout for
// every executor — the canonical structure is mirrored verbatim.
function ReferenceReplicaRelPath(const ACommandName,
  AReferenceName: string): string;

// ADR-080: strips a leading YAML frontmatter block (first line exactly '---',
// a later line exactly '---'). Absent/malformed frontmatter returns verbatim.
function StripFrontmatter(const AContent: string): string;

// ADR-237: the Codex global prompts root. $CODEX_HOME\prompts, else
// %USERPROFILE%\.codex\prompts.
function ResolveCodexPromptsRoot: string;
// Copilot global prompts root. $COPILOT_HOME\prompts, else
// %USERPROFILE%\.copilot\prompts.
function ResolveCopilotPromptsRoot: string;
// Gemini global commands root. $GEMINI_HOME\commands, else
// %USERPROFILE%\.gemini\commands.
function ResolveGeminiCommandsRoot: string;
// Local-model (Ollama) global commands root: %USERPROFILE%\.aefos\commands.
// Nothing consumes these replicas today; the global root keeps the
// replicator uniform without touching the user's project.
function ResolveAefosLocalCommandsRoot: string;

implementation

uses
{$IFDEF FPC}
  // FPC 3.2.2 ships no System.IOUtils; the TPath/TFile surface this unit uses
  // comes from the shim (Aefos.Compat.IO). Kept behind the IFDEF rather than
  // used unconditionally so the Delphi package graph is untouched: the shim is
  // compiled into Aefos.MCP.Core.bpl, which Aefos.Providers.bpl does not require.
  SysUtils,
  Aefos.Compat.IO;
{$ELSE}
  System.SysUtils,
  System.IOUtils;
{$ENDIF}
{ Provider.Base is deliberately provider-type-free: it holds only the shared
  string/path primitives, so the individual drivers depend on it without a cycle. }

const
  FRONTMATTER_MARK = '---';
  REFERENCES_FOLDER = 'references';

function ResolveMcpServerName(const AName: string): string;
begin
  if AName <> '' then
    Result := AName
  else
    Result := DEFAULT_MCP_SERVER_NAME;
end;

{ TCliSessionScraper }

class function TCliSessionScraper.TryIdAfterMarker(const AOutput,
  AMarker: UnicodeString; out AId: UnicodeString): Boolean;
var
  LFound: Integer;
  LProbe: Integer;
  LScan: Integer;
  LStop: Integer;
  LChar: Char;
begin
  AId := '';
  Result := False;
  if (AOutput = '') or (AMarker = '') then
    Exit;
  // Walk EVERY occurrence, keeping the last one -- see the header note. Scanned
  // with a plain Pos over a moving start rather than PosEx/StrUtils so the unit
  // stays on the RTL both compilers agree on.
  LFound := 0;
  LProbe := Pos(AMarker, AOutput);
  while LProbe > 0 do
  begin
    LFound := LProbe;
    LProbe := Pos(AMarker, AOutput, LProbe + Length(AMarker));
  end;
  if LFound = 0 then
    Exit;
  LScan := LFound + Length(AMarker);
  LStop := LScan;
  while LStop <= Length(AOutput) do
  begin
    LChar := AOutput[LStop];
    if ((LChar >= '0') and (LChar <= '9')) or
       ((LChar >= 'a') and (LChar <= 'f')) or
       ((LChar >= 'A') and (LChar <= 'F')) or (LChar = '-') then
      Inc(LStop)
    else
      Break;
  end;
  if LStop = LScan then
    Exit;
  AId := Copy(AOutput, LScan, LStop - LScan);
  Result := AId <> '';
end;

function SanitizeModelForCli(const AModel: string): string;
var
  LParen: Integer;
begin
  Result := Trim(AModel);
  if (Result <> '') and (Result[Length(Result)] = ')') then
  begin
    // Hand-scan for the last '(' rather than LastDelimiter: FPC's LastDelimiter
    // takes AnsiString, so under delphiunicode it would round-trip the model id
    // through the ANSI codepage (an "Implicit string type conversion with
    // potential data loss" warning that is a real bug for a non-ASCII label).
    // A `while` (not a `for`) because a for-loop variable's value is undefined
    // after the loop completes normally -- the not-found case must be readable.
    LParen := Length(Result);
    while (LParen > 0) and (Result[LParen] <> '(') do
      Dec(LParen);
    if (LParen > 1) and (Result[LParen - 1] = ' ') then
      Result := TrimRight(Copy(Result, 1, LParen - 1));
  end;
end;

function BuildModelArgs(const AModel: string): TArray<string>;
var
  LModel: string;
begin
  LModel := SanitizeModelForCli(AModel);
  SetLength(Result, 0);
  if LModel <> '' then
    Result := ['--model', LModel];
end;

function ReferenceReplicaRelPath(const ACommandName,
  AReferenceName: string): string;
begin
  Result := TPath.Combine(ACommandName,
    TPath.Combine(REFERENCES_FOLDER, AReferenceName + MD_EXTENSION));
end;

function ResolveCodexPromptsRoot: string;
var
  LBase: string;
begin
  LBase := GetEnvironmentVariable('CODEX_HOME');
  if LBase = '' then
    LBase := TPath.Combine(GetEnvironmentVariable('USERPROFILE'), '.codex');
  Result := TPath.Combine(LBase, 'prompts');
end;

function ResolveCopilotPromptsRoot: string;
var
  LBase: string;
begin
  LBase := GetEnvironmentVariable('COPILOT_HOME');
  if LBase = '' then
    LBase := TPath.Combine(GetEnvironmentVariable('USERPROFILE'), '.copilot');
  Result := TPath.Combine(LBase, 'prompts');
end;

function ResolveGeminiCommandsRoot: string;
var
  LBase: string;
begin
  LBase := GetEnvironmentVariable('GEMINI_HOME');
  if LBase = '' then
    LBase := TPath.Combine(GetEnvironmentVariable('USERPROFILE'), '.gemini');
  Result := TPath.Combine(LBase, 'commands');
end;

function ResolveAefosLocalCommandsRoot: string;
begin
  Result := TPath.Combine(
    TPath.Combine(GetEnvironmentVariable('USERPROFILE'), '.aefos'),
    'commands');
end;

// Reads one line from AContent starting at AStart. ALine excludes the line
// terminator; ANextStart points past it. CRLF, CR and LF are all recognised.
function _NextLine(const AContent: string; const AStart: Integer;
  out ALine: string; out ANextStart: Integer): Boolean;
var
  LEnd: Integer;
begin
  if AStart > Length(AContent) then
    Exit(False);
  LEnd := AStart;
  while (LEnd <= Length(AContent)) and
        (AContent[LEnd] <> #10) and (AContent[LEnd] <> #13) do
    Inc(LEnd);
  ALine := Copy(AContent, AStart, LEnd - AStart);
  if (LEnd <= Length(AContent)) and (AContent[LEnd] = #13) then
    Inc(LEnd);
  if (LEnd <= Length(AContent)) and (AContent[LEnd] = #10) then
    Inc(LEnd);
  ANextStart := LEnd;
  Result := True;
end;

// Drops leading blank (whitespace-only) lines; the surviving body is returned
// verbatim from the first non-blank line onward (BR-4).
function _TrimLeadingBlankLines(const ABody: string): string;
var
  LLine: string;
  LCursor: Integer;
  LNext: Integer;
begin
  LCursor := 1;
  while _NextLine(ABody, LCursor, LLine, LNext) do
  begin
    if Trim(LLine) <> '' then
      Break;
    LCursor := LNext;
  end;
  Result := Copy(ABody, LCursor, MaxInt);
end;

function StripFrontmatter(const AContent: string): string;
var
  LLine: string;
  LCursor: Integer;
  LNext: Integer;
  LIsFirst: Boolean;
begin
  LCursor := 1;
  LIsFirst := True;
  while _NextLine(AContent, LCursor, LLine, LNext) do
  begin
    if LIsFirst then
    begin
      if LLine <> FRONTMATTER_MARK then
        Exit(AContent);
      LIsFirst := False;
    end
    else if LLine = FRONTMATTER_MARK then
      Exit(_TrimLeadingBlankLines(Copy(AContent, LNext, MaxInt)));
    LCursor := LNext;
  end;
  Result := AContent;
end;

end.
