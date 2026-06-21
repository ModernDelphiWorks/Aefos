# 6. What the agent does in your project

In Agent mode, the AI acts on the open project through Aefos's internal **MCP server**,
which exposes the IDE's capabilities as **tools**. You don't need to memorize any of
this — the agent uses the tools on its own — but it helps to know what it can do.

## What it can do

| Area | Examples of what the agent does |
|------|---------------------------------|
| **Code** | Read, insert, replace, and edit unit snippets |
| **Build & Run** | Compile, run **with the debugger**, stop execution, view compiler errors |
| **Git** | Status, log, current branch |
| **Project** | Project tree, units, packages, search paths |
| **Form Designer (live)** | Add/remove components on the open form, set properties, create event handlers |
| **Refactor** | Rename, scaffolding |

> All changes go through **consent + before/after review + audit** (see
> [Using the Chat](05-using-the-chat.md)).

## The Design ↔ Code "magic"

Delphi's big differentiator is having **Design** (Form Designer) **and** **Code** (the
editor). Aefos respects that automatically:

- When the agent makes a **design change** (e.g. adding a button), the IDE **flips to
  Design** and you see the component appear instantly.
- When it makes a **code change** (e.g. inserting a method), the IDE **flips to Code**.
- **Read** actions (read design/code, build, git, search) **do not** move your view.

The result is a fluid sequence: you ask for a component and *watch* the IDE flip to
Design; ask for code and *watch* it flip to Code.

## The "live" designer

Form reads and changes operate on the **live designer** — not the stale `.dfm` on
disk. So what the agent reads and changes is exactly what you see on screen.

### Create an event handler in one step

The agent can create an event handler **atomically** with `AddEventHandler` — it
creates the method in the correct section of the form **and** wires the event in the
`.dfm` in a single step, exactly like the designer's double-click.

## Full build → run → stop control

From the Chat, the agent can save everything, clean, compile, **run with the
debugger**, and **stop** the application — a complete cycle without you leaving the
conversation.

➡️ Next: [Using the Terminal](07-using-the-terminal.md)
