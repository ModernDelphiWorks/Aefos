unit Aefos.Compat.Json;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{
  System.JSON compatibility shim (Aefos -> Lazarus port, Milestone 1 / Phase A).

  Single uses-target replacing `uses System.JSON` in the swept MCP core so the
  call sites stay byte-for-byte unchanged across Delphi and FPC 3.2.2.

  - Delphi (not FPC): pure TYPE ALIASES onto System.JSON, so behaviour is
    identical to the pre-shim code (same classes, same methods, same lifetimes).
    The pure suite compiling `uses System.JSON` directly interoperates because
    the aliased types ARE the System.JSON types.
  - FPC: thin wrapper classes over fpjson/jsonparser that present the System.JSON
    API SHAPE. Ownership mirrors System.JSON: freeing a container frees the whole
    sub-tree exactly once; values handed to AddPair/Add are owned by the parent.
    KNOWN DEVIATIONS from System.JSON on the FPC side only:
      * NO reference identity across reads — GetValue/Items[]/enumeration build
        a NEW wrapper per call (retained by the parent until it is freed), so
        `Obj.GetValue('x') = Obj.GetValue('x')` is False on FPC, True on Delphi.
        No swept call site compares JSON references; do not start.
      * Serialized output is fpjson-spaced ("a" : 1, with blanks around colons
        and braces), not System.JSON compact — valid JSON, round-trips fine,
        but not byte-identical. Assert on parsed values, never on exact
        serialized strings.

  API SURFACE COVERED (the exact set used by the swept Core + the pure FPC test;
  members outside this list are intentionally not implemented):
    TJSONValue   : Value (property), ToJSON, ToString, Format(indent), Clone;
                   GetValue(name); GetValue<T>(path, default);
                   TryGetValue<T>(path, out) — the System.JSON accessors, added
                   for the Ollama core + the Agent CLI chain (Phase D). T is one
                   of string, Integer, Int64, Boolean, TJSONObject, TJSONArray or
                   TJSONValue. The path is a dot-separated member walk (e.g. the
                   two-level serverInfo then name), objects only; an empty path
                   resolves to THIS value; a missing member or a type mismatch
                   yields False / the default. Class results are materialised
                   wrappers owned by this value (same lifetime as GetValue). These
                   all live on the base, and TryGetValue<T> is NOT overloaded,
                   for the FPC generic-call-through-cast parse reason noted at the
                   declaration - call sites need parentheses only around a generic
                   call adjacent to not/and/or.
    TJSONObject  : Create; AddPair(string,string); AddPair(string,TJSONValue);
                   Get(name) (pair); RemovePair(name) -> the DETACHED pair, now
                   owned by the CALLER (nil when absent, so the System.JSON
                   `Obj.RemovePair(k).Free` idiom stays nil-safe);
                   Values[name] (property, alias of inherited
                   GetValue); Count; GetEnumerator (yields TJSONPair);
                   class ParseJSONValue(string) -> nil on malformed input
    TJSONArray   : Create; Add(TJSONValue); Add(string); AddElement(TJSONValue);
                   GetEnumerator (yields TJSONValue); Count; Items[index]
    TJSONString  : Create(string); Value
    TJSONNumber  : Create(Int64); Create(Double); AsInt; AsDouble
    TJSONBool    : Create(Boolean); AsBoolean
    TJSONNull    : Create
    TJSONPair    : JsonString (TJSONString); JsonValue (TJSONValue)
  RTTI: `is`/`(TJSON...)` casts across the wrapper hierarchy behave like
  System.JSON (TJSONObject/TJSONArray/TJSONString/TJSONNumber/TJSONBool/TJSONNull
  all descend from TJSONValue).
}

interface

{$IFNDEF FPC}

uses
  System.JSON;

type
  TJSONValue  = System.JSON.TJSONValue;
  TJSONObject = System.JSON.TJSONObject;
  TJSONArray  = System.JSON.TJSONArray;
  TJSONString = System.JSON.TJSONString;
  TJSONNumber = System.JSON.TJSONNumber;
  TJSONBool   = System.JSON.TJSONBool;
  TJSONNull   = System.JSON.TJSONNull;
  TJSONPair   = System.JSON.TJSONPair;

{$ELSE}

uses
  SysUtils,
  TypInfo,
  Classes,
  Generics.Collections,
  fpjson,
  jsonparser;

type
  TJSONValue = class;
  TJSONObject = class;
  TJSONPair = class;

  // Base wrapper. FNode is the underlying fpjson node; FOwnsNode is True only
  // for the root of an owned tree (freeing it frees the whole fpjson sub-tree).
  // FOwned holds wrapper objects this wrapper is responsible for freeing
  // (children materialised on read, or values handed to AddPair/Add).
  TJSONValue = class
  protected
    FNode: TJSONData;
    FOwnsNode: Boolean;
    FOwned: TObjectList<TObject>;
    function GetValueText: string; virtual;
    procedure Adopt(const AWrapper: TObject);
    // Path walk + typed read backing the generic accessors. Kept as ordinary
    // (non-generic) methods so the generic templates reference only visible
    // class members - a generic body may not touch an implementation-static
    // symbol (FPC "Global Generic template references static symtable").
    function _FindByPath(const APath: string): TJSONData;
    function _AssignNodeAs(const ANode: TJSONData; const AKind: TTypeKind;
      const ATypeInfo: PTypeInfo; const AValuePtr: Pointer): Boolean;
  public
    // Wrapping constructor (distinct name so subclass Create overloads never
    // hide it): inherited by every subclass and used by _WrapNode/parse.
    constructor CreateWrap(const ANode: TJSONData; const AOwnsNode: Boolean);
    destructor Destroy; override;
    function ToJSON: string;
    // reintroduce (not override): FPC's TObject.ToString returns AnsiString, so
    // this UnicodeString-returning twin cannot override it. Call sites use the
    // TJSONValue static type, so they bind here; polymorphism via TObject is not
    // needed. On the Delphi side ToString is the native System.JSON override.
    function ToString: string; reintroduce;
    // Pretty-prints with AIndent spaces per level (System.JSON parity name).
    // Output is fpjson-spaced, not byte-identical to System.JSON - assert on
    // parsed values, never on the exact string.
    function Format(const AIndent: Integer): string;
    // Deep copy as a NEW owned wrapper (its fpjson node is a fresh Clone). The
    // caller owns it and must Free it (or hand it to AddPair/Add which adopts).
    function Clone: TJSONValue;
    // System.JSON generic accessors (see the unit header). TryGetValue<T> walks
    // a dot-separated member path from THIS value (objects only; an empty path
    // resolves to THIS value, so a scalar reads itself). GetValue<T> is the same
    // with a fallback. Class T yields a wrapper owned by this value; a missing
    // path or a type mismatch yields False / the default.
    //   These + the non-generic GetValue ALL live on the base (not on
    // TJSONObject) and TryGetValue<T> is NOT overloaded, because FPC 3.2.2's
    // parser mishandles a generic method call through a hard cast
    // (`TJSONObject(x).M<T>(`) when the method is overloaded or the receiver's
    // static class declares a local generic. On the base, single, these parse -
    // call sites only need parentheses around a generic call under not/and/or.
    function GetValue(const AName: string): TJSONValue; overload;
    function GetValue<T>(const APath: string; const ADefault: T): T; overload;
    function TryGetValue<T>(const APath: string; out AValue: T): Boolean;
    property Value: string read GetValueText;
  end;

  TJSONString = class(TJSONValue)
  public
    constructor Create(const AText: string);
  end;

  TJSONNumber = class(TJSONValue)
  private
    function GetAsInt: Integer;
    function GetAsDouble: Double;
  public
    constructor Create(const AValue: Int64); overload;
    constructor Create(const AValue: Double); overload;
    // System.JSON parity: the numeric value as Integer / Double. Non-number or
    // nil nodes yield 0 (never raise), matching how the shim's other typed
    // accessors degrade.
    property AsInt: Integer read GetAsInt;
    property AsDouble: Double read GetAsDouble;
  end;

  TJSONBool = class(TJSONValue)
  private
    function GetAsBoolean: Boolean;
  public
    constructor Create(const AValue: Boolean);
    property AsBoolean: Boolean read GetAsBoolean;
  end;

  TJSONNull = class(TJSONValue)
  public
    constructor Create;
  end;

  TJSONArrayEnumerator = class;

  TJSONArray = class(TJSONValue)
  private
    function GetCount: Integer;
    function GetItem(const AIndex: Integer): TJSONValue;
  public
    constructor Create;
    function Add(const AValue: TJSONValue): TJSONArray; overload;
    function Add(const AValue: string): TJSONArray; overload;
    // System.JSON's element-adding twin of Add(TJSONValue); takes ownership.
    function AddElement(const AValue: TJSONValue): TJSONArray;
    // for-in support (yields each element as a materialised wrapper owned by
    // this array), matching System.JSON's `for LItem in LArr`.
    function GetEnumerator: TJSONArrayEnumerator;
    property Count: Integer read GetCount;
    property Items[const AIndex: Integer]: TJSONValue read GetItem; default;
  end;

  TJSONArrayEnumerator = class
  private
    FOwner: TJSONArray;
    FIndex: Integer;
    function GetCurrent: TJSONValue;
  public
    constructor Create(const AOwner: TJSONArray);
    function MoveNext: Boolean;
    property Current: TJSONValue read GetCurrent;
  end;

  // A name/value pair yielded by the object enumerator.
  TJSONPair = class
  private
    FName: TJSONString;
    FValue: TJSONValue;
  public
    constructor Create(const AName: TJSONString; const AValue: TJSONValue);
    destructor Destroy; override;
    property JsonString: TJSONString read FName;
    property JsonValue: TJSONValue read FValue;
  end;

  TJSONPairEnumerator = class
  private
    FOwner: TJSONObject;
    FIndex: Integer;
    function GetCurrent: TJSONPair;
  public
    constructor Create(const AOwner: TJSONObject);
    function MoveNext: Boolean;
    property Current: TJSONPair read GetCurrent;
  end;

  TJSONObject = class(TJSONValue)
  private
    function GetCount: Integer;
    function AsFpObject: fpjson.TJSONObject;
  public
    constructor Create;
    function AddPair(const AName, AValue: string): TJSONObject; overload;
    function AddPair(const AName: string; const AValue: TJSONValue): TJSONObject; overload;
    // GetValue / GetValue<T> are inherited from TJSONValue (see the note there).
    // System.JSON's pair accessor: the name/value PAIR (nil if absent).
    function Get(const AName: string): TJSONPair;
    // System.JSON parity: DETACHES the named pair from this object and hands it
    // to the CALLER, who must Free it (freeing the pair frees its name+value
    // sub-tree). nil when the member is absent, so the shipped
    // `Obj.RemovePair(k).Free` idiom is a no-op on a miss. Any wrapper a prior
    // GetValue materialised for the same member stays adopted by this object but
    // is inert (it never owned the node), so nothing double-frees.
    function RemovePair(const AName: string): TJSONPair;
    function GetEnumerator: TJSONPairEnumerator;
    property Count: Integer read GetCount;
    // System.JSON's indexed value accessor - the VALUE for AName (nil if
    // absent). Same semantics/lifetime as GetValue (a per-call materialised
    // wrapper retained by this object).
    property Values[const AName: string]: TJSONValue read GetValue;
    // Returns nil (never raises) for malformed input, matching System.JSON.
    class function ParseJSONValue(const AJson: string): TJSONValue; static;
  end;

{$ENDIF}

implementation

{$IFDEF FPC}

// Materialise the correct wrapper subclass for an fpjson node (used for reads
// and parse). AOwnsNode transfers fpjson ownership to the returned wrapper.
function _WrapNode(const ANode: TJSONData; const AOwnsNode: Boolean): TJSONValue;
begin
  if ANode = nil then
    Exit(nil);
  if ANode is fpjson.TJSONObject then
    Result := TJSONObject.CreateWrap(ANode, AOwnsNode)
  else if ANode is fpjson.TJSONArray then
    Result := TJSONArray.CreateWrap(ANode, AOwnsNode)
  else if ANode is fpjson.TJSONString then
    Result := TJSONString.CreateWrap(ANode, AOwnsNode)
  else if ANode is fpjson.TJSONBoolean then
    Result := TJSONBool.CreateWrap(ANode, AOwnsNode)
  else if ANode is fpjson.TJSONNull then
    Result := TJSONNull.CreateWrap(ANode, AOwnsNode)
  else if ANode is fpjson.TJSONNumber then
    Result := TJSONNumber.CreateWrap(ANode, AOwnsNode)
  else
    Result := TJSONValue.CreateWrap(ANode, AOwnsNode);
end;

{ TJSONValue - generic accessor backing }

// Walks a dot-separated member path (objects only) from THIS node; nil when any
// segment is absent or a non-object is reached before the last segment. An
// empty path resolves to this node itself.
function TJSONValue._FindByPath(const APath: string): TJSONData;
var
  LCur: TJSONData;
  LSeg: string;
  LDot: Integer;
  LRest: string;
begin
  LCur := FNode;
  LRest := APath;
  while (LRest <> '') and (LCur <> nil) do
  begin
    LDot := Pos('.', LRest);
    if LDot = 0 then
    begin
      LSeg := LRest;
      LRest := '';
    end
    else
    begin
      LSeg := Copy(LRest, 1, LDot - 1);
      LRest := Copy(LRest, LDot + 1, MaxInt);
    end;
    if not (LCur is fpjson.TJSONObject) then
      Exit(nil);
    LCur := fpjson.TJSONObject(LCur).Find(LSeg);
  end;
  Result := LCur;
end;

// Interprets ANode as the requested scalar/class T, writing to the location at
// AValuePtr. False on a type mismatch or a nil node. A materialised class
// wrapper is adopted by THIS value so its lifetime matches System.JSON's read
// model.
function TJSONValue._AssignNodeAs(const ANode: TJSONData;
  const AKind: TTypeKind; const ATypeInfo: PTypeInfo;
  const AValuePtr: Pointer): Boolean;
var
  LWrap: TJSONValue;
  LClass: TClass;
  LStr: string;
  LI: Integer;
  LI64: Int64;
  LB: Boolean;
begin
  Result := False;
  if ANode = nil then
    Exit;
  case AKind of
    tkClass:
      begin
        LWrap := _WrapNode(ANode, False);
        if LWrap = nil then
          Exit;
        LClass := GetTypeData(ATypeInfo)^.ClassType;
        if LWrap.InheritsFrom(LClass) then
        begin
          Adopt(LWrap);
          TObject(AValuePtr^) := LWrap;
          Result := True;
        end
        else
          LWrap.Free;
      end;
    tkAString, tkUString, tkWString:
      if ANode.JSONType in [jtString, jtNumber, jtBoolean] then
      begin
        LStr := ANode.AsString;
        string(AValuePtr^) := LStr;
        Result := True;
      end;
    tkInteger:
      if ANode.JSONType = jtNumber then
      begin
        LI := ANode.AsInteger;
        Move(LI, AValuePtr^, SizeOf(Integer));
        Result := True;
      end;
    tkInt64, tkQWord:
      if ANode.JSONType = jtNumber then
      begin
        LI64 := ANode.AsInt64;
        Move(LI64, AValuePtr^, SizeOf(Int64));
        Result := True;
      end;
    tkBool:
      if ANode.JSONType = jtBoolean then
      begin
        LB := ANode.AsBoolean;
        Move(LB, AValuePtr^, SizeOf(Boolean));
        Result := True;
      end;
  end;
end;

{ TJSONValue }

// Non-generic value lookup (System.JSON parity): the child named AName, or nil
// when this value is not an object / the member is absent. Result wrapper is
// adopted so its lifetime matches this value.
function TJSONValue.GetValue(const AName: string): TJSONValue;
var
  LNode: TJSONData;
begin
  Result := nil;
  if not (FNode is fpjson.TJSONObject) then
    Exit;
  LNode := fpjson.TJSONObject(FNode).Find(AName);
  if LNode = nil then
    Exit;
  Result := _WrapNode(LNode, False);
  if Result <> nil then
    Adopt(Result);
end;

function TJSONValue.TryGetValue<T>(const APath: string; out AValue: T): Boolean;
begin
  AValue := Default(T);
  Result := _AssignNodeAs(_FindByPath(APath), GetTypeKind(T),
    TypeInfo(T), @AValue);
end;

function TJSONValue.GetValue<T>(const APath: string; const ADefault: T): T;
var
  LTmp: T;
begin
  if TryGetValue<T>(APath, LTmp) then
    Result := LTmp
  else
    Result := ADefault;
end;

constructor TJSONValue.CreateWrap(const ANode: TJSONData; const AOwnsNode: Boolean);
begin
  inherited Create;
  FNode := ANode;
  FOwnsNode := AOwnsNode;
end;

destructor TJSONValue.Destroy;
begin
  FOwned.Free;               // frees materialised child wrappers first
  if FOwnsNode and Assigned(FNode) then
    FNode.Free;              // frees the whole fpjson sub-tree exactly once
  inherited Destroy;
end;

procedure TJSONValue.Adopt(const AWrapper: TObject);
begin
  if FOwned = nil then
    FOwned := TObjectList<TObject>.Create(True);
  FOwned.Add(AWrapper);
end;

function TJSONValue.GetValueText: string;
begin
  if FNode = nil then
    Result := ''
  else if FNode.JSONType in [jtString, jtNumber, jtBoolean] then
    Result := FNode.AsString
  else
    Result := '';
end;

function TJSONValue.ToJSON: string;
begin
  if FNode = nil then
    Result := 'null'
  else
    Result := FNode.AsJSON;
end;

function TJSONValue.ToString: string;
begin
  Result := ToJSON;
end;

function TJSONValue.Format(const AIndent: Integer): string;
begin
  if FNode = nil then
    Result := 'null'
  else
    Result := FNode.FormatJSON(DefaultFormat, AIndent);
end;

function TJSONValue.Clone: TJSONValue;
begin
  if FNode = nil then
    Exit(nil);
  // FNode.Clone is a deep fpjson copy; the new wrapper owns it (FOwnsNode).
  Result := _WrapNode(FNode.Clone, True);
end;

{ TJSONString }

constructor TJSONString.Create(const AText: string);
begin
  inherited CreateWrap(fpjson.TJSONString.Create(AText), True);
end;

{ TJSONNumber }

constructor TJSONNumber.Create(const AValue: Int64);
begin
  inherited CreateWrap(fpjson.TJSONInt64Number.Create(AValue), True);
end;

constructor TJSONNumber.Create(const AValue: Double);
begin
  inherited CreateWrap(fpjson.TJSONFloatNumber.Create(AValue), True);
end;

function TJSONNumber.GetAsInt: Integer;
begin
  if (FNode <> nil) and (FNode.JSONType = jtNumber) then
    Result := FNode.AsInteger
  else
    Result := 0;
end;

function TJSONNumber.GetAsDouble: Double;
begin
  if (FNode <> nil) and (FNode.JSONType = jtNumber) then
    Result := FNode.AsFloat
  else
    Result := 0;
end;

{ TJSONBool }

constructor TJSONBool.Create(const AValue: Boolean);
begin
  inherited CreateWrap(fpjson.TJSONBoolean.Create(AValue), True);
end;

function TJSONBool.GetAsBoolean: Boolean;
begin
  Result := (FNode <> nil) and (FNode.JSONType = jtBoolean) and FNode.AsBoolean;
end;

{ TJSONNull }

constructor TJSONNull.Create;
begin
  inherited CreateWrap(fpjson.TJSONNull.Create, True);
end;

{ TJSONArray }

constructor TJSONArray.Create;
begin
  inherited CreateWrap(fpjson.TJSONArray.Create, True);
end;

function TJSONArray.Add(const AValue: TJSONValue): TJSONArray;
begin
  fpjson.TJSONArray(FNode).Add(AValue.FNode);   // fpjson takes node ownership
  AValue.FOwnsNode := False;
  Adopt(AValue);                                // wrapper freed with this array
  Result := Self;
end;

function TJSONArray.Add(const AValue: string): TJSONArray;
begin
  fpjson.TJSONArray(FNode).Add(AValue);
  Result := Self;
end;

function TJSONArray.AddElement(const AValue: TJSONValue): TJSONArray;
begin
  Result := Add(AValue);
end;

function TJSONArray.GetCount: Integer;
begin
  Result := fpjson.TJSONArray(FNode).Count;
end;

function TJSONArray.GetItem(const AIndex: Integer): TJSONValue;
begin
  Result := _WrapNode(fpjson.TJSONArray(FNode).Items[AIndex], False);
  if Result <> nil then
    Adopt(Result);
end;

function TJSONArray.GetEnumerator: TJSONArrayEnumerator;
begin
  // Like TJSONObject.GetEnumerator: the for-in construct frees the enumerator;
  // the item wrappers it yields are adopted by this array.
  Result := TJSONArrayEnumerator.Create(Self);
end;

{ TJSONArrayEnumerator }

constructor TJSONArrayEnumerator.Create(const AOwner: TJSONArray);
begin
  inherited Create;
  FOwner := AOwner;
  FIndex := -1;
end;

function TJSONArrayEnumerator.MoveNext: Boolean;
begin
  Inc(FIndex);
  Result := FIndex < FOwner.Count;
end;

function TJSONArrayEnumerator.GetCurrent: TJSONValue;
begin
  // GetItem materialises the wrapper and adopts it to the array, so the
  // for-in body must not free the element (System.JSON parity).
  Result := FOwner.GetItem(FIndex);
end;

{ TJSONPair }

constructor TJSONPair.Create(const AName: TJSONString; const AValue: TJSONValue);
begin
  inherited Create;
  FName := AName;
  FValue := AValue;
end;

destructor TJSONPair.Destroy;
begin
  FName.Free;
  FValue.Free;
  inherited Destroy;
end;

{ TJSONPairEnumerator }

constructor TJSONPairEnumerator.Create(const AOwner: TJSONObject);
begin
  inherited Create;
  FOwner := AOwner;
  FIndex := -1;
end;

function TJSONPairEnumerator.MoveNext: Boolean;
begin
  Inc(FIndex);
  Result := FIndex < FOwner.AsFpObject.Count;
end;

function TJSONPairEnumerator.GetCurrent: TJSONPair;
var
  LName: TJSONString;
  LValue: TJSONValue;
begin
  LName := TJSONString.Create(FOwner.AsFpObject.Names[FIndex]);
  LValue := _WrapNode(FOwner.AsFpObject.Items[FIndex], False);
  Result := TJSONPair.Create(LName, LValue);
  FOwner.Adopt(Result);      // pair (and its name/value) freed with the object
end;

{ TJSONObject }

constructor TJSONObject.Create;
begin
  inherited CreateWrap(fpjson.TJSONObject.Create, True);
end;

function TJSONObject.AsFpObject: fpjson.TJSONObject;
begin
  Result := fpjson.TJSONObject(FNode);
end;

function TJSONObject.AddPair(const AName, AValue: string): TJSONObject;
begin
  AsFpObject.Add(AName, AValue);
  Result := Self;
end;

function TJSONObject.AddPair(const AName: string; const AValue: TJSONValue): TJSONObject;
begin
  AsFpObject.Add(AName, AValue.FNode);   // fpjson takes node ownership
  AValue.FOwnsNode := False;
  Adopt(AValue);                         // wrapper freed with this object
  Result := Self;
end;

function TJSONObject.Get(const AName: string): TJSONPair;
var
  LNode: TJSONData;
  LName: TJSONString;
  LValue: TJSONValue;
begin
  LNode := AsFpObject.Find(AName);
  if LNode = nil then
    Exit(nil);
  LName := TJSONString.Create(AName);
  LValue := _WrapNode(LNode, False);
  Result := TJSONPair.Create(LName, LValue);
  Adopt(Result);   // pair (and its name/value) freed with the object
end;

function TJSONObject.RemovePair(const AName: string): TJSONPair;
var
  LNode: TJSONData;
  LName: TJSONString;
  LValue: TJSONValue;
begin
  // Extract (not Delete) unlinks the node WITHOUT freeing it, so ownership can
  // pass to the returned pair - the System.JSON contract.
  if AsFpObject.IndexOfName(AName) < 0 then
    Exit(nil);
  LNode := AsFpObject.Extract(AName);
  if LNode = nil then
    Exit(nil);
  LName := TJSONString.Create(AName);
  LValue := _WrapNode(LNode, True);   // the pair now owns the detached sub-tree
  Result := TJSONPair.Create(LName, LValue);
  // Deliberately NOT adopted: the caller frees it (System.JSON parity).
end;

function TJSONObject.GetCount: Integer;
begin
  Result := AsFpObject.Count;
end;

function TJSONObject.GetEnumerator: TJSONPairEnumerator;
begin
  // NOT adopted: the for-in construct frees the enumerator automatically at the
  // end of the loop. The pairs it yields ARE adopted (by the object) so they
  // outlive the enumerator until the object itself is freed.
  Result := TJSONPairEnumerator.Create(Self);
end;

class function TJSONObject.ParseJSONValue(const AJson: string): TJSONValue;
var
  LNode: TJSONData;
begin
  LNode := nil;
  try
    LNode := GetJSON(AJson);
  except
    LNode := nil;
  end;
  Result := _WrapNode(LNode, True);
end;

{$ENDIF}

end.
