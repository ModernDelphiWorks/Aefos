# Component — Terminal

**BPL:** `Aefos.OTA.Terminal` · **Source:** `source/terminal`. Formerly the
standalone **RADShell** repo.

## What it is

A real terminal docked inside the IDE — ConPTY-backed, rendered through a `libvterm`
emulation layer — with the same OTA reach as the Chat plugin. Like Chat, the Terminal
BPL can **host the in-process MCP server** (via its own workspace facade), so an agent
launched from the terminal can act on the project.

## Source layout (`source/terminal`)

| Folder | Contents |
|--------|----------|
| `Core/` | Terminal engine + services. |
| `UI/` | The dock form, terminal canvas/painter, welcome pane, options, snippets, command palette views, branding. |
| `ThirdParty/libvterm` | Vendored VTerm emulation. |

### Notable Core areas

- **Terminal engine:** `Core.ConPTY`, `Core.LibVTerm`, `Core.VTermBuffer`,
  `Core.TerminalHost`, `Core.Session`, `Core.Reflow`, `Core.SixelDecode`,
  `Core.MouseEncode`.
- **Shell UX:** `Core.Profiles` (pwsh/cmd/…), `Core.Themes`, `Core.Snippets` (+
  edit model / vars), `Core.CommandPalette` + `Core.FuzzyMatch`,
  `Core.CommandHistory`, `Core.GitInfo`, `Core.ContextStrip`, `Core.WelcomeModel`.
- **MCP host:** `MCP.Host`, `MCP.WorkspaceFacade` (`TTerminalOTAWorkspaceFacade` —
  the facade that actually serves the MCP pipe in dev), `MCP.Composition`,
  `MCP.Config`, plus policies (`MCP.RepoRootPolicy`, `MCP.ProjectCreatePolicy`,
  `MCP.ProjectGroupManagerPolicy`) and project creation (`MCP.ProjectCreator`,
  `MCP.ProjectDir`, `UI.Wizard`).
- **Self-test:** `Core.SelfTest`, `Core.TestContract`, `UI.SelfTestChannel`
  (in-IDE L5 channel, `{$IFDEF DEBUG}`-gated).

## Relationship to Chat / shared core

Both plugins consume the same `MCP.Core` engine. They differ only in their facade
wiring and UI. In a dev session where only the Terminal BPL is installed, the
**Terminal's** facade is the one serving the MCP pipe — so MCP-driven workflows
(e.g. `CreateNewProject`) are implemented/validated against
`TTerminalOTAWorkspaceFacade`, and a rebuild to change MCP behavior is a **Terminal
BPL** rebuild.

## Hosting notes

- **Distinct pipe names.** When Chat and Terminal both run, each MCP host must use a
  **distinct pipe name**; otherwise the second BPL to load fails (`ERROR_PIPE_BUSY`).
- **Menu sharing.** Both BPLs contribute to a single top-level **Aefos AI**
  menu via a find-or-create shared between them (same caption in both).
- **Splash/About.** Chat and Terminal each register their own splash + About
  independently.
