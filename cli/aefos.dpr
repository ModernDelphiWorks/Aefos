program aefos;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{$APPTYPE CONSOLE}

{
  aefos.exe - the Aefos addon package manager.

  Downloads a versioned, sha256-verified addon bundle from the registry and lays
  its artifacts (command / skill+okf / mcp / tools) under ~/.aefos so Aefos
  recognises them automatically. See meta\aefos-addons-contract.md.

    aefos install <slug> [--yes]
    aefos uninstall <slug>
    aefos update [<slug>] [--check]   (no slug = all installed)
    aefos list

  Exit codes: 0 ok, 1 runtime failure, 2 usage error.
}

uses
  {$IFDEF FPC}
  // Windows first, SysUtils last: the WinAPI GetEnvironmentVariable (3-arg) must
  // NOT hide SysUtils' one-arg string version that AefosVersion calls.
  Windows,
  SysUtils,
  {$ELSE}
  System.SysUtils,
  Winapi.Windows,
  {$ENDIF}
  Aefos.Addons.Types in 'Aefos.Addons.Types.pas',
  Aefos.Addons.Paths in 'Aefos.Addons.Paths.pas',
  Aefos.Addons.Manifest in 'Aefos.Addons.Manifest.pas',
  Aefos.Addons.Sources in 'Aefos.Addons.Sources.pas',
  Aefos.Addons.Catalog in 'Aefos.Addons.Catalog.pas',
  Aefos.Addons.Ledger in 'Aefos.Addons.Ledger.pas',
  Aefos.Addons.Net in 'Aefos.Addons.Net.pas',
  Aefos.Addons.Installer in 'Aefos.Addons.Installer.pas',
  Aefos.Addons.Args in 'Aefos.Addons.Args.pas';

const
  // The manager's own version, printed by `aefos --version`.
  //
  // CAefosBaseline is the Aefos version an addon's requirements.aefos_version is
  // gated against. %AEFOS_VERSION% overrides it when set, but no installer sets
  // that variable today, so in practice the baseline IS the answer - which is
  // why it has to move with the release: a stale baseline refuses addons that
  // the running Aefos actually satisfies.
  //
  // Both are rewritten by scripts/bump-version.ps1. Do not edit by hand.
  CManagerVersion = '1.5.2';
  CAefosBaseline = '1.5.2';

var
  GArgv: TArray<string>;
  GArgs: TAddonCliArgs;
  GOpts: TInstallOptions;
  GCatalog: TArray<TAddonCatalogResult>;
  LIndex: Integer;

procedure Log(const ALine: string);
begin
  Writeln(ALine);
  Flush(Output);
end;

procedure PrintUsage;
begin
  Writeln('aefos ', CManagerVersion, ' - Aefos addon manager');
  Writeln('');
  Writeln('Usage:');
  Writeln('  aefos install <slug> [--yes]   download + install an addon');
  Writeln('  aefos uninstall <slug>         remove an installed addon');
  Writeln('  aefos update [<slug>] [--check]  refresh changed addons (no slug = all)');
  Writeln('  aefos list                     list installed addons');
  Writeln('  aefos catalog [--json]         what can be installed, from every source');
  Writeln('  aefos sources [--json]         the configured stores');
  Writeln('  aefos sources add <name> --kind path|aefos --location <where>');
  Writeln('  aefos sources remove <name>');
  Writeln('  aefos sources enable|disable <name>');
  Writeln('');
  Writeln('Options:');
  Writeln('  -y, --yes            consent to third-party code (mcp/tools) up front');
  Writeln('  --check              dry-run: report what would update, install nothing');
  Writeln('  --source <name>      take the addon from THAT store (see: aefos sources)');
  Writeln('  --registry <url>     override the registry URL');
  Writeln('  -h, --help           this help');
  Writeln('  -v, --version        version');
  Writeln('');
  Writeln('Addons install under ~/.aefos (commands, skills, addons).');
end;

function _OriginOf(const ASource: TAddonSource): string;
begin
  if ASource.Builtin then
    Result := 'official'
  else
    Result := 'custom';
end;

procedure PrintSources;
var
  LSources: TArray<TAddonSource>;
  LIndex: Integer;
  LWhere: string;
begin
  LSources := TAddonSources.Load;
  Writeln('Sources (custom ones live in ', TAddonSources.ConfigPath, '):');
  for LIndex := 0 to High(LSources) do
  begin
    LWhere := LSources[LIndex].Location;
    if LSources[LIndex].Builtin then
      LWhere := '(official gallery - not configurable)';
    if not LSources[LIndex].Enabled then
      LWhere := LWhere + '   (disabled)';
    Writeln(Format('  %-12s %-8s %-6s %s', [LSources[LIndex].Name,
      _OriginOf(LSources[LIndex]),
      TAddonSources.KindToStr(LSources[LIndex].Kind), LWhere]));
  end;
end;

// "aefos sources ..." - list, or one edit. The edits print what they did rather
// than staying silent: this is also the store window's only writer, and a window
// that says nothing after Save cannot tell "done" from "swallowed".
procedure RunSources;
begin
  case GArgs.SourceAction of
    asaAdd:
      begin
        TAddonSources.Add(GArgs.SourceName, GArgs.Kind, GArgs.Location);
        Writeln('Added store "', GArgs.SourceName, '".');
      end;
    asaRemove:
      begin
        TAddonSources.Remove(GArgs.SourceName);
        Writeln('Removed store "', GArgs.SourceName, '".');
      end;
    asaEnable:
      begin
        TAddonSources.SetEnabled(GArgs.SourceName, True);
        Writeln('Enabled store "', GArgs.SourceName, '".');
      end;
    asaDisable:
      begin
        TAddonSources.SetEnabled(GArgs.SourceName, False);
        Writeln('Disabled store "', GArgs.SourceName, '".');
      end;
  else
    if GArgs.Json then
      Writeln(TAddonSources.ToJson(TAddonSources.Load))
    else
      PrintSources;
  end;
end;

// The human view of the catalogue. --json is the one the IDE dialog reads; this
// is for the person at a prompt, and it prints the SOURCE first because with
// more than one store the name alone stops identifying anything.
procedure PrintCatalog(const AResults: TArray<TAddonCatalogResult>);
var
  LI, LJ, LTotal: Integer;
begin
  LTotal := 0;
  for LI := 0 to High(AResults) do
  begin
    if AResults[LI].Error <> '' then
    begin
      Writeln(Format('  ! %s: %s', [AResults[LI].Source.Name, AResults[LI].Error]));
      Continue;
    end;
    for LJ := 0 to High(AResults[LI].Rows) do
    begin
      Writeln(Format('  %-10s %-22s %-10s %s', [AResults[LI].Rows[LJ].Source,
        AResults[LI].Rows[LJ].Entry.Slug, AResults[LI].Rows[LJ].Entry.Version,
        AResults[LI].Rows[LJ].Entry.Name]));
      Inc(LTotal);
    end;
  end;
  Writeln(Format('%d addon(s) available.', [LTotal]));
end;

function AefosVersion: string;
begin
  Result := GetEnvironmentVariable('AEFOS_VERSION');
  if Trim(Result) = '' then
    Result := CAefosBaseline;
end;

begin
  try
    SetConsoleOutputCP(CP_UTF8);
    SetTextCodePage(Output, CP_UTF8);
    SetTextCodePage(ErrOutput, CP_UTF8);

    SetLength(GArgv, ParamCount);
    for LIndex := 1 to ParamCount do
      GArgv[LIndex - 1] := ParamStr(LIndex);
    GArgs := TAddonCliArgs.Parse(GArgv);

    if GArgs.Error <> '' then
    begin
      Writeln(ErrOutput, 'error: ', GArgs.Error);
      Halt(2);
    end;

    case GArgs.Command of
      acHelp:
        begin
          PrintUsage;
          Halt(0);
        end;
      acVersion:
        begin
          Writeln('aefos ', CManagerVersion);
          Halt(0);
        end;
    end;

    // A --registry flag wins over the env var the Net unit reads.
    if GArgs.Registry <> '' then
      {$IFDEF FPC}
      SetEnvironmentVariableW(PChar('AEFOS_ADDONS_REGISTRY'),
        PChar(GArgs.Registry));
      {$ELSE}
      SetEnvironmentVariable('AEFOS_ADDONS_REGISTRY', PChar(GArgs.Registry));
      {$ENDIF}

    GOpts := TInstallOptions.Create(GArgs.Yes, AefosVersion, GArgs.Source);

    case GArgs.Command of
      acInstall: TAddonInstaller.Install(GArgs.Slug, GOpts, Log);
      acUpdate:
        if GArgs.Check then
          TAddonInstaller.CheckUpdates(GArgs.Slug, Log)  // dry-run (slug optional)
        else if GArgs.Slug = '' then
          TAddonInstaller.UpdateAll(GOpts, Log)    // no slug => every installed addon
        else
          TAddonInstaller.Update(GArgs.Slug, GOpts, Log);
      acUninstall: TAddonInstaller.Uninstall(GArgs.Slug, Log);
      acList:    TAddonInstaller.List(Log);
      acSources: RunSources;
      acCatalog:
        begin
          GCatalog := TAddonCatalog.ReadAll;
          if GArgs.Json then
            Writeln(TAddonCatalog.ToJson(GCatalog))
          else
            PrintCatalog(GCatalog);
        end;
    end;
    Halt(0);
  except
    on E: EAddonError do
    begin
      Writeln(ErrOutput, 'error: ', E.Message);
      Halt(1);
    end;
    on E: Exception do
    begin
      Writeln(ErrOutput, 'error: ', E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
