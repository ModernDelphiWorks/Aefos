unit Aefos.OTA.Chat.Core.BuiltInCommands;

{$IFDEF FPC}{$mode delphi}{$H+}{$ENDIF}

(*
  Built-in slash-commands - the SINGLE registry for every reserved /command
  (NOT the stored .aefos ones). Both kinds live here so the picker and
  the dispatch read one list:

    - bikUIModal (/new, /reset, /memory, /mcp, /command): LISTED here for the
      picker, but the behaviour stays bespoke in ChatPanel._DispatchCommand
      (each opens a different modal / resets the session). Only Name+Description
      matter for these.
    - bikAgentic (/new-project): carries a Guide injected at dispatch as the
      prompt body (the agent then drives the flow with the MCP tools); may
      ForceAgent.

  ADD A BUILT-IN = add ONE TBuiltInCommand to BuiltInCommands below. The
  consumers all read this table (no name hardcoded elsewhere):
    - ChatPanel picker feed         : lists every entry (+ the registered ones).
    - ChatPanel dispatch            : forces Agent when an agentic one ForcesAgent.
    - CommandExecutor._PrepareContext : injects Guide for agentic ones.
  (UI-modal behaviour still lives in _DispatchCommand - a modal opener can't be
  tableised in a pure unit; only the LIST is centralised here.)

  Guide text must be ASCII (no UTF-8 BOM trap). Pure: RTL only - no ToolsAPI,
  no VCL.
*)

interface

type
  // bikUIModal — handled bespoke in ChatPanel._DispatchCommand (modal / reset).
  // bikAgentic — dispatched to the CLI with Guide as the prompt body.
  TBuiltInKind = (bikUIModal, bikAgentic);

  TBuiltInCommand = record
    Name: string;         // the slash-command name, e.g. 'new-project'
    Description: string;  // shown in the slash picker
    Kind: TBuiltInKind;
    Guide: string;        // agentic only: prompt-guide injected as the body (ASCII)
    ForcesAgent: Boolean; // agentic only: auto-switch to Agent before dispatch
  end;

// The single table of ALL built-in slash-commands (UI-modal + agentic). The
// picker lists every entry; dispatch routes by Kind. Add a built-in = add ONE
// entry here.
function BuiltInCommands: TArray<TBuiltInCommand>;

// True when AText is a built-in command - bare ('new-project') or with trailing
// args ('new-project a REST server'). ACmd receives the matched command;
// AUserText receives whatever was typed after the command name.
function FindBuiltInCommand(const AText: string; out ACmd: TBuiltInCommand;
  out AUserText: string): Boolean;

implementation

uses
{$IFDEF FPC}
  SysUtils;
{$ELSE}
  System.SysUtils;
{$ENDIF}

const
  // /new-project - scaffold a whole project from a template folder. The {"Name"}
  // below is a string literal, not a comment, so the braces are safe.
  NEW_PROJECT_GUIDE =
    'You are helping the developer create a NEW Delphi project from a ' +
    'template. Use the MCP tools to do it - never write the project ' +
    'boilerplate yourself.' + sLineBreak + sLineBreak +
    'Flow (ask the developer in their own language, and skip anything they ' +
    'already told you):' + sLineBreak +
    '1. Call ListProjectTemplates to see what is available (each template has ' +
    'id, name, category, description, vars). If there are many, group them by ' +
    'category (VCL / FMX / Package / Console...) and ask which type first, then ' +
    'which template; if only a few, just list them and ask which one.' +
    sLineBreak +
    '2. Ask for the template variables you still need - ALWAYS including the ' +
    'project Name - and ask WHERE to save it (the target directory). The save ' +
    'location is what completes the request.' + sLineBreak +
    '3. Call CreateProjectFromTemplate with template_id, target_dir (the save ' +
    'location) and vars (e.g. {"Name":"MyApp"}). It writes the files and opens ' +
    'the new project in the IDE automatically.' + sLineBreak +
    '4. Tell the developer what was created and where (project_path).';

  // /suggest - review the developer's current editor selection (Ctrl+Alt+F10).
  // The selected code is appended by the executor after this guide.
  SUGGEST_GUIDE =
    'You are reviewing a block of Delphi code the developer SELECTED in the ' +
    'IDE (it follows below). Suggest concrete, high-value improvements - not ' +
    'generic advice.' + sLineBreak + sLineBreak +
    'Prioritise, in order:' + sLineBreak +
    '1. Correctness & safety: real bugs, missing try/finally, leaks, ' +
    'use-after-free / dangling references, unhandled exceptions.' + sLineBreak +
    '2. Clarity & simplification: dead code, redundancy, unclear names, ' +
    'over-complex control flow.' + sLineBreak +
    '3. Delphi idioms: interfaces/RAII over manual lifetime, generics, RTTI, ' +
    'string/array handling, const params.' + sLineBreak +
    '4. Performance only where it actually matters (hot paths, allocations in ' +
    'loops).' + sLineBreak + sLineBreak +
    'Rules:' + sLineBreak +
    '- Each suggestion: one short line on WHY, then the improved code.' +
    sLineBreak +
    '- Keep the existing style and conventions; do not rewrite wholesale.' +
    sLineBreak +
    '- Answer directly from the selection in ONE reply - do not call tools or ' +
    'fetch more files; speed matters here.' + sLineBreak +
    '- If the code is already clean, say so in one line - do not invent ' +
    'nitpicks.';

  // The welcome-screen / toolbar shortcuts. Each operates on the developer's
  // current selection (appended by the executor) when present, else on whatever
  // they name after the command. The edit-y ones (refactor/test/docs/optimize)
  // APPLY via the MCP editor tools so the result lands in the inline change-review.

  // Shared change-review contract - ONE wording reused by the edit-y commands
  // (/refactor, /test, /docs, /optimize) so the "apply via tools, not in chat"
  // rule never drifts between them. ASCII only (see the unit note above).
  APPLY_VIA_TOOLS_RULE =
    '- APPLY the result with the MCP editor tools (EditUnit) so it appears in the ' +
    'inline change-review for the developer to accept or reject - do NOT just ' +
    'print the code in the chat.';

  // /explain - read-only: explain the selection / named code.
  EXPLAIN_GUIDE =
    'You are explaining Delphi code to the developer. If a block is SELECTED in ' +
    'the IDE it follows below; otherwise explain whatever the developer names.' +
    sLineBreak + sLineBreak +
    '- Explain WHAT it does and WHY, in plain language, top-down: the big picture ' +
    'first, then the notable details.' + sLineBreak +
    '- Call out side effects, lifetime/ownership, exceptions and any non-obvious ' +
    'Delphi idioms at play.' + sLineBreak +
    '- Answer in ONE reply from what you were given; do NOT change code.' +
    sLineBreak +
    '- Be concise; skip the trivial lines.';

  // /refactor - edits via tools -> shows in the change-review.
  REFACTOR_GUIDE =
    'You are refactoring Delphi code for the developer. If a block is SELECTED it ' +
    'follows below; otherwise act on what the developer names.' +
    sLineBreak + sLineBreak +
    '- Improve clarity and structure WITHOUT changing behaviour: clearer names, ' +
    'smaller routines, less duplication, better control flow, idiomatic Delphi ' +
    '(interfaces/RAII, generics, const params).' + sLineBreak +
    APPLY_VIA_TOOLS_RULE + sLineBreak +
    '- Keep the existing style; refactor in small, reviewable steps.' + sLineBreak +
    '- Do not invent features or touch unrelated code.';

  // /test - creates/edits tests via tools -> change-review.
  TEST_GUIDE =
    'You are writing tests for the developer''s Delphi code (selection follows ' +
    'below if any; otherwise use what they name).' + sLineBreak + sLineBreak +
    '- Identify the unit/class/routine under test and the meaningful cases: happy ' +
    'path, edge cases, error paths.' + sLineBreak +
    '- Use the project''s existing test framework/conventions if present (look ' +
    'first with the MCP tools); otherwise DUnitX.' + sLineBreak +
    APPLY_VIA_TOOLS_RULE + sLineBreak +
    '- Keep tests focused and readable; one assert intent per test.';

  // /docs - adds documentation via tools -> change-review.
  DOCS_GUIDE =
    'You are documenting the developer''s Delphi code (selection follows below if ' +
    'any; otherwise what they name).' + sLineBreak + sLineBreak +
    '- Add clear XMLDoc (///) or comment headers for units, classes and public ' +
    'methods: purpose, parameters, return, raised exceptions, non-obvious ' +
    'behaviour.' + sLineBreak +
    APPLY_VIA_TOOLS_RULE + sLineBreak +
    '- Document WHY, not the obvious; match the surrounding comment style and ' +
    'language. Do NOT change code behaviour.';

  // /find - read-only: locate things via the search tools.
  FIND_GUIDE =
    'You are helping the developer FIND something in the Delphi project. Use the ' +
    'MCP search tools (FindInProject, FindInEditor, FindSymbolUsages, ' +
    'GetProjectManagerTree) - do NOT guess.' + sLineBreak + sLineBreak +
    '- Interpret what they are after (a symbol, a string, a usage, a file) and ' +
    'pick the right tool.' + sLineBreak +
    '- Report each hit as unit / location so it is easy to jump to.' + sLineBreak +
    '- Many hits: group and summarise. None: say so and suggest a broader query.' +
    sLineBreak +
    '- Read-only: report findings, do NOT edit.';

  // /optimize - performance edits via tools -> change-review.
  OPTIMIZE_GUIDE =
    'You are optimising the performance of the developer''s Delphi code (selection ' +
    'follows below if any; otherwise what they name).' + sLineBreak + sLineBreak +
    '- Find the REAL costs: allocations in loops, repeated work, O(n^2) patterns, ' +
    'needless string/array copies, chatty I/O - not micro-noise.' + sLineBreak +
    '- Preserve behaviour; prefer measurable wins over speculative ones.' +
    sLineBreak +
    APPLY_VIA_TOOLS_RULE + sLineBreak +
    '- For each change, say in one line WHY it is faster.' + sLineBreak +
    '- If nothing meaningful can be improved, say so - do not invent.';

  // /modernize - modernise the LOOK of the active form by DRIVING the live
  // designer. This is the Aefos edge over completion-first assistants: they
  // SUGGEST UI changes as text; Aefos APPLIES them so they land in the Object
  // Inspector and the .dfm/.fmx. Design-intent flow (see RULE #1) - the agent
  // opens the designer, reads the form, then sets properties via the DESIGN
  // tools. Static look goes through SetComponentProperty, never FormCreate.
  { /scan -- drive a RUNNING application and let the Visual Scanner show it.

    The scanner card only lights up when the desktop tools are called in the
    order the state machine accepts: a capture BEFORE anything is touched, then a
    real read, then the operation, then a second capture. That ordering is not a
    preference -- it is what makes the card unable to animate over something that
    did not happen. But it left the user having to remember and retype it, and a
    run in the wrong order simply showed nothing, with no hint why.

    So the order lives here, once, and the user writes only what they want tested. }
  SCAN_GUIDE =
    'Drive the RUNNING application with the Aefos desktop tools and let the ' +
    'Visual Scanner follow along. Follow this order EXACTLY -- the scanner ' +
    'advances on real tool results, so a step you skip is a step it cannot show:' +
    sLineBreak +
    '1. desktop_list_windows -- find the target window and note its hwnd.' + sLineBreak +
    '2. desktop_window_capture -- the BEFORE picture. Do this before touching ' +
    'anything.' + sLineBreak +
    '3. desktop_window_tree -- read the REAL control names. Never guess one.' + sLineBreak +
    '4. desktop_invoke / desktop_type_text -- perform what was asked.' + sLineBreak +
    '5. desktop_window_capture -- the AFTER picture.' + sLineBreak +
    'Then read the result from the "value" field of the relevant control (NOT ' +
    'from a screenshot) and report it. If the app is not running, run the ' +
    'active project first.' + sLineBreak + sLineBreak +
    'What to test:';

  MODERNIZE_GUIDE =
    'You are MODERNIZING the look of the developer''s ACTIVE Delphi form (VCL or ' +
    'FMX). Unlike an assistant that only SUGGESTS, you APPLY the changes in the ' +
    'live Form Designer so they land in the Object Inspector and the .dfm/.fmx.' +
    sLineBreak + sLineBreak +
    'Flow (use the MCP tools - never hand-write the form file):' + sLineBreak +
    '1. Call OpenFormDesigner to focus the active form in the Designer (DESIGN ' +
    'view).' + sLineBreak +
    '2. SEE the form: call CaptureForm to get a rendered PNG of the LIVE form. ' +
    'If your model has vision, LOOK at the actual appearance - alignment, ' +
    'overlap, colours, cramped spacing, leftover placeholder captions - not just ' +
    'the property values (VCL only; on FMX it fails clean, so skip it there).' +
    sLineBreak +
    '3. Read the structure: ListFormComponents, GetFormProperties and ' +
    'GetComponentProperties for the notable controls (GetDFMContent for the full ' +
    'picture). Understand the layout before touching anything.' + sLineBreak +
    '4. Apply improvements with SetFormProperty / SetComponentProperty (they set ' +
    'nested paths like Font.Name and write into the live designer):' + sLineBreak +
    '   - Typography: a modern UI font (Segoe UI, 9-10pt) consistently; retire ' +
    'legacy fonts (MS Sans Serif, Tahoma 8).' + sLineBreak +
    '   - Spacing & alignment: consistent margins/padding, aligned edges, sane ' +
    'Anchors/Align so it resizes cleanly; fix cramped or overlapping controls.' +
    sLineBreak +
    '   - Grouping & hierarchy: group related controls, clear visual order, the ' +
    'primary action emphasised.' + sLineBreak +
    '   - Color & theme: a clean, low-noise palette with good contrast; prefer ' +
    'VCL Styles/theming over hard-coded 3D gray where it fits.' + sLineBreak +
    '   - Sizing: comfortable, consistent control heights and button sizes.' +
    sLineBreak + sLineBreak +
    'Rules:' + sLineBreak +
    '- APPLY every change with the DESIGN tools ONLY - SetComponentProperty and ' +
    'SetFormProperty - so it lands in the .dfm/.fmx and the Object Inspector. Do ' +
    'NOT use ExecuteIDEAction or menu actions to change the form, do NOT print ' +
    'property lists in the chat, and NEVER assign static look in FormCreate.' +
    sLineBreak +
    '- Preserve behaviour: do NOT rename components, remove controls, or touch ' +
    'event handlers. Modernize the LOOK, not the logic.' + sLineBreak +
    '- Work in small, reviewable steps and keep the form functional - do not ' +
    'break the layout. If a change is drastic or risky, describe it and ask ' +
    'first.' + sLineBreak +
    '- When done, call CaptureForm once more (VCL, vision models) to CHECK the ' +
    'result and fix anything the image still shows wrong; then summarise briefly ' +
    'what you changed and why.';

function BuiltInCommands: TArray<TBuiltInCommand>;
  function Modal(const AName, ADesc: string): TBuiltInCommand;
  begin
    Result := Default(TBuiltInCommand);
    Result.Name := AName;
    Result.Description := ADesc;
    Result.Kind := bikUIModal;
  end;
  function Agentic(const AName, ADesc, AGuide: string;
    AForcesAgent: Boolean): TBuiltInCommand;
  begin
    Result := Default(TBuiltInCommand);
    Result.Name := AName;
    Result.Description := ADesc;
    Result.Kind := bikAgentic;
    Result.Guide := AGuide;
    Result.ForcesAgent := AForcesAgent;
  end;
var
  LNewProject: TBuiltInCommand;
  LSuggest: TBuiltInCommand;
begin
  LNewProject := Default(TBuiltInCommand);
  LNewProject.Name := 'new-project';
  LNewProject.Description := 'Create a new Delphi project from a template';
  LNewProject.Kind := bikAgentic;
  LNewProject.ForcesAgent := True;
  LNewProject.Guide := NEW_PROJECT_GUIDE;

  LSuggest := Default(TBuiltInCommand);
  LSuggest.Name := 'suggest';
  LSuggest.Description := 'Review the selected code and suggest improvements';
  LSuggest.Kind := bikAgentic;
  LSuggest.ForcesAgent := False;
  LSuggest.Guide := SUGGEST_GUIDE;

  Result := [
    // UI-modal built-ins (behaviour bespoke in ChatPanel._DispatchCommand).
    Modal('new', 'New empty session'),
    Modal('reset', 'Reset the conversation'),
    Modal('memory', 'Edit the memory'),
    Modal('mcp', 'MCP servers'),
    Modal('inspector', 'MCP Tool Inspector'),
    Modal('command', 'Create/edit a command'),
    // Named for what it IS, not for what it does. "addons" is a noun - it says
    // what the window is about, and it is the word Aefos uses everywhere else
    // (the store, the contract, ~/.aefos/addons), so the command carries the
    // product's own identity instead of a generic verb. /install and /store
    // still answer (see ChatPanel._DispatchCommand); only one of the three
    // belongs in the picker.
    Modal('addons', 'Browse and install addons from the Aefos store'),
    // Agentic built-ins (dispatched with a guide).
    LNewProject,
    LSuggest,
    // Welcome-screen / toolbar shortcuts (read-only ones don't force Agent).
    Agentic('explain',  'Explain the selected/named code', EXPLAIN_GUIDE,  False),
    Agentic('refactor', 'Refactor the selected/named code', REFACTOR_GUIDE, True),
    Agentic('test',     'Write tests for the selected/named code', TEST_GUIDE, True),
    Agentic('docs',     'Document the selected/named code', DOCS_GUIDE,     True),
    Agentic('find',     'Find a symbol, string or usage in the project', FIND_GUIDE, True),
    Agentic('optimize', 'Optimise the selected/named code', OPTIMIZE_GUIDE, True),
    Agentic('modernize', 'Modernise the look of the active form (applies in the designer)', MODERNIZE_GUIDE, True),
    Agentic('scan', 'Operate a running app and watch it in the Visual Scanner', SCAN_GUIDE, True)
  ];
end;

function FindBuiltInCommand(const AText: string; out ACmd: TBuiltInCommand;
  out AUserText: string): Boolean;
var
  LName: string;
  LCmd: TBuiltInCommand;
begin
  Result := False;
  ACmd := Default(TBuiltInCommand);
  AUserText := '';
  LName := Trim(AText);
  for LCmd in BuiltInCommands do
  begin
    if SameText(LName, LCmd.Name) then
    begin
      ACmd := LCmd;
      Exit(True);
    end;
    if (Length(LName) > Length(LCmd.Name)) and
       SameText(Copy(LName, 1, Length(LCmd.Name) + 1), LCmd.Name + ' ') then
    begin
      ACmd := LCmd;
      AUserText := Trim(Copy(LName, Length(LCmd.Name) + 2, MaxInt));
      Exit(True);
    end;
  end;
end;

end.
