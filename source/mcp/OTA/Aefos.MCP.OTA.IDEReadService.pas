unit Aefos.MCP.OTA.IDEReadService;

{
  IDE environment reads, extracted from the TMCPWorkspaceFacade god-object as a
  focused service of the SOLID split (audit S6 / facade split). Sibling of the
  action-oriented Aefos.MCP.OTA.IDEService — this one only READS IDE/host state.

  Owns GetIDEVersion, GetIDETheme, GetRecentFiles (+ the _ReadClosedFilesEntries
  registry helper) and GetProjectManagerTree. Reads come from ToolsAPI
  (IOTAIDEThemingServices250, IOTAServices, IOTAModuleServices), the recent-files
  registry hive (HKCU, via System.Win.Registry), the pure RecentFilesPolicy seam
  (ExtractReopenPath / OrderReopenEntries / NormalizeRecentFiles), and FacadeShared
  (TFacadeShared.TryProject). No mutation, no FAudit, no public-method delegation.

  GetIDEVersion is FIXED while moving: the facade version hard-coded "13.0" (wrong on
  Delphi 12 / BDS 23.0). It now derives the running version from
  IOTAServices.GetBaseRegistryKey (the live BDS hive, e.g. ...\BDS\37.0 or \23.0),
  reports that as Build, and maps it to the RAD Studio marketing Version (with the
  BDS number itself as the fallback for an unmapped release). The other four bodies
  moved VERBATIM. The facade delegates the four frozen methods to a refcounted
  FIDERead field.
}

interface

uses
  Aefos.MCP.Types;

type
  IMCPIDEReadService = interface
    ['{4A7C1E94-6D83-4B50-9F38-3C6A1B5E8D70}']
    function GetIDEVersion: TMCPRecordIDEVersion;
    function GetIDETheme: string;
    function GetRecentFiles: TArray<string>;
    function GetProjectManagerTree: TArray<TMCPRecordProjectManagerNode>;
  end;

// Factory — the facade calls this once in its constructor.
function NewMCPIDEReadService: IMCPIDEReadService;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.Generics.Collections,
  System.Win.Registry,
  Winapi.Windows,
  ToolsAPI,
  Aefos.MCP.OTA.FacadeShared,
  Aefos.MCP.OTA.RecentFilesPolicy;

type
  TMCPIDEReadService = class(TInterfacedObject, IMCPIDEReadService)
  public
    function GetIDEVersion: TMCPRecordIDEVersion;
    function GetIDETheme: string;
    function GetRecentFiles: TArray<string>;
    function GetProjectManagerTree: TArray<TMCPRecordProjectManagerNode>;
  end;

// Upper bound on the returned recent-files list. The IDE's own "Max Closed Files"
// default is 15; cap generously above it so the list is never truncated below
// what the File ▸ Reopen menu shows (faithful-to-menu, BR8 / R4).
const
  CMaxRecentFiles = 50;

function TMCPIDEReadService.GetIDEVersion: TMCPRecordIDEVersion;
var
  LResult: TMCPRecordIDEVersion;
begin
  LResult := Default(TMCPRecordIDEVersion);
  LResult.Product := 'RAD Studio';
  LResult.Version := '';
  LResult.Build   := '';
  // FIX (was hard-coded '13.0', wrong on Delphi 12 / BDS 23.0): derive the running
  // version from the live BDS registry hive. IOTAServices.GetBaseRegistryKey ends in
  // the active version, e.g. 'Software\Embarcadero\BDS\37.0' (D13) or '...\23.0'
  // (D12) — the only reliable runtime source (Core/OTA expose no version string).
  try
    TThread.Synchronize(nil, procedure
    var
      LServices: IOTAServices;
      LBase, LBds: string;
    begin
      if not Assigned(BorlandIDEServices) then Exit;
      if not Supports(BorlandIDEServices, IOTAServices, LServices) then Exit;
      LBase := LServices.GetBaseRegistryKey;
      LBds  := Copy(LBase, LastDelimiter('\', LBase) + 1, MaxInt); // '37.0' / '23.0'
      LResult.Build := LBds;
      // Map the BDS internal version to the RAD Studio marketing version; an
      // unmapped (future) release falls back to the BDS number itself.
      if LBds = '37.0' then LResult.Version := '13.0'
      else if LBds = '23.0' then LResult.Version := '12.0'
      else if LBds = '22.0' then LResult.Version := '11.0'
      else if LBds = '21.0' then LResult.Version := '10.4'
      else if LBds = '20.0' then LResult.Version := '10.3'
      else LResult.Version := LBds;
    end);
  except
  end;
  if LResult.Version = '' then
    LResult.Version := LResult.Build;
  Result := LResult;
end;

function TMCPIDEReadService.GetIDETheme: string;
var
  LResult: string;
begin
  LResult := 'system';
  try
    TThread.Synchronize(nil, procedure
    var
      {$IF Declared(IOTAIDEThemingServices250)}
      LTheming: IOTAIDEThemingServices250;
      {$IFEND}
      LName: string;
    begin
      if not Assigned(BorlandIDEServices) then Exit;
      // An IDE with no theming service (10 Seattle) answers 'system', which is
      // the honest answer: it has no theme to report. Declared() asks the
      // ToolsAPI in hand rather than encoding which release added the service.
      {$IF Declared(IOTAIDEThemingServices250)}
      if not Supports(BorlandIDEServices, IOTAIDEThemingServices250, LTheming) then Exit;
      try
        LName := LTheming.GetActiveThemeName;
        if Pos('dark', LowerCase(LName)) > 0 then
          LResult := 'dark'
        else if Pos('light', LowerCase(LName)) > 0 then
          LResult := 'light';
      except
        LResult := 'system';
      end;
      {$IFEND}
    end);
  except
    LResult := 'system';
  end;
  Result := LResult;
end;

// Impure read of the IDE "Closed Files" Reopen history (ESP-094, S2 / ADR-094-03).
// Enumerates the File_<N> values of `<base>\Closed Files` under HKCU and returns
// (valueName, extracted-path) pairs for the pure seam to order/normalize. Only
// string values are read (the integer "Max Closed Files" bookkeeping value is
// skipped). Read-only: never writes the registry (BR8). ABaseKey is the live
// version hive from IOTAServices.GetBaseRegistryKey (e.g. Software\Embarcadero\
// BDS\37.0), so the read tracks the running Studio version (R2).
function _ReadClosedFilesEntries(const ABaseKey: string): TArray<TPair<string, string>>;
var
  LReg: TRegistry;
  LNames: TStringList;
  LName, LRaw: string;
  LEntries: TList<TPair<string, string>>;
begin
  LEntries := nil;
  LReg := nil;
  LNames := nil;
  try
    // Create inside the try so an earlier object never leaks if a later
    // constructor raises (combined finally frees all three, nil-safe).
    LEntries := TList<TPair<string, string>>.Create;
    LReg := TRegistry.Create(KEY_READ);
    LNames := TStringList.Create;
    LReg.RootKey := HKEY_CURRENT_USER;
    if LReg.OpenKeyReadOnly(ABaseKey + '\Closed Files') then
    begin
      LReg.GetValueNames(LNames);
      for LName in LNames do
      begin
        if LReg.GetDataType(LName) <> rdString then
          Continue;
        LRaw := LReg.ReadString(LName);
        LEntries.Add(TPair<string, string>.Create(LName, TRecentFilesPolicy.ExtractReopenPath(LRaw)));
      end;
      LReg.CloseKey;
    end;
    Result := LEntries.ToArray;
  finally
    LNames.Free;
    LReg.Free;
    LEntries.Free;
  end;
end;

function TMCPIDEReadService.GetRecentFiles: TArray<string>;
var
  LResult: TArray<string>;
begin
  // OTA exposes no stable MRU enumerator in Delphi 13, but the IDE persists its
  // File ▸ Reopen file history in the registry hive (ESP-094 S0). Read that hive
  // consumer-side (Core untouched, BR1) and shape it through the pure seam:
  // File_<N> ordered most-recent-first, deduped, capped (ADR-094-02/-03).
  LResult := [];
  try
    TThread.Synchronize(nil, procedure
    var
      LServices: IOTAServices;
      LEntries: TArray<TPair<string, string>>;
    begin
      if not Assigned(BorlandIDEServices) then Exit;
      if not Supports(BorlandIDEServices, IOTAServices, LServices) then Exit;
      LEntries := _ReadClosedFilesEntries(LServices.GetBaseRegistryKey);
      LResult := TRecentFilesPolicy.NormalizeRecentFiles(TRecentFilesPolicy.OrderReopenEntries(LEntries), CMaxRecentFiles);
    end);
  except
    LResult := [];
  end;
  Result := LResult;
end;

function TMCPIDEReadService.GetProjectManagerTree: TArray<TMCPRecordProjectManagerNode>;
var
  LResult: TArray<TMCPRecordProjectManagerNode>;
begin
  LResult := [];
  try
    TThread.Synchronize(nil, procedure
    var
      LProject: IOTAProject;
      LRoot: TMCPRecordProjectManagerNode;
      LMS: IOTAModuleServices;
      LList: TList<TMCPRecordProjectManagerNode>;
      LIdx: Integer;
      LModRef: IOTAModuleInfo;
      LRealModule: IOTAModule;
      LChild: TMCPRecordProjectManagerNode;
    begin
      if not TFacadeShared.TryProject(LProject) then Exit;
      LRoot := Default(TMCPRecordProjectManagerNode);
      LRoot.Name := TPath.GetFileName(LProject.FileName);
      LRoot.Kind := 'project';
      if Supports(BorlandIDEServices, IOTAModuleServices, LMS) then
      begin
        LList := TList<TMCPRecordProjectManagerNode>.Create;
        try
          for LIdx := 0 to LProject.GetModuleCount - 1 do
          begin
            LModRef := LProject.GetModule(LIdx);
            if not Assigned(LModRef) then Continue;
            LRealModule := LMS.FindModule(LModRef.FileName);
            if not Assigned(LRealModule) then Continue;
            LChild := Default(TMCPRecordProjectManagerNode);
            LChild.Name := TPath.GetFileName(LRealModule.FileName);
            LChild.Kind := 'unit';
            LList.Add(LChild);
          end;
          LRoot.Children := LList.ToArray;
        finally
          LList.Free;
        end;
      end;
      SetLength(LResult, 1);
      LResult[0] := LRoot;
    end);
  except
    LResult := [];
  end;
  Result := LResult;
end;

function NewMCPIDEReadService: IMCPIDEReadService;
begin
  Result := TMCPIDEReadService.Create;
end;

end.
