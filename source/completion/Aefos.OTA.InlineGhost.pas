unit Aefos.OTA.InlineGhost;

{
  Inline completion (ghost text) -- the IDE wiring.

  The policy lives in Aefos.Chat.Core.InlineCompletion (pure, tested headless);
  the FIM request lives in Aefos.Provider.Ollama.Core. THIS unit is only the
  three things that need the IDE: painting, keys, and reading the caret.

  Painting, and why it costs the user's file NOTHING
  --------------------------------------------------
  ToolsAPI.Editor.INTACodeEditorEvents.PaintLine at stage plsEndPaint -- after
  the line's real text is drawn -- with the x taken from
  Context.LineState.GetVisibleTextRect.Right, so the ghost sits AFTER the code
  instead of on top of it and without guessing font widths. Not one byte of the
  buffer is touched to show a suggestion.
    This matters because the obvious alternative is what the reference
  implementation we studied does: insert real blank lines to make room and paint
  over them. That marks the file Modified before the user has typed anything.
    INTAEditViewNotifier.PaintLine (what the reference uses) is deprecated;
  ToolsAPI.pas says so and points here.

  A BLOCK, not a line -- and how it is drawn without an overlay window
  -------------------------------------------------------------------
  One line was not convincing (owner, 2026-08-03), and it was never a model
  limit: the same prompt that we were reducing to one line returns a whole
  try/finally in ~3s. The editor never paints below the end of the file
  (measured: 199-line file, highest line requested was 199), so the extra lines
  cannot be drawn in empty space -- but they CAN be drawn over the lines that
  already follow the caret, which is exactly where the code will land.
    What makes that readable instead of a smear is painting the covered line OUT
  first. The documented way -- PaintText's AllowDefaultPainting, "skip the IDE's
  default text painting" -- simply did not work on this build: the first live
  attempt put the suggestion straight on top of the code (screenshot,
  2026-08-04). So the line's background is SAMPLED from the editor's own canvas
  at plsBackground, while the line is still bare, and laid back over the code
  area at plsEndPaint before the ghost goes on. Sampling instead of asking a
  theme API means it is right by construction under any theme, on the current
  line, and under a selection -- and still not one byte written to the buffer.
    Only the code area is painted out, never the gutter: line numbers,
  breakpoints and the change bar stay.
    Line 0 stays ON the caret line (after the code, or behind an [Enter] marker
  when the suggestion belongs on a new line), so a block always shows something
  even when the caret is on the last line of the file. When the file has fewer
  lines below the caret than the block needs, the last painted line says how
  many are hidden rather than letting the preview stop mid-thought.

  Keys, and the one that could really hurt
  ----------------------------------------
  Tab is the accept key, and Tab is also the single most important key in a code
  editor. So the binding returns krUnhandled unless a suggestion is showing FOR
  THE EXACT CARET IT WAS MADE FOR. Anything else -- no suggestion, different
  file, caret moved a column -- falls straight through to the IDE. A ghost
  feature that eats Tab is worse than no ghost feature.

  Teardown
  --------
  Both the keyboard binding and the editor-events notifier are removed
  EXPLICITLY in finalization, guarded. Read Aefos.OTA.Chat.UnloadContract before
  changing that: relying on the IDE to clean up after a package unload is what
  produced the chronic AV + locked .bpl + F2039.
}

interface

uses
  ToolsAPI;

type
  TAefosInlineGhost = class sealed
  public
    // Wires the painter + the keys. Safe to call more than once (later calls
    // are no-ops). Never raises: a failure here must not stop the IDE loading
    // the rest of Aefos.
    class procedure RegisterSelf; static;
    class procedure UnregisterSelf; static;
    // Re-reads Tools > Options (AI Flow) and installs or removes each piece to
    // match. Called at load and pushed by the Options page when the user
    // accepts the dialog, so a change takes effect without an IDE restart.
    class procedure ApplySettings; static;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Types,
  System.IOUtils,
  System.Math,
  Winapi.Windows,
  Vcl.Graphics,
  Vcl.Controls,
  Vcl.Menus,
  Vcl.Forms,
  ToolsAPI.Editor,
  Aefos.Compat.Http,
  Aefos.Provider.Ollama.Core,
  Aefos.Chat.Core.InlineCompletion,
  Aefos.OTA.Chat.Core.Dispatcher.Types,
  Aefos.OTA.Chat.Core.CLIDispatcher,
  Aefos.Provider.Types,
  Aefos.Provider.Registry,
  Aefos.OTA.Options.AIFlow,
  Aefos.OTA.Options.AIFlow.Store,
  Aefos.OTA.Chat.Core.Config,
  Aefos.OTA.Chat.Core.Config.Types,
  Aefos.Executor.Models;

const
  ACCEPT_SHORTCUT = 'Tab';
  DISMISS_SHORTCUT = 'Esc';
  BINDING_NAME = 'AefosInlineGhost';
  BINDING_DISPLAY = 'Aefos AI inline completion';
  // The ghost must read as "not yours yet". Grey at both ends of the theme
  // range; the editor's own background is not queryable per-theme from here, so
  // a mid grey is the safe choice on light AND dark.
  GHOST_COLOR = TColor($00808080);
  // A thin accent down the left of the lines the block borrows. Without it the
  // preview reads as DELETION -- the owner's words on first sight were "it ate
  // the ends" (2026-08-04), because the real end;/end. under the block were
  // simply gone from the screen. The bar says "this is laid over your file",
  // which is the truth: nothing has been touched, and the code comes straight
  // back on Esc. Teal reads as ours on a light and a dark theme alike.
  GHOST_ACCENT_COLOR = TColor($00B0A030);
  GHOST_ACCENT_WIDTH = 2;
  // How much of the accent is mixed into the borrowed lines' background. Enough
  // to read as a DIFFERENT SURFACE at a glance, nowhere near enough to fight the
  // grey text on it. The bar alone was not enough -- the owner still read the
  // block as "it deleted my end;" with the bar right there (2026-08-04) -- so
  // the whole band is tinted and ruled off top and bottom. A card sitting ON the
  // file, which is what it is.
  GHOST_TINT_PERCENT = 10;
  REQUEST_TIMEOUT_MS = 8000;
  // The CLI path gets far longer than the local one. A cloud round trip is ~4s
  // measured, a cold one is worse, and the user is deliberately waiting for it.
  // But a completion that has not arrived in half a minute is not coming, and
  // an unbounded child process is a leak with a UI.
  CLI_TIMEOUT_MS = 30000;
  // Where the breadcrumb log wraps. Big enough to hold a long session's worth of
  // requests (a day of heavy testing produced 65 KB), small enough that nobody
  // ever notices it in their profile.
  LOG_MAX_BYTES = 1024 * 1024;
  // The worker is bounded by REQUEST_TIMEOUT_MS, so this only has to outlast a
  // request that is already returning.
  TEARDOWN_DRAIN_MS = 10000;
  TEARDOWN_POLL_MS = 25;
  DEFAULT_OLLAMA_BASE = 'http://localhost:11434';
  // Deliberately plain ASCII dots rather than a single ellipsis character: this
  // file carries no BOM, and a non-ASCII literal here is the mojibake trap the
  // house has paid for before.
  PENDING_MARKER = '  ...';
  // Same reason as above: ASCII, no BOM in this file. It has to READ as an
  // instruction, because the ghost is not where the code will land.
  NEWLINE_MARKER = '  [Enter] ';
  // Said on the last line we can actually paint, when the file runs out of
  // lines below the caret before the block runs out of lines. A preview that
  // just stops looks like a model that just stopped.
  MORE_MARKER = '   ... +%d more (Tab)';

type
  // What is currently offered, and the exact caret it belongs to. The caret
  // triple is the whole safety story for the Tab key: if any of it stops
  // matching, the suggestion is stale and Tab is none of our business.
  TGhostState = record
    // The whole block, one entry per line. Line 0 is painted on the caret line;
    // 1..n are painted OVER the lines that follow it.
    Lines: TArray<string>;
    FileName: string;
    Line: Integer;
    Column: Integer;
    Showing: Boolean;
    // The suggestion goes on a NEW line: line 0 is painted on the caret line
    // behind a marker, and accepted with a line break in front of the block.
    NewLine: Boolean;
    // How many of Lines can actually be drawn: the file may not have enough
    // lines below the caret, and the editor will not paint past its end.
    VisibleLines: Integer;
    // The policy dropped lines beyond its cap. Counted into the "+n more" note
    // so the number the user reads is the number really hidden.
    Truncated: Boolean;
  end;

  // Shown while a request is in flight. Without it the feature is indist-
  // inguishable from broken: the model legitimately returns NOTHING at a caret
  // where there is nothing to suggest (measured live -- a blank line before
  // `end.` answered empty every time, in ~300ms), and a silent refusal looks
  // exactly like a key that did not work. The user must always be able to see
  // that the request happened.
  TGhostPending = record
    FileName: string;
    Line: Integer;
    Column: Integer;
    Token: Integer;
    Active: Boolean;
  end;

  // A short grey note on the caret line when a request FAILED. Never a dialog --
  // nothing here may interrupt typing -- but never silence either: "the model is
  // not installed" and "the model had nothing to suggest" look identical to a
  // user, and one of them is a five-second fix they cannot make if we do not
  // tell them. Shown only while the caret is still where the request was made,
  // so it retires on its own the moment the user moves on.
  TGhostNotice = record
    Text: string;
    FileName: string;
    Line: Integer;
    Column: Integer;
    Active: Boolean;
  end;

  TAefosGhostPainter = class(TInterfacedObject, INTACodeEditorEvents)
  public
    procedure AfterSave;
    procedure BeforeSave;
    procedure Destroyed;
    procedure Modified;
    procedure EditorScrolled(const Editor: TWinControl;
      const Direction: TCodeEditorScrollDirection);
    procedure EditorResized(const Editor: TWinControl);
    procedure EditorElided(const Editor: TWinControl; const LogicalLineNum: Integer);
    procedure EditorUnElided(const Editor: TWinControl; const LogicalLineNum: Integer);
    procedure EditorMouseDown(const Editor: TWinControl; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure EditorMouseMove(const Editor: TWinControl; Shift: TShiftState;
      X, Y: Integer);
    procedure EditorMouseUp(const Editor: TWinControl; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure BeginPaint(const Editor: TWinControl; const ForceFullRepaint: Boolean);
    procedure EndPaint(const Editor: TWinControl);
    procedure PaintLine(const Rect: TRect; const Stage: TPaintLineStage;
      const BeforeEvent: Boolean; var AllowDefaultPainting: Boolean;
      const Context: INTACodeEditorPaintContext);
    procedure PaintGutter(const Rect: TRect; const Stage: TPaintGutterStage;
      const BeforeEvent: Boolean; var AllowDefaultPainting: Boolean;
      const Context: INTACodeEditorPaintContext);
    procedure PaintText(const Rect: TRect; const ColNum: SmallInt;
      const Text: string; const SyntaxCode: TOTASyntaxCode;
      const Hilight, BeforeEvent: Boolean; var AllowDefaultPainting: Boolean;
      const Context: INTACodeEditorPaintContext);
    function AllowedEvents: TCodeEditorEvents;
    function AllowedGutterStages: TPaintGutterStages;
    function AllowedLineStages: TPaintLineStages;
    function UIOptions: TCodeEditorUIOptions;
  end;

  // What the AI Flow Options page says this feature may do. Cached because the
  // painter path reads it on every line of every repaint; refreshed by a push
  // from the page (TAIFlowOptions' settings-changed handler), never by polling
  // the config file.
  //
  // AUTOMATIC MODE WAS REMOVED (owner, 2026-08-04: "esquece o Auto"). It worked,
  // but it can only ever work against a fast local model -- an agentic CLI turn
  // costs ~4s no matter how warm it is, and firing that on its own after every
  // typing pause is a promise the backend cannot keep. Explicit invocation has
  // no such ceiling: the user asked and is waiting, so 4s is simply how long it
  // took. So the feature is the SHORTCUT, it works against whatever the user has
  // configured, and no poll runs in the IDE for it.
  TGhostSettings = record
    Enabled: Boolean;
    Shortcut: string;
  end;

  TAefosGhostBinding = class(TNotifierObject, IOTAKeyboardBinding)
  private
    procedure _OnRequest(const AContext: IOTAKeyContext; AKeyCode: TShortcut;
      var ABindingResult: TKeyBindingResult);
    procedure _OnAccept(const AContext: IOTAKeyContext; AKeyCode: TShortcut;
      var ABindingResult: TKeyBindingResult);
    procedure _OnDismiss(const AContext: IOTAKeyContext; AKeyCode: TShortcut;
      var ABindingResult: TKeyBindingResult);
  public
    function GetBindingType: TBindingType;
    function GetDisplayName: string;
    function GetName: string;
    procedure BindKeyboard(const ABindingServices: IOTAKeyBindingServices);
  end;

  // The request runs OFF the main thread: an 8s HTTP timeout on the IDE thread
  // would freeze the editor, and the whole point of a local model is that the
  // user keeps typing while it thinks.
  //   The result is delivered as a CLOSURE OVER COPIES, never as a method of
  // this object. FreeOnTerminate is True, so by the time a queued method would
  // run on the main thread the thread instance can already be gone, and reading
  // its string fields is a read of freed memory. That is not a theoretical
  // hazard: it AV'd on the first live keypress, with System.@UStrAsg on top of
  // the stack inside the delivery method (2026-08-03).
  TGhostRequestThread = class(TThread)
  private
    FUrl: string;
    FBody: string;
    FFileName: string;
    FLine: Integer;
    FColumn: Integer;
    FLineText: string;
    FSuffix: string;
    // Captured at CREATION, never at delivery. Read at the end of the run it
    // would always equal the current token and the staleness check would pass
    // for every reply -- the guard would exist and protect nothing.
    FToken: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(const AUrl, ABody, AFileName: string;
      const ALine, AColumn: Integer; const ALineText, ASuffix: string);
  end;

var
  GState: TGhostState;
  GPending: TGhostPending;
  GNotice: TGhostNotice;
  // Set the moment teardown begins. Everything that could run code from this
  // BPL after that point checks it FIRST and does nothing.
  //   Learned the hard way: the request worker is FreeOnTerminate and its reply
  // is delivered through TThread.Queue, so a request in flight when the IDE
  // closes would keep executing -- and its queued closure would fire -- while
  // the package is unmapping. That is the exact family of defect the unload
  // contract exists for (AV / locked .bpl / F2039), and it hangs the IDE.
  GShuttingDown: Boolean = False;
  // How many workers are alive. Teardown waits on this, bounded, instead of
  // hoping.
  GInFlight: Integer = 0;
  // The background colour of the line currently being painted, sampled from the
  // editor's own canvas at plsBackground -- after the editor filled it and
  // before any text went on it. Sampling beats asking: it is whatever the theme,
  // the current-line highlight or a selection actually produced, with no theme
  // API to keep in step. Valid only for GCoverLine, and only between that
  // line's plsBackground and its plsEndPaint.
  // The CLI run in flight, if the configured executor is an agentic CLI rather
  // than a local model. Held so teardown can cancel it: a child process still
  // streaming into our callbacks while the BPL unmaps is the same family of
  // defect as a live notifier, and this house has paid for that one already.
  GCliRun: IDispatcherRunHandle = nil;
  GCliBuffer: string = '';
  GCoverColor: TColor = clNone;
  GCoverLine: Integer = -1;
  GBindingIndex: Integer = -1;
  GPainterIndex: Integer = -1;
  GRegistered: Boolean = False;
  GSettings: TGhostSettings;
  // Bumped on every request and on every dismissal. A reply carrying a stale
  // token is dropped: without it, a slow answer for a caret the user already
  // left would pop a ghost somewhere they are not looking.
  GRequestToken: Integer = 0;

// The size of a file, without asking the RTL for a whole stream. Returns 0 for
// anything it cannot measure -- a log that cannot be sized must not stop the
// log from being written.
function _FileSize(const APath: string): Int64;
var
  LRec: TSearchRec;
begin
  // Qualified: Winapi.Windows exports its own FindClose (and takes a handle),
  // and this unit uses both. Unqualified, the wrong one binds.
  Result := 0;
  if System.SysUtils.FindFirst(APath, faAnyFile, LRec) = 0 then
    try
      Result := LRec.Size;
    finally
      System.SysUtils.FindClose(LRec);
    end;
end;

// Breadcrumb log. OutputDebugString alone was NOT enough: the feature failed
// live and there was no way for the owner to see WHY without attaching a
// debugger -- the first request went out asking for a model that was not
// installed and the whole thing stayed silent. A file the user can open is the
// difference between "faz nada" and a diagnosis.
procedure _Log(const AText: string);
var
  LDir: string;
  LPath: string;
begin
  try
    LDir := TPath.Combine(TPath.GetHomePath, 'Aefos');
    if not TDirectory.Exists(LDir) then
      TDirectory.CreateDirectory(LDir);
    LPath := TPath.Combine(LDir, 'aefos-inline-ghost.log');
    // BOUNDED. This wrote 65 KB in a single day of testing and had no ceiling at
    // all -- a diagnostic that grows forever in the user's profile is a leak
    // that happens to be made of text. One previous file is kept, because the
    // interesting part of a bug report is usually just before the wrap.
    if TFile.Exists(LPath) and (_FileSize(LPath) > LOG_MAX_BYTES) then
    begin
      if TFile.Exists(LPath + '.old') then
        TFile.Delete(LPath + '.old');
      TFile.Move(LPath, LPath + '.old');
    end;
    TFile.AppendAllText(LPath,
      FormatDateTime('hh:nn:ss.zzz', Now) + '  ' + AText + sLineBreak);
  except
    // Diagnostics must never take the IDE down.
  end;
end;

function _EditorServices: INTACodeEditorServices;
begin
  if not Supports(BorlandIDEServices, INTACodeEditorServices, Result) then
    Result := nil;
end;

procedure _ClearGhost;
begin
  GState.Showing := False;
  GState.Lines := nil;
  GState.NewLine := False;
  GState.VisibleLines := 0;
  GState.Truncated := False;
  GPending.Active := False;
  GNotice.Active := False;
  Inc(GRequestToken); // any in-flight reply is now stale
end;

// The one-line version of a failure, for the editor. The DETAIL always goes to
// the log; this is only enough for the user to know which kind of problem they
// are looking at, because the two common ones have completely different fixes.
function _NoticeFor(const AError: string): string;
var
  LLower: string;
begin
  LLower := LowerCase(AError);
  if Pos('not found', LLower) > 0 then
    Result := '  [Aefos: completion model not installed]'
  else if (Pos('refused', LLower) > 0) or (Pos('could not connect', LLower) > 0) or
          (Pos('cannot connect', LLower) > 0) then
    Result := '  [Aefos: no local model server]'
  else if Pos('timed out', LLower) > 0 then
    Result := '  [Aefos: completion timed out]'
  else
    Result := '  [Aefos: completion failed, see aefos-inline-ghost.log]';
end;

procedure _InvalidateTop;
var
  LServices: INTACodeEditorServices;
begin
  LServices := _EditorServices;
  if LServices <> nil then
    try
      LServices.InvalidateTopEditor;
    except
      // A repaint we could not ask for is not worth an exception in the IDE.
    end;
end;

// True when the view has a real selection in it.
//   Tab with a selection is BLOCK INDENT in this editor, and that is not a key
// a completion may take away. A ghost has no business appearing over selected
// code either -- and it would look absurd if it did, because the covered lines'
// sampled background IS the selection colour, so the "card" comes out as a slab
// of selection blue.
function _HasSelection(const AView: IOTAEditView): Boolean;
var
  LBlock: IOTAEditBlock;
begin
  Result := False;
  if AView = nil then
    Exit;
  try
    LBlock := AView.Block;
    Result := (LBlock <> nil) and LBlock.IsValid and (LBlock.Size > 0);
  except
    // A view that will not answer is not a view we paint over.
    Result := True;
  end;
end;

// How many lines the active buffer has. Needed because the block ghost borrows
// the lines BELOW the caret to draw itself, and the editor never paints past
// the end of the file -- so a block near the bottom has fewer rows to live in
// than it has lines.
function _TotalLines: Integer;
var
  LServices: IOTAEditorServices;
  LView: IOTAEditView;
begin
  Result := 0;
  if not Supports(BorlandIDEServices, IOTAEditorServices, LServices) then
    Exit;
  LView := LServices.TopView;
  if (LView = nil) or (LView.Buffer = nil) then
    Exit;
  try
    Result := LView.Buffer.GetLinesInBuffer;
  except
    Result := 0;
  end;
end;

// The active source editor's full text, plus where the caret is in it.
function _ReadActiveEditor(out AText, AFileName, ALineText: string;
  out AOffset, ALine, AColumn: Integer): Boolean;
var
  LServices: IOTAEditorServices;
  LView: IOTAEditView;
  LBuffer: IOTAEditBuffer;
  LReader: IOTAEditReader;
  LChunk: array[0..8191] of AnsiChar;
  LRead: Integer;
  LPos: Integer;
  LUtf8: RawByteString;
  LScan: Integer;
  LRow: Integer;
  LLineStart: Integer;
begin
  Result := False;
  AText := '';
  AFileName := '';
  ALineText := '';
  AOffset := 0;
  ALine := 0;
  AColumn := 0;
  if not Supports(BorlandIDEServices, IOTAEditorServices, LServices) then
    Exit;
  LView := LServices.TopView;
  if LView = nil then
    Exit;
  LBuffer := LView.Buffer;
  if LBuffer = nil then
    Exit;
  AFileName := LBuffer.FileName;
  ALine := LView.CursorPos.Line;
  AColumn := LView.CursorPos.Col;
  LReader := LBuffer.CreateReader;
  if LReader = nil then
    Exit;
  // IOTAEditReader hands out UTF-8 bytes; accumulate then decode once, or a
  // multibyte character split across two chunks becomes mojibake.
  LUtf8 := '';
  LPos := 0;
  repeat
    LRead := LReader.GetText(LPos, @LChunk[0], SizeOf(LChunk) - 1);
    if LRead <= 0 then
      Break;
    SetLength(LUtf8, Length(LUtf8) + LRead);
    Move(LChunk[0], LUtf8[Length(LUtf8) - LRead + 1], LRead);
    Inc(LPos, LRead);
  until LRead < SizeOf(LChunk) - 1;
  AText := UTF8ToString(LUtf8);
  if AText = '' then
    Exit;
  // Walk to the caret line to get both the character offset and the line text.
  // Done by scanning rather than trusting a byte offset: the editor counts in
  // characters and the buffer arrived as UTF-8.
  LRow := 1;
  LScan := 1;
  LLineStart := 1;
  while (LScan <= Length(AText)) and (LRow < ALine) do
  begin
    if AText[LScan] = #10 then
    begin
      Inc(LRow);
      LLineStart := LScan + 1;
    end;
    Inc(LScan);
  end;
  if LRow <> ALine then
    Exit; // caret past the end of what we read: refuse rather than guess
  LScan := LLineStart;
  while (LScan <= Length(AText)) and (AText[LScan] <> #10) do
    Inc(LScan);
  ALineText := Copy(AText, LLineStart, LScan - LLineStart);
  ALineText := StringReplace(ALineText, #13, '', [rfReplaceAll]);
  // Clamped to the END OF THE CARET LINE, not to the end of the document.
  //
  // The caret in this editor can sit BEYOND the last character of its line --
  // measured here more than once, e.g. `linelen=0 col=3` on a blank line. The
  // old arithmetic (LineStart + Col - 1) then walked straight over the line's
  // own CRLF and landed at the start of the NEXT line, so a five-line block
  // accepted on a blank line was written one line too far down and its last
  // line fused with the code that followed: `end;   if FPendingOperator = ...`
  // on one row (owner screenshot, 2026-08-04).
  //   It only became visible when accept moved to the edit writer: IOTAEdit
  // Position.Move clamps a bad column silently, a byte offset does not. The
  // same overshoot was also skewing the prefix/suffix window sent to the model.
  AOffset := LLineStart + Min(AColumn - 1, Length(ALineText));
  if AOffset > Length(AText) + 1 then
    AOffset := Length(AText) + 1;
  Result := True;
end;

function _ResolveModel: string;
begin
  // An explicit override first: it is how this gets tried against a dedicated
  // FIM model without disturbing the chat's own Ollama pick. A per-feature
  // Option belongs here later -- the chat model and the completion model are
  // genuinely different jobs (chat wants instruct, completion wants FIM).
  Result := Trim(GetEnvironmentVariable('AEFOS_INLINE_MODEL'));
  if Result = '' then
    Result := Trim(TExecutorModelStore.SelectedModelForKind(ekOllama));
end;

function _ResolveBaseUrl: string;
begin
  // NOT read from the chat's TConfig on purpose: that config is PER PROJECT and
  // is resolved through the executor's root resolver, which this unit has no
  // business owning -- inline completion runs whether or not a chat session
  // exists. Env override + the Ollama default keeps the dependency at zero
  // until the feature earns its own Options field (where the endpoint AND the
  // model belong together, since a completion model is a different job from the
  // chat model: FIM versus instruct).
  Result := Trim(GetEnvironmentVariable('AEFOS_OLLAMA_URL'));
  if Result = '' then
    Result := DEFAULT_OLLAMA_BASE;
end;

// Forward: the one place a reply -- from either backend -- becomes a ghost.
// Declared here so the CLI path below can reach it without moving the local
// model's delivery code away from the thread it belongs to.
procedure _ApplyReply(const AReply, AError, AFileName, ALineText,
  ASuffix: string; const ALine, AColumn, AToken: Integer); forward;

// Which backend answers. NOT probed -- decided by what the user configured for
// the chat, which is what the owner asked for ("usar o agente configurado para o
// chat"). Probing would cost a failed round trip on every single request for
// everyone who is not on Ollama, to learn something the config already says.
function _ConfiguredExecutor(out AKind: TExecutorKind;
  out APath, AModel: string): Boolean;
var
  LToken: string;
begin
  LToken := Trim(TAefosFlowConfigStore.ReadString('executor', ''));
  APath := Trim(TAefosFlowConfigStore.ReadString('executor_path', ''));
  AModel := Trim(TAefosFlowConfigStore.ReadString('model', ''));
  Result := False;
  if LToken = '' then
    Exit;
  AKind := TProviderRegistry.ParseExecutorKind(LToken);
  Result := True;
end;

// Delivers a CLI answer on the main thread, through exactly the same policy the
// local model's reply goes through. The CLI's output is scrubbed of prose FIRST
// -- that is the only step the two paths do not share, and it exists because an
// instruct model behind a command line will explain itself unless stopped.
procedure _ApplyCliReply(const AOutput, AFileName, ALineText, ASuffix: string;
  const ALine, AColumn, AToken: Integer);
begin
  _ApplyReply(TAefosInlineCompletion.StripProse(AOutput), '', AFileName,
    ALineText, ASuffix, ALine, AColumn, AToken);
end;

// Asks the configured agentic CLI. Costs ~4s, which is why this is reachable
// ONLY from the shortcut: the user pressed a key and is waiting for an answer.
procedure _RequestViaCli(const AKind: TExecutorKind;
  const APath, AModel, APrefix, ASuffix, AFileName, ALineText: string;
  const ALine, AColumn: Integer);
var
  LProfile: IExecutorProfile;
  LCtx: TProviderDispatchContext;
  LRequest: TDispatchRequest;
  LToken: Integer;
begin
  LProfile := TProviderRegistry.ResolveExecutorProfile(AKind);
  if LProfile = nil then
  begin
    _Log('request: ABORT no driver for the configured executor');
    GPending.Active := False;
    _InvalidateTop;
    Exit;
  end;
  LCtx := Default(TProviderDispatchContext);
  LCtx.Model := AModel;
  // NOT agent mode, and no session. This is one question with one answer -- the
  // CLI has no business reaching for MCP tools, editing the project, or
  // remembering that it was asked. Agent mode here would let a completion
  // request start changing files.
  LCtx.AgentMode := False;
  LCtx.SessionStarted := False;
  LRequest := Default(TDispatchRequest);
  LRequest.ExecutorPath := APath;
  LRequest.Args := LProfile.BuildDispatchArgs(LCtx);
  LRequest.Prompt := TAefosInlineCompletion.BuildInstructPrompt(APrefix, ASuffix);
  LRequest.Executor := TProviderRegistry.ExecutorKindToString(AKind);
  // Bounded, and generously: a cloud round trip is ~4s and a cold one is worse,
  // but a completion that has not arrived in half a minute is not coming.
  LRequest.TimeoutMs := CLI_TIMEOUT_MS;
  LRequest.OutputFilter := ofpStrip;
  GCliBuffer := '';
  LToken := GRequestToken;
  _Log(Format('request: via CLI %s (%s)',
    [LRequest.Executor, TPath.GetFileName(APath)]));
  TInterlocked.Increment(GInFlight);
  try
    GCliRun := TCLIDispatcher.Create.Dispatch(LRequest,
      procedure(const AChunk: string)
      begin
        GCliBuffer := GCliBuffer + AChunk;
      end,
      procedure(const AExitCode: Integer; const ADurationMs: Cardinal)
      begin
        TInterlocked.Decrement(GInFlight);
        GCliRun := nil;
        if GShuttingDown then
          Exit;
        _Log(Format('reply: CLI finished exit=%d in %dms, %d chars',
          [AExitCode, ADurationMs, Length(GCliBuffer)]));
        if AExitCode <> 0 then
          _ApplyReply('', Format('the CLI exited with %d', [AExitCode]),
            AFileName, ALineText, ASuffix, ALine, AColumn, LToken)
        else
          _ApplyCliReply(GCliBuffer, AFileName, ALineText, ASuffix, ALine,
            AColumn, LToken);
      end,
      procedure(const AMessage: string)
      begin
        TInterlocked.Decrement(GInFlight);
        GCliRun := nil;
        if GShuttingDown then
          Exit;
        _ApplyReply('', AMessage, AFileName, ALineText, ASuffix, ALine, AColumn,
          LToken);
      end);
  except
    on E: Exception do
    begin
      TInterlocked.Decrement(GInFlight);
      GCliRun := nil;
      GPending.Active := False;
      _Log('request: ABORT the CLI would not start: ' + E.Message);
      _InvalidateTop;
    end;
  end;
end;

procedure _RequestSuggestion;
var
  LText, LFile, LLineText: string;
  LOffset, LLine, LColumn: Integer;
  LPrefix, LSuffix, LModel, LBody: string;
  LThread: TGhostRequestThread;
  LEditorServices: IOTAEditorServices;
  LKind: TExecutorKind;
  LExecutorPath: string;
  LExecutorModel: string;
  LHasExecutor: Boolean;
  LUseCli: Boolean;
begin
  if GShuttingDown or (not GSettings.Enabled) then
    Exit;
  _ClearGhost;
  // WHICH BACKEND. The user's chat executor decides, because that is the one
  // thing they have already configured -- and for most of them it is not
  // Ollama. Before this branch existed the feature was inert for anyone without
  // a local model installed, which is nearly everyone who installs Aefos.
  LHasExecutor := _ConfiguredExecutor(LKind, LExecutorPath, LExecutorModel);
  LUseCli := LHasExecutor and (LKind <> ekOllama) and (LExecutorPath <> '');
  LModel := _ResolveModel;
  if (not LUseCli) and (LModel = '') then
  begin
    _Log('request: ABORT no local model and no CLI executor configured');
    Exit;
  end;
  if not _ReadActiveEditor(LText, LFile, LLineText, LOffset, LLine, LColumn) then
  begin
    _Log('request: ABORT could not read the active editor');
    Exit;
  end;
  if Supports(BorlandIDEServices, IOTAEditorServices, LEditorServices) and
     _HasSelection(LEditorServices.TopView) then
  begin
    // Selected code is code the user is doing something else with, and Tab
    // there means block indent.
    _Log('request: ABORT there is a selection');
    Exit;
  end;
  if LUseCli then
    _Log(Format('request: executor=%s file=%s line=%d col=%d linelen=%d doclen=%d',
      [TProviderRegistry.ExecutorKindToString(LKind), TPath.GetFileName(LFile),
       LLine, LColumn, Length(LLineText), Length(LText)]))
  else
    _Log(Format('request: model=%s file=%s line=%d col=%d linelen=%d doclen=%d',
      [LModel, TPath.GetFileName(LFile), LLine, LColumn, Length(LLineText), Length(LText)]));
  // Refuse before spending a request: the policy would reject a mid-line caret
  // anyway, because the user's own text occupies the space the ghost needs.
  if (LColumn >= 1) and (LColumn <= Length(TrimRight(LLineText))) then
  begin
    _Log('request: ABORT caret is not at the end of the line');
    Exit;
  end;
  LPrefix := TAefosInlineCompletion.BuildPrefix(LText, LOffset);
  LSuffix := TAefosInlineCompletion.BuildSuffix(LText, LOffset);
  // The "working" marker goes up for BOTH backends, and it matters more on the
  // CLI one: four seconds of nothing is indistinguishable from a dead key.
  GPending.FileName := LFile;
  GPending.Line := LLine;
  GPending.Column := LColumn;
  GPending.Token := GRequestToken;
  GPending.Active := True;
  _InvalidateTop;
  if LUseCli then
  begin
    _RequestViaCli(LKind, LExecutorPath, LExecutorModel, LPrefix, LSuffix, LFile,
      LLineText, LLine, LColumn);
    Exit;
  end;
  // AStopAtNewline = False on purpose: a leading newline is how the model says
  // the answer belongs on a NEW line, and stopping there truncated exactly that
  // token -- every complete line came back empty.
  LBody := OllamaBuildGenerateRequest(LModel, LPrefix, LSuffix,
    INLINE_MAX_TOKENS, INLINE_TEMPERATURE, False, INLINE_KEEP_ALIVE_SECONDS);
  _Log(Format('request: POST %s (prefix %d, suffix %d chars)',
    [OllamaGenerateEndpoint(_ResolveBaseUrl), Length(LPrefix), Length(LSuffix)]));
  LThread := TGhostRequestThread.Create(OllamaGenerateEndpoint(_ResolveBaseUrl),
    LBody, LFile, LLine, LColumn, LLineText, LSuffix);
  // Counted BEFORE the start, or the worker could finish and decrement before
  // we ever incremented. Balanced by Execute, or by the handler below when the
  // worker never gets to run at all.
  TInterlocked.Increment(GInFlight);
  try
    LThread.Start;
  except
    on E: Exception do
    begin
      // Nothing will run and nothing will answer, so say so instead of leaving
      // a "..." on screen forever, and give teardown its count back -- it waits
      // on GInFlight and would otherwise sit out the whole drain for a thread
      // that does not exist.
      TInterlocked.Decrement(GInFlight);
      GPending.Active := False;
      _Log('request: ABORT the worker would not start: ' + E.Message);
      _InvalidateTop;
    end;
  end;
end;

procedure _AcceptGhost;
var
  LServices: IOTAEditorServices;
  LView: IOTAEditView;
  LBuffer: IOTAEditBuffer;
  LWriter: IOTAEditWriter;
  LPosition: IOTAEditPosition;
  LDoc, LFile, LLineText: string;
  LOffset, LLine, LColumn: Integer;
  LText: string;
  LScan: Integer;
  LBytePos: Integer;
  LLastRow: Integer;
  LLastCol: Integer;
  // A SNAPSHOT of the suggestion, taken before a single byte is written.
  //
  // Everything below the write used to read GState directly, and that was an
  // access violation waiting to happen -- it fired live, "Read of address
  // FFFFFFFC" (2026-08-04), which is a nil dynamic array indexed at [-1].
  // The cause is re-entrancy on ONE thread: writing to the buffer makes the
  // editor repaint, the repaint calls our own PaintLine, PaintLine sees that the
  // caret has moved off the suggestion and calls _ClearGhost -- which nils
  // GState.Lines while _AcceptGhost is still in the middle of using it.
  //   So the accept path stops touching GState the moment it starts writing.
  LLines: TArray<string>;
  LGhostLine: Integer;
  LGhostColumn: Integer;
  LNewLine: Boolean;
begin
  if not GState.Showing then
    Exit;
  if not Supports(BorlandIDEServices, IOTAEditorServices, LServices) then
    Exit;
  LView := LServices.TopView;
  if (LView = nil) or (LView.Buffer = nil) then
    Exit;
  LBuffer := LView.Buffer;
  LLines := Copy(GState.Lines);
  LGhostLine := GState.Line;
  LGhostColumn := GState.Column;
  LNewLine := GState.NewLine;
  if Length(LLines) = 0 then
  begin
    _Log('accept: ABORT the suggestion is empty');
    Exit;
  end;
  LText := '';
  for LScan := 0 to High(LLines) do
  begin
    if LScan > 0 then
      LText := LText + sLineBreak;
    LText := LText + LLines[LScan];
  end;
  if LNewLine then
    LText := sLineBreak + LText;
  _Log(Format('accept: line=%d col=%d newline=%s lines=%d text=[%s]',
    [LGhostLine, LGhostColumn, BoolToStr(LNewLine, True),
     Length(LLines), StringReplace(LText, sLineBreak, '\n', [rfReplaceAll])]));
  // Written through an EDIT WRITER, not through IOTAEditPosition.InsertText.
  //
  // InsertText behaves like typing, so the editor's AUTO-INDENT fires on every
  // line break in the text -- it copies the previous line's indentation and our
  // block brings its own on top of that, so a five-line suggestion came out as a
  // staircase, each line one level deeper than the last (owner screenshot,
  // 2026-08-04). The block is not keystrokes; it is text going in at an offset,
  // exactly as the model wrote it. CreateUndoableWriter is still ONE undo step,
  // so Ctrl+Z takes the whole suggestion back out.
  if not _ReadActiveEditor(LDoc, LFile, LLineText, LOffset, LLine, LColumn) then
  begin
    _Log('accept: ABORT could not re-read the editor');
    Exit;
  end;
  // The suggestion belongs to a caret that must still be the caret. Re-read
  // rather than trusting the stored offset: the buffer can have changed under
  // us between the reply and this keypress.
  if (not SameText(LFile, GState.FileName)) or (LLine <> LGhostLine) or
     (LColumn <> LGhostColumn) then
  begin
    _Log('accept: ABORT the buffer moved under the suggestion');
    _ClearGhost;
    _InvalidateTop;
    Exit;
  end;
  // The writer counts BYTES of the UTF-8 buffer; everything above counts
  // characters. Converting through the actual prefix is the only way that stays
  // right for a file with accents in it -- and this codebase has burned on that
  // before.
  // The caret line AS IT IS, verbatim, next to the text about to go in. Without
  // this pair a report of "the indentation broke" cannot be diagnosed from the
  // log: the two ways it can break -- a block appended to a line that already
  // has code on it, and a first line whose own leading spaces land on top of
  // whitespace already there -- look identical from the inserted text alone.
  _Log(Format('accept: caret line was [%s] (len=%d, col=%d, offset=%d)',
    [LLineText, Length(LLineText), LColumn, LOffset]));
  LBytePos := Length(UTF8Encode(Copy(LDoc, 1, LOffset - 1)));
  LWriter := LBuffer.CreateUndoableWriter;
  if LWriter = nil then
  begin
    _Log('accept: ABORT no edit writer');
    Exit;
  end;
  try
    LWriter.CopyTo(LBytePos);
    LWriter.Insert(PAnsiChar(UTF8Encode(LText)));
  finally
    LWriter := nil; // flush before the caret is moved
  end;
  // Land the caret at the end of what was just inserted, the way accepting a
  // completion should leave you: ready to keep typing after it.
  // From the SNAPSHOT only. GState may already have been cleared by a repaint
  // that our own write provoked -- see the note on LLines above.
  LLastRow := LGhostLine + High(LLines);
  if LNewLine then
    Inc(LLastRow);
  if (Length(LLines) = 1) and not LNewLine then
    LLastCol := LGhostColumn + Length(LLines[0])
  else
    LLastCol := Length(LLines[High(LLines)]) + 1;
  LPosition := LBuffer.EditPosition;
  if LPosition = nil then
    // The text IS in. Only the caret placement was lost -- say so, rather than
    // ending the log after "accept: line=..." and leaving the next reader to
    // wonder whether anything happened at all.
    _Log('accept: text written, but no edit position to move the caret with')
  else
  begin
    LPosition.Move(LLastRow, LLastCol);
    _Log(Format('accept: done, caret now line=%d col=%d',
      [LPosition.Row, LPosition.Column]));
  end;
  _ClearGhost;
  _InvalidateTop;
end;

{ TGhostRequestThread }

constructor TGhostRequestThread.Create(const AUrl, ABody, AFileName: string;
  const ALine, AColumn: Integer; const ALineText, ASuffix: string);
begin
  // SUSPENDED, and started by the CALLER -- never from in here.
  //
  // Create(False) is wrong for the obvious reason (Execute would run before the
  // fields below are assigned, so the worker could POST an empty URL and body).
  // But Create(True) followed by Start *inside the constructor* is wrong too,
  // and it is a much nastier kind of wrong -- it is what broke this feature
  // outright (2026-08-04):
  //
  //   Start sets FCreateSuspended := False. The compiler then calls
  //   AfterConstruction as the constructor returns, and TThread.AfterConstruction
  //   (System.Classes.pas 16590) reads: "if not FCreateSuspended ... then
  //   InternalStart(True)". InternalStart calls ResumeThread on a thread that is
  //   already running, gets a suspend count that is not 1, and RAISES
  //   EThread('Thread start error'). The exception escapes the constructor, so
  //   the compiler destroys the half-delivered object -- which Terminates and
  //   WaitFors the worker and strips its queued reply.
  //
  // Net effect: EVERY request was started and then immediately killed. From the
  // keyboard it looked like a dead shortcut (the handler's except swallowed the
  // EThread); from the automatic timer, which had no except, it reached the IDE
  // as a crash dialog.
  inherited Create(True);
  FreeOnTerminate := True;
  FUrl := AUrl;
  FBody := ABody;
  FFileName := AFileName;
  FLine := ALine;
  FColumn := AColumn;
  FLineText := ALineText;
  FSuffix := ASuffix;
  FToken := GRequestToken;
end;

// Runs on the MAIN thread with values copied out of the worker. A unit-local
// routine on purpose: it must not be reachable through a thread instance that
// may already be freed.
procedure _ApplyReply(const AReply, AError, AFileName, ALineText,
  ASuffix: string; const ALine, AColumn, AToken: Integer);
var
  LSuggestion: TInlineSuggestion;
begin
  // A reply for a caret the user already left. Dropping it is the difference
  // between a ghost that follows you and one that pops up behind your back.
  if AToken <> GRequestToken then
  begin
    // A stale reply must NOT clear the indicator: a newer request is still in
    // flight and the user is still waiting for it.
    _Log('reply: dropped, stale token');
    Exit;
  end;
  // Whatever the outcome -- shown, refused or failed -- the waiting is over.
  if GPending.Token = AToken then
  begin
    GPending.Active := False;
    _InvalidateTop;
  end;
  if AError <> '' then
  begin
    // NOT silent any more. It used to be, on the theory that a completion which
    // did not come is not an error the user asked about -- and that theory cost
    // a live session: the model was simply not installed, the server said so in
    // 25ms, and the feature looked like a model with nothing to suggest.
    _Log('reply: ERROR ' + AError);
    OutputDebugString(PChar('[Aefos] inline completion: ' + AError));
    GNotice.Text := _NoticeFor(AError);
    GNotice.FileName := AFileName;
    GNotice.Line := ALine;
    GNotice.Column := AColumn;
    GNotice.Active := True;
    _InvalidateTop;
    Exit;
  end;
  LSuggestion := TAefosInlineCompletion.Sanitize(AReply, ALineText, AColumn,
    ASuffix);
  if not LSuggestion.Accepted then
  begin
    _Log('reply: REFUSED ' + TAefosInlineCompletion.ReasonToken(LSuggestion.Reason) +
      '  raw=[' + Copy(AReply, 1, 80) + ']');
    OutputDebugString(PChar('[Aefos] inline completion refused: ' +
      TAefosInlineCompletion.ReasonToken(LSuggestion.Reason)));
    // SAY so. A refusal used to paint nothing, which is fine after 300ms and
    // indefensible after twelve seconds on a CLI: the user pressed a key, waited,
    // and got a screen identical to the one where the shortcut is broken. Two of
    // three live CLI requests came back with nothing to offer (2026-08-04), so
    // this is the common case, not the edge one.
    GNotice.Text := '  [Aefos: nothing to suggest here]';
    GNotice.FileName := AFileName;
    GNotice.Line := ALine;
    GNotice.Column := AColumn;
    GNotice.Active := True;
    _InvalidateTop;
    Exit;
  end;
  GState.Lines := LSuggestion.Lines;
  GState.NewLine := LSuggestion.NewLine;
  GState.Truncated := LSuggestion.Truncated;
  GState.FileName := AFileName;
  GState.Line := ALine;
  GState.Column := AColumn;
  // Line 0 goes on the caret line; the rest need a real line each, and the
  // editor will not paint past the end of the file. Clamped HERE, once, so the
  // painter never has to ask and the "+n more" count is honest.
  GState.VisibleLines := Min(Min(Length(LSuggestion.Lines), INLINE_MAX_LINES),
    1 + Max(0, _TotalLines - ALine));
  GState.Showing := True;
  _Log(Format('reply: SHOWING %d line(s), %d paintable, truncated=%s  first=[%s]',
    [Length(LSuggestion.Lines), GState.VisibleLines,
     BoolToStr(LSuggestion.Truncated, True),
     TAefosInlineCompletion.FirstLine(LSuggestion)]));
  _InvalidateTop;
end;

procedure TGhostRequestThread.Execute;
var
  LStatus: Integer;
  LResponse: string;
  LRaw: string;
  LErr: string;
  LReply: string;
  LError: string;
  // Copies captured by the closure below. They must be LOCALS, not fields:
  // capturing a field would capture Self, and Self can be freed before the
  // queued closure runs (FreeOnTerminate).
  LFileName: string;
  LLineText: string;
  LSuffix: string;
  LLine: Integer;
  LColumn: Integer;
  LToken: Integer;
begin
  LReply := '';
  LError := '';
  try
    // A non-200 is an ERROR, and saying so is the whole point. It used to fall
    // into the same branch as a transport failure, whose LErr is empty for an
    // answered request -- so the caller got an empty reply and reported
    // "inline-empty", i.e. "the model had nothing to suggest".
    //   That cost a live session (2026-08-04): Ollama was answering
    //   404 {"error":"model 'qwen2.5-coder:14b' not found"} in 25ms and the
    // feature looked like a model with no opinions. A diagnostic that turns a
    // configuration error into a shrug is worse than no diagnostic.
    if not TAefosHttp.TryPostText(FUrl, FBody, 'application/json',
      REQUEST_TIMEOUT_MS, LStatus, LResponse, LErr) then
      LError := LErr
    else if LStatus <> 200 then
      LError := Format('HTTP %d from %s -- %s',
        [LStatus, FUrl, Copy(Trim(LResponse), 1, 300)])
    else if OllamaParseGenerateResponse(LResponse, LRaw, LError) then
      LReply := LRaw;
  except
    on E: Exception do
      LError := E.Message;
  end;
  LFileName := FFileName;
  LLineText := FLineText;
  LSuffix := FSuffix;
  LLine := FLine;
  LColumn := FColumn;
  LToken := FToken;
  // Teardown started while this request was in flight: drop it silently. The
  // queued closure below would otherwise run code from a package that is being
  // unmapped.
  if GShuttingDown then
  begin
    TInterlocked.Decrement(GInFlight);
    Exit;
  end;
  // Queue, not Synchronize: the worker must never block on the IDE thread.
  TThread.Queue(nil,
    procedure
    begin
      if not GShuttingDown then
        _ApplyReply(LReply, LError, LFileName, LLineText, LSuffix, LLine,
          LColumn, LToken);
    end);
  TInterlocked.Decrement(GInFlight);
end;

// Which line of the block, if any, belongs on the logical line being painted --
// -1 for none. ONE answer, shared by the text suppression and the drawing, so
// the two can never disagree: if they did, the user's real code would be hidden
// with nothing drawn in its place, which is the worst thing this feature could
// possibly do to a file.
//   Line 0 sits on the caret line (after the code, or behind the [Enter] marker)
// and line n covers the nth line below it -- which is exactly where the block
// will land when Tab is pressed.
function _GhostIndexFor(const Context: INTACodeEditorPaintContext): Integer;
var
  LView: IOTAEditView;
  LIndex: Integer;
begin
  Result := -1;
  if not GState.Showing then
    Exit;
  // Arithmetic first, COM calls after: this runs for every visible line -- and
  // for every syntax run inside them -- on every repaint, caret blink included.
  LIndex := Context.LogicalLineNum - GState.Line;
  if (LIndex < 0) or (LIndex >= GState.VisibleLines) or
     (LIndex > High(GState.Lines)) then
    Exit;
  if not SameText(Context.FileName, GState.FileName) then
    Exit;
  LView := Context.EditView;
  if (LView = nil) or (LView.CursorPos.Line <> GState.Line) or
     (LView.CursorPos.Col <> GState.Column) then
    Exit;
  Result := LIndex;
end;

function _CaretAt(const Context: INTACodeEditorPaintContext;
  const ALine, AColumn: Integer): Boolean;
var
  LView: IOTAEditView;
begin
  LView := Context.EditView;
  Result := (LView <> nil) and (LView.CursorPos.Line = ALine) and
            (LView.CursorPos.Col = AColumn);
end;

// True when the caret is no longer where the suggestion was made for. Asked only
// about the file the ghost belongs to: another editor repainting says nothing
// about our caret.
function _CaretMoved(const Context: INTACodeEditorPaintContext): Boolean;
begin
  Result := SameText(Context.FileName, GState.FileName) and
            (Context.EditView <> nil) and
            not _CaretAt(Context, GState.Line, GState.Column);
end;

// APercent of B mixed into A, per channel. TColor is $00BBGGRR, so the channels
// come apart with plain byte arithmetic and no Graphics helper is needed.
function _Blend(const A, B: TColor; const APercent: Integer): TColor;
var
  LA: Cardinal;
  LB: Cardinal;

  function _Mix(const AShift: Integer): Cardinal;
  var
    LX: Integer;
    LY: Integer;
  begin
    LX := (LA shr AShift) and $FF;
    LY := (LB shr AShift) and $FF;
    Result := Cardinal(LX + ((LY - LX) * APercent) div 100) shl AShift;
  end;

begin
  LA := Cardinal(ColorToRGB(A));
  LB := Cardinal(ColorToRGB(B));
  Result := TColor(_Mix(0) or _Mix(8) or _Mix(16));
end;

// The colour to paint a covered line out with.
//   AClean = True at plsBackground, where the line is still bare, so the middle
// of it is background by definition. False at plsEndPaint, where the code is
// already drawn and only the far right is reliably empty -- a fallback, used
// only if the plsBackground sample for this line never arrived.
//   Sampled rather than computed: the editor's background depends on the theme,
// on whether this is the current line, and on any selection. Reading the pixel
// the editor just produced is right by construction and cannot drift out of
// step with a theme API.
function _SampleBackground(const Context: INTACodeEditorPaintContext;
  const ARect: TRect; const AClean: Boolean): TColor;
var
  LCanvas: TCanvas;
  LX: Integer;
  LY: Integer;
begin
  Result := clNone;
  if (not AClean) and (GCoverLine = Context.LogicalLineNum) and
     (GCoverColor <> clNone) then
    Exit(GCoverColor);
  LCanvas := Context.Canvas;
  if LCanvas = nil then
    Exit;
  if AClean then
    LX := (ARect.Left + ARect.Right) div 2
  else
    LX := ARect.Right - 2;
  LY := ARect.Top + (ARect.Bottom - ARect.Top) div 2;
  try
    Result := LCanvas.Pixels[LX, LY];
  except
    // A canvas that will not be read is not worth an exception in a paint
    // handler; the caller falls back to not covering at all.
    Result := clNone;
  end;
  if Result = clNone then
    // Better a wrong-but-solid colour than a smear of two texts on top of each
    // other, which is the exact defect this routine exists to end.
    Result := clWindow;
end;

{ TAefosGhostPainter }

procedure TAefosGhostPainter.PaintLine(const Rect: TRect;
  const Stage: TPaintLineStage; const BeforeEvent: Boolean;
  var AllowDefaultPainting: Boolean;
  const Context: INTACodeEditorPaintContext);
var
  LCanvas: TCanvas;
  LLineState: INTACodeEditorLineState;
  LState: INTACodeEditorState;
  LIndex: Integer;
  LX: Integer;
  LText: string;
  LHidden: Integer;
  LCover: TRect;
  LAccent: TRect;
begin
  AllowDefaultPainting := True;
  if (Context = nil) or BeforeEvent then
    Exit;
  // Remember what the editor just painted this line's background with, while it
  // is still clean. A line the block covers gets that exact colour laid back
  // over its code at plsEndPaint.
  if Stage = plsBackground then
  begin
    if _GhostIndexFor(Context) >= 1 then
    begin
      GCoverLine := Context.LogicalLineNum;
      GCoverColor := _SampleBackground(Context, Rect, True);
    end;
    Exit;
  end;
  if Stage <> plsEndPaint then
    Exit;
  // A suggestion the caret has walked away from must not survive on screen: the
  // lines it covers are only repainted when something invalidates them, and the
  // caret line is repainted the moment the caret leaves. So this is where a
  // stale block gets noticed and the real code gets its rows back.
  if GState.Showing and (Context.LogicalLineNum = GState.Line) and
     _CaretMoved(Context) then
  begin
    _Log('paint: ghost dropped, the caret left it');
    _ClearGhost;
    _InvalidateTop;
    Exit;
  end;
  LText := '';
  LIndex := _GhostIndexFor(Context);
  if LIndex >= 0 then
  begin
    if (LIndex = 0) and GState.NewLine then
      // Says exactly what Tab will do: put in an Enter, then this code.
      LText := NEWLINE_MARKER + GState.Lines[0]
    else
      LText := GState.Lines[LIndex];
    // The last row we get to paint has to admit what is not on screen, or the
    // block reads as if the model stopped there. Those lines are NOT lost --
    // Tab inserts the whole suggestion, painted or not.
    if LIndex = GState.VisibleLines - 1 then
    begin
      LHidden := Length(GState.Lines) - GState.VisibleLines;
      if LHidden > 0 then
        LText := LText + Format(MORE_MARKER, [LHidden]);
    end;
  end
  else if GPending.Active and (Context.LogicalLineNum = GPending.Line) and
          SameText(Context.FileName, GPending.FileName) then
    // Nothing is offered yet, but the user must be able to see that their key
    // did something. A silent refusal looks exactly like a dead shortcut.
    LText := PENDING_MARKER
  else if GNotice.Active and (Context.LogicalLineNum = GNotice.Line) and
          SameText(Context.FileName, GNotice.FileName) and
          _CaretAt(Context, GNotice.Line, GNotice.Column) then
    // Only while the caret is still where the request was made, so the note
    // retires by itself the moment the user moves on.
    LText := GNotice.Text;
  // A BORROWED line goes on even with nothing to write on it. A suggestion is
  // allowed to contain a blank line -- a block that separates its parts usually
  // does -- and bailing out here left that row unpainted, so the user's real
  // code showed through a hole in the middle of the card, syntax-coloured, as if
  // the block had been interrupted (owner screenshot, 2026-08-04).
  if (LText = '') and (LIndex < 1) then
    Exit;
  LCanvas := Context.Canvas;
  if LCanvas = nil then
    Exit;
  // Where to start drawing. Line 0 sits AFTER the real code, so it takes the x
  // from the line's own painted rect and never guesses font metrics. The
  // covering lines start where column 1 starts -- taken from the editor, so a
  // horizontally scrolled view still lines up.
  LX := Rect.Left;
  if LIndex >= 1 then
  begin
    LState := Context.EditorState;
    if LState <> nil then
      LX := LState.GetCharacterPosPx(1, Context.EditorLineNum).Left;
    // The covered line's own code has to GO, and the editor will not do it for
    // us: PaintText offers an AllowDefaultPainting flag, but setting it False
    // changed nothing on this build -- the user got the suggestion drawn on top
    // of the code, both legible enough to prove neither was readable
    // (screenshot, 2026-08-04). So the code area is painted out here, with the
    // colour the editor itself used a moment ago.
    //   From the code's left edge only: filling the whole Rect would wipe the
    // gutter -- line numbers, breakpoints, the change bar.
    LCover := Rect;
    if LState <> nil then
      LCover.Left := LState.GetCodeLeftEdge;
    if LCover.Left < Rect.Left then
      LCover.Left := Rect.Left;
    LCanvas.Brush.Style := bsSolid;
    LCanvas.Brush.Color := _Blend(_SampleBackground(Context, Rect, False),
      GHOST_ACCENT_COLOR, GHOST_TINT_PERCENT);
    LCanvas.FillRect(LCover);
    // ... and then make it look BORROWED rather than lost: an accent down the
    // left, a rule across the top of the first borrowed line and across the
    // bottom of the last. Those three strokes are what turn "my code vanished"
    // into "something is sitting on top of my code".
    LCanvas.Brush.Color := GHOST_ACCENT_COLOR;
    LAccent := LCover;
    LAccent.Right := LAccent.Left + GHOST_ACCENT_WIDTH;
    LCanvas.FillRect(LAccent);
    if LIndex = 1 then
    begin
      LAccent := LCover;
      LAccent.Bottom := LAccent.Top + 1;
      LCanvas.FillRect(LAccent);
    end;
    if LIndex = GState.VisibleLines - 1 then
    begin
      LAccent := LCover;
      LAccent.Top := LAccent.Bottom - 1;
      LCanvas.FillRect(LAccent);
    end;
  end
  else
  begin
    LLineState := Context.LineState;
    if LLineState <> nil then
      LX := LLineState.GetVisibleTextRect.Right;
  end;
  if LText = '' then
    Exit; // a blank line of the block: the cover above is the whole job
  LCanvas.Brush.Style := bsClear;
  // Reset explicitly: the canvas arrives carrying whatever the last syntax token
  // on this line used, so without this the ghost inherits bold comments or
  // italic keywords at random.
  LCanvas.Font.Style := [];
  LCanvas.Font.Color := GHOST_COLOR;
  LCanvas.TextOut(LX, Rect.Top, LText);
end;

procedure TAefosGhostPainter.PaintGutter(const Rect: TRect;
  const Stage: TPaintGutterStage; const BeforeEvent: Boolean;
  var AllowDefaultPainting: Boolean;
  const Context: INTACodeEditorPaintContext);
begin
  AllowDefaultPainting := True;
end;

procedure TAefosGhostPainter.PaintText(const Rect: TRect;
  const ColNum: SmallInt; const Text: string; const SyntaxCode: TOTASyntaxCode;
  const Hilight, BeforeEvent: Boolean; var AllowDefaultPainting: Boolean;
  const Context: INTACodeEditorPaintContext);
begin
  // Nothing. This was where the covered lines' own text was going to be
  // suppressed -- ToolsAPI.Editor documents AllowDefaultPainting as "skip the
  // IDE's default text painting" while BeforeEvent is True -- and on this build
  // setting it False changed NOTHING: the suggestion came out drawn on top of
  // the code (screenshot, 2026-08-04). PaintLine paints the line out itself
  // instead, so this event is not even subscribed to any more.
  AllowDefaultPainting := True;
end;

function TAefosGhostPainter.AllowedEvents: TCodeEditorEvents;
begin
  Result := [cevPaintLineEvents];
end;

function TAefosGhostPainter.AllowedGutterStages: TPaintGutterStages;
begin
  Result := [];
end;

function TAefosGhostPainter.AllowedLineStages: TPaintLineStages;
begin
  // plsBackground to SAMPLE the line's clean background, plsEndPaint to lay it
  // back over the code and draw the ghost on top.
  Result := [plsBackground, plsEndPaint];
end;

function TAefosGhostPainter.UIOptions: TCodeEditorUIOptions;
begin
  Result := [];
end;

procedure TAefosGhostPainter.EditorScrolled(const Editor: TWinControl;
  const Direction: TCodeEditorScrollDirection);
begin
end;

procedure TAefosGhostPainter.EditorResized(const Editor: TWinControl);
begin
end;

procedure TAefosGhostPainter.EditorElided(const Editor: TWinControl;
  const LogicalLineNum: Integer);
begin
end;

procedure TAefosGhostPainter.EditorUnElided(const Editor: TWinControl;
  const LogicalLineNum: Integer);
begin
end;

procedure TAefosGhostPainter.EditorMouseDown(const Editor: TWinControl;
  Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
end;

procedure TAefosGhostPainter.EditorMouseMove(const Editor: TWinControl;
  Shift: TShiftState; X, Y: Integer);
begin
end;

procedure TAefosGhostPainter.EditorMouseUp(const Editor: TWinControl;
  Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
end;

procedure TAefosGhostPainter.BeginPaint(const Editor: TWinControl;
  const ForceFullRepaint: Boolean);
begin
end;

procedure TAefosGhostPainter.EndPaint(const Editor: TWinControl);
begin
end;

procedure TAefosGhostPainter.AfterSave;
begin
end;

procedure TAefosGhostPainter.BeforeSave;
begin
end;

procedure TAefosGhostPainter.Destroyed;
begin
end;

procedure TAefosGhostPainter.Modified;
begin
end;

{ TAefosGhostBinding }

function TAefosGhostBinding.GetBindingType: TBindingType;
begin
  Result := btPartial;
end;

function TAefosGhostBinding.GetDisplayName: string;
begin
  Result := BINDING_DISPLAY;
end;

function TAefosGhostBinding.GetName: string;
begin
  Result := BINDING_NAME;
end;

procedure TAefosGhostBinding.BindKeyboard(
  const ABindingServices: IOTAKeyBindingServices);
var
  LRequest: TShortCut;
begin
  // The request key is the user's, from Tools > Options. It is now the ONLY way
  // the feature is invoked -- see the note on automatic mode in the unit header.
  LRequest := TextToShortCut(GSettings.Shortcut);
  if LRequest = 0 then
    LRequest := TextToShortCut(TAefosFlowConfigStore.INLINE_DEFAULT_SHORTCUT);
  if LRequest <> 0 then
    ABindingServices.AddKeyBinding([LRequest], _OnRequest, nil);
  // Tab and Esc are bound UNCONDITIONALLY here because a binding cannot be
  // added and removed per suggestion -- the handlers themselves decide, and
  // they hand the key back untouched whenever no ghost is showing.
  ABindingServices.AddKeyBinding([TextToShortCut(ACCEPT_SHORTCUT)],
    _OnAccept, nil);
  ABindingServices.AddKeyBinding([TextToShortCut(DISMISS_SHORTCUT)],
    _OnDismiss, nil);
end;

procedure TAefosGhostBinding._OnRequest(const AContext: IOTAKeyContext;
  AKeyCode: TShortcut; var ABindingResult: TKeyBindingResult);
begin
  ABindingResult := krHandled;
  _Log('request: key pressed');
  try
    _RequestSuggestion;
  except
    // Goes to the FILE, not only to OutputDebugString. This handler hid a fatal
    // defect for a whole day: every keypress raised EThread here and the user
    // saw a shortcut that "did nothing", with the reason visible only to someone
    // already attached with a debugger.
    on E: Exception do
    begin
      GPending.Active := False;
      _Log('request: FAILED ' + E.ClassName + ': ' + E.Message);
      OutputDebugString(PChar('[Aefos] inline request: ' + E.Message));
    end;
  end;
end;

procedure TAefosGhostBinding._OnAccept(const AContext: IOTAKeyContext;
  AKeyCode: TShortcut; var ABindingResult: TKeyBindingResult);
var
  LView: IOTAEditView;
  LServices: IOTAEditorServices;
begin
  // THE careful one. Tab belongs to the editor unless a ghost is showing for
  // exactly this caret; every other case falls through untouched.
  ABindingResult := krUnhandled;
  if not GState.Showing then
    Exit;
  _Log('accept: Tab pressed while a ghost is showing');
  if not Supports(BorlandIDEServices, IOTAEditorServices, LServices) then
    Exit;
  LView := LServices.TopView;
  if (LView = nil) or (LView.Buffer = nil) then
    Exit;
  if not SameText(LView.Buffer.FileName, GState.FileName) then
    Exit;
  if _HasSelection(LView) then
  begin
    // Tab here is BLOCK INDENT. Hand it straight back -- taking it would be the
    // feature breaking an editor command the user has used for thirty years.
    _Log('accept: DECLINED there is a selection, Tab belongs to block indent');
    Exit;
  end;
  if (LView.CursorPos.Line <> GState.Line) or
     (LView.CursorPos.Col <> GState.Column) then
  begin
    // The caret moved away: the suggestion is stale, drop it AND give Tab back.
    _Log(Format('accept: DECLINED caret moved (now %d:%d, ghost %d:%d)',
      [LView.CursorPos.Line, LView.CursorPos.Col, GState.Line, GState.Column]));
    _ClearGhost;
    _InvalidateTop;
    Exit;
  end;
  ABindingResult := krHandled;
  try
    _AcceptGhost;
  except
    // To the FILE, like the request path. An accept that half-worked and threw
    // left no trace here at all, and the missing "accept: done" line was the
    // only clue that anything had gone wrong (2026-08-04).
    on E: Exception do
    begin
      _Log('accept: FAILED ' + E.ClassName + ': ' + E.Message);
      OutputDebugString(PChar('[Aefos] inline accept: ' + E.Message));
    end;
  end;
end;

procedure TAefosGhostBinding._OnDismiss(const AContext: IOTAKeyContext;
  AKeyCode: TShortcut; var ABindingResult: TKeyBindingResult);
begin
  // Same discipline as Tab: Esc closes code-completion popups, aborts things,
  // and is not ours to swallow when there is nothing to dismiss.
  if not GState.Showing then
  begin
    ABindingResult := krUnhandled;
    Exit;
  end;
  ABindingResult := krHandled;
  _ClearGhost;
  _InvalidateTop;
end;

{ Wiring the IDE up and down, one piece at a time.

  Each of the three pieces is installed only while the settings actually want it,
  and each removal follows the unload contract: by index, guarded, never left for
  the IDE to do after the BPL unmaps. }

procedure _EnsurePainter(const AWanted: Boolean);
var
  LEditor: INTACodeEditorServices;
begin
  if AWanted = (GPainterIndex >= 0) then
    Exit;
  LEditor := _EditorServices;
  if LEditor = nil then
    Exit;
  try
    if AWanted then
    begin
      GPainterIndex := LEditor.AddEditorEventsNotifier(TAefosGhostPainter.Create);
      _Log(Format('wiring: painter ON (index=%d)', [GPainterIndex]));
    end
    else
    begin
      LEditor.RemoveEditorEventsNotifier(GPainterIndex);
      GPainterIndex := -1;
      _Log('wiring: painter OFF');
    end;
  except
    on E: Exception do
      OutputDebugString(PChar('[Aefos] inline ghost painter: ' + E.Message));
  end;
end;

procedure _EnsureBindings(const AWanted: Boolean);
var
  LKeyboard: IOTAKeyboardServices;
begin
  if AWanted = (GBindingIndex >= 0) then
    Exit;
  if not Supports(BorlandIDEServices, IOTAKeyboardServices, LKeyboard) then
    Exit;
  try
    if AWanted then
    begin
      // BindKeyboard reads GSettings, so the caller must have refreshed it.
      GBindingIndex := LKeyboard.AddKeyboardBinding(TAefosGhostBinding.Create);
      _Log(Format('wiring: keys ON (index=%d, request=%s)',
        [GBindingIndex, GSettings.Shortcut]));
    end
    else
    begin
      // *** Read Aefos.OTA.Chat.UnloadContract before touching this. *** The IDE
      // does NOT reliably unregister a package's bindings before the BPL
      // unmaps; that belief WAS the chronic AV.
      LKeyboard.RemoveKeyboardBinding(GBindingIndex);
      GBindingIndex := -1;
      _Log('wiring: keys OFF');
    end;
  except
    on E: Exception do
      OutputDebugString(PChar('[Aefos] inline ghost binding: ' + E.Message));
  end;
end;

{ TAefosInlineGhost }

class procedure TAefosInlineGhost.ApplySettings;
var
  LWasShortcut: string;
begin
  if GShuttingDown then
    Exit;
  LWasShortcut := GSettings.Shortcut;
  GSettings.Enabled := TAIFlowOptions.InlineCompletionEnabled;
  GSettings.Shortcut := TAIFlowOptions.InlineCompletionShortcut;
  // OFF means OFF: the painter and the keys come out of the IDE entirely, so a
  // user who does not want this feature pays nothing for it -- not a per-line
  // paint callback, not a claim on Tab. That is the whole point of the switch.
  if not GSettings.Enabled then
  begin
    _ClearGhost;
    _EnsureBindings(False);
    _EnsurePainter(False);
    _InvalidateTop;
    Exit;
  end;
  // A binding cannot be edited in place -- to change the key, take it out and
  // put it back.
  if (GBindingIndex >= 0) and (LWasShortcut <> GSettings.Shortcut) then
    _EnsureBindings(False);
  _EnsurePainter(True);
  _EnsureBindings(True);
end;

class procedure TAefosInlineGhost.RegisterSelf;
begin
  if GRegistered then
    Exit;
  GRegistered := True;
  ApplySettings;
  // Pushed, not polled: the AI Flow page tells us the moment it has persisted a
  // change, so Tools > Options takes effect without an IDE restart and nothing
  // reads the config file on a timer. Cleared in UnregisterSelf -- a closure
  // living in another package's global while THIS package unmaps is the exact
  // dangling-reference family the unload contract exists for.
  TAIFlowOptions.SetSettingsChangedHandler(
    procedure
    begin
      TAefosInlineGhost.ApplySettings;
    end);
end;

class procedure TAefosInlineGhost.UnregisterSelf;
var
  LKeyboard: IOTAKeyboardServices;
  LEditor: INTACodeEditorServices;
  LWaited: Integer;
begin
  // Stop accepting work FIRST, then drain. Order matters: marking after the
  // wait would let a keypress start a brand-new request while we are unloading.
  GShuttingDown := True;
  // The Options page holds a closure that lives in THIS package. Drop it before
  // anything else: a dialog accepted while we unload would call into a BPL that
  // is unmapping -- the same family of defect as a stale notifier.
  try
    TAIFlowOptions.SetSettingsChangedHandler(nil);
  except
    on E: Exception do
      OutputDebugString(PChar('[Aefos] inline settings handler: ' + E.Message));
  end;
  // A CLI run is a CHILD PROCESS streaming into closures that live in this BPL.
  // Cancel it before draining, or teardown waits the full 30s CLI timeout for a
  // process nobody wants any more -- and its callbacks fire into unmapped code
  // if the wait gives up first.
  if GCliRun <> nil then
    try
      _Log('teardown: cancelling the CLI run');
      GCliRun.Cancel;
      GCliRun.WaitFor(TEARDOWN_DRAIN_MS);
      GCliRun := nil;
    except
      on E: Exception do
        OutputDebugString(PChar('[Aefos] inline CLI cancel: ' + E.Message));
    end;
  LWaited := 0;
  while (GInFlight > 0) and (LWaited < TEARDOWN_DRAIN_MS) do
  begin
    Sleep(TEARDOWN_POLL_MS);
    Inc(LWaited, TEARDOWN_POLL_MS);
  end;
  if GInFlight > 0 then
    // Bounded, never infinite: an 8s HTTP timeout bounds the worker anyway, and
    // a teardown that waits forever is a hang -- exactly what we are fixing.
    _Log(Format('teardown: %d request(s) still in flight after %dms',
      [GInFlight, LWaited]));
  // *** Read Aefos.OTA.Chat.UnloadContract before touching this. *** Every
  // notifier and binding we hand the IDE is removed by INDEX here, guarded:
  // letting the IDE clean up after the BPL unmaps is what produced the chronic
  // AV at rtl370+100C2, the locked .bpl and the F2039 rebuild failure.
  if (GBindingIndex >= 0) and
     Supports(BorlandIDEServices, IOTAKeyboardServices, LKeyboard) then
    try
      LKeyboard.RemoveKeyboardBinding(GBindingIndex);
    except
      on E: Exception do
        OutputDebugString(PChar('[Aefos] inline RemoveKeyboardBinding: ' + E.Message));
    end;
  GBindingIndex := -1;
  if GPainterIndex >= 0 then
  begin
    LEditor := _EditorServices;
    if LEditor <> nil then
      try
        LEditor.RemoveEditorEventsNotifier(GPainterIndex);
      except
        on E: Exception do
          OutputDebugString(PChar('[Aefos] inline RemoveEditorEventsNotifier: ' +
            E.Message));
      end;
  end;
  GPainterIndex := -1;
  GState.Showing := False;
  GState.Lines := nil;
  GRegistered := False;
end;

initialization

finalization
  // Guarded: an exception escaping finalization aborts the IDE's BPL unload.
  try
    TAefosInlineGhost.UnregisterSelf;
  except // NOSONAR -- teardown must never raise.
  end;

end.
