unit Aefos.OTA.Terminal.Core.ContextStrip;

(*
  Pure RTL context model for the AI-CLI context strip - ESP-076 / ADR-076-02.

  Single source of truth for the two strings the strip needs, both now methods
  of TIDEContextSnapshot:
    - Caption     : the compact one-line caption painted on the strip
                    (project, unit basename, cursor L:C, selection length).
    - InjectLine  : the exact text written into the running CLI prompt on
                    a one-shot inject (ADR-076-03).
  Plus ChangedFrom, the debounce predicate the focus-gated refresh timer uses
  to repaint only on a real field delta (BR5).

  TIDEContextSnapshot carries the raw situational data. An empty ProjectName /
  UnitPath is the "not available" convention - a fully blank snapshot is the
  safe-degrade value the OTA provider returns when nothing is open (BR5), and it
  renders as a friendly "no IDE context" caption rather than a confusing partial.

  This unit is pure RTL (System.SysUtils only): no VCL, no ToolsAPI, no MCP.Types
  (BR3). OTA context is reached only through the injected IIDEContextProvider,
  whose OTA-backed implementation lives in the UI layer.
*)

interface

type
  /// <summary>
  ///   Raw IDE situational context for one strip refresh. Empty
  ///   <c>ProjectName</c> / <c>UnitPath</c> means "not available"; a fully blank
  ///   record is the safe-degrade snapshot (no project / unit open).
  /// </summary>
  TIDEContextSnapshot = record
    /// <summary>Active project display name, or '' when no project is open.</summary>
    ProjectName: string;
    /// <summary>Active editor file path (full path), or '' when no unit is open.
    /// The caption basenames it; the full path drives change detection.</summary>
    UnitPath: string;
    /// <summary>Caret line (1-based). Meaningful only when <c>UnitPath</c> is set.</summary>
    Line: Integer;
    /// <summary>Caret column (1-based). Meaningful only when <c>UnitPath</c> is set.</summary>
    Col: Integer;
    /// <summary>Length, in characters, of the current selection (0 when none).</summary>
    SelLength: Integer;
    /// <summary>The safe-degrade blank snapshot (no project / unit open).</summary>
    class function Empty: TIDEContextSnapshot; static;
    /// <summary>Compact one-line caption for the strip.</summary>
    function Caption: string;
    /// <summary>True when any field of Self differs from AOld (refresh debounce, BR5).</summary>
    function ChangedFrom(const AOld: TIDEContextSnapshot): Boolean;
    /// <summary>The exact text injected into the CLI prompt.</summary>
    function InjectLine: string;
  end;

  /// <summary>
  ///   Seam that feeds a live <see cref="TIDEContextSnapshot"/> to the strip.
  ///   The OTA-backed implementation lives in the UI layer; a stub drives
  ///   headless tests. Implementations must never raise - they safe-degrade to
  ///   a blank snapshot (BR5).
  /// </summary>
  IIDEContextProvider = interface
    ['{6F2C9A14-7B3E-4D58-9C21-0A6E5B7D4F83}']
    /// <summary>Current IDE context, or a blank snapshot when nothing is open.</summary>
    function GetSnapshot: TIDEContextSnapshot;
  end;

implementation

uses
  System.SysUtils;

const
  /// <summary>Separator between caption segments (middle dot via escape so a
  /// non-BOM source never mojibakes it to 'Â·').</summary>
  CCaptionSep = ' ' + #$00B7 + ' ';
  /// <summary>Caption shown when no project and no unit are open.</summary>
  CNoContextCaption = 'no IDE context';
  /// <summary>Max rendered caption width; longer captions are ellipsized.</summary>
  CMaxCaptionLen = 100;
  /// <summary>Ellipsis appended to a truncated caption.</summary>
  CEllipsis = '…';
  /// <summary>Prefix of the injected context line.</summary>
  CInjectPrefix = 'Context: ';
  /// <summary>Injected line when no context is available.</summary>
  CInjectNoContext = CInjectPrefix + 'no active IDE context. ';

/// <summary>True when neither a project nor a unit is available.</summary>
function _IsBlank(const ASnapshot: TIDEContextSnapshot): Boolean;
begin
  Result := (ASnapshot.ProjectName = '') and (ASnapshot.UnitPath = '');
end;

/// <summary>Truncates <c>AText</c> to <c>AMaxLen</c>, appending an ellipsis.</summary>
function _Truncate(const AText: string; const AMaxLen: Integer): string;
begin
  if Length(AText) <= AMaxLen then
    Result := AText
  else
    Result := Copy(AText, 1, AMaxLen - Length(CEllipsis)) + CEllipsis;
end;

class function TIDEContextSnapshot.Empty: TIDEContextSnapshot;
begin
  Result := Default(TIDEContextSnapshot);
end;

function TIDEContextSnapshot.Caption: string;
var
  LParts: TArray<string>;
begin
  if _IsBlank(Self) then
    Exit(CNoContextCaption);

  LParts := [];
  if ProjectName <> '' then
    LParts := LParts + [ProjectName];
  if UnitPath <> '' then
    LParts := LParts + [ExtractFileName(UnitPath),
                        Format('L%d:%d', [Line, Col])];
  LParts := LParts + [Format('sel %d', [SelLength])];

  Result := _Truncate(string.Join(CCaptionSep, LParts), CMaxCaptionLen);
end;

function TIDEContextSnapshot.ChangedFrom(const AOld: TIDEContextSnapshot): Boolean;
begin
  Result := (AOld.ProjectName <> ProjectName) or
            (AOld.UnitPath <> UnitPath) or
            (AOld.Line <> Line) or
            (AOld.Col <> Col) or
            (AOld.SelLength <> SelLength);
end;

function TIDEContextSnapshot.InjectLine: string;
var
  LParts: TArray<string>;
begin
  if _IsBlank(Self) then
    Exit(CInjectNoContext);

  LParts := [];
  if ProjectName <> '' then
    LParts := LParts + [Format('project %s', [ProjectName])];
  if UnitPath <> '' then
    LParts := LParts + [Format('unit %s', [ExtractFileName(UnitPath)]),
                        Format('line %d', [Line]),
                        Format('col %d', [Col])];
  LParts := LParts + [Format('selection %d chars', [SelLength])];

  Result := CInjectPrefix + string.Join(', ', LParts) + '. ';
end;

end.
