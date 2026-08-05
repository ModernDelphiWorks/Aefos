unit Aefos.MCP.OTA.ResourcesService;

{
  Project resource/image operations, extracted from the TMCPWorkspaceFacade
  god-object as a focused service of the SOLID split (audit S6 / facade split).

  Owns ListProjectResources (.res/.rc members), ListProjectImages (image members)
  and AddResourceFile (adds an on-disk .res/.rc as a non-unit project member). The
  shared dependencies are the trivial TFacadeShared.TryProject getter (Aefos.MCP.OTA.FacadeShared)
  and the pure ConfineConfigPath gate (Aefos.MCP.OTA.ConfigWritePolicy) — both
  already separate units; no facade-private helper is needed.

  Bodies moved VERBATIM from the facade (only the class qualifier changes), so
  behaviour is identical. The facade keeps its frozen IMCPWorkspaceFacade methods
  and delegates each to a refcounted FResources field.
}

interface

uses
  Aefos.MCP.Types;

type
  IMCPResourcesService = interface
    ['{2D7B9F14-6C83-4A50-8E19-5B3C1A6D2F84}']
    function ListProjectResources: TArray<TMCPRecordProjectResource>;
    function AddResourceFile(const AFilePath: string;
      out AChanged: Boolean; out AReason: string): Boolean;
    function ListProjectImages: TArray<string>;
  end;

// Factory — the facade calls this once in its constructor.
function NewMCPResourcesService: IMCPResourcesService;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.Generics.Collections,
  ToolsAPI,
  Aefos.MCP.OTA.FacadeShared,
  Aefos.MCP.OTA.ConfigWritePolicy;

type
  TMCPResourcesService = class(TInterfacedObject, IMCPResourcesService)
  public
    function ListProjectResources: TArray<TMCPRecordProjectResource>;
    function AddResourceFile(const AFilePath: string;
      out AChanged: Boolean; out AReason: string): Boolean;
    function ListProjectImages: TArray<string>;
  end;

function TMCPResourcesService.ListProjectResources: TArray<TMCPRecordProjectResource>;
var
  LResult: TArray<TMCPRecordProjectResource>;
begin
  LResult := [];
  try
    TThread.Synchronize(nil, procedure
    var
      LProject: IOTAProject;
      LFor: Integer;
      LInfo: IOTAModuleInfo;
      LExt: string;
      LList: TList<TMCPRecordProjectResource>;
      LItem: TMCPRecordProjectResource;
    begin
      if not TFacadeShared.TryProject(LProject) then Exit;
      LList := TList<TMCPRecordProjectResource>.Create;
      try
        for LFor := 0 to LProject.GetModuleCount - 1 do
        begin
          LInfo := LProject.GetModule(LFor);
          if not Assigned(LInfo) then Continue;
          LExt := LowerCase(ExtractFileExt(LInfo.FileName));
          if (LExt = '.res') or (LExt = '.rc') then
          begin
            LItem := Default(TMCPRecordProjectResource);
            LItem.Path := LInfo.FileName;
            LItem.Kind := Copy(LExt, 2, MaxInt);
            LList.Add(LItem);
          end;
        end;
        LResult := LList.ToArray;
      finally
        LList.Free;
      end;
    end);
  except
    LResult := [];
  end;
  Result := LResult;
end;

// Add an on-disk .res/.rc resource to the active project (ESP-089,
// IOTAProject.AddFile as a non-unit member). Path-bearing → confined to the
// scratch-project root (ADR-089-07 / BR10): an out-of-root target is refused
// with no write, and the file must exist. ListProjectResources is the live
// acceptance read.
function TMCPResourcesService.AddResourceFile(const AFilePath: string;
  out AChanged: Boolean; out AReason: string): Boolean;
var
  LOk, LChanged: Boolean;
  LReason: string;
begin
  LOk      := False;
  LChanged := False;
  LReason  := 'no-active-project';
  try
    TThread.Synchronize(nil, procedure
    var
      LProject: IOTAProject;
      LRoot, LFull, LConfReason: string;
    begin
      if not TFacadeShared.TryProject(LProject) then
      begin
        LReason := 'no-active-project';
        Exit;
      end;
      LRoot := TPath.GetDirectoryName(LProject.FileName);
      if not TConfigWritePolicy.ConfineConfigPath(AFilePath, LRoot, LFull, LConfReason) then
      begin
        LReason := LConfReason;
        Exit;
      end;
      if not TFile.Exists(LFull) then
      begin
        LReason := 'file-not-found';
        Exit;
      end;
      LProject.AddFile(LFull, False);
      LProject.Save(False, True);
      LChanged := True;
      LOk      := True;
    end);
  except
    on E: Exception do
    begin
      LOk     := False;
      LReason := E.Message;
    end;
  end;
  AChanged := LChanged;
  if LOk then AReason := '' else AReason := LReason;
  Result := LOk;
end;

function TMCPResourcesService.ListProjectImages: TArray<string>;
var
  LResult: TArray<string>;
begin
  LResult := [];
  try
    TThread.Synchronize(nil, procedure
    var
      LProject: IOTAProject;
      LFor: Integer;
      LInfo: IOTAModuleInfo;
      LExt: string;
      LList: TList<string>;
    begin
      if not TFacadeShared.TryProject(LProject) then Exit;
      LList := TList<string>.Create;
      try
        for LFor := 0 to LProject.GetModuleCount - 1 do
        begin
          LInfo := LProject.GetModule(LFor);
          if not Assigned(LInfo) then Continue;
          LExt := LowerCase(ExtractFileExt(LInfo.FileName));
          if (LExt = '.png') or (LExt = '.jpg') or (LExt = '.jpeg')
            or (LExt = '.bmp') or (LExt = '.gif') or (LExt = '.ico') then
            LList.Add(LInfo.FileName);
        end;
        LResult := LList.ToArray;
      finally
        LList.Free;
      end;
    end);
  except
    LResult := [];
  end;
  Result := LResult;
end;

function NewMCPResourcesService: IMCPResourcesService;
begin
  Result := TMCPResourcesService.Create;
end;

end.
