# 5. Using the Chat

The Chat panel is where you talk to the AI and put it to work on your project.

## Agent mode vs. Chat mode

| Mode | What it does | When to use |
|------|--------------|-------------|
| **Agent** (default) | The AI can **act** on the project: read, edit code, build, run, drive the Form Designer, git… via MCP tools | When you want the AI to *do* something in the project |
| **Chat** | Conversation only — no acting on the project | Questions, brainstorming, explanations |

**Agent mode is the default.** The two modes are kept distinct — choose according to
your intent.

## Sending a message

Type your request and press **Enter**. The CLI output is streamed live and rendered as
**Markdown** (with syntax highlighting) when WebView2 is installed; without it, it
appears as plain text.

## Skills with `/agent`

You can invoke **skills** (predefined flows) by typing `/agent` followed by the skill.
Skills live in a canonical project folder (`.aefos/skills/`) and are automatically
replicated to the format the active CLI expects.

- Free-form text (no skill) goes straight to the CLI as a normal prompt.
- A skill builds a **Delphi-aware** prompt and dispatches it to the CLI.

## Project context

In Agent mode, Aefos packages your **Delphi project context** (via OTA) so the AI
answers with knowledge of what is open — instead of generic answers.

## Inline diff: accept or reject changes

Whenever the agent is about to **change code**, Aefos shows the change as an **inline
diff** in the editor, VS Code style:

- Removed lines in **red**, added lines in **green**.
- Clickable **✓ (apply)** and **✗ (reject)** buttons.
- Shortcuts: **Tab** applies, **Esc** rejects.

Nothing is written without your approval. If you reject, the change is discarded and
the agent gets that result back (instead of mutating the file).

> The diff is shown for code edits (e.g. editing a unit, replacing a snippet,
> rewriting the editor content). See
> [What the agent does in your project](06-what-the-agent-does.md).

## Safety: consent and audit

Actions that **modify** the project go through a **consent** prompt before they run,
and **every** tool call is recorded in an **audit log**. You have traceability of what
the agent did.

➡️ Next: [What the agent does in your project](06-what-the-agent-does.md)
