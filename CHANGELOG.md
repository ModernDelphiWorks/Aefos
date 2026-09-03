# Changelog

All notable changes to **Aefos AI** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Dates are in `YYYY-MM-DD`.

## [Unreleased]

### Fixed

**With a project open, every Chat message failed instantly.** The turn never
reached the CLI — it died in the spawn with
`CreateProcess failed for "…\claude.exe" (last error: 206)`. Closing the project
made the same question work, which made the bug look like it was about the
project and not about the message.

Error 206 is `ERROR_FILENAME_EXCED_RANGE`, and despite the name it is not a path
problem: `CreateProcess` returns it when the command line passes 32767
characters. The prompt was the last token of that command line, and the prompt
carries the rendered project context — whose active-unit body alone is capped at
32 KB (`ProjectContextBuilder.ACTIVE_UNIT_MAX_BYTES`). That cap is already one
byte past what a command line can hold, before the executable, the flags and the
quoting are added. Hence the exact correlation: with no project open the context
degrades to a single short line and the same prompt fits.

The prompt now travels on **stdin** for Claude Code, which reads it there and
which the dispatcher has always opened a pipe for (it just closed it empty). A
dedicated writer thread feeds it, so a payload larger than the pipe buffer cannot
deadlock against a child that writes output before draining its input. Off the
command line, the 32 KB limit no longer applies at all.

Each driver declares its own answer (`IExecutorProfile.PromptViaStdin`), because
where a CLI accepts its prompt is that CLI's dialect: Codex, Copilot, Gemini and
the local agent CLI keep the command line, unchanged, until their stdin form can
be verified against a real binary. For those, an over-long command line is now
refused up front with a message that says what actually happened, instead of
surfacing as a bare `last error: 206`.

## [1.5.1] - 2026-08-10

**Two things the addon store and the MCP list disagreed about.** Both were found
on a machine running Delphi 10 Seattle and Delphi 13 side by side, one day after
1.5.0 reached it.

### Fixed

**On Seattle and Berlin, an installed MCP addon was invisible — and the agent
could not reach it.** The Desktop MCP was missing from `/MCP` on Delphi 10 while
the same user profile's Delphi 13 listed it, reading the very same file.

The cause is in the old RTL: on **10 Seattle (17.0)** and **10.1 Berlin (18.0)**,
`TFile.ReadAllText(path, TEncoding.UTF8)` discards the first three bytes of a
file that carries no BOM — it charges the preamble whether or not the file paid
it. **10.2 Tokyo (19.0)** and up return the file whole (measured on all six).
The addon aggregate is written UTF-8 *without* a BOM on purpose, so on those two
IDEs it arrived with its opening brace gone, failed to parse, and degraded to
"no servers" — in the modal **and** in the `.mcp.json` handed to the CLI, which
is how the agent lost the addon's tools there.

It now reads the bytes and strips a BOM only when one is present — the method
the in-IDE gateway already used, which is why the tools inside the IDE kept
working while the config leg went silent.

**The store said "Update" on a current addon, forever.** The installer seeds the
Desktop MCP offline from a copy this repository builds, and the catalogue decided
the button by comparing sha256 with the gallery. Two honest builds of the same
version have two different sha256, so every freshly installed machine was told
to update an addon that was already the newest release.

The button now answers the question a user actually reads in it — *is there a
newer release?* — by version. `aefos update <slug>` still compares sha256, so a
re-published bundle can be pulled deliberately; only the catalogue stops calling
a rebuild an upgrade.

## [1.5.0] - 2026-08-10

**Every RAD Studio from Delphi 10 Seattle up, and an addon store inside the IDE.**
The installer now carries eight payloads (17.0 Seattle through 37.0), each built
against its own compiler, and the chat grew an `/addons` window that browses and
installs bundles without leaving the IDE.

### Added

**Delphi 10 Seattle, 10.1 Berlin, 10.2 Tokyo, 10.3 Rio and 10.4 Sydney (BDS 17.0
to 21.0).** Reaching back a decade cost less than it looks: nothing in the RTL
Aefos uses is newer than XE8, the WebView2 layer is our own COM import rather
than `Vcl.Edge`, and the source has been free of inline `var` by house rule. What
did have to change was measured, never guessed — static SQLite is now detected in
the project instead of assumed from the version, an IDE with no C++ personality is
named as such instead of failing on a missing `stdint.h`, DFM character escapes
are written in decimal (Seattle rejects hex), and the BPL staging hook moved to
`_PostCompileTargets`, inside the `Base` group, where an old IDE's own build
engine still reads it.

Installed and run on a Delphi 10 Seattle machine, not merely compiled for it.

**The addon store, in the chat.** `/addons` opens a window that lists what an
Aefos store offers, installs a bundle, and updates one already installed —
including an MCP addon whose server is running at that moment. There is one
official store nobody can move, and the user's own stores beside it: add one by
picking a folder, and a folder that *is* an addon is read as a store of one. A
Format tab documents the bundle format where the addons are, and an installed
addon's tools reach every executor, namespaced `<slug>__<tool>`.

`/install` and `/store` still answer, but the command the picker offers is
`/addons` — the word the product already uses for the store, for the contract and
for `~/.aefos/addons`.

**One bundle format: `addon.json` v1.** A bundle may carry several commands and
several skills. The four foreign-plugin readers are gone: reading someone else's
format made Aefos responsible for four moving contracts it does not own.

### Fixed

**Two RAD Studios were answering for each other's packages.** Every BPL carried
the same file name on every version, so whichever install came first on `PATH`
served them all — a Seattle IDE could load Sydney's Core and die as an access
violation with no visible parent. Each BPL now carries the IDE's own suffix
(`Aefos.MCP.Core230.bpl` … `370`), each IDE's search path points at its own
folder, and an unsuffixed BPL is refused from inside the IDE too, where no build
script can reach. The suffix is gated on `VERxxx`, because `CompilerVersion` is
not declared inside a `.dpk` and an `{$IF}` on it is silently always true.

**A link in a chat message navigated the chat away**, taking the transcript with
it. A link now opens the file.

**The store window opened blank, or not at all.** It is shown modeless — a
WebView2 control never completes its initialization under `ShowModal` — and it
receives its own user-data folder and its configuration before anything can
allocate its handle.

**Installing from a folder store copied the bundle** instead of registering it,
so a change at the source never reached the install.

**The addon manager (`aefos.exe`) did not build below Delphi 12.** Two
structurally identical `reference to procedure` declarations are two different
types, which Athens forgives and Delphi 11 does not; the addon stack now declares
one log type and aliases it everywhere else.

**A published Python tool installed where the loader did not look.**

## [1.4.0] - 2026-08-05

**Delphi 13's 64-bit IDE is supported.** Aefos now installs into the 64-bit IDE
as well as the classic 32-bit one, with its own set of packages.

### Added

**Delphi 13 (BDS 37.0), 64-bit IDE.** Delphi 13 ships two IDE executables, and a
design-time package is loaded into the IDE *process* — so a 32-bit package is
invisible to the 64-bit IDE and always was. The installer now carries a second set
of packages built for Win64, installs them into `Bpl\Win64`, and registers them
under the `Known Packages x64` key the 64-bit IDE reads. Confirmed running: chat
panel, WebView2 rendering and the MCP server, all inside the 64-bit process.

Nothing changes for the 32-bit IDE, and the two sets coexist: different files,
different folders, different registry keys.

### Fixed

**The 64-bit build reported version 1.0.0.** Delphi writes a default version block
for every new platform configuration, and the version bump deliberately skipped
untagged blocks — correct while only the 32-bit build shipped, wrong the day the
64-bit one did. The 64-bit blocks now carry the same keys as the 32-bit build.

## [1.3.0] - 2026-08-05

**Delphi 11 Alexandria is supported.** The installer now carries a BDS 22.0
payload beside 23.0 and 37.0, built and proven in a Delphi 11 VM from this
repository.

### Added

**Delphi 11 Alexandria (BDS 22.0)**, with one feature withheld: **inline
completion (ghost text) needs Delphi 12 or newer.** It is built on
`ToolsAPI.Editor.INTACodeEditorEvents.PaintLine`, and that unit does not exist
before Athens. Everything else — Chat, Terminal, the MCP server, the agent
tools — is present.

### Fixed

**The build scripts did not parse under Windows PowerShell 5.1**, which is what a
stock Windows has. `build-packages.ps1` used `&&` in argument position, which 5.1
rejects at parse time: sixteen errors, nothing runs. Nine scripts also carried
non-ASCII characters with no BOM, and 5.1 reads a BOM-less `.ps1` as CP1252 — so
the third byte of a UTF-8 em dash became a typographic quote, which 5.1 accepts as
a string delimiter, closing the string mid-sentence and turning the rest of the
words into code. Anyone who cloned this repository without PowerShell 7 could not
build it.

**String literals over 255 characters** stopped the compiler on Delphi 11 and
anything older (`E2056`). There were 108, 107 of them in the generated assets, up
to 900 characters each; all are re-chunked to 250, with the payload verified
byte-identical.

**The libvterm objects would not link on Delphi 11.** Its `bcc32c` reaches the
standard streams through the C runtime `FILE` table rather than the helper the
unit already stubs; an empty table satisfies the linker and is never read, since
every stdio call here is stubbed.

**The CLI build scripts gave up on a machine with only Delphi 11**, looking for
37.0 then 23.0 and stopping. They now fall through to 22.0.

**The Lazarus installer shipped a README** into the user's Lazarus folder along
with the 64-bit runtime DLLs. It ships only the DLLs now.

## [1.2.0] - 2026-08-05

**Aefos AI is free software.** The source is published, the licence gate is gone,
and every feature ships enabled. **Delphi 12 Athens (BDS 23.0)** and **Delphi 13
(BDS 37.0)**; the installer detects what you have and lets you pick.

### Changed

**The installer no longer bundles an AI CLI.** 1.1.0 shipped Codex and Gemini
beside the agent so a fresh install was productive immediately. With the source
public that trade stopped being worth it: redistributing third-party binaries
adds licence surface and ships versions that go stale between releases, and the
installer drops from 109 MB to about 5 MB. Aefos is, and is documented as,
**bring your own CLI** — install the one you already use and point Aefos at it,
or leave the path empty and let it be found on PATH.

Nothing is taken away from anyone: the bundled binaries were installed with
`uninsneveruninstall`, so a 1.1.0 user keeps the copy already in
`%APPDATA%\Aefos\bin`. New installs simply do not get one.

### Removed

**The licence gate is gone.** There is no key, no activation, no trial and no
editions: every feature ships enabled, including the Terminal, the MCP server
and the agent tools.

With the source public, the gate had stopped being a lock and become a liability:
under the GPL any fork could remove it in five minutes, while the client kept
registering a machine fingerprint in the maintainer's own database — which
would have meant every build by every stranger phoning home to it.

So the whole feature was removed rather than disabled: the `Aefos.License` package
and its four units, the activation dialog, the menu items, the trial badge, the
"(Pro)" tags, and all 44 call sites across both the RAD Studio and Lazarus
editions. The installer now ships 10 runtime packages instead of 11.

The licence code remains in this repository's HISTORY, in the commit that first
published the source. That is a fact of git, not an oversight.

### Licence

**Aefos AI became free software on 2026-08-05.** The software is now licensed
under the **GNU General Public License version 3**, with two additional
permissions granted under GPLv3 section 7 (`ADDITIONAL-PERMISSIONS.md`):

- the code Aefos generates for you is **yours**, under any licence you choose,
  including a proprietary one — using Aefos places no obligation on what you
  build with it;
- linking with the Embarcadero RAD Studio libraries is expressly permitted,
  without which a design-time package could not be distributed at all.

Until this date the software was proprietary, governed by an EULA. That agreement
is kept in the repository as `EULA-historical.md` — the record of what the licence
used to be, not a document that still governs the software.

Releases continue to be published from this repository.

### Fixed

Publication left references behind, and they are corrected here: the chat package
listed two test units under a directory that is not published, so a DEBUG build
could not resolve them; the Lazarus register still declared a License menu and
described it in four comments; the third-party notices pointed at vendor
directories for components that ship embedded in a `.pas`; and `CONTRIBUTING.md`
still told visitors the source was private, on the page GitHub links from every
new issue and pull request.

The READMEs advertised Delphi 11 support, which had never been built. They now say
12 and 13, which this release ships and was built from this tree.


## [1.1.0] - 2026-07-15

**Aefos AI now works out of the box.** This release bundles a ready-to-use AI CLI right in the installer, so a fresh install is productive immediately — no separate CLI download, no PATH setup. **Delphi 12 Athens (BDS 23.0)** and **Delphi 13 (BDS 37.0)**; the installer detects your installed versions and lets you pick.

**New — a ready-to-use AI CLI is bundled**
- The installer ships **Codex** (and **Gemini**) beside the Aefos agent, installed to your user profile. After setup, open Tools → Options → Aefos → AI Chat and Codex is already selected and working — the executor path can stay empty; Aefos finds the bundled binary.
- The binaries are refreshed to the current upstream version at each Aefos release (evergreen), not frozen — you always get a recent build, and updating your own CLI keeps working exactly as before.
- Prefer your own install? A CLI you already have on PATH still takes precedence over the bundled one, so nothing changes for existing setups.

**How the CLIs are provided**
- **Codex** and **Gemini** are bundled (both Apache-2.0). Gemini has no official Windows binary, so Aefos compiles a standalone one from the published package.
- **GitHub Copilot** can be **downloaded during setup** — an optional checkbox fetches its official release directly, with an integrated progress page (Aefos never repackages it; Copilot needs its own subscription).
- **Claude Code** is user-supplied: Aefos detects it on PATH, and the one-click **Download CLI** action in Options opens the official page.

**Under the hood**
- New resolver step: a bundled CLI in your Aefos user folder resolves with zero configuration, after PATH so your own install always wins.
- The AI Chat settings (executor, model, path) are confirmed IDE-wide per user profile — editable on the Welcome page with no project open.

Carried forward from 1.0.0: the in-house clean-room WebView2 engine (Chat + MCP Tool Inspector), installed-addon MCP merge, the Reasoning Effort selector, the 17 live debugger tools, local models (Ollama), the live Form Designer tools, RULE #1 intent-guard, and the change-review gutter.

## [1.0.0] - 2026-07-15
**Aefos AI leaves beta** — the first stable release.

### Added
- **Our own WebView2 engine.** The Chat and the MCP Tool Inspector now render on an
  in-house, clean-room WebView2 integration built directly on Microsoft's public COM
  API — decoupled from any specific RTL edition, opening the path to older Delphi
  releases (and, ahead, Lazarus).
- **Installed addons show up everywhere.** `aefos install <addon>` now reaches both the
  Chat and the raw terminal: the addon's MCP servers are merged into the project
  configuration automatically, and a read-only **MCP Servers** panel lists what the
  agent can reach.
- **Reasoning Effort selector.** For CLIs that expose it, pick the reasoning effort in
  the chat footer next to the model pill; remembered per executor.
- **Download CLI link.** A subtle link under the Executor path field opens the official download page for the
  selected CLI — the plugin still bundles none and owns no credentials.

### Fixed
- Typed model labels are normalized to real model ids before reaching the CLI, and the
- Agent mode now works with CLIs that sandbox MCP tool calls: some CLIs auto-deny
  MCP calls in non-interactive turns ("user cancelled MCP tool call"); the agent
  dispatch now grants the CLI the access it needs — safety stays in the Aefos guards.
  suggested model list was re-seeded to currently valid entries.
- The Gemini / Ollama provider box in the AI Chat options no longer clips its
  bottom link.
- `aefos --version` now reports the real product version.

### Changed
- A broad internal code-quality overhaul across the entire codebase — no behavior
  change, a cleaner foundation for what comes next.


## [0.30.0-beta] - 2026-07-12
The biggest release since the plugin launched: the agent can now **drive the Delphi
debugger**, and it can run entirely on **local models** — no cloud, no key.

### Added
- **The agent debugs your code — 17 debug tools, live in the IDE.** It sets and clears
  breakpoints (conditional ones too), runs and stops the project, walks the code with
  step-over / step-into / step-out, reads the call stack and local variables, and
  evaluates expressions in the current frame — the same loop you would do by hand,
  driven from chat or the terminal. Ask it to *"find why this returns nil"* and it
  actually breaks, inspects state and tells you, instead of guessing from the source.
- **Local models (Ollama).** Pick **"Local models (Ollama)"** in the AI Flow options and
  the chat runs against your own machine. **Test CLI** pings your Ollama and fills the
  model list with the models you actually have installed. Free tier — no API key, and
  nothing leaves your computer.

### Fixed
- **The Form Designer is no longer bypassable.** `SetDFMContent` could be used to author
  UI as raw DFM text — controls that never sprout in the Designer, fields Delphi never
  declares. The tool now refuses it and steers the agent to the proper Design-mode tools,
  so a form the agent builds is a form the Designer really owns.
- **The terminal no longer freezes on Ctrl+D.** The bundled `claude` profile ran the CLI
  as the root of the terminal session; exiting it with Ctrl+D left the session alive but
  dead inside, and the terminal hung. The profile is gone — open your AI CLI inside a
  normal shell instead, where exiting it just returns you to the prompt. An existing
  profile is removed for you.
- **The chat no longer gets stuck on "working…" after switching provider**, and Stop is
  guarded so it cannot strand the composer.
- **Local models never spawn the wrong CLI** — a stale shared executor path could launch
  a foreign CLI for an Ollama run.

### Changed
- The bundled agent CLI got a leaner tool catalog, better orientation and conversation
  compaction, so long sessions stay coherent and cheaper.

> ⬇️ Free edition: <https://www.pubpascal.dev> · 💎 Subscription plans (Pro): <https://isaquepinheiro.com.br/>

## [0.29.0-beta] - 2026-07-07
### Fixed (refresh 2026-07-08 — installer assets updated in place)
- **MCP now connects on default-policy Windows.** The stdio↔pipe bridge is launched
  with `-ExecutionPolicy Bypass`; a `Restricted` policy (the Windows client default)
  used to kill it at startup, so every CLI reported "handshaking with MCP server
  failed: connection closed".
- **"Test MCP" is now truthful for Codex.** It performs a live MCP handshake through
  the same per-run wiring the chat uses, instead of probing `codex mcp list` (which
  can never see it) and always reporting "aefos not found in this project".
- **The chat header honors your saved executor on the Welcome page.** The model list
  showed the default executor's models and a picked model never took until the first
  message; the header now resolves the executor exactly like sending does.
- **Fixed an IDE crash from the Terminal "Test MCP" button** (`External exception
  C0150014`, then "Unknown Hard Error" on IDE close). The MCP host is no longer
  restarted on a no-op apply, and its shutdown can no longer deadlock against an
  in-flight tool call.
- **The Login button now shows "Logged in"** when the Codex CLI reports an
  authenticated session.
- **Codex model list refreshed to the current generation** (`gpt-5.5`, `gpt-5.4`,
  `gpt-5.4-mini`) — the backend retired the old `gpt-5-codex`/`gpt-5` slugs. An
  untouched old list migrates automatically; a customized list is never modified.
- **"Test CLI" now discovers the models your account actually supports** — for
  Codex it reads the CLI's own per-account catalog and fills the model list
  ("Connected … - N model(s) on your account"), the same way the Ollama Test
  fills the list from your local models. CLIs that publish no list keep the
  curated suggestions plus the "+" button.

> ⬇️ Free edition: <https://www.pubpascal.dev> · 💎 Subscription plans (Pro): <https://isaquepinheiro.com.br/>

### Fixed
- **Sending from the Welcome page now works.** With no project open, the chat used
  to echo your message and silently do nothing (the report behind most 0.28.0
  complaints). The agent now answers from the Welcome page and can even open or
  create the project for you.
- **A stuck "working..." never bricks the chat again.** If the completion signal is
  ever lost, the composer detects the stale state and heals itself; your typed text
  is preserved.
- **Blank assistant bubbles auto-recover.** A corrupted chat page (the cause of
  empty responses) is detected and reloaded automatically, replaying the conversation.
- **Garbled characters fixed** (`â€"` instead of `—`) in the consent dialog title,
  the audit log and the tool descriptions the agent reads.

### Added
- **Send while the agent works.** Type and press Enter mid-run: the message shows as
  a bubble at once, a "⏳ N messages queued" line tracks what's waiting, and each
  queued message dispatches automatically as its own turn when the current one
  finishes — the agent keeps the full conversation context. **Stop cancels only the
  current turn**; queued messages survive and run next. Starting a new session (or
  switching Chat↔Agent) discards the leftover queue.
- **`.pas` ↔ `.dfm` desync guard.** Bulk writes that would orphan a component (form
  declares it, code doesn't) are refused with a machine-actionable reason, steering
  the agent to the proper Design-mode tools.

### Changed
- **Faster first reaction on screenshot prompts.** The agent is instructed to start
  building immediately (project first, then component by component) instead of
  planning in silence.

## [0.28.0-beta] - 2026-07-04

### Added
- **Screenshot the form (`CaptureForm`).** The agent can capture the live form
  designer to *see* what it built.
- **Design↔Code guidance.** The agent receives advisory next-prompts that conduct it
  smoothly through the Design/Code flow.
- **`SetComponentProperty` accepts named constants.** Set a `TColor`/`TCursor` by
  name (e.g. `clSkyBlue`, `crHandPoint`), not just a raw value.

### Changed
- **Change-review gutter (the Cursor-style ✓/✗ diff).** Real unified-diff `+`/`-`
  markers; per-unit review state (opening another file no longer disturbs a review
  in progress); "Wait for my approval" is honoured (a save never silently
  auto-accepts); `InsertCodeAtCursor` and `ReplaceEditorSelection` now route through
  the same review gate; a pending change re-anchors when you edit the lines above it.
- **Smarter Save-All guard.** Aefos refuses a Save-All while a `.dfm` event still has
  no handler (no more "handler does not exist — remove the reference?" popup); the
  guard also covers Save-Active-File.
- **`AddComponent` requires a Parent** — components land where you intend, first time.

### Fixed
- Audit-remediation robustness pass: UTF-8 no longer truncated mid-character on large
  frames; the whole edit buffer is read (256 KB cap removed);
  `_RefreshModuleFromDisk` no longer clobbers an unsaved sibling buffer; the pipe
  send timeout scales to the frame size; consent prompts are interpreter-aware and
  tool descriptions are honest about what each tool does.

## [0.27.0-beta] - 2026-06-29

### Fixed
- **IDE version reported correctly.** `GetIDEVersion` no longer hard-codes "13.0";
  it reports the actual running IDE (Delphi 12 / BDS 23.0 → 12.0; Delphi 13 /
  BDS 37.0 → 13.0).
- **Terminal find-bar teardown** — fixed a use-after-free (the `pnlFind` window-proc
  subclass was never restored before the panel was freed).

### Changed
- The MCP workspace facade (an 8,200-line god-object) was decomposed into **24
  focused SOLID services** — a pure delegation shell (−86%), every step validated
  and build-clean on D12 + D13.
- New **`WithLiveSource`** harness seam: all six code-write tools flip the IDE to
  Code and edit the live buffer through one battle-tested transaction.
- The terminal dock form (4,400 lines) was decomposed into **5 focused helpers** (−26%).
- Debug breadcrumbs no longer ship in release builds; dead code removed.

## [0.26.0-beta] - 2026-06-24

### Added
- **Manage your Python tools from the IDE (Pro).** A new **Aefos PyTools** item in
  the IDE **View** menu opens a manager to **create, edit and delete** the Python
  tools the agent can use (in both Chat and Terminal) — no more hand-editing files.
  Each tool stays a folder under `%APPDATA%\Aefos\pytools` (`tool.json` + `main.py`);
  the manager writes them for you. New tools load on the next MCP session.

## [0.25.1-beta] - 2026-06-24

### Changed
- **Issue reporting is now opt-in.** A new **Issue reporting** toggle in
  **Tools → Options → Aefos → AI Flow** controls whether the agent's bug/suggestion
  dialog (`ProposeAefosIssue`) can open. **Off by default** — turn it on to send
  feedback; otherwise the agent can never pop the dialog.

## [0.25.0-beta] - 2026-06-24

### Added
- **Built-in project templates.** The agent (and the chat **New Project** picker)
  scaffolds a ready-to-build project from a template: **Console, VCL, FMX, Library,
  Package, DUnitX**. Each renders the name you choose, ships a clean `.dproj`, and
  gets a fresh project GUID so two projects from the same template never collide.
  Installed to `%APPDATA%\Aefos\templates` — drop your own folder there to add one.
- **DUnitX projects come ready to run.** A new DUnitX test project includes the
  canonical runner (console + NUnit-XML loggers, RTTI discovery) **and** a sample
  `[TestFixture]`, so it builds and runs a test out of the box.
- **Report an Aefos issue from the agent.** When it hits a genuine defect the agent
  can *propose* a bug/suggestion: an editable window opens (your text pre-filled,
  IDE/Aefos/OS versions attached) and **Send** opens a pre-filled GitHub issue for
  you to review and submit. The agent never files anything itself.

## [0.24.1-beta] - 2026-06-24

### Added
- **Auto-approve tool permissions.** A new "Tool permissions" mode in
  **Tools → Options → Aefos → AI Flow**: *Ask every time* (default), *Auto-approve
  edits, ask before destructive*, or *Auto-approve everything*. Works for both Chat
  and Terminal; auto-approvals are still recorded in the audit log.

### Changed
- **Cleaner AI Flow options page** — reorganized into clear sections (Tool
  permissions, Agent edits, IDE behavior, Diagnostics).

## [0.23.0-beta] - 2026-06-22

### Fixed
- **Black Chat panel, attacked at the root.** The Microsoft WebView2 loader
  (`WebView2Loader.dll`) is now **shipped next to the plugin** and loaded by full path,
  so it's found even when it isn't beside the IDE executable (a cause of the black panel
  on some Windows 10 machines).

### Changed
- **The installer now checks the WebView2 Runtime up front.** If it's missing, setup
  **stops with a clear message and the download link** instead of installing into a panel
  that can't render — and it tells you explicitly when the machine is **offline** (so you
  know it couldn't download or verify it). Install the Runtime, then re-run setup.

## [0.22.0-beta] - 2026-06-22

### Added
- **WebView2 diagnostic trace toggle** in **Tools → Options → Aefos → AI Flow**. If the
  Chat panel ever shows a blank/black screen, turn this on to capture a diagnostic log
  (`%TEMP%\aefos_comp.log`) to send with a bug report — no need to touch environment
  variables. Leave it off for normal use.

## [0.21.0-beta] - 2026-06-21

### Added
- **The Chat welcome shortcuts now do real work.** Explain, Refactor, Test, Document,
  Find and Optimize each run a focused, built-in command — **Refactor / Test / Document /
  Optimize apply their changes through the editor** so they show up in the change-review
  for you to accept or reject; Explain and Find answer read-only. They're also available
  by typing `/` in the message box.
- **Polished slash-command picker.** Typing `/` shows a tidy panel — header, scrollable
  list and a footer with the keyboard hints (↑↓ navigate · Enter run · Esc close).

### Changed
- **"Thinking…" indicator** now shows an animated robot while the assistant works, with
  cleaner spacing.
- Clicking a welcome shortcut now fills the message box directly (it previously popped an
  empty bar).

## [0.20.0-beta] - 2026-06-21

### Added
- **See what an AI edit changes before you accept it.** When the assistant edits
  your code, the change now shows inline as a **before/after diff** — the original
  lines struck out in red, stacked above the new lines in green — so you can tell at
  a glance what was replaced (works for wide and multi-line edits).
- **Per-change Approve / Reject / Annotate, right in the gutter.** Each pending change
  gets ✓ (keep), ✗ (undo) and ✎ (leave a note) controls, plus an **Approve All / Reject
  All** pill. Multiple changes accumulate without blocking the assistant.
- **Your notes reach the assistant.** A note you attach to a change is delivered back
  to the AI, tagged as approved or rejected, so it learns your feedback on each edit.
- **Available in both Chat and Terminal.** The change-review works the same in the AI
  Chat and the AI Terminal.

### Changed
- **Saving accepts pending changes.** Saving the file (or running) keeps the new text
  and clears the review markers — it never writes a half-reviewed, duplicated file.

## [0.19.1-beta] - 2026-06-20

### Fixed
- **No more crash on a click in the Chat right after it opens.** A mouse event
  arriving while the WebView host was still initialising could raise an error inside
  the IDE; mouse input is now ignored until the host is ready (and never fatal).

## [0.19.0-beta] - 2026-06-20

### Fixed
- **Chat no longer shows a black panel on machines where it failed to render.** GPU
  compositing is now **off by default** (it was the cause of the black screen on some
  GPUs/drivers/VMs — the Chat is text, so there's no visible cost), and if the WebView2
  host still can't start, the Chat **falls back to plain text with a clear "install
  WebView2" notice** instead of a black panel.
- **Docked Chat/Terminal reliably comes back.** If the pane disappears after a
  desktop/layout switch, clicking its menu entry now brings it forward again (it used
  to stay hidden until you switched profiles or restarted the IDE).
- **About dialog no longer clips its last line** (Chat and Terminal) — it sizes to
  its content.
- **Version is consistent across Chat and Terminal** (the splash/About showed
  mismatched versions before).

### Changed
- **Chat/executor settings are now editable without an open project** (on the
  Welcome page) — they are machine-global, so you can pick your AI CLI, path, model
  and log in before opening any project.
- **Smoother Chat first-open**: a dark "Loading…" placeholder replaces the brief
  black flash while the WebView2 engine warms up; the panel background paints dark
  from the first frame.
- **More tools show the reviewable diff**: inserting a method now routes through the
  same inline red/green diff (accept/reject, with an optional reason) as editing.
- **Installer only asks you to close RAD Studio when it's actually running** (no more
  unconditional prompt).

### Notes
- Advanced: set `AEFOS_WEBVIEW_ENABLE_GPU=1` to opt back into GPU compositing if your
  machine has a good GPU.

## [0.18.0-beta] - 2026-06-20

### Added
- **Reject with a reason.** When you reject an agent's inline edit, a themed
  dialog (matching the IDE's dark/light theme) asks for an optional note — and
  that note is sent back to the agent, so it learns *why* the change was refused
  instead of just *that* it was.
- **Reveal on code insertion.** Tools that write code (`AddEventHandler`,
  `InsertMethod`, insert-at-cursor) now flip the IDE to Code view and scroll to
  the freshly written method, so what the agent wrote is on-screen — not buried
  below the form's component declarations.

### Changed
- **Inline diff scrolls to the change.** When a diff appears it now jumps to the
  first changed line, so the red/green block and its Accept/Reject buttons are
  always visible (no more hunting for them).
- **Cleaner generated code.** Event handlers added by the agent are now separated
  by a single blank line (the IDE convention), not two.

### Fixed
- **Editor crash on diff preview.** Fixed an access violation (use-after-free in
  the editor's diff painting) that could crash the IDE while previewing an inline
  edit.

## [0.17.0-beta] - 2026-06-19

### Added
- **Composition-hosted WebView2** (`TAefosWebView`) for the docked Chat — renders
  smoothly while docked, fixing the blank/flicker on focus changes.
- **Provider drivers** for four AI CLIs: Claude Code, Codex, GitHub Copilot CLI, and
  Gemini, each with its own MCP wiring and remembered model.
- **Design ↔ Code (intent → view)** harness: design-mutation tools end in the Form
  Designer; code-mutation tools end in the editor.
- **Atomic `AddEventHandler`** — creates the handler in the correct section and wires
  the `.dfm` event in one step.
- Node-locked single-seat **licensing** (Community / Pro / Enterprise) with offline
  grace and a built-in trial.

### Changed
- **Inline diff** routing broadened (edit unit, replace-in-editor, full-buffer
  rewrite) with accept/reject (Tab/Esc).
- License terms moved to a proprietary **EULA** with a free Community edition
  (including internal business use).

### Security / supply chain
- Published a machine-readable **SBOM** (CycloneDX 1.5) and a **security disclosure
  policy** (coordinated vulnerability disclosure).

[Unreleased]: https://github.com/ModernDelphiWorks/Aefos/compare/v1.5.1...HEAD
[1.5.1]: https://github.com/ModernDelphiWorks/Aefos/compare/v1.5.0...v1.5.1
[1.5.0]: https://github.com/ModernDelphiWorks/Aefos/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/ModernDelphiWorks/Aefos/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/ModernDelphiWorks/Aefos/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/ModernDelphiWorks/Aefos/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/ModernDelphiWorks/Aefos/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/ModernDelphiWorks/Aefos/compare/v0.30.0...v1.0.0
[0.30.0-beta]: https://github.com/ModernDelphiWorks/Aefos/compare/v0.29.0...v0.30.0
[0.19.1-beta]: https://github.com/ModernDelphiWorks/Aefos/compare/v0.19.0...v0.19.1
[0.19.0-beta]: https://github.com/ModernDelphiWorks/Aefos/compare/v0.18.0...v0.19.0
[0.18.0-beta]: https://github.com/ModernDelphiWorks/Aefos/compare/v0.17.0...v0.18.0
[0.17.0-beta]: https://github.com/ModernDelphiWorks/Aefos/releases/tag/v0.17.0
