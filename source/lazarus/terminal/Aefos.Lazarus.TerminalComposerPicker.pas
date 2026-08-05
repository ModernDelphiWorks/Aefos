unit Aefos.Lazarus.TerminalComposerPicker;

{$IFDEF FPC}{$mode delphi}{$H+}{$ENDIF}

{
  Floating "/" command picker for the Lazarus terminal composer (Aefos ->
  Lazarus, terminal AI slice). The LCL twin of the Delphi
  source\terminal\UI\Aefos.OTA.Terminal.UI.ComposerPicker.pas.

  A CHILD CONTROL of the terminal control (a TCustomControl hosting an owner-drawn
  TListBox), NOT a top-level window. It floats ABOVE the composer bar by sitting
  higher in the sibling z-order (BringToFront) and overlaying the terminal grid;
  its Visible toggles show/hide. A child never activates and never steals the
  keyboard the way a popup would, so the focus stays in the composer's WebView
  textarea -- the JS owns the keyboard and posts nav intents ('navdown' /
  'navup' / 'commit' / 'cancel'); this control just renders the filtered list and
  highlights the selection. A mouse click also picks.

  API: SetItems (filtered commands) -> MoveSel / Selected / OnPick. ShowAbove
  places it just above the bar (client coords of the shared parent); HidePicker
  hides it. Owned + parented by the terminal control; no notifiers or keybindings,
  so nothing to unregister at teardown. All literals are ASCII -- no BOM.
}

interface

uses
  Classes,
  SysUtils,
  Types,
  Controls,
  Graphics,
  StdCtrls,
  LCLType,
  Aefos.OTA.Terminal.Core.SlashCommands;

type
  TAefosComposerPickEvent = procedure(Sender: TObject;
    const ACommand: TSlashCommand) of object;

  TAefosLazTerminalComposerPicker = class(TCustomControl)
  private
    FList: TListBox;
    FItems: TArray<TSlashCommand>;
    FOnPick: TAefosComposerPickEvent;
    procedure _DrawItem(Control: TWinControl; Index: Integer; ARect: TRect;
      State: TOwnerDrawState);
    procedure _ListMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
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
    // count (capped). No activation, no focus change -- it is a child control.
    procedure ShowAbove(const ABarBounds: TRect);
    procedure HidePicker;
    function IsShown: Boolean;
    property OnPick: TAefosComposerPickEvent read FOnPick write FOnPick;
  end;

implementation

const
  ROW_H     = 40;   // two-column row: trigger + description
  MAX_ROWS  = 8;    // cap the visible height; the rest scrolls
  PICKER_BG = TColor($001E1E1E);
  ROW_SEL   = TColor($00332A24);  // subtle orange-tinted highlight (BGR)
  CLR_TRIG  = TColor($005C9AFF);  // orange #ff9a5c in BGR
  CLR_DESC  = TColor($009A9A9A);

{ TAefosLazTerminalComposerPicker }

constructor TAefosLazTerminalComposerPicker.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := 320;
  Height := ROW_H;
  Color := PICKER_BG;
  Visible := False;

  FList := TListBox.Create(Self);
  FList.Parent := Self;
  FList.Align := alClient;
  FList.BorderStyle := bsNone;
  FList.Style := lbOwnerDrawFixed;
  FList.ItemHeight := ROW_H;
  FList.Color := PICKER_BG;
  FList.Font.Name := 'Segoe UI';
  FList.Font.Size := 9;
  FList.TabStop := False;
  FList.OnDrawItem := _DrawItem;
  FList.OnMouseUp := _ListMouseUp;
end;

procedure TAefosLazTerminalComposerPicker.Paint;
begin
  // Fill behind the listbox so a resize never flashes the default control color.
  Canvas.Brush.Color := PICKER_BG;
  Canvas.FillRect(ClientRect);
end;

procedure TAefosLazTerminalComposerPicker._DrawItem(Control: TWinControl;
  Index: Integer; ARect: TRect; State: TOwnerDrawState);
var
  LCanvas: TCanvas;
  LCmd: TSlashCommand;
  LX, LTextW: Integer;
begin
  LCanvas := FList.Canvas;
  if (Index < Low(FItems)) or (Index > High(FItems)) then
    Exit;
  LCmd := FItems[Index];

  if odSelected in State then
    LCanvas.Brush.Color := ROW_SEL
  else
    LCanvas.Brush.Color := PICKER_BG;
  LCanvas.FillRect(ARect);

  LX := ARect.Left + 12;
  // Trigger (orange, bold).
  LCanvas.Font.Color := CLR_TRIG;
  LCanvas.Font.Style := [fsBold];
  LCanvas.Brush.Style := bsClear;
  LCanvas.TextOut(LX, ARect.Top + 6, LCmd.Trigger);
  LTextW := LCanvas.TextWidth(LCmd.Trigger);

  // Description (grey, regular) -- same line, to the right of the trigger.
  LCanvas.Font.Color := CLR_DESC;
  LCanvas.Font.Style := [];
  LCanvas.TextOut(LX + LTextW + 12, ARect.Top + 7, LCmd.Description);
  LCanvas.Brush.Style := bsSolid;
end;

procedure TAefosLazTerminalComposerPicker._ListMouseUp(Sender: TObject;
  Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  LCmd: TSlashCommand;
begin
  // A left click already moved FList.ItemIndex to the row under the cursor (default
  // listbox behaviour) before this fires, so read the selection and pick it.
  if Button <> mbLeft then
    Exit;
  if Selected(LCmd) and Assigned(FOnPick) then
    FOnPick(Self, LCmd);
end;

procedure TAefosLazTerminalComposerPicker.SetItems(
  const ACmds: TArray<TSlashCommand>);
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

procedure TAefosLazTerminalComposerPicker.MoveSel(const ADelta: Integer);
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
  // Setting ItemIndex also scrolls the row into view when the list is capped;
  // Invalidate guarantees the selected/deselected rows repaint.
  FList.Invalidate;
end;

function TAefosLazTerminalComposerPicker.Selected(
  out ACommand: TSlashCommand): Boolean;
begin
  Result := (FList.ItemIndex >= Low(FItems)) and
            (FList.ItemIndex <= High(FItems));
  if Result then
    ACommand := FItems[FList.ItemIndex];
end;

function TAefosLazTerminalComposerPicker.ItemCount: Integer;
begin
  Result := Length(FItems);
end;

procedure TAefosLazTerminalComposerPicker.ShowAbove(const ABarBounds: TRect);
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

procedure TAefosLazTerminalComposerPicker.HidePicker;
begin
  if Visible then
    Visible := False;
end;

function TAefosLazTerminalComposerPicker.IsShown: Boolean;
begin
  Result := Visible;
end;

end.
