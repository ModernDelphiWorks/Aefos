# 3. Installation

The recommended path for end users is the **installer**
(`Aefos-Setup-<version>.exe`). It copies the packages (BPLs), registers the Chat and
the Terminal in the IDE, and prepares the MCP configuration — no manual folder work
required.

> If you build from source (plugin developer), see the
> the project repository. This page covers the
> **end-user** path.

## Step by step

1. **Close RAD Studio.** The installer registers packages in the IDE; it cannot be
   open.
2. **Run** `Aefos-Setup-<version>.exe`. It is **per-user** (no administrator needed).
   - During installation, Aefos **detects** whether you already have the AI CLI,
     Python, and WebView2. If something is missing, it points you to the official
     source — it **never** installs third-party binaries for you.
3. **Restart RAD Studio.** The `Aefos AI - Chat` and `Aefos AI - Terminal` packages
   come pre-registered.
4. **Confirm:** the **View** menu shows the **Aefos AI (Chat)** and
   **Aefos AI (Terminal)** submenus.

## Post-install verification

After reopening the IDE, check:

- [ ] The **View** menu shows **Aefos AI (Chat)** and **Aefos AI (Terminal)**.
- [ ] Under **Tools → Options** there is an **Aefos** node (with its config pages).
- [ ] **View → Aefos AI (Chat) → Open Chat** opens the chat panel.
- [ ] (If you installed it) **View → Aefos AI (Terminal)** opens the terminal.

## Enabling rich Markdown (WebView2)

If the Chat shows **plain text** instead of formatted Markdown, install the **WebView2
Runtime**: <https://aka.ms/webview2>. Then restart the IDE.

## Where things live

| Item | Path |
|------|------|
| Global MCP configuration | `%APPDATA%\Aefos\aefos-mcp.json` |
| MCP bridge (Terminal) | `%APPDATA%\Aefos\mcp-bridge.ps1` |
| PyTools (Python tools) | `%APPDATA%\Aefos\pytools` |

## Uninstall

Uninstalling removes the BPLs, the bridge, the generated `.mcp.json`, the IDE package
registrations, and the PATH entry. Your own PyTools (the ones you dropped into the
folder) are preserved.

➡️ Next: [Getting started](04-getting-started.md)
