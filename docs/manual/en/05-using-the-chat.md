# 5. Using the Chat

The Chat panel is where you talk to the AI and put it to work on your project.

![Aefos Chat panel in Agent mode, docked in the IDE](../assets/chat.png)

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

## Reviewing changes: see the before and the after

Whenever the agent **changes code**, Aefos shows the change **inside the editor** as a
**stacked before/after diff**: the original text appears struck out in **red on top**,
and the new text in **green right below** — so you see exactly what will change before
deciding (it also works for wide and multi-line edits).

![Change review: the before (struck-out red) stacked above the after (green), with the ✓/✗/✎ controls in the gutter](../assets/change-review.png)

In the **gutter** (on the left) each change has three buttons:

- **✓ accept** — keep the new text.
- **✗ reject** — undo it and restore the original.
- **✎ annotate** — write a note that is **delivered to the agent** (tagged accepted or
  rejected), so it learns your feedback on that edit.

There's also an **Accept all / Reject all** pill when several changes are pending — they
accumulate **without blocking** the agent. **Saving** the file (or running) **accepts**
the pending changes and clears the review.

The same review applies to edits made from the **Chat and the Terminal** — it lives in a
shared IDE layer, so the accept/reject/annotate flow is identical in both.

> The review is shown for code edits (e.g. editing a unit, replacing a snippet). See
> [What the agent does in your project](06-what-the-agent-does.md).

## Safety: consent and audit

Actions that **modify** the project go through a **consent** prompt before they run,
and **every** tool call is recorded in an **audit log**. You have traceability of what
the agent did.

➡️ Next: [What the agent does in your project](06-what-the-agent-does.md)
