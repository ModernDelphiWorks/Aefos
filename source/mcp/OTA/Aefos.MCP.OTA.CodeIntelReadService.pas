unit Aefos.MCP.OTA.CodeIntelReadService;

{
  Code-intelligence reads, extracted from the TMCPWorkspaceFacade god-object as a
  focused service of the SOLID split (audit S6 / facade split).

  Owns the read-only source-analysis queries — GetSymbolsInUnit, GetClassMembers,
  FindSymbolUsages, GetMethodBody and GetInheritanceChain (+ the _LookupParentClass
  helper). All parsing is the pure Aefos.MCP.PasParser seam (TPasParser.Tokenize +
  TPasParser.FindUnitSymbols / TPasParser.FindClassMembers / TPasParser.EnumerateIdentifierUsages / TPasParser.FindMethodBody /
  TPasParser.FindParentClassName + the *ToString mappers); the only OTA touch is resolving the
  unit path and reading the LIVE editor buffer (so unsaved edits + pending
  review-gutter diffs are seen) before falling back to the on-disk file. No mutation,
  no facade state (no FAudit), no public-method delegation.

  Bodies moved VERBATIM (only the class qualifier changes on the methods). Every
  dependency is drawn from an already-shared unit: FacadeShared (FindUnitPath /
  FindSourceForPath / EnumProjectUnitPaths), PasParser, and Aefos.MCP.Types. The
  facade delegates the five frozen methods to a refcounted FCodeIntel field.
}

interface

uses
  Aefos.MCP.Types;

type
  IMCPCodeIntelReadService = interface
    ['{6F2C1E94-8D73-4B50-9A38-3C6A1B5E8D40}']
    function GetSymbolsInUnit(const AUnitName: string;
      out ASymbols: TArray<TMCPRecordUnitSymbol>): Boolean;
    function GetClassMembers(const AUnitName, AClassName: string;
      out AMembers: TArray<TMCPRecordClassMember>): Boolean;
    function FindSymbolUsages(const ASymbol: string;
      out AUsages: TArray<TMCPRecordSymbolUsage>): Boolean;
    function GetMethodBody(const AUnitName, AMethodName: string;
      out ABody: string): Boolean;
    function GetInheritanceChain(const AClassName: string;
      out AChain: TArray<string>): Boolean;
  end;

// Factory — the facade calls this once in its constructor.
function NewMCPCodeIntelReadService: IMCPCodeIntelReadService;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.Generics.Collections,
  ToolsAPI,
  Aefos.MCP.PasParser,
  Aefos.MCP.OTA.FacadeShared;

type
  TMCPCodeIntelReadService = class(TInterfacedObject, IMCPCodeIntelReadService)
  public
    function GetSymbolsInUnit(const AUnitName: string;
      out ASymbols: TArray<TMCPRecordUnitSymbol>): Boolean;
    function GetClassMembers(const AUnitName, AClassName: string;
      out AMembers: TArray<TMCPRecordClassMember>): Boolean;
    function FindSymbolUsages(const ASymbol: string;
      out AUsages: TArray<TMCPRecordSymbolUsage>): Boolean;
    function GetMethodBody(const AUnitName, AMethodName: string;
      out ABody: string): Boolean;
    function GetInheritanceChain(const AClassName: string;
      out AChain: TArray<string>): Boolean;
  end;

function TMCPCodeIntelReadService.GetSymbolsInUnit(const AUnitName: string;
  out ASymbols: TArray<TMCPRecordUnitSymbol>): Boolean;
var
  LFilePath, LSource: string;
  LTokens: TArray<TPasToken>;
  LRefs: TArray<TPasSymbolRef>;
  LFor: Integer;
begin
  ASymbols := [];
  Result := False;
  LFilePath := '';
  try
    TThread.Synchronize(nil, procedure
    begin
      LFilePath := TFacadeShared.FindUnitPath(AUnitName);
    end);
  except
    LFilePath := '';
  end;
  if LFilePath = '' then Exit;
  try
    LSource := TFile.ReadAllText(LFilePath, TEncoding.UTF8);
  except
    LSource := '';
  end;
  if LSource = '' then Exit;
  try
    LTokens := TPasParser.Tokenize(LSource);
    LRefs := TPasParser.FindUnitSymbols(LTokens);
    SetLength(ASymbols, Length(LRefs));
    for LFor := 0 to High(LRefs) do
    begin
      ASymbols[LFor].Name := LRefs[LFor].Name;
      ASymbols[LFor].Kind := TPasParser.SymbolKindToString(LRefs[LFor].Kind);
      ASymbols[LFor].Line := LRefs[LFor].Line;
    end;
    Result := True;
  except
    ASymbols := [];
    Result := False;
  end;
end;

function TMCPCodeIntelReadService.GetClassMembers(const AUnitName,
  AClassName: string; out AMembers: TArray<TMCPRecordClassMember>): Boolean;
var
  LFilePath, LSource: string;
  LTokens: TArray<TPasToken>;
  LRefs: TArray<TPasMemberRef>;
  LFor: Integer;
begin
  AMembers := [];
  Result := False;
  LFilePath := '';
  LSource := '';
  try
    TThread.Synchronize(nil, procedure
    var
      LSrcEd: IOTASourceEditor;
      LLive: string;
    begin
      LFilePath := TFacadeShared.FindUnitPath(AUnitName);
      // Prefer the LIVE editor buffer: unsaved edits and pending review-gutter
      // diffs (e.g. an AddEventHandler body not yet approved) live in the buffer,
      // not on disk. Mirrors ReadUnit/GetDFMContent reading live state. Falls back
      // to disk below when the unit is not open in the editor.
      if (LFilePath <> '') and TFacadeShared.FindSourceForPath(LFilePath, LSrcEd, LLive)
         and (LLive <> '') then
        LSource := LLive;
    end);
  except
    LFilePath := '';
    LSource := '';
  end;
  if LFilePath = '' then Exit;
  if LSource = '' then
    try
      LSource := TFile.ReadAllText(LFilePath, TEncoding.UTF8);
    except
      LSource := '';
    end;
  if LSource = '' then Exit;
  try
    LTokens := TPasParser.Tokenize(LSource);
    LRefs := TPasParser.FindClassMembers(LTokens, AClassName);
    SetLength(AMembers, Length(LRefs));
    for LFor := 0 to High(LRefs) do
    begin
      AMembers[LFor].Name       := LRefs[LFor].Name;
      AMembers[LFor].Kind       := TPasParser.MemberKindToString(LRefs[LFor].Kind);
      AMembers[LFor].Visibility := TPasParser.VisibilityToString(LRefs[LFor].Visibility);
      AMembers[LFor].Line       := LRefs[LFor].Line;
    end;
    Result := Length(AMembers) > 0;
  except
    AMembers := [];
    Result := False;
  end;
end;

function TMCPCodeIntelReadService.FindSymbolUsages(const ASymbol: string;
  out AUsages: TArray<TMCPRecordSymbolUsage>): Boolean;
var
  LPaths: TArray<string>;
  LFor, LHit: Integer;
  LSource: string;
  LTokens: TArray<TPasToken>;
  LHits: TArray<TPasIdentifierUsage>;
  LList: TList<TMCPRecordSymbolUsage>;
  LItem: TMCPRecordSymbolUsage;
begin
  AUsages := [];
  Result := False;
  if Trim(ASymbol) = '' then Exit;
  LPaths := nil;
  try
    TThread.Synchronize(nil, procedure
    begin
      LPaths := TFacadeShared.EnumProjectUnitPaths;
    end);
  except
    LPaths := nil;
  end;
  if Length(LPaths) = 0 then Exit;
  LList := TList<TMCPRecordSymbolUsage>.Create;
  try
    for LFor := 0 to High(LPaths) do
    begin
      try
        LSource := TFile.ReadAllText(LPaths[LFor], TEncoding.UTF8);
      except
        Continue;
      end;
      LTokens := TPasParser.Tokenize(LSource);
      LHits := TPasParser.EnumerateIdentifierUsages(LSource, LTokens, ASymbol);
      for LHit := 0 to High(LHits) do
      begin
        LItem := Default(TMCPRecordSymbolUsage);
        LItem.FilePath := LPaths[LFor];
        LItem.Line     := LHits[LHit].Line;
        LItem.Column   := LHits[LHit].Column;
        LItem.Context  := LHits[LHit].Context;
        LList.Add(LItem);
      end;
    end;
    AUsages := LList.ToArray;
    Result := True;
  finally
    LList.Free;
  end;
end;

function TMCPCodeIntelReadService.GetMethodBody(const AUnitName,
  AMethodName: string; out ABody: string): Boolean;
var
  LFilePath, LSource: string;
  LTokens: TArray<TPasToken>;
begin
  ABody := '';
  Result := False;
  LFilePath := '';
  LSource := '';
  try
    TThread.Synchronize(nil, procedure
    var
      LSrcEd: IOTASourceEditor;
      LLive: string;
    begin
      LFilePath := TFacadeShared.FindUnitPath(AUnitName);
      // Prefer the LIVE editor buffer: unsaved edits and pending review-gutter
      // diffs (e.g. an AddEventHandler body not yet approved) live in the buffer,
      // not on disk. Mirrors ReadUnit/GetDFMContent reading live state. Falls back
      // to disk below when the unit is not open in the editor.
      if (LFilePath <> '') and TFacadeShared.FindSourceForPath(LFilePath, LSrcEd, LLive)
         and (LLive <> '') then
        LSource := LLive;
    end);
  except
    LFilePath := '';
    LSource := '';
  end;
  if LFilePath = '' then Exit;
  if LSource = '' then
    try
      LSource := TFile.ReadAllText(LFilePath, TEncoding.UTF8);
    except
      LSource := '';
    end;
  if LSource = '' then Exit;
  try
    LTokens := TPasParser.Tokenize(LSource);
    ABody := TPasParser.FindMethodBody(LSource, LTokens, AMethodName);
    Result := ABody <> '';
  except
    ABody := '';
    Result := False;
  end;
end;

// Scans the project unit paths for AClassName's declared parent class name;
// returns '' when none is found in the corpus.
function _LookupParentClass(const APaths: TArray<string>;
  const AClassName: string): string;
var
  LFor: Integer;
  LSource: string;
  LTokens: TArray<TPasToken>;
begin
  Result := '';
  for LFor := 0 to High(APaths) do
  begin
    try
      LSource := TFile.ReadAllText(APaths[LFor], TEncoding.UTF8);
    except
      Continue;
    end;
    LTokens := TPasParser.Tokenize(LSource);
    Result := TPasParser.FindParentClassName(LTokens, AClassName);
    if Result <> '' then Exit;
  end;
end;

function TMCPCodeIntelReadService.GetInheritanceChain(
  const AClassName: string; out AChain: TArray<string>): Boolean;
const
  CChainSafetyLimit = 32;
var
  LPaths: TArray<string>;
  LCurrent, LParent: string;
  LList: TList<string>;
  LSafety: Integer;
  LFound: Boolean;
begin
  AChain := [];
  Result := False;
  if Trim(AClassName) = '' then Exit;
  LPaths := nil;
  try
    TThread.Synchronize(nil, procedure
    begin
      LPaths := TFacadeShared.EnumProjectUnitPaths;
    end);
  except
    LPaths := nil;
  end;
  if Length(LPaths) = 0 then Exit;
  LList := TList<string>.Create;
  try
    LCurrent := AClassName;
    LFound := _LookupParentClass(LPaths, LCurrent) <> '';
    LList.Add(LCurrent);
    LSafety := 0;
    while LSafety < CChainSafetyLimit do
    begin
      LParent := _LookupParentClass(LPaths, LCurrent);
      if LParent = '' then Break;
      LList.Add(LParent);
      LCurrent := LParent;
      Inc(LSafety);
    end;
    if (LList.Count > 0) and not SameText(LList.Last, 'TObject') then
      LList.Add('TObject');
    if not LFound and (LList.Count = 1) then
    begin
      AChain := [];
      Result := False;
      Exit;
    end;
    AChain := LList.ToArray;
    Result := True;
  finally
    LList.Free;
  end;
end;

function NewMCPCodeIntelReadService: IMCPCodeIntelReadService;
begin
  Result := TMCPCodeIntelReadService.Create;
end;

end.
