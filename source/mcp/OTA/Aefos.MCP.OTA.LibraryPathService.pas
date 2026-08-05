unit Aefos.MCP.OTA.LibraryPathService;

{
  IDE-global library-path operations, extracted from the TMCPWorkspaceFacade
  god-object as a focused service of the SOLID split (audit S6 / facade split).

  Owns GetLibraryPath and the atomic add-verify-revert AddToLibraryPath. Both
  shared dependencies are already separate units: ReadIDELibraryPathRaw /
  WriteIDELibraryPathRaw from Aefos.MCP.OTA.FacadeShared and ParseOptionList /
  AppendRawEntry from ConfigWritePolicy.

  Bodies moved VERBATIM from the facade (only the class qualifier changes), so
  behaviour is identical. The facade keeps its frozen IMCPWorkspaceFacade methods
  and delegates each to a refcounted FLibraryPath field.
}

interface

type
  IMCPLibraryPathService = interface
    ['{5C8A2E14-7B69-4D30-9F25-1A6C3E8B5D74}']
    function GetLibraryPath: TArray<string>;
    function AddToLibraryPath(const APath: string;
      out AChanged: Boolean; out AReason: string): Boolean;
  end;

// Factory — the facade calls this once in its constructor.
function NewMCPLibraryPathService: IMCPLibraryPathService;

implementation

uses
  System.SysUtils,
  System.Classes,
  Aefos.MCP.OTA.FacadeShared,
  Aefos.MCP.OTA.ConfigWritePolicy;

type
  TMCPLibraryPathService = class(TInterfacedObject, IMCPLibraryPathService)
  public
    function GetLibraryPath: TArray<string>;
    function AddToLibraryPath(const APath: string;
      out AChanged: Boolean; out AReason: string): Boolean;
  end;

function TMCPLibraryPathService.GetLibraryPath: TArray<string>;
var
  LRaw: string;
begin
  LRaw := '';
  try
    TThread.Synchronize(nil, procedure
    begin
      LRaw := TFacadeShared.ReadIDELibraryPathRaw;
    end);
  except
    LRaw := '';
  end;
  Result := TConfigWritePolicy.ParseOptionList(LRaw);
end;

// Append a path to the IDE-GLOBAL library path, verify it landed, then
// immediately revert to the original raw value (ESP-089, ADR-089-07 / BR11).
//
// The catalog has no remove-from-library-path tool, so this tool performs an
// atomic add → read-verify → revert cycle (all within one TThread.Synchronize
// on the main thread). The BPL-internal read-back confirms the mutation happened;
// the revert restores the original raw string byte-identical. AChanged is True
// when the append + revert both succeeded; False on a no-op (path already
// present) or on any failure (no partial change). The follow-up MCP read
// (GetLibraryPath) confirms the reverted state — no marker in the list proves
// the revert completed cleanly (ADR-089-07 proof, AC7/AC9).
function TMCPLibraryPathService.AddToLibraryPath(const APath: string;
  out AChanged: Boolean; out AReason: string): Boolean;
var
  LOk, LChanged: Boolean;
  LReason: string;
begin
  LOk      := False;
  LChanged := False;
  LReason  := 'no-environment-options';
  try
    TThread.Synchronize(nil, procedure
    var
      LBefore, LNew, LVerify: string;
    begin
      if Trim(APath) = '' then
      begin
        LReason := 'empty-path';
        Exit;
      end;
      LBefore := TFacadeShared.ReadIDELibraryPathRaw;
      if not TConfigWritePolicy.AppendRawEntry(LBefore, APath, LNew, LChanged) then
      begin
        LReason := 'empty-path';
        Exit;
      end;
      if not LChanged then
      begin
        LOk := True; // already present — valid no-op, state untouched
        Exit;
      end;
      // Step 1: append marker
      if not TFacadeShared.WriteIDELibraryPathRaw(LNew) then
      begin
        LReason := 'library-path-write-failed';
        Exit;
      end;
      // Step 2: read-back verify (internal; follow-up MCP read confirms revert)
      LVerify := TFacadeShared.ReadIDELibraryPathRaw;
      if LVerify.IndexOf(APath, 0) < 0 then
      begin
        // Write appeared to succeed but read-back disagrees — attempt revert
        // and report the discrepancy, so the caller does not falsely succeed.
        TFacadeShared.WriteIDELibraryPathRaw(LBefore);
        LReason := 'library-path-verify-failed';
        LChanged := False;
        Exit;
      end;
      // Step 3: revert to original — leaves IDE-global state byte-identical
      if not TFacadeShared.WriteIDELibraryPathRaw(LBefore) then
      begin
        LReason := 'library-path-revert-failed';
        // Don't set LChanged; the state is now dirty (partial).
        Exit;
      end;
      LOk := True;
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

function NewMCPLibraryPathService: IMCPLibraryPathService;
begin
  Result := TMCPLibraryPathService.Create;
end;

end.
