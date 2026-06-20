# 11. Troubleshooting

Common symptoms and how to fix them. If nothing here helps, see
[Privacy & license](12-privacy-and-license.md) for the contact channel.

## Installation and package loading

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| **View → Aefos AI (Chat)/(Terminal)** does not appear | IDE not restarted after install; package not registered | Restart RAD Studio; check **Components → Install Packages** |
| A plugin package fails to load (`requires`) | Runtime BPLs not on the search path | Make sure the BPLs are reachable (PATH / Library path) and restart the IDE |
| Pipe conflict when loading Chat + Terminal | Both hosts need distinct pipe names | Restart the IDE |

## Chat

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Chat shows **plain text**, no Markdown | WebView2 Runtime missing | Install WebView2: <https://aka.ms/webview2> and restart the IDE |
| Chat is **fully black** (not plain text, not the brief flicker) | (rare) WebView2 Runtime missing — the Chat already runs **with GPU acceleration off by default**, so GPU/driver black no longer happens | Re-run the installer (it bundles + installs WebView2 offline). To **force** GPU acceleration (if your machine has a good GPU), set `AEFOS_WEBVIEW_ENABLE_GPU=1` and restart the IDE |
| Sending a message **"does nothing"** | No AI CLI configured/installed | Configure the provider in **Options → Aefos** and install/log in to the CLI ([Providers](08-ai-providers.md)) |
| The agent doesn't use the project tools (MCP) | MCP not connected for that CLI | Run **Test MCP** in **Options → Aefos**; check the selected provider |
| The docked panel flickers/blacks out briefly on submit | Docked-window composition behavior | Usually recovers on its own; if it persists, use the **floating** panel |

## AI providers

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Codex connects MCP but doesn't answer | Missing `codex login` | Run `codex login` to enable the model |
| "aefos listed but not connected" (Test MCP) | Wording difference between CLIs | For non-Claude CLIs, `aefos` being present already means configured |
| Copilot can't find MCP in agent mode | `-p` does not auto-load the workspace `.mcp.json` | Aefos already injects the global config; confirm the provider and run **Test MCP** |

## Terminal

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Prompt glyphs show as "tofu" boxes | Font without Nerd/powerline glyphs | Pick a compatible font (e.g. a *Nerd Font*) in the Terminal options |
| **Ctrl+P** and **Ctrl+R** seem to conflict | They are different things | **Ctrl+P** = Aefos palette; **Ctrl+R** = the shell's native reverse search |
| Terminal unavailable | **Pro** edition feature | See [Licensing](10-licensing.md) |

## License

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Pro feature blocked | No active Pro license (or expired trial) | In **View → Aefos AI (Chat)**, open the license item (e.g. *License: active*) and activate the key |
| Activation fails | No network at activation time | Validation needs network; afterward it works offline within the grace window |

➡️ Next: [Privacy & license](12-privacy-and-license.md)
