unit Aefos.OTA.Terminal.Core.WindowPlacement;

{
  Pure off-screen-recovery geometry for the terminal dock form (ESP-083 /
  ADR-083-02). Decides whether a desired window rectangle is visible on any
  monitor and, when it is not, which fallback rectangle to use instead.

  No VCL, no IDE, no Windows API — RTL System.Types.TRect only, so the decision
  is deterministic and headless-testable (target >= 80% coverage). The VCL side
  (ShowAefosTerminalDockForm) only gathers Screen.Monitors[*].BoundsRect
  plus a primary-monitor-centered default and calls in here; the geometry never
  raises and never touches a handle. See [[mobaxterm-ux-reference]].

  Minimum-visible-margin (MIN_VISIBLE_MARGIN): a rectangle counts as visible
  when it overlaps at least one monitor by this many pixels in BOTH dimensions.
  The value is large enough that a grabbable strip of title bar is on-screen,
  yet small enough that a deliberately-placed, mostly-on-screen form is never
  moved (ADR-083-02 R3 / AC2).
}

interface

uses
  System.Types;

type
  /// <summary>
  ///   Pure off-screen-recovery geometry for the terminal dock form. Static-only
  ///   sealed class — no VCL, no IDE, no Windows API.
  /// </summary>
  TWindowPlacement = class sealed
  public
    /// <summary>
    ///   <c>True</c> when <c>ARect</c> overlaps at least one monitor in
    ///   <c>AMonitors</c> by at least <c>MIN_VISIBLE_MARGIN</c> pixels in both
    ///   width and height. An empty monitor list, or a fully off-screen /
    ///   degenerate rect, yields <c>False</c>. Never raises.
    /// </summary>
    class function IsRectVisibleOnMonitors(const ARect: TRect;
      const AMonitors: array of TRect): Boolean; static;

    /// <summary>
    ///   Returns <c>ADesired</c> when it is visible on any monitor (see
    ///   <see cref="IsRectVisibleOnMonitors"/>), otherwise returns <c>ADefault</c>.
    ///   This is the off-screen-recovery decision: keep a partially-visible form
    ///   where the user left it, reset a fully off-screen form to a visible
    ///   fallback. Never raises.
    /// </summary>
    class function ResolveVisibleBounds(const ADesired, ADefault: TRect;
      const AMonitors: array of TRect): TRect; static;
  end;

implementation

const
  /// <summary>Pixels of overlap required, per axis, for a rect to count as
  /// visible on a monitor (ADR-083-02). A grabbable title-bar strip.</summary>
  MIN_VISIBLE_MARGIN = 16;

function _Min(const ALeft, ARight: Integer): Integer;
begin
  if ALeft < ARight then
    Result := ALeft
  else
    Result := ARight;
end;

function _Max(const ALeft, ARight: Integer): Integer;
begin
  if ALeft > ARight then
    Result := ALeft
  else
    Result := ARight;
end;

/// <summary>
///   <c>True</c> when the intersection of <c>ARect</c> and <c>AMonitor</c> is at
///   least <c>MIN_VISIBLE_MARGIN</c> pixels wide AND tall. Pure rect math (no
///   Winapi.IntersectRect) so it is dependency-free and never raises.
/// </summary>
function _OverlapsMonitor(const ARect, AMonitor: TRect): Boolean;
var
  LOverlapWidth: Integer;
  LOverlapHeight: Integer;
begin
  LOverlapWidth := _Min(ARect.Right, AMonitor.Right) -
    _Max(ARect.Left, AMonitor.Left);
  LOverlapHeight := _Min(ARect.Bottom, AMonitor.Bottom) -
    _Max(ARect.Top, AMonitor.Top);
  Result := (LOverlapWidth >= MIN_VISIBLE_MARGIN) and
    (LOverlapHeight >= MIN_VISIBLE_MARGIN);
end;

class function TWindowPlacement.IsRectVisibleOnMonitors(const ARect: TRect;
  const AMonitors: array of TRect): Boolean;
var
  LIndex: Integer;
begin
  for LIndex := Low(AMonitors) to High(AMonitors) do
    if _OverlapsMonitor(ARect, AMonitors[LIndex]) then
      Exit(True);
  Result := False;
end;

class function TWindowPlacement.ResolveVisibleBounds(const ADesired, ADefault: TRect;
  const AMonitors: array of TRect): TRect;
begin
  if TWindowPlacement.IsRectVisibleOnMonitors(ADesired, AMonitors) then
    Result := ADesired
  else
    Result := ADefault;
end;

end.
