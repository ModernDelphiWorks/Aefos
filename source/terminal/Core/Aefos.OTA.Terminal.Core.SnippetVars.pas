unit Aefos.OTA.Terminal.Core.SnippetVars;

(*
  Canonical {{...}} variable catalog + context assembler - ESP-060 / ADR-060-06.

  Maps typed IDE inputs (git info, project paths, shell profile, datetime) to
  the dotted-key dictionary consumed by Aefos.OTA.Terminal.Core.Mustache.TMustacheEngine.Substitute.
  VCL-free and OTA-free (BR1): the IDE layer reads live state and passes it in;
  this unit only names and assembles the keys.

  In scope this demand (six keys): git.branch, git.commit, project.dproj,
  project.root, shell.profile, datetime.iso.

  Declared but deferred (ADR-060-06): cursor.file, cursor.line. They are NOT
  added to the context, so a snippet referencing them resolves verbatim (BR3)
  until a later demand wires the editor cursor.
*)

interface

uses
  System.Generics.Collections,
  Aefos.OTA.Terminal.Core.GitInfo;

const
  /// <summary>Current git branch name; empty on detached HEAD / non-repo.</summary>
  CVarGitBranch = 'git.branch';
  /// <summary>Short commit SHA (first 7 chars); empty in a non-repo.</summary>
  CVarGitCommit = 'git.commit';
  /// <summary>Full path of the active project's .dproj.</summary>
  CVarProjectDproj = 'project.dproj';
  /// <summary>Active project root directory.</summary>
  CVarProjectRoot = 'project.root';
  /// <summary>Name of the focused terminal's shell profile.</summary>
  CVarShellProfile = 'shell.profile';
  /// <summary>Local ISO-8601 datetime supplied by the IDE layer.</summary>
  CVarDateTimeIso = 'datetime.iso';

  /// <summary>Editor file under the caret - declared, deferred (ADR-060-06).</summary>
  CVarCursorFile = 'cursor.file';
  /// <summary>Editor caret line - declared, deferred (ADR-060-06).</summary>
  CVarCursorLine = 'cursor.line';

  /// <summary>The six keys populated by TSnippetVars.Build this demand.</summary>
  CInScopeVarKeys: array[0..5] of string = (
    CVarGitBranch, CVarGitCommit, CVarProjectDproj, CVarProjectRoot,
    CVarShellProfile, CVarDateTimeIso);

type
  /// <summary>
  ///   Assembler of the canonical {{...}} variable context. Stateless: the
  ///   single member is static.
  /// </summary>
  TSnippetVars = class sealed
    /// <summary>
    ///   Builds the dotted-key dictionary for the six in-scope variables from live
    ///   IDE inputs. git.commit maps to the short SHA. cursor.* are intentionally
    ///   omitted (deferred). The caller owns the returned dictionary.
    /// </summary>
    class function Build(const AGit: TGitInfo;
      const AProjectDproj, AProjectRoot, AShellProfile,
      ADateTimeIso: string): TDictionary<string, string>; static;
  end;

implementation

class function TSnippetVars.Build(const AGit: TGitInfo;
  const AProjectDproj, AProjectRoot, AShellProfile,
  ADateTimeIso: string): TDictionary<string, string>;
begin
  Result := TDictionary<string, string>.Create;
  Result.Add(CVarGitBranch, AGit.Branch);
  Result.Add(CVarGitCommit, AGit.ShortCommit);
  Result.Add(CVarProjectDproj, AProjectDproj);
  Result.Add(CVarProjectRoot, AProjectRoot);
  Result.Add(CVarShellProfile, AShellProfile);
  Result.Add(CVarDateTimeIso, ADateTimeIso);
end;

end.


