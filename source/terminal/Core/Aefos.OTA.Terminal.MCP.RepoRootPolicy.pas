unit Aefos.OTA.Terminal.MCP.RepoRootPolicy;

{
  Pure repo-root ascent seam (ESP-095, S1 / ADR-095-02 / BR3).

  Pure RTL — no ToolsAPI, no filesystem IO. AscendToRepoRoot walks from a start
  directory up through its parents and returns the nearest ancestor that carries
  a ".git" marker, so Core's read-only Git facade can anchor at the enclosing
  work tree instead of the active project sub-directory. #7: GetFileDiff returned
  "outside-repo" for files inside the repo but outside the project dir, because
  the host injected _RepoRoot = GetProjectPath verbatim with no ascent to the
  enclosing .git (the RADShell monorepo layout — a package dir inside a source
  tree; ESP-085).

  The marker probe is INJECTED (a TPredicate<string>), so the walk logic is
  headless-testable with no real filesystem; the host owns the impure ".git"
  probe at its boundary (DirectoryExists OR FileExists of <dir>\.git — a normal
  clone stores .git as a directory, a worktree/submodule gitlink stores it as a
  file, R1). The seam is agnostic to which one it is.

  Layout-agnostic degrade: when no ancestor carries the marker (the start dir is
  not inside any repo), AscendToRepoRoot returns the start dir unchanged,
  preserving today's honest not-a-repo behaviour (R2). It operates on the string
  path as given — no canonicalization of symlinks / junctions / UNC (R3); the
  walk terminates at the filesystem / UNC root.
}

interface

uses
  System.SysUtils;

// Ascend from AStartDir through its parent directories and return the nearest
// directory (AStartDir included) for which AHasGitMarker(dir) is True — the
// enclosing repo root. Returns AStartDir unchanged when no ancestor carries the
// marker, or when AStartDir is blank. Pure: the marker probe is injected, no IO
// happens inside. A trailing path separator on AStartDir is tolerated (stripped
// before probing, so the predicate always sees a separator-free directory).
function AscendToRepoRoot(const AStartDir: string;
  const AHasGitMarker: TPredicate<string>): string;

implementation

function AscendToRepoRoot(const AStartDir: string;
  const AHasGitMarker: TPredicate<string>): string;
var
  LDir, LParent: string;
begin
  Result := AStartDir;
  if AStartDir = '' then
    Exit;
  LDir := ExcludeTrailingPathDelimiter(AStartDir);
  while LDir <> '' do
  begin
    if AHasGitMarker(LDir) then
      Exit(LDir);
    LParent := ExtractFileDir(LDir);
    // ExtractFileDir returns the input unchanged at the filesystem / UNC root —
    // that fixed point is the walk's termination guard (no marker found).
    if (LParent = '') or SameText(LParent, LDir) then
      Break;
    LDir := LParent;
  end;
end;

end.
