; ============================================================================
;  Aefos AI - Lazarus edition - Inno Setup installer
;
;  Lazarus does NOT load design packages like Delphi loads design-time BPLs.
;  A Delphi package is a .bpl dropped into a folder and registered in the
;  registry, mapped by the IDE at runtime. A Lazarus design package is instead
;  STATICALLY LINKED into lazarus.exe: installing it means RECOMPILING the user's
;  lazarus.exe with the package in its static list. There is no drop-and-register.
;
;  Up to 0.24.7 we did that IN PLACE: we relinked the USER'S lazarus.exe, edited
;  his config, dropped DLLs in his folder. Milestone 2 stops doing that. This
;  installer now builds a SECOND IDE, entirely inside the user's own profile:
;
;    %LOCALAPPDATA%\Aefos\lazarus\bin\lazarus.exe   <- OUR IDE
;
;  It uses his tree only through --lazarusdir (same LCL, same FPC, same sources -
;  no duplicated tree, no version conflict) and writes NOTHING on his side: not
;  his lazarus.exe, not his config, not even to ADD. Uninstalling is then the
;  removal of ONE directory plus ONE shortcut, and "your IDE is exactly as it was"
;  stops being a restore procedure and becomes an empty diff
;  (proven by the isolated round-trip gate, allowlist EMPTY).
;
;  So this installer does three things:
;    1. Ships the Aefos package SOURCES (the .lpk + the source\ tree it needs), the
;       three runtime DLLs and the PowerShell engines to a STABLE per-user location
;       ({userpf}\Aefos AI\Lazarus). Stable and never %TEMP%: the engines read it
;       again on every later rebuild/repair, and the uninstaller runs from it.
;    2. MIGRATES a machine that still carries the old in-place install - hands the
;       user his stock lazarus.exe back - BEFORE anything of ours is written
;       (PrepareToInstall, so a refusal costs nothing).
;    3. Runs the isolated install engine, which builds our own lazarus.exe into
;       %LOCALAPPDATA%\Aefos\lazarus\bin with the three DLLs beside it and puts one
;       shortcut in the user's own Start menu.
;
;  WHY {userpf} (%LOCALAPPDATA%\Programs) AND PrivilegesRequired=lowest: see the
;  [Setup] section - both are load-bearing now, not cosmetic.
;
;  PREREQUISITES (target machine):
;    - Lazarus installed (we build against its LCL/FPC through --lazarusdir).
;    - Windows PowerShell (always present) drives the build.
;    - WebView2 Evergreen Runtime for the chat (validated up front; the small
;      WebView2Loader.dll is shipped by us beside OUR exe).
;    - The Aefos IDE closed, if a previous one is installed (we replace OUR exe).
;      His own Lazarus only has to be closed when there is an in-place install to
;      migrate, because that is the one step that touches his binary.
;
;  BUILD (dev machine):  pwsh -File installer\lazarus\build-lazarus-installer.ps1
; ============================================================================

#define AppName    "Aefos AI (Lazarus)"
#define AppVer     "0.24.7-beta"
#define Publisher  "ModernDelphiWorks"
; The name of the IDE this setup produces, as the user will see it in the Start
; menu. This setup does NOT create that shortcut - the install engine does - so
; this is only the text of the messages that tell him where to find it. The one
; declaration that actually names the .lnk is
; scripts\aefos-laz-isolated-layout.ps1 $Script:AefosIsolatedShortcutName; keep
; the two in step (the isolated round-trip gate reads
; the PowerShell one, so a drift shows up there as a missing shortcut).
#define IdeName    "Aefos AI Lazarus IDE"

; --- WHICH ARCHITECTURES THIS BUILD CAN ACTUALLY DELIVER ----------------------
; Computed HERE, at compile time, from what is really on disk - never typed by
; hand. The setup does not ship a lazarus.exe (it builds one with the user's own
; FPC, so the IDE's architecture is HIS), but it DOES ship three fixed runtime
; DLLs, and libvterm.dll is a LOAD-TIME import: an x86_64 IDE beside an i386
; libvterm.dll dies at 0xc000007b before a line of our code runs - a green
; install and a dead IDE, which is exactly what a partner testing 0.24.7-beta
; got.
;
; So the wizard refuses a target it has no libraries for. Deriving the list from
; FileExists instead of a constant is the point: the day redist\x86_64\ is
; produced and packed, the refusal stops by itself. A hand-maintained constant
; would have to be remembered, and this is precisely the kind of thing that is
; not.
#define PayloadCpus "i386"
#if FileExists(AddBackslash(SourcePath) + "redist\x86_64\libvterm.dll")
  #define PayloadCpus PayloadCpus + ",x86_64"
#endif
#if FileExists(AddBackslash(SourcePath) + "redist\arm64\libvterm.dll")
  #define PayloadCpus PayloadCpus + ",arm64"
#endif

[Setup]
AppId={{2B9E7C41-5A3D-4E88-BF12-7C6E9A0D4F55}
AppName={#AppName}
AppVersion={#AppVer}
AppPublisher={#Publisher}
; WHERE THE PAYLOAD GOES, AND WHY IT IS NOT {commonpf} ANY MORE
; -------------------------------------------------------------
; {userpf} is %LOCALAPPDATA%\Programs - the per-user twin of Program Files, and
; where the Delphi edition's own installer already puts its per-user payload
; (installer\Aefos.iss: DefaultDirName={localappdata}\Aefos, PrivilegesRequired=
; lowest). Three things decide it:
;   1. NOTHING outside the user's profile is written any more, so nothing here
;      justifies elevation (see PrivilegesRequired below).
;   2. It must be STABLE and readable later without elevation: the reconcile/
;      rebuild engine reads this payload again whenever the user's Lazarus moves
;      on, and that runs as the plain user from inside the IDE.
;   3. It must NOT be {localappdata}\Aefos\Lazarus. Windows paths are case-
;      insensitive, so that directory IS %LOCALAPPDATA%\Aefos\lazarus - the
;      isolated IDE itself. The install engine fails on any entry it did not
;      declare in its layout manifest, and the uninstall engine removes that
;      whole directory: putting the payload there would break the install and
;      then delete the payload. Hence a sibling root, not a child of \Aefos.
DefaultDirName={userpf}\Aefos AI\Lazarus
DefaultGroupName=Aefos AI
DisableProgramGroupPage=yes
; NO ELEVATION. Every byte this setup writes now lands inside the current user's
; own profile: the payload in {userpf}, the IDE in %LOCALAPPDATA%\Aefos\lazarus,
; the shortcut in his own Start menu, the shared brain in %APPDATA%\Aefos.
; This is not just "nice to have":
;   * ISCC itself warned on the old combination - "PrivilegesRequired is set to
;     admin but per-user areas (localappdata, userappdata) are used by the
;     script" - and it was right: under an elevated setup {userappdata} and
;     {localappdata} resolve to the ELEVATING ADMIN'S profile, so mcp-bridge.ps1,
;     the About logo and aefos.exe landed in a profile the user never uses, and
;     the IDE would have been built against the wrong config. Running as the user
;     removes that whole class of failure by construction, not by a guard.
;   * The install engine ASSERTS it: Get-AefosIsolatedWriteRoots marks every
;     write root, and a root outside the current profile aborts the install.
; PrivilegesRequiredOverridesAllowed is deliberately NOT set: letting the user
; elevate would put the wrong-profile bug straight back.
PrivilegesRequired=lowest
OutputBaseFilename=Aefos-Lazarus-Setup-{#AppVer}
OutputDir=Output
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ShowLanguageDialog=yes
; 32-bit Lazarus is the common case; the package + loader are x86. Do not switch
; the install to 64-bit mode.
ArchitecturesInstallIn64BitMode=

[Languages]
Name: "en";   MessagesFile: "compiler:Default.isl"
Name: "ptbr"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"

[CustomMessages]
; NO LANGUAGE PREFIX, and that is the point: an unprefixed entry is used by EVERY
; language, so this text is English whichever language the user picked at the
; start. Everything Aefos says is English (CLAUDE.md); the pt-BR entry in
; [Languages] only translates Inno's own buttons and boilerplate.
DesktopIconTask=Create a shortcut for the Aefos AI Lazarus IDE on my desktop
ShortcutsGroup=Shortcuts:

[Tasks]
; TICKED BY DEFAULT, and that is a DECISION, not an oversight. The Inno custom is
; `Flags: unchecked`, and it does not fit this product:
;   * this shortcut is the PRIMARY way the user opens what he just installed -
;     there is no file association and no other entry point;
;   * his OWN Lazarus, which sits side by side with ours, HAS a desktop shortcut
;     (lazarus.lnk). Shipping ours unticked builds the asymmetry into the daily
;     gesture: he clicks his straight away and has to hunt for ours in the menu;
;   * it happened. The owner installed, went to the desktop for the icon, and it
;     was not there.
; The cost of being wrong is asymmetric too: unticking one box takes a second,
; while not finding the IDE becomes a support case. Do NOT "fix" this back to
; unchecked.
;
; The task is a FLAG, not an [Icons] entry: the target is
; %LOCALAPPDATA%\Aefos\lazarus\bin\lazarus.exe, which does not exist while the
; wizard runs - it is BUILT by the install engine, at the very end. So the choice
; is handed to that engine (_RunIsolatedInstall passes -DesktopShortcut) and the
; engine writes both .lnk files from one function, with one name, one icon and one
; tooltip. An [Icons] entry here would point at a file that is not there yet.
Name: "desktopicon"; Description: "{cm:DesktopIconTask}"; GroupDescription: "{cm:ShortcutsGroup}"

[Files]
; --- The ISOLATED engines, ALL IN THE SAME DIRECTORY --------------------------
; They resolve each other by $ScriptDir (Split-Path of their own path), so they
; must land TOGETHER at the root of {app}. The dependency graph, read off the
; dot-source lists rather than remembered:
;
;   aefos-laz-install-isolated.ps1   (run by _RunIsolatedInstall below)
;       . aefos-laz-isolated-layout.ps1      :121
;       . aefos-laz-seed-pcp.ps1             :121
;       . aefos-laz-import-components.ps1    :121
;   aefos-laz-uninstall-isolated.ps1 (run by [UninstallRun])
;       . aefos-laz-isolated-layout.ps1      :71
;   aefos-laz-reconcile-ide.ps1      (the repair/rebuild path, run later)
;       . aefos-laz-isolated-layout.ps1      :130
;       . aefos-laz-seed-pcp.ps1             :130
;       . aefos-laz-import-components.ps1    :131
;       . aefos-laz-ide-drift.ps1            :131
;
; A missing one is NOT a soft failure: each loader does
; `throw "Required engine not found"`. The payload gate 
; run-payload-tree-gate.ps1 stages EXACTLY this [Files] list into a scratch {app}
; and runs the engines FROM IT, because a directory that is used but not listed
; here passes every dev gate (they build from the full repo) and only breaks on a
; real machine - which is precisely how 0.21.7-beta shipped uninstallable.
Source: "..\..\scripts\aefos-laz-isolated-layout.ps1";    DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\scripts\aefos-laz-seed-pcp.ps1";           DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\scripts\aefos-laz-import-components.ps1";  DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\scripts\aefos-laz-ide-drift.ps1";          DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\scripts\aefos-laz-install-isolated.ps1";   DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\scripts\aefos-laz-uninstall-isolated.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\scripts\aefos-laz-reconcile-ide.ps1";      DestDir: "{app}"; Flags: ignoreversion

; --- The MIGRATION pair: {tmp} only, never {app} -------------------------------
; The migration runs ONCE, in PrepareToInstall, before a single byte of ours is
; written - so it is extracted to {tmp} with dontcopy and is gone when setup ends.
; It is NOT left in {app} on purpose: it is the engine that undoes an IN-PLACE
; install, and an installed copy invites being re-run on a machine that no longer
; has one. What a support case actually needs survives anyway - the engine writes
; migration-report.txt / migration-state.json into %LOCALAPPDATA%\Aefos\lazarus.
;
; aefos-laz-uninstall.ps1 is the LEGACY in-place uninstall engine and it ships for
; exactly one reason: aefos-laz-migrate.ps1:458 resolves it beside itself and
; REFUSES to run without it (exit 4). The migration deliberately does not carry a
; second copy of that undo logic - every rule in it (index-safe list edits, DLL
; provenance, the refusal to rebuild the IDE) was paid for with real damage, and
; two copies would drift apart.
;
; The old in-place INSTALL engine (aefos-laz-install.ps1) is NOT shipped any more,
; in any form: it is the one that relinks the user's lazarus.exe in place, and
; nothing in this installer may call it again.
Source: "..\..\scripts\aefos-laz-migrate.ps1"; Flags: dontcopy
Source: "aefos-laz-uninstall.ps1";             Flags: dontcopy

; The layout module a SECOND time, as a {tmp} payload. The wizard has to answer
; "what architecture will the IDE be built for?" on the page where the user picks
; his Lazarus - before {app} exists - and the answer must come from the SAME code
; the install engine uses later (Get-AefosPeMachine / Get-AefosLazarusTargetCpu).
; A private PE reader written into [Code] would be a second implementation of one
; fact, and this installer has paid for that mistake before: two copies of the
; undo logic were rejected for the same reason (see the migration note above).
;
; DestName, and not the plain name: the SAME file is already a [Files] entry that
; installs into {app}, and ExtractTemporaryFile resolves by file name. Two entries
; called the same thing would leave "which one" to Inno's matching order - a thing
; that works until it does not. Renaming the temporary copy makes the question
; unaskable.
Source: "..\..\scripts\aefos-laz-isolated-layout.ps1"; DestName: "aefos-laz-layout-probe.ps1"; Flags: dontcopy

; --- WebView2 loader (staged beside this .iss) --------------------------------
; Copied by the install engine into <ourpcp>\bin, beside OUR exe - never beside
; his, which is one of the three mutations of his tree that milestone 2 removes.
Source: "WebView2Loader.dll";      DestDir: "{app}"; Flags: ignoreversion

; --- MCP stdio<->named-pipe bridge (single-sourced repo-root file) -------------
; The chat agent points every external CLI at %APPDATA%\Aefos\aefos-mcp.json,
; whose built-in 'aefos' server runs this bridge to reach the Lazarus MCP host
; pipe. The RAD Studio edition self-heals the bridge to this exact shared path
; from an embedded resource at BPL load; the Lazarus package is statically linked
; (no resource slice), so the installer provisions it directly to the shared
; per-user path. Shipped to {app} too, mirroring the RAD Studio installer layout.
;
; uninsneveruninstall on the {userappdata} copy: that path is CO-OWNED with the
; RAD Studio edition (the BPL self-heals the same file to the same place at load).
; Uninstalling the Lazarus edition must not reach into the shared brain and delete
; a file a Delphi user is still running on. The {app} copy is ours alone and goes.
Source: "..\..\mcp-bridge.ps1"; DestDir: "{userappdata}\Aefos"; Flags: ignoreversion uninsneveruninstall
Source: "..\..\mcp-bridge.ps1"; DestDir: "{app}";               Flags: ignoreversion

; --- About-dialog lockup logo (shared per-user path) ---------------------------
; The branded About modal (Aefos.Lazarus.AboutForm) loads the lockup PNG from
; %APPDATA%\Aefos\aefos-about-logo.png. The Lazarus package is statically linked
; (no embedded RES like the RAD Studio BPL), so the installer stages the same
; art the Delphi edition embeds, next to mcp-bridge.ps1.
;
; uninsneveruninstall: this path is CO-OWNED with the RAD Studio edition (its BPL
; self-heals the SAME file to the SAME place at load, from an embedded resource).
; Whichever edition writes it last owns the bytes; uninstalling the Lazarus
; edition must not delete the About logo out from under a Delphi user still
; running the other edition (this exact gap shipped in 0.24.7-beta — the sibling
; mcp-bridge.ps1 line right above already had the flag, this one was missed).
Source: "..\..\source\chat\UI\branding\logo_about.png"; DestDir: "{userappdata}\Aefos"; DestName: "aefos-about-logo.png"; Flags: ignoreversion uninsneveruninstall

; --- The Aefos IDE application icon (shell entry + running window) -------------
; This setup does not install a plug-in into the user's Lazarus: it BUILDS A
; SECOND IDE. Both exes are lazarus.exe (ide\lazarusmanager.pas:331 hardcodes that
; name, so ours can never be renamed - startlazarus would otherwise send a "Save
; and rebuild IDE" restart into HIS IDE with OUR config), and both link the same
; MAINICON out of his ide\lazarus.res. The result was two IDEs the user could not
; tell apart in the taskbar or in Alt+Tab. One icon file answers both halves:
;   * {app}     -> the install engine points the shortcut's IconLocation at it, so
;                  the Start-menu/desktop/search entry carries the Aefos mark;
;   * %APPDATA%\Aefos -> the RUNNING IDE loads it into Application.Icon at startup
;                  (source\lazarus\ide\Aefos.Lazarus.AppIdentity.pas), which the
;                  LCL turns into WM_SETICON on the application window (the taskbar
;                  button, since ide\lazarus.pp:123 sets MainFormOnTaskBar := False)
;                  and on every IDE window. Staged in the same shared brand folder
;                  as aefos-about-logo.png, and for the same reason: this edition is
;                  compiled on the USER'S machine, so art is shipped as a file
;                  instead of linked into that build as a resource.
; NOT uninsneveruninstall, unlike its two neighbours: the name is this edition's
; alone, the RAD Studio edition neither writes nor reads it, so nothing is co-owned
; and it goes when Aefos AI (Lazarus) goes.
; Regenerate with: pwsh -File scripts\build-aefos-icon.ps1
Source: "aefos-lazarus.ico"; DestDir: "{app}";                Flags: ignoreversion
Source: "aefos-lazarus.ico"; DestDir: "{userappdata}\Aefos";  Flags: ignoreversion

; --- The Aefos design package + the source tree its .lpk needs -----------------
; The .lpk references paths relative to itself, so it must sit at
; {app}\packages\Lazarus with the trees it points at preserved: {app}\source\...
; AND {app}\cli (its OtherUnitFiles ends in ..\..\cli).
; ⚠️ These [Files] entries MUST cover EVERY directory in the .lpk's OtherUnitFiles.
; A missing one compiles fine in the dev gate (which builds from the full repo) but
; FAILS the on-machine -BuildIde with "Can't find unit X" -- only a real install
; catches it. The Agent-mode slice added the cli dependency and this line with it.
Source: "..\..\packages\Lazarus\Aefos.Lazarus.IDE.lpk"; DestDir: "{app}\packages\Lazarus"; Flags: ignoreversion
Source: "..\..\source\lazarus\*";   DestDir: "{app}\source\lazarus";   Flags: recursesubdirs createallsubdirs ignoreversion; Excludes: "*.dcu,*.ppu,*.o,*.a,*.dcp,*.bpl,*.compiled,*.identcache,__history\*,backup\*,lib\*"
Source: "..\..\source\webview\*";   DestDir: "{app}\source\webview";   Flags: recursesubdirs createallsubdirs ignoreversion; Excludes: "*.dcu,*.ppu,*.o,*.a,*.dcp,*.bpl,*.compiled,*.identcache,__history\*,backup\*,lib\*"
Source: "..\..\source\compat\*";    DestDir: "{app}\source\compat";    Flags: recursesubdirs createallsubdirs ignoreversion; Excludes: "*.dcu,*.ppu,*.o,*.a,*.dcp,*.bpl,*.compiled,*.identcache,__history\*,backup\*,lib\*"
Source: "..\..\source\providers\*"; DestDir: "{app}\source\providers"; Flags: recursesubdirs createallsubdirs ignoreversion; Excludes: "*.dcu,*.ppu,*.o,*.a,*.dcp,*.bpl,*.compiled,*.identcache,__history\*,backup\*,lib\*"
Source: "..\..\source\mcp\Core\*";  DestDir: "{app}\source\mcp\Core";  Flags: recursesubdirs createallsubdirs ignoreversion; Excludes: "*.dcu,*.ppu,*.o,*.a,*.dcp,*.bpl,*.compiled,*.identcache,__history\*,backup\*,lib\*"
Source: "..\..\source\chat\Core\*"; DestDir: "{app}\source\chat\Core"; Flags: recursesubdirs createallsubdirs ignoreversion; Excludes: "*.dcu,*.ppu,*.o,*.a,*.dcp,*.bpl,*.compiled,*.identcache,__history\*,backup\*,lib\*"
Source: "..\..\source\chat\UI\*";   DestDir: "{app}\source\chat\UI";   Flags: recursesubdirs createallsubdirs ignoreversion; Excludes: "*.dcu,*.ppu,*.o,*.a,*.dcp,*.bpl,*.compiled,*.identcache,__history\*,backup\*,lib\*"
; Terminal engine cores compiled by the Lazarus package (source\terminal\Core added
; to the .lpk OtherUnitFiles): ConPTY + the libvterm-backed VTermBuffer and its deps.
; Only the 7 units the .lpk lists are compiled; the rest of the dir rides along
; unused. libvterm itself is a runtime DLL (below), not a linked object here.
Source: "..\..\source\terminal\Core\*"; DestDir: "{app}\source\terminal\Core"; Flags: recursesubdirs createallsubdirs ignoreversion; Excludes: "*.dcu,*.ppu,*.o,*.a,*.dcp,*.bpl,*.compiled,*.identcache,__history\*,backup\*,lib\*"
; source\terminal\UI is ALSO in the .lpk OtherUnitFiles, and the package compiles
; Aefos.OTA.Terminal.UI.ComposerHtml from it (added with the WebView2 composer bar).
; It was missing here, so an installed tree had the unit on the .lpk's search path
; but not on disk -> the on-machine -BuildIde died with "Can't find unit
; Aefos.OTA.Terminal.UI.ComposerHtml" while the dev gate (full repo) passed. Exactly
; the failure this file's header warns about. The dir ships whole, mirroring the
; terminal\Core line: only the unit the .lpk lists is compiled, the VCL siblings
; ride along unused, and the installed search path then matches the dev one.
Source: "..\..\source\terminal\UI\*"; DestDir: "{app}\source\terminal\UI"; Flags: recursesubdirs createallsubdirs ignoreversion; Excludes: "*.dcu,*.ppu,*.o,*.a,*.dcp,*.bpl,*.compiled,*.identcache,__history\*,backup\*,lib\*"
; License engine (cross-compiler): Aefos.License.Client/Gate compiled by the
; Lazarus package (source\license added to the .lpk OtherUnitFiles). The LCL UI
; twin lives under source\lazarus\* (already shipped above). Aefos.License.Token
; is Delphi-only and harmlessly rides along; the FPC build never references it.
Source: "..\..\source\license\*";   DestDir: "{app}\source\license";   Flags: recursesubdirs createallsubdirs ignoreversion; Excludes: "*.dcu,*.ppu,*.o,*.a,*.dcp,*.bpl,*.compiled,*.identcache,__history\*,backup\*,lib\*"
; Excludes: the cli\ tree is a SOURCE tree, but a developer machine also holds the
; compiler's intermediates there (.build-aefos\*.dcu from dcc32, .build-fpc\*.a/.o
; from FPC) plus stray capture files. Without this the packed content would vary by
; machine - a clean checkout ships one set of files, a build machine another - and
; a public beta would carry object files it has no use for. The sources and
; cli\bin\*.exe (needed by the [Run] seed below) still ship.
Source: "..\..\cli\*";              DestDir: "{app}\cli";              Flags: recursesubdirs createallsubdirs ignoreversion; Excludes: "\.build-aefos\*,\.build-fpc\*,*.dcu,*.ppu,*.o,*.a,stderr*.txt"

; --- Aefos addon manager + bundled Desktop MCP addon (offline) ------------------
; ONE brain with the RAD Studio edition: aefos.exe + the sha256-pinned Desktop MCP
; bundle land in the SAME shared per-user layout the Delphi installer uses, so a
; user running both editions shares one ~/.aefos\addons tree and one aefos.exe.
;   * aefos.exe -> the shared per-user bin (%APPDATA%\Aefos\bin), like the Delphi
;     installer. Built by scripts\build-aefos-cli.ps1 (dcc32) or FPC into cli\bin.
;   * the Desktop MCP dist (registry.json + addons\desktop\<zip> with
;     AefosDesktopMcp.exe inside), WHEN staged under mcps\desktop\dist. That
;     addon is published in the addons repository; this repo carries only the
;     source of its server executable.
; The [Run] step below seeds the addon 100% offline via aefos.exe --registry, and
; the Lazarus chat merges the resulting ~/.aefos\addons\mcp-servers.json the same
; way the RAD Studio edition does. skipifsourcedoesntexist: a build that staged
; neither degrades to online-only without failing.
; uninsneveruninstall on aefos.exe: it is the SHARED addon manager, the same file
; the RAD Studio installer writes to the same per-user bin. Whichever edition
; installs it last owns the bytes; NEITHER may delete it on uninstall, or removing
; the Lazarus edition silently breaks `aefos install <mcp>` for a Delphi user (and
; vice versa - installer\Aefos.iss carries the same flag for the same reason).
; One brain, one aefos.exe: shared state outlives either edition's uninstall.
Source: "..\..\cli\bin\aefos.exe"; DestDir: "{userappdata}\Aefos\bin"; Flags: ignoreversion skipifsourcedoesntexist uninsneveruninstall
Source: "..\..\mcps\desktop\dist\registry.json"; DestDir: "{app}\addons"; Flags: ignoreversion skipifsourcedoesntexist
Source: "..\..\mcps\desktop\dist\addons\*"; DestDir: "{app}\addons\addons"; Flags: recursesubdirs createallsubdirs ignoreversion skipifsourcedoesntexist

; --- SQLite runtime DLL --------------------------------------------------------
; The chat session store operates the shared %APPDATA%\Aefos\aefos.db through a
; standard i386 sqlite3.dll, shipped beside lazarus.exe exactly like
; WebView2Loader.dll (the install engine copies it there). This REPLACES the old
; static-object approach, which broke the user's ability to rebuild the IDE by
; normal means (a plain `lazbuild --build-ide`, run by Package > Install/Uninstall
; Packages to add e.g. AnchorDocking, had no -Fo/-Fl and failed to find the object
; + mingw libs). With a runtime DLL the IDE link has ZERO C dependencies and
; rebuilds normally. The DLL is built from the vendored amalgamation
; (build-sqlite-fpc.ps1) into redist\ by build-lazarus-installer.ps1; it is
; byte-standard "SQLite format 3", the same aefos.db FireDAC reads. SQLite is
; public domain. It is staged to {app} and copied into <ourpcp>\bin, beside OUR
; lazarus.exe: his own sqlite3.dll (the one every SQLdb tutorial tells him to keep
; next to lazarus.exe) is never overwritten and never deleted again.
Source: "redist\sqlite3.dll"; DestDir: "{app}"; Flags: ignoreversion

; --- libvterm runtime DLL ------------------------------------------------------
; The terminal panel binds libvterm as a RUNTIME DLL (external 'libvterm.dll'),
; shipped beside lazarus.exe exactly like sqlite3.dll and for the same reason: a
; static {$LINK} of the object made the IDE non-rebuildable by normal means and
; dragged the mingw CRT into the link. Built (i686) from the vendored unity C by
; build-libvterm-fpc.ps1 into redist\ by build-lazarus-installer.ps1. Staged to
; {app} and copied into <ourpcp>\bin, beside OUR lazarus.exe (same reason).
Source: "redist\libvterm.dll"; DestDir: "{app}"; Flags: ignoreversion

; --- per-architecture runtime DLLs --------------------------------------------
; The three entries above are the historical FLAT payload, and it is i386. They
; stay exactly where they are: Get-AefosIsolatedPayloadDlls searches the per-CPU
; folders FIRST and falls back to the flat ones, so an i386 target resolves today
; precisely as it did before this slice existed.
;
; These subdirectories are what a 64-bit (or ARM64) Lazarus needs, and they are
; packed only when the build actually produced them - the same FileExists that
; computed PayloadCpus above, so the payload and the wizard's refusal can never
; disagree. Installing them under {app}\<cpu>\ matches the first candidate
; Get-AefosIsolatedPayloadDlls looks at.
#if FileExists(AddBackslash(SourcePath) + "redist\x86_64\libvterm.dll")
Source: "redist\x86_64\*"; DestDir: "{app}\x86_64"; Flags: ignoreversion
#endif
#if FileExists(AddBackslash(SourcePath) + "redist\arm64\libvterm.dll")
Source: "redist\arm64\*";  DestDir: "{app}\arm64";  Flags: ignoreversion
#endif

; NOTE: neither the IDE build nor the migration has a [Run] entry, on purpose.
;   * The BUILD runs from CurStepChanged(ssPostInstall) through ExecAndLogOutput,
;     so the engine stays HIDDEN and reports its progress INSIDE the wizard
;     instead of throwing a console window at the user - and so the "installed"
;     dialog can be conditional on the build actually succeeding.
;   * The MIGRATION runs from PrepareToInstall for a stronger reason: its contract
;     is an EXIT CODE (0 = nothing to do / migrated, 3 = partial, keep going and
;     show the report, 4 = refused, STOP), and a [Run] entry cannot honour it -
;     Inno ignores a [Run] entry's exit code entirely. PrepareToInstall is the one
;     hook that can still say "do not install", and it runs BEFORE any file of
;     ours is written, so a refusal costs the user nothing.
; See _RunMigration and _RunIsolatedInstall below.

[Run]
; Seed the bundled Desktop MCP addon OFFLINE from the local dist under {app}\addons
; (no network). Idempotent (clean-replace), so a repair/upgrade re-run is safe.
; runhidden: no console window. runascurrentuser: install into the ORIGINATING
; user's ~/.aefos (Setup runs elevated), matching where aefos.exe was staged.
; Check + skipifdoesntexist: no-op when either aefos.exe or the dist was not
; staged, degrading to online-only without failing the install.
Filename: "{userappdata}\Aefos\bin\aefos.exe"; \
  Parameters: "install desktop --registry ""{app}\addons\registry.json"" -y"; \
  WorkingDir: "{userappdata}\Aefos\bin"; \
  StatusMsg: "Installing the bundled Desktop MCP addon..."; \
  Flags: runhidden skipifdoesntexist runascurrentuser; \
  Check: DesktopAddonBundled

[UninstallRun]
; Remove the isolated IDE: ONE directory (%LOCALAPPDATA%\Aefos\lazarus) and ONE
; shortcut. There is nothing to restore, because nothing on the user's side was
; ever written - that is the whole of milestone 2. Runs before [Files] removal.
;
; -LazarusDir is passed as an EXTRA REFUSAL, not as a target: the engine stops if
; the directory it is about to delete somehow resolved inside his Lazarus tree.
; ({code:...} is expanded when the entry is RECORDED, i.e. during install, so the
; wizard page is still alive at that point.)
;
; NOT runhidden, deliberately: the engine's closing report is "what was removed
; and what was deliberately KEPT" - his Lazarus, his config, the shared brain in
; %APPDATA%\Aefos and his addons - and that answer is worth a console window.
; Writing it to a log file instead would leave a file behind on a machine the user
; just asked us to leave.
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\aefos-laz-uninstall-isolated.ps1"" -LazarusDir ""{code:GetLazarusDir}"""; \
  RunOnceId: "AefosLazUninstallIsolated"; Flags: waituntilterminated

[Code]
var
  LazPage: TInputDirWizardPage;
  // Whole captured stream of the engine currently running (migration, then the
  // isolated install), flushed to a log file when that run ends.
  GEngineLog: string;
  // Did this machine carry an in-place install when setup started? Decided BEFORE
  // the migration runs, because afterwards the evidence is gone by design.
  GHadInPlaceInstall: Boolean;
  // Did the isolated install engine actually succeed? Read by the FINAL PAGE,
  // which must never claim a working IDE the build did not produce.
  GInstallOk: Boolean;

// [Run] Check for the offline Desktop MCP seed: true only when the bundled
// registry.json was actually staged into {app}\addons (so a build without the
// dist silently skips the seed instead of erroring).
function DesktopAddonBundled(): Boolean;
begin
  Result := FileExists(ExpandConstant('{app}\addons\registry.json'));
end;

// EVERY user-facing string in this installer is ENGLISH, and there is no longer a
// helper that could make it otherwise. This file used to pair each message with a
// Portuguese twin through a translation helper; that was against the project rule
// (CLAUDE.md: nothing user- or agent-facing in Aefos is written in Portuguese), so
// both the helper and the Portuguese halves were deleted rather than left as dead
// text. The [Languages] entry for pt-BR STAYS: those are Inno's OWN strings -
// Next, Cancel, "Setup will now install" - which Inno ships translated, and
// dropping them would only make the wizard chrome worse for a Brazilian user
// without making anything of OURS more English.

// -------- Lazarus directory detection (mirrors the PS engine) ----------------
function DetectLazarusDir(): string;
var
  Cands: TArrayOfString;
  I: Integer;
  Loc: string;
begin
  Result := '';
  SetArrayLength(Cands, 7);
  Cands[0] := 'C:\lazarus';
  Cands[1] := ExpandConstant('{sd}\lazarus');
  Cands[2] := ExpandConstant('{commonpf}\Lazarus');
  Cands[3] := ExpandConstant('{commonpf32}\Lazarus');
  Cands[4] := ExpandConstant('{localappdata}\Programs\Lazarus');
  // The 64-bit conventional names, LAST on purpose. They are real - the partner
  // whose install failed keeps his at C:\lazarus64 - so not knowing them means
  // an empty path on the wizard page. But while the payload is i386-only, a
  // 32-bit tree found earlier in this list is the one we can actually build
  // from, so it must keep winning. Order is the policy here, not an accident.
  Cands[5] := 'C:\lazarus64';
  Cands[6] := ExpandConstant('{sd}\lazarus64');
  for I := 0 to GetArrayLength(Cands) - 1 do
    if FileExists(Cands[I] + '\lazbuild.exe') then
    begin
      Result := Cands[I];
      Exit;
    end;
  // Registry: Lazarus' own uninstall key.
  if RegQueryStringValue(HKLM,
       'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\lazarus',
       'InstallLocation', Loc) and (Loc <> '') and FileExists(Loc + '\lazbuild.exe') then
    Result := Loc
  else if RegQueryStringValue(HKLM,
       'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\lazarus',
       'InstallLocation', Loc) and (Loc <> '') and FileExists(Loc + '\lazbuild.exe') then
    Result := Loc;
end;

// The Lazarus the user pointed us at, or the detected one. Nil-safe on purpose:
// [Code] is shared with the uninstaller, where LazPage was never created, and a
// nil dereference there would turn "remove Aefos" into a script error.
function GetLazarusDir(Param: string): string;
begin
  Result := '';
  if LazPage <> nil then
    Result := LazPage.Values[0];
  if Result = '' then
    Result := DetectLazarusDir();
end;

// -------- Lazarus VERSION gate -----------------------------------------------
//
// Aefos links STATICALLY into lazarus.exe, and its package depends on the IDE's
// own IdeDebugger package (packages\Lazarus\Aefos.Lazarus.IDE.lpk) -- which only
// exists since the IDE was split into ide\packages\ (Lazarus 3.x). On anything
// older the build dies MINUTES IN with a raw compiler error, which reads as a
// broken product rather than an unmet requirement -- and is indistinguishable
// from a packaging bug (that ambiguity is exactly what hid the 0.21.7 failure).
// So ask lazbuild its version and say so UP FRONT, before touching anything.
//
// Fail-OPEN when the version cannot be read, for the same reason ExeIsRunning
// does: a wrong block leaves the user with no way to install, while a missed one
// only means the build reports the real error.
const
  CMinLazMajor    = 3;   // hard floor - below this the package cannot compile
  CTestedLazMajor = 4;   // what Aefos is actually built and tested against

// Version major of the Lazarus in LazDir, or -1 when it cannot be determined.
// VerText receives the raw string as printed ('4.8'), for the message.
function ReadLazarusMajor(const LazDir: string; var VerText: string): Integer;
var
  LOutFile: string;
  LLines: TArrayOfString;
  LLine: string;
  LCode: Integer;
  I, LDot: Integer;
begin
  Result := -1;
  VerText := '';
  if not FileExists(LazDir + '\lazbuild.exe') then Exit;
  LOutFile := ExpandConstant('{tmp}\aefos-lazver.txt');
  DeleteFile(LOutFile);
  // lazbuild prints its version on stdout; cmd captures it to a file.
  if not Exec(ExpandConstant('{cmd}'),
       '/C ""' + LazDir + '\lazbuild.exe" --version > "' + LOutFile + '" 2>&1"',
       '', SW_HIDE, ewWaitUntilTerminated, LCode) then Exit;
  if not LoadStringsFromFile(LOutFile, LLines) then Exit;
  // Scan from the BOTTOM: older lazbuild prints banner/usage noise first and the
  // bare version last. Take the last line shaped like '<digits>.<something>'.
  for I := GetArrayLength(LLines) - 1 downto 0 do
  begin
    LLine := Trim(LLines[I]);
    if LLine = '' then Continue;
    LDot := Pos('.', LLine);
    if (LDot > 1) and (StrToIntDef(Copy(LLine, 1, LDot - 1), -1) >= 0) then
    begin
      VerText := LLine;
      Result := StrToIntDef(Copy(LLine, 1, LDot - 1), -1);
      Exit;
    end;
  end;
end;

// May setup proceed against the Lazarus in LazDir?
function LazarusVersionAccepted(const LazDir: string): Boolean;
var
  LMajor: Integer;
  LVer: string;
begin
  Result := True;
  LMajor := ReadLazarusMajor(LazDir, LVer);
  if LMajor < 0 then Exit;                       // unreadable -> fail open
  if LMajor < CMinLazMajor then
  begin
    MsgBox('This Lazarus is too old for Aefos AI.' + #13#10#13#10
        + 'Found:     Lazarus ' + LVer + #13#10
        + 'Required:  Lazarus ' + IntToStr(CMinLazMajor) + '.0 or newer'
        + ' (built and tested on ' + IntToStr(CTestedLazMajor) + '.x)' + #13#10#13#10
        + 'Aefos links into the IDE and needs IDE packages this version does not '
        + 'have, so rebuilding lazarus.exe would fail with a compiler error. '
        + 'Install a newer Lazarus, then run this setup again.',
      mbError, MB_OK);
    Result := False;
    Exit;
  end;
  // Above the floor but below what we test on: honest warning, user decides.
  // The reassurance is no longer "we restore your exe" - we never replace it. If
  // the build fails, the only thing that failed is OUR IDE, in OUR folder.
  if LMajor < CTestedLazMajor then
    Result := MsgBox('Aefos AI is built and tested on Lazarus ' + IntToStr(CTestedLazMajor)
        + '.x, and this is Lazarus ' + LVer + '.' + #13#10#13#10
        + 'It may work, but the build is not verified on it. If it fails, YOUR '
        + 'Lazarus is untouched either way - Aefos builds a separate IDE of its '
        + 'own and never modifies yours - and the full log is kept.' + #13#10#13#10
        + 'Continue anyway?',
      mbConfirmation, MB_OKCANCEL) = IDOK;
end;

// -------- Lazarus ARCHITECTURE gate ------------------------------------------
//
// The gate that 0.24.7-beta did not have, and the reason a partner ended up with
// a fully built, "successfully installed", completely dead IDE.
//
// This setup does not ship an IDE - it BUILDS one, with the user's own FPC, so
// the architecture of the product is decided by HIS Lazarus, not by us. What we
// do ship as fixed binaries are three runtime DLLs, all of them i386 today (see
// scripts\build-libvterm-fpc.ps1 / build-sqlite-fpc.ps1, which to this day
// refuse a 64-bit gcc). On a 64-bit Lazarus those facts collide: the build
// SUCCEEDS - FPC compiles every Aefos unit for x86_64 without a complaint - and
// then the loader refuses the process, because every vterm_* is declared
// `external cLibVTerm` (source\terminal\Core\Aefos.OTA.Terminal.Core.LibVTerm.pas)
// and a load-time import of a 32-bit DLL into a 64-bit image is 0xc000007b.
//
// So the question is asked HERE, on the page where he chooses the Lazarus, and
// the answer comes from the install engine's OWN code (dontcopy payload above) -
// not from a second PE reader written into this script.
function ReadLazarusTargetCpu(const LazDir: string): string;
var
  LModule, LOutFile, LParams, LDirArg: string;
  LLines: TArrayOfString;
  LCode, I: Integer;
begin
  Result := '';
  if not FileExists(LazDir + '\lazbuild.exe') then Exit;
  try
    ExtractTemporaryFile('aefos-laz-layout-probe.ps1');
  except
    Exit;                                        // no module -> fail open
  end;
  LModule  := ExpandConstant('{tmp}\aefos-laz-layout-probe.ps1');
  LOutFile := ExpandConstant('{tmp}\aefos-lazcpu.txt');
  DeleteFile(LOutFile);
  // Single-quoted PowerShell literals, so spaces in the path are a non-issue; a
  // literal quote inside a directory name is doubled, which is how PowerShell
  // escapes it. The user picks this path on a wizard page - it is his string,
  // not ours, and it gets quoted properly rather than assumed well-behaved.
  LDirArg := LazDir;
  StringChangeEx(LDirArg, '''', '''''', True);
  LParams := '-NoProfile -ExecutionPolicy Bypass -Command "& { . ''' + LModule
    + '''; Get-AefosLazarusTargetCpu -LazarusDir ''' + LDirArg
    + ''' } | Out-File -Encoding ascii -FilePath ''' + LOutFile + '''"';
  if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
       LParams, '', SW_HIDE, ewWaitUntilTerminated, LCode) then Exit;
  if not LoadStringsFromFile(LOutFile, LLines) then Exit;
  for I := 0 to GetArrayLength(LLines) - 1 do
    if Trim(LLines[I]) <> '' then
    begin
      Result := Trim(LLines[I]);
      Exit;
    end;
end;

// May setup proceed against a Lazarus of this architecture?
//
// FAILS OPEN on an unreadable answer, exactly like the version gate: a wrong
// refusal leaves a user with no way to install at all, while a missed one only
// means the install engine repeats the same refusal a moment later (it runs the
// same check on real machine words before it builds anything).
function LazarusTargetCpuAccepted(const LazDir: string): Boolean;
var
  LCpu: string;
begin
  Result := True;
  LCpu := ReadLazarusTargetCpu(LazDir);
  if LCpu = '' then Exit;
  // Comma-delimited containment, with the delimiters on both ends so 'i386'
  // cannot match inside another entry.
  if Pos(',' + LCpu + ',', ',' + '{#PayloadCpus}' + ',') > 0 then Exit;
  MsgBox('This Lazarus is ' + LCpu + ', and this Aefos setup has no ' + LCpu
      + ' build of the libraries the IDE needs.' + #13#10#13#10
      + 'Aefos does not ship an IDE - it compiles one from the Lazarus you '
      + 'choose, using your own FPC. That means the IDE it builds would be '
      + LCpu + ' as well, while the runtime libraries in this setup are 32-bit '
      + '(i386). It would build successfully and then fail to start, with '
      + 'error 0xc000007b.' + #13#10#13#10
      + 'Nothing has been installed and your Lazarus has not been touched.'
      + #13#10#13#10
      + 'To install Aefos today, point it at a 32-bit (i386) Lazarus. It can sit '
      + 'beside this one - this setup never modifies the Lazarus it builds from.',
    mbError, MB_OK);
  Result := False;
end;

// Is this path inside a MACHINE-WIDE location that a non-elevated setup cannot
// write? Environment variables and not the {common*} constants: those are the ones
// Inno refuses to expand outside administrative install mode, and reading them is
// all this question needs.
function IsMachineWidePath(const APath: string): Boolean;
var
  I: Integer;
  LRoot: string;
  LRoots: TArrayOfString;
begin
  Result := False;
  if APath = '' then Exit;
  SetArrayLength(LRoots, 3);
  LRoots[0] := GetEnv('ProgramFiles');
  LRoots[1] := GetEnv('ProgramFiles(x86)');
  LRoots[2] := GetEnv('SystemRoot');
  for I := 0 to GetArrayLength(LRoots) - 1 do
  begin
    LRoot := LRoots[I];
    if LRoot = '' then Continue;
    if Pos(Uppercase(AddBackslash(LRoot)), Uppercase(AddBackslash(APath))) = 1 then
    begin
      Result := True;
      Exit;
    end;
  end;
end;

procedure InitializeWizard();
var
  Detected: string;
begin
  // THE UPGRADE TRAP, DISARMED. The AppId is unchanged on purpose (the migration
  // depends on being able to reason about the same product), but the MODEL changed
  // from a machine-wide admin install in {commonpf} to a per-user one. If this
  // setup ever inherits the previous directory - Inno's UsePreviousAppDir, reading
  // what an older admin install recorded - a non-elevated run would then try to
  // write into Program Files and fail with an access error the user cannot act on.
  // So: a prefilled directory that lives in a machine-wide root is replaced by our
  // per-user default. The page still shows it, and he can still change it.
  if IsMachineWidePath(WizardForm.DirEdit.Text) then
    WizardForm.DirEdit.Text := ExpandConstant('{userpf}\Aefos AI\Lazarus');

  // The page where the misunderstanding starts, so it is the page that has to be
  // explicit: what this setup produces is a SECOND lazarus.exe, of its own, and
  // the folder asked for here is only the source it is compiled against.
  LazPage := CreateInputDirPage(wpSelectDir,
    'Lazarus installation',
    'Which Lazarus should the Aefos IDE be built from?',
    'This setup does NOT install a plug-in into this Lazarus. It COMPILES ITS '
      + 'OWN lazarus.exe from it - same LCL, same FPC, same sources - and installs '
      + 'that separate IDE in your user folder, with its own name, its own icon and '
      + 'its own configuration. The Lazarus below is only read: it stays in its '
      + 'folder, with its shortcut on your desktop if it has one, and nothing in it '
      + 'is changed. Confirm the folder that contains lazbuild.exe (the build takes '
      + 'a couple of minutes).',
    False, '');
  LazPage.Add('');
  Detected := DetectLazarusDir();
  if Detected <> '' then
    LazPage.Values[0] := Detected
  else
    LazPage.Values[0] := 'C:\lazarus';
end;

// Validate the chosen Lazarus dir before proceeding.
function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if CurPageID = LazPage.ID then
  begin
    if not FileExists(LazPage.Values[0] + '\lazbuild.exe') then
    begin
      MsgBox('lazbuild.exe was not found in:' + #13#10 + '    ' + LazPage.Values[0]
        + #13#10#13#10 + 'Point this at your Lazarus folder (the one with lazbuild.exe).',
        mbError, MB_OK);
      Result := False;
    end
    // Version gate on the folder the user actually chose - not on the detected
    // one, so a custom path is checked too. Architecture second, and only if the
    // version passed: telling a user his Lazarus 2.x is 64-bit would be true and
    // useless - the version is the one he has to fix first.
    else if not LazarusVersionAccepted(LazPage.Values[0]) then
      Result := False
    else
      Result := LazarusTargetCpuAccepted(LazPage.Values[0]);
  end;
end;

// -------- WebView2 Evergreen Runtime prerequisite (like the Delphi installer) --
const
  CWebView2ClientGuid   = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';
  CWebView2BootstrapUrl = 'https://go.microsoft.com/fwlink/p/?LinkId=2124703';

function WebView2RuntimeInstalled(): Boolean;
var
  Pv: string;
begin
  Result :=
    (RegQueryStringValue(HKLM,
       'SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\' + CWebView2ClientGuid, 'pv', Pv)
       and (Pv <> '') and (Pv <> '0.0.0.0'))
    or
    (RegQueryStringValue(HKLM,
       'SOFTWARE\Microsoft\EdgeUpdate\Clients\' + CWebView2ClientGuid, 'pv', Pv)
       and (Pv <> '') and (Pv <> '0.0.0.0'))
    or
    (RegQueryStringValue(HKCU,
       'SOFTWARE\Microsoft\EdgeUpdate\Clients\' + CWebView2ClientGuid, 'pv', Pv)
       and (Pv <> '') and (Pv <> '0.0.0.0'));
end;

function InternetGetConnectedState(var lpdwFlags: Cardinal; dwReserved: Cardinal): Boolean;
  external 'InternetGetConnectedState@wininet.dll stdcall';

function IsOnline(): Boolean;
var
  Flags: Cardinal;
begin
  Flags := 0;
  Result := InternetGetConnectedState(Flags, 0);
end;

function CreateFileW(lpFileName: string; dwDesiredAccess, dwShareMode,
  lpSecurityAttributes, dwCreationDisposition, dwFlagsAndAttributes,
  hTemplateFile: Cardinal): Cardinal;
  external 'CreateFileW@kernel32.dll stdcall';

function CloseHandle(hObject: Cardinal): Boolean;
  external 'CloseHandle@kernel32.dll stdcall';

function GetLastError(): Cardinal;
  external 'GetLastError@kernel32.dll stdcall';

// Is this executable running right now?
//
// Probe the FILE, not a window class: Windows locks a running image against
// writes, so a GENERIC_WRITE open failing with ERROR_SHARING_VIOLATION is exact
// proof, and it asks precisely the question the install cares about.
// Do NOT go back to FindWindowByClassName - 'TApplication' is the class of EVERY
// Delphi/LCL app, including this Inno setup itself, so it matched us and trapped
// the user in an unclosable Retry loop (field report, 2026-07-17). The RAD Studio
// installer can use a class name only because 'TAppBuilder' is unique to the IDE;
// the LCL has no such unique class. This is the same probe the isolated uninstall
// engine uses (Test-AefosIsolatedIdeRunning), for the same reason.
//
// Fail-OPEN on any other error (ACCESS_DENIED on a Program Files Lazarus, an odd
// path): a wrong nag is a hard block (the user can never install), while a missed
// nag only means the engine reports a locked file.
function ExeIsRunning(const AExePath: string): Boolean;
var
  LHandle: Cardinal;
begin
  Result := False;
  if AExePath = '' then Exit;
  if not FileExists(AExePath) then Exit;
  // GENERIC_WRITE, no sharing, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL.
  // Opening for write neither truncates nor modifies the file.
  LHandle := CreateFileW(AExePath, $40000000, 0, 0, 3, $80, 0);
  if LHandle = $FFFFFFFF then          // INVALID_HANDLE_VALUE
    Result := (GetLastError() = 32)    // ERROR_SHARING_VIOLATION
  else
    CloseHandle(LHandle);
end;

// OUR IDE. Not a guess: scripts\aefos-laz-isolated-layout.ps1
// Get-AefosIsolatedInstallPcp is %LOCALAPPDATA%\Aefos\lazarus, and the exe lives
// in <pcp>\bin because that is the only place startlazarus looks for an
// alternative IDE (ide\lazarusmanager.pas:314).
function AefosIdeExePath(): string;
begin
  Result := ExpandConstant('{localappdata}\Aefos\lazarus\bin\lazarus.exe');
end;

// The exe THIS setup replaces is ours, not his - so this is the one to nag about.
function AefosIdeIsRunning(): Boolean;
begin
  Result := ExeIsRunning(AefosIdeExePath());
end;

// Does this machine still carry an IN-PLACE install (<= 0.24.7)? If it does, the
// migration will replace HIS lazarus.exe to give him his stock binary back, and
// that is the ONLY case where his IDE has to be closed. File evidence only, and
// only the artefacts nothing but an Aefos in-place install creates - the same
// STRONG items scripts\aefos-laz-migrate.ps1 Get-AefosInPlaceEvidence keys on.
// The exe-carries-'Aefos.Lazarus.IDE' probe is deliberately NOT repeated here:
// scanning a 20 MB binary from Pascal Script at wizard time is not worth it, and
// an install that produced that exe also left one of these beside it.
function InPlaceInstallPresent(const ALazDir: string): Boolean;
var
  LRec: TFindRec;
begin
  Result := False;
  if ALazDir = '' then Exit;
  if FileExists(ALazDir + '\aefos-laz-install-state.json') then begin Result := True; Exit; end;
  if FileExists(ALazDir + '\aefos-laz-buildide.log') then begin Result := True; Exit; end;
  if FileExists(ALazDir + '\AEFOS-UNINSTALL-README.txt') then begin Result := True; Exit; end;
  if FindFirst(ALazDir + '\lazarus-aefos-backup-*.exe', LRec) then
  begin
    try
      Result := True;
    finally
      FindClose(LRec);
    end;
  end;
end;

// His lazarus.exe, and only when we are actually going to replace it.
function UserLazarusMustBeClosed(): Boolean;
var
  LDir: string;
begin
  Result := False;
  LDir := DetectLazarusDir();
  if LDir = '' then Exit;              // nothing detected yet - nothing to lock
  if not InPlaceInstallPresent(LDir) then Exit;
  Result := ExeIsRunning(LDir + '\lazarus.exe');
end;

function InitializeSetup(): Boolean;
var
  MsgText: string;
  ErrCode: Integer;
begin
  // Lazarus must be installed - this is an IDE integration.
  if DetectLazarusDir() = '' then
  begin
    MsgBox('No Lazarus installation was found (no lazbuild.exe on the usual paths).' + #13#10#13#10
        + 'Install Lazarus first, then run this setup. You can also point the '
        + 'installer at a custom folder on the next screens.',
      mbInformation, MB_OK);
    // Not fatal: the user can still type a path on the Lazarus page.
  end;
  // Nag to close OUR IDE: the build replaces exactly that binary, and a running
  // image cannot be overwritten.
  while AefosIdeIsRunning() do
  begin
    if MsgBox('The Aefos IDE is OPEN. Close it before continuing - this setup replaces '
        + 'that program:' + #13#10 + '    ' + AefosIdeExePath() + #13#10#13#10
        + 'Click Retry after closing it.',
      mbConfirmation, MB_RETRYCANCEL) = IDCANCEL then
    begin
      Result := False;
      Exit;
    end;
  end;
  // Nag to close HIS Lazarus ONLY when there is an in-place install to migrate:
  // that migration hands him his stock lazarus.exe back, which means replacing a
  // file the running IDE holds locked. Without an in-place install his IDE is
  // never touched and there is nothing to close.
  while UserLazarusMustBeClosed() do
  begin
    if MsgBox('Your own Lazarus is OPEN, and this machine still has the OLD Aefos '
        + 'installed INSIDE it.' + #13#10#13#10
        + 'Setup will hand you your original lazarus.exe back before installing '
        + 'the new, separate Aefos IDE - and replacing that file needs Lazarus '
        + 'closed. Close it and click Retry.',
      mbConfirmation, MB_RETRYCANCEL) = IDCANCEL then
    begin
      Result := False;
      Exit;
    end;
  end;
  // WebView2 Runtime gate (chat renders through it).
  while not WebView2RuntimeInstalled() do
  begin
    if IsOnline() then
    begin
      MsgText := 'Microsoft WebView2 Runtime was not found. The Aefos chat renders through '
          + 'it - without it the panel is black.' + #13#10#13#10
          + 'The download page is opening now. Install it, then click Retry. '
          + 'Cancel aborts.';
      ShellExec('open', CWebView2BootstrapUrl, '', '', SW_SHOWNORMAL, ewNoWait, ErrCode);
    end
    else
      MsgText := 'You are OFFLINE and the WebView2 Runtime is not installed.' + #13#10#13#10
          + 'Connect to the internet, install it from' + #13#10 + '    '
          + CWebView2BootstrapUrl + #13#10 + 'then run this setup again.';
    if MsgBox(MsgText, mbConfirmation, MB_RETRYCANCEL) = IDCANCEL then
    begin
      Result := False;
      Exit;
    end;
  end;
  Result := True;
end;

// Line callback shared by BOTH hidden engines (migration and install). EVERY line
// is kept for the log file, but only phase-level lines reach the wizard: the
// FPC/make stream is ~500 lines of hints and notes, which is exactly the console
// noise we are getting rid of.
procedure _OnEngineLog(const S: string; const Error, FirstLine: Boolean);
var
  LLine: string;
begin
  GEngineLog := GEngineLog + S + #13#10;
  LLine := Trim(S);
  if LLine = '' then Exit;
  // '--' = an engine phase banner (both engines print those); Compiling/Linking =
  // FPC's own progress, which is what makes the couple-of-minutes build look alive
  // instead of hung.
  if (Pos('--', LLine) = 1) or (Pos('Compiling ', LLine) > 0)
     or (Pos('Linking ', LLine) > 0) then
  begin
    if Length(LLine) > 88 then
      LLine := Copy(LLine, 1, 85) + '...';
    WizardForm.FilenameLabel.Caption := LLine;
    WizardForm.FilenameLabel.Update;
  end;
end;

// ---------------------------------------------------------------------------
// MIGRATION (slice F5) - hand back the IDE an in-place install took over.
// ---------------------------------------------------------------------------
// Where the isolated engines write their journal/report/log. Same value the
// migration engine would derive on its own (%LOCALAPPDATA%\Aefos\lazarus), passed
// explicitly so the paths we QUOTE at the user are the paths it actually used.
function AefosHomeDir(): string;
begin
  Result := ExpandConstant('{localappdata}\Aefos\lazarus');
end;

// Runs the migration engine HIDDEN from {tmp} and streams it into the wizard.
// Returns the engine's exit code, or -1 when it could not be started at all.
function _RunMigration(): Integer;
var
  LParams: string;
  LCode: Integer;
begin
  Result := -1;
  try
    // dontcopy payload: extracted on demand, never installed. The migration
    // engine resolves the LEGACY uninstall engine beside itself
    // (aefos-laz-migrate.ps1:458), so both must land in the same {tmp}.
    ExtractTemporaryFile('aefos-laz-migrate.ps1');
    ExtractTemporaryFile('aefos-laz-uninstall.ps1');
  except
    Exit;
  end;
  LParams := '-NoProfile -ExecutionPolicy Bypass -File "'
    + ExpandConstant('{tmp}\aefos-laz-migrate.ps1') + '"'
    + ' -LazarusDir "' + GetLazarusDir('') + '"'
    + ' -Pcp "' + ExpandConstant('{localappdata}\lazarus') + '"'
    + ' -AefosHome "' + AefosHomeDir() + '"';
  WizardForm.StatusLabel.Caption := 'Checking for a previous Aefos installed inside your Lazarus...';
  GEngineLog := '';
  LCode := -1;
  try
    if not ExecAndLogOutput(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
         LParams, '', SW_HIDE, ewWaitUntilTerminated, LCode, @_OnEngineLog) then
      LCode := -1;
    Result := LCode;
  finally
    WizardForm.FilenameLabel.Caption := '';
    // The engine writes its own report/journal/transcript into AefosHomeDir; this
    // is OUR capture of the stream, and it is the only trace left if the engine
    // died before it could write anything of its own. It lives inside the same
    // directory the uninstall removes, so it is not litter.
    //
    // Written only when there WAS something to migrate or something went wrong: on
    // a clean machine the migration is a one-second no-op, and a log saying
    // "nothing to do" is a file the user did not ask for. (It is declared in
    // scripts\aefos-laz-isolated-layout.ps1 either way - an undeclared entry fails
    // the install, which is exactly how this interaction was found.)
    if GHadInPlaceInstall or (Result <> 0) then
    begin
      ForceDirectories(AefosHomeDir());
      SaveStringToFile(AefosHomeDir() + '\migration-setup.log', GEngineLog, False);
    end;
  end;
end;

// The LAST point at which setup can still say "do not install" - and it runs
// BEFORE any file of ours is written, which is exactly what the migration needs:
// a refusal must cost the user nothing.
//
// EXIT CODE CONTRACT (scripts\aefos-laz-migrate.ps1:118-126):
//   0  nothing to migrate, or migrated and verified   -> continue, say nothing
//   3  PARTIAL: everything reversible was reverted; something is left that only
//      the user can finish. His IDE still works.      -> continue, SHOW the report
//   4  REFUSED: the machine is not in a state the migration can reason about.
//      NOTHING was changed.                           -> STOP
//   1  hard error                                     -> STOP (same reason as 4:
//      an undo that failed halfway is not a machine to install a second IDE on)
//  -1  the engine could not be started at all         -> STOP
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  LExit: Integer;
begin
  Result := '';
  GHadInPlaceInstall := InPlaceInstallPresent(GetLazarusDir(''));
  LExit := _RunMigration();
  if LExit = 0 then Exit;
  if LExit = 3 then
  begin
    MsgBox('Your Lazarus was given back, but not completely.' + #13#10#13#10
        + 'Everything that could be reverted was reverted - your IDE works - and '
        + 'one item needs you to finish it by hand. The report says exactly '
        + 'which:' + #13#10 + '    ' + AefosHomeDir() + '\migration-report.txt'
        + #13#10#13#10 + 'Installation continues.',
      mbInformation, MB_OK);
    Exit;
  end;
  // Anything else stops setup, with NOTHING installed.
  Result := 'Aefos could not safely give your Lazarus back (migration exit '
      + IntToStr(LExit) + '), so nothing was installed.' + #13#10#13#10
      + 'Your machine was NOT changed. What the migration found, and what it '
      + 'needs from you, is in:' + #13#10 + '    ' + AefosHomeDir()
      + '\migration-setup.log' + #13#10#13#10
      + 'The usual causes: Lazarus is still open, or your Lazarus folder is not '
      + 'writable by your user (a Lazarus installed under Program Files needs an '
      + 'administrator to hand the binary back).';
end;

// Runs the ISOLATED install engine HIDDEN and streams it into the wizard. Returns
// the engine's exit code (-1 if it could not be started at all).
//
// ONLY TWO ARGUMENTS, AND THAT IS DELIBERATE. -SourceRoot is mandatory (it is
// where the .lpk, the source tree and the three runtime DLLs are). -LazarusDir is
// the tree the user confirmed on the wizard page. EVERYTHING ELSE - the target
// %LOCALAPPDATA%\Aefos\lazarus, his %LOCALAPPDATA%\lazarus config, the Start-menu
// folder - comes from the engine's OWN defaults, because those defaults are what
// the isolated round-trip gate exercises. Passing them
// from here would mean shipping a path the gate never tested.
function _RunIsolatedInstall(): Integer;
var
  LParams: string;
  LLogPath: string;
  LCode: Integer;
begin
  LParams := '-NoProfile -ExecutionPolicy Bypass -File "'
    + ExpandConstant('{app}\aefos-laz-install-isolated.ps1') + '"'
    + ' -SourceRoot "' + ExpandConstant('{app}') + '"'
    + ' -LazarusDir "' + GetLazarusDir('') + '"';
  // The ONE exception to "only two arguments": the desktop shortcut is a CHOICE
  // the user makes on the wizard, and only the wizard knows it. The path of the
  // desktop folder is NOT passed - the engine resolves it itself
  // (Get-AefosIsolatedDesktopDir, which follows a OneDrive-relocated desktop),
  // exactly like the Start-menu folder, so what ships is what the gate exercises.
  if WizardIsTaskSelected('desktopicon') then
    LParams := LParams + ' -DesktopShortcut';
  WizardForm.StatusLabel.Caption := 'Building the Aefos IDE (a couple of minutes). Your Lazarus is not modified...';
  // The build reports no percentage, so a marquee is the honest indicator.
  WizardForm.ProgressGauge.Style := npbstMarquee;
  GEngineLog := '';
  LCode := -1;
  try
    // Param order mirrors Exec(): ShowCmd BEFORE Wait. SW_HIDE is the whole point
    // - no console window; the output arrives through _OnEngineLog instead.
    if not ExecAndLogOutput(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
         LParams, '', SW_HIDE, ewWaitUntilTerminated, LCode, @_OnEngineLog) then
      LCode := -1;
    Result := LCode;
  finally
    WizardForm.ProgressGauge.Style := npbstNormal;
    WizardForm.FilenameLabel.Caption := '';
    // Keep the full stream on disk either way - this is the only forensic trail
    // now that no console lingers on screen. Every explicit write the engine makes
    // is announced in it as a WROTE: line, so "what did you put on my machine" is
    // answerable from this file alone.
    LLogPath := ExpandConstant('{app}\aefos-laz-install.log');
    SaveStringToFile(LLogPath, GEngineLog, False);
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  LExit: Integer;
  LWhy: string;
  LOldEntry: string;
  LStartFrom: string;
begin
  if CurStep <> ssPostInstall then Exit;
  LExit := _RunIsolatedInstall();
  if LExit <> 0 then
  begin
    // Never claim success on a failed build: without our IDE there is no product.
    // The exit codes come from scripts\aefos-laz-install-isolated.ps1.
    case LExit of
      1: LWhy := 'The IDE could not be built (or a runtime DLL was missing from this installer).';
      2: LWhy := 'Setup refused before building: no usable Lazarus, or the install target was not a place we may write.';
      3: LWhy := 'The install produced something it cannot account for and stopped rather than leave it there.';
      4: LWhy := 'The IDE was built but does not start, so it is not being called installed.';
    else
      LWhy := 'The install engine could not be run.';
    end;
    MsgBox('The Aefos IDE could not be installed (exit ' + IntToStr(LExit) + ').' + #13#10#13#10
        + LWhy + #13#10#13#10
        + 'YOUR OWN LAZARUS WAS NOT MODIFIED - this installer never writes in it. '
        + 'The full build output is at:' + #13#10 + '    '
        + ExpandConstant('{app}\aefos-laz-install.log'),
      mbCriticalError, MB_OK);
    Exit;
  end;
  // From here on the IDE really exists. The final page reads this.
  GInstallOk := True;
  // A machine that HAD the in-place edition also has its old entry in Apps &
  // features - a different, MACHINE-WIDE installation this per-user setup cannot
  // and must not touch (it lives in Program Files, under an HKLM key). Say so,
  // once, instead of leaving him to wonder why Aefos is listed twice.
  //
  // And say what its uninstaller will do, because we know: aefos-laz-uninstall.ps1
  // sets $IdeIsClean := ($restored -or $rebuilt) (:495) and neither can happen once
  // the migration has already given him his stock binary back - so it takes the
  // "could not restore" path, drops AEFOS-UNINSTALL-README.txt in his Lazarus
  // folder (:663) and exits 1. That note's instructions are wrong AFTER a
  // migration (it claims his lazarus.exe still has Aefos compiled in). We cannot
  // fix a script that is already installed in someone else's directory; we can
  // warn him before he reads it and worries.
  // WHERE HE OPENS IT, in the words that match what is actually on his machine.
  // The desktop line is printed only when the box was ticked, because telling a
  // user to look for an icon that was not created is worse than not telling him
  // anything - and that is the same defect, mirrored, that this slice fixes.
  if WizardIsTaskSelected('desktopicon') then
    LStartFrom := '        the "{#IdeName}" icon on your desktop' + #13#10
        + '        or Start menu > Aefos AI > {#IdeName}'
  else
    LStartFrom := '        Start menu > Aefos AI > {#IdeName}';
  LOldEntry := '';
  if GHadInPlaceInstall then
    // NOTE the leading '' + : a line that STARTS with #13 is read by the ISPP
    // preprocessor as a directive ("Unknown preprocessor directive"), because #
    // in column 1 is its own syntax. Keep every continuation line starting with a
    // quote or a '+'.
    LOldEntry := '' + #13#10#13#10 + 'One more thing: the OLDER Aefos AI (Lazarus) is still listed in Apps '
        + '& features - it was installed for the whole machine, this one is just '
        + 'for you, so they are separate. Your Lazarus has already been handed '
        + 'back, so you can remove it there. Its old uninstaller may leave a note '
        + 'file (AEFOS-UNINSTALL-README.txt) in your Lazarus folder whose '
        + 'instructions no longer apply - you can simply delete it.';
  // The closing screen has ONE job beyond "it worked": leave no doubt about what
  // now exists on this machine. A user who reads "installed" and then finds a
  // second IDE gets a fright - which is exactly what happened - so the two exes
  // are named, side by side, with their paths.
  MsgBox('Aefos AI (Lazarus) installed.' + #13#10#13#10
        + 'THIS SETUP BUILT A LAZARUS OF ITS OWN. There are now two separate IDEs '
        + 'on this machine, and they are handled separately:' + #13#10#13#10
        + '  1. YOURS - ' + GetLazarusDir('') + '\lazarus.exe' + #13#10
        + '     Untouched: same exe, same configuration, same packages, and its '
        + 'desktop shortcut (if it has one) still opens exactly it.' + #13#10#13#10
        + '  2. OURS  - ' + AefosIdeExePath() + #13#10
        + '     Built from yours, installed in your user folder, with its own icon '
        + 'and its own configuration. Start it from:' + #13#10
        + LStartFrom + #13#10#13#10
        + 'Aefos - the chat, the terminal and the MCP server - lives in the second '
        + 'one only. The two open side by side.' + #13#10#13#10
        + 'To use your own AI CLI (Claude, Codex, Gemini, ...), make sure it is on '
        + 'PATH; the chat also supports local models via Ollama.' + LOldEntry,
      mbInformation, MB_OK);
end;

// -------- The LAST screen must say what happened -----------------------------
// WHEN THE MESSAGE ABOVE APPEARS, AND WHY THAT WAS NOT ENOUGH
// ----------------------------------------------------------
// CurStepChanged(ssPostInstall) runs at the END of the install step and BEFORE
// the wizard switches to its Finished page. So the two-IDE explanation is a modal
// that pops over the progress page, and the very last thing left on screen after
// the user clicks OK is Inno's DEFAULT finished text: "Setup has finished
// installing [name] on your computer... Click Finish to exit Setup." That page
// says nothing about a second IDE, about where it is, or about how to open it -
// which is exactly the screen the owner was looking at when he went hunting for a
// desktop icon that did not exist.
//
// The modal is not swallowed (only /SILENT would do that), it is simply TRANSIENT.
// The fix is to put the standing facts where they stay put: on the page the user
// reads before clicking Finish. Kept SHORT on purpose - FinishedLabel is a fixed
// area, and text longer than it can show is text nobody reads.
procedure CurPageChanged(CurPageID: Integer);
var
  LOpen: string;
begin
  if CurPageID <> wpFinished then Exit;
  if not GInstallOk then Exit;
  if WizardIsTaskSelected('desktopicon') then
    LOpen := 'the "{#IdeName}" icon on your desktop,' + #13#10
                 + '   or Start menu > Aefos AI.'
  else
    LOpen := 'Start menu > Aefos AI >' + #13#10 + '   {#IdeName}.';
  // The label is a fixed box on a page whose left half is the wizard image, so the
  // text is written in SHORT lines with explicit breaks (WordWrap only breaks on
  // spaces - a full path would be cut off) and the box is grown to the page.
  WizardForm.FinishedLabel.Height :=
    WizardForm.FinishedPage.Height - WizardForm.FinishedLabel.Top - ScaleY(8);
  WizardForm.FinishedLabel.Caption := 'Aefos AI built a Lazarus IDE OF ITS OWN.' + #13#10
      + 'There are now TWO IDEs on this machine.' + #13#10#13#10
      + 'YOURS is untouched: same exe, same' + #13#10
      + '   configuration, same packages.' + #13#10#13#10
      + 'OURS is the one that has Aefos in it' + #13#10
      + '   (chat, terminal, MCP server), and it' + #13#10
      + '   lives in your user folder:' + #13#10
      + '   %LOCALAPPDATA%\Aefos\lazarus' + #13#10#13#10
      + 'Open it from ' + LOpen + #13#10#13#10
      + 'Click Finish to exit Setup.';
end;

// -------- Uninstall: refuse while OUR IDE is running -------------------------
// Without this the uninstall engine would exit 3 ("the Aefos IDE is RUNNING"),
// Inno would carry on regardless - it does not read that exit code - and the user
// would be left with {app} and the registry entry gone but ~240 MB of isolated IDE
// in %LOCALAPPDATA%\Aefos\lazarus and nothing left that knows how to remove it.
function InitializeUninstall(): Boolean;
begin
  Result := True;
  while AefosIdeIsRunning() do
  begin
    if MsgBox('The Aefos IDE is OPEN. Close it before removing Aefos AI:' + #13#10
        + '    ' + AefosIdeExePath() + #13#10#13#10
        + 'Click Retry after closing it.',
      mbConfirmation, MB_RETRYCANCEL) = IDCANCEL then
    begin
      Result := False;
      Exit;
    end;
  end;
end;
