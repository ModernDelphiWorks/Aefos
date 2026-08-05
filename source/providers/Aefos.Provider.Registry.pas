unit Aefos.Provider.Registry;

{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

{ Provider registry — the factory + kind<->token mapping. Selects a driver from
  a TExecutorKind; the two-arg overload injects the probed TMcpSupport into a
  Codex/Copilot/Gemini driver. This is the unit consumers reference for the free
  functions (the per-provider driver units are seen only here). }

interface

uses
  Aefos.Provider.Types;

type
  // The provider registry as a sealed static namespace: the factory +
  // kind<->token mapping. Never instantiated — the class is the namespace; the
  // per-provider driver units stay visible only inside the implementation.
  TProviderRegistry = class sealed
  public
    class function ResolveExecutorProfile(const AKind: TExecutorKind): IExecutorProfile;
      overload; static;
    class function ResolveExecutorProfile(const AKind: TExecutorKind;
      const AMcpSupport: TMcpSupport): IExecutorProfile; overload; static;
    class function ParseExecutorKind(const AValue: string): TExecutorKind; static;
    class function ExecutorKindToString(const AKind: TExecutorKind): string; static;
    class function ExecutorKindDisplayName(const AKind: TExecutorKind): string; static;
    // Display name for a stored token; '' when empty or unrecognised (never the
    // ekClaude fallback). For labelling records whose executor may be unknown.
    class function TokenDisplayName(const AToken: string): string; static;
    // ADR-083 / BR-2: the guard predicate for Register._ResolveExecutorGraph.
    // True when the executor graph must be (re)built — no profile resolved yet, or
    // the desired executor differs from the live one. Pure — unit-testable.
    class function ExecutorGraphNeedsReResolve(const AProfileResolved: Boolean;
      const ACurrentKind, ADesiredKind: TExecutorKind): Boolean; static;
    // ESP-003 / AC-02: the FULL re-resolve decision — also re-resolves when the
    // active project root changed. Pure (no OTA, RTL-only).
    class function ShouldReResolveExecutorGraph(const AProfileResolved: Boolean;
      const ACurrentKind, ADesiredKind: TExecutorKind;
      const ALastRoot, ACurrentRoot: string): Boolean; static;
  end;

implementation

uses
  Aefos.Provider.Kinds,
  Aefos.Provider.Claude,
  Aefos.Provider.Codex,
  Aefos.Provider.Copilot,
  Aefos.Provider.Gemini,
  Aefos.Provider.Ollama.Profile;

class function TProviderRegistry.ResolveExecutorProfile(const AKind: TExecutorKind): IExecutorProfile;
begin
  Result := ResolveExecutorProfile(AKind, msUnknown);
end;

class function TProviderRegistry.ResolveExecutorProfile(const AKind: TExecutorKind;
  const AMcpSupport: TMcpSupport): IExecutorProfile;
begin
  // AMcpSupport applies only to Codex/Copilot/Gemini; the Claude driver is
  // statically msSupported and ignores it (C-5).
  if AKind = ekCodex then
    Result := TCodexExecutorProfile.Create(AMcpSupport)
  else if AKind = ekCopilot then
    Result := TCopilotExecutorProfile.Create(AMcpSupport)
  else if AKind = ekGemini then
    Result := TGeminiExecutorProfile.Create(AMcpSupport)
  else if AKind = ekOllama then
    // Statically msUnsupported (no MCP loop for local models yet); the probed
    // AMcpSupport does not apply.
    Result := TOllamaExecutorProfile.Create
  else
    Result := TClaudeExecutorProfile.Create;
end;

class function TProviderRegistry.ParseExecutorKind(const AValue: string): TExecutorKind;
begin
  // Delegates to the pure mapping (Aefos.Provider.Kinds) - single source of
  // truth, driver-free, shared with the Lazarus/FPC config core.
  Result := TExecutorKinds.ParseExecutorKind(AValue);
end;

class function TProviderRegistry.ExecutorKindToString(const AKind: TExecutorKind): string;
begin
  Result := TExecutorKinds.ExecutorKindToString(AKind);
end;

class function TProviderRegistry.ExecutorKindDisplayName(const AKind: TExecutorKind): string;
begin
  Result := TExecutorKinds.ExecutorKindDisplayName(AKind);
end;

class function TProviderRegistry.TokenDisplayName(const AToken: string): string;
begin
  Result := TExecutorKinds.TokenDisplayName(AToken);
end;

class function TProviderRegistry.ExecutorGraphNeedsReResolve(const AProfileResolved: Boolean;
  const ACurrentKind, ADesiredKind: TExecutorKind): Boolean;
begin
  Result := (not AProfileResolved) or (ACurrentKind <> ADesiredKind);
end;

class function TProviderRegistry.ShouldReResolveExecutorGraph(const AProfileResolved: Boolean;
  const ACurrentKind, ADesiredKind: TExecutorKind;
  const ALastRoot, ACurrentRoot: string): Boolean;
begin
  Result := ExecutorGraphNeedsReResolve(AProfileResolved, ACurrentKind,
    ADesiredKind) or (ACurrentRoot <> ALastRoot);
end;

end.
