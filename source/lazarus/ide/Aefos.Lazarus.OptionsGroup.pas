unit Aefos.Lazarus.OptionsGroup;

{ Aefos AI - Lazarus edition: the "Aefos AI" IDE options GROUP container.

  Extracted from Aefos.Lazarus.Options so the three editor pages (AI Chat, AI
  Flow, Terminal) can each name the same group's options class WITHOUT a
  cross-unit dependency cycle. The Chat page's RegisterAefosOptionsPage still
  references the sibling page classes (a one-way dependency), while the sibling
  pages depend only on THIS unit for TAefosIDEOptions. That keeps the graph
  acyclic - which the FPC package build tolerated as an implementation cycle but
  the IDE static-link rebuild (make idepkg) did not (it fails a partial recompile
  with "Can't find unit ... used by ..." when two units use each other's
  implementation).

  Aefos stores its settings in its own JSON (the SHARED chat config.json - one
  brain with the RAD plugin), NOT the IDE options store, so this class holds no
  state: it exists to name the group node ("Aefos AI") and hand the dialog a
  non-nil instance. Each editor page reads/writes the real config core directly.

  Mode delphi (LCL/IDEIntf AnsiString boundary); all literals ASCII, no BOM. }

{$mode delphi}
{$H+}

interface

uses
  IDEOptionsIntf;

type
  { The options-data container for the Aefos AI group. }
  TAefosIDEOptions = class(TAbstractIDEEnvironmentOptions)
  public
    class function GetGroupCaption: string; override;
    class function GetInstance: TAbstractIDEOptions; override;
  end;

implementation

var
  { The lazily-created singleton the dialog receives from GetInstance. Owned by
    this unit; freed at finalization. }
  GAefosOptionsInstance: TAefosIDEOptions = nil;

class function TAefosIDEOptions.GetGroupCaption: string;
begin
  Result := 'Aefos AI';
end;

class function TAefosIDEOptions.GetInstance: TAbstractIDEOptions;
begin
  if GAefosOptionsInstance = nil then
    GAefosOptionsInstance := TAefosIDEOptions.Create;
  Result := GAefosOptionsInstance;
end;

finalization
  GAefosOptionsInstance.Free;

end.
