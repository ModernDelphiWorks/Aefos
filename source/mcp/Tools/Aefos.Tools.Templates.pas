unit Aefos.Tools.Templates;

(*
  Aefos.Tools.Templates — pure template engine + file-based library.

  Lets the agent GET a project/unit template and render it with a small set of
  variables, instead of emitting the whole source itself (token economy). The
  library is data-driven: a template is a `.tpl` file under a root directory,
  addressed by id `<tipo>/<artefato>` (e.g. 'vcl/program', 'vcl/mainform.pas').
  Adding a template = dropping a file; no recompile.

  Two layers:
    - Render (pure, no IO): TTemplateEngine.Render(text, vars) — substitutes every
      `{{Key}}` and reports any placeholder left unresolved.
    - Library (reads files): TTemplateEngine.Load / TTemplateEngine.RenderFile —
      resolves `<root>\<id>.tpl` and renders it.

  Placeholder syntax: exact `{{Key}}` (case-sensitive, no inner spaces).

  Boundary: RTL only (System.IOUtils for reads). No ToolsAPI, no Vcl./FMX.
  The OTA host stays the applier — it consumes the rendered text to materialise
  a project/unit via IOTAModuleServices.

  Naming convention: MCP\Source\Tools\NAMING.md.
*)

interface

type
  // Outcome of a template operation. Prefix `tpl` keeps the unscoped enum from
  // colliding with TToolTextOutcome's `tt*`.
  TToolTemplateOutcome = (
    tplApplied,          // rendered; every placeholder resolved
    tplUnknownTemplate,  // no `.tpl` file for the requested id
    tplMissingVar,       // rendered, but placeholders remain (see Unresolved)
    tplReadError         // the template file could not be read
  );

  TToolTemplateVar = record
    Key: string;
    Value: string;
    class function Make(const AKey, AValue: string): TToolTemplateVar; static;
  end;

  TToolTemplateResult = record
    Outcome: TToolTemplateOutcome;
    Content: string;               // rendered text (filled when not a load error)
    Unresolved: TArray<string>;    // placeholder keys left without a value
    function Ok: Boolean;
    function OutcomeText: string;
  end;

  // Pure template engine + file-based library as a sealed static namespace
  // (see the unit header). Never instantiated.
  TTemplateEngine = class sealed
  public
    // ── Render (pure) ────────────────────────────────────────────────────────

    // Substitutes every `{{Key}}` in ATemplate with its value and reports any
    // placeholder that had no matching variable.
    class function Render(const ATemplate: string;
      const AVars: TArray<TToolTemplateVar>): TToolTemplateResult; static;

    // ── Library (file-based) ─────────────────────────────────────────────────

    // Absolute path of template AId under ARoot (`<root>\<id>.tpl`, '/' → PathDelim).
    class function ResolvePath(const ARoot, ATemplateId: string): string; static;

    // Loads the raw template text for AId. tplUnknownTemplate when absent.
    class function Load(const ARoot, ATemplateId: string;
      out AContent: string): TToolTemplateOutcome; static;

    // Loads AId and renders it with AVars in one call.
    class function RenderFile(const ARoot, ATemplateId: string;
      const AVars: TArray<TToolTemplateVar>): TToolTemplateResult; static;

    // The Delphi project types the library is expected to cover (VCL → library).
    class function ProjectTypes: TArray<string>; static;
  end;

implementation

uses
  System.SysUtils,
  System.StrUtils,
  System.IOUtils,
  Aefos.Compat.IO,
  System.Generics.Collections;

{ TToolTemplateVar }

class function TToolTemplateVar.Make(const AKey,
  AValue: string): TToolTemplateVar;
begin
  Result.Key := AKey;
  Result.Value := AValue;
end;

{ TToolTemplateResult }

function TToolTemplateResult.Ok: Boolean;
begin
  Result := Outcome = tplApplied;
end;

function TToolTemplateResult.OutcomeText: string;
begin
  case Outcome of
    tplApplied:         Result := 'applied';
    tplUnknownTemplate: Result := 'unknown-template';
    tplMissingVar:      Result := 'missing-var';
    tplReadError:       Result := 'read-error';
  else
    Result := 'unknown';
  end;
end;

// ── Render ───────────────────────────────────────────────────────────────

// Collects the distinct keys of every `{{...}}` still present in AText.
function _FindUnresolved(const AText: string): TArray<string>;
var
  LList: TList<string>;
  LOpen, LClose: Integer;
  LKey: string;
begin
  LList := TList<string>.Create;
  try
    LOpen := Pos('{{', AText);
    while LOpen > 0 do
    begin
      LClose := PosEx('}}', AText, LOpen + 2);
      if LClose = 0 then
        Break;
      LKey := Copy(AText, LOpen + 2, LClose - (LOpen + 2));
      if LList.IndexOf(LKey) < 0 then
        LList.Add(LKey);
      LOpen := PosEx('{{', AText, LClose + 2);
    end;
    Result := LList.ToArray;
  finally
    LList.Free;
  end;
end;

class function TTemplateEngine.Render(const ATemplate: string;
  const AVars: TArray<TToolTemplateVar>): TToolTemplateResult;
var
  LText: string;
  LFor: Integer;
begin
  LText := ATemplate;
  for LFor := 0 to High(AVars) do
    LText := StringReplace(LText, '{{' + AVars[LFor].Key + '}}',
      AVars[LFor].Value, [rfReplaceAll]);
  Result.Content := LText;
  Result.Unresolved := _FindUnresolved(LText);
  if Length(Result.Unresolved) > 0 then
    Result.Outcome := tplMissingVar
  else
    Result.Outcome := tplApplied;
end;

// ── Library ──────────────────────────────────────────────────────────────

class function TTemplateEngine.ResolvePath(const ARoot, ATemplateId: string): string;
var
  LRel: string;
begin
  LRel := StringReplace(ATemplateId, '/', PathDelim, [rfReplaceAll]) + '.tpl';
  Result := TPath.Combine(ARoot, LRel);
end;

class function TTemplateEngine.Load(const ARoot, ATemplateId: string;
  out AContent: string): TToolTemplateOutcome;
var
  LPath: string;
begin
  AContent := '';
  LPath := TTemplateEngine.ResolvePath(ARoot, ATemplateId);
  if not TFile.Exists(LPath) then
    Exit(tplUnknownTemplate);
  try
    AContent := TAefosText.ReadAllUtf8(LPath);
  except
    Exit(tplReadError);
  end;
  Result := tplApplied;
end;

class function TTemplateEngine.RenderFile(const ARoot, ATemplateId: string;
  const AVars: TArray<TToolTemplateVar>): TToolTemplateResult;
var
  LContent: string;
  LLoad: TToolTemplateOutcome;
begin
  LLoad := TTemplateEngine.Load(ARoot, ATemplateId, LContent);
  if LLoad <> tplApplied then
  begin
    Result := Default(TToolTemplateResult);
    Result.Outcome := LLoad;
    Exit;
  end;
  Result := TTemplateEngine.Render(LContent, AVars);
end;

class function TTemplateEngine.ProjectTypes: TArray<string>;
begin
  Result := ['vcl', 'fmx', 'console', 'library', 'package', 'dunit', 'dunitx'];
end;

end.
