# 4. Getting started

In a few minutes you will have your first conversation with the agent acting on your
project.

## 1. Open a Delphi project

Aefos works on the **open project** in the IDE. Open (or create) a project before you
start — that way the agent has something to read and change.

## 2. Open the Chat panel

Go to **View → Aefos AI (Chat) → Open Chat**. The panel can be **floating** or
**docked** in the IDE, like any Delphi panel.

## 3. Pick the AI provider

Go to **Tools → Options → Aefos** and select the **provider/executor** you want to use
(Claude Code, Codex, Copilot, or Gemini) and the **model**, if applicable.

- The chosen model is **remembered per provider** — switching CLIs does not "leak" the
  model from one to another.
- You must have that CLI **installed and logged in**. See
  [AI providers](08-ai-providers.md).

> **Tip:** still in **Options → Aefos**, use the **Test MCP** action to confirm the
> CLI sees the `aefos` server. See [Configuration](09-configuration.md).

## 4. Your first conversation

1. In the Chat panel, type a simple request, for example:
   *"List the project units and explain the main unit to me."*
2. Press **Enter**.
3. The agent will use the Aefos MCP to read the project and answer.

**Agent mode is the default** — the agent is ready to *act* on the project, not just
talk. To understand the difference between the modes, see
[Using the Chat](05-using-the-chat.md).

## 5. Watch the agent act

Ask for something that changes code, for example:
*"Add an example method to the main unit."*

When the agent edits a file, Aefos shows an **inline diff** (red/green) in the editor,
with **✓ accept** / **✗ reject** buttons (or **Tab** / **Esc**). Nothing is applied
without your approval. Details in [Using the Chat](05-using-the-chat.md).

## Next steps

- Understand the modes and the diff: [Using the Chat](05-using-the-chat.md)
- See everything the agent can do: [What the agent does in your project](06-what-the-agent-does.md)
- Try the Terminal: [Using the Terminal](07-using-the-terminal.md)
