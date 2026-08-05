unit Aefos.OTA.Terminal.Core.Layout;

interface

uses
  System.Generics.Collections,
  System.JSON;

type
  TLayoutNodeType = (lntView, lntSplit);

  /// <summary>
  ///   Represents a node in the layout tree structure.
  /// </summary>
  TLayoutNode = class
  private
    FNodeType: TLayoutNodeType;
    FProfile: string;
    FDir: string;
    FOrientation: string; // 'vertical' or 'horizontal'
    FSplitPercent: Double;
    FChild1: TLayoutNode;
    FChild2: TLayoutNode;
    FIsFocused: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    
    /// <summary>
    ///   Serializes the node to a JSON object.
    /// </summary>
    function ToJSON: TJSONObject;
    /// <summary>
    ///   Deserializes the node from a JSON object.
    /// </summary>
    procedure FromJSON(AJSON: TJSONObject);

    /// <summary>
    ///   The type of the node (View or Split).
    /// </summary>
    property NodeType: TLayoutNodeType read FNodeType write FNodeType;
    /// <summary>
    ///   The name of the shell profile for View nodes.
    /// </summary>
    property Profile: string read FProfile write FProfile;
    /// <summary>
    ///   The working directory for View nodes.
    /// </summary>
    property Dir: string read FDir write FDir;
    /// <summary>
    ///   The orientation of the split ('vertical' or 'horizontal').
    /// </summary>
    property Orientation: string read FOrientation write FOrientation;
    /// <summary>
    ///   The split percentage (0.0 to 1.0).
    /// </summary>
    property SplitPercent: Double read FSplitPercent write FSplitPercent;
    /// <summary>
    ///   The first child node in a split.
    /// </summary>
    property Child1: TLayoutNode read FChild1 write FChild1;
    /// <summary>
    ///   The second child node in a split.
    /// </summary>
    property Child2: TLayoutNode read FChild2 write FChild2;
    /// <summary>
    ///   Indicates if this view node was the focused one.
    /// </summary>
    property IsFocused: Boolean read FIsFocused write FIsFocused;
  end;

  /// <summary>
  ///   Represents the layout of a single tab.
  /// </summary>
  TTabLayout = class
  private
    FCaption: string;
    FRoot: TLayoutNode;
  public
    destructor Destroy; override;
    
    /// <summary>
    ///   Serializes the tab layout to a JSON object.
    /// </summary>
    function ToJSON: TJSONObject;
    /// <summary>
    ///   Deserializes the tab layout from a JSON object.
    /// </summary>
    procedure FromJSON(AJSON: TJSONObject);

    /// <summary>
    ///   The display caption of the tab.
    /// </summary>
    property Caption: string read FCaption write FCaption;
    /// <summary>
    ///   The root node of the terminal hierarchy in this tab.
    /// </summary>
    property Root: TLayoutNode read FRoot write FRoot;
  end;

  /// <summary>
  ///   Represents the entire workspace layout including all tabs.
  /// </summary>
  TWorkspaceLayout = class
  private
    FActiveTabIndex: Integer;
    FTabs: TObjectList<TTabLayout>;
    FActionCenterVisible: Boolean;
    FActionCenterLeft: Integer;
    FActionCenterTop: Integer;
    FActionCenterWidth: Integer;
    FActionCenterHeight: Integer;
  public
    constructor Create;
    destructor Destroy; override;

    /// <summary>
    ///   Serializes the entire workspace layout to a JSON object.
    /// </summary>
    function ToJSON: TJSONObject;
    /// <summary>
    ///   Deserializes the entire workspace layout from a JSON object.
    /// </summary>
    procedure FromJSON(AJSON: TJSONObject);

    /// <summary>
    ///   The index of the currently active tab.
    /// </summary>
    property ActiveTabIndex: Integer read FActiveTabIndex write FActiveTabIndex;
    /// <summary>
    ///   The list of tab layouts in the workspace.
    /// </summary>
    property Tabs: TObjectList<TTabLayout> read FTabs;
    /// <summary>
    ///   Whether the Action Center panel was visible.
    /// </summary>
    property ActionCenterVisible: Boolean read FActionCenterVisible
      write FActionCenterVisible;
    /// <summary>
    ///   The Action Center panel's left coordinate.
    /// </summary>
    property ActionCenterLeft: Integer read FActionCenterLeft
      write FActionCenterLeft;
    /// <summary>
    ///   The Action Center panel's top coordinate.
    /// </summary>
    property ActionCenterTop: Integer read FActionCenterTop
      write FActionCenterTop;
    /// <summary>
    ///   The Action Center panel's width.
    /// </summary>
    property ActionCenterWidth: Integer read FActionCenterWidth
      write FActionCenterWidth;
    /// <summary>
    ///   The Action Center panel's height.
    /// </summary>
    property ActionCenterHeight: Integer read FActionCenterHeight
      write FActionCenterHeight;
  end;

  /// <summary>
  ///   Static manager for loading and saving workspace layouts to disk.
  /// </summary>
  TLayoutManager = class
  public
    /// <summary>
    ///   Loads the workspace layout from the configuration file.
    /// </summary>
    class function Load: TWorkspaceLayout;
    /// <summary>
    ///   Saves the workspace layout to the configuration file.
    /// </summary>
    class procedure Save(ALayout: TWorkspaceLayout);
  end;

implementation

uses
  System.Classes, System.SysUtils, System.IOUtils;

{ TLayoutNode }

constructor TLayoutNode.Create;
begin
  inherited;
  FNodeType := lntView;
end;

destructor TLayoutNode.Destroy;
begin
  FChild1.Free;
  FChild2.Free;
  inherited;
end;

function TLayoutNode.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  if FNodeType = lntView then
  begin
    Result.AddPair('type', 'view');
    Result.AddPair('profile', FProfile);
    Result.AddPair('dir', FDir);
    Result.AddPair('isFocused', FIsFocused);
  end
  else
  begin
    Result.AddPair('type', 'split');
    Result.AddPair('orientation', FOrientation);
    Result.AddPair('splitPercent', TJSONNumber.Create(FSplitPercent));
    if Assigned(FChild1) then
      Result.AddPair('child1', FChild1.ToJSON);
    if Assigned(FChild2) then
      Result.AddPair('child2', FChild2.ToJSON);
  end;
end;

procedure TLayoutNode.FromJSON(AJSON: TJSONObject);
var
  LType: string;
begin
  LType := AJSON.GetValue<string>('type', 'view');
  if LType = 'view' then
  begin
    FNodeType := lntView;
    FProfile := AJSON.GetValue<string>('profile', '');
    FDir := AJSON.GetValue<string>('dir', '');
    FIsFocused := AJSON.GetValue<Boolean>('isFocused', False);
  end
  else
  begin
    FNodeType := lntSplit;
    FOrientation := AJSON.GetValue<string>('orientation', 'vertical');
    FSplitPercent := AJSON.GetValue<Double>('splitPercent', 0.5);
    
    if AJSON.GetValue('child1') <> nil then
    begin
      FChild1 := TLayoutNode.Create;
      FChild1.FromJSON(AJSON.GetValue<TJSONObject>('child1'));
    end;
    
    if AJSON.GetValue('child2') <> nil then
    begin
      FChild2 := TLayoutNode.Create;
      FChild2.FromJSON(AJSON.GetValue<TJSONObject>('child2'));
    end;
  end;
end;

{ TTabLayout }


destructor TTabLayout.Destroy;
begin
  FRoot.Free;
  inherited;
end;

function TTabLayout.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('caption', FCaption);
  if Assigned(FRoot) then
    Result.AddPair('root', FRoot.ToJSON);
end;

procedure TTabLayout.FromJSON(AJSON: TJSONObject);
begin
  FCaption := AJSON.GetValue<string>('caption', '');
  if AJSON.GetValue('root') <> nil then
  begin
    FRoot := TLayoutNode.Create;
    FRoot.FromJSON(AJSON.GetValue<TJSONObject>('root'));
  end;
end;

{ TWorkspaceLayout }

constructor TWorkspaceLayout.Create;
begin
  inherited;
  FTabs := TObjectList<TTabLayout>.Create(True);
end;

destructor TWorkspaceLayout.Destroy;
begin
  FTabs.Free;
  inherited;
end;

function TWorkspaceLayout.ToJSON: TJSONObject;
var
  LTabsArray: TJSONArray;
  LActionCenter: TJSONObject;
  LIndex: Integer;
begin
  Result := TJSONObject.Create;
  Result.AddPair('activeTabIndex', TJSONNumber.Create(FActiveTabIndex));
  LTabsArray := TJSONArray.Create;
  for LIndex := 0 to FTabs.Count - 1 do
    LTabsArray.AddElement(FTabs[LIndex].ToJSON);
  Result.AddPair('tabs', LTabsArray);

  LActionCenter := TJSONObject.Create;
  LActionCenter.AddPair('visible', TJSONBool.Create(FActionCenterVisible));
  LActionCenter.AddPair('left', TJSONNumber.Create(FActionCenterLeft));
  LActionCenter.AddPair('top', TJSONNumber.Create(FActionCenterTop));
  LActionCenter.AddPair('width', TJSONNumber.Create(FActionCenterWidth));
  LActionCenter.AddPair('height', TJSONNumber.Create(FActionCenterHeight));
  Result.AddPair('actionCenter', LActionCenter);
end;

procedure TWorkspaceLayout.FromJSON(AJSON: TJSONObject);
var
  LTabsArray: TJSONArray;
  LTabValue: TJSONValue;
  LActionCenter: TJSONObject;
  LTab: TTabLayout;
begin
  FActiveTabIndex := AJSON.GetValue<Integer>('activeTabIndex', 0);
  FTabs.Clear;
  LTabsArray := AJSON.GetValue<TJSONArray>('tabs');
  if Assigned(LTabsArray) then
  begin
    for LTabValue in LTabsArray do
    begin
      LTab := TTabLayout.Create;
      LTab.FromJSON(LTabValue as TJSONObject);
      FTabs.Add(LTab);
    end;
  end;

  LActionCenter := AJSON.GetValue<TJSONObject>('actionCenter');
  if Assigned(LActionCenter) then
  begin
    FActionCenterVisible := LActionCenter.GetValue<Boolean>('visible', False);
    FActionCenterLeft := LActionCenter.GetValue<Integer>('left', 0);
    FActionCenterTop := LActionCenter.GetValue<Integer>('top', 0);
    FActionCenterWidth := LActionCenter.GetValue<Integer>('width', 0);
    FActionCenterHeight := LActionCenter.GetValue<Integer>('height', 0);
  end;
end;

{ TLayoutManager }

class function TLayoutManager.Load: TWorkspaceLayout;
var
  LAppData, LDir, LPath, LContent: string;
  LJSONValue: TJSONValue;
begin
  Result := nil;

  LAppData := GetEnvironmentVariable('APPDATA');
  if LAppData = '' then
    LAppData := TPath.GetHomePath;
  LDir := TPath.Combine(TPath.Combine(LAppData, 'ModernDelphiWorks'), 'Aefos.OTA.Terminal');
  LPath := TPath.Combine(LDir, 'layout.json');

  if not TFile.Exists(LPath) then
    Exit;

  try
    LContent := TFile.ReadAllText(LPath);
    if LContent.Trim = '' then
      Exit;

    LJSONValue := TJSONObject.ParseJSONValue(LContent);
    try
      if LJSONValue is TJSONObject then
      begin
        Result := TWorkspaceLayout.Create;
        Result.FromJSON(LJSONValue as TJSONObject);
      end;
    finally
      LJSONValue.Free;  // frees even when root parses to a non-object (array/number)
    end;
  except
    FreeAndNil(Result);
  end;
end;

class procedure TLayoutManager.Save(ALayout: TWorkspaceLayout);
var
  LJSON: TJSONObject;
  LAppData, LDir, LPath: string;
begin
  LAppData := GetEnvironmentVariable('APPDATA');
  if LAppData = '' then
    LAppData := TPath.GetHomePath;
  LDir := TPath.Combine(TPath.Combine(LAppData, 'ModernDelphiWorks'), 'Aefos.OTA.Terminal');
  if not TDirectory.Exists(LDir) then
    TDirectory.CreateDirectory(LDir);
  LPath := TPath.Combine(LDir, 'layout.json');

  LJSON := ALayout.ToJSON;
  try
    TFile.WriteAllText(LPath, LJSON.ToJSON);
  finally
    LJSON.Free;
  end;
end;

end.


