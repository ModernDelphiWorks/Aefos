# MCP Tool Surface

The in-process MCP server is how the external agent **acts** on the IDE project.
This doc explains the tool model and safety guarantees. For the *authoritative* live
list, ask the running server (`tools/list`) — the surface evolves, so this doc
deliberately avoids hardcoding a tool count that would drift.

## Where the surface is defined

- **Engine / dispatch:** `source/mcp/Core` (`Aefos.MCP.Tools`, `…Server`).
- **OTA implementations:** `source/mcp/OTA` (the workspace facade that backs each
  IDE-coupled tool).
- **Pure file tools:** `source/mcp/Tools` (`Aefos.Tools.*`) — line/column,
  disk, templates; no IDE dependency.

## Tool groups

The surface is organized by area. Representative tools per group:

| Group | Examples |
|-------|----------|
| **Project** | `GetProjectName`, `GetProjectPath`, `GetProjectType`, `GetProjectVersion`/`Set…`, `RenameProject`, `GetActiveProject`, `GetProjectManagerTree` |
| **Project group** | `ListProjectsInGroup`, `AddProjectToGroup`, `BuildAllInGroup`, `SaveProjectGroup` |
| **Units** | `ReadUnit`, `AddUnit`, `EditUnit`, `DeleteUnit`, `RenameUnit`, `MoveUnitToFolder`, `CreateNewUnit` |
| **Editor** | `GetCursorPosition`, `GetSelection`, `OverwriteFile`, `InsertCodeAtCursor`, `ReplaceEditorSelection`, `FindInEditor`, `OpenUnitInEditor` |
| **Build** | `RunBuild`, `GetBuildStatus`, `GetCompilerErrors`, `CleanProject`, `GetActiveConfiguration` |
| **Run** | `RunProject`, `RunWithoutDebugger`, `StopProject` |
| **Forms / DFM (live designer)** | `GetDFMContent`, `SetDFMContent`, `ListFormComponents`, `AddComponent`, `RemoveComponent`, `SetComponentProperty`, `AddEventHandler`, `OpenFormDesigner` |
| **Symbols** | `GetClassMembers`, `GetMethodBody`, `FindSymbolUsages`, `GetInheritanceChain`, `GetSymbolsInUnit` |
| **Uses / deps** | `GetUnitUses`, `AddToUses`, `RemoveFromUses`, `AddToSearchPath`, `AddToLibraryPath` |
| **Resources** | `AddResourceFile`, `EmbedFileAsDelphiConst`, `ListProjectResources`, `ListProjectImages` |
| **Git** | `GetGitStatus`, `GetGitLog`, `GetGitCurrentBranch` |
| **IDE** | `ListIDEActions` (full live action catalog — discover the name first), `ExecuteIDEAction`, `GetIDEVersion`, `GetIDETheme`, `ShowMessage` |
| **Audit** | `QueryAuditLog` |

This table is illustrative, not exhaustive. The running server is the source of
truth.

## Safety model

Three guarantees, all enforced in `MCP.Core` (IDE-agnostic):

### 1. Read-before-edit (anchored mutation)

`EditUnit` requires a `base_hash` obtained from a prior `ReadUnit`. The edit replaces
`old_text` with `new_text` **only if** the buffer still hashes to `base_hash`. A
stale edit is rejected rather than clobbering newer content. On apply it returns a
fresh `content_hash`.

```
ReadUnit(unit_path) → { body, content_hash }
EditUnit(unit_path, old_text, new_text, base_hash = content_hash)
   → { outcome, content_hash }   // outcome ∈ { applied, rejected, userRejected, … }
```

### 2. Consent

Destructive or mutating tools (`DeleteUnit`, `OverwriteFile`, `AddUnit`, version
writes, …) are gated by a **consent registry** before they run. The host plugin
decides how consent is surfaced (the seam mirrors the consent-presenter pattern).

### 3. Audit

Mutations are appended to a JSONL audit log, `mcp-audit-YYYY-MM-DD.jsonl`, queryable
via `QueryAuditLog`. This gives a replayable trail of every change the agent made.

## Inline diff approval (Chat)

On top of consent, the Chat plugin shows an **inline red/green diff in the editor**
(VS-Code style) before a code edit is applied, with clickable ✓ Apply / ✗ Reject
(keyboard Tab/Esc or a floating overlay). The agent's edit pauses on a diff approver;
rejection returns a `userRejected` outcome instead of mutating. It is routed for
`EditUnit`, `ReplaceInEditor` and `SetEditorFullContent` (the latter with a
whole-buffer fallback when a minimal block can't anchor). See
[components/chat.md](components/chat.md).

## Intent → View (the tool *is* the contract)

Because the terminal agent runs a raw CLI with no harness, correctness lives in the
tool, not in agent reasoning. Mutation tools end in the right IDE view:

- **Design-mutation tools** (`AddComponent`, `RemoveComponent`, `SetComponentProperty`,
  `AddEventHandler`) run through `Aefos.Harness.WithLiveForm` — they `EnsureDesignView`
  and end in the **Form Designer**, operating on the *live* designer (reads serialize
  the live form, not the stale on-disk `.dfm`).
- **Code-mutation tools** (`EditUnit`, `ReplaceInEditor`, `SetEditorFullContent`,
  `ReplaceEditorSelection`, `InsertCodeAtCursor`) call `EnsureCodeView` and end in
  **Code**.
- **`AddEventHandler(unit, comp, event, body)`** is atomic — it creates the handler
  in the form's published auto-managed section *and* wires the `.dfm` event in one
  step (the designer's double-click), replacing the broken InsertMethod +
  SetComponentProperty two-step.

See [intent-view.md](intent-view.md).

## Pure file tools (no OTA)

`Aefos.Tools.*` (in `source/mcp/Tools`) are pure: they take a coordinate +
payload and edit a file on disk (line/column, templates) with no `uses ToolsAPI`.
They exist so the engine can do file edits without the IDE, and so other BPLs can
reuse them.
