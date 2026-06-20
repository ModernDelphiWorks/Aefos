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
   - During installation, Aefos **detects** the AI CLI, Python, and WebView2. The
     **WebView2 Runtime** (Microsoft's official component, required by the Chat) is
     **installed automatically** when missing, from Microsoft's official bootstrapper.
     For the **AI CLI** and **Python**, Aefos only points you to the official source —
     it **never** installs third-party binaries for you.
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

## Rich Markdown (WebView2)

The Chat renders through **WebView2**, which the installer provisions automatically.
If the Chat appears **blank/black** or shows **plain text**, it's usually a missing
WebView2 — re-run the installer (it installs the runtime) or install it manually:
<https://aka.ms/webview2>. Then restart the IDE.

## Where things live

| Item | Path |
|------|------|
| Global MCP configuration | `%APPDATA%\Aefos\aefos-mcp.json` |
| MCP bridge (Terminal) | `%APPDATA%\Aefos\mcp-bridge.ps1` |
| PyTools (Python tools) | `%APPDATA%\Aefos\pytools` |

## Updating to a new version

On the **same machine** your license is preserved — you **don't need to deactivate
anything**.

**Recommended (same machine):**

1. **Close RAD Studio.**
2. **Run** the new `Aefos-Setup-<version>.exe` — you can install **over** the current
   version (no need to uninstall).
3. **Reopen the IDE.** Your license (including the **Free** tier) stays active, and the
   Chat now uses the WebView2 the installer provisions.

**Clean reinstall — or moving to another machine:**

1. Open the IDE → **Aefos → License…** → **copy your key** and click
   **Deactivate (free seat)**.
2. **Close the IDE** and **uninstall** the current version.
3. **Install** the new version.
4. Reopen the IDE → **Aefos → License…** → **paste the key** → **Activate**.

> **Deactivate** is only required to move the seat to **another machine**. The license
> lives in `%APPDATA%\Aefos\license.dat` and is **not** removed on uninstall — so, on
> the same machine, updating needs no deactivation and no re-entering the key.

## Uninstall

Uninstalling removes the BPLs, the bridge, the generated `.mcp.json`, the IDE package
registrations, and the PATH entry. Your own PyTools (the ones you dropped into the
folder) are preserved.

➡️ Next: [Getting started](04-getting-started.md)
