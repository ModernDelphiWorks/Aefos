unit Aefos.Lazarus.WebViewDComp;

{ DirectComposition + D3D11 + DXGI minimal ABI for the Lazarus/FPC composition
  WebView2 host (TAefosLazWebView).

  This is the FPC twin of the Delphi edition's Aefos.WebView.DComp -- but it also
  hand-declares the few D3D11/DXGI symbols the Delphi build gets for free from the
  RTL's Winapi.D3D11 / Winapi.DXGI (units FPC 3.2.2 does NOT ship). None of these
  are third-party: dcomp.dll, d3d11.dll and the DXGI/D3D COM contracts are Windows
  system components (present since Windows 8). We declare ONLY the handful of
  symbols the composition pipeline needs; IIDs + method/vtable order mirror the
  Microsoft ABI and the Delphi Aefos.WebView.DComp byte-for-byte.

  Why composition hosting: a WINDOWED WebView2 (its own child HWND parented to the
  host control) stops compositing when the host's top-level window is deactivated
  (e.g. the IDE losing the foreground to the CLI terminal) and must be re-homed on
  every dock/undock/layout reparent -- the fragile "blank docked chat" whack-a-mole.
  A COMPOSITION-hosted WebView2 renders into a DirectComposition visual that the DWM
  composites regardless of window activation/occlusion, and survives reparent because
  only the DComp TARGET is bound to the host HWND (rebuilt in one step), never the
  controller (whose parent is a hidden stable anchor window). See the host unit.

  The D3D11 device + context are treated as opaque (we only QI the device to
  IDXGIDevice and never call their methods), and the composition visual is opaque
  (the WebView2 controller renders into it via Set_RootVisualTarget; we never call
  IDCompositionVisual methods ourselves) -- so only Device + Target need real method
  declarations. Method order MUST match the C++ vtable. }

{$mode delphi}
{$H+}

interface

uses
  Windows;

const
  // Mirrors the Delphi Aefos.WebView.DComp IID + the Microsoft globals page.
  IID_IDCompositionDevice: TGUID = '{C37EA93A-E7AA-450D-B16F-9746CB0407F3}';
  // IDXGIDevice IID (dxgi.h) -- used only to QI the D3D11 device before handing it
  // to DCompositionCreateDevice.
  IID_IDXGIDevice: TGUID = '{54EC77FA-1377-44E6-8C32-88FD5F44C84C}';

  // D3D11CreateDevice inputs (d3d11.h / d3dcommon.h). Only the two driver types the
  // host tries (hardware, then WARP software fallback for VMs/RDP) and the flag/SDK
  // constants it passes are declared.
  D3D_DRIVER_TYPE_HARDWARE = 1;
  D3D_DRIVER_TYPE_WARP     = 5;
  D3D11_SDK_VERSION        = 7;
  D3D11_CREATE_DEVICE_BGRA_SUPPORT = $20;

type
  // 4-byte C enums passed as plain scalars (we only supply the constants above).
  TD3DDriverType   = LongWord;
  TD3DFeatureLevel = LongWord;

  // -- DirectComposition (dcomp.dll) ----------------------------------------
  // Opaque: only passed around (CreateVisual -> SetRoot / Set_RootVisualTarget).
  IDCompositionVisual = interface(IUnknown)
    ['{4D93059D-097B-4651-9A60-F0F25116E2F3}']
  end;

  IDCompositionTarget = interface(IUnknown)
    ['{EACDD04C-117E-4E17-88F4-D1B12B0E3D89}']
    function SetRoot(const visual: IDCompositionVisual): HResult; stdcall;
  end;

  IDCompositionDevice = interface(IUnknown)
    ['{C37EA93A-E7AA-450D-B16F-9746CB0407F3}']
    function Commit: HResult; stdcall;
    function WaitForCommitCompletion: HResult; stdcall;
    function GetFrameStatistics(out statistics): HResult; stdcall;
    function CreateTargetForHwnd(hwnd: HWND; topmost: BOOL;
      out target: IDCompositionTarget): HResult; stdcall;
    function CreateVisual(out visual: IDCompositionVisual): HResult; stdcall;
    // (further methods omitted -- not used by the host)
  end;

  // -- D3D11 / DXGI (opaque) -------------------------------------------------
  // We never call methods on the D3D11 device/context -- we only need the device
  // pointer (out of D3D11CreateDevice) and a QI to IDXGIDevice. Declared with the
  // real IIDs so Supports()/QueryInterface resolves them; bodies left empty.
  ID3D11DeviceContext = interface(IUnknown)
    ['{C0BFA96C-E089-44FB-8EAF-26F8796190DA}']
  end;

  ID3D11Device = interface(IUnknown)
    ['{DB6F6DDB-AC77-4E88-8253-819DF9BBF140}']
  end;

  IDXGIDevice = interface(IUnknown)
    ['{54EC77FA-1377-44E6-8C32-88FD5F44C84C}']
  end;

// d3d11.dll: create a D3D11 device (the composition pipeline's GPU/WARP root).
// Signature mirrors Winapi.D3D11.D3D11CreateDevice; pFeatureLevels is passed nil
// (Pointer here avoids importing the feature-level array type we never populate).
function D3D11CreateDevice(pAdapter: IUnknown; DriverType: TD3DDriverType;
  Software: HMODULE; Flags: UINT; pFeatureLevels: Pointer; FeatureLevels: UINT;
  SDKVersion: UINT; out ppDevice: ID3D11Device;
  out pFeatureLevel: TD3DFeatureLevel;
  out ppImmediateContext: ID3D11DeviceContext): HResult; stdcall;
  external 'd3d11.dll';

// dcomp.dll: build an IDCompositionDevice over a DXGI device (from a D3D11 device).
function DCompositionCreateDevice(const dxgiDevice: IUnknown; const iid: TGUID;
  out dcompositionDevice): HResult; stdcall; external 'dcomp.dll';

implementation

end.
