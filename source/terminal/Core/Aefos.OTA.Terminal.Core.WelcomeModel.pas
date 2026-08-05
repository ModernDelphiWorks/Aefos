unit Aefos.OTA.Terminal.Core.WelcomeModel;

{
  Pure helpers for the V.1 welcome / "new tab" landing pane (ESP-058 /
  ADR-058-02).

  This unit is the headless-testable portion of the welcome surface. It holds
  no VCL paint and no StyleServices dependency: it only turns the configured
  shell profiles into card view-models, decides whether the welcome pane should
  be shown, and builds the greeting string. The pane itself
  (Aefos.OTA.Terminal.UI.WelcomePane) consumes these helpers to lay out the cards.

  Colors come exclusively from Aefos.OTA.Terminal.Core.VisualTokens (BR2). See
  [[mobaxterm-ux-reference]].
}

interface

uses
  Vcl.Graphics,
  System.Generics.Collections,
  Aefos.OTA.Terminal.Core.Profiles;

type
  /// <summary>
  ///   View-model for a single profile launch card on the welcome pane.
  ///   Derived purely from a <see cref="TShellProfile"/> entry, so it carries
  ///   no VCL controls and is fully headless-testable (AC8).
  /// </summary>
  TWelcomeCard = record
    /// <summary>Index into <c>TProfileManager.Profiles</c>; used by the pane
    /// to launch the matching profile via the existing terminal path.</summary>
    ProfileIndex: Integer;
    /// <summary>Display name of the profile (e.g. <c>cmd</c>, <c>pwsh</c>).</summary>
    ProfileName: string;
    /// <summary>Dot color resolved through
    /// <see cref="TVisualTokens.ProfileDotColor"/> (BR2/BR3).</summary>
    DotColor: TColor;
    /// <summary>Compact one-line shell summary (executable + arguments).</summary>
    ShellSummary: string;
  end;

  /// <summary>
  ///   Pure builder/predicate helpers for the welcome pane. No VCL paint, no
  ///   <c>StyleServices</c> (AC1).
  /// </summary>
  TWelcomeModel = class
  public
    /// <summary>
    ///   Builds one <see cref="TWelcomeCard"/> per entry in <c>AProfiles</c>,
    ///   in order (BR3 — dynamic over the live profile list). Returns an empty
    ///   array when <c>AProfiles</c> is nil or empty.
    /// </summary>
    class function BuildCards(const AProfiles: TObjectList<TShellProfile>): TArray<TWelcomeCard>; static;

    /// <summary>
    ///   Compact shell-summary line for a card: the executable file name plus
    ///   the arguments when present (A3). Never empty for a non-empty
    ///   executable.
    /// </summary>
    class function ShellSummary(const AExecutable, AArguments: string): string; static;

    /// <summary>
    ///   Welcome-visibility predicate (A1): a new tab shows the welcome pane
    ///   only when it has no pre-selected profile.
    /// </summary>
    class function ShouldShowWelcome(const AHasPreselectedProfile: Boolean): Boolean; static;

    /// <summary>The greeting header shown at the top of the welcome pane.</summary>
    class function Greeting: string; static;
  end;

implementation

uses
  System.SysUtils,
  Aefos.OTA.Terminal.Core.VisualTokens;

{ TWelcomeModel }

class function TWelcomeModel.BuildCards(
  const AProfiles: TObjectList<TShellProfile>): TArray<TWelcomeCard>;
var
  LIndex: Integer;
  LProfile: TShellProfile;
begin
  if not Assigned(AProfiles) then
    Exit(nil);

  SetLength(Result, AProfiles.Count); // NOSONAR — Win32 target: Count (Integer) == NativeInt; no truncation
  for LIndex := 0 to AProfiles.Count - 1 do
  begin
    LProfile := AProfiles[LIndex];
    Result[LIndex].ProfileIndex := LIndex;
    Result[LIndex].ProfileName := LProfile.Name;
    Result[LIndex].DotColor := TVisualTokens.ProfileDotColor(LProfile.Name);
    Result[LIndex].ShellSummary := ShellSummary(LProfile.Executable, LProfile.Arguments);
  end;
end;

class function TWelcomeModel.ShellSummary(const AExecutable, AArguments: string): string;
begin
  Result := ExtractFileName(AExecutable);
  if Result = '' then
    Result := AExecutable;
  if AArguments.Trim <> '' then
    Result := Result + ' ' + AArguments.Trim;
end;

class function TWelcomeModel.ShouldShowWelcome(const AHasPreselectedProfile: Boolean): Boolean;
begin
  Result := not AHasPreselectedProfile;
end;

class function TWelcomeModel.Greeting: string;
begin
  Result := 'Welcome to Aefos.OTA.Terminal';
end;

end.


