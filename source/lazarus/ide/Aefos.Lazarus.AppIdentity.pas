unit Aefos.Lazarus.AppIdentity;

{ Aefos AI - Lazarus edition: the IDE's OWN visual identity.

  THE PROBLEM THIS SOLVES
  -----------------------
  The installer no longer touches the user's Lazarus: it BUILDS A SECOND IDE
  (%LOCALAPPDATA%\Aefos\lazarus\bin\lazarus.exe) from his tree. Two IDEs then
  run side by side - and they were INDISTINGUISHABLE in the taskbar and in
  Alt+Tab, because the window icon of both comes from the MAINICON resource of
  HIS lazarus.lpr (ide\lazarus.res), which our build links verbatim.

  Renaming our exe is not an option and never will be: ide\lazarusmanager.pas:331
  hardcodes DefaultExe/CustomExe as 'lazarus' + GetExeExt, so startlazarus - the
  process TMainIDE.DoRestart launches on "Save and rebuild IDE" and on installing
  a package - looks for literally lazarus.exe in <pcp>\bin. A renamed exe would
  send that restart into HIS IDE carrying OUR configuration.

  So the identity is set at RUNTIME, from our own package, in one place: this
  unit. It is called once from Register (Aefos.Lazarus.Register), which the IDE
  dispatches during TMainIDE.Create - i.e. AFTER Application.Initialize
  (ide\lazarus.pp:131) has created the widgetset and its application window, so
  the assignment lands on a live handle.

  WHY Application.Icon IS THE WHOLE ANSWER HERE
  ---------------------------------------------
  ide\lazarus.pp:123 sets Application.MainFormOnTaskBar := False on Windows, so
  the taskbar button belongs to the widgetset's application window, not to the
  main form. Writing Application.Icon fires TApplication.IconChanged
  (lcl\include\application.inc:1130), which does exactly two things:
    1. Widgetset.AppSetIcon(Small, Big) -> WM_SETICON + SetClassLongPtr on that
       application window (lcl\interfaces\win32\win32object.inc:509) = the
       TASKBAR and Alt+Tab entry;
    2. CM_ICONCHANGED to every form on Screen, and a form with no icon of its own
       falls back to Application.SmallIconHandle/BigIconHandle
       (lcl\include\customform.inc:351/371) = every IDE WINDOW, including ones
       created later.
  One assignment, both surfaces, no PE post-processing of the produced binary
  (rewriting a linked exe is what cost a release once - it is not done here).

  THE ONE WINDOW THAT NEEDS A SECOND LINE
  ---------------------------------------
  TMainIDEBar.Create does Icon.LoadFromResourceName(HInstance, 'WIN_MAIN')
  (ide\mainbar.pas:636), so the IDE's main window has an icon OF ITS OWN and
  never consults Application.Icon - its title bar would still show Lazarus's
  while the taskbar showed ours. So the main form's icon is assigned too, right
  after. This is plain LCL (the picture is COPIED into the form's own TIcon), it
  is exactly what the form's constructor did, and it holds nothing of ours.

  WHY THE ICON IS A FILE AND NOT AN EMBEDDED RESOURCE
  ---------------------------------------------------
  Same reason the About dialog loads its lockup PNG from disk
  (Aefos.Lazarus.AboutForm): the RAD Studio edition embeds its art in a BPL
  resource, but this edition is COMPILED ON THE USER'S MACHINE by lazbuild, and
  adding a binary resource to that link is a build risk carried by every user for
  a cosmetic gain. The installer stages the .ico next to the About logo, in the
  same shared per-user brand folder, and a missing file degrades to "the IDE
  looks like Lazarus" - never to a failure.

  IDE-UNLOAD DISCIPLINE
  ---------------------
  Nothing to unpair. This registers no notifier, no keyboard binding and no menu
  item; it only replaces the CONTENT of the TIcon that TApplication itself owns
  and frees, so no reference into this package survives the call. (A Lazarus
  design package is statically linked into lazarus.exe and is never unloaded at
  all - but the rule is honoured on its own terms, not by that accident.)

  Pure LCL - no IDEIntf/ToolsAPI. All literals are ASCII, so the file needs no
  BOM. }

{$mode delphi}
{$H+}

interface

type
  { The IDE's own look. A class holder, so no loose routine is exported. }
  TAefosLazAppIdentity = class
  public
    { Points the application icon (taskbar, Alt+Tab and every IDE window that
      has no icon of its own) at the Aefos icon staged by the installer. Safe to
      call more than once - the second call is a no-op - and it NEVER raises:
      a missing or unreadable file leaves the stock Lazarus icon in place. }
    class procedure ApplyIcon;
    { Absolute path of the staged icon (%APPDATA%\Aefos\aefos-lazarus.ico), or
      an empty string when %APPDATA% is not set. Public so a diagnostic can
      report the exact path that was looked for. }
    class function IconPath: string;
  end;

implementation

uses
  SysUtils,
  Forms,
  LazUTF8,        // GetEnvironmentVariableUTF8 - the UTF-8 environment seam
  LazFileUtils,   // AppendPathDelim / FileExistsUTF8
  LazLoggerBase;  // DebugLn breadcrumbs (visible with --debug-log)

const
  { The shared per-user brand folder: the SAME %APPDATA%\Aefos the RAD Studio
    edition uses (one brain, both editions). The installer stages this file
    beside aefos-about-logo.png and mcp-bridge.ps1. }
  cVendorDir    = 'Aefos';
  cIconFileName = 'aefos-lazarus.ico';

  { Breadcrumb tag, matching Aefos.Lazarus.Register's. }
  cLogTag = '[AefosAI] ';

var
  { One-shot latch: Register calls ApplyIcon once, but a future caller (a repair
    action, a diagnostic) must not pay for the file read twice. }
  GIconApplied: Boolean = False;

class function TAefosLazAppIdentity.IconPath: string;
var
  LAppData: string;
begin
  Result := '';
  LAppData := GetEnvironmentVariableUTF8('APPDATA');
  if LAppData = '' then
    Exit;
  Result := AppendPathDelim(AppendPathDelim(LAppData) + cVendorDir) + cIconFileName;
end;

class procedure TAefosLazAppIdentity.ApplyIcon;
var
  LPath: string;
begin
  if GIconApplied then
    Exit;
  GIconApplied := True;
  if Application = nil then
    Exit;
  LPath := IconPath;
  if (LPath = '') or (not FileExistsUTF8(LPath)) then
  begin
    { Honest, and actionable: this is exactly what a user sees when the icon was
      not staged (a manual .lpk install, or a deleted file). The IDE then keeps
      the stock Lazarus icon - it does not fail. }
    DebugLn(cLogTag + 'AppIdentity: icon not staged, keeping the stock IDE icon ('
      + LPath + ')');
    Exit;
  end;
  try
    { Assigning the icon is what fires TApplication.IconChanged; loading INTO
      Application.Icon (rather than assigning a TIcon of ours) also means the
      instance stays TApplication's to free. }
    Application.Icon.LoadFromFile(LPath);
    { The main IDE window carries its own 'WIN_MAIN' icon and would otherwise be
      the one window still wearing Lazarus's. Nil when this ever runs before the
      main form exists (it does not in Lazarus - packages load from
      TMainIDE.Create, after ide\main.pp:1611 created the bar - but a nil check
      is cheaper than depending on that order).

      Read from the file again rather than copied from the icon just loaded: the
      assignment above already fired TApplication.IconChanged, which calls
      Icon.ReleaseHandle on Application.Icon (application.inc:1158, inside
      SmallIconHandle), so copying would make this window's icon depend on the
      state that left behind. A second read of a file we know is readable does
      not. }
    if Application.MainForm <> nil then
      Application.MainForm.Icon.LoadFromFile(LPath);
    DebugLn(cLogTag + 'AppIdentity: application icon set from ' + LPath);
  except
    on E: Exception do
      { A corrupt/unsupported file must not cost the user his IDE for a picture. }
      DebugLn(cLogTag + 'AppIdentity: icon load RAISED ' + E.ClassName + ': '
        + E.Message + ' (' + LPath + ')');
  end;
end;

end.
