unit Aefos.OTA.Terminal.UI.ThemedForm;

(*
  ESP-077 / ADR-077-01..03 — the roadmap's TRADShellThemedForm slot.

  A thin VCL base that consolidates the per-form IDE-theme call site every
  standalone TForm dialog used to repeat in its constructor (the ADR-041-02
  consequence). Descendants inherit this base and the IDE theme is applied once
  in the base constructor via the virtual _ApplyTheme hook (default body =
  ApplyAefosTerminalIDETheme(Self)).

  Timing (BR3 / ADR-077-02):
    - DFM-streamed forms inherit unchanged: their controls already exist after
      the inherited TForm constructor streams the .dfm, so the base applies the
      theme at the same point as the old manual call.
    - Code-built forms (CreateNew, controls built in the descendant constructor
      body) bypass this base constructor; they call _ApplyTheme explicitly after
      their controls exist, or override it, so the theme is never applied before
      the controls are created.

  The theming helper itself is frozen (BR2 / ADR-077-03): this unit only
  centralizes who calls it and when. Dockable forms and TMCPConsentDialog are
  out of scope (BR4 / ADR-077-01).

  [[ide-theming-pattern]]
*)

interface

uses
  System.Classes,
  Vcl.Forms;

type
  /// <summary>
  ///   Themed base for standalone (non-dockable) Terminal dialogs. The base
  ///   constructor applies the active IDE theme once through the virtual
  ///   <see cref="_ApplyTheme"/> hook, so DFM-streamed descendants no longer
  ///   repeat the manual <c>ApplyAefosTerminalIDETheme(Self)</c> call
  ///   (ESP-077). This is the concrete realization of the roadmap's
  ///   <c>TRADShellThemedForm</c> slot (ADR-077-01 / BR7).
  /// </summary>
  TAefosTerminalThemedForm = class(TForm)
  protected
    /// <summary>
    ///   Applies the IDE theme to this form. The default body themes via the
    ///   proven <c>ApplyAefosTerminalIDETheme</c> combo. Code-built
    ///   descendants whose controls are constructed after this point override
    ///   the hook (or call it explicitly later) to preserve theme timing
    ///   (BR3 / ADR-077-02).
    /// </summary>
    procedure _ApplyTheme; virtual;
  public
    constructor Create(AOwner: TComponent); override;
  end;

implementation

uses
  Aefos.OTA.Terminal.UI.IDEThemes;

{ TAefosTerminalThemedForm }

constructor TAefosTerminalThemedForm.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  _ApplyTheme;
end;

procedure TAefosTerminalThemedForm._ApplyTheme;
begin
  ApplyAefosTerminalIDETheme(Self);
end;

end.
