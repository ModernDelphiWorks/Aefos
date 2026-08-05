unit Aefos.MCP.OTA.PackagesService;

{
  Project design/runtime package operations, extracted from the
  TMCPWorkspaceFacade god-object as a focused service of the SOLID split
  (audit S6 / facade split).

  Owns ListProjectPackages (reads the .dproj <DCC_UsePackage> list) and the two
  honest OTA-gap sentinels AddPackageToProject / RemovePackageFromProject, plus
  the package-specific .dproj scanner _ScanUsePackages. The only shared
  dependency is the trivial TFacadeShared.TryProject getter, drawn from
  Aefos.MCP.OTA.FacadeShared.

  Bodies moved VERBATIM from the facade (only the class qualifier changes), so
  behaviour is identical. The facade keeps its frozen IMCPWorkspaceFacade methods
  and delegates each to a refcounted FPackages field.
}

interface

uses
  Aefos.MCP.Types;

type
  IMCPPackagesService = interface
    ['{8A52E1C6-3D94-4B70-9E28-1F6C4A2D8B53}']
    function ListProjectPackages: TArray<TMCPRecordProjectPackage>;
    function AddPackageToProject(const APackagePath: string;
      const ARuntime: Boolean;
      out AChanged: Boolean; out AReason: string): Boolean;
    function RemovePackageFromProject(const APackageName: string;
      out AChanged: Boolean; out AReason: string): Boolean;
  end;

// Factory — the facade calls this once in its constructor.
function NewMCPPackagesService: IMCPPackagesService;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.Generics.Collections,
  ToolsAPI,
  Aefos.MCP.OTA.FacadeShared;

type
  TMCPPackagesService = class(TInterfacedObject, IMCPPackagesService)
  public
    function ListProjectPackages: TArray<TMCPRecordProjectPackage>;
    function AddPackageToProject(const APackagePath: string;
      const ARuntime: Boolean;
      out AChanged: Boolean; out AReason: string): Boolean;
    function RemovePackageFromProject(const APackageName: string;
      out AChanged: Boolean; out AReason: string): Boolean;
  end;

function _ScanUsePackages(const ADProjText: string): TArray<TMCPRecordProjectPackage>;
const
  COpenTag = '<DCC_UsePackage>';
  CCloseTag = '</DCC_UsePackage>';
var
  LSeen: TStringList;
  LRes: TList<TMCPRecordProjectPackage>;
  LPosAt, LOpen, LClose, LFor: Integer;
  LInner, LName: string;
  LTokens: TArray<string>;
  LItem: TMCPRecordProjectPackage;
begin
  SetLength(Result, 0);
  LSeen := TStringList.Create;
  LRes := TList<TMCPRecordProjectPackage>.Create;
  try
    LSeen.CaseSensitive := False;
    LPosAt := 1;
    repeat
      LOpen := Pos(COpenTag, ADProjText, LPosAt);
      if LOpen = 0 then Break;
      LClose := Pos(CCloseTag, ADProjText, LOpen);
      if LClose = 0 then Break;
      LInner := Copy(ADProjText, LOpen + Length(COpenTag),
        LClose - (LOpen + Length(COpenTag)));
      LTokens := LInner.Split([';']);
      for LFor := 0 to High(LTokens) do
      begin
        LName := Trim(LTokens[LFor]);
        if (LName = '') or (Pos('$(', LName) > 0) then Continue;
        if LSeen.IndexOf(LName) >= 0 then Continue;
        LSeen.Add(LName);
        LItem := Default(TMCPRecordProjectPackage);
        LItem.Name       := LName;
        LItem.Path       := LName;
        LItem.Runtime    := False;
        LItem.Designtime := True;
        LRes.Add(LItem);
      end;
      LPosAt := LClose + Length(CCloseTag);
    until False;
    Result := LRes.ToArray;
  finally
    LRes.Free;
    LSeen.Free;
  end;
end;

function TMCPPackagesService.ListProjectPackages: TArray<TMCPRecordProjectPackage>;
var
  LResult: TArray<TMCPRecordProjectPackage>;
  LDProjPath, LText: string;
begin
  LResult := [];
  LDProjPath := '';
  try
    TThread.Synchronize(nil, procedure
    var
      LProject: IOTAProject;
    begin
      if TFacadeShared.TryProject(LProject) then
        LDProjPath := LProject.FileName;
    end);
  except
    LDProjPath := '';
  end;
  if (LDProjPath = '') or not TFile.Exists(LDProjPath) then
  begin
    Result := LResult;
    Exit;
  end;
  try
    LText := TFile.ReadAllText(LDProjPath);
    LResult := _ScanUsePackages(LText);
  except
    LResult := [];
  end;
  Result := LResult;
end;

// Honest OTA-gap sentinel (ESP-089 / R5 / ADR-089-03). ToolsAPI exposes no
// reliable project-level package-reference mutation: the design-package list
// lives in the .dproj <DCC_UsePackage> XML and the runtime list in its own node,
// and rewriting either under the open project desyncs the live IOTAProject (same
// risk class as RenameDPR / project-group mutation). Returned as a CAVEAT +
// upstream ask, never forced into Core (BR1).
function TMCPPackagesService.AddPackageToProject(
  const APackagePath: string; const ARuntime: Boolean;
  out AChanged: Boolean; out AReason: string): Boolean;
begin
  AChanged := False;
  AReason  := 'ota-no-project-package-mutation';
  Result   := False;
end;

function TMCPPackagesService.RemovePackageFromProject(
  const APackageName: string;
  out AChanged: Boolean; out AReason: string): Boolean;
begin
  AChanged := False;
  AReason  := 'ota-no-project-package-mutation';
  Result   := False;
end;

function NewMCPPackagesService: IMCPPackagesService;
begin
  Result := TMCPPackagesService.Create;
end;

end.
