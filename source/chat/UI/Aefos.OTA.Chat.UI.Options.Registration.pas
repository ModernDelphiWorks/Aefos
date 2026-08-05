unit Aefos.OTA.Chat.UI.Options.Registration;

{
  OTA Tools->Options registration for the Aefos node
  (ESP-002, Epic 4/4, Demand 1/1, ADR-208/210/211).

  Registers one INTAAddInOptions per page (Chat / MCP), both sharing
  GetArea='Aefos' so the IDE groups them under a single Aefos tree
  node. Each returns a TFrame class and drives its lifecycle through the
  ToolsAPI-free TOptionsConfigBinding seam (load on FrameCreated, validate on
  ValidateContents, persist-on-accept in DialogClosed — RN-004).

  The Terminal page is NOT registered here. The external Terminal add-in
  (Aefos.OTA.Terminal) owns and registers its own 'Terminal' page under
  the same GetArea='Aefos' node (RN-005 / ADR-210 contribution seam). The
  empty placeholder this unit used to register was removed 2026-06-07: it added
  no value and, because the Options dialog keys frames by caption, a second
  page captioned 'Terminal' collided with the Terminal add-in's real page.

  S-1 spike findings (recorded for AC-01, Delphi 13 / RAD Studio 37.0):
    - INTAAddInOptions.GetArea returning a non-empty 'Aefos' yields a
      dedicated tree node under which every page sharing that area is grouped
      (ToolsAPI.pas doc: a page appears under the node named by GetArea). This
      is the parent->children shape the maintainer asked for (the same shape the
      IDE's built-in AI assistant node uses); the exact top-level placement is
      maintainer-verified at AC-12.
    - Deep-link IS achievable on Delphi 13: IOTAEnvironmentOptions140.EditOptions
      (const Area, PageCaption) is a stable public API. OpenAefosOptions
      focuses the Aefos area/page directly; on any failure it falls back
      to opening the dialog top-level (ADR-211).

  Lifecycle (RN-007): RegisterAefosOptions on plugin init,
  UnregisterAefosOptions on unload — load/unload twice leaves no orphan
  nodes (the option objects are released when the global array is cleared).

  This unit links ToolsAPI and therefore lives only in the designtime plugin
  BPL (C-2 / ADR-115). The frames and the binding it drives stay ToolsAPI-free.
}

interface

uses
  System.SysUtils,
  Aefos.OTA.Chat.Core.Config.Types;

// Registers the Chat/MCP pages under the Aefos node. Idempotent.
// AConfig + ARootResolver are injected into each page's binding (the same root
// resolver Register feeds TConfigService). AOnConfigSaved is fired once after a
// page persists on accept (lets the composition root re-resolve the executor
// graph). Safe to call again to refresh the injected dependencies.
procedure RegisterAefosOptions(const AConfig: IConfig;
  const ARootResolver: TFunc<string>; const AOnConfigSaved: TProc);

// Unregisters the pages and releases the option objects (RN-007).
procedure UnregisterAefosOptions;

// Single integration point for the menu action and the Chat-panel link
// (ADR-211). Opens Tools->Options focused on the Aefos node / page; on
// any failure falls back to opening the dialog top-level.
procedure OpenAefosOptions(const APageCaption: string = 'AI Chat');

implementation

uses
  Winapi.Windows,
  Vcl.Forms,
  Vcl.Dialogs,
  ToolsAPI,
  Aefos.OTA.Chat.UI.Options.Binding,
  Aefos.OTA.Chat.UI.Options.ChatFrame;

const
  AREA_NAME = 'Aefos';
  // 'Chat' collides exactly with the IDE's built-in AI assistant Chat page. The
  // RAD Studio Options dialog keys the page frame by caption (area-independent),
  // so a bare 'Chat' aliases to that built-in frame. 'AI Chat' keeps us under the
  // Aefos area node while staying globally unique (img-4 evidence: 'MCP Server'
  // never collided with the built-in 'MCP Servers' because the strings differ). 2026-06-07.
  CAPTION_CHAT = 'AI Chat';

type
  // Chat / Executor page. Owns a osChat binding rebuilt per dialog open.
  TChatAddInOptions = class(TInterfacedObject, INTAAddInOptions)
  private
    FFrame: TAefosChatOptionsFrame;
    FBinding: TOptionsConfigBinding;
  public
    destructor Destroy; override;
    function GetArea: string;
    function GetCaption: string;
    function GetFrameClass: TCustomFrameClass;
    procedure FrameCreated(AFrame: TCustomFrame);
    procedure DialogClosed(Accepted: Boolean);
    function ValidateContents: Boolean;
    function GetHelpContext: Integer;
    function IncludeInIDEInsight: Boolean;
  end;

var
  GConfig: IConfig = nil;
  GRootResolver: TFunc<string> = nil;
  GOnConfigSaved: TProc = nil;
  GOptions: TArray<INTAAddInOptions> = nil;
  GRegistered: Boolean = False;

function _EnvOptionsServices(out AServices: INTAEnvironmentOptionsServices): Boolean;
begin
  AServices := nil;
  Result := Assigned(BorlandIDEServices) and
    Supports(BorlandIDEServices, INTAEnvironmentOptionsServices, AServices);
end;

function _NewBinding(const AScope: TOptionsScope): TOptionsConfigBinding;
begin
  Result := TOptionsConfigBinding.Create(GConfig, GRootResolver, AScope);
  Result.LoadFromConfig;
end;

{ TChatAddInOptions }

destructor TChatAddInOptions.Destroy;
begin
  FBinding.Free;
  inherited;
end;

function TChatAddInOptions.GetArea: string;
begin
  Result := AREA_NAME;
end;

function TChatAddInOptions.GetCaption: string;
begin
  Result := CAPTION_CHAT;
end;

function TChatAddInOptions.GetFrameClass: TCustomFrameClass;
begin
  Result := TAefosChatOptionsFrame;
end;

procedure TChatAddInOptions.FrameCreated(AFrame: TCustomFrame);
begin
  FFrame := AFrame as TAefosChatOptionsFrame;
  FreeAndNil(FBinding);
  if not Assigned(GConfig) or not Assigned(GRootResolver) then
    Exit;
  FBinding := _NewBinding(osChat);
  FFrame.LoadFrom(FBinding);
end;

function TChatAddInOptions.ValidateContents: Boolean;
var
  LReason: string;
begin
  Result := True;
  if not Assigned(FFrame) or not Assigned(FBinding) then
    Exit;
  FFrame.StoreTo(FBinding);
  if FBinding.Validate(LReason) then
    Exit;
  if LReason <> '' then
    ShowMessage(LReason);
  Result := False;
end;

procedure TChatAddInOptions.DialogClosed(Accepted: Boolean);
begin
  if Accepted and Assigned(FFrame) and Assigned(FBinding) then
  begin
    FFrame.StoreTo(FBinding);
    FBinding.SaveToConfig;
    if Assigned(GOnConfigSaved) then
      GOnConfigSaved();
  end;
  // The IDE frees the frame after the dialog closes; drop our refs so the next
  // open rebuilds them (RN-004).
  FFrame := nil;
  FreeAndNil(FBinding);
end;

function TChatAddInOptions.GetHelpContext: Integer;
begin
  Result := 0;
end;

function TChatAddInOptions.IncludeInIDEInsight: Boolean;
begin
  Result := True;
end;

procedure RegisterAefosOptions(const AConfig: IConfig;
  const ARootResolver: TFunc<string>; const AOnConfigSaved: TProc);
var
  LServices: INTAEnvironmentOptionsServices;
  LOption: INTAAddInOptions;
begin
  // Refresh the injected dependencies on every call so a re-resolve picks up a
  // new GConfig/resolver even if the pages are already registered.
  GConfig := AConfig;
  GRootResolver := ARootResolver;
  GOnConfigSaved := AOnConfigSaved;
  if GRegistered then
    Exit;
  if not _EnvOptionsServices(LServices) then
    Exit;
  GOptions := [TChatAddInOptions.Create];
  for LOption in GOptions do
    LServices.RegisterAddInOptions(LOption);
  GRegistered := True;
end;

procedure UnregisterAefosOptions;
var
  LServices: INTAEnvironmentOptionsServices;
  LOption: INTAAddInOptions;
begin
  if not GRegistered then
    Exit;
  if _EnvOptionsServices(LServices) then
    for LOption in GOptions do
      LServices.UnregisterAddInOptions(LOption);
  // Releasing the interface refs frees the option objects (and their bindings).
  GOptions := nil;
  GRegistered := False;
  GConfig := nil;
  GRootResolver := nil;
  GOnConfigSaved := nil;
end;

procedure OpenAefosOptions(const APageCaption: string);
var
  LServices: IOTAServices;
  LEnv: IOTAEnvironmentOptions;
begin
  if not (Assigned(BorlandIDEServices) and
    Supports(BorlandIDEServices, IOTAServices, LServices)) then
    Exit;
  LEnv := LServices.GetEnvironmentOptions;
  if not Assigned(LEnv) then
    Exit;
  try
    // ADR-211: focus the Aefos area + requested page directly.
    LEnv.EditOptions(AREA_NAME, APageCaption);
  except
    on E: Exception do
    begin
      OutputDebugString(PChar(
        'Aefos.Options: focused EditOptions failed, opening top-level: '
        + E.Message));
      // Fallback: open the dialog without focusing a node.
      try
        LEnv.EditOptions('', '');
      except
        // best-effort — never raise into the IDE
      end;
    end;
  end;
end;

end.
