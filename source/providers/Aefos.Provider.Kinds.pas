unit Aefos.Provider.Kinds;

{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{ Executor-kind <-> token/display mapping.

  The PURE half of the provider registry: the TExecutorKind <-> config.json
  token and the user-facing display name. It carries NO reference to any driver
  unit, so a consumer that only needs the mapping (the config core, an options
  page) does not drag the driver factory (Aefos.Provider.Registry, which pulls
  Claude/Codex/Copilot/Gemini/Ollama). That separation is what lets the config
  core compile under FPC for the Lazarus port without the CLI drivers - only the
  factory (ResolveExecutorProfile) needs them, and nothing in the port calls it
  yet.

  Aefos.Provider.Registry now delegates its Parse/ToString/DisplayName to this
  unit, so the mapping has a single source of truth; existing callers of
  TProviderRegistry.* keep working unchanged. }

interface

uses
  Aefos.Provider.Types;

type
  // Sealed static namespace: the kind<->token mapping + display name. Never
  // instantiated. Pure - no I/O, no drivers, RTL-only.
  TExecutorKinds = class sealed
  public
    // Parses a config.json token to its kind. An unrecognised token degrades to
    // ekClaude (BR-3) - the caller diagnoses a typo, the mapping never raises.
    class function ParseExecutorKind(const AValue: string): TExecutorKind; static;
    // The config.json token for a kind (round-trips with ParseExecutorKind).
    class function ExecutorKindToString(const AKind: TExecutorKind): string; static;
    // The user-facing display name (vendor-neutral where the product requires).
    class function ExecutorKindDisplayName(const AKind: TExecutorKind): string; static;
    // The display name for a STORED token, WITHOUT ParseExecutorKind's degrade.
    // Returns '' when the token is empty or unrecognised.
    //
    // ParseExecutorKind answering ekClaude for anything it does not know is
    // right for config.json (a typo must still boot the chat) and wrong for a
    // label (a record with no executor recorded would announce "Claude Code",
    // which is the exact lie this exists to stop). A caller that does not know
    // which executor produced a record must show NOTHING, not a guess.
    class function TokenDisplayName(const AToken: string): string; static;
  end;

implementation

uses
  SysUtils;

const
  KIND_TOKEN_CLAUDE = 'claude';
  KIND_TOKEN_CODEX = 'codex';
  KIND_TOKEN_COPILOT = 'copilot';
  KIND_TOKEN_GEMINI = 'gemini';
  KIND_TOKEN_OLLAMA = 'ollama';
  KIND_DISPLAY_CLAUDE = 'Claude Code';
  KIND_DISPLAY_CODEX = 'Codex';
  KIND_DISPLAY_COPILOT = 'GitHub Copilot';
  KIND_DISPLAY_GEMINI = 'Gemini';
  KIND_DISPLAY_OLLAMA = 'Local models (Ollama)';

class function TExecutorKinds.ParseExecutorKind(const AValue: string): TExecutorKind;
begin
  if SameText(Trim(AValue), KIND_TOKEN_CODEX) then
    Result := ekCodex
  else if SameText(Trim(AValue), KIND_TOKEN_COPILOT) then
    Result := ekCopilot
  else if SameText(Trim(AValue), KIND_TOKEN_GEMINI) then
    Result := ekGemini
  else if SameText(Trim(AValue), KIND_TOKEN_OLLAMA) then
    Result := ekOllama
  else
    Result := ekClaude;
end;

class function TExecutorKinds.ExecutorKindToString(const AKind: TExecutorKind): string;
begin
  if AKind = ekCodex then
    Result := KIND_TOKEN_CODEX
  else if AKind = ekCopilot then
    Result := KIND_TOKEN_COPILOT
  else if AKind = ekGemini then
    Result := KIND_TOKEN_GEMINI
  else if AKind = ekOllama then
    Result := KIND_TOKEN_OLLAMA
  else
    Result := KIND_TOKEN_CLAUDE;
end;

class function TExecutorKinds.ExecutorKindDisplayName(const AKind: TExecutorKind): string;
begin
  if AKind = ekCodex then
    Result := KIND_DISPLAY_CODEX
  else if AKind = ekCopilot then
    Result := KIND_DISPLAY_COPILOT
  else if AKind = ekGemini then
    Result := KIND_DISPLAY_GEMINI
  else if AKind = ekOllama then
    Result := KIND_DISPLAY_OLLAMA
  else
    Result := KIND_DISPLAY_CLAUDE;
end;

class function TExecutorKinds.TokenDisplayName(const AToken: string): string;
var
  LKind: TExecutorKind;
  LToken: string;
begin
  Result := '';
  LToken := Trim(AToken);
  if LToken = '' then
    Exit;
  // Round-trip check: only a token the mapping genuinely owns gets a name.
  // Without it every unknown string comes back as the ekClaude default -- which
  // is precisely how a Codex conversation ended up listed as Claude.
  LKind := ParseExecutorKind(LToken);
  if SameText(LToken, ExecutorKindToString(LKind)) then
    Result := ExecutorKindDisplayName(LKind);
end;

end.
