unit Aefos.OTA.Terminal.Core.SnippetEditModel;

(*
  Pure editor logic for the V.6 snippet editor - ESP-064 / ADR-064-01..03.

  VCL-free and OTA-free (BR1): the editor form (Aefos.OTA.Terminal.UI.SnippetEditDialog) owns
  only rendering and event wiring; every testable decision lives here and is
  covered by Aefos.OTA.Terminal.Core.TestSnippetEditModel (BR2).

  Reuses the existing variable machinery instead of forking a second grammar
  (BR3): chips are classified against Aefos.OTA.Terminal.Core.SnippetVars.CInScopeVarKeys and
  scanned by Aefos.OTA.Terminal.Core.Mustache.TMustacheEngine.ScanVars; the live preview the form draws
  feeds TSnippetEditModel.BuildPreviewContext into Aefos.OTA.Terminal.Core.Mustache.TMustacheEngine.Substitute - the
  same resolver the sidebar run/copy path uses.

  cursor.file / cursor.line stay deferred (ADR-060-06): they are classified as
  svkDeferred and are never added to the preview context, so they resolve
  verbatim.
*)

interface

uses
  System.Generics.Collections;

type
  /// <summary>
  ///   Classification of a {{...}} variable a snippet body references:
  ///   svkKnown (in the live catalog), svkDeferred (declared but not yet wired -
  ///   cursor.*), svkUnknown (not recognized - likely a typo).
  /// </summary>
  TSnippetVarKind = (svkKnown, svkDeferred, svkUnknown);

  /// <summary>A variable chip: the dotted name plus its classification.</summary>
  TSnippetChip = record
    Name: string;
    Kind: TSnippetVarKind;
  end;

  /// <summary>
  ///   Pure editor logic for the snippet editor. Stateless: all members are
  ///   static.
  /// </summary>
  TSnippetEditModel = class sealed
    /// <summary>
    ///   Classifies a dotted variable name. svkKnown when AName is one of the six
    ///   in-scope keys (CInScopeVarKeys); svkDeferred for cursor.file / cursor.line;
    ///   svkUnknown otherwise. Case-sensitive, matching the Mustache grammar.
    /// </summary>
    class function ClassifyVar(const AName: string): TSnippetVarKind; static;

    /// <summary>
    ///   Scans ABody for {{...}} variables and returns one chip per distinct name,
    ///   in first-occurrence order (delegates dedup/order/grammar to
    ///   TMustacheEngine.ScanVars), each tagged with its kind.
    /// </summary>
    class function BuildChips(const ABody: string): TArray<TSnippetChip>; static;

    /// <summary>
    ///   Parses the tags input field: split on comma, trim each segment, drop
    ///   empties, dedup case-insensitively, preserve first-occurrence order (the
    ///   original casing of the first occurrence is kept).
    /// </summary>
    class function ParseTags(const AText: string): TArray<string>; static;

    /// <summary>Joins tags with ', ' for display in the tags input field.</summary>
    class function FormatTags(const ATags: TArray<string>): string; static;

    /// <summary>
    ///   Validates a draft. Returns '' when both Title and Command are non-blank
    ///   (after trim); otherwise a human-readable message naming the first missing
    ///   field ('Title is required' / 'Command is required').
    /// </summary>
    class function ValidateDraft(const ATitle, ACommand: string): string; static;

    /// <summary>
    ///   Builds the dictionary the preview renders against. For each in-scope key:
    ///   uses ALive[key] when present and non-empty, else a labeled placeholder
    ///   «key» so the preview stays legible with no project / terminal. cursor.* are
    ///   not added (stay verbatim, ADR-060-06). ALive may be nil (all placeholders).
    ///   The caller owns the returned dictionary.
    /// </summary>
    class function BuildPreviewContext(
      const ALive: TDictionary<string, string>): TDictionary<string, string>; static;
  end;

implementation

uses
  System.SysUtils,
  Aefos.OTA.Terminal.Core.Mustache,
  Aefos.OTA.Terminal.Core.SnippetVars;

class function TSnippetEditModel.ClassifyVar(const AName: string): TSnippetVarKind;
var
  LKey: string;
begin
  for LKey in CInScopeVarKeys do
    if AName = LKey then
      Exit(svkKnown);
  if (AName = CVarCursorFile) or (AName = CVarCursorLine) then
    Exit(svkDeferred);
  Result := svkUnknown;
end;

class function TSnippetEditModel.BuildChips(const ABody: string): TArray<TSnippetChip>;
var
  LNames: TArray<string>;
  LIndex: Integer;
begin
  LNames := TMustacheEngine.ScanVars(ABody);
  SetLength(Result, Length(LNames));
  for LIndex := 0 to High(LNames) do
  begin
    Result[LIndex].Name := LNames[LIndex];
    Result[LIndex].Kind := ClassifyVar(LNames[LIndex]);
  end;
end;

class function TSnippetEditModel.ParseTags(const AText: string): TArray<string>;
var
  LParts: TArray<string>;
  LPart: string;
  LTrimmed: string;
  LSeen: TDictionary<string, Boolean>;
  LResult: TList<string>;
begin
  LSeen := TDictionary<string, Boolean>.Create;
  LResult := TList<string>.Create;
  try
    LParts := AText.Split([',']);
    for LPart in LParts do
    begin
      LTrimmed := LPart.Trim;
      if LTrimmed = '' then
        Continue;
      if LSeen.ContainsKey(LTrimmed.ToLower) then
        Continue;
      LSeen.Add(LTrimmed.ToLower, True);
      LResult.Add(LTrimmed);
    end;
    Result := LResult.ToArray;
  finally
    LResult.Free;
    LSeen.Free;
  end;
end;

class function TSnippetEditModel.FormatTags(const ATags: TArray<string>): string;
begin
  Result := string.Join(', ', ATags);
end;

class function TSnippetEditModel.ValidateDraft(const ATitle, ACommand: string): string;
begin
  if ATitle.Trim = '' then
    Exit('Title is required');
  if ACommand.Trim = '' then
    Exit('Command is required');
  Result := '';
end;

class function TSnippetEditModel.BuildPreviewContext(
  const ALive: TDictionary<string, string>): TDictionary<string, string>;
var
  LKey: string;
  LValue: string;
begin
  Result := TDictionary<string, string>.Create;
  for LKey in CInScopeVarKeys do
  begin
    if Assigned(ALive) and ALive.TryGetValue(LKey, LValue) and (LValue <> '') then
      Result.Add(LKey, LValue)
    else
      Result.Add(LKey, '«' + LKey + '»');
  end;
end;

end.


