unit Aefos.Desktop.ReadShape;

{
  Pure shaping helpers for the Aefos Desktop MCP READ tools (feat/desktop-mcp,
  PHASE 4). RTL-only — no UIA, no Winapi, no side effect — so the bounds
  arithmetic and the control-type name mapping are unit-testable headless,
  exactly like Aefos.Desktop.Guard.

  WHY THIS UNIT EXISTS
  --------------------
  desktop_window_tree walks a live UIA element tree and desktop_element_find runs
  a UIA FindAll. Both need two pieces of PURE logic that must not depend on COM:

    * DEPTH / NODE / RESULT CAPS. A raw agent can ask for an unbounded tree; the
      caps keep one call from producing a giant frame (or spinning forever on a
      pathological tree). The clamp turns an arbitrary requested value into a safe
      effective value: <= 0 (or absent) means "use the default"; anything above
      the hard ceiling is capped to the ceiling. Deterministic, so it is tested.

    * CONTROL-TYPE <-> NAME. The tools report a readable control-type string
      ("Button", "Edit", ...) and desktop_element_find accepts one as a filter
      criterion. The id<->name table is a plain integer map (the UIA control-type
      ids are a public, stable Windows ABI), so it lives here, pure, rather than
      inside the COM-bound tool code.

  The UIA control-type ids are transcribed from the public Windows UI Automation
  ABI (UIA_*ControlTypeId, 50000..50040). Aefos.Win.UIAutomation declares the
  subset it calls; this table is the fuller list the read tools surface, kept as
  literal ids here so the mapping is COM-free and testable.
}

interface

uses
  System.SysUtils;

const
  // Tree-walk defaults + hard ceilings. The default is what a caller gets when it
  // does not ask (or asks for <= 0); the ceiling is the most it can ever request.
  DESKTOP_TREE_DEFAULT_DEPTH = 4;
  DESKTOP_TREE_MAX_DEPTH     = 12;
  DESKTOP_TREE_DEFAULT_NODES = 500;
  DESKTOP_TREE_MAX_NODES     = 5000;

  // element_find result cap: default when unspecified, hard ceiling otherwise.
  DESKTOP_FIND_DEFAULT_MAX = 100;
  DESKTOP_FIND_MAX         = 1000;

  // window_capture (PHASE 4b): the longest edge of the EMITTED image. A capture
  // rides back to the model as an inline base64 PNG, so an uncapped 4K window
  // would blow up both the context and the bill; the image is downscaled to fit
  // this box. The floor stops a caller from asking for a useless 3px thumbnail.
  DESKTOP_CAPTURE_DEFAULT_MAX_DIM = 1280;
  DESKTOP_CAPTURE_MAX_DIM         = 2560;
  DESKTOP_CAPTURE_MIN_DIM         = 64;

type
  // The effective, already-clamped limits for one window_tree call.
  TDesktopTreeLimits = record
    MaxDepth: Integer;
    MaxNodes: Integer;
  end;

  // The emitted size of a capture: the source window scaled to fit the max-dim
  // box, aspect preserved. Scaled=False when the window already fits.
  TDesktopCaptureSize = record
    Width: Integer;
    Height: Integer;
    Scaled: Boolean;
  end;

type
  // Static, sealed namespace for the pure READ-tool shaping helpers. Never
  // instantiated (no constructor): every routine is a class function so it has a
  // named owner (e.g. TDesktopReadShape.ClampDepth) instead of floating free in
  // the unit interface. The class IS the namespace, so the old 'Desktop' prefix
  // is gone from the method names.
  TDesktopReadShape = class sealed
  public
    // Clamps a requested depth: <= 0 => the default; above the ceiling => the ceiling.
    class function ClampDepth(ARequested: Integer): Integer; static;

    // Clamps a requested node budget: <= 0 => the default; above the ceiling => the
    // ceiling.
    class function ClampNodes(ARequested: Integer): Integer; static;

    // Both caps at once (window_tree).
    class function ClampTreeLimits(AReqDepth, AReqNodes: Integer): TDesktopTreeLimits; static;

    // Clamps a requested element_find result cap: <= 0 => default; above => ceiling.
    class function ClampFindMax(ARequested: Integer): Integer; static;

    // Clamps a requested capture max-dimension: <= 0 => the default; below the floor
    // => the floor; above the ceiling => the ceiling.
    class function ClampCaptureDim(ARequested: Integer): Integer; static;

    // The emitted size for a source window of ASrcW x ASrcH under a (already clamped
    // or raw — it clamps) max-dimension budget: scaled DOWN to fit the box with the
    // aspect ratio preserved, never scaled UP (a small window is emitted 1:1). Each
    // side is floored at 1px so a sliver window still yields a valid image.
    class function CaptureSizeFor(ASrcW, ASrcH, AReqMaxDim: Integer): TDesktopCaptureSize; static;

    // Maps a UIA control-type id to a short readable name. Unknown => 'Ct#<id>'.
    class function ControlTypeName(AId: Integer): string; static;

    // Resolves a control-type FILTER string to its UIA id. Accepts a readable name
    // ('Button', case-insensitive, with or without the leading 'UIA_'/trailing
    // 'ControlTypeId'), OR a plain integer string ('50000'). Returns False when the
    // text names no known control type and is not a positive integer.
    class function ControlTypeIdFromName(const AName: string; out AId: Integer): Boolean; static;
  end;

implementation

type
  TDesktopCtEntry = record
    Id: Integer;
    Name: string;
  end;

const
  // The public UIA control-type ids (50000..50040), id + canonical short name.
  CControlTypes: array[0..40] of TDesktopCtEntry = (
    (Id: 50000; Name: 'Button'),
    (Id: 50001; Name: 'Calendar'),
    (Id: 50002; Name: 'CheckBox'),
    (Id: 50003; Name: 'ComboBox'),
    (Id: 50004; Name: 'Edit'),
    (Id: 50005; Name: 'Hyperlink'),
    (Id: 50006; Name: 'Image'),
    (Id: 50007; Name: 'ListItem'),
    (Id: 50008; Name: 'List'),
    (Id: 50009; Name: 'Menu'),
    (Id: 50010; Name: 'MenuBar'),
    (Id: 50011; Name: 'MenuItem'),
    (Id: 50012; Name: 'ProgressBar'),
    (Id: 50013; Name: 'RadioButton'),
    (Id: 50014; Name: 'ScrollBar'),
    (Id: 50015; Name: 'Slider'),
    (Id: 50016; Name: 'Spinner'),
    (Id: 50017; Name: 'StatusBar'),
    (Id: 50018; Name: 'Tab'),
    (Id: 50019; Name: 'TabItem'),
    (Id: 50020; Name: 'Text'),
    (Id: 50021; Name: 'ToolBar'),
    (Id: 50022; Name: 'ToolTip'),
    (Id: 50023; Name: 'Tree'),
    (Id: 50024; Name: 'TreeItem'),
    (Id: 50025; Name: 'Custom'),
    (Id: 50026; Name: 'Group'),
    (Id: 50027; Name: 'Thumb'),
    (Id: 50028; Name: 'DataGrid'),
    (Id: 50029; Name: 'DataItem'),
    (Id: 50030; Name: 'Document'),
    (Id: 50031; Name: 'SplitButton'),
    (Id: 50032; Name: 'Window'),
    (Id: 50033; Name: 'Pane'),
    (Id: 50034; Name: 'Header'),
    (Id: 50035; Name: 'HeaderItem'),
    (Id: 50036; Name: 'Table'),
    (Id: 50037; Name: 'TitleBar'),
    (Id: 50038; Name: 'Separator'),
    (Id: 50039; Name: 'SemanticZoom'),
    (Id: 50040; Name: 'AppBar'));

class function TDesktopReadShape.ClampDepth(ARequested: Integer): Integer;
begin
  if ARequested <= 0 then
    Result := DESKTOP_TREE_DEFAULT_DEPTH
  else if ARequested > DESKTOP_TREE_MAX_DEPTH then
    Result := DESKTOP_TREE_MAX_DEPTH
  else
    Result := ARequested;
end;

class function TDesktopReadShape.ClampNodes(ARequested: Integer): Integer;
begin
  if ARequested <= 0 then
    Result := DESKTOP_TREE_DEFAULT_NODES
  else if ARequested > DESKTOP_TREE_MAX_NODES then
    Result := DESKTOP_TREE_MAX_NODES
  else
    Result := ARequested;
end;

class function TDesktopReadShape.ClampTreeLimits(AReqDepth, AReqNodes: Integer): TDesktopTreeLimits;
begin
  Result.MaxDepth := ClampDepth(AReqDepth);
  Result.MaxNodes := ClampNodes(AReqNodes);
end;

class function TDesktopReadShape.ClampFindMax(ARequested: Integer): Integer;
begin
  if ARequested <= 0 then
    Result := DESKTOP_FIND_DEFAULT_MAX
  else if ARequested > DESKTOP_FIND_MAX then
    Result := DESKTOP_FIND_MAX
  else
    Result := ARequested;
end;

class function TDesktopReadShape.ClampCaptureDim(ARequested: Integer): Integer;
begin
  if ARequested <= 0 then
    Result := DESKTOP_CAPTURE_DEFAULT_MAX_DIM
  else if ARequested < DESKTOP_CAPTURE_MIN_DIM then
    Result := DESKTOP_CAPTURE_MIN_DIM
  else if ARequested > DESKTOP_CAPTURE_MAX_DIM then
    Result := DESKTOP_CAPTURE_MAX_DIM
  else
    Result := ARequested;
end;

class function TDesktopReadShape.CaptureSizeFor(ASrcW, ASrcH, AReqMaxDim: Integer): TDesktopCaptureSize;
var
  LMax, LLongest: Integer;
  LScale: Double;
begin
  Result := Default(TDesktopCaptureSize);
  // A degenerate source has no meaningful emitted size; the caller refuses such
  // a window before it gets here, but stay total rather than divide by zero.
  if (ASrcW <= 0) or (ASrcH <= 0) then
    Exit;

  LMax := ClampCaptureDim(AReqMaxDim);
  if ASrcW >= ASrcH then
    LLongest := ASrcW
  else
    LLongest := ASrcH;

  // Never scale UP: a 300px dialog is emitted 1:1, not blown up to the box.
  if LLongest <= LMax then
  begin
    Result.Width := ASrcW;
    Result.Height := ASrcH;
    Result.Scaled := False;
    Exit;
  end;

  LScale := LMax / LLongest;
  Result.Width := Round(ASrcW * LScale);
  Result.Height := Round(ASrcH * LScale);
  if Result.Width < 1 then
    Result.Width := 1;
  if Result.Height < 1 then
    Result.Height := 1;
  Result.Scaled := True;
end;

class function TDesktopReadShape.ControlTypeName(AId: Integer): string;
var
  LIndex: Integer;
begin
  for LIndex := Low(CControlTypes) to High(CControlTypes) do
    if CControlTypes[LIndex].Id = AId then
      Exit(CControlTypes[LIndex].Name);
  Result := 'Ct#' + IntToStr(AId);
end;

class function TDesktopReadShape.ControlTypeIdFromName(const AName: string; out AId: Integer): Boolean;
var
  LText, LNorm: string;
  LIndex, LNum: Integer;
begin
  AId := 0;
  LText := Trim(AName);
  if LText = '' then
    Exit(False);

  // A plain positive integer resolves directly (e.g. '50000').
  if TryStrToInt(LText, LNum) and (LNum > 0) then
  begin
    AId := LNum;
    Exit(True);
  end;

  // Normalise a readable name: drop a leading 'UIA_' and a trailing
  // 'ControlTypeId', lower-case, so 'UIA_ButtonControlTypeId' == 'button'.
  LNorm := LowerCase(LText);
  if Copy(LNorm, 1, 4) = 'uia_' then
    LNorm := Copy(LNorm, 5, Length(LNorm) - 4);
  if (Length(LNorm) > 13) and
     (Copy(LNorm, Length(LNorm) - 12, 13) = 'controltypeid') then
    LNorm := Copy(LNorm, 1, Length(LNorm) - 13);

  for LIndex := Low(CControlTypes) to High(CControlTypes) do
    if LowerCase(CControlTypes[LIndex].Name) = LNorm then
    begin
      AId := CControlTypes[LIndex].Id;
      Exit(True);
    end;
  Result := False;
end;

end.
