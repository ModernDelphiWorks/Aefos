unit Aefos.OTA.Chat.UnloadContract;

{ ============================================================================
  THE UNLOAD CONTRACT - READ THIS BEFORE TOUCHING ANY TEARDOWN/BINDING CODE
  ============================================================================

  This unit contains NO code on purpose. It is the written record of a chronic,
  expensive bug so that NO maintainer or AI agent ever reintroduces it.

  THE BUG (solved 2026-06-11, by map forensics - not guesswork)
  -------------------------------------------------------------
  Symptom: with the suite installed, simply reopening the IDE and running
  Build All produced:

    [Fatal Error] Access violation at address ... in module 'rtl370.bpl'
    (offset 100C2). Read of address ...
    -> F2039: Could not create output file '...\Aefos.Tools.bpl'
    -> the Chat package silently DEINSTALLED.

  Forensic resolution: rtl370 offset 100C2 disassembles into
  System.TObject.Free (the VMT fetch). The faulting address, resolved with the
  module-base load log + the linker .map, was the VMT/metadata block of
  TAefosAgentKeyboardBinding (the chat's Ctrl+Alt+F10 binding object) inside
  the ALREADY-UNMAPPED chat BPL image. Translation: the IDE destroys a
  package's keyboard-binding objects only AFTER the BPL unmaps. Anything the
  IDE still references at that point reads dead memory.

  THE LAW
  -------
  1. EVERY IOTAKeyboardServices.AddKeyboardBinding MUST be paired with an
     explicit RemoveKeyboardBinding(Index) at teardown, guarded by Supports +
     try/except. NEVER rely on "the IDE auto-unregisters a package's bindings
     on unload" - that belief WAS the bug. An old comment in this codebase
     claimed manual removal "double-frees"; it was wrong and got removed.
     Reference implementations (keep them aligned):
       - Aefos.OTA.Chat.Adapter.AgentSuggest.TAefosAgentSuggestAdapter.UnregisterSelf
       - Aefos.OTA.Chat.Adapter.MainMenu._UnregisterKeyboardBindings
       - Aefos.OTA.IDE.GutterReview.UnregisterGutterReview
         (migrated 2026-06-21 from Aefos.OTA.Chat.IDE.DiffPreview to the shared
          Aefos.MCP.Tools.OTA BPL; teardown now in that unit's finalization)
       - Aefos.OTA.Terminal.UI.KeyBinding (the terminal always did it right -
         that asymmetry, spotted by the maintainer, cracked the case).
  2. Nothing IDE-held may point into this BPL after finalization: notifiers
     (remove by stored index), menu items (free your own), cross-BPL globals
     (nil them), Application.OnMessage / root-form OnShortCut hooks (restore
     them - see the safety net in UI.ChatPanel's finalization).
  3. The 'Aefos AI (Chat)' top-level menu is registered AT BPL LOAD
     (Register._InitChatMenuBar) so it exists on the Welcome page, exactly like
     the Terminal's. This is an explicit, repeated maintainer requirement. It
     was investigated as an AV suspect and PROVEN INNOCENT (the AV persisted
     identically with it reverted). Do not gate it behind project-open. Do not
     revert it. Ever.
  4. Teardown never raises: route every step through Register._GuardedShutdown.

  EXONERATED SUSPECTS (do not re-litigate these)
  ----------------------------------------------
  - The menu-at-load (rule 3) - reverting it changed nothing.
  - The Ctrl+V Application.OnMessage hook - panel-scoped; it is not even
    installed unless the chat panel was opened, and the AV reproduced with
    NOTHING opened.
  - The MCP named-pipe listener threads - they exit cleanly via FCancelEvent;
    gating the dev-session server off changed nothing.
  - FireDAC / Aefos.Data - the connection is lazy; never created in the repro.

  THE FORENSIC TOOLKIT (kept in DEBUG builds - do not strip it)
  -------------------------------------------------------------
  - Per-step teardown breadcrumbs + module-base load log:
    %APPDATA%\Aefos\aefos-teardown.log (Register._TeardownLog /
    _LogAefosModuleBases). The last '>>' without a '<< done' is a hanging
    step; all steps done but still crashing means the IDE touched something
    of ours AFTER finalization.
  - DCC_MapFile=3 in the chat/data .dproj: AV address - logged module base
    = RVA; map segment 0001 offset = RVA - $1000; the nearest symbol names
    the dangling object. 'Unit..TClass' map symbols are class VMT/metadata.
  - rtl370.bpl's PE export table names the faulting RTL routine from the
    dialog's offset (e.g. 100C2 => System.TObject.Free).

  If you change teardown behaviour, prove it with one full cycle:
  install -> close IDE -> reopen -> Build All. Clean means NO AV dialog,
  NO F2039, package still installed.
  ============================================================================ }

interface

implementation

end.
