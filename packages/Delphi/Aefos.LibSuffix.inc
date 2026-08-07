(*
  One BPL file name per RAD Studio version.

  WHY THIS EXISTS. A design package names the runtime packages it needs, and the
  IDE resolves each one through the process PATH - where every installed RAD
  Studio has already put its own Bpl folder. Without a suffix our packages carry
  the SAME file name in every version, so on a machine with more than one IDE the
  first Bpl folder on PATH answers for all of them. Measured on a VM holding 17.0
  through 22.0: the Seattle IDE loaded the SYDNEY Aefos.MCP.Core.bpl, which has
  no Aefos.Compat.JsonFormat helper (compiled only below CompilerVersion 33), and
  the install died with "entry point ...TAefosJsonFormatHelper@Format not found".
  The WebView package failed differently - a Sydney BPL dragging the Sydney RTL
  into a Seattle process, access violation - from the same single cause.

  Embarcadero solved this for their own packages long ago: rtl230.bpl, rtl270.bpl,
  rtl290.bpl. We follow their suffix exactly, so an Aefos BPL sits next to the RTL
  it was built against and reads as belonging to it.

  ---------------------------------------------------------------------------
  WHY {$IFDEF VERxxx} AND NOT {$IF CompilerVersion = nn}

  Because CompilerVersion DOES NOT EXIST in a .dpk, and the way it fails is the
  dangerous kind. Measured on Delphi 12 (compiler 36.0):

      {$IF CompilerVersion = 36}  -> taken
      {$IF CompilerVersion = 99}  -> ALSO TAKEN
      {$IF Declared(CompilerVersion)} -> not taken
      {$IF RTLVersion = 99}       -> ALSO TAKEN

  An {$IF} naming an undeclared constant is treated as TRUE. Plain {$IFDEF} and
  {$IF 0 = 1} behave correctly in the same file, so this is specific to those
  symbols: a package's directive section does not have them. The first version of
  this file used CompilerVersion and every branch fired at once - all eight
  {$LIBSUFFIX} lines executed and the last one won. That is a conditional that
  compiles, looks reasonable, and silently means nothing.

  {$IFDEF VERxxx} is proven to work here: on Delphi 12 only VER360 was taken,
  VER300/VER350/VER370 were not, and {$LIBSUFFIX '290'} made the compiler write
  TestSfx4290.bpl.
  ---------------------------------------------------------------------------

  THE NUMBERS ARE MEASURED, NOT REMEMBERED. Each suffix was read off the IDE's own
  bin folder (rtl<suffix>.bpl / designide<suffix>.bpl) on 2026-08-07:

    VER symbol  BDS    Product          Suffix
    VER300      17.0   10 Seattle       230
    VER310      18.0   10.1 Berlin      240
    VER320      19.0   10.2 Tokyo       250
    VER330      20.0   10.3 Rio         260
    VER340      21.0   10.4 Sydney      270
    VER350      22.0   Delphi 11        280
    VER360      23.0   Delphi 12        290
    VER370      37.0   Delphi 13        370

  Note the jump at the end: 22.0 -> 280 and 23.0 -> 290 are ten apart, 23.0 -> 37.0
  is eighty. There is no formula to derive, which is exactly why the table is read
  from disk rather than computed - the one time this file could be "obviously"
  generalised is the time it would be wrong.

  Win32 and Win64 share a suffix; Embarcadero ships rtl290.bpl in both bin and
  bin64. The two bitnesses are told apart by their FOLDER (Bpl and Bpl\Win64), not
  by their name, and inventing a difference here would break that convention for
  no gain.

  A FUTURE RAD STUDIO matches no line here and therefore gets no suffix. That is
  deliberate: {$LIBSUFFIX AUTO} would cover it, but AUTO cannot be guarded (the
  only guard available is {$IFDEF VERxxx}, which by definition does not know the
  version that has not shipped), and an unguarded AUTO would also reach 10 Seattle,
  where it does not exist. So the new version produces an unsuffixed BPL and
  build-packages.ps1 stops the build asking for the suffixed name - a loud failure
  with an obvious fix (add the row) instead of a quiet one.

  THE SAME LOUD FAILURE COVERS the other way this can break: the IDE rewrites a
  .dpk when you add or remove files through the Project Manager, and a directive
  it does not recognise can be dropped. If the {$I} line for this file ever goes,
  the BPL returns to its unsuffixed name and the staging step refuses it.
*)

{$IFNDEF FPC}
{$IFDEF VER300}{$LIBSUFFIX '230'}{$ENDIF}
{$IFDEF VER310}{$LIBSUFFIX '240'}{$ENDIF}
{$IFDEF VER320}{$LIBSUFFIX '250'}{$ENDIF}
{$IFDEF VER330}{$LIBSUFFIX '260'}{$ENDIF}
{$IFDEF VER340}{$LIBSUFFIX '270'}{$ENDIF}
{$IFDEF VER350}{$LIBSUFFIX '280'}{$ENDIF}
{$IFDEF VER360}{$LIBSUFFIX '290'}{$ENDIF}
{$IFDEF VER370}{$LIBSUFFIX '370'}{$ENDIF}
{$ENDIF}
