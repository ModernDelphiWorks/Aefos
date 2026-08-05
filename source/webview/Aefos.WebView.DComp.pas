unit Aefos.WebView.DComp;

{
  DirectComposition (dcomp.dll) minimal import — the FOUNDATION of the composition
  (visual) WebView2 host. NOT a third-party dependency: dcomp.dll is a Windows
  system DLL (present since Windows 8) and is not declared in the Delphi RTL, so we
  hand-declare only the few symbols the host needs.

  Why composition hosting: a windowed WebView2 (Vcl.Edge.TEdgeBrowser) hosted in a
  child window STOPS compositing when its top-level host window is deactivated (e.g.
  the IDE losing the foreground to the CLI's terminal) -> the docked chat goes
  black. A composition-hosted WebView2 renders into a DirectComposition visual that
  the DWM composites regardless of window activation/occlusion -> never blanks.

  Visuals are treated as opaque IUnknown here (the WebView2 controller renders into
  the root visual via put_RootVisualTarget; we never call IDCompositionVisual
  methods ourselves), so only Device + Target need real method declarations.
  Method order MUST match the C++ vtable.
}

interface

uses
  Winapi.Windows;

const
  IID_IDCompositionDevice: TGUID = '{C37EA93A-E7AA-450D-B16F-9746CB0407F3}';

type
  // Opaque — we only pass it around (CreateVisual -> SetRoot / RootVisualTarget).
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
    // (further methods omitted — not used by the host)
  end;

// dcomp.dll: build an IDCompositionDevice over a DXGI device (from a D3D11 device).
function DCompositionCreateDevice(const dxgiDevice: IUnknown; const iid: TGUID;
  out dcompositionDevice): HResult; stdcall; external 'dcomp.dll';

implementation

end.
