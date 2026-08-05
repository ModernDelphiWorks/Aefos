unit Aefos.Addons.McpRewrite;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

//  Aefos Addons - MCP server.json path token rewrite.
//
//  An addon's mcp\server.json cannot ship an absolute install path (it does not
//  know where the user's ~/.aefos lives) and it MUST NOT ship a shell/env token
//  like %USERPROFILE%: an MCP client (Claude/Codex) spawns the server command
//  RAW - no shell, no environment expansion - so %USERPROFILE%\... is passed
//  verbatim and the process fails to launch.
//
//  The contract: an addon that needs its own install directory writes the
//  explicit, OS-neutral ADDON_ROOT_TOKEN (= ~/.aefos\addons\<slug>). When the
//  CLI lays the addon down it substitutes that token with the ABSOLUTE, resolved
//  install directory - so both the per-addon mcp.json and the aggregate
//  mcp-servers.json carry a path a raw spawn can execute.
//
//  Pure: no disk, no HTTP, no env. A fragment WITHOUT the token is returned
//  byte-for-byte unchanged, so the existing "command":"npx" addons are untouched.

interface

const
  // The token an addon's server.json uses to reference its own install root
  // (~/.aefos\addons\<slug>). Explicit and OS-neutral - not a shell %VAR%.
  ADDON_ROOT_TOKEN = '${ADDON_ROOT}';

type
  { Static, sealed namespace for the ADDON_ROOT token rewrite. Never
    instantiated; the class IS the namespace. }
  TAddonMcpRewrite = class sealed
  public
    // Replaces every ADDON_ROOT_TOKEN occurrence in an MCP server.json fragment
    // with AAddonRootAbs (the addon's absolute install directory), JSON-escaping
    // the path so the result stays valid JSON (backslashes doubled, quotes
    // escaped). A trailing path delimiter on AAddonRootAbs is dropped first, so a
    // "...\tools\x" reference yields "<root>\tools\x" with exactly one separator.
    // A fragment that does not contain the token is returned unchanged
    // (byte-for-byte). Pure.
    class function RewriteRootToken(
      const AJson, AAddonRootAbs: string): string; static;
  end;

implementation

uses
  SysUtils;

// JSON-escapes a filesystem path for embedding inside a JSON string literal:
// backslash -> \\ and double-quote -> \". Control chars are not expected in a
// path and are left as-is.
function _JsonEscapePath(const APath: string): string;
begin
  Result := StringReplace(APath, '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '\"', [rfReplaceAll]);
end;

class function TAddonMcpRewrite.RewriteRootToken(
  const AJson, AAddonRootAbs: string): string;
var
  LRoot: string;
begin
  // No token => nothing to do; return the input untouched (npx-style addons).
  if (AJson = '') or (Pos(ADDON_ROOT_TOKEN, AJson) = 0) then
    Exit(AJson);
  LRoot := ExcludeTrailingPathDelimiter(AAddonRootAbs);
  Result := StringReplace(AJson, ADDON_ROOT_TOKEN,
    _JsonEscapePath(LRoot), [rfReplaceAll]);
end;

end.
