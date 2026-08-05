# pytools — Python tools (drop-a-file)

Each subfolder here is **one MCP tool written in Python**, for what Delphi does
not do well (data analysis, ML, libraries from the Python ecosystem). The MCP
server scans this tree at startup and exposes each manifest as a live tool —
**adding capability = dropping a folder, no BPL recompile**.

## Contract

One tool = one folder with:

```
<tool>/
  tool.json     # manifest: name, description, inputSchema, entry, timeoutMs
  <entry>.py    # the script
  requirements.txt   # (optional) deps; install into a venv and point "python" at it in the manifest
```

### Invocation protocol
- **Input:** the tool argument arrives as **JSON on stdin** (UTF-8).
- **Output:** the result is **JSON on stdout** (UTF-8).
- **stderr:** logs/errors (not the result).
- **exit code:** `0` = ok; non-`0` = failure (the message goes to stderr).

### `tool.json` manifest
```json
{
  "name": "ProfileCsv",
  "description": "Profiles a CSV and returns per-column statistics",
  "inputSchema": { "type": "object", "properties": { "path": {"type":"string"} }, "required":["path"] },
  "entry": "main.py",
  "python": "",          // optional: path to a specific interpreter/venv; empty = auto (py/python on PATH)
  "timeoutMs": 30000
}
```

The engine that runs this is pure Delphi: `Aefos.Tools.PyTool` (resolves the
interpreter + runs the script) on top of `Aefos.Tools.Process` (subprocess
with pipes/timeout/kill). The MCP registry reads the manifest and wraps it as a
tool.

> Security: running arbitrary Python is a sensitive capability — every
> invocation passes through the MCP's Consent + AuditLog gate. Python tools must
> use UTF-8 on stdio (see the `echo_upper` example).
