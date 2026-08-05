unit Aefos.OTA.Terminal.MCP.ProjectGroupManagerPolicy;

{
  Consumer-owned seam for the SaveProjectGroup and RenameProjectGroup MCP tools
  (ESP-096 follow-on). Pure RTL — no ToolsAPI, no VCL, no I/O.

  The frozen Core IMCPWorkspaceFacade is never extended (BR1). These tools bind to
  IProjectGroupManagerService (consumer-owned), obtained from
  GProjectGroupManagerServiceFactory, which the UI ProjectCreator unit wires at
  BPL load. In the headless host the factory is nil: the descriptors still register
  (catalog asserts 118), and an invocation without a live service is refused.
}

interface

uses
  System.SysUtils;

type
  TProjectGroupSaveResult = record
    Applied:     Boolean;
    Path:        string; // target path (new path for Rename)
    OldPath:     string; // previous path — non-empty only on Rename
    ErrorReason: string; // kebab sentinel on failure, '' on success
  end;

  IProjectGroupManagerService = interface
    ['{B7F3A2D9-6C14-4E58-91A3-5D8E0B7C2F46}']
    // Saves the current project group to APath (SetFileName + Save(False,True)).
    // Works for both new unsaved groups and existing ones.
    function SaveGroupAs(const APath: string): TProjectGroupSaveResult;
    // Renames the current project group: same-dir rename, deletes old .groupproj.
    // Returns 'group-not-saved' if the group has no file yet.
    function RenameGroup(const ANewName: string): TProjectGroupSaveResult;
    // Closes all open modules + project group (IOTAModuleServices.CloseAll).
    // May prompt to save unsaved modules; returns True if closed without cancel.
    function CloseAll: Boolean;
  end;

var
  GProjectGroupManagerServiceFactory: TFunc<IProjectGroupManagerService>;

implementation

end.
