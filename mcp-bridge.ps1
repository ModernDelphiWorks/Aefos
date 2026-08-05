#Requires -Version 5.1
<#
.SYNOPSIS
  stdio <-> Windows named-pipe bridge for the Aefos MCP server.

.DESCRIPTION
  Connects to the named pipe exposed by the Terminal BPL, then forwards
  stdin to the pipe and pipe responses back to stdout.  The MCP transport
  uses LF-delimited JSON-RPC frames, so each readline/writeline maps to
  exactly one frame.

.PARAMETER Session
  MCP session name (default: terminal).  Must match the session name
  configured in Tools -> Options -> Aefos -> Terminal.
#>
param(
  [string]$Session = 'terminal'
)

$pipeName = 'aefos-mcp-' + $Session

try {
  $pipe = [System.IO.Pipes.NamedPipeClientStream]::new(
    '.',
    $pipeName,
    [System.IO.Pipes.PipeDirection]::InOut,
    [System.IO.Pipes.PipeOptions]::None,
    [System.Security.Principal.TokenImpersonationLevel]::None)

  $pipe.Connect(5000)

  # UTF-8 WITHOUT a BOM. [System.Text.Encoding]::UTF8 is BOM-emitting, so the
  # StreamWriter prepends EF BB BF to the FIRST frame; the server then sees
  # those three bytes ahead of the "{...}" initialize handshake and rejects it -32700
  # (malformed JSON), which the MCP client surfaces as a failed server. Only the
  # first frame carries the BOM, so later frames (tools/list) would parse -- a
  # confusing partial failure. A single shared no-BOM encoding fixes both
  # directions.
  $utf8NoBom  = [System.Text.UTF8Encoding]::new($false)
  $pipeReader = [System.IO.StreamReader]::new($pipe, $utf8NoBom)
  $pipeWriter = [System.IO.StreamWriter]::new($pipe, $utf8NoBom)
  $pipeWriter.AutoFlush = $true
  $pipeWriter.NewLine   = "`n"

  [System.Console]::OutputEncoding = $utf8NoBom
  # Decode stdin as UTF-8 too. Without this, stdin is read with the console's OEM
  # code page, so a UTF-8 'a-acute' (bytes C3 A1) arrives as two chars (CP437:
  # C3 -> box-drawing, A1 -> i-acute) and corrupts tool arguments. Must be set
  # BEFORE [Console]::In is first read so the cached reader uses UTF-8.
  [System.Console]::InputEncoding = $utf8NoBom

  $stdIn  = [System.Console]::In
  $stdOut = [System.Console]::Out

  while ($true) {
    $line = $stdIn.ReadLine()
    if ($null -eq $line) { break }

    # Rewrite protocolVersion in initialize frames -- the server only accepts
    # 2025-06-18; Claude CLI may send an older version and trigger -32602.
    $lineToSend = $line
    $isNotification = $false
    try {
      $frame = $line | ConvertFrom-Json -ErrorAction Stop
      $isNotification = ($null -eq $frame.id)
      if ($frame.method -eq 'initialize' -and
          $null -ne $frame.PSObject.Properties['params'] -and
          $null -ne $frame.params.PSObject.Properties['protocolVersion']) {
        $frame.params.protocolVersion = '2025-06-18'
        $lineToSend = $frame | ConvertTo-Json -Compress -Depth 10
      }
    } catch { }

    $pipeWriter.WriteLine($lineToSend)

    if (-not $isNotification) {
      $response = $pipeReader.ReadLine()
      if ($null -eq $response) { break }

      $stdOut.Write($response + "`n")
      $stdOut.Flush()
    }
  }
}
catch {
  [System.Console]::Error.WriteLine('mcp-bridge: ' + $_.Exception.Message)
  exit 1
}
finally {
  if ($null -ne $pipe) { $pipe.Dispose() }
}
