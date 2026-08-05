# IDE Actions — discovery & the fire-and-forget recipe

Two MCP tools work together:

- **`ListIDEActions`** (read-only) — enumerates the live `INTAServices.ActionList`
  (`{name, caption, category, shortcut, hint, enabled}`, optional `filter`). Use it
  to **discover** the exact action name — the live list is the authority, since it
  reflects the IDE and packages actually installed.
- **`ExecuteIDEAction`** (consent-light) — **fires** a named action. Deterministic,
  works with the IDE in the background (no keyboard/foreground).

## Rule of thumb: prefer a dedicated tool when one exists

Many IDE behaviors already have a **dedicated MCP tool** that returns a *structured
result* (status, errors, ids) instead of just "fired". Prefer the tool; reach for
`ExecuteIDEAction` only when there is **no** tool for the behavior.

| Behavior | IDE action (shortcut) | Prefer this tool instead |
|----------|----------------------|--------------------------|
| Build | `ProjectBuildCommand` (Shift+F9) | **`RunBuild`** (`mode:build`) → returns `build_id`, then `GetBuildStatus` / `GetCompilerErrors` |
| Compile (make) | `ProjectCompileCommand` (Ctrl+F9) | **`RunBuild`** (`mode:make`) |
| Run | `RunRunCommand` (F9) | **`RunProject`** |
| Run without debugging | `RunRunNoDebugCommand` (Ctrl+Shift+F9) | **`RunWithoutDebugger`** |
| Stop | — | **`StopProject`** |
| Save active file | `FileSaveCommand` (Ctrl+S) | **`SaveActiveFile`** (reports `changed`) |
| Save all | `FileSaveAllCommand` (Ctrl+Shift+S) | **`SaveAllFiles`** |
| Clean | — | **`CleanProject`** |

## Genuine fire-and-forget actions (no dedicated tool — use ExecuteIDEAction)

These are deterministic, dialog-free, and have **no** MCP-tool equivalent — firing
the action *is* the clean path:

| Action | Shortcut | Effect |
|--------|----------|--------|
| `actFormatSource` | Ctrl+D | **Format Source** — reformats the active unit to the IDE's formatter settings. No tool exists for this. |
| `EditFormatDocument` | — | Format Document (HTML/other designers). |
| `ViewToggleFormCommand` | F12 | Toggle **Form ↔ code** (this is the one that makes the designer re-render after a DFM edit). |
| `ViewSwapSourceFormCommand` | Alt+F12 | Swap **Design ↔ DFM-as-text**. |
| `ViewFormCommand` | Shift+F12 | Open the **Forms…** picker (navigation). |

### The canonical DFM round-trip (edit a form's components programmatically)

The pain that motivated `ListIDEActions`: an agent needs to edit a form, then make
the designer re-render. The deterministic, keyboard-free flow:

```
1. OpenFormDesigner(unit)                      -> always lands on Design (not a toggle)
2. ExecuteIDEAction("ViewSwapSourceFormCommand") -> Design -> DFM-as-text (deterministic: we know we're on Design)
3. SetEditorFullContent(dfmSource)             -> inject the new DFM into the buffer
4. ExecuteIDEAction("ViewSwapSourceFormCommand") -> DFM-as-text -> Design (re-renders the components)
5. SaveActiveFile                              -> persist
```

## NOT fire-and-forget — avoid firing these blindly

- **Anything that opens a dialog/gallery.** `FileNewCommand` ("New items"),
  `ProjectAddNewProjectCommand`, `ComponentNewCommand`, `FileSaveAsCommand`,
  `FileSaveProjectAsCommand` — these open interactive windows an agent can't drive.
  To *create* artifacts, use the programmatic tools (`CreateNewUnit`,
  `CreateNewProject`) instead, which the OTA fulfils directly.
- **Debug stepping / breakpoints.** `RunStepOverCommand` (F8), `RunTraceIntoCommand`
  (F7), `RunGotoCursorCommand` (F4), `Run*BreakpointCommand`, `RunEvalModCommand` —
  interactive debug flow, not single-shot operations.

## Discovering more

```
ListIDEActions(filter: "refactor")   // or "view", "edit", "project", "search", ...
```

The running server is the source of truth — the live list reflects the current IDE
version and even per-action `enabled` state (e.g. `ViewToggleFormCommand` reports
`enabled:false` when there's nothing to toggle).
