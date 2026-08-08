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
              --source <name>        take the slug from THAT configured store
                                     (required when two stores publish the name)
              --registry <url>       override the registry URL (also AEFOS_ADDONS_REGISTRY)
              -h | --help | -v | --version

    sources takes an ACTION as well, because the store list is edited from the
    store window and the CLI stays its ONE writer - two writers of the same file
    is a bug this project has already paid for once:

      aefos sources                          list them
      aefos sources --json                   the same list, for the store window
      aefos sources add <name> --kind path|aefos|git --location <where>
      aefos sources remove <name>
      aefos sources enable <name> | disable <name>

  Parsing never raises; a bad input lands in Result.Error.
}

interface

uses
  SysUtils;

type
  TAddonCommand = (acNone, acInstall, acUninstall, acUpdate, acList,
    acHelp, acVersion, acCatalog, acSources);

  { What "aefos sources" is being asked to do. Listing is the one that needs no
    word, so it is also what an unadorned "aefos sources" keeps meaning. }
  TAddonSourceAction = (asaList, asaAdd, asaRemove, asaEnable, asaDisable);

  TAddonCliArgs = record
    Command: TAddonCommand;
    Slug: string;
    Yes: Boolean;
    Check: Boolean;     // --check: dry-run, report without installing
    Json: Boolean;      // --json: machine-readable output (the IDE dialog reads it)
    Source: string;     // --source: which configured store to use ('' = any)
    Registry: string;   // '' = default/env
    { sources only. SourceName is the store being edited - deliberately NOT
      reusing Slug, which means an addon everywhere else in this record. }
    SourceAction: TAddonSourceAction;
    SourceName: string;
    Kind: string;       // --kind: aefos | path | git (parsed by TAddonSources)
    Location: string;   // --location: URL or directory
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
  else if SameText(AWord, 'sources') or SameText(AWord, 'source') then
    ACmd := acSources
  else
    Result := False;
end;

{ The word after "sources". "list" is accepted for symmetry even though bare
  "aefos sources" already means it. }
function _ParseSourceAction(const AWord: string;
  out AAction: TAddonSourceAction): Boolean;
begin
  Result := True;
  if SameText(AWord, 'add') then
    AAction := asaAdd
  else if SameText(AWord, 'remove') or SameText(AWord, 'rm') or
          SameText(AWord, 'delete') then
    AAction := asaRemove
  else if SameText(AWord, 'enable') then
    AAction := asaEnable
  else if SameText(AWord, 'disable') then
    AAction := asaDisable
  else if SameText(AWord, 'list') or SameText(AWord, 'ls') then
    AAction := asaList
  else
    Result := False;
end;

class function TAddonCliArgs.Parse(const AArgv: TArray<string>): TAddonCliArgs;
var
  LIndex: Integer;
  LArg: string;
  LSeenAction: Boolean;
begin
  Result := Default(TAddonCliArgs);
  Result.Command := acNone;
  LSeenAction := False;
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
    else if SameText(LArg, '--source') then
    begin
      if LIndex >= High(AArgv) then
      begin
        Result.Error := 'Missing store name after --source.';
        Exit;
      end;
      Inc(LIndex);
      Result.Source := AArgv[LIndex];
    end
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
    else if SameText(LArg, '--kind') then
    begin
      if LIndex >= High(AArgv) then
      begin
        Result.Error := 'Missing kind after --kind (aefos, path or git).';
        Exit;
      end;
      Inc(LIndex);
      Result.Kind := AArgv[LIndex];
    end
    else if SameText(LArg, '--location') or SameText(LArg, '--url') then
    begin
      if LIndex >= High(AArgv) then
      begin
        Result.Error := 'Missing value after ' + LArg + '.';
        Exit;
      end;
      Inc(LIndex);
      Result.Location := AArgv[LIndex];
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
    else if Result.Command = acSources then
    begin
      // "sources" spends its positionals on ACTION then NAME; every other
      // command spends its first one on a slug.
      if not LSeenAction then
      begin
        if not _ParseSourceAction(LArg, Result.SourceAction) then
        begin
          Result.Error := 'Unknown sources action "' + LArg +
            '". Use add, remove, enable or disable.';
          Exit;
        end;
        LSeenAction := True;
      end
      else if Result.SourceName = '' then
        Result.SourceName := LArg
      else
      begin
        Result.Error := 'Unexpected argument "' + LArg + '".';
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
  begin
    Result.Error := 'This command needs an addon slug (e.g. "aefos install janus-orm").';
    Exit;
  end;
  if Result.Command = acSources then
  begin
    // Every action but listing edits ONE named store, so the name is the whole
    // subject of the command; without it there is nothing to guess at.
    if (Result.SourceAction <> asaList) and (Result.SourceName = '') then
    begin
      Result.Error := 'This command needs a store name (e.g. "aefos sources ' +
        'disable team").';
      Exit;
    end;
    if (Result.SourceAction = asaAdd) and (Result.Location = '') then
      Result.Error := 'A store needs somewhere to read: pass --location ' +
        '<folder, share or URL>.';
  end;
end;

end.
