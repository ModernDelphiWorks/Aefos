unit Aefos.OTA.MCP.IssueReport;

{
  ProposeAefosIssue — the agent PROPOSES a bug/suggestion; the human disposes.

  Golden rule (design 2026-06-24): the agent NEVER writes to GitHub. It only calls
  ProposeAefosIssue(title, problem, possibleSolution) describing a symptom. The
  plugin then shows an EDITABLE dialog (the agent's prose pre-filled) with a
  deterministic FACT block the plugin appends itself (IDE / Aefos / OS versions) so
  it cannot be forged by the prose. "Send" opens a PRE-FILLED GitHub new-issue URL
  in the browser — the human reviews and clicks Submit. v1: no backend, no token.

  "Impossible to spam, hard to fool" (not "infallible"): the human gate on the
  editable dialog + the explicit browser Submit removes ~all spam risk.

  Lives in the shared MCP.Tools.OTA BPL so BOTH hosts (Chat + Terminal) register the
  same tool. VCL + OTA (it shows a modal + reads the IDE version); never linked by
  the headless test runner.

  Phase 2 (later, not here): a "Debug mode" toggle in AI Flow gates WHEN the agent
  may propose, and FFeedbackProvider auto-captures the failing tool + repro (last N
  calls) into the FACT. This v1 is just the tool + dialog + URL so the flow can be
  exercised end to end.
}

interface

uses
  Aefos.MCP.Server,
  Aefos.MCP.Types;

// Registers the ProposeAefosIssue tool on AServer (no-op when AServer is nil).
procedure RegisterProposeAefosIssueTool(const AServer: IMCPServer);

implementation

uses
  Winapi.Windows,
  Winapi.ShellAPI,
  System.SysUtils,
  System.Classes,
  System.JSON,
  System.NetEncoding,
  Vcl.Forms,
  Vcl.Controls,
  Vcl.StdCtrls,
  Vcl.ExtCtrls,
  Vcl.Graphics,
  Aefos.OTA.UI.ThemeHelper,
  Aefos.OTA.Options.AIFlow,
  ToolsAPI;

const
  CIssueRepoUrl = 'https://github.com/ModernDelphiWorks/Aefos/issues/new';
  // Fallback only — _PluginVersion reads the module FileVersion first. Kept in
  // sync by scripts/bump-version.ps1 so it never drifts behind a release.
  CPluginVersionFallback = '1.4.0';

// ── deterministic fact (plugin-supplied, not forgeable by the prose) ─────────

function _PluginVersion: string;
var
  LFile: array[0..MAX_PATH] of Char;
  LDummy, LSize: DWORD;
  LBuf: TBytes;
  LValue: Pointer;
  LLen: UINT;
  LFixed: PVSFixedFileInfo;
begin
  Result := CPluginVersionFallback;
  try
    if GetModuleFileName(HInstance, LFile, MAX_PATH) = 0 then
      Exit;
    LSize := GetFileVersionInfoSize(LFile, LDummy);
    if LSize = 0 then
      Exit;
    SetLength(LBuf, LSize);
    if not GetFileVersionInfo(LFile, 0, LSize, Pointer(LBuf)) then
      Exit;
    if VerQueryValue(Pointer(LBuf), '\', LValue, LLen)
      and (LLen >= SizeOf(TVSFixedFileInfo)) then
    begin
      LFixed := PVSFixedFileInfo(LValue);
      Result := Format('%d.%d.%d', [
        HiWord(LFixed.dwFileVersionMS), LoWord(LFixed.dwFileVersionMS),
        HiWord(LFixed.dwFileVersionLS)]);
    end;
  except
    Result := CPluginVersionFallback;
  end;
end;

function _IdeVersion: string;
var
  LServices: IOTAServices;
  LKey: string;
  LPos: Integer;
begin
  Result := 'RAD Studio';
  try
    if Supports(BorlandIDEServices, IOTAServices, LServices) then
    begin
      LKey := LServices.GetBaseRegistryKey; // ...\Embarcadero\BDS\23.0
      LPos := LastDelimiter('\', LKey);
      if LPos > 0 then
        Result := 'BDS ' + Copy(LKey, LPos + 1, MaxInt);
    end;
  except
  end;
end;

// The fact block, plain markdown, appended to the body and shown read-only.
function _BuildFact: string;
begin
  Result :=
    '- Aefos: ' + _PluginVersion + sLineBreak +
    '- IDE: ' + _IdeVersion + sLineBreak +
    '- OS: ' + TOSVersion.ToString;
end;

// ── editable dialog (built in code; no .dfm) ─────────────────────────────────

function _ShowIssueDialog(const ATitle, AProblem, ASolution, AFact: string;
  out AEditedTitle, AEditedBody: string): Boolean;
var
  LForm: TForm;
  LEdtTitle: TEdit;
  LMemoBody, LMemoFact: TMemo;
  LBtnSend, LBtnCancel: TButton;

  function _Lbl(const ACaption: string; ATop: Integer): TLabel;
  begin
    Result := TLabel.Create(LForm);
    Result.Parent := LForm;
    Result.SetBounds(16, ATop, 560, 16);
    Result.Caption := ACaption;
  end;

begin
  AEditedTitle := '';
  AEditedBody := '';
  Result := False;
  LForm := TForm.CreateNew(nil);
  try
    LForm.Caption := 'Aefos AI - Report an issue';
    LForm.BorderStyle := bsDialog;
    LForm.Position := poScreenCenter;
    LForm.ClientWidth := 600;
    LForm.ClientHeight := 520;

    _Lbl('Title', 12);
    LEdtTitle := TEdit.Create(LForm);
    LEdtTitle.Parent := LForm;
    LEdtTitle.SetBounds(16, 32, 568, 24);
    LEdtTitle.Text := ATitle;

    _Lbl('Description (editable) - problem and possible solution', 68);
    LMemoBody := TMemo.Create(LForm);
    LMemoBody.Parent := LForm;
    LMemoBody.SetBounds(16, 88, 568, 240);
    LMemoBody.ScrollBars := ssVertical;
    LMemoBody.WordWrap := True;
    LMemoBody.Lines.Add('## Problem');
    LMemoBody.Lines.Add(AProblem);
    LMemoBody.Lines.Add('');
    LMemoBody.Lines.Add('## Possible solution');
    LMemoBody.Lines.Add(ASolution);

    _Lbl('Attached automatically by Aefos (not editable)', 340);
    LMemoFact := TMemo.Create(LForm);
    LMemoFact.Parent := LForm;
    LMemoFact.SetBounds(16, 360, 568, 88);
    LMemoFact.ReadOnly := True;
    LMemoFact.Text := AFact;

    LBtnSend := TButton.Create(LForm);
    LBtnSend.Parent := LForm;
    LBtnSend.SetBounds(396, 468, 90, 32);
    LBtnSend.Caption := 'Send';
    LBtnSend.Default := True;
    LBtnSend.ModalResult := mrOk;

    LBtnCancel := TButton.Create(LForm);
    LBtnCancel.Parent := LForm;
    LBtnCancel.SetBounds(494, 468, 90, 32);
    LBtnCancel.Caption := 'Cancel';
    LBtnCancel.Cancel := True;
    LBtnCancel.ModalResult := mrCancel;

    // Match the active IDE theme (dark/light) recursively across the form and all
    // child controls — the shared helper the other Aefos dialogs use.
    TThemeHelper.ApplyPremiumTheme(LForm);

    if LForm.ShowModal = mrOk then
    begin
      AEditedTitle := Trim(LEdtTitle.Text);
      // Prose (user-editable) + a separator + the deterministic fact block.
      AEditedBody := LMemoBody.Lines.Text + sLineBreak + sLineBreak +
        '---' + sLineBreak +
        '### Environment (attached by Aefos)' + sLineBreak +
        AFact;
      Result := AEditedTitle <> '';
    end;
  finally
    LForm.Free;
  end;
end;

// Opens the pre-filled GitHub new-issue page in the default browser.
procedure _OpenGitHubIssue(const ATitle, ABody: string);
var
  LUrl: string;
begin
  LUrl := CIssueRepoUrl +
    '?title=' + TNetEncoding.URL.Encode(ATitle) +
    '&body=' + TNetEncoding.URL.Encode(ABody);
  ShellExecute(0, 'open', PChar(LUrl), nil, nil, SW_SHOWNORMAL);
end;

// ── tool registration ────────────────────────────────────────────────────────

function _Str(const AObj: TJSONObject; const AName: string): string;
var
  LVal: TJSONValue;
begin
  Result := '';
  if AObj = nil then
    Exit;
  LVal := AObj.GetValue(AName);
  if LVal is TJSONString then
    Result := TJSONString(LVal).Value;
end;

procedure RegisterProposeAefosIssueTool(const AServer: IMCPServer);
var
  LDesc: TMCPToolDescriptor;
  LProps: TJSONObject;
begin
  if not Assigned(AServer) then
    Exit;
  LDesc := Default(TMCPToolDescriptor);
  LDesc.Name := 'ProposeAefosIssue';
  LDesc.Title := 'Propose an Aefos issue';
  LDesc.Description :=
    'PROPOSE an Aefos bug or suggestion to the user (you NEVER file it yourself). ' +
    'Call this ONLY when you hit friction that looks like a genuine Aefos defect AND ' +
    'is not your own fault (wrong view / bad params / a RULE #1 rejection -> fix and ' +
    'resend, do NOT report). Describe the problem and a possible solution; Aefos pops ' +
    'an EDITABLE window (your text pre-filled) with the IDE/Aefos/OS versions attached, ' +
    'and the user decides whether to open a pre-filled GitHub issue. Params: title ' +
    '(short), problem (what went wrong), possibleSolution (your suggested fix). ' +
    'Returns {sent, url}: sent=false means the user cancelled OR issue reporting ' +
    'is turned off in Tools > Options > Aefos > AI Flow (do not retry in that case).';
  LProps := TJSONObject.Create;
  LProps.AddPair('title', TJSONObject.Create
    .AddPair('type', 'string')
    .AddPair('description', 'Short issue title.'));
  LProps.AddPair('problem', TJSONObject.Create
    .AddPair('type', 'string')
    .AddPair('description', 'What went wrong (the symptom).'));
  LProps.AddPair('possibleSolution', TJSONObject.Create
    .AddPair('type', 'string')
    .AddPair('description', 'Your suggested fix or direction.'));
  LDesc.InputSchema := TJSONObject.Create;
  LDesc.InputSchema.AddPair('type', 'object');
  LDesc.InputSchema.AddPair('properties', LProps);
  LDesc.InputSchema.AddPair('required', TJSONArray.Create
    .Add('title').Add('problem'));
  LDesc.OutputSchema := TJSONObject.Create;
  LDesc.OutputSchema.AddPair('type', 'object');
  LDesc.Handler :=
    function(const AParams: TJSONObject;
      const AContext: IMCPToolContext): TMCPToolResult
    var
      LTitle, LProblem, LSolution, LFact, LEditedTitle, LEditedBody, LUrl: string;
      LSent: Boolean;
      LObj: TJSONObject;
    begin
      Result := Default(TMCPToolResult);
      // Gated by Tools > Options > Aefos > AI Flow > "Issue reporting". When off
      // (default) the dialog never opens and we return a "disabled" result — so a
      // misbehaving / hallucinating agent can never spam the dialog.
      if not TAIFlowOptions.IssueReportingEnabled then
      begin
        LObj := TJSONObject.Create;
        try
          LObj.AddPair('sent', TJSONBool.Create(False));
          LObj.AddPair('message',
            'Issue reporting is disabled. The user can enable it in ' +
            'Tools > Options > Aefos > AI Flow > Issue reporting.');
          Result.Content := LObj.ToJSON;
        finally
          LObj.Free;
        end;
        Exit;
      end;
      LTitle := _Str(AParams, 'title');
      LProblem := _Str(AParams, 'problem');
      LSolution := _Str(AParams, 'possibleSolution');
      LSent := False;
      LUrl := '';
      // UI + browser launch belong on the IDE main thread.
      if Assigned(AContext) then
        AContext.MarshalToMainThread(
          procedure
          begin
            LFact := _BuildFact;
            if _ShowIssueDialog(LTitle, LProblem, LSolution, LFact,
                 LEditedTitle, LEditedBody) then
            begin
              LUrl := CIssueRepoUrl +
                '?title=' + TNetEncoding.URL.Encode(LEditedTitle) +
                '&body=' + TNetEncoding.URL.Encode(LEditedBody);
              _OpenGitHubIssue(LEditedTitle, LEditedBody);
              LSent := True;
            end;
          end);
      LObj := TJSONObject.Create;
      try
        LObj.AddPair('sent', TJSONBool.Create(LSent));
        if LSent then
          LObj.AddPair('url', LUrl)
        else
          LObj.AddPair('message', 'User cancelled - no issue was opened.');
        Result.Content := LObj.ToJSON;
      finally
        LObj.Free;
      end;
    end;
  AServer.RegisterTool(LDesc);
end;

end.
