unit Aefos.OTA.Chat.UI.ConsentWebForm;

{
  The permission prompt, OUTSIDE the chat panel, rendered by the SAME code that
  draws it inside it.

  Aefos asked for permission in three visually different ways and the owner said
  the obvious thing: "ate pode criar um form para cada um mas o MODELO igual
  poxa, padrao". Copying the card's layout into a VCL form got close, but close
  is what you get when two renderers agree by hand -- they drift the moment
  someone edits one.

  So this is not a copy. It is a borderless VCL shell hosting a WebView2 that
  loads the card AND NOTHING ELSE, and calls the panel's own dsShowPermission.
  Same CSS, same markup, same buttons, same theme variables -- spliced from the
  same constants the chat shell splices, so they are not "kept in sync", they
  are the same characters. If the card changes, this changes with it.

  The first attempt pointed it at BuildShell, the panel's whole document, and
  opened the ENTIRE CHAT in a frameless window -- header, welcome, composer.
  Reverted in PR #390. TRenderProtocol.BuildConsentDocument exists so that
  mistake has no path back: this window cannot load the chat, because the
  document it loads has no chat in it.

  Borderless on purpose (the owner: "tira as bordas, ninguem vai saber"): the
  HTML already draws a rounded card with its own shadow, so an OS frame around it
  would be the only thing giving away that this is a different window.

  On the WebView2 prerequisite: there is no plain-VCL floor under this, and that
  is deliberate. The owner's point, and he is right -- "se o WebView2 faltar na
  maquina, nao vai aparecer nem o CHAT". A fallback for a state in which the
  product does not function is defence that never pays. What IS handled is the
  WebView failing to come up in time: then the caller falls back, because a
  consent prompt that never appears is the one failure mode this may not have.
}

interface

uses
  Vcl.Forms,
  Aefos.MCP.Types;

type
  TAefosConsentWebForm = class sealed
  public
    { Shows the prompt and blocks until the user answers, the timeout elapses, or
      the WebView fails to become ready.

      Returns False when it could not PRESENT (no WebView) -- the caller then
      uses its own modal. A False here means "not shown", never "denied": the two
      must not be confused, or a broken renderer would silently look like a user
      saying no. }
    class function TryExecute(const AToolName, ASummary, ADetail: string;
      const ATimeoutMs: Cardinal; out ADecision: TMCPConsentDecision): Boolean;
  end;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  Vcl.Controls,
  Vcl.Graphics,
  Aefos.OTA.Chat.Core.OutputPanel.RenderProtocol,
  Aefos.OTA.Chat.UI.OutputPanel.EdgeController;

{$IF not Declared(GetTickCount64)}
// 10 Seattle's Winapi.Windows does not declare this Vista-era API yet.
// Declared() rather than a CompilerVersion number: it asks the compiler in
// hand whether the symbol exists, instead of encoding a guess about which
// release added it.
function GetTickCount64: UInt64; stdcall; external 'kernel32.dll' name 'GetTickCount64';
{$IFEND}

type
  { Private shell. Nothing about it is visible: no border, no caption, no taskbar
    button -- the HTML inside is the entire window as far as the user can tell. }
  TConsentShell = class(TForm)
  private
    FController: TOutputPanelEdgeController;
    FDecision: TMCPConsentDecision;
    FAnswered: Boolean;
    FSized: Boolean;
    procedure _OnHostMessage(const AMessage: string);
  private
    // Rounds the window itself to the card's radius. Without it the HTML draws
    // rounded corners and the OS draws square ones a pixel outside them, which
    // is exactly the giveaway the borderless shell exists to avoid. Re-applied
    // after every resize: a region is in pixels, so it does not follow.
    procedure _ApplyRoundedRegion;
    // "card:size:WxH" from the page. The card's height depends on how much
    // PREVIEW there is, so the window cannot be a constant without either
    // clipping a long one or leaving a dark band under a short one.
    procedure _FitToCard(const ASpec: string);
  protected
    procedure CreateWnd; override;
  public
    constructor CreateShell(AOwner: TComponent); reintroduce;
    destructor Destroy; override;
    procedure Centre;
    property Controller: TOutputPanelEdgeController read FController;
    property Decision: TMCPConsentDecision read FDecision;
    property Answered: Boolean read FAnswered;
    property Sized: Boolean read FSized;
  end;

const
  // The card is 560 CSS px wide with a 94vw cap; the shell gives it room plus the
  // backdrop padding the HTML expects. Height is generous on purpose -- the card
  // centres itself in the backdrop, so extra space costs nothing visually and a
  // long PREVIEW is not clipped.
  CShellWidth  = 620;
  CShellHeight = 520;
  // How long to wait for the page to report the card's size before giving up
  // and showing it at the fixed one. Layout, not creation: a frame, not seconds.
  CSizeTimeoutMs = 700;
  // Matches #ds-perm-modal's border-radius so the window edge follows the card.
  CCornerRadius = 16;
  // How long to wait for WebView2 to come up before giving the caller its modal
  // back. Not the CONSENT timeout: this only covers creation.
  CReadyTimeoutMs = 6000;

constructor TConsentShell.CreateShell(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  BorderStyle := bsNone;
  // Parked off screen, NOT centred. WebView2 will not finish creating in a
  // window that was never shown, so this one has to be shown before it can be
  // measured -- and the user must not watch a 620x520 slab appear and then
  // shrink onto the card. It comes back to the centre once it fits.
  Position := poDesigned;
  Left := -32000;
  Top := -32000;
  ClientWidth := CShellWidth;
  ClientHeight := CShellHeight;
  FSized := False;
  // Matches the shell's own background so the moment before the document paints
  // is not a white flash in the middle of a dark IDE.
  Color := TColor($211E1E);
  FormStyle := fsStayOnTop;
  FDecision := cdDenied;   // safe default, as everywhere else
  FAnswered := False;
  FController := TOutputPanelEdgeController.Create(Self);
  FController.OnHostMessage := _OnHostMessage;
end;

procedure TConsentShell._ApplyRoundedRegion;
var
  LRgn: HRGN;
begin
  if not HandleAllocated then
    Exit;
  // +1 on each extent: CreateRoundRectRgn's right/bottom are EXCLUSIVE, so the
  // last column and row would be clipped off without it.
  LRgn := CreateRoundRectRgn(0, 0, Width + 1, Height + 1,
    CCornerRadius * 2, CCornerRadius * 2);
  if LRgn <> 0 then
    // The window owns the region after this call; do NOT delete it here.
    SetWindowRgn(Handle, LRgn, True);
end;

procedure TConsentShell.CreateWnd;
begin
  inherited CreateWnd;
  _ApplyRoundedRegion;
end;

procedure TConsentShell._FitToCard(const ASpec: string);
var
  LSplit: Integer;
  LW, LH, LMaxH: Integer;
begin
  LSplit := Pos('x', ASpec);
  if LSplit <= 1 then
    Exit;
  LW := StrToIntDef(Copy(ASpec, 1, LSplit - 1), 0);
  LH := StrToIntDef(Copy(ASpec, LSplit + 1, MaxInt), 0);
  // A page that reports nonsense must not produce a 1px window or one larger
  // than the screen. Out of range = keep what we have; the fixed size was
  // never wrong, only wasteful.
  if (LW < 200) or (LH < 120) then
    Exit;
  LMaxH := (Screen.WorkAreaHeight * 9) div 10;
  if LH > LMaxH then
    LH := LMaxH;
  if LW > Screen.WorkAreaWidth then
    LW := Screen.WorkAreaWidth;
  ClientWidth := LW;
  ClientHeight := LH;
  Centre;
  _ApplyRoundedRegion;
  FSized := True;
end;

procedure TConsentShell.Centre;
begin
  // By hand, not poScreenCenter: the window is deliberately parked off screen
  // while WebView2 warms up, and a resize afterwards would leave it off-centre
  // by half the difference anyway.
  Left := Screen.WorkAreaLeft + (Screen.WorkAreaWidth - Width) div 2;
  Top := Screen.WorkAreaTop + (Screen.WorkAreaHeight - Height) div 2;
end;

destructor TConsentShell.Destroy;
begin
  FController.Free;
  inherited Destroy;
end;

procedure TConsentShell._OnHostMessage(const AMessage: string);
var
  LKind: string;
begin
  // Sizing arrives first and is not a decision -- handled before the 'perm:'
  // branch, where anything unrecognised is deliberately read as a denial.
  if AMessage.StartsWith('card:size:') then
  begin
    _FitToCard(Copy(AMessage, Length('card:size:') + 1, MaxInt));
    Exit;
  end;
  // The page posts the same 'perm:*' messages the chat panel listens for -- this
  // shell understands the panel's protocol rather than inventing one.
  if not AMessage.StartsWith('perm:') then
    Exit;
  LKind := Copy(AMessage, Length('perm:') + 1, MaxInt);
  if SameText(LKind, 'once') then
    FDecision := cdAllowOnce
  else if SameText(LKind, 'session') then
    FDecision := cdAllowSession
  else
    FDecision := cdDenied;   // anything unrecognised is a deny
  FAnswered := True;
  ModalResult := mrOk;
end;

class function TAefosConsentWebForm.TryExecute(const AToolName, ASummary,
  ADetail: string; const ATimeoutMs: Cardinal;
  out ADecision: TMCPConsentDecision): Boolean;
var
  LShell: TConsentShell;
  LStart: UInt64;
  LShown: Boolean;
begin
  ADecision := cdDenied;
  Result := False;
  LShell := TConsentShell.CreateShell(nil);
  try
    // The controller creates the browser HIDDEN -- the chat panel reveals it once
    // its document is up (ChatPanel.pas:2467). Nothing did that here, so the
    // shell showed an empty dark rectangle: the window was right, the WebView
    // was simply never made visible.
    LShell.Controller.Browser.Visible := True;
    // The CARD, not the panel's shell. Navigate() here is what opened the whole
    // chat in a frameless window (PR #390).
    LShell.Controller.NavigateConsent(TPanelTheme.Dark);
    // Pump until the document is ready. ShowPermission refuses before that, and
    // showing an empty window while WebView2 warms up is worse than a beat of
    // delay.
    // The window has to be ON SCREEN before WebView2 will finish creating: a
    // composition-hosted browser in a window that was never shown stays blank
    // forever. Show it non-modally, let the document come up, THEN go modal.
    LShell.Show;
    LStart := GetTickCount64;
    LShown := False;
    while (GetTickCount64 - LStart) < CReadyTimeoutMs do
    begin
      Application.ProcessMessages;
      if LShell.Controller.ShowPermission(AToolName, ASummary, ADetail) then
      begin
        LShown := True;
        Break;
      end;
      Sleep(20);
    end;
    if not LShown then
      // Could not PRESENT. Not a denial -- the caller shows its own modal.
      Exit;
    // The card reports its size one animation frame after it is filled in, so
    // it lands just AFTER ShowPermission returned. Give it that moment while the
    // window is still parked off screen; a card that arrives already the right
    // size never has to be seen resizing.
    LStart := GetTickCount64;
    while (not LShell.Sized) and ((GetTickCount64 - LStart) < CSizeTimeoutMs) do
    begin
      Application.ProcessMessages;
      Sleep(10);
    end;
    if not LShell.Sized then
      // Never measured: show it at the fixed size rather than not at all.
      LShell.Centre;
    LShell.Hide;
    LShell.ShowModal;
    ADecision := LShell.Decision;
    // Closed without answering (Escape, Alt+F4) leaves the safe default, and it
    // still counts as SHOWN: the user saw the prompt and dismissed it.
    Result := True;
  finally
    LShell.Free;
  end;
end;

end.
