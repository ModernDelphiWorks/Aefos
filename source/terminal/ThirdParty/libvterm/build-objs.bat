@echo off
rem ===========================================================================
rem  build-objs.bat - Compile vendored libvterm C sources to linkable .obj files
rem ---------------------------------------------------------------------------
rem  Demand #24 (ESP-024 / ADR-024-02): libvterm is embedded into RADShell.bpl
rem  via {$L} object-file linking - no separate DLL.
rem
rem  Compiler: bcc32c.exe - the Clang-enhanced, classic-compatible C++ compiler
rem  shipped with RAD Studio. The legacy bcc32.exe is C89/C++03 and CANNOT
rem  compile libvterm (C99 designated initializers + mixed declarations).
rem  bcc32c emits OMF objects ("8086 relocatable"), which the Delphi Win32
rem  linker accepts directly through {$L}.
rem
rem  Usage:  build-objs.bat
rem    Requires bcc32c.exe on PATH, or the BDS environment variable pointing at
rem    the RAD Studio root (set automatically inside the IDE / by rsvars.bat).
rem  Output: obj\*.obj  (individual objects + libvterm_unity.obj for {$L})
rem
rem  Unity build: libvterm_unity.obj bundles all 9 translation units into one
rem  object to solve circular cross-references that Delphi's single-pass {$L}
rem  linker cannot resolve from separately-linked objects.
rem ===========================================================================
setlocal

set HERE=%~dp0
set OUTDIR=%HERE%obj

rem -- Locate the compiler -----------------------------------------------------
set BCC=bcc32c.exe
if defined BDS if exist "%BDS%\bin\bcc32c.exe" set BCC="%BDS%\bin\bcc32c.exe"

rem -- Core translation units (see CODE-MAP for the role of each) --------------
set UNITS=encoding keyboard mouse parser pen screen state unicode vterm

if not exist "%OUTDIR%" mkdir "%OUTDIR%"

set FAILED=0
for %%U in (%UNITS%) do (
  echo Compiling %%U.c
  %BCC% -c -I"%HERE%include" -I"%HERE%src" -o"%OUTDIR%\%%U.obj" "%HERE%src\%%U.c"
  if errorlevel 1 set FAILED=1
)

if "%FAILED%"=="1" (
  echo.
  echo *** libvterm individual objects build FAILED ***
  endlocal & exit /b 1
)

rem -- Unity build (all 9 TUs in one object for Delphi {$L} linking) -----------
echo Compiling libvterm_unity.c
%BCC% -c -I"%HERE%include" -I"%HERE%src" -o"%OUTDIR%\libvterm_unity.obj" "%HERE%src\libvterm_unity.c"
if errorlevel 1 (
  echo.
  echo *** libvterm unity build FAILED ***
  endlocal & exit /b 1
)

echo.
echo libvterm objects built into %OUTDIR%
endlocal & exit /b 0
