unit Aefos.Win.UIAutomation;

{
  Aefos.Win.UIAutomation - minimal, hand-written COM import of the Windows
  UI Automation client interfaces that the Aefos "Desktop MCP" needs.

  WHY THIS UNIT EXISTS
  --------------------
  RAD Studio 13 (BDS 37.0) ships Winapi.UIAutomation.pas (the full UIA type
  library import). RAD Studio 12 Athens (BDS 23.0) and 11 (BDS 22.0) do NOT.
  Aefos supports D11/D12/D13, so on D11/D12 the Desktop MCP would not compile
  against the RTL. UI Automation is a PUBLIC Windows COM ABI (Microsoft's
  UIAutomationClient.h / UIAutomationCore.dll), so declaring our own bindings
  is legitimate - exactly like any Win32 declaration - and is NOT a copy of
  Embarcadero IP.

  This is a MINIMAL import: only the interfaces, GUIDs, property/pattern/
  control-type IDs and the TreeScope constants the Desktop MCP probe actually
  uses. It is NOT the whole TLB.

  CRITICAL - COM VTABLE ORDER
  ---------------------------
  COM dispatches by SLOT: the order of methods in each interface MUST match the
  Windows ABI exactly, or a call lands on the wrong function (crash / garbage).
  Every method below is transcribed method-for-method, in order, from the D13
  reference:
      <BDS 37.0>\source\rtl\win\Winapi.UIAutomation.pas
  The exact reference line is cited on each interface. Methods the Desktop MCP
  calls carry their FULL faithful signature. Methods it never calls are kept in
  their exact slot position but some exotic parameter types (event-handler /
  proxy-factory interfaces) are widened to Pointer - same 4-byte pointer size,
  same slot, never invoked, so ABI-safe. This keeps the unit self-contained
  without dragging in the rest of the type library.

  PORTABILITY (compiler >= 22.0 / D11)
  ------------------------------------
  Pure COM interfaces + GUIDs + consts only. No inline var declarations, no
  generics, no helpers, no RTL feature newer than D11. ASCII only (no BOM
  needed). Compatible with dcc32 from BDS 22.0, 23.0 and 37.0.

  Enum-typed COM parameters (TreeScope, OrientationType) are declared as plain
  4-byte integer aliases here - the UIA ABI passes these as 32-bit values, so an
  Integer alias is size-exact regardless of any MINENUMSIZE the RTL might use.
}

interface

uses
  Winapi.Windows,
  Winapi.ActiveX,
  System.Types;

const
  // Reference: Winapi.UIAutomation.pas line 29.
  CLSID_CUIAutomation: TGuid = '{FF48DBA4-60EF-4201-AA87-54103EEF594E}';

  // TreeScope enum values (reference lines 550-562). Passed as 32-bit.
  TreeScope_None        = $0;
  TreeScope_Element     = $1;
  TreeScope_Children    = $2;
  TreeScope_Descendants = $4;
  TreeScope_Subtree     = $7;
  TreeScope_Parent      = $8;
  TreeScope_Ancestors   = $10;

  // Property IDs (reference lines 948-1032).
  UIA_ControlTypePropertyId  = $7533; // 30003
  UIA_NamePropertyId         = $7535; // 30005
  UIA_AutomationIdPropertyId = $753B; // 30011
  UIA_ValueValuePropertyId   = $755D; // 30045

  // Pattern IDs (reference lines 865-869).
  UIA_InvokePatternId = $2710; // 10000
  UIA_ValuePatternId  = $2712; // 10002

  // Control-type IDs (reference lines 1787-1861).
  UIA_ButtonControlTypeId   = $C350; // 50000
  UIA_EditControlTypeId     = $C354; // 50004
  UIA_MenuBarControlTypeId  = $C35A; // 50010
  UIA_MenuItemControlTypeId = $C35B; // 50011
  UIA_TextControlTypeId     = $C364; // 50020
  UIA_ToolBarControlTypeId  = $C365; // 50021
  UIA_GroupControlTypeId    = $C36A; // 50026
  UIA_DocumentControlTypeId = $C36E; // 50030
  UIA_WindowControlTypeId   = $C370; // 50032
  UIA_PaneControlTypeId     = $C371; // 50033
  UIA_TitleBarControlTypeId = $C375; // 50037

type
  // ABI scalar aliases (reference lines 861/938/1783). All 4-byte on Win32/64.
  UIA_PROPERTY_ID    = Cardinal;
  UIA_PATTERN_ID     = Cardinal;
  UIA_CONTROLTYPE_ID = Cardinal;
  // Enum params widened to a size-exact 32-bit alias (see header note).
  TreeScope          = Integer;
  OrientationType    = Integer;

  PUIA_PROPERTY_ID = ^UIA_PROPERTY_ID;

  // Forward declarations.
  IUIAutomationCondition = interface;
  IUIAutomationElement = interface;
  IUIAutomationElementArray = interface;
  IUIAutomationTreeWalker = interface;
  IUIAutomationCacheRequest = interface;
  IUIAutomation = interface;

  PIUIAutomationCondition = ^IUIAutomationCondition;

  // Reference: Winapi.UIAutomation.pas line 3063. Marker interface, no methods.
  IUIAutomationCondition = interface(IUnknown)
    ['{352FFBA8-0973-437C-A61F-F64CAFD81DF9}']
  end;

  // Reference: Winapi.UIAutomation.pas line 3085. Never called by the probe;
  // declared (empty, correct GUID) only as a parameter type for the *BuildCache
  // overloads below, which the probe never invokes.
  IUIAutomationCacheRequest = interface(IUnknown)
    ['{B32A92B5-BC25-4078-9C08-D7EE95C48E03}']
  end;

  // Reference: Winapi.UIAutomation.pas line 3072.
  IUIAutomationElementArray = interface(IUnknown)
    ['{14314595-B4BC-4055-95F2-58F2E42C9855}']
    function get_Length(out length: Integer): HRESULT; stdcall;                                        // ref 3075
    function GetElement(index: Integer; out element: IUIAutomationElement): HRESULT; stdcall;          // ref 3077
  end;

  // Reference: Winapi.UIAutomation.pas line 3112. Full faithful vtable
  // (82 slots). Slots called by the Desktop MCP are marked <CALLED>.
  IUIAutomationElement = interface(IUnknown)
    ['{D22108AA-8AC5-49A5-837B-37BBB3D7591E}']
    function SetFocus: HRESULT; stdcall;                                                                                                                  // ref 3115
    function GetRuntimeId(out runtimeId: SAFEARRAY): HRESULT; stdcall;                                                                                    // ref 3117
    function FindFirst(scope: TreeScope; condition: IUIAutomationCondition; out found: IUIAutomationElement): HRESULT; stdcall;                           // ref 3119 <CALLED>
    function FindAll(scope: TreeScope; condition: IUIAutomationCondition; out found: IUIAutomationElementArray): HRESULT; stdcall;                        // ref 3121 <CALLED>
    function FindFirstBuildCache(scope: TreeScope; condition: IUIAutomationCondition; cacheRequest: IUIAutomationCacheRequest; out found: IUIAutomationElement): HRESULT; stdcall;             // ref 3123
    function FindAllBuildCache(scope: TreeScope; condition: IUIAutomationCondition; cacheRequest: IUIAutomationCacheRequest; out found: IUIAutomationElementArray): HRESULT; stdcall;          // ref 3125
    function BuildUpdatedCache(cacheRequest: IUIAutomationCacheRequest; out updatedElement: IUIAutomationElement): HRESULT; stdcall;                       // ref 3127
    function GetCurrentPropertyValue(propertyId: UIA_PROPERTY_ID; out retVal: OleVariant): HRESULT; stdcall;                                              // ref 3129 <CALLED>
    function GetCurrentPropertyValueEx(propertyId: UIA_PROPERTY_ID; ignoreDefaultValue: BOOL; out retVal: OleVariant): HRESULT; stdcall;                  // ref 3131
    function GetCachedPropertyValue(propertyId: UIA_PROPERTY_ID; out retVal: OleVariant): HRESULT; stdcall;                                               // ref 3133
    function GetCachedPropertyValueEx(propertyId: UIA_PROPERTY_ID; ignoreDefaultValue: BOOL; out retVal: OleVariant): HRESULT; stdcall;                   // ref 3135
    function GetCurrentPatternAs(patternId: UIA_PATTERN_ID; riid: PGuid; out patternObject: Pointer): HRESULT; stdcall;                                   // ref 3137
    function GetCachedPatternAs(patternId: UIA_PATTERN_ID; riid: PGuid; out patternObject: Pointer): HRESULT; stdcall;                                    // ref 3139
    function GetCurrentPattern(patternId: UIA_PATTERN_ID; out patternObject: IUnknown): HRESULT; stdcall;                                                 // ref 3141 <CALLED>
    function GetCachedPattern(patternId: UIA_PATTERN_ID; out patternObject: IUnknown): HRESULT; stdcall;                                                  // ref 3143
    function GetCachedParent(out parent: IUIAutomationElement): HRESULT; stdcall;                                                                         // ref 3145
    function GetCachedChildren(out children: IUIAutomationElementArray): HRESULT; stdcall;                                                                // ref 3147
    function get_CurrentProcessId(out retVal: Integer): HRESULT; stdcall;                                                                                 // ref 3149
    function get_CurrentControlType(out retVal: UIA_CONTROLTYPE_ID): HRESULT; stdcall;                                                                    // ref 3151
    function get_CurrentLocalizedControlType(out retVal: PChar): HRESULT; stdcall;                                                                        // ref 3153
    function get_CurrentName(out retVal: PChar): HRESULT; stdcall;                                                                                        // ref 3155
    function get_CurrentAcceleratorKey(out retVal: PChar): HRESULT; stdcall;                                                                              // ref 3157
    function get_CurrentAccessKey(out retVal: PChar): HRESULT; stdcall;                                                                                   // ref 3159
    function get_CurrentHasKeyboardFocus(out retVal: BOOL): HRESULT; stdcall;                                                                             // ref 3161
    function get_CurrentIsKeyboardFocusable(out retVal: BOOL): HRESULT; stdcall;                                                                          // ref 3163
    function get_CurrentIsEnabled(out retVal: BOOL): HRESULT; stdcall;                                                                                    // ref 3165
    function get_CurrentAutomationId(out retVal: PChar): HRESULT; stdcall;                                                                                // ref 3167
    function get_CurrentClassName(out retVal: PChar): HRESULT; stdcall;                                                                                   // ref 3169
    function get_CurrentHelpText(out retVal: PChar): HRESULT; stdcall;                                                                                    // ref 3171
    function get_CurrentCulture(out retVal: Integer): HRESULT; stdcall;                                                                                   // ref 3173
    function get_CurrentIsControlElement(out retVal: BOOL): HRESULT; stdcall;                                                                             // ref 3175
    function get_CurrentIsContentElement(out retVal: BOOL): HRESULT; stdcall;                                                                             // ref 3177
    function get_CurrentIsPassword(out retVal: BOOL): HRESULT; stdcall;                                                                                   // ref 3179
    function get_CurrentNativeWindowHandle(out retVal: HWND): HRESULT; stdcall;                                                                           // ref 3181 <CALLED>
    function get_CurrentItemType(out retVal: PChar): HRESULT; stdcall;                                                                                    // ref 3183
    function get_CurrentIsOffscreen(out retVal: BOOL): HRESULT; stdcall;                                                                                  // ref 3185
    function get_CurrentOrientation(out retVal: OrientationType): HRESULT; stdcall;                                                                       // ref 3187
    function get_CurrentFrameworkId(out retVal: PChar): HRESULT; stdcall;                                                                                 // ref 3189
    function get_CurrentIsRequiredForForm(out retVal: BOOL): HRESULT; stdcall;                                                                            // ref 3191
    function get_CurrentItemStatus(out retVal: PChar): HRESULT; stdcall;                                                                                  // ref 3193
    function get_CurrentBoundingRectangle(out retVal: TRectF): HRESULT; stdcall;                                                                          // ref 3195
    function get_CurrentLabeledBy(out retVal: IUIAutomationElement): HRESULT; stdcall;                                                                    // ref 3197
    function get_CurrentAriaRole(out retVal: PChar): HRESULT; stdcall;                                                                                    // ref 3199
    function get_CurrentAriaProperties(out retVal: PChar): HRESULT; stdcall;                                                                              // ref 3201
    function get_CurrentIsDataValidForForm(out retVal: BOOL): HRESULT; stdcall;                                                                           // ref 3203
    function get_CurrentControllerFor(out retVal: IUIAutomationElementArray): HRESULT; stdcall;                                                           // ref 3205
    function get_CurrentDescribedBy(out retVal: IUIAutomationElementArray): HRESULT; stdcall;                                                             // ref 3207
    function get_CurrentFlowsTo(out retVal: IUIAutomationElementArray): HRESULT; stdcall;                                                                 // ref 3209
    function get_CurrentProviderDescription(out retVal: PChar): HRESULT; stdcall;                                                                         // ref 3211
    function get_CachedProcessId(out retVal: Integer): HRESULT; stdcall;                                                                                  // ref 3213
    function get_CachedControlType(out retVal: UIA_CONTROLTYPE_ID): HRESULT; stdcall;                                                                     // ref 3215
    function get_CachedLocalizedControlType(out retVal: PChar): HRESULT; stdcall;                                                                         // ref 3217
    function get_CachedName(out retVal: PChar): HRESULT; stdcall;                                                                                         // ref 3219
    function get_CachedAcceleratorKey(out retVal: PChar): HRESULT; stdcall;                                                                               // ref 3221
    function get_CachedAccessKey(out retVal: PChar): HRESULT; stdcall;                                                                                    // ref 3223
    function get_CachedHasKeyboardFocus(out retVal: BOOL): HRESULT; stdcall;                                                                              // ref 3225
    function get_CachedIsKeyboardFocusable(out retVal: BOOL): HRESULT; stdcall;                                                                           // ref 3227
    function get_CachedIsEnabled(out retVal: BOOL): HRESULT; stdcall;                                                                                     // ref 3229
    function get_CachedAutomationId(out retVal: PChar): HRESULT; stdcall;                                                                                 // ref 3231
    function get_CachedClassName(out retVal: PChar): HRESULT; stdcall;                                                                                    // ref 3233
    function get_CachedHelpText(out retVal: PChar): HRESULT; stdcall;                                                                                     // ref 3235
    function get_CachedCulture(out retVal: Integer): HRESULT; stdcall;                                                                                    // ref 3237
    function get_CachedIsControlElement(out retVal: BOOL): HRESULT; stdcall;                                                                              // ref 3239
    function get_CachedIsContentElement(out retVal: BOOL): HRESULT; stdcall;                                                                              // ref 3241
    function get_CachedIsPassword(out retVal: BOOL): HRESULT; stdcall;                                                                                    // ref 3243
    function get_CachedNativeWindowHandle(out retVal: HWND): HRESULT; stdcall;                                                                            // ref 3245
    function get_CachedItemType(out retVal: PChar): HRESULT; stdcall;                                                                                     // ref 3247
    function get_CachedIsOffscreen(out retVal: BOOL): HRESULT; stdcall;                                                                                   // ref 3249
    function get_CachedOrientation(out retVal: OrientationType): HRESULT; stdcall;                                                                        // ref 3251
    function get_CachedFrameworkId(out retVal: PChar): HRESULT; stdcall;                                                                                  // ref 3253
    function get_CachedIsRequiredForForm(out retVal: BOOL): HRESULT; stdcall;                                                                             // ref 3255
    function get_CachedItemStatus(out retVal: PChar): HRESULT; stdcall;                                                                                   // ref 3257
    function get_CachedBoundingRectangle(out retVal: TRectF): HRESULT; stdcall;                                                                           // ref 3259
    function get_CachedLabeledBy(out retVal: IUIAutomationElement): HRESULT; stdcall;                                                                     // ref 3261
    function get_CachedAriaRole(out retVal: PChar): HRESULT; stdcall;                                                                                     // ref 3263
    function get_CachedAriaProperties(out retVal: PChar): HRESULT; stdcall;                                                                               // ref 3265
    function get_CachedIsDataValidForForm(out retVal: BOOL): HRESULT; stdcall;                                                                            // ref 3267
    function get_CachedControllerFor(out retVal: IUIAutomationElementArray): HRESULT; stdcall;                                                            // ref 3269
    function get_CachedDescribedBy(out retVal: IUIAutomationElementArray): HRESULT; stdcall;                                                              // ref 3271
    function get_CachedFlowsTo(out retVal: IUIAutomationElementArray): HRESULT; stdcall;                                                                  // ref 3273
    function get_CachedProviderDescription(out retVal: PChar): HRESULT; stdcall;                                                                          // ref 3275
    function GetClickablePoint(out clickable: TPointF; out gotClickable: BOOL): HRESULT; stdcall;                                                         // ref 3277
  end;

  // Reference: Winapi.UIAutomation.pas line 3285. Full faithful vtable (13 slots).
  IUIAutomationTreeWalker = interface(IUnknown)
    ['{4042C624-389C-4AFC-A630-9DF854A541FC}']
    function GetParentElement(element: IUIAutomationElement; out parent: IUIAutomationElement): HRESULT; stdcall;                                         // ref 3287
    function GetFirstChildElement(element: IUIAutomationElement; out first: IUIAutomationElement): HRESULT; stdcall;                                      // ref 3289 <CALLED>
    function GetLastChildElement(element: IUIAutomationElement; out last: IUIAutomationElement): HRESULT; stdcall;                                        // ref 3291
    function GetNextSiblingElement(element: IUIAutomationElement; out next: IUIAutomationElement): HRESULT; stdcall;                                      // ref 3293 <CALLED>
    function GetPreviousSiblingElement(element: IUIAutomationElement; out previous: IUIAutomationElement): HRESULT; stdcall;                              // ref 3295
    function NormalizeElement(element: IUIAutomationElement; out normalized: IUIAutomationElement): HRESULT; stdcall;                                     // ref 3297
    function GetParentElementBuildCache(element: IUIAutomationElement; cacheRequest: IUIAutomationCacheRequest; out parent: IUIAutomationElement): HRESULT; stdcall;      // ref 3299
    function GetFirstChildElementBuildCache(element: IUIAutomationElement; cacheRequest: IUIAutomationCacheRequest; out first: IUIAutomationElement): HRESULT; stdcall;   // ref 3301
    function GetLastChildElementBuildCache(element: IUIAutomationElement; cacheRequest: IUIAutomationCacheRequest; out last: IUIAutomationElement): HRESULT; stdcall;     // ref 3303
    function GetNextSiblingElementBuildCache(element: IUIAutomationElement; cacheRequest: IUIAutomationCacheRequest; out next: IUIAutomationElement): HRESULT; stdcall;   // ref 3305
    function GetPreviousSiblingElementBuildCache(element: IUIAutomationElement; cacheRequest: IUIAutomationCacheRequest; out previous: IUIAutomationElement): HRESULT; stdcall; // ref 3307
    function NormalizeElementBuildCache(element: IUIAutomationElement; cacheRequest: IUIAutomationCacheRequest; out normalized: IUIAutomationElement): HRESULT; stdcall;  // ref 3309
    function get_Condition(out condition: IUIAutomationCondition): HRESULT; stdcall;                                                                      // ref 3311
  end;

  // Reference: Winapi.UIAutomation.pas line 3507. Full faithful vtable (55 slots).
  // Event-handler / proxy-factory / IAccessible parameter types (never called by
  // the Desktop MCP) are widened to Pointer - same pointer size, same slot.
  IUIAutomation = interface(IUnknown)
    ['{30CBE57D-D9D0-452A-AB13-7AC5AC4825EE}']
    function CompareElements(el1: IUIAutomationElement; el2: IUIAutomationElement; out areSame: BOOL): HRESULT; stdcall;                                  // ref 3510
    function CompareRuntimeIds(runtimeId1: PSAFEARRAY; runtimeId2: PSAFEARRAY; out areSame: BOOL): HRESULT; stdcall;                                      // ref 3512
    function GetRootElement(out root: IUIAutomationElement): HRESULT; stdcall;                                                                            // ref 3514 <CALLED>
    function ElementFromHandle(hwnd: HWND; out element: IUIAutomationElement): HRESULT; stdcall;                                                          // ref 3516 <CALLED>
    function ElementFromPoint(pt: TPointF; out element: IUIAutomationElement): HRESULT; stdcall;                                                          // ref 3518
    function GetFocusedElement(out element: IUIAutomationElement): HRESULT; stdcall;                                                                      // ref 3520
    function GetRootElementBuildCache(cacheRequest: IUIAutomationCacheRequest; out root: IUIAutomationElement): HRESULT; stdcall;                         // ref 3522
    function ElementFromHandleBuildCache(hwnd: HWND; cacheRequest: IUIAutomationCacheRequest; out element: IUIAutomationElement): HRESULT; stdcall;       // ref 3524
    function ElementFromPointBuildCache(pt: TPointF; cacheRequest: IUIAutomationCacheRequest; out element: IUIAutomationElement): HRESULT; stdcall;       // ref 3526
    function GetFocusedElementBuildCache(cacheRequest: IUIAutomationCacheRequest; out element: IUIAutomationElement): HRESULT; stdcall;                   // ref 3528
    function CreateTreeWalker(pCondition: IUIAutomationCondition; out walker: IUIAutomationTreeWalker): HRESULT; stdcall;                                 // ref 3530
    function get_ControlViewWalker(out walker: IUIAutomationTreeWalker): HRESULT; stdcall;                                                                // ref 3532 <CALLED>
    function get_ContentViewWalker(out walker: IUIAutomationTreeWalker): HRESULT; stdcall;                                                                // ref 3534
    function get_RawViewWalker(out walker: IUIAutomationTreeWalker): HRESULT; stdcall;                                                                    // ref 3536
    function get_RawViewCondition(out condition: IUIAutomationCondition): HRESULT; stdcall;                                                               // ref 3538
    function get_ControlViewCondition(out condition: IUIAutomationCondition): HRESULT; stdcall;                                                           // ref 3540
    function get_ContentViewCondition(out condition: IUIAutomationCondition): HRESULT; stdcall;                                                           // ref 3542
    function CreateCacheRequest(out cacheRequest: IUIAutomationCacheRequest): HRESULT; stdcall;                                                           // ref 3544
    function CreateTrueCondition(out newCondition: IUIAutomationCondition): HRESULT; stdcall;                                                             // ref 3546 <CALLED>
    function CreateFalseCondition(out newCondition: IUIAutomationCondition): HRESULT; stdcall;                                                            // ref 3548
    function CreatePropertyCondition(propertyId: UIA_PROPERTY_ID; value: OleVariant; out newCondition: IUIAutomationCondition): HRESULT; stdcall;         // ref 3550 <CALLED>
    function CreatePropertyConditionEx(propertyId: UIA_PROPERTY_ID; value: OleVariant; flags: Integer; out newCondition: IUIAutomationCondition): HRESULT; stdcall;   // ref 3552
    function CreateAndCondition(condition1: IUIAutomationCondition; condition2: IUIAutomationCondition; out newCondition: IUIAutomationCondition): HRESULT; stdcall;   // ref 3554
    function CreateAndConditionFromArray(conditions: PSAFEARRAY; out newCondition: IUIAutomationCondition): HRESULT; stdcall;                             // ref 3556
    function CreateAndConditionFromNativeArray(conditions: PIUIAutomationCondition; conditionCount: Integer; out newCondition: IUIAutomationCondition): HRESULT; stdcall; // ref 3558
    function CreateOrCondition(condition1: IUIAutomationCondition; condition2: IUIAutomationCondition; out newCondition: IUIAutomationCondition): HRESULT; stdcall;    // ref 3560
    function CreateOrConditionFromArray(conditions: PSAFEARRAY; out newCondition: IUIAutomationCondition): HRESULT; stdcall;                              // ref 3562
    function CreateOrConditionFromNativeArray(conditions: PIUIAutomationCondition; conditionCount: Integer; out newCondition: IUIAutomationCondition): HRESULT; stdcall;  // ref 3564
    function CreateNotCondition(condition: IUIAutomationCondition; out newCondition: IUIAutomationCondition): HRESULT; stdcall;                           // ref 3566
    function AddAutomationEventHandler(eventId: Integer; element: IUIAutomationElement; scope: TreeScope; cacheRequest: IUIAutomationCacheRequest; handler: Pointer): HRESULT; stdcall; // ref 3568
    function RemoveAutomationEventHandler(eventId: Integer; element: IUIAutomationElement; handler: Pointer): HRESULT; stdcall;                           // ref 3570
    function AddPropertyChangedEventHandlerNativeArray(element: IUIAutomationElement; scope: TreeScope; cacheRequest: IUIAutomationCacheRequest; handler: Pointer; propertyArray: PUIA_PROPERTY_ID; propertyCount: Integer): HRESULT; stdcall; // ref 3572
    function AddPropertyChangedEventHandler(element: IUIAutomationElement; scope: TreeScope; cacheRequest: IUIAutomationCacheRequest; handler: Pointer; propertyArray: PSAFEARRAY): HRESULT; stdcall; // ref 3574
    function RemovePropertyChangedEventHandler(element: IUIAutomationElement; handler: Pointer): HRESULT; stdcall;                                        // ref 3576
    function AddStructureChangedEventHandler(element: IUIAutomationElement; scope: TreeScope; cacheRequest: IUIAutomationCacheRequest; handler: Pointer): HRESULT; stdcall; // ref 3578
    function RemoveStructureChangedEventHandler(element: IUIAutomationElement; handler: Pointer): HRESULT; stdcall;                                       // ref 3580
    function AddFocusChangedEventHandler(cacheRequest: IUIAutomationCacheRequest; handler: Pointer): HRESULT; stdcall;                                    // ref 3582
    function RemoveFocusChangedEventHandler(handler: Pointer): HRESULT; stdcall;                                                                          // ref 3584
    function RemoveAllEventHandlers: HRESULT; stdcall;                                                                                                    // ref 3586
    function IntNativeArrayToSafeArray(arr: PInteger; arrayCount: Integer; out safeArray: SAFEARRAY): HRESULT; stdcall;                                   // ref 3588
    function IntSafeArrayToNativeArray(intArray: PSAFEARRAY; out arr: Integer; out arrayCount: Integer): HRESULT; stdcall;                                // ref 3590
    function RectToVariant(rc: TRectF; out varRc: OleVariant): HRESULT; stdcall;                                                                          // ref 3592
    function VariantToRect(varRc: OleVariant; out rc: TRectF): HRESULT; stdcall;                                                                          // ref 3594
    function SafeArrayToRectNativeArray(rects: PSAFEARRAY; out rectArray: TRectF; out rectArrayCount: Integer): HRESULT; stdcall;                         // ref 3596
    function CreateProxyFactoryEntry(factory: Pointer; out factoryEntry: IUnknown): HRESULT; stdcall;                                                     // ref 3598
    function get_ProxyFactoryMapping(out factoryMapping: IUnknown): HRESULT; stdcall;                                                                     // ref 3600
    function GetPropertyProgrammaticName(propertyId: UIA_PROPERTY_ID; out name: PChar): HRESULT; stdcall;                                                 // ref 3602
    function GetPatternProgrammaticName(pattern: UIA_PATTERN_ID; out name: PChar): HRESULT; stdcall;                                                      // ref 3604
    function PollForPotentialSupportedPatterns(pElement: IUIAutomationElement; out patternIds: SAFEARRAY; out patternNames: SAFEARRAY): HRESULT; stdcall; // ref 3606
    function PollForPotentialSupportedProperties(pElement: IUIAutomationElement; out propertyIds: SAFEARRAY; out propertyNames: SAFEARRAY): HRESULT; stdcall; // ref 3608
    function CheckNotSupported(value: OleVariant; out isNotSupported: BOOL): HRESULT; stdcall;                                                            // ref 3610
    function get_ReservedNotSupportedValue(out notSupportedValue: IUnknown): HRESULT; stdcall;                                                            // ref 3612
    function get_ReservedMixedAttributeValue(out mixedAttributeValue: IUnknown): HRESULT; stdcall;                                                        // ref 3614
    function ElementFromIAccessible(accessible: Pointer; childId: Integer; out element: IUIAutomationElement): HRESULT; stdcall;                          // ref 3616
    function ElementFromIAccessibleBuildCache(accessible: Pointer; childId: Integer; cacheRequest: IUIAutomationCacheRequest; out element: IUIAutomationElement): HRESULT; stdcall; // ref 3618
  end;

  // Reference: Winapi.UIAutomation.pas line 4774. Declared for completeness; the
  // read-only probe never calls SetValue (mutation is out of scope).
  IUIAutomationValuePattern = interface(IUnknown)
    ['{A94CD8B1-0844-4CD6-9D2D-640537AB39E9}']
    function SetValue(val: PChar): HRESULT; stdcall;                          // ref 4777
    function get_CurrentValue(out retVal: PChar): HRESULT; stdcall;          // ref 4779
    function get_CurrentIsReadOnly(out retVal: BOOL): HRESULT; stdcall;      // ref 4781
    function get_CachedValue(out retVal: PChar): HRESULT; stdcall;           // ref 4783
    function get_CachedIsReadOnly(out retVal: BOOL): HRESULT; stdcall;       // ref 4785
  end;

  // Reference: Winapi.UIAutomation.pas line 5233. Declared for completeness; the
  // read-only probe never calls Invoke (mutation is out of scope).
  IUIAutomationInvokePattern = interface(IUnknown)
    ['{FB377FBE-8EA6-46D5-9C73-6499642D3059}']
    function Invoke: HRESULT; stdcall;                                        // ref 5236
  end;

implementation

end.
