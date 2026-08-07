unit Aefos.Addons.PluginFormat;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

(*
  Aefos Addons - reading agent-plugin bundles that were not packaged for Aefos.

  WHY. Aefos invented a bundle format (addon.json, contract docs/addons-contract.md)
  before there was one to adopt. There is one now, and it is the same shape:
  VS Code ships "agent plugins", Claude Code ships "plugins", and both are a
  directory of skills, commands, MCP servers and hooks under a small manifest.
  Keeping a private dialect buys nothing - the packaging was never the thing
  Aefos is good at - and it costs the ability to install what already exists.

  So this unit teaches the CLI to READ the other formats. VS Code auto-detects
  four, and they differ only in where two files live:

    Format             Manifest                      MCP config
    Agent Plugins 1.0  plugin.json ($schema)         mcp.json
    Copilot            plugin.json                   .mcp.json
    Claude             .claude-plugin/plugin.json    .mcp.json
    OpenPlugin (old)   .plugin/plugin.json           -

  skills/ is discovered the same way in all of them. That is why supporting
  several is a detection table rather than four implementations.

  HOW IT LANDS. The installer already knows one way to place a bundle: the
  install[] mappings (source directory -> path under ~/.aefos). Rather than
  teach the installer a second placement engine, this unit ADAPTS a foreign
  bundle into those mappings - normalising, in a staging folder inside the
  extracted copy, only the two things the mapping engine cannot express:
  a per-file command, and an MCP fragment that has to be unwrapped.

  THREE DECISIONS worth stating, because they are not obvious:

  1. The whole foreign tree is copied to ~/.aefos/addons/<slug>/, and THAT is
     the plugin root. It has to be: an MCP server declared as
     "${CLAUDE_PLUGIN_ROOT}/servers/db-server" only resolves if the scripts and
     binaries beside it came along. Placing just the skills would install a
     plugin whose tools cannot start - the worst kind of half-success.

  2. Skills and commands are NAMESPACED BY SLUG. A plugin brings N of each,
     Aefos historically had one per addon, and two plugins each shipping a
     "review" command would otherwise silently overwrite one another.
     skills/<n> becomes ~/.aefos/skills/<slug>.<n>.

  3. What Aefos has no home for is REPORTED, not dropped in silence. Agents,
     hooks, LSP servers and monitors are real parts of a plugin; a user whose
     hook never runs deserves a line saying so at install time rather than a
     mystery later.
*)

interface

uses
  SysUtils,
  Aefos.Addons.Types;

type
  { Which bundle layout a directory is in. pfNone means no manifest we know. }
  TPluginFormat = (pfNone, pfAefos, pfAgentPlugins, pfCopilot, pfClaude,
    pfOpenPlugin);

  { Called with one human-readable line per adoption decision. }
{$IFDEF FPC}
  TPluginFormatLog = procedure(const ALine: string);
{$ELSE}
  TPluginFormatLog = reference to procedure(const ALine: string);
{$ENDIF}

  { Static, sealed namespace: the class IS the namespace, never instantiated. }
  TAddonPluginFormat = class sealed
  public
    { Which format the directory is in, by the documented manifest paths.
      Aefos's own addon.json wins when present, so nothing about existing
      bundles changes. }
    class function Detect(const ABundleDir: string): TPluginFormat; static;

    { Display name for messages ('Claude plugin', 'Agent Plugins 1.0', ...). }
    class function FormatName(const AFormat: TPluginFormat): string; static;

    { Where that format keeps its manifest, so a catalogue can read a bundle's
      name and version without adopting it. Exposed rather than duplicated: the
      point of a detection table is that it exists in one place. }
    class function ManifestPathOf(const ABundleDir: string;
      const AFormat: TPluginFormat): string; static;

    { Where that format keeps its MCP config, or '' when it carries none - so a
      catalogue can tell what TYPE a bundle is without adopting it. Exposed for
      the same reason as ManifestPathOf: a detection table that gets copied is
      no longer a table. }
    class function McpConfigPathOf(const ABundleDir: string;
      const AFormat: TPluginFormat): string; static;

    { Turns a foreign bundle into a manifest the installer can already place:
      metadata read from the foreign manifest, install[] mappings synthesised
      from the layout, artifacts set from what was actually found. Normalises
      into <bundle>\_aefos, which is inside the temp copy and never shipped.
      Raises EAddonManifest when the bundle carries nothing installable. }
    class function Adopt(const ABundleDir, ASlug: string;
      const AFormat: TPluginFormat;
      const ALog: TPluginFormatLog): TAddonManifest; static;
  end;

implementation

uses
  Classes,
  IOUtils,
  Types,
  Generics.Collections,
  Aefos.Compat.Json,
  Aefos.Addons.Paths;

const
  CStageDir     = '_aefos';    // normalisation staging, inside the temp copy
  CAgentSchema  = 'agent-plugins.org';

function _ReadTextIfExists(const APath: string): string;
begin
  Result := '';
  if not TFile.Exists(APath) then
    Exit;
  try
    Result := TFile.ReadAllText(APath, TEncoding.UTF8);
  except
    Result := '';
  end;
end;

function _JsonStr(const AObj: TJSONObject; const AKey: string): string;
var
  LVal: TJSONValue;
begin
  Result := '';
  if AObj = nil then
    Exit;
  LVal := AObj.Values[AKey];
  if LVal is TJSONString then
    Result := TJSONString(LVal).Value;
end;

{ The manifest path for each format, relative to the bundle root. }
function _ManifestPath(const ABundleDir: string;
  const AFormat: TPluginFormat): string;
begin
  case AFormat of
    pfAefos:      Result := TPath.Combine(ABundleDir, 'addon.json');
    pfClaude:     Result := TPath.Combine(ABundleDir, TPath.Combine('.claude-plugin', 'plugin.json'));
    pfOpenPlugin: Result := TPath.Combine(ABundleDir, TPath.Combine('.plugin', 'plugin.json'));
  else
    // Agent Plugins 1.0 and Copilot share the root manifest name; they are told
    // apart by $schema, not by path.
    Result := TPath.Combine(ABundleDir, 'plugin.json');
  end;
end;

{ The MCP config, tried in the order the format prefers but accepting either
  name. Both spellings mean the same file and a bundle in the wild may carry the
  other one; refusing it would be pedantry paid for by the user. }
function _FindMcpConfig(const ABundleDir: string;
  const AFormat: TPluginFormat): string;
var
  LFirst, LSecond: string;
begin
  if AFormat = pfAgentPlugins then
  begin
    LFirst  := TPath.Combine(ABundleDir, 'mcp.json');
    LSecond := TPath.Combine(ABundleDir, '.mcp.json');
  end
  else
  begin
    LFirst  := TPath.Combine(ABundleDir, '.mcp.json');
    LSecond := TPath.Combine(ABundleDir, 'mcp.json');
  end;
  if TFile.Exists(LFirst) then
    Result := LFirst
  else if TFile.Exists(LSecond) then
    Result := LSecond
  else
    Result := '';
end;

class function TAddonPluginFormat.ManifestPathOf(const ABundleDir: string;
  const AFormat: TPluginFormat): string;
begin
  Result := _ManifestPath(ABundleDir, AFormat);
end;

class function TAddonPluginFormat.McpConfigPathOf(const ABundleDir: string;
  const AFormat: TPluginFormat): string;
begin
  Result := _FindMcpConfig(ABundleDir, AFormat);
end;

class function TAddonPluginFormat.Detect(const ABundleDir: string): TPluginFormat;
var
  LRoot, LJson: string;
  LVal: TJSONValue;
begin
  // Aefos first: an existing bundle must keep behaving exactly as before.
  if TFile.Exists(TPath.Combine(ABundleDir, 'addon.json')) then
    Exit(pfAefos);
  if TFile.Exists(TPath.Combine(ABundleDir,
       TPath.Combine('.claude-plugin', 'plugin.json'))) then
    Exit(pfClaude);
  LRoot := TPath.Combine(ABundleDir, 'plugin.json');
  if TFile.Exists(LRoot) then
  begin
    // $schema decides between the open standard and Copilot's reading of the
    // same file name. VS Code does exactly this, and defaults to Copilot.
    Result := pfCopilot;
    LJson := _ReadTextIfExists(LRoot);
    if LJson <> '' then
    begin
      LVal := TJSONObject.ParseJSONValue(LJson);
      try
        if (LVal is TJSONObject) and
           (Pos(CAgentSchema, LowerCase(_JsonStr(TJSONObject(LVal), '$schema'))) > 0) then
          Result := pfAgentPlugins;
      finally
        LVal.Free;
      end;
    end;
    Exit;
  end;
  if TFile.Exists(TPath.Combine(ABundleDir,
       TPath.Combine('.plugin', 'plugin.json'))) then
    Exit(pfOpenPlugin);
  Result := pfNone;
end;

class function TAddonPluginFormat.FormatName(
  const AFormat: TPluginFormat): string;
begin
  case AFormat of
    pfAefos:        Result := 'Aefos addon';
    pfAgentPlugins: Result := 'Agent Plugins 1.0';
    pfCopilot:      Result := 'Copilot plugin';
    pfClaude:       Result := 'Claude plugin';
    pfOpenPlugin:   Result := 'OpenPlugin (legacy)';
  else
    Result := 'unknown';
  end;
end;

{ Appends one source -> target pair. }
procedure _AddMapping(var AList: TArray<TAddonInstallMapping>;
  const ASource, ATarget: string);
var
  LLen: Integer;
begin
  LLen := Length(AList);
  SetLength(AList, LLen + 1);
  AList[LLen].Source := ASource;
  AList[LLen].TargetPath := ATarget;
end;

{ A plugin's own name for a skill/command folder, prefixed with the slug so two
  plugins shipping the same name cannot collide under ~/.aefos. }
function _Namespaced(const ASlug, AName: string): string;
begin
  Result := ASlug + '.' + AName;
end;

(* Writes the MCP fragment in the shape Aefos aggregates: a bare object of
  servers (the aggregate iterates the pairs), with the plugin-root placeholders
  already resolved to where this addon will actually live. Both spellings are
  replaced - ${CLAUDE_PLUGIN_ROOT} is what a Claude plugin writes,
  ${ADDON_ROOT} is what an Aefos addon writes, and they mean the same directory. *)
function _NormaliseMcp(const ASrcFile, ADstFile, ASlug: string): Boolean;
var
  LJson, LOut, LRootAbs: string;
  LVal, LServers: TJSONValue;
  LObj: TJSONObject;
begin
  Result := False;
  LJson := _ReadTextIfExists(ASrcFile);
  if LJson = '' then
    Exit;
  LVal := TJSONObject.ParseJSONValue(LJson);
  try
    if not (LVal is TJSONObject) then
      Exit;
    LObj := TJSONObject(LVal);
    LServers := LObj.Values['mcpServers'];
    if LServers is TJSONObject then
      LOut := TJSONObject(LServers).Format(2)
    else
      LOut := LObj.Format(2);   // already a bare server map
  finally
    LVal.Free;
  end;
  if Trim(LOut) = '' then
    Exit;
  LRootAbs := StringReplace(TAddonPaths.AddonDir(ASlug), '\', '\\', [rfReplaceAll]);
  LOut := StringReplace(LOut, '${CLAUDE_PLUGIN_ROOT}', LRootAbs, [rfReplaceAll]);
  LOut := StringReplace(LOut, '${ADDON_ROOT}', LRootAbs, [rfReplaceAll]);
  ForceDirectories(ExtractFilePath(ADstFile));
  TFile.WriteAllBytes(ADstFile, TEncoding.UTF8.GetBytes(LOut));
  Result := True;
end;

{ Reports a component the standard has and Aefos does not, so the user learns it
  at install time. Silence here is how a plugin comes to look installed while
  half of it does nothing. }
procedure _ReportUnsupported(const ABundleDir, ARelPath, AWhat: string;
  const ALog: TPluginFormatLog);
var
  LPath: string;
begin
  LPath := TPath.Combine(ABundleDir, ARelPath);
  if TDirectory.Exists(LPath) or TFile.Exists(LPath) then
    ALog(Format('  ! %s present but Aefos has no home for it yet - ignored.',
      [AWhat]));
end;

class function TAddonPluginFormat.Adopt(const ABundleDir, ASlug: string;
  const AFormat: TPluginFormat;
  const ALog: TPluginFormatLog): TAddonManifest;
var
  LManifestJson, LStage, LSkillsDir, LCommandsDir, LMcpSrc, LName: string;
  LDirs, LFiles: TStringDynArray;
  LIndex: Integer;
  LVal: TJSONValue;
  LObj: TJSONObject;
  LFound: Boolean;
begin
  Result := Default(TAddonManifest);
  Result.Slug := ASlug;
  Result.Trust := atCommunity;   // a foreign bundle is never "official" to us
  LFound := False;

  // --- metadata (best effort: the standard makes the manifest optional) -----
  LManifestJson := _ReadTextIfExists(_ManifestPath(ABundleDir, AFormat));
  if LManifestJson <> '' then
  begin
    LVal := TJSONObject.ParseJSONValue(LManifestJson);
    try
      if LVal is TJSONObject then
      begin
        LObj := TJSONObject(LVal);
        Result.Version     := _JsonStr(LObj, 'version');
        Result.Description := _JsonStr(LObj, 'description');
        Result.Name        := _JsonStr(LObj, 'displayName');
        if Result.Name = '' then
          Result.Name := _JsonStr(LObj, 'name');
      end;
    finally
      LVal.Free;
    end;
  end;
  if Result.Name = '' then
    Result.Name := ASlug;

  LStage := TPath.Combine(ABundleDir, CStageDir);

  // --- the plugin root itself ----------------------------------------------
  // Everything, because ${CLAUDE_PLUGIN_ROOT} points here and a bundled script
  // or binary is reachable only if it travelled with the manifest.
  _AddMapping(Result.Install, '.', 'addons/' + ASlug);
  ALog('  + plugin root -> addons/' + ASlug);

  // --- skills ---------------------------------------------------------------
  LSkillsDir := TPath.Combine(ABundleDir, 'skills');
  if TDirectory.Exists(LSkillsDir) then
  begin
    LDirs := TDirectory.GetDirectories(LSkillsDir);
    for LIndex := 0 to High(LDirs) do
    begin
      if not TFile.Exists(TPath.Combine(LDirs[LIndex], 'SKILL.md')) then
        Continue;
      LName := TPath.GetFileName(ExcludeTrailingPathDelimiter(LDirs[LIndex]));
      _AddMapping(Result.Install, 'skills/' + LName,
        'skills/' + _Namespaced(ASlug, LName));
      Result.Artifacts.HasSkill := True;
      LFound := True;
      ALog('  + skill    ' + _Namespaced(ASlug, LName));
    end;
  end;
  // A plugin may instead carry a single SKILL.md at its root.
  if (not Result.Artifacts.HasSkill) and
     TFile.Exists(TPath.Combine(ABundleDir, 'SKILL.md')) then
  begin
    ForceDirectories(TPath.Combine(LStage, TPath.Combine('skills', ASlug)));
    TFile.Copy(TPath.Combine(ABundleDir, 'SKILL.md'),
      TPath.Combine(LStage, TPath.Combine('skills',
        TPath.Combine(ASlug, 'SKILL.md'))), True);
    _AddMapping(Result.Install, CStageDir + '/skills/' + ASlug, 'skills/' + ASlug);
    Result.Artifacts.HasSkill := True;
    LFound := True;
    ALog('  + skill    ' + ASlug + ' (single SKILL.md at plugin root)');
  end;

  // --- commands -------------------------------------------------------------
  // The standard keeps one flat .md per command; Aefos reads one FOLDER per
  // command holding COMMAND.md, so each file is restaged into that shape. This
  // is the one thing the mapping engine cannot express, which is why the
  // staging folder exists at all.
  LCommandsDir := TPath.Combine(ABundleDir, 'commands');
  if TDirectory.Exists(LCommandsDir) then
  begin
    LFiles := TDirectory.GetFiles(LCommandsDir, '*.md');
    for LIndex := 0 to High(LFiles) do
    begin
      LName := TPath.GetFileNameWithoutExtension(LFiles[LIndex]);
      if LName = '' then
        Continue;
      ForceDirectories(TPath.Combine(LStage,
        TPath.Combine('commands', _Namespaced(ASlug, LName))));
      TFile.Copy(LFiles[LIndex],
        TPath.Combine(LStage, TPath.Combine('commands',
          TPath.Combine(_Namespaced(ASlug, LName), 'COMMAND.md'))), True);
      _AddMapping(Result.Install,
        CStageDir + '/commands/' + _Namespaced(ASlug, LName),
        'commands/' + _Namespaced(ASlug, LName));
      Result.Artifacts.HasCommand := True;
      LFound := True;
      ALog('  + command  /' + _Namespaced(ASlug, LName));
    end;
  end;

  // --- MCP servers ----------------------------------------------------------
  LMcpSrc := _FindMcpConfig(ABundleDir, AFormat);
  if LMcpSrc <> '' then
  begin
    if _NormaliseMcp(LMcpSrc, TPath.Combine(LStage,
         TPath.Combine('mcp', 'mcp.json')), ASlug) then
    begin
      // Target is the addon dir itself: the mapping engine copies a DIRECTORY,
      // and the aggregate reads addons/<slug>/mcp.json.
      _AddMapping(Result.Install, CStageDir + '/mcp', 'addons/' + ASlug);
      Result.Artifacts.HasMcp := True;
      LFound := True;
      ALog('  + mcp      ' + TPath.GetFileName(LMcpSrc) + ' -> addons/' + ASlug + '/mcp.json');
    end;
  end;

  // --- what we cannot host yet ---------------------------------------------
  _ReportUnsupported(ABundleDir, 'agents', 'agents/', ALog);
  _ReportUnsupported(ABundleDir, 'hooks', 'hooks/', ALog);
  _ReportUnsupported(ABundleDir, 'hooks.json', 'hooks.json', ALog);
  _ReportUnsupported(ABundleDir, '.lsp.json', 'LSP servers', ALog);
  _ReportUnsupported(ABundleDir, 'monitors', 'monitors/', ALog);

  if not LFound then
    raise EAddonManifest.CreateFmt(
      'bundle "%s" is a %s but carries no skill, command or MCP server that ' +
      'Aefos can install.', [ASlug, FormatName(AFormat)]);
end;

end.
