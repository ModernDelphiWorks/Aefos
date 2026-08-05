unit Aefos.OTA.Terminal.Core.ConPTY;

{$IFDEF FPC}{$mode delphi}{$H+}{$ENDIF}

interface

uses
  {$IFDEF FPC}Windows, SysUtils{$ELSE}Winapi.Windows, System.SysUtils{$ENDIF};

const
  PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = $00020016;
  EXTENDED_STARTUPINFO_PRESENT = $00080000;

type
  HPCON = THandle;

  TCreatePseudoConsole = function(ASize: TCoord; AhInput: THandle; AhOutput: THandle; AdwFlags: DWORD; out AphPC: HPCON): HRESULT; stdcall;
  TResizePseudoConsole = function(AhPC: HPCON; ASize: TCoord): HRESULT; stdcall;
  TClosePseudoConsole = procedure(AhPC: HPCON); stdcall;

  TInitializeProcThreadAttributeList = function(AlpAttributeList: Pointer; AdwAttributeCount: DWORD; AdwFlags: DWORD; var AlpSize: NativeUint): BOOL; stdcall;
  TUpdateProcThreadAttribute = function(AlpAttributeList: Pointer; AdwFlags: DWORD; AAttribute: NativeUint; AlpValue: Pointer; AcbSize: NativeUint; AlpPreviousValue: Pointer; AlpReturnSize: PNativeUint): BOOL; stdcall;
  TDeleteProcThreadAttributeList = procedure(AlpAttributeList: Pointer); stdcall;

  TStartupInfoEx = record
    StartupInfo: TStartupInfo;
    lpAttributeList: Pointer;
  end;

  /// <summary>
  /// Wrapper for Windows Pseudo Console (ConPTY) API.
  /// </summary>
  TConPTY = class
  private
    FModule: HMODULE;
    FCreatePseudoConsole: TCreatePseudoConsole;
    FResizePseudoConsole: TResizePseudoConsole;
    FClosePseudoConsole: TClosePseudoConsole;
    FInitializeProcThreadAttributeList: TInitializeProcThreadAttributeList;
    FUpdateProcThreadAttribute: TUpdateProcThreadAttribute;
    FDeleteProcThreadAttributeList: TDeleteProcThreadAttributeList;
    FIsAvailable: Boolean;
    class var FInstance: TConPTY;
    procedure _LoadFunctions;
  public
    constructor Create;
    destructor Destroy; override;

    /// <summary>
    /// Lazily-created process-wide singleton accessor. Freed at unit
    /// finalization.
    /// </summary>
    class function Instance: TConPTY; static;

    /// <summary>
    /// Returns True if ConPTY API is available on the current OS.
    /// </summary>
    property IsAvailable: Boolean read FIsAvailable;

    function CreatePseudoConsole(ASize: TCoord; AInput: THandle; AOutput: THandle; AFlags: DWORD; out AphPC: HPCON): HRESULT;
    function ResizePseudoConsole(AhPC: HPCON; ASize: TCoord): HRESULT;
    procedure ClosePseudoConsole(AhPC: HPCON);

    function InitializeProcThreadAttributeList(AlpAttributeList: Pointer; AdwAttributeCount: DWORD; AdwFlags: DWORD; var AlpSize: NativeUint): BOOL;
    function UpdateProcThreadAttribute(AlpAttributeList: Pointer; AdwFlags: DWORD; AAttribute: NativeUint; AlpValue: Pointer; AcbSize: NativeUint; AlpPreviousValue: Pointer; AlpReturnSize: PNativeUint): BOOL;
    procedure DeleteProcThreadAttributeList(AlpAttributeList: Pointer);
  end;

implementation

{ TConPTY }

class function TConPTY.Instance: TConPTY;
begin
  if FInstance = nil then
    FInstance := TConPTY.Create;
  Result := FInstance;
end;

constructor TConPTY.Create;
begin
  inherited Create;
  _LoadFunctions;
end;

destructor TConPTY.Destroy;
begin
  if FModule <> 0 then
    FreeLibrary(FModule);
  inherited Destroy;
end;

procedure TConPTY._LoadFunctions;
begin
  FIsAvailable := False;
  FModule := GetModuleHandle('kernel32.dll');
  if FModule = 0 then
    FModule := LoadLibrary('kernel32.dll');
    
  if FModule = 0 then Exit;

  @FCreatePseudoConsole := GetProcAddress(FModule, 'CreatePseudoConsole');
  @FResizePseudoConsole := GetProcAddress(FModule, 'ResizePseudoConsole');
  @FClosePseudoConsole := GetProcAddress(FModule, 'ClosePseudoConsole');
  
  @FInitializeProcThreadAttributeList := GetProcAddress(FModule, 'InitializeProcThreadAttributeList');
  @FUpdateProcThreadAttribute := GetProcAddress(FModule, 'UpdateProcThreadAttribute');
  @FDeleteProcThreadAttributeList := GetProcAddress(FModule, 'DeleteProcThreadAttributeList');

  FIsAvailable := Assigned(FCreatePseudoConsole) and 
                  Assigned(FResizePseudoConsole) and 
                  Assigned(FClosePseudoConsole) and
                  Assigned(FInitializeProcThreadAttributeList) and
                  Assigned(FUpdateProcThreadAttribute) and
                  Assigned(FDeleteProcThreadAttributeList);
end;

function TConPTY.CreatePseudoConsole(ASize: TCoord; AInput: THandle; AOutput: THandle; AFlags: DWORD; out AphPC: HPCON): HRESULT;
begin
  if not FIsAvailable then
    Result := E_NOTIMPL
  else
    Result := FCreatePseudoConsole(ASize, AInput, AOutput, AFlags, AphPC);
end;

function TConPTY.ResizePseudoConsole(AhPC: HPCON; ASize: TCoord): HRESULT;
begin
  if not FIsAvailable then
    Result := E_NOTIMPL
  else
    Result := FResizePseudoConsole(AhPC, ASize);
end;

procedure TConPTY.ClosePseudoConsole(AhPC: HPCON);
begin
  if FIsAvailable then
    FClosePseudoConsole(AhPC);
end;

function TConPTY.InitializeProcThreadAttributeList(AlpAttributeList: Pointer; AdwAttributeCount: DWORD; AdwFlags: DWORD; var AlpSize: NativeUint): BOOL;
begin
  if not FIsAvailable then
    Result := False
  else
    Result := FInitializeProcThreadAttributeList(AlpAttributeList, AdwAttributeCount, AdwFlags, AlpSize);
end;

function TConPTY.UpdateProcThreadAttribute(AlpAttributeList: Pointer; AdwFlags: DWORD; AAttribute: NativeUint; AlpValue: Pointer; AcbSize: NativeUint; AlpPreviousValue: Pointer; AlpReturnSize: PNativeUint): BOOL;
begin
  if not FIsAvailable then
    Result := False
  else
    Result := FUpdateProcThreadAttribute(AlpAttributeList, AdwFlags, AAttribute, AlpValue, AcbSize, AlpPreviousValue, AlpReturnSize);
end;

procedure TConPTY.DeleteProcThreadAttributeList(AlpAttributeList: Pointer);
begin
  if FIsAvailable then
    FDeleteProcThreadAttributeList(AlpAttributeList);
end;

initialization

finalization
  if Assigned(TConPTY.FInstance) then
    FreeAndNil(TConPTY.FInstance);

end.


