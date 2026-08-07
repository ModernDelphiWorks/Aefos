unit Aefos.OTA.Chat.Core.AddonStore;

(*
  Aefos.OTA.Chat.Core.AddonStore - the store's only door to the addon manager.

  The store dialog shows a list and installs from it. Neither of those is
  implemented here, and neither is implemented in the dialog: both are questions
  only aefos.exe can answer, because reading a store (an HTTP gallery, a folder,
  a company share), measuring a bundle's identity and deciding whether a row is
  current is real logic that already exists there, single-source and proven. A
  second implementation living in the IDE would be free to disagree with the
  first, and the disagreement would surface as an install that does the wrong
  thing quietly.

  So this unit is deliberately thin: build a command line, run it, hand back
  what came out. It does NOT parse the catalogue - the JSON goes to the page as
  it arrived, because the page is the only thing that renders it and a Pascal
  record in between would be a third place to keep the schema.

  BOUNDARY: RTL + the existing process runner. No Vcl., no ToolsAPI, no WebView.
  That is what makes it testable from a console and callable from anywhere.

  THREADING: TProcessRunner.Run BLOCKS, and its own header says it must not be
  called on the IDE main thread - a store that is slow to answer would otherwise
  freeze the IDE. Everything here inherits that rule; the caller owns the thread
  and the marshalling back.
*)

interface

uses
  System.SysUtils;

type
  { What one aefos.exe invocation produced. Ok is the only thing a caller has
    to check: Output carries the text either way, because the CLI's failures are
    written for a person to read and throwing that away to raise a generic
    exception would lose the only useful part. }
  TAddonStoreResult = record
    Ok: Boolean;
    ExitCode: Integer;
    Output: string;      // stdout + stderr, in the order the CLI wrote them
  end;

  { Static, sealed namespace; never instantiated. }
  TAefosAddonStore = class sealed
  public
    { Absolute path of aefos.exe, or '' when it is not installed. The installer
      puts it in %APPDATA%\Aefos\bin, which is also where build-packages.ps1
      stages it, so one answer covers a developer machine and a user's. }
    class function ExePath: string; static;

    { True when the manager is present. The dialog asks FIRST, so it can say
      "the addon manager is not installed" instead of showing an empty store,
      which looks like "there is nothing to install". }
    class function Available: Boolean; static;

    { `aefos catalog --json`. Returns the document untouched - addons[], errors[]
      and all - for the page to render. }
    class function CatalogJson: TAddonStoreResult; static;

    { `aefos install <slug> --source <store> --yes`.

      --yes is passed because the store dialog IS the consent surface: the user
      pressed Install on a row that showed the trust badge. Nothing else about
      the gate changes - trust is still clamped to what the STORE is, so a
      community bundle stays community however its publisher labelled it. }
    class function Install(const ASlug, ASource: string): TAddonStoreResult; static;

    { `aefos update <slug> --source <store> --yes`. }
    class function Update(const ASlug, ASource: string): TAddonStoreResult; static;

    { `aefos uninstall <slug>`. No source: the ledger already knows where it came
      from, and passing one here would let the dialog remove something other than
      what it is showing. }
    class function Remove(const ASlug: string): TAddonStoreResult; static;
  end;

implementation

uses
  System.IOUtils,
  Aefos.Tools.Process;

const
  // Long enough for a slow gallery on a bad connection, short enough that a
  // hung child cannot hold a thread forever. The runner kills on timeout.
  CTimeoutMs = 120000;

class function TAefosAddonStore.ExePath: string;
var
  LAppData: string;
begin
  Result := '';
  LAppData := GetEnvironmentVariable('APPDATA');
  if LAppData = '' then
    Exit;
  Result := TPath.Combine(TPath.Combine(LAppData, 'Aefos'),
    TPath.Combine('bin', 'aefos.exe'));
  if not TFile.Exists(Result) then
    Result := '';
end;

class function TAefosAddonStore.Available: Boolean;
begin
  Result := ExePath <> '';
end;

// A slug or a store name reaches here from the page, and the page got it from
// the catalogue - but the trip through JSON means it is still just a string, so
// it is quoted rather than trusted. CreateProcess takes one command line and
// splits it itself; an unquoted name with a space would silently become two
// arguments.
function _Quote(const AValue: string): string;
begin
  Result := '"' + StringReplace(AValue, '"', '""', [rfReplaceAll]) + '"';
end;

function _Run(const AArgs: string): TAddonStoreResult;
var
  LExe: string;
  LRes: TToolProcessResult;
begin
  Result := Default(TAddonStoreResult);
  LExe := TAefosAddonStore.ExePath;
  if LExe = '' then
  begin
    Result.Output := 'The Aefos addon manager (aefos.exe) is not installed.';
    Exit;
  end;
  LRes := TProcessRunner.Run(LExe, AArgs, '', '', CTimeoutMs);
  Result.ExitCode := Integer(LRes.ExitCode);
  Result.Ok := LRes.Ok;
  Result.Output := LRes.StdOut;
  if Trim(LRes.StdErr) <> '' then
  begin
    if Trim(Result.Output) <> '' then
      Result.Output := Result.Output + sLineBreak;
    Result.Output := Result.Output + LRes.StdErr;
  end;
  // A timeout or a failed spawn has no exit code worth reporting, so say what
  // happened instead of leaving the caller with an empty, successful-looking
  // result.
  if LRes.Outcome <> poCompleted then
  begin
    if Trim(Result.Output) <> '' then
      Result.Output := Result.Output + sLineBreak;
    Result.Output := Result.Output + LRes.OutcomeText;
  end;
end;

// The store argument is optional at the CLI, and omitting it means "any store" -
// which the dialog must never do: every row it shows names its store, so the
// action it fires has to name the same one. A row without a source is a bug
// upstream, and passing nothing would turn it into an ambiguous install.
function _SourceArg(const ASource: string): string;
begin
  if Trim(ASource) = '' then
    Result := ''
  else
    Result := ' --source ' + _Quote(ASource);
end;

class function TAefosAddonStore.CatalogJson: TAddonStoreResult;
begin
  Result := _Run('catalog --json');
end;

class function TAefosAddonStore.Install(
  const ASlug, ASource: string): TAddonStoreResult;
begin
  Result := _Run('install ' + _Quote(ASlug) + _SourceArg(ASource) + ' --yes');
end;

class function TAefosAddonStore.Update(
  const ASlug, ASource: string): TAddonStoreResult;
begin
  Result := _Run('update ' + _Quote(ASlug) + _SourceArg(ASource) + ' --yes');
end;

class function TAefosAddonStore.Remove(const ASlug: string): TAddonStoreResult;
begin
  Result := _Run('uninstall ' + _Quote(ASlug));
end;

end.
