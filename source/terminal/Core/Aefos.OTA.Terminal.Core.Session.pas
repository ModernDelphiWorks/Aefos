unit Aefos.OTA.Terminal.Core.Session;

interface

uses
  System.Classes, System.SysUtils, System.JSON, System.IOUtils, System.Generics.Collections;

const
  /// <summary>
  /// Current session payload format. A session saved with a different version
  /// is treated as incompatible and a fresh session is started instead.
  /// </summary>
  SESSION_FORMAT_VERSION = 2;

type
  /// <summary>
  /// Data structure for persisted terminal session state.
  /// </summary>
  TSessionData = class
  private
    FProfileName: string;
    FWorkingDir: string;
    FBufferContent: string;
    FUpdateTimestamp: TDateTime;
    FFormatVersion: Integer;
  public
    property ProfileName: string read FProfileName write FProfileName;
    property WorkingDir: string read FWorkingDir write FWorkingDir;
    /// <summary>Serialized screen-buffer state (JSON payload).</summary>
    property BufferContent: string read FBufferContent write FBufferContent;
    property UpdateTimestamp: TDateTime read FUpdateTimestamp write FUpdateTimestamp;
    /// <summary>Payload format version; see SESSION_FORMAT_VERSION.</summary>
    property FormatVersion: Integer read FFormatVersion write FFormatVersion;
  end;

  /// <summary>
  /// Manages loading and saving the session state to disk.
  /// </summary>
  TSessionManager = class
  private
    class function _GetConfigPath: string;
  public
    class function Load: TSessionData;
    class procedure Save(const AData: TSessionData);
    class procedure Clear;
  end;

implementation

{ TSessionManager }

class function TSessionManager._GetConfigPath: string;
var
  LAppData: string;
  LDir: string;
begin
  LAppData := GetEnvironmentVariable('APPDATA');
  if LAppData = '' then
    LAppData := TPath.GetHomePath; // Fallback for testing environments

  LDir := TPath.Combine(TPath.Combine(LAppData, 'ModernDelphiWorks'), 'Aefos.OTA.Terminal');
  if not TDirectory.Exists(LDir) then
    TDirectory.CreateDirectory(LDir);
  Result := TPath.Combine(LDir, 'session.json');
end;

class function TSessionManager.Load: TSessionData;
var
  LPath: string;
  LContent: string;
  LJSON: TJSONObject;
begin
  Result := nil;
  LPath := _GetConfigPath;
  if not TFile.Exists(LPath) then
    Exit;

  try
    LContent := TFile.ReadAllText(LPath);
    if LContent.Trim = '' then
      Exit;

    LJSON := TJSONObject.ParseJSONValue(LContent) as TJSONObject;
    if Assigned(LJSON) then
    try
      Result := TSessionData.Create;
      Result.ProfileName := LJSON.GetValue<string>('profileName', '');
      Result.WorkingDir := LJSON.GetValue<string>('workingDir', '');
      Result.BufferContent := LJSON.GetValue<string>('bufferContent', '');
      Result.UpdateTimestamp := LJSON.GetValue<double>('timestamp', 0);
      Result.FormatVersion := LJSON.GetValue<Integer>('formatVersion', 0);
    finally
      LJSON.Free;
    end;
  except
    on LE: Exception do
    begin
      // Gracefully handle corruption or I/O errors
      if Assigned(Result) then
        FreeAndNil(Result);
    end;
  end;
end;

class procedure TSessionManager.Save(const AData: TSessionData);
var
  LJSON: TJSONObject;
  LPath: string;
begin
  if not Assigned(AData) then Exit;

  LJSON := TJSONObject.Create;
  try
    LJSON.AddPair('formatVersion', TJSONNumber.Create(AData.FormatVersion));
    LJSON.AddPair('profileName', AData.ProfileName);
    LJSON.AddPair('workingDir', AData.WorkingDir);
    LJSON.AddPair('bufferContent', AData.BufferContent);
    LJSON.AddPair('timestamp', TJSONNumber.Create(AData.UpdateTimestamp));
    
    LPath := _GetConfigPath;
    TFile.WriteAllText(LPath, LJSON.ToJSON);
  finally
    LJSON.Free;
  end;
end;

class procedure TSessionManager.Clear;
var
  LPath: string;
begin
  LPath := _GetConfigPath;
  if TFile.Exists(LPath) then
    TFile.Delete(LPath);
end;

end.


