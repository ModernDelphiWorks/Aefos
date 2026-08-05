unit Aefos.Win.WebView2;

{$IFDEF FPC}
// FPC's plain {$MODE Delphi} keeps Char=AnsiChar / string=AnsiString, but the
// entire WebView2 COM ABI is UTF-16 (every string parameter is PWideChar). Delphi
// itself compiles this unit with Unicode strings (Char=WideChar, PChar=PWideChar);
// DELPHIUNICODE is FPC's matching mode, so the unit keeps identical string
// semantics under both compilers. Compiler-capability guard only: no ABI change.
{$MODE DELPHIUNICODE}
{$ENDIF}

{
  Aefos' clean-room WebView2 COM import.

  Purpose: give the Aefos WebView host a single, self-contained import of the
  subset of the Microsoft WebView2 COM ABI it actually consumes, so the host
  never has to depend on any pre-packaged Pascal translation. This unblocks
  toolchains that do not ship a WebView2 import (Delphi 10.3 Rio and, later, the
  Lazarus/FPC port) and keeps the whole surface under our control.

  PROVENANCE (important): every declaration below is derived SOLELY from
  Microsoft's own published WebView2 material -- the ABI is Microsoft's public
  specification and anyone may implement it. Two Microsoft artifacts were used:

    1. The Win32 reference on Microsoft Learn, one page per interface, which
       gives each method's signature and the interface's inheritance parent:
       https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/
       (each interface below carries its exact page URL).

    2. Microsoft's authoritative WebView2.idl, shipped inside the official
       Microsoft.Web.WebView2 NuGet package, which supplies each interface's
       [uuid(...)] and the exact top-to-bottom method DECLARATION order (COM
       vtables are positional, and the Learn pages render methods alphabetically,
       so the IDL is the source of truth for slot order). The options class is
       modelled on Microsoft's reference WebView2EnvironmentOptions.h from the
       same package.

  No third-party or vendor Pascal translation was consulted, mirrored, or used
  to cross-check any fact here. The unit's layout, helper names, comments and the
  choice of which slices of the ABI to declare are Aefos' own.

  Because vtables are positional, every interface lists its FULL public method
  set in the exact IDL declaration order. Parameter types the Aefos host never
  references are pruned to IUnknown (an interface reference is a pointer either
  way, so the slot width is unchanged) or to their raw 4-byte ABI width for
  enums. This keeps the offsets of the methods we DO call exact without pulling
  in the rest of the WebView2 interface graph.

  Dependencies stay pre-Rio: Winapi.Windows, Winapi.ActiveX, System.SysUtils,
  plus generics and anonymous methods (all available before 10.4).
}

interface

uses
  // FPC 3.2.2 (the Lazarus port target) does not ship the Delphi 2010+ dotted
  // RTL unit names (Winapi.*, System.*), so it resolves the same RTL surface via
  // the classic short unit names. Math supplies SetExceptionMask/exXxx for the
  // FPU mask in initialization (Delphi carries that in the System/SysUtils RTL).
  // This is a compiler-capability guard only: it changes NO ABI declaration.
  {$IFDEF FPC}
  Windows, ActiveX, SysUtils, Math;
  {$ELSE}
  Winapi.Windows, Winapi.ActiveX, System.SysUtils;
  {$ENDIF}

// ---------------------------------------------------------------------------
// Scalar aliases / enums / structs from the WebView2 ABI.
// SYSINT / SYSUINT / Largeuint come from Winapi.ActiveX (the OLE wire scalars);
// tagPOINT comes from Winapi.Windows. Only the WebView2-specific types below
// need declaring here.
// ---------------------------------------------------------------------------
type
  // WebView2 enums are 4-byte C enums. The Microsoft globals page documents them
  // as plain enumerations, so each is aliased to a 4-byte unsigned scalar and
  // only the constants Aefos references are provided as consts below.
  // Ref: https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/webview2-idl
  COREWEBVIEW2_MOVE_FOCUS_REASON = LongWord;
  COREWEBVIEW2_MOUSE_EVENT_KIND = LongWord;
  COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS = LongWord;
  COREWEBVIEW2_POINTER_EVENT_KIND = LongWord;
  // Ref: https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/corewebview2_web_error_status
  COREWEBVIEW2_WEB_ERROR_STATUS = LongWord;
  COREWEBVIEW2_CAPTURE_PREVIEW_IMAGE_FORMAT = LongWord;
  COREWEBVIEW2_WEB_RESOURCE_CONTEXT = LongWord;

  // EventRegistrationToken is the WinRT add_*/remove_* cookie. WebView2's
  // add_* handlers hand one back and remove_* takes it. The single Int64 'value'
  // field matches the ABI and the Aefos host's FNavToken.value / FMsgToken.value.
  EventRegistrationToken = record
    value: Int64;
  end;

  // 32-bit colour used by ICoreWebView2Controller2's DefaultBackgroundColor.
  // Field order A,R,G,B (each BYTE) per the Microsoft struct page:
  // https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/corewebview2_color
  COREWEBVIEW2_COLOR = record
    A: Byte;
    R: Byte;
    G: Byte;
    B: Byte;
  end;

  // WebView2's rectangle parameter is a plain Win32 RECT (Left/Top/Right/Bottom
  // as 32-bit ints). Winapi.Windows publishes it only under the TRect alias, so
  // this identically-laid-out record is declared for the tagRECT name the Aefos
  // host uses for its FBounds field.
  tagRECT = record
    Left: Integer;
    Top: Integer;
    right: Integer;
    bottom: Integer;
  end;

// ---------------------------------------------------------------------------
// Enum constants actually referenced by the Aefos host.
// Values per Microsoft's WebView2 enum documentation (globals / enum pages).
// ---------------------------------------------------------------------------
const
  COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC = $00000000;
  COREWEBVIEW2_MOUSE_EVENT_KIND_WHEEL = $0000020A;

// ---------------------------------------------------------------------------
// Forward declarations (the WebView2 interfaces reference one another).
// ---------------------------------------------------------------------------
type
  ICoreWebView2 = interface;
  ICoreWebView2NavigationCompletedEventHandler = interface;
  ICoreWebView2NavigationCompletedEventArgs = interface;
  ICoreWebView2ExecuteScriptCompletedHandler = interface;
  ICoreWebView2WebMessageReceivedEventHandler = interface;
  ICoreWebView2WebMessageReceivedEventArgs = interface;
  ICoreWebView2Environment = interface;
  ICoreWebView2Environment2 = interface;
  ICoreWebView2Environment3 = interface;
  ICoreWebView2Controller = interface;
  ICoreWebView2Controller2 = interface;
  ICoreWebView2CompositionController = interface;
  ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler = interface;
  ICoreWebView2CreateCoreWebView2CompositionControllerCompletedHandler = interface;
  {$IFDEF FPC}
  // Windowed controller-completed handler (Lazarus/FPC host only, see below).
  ICoreWebView2CreateCoreWebView2ControllerCompletedHandler = interface;
  {$ENDIF}
  ICoreWebView2EnvironmentOptions = interface;

  // -------------------------------------------------------------------------
  // ICoreWebView2 -- the page/webview object (the v1 ABI's 58 members).
  // Doc: https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2
  // IID + slot order from WebView2.idl: uuid(76eceacb-0462-4d94-ac83-423a6793775e).
  // -------------------------------------------------------------------------
  ICoreWebView2 = interface(IUnknown)
    ['{76ECEACB-0462-4D94-AC83-423A6793775E}']
    function Get_Settings(out Settings: IUnknown): HResult; stdcall;
    function Get_Source(out uri: PWideChar): HResult; stdcall;
    function Navigate(uri: PWideChar): HResult; stdcall;
    function NavigateToString(htmlContent: PWideChar): HResult; stdcall;
    function add_NavigationStarting(const eventHandler: IUnknown;
                                    out token: EventRegistrationToken): HResult; stdcall;
    function remove_NavigationStarting(token: EventRegistrationToken): HResult; stdcall;
    function add_ContentLoading(const eventHandler: IUnknown;
                                out token: EventRegistrationToken): HResult; stdcall;
    function remove_ContentLoading(token: EventRegistrationToken): HResult; stdcall;
    function add_SourceChanged(const eventHandler: IUnknown;
                               out token: EventRegistrationToken): HResult; stdcall;
    function remove_SourceChanged(token: EventRegistrationToken): HResult; stdcall;
    function add_HistoryChanged(const eventHandler: IUnknown;
                                out token: EventRegistrationToken): HResult; stdcall;
    function remove_HistoryChanged(token: EventRegistrationToken): HResult; stdcall;
    function add_NavigationCompleted(const eventHandler: ICoreWebView2NavigationCompletedEventHandler;
                                     out token: EventRegistrationToken): HResult; stdcall;
    function remove_NavigationCompleted(token: EventRegistrationToken): HResult; stdcall;
    function add_FrameNavigationStarting(const eventHandler: IUnknown;
                                         out token: EventRegistrationToken): HResult; stdcall;
    function remove_FrameNavigationStarting(token: EventRegistrationToken): HResult; stdcall;
    function add_FrameNavigationCompleted(const eventHandler: ICoreWebView2NavigationCompletedEventHandler;
                                          out token: EventRegistrationToken): HResult; stdcall;
    function remove_FrameNavigationCompleted(token: EventRegistrationToken): HResult; stdcall;
    function add_ScriptDialogOpening(const eventHandler: IUnknown;
                                     out token: EventRegistrationToken): HResult; stdcall;
    function remove_ScriptDialogOpening(token: EventRegistrationToken): HResult; stdcall;
    function add_PermissionRequested(const eventHandler: IUnknown;
                                     out token: EventRegistrationToken): HResult; stdcall;
    function remove_PermissionRequested(token: EventRegistrationToken): HResult; stdcall;
    function add_ProcessFailed(const eventHandler: IUnknown;
                               out token: EventRegistrationToken): HResult; stdcall;
    function remove_ProcessFailed(token: EventRegistrationToken): HResult; stdcall;
    function AddScriptToExecuteOnDocumentCreated(javaScript: PWideChar;
                                                 const handler: IUnknown): HResult; stdcall;
    function RemoveScriptToExecuteOnDocumentCreated(id: PWideChar): HResult; stdcall;
    function ExecuteScript(javaScript: PWideChar;
                           const handler: ICoreWebView2ExecuteScriptCompletedHandler): HResult; stdcall;
    function CapturePreview(imageFormat: COREWEBVIEW2_CAPTURE_PREVIEW_IMAGE_FORMAT;
                            const imageStream: IStream;
                            const handler: IUnknown): HResult; stdcall;
    function Reload: HResult; stdcall;
    function PostWebMessageAsJson(webMessageAsJson: PWideChar): HResult; stdcall;
    function PostWebMessageAsString(webMessageAsString: PWideChar): HResult; stdcall;
    function add_WebMessageReceived(const handler: ICoreWebView2WebMessageReceivedEventHandler;
                                    out token: EventRegistrationToken): HResult; stdcall;
    function remove_WebMessageReceived(token: EventRegistrationToken): HResult; stdcall;
    function CallDevToolsProtocolMethod(methodName: PWideChar; parametersAsJson: PWideChar;
                                        const handler: IUnknown): HResult; stdcall;
    function Get_BrowserProcessId(out value: SYSUINT): HResult; stdcall;
    function Get_CanGoBack(out CanGoBack: Integer): HResult; stdcall;
    function Get_CanGoForward(out CanGoForward: Integer): HResult; stdcall;
    function GoBack: HResult; stdcall;
    function GoForward: HResult; stdcall;
    function GetDevToolsProtocolEventReceiver(eventName: PWideChar;
                                              out receiver: IUnknown): HResult; stdcall;
    function Stop: HResult; stdcall;
    function add_NewWindowRequested(const eventHandler: IUnknown;
                                    out token: EventRegistrationToken): HResult; stdcall;
    function remove_NewWindowRequested(token: EventRegistrationToken): HResult; stdcall;
    function add_DocumentTitleChanged(const eventHandler: IUnknown;
                                      out token: EventRegistrationToken): HResult; stdcall;
    function remove_DocumentTitleChanged(token: EventRegistrationToken): HResult; stdcall;
    function Get_DocumentTitle(out title: PWideChar): HResult; stdcall;
    function AddHostObjectToScript(name: PWideChar; const object_: OleVariant): HResult; stdcall;
    function RemoveHostObjectFromScript(name: PWideChar): HResult; stdcall;
    function OpenDevToolsWindow: HResult; stdcall;
    function add_ContainsFullScreenElementChanged(const eventHandler: IUnknown;
                                                  out token: EventRegistrationToken): HResult; stdcall;
    function remove_ContainsFullScreenElementChanged(token: EventRegistrationToken): HResult; stdcall;
    function Get_ContainsFullScreenElement(out ContainsFullScreenElement: Integer): HResult; stdcall;
    function add_WebResourceRequested(const eventHandler: IUnknown;
                                      out token: EventRegistrationToken): HResult; stdcall;
    function remove_WebResourceRequested(token: EventRegistrationToken): HResult; stdcall;
    function AddWebResourceRequestedFilter(uri: PWideChar;
                                           ResourceContext: COREWEBVIEW2_WEB_RESOURCE_CONTEXT): HResult; stdcall;
    function RemoveWebResourceRequestedFilter(uri: PWideChar;
                                              ResourceContext: COREWEBVIEW2_WEB_RESOURCE_CONTEXT): HResult; stdcall;
    function add_WindowCloseRequested(const eventHandler: IUnknown;
                                      out token: EventRegistrationToken): HResult; stdcall;
    function remove_WindowCloseRequested(token: EventRegistrationToken): HResult; stdcall;
  end;

  // -------------------------------------------------------------------------
  // NavigationCompleted event handler + args.
  // Handler doc: https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2navigationcompletedeventhandler
  //   IID uuid(d33a35bf-1c49-4f98-93ab-006e0533fe1c); one Invoke(sender, args).
  // Args doc: https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2navigationcompletedeventargs
  //   IID uuid(30d68b7d-20d9-4752-a9ca-ec8448fbb5c1); IsSuccess/WebErrorStatus/NavigationId getters.
  // -------------------------------------------------------------------------
  ICoreWebView2NavigationCompletedEventHandler = interface(IUnknown)
    ['{D33A35BF-1C49-4F98-93AB-006E0533FE1C}']
    function Invoke(const sender: ICoreWebView2;
                    const args: ICoreWebView2NavigationCompletedEventArgs): HResult; stdcall;
  end;

  ICoreWebView2NavigationCompletedEventArgs = interface(IUnknown)
    ['{30D68B7D-20D9-4752-A9CA-EC8448FBB5C1}']
    // IsSuccess is a BOOL (4 bytes); declared Integer here (identical width).
    function Get_IsSuccess(out IsSuccess: Integer): HResult; stdcall;
    function Get_WebErrorStatus(out WebErrorStatus: COREWEBVIEW2_WEB_ERROR_STATUS): HResult; stdcall;
    // NavigationId is a UINT64; Largeuint (Winapi.ActiveX) is its 8-byte match.
    function Get_NavigationId(out NavigationId: Largeuint): HResult; stdcall;
  end;

  // -------------------------------------------------------------------------
  // ExecuteScript completed handler.
  // Doc: https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2executescriptcompletedhandler
  // IID uuid(49511172-cc67-4bca-9923-137112f4c4cc); Invoke(errorCode, resultObjectAsJson).
  // -------------------------------------------------------------------------
  ICoreWebView2ExecuteScriptCompletedHandler = interface(IUnknown)
    ['{49511172-CC67-4BCA-9923-137112F4C4CC}']
    function Invoke(errorCode: HResult; result: PWideChar): HResult; stdcall;
  end;

  // -------------------------------------------------------------------------
  // WebMessageReceived event handler + args.
  // Handler doc: https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2webmessagereceivedeventhandler
  //   IID uuid(57213f19-00e6-49fa-8e07-898ea01ecbd2).
  // Args doc: https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2webmessagereceivedeventargs
  //   IID uuid(0f99a40c-e962-4207-9e92-e3d542eff849); Source / WebMessageAsJson / TryGetWebMessageAsString.
  // -------------------------------------------------------------------------
  ICoreWebView2WebMessageReceivedEventHandler = interface(IUnknown)
    ['{57213F19-00E6-49FA-8E07-898EA01ECBD2}']
    function Invoke(const sender: ICoreWebView2;
                    const args: ICoreWebView2WebMessageReceivedEventArgs): HResult; stdcall;
  end;

  ICoreWebView2WebMessageReceivedEventArgs = interface(IUnknown)
    ['{0F99A40C-E962-4207-9E92-E3D542EFF849}']
    function Get_Source(out value: PWideChar): HResult; stdcall;
    function Get_webMessageAsJson(out value: PWideChar): HResult; stdcall;
    function TryGetWebMessageAsString(out value: PWideChar): HResult; stdcall;
  end;

  // -------------------------------------------------------------------------
  // ICoreWebView2Environment (v1) -- the WebView2 factory object.
  // Doc: https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2environment
  // IID uuid(b96d755e-0319-4e92-a296-23436f46a1fc).
  // -------------------------------------------------------------------------
  ICoreWebView2Environment = interface(IUnknown)
    ['{B96D755E-0319-4E92-A296-23436F46A1FC}']
    function CreateCoreWebView2Controller(ParentWindow: HWND;
                                          const handler: IUnknown): HResult; stdcall;
    function CreateWebResourceResponse(const Content: IStream; StatusCode: SYSINT;
                                       ReasonPhrase: PWideChar; Headers: PWideChar;
                                       out Response: IUnknown): HResult; stdcall;
    function Get_BrowserVersionString(out versionInfo: PWideChar): HResult; stdcall;
    function add_NewBrowserVersionAvailable(const eventHandler: IUnknown;
                                            out token: EventRegistrationToken): HResult; stdcall;
    function remove_NewBrowserVersionAvailable(token: EventRegistrationToken): HResult; stdcall;
  end;

  // ICoreWebView2Environment2 -- adds CreateWebResourceRequest.
  // Doc: https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2environment2
  // IID uuid(41f3632b-5ef4-404f-ad82-2d606c5a9a21).
  ICoreWebView2Environment2 = interface(ICoreWebView2Environment)
    ['{41F3632B-5EF4-404F-AD82-2D606C5A9A21}']
    function CreateWebResourceRequest(uri: PWideChar; Method: PWideChar; const postData: IStream;
                                      Headers: PWideChar; out value: IUnknown): HResult; stdcall;
  end;

  // ICoreWebView2Environment3 -- adds the composition-controller factory the
  // Aefos host uses for DirectComposition (windowless) hosting.
  // Doc: https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2environment3
  // IID uuid(80a22ae3-be7c-4ce2-afe1-5a50056cdeeb).
  ICoreWebView2Environment3 = interface(ICoreWebView2Environment2)
    ['{80A22AE3-BE7C-4CE2-AFE1-5A50056CDEEB}']
    function CreateCoreWebView2CompositionController(ParentWindow: HWND;
                                                     const handler: ICoreWebView2CreateCoreWebView2CompositionControllerCompletedHandler): HResult; stdcall;
    function CreateCoreWebView2PointerInfo(out value: IUnknown): HResult; stdcall;
  end;

  // -------------------------------------------------------------------------
  // ICoreWebView2Controller (v1) -- owns windowing/visibility/bounds/focus.
  // Doc: https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2controller
  // IID uuid(4d00c0d1-9434-4eb6-8078-8697a560334f); 23 members.
  // ParentWindow is an HWND in the header; declared Pointer (same width) because
  // Aefos never calls the ParentWindow accessors and does not need the handle type.
  // -------------------------------------------------------------------------
  ICoreWebView2Controller = interface(IUnknown)
    ['{4D00C0D1-9434-4EB6-8078-8697A560334F}']
    function Get_IsVisible(out IsVisible: Integer): HResult; stdcall;
    function Set_IsVisible(IsVisible: Integer): HResult; stdcall;
    function Get_Bounds(out Bounds: tagRECT): HResult; stdcall;
    function Set_Bounds(Bounds: tagRECT): HResult; stdcall;
    function Get_ZoomFactor(out ZoomFactor: Double): HResult; stdcall;
    function Set_ZoomFactor(ZoomFactor: Double): HResult; stdcall;
    function add_ZoomFactorChanged(const eventHandler: IUnknown;
                                   out token: EventRegistrationToken): HResult; stdcall;
    function remove_ZoomFactorChanged(token: EventRegistrationToken): HResult; stdcall;
    function SetBoundsAndZoomFactor(Bounds: tagRECT; ZoomFactor: Double): HResult; stdcall;
    function MoveFocus(reason: COREWEBVIEW2_MOVE_FOCUS_REASON): HResult; stdcall;
    function add_MoveFocusRequested(const eventHandler: IUnknown;
                                    out token: EventRegistrationToken): HResult; stdcall;
    function remove_MoveFocusRequested(token: EventRegistrationToken): HResult; stdcall;
    function add_GotFocus(const eventHandler: IUnknown;
                          out token: EventRegistrationToken): HResult; stdcall;
    function remove_GotFocus(token: EventRegistrationToken): HResult; stdcall;
    function add_LostFocus(const eventHandler: IUnknown;
                           out token: EventRegistrationToken): HResult; stdcall;
    function remove_LostFocus(token: EventRegistrationToken): HResult; stdcall;
    function add_AcceleratorKeyPressed(const eventHandler: IUnknown;
                                       out token: EventRegistrationToken): HResult; stdcall;
    function remove_AcceleratorKeyPressed(token: EventRegistrationToken): HResult; stdcall;
    function Get_ParentWindow(out ParentWindow: Pointer): HResult; stdcall;
    function Set_ParentWindow(ParentWindow: Pointer): HResult; stdcall;
    function NotifyParentWindowPositionChanged: HResult; stdcall;
    function Close: HResult; stdcall;
    function Get_CoreWebView2(out CoreWebView2: ICoreWebView2): HResult; stdcall;
  end;

  // ICoreWebView2Controller2 -- adds the DefaultBackgroundColor pair the Aefos
  // host paints behind the page to kill the cold-load black flash.
  // Doc: https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2controller2
  // IID uuid(c979903e-d4ca-4228-92eb-47ee3fa96eab).
  ICoreWebView2Controller2 = interface(ICoreWebView2Controller)
    ['{C979903E-D4CA-4228-92EB-47EE3FA96EAB}']
    function Get_DefaultBackgroundColor(out value: COREWEBVIEW2_COLOR): HResult; stdcall;
    function Set_DefaultBackgroundColor(value: COREWEBVIEW2_COLOR): HResult; stdcall;
  end;

  // -------------------------------------------------------------------------
  // ICoreWebView2CompositionController -- visual (windowless) hosting: connect a
  // composition visual and feed input to the WebView.
  // Doc: https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2compositioncontroller
  // IID uuid(3df9b733-b9ae-4a15-86b4-eb9ee9826469); 8 members.
  // Cursor is an HCURSOR in the header; declared Pointer (same width) -- Aefos
  // never reads the cursor.
  // -------------------------------------------------------------------------
  ICoreWebView2CompositionController = interface(IUnknown)
    ['{3DF9B733-B9AE-4A15-86B4-EB9EE9826469}']
    function Get_RootVisualTarget(out target: IUnknown): HResult; stdcall;
    function Set_RootVisualTarget(const target: IUnknown): HResult; stdcall;
    function SendMouseInput(eventKind: COREWEBVIEW2_MOUSE_EVENT_KIND;
                            virtualKeys: COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS; mouseData: SYSUINT;
                            point: tagPOINT): HResult; stdcall;
    function SendPointerInput(eventKind: COREWEBVIEW2_POINTER_EVENT_KIND;
                              const pointerInfo: IUnknown): HResult; stdcall;
    function Get_Cursor(out Cursor: Pointer): HResult; stdcall;
    function Get_SystemCursorId(out SystemCursorId: SYSUINT): HResult; stdcall;
    function add_CursorChanged(const eventHandler: IUnknown;
                               out token: EventRegistrationToken): HResult; stdcall;
    function remove_CursorChanged(token: EventRegistrationToken): HResult; stdcall;
  end;

  // -------------------------------------------------------------------------
  // Async creation completed handlers (single Invoke each).
  // Env handler doc: https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2createcorewebview2environmentcompletedhandler
  //   IID uuid(4e8a3389-c9d8-4bd2-b6b5-124fee6cc14d).
  // Composition-controller handler doc: https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2createcorewebview2compositioncontrollercompletedhandler
  //   IID uuid(02fab84b-1428-4fb7-ad45-1b2e64736184).
  // -------------------------------------------------------------------------
  ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler = interface(IUnknown)
    ['{4E8A3389-C9D8-4BD2-B6B5-124FEE6CC14D}']
    function Invoke(errorCode: HResult; const result: ICoreWebView2Environment): HResult; stdcall;
  end;

  ICoreWebView2CreateCoreWebView2CompositionControllerCompletedHandler = interface(IUnknown)
    ['{02FAB84B-1428-4FB7-AD45-1B2E64736184}']
    function Invoke(errorCode: HResult; const result: ICoreWebView2CompositionController): HResult; stdcall;
  end;

  {$IFDEF FPC}
  // -------------------------------------------------------------------------
  // Windowed controller-completed handler + FPC handler idiom (Lazarus host).
  //
  // ICoreWebView2CreateCoreWebView2ControllerCompletedHandler -- the WINDOWED
  // twin of the composition handler above.
  // Microsoft ABI: IID {6C4819F3-C9B7-4260-8127-C9F5BDE7F68C}, single method
  //   Invoke(errorCode: HRESULT; createdController: ICoreWebView2Controller).
  // Doc: https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2createcorewebview2controllercompletedhandler
  //
  // The Delphi build hosts via the composition (windowless) controller and never
  // calls CreateCoreWebView2Controller, so this windowed handler is a first-class
  // need only for the Lazarus windowed host. It is promoted here from the merged
  // FPC spike's LOCAL probe declaration (meta/lazarus-port/07-webview2-fpc-spike.md,
  // "One local ABI addition"); its IID + Invoke slot were verified byte-correct
  // against the Microsoft ABI by webview2-specialist in that spike's review
  // (PR #237). Guarded {$IFDEF FPC} so the Delphi .dcu stays byte-identical -- the
  // interface is net-new and additive, no existing declaration is touched.
  // -------------------------------------------------------------------------
  ICoreWebView2CreateCoreWebView2ControllerCompletedHandler = interface(IUnknown)
    ['{6C4819F3-C9B7-4260-8127-C9F5BDE7F68C}']
    function Invoke(errorCode: HResult;
      const createdController: ICoreWebView2Controller): HResult; stdcall;
  end;

  // -------------------------------------------------------------------------
  // FPC handler idiom -- replaces the compiled-out Callback<> closure adapter.
  //
  // FPC 3.2.2 has no `reference to function` (anonymous methods land only in
  // 3.3.1+), so the Callback<> record above is excluded under FPC. Each WebView2
  // completion / event handler is instead surfaced as an ordinary
  // TInterfacedObject implementing EXACTLY ONE single-Invoke WebView2 interface
  // (so its interface pointer coincides with the IUnknown pointer WebView2
  // receives -- the same single-Invoke layout invariant the Callback<>
  // reinterpret relied on), wrapping a plain `of object` method the Lazarus host
  // supplies. Method pointers ARE supported by FPC 3.2.2; only closures are not.
  // This is idiom (a) recommended by the spike. No ABI is added or changed here
  // -- these are ordinary implementors of the interfaces declared above.
  // -------------------------------------------------------------------------
  TAefosWv2EnvCompletedProc = function(errorCode: HResult;
    const AEnvironment: ICoreWebView2Environment): HResult of object;
  TAefosWv2ControllerCompletedProc = function(errorCode: HResult;
    const AController: ICoreWebView2Controller): HResult of object;
  TAefosWv2NavCompletedProc = function(const ASender: ICoreWebView2;
    const AArgs: ICoreWebView2NavigationCompletedEventArgs): HResult of object;
  TAefosWv2WebMessageProc = function(const ASender: ICoreWebView2;
    const AArgs: ICoreWebView2WebMessageReceivedEventArgs): HResult of object;

  TAefosWv2EnvCompletedHandler = class(TInterfacedObject,
    ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler)
  private
    FProc: TAefosWv2EnvCompletedProc;
  public
    constructor Create(const AProc: TAefosWv2EnvCompletedProc);
    function Invoke(errorCode: HResult;
      const AEnvironment: ICoreWebView2Environment): HResult; stdcall;
  end;

  TAefosWv2ControllerCompletedHandler = class(TInterfacedObject,
    ICoreWebView2CreateCoreWebView2ControllerCompletedHandler)
  private
    FProc: TAefosWv2ControllerCompletedProc;
  public
    constructor Create(const AProc: TAefosWv2ControllerCompletedProc);
    function Invoke(errorCode: HResult;
      const AController: ICoreWebView2Controller): HResult; stdcall;
  end;

  TAefosWv2NavCompletedHandler = class(TInterfacedObject,
    ICoreWebView2NavigationCompletedEventHandler)
  private
    FProc: TAefosWv2NavCompletedProc;
  public
    constructor Create(const AProc: TAefosWv2NavCompletedProc);
    function Invoke(const ASender: ICoreWebView2;
      const AArgs: ICoreWebView2NavigationCompletedEventArgs): HResult; stdcall;
  end;

  TAefosWv2WebMessageHandler = class(TInterfacedObject,
    ICoreWebView2WebMessageReceivedEventHandler)
  private
    FProc: TAefosWv2WebMessageProc;
  public
    constructor Create(const AProc: TAefosWv2WebMessageProc);
    function Invoke(const ASender: ICoreWebView2;
      const AArgs: ICoreWebView2WebMessageReceivedEventArgs): HResult; stdcall;
  end;
  {$ENDIF}

  // -------------------------------------------------------------------------
  // ICoreWebView2EnvironmentOptions -- creation options object.
  // Doc: https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2environmentoptions
  // IID uuid(2fde08a8-1e9a-4766-8c05-95a9ceb9d1c5).
  // -------------------------------------------------------------------------
  ICoreWebView2EnvironmentOptions = interface(IUnknown)
    ['{2FDE08A8-1E9A-4766-8C05-95A9CEB9D1C5}']
    function Get_AdditionalBrowserArguments(out value: PWideChar): HResult; stdcall;
    function Set_AdditionalBrowserArguments(value: PWideChar): HResult; stdcall;
    function Get_Language(out value: PWideChar): HResult; stdcall;
    function Set_Language(value: PWideChar): HResult; stdcall;
    function Get_TargetCompatibleBrowserVersion(out value: PWideChar): HResult; stdcall;
    function Set_TargetCompatibleBrowserVersion(value: PWideChar): HResult; stdcall;
    function Get_AllowSingleSignOnUsingOSPrimaryAccount(out allow: Integer): HResult; stdcall;
    function Set_AllowSingleSignOnUsingOSPrimaryAccount(allow: Integer): HResult; stdcall;
  end;

  // -------------------------------------------------------------------------
  // AefosCallback<T1, T2> -- adapts a Delphi anonymous method (or method of
  // object) into one of the WebView2 single-method handler COM interfaces.
  //
  // Design basis (Microsoft): every WebView2 completion/event handler is a
  // COM interface deriving from IUnknown with exactly ONE Invoke method (see the
  // handler interfaces above and their Microsoft doc pages). Microsoft's own C++
  // samples wrap a lambda in such a handler via the WRL helper spelled
  // "Callback<IHandler>(lambda)". This record provides the Delphi equivalent.
  //
  // Mechanism (Delphi language contract, no Microsoft code involved): a Delphi
  // "reference to function ... stdcall" closure is itself a heap object exposing
  // IInterface plus its invocation entry at the first vtable slot after IUnknown
  // -- exactly the shape of an IUnknown-derived interface with one Invoke. So a
  // closure of the right signature can be surfaced AS the handler interface by
  // reinterpreting the reference. CreateAs<INTF> does that reinterpret; the
  // closure's own reference counting keeps the handler alive for WebView2.
  //
  // The public spelling Callback<T1,T2>.CreateAs<INTF> is retained (matching the
  // WRL "Callback" name Microsoft uses) so the host call sites read naturally.
  //
  // FPC guard: this closure->COM-handler adapter is pure Delphi language sugar
  // built on `reference to function` (anonymous methods), which FPC 3.2.2 does
  // NOT support (it landed only in FPC 3.3.1+). It is excluded under FPC; the
  // Lazarus host implements each single-Invoke WebView2 handler as an ordinary
  // TInterfacedObject class instead. This removes NO ABI declaration -- every
  // ICoreWebView2* interface, IID and vtable above is untouched.
  // -------------------------------------------------------------------------
  {$IFNDEF FPC}
  TCbStdProc1<T1> = reference to function(const P1: T1): HResult stdcall;
  TCbStdProc2<T1, T2> = reference to function(const P1: T1; const P2: T2): HResult stdcall;
  TCbStdProc3<T1, T2> = reference to function(P1: T1; P2: T2): HResult stdcall;
  TCbStdProc4<T1, T2> = reference to function(P1: T1; const P2: T2): HResult stdcall;
  TCbStdMethod1<T1> = function(P1: T1): HResult of object stdcall;
  TCbStdMethod2<T1, T2> = function(P1: T1; const P2: T2): HResult of object stdcall;

  Callback<T1, T2> = record
    type
      TStdProc1 = TCbStdProc1<T1>;
      TStdProc2 = TCbStdProc2<T1, T2>;
      TStdProc3 = TCbStdProc3<T1, T2>;
      TStdProc4 = TCbStdProc4<T1, T2>;
      TStdMethod1 = TCbStdMethod1<T1>;
      TStdMethod2 = TCbStdMethod2<T1, T2>;
    class function CreateAs<INTF>(P: TStdProc1): INTF; overload; static;
    class function CreateAs<INTF>(P: TStdProc2): INTF; overload; static;
    class function CreateAs<INTF>(P: TStdProc3): INTF; overload; static;
    class function CreateAs<INTF>(P: TStdProc4): INTF; overload; static;
    class function CreateAs<INTF>(P: TStdMethod1): INTF; overload; static;
    class function CreateAs<INTF>(P: TStdMethod2): INTF; overload; static;
  end;
  {$ENDIF}

  // -------------------------------------------------------------------------
  // TCoreWebView2EnvironmentOptions -- our concrete ICoreWebView2EnvironmentOptions.
  //
  // Design basis (Microsoft): CreateCoreWebView2EnvironmentWithOptions takes an
  // ICoreWebView2EnvironmentOptions* the caller supplies. Microsoft ships a
  // reference implementation of that object in WebView2EnvironmentOptions.h
  // (class CoreWebView2EnvironmentOptions inside the Microsoft.Web.WebView2 NuGet
  // package): four settable properties (AdditionalBrowserArguments, Language,
  // TargetCompatibleBrowserVersion, AllowSingleSignOnUsingOSPrimaryAccount), with
  // the string getters handing back a COM-allocated copy the runtime frees. This
  // class provides the same behaviour in Pascal; the code below is our own.
  // -------------------------------------------------------------------------
  TCoreWebView2EnvironmentOptions = class(TInterfacedObject, ICoreWebView2EnvironmentOptions)
  private
    FAdditionalBrowserArguments: string;
    FLanguage: string;
    FTargetCompatibleBrowserVersion: string;
    FAllowSingleSignOnUsingOSPrimaryAccount: BOOL;
    class function AllocCOMString(const DelphiString: string): PChar; static;
    class function BOOLToInt(Value: BOOL): Integer; inline; static;
  public
    // ICoreWebView2EnvironmentOptions
    function Get_AdditionalBrowserArguments(out value: PWideChar): HResult; stdcall;
    function Set_AdditionalBrowserArguments(value: PWideChar): HResult; stdcall;
    function Get_Language(out value: PWideChar): HResult; stdcall;
    function Set_Language(value: PWideChar): HResult; stdcall;
    function Get_TargetCompatibleBrowserVersion(out value: PWideChar): HResult; stdcall;
    function Set_TargetCompatibleBrowserVersion(value: PWideChar): HResult; stdcall;
    function Get_AllowSingleSignOnUsingOSPrimaryAccount(out allow: Integer): HResult; stdcall;
    function Set_AllowSingleSignOnUsingOSPrimaryAccount(allow: Integer): HResult; stdcall;
  end;

// ---------------------------------------------------------------------------
// WebView2 loader entry point.
//
// Microsoft's WebView2 SDK exports CreateCoreWebView2EnvironmentWithOptions from
// WebView2Loader.dll (documented on the globals page:
// https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/webview2-idl).
// Rather than a static/delayed "external WebView2Loader.dll" import (which would
// only ever search the process exe dir + system path), the loader is resolved at
// call time via an explicit LoadLibrary of a SETTABLE path. That is REQUIRED by
// the Aefos host: it ships WebView2Loader.dll next to its own BPL and points the
// loader there (see CompositionHost.Start). A missing loader fails gracefully at
// call time with E_FAIL -- never at unit load.
// ---------------------------------------------------------------------------

// Overrides the loader DLL path (default 'WebView2Loader.dll'); returns the
// previous value. Call before the first Create... call.
function SetWebView2Path(const APath: string): string;

// True once the loader DLL is (or was already) mapped and its export resolved.
function CheckWebView2Loaded: Boolean;

function CreateCoreWebView2EnvironmentWithOptions(
  BrowserExecutableFolder, UserDataFolder: LPCWSTR;
  const EnvironmentOptions: ICoreWebView2EnvironmentOptions;
  const Environment_created_handler: ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler): HRESULT; stdcall;

implementation

{$IFNDEF FPC}
{ Callback<T1, T2> }

// CreateAs<INTF> reinterprets the closure reference as the target handler
// interface (see the type comment for why the closure and a single-Invoke COM
// interface share one layout). PIntf(@P)^ hands back the same reference typed as
// INTF; assigning it to Result takes a reference, so the handler outlives this
// call for as long as WebView2 holds it.
class function Callback<T1, T2>.CreateAs<INTF>(P: TStdProc1): INTF;
type
  PIntf = ^INTF;
begin
  Result := PIntf(@P)^;
end;

class function Callback<T1, T2>.CreateAs<INTF>(P: TStdProc2): INTF;
type
  PIntf = ^INTF;
begin
  Result := PIntf(@P)^;
end;

class function Callback<T1, T2>.CreateAs<INTF>(P: TStdProc3): INTF;
type
  PIntf = ^INTF;
begin
  Result := PIntf(@P)^;
end;

class function Callback<T1, T2>.CreateAs<INTF>(P: TStdProc4): INTF;
type
  PIntf = ^INTF;
begin
  Result := PIntf(@P)^;
end;

// The method-of-object overloads wrap the bound method in an anonymous function
// of the matching stdcall signature, then reuse the reference-reinterpret above.
class function Callback<T1, T2>.CreateAs<INTF>(P: TStdMethod1): INTF;
begin
  Result := CreateAs<INTF>(
    function(const P1: T1): HResult stdcall
    begin
      Result := P(P1);
    end);
end;

class function Callback<T1, T2>.CreateAs<INTF>(P: TStdMethod2): INTF;
begin
  Result := CreateAs<INTF>(
    function(const P1: T1; const P2: T2): HResult stdcall
    begin
      Result := P(P1, P2);
    end);
end;
{$ENDIF}

{$IFDEF FPC}
{ FPC handler idiom -- concrete single-Invoke handlers wrapping an `of object`
  method. Each Invoke just forwards to the wrapped method (or returns S_OK if the
  host cleared it), so the host owns all policy while these stay ABI-thin. }

{ TAefosWv2EnvCompletedHandler }

constructor TAefosWv2EnvCompletedHandler.Create(const AProc: TAefosWv2EnvCompletedProc);
begin
  inherited Create;
  FProc := AProc;
end;

function TAefosWv2EnvCompletedHandler.Invoke(errorCode: HResult;
  const AEnvironment: ICoreWebView2Environment): HResult; stdcall;
begin
  if Assigned(FProc) then
    Result := FProc(errorCode, AEnvironment)
  else
    Result := S_OK;
end;

{ TAefosWv2ControllerCompletedHandler }

constructor TAefosWv2ControllerCompletedHandler.Create(const AProc: TAefosWv2ControllerCompletedProc);
begin
  inherited Create;
  FProc := AProc;
end;

function TAefosWv2ControllerCompletedHandler.Invoke(errorCode: HResult;
  const AController: ICoreWebView2Controller): HResult; stdcall;
begin
  if Assigned(FProc) then
    Result := FProc(errorCode, AController)
  else
    Result := S_OK;
end;

{ TAefosWv2NavCompletedHandler }

constructor TAefosWv2NavCompletedHandler.Create(const AProc: TAefosWv2NavCompletedProc);
begin
  inherited Create;
  FProc := AProc;
end;

function TAefosWv2NavCompletedHandler.Invoke(const ASender: ICoreWebView2;
  const AArgs: ICoreWebView2NavigationCompletedEventArgs): HResult; stdcall;
begin
  if Assigned(FProc) then
    Result := FProc(ASender, AArgs)
  else
    Result := S_OK;
end;

{ TAefosWv2WebMessageHandler }

constructor TAefosWv2WebMessageHandler.Create(const AProc: TAefosWv2WebMessageProc);
begin
  inherited Create;
  FProc := AProc;
end;

function TAefosWv2WebMessageHandler.Invoke(const ASender: ICoreWebView2;
  const AArgs: ICoreWebView2WebMessageReceivedEventArgs): HResult; stdcall;
begin
  if Assigned(FProc) then
    Result := FProc(ASender, AArgs)
  else
    Result := S_OK;
end;
{$ENDIF}

{ Loader }

type
  TCreateCoreWebView2EnvironmentWithOptions = function(
    browserExecutableFolder, userDataFolder: LPCWSTR;
    const environmentOptions: ICoreWebView2EnvironmentOptions;
    const environment_created_handler: ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler): HRESULT; stdcall;

var
  sWebView2Path: string = 'WebView2Loader.dll';
  hWebView2: THandle = 0;
  _CreateCoreWebView2EnvironmentWithOptions: TCreateCoreWebView2EnvironmentWithOptions = nil;

function SetWebView2Path(const APath: string): string;
begin
  Result := sWebView2Path;
  sWebView2Path := APath;
end;

function CheckWebView2Loaded: Boolean;
begin
  if hWebView2 = 0 then
  begin
    // FPC's Windows.LoadLibrary is the ANSI entry (PAnsiChar); the wide loader
    // path (PWideChar, matching Delphi's Unicode LoadLibrary) is LoadLibraryW.
    {$IFDEF FPC}
    hWebView2 := LoadLibraryW(PWideChar(sWebView2Path));
    {$ELSE}
    hWebView2 := LoadLibrary(PChar(sWebView2Path));
    {$ENDIF}
    if hWebView2 = 0 then
      Exit(False);
    @_CreateCoreWebView2EnvironmentWithOptions :=
      GetProcAddress(hWebView2, 'CreateCoreWebView2EnvironmentWithOptions');
  end;
  Result := True;
end;

function CreateCoreWebView2EnvironmentWithOptions(
  BrowserExecutableFolder, UserDataFolder: LPCWSTR;
  const EnvironmentOptions: ICoreWebView2EnvironmentOptions;
  const Environment_created_handler: ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler): HRESULT; stdcall;
begin
  if CheckWebView2Loaded and Assigned(_CreateCoreWebView2EnvironmentWithOptions) then
    Result := _CreateCoreWebView2EnvironmentWithOptions(
      BrowserExecutableFolder, UserDataFolder, EnvironmentOptions, Environment_created_handler)
  else
    Result := E_FAIL;
end;

{ TCoreWebView2EnvironmentOptions }

class function TCoreWebView2EnvironmentOptions.BOOLToInt(Value: BOOL): Integer;
begin
  // Normalise to a WebView2-facing BOOL of 1/0. Delphi's LongBool carries -1 for
  // True, but the ABI's BOOL convention is TRUE=1, so map explicitly.
  if Value then
    Result := 1
  else
    Result := 0;
end;

class function TCoreWebView2EnvironmentOptions.AllocCOMString(const DelphiString: string): PChar;
var
  LLength: Integer;
begin
  // WebView2 frees the returned string, so allocate it with the COM task
  // allocator (per the options-object string-getter contract).
  // System.Length(): the string-helper spelling DelphiString.Length is a Delphi
  // SysUtils helper FPC does not expose; the intrinsic is identical on both.
  LLength := Succ(System.Length(DelphiString));
  Result := CoTaskMemAlloc(LLength * SizeOf(Char));
  {$IFDEF FPC}
  // FPC's StringToWideChar takes an AnsiString source, so feeding it a
  // UnicodeString round-trips through the ANSI codepage and narrows non-ASCII
  // (browser args / language tag). Both compilers hold the string as UTF-16
  // here (DELPHIUNICODE), so copy the UTF-16 code units straight across.
  if System.Length(DelphiString) > 0 then
    Move(PWideChar(DelphiString)^, Result^, System.Length(DelphiString) * SizeOf(Char));
  Result[System.Length(DelphiString)] := #0;
  {$ELSE}
  StringToWideChar(DelphiString, Result, LLength);
  {$ENDIF}
end;

function TCoreWebView2EnvironmentOptions.Get_AdditionalBrowserArguments(out value: PWideChar): HResult;
begin
  try
    value := AllocCOMString(FAdditionalBrowserArguments);
    Result := S_OK;
  except
    Result := E_FAIL;
  end;
end;

function TCoreWebView2EnvironmentOptions.Get_Language(out value: PWideChar): HResult;
begin
  try
    value := AllocCOMString(FLanguage);
    Result := S_OK;
  except
    Result := E_FAIL;
  end;
end;

function TCoreWebView2EnvironmentOptions.Get_TargetCompatibleBrowserVersion(out value: PWideChar): HResult;
begin
  try
    value := AllocCOMString(FTargetCompatibleBrowserVersion);
    Result := S_OK;
  except
    Result := E_FAIL;
  end;
end;

function TCoreWebView2EnvironmentOptions.Get_AllowSingleSignOnUsingOSPrimaryAccount(out allow: Integer): HResult;
begin
  try
    allow := BOOLToInt(FAllowSingleSignOnUsingOSPrimaryAccount);
    Result := S_OK;
  except
    Result := E_FAIL;
  end;
end;

function TCoreWebView2EnvironmentOptions.Set_AdditionalBrowserArguments(value: PWideChar): HResult;
begin
  try
    FAdditionalBrowserArguments := string(value);
    Result := S_OK;
  except
    Result := E_FAIL;
  end;
end;

function TCoreWebView2EnvironmentOptions.Set_Language(value: PWideChar): HResult;
begin
  try
    FLanguage := string(value);
    Result := S_OK;
  except
    Result := E_FAIL;
  end;
end;

function TCoreWebView2EnvironmentOptions.Set_TargetCompatibleBrowserVersion(value: PWideChar): HResult;
begin
  try
    FTargetCompatibleBrowserVersion := string(value);
    Result := S_OK;
  except
    Result := E_FAIL;
  end;
end;

function TCoreWebView2EnvironmentOptions.Set_AllowSingleSignOnUsingOSPrimaryAccount(allow: Integer): HResult;
begin
  try
    FAllowSingleSignOnUsingOSPrimaryAccount := BOOL(allow);
    Result := S_OK;
  except
    Result := E_FAIL;
  end;
end;

initialization
  // Mask all FPU exceptions before any WebView2 / Chromium code runs: the Edge
  // runtime uses SSE/x87 in ways that would otherwise raise host FP exceptions.
  // Delphi carries femALLEXCEPT/FSetExceptMask in its RTL; FPC's equivalent is
  // the full TFPUExceptionMask set via Math.SetExceptionMask (same net effect).
  {$IFDEF FPC}
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow,
    exUnderflow, exPrecision]);
  {$ELSE}
  FSetExceptMask(femALLEXCEPT);
  {$ENDIF}

finalization
  if hWebView2 <> 0 then
  begin
    FreeLibrary(hWebView2);
    hWebView2 := 0;
  end;

end.
