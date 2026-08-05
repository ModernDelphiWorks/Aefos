unit Aefos.Lazarus.LfmParser;

{ Aefos AI - Lazarus edition: thin .lfm parser (Phase J).

  A Lazarus `.lfm` is a BYTE-IDENTICAL text component resource to a RAD Studio
  `.dfm`: the same FCL object-tree text stream (object/inherited/inline headers,
  `Name = Value` scalar assignments, `end` markers, nested blocks), produced and
  read by the same RTL machinery (WriteComponentAsTextToStream /
  ReadComponentFromTextStream, bridged on Lazarus by lresources.pp). So the
  shared, RTL-only Aefos.MCP.DFMParser (source\mcp\Core) already parses `.lfm`
  text VERBATIM - there is nothing framework-specific to re-implement.

  This unit is the deliberately-thin `.lfm` variant the port plan asks for
  (meta\lazarus-port\02-designer.md step 4): it re-exposes the DFMParser surface
  under LFM-named entry points so the Lazarus design reads
  (Aefos.Lazarus.WorkspaceFacade) read as `.lfm`, while single-sourcing the
  actual parse to the shared parser (no duplicated grammar). It also documents,
  at one place, WHY no separate grammar exists.

  Lazarus-only (source\lazarus\ide) - it is not on the Delphi package unit path,
  so it does not touch the RAD Studio build. Mode + de-dot match the MCP core;
  all literals are ASCII, so the file needs no BOM. }

{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

interface

uses
  Aefos.MCP.DFMParser;

type
  // The record shapes are shared verbatim with the .dfm parser (same fields);
  // re-exported here so callers can speak in LFM terms without a cross-unit dep
  // on the DFM-named types.
  TLFMPropertyPair = TDFMPropertyPair;
  TLFMComponentRef = TDFMComponentRef;

  { Sealed static namespace: the .lfm face of TDFMParser. Every method delegates
    1:1 to the shared parser (the text format is identical). }
  TLFMParser = class sealed
  public
    // The [Name, TypeName] of the root header (`object Form1: TForm1`).
    class function ParseRootHeader(const AContent: string;
      out AName, ATypeName: string): Boolean; static;
    // Immediate-child component blocks of the root (depth 1 from the root body).
    class function EnumerateImmediateChildren(
      const AContent: string): TArray<TLFMComponentRef>; static;
    // Every component at EVERY depth, each carrying the name of what contains
    // it. The immediate-children twin reports ONE component for a form whose
    // controls all live inside a page control, which reads as a .pas/.lfm
    // desync that is not there -- see the .dfm side for the field report.
    class function EnumerateAllComponents(
      const AContent: string): TArray<TLFMComponentRef>; static;
    // Property assignments at the root's top scope (depth 1).
    class function ExtractTopLevelProperties(
      const AContent: string): TArray<TLFMPropertyPair>; static;
    // Property assignments scoped to AComponentName (any depth >= 2).
    class function ExtractComponentProperties(const AContent,
      AComponentName: string): TArray<TLFMPropertyPair>; static;
  end;

implementation

class function TLFMParser.ParseRootHeader(const AContent: string;
  out AName, ATypeName: string): Boolean;
begin
  Result := TDFMParser.ParseFormHeader(AContent, AName, ATypeName);
end;

class function TLFMParser.EnumerateImmediateChildren(
  const AContent: string): TArray<TLFMComponentRef>;
begin
  Result := TDFMParser.EnumerateImmediateChildren(AContent);
end;

class function TLFMParser.EnumerateAllComponents(
  const AContent: string): TArray<TLFMComponentRef>;
begin
  Result := TDFMParser.EnumerateAllComponents(AContent);
end;

class function TLFMParser.ExtractTopLevelProperties(
  const AContent: string): TArray<TLFMPropertyPair>;
begin
  Result := TDFMParser.ExtractTopLevelProperties(AContent);
end;

class function TLFMParser.ExtractComponentProperties(const AContent,
  AComponentName: string): TArray<TLFMPropertyPair>;
begin
  Result := TDFMParser.ExtractComponentProperties(AContent, AComponentName);
end;

end.
