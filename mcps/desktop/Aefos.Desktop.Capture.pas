unit Aefos.Desktop.Capture;

{
  Per-window bitmap capture for the Aefos Desktop MCP (feat/desktop-mcp, PHASE 4b).

  THE ONE RULE THIS UNIT EXISTS TO KEEP: **capturing must never mutate the
  desktop.** The obvious implementation — SetForegroundWindow + BitBlt from the
  screen — was the finding C3 of the plan's security review: it STEALS FOCUS
  (that is a mutation, performed by a "read" tool that skips every write key) and
  it photographs whatever pixels happen to be on screen, so an occluding window
  leaks into the frame. This unit therefore captures with **PrintWindow**, which
  asks the window to render ITSELF into our DC:

    * no SetForegroundWindow, no focus change, no z-order change, no input;
    * the window's own content, even when partly covered by another window;
    * ONE window by hwnd — there is deliberately no whole-screen capture at all.
      "Photograph the entire desktop" is exactly the capability the security model
      refuses to hand an LLM, so it does not exist as a code path here.

  When PrintWindow cannot produce a real image (a DirectComposition / WinUI
  surface commonly renders blank, and a minimised window has nothing to render)
  we return an HONEST failure — desktop-capture-unavailable — and the agent falls
  back to the UIA read tools. We do NOT quietly retry with the foreground-stealing
  BitBlt: an undetectable focus steal is precisely what C3 forbids, and a tool
  that silently changes strategy is a tool whose safety contract is a lie.

  Blank detection is a uniform-pixel test, which also flags a legitimately
  single-colour window as "unavailable". That false positive is deliberate: the
  cost is an honest refusal on a rare window (the agent still has UIA), while the
  false NEGATIVE it prevents is handing the model a black rectangle and letting it
  reason about it as if it had seen the app.

  Scaling and encoding: the emitted image rides back to the model as an inline
  base64 PNG (the MCP `image` content block the core already supports), so it is
  downscaled to fit a max-dimension box (Aefos.Desktop.ReadShape, pure + tested)
  before encoding — an uncapped 4K window would blow up the context and the bill.
  Encoding is WIC (Winapi.Wincodec, the same imaging stack TWICImage wraps) so the
  MCP server exe does not have to drag in the whole Vcl for a PNG.

  This unit is Winapi-bound (GDI + WIC) and therefore NOT part of the headless
  pure-test suite; its PURE halves — the scope decision (Aefos.Desktop.Guard's
  dtCapture tier) and the size arithmetic (Aefos.Desktop.ReadShape) — live in the
  units that ARE tested headless. What remains here is the Windows plumbing, which
  is exercised by the live capture probe.
}

interface

uses
  System.SysUtils;

type
  // The outcome of one window capture. Ok=False carries a kebab Reason the tool
  // layer hands straight to the agent (same style as the guard's verdicts).
  TDesktopCaptureResult = record
    Ok: Boolean;
    Reason: string;        // kebab code when not Ok; '' when Ok
    PngBase64: string;     // raw base64 (no data: prefix) — MCP image block
    Width: Integer;        // emitted size (after any downscale)
    Height: Integer;
    SourceWidth: Integer;  // the window's real client-area size
    SourceHeight: Integer;
    Scaled: Boolean;       // True when the emitted image was downscaled
  end;

const
  // Kebab failure codes (agent-actionable, RULE #1 style).
  DESKTOP_CAPTURE_WINDOW_GONE  = 'desktop-capture-window-gone';
  DESKTOP_CAPTURE_MINIMIZED    = 'desktop-capture-minimized';
  DESKTOP_CAPTURE_EMPTY_RECT   = 'desktop-capture-empty-rect';
  DESKTOP_CAPTURE_UNAVAILABLE  = 'desktop-capture-unavailable';
  DESKTOP_CAPTURE_ENCODE_FAILED = 'desktop-capture-encode-failed';

type
  // Static, sealed namespace for the per-window bitmap capture mechanism. Never
  // instantiated (no constructor): the single routine is a class function so it
  // has a named owner (TDesktopCapture.CaptureWindow) instead of floating free in
  // the unit interface.
  TDesktopCapture = class sealed
  public
    { Captures ONE window by hwnd via PrintWindow (never stealing the foreground) and
      returns it as a base64 PNG, downscaled to fit AReqMaxDim (<=0 => the default).
      Never raises: every failure comes back as Ok=False + a kebab Reason. The CALLER
      must have already cleared the capture through the guard (dtCapture): this unit
      is the mechanism, not the policy. }
    class function CaptureWindow(AHwnd: NativeInt;
      AReqMaxDim: Integer): TDesktopCaptureResult; static;
  end;

implementation

uses
  Winapi.Windows,
  Winapi.ActiveX,
  Winapi.Wincodec,
  System.NetEncoding,
  System.Win.ComObj,
  Aefos.Desktop.ReadShape;

const
  // PrintWindow flag (Win8.1+): render the FULL content, including a
  // DirectComposition/DWM-composited surface, instead of only the legacy WM_PRINT
  // path. Without it, modern windows come back blank far more often. Not declared
  // by the RTL's Winapi.Windows.
  PW_RENDERFULLCONTENT = $00000002;

// PrintWindow is not declared by the RTL's Winapi.Windows either — import it
// (the same hand-written-import approach the UIA unit takes).
function PrintWindow(hwnd: HWND; hdcBlt: HDC; nFlags: UINT): BOOL; stdcall;
  external user32 name 'PrintWindow';

type
  // A 32-bit top-down DIB we own: the device context, the bitmap and the raw
  // pixel pointer travel together, so the GDI cleanup is one call.
  TDib = record
    DC: HDC;
    Bmp: HBITMAP;
    OldBmp: HGDIOBJ;
    Bits: PByte;      // BGRA, top-down, stride = Width * 4
    Width: Integer;
    Height: Integer;
  end;

// Creates a 32bpp top-down DIB section of AWidth x AHeight. Zeroed record on
// failure (DC=0), never raises.
function _CreateDib(AWidth, AHeight: Integer): TDib;
var
  LInfo: TBitmapInfo;
begin
  Result := Default(TDib);
  if (AWidth <= 0) or (AHeight <= 0) then
    Exit;

  Result.DC := CreateCompatibleDC(0);
  if Result.DC = 0 then
    Exit;

  FillChar(LInfo, SizeOf(LInfo), 0);
  LInfo.bmiHeader.biSize := SizeOf(TBitmapInfoHeader);
  LInfo.bmiHeader.biWidth := AWidth;
  // NEGATIVE height = top-down rows, so row 0 is the TOP of the image and the
  // buffer can be handed to WIC as-is (WIC expects top-down).
  LInfo.bmiHeader.biHeight := -AHeight;
  LInfo.bmiHeader.biPlanes := 1;
  LInfo.bmiHeader.biBitCount := 32;
  LInfo.bmiHeader.biCompression := BI_RGB;

  Result.Bmp := CreateDIBSection(Result.DC, LInfo, DIB_RGB_COLORS,
    Pointer(Result.Bits), 0, 0);
  if (Result.Bmp = 0) or (Result.Bits = nil) then
  begin
    DeleteDC(Result.DC);
    Result := Default(TDib);
    Exit;
  end;

  Result.OldBmp := SelectObject(Result.DC, Result.Bmp);
  Result.Width := AWidth;
  Result.Height := AHeight;
end;

procedure _FreeDib(var ADib: TDib);
begin
  if ADib.DC <> 0 then
  begin
    if ADib.OldBmp <> 0 then
      SelectObject(ADib.DC, ADib.OldBmp);
    if ADib.Bmp <> 0 then
      DeleteObject(ADib.Bmp);
    DeleteDC(ADib.DC);
  end;
  ADib := Default(TDib);
end;

// GDI leaves the alpha byte of a 32bpp DIB at 0 after PrintWindow/StretchBlt (it
// is an "unused" byte to GDI). Encoded as BGRA that reads as FULLY TRANSPARENT —
// the classic "my screenshot is blank" bug. Force every pixel opaque.
procedure _ForceOpaque(const ADib: TDib);
var
  LPixel: PByte;
  LIndex, LCount: Integer;
begin
  if ADib.Bits = nil then
    Exit;
  LCount := ADib.Width * ADib.Height;
  LPixel := ADib.Bits;
  for LIndex := 0 to LCount - 1 do
  begin
    Inc(LPixel, 3);       // B,G,R then A
    LPixel^ := 255;
    Inc(LPixel);
  end;
end;

// True when every pixel is identical — PrintWindow produced nothing usable (a
// DirectComposition/WinUI surface, or a window with no rendered content). See the
// unit header on why a solid-colour window is deliberately treated the same way.
function _IsUniform(const ADib: TDib): Boolean;
var
  LPixels: PCardinal;
  LFirst: Cardinal;
  LIndex, LCount: Integer;
begin
  Result := True;
  if (ADib.Bits = nil) or (ADib.Width <= 0) or (ADib.Height <= 0) then
    Exit;
  LPixels := PCardinal(ADib.Bits);
  LFirst := LPixels^;
  LCount := ADib.Width * ADib.Height;
  for LIndex := 1 to LCount - 1 do
  begin
    Inc(LPixels);
    if LPixels^ <> LFirst then
      Exit(False);
  end;
end;

// Encodes a 32bpp top-down BGRA DIB as PNG and returns the bytes. Empty on any
// WIC failure (the caller turns that into desktop-capture-encode-failed).
{ Base64 with NO line breaks.

  TNetEncoding.Base64 wraps at 76 characters with CRLF -- a MIME convention that
  is wrong everywhere this string goes. The breaks survive into the MCP image
  block, get escaped as 
 when the result is serialised to JSON, and arrive
  in the panel INSIDE the data: URI, which then will not decode. The card showed
  it as a grey placeholder: "The after screenshot could not be displayed (16410
  chars received)" -- a length that looked plausible precisely because the escape
  sequences padded it back up.

  Nothing downstream wants the wrapping. TBase64Encoding.Create(0) means "never
  split", which is what a data URI and an MCP image block both require. }
function _Base64NoWrap(const ABytes: TBytes): string;
var
  LEnc: TBase64Encoding;
begin
  LEnc := TBase64Encoding.Create(0);
  try
    Result := LEnc.EncodeBytesToString(ABytes);
  finally
    LEnc.Free;
  end;
end;

function _EncodePng(const ADib: TDib): TBytes;
var
  LFactory: IWICImagingFactory;
  LStream: IStream;
  LEncoder: IWICBitmapEncoder;
  LFrame: IWICBitmapFrameEncode;
  LProps: IPropertyBag2;
  LFormat: TGUID;
  LStat: TStatStg;
  LRead: LargeUInt;
  LPos: LargeUInt;
  LSize: Integer;
begin
  Result := nil;
  if (ADib.Bits = nil) or (ADib.Width <= 0) or (ADib.Height <= 0) then
    Exit;

  LFactory := CreateComObject(CLSID_WICImagingFactory) as IWICImagingFactory;
  if LFactory = nil then
    Exit;

  // An in-memory stream (HGLOBAL-backed) receives the encoded PNG.
  if Failed(CreateStreamOnHGlobal(0, True, LStream)) or (LStream = nil) then
    Exit;

  // GUID_NULL vendor = "any PNG encoder" (the param is a const TGUID, not a
  // pointer, in the RTL's Wincodec import).
  if Failed(LFactory.CreateEncoder(GUID_ContainerFormatPng, GUID_NULL, LEncoder)) then
    Exit;
  if Failed(LEncoder.Initialize(LStream, WICBitmapEncoderNoCache)) then
    Exit;
  if Failed(LEncoder.CreateNewFrame(LFrame, LProps)) then
    Exit;
  if Failed(LFrame.Initialize(LProps)) then
    Exit;
  if Failed(LFrame.SetSize(ADib.Width, ADib.Height)) then
    Exit;

  // WIC may negotiate a different pixel format; it converts for us either way.
  LFormat := GUID_WICPixelFormat32bppBGRA;
  if Failed(LFrame.SetPixelFormat(LFormat)) then
    Exit;

  if Failed(LFrame.WritePixels(ADib.Height, ADib.Width * 4,
    ADib.Width * 4 * ADib.Height, ADib.Bits)) then
    Exit;
  if Failed(LFrame.Commit) then
    Exit;
  if Failed(LEncoder.Commit) then
    Exit;

  // Drain the stream back into a byte array.
  if Failed(LStream.Stat(LStat, STATFLAG_NONAME)) then
    Exit;
  LSize := Integer(LStat.cbSize);
  if LSize <= 0 then
    Exit;
  LPos := 0;
  if Failed(LStream.Seek(0, STREAM_SEEK_SET, LPos)) then
    Exit;
  SetLength(Result, LSize);
  LRead := 0;
  if Failed(LStream.Read(@Result[0], LSize, @LRead)) or (LRead <> LSize) then
    SetLength(Result, 0);
end;

class function TDesktopCapture.CaptureWindow(AHwnd: NativeInt;
  AReqMaxDim: Integer): TDesktopCaptureResult;
var
  LWnd: HWND;
  LRect: TRect;
  LSrcW, LSrcH: Integer;
  LSize: TDesktopCaptureSize;
  LShot, LScaled: TDib;
  LEmit: ^TDib;
  LPng: TBytes;
begin
  Result := Default(TDesktopCaptureResult);
  LShot := Default(TDib);
  LScaled := Default(TDib);
  LWnd := HWND(AHwnd);

  if (AHwnd = 0) or (not IsWindow(LWnd)) then
  begin
    Result.Reason := DESKTOP_CAPTURE_WINDOW_GONE;
    Exit;
  end;
  // A minimised window renders nothing: report it instead of emitting a blank.
  if IsIconic(LWnd) then
  begin
    Result.Reason := DESKTOP_CAPTURE_MINIMIZED;
    Exit;
  end;
  if not GetWindowRect(LWnd, LRect) then
  begin
    Result.Reason := DESKTOP_CAPTURE_WINDOW_GONE;
    Exit;
  end;

  LSrcW := LRect.Right - LRect.Left;
  LSrcH := LRect.Bottom - LRect.Top;
  if (LSrcW <= 0) or (LSrcH <= 0) then
  begin
    Result.Reason := DESKTOP_CAPTURE_EMPTY_RECT;
    Exit;
  end;
  Result.SourceWidth := LSrcW;
  Result.SourceHeight := LSrcH;

  try
    LShot := _CreateDib(LSrcW, LSrcH);
    if LShot.DC = 0 then
    begin
      Result.Reason := DESKTOP_CAPTURE_UNAVAILABLE;
      Exit;
    end;

    // THE capture. PrintWindow asks the window to draw itself into our DC — no
    // foreground steal, no z-order change, no occlusion bleed (C3).
    if not PrintWindow(LWnd, LShot.DC, PW_RENDERFULLCONTENT) then
    begin
      Result.Reason := DESKTOP_CAPTURE_UNAVAILABLE;
      Exit;
    end;
    _ForceOpaque(LShot);

    // Nothing was actually rendered (WinUI/DirectComposition, empty surface).
    // Honest refusal — never a silent fallback to a focus-stealing BitBlt.
    if _IsUniform(LShot) then
    begin
      Result.Reason := DESKTOP_CAPTURE_UNAVAILABLE;
      Exit;
    end;

    // Downscale to the budget (pure arithmetic, tested headless).
    LSize := TDesktopReadShape.CaptureSizeFor(LSrcW, LSrcH, AReqMaxDim);
    LEmit := @LShot;
    if LSize.Scaled then
    begin
      LScaled := _CreateDib(LSize.Width, LSize.Height);
      if LScaled.DC = 0 then
      begin
        Result.Reason := DESKTOP_CAPTURE_UNAVAILABLE;
        Exit;
      end;
      // HALFTONE = the smooth (averaging) downscale; COLORONCOLOR would drop
      // rows and render text unreadable, which defeats the point of a capture.
      SetStretchBltMode(LScaled.DC, HALFTONE);
      SetBrushOrgEx(LScaled.DC, 0, 0, nil);
      if not StretchBlt(LScaled.DC, 0, 0, LScaled.Width, LScaled.Height,
        LShot.DC, 0, 0, LShot.Width, LShot.Height, SRCCOPY) then
      begin
        Result.Reason := DESKTOP_CAPTURE_UNAVAILABLE;
        Exit;
      end;
      _ForceOpaque(LScaled);   // StretchBlt zeroes alpha again
      LEmit := @LScaled;
    end;

    LPng := _EncodePng(LEmit^);
    if Length(LPng) = 0 then
    begin
      Result.Reason := DESKTOP_CAPTURE_ENCODE_FAILED;
      Exit;
    end;

    Result.PngBase64 := _Base64NoWrap(LPng);
    Result.Width := LEmit^.Width;
    Result.Height := LEmit^.Height;
    Result.Scaled := LSize.Scaled;
    Result.Ok := True;
    Result.Reason := '';
  finally
    _FreeDib(LScaled);
    _FreeDib(LShot);
  end;
end;

end.
