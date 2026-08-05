unit Aefos.OTA.Terminal.Core.TerminalHost;

interface

{$I ..\Aefos.OTA.Terminal.inc}

uses
  System.Classes, System.SysUtils, Winapi.Windows, Aefos.OTA.Terminal.Core.VTermBuffer,
  Aefos.OTA.Terminal.Core.ConPTY, Aefos.OTA.Terminal.Core.Session, Aefos.OTA.Terminal.Core.ActionRunner,
  Aefos.OTA.Terminal.Core.CommandHistory, Aefos.OTA.Terminal.Core.CommandHistoryStore;

type
  /// <summary>
  /// Background thread that reads raw output from the shell process pipe and
  /// feeds it as raw bytes into the libvterm-backed screen model.
  /// </summary>
  TTerminalReaderThread = class(TThread)
  private
    FReadPipe: THandle;
    FBuffer: TVTermBuffer;
    FLBuffer: array[0..4095] of AnsiChar;
    FLBytesRead: Cardinal;
    FOnActivity: TNotifyEvent;
    procedure _DoNotifyActivity;
  protected
    procedure Execute; override;
  public
    constructor Create(AReadPipe: THandle; ABuffer: TVTermBuffer);
    property OnActivity: TNotifyEvent read FOnActivity write FOnActivity;
  end;

  /// <summary>
  /// Manages the lifecycle of a terminal process (e.g. cmd.exe) and its I/O
  /// redirection, feeding output into a TVTermBuffer. Implements
  /// ITerminalInput (non-refcounted) so TActionRunner can inject script lines
  /// into the active session without depending on the I/O thread.
  /// </summary>
  TTerminalHost = class(TObject, IInterface, ITerminalInput)
  private
    FBuffer: TVTermBuffer;
    FProcessInfo: TProcessInformation;
    FReadPipe: THandle;
    FWritePipe: THandle;
    FHPCON: HPCON;
    FPtyIn: THandle;
    FPtyOut: THandle;
    FReaderThread: TTerminalReaderThread;
    FIsRunning: Boolean;
    FActiveProfileName: string;
    FLastDir: string;
    FOnActivity: TNotifyEvent;
    // ESP-078: command-history capture. The tap reconstructs submitted command
    // lines from the input funnel (side-effect, BR3); completed commands land in
    // the bounded ring and are persisted via the store.
    FCommandTap: TCommandLineTap;
    FCommandRing: TCommandHistoryRing;
    FCommandStore: TCommandHistoryStore;
    procedure _Cleanup;
    procedure _StartConPTY(const ACommand, AStartDir: string);
    procedure _StartPipes(const ACommand, AStartDir: string);
    procedure _SetOnActivity(const AValue: TNotifyEvent);
    procedure _HandleCommandLine(const ACommand: string);
  protected
    { IInterface — non-refcounted: the host owns its own lifetime. }
    function QueryInterface(const IID: TGUID; out Obj): HResult; stdcall;
    function _AddRef: Integer; stdcall;
    function _Release: Integer; stdcall;
    /// <summary>Writes AText into the terminal input stream (ITerminalInput).</summary>
    procedure SendInput(const AText: string);
  public
    /// <summary>True when the shell process is running, the input pipe is
    /// open, and the process handle still signals running. Used by PasteText
    /// (CP-7/CP-8 guard) and exposed publicly so tests can assert the seam.
    /// Also satisfies ITerminalInput.</summary>
    function IsActive: Boolean;
    constructor Create(ABuffer: TVTermBuffer);
    destructor Destroy; override;

    /// <summary>Spawns the shell process and starts the reader thread.</summary>
    procedure Start(const AExecutable: string; const AArguments: string = '';
      const AStartDir: string = '');
    /// <summary>Terminates the shell process and cleans up resources.</summary>
    procedure Stop;
    /// <summary>Sends text (commands or VT input) to the terminal input stream.</summary>
    procedure WriteText(const AText: string);
    /// <summary>
    /// Pastes clipboard text into the terminal. When the foreground program
    /// has DEC private mode `?2004` enabled, the payload is wrapped in
    /// `ESC[200~ … ESC[201~`; otherwise CRLF and bare LF are normalized to
    /// CR. Silent no-op when the host is inactive or the input is empty.
    /// </summary>
    procedure PasteText(const AText: string);
    /// <summary>Resizes the pseudoconsole to the new column/row count.</summary>
    procedure Resize(const ACols, ARows: Integer);
    /// <summary>Commands the shell to navigate to the specified path.</summary>
    procedure NavigateTo(const APath: string);
    /// <summary>Saves the current session state with a versioned payload.</summary>
    procedure SaveSession;
    /// <summary>
    /// Restores the previous session into the buffer. Returns True if a
    /// compatible session was restored.
    /// </summary>
    function RestoreSession(var AProfileName, AStartDir: string): Boolean;
    /// <summary>
    /// Up to <c>ACount</c> recently submitted commands, newest-first (ESP-078).
    /// Reconstructed best-effort from the input funnel; edited / history-recalled
    /// / tab-completed lines may not be captured verbatim (ADR-078-01 / R1).
    /// </summary>
    function RecentCommands(const ACount: Integer): TArray<string>;

    /// <summary>
    /// Pure transform that wraps or normalizes a paste payload per
    /// ADR-026-01 (as corrected by ADR-028-01) and ADR-026-02. Bracketed mode
    /// adds `ESC[200~ … ESC[201~` and passes the body unchanged; raw mode
    /// collapses every CRLF and bare LF to a single CR so each line submits
    /// as one Enter. Empty input yields empty output.
    /// </summary>
    class function PreparePastePayload(const AText: string;
      const ABracketed: Boolean): string; static;

    property IsRunning: Boolean read FIsRunning;
    property ActiveProfileName: string read FActiveProfileName write FActiveProfileName;
    property LastDir: string read FLastDir write FLastDir;
    /// <summary>
    ///   Fires on the main thread (via Synchronize in the reader thread) each
    ///   time the shell process delivers output to the buffer. Callers may
    ///   safely access VCL controls directly. Sender = the TTerminalHost
    ///   instance. ESP-059 / ADR-059-01.
    /// </summary>
    property OnActivity: TNotifyEvent read FOnActivity write _SetOnActivity;
  end;

implementation

const
  BRACKETED_PASTE_INTRO = #27'[200~';
  BRACKETED_PASTE_OUTRO = #27'[201~';

class function TTerminalHost.PreparePastePayload(const AText: string;
  const ABracketed: Boolean): string;
var
  LBuilder: TStringBuilder;
  LIndex, LLen: Integer;
  LChar: Char;
begin
  if AText = '' then
    Exit('');

  if ABracketed then
    Exit(BRACKETED_PASTE_INTRO + AText + BRACKETED_PASTE_OUTRO);

  LBuilder := TStringBuilder.Create;
  try
    LLen := Length(AText);
    LIndex := 1;
    while LIndex <= LLen do
    begin
      LChar := AText[LIndex];
      if LChar = #13 then
      begin
        LBuilder.Append(#13);
        if (LIndex < LLen) and (AText[LIndex + 1] = #10) then
          Inc(LIndex);
      end
      else if LChar = #10 then
        LBuilder.Append(#13)
      else
        LBuilder.Append(LChar);
      Inc(LIndex);
    end;
    Result := LBuilder.ToString;
  finally
    LBuilder.Free;
  end;
end;

{ TTerminalReaderThread }

procedure TTerminalReaderThread._DoNotifyActivity;
begin
  if Assigned(FOnActivity) then FOnActivity(Self);
end;

constructor TTerminalReaderThread.Create(AReadPipe: THandle; ABuffer: TVTermBuffer);
begin
  inherited Create(False);
  FReadPipe := AReadPipe;
  FBuffer := ABuffer;
  FreeOnTerminate := False;
end;

procedure TTerminalReaderThread.Execute;
var
  LBytes: TBytes;
  LOK: Boolean;
begin
  while not Terminated do
  begin
    LOK := ReadFile(FReadPipe, FLBuffer, SizeOf(FLBuffer), FLBytesRead, nil);
    if LOK and (FLBytesRead > 0) then
    begin
      SetLength(LBytes, FLBytesRead);
      Move(FLBuffer[0], LBytes[0], FLBytesRead);
      // TVTermBuffer.FeedBytes drives libvterm, whose callbacks fire UI-facing
      // events (window title, bell, repaint). Marshal it onto the main thread:
      // running it on this background thread touches VCL cross-thread and
      // deadlocks against the painting UI on the buffer lock. Raw UTF-8 bytes
      // go straight to libvterm — it buffers partial multibyte sequences
      // across calls, so a chunk boundary mid-character is handled correctly.
      // Synchronize blocks this thread, so LBytes stays valid for the closure.
      Synchronize(
        procedure
        begin
          FBuffer.FeedBytes(LBytes);
          _DoNotifyActivity; // ESP-059 / ADR-059-01 — fires on main thread via Synchronize
        end);
    end
    else
    begin
      if (GetLastError = ERROR_BROKEN_PIPE) or (GetLastError = ERROR_NO_DATA) then
        Break;
      if not Terminated then
        Sleep(10);
    end;
  end;
end;

{ TTerminalHost }

constructor TTerminalHost.Create(ABuffer: TVTermBuffer);
begin
  inherited Create;
  FBuffer := ABuffer;
  FIsRunning := False;
  FillChar(FProcessInfo, SizeOf(TProcessInformation), 0);

  // ESP-078: own the capture spine. The persisted store is created+loaded in Start,
  // once ActiveProfileName (the terminal TYPE) is known, so each type keeps its OWN
  // history file (command-history\<type>.json). FCommandStore stays nil until then.
  FCommandRing := TCommandHistoryRing.Create;
  FCommandTap := TCommandLineTap.Create;
  FCommandTap.OnCommand := _HandleCommandLine;
end;

destructor TTerminalHost.Destroy;
begin
  SaveSession;
  Stop;
  FCommandStore.Free;
  FCommandTap.Free;
  FCommandRing.Free;
  inherited Destroy;
end;

procedure TTerminalHost._HandleCommandLine(const ACommand: string);
begin
  // A command was reconstructed: retain it and persist the ring (ESP-078 / BR5).
  FCommandRing.Add(ACommand);
  if Assigned(FCommandStore) then
    FCommandStore.Save(FCommandRing);
end;

function TTerminalHost.RecentCommands(const ACount: Integer): TArray<string>;
begin
  Result := FCommandRing.MostRecent(ACount);
end;

procedure TTerminalHost.Start(const AExecutable, AArguments, AStartDir: string);
var
  LCommand: string;
begin
  if FIsRunning then Exit;

  // ESP-078 (per-type history): now that the terminal TYPE is known, open this
  // type's OWN history file and load it. Each type (cmd/pwsh/wsl/git-bash/claude)
  // keeps a separate command-history\<type>.json, so Ctrl+R shows only THIS shell.
  if not Assigned(FCommandStore) then
  begin
    FCommandStore := TCommandHistoryStore.Create(
      TCommandHistoryStore.PathForShell(FActiveProfileName));
    FCommandStore.Load(FCommandRing);
  end;

  LCommand := AExecutable;
  if AArguments <> '' then
    LCommand := LCommand + ' ' + AArguments;

  if TConPTY.Instance.IsAvailable then
    _StartConPTY(LCommand, AStartDir)
  else
    _StartPipes(LCommand, AStartDir);

  FLastDir := AStartDir;
end;

procedure TTerminalHost._StartConPTY(const ACommand, AStartDir: string);
var
  LSize: TCoord;
  LStartupInfo: TStartupInfoEx;
  LAttrListSize: NativeUint;
  LStartDirPtr: PChar;
  LCmdLine: string;
begin
  if AStartDir = '' then
    LStartDirPtr := nil
  else
    LStartDirPtr := PChar(AStartDir);

  if not CreatePipe(FPtyIn, FWritePipe, nil, 0) then RaiseLastOSError;
  if not CreatePipe(FReadPipe, FPtyOut, nil, 0) then RaiseLastOSError;

  try
    LSize.X := FBuffer.Cols;
    LSize.Y := FBuffer.Rows;
    if TConPTY.Instance.CreatePseudoConsole(LSize, FPtyIn, FPtyOut, 0, FHPCON) <> S_OK then
      RaiseLastOSError;

    // CreatePseudoConsole duplicated the PTY-side handles. Release our copies:
    // keeping FPtyOut open would stop the child's output pipe from ever
    // signalling EOF, hanging the reader thread on process exit.
    CloseHandle(FPtyIn);
    FPtyIn := 0;
    CloseHandle(FPtyOut);
    FPtyOut := 0;

    LAttrListSize := 0;
    TConPTY.Instance.InitializeProcThreadAttributeList(nil, 1, 0, LAttrListSize);

    FillChar(LStartupInfo, SizeOf(TStartupInfoEx), 0);
    LStartupInfo.StartupInfo.cb := SizeOf(TStartupInfoEx);
    LStartupInfo.lpAttributeList := AllocMem(LAttrListSize);

    try
      if not TConPTY.Instance.InitializeProcThreadAttributeList(
        LStartupInfo.lpAttributeList, 1, 0, LAttrListSize) then
        RaiseLastOSError;

      // PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE expects the HPCON *value* as
      // lpValue, not a pointer to it. Passing @FHPCON gives the kernel a bogus
      // handle, so the child never attaches to our pseudoconsole — it spawns
      // its own console window and our output pipe stays empty forever.
      if not TConPTY.Instance.UpdateProcThreadAttribute(
        LStartupInfo.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
        Pointer(FHPCON), SizeOf(HPCON), nil, nil) then
        RaiseLastOSError;

      LCmdLine := ACommand;
      UniqueString(LCmdLine);

      // bInheritHandles MUST be False for a ConPTY child: the pseudoconsole
      // connection is established via the attribute list, not handle
      // inheritance. Passing True lets the child inherit the IDE host's
      // handles, corrupting console init and failing cmd.exe with 0xC0000142.
      if not CreateProcess(nil, PChar(LCmdLine), nil, nil, False,
        EXTENDED_STARTUPINFO_PRESENT, nil, LStartDirPtr,
        LStartupInfo.StartupInfo, FProcessInfo) then
        RaiseLastOSError;

      FIsRunning := True;
      FReaderThread := TTerminalReaderThread.Create(FReadPipe, FBuffer);
      FReaderThread.OnActivity := FOnActivity;
    finally
      if LStartupInfo.lpAttributeList <> nil then
      begin
        TConPTY.Instance.DeleteProcThreadAttributeList(LStartupInfo.lpAttributeList);
        FreeMem(LStartupInfo.lpAttributeList);
      end;
    end;
  except
    _Cleanup;
    raise;
  end;
end;

procedure TTerminalHost._StartPipes(const ACommand, AStartDir: string);
var
  LSecurityAttr: TSecurityAttributes;
  LStartDirPtr: PChar;
  LInRead, LInWrite: THandle;
  LChildStdoutWrite: THandle;
  LStartupInfo: TStartupInfo;
  LCmdLine: string;
begin
  if AStartDir = '' then
    LStartDirPtr := nil
  else
    LStartDirPtr := PChar(AStartDir);

  LSecurityAttr.nLength := SizeOf(TSecurityAttributes);
  LSecurityAttr.lpSecurityDescriptor := nil;
  LSecurityAttr.bInheritHandle := True;

  if not CreatePipe(FReadPipe, FWritePipe, @LSecurityAttr, 0) then
    RaiseLastOSError;
  if not CreatePipe(LInRead, LInWrite, @LSecurityAttr, 0) then
    RaiseLastOSError;

  try
    if not SetHandleInformation(FReadPipe, HANDLE_FLAG_INHERIT, 0) then
      RaiseLastOSError;
    if not SetHandleInformation(LInWrite, HANDLE_FLAG_INHERIT, 0) then
      RaiseLastOSError;

    LChildStdoutWrite := FWritePipe;
    FWritePipe := LInWrite;

    FillChar(LStartupInfo, SizeOf(TStartupInfo), 0);
    LStartupInfo.cb := SizeOf(TStartupInfo);
    LStartupInfo.dwFlags := STARTF_USESTDHANDLES or STARTF_USESHOWWINDOW;
    LStartupInfo.hStdInput := LInRead;
    LStartupInfo.hStdOutput := LChildStdoutWrite;
    LStartupInfo.hStdError := LChildStdoutWrite;
    LStartupInfo.wShowWindow := SW_HIDE;

    LCmdLine := ACommand;
    UniqueString(LCmdLine);

    if not CreateProcess(nil, PChar(LCmdLine), nil, nil, True,
      CREATE_NEW_CONSOLE, nil, LStartDirPtr, LStartupInfo, FProcessInfo) then
      RaiseLastOSError;

    CloseHandle(LInRead);
    CloseHandle(LChildStdoutWrite);

    FIsRunning := True;
    FReaderThread := TTerminalReaderThread.Create(FReadPipe, FBuffer);
    FReaderThread.OnActivity := FOnActivity;
  except
    _Cleanup;
    raise;
  end;
end;

procedure TTerminalHost._SetOnActivity(const AValue: TNotifyEvent);
begin
  FOnActivity := AValue;
  if Assigned(FReaderThread) and not FReaderThread.Terminated then
    FReaderThread.OnActivity := AValue;
end;

procedure TTerminalHost.Stop;
begin
  if not FIsRunning then Exit;

  if FProcessInfo.hProcess <> 0 then
  begin
    TerminateProcess(FProcessInfo.hProcess, 0);
    WaitForSingleObject(FProcessInfo.hProcess, 500);
  end;

  // Break the output pipe BEFORE waiting for the reader thread. The reader is
  // blocked in ReadFile, which only returns once every write end of the pipe
  // is closed. Closing the pseudoconsole and our read handle unblocks it;
  // waiting first would hang the caller (the UI thread) forever.
  if FHPCON <> 0 then
  begin
    TConPTY.Instance.ClosePseudoConsole(FHPCON);
    FHPCON := 0;
  end;
  if FReadPipe <> 0 then
  begin
    CloseHandle(FReadPipe);
    FReadPipe := 0;
  end;

  if Assigned(FReaderThread) then
  begin
    FReaderThread.Terminate;
    FReaderThread.WaitFor;
    FreeAndNil(FReaderThread);
  end;

  _Cleanup;
  FIsRunning := False;
end;

function TTerminalHost.QueryInterface(const IID: TGUID; out Obj): HResult;
begin
  if GetInterface(IID, Obj) then
    Result := S_OK
  else
    Result := E_NOINTERFACE;
end;

function TTerminalHost._AddRef: Integer;
begin
  Result := -1;
end;

function TTerminalHost._Release: Integer;
begin
  Result := -1;
end;

function TTerminalHost.IsActive: Boolean;
begin
  // ADR-056-01: strengthen IsActive so callers can guard a paste write against
  // a host whose process exited externally (CP-7: user typed `exit`, or the
  // shell crashed) before FIsRunning was reconciled by Stop. The handle check
  // is what unblocks an otherwise-synchronous WriteFile to a closed pipe.
  Result := FIsRunning and (FWritePipe <> 0)
    and (FProcessInfo.hProcess <> 0)
    and (WaitForSingleObject(FProcessInfo.hProcess, 0) = WAIT_TIMEOUT);
end;

procedure TTerminalHost.SendInput(const AText: string);
begin
  WriteText(AText);
end;

procedure TTerminalHost.WriteText(const AText: string);
var
  LUtf8: RawByteString;
  LBytesWritten: Cardinal;
begin
  if not FIsRunning or (FWritePipe = 0) or (AText = '') then Exit;

  LUtf8 := UTF8Encode(AText);
  WriteFile(FWritePipe, PAnsiChar(LUtf8)^, Length(LUtf8), LBytesWritten, nil);

  // ESP-078 / BR3: tap the input as a side-effect *after* the passthrough write.
  // It never alters, blocks, or reorders the bytes sent to the shell above.
  if Assigned(FCommandTap) then
    FCommandTap.Feed(AText);
end;

procedure TTerminalHost.PasteText(const AText: string);
const
  PASTE_CHUNK_BYTES = 4096;
var
  LBracketed: Boolean;
  LPayload: string;
  LUtf8: RawByteString;
  LRemaining, LChunk: Integer;
  LCursor: PAnsiChar;
  LBytesWritten: Cardinal;
begin
  // ADR-056-01: guard CP-7 (inactive host) and CP-8 (large payload hang). The
  // host-validity check at entry stops a freeze when the shell process is
  // already gone; chunked writes with a per-chunk re-check stop a hang when
  // the process dies mid-paste. BR8 keeps the writes on the UI thread.
  if (AText = '') or not IsActive then Exit;

  if Assigned(FBuffer) then
    LBracketed := FBuffer.BracketedPasteEnabled
  else
    LBracketed := False;

  LPayload := TTerminalHost.PreparePastePayload(AText, LBracketed);
  if LPayload = '' then Exit;

  LUtf8 := UTF8Encode(LPayload);
  LRemaining := Length(LUtf8);
  if LRemaining = 0 then Exit;
  LCursor := PAnsiChar(LUtf8);
  while LRemaining > 0 do
  begin
    if not IsActive then Exit;
    LChunk := LRemaining;
    if LChunk > PASTE_CHUNK_BYTES then
      LChunk := PASTE_CHUNK_BYTES;
    if not WriteFile(FWritePipe, LCursor^, LChunk, LBytesWritten, nil) then
      Exit;
    if LBytesWritten = 0 then Exit;
    Inc(LCursor, LBytesWritten);
    Dec(LRemaining, Integer(LBytesWritten));
  end;
end;

procedure TTerminalHost.Resize(const ACols, ARows: Integer);
var
  LSize: TCoord;
begin
  if (ACols < 1) or (ARows < 1) then Exit;

  // Resize the libvterm screen model first so the cell grid matches the new
  // geometry, then resize the pseudoconsole so the shell agrees on the size.
  if Assigned(FBuffer) then
    FBuffer.Resize(ACols, ARows);

  if not FIsRunning or (FHPCON = 0) then Exit;

  LSize.X := ACols;
  LSize.Y := ARows;
  TConPTY.Instance.ResizePseudoConsole(FHPCON, LSize);
end;

procedure TTerminalHost.NavigateTo(const APath: string);
begin
  if APath = '' then Exit;

  WriteText(Format('cd /d "%s"'#13#10, [APath]));
  FLastDir := APath;
end;

procedure TTerminalHost.SaveSession;
var
  LData: TSessionData;
begin
  LData := TSessionData.Create;
  try
    LData.FormatVersion := SESSION_FORMAT_VERSION;
    LData.ProfileName := FActiveProfileName;
    LData.WorkingDir := FLastDir;
    if Assigned(FBuffer) then
      LData.BufferContent := FBuffer.SaveStateJSON;
    LData.UpdateTimestamp := Now;
    TSessionManager.Save(LData);
  finally
    LData.Free;
  end;
end;

function TTerminalHost.RestoreSession(var AProfileName, AStartDir: string): Boolean;
var
  LData: TSessionData;
begin
  Result := False;
  LData := TSessionManager.Load;
  if Assigned(LData) then
  try
    AProfileName := LData.ProfileName;
    AStartDir := LData.WorkingDir;
    FActiveProfileName := LData.ProfileName;
    FLastDir := LData.WorkingDir;

    if (LData.FormatVersion = SESSION_FORMAT_VERSION) and
       (LData.BufferContent <> '') and Assigned(FBuffer) then
      Result := FBuffer.LoadStateJSON(LData.BufferContent);
  finally
    LData.Free;
  end;
end;

procedure TTerminalHost._Cleanup;
begin
  if FHPCON <> 0 then
  begin
    TConPTY.Instance.ClosePseudoConsole(FHPCON);
    FHPCON := 0;
  end;
  if FWritePipe <> 0 then
  begin
    CloseHandle(FWritePipe);
    FWritePipe := 0;
  end;
  if FReadPipe <> 0 then
  begin
    CloseHandle(FReadPipe);
    FReadPipe := 0;
  end;
  if FPtyIn <> 0 then
  begin
    CloseHandle(FPtyIn);
    FPtyIn := 0;
  end;
  if FPtyOut <> 0 then
  begin
    CloseHandle(FPtyOut);
    FPtyOut := 0;
  end;
  if FProcessInfo.hProcess <> 0 then
  begin
    CloseHandle(FProcessInfo.hProcess);
    FProcessInfo.hProcess := 0;
  end;
  if FProcessInfo.hThread <> 0 then
  begin
    CloseHandle(FProcessInfo.hThread);
    FProcessInfo.hThread := 0;
  end;
end;

end.


