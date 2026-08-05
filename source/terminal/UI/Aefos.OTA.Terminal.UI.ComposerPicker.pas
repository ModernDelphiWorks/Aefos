unit Aefos.OTA.Terminal.UI.ComposerPicker;

{
  Floating "/" command picker for the Terminal composer. A CHILD CONTROL of the
  DockForm (a TCustomControl hosting an owner-drawn TListBox), NOT a top-level
  window. It floats ABOVE the composer bar by sitting higher in the sibling
  z-order (BringToFront) and overlaying the terminal pane; its Visible toggles
  show/hide.

  Why a child and not a popup: the two hard requirements — (a) PAINT the
  owner-drawn rows, (b) NEVER take activation/focus off the webview textarea —
  are in tension on a top-level window. `Visible := True` on a popup runs
  ShowWindow(SW_SHOW), which ACTIVATES it despite WS_EX_NOACTIVATE (so arrows hit
  the listbox, not the webview); dodging that with SWP_NOACTIVATE then left the
  owner-drawn rows blank. A CHILD control has neither problem: it never activates
  and never steals focus (we simply never SetFocus it), yet it paints like any
  normal VCL control. That removes the entire activation problem class.

  Focus stays in the webview textarea: the composer's JS owns the keyboard and
  posts nav intents ('navdown'/'navup'/'commit'/'cancel'); this control just
  renders the filtered list and highlights the selection. A mouse click also
  picks — and is handled so it does NOT focus the listbox (the WM_LBUTTONDOWN is
  answered without the default SetFocus).

  API: SetItems (filtered commands) -> MoveSel / Selected / OnPick. ShowAbove
  places it just above the bar (client coords of the shared parent); HidePicker
  hides it. Owned + parented by the DockForm; no notifiers or keybindings, so
  nothing to unregister at teardown.
}

interface

uses
  Winapi.Windows,
  Winapi.Messages,
  System.Classes,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.StdCtrls,
  Vcl.Graphics,
  Aefos.OTA.Terminal.Core.SlashCommands;

type
  TComposerPickEvent = procedure(Sender: TObject;
    const ACommand: TSlashCommand) of object;

  // Owner-drawn listbox that, on a mouse click, selects the row under the cursor
  // and fires OnRowPick WITHOUT taking focus. A default TListBox focuses itself on
  // WM_LBUTTONDOWN (via SetFocus), which would pull the keyboard off the webview
  // textarea; we swallow that message, do the selection ourselves, and never chain
  // to inherited, so focus stays where it is.
  TPickerListBox = class(TListBox)
  private
    FOnRowPick: TNotifyEvent;
  protected
    procedure WndProc(var Message: TMessage); override;
  public
    property OnRowPick: TNotifyEvent read FOnRowPick write FOnRowPick;
  end;

  TComposerPickerControl = class(TCustomControl)
  private
    FList: TPickerListBox;
    FItems: TArray<TSlashCommand>;
    FOnPick: TComposerPickEvent;
    procedure _DrawItem(AControl: TWinControl; AIndex: Integer; ARect: TRect;
      AState: TOwnerDrawState);
    procedure _RowPicked(Sender: TObject);
  protected
    procedure Paint; override;
  public
    constructor Create(AOwner: TComponent); override;
    // Replaces the visible items; selects the first row. Empty -> nothing shown.
    procedure SetItems(const ACmds: TArray<TSlashCommand>);
    // Moves the highlighted row (+1 down / -1 up), clamped/wrapped.
    procedure MoveSel(const ADelta: Integer);
    // The highlighted command; returns False when the list is empty.
    function Selected(out ACommand: TSlashCommand): Boolean;
    function ItemCount: Integer;
    // Places the picker just above ABarBounds (the composer bar's BoundsRect, in
    // the shared parent's CLIENT coords) and shows it. Height auto-fits the item
    // count (capped). No activation, no focus change — it is a child control.
    procedure ShowAbove(const ABarBounds: TRect);
    procedure HidePicker;
    function IsShown: Boolean;
    property OnPick: TComposerPickEvent read FOnPick write FOnPick;
  end;

implementation

const
  ROW_H     = 40;   // two lines: trigger + description
  MAX_ROWS  = 8;    // cap the visible height; the rest scrolls
  PICKER_BG = $001E1E1E;
  ROW_SEL   = $00332A24;  // subtle orange-tinted highlight (BGR)
  CLR_TRIG  = $005C9AFF;  // orange #ff9a5c in BGR
  CLR_DESC  = $009A9A9A;

{ TPickerListBox }

procedure TPickerListBox.WndProc(var Message: TMessage);
var
  LIndex: Integer;
begin
  case Message.Msg of
    WM_MOUSEACTIVATE:
      begin
        // Never activate on a click — keep the webview's activation intact.
        Message.Result := MA_NOACTIVATE;
        Exit;
      end;
    WM_LBUTTONDOWN, WM_LBUTTONDBLCLK:
      begin
        LIndex := ItemAtPos(Point(TWMMouse(Message).XPos,
          TWMMouse(Message).YPos), True);
        if LIndex >= 0 then
        begin
          ItemIndex := LIndex;
          Invalidate;
          if Assigned(FOnRowPick) then
            FOnRowPick(Self);
        end;
        // Do NOT call inherited: the default handler would SetFocus this listbox,
        // stealing the keyboard from the webview textarea. Selecting + picking is
        // all we want from a click.
        Exit;
      end;
  end;
  inherited WndProc(Message);
end;

{ TComposerPickerControl }

constructor TComposerPickerControl.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := 320;
  Height := ROW_H;
  Color := PICKER_BG;
  Visible := False;

  FList := TPickerListBox.Create(Self);
  FList.Parent := Self;
  FList.Align := alClient;
  FList.BorderStyle := bsNone;
  FList.Style := lbOwnerDrawFixed;
  FList.ItemHeight := ROW_H;
  FList.Color := PICKER_BG;
  FList.Font.Name := 'Segoe UI';
  FList.Font.Size := 9;
  FList.OnDrawItem := _DrawItem;
  FList.OnRowPick := _RowPicked;
end;

procedure TComposerPickerControl.Paint;
begin
  // Fill behind the listbox so a resize never flashes the default control color.
  Canvas.Brush.Color := PICKER_BG;
  Canvas.FillRect(ClientRect);
end;

procedure TComposerPickerControl._DrawItem(AControl: TWinControl; AIndex: Integer;
  ARect: TRect; AState: TOwnerDrawState);
var
  LCanvas: TCanvas;
  LCmd: TSlashCommand;
  LX, LTextW: Integer;
begin
  LCanvas := FList.Canvas;
  if (AIndex < Low(FItems)) or (AIndex > High(FItems)) then
    Exit;
  LCmd := FItems[AIndex];

  if odSelected in AState then
    LCanvas.Brush.Color := ROW_SEL
  else
    LCanvas.Brush.Color := PICKER_BG;
  LCanvas.FillRect(ARect);

  LX := ARect.Left + 12;
  // Trigger (orange, bold)
  LCanvas.Font.Color := CLR_TRIG;
  LCanvas.Font.Style := [fsBold];
  LCanvas.Brush.Style := bsClear;
  LCanvas.TextOut(LX, ARect.Top + 6, LCmd.Trigger);
  LTextW := LCanvas.TextWidth(LCmd.Trigger);

  // Description (grey, regular) — same line, to the right of the trigger.
  LCanvas.Font.Color := CLR_DESC;
  LCanvas.Font.Style := [];
  LCanvas.TextOut(LX + LTextW + 12, ARect.Top + 7, LCmd.Description);
  LCanvas.Brush.Style := bsSolid;
end;

procedure TComposerPickerControl._RowPicked(Sender: TObject);
var
  LCmd: TSlashCommand;
begin
  if Selected(LCmd) and Assigned(FOnPick) then
    FOnPick(Self, LCmd);
end;

procedure TComposerPickerControl.SetItems(const ACmds: TArray<TSlashCommand>);
var
  LIndex: Integer;
begin
  FItems := ACmds;
  FList.Items.BeginUpdate;
  try
    FList.Items.Clear;
    for LIndex := 0 to High(FItems) do
      FList.Items.Add(FItems[LIndex].Name);
  finally
    FList.Items.EndUpdate;
  end;
  if Length(FItems) > 0 then
    FList.ItemIndex := 0;
end;

procedure TComposerPickerControl.MoveSel(const ADelta: Integer);
var
  LCount, LNew: Integer;
begin
  LCount := Length(FItems);
  if LCount = 0 then
    Exit;
  LNew := FList.ItemIndex + ADelta;
  if LNew < 0 then
    LNew := LCount - 1
  else if LNew >= LCount then
    LNew := 0;
  FList.ItemIndex := LNew;
  // A child listbox repaints the highlight normally — no RedrawWindow hack needed.
  // Invalidate is explicit so the selected/deselected rows are guaranteed to redraw,
  // and setting ItemIndex also scrolls the row into view when the list is capped.
  FList.Invalidate;
end;

function TComposerPickerControl.Selected(out ACommand: TSlashCommand): Boolean;
begin
  Result := (FList.ItemIndex >= Low(FItems)) and
            (FList.ItemIndex <= High(FItems));
  if Result then
    ACommand := FItems[FList.ItemIndex];
end;

function TComposerPickerControl.ItemCount: Integer;
begin
  Result := Length(FItems);
end;

procedure TComposerPickerControl.ShowAbove(const ABarBounds: TRect);
var
  LRows, LHeight: Integer;
begin
  if Length(FItems) = 0 then
  begin
    HidePicker;
    Exit;
  end;
  LRows := Length(FItems);
  if LRows > MAX_ROWS then
    LRows := MAX_ROWS;
  LHeight := LRows * ROW_H + 2;
  // Both this picker and the composer bar are children of the same parent, so
  // ABarBounds (the bar's BoundsRect) is already in our coordinate space: place
  // the picker just above the bar, inset 8px on each side.
  SetBounds(ABarBounds.Left + 8, ABarBounds.Top - LHeight - 2,
    (ABarBounds.Right - ABarBounds.Left) - 16, LHeight);
  BringToFront;
  Visible := True;
  Invalidate;
  FList.Invalidate;
end;

procedure TComposerPickerControl.HidePicker;
begin
  if Visible then
    Visible := False;
end;

function TComposerPickerControl.IsShown: Boolean;
begin
  Result := Visible;
end;

end.
