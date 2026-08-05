unit Aefos.OTA.Terminal.UI.TerminalView;

interface

uses
  Winapi.Windows,
  Winapi.Messages,
  System.SysUtils,
  System.Classes,
  Vcl.Graphics,
  Vcl.Controls,
  Vcl.ExtCtrls,
  Vcl.StdCtrls,
  Aefos.OTA.Terminal.Core.VTermBuffer,
  Aefos.OTA.Terminal.UI.TerminalCanvas,
  Aefos.OTA.Terminal.Core.TerminalHost,
  Aefos.OTA.Terminal.Core.CellColor,
  Aefos.OTA.Terminal.Core.Hyperlink,
  Aefos.OTA.Terminal.Core.Themes,
  Aefos.OTA.Terminal.Core.ContextStrip,
  Aefos.OTA.Terminal.Core.Profiles;

type
  /// <summary>
  /// A terminal pane: hosts an owner-drawn TTerminalCanvas backed by a
  /// TVTermBuffer and a TTerminalHost driving the shell process.
  /// </summary>
  TAefosTerminalTerminalView = class(TPanel)
  protected
    FBuffer: TVTermBuffer;
    FCanvas: TTerminalCanvas;
    FHost: TTerminalHost;
    FThemeManager: TThemeManager;
    FThemeBackground: TColor;
    FActiveOutline: Boolean;
    FOnFocusChanged: TNotifyEvent;
    FOnSnippetsRequest: TNotifyEvent;
    // ESP-076: AI-CLI context strip. Created only for AIClientType <> aitNone;
    // for a non-AI pane every field below stays nil and the layout is identical
    // to today (BR2/AC4).
    FContextStrip: TPanel;
    FContextLabel: TLabel;
    FContextTimer: TTimer;
    FContextProvider: IIDEContextProvider;
    FLastSnapshot: TIDEContextSnapshot;
    procedure SetActiveOutline(const AValue: Boolean);
    // Resolves the pane border color from focus + active-outline state.
    // V.4 (ESP-061): the focused pane carries the orange accent only when the
    // dock form flags it as the active pane in a multi-pane tab; otherwise the
    // pre-V.4 grey-focus / theme-background behavior is preserved verbatim.
    procedure _UpdateBorderColor;
    procedure _OnCanvasInput(Sender: TObject; const AData: string);
    procedure _OnCanvasResize(Sender: TObject; const ACols, ARows: Integer);
    procedure _OnCanvasFocus(Sender: TObject);
    procedure _OnCanvasPaste(Sender: TObject; const AText: string);
    procedure _OnHyperlinkClick(Sender: TObject; const AUrl: string);
    procedure _OnCanvasSnippetsRequest(Sender: TObject);
    // ESP-075 (S3): when an AI CLI profile (aitClaude) opens, fire-and-forget
    // `claude mcp add` so the CLI auto-connects to the Aefos MCP server.
    // Failures are logged via OutputDebugString and never abort session open (BR4).
    procedure _AutoWireClaudeMcp;
    // ESP-076 (S3/S4): the read-only context strip for AI-CLI panes.
    procedure _CreateContextStrip;
    procedure _RefreshContext;
    procedure _ApplyContextStripTheme;
    procedure _OnContextTimer(Sender: TObject);
    procedure _OnContextStripClick(Sender: TObject);
    procedure WMSetFocus(var Msg: TWMSetFocus); message WM_SETFOCUS;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    /// <summary>Spawns the shell process for this pane. For an <c>aitClaude</c>
    /// profile the working directory is resolved to the active project root
    /// (BR3) and the MCP auto-wiring is fired before spawn (BR4).</summary>
    procedure Start(const AExecutable, AArguments, AStartDir: string;
      const AClientType: TAIClientType = aitNone);
    /// <summary>Terminates the shell process for this pane.</summary>
    procedure Stop;
    /// <summary>Sends text or VT input to the shell.</summary>
    procedure WriteText(const AText: string);
    /// <summary>Clears the screen buffer and scrollback.</summary>
    procedure Reset;
    /// <summary>Applies the active theme to the terminal canvas.</summary>
    procedure ApplyTheme(AThemeManager: TThemeManager);
    /// <summary>Searches the cell grid for the supplied text.</summary>
    function FindText(const ASearchStr: string; AForward, ACaseSensitive: Boolean): Boolean;
    /// <summary>Total occurrences of <c>ASearchStr</c> across the canvas grid and
    /// scrollback. Drives the standalone find-bar <c>N/M</c> counter (ESP-055).</summary>
    function CountFindMatches(const ASearchStr: string; ACaseSensitive: Boolean): Integer;
    /// <summary>1-based index of the highlighted match, or 0 when no match
    /// is currently focused.</summary>
    function FindCurrentMatchIndex(const ASearchStr: string; ACaseSensitive: Boolean): Integer;
    property Host: TTerminalHost read FHost;
    property Buffer: TVTermBuffer read FBuffer;
    property TerminalCanvas: TTerminalCanvas read FCanvas;
    property OnFocusChanged: TNotifyEvent read FOnFocusChanged write FOnFocusChanged;
    property OnSnippetsRequest: TNotifyEvent read FOnSnippetsRequest write FOnSnippetsRequest;
    /// <summary>When True, the focused pane paints the orange active-pane
    /// accent border (ESP-061 / ADR-061-03). Set by the dock form only when
    /// two or more panes are visible; clearing it restores the default
    /// focus/background border. Visual-only (BR1).</summary>
    property ActiveOutline: Boolean read FActiveOutline write SetActiveOutline;
  end;

implementation

uses
  ToolsAPI,
  Winapi.ShellAPI,
  Vcl.Themes,
  Aefos.OTA.Terminal.Core.VisualTokens,
  Aefos.OTA.Terminal.UI.ContextProvider,
  Aefos.OTA.Terminal.MCP.ProjectDir;

constructor TAefosTerminalTerminalView.Create(AOwner: TComponent);
begin
  inherited;
  BevelOuter := bvNone;
  Padding.SetBounds(2, 2, 2, 2);
  Color := clBtnFace;
  FThemeBackground := clBtnFace;

  FBuffer := TVTermBuffer.Create(80, 25);
  FCanvas := TTerminalCanvas.Create(Self, FBuffer);
  FCanvas.Parent := Self;
  FCanvas.Align := alClient;
  FCanvas.OnInput := _OnCanvasInput;
  FCanvas.OnResizeRequest := _OnCanvasResize;
  FCanvas.OnFocusChanged := _OnCanvasFocus;
  FCanvas.OnPaste := _OnCanvasPaste;
  FCanvas.OnHyperlinkClick := _OnHyperlinkClick;
  FCanvas.OnSnippetsRequest := _OnCanvasSnippetsRequest;

  FHost := TTerminalHost.Create(FBuffer);
end;

destructor TAefosTerminalTerminalView.Destroy;
begin
  // Stop the refresh before tearing the pane down; the strip/label/timer are
  // owned by Self and freed by inherited Destroy. Release the provider's facade
  // reference explicitly (AI panes only; all nil on a non-AI pane).
  if Assigned(FContextTimer) then
    FContextTimer.Enabled := False;
  FContextProvider := nil;
  FHost.Free;
  FCanvas.Free;
  FBuffer.Free;
  inherited;
end;

procedure TAefosTerminalTerminalView.WMSetFocus(var Msg: TWMSetFocus);
begin
  inherited;
  if Assigned(FCanvas) and FCanvas.CanFocus then
    FCanvas.SetFocus;
end;

procedure TAefosTerminalTerminalView._OnCanvasInput(Sender: TObject; const AData: string);
begin
  if Assigned(FHost) then
    FHost.WriteText(AData);
end;

procedure TAefosTerminalTerminalView._OnCanvasResize(Sender: TObject;
  const ACols, ARows: Integer);
begin
  if Assigned(FHost) then
    FHost.Resize(ACols, ARows);
end;

procedure TAefosTerminalTerminalView._OnCanvasPaste(Sender: TObject; const AText: string);
begin
  if Assigned(FHost) then
    FHost.PasteText(AText);
end;

procedure TAefosTerminalTerminalView._OnHyperlinkClick(Sender: TObject;
  const AUrl: string);
// ESP-033 / ADR-033-03. The canvas only reports the gesture; policy and
// dispatch live in Aefos.OTA.Terminal.Core.Hyperlink so the security boundary stays
// headlessly testable. THyperlink.Open silently rejects URLs that fail the
// scheme allow-list or length cap.
begin
  THyperlink.Open(AUrl);
end;

procedure TAefosTerminalTerminalView._OnCanvasSnippetsRequest(Sender: TObject);
begin
  if Assigned(FOnSnippetsRequest) then
    FOnSnippetsRequest(Self);
end;

procedure TAefosTerminalTerminalView._UpdateBorderColor;
var
  LFocusColor: TColor;
  LBg: Longint;
  LIsDark: Boolean;
begin
  if FCanvas.Focused then
  begin
    if FActiveOutline then
      // V.4 active-pane accent (ESP-061 / ADR-061-03): orange border on the
      // focused pane when two or more panes are visible.
      Color := TVisualTokens.Accent
    else
    begin
      // Deterministic active border color to eliminate any style system gamble ("roleta")
      LBg := ColorToRGB(FThemeBackground);
      LIsDark := ((0.299 * GetRValue(LBg)) + (0.587 * GetGValue(LBg)) + (0.114 * GetBValue(LBg))) < 128;
      if LIsDark then
        LFocusColor := $004A4A4A // Elegant dark grey
      else
        LFocusColor := $00C0C0C0; // Clean light grey
      Color := LFocusColor;
    end;
  end
  else
    Color := FThemeBackground;
end;

procedure TAefosTerminalTerminalView.SetActiveOutline(const AValue: Boolean);
begin
  if FActiveOutline = AValue then
    Exit;
  FActiveOutline := AValue;
  _UpdateBorderColor;
end;

procedure TAefosTerminalTerminalView._OnCanvasFocus(Sender: TObject);
begin
  _UpdateBorderColor;
  // Focus-gate the context refresh: the timer only runs while this pane is
  // focused, so an unfocused AI pane never polls OTA (BR5). Refresh once on
  // focus-gain so the strip is current the moment the pane is active.
  if Assigned(FContextTimer) then
  begin
    FContextTimer.Enabled := FCanvas.Focused;
    if FCanvas.Focused then
      _RefreshContext;
  end;
  if FCanvas.Focused and Assigned(FOnFocusChanged) then
    FOnFocusChanged(Self);
end;

procedure TAefosTerminalTerminalView._AutoWireClaudeMcp;
var
  LCommand: string;
begin
  // Built off the main thread's data before the worker starts, so the worker
  // touches no shared state (BR4). cmd.exe /c tolerates `claude` resolving to a
  // .cmd/.exe shim on PATH; SW_HIDE keeps it invisible.
  LCommand := TTerminalMcpBridgeCommand.BuildClaudeMcpAddCommandLine(
    TTerminalMcpBridgeCommand.ResolveBridgePath, MCP_DEFAULT_SESSION);
  TThread.CreateAnonymousThread(
    procedure
    var
      LExitCode: HINST;
    begin
      try
        LExitCode := ShellExecute(0, nil, 'cmd.exe', PChar('/c ' + LCommand),
          nil, SW_HIDE);
        if LExitCode <= 32 then
          OutputDebugString(PChar(Format(
            'Aefos MCP auto-wire: ShellExecute failed (%d)', [LExitCode])));
      except
        on E: Exception do
          OutputDebugString(PChar('Aefos MCP auto-wire failed: ' + E.Message));
      end;
    end).Start;
end;

const
  // Low-frequency, focus-gated refresh: cheap enough that polling OTA reads adds
  // no perceptible main-thread cost, responsive enough to track the caret (BR5).
  CContextRefreshIntervalMs = 1000;
  CContextStripHeight       = 20;
  CContextStripHint         = 'Click to inject the IDE context into the CLI prompt';

procedure TAefosTerminalTerminalView._CreateContextStrip;
begin
  if Assigned(FContextStrip) then
    Exit;

  FContextProvider := TOTAIDEContextProvider.Create;

  FContextStrip := TPanel.Create(Self);
  FContextStrip.Parent     := Self;
  FContextStrip.Align      := alTop;
  FContextStrip.Height     := CContextStripHeight;
  FContextStrip.BevelOuter := bvNone;
  FContextStrip.ParentBackground := False;
  FContextStrip.ShowHint   := True;
  FContextStrip.Hint       := CContextStripHint;
  FContextStrip.OnClick    := _OnContextStripClick;

  FContextLabel := TLabel.Create(Self);
  FContextLabel.Parent      := FContextStrip;
  FContextLabel.Align       := alClient;
  FContextLabel.Layout      := tlCenter;
  FContextLabel.AutoSize    := False;
  FContextLabel.AlignWithMargins := True;
  FContextLabel.Margins.SetBounds(6, 0, 6, 0);
  FContextLabel.EllipsisPosition := epEndEllipsis;
  FContextLabel.ShowHint    := True;
  FContextLabel.Hint        := CContextStripHint;
  FContextLabel.OnClick     := _OnContextStripClick;

  FContextTimer := TTimer.Create(Self);
  FContextTimer.Interval := CContextRefreshIntervalMs;
  FContextTimer.Enabled  := False;
  FContextTimer.OnTimer   := _OnContextTimer;

  _ApplyContextStripTheme;
  _RefreshContext;
end;

procedure TAefosTerminalTerminalView._RefreshContext;
var
  LSnapshot: TIDEContextSnapshot;
begin
  if not Assigned(FContextProvider) or not Assigned(FContextLabel) then
    Exit;
  LSnapshot := FContextProvider.GetSnapshot;
  // Debounce: only touch the label when a field actually changed (BR5).
  if not LSnapshot.ChangedFrom(FLastSnapshot) and (FContextLabel.Caption <> '') then
    Exit;
  FLastSnapshot := LSnapshot;
  FContextLabel.Caption := LSnapshot.Caption;
end;

procedure TAefosTerminalTerminalView._ApplyContextStripTheme;
var
  LSurface: TColor;
begin
  if not Assigned(FContextStrip) then
    Exit;
  // Strip chrome reuses the pane theme background with a subtle surface lift,
  // and a legible foreground resolved from luminance (BR7) — no new theming
  // engine, mirrors the VisualTokens dark/light pattern.
  LSurface := TVisualTokens.SurfaceHover(FThemeBackground);
  FContextStrip.Color := LSurface;
  if Assigned(FContextLabel) then
  begin
    if TVisualTokens.IsLightColor(LSurface) then
      FContextLabel.Font.Color := TVisualTokens.Shade(LSurface, -65)
    else
      FContextLabel.Font.Color := TVisualTokens.Shade(LSurface, 65);
  end;
end;

procedure TAefosTerminalTerminalView._OnContextTimer(Sender: TObject);
begin
  _RefreshContext;
end;

procedure TAefosTerminalTerminalView._OnContextStripClick(Sender: TObject);
begin
  // One-shot inject (ADR-076-03): write the exact context line into the running
  // CLI via the existing input seam, then return focus to the canvas so the
  // developer keeps typing in the prompt. No persistent input box (BR4).
  if not Assigned(FContextProvider) then
    Exit;
  WriteText(FContextProvider.GetSnapshot.InjectLine);
  if FCanvas.CanFocus then
    FCanvas.SetFocus;
end;

procedure TAefosTerminalTerminalView.Start(const AExecutable, AArguments, AStartDir: string;
  const AClientType: TAIClientType);
var
  LStartDir: string;
begin
  // Every profile opens in the active project root when its StartDir is empty;
  // an explicit configured StartDir wins verbatim, and a no-project session
  // falls back to the Delphi default Projects dir (ESP-082, ADR-082-01/03).
  LStartDir := TTerminalProjectDirResolver.ResolveSessionWorkDir(AStartDir,
    TTerminalProjectDirResolver.DefaultDelphiProjectsDir);
  // MCP auto-wiring stays AI-CLI-only — only the dir-resolution gate moved out.
  if AClientType = aitClaude then
    _AutoWireClaudeMcp;
  // Any AI-CLI pane gets the read-only context strip; non-AI panes get nothing
  // (no strip, no timer, byte-identical layout — BR2/AC4). Built before the host
  // spawns so the PTY is sized to the canvas that the strip has already shrunk.
  if AClientType <> aitNone then
    _CreateContextStrip;
  FHost.Start(AExecutable, AArguments, LStartDir);
end;

procedure TAefosTerminalTerminalView.Stop;
begin
  FHost.Stop;
end;

procedure TAefosTerminalTerminalView.WriteText(const AText: string);
begin
  if Assigned(FHost) then
    FHost.WriteText(AText);
end;

procedure TAefosTerminalTerminalView.Reset;
begin
  if Assigned(FBuffer) then
    FBuffer.Reset;
  if Assigned(FCanvas) then
    FCanvas.Invalidate;
end;

procedure TAefosTerminalTerminalView.ApplyTheme(AThemeManager: TThemeManager);
var
  LTheme: TTerminalTheme;
  LPalette: TBasePalette;
  LFontName: string;
  LFontSize: Integer;
  LTheming: IOTAIDEThemingServices;
  LStyle: TCustomStyleServices;
  LIndex: Integer;
begin
  FThemeManager := AThemeManager;
  if not Assigned(FThemeManager) then Exit;

  if (FThemeManager.ActiveThemeIndex >= 0) and
     (FThemeManager.ActiveThemeIndex < FThemeManager.Themes.Count) then
  begin
    LTheme := FThemeManager.Themes[FThemeManager.ActiveThemeIndex];
    
    // If the active theme is "Delphi IDE" and we are running inside the IDE,
    // dynamically resolve colors from Embarcadero's style services!
    if SameText(LTheme.Name, 'Delphi IDE') and
       Assigned(BorlandIDEServices) and
       Supports(BorlandIDEServices, IOTAIDEThemingServices, LTheming) and
       LTheming.IDEThemingEnabled then
    begin
      LStyle := LTheming.GetIDEStyleServices;
      if Assigned(LStyle) then
      begin
        LTheme.Background := LStyle.GetStyleColor(scEdit);
        LTheme.Foreground := LStyle.GetSystemColor(clWindowText);
        LTheme.Cursor := LTheme.Foreground;
        
        // Apply Embarcadero-themed ANSI base-16 palette (ESP-059 / ADR-059-02).
        for LIndex := 0 to 15 do
          LTheme.ANSIColors[LIndex] := TVisualTokens.AnsiColor(LIndex);
      end;
    end;

    // Orange Embarcadero accent cursor with a dark/light legibility fallback
    // resolved from the final (StyleServices-adjusted) background (ADR-057-03 /
    // BR6). Replaces the previous "cursor follows foreground" rule.
    LTheme.Cursor := TVisualTokens.ResolveCursorColor(LTheme.Background);

    FThemeBackground := LTheme.Background;
    if not FCanvas.Focused then
      Color := FThemeBackground;
    LPalette := LTheme.BasePalette;
    LFontName := FThemeManager.FontName;
    LFontSize := FThemeManager.FontSize;
    FCanvas.ApplyTheme(LPalette, LTheme.Foreground, LTheme.Background,
      LTheme.Cursor, LFontName, LFontSize);
    // Re-theme the context strip to track the pane background (AI panes only).
    _ApplyContextStripTheme;
  end;
end;

function TAefosTerminalTerminalView.FindText(const ASearchStr: string;
  AForward, ACaseSensitive: Boolean): Boolean;
begin
  Result := FCanvas.FindText(ASearchStr, AForward, ACaseSensitive);
end;

function TAefosTerminalTerminalView.CountFindMatches(const ASearchStr: string;
  ACaseSensitive: Boolean): Integer;
begin
  Result := FCanvas.CountFindMatches(ASearchStr, ACaseSensitive);
end;

function TAefosTerminalTerminalView.FindCurrentMatchIndex(const ASearchStr: string;
  ACaseSensitive: Boolean): Integer;
begin
  Result := FCanvas.FindCurrentMatchIndex(ASearchStr, ACaseSensitive);
end;

end.



