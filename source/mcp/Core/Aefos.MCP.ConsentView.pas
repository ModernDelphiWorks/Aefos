unit Aefos.MCP.ConsentView;

{$IFDEF FPC}{$mode delphiunicode}{$H+}{$ENDIF}

{
  ONE model for every permission surface.

  Aefos asks for permission in four places -- the chat's HTML card, a VCL modal
  when the panel is not available, the Lazarus twin of that modal, and a raw
  Win32 popup for acting on other applications. Four surfaces is defensible: they
  are drawn in different media and one of them must not be automatable at all.

  Four MODELS was not. Each one had invented its own wording and its own layout,
  and the duplication was not even hidden -- Aefos.OTA.UI.MCPConsentDialog opens
  with "Mirrors Aefos.OTA.Chat.UI.MCPConsentDialog", a copy declared in a comment.
  The owner, looking at three of them side by side: "ate pode criar um form para
  cada um mas o MODELO igual poxa, padrao".

  So the model lives HERE, once, and each surface only RENDERS it:

      heading   the question, in the user's terms
      summary   the consequence
      target    WHAT is being acted on -- the field a human checks before saying yes
      note      the thing that cannot be deduced from looking (may be empty)
      actions   the captions of the choices

  A surface that needs a different layout is fine. A surface that invents
  different WORDS is how two windows stop looking like one product.

  Purity: RTL only. No VCL, no LCL, no ToolsAPI, no OTA -- the Lazarus edition
  compiles this same unit, so the two editions cannot drift by construction.
  ASCII only: no BOM needed.
}

interface

uses
  {$IFDEF FPC}
  SysUtils;
  {$ELSE}
  System.SysUtils;
  {$ENDIF}

type
  { Field for field, this IS the chat card. The owner named that card the
    reference ("e a tela mais bonita, nao mexa nela"), so the model carries its
    words -- not an approximation of them. Anything a surface shows that is not
    here is a surface inventing something.

    The card's own markup is the source: Aefos.OTA.Chat.UI.OutputPanel.Assets,
    the #ds-perm-modal block. }
  TAefosConsentView = record
    Heading: string;       // .ds-perm-title
    Summary: string;       // .ds-perm-sub
    ToolChip: string;      // .ds-perm-tool -- the tool name, monospaced
    ToolChipHint: string;  // the label beside the chip
    What: string;          // .ds-perm-what
    DetailLabel: string;   // .ds-perm-detlabel
    FootHint: string;      // .ds-perm-hint in the footer
    Note: string;          // desktop-only: the physical-key sentence
    { Button ORDER is part of the standard, not a detail. The card lays them out
      Deny -> Allow for this session -> Allow once, right-aligned, with Allow
      once carrying the primary style and Deny the safe-default focus ring. The
      VCL form used the opposite order, which is enough on its own to make two
      windows feel like two products. }
    Deny: string;
    AllowSession: string;
    AllowOnce: string;
  end;

  TAefosConsentModel = class sealed
  public
    { An IDE tool asking to run. ADetail is the content preview the surface may
      also show; it is NOT part of the model because only some surfaces have room
      for it -- the model is what they must all say the same way. }
    class function ForTool(const AToolName,
      ASummary: string): TAefosConsentView; static;
    { Acting on ANOTHER application: closing it, ending its process. Carries the
      note, because "only a physical keypress counts" is exactly the fact a user
      cannot deduce by looking at the window. }
    class function ForDesktopAction(const AActionVerb,
      ATarget: string): TAefosConsentView; static;
    { WHERE the card is drawn: inside the chat panel, or in a window of its own.

      The rule is not "is there a panel object" -- that was the bug. The global
      holding the panel is set the first time one is created and never goes back
      to nil, so a user who CLOSED the chat still had a panel as far as this
      decision was concerned. The card then rendered into a hidden window and
      reported success: the request was never seen, and five minutes later the
      timeout denied it on the user's behalf.

      A surface nobody can see is not a surface. So the question is whether the
      panel is ON SCREEN; anything else routes to the standalone window, which
      is what it was built for. }
    class function RoutesToOwnWindow(const APanelExists,
      APanelOnScreen: Boolean): Boolean; static;
  end;

implementation

class function TAefosConsentModel.ForTool(const AToolName,
  ASummary: string): TAefosConsentView;
begin
  // Verbatim from the card. Do not "improve" these strings here -- the point of
  // the model is that three surfaces say the same thing.
  Result.Heading := 'Permission required';
  Result.Summary := 'The AI wants to run an action that changes project files. '
    + 'You decide whether it can.';
  Result.ToolChip := AToolName;
  Result.ToolChipHint := 'Aefos MCP tool';
  Result.What := ASummary;
  Result.DetailLabel := 'PREVIEW';
  Result.FootHint := 'Safe default: Deny.';
  Result.Note := '';
  Result.Deny := 'Deny';
  Result.AllowSession := 'Allow for this session';
  Result.AllowOnce := 'Allow once';
end;

class function TAefosConsentModel.ForDesktopAction(const AActionVerb,
  ATarget: string): TAefosConsentView;
begin
  // Same shape as the tool prompt, different subject: this one is not about a
  // project file, it is about another running application.
  Result.Heading := 'Permission required';
  Result.Summary := 'The AI wants to act on another application on your '
    + 'desktop. You decide whether it can.';
  Result.ToolChip := AActionVerb;
  Result.ToolChipHint := 'Aefos desktop action';
  Result.What := ATarget;
  Result.DetailLabel := '';
  Result.FootHint := 'Safe default: Deny.';
  Result.Note :=
    'Only a PHYSICAL keypress or click is accepted - no tool can answer this.';
  // Same captions and same ORDER as the card. This window is painted by hand, so
  // its "buttons" are pixels, not controls -- UI Automation cannot see them and
  // our own desktop_invoke has nothing to press. It can therefore LOOK exactly
  // like the others without becoming answerable by the agent it is gating.
  Result.Deny := 'Deny';
  Result.AllowSession := '';
  Result.AllowOnce := 'Allow once';
end;

class function TAefosConsentModel.RoutesToOwnWindow(const APanelExists,
  APanelOnScreen: Boolean): Boolean;
begin
  // Deliberately NOT "not APanelExists". Existing and being on screen are two
  // different facts and only the second one is about the user.
  Result := not (APanelExists and APanelOnScreen);
end;

end.
