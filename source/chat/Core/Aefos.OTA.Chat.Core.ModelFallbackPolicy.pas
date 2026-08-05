unit Aefos.OTA.Chat.Core.ModelFallbackPolicy;

{
  Pure (OTA-free) detector for the model-fallback self-heal.

  Field reports showed a CLI run dying because the picked model slug is not
  supported by that CLI/account (e.g. Codex on a ChatGPT account: "The 'gpt-5'
  model is not supported when using Codex with a ChatGPT account" — the ChatGPT
  backend retires slugs). ModelNotSupported inspects the run's accumulated
  stdout+stderr text and answers whether the failure is THAT class of failure,
  so the executor can re-dispatch ONCE without --model (the CLI's own default).

  Deliberately generic (any CLI, any such message), matched case-insensitively
  on robust substrings. The lone generic phrase 'is not supported when using'
  additionally requires the word 'model' shortly BEFORE it, so unrelated
  "feature X is not supported when using Y" noise never triggers a retry.

  Headless-tested.
}

interface

// True when the accumulated run output signals an unsupported/retired model.
function ModelNotSupported(const AOutput: string): Boolean;

// Returns a short, user-facing hint for a KNOWN class of CLI failure found in
// the run's accumulated output, or '' when nothing recognisable matched. The
// executor prints this ABOVE the raw CLI dump on a failed run, so a cryptic
// provider error (a 400 "[object Object]", a 429 quota wall, a dead OAuth
// login) reads as one actionable English line instead of a scary stack trace.
// Pure: substring-matched case-insensitively; order = most specific first.
// ASuggestedModel makes the "(e.g. <slug>)" example executor-aware — the caller
// passes a valid slug for the ACTIVE executor (so a Codex run no longer suggests
// a Gemini model). Empty falls back to the historical gemini example.
function ClassifyCliFailure(const AOutput: string;
  const ASuggestedModel: string = ''): string;

implementation

uses
  System.SysUtils;

const
  // How far back (in characters) the word 'model' must appear before the
  // generic 'is not supported when using' phrase for it to count as a model
  // rejection (e.g. "the model 'gpt-5' is not supported when using ...").
  CModelProximityWindow = 80;

function ModelNotSupported(const AOutput: string): Boolean;
var
  LText: string;
  LPhrasePos: Integer;
  LWindowStart: Integer;
  LWindow: string;
begin
  Result := False;
  if AOutput = '' then
    Exit;
  LText := LowerCase(AOutput);
  // Strong phrases: each already names the model as the rejected thing.
  if (Pos('model is not supported', LText) > 0) or
     (Pos('unknown model', LText) > 0) or
     (Pos('model not found', LText) > 0) or
     (Pos('unsupported model', LText) > 0) then
    Exit(True);
  // Generic phrase: only a model rejection when 'model' appears shortly before
  // it (covers "the model 'x' is not supported when using ..." variants without
  // firing on unrelated 'not supported' noise).
  LPhrasePos := Pos('is not supported when using', LText);
  if LPhrasePos > 0 then
  begin
    LWindowStart := LPhrasePos - CModelProximityWindow;
    if LWindowStart < 1 then
      LWindowStart := 1;
    LWindow := Copy(LText, LWindowStart, LPhrasePos - LWindowStart);
    Result := Pos('model', LWindow) > 0;
  end;
end;

function ClassifyCliFailure(const AOutput: string;
  const ASuggestedModel: string = ''): string;
var
  LText: string;
  LEg: string;
  function Has(const ANeedle: string): Boolean;
  begin
    Result := Pos(ANeedle, LText) > 0;
  end;
begin
  Result := '';
  if AOutput = '' then
    Exit;
  LText := LowerCase(AOutput);
  // Executor-aware example slug for the model-related hints below.
  if ASuggestedModel <> '' then
    LEg := ASuggestedModel
  else
    LEg := 'gemini-2.5-flash';

  // Dead OAuth login (Google retired "Sign in with Google" for individuals in
  // the Gemini CLI). Most specific, so it wins over the generic auth bucket.
  if Has('no longer supported for gemini code assist') or
     Has('migrate to the antigravity') then
    Exit('Google retired the Gemini CLI''s free "Sign in with Google" login. ' +
      'Use an API key instead: Options > Gemini > paste a key from ' +
      'aistudio.google.com/apikey.');

  // Quota / rate limit (free tiers are small and per-model). The 429 wall.
  if Has('exhausted your daily quota') or Has('resource_exhausted') or
     Has('quota exceeded') or Has('rate limit') or Has('too many requests') or
     Has('status: 429') then
    Exit('The provider''s quota or rate limit was hit (free tiers are small ' +
      'and per-model). Switch model (e.g. ' + LEg + '), swap to another ' +
      'account''s API key, wait for the daily reset, or enable billing.');

  // Invalid / unsupported model.
  if ModelNotSupported(AOutput) or Has('invalid model') or
     Has('is not a valid model') then
    Exit('That model was rejected. Pick one from the Model list (e.g. ' +
      LEg + ') and remove any hand-typed or annotated entry.');

  // Authentication (generic bucket, after the specific cases above).
  if Has('api key not valid') or Has('api_key_invalid') or
     Has('invalid api key') or Has('permission_denied') or
     Has('unauthenticated') or Has('authentication failed') or
     Has('status: 401') or Has('status: 403') then
    Exit('Authentication failed. Check or replace the API key in Options for ' +
      'this provider (create one at aistudio.google.com/apikey for Gemini).');
end;

end.
