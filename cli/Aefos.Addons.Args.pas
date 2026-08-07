unit Aefos.Addons.Args;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  Aefos Addons - command-line grammar (pure, RTL-only, headless-testable).

  Grammar:
    aefos <command> [<slug>] [options]
    commands: install | uninstall | remove | update | list
      update takes an OPTIONAL slug: "aefos update" (no slug) = update ALL
      installed addons.
    options:  --yes | -y            pre-consent third-party (mcp/tools) code
              --check                dry-run: report what would update, install nothing
                                     (valid on update, with or without a slug)
              --registry <url>       override the registry URL (also AEFOS_ADDONS_REGISTRY)
              -h | --help | -v | --version

  Parsing never raises; a bad input lands in Result.Error.
}

interface

uses
  SysUtils;

type
  TAddonCommand = (acNone, acInstall, acUninstall, acUpdate, acList,
    acHelp, acVersion, acCatalog, acSources);

  TAddonCliArgs = record
    Command: TAddonCommand;
    Slug: string;
    Yes: Boolean;
    Check: Boolean;     // --check: dry-run, report without installing
    Json: Boolean;      // --json: machine-readable output (the IDE dialog reads it)
    Registry: string;   // '' = default/env
    Error: string;      // non-empty => parse failed (user-facing one-liner)
    { Parses the argv tail into this record. Never raises; a bad input lands in
      Result.Error. The record owns the parse that only exists to build it. }
    class function Parse(const AArgv: TArray<string>): TAddonCliArgs; static;
  end;

implementation

function _ParseCommand(const AWord: string; out ACmd: TAddonCommand): Boolean;
begin
  Result := True;
  if SameText(AWord, 'install') or SameText(AWord, 'add') then
    ACmd := acInstall
  else if SameText(AWord, 'uninstall') or SameText(AWord, 'remove') or
          SameText(AWord, 'rm') then
    ACmd := acUninstall
  else if SameText(AWord, 'update') or SameText(AWord, 'upgrade') then
    ACmd := acUpdate
  else if SameText(AWord, 'list') or SameText(AWord, 'ls') then
    ACmd := acList
  else if SameText(AWord, 'catalog') or SameText(AWord, 'search') then
    ACmd := acCatalog
  else if SameText(AWord, 'sources') then
    ACmd := acSources
  else
    Result := False;
end;

class function TAddonCliArgs.Parse(const AArgv: TArray<string>): TAddonCliArgs;
var
  LIndex: Integer;
  LArg: string;
begin
  Result := Default(TAddonCliArgs);
  Result.Command := acNone;
  LIndex := 0;
  while LIndex <= High(AArgv) do
  begin
    LArg := AArgv[LIndex];
    if (LArg = '-h') or (LArg = '--help') then
    begin
      Result.Command := acHelp;
      Exit;
    end;
    if (LArg = '-v') or (LArg = '--version') then
    begin
      Result.Command := acVersion;
      Exit;
    end;
    if (LArg = '-y') or (LArg = '--yes') then
      Result.Yes := True
    else if LArg = '--check' then
      Result.Check := True
    else if SameText(LArg, '--json') then
      Result.Json := True
    else if LArg = '--registry' then
    begin
      if LIndex >= High(AArgv) then
      begin
        Result.Error := 'Missing URL after --registry.';
        Exit;
      end;
      Inc(LIndex);
      Result.Registry := AArgv[LIndex];
    end
    else if (LArg <> '') and (LArg[1] = '-') then
    begin
      Result.Error := 'Unknown option ' + LArg + '. Try --help.';
      Exit;
    end
    else if Result.Command = acNone then
    begin
      if not _ParseCommand(LArg, Result.Command) then
      begin
        Result.Error := 'Unknown command "' + LArg +
          '". Use install, uninstall, update, list, catalog or sources.';
        Exit;
      end;
    end
    else if Result.Slug = '' then
      Result.Slug := LArg
    else
    begin
      Result.Error := 'Unexpected argument "' + LArg + '".';
      Exit;
    end;
    Inc(LIndex);
  end;

  if Result.Command = acNone then
  begin
    Result.Command := acHelp;
    Exit;
  end;
  // install/uninstall need a slug; update does NOT (no slug => all installed).
  if (Result.Command in [acInstall, acUninstall]) and (Result.Slug = '') then
    Result.Error := 'This command needs an addon slug (e.g. "aefos install janus-orm").';
end;

end.
