unit Aefos.MCP.ThemeBridge;

{$IFDEF FPC}{$mode delphiunicode}{$H+}{$ENDIF}

{
  The IDE's resolved theme colours, written where a SEPARATE PROCESS can read
  them.

  Every Aefos permission surface that lives inside the IDE asks the IDE for its
  theme and paints to match. The desktop popup cannot: it runs in
  AefosDesktopMcp.exe, which has no ToolsAPI and nobody to ask -- so it wore a
  fixed dark palette and ended up looking like a different product next to a
  light-themed modal. The owner's verdict on that: "para mim nao valeu de NADA".

  So the IDE writes what it resolved, once, to a small file, and the popup reads
  it at startup. Deliberately a FILE and not an env var: the theme can change
  while the IDE runs, and the child is spawned once at load.

  Degrades to the dark default at every step -- a missing, unreadable or partial
  file simply means the popup looks the way it did before. A colour is never
  worth failing a consent prompt over.

  Purity: RTL only, no VCL/LCL/OTA, so both editions and the out-of-process
  server compile the same unit. ASCII only: no BOM needed.
}

interface

uses
  {$IFDEF FPC}
  SysUtils, Classes;
  {$ELSE}
  System.SysUtils, System.Classes;
  {$ENDIF}

type
  { Colours as $00RRGGBB, NOT Windows' $00BBGGRR: this crosses a process and a
    file, and the one thing worse than a wrong colour is two sides disagreeing
    about the byte order silently. Converted at the point of use. }
  TAefosThemeColors = record
    Background: Cardinal;
    Surface: Cardinal;     // the panel/caption strip behind the content
    Text: Cardinal;
    DimText: Cardinal;
    Border: Cardinal;
    Accent: Cardinal;
    IsDark: Boolean;
  end;

  TAefosThemeBridge = class sealed
  public
    { The palette the popup falls back to: today's fixed dark one, so a machine
      with no file behaves exactly as it did before this existed. }
    class function Defaults: TAefosThemeColors; static;
    { %APPDATA%\Aefos\ide-theme.ini -- one place, both editions. }
    class function FilePath: string; static;
    { Writes what the IDE resolved. Never raises: a failed write costs a colour,
      and the caller is on the IDE main thread during startup. }
    class procedure Save(const AColors: TAefosThemeColors); static;
    { Reads it back, filling anything missing from Defaults. Never raises. }
    class function Load: TAefosThemeColors; static;
    { Parsing split out from the file read so it can be tested headlessly --
      this is the part with the real chance of being wrong. }
    class function Parse(const AText: string): TAefosThemeColors; static;
    class function Render(const AColors: TAefosThemeColors): string; static;
  end;

implementation

const
  CKeyBackground = 'background';
  CKeySurface    = 'surface';
  CKeyText       = 'text';
  CKeyDimText    = 'dimtext';
  CKeyBorder     = 'border';
  CKeyAccent     = 'accent';
  CKeyIsDark     = 'isdark';

class function TAefosThemeBridge.Defaults: TAefosThemeColors;
begin
  Result.Background := $1B1D21;
  Result.Surface    := $212429;
  Result.Text       := $FFFFFF;
  Result.DimText    := $8B9099;
  Result.Border     := $33373D;
  Result.Accent     := $D97757;
  Result.IsDark     := True;
end;

class function TAefosThemeBridge.FilePath: string;
var
  LRoot: string;
begin
  LRoot := GetEnvironmentVariable('APPDATA');
  if LRoot = '' then
    Exit('');
  Result := IncludeTrailingPathDelimiter(LRoot) + 'Aefos' + PathDelim
    + 'ide-theme.ini';
end;

class function TAefosThemeBridge.Render(
  const AColors: TAefosThemeColors): string;

  function Hex(const AValue: Cardinal): string;
  begin
    Result := IntToHex(AValue and $FFFFFF, 6);
  end;

begin
  // Plain key=value, RRGGBB. Readable by a human staring at it, which matters
  // for a file whose only symptom when wrong is "the colour looks off".
  Result :=
    CKeyBackground + '=' + Hex(AColors.Background) + sLineBreak +
    CKeySurface    + '=' + Hex(AColors.Surface) + sLineBreak +
    CKeyText       + '=' + Hex(AColors.Text) + sLineBreak +
    CKeyDimText    + '=' + Hex(AColors.DimText) + sLineBreak +
    CKeyBorder     + '=' + Hex(AColors.Border) + sLineBreak +
    CKeyAccent     + '=' + Hex(AColors.Accent) + sLineBreak +
    CKeyIsDark     + '=' + IntToStr(Ord(AColors.IsDark)) + sLineBreak;
end;

class function TAefosThemeBridge.Parse(
  const AText: string): TAefosThemeColors;
var
  LLines: TStringList;
  LScan, LEq: Integer;
  LKey, LValue, LLine: string;
  LNum: Int64;

  function ReadHex(const AStr: string; const ADefault: Cardinal): Cardinal;
  var
    LParsed: Int64;
  begin
    // A malformed entry keeps the default rather than painting black-on-black.
    if TryStrToInt64('$' + Trim(AStr), LParsed) and (LParsed >= 0)
      and (LParsed <= $FFFFFF) then
      Result := Cardinal(LParsed)
    else
      Result := ADefault;
  end;

begin
  Result := Defaults;
  if Trim(AText) = '' then
    Exit;
  LLines := TStringList.Create;
  try
    LLines.Text := AText;
    for LScan := 0 to LLines.Count - 1 do
    begin
      LLine := Trim(LLines[LScan]);
      if (LLine = '') or (LLine[1] = ';') or (LLine[1] = '#') then
        Continue;
      LEq := Pos('=', LLine);
      if LEq <= 1 then
        Continue;
      LKey := LowerCase(Trim(Copy(LLine, 1, LEq - 1)));
      LValue := Trim(Copy(LLine, LEq + 1, MaxInt));
      if LKey = CKeyBackground then
        Result.Background := ReadHex(LValue, Result.Background)
      else if LKey = CKeySurface then
        Result.Surface := ReadHex(LValue, Result.Surface)
      else if LKey = CKeyText then
        Result.Text := ReadHex(LValue, Result.Text)
      else if LKey = CKeyDimText then
        Result.DimText := ReadHex(LValue, Result.DimText)
      else if LKey = CKeyBorder then
        Result.Border := ReadHex(LValue, Result.Border)
      else if LKey = CKeyAccent then
        Result.Accent := ReadHex(LValue, Result.Accent)
      else if LKey = CKeyIsDark then
        if TryStrToInt64(LValue, LNum) then
          Result.IsDark := LNum <> 0;
    end;
  finally
    LLines.Free;
  end;
end;

class procedure TAefosThemeBridge.Save(const AColors: TAefosThemeColors);
var
  LPath: string;
  LFile: TStringList;
begin
  LPath := FilePath;
  if LPath = '' then
    Exit;
  try
    ForceDirectories(ExtractFilePath(LPath));
    LFile := TStringList.Create;
    try
      LFile.Text := Render(AColors);
      LFile.SaveToFile(LPath);
    finally
      LFile.Free;
    end;
  except
    // A colour is never worth an exception on the IDE's startup path.
  end;
end;

class function TAefosThemeBridge.Load: TAefosThemeColors;
var
  LPath: string;
  LFile: TStringList;
begin
  Result := Defaults;
  LPath := FilePath;
  if (LPath = '') or not FileExists(LPath) then
    Exit;
  try
    LFile := TStringList.Create;
    try
      LFile.LoadFromFile(LPath);
      Result := Parse(LFile.Text);
    finally
      LFile.Free;
    end;
  except
    Result := Defaults;
  end;
end;

end.
