unit Aefos.OTA.Terminal.Core.Themes;

interface

uses
  System.Classes, System.SysUtils, System.Generics.Collections, Vcl.Graphics,
  System.IniFiles, System.IOUtils, Aefos.OTA.Terminal.Core.CellColor;

type
  TTerminalTheme = record
    Name: string;
    Background: TColor;
    Foreground: TColor;
    Cursor: TColor;
    ANSIColors: array[0..15] of TColor;
    /// <summary>
    /// Build a theme in one call. AANSIColors supplies the 16-entry ANSI
    /// palette; any slot beyond what is passed is filled with clNone (so an
    /// empty array yields the all-clNone "Delphi IDE" theme). Collapses the
    /// per-colour assignment ritual the manager used to repeat per theme.
    /// </summary>
    class function Create(const AName: string;
      ABackground, AForeground, ACursor: TColor;
      const AANSIColors: array of TColor): TTerminalTheme; static;
    /// <summary>
    /// The 16 base ANSI palette entries as a TBasePalette, ready for the
    /// cell-colour resolver.
    /// </summary>
    function BasePalette: TBasePalette;
  end;

  TThemeManager = class
  private
    FThemes: TList<TTerminalTheme>;
    FActiveThemeIndex: Integer;
    FFontName: string;
    FFontSize: Integer;
    function _GetConfigPath: string;
  public
    constructor Create;
    destructor Destroy; override;

    procedure LoadFromIni;
    procedure SaveToIni;

    property Themes: TList<TTerminalTheme> read FThemes;
    property ActiveThemeIndex: Integer read FActiveThemeIndex write FActiveThemeIndex;
    property FontName: string read FFontName write FFontName;
    property FontSize: Integer read FFontSize write FFontSize;
  end;

implementation

uses
  Aefos.OTA.Terminal.Core.GlyphSupport;

class function TTerminalTheme.Create(const AName: string;
  ABackground, AForeground, ACursor: TColor;
  const AANSIColors: array of TColor): TTerminalTheme;
var
  LIndex: Integer;
begin
  Result.Name := AName;
  Result.Background := ABackground;
  Result.Foreground := AForeground;
  Result.Cursor := ACursor;
  for LIndex := 0 to 15 do
    if LIndex <= High(AANSIColors) then
      Result.ANSIColors[LIndex] := AANSIColors[LIndex]
    else
      Result.ANSIColors[LIndex] := clNone;
end;

function TTerminalTheme.BasePalette: TBasePalette;
var
  LIndex: Integer;
begin
  for LIndex := 0 to 15 do
    Result[LIndex] := ANSIColors[LIndex];
end;

{ TThemeManager }

constructor TThemeManager.Create;
begin
  inherited Create;
  FThemes := TList<TTerminalTheme>.Create;

  // Theme 1: Campbell (Windows Console Default)
  FThemes.Add(TTerminalTheme.Create('Campbell', $0C0C0C, $CCCCCC, $FFFFFF,
    [$0C0C0C, $1F0FC5, $0EA113, $009CC1, $DA3700, $981788, $DD963A, $CCCCCC,
     $767676, $5648E7, $0CC616, $A5F2F9, $FF783B, $9E00B4, $D6D861, $F2F2F2]));

  // Theme 2: OneHalfDark
  FThemes.Add(TTerminalTheme.Create('OneHalfDark', $342C28, $DCDCDD, $DCDCDD,
    [$342C28, $4561E0, $77C298, $75C1E5, $F2AF61, $B67CC0, $C0C556, $DCDCDD,
     $645A5A, $4561E0, $77C298, $75C1E5, $F2AF61, $B67CC0, $C0C556, $DCDCDD]));

  // Theme 3: SolarizedLight
  FThemes.Add(TTerminalTheme.Create('SolarizedLight', $E3F6FD, $425465, $425465,
    [$D2E807, $2F32DC, $008985, $0089B5, $D28B26, $8236D3, $98A12A, $D5E8EE,
     $839400, $164CCB, $536858, $425465, $969483, $C4716C, $A1A193, $E3F6FD]));

  // Theme 4: Delphi IDE (strictly locks all window and canvas colors to
  // Embarcadero's style services; the empty palette fills all 16 with clNone).
  FThemes.Add(TTerminalTheme.Create('Delphi IDE', clWindow, clWindowText,
    clWindowText, []));

  FActiveThemeIndex := 3; // Default to 'Delphi IDE'
  FFontName := TERMINAL_NERD_FONT;
  FFontSize := 10;
  LoadFromIni;
end;

destructor TThemeManager.Destroy;
begin
  FThemes.Free;
  inherited;
end;

function TThemeManager._GetConfigPath: string;
var
  LAppData: string;
  LDir: string;
begin
  LAppData := GetEnvironmentVariable('APPDATA');
  LDir := TPath.Combine(TPath.Combine(LAppData, 'ModernDelphiWorks'), 'Aefos.OTA.Terminal');
  if not TDirectory.Exists(LDir) then
    TDirectory.CreateDirectory(LDir);
  Result := TPath.Combine(LDir, 'config.ini');
end;

procedure TThemeManager.LoadFromIni;
var
  LIni: TMemIniFile;
  LStored: string;
begin
  LIni := TMemIniFile.Create(_GetConfigPath);
  try
    // Strictly locked to 'Delphi IDE' (index 3); the saved ActiveTheme value is ignored.
    FActiveThemeIndex := 3;

    LStored := LIni.ReadString('Settings', 'FontName', TERMINAL_NERD_FONT);
    // A persisted name that lacks the powerline / BMP-PUA glyph set (e.g. an
    // older 'Cascadia Code' default) realizes a face without those glyphs and
    // renders tofu. Normalize it to the embedded Nerd Font face and heal the
    // stored value (ESP-081 S0 root cause; ADR-081-01).
    FFontName := TGlyphSupport.NormalizeFontName(LStored);
    if FFontName <> LStored then
    begin
      LIni.WriteString('Settings', 'FontName', FFontName);
      LIni.UpdateFile;
    end;
    FFontSize := LIni.ReadInteger('Settings', 'FontSize', 10);
  finally
    LIni.Free;
  end;
end;

procedure TThemeManager.SaveToIni;
var
  LIni: TMemIniFile;
begin
  LIni := TMemIniFile.Create(_GetConfigPath);
  try
    if (FActiveThemeIndex >= 0) and (FActiveThemeIndex < FThemes.Count) then
      LIni.WriteString('Settings', 'ActiveTheme', FThemes[FActiveThemeIndex].Name);
    LIni.WriteString('Settings', 'FontName', FFontName);
    LIni.WriteInteger('Settings', 'FontSize', FFontSize);
    LIni.UpdateFile;
  finally
    LIni.Free;
  end;
end;

end.


