unit Aefos.Tools.PyTool;

(*
  Aefos.Tools.PyTool — Python tool launcher (thin layer over Tools.Process).

  Lets the suite run a Python script as a tool: resolve an interpreter, run the
  script feeding JSON on stdin, capture JSON on stdout. The CONTRACT (what each
  tool folder looks like, how args/results are shaped) is consumed by the MCP
  registry; this unit only knows "find python, run a .py, return the process
  result". JSON parsing/building stays in the caller — this stays pure strings.

  Interpreter resolution order: an explicit path if it exists, else `py.exe`,
  else `python.exe` on PATH. Returns '' when none is found.

  Boundary: RTL + Winapi (PATH search) + Tools.Process. No ToolsAPI, no Vcl./FMX.

  Naming convention: MCP\Source\Tools\NAMING.md (domain `Py`).
*)

interface

uses
  Aefos.Tools.Process;

type
  // Python tool launcher (thin layer over Tools.Process) as a sealed static
  // namespace (see the unit header). Never instantiated.
  TPythonRunner = class sealed
  public
    // Resolves a usable Python interpreter. APreferred (e.g. a venv python.exe) wins
    // when it exists on disk; otherwise `py` then `python` are searched on PATH.
    // Returns the resolved executable path, or '' when none is available.
    class function ResolveInterpreter(const APreferred: string): string; static;

    // Runs AScriptPath under AInterpreter, feeding AStdInput on stdin. AWorkDir = ''
    // keeps the caller's directory. ATimeoutMs = 0 waits forever.
    class function RunScript(const AInterpreter, AScriptPath, AStdInput,
      AWorkDir: string; const ATimeoutMs: Cardinal): TToolProcessResult; static;
  end;

implementation

uses
  System.SysUtils,
  Winapi.Windows;

// True when AName is found on PATH; fills AResolved with its full path.
function _OnPath(const AName: string; out AResolved: string): Boolean;
var
  LBuf: array[0..MAX_PATH] of Char;
  LFilePart: PChar;
  LLen: DWORD;
begin
  LLen := SearchPath(nil, PChar(AName), nil, Length(LBuf), LBuf, LFilePart);
  Result := (LLen > 0) and (LLen < Cardinal(Length(LBuf)));
  if Result then
    AResolved := Copy(LBuf, 0, LLen)
  else
    AResolved := '';
end;

class function TPythonRunner.ResolveInterpreter(const APreferred: string): string;
begin
  if (APreferred <> '') and FileExists(APreferred) then
    Exit(APreferred);
  if _OnPath('py.exe', Result) then
    Exit;
  if _OnPath('python.exe', Result) then
    Exit;
  Result := '';
end;

class function TPythonRunner.RunScript(const AInterpreter, AScriptPath, AStdInput,
  AWorkDir: string; const ATimeoutMs: Cardinal): TToolProcessResult;
begin
  // -I = isolated mode (ignore env/user site) for reproducible tool runs.
  Result := TProcessRunner.Run(AInterpreter, '-I "' + AScriptPath + '"',
    AStdInput, AWorkDir, ATimeoutMs);
end;

end.
