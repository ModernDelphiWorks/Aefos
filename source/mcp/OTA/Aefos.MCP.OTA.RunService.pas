unit Aefos.MCP.OTA.RunService;

{
  Run / stop / keystroke IDE-process control, extracted from the
  TMCPWorkspaceFacade god-object as a focused service of the SOLID split
  (audit S6 / facade split).

  Owns RunProject, RunWithoutDebugger, StopProject and SendKeystroke, plus the
  run-specific helpers _TerminalProcessIsRunning and _TerminalResolveIDEAction.
  The only shared dependency is the trivial TFacadeShared.TryProject getter (RunWithoutDebugger's
  output-EXE fallback), drawn from Aefos.MCP.OTA.FacadeShared.

  Bodies moved VERBATIM from the facade (only the class qualifier changes), so
  behaviour is identical. The facade keeps its frozen IMCPWorkspaceFacade methods
  and delegates each to a refcounted FRun service field.
}

interface

type
  IMCPRunService = interface
    ['{1F3D9C44-5A8E-46B2-8D71-9C2E4B6A7F31}']
    function SendKeystroke(const AKeys: string): Boolean;
    function RunProject: Boolean;
    function RunWithoutDebugger: Boolean;
    function StopProject: Boolean;
  end;

// Factory — the facade calls this once in its constructor.
function NewMCPRunService: IMCPRunService;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.Actions,
  Vcl.ActnList,
  Vcl.Forms,
  Winapi.Windows,
  ToolsAPI,
  Aefos.MCP.OTA.FacadeShared;

type
  TMCPRunService = class(TInterfacedObject, IMCPRunService)
  public
    function SendKeystroke(const AKeys: string): Boolean;
    function RunProject: Boolean;
    function RunWithoutDebugger: Boolean;
    function StopProject: Boolean;
  end;

// Returns True when a debugged process is already running under the IDE.
// Guards RunProject / RunWithoutDebugger against double-launch (BR6 dedup).
function _TerminalProcessIsRunning: Boolean;
var
  LDS: IOTADebuggerServices;
begin
  Result := False;
  try
    if not Assigned(BorlandIDEServices) then Exit;
    if not Supports(BorlandIDEServices, IOTADebuggerServices, LDS) then Exit;
    Result := LDS.ProcessCount > 0;
  except
    Result := False;
  end;
end;

// Looks up an IDE TBasicAction by trying each candidate name in order on the
// live INTAServices.ActionList. Returns nil when none of the alternates is
// registered. Multiple candidates because action identifiers drifted across
// RAD Studio releases (ADR-138 fallback pattern).
function _TerminalResolveIDEAction(
  const AAlternates: array of string): TBasicAction;
var
  LNTA: INTAServices;
  LList: TCustomActionList;
  LFor, LIdx: Integer;
  LAction: TContainedAction;
begin
  Result := nil;
  try
    if not Assigned(BorlandIDEServices) then Exit;
    if not Supports(BorlandIDEServices, INTAServices, LNTA) then Exit;
    LList := LNTA.ActionList;
    if not Assigned(LList) then Exit;
    for LFor := Low(AAlternates) to High(AAlternates) do
      for LIdx := 0 to LList.ActionCount - 1 do
      begin
        LAction := LList.Actions[LIdx];
        if Assigned(LAction) and SameText(LAction.Name, AAlternates[LFor]) then
          Exit(LAction);
      end;
  except
    Result := nil;
  end;
end;

function TMCPRunService.SendKeystroke(
  const AKeys: string): Boolean;
var
  LParts: TArray<string>;
  LPart, LKey: string;
  LModCtrl, LModAlt, LModShift: Boolean;
  LMainKey: Word;
begin
  // Parse key string on caller thread — no OTA needed, pure computation.
  LModCtrl  := False;
  LModAlt   := False;
  LModShift := False;
  LMainKey  := 0;
  LParts := AKeys.Split(['+']);
  for LPart in LParts do
  begin
    LKey := LPart.Trim.ToUpper;
    if      LKey = 'CTRL'     then LModCtrl  := True
    else if LKey = 'ALT'      then LModAlt   := True
    else if LKey = 'SHIFT'    then LModShift := True
    else if LKey = 'F1'       then LMainKey  := VK_F1
    else if LKey = 'F2'       then LMainKey  := VK_F2
    else if LKey = 'F3'       then LMainKey  := VK_F3
    else if LKey = 'F4'       then LMainKey  := VK_F4
    else if LKey = 'F5'       then LMainKey  := VK_F5
    else if LKey = 'F6'       then LMainKey  := VK_F6
    else if LKey = 'F7'       then LMainKey  := VK_F7
    else if LKey = 'F8'       then LMainKey  := VK_F8
    else if LKey = 'F9'       then LMainKey  := VK_F9
    else if LKey = 'F10'      then LMainKey  := VK_F10
    else if LKey = 'F11'      then LMainKey  := VK_F11
    else if LKey = 'F12'      then LMainKey  := VK_F12
    else if LKey = 'ESC'      then LMainKey  := VK_ESCAPE
    else if LKey = 'ESCAPE'   then LMainKey  := VK_ESCAPE
    else if LKey = 'RETURN'   then LMainKey  := VK_RETURN
    else if LKey = 'ENTER'    then LMainKey  := VK_RETURN
    else if LKey = 'TAB'      then LMainKey  := VK_TAB
    else if LKey = 'DELETE'   then LMainKey  := VK_DELETE
    else if LKey = 'INSERT'   then LMainKey  := VK_INSERT
    else if LKey = 'HOME'     then LMainKey  := VK_HOME
    else if LKey = 'END'      then LMainKey  := VK_END
    else if LKey = 'PAGEUP'   then LMainKey  := VK_PRIOR
    else if LKey = 'PAGEDOWN' then LMainKey  := VK_NEXT
    else if LKey = 'SPACE'    then LMainKey  := VK_SPACE
    else if LKey = 'BACK'     then LMainKey  := VK_BACK
    else if Length(LKey) = 1  then LMainKey  := Ord(LKey[1]);
  end;
  if LMainKey = 0 then
    Exit(False);

  // Queue the actual SendInput to run AFTER the message pump resumes.
  // Calling SendInput inside TThread.Synchronize would inject into a suspended
  // pump; TThread.Queue schedules injection for the next pump cycle.
  TThread.Queue(nil, procedure
  var
    LInputs: array[0..7] of TInput;
    LCount: Integer;
    LIdeWnd: HWND;

    procedure Push(AVk: Word; AUp: Boolean);
    begin
      FillChar(LInputs[LCount], SizeOf(TInput), 0);
      LInputs[LCount].Itype := INPUT_KEYBOARD;
      LInputs[LCount].ki.wVk := AVk;
      if AUp then
        LInputs[LCount].ki.dwFlags := KEYEVENTF_KEYUP;
      Inc(LCount);
    end;

  begin
    LCount  := 0;
    LIdeWnd := Application.MainForm.Handle;
    if GetForegroundWindow <> LIdeWnd then
      SetForegroundWindow(LIdeWnd);
    if LModAlt   then Push(VK_MENU,    False);
    if LModCtrl  then Push(VK_CONTROL, False);
    if LModShift then Push(VK_SHIFT,   False);
    Push(LMainKey, False);
    Push(LMainKey, True);
    if LModShift then Push(VK_SHIFT,   True);
    if LModCtrl  then Push(VK_CONTROL, True);
    if LModAlt   then Push(VK_MENU,    True);
    SendInput(LCount, LInputs[0], SizeOf(TInput));
  end);
  Result := True;
end;

// Run the active project with the IDE debugger (F9). Fires the IDE action
// (multi-candidate for cross-release compatibility), then CONFIRMS the launch:
// firing the action only DISPATCHES the run — a missing main form (a .dpr with
// no Application.CreateForm), a compile error or a modal can abort the start, so
// the action returning is not proof the app is up. We therefore bounded-poll
// IOTADebuggerServices.ProcessCount (the same signal StopProject relies on) for
// up to ~1.5s, pumping the IDE message queue so the debugger's process-create
// notification is actually delivered. Result is True only when a debugged
// process is confirmed running (or one was already running — dedup); False when
// the action is absent or nothing came up within the budget. The poll is
// strictly bounded so it never blocks the IDE.
function TMCPRunService.RunProject: Boolean;
var
  LOk: Boolean;
begin
  LOk := False;
  try
    TThread.Synchronize(nil, procedure
    var
      LAction: TBasicAction;
      LWait: Integer;
    begin
      if _TerminalProcessIsRunning then
      begin
        LOk := True; // already up — honest "running", no double-launch (BR6)
        Exit;
      end;
      LAction := _TerminalResolveIDEAction(
        ['RunRunCommand', 'ProjectRunCommand', 'DebuggerRunCommand',
         'RunCommand', 'RunProjectCommand']);
      if not Assigned(LAction) then Exit;
      LAction.Execute;
      // Bounded launch confirmation (~1.5s). The debugger spawns the process
      // asynchronously and bumps ProcessCount on the main message loop, so we
      // must pump (ProcessMessages) between checks for the count to update.
      LWait := 15;
      while (LWait > 0) and (not _TerminalProcessIsRunning) do
      begin
        Application.ProcessMessages;
        Sleep(100);
        Dec(LWait);
      end;
      LOk := _TerminalProcessIsRunning;
    end);
  except
    LOk := False;
  end;
  Result := LOk;
end;

// Run the active project without the debugger (Ctrl+Shift+F9). Tries the IDE
// action first; falls back to locating the output EXE and launching via
// CreateProcess when no matching action is found in the live action list.
function TMCPRunService.RunWithoutDebugger: Boolean;
var
  LOk: Boolean;
begin
  LOk := False;
  try
    TThread.Synchronize(nil, procedure
    var
      LAction: TBasicAction;
      LProject: IOTAProject;
      LDir, LExePath: string;
      LSI: TStartupInfo;
      LPI: TProcessInformation;
    begin
      if _TerminalProcessIsRunning then Exit;
      LAction := _TerminalResolveIDEAction(
        ['RunWithoutDebuggerCommand', 'DebuggerRunWithoutDebuggingCommand',
         'RunWithoutDebugger', 'ProjectRunWithoutDebugCommand']);
      if Assigned(LAction) then
      begin
        LAction.Execute;
        LOk := True;
        Exit;
      end;
      // Fallback: locate output EXE and launch directly via CreateProcess.
      if not TFacadeShared.TryProject(LProject) then Exit;
      LDir := TPath.GetDirectoryName(LProject.FileName);
      LExePath := TPath.Combine(LDir,
        'Win32\Debug\' +
        TPath.GetFileNameWithoutExtension(LProject.FileName) + '.exe');
      if not TFile.Exists(LExePath) then
        LExePath := TPath.Combine(LDir,
          'Win32\Release\' +
          TPath.GetFileNameWithoutExtension(LProject.FileName) + '.exe');
      if not TFile.Exists(LExePath) then Exit;
      FillChar(LSI, SizeOf(LSI), 0);
      LSI.cb := SizeOf(LSI);
      LSI.dwFlags := STARTF_USESHOWWINDOW;
      LSI.wShowWindow := SW_SHOW;
      if CreateProcess(nil, PChar('"' + LExePath + '"'), nil, nil, False,
          0, nil, PChar(LDir), LSI, LPI) then
      begin
        CloseHandle(LPI.hProcess);
        CloseHandle(LPI.hThread);
        LOk := True;
      end;
    end);
  except
    LOk := False;
  end;
  Result := LOk;
end;

// Terminate any active debugged process via IOTADebuggerServices (ESP-091, S2 /
// ADR-091-07 / BR11 — the no-orphan guarantee). Idempotent: when no process is
// running it is a valid no-op (False, nothing to stop); when one or more debug
// sessions are active it terminates each and reports success. The observable
// "process stopped" side-effect is IOTADebuggerServices.ProcessCount dropping to
// zero. This is the campaign's standing guard that no launched process is left
// orphaned.
function TMCPRunService.StopProject: Boolean;
var
  LOk: Boolean;
begin
  LOk := False;
  try
    TThread.Synchronize(nil, procedure
    var
      LDS: IOTADebuggerServices;
      LFor: Integer;
      LProcess: IOTAProcess;
    begin
      if not Supports(BorlandIDEServices, IOTADebuggerServices, LDS) then Exit;
      if LDS.ProcessCount = 0 then
      begin
        // BUG-3 fix: idempotent SUCCESS — "nothing running" is the desired end
        // state, so report applied:true (matches the tool's documented contract).
        // The old Exit left LOk=False, so a stop that had nothing to do — or a
        // second stop after the process already ended — lied with applied:false.
        LOk := True;
        Exit;
      end;
      for LFor := LDS.ProcessCount - 1 downto 0 do
      begin
        LProcess := LDS.Processes[LFor];
        if Assigned(LProcess) then
          LProcess.Terminate;
      end;
      LOk := True; // terminate issued to every active debug session
    end);
  except
    LOk := False;
  end;
  Result := LOk;
end;

function NewMCPRunService: IMCPRunService;
begin
  Result := TMCPRunService.Create;
end;

end.
