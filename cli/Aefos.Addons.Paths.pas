unit Aefos.Addons.Paths;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  Aefos Addons - filesystem roots and per-slug path resolution.

  The single place that knows the on-disk layout (contract §1). Content lives
  under ~/.aefos (%USERPROFILE%\.aefos): commands\, skills\, addons\. Slugs are
  validated to a filesystem-safe charset before they ever touch a path, so a
  registry/manifest slug can never traverse out of the addons tree.
}

interface

type
  { Static, sealed namespace for the on-disk addon layout. Never instantiated
    (no constructor): every routine is a class function so it has a named owner
    (e.g. TAddonPaths.CommandDir) instead of floating free in the unit interface.
    The class IS the namespace, so the old name prefixes are gone. }
  TAddonPaths = class sealed
  public
    { True when ASlug is a non-empty, filesystem-safe slug: only A-Z a-z 0-9 . _ -,
      no path separators, not '.'/'..'. Pure. }
    class function IsValidSlug(const ASlug: string): Boolean; static;

    { ~/.aefos (%USERPROFILE%\.aefos). Raises when %USERPROFILE% is unset. }
    class function UserRoot: string; static;

    { ~/.aefos\commands }
    class function CommandsRoot: string; static;
    { ~/.aefos\commands\<slug> }
    class function CommandDir(const ASlug: string): string; static;
    { ~/.aefos\skills }
    class function SkillsRoot: string; static;
    { ~/.aefos\skills\<slug> }
    class function SkillDir(const ASlug: string): string; static;
    { ~/.aefos\templates }
    class function TemplatesRoot: string; static;
    { ~/.aefos\templates\<slug> }
    class function TemplateDir(const ASlug: string): string; static;
    { ~/.aefos\addons }
    class function AddonsRoot: string; static;
    { ~/.aefos\addons\<slug> }
    class function AddonDir(const ASlug: string): string; static;
    { ~/.aefos\addons\installed.json }
    class function LedgerPath: string; static;
    { ~/.aefos\addons\mcp-servers.json - the aggregate the plugin merges. }
    class function McpAggregatePath: string; static;
  end;

implementation

uses
  SysUtils,
  Aefos.Compat.IO;

class function TAddonPaths.IsValidSlug(const ASlug: string): Boolean;
var
  LIndex: Integer;
  LCh: Char;
begin
  if (ASlug = '') or (ASlug = '.') or (ASlug = '..') then
    Exit(False);
  for LIndex := Low(ASlug) to High(ASlug) do
  begin
    LCh := ASlug[LIndex];
    if not CharInSet(LCh, ['A'..'Z', 'a'..'z', '0'..'9', '.', '_', '-']) then
      Exit(False);
  end;
  Result := True;
end;

class function TAddonPaths.UserRoot: string;
var
  LProfile: string;
begin
  LProfile := GetEnvironmentVariable('USERPROFILE');
  if LProfile = '' then
    raise Exception.Create('%USERPROFILE% is not set; cannot locate ~/.aefos.');
  Result := TPath.Combine(LProfile, '.aefos');
end;

class function TAddonPaths.CommandsRoot: string;
begin
  Result := TPath.Combine(UserRoot, 'commands');
end;

function _RequireSlug(const ASlug: string): string;
begin
  if not TAddonPaths.IsValidSlug(ASlug) then
    raise Exception.CreateFmt('Invalid addon slug "%s".', [ASlug]);
  Result := ASlug;
end;

class function TAddonPaths.CommandDir(const ASlug: string): string;
begin
  Result := TPath.Combine(CommandsRoot, _RequireSlug(ASlug));
end;

class function TAddonPaths.SkillsRoot: string;
begin
  Result := TPath.Combine(UserRoot, 'skills');
end;

class function TAddonPaths.SkillDir(const ASlug: string): string;
begin
  Result := TPath.Combine(SkillsRoot, _RequireSlug(ASlug));
end;

class function TAddonPaths.TemplatesRoot: string;
begin
  Result := TPath.Combine(UserRoot, 'templates');
end;

class function TAddonPaths.TemplateDir(const ASlug: string): string;
begin
  Result := TPath.Combine(TemplatesRoot, _RequireSlug(ASlug));
end;

class function TAddonPaths.AddonsRoot: string;
begin
  Result := TPath.Combine(UserRoot, 'addons');
end;

class function TAddonPaths.AddonDir(const ASlug: string): string;
begin
  Result := TPath.Combine(AddonsRoot, _RequireSlug(ASlug));
end;

class function TAddonPaths.LedgerPath: string;
begin
  Result := TPath.Combine(AddonsRoot, 'installed.json');
end;

class function TAddonPaths.McpAggregatePath: string;
begin
  Result := TPath.Combine(AddonsRoot, 'mcp-servers.json');
end;

end.
