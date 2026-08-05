# Intent → View: the Design/Code harness

**BPL:** `Aefos.Harness` · **Source:** `source/harness` · **Key unit:**
`Aefos.Harness.View`.

Delphi's killer differentiator is that it has a **Form Designer (Design mode)** *and*
a **Code editor (Code mode)** — text-only IDEs lack this. The terminal agent is a raw
CLI with **no harness**, so the **MCP tool's own behaviour is the only contract**:
correctness must live in the tool/facade, **not** in agent reasoning. The harness
makes that policy *executable* and shared by both the Chat and the Terminal.

## The policy

| Tool class | Rule | Ends in |
|------------|------|---------|
| **Design-mutation** (Add/Remove/Move component, SetProperty, `AddEventHandler`) | `EnsureDesignView` — bring the Form Designer forward, mutate the live designer, `MarkModified` | **Design** |
| **Code-mutation** (`EditUnit`, `ReplaceInEditor`, `SetEditorFullContent`, `ReplaceEditorSelection`, `InsertCodeAtCursor`) | `EnsureCodeView` — bring the source editor to the front (OTA F12) | **Code** |
| **Read / neutral** (design-read, code-read, build/git/search) | Never touch the view | *unchanged* |

Reads serialize the **live** designer, not the stale on-disk `.dfm`.

## `WithLiveForm` — the live-form transaction

The five live form tools all repeated the same ~15-line block (marshal to main
thread → resolve module → find `IOTAFormEditor` → `Show` → resolve native root via
`INTAComponent` → work → `try/except` into a kebab reason → `MarkModified`). That
duplication is where bugs hid (the FMX `is`-false-negative, the `.dfm` clobber).
`WithLiveForm` does the choreography **once**; a tool declares only its **intent**
and the work to run.

```pascal
function WithLiveForm(const AUnitName: string; const AIntent: TLiveIntent;
  const AWork: TLiveFormWork;
  out AChanged: Boolean; out AReason: string): Boolean;
```

- `TLiveIntent = (liDesignMutation, liDesignRead)`.
- Marshals to the IDE main thread (`TThread.Synchronize`), resolves the form +
  native root, applies `EnsureDesignView` for a mutation, runs `AWork`, then
  `MarkModifies` on success.
- Exceptions never cross — any failure returns `False` with a kebab `AReason`
  (`form-not-found`, `access-error`, or the work's own `Ctx.Fail` reason).
- The work block receives an `ILiveFormContext` (the resolved `FormEditor`, native
  `Form`, lazy `Designer`, `FindComponent`, and `Fail`).

### Code-side counterpart

```pascal
procedure EnsureCodeView(const ASourceEditor: IOTASourceEditor); // = OTA F12
```

Call it right after resolving the editor, before the buffer edit / inline diff, so a
code mutation lands **and** ends in Code rather than behind a Form Designer a
preceding design step left in front. Must run on the IDE main thread.

## Module-first fallback

When a design-mutation's unit name doesn't resolve to a live form module — e.g. the
agent invented a phantom `Unit2` or left the name blank — `WithLiveForm` targets the
form the user has **open** in the Designer (`IOTAModuleServices.CurrentModule`, only
when it actually owns a form editor). Components then sprout on screen instead of
failing `form-not-found` and pushing the agent onto a file-first `OverwriteFile` that
ends stuck in Code. A **read** stays strict — no guessing which form was meant.

## The atomic `AddEventHandler`

`AddEventHandler(unit, comp, event, body)` is the headline deliverable: via the
designer it creates the handler **in the form's published auto-managed section**
(where `FormCreate` lives — *not* `public`) **and** wires the `.dfm` event in **one
step** — exactly the designer's double-click. It replaces the broken InsertMethod +
`SetComponentProperty(OnClick)` two-step, whose layer fight (buffer edit vs.
disk-write + module refresh) clobbered the unsaved handler.

## Why a named layer (not a separate process)

The harness is a **named layer** inside the BPLs (`Aefos.Harness`), not a separate
process. It encapsulates the Design/Code duality so every live tool draws on the same
battle-tested primitives. `Aefos.MCP.Tools.OTA` requires it; the facade calls
`WithLiveForm`. `Aefos.Harness.Agents` is the reserved home for deterministic
backstage helpers — **not** LLM sub-agents.

> **Open item:** a full `WithLiveSource` transaction (the code-side analogue of
> `WithLiveForm`) is planned; today the lightweight `EnsureCodeView` `Show` helper
> achieves the intent→view goal with far less risk.
