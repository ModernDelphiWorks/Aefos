unit Aefos.OTA.Chat.Core.ProjectContextBuilder.Types;

{
  Domain types for the Delphi-aware project context (ESP-008, demand 4/5).

  Pure declarative unit: shape of the active-project snapshot, the rendered
  context record, the builder contract, and the exception family. No OTA,
  no Win32, no I/O — kept testable from console DUnit via TFunc resolver.

  Architectural baseline:
    - ADR-016: context shape = selection + active unit (32 KB cap) + project
      header. Render output is deterministic for testability.
    - ADR-006: Delphi 13 only.
}

interface

uses
  System.SysUtils;

type
  TActiveProjectInfo = record
    ProjectName: string;
    ProjectFile: string;
    ActiveUnitName: string;
    ActiveUnitBody: string;
  end;

  TProjectContext = record
    Selection: string;
    ActiveUnitName: string;
    ActiveUnitBody: string;
    ActiveUnitTruncated: Boolean;
    ProjectName: string;
    ProjectFile: string;
  end;

  IProjectContextBuilder = interface
    ['{6B4D9F2C-1A57-4E83-9D0E-3A8C5F7B2D41}']
    function Build(const ASelection: string): TProjectContext;
    function Render(const AContext: TProjectContext): string;
  end;

  EProjectContextError = class(Exception);

function DecodeUnitBodyBytes(const ABytes: TBytes; ASize: Integer): string;

implementation

function DecodeUnitBodyBytes(const ABytes: TBytes; ASize: Integer): string;
begin
  Result := '';
  if ASize <= 0 then
    Exit;
  Result := TEncoding.UTF8.GetString(Copy(ABytes, 0, ASize));
end;

end.
