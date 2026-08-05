unit Aefos.Harness.Agents;

{ Backstage "agents" — the deterministic behind-the-scenes helpers that run
  AROUND the real work so the worker (the user's AI CLI) never has to think
  about IDE mechanics. They are NOT LLM sub-agents: an LLM is the wrong tool for
  mechanical, deterministic steps (it adds cost, latency and a misclassification
  failure mode, and a separate flip-loop would race the live mutation). The
  contract lives here, in code, executed in-process at the MCP choke point.

  The first such helper is the intent->view enforcement: a code mutation flips
  the IDE to Code, a design mutation to Design — synchronised with the change so
  the Design<->Code dance looks fluid to whoever is watching. That seam lives in
  Aefos.Harness.View as the symmetric pair WithLiveForm (design transactions) and
  WithLiveSource (code transactions) — both shipped (S2); every code-write tool
  runs through WithLiveSource. Higher-level orchestration helpers (e.g. compose a
  multi-step IDE operation from primitives) land here as they are extracted, tool
  by tool.

  Home: the Aefos.Harness BPL (passive — registers NOTHING in the IDE, so it
  carries no unload-AV surface), shared by the chat and the terminal. }

interface

implementation

end.
