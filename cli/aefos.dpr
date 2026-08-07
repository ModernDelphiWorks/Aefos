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
  Aefos.Addons.PluginFormat in 'Aefos.Addons.PluginFormat.pas',
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
  CManagerVersion = '1.4.0';
  CAefosBaseline = '1.4.0';

var
  GArgv: TArray<string>;
  GArgs: TAddonCliArgs;
  GOpts: TInstallOptions;
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
  Writeln('');
  Writeln('Options:');
  Writeln('  -y, --yes            consent to third-party code (mcp/tools) up front');
  Writeln('  --check              dry-run: report what would update, install nothing');
  Writeln('  --registry <url>     override the registry URL');
  Writeln('  -h, --help           this help');
  Writeln('  -v, --version        version');
  Writeln('');
  Writeln('Addons install under ~/.aefos (commands, skills, addons).');
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

    GOpts := TInstallOptions.Create(GArgs.Yes, AefosVersion);

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
