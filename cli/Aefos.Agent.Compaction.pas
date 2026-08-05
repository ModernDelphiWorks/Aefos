unit Aefos.Agent.Compaction;
{$IFDEF FPC}{$mode delphiunicode}{$ENDIF}

(*
  Aefos Agent CLI - context compaction (pure, RTL-only, headless-testable).

  Harness contract P0-3: when the message
  history nears the model's context window, the OLD turns are replaced by a
  compact summary and the recent tail is kept verbatim - the turn continues
  seamlessly instead of silently truncating (which is what Ollama itself does
  when the window overflows). Local models have small windows, so a multi-hop
  tool turn or a --resume thread dies without this.

  All decisions are pure functions over the message array; the loop performs
  the actual summary request (it owns the transport).
*)

interface

uses
  {$IFDEF FPC}
  SysUtils,
  {$ELSE}
  System.SysUtils,
  {$ENDIF}
  Aefos.Provider.Ollama.Core;

const
  // Compact when the estimated tokens reach this percentage of the window.
  CCompactionThresholdPct = 70;
  // Recent messages kept verbatim (the model's working set).
  CDefaultKeepTail = 8;
  // Fewer head messages than this aren't worth a summary round-trip.
  CMinHeadToCompact = 4;

type
  { Static, sealed namespace for the context-compaction decisions (all pure).
    Never instantiated; the class IS the namespace. }
  TAgentCompaction = class sealed
  public
    // Estimated token count of the whole history: chars div 4 across content,
    // tool payloads and roles. Crude but stable - the threshold has slack.
    class function ApproxMessagesTokens(
      const AMessages: TArray<TOllamaMessage>): Integer; static;

    // True when ATokens has crossed the compaction threshold for ACtxWindow.
    // ACtxWindow <= 0 disables compaction.
    class function IsNeeded(const ATokens, ACtxWindow: Integer): Boolean; static;

    // Splits the history for compaction:
    //   ALeading  - the LEADING run of system messages (system prompt, catalog
    //               preamble): never summarized, never dropped.
    //   AHead     - the old middle to be summarized.
    //   ATail     - the last AKeepTail messages, kept verbatim. The tail is
    //               extended backwards while it starts with a 'tool' result so a
    //               tool message is never orphaned from its assistant tool_calls.
    // False when there is nothing worth compacting (small head).
    class function Split(const AMessages: TArray<TOllamaMessage>;
      const AKeepTail: Integer; out ALeading, AHead,
      ATail: TArray<TOllamaMessage>): Boolean; static;

    // The one-shot summary request: the head rendered as a transcript plus a
    // terse instruction. Sent WITHOUT tools; the reply becomes the summary.
    class function BuildRequestMessages(
      const AHead: TArray<TOllamaMessage>): TArray<TOllamaMessage>; static;

    // The system message that replaces the summarized head.
    class function MakeSummaryMessage(const ASummary: string): TOllamaMessage; static;
    class function SummaryMessageMarker: string; static;
  end;

implementation

class function TAgentCompaction.ApproxMessagesTokens(
  const AMessages: TArray<TOllamaMessage>): Integer;
var
  LIndex, LChars: Integer;
begin
  LChars := 0;
  for LIndex := 0 to High(AMessages) do
  begin
    Inc(LChars, Length(AMessages[LIndex].Content));
    Inc(LChars, Length(AMessages[LIndex].ToolCallsJson));
    Inc(LChars, Length(AMessages[LIndex].ToolName));
    Inc(LChars, 8); // role + framing overhead
  end;
  Result := LChars div 4;
end;

class function TAgentCompaction.IsNeeded(
  const ATokens, ACtxWindow: Integer): Boolean;
begin
  Result := (ACtxWindow > 0) and
    (ATokens * 100 >= ACtxWindow * CCompactionThresholdPct);
end;

class function TAgentCompaction.Split(const AMessages: TArray<TOllamaMessage>;
  const AKeepTail: Integer; out ALeading, AHead,
  ATail: TArray<TOllamaMessage>): Boolean;
var
  LLeadCount, LTailStart, LKeep, LIndex: Integer;
begin
  Result := False;
  ALeading := nil;
  AHead := nil;
  ATail := nil;
  // Leading run of system messages is untouchable.
  LLeadCount := 0;
  while (LLeadCount <= High(AMessages)) and
    SameText(AMessages[LLeadCount].Role, 'system') do
    Inc(LLeadCount);
  LKeep := AKeepTail;
  if LKeep <= 0 then
    LKeep := CDefaultKeepTail;
  LTailStart := Length(AMessages) - LKeep;
  if LTailStart < LLeadCount then
    LTailStart := LLeadCount;
  // Never let the tail OPEN on a tool result: a role:"tool" message without
  // its preceding assistant tool_calls confuses (or errors) the endpoint.
  while (LTailStart > LLeadCount) and
    SameText(AMessages[LTailStart].Role, 'tool') do
    Dec(LTailStart);
  if LTailStart - LLeadCount < CMinHeadToCompact then
    Exit; // head too small - not worth a summary round-trip
  SetLength(ALeading, LLeadCount);
  for LIndex := 0 to LLeadCount - 1 do
    ALeading[LIndex] := AMessages[LIndex];
  SetLength(AHead, LTailStart - LLeadCount);
  for LIndex := LLeadCount to LTailStart - 1 do
    AHead[LIndex - LLeadCount] := AMessages[LIndex];
  SetLength(ATail, Length(AMessages) - LTailStart);
  for LIndex := LTailStart to High(AMessages) do
    ATail[LIndex - LTailStart] := AMessages[LIndex];
  Result := True;
end;

class function TAgentCompaction.BuildRequestMessages(
  const AHead: TArray<TOllamaMessage>): TArray<TOllamaMessage>;
var
  LSb: TStringBuilder;
  LIndex: Integer;
  LRole: string;
begin
  LSb := TStringBuilder.Create;
  try
    LSb.Append('Summarize the following working transcript into a terse, ');
    LSb.Append('factual brief a coding agent can resume from. Keep: the ');
    LSb.Append('task/goal, decisions made, tools called with their outcomes, ');
    LSb.Append('files or components touched, current state, and what remains ');
    LSb.Append('to be done. No praise, no prose - dense bullet points.');
    LSb.Append(#10#10);
    for LIndex := 0 to High(AHead) do
    begin
      LRole := AHead[LIndex].Role;
      LSb.Append('[');
      LSb.Append(LRole);
      if SameText(LRole, 'tool') and (AHead[LIndex].ToolName <> '') then
      begin
        LSb.Append(':');
        LSb.Append(AHead[LIndex].ToolName);
      end;
      LSb.Append('] ');
      if AHead[LIndex].Content <> '' then
        LSb.Append(AHead[LIndex].Content);
      if AHead[LIndex].ToolCallsJson <> '' then
      begin
        LSb.Append(' calls=');
        LSb.Append(AHead[LIndex].ToolCallsJson);
      end;
      LSb.Append(#10);
    end;
    Result := [TOllamaMessage.New('user', LSb.ToString)];
  finally
    LSb.Free;
  end;
end;

class function TAgentCompaction.SummaryMessageMarker: string;
begin
  Result := '[summary of earlier work]';
end;

class function TAgentCompaction.MakeSummaryMessage(
  const ASummary: string): TOllamaMessage;
begin
  Result := TOllamaMessage.New('system',
    SummaryMessageMarker + ' The older part of this conversation was ' +
    'compacted. Its summary:' + #10 + ASummary);
end;

end.
