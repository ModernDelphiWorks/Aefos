unit Aefos.OTA.Terminal.Core.VisualDiff;

/// <summary>
/// Pure RTL perceptual-diff comparator for terminal visual golden-image testing
/// (ESP-067 / ADR-067-03). RTL-only — no VCL dependency. The VCL host extracts
/// raw pixel bytes from TBitmap scanlines and calls TVisualDiffComparator.Compare.
/// </summary>

interface

uses
  System.SysUtils;

type
  /// <summary>
  /// Result of a pixel-buffer comparison.
  /// <c>PixelsDiff</c> = count of pixels whose max per-channel delta exceeds
  /// <c>ATolerance</c>; <c>MaxChannelDelta</c> = the global worst single-channel
  /// delta across all pixels.
  /// </summary>
  TVisualDiffResult = record
    Width: Integer;
    Height: Integer;
    PixelsDiff: Integer;
    MaxChannelDelta: Integer;
    /// <summary>
    /// Returns True when <c>PixelsDiff</c> does not exceed <c>AMax</c>. The
    /// sole pass/fail predicate — keeps the threshold check in one place (BR3).
    /// </summary>
    function WithinThreshold(AMax: Integer): Boolean;
  end;

  /// <summary>
  /// Pure perceptual-diff comparator over raw pixel buffers. Static-only
  /// sealed class.
  /// </summary>
  TVisualDiffComparator = class sealed
  public
    /// <summary>
    /// Compares two raw BGRA pixel buffers (row-major, 4 bytes/pixel).
    /// A pixel is counted as different when its max per-channel R/G/B delta
    /// exceeds <c>ATolerance</c>; the alpha channel is ignored.
    /// Returns a <c>TVisualDiffResult</c> with deterministic fields for
    /// threshold evaluation. If the buffers have different lengths a
    /// dimension-mismatch result is returned: <c>PixelsDiff = Width*Height</c>
    /// (all pixels reported as different).
    /// </summary>
    class function Compare(const ALeft, ARight: TBytes; const AWidth, AHeight: Integer;
      const ATolerance: Integer): TVisualDiffResult; static;
  end;

implementation

class function TVisualDiffComparator.Compare(const ALeft, ARight: TBytes;
  const AWidth, AHeight: Integer; const ATolerance: Integer): TVisualDiffResult;
var
  LExpected: Integer;
  LIdx, LBDelta, LGDelta, LRDelta, LMaxDelta: Integer;
  LPixel: Integer;
begin
  Result.Width  := AWidth;
  Result.Height := AHeight;
  Result.PixelsDiff     := 0;
  Result.MaxChannelDelta := 0;

  LExpected := AWidth * AHeight * 4;

  if (Length(ALeft) <> LExpected) or (Length(ARight) <> LExpected) then
  begin
    Result.PixelsDiff      := AWidth * AHeight;
    Result.MaxChannelDelta := 255;
    Exit;
  end;

  LIdx := 0;
  for LPixel := 0 to AWidth * AHeight - 1 do
  begin
    LBDelta := Abs(Integer(ALeft[LIdx])     - Integer(ARight[LIdx]));
    LGDelta := Abs(Integer(ALeft[LIdx + 1]) - Integer(ARight[LIdx + 1]));
    LRDelta := Abs(Integer(ALeft[LIdx + 2]) - Integer(ARight[LIdx + 2]));
    // Alpha (LIdx+3) is ignored — terminal renders to opaque bitmaps.
    if LBDelta > LGDelta then
      LMaxDelta := LBDelta
    else
      LMaxDelta := LGDelta;
    if LRDelta > LMaxDelta then
      LMaxDelta := LRDelta;

    if LMaxDelta > ATolerance then
      Inc(Result.PixelsDiff);

    if LMaxDelta > Result.MaxChannelDelta then
      Result.MaxChannelDelta := LMaxDelta;

    Inc(LIdx, 4);
  end;
end;

function TVisualDiffResult.WithinThreshold(AMax: Integer): Boolean;
begin
  Result := PixelsDiff <= AMax;
end;

end.
