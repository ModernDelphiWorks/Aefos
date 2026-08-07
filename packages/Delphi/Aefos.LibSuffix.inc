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

  THE NUMBERS ARE MEASURED, NOT REMEMBERED. Each one was read off the IDE's own
  bin folder (rtl<suffix>.bpl / designide<suffix>.bpl) on 2026-08-07:

    CompilerVersion  BDS    Product          Suffix
    30               17.0   10 Seattle       230
    31               18.0   10.1 Berlin      240
    32               19.0   10.2 Tokyo       250
    33               20.0   10.3 Rio         260
    34               21.0   10.4 Sydney      270
    35               22.0   Delphi 11        280
    36               23.0   Delphi 12        290
    37               37.0   Delphi 13        370

  Note the jump at the end: 35 -> 280 and 36 -> 290 are ten apart, 36 -> 37 is
  eighty. There is no formula to derive, which is exactly why the table is read
  from disk rather than computed - the one time this file could be "obviously"
  generalised is the time it would be wrong.

  Win32 and Win64 share a suffix; Embarcadero ships rtl290.bpl in both bin and
  bin64. The two bitnesses are told apart by their FOLDER (Bpl and Bpl\Win64), not
  by their name, and inventing a difference here would break that convention for
  no gain.

  AUTO covers whatever ships next: it asks the compiler for its own suffix, so a
  future RAD Studio needs no edit here. It is only reached above 37 because every
  version at or below that has a measured number, and a measured number beats a
  mechanism we have not watched run.

  IF THIS FILE STOPS BEING INCLUDED - the IDE rewrites a .dpk when you add or
  remove files through the Project Manager, and a directive it does not recognise
  can be dropped - the BPL silently goes back to its unsuffixed name and the
  collision returns. That is why build-packages.ps1 asserts the SUFFIXED file
  exists after every build: the failure has to be loud.
*)

{$IFNDEF FPC}

{$IF CompilerVersion < 30}
  {$MESSAGE FATAL 'Aefos needs Delphi 10 Seattle (CompilerVersion 30) or newer.'}
{$IFEND}

{$IF CompilerVersion = 30}{$LIBSUFFIX '230'}{$IFEND}
{$IF CompilerVersion = 31}{$LIBSUFFIX '240'}{$IFEND}
{$IF CompilerVersion = 32}{$LIBSUFFIX '250'}{$IFEND}
{$IF CompilerVersion = 33}{$LIBSUFFIX '260'}{$IFEND}
{$IF CompilerVersion = 34}{$LIBSUFFIX '270'}{$IFEND}
{$IF CompilerVersion = 35}{$LIBSUFFIX '280'}{$IFEND}
{$IF CompilerVersion = 36}{$LIBSUFFIX '290'}{$IFEND}
{$IF CompilerVersion = 37}{$LIBSUFFIX '370'}{$IFEND}
{$IF CompilerVersion > 37}{$LIBSUFFIX AUTO}{$IFEND}

{$ENDIF}
