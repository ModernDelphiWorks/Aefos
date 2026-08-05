; ============================================================================
;  Aefos - Inno Setup installer (multi-version)
;
;  Deploys the Aefos plugin (Chat + Terminal) into a target machine's RAD Studio
;  IDE. The installer ships every Delphi version that was staged into .\bpl\<ver>
;  by build-installer.ps1 and lets the user CHOOSE which to install (a checkbox
;  page; only versions detected on this machine are enabled). For each chosen
;  version it copies that version's BPLs into the matching RAD Studio public Bpl
;  dir and registers the design packages under that version's Known Packages.
;
;  Supported design-time versions (the only IDEs that load a plugin):
;    22.0 = Delphi 11 Alexandria  23.0 = Delphi 12 Athens  37.0 = Delphi 13
;
;  Delphi 13 counts as TWO targets, not one: it ships a second IDE executable
;  (bin64\bds.exe), and a design-time package is loaded into the IDE PROCESS -- so
;  a Win32 BPL is invisible to the 64-bit IDE and vice-versa. The Win64 set is
;  built separately, installed into Bpl\Win64, and registered under its own
;  "Known Packages x64" key.
;
;  Per-version BPLs are RTL-version-specific and CANNOT be shared - a Delphi 12
;  BPL will not load in Delphi 13 and vice-versa. They share a filename but live
;  in per-version folders (Studio\<ver>\Bpl) and are registered under per-version
;  registry keys, so the two IDEs coexist with no clash.
;
;  NOTE: there is NO sqlite3.dll. SQLite is STATICALLY linked into
;  Aefos.Data.bpl (FireDAC.Phys.SQLiteWrapper.Stat) - nothing to bundle.
;
;  PREREQUISITES (DEV machine, before building this installer):
;    1. Build the group for each version you want to ship:
;         pwsh -File scripts\build-packages.ps1            (all installed versions)
;       in RELEASE/Win32 (design-time BPLs load into the 32-bit IDE).
;    2. pwsh -File installer\build-installer.ps1  (stages .\bpl\<ver> + runs ISCC)
;
;  PREREQUISITES (TARGET machine):
;    - At least one supported RAD Studio version installed (this IS a plugin).
;    - WebView2 Evergreen Runtime: VALIDATED up front (registry). If missing the
;      setup STOPS with a clear message + the download link - Chat is black
;      without it. The small WebView2Loader.dll is shipped by us beside the BPLs.
;    - CLOSE RAD Studio before installing (the IDE locks the BPLs + reads the
;      Known Packages registry at startup).
; ============================================================================

#define AppName    "Aefos"
#define AppVer     "1.4.0"
#define Publisher  "ModernDelphiWorks"
; The BPLs are STAGED into .\bpl\<ver> by build-installer.ps1 (per Delphi version).
#define BplSrc     "bpl"

; --- supported design-time IDE versions ------------------------------------
#define VerD11     "22.0"
#define VerD12     "23.0"
#define VerD13     "37.0"

; A version's payload is emitted ONLY if its BPLs were staged, so building just
; one Delphi yields a single-version installer (FileExists is a compile-time check).
#define HaveD11  FileExists(AddBackslash(SourcePath) + BplSrc + "\" + VerD11 + "\Aefos.OTA.Chat.bpl")
#define HaveD12  FileExists(AddBackslash(SourcePath) + BplSrc + "\" + VerD12 + "\Aefos.OTA.Chat.bpl")
#define HaveD13  FileExists(AddBackslash(SourcePath) + BplSrc + "\" + VerD13 + "\Aefos.OTA.Chat.bpl")
; The 64-bit IDE payload is independent: -Platform Win32 (the default) stages
; nothing under Win64 and the whole block below vanishes at compile time.
#define HaveD13x FileExists(AddBackslash(SourcePath) + BplSrc + "\" + VerD13 + "\Win64\Aefos.OTA.Chat.bpl")
#if !HaveD11 && !HaveD12 && !HaveD13
  #error No staged BPLs found under .\bpl\<ver>. Run scripts\build-packages.ps1 then installer\build-installer.ps1.
#endif

; WebView2 Evergreen STANDALONE offline installer (optional embed, -DBundleWebView2).
#ifndef WV2Arch
  #define WV2Arch "X64"
#endif

[Languages]
Name: "en";   MessagesFile: "compiler:Default.isl"
Name: "ptbr"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"

[Setup]
AppId={{8F3C1A20-DE45-4B77-9C61-DA7A5E2F0B31}
AppName={#AppName}
AppVersion={#AppVer}
AppPublisher={#Publisher}
DefaultDirName={localappdata}\Aefos
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputBaseFilename=Aefos-Setup-{#AppVer}
OutputDir=Output
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ShowLanguageDialog=yes
; The SETUP itself stays a 32-bit process. This says nothing about the packages:
; Delphi 13 gained a 64-bit IDE and we now ship Win64 BPLs for it (see HaveD13x).
; What this setting controls is where {pf} and the registry redirector point, and
; every path here is written literally, so 32-bit mode is both correct and the
; safer default on a machine with no 64-bit IDE at all.
ArchitecturesInstallIn64BitMode=

[Files]
; mcp-bridge + pytools are version-independent - install once regardless of which
; IDE versions are selected. (mcp-bridge.ps1 is a tracked source file, referenced
; relative to installer/, not a build artifact, so it is not staged into .\bpl.)
Source: "..\mcp-bridge.ps1"; DestDir: "{app}"; Flags: ignoreversion
; uninsneveruninstall: %APPDATA%\Aefos\pytools is the SAME drop-folder store the
; Lazarus edition's PyTools window/MCP tools read and write (see
; Aefos.Lazarus.PyToolsStore.DefaultRoot - "the SAME root the RAD Studio plugin
; uses"). Uninstalling Delphi must not delete a Lazarus user's built-in example
; tools (or their own custom ones, which the uninstaller never touches anyway -
; it only removes files it itself installed). One brain, one pytools\ folder.
Source: "..\source\mcp\Tools\pytools\*"; DestDir: "{userappdata}\Aefos\pytools"; \
  Flags: recursesubdirs createallsubdirs ignoreversion uninsneveruninstall
; Built-in project templates (drop-folder library the ListProjectTemplates /
; CreateProjectFromTemplate tools read). Same pattern as pytools: shipped to the
; per-user templates root the tool resolves (%APPDATA%\Aefos\templates).
;
; uninsneveruninstall: %APPDATA%\Aefos\templates sits in the shared per-user
; "one brain" root (%APPDATA%\Aefos) - the Lazarus package links the same
; Aefos.MCP.Core tree (source\mcp\Core, incl. Aefos.MCP.Tools.Scaffold) that
; reads ATemplatesRoot; today the Lazarus MCP host does not yet register the
; scaffold tools, so this is DEFENSIVE, not proven-consumed. Flagged anyway per
; the "leave it, don't guess" rule - owner can drop the flag once confirmed
; Lazarus-side that nothing wants these to be removable per-edition.
Source: "..\source\mcp\Tools\templates\*"; DestDir: "{userappdata}\Aefos\templates"; \
  Flags: recursesubdirs createallsubdirs ignoreversion uninsneveruninstall
; Agent CLI that drives local models (Phase D). One console exe for every RAD
; Studio version, installed to the per-user bin the plugin resolves first
; (%APPDATA%\Aefos\bin - see _ResolveAgentCliPath). Built by build-packages.ps1.
;
; uninsneveruninstall: lives in the shared per-user bin (%APPDATA%\Aefos\bin,
; the same folder as aefos.exe/codex.exe/gemini.exe below). Verified TODAY the
; Lazarus edition never spawns AefosAgent.exe - its ekOllama path always runs
; the model IN-PROCESS (Aefos.Lazarus.ChatController._DispatchOllama), never
; through ResolveCLIBinary - so this one is genuinely Delphi-only at the moment.
; Flagged anyway to match its shared-folder siblings and the "don't guess, ask"
; rule; owner may prefer to let it delete on uninstall since Lazarus never reads
; it - flagging here for that decision, not removing.
Source: "..\cli\bin\AefosAgent.exe"; DestDir: "{userappdata}\Aefos\bin"; Flags: ignoreversion uninsneveruninstall

; Aefos addon manager (aefos.exe). One console exe for every RAD Studio version,
; installed beside AefosAgent.exe in the per-user bin. Used by the [Run] step
; below to SEED the bundled Desktop MCP addon OFFLINE (no download). Built by
; scripts\build-aefos-cli.ps1. skipifsourcedoesntexist: a build that did not
; stage it simply omits the offline seed (the addon is still installable online).
; uninsneveruninstall: aefos.exe is SHARED with the Lazarus edition, which installs
; the same binary to this same per-user bin (installer\lazarus\Aefos-Lazarus.iss
; carries the same flag). Whichever edition installs it last owns the bytes;
; NEITHER may delete it on uninstall, or removing one edition silently breaks
; `aefos install <mcp>` for a user still running the other. One brain, one
; aefos.exe: the shared state outlives either edition's uninstall.
Source: "..\cli\bin\aefos.exe"; DestDir: "{userappdata}\Aefos\bin"; Flags: ignoreversion skipifsourcedoesntexist uninsneveruninstall

; Bundled Desktop MCP addon (offline), when a packed dist is present. The Desktop
; MCP is an ADDON: it is published in the addons repository and normally obtained
; with `aefos install desktop` (binary included). Only the source of its server
; executable lives in this repo, so nothing here produces the dist.
; If a dist IS staged under mcps\desktop\dist, it rides along verbatim into
; {app}\addons and the [Run] step seeds it with no download.
; skipifsourcedoesntexist: without it, the installer simply ships online-only.
Source: "..\mcps\desktop\dist\registry.json"; DestDir: "{app}\addons"; Flags: ignoreversion skipifsourcedoesntexist
Source: "..\mcps\desktop\dist\addons\*"; DestDir: "{app}\addons\addons"; Flags: recursesubdirs createallsubdirs ignoreversion skipifsourcedoesntexist

; Bundled third-party AI CLIs (out-of-the-box, like the IDE's built-in AI ships them). Staged fresh
; each release by installer\fetch-clis.ps1 into installer\redist\cli\ (gitignored
; *.exe), then installed beside AefosAgent.exe in the per-user bin the plugin's
; CLIBinaryResolver checks after PATH. skipifsourcedoesntexist: a binary not
; staged this build is simply omitted. ONLY the Apache-2.0 CLIs are bundled:
;   - codex  : official standalone binary.
;   - gemini : Apache-2.0 permits our Node SEA repackage (fetch script, phase 2).
; NOT bundled (detect-only): Claude Code (proprietary/non-redistributable) AND
; GitHub Copilot CLI - its license permits only UNMODIFIED redistribution and
; explicitly forbids wrapping/repackaging, but there is no official standalone
; binary, so the SEA repackage we'd need is exactly what it prohibits.
;
; uninsneveruninstall (both codex.exe and gemini.exe): CONFIRMED shared, not just
; positionally. The Lazarus edition's TAefosLazChatController._DispatchExternalCli
; calls the SAME Aefos.OTA.Chat.Core.CLIBinaryResolver.ResolveCLIBinary (compiled
; into both editions), whose step 4 falls back to %APPDATA%\Aefos\bin\<name>.exe -
; this exact folder. Uninstalling Delphi must not yank codex/gemini out from under
; a Lazarus user who picked either as their executor.
Source: "redist\cli\codex.exe";  DestDir: "{userappdata}\Aefos\bin"; Flags: ignoreversion skipifsourcedoesntexist uninsneveruninstall
Source: "redist\cli\gemini.exe"; DestDir: "{userappdata}\Aefos\bin"; Flags: ignoreversion skipifsourcedoesntexist uninsneveruninstall
; Aggregated Apache-2.0 attribution (NOTICE + LICENSE) for the bundled CLIs.
; uninsneveruninstall: rides along with codex.exe/gemini.exe above - a license
; notice orphaned by a Delphi uninstall while the binaries it covers keep running
; under Lazarus would be a compliance gap, not just clutter.
Source: "redist\cli\THIRD-PARTY-LICENSES.txt"; DestDir: "{userappdata}\Aefos\bin"; Flags: ignoreversion skipifsourcedoesntexist uninsneveruninstall

; --- Delphi 11 (BDS 22.0) payload - only if staged; installed only if chosen ----
#if HaveD11
Source: "{#BplSrc}\{#VerD11}\Aefos.Harness.bpl";       DestDir: "{commondocs}\Embarcadero\Studio\{#VerD11}\Bpl"; Flags: ignoreversion; Check: WantVer('{#VerD11}')
Source: "{#BplSrc}\{#VerD11}\Aefos.Providers.bpl";     DestDir: "{commondocs}\Embarcadero\Studio\{#VerD11}\Bpl"; Flags: ignoreversion; Check: WantVer('{#VerD11}')
Source: "{#BplSrc}\{#VerD11}\Aefos.Tools.bpl";         DestDir: "{commondocs}\Embarcadero\Studio\{#VerD11}\Bpl"; Flags: ignoreversion; Check: WantVer('{#VerD11}')
Source: "{#BplSrc}\{#VerD11}\Aefos.MCP.Core.bpl";      DestDir: "{commondocs}\Embarcadero\Studio\{#VerD11}\Bpl"; Flags: ignoreversion; Check: WantVer('{#VerD11}')
Source: "{#BplSrc}\{#VerD11}\Aefos.MCP.Tools.OTA.bpl"; DestDir: "{commondocs}\Embarcadero\Studio\{#VerD11}\Bpl"; Flags: ignoreversion; Check: WantVer('{#VerD11}')
Source: "{#BplSrc}\{#VerD11}\Aefos.Data.bpl";          DestDir: "{commondocs}\Embarcadero\Studio\{#VerD11}\Bpl"; Flags: ignoreversion; Check: WantVer('{#VerD11}')
Source: "{#BplSrc}\{#VerD11}\Aefos.WebView.bpl";       DestDir: "{commondocs}\Embarcadero\Studio\{#VerD11}\Bpl"; Flags: ignoreversion; Check: WantVer('{#VerD11}')
Source: "{#BplSrc}\{#VerD11}\WebView2Loader.dll";      DestDir: "{commondocs}\Embarcadero\Studio\{#VerD11}\Bpl"; Flags: ignoreversion; Check: WantVer('{#VerD11}')
Source: "{#BplSrc}\{#VerD11}\Aefos.OTA.Chat.bpl";      DestDir: "{commondocs}\Embarcadero\Studio\{#VerD11}\Bpl"; Flags: ignoreversion; Check: WantVer('{#VerD11}')
Source: "{#BplSrc}\{#VerD11}\Aefos.OTA.Terminal.bpl";  DestDir: "{commondocs}\Embarcadero\Studio\{#VerD11}\Bpl"; Flags: ignoreversion; Check: WantVer('{#VerD11}')
Source: "{#BplSrc}\{#VerD11}\dclAefosWebView.bpl";     DestDir: "{commondocs}\Embarcadero\Studio\{#VerD11}\Bpl"; Flags: ignoreversion; Check: WantVer('{#VerD11}')
#endif

; --- Delphi 12 (BDS 23.0) payload - only if staged; installed only if chosen ----
#if HaveD12
Source: "{#BplSrc}\{#VerD12}\Aefos.Harness.bpl";       DestDir: "{commondocs}\Embarcadero\Studio\{#VerD12}\Bpl"; Flags: ignoreversion; Check: WantVer('{#VerD12}')
Source: "{#BplSrc}\{#VerD12}\Aefos.Providers.bpl";     DestDir: "{commondocs}\Embarcadero\Studio\{#VerD12}\Bpl"; Flags: ignoreversion; Check: WantVer('{#VerD12}')
Source: "{#BplSrc}\{#VerD12}\Aefos.Tools.bpl";         DestDir: "{commondocs}\Embarcadero\Studio\{#VerD12}\Bpl"; Flags: ignoreversion; Check: WantVer('{#VerD12}')
Source: "{#BplSrc}\{#VerD12}\Aefos.MCP.Core.bpl";      DestDir: "{commondocs}\Embarcadero\Studio\{#VerD12}\Bpl"; Flags: ignoreversion; Check: WantVer('{#VerD12}')
Source: "{#BplSrc}\{#VerD12}\Aefos.MCP.Tools.OTA.bpl"; DestDir: "{commondocs}\Embarcadero\Studio\{#VerD12}\Bpl"; Flags: ignoreversion; Check: WantVer('{#VerD12}')
Source: "{#BplSrc}\{#VerD12}\Aefos.Data.bpl";          DestDir: "{commondocs}\Embarcadero\Studio\{#VerD12}\Bpl"; Flags: ignoreversion; Check: WantVer('{#VerD12}')
Source: "{#BplSrc}\{#VerD12}\Aefos.WebView.bpl";       DestDir: "{commondocs}\Embarcadero\Studio\{#VerD12}\Bpl"; Flags: ignoreversion; Check: WantVer('{#VerD12}')
Source: "{#BplSrc}\{#VerD12}\WebView2Loader.dll";      DestDir: "{commondocs}\Embarcadero\Studio\{#VerD12}\Bpl"; Flags: ignoreversion; Check: WantVer('{#VerD12}')
Source: "{#BplSrc}\{#VerD12}\Aefos.OTA.Chat.bpl";      DestDir: "{commondocs}\Embarcadero\Studio\{#VerD12}\Bpl"; Flags: ignoreversion; Check: WantVer('{#VerD12}')
Source: "{#BplSrc}\{#VerD12}\Aefos.OTA.Terminal.bpl";  DestDir: "{commondocs}\Embarcadero\Studio\{#VerD12}\Bpl"; Flags: ignoreversion; Check: WantVer('{#VerD12}')
Source: "{#BplSrc}\{#VerD12}\dclAefosWebView.bpl";     DestDir: "{commondocs}\Embarcadero\Studio\{#VerD12}\Bpl"; Flags: ignoreversion; Check: WantVer('{#VerD12}')
#endif

; --- Delphi 13 (BDS 37.0) payload - only if staged; installed only if chosen ----
#if HaveD13
Source: "{#BplSrc}\{#VerD13}\Aefos.Harness.bpl";       DestDir: "{commondocs}\Embarcadero\Studio\{#VerD13}\Bpl"; Flags: ignoreversion; Check: WantVer('{#VerD13}')
Source: "{#BplSrc}\{#VerD13}\Aefos.Providers.bpl";     DestDir: "{commondocs}\Embarcadero\Studio\{#VerD13}\Bpl"; Flags: ignoreversion; Check: WantVer('{#VerD13}')
Source: "{#BplSrc}\{#VerD13}\Aefos.Tools.bpl";         DestDir: "{commondocs}\Embarcadero\Studio\{#VerD13}\Bpl"; Flags: ignoreversion; Check: WantVer('{#VerD13}')
Source: "{#BplSrc}\{#VerD13}\Aefos.MCP.Core.bpl";      DestDir: "{commondocs}\Embarcadero\Studio\{#VerD13}\Bpl"; Flags: ignoreversion; Check: WantVer('{#VerD13}')
Source: "{#BplSrc}\{#VerD13}\Aefos.MCP.Tools.OTA.bpl"; DestDir: "{commondocs}\Embarcadero\Studio\{#VerD13}\Bpl"; Flags: ignoreversion; Check: WantVer('{#VerD13}')
Source: "{#BplSrc}\{#VerD13}\Aefos.Data.bpl";          DestDir: "{commondocs}\Embarcadero\Studio\{#VerD13}\Bpl"; Flags: ignoreversion; Check: WantVer('{#VerD13}')
Source: "{#BplSrc}\{#VerD13}\Aefos.WebView.bpl";       DestDir: "{commondocs}\Embarcadero\Studio\{#VerD13}\Bpl"; Flags: ignoreversion; Check: WantVer('{#VerD13}')
Source: "{#BplSrc}\{#VerD13}\WebView2Loader.dll";      DestDir: "{commondocs}\Embarcadero\Studio\{#VerD13}\Bpl"; Flags: ignoreversion; Check: WantVer('{#VerD13}')
Source: "{#BplSrc}\{#VerD13}\Aefos.OTA.Chat.bpl";      DestDir: "{commondocs}\Embarcadero\Studio\{#VerD13}\Bpl"; Flags: ignoreversion; Check: WantVer('{#VerD13}')
Source: "{#BplSrc}\{#VerD13}\Aefos.OTA.Terminal.bpl";  DestDir: "{commondocs}\Embarcadero\Studio\{#VerD13}\Bpl"; Flags: ignoreversion; Check: WantVer('{#VerD13}')
Source: "{#BplSrc}\{#VerD13}\dclAefosWebView.bpl";     DestDir: "{commondocs}\Embarcadero\Studio\{#VerD13}\Bpl"; Flags: ignoreversion; Check: WantVer('{#VerD13}')
#endif

; --- Delphi 13, 64-bit IDE (bin64\bds.exe) - a SEPARATE set of packages --------
; Delphi 13 ships two IDE executables, and a design-time BPL is loaded into the
; IDE PROCESS: a Win32 package simply does not appear in the 64-bit IDE, and vice
; versa. So this is a second build (Platform=Win64), installed into the Win64
; subfolder the IDE itself writes to, and registered under its OWN registry key --
; "Known Packages x64", which is a different key from the 32-bit one (verified: 80
; entries there, all under $(BDS)\bin64).
;
; Optional exactly like a version payload: build-packages.ps1 -Platform Win32 (the
; default) stages nothing here, and this whole block disappears at compile time.
#if HaveD13x
Source: "{#BplSrc}\{#VerD13}\Win64\Aefos.Harness.bpl";       DestDir: "{commondocs}\Embarcadero\Studio\{#VerD13}\Bpl\Win64"; Flags: ignoreversion; Check: WantVer('{#VerD13}')
Source: "{#BplSrc}\{#VerD13}\Win64\Aefos.Providers.bpl";     DestDir: "{commondocs}\Embarcadero\Studio\{#VerD13}\Bpl\Win64"; Flags: ignoreversion; Check: WantVer('{#VerD13}')
Source: "{#BplSrc}\{#VerD13}\Win64\Aefos.Tools.bpl";         DestDir: "{commondocs}\Embarcadero\Studio\{#VerD13}\Bpl\Win64"; Flags: ignoreversion; Check: WantVer('{#VerD13}')
Source: "{#BplSrc}\{#VerD13}\Win64\Aefos.MCP.Core.bpl";      DestDir: "{commondocs}\Embarcadero\Studio\{#VerD13}\Bpl\Win64"; Flags: ignoreversion; Check: WantVer('{#VerD13}')
Source: "{#BplSrc}\{#VerD13}\Win64\Aefos.MCP.Tools.OTA.bpl"; DestDir: "{commondocs}\Embarcadero\Studio\{#VerD13}\Bpl\Win64"; Flags: ignoreversion; Check: WantVer('{#VerD13}')
Source: "{#BplSrc}\{#VerD13}\Win64\Aefos.Data.bpl";          DestDir: "{commondocs}\Embarcadero\Studio\{#VerD13}\Bpl\Win64"; Flags: ignoreversion; Check: WantVer('{#VerD13}')
Source: "{#BplSrc}\{#VerD13}\Win64\Aefos.WebView.bpl";       DestDir: "{commondocs}\Embarcadero\Studio\{#VerD13}\Bpl\Win64"; Flags: ignoreversion; Check: WantVer('{#VerD13}')
Source: "{#BplSrc}\{#VerD13}\Win64\Aefos.OTA.Chat.bpl";      DestDir: "{commondocs}\Embarcadero\Studio\{#VerD13}\Bpl\Win64"; Flags: ignoreversion; Check: WantVer('{#VerD13}')
Source: "{#BplSrc}\{#VerD13}\Win64\Aefos.OTA.Terminal.bpl";  DestDir: "{commondocs}\Embarcadero\Studio\{#VerD13}\Bpl\Win64"; Flags: ignoreversion; Check: WantVer('{#VerD13}')
Source: "{#BplSrc}\{#VerD13}\Win64\dclAefosWebView.bpl";     DestDir: "{commondocs}\Embarcadero\Studio\{#VerD13}\Bpl\Win64"; Flags: ignoreversion; Check: WantVer('{#VerD13}')
; A 64-bit IDE process cannot bind the 32-bit loader RAD Studio ships, so this is
; the x64 one -- staged by build-installer.ps1 from the same place the Lazarus
; installer gets it. Without it the chat would fall back to plain text in the
; 64-bit IDE only, which is exactly the kind of difference nobody would think to
; look for.
Source: "{#BplSrc}\{#VerD13}\Win64\WebView2Loader.dll";      DestDir: "{commondocs}\Embarcadero\Studio\{#VerD13}\Bpl\Win64"; Flags: ignoreversion; Check: WantVer('{#VerD13}')
#endif

; --- WebView2 Evergreen STANDALONE (offline) - OPTIONAL embed (-DBundleWebView2) -
#ifdef BundleWebView2
Source: "redist\MicrosoftEdgeWebView2RuntimeInstaller{#WV2Arch}.exe"; Flags: dontcopy
#endif

[Registry]
; Per version: purge stale Disabled/old-layout entries, then register the design
; packages in Known Packages. Each entry is gated by Check: WantVer(<ver>) so only
; the chosen versions are touched. (commondocs = C:\Users\Public\Documents.)

#if HaveD11
Root: HKCU; Subkey: "Software\Embarcadero\BDS\{#VerD11}\Disabled Packages"; ValueType: none; ValueName: "{commondocs}\Embarcadero\Studio\{#VerD11}\Bpl\Aefos.OTA.Chat.bpl";     Flags: deletevalue; Check: WantVer('{#VerD11}')
Root: HKCU; Subkey: "Software\Embarcadero\BDS\{#VerD11}\Disabled Packages"; ValueType: none; ValueName: "{commondocs}\Embarcadero\Studio\{#VerD11}\Bpl\Aefos.OTA.Terminal.bpl"; Flags: deletevalue; Check: WantVer('{#VerD11}')
Root: HKCU; Subkey: "Software\Embarcadero\BDS\{#VerD11}\Disabled Packages"; ValueType: none; ValueName: "{commondocs}\Embarcadero\Studio\{#VerD11}\Bpl\dclAefosWebView.bpl";       Flags: deletevalue; Check: WantVer('{#VerD11}')
Root: HKCU; Subkey: "Software\Embarcadero\BDS\{#VerD11}\Known Packages";    ValueType: string; ValueName: "{commondocs}\Embarcadero\Studio\{#VerD11}\Bpl\Aefos.OTA.Chat.bpl";     ValueData: "Aefos AI - Chat";              Flags: uninsdeletevalue; Check: WantVer('{#VerD11}')
Root: HKCU; Subkey: "Software\Embarcadero\BDS\{#VerD11}\Known Packages";    ValueType: string; ValueName: "{commondocs}\Embarcadero\Studio\{#VerD11}\Bpl\Aefos.OTA.Terminal.bpl"; ValueData: "Aefos AI - Terminal";          Flags: uninsdeletevalue; Check: WantVer('{#VerD11}')
Root: HKCU; Subkey: "Software\Embarcadero\BDS\{#VerD11}\Known Packages";    ValueType: string; ValueName: "{commondocs}\Embarcadero\Studio\{#VerD11}\Bpl\dclAefosWebView.bpl";       ValueData: "Aefos AI - WebView2 component"; Flags: uninsdeletevalue; Check: WantVer('{#VerD11}')
#endif

#if HaveD12
Root: HKCU; Subkey: "Software\Embarcadero\BDS\{#VerD12}\Disabled Packages"; ValueType: none; ValueName: "{commondocs}\Embarcadero\Studio\{#VerD12}\Bpl\Aefos.OTA.Chat.bpl";     Flags: deletevalue; Check: WantVer('{#VerD12}')
Root: HKCU; Subkey: "Software\Embarcadero\BDS\{#VerD12}\Disabled Packages"; ValueType: none; ValueName: "{commondocs}\Embarcadero\Studio\{#VerD12}\Bpl\Aefos.OTA.Terminal.bpl"; Flags: deletevalue; Check: WantVer('{#VerD12}')
Root: HKCU; Subkey: "Software\Embarcadero\BDS\{#VerD12}\Disabled Packages"; ValueType: none; ValueName: "{commondocs}\Embarcadero\Studio\{#VerD12}\Bpl\dclAefosWebView.bpl";       Flags: deletevalue; Check: WantVer('{#VerD12}')
Root: HKCU; Subkey: "Software\Embarcadero\BDS\{#VerD12}\Known Packages";    ValueType: string; ValueName: "{commondocs}\Embarcadero\Studio\{#VerD12}\Bpl\Aefos.OTA.Chat.bpl";     ValueData: "Aefos AI - Chat";              Flags: uninsdeletevalue; Check: WantVer('{#VerD12}')
Root: HKCU; Subkey: "Software\Embarcadero\BDS\{#VerD12}\Known Packages";    ValueType: string; ValueName: "{commondocs}\Embarcadero\Studio\{#VerD12}\Bpl\Aefos.OTA.Terminal.bpl"; ValueData: "Aefos AI - Terminal";          Flags: uninsdeletevalue; Check: WantVer('{#VerD12}')
Root: HKCU; Subkey: "Software\Embarcadero\BDS\{#VerD12}\Known Packages";    ValueType: string; ValueName: "{commondocs}\Embarcadero\Studio\{#VerD12}\Bpl\dclAefosWebView.bpl";       ValueData: "Aefos AI - WebView2 component"; Flags: uninsdeletevalue; Check: WantVer('{#VerD12}')
#endif

#if HaveD13
Root: HKCU; Subkey: "Software\Embarcadero\BDS\{#VerD13}\Disabled Packages"; ValueType: none; ValueName: "{commondocs}\Embarcadero\Studio\{#VerD13}\Bpl\Aefos.OTA.Chat.bpl";     Flags: deletevalue; Check: WantVer('{#VerD13}')
Root: HKCU; Subkey: "Software\Embarcadero\BDS\{#VerD13}\Disabled Packages"; ValueType: none; ValueName: "{commondocs}\Embarcadero\Studio\{#VerD13}\Bpl\Aefos.OTA.Terminal.bpl"; Flags: deletevalue; Check: WantVer('{#VerD13}')
Root: HKCU; Subkey: "Software\Embarcadero\BDS\{#VerD13}\Disabled Packages"; ValueType: none; ValueName: "{commondocs}\Embarcadero\Studio\{#VerD13}\Bpl\dclAefosWebView.bpl";       Flags: deletevalue; Check: WantVer('{#VerD13}')
Root: HKCU; Subkey: "Software\Embarcadero\BDS\{#VerD13}\Known Packages";    ValueType: string; ValueName: "{commondocs}\Embarcadero\Studio\{#VerD13}\Bpl\Aefos.OTA.Chat.bpl";     ValueData: "Aefos AI - Chat";              Flags: uninsdeletevalue; Check: WantVer('{#VerD13}')
Root: HKCU; Subkey: "Software\Embarcadero\BDS\{#VerD13}\Known Packages";    ValueType: string; ValueName: "{commondocs}\Embarcadero\Studio\{#VerD13}\Bpl\Aefos.OTA.Terminal.bpl"; ValueData: "Aefos AI - Terminal";          Flags: uninsdeletevalue; Check: WantVer('{#VerD13}')
Root: HKCU; Subkey: "Software\Embarcadero\BDS\{#VerD13}\Known Packages";    ValueType: string; ValueName: "{commondocs}\Embarcadero\Studio\{#VerD13}\Bpl\dclAefosWebView.bpl";       ValueData: "Aefos AI - WebView2 component"; Flags: uninsdeletevalue; Check: WantVer('{#VerD13}')

; The 64-bit IDE reads a DIFFERENT key. Registering under "Known Packages" alone
; installs nothing visible in the 64-bit IDE -- it reads "Known Packages x64",
; and the two lists never see each other.
#if HaveD13x
Root: HKCU; Subkey: "Software\Embarcadero\BDS\{#VerD13}\Known Packages x64";    ValueType: string; ValueName: "{commondocs}\Embarcadero\Studio\{#VerD13}\Bpl\Win64\Aefos.OTA.Chat.bpl";     ValueData: "Aefos AI - Chat";              Flags: uninsdeletevalue; Check: WantVer('{#VerD13}')
Root: HKCU; Subkey: "Software\Embarcadero\BDS\{#VerD13}\Known Packages x64";    ValueType: string; ValueName: "{commondocs}\Embarcadero\Studio\{#VerD13}\Bpl\Win64\Aefos.OTA.Terminal.bpl"; ValueData: "Aefos AI - Terminal";          Flags: uninsdeletevalue; Check: WantVer('{#VerD13}')
Root: HKCU; Subkey: "Software\Embarcadero\BDS\{#VerD13}\Known Packages x64";    ValueType: string; ValueName: "{commondocs}\Embarcadero\Studio\{#VerD13}\Bpl\Win64\dclAefosWebView.bpl";       ValueData: "Aefos AI - WebView2 component"; Flags: uninsdeletevalue; Check: WantVer('{#VerD13}')
#endif
#endif

[Run]
; Seed the bundled Desktop MCP addon OFFLINE: aefos.exe installs it from the
; local, sha256-pinned dist staged under {app}\addons (no network). The chat
; merges its MCP server from ~/.aefos\addons\mcp-servers.json on the next
; provision, so the tools are visible out-of-the-box. Idempotent (clean-replace),
; so a repair/upgrade re-run is safe. runhidden: no console window. Check +
; skipifdoesntexist: no-op when either aefos.exe or the dist was not staged, so
; the installer degrades to online-only without failing.
Filename: "{userappdata}\Aefos\bin\aefos.exe"; \
  Parameters: "install desktop --registry ""{app}\addons\registry.json"" -y"; \
  WorkingDir: "{userappdata}\Aefos\bin"; \
  StatusMsg: "Installing the bundled Desktop MCP addon..."; \
  Flags: runhidden skipifdoesntexist runascurrentuser; \
  Check: DesktopAddonBundled

[UninstallDelete]
; .mcp.json is generated in [Code] (not [Files]), so remove it explicitly.
Type: files; Name: "{app}\.mcp.json"

[Tasks]
; Optional: download the GitHub Copilot CLI's OFFICIAL portable zip during setup
; (integrated download page) and extract copilot.exe into the Aefos bin, where the
; plugin's resolver finds it. Aefos cannot BUNDLE Copilot (its license forbids
; repackaging), but downloading the genuine, unmodified official release on the
; user's own machine is clean. Off by default: it needs internet, and Copilot itself
; needs a Copilot subscription to run.
Name: "copilotcli"; Description: "Download GitHub Copilot CLI (official release - needs a Copilot subscription)"; Flags: unchecked

[Code]
// ===========================================================================
//  Version selection. The installer ships whatever build-installer.ps1 staged;
//  here we surface a checkbox per SHIPPED version, enable only the ones detected
//  on this machine, and gate every [Files]/[Registry] entry on the user's pick.
// ===========================================================================
var
  PageVersions: TInputOptionWizardPage;
  GVer: array of string;   // versions offered on the checkbox page (Add order)
  DownloadPage: TDownloadWizardPage;  // integrated progress page for the optional Copilot download

const
  // Official Copilot CLI portable zip (a single copilot.exe inside). The 'latest'
  // redirect keeps it evergreen; downloaded only when the 'copilotcli' task is on.
  CCopilotZipUrl = 'https://github.com/github/copilot-cli/releases/latest/download/copilot-win32-x64.zip';

// Defined further down (Inno is top-down); forward-declared so NextButtonClick can call it.
procedure _DownloadCopilot; forward;

function VerInstalled(const Ver: string): Boolean;
begin
  // The per-user BDS key proves the IDE is installed for the current user.
  Result := RegKeyExists(HKCU, 'Software\Embarcadero\BDS\' + Ver);
end;

function VerLabel(const Ver: string): string;
begin
  if Ver = '{#VerD11}' then Result := 'Delphi 11 Alexandria (BDS {#VerD11})'
  else if Ver = '{#VerD12}' then Result := 'Delphi 12 Athens (BDS {#VerD12})'
  else if Ver = '{#VerD13}' then Result := 'Delphi 13 (BDS {#VerD13})'
  else Result := 'RAD Studio (BDS ' + Ver + ')';
end;

function VerOptionIndex(const Ver: string): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to GetArrayLength(GVer) - 1 do
    if GVer[I] = Ver then
    begin
      Result := I;
      Exit;
    end;
end;

// Called from [Files]/[Registry] Check: True only when this version is BOTH
// offered (shipped) and ticked on the page.
function WantVer(const Ver: string): Boolean;
var
  Idx: Integer;
begin
  Idx := VerOptionIndex(Ver);
  Result := (Idx >= 0) and PageVersions.Values[Idx];
end;

procedure AddVersion(const Ver: string);
var
  N: Integer;
begin
  PageVersions.Add(VerLabel(Ver));
  N := GetArrayLength(GVer);
  SetArrayLength(GVer, N + 1);
  GVer[N] := Ver;
  // Default-check installed versions; disable (and leave unchecked) the rest.
  if VerInstalled(Ver) then
    PageVersions.Values[N] := True
  else
    PageVersions.CheckListBox.ItemEnabled[N] := False;
end;

procedure InitializeWizard();
begin
  // Integrated download page for the optional Copilot CLI task (shown only if the
  // task is selected, when leaving the Ready page - see NextButtonClick).
  DownloadPage := CreateDownloadPage(
    'Downloading GitHub Copilot CLI',
    'Fetching the official Copilot CLI release from GitHub...', nil);
  PageVersions := CreateInputOptionPage(wpWelcome,
    SetupMessage(msgWizardSelectComponents),
    'Choose the RAD Studio versions to install Aefos into',
    'Aefos was built for the versions below. Check the ones to install into. '
      + 'Versions not detected on this machine are greyed out. Each gets its own '
      + 'set of BPLs (Delphi 12 and Delphi 13 do not share binaries).',
    False, False);
  SetArrayLength(GVer, 0);
#if HaveD11
  AddVersion('{#VerD11}');
#endif
#if HaveD12
  AddVersion('{#VerD12}');
#endif
#if HaveD13
  AddVersion('{#VerD13}');
#endif
end;

// Block leaving the version page with nothing (installable) selected.
function NextButtonClick(CurPageID: Integer): Boolean;
var
  I: Integer;
  Any: Boolean;
begin
  Result := True;
  if CurPageID = PageVersions.ID then
  begin
    Any := False;
    for I := 0 to GetArrayLength(GVer) - 1 do
      if PageVersions.Values[I] then Any := True;
    if not Any then
    begin
      MsgBox(
        ExpandConstant('{cm:NoVersionSelected}'),
        mbError, MB_OK);
      Result := False;
    end;
  end;
  // Optional Copilot CLI: on leaving the Ready page, download the official zip via
  // the integrated progress page (extracted later in ssPostInstall). Delegated to a
  // proc defined further down - Inno is top-down, hence the forward declaration.
  if (CurPageID = wpReady) and WizardIsTaskSelected('copilotcli') then
    _DownloadCopilot;
end;

// [Run] Check for the offline Desktop MCP seed: true only when the bundled
// registry.json was actually staged into {app}\addons (so a build without the
// dist silently skips the seed instead of erroring).
function DesktopAddonBundled(): Boolean;
begin
  Result := FileExists(ExpandConstant('{app}\addons\registry.json'));
end;

function NeedsAddPath(Param: string): Boolean;
var
  OrigPath: string;
begin
  if not RegQueryStringValue(HKCU, 'Environment', 'Path', OrigPath) then
  begin
    Result := True;
    exit;
  end;
  Result := Pos(';' + Lowercase(Param) + ';', ';' + Lowercase(OrigPath) + ';') = 0;
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

// Downloads the official Copilot CLI zip via the integrated progress page (to
// {tmp}\copilot.zip; extracted in ssPostInstall). A failure (offline / URL down)
// is non-fatal - install proceeds without Copilot.
procedure _DownloadCopilot;
begin
  DownloadPage.Clear;
  DownloadPage.Add(CCopilotZipUrl, 'copilot.zip', '');
  DownloadPage.Show;
  try
    try
      DownloadPage.Download;
    except
      SuppressibleMsgBox(
        'Could not download the GitHub Copilot CLI (offline?). You can install it '
          + 'later from Tools -> Options -> Aefos -> Download CLI.',
        mbInformation, MB_OK, IDOK);
    end;
  finally
    DownloadPage.Hide;
  end;
end;

// Local connectivity probe (no traffic) - only to tell the user whether they can
// reach the internet to fetch the WebView2 Runtime when it is missing.
function InternetGetConnectedState(var lpdwFlags: Cardinal; dwReserved: Cardinal): Boolean;
  external 'InternetGetConnectedState@wininet.dll stdcall';

function IsOnline(): Boolean;
var
  Flags: Cardinal;
begin
  Flags := 0;
  Result := InternetGetConnectedState(Flags, 0);
end;

// --- WebView2 Evergreen Runtime prerequisite -------------------------------
const
  CWebView2ClientGuid   = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';
  CWebView2BootstrapUrl = 'https://go.microsoft.com/fwlink/p/?LinkId=2124703';

function WebView2RuntimeInstalled(): Boolean;
var
  Pv: string;
begin
  Result :=
    (RegQueryStringValue(HKLM,
       'SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\' + CWebView2ClientGuid,
       'pv', Pv) and (Pv <> '') and (Pv <> '0.0.0.0'))
    or
    (RegQueryStringValue(HKLM,
       'SOFTWARE\Microsoft\EdgeUpdate\Clients\' + CWebView2ClientGuid,
       'pv', Pv) and (Pv <> '') and (Pv <> '0.0.0.0'))
    or
    (RegQueryStringValue(HKCU,
       'SOFTWARE\Microsoft\EdgeUpdate\Clients\' + CWebView2ClientGuid,
       'pv', Pv) and (Pv <> '') and (Pv <> '0.0.0.0'));
end;

// True if at least one SHIPPED version is installed on this machine.
function AnySupportedIdeInstalled(): Boolean;
begin
  Result := False;
#if HaveD11
  if VerInstalled('{#VerD11}') then Result := True;
#endif
#if HaveD12
  if VerInstalled('{#VerD12}') then Result := True;
#endif
#if HaveD13
  if VerInstalled('{#VerD13}') then Result := True;
#endif
end;

function InitializeSetup(): Boolean;
var
  MsgText: string;
  ErrCode: Integer;
begin
  // At least one supported IDE must be installed (this is a plugin).
  if not AnySupportedIdeInstalled() then
  begin
    MsgBox(
      'No supported RAD Studio version (Delphi 11 / BDS {#VerD11}, Delphi 12 / '
        + 'BDS {#VerD12} or Delphi 13 / BDS {#VerD13}) was found for the current user.'
        + #13#10#13#10
        + 'Aefos is an IDE plugin: install a supported RAD Studio first.',
      mbCriticalError, MB_OK);
    Result := False;
    exit;
  end;
  // Nag about closing the IDE only if it is ACTUALLY running (main window class
  // 'TAppBuilder'). Loop on Retry so the user can close it and continue.
  while FindWindowByClassName('TAppBuilder') <> 0 do
  begin
    if MsgBox(
      'RAD Studio is OPEN. Please close it to continue - the installer copies the '
        + 'BPLs and registers the design packages (the IDE locks them while open). '
        + 'Click Retry after closing it; restart the IDE at the end.',
      mbConfirmation, MB_RETRYCANCEL) = IDCANCEL then
    begin
      Result := False;
      exit;
    end;
  end;
  // WebView2 Runtime gate (machine-wide). Without it the Chat panel is BLACK.
  while not WebView2RuntimeInstalled() do
  begin
    if IsOnline() then
    begin
      MsgText :=
        'Microsoft WebView2 Runtime was not found. The Chat renders through it - '
          + 'without it the panel is black.' + #13#10#13#10
          + 'The download page is opening now. Install it, then click Retry. '
          + 'Cancel aborts the installation.';
      ShellExec('open', CWebView2BootstrapUrl, '', '', SW_SHOWNORMAL, ewNoWait, ErrCode);
    end
    else
      MsgText :=
        'You are OFFLINE and the WebView2 Runtime is not installed - I cannot download '
          + 'or validate it now.' + #13#10#13#10
          + 'Connect to the internet, install it from'
          + #13#10 + '    ' + CWebView2BootstrapUrl + #13#10
          + 'then run this setup again. Retry re-checks; Cancel aborts.';
    if MsgBox(MsgText, mbConfirmation, MB_RETRYCANCEL) = IDCANCEL then
    begin
      Result := False;
      exit;
    end;
  end;
  Result := True;
end;

// Doubles backslashes so a Windows path is a valid JSON string.
function JsonEsc(S: string): string;
begin
  StringChangeEx(S, '\', '\\', True);
  Result := S;
end;

// Writes {app}\.mcp.json pointing the external CLI at the INSTALLED bridge.
procedure WriteMcpJson();
var
  BridgePath, Json: string;
begin
  BridgePath := JsonEsc(ExpandConstant('{app}\mcp-bridge.ps1'));
  Json :=
    '{' + #13#10 +
    '  "mcpServers": {' + #13#10 +
    '    "aefos": {' + #13#10 +
    '      "command": "powershell",' + #13#10 +
    '      "args": [' + #13#10 +
    '        "-NonInteractive",' + #13#10 +
    '        "-File",' + #13#10 +
    '        "' + BridgePath + '",' + #13#10 +
    '        "-Session",' + #13#10 +
    '        "plugin"' + #13#10 +
    '      ]' + #13#10 +
    '    }' + #13#10 +
    '  }' + #13#10 +
    '}' + #13#10;
  SaveStringToFile(ExpandConstant('{app}\.mcp.json'), Json, False);
end;

function _OnPath(const AExe: string): Boolean;
var
  ResultCode: Integer;
begin
  Result := Exec(ExpandConstant('{cmd}'), '/C where ' + AExe + ' >nul 2>&1', '',
    SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0);
end;

function IsAnyAiCliOnPath(): Boolean;
begin
  Result := _OnPath('claude') or _OnPath('codex')
         or _OnPath('copilot') or _OnPath('gemini');
end;

// True when a bundled CLI was installed into the per-user bin (the plugin's
// CLIBinaryResolver finds it there after PATH, so it works with zero setup).
// Checked at ssPostInstall, when the [Files] payload is already on disk.
function IsAnyBundledCli(): Boolean;
begin
  // Only the Apache-2.0 CLIs are bundled (codex + gemini). Copilot and Claude are
  // not bundled (their licenses don't allow it), so they are not checked here.
  Result := FileExists(ExpandConstant('{userappdata}\Aefos\bin\codex.exe'))
         or FileExists(ExpandConstant('{userappdata}\Aefos\bin\gemini.exe'));
end;

// Optional 'copilotcli' task: after the integrated download page fetched the
// official Copilot portable zip to {tmp}, extract copilot.exe into the Aefos bin
// so the plugin's resolver finds it. No-op if the task is off or the zip is absent
// (download skipped/failed - non-fatal). Windows' built-in tar handles the zip.
procedure _ExtractCopilotZip();
var
  ResultCode: Integer;
  Zip: string;
begin
  if not WizardIsTaskSelected('copilotcli') then
    exit;
  Zip := ExpandConstant('{tmp}\copilot.zip');
  if not FileExists(Zip) then
    exit;
  Exec(ExpandConstant('{cmd}'),
    '/C tar -xf "' + Zip + '" -C "' + ExpandConstant('{userappdata}\Aefos\bin') + '"',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

function IsPythonAvailable(): Boolean;
var
  ResultCode: Integer;
begin
  Result := (Exec(ExpandConstant('{cmd}'), '/C where py >nul 2>&1', '',
              SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0))
         or (Exec(ExpandConstant('{cmd}'), '/C where python >nul 2>&1', '',
              SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0));
end;

function OnWebView2DownloadProgress(const Url, FileName: string;
  const Progress, ProgressMax: Int64): Boolean;
begin
  Result := True;
end;

#ifdef BundleWebView2
const
  CWebView2Standalone = 'MicrosoftEdgeWebView2RuntimeInstaller{#WV2Arch}.exe';
#endif

procedure EnsureWebView2();
var
  ResultCode: Integer;
begin
  if WebView2RuntimeInstalled() then
    exit;

#ifdef BundleWebView2
  try
    ExtractTemporaryFile(CWebView2Standalone);
    Exec(ExpandConstant('{tmp}\' + CWebView2Standalone), '/silent /install',
      '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  except
  end;
  if WebView2RuntimeInstalled() then
    exit;
#endif

  MsgBox(
    'The Microsoft WebView2 Runtime (used for the Chat''s rich rendering) was not '
      + 'found. The installer will try to download it now (needs internet). Without '
      + 'it the Chat still works in plain-text mode.',
    mbInformation, MB_OK);
  try
    DownloadTemporaryFile(CWebView2BootstrapUrl, 'MicrosoftEdgeWebview2Setup.exe',
      '', @OnWebView2DownloadProgress);
    Exec(ExpandConstant('{tmp}\MicrosoftEdgeWebview2Setup.exe'), '/silent /install',
      '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  except
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Msg: string;
begin
  if CurStep = ssInstall then
  begin
    EnsureWebView2();
    exit;
  end;
  if CurStep <> ssPostInstall then
    exit;

  WriteMcpJson();
  _ExtractCopilotZip();

  Msg :=
    'Aefos installed.' + #13#10#13#10
      + 'OPEN (or restart) the RAD Studio version(s) you selected. The packages '
      + '"Aefos AI - Chat" and "Aefos AI - Terminal" already show as installed; '
      + 'the Aefos AI menu is on the menu bar.' + #13#10#13#10;

  if IsAnyBundledCli() then
    Msg := Msg +
      'AI CLI: a ready-to-use CLI is bundled and installed -- no setup needed. '
        + 'You can also use your own CLI (Claude, Gemini, Copilot) on PATH and '
        + 'pick it in Tools -> Options -> Aefos.' + #13#10#13#10
  else if IsAnyAiCliOnPath() then
    Msg := Msg + 'AI CLI: a supported CLI was found on PATH. OK.' + #13#10#13#10
  else
    Msg := Msg +
      'AI CLI: none found on PATH. Install your preferred CLI (Claude, Codex, '
        + 'Gemini or Copilot), make sure it is on PATH, then select it in '
        + 'Tools -> Options -> Aefos.'
        + #13#10#13#10;

  if FileExists(ExpandConstant('{userappdata}\Aefos\bin\copilot.exe')) then
    Msg := Msg +
      'GitHub Copilot CLI: downloaded and installed. Pick "Copilot" in ' +
      'Tools -> Options -> Aefos to use it (needs a Copilot subscription).' + #13#10#13#10;

  Msg := Msg +
    'Terminal MCP: bridge + config generated at' + #13#10
      + '    ' + ExpandConstant('{app}') + '\mcp-bridge.ps1' + #13#10
      + '    ' + ExpandConstant('{app}') + '\.mcp.json  (already points to the bridge)'
      + #13#10 + 'Copy .mcp.json to your Delphi project root (or add its "aefos" '
      + 'block to your ~/.claude.json). The SessionName must match '
      + 'Tools -> Options -> Aefos -> Terminal (default "plugin"). '
      + 'Chat works without any of this.' + #13#10#13#10;

  if IsPythonAvailable() then
    Msg := Msg +
      'PyTools: tools installed in '
        + ExpandConstant('{userappdata}') + '\Aefos\pytools (Python OK).' + #13#10#13#10
  else
    Msg := Msg +
      'PyTools installed in ' + ExpandConstant('{userappdata}')
        + '\Aefos\pytools, but Python was NOT found. To use them, install Python '
        + '(py/python on PATH) from https://www.python.org '
        + '(or: winget install Python.Python.3.12). We bundle no Python.' + #13#10#13#10;

  if WebView2RuntimeInstalled() then
    Msg := Msg + 'WebView2 Runtime: OK (Chat renders).'
  else
    Msg := Msg +
      'WebView2 Runtime: still MISSING - the Chat panel will be blank. '
        + 'Install it manually: https://aka.ms/webview2';

  MsgBox(Msg, mbInformation, MB_OK);
end;

[CustomMessages]
; NO LANGUAGE PREFIX, and that is the point: an unprefixed entry is used by EVERY
; language, so this text is English whichever language the user picked at the
; start. Everything Aefos says is English (CLAUDE.md); the pt-BR entry in
; [Languages] only translates Inno's own buttons and boilerplate.
NoVersionSelected=Select at least one RAD Studio version to install into.
