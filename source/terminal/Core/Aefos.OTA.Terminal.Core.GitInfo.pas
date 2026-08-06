unit Aefos.OTA.Terminal.Core.GitInfo;

(*
  Pure git metadata reader for {{git.branch}} / {{git.commit}} snippet
  variables - ESP-060 / ADR-060-02.

  Given a start directory, walks up to find a ".git" directory, reads HEAD,
  and resolves the current branch + commit SHA by pure file IO:
    - "ref: refs/heads/<branch>" -> Branch = <branch>, commit read from the
      loose ref file (.git/refs/heads/<branch>) or, failing that, packed-refs.
    - a bare SHA in HEAD (detached HEAD) -> Branch = '', commit = the SHA.
    - no ".git" found -> IsRepo = False, all fields empty.

  NEVER spawns git.exe (BR2): process spawn + pipe read can block the IDE main
  thread and is not deterministically testable headless. VCL-free and OTA-free
  (BR1): the IDE layer supplies the start directory.

  Known limitation (ADR-060-02): a ".git" *file* (worktree / submodule gitdir
  pointer) is treated as a non-repo - IsRepo = False is the safe fallback.
*)

interface

type
  /// <summary>
  ///   Snapshot of the current git branch + commit, or IsRepo = False when no
  ///   readable repository was found walking up from the start directory.
  /// </summary>
  TGitInfo = record
    IsRepo: Boolean;
    Branch: string;
    ShortCommit: string;
    FullCommit: string;

    /// <summary>
    ///   Walks up from AStartDir to the first ".git" directory and reads the
    ///   current branch + commit. Returns a record with IsRepo = False (all other
    ///   fields empty) when no repository is found or AStartDir is empty.
    /// </summary>
    class function ReadFrom(const AStartDir: string): TGitInfo; static;
  end;

implementation

uses
  System.SysUtils, System.Types, System.IOUtils;   // Types: TStringDynArray

const
  CHeadRefPrefix = 'ref:';
  CBranchPrefix = 'refs/heads/';

/// <summary>
///   Finds the nearest ".git" directory walking up from AStartDir. Returns its
///   full path, or '' when none is found. A ".git" *file* (gitdir pointer)
///   stops the walk and yields '' (ADR-060-02).
/// </summary>
function _FindGitDir(const AStartDir: string): string;
var
  LDir: string;
  LParent: string;
  LCandidate: string;
begin
  Result := '';
  if AStartDir.Trim = '' then
    Exit;
  if not TDirectory.Exists(AStartDir) then
    Exit;

  LDir := ExcludeTrailingPathDelimiter(TPath.GetFullPath(AStartDir));
  while LDir <> '' do
  begin
    LCandidate := TPath.Combine(LDir, '.git');
    if TDirectory.Exists(LCandidate) then
      Exit(LCandidate);
    if TFile.Exists(LCandidate) then
      Exit(''); // worktree/submodule pointer - documented non-repo fallback

    LParent := TPath.GetDirectoryName(LDir);
    if (LParent = '') or SameText(LParent, LDir) then
      Break;
    LDir := LParent;
  end;
end;

/// <summary>
///   Reads the trimmed contents of a file, returning '' when it is absent or
///   cannot be read. Never raises - a missing/locked ref is non-fatal.
/// </summary>
function _ReadTrimmed(const APath: string): string;
begin
  Result := '';
  if not TFile.Exists(APath) then
    Exit;
  try
    Result := TFile.ReadAllText(APath).Trim;
  except
    Result := '';
  end;
end;

/// <summary>
///   Resolves a ref name (e.g. refs/heads/main) to its commit SHA, first via
///   the loose ref file under AGitDir, then via packed-refs. Returns '' when
///   the ref cannot be resolved.
/// </summary>
function _ResolveRef(const AGitDir, ARef: string): string;
var
  LLoosePath: string;
  LPackedPath: string;
  LLines: TStringDynArray;
  LLine: string;
  LTrimmed: string;
  LParts: TArray<string>;
begin
  Result := '';

  LLoosePath := TPath.Combine(AGitDir, ARef.Replace('/', PathDelim));
  Result := _ReadTrimmed(LLoosePath);
  if Result <> '' then
    Exit;

  LPackedPath := TPath.Combine(AGitDir, 'packed-refs');
  if not TFile.Exists(LPackedPath) then
    Exit;
  try
    LLines := TFile.ReadAllLines(LPackedPath);
  except
    Exit;
  end;

  for LLine in LLines do
  begin
    LTrimmed := LLine.Trim;
    if (LTrimmed = '') or LTrimmed.StartsWith('#') or LTrimmed.StartsWith('^') then
      Continue;
    LParts := LTrimmed.Split([' '], TStringSplitOptions.ExcludeEmpty);
    if (Length(LParts) >= 2) and (LParts[1] = ARef) then
      Exit(LParts[0]);
  end;
end;

procedure _SetCommit(var AInfo: TGitInfo; const AFullCommit: string);
begin
  AInfo.FullCommit := AFullCommit;
  if Length(AFullCommit) >= 7 then
    AInfo.ShortCommit := Copy(AFullCommit, 1, 7)
  else
    AInfo.ShortCommit := AFullCommit;
end;

class function TGitInfo.ReadFrom(const AStartDir: string): TGitInfo;
var
  LGitDir: string;
  LHead: string;
  LRef: string;
begin
  Result := Default(TGitInfo);

  LGitDir := _FindGitDir(AStartDir);
  if LGitDir = '' then
    Exit;

  // A ".git" directory was found: this is a repository.
  Result.IsRepo := True;

  LHead := _ReadTrimmed(TPath.Combine(LGitDir, 'HEAD'));
  if LHead = '' then
    Exit;

  if LHead.StartsWith(CHeadRefPrefix) then
  begin
    LRef := Copy(LHead, Length(CHeadRefPrefix) + 1, MaxInt).Trim;
    if LRef.StartsWith(CBranchPrefix) then
      Result.Branch := Copy(LRef, Length(CBranchPrefix) + 1, MaxInt);
    _SetCommit(Result, _ResolveRef(LGitDir, LRef));
  end
  else
    // Detached HEAD: the file holds the commit SHA directly.
    _SetCommit(Result, LHead);
end;

end.


